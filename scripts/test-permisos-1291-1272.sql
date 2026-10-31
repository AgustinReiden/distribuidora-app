-- Ensayo de la migración 415 permisos_el_admin_y_sus_usuarios (#1291, #1272).
--   1 · asignar_usuario_sucursal: el admin de una sucursal no se trae a un
--       usuario de otra (el ataque de #1291), ni a uno que además trabaja en
--       otra; sí actualiza a los suyos. El admin de todas sí mueve al de una.
--   2 · desasignar_usuario_sucursal: lo mismo, y no deja a nadie sin sucursal.
--   3 · cliente_preventistas por REST: el admin no asigna ni desasigna
--       preventistas de un cliente de otra sucursal; de la suya, sí. El
--       preventista se sigue asignando un cliente libre de su sucursal.
--   4 · metas_gerenciales y reportes_mensuales: el admin lee lo de sus
--       sucursales, y la Red (sucursal NULL) sólo el admin de todas.
--   5 · proveedores_eliminados: eliminar_proveedor deja la sucursal del
--       proveedor, y el admin sólo lee los de sus sucursales.
--   6 · auditoria_rpcs_definer(): sólo service_role, y ve que asignar y
--       desasignar acotan al usuario.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1, 2, 3.1, 3.1b, 4, 5 y 6; después, pasar.
-- 3.2 ya pasaba: un DELETE con filtro también tiene que pasar cp_select, que
-- miraba la sucursal. Queda para que no vuelva. 3.3 y 3.4 pasan antes y después:
-- son el flujo del front sobre cliente_preventistas (upsert con ignoreDuplicates
-- de lo que se agregó, DELETE … IN de lo que se sacó).
-- Ensayo en seco:
--
--   BEGIN; <migrations/415_permisos_el_admin_y_sus_usuarios.sql>; <este archivo>; (el DO aborta)
--
-- Molde: scripts/test-rama-admin-sucursal-1244.sql.
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-1291-1272.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';

  v_s1     bigint;  -- dos sucursales activas
  v_s2     bigint;
  v_a2     uuid;    -- admin sólo de v_s2
  v_a1     uuid;    -- admin sólo de v_s1
  v_ared   uuid;    -- admin de todas las sucursales activas
  v_u1     uuid;    -- usuario (no admin) sólo de v_s1
  v_u2     uuid;    -- usuario (no admin) sólo de v_s2, que no es v_p2
  v_p2     uuid;    -- preventista de v_s2
  v_cli1   bigint;  -- cliente de v_s1 con un preventista asignado
  v_pcli1  uuid;    -- ese preventista
  v_cli2   bigint;  -- cliente de v_s2, no reservado
  v_prov   bigint;
  v_suc_pe bigint;  -- la sucursal con que quedó archivado
  v_antes  text;    -- las filas de usuario_sucursales de v_u1 antes del ataque

  r      jsonb;
  v_n    int;
  v_ids  bigint[];
  v_ok   boolean;
  v_err  text;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- datos ---
  SELECT min(id), max(id) INTO v_s1, v_s2 FROM (SELECT id FROM sucursales WHERE activa ORDER BY id LIMIT 2) s;

  SELECT pf.id INTO v_a2 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id HAVING bool_and(us.sucursal_id = v_s2) ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_a1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id HAVING bool_and(us.sucursal_id = v_s1) ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_ared FROM perfiles pf
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
     AND NOT EXISTS (SELECT 1 FROM sucursales s WHERE s.activa
                      AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id = s.id))
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_u1 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol <> 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id HAVING bool_and(us.sucursal_id = v_s1) ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_p2 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_s2
   WHERE pf.rol = 'preventista' AND COALESCE(pf.activo, true) ORDER BY pf.id LIMIT 1;
  -- Otro que v_p2: sin el arreglo, 2.2 lo saca de v_s2 y 3.4 fallaría en cascada.
  SELECT pf.id INTO v_u2 FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol <> 'admin' AND COALESCE(pf.activo, true) AND pf.id <> v_p2
   GROUP BY pf.id HAVING bool_and(us.sucursal_id = v_s2) ORDER BY pf.id LIMIT 1;
  SELECT cp.cliente_id, cp.preventista_id INTO v_cli1, v_pcli1
    FROM cliente_preventistas cp JOIN clientes c ON c.id = cp.cliente_id
   WHERE c.sucursal_id = v_s1 ORDER BY cp.cliente_id LIMIT 1;
  SELECT c.id INTO v_cli2 FROM clientes c
   WHERE c.sucursal_id = v_s2 AND c.activo AND NOT c.reservado_admin
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;

  IF v_s1 = v_s2 OR v_a2 IS NULL OR v_a1 IS NULL OR v_ared IS NULL OR v_u1 IS NULL OR v_u2 IS NULL
     OR v_p2 IS NULL OR v_cli1 IS NULL OR v_cli2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ #1291/#1272: faltan datos (s % y %, a2 %, a1 %, ared %, u1 %, u2 %, p2 %, cli1 %, cli2 %)',
      v_s1, v_s2, v_a2, v_a1, v_ared, v_u1, v_u2, v_p2, v_cli1, v_cli2;
  END IF;

  -- La sesión de v_a2 en su sucursal, salvo donde se cambia.
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_s2::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2, 'role', 'authenticated')::text, true);

  -- ------------------------------------------------ 1 · asignar (#1291) ---
  -- 1.1 · El ataque: el admin de v_s2 se trae a v_u1 (sólo de v_s1) como default.
  SELECT string_agg(sucursal_id || ':' || es_default, ',' ORDER BY sucursal_id) INTO v_antes
    FROM usuario_sucursales WHERE usuario_id = v_u1;
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT public.asignar_usuario_sucursal($1, $2, ''mismo'', true)' INTO r USING v_u1, v_s2;
  EXECUTE 'RESET ROLE';
  IF COALESCE((r->>'success')::boolean, false)
     OR (SELECT string_agg(sucursal_id || ':' || es_default, ',' ORDER BY sucursal_id)
           FROM usuario_sucursales WHERE usuario_id = v_u1) IS DISTINCT FROM v_antes THEN
    v_fallas := v_fallas || format('1.1 · el admin de la %s se trajo a un usuario de la %s: %s', v_s2, v_s1, r);
  END IF;

  -- 1.2 · Tampoco a uno que es de la suya y de otra (v_ared): le cambiaría la default.
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT public.asignar_usuario_sucursal($1, $2, ''mismo'', true)' INTO r USING v_ared, v_s2;
  EXECUTE 'RESET ROLE';
  IF COALESCE((r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('1.2 · el admin de la %s reasignó a un usuario que también es de otra: %s', v_s2, r);
  END IF;

  -- 1.3 · A uno suyo, sí.
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT public.asignar_usuario_sucursal($1, $2, ''mismo'', true)' INTO r USING v_u2, v_s2;
  EXECUTE 'RESET ROLE';
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('1.3 · el admin de la %s no pudo asignar a uno suyo: %s', v_s2, r);
  END IF;

  -- 1.4 · El admin de todas sí se trae a v_u1 a la otra sucursal.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ared, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT public.asignar_usuario_sucursal($1, $2, ''mismo'', false)' INTO r USING v_u1, v_s2;
  EXECUTE 'RESET ROLE';
  IF NOT COALESCE((r->>'success')::boolean, false)
     OR NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_u1 AND sucursal_id = v_s2) THEN
    v_fallas := v_fallas || format('1.4 · el admin de todas no pudo asignar a un usuario de una: %s', r);
  END IF;

  -- --------------------------------------------- 2 · desasignar (#1291) ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2, 'role', 'authenticated')::text, true);

  -- 2.1 · El admin de v_s2 no saca a v_u1 (ahora de las dos) de la suya.
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT public.desasignar_usuario_sucursal($1, $2)' INTO r USING v_u1, v_s2;
  EXECUTE 'RESET ROLE';
  IF COALESCE((r->>'success')::boolean, false)
     OR NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_u1 AND sucursal_id = v_s2) THEN
    v_fallas := v_fallas || format('2.1 · el admin de la %s desasignó a un usuario que también es de otra: %s', v_s2, r);
  END IF;

  -- 2.2 · Ni deja a uno suyo sin sucursal.
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT public.desasignar_usuario_sucursal($1, $2)' INTO r USING v_u2, v_s2;
  EXECUTE 'RESET ROLE';
  IF COALESCE((r->>'success')::boolean, false)
     OR NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_u2) THEN
    v_fallas := v_fallas || format('2.2 · desasignar dejó a un usuario sin sucursal: %s', r);
  END IF;

  -- 2.3 · El admin de todas saca a v_u1 de la v_s2 (le queda la v_s1).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ared, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT public.desasignar_usuario_sucursal($1, $2)' INTO r USING v_u1, v_s2;
  EXECUTE 'RESET ROLE';
  IF NOT COALESCE((r->>'success')::boolean, false)
     OR EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_u1 AND sucursal_id = v_s2) THEN
    v_fallas := v_fallas || format('2.3 · el admin de todas no pudo desasignar: %s', r);
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2, 'role', 'authenticated')::text, true);

  -- ---------------------------------- 3 · cliente_preventistas (#1272) ---
  -- 3.1 · El admin de v_s2 no le asigna un preventista a un cliente de v_s1.
  v_ok := false;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)' USING v_cli1, v_p2;
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;  -- 42501: la policy lo frenó
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_ok THEN
    v_fallas := v_fallas || format('3.1 · el admin de la %s asignó un preventista a un cliente de la %s', v_s2, v_s1);
  END IF;

  -- 3.2 · Ni le borra el que tiene (cp_select ya lo frenaba; ahora también cp_delete).
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'WITH d AS (DELETE FROM cliente_preventistas WHERE cliente_id = $1 RETURNING 1) SELECT count(*) FROM d'
     INTO v_n USING v_cli1;
  EXECUTE 'RESET ROLE';
  IF v_n > 0 OR NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cli1 AND preventista_id = v_pcli1) THEN
    v_fallas := v_fallas || format('3.2 · el admin de la %s borró %s asignación(es) de un cliente de la %s', v_s2, v_n, v_s1);
  END IF;

  -- 3.1b · Tampoco con la forma del front (upsert con ignoreDuplicates).
  v_ok := false;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)
             ON CONFLICT (cliente_id, preventista_id) DO NOTHING' USING v_cli1, v_p2;
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN insufficient_privilege THEN
    v_ok := true;
  END;
  EXECUTE 'RESET ROLE';
  IF NOT v_ok THEN
    v_fallas := v_fallas || format('3.1b · el admin de la %s asignó por upsert un preventista a un cliente de la %s', v_s2, v_s1);
  END IF;

  -- 3.3 · A un cliente suyo, asigna y desasigna, con lo que manda el front:
  -- INSERT … ON CONFLICT DO NOTHING (dos veces: la segunda, con la fila ya
  -- puesta) y DELETE … AND preventista_id IN (…).
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)
             ON CONFLICT (cliente_id, preventista_id) DO NOTHING' USING v_cli2, v_p2;
    EXECUTE 'INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)
             ON CONFLICT (cliente_id, preventista_id) DO NOTHING' USING v_cli2, v_p2;
    EXECUTE 'WITH d AS (DELETE FROM cliente_preventistas WHERE cliente_id = $1 AND preventista_id IN ($2) RETURNING 1)
             SELECT count(*) FROM d' INTO v_n USING v_cli2, v_p2;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('3.3 · el admin desasignó %s filas de un cliente suyo; esperado 1', v_n);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    v_fallas := v_fallas || format('3.3 · el admin no pudo asignar en un cliente suyo: %s', SQLERRM);
  END;

  -- 3.4 · La rama del preventista no cambió: se asigna a sí mismo un cliente
  -- libre de su sucursal, con el upsert del front (también con la fila ya
  -- puesta). Borrar no podía antes ni puede ahora: cp_delete es sólo del admin,
  -- y el DELETE del front no borra nada.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p2, 'role', 'authenticated')::text, true);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)
             ON CONFLICT (cliente_id, preventista_id) DO NOTHING' USING v_cli2, v_p2;
    EXECUTE 'INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)
             ON CONFLICT (cliente_id, preventista_id) DO NOTHING' USING v_cli2, v_p2;
    EXECUTE 'WITH d AS (DELETE FROM cliente_preventistas WHERE cliente_id = $1 AND preventista_id IN ($2) RETURNING 1)
             SELECT count(*) FROM d' INTO v_n USING v_cli2, v_p2;
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 OR NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_cli2 AND preventista_id = v_p2) THEN
      v_fallas := v_fallas || format('3.4 · el preventista borró %s asignación(es); cp_delete es sólo del admin', v_n);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    v_fallas := v_fallas || format('3.4 · el preventista no pudo asignarse un cliente libre de su sucursal: %s', SQLERRM);
  END;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2, 'role', 'authenticated')::text, true);

  -- ---------------------------- 4 · metas y reportes mensuales (#1272) ---
  -- Una fila por sucursal y una de la Red, en un período que no existe.
  INSERT INTO metas_gerenciales (sucursal_id, periodo, metrica, valor)
  VALUES (v_s1, '2099-01-01', 'venta', 1), (v_s2, '2099-01-01', 'venta', 2), (NULL, '2099-01-01', 'venta', 3);
  INSERT INTO reportes_mensuales (sucursal_id, periodo, analisis_md)
  VALUES (v_s1, '2099-01-01', 'uno'), (v_s2, '2099-01-01', 'dos'), (NULL, '2099-01-01', 'red');

  -- 4.1 · El admin de v_s2: sólo la suya.
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT COALESCE(array_agg(COALESCE(sucursal_id, -1) ORDER BY COALESCE(sucursal_id, -1)), ''{}'') FROM metas_gerenciales WHERE periodo = ''2099-01-01''' INTO v_ids;
  EXECUTE 'RESET ROLE';
  IF v_ids IS DISTINCT FROM ARRAY[v_s2] THEN
    v_fallas := v_fallas || format('4.1 · el admin de la %s lee las metas de %s (-1 = Red)', v_s2, v_ids);
  END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT COALESCE(array_agg(COALESCE(sucursal_id, -1) ORDER BY COALESCE(sucursal_id, -1)), ''{}'') FROM reportes_mensuales WHERE periodo = ''2099-01-01''' INTO v_ids;
  EXECUTE 'RESET ROLE';
  IF v_ids IS DISTINCT FROM ARRAY[v_s2] THEN
    v_fallas := v_fallas || format('4.1 · el admin de la %s lee los análisis de %s (-1 = Red)', v_s2, v_ids);
  END IF;

  -- 4.2 · El admin de todas: todo, la Red incluida.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ared, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT COALESCE(array_agg(COALESCE(sucursal_id, -1) ORDER BY COALESCE(sucursal_id, -1)), ''{}'') FROM metas_gerenciales WHERE periodo = ''2099-01-01''' INTO v_ids;
  EXECUTE 'RESET ROLE';
  IF v_ids IS DISTINCT FROM ARRAY[-1, v_s1, v_s2] THEN
    v_fallas := v_fallas || format('4.2 · el admin de todas lee las metas de %s; esperado la Red y las dos', v_ids);
  END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT COALESCE(array_agg(COALESCE(sucursal_id, -1) ORDER BY COALESCE(sucursal_id, -1)), ''{}'') FROM reportes_mensuales WHERE periodo = ''2099-01-01''' INTO v_ids;
  EXECUTE 'RESET ROLE';
  IF v_ids IS DISTINCT FROM ARRAY[-1, v_s1, v_s2] THEN
    v_fallas := v_fallas || format('4.2 · el admin de todas lee los análisis de %s; esperado la Red y las dos', v_ids);
  END IF;

  -- 4.3 · Uno que no es admin: nada.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u2, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT (SELECT count(*) FROM metas_gerenciales WHERE periodo = ''2099-01-01'') + (SELECT count(*) FROM reportes_mensuales WHERE periodo = ''2099-01-01'')' INTO v_n;
  EXECUTE 'RESET ROLE';
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('4.3 · uno que no es admin lee %s metas o análisis', v_n);
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2, 'role', 'authenticated')::text, true);

  -- ----------------------------------- 5 · proveedores_eliminados (#1272) ---
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'proveedores_eliminados' AND column_name = 'sucursal_id') THEN
    v_fallas := v_fallas || '5 · proveedores_eliminados no tiene sucursal_id'::text;
  ELSE
    INSERT INTO proveedores (nombre, sucursal_id) VALUES ('ZZ ensayo 1272', v_s2) RETURNING id INTO v_prov;

    -- 5.1 · eliminar_proveedor (el admin de v_s2) deja la sucursal del proveedor.
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT public.eliminar_proveedor($1)' INTO r USING v_prov;
    EXECUTE 'RESET ROLE';
    EXECUTE 'SELECT sucursal_id FROM proveedores_eliminados WHERE proveedor_id = $1' INTO v_suc_pe USING v_prov;
    IF NOT COALESCE((r->>'success')::boolean, false) OR v_suc_pe IS DISTINCT FROM v_s2 THEN
      v_fallas := v_fallas || format('5.1 · el proveedor eliminado quedó con sucursal %s; esperado %s (%s)', v_suc_pe, v_s2, r);
    END IF;

    -- 5.2 · Lo ve el admin de v_s2, no el de v_s1; y las filas viejas (NULL), nadie.
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM proveedores_eliminados WHERE proveedor_id = $1' INTO v_n USING v_prov;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('5.2 · el admin de la %s no ve el proveedor que eliminó', v_s2);
    END IF;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_s1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a1, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM proveedores_eliminados WHERE proveedor_id = $1 OR sucursal_id IS NULL' INTO v_n USING v_prov;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('5.2 · el admin de la %s ve %s proveedor(es) eliminado(s) ajeno(s) o sin sucursal', v_s1, v_n);
    END IF;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_s2::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a2, 'role', 'authenticated')::text, true);
  END IF;

  -- ------------------------------------- 6 · auditoria_rpcs_definer (#1291) ---
  IF to_regprocedure('public.auditoria_rpcs_definer()') IS NULL THEN
    v_fallas := v_fallas || '6 · no existe auditoria_rpcs_definer()'::text;
  ELSE
    IF has_function_privilege('authenticated', 'public.auditoria_rpcs_definer()', 'EXECUTE')
       OR has_function_privilege('anon', 'public.auditoria_rpcs_definer()', 'EXECUTE') THEN
      v_fallas := v_fallas || '6.1 · auditoria_rpcs_definer() es ejecutable desde la API'::text;
    END IF;
    EXECUTE 'SELECT public.auditoria_rpcs_definer()' INTO r;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'gestion_usuarios') g
     WHERE g->>'nombre' IN ('asignar_usuario_sucursal', 'desasignar_usuario_sucursal') AND (g->>'acota')::boolean;
    IF v_n <> 2 THEN
      v_fallas := v_fallas || format('6.2 · el gate ve %s de las 2 RPCs de #1291 acotando al usuario', v_n);
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(r->'parametros') p
     WHERE p->>'nombre' = 'asignar_usuario_sucursal' AND p->>'parametro' = 'p_usuario_id' AND (p->>'acotado')::boolean;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || '6.3 · el gate no ve que asignar_usuario_sucursal acota p_usuario_id'::text;
    END IF;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ #1291/#1272 · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK #1291/#1272 · el admin asigna a los suyos, y las cinco policies miran la sucursal';
END
$ensayo$;
