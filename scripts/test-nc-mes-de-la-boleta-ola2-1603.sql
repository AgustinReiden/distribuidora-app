-- Ensayo de la tarjeta B16 de la ola 2 del plan #1603: la nota de crédito de venta se imputa al mes de su
-- boleta, y resta de las comisiones y de las metas (decisiones del dueño del 16/11, en #1545 y #1551).
-- Migración: NNN_nc_mes_de_la_boleta.
--
-- Un único DO con datos propios (una sucursal nueva, un preventista V, sus clientes, productos, boletas y
-- notas) que termina SIEMPRE en una excepción: no deja rastro (salvo valores de secuencia).
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista.
--
-- Los datos, en la sucursal S. F es el día 10 del mes pasado (un mes ya cerrado); las notas se emiten hoy.
--   P1 · ZZ, C1, vendedor V, del día F: A×10 a 100 y B×4 a 50 (1.200).
--   P2 · ZZ, C2, vendedor V, del día F+1: A×5 a 100 (500).
--   NC1 · por la RPC, sobre P1: A×2 (200).               NC2 · por la RPC, sobre P1: B×1 (50), y se anula.
--   NC3 · cargada por el server sobre P2 con la fecha de hoy y sin renglón de la boleta (pedido_item_id NULL,
--         como queda cuando la edición rehace las líneas): A×1 (100).
--   La venta de V en el mes de F: 1.700 por boleta, 1.400 neta de las notas vigentes (200 + 100).
--
--   F  · Decisión 1, la nota se imputa al mes de su boleta:
--        F1 la RPC deja la nota con la fecha de la boleta y la devuelve; created_at es hoy; el crédito
--           (los pagos con su nota_credito_id) queda con la fecha de hoy: la plata no cambia de día.
--        F2 una nota cargada con otra fecha toma la de su boleta (el freno está en la tabla).
--        F3 un UPDATE de la fecha de una nota no la saca de la de su boleta.
--        F4 la posición fiscal del mes de la boleta resta las notas (300 de ZZ) y la del mes de hoy no.
--        F5 cambiar la fecha de la boleta arrastra sus notas, vigentes y anuladas.
--   C  · Decisión 2, la nota resta de la comisión (_comision_lineas, la única):
--        C1 calcular_comisiones del mes de F: V con base 1.400 y comisión 28 (2 %), 3 ítems (los renglones
--           de las boletas, no los de las notas).
--        C2 por renglón: la clave de A en P1 da 800, la de B 200 (la NC2 anulada no resta), la de A en P2
--           400 (la NC3 sin renglón cae en el renglón del mismo producto).
--        C3 el gerencial: kpis.base_comision y vendedores[V].base_nc, 1.400.
--   L  · La liquidación (libro de deltas): un empleado de V que comisiona.
--        L1 sin nada liquidado, las líneas iniciales suman base 1.400 y comisión 28.
--        L2 liquidado eso, una nota nueva sobre P2 (A×1, 100) sale como un ajuste de −100 de base y −2 de
--           comisión, con el motivo de la nota; L3 liquidado el ajuste, anular esa nota devuelve +100 / +2.
--   M  · Decisión 2, la nota resta de las metas:
--        M1 avance_metas_preventista: la meta de facturación de V en el mes de F logra 1.400; la de unidades
--           de A sigue en 15 (la nota resta plata, no unidades: la regla de _ventas_nc).
--        M2 rendimiento_preventistas: V vende 1.400 con 19 unidades y 2 pedidos; por marca y por rubro también.
--   B  · El bot: bot_mis_ventas y bot_ventas_periodo dan 1.400 (C1 1.000 y C2 400; A facturó 1.200) y el
--        resumen del preventista lo hereda; las claves de los JSON no cambian.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-nc-mes-de-la-boleta-ola2-1603.sql

DO $ensayo$
DECLARE
  v_hoy     date := public._tablero_hoy();
  v_mes     date := (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date;
  v_finmes  date := (date_trunc('month', public._tablero_hoy()) - interval '1 day')::date;
  v_f       date := (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date + 9;
  v_adm     uuid := '00000000-0000-0000-0000-0000000004e7';
  v_s       bigint;
  v_ven     uuid;
  v_c1      bigint;
  v_c2      bigint;
  v_a       bigint;
  v_b       bigint;
  v_p1      bigint;
  v_p2      bigint;
  v_i1a     bigint;
  v_i1b     bigint;
  v_i2      bigint;
  v_nc1     bigint;
  v_nc2     bigint;
  v_nc3     bigint;
  v_nc4     bigint;
  v_emp     bigint;
  v_liq     bigint;
  v_r       jsonb;
  v_j       jsonb;
  v_x       jsonb;
  v_t       text;
  v_n       numeric;
  v_m       numeric;
  v_fallas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b16-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'B16 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  -- Corre p_sql como p_uid (authenticated, parado en p_suc) y devuelve su resultado; un error sale tal cual.
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE x text;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO x;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.headers', '', true);
    RETURN x;
  END $f$;
  CREATE FUNCTION pg_temp.igual(a numeric, b numeric) RETURNS boolean LANGUAGE sql AS $f$
    SELECT a IS NOT NULL AND b IS NOT NULL AND abs(a - b) < 0.005
  $f$;
  CREATE FUNCTION pg_temp.fila(p jsonb, p_campo text, p_valor text) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT e FROM jsonb_array_elements(COALESCE(p, '[]'::jsonb)) e WHERE e->>p_campo IS NOT DISTINCT FROM p_valor LIMIT 1
  $f$;
  CREATE FUNCTION pg_temp.suma(p jsonb, p_campo text) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum((e->>p_campo)::numeric), 0) FROM jsonb_array_elements(COALESCE(p, '[]'::jsonb)) e
  $f$;
  -- Las claves de un JSON, ordenadas: la forma que no puede cambiar.
  CREATE FUNCTION pg_temp.claves(p jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(p) k
  $f$;
  -- La NC por la RPC, como el front (admin parado en la sucursal de la boleta).
  CREATE FUNCTION pg_temp.nc(p_adm uuid, p_ped bigint, p_item bigint, p_cant int) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_adm, (SELECT sucursal_id FROM pedidos WHERE id = p_ped), format(
      'SELECT public.crear_nota_credito_venta(%s, %s, %L::jsonb, %L, %L, %L::uuid)::text',
      p_ped, (SELECT cliente_id FROM pedidos WHERE id = p_ped),
      jsonb_build_array(jsonb_build_object('pedido_item_id', p_item, 'cantidad', p_cant)),
      'producto_vencido', 'ensayo B16', gen_random_uuid()))::jsonb;
  $f$;
  CREATE FUNCTION pg_temp.anular(p_adm uuid, p_nc bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_adm, (SELECT sucursal_id FROM notas_credito_venta WHERE id = p_nc), format(
      'SELECT public.anular_nota_credito_venta(%s, %L)::text', p_nc, 'ensayo B16'))::jsonb;
  $f$;
  -- Congela en el libro lo que la liquidación liquidaría hoy (lo que hace liquidar_empleado con
  -- _liquidacion_lineas), con una liquidación hecha p_hace antes: así lo que pase después es "después".
  CREATE FUNCTION pg_temp.congelar(p_emp bigint, p_desde date, p_hasta date, p_hace interval) RETURNS bigint
  LANGUAGE plpgsql AS $f$
  DECLARE v_id bigint; e empleados;
  BEGIN
    SELECT * INTO e FROM empleados WHERE id = p_emp;
    INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                        saldo_anterior, a_pagar, pagado, fecha_pago, creado_por, created_at)
    VALUES (p_emp, p_desde, p_hasta, 'mensual', e.sucursal_id, false, 0, 0, 0, public._tablero_hoy(),
            '00000000-0000-0000-0000-0000000004e7', now() - p_hace)
    RETURNING id INTO v_id;
    INSERT INTO empleado_liquidacion_lineas (liquidacion_id, empleado_id, pedido_id, usuario_id, clave, producto_id,
                                             combo_id, origen_precio, regla_id, pct, base, comision, tipo, motivo,
                                             entregado_el)
    SELECT v_id, p_emp, l.pedido_id, l.usuario_id, l.clave, l.producto_id, l.combo_id, l.origen_precio, l.regla_id,
           l.pct, l.base, l.comision, l.tipo, l.motivo, l.entregado_el
      FROM public._liquidacion_lineas(e, p_hasta) l;
    RETURN v_id;
  END $f$;

  -- ------------------------------------------------------------------- datos -
  INSERT INTO sucursales (nombre) VALUES ('B16 ensayo ' || left(gen_random_uuid()::text, 8)) RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, v_s) ON CONFLICT DO NOTHING;
  v_ven := pg_temp.u('preventista', v_s);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B16 uno', 'B16 uno', 'Calle 1', v_s) RETURNING id INTO v_c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B16 dos', 'B16 dos', 'Calle 2', v_s) RETURNING id INTO v_c2;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('B16 A', 100, 1000, 60, v_s) RETURNING id INTO v_a;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('B16 B', 50, 1000, 30, v_s) RETURNING id INTO v_b;

  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal,
                       retiro_deposito, tipo_factura)
    VALUES (v_c1, v_s, v_ven, 1200, 'entregado', v_f, (v_f + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires',
            'app', true, 'ZZ') RETURNING id INTO v_p1;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
    VALUES (v_p1, v_a, 10, 100, 1000, v_s, 60) RETURNING id INTO v_i1a;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
    VALUES (v_p1, v_b, 4, 50, 200, v_s, 30) RETURNING id INTO v_i1b;

  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal,
                       retiro_deposito, tipo_factura)
    VALUES (v_c2, v_s, v_ven, 500, 'entregado', v_f + 1, (v_f + 1 + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires',
            'app', true, 'ZZ') RETURNING id INTO v_p2;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
    VALUES (v_p2, v_a, 5, 100, 500, v_s, 60) RETURNING id INTO v_i2;

  -- El empleado de V, que comisiona desde antes del mes de F.
  INSERT INTO empleados (nombre, puesto, sucursal_id, usuario_id, creado_por)
    VALUES ('B16 vendedor', 'preventista', v_s, v_ven, v_adm) RETURNING id INTO v_emp;
  INSERT INTO empleado_arreglos (empleado_id, vigente_desde, sueldo, frecuencia, comisiona, creado_por)
    VALUES (v_emp, v_mes - 31, 0, 'mensual', true, v_adm);

  -- L1 · antes de toda nota, para tener con qué comparar: 1.700 por boleta.
  SELECT COALESCE(sum(base), 0) INTO v_n FROM public._liquidacion_lineas((SELECT e FROM empleados e WHERE e.id = v_emp), v_finmes);
  IF NOT pg_temp.igual(v_n, 1700) THEN
    v_fallas := v_fallas || format('L0 sin notas la base inicial es 1700: dio %s', v_n);
  END IF;

  -- ------------------------------------------------------------- las notas -
  v_r := pg_temp.nc(v_adm, v_p1, v_i1a, 2);
  v_nc1 := (v_r->>'nota_credito_id')::bigint;
  v_j := pg_temp.nc(v_adm, v_p1, v_i1b, 1);
  v_nc2 := (v_j->>'nota_credito_id')::bigint;
  PERFORM pg_temp.anular(v_adm, v_nc2);
  -- La NC3, como la deja el server sin pasar por la RPC, con la fecha de hoy y sin renglón.
  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (v_s, v_c2, v_p2, v_hoy, 'producto_vencido', 100, v_adm, 100, 0) RETURNING id INTO v_nc3;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc3, v_s, NULL, v_a, 1, 100, 100);
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, nota_credito_id)
    VALUES (v_c2, NULL, v_s, 100, 'nota_credito', v_hoy, v_adm, v_nc3);

  -- ============================================================ F · la fecha
  IF (SELECT fecha FROM notas_credito_venta WHERE id = v_nc1) IS DISTINCT FROM v_f
     OR (v_r->>'fecha')::date IS DISTINCT FROM v_f THEN
    v_fallas := v_fallas || format('F1 la NC1 se imputa al día de su boleta (%s): quedó %s y la RPC dijo %s',
      v_f, (SELECT fecha FROM notas_credito_venta WHERE id = v_nc1), v_r->>'fecha');
  END IF;
  IF (SELECT (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date FROM notas_credito_venta WHERE id = v_nc1)
       IS DISTINCT FROM v_hoy
     OR EXISTS (SELECT 1 FROM pagos WHERE nota_credito_id = v_nc1 AND fecha IS DISTINCT FROM v_hoy)
     OR NOT EXISTS (SELECT 1 FROM pagos WHERE nota_credito_id = v_nc1) THEN
    v_fallas := v_fallas || format('F1b la NC1 se creó hoy y su crédito es de hoy: %s',
      (SELECT jsonb_agg(jsonb_build_object('id', id, 'fecha', fecha)) FROM pagos WHERE nota_credito_id = v_nc1));
  END IF;
  IF (SELECT fecha FROM notas_credito_venta WHERE id = v_nc3) IS DISTINCT FROM v_f + 1 THEN
    v_fallas := v_fallas || format('F2 una nota cargada con la fecha de hoy toma la de su boleta (%s): quedó %s',
      v_f + 1, (SELECT fecha FROM notas_credito_venta WHERE id = v_nc3));
  END IF;
  UPDATE notas_credito_venta SET fecha = v_hoy WHERE id = v_nc1;
  IF (SELECT fecha FROM notas_credito_venta WHERE id = v_nc1) IS DISTINCT FROM v_f THEN
    v_fallas := v_fallas || format('F3 la fecha de una nota no se mueve de la de su boleta: quedó %s',
      (SELECT fecha FROM notas_credito_venta WHERE id = v_nc1));
  END IF;
  v_j := public.posicion_fiscal(v_s, v_mes, v_finmes);
  v_x := public.posicion_fiscal(v_s, date_trunc('month', v_hoy)::date, v_hoy);
  IF NOT pg_temp.igual((v_j#>>'{ventas,nc_zz_monto}')::numeric, 300)
     OR NOT pg_temp.igual((v_j#>>'{ventas,zz_venta}')::numeric, 1400)
     OR NOT pg_temp.igual((v_x#>>'{ventas,nc_zz_monto}')::numeric, 0) THEN
    v_fallas := v_fallas || format('F4 la posición fiscal del mes de la boleta resta 300 (ZZ 1400) y la de hoy 0: %s, %s y %s',
      v_j#>>'{ventas,nc_zz_monto}', v_j#>>'{ventas,zz_venta}', v_x#>>'{ventas,nc_zz_monto}');
  END IF;

  -- ======================================================== C · la comisión
  v_j := pg_temp.como(v_adm, v_s, format('SELECT public.calcular_comisiones(%L::date, %L::date, ARRAY[%s]::bigint[])::text',
                                         v_mes, v_finmes, v_s))::jsonb;
  v_x := pg_temp.fila(v_j->'preventistas', 'id', v_ven::text);
  IF NOT pg_temp.igual((v_x->>'base')::numeric, 1400) OR NOT pg_temp.igual((v_x->>'comision')::numeric, 28)
     OR (v_x->>'items')::int IS DISTINCT FROM 3 THEN
    v_fallas := v_fallas || format('C1 calcular_comisiones: V con base 1400, comisión 28 y 3 ítems: %s', v_x);
  END IF;
  SELECT COALESCE(sum(base) FILTER (WHERE pedido_id = v_p1 AND producto_id = v_a), -1),
         COALESCE(sum(base) FILTER (WHERE pedido_id = v_p2 AND producto_id = v_a), -1)
    INTO v_n, v_m
    FROM public._comision_lineas(ARRAY[v_p1, v_p2]);
  IF NOT pg_temp.igual(v_n, 800) OR NOT pg_temp.igual(v_m, 400)
     OR NOT pg_temp.igual((SELECT sum(base) FROM public._comision_lineas(ARRAY[v_p1]) WHERE producto_id = v_b), 200) THEN
    v_fallas := v_fallas || format('C2 por renglón: A de P1 800, B de P1 200 (la anulada no resta), A de P2 400: %s, %s, %s',
      v_n, (SELECT sum(base) FROM public._comision_lineas(ARRAY[v_p1]) WHERE producto_id = v_b), v_m);
  END IF;
  v_j := public.reporte_gerencial(v_s, v_mes, v_finmes);
  IF NOT pg_temp.igual((v_j#>>'{kpis,base_comision}')::numeric, 1400)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'vendedores', 'id', v_ven::text)->>'base_nc')::numeric, 1400)
     OR NOT pg_temp.igual((v_j#>>'{kpis,venta}')::numeric, 1400) THEN
    v_fallas := v_fallas || format('C3 el gerencial del mes de F: base de comisión 1400, la de V 1400 y la venta 1400: %s, %s, %s',
      v_j#>>'{kpis,base_comision}', pg_temp.fila(v_j->'vendedores', 'id', v_ven::text)->>'base_nc', v_j#>>'{kpis,venta}');
  END IF;

  -- ===================================================== L · la liquidación
  SELECT COALESCE(sum(base), 0), COALESCE(sum(comision), 0), count(*) FILTER (WHERE tipo <> 'inicial')
    INTO v_n, v_m, v_liq
    FROM public._liquidacion_lineas((SELECT e FROM empleados e WHERE e.id = v_emp), v_finmes);
  IF NOT pg_temp.igual(v_n, 1400) OR NOT pg_temp.igual(v_m, 28) OR v_liq <> 0 THEN
    v_fallas := v_fallas || format('L1 lo inicial suma base 1400 y comisión 28, sin ajustes: %s, %s, %s', v_n, v_m, v_liq);
  END IF;
  PERFORM pg_temp.congelar(v_emp, v_mes, v_finmes, interval '2 hours');

  v_j := pg_temp.nc(v_adm, v_p2, v_i2, 1);
  v_nc4 := (v_j->>'nota_credito_id')::bigint;
  SELECT jsonb_agg(to_jsonb(l)) INTO v_x
    FROM public._liquidacion_lineas((SELECT e FROM empleados e WHERE e.id = v_emp), v_finmes) l;
  IF jsonb_array_length(COALESCE(v_x, '[]')) <> 1
     OR v_x->0->>'tipo' IS DISTINCT FROM 'ajuste'
     OR (v_x->0->>'pedido_id')::bigint IS DISTINCT FROM v_p2
     OR NOT pg_temp.igual((v_x->0->>'base')::numeric, -100)
     OR NOT pg_temp.igual((v_x->0->>'comision')::numeric, -2)
     OR v_x->0->>'motivo' NOT ILIKE '%nota de crédito%' THEN
    v_fallas := v_fallas || format('L2 una nota después de liquidar sale como ajuste de −100 / −2 con su motivo: %s', v_x);
  END IF;
  PERFORM pg_temp.congelar(v_emp, v_finmes + 1, v_finmes + 1, interval '1 hour');

  PERFORM pg_temp.anular(v_adm, v_nc4);
  SELECT jsonb_agg(to_jsonb(l)) INTO v_x
    FROM public._liquidacion_lineas((SELECT e FROM empleados e WHERE e.id = v_emp), v_finmes) l;
  IF jsonb_array_length(COALESCE(v_x, '[]')) <> 1
     OR v_x->0->>'tipo' IS DISTINCT FROM 'ajuste'
     OR NOT pg_temp.igual((v_x->0->>'base')::numeric, 100)
     OR NOT pg_temp.igual((v_x->0->>'comision')::numeric, 2)
     OR v_x->0->>'motivo' NOT ILIKE '%anul%nota de crédito%' THEN
    v_fallas := v_fallas || format('L3 anular la nota devuelve +100 / +2 con su motivo: %s', v_x);
  END IF;

  -- ============================================================ M · las metas
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo)
    VALUES (v_s, v_ven, v_mes, v_finmes, 'facturacion', 5000);
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo, producto_ids)
    VALUES (v_s, v_ven, v_mes, v_finmes, 'unidades', 50, ARRAY[v_a]);
  v_j := public.avance_metas_preventista(v_ven, v_mes);
  IF NOT pg_temp.igual((pg_temp.fila(v_j->'metas', 'tipo_meta', 'facturacion')->>'logrado')::numeric, 1400)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'metas', 'tipo_meta', 'unidades')->>'logrado')::numeric, 15) THEN
    v_fallas := v_fallas || format('M1 la meta de facturación logra 1400 y la de unidades de A 15: %s', v_j->'metas');
  END IF;
  v_j := pg_temp.como(v_adm, v_s, format('SELECT public.rendimiento_preventistas(%s, %L::date)::text', v_s, v_mes))::jsonb;
  v_x := pg_temp.fila(v_j->'preventistas', 'preventista_id', v_ven::text);
  IF NOT pg_temp.igual((v_x->>'venta')::numeric, 1400) OR NOT pg_temp.igual((v_x->>'unidades')::numeric, 19)
     OR (v_x->>'pedidos')::int IS DISTINCT FROM 2
     OR NOT pg_temp.igual(pg_temp.suma(v_x->'por_marca', 'venta'), 1400)
     OR NOT pg_temp.igual(pg_temp.suma(v_x->'por_categoria', 'venta'), 1400)
     OR NOT pg_temp.igual(pg_temp.suma(v_x->'por_categoria', 'unidades'), 19)
     OR NOT pg_temp.igual((v_x->>'margen_comercial')::numeric, 1700 - 1020 - 300)
     OR NOT pg_temp.igual((pg_temp.fila(v_x->'metas', 'tipo_meta', 'facturacion')->>'logrado')::numeric, 1400) THEN
    v_fallas := v_fallas || format('M2 rendimiento: V vende 1400, 19 u., 2 pedidos, margen 380 (1700 − 1020 de costo − 300 de notas), por marca y rubro 1400: %s', v_x);
  END IF;

  -- =============================================================== B · el bot
  v_j := public.bot_mis_ventas(v_ven, v_mes, v_finmes, v_s, 10)::jsonb;
  IF NOT pg_temp.igual((v_j->>'total_ventas')::numeric, 1400)
     OR NOT pg_temp.igual((v_j->>'ticket_promedio')::numeric, 700)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'top_clientes', 'cliente_id', v_c1::text)->>'total_comprado')::numeric, 1000)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'top_clientes', 'cliente_id', v_c2::text)->>'total_comprado')::numeric, 400)
     OR pg_temp.claves(v_j) IS DISTINCT FROM 'clientes_distintos,desde,hasta,pedidos_count,preventista_id,ticket_promedio,top_clientes,total_ventas' THEN
    v_fallas := v_fallas || format('B1 bot_mis_ventas: 1400, ticket 700, C1 1000 y C2 400, mismas claves: %s', v_j);
  END IF;
  v_j := public.bot_ventas_periodo(v_mes, v_finmes, v_s, 10)::jsonb;
  IF NOT pg_temp.igual((v_j->>'total_ventas')::numeric, 1400)
     OR NOT pg_temp.igual((v_j->>'ticket_promedio')::numeric, 700)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'top_clientes', 'id', v_c1::text)->>'total_comprado')::numeric, 1000)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'top_productos', 'id', v_a::text)->>'facturado')::numeric, 1200)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'top_productos', 'id', v_a::text)->>'unidades')::numeric, 15)
     OR pg_temp.claves(v_j) IS DISTINCT FROM 'desde,en_curso_monto,en_curso_pedidos,hasta,pedidos_count,ticket_promedio,top_clientes,top_productos,total_ventas' THEN
    v_fallas := v_fallas || format('B2 bot_ventas_periodo: 1400, ticket 700, C1 1000, A 1200 con 15 u., mismas claves: %s', v_j);
  END IF;
  v_j := public.bot_digest_preventista(v_ven, v_s, v_finmes)::jsonb;
  IF NOT pg_temp.igual((v_j#>>'{mis_ventas,mes_total}')::numeric, 1400) THEN
    v_fallas := v_fallas || format('B3 el resumen del preventista: el mes en 1400: %s', v_j->'mis_ventas');
  END IF;

  -- ======================================================= F5 · el arrastre
  UPDATE pedidos SET fecha = v_f + 2 WHERE id = v_p1;
  IF EXISTS (SELECT 1 FROM notas_credito_venta WHERE pedido_id = v_p1 AND fecha IS DISTINCT FROM v_f + 2)
     OR (SELECT count(*) FROM notas_credito_venta WHERE pedido_id = v_p1) <> 2 THEN
    v_fallas := v_fallas || format('F5 la fecha de la boleta arrastra sus dos notas (la vigente y la anulada) al %s: %s',
      v_f + 2, (SELECT jsonb_agg(jsonb_build_object('id', id, 'fecha', fecha, 'anulada', anulada))
                  FROM notas_credito_venta WHERE pedido_id = v_p1));
  END IF;

  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = PG_EXCEPTION_CONTEXT;
    v_fallas := v_fallas || format('el ensayo cortó: %s %s (%s)', SQLSTATE, SQLERRM, left(v_t, 400));
  END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · B16: la NC se imputa al mes de su boleta y resta de comisiones, liquidación, metas y bot';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · % caso(s):\n  - %', cardinality(v_fallas), array_to_string(v_fallas, E'\n  - ');
END
$ensayo$;
