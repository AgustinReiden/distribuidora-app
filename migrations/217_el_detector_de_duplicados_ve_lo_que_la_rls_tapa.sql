-- Migración 217: el detector de duplicados ve lo que la RLS le tapa
--
-- Issue #543.
--
-- EL BUG. El detector de duplicados por ubicación de `createCliente` corría
-- COMO EL USUARIO, o sea pasando por la RLS de `clientes`. Un preventista no ve
-- los clientes asignados a OTRO preventista, así que el detector tampoco los
-- veía, no avisaba nada, y el preventista creaba un CLON del mismo cliente.
--
-- Es la misma forma de fail-open que la 214 documenta en
-- `cliente_preventistas_no_reservado` y `pedidos_cliente_reservado`: un guard
-- que consulta bajo la policy que justamente le tapa la fila no falla — APRUEBA.
-- Por eso esto es SECURITY DEFINER y no invoker.
--
-- VERIFICADO EN PROD ANTES DEL ARREGLO, impersonando: el cliente 22
-- (LOS PORTEÑOS, sucursal 1, asignado a Marcelo y Víctor) existe en esas
-- coordenadas exactas, y la consulta del detector con el JWT de Osvaldo
-- —preventista de la MISMA sucursal— devolvía 0 filas.
--
-- POR QUÉ IMPORTA MÁS AHORA. Cuando se escribió el detector la base era casi
-- toda huérfanos (401 vs 26 asignados, mig 028) y casi todo cliente era visible
-- para casi todo preventista. Hoy está dada vuelta: 598 asignados vs 124
-- huérfanos. La superficie del bug creció ~20x sin que nadie tocara ese código.
--
-- DEVUELVE UN BOOLEANO. Nunca la fila, nunca el nombre, nunca el id. Si
-- devolviera datos del cliente, el preventista los lee desde la consola del
-- navegador: sería filtrar por la ventana lo que la policy tapa por la puerta.
--
-- LO QUE SÍ SE REVELA, a sabiendas: que HAY alguien en esas coordenadas. No se
-- puede decir "no crees esto" sin admitir que hay algo ahí — es el piso del
-- problema, no una elección de implementación. Sondearlo pide el lat/long a 6
-- decimales (~0,2 m), o sea estar parado en la puerta.
--
-- EL DETECTOR POR RAZÓN SOCIAL SE DEJA CIEGO, deliberadamente. Ahí el mismo
-- booleano sería fácil de sondear —se prueban nombres— y se decidió que el
-- intercambio no vale. O sea: el clon por nombre contra un cliente de otro
-- preventista se sigue pudiendo crear, y es una decisión tomada, no un olvido.
--
-- EL FRONT NO DUPLICA EL PREDICADO DE LA RLS. La consulta vieja (la que pasa
-- por RLS) se conserva y va PRIMERO; esta RPC se llama sólo si aquella no
-- encontró nada. Entonces:
--   * lo ve     → mensaje de siempre, con nombre, y con el camino de
--                 reactivación si está inactivo. Sin cambios.
--   * no lo ve  → mensaje genérico, sin identidad.
-- Así esta función nunca tiene que contestar "¿este usuario puede verlo?", que
-- es lo que obligaría a copiar `mt_clientes_select` acá dentro y a mantener las
-- dos sincronizadas para siempre.
--
-- MIRA A LOS INACTIVOS A PROPÓSITO, igual que el detector viejo. El incidente
-- que originó las migs 199/200 fue exactamente una deduplicación —crear el
-- nuevo, desactivar el viejo— que partió un historial al medio. Si el de esa
-- esquina está desactivado, lo que corresponde es reactivarlo. No "arreglar"
-- esto agregando `activo = true`.
--
-- RESERVADO_ADMIN (mig 214): cae solo en la rama de "no lo ve", así que bloquea
-- el clon sin delatar que el cliente está reservado — que es justo el que más
-- interesa que no se clone.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. El detector, que ve por encima de la RLS
-- ---------------------------------------------------------------------------
-- VOLATILE (el default), no STABLE: además de responder, notifica.
--
-- Acotada a `current_sucursal_id()` como lo estaba la consulta vieja por vía de
-- la RLS. Sin eso, un preventista sondearía coordenadas de OTRA sucursal, que
-- es más de lo que el detector necesita y más de lo que hoy puede.

