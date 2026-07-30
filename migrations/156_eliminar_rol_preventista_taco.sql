-- =========================================================================
-- 156_eliminar_rol_preventista_taco.sql
--
-- Elimina el rol `preventista_taco` (agregado por la mig 050, propagado por
-- la 055). Tiene 0 usuarios en produccion y arrastraba un bug: `menuGroups`
-- en TopNavigation.tsx nunca lo listo en ningun `roles[]`, asi que un usuario
-- con ese rol veia el menu COMPLETAMENTE VACIO -- ni siquiera Pedidos.
--
-- El rol era "preventista que no ve plata": su unica diferencia funcional con
-- `preventista` era ocultar montos, saldos e historial de compras. Ese caso de
-- uso, si vuelve a hacer falta, hoy se modela como capacidad en `perfil_roles`
-- (mig 155) y no como un rol compuesto nuevo -- que es justamente el motivo por
-- el que se creo esa tabla.
--
-- QUE HACE
--   1. Guarda: aborta si algun perfil todavia tiene el rol.
--   2. Achica el CHECK `perfiles_rol_check`.
--   3. Barre el literal de TODA funcion de `public` que lo mencione.
--   4. Barre el literal de TODA policy de `public` que lo mencione.
--   5. Verifica que no quede ni un rastro; si queda, aborta.
--
-- POR QUE ES DINAMICA (no hardcodea cuerpos)
--   `migrations/` es una vista curada y NO es 1:1 con produccion (ver
--   MANIFEST.md). Los cuerpos de `crear_pedido_completo`,
--   `actualizar_pedido_items`, `registrar_visita_cliente` y
--   `obtener_geolocalizacion_preventistas` que estan en la mig 055 fueron
--   superados despues por las migs 096, 101, 102, 117, 123, 129, 132 y 140;
--   y `es_preventista()` fue redefinida out-of-band por la mig 155
--   (`perfil_roles`), que NO esta versionada en este repo.
--
--   Copiar cualquiera de esos cuerpos desde los archivos del repo REVERTIRIA
--   logica viva -- incluido el multi-rol por sucursal. Por eso esta migracion
--   lee la definicion viva de cada objeto desde el catalogo
--   (`pg_get_functiondef` / `pg_get_expr`), le saca unicamente el literal
--   `'preventista_taco'` y la vuelve a crear. El resto del cuerpo se preserva
--   caracter por caracter, sea cual sea.
--
--   Corolario: `perfil_roles` y `es_transportista()` no se tocan. La unica
--   forma en que esta migracion toca `es_preventista()` es borrandole el
--   literal muerto; si hoy consulta `perfil_roles`, lo sigue haciendo igual.
--
-- SEGURIDAD DEL BARRIDO
--   Los reemplazos solo contemplan el literal como elemento de una lista
--   (`IN (...)` / `= ANY (ARRAY[...])`), que es la unica forma en que aparece.
--   Si en produccion existiera bajo otra forma (por ejemplo
--   `rol = 'preventista_taco'`), el paso 5 aborta la transaccion en vez de
--   dejar el objeto a medio limpiar.
--
-- NOTA sobre el bot de Telegram: `bot_usuarios_rol_check` (mig 014) y el tipo
-- `BotRol` nunca incluyeron este rol, por lo que un preventista_taco jamas
-- pudo vincular Telegram. Al eliminar el rol esa inconsistencia desaparece
-- sola y no hay nada que migrar ahi.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Guarda: el rol no puede estar en uso
-- -------------------------------------------------------------------------

DO $guard$
DECLARE
  v_n integer;
BEGIN
  SELECT count(*) INTO v_n FROM public.perfiles WHERE rol = 'preventista_taco';
  IF v_n > 0 THEN
    RAISE EXCEPTION
      'Hay % perfil(es) con rol preventista_taco. Reasignalos a preventista antes de correr esta migracion.', v_n;
  END IF;
END
$guard$;

-- -------------------------------------------------------------------------
-- 2. CHECK perfiles_rol_check: se reconstruye desde la definicion viva
-- -------------------------------------------------------------------------

