-- =========================================================================
-- NNN · EL search_path DE TODA FUNCIÓN SECURITY DEFINER DE public TERMINA EN
--       pg_temp (plan #1603, ola 2, tarjeta B15: 1564-b8 y 1564-g4)
--
-- Ensayo: scripts/test-search-path-ola2-1603.sql. Gate: scripts/check-search-path.mjs.
-- Se aplica en LF. Va AL FINAL de la ola: un CREATE OR REPLACE posterior que no
-- escriba el SET lo pierde (eso lo ve el gate, no esta migración).
--
-- El problema
-- -----------
-- Cuando `pg_temp` no está escrito en el search_path, Postgres busca PRIMERO
-- en el esquema temporal de la sesión las tablas, vistas, secuencias y tipos
-- (no las funciones ni los operadores). Una función SECURITY DEFINER corre con
-- los permisos de su dueño (postgres) y casi todas tienen
-- `SET search_path TO 'public'`: quien la llama puede crear una tabla temporal
-- con el nombre de una tabla de public que la función nombra sin esquema, y la
-- función lee (o escribe) la temporal. Ejemplo real (el ensayo lo reproduce):
-- un `authenticated` con una sesión SQL crea `perfiles` temporal con su uuid y
-- rol 'admin', y `es_admin()` le da true. Por la API (PostgREST) no se pueden
-- crear tablas temporales, así que hace falta una sesión SQL: el riesgo es
-- bajo, pero la puerta está abierta. Con `pg_temp` escrito AL FINAL, se busca
-- último y la temporal no tapa nada.
--
-- Qué hace
-- --------
-- A cada SECURITY DEFINER de public le agrega `pg_temp` al final de su
-- search_path de hoy, conservando lo que tiene (`public` queda
-- `public, pg_temp`; `public, pg_catalog` queda `public, pg_catalog, pg_temp`).
-- La que ya lo tiene al final no se toca; la que lo tiene en otro lugar, se
-- mueve al final. Al 18/11 (conc-base:530): 355 definer, 345 con `public`,
-- 7 con `public, pg_catalog` y 3 que ya terminan en pg_temp → cambian 352.
--
-- Por qué un DO que recorre el catálogo y no una lista de 352 ALTER
-- ----------------------------------------------------------------
-- Hay sesiones en paralelo que crean y reemplazan funciones: una lista escrita
-- hoy dejaría afuera la que nazca mañana y abortaría por una que ya no exista.
-- El DO toma las que haya al aplicar y reaplicarlo no cambia nada (todas ya
-- terminan en pg_temp: 0 cambios). Lo que se puede revisar a mano queda en las
-- premisas: aborta (sin cambiar nada) ante una definer sin search_path o con
-- uno que no sabe releer, y la poscondición compara la foto de antes y después.
--
-- Qué NO cambia (premisa y poscondición): el cuerpo (`md5(prosrc)`), los
-- permisos (`proacl`), `prosecdef`, la volatilidad, el dueño y toda otra clave
-- de `proconfig` de TODAS las funciones de public; y el `proconfig` entero de
-- las que no cambian (las INVOKER y las que ya terminaban en pg_temp).
--
-- Locks: `ALTER FUNCTION … SET` no toma locks de tabla ni espera a quien está
-- ejecutando la función: reescribe la fila de pg_proc. Una llamada en curso
-- termina con el search_path con el que empezó; las siguientes toman el nuevo
-- después del COMMIT. Si otra sesión reemplaza la misma función a la vez, la
-- migración falla con «tuple concurrently updated» y se reintenta entera.
--
-- Lo único que se apoya en una tabla temporal a propósito es guardar_combo
-- (`CREATE TEMP TABLE IF NOT EXISTS _combo_resuelto … ON COMMIT DROP`), y en
-- public no hay nada que se llame así: se sigue encontrando en pg_temp.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $b15$
DECLARE
  -- Un search_path "termina en pg_temp" si su último elemento es pg_temp. Es la
  -- misma regla de scripts/check-search-path.mjs (scripts/lib/catalogo.mjs).
  c_termina CONSTANT text := '^search_path=(.*, )?pg_temp$';
  -- Cada elemento, como lo guarda Postgres: un identificador sin comillas o uno
  -- entre comillas sin comas ni comillas adentro. Otra cosa no se relee.
  c_elemento CONSTANT text := '^([a-z_][a-z0-9_$]*|"[^",]+")$';
  r record;
  v_elems text[];
  v_previo jsonb := '{}'::jsonb;
  v_malas text;
  v_definer int;
  v_ya int := 0;
  v_movidas int := 0;
  v_cambiadas int := 0;
  v_fijo_antes text;
  v_fijo_despues text;
  v_quietas_antes text;
  v_quietas_despues text;
BEGIN
  -- -------------------------------------------------------------------------
  -- Premisas
  -- -------------------------------------------------------------------------
  -- 1 · Toda definer de public tiene search_path. Una sin él usa el del que
  --     llama: elegirle uno puede cambiarle lo que lee, y eso se decide a mano.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_malas
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%');
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · definer sin search_path (revisar a mano, no se cambió nada): %', v_malas;
  END IF;

  -- 2 · Cada search_path se sabe releer elemento por elemento.
  SELECT string_agg(DISTINCT p.oid::regprocedure::text || ' [' || c || ']', ', ') INTO v_malas
    FROM pg_proc p, unnest(p.proconfig) c
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef AND c LIKE 'search_path=%'
     AND EXISTS (SELECT 1 FROM unnest(string_to_array(substr(c, 13), ', ')) e WHERE e !~ c_elemento);
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · search_path que no se sabe releer (revisar a mano, no se cambió nada): %', v_malas;
  END IF;

  -- 3 · La foto: lo que NO puede cambiar en ninguna función de public (cuerpo,
  --     permisos, definer, volatilidad, dueño y las otras claves de proconfig),
  --     y el proconfig entero de las que no se tocan.
  SELECT md5(string_agg(concat_ws('/', p.oid, md5(p.prosrc), p.proacl::text, p.prosecdef, p.provolatile, p.proowner,
                                  (SELECT string_agg(c, ',' ORDER BY c) FROM unnest(p.proconfig) c WHERE c NOT LIKE 'search_path=%')),
                        '|' ORDER BY p.oid))
    INTO v_fijo_antes
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace;
  SELECT md5(string_agg(p.oid || '=' || coalesce(p.proconfig::text, ''), '|' ORDER BY p.oid))
    INTO v_quietas_antes
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND NOT (p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c ~ c_termina));

  -- -------------------------------------------------------------------------
  -- El cambio: pg_temp al final, conservando lo demás y su orden.
  -- -------------------------------------------------------------------------
  FOR r IN
    SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args, substr(c, 13) AS sp
      FROM pg_proc p, unnest(p.proconfig) c
     WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef AND c LIKE 'search_path=%'
     ORDER BY p.oid
  LOOP
    v_elems := string_to_array(r.sp, ', ');
    IF v_elems[cardinality(v_elems)] = 'pg_temp' THEN
      v_ya := v_ya + 1;
      CONTINUE;
    END IF;
    IF 'pg_temp' = ANY (v_elems) THEN
      v_movidas := v_movidas + 1;
    END IF;
    v_elems := array_remove(v_elems, 'pg_temp') || 'pg_temp'::text;
    v_previo := v_previo || jsonb_build_object(r.oid::text, r.sp);
    EXECUTE format('ALTER FUNCTION public.%I(%s) SET search_path = %s', r.proname, r.args, array_to_string(v_elems, ', '));
    v_cambiadas := v_cambiadas + 1;
  END LOOP;

  SELECT count(*) INTO v_definer FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef;
  RAISE NOTICE 'mig NNN · % SECURITY DEFINER en public: % ya terminaban en pg_temp, % cambiaron (% lo tenían en otro lugar y se movió al final)',
    v_definer, v_ya, v_cambiadas, v_movidas;

  -- -------------------------------------------------------------------------
  -- Poscondición
  -- -------------------------------------------------------------------------
  SELECT md5(string_agg(concat_ws('/', p.oid, md5(p.prosrc), p.proacl::text, p.prosecdef, p.provolatile, p.proowner,
                                  (SELECT string_agg(c, ',' ORDER BY c) FROM unnest(p.proconfig) c WHERE c NOT LIKE 'search_path=%')),
                        '|' ORDER BY p.oid))
    INTO v_fijo_despues
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace;
  IF v_fijo_despues IS DISTINCT FROM v_fijo_antes THEN
    RAISE EXCEPTION 'mig NNN · cambió algo más que el search_path (cuerpo, permisos, definer, volatilidad, dueño u otra clave de proconfig)';
  END IF;

  SELECT md5(string_agg(p.oid || '=' || coalesce(p.proconfig::text, ''), '|' ORDER BY p.oid))
    INTO v_quietas_despues
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND NOT (p.oid::text = ANY (ARRAY(SELECT jsonb_object_keys(v_previo))));
  IF v_quietas_despues IS DISTINCT FROM v_quietas_antes THEN
    RAISE EXCEPTION 'mig NNN · cambió el proconfig de una función que no había que tocar';
  END IF;

  -- Cada una que cambió: su search_path de antes, sin pg_temp, y pg_temp al final.
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_malas
    FROM pg_proc p
    JOIN jsonb_each_text(v_previo) prev(oid, sp) ON prev.oid::oid = p.oid
   WHERE (SELECT array_agg(substr(c, 13)) FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')
         IS DISTINCT FROM ARRAY[array_to_string(array_remove(string_to_array(prev.sp, ', '), 'pg_temp') || 'pg_temp'::text, ', ')];
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · el search_path no quedó como el de antes con pg_temp al final: %', v_malas;
  END IF;
END
$b15$;

DO $post$
DECLARE
  v_malas text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_malas
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c ~ '^search_path=(.*, )?pg_temp$');
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · quedaron definer cuyo search_path no termina en pg_temp: %', v_malas;
  END IF;
END
$post$;

COMMIT;
