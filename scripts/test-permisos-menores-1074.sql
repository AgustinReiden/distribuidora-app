-- Ensayo de #1074: permisos menores.
--   1 · avance_metas_preventista no cruza sucursales (y el admin de varias no
--       pierde nada).
--   2 · perfil_de_sucursal_activa: authenticated la necesita (la evalúa la
--       policy de perfiles) y no dice nada que la tabla no muestre.
--   3 · pagos_forzar_usuario (trigger) sin EXECUTE para la app, y el trigger
--       sigue firmando el pago.
--   4 · El encargado da de alta proveedores de su sucursal (decisión del dueño,
--       2026-10-09); editar sigue siendo del admin.
--   5 · SEG-A: la lista blanca es por firma + md5 del cuerpo. Cambiar el cuerpo
--       de una función exceptuada la vuelve a poner en rojo.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1, 3, 4 y 5; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-menores-1074.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_periodo  date := date_trunc('month', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)::date;

  v_admin1   uuid;    -- admin de UNA sola sucursal
  v_suc1     bigint;  -- su sucursal
  v_ajeno    uuid;    -- preventista con metas vigentes sólo fuera de v_suc1
  v_propio   uuid;    -- preventista con metas vigentes en v_suc1
  v_multi    uuid;    -- admin asignado a TODAS las sucursales

  v_enc      uuid;    -- encargado (no admin)
  v_suc_enc  bigint;
  v_otra_suc bigint;  -- una sucursal que no es la del encargado
  v_prev     uuid;    -- preventista (no admin ni encargado) de v_suc_enc
  v_cliente  bigint;  -- cliente de v_suc_enc

  v_json     jsonb;
  v_json2    jsonb;
  v_ids      bigint[];
  v_ids2     bigint[];
  v_uuids    uuid[];
  v_n        int;
  v_id       bigint;
  v_uid      uuid;
  v_bool     boolean;
  v_def      text;
  r          record;
