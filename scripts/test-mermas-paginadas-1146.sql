-- Ensayo de #1146: el historial de mermas pagina en el servidor.
--
-- reporte_mermas recibe la pagina (p_offset, p_limite_detalle) y la busqueda
-- (p_busqueda: producto, codigo u observaciones). Lo que el ensayo exige es lo
-- que la pantalla y el gate necesitan: paginar o buscar acorta la LISTA y no
-- mueve ningun total, recorrer las paginas devuelve cada fila una vez, y la
-- busqueda da lo mismo que un filtrado hecho aparte.
--
-- Solo lecturas sobre las mermas reales (periodo historico, la sucursal con mas
-- mermas y la Red): no fabrica datos. La referencia independiente se calcula
-- desde mermas_valorizadas() --la fuente del criterio--, no desde la salida de
-- reporte_mermas. Cada caso corre en su propio sub-bloque: sin la migracion la
-- llamada con p_offset no existe y el caso se anota como falla sin abortar.
--
--   P1  · offset 0 sin busqueda: detalle = las primeras 500 por (created_at
--         DESC, id DESC); detalle_total = detalle_filtrado; detalle_offset 0;
--         detalle_truncado = total > 500; y fuera de las dos claves nuevas, lo
--         mismo que la llamada de siempre (la del gate, sin parametros nuevos)
--   P2  · totales, por_motivo, por_procedencia y detalle_total no se mueven con
--         offset ni busqueda (sin match, con match), en cada sucursal y la Red
--   P3  · recorrer paginas de 50 devuelve todas las filas, en orden y sin
--         repetir; truncado en todas menos la ultima
--   P4  · busqueda contra un filtrado INDEPENDIENTE (lower LIKE sobre las tres
--         columnas): misma cantidad y mismo conjunto de ids. Por nombre
--         (mayusculas y espacios), por codigo y por observaciones (con acento)
--   P5  · offset pasado del final: detalle [], detalle_filtrado = total,
--         truncado false, sin error
--   P6  · detalle_truncado = "hay mas despues de esta pagina"
--   P7  · bordes: offset NULL o negativo = 0; busqueda NULL o en blanco = sin
--         filtro; % y _ son literales (no comodines); limite 5000 -> 2000 y 0 -> 1
--   P8  · grants: anon y PUBLIC sin EXECUTE; authenticated y service_role con
--         EXECUTE (pasa antes y despues)
--   P9  · una sola sobrecarga, de 7 argumentos, p_offset INTEGER (no SMALLINT)
--         y p_busqueda text (PGRST203, trampa 5)
--   P10 · como PostgREST (authenticated): el encargado pagina su sucursal y la
--         Red resuelve a sus sucursales; otra sucursal y un preventista ->
--         Acceso denegado
--   P11 · compatibilidad: un bundle viejo (4 parametros con nombre) y la
--         llamada posicional de 5 (como la 301) siguen respondiendo igual
--         (pasa antes y despues)
--
-- Sin la migracion tienen que FALLAR P1 a P7, P9 y P10; P8 y P11 pasan antes y
-- despues. Con la migracion antepuesta: 'ENSAYO OK' y despues ENSAYO_ROLLBACK.
--
--   psql "$DATABASE_URL" -1 -f scripts/test-mermas-paginadas-1146.sql

DO $ensayo$
DECLARE
  v_desde  date := DATE '2020-01-01';
  v_hasta  date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_suc    bigint;   -- la sucursal con mas mermas
  v_suc_e  bigint;   -- la sucursal del encargado
  v_otra   bigint;   -- una sucursal que el encargado no tiene
  v_enc    uuid;     -- un encargado activo con UNA sucursal
  v_prev   uuid;     -- un preventista activo
  v_sql    text := 'SELECT public.reporte_mermas(p_desde => $1, p_hasta => $2, p_sucursal_id => $3, '
                   'p_motivo => NULL, p_limite_detalle => $4, p_offset => $5, p_busqueda => $6)';
  v_ref    bigint[]; -- ids de v_suc en el orden del reporte, calculados aparte
  v_n      int;
  v_ids    bigint[];
  v_pag    bigint[];
  v_base   jsonb;
  r        jsonb;
  v_q      text;
  v_cod    text;
  v_amb    bigint;
  v_off    int;
  v_trunc  boolean;
  v_err    text;
  v_fallas text[] := '{}';
