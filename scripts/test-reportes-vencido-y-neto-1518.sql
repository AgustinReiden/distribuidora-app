-- Ensayo de #1518 y COB-4 de #1512 (mig NNN): lo vencido es uno solo y descuenta el crédito
-- suelto, el neto es uno, las zonas van por id y la venta en curso cuenta lo mismo en todos lados.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE EXCEPTION, así
-- que todo lo que escribe (clientes, zonas, pedidos y un pago de ensayo) se deshace.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración falla en V1 (Taco Pozo), V2, V3 y V4 (sucursal 1, el mes pasado), V5,
-- V6, V7, V8 y V9 (_cxc_boletas no existe).
--
--   psql "$DATABASE_URL" -f scripts/test-reportes-vencido-y-neto-1518.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_hoy     date := public._tablero_hoy();
  v_mes_ini date := (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date;
  v_mes_fin date := (date_trunc('month', public._tablero_hoy()) - interval '1 day')::date;
  v_suc     bigint;
  v_suc2    bigint;
  v_s       bigint;
  v_adm     uuid;
  v_otro    uuid;
  v_prod    bigint;
  v_c7      bigint;
  v_c30     bigint;
  v_cc      bigint;
  v_cz1     bigint;
  v_cz2     bigint;
  v_cv      bigint;
  v_z1      bigint;
  v_z2      bigint;
  v_p       bigint;
  v_res     jsonb;
  v_j       jsonb;
  v_k       jsonb;
  v_lista   jsonb;
  v_x       numeric;
  v_y       numeric;
  v_n       int;
  v_r       record;
  v_txt     text;
BEGIN
  -- El admin con más sucursales activas y la primera de ellas; la segunda, para la Red.
  SELECT us.usuario_id INTO v_adm
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND COALESCE(pf.activo, true)
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   GROUP BY us.usuario_id
   ORDER BY count(*) DESC, us.usuario_id
   LIMIT 1;
  SELECT min(us.sucursal_id) INTO v_suc
    FROM usuario_sucursales us JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE us.usuario_id = v_adm;
  SELECT min(s.id) INTO v_suc2 FROM sucursales s WHERE s.activa AND s.id <> v_suc;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ningún admin activo con una sucursal activa';
  END IF;

  -- Como servidor (auth.uid() NULL): la Red son todas las activas.
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---------------------------------------------------------------- fixtures
  -- C7: 7 días de crédito, una boleta entregada hace 10 días → vencida hace 3.
  -- C30: 30 días de crédito, la misma boleta → corriente.
  -- CC: 7 días de crédito, A (hace 20, 500), B (hace 12, 400), C pendiente (300) y 600 a favor
  --     sin imputar. FIFO: A se cubre entera, B queda en 300 (vencida hace 5), C en 300 corriente.
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, dias_credito)
  VALUES ('ZZ ensayo 1518 siete', 'ZZ 1518 siete', 'Ensayo 1518', v_suc, 7) RETURNING id INTO v_c7;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, dias_credito)
  VALUES ('ZZ ensayo 1518 treinta', 'ZZ 1518 treinta', 'Ensayo 1518', v_suc, 30) RETURNING id INTO v_c30;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, dias_credito)
  VALUES ('ZZ ensayo 1518 credito', 'ZZ 1518 credito', 'Ensayo 1518', v_suc, 7) RETURNING id INTO v_cc;

  -- Entregadas como retiro en el depósito (el servidor puede marcarlo): sin chofer no se entregan.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal, retiro_deposito)
  VALUES (v_c7,  v_suc, v_adm, 1000, 'entregado', v_hoy - 10, ((v_hoy - 10) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'app', true),
         (v_c30, v_suc, v_adm, 1000, 'entregado', v_hoy - 10, ((v_hoy - 10) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'app', true),
         (v_cc,  v_suc, v_adm,  500, 'entregado', v_hoy - 20, ((v_hoy - 20) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'app', true),
         (v_cc,  v_suc, v_adm,  400, 'entregado', v_hoy - 12, ((v_hoy - 12) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'app', true),
         (v_cc,  v_suc, v_adm,  300, 'pendiente', v_hoy - 1,  NULL, 'app', false);
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas)
  VALUES (v_cc, NULL, v_suc, 600, 'efectivo', v_hoy, v_adm, 'ensayo 1518 [saldo a favor]');

  -- --------------------------- V1 · la alerta = lo vencido de Cuentas por cobrar = Σ detalle
  FOR v_s IN SELECT id FROM sucursales WHERE activa UNION ALL SELECT NULL::bigint LOOP
    v_j := public.reporte_cuentas_por_cobrar(v_s);
    v_x := (v_j->'totales'->>'vencido30')::numeric + (v_j->'totales'->>'vencido60')::numeric
         + (v_j->'totales'->>'vencido90')::numeric;
    v_y := COALESCE((SELECT (a->>'valor')::numeric
                       FROM jsonb_array_elements(public.reporte_gerencial(v_s, v_hoy, v_hoy, false, false)->'alertas') a
                      WHERE a->>'codigo' = 'cobranza_vencida'), 0);
    IF v_x IS DISTINCT FROM v_y THEN
      v_fallas := v_fallas || format('V1 suc %s · Cuentas por cobrar vencido %s, la alerta %s', COALESCE(v_s::text, 'Red'), v_x, v_y);
    END IF;
    v_lista := public.reporte_alerta_detalle(v_s, 'cobranza_vencida');
    IF jsonb_array_length(v_lista) < 100
       AND (SELECT COALESCE(sum((e->>'valor')::numeric), 0) FROM jsonb_array_elements(v_lista) e) IS DISTINCT FROM v_y THEN
      v_fallas := v_fallas || format('V1 suc %s · el detalle de la alerta no suma la alerta (%s)', COALESCE(v_s::text, 'Red'), v_y);
    END IF;
  END LOOP;

  -- ------------------------------------- V2 · los días de crédito y el crédito suelto (FIFO)
  v_j := public.reporte_cuentas_por_cobrar(v_suc);
  SELECT e INTO v_k FROM jsonb_array_elements(v_j->'clientes') e WHERE (e->'cliente'->>'id')::bigint = v_c7;
  IF (v_k->'aging'->>'vencido30')::numeric IS DISTINCT FROM 1000 THEN
    v_fallas := v_fallas || format('V2 C7 · esperaba 1000 en 1-30 días, dio %s', v_k->'aging');
  END IF;
  SELECT e INTO v_k FROM jsonb_array_elements(v_j->'clientes') e WHERE (e->'cliente'->>'id')::bigint = v_c30;
  IF (v_k->'aging'->>'corriente')::numeric IS DISTINCT FROM 1000 THEN
    v_fallas := v_fallas || format('V2 C30 · esperaba 1000 corriente, dio %s', v_k->'aging');
  END IF;
  SELECT e INTO v_k FROM jsonb_array_elements(v_j->'clientes') e WHERE (e->'cliente'->>'id')::bigint = v_cc;
  IF (v_k->>'saldoPendiente')::numeric IS DISTINCT FROM 600
     OR (v_k->'aging'->>'vencido30')::numeric IS DISTINCT FROM 300
     OR (v_k->'aging'->>'corriente')::numeric IS DISTINCT FROM 300
     OR (v_k->>'pedidosPendientes')::int IS DISTINCT FROM 2
     OR (v_k->>'totalDeuda')::numeric - (v_k->>'totalPagado')::numeric IS DISTINCT FROM 600
     OR (v_k->>'creditoAplicado')::numeric IS DISTINCT FROM 100 THEN
    v_fallas := v_fallas || format('V2 CC · esperaba saldo 600 (300 vencido, 300 corriente, 2 boletas, 100 de crédito en ellas), dio %s', v_k);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'consistencia'->'clientes_con_desvio') e
              WHERE (e->>'cliente_id')::bigint = v_cc) THEN
    v_fallas := v_fallas || format('V2 CC · figura con desvío contra saldo_cuenta (%s)',
      (SELECT saldo_cuenta FROM clientes WHERE id = v_cc));
  END IF;
  v_lista := public.reporte_alerta_detalle(v_suc, 'cobranza_vencida');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lista) e
                  WHERE e->>'nombre' = 'ZZ 1518 siete' AND (e->>'valor')::numeric = 1000
                    AND e->>'detalle' = 'vencida hace 3 días')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lista) e
                     WHERE e->>'nombre' = 'ZZ 1518 credito' AND (e->>'valor')::numeric = 300)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_lista) e WHERE e->>'nombre' = 'ZZ 1518 treinta') THEN
    v_fallas := v_fallas || format('V2 detalle de la alerta · esperaba C7 1000 (hace 3 días) y CC 300, sin C30: %s',
      (SELECT jsonb_agg(e) FROM jsonb_array_elements(v_lista) e WHERE e->>'nombre' LIKE 'ZZ 1518%'));
  END IF;

  -- Deudores en mora, como el admin en la sucursal
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  SELECT * INTO v_r FROM public.obtener_deudores_mora(1) d WHERE d.cliente_id = v_cc;
  IF v_r.saldo_vencido IS DISTINCT FROM 300 OR v_r.dias_mora_max IS DISTINCT FROM 5
     OR v_r.pedido_mas_viejo IS DISTINCT FROM v_hoy - 12 THEN
    v_fallas := v_fallas || format('V2 mora CC · esperaba 300 vencido, 5 días, desde %s; dio %s, %s, %s',
      v_hoy - 12, v_r.saldo_vencido, v_r.dias_mora_max, v_r.pedido_mas_viejo);
  END IF;
  SELECT * INTO v_r FROM public.obtener_deudores_mora(1) d WHERE d.cliente_id = v_c7;
  IF v_r.saldo_vencido IS DISTINCT FROM 1000 OR v_r.dias_mora_max IS DISTINCT FROM 3 THEN
    v_fallas := v_fallas || format('V2 mora C7 · esperaba 1000 y 3 días, dio %s y %s', v_r.saldo_vencido, v_r.dias_mora_max);
  END IF;
  IF EXISTS (SELECT 1 FROM public.obtener_deudores_mora(1) d WHERE d.cliente_id = v_c30) THEN
    v_fallas := v_fallas || 'V2 mora · C30 figura en mora con 30 días de crédito'::text;
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---------------------------------------------- V3 · un solo neto (el mes pasado, en vivo)
  FOR v_s IN SELECT id FROM sucursales WHERE activa UNION ALL SELECT NULL::bigint LOOP
    v_k := public.reporte_rentabilidad(v_mes_ini, v_mes_fin, v_s, 'incluir')->'totales';
    IF (v_k->>'ventasNetas')::numeric IS DISTINCT FROM
         (v_k->>'ventasBrutas')::numeric - (v_k->>'ivaDiscriminado')::numeric - (v_k->>'impuestosInternos')::numeric
       OR abs((v_k->>'ventasNetas')::numeric - (v_k->>'ingresosTotales')::numeric) > 0.01 THEN
      v_fallas := v_fallas || format('V3 rentabilidad suc %s · brutas %s − IVA %s − II %s, netas %s, ingresos %s',
        COALESCE(v_s::text, 'Red'), v_k->'ventasBrutas', v_k->'ivaDiscriminado', v_k->'impuestosInternos',
        v_k->'ventasNetas', v_k->'ingresosTotales');
    END IF;
    v_k := public.reporte_gerencial(v_s, v_mes_ini, v_mes_fin, false, false)->'kpis';
    IF (v_k->>'venta_neta')::numeric IS DISTINCT FROM (v_k->>'venta')::numeric - (v_k->>'iva_debito')::numeric
       OR (v_k->>'venta_neta')::numeric IS DISTINCT FROM (v_k->>'venta_real')::numeric
       OR (v_k->>'margen_comercial_neto')::numeric IS DISTINCT FROM (v_k->>'margen_real')::numeric THEN
      v_fallas := v_fallas || format('V3 gerencial suc %s · venta %s − IVA %s, venta_neta %s, venta_real %s, mcn %s, margen_real %s',
        COALESCE(v_s::text, 'Red'), v_k->'venta', v_k->'iva_debito', v_k->'venta_neta', v_k->'venta_real',
        v_k->'margen_comercial_neto', v_k->'margen_real');
    END IF;
  END LOOP;

  -- ------------------- V4 · top clientes por zona cierra contra cobertura (el mes pasado)
  FOR v_s IN SELECT id FROM sucursales WHERE activa LOOP
    v_j := public.tablero_top_clientes_zona(v_s, v_mes_ini, v_mes_fin, 10, 14);
    v_k := public.tablero_cobertura(v_s, v_mes_ini);
    FOR v_r IN
      SELECT (z->>'zona_id')::bigint AS zona_id, (z->>'total')::numeric AS total
        FROM jsonb_array_elements(v_j->'zonas') z
    LOOP
      v_x := (SELECT (c->>'facturacion')::numeric FROM jsonb_array_elements(v_k->'zonas') c
               WHERE (c->>'zona_id')::bigint = v_r.zona_id);
      IF v_x IS DISTINCT FROM v_r.total THEN
        v_fallas := v_fallas || format('V4 suc %s zona %s · top %s, cobertura %s', v_s, v_r.zona_id, v_r.total, v_x);
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'zonas') z, jsonb_array_elements(z->'top') t
                WHERE NOT (t->>'activo')::boolean AND (t->>'alerta')::boolean) THEN
      v_fallas := v_fallas || format('V4 suc %s · un cliente de baja hace saltar la alerta', v_s);
    END IF;
  END LOOP;

  -- ------------------------------------------- V5 · las zonas homónimas de la Red, por id
  IF v_suc2 IS NOT NULL THEN
    INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZZ zona 1518', v_suc) RETURNING id INTO v_z1;
    INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZZ zona 1518', v_suc2) RETURNING id INTO v_z2;
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES ('ZZ ensayo 1518 z1', 'ZZ 1518 z1', 'Ensayo 1518', v_suc, v_z1) RETURNING id INTO v_cz1;
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES ('ZZ ensayo 1518 z2', 'ZZ 1518 z2', 'Ensayo 1518', v_suc2, v_z2) RETURNING id INTO v_cz2;
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal, retiro_deposito)
    VALUES (v_cz1, v_suc,  v_adm, 100, 'entregado', v_hoy, now(), 'app', true),
           (v_cz2, v_suc2, v_adm, 200, 'entregado', v_hoy, now(), 'app', true);
    v_j := public.reporte_ventas_por_cliente(v_hoy, v_hoy, NULL, NULL);
    IF (SELECT count(*) FROM jsonb_array_elements(v_j->'zonas') z WHERE z->>'zona' = 'ZZ zona 1518') <> 2
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'zonas') z
                       WHERE (z->>'zona_id')::bigint = v_z1 AND (z->>'total')::numeric = 100
                         AND z->>'sucursal' = (SELECT nombre FROM sucursales WHERE id = v_suc))
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'zonas') z
                       WHERE (z->>'zona_id')::bigint = v_z2 AND (z->>'total')::numeric = 200) THEN
      v_fallas := v_fallas || format('V5 la Red junta las zonas homónimas: %s',
        (SELECT jsonb_agg(z) FROM jsonb_array_elements(v_j->'zonas') z WHERE z->>'zona' = 'ZZ zona 1518'));
    END IF;
    IF (SELECT COALESCE(sum((z->>'total')::numeric), 0) FROM jsonb_array_elements(v_j->'zonas') z)
       IS DISTINCT FROM (v_j->'totales'->>'total')::numeric THEN
      v_fallas := v_fallas || 'V5 Σ zonas no cierra contra el total'::text;
    END IF;
  END IF;

  -- ----------------- V6 · en curso: el bot = el gerencial con "Todos" menos el de entregadas
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal)
  VALUES (v_c7, v_suc, v_adm, 700, 'en_preparacion', v_hoy, 'app');
  FOR v_s IN SELECT id FROM sucursales WHERE activa LOOP
    FOR v_r IN SELECT * FROM (VALUES (v_mes_ini, v_mes_fin), (v_hoy, v_hoy)) AS t(d, h) LOOP
      v_x := (public.bot_ventas_periodo(v_r.d, v_r.h, v_s, 10)::jsonb->>'en_curso_monto')::numeric;
      v_y := (public.reporte_gerencial(v_s, v_r.d, v_r.h, true, false)->'kpis'->>'venta')::numeric
           - (public.reporte_gerencial(v_s, v_r.d, v_r.h, false, false)->'kpis'->>'venta')::numeric;
      IF v_x IS DISTINCT FROM v_y THEN
        v_fallas := v_fallas || format('V6 suc %s %s..%s · bot en curso %s, gerencial %s', v_s, v_r.d, v_r.h, v_x, v_y);
      END IF;
    END LOOP;
  END LOOP;

  -- ------------------------------ V7 · con "Todos", la base de comisión es sólo lo entregado
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1518', 1000, 1000, 1, v_suc) RETURNING id INTO v_prod;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1518 venta', 'ZZ 1518 venta', 'Ensayo 1518', v_suc) RETURNING id INTO v_cv;
  v_res := public.crear_pedido_completo(
    v_cv, 1000, v_adm,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 1000)),
    'ensayo 1518', 'efectivo', 'pendiente', v_hoy);
  v_p := (v_res->>'pedido_id')::bigint;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_p IS NULL THEN
    v_fallas := v_fallas || format('V7 sin fixture: no se pudo crear el pedido (%s)', v_res);
  ELSE
    SELECT pf.id INTO v_otro
      FROM perfiles pf
     WHERE NOT EXISTS (SELECT 1 FROM pedidos pe
                        WHERE pe.usuario_id = pf.id AND pe.sucursal_id = v_suc AND pe.fecha = v_hoy)
     ORDER BY pf.id LIMIT 1;
    UPDATE pedidos SET usuario_id = v_otro WHERE id = v_p;
    v_j := public.reporte_gerencial(v_suc, v_hoy, v_hoy, true, false);
    SELECT e INTO v_k FROM jsonb_array_elements(v_j->'vendedores') e WHERE (e->>'id')::uuid = v_otro;
    IF (v_k->>'venta')::numeric IS DISTINCT FROM 1000 OR (v_k->>'base_nc')::numeric IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('V7 un vendedor con sólo un pendiente de 1000 · esperaba venta 1000 y base 0, dio %s', v_k);
    END IF;
  END IF;

  -- -------------------------------------------------------- V8 · la serie diaria lleva el año
  v_j := public.reporte_gerencial(v_suc, v_hoy - 3, v_hoy, true, false);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'serie_diaria') e WHERE NOT (e->>0 ~ '^\d{4}-\d{2}-\d{2}$')) THEN
    v_fallas := v_fallas || format('V8 serie_diaria sin año: %s', v_j->'serie_diaria');
  END IF;

  -- ----------------------------------------- V9 · _cxc_boletas es sólo de server
  IF to_regprocedure('public._cxc_boletas(bigint[])') IS NULL THEN
    v_fallas := v_fallas || 'V9 _cxc_boletas no existe'::text;
  ELSIF has_function_privilege('authenticated', 'public._cxc_boletas(bigint[])', 'EXECUTE')
     OR has_function_privilege('anon', 'public._cxc_boletas(bigint[])', 'EXECUTE') THEN
    v_fallas := v_fallas || '_cxc_boletas tiene EXECUTE para authenticated o anon'::text;
  END IF;

  -- -------------------------------- V10 · nada de esto mira el día UTC
  v_j := public.auditoria_fechas_utc();
  SELECT string_agg(f->>'nombre', ', ') INTO v_txt
    FROM jsonb_array_elements(v_j->'funciones') f
   WHERE f->>'nombre' IN ('_cxc_boletas', 'reporte_gerencial', 'reporte_alerta_detalle', 'reporte_cuentas_por_cobrar',
                          'obtener_deudores_mora', 'reporte_rentabilidad', 'tablero_top_clientes_zona',
                          'reporte_ventas_por_cliente', 'bot_ventas_periodo');
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('V10 auditoria_fechas_utc ve: %s', v_txt);
  END IF;

  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · V1 V2 V3 V4 V5 V6 V7 V8 V9 V10';
END
$ensayo$;
