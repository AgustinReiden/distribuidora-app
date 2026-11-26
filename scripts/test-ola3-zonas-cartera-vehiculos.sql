-- Ensayo de la migración 551_ola3_zonas_cartera_vehiculos (ola 3 de #1603, tarjeta T9: zonas,
-- cartera, vehículos y tablero; #1554, #1522 y #1690).
--
-- No deja rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una excepción.
-- Antes de aplicar la migración tiene que FALLAR en A1, A2, A3, A5, B1, B2, B7, C1, D1, E1, F1, F2,
-- F3, F4, F6, F7, F8, F9, F10, F11, G1, G2 y G4; después, dar 'ENSAYO OK'. A8, B6 y E3 pasan también
-- antes: son regresiones que matan a los mutantes M1c, M2c y M5b (ver el PR). Corre en una base local con
-- la semilla mínima (un admin activo de las sucursales 1 y 2) o en una copia de prod: arma sus
-- propias personas, clientes, pedidos, zonas y vehículos. Usa el día argentino (_tablero_hoy()).
--
-- Var-B4 = permisos-B7 (D12) · el admin asigna un cliente sólo a quien actúa como preventista
--   activo en la sucursal del cliente.
--   A1 · el admin le asigna un huérfano a un chofer por REST → 22023 «no actúa como preventista activo».
--   A2 · … a un encargado → 22023.
--   A3 · … a un preventista desactivado → 22023.
--   A4 · … a un preventista activo de la sucursal → entra (regresión).
--   A5 · el admin, por guardar_cliente, con preventista_ids = [chofer] → 22023 y no queda asignado.
--   A6 · el server (sin claims) le asigna el huérfano al chofer → entra (sigue como está).
--   A7 · asignar_preventista_zona como admin con un preventista activo → entra y la zona queda suya.
--   A8 · guardar_cliente, editando un cliente que ya tiene un dueño inválido (un chofer, de antes), no
--        se traba: el chofer se queda y el preventista que se suma entra (la regla mira lo que entra).
-- Var-B5 · actualizar_preventista_pedido: estado y destino.
--   B1 · pedido entregado → success false (antes lo cambiaba).
--   B2 · pedido cancelado → success false.
--   B3 · pedido pendiente, destino un chofer → success false (regresión).
--   B4 · pedido pendiente, destino el admin → entra (regresión: el selector ofrece admins).
--   B5 · pedido en camino (asignado), destino otro preventista → entra (regresión).
--   B6 · pedido en preparación → entra.
--   B7 · un chofer con el rol extra de preventista en la sucursal entra como destino; un preventista
--        desactivado no. El extra 'preventista' hoy lo prohíbe perfil_roles_rol_check: el ensayo lo
--        levanta (se revierte con todo), como el D8 de test-cartera-chofer-y-asignacion-1182-1183.
-- Var-B6 · la patente es única por sucursal.
--   C1 · la misma patente en las sucursales 1 y 2 → entran las dos (antes, la segunda daba «Ya hay…»).
--   C2 · la misma patente otra vez en la sucursal 1, escrita distinto → «Ya hay un vehículo…» (regresión).
-- Var-B9 · asignar_preventista_zona.
--   D1 · un 23505 al escribir la zona sale con un mensaje claro, no el crudo. Se provoca con un índice
--        único de prueba sobre preventista_zonas (dentro del ensayo, que se revierte): la carrera de
--        dos asignaciones a la vez la prueba scripts/concurrencia/t9-zona-y-cliente.sh.
-- Var-B11 · tablero_cobertura.
--   E1 · el mes que viene → avance_mes_pct = 0 (antes negativo) y el corte es el día anterior al inicio.
--   E2 · el mes en curso → avance entre 0 y 100 y el corte es hoy (regresión).
--   E3 · el mes pasado → avance 100 y el corte es su último día.
-- GTO-5 y Var-B7 · las lecturas de km.
--   F1 · registrar una lectura con fecha de mañana → «posterior a hoy».
--   F2 · la misma lectura dos veces (mismo día y km) → «ya está cargada».
--   F3 · una lectura que baja respecto de la anterior por fecha → «no pueden bajar».
--   F4 · una lectura en el medio que pasa a la siguiente por fecha → «no pueden bajar».
--   F5 · una lectura que sube, y otra del mismo día con menos km → entran (regresión y regla del día).
--   F6 · corregir_lectura_km como admin: la lectura queda con los km nuevos.
--   F7 · corregir es sólo del admin: el encargado y el preventista, no.
--   F8 · una corrección que rompe la serie → «no pueden bajar», y la lectura no cambia.
--   F9 · una lectura del GPS no se corrige a mano.
--   F10 · borrar una lectura manual la saca.
--   F11 · el admin parado en otra sucursal no corrige una lectura de esta.
-- D13 · el nombre de una zona es único por sucursal sin mirar mayúsculas ni espacios.
--   G1 · el admin da de alta «zt9 centro » con «ZT9 Centro» en la sucursal → 23505 que nombra «ZT9 Centro».
--   G2 · renombrar otra zona a « ZT9 CENTRO» → el mismo rechazo.
--   G3 · «ZT9 Centro» en la sucursal 2 → entra; renombrar «ZT9 Centro» a «zt9 CENTRO» (ella misma) → entra.
--   G4 · el server (sin claims) con «ZT9 CENTRO» → el mismo rechazo.
--   G5 · un preventista que intenta el alta recibe el 42501 de la RLS, sin el nombre de ninguna zona.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-ola3-zonas-cartera-vehiculos.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_p1     uuid := gen_random_uuid();
  v_p2     uuid := gen_random_uuid();
  v_pd     uuid := gen_random_uuid();
  v_tr     uuid := gen_random_uuid();
  v_tx     uuid := gen_random_uuid();
  v_enc    uuid := gen_random_uuid();
  v_h      bigint;
  v_h2     bigint;
  v_ped    bigint;
  v_z1     bigint;
  v_z2     bigint;
  v_zc     bigint;
  v_zo     bigint;
  v_veh    bigint;
  v_l1     bigint;
  v_l2     bigint;
  v_l3     bigint;
  v_lg     bigint;
  v_pat    text := 'ZT9' || lpad(floor(random() * 1000)::int::text, 3, '0') || 'Q';
  v_t      text;
  v_j      jsonb;
  v_n      int;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------- personas ---
  SELECT p.id INTO v_adm
    FROM perfiles p
   WHERE p.rol = 'admin' AND p.activo
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = 1)
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = 2)
   ORDER BY p.id LIMIT 1;
  IF v_adm IS NULL OR (SELECT count(*) FROM sucursales WHERE id IN (1, 2) AND activa) < 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de las sucursales 1 y 2, activas';
  END IF;
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't9-' || u.id || '@ensayo.invalid',
         jsonb_build_object('rol', u.rol, 'sucursal_id', 1), jsonb_build_object('nombre', u.nombre), now(), now()
    FROM (VALUES (v_p1, 'preventista', 'T9 prev uno'), (v_p2, 'preventista', 'T9 prev dos'),
                 (v_pd, 'preventista', 'T9 prev baja'), (v_tr, 'transportista', 'T9 chofer'),
                 (v_tx, 'transportista', 'T9 chofer con extra'),
                 (v_enc, 'encargado', 'T9 encargado')) AS u(id, rol, nombre);
  -- El sync con auth.users (el ban) pide una columna que la base local no tiene: se apaga para esto.
  ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
  UPDATE perfiles SET activo = false WHERE id = v_pd;
  ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;
  PERFORM set_config('et9.adm', v_adm::text, true);

  -- ---------------------------------------------------------------- helpers -
  -- Como el front: rol authenticated, como p_uid (el admin si es NULL), parado en p_suc.
  CREATE FUNCTION pg_temp.como(p_sql text, p_uid uuid DEFAULT NULL, p_suc bigint DEFAULT 1) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', COALESCE(p_uid, current_setting('et9.adm')::uuid), 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.headers', '', true);
    RETURN v;
  END $f$;
  -- NULL si anda; si no, 'SQLSTATE: mensaje'.
  CREATE FUNCTION pg_temp.err(p_sql text, p_uid uuid DEFAULT NULL, p_suc bigint DEFAULT 1) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_sql, p_uid, p_suc);
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.headers', '', true);
    RETURN SQLSTATE || ': ' || SQLERRM;
  END $f$;
  -- Lo mismo, sin claims (el server).
  CREATE FUNCTION pg_temp.err_server(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ': ' || SQLERRM;
  END $f$;
  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;
  CREATE FUNCTION pg_temp.cli(p_suc bigint DEFAULT 1) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('ZZ t9', 'ZZ t9 ' || gen_random_uuid(), 'calle t9 ' || gen_random_uuid(), p_suc) RETURNING id;
  $f$;

  v_h := pg_temp.cli();
  v_h2 := pg_temp.cli();

  -- ----------------------------------------------------------- A · D12 ------
  v_t := pg_temp.err(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L) RETURNING cliente_id::text', v_h, v_tr));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%no actúa como preventista activo%',
                                      'A1 · el admin le asignó un cliente a un chofer: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L) RETURNING cliente_id::text', v_h, v_enc));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%no actúa como preventista activo%',
                                      'A2 · el admin le asignó un cliente a un encargado: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L) RETURNING cliente_id::text', v_h, v_pd));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%no actúa como preventista activo%',
                                      'A3 · el admin le asignó un cliente a un preventista desactivado: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L) RETURNING cliente_id::text', v_h, v_p1));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_h AND preventista_id = v_p1),
                                      'A4 · el admin no pudo asignarle un cliente a un preventista activo: ' || COALESCE(v_t, '¿sin fila?'));
  DELETE FROM cliente_preventistas WHERE cliente_id = v_h;
  v_t := pg_temp.err(format('SELECT public.guardar_cliente(%L::jsonb)::text',
                            jsonb_build_object('id', v_h, 'campos', '{}'::jsonb, 'preventista_ids', jsonb_build_array(v_tr))));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%no actúa como preventista activo%'
                                      AND NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_h),
                                      'A5 · guardar_cliente le asignó un cliente a un chofer: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err_server(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L) RETURNING cliente_id::text', v_h, v_tr));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'A6 · el server no pudo asignar (tiene que seguir como está): ' || COALESCE(v_t, ''));
  -- A8 · el chofer de A6 queda como dueño inválido de antes; el admin edita el cliente y suma a P1.
  v_t := pg_temp.err(format('SELECT public.guardar_cliente(%L::jsonb)::text',
                            jsonb_build_object('id', v_h, 'campos', jsonb_build_object('notas', 'T9 edición'),
                                               'preventista_ids', jsonb_build_array(v_tr, v_p1),
                                               'preventista_ids_previos', jsonb_build_array(v_tr))));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL
                                      AND (SELECT notas FROM clientes WHERE id = v_h) = 'T9 edición'
                                      AND (SELECT array_agg(preventista_id ORDER BY preventista_id::text) FROM cliente_preventistas WHERE cliente_id = v_h)
                                          = (SELECT array_agg(x ORDER BY x::text) FROM unnest(ARRAY[v_tr, v_p1]) x),
                                      'A8 · editar un cliente con un dueño inválido de antes se trabó: ' || COALESCE(v_t, '¿sin los dos dueños?'));
  DELETE FROM cliente_preventistas WHERE cliente_id = v_h;

  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZT9 zona A ' || gen_random_uuid(), 1) RETURNING id INTO v_z1;
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZT9 zona B ' || gen_random_uuid(), 1) RETURNING id INTO v_z2;
  UPDATE clientes SET zona_id = v_z1 WHERE id = v_h2;
  v_t := pg_temp.err(format('SELECT public.asignar_preventista_zona(%s, %L, false)::text', v_z1, v_p1));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL
                                      AND (SELECT array_agg(preventista_id) FROM cliente_preventistas WHERE cliente_id = v_h2) = ARRAY[v_p1]
                                      AND (SELECT perfil_id FROM preventista_zonas WHERE zona_id = v_z1) = v_p1,
                                      'A7 · asignar_preventista_zona con un preventista activo no dejó la zona y su cliente con él: ' || COALESCE(v_t, ''));

  -- ----------------------------------------------------------- B · Var-B5 ---
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, transportista_id, estado, total, fecha_entrega)
  VALUES (v_h, 1, v_p1, v_tr, 'entregado', 0, now()) RETURNING id INTO v_ped;
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_p2))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(NOT COALESCE((v_j->>'success')::boolean, false) AND v_j->>'error' LIKE '%ya fue entregado%'
                                      AND (SELECT usuario_id FROM pedidos WHERE id = v_ped) = v_p1,
                                      'B1 · le cambió el preventista a un pedido entregado (o el motivo no lo dice): ' || v_j::text);
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, estado, total, motivo_cancelacion)
  VALUES (v_h, 1, v_p1, 'cancelado', 0, 'ensayo T9') RETURNING id INTO v_ped;
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_p2))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(NOT COALESCE((v_j->>'success')::boolean, false)
                                      AND (SELECT usuario_id FROM pedidos WHERE id = v_ped) = v_p1,
                                      'B2 · le cambió el preventista a un pedido cancelado: ' || v_j::text);
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, estado, total)
  VALUES (v_h, 1, v_p1, 'pendiente', 0) RETURNING id INTO v_ped;
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_tr))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(NOT COALESCE((v_j->>'success')::boolean, false),
                                      'B3 · un chofer quedó de vendedor del pedido: ' || v_j::text);
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_adm))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(COALESCE((v_j->>'success')::boolean, false)
                                      AND (SELECT usuario_id FROM pedidos WHERE id = v_ped) = v_adm,
                                      'B4 · el admin no pudo quedar de vendedor de un pedido pendiente: ' || v_j::text);
  UPDATE pedidos SET estado = 'asignado' WHERE id = v_ped;
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_p2))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(COALESCE((v_j->>'success')::boolean, false)
                                      AND (SELECT usuario_id FROM pedidos WHERE id = v_ped) = v_p2,
                                      'B5 · no le pudo cambiar el preventista a un pedido en camino: ' || v_j::text);
  UPDATE pedidos SET estado = 'en_preparacion' WHERE id = v_ped;
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_p1))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(COALESCE((v_j->>'success')::boolean, false)
                                      AND (SELECT usuario_id FROM pedidos WHERE id = v_ped) = v_p1,
                                      'B6 · no le pudo cambiar el preventista a un pedido en preparación: ' || v_j::text);
  ALTER TABLE public.perfil_roles DROP CONSTRAINT perfil_roles_rol_check;
  INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_tx, 1, 'preventista');
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_tx))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(COALESCE((v_j->>'success')::boolean, false)
                                      AND (SELECT usuario_id FROM pedidos WHERE id = v_ped) = v_tx,
                                      'B7 · un chofer con el extra de preventista no pudo quedar de vendedor: ' || v_j::text);
  v_j := pg_temp.como(format('SELECT public.actualizar_preventista_pedido(%s, %L)::text', v_ped, v_pd))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(NOT COALESCE((v_j->>'success')::boolean, false)
                                      AND (SELECT usuario_id FROM pedidos WHERE id = v_ped) = v_tx,
                                      'B7 · un preventista desactivado quedó de vendedor: ' || v_j::text);

  -- ----------------------------------------------------------- C · Var-B6 ---
  v_t := pg_temp.err(format('SELECT public.guardar_vehiculo(%L::jsonb)::text', jsonb_build_object('patente', v_pat, 'descripcion', 'T9 uno')));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'C1 · no se pudo dar de alta el vehículo en la sucursal 1: ' || COALESCE(v_t, ''));
  v_t := pg_temp.err(format('SELECT public.guardar_vehiculo(%L::jsonb)::text', jsonb_build_object('patente', v_pat, 'descripcion', 'T9 dos')), NULL, 2);
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND (SELECT count(*) FROM vehiculos WHERE patente = v_pat) = 2,
                                      'C1 · la misma patente en la sucursal 2 se rechazó (oráculo entre sucursales): ' || COALESCE(v_t, ''));
  v_t := pg_temp.err(format('SELECT public.guardar_vehiculo(%L::jsonb)::text',
                            jsonb_build_object('patente', ' ' || lower(left(v_pat, 3)) || ' ' || substr(v_pat, 4), 'descripcion', 'T9 tres')));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%Ya hay un vehículo con la patente%',
                                      'C2 · la patente repetida en la misma sucursal entró o dio otro error: ' || COALESCE(v_t, 'entró'));

  -- ----------------------------------------------------------- D · Var-B9 ---
  -- Un índice de prueba que choca si P1 queda dueño de dos zonas de la sucursal 1.
  EXECUTE format('CREATE UNIQUE INDEX ensayo_t9_pz ON public.preventista_zonas (sucursal_id) WHERE perfil_id = %L', v_p1);
  v_t := pg_temp.err(format('SELECT public.asignar_preventista_zona(%s, %L, false)::text', v_z2, v_p1));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '23505:%se guardó al mismo tiempo%',
                                      'D1 · el 23505 de asignar_preventista_zona salió crudo: ' || COALESCE(v_t, 'entró'));
  DROP INDEX public.ensayo_t9_pz;

  -- ---------------------------------------------------------- E · Var-B11 ---
  v_j := public.tablero_cobertura(1, (date_trunc('month', v_hoy) + interval '1 month')::date);
  v_fallas := v_fallas || pg_temp.chk((v_j->>'avance_mes_pct')::numeric = 0
                                      AND (v_j->>'corte')::date = (date_trunc('month', v_hoy) + interval '1 month')::date - 1,
                                      format('E1 · el mes que viene da avance %s y corte %s', v_j->>'avance_mes_pct', v_j->>'corte'));
  v_j := public.tablero_cobertura(1, v_hoy);
  v_fallas := v_fallas || pg_temp.chk((v_j->>'avance_mes_pct')::numeric BETWEEN 0 AND 100 AND (v_j->>'corte')::date = v_hoy,
                                      format('E2 · el mes en curso da avance %s y corte %s', v_j->>'avance_mes_pct', v_j->>'corte'));
  v_j := public.tablero_cobertura(1, (date_trunc('month', v_hoy) - interval '1 month')::date);
  v_fallas := v_fallas || pg_temp.chk((v_j->>'avance_mes_pct')::numeric = 100
                                      AND (v_j->>'corte')::date = date_trunc('month', v_hoy)::date - 1,
                                      format('E3 · el mes pasado da avance %s y corte %s', v_j->>'avance_mes_pct', v_j->>'corte'));

  -- ---------------------------------------------------------- F · km --------
  INSERT INTO vehiculos (sucursal_id, patente, descripcion, creado_por)
  VALUES (1, 'ZT9' || lpad(floor(random() * 1000)::int::text, 3, '0') || 'K', 'T9 km', v_adm) RETURNING id INTO v_veh;
  v_t := pg_temp.err(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy + 1, 100));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%posterior a hoy%', 'F1 · entró una lectura con fecha de mañana: ' || COALESCE(v_t, 'entró'));
  DELETE FROM vehiculo_km WHERE vehiculo_id = v_veh;
  v_l1 := pg_temp.como(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy - 10, 1000))::bigint;
  v_l2 := pg_temp.como(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy - 5, 2000))::bigint;
  v_t := pg_temp.err(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy - 5, 2000));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%ya está cargada%'
                                      AND (SELECT count(*) FROM vehiculo_km WHERE vehiculo_id = v_veh AND km = 2000) = 1,
                                      'F2 · la misma lectura entró dos veces: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy - 3, 1500));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%no pueden bajar%', 'F3 · entró una lectura con menos km que la anterior: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy - 7, 2500));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%no pueden bajar%', 'F4 · entró una lectura con más km que la siguiente: ' || COALESCE(v_t, 'entró'));
  DELETE FROM vehiculo_km WHERE vehiculo_id = v_veh AND id NOT IN (v_l1, v_l2);
  v_t := pg_temp.err(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy - 3, 2100));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'F5 · no entró una lectura que sube: ' || COALESCE(v_t, ''));
  v_t := pg_temp.err(format('SELECT public.registrar_km_vehiculo(%s, %L, %s)::text', v_veh, v_hoy - 3, 2050));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'F5 · no entró otra lectura del mismo día: ' || COALESCE(v_t, ''));
  SELECT id INTO v_l3 FROM vehiculo_km WHERE vehiculo_id = v_veh AND km = 2100;

  v_t := pg_temp.err(format('SELECT public.corregir_lectura_km(%s, %L, %s, false)::text', v_l2, v_hoy - 5, 2010));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND (SELECT km FROM vehiculo_km WHERE id = v_l2) = 2010,
                                      'F6 · el admin no pudo corregir la lectura: ' || COALESCE(v_t, '¿sin cambio?'));
  v_t := pg_temp.err(format('SELECT public.corregir_lectura_km(%s, %L, %s, false)::text', v_l2, v_hoy - 5, 2020), v_enc);
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%Sólo un admin puede corregir%' AND (SELECT km FROM vehiculo_km WHERE id = v_l2) = 2010,
                                      'F7 · el encargado corrigió una lectura o lo frenó otra cosa: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.corregir_lectura_km(%s, %L, %s, false)::text', v_l2, v_hoy - 5, 2030), v_p1);
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%Sólo un admin puede corregir%' AND (SELECT km FROM vehiculo_km WHERE id = v_l2) = 2010,
                                      'F7 · un preventista corrigió una lectura o lo frenó otra cosa: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.corregir_lectura_km(%s, %L, %s, false)::text', v_l1, v_hoy - 10, 3000));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%no pueden bajar%' AND (SELECT km FROM vehiculo_km WHERE id = v_l1) = 1000,
                                      'F8 · una corrección que rompe la serie entró o dio otro error: ' || COALESCE(v_t, 'entró'));
  INSERT INTO vehiculo_km (sucursal_id, vehiculo_id, fecha, km, origen) VALUES (1, v_veh, v_hoy - 1, 2500, 'gps') RETURNING id INTO v_lg;
  v_t := pg_temp.err(format('SELECT public.corregir_lectura_km(%s, %L, %s, false)::text', v_lg, v_hoy - 1, 2600));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%GPS%' AND (SELECT km FROM vehiculo_km WHERE id = v_lg) = 2500,
                                      'F9 · se corrigió a mano una lectura del GPS: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.corregir_lectura_km(%s, NULL, NULL, true)::text', v_l3));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND NOT EXISTS (SELECT 1 FROM vehiculo_km WHERE id = v_l3),
                                      'F10 · no se pudo borrar una lectura manual: ' || COALESCE(v_t, '¿sigue?'));
  v_t := pg_temp.err(format('SELECT public.corregir_lectura_km(%s, %L, %s, false)::text', v_l1, v_hoy - 10, 900), NULL, 2);
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%no es de esta sucursal%' AND (SELECT km FROM vehiculo_km WHERE id = v_l1) = 1000,
                                      'F11 · el admin parado en otra sucursal corrigió la lectura: ' || COALESCE(v_t, 'entró'));

  -- ---------------------------------------------------------- G · D13 -------
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZT9 Centro', 1) RETURNING id INTO v_zc;
  v_t := pg_temp.err($q$INSERT INTO public.zonas (nombre, sucursal_id) VALUES ('zt9 centro ', 1) RETURNING id::text$q$);
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '23505:%Ya existe la zona «ZT9 Centro»%',
                                      'G1 · entró «zt9 centro » con «ZT9 Centro» en la sucursal, o el rechazo no la nombra: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format($q$UPDATE public.zonas SET nombre = ' ZT9 CENTRO' WHERE id = %s RETURNING id::text$q$, v_z2));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '23505:%Ya existe la zona «ZT9 Centro»%',
                                      'G2 · se pudo renombrar otra zona a « ZT9 CENTRO»: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err($q$INSERT INTO public.zonas (nombre, sucursal_id) VALUES ('ZT9 Centro', 2) RETURNING id::text$q$, NULL, 2);
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'G3 · el mismo nombre en otra sucursal no entró: ' || COALESCE(v_t, ''));
  v_t := pg_temp.err(format($q$UPDATE public.zonas SET nombre = 'zt9 CENTRO' WHERE id = %s RETURNING id::text$q$, v_zc));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND (SELECT nombre FROM zonas WHERE id = v_zc) = 'zt9 CENTRO',
                                      'G3 · no se pudo cambiar las mayúsculas del nombre de la misma zona: ' || COALESCE(v_t, ''));
  v_t := pg_temp.err_server($q$INSERT INTO public.zonas (nombre, sucursal_id) VALUES ('ZT9 CENTRO', 1)$q$);
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '23505:%Ya existe la zona «zt9 CENTRO»%',
                                      'G4 · el server dio de alta una zona repetida: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err($q$INSERT INTO public.zonas (nombre, sucursal_id) VALUES ('ZT9 CENTRO', 1) RETURNING id::text$q$, v_p1);
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '42501:%' AND v_t NOT LIKE '%ZT9%' AND v_t NOT LIKE '%zt9%',
                                      'G5 · el alta de un preventista no dio el 42501 de la RLS (o nombró la zona): ' || COALESCE(v_t, 'entró'));

  -- ------------------------------------------------------------- veredicto ---
  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · ola 3, tarjeta T9 (A1-A8 B1-B7 C1-C2 D1 E1-E3 F1-F11 G1-G5)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · %', array_to_string(v_fallas, E'\n  · ');
END
$ensayo$;
