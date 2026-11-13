-- Ensayo de la migración del arrastre con NC y del piso de la fecha de carga
-- (reauditoría final del 12/11: STK-11 de #1542 y GTO-A de #1545).
--
-- Corre contra prod SIN dejar rastro (salvo valores de secuencia): un único DO que termina SIEMPRE
-- en una excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN
-- y el COMMIT; después, solo. Cada caso usa sus propios productos.
--
-- Personas (salen de la base): un admin activo de una sucursal activa. El rubro de los gastos, el
-- empleado y el chofer los crea el ensayo. Las compras son ZZ: el costo
-- real es el costo unitario. Todas nacen en la misma transacción (misma hora): el orden de la
-- cadena lo da el id de la compra.
--
-- STK-11 · el arrastre recorre cada compra posterior con lo que le queda después de sus NC.
-- El producto arranca con 50 u. a 8. B es la compra anterior (100 a 10 → 9,3333) y A la
-- posterior (100 a 20 → 13,6).
--   A1 · NC de 50 de A → 12; se anula B → 14 (50 a 8 + 50 a 20). Antes: 14,4. La foto de A pasa a
--        50 u. a 8.
--   A2 · NC de 50 de A → 12; el costo de B pasa de 10 a 12 → 13. Antes: 12,8.
--   A3 · NC de 50 de A → 12; NC de las 100 de B → 14. Antes: 14,4.
--   A4 · NC de las 100 de A → 9,3333; se anula B → 8 (sólo quedan las 50 a 8). Antes: 11,7333.
--   A5 · A con dos renglones del mismo producto (60 a 20 y 40 a 30 → 15,2); NC de 50 de A → 13; se
--        anula B → 16 (50 a 8 + 30 a 20 + 20 a 30). Antes: 16,4667.
--   A6 · regresión, sin NC: 100 a 10; A 100 a 20 → 15; C 50 a 30 → 18; se anula A → 16,6667.
-- GTO-A · la fecha de un gasto, de un movimiento de empleado y del pago de una liquidación va hasta
-- 60 días antes de hoy.
--   G1 · un gasto de hace 61 días no entra; uno de hace 60, sí.
--   G2 · un gasto viejo (90 días) se corrige sin tocarle la fecha; cambiársela a 61 días atrás no
--        entra, y a 10 días atrás, sí.
--   G3 · un movimiento de empleado de hace 61 días no entra; uno de hace 60, sí.
--   G4 · liquidar con la fecha del pago 61 días atrás no entra, con pago y sin pago; con la de hoy, sí.
--   G5 · el pago que sale de una rendición lleva el día de esa rendición y no tiene piso: con una
--        rendición de hace 70 días no lo frena el piso (lo frena el saldo, que viene después). Si la
--        rendición no se puede usar (un día ya cerrado), el caso queda sin ensayar y el veredicto
--        lo dice. El mismo pago desde la oficina, con esa fecha, no entra.
--   L1 · los permisos: el helper es de server y las RPCs conservan su EXECUTE.
-- Regresión que pasa con y sin la migración: A6.
--
-- Sin la migración tiene que FALLAR en A1–A5, G1–G5 y L1.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   psql "$DATABASE_URL" -f scripts/test-arrastre-nc-y-piso-de-fecha-1542-1545.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_ua     uuid;
  v_hoy    date := public._tablero_hoy();
  v_p      bigint;
  v_b      bigint;
  v_a      bigint;
  v_c      bigint;
  v_rubro  bigint;
  v_g      bigint;
  v_e      bigint;
  v_tr     uuid;
  v_j      jsonb;
  v_t      text;
  v_notas  text := '';
  v_piso   text := 'no puede ser anterior al ' || to_char(public._tablero_hoy() - 60, 'DD/MM/YYYY');
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------- personas ---
  SELECT us.sucursal_id, us.usuario_id INTO v_s1, v_ua
    FROM usuario_sucursales us
    JOIN perfiles p   ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de una sucursal activa';
  END IF;
  -- El rubro es del ensayo: así corre igual en una base sin rubros cargados.
  INSERT INTO gasto_rubros (nombre, grupo) VALUES ('ZZ ensayo 1545 ' || gen_random_uuid(), 'otros')
  RETURNING id INTO v_rubro;
  PERFORM set_config('e1542.ua', v_ua::text, true);
  PERFORM set_config('e1542.s1', v_s1::text, true);
  PERFORM set_config('e1542.rubro', v_rubro::text, true);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.claims(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  -- Una RPC como el front: con el rol authenticated.
  CREATE FUNCTION pg_temp.como(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM pg_temp.claims(current_setting('e1542.ua')::uuid, current_setting('e1542.s1')::bigint);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  END $f$;

  -- '' si la RPC falla con el mensaje esperado; si no, lo que pasó.
  CREATE FUNCTION pg_temp.falla(p_que text, p_sql text, p_espera text) RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_sql);
    EXCEPTION WHEN SQLSTATE 'P0098' THEN RAISE;
      WHEN OTHERS THEN
        IF position(p_espera IN SQLERRM) > 0 THEN
          RETURN '{}';
        END IF;
        RETURN ARRAY[format('%s: falló con otro mensaje: %s (esperado: %s)', p_que, SQLERRM, p_espera)];
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RETURN ARRAY[format('%s: anduvo y tenía que fallar', p_que)];
  END $f$;

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  CREATE FUNCTION pg_temp.ok(p_que text, v jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    IF NOT COALESCE((v->>'success')::boolean, (v->>'ok')::boolean, false) THEN
      RAISE EXCEPTION '% no pasó: %', p_que, v;
    END IF;
    RETURN v;
  END $f$;

  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text, p_stock int, p_cpp numeric)
  RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real,
                                  costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES (p_nombre, 100, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, p_suc) RETURNING id;
  $f$;

  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(e || jsonb_build_object(
             'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0,
             'subtotal', round((e->>'cantidad')::numeric * (e->>'costo_unitario')::numeric, 2))
             ORDER BY o)
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o);
  $f$;

  -- Una compra ZZ con los renglones de p_items ([{producto_id, cantidad, costo_unitario}]).
  CREATE FUNCTION pg_temp.comprar(p_ref text, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(p_items);
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(v_lin) e);
    v_r   jsonb;
  BEGIN
    v_r := public.registrar_compra_completa(
      NULL, 'ENSAYO 1542', 'ENSAYO-1542-' || p_ref, public._tablero_hoy(),
      v_sub, 0, 0, v_sub, 'efectivo', 'ensayo 1542', current_setting('e1542.ua')::uuid, v_lin, 'ZZ');
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra % no se registró: %', p_ref, v_r;
    END IF;
    RETURN (v_r->>'compra_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.comprar1(p_ref text, p_prod bigint, p_cant int, p_costo numeric) RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.comprar(p_ref, jsonb_build_array(jsonb_build_object(
             'producto_id', p_prod, 'cantidad', p_cant, 'costo_unitario', p_costo)));
  $f$;

  -- NC de devolución de una compra ZZ, con los importes que calcula el server (costo × cantidad).
  CREATE FUNCTION pg_temp.nc(p_compra bigint, p_prod bigint, p_cant int) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_costo numeric := (SELECT sum(cantidad * costo_unitario) / sum(cantidad) FROM public.compra_items
                         WHERE compra_id = p_compra AND producto_id = p_prod);
    v_sub   numeric := round(p_cant * v_costo, 2);
  BEGIN
    RETURN pg_temp.ok('la NC', public.registrar_nota_credito(
      p_compra, 'NC-1542-' || p_compra || '-' || p_cant, 'ensayo 1542', v_sub, 0, v_sub,
      current_setting('e1542.ua')::uuid,
      jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'subtotal', v_sub)), 0));
  END $f$;

  CREATE FUNCTION pg_temp.anular(p_compra bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.ok('anular', public.anular_compra_atomica(p_compra, current_setting('e1542.ua')::uuid));
  END $f$;

  CREATE FUNCTION pg_temp.cpp(p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(round(costo_promedio, 4)::text, 'NULL') FROM public.productos WHERE id = p_prod;
  $f$;

  -- guardar_gasto como ModalGasto, desde la oficina, con lo que cambie p.
  CREATE FUNCTION pg_temp.gg(p jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)',
      jsonb_build_object('sucursal_id', current_setting('e1542.s1')::bigint, 'compartido', false,
                         'fecha', public._tablero_hoy(), 'rubro_id', current_setting('e1542.rubro')::bigint,
                         'monto_total', 1000, 'comprobante', 'ninguno', 'comprobante_numero', NULL,
                         'vehiculo_id', NULL, 'repartir_meses', 1, 'origen_pago', 'oficina',
                         'observacion', 'ensayo 1545') || p);
  $f$;

  -- El alta de un empleado como ModalEmpleado: sueldo semanal desde p_desde.
  CREATE FUNCTION pg_temp.alta(p_desde date) RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ e1545 ' || gen_random_uuid(), 'puesto', 'preventista',
      'sucursal_id', current_setting('e1542.s1')::bigint, 'de_las_dos', false,
      'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', NULL, 'cliente_id', NULL, 'vehiculo_id', NULL,
      'arreglo', jsonb_build_object('vigente_desde', p_desde, 'sueldo', 70000, 'frecuencia', 'semanal', 'comisiona', false),
      'saldo_inicial', NULL)))::bigint;
  $f$;

  CREATE FUNCTION pg_temp.mov(p_emp bigint, p jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_movimiento_empleado(p_empleado_id => %s, p_movimiento => %L::jsonb)', p_emp, p);
  $f$;

  -- Liquida el próximo período como ModalLiquidar, pagando p_pago desde la oficina con fecha p_fecha.
  CREATE FUNCTION pg_temp.lq(p_emp bigint, p_pago numeric, p_fecha date) RETURNS text LANGUAGE sql AS $f$
    SELECT format(
      'SELECT public.liquidar_empleado(p_empleado_id => %s, p_liquidacion => %L::jsonb)', p_emp,
      jsonb_build_object('desde', v#>>'{periodo,desde}', 'hasta', v#>>'{periodo,hasta}',
                         'sueldo', (v#>>'{sueldo,propuesto}')::numeric, 'motivo_sueldo', NULL, 'pago', p_pago,
                         'fecha_pago', p_fecha, 'a_pagar_esperado', (v->>'a_pagar')::numeric,
                         'origen_pago', 'oficina', 'rendicion_transportista_id', NULL, 'rendicion_fecha', NULL))
      FROM (SELECT pg_temp.como(format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', p_emp))::jsonb AS v) x;
  $f$;

  IF cardinality(pg_temp.falla('canario', 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'otro mensaje')) <> 1
     OR pg_temp.como('SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_ua, v_s1)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  -- =============================================================== STK-11 ===
  PERFORM pg_temp.claims(v_ua, v_s1);

  -- A1 · se anula la compra anterior a una que tiene una NC
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1542 A1', 50, 8);
    v_b := pg_temp.comprar1('A1b', v_p, 100, 10);
    v_a := pg_temp.comprar1('A1a', v_p, 100, 20);
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.nc(v_a, v_p, 50);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    PERFORM pg_temp.anular(v_b);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p) || ' foto=' ||
           (SELECT stock_anterior || '/' || round(costo_promedio_anterior, 4) FROM compra_items WHERE compra_id = v_a);
    IF v_t IS DISTINCT FROM '13.6000 → 12.0000 → 14.0000 foto=50/8.0000' THEN
      v_fallas := v_fallas || ('A1 ' || v_t || ' (tiene que ser 13.6 → 12 → 14 y la foto 50/8)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('A1 ' || SQLERRM);
  END;

  -- A2 · se corrige el costo de la compra anterior
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1542 A2', 50, 8);
    v_b := pg_temp.comprar1('A2b', v_p, 100, 10);
    v_a := pg_temp.comprar1('A2a', v_p, 100, 20);
    PERFORM pg_temp.nc(v_a, v_p, 50);
    v_t := pg_temp.cpp(v_p);
    v_j := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 100, 'costo_unitario', 12)));
    PERFORM pg_temp.ok('editar la compra', public.actualizar_compra_items(
      v_b, v_j, 1200, 0, 1200, v_ua, p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb,
      p_renglones_vistos => (SELECT array_agg(id) FROM public.compra_items WHERE compra_id = v_b)));
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    IF v_t IS DISTINCT FROM '12.0000 → 13.0000' THEN
      v_fallas := v_fallas || ('A2 ' || v_t || ' (tiene que ser 12 → 13)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('A2 ' || SQLERRM);
  END;

  -- A3 · una NC sobre la compra anterior
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1542 A3', 50, 8);
    v_b := pg_temp.comprar1('A3b', v_p, 100, 10);
    v_a := pg_temp.comprar1('A3a', v_p, 100, 20);
    PERFORM pg_temp.nc(v_a, v_p, 50);
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.nc(v_b, v_p, 100);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    IF v_t IS DISTINCT FROM '12.0000 → 14.0000' THEN
      v_fallas := v_fallas || ('A3 ' || v_t || ' (tiene que ser 12 → 14)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('A3 ' || SQLERRM);
  END;

  -- A4 · la compra posterior se devolvió entera
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1542 A4', 50, 8);
    v_b := pg_temp.comprar1('A4b', v_p, 100, 10);
    v_a := pg_temp.comprar1('A4a', v_p, 100, 20);
    PERFORM pg_temp.nc(v_a, v_p, 100);
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.anular(v_b);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    IF v_t IS DISTINCT FROM '9.3333 → 8.0000' THEN
      v_fallas := v_fallas || ('A4 ' || v_t || ' (tiene que ser 9.3333 → 8)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('A4 ' || SQLERRM);
  END;

  -- A5 · la compra posterior tiene dos renglones del mismo producto
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1542 A5', 50, 8);
    v_b := pg_temp.comprar1('A5b', v_p, 100, 10);
    v_a := pg_temp.comprar('A5a', jsonb_build_array(
             jsonb_build_object('producto_id', v_p, 'cantidad', 60, 'costo_unitario', 20),
             jsonb_build_object('producto_id', v_p, 'cantidad', 40, 'costo_unitario', 30)));
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.nc(v_a, v_p, 50);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    PERFORM pg_temp.anular(v_b);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p);
    IF v_t IS DISTINCT FROM '15.2000 → 13.0000 → 16.0000' THEN
      v_fallas := v_fallas || ('A5 ' || v_t || ' (tiene que ser 15.2 → 13 → 16)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('A5 ' || SQLERRM);
  END;

  -- A6 · regresión: sin NC el arrastre da lo de siempre
  BEGIN
    v_p := pg_temp.producto(v_s1, 'ZZ ensayo 1542 A6', 100, 10);
    v_a := pg_temp.comprar1('A6a', v_p, 100, 20);
    v_c := pg_temp.comprar1('A6c', v_p, 50, 30);
    v_t := pg_temp.cpp(v_p);
    PERFORM pg_temp.anular(v_a);
    v_t := v_t || ' → ' || pg_temp.cpp(v_p) || ' foto=' ||
           (SELECT stock_anterior || '/' || round(costo_promedio_anterior, 4) FROM compra_items WHERE compra_id = v_c);
    IF v_t IS DISTINCT FROM '18.0000 → 16.6667 foto=100/10.0000' THEN
      v_fallas := v_fallas || ('A6 ' || v_t || ' (tiene que ser 18 → 16.6667 y la foto 100/10)');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('A6 ' || SQLERRM);
  END;

  -- ================================================================ GTO-A ===
  -- G1 · el gasto nuevo
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('G1 un gasto de hace 61 días',
                  pg_temp.gg(jsonb_build_object('fecha', v_hoy - 61)), 'La fecha del gasto ' || v_piso);
    v_g := pg_temp.como(pg_temp.gg(jsonb_build_object('fecha', v_hoy - 60)))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT fecha FROM gastos WHERE id = v_g) = v_hoy - 60, 'G1 un gasto de hace 60 días entra');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('G1 ' || SQLERRM);
  END;

  -- G2 · un gasto viejo se corrige sin tocarle la fecha
  BEGIN
    v_g := pg_temp.como(pg_temp.gg('{}'::jsonb))::bigint;
    RESET ROLE;
    UPDATE gastos SET fecha = v_hoy - 90, mes_imputado = date_trunc('month', (v_hoy - 90)::timestamp)::date WHERE id = v_g;
    PERFORM pg_temp.como(pg_temp.gg(jsonb_build_object(
      'id', v_g, 'fecha', v_hoy - 90, 'monto_total', 2000,
      'mes_imputado', date_trunc('month', (v_hoy - 90)::timestamp)::date)));
    v_fallas := v_fallas || pg_temp.chk((SELECT monto_total = 2000 AND fecha = v_hoy - 90 FROM gastos WHERE id = v_g),
                  'G2 el gasto viejo se corrige sin tocar la fecha');
    v_fallas := v_fallas || pg_temp.falla('G2 cambiarle la fecha a 61 días atrás',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'fecha', v_hoy - 61, 'monto_total', 2000)),
                  'La fecha del gasto ' || v_piso);
    PERFORM pg_temp.como(pg_temp.gg(jsonb_build_object('id', v_g, 'fecha', v_hoy - 10, 'monto_total', 2000)));
    v_fallas := v_fallas || pg_temp.chk((SELECT fecha FROM gastos WHERE id = v_g) = v_hoy - 10, 'G2 cambiarle la fecha a 10 días atrás entra');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('G2 ' || SQLERRM);
  END;

  -- G3 · el movimiento de un empleado
  BEGIN
    v_e := pg_temp.alta(v_hoy - 14);
    v_fallas := v_fallas || pg_temp.falla('G3 un ajuste de hace 61 días',
                  pg_temp.mov(v_e, jsonb_build_object('tipo', 'ajuste', 'monto', 5000, 'observacion', 'ensayo 1545', 'fecha', v_hoy - 61)),
                  'La fecha del movimiento ' || v_piso);
    PERFORM pg_temp.como(pg_temp.mov(v_e, jsonb_build_object('tipo', 'ajuste', 'monto', 5000, 'observacion', 'ensayo 1545', 'fecha', v_hoy - 60)));
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM empleado_movimientos WHERE empleado_id = v_e AND tipo = 'ajuste' AND fecha = v_hoy - 60),
                  'G3 un ajuste de hace 60 días entra');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('G3 ' || SQLERRM);
  END;

  -- G5 · el pago que sale de una rendición (antes de G4: usa el saldo a favor de G3)
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('G5 un pago de la oficina de hace 70 días',
                  pg_temp.mov(v_e, jsonb_build_object('tipo', 'pago', 'monto', 100, 'fecha', v_hoy - 70,
                    'origen_pago', 'oficina', 'rendicion_transportista_id', NULL, 'rendicion_fecha', NULL)),
                  'La fecha del movimiento ' || v_piso);
    v_tr := gen_random_uuid();
    RESET ROLE;
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v_tr, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1545-' || v_tr || '@ensayo.invalid',
            jsonb_build_object('rol', 'transportista', 'sucursal_id', v_s1), '{}', now(), now());
    BEGIN
      -- Más que el saldo (5.000): si el piso no frena, lo frena el tope del saldo, que viene después.
      PERFORM pg_temp.como(pg_temp.mov(v_e, jsonb_build_object('tipo', 'pago', 'monto', 999999, 'fecha', v_hoy,
                'origen_pago', 'rendicion', 'rendicion_transportista_id', v_tr, 'rendicion_fecha', v_hoy - 70)));
      RESET ROLE;
      v_fallas := v_fallas || 'G5 el pago de más que el saldo entró';
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      IF position('no puede ser anterior al' IN SQLERRM) > 0 THEN
        v_fallas := v_fallas || ('G5 el piso frenó un pago que sale de una rendición: ' || SQLERRM);
      ELSIF position('más de lo que se le debe' IN SQLERRM) = 0 THEN
        v_notas := v_notas || ' · G5 sin ensayar (la rendición de hace 70 días no se puede usar: ' || SQLERRM || ')';
      END IF;
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('G5 ' || SQLERRM);
  END;

  -- G4 · el pago de una liquidación
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('G4 liquidar con el pago de hace 61 días',
                  pg_temp.lq(v_e, 100, v_hoy - 61), 'La fecha del pago ' || v_piso);
    v_fallas := v_fallas || pg_temp.falla('G4 liquidar sin pago con la fecha de hace 61 días',
                  pg_temp.lq(v_e, 0, v_hoy - 61), 'La fecha del pago ' || v_piso);
    PERFORM pg_temp.como(pg_temp.lq(v_e, 100, v_hoy));
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM empleado_liquidaciones WHERE empleado_id = v_e AND fecha_pago = v_hoy),
                  'G4 liquidar con la fecha de hoy entra');
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('G4 ' || SQLERRM);
  END;

  -- =================================================================== L1 ===
  RESET ROLE;
  v_fallas := v_fallas || pg_temp.chk(
    to_regprocedure('public._fecha_carga_validar_piso(date,text)') IS NOT NULL
    AND NOT has_function_privilege('authenticated', 'public._fecha_carga_validar_piso(date,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public._fecha_carga_validar_piso(date,text)', 'EXECUTE'),
    'L1 el helper del piso no existe o no es sólo de server');
  v_fallas := v_fallas || pg_temp.chk(
    NOT has_function_privilege('authenticated', 'public._cpp_arrastrar(bigint,bigint,bigint,timestamp with time zone,integer,numeric,numeric)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public._guardar_gasto(jsonb,boolean)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.registrar_movimiento_empleado(bigint,jsonb)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.liquidar_empleado(bigint,jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.registrar_movimiento_empleado(bigint,jsonb)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.liquidar_empleado(bigint,jsonb)', 'EXECUTE'),
    'L1 los permisos de las funciones cambiaron');

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · A1 A2 A3 A4 A5 A6 G1 G2 G3 G4 G5 L1%', v_notas;
END
$ensayo$;
