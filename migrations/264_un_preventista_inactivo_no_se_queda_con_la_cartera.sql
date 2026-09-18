-- 264 — Desactivar un preventista le suelta la cartera
--
-- Un cliente con filas en `cliente_preventistas` lo ven SOLO esos preventistas
-- (politica `mt_clientes_select`); sin filas, lo ven todos (mig 028). Nada
-- limpiaba esas filas al poner `perfiles.activo = false`, asi que la cartera del
-- preventista dado de baja quedaba reservada para un usuario que ya no entra: los
-- clientes desaparecian para el reemplazo y para todos los demas.
--
-- Y era invisible desde la app: el checklist de la ficha se llena con
-- `fetchPreventistas`, que filtra `activo = true`, asi que la asignacion colgada
-- no se renderizaba y el cliente figuraba "sin preventista" estando asignado.
--
-- Paso en Taco Pozo: Juan de baja con 43 clientes todavia a su nombre, Nicolas
-- recien creado sin ver ninguno.
--
-- La baja es logica y reversible, pero la cartera no vuelve sola al reactivarlo:
-- una asignacion es una decision comercial, no un atributo del perfil. Soltarla es
-- el default seguro —el cliente vuelve al pool visible—; volver a cerrarla es un
-- acto explicito desde la ficha.

CREATE OR REPLACE FUNCTION public.soltar_cartera_preventista_inactivo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.cliente_preventistas
  WHERE preventista_id = NEW.id;
  RETURN NULL;
END;
$$;

-- Funcion de trigger: la invoca el executor como parte del DML, no el caller.
-- No necesita EXECUTE para nadie.
REVOKE ALL ON FUNCTION public.soltar_cartera_preventista_inactivo() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_soltar_cartera_preventista_inactivo ON public.perfiles;

CREATE TRIGGER trg_soltar_cartera_preventista_inactivo
  AFTER UPDATE OF activo ON public.perfiles
  FOR EACH ROW
  WHEN (OLD.activo IS DISTINCT FROM NEW.activo AND NEW.activo = false)
  EXECUTE FUNCTION public.soltar_cartera_preventista_inactivo();

-- Limpieza de lo ya colgado: toda asignacion a un perfil inactivo hoy.
DELETE FROM public.cliente_preventistas cp
USING public.perfiles p
WHERE p.id = cp.preventista_id
  AND p.activo = false;
