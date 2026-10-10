-- Ensayo de #1072: el encargado ve las salvedades de su sucursal (RLS de
-- salvedades_items y salvedad_historial).
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION. Sólo lee: simula la sesión como PostgREST (SET LOCAL ROLE
-- authenticated + request.jwt.claims + x-sucursal-id) y compara lo que deja ver
-- la policy contra lo que debería ver cada rol, calculado como postgres (sin RLS).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR (el encargado ve sólo los pedidos que
-- cargó o repartió él); después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-salvedades-encargado-1072.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_enc      uuid;    -- encargado (perfiles.rol = 'encargado')
  v_suc      bigint;  -- sucursal default del encargado
  v_ajena    bigint;  -- una sucursal a la que el encargado NO pertenece
  v_admin    uuid;    -- admin de v_suc
  v_prev     uuid;    -- preventista de v_suc con salvedades propias
  v_transp   uuid;    -- transportista de v_suc con salvedades repartidas
  v_total_i  int;     -- salvedades_items de v_suc
  v_total_h  int;     -- salvedad_historial de v_suc
  v_esp_i    int;
  v_esp_h    int;
  v_ve_i     int;
  v_ve_h     int;
  v_ped      int;
  v_qual     text;
  r          record;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, us.sucursal_id INTO v_enc, v_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'encargado' AND COALESCE(pf.activo, true)
   ORDER BY us.es_default DESC NULLS LAST, pf.id LIMIT 1;
  IF v_enc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO SIN DATOS: no hay encargado activo con sucursal.';
  END IF;

  SELECT s.id INTO v_ajena FROM sucursales s
   WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = v_enc AND us.sucursal_id = s.id)
   ORDER BY s.id LIMIT 1;

  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  SELECT p.usuario_id INTO v_prev
    FROM salvedades_items si JOIN pedidos p ON p.id = si.pedido_id
    JOIN perfiles pf ON pf.id = p.usuario_id AND pf.rol = 'preventista'
    JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE si.sucursal_id = v_suc
   GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;

  SELECT p.transportista_id INTO v_transp
    FROM salvedades_items si JOIN pedidos p ON p.id = si.pedido_id
    JOIN perfiles pf ON pf.id = p.transportista_id AND pf.rol = 'transportista'
    JOIN usuario_sucursales us ON us.usuario_id = pf.id AND us.sucursal_id = v_suc
   WHERE si.sucursal_id = v_suc
   GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;

  SELECT count(*) INTO v_total_i FROM salvedades_items WHERE sucursal_id = v_suc;
  SELECT count(*) INTO v_total_h FROM salvedad_historial WHERE sucursal_id = v_suc;

  -- --------------------------------------- 1 · el encargado ve su sucursal --
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*), count(DISTINCT pedido_id) INTO v_ve_i, v_ped FROM salvedades_items;
  SELECT count(*) INTO v_ve_h FROM salvedad_historial;
  EXECUTE 'RESET ROLE';
  IF v_ve_i <> v_total_i THEN
    v_fallas := v_fallas || format('encargado · ve %s de %s salvedades_items de la sucursal %s', v_ve_i, v_total_i, v_suc);
  END IF;
  IF v_ve_h <> v_total_h THEN
    v_fallas := v_fallas || format('encargado · ve %s de %s filas de salvedad_historial de la sucursal %s', v_ve_h, v_total_h, v_suc);
  END IF;

  -- ------------------------------ 2 · y nada con una sucursal que no es suya --
  IF v_ajena IS NULL THEN
    v_saltados := v_saltados || 'sucursal ajena · el encargado pertenece a todas'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_ajena::text)::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_ve_i FROM salvedades_items;
    SELECT count(*) INTO v_ve_h FROM salvedad_historial;
    EXECUTE 'RESET ROLE';
    IF v_ve_i > 0 OR v_ve_h > 0 THEN
      v_fallas := v_fallas || format('encargado · con x-sucursal-id %s (ajena) ve %s salvedades y %s de historial', v_ajena, v_ve_i, v_ve_h);
    END IF;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  END IF;

  -- ------------------------------------------------ 3 · el admin, sin cambios --
  IF v_admin IS NULL THEN
    v_saltados := v_saltados || format('admin · no hay admin en la sucursal %s', v_suc);
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_ve_i FROM salvedades_items;
    SELECT count(*) INTO v_ve_h FROM salvedad_historial;
    EXECUTE 'RESET ROLE';
    IF v_ve_i <> v_total_i OR v_ve_h <> v_total_h THEN
      v_fallas := v_fallas || format('admin · ve %s/%s salvedades y %s/%s de historial', v_ve_i, v_total_i, v_ve_h, v_total_h);
    END IF;
  END IF;

  -- ---------- 4 · preventista y transportista: sólo lo suyo (trampa 4) -------
  FOR r IN SELECT * FROM (VALUES ('preventista', v_prev), ('transportista', v_transp)) t(rol, uid) LOOP
    IF r.uid IS NULL THEN
      v_saltados := v_saltados || format('%s · ninguno con salvedades en la sucursal %s', r.rol, v_suc);
      CONTINUE;
    END IF;
    SELECT count(*) INTO v_esp_i FROM salvedades_items si
     WHERE si.sucursal_id = v_suc
       AND EXISTS (SELECT 1 FROM pedidos p WHERE p.id = si.pedido_id
                     AND (p.usuario_id = r.uid OR p.transportista_id = r.uid));
    SELECT count(*) INTO v_esp_h FROM salvedad_historial sh
     WHERE sh.sucursal_id = v_suc
       AND EXISTS (SELECT 1 FROM salvedades_items si JOIN pedidos p ON p.id = si.pedido_id
                    WHERE si.id = sh.salvedad_id
                      AND (p.usuario_id = r.uid OR p.transportista_id = r.uid));
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_ve_i FROM salvedades_items;
    SELECT count(*) INTO v_ve_h FROM salvedad_historial;
    EXECUTE 'RESET ROLE';
    IF v_ve_i <> v_esp_i OR v_ve_h <> v_esp_h THEN
      v_fallas := v_fallas || format('%s %s · ve %s salvedades (esperado %s) y %s de historial (esperado %s)',
                                     r.rol, r.uid, v_ve_i, v_esp_i, v_ve_h, v_esp_h);
    END IF;
  END LOOP;

  -- -------------------------------- 5 · el predicado, no es_preventista() ---
  FOR v_qual IN SELECT qual FROM pg_policies
                 WHERE schemaname = 'public'
                   AND policyname IN ('mt_salvedades_items_select', 'mt_salvedad_historial_select') LOOP
    IF v_qual ~ 'es_preventista\(|es_transportista\(' THEN
      v_fallas := v_fallas || format('policy · el SELECT usa un helper multi-rol: %s', v_qual);
    END IF;
    IF v_qual !~ 'current_sucursal_id\(\)' THEN
      v_fallas := v_fallas || format('policy · el SELECT perdió el filtro de sucursal: %s', v_qual);
    END IF;
  END LOOP;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %\nSaltados:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
  END IF;
  RAISE EXCEPTION E'ENSAYO OK (todo revertido). sucursal %: % salvedades (% pedidos) y % de historial; ajena %; encargado %, admin %, preventista %, transportista %.\nSaltados:\n- %',
    v_suc, v_total_i, v_ped, v_total_h, v_ajena, v_enc, v_admin, v_prev, v_transp,
    COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
END
$ensayo$;
