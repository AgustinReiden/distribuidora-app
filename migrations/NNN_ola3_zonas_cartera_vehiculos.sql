-- =========================================================================
-- NNN · ZONAS, CARTERA, VEHÍCULOS Y TABLERO (ola 3 de #1603, tarjeta T9; #1554, #1522, #1690)
--
-- Ensayo: scripts/test-ola3-zonas-cartera-vehiculos.sql (falla sin esta migración en A1, A2,
-- A3, A5, B1, B2, C1, D1, E1, F1, F2, F3, F4, F6, F7, F8, F9, F10, F11, G1, G2 y G4; ENSAYO OK
-- con ella). Concurrencia: scripts/concurrencia/t9-zona-y-cliente.sh (dos sesiones; sin esta
-- migración el cliente que entra a la zona queda con el dueño de antes (Z1), la segunda
-- asignación da un 23505 crudo (Z2) y el cliente que se va queda con dos dueños (Z3)). Corrige
-- el caso D6 de test-cartera-chofer-y-asignacion-1182-1183.sql (el admin ya no le asigna un
-- cliente a un chofer) y el 8i de test-gastos-5.sql (la RPC ya no cambia el vendedor de un
-- entregado). Se aplica en LF, sobre la 548.
--
-- 1 · Var-B4 = permisos-B7 (decisión D12 del dueño, 25/11). Un cliente se asigna sólo a quien
--     actúa como preventista ACTIVO en la sucursal del cliente, también cuando lo hace el admin:
--     por REST (cliente_preventistas) o por guardar_cliente (INVOKER, pasa por el mismo trigger).
--     La rama es_admin() de cliente_preventistas_no_ajeno sólo miraba que fuera de la sucursal:
--     el admin le asignaba un cliente a un chofer, a un encargado o a un desactivado, y el cliente
--     desaparecía de la vista de los preventistas (ASG-B rojo). La regla es la de ASG-B, en un
--     helper de server: _preventista_activo_de_sucursal(usuario, sucursal) = activo, de la
--     sucursal y _actua_como_preventista. El server (auth.uid() NULL) y la reasignación por zona
--     (pg_trigger_depth() > 1, y asignar_preventista_zona, que ya exige un preventista activo de
--     la sucursal) siguen igual. Lo que ya está asignado a quien no cumple no se toca: el
--     trigger mira sólo lo que se inserta o se cambia.
-- 2 · Var-B5. actualizar_preventista_pedido (el vendedor de un pedido, desde la edición, sólo
--     admin):
--     · el estado: la edición se abre en pendiente, en preparación y asignado (en camino), y el
--       selector se apaga en entregado; un cancelado no se edita. Ahora la RPC rechaza entregado
--       (la venta ya se reconoció con la entrega: comisión, metas y Rendimiento la cuentan, y
--       cambiarla de vendedor la mueve entre vendedores después de contada) y cancelado (no es
--       venta). El estado se mira con el pedido tomado (FOR UPDATE).
--     · el destino: activo, de la sucursal del pedido y, o un admin (el que carga el pedido; el
--       selector los ofrece hoy), o quien actúa como preventista activo en la sucursal (la regla
--       de D12, el mismo helper). Cambia: un chofer con el extra de preventista en la sucursal
--       ahora entra (antes no, por el rol base).
-- 3 · Var-B6. La patente es única por sucursal, sin mirar mayúsculas ni los espacios de los
--     bordes: el índice vehiculos_patente_por_sucursal (sucursal_id, upper(btrim(patente)))
--     reemplaza a vehiculos_patente_key UNIQUE (patente), que le decía a un admin si la patente
--     existía en otra sucursal. Ninguna FK apunta a esa clave (las de empleados, gastos y
--     vehiculo_km van a la pk y a (id, sucursal_id)). guardar_vehiculo no cambia: ya normaliza
--     la patente y su mensaje («Ya hay un vehículo con la patente …») sigue siendo cierto.
-- 4 · Var-B9. asignar_preventista_zona toma la zona (FOR UPDATE: choca con el KEY SHARE de la FK
--     del cliente que entra a la zona, así que el cambio de zona espera y su trigger ve el dueño
--     nuevo) y después los clientes de la zona por id (FOR NO KEY UPDATE: no frena las ventas),
--     antes de contar y de escribir; la simulación no toma nada. Un 23505 que quede (la carrera
--     que el lock ya no deja pasar) sale con un mensaje que se entiende.
-- 5 · Var-B11. tablero_cobertura con un período futuro daba avance_mes_pct negativo: el corte es
--     a lo sumo el día de hoy y a lo menos el anterior al inicio del período (avance 0).
-- 6 · GTO-5 y Var-B7. registrar_km_vehiculo rechaza una fecha posterior a hoy (día argentino),
--     la misma lectura dos veces (mismo vehículo, día y km) y los km que bajan: no puede marcar
--     menos que la lectura anterior por fecha ni más que la siguiente (las de otro día; las del
--     mismo día no se ordenan entre sí). Se compara con la vecina, no con todas: una lectura vieja
--     mal cargada traba sólo a sus vecinas y el mensaje dice cuál corregir. Toma el vehículo
--     (FOR NO KEY UPDATE) para que dos cargas a la vez no pasen las dos. La regla es una,
--     _km_lectura_fuera_de_serie (de server). RPC nueva corregir_lectura_km(id, fecha, km, borrar):
--     admin o encargado de la sucursal de la lectura (la activa); sólo las manuales (la de una
--     carga se corrige editando su gasto, la del GPS no se toca); la corrección pasa por las
--     mismas reglas, sin compararse consigo misma. Sin motivo: audit_vehiculo_km ya guarda el
--     antes, el después, quién y cuándo. Lo que ya está cargado no se toca.
-- 7 · Zonas con nombre único (decisión D13 del dueño, 25/11): único por sucursal según
--     upper(btrim(nombre)), como los rubros. El índice zonas_nombre_unico_por_sucursal reemplaza
--     a zonas_nombre_sucursal_unique (nombre, sucursal_id), y el trigger zonas_nombre_unico da el
--     mensaje con la zona que ya existe, sólo a quien pasa la policy de escritura (un admin en su
--     sucursal activa) o al server; a cualquier otro le devuelve la fila y lo frena la RLS (corre
--     antes que ella). Espejo en src/utils/nombreZona.ts.
--
-- PREMISAS DE DATOS (abortan con el motivo): ninguna patente repetida por sucursal según
-- upper(btrim()), ningún nombre de zona repetido por sucursal según upper(btrim()).
--
-- LOCKS: ACCESS EXCLUSIVE NOWAIT, al principio y de una vez, sobre vehiculos y zonas (CREATE
-- INDEX, DROP CONSTRAINT, CREATE TRIGGER). Los dos índices recorren su tabla una vez (13 zonas y
-- la flota de vehículos en prod).
--
-- No cambia firmas de las RPC que existen. Un bundle viejo del PWA sigue andando: el alta de
-- zona traduce cualquier 23505 a «La zona … ya existe», y los rechazos nuevos llegan como el
-- mensaje de un RAISE.
--
-- Revertir: volver las seis funciones a los cuerpos de las premisas, DROP de los dos triggers de
-- zonas y de zonas_nombre_unico(), corregir_lectura_km, _km_lectura_fuera_de_serie y
-- _preventista_activo_de_sucursal; DROP INDEX de los dos índices nuevos y volver a crear
-- vehiculos_patente_key UNIQUE (patente) y zonas_nombre_sucursal_unique UNIQUE (nombre,
-- sucursal_id) (si los datos lo permiten).
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

LOCK TABLE public.vehiculos, public.zonas IN ACCESS EXCLUSIVE MODE NOWAIT;

-- -------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de la 548, lo que se reemplaza existe y lo nuevo todavía no; datos.
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cliente_preventistas_no_ajeno()', '79501f926fd9b9e940bdb5acf94b14e4'),
    ('public.actualizar_preventista_pedido(bigint,uuid)', '43ac71d45f8d8a6a793b840b820da418'),
    ('public.asignar_preventista_zona(bigint,uuid,boolean)', '33e67d03deb887225dc13c27fd62955b'),
    ('public.tablero_cobertura(bigint,date)', 'c77e1688c6850c805997518be1358355'),
    ('public.registrar_km_vehiculo(bigint,date,integer)', 'a54019552ff04b4a875d6f0724fcac5a'),
    ('public._actua_como_preventista(uuid,bigint)', 'ef86cf93bcd7a2e03a05e35895b2bdf1')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public.corregir_lectura_km(bigint,date,integer,boolean)') IS NOT NULL
     OR to_regprocedure('public._km_lectura_fuera_de_serie(bigint,date,integer,bigint)') IS NOT NULL
     OR to_regprocedure('public._preventista_activo_de_sucursal(uuid,bigint)') IS NOT NULL
     OR to_regprocedure('public.zonas_nombre_unico()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · una de las funciones nuevas ya existe: rehacer sobre lo vigente';
  END IF;
  IF to_regclass('public.vehiculos_patente_por_sucursal') IS NOT NULL
     OR to_regclass('public.zonas_nombre_unico_por_sucursal') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · uno de los índices nuevos ya existe: rehacer sobre lo vigente';
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE (conrelid = 'public.vehiculos'::regclass AND conname = 'vehiculos_patente_key'
              AND pg_get_constraintdef(oid) = 'UNIQUE (patente)')
          OR (conrelid = 'public.zonas'::regclass AND conname = 'zonas_nombre_sucursal_unique'
              AND pg_get_constraintdef(oid) = 'UNIQUE (nombre, sucursal_id)')) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · vehiculos_patente_key o zonas_nombre_sucursal_unique no son los de la 548: rehacer sobre lo vigente';
  END IF;
  -- Ninguna FK usa los índices que se van.
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE contype = 'f'
                AND conindid IN ('public.vehiculos_patente_key'::regclass, 'public.zonas_nombre_sucursal_unique'::regclass)) THEN
    RAISE EXCEPTION 'mig NNN · una FK apunta a vehiculos_patente_key o a zonas_nombre_sucursal_unique';
  END IF;

  -- Datos: lo que el índice nuevo no dejaría crear, con el motivo.
  SELECT string_agg(format('sucursal %s: %s vehículos con la patente %s', sucursal_id, n, clave), '; ') INTO v
    FROM (SELECT sucursal_id, upper(btrim(patente)) AS clave, count(*) AS n
            FROM public.vehiculos GROUP BY 1, 2 HAVING count(*) > 1) d;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · hay patentes repetidas en una sucursal (%): resolverlas antes', v;
  END IF;
  SELECT string_agg(format('sucursal %s: %s zonas «%s»', sucursal_id, n, clave), '; ') INTO v
    FROM (SELECT sucursal_id, upper(btrim(nombre)) AS clave, count(*) AS n
            FROM public.zonas GROUP BY 1, 2 HAVING count(*) > 1) d;
  IF v IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · hay zonas con el mismo nombre en una sucursal (%): resolverlas antes', v;
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · D12: el helper y la rama del admin de cliente_preventistas_no_ajeno
-- -------------------------------------------------------------------------
CREATE FUNCTION public._preventista_activo_de_sucursal(p_usuario uuid, p_sucursal bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path = public, pg_temp
AS $function$
  -- La regla de ASG-B de auditoria_integridad() (#1316) y de D12: activo, de la sucursal y
  -- actúa como preventista en ella (rol base preventista o el extra de esa sucursal; ni admin
  -- ni encargado).
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles pf
     WHERE pf.id = p_usuario
       AND COALESCE(pf.activo, false)
       AND EXISTS (SELECT 1 FROM public.usuario_sucursales us
                    WHERE us.usuario_id = pf.id AND us.sucursal_id = p_sucursal)
       AND public._actua_como_preventista(pf.id, p_sucursal));
$function$;

REVOKE ALL ON FUNCTION public._preventista_activo_de_sucursal(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._preventista_activo_de_sucursal(uuid, bigint) TO service_role;

CREATE OR REPLACE FUNCTION public.cliente_preventistas_no_ajeno()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal bigint;
  v_cliente  text;
  v_duenos   text;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- Reasignación por zona (mig 359): la inserta un trigger, no el usuario. Va
  -- antes que el admin: un dueño de zona que dejó la sucursal no frena un cambio
  -- de zona.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- #1374: el admin elige a quién, pero entre los de la sucursal del cliente.
  -- cp_insert acota el cliente y no al preventista, y su segunda rama
  -- (preventista_id = auth.uid()) deja pasar a un admin con un cliente ajeno:
  -- esto cubre las dos. La FK de preventista_id va a perfiles, sin sucursal.
  IF es_admin() THEN
    IF NOT EXISTS (SELECT 1
                     FROM clientes c
                     JOIN usuario_sucursales us ON us.sucursal_id = c.sucursal_id
                    WHERE c.id = NEW.cliente_id
                      AND us.usuario_id = NEW.preventista_id) THEN
      RAISE EXCEPTION 'El preventista no es de la sucursal del cliente #%: no se le puede asignar.',
        NEW.cliente_id
        USING ERRCODE = '42501';
    END IF;
    -- D12 (Var-B4 = permisos-B7, mig NNN): y entre los que actúan como preventista activo en
    -- esa sucursal. Un chofer, un encargado o un desactivado dejaban al cliente sin nadie que lo
    -- atienda (fuera de la vista de los preventistas). Es la regla de ASG-B.
    SELECT c.sucursal_id INTO v_sucursal FROM clientes c WHERE c.id = NEW.cliente_id;
    -- El mensaje no nombra al usuario (el gate de mensajes de trigger): el admin sabe a quién eligió.
    IF NOT public._preventista_activo_de_sucursal(NEW.preventista_id, v_sucursal) THEN
      RAISE EXCEPTION 'No se le puede asignar el cliente #% a ese usuario: no actúa como preventista activo en la sucursal del cliente. Un chofer, un encargado o un usuario dado de baja dejaría al cliente sin nadie que lo atienda.',
        NEW.cliente_id
        USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
  END IF;

  SELECT c.sucursal_id, COALESCE(c.nombre_fantasia, c.razon_social)
    INTO v_sucursal, v_cliente
    FROM clientes c
   WHERE c.id = NEW.cliente_id;

  IF v_sucursal IS NULL OR v_sucursal IS DISTINCT FROM current_sucursal_id() THEN
    RAISE EXCEPTION 'El cliente #% no es de tu sucursal: no podés asignarle preventistas.',
      NEW.cliente_id
      USING ERRCODE = '42501';
  END IF;

  SELECT string_agg(pf.nombre, ', ' ORDER BY pf.nombre)
    INTO v_duenos
    FROM cliente_preventistas cp
    JOIN perfiles pf ON pf.id = cp.preventista_id
   WHERE cp.cliente_id = NEW.cliente_id
     AND cp.preventista_id IS DISTINCT FROM NEW.preventista_id;

  IF v_duenos IS NOT NULL THEN
    RAISE EXCEPTION 'Cliente asignado a otro preventista: % (#%) lo atiende %. No podés asignártelo.',
      COALESCE(v_cliente, '?'), NEW.cliente_id, v_duenos
      USING ERRCODE = '42501';
  END IF;

  IF NEW.preventista_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Solo un administrador puede asignarle un cliente a otro preventista.'
      USING ERRCODE = '42501';
  END IF;

  -- #1183: sólo tiene clientes asignados quien actúa como preventista en la
  -- sucursal del cliente (rol base preventista o el extra de esa sucursal; ni
  -- admin ni encargado). cp_insert sólo exige preventista_id = auth.uid(): sin
  -- esto un transportista se asignaba un huérfano por REST y lo sacaba de la
  -- vista de todos los preventistas. Admin, server (auth.uid() NULL) y la
  -- reasignación por zona (pg_trigger_depth() > 1) salen antes.
  IF NOT public._actua_como_preventista(NEW.preventista_id, v_sucursal) THEN
    RAISE EXCEPTION 'Sólo un preventista puede tener clientes asignados: no podés asignarte el cliente #%.',
      NEW.cliente_id
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$function$;

-- -------------------------------------------------------------------------
-- 2 · Var-B5: el estado del pedido y el destino
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_preventista_pedido(p_pedido_id bigint, p_nuevo_preventista_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_actor uuid := auth.uid();
  v_actor_role text;
  v_target_role text;
  v_sucursal bigint := current_sucursal_id();
  v_anterior uuid;
  v_estado text;
  -- 1559-b9: la versión de antes y la nueva.
  v_version_anterior timestamptz;
  v_version timestamptz;
BEGIN
  IF v_actor IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Sesion no autenticada');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT rol INTO v_actor_role FROM perfiles WHERE id = v_actor;
  IF v_actor_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede cambiar el preventista de un pedido');
  END IF;

  -- Var-B5 (mig NNN): el destino es un admin activo de la sucursal (el que carga el pedido) o
  -- quien actúa como preventista activo en ella (la regla de D12, _preventista_activo_de_sucursal).
  SELECT p.rol INTO v_target_role
  FROM perfiles p
  WHERE p.id = p_nuevo_preventista_id
    AND p.activo = true
    AND EXISTS (
      SELECT 1 FROM usuario_sucursales us
      WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal
    );
  IF v_target_role IS NULL
     OR (v_target_role IS DISTINCT FROM 'admin'
         AND NOT public._preventista_activo_de_sucursal(p_nuevo_preventista_id, v_sucursal)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El usuario elegido no es un preventista activo de la sucursal (ni un admin): no puede ser el vendedor del pedido');
  END IF;

  SELECT usuario_id, updated_at, estado INTO v_anterior, v_version_anterior, v_estado FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado en la sucursal');
  END IF;

  -- Var-B5 (mig NNN): sólo antes de la entrega, como la edición. Entregado, la venta ya se
  -- contó (comisión, metas, Rendimiento) para su vendedor; cancelado, no es venta.
  IF v_estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya fue entregado: el preventista no se puede cambiar (la venta ya se le contó al que la hizo)');
  END IF;
  IF v_estado NOT IN ('pendiente', 'en_preparacion', 'asignado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido está cancelado: el preventista no se puede cambiar');
  END IF;

  IF v_anterior IS NOT DISTINCT FROM p_nuevo_preventista_id THEN
    RETURN jsonb_build_object('success', true, 'sin_cambios', true,
                              'updated_at_anterior', v_version_anterior, 'updated_at', v_version_anterior);
  END IF;

  UPDATE pedidos
     SET usuario_id = p_nuevo_preventista_id,
         updated_at = now()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal
  RETURNING updated_at INTO v_version;

  INSERT INTO pedido_historial
    (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES
    (p_pedido_id, v_actor, 'usuario_id', v_anterior::text, p_nuevo_preventista_id::text, v_sucursal);

  -- 1559-b9 (#1559): la edición abierta adopta la versión nueva sólo si estaba parada en
  -- la de antes (versionTrasCambioPropio), como tras sustituir o dividir un regalo.
  RETURN jsonb_build_object('success', true, 'pedido_id', p_pedido_id, 'preventista_id', p_nuevo_preventista_id,
                            'updated_at_anterior', v_version_anterior, 'updated_at', v_version);
END;
$function$;

-- -------------------------------------------------------------------------
-- 3 · Var-B6: la patente, única por sucursal
-- -------------------------------------------------------------------------
CREATE UNIQUE INDEX vehiculos_patente_por_sucursal ON public.vehiculos (sucursal_id, upper(btrim(patente)));
ALTER TABLE public.vehiculos DROP CONSTRAINT vehiculos_patente_key;
COMMENT ON INDEX public.vehiculos_patente_por_sucursal IS
  'Var-B6 (mig NNN): la patente es única por sucursal, sin mirar mayúsculas ni los espacios de los bordes. La única en toda la base le decía a un admin si existía en otra sucursal.';

-- -------------------------------------------------------------------------
-- 4 · Var-B9: la zona y sus clientes, tomados antes de contar y de escribir
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.asignar_preventista_zona(p_zona_id bigint, p_preventista_id uuid, p_simular boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucursal  bigint;
  v_anterior  uuid;
  v_ids       bigint[];
  v_cambian   integer := 0;
  v_reserv    integer := 0;
  v_total     integer := 0;
  v_quitados  jsonb := '[]'::jsonb;
  v_zona      text;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Sólo un administrador puede asignar zonas a preventistas'
      USING ERRCODE = '42501';
  END IF;

  SELECT z.sucursal_id, z.nombre INTO v_sucursal, v_zona
    FROM zonas z
   WHERE z.id = p_zona_id
     AND z.sucursal_id = current_sucursal_id();
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'La zona % no existe en la sucursal activa', p_zona_id
      USING ERRCODE = 'P0002';
  END IF;

  IF p_preventista_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM perfiles p
       WHERE p.id = p_preventista_id AND p.rol = 'preventista' AND p.activo
    ) THEN
      RAISE EXCEPTION 'Sólo se le puede asignar una zona a un preventista activo'
        USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM usuario_sucursales us
       WHERE us.usuario_id = p_preventista_id AND us.sucursal_id = v_sucursal
    ) THEN
      RAISE EXCEPTION 'Ese preventista no trabaja en esta sucursal'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- Var-B9 (mig NNN): la zona y después sus clientes, por id, antes de contar y de escribir.
  -- La zona va FOR UPDATE a propósito: choca con el KEY SHARE de la FK de un cliente que entra a
  -- la zona, así que ese cambio espera a que esto confirme y su trigger
  -- (clientes_zona_asigna_duenio, AFTER, que corre después de la FK) ve el dueño nuevo; sin el
  -- lock quedaba con el de antes y fuera de v_ids. Los clientes van FOR NO KEY UPDATE: no chocan
  -- con el KEY SHARE de una venta. La simulación no toma nada.
  IF NOT p_simular THEN
    PERFORM 1 FROM zonas z WHERE z.id = p_zona_id FOR UPDATE;
    PERFORM 1 FROM clientes c WHERE c.zona_id = p_zona_id ORDER BY c.id FOR NO KEY UPDATE;
  END IF;

  SELECT pz.perfil_id INTO v_anterior
    FROM preventista_zonas pz WHERE pz.zona_id = p_zona_id;

  -- Todos los clientes de la zona, activos e inactivos.
  SELECT array_agg(c.id),
         count(*),
         count(*) FILTER (WHERE c.reservado_admin)
    INTO v_ids, v_total, v_reserv
    FROM clientes c
   WHERE c.zona_id = p_zona_id;

  IF p_preventista_id IS NOT NULL THEN
    SELECT count(*) INTO v_cambian
      FROM clientes c
     WHERE c.zona_id = p_zona_id
       AND NOT c.reservado_admin
       AND (
         NOT EXISTS (SELECT 1 FROM cliente_preventistas cp
                      WHERE cp.cliente_id = c.id AND cp.preventista_id = p_preventista_id)
         OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                     WHERE cp.cliente_id = c.id AND cp.preventista_id <> p_preventista_id)
       );

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'preventista_id', q.preventista_id,
             'nombre', q.nombre,
             'clientes', q.n) ORDER BY q.n DESC, q.nombre), '[]'::jsonb)
      INTO v_quitados
      FROM (
        SELECT cp.preventista_id, pf.nombre, count(*) AS n
          FROM clientes c
          JOIN cliente_preventistas cp ON cp.cliente_id = c.id
          JOIN perfiles pf ON pf.id = cp.preventista_id
         WHERE c.zona_id = p_zona_id
           AND NOT c.reservado_admin
           AND cp.preventista_id <> p_preventista_id
         GROUP BY cp.preventista_id, pf.nombre
      ) q;
  END IF;

  IF NOT p_simular THEN
    BEGIN
      DELETE FROM preventista_zonas WHERE zona_id = p_zona_id;
      IF p_preventista_id IS NOT NULL THEN
        INSERT INTO preventista_zonas (perfil_id, zona_id, sucursal_id)
        VALUES (p_preventista_id, p_zona_id, v_sucursal);
        IF v_ids IS NOT NULL THEN
          PERFORM _asignar_clientes_a(v_ids, p_preventista_id);
        END IF;
      END IF;
    EXCEPTION WHEN unique_violation THEN
      -- Var-B9 (mig NNN): con la zona tomada no debería pasar; si pasa, que se entienda.
      RAISE EXCEPTION 'Otro cambio de la zona «%» se guardó al mismo tiempo que éste: volvé a abrir las zonas y elegí el preventista de nuevo.',
        v_zona
        USING ERRCODE = '23505';
    END;
  END IF;

  RETURN jsonb_build_object(
    'duenio_anterior', v_anterior,
    'clientes_zona', v_total,
    'cambian', v_cambian,
    'reservados', v_reserv,
    'quitados', v_quitados,
    'simulado', p_simular
  );
END;
$function$;

-- -------------------------------------------------------------------------
-- 5 · Var-B11: el avance del mes de un período futuro es 0
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tablero_cobertura(p_sucursal_id bigint DEFAULT NULL::bigint, p_periodo date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_sucs bigint[] := _tablero_sucursales(p_sucursal_id);
  v_hoy  date := _tablero_hoy();
  v_ini  date := date_trunc('month', COALESCE(p_periodo, _tablero_hoy()))::date;
  v_fin  date;
  v_corte date;
  r jsonb;
BEGIN
  v_fin   := (v_ini + interval '1 month - 1 day')::date;
  -- Var-B11 (mig NNN): un período futuro todavía no empezó: el corte es el día anterior a su
  -- inicio y el avance da 0, no negativo.
  v_corte := GREATEST(LEAST(v_fin, v_hoy), v_ini - 1);

  WITH cli AS (
    SELECT c.id, c.zona_id FROM clientes c
     WHERE c.sucursal_id = ANY(v_sucs) AND COALESCE(c.activo, true) AND c.zona_id IS NOT NULL
  ),
  v AS (SELECT * FROM _tablero_ventas(v_sucs, v_ini, v_fin) WHERE zona_id IS NOT NULL),
  -- REP-D (#1545, D44): la facturación de la zona es neta de sus notas de crédito.
  vnc AS (SELECT n.zona_id, sum(n.monto) AS monto
            FROM public._ventas_nc(v_sucs, v_ini, v_fin) n
           WHERE n.zona_id IS NOT NULL GROUP BY n.zona_id),
  vis AS (
    SELECT DISTINCT vc.cliente_id FROM visitas_cliente vc
     WHERE vc.sucursal_id = ANY(v_sucs)
       AND (vc.created_at AT TIME ZONE 'America/Argentina/Tucuman')::date BETWEEN v_ini AND v_fin
  ),
  zs AS (
    SELECT z.id, z.nombre, z.sucursal_id, pf.nombre AS preventista,
           (SELECT count(*) FROM cli WHERE cli.zona_id = z.id) AS clientes,
           (SELECT count(DISTINCT v.cliente_id) FROM v JOIN cli ON cli.id = v.cliente_id WHERE cli.zona_id = z.id) AS compradores,
           (SELECT COALESCE(sum(v.total), 0) FROM v WHERE v.zona_id = z.id)
             - COALESCE((SELECT vnc.monto FROM vnc WHERE vnc.zona_id = z.id), 0) AS facturacion,
           (SELECT count(*) FROM vis JOIN cli ON cli.id = vis.cliente_id WHERE cli.zona_id = z.id) AS visitados,
           mt.objetivo_pct, mt.objetivo_clientes, mt.periodo AS objetivo_desde
      FROM zonas z
      LEFT JOIN preventista_zonas pz ON pz.zona_id = z.id
      LEFT JOIN perfiles pf ON pf.id = pz.perfil_id
      LEFT JOIN LATERAL (
        SELECT m.objetivo_pct, m.objetivo_clientes, m.periodo FROM metas_cobertura_zona m
         WHERE m.zona_id = z.id AND m.periodo <= v_ini ORDER BY m.periodo DESC LIMIT 1
      ) mt ON true
     WHERE z.sucursal_id = ANY(v_sucs) AND COALESCE(z.activo, true)
  ),
  calc AS (
    SELECT zs.*,
           CASE WHEN clientes > 0 THEN round(100.0 * compradores / clientes, 1) ELSE 0 END AS cobertura_pct,
           COALESCE(objetivo_clientes, CASE WHEN objetivo_pct IS NOT NULL THEN ceil(clientes * objetivo_pct / 100.0)::int END) AS meta_clientes
      FROM zs
  )
  SELECT jsonb_build_object(
    'periodo', v_ini, 'fin', v_fin, 'corte', v_corte,
    'avance_mes_pct', round(100.0 * (v_corte - v_ini + 1) / (v_fin - v_ini + 1), 1),
    'totales', jsonb_build_object(
       'clientes', COALESCE(sum(clientes), 0), 'compradores', COALESCE(sum(compradores), 0),
       'facturacion', COALESCE(sum(facturacion), 0),
       'cobertura_pct', CASE WHEN sum(clientes) > 0 THEN round(100.0 * sum(compradores) / sum(clientes), 1) ELSE 0 END,
       'meta_clientes', sum(meta_clientes)),
    'zonas', COALESCE(jsonb_agg(jsonb_build_object(
      'zona_id', id, 'zona', nombre, 'sucursal_id', sucursal_id, 'preventista', preventista,
      'clientes', clientes, 'compradores', compradores, 'visitados', visitados, 'facturacion', facturacion,
      'cobertura_pct', cobertura_pct, 'objetivo_pct', objetivo_pct, 'objetivo_clientes', objetivo_clientes,
      'objetivo_desde', objetivo_desde, 'meta_clientes', meta_clientes,
      'faltan', GREATEST(COALESCE(meta_clientes, 0) - compradores, 0),
      'estado', CASE WHEN meta_clientes IS NULL THEN 'sin_objetivo'
                     WHEN compradores >= meta_clientes THEN 'cumplido'
                     WHEN compradores >= 0.8 * meta_clientes THEN 'cerca'
                     ELSE 'lejos' END
    ) ORDER BY sucursal_id, nombre), '[]'::jsonb)
  ) INTO r FROM calc;
  RETURN r;
END;
$function$;

-- -------------------------------------------------------------------------
-- 6 · GTO-5 y Var-B7: la serie de km de un vehículo
-- -------------------------------------------------------------------------
CREATE FUNCTION public._km_lectura_fuera_de_serie(p_vehiculo_id bigint, p_fecha date, p_km integer, p_excepto bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v record;
BEGIN
  -- GTO-5 y Var-B7 (mig NNN): por qué una lectura de km no entra en la serie del vehículo, o
  -- NULL si entra. p_excepto es la lectura que se corrige (no se compara consigo misma). Se mira
  -- la vecina por fecha, no todas: una lectura vieja mal cargada traba sólo a las de al lado, y el
  -- mensaje dice cuál corregir. Las del mismo día no se ordenan entre sí.
  IF EXISTS (SELECT 1 FROM vehiculo_km k
              WHERE k.vehiculo_id = p_vehiculo_id AND k.fecha = p_fecha AND k.km = p_km
                AND k.id IS DISTINCT FROM p_excepto) THEN
    RETURN format('Esa lectura ya está cargada: el %s el vehículo marcaba %s km.',
                  to_char(p_fecha, 'DD/MM/YYYY'), replace(to_char(p_km, 'FM9,999,999'), ',', '.'));
  END IF;

  SELECT k.fecha, k.km INTO v
    FROM vehiculo_km k
   WHERE k.vehiculo_id = p_vehiculo_id AND k.fecha < p_fecha AND k.id IS DISTINCT FROM p_excepto
   ORDER BY k.fecha DESC, k.km DESC
   LIMIT 1;
  IF FOUND AND p_km < v.km THEN
    RETURN format('Los km no pueden bajar: el %s el vehículo marcaba %s km y esta lectura dice %s. Si aquella lectura está mal, corregila.',
                  to_char(v.fecha, 'DD/MM/YYYY'), replace(to_char(v.km, 'FM9,999,999'), ',', '.'),
                  replace(to_char(p_km, 'FM9,999,999'), ',', '.'));
  END IF;

  SELECT k.fecha, k.km INTO v
    FROM vehiculo_km k
   WHERE k.vehiculo_id = p_vehiculo_id AND k.fecha > p_fecha AND k.id IS DISTINCT FROM p_excepto
   ORDER BY k.fecha ASC, k.km ASC
   LIMIT 1;
  IF FOUND AND p_km > v.km THEN
    RETURN format('Los km no pueden bajar: el %s, después de esta fecha, el vehículo marcaba %s km y esta lectura dice %s. Si aquella lectura está mal, corregila.',
                  to_char(v.fecha, 'DD/MM/YYYY'), replace(to_char(v.km, 'FM9,999,999'), ',', '.'),
                  replace(to_char(p_km, 'FM9,999,999'), ',', '.'));
  END IF;

  RETURN NULL;
END
$function$;

REVOKE ALL ON FUNCTION public._km_lectura_fuera_de_serie(bigint, date, integer, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._km_lectura_fuera_de_serie(bigint, date, integer, bigint) TO service_role;

CREATE OR REPLACE FUNCTION public.registrar_km_vehiculo(p_vehiculo_id bigint, p_fecha date, p_km integer)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_suc bigint := public.current_sucursal_id();
  v_id  bigint;
  v_motivo text;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede registrar los km de un vehículo';
  END IF;
  IF v_suc IS NULL OR NOT EXISTS (SELECT 1 FROM vehiculos WHERE id = p_vehiculo_id AND sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'Ese vehículo no es de esta sucursal';
  END IF;
  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha de la lectura';
  END IF;
  -- GTO-5 (mig NNN): el día argentino, no el del servidor.
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha de la lectura (%) es posterior a hoy: no se cargan km a futuro', to_char(p_fecha, 'DD/MM/YYYY');
  END IF;
  IF p_km IS NULL OR p_km NOT BETWEEN 0 AND 9999999 THEN
    RAISE EXCEPTION 'Los km tienen que estar entre 0 y 9.999.999';
  END IF;

  -- GTO-5 y Var-B7 (mig NNN): el vehículo tomado, así dos cargas a la vez de la misma lectura no
  -- pasan las dos; después, la serie.
  PERFORM 1 FROM vehiculos WHERE id = p_vehiculo_id AND sucursal_id = v_suc FOR NO KEY UPDATE;
  v_motivo := public._km_lectura_fuera_de_serie(p_vehiculo_id, p_fecha, p_km, NULL);
  IF v_motivo IS NOT NULL THEN
    RAISE EXCEPTION '%', v_motivo;
  END IF;

  INSERT INTO vehiculo_km (sucursal_id, vehiculo_id, fecha, km, origen, creado_por)
  VALUES (v_suc, p_vehiculo_id, p_fecha, p_km, 'manual', auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END
$function$;

CREATE FUNCTION public.corregir_lectura_km(p_lectura_id bigint, p_fecha date, p_km integer, p_borrar boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_suc bigint := public.current_sucursal_id();
  v_veh bigint;
  v_l   vehiculo_km%ROWTYPE;
  v_motivo text;
BEGIN
  -- GTO-5 (mig NNN): corregir o borrar una lectura de km cargada a mano. Admin o encargado de la
  -- sucursal de la lectura (la activa). audit_vehiculo_km guarda el antes, el después y quién.
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o un encargado puede corregir una lectura de km';
  END IF;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT k.vehiculo_id INTO v_veh FROM vehiculo_km k WHERE k.id = p_lectura_id AND k.sucursal_id = v_suc;
  IF v_veh IS NULL THEN
    RAISE EXCEPTION 'Esa lectura de km no es de esta sucursal';
  END IF;

  -- El vehículo y después la lectura, como registrar_km_vehiculo.
  PERFORM 1 FROM vehiculos WHERE id = v_veh AND sucursal_id = v_suc FOR NO KEY UPDATE;
  SELECT * INTO v_l FROM vehiculo_km k WHERE k.id = p_lectura_id AND k.sucursal_id = v_suc FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Esa lectura de km ya no existe: la borró otro';
  END IF;
  IF v_l.origen = 'carga' THEN
    RAISE EXCEPTION 'Esa lectura sale de la carga de combustible del gasto #%: se corrige editando ese gasto', v_l.gasto_id;
  END IF;
  IF v_l.origen IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'Esa lectura viene del GPS: no se corrige a mano';
  END IF;

  IF COALESCE(p_borrar, false) THEN
    DELETE FROM vehiculo_km WHERE id = p_lectura_id;
    RETURN p_lectura_id;
  END IF;

  IF p_fecha IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha de la lectura';
  END IF;
  IF p_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha de la lectura (%) es posterior a hoy: no se cargan km a futuro', to_char(p_fecha, 'DD/MM/YYYY');
  END IF;
  IF p_km IS NULL OR p_km NOT BETWEEN 0 AND 9999999 THEN
    RAISE EXCEPTION 'Los km tienen que estar entre 0 y 9.999.999';
  END IF;
  IF p_fecha = v_l.fecha AND p_km = v_l.km THEN
    RETURN p_lectura_id;
  END IF;
  v_motivo := public._km_lectura_fuera_de_serie(v_veh, p_fecha, p_km, p_lectura_id);
  IF v_motivo IS NOT NULL THEN
    RAISE EXCEPTION '%', v_motivo;
  END IF;

  UPDATE vehiculo_km SET fecha = p_fecha, km = p_km WHERE id = p_lectura_id;
  RETURN p_lectura_id;
END
$function$;

REVOKE ALL ON FUNCTION public.corregir_lectura_km(bigint, date, integer, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.corregir_lectura_km(bigint, date, integer, boolean) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 7 · D13: el nombre de una zona, único por sucursal sin mirar mayúsculas ni espacios
-- -------------------------------------------------------------------------
CREATE UNIQUE INDEX zonas_nombre_unico_por_sucursal ON public.zonas (sucursal_id, upper(btrim(nombre)));
ALTER TABLE public.zonas DROP CONSTRAINT zonas_nombre_sucursal_unique;
COMMENT ON INDEX public.zonas_nombre_unico_por_sucursal IS
  'D13 (mig NNN): el nombre de una zona es único por sucursal sin mirar mayúsculas ni los espacios de los bordes, como los rubros. El mensaje con la zona que ya existe lo da zonas_nombre_unico().';

CREATE FUNCTION public.zonas_nombre_unico()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_otra record;
BEGIN
  -- D13 (mig NNN): el índice zonas_nombre_unico_por_sucursal lo asegura; esto da el mensaje
  -- con la zona que ya existe. Corre ANTES que la RLS: nombra la zona sólo a quien pasa la
  -- policy de escritura (mt_zonas_insert / mt_zonas_update: es_admin() en su sucursal activa) o
  -- al server (sin usuario). A cualquier otro le devuelve la fila y lo frena la RLS con su
  -- 42501, sin decirle qué zonas hay en otra sucursal. COALESCE: con un x-sucursal-id ajeno
  -- current_sucursal_id() da NULL (#1488).
  IF NOT COALESCE(auth.uid() IS NULL OR (es_admin() AND NEW.sucursal_id = current_sucursal_id()), false) THEN
    RETURN NEW;
  END IF;

  SELECT z.id, z.nombre, z.activo INTO v_otra
    FROM zonas z
   WHERE z.sucursal_id = NEW.sucursal_id
     AND upper(btrim(z.nombre)) = upper(btrim(NEW.nombre))
     AND z.id <> NEW.id
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION 'Ya existe la zona «%» en esta sucursal%: es el mismo nombre que «%» (no se distinguen mayúsculas ni espacios). Usá esa zona o elegí otro nombre.',
      v_otra.nombre,
      CASE WHEN COALESCE(v_otra.activo, true) THEN '' ELSE ' (desactivada)' END,
      btrim(NEW.nombre)
      USING ERRCODE = '23505';
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.zonas_nombre_unico() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.zonas_nombre_unico() TO service_role;

CREATE TRIGGER trg_zonas_nombre_unico
  BEFORE INSERT ON public.zonas
  FOR EACH ROW EXECUTE FUNCTION public.zonas_nombre_unico();
CREATE TRIGGER trg_zonas_nombre_unico_upd
  BEFORE UPDATE OF nombre, sucursal_id ON public.zonas
  FOR EACH ROW
  WHEN (OLD.nombre IS DISTINCT FROM NEW.nombre OR OLD.sucursal_id IS DISTINCT FROM NEW.sucursal_id)
  EXECUTE FUNCTION public.zonas_nombre_unico();

-- -------------------------------------------------------------------------
-- Poscondición: cuerpos, definer, search_path y EXECUTE como en el repo; índices y triggers.
-- -------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cliente_preventistas_no_ajeno()', '3af296dfdb1e03b10d291ed9fa5bd3ef',
     '{postgres=X/postgres,service_role=X/postgres}', true),
    ('public.actualizar_preventista_pedido(bigint,uuid)', '1fb8bd374b8b4c115ac9a244320f395b',
     '{authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres}', true),
    ('public.asignar_preventista_zona(bigint,uuid,boolean)', '4358c4f7f4944e87197475bc4b21f739',
     '{authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres}', true),
    ('public.tablero_cobertura(bigint,date)', '760b29e9d3fcabdf70b280129aa1f70b',
     '{postgres=X/postgres,service_role=X/postgres}', true),
    ('public.registrar_km_vehiculo(bigint,date,integer)', 'fee73cb33fb108f7039ba1203a3ed16d',
     '{authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres}', true),
    ('public.corregir_lectura_km(bigint,date,integer,boolean)', 'd2c940b7ef347c10c2920a0e69a1ed5f',
     '{authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres}', true),
    ('public._km_lectura_fuera_de_serie(bigint,date,integer,bigint)', '47d32ce80647c0c9480c2c4711237f02',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public._preventista_activo_de_sucursal(uuid,bigint)', 'f11ad54483683e654229df77abf2af39',
     '{postgres=X/postgres,service_role=X/postgres}', false),
    ('public.zonas_nombre_unico()', 'a1bf63e3ed176d9d4bfa981252f5227a',
     '{postgres=X/postgres,service_role=X/postgres}', true)
  ) AS v(fn, h, acl, def) LOOP
    -- Los EXECUTE, ordenados: el orden de las entradas depende de los privilegios por defecto.
    SELECT md5(prosrc) AS h, (SELECT array_agg(a::text ORDER BY a::text) FROM unnest(proacl) a)::text AS a,
           prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def
       OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
  END LOOP;

  SELECT indexdef INTO v FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'vehiculos_patente_por_sucursal';
  IF v IS DISTINCT FROM 'CREATE UNIQUE INDEX vehiculos_patente_por_sucursal ON public.vehiculos USING btree (sucursal_id, upper(btrim(patente)))' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: el índice de la patente quedó %', v;
  END IF;
  SELECT indexdef INTO v FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'zonas_nombre_unico_por_sucursal';
  IF v IS DISTINCT FROM 'CREATE UNIQUE INDEX zonas_nombre_unico_por_sucursal ON public.zonas USING btree (sucursal_id, upper(btrim((nombre)::text)))' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: el índice del nombre de zona quedó %', v;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conname IN ('vehiculos_patente_key', 'zonas_nombre_sucursal_unique')
                AND connamespace = 'public'::regnamespace) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: quedó una de las claves únicas viejas';
  END IF;
  IF (SELECT count(*) FROM pg_trigger
       WHERE tgrelid = 'public.zonas'::regclass AND NOT tgisinternal
         AND tgfoid = 'public.zonas_nombre_unico()'::regprocedure
         AND tgname IN ('trg_zonas_nombre_unico', 'trg_zonas_nombre_unico_upd')) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: faltan los triggers del nombre de zona';
  END IF;
END
$post$;

COMMIT;
