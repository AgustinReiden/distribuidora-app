-- Ensayo de la tarjeta B15 de la ola 2 del plan #1603 (1564-b8 y 1564-g4): el search_path de toda
-- función SECURITY DEFINER de public termina en pg_temp.
-- Migración: NNN_search_path_pg_temp. Gate: scripts/check-search-path.mjs.
--
-- Un único DO que termina SIEMPRE en una excepción: no deja rastro (la tabla temporal es ON COMMIT DROP y
-- se deshace con todo lo demás). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista.
--
-- El problema: sin pg_temp escrito en el search_path, Postgres busca PRIMERO en el esquema temporal de la
-- sesión las tablas, vistas y tipos. Una definer corre como su dueño (postgres), así que una tabla temporal
-- del que llama con el nombre de una tabla de public le tapa la real. Con pg_temp AL FINAL se busca último.
--
--   P · LA POSCONDICIÓN DE LA MIGRACIÓN (sobre el catálogo)
--     P1 ninguna SECURITY DEFINER de public sin search_path.
--     P2 ninguna SECURITY DEFINER de public cuyo search_path no termine en pg_temp.
--     P3 es_admin() (la de la demostración) sigue siendo definer y su search_path es «public, pg_temp».
--   D · LA DEMOSTRACIÓN, como authenticated, con es_admin() (de sólo lectura: lee perfiles sin esquema)
--     D1 un usuario que no tiene perfil no es admin (sin temporal: el punto de partida).
--     D2 crea una tabla temporal `perfiles` con su uuid y rol 'admin'. La temporal existe y, para sus propias
--        consultas sin esquema, le tapa la real (el control: si no, D3 no probaría nada).
--     D3 es_admin() sigue dando false: la función lee public.perfiles, no la temporal. ANTES de la
--        migración da true: un authenticated cualquiera se hace admin para toda definer que pregunte.
--     D4 el admin de la semilla, con la misma temporal en la sesión, sigue siendo admin: la función no la
--        ve. ANTES de la migración da false (la temporal no lo tiene).
DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_intruso uuid := '0b150000-0000-4000-8000-00000000b015';  -- inventado, sin perfil
  v_admin uuid := '00000000-0000-0000-0000-0000000004e7';    -- el admin de la semilla
  v_n int;
  v_txt text;
  v_es boolean;
  v_t text;
BEGIN
  BEGIN
    -- P1
    SELECT count(*), string_agg(p.oid::regprocedure::text, ', ') INTO v_n, v_txt
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%');
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('P1 %s definer sin search_path: %s', v_n, left(v_txt, 300));
    END IF;

    -- P2
    SELECT count(*), string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_n, v_txt
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c ~ '^search_path=(.*, )?pg_temp$');
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('P2 %s definer cuyo search_path no termina en pg_temp (p. ej. %s)', v_n, left(v_txt, 200));
    END IF;

    -- P3
    SELECT array_to_string(p.proconfig, ' | ') INTO v_txt
      FROM pg_proc p WHERE p.oid = 'public.es_admin()'::regprocedure AND p.prosecdef;
    IF v_txt IS DISTINCT FROM 'search_path=public, pg_temp' THEN
      v_fallas := v_fallas || format('P3 es_admin(): se esperaba definer con «search_path=public, pg_temp» y es «%s»', v_txt);
    END IF;

    -- D · como authenticated
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_intruso, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- D1
    v_es := public.es_admin();
    IF v_es IS DISTINCT FROM false THEN
      v_fallas := v_fallas || format('D1 un usuario sin perfil, sin temporal: es_admin() dio %s', v_es);
    END IF;

    -- D2
    CREATE TEMP TABLE perfiles (id uuid, rol text, activo boolean) ON COMMIT DROP;
    INSERT INTO perfiles (id, rol, activo) VALUES (v_intruso, 'admin', true);
    SELECT count(*) INTO v_n FROM perfiles WHERE id = v_intruso;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('D2 la temporal no le tapa la real al que la creó (%s filas): la demostración no prueba nada', v_n);
    END IF;

    -- D3
    v_es := public.es_admin();
    IF v_es IS DISTINCT FROM false THEN
      v_fallas := v_fallas || format('D3 con una tabla temporal «perfiles» un usuario sin perfil es admin: es_admin() dio %s (la función leyó la temporal, no public.perfiles)', v_es);
    END IF;

    -- D4
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    v_es := public.es_admin();
    IF v_es IS DISTINCT FROM true THEN
      v_fallas := v_fallas || format('D4 el admin de la semilla, con la temporal en la sesión, no es admin: es_admin() dio %s (la función leyó la temporal)', v_es);
    END IF;

    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    DROP TABLE pg_temp.perfiles;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_t = PG_EXCEPTION_CONTEXT;
    v_fallas := v_fallas || format('el ensayo cortó: %s %s (%s)', SQLSTATE, SQLERRM, left(v_t, 400));
  END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · B15: toda definer de public termina su search_path en pg_temp, y una tabla temporal del que llama ya no le tapa una de public (es_admin() con una «perfiles» temporal)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · % caso(s):\n  - %', cardinality(v_fallas), array_to_string(v_fallas, E'\n  - ');
END
$ensayo$;
