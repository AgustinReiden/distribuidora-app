-- Ensayo de #1245 (migración 405): funciones de trigger sin EXECUTE para la app,
-- y el depósito sin los costos de compra.
--   1 · perfiles_guard_desactivacion y perfiles_sync_acceso_auth: sin EXECUTE
--       para PUBLIC, anon ni authenticated; postgres y service_role lo conservan.
--   2 · Los dos triggers siguen disparando para el admin que desactiva: el
--       guard frena que se desactive a sí mismo, y el sync banea en auth.users
--       al desactivado y lo desbanea al reactivarlo.
--   3 · auditoria_permisos_execute() cuenta las funciones de trigger que la app
--       ejecuta: 0 hoy, y 1 si se le da EXECUTE a una (lo que mira
--       scripts/check-permisos.mjs).
--   4 · El depósito no lee compra_items ni nota_credito_items; admin y
--       encargado leen todo lo de su sucursal, como antes. La cabecera de la
--       compra no cambia (no es parte de la decisión).
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
-- No hay usuarios con rol depósito en prod: el ensayo convierte uno adentro de
-- la transacción.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1, 3 y 4; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-triggers-y-deposito-1245.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_admin    uuid;    -- admin de todas las sucursales (abarca a cualquiera)
  v_victima  uuid;    -- usuario activo, no admin, que no es v_admin
  v_dep      uuid;    -- usuario que el ensayo convierte en depósito
  v_suc      bigint;  -- sucursal con líneas de compra y de nota de crédito
  v_enc      uuid;    -- encargado o admin de v_suc

  v_fn       text;
  v_n        int;
  v_m        int;
  v_ok       boolean;
  v_ban      timestamptz;
  v_json     jsonb;
