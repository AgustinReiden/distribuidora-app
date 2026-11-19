-- =========================================================================
-- NNN · TODA FUNCIÓN DE public QUE FIJA search_path LO TERMINA EN pg_temp
--       (plan #1603, ola 2, tarjeta B15 v2: 1564-b8 y 1564-g4)
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
-- Y no alcanza con las definer: una INVOKER con su propio
-- `SET search_path = public` que llama una definer (o que dispara como trigger
-- del DML de una definer) corre como postgres y su SET vuelve a poner pg_temp
-- primero (el ensayo también lo reproduce: «admin como postgres»). Por eso la
-- regla es para TODA función que fije search_path.
--
-- Qué hace
-- --------
-- A cada función de public que fija search_path (definer o no, de trigger o
-- no) le agrega `pg_temp` al final, conservando lo que tiene: `public` queda
-- `public, pg_temp`; `public, pg_catalog` queda `public, pg_catalog, pg_temp`;
-- el vacío (`''`, todo calificado) queda `pg_temp` (pg_catalog sigue primero,
-- implícito). La que ya lo tiene una sola vez y al final no se toca; la que lo
-- tiene en otro lugar, o repetido (`pg_temp, public, pg_temp`: Postgres usa la
-- PRIMERA aparición), queda con uno solo, al final. Vale igual para un
-- procedimiento (`ALTER ROUTINE`). Las que NO fijan search_path no se tocan: heredan
-- el de quien las llama, y dentro de una definer es el de la definer (las SQL
-- sin SET, como `_cliente_visible`, son así a propósito: para que se inlineen).
-- Al 18/11 (conc-base:530), 607 funciones fijan search_path:
--   definer 355: `public` 345, `public, pg_catalog` 7, `public, pg_temp` 3;
--   invoker 252: `public` 239 (52 de trigger), `public, pg_catalog` 5, `''` 1,
--                `public, pg_temp` 7.
-- Cambian 597 (352 definer y 245 invoker).
--
-- Por qué un DO que recorre el catálogo y no una lista de 597 ALTER
-- ----------------------------------------------------------------
-- Hay sesiones en paralelo que crean y reemplazan funciones: una lista escrita
-- hoy dejaría afuera la que nazca mañana y abortaría por una que ya no exista.
-- El DO toma las que haya al aplicar y reaplicarlo no cambia nada (todas ya
-- terminan en pg_temp: 0 cambios). Lo que se puede revisar a mano queda en las
-- premisas: aborta (sin cambiar nada) ante una DEFINER sin search_path, ante
-- un search_path que no sabe releer o ante una que hay que cambiar y cuyo dueño
-- no es quien aplica (la nombra), y la poscondición compara la foto de antes y
-- después.
--
-- Qué NO cambia (premisa y poscondición): el cuerpo (`md5(prosrc)`), los
-- permisos (`proacl`), `prosecdef`, la volatilidad, el dueño y toda otra clave
-- de `proconfig` de TODAS las funciones de public; y el `proconfig` entero de
-- las que no cambian (las que no fijan search_path y las que ya terminaban en
-- pg_temp). Una SQL con SET ya no se inlineaba; agregar pg_temp no cambia eso.
--
-- Locks: `ALTER ROUTINE … SET` no toma locks de tabla ni espera a quien está
-- ejecutando la función: reescribe la fila de pg_proc (RowExclusiveLock sobre
-- pg_proc). Una llamada en curso termina con el search_path con el que empezó;
-- las siguientes toman el nuevo después del COMMIT. Si otra sesión reemplaza
-- la misma función a la vez, la migración falla con «tuple concurrently
-- updated» y se reintenta entera.
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
  -- Un search_path está bien si su último elemento es pg_temp y no lo tiene antes
  -- (Postgres usa la primera aparición). Es la misma regla de
  -- scripts/check-search-path.mjs (scripts/lib/catalogo.mjs).
  c_termina CONSTANT text := '^search_path=(.*, )?pg_temp$';
  c_otro_pg_temp CONSTANT text := '(=|, )pg_temp, ';
  -- Cada elemento, como lo guarda Postgres: un identificador sin comillas o uno
  -- entre comillas sin comas ni comillas adentro. El search_path vacío se guarda
  -- `""` (y sólo así: un elemento vacío no se puede escribir). Otra cosa no se relee.
  c_elemento CONSTANT text := '^([a-z_][a-z0-9_$]*|"[^",]+")$';
  r record;
  v_elems text[];
  v_previo jsonb := '{}'::jsonb;
  v_malas text;
  v_total int;
  v_ya int := 0;
  v_movidas int := 0;
  v_def int := 0;
  v_inv int := 0;
  v_fijo_antes text;
  v_fijo_despues text;
  v_quietas_antes text;
  v_quietas_despues text;
BEGIN
  -- -------------------------------------------------------------------------
  -- Premisas
  -- -------------------------------------------------------------------------
  -- 1 · Toda DEFINER de public tiene search_path. Una sin él usa el del que
  --     llama: elegirle uno puede cambiarle lo que lee, y eso se decide a mano.
  --     (Una INVOKER sin search_path no se toca: hereda el de quien la llama.)
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
   WHERE p.pronamespace = 'public'::regnamespace AND c LIKE 'search_path=%'
     AND substr(c, 13) <> '""'
     AND EXISTS (SELECT 1 FROM unnest(string_to_array(substr(c, 13), ', ')) e WHERE e !~ c_elemento);
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · search_path que no se sabe releer (revisar a mano, no se cambió nada): %', v_malas;
  END IF;

  -- 3 · Quien aplica puede cambiar cada una que hay que cambiar (ALTER pide ser su
  --     dueño o tener sus permisos): si no, se nombra en vez de abortar con
  --     «must be owner».
  SELECT string_agg(DISTINCT p.oid::regprocedure::text || ' (dueño ' || pg_get_userbyid(p.proowner) || ')', ', ') INTO v_malas
    FROM pg_proc p, unnest(p.proconfig) c
   WHERE p.pronamespace = 'public'::regnamespace AND c LIKE 'search_path=%'
     AND (c !~ c_termina OR c ~ c_otro_pg_temp)
     AND NOT pg_has_role(p.proowner, 'USAGE');
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · funciones a cambiar cuyo dueño no es % (revisar a mano, no se cambió nada): %', current_user, v_malas;
  END IF;

  -- 4 · La foto: lo que NO puede cambiar en ninguna función de public (cuerpo,
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
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c
                      WHERE c LIKE 'search_path=%' AND (c !~ c_termina OR c ~ c_otro_pg_temp));

  -- -------------------------------------------------------------------------
  -- El cambio: pg_temp al final, conservando lo demás y su orden.
  -- -------------------------------------------------------------------------
  FOR r IN
    SELECT p.oid, p.proname, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args, substr(c, 13) AS sp
      FROM pg_proc p, unnest(p.proconfig) c
     WHERE p.pronamespace = 'public'::regnamespace AND c LIKE 'search_path=%'
     ORDER BY p.oid
  LOOP
    v_elems := array_remove(string_to_array(r.sp, ', '), '""');
    IF v_elems[cardinality(v_elems)] = 'pg_temp' AND cardinality(array_positions(v_elems, 'pg_temp')) = 1 THEN
      v_ya := v_ya + 1;
      CONTINUE;
    END IF;
    IF 'pg_temp' = ANY (v_elems) THEN
      v_movidas := v_movidas + 1;
    END IF;
    v_elems := array_remove(v_elems, 'pg_temp') || 'pg_temp'::text;
    v_previo := v_previo || jsonb_build_object(r.oid::text, r.sp);
    -- ROUTINE: sirve para funciones y procedimientos.
    EXECUTE format('ALTER ROUTINE public.%I(%s) SET search_path = %s', r.proname, r.args, array_to_string(v_elems, ', '));
    IF r.prosecdef THEN v_def := v_def + 1; ELSE v_inv := v_inv + 1; END IF;
  END LOOP;

  SELECT count(*) INTO v_total
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%');
  RAISE NOTICE 'mig NNN · % funciones de public fijan search_path: % ya terminaban en pg_temp, % cambiaron (% definer, % invoker; % lo tenían en otro lugar o repetido y quedó uno, al final)',
    v_total, v_ya, v_def + v_inv, v_def, v_inv, v_movidas;

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

  -- Cada una que cambió: su search_path de antes, sin pg_temp (ni el vacío), y pg_temp al final.
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_malas
    FROM pg_proc p
    JOIN jsonb_each_text(v_previo) prev(oid, sp) ON prev.oid::oid = p.oid
   WHERE (SELECT array_agg(substr(c, 13)) FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%')
         IS DISTINCT FROM ARRAY[array_to_string(
           array_remove(array_remove(string_to_array(prev.sp, ', '), '""'), 'pg_temp') || 'pg_temp'::text, ', ')];
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · el search_path no quedó como el de antes con pg_temp al final: %', v_malas;
  END IF;
END
$b15$;

DO $post$
DECLARE
  v_malas text;
BEGIN
  -- Toda definer fija search_path, y toda función o procedimiento que lo fija lo
  -- termina en pg_temp, una sola vez.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_malas
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND (   (p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))
          OR EXISTS (SELECT 1 FROM unnest(p.proconfig) c
                      WHERE c LIKE 'search_path=%'
                        AND (c !~ '^search_path=(.*, )?pg_temp$' OR c ~ '(=|, )pg_temp, ')));
  IF v_malas IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · quedaron funciones cuyo search_path no termina en pg_temp (una sola vez): %', v_malas;
  END IF;
END
$post$;

COMMIT;
