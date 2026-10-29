-- Ensayo de #1243 (migración 403b): el alta de un usuario no le cree al usuario.
--   1 · El metadata del usuario no da rol ni sucursal: un signup con
--       data {rol: 'admin', sucursal_id: <otra>} nace preventista de la 1.
--   2 · app_metadata sí (el alta por la admin API o por SQL): rol y sucursal,
--       con la sucursal como texto o como número.
--   3 · El nombre sigue saliendo de user_metadata; sin nombre, el del email.
--   4 · Un rol o una sucursal de app_metadata que no existen frenan el alta.
--   5 · auditoria_auth(): sólo la ejecuta service_role, ve el trigger de
--       auth.users, y el cuerpo que devuelve no lee el metadata del usuario más
--       que para el nombre (lo mismo que decide scripts/check-auth.mjs).
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que los usuarios que inserta se deshacen. Inserta en
-- auth.users como lo hace GoTrue, y el trigger on_auth_user_created hace el resto.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1, 2, 4 y 5; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-alta-usuario-1243.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_otra   bigint;  -- una sucursal que no es la 1
  v_id     uuid;
  v_rol    text;
  v_activo boolean;
  v_nombre text;
  v_sucs   bigint[];
  v_ok     boolean;
  v_json   jsonb;
  v_cuerpo text;
  v_app    jsonb := '{"provider":"email","providers":["email"]}';
