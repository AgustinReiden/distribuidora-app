-- Ensayo de la migración "pedido: alta, estado y entrega masiva" (#1317, #1318, #1319).
--   1 · #1317. Por REST, con la sesión de cada rol:
--       P1 el preventista no marca entregado su pedido con un chofer;
--       P2 sí devuelve a pendiente y sin chofer su pedido asignado (la edición);
--       C1 el chofer del pedido lo entrega;
--       C2 el chofer no lo vuelve de entregado a asignado;
--       C3 el chofer no se cambia por otro;
--       P3 el preventista no vuelve su pedido entregado a pendiente;
--       E1 el encargado sí lo vuelve de entregado a asignado.
--   2 · #1319. F1 el preventista no carga un pedido con fecha de mañana; F2 sí
--       con la de ayer (la cola offline); F3 el admin sí con la de mañana.
--       A1 el alta, A2 la visita, A3 el canje y A4 el bot rechazan a un cliente
--       dado de baja, el alta como success=false. H1 el cambio de fecha queda
--       en pedido_historial con el antes, el después y quién.
--   3 · #1318. M1 la entrega y pago masiva saltea un pedido ya entregado (ni lo
--       cobra ni le pisa chofer y fecha); M2 las dos masivas rechazan la fecha
--       de un día controlado y el control sigue en pie; M3 saltean un canje.
--   4 · #1298. Una entrega de las 22:30 (en UTC, el día siguiente) es del día
--       argentino: T1 el chofer no la saca de su día controlado; T2 el
--       encargado sí, y el control que se descarta es el de ese día.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
-- Las fechas de entrega van en 2099 para no pisar ningún control real.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en P1, P3, F1, A1–A4, H1, M1, M2, M3,
-- T1 y T2;
-- después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-pedido-estado-alta-entrega-1317-1319.sql

