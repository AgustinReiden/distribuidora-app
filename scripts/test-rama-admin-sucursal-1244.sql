-- Ensayo de #1244 (migración 404): el admin gestiona los usuarios, los bots y
-- los descuentos de SUS sucursales.
--   1 · perfiles SELECT: el admin de una sucursal no ve a nadie de otra, y ve a
--       todos los de la suya.
--   2 · perfiles UPDATE: no toca a un usuario de otra sucursal (el ataque:
--       activo = false), ni a uno que además trabaja en otra; sí a los de su
--       sucursal y a sí mismo. El admin de todas las sucursales sí al mixto. El
--       que no es admin sigue editando su propio perfil.
--   3 · Los helpers: authenticated los ejecuta (los evalúan las policies), anon
--       no, y para quien no es admin dan siempre false.
--   4 · bot_admin_*: listar, el audit log, su resumen y los digests sólo traen
--       lo de sus sucursales; toggle no apaga el bot de alguien de otra.
--   5 · cliente_descuentos_categoria: el admin no carga ni borra descuentos de
--       un cliente de otra sucursal; los de la suya, sí.
--   6 · auditoria_rama_admin(): sólo service_role, y ve las policies nuevas.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1, 2, 3, 4, 5 y 6; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-rama-admin-sucursal-1244.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_admin1  uuid;    -- admin de UNA sola sucursal
  v_suc1    bigint;  -- su sucursal
  v_multi   uuid;    -- admin de todas las sucursales
  v_ajeno   uuid;    -- usuario sin ninguna sucursal en común con v_admin1
  v_propio  uuid;    -- usuario (no v_admin1) que sólo está en v_suc1
  v_mixto   uuid;    -- usuario en v_suc1 y en otra
  v_prev    uuid;    -- preventista (no admin)
  v_cli_mio bigint;  -- cliente de v_suc1
  v_cli_otro bigint; -- cliente de otra sucursal

  v_uuids uuid[];
  v_n     int;
  v_m     int;
  v_json  json;
  v_tg    bigint;
  v_ok    boolean;
  v_id    bigint;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, min(us.sucursal_id) INTO v_admin1, v_suc1
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id HAVING count(*) = 1
   ORDER BY pf.id LIMIT 1;

  -- El de más sucursales (hay sucursales sin nadie, así que "todas" no sirve).
  SELECT pf.id INTO v_multi
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id HAVING count(DISTINCT us.sucursal_id) >= 2
   ORDER BY count(DISTINCT us.sucursal_id) DESC, pf.id LIMIT 1;

  SELECT pf.id INTO v_ajeno
    FROM perfiles pf
   WHERE COALESCE(pf.activo, true)
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id)
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id = v_suc1)
   ORDER BY pf.id LIMIT 1;

  SELECT pf.id INTO v_propio
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.id <> v_admin1
   GROUP BY pf.id HAVING bool_and(us.sucursal_id = v_suc1)
   ORDER BY pf.id LIMIT 1;

  -- Uno de v_suc1 y de otra, y que v_multi abarque (para 2.5).
  SELECT pf.id INTO v_mixto
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   GROUP BY pf.id HAVING bool_or(us.sucursal_id = v_suc1) AND bool_or(us.sucursal_id <> v_suc1)
   ORDER BY bool_and(us.sucursal_id IN (SELECT a.sucursal_id FROM usuario_sucursales a WHERE a.usuario_id = v_multi)) DESC,
            pf.id
   LIMIT 1;

  SELECT pf.id INTO v_prev
    FROM perfiles pf
   WHERE pf.rol = 'preventista' AND COALESCE(pf.activo, true)
   ORDER BY pf.id LIMIT 1;

  SELECT id INTO v_cli_mio  FROM clientes WHERE sucursal_id = v_suc1 ORDER BY id LIMIT 1;
  SELECT id INTO v_cli_otro FROM clientes WHERE sucursal_id <> v_suc1 ORDER BY id LIMIT 1;

  IF v_admin1 IS NULL OR v_ajeno IS NULL OR v_propio IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ #1244: faltan datos (admin de una sucursal %, ajeno %, propio %)',
      v_admin1, v_ajeno, v_propio;
  END IF;

  -- La sesión de v_admin1 en su sucursal, para todo lo que sigue.
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1, 'role', 'authenticated')::text, true);

  -- ---------------------------------------------------- 1 · perfiles SELECT ---
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT COALESCE(array_agg(id), ''{}'') FROM perfiles' INTO v_uuids;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM unnest(v_uuids) AS x(id)
   WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = x.id AND us.sucursal_id = v_suc1);
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('1.1 · el admin de la sucursal %s ve %s perfil(es) de otras sucursales', v_suc1, v_n);
  END IF;
  SELECT count(DISTINCT us.usuario_id) INTO v_m FROM usuario_sucursales us WHERE us.sucursal_id = v_suc1;
  IF cardinality(v_uuids) - v_n <> v_m THEN
    v_fallas := v_fallas || format('1.2 · el admin ve %s de los %s perfiles de su sucursal', cardinality(v_uuids) - v_n, v_m);
  END IF;

  -- ---------------------------------------------------- 2 · perfiles UPDATE ---
  -- 2.1 · El ataque de #1244: desactivar por REST a un usuario de otra sucursal.
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'WITH u AS (UPDATE perfiles SET activo = false WHERE id = $1 RETURNING 1) SELECT count(*) FROM u'
    INTO v_n USING v_ajeno;
  EXECUTE 'RESET ROLE';
  IF v_n > 0 OR NOT (SELECT COALESCE(activo, true) FROM perfiles WHERE id = v_ajeno) THEN
    v_fallas := v_fallas || '2.1 · el admin de una sucursal desactivó a un usuario de otra'::text;
  END IF;

  -- 2.2 · A uno de su sucursal, sí.
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'WITH u AS (UPDATE perfiles SET nombre = nombre WHERE id = $1 RETURNING 1) SELECT count(*) FROM u'
    INTO v_n USING v_propio;
  EXECUTE 'RESET ROLE';
  IF v_n <> 1 THEN
    v_fallas := v_fallas || '2.2 · el admin no puede editar a un usuario que sólo está en su sucursal'::text;
  END IF;

  -- 2.3 · A sí mismo, sí (por perfiles_update_self y por la suya).
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'WITH u AS (UPDATE perfiles SET nombre = nombre WHERE id = $1 RETURNING 1) SELECT count(*) FROM u'
    INTO v_n USING v_admin1;
  EXECUTE 'RESET ROLE';
  IF v_n <> 1 THEN
    v_fallas := v_fallas || '2.3 · el admin no puede editar su propio perfil'::text;
  END IF;

  -- 2.4 · Al que también trabaja en otra sucursal, no (decisión del dueño).
  IF v_mixto IS NULL OR v_mixto = v_admin1 THEN
    v_saltados := v_saltados || '2.4: no hay usuario en la sucursal del admin y en otra'::text;
  ELSE
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'WITH u AS (UPDATE perfiles SET rol = rol WHERE id = $1 RETURNING 1) SELECT count(*) FROM u'
      INTO v_n USING v_mixto;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 THEN
      v_fallas := v_fallas || '2.4 · el admin de una sucursal editó a un usuario que también trabaja en otra'::text;
    END IF;
    -- 2.5 · El admin de todas sus sucursales, sí.
    IF v_multi IS NULL OR EXISTS (
         SELECT 1 FROM usuario_sucursales u WHERE u.usuario_id = v_mixto
            AND u.sucursal_id NOT IN (SELECT a.sucursal_id FROM usuario_sucursales a WHERE a.usuario_id = v_multi)) THEN
      v_saltados := v_saltados || '2.5: no hay admin que abarque las sucursales del usuario mixto'::text;
    ELSE
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_multi, 'role', 'authenticated')::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'WITH u AS (UPDATE perfiles SET rol = rol WHERE id = $1 RETURNING 1) SELECT count(*) FROM u'
        INTO v_n USING v_mixto;
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1, 'role', 'authenticated')::text, true);
      IF v_n <> 1 THEN
        v_fallas := v_fallas || '2.5 · el admin de todas las sucursales no puede editar a un usuario de dos'::text;
      END IF;
    END IF;
  END IF;

  -- 2.6 · El que no es admin edita su perfil y no el de otro.
  IF v_prev IS NULL THEN
    v_saltados := v_saltados || '2.6: no hay preventista activo'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id',
      (SELECT min(sucursal_id) FROM usuario_sucursales WHERE usuario_id = v_prev)::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'WITH u AS (UPDATE perfiles SET nombre = nombre WHERE id = $1 RETURNING 1) SELECT count(*) FROM u'
      INTO v_n USING v_prev;
    EXECUTE 'WITH u AS (UPDATE perfiles SET nombre = nombre WHERE id <> $1 RETURNING 1) SELECT count(*) FROM u'
      INTO v_m USING v_prev;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN
      v_fallas := v_fallas || '2.6 · un preventista no puede editar su propio perfil'::text;
    END IF;
    IF v_m > 0 THEN
      v_fallas := v_fallas || format('2.6 · un preventista editó %s perfil(es) ajenos', v_m);
    END IF;

    -- --------------------------------------------------------- 3 · helpers ---
    -- 3.2 · Para quien no es admin dan false: no le cuentan nada.
    IF to_regprocedure('public.admin_comparte_sucursal_con(uuid)') IS NOT NULL THEN
      SELECT array_agg(id) INTO v_uuids FROM perfiles;
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'SELECT count(*) FROM unnest($1) AS x(id)
                WHERE public.admin_comparte_sucursal_con(x.id) OR public.admin_abarca_sucursales_de(x.id)'
        INTO v_n USING v_uuids;
      EXECUTE 'RESET ROLE';
      IF v_n > 0 THEN
        v_fallas := v_fallas || format('3.2 · para un preventista, los helpers dan true en %s perfil(es)', v_n);
      END IF;
    END IF;

    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1, 'role', 'authenticated')::text, true);
  END IF;

  -- 3.1 · authenticated los ejecuta, anon no.
  IF to_regprocedure('public.admin_comparte_sucursal_con(uuid)') IS NULL
     OR to_regprocedure('public.admin_abarca_sucursales_de(uuid)') IS NULL THEN
    v_fallas := v_fallas || '3.1 · faltan admin_comparte_sucursal_con / admin_abarca_sucursales_de'::text;
  ELSIF has_function_privilege('anon', 'public.admin_comparte_sucursal_con(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.admin_abarca_sucursales_de(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.admin_comparte_sucursal_con(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.admin_abarca_sucursales_de(uuid)', 'EXECUTE') THEN
    v_fallas := v_fallas || '3.1 · los helpers tienen que ser de authenticated y no de anon'::text;
  END IF;

  -- ------------------------------------------------------------- 4 · bot ---
  -- 4.1 · listar: los de sus sucursales, todos.
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_json := public.bot_admin_listar_vinculados();
  EXECUTE 'RESET ROLE';
  SELECT count(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM usuario_sucursales us
            WHERE us.usuario_id = (e->>'perfil_id')::uuid AND us.sucursal_id = v_suc1)),
         count(*)
    INTO v_n, v_m
    FROM json_array_elements(v_json) e;
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('4.1 · bot_admin_listar_vinculados le muestra %s usuario(s) de otras sucursales', v_n);
  END IF;
  IF v_m <> (SELECT count(*) FROM bot_usuarios bu
              WHERE EXISTS (SELECT 1 FROM usuario_sucursales us
                             WHERE us.usuario_id = bu.perfil_id AND us.sucursal_id = v_suc1)) THEN
    v_fallas := v_fallas || format('4.1 · bot_admin_listar_vinculados trae %s, no todos los de su sucursal', v_m);
  END IF;

  -- 4.2 · toggle: el bot de alguien sin su sucursal no se apaga.
  SELECT bu.telegram_user_id INTO v_tg FROM bot_usuarios bu
   WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = bu.perfil_id AND us.sucursal_id = v_suc1)
   ORDER BY 1 LIMIT 1;
  IF v_tg IS NULL THEN
    v_saltados := v_saltados || '4.2: no hay bot de un usuario de otra sucursal'::text;
  ELSE
    v_ok := false;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      PERFORM public.bot_admin_toggle_usuario(v_tg, false);
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN raise_exception THEN v_ok := true;
    END;
    IF NOT v_ok OR NOT (SELECT activo FROM bot_usuarios WHERE telegram_user_id = v_tg) THEN
      v_fallas := v_fallas || '4.2 · el admin de una sucursal apagó el bot de un usuario de otra'::text;
    END IF;
  END IF;
  -- 4.3 · Ni el de alguien que también trabaja en otra.
  SELECT bu.telegram_user_id INTO v_tg FROM bot_usuarios bu
   WHERE EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = bu.perfil_id AND us.sucursal_id = v_suc1)
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = bu.perfil_id AND us.sucursal_id <> v_suc1)
   ORDER BY 1 LIMIT 1;
  IF v_tg IS NULL THEN
    v_saltados := v_saltados || '4.3: no hay bot de un usuario de dos sucursales'::text;
  ELSE
    v_ok := false;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      PERFORM public.bot_admin_toggle_usuario(v_tg, false);
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN raise_exception THEN v_ok := true;
    END;
    IF NOT v_ok THEN
      v_fallas := v_fallas || '4.3 · el admin de una sucursal apagó el bot de un usuario que también trabaja en otra'::text;
    END IF;
  END IF;
  -- 4.4 · El de uno que sólo está en su sucursal, sí.
  SELECT bu.telegram_user_id INTO v_tg FROM bot_usuarios bu
    JOIN usuario_sucursales us ON us.usuario_id = bu.perfil_id
   GROUP BY bu.telegram_user_id HAVING bool_and(us.sucursal_id = v_suc1)
   ORDER BY 1 LIMIT 1;
  IF v_tg IS NULL THEN
    v_saltados := v_saltados || '4.4: no hay bot de un usuario sólo de la sucursal del admin'::text;
  ELSE
    -- El valor nuevo, antes de ponerse el sombrero: authenticated no lee bot_usuarios.
    SELECT NOT activo INTO v_ok FROM bot_usuarios WHERE telegram_user_id = v_tg;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      PERFORM public.bot_admin_toggle_usuario(v_tg, v_ok);
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN raise_exception THEN
      v_fallas := v_fallas || format('4.4 · el admin no puede apagar el bot de un usuario de su sucursal: %s', SQLERRM);
    END;
  END IF;

  -- 4.5 · El audit log y su resumen: sólo los eventos de sus sucursales.
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_json := public.bot_admin_audit_log('2000-01-01', current_date + 1, NULL, NULL, 1000);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM json_array_elements(v_json) e
   WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                      WHERE us.usuario_id = (e->>'perfil_id')::uuid AND us.sucursal_id = v_suc1);
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('4.5 · bot_admin_audit_log le muestra %s evento(s) de otras sucursales', v_n);
  END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_json := public.bot_admin_audit_summary('2000-01-01', current_date + 1);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM bot_audit_log al
   WHERE EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = al.perfil_id AND us.sucursal_id = v_suc1);
  IF (v_json->>'total_eventos')::int <> v_n THEN
    v_fallas := v_fallas || format('4.5 · bot_admin_audit_summary cuenta %s eventos, los de su sucursal son %s',
                                   v_json->>'total_eventos', v_n);
  END IF;

  -- 4.6 · Los digests enviados: los de los usuarios de sus sucursales.
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_json := public.bot_admin_digests_enviados('2000-01-01', current_date + 1);
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM json_array_elements(v_json) e
   WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                      WHERE us.usuario_id = (e->>'admin_perfil_id')::uuid AND us.sucursal_id = v_suc1);
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('4.6 · bot_admin_digests_enviados le muestra %s digest(s) de otras sucursales', v_n);
  END IF;

  -- ------------------------------------------- 5 · descuentos por categoría ---
  IF v_cli_otro IS NULL OR v_cli_mio IS NULL THEN
    v_saltados := v_saltados || '5: falta un cliente de cada lado'::text;
  ELSE
    -- 5.1 · No le carga un descuento a un cliente de otra sucursal.
    v_ok := false;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
               VALUES ($1, ''ensayo #1244'', 50)' USING v_cli_otro;
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN insufficient_privilege THEN v_ok := true;
    END;
    IF NOT v_ok THEN
      v_fallas := v_fallas || '5.1 · el admin le cargó un descuento a un cliente de otra sucursal'::text;
    END IF;
    -- 5.2 · Ni le borra uno.
    INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
    VALUES (v_cli_otro, 'ensayo #1244 ajeno', 10) RETURNING id INTO v_id;
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'WITH d AS (DELETE FROM cliente_descuentos_categoria WHERE id = $1 RETURNING 1) SELECT count(*) FROM d'
      INTO v_n USING v_id;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 THEN
      v_fallas := v_fallas || '5.2 · el admin borró un descuento de un cliente de otra sucursal'::text;
    END IF;
    -- 5.3 · A uno de su sucursal, las dos cosas (lo que hace replaceCategoriaDiscounts).
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
               VALUES ($1, ''ensayo #1244'', 5) RETURNING id' INTO v_id USING v_cli_mio;
      EXECUTE 'WITH d AS (DELETE FROM cliente_descuentos_categoria WHERE id = $1 RETURNING 1) SELECT count(*) FROM d'
        INTO v_n USING v_id;
      EXECUTE 'RESET ROLE';
      IF v_n <> 1 THEN
        v_fallas := v_fallas || '5.3 · el admin no puede borrar un descuento de un cliente de su sucursal'::text;
      END IF;
    EXCEPTION WHEN insufficient_privilege THEN
      v_fallas := v_fallas || format('5.3 · el admin no puede cargar un descuento a un cliente de su sucursal: %s', SQLERRM);
    END;
  END IF;

  -- ------------------------------------------- 6 · auditoria_rama_admin() ---
  IF to_regprocedure('public.auditoria_rama_admin()') IS NULL THEN
    v_fallas := v_fallas || '6 · no existe auditoria_rama_admin()'::text;
  ELSE
    IF has_function_privilege('anon', 'public.auditoria_rama_admin()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.auditoria_rama_admin()', 'EXECUTE')
       OR NOT has_function_privilege('service_role', 'public.auditoria_rama_admin()', 'EXECUTE') THEN
      v_fallas := v_fallas || '6.1 · auditoria_rama_admin() tiene que ser sólo de service_role'::text;
    END IF;
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(public.auditoria_rama_admin()->'politicas') p
     WHERE p->>'tabla' = 'perfiles' AND p->>'policy' IN ('perfiles_select_admin', 'perfiles_update_admin')
       AND (COALESCE(p->>'using', '') || COALESCE(p->>'check', '')) ~ 'admin_(comparte_sucursal_con|abarca_sucursales_de)';
    IF v_n <> 2 THEN
      v_fallas := v_fallas || format('6.2 · auditoria_rama_admin() ve %s de las 2 policies nuevas de perfiles', v_n);
    END IF;
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK #1244 (rama admin acotada)%',
      CASE WHEN cardinality(v_saltados) > 0 THEN ' · saltados: ' || array_to_string(v_saltados, ' | ') ELSE '' END;
  ELSE
    RAISE EXCEPTION 'ENSAYO FALLÓ #1244: % %',
      array_to_string(v_fallas, ' | '),
      CASE WHEN cardinality(v_saltados) > 0 THEN ' · saltados: ' || array_to_string(v_saltados, ' | ') ELSE '' END;
  END IF;
END
$ensayo$;
