-- Ensayo de #1075: las metas no cruzan sucursales.
--   1 · La tabla metas_preventista por REST: admin y encargado ven sólo las
--       metas de sus sucursales asignadas; el preventista, las suyas; el
--       admin de varias sucursales no pierde nada.
--   2 · avance_metas_preventista no devuelve el nombre de un preventista que
--       no comparte sucursal con el admin que pregunta.
--   3 · rendimiento_preventistas(p_sucursal_id) embebe sólo las metas de esa
--       sucursal, con el resumen recalculado; sin sucursal, todas las del
--       admin.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace (incluida la meta de
-- prueba del caso 3). Simula la sesión como PostgREST (SET LOCAL ROLE
-- authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1.1, 1.3, 2.1 y 3.1; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-metas-sucursal-1075.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_periodo  date := date_trunc('month', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)::date;

  v_admin1   uuid;    -- admin de UNA sola sucursal, con metas de otra en el mes
  v_suc1     bigint;
  v_ajeno    uuid;    -- preventista con metas sólo fuera de v_suc1
  v_propio   uuid;    -- preventista con metas en v_suc1
  v_multi    uuid;    -- admin con más sucursales asignadas
  v_suc2     bigint;  -- otra sucursal del admin multi
  v_enc      uuid;    -- encargado
  v_suc_enc  bigint;

  v_json     jsonb;
  v_meta     bigint;
  v_n        int;
  v_m        int;
  r          record;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, min(us.sucursal_id) INTO v_admin1, v_suc1
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
     AND EXISTS (SELECT 1 FROM metas_preventista m
                  WHERE m.activo
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

  SELECT pf.id INTO v_multi
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   GROUP BY pf.id HAVING count(DISTINCT us.sucursal_id) >= 2
   ORDER BY count(DISTINCT us.sucursal_id) DESC, pf.id LIMIT 1;

  SELECT min(sucursal_id) INTO v_suc2 FROM usuario_sucursales
   WHERE usuario_id = v_multi AND sucursal_id <> v_suc1;

  SELECT pf.id, min(us.sucursal_id) INTO v_enc, v_suc_enc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'encargado' AND COALESCE(pf.activo, true)
   GROUP BY pf.id ORDER BY pf.id LIMIT 1;

  -- ------------------------------------------------- 1 · la tabla por REST ---
  -- 1.1 · El admin de una sola sucursal no lee metas de otra.
  IF v_admin1 IS NULL THEN
    v_saltados := v_saltados || 'tabla 1.1: no hay admin de una sola sucursal con metas ajenas'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM metas_preventista
              WHERE sucursal_id NOT IN (SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())'
      INTO v_n;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('tabla 1.1 · un admin de la sucursal %s lee %s meta(s) de otra sucursal', v_suc1, v_n);
    END IF;
  END IF;

  -- 1.2 · El admin de varias sucursales lee todas las de sus sucursales.
  IF v_multi IS NULL THEN
    v_saltados := v_saltados || 'tabla 1.2: no hay admin de varias sucursales'::text;
  ELSE
    SELECT count(*) INTO v_m FROM metas_preventista
     WHERE sucursal_id IN (SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = v_multi);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_multi, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM metas_preventista' INTO v_n;
    EXECUTE 'RESET ROLE';
    IF v_n <> v_m THEN
      v_fallas := v_fallas || format('tabla 1.2 · el admin de varias sucursales lee %s de las %s metas de sus sucursales', v_n, v_m);
    END IF;
  END IF;

  -- 1.3 · El encargado, sólo las de su sucursal.
  IF v_enc IS NULL THEN
    v_saltados := v_saltados || 'tabla 1.3: no hay encargado'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc_enc::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM metas_preventista
              WHERE sucursal_id NOT IN (SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())'
      INTO v_n;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('tabla 1.3 · el encargado lee %s meta(s) de otra sucursal', v_n);
    END IF;
  END IF;

  -- 1.4 · El preventista, exactamente las suyas.
  IF v_propio IS NOT NULL THEN
    SELECT count(*) INTO v_m FROM metas_preventista WHERE preventista_id = v_propio;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_propio, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT count(*) FROM metas_preventista WHERE preventista_id <> auth.uid()' INTO v_n;
    EXECUTE 'SELECT count(*) FROM metas_preventista WHERE preventista_id = auth.uid()' INTO v_meta;
    EXECUTE 'RESET ROLE';
    IF v_n > 0 OR v_meta <> v_m THEN
      v_fallas := v_fallas || format('tabla 1.4 · el preventista lee %s ajenas y %s de sus %s metas', v_n, v_meta, v_m);
    END IF;
  END IF;

  -- -------------------------------------------- 2 · el nombre en el avance ---
  -- 2.1 · Un admin no recibe el nombre de un preventista con el que no
  --       comparte sucursal y del que no ve metas.
  IF v_admin1 IS NULL OR v_ajeno IS NULL
     OR EXISTS (SELECT 1 FROM usuario_sucursales a JOIN usuario_sucursales b ON b.sucursal_id = a.sucursal_id
                 WHERE a.usuario_id = v_admin1 AND b.usuario_id = v_ajeno) THEN
    v_saltados := v_saltados || 'nombre 2.1: no hay un par admin/preventista sin sucursal en común'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin1, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.avance_metas_preventista(v_ajeno, v_periodo);
    EXECUTE 'RESET ROLE';
    IF v_json->>'nombre' IS NOT NULL THEN
      v_fallas := v_fallas || 'nombre 2.1 · un admin recibe el nombre de un preventista de otra sucursal'::text;
    END IF;
  END IF;

  -- 2.2 · El admin de varias sucursales y el propio preventista, sí.
  IF v_multi IS NOT NULL AND v_ajeno IS NOT NULL THEN
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_multi, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.avance_metas_preventista(v_ajeno, v_periodo);
    EXECUTE 'RESET ROLE';
    IF v_json->>'nombre' IS DISTINCT FROM (SELECT nombre FROM perfiles WHERE id = v_ajeno) THEN
      v_fallas := v_fallas || 'nombre 2.2 · el admin de varias sucursales perdió el nombre del preventista'::text;
    END IF;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ajeno, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.avance_metas_preventista(NULL, v_periodo);
    EXECUTE 'RESET ROLE';
    IF v_json->>'nombre' IS DISTINCT FROM (SELECT nombre FROM perfiles WHERE id = v_ajeno) THEN
      v_fallas := v_fallas || 'nombre 2.2 · el preventista perdió su propio nombre'::text;
    END IF;
  END IF;

  -- ------------------------------------------- 3 · rendimiento por sucursal ---
  -- Hoy ningún preventista tiene metas en dos sucursales: se fabrica una (se
  -- revierte con todo lo demás). v_propio, de v_suc1, con una meta en v_suc2.
  IF v_multi IS NULL OR v_propio IS NULL OR v_suc2 IS NULL THEN
    v_saltados := v_saltados || 'rendimiento 3: falta admin de varias sucursales o preventista con metas'::text;
  ELSE
    INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo, usuario_id)
    VALUES (v_suc2, v_propio, v_periodo + 1, v_periodo + 20, 'cobertura', 1, v_multi)
    RETURNING id INTO v_meta;

    -- 3.1 · Filtrando por v_suc1, la meta de v_suc2 no aparece y el resumen
    --       cuenta lo que se muestra.
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc1::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_multi, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.rendimiento_preventistas(v_suc1, v_periodo);
    EXECUTE 'RESET ROLE';
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_json->'preventistas') p,
           jsonb_array_elements(p->'metas') e
      JOIN metas_preventista m ON m.id = (e->>'id')::bigint
     WHERE m.sucursal_id <> v_suc1;
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('rendimiento 3.1 · filtrando por la sucursal %s aparecen %s meta(s) de otra', v_suc1, v_n);
    END IF;
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_json->'preventistas') p
     WHERE (p->'resumen_metas'->>'total')::int <> jsonb_array_length(p->'metas')
        OR (p->'resumen_metas'->>'total')::int <> (p->>'metas_cargadas')::int;
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('rendimiento 3.1 · %s preventista(s) con un resumen que no cuenta las metas que muestra', v_n);
    END IF;

    -- 3.2 · Sin sucursal, el admin de varias las ve todas (no perdió nada):
    --       lo mismo que el avance directo.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_multi, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.rendimiento_preventistas(NULL, v_periodo);
    SELECT p INTO r FROM jsonb_array_elements(v_json->'preventistas') p WHERE p->>'preventista_id' = v_propio::text;
    v_json := public.avance_metas_preventista(v_propio, v_periodo);
    EXECUTE 'RESET ROLE';
    IF (r.p->'metas') IS DISTINCT FROM (v_json->'metas')
       OR (r.p->'resumen_metas') IS DISTINCT FROM (v_json->'resumen') THEN
      v_fallas := v_fallas || 'rendimiento 3.2 · sin sucursal, el rendimiento no muestra lo mismo que el avance'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r.p->'metas') e WHERE (e->>'id')::bigint = v_meta) THEN
      v_fallas := v_fallas || 'rendimiento 3.2 · sin sucursal, el admin de varias no ve la meta de la otra sucursal'::text;
    END IF;
  END IF;

  -- ----------------------------------------------------- 4 · SEG-A y SEG-B ---
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
  RAISE EXCEPTION E'ENSAYO OK (todo revertido). admin1 % (suc %), ajeno %, propio %, multi % (suc2 %), encargado % (suc %).\nSaltados:\n- %',
    v_admin1, v_suc1, v_ajeno, v_propio, v_multi, v_suc2, v_enc, v_suc_enc,
    COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
END
$ensayo$;