BEGIN

  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, min(us.sucursal_id) INTO v_admin1, v_suc1
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
     -- con un preventista de metas vigentes en otra sucursal
     AND EXISTS (SELECT 1 FROM metas_preventista m
                  WHERE m.activo AND m.periodo <= (v_periodo + interval '1 month - 1 day')::date
                    AND m.periodo_fin >= v_periodo
                    AND m.sucursal_id NOT IN (SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = pf.id))
   GROUP BY pf.id HAVING count(*) = 1
   ORDER BY pf.id LIMIT 1;

  SELECT m.preventista_id INTO v_ajeno
    FROM metas_preventista m
   WHERE m.activo AND m.periodo <= (v_periodo + interval '1 month - 1 day')::date AND m.periodo_fin >= v_periodo
   GROUP BY m.preventista_id
  HAVING bool_and(m.sucursal_id <> v_suc1)
   ORDER BY m.preventista_id LIMIT 1;

  SELECT m.preventista_id INTO v_propio
    FROM metas_preventista m
   WHERE m.activo AND m.periodo <= (v_periodo + interval '1 month - 1 day')::date AND m.periodo_fin >= v_periodo
     AND m.sucursal_id = v_suc1
   ORDER BY m.preventista_id LIMIT 1;

  -- El admin con más sucursales asignadas.
  SELECT pf.id INTO v_multi
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id HAVING count(DISTINCT us.sucursal_id) >= 2
   ORDER BY count(DISTINCT us.sucursal_id) DESC, pf.id LIMIT 1;

  SELECT pf.id, min(us.sucursal_id) INTO v_enc, v_suc_enc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'encargado' AND COALESCE(pf.activo, true)
   GROUP BY pf.id ORDER BY pf.id LIMIT 1;

  SELECT id INTO v_otra_suc FROM sucursales WHERE id <> v_suc_enc ORDER BY id LIMIT 1;

  SELECT pf.id INTO v_prev
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'preventista' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc_enc
     -- Puede tener un rol extra (transportista), no uno de gestión.
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr
                      WHERE pr.usuario_id = pf.id AND pr.rol IN ('admin', 'encargado'))
   ORDER BY pf.id LIMIT 1;

  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc_enc ORDER BY id LIMIT 1;

  -- -------------------- 1 · avance_metas_preventista no cruza sucursales ---
  IF v_admin1 IS NULL OR v_ajeno IS NULL THEN
    v_saltados := v_saltados || 'avance_metas 1.1: no hay admin de una sola sucursal con un preventista de metas en otra'::text;
  ELSE
    -- 1.1 · El admin de una sola sucursal no ve las metas de otra.
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.avance_metas_preventista(v_ajeno, v_periodo);
    EXECUTE 'RESET ROLE';
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_json->'metas') e
      JOIN metas_preventista m ON m.id = (e->>'id')::bigint
     WHERE m.sucursal_id NOT IN (SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = v_admin1);
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('avance_metas 1.1 · un admin de la sucursal %s ve %s meta(s) de otra sucursal', v_suc1, v_n);
    END IF;
  END IF;

  -- 1.2 · Y sigue viendo las de su sucursal, todas.
  IF v_admin1 IS NULL OR v_propio IS NULL THEN
    v_saltados := v_saltados || 'avance_metas 1.2: no hay preventista con metas en la sucursal del admin'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.avance_metas_preventista(v_propio, v_periodo);
    EXECUTE 'RESET ROLE';
    SELECT count(*) INTO v_n FROM metas_preventista m
     WHERE m.preventista_id = v_propio AND m.activo AND m.sucursal_id = v_suc1
       AND m.periodo <= (v_periodo + interval '1 month - 1 day')::date AND m.periodo_fin >= v_periodo;
    IF jsonb_array_length(v_json->'metas') <> v_n THEN
      v_fallas := v_fallas || format('avance_metas 1.2 · el admin ve %s de las %s metas de su sucursal',
                                     jsonb_array_length(v_json->'metas'), v_n);
    END IF;
  END IF;

  -- 1.3 · El admin de todas las sucursales ve exactamente lo mismo que el
  --       servicio (auth.uid() NULL), para cada preventista con metas: no
  --       perdió nada. Y el preventista, sus propias metas, todas.
  FOR r IN SELECT DISTINCT m.preventista_id AS id FROM metas_preventista m
            WHERE m.activo AND m.periodo <= (v_periodo + interval '1 month - 1 day')::date
              AND m.periodo_fin >= v_periodo LOOP
    PERFORM set_config('request.jwt.claims', '{}', true);
    v_json := public.avance_metas_preventista(r.id, v_periodo);
    SELECT COALESCE(array_agg((e->>'id')::bigint ORDER BY (e->>'id')::bigint), '{}') INTO v_ids
      FROM jsonb_array_elements(v_json->'metas') e;

    IF v_multi IS NULL OR EXISTS (
         SELECT 1 FROM metas_preventista m
          WHERE m.preventista_id = r.id AND m.activo
            AND m.periodo <= (v_periodo + interval '1 month - 1 day')::date AND m.periodo_fin >= v_periodo
            AND m.sucursal_id NOT IN (SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = v_multi)) THEN
      v_saltados := v_saltados || format('avance_metas 1.3: el admin de varias sucursales no cubre las metas de %s', r.id);
    ELSE
      PERFORM set_config('request.headers', json_build_object('x-sucursal-id', (SELECT min(id) FROM sucursales)::text)::text, true);
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_multi, 'role', 'authenticated')::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      v_json2 := public.avance_metas_preventista(r.id, v_periodo);
      EXECUTE 'RESET ROLE';
      SELECT COALESCE(array_agg((e->>'id')::bigint ORDER BY (e->>'id')::bigint), '{}') INTO v_ids2
        FROM jsonb_array_elements(v_json2->'metas') e;
      IF v_ids2 IS DISTINCT FROM v_ids OR v_json2 IS DISTINCT FROM v_json THEN
        v_fallas := v_fallas || format('avance_metas 1.3 · el admin de todas las sucursales ve otra cosa que el servicio para %s', r.id);
      END IF;
    END IF;

    -- El propio preventista (con su sucursal activa cualquiera de las suyas).
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id',
      (SELECT min(sucursal_id) FROM usuario_sucursales WHERE usuario_id = r.id)::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.id, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json2 := public.avance_metas_preventista(NULL, v_periodo);
    EXECUTE 'RESET ROLE';
    SELECT COALESCE(array_agg((e->>'id')::bigint ORDER BY (e->>'id')::bigint), '{}') INTO v_ids2
      FROM jsonb_array_elements(v_json2->'metas') e;
    IF v_ids2 IS DISTINCT FROM v_ids THEN
      v_fallas := v_fallas || format('avance_metas 1.3 · el preventista %s no ve todas sus metas', r.id);
    END IF;
  END LOOP;

  -- 1.4 · Un preventista no lee el avance de otro (el guard de siempre).
  IF v_prev IS NOT NULL AND v_ajeno IS NOT NULL AND v_prev <> v_ajeno THEN
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc_enc::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      PERFORM public.avance_metas_preventista(v_ajeno, v_periodo);
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || 'avance_metas 1.4 · un preventista leyó el avance de otro'::text;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END IF;

  -- ------------------------------------------- 2 · perfil_de_sucursal_activa
  -- 2.1 · authenticated la necesita: la policy perfiles_select_sucursal la
  --       evalúa como el usuario. Sin EXECUTE, leer perfiles se rompe entero.
  IF NOT has_function_privilege('authenticated', 'public.perfil_de_sucursal_activa(uuid)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'perfil_de_sucursal_activa 2.1 · authenticated perdió el EXECUTE (la policy de perfiles lo necesita)'::text;
  END IF;
  v_bool := NULL;
  BEGIN
    REVOKE EXECUTE ON FUNCTION public.perfil_de_sucursal_activa(uuid) FROM authenticated;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc_enc::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE 'SELECT count(*) FROM perfiles' INTO v_n;
      v_bool := false;
    EXCEPTION WHEN insufficient_privilege THEN v_bool := true;
    END;
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'deshacer el REVOKE' USING ERRCODE = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF v_bool IS DISTINCT FROM true THEN
    v_fallas := v_fallas || 'perfil_de_sucursal_activa 2.1 · revocarla NO rompe leer perfiles: el motivo de la lista blanca quedó viejo'::text;
  END IF;

  -- 2.2 · No es un oráculo: todo uuid que da true es una fila que el mismo
  --       usuario ya ve en perfiles.
  SELECT array_agg(id) INTO v_uuids FROM perfiles;
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc_enc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE 'SELECT count(*) FROM unnest($1) AS x(id)
            WHERE public.perfil_de_sucursal_activa(x.id)
              AND NOT EXISTS (SELECT 1 FROM perfiles p WHERE p.id = x.id)'
    INTO v_n USING v_uuids;
  EXECUTE 'RESET ROLE';
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('perfil_de_sucursal_activa 2.2 · responde true para %s perfil(es) que el usuario no ve', v_n);
  END IF;

  -- ------------------------------------------------ 3 · pagos_forzar_usuario
  IF has_function_privilege('authenticated', 'public.pagos_forzar_usuario()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.pagos_forzar_usuario()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'pagos_forzar_usuario 3.1 · la app (authenticated o anon) tiene EXECUTE sobre una función de trigger'::text;
  END IF;
  IF NOT has_function_privilege('service_role', 'public.pagos_forzar_usuario()', 'EXECUTE')
     OR NOT has_function_privilege('postgres', 'public.pagos_forzar_usuario()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'pagos_forzar_usuario 3.1 · postgres o service_role perdieron el EXECUTE'::text;
  END IF;
  -- 3.2 · El trigger sigue disparando para authenticated: un pago a nombre de
  --       otro queda firmado por quien lo carga.
  IF v_enc IS NULL OR v_cliente IS NULL OR v_prev IS NULL THEN
    v_saltados := v_saltados || 'pagos_forzar_usuario 3.2: falta encargado, cliente o preventista'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc_enc::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'INSERT INTO pagos (cliente_id, monto, forma_pago, usuario_id, sucursal_id, notas)
             VALUES ($1, 1, ''efectivo'', $2, $3, ''ensayo #1074'') RETURNING id'
      INTO v_id USING v_cliente, v_prev, v_suc_enc;
    EXECUTE 'RESET ROLE';
    SELECT usuario_id INTO v_uid FROM pagos WHERE id = v_id;
    IF v_uid IS DISTINCT FROM v_enc THEN
      v_fallas := v_fallas || format('pagos_forzar_usuario 3.2 · el pago quedó a nombre de %s, no de quien lo cargó', v_uid);
    END IF;
  END IF;

  -- ------------------------------------------------- 4 · alta de proveedores
  IF v_enc IS NULL THEN
    v_saltados := v_saltados || 'proveedores: no hay encargado'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc_enc::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
    -- 4.1 · El encargado da de alta un proveedor de su sucursal (y lo lee de
    --       vuelta, como el insert + select del front).
    v_id := NULL;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'INSERT INTO proveedores (nombre, sucursal_id) VALUES (''ensayo #1074'', $1) RETURNING id'
        INTO v_id USING v_suc_enc;
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN insufficient_privilege THEN
      v_fallas := v_fallas || 'proveedores 4.1 · el encargado no puede dar de alta un proveedor de su sucursal'::text;
    END;

    -- 4.2 · Pero no en otra sucursal.
    IF v_otra_suc IS NOT NULL THEN
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE 'INSERT INTO proveedores (nombre, sucursal_id) VALUES (''ensayo #1074 ajeno'', $1)' USING v_otra_suc;
        EXECUTE 'RESET ROLE';
        v_fallas := v_fallas || 'proveedores 4.2 · el encargado dio de alta un proveedor en otra sucursal'::text;
      EXCEPTION WHEN insufficient_privilege THEN NULL;
      END;
    END IF;

    -- 4.3 · Editar y borrar siguen siendo del admin.
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'WITH u AS (UPDATE proveedores SET notas = ''ensayo #1074'' WHERE sucursal_id = $1 RETURNING 1)
             SELECT count(*) FROM u' INTO v_n USING v_suc_enc;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('proveedores 4.3 · el encargado editó %s proveedor(es)', v_n);
    END IF;
    IF v_id IS NOT NULL THEN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'WITH d AS (DELETE FROM proveedores WHERE id = $1 RETURNING 1) SELECT count(*) FROM d'
        INTO v_n USING v_id;
      EXECUTE 'RESET ROLE';
      IF v_n > 0 THEN
        v_fallas := v_fallas || 'proveedores 4.3 · el encargado borró un proveedor'::text;
      END IF;
    END IF;

    -- 4.4 · Un preventista no da de alta proveedores.
    IF v_prev IS NOT NULL THEN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE 'INSERT INTO proveedores (nombre, sucursal_id) VALUES (''ensayo #1074 prev'', $1)' USING v_suc_enc;
        EXECUTE 'RESET ROLE';
        v_fallas := v_fallas || 'proveedores 4.4 · un preventista dio de alta un proveedor'::text;
      EXCEPTION WHEN insufficient_privilege THEN NULL;
      END;
    END IF;
  END IF;

  -- ------------------------------------------- 5 · SEG-A: firma + md5 ---
  -- 5.1 · Cambiar el cuerpo de una función exceptuada (sin tocarle la firma)
  --       la vuelve a listar.
  v_bool := NULL;
  BEGIN
    v_def := pg_get_functiondef('public.perfil_de_sucursal_activa(uuid)'::regprocedure);
    EXECUTE replace(v_def, '  SELECT EXISTS (', '  -- ensayo #1074: cuerpo cambiado
  SELECT EXISTS (');
    SELECT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                    WHERE firma = 'perfil_de_sucursal_activa(uuid)') INTO v_bool;
    RAISE EXCEPTION 'deshacer el cambio de cuerpo' USING ERRCODE = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF v_bool IS DISTINCT FROM true THEN
    v_fallas := v_fallas || 'SEG-A 5.1 · una función de la lista blanca cambió de cuerpo y SEG-A no se enteró'::text;
  END IF;

  -- 5.2 · SEG-A y SEG-B en cero (como el gate: sin usuario).
  PERFORM set_config('request.jwt.claims', '{}', true);
  FOR r IN SELECT c->>'id' AS id, (c->>'violaciones')::int AS v
             FROM jsonb_array_elements(to_jsonb(public.auditoria_integridad())->'checks') c
            WHERE c->>'id' IN ('SEG-A', 'SEG-B') LOOP
    IF r.v <> 0 THEN
      v_fallas := v_fallas || format('%s · %s violaciones', r.id, r.v);
    END IF;
  END LOOP;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %\nSaltados:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
  END IF;
  RAISE EXCEPTION E'ENSAYO OK (todo revertido). admin1 % (suc %), ajeno %, propio %, multi %, encargado % (suc %), preventista %.\nSaltados:\n- %',
    v_admin1, v_suc1, v_ajeno, v_propio, v_multi, v_enc, v_suc_enc, v_prev,
    COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
END
$ensayo$;
