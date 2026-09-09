-- Que `perfiles.activo` bloquee de verdad
--
-- EL BUG
-- ------
-- El checkbox "Usuario activo" de ModalUsuario.tsx no impedia nada. Verificado
-- por tres lados en prod:
--
--   1. Ninguna policy RLS menciona `activo` (pg_policy filtrado por activo +
--      perfil: cero filas).
--   2. `es_preventista()` decide por `rol IN ('admin','preventista','encargado')`
--      y nunca lo mira. Idem `es_admin()` y `es_transportista()`.
--   3. El login no lo consulta: en useAuth.tsx `activo` aparece solo como campo
--      del tipo Perfil.
--
-- O sea que un admin podia destildar la casilla creyendo que sacaba a alguien,
-- verlo en rojo en el panel, y esa persona seguia cargando pedidos con
-- normalidad. Una UI que promete un candado que no cierra es peor que no tener
-- el candado: nadie va a buscar el problema donde cree que ya lo resolvio.
--
-- POR QUE NO SE ARREGLA METIENDO `AND activo` EN LOS HELPERS
-- ---------------------------------------------------------
-- Seria lo obvio y es el peor camino disponible:
--
--   - `es_preventista()` NO significa "es preventista": devuelve true tambien
--     para admin, encargado y para quien tenga el rol extra en `perfil_roles`.
--     Un CREATE OR REPLACE descuidado de ese helper revierte el multi-rol en
--     silencio, y lo cubren decenas de policies.
--   - Seria autorizacion, no autenticacion: el usuario igual entra a la app,
--     igual tiene sesion valida, y recien rebota contra cada policy. Media app
--     rota en vez de una puerta cerrada.
--   - Habria que tocar los tres helpers y acordarse del cuarto que se agregue
--     manana. Un candado que hay que recordar poner en cada lugar nuevo ya
--     nacio roto.
--
-- LO QUE SI SE HACE
-- -----------------
-- `activo` pasa a manejar `auth.users.banned_until`, que es el mecanismo NATIVO
-- de GoTrue: el endpoint /token lo chequea ANTES de validar el hash de la
-- contraseña y devuelve 400 user_banned. No depende de que nuestro codigo se
-- acuerde de nada, no se puede esquivar por otro camino de datos, y cubre por
-- igual la web, el replay offline y cualquier cliente futuro.
--
-- Desactivar ademas purga sesiones, refresh tokens y tokens de recuperacion
-- pendientes. Sin eso el bloqueo seria a medias: `banned_until` corta el login
-- nuevo, pero una sesion ya abierta sigue renovandose sola, y un link de
-- "olvide mi contraseña" sin usar en la casilla del usuario le devuelve la
-- cuenta cuando quiera.
--
-- Es reversible y no destructivo: reactivar limpia el ban. No se borra el
-- usuario ni su historial, que es justamente por lo que la baja es logica.
--
-- LOS DOS GUARDS
-- --------------
-- Hacer que el flag muerda de verdad crea un modo de falla que antes no existia
-- (antes no hacia nada, mal podia dejar a alguien afuera), asi que nacen con el:
--
--   1. Un admin no puede desactivarse a si mismo. Un click distraido en su
--      propia fila lo dejaba afuera de su propia app.
--   2. No se puede desactivar al ultimo admin activo. Sin admin no queda nadie
--      que pueda reactivar a nadie, y la unica salida es SQL a mano contra prod.
--
-- `prevenir_autoescalada_perfil()` (trigger ya existente) sigue cubriendo lo
-- suyo: un no-admin no puede cambiar `rol` ni `activo` de nadie, ni de si mismo.
-- Estos guards son para el admin, que si puede.

-- ---------------------------------------------------------------------------
-- 1. Guards
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.perfiles_guard_desactivacion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_admins_activos INT;
BEGIN
  -- Solo interesa la transicion activo -> inactivo.
  IF COALESCE(NEW.activo, true) OR NOT COALESCE(OLD.activo, true) THEN
    RETURN NEW;
  END IF;

  -- auth.uid() es NULL cuando corre una migracion o un job con service_role;
  -- ahi no hay "si mismo" que proteger y el backfill de abajo tiene que pasar.
  IF auth.uid() IS NOT NULL AND NEW.id = auth.uid() THEN
    RAISE EXCEPTION 'No podes desactivar tu propio usuario: quedarias afuera de la app.';
  END IF;

  IF COALESCE(OLD.rol, '') = 'admin' THEN
    SELECT count(*) INTO v_admins_activos
    FROM public.perfiles
    WHERE rol = 'admin' AND COALESCE(activo, true) AND id <> NEW.id;

    IF v_admins_activos = 0 THEN
      RAISE EXCEPTION 'No podes desactivar al ultimo administrador activo: nadie podria reactivarlo despues.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.perfiles_guard_desactivacion() FROM PUBLIC, anon;

