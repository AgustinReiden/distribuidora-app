-- Ensayo de la migración de la tarjeta 4 de #1477 (#1471, STK-F-1 a STK-F-7): compras, notas de
-- crédito de compra y movimientos entre sucursales.
--
-- El 40P01 de las dos notas lo mide el arnés (scripts/concurrencia, escenario a4), porque hacen falta dos
-- sesiones. Acá se prueba en una sola sesión lo que cambia en cada camino, y que los cuerpos quedaron
-- con los locks en el orden global.
--
--   C0 · registrar_compra_completa de A (10 a $100 + 2 de regalo al 100 %) y B (10 a $200 con 10 %):
--        entra, y A queda en 12 y B en 10.
--   C1 · La misma compra con la fecha de mañana, con más de un año, con una cantidad de 2.5, con
--        cantidad 0, con una bonificación de 150 o de −5, o con un costo de −1: cada una se rechaza
--        con su motivo y no se crea ninguna compra.
--   N1 · Nota de crédito de 6 de A y 2 de B, en orden [B, A], con los importes que calcula el modal
--        nuevo (costo neto promedio): A acredita 6 × 1000/12 = 500 y B 2 × 180 = 360; IVA 180,60.
--        Un item por producto, A queda en 6 y B en 8.
--   N2 · La misma nota con los importes del modal viejo (costo bruto, 2 × 100 = 200): se rechaza y no
--        se mueve nada.
--   N3 · Con B en 1 de stock, una nota de 3 de B: se rechaza (antes la dejaba en 0 en silencio).
--   N4 · Nota por lote de 2 de A (un lote de la compra con 6): acredita 2 × 1000/12 = 166,67 y no 200;
--        el lote queda en 4 y A en 4.
--   M1 · crear_movimiento_sucursal con una línea en 0, o con [A 1, A −1]: se rechaza y no sale nada.
--   M2 · editar_movimiento_sucursal de un envío de 1 de A a [A 0]: se rechaza y el envío sigue igual.
--   K1 · productos.stock = −1 da 23514 (productos_stock_no_negativo).
--   L1 · Los cuerpos: las dos notas toman el producto antes que las líneas de la compra y que el lote.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre
-- en una excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y
-- el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ' por C1, N1, N2, N3,
-- N4, M1, M2, K1 y L1: sólo C0 pasa igual con y sin la migración.
--
-- Fixtures: una sucursal activa con un admin activo. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_como(p_uid uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text, p_stock int)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 2000, p_stock, 100, p_suc)
  RETURNING id;
$fn$;

