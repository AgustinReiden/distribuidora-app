-- Ensayo de la migración 483 (tarjeta 5 de #1524; STK-1, STK-4, STK-5 y STK-10 de #1516).
--
-- Corre contra prod SIN dejar rastro (salvo valores de secuencia): un único DO que termina SIEMPRE
-- en una excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN
-- y el COMMIT; después, solo. Cada caso usa sus propios productos.
--
-- Personas (salen de la base): un admin activo de una sucursal S1 y alguien activo que es admin o
-- encargado de otra sucursal S2 (puede ser el mismo usuario). Las compras son ZZ: el costo real es
-- el costo unitario.
--
-- STK-1 · lo que vuelve de un envío vuelve de donde salió (los lotes tienen hueco, a propósito: con
-- la bolsa en 0 y sin hueco la devolución por FEFO da bien por casualidad).
--   E1 · el ejemplo de #1516: L 60 al que le quedan 40, bolsa 60. Se envían 30, que salen de la
--        bolsa; cancelar deja L en 40 y la bolsa en 60. Antes: L 60 y la bolsa 40.
--   E2 · denegar: L1 (vence antes, 30 con 10) y L2 (40 con 40), bolsa 0. Se envían 30: 10 de L1 y
--        20 de L2. Denegar deja L1 10 y L2 40. Antes: L1 30 y L2 20.
--   E3 · achicar el envío dos veces y cancelarlo: L 50 con 20, bolsa 80. Se envían 90 (80 de la
--        bolsa y 10 de L). A 85: los 5 vuelven a la bolsa (L 10, bolsa 5; antes L 15). A 5: 75 a la
--        bolsa y 5 a L (L 15, bolsa 80), y el registro queda en 5. Cancelar: L 20, bolsa 80.
--   E4 · el lote del registro ya no existe (se borró): cancelar devuelve todo a la bolsa.
-- STK-4 · la NC de devolución corrige el promedio como una anulación parcial de la compra.
--   N1 · el ejemplo de #1516: 100 a 10 + P 100 a 20 = 15; NC de las 100: 10. Antes: 15.
--   N2 · en dos notas: NC de 50 → 13,3333; NC de las otras 50 → 10.
--   N3 · con una compra posterior: 100 a 10; P 100 a 20 → 15; P2 50 a 30 → 18; NC de 100 de P →
--        16,6667, y la foto de P2 pasa a 100 u. a 10.
--   N4 · la NC por lote: 100 a 10 + P 100 a 20; NC de 40 del lote de P → 13,75.
--   N5 · compra sin foto (anterior a la 236): la NC pasa, avisa sin_cpp_previo y el promedio queda.
--   N6 · la NC de ajuste (sin mercadería) no toca el promedio.
-- STK-5 · el arrastre ve los ingresos por envío.
--   R1 · anular con un envío aceptado después: 100 a 10; P 100 a 20 → 15; entran 50 a 30 → 18;
--        anular P → 16,6667 (antes 13), y la foto del ingreso pasa a 100 u.
--   R2 · anular la primera compra con un envío después: P 100 a 20 → 20; entran 50 a 30 →
--        23,3333; anular P → 30 (antes NULL).
--   R3 · editar con un envío después: igual que R1, P pasa a 50 u. → 17,5 (antes 16,3333).
-- STK-10 · la merma por vencimiento sale del lote vencido.
--   V1 · LV vencido (30), LN vigente (30), bolsa 40: merma de 20 por vencimiento → LV 10, LN 30,
--        bolsa 40. Antes: LV 30, bolsa 20.
--   V2 · igual, merma de 50: LV 0, LN 30, bolsa 20.
--   V3 · una rotura no toca los lotes: merma de 10 → bolsa 30.
--   V4 · un lote que vence hoy no está vencido: merma de 10 por vencimiento → sale de la bolsa.
-- Regresiones que pasan con y sin la migración: E4, N6, V3 y V4.
--
-- Sin la migración tiene que FALLAR en E1, E2, E3, N1–N5, R1, R2, R3, V1 y V2.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   psql "$DATABASE_URL" -f scripts/test-envios-promedio-merma-1516.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_s2     bigint;
  v_ua     uuid;   -- admin de S1
  v_ub     uuid;   -- admin o encargado de S2
  v_hoy    date := public._tablero_hoy();
  v_p      bigint;
  v_o      bigint;
  v_l1     bigint;
  v_l2     bigint;
  v_c      bigint;
  v_c2     bigint;
  v_mov    bigint;
  v_item   bigint;
  v_j      jsonb;
  v_t      text;
  v_fallas text[] := '{}';
BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT us1.sucursal_id, us1.usuario_id, us2.sucursal_id, us2.usuario_id
    INTO v_s1, v_ua, v_s2, v_ub
    FROM usuario_sucursales us1
    JOIN perfiles p1   ON p1.id = us1.usuario_id AND p1.activo AND p1.rol = 'admin'
    JOIN sucursales s1 ON s1.id = us1.sucursal_id AND s1.activa
    JOIN usuario_sucursales us2 ON us2.sucursal_id <> us1.sucursal_id
    JOIN perfiles p2   ON p2.id = us2.usuario_id AND p2.activo
    JOIN sucursales s2 ON s2.id = us2.sucursal_id AND s2.activa
   WHERE public._rol_en_sucursal(us1.usuario_id, us1.sucursal_id) = 'admin'
     AND public._rol_en_sucursal(us2.usuario_id, us2.sucursal_id) IN ('admin', 'encargado')
   ORDER BY us1.sucursal_id, us1.usuario_id, us2.sucursal_id, us2.usuario_id
   LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hacen falta un admin de una sucursal y un admin o encargado de otra';
  END IF;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text, p_stock int, p_cpp numeric)
  RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real,
                                  costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES (p_nombre, 100, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, p_suc) RETURNING id;
  $f$;

  CREATE FUNCTION pg_temp.lote(p_prod bigint, p_venc date, p_cant int, p_resta int, p_compra bigint DEFAULT NULL)
  RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante,
                                       compra_id, origen)
    SELECT p_prod, p.sucursal_id, p_venc, p_cant, p_resta, p_compra,
           CASE WHEN p_compra IS NULL THEN 'manual' ELSE 'compra' END
      FROM public.productos p WHERE p.id = p_prod
    RETURNING id;
  $f$;

  -- Los lotes del producto en orden de vencimiento, la bolsa y el stock, en una línea.
  CREATE FUNCTION pg_temp.lotes(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('lotes=%s bolsa=%s stock=%s',
                  COALESCE((SELECT string_agg(cantidad_restante::text, ',' ORDER BY fecha_vencimiento, id)
                              FROM public.producto_lotes WHERE producto_id = p_prod), '-'),
                  p.stock - COALESCE((SELECT sum(cantidad_restante) FROM public.producto_lotes
                                       WHERE producto_id = p_prod), 0),
                  p.stock)
      FROM public.productos p WHERE p.id = p_prod;
  $f$;

  -- Cuánto lleva registrado el envío de cada lote, en orden de vencimiento.
  CREATE FUNCTION pg_temp.registro(p_mov bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(l.cantidad::text, ',' ORDER BY l.fecha_vencimiento, l.id), '-')
      FROM public.movimiento_sucursal_item_lotes l
      JOIN public.movimiento_sucursal_items i ON i.id = l.item_id
     WHERE i.movimiento_id = p_mov;
  $f$;

  CREATE FUNCTION pg_temp.enviar(p_dest bigint, p_prod bigint, p_cant int) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    v := public.crear_movimiento_sucursal(p_dest, 'ensayo 483',
           jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant)));
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'el envío no salió: %', v;
    END IF;
    RETURN (v->>'movimiento_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.ok(p_que text, v jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    IF NOT COALESCE((v->>'success')::boolean, (v->>'ok')::boolean, false) THEN
      RAISE EXCEPTION '% no pasó: %', p_que, v;
    END IF;
    RETURN v;
  END $f$;

  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(e || jsonb_build_object(
             'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
             'subtotal', round((e->>'cantidad')::numeric * (e->>'costo_unitario')::numeric, 2))
             ORDER BY o)
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o);
  $f$;

  CREATE FUNCTION pg_temp.comprar(p_admin uuid, p_ref text, p_prod bigint, p_cant int, p_costo numeric)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(jsonb_build_array(jsonb_build_object(
                     'producto_id', p_prod, 'cantidad', p_cant, 'costo_unitario', p_costo)));
    v_sub numeric := p_cant * p_costo;
    v_r   jsonb;
  BEGIN
    v_r := public.registrar_compra_completa(
      NULL, 'ENSAYO 483', 'ENSAYO-483-' || p_ref, public._tablero_hoy(),
      v_sub, 0, 0, v_sub, 'efectivo', 'ensayo 483', p_admin, v_lin, 'ZZ');
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra % no se registró: %', p_ref, v_r;
    END IF;
    RETURN (v_r->>'compra_id')::bigint;
  END $f$;

  -- NC de devolución de una compra ZZ, con los importes que calcula el server (costo × cantidad).
  CREATE FUNCTION pg_temp.nc(p_admin uuid, p_compra bigint, p_prod bigint, p_cant int) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_costo numeric := (SELECT sum(cantidad * costo_unitario) / sum(cantidad) FROM public.compra_items
                         WHERE compra_id = p_compra AND producto_id = p_prod);
    v_sub   numeric := round(p_cant * v_costo, 2);
  BEGIN
    RETURN pg_temp.ok('la NC', public.registrar_nota_credito(
      p_compra, 'NC-483-' || p_compra || '-' || p_cant, 'ensayo 483', v_sub, 0, v_sub, p_admin,
      jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'subtotal', v_sub)), 0));
  END $f$;

  CREATE FUNCTION pg_temp.cpp(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(round(costo_promedio, 4)::text, 'NULL') FROM public.productos WHERE id = p_prod;
  $f$;

  -- Un envío de p_cant de un producto de S2 a costo p_cpp, aceptado en S1 sobre p_dest, con la hora de
  -- aceptación fijada a mano (acá todo nace en la misma transacción).
  CREATE FUNCTION pg_temp.ingreso(p_s2 bigint, p_ub uuid, p_s1 bigint, p_ua uuid, p_dest bigint,
                                  p_cant int, p_cpp numeric, p_hora timestamptz) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_o    bigint := pg_temp.producto(p_s2, 'ZZ ensayo 483 origen ' || p_dest, p_cant, p_cpp);
    v_mov  bigint;
    v_item bigint;
  BEGIN
    PERFORM pg_temp.como(p_ub, p_s2);
    v_mov := pg_temp.enviar(p_s1, v_o, p_cant);
    SELECT id INTO v_item FROM public.movimiento_sucursal_items WHERE movimiento_id = v_mov;
    PERFORM pg_temp.como(p_ua, p_s1);
    PERFORM pg_temp.ok('aceptar', public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
      'item_id', v_item, 'accion', 'match_existente', 'producto_destino_id', p_dest))));
    UPDATE public.movimientos_sucursal SET resuelto_at = p_hora WHERE id = v_mov;
    RETURN v_item;
  END $f$;

  -- ================================================================ STK-1 ===
  -- E1 · el ejemplo de #1516
  BEGIN
    PERFORM pg_temp.como(v_ua, v_s1);
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 E1', 100, 10);
    PERFORM pg_temp.lote(v_p, v_hoy + 30, 60, 40);
    v_mov := pg_temp.enviar(v_s2, v_p, 30);
    v_t := pg_temp.lotes(v_p) || ' reg=' || pg_temp.registro(v_mov);
    IF v_t IS DISTINCT FROM 'lotes=40 bolsa=30 stock=70 reg=-' THEN
      v_fallas := v_fallas || ('E1 el envío dejó ' || v_t);
    END IF;
    PERFORM pg_temp.ok('cancelar', public.cancelar_movimiento_sucursal(v_mov, 'ensayo 483'));
    v_t := pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM 'lotes=40 bolsa=60 stock=100' THEN
      v_fallas := v_fallas || ('E1 cancelar dejó ' || v_t || ' (tiene que ser lotes=40 bolsa=60)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('E1 ' || SQLERRM);
  END;

  -- E2 · denegar devuelve a cada lote lo suyo
  BEGIN
    PERFORM pg_temp.como(v_ua, v_s1);
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 E2', 50, 10);
    PERFORM pg_temp.lote(v_p, v_hoy + 10, 30, 10);
    PERFORM pg_temp.lote(v_p, v_hoy + 40, 40, 40);
    v_mov := pg_temp.enviar(v_s2, v_p, 30);
    v_t := pg_temp.lotes(v_p) || ' reg=' || pg_temp.registro(v_mov);
    IF v_t IS DISTINCT FROM 'lotes=0,20 bolsa=0 stock=20 reg=10,20' THEN
      v_fallas := v_fallas || ('E2 el envío dejó ' || v_t);
    END IF;
    PERFORM pg_temp.como(v_ub, v_s2);
    PERFORM pg_temp.ok('denegar', public.denegar_movimiento_sucursal(v_mov, 'ensayo 483'));
    v_t := pg_temp.lotes(v_p) || ' reg=' || pg_temp.registro(v_mov);
    IF v_t IS DISTINCT FROM 'lotes=10,40 bolsa=0 stock=50 reg=-' THEN
      v_fallas := v_fallas || ('E2 denegar dejó ' || v_t || ' (tiene que ser lotes=10,40)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('E2 ' || SQLERRM);
  END;

  -- E3 · achicar dos veces y cancelar
  BEGIN
    PERFORM pg_temp.como(v_ua, v_s1);
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 E3', 100, 10);
    PERFORM pg_temp.lote(v_p, v_hoy + 10, 50, 20);
    v_mov := pg_temp.enviar(v_s2, v_p, 90);
    v_t := pg_temp.lotes(v_p) || ' reg=' || pg_temp.registro(v_mov);
    IF v_t IS DISTINCT FROM 'lotes=10 bolsa=0 stock=10 reg=10' THEN
      v_fallas := v_fallas || ('E3 el envío dejó ' || v_t);
    END IF;
    PERFORM pg_temp.ok('editar a 85', public.editar_movimiento_sucursal(v_mov, 'ensayo 483',
      jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 85))));
    v_t := pg_temp.lotes(v_p) || ' reg=' || pg_temp.registro(v_mov);
    IF v_t IS DISTINCT FROM 'lotes=10 bolsa=5 stock=15 reg=10' THEN
      v_fallas := v_fallas || ('E3 achicar a 85 dejó ' || v_t || ' (tiene que ser lotes=10 bolsa=5 reg=10)');
    END IF;
    PERFORM pg_temp.ok('editar a 5', public.editar_movimiento_sucursal(v_mov, 'ensayo 483',
      jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 5))));
    v_t := pg_temp.lotes(v_p) || ' reg=' || pg_temp.registro(v_mov);
    IF v_t IS DISTINCT FROM 'lotes=15 bolsa=80 stock=95 reg=5' THEN
      v_fallas := v_fallas || ('E3 achicar a 5 dejó ' || v_t || ' (tiene que ser lotes=15 bolsa=80 reg=5)');
    END IF;
    PERFORM pg_temp.ok('cancelar', public.cancelar_movimiento_sucursal(v_mov, 'ensayo 483'));
    v_t := pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM 'lotes=20 bolsa=80 stock=100' THEN
      v_fallas := v_fallas || ('E3 cancelar dejó ' || v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('E3 ' || SQLERRM);
  END;

  -- E4 · el lote del registro ya no existe
  BEGIN
    PERFORM pg_temp.como(v_ua, v_s1);
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 E4', 40, 10);
    v_l1 := pg_temp.lote(v_p, v_hoy + 10, 40, 40);
    v_mov := pg_temp.enviar(v_s2, v_p, 10);
    DELETE FROM public.producto_lotes WHERE id = v_l1;
    PERFORM pg_temp.ok('cancelar', public.cancelar_movimiento_sucursal(v_mov, 'ensayo 483'));
    v_t := pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM 'lotes=- bolsa=40 stock=40' THEN
      v_fallas := v_fallas || ('E4 cancelar dejó ' || v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('E4 ' || SQLERRM);
  END;

  -- ================================================================ STK-4 ===
  PERFORM pg_temp.como(v_ua, v_s1);

  -- N1 · el ejemplo de #1516
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 N1', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'N1', v_p, 100, 20);
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.nc(v_ua, v_c, v_p, 100);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p) || ' stock=' || (SELECT stock FROM productos WHERE id = v_p);
    IF v_t IS DISTINCT FROM '15.0000 → 10.0000 stock=100' THEN
      v_fallas := v_fallas || ('N1 ' || v_t || ' (tiene que volver a 10)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('N1 ' || SQLERRM);
  END;

  -- N2 · en dos notas
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 N2', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'N2', v_p, 100, 20);
    PERFORM pg_temp.nc(v_ua, v_c, v_p, 50);
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.nc(v_ua, v_c, v_p, 50);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    IF v_t IS DISTINCT FROM '13.3333 → 10.0000' THEN
      v_fallas := v_fallas || ('N2 ' || v_t || ' (tiene que ser 13.3333 → 10.0000)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('N2 ' || SQLERRM);
  END;

  -- N3 · con una compra posterior
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 N3', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'N3a', v_p, 100, 20);
    v_c2 := pg_temp.comprar(v_ua, 'N3b', v_p, 50, 30);
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.nc(v_ua, v_c, v_p, 100);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p) || ' foto=' ||
           (SELECT stock_anterior || '/' || round(costo_promedio_anterior, 4) FROM compra_items WHERE compra_id = v_c2);
    IF v_t IS DISTINCT FROM '18.0000 → 16.6667 foto=100/10.0000' THEN
      v_fallas := v_fallas || ('N3 ' || v_t || ' (tiene que ser 18 → 16.6667 y la foto 100/10)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('N3 ' || SQLERRM);
  END;

  -- N4 · la NC por lote
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 N4', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'N4', v_p, 100, 20);
    v_l1 := pg_temp.lote(v_p, v_hoy + 30, 100, 100, v_c);
    v_j := public.registrar_nota_credito_lote(v_l1, 40, 'NC-483-N4', 'ensayo 483');
    v_t := pg_temp.cpp(v_p) || ' ' || pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM '13.7500 lotes=60 bolsa=100 stock=160' THEN
      v_fallas := v_fallas || ('N4 ' || v_t || ' (tiene que ser 13.7500) ' || v_j::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('N4 ' || SQLERRM);
  END;

  -- N5 · compra sin foto
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 N5', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'N5', v_p, 100, 20);
    UPDATE compra_items SET costo_promedio_anterior = NULL WHERE compra_id = v_c;
    v_j := pg_temp.nc(v_ua, v_c, v_p, 50);
    v_t := pg_temp.cpp(v_p) || ' aviso=' || COALESCE(v_j->'warnings'->0->>'motivo', '-');
    IF v_t IS DISTINCT FROM '15.0000 aviso=sin_cpp_previo' THEN
      v_fallas := v_fallas || ('N5 ' || v_t || ' ' || v_j::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('N5 ' || SQLERRM);
  END;

  -- N6 · la NC de ajuste
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 N6', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'N6', v_p, 100, 20);
    PERFORM pg_temp.ok('la NC de ajuste', public.registrar_nota_credito(
      v_c, 'NC-483-N6', 'ensayo 483: descuento', 100, 0, 100, v_ua, '[]'::jsonb, 0));
    v_t := pg_temp.cpp(v_p) || ' stock=' || (SELECT stock FROM productos WHERE id = v_p);
    IF v_t IS DISTINCT FROM '15.0000 stock=200' THEN
      v_fallas := v_fallas || ('N6 ' || v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('N6 ' || SQLERRM);
  END;

  -- ================================================================ STK-5 ===
  -- R1 · anular con un envío aceptado después
  BEGIN
    PERFORM pg_temp.como(v_ua, v_s1);
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 R1', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'R1', v_p, 100, 20);
    UPDATE compra_items SET created_at = now() - interval '2 hours' WHERE compra_id = v_c;
    v_item := pg_temp.ingreso(v_s2, v_ub, v_s1, v_ua, v_p, 50, 30, now() - interval '1 hour');
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.ok('anular', public.anular_compra_atomica(v_c, v_ua));
    v_t := v_t || ' → ' || pg_temp.cpp(v_p) || ' foto=' ||
           (SELECT stock_destino_anterior || '→' || stock_destino_nuevo FROM movimiento_sucursal_items WHERE id = v_item);
    IF v_t IS DISTINCT FROM '18.0000 → 16.6667 foto=100→150' THEN
      v_fallas := v_fallas || ('R1 ' || v_t || ' (tiene que ser 18 → 16.6667 y la foto 100→150)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('R1 ' || SQLERRM);
  END;

  -- R2 · anular la primera compra con un envío después
  BEGIN
    PERFORM pg_temp.como(v_ua, v_s1);
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 R2', 0, NULL);
    v_c := pg_temp.comprar(v_ua, 'R2', v_p, 100, 20);
    UPDATE compra_items SET created_at = now() - interval '2 hours' WHERE compra_id = v_c;
    v_item := pg_temp.ingreso(v_s2, v_ub, v_s1, v_ua, v_p, 50, 30, now() - interval '1 hour');
    v_t := pg_temp.cpp(v_p) || ' c0=' || COALESCE((SELECT costo_promedio_anterior::text FROM compra_items WHERE compra_id = v_c), 'NULL');
    PERFORM pg_temp.ok('anular', public.anular_compra_atomica(v_c, v_ua));
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    IF v_t NOT LIKE '23.3333 c0=% → 30.0000' THEN
      v_fallas := v_fallas || ('R2 ' || v_t || ' (tiene que terminar en 30, no en NULL)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('R2 ' || SQLERRM);
  END;

  -- R3 · editar con un envío después
  BEGIN
    PERFORM pg_temp.como(v_ua, v_s1);
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 R3', 100, 10);
    v_c := pg_temp.comprar(v_ua, 'R3', v_p, 100, 20);
    UPDATE compra_items SET created_at = now() - interval '2 hours' WHERE compra_id = v_c;
    v_item := pg_temp.ingreso(v_s2, v_ub, v_s1, v_ua, v_p, 50, 30, now() - interval '1 hour');
    PERFORM pg_temp.como(v_ua, v_s1);
    v_j := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 50, 'costo_unitario', 20)));
    PERFORM pg_temp.ok('editar la compra', public.actualizar_compra_items(
      v_c, v_j, 1000, 0, 1000, v_ua, p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb,
      p_renglones_vistos => (SELECT array_agg(id) FROM public.compra_items WHERE compra_id = v_c)));
    v_t := pg_temp.cpp(v_p) || ' foto=' ||
           (SELECT stock_destino_anterior::text FROM movimiento_sucursal_items WHERE id = v_item);
    IF v_t IS DISTINCT FROM '17.5000 foto=150' THEN
      v_fallas := v_fallas || ('R3 ' || v_t || ' (tiene que ser 17.5000 y la foto 150)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('R3 ' || SQLERRM);
  END;

  -- =============================================================== STK-10 ===
  PERFORM pg_temp.como(v_ua, v_s1);

  -- V1 y V2 · la merma por vencimiento sale del lote vencido
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 V1', 100, 10);
    PERFORM pg_temp.lote(v_p, v_hoy - 5, 30, 30);
    PERFORM pg_temp.lote(v_p, v_hoy + 30, 30, 30);
    PERFORM pg_temp.ok('la merma', public.registrar_merma_manual(v_p, 20, 'vencimiento', 'ensayo 483'));
    v_t := pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM 'lotes=10,30 bolsa=40 stock=80' THEN
      v_fallas := v_fallas || ('V1 ' || v_t || ' (tiene que ser lotes=10,30 bolsa=40)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('V1 ' || SQLERRM);
  END;
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 V2', 100, 10);
    PERFORM pg_temp.lote(v_p, v_hoy - 5, 30, 30);
    PERFORM pg_temp.lote(v_p, v_hoy + 30, 30, 30);
    PERFORM pg_temp.ok('la merma', public.registrar_merma_manual(v_p, 50, 'vencimiento', 'ensayo 483'));
    v_t := pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM 'lotes=0,30 bolsa=20 stock=50' THEN
      v_fallas := v_fallas || ('V2 ' || v_t || ' (tiene que ser lotes=0,30 bolsa=20)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('V2 ' || SQLERRM);
  END;

  -- V3 · una rotura no toca los lotes
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 V3', 100, 10);
    PERFORM pg_temp.lote(v_p, v_hoy - 5, 30, 30);
    PERFORM pg_temp.lote(v_p, v_hoy + 30, 30, 30);
    PERFORM pg_temp.ok('la merma', public.registrar_merma_manual(v_p, 10, 'rotura', 'ensayo 483'));
    v_t := pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM 'lotes=30,30 bolsa=30 stock=90' THEN
      v_fallas := v_fallas || ('V3 ' || v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('V3 ' || SQLERRM);
  END;

  -- V4 · un lote que vence hoy no está vencido
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 483 V4', 100, 10);
    PERFORM pg_temp.lote(v_p, v_hoy, 30, 30);
    PERFORM pg_temp.ok('la merma', public.registrar_merma_manual(v_p, 10, 'vencimiento', 'ensayo 483'));
    v_t := pg_temp.lotes(v_p);
    IF v_t IS DISTINCT FROM 'lotes=30 bolsa=60 stock=90' THEN
      v_fallas := v_fallas || ('V4 ' || v_t);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('V4 ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · E1 E2 E3 E4 N1 N2 N3 N4 N5 N6 R1 R2 R3 V1 V2 V3 V4';
END
$ensayo$;
