-- Ensayo de la mig NNN_bot_alcance_por_rol_y_sucursal (#1552): el bot respeta el
-- alcance que el usuario tiene en la app.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en una
-- excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo
-- sin el BEGIN/COMMIT. Sin la migración tiene que dar ENSAYO FALLO.
-- Usa gente que ya existe: dos sucursales activas A y B, dos admins de A (ADM
-- sólo de A, y Z, al que se le suma B), un transportista y un preventista sólo
-- de A, y un cliente activo de A. Los chats de Telegram son ids que no existen
-- (99000000155x) y las filas del registro van fechadas en 2099, para no
-- mezclarse con las reales.
--
--   B-4 · el registro del bot se filtra por la sucursal del evento
--     L1 · Z parado en B (/sucursal) → la fila nace con B; parado en A, con A.
--     L2 · el resumen diario declara su sucursal en el meta (B) y gana sobre la
--          del chat (A); un meta raro no tira el INSERT.
--     L3 · ADM (sólo A) ve lo de A, no lo de B ni la fila vieja de Z (Z tiene
--          A y B); sí la fila vieja de un usuario sólo de A. El resumen cuenta
--          lo mismo que la lista.
--     L4 · Z (A y B) ve todo lo suyo. Un admin sólo de B, si hay, ve lo de B.
--   B-1 · el depósito no lee clientes; el transportista sigue
--     D1 · bot_buscar_cliente como depósito: 0 filas.
--     D2 · como transportista y preventista sigue viendo al huérfano; el admin,
--          todos los activos de A.
--     D3 · resumen de visita, recurrentes y dejados como depósito: el error y
--          sin saldo; como transportista y admin, igual que antes.
--   B-2 · sin fecha, el recorrido de hoy
--     R1 · bot_recorrido_resumen y bot_mi_recorrido con NULL → el de hoy.
--     R2 · con la fecha explícita de hoy, el mismo; con la de ayer, no.
--   B-3 · el aviso de atrasados va a las sucursales vivas
--     A1 · el preventista que no se movió lo recibe de A.
--     A2 · movido de A a B (la foto de bot_usuarios sigue en A) → de B.
--     A3 · con A y B → de las dos.
--     A4 · desactivado, o con el chat apagado → de ninguna.
--   P  · EXECUTE: las de server sin authenticated ni anon; las del panel sin
--        anon; el trigger, de nadie.

DO $ensayo$
DECLARE
  v_a       bigint;
  v_b       bigint;
  v_adm     uuid;
  v_z       uuid;
  v_adm_b   uuid;
  v_tr      uuid;
  v_prev    uuid;
  v_cli     bigint;
  v_rec     bigint;
  v_txt     text;
  v_n       bigint;
  v_t       text;
  v_j       json;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
  TS  CONSTANT timestamptz := TIMESTAMPTZ '2099-01-05 15:00:00-03';
  TGZ CONSTANT bigint      := 990000001552;
  TGP CONSTANT bigint      := 990000001553;
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, adm.usuario_id, z.usuario_id, tr.usuario_id, pv.usuario_id
    INTO v_a, v_adm, v_z, v_tr, v_prev
    FROM sucursales s
    -- un admin sólo de A
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales x WHERE x.usuario_id = pf.id AND x.sucursal_id <> s.id)
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
    -- otro admin de A
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin' AND pf.id <> adm.usuario_id
                   ORDER BY us.usuario_id LIMIT 1) z ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) tr ON true
    -- un preventista sólo de A
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista'
                     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales x WHERE x.usuario_id = pf.id AND x.sucursal_id <> s.id)
                   ORDER BY us.usuario_id LIMIT 1) pv ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures: ninguna sucursal activa con un admin sólo de ella, otro admin, un transportista y un preventista sólo de ella';
  END IF;
  -- B: mejor una que tenga un admin sólo de ella, para probar su lado (L4).
  SELECT s.id INTO v_b FROM sucursales s
   WHERE s.activa AND s.id <> v_a
   ORDER BY EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                     WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                       AND NOT EXISTS (SELECT 1 FROM usuario_sucursales x
                                        WHERE x.usuario_id = pf.id AND x.sucursal_id <> s.id)) DESC,
            s.id
   LIMIT 1;
  IF v_b IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures: una segunda sucursal activa';
  END IF;
  SELECT pf.id INTO v_adm_b
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_b
   WHERE pf.activo AND pf.rol = 'admin'
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales x WHERE x.usuario_id = pf.id AND x.sucursal_id <> v_b)
   ORDER BY pf.id LIMIT 1;
  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_a AND c.activo AND NOT c.reservado_admin
   ORDER BY c.id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures: un cliente activo en la sucursal %', v_a;
  END IF;
  v_notas := v_notas || format('A %s, B %s, ADM %s, Z %s, ADM_B %s, TR %s, PREV %s, CLI %s',
                               v_a, v_b, left(v_adm::text, 8), left(v_z::text, 8),
                               left(COALESCE(v_adm_b::text, '-'), 8), left(v_tr::text, 8),
                               left(v_prev::text, 8), v_cli);

  -- ---------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
    IF p_uid IS NULL THEN
      EXECUTE 'RESET ROLE';
    ELSE
      EXECUTE 'SET LOCAL ROLE authenticated';
    END IF;
  END $f$;
  -- Los textos del registro que ve quien llama, en 2099, ordenados.
  CREATE OR REPLACE FUNCTION pg_temp.ve(p_uid uuid, p_suc bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    SELECT string_agg(t.texto_bot, ',' ORDER BY t.texto_bot) INTO r
      FROM json_to_recordset(public.bot_admin_audit_log(DATE '2099-01-05', DATE '2099-01-05', NULL, NULL, 1000))
           AS t(texto_bot text);
    PERFORM pg_temp.como(NULL, NULL);
    RETURN COALESCE(r, '');
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.cuenta(p_uid uuid, p_suc bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE r bigint;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    r := (public.bot_admin_audit_summary(DATE '2099-01-05', DATE '2099-01-05') ->> 'total_eventos')::bigint;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- Las sucursales del aviso de atrasados para un perfil, ordenadas.
  CREATE OR REPLACE FUNCTION pg_temp.aviso(p_perfil uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(e ->> 'sucursal_id', ',' ORDER BY (e ->> 'sucursal_id')::bigint), '')
      FROM json_array_elements(public.bot_aviso_atrasados_destinatarios(23, 1)) e
     WHERE (e ->> 'perfil_id')::uuid = p_perfil
  $f$;

  -- Los chats de Telegram, prendidos (un apagado por admin no se puede prender).
  DELETE FROM bot_apagados_por_admin WHERE perfil_id IN (v_z, v_prev);
  INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
  VALUES (TGZ, v_z, 'admin', v_a, true), (TGP, v_prev, 'preventista', v_a, true);
  -- Z es admin de A y de B.
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default)
  VALUES (v_z, v_b, false) ON CONFLICT DO NOTHING;

  -- ==================================================== B-4 · el registro ---
  BEGIN
    -- L1 · Z parado en B y después en A.
    UPDATE bot_usuarios SET sucursal_id = v_b WHERE telegram_user_id = TGZ;
    INSERT INTO bot_audit_log (telegram_user_id, perfil_id, rol, tipo, texto_bot, created_at)
    VALUES (TGZ, v_z, 'admin', 'respuesta', 'z-en-B', TS);
    UPDATE bot_usuarios SET sucursal_id = v_a WHERE telegram_user_id = TGZ;
    INSERT INTO bot_audit_log (telegram_user_id, perfil_id, rol, tipo, texto_bot, created_at)
    VALUES (TGZ, v_z, 'admin', 'respuesta', 'z-en-A', TS);
    -- L2 · el resumen de B, con el chat parado en A; y un meta raro.
    INSERT INTO bot_audit_log (telegram_user_id, perfil_id, rol, tipo, texto_bot, resultado_meta, created_at)
    VALUES (TGZ, v_z, 'admin', 'respuesta', 'z-resumen-B', jsonb_build_object('digest', true, 'sucursal_id', v_b), TS),
           (TGZ, v_z, 'admin', 'respuesta', 'z-meta-raro', jsonb_build_object('sucursal_id', 'x; 5.5'), TS);
    -- Filas de antes de la migración (sin sucursal): de Z, de PREV (sólo A) y
    -- de alguien sin vincular.
    INSERT INTO bot_audit_log (telegram_user_id, perfil_id, rol, tipo, texto_bot, created_at)
    VALUES (NULL, v_z, 'admin', 'respuesta', 'z-vieja', TS),
           (NULL, v_prev, 'preventista', 'respuesta', 'prev-vieja', TS),
           (TGZ + 10, NULL, NULL, 'mensaje', 'sin-perfil', TS);

    EXECUTE format($q$SELECT string_agg(texto_bot || '=' || COALESCE(sucursal_id::text, '-'), ',' ORDER BY texto_bot)
                        FROM bot_audit_log WHERE created_at = %L$q$, TS) INTO v_txt;
    v_t := format('prev-vieja=-,sin-perfil=-,z-en-A=%s,z-en-B=%s,z-meta-raro=%s,z-resumen-B=%s,z-vieja=-',
                  v_a, v_b, v_a, v_b);
    IF v_txt IS DISTINCT FROM v_t THEN
      v_fallas := v_fallas || format('L1/L2 · la sucursal de cada fila: %s (esperado %s)', v_txt, v_t);
    END IF;

    -- L3 · ADM, sólo de A.
    v_txt := pg_temp.ve(v_adm, v_a);
    IF v_txt IS DISTINCT FROM 'prev-vieja,z-en-A,z-meta-raro' THEN
      v_fallas := v_fallas || format('L3 · el admin sólo de A ve: %s (esperado prev-vieja,z-en-A,z-meta-raro)', v_txt);
    END IF;
    v_n := pg_temp.cuenta(v_adm, v_a);
    IF v_n IS DISTINCT FROM 3 THEN
      v_fallas := v_fallas || format('L3 · el resumen del admin sólo de A cuenta %s (esperado 3)', v_n);
    END IF;

    -- L4 · Z, de A y B: todo lo suyo.
    v_txt := pg_temp.ve(v_z, v_a);
    IF v_txt IS DISTINCT FROM 'prev-vieja,z-en-A,z-en-B,z-meta-raro,z-resumen-B,z-vieja' THEN
      v_fallas := v_fallas || format('L4 · el admin de A y B ve: %s', v_txt);
    END IF;
    v_n := pg_temp.cuenta(v_z, v_a);
    IF v_n IS DISTINCT FROM 6 THEN
      v_fallas := v_fallas || format('L4 · el resumen del admin de A y B cuenta %s (esperado 6)', v_n);
    END IF;
    IF v_adm_b IS NOT NULL THEN
      v_txt := pg_temp.ve(v_adm_b, v_b);
      IF v_txt IS DISTINCT FROM 'z-en-B,z-resumen-B' THEN
        v_fallas := v_fallas || format('L4 · el admin sólo de B ve: %s (esperado z-en-B,z-resumen-B)', v_txt);
      END IF;
    ELSE
      v_notas := v_notas || 'L4 · no hay un admin sólo de B: no se probó su lado'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
    PERFORM pg_temp.como(NULL, NULL);
    v_fallas := v_fallas || format('B-4 · no corre: %s', v_t);
  END;

  -- ============================================ B-1 · el depósito y clientes -
  BEGIN
    -- CLI, huérfano: lo ve cualquier preventista y, por esa rama, también el
    -- depósito antes de la migración.
    DELETE FROM cliente_preventistas WHERE cliente_id = v_cli;

    -- D1
    SELECT count(*) INTO v_n FROM public.bot_buscar_cliente('', gen_random_uuid(), 'deposito', v_a, 100000);
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format('D1 · bot_buscar_cliente como depósito devuelve %s clientes', v_n);
    END IF;
    -- D2
    IF NOT EXISTS (SELECT 1 FROM public.bot_buscar_cliente('', v_tr, 'transportista', v_a, 100000) b WHERE b.id = v_cli) THEN
      v_fallas := v_fallas || 'D2 · el transportista dejó de encontrar al huérfano'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.bot_buscar_cliente('', v_prev, 'preventista', v_a, 100000) b WHERE b.id = v_cli) THEN
      v_fallas := v_fallas || 'D2 · el preventista dejó de encontrar al huérfano'::text;
    END IF;
    SELECT count(*) INTO v_n FROM public.bot_buscar_cliente('', v_adm, 'admin', v_a, 100000);
    IF v_n IS DISTINCT FROM (SELECT count(*) FROM clientes c WHERE c.sucursal_id = v_a AND c.activo) THEN
      v_fallas := v_fallas || format('D2 · el admin encuentra %s clientes y A tiene %s activos', v_n,
                                     (SELECT count(*) FROM clientes c WHERE c.sucursal_id = v_a AND c.activo));
    END IF;

    -- D3
    v_j := public.bot_resumen_cliente_visita(v_cli, gen_random_uuid(), 'deposito', v_a);
    IF (v_j ->> 'error') IS DISTINCT FROM 'Tu rol no tiene acceso a clientes' OR (v_j::jsonb ? 'saldo') THEN
      v_fallas := v_fallas || format('D3 · resumen de visita como depósito: %s', left(v_j::text, 200));
    END IF;
    v_j := public.bot_productos_recurrentes_cliente(v_cli, gen_random_uuid(), 'deposito', v_a, 90, 10);
    IF (v_j ->> 'error') IS DISTINCT FROM 'Tu rol no tiene acceso a clientes' THEN
      v_fallas := v_fallas || format('D3 · recurrentes como depósito: %s', left(v_j::text, 200));
    END IF;
    v_j := public.bot_productos_dejados_cliente(v_cli, gen_random_uuid(), 'deposito', v_a);
    IF (v_j ->> 'error') IS DISTINCT FROM 'Tu rol no tiene acceso a clientes' THEN
      v_fallas := v_fallas || format('D3 · dejados como depósito: %s', left(v_j::text, 200));
    END IF;
    v_j := public.bot_resumen_cliente_visita(v_cli, v_tr, 'transportista', v_a);
    IF (v_j ->> 'error') IS NOT NULL OR NOT (v_j::jsonb ? 'saldo') THEN
      v_fallas := v_fallas || format('D3 · resumen de visita como transportista cambió: %s', left(v_j::text, 200));
    END IF;
    v_j := public.bot_resumen_cliente_visita(v_cli, v_adm, 'admin', v_a);
    IF (v_j ->> 'error') IS NOT NULL OR NOT (v_j::jsonb ? 'saldo') THEN
      v_fallas := v_fallas || format('D3 · resumen de visita como admin cambió: %s', left(v_j::text, 200));
    END IF;
    v_j := public.bot_productos_dejados_cliente(v_cli, v_prev, 'preventista', v_a);
    IF (v_j ->> 'error') IS NOT NULL THEN
      v_fallas := v_fallas || format('D3 · dejados como preventista cambió: %s', left(v_j::text, 200));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
    v_fallas := v_fallas || format('B-1 · no corre: %s', v_t);
  END;

  -- ====================================================== B-2 · recorrido ---
  BEGIN
    INSERT INTO recorridos (transportista_id, sucursal_id, fecha, estado, total_pedidos,
                            pedidos_entregados, total_facturado, total_cobrado)
    VALUES (v_tr, v_a, public._tablero_hoy(), 'en_curso', 3, 1, 1000, 400)
    RETURNING id INTO v_rec;

    -- R1
    v_j := public.bot_recorrido_resumen(v_tr, v_a, NULL);
    IF (v_j ->> 'recorrido_id')::bigint IS DISTINCT FROM v_rec
       OR (v_j ->> 'porcentaje_cobrado')::numeric IS DISTINCT FROM 40.0 THEN
      v_fallas := v_fallas || format('R1 · bot_recorrido_resumen sin fecha: %s (esperado el recorrido %s)', v_j, v_rec);
    END IF;
    v_j := public.bot_mi_recorrido(v_tr, v_a, NULL);
    IF (v_j -> 'recorrido' ->> 'id')::bigint IS DISTINCT FROM v_rec THEN
      v_fallas := v_fallas || format('R1 · bot_mi_recorrido sin fecha: %s (esperado el recorrido %s)',
                                     left(v_j::text, 200), v_rec);
    END IF;
    -- R2
    IF (public.bot_recorrido_resumen(v_tr, v_a, public._tablero_hoy()) ->> 'recorrido_id')::bigint IS DISTINCT FROM v_rec THEN
      v_fallas := v_fallas || 'R2 · bot_recorrido_resumen con la fecha de hoy no da el de hoy'::text;
    END IF;
    IF (public.bot_recorrido_resumen(v_tr, v_a, public._tablero_hoy() - 1) ->> 'recorrido_id')::bigint = v_rec THEN
      v_fallas := v_fallas || 'R2 · bot_recorrido_resumen con la fecha de ayer da el de hoy'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
    v_fallas := v_fallas || format('B-2 · no corre: %s', v_t);
  END;

  -- ====================================================== B-3 · el aviso ----
  BEGIN
    -- PREV recibe el aviso todos los días desde las 0, y hoy todavía no salió.
    INSERT INTO bot_digest_config (perfil_id, aviso_atrasados_activo, aviso_atrasados_hora, aviso_atrasados_dias)
    VALUES (v_prev, true, 0, ARRAY[1,2,3,4,5,6,7]::smallint[])
    ON CONFLICT (perfil_id) DO UPDATE
       SET aviso_atrasados_activo = true, aviso_atrasados_hora = 0,
           aviso_atrasados_dias = ARRAY[1,2,3,4,5,6,7]::smallint[];
    DELETE FROM bot_avisos_atrasados_enviados WHERE perfil_id = v_prev AND fecha = public._tablero_hoy();

    -- A1 · no se movió.
    v_txt := pg_temp.aviso(v_prev);
    IF v_txt IS DISTINCT FROM v_a::text THEN
      v_fallas := v_fallas || format('A1 · el preventista de A recibe el aviso de: %s (esperado %s)', v_txt, v_a);
    END IF;
    -- A2 · lo pasan a B; bot_usuarios.sucursal_id sigue en A.
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_prev, v_b, false);
    DELETE FROM usuario_sucursales WHERE usuario_id = v_prev AND sucursal_id = v_a;
    v_txt := pg_temp.aviso(v_prev);
    IF v_txt IS DISTINCT FROM v_b::text THEN
      v_fallas := v_fallas || format('A2 · movido de A a B recibe el aviso de: %s (esperado %s)', v_txt, v_b);
    END IF;
    -- A3 · con las dos.
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_prev, v_a, true);
    v_txt := pg_temp.aviso(v_prev);
    IF v_txt IS DISTINCT FROM format('%s,%s', least(v_a, v_b), greatest(v_a, v_b)) THEN
      v_fallas := v_fallas || format('A3 · con A y B recibe el aviso de: %s', v_txt);
    END IF;
    -- A4 · con el chat apagado, y desactivado.
    UPDATE bot_usuarios SET activo = false WHERE telegram_user_id = TGP;
    v_txt := pg_temp.aviso(v_prev);
    IF v_txt <> '' THEN
      v_fallas := v_fallas || format('A4 · con el chat apagado recibe el aviso de: %s', v_txt);
    END IF;
    UPDATE bot_usuarios SET activo = true WHERE telegram_user_id = TGP;
    BEGIN
      BEGIN
        UPDATE perfiles SET activo = false WHERE id = v_prev;
      EXCEPTION WHEN OTHERS THEN
        -- La baja sincroniza auth.users (trg_perfiles_sync_acceso_auth): en una
        -- base sin el schema de Auth completo, sin triggers.
        GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
        v_notas := v_notas || format('A4 · la baja con triggers no anda en esta base (%s): sin triggers', v_t);
        SET LOCAL session_replication_role = replica;
        UPDATE perfiles SET activo = false WHERE id = v_prev;
        SET LOCAL session_replication_role = origin;
      END;
      v_txt := pg_temp.aviso(v_prev);
      IF v_txt <> '' THEN
        v_fallas := v_fallas || format('A4 · desactivado recibe el aviso de: %s', v_txt);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
      v_notas := v_notas || format('A4 · no se pudo desactivar al preventista: %s', v_t);
    END;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
    v_fallas := v_fallas || format('B-3 · no corre: %s', v_t);
  END;

  -- =========================================================== P · EXECUTE -
  SELECT string_agg(fn, ', ' ORDER BY fn) INTO v_txt
    FROM unnest(ARRAY[
      'public.bot_buscar_cliente(text,uuid,text,bigint,integer)',
      'public.bot_productos_recurrentes_cliente(bigint,uuid,text,bigint,integer,integer)',
      'public.bot_productos_dejados_cliente(bigint,uuid,text,bigint)',
      'public.bot_resumen_cliente_visita(bigint,uuid,text,bigint)',
      'public.bot_recorrido_resumen(uuid,bigint,date)',
      'public.bot_mi_recorrido(uuid,bigint,date)',
      'public.bot_aviso_atrasados_destinatarios(integer,integer)',
      'public.bot_resolver_usuario(bigint)'
    ]) fn
   WHERE has_function_privilege('authenticated', fn, 'EXECUTE')
      OR has_function_privilege('anon', fn, 'EXECUTE');
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('P · funciones de server alcanzables desde la API: %s', v_txt);
  END IF;
  SELECT string_agg(fn, ', ' ORDER BY fn) INTO v_txt
    FROM unnest(ARRAY[
      'public.bot_admin_audit_log(date,date,text,uuid,integer)',
      'public.bot_admin_audit_summary(date,date)'
    ]) fn
   WHERE NOT has_function_privilege('authenticated', fn, 'EXECUTE')
      OR has_function_privilege('anon', fn, 'EXECUTE');
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('P · las del panel sin authenticated o con anon: %s', v_txt);
  END IF;
  IF to_regprocedure('public.bot_audit_log_sucursal()') IS NULL THEN
    v_fallas := v_fallas || 'P · falta bot_audit_log_sucursal()'::text;
  ELSIF has_function_privilege('authenticated', 'public.bot_audit_log_sucursal()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.bot_audit_log_sucursal()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'P · el trigger bot_audit_log_sucursal() tiene EXECUTE para la API'::text;
  END IF;

  -- -------------------------------------------------------------- veredicto -
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLO (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_t;
 END;
END
$ensayo$;