-- La compra de C0 (y de C1, con un cambio): A 10 + 2 de regalo, B 10 con 10 %.
CREATE OR REPLACE FUNCTION pg_temp.t_compra(p_adm uuid, p_a bigint, p_b bigint, p_fecha date, p_cambio jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.registrar_compra_completa(
    NULL, 'ZZ ensayo 1471', 'ensayo-1471', p_fecha, 2800, 588, 0, 3388, 'efectivo', 'ensayo 1471', p_adm,
    jsonb_build_array(
      jsonb_build_object('producto_id', p_a, 'cantidad', 10, 'costo_unitario', 100, 'subtotal', 1000, 'bonificacion', 0, 'porcentaje_iva', 21) || p_cambio,
      jsonb_build_object('producto_id', p_a, 'cantidad', 2, 'costo_unitario', 100, 'subtotal', 0, 'bonificacion', 100, 'porcentaje_iva', 21),
      jsonb_build_object('producto_id', p_b, 'cantidad', 10, 'costo_unitario', 200, 'subtotal', 1800, 'bonificacion', 10, 'porcentaje_iva', 21)));
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_dest   bigint;
  v_adm    uuid;
  v_a      bigint;
  v_b      bigint;
  v_compra bigint;
  v_lote   bigint;
  v_mov    bigint;
  v_nc     bigint;
  v_n      int;
  v_j      jsonb;
  v_txt    text;
  v_src    text;
  v_caso   record;
  v_fallas text[] := '{}';
BEGIN
  SELECT s.id, adm.usuario_id INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin';
  END IF;
  PERFORM pg_temp.t_como(v_adm, v_suc);

  SELECT id INTO v_dest FROM sucursales WHERE activa AND id <> v_suc ORDER BY id LIMIT 1;
  IF v_dest IS NULL THEN
    INSERT INTO sucursales (nombre, activa) VALUES ('ZZ ensayo 1471 destino', true) RETURNING id INTO v_dest;
  END IF;
  v_a := pg_temp.t_producto(v_suc, 'ZZ ensayo 1471 A', 0);
  v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1471 B', 0);

  -- C0 · la compra
  v_j := pg_temp.t_compra(v_adm, v_a, v_b, public._tablero_hoy());
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · C0 no se pudo registrar la compra: %', v_j;
  END IF;
  v_compra := (v_j->>'compra_id')::bigint;
  v_txt := format('A=%s B=%s', (SELECT stock FROM productos WHERE id = v_a), (SELECT stock FROM productos WHERE id = v_b));
  IF v_txt IS DISTINCT FROM 'A=12 B=10' THEN
    v_fallas := v_fallas || ('C0 la compra dejó ' || v_txt);
  END IF;

  -- C1 · los rangos del alta
  SELECT count(*) INTO v_n FROM compras WHERE sucursal_id = v_suc;
  FOR v_caso IN
    SELECT * FROM (VALUES
      ('fecha de mañana',   public._tablero_hoy() + 1,                             '{}'::jsonb,                         'posterior a hoy'),
      ('fecha de hace 1 año y 1 día', (public._tablero_hoy() - INTERVAL '1 year')::date - 1, '{}'::jsonb,               'más de un año'),
      ('cantidad 2.5',      public._tablero_hoy(), '{"cantidad": 2.5}'::jsonb,                                   'la cantidad tiene que ser entera'),
      ('cantidad 0',        public._tablero_hoy(), '{"cantidad": 0}'::jsonb,                                     'la cantidad tiene que ser mayor a 0'),
      ('bonificación 150',  public._tablero_hoy(), '{"bonificacion": 150}'::jsonb,                               'la bonificación es un porcentaje, de 0 a 100'),
      ('bonificación -5',   public._tablero_hoy(), '{"bonificacion": -5}'::jsonb,                                'la bonificación es un porcentaje, de 0 a 100'),
      ('costo -1',          public._tablero_hoy(), '{"costo_unitario": -1}'::jsonb,                              'el costo no puede ser negativo')
    ) AS c(nombre, fecha, cambio, motivo)
  LOOP
    v_j := pg_temp.t_compra(v_adm, v_a, v_b, v_caso.fecha, v_caso.cambio);
    IF COALESCE((v_j->>'success')::boolean, true) OR position(v_caso.motivo IN COALESCE(v_j->>'error', '')) = 0 THEN
      v_fallas := v_fallas || format('C1 %s dio %s', v_caso.nombre, v_j);
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM compras WHERE sucursal_id = v_suc) <> v_n THEN
    v_fallas := v_fallas || 'C1 una compra rechazada quedó creada'::text;
  END IF;

  -- N2 · los importes del modal viejo (bruto): se rechaza
  v_j := public.registrar_nota_credito(v_compra, 'NC-1471-viejo', 'ensayo 1471', 200, 42, 242, v_adm,
           jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 2, 'costo_unitario', 100, 'subtotal', 200)), 0);
  IF COALESCE((v_j->>'success')::boolean, true)
     OR position('no coincide con el costo neto' IN COALESCE(v_j->>'error', '')) = 0
     OR (SELECT stock FROM productos WHERE id = v_a) <> 12
     OR EXISTS (SELECT 1 FROM notas_credito WHERE compra_id = v_compra) THEN
    v_fallas := v_fallas || ('N2 la nota con el costo bruto dio ' || v_j::text);
  END IF;

  -- N1 · la nota con los importes netos promedio, en orden [B, A]
  v_j := public.registrar_nota_credito(v_compra, 'NC-1471', 'ensayo 1471', 860, 180.6, 1040.6, v_adm,
           jsonb_build_array(
             jsonb_build_object('producto_id', v_b, 'cantidad', 2, 'costo_unitario', 180, 'subtotal', 360),
             jsonb_build_object('producto_id', v_a, 'cantidad', 6, 'costo_unitario', 83.3333, 'subtotal', 500)), 0);
  v_nc := (v_j->>'nota_credito_id')::bigint;
  v_txt := format('ok=%s sub=%s iva=%s total=%s items=%s A=%s B=%s', v_j->>'success',
                  (SELECT subtotal FROM notas_credito WHERE id = v_nc), (SELECT iva FROM notas_credito WHERE id = v_nc),
                  (SELECT total FROM notas_credito WHERE id = v_nc),
                  (SELECT string_agg(format('%s:%s:%s:%s', CASE producto_id WHEN v_a THEN 'A' ELSE 'B' END, cantidad,
                                            round(costo_unitario, 2), subtotal), ',' ORDER BY producto_id)
                     FROM nota_credito_items WHERE nota_credito_id = v_nc),
                  (SELECT stock FROM productos WHERE id = v_a), (SELECT stock FROM productos WHERE id = v_b));
  IF v_txt IS DISTINCT FROM 'ok=true sub=860.00 iva=180.60 total=1040.60 items=A:6:83.33:500.00,B:2:180.00:360.00 A=6 B=8' THEN
    v_fallas := v_fallas || ('N1 la nota dejó ' || v_txt);
  END IF;

  -- N3 · el stock que no alcanza
  UPDATE productos SET stock = 1 WHERE id = v_b;
  v_j := public.registrar_nota_credito(v_compra, 'NC-1471-corta', 'ensayo 1471', 540, 113.4, 653.4, v_adm,
           jsonb_build_array(jsonb_build_object('producto_id', v_b, 'cantidad', 3, 'costo_unitario', 180, 'subtotal', 540)), 0);
  IF COALESCE((v_j->>'success')::boolean, true)
     OR position('No alcanza el stock' IN COALESCE(v_j->>'error', '')) = 0
     OR (SELECT stock FROM productos WHERE id = v_b) <> 1 THEN
    v_fallas := v_fallas || ('N3 la nota sin stock dio ' || v_j::text);
  END IF;

  -- N4 · la nota por lote, al neto promedio
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id)
  VALUES (v_a, v_suc, public._tablero_hoy() + 30, 6, 6, v_compra)
  RETURNING id INTO v_lote;
  BEGIN
    v_j := public.registrar_nota_credito_lote(v_lote, 2, 'NC-1471-lote', 'ensayo 1471');
  EXCEPTION WHEN OTHERS THEN
    v_j := jsonb_build_object('error', SQLERRM);
  END;
  v_txt := format('sub=%s iva=%s total=%s lote=%s A=%s', v_j->>'subtotal', v_j->>'iva', v_j->>'total',
                  (SELECT cantidad_restante FROM producto_lotes WHERE id = v_lote), (SELECT stock FROM productos WHERE id = v_a));
  IF v_txt IS DISTINCT FROM 'sub=166.67 iva=35.00 total=201.67 lote=4 A=4' THEN
    v_fallas := v_fallas || ('N4 la nota por lote dejó ' || v_txt || ' ' || v_j::text);
  END IF;

  -- M1 · crear un envío con líneas que no sirven
  FOR v_caso IN
    SELECT * FROM (VALUES
      ('una línea en 0', jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 0))),
      ('[A 1, A -1]',    jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 1),
                                           jsonb_build_object('producto_id', v_a, 'cantidad', -1)))
    ) AS c(nombre, items)
  LOOP
    v_j := public.crear_movimiento_sucursal(v_dest, 'ensayo 1471', v_caso.items);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR position('cantidad entera mayor a 0' IN COALESCE(v_j->>'error', '')) = 0
       OR (SELECT stock FROM productos WHERE id = v_a) <> 4 THEN
      v_fallas := v_fallas || format('M1 crear con %s dio %s', v_caso.nombre, v_j);
    END IF;
  END LOOP;

  -- M2 · editar un envío a una línea en 0
  v_j := public.crear_movimiento_sucursal(v_dest, 'ensayo 1471',
           jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 1)));
  v_mov := (v_j->>'movimiento_id')::bigint;
  IF v_mov IS NULL THEN
    v_fallas := v_fallas || ('M2 no se pudo crear el envío: ' || v_j::text);
  ELSE
    v_j := public.editar_movimiento_sucursal(v_mov, 'ensayo 1471',
             jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 0),
                               jsonb_build_object('producto_id', v_b, 'cantidad', 1)));
    IF COALESCE((v_j->>'success')::boolean, true)
       OR position('cantidad entera mayor a 0' IN COALESCE(v_j->>'error', '')) = 0
       OR (SELECT string_agg(producto_origen_id || ':' || cantidad, ',') FROM movimiento_sucursal_items WHERE movimiento_id = v_mov)
          IS DISTINCT FROM v_a || ':1'
       OR (SELECT stock FROM productos WHERE id = v_a) <> 3 THEN
      v_fallas := v_fallas || ('M2 editar a [A 0, B 1] dio ' || v_j::text);
    END IF;
  END IF;

  -- K1 · el CHECK
  BEGIN
    UPDATE productos SET stock = -1 WHERE id = v_b;
    v_fallas := v_fallas || 'K1 productos.stock aceptó -1'::text;
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%productos_stock_no_negativo%' THEN
      v_fallas := v_fallas || ('K1 el CHECK que saltó es otro: ' || SQLERRM);
    END IF;
  END;

  -- L1 · el orden de los locks en los cuerpos
  v_src := (SELECT prosrc FROM pg_proc
             WHERE oid = 'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure);
  IF position('#1471 (STK-F-2)' IN v_src) NOT BETWEEN position('FOR SHARE' IN v_src) AND position('PERFORM 1 FROM compra_items' IN v_src)
     OR position('#1471: los lotes de la compra' IN v_src) NOT BETWEEN position('PERFORM 1 FROM compra_items' IN v_src) AND position('FOR v_linea IN' IN v_src) THEN
    v_fallas := v_fallas || 'L1 registrar_nota_credito no toma compra → productos → líneas → lotes'::text;
  END IF;
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = 'public.registrar_nota_credito_lote(bigint,numeric,text,text)'::regprocedure);
  IF position('#1471 (STK-F-1)' IN v_src) NOT BETWEEN position('FOR SHARE' IN v_src) AND position('SELECT * INTO v_lote' IN v_src) THEN
    v_fallas := v_fallas || 'L1 registrar_nota_credito_lote no toma el producto antes que el lote'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · C0 C1 N1 N2 N3 N4 M1 M2 K1 L1';
END
$ensayo$;