BEGIN
  SELECT id INTO v_otra FROM sucursales WHERE id <> 1 ORDER BY id LIMIT 1;
  IF v_otra IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: hace falta una sucursal además de la 1';
  END IF;

  -- -------------------------------- 1 · el metadata del usuario no da nada ---
  v_id := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1243-a@ensayo.invalid', v_app,
          jsonb_build_object('rol', 'admin', 'sucursal_id', v_otra::text, 'nombre', 'Atacante'),
          now(), now());
  SELECT rol, activo, nombre INTO v_rol, v_activo, v_nombre FROM perfiles WHERE id = v_id;
  SELECT array_agg(sucursal_id ORDER BY sucursal_id) INTO v_sucs FROM usuario_sucursales WHERE usuario_id = v_id;
  IF v_rol IS DISTINCT FROM 'preventista' THEN
    v_fallas := v_fallas || format('1.1 · un signup con data.rol = admin nació %s', COALESCE(v_rol, '(sin perfil)'));
  END IF;
  IF v_sucs IS DISTINCT FROM ARRAY[1::bigint] THEN
    v_fallas := v_fallas || format('1.2 · un signup con data.sucursal_id = %s quedó en %s, no en la 1', v_otra, v_sucs);
  END IF;
  -- ------------------------------------------------- 3 · el nombre, igual ---
  IF v_nombre IS DISTINCT FROM 'Atacante' THEN
    v_fallas := v_fallas || format('3.1 · el nombre de user_metadata se perdió (quedó %s)', v_nombre);
  END IF;

  -- ------------------------------------------------ 2 · app_metadata sí da ---
  v_id := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1243-b@ensayo.invalid',
          v_app || jsonb_build_object('rol', 'encargado', 'sucursal_id', v_otra::text),
          -- Lo que diga el usuario no pisa lo que dice app_metadata.
          jsonb_build_object('rol', 'admin', 'sucursal_id', '1'),
          now(), now());
  SELECT rol, activo, nombre INTO v_rol, v_activo, v_nombre FROM perfiles WHERE id = v_id;
  SELECT array_agg(sucursal_id ORDER BY sucursal_id) INTO v_sucs FROM usuario_sucursales WHERE usuario_id = v_id;
  IF v_rol IS DISTINCT FROM 'encargado' THEN
    v_fallas := v_fallas || format('2.1 · app_metadata.rol = encargado nació %s', COALESCE(v_rol, '(sin perfil)'));
  END IF;
  IF v_sucs IS DISTINCT FROM ARRAY[v_otra] THEN
    v_fallas := v_fallas || format('2.2 · app_metadata.sucursal_id = "%s" quedó en %s', v_otra, v_sucs);
  END IF;
  IF v_activo IS DISTINCT FROM true THEN
    v_fallas := v_fallas || '2.3 · el alta con app_metadata no nació activa'::text;
  END IF;
  -- 3.2 · Sin nombre en user_metadata, el del email.
  IF v_nombre IS DISTINCT FROM 'ensayo-1243-b' THEN
    v_fallas := v_fallas || format('3.2 · sin nombre, el perfil quedó %s y no la parte local del email', v_nombre);
  END IF;

  -- 2.4 · La sucursal como número de JSON (la admin API manda números).
  v_id := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1243-c@ensayo.invalid',
          v_app || jsonb_build_object('rol', 'transportista', 'sucursal_id', v_otra),
          '{}', now(), now());
  SELECT rol INTO v_rol FROM perfiles WHERE id = v_id;
  SELECT array_agg(sucursal_id ORDER BY sucursal_id) INTO v_sucs FROM usuario_sucursales WHERE usuario_id = v_id;
  IF v_rol IS DISTINCT FROM 'transportista' OR v_sucs IS DISTINCT FROM ARRAY[v_otra] THEN
    v_fallas := v_fallas || format('2.4 · app_metadata con sucursal_id numérico dio %s en %s', v_rol, v_sucs);
  END IF;

  -- 2.5 · Sin nada (el alta del panel): preventista activo de la 1, como siempre.
  v_id := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1243-d@ensayo.invalid', v_app, '{"email_verified": true}', now(), now());
  SELECT rol, activo INTO v_rol, v_activo FROM perfiles WHERE id = v_id;
  SELECT array_agg(sucursal_id ORDER BY sucursal_id) INTO v_sucs FROM usuario_sucursales WHERE usuario_id = v_id;
  IF v_rol IS DISTINCT FROM 'preventista' OR v_activo IS DISTINCT FROM true OR v_sucs IS DISTINCT FROM ARRAY[1::bigint] THEN
    v_fallas := v_fallas || format('2.5 · el alta del panel nació %s / activo %s / %s', v_rol, v_activo, v_sucs);
  END IF;

  -- ------------------------------- 4 · lo que no existe frena el alta ---
  v_ok := false;
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ensayo-1243-e@ensayo.invalid', v_app || '{"rol": "superadmin"}', '{}', now(), now());
  EXCEPTION WHEN raise_exception OR check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN
    v_fallas := v_fallas || '4.1 · app_metadata.rol = superadmin no frenó el alta'::text;
  END IF;

  v_ok := false;
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ensayo-1243-f@ensayo.invalid',
            v_app || jsonb_build_object('sucursal_id', (SELECT max(id) + 1000 FROM sucursales)::text),
            '{}', now(), now());
  EXCEPTION WHEN raise_exception THEN v_ok := true;
  END;
  IF NOT v_ok THEN
    v_fallas := v_fallas || '4.2 · una app_metadata.sucursal_id que no existe no frenó el alta (cayó en la 1)'::text;
  END IF;

  -- ------------------------------------------------- 5 · auditoria_auth() ---
  IF to_regprocedure('public.auditoria_auth()') IS NULL THEN
    v_fallas := v_fallas || '5 · no existe auditoria_auth()'::text;
  ELSE
    IF has_function_privilege('anon', 'public.auditoria_auth()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.auditoria_auth()', 'EXECUTE') THEN
      v_fallas := v_fallas || '5.1 · auditoria_auth() la ejecuta la app (anon o authenticated)'::text;
    END IF;
    IF NOT has_function_privilege('service_role', 'public.auditoria_auth()', 'EXECUTE') THEN
      v_fallas := v_fallas || '5.1 · service_role no ejecuta auditoria_auth(): el gate no puede mirar'::text;
    END IF;

    v_json := public.auditoria_auth();
    SELECT t->>'cuerpo' INTO v_cuerpo
      FROM jsonb_array_elements(v_json->'triggers_auth_users') t
     WHERE t->>'trigger' = 'on_auth_user_created';
    IF v_cuerpo IS NULL THEN
      v_fallas := v_fallas || '5.2 · auditoria_auth() no ve on_auth_user_created'::text;
    -- La regla de lecturasDeMetadataDelUsuario: sin comentarios y sin la
    -- lectura del nombre, no queda ninguna mención.
    ELSIF regexp_replace(
            regexp_replace(regexp_replace(v_cuerpo, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', ' ', 'g'),
            'raw_user_meta_data\s*->>\s*''nombre''', ' ', 'gi') ~* 'raw_user_meta_data|user_metadata' THEN
      v_fallas := v_fallas || '5.3 · handle_new_user() todavía lee el metadata del usuario para algo más que el nombre'::text;
    END IF;
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK #1243 (alta sin metadata del usuario)';
  ELSE
    RAISE EXCEPTION 'ENSAYO FALLÓ #1243: %', array_to_string(v_fallas, ' | ');
  END IF;
END
$ensayo$;
