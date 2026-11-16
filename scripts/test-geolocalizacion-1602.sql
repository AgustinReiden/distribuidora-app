-- Ensayo del diagnóstico y los rangos del GPS (#1602, mig NNN_diagnostico_y_rangos_del_gps).
--
-- Corre contra prod SIN dejar rastro, como scripts/test-volver-a-pendiente-1313.sql:
-- un único DO que termina SIEMPRE en una excepción (`ENSAYO OK …` o `ENSAYO FALLO …`).
-- Sin la migración falla en G0 (las columnas no existen).
--
-- Usa un pedido que ya existe de un preventista activo (le borra el GPS adentro de
-- la transacción) y un cliente que ese preventista puede operar. En la base local,
-- crearlos en un envoltorio: BEGIN; select conc.pedido_de(…); \i este; ROLLBACK;
--
--   G0 · Las columnas, los CHECK y una sola firma de cada RPC, con EXECUTE sólo para
--        authenticated (y service_role), DEFINER.
--   G1 · El bundle viejo: la llamada con los siete parámetros de antes (por nombre,
--        como PostgREST) sigue andando, y deja el diagnóstico en NULL.
--   G2 · El bundle nuevo: `denied` con motivo y diagnóstico → quedan los tres.
--        Escalar a `ok` reemplaza el diagnóstico y borra el motivo.
--   G3 · Un diagnóstico que no es un objeto, o que se pasa del tope, no se guarda,
--        pero el GPS sí.
--   G4 · VAR-01 en pedidos: latitud 91, longitud −181, precisión −1, NaN en las
--        tres y un diagnóstico de más de 300 bytes → 23514. Por la RPC, una
--        latitud NaN tampoco entra.
--   G5 · Lo mismo en visitas_cliente, con la visita que deja la RPC nueva (y la
--        vieja llamada, sin diagnóstico).
--   G6 · auditoria_rol_sin_activo() ya no marca a ninguna de las dos.

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_prev   uuid;
  v_ped    bigint;
  v_cli    bigint;
  v_vis    bigint;
  v_r      jsonb;
  v_row    record;
  v_estado text;
  v_fallas text[] := '{}';
  v_diag   CONSTANT jsonb := '{"permiso":"denied","error":1,"instalada":true,"navegador":"chrome 131","so":"android 10"}';
  v_diag_ok CONSTANT jsonb := '{"permiso":"granted","error":null,"instalada":true,"navegador":"chrome 131","so":"android 10"}';
  F_GEO CONSTANT text := 'public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)';
  F_VIS CONSTANT text := 'public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)';
BEGIN
 BEGIN
  -- ------------------------------------------------------------------- G0 ---
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name IN ('pedidos', 'visitas_cliente')
         AND column_name = 'gps_diagnostico') <> 2 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · G0: pedidos/visitas_cliente no tienen gps_diagnostico (falta la migración)';
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE conrelid IN ('public.pedidos'::regclass, 'public.visitas_cliente'::regclass)
         AND conname IN ('pedidos_gps_lat_rango', 'pedidos_gps_lng_rango', 'pedidos_gps_accuracy_rango',
                         'pedidos_gps_diagnostico_forma',
                         'visitas_cliente_gps_lat_rango', 'visitas_cliente_gps_lng_rango',
                         'visitas_cliente_gps_accuracy_rango', 'visitas_cliente_gps_diagnostico_forma')
         AND convalidated) <> 8 THEN
    v_fallas := v_fallas || 'G0 · faltan CHECK de rango o de forma (o no están validados)'::text;
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname IN ('registrar_geolocalizacion_pedido', 'registrar_visita_cliente')) <> 2
     OR to_regprocedure(F_GEO) IS NULL OR to_regprocedure(F_VIS) IS NULL THEN
    v_fallas := v_fallas || 'G0 · no hay exactamente una firma (la nueva) de cada RPC'::text;
  END IF;
  IF has_function_privilege('anon', F_GEO, 'EXECUTE') OR has_function_privilege('anon', F_VIS, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', F_GEO, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', F_VIS, 'EXECUTE')
     OR NOT (SELECT bool_and(prosecdef) FROM pg_proc WHERE oid IN (to_regprocedure(F_GEO), to_regprocedure(F_VIS))) THEN
    v_fallas := v_fallas || 'G0 · EXECUTE o DEFINER de las RPC no quedaron como antes'::text;
  END IF;
  IF has_column_privilege('authenticated', 'public.pedidos', 'gps_diagnostico', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.visitas_cliente', 'gps_diagnostico', 'INSERT')
     OR has_column_privilege('anon', 'public.pedidos', 'gps_diagnostico', 'SELECT') THEN
    v_fallas := v_fallas || 'G0 · gps_diagnostico se puede escribir por REST, o lo lee anon'::text;
  END IF;

  -- ------------------------------------------------------------- personas ---
  SELECT p.sucursal_id, p.usuario_id, p.id INTO v_suc, v_prev, v_ped
    FROM pedidos p
    JOIN perfiles pf ON pf.id = p.usuario_id AND pf.activo AND pf.rol = 'preventista'
    JOIN sucursales s ON s.id = p.sucursal_id AND s.activa
    JOIN usuario_sucursales us ON us.usuario_id = p.usuario_id AND us.sucursal_id = p.sucursal_id
   ORDER BY p.id DESC LIMIT 1;
  IF v_ped IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = 'ENSAYO FALLO · no hay un pedido de un preventista activo para probar';
  END IF;
  SELECT c.id INTO v_cli
    FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT COALESCE(c.reservado_admin, false)
     AND (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
          OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id AND cp.preventista_id = v_prev))
   ORDER BY c.id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = 'ENSAYO FALLO · no hay un cliente que el preventista pueda operar';
  END IF;

  UPDATE pedidos SET gps_status = NULL, gps_lat = NULL, gps_lng = NULL, gps_accuracy = NULL,
                     gps_capturado_at = NULL, gps_motivo_omision = NULL, gps_diagnostico = NULL
   WHERE id = v_ped;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- ------------------------------------------------------------------- G1 ---
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'timeout',
                                                 p_motivo_omision => 'sótano sin señal');
  RESET ROLE;
  SELECT gps_status, gps_motivo_omision, gps_diagnostico INTO v_row FROM pedidos WHERE id = v_ped;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_row.gps_status IS DISTINCT FROM 'timeout'
     OR v_row.gps_motivo_omision IS DISTINCT FROM 'sótano sin señal' OR v_row.gps_diagnostico IS NOT NULL THEN
    v_fallas := v_fallas || format('G1 · la llamada del bundle viejo no anduvo: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;

  -- ------------------------------------------------------------------- G2 ---
  UPDATE pedidos SET gps_status = NULL, gps_motivo_omision = NULL WHERE id = v_ped;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'denied',
                                                 p_motivo_omision => 'no me deja activarla', p_diagnostico => v_diag);
  RESET ROLE;
  SELECT gps_status, gps_motivo_omision, gps_diagnostico INTO v_row FROM pedidos WHERE id = v_ped;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_row.gps_status IS DISTINCT FROM 'denied'
     OR v_row.gps_motivo_omision IS DISTINCT FROM 'no me deja activarla' OR v_row.gps_diagnostico IS DISTINCT FROM v_diag THEN
    v_fallas := v_fallas || format('G2 · denied con motivo y diagnóstico: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'ok', p_lat => -26.8241, p_lng => -65.2226,
                                                 p_accuracy => 12.5, p_diagnostico => v_diag_ok);
  RESET ROLE;
  SELECT gps_status, gps_lat, gps_motivo_omision, gps_diagnostico INTO v_row FROM pedidos WHERE id = v_ped;
  IF v_row.gps_status IS DISTINCT FROM 'ok' OR v_row.gps_lat IS DISTINCT FROM -26.8241
     OR v_row.gps_motivo_omision IS NOT NULL OR v_row.gps_diagnostico IS DISTINCT FROM v_diag_ok THEN
    v_fallas := v_fallas || format('G2 · escalar a ok: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;

  -- ------------------------------------------------------------------- G3 ---
  UPDATE pedidos SET gps_status = NULL, gps_diagnostico = NULL WHERE id = v_ped;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'denied',
                                                 p_diagnostico => '["no", "es", "un objeto"]'::jsonb);
  RESET ROLE;
  SELECT gps_status, gps_diagnostico INTO v_row FROM pedidos WHERE id = v_ped;
  IF v_row.gps_status IS DISTINCT FROM 'denied' OR v_row.gps_diagnostico IS NOT NULL THEN
    v_fallas := v_fallas || format('G3 · diagnóstico que no es objeto: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  UPDATE pedidos SET gps_status = NULL WHERE id = v_ped;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'denied',
                                                 p_diagnostico => jsonb_build_object('so', repeat('x', 400)));
  RESET ROLE;
  SELECT gps_status, gps_diagnostico INTO v_row FROM pedidos WHERE id = v_ped;
  IF v_row.gps_status IS DISTINCT FROM 'denied' OR v_row.gps_diagnostico IS NOT NULL THEN
    v_fallas := v_fallas || format('G3 · diagnóstico de más de 300 bytes: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;

  -- ------------------------------------------------------------------- G4 ---
  FOR v_row IN SELECT * FROM (VALUES
    ('gps_lat = 91'), ('gps_lat = -90.0000001'), ('gps_lat = ''NaN'''),
    ('gps_lng = -181'), ('gps_lng = ''NaN'''),
    ('gps_accuracy = -1'), ('gps_accuracy = ''NaN'''),
    ('gps_diagnostico = jsonb_build_object(''so'', repeat(''x'', 400))'), ('gps_diagnostico = ''[1]''::jsonb')
  ) AS t(set_) LOOP
    BEGIN
      EXECUTE format('UPDATE public.pedidos SET %s WHERE id = %s', v_row.set_, v_ped);
      v_fallas := v_fallas || format('G4 · pedidos aceptó %s', v_row.set_)::text;
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;
  END LOOP;
  -- Los bordes entran.
  BEGIN
    UPDATE pedidos SET gps_lat = -90, gps_lng = 180, gps_accuracy = 0 WHERE id = v_ped;
  EXCEPTION WHEN check_violation THEN
    v_fallas := v_fallas || 'G4 · pedidos rechazó los bordes (-90, 180, 0)'::text;
  END;
  UPDATE pedidos SET gps_status = NULL WHERE id = v_ped;
  v_estado := NULL;
  BEGIN
    SET LOCAL ROLE authenticated;
    v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'ok', p_lat => 'NaN', p_lng => -65);
    RESET ROLE;
    v_fallas := v_fallas || format('G4 · la RPC aceptó una latitud NaN: %s', v_r)::text;
  EXCEPTION WHEN check_violation THEN
    v_estado := 'rechazado';
  END;
  RESET ROLE;

  -- ------------------------------------------------------------------- G5 ---
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_visita_cliente(p_cliente_id => v_cli, p_status => 'denied', p_motivo_omision => 'bloqueada',
                                         p_diagnostico => v_diag);
  RESET ROLE;
  v_vis := (v_r->>'visita_id')::bigint;
  SELECT gps_status, gps_motivo_omision, gps_diagnostico INTO v_row FROM visitas_cliente WHERE id = v_vis;
  IF v_vis IS NULL OR v_row.gps_status IS DISTINCT FROM 'denied' OR v_row.gps_diagnostico IS DISTINCT FROM v_diag
     OR v_row.gps_motivo_omision IS DISTINCT FROM 'bloqueada' THEN
    v_fallas := v_fallas || format('G5 · visita con diagnóstico: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_visita_cliente(p_cliente_id => v_cli, p_status => 'ok', p_lat => -26.8, p_lng => -65.2,
                                         p_accuracy => 30);
  RESET ROLE;
  SELECT gps_status, gps_diagnostico INTO v_row FROM visitas_cliente WHERE id = (v_r->>'visita_id')::bigint;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_row.gps_status IS DISTINCT FROM 'ok' OR v_row.gps_diagnostico IS NOT NULL THEN
    v_fallas := v_fallas || format('G5 · la visita del bundle viejo: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  FOR v_row IN SELECT * FROM (VALUES
    ('gps_lat = 90.5'), ('gps_lat = ''NaN'''), ('gps_lng = 180.5'), ('gps_lng = ''NaN'''),
    ('gps_accuracy = -0.01'), ('gps_accuracy = ''NaN'''), ('gps_diagnostico = ''"texto"''::jsonb')
  ) AS t(set_) LOOP
    BEGIN
      EXECUTE format('UPDATE public.visitas_cliente SET %s WHERE id = %s', v_row.set_, v_vis);
      v_fallas := v_fallas || format('G5 · visitas_cliente aceptó %s', v_row.set_)::text;
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;
  END LOOP;

  -- ------------------------------------------------------------------- G6 ---
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_rol_sin_activo()->'lecturas') l
              WHERE l->>'firma' ~ '^registrar_(geolocalizacion_pedido|visita_cliente)\(') THEN
    v_fallas := v_fallas || 'G6 · auditoria_rol_sin_activo() todavía marca una RPC de GPS'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · G0–G6 (pedido %s, cliente %s, sucursal %s; latitud NaN por la RPC: %s)',
                     v_ped, v_cli, v_suc, COALESCE(v_estado, '¿?'));
 END;
END
$ensayo$;
