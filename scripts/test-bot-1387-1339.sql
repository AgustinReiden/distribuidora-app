-- Ensayo de #1387 y #1339 (migración NNN_el_bot_recupera_el_resumen_y_el_panel_distingue).
--   1 · El resumen perdido (#1387.1, decisión del dueño 02/11): si el de ayer no
--       salió, hoy sale también, un día atrás y no más, con su fecha y marcado
--       como atrasado, antes que el de hoy. Con la misma hora que el de hoy y el
--       día de la semana del envío perdido. 'ok', 'skipped' y 'enviando' no lo
--       reintentan (una marca en 'enviando' es una corrida que murió en el medio:
--       no se manda dos veces); 'error' sí. Reservarlo lo saca de la lista.
--   2 · El último pedido de la ficha del bot (#1387.2) es `MAX(pedidos.fecha)`,
--       no la hora de carga.
--   3 · El panel del resumen (#1387.3) mira usuario_sucursales, como
--       bot_digest_suscripciones: una fila por persona con el chat que recibe y
--       sus sucursales activas; sin ninguna, no se lo puede prender pero sí
--       apagar; con una asignada y /sucursal en NULL, se lo puede prender.
--   4 · El panel del bot (#1339): distingue "apagado por un admin" de
--       "desvinculado", y un admin le pone la marca a un usuario ya inactivo sin
--       prenderlo.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que inserta se deshace. Los usuarios del ensayo se
-- dan de alta en auth.users como lo hace GoTrue (ver test-alta-usuario-1243).
-- Las fechas del resumen son de 2030: ninguna marca real las toca.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración falla; después, pasa.
--
--   psql "$DATABASE_URL" -f scripts/test-bot-1387-1339.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_otra    bigint;
  v_admin   uuid := gen_random_uuid();   -- recibe el resumen
  v_jefe    uuid := gen_random_uuid();   -- el admin que mira el panel
  v_prev    uuid := gen_random_uuid();   -- preventista con /sucursal en NULL
  v_solo    uuid := gen_random_uuid();   -- admin sin ninguna sucursal
  v_tg      bigint := -990138701;
  v_tg2     bigint := -990138702;
  v_tgp     bigint := -990138703;
  v_tgs     bigint := -990138704;
  v_app     jsonb;
  -- El envío de hoy resume el martes 08/01/2030; el de ayer, el lunes 07/01.
  v_fecha   date := DATE '2030-01-08';
  v_dow     int  := EXTRACT(ISODOW FROM DATE '2030-01-09')::int;  -- hoy: miércoles
  v_j       json;
  v_n       int;
  v_m       int;
  v_ok      boolean;
  v_txt     text;
  v_txt2    text;
  v_txt3    text;
  v_nombre  text;
  v_cli     bigint;
BEGIN
  SELECT id INTO v_otra FROM sucursales WHERE id <> 1 AND activa IS TRUE ORDER BY id LIMIT 1;
  IF v_otra IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: hace falta una sucursal activa además de la 1';
  END IF;

  v_app := jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'),
                              'rol', 'admin', 'sucursal_id', 1);
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1387-a@ensayo.invalid', v_app, '{"nombre":"Ensayo Resumen"}', now(), now()),
         (v_jefe, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1387-b@ensayo.invalid', v_app, '{"nombre":"Ensayo Jefe"}', now(), now()),
         (v_solo, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1387-d@ensayo.invalid', v_app, '{"nombre":"Ensayo Sin Sucursal"}', now(), now()),
         (v_prev, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1387-c@ensayo.invalid',
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'),
                             'rol', 'preventista', 'sucursal_id', 1),
          '{"nombre":"Ensayo Preventista"}', now(), now());
  -- El jefe abarca las dos sucursales; el admin del resumen, sólo la 1.
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default)
  VALUES (v_jefe, v_otra, false) ON CONFLICT DO NOTHING;
  DELETE FROM usuario_sucursales WHERE usuario_id = v_solo;

  INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
  VALUES (v_tg, v_admin, 'admin', 1, true);
  INSERT INTO bot_digest_config (perfil_id, activo, hora_local, dias_semana)
  VALUES (v_admin, true, 9, ARRAY[1,2,3,4,5,6,7]::smallint[]);

  -- ------------------------------------------- 1 · el resumen perdido ---------
  -- Sin ninguna marca: el de hoy y el de ayer, el atrasado primero.
  SELECT json_agg(json_build_object('fecha', e->>'fecha', 'atrasado', e->>'atrasado') ORDER BY o)
    INTO v_j
    FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 10, v_dow)) WITH ORDINALITY AS x(e, o)
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_j::jsonb IS DISTINCT FROM
     jsonb_build_array(jsonb_build_object('fecha', '2030-01-07', 'atrasado', 'true'),
                       jsonb_build_object('fecha', '2030-01-08', 'atrasado', 'false')) THEN
    v_fallas := v_fallas || format('1.1 · sin marcas tenía que tocarle el de ayer (primero) y el de hoy: %s', v_j);
  END IF;

  -- Antes de su hora, ninguno de los dos: el atrasado sale con el de hoy.
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 8, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('1.2 · antes de su hora ya le tocaba algo (%s filas)', v_n);
  END IF;

  -- Nunca dos días atrás: el de anteayer sin marca no vuelve.
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 23, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin AND (e->>'fecha')::date < v_fecha - 1;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('1.3 · devolvió un resumen de más de un día atrás (%s filas)', v_n);
  END IF;

  -- Cada marca del de ayer: 'ok', 'skipped' y 'enviando' lo sacan; 'error', no.
  FOREACH v_txt IN ARRAY ARRAY['ok', 'skipped', 'enviando', 'error'] LOOP
    DELETE FROM bot_digests_enviados WHERE admin_perfil_id = v_admin;
    INSERT INTO bot_digests_enviados (admin_perfil_id, fecha, sucursal_id, telegram_user_id, status, sent_at)
    VALUES (v_admin, v_fecha - 1, 1, v_tg, v_txt, now());
    SELECT count(*) FILTER (WHERE (e->>'fecha')::date = v_fecha - 1),
           count(*) FILTER (WHERE (e->>'fecha')::date = v_fecha)
      INTO v_n, v_m
      FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 10, v_dow)) e
     WHERE (e->>'perfil_id')::uuid = v_admin;
    IF v_n <> (CASE WHEN v_txt = 'error' THEN 1 ELSE 0 END) OR v_m <> 1 THEN
      v_fallas := v_fallas || format('1.4 · con el de ayer en %L: %s atrasados y %s de hoy', v_txt, v_n, v_m);
    END IF;
  END LOOP;

  -- Reservar el atrasado lo saca (y una segunda reserva pierde: no hay doble envío).
  DELETE FROM bot_digests_enviados WHERE admin_perfil_id = v_admin;
  IF NOT public.bot_digest_reservar(v_admin, 1, v_fecha - 1, v_tg) THEN
    v_fallas := v_fallas || '1.5 · la reserva del atrasado no ganó'::text;
  END IF;
  IF public.bot_digest_reservar(v_admin, 1, v_fecha - 1, v_tg) THEN
    v_fallas := v_fallas || '1.6 · la segunda reserva del atrasado también ganó: doble envío'::text;
  END IF;
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 10, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin AND (e->>'atrasado')::boolean;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('1.7 · reservado, el atrasado siguió en la lista (%s)', v_n);
  END IF;
  DELETE FROM bot_digests_enviados WHERE admin_perfil_id = v_admin;

  -- El día de la semana del atrasado es el del envío perdido (ayer), no hoy.
  UPDATE bot_digest_config SET dias_semana = ARRAY[EXTRACT(ISODOW FROM v_fecha)::smallint]
   WHERE perfil_id = v_admin;
  SELECT count(*) FILTER (WHERE (e->>'atrasado')::boolean), count(*) FILTER (WHERE NOT (e->>'atrasado')::boolean)
    INTO v_n, v_m
    FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 10, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 1 OR v_m <> 0 THEN
    v_fallas := v_fallas || format('1.8 · con sólo el día de ayer: %s atrasados (1) y %s de hoy (0)', v_n, v_m);
  END IF;
  UPDATE bot_digest_config SET dias_semana = ARRAY[v_dow::smallint] WHERE perfil_id = v_admin;
  SELECT count(*) FILTER (WHERE (e->>'atrasado')::boolean), count(*) FILTER (WHERE NOT (e->>'atrasado')::boolean)
    INTO v_n, v_m
    FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 10, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 0 OR v_m <> 1 THEN
    v_fallas := v_fallas || format('1.9 · con sólo el día de hoy: %s atrasados (0) y %s de hoy (1)', v_n, v_m);
  END IF;
  UPDATE bot_digest_config SET dias_semana = ARRAY[1,2,3,4,5,6,7]::smallint[] WHERE perfil_id = v_admin;

  -- Las dos fechas, por cada sucursal asignada.
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_admin, v_otra, false);
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 10, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 4 THEN
    v_fallas := v_fallas || format('1.10 · con dos sucursales tenían que ser 4 filas (2 días × 2), fueron %s', v_n);
  END IF;
  DELETE FROM usuario_sucursales WHERE usuario_id = v_admin AND sucursal_id = v_otra;

  -- ------------------------------------------- 2 · el último pedido -----------
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ENSAYO 1387', 'ENSAYO 1387', 'Ensayo 1387', 1)
  RETURNING id INTO v_cli;
  -- El del 25/10 se cargó antes; el del 20/10, después (lo cargado último no es
  -- lo más nuevo).
  INSERT INTO pedidos (cliente_id, sucursal_id, total, estado, estado_pago, fecha, created_at)
  VALUES (v_cli, 1, 100, 'pendiente', 'pendiente', DATE '2026-10-25', now() - interval '2 days'),
         (v_cli, 1, 100, 'pendiente', 'pendiente', DATE '2026-10-20', now());
  v_txt := public.obtener_resumen_cuenta_cliente_bot(v_cli::int) ->> 'ultimo_pedido';
  IF v_txt IS DISTINCT FROM '2026-10-25' THEN
    v_fallas := v_fallas || format('2.1 · ultimo_pedido tenía que ser la fecha 2026-10-25, fue %s', v_txt);
  END IF;

  -- ------------------------------------------- 3 · el panel del resumen -------
  -- El preventista: sucursal 1 asignada, /sucursal en NULL, dos chats prendidos.
  INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo, vinculado_at)
  VALUES (v_tgp, v_prev, 'preventista', NULL, true, now()),
         (v_tg2, v_prev, 'preventista', NULL, true, now() - interval '1 day');
  -- El admin sin ninguna sucursal: su propio panel.
  INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
  VALUES (v_tgs, v_solo, 'admin', 1, true);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_jefe, 'role', 'authenticated')::text, true);
  -- Una fila por persona, con el chat más nuevo y la sucursal asignada, no /sucursal.
  SELECT count(*), max(e->>'telegram_user_id'), max((e->'sucursales')::text), max(e->>'sucursal_nombre')
    INTO v_n, v_txt, v_j, v_nombre
    FROM json_array_elements(public.bot_admin_listar_config_digest()) e
   WHERE (e->>'perfil_id')::uuid = v_prev;
  IF v_n <> 1 OR v_txt IS DISTINCT FROM v_tgp::text
     OR v_j::jsonb IS DISTINCT FROM (SELECT jsonb_build_array(jsonb_build_object('id', 1, 'nombre', nombre))
                                       FROM sucursales WHERE id = 1)
     OR v_nombre IS DISTINCT FROM (SELECT nombre::text FROM sucursales WHERE id = 1) THEN
    v_fallas := v_fallas || format('3.1 · el panel tenía que mostrar al preventista una vez, con el chat %s y la sucursal 1: %s filas, chat %s, sucursales %s, nombre %s',
                                   v_tgp, v_n, v_txt, v_j, v_nombre);
  END IF;
  -- Con /sucursal en NULL antes no se lo podía guardar; ahora sí.
  BEGIN
    PERFORM public.bot_admin_guardar_config_digest(v_prev, true, 8, ARRAY[1,2,3,4,5], ARRAY['mis_ventas']);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('3.2 · no se pudo prender el resumen del preventista con /sucursal en NULL: %s', SQLERRM);
  END;
  -- Y el chat del panel es el que recibe.
  SELECT count(*), bool_and((s.telegram_user_id) = v_tgp) INTO v_n, v_ok
    FROM bot_digest_suscripciones() s WHERE s.perfil_id = v_prev;
  IF v_n <> 1 OR NOT COALESCE(v_ok, false) THEN
    v_fallas := v_fallas || format('3.3 · la suscripción del preventista no es la del panel (%s filas)', v_n);
  END IF;

  -- El admin sin sucursal, en su propio panel: se ve sin sucursales, no se lo
  -- puede prender y sí apagar.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_solo, 'role', 'authenticated')::text, true);
  SELECT (e->'sucursales')::text, e->>'sucursal_nombre' INTO v_txt, v_nombre
    FROM json_array_elements(public.bot_admin_listar_config_digest()) e
   WHERE (e->>'perfil_id')::uuid = v_solo;
  IF v_txt IS DISTINCT FROM '[]' OR v_nombre IS NOT NULL THEN
    v_fallas := v_fallas || format('3.4 · sin sucursal, el panel tenía que mostrar [] y sin nombre: %s / %s', v_txt, v_nombre);
  END IF;
  BEGIN
    PERFORM public.bot_admin_guardar_config_digest(v_solo, true, 7, ARRAY[1,2,3,4,5,6,7], ARRAY['ventas']);
    v_fallas := v_fallas || '3.5 · se pudo prender el resumen de alguien sin ninguna sucursal'::text;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ninguna sucursal activa%' THEN
      v_fallas := v_fallas || format('3.5 · prender sin sucursal falló por otra cosa: %s', SQLERRM);
    END IF;
  END;
  BEGIN
    PERFORM public.bot_admin_guardar_config_digest(v_solo, false, 7, ARRAY[1,2,3,4,5,6,7], ARRAY['ventas']);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('3.6 · no se pudo apagar el resumen de alguien sin sucursal: %s', SQLERRM);
  END;
  IF (SELECT activo FROM bot_digest_config WHERE perfil_id = v_solo) IS DISTINCT FROM false THEN
    v_fallas := v_fallas || '3.6b · el apagado no quedó guardado'::text;
  END IF;

  -- ------------------------------------------- 4 · el panel del bot (#1339) ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_jefe, 'role', 'authenticated')::text, true);
  -- Desvinculado: activo = false, sin marca.
  UPDATE bot_usuarios SET activo = false WHERE telegram_user_id = v_tg;
  SELECT e->>'activo', e->>'apagado_por_admin' INTO v_txt, v_nombre
    FROM json_array_elements(public.bot_admin_listar_vinculados()) e
   WHERE (e->>'telegram_user_id')::bigint = v_tg;
  IF v_txt IS DISTINCT FROM 'false' OR v_nombre IS DISTINCT FROM 'false' THEN
    v_fallas := v_fallas || format('4.1 · el desvinculado tenía que verse inactivo y sin marca: activo %s, marca %s', v_txt, v_nombre);
  END IF;

  -- El admin lo apaga sin prenderlo antes: queda la marca y el chat sigue apagado.
  PERFORM public.bot_admin_toggle_usuario(v_tg, false);
  IF NOT EXISTS (SELECT 1 FROM bot_apagados_por_admin WHERE perfil_id = v_admin AND apagado_por = v_jefe) THEN
    v_fallas := v_fallas || '4.2 · apagar a un inactivo no dejó la marca'::text;
  END IF;
  IF (SELECT activo FROM bot_usuarios WHERE telegram_user_id = v_tg) THEN
    v_fallas := v_fallas || '4.3 · apagar a un inactivo lo prendió'::text;
  END IF;
  SELECT e->>'activo', e->>'apagado_por_admin', e->>'apagado_por_nombre', e->>'apagado_at'
    INTO v_txt, v_nombre, v_txt2, v_txt3
    FROM json_array_elements(public.bot_admin_listar_vinculados()) e
   WHERE (e->>'telegram_user_id')::bigint = v_tg;
  IF v_txt IS DISTINCT FROM 'false' OR v_nombre IS DISTINCT FROM 'true'
     OR v_txt2 IS DISTINCT FROM 'Ensayo Jefe' OR v_txt3 IS NULL THEN
    v_fallas := v_fallas || format('4.4 · el panel tenía que mostrar "apagado por Ensayo Jefe": activo %s, marca %s, por %s, cuándo %s',
                                   v_txt, v_nombre, v_txt2, v_txt3);
  END IF;
  -- Y desde ahí no vuelve solo: un UPDATE directo choca con el trigger.
  BEGIN
    UPDATE bot_usuarios SET activo = true WHERE telegram_user_id = v_tg;
    v_fallas := v_fallas || '4.5 · con la marca, el chat se prendió sin el admin'::text;
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- El admin lo prende: se va la marca.
  PERFORM public.bot_admin_toggle_usuario(v_tg, true);
  SELECT e->>'activo', e->>'apagado_por_admin' INTO v_txt, v_nombre
    FROM json_array_elements(public.bot_admin_listar_vinculados()) e
   WHERE (e->>'telegram_user_id')::bigint = v_tg;
  IF v_txt IS DISTINCT FROM 'true' OR v_nombre IS DISTINCT FROM 'false' THEN
    v_fallas := v_fallas || format('4.6 · prendido por el admin tenía que verse activo y sin marca: activo %s, marca %s', v_txt, v_nombre);
  END IF;
  PERFORM set_config('request.jwt.claims', '{}', true);

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK #1387 #1339 (resumen perdido, último pedido y paneles del bot)';
  ELSE
    RAISE EXCEPTION 'ENSAYO FALLÓ #1387 #1339: %', array_to_string(v_fallas, ' | ');
  END IF;
END
$ensayo$;
