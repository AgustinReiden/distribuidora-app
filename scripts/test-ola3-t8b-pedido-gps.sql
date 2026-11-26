-- Ensayo de la tanda T8b de la ola 3 (#1690, permisos-B4 de #1677; mig 555_ola3_t8b_pedido_gps):
-- el GPS del pedido vive en pedido_gps, que el chofer no lee.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en una excepción
-- (`ENSAYO OK …` o `ENSAYO FALLO …`). Arma su contexto adentro de la transacción (corre
-- también sobre la base vacía de CI): una sucursal activa con un admin, un encargado, un
-- preventista y un chofer, un cliente activo de la sucursal y dos pedidos nuevos del
-- preventista, asignados al chofer. El día es el argentino (`_tablero_hoy()`).
-- Sin la migración falla en A1 (pedidos todavía tiene las columnas y pedido_gps no existe).
--
--   A1 · pedidos sin ninguna columna gps_; pedido_gps con RLS, una sola FK (la compuesta a
--        pedidos), SELECT para authenticated y nada más, nada para anon, una sola policy (de
--        SELECT); las dos RPC con una firma, DEFINER, search_path con pg_temp, EXECUTE para
--        authenticated y no para anon.
--   B1 · El alta sigue guardando el GPS: el preventista registra un ok por la RPC y queda la
--        fila en pedido_gps (con la sucursal del pedido).
--   B2 · Las reglas de siempre: un no-ok después de un ok no pisa (ya_registrado); un no-ok
--        con motivo y diagnóstico entra; otro no-ok no lo pisa; un ok sí, y borra el motivo.
--   C1 · El chofer ve el pedido que reparte pero no su GPS: la fila de pedidos no trae
--        ninguna clave gps_ y pedido_gps le da 0 filas. Tampoco el panel (42501).
--   C2 · El encargado y el propio preventista tampoco leen pedido_gps (lo más cerrado; decisión
--        abierta del dueño para el propio). anon no tiene SELECT.
--   C3 · El admin sí: por REST en su sucursal activa (y no parado en otra), y por el panel.
--   E1 · El panel da lo mismo que antes: cada pedido trae las mismas claves de siempre, el GPS
--        es el de pedido_gps, la distancia sale de esas coordenadas, y un pedido sin fila sale
--        con gps_status NULL y cuenta «sin GPS».
--   D1 · Los frenos de la tabla: latitud 91 o −90,0000001, longitud −181, precisión −1, NaN en
--        las tres, un diagnóstico que no es objeto o de más de 300 bytes, un estado que no
--        existe, un ok sin coordenadas, un no-ok con coordenadas, un ok con motivo → 23514; los
--        bordes (−90, 180, 0) entran; un pedido de otra sucursal → 23503 (la FK compuesta).
--   D2 · Por la RPC, una latitud NaN tampoco entra.

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_suc2   bigint;
  v_adm    uuid;
  v_enc    uuid;
  v_prev   uuid;
  v_chof   uuid;
  v_cli    bigint;
  v_ped    bigint;   -- con GPS ok
  v_ped2   bigint;   -- denied y después ok
  v_ped3   bigint;   -- sin check-in
  v_hoy    date := public._tablero_hoy();
  v_r      jsonb;
  v_geo    jsonb;
  v_e      jsonb;
  v_row    record;
  v_n      int;
  v_txt    text;
  v_fallas text[] := '{}';
  v_diag   CONSTANT jsonb := '{"permiso":"denied","error":1,"instalada":true}';
  F_GEO CONSTANT text := 'public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)';
  F_PAN CONSTANT text := 'public.obtener_geolocalizacion_preventistas(date,date)';
  CLAVES CONSTANT text := 'cliente_id,cliente_lat,cliente_lng,cliente_nombre,distancia_m,fecha,gps_accuracy,gps_capturado_at,gps_lat,gps_lng,gps_status,pedido_created_at,pedido_id,preventista_id,total';
BEGIN
 BEGIN
  -- ------------------------------------------------------------------- A1 ---
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'pedidos' AND column_name LIKE 'gps\_%')
     OR to_regclass('public.pedido_gps') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · A1: pedidos todavía tiene el GPS, o pedido_gps no existe (falta la migración)';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pedido_gps'::regclass) THEN
    v_fallas := v_fallas || 'A1 · pedido_gps sin RLS'::text;
  END IF;
  IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.pedido_gps'::regclass AND contype = 'f') <> 1
     OR NOT EXISTS (SELECT 1 FROM pg_constraint
                     WHERE conrelid = 'public.pedido_gps'::regclass AND contype = 'f'
                       AND confrelid = 'public.pedidos'::regclass AND cardinality(conkey) = 2) THEN
    v_fallas := v_fallas || 'A1 · pedido_gps no tiene una sola FK, la compuesta (pedido_id, sucursal_id) a pedidos'::text;
  END IF;
  SELECT string_agg(grantee || ':' || privilege_type, ',' ORDER BY grantee, privilege_type) INTO v_txt
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'pedido_gps' AND grantee IN ('anon', 'authenticated', 'PUBLIC');
  IF v_txt IS DISTINCT FROM 'authenticated:SELECT'
     OR has_table_privilege('anon', 'public.pedido_gps', 'SELECT') THEN
    v_fallas := v_fallas || format('A1 · los grants REST de pedido_gps son %s (se espera sólo SELECT de authenticated)', v_txt)::text;
  END IF;
  IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.pedido_gps'::regclass) <> 1
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.pedido_gps'::regclass AND polcmd <> 'r') THEN
    v_fallas := v_fallas || 'A1 · pedido_gps tiene que tener una sola policy, de SELECT'::text;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('registrar_geolocalizacion_pedido', 'obtener_geolocalizacion_preventistas')) <> 2
     OR to_regprocedure(F_GEO) IS NULL OR to_regprocedure(F_PAN) IS NULL THEN
    v_fallas := v_fallas || 'A1 · no hay exactamente una firma de cada RPC'::text;
  ELSIF has_function_privilege('anon', F_GEO, 'EXECUTE') OR has_function_privilege('anon', F_PAN, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', F_GEO, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', F_PAN, 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc WHERE oid IN (to_regprocedure(F_GEO), to_regprocedure(F_PAN))
                 AND (NOT prosecdef OR proconfig::text IS DISTINCT FROM '{"search_path=public, pg_temp"}')) THEN
    v_fallas := v_fallas || 'A1 · EXECUTE, DEFINER o search_path de las RPC del GPS no quedaron bien'::text;
  END IF;

  -- ------------------------------------------------------------- contexto ---
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                  WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin')
     AND EXISTS (SELECT 1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                  WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado')
     AND EXISTS (SELECT 1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                  WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista')
     AND EXISTS (SELECT 1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                  WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista')
     AND EXISTS (SELECT 1 FROM clientes c WHERE c.sucursal_id = s.id AND c.activo)
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · sin contexto: hace falta una sucursal activa con admin, encargado, preventista, chofer y un cliente';
  END IF;
  SELECT pf.id INTO v_adm FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'admin' ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_enc FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'encargado' ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_prev FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'preventista' ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_chof FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'transportista' ORDER BY pf.id LIMIT 1;
  SELECT c.id INTO v_cli FROM clientes c WHERE c.sucursal_id = v_suc AND c.activo ORDER BY c.id LIMIT 1;
  SELECT s.id INTO v_suc2 FROM sucursales s WHERE s.id <> v_suc ORDER BY s.id LIMIT 1;

  -- Tres pedidos del preventista, cargados hoy, asignados al chofer (como postgres: acá se
  -- prueba quién lee el GPS, no el alta).
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, transportista_id, total, estado, fecha, created_at)
  VALUES (v_cli, v_suc, v_prev, v_chof, 1000, 'asignado', v_hoy, now()) RETURNING id INTO v_ped;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, transportista_id, total, estado, fecha, created_at)
  VALUES (v_cli, v_suc, v_prev, v_chof, 1000, 'asignado', v_hoy, now()) RETURNING id INTO v_ped2;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, transportista_id, total, estado, fecha, created_at)
  VALUES (v_cli, v_suc, v_prev, v_chof, 1000, 'asignado', v_hoy, now()) RETURNING id INTO v_ped3;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- ------------------------------------------------------------------- B1 ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'ok', p_lat => -26.8241,
                                                 p_lng => -65.2226, p_accuracy => 12.5);
  RESET ROLE;
  SELECT * INTO v_row FROM pedido_gps WHERE pedido_id = v_ped;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR (v_r ? 'ya_registrado')
     OR v_row.gps_status IS DISTINCT FROM 'ok' OR v_row.gps_lat IS DISTINCT FROM -26.8241
     OR v_row.gps_lng IS DISTINCT FROM -65.2226 OR v_row.gps_accuracy IS DISTINCT FROM 12.5
     OR v_row.sucursal_id IS DISTINCT FROM v_suc OR v_row.gps_capturado_at IS NULL THEN
    v_fallas := v_fallas || format('B1 · el alta no guardó el GPS en pedido_gps: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;

  -- ------------------------------------------------------------------- B2 ---
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped, p_status => 'denied', p_motivo_omision => 'x');
  RESET ROLE;
  SELECT * INTO v_row FROM pedido_gps WHERE pedido_id = v_ped;
  IF NOT COALESCE((v_r->>'ya_registrado')::boolean, false) OR v_row.gps_status IS DISTINCT FROM 'ok'
     OR v_row.gps_lat IS DISTINCT FROM -26.8241 THEN
    v_fallas := v_fallas || format('B2 · un denied pisó el ok: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped2, p_status => 'denied',
                                                 p_motivo_omision => 'no me deja activarla', p_diagnostico => v_diag);
  RESET ROLE;
  SELECT * INTO v_row FROM pedido_gps WHERE pedido_id = v_ped2;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR v_row.gps_status IS DISTINCT FROM 'denied'
     OR v_row.gps_motivo_omision IS DISTINCT FROM 'no me deja activarla' OR v_row.gps_diagnostico IS DISTINCT FROM v_diag
     OR v_row.gps_lat IS NOT NULL THEN
    v_fallas := v_fallas || format('B2 · denied con motivo y diagnóstico: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped2, p_status => 'timeout', p_motivo_omision => 'otro');
  RESET ROLE;
  SELECT * INTO v_row FROM pedido_gps WHERE pedido_id = v_ped2;
  IF NOT COALESCE((v_r->>'ya_registrado')::boolean, false) OR v_row.gps_status IS DISTINCT FROM 'denied'
     OR v_row.gps_motivo_omision IS DISTINCT FROM 'no me deja activarla' THEN
    v_fallas := v_fallas || format('B2 · un no-ok pisó otro no-ok: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  SET LOCAL ROLE authenticated;
  v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped2, p_status => 'ok', p_lat => -26.9,
                                                 p_lng => -65.3, p_accuracy => 40);
  RESET ROLE;
  SELECT * INTO v_row FROM pedido_gps WHERE pedido_id = v_ped2;
  IF NOT COALESCE((v_r->>'success')::boolean, false) OR (v_r ? 'ya_registrado')
     OR v_row.gps_status IS DISTINCT FROM 'ok' OR v_row.gps_lat IS DISTINCT FROM -26.9
     OR v_row.gps_motivo_omision IS NOT NULL OR v_row.gps_diagnostico IS NOT NULL THEN
    v_fallas := v_fallas || format('B2 · un ok no reemplazó al denied: %s / %s', v_r, row_to_json(v_row))::text;
  END IF;
  IF (SELECT count(*) FROM pedido_gps WHERE pedido_id IN (v_ped, v_ped2, v_ped3)) <> 2 THEN
    v_fallas := v_fallas || 'B2 · pedido_gps no tiene una fila por pedido con check-in (y ninguna del que no lo tiene)'::text;
  END IF;

  -- ------------------------------------------------------------------- C1 ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_chof, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM pedidos WHERE id = v_ped;
  SELECT string_agg(k, ',') INTO v_txt
    FROM pedidos p, jsonb_object_keys(to_jsonb(p)) k WHERE p.id = v_ped AND k LIKE 'gps%';
  IF v_n <> 1 THEN
    RESET ROLE;
    v_fallas := v_fallas || 'C1 · el chofer no ve el pedido que reparte (el ensayo no prueba nada)'::text;
  ELSE
    SELECT count(*) INTO v_n FROM pedido_gps WHERE pedido_id IN (v_ped, v_ped2);
    RESET ROLE;
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || format('C1 · la fila de pedidos que lee el chofer trae %s', v_txt)::text;
    END IF;
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format('C1 · el chofer lee %s filas de pedido_gps', v_n)::text;
    END IF;
  END IF;
  BEGIN
    SET LOCAL ROLE authenticated;
    v_geo := public.obtener_geolocalizacion_preventistas(v_hoy, v_hoy);
    RESET ROLE;
    v_fallas := v_fallas || 'C1 · el chofer abrió el panel de Geolocalización'::text;
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;

  -- ------------------------------------------------------------------- C2 ---
  FOR v_row IN SELECT * FROM (VALUES ('encargado', v_enc), ('preventista dueño', v_prev)) AS t(quien, uid) LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_row.uid, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_n FROM pedido_gps WHERE pedido_id IN (v_ped, v_ped2);
    RESET ROLE;
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format('C2 · el %s lee %s filas de pedido_gps', v_row.quien, v_n)::text;
    END IF;
  END LOOP;

  -- ------------------------------------------------------------------- C3 ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM pedido_gps WHERE pedido_id IN (v_ped, v_ped2);
  RESET ROLE;
  IF v_n <> 2 THEN
    v_fallas := v_fallas || format('C3 · el admin lee %s filas de pedido_gps en su sucursal (se esperan 2)', v_n)::text;
  END IF;
  IF v_suc2 IS NOT NULL THEN
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc2::text)::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_n FROM pedido_gps WHERE pedido_id IN (v_ped, v_ped2);
    RESET ROLE;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    IF v_n <> 0 THEN
      v_fallas := v_fallas || 'C3 · el admin parado en otra sucursal lee el GPS de esta'::text;
    END IF;
  END IF;
  v_geo := NULL;
  BEGIN
    SET LOCAL ROLE authenticated;
    v_geo := public.obtener_geolocalizacion_preventistas(v_hoy, v_hoy);
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || format('C3 · el panel le falló al admin: %s', SQLERRM)::text;
  END;

  -- ------------------------------------------------------------------- E1 ---
  IF v_geo IS NOT NULL THEN
    SELECT e INTO v_e FROM jsonb_array_elements(v_geo->'pedidos') e WHERE (e->>'pedido_id')::bigint = v_ped;
    IF v_e IS NULL THEN
      v_fallas := v_fallas || 'E1 · el pedido con GPS no sale en el panel'::text;
    ELSE
      SELECT string_agg(k, ',' ORDER BY k) INTO v_txt FROM jsonb_object_keys(v_e) k;
      IF v_txt IS DISTINCT FROM CLAVES THEN
        v_fallas := v_fallas || format('E1 · el pedido del panel trae otras claves: %s', v_txt)::text;
      END IF;
      IF (v_e->>'gps_status') IS DISTINCT FROM 'ok' OR (v_e->>'gps_lat')::numeric IS DISTINCT FROM -26.8241
         OR (v_e->>'gps_lng')::numeric IS DISTINCT FROM -65.2226 OR (v_e->>'gps_accuracy')::numeric IS DISTINCT FROM 12.5
         OR (v_e->>'gps_capturado_at') IS NULL
         OR (v_e->>'distancia_m')::numeric IS DISTINCT FROM
            (SELECT public.haversine_m(-26.8241, -65.2226, c.latitud, c.longitud)::numeric FROM clientes c WHERE c.id = v_cli) THEN
        v_fallas := v_fallas || format('E1 · el GPS del panel no es el de pedido_gps: %s', v_e)::text;
      END IF;
    END IF;
    SELECT e INTO v_e FROM jsonb_array_elements(v_geo->'pedidos') e WHERE (e->>'pedido_id')::bigint = v_ped3;
    IF v_e IS NULL OR (v_e->>'gps_status') IS NOT NULL OR (v_e->>'gps_lat') IS NOT NULL THEN
      v_fallas := v_fallas || format('E1 · el pedido sin check-in no sale, o sale con GPS: %s', v_e)::text;
    END IF;
    SELECT e INTO v_e FROM jsonb_array_elements(v_geo->'preventistas') e WHERE (e->>'preventista_id')::uuid = v_prev;
    IF v_e IS NULL
       OR (v_e->>'pedidos_con_gps')::int
          <> (SELECT count(*) FROM pedidos p JOIN pedido_gps g ON g.pedido_id = p.id
               WHERE p.sucursal_id = v_suc AND p.usuario_id = v_prev AND p.estado <> 'cancelado'
                 AND g.gps_status = 'ok'
                 AND p.created_at >= v_hoy::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires'
                 AND p.created_at < (v_hoy + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
       OR (v_e->>'pedidos_sin_gps')::int < 1
       OR (v_e->'ultima_ubicacion') IS NULL OR jsonb_typeof(v_e->'ultima_ubicacion') <> 'object' THEN
      v_fallas := v_fallas || format('E1 · el resumen del preventista no cuenta el GPS de pedido_gps: %s', v_e)::text;
    END IF;
  END IF;

  -- ------------------------------------------------------------------- D1 ---
  FOR v_row IN SELECT * FROM (VALUES
    ('''ok'', 91, -65, 1, NULL, NULL'), ('''ok'', -90.0000001, -65, 1, NULL, NULL'), ('''ok'', ''NaN'', -65, 1, NULL, NULL'),
    ('''ok'', -26, -181, 1, NULL, NULL'), ('''ok'', -26, ''NaN'', 1, NULL, NULL'),
    ('''ok'', -26, -65, -1, NULL, NULL'), ('''ok'', -26, -65, ''NaN'', NULL, NULL'),
    ('''denied'', NULL, NULL, NULL, NULL, ''[1]''::jsonb'),
    ('''denied'', NULL, NULL, NULL, NULL, jsonb_build_object(''so'', repeat(''x'', 400))'),
    ('''perdido'', NULL, NULL, NULL, NULL, NULL'),
    ('''ok'', NULL, NULL, NULL, NULL, NULL'), ('''ok'', -26, NULL, NULL, NULL, NULL'),
    ('''denied'', -26, -65, NULL, NULL, NULL'), ('''timeout'', NULL, NULL, 10, NULL, NULL'),
    ('''ok'', -26, -65, 1, ''motivo'', NULL')
  ) AS t(vals) LOOP
    BEGIN
      EXECUTE format('INSERT INTO public.pedido_gps (pedido_id, sucursal_id, gps_status, gps_lat, gps_lng, gps_accuracy, gps_motivo_omision, gps_diagnostico) VALUES (%s, %s, %s)',
                     v_ped3, v_suc, v_row.vals);
      v_fallas := v_fallas || format('D1 · pedido_gps aceptó (%s)', v_row.vals)::text;
      DELETE FROM pedido_gps WHERE pedido_id = v_ped3;
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;
  END LOOP;
  BEGIN
    INSERT INTO pedido_gps (pedido_id, sucursal_id, gps_status, gps_lat, gps_lng, gps_accuracy)
    VALUES (v_ped3, v_suc, 'ok', -90, 180, 0);
    DELETE FROM pedido_gps WHERE pedido_id = v_ped3;
  EXCEPTION WHEN check_violation THEN
    v_fallas := v_fallas || 'D1 · pedido_gps rechazó los bordes (-90, 180, 0)'::text;
  END;
  IF v_suc2 IS NOT NULL THEN
    BEGIN
      INSERT INTO pedido_gps (pedido_id, sucursal_id, gps_status) VALUES (v_ped3, v_suc2, 'denied');
      v_fallas := v_fallas || 'D1 · pedido_gps aceptó la fila de un pedido con otra sucursal'::text;
    EXCEPTION WHEN foreign_key_violation THEN
      NULL;
    END;
  END IF;

  -- ------------------------------------------------------------------- D2 ---
  v_txt := NULL;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
  BEGIN
    SET LOCAL ROLE authenticated;
    v_r := public.registrar_geolocalizacion_pedido(p_pedido_id => v_ped3, p_status => 'ok', p_lat => 'NaN', p_lng => -65);
    RESET ROLE;
    v_fallas := v_fallas || format('D2 · la RPC aceptó una latitud NaN: %s', v_r)::text;
  EXCEPTION WHEN check_violation THEN
    v_txt := 'rechazada';
  END;
  RESET ROLE;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · A1, B1–B2, C1–C3, E1, D1–D2 (sucursal %s, pedidos %s, %s y %s; latitud NaN por la RPC: %s)',
                     v_suc, v_ped, v_ped2, v_ped3, COALESCE(v_txt, '¿?'));
 END;
END
$ensayo$;