BEGIN
  SELECT sucursal_id INTO v_suc
    FROM public.mermas_valorizadas(v_desde, v_hasta, (SELECT array_agg(id) FROM sucursales))
   GROUP BY sucursal_id ORDER BY count(*) DESC LIMIT 1;
  v_ref := ARRAY(SELECT id FROM public.mermas_valorizadas(v_desde, v_hasta, ARRAY[v_suc])
                  ORDER BY created_at DESC, id DESC);
  v_n := cardinality(v_ref);
  IF v_n <= 500 THEN
    RAISE EXCEPTION 'ENSAYO SIN DATOS: la sucursal % tiene % mermas, hacen falta mas de 500', v_suc, v_n;
  END IF;

  SELECT p.id, min(us.sucursal_id) INTO v_enc, v_suc_e
    FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'encargado' AND p.activo
   GROUP BY p.id HAVING count(*) = 1 LIMIT 1;
  SELECT id INTO v_prev FROM perfiles WHERE rol = 'preventista' AND activo LIMIT 1;

  -- La base: la llamada de siempre (la del gate), sin parametros nuevos.
  v_base := public.reporte_mermas(v_desde, v_hasta, v_suc);

  -- ------------------------------------------------------------------ P1 ---
  BEGIN
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 500, 0, NULL::text;
    v_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(r->'detalle') WITH ORDINALITY t(x, o) ORDER BY o);
    IF v_ids IS DISTINCT FROM v_ref[1:500] THEN
      v_fallas := v_fallas || 'P1 · el detalle no son las primeras 500 en orden'::text;
    END IF;
    IF (r->>'detalle_total')::int <> v_n OR (r->>'detalle_filtrado')::int IS DISTINCT FROM v_n
       OR (r->>'detalle_offset')::int IS DISTINCT FROM 0 OR (r->>'detalle_limite')::int <> 500
       OR (r->>'detalle_truncado')::boolean IS DISTINCT FROM (v_n > 500) THEN
      v_fallas := v_fallas || format('P1 · claves: total %s filtrado %s offset %s limite %s truncado %s (esperado %s)',
        r->>'detalle_total', r->>'detalle_filtrado', r->>'detalle_offset', r->>'detalle_limite', r->>'detalle_truncado', v_n);
    END IF;
    -- Fuera de las dos claves nuevas, la misma respuesta que la llamada de
    -- siempre (la base corre con la funcion vigente: antes o despues).
    IF r - 'detalle_filtrado' - 'detalle_offset' - 'meta'
       IS DISTINCT FROM v_base - 'detalle_filtrado' - 'detalle_offset' - 'meta' THEN
      v_fallas := v_fallas || 'P1 · con offset 0 y sin busqueda la respuesta no es la de la llamada de siempre'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P1 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P2 ---
  BEGIN
    FOR v_amb IN SELECT id FROM sucursales WHERE activa UNION ALL SELECT NULL LOOP
      v_base := public.reporte_mermas(v_desde, v_hasta, v_amb);
      FOREACH v_q IN ARRAY ARRAY['zzzz-sin-match', 'manaos', ''] LOOP
        EXECUTE v_sql INTO r USING v_desde, v_hasta, v_amb, 1, 1, v_q;
        IF r->'totales' IS DISTINCT FROM v_base->'totales'
           OR r->'por_motivo' IS DISTINCT FROM v_base->'por_motivo'
           OR r->'por_procedencia' IS DISTINCT FROM v_base->'por_procedencia'
           OR r->'detalle_total' IS DISTINCT FROM v_base->'detalle_total' THEN
          v_fallas := v_fallas || format('P2 · sucursal %s, busqueda %L: paginar o buscar movio un total',
                                         COALESCE(v_amb::text, 'Red'), v_q);
        END IF;
      END LOOP;
    END LOOP;
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 1, 1, 'zzzz-sin-match';
    IF (r->>'detalle_filtrado')::int IS DISTINCT FROM 0 OR jsonb_array_length(r->'detalle') <> 0 THEN
      v_fallas := v_fallas || format('P2 · busqueda sin match: filtrado %s', r->>'detalle_filtrado');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P2 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P3 ---
  BEGIN
    v_ids := '{}';
    v_off := 0;
    WHILE v_off < v_n LOOP
      EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 50, v_off, NULL::text;
      v_ids := v_ids || ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(r->'detalle') WITH ORDINALITY t(x, o) ORDER BY o);
      IF (r->>'detalle_truncado')::boolean IS DISTINCT FROM (v_off + 50 < v_n) THEN
        v_fallas := v_fallas || format('P3 · offset %s: truncado %s', v_off, r->>'detalle_truncado');
      END IF;
      v_off := v_off + 50;
    END LOOP;
    IF v_ids IS DISTINCT FROM v_ref THEN
      v_fallas := v_fallas || format('P3 · recorrer de a 50 dio %s filas (%s unicas), esperadas %s en orden',
        cardinality(v_ids), (SELECT count(DISTINCT x) FROM unnest(v_ids) x), v_n);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P3 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P4 ---
  BEGIN
    SELECT producto_codigo INTO v_cod
      FROM public.mermas_valorizadas(v_desde, v_hasta, ARRAY[v_suc])
     WHERE producto_codigo IS NOT NULL AND btrim(producto_codigo) <> ''
     GROUP BY producto_codigo ORDER BY count(*) DESC LIMIT 1;
    FOREACH v_q IN ARRAY ARRAY['  MaNaOs ', v_cod, 'cáritas', 'sustitucion'] LOOP
      -- El filtrado independiente, sobre la fuente del criterio.
      v_pag := ARRAY(
        SELECT id FROM public.mermas_valorizadas(v_desde, v_hasta, ARRAY[v_suc])
         WHERE lower(producto_nombre) LIKE '%' || lower(btrim(v_q)) || '%'
            OR lower(COALESCE(producto_codigo, '')) LIKE '%' || lower(btrim(v_q)) || '%'
            OR lower(COALESCE(observaciones, '')) LIKE '%' || lower(btrim(v_q)) || '%'
         ORDER BY id);
      IF cardinality(v_pag) = 0 OR cardinality(v_pag) = v_n THEN
        v_fallas := v_fallas || format('P4 · la busqueda %L no discrimina (%s de %s): el caso no muerde',
                                       v_q, cardinality(v_pag), v_n);
        CONTINUE;
      END IF;
      EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 2000, 0, v_q;
      v_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(r->'detalle') x ORDER BY 1);
      IF (r->>'detalle_filtrado')::int IS DISTINCT FROM cardinality(v_pag) OR v_ids IS DISTINCT FROM v_pag THEN
        v_fallas := v_fallas || format('P4 · busqueda %L: filtrado %s, filas %s; independiente %s',
                                       v_q, r->>'detalle_filtrado', cardinality(v_ids), cardinality(v_pag));
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P4 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P5 ---
  BEGIN
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 20, v_n + 100, NULL::text;
    IF r->'detalle' IS DISTINCT FROM '[]'::jsonb
       OR (r->>'detalle_filtrado')::int IS DISTINCT FROM v_n
       OR (r->>'detalle_truncado')::boolean IS DISTINCT FROM false
       OR (r->>'detalle_offset')::int IS DISTINCT FROM v_n + 100 THEN
      v_fallas := v_fallas || format('P5 · offset pasado: detalle %s, filtrado %s, truncado %s',
        jsonb_array_length(r->'detalle'), r->>'detalle_filtrado', r->>'detalle_truncado');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P5 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P6 ---
  BEGIN
    FOREACH v_off IN ARRAY ARRAY[0, v_n - 11, v_n - 10, v_n - 3] LOOP
      EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 10, v_off, NULL::text;
      v_trunc := (r->>'detalle_truncado')::boolean;
      IF v_trunc IS DISTINCT FROM (v_off + 10 < v_n)
         OR jsonb_array_length(r->'detalle') <> LEAST(10, v_n - v_off) THEN
        v_fallas := v_fallas || format('P6 · offset %s de %s: truncado %s, filas %s',
                                       v_off, v_n, r->>'detalle_truncado', jsonb_array_length(r->'detalle'));
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P6 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P7 ---
  BEGIN
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 5, NULL::int, NULL::text;
    v_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(r->'detalle') WITH ORDINALITY t(x, o) ORDER BY o);
    IF v_ids IS DISTINCT FROM v_ref[1:5] OR (r->>'detalle_offset')::int IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || 'P7 · offset NULL no es 0'::text;
    END IF;
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 5, -7, NULL::text;
    v_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(r->'detalle') WITH ORDINALITY t(x, o) ORDER BY o);
    IF v_ids IS DISTINCT FROM v_ref[1:5] OR (r->>'detalle_offset')::int IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || 'P7 · offset negativo no es 0'::text;
    END IF;
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 5, 0, '   ';
    IF (r->>'detalle_filtrado')::int IS DISTINCT FROM v_n THEN
      v_fallas := v_fallas || format('P7 · busqueda en blanco filtra: %s de %s', r->>'detalle_filtrado', v_n);
    END IF;
    FOREACH v_q IN ARRAY ARRAY['%', '_'] LOOP
      SELECT count(*) INTO v_off FROM public.mermas_valorizadas(v_desde, v_hasta, ARRAY[v_suc])
       WHERE strpos(lower(producto_nombre), v_q) > 0
          OR strpos(lower(COALESCE(producto_codigo, '')), v_q) > 0
          OR strpos(lower(COALESCE(observaciones, '')), v_q) > 0;
      EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 5, 0, v_q;
      IF (r->>'detalle_filtrado')::int IS DISTINCT FROM v_off OR v_off = v_n THEN
        v_fallas := v_fallas || format('P7 · %L es comodin: filtrado %s, literal %s de %s',
                                       v_q, r->>'detalle_filtrado', v_off, v_n);
      END IF;
    END LOOP;
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 5000, 0, NULL::text;
    IF (r->>'detalle_limite')::int <> 2000 OR jsonb_array_length(r->'detalle') <> LEAST(2000, v_n) THEN
      v_fallas := v_fallas || format('P7 · limite 5000: %s', r->>'detalle_limite');
    END IF;
    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc, 0, 3, NULL::text;
    IF (r->>'detalle_limite')::int <> 1 OR (r->'detalle'->0->>'id')::bigint IS DISTINCT FROM v_ref[4] THEN
      v_fallas := v_fallas || format('P7 · limite 0 con offset 3: limite %s', r->>'detalle_limite');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P7 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P8 ---
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'reporte_mermas') THEN
      v_fallas := v_fallas || 'P8 · no hay reporte_mermas'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p
                WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'reporte_mermas'
                  AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                       OR NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
                       OR NOT has_function_privilege('service_role', p.oid, 'EXECUTE')
                       OR p.proacl IS NULL
                       OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) x WHERE x.grantee = 0))) THEN
      v_fallas := v_fallas || 'P8 · grants: anon o PUBLIC con EXECUTE, o authenticated/service_role sin'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P8 · error: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P9 ---
  BEGIN
    IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'reporte_mermas') <> 1
       OR to_regprocedure('public.reporte_mermas(date,date,bigint,text,integer,integer,text)') IS NULL
       OR (SELECT proargnames[6:7] FROM pg_proc
            WHERE oid = to_regprocedure('public.reporte_mermas(date,date,bigint,text,integer,integer,text)'))
          IS DISTINCT FROM ARRAY['p_offset', 'p_busqueda']
       OR NOT (SELECT prosecdef FROM pg_proc
                WHERE oid = to_regprocedure('public.reporte_mermas(date,date,bigint,text,integer,integer,text)')) THEN
      v_fallas := v_fallas || format('P9 · firmas: %s', (SELECT string_agg(oid::regprocedure::text, ' | ')
        FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'reporte_mermas'));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P9 · error: ' || SQLERRM);
  END;

  -- ----------------------------------------------------------------- P10 ---
  BEGIN
    IF v_enc IS NULL OR v_prev IS NULL THEN
      RAISE EXCEPTION 'no hay encargado con una sucursal o preventista activo';
    END IF;
    v_pag := ARRAY(SELECT id FROM public.mermas_valorizadas(v_desde, v_hasta, ARRAY[v_suc_e])
                    ORDER BY created_at DESC, id DESC);
    IF cardinality(v_pag) < 20 THEN
      RAISE EXCEPTION 'la sucursal % tiene % mermas, hacen falta 20', v_suc_e, cardinality(v_pag);
    END IF;

    SELECT id INTO v_otra FROM sucursales WHERE id <> v_suc_e ORDER BY id LIMIT 1;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    EXECUTE v_sql INTO r USING v_desde, v_hasta, v_suc_e, 10, 10, NULL::text;
    v_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(r->'detalle') WITH ORDINALITY t(x, o) ORDER BY o);
    IF v_ids IS DISTINCT FROM v_pag[11:20] THEN
      v_fallas := v_fallas || 'P10 · el encargado no recibe la pagina 2 de su sucursal'::text;
    END IF;
    EXECUTE v_sql INTO r USING v_desde, v_hasta, NULL::bigint, 10, 0, NULL::text;
    IF (r->>'detalle_filtrado')::int IS DISTINCT FROM cardinality(v_pag) THEN
      v_fallas := v_fallas || format('P10 · la Red del encargado da %s, su sucursal %s',
                                     r->>'detalle_filtrado', cardinality(v_pag));
    END IF;

    v_err := NULL;
    BEGIN
      EXECUTE v_sql INTO r USING v_desde, v_hasta, v_otra, 10, 0, NULL::text;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err IS NULL OR v_err NOT LIKE 'Acceso denegado%' THEN
      v_fallas := v_fallas || format('P10 · otra sucursal: %s', COALESCE(v_err, 'respondio'));
    END IF;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
    v_err := NULL;
    BEGIN
      EXECUTE v_sql INTO r USING v_desde, v_hasta, NULL::bigint, 10, 0, NULL::text;
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err IS NULL OR v_err NOT LIKE 'Acceso denegado%' THEN
      v_fallas := v_fallas || format('P10 · preventista: %s', COALESCE(v_err, 'respondio'));
    END IF;

    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P10 · error: ' || SQLERRM);
  END;
  -- El sub-bloque revierte el SET LOCAL si fallo; por las dudas:
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);

  -- ----------------------------------------------------------------- P11 ---
  BEGIN
    EXECUTE 'SELECT public.reporte_mermas(p_desde => $1, p_hasta => $2, p_sucursal_id => $3, p_motivo => NULL)'
      INTO r USING v_desde, v_hasta, v_suc;
    v_ids := ARRAY(SELECT (x->>'id')::bigint FROM jsonb_array_elements(r->'detalle') WITH ORDINALITY t(x, o) ORDER BY o);
    IF v_ids IS DISTINCT FROM v_ref[1:500] OR (r->>'detalle_total')::int <> v_n
       OR (r->>'detalle_truncado')::boolean IS DISTINCT FROM (v_n > 500) THEN
      v_fallas := v_fallas || 'P11 · la llamada de 4 parametros con nombre cambio'::text;
    END IF;
    EXECUTE 'SELECT public.reporte_mermas($1, $2, $3, NULL, NULL)' INTO r USING v_desde, v_hasta, v_suc;
    IF jsonb_array_length(r->'detalle') <> 500 OR (r->>'detalle_limite')::int <> 500 THEN
      v_fallas := v_fallas || 'P11 · la llamada posicional de 5 cambio'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P11 · error: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK';
END
$ensayo$;

-- Nada de lo de arriba queda escrito: la transaccion se revierte entera.
DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