CREATE OR REPLACE FUNCTION public.existe_cliente_en_ubicacion(
  p_latitud numeric,
  p_longitud numeric
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  -- Misma tolerancia que el detector del front: ~0,2 m (6 decimales).
  c_tolerancia constant numeric := 0.000002;
  v_uid uuid := auth.uid();
  v_sucursal bigint := current_sucursal_id();
  v_cliente record;
  v_quien text;
BEGIN
  IF p_latitud IS NULL OR p_longitud IS NULL THEN
    RETURN false;
  END IF;

  -- Fail-closed: sin sesión o sin sucursal activa no se contesta "no hay
  -- duplicado", que dejaría crear el clon. El front ya corta antes por su
  -- cuenta si no hay sucursal; esto es el cinturón.
  IF v_uid IS NULL OR v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo verificar duplicados: sin sesión o sin sucursal activa'
      USING ERRCODE = '42501';
  END IF;

  SELECT c.id, COALESCE(c.nombre_fantasia, c.razon_social) AS nombre
    INTO v_cliente
    FROM clientes c
   WHERE c.sucursal_id = v_sucursal
     AND c.latitud  BETWEEN p_latitud  - c_tolerancia AND p_latitud  + c_tolerancia
     AND c.longitud BETWEEN p_longitud - c_tolerancia AND p_longitud + c_tolerancia
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- ---- Aviso a administración -------------------------------------------
  -- El preventista recibe un mensaje sin identidad; el admin recibe el nombre
  -- y el id, porque los ve igual y sin eso el aviso no le sirve para nada.
  --
  -- Sólo se avisa si el que pregunta es preventista (`perfiles.rol` CRUDO:
  -- es_preventista() devuelve true también para admin y encargado). Para los
  -- demás roles la RLS no tapa nada, así que si llegaron hasta acá no hay
  -- ningún conflicto de visibilidad que contar.
  IF EXISTS (SELECT 1 FROM perfiles p WHERE p.id = v_uid AND p.rol = 'preventista') THEN
    -- Dedupe: el alta se reintenta, y sin esto cada intento deja una fila por
    -- cada admin y encargado de la sucursal. Una campanita que grita 20 veces
    -- lo mismo se deja de mirar, que es la forma de que el aviso no exista.
    IF NOT EXISTS (
      SELECT 1 FROM notificaciones n
       WHERE n.tipo = 'cliente_duplicado_oculto'
         AND n.entidad_id = v_cliente.id
         AND n.created_at > now() - interval '1 day'
    ) THEN
      SELECT p.nombre INTO v_quien FROM perfiles p WHERE p.id = v_uid;

      PERFORM _notificar_sucursal_roles(
        v_sucursal,
        v_uid,
        'cliente_duplicado_oculto',
        'Alta de cliente bloqueada por duplicado',
        COALESCE(v_quien, 'Un preventista')
          || ' intentó cargar un cliente en la dirección de "'
          || COALESCE(v_cliente.nombre, 'sin nombre')
          || '" (#' || v_cliente.id || '), que no tiene en su cartera. Se bloqueó el alta. '
          || 'Puede ser el mismo comercio: si corresponde, asignáselo.',
        'cliente',
        v_cliente.id,
        jsonb_build_object(
          'preventista_id', v_uid,
          'latitud', p_latitud,
          'longitud', p_longitud
        )
      );
    END IF;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.existe_cliente_en_ubicacion(numeric, numeric) IS
  'Issue #543. ¿Hay un cliente en estas coordenadas (~0,2 m) dentro de la '
  'sucursal activa? SECURITY DEFINER a propósito: como invoker la RLS le tapa '
  'los clientes de otros preventistas, el EXISTS da false y el guard deja pasar '
  'el clon (fail-open). Devuelve un booleano y nada más: la identidad del '
  'cliente no puede volver al que pregunta. Incluye inactivos a propósito '
  '(migs 199/200). Avisa a admin y encargado cuando el que pregunta es '
  'preventista.';

-- ---------------------------------------------------------------------------
-- 2. ACL
-- ---------------------------------------------------------------------------
-- Toda función nueva de `public` nace con EXECUTE para PUBLIC (la entrada
-- `=X/postgres` sin grantee) y Supabase le concede `anon` por separado: hay que
-- revocar las DOS mitades acá, en la misma migración. Es lo que la 212 se
-- olvidó y la 213 tuvo que venir a cerrar.
--
-- Una función SECURITY DEFINER que ve TODOS los clientes de una sucursal y que
-- pueda llamar cualquiera es un agujero peor que el bug que vino a arreglar.
-- Sin sesión `auth.uid()` es NULL y la función tira, pero el REVOKE es el que
-- vale: el gate de CI (scripts/check-permisos.mjs) falla ante cualquier función
-- alcanzable con la anon key.

REVOKE ALL ON FUNCTION public.existe_cliente_en_ubicacion(numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.existe_cliente_en_ubicacion(numeric, numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Verificación de ACL (gate de CI: scripts/check-permisos.mjs)
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'existe_cliente_en_ubicacion';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'existe_cliente_en_ubicacion quedo con ACL default (PUBLIC ejecuta)';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'existe_cliente_en_ubicacion quedo ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'existe_cliente_en_ubicacion quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'existe_cliente_en_ubicacion no quedo ejecutable por authenticated: %', v_acl;
  END IF;
END
$verif$;

COMMIT;
