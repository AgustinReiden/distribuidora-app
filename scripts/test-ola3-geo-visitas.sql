-- Ensayo de la tarjeta T8 de la ola 3 (#1690, #1554, #1623; mig 549_ola3_geo_visitas):
-- la visita con clave y el panel de Geolocalización por el día en que se cargó.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en una excepción
-- (`ENSAYO OK …` o `ENSAYO FALLO …`). Arma su contexto adentro de la transacción (corre
-- también sobre la base vacía de CI): dos preventistas activos de una sucursal sin pedidos
-- cargados hoy ni ayer, dos clientes libres y cuatro pedidos nuevos del primero, con la
-- fecha y la hora de carga de cada caso. El día es el argentino (`_tablero_hoy()`), nunca
-- CURRENT_DATE.
-- Cada caso corre en su propio bloque: sin la migración, todos dicen por qué fallan.
--
--   V0 · Una sola firma de registrar_visita_cliente (la de p_clave), DEFINER, con
--        search_path que termina en pg_temp, EXECUTE para authenticated y no para anon.
--   V1 · Var-B1: dos llamadas con la misma clave dejan UNA visita y la segunda devuelve
--        la misma (`replay`). Sin clave, cada llamada es una visita (como siempre).
--   V2 · La misma clave para otro cliente, o de otro usuario, se rechaza y no crea nada.
--   V3 · Un intento rechazado (un cliente que no existe) no gasta la clave: el siguiente
--        con esa clave registra la visita.
--   G1 · Var-B3: un pedido cargado hoy con fecha de ayer aparece hoy; uno cargado ayer con
--        fecha de hoy aparece ayer y no hoy; uno cargado ayer a las 23:30 (02:30 UTC de hoy)
--        es de ayer. Y el borde de la medianoche: uno cargado a las 00:00:00 argentinas de hoy
--        aparece hoy (el «desde» del día es inclusivo) y uno a las 23:59:59 de ayer es de ayer.
--   G2 · Var-B2: un pedido cancelado cargado hoy no cuenta (ni en el total ni «sin GPS»)
--        y no sale en el detalle.
--   G3 · #1623: un preventista con visitas y sin pedidos aparece en el resumen del día,
--        con 0 pedidos, sus visitas y su última ubicación.

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_p1     uuid;
  v_p2     uuid;
  v_cli    bigint;
  v_cli2   bigint;
  v_hoy    date := public._tablero_hoy();
  v_ayer   date := public._tablero_hoy() - 1;
  v_x      bigint;  -- cargado hoy, fecha de ayer, con GPS
  v_y      bigint;  -- cargado ayer, fecha de hoy, con GPS
  v_w      bigint;  -- cargado ayer 23:30 (AR), fecha de ayer, con GPS
  v_m0     bigint;  -- cargado hoy a las 00:00:00 (AR) justo, con GPS: el primer instante de hoy
  v_m1     bigint;  -- cargado ayer a las 23:59:59 (AR), con GPS: el último instante de ayer
  v_z      bigint;  -- cargado hoy, fecha de hoy, cancelado, sin GPS
  v_clave  uuid := gen_random_uuid();
  v_clave3 uuid := gen_random_uuid();
  v_r1     jsonb;
  v_r2     jsonb;
  v_geo    jsonb;
  v_geo_ay jsonb;
  v_res    jsonb;
  v_n      int;
  v_fallas text[] := '{}';
  F_VIS CONSTANT text := 'public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb,uuid)';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- contexto ---
  SELECT s.id, a.id INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT pf.id FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY pf.id LIMIT 1) a ON true
   WHERE s.activa
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · sin contexto: no hay una sucursal activa con un admin';
  END IF;

  -- Dos preventistas sin pedidos cargados hoy ni ayer en la sucursal: así los números del
  -- resumen son sólo los del ensayo.
  SELECT pf.id INTO v_p1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM pedidos p WHERE p.sucursal_id = v_suc AND p.usuario_id = pf.id
                      AND ((p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN v_ayer AND v_hoy
                           OR p.fecha BETWEEN v_ayer AND v_hoy))
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_p2 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.activo AND pf.rol = 'preventista' AND pf.id <> v_p1
     AND NOT EXISTS (SELECT 1 FROM pedidos p WHERE p.sucursal_id = v_suc AND p.usuario_id = pf.id
                      AND ((p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN v_ayer AND v_hoy
                           OR p.fecha BETWEEN v_ayer AND v_hoy))
   ORDER BY pf.id LIMIT 1;
  -- Dos clientes libres (sin preventista, no reservados) activos de la sucursal.
  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT c.reservado_admin
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;
  SELECT c.id INTO v_cli2 FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT c.reservado_admin AND c.id <> v_cli
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;
  IF v_p1 IS NULL OR v_p2 IS NULL OR v_cli IS NULL OR v_cli2 IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = format('ENSAYO FALLO · sin contexto: hacen falta dos preventistas sin pedidos de hoy ni de ayer y dos clientes libres (sucursal %s)', v_suc);
  END IF;

  -- Cuatro pedidos nuevos del primer preventista, con la carga de cada caso (como postgres:
  -- la fecha y la hora de carga no se eligen por la API, y acá se prueba el panel).
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, created_at,
                       gps_status, gps_lat, gps_lng, gps_capturado_at)
  VALUES (v_cli, v_suc, v_p1, 1000, 'pendiente', v_ayer, now(), 'ok', -26.8, -65.2, now())
  RETURNING id INTO v_x;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, created_at,
                       gps_status, gps_lat, gps_lng, gps_capturado_at)
  VALUES (v_cli, v_suc, v_p1, 1000, 'pendiente', v_hoy,
          (v_ayer + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'ok', -26.8, -65.2,
          (v_ayer + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires')
  RETURNING id INTO v_y;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, created_at,
                       gps_status, gps_lat, gps_lng, gps_capturado_at)
  VALUES (v_cli, v_suc, v_p1, 1000, 'pendiente', v_ayer,
          (v_ayer + time '23:30') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'ok', -26.8, -65.2,
          (v_ayer + time '23:30') AT TIME ZONE 'America/Argentina/Buenos_Aires')
  RETURNING id INTO v_w;
  -- El borde de la medianoche: el 00:00:00 de hoy es de hoy (`>=` en el «desde»), el 23:59:59 de ayer no.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, created_at,
                       gps_status, gps_lat, gps_lng, gps_capturado_at)
  VALUES (v_cli, v_suc, v_p1, 1000, 'pendiente', v_hoy,
          v_hoy::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires', 'ok', -26.8, -65.2,
          v_hoy::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires')
  RETURNING id INTO v_m0;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, created_at,
                       gps_status, gps_lat, gps_lng, gps_capturado_at)
  VALUES (v_cli, v_suc, v_p1, 1000, 'pendiente', v_ayer,
          (v_ayer + time '23:59:59') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'ok', -26.8, -65.2,
          (v_ayer + time '23:59:59') AT TIME ZONE 'America/Argentina/Buenos_Aires')
  RETURNING id INTO v_m1;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, created_at, motivo_cancelacion)
  VALUES (v_cli, v_suc, v_p1, 0, 'cancelado', v_hoy, now(), 'ensayo T8')
  RETURNING id INTO v_z;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- ------------------------------------------------------------------- V0 ---
  BEGIN
    IF to_regprocedure(F_VIS) IS NULL THEN
      v_fallas := v_fallas || 'V0 · no existe registrar_visita_cliente con p_clave'::text;
    ELSE
      IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname = 'registrar_visita_cliente') <> 1 THEN
        v_fallas := v_fallas || 'V0 · quedó más de una firma de registrar_visita_cliente'::text;
      END IF;
      IF has_function_privilege('anon', F_VIS, 'EXECUTE') OR NOT has_function_privilege('authenticated', F_VIS, 'EXECUTE')
         OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(F_VIS))
         OR (SELECT array_to_string(proconfig, ',') FROM pg_proc WHERE oid = to_regprocedure(F_VIS)) !~ 'search_path=.*pg_temp$' THEN
        v_fallas := v_fallas || 'V0 · registrar_visita_cliente no quedó DEFINER, con pg_temp y EXECUTE sólo para authenticated'::text;
      END IF;
    END IF;
  END;

  -- ------------------------------------------------------------------- V1 ---
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p2, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE 'SELECT public.registrar_visita_cliente(p_cliente_id => $1, p_status => ''ok'', p_lat => -26.81, p_lng => -65.21,
                    p_accuracy => 8, p_capturado_at => now(), p_clave => $2)' INTO v_r1 USING v_cli, v_clave;
    -- El reintento captura otra vez el GPS: la misma visita, aunque la ubicación cambie un poco.
    EXECUTE 'SELECT public.registrar_visita_cliente(p_cliente_id => $1, p_status => ''ok'', p_lat => -26.82, p_lng => -65.22,
                    p_accuracy => 12, p_capturado_at => now(), p_clave => $2)' INTO v_r2 USING v_cli, v_clave;
    RESET ROLE;
    SELECT count(*) INTO v_n FROM visitas_cliente WHERE preventista_id = v_p2 AND cliente_id = v_cli AND created_at = now();
    IF NOT COALESCE((v_r1->>'success')::boolean, false) OR NOT COALESCE((v_r2->>'success')::boolean, false)
       OR v_r2->>'visita_id' IS DISTINCT FROM v_r1->>'visita_id' OR NOT COALESCE((v_r2->>'replay')::boolean, false)
       OR v_n <> 1 THEN
      v_fallas := v_fallas || format('V1 · dos llamadas con la misma clave dejaron %s visitas (%s / %s)', v_n, v_r1, v_r2)::text;
    END IF;
    -- Sin clave (un bundle de antes): cada llamada es una visita.
    SET LOCAL ROLE authenticated;
    v_r1 := public.registrar_visita_cliente(p_cliente_id => v_cli2, p_status => 'timeout', p_motivo_omision => 'ensayo T8');
    v_r2 := public.registrar_visita_cliente(p_cliente_id => v_cli2, p_status => 'timeout', p_motivo_omision => 'ensayo T8');
    RESET ROLE;
    SELECT count(*) INTO v_n FROM visitas_cliente WHERE preventista_id = v_p2 AND cliente_id = v_cli2 AND created_at = now();
    IF v_n <> 2 OR v_r1->>'visita_id' = v_r2->>'visita_id' THEN
      v_fallas := v_fallas || format('V1 · sin clave, dos llamadas no dejaron dos visitas (%s)', v_n)::text;
    END IF;
  EXCEPTION WHEN others THEN
    RESET ROLE;
    v_fallas := v_fallas || format('V1 · error: %s', SQLERRM)::text;
  END;

  -- ------------------------------------------------------------------- V2 ---
  BEGIN
    SET LOCAL ROLE authenticated;
    EXECUTE 'SELECT public.registrar_visita_cliente(p_cliente_id => $1, p_status => ''timeout'',
                    p_motivo_omision => ''ensayo T8'', p_clave => $2)' INTO v_r1 USING v_cli2, v_clave;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p1, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE 'SELECT public.registrar_visita_cliente(p_cliente_id => $1, p_status => ''timeout'',
                    p_motivo_omision => ''ensayo T8'', p_clave => $2)' INTO v_r2 USING v_cli, v_clave;
    RESET ROLE;
    SELECT count(*) INTO v_n FROM visitas_cliente
     WHERE created_at = now() AND ((preventista_id = v_p2 AND cliente_id = v_cli2) OR preventista_id = v_p1);
    IF COALESCE((v_r1->>'success')::boolean, true) OR COALESCE((v_r2->>'success')::boolean, true) OR v_n <> 2 THEN
      v_fallas := v_fallas || format('V2 · la clave usada para otro cliente o por otro usuario no se rechazó (%s / %s, %s visitas)', v_r1, v_r2, v_n)::text;
    END IF;
  EXCEPTION WHEN others THEN
    RESET ROLE;
    v_fallas := v_fallas || format('V2 · error: %s', SQLERRM)::text;
  END;

  -- ------------------------------------------------------------------- V3 ---
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p2, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE 'SELECT public.registrar_visita_cliente(p_cliente_id => $1, p_status => ''ok'', p_lat => -26.8, p_lng => -65.2,
                    p_clave => $2)' INTO v_r1 USING -1::bigint, v_clave3;
    EXECUTE 'SELECT public.registrar_visita_cliente(p_cliente_id => $1, p_status => ''ok'', p_lat => -26.8, p_lng => -65.2,
                    p_clave => $2)' INTO v_r2 USING v_cli2, v_clave3;
    RESET ROLE;
    IF COALESCE((v_r1->>'success')::boolean, true) OR v_r1->>'error' IS DISTINCT FROM 'Cliente no existe'
       OR NOT COALESCE((v_r2->>'success')::boolean, false)
       OR COALESCE((v_r2->>'replay')::boolean, false) THEN
      v_fallas := v_fallas || format('V3 · un intento rechazado gastó la clave (%s / %s)', v_r1, v_r2)::text;
    END IF;
  EXCEPTION WHEN others THEN
    RESET ROLE;
    v_fallas := v_fallas || format('V3 · error: %s', SQLERRM)::text;
  END;

  -- G3 no depende de la clave: una visita del segundo preventista con la llamada de siempre.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p2, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_r1 := public.registrar_visita_cliente(p_cliente_id => v_cli, p_status => 'ok', p_lat => -26.83, p_lng => -65.23,
                                          p_accuracy => 9, p_capturado_at => now());
  RESET ROLE;

  -- ----------------------------------------------------- el panel, de hoy y de ayer ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_geo    := public.obtener_geolocalizacion_preventistas(v_hoy, v_hoy);
  v_geo_ay := public.obtener_geolocalizacion_preventistas(v_ayer, v_ayer);
  RESET ROLE;

  -- ------------------------------------------------------------------- G1 ---
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_geo->'pedidos') e WHERE (e->>'pedido_id')::bigint = v_x) THEN
    v_fallas := v_fallas || format('G1 · el pedido %s, cargado hoy con fecha de ayer, no aparece hoy', v_x)::text;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_geo->'pedidos') e WHERE (e->>'pedido_id')::bigint IN (v_y, v_w, v_m1)) THEN
    v_fallas := v_fallas || format('G1 · un pedido cargado ayer (%s, %s, %s) aparece hoy', v_y, v_w, v_m1)::text;
  END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(v_geo_ay->'pedidos') e WHERE (e->>'pedido_id')::bigint IN (v_y, v_w, v_m1)) <> 3
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_geo_ay->'pedidos') e WHERE (e->>'pedido_id')::bigint IN (v_x, v_m0)) THEN
    v_fallas := v_fallas || format('G1 · ayer no muestra los tres cargados ayer (%s, %s, %s) o muestra uno de hoy (%s, %s)', v_y, v_w, v_m1, v_x, v_m0)::text;
  END IF;
  -- El borde: el pedido de las 00:00:00 de hoy es de hoy (con `>` en el «desde» se caía).
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_geo->'pedidos') e WHERE (e->>'pedido_id')::bigint = v_m0) THEN
    v_fallas := v_fallas || format('G1 · el pedido %s, cargado a las 00:00:00 de hoy, no aparece hoy', v_m0)::text;
  END IF;

  -- ------------------------------------------------------------------- G2 ---
  SELECT e INTO v_res FROM jsonb_array_elements(v_geo->'preventistas') e WHERE e->>'preventista_id' = v_p1::text;
  IF v_res IS NULL OR (v_res->>'total_pedidos')::int <> 2 OR (v_res->>'pedidos_sin_gps')::int <> 0
     OR (v_res->>'pedidos_con_gps')::int <> 2 THEN
    v_fallas := v_fallas || format('G2 · el resumen de hoy del primer preventista no es 2 pedidos con GPS (el de hoy y el de las 00:00:00) y 0 sin GPS: %s', v_res)::text;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_geo->'pedidos') e WHERE (e->>'pedido_id')::bigint = v_z) THEN
    v_fallas := v_fallas || format('G2 · el pedido cancelado %s sale en el detalle', v_z)::text;
  END IF;

  -- ------------------------------------------------------------------- G3 ---
  SELECT e INTO v_res FROM jsonb_array_elements(v_geo->'preventistas') e WHERE e->>'preventista_id' = v_p2::text;
  IF v_res IS NULL THEN
    v_fallas := v_fallas || 'G3 · el preventista con visitas y sin pedidos no aparece en el resumen de hoy'::text;
  ELSIF (v_res->>'total_pedidos')::int <> 0
     OR (v_res->>'total_visitas')::int IS DISTINCT FROM (SELECT count(*)::int FROM visitas_cliente
                                                          WHERE preventista_id = v_p2 AND sucursal_id = v_suc
                                                            AND (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date = v_hoy)
     OR v_res->'ultima_ubicacion'->>'tipo' IS DISTINCT FROM 'visita' THEN
    v_fallas := v_fallas || format('G3 · el resumen del preventista sin pedidos no tiene 0 pedidos, sus visitas y su última ubicación: %s', v_res)::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLO · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · V0–V3, G1–G3 (sucursal %s, día %s; pedidos %s, %s, %s, %s, %s y %s)',
                     v_suc, v_hoy, v_x, v_y, v_w, v_m0, v_m1, v_z);
 END;
END
$ensayo$;