BEGIN
  -- --------------------------------------- 1 · sin EXECUTE para la app ---
  FOREACH v_fn IN ARRAY ARRAY['public.perfiles_guard_desactivacion()', 'public.perfiles_sync_acceso_auth()'] LOOP
    IF has_function_privilege('anon', v_fn, 'EXECUTE') OR has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
      v_fallas := v_fallas || format('1.1 · %s es ejecutable por la app (anon o authenticated)', v_fn);
    END IF;
    IF NOT has_function_privilege('postgres', v_fn, 'EXECUTE') OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      v_fallas := v_fallas || format('1.2 · %s perdió el EXECUTE de postgres o service_role', v_fn);
    END IF;
  END LOOP;

  -- ------------------------------------ 2 · los triggers siguen disparando ---
  -- El admin de más sucursales, y un usuario cuyas sucursales son todas suyas.
  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id
   ORDER BY count(DISTINCT us.sucursal_id) DESC, pf.id LIMIT 1;
  SELECT pf.id INTO v_victima
    FROM perfiles pf
   WHERE pf.rol <> 'admin' AND COALESCE(pf.activo, true) AND pf.id <> v_admin
     AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = pf.id)
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id)
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                      WHERE us.usuario_id = pf.id
                        AND us.sucursal_id NOT IN (SELECT a.sucursal_id FROM usuario_sucursales a WHERE a.usuario_id = v_admin))
   ORDER BY pf.id LIMIT 1;

  IF v_admin IS NULL OR v_victima IS NULL THEN
    v_saltados := v_saltados || '2: falta un admin o un usuario activo de sus sucursales'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id',
      (SELECT min(sucursal_id) FROM usuario_sucursales WHERE usuario_id = v_victima)::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

    -- 2.1 · El guard: no se desactiva a sí mismo.
    v_ok := false;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'UPDATE perfiles SET activo = false WHERE id = $1' USING v_admin;
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN raise_exception THEN v_ok := true;
    END;
    IF NOT v_ok THEN
      v_fallas := v_fallas || '2.1 · el admin se desactivó a sí mismo: perfiles_guard_desactivacion no disparó'::text;
    END IF;

    -- 2.2 · El sync: el desactivado queda baneado, y el reactivado no.
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'WITH u AS (UPDATE perfiles SET activo = false WHERE id = $1 RETURNING 1) SELECT count(*) FROM u'
      INTO v_n USING v_victima;
    EXECUTE 'RESET ROLE';
    SELECT banned_until INTO v_ban FROM auth.users WHERE id = v_victima;
    IF v_n <> 1 OR v_ban IS NULL OR v_ban < now() + interval '10 years' THEN
      v_fallas := v_fallas || format('2.2 · desactivar no baneó al usuario (filas %s, banned_until %s)', v_n, v_ban);
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'UPDATE perfiles SET activo = true WHERE id = $1' USING v_victima;
    EXECUTE 'RESET ROLE';
    SELECT banned_until INTO v_ban FROM auth.users WHERE id = v_victima;
    IF v_ban IS NOT NULL THEN
      v_fallas := v_fallas || '2.3 · reactivar no desbaneó al usuario'::text;
    END IF;
  END IF;

  -- -------------------------------------- 3 · auditoria_permisos_execute ---
  v_json := public.auditoria_permisos_execute();
  IF NOT (v_json ? 'triggers_ejecutables_por_la_app') THEN
    v_fallas := v_fallas || '3 · auditoria_permisos_execute() no informa triggers_ejecutables_por_la_app'::text;
  ELSE
    IF (v_json->>'triggers_ejecutables_por_la_app')::int <> 0 THEN
      v_fallas := v_fallas || format('3.1 · quedan %s función(es) de trigger ejecutables por la app: %s',
        v_json->>'triggers_ejecutables_por_la_app', v_json->'detalle_triggers_ejecutables');
    END IF;
    -- 3.2 · Y la ve si alguien le da EXECUTE a una (se deshace con el bloque).
    BEGIN
      GRANT EXECUTE ON FUNCTION public.perfiles_sync_acceso_auth() TO authenticated;
      v_json := public.auditoria_permisos_execute();
      IF (v_json->>'triggers_ejecutables_por_la_app')::int < 1
         OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_json->'detalle_triggers_ejecutables') d
                         WHERE d->>'firma' = 'perfiles_sync_acceso_auth()') THEN
        v_fallas := v_fallas || '3.2 · un trigger con EXECUTE para authenticated no sale en auditoria_permisos_execute()'::text;
      END IF;
      RAISE EXCEPTION 'deshacer el GRANT' USING ERRCODE = 'P0001';
    EXCEPTION WHEN raise_exception THEN NULL;
    END;
  END IF;

  -- -------------------------------------------- 4 · el depósito sin costos ---
  SELECT ci.sucursal_id INTO v_suc
    FROM compra_items ci
   WHERE EXISTS (SELECT 1 FROM nota_credito_items n WHERE n.sucursal_id = ci.sucursal_id)
   GROUP BY ci.sucursal_id ORDER BY count(*) DESC LIMIT 1;
  IF v_suc IS NULL THEN
    SELECT sucursal_id INTO v_suc FROM compra_items GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;
  END IF;
  -- Un usuario de esa sucursal que no sea admin ni encargado, convertido en depósito.
  SELECT pf.id INTO v_dep
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.rol IN ('transportista', 'preventista')
   ORDER BY (pf.rol = 'transportista') DESC, pf.id LIMIT 1;
  SELECT pf.id INTO v_enc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE pf.rol IN ('encargado', 'admin') AND COALESCE(pf.activo, true)
   ORDER BY (pf.rol = 'encargado') DESC, pf.id LIMIT 1;

  IF v_suc IS NULL OR v_dep IS NULL OR v_enc IS NULL THEN
    v_saltados := v_saltados || '4: falta una sucursal con compras, un usuario para depósito o un encargado'::text;
  ELSE
    UPDATE perfiles SET rol = 'deposito' WHERE id = v_dep;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    -- 4.1 · El depósito no lee las líneas.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_dep, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM compra_items' INTO v_n;
    EXECUTE 'SELECT count(*) FROM nota_credito_items' INTO v_m;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('4.1 · el depósito lee %s línea(s) de compra con su costo', v_n);
    END IF;
    IF v_m > 0 THEN
      v_fallas := v_fallas || format('4.1 · el depósito lee %s línea(s) de nota de crédito de compra con su costo', v_m);
    END IF;
    -- 4.2 · La cabecera de la compra, como antes.
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM compras' INTO v_n;
    EXECUTE 'RESET ROLE';
    IF v_n <> (SELECT count(*) FROM compras WHERE sucursal_id = v_suc) THEN
      v_fallas := v_fallas || '4.2 · la cabecera de la compra cambió para el depósito (no era parte de la decisión)'::text;
    END IF;

    -- 4.3 · Admin y encargado leen todas las de su sucursal.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM compra_items' INTO v_n;
    EXECUTE 'SELECT count(*) FROM nota_credito_items' INTO v_m;
    EXECUTE 'RESET ROLE';
    IF v_n <> (SELECT count(*) FROM compra_items WHERE sucursal_id = v_suc)
       OR v_m <> (SELECT count(*) FROM nota_credito_items WHERE sucursal_id = v_suc) THEN
      v_fallas := v_fallas || format('4.3 · el %s no lee todas las líneas de compra o de NC de su sucursal',
                                     (SELECT rol FROM perfiles WHERE id = v_enc));
    END IF;

    -- 4.4 · La decisión queda escrita al lado de la policy.
    IF obj_description((SELECT oid FROM pg_policy WHERE polname = 'mt_compra_items_select'
                         AND polrelid = 'public.compra_items'::regclass), 'pg_policy') IS NULL THEN
      v_fallas := v_fallas || '4.4 · mt_compra_items_select no dice por qué el depósito no la lee'::text;
    END IF;
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK #1245 (triggers sin EXECUTE, depósito sin costos)%',
      CASE WHEN cardinality(v_saltados) > 0 THEN ' · saltados: ' || array_to_string(v_saltados, ' | ') ELSE '' END;
  ELSE
    RAISE EXCEPTION 'ENSAYO FALLÓ #1245: % %',
      array_to_string(v_fallas, ' | '),
      CASE WHEN cardinality(v_saltados) > 0 THEN ' · saltados: ' || array_to_string(v_saltados, ' | ') ELSE '' END;
  END IF;
END
$ensayo$;