DROP TRIGGER IF EXISTS trg_perfiles_guard_desactivacion ON public.perfiles;
CREATE TRIGGER trg_perfiles_guard_desactivacion
  BEFORE UPDATE OF activo ON public.perfiles
  FOR EACH ROW
  WHEN (COALESCE(NEW.activo, true) IS DISTINCT FROM COALESCE(OLD.activo, true))
  EXECUTE FUNCTION public.perfiles_guard_desactivacion();

-- ---------------------------------------------------------------------------
-- 2. Sincronizacion con auth
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.perfiles_sync_acceso_auth()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF COALESCE(NEW.activo, true) THEN
    -- Reactivar: se levanta el ban. Las sesiones no se restauran (no se puede
    -- ni corresponde): el usuario vuelve a loguearse con su contraseña.
    UPDATE auth.users
       SET banned_until = NULL,
           updated_at   = now()
     WHERE id = NEW.id;
  ELSE
    -- Desactivar. La fecha lejana en vez de 'infinity' es a proposito: GoTrue
    -- parsea este campo con el time.Time de Go, que no tiene infinito.
    UPDATE auth.users
       SET banned_until = '2099-12-31 00:00:00+00'::timestamptz,
           updated_at   = now()
     WHERE id = NEW.id;

    -- Cortar todo acceso vivo. El orden importa: refresh_tokens antes que
    -- sessions por la FK entre ambas.
    DELETE FROM auth.refresh_tokens  WHERE user_id = NEW.id::text;
    DELETE FROM auth.sessions        WHERE user_id = NEW.id;
    DELETE FROM auth.one_time_tokens WHERE user_id = NEW.id;
  END IF;

  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.perfiles_sync_acceso_auth() FROM PUBLIC, anon;

DROP TRIGGER IF EXISTS trg_perfiles_sync_acceso_auth ON public.perfiles;
CREATE TRIGGER trg_perfiles_sync_acceso_auth
  AFTER UPDATE OF activo ON public.perfiles
  FOR EACH ROW
  WHEN (COALESCE(NEW.activo, true) IS DISTINCT FROM COALESCE(OLD.activo, true))
  EXECUTE FUNCTION public.perfiles_sync_acceso_auth();

-- ---------------------------------------------------------------------------
-- 3. Backfill
-- ---------------------------------------------------------------------------
-- Los perfiles que hoy estan en false quedaron marcados cuando el flag no hacia
-- nada, asi que hay que alinearlos a mano: el trigger solo mira transiciones.
--
-- La direccion contraria NO se toca. Un `activo = true` con `banned_until`
-- puesto se deja como esta: ese ban pudo ponerse por otra razon y a mano, y
-- levantarlo aca seria abrirle la puerta a alguien sin que nadie lo haya pedido.

UPDATE auth.users u
   SET banned_until = '2099-12-31 00:00:00+00'::timestamptz,
       updated_at   = now()
  FROM public.perfiles p
 WHERE p.id = u.id
   AND p.activo IS FALSE
   AND u.banned_until IS NULL;

DELETE FROM auth.refresh_tokens r
 USING public.perfiles p
 WHERE p.id::text = r.user_id AND p.activo IS FALSE;

DELETE FROM auth.sessions s
 USING public.perfiles p
 WHERE p.id = s.user_id AND p.activo IS FALSE;

DELETE FROM auth.one_time_tokens t
 USING public.perfiles p
 WHERE p.id = t.user_id AND p.activo IS FALSE;

COMMENT ON FUNCTION public.perfiles_sync_acceso_auth() IS
  'Sincroniza perfiles.activo con auth.users.banned_until y purga sesiones al desactivar. Es lo que hace que la baja logica de un usuario bloquee el login de verdad; sin esto el flag es puramente cosmetico. Ver migracion 206.';

COMMENT ON FUNCTION public.perfiles_guard_desactivacion() IS
  'Impide que un admin se desactive a si mismo o desactive al ultimo admin activo, escenarios que dejan la app sin administrador recuperable. Ver migracion 206.';
