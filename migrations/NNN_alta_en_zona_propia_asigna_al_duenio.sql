-- =========================================================================
-- NNN · EL ALTA EN ZONA PROPIA ASIGNA AL DUEÑO EN EL MISMO INSERT
--       (auditoría de lo ajeno al núcleo del 12/11: VAR-03 de #1553)
--
-- Cambia una línea de `clientes_alta_asigna_duenio` y crea un trigger de
-- server sobre `cliente_preventistas`, con premisa de md5 sobre el cuerpo vivo
-- leído el 12/11 y poscondición de md5, ACL y definer.
-- Ensayo: scripts/test-alta-en-zona-propia-1553.sql. Se aplica en LF.
--
-- QUÉ PASABA
-- ----------
-- La zona manda la asignación (mig 359): el alta de un cliente en una zona con
-- dueño lo asigna al dueño (`trg_clientes_alta_asigna_duenio`, 416). Pero el
-- trigger se salteaba el alta que hace el propio dueño: lo dejaba para la app,
-- que se asigna en un segundo pedido (`sincronizarPreventistas`). Si ese
-- segundo pedido se cortaba, el cliente quedaba sin asignar —visible para todos
-- los preventistas— y ASG-A pasaba de 0 a 1. Al reintentar, el alta creaba
-- otro cliente.
--
-- POR QUÉ SE SALTEABA
-- -------------------
-- Lo dice la 416: un bundle viejo del PWA (anterior al 29/10) arma la
-- asignación con `DELETE` de todas las filas del cliente y un `INSERT` pelado.
-- El preventista no tiene DELETE en `cliente_preventistas` (`cp_delete` es de
-- admin), así que el DELETE no borra nada, y si el trigger ya había puesto la
-- fila el INSERT da 23505 y el alta se ve fallada. El bundle de hoy lee las
-- filas antes y no reinserta la que ya está (y además tolera el 23505).
--
-- QUÉ CAMBIA
-- ----------
-- 1 · `clientes_alta_asigna_duenio` asigna al dueño siempre, también cuando el
--     dueño es quien da de alta. La fila la pone `_asignar_clientes_a` desde el
--     trigger (depth 2: `cliente_preventistas_no_ajeno` no la mira, como en el
--     alta de un admin o de un encargado).
-- 2 · Para que el bundle viejo siga andando, un `INSERT` en
--     `cliente_preventistas` de una fila que ya existe no hace nada y no falla
--     (`trg_cliente_preventistas_ya_asignado`, BEFORE INSERT que devuelve NULL).
--     Es el último BEFORE INSERT por nombre, así que las guardas
--     (`_no_ajeno`, `_no_reservado`) corren antes igual. Es INVOKER: lee la fila
--     con la RLS de quien inserta (`cp_select`, la sucursal activa), así que un
--     admin con un cliente de otra sucursal sigue chocando con `cp_insert` y no
--     aprende si la asignación existe. No escribe nada ni toca la auditoría
--     (`audit_cliente_preventistas` no ve una fila que no entró).
--
-- Los demás caminos no cambian: el alta de un admin o un encargado en zona con
-- dueño (ya asignaba), la zona sin dueño (queda sin asignar), el reservado (el
-- trigger no corre por su WHEN y `_asignar_clientes_a` lo excluye), el
-- preventista en zona ajena (lo frena `clientes_alta_en_zona_propia`, que no se
-- toca) y el cambio de zona (`clientes_zona_asigna_duenio`, que no se toca).
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

-- ---------------------------------------------------------------------------
-- Premisa: el cuerpo vivo es el leído el 12/11, y lo nuevo no existe
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v text;
BEGIN
  SELECT md5(prosrc) INTO v FROM pg_proc
   WHERE oid = 'public.clientes_alta_asigna_duenio()'::regprocedure;
  IF v IS DISTINCT FROM 'af4cbfa8507ed445bbc31357ccf6406a' THEN
    RAISE EXCEPTION 'mig NNN · clientes_alta_asigna_duenio cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', v;
  END IF;

  IF to_regprocedure('public.cliente_preventistas_ya_asignado()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · cliente_preventistas_ya_asignado ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · El alta asigna al dueño aunque el dueño sea quien da de alta
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.clientes_alta_asigna_duenio()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_duenio uuid;
BEGIN
  v_duenio := _duenio_zona(NEW.zona_id);
  -- También cuando el dueño es quien da de alta (#1553): el segundo pedido de
  -- la app puede no llegar. El INSERT repetido de un bundle viejo lo absorbe
  -- trg_cliente_preventistas_ya_asignado.
  IF v_duenio IS NOT NULL THEN
    PERFORM _asignar_clientes_a(ARRAY[NEW.id], v_duenio);
  END IF;
  RETURN NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · Reinsertar una asignación que ya existe no hace nada
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.cliente_preventistas_ya_asignado()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- INVOKER a propósito: ve la fila con la RLS de quien inserta (#1553).
  IF EXISTS (SELECT 1 FROM cliente_preventistas cp
              WHERE cp.cliente_id = NEW.cliente_id
                AND cp.preventista_id = NEW.preventista_id) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.cliente_preventistas_ya_asignado() FROM PUBLIC, anon, authenticated;

-- El nombre importa: los BEFORE de una tabla corren por orden alfabético, y éste
-- tiene que ir después de _no_ajeno y _no_reservado.
CREATE TRIGGER trg_cliente_preventistas_ya_asignado
  BEFORE INSERT ON public.cliente_preventistas
  FOR EACH ROW
  EXECUTE FUNCTION public.cliente_preventistas_ya_asignado();

-- ---------------------------------------------------------------------------
-- Poscondición: md5, ACL y definer de lo que quedó, y el orden de los BEFORE
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v_ultimo text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.clientes_alta_asigna_duenio()', '6c7cb48a2ba5f19094d03f680c5316c4', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.cliente_preventistas_ya_asignado()', 'fdd191f8449d758e16c22afb8f23f86b', false,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  SELECT max(tgname) INTO v_ultimo
    FROM pg_trigger
   WHERE tgrelid = 'public.cliente_preventistas'::regclass
     AND NOT tgisinternal
     AND (tgtype & 2) <> 0   -- BEFORE
     AND (tgtype & 4) <> 0;  -- INSERT
  IF v_ultimo IS DISTINCT FROM 'trg_cliente_preventistas_ya_asignado' THEN
    RAISE EXCEPTION 'mig NNN · el último BEFORE INSERT de cliente_preventistas es %, no el que absorbe el repetido', v_ultimo;
  END IF;
END
$post$;

COMMIT;