CREATE OR REPLACE FUNCTION pg_temp.t4_como(p_uid uuid, p_suc bigint) RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true),
         set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';

  v_suc     bigint;
  v_prev    uuid;   -- preventista que no reparte en v_suc
  v_chofer  uuid;   -- reparte en v_suc, no es admin ni encargado, no es v_prev
  v_enc     uuid;   -- encargado (o admin si no hay) de v_suc
  v_admin   uuid;   -- admin de v_suc
  v_cli     bigint; -- cliente activo de v_suc
  v_prod    bigint;
  v_hoy     date := public._tablero_hoy();

  v_ped     bigint; -- de v_prev, asignado a v_chofer
  v_pede    bigint; -- ya entregado
  v_pedc    bigint; -- comanda de un canje
  v_conf    uuid;
  v_res     text;
  v_json    jsonb;
  v_n       int;
  v_r       record;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, us.sucursal_id INTO v_chofer, v_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE COALESCE(pf.activo, true) AND pf.rol NOT IN ('admin', 'encargado')
     AND public._actua_como_transportista(pf.id, us.sucursal_id)
     AND EXISTS (SELECT 1 FROM perfiles p2 JOIN usuario_sucursales u2 ON u2.usuario_id = p2.id
                  WHERE u2.sucursal_id = us.sucursal_id AND p2.rol = 'preventista' AND p2.id <> pf.id
                    AND COALESCE(p2.activo, true) AND NOT public._actua_como_transportista(p2.id, us.sucursal_id))
     AND EXISTS (SELECT 1 FROM perfiles p3 JOIN usuario_sucursales u3 ON u3.usuario_id = p3.id
                  WHERE u3.sucursal_id = us.sucursal_id AND p3.rol = 'admin' AND COALESCE(p3.activo, true))
   ORDER BY us.sucursal_id, pf.id LIMIT 1;
  IF v_chofer IS NULL THEN
    RAISE EXCEPTION 'ENSAYO SIN DATOS: no hay una sucursal con chofer (no staff), preventista que no reparte y admin';
  END IF;

  SELECT pf.id INTO v_prev
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'preventista' AND pf.id <> v_chofer
     AND COALESCE(pf.activo, true) AND NOT public._actua_como_transportista(pf.id, v_suc)
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' AND COALESCE(pf.activo, true)
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_enc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'encargado' AND COALESCE(pf.activo, true)
   ORDER BY pf.id LIMIT 1;
  v_enc := COALESCE(v_enc, v_admin);

  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT COALESCE(c.reservado_admin, false)
     AND c.tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY c.id LIMIT 1;
  SELECT id INTO v_prod FROM productos WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  RAISE NOTICE 'datos: sucursal % · preventista % · chofer % · encargado % · admin % · cliente %',
    v_suc, v_prev, v_chofer, v_enc, v_admin, v_cli;

  -- Pedidos de prueba, como el server (postgres: los guards de API no corren).
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, stock_descontado, forma_pago, estado_pago)
  VALUES (v_cli, v_suc, v_prev, v_prev, v_hoy, 100, 100, 0, 100, 'ZZ', 'asignado', v_chofer, true, 'efectivo', 'pendiente')
  RETURNING id INTO v_ped;

  -- ------------------------------------------------------------ 1 · #1317 ---
  -- P1 · el preventista marca entregado su pedido.
  PERFORM pg_temp.t4_como(v_prev, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = '2099-01-02 12:00-03' WHERE id = $1$q$ USING v_ped;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> '42501' THEN v_fallas := v_fallas || ('P1 el preventista marcó entregado su pedido: ' || v_res); END IF;

  -- P2 · el preventista lo saca de la ruta (lo que hace la edición).
  PERFORM pg_temp.t4_como(v_prev, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET estado = 'pendiente', transportista_id = NULL WHERE id = $1$q$ USING v_ped;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> 'ok 1' THEN v_fallas := v_fallas || ('P2 el preventista no pudo volver a pendiente su pedido: ' || v_res); END IF;
  UPDATE pedidos SET estado = 'asignado', transportista_id = v_chofer WHERE id = v_ped;

  -- C1 · el chofer lo entrega.
  PERFORM pg_temp.t4_como(v_chofer, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = '2099-01-02 12:00-03' WHERE id = $1$q$ USING v_ped;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> 'ok 1' THEN v_fallas := v_fallas || ('C1 el chofer no pudo entregar: ' || v_res); END IF;

  -- C2 · el chofer lo vuelve de entregado a asignado.
  PERFORM pg_temp.t4_como(v_chofer, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = $1$q$ USING v_ped;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> '42501' THEN v_fallas := v_fallas || ('C2 el chofer revirtió una entrega: ' || v_res); END IF;

  -- C3 · el chofer pasa el pedido a otro.
  PERFORM pg_temp.t4_como(v_chofer, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET transportista_id = $2 WHERE id = $1$q$ USING v_ped, v_enc;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> '42501' THEN v_fallas := v_fallas || ('C3 el chofer cambió el chofer: ' || v_res); END IF;

  -- P3 · el preventista vuelve a pendiente su pedido entregado.
  PERFORM pg_temp.t4_como(v_prev, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET estado = 'pendiente', transportista_id = NULL, fecha_entrega = NULL WHERE id = $1$q$ USING v_ped;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> '42501' THEN v_fallas := v_fallas || ('P3 el preventista revirtió su pedido entregado: ' || v_res); END IF;

  -- E1 · el encargado revierte la entrega.
  PERFORM pg_temp.t4_como(v_enc, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = $1$q$ USING v_ped;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> 'ok 1' THEN v_fallas := v_fallas || ('E1 el encargado no pudo revertir la entrega: ' || v_res); END IF;

  -- ------------------------------------------------------------ 2 · #1319 ---
  -- F1 · fecha de mañana, preventista.
  PERFORM pg_temp.t4_como(v_prev, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.crear_pedido_completo(p_cliente_id => $1, p_total => 0, p_usuario_id => $2,
               p_items => '[]'::jsonb, p_fecha => $3)$q$ INTO v_json USING v_cli, v_prev, v_hoy + 1;
    v_res := v_json::text;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '%posterior a hoy%' OR v_json->>'success' <> 'false' THEN
    v_fallas := v_fallas || ('F1 el preventista cargó con fecha de mañana: ' || v_res);
  END IF;

  -- F2 · fecha de ayer, preventista: no lo frena la fecha (falla por otra cosa: no hay items).
  PERFORM pg_temp.t4_como(v_prev, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.crear_pedido_completo(p_cliente_id => $1, p_total => 0, p_usuario_id => $2,
               p_items => '[]'::jsonb, p_fecha => $3)$q$ INTO v_json USING v_cli, v_prev, v_hoy - 1;
    v_res := v_json::text;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res LIKE '%posterior a hoy%' THEN v_fallas := v_fallas || ('F2 una fecha pasada no entró: ' || v_res); END IF;

  -- F3 · fecha de mañana, admin.
  PERFORM pg_temp.t4_como(v_admin, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.crear_pedido_completo(p_cliente_id => $1, p_total => 0, p_usuario_id => $2,
               p_items => '[]'::jsonb, p_fecha => $3)$q$ INTO v_json USING v_cli, v_admin, v_hoy + 1;
    v_res := v_json::text;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res LIKE '%posterior a hoy%' THEN v_fallas := v_fallas || ('F3 el admin no pudo cargar con fecha futura: ' || v_res); END IF;

  -- A · cliente dado de baja.
  UPDATE clientes SET activo = false WHERE id = v_cli;

  -- A1 · el alta, como success=false (la cola offline lo toma como definitivo).
  PERFORM pg_temp.t4_como(v_prev, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.crear_pedido_completo(p_cliente_id => $1, p_total => 0, p_usuario_id => $2,
               p_items => '[]'::jsonb, p_fecha => $3)$q$ INTO v_json USING v_cli, v_prev, v_hoy;
    v_res := v_json::text;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM; v_json := NULL;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '%dado de baja%' OR v_json->>'success' IS DISTINCT FROM 'false' THEN
    v_fallas := v_fallas || ('A1 el alta aceptó un cliente dado de baja: ' || v_res);
  END IF;

  -- A2 · la visita.
  PERFORM pg_temp.t4_como(v_prev, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.registrar_visita_cliente(p_cliente_id => $1, p_status => 'denied',
               p_motivo_omision => 'ensayo')$q$ INTO v_json USING v_cli;
    v_res := v_json::text;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '%dado de baja%' THEN v_fallas := v_fallas || ('A2 la visita aceptó un cliente dado de baja: ' || v_res); END IF;

  -- A3 · el canje.
  PERFORM pg_temp.t4_como(v_enc, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.registrar_cambio_producto($1::int, $2, 1, $2, 1)$q$ INTO v_n USING v_cli, v_prod;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '%dado de baja%' THEN v_fallas := v_fallas || ('A3 el canje aceptó un cliente dado de baja: ' || v_res); END IF;

  -- A4 · el bot (server).
  INSERT INTO bot_pedidos_pendientes (id, perfil_id, sucursal_id, cliente_id, items, total, total_iva, forma_pago,
                                      consumido, created_at, expires_at, cargo_mostrado)
  VALUES (gen_random_uuid(), v_prev, v_suc, v_cli, '[]'::jsonb, 0, 0, 'efectivo', false, now(), now() + interval '10 minutes', 0)
  RETURNING id INTO v_conf;
  BEGIN
    v_json := public.crear_pedido_completo_bot(v_prev, v_conf);
    v_res := v_json::text;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  IF v_res NOT LIKE '%dado de baja%' THEN v_fallas := v_fallas || ('A4 el bot aceptó un cliente dado de baja: ' || v_res); END IF;

  UPDATE clientes SET activo = true WHERE id = v_cli;

  -- H1 · el encargado corre el pedido un día: queda en el historial.
  PERFORM pg_temp.t4_como(v_enc, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET fecha = $2 WHERE id = $1$q$ USING v_ped, v_hoy - 1;
    v_res := 'ok';
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM pedido_historial
   WHERE pedido_id = v_ped AND campo_modificado = 'fecha'
     AND valor_anterior = v_hoy::text AND valor_nuevo = (v_hoy - 1)::text AND usuario_id = v_enc;
  IF v_res <> 'ok' OR v_n <> 1 THEN
    v_fallas := v_fallas || format('H1 el cambio de fecha no quedó en el historial (%s, %s filas)', v_res, v_n);
  END IF;

  -- ------------------------------------------------------------ 3 · #1318 ---
  -- M1 · entrega y pago masiva sobre un pedido ya entregado.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, fecha_entrega, stock_descontado,
                       forma_pago, estado_pago)
  VALUES (v_cli, v_suc, v_prev, v_prev, v_hoy, 100, 100, 0, 100, 'ZZ', 'entregado', v_chofer,
          '2099-01-03 12:00-03', true, 'efectivo', 'pendiente')
  RETURNING id INTO v_pede;
  PERFORM pg_temp.t4_como(v_admin, v_suc);
  BEGIN
    v_n := public.marcar_entrega_y_pago_masivo_impl(ARRAY[v_pede], v_chofer, 'efectivo', DATE '2099-01-04');
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  SELECT (fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS dia,
         (SELECT count(*) FROM pagos WHERE pedido_id = v_pede) AS pagos
    INTO v_r FROM pedidos WHERE id = v_pede;
  IF v_res <> 'ok 0' OR v_r.dia <> DATE '2099-01-03' OR v_r.pagos <> 0 THEN
    v_fallas := v_fallas || format('M1 la masiva volvió a entregar o cobró un entregado (%s, día %s, %s pagos)', v_res, v_r.dia, v_r.pagos);
  END IF;

  -- M2 · día controlado: las dos masivas lo rechazan y el control sigue.
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, created_at, controlada_at, controlada_por)
  VALUES (DATE '2099-01-05', v_chofer, v_suc, 'confirmada', now(), now(), v_admin);

  PERFORM pg_temp.t4_como(v_admin, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.marcar_entregas_masivo(ARRAY[$1]::bigint[], $2, DATE '2099-01-05')$q$ INTO v_n USING v_ped, v_chofer;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '42501%ya fue controlada%' THEN v_fallas := v_fallas || ('M2 marcar_entregas_masivo entregó en un día controlado: ' || v_res); END IF;

  PERFORM pg_temp.t4_como(v_admin, v_suc);
  BEGIN
    v_n := public.marcar_entrega_y_pago_masivo_impl(ARRAY[v_ped], v_chofer, 'efectivo', DATE '2099-01-05');
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  IF v_res NOT LIKE '42501%ya fue controlada%' THEN v_fallas := v_fallas || ('M2 entrega y pago entregó en un día controlado: ' || v_res); END IF;

  SELECT count(*) INTO v_n FROM rendiciones_control
   WHERE fecha = DATE '2099-01-05' AND transportista_id = v_chofer AND sucursal_id = v_suc;
  IF v_n <> 1 THEN v_fallas := v_fallas || 'M2 el control del día se borró'; END IF;

  -- M3 · la comanda de un canje no se entrega en masa.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, stock_descontado, forma_pago,
                       estado_pago, canal)
  VALUES (v_cli, v_suc, v_prev, v_prev, v_hoy, 0, 0, 0, 0, 'ZZ', 'asignado', v_chofer, true, 'efectivo',
          'pendiente', 'cambio')
  RETURNING id INTO v_pedc;

  PERFORM pg_temp.t4_como(v_admin, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.marcar_entregas_masivo(ARRAY[$1]::bigint[], $2, DATE '2099-01-06')$q$ INTO v_n USING v_pedc, v_chofer;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.t4_como(v_admin, v_suc);
  BEGIN
    v_n := public.marcar_entrega_y_pago_masivo_impl(ARRAY[v_pedc], v_chofer, 'efectivo', DATE '2099-01-06');
    v_res := v_res || ' / ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := v_res || ' / ' || SQLSTATE || ' ' || SQLERRM;
  END;
  IF v_res <> 'ok 0 / ok 0' OR (SELECT estado FROM pedidos WHERE id = v_pedc) <> 'asignado' THEN
    v_fallas := v_fallas || ('M3 la masiva entregó la comanda de un canje: ' || v_res);
  END IF;

  -- ----------------------------------------------- 4 · #1298 (día argentino) ---
  -- Una entrega de las 22:30 del 07/01 (en UTC ya es el 08) con el 07 controlado.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, fecha_entrega, stock_descontado,
                       forma_pago, estado_pago)
  VALUES (v_cli, v_suc, v_prev, v_prev, v_hoy, 100, 100, 0, 100, 'ZZ', 'entregado', v_chofer,
          '2099-01-07 22:30-03', true, 'efectivo', 'pendiente')
  RETURNING id INTO v_pede;
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, created_at, controlada_at, controlada_por)
  VALUES (DATE '2099-01-07', v_chofer, v_suc, 'confirmada', now(), now(), v_admin);

  -- T1 · el chofer le mueve la entrega al 08: reabriría el 07, que está controlado.
  PERFORM pg_temp.t4_como(v_chofer, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET fecha_entrega = '2099-01-08 12:00-03' WHERE id = $1$q$ USING v_pede;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '42501%ya fue controlada%' THEN
    v_fallas := v_fallas || ('T1 una entrega de las 22:30 se movió de un día controlado: ' || v_res);
  END IF;

  -- T2 · el encargado sí la mueve, y el control que se descarta es el del 07.
  PERFORM pg_temp.t4_como(v_enc, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$UPDATE public.pedidos SET fecha_entrega = '2099-01-09 12:00-03' WHERE id = $1$q$ USING v_pede;
    v_res := 'ok';
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM rendiciones_control
   WHERE fecha = DATE '2099-01-07' AND transportista_id = v_chofer AND sucursal_id = v_suc;
  IF v_res <> 'ok' OR v_n <> 0 THEN
    v_fallas := v_fallas || format('T2 mover la entrega de las 22:30 no descartó el control de su día (%s, quedan %s)', v_res, v_n);
  END IF;

  -- ---------------------------------------------------------- resultado ---
  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% de 22):\n%', array_length(v_fallas, 1), array_to_string(v_fallas, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK: 22 aserciones (#1317 P1–P3, C1–C3, E1; #1319 F1–F3, A1–A4, H1; #1318 M1, M2 ×3, M3; #1298 T1, T2)';
END
$ensayo$;