DO $chk$
DECLARE
  v_def text;
  v_new text;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_def
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
   WHERE n.nspname = 'public' AND t.relname = 'perfiles' AND c.conname = 'perfiles_rol_check';

  IF v_def IS NULL THEN
    RAISE NOTICE 'perfiles_rol_check no existe; nada que achicar';
    RETURN;
  END IF;

  IF position('preventista_taco' in v_def) = 0 THEN
    RAISE NOTICE 'perfiles_rol_check ya estaba limpio';
    RETURN;
  END IF;

  v_new := regexp_replace(v_def, '\s*,\s*''preventista_taco''(::text)?', '', 'g');
  v_new := regexp_replace(v_new, '''preventista_taco''(::text)?\s*,\s*', '', 'g');

  IF position('preventista_taco' in v_new) > 0 THEN
    RAISE EXCEPTION 'No se pudo limpiar el literal de perfiles_rol_check: %', v_new;
  END IF;

  EXECUTE 'ALTER TABLE public.perfiles DROP CONSTRAINT perfiles_rol_check';
  EXECUTE 'ALTER TABLE public.perfiles ADD CONSTRAINT perfiles_rol_check ' || v_new;
  RAISE NOTICE 'perfiles_rol_check achicado: %', v_new;
END
$chk$;

-- -------------------------------------------------------------------------
-- 3. Funciones: se recrean con su cuerpo vivo menos el literal
--
--    Alcanza (entre otras) a es_preventista(), crear_pedido_completo(),
--    crear_pedido_completo_bot(), actualizar_pedido_items(),
--    registrar_visita_cliente() y obtener_geolocalizacion_preventistas(),
--    sea cual sea la version que hoy este viva en produccion.
-- -------------------------------------------------------------------------

DO $fns$
DECLARE
  v_oids oid[];
  v_oid  oid;
  v_def  text;
  v_new  text;
  v_n    integer := 0;
BEGIN
  -- Se materializa la lista ANTES de tocar nada: el loop modifica pg_proc.
  SELECT array_agg(p.oid ORDER BY p.proname) INTO v_oids
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind IN ('f', 'p')
     AND p.prosrc LIKE '%preventista_taco%';

  IF v_oids IS NULL THEN
    RAISE NOTICE 'No hay funciones que mencionen el rol';
    RETURN;
  END IF;

  FOREACH v_oid IN ARRAY v_oids LOOP
    v_def := pg_get_functiondef(v_oid);

    v_new := regexp_replace(v_def, '\s*,\s*''preventista_taco''(::text)?', '', 'g');
    v_new := regexp_replace(v_new, '''preventista_taco''(::text)?\s*,\s*', '', 'g');

    IF position('preventista_taco' in v_new) > 0 THEN
      RAISE EXCEPTION
        'No se pudo limpiar el literal de %: aparece fuera de una lista. Revisala a mano.',
        v_oid::regprocedure;
    END IF;

    EXECUTE v_new;
    v_n := v_n + 1;
    RAISE NOTICE 'Funcion limpiada: %', v_oid::regprocedure;
  END LOOP;

  RAISE NOTICE 'Funciones limpiadas: %', v_n;
END
$fns$;

-- -------------------------------------------------------------------------
-- 4. Policies: se recrean con su expresion viva menos el literal
--
--    En el repo la unica afectada es `mt_clientes_select` sobre `clientes`
--    (mig 055), pero el barrido es generico por si produccion derivo.
-- -------------------------------------------------------------------------

DO $pols$
DECLARE
  v_oids   oid[];
  v_oid    oid;
  r        record;
  v_qual   text;
  v_check  text;
  v_roles  text;
  v_cmd    text;
  v_sql    text;
  v_n      integer := 0;
BEGIN
  -- Se materializa la lista ANTES de tocar nada: el loop modifica pg_policy.
  SELECT array_agg(pol.oid ORDER BY pol.polname) INTO v_oids
    FROM pg_policy pol
    JOIN pg_class c     ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND (COALESCE(pg_get_expr(pol.polqual, pol.polrelid), '')      LIKE '%preventista_taco%'
       OR COALESCE(pg_get_expr(pol.polwithcheck, pol.polrelid), '') LIKE '%preventista_taco%');

  IF v_oids IS NULL THEN
    RAISE NOTICE 'No hay policies que mencionen el rol';
    RETURN;
  END IF;

  FOREACH v_oid IN ARRAY v_oids LOOP
    SELECT pol.polname,
           pol.polcmd,
           pol.polpermissive,
           pol.polroles,
           n.nspname,
           c.relname,
           pg_get_expr(pol.polqual, pol.polrelid)      AS qual,
           pg_get_expr(pol.polwithcheck, pol.polrelid) AS withcheck
      INTO r
      FROM pg_policy pol
      JOIN pg_class c     ON c.oid = pol.polrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE pol.oid = v_oid;

    v_qual  := r.qual;
    v_check := r.withcheck;

    v_qual := regexp_replace(v_qual, '\s*,\s*''preventista_taco''(::text)?', '', 'g');
    v_qual := regexp_replace(v_qual, '''preventista_taco''(::text)?\s*,\s*', '', 'g');
    v_check := regexp_replace(v_check, '\s*,\s*''preventista_taco''(::text)?', '', 'g');
    v_check := regexp_replace(v_check, '''preventista_taco''(::text)?\s*,\s*', '', 'g');

    IF position('preventista_taco' in COALESCE(v_qual, '')) > 0
       OR position('preventista_taco' in COALESCE(v_check, '')) > 0 THEN
      RAISE EXCEPTION
        'No se pudo limpiar el literal de la policy % sobre %.%. Revisala a mano.',
        r.polname, r.nspname, r.relname;
    END IF;

    v_cmd := CASE r.polcmd
               WHEN 'r' THEN 'SELECT'
               WHEN 'a' THEN 'INSERT'
               WHEN 'w' THEN 'UPDATE'
               WHEN 'd' THEN 'DELETE'
               ELSE 'ALL'
             END;

    -- polroles = {0} significa PUBLIC
    IF r.polroles = '{0}'::oid[] THEN
      v_roles := 'PUBLIC';
    ELSE
      SELECT string_agg(quote_ident(rolname), ', ')
        INTO v_roles
        FROM pg_roles
       WHERE oid = ANY (r.polroles);
    END IF;

    v_sql := format('CREATE POLICY %I ON %I.%I AS %s FOR %s TO %s',
                    r.polname, r.nspname, r.relname,
                    CASE WHEN r.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
                    v_cmd, COALESCE(v_roles, 'PUBLIC'));

    IF v_qual IS NOT NULL THEN
      v_sql := v_sql || format(' USING (%s)', v_qual);
    END IF;
    IF v_check IS NOT NULL THEN
      v_sql := v_sql || format(' WITH CHECK (%s)', v_check);
    END IF;

    EXECUTE format('DROP POLICY %I ON %I.%I', r.polname, r.nspname, r.relname);
    EXECUTE v_sql;
    v_n := v_n + 1;
    RAISE NOTICE 'Policy limpiada: % sobre %.%', r.polname, r.nspname, r.relname;
  END LOOP;

  RAISE NOTICE 'Policies limpiadas: %', v_n;
END
$pols$;

-- -------------------------------------------------------------------------
-- 5. Verificacion final: no debe quedar ni un rastro
-- -------------------------------------------------------------------------

DO $verify$
DECLARE
  v_fns   integer;
  v_pols  integer;
  v_chk   integer;
  v_rows  integer;
BEGIN
  SELECT count(*) INTO v_fns
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prosrc LIKE '%preventista_taco%';

  SELECT count(*) INTO v_pols
    FROM pg_policy pol JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND (COALESCE(pg_get_expr(pol.polqual, pol.polrelid), '')      LIKE '%preventista_taco%'
       OR COALESCE(pg_get_expr(pol.polwithcheck, pol.polrelid), '') LIKE '%preventista_taco%');

  SELECT count(*) INTO v_chk
    FROM pg_constraint c JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
   WHERE n.nspname = 'public' AND pg_get_constraintdef(c.oid) LIKE '%preventista_taco%';

  SELECT count(*) INTO v_rows FROM public.perfiles WHERE rol = 'preventista_taco';

  IF v_fns > 0 OR v_pols > 0 OR v_chk > 0 OR v_rows > 0 THEN
    RAISE EXCEPTION
      'Quedaron rastros de preventista_taco: % funcion(es), % policy(s), % constraint(s), % fila(s)',
      v_fns, v_pols, v_chk, v_rows;
  END IF;

  RAISE NOTICE 'OK: el rol preventista_taco fue eliminado por completo';
END
$verify$;

COMMIT;
