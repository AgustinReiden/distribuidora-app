-- Ensayo de la tarjeta B16 de la ola 2 del plan #1603 (v3): la nota de crédito de venta se imputa al mes
-- de su boleta; tiene motivos, y le descuenta al vendedor según el motivo y sin ir hacia atrás
-- (decisiones del dueño del 16/11 en #1545 y #1551, y del 17/11 en la ficha B16 v3).
-- Migración: NNN_nc_mes_de_la_boleta.
--
-- Un único DO con datos propios (una sucursal nueva, sus vendedores, clientes, productos, boletas y notas)
-- que termina SIEMPRE en una excepción: no deja rastro (salvo valores de secuencia).
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Los tiempos los mide aparte
-- scripts/tiempos-nc-mes-de-la-boleta-ola2-1603.sql.
--
-- F es el día 10 del mes pasado (un mes cerrado); H, hoy. Las notas se emiten hoy, por la RPC (el admin)
-- salvo donde se dice. Toda boleta es A×10 a 100 (1.000) salvo donde se dice. Producto A: costo 60.
--
--   F · LA FECHA (decisión 1, sin cambios desde la v2)
--     F1 la RPC deja la nota con la fecha de la boleta y la devuelve; created_at es hoy; su crédito, hoy.
--     F2 una nota cargada por el server con la fecha de hoy toma la de su boleta.
--     F3 un UPDATE de la fecha de la nota no la saca de la de su boleta.
--     F5 cambiar la fecha de la boleta arrastra sus notas, vigentes y anuladas.
--   T · LOS MOTIVOS: siete boletas de V del día F, una nota de A×2 (200) con cada motivo.
--     T1 descuentan al vendedor cliente_rechaza, error_pedido y descuento_comercial (resta_comision y la
--        respuesta de la RPC); los otros cuatro no. Cada boleta comisiona 800 o 1.000.
--     T2 calcular_comisiones del mes de F: V con base 6.400 (7.000 − 3 × 200).
--     T3 la venta no depende del motivo: el gerencial resta las siete (V vende 5.600) y su base de
--        comisión resta tres (6.400); la posición fiscal del mes resta toda nota vigente.
--     T4 (v4, decisión del dueño del 18/11) Rendimiento va con su foto: las notas de T se emiten hoy,
--        fuera del mes de su boleta, y no lo tocan: V vende 7.000 y 70 unidades en el mes de F.
--     T4b dos de esas notas, como emitidas dentro del mes de F (resta_rendimiento): 6.600 y 68 u. (el
--        descuento comercial resta plata y no unidades); anular la de rechazo con el mes cerrado no lo mueve.
--     T5 un motivo que no está en la lista lo rechazan la RPC y la tabla.
--   M · LAS METAS de V del mes en curso (facturación 100.000 y unidades de A 1.000), con cuatro boletas
--       de hoy: cliente_rechaza A×3 (300), descuento_comercial A×1 (100), producto_vencido A×2 (no
--       descuenta) y error_pedido A×1 (100) que se anula en el mes y sin cumplir.
--     M1 facturación 3.600 y unidades 37; la foto: dos filas de la de rechazo, una del descuento.
--     M2 Rendimiento del mes (notas emitidas en el mes de su boleta: restan): 3.600 y 37 unidades; la
--        comisión de las cuatro, 3.600; su venta en el bot,
--        3.400 (toda nota vigente resta).
--     M3 fuera del mes: las metas de V del mes de F (facturación 100.000, unidades 1.000) no ven las
--        notas de T, emitidas hoy: 7.000 y 70.
--   C · CUMPLIDA: V2, meta 500, boleta de hoy de 1.000: ya cumplida, la nota de rechazo (200) no la
--       toca (sigue en 1.000) y sí resta de la comisión (800).
--   A · ANULAR: V3, meta del mes de 1.500. Boleta S1 de hoy con una nota de rechazo (200): la meta en
--       800. S2 de hoy: 1.800, cumplida. Una meta nueva de V3, desde el mes pasado hasta hoy, nace después
--       de esa nota y no la ve (2.000). S0 del día F con una nota de error de pedido (100): esa meta en
--       2.900. Anular la de S1 con la meta cumplida no la mueve (1.800). La meta nueva pasa a terminar
--       ayer (fuera del mes) y anular la de S0 no la mueve (900, no 1.000).
--   L · LA LIQUIDACIÓN: V4, que comisiona (sin metas).
--     L1 T1 del día F liquidada; después una nota de rechazo: no resta (resta_comision false), 1.000.
--     L2 T2 con una nota de rechazo (800); se liquida; se anula la nota: sigue en 800.
--     L3 T3 con una nota de rechazo que se anula antes de liquidar: vuelve a 1.000.
--     L4 lo que queda por liquidar es sólo T3 (1.000) y no hay ningún ajuste.
--     L5 (v4) anulada la liquidación que congelaba T2 (con su nota anulada), la nota deja de restar: 1.000.
--   G · (v4) una nota no cambia de motivo ni vuelve a estar vigente (los dos UPDATE se rechazan).
--   Las carreras de la nota y la liquidación (H1 de la revisión de la v3) piden dos sesiones: las prueba
--   scripts/concurrencia/b16-nota-y-liquidacion.sh.
--   D · EL ADELANTO DE SUELDO va sobre la venta neta: V5, U1 con una nota de rechazo (200) que paga la
--       boleta y 800 de adelanto: base 0; U2 con una de vencido (no descuenta) y 800 de adelanto: 200
--       (sobre el total). El gerencial da lo mismo: 200.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-nc-mes-de-la-boleta-ola2-1603.sql

DO $ensayo$
DECLARE
  v_hoy     date := public._tablero_hoy();
  v_mes     date := (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date;
  v_finmes  date := (date_trunc('month', public._tablero_hoy()) - interval '1 day')::date;
  v_mesh    date := date_trunc('month', public._tablero_hoy())::date;
  v_finh    date := (date_trunc('month', public._tablero_hoy()) + interval '1 month - 1 day')::date;
  v_f       date := (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date + 9;
  v_adm     uuid := '00000000-0000-0000-0000-0000000004e7';
  v_s       bigint;
  v_ven     uuid;
  v_v2      uuid;
  v_v3      uuid;
  v_v4      uuid;
  v_v5      uuid;
  v_c1      bigint;
  v_c9      bigint;
  v_a       bigint;
  v_p       bigint;
  v_p2      bigint;
  v_i       bigint;
  v_nc      bigint;
  v_nc2     bigint;
  v_emp     bigint;
  v_liq     bigint;
  v_m       bigint;
  v_m2      bigint;
  v_r       jsonb;
  v_j       jsonb;
  v_x       jsonb;
  v_t       text;
  v_t2      text;
  v_n       numeric;
  v_k       int;
  v_mot     text;
  v_mot_metas text;
  v_bol     bigint[] := '{}';
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
    BEGIN
      EXECUTE p_sql INTO x;
    EXCEPTION WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);
      PERFORM set_config('request.headers', '', true);
      RAISE;
    END;
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
  -- Una boleta entregada de p_ven, del día p_dia, con A×p_cant a 100. Devuelve su id.
  CREATE FUNCTION pg_temp.bol(p_ven uuid, p_cli bigint, p_dia date, p_cant int DEFAULT 10) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_id bigint; v_suc bigint; v_a bigint;
  BEGIN
    SELECT sucursal_id INTO v_suc FROM clientes WHERE id = p_cli;
    SELECT id INTO v_a FROM productos WHERE sucursal_id = v_suc AND nombre = 'B16 A';
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal,
                         retiro_deposito, tipo_factura)
      VALUES (p_cli, v_suc, p_ven, 100 * p_cant, 'entregado', p_dia,
              (p_dia + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'app', true, 'ZZ')
      RETURNING id INTO v_id;
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
      VALUES (v_id, v_a, p_cant, 100, 100 * p_cant, v_suc, 60);
    RETURN v_id;
  END $f$;
  -- La NC por la RPC, como el front (admin parado en la sucursal de la boleta): A×p_cant con p_motivo.
  CREATE FUNCTION pg_temp.nc(p_ped bigint, p_cant int, p_motivo text) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como('00000000-0000-0000-0000-0000000004e7', (SELECT sucursal_id FROM pedidos WHERE id = p_ped), format(
      'SELECT public.crear_nota_credito_venta(%s, %s, %L::jsonb, %L, %L, %L::uuid)::text',
      p_ped, (SELECT cliente_id FROM pedidos WHERE id = p_ped),
      jsonb_build_array(jsonb_build_object('pedido_item_id', (SELECT min(id) FROM pedido_items WHERE pedido_id = p_ped),
                                           'cantidad', p_cant)),
      p_motivo, 'ensayo B16', gen_random_uuid()))::jsonb;
  $f$;
  CREATE FUNCTION pg_temp.anular(p_nc bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como('00000000-0000-0000-0000-0000000004e7', (SELECT sucursal_id FROM notas_credito_venta WHERE id = p_nc), format(
      'SELECT public.anular_nota_credito_venta(%s, %L)::text', p_nc, 'ensayo B16'))::jsonb;
  $f$;
  CREATE FUNCTION pg_temp.base(p_ped bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(base), 0) FROM public._comision_lineas(ARRAY[p_ped])
  $f$;
  -- Lo logrado de una meta según avance_metas_preventista (como el server: sin usuario).
  CREATE FUNCTION pg_temp.logrado(p_ven uuid, p_periodo date, p_meta bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT (e->>'logrado')::numeric
      FROM jsonb_array_elements(public.avance_metas_preventista(p_ven, p_periodo)->'metas') e
     WHERE (e->>'id')::bigint = p_meta
  $f$;
  -- Congela en el libro lo que la liquidación liquidaría hoy (lo que hace liquidar_empleado con
  -- _liquidacion_lineas), con una liquidación hecha p_hace antes.
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
  v_v2 := pg_temp.u('preventista', v_s);
  v_v3 := pg_temp.u('preventista', v_s);
  v_v4 := pg_temp.u('preventista', v_s);
  v_v5 := pg_temp.u('preventista', v_s);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B16 uno', 'B16 uno', 'Calle 1', v_s) RETURNING id INTO v_c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B16 consumidor', 'B16 consumidor', 'Calle 9', v_s) RETURNING id INTO v_c9;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('B16 A', 100, 100000, 60, v_s) RETURNING id INTO v_a;

  -- =========================================================== F · la fecha
  -- Del admin, que en el ensayo no tiene metas ni comisión: no se mezcla con las cuentas de abajo.
  v_p := pg_temp.bol(v_adm, v_c1, v_f);
  v_r := pg_temp.nc(v_p, 1, 'otro');
  v_nc := (v_r->>'nota_credito_id')::bigint;
  IF (SELECT fecha FROM notas_credito_venta WHERE id = v_nc) IS DISTINCT FROM v_f
     OR (v_r->>'fecha')::date IS DISTINCT FROM v_f OR (v_r->>'creada_el')::date IS DISTINCT FROM v_hoy THEN
    v_fallas := v_fallas || format('F1 la nota se imputa al día de su boleta (%s) y se creó hoy: %s', v_f, v_r);
  END IF;
  IF EXISTS (SELECT 1 FROM pagos WHERE nota_credito_id = v_nc AND fecha IS DISTINCT FROM v_hoy)
     OR NOT EXISTS (SELECT 1 FROM pagos WHERE nota_credito_id = v_nc) THEN
    v_fallas := v_fallas || text 'F1b el crédito de la nota es de hoy';
  END IF;
  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (v_s, v_c1, v_p, v_hoy, 'otro', 100, v_adm, 100, 0) RETURNING id INTO v_nc2;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc2, v_s, NULL, v_a, 1, 100, 100);
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, nota_credito_id)
    VALUES (v_c1, NULL, v_s, 100, 'nota_credito', v_hoy, v_adm, v_nc2);
  IF (SELECT fecha FROM notas_credito_venta WHERE id = v_nc2) IS DISTINCT FROM v_f THEN
    v_fallas := v_fallas || text 'F2 una nota cargada con la fecha de hoy toma la de su boleta';
  END IF;
  UPDATE notas_credito_venta SET fecha = v_hoy WHERE id = v_nc;
  IF (SELECT fecha FROM notas_credito_venta WHERE id = v_nc) IS DISTINCT FROM v_f THEN
    v_fallas := v_fallas || text 'F3 la fecha de una nota no se mueve de la de su boleta';
  END IF;
  PERFORM pg_temp.anular(v_nc2);
  UPDATE pedidos SET fecha = v_f + 1 WHERE id = v_p;
  IF EXISTS (SELECT 1 FROM notas_credito_venta WHERE pedido_id = v_p AND fecha IS DISTINCT FROM v_f + 1)
     OR (SELECT count(*) FROM notas_credito_venta WHERE pedido_id = v_p) <> 2 THEN
    v_fallas := v_fallas || text 'F5 la fecha de la boleta arrastra sus dos notas (la vigente y la anulada)';
  END IF;
  -- ========================================================= T · los motivos
  -- Las metas de V del mes de F existen desde antes de las notas (para M3: fuera del mes).
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo)
    VALUES (v_s, v_ven, v_mes, v_finmes, 'facturacion', 100000) RETURNING id INTO v_m;
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo, producto_ids)
    VALUES (v_s, v_ven, v_mes, v_finmes, 'unidades', 1000, ARRAY[v_a]) RETURNING id INTO v_m2;
  v_t := v_m || ',' || v_m2;
  v_k := 0;
  FOREACH v_mot IN ARRAY ARRAY['cliente_rechaza', 'error_pedido', 'error_entrega', 'producto_vencido',
                                'producto_danado', 'descuento_comercial', 'otro'] LOOP
    v_k := v_k + 1;
    v_p := pg_temp.bol(v_ven, v_c1, v_f);
    v_bol := v_bol || v_p;
    BEGIN
      v_r := pg_temp.nc(v_p, 2, v_mot);
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('T1 %s: la RPC no lo aceptó: %s', v_mot, SQLERRM);
      CONTINUE;
    END;
    v_nc := (v_r->>'nota_credito_id')::bigint;
    IF (SELECT resta_comision FROM notas_credito_venta WHERE id = v_nc)
         IS DISTINCT FROM (v_mot IN ('cliente_rechaza', 'error_pedido', 'descuento_comercial'))
       OR (v_r->>'resta_comision')::boolean IS DISTINCT FROM (v_mot IN ('cliente_rechaza', 'error_pedido', 'descuento_comercial'))
       OR NOT pg_temp.igual(pg_temp.base(v_p),
                            CASE WHEN v_mot IN ('cliente_rechaza', 'error_pedido', 'descuento_comercial') THEN 800 ELSE 1000 END) THEN
      v_fallas := v_fallas || format('T1 %s: descuenta %s, resta_comision %s, la RPC %s, base %s',
        v_mot, v_mot IN ('cliente_rechaza', 'error_pedido', 'descuento_comercial'),
        (SELECT resta_comision FROM notas_credito_venta WHERE id = v_nc), v_r->>'resta_comision', pg_temp.base(v_p));
    END IF;
  END LOOP;

  v_j := pg_temp.como(v_adm, v_s, format('SELECT public.calcular_comisiones(%L::date, %L::date, ARRAY[%s]::bigint[])::text',
                                         v_mes, v_finmes, v_s))::jsonb;
  v_x := pg_temp.fila(v_j->'preventistas', 'id', v_ven::text);
  IF NOT pg_temp.igual((v_x->>'base')::numeric, 6400) OR NOT pg_temp.igual((v_x->>'comision')::numeric, 128) THEN
    v_fallas := v_fallas || format('T2 calcular_comisiones del mes de F: V con base 6400 y comisión 128: %s', v_x);
  END IF;

  v_j := public.reporte_gerencial(v_s, v_mes, v_finmes);
  v_x := pg_temp.fila(v_j->'vendedores', 'id', v_ven::text);
  v_n := (SELECT sum(n.total) FROM notas_credito_venta n JOIN pedidos p ON p.id = n.pedido_id
           WHERE n.sucursal_id = v_s AND NOT n.anulada AND p.fecha BETWEEN v_mes AND v_finmes);
  IF NOT pg_temp.igual((v_x->>'venta')::numeric, 5600) OR NOT pg_temp.igual((v_x->>'base_nc')::numeric, 6400)
     OR NOT pg_temp.igual((v_j#>>'{kpis,notas_credito_venta}')::numeric, v_n)
     OR NOT pg_temp.igual((v_j#>>'{kpis,venta}')::numeric, (v_j#>>'{kpis,venta_bruta}')::numeric - v_n) THEN
    v_fallas := v_fallas || format('T3 gerencial: V vende 5600 (todas las notas) y su base 6400 (las que descuentan); las notas del mes %s: %s / %s',
      v_n, v_x, v_j->'kpis');
  END IF;
  v_j := public.posicion_fiscal(v_s, v_mes, v_finmes);
  IF NOT pg_temp.igual((v_j#>>'{ventas,nc_zz_monto}')::numeric, v_n) THEN
    v_fallas := v_fallas || format('T3b la posición fiscal del mes resta toda nota vigente (%s): %s', v_n, v_j#>>'{ventas,nc_zz_monto}');
  END IF;

  -- T4 (decisión del dueño del 18/11): Rendimiento con su foto. Las notas de T se emiten hoy, fuera
  -- del mes de su boleta: ninguna resta del Rendimiento del mes de F, que queda en 7.000 y 70 u.
  v_j := pg_temp.como(v_adm, v_s, format('SELECT public.rendimiento_preventistas(%s, %L::date)::text', v_s, v_mes))::jsonb;
  v_x := pg_temp.fila(v_j->'preventistas', 'preventista_id', v_ven::text);
  IF NOT pg_temp.igual((v_x->>'venta')::numeric, 7000) OR NOT pg_temp.igual((v_x->>'unidades')::numeric, 70)
     OR NOT pg_temp.igual(pg_temp.suma(v_x->'por_categoria', 'unidades'), 70)
     OR EXISTS (SELECT 1 FROM notas_credito_venta WHERE pedido_id = ANY(v_bol) AND resta_rendimiento) THEN
    v_fallas := v_fallas || format('T4 Rendimiento del mes de F: las notas de hoy no lo tocan (7000 y 70 u., ninguna resta_rendimiento): %s', v_x);
  END IF;
  -- T4b: la de rechazo y la del descuento comercial, como si se hubieran emitido dentro del mes de F
  -- (resta_rendimiento): restan 200 y 200, y sólo la de rechazo resta unidades (6.600 y 68 u.). Anular
  -- la de rechazo con el mes ya cerrado no lo mueve: sigue restando (la marca queda).
  UPDATE notas_credito_venta SET resta_rendimiento = true WHERE pedido_id IN (v_bol[1], v_bol[6]);
  v_j := pg_temp.como(v_adm, v_s, format('SELECT public.rendimiento_preventistas(%s, %L::date)::text', v_s, v_mes))::jsonb;
  v_x := pg_temp.fila(v_j->'preventistas', 'preventista_id', v_ven::text);
  v_t2 := format('%s/%s', v_x->>'venta', v_x->>'unidades');
  PERFORM pg_temp.anular((SELECT id FROM notas_credito_venta WHERE pedido_id = v_bol[1]));
  v_j := pg_temp.como(v_adm, v_s, format('SELECT public.rendimiento_preventistas(%s, %L::date)::text', v_s, v_mes))::jsonb;
  v_x := pg_temp.fila(v_j->'preventistas', 'preventista_id', v_ven::text);
  IF NOT COALESCE(pg_temp.igual(NULLIF(split_part(v_t2, '/', 1), '')::numeric, 6600)
                  AND pg_temp.igual(NULLIF(split_part(v_t2, '/', 2), '')::numeric, 68), false)
     OR NOT pg_temp.igual((v_x->>'venta')::numeric, 6600) OR NOT pg_temp.igual((v_x->>'unidades')::numeric, 68)
     OR NOT (SELECT resta_rendimiento FROM notas_credito_venta WHERE pedido_id = v_bol[1]) THEN
    v_fallas := v_fallas || format('T4b dos notas emitidas en el mes de F restan del Rendimiento (6600 y 68 u.: %s) y anular una con el mes cerrado no lo mueve: %s',
      v_t2, v_x);
  END IF;

  BEGIN
    v_r := pg_temp.nc(v_bol[1], 1, 'inventado');
    v_fallas := v_fallas || text 'T5 la RPC aceptó un motivo que no está en la lista';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT ILIKE '%motivo%' THEN
      v_fallas := v_fallas || format('T5 la RPC rechazó por otra cosa: %s', SQLERRM);
    END IF;
  END;
  BEGIN
    INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
      VALUES (v_s, v_c1, v_bol[1], v_hoy, 'inventado', 1, v_adm, 1, 0);
    v_fallas := v_fallas || text 'T5b la tabla aceptó un motivo que no está en la lista';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- ======================================================= M · las metas de V
  v_mot_metas := v_t;
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo)
    VALUES (v_s, v_ven, v_mesh, v_finh, 'facturacion', 100000) RETURNING id INTO v_m;
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo, producto_ids)
    VALUES (v_s, v_ven, v_mesh, v_finh, 'unidades', 1000, ARRAY[v_a]) RETURNING id INTO v_m2;
  v_bol := '{}';
  v_p := pg_temp.bol(v_ven, v_c1, v_hoy); v_bol := v_bol || v_p; PERFORM pg_temp.nc(v_p, 3, 'cliente_rechaza');
  v_p := pg_temp.bol(v_ven, v_c1, v_hoy); v_bol := v_bol || v_p; PERFORM pg_temp.nc(v_p, 1, 'descuento_comercial');
  v_p := pg_temp.bol(v_ven, v_c1, v_hoy); v_bol := v_bol || v_p; PERFORM pg_temp.nc(v_p, 2, 'producto_vencido');
  v_p := pg_temp.bol(v_ven, v_c1, v_hoy); v_bol := v_bol || v_p;
  v_r := pg_temp.nc(v_p, 1, 'error_pedido');
  v_t := format('%s filas', (SELECT count(*) FROM nota_credito_venta_metas WHERE nota_credito_id = (v_r->>'nota_credito_id')::bigint));
  PERFORM pg_temp.anular((v_r->>'nota_credito_id')::bigint);
  IF NOT pg_temp.igual(pg_temp.logrado(v_ven, v_hoy, v_m), 3600) OR NOT pg_temp.igual(pg_temp.logrado(v_ven, v_hoy, v_m2), 37)
     OR (SELECT count(*) FROM nota_credito_venta_metas nm JOIN notas_credito_venta n ON n.id = nm.nota_credito_id
          WHERE n.pedido_id = v_bol[1]) <> 2
     OR (SELECT count(*) FROM nota_credito_venta_metas nm JOIN notas_credito_venta n ON n.id = nm.nota_credito_id
          WHERE n.pedido_id = v_bol[2]) <> 1
     OR (SELECT count(*) FROM nota_credito_venta_metas nm JOIN notas_credito_venta n ON n.id = nm.nota_credito_id
          WHERE n.pedido_id IN (v_bol[3], v_bol[4])) <> 0
     OR v_t <> '2 filas' THEN
    v_fallas := v_fallas || format('M1 metas de V: facturación 3600 y unidades 37, filas 2/1/0 (la anulada tenía 2: %s): %s y %s',
      v_t, pg_temp.logrado(v_ven, v_hoy, v_m), pg_temp.logrado(v_ven, v_hoy, v_m2));
  END IF;
  v_j := pg_temp.como(v_adm, v_s, format('SELECT public.rendimiento_preventistas(%s, %L::date)::text', v_s, v_mesh))::jsonb;
  v_x := pg_temp.fila(v_j->'preventistas', 'preventista_id', v_ven::text);
  v_n := (SELECT sum(pg_temp.base(b)) FROM unnest(v_bol) b);
  IF NOT pg_temp.igual((v_x->>'venta')::numeric, 3600) OR NOT pg_temp.igual((v_x->>'unidades')::numeric, 37)
     -- Emitidas dentro del mes de su boleta: restan las que descuentan; la anulada en el mes, no.
     OR (SELECT array_agg(n.resta_rendimiento ORDER BY b.o) FROM unnest(v_bol) WITH ORDINALITY b(p, o)
           JOIN notas_credito_venta n ON n.pedido_id = b.p) IS DISTINCT FROM ARRAY[true, true, false, false]
     OR NOT pg_temp.igual(v_n, 3600)
     OR NOT pg_temp.igual((public.bot_mis_ventas(v_ven, v_mesh, v_finh, v_s, 10)::jsonb->>'total_ventas')::numeric, 3400) THEN
    v_fallas := v_fallas || format('M2 el mes de V: Rendimiento 3600 y 37 u. (%s, %s), resta_rendimiento sí/sí/no/no (%s), comisión 3600 (%s), venta del bot 3400 (%s)',
      v_x->>'venta', v_x->>'unidades',
      (SELECT array_agg(n.resta_rendimiento ORDER BY b.o) FROM unnest(v_bol) WITH ORDINALITY b(p, o) JOIN notas_credito_venta n ON n.pedido_id = b.p),
      v_n, public.bot_mis_ventas(v_ven, v_mesh, v_finh, v_s, 10)::jsonb->>'total_ventas');
  END IF;
  v_m := split_part(v_mot_metas, ',', 1)::bigint;
  v_m2 := split_part(v_mot_metas, ',', 2)::bigint;
  IF NOT pg_temp.igual(pg_temp.logrado(v_ven, v_mes, v_m), 7000) OR NOT pg_temp.igual(pg_temp.logrado(v_ven, v_mes, v_m2), 70) THEN
    v_fallas := v_fallas || format('M3 las metas del mes de F no ven las notas de hoy: 7000 y 70, dieron %s y %s',
      pg_temp.logrado(v_ven, v_mes, v_m), pg_temp.logrado(v_ven, v_mes, v_m2));
  END IF;

  -- ============================================================ C · cumplida
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo)
    VALUES (v_s, v_v2, v_mesh, v_finh, 'facturacion', 500) RETURNING id INTO v_m;
  v_p := pg_temp.bol(v_v2, v_c1, v_hoy);
  v_r := pg_temp.nc(v_p, 2, 'cliente_rechaza');
  IF NOT pg_temp.igual(pg_temp.logrado(v_v2, v_hoy, v_m), 1000) OR NOT pg_temp.igual(pg_temp.base(v_p), 800)
     OR (v_r->>'metas_restadas')::int IS DISTINCT FROM 0 THEN
    v_fallas := v_fallas || format('C1 meta ya cumplida: sigue en 1000 y la comisión baja a 800: %s, %s, %s',
      pg_temp.logrado(v_v2, v_hoy, v_m), pg_temp.base(v_p), v_r->>'metas_restadas');
  END IF;

  -- ============================================================== A · anular
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo)
    VALUES (v_s, v_v3, v_mesh, v_finh, 'facturacion', 1500) RETURNING id INTO v_m;
  v_p := pg_temp.bol(v_v3, v_c1, v_hoy);
  v_r := pg_temp.nc(v_p, 2, 'cliente_rechaza');
  v_nc := (v_r->>'nota_credito_id')::bigint;
  v_t := format('%s', round(pg_temp.logrado(v_v3, v_hoy, v_m)));
  PERFORM pg_temp.bol(v_v3, v_c1, v_hoy);
  v_t := v_t || format(' / %s', round(pg_temp.logrado(v_v3, v_hoy, v_m)));
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo)
    VALUES (v_s, v_v3, v_mes, v_hoy, 'facturacion', 100000) RETURNING id INTO v_m2;
  v_t := v_t || format(' / nueva %s', round(pg_temp.logrado(v_v3, v_mes, v_m2)));
  v_p2 := pg_temp.bol(v_v3, v_c1, v_f);
  v_r := pg_temp.nc(v_p2, 1, 'error_pedido');
  v_nc2 := (v_r->>'nota_credito_id')::bigint;
  v_t := v_t || format(' / nueva con S0 %s', round(pg_temp.logrado(v_v3, v_mes, v_m2)));
  PERFORM pg_temp.anular(v_nc);
  v_t := v_t || format(' / anulada con la meta cumplida %s', round(pg_temp.logrado(v_v3, v_hoy, v_m)));
  UPDATE metas_preventista SET periodo_fin = v_hoy - 1 WHERE id = v_m2;
  PERFORM pg_temp.anular(v_nc2);
  v_t := v_t || format(' / anulada fuera del mes %s', round(pg_temp.logrado(v_v3, v_mes, v_m2)));
  IF v_t <> '800 / 1800 / nueva 2000 / nueva con S0 2900 / anulada con la meta cumplida 1800 / anulada fuera del mes 900' THEN
    v_fallas := v_fallas || format('A1 anular: esperaba «800 / 1800 / nueva 2000 / nueva con S0 2900 / anulada con la meta cumplida 1800 / anulada fuera del mes 900», dio «%s»', v_t);
  END IF;
  -- La venta, en cambio, no las resta más (las dos están anuladas).
  IF EXISTS (SELECT 1 FROM public._ventas_nc(ARRAY[v_s], v_mes, v_finh) x WHERE x.nota_credito_id IN (v_nc, v_nc2)) THEN
    v_fallas := v_fallas || text 'A2 una nota anulada sigue restando de la venta';
  END IF;

  -- ========================================================= L · liquidación
  INSERT INTO empleados (nombre, puesto, sucursal_id, usuario_id, creado_por)
    VALUES ('B16 vendedor 4', 'preventista', v_s, v_v4, v_adm) RETURNING id INTO v_emp;
  INSERT INTO empleado_arreglos (empleado_id, vigente_desde, sueldo, frecuencia, comisiona, creado_por)
    VALUES (v_emp, v_mes - 31, 0, 'mensual', true, v_adm);
  v_p := pg_temp.bol(v_v4, v_c1, v_f);
  PERFORM pg_temp.congelar(v_emp, v_mes, v_finmes, interval '3 hours');
  v_r := pg_temp.nc(v_p, 2, 'cliente_rechaza');
  IF (v_r->>'resta_comision')::boolean IS DISTINCT FROM false OR NOT pg_temp.igual(pg_temp.base(v_p), 1000) THEN
    v_fallas := v_fallas || format('L1 con la comisión liquidada la nota no resta: %s, base %s', v_r->>'resta_comision', pg_temp.base(v_p));
  END IF;
  v_p := pg_temp.bol(v_v4, v_c1, v_f);
  v_p2 := v_p;
  v_r := pg_temp.nc(v_p, 2, 'cliente_rechaza');
  v_nc2 := (v_r->>'nota_credito_id')::bigint;
  v_liq := pg_temp.congelar(v_emp, v_finmes + 1, v_finmes + 1, interval '2 hours');
  PERFORM pg_temp.anular((v_r->>'nota_credito_id')::bigint);
  IF (SELECT resta_comision FROM notas_credito_venta WHERE id = (v_r->>'nota_credito_id')::bigint) IS DISTINCT FROM true
     OR NOT pg_temp.igual(pg_temp.base(v_p), 800) THEN
    v_fallas := v_fallas || format('L2 anular con la comisión ya liquidada no la mueve: base %s', pg_temp.base(v_p));
  END IF;
  v_p := pg_temp.bol(v_v4, v_c1, v_f);
  v_r := pg_temp.nc(v_p, 2, 'cliente_rechaza');
  PERFORM pg_temp.anular((v_r->>'nota_credito_id')::bigint);
  IF (SELECT resta_comision FROM notas_credito_venta WHERE id = (v_r->>'nota_credito_id')::bigint) IS DISTINCT FROM false
     OR NOT pg_temp.igual(pg_temp.base(v_p), 1000) THEN
    v_fallas := v_fallas || format('L3 anular antes de liquidar devuelve la comisión: base %s', pg_temp.base(v_p));
  END IF;
  SELECT jsonb_agg(jsonb_build_object('p', l.pedido_id = v_p, 'tipo', l.tipo, 'base', round(l.base, 2)))
    INTO v_x
    FROM public._liquidacion_lineas((SELECT e FROM empleados e WHERE e.id = v_emp), v_finmes) l;
  IF v_x IS DISTINCT FROM jsonb_build_array(jsonb_build_object('p', true, 'tipo', 'inicial', 'base', 1000.00)) THEN
    v_fallas := v_fallas || format('L4 por liquidar sólo T3 (1000) y ningún ajuste: %s', v_x);
  END IF;

  -- L5 (v4, H2 de la revisión): se anula la liquidación que había congelado T2 con su nota
  -- anulada: T2 ya no está liquidada, así que esa nota deja de restar (vuelve a 1.000).
  PERFORM pg_temp.como(v_adm, v_s, format('SELECT public.anular_liquidacion(%s, %L)::text', v_liq, 'ensayo B16'));
  IF (SELECT resta_comision FROM notas_credito_venta WHERE id = v_nc2) IS DISTINCT FROM false
     OR NOT pg_temp.igual(pg_temp.base(v_p2), 1000) THEN
    v_fallas := v_fallas || format('L5 anulada la liquidación, la nota anulada que congelaba deja de restar: %s, base %s',
      (SELECT resta_comision FROM notas_credito_venta WHERE id = v_nc2), pg_temp.base(v_p2));
  END IF;

  -- ============================================ G · la foto no se rehace (v4, H6)
  BEGIN
    UPDATE notas_credito_venta SET motivo = 'otro' WHERE id = v_nc2;
    v_fallas := v_fallas || text 'G1 se pudo cambiar el motivo de una nota ya creada';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;
  BEGIN
    UPDATE notas_credito_venta SET anulada = false, anulada_at = NULL WHERE id = v_nc2;
    v_fallas := v_fallas || text 'G2 una nota anulada volvió a estar vigente';
  EXCEPTION WHEN invalid_parameter_value THEN NULL;
  END;

  -- ================================================== D · el adelanto de sueldo
  INSERT INTO empleados (nombre, puesto, sucursal_id, cliente_id, creado_por)
    VALUES ('B16 consumidor', 'deposito', v_s, v_c9, v_adm);
  v_p := pg_temp.bol(v_v5, v_c9, v_f);
  PERFORM pg_temp.nc(v_p, 2, 'cliente_rechaza');
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id)
    VALUES (v_c9, v_p, v_s, 800, 'adelanto_sueldo', v_f, v_adm);
  v_p2 := pg_temp.bol(v_v5, v_c9, v_f);
  PERFORM pg_temp.nc(v_p2, 2, 'producto_vencido');
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id)
    VALUES (v_c9, v_p2, v_s, 800, 'adelanto_sueldo', v_f, v_adm);
  v_j := public.reporte_gerencial(v_s, v_mes, v_finmes);
  IF NOT pg_temp.igual(pg_temp.base(v_p), 0) OR NOT pg_temp.igual(pg_temp.base(v_p2), 200)
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'vendedores', 'id', v_v5::text)->>'base_nc')::numeric, 200) THEN
    v_fallas := v_fallas || format('D1 adelanto sobre la venta neta: U1 0 (%s), U2 200 (%s), gerencial 200 (%s)',
      pg_temp.base(v_p), pg_temp.base(v_p2), pg_temp.fila(v_j->'vendedores', 'id', v_v5::text)->>'base_nc');
  END IF;

  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = PG_EXCEPTION_CONTEXT;
    v_fallas := v_fallas || format('el ensayo cortó: %s %s (%s)', SQLSTATE, SQLERRM, left(v_t, 400));
  END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · B16 v4: la NC se imputa al mes de su boleta; motivos, foto del vendedor (comisión, metas y Rendimiento) y nada hacia atrás (también al anular una liquidación)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · % caso(s):\n  - %', cardinality(v_fallas), array_to_string(v_fallas, E'\n  - ');
END
$ensayo$;
