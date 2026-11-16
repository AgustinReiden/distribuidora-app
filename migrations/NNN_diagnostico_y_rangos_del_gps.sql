-- =========================================================================
-- mig NNN · #1602 · el diagnóstico del equipo con cada captura de GPS, y los
-- rangos de lo que se guarda (VAR-01 de la auditoría del 12/11)
-- =========================================================================
--
-- Tres preventistas de una sucursal tienen sus pedidos 100 % en
-- `gps_status = 'denied'` desde hace meses, y los datos no dicen qué teléfono
-- tienen ni si usan la app instalada o el navegador. Desde esta migración cada
-- captura guarda un diagnóstico corto del equipo:
--
--   1 · `pedidos.gps_diagnostico` y `visitas_cliente.gps_diagnostico` (jsonb):
--       `{permiso, error, instalada, navegador, so}` —el estado de la
--       Permissions API, el código del error de `getCurrentPosition`, si es la
--       app instalada, y el navegador y el sistema como familia y versión mayor
--       (nunca el user agent entero). Lo arma `diagnosticoGps` en
--       `src/utils/ubicacionEquipo.ts`. Un objeto de hasta 300 bytes, con CHECK.
--       Sin grant de escritura REST: lo escriben sólo las dos RPC (DEFINER). Se
--       lee con el SELECT de tabla que `authenticated` ya tiene en las dos.
--
--   2 · `registrar_geolocalizacion_pedido` y `registrar_visita_cliente` suman
--       `p_diagnostico jsonb DEFAULT NULL` al final. La firma vieja se dropea
--       (dos sobrecargas superpuestas dan PGRST203), y el DEFAULT hace que un
--       bundle viejo del PWA, que llama con los siete parámetros de siempre por
--       nombre, siga resolviendo a la nueva. Un diagnóstico que no es un objeto
--       o se pasa del tope no se guarda (queda NULL): es un extra y no puede
--       costar la ubicación. Lo demás del cuerpo es el vivo, salvo que la
--       lectura del rol ahora mira `activo` (#1490): con la firma nueva, sus
--       dos entradas de `scripts/rol-sin-activo-permitidas.json` ya no aplican
--       (la lista sólo se achica). No cambia nada: un desactivado ya cortaba
--       por `current_sucursal_id()` NULL.
--
--   3 · VAR-01: `gps_lat` entre −90 y 90, `gps_lng` entre −180 y 180 y
--       `gps_accuracy` ≥ 0, en `pedidos` y en `visitas_cliente`. El NaN queda
--       afuera: `'NaN'::numeric` es mayor que todo número y no pasa ningún
--       techo; la precisión, que no tiene techo, lo excluye con `<> 'NaN'`. Las
--       columnas son numeric con precisión, que no guardan infinito. La premisa
--       cuenta las filas que los violarían y falla con el número.
--
-- Parche con premisa: los cuerpos vivos son los leídos el 15/11 de la base
-- local (huella igual a prod, ledger en la 503).
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
-- Premisas: los cuerpos vivos, que la columna no exista, y ninguna fila fuera
-- de rango
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
  n_ped bigint;
  n_vis bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)', '00b6e37a89bdad2e880fdaccb1cb279b'),
    ('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)',          'a1fc32005cd3e34bebf712fce2c64c89')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = to_regprocedure(r.f);
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name IN ('pedidos', 'visitas_cliente')
                AND column_name = 'gps_diagnostico') THEN
    RAISE EXCEPTION 'mig NNN · gps_diagnostico ya existe: revisar a mano';
  END IF;

  SELECT count(*) INTO n_ped FROM public.pedidos
   WHERE NOT (gps_lat BETWEEN -90 AND 90) OR NOT (gps_lng BETWEEN -180 AND 180)
      OR NOT (gps_accuracy >= 0 AND gps_accuracy <> 'NaN');
  SELECT count(*) INTO n_vis FROM public.visitas_cliente
   WHERE NOT (gps_lat BETWEEN -90 AND 90) OR NOT (gps_lng BETWEEN -180 AND 180)
      OR NOT (gps_accuracy >= 0 AND gps_accuracy <> 'NaN');
  IF n_ped > 0 OR n_vis > 0 THEN
    RAISE EXCEPTION 'mig NNN · hay GPS fuera de rango (o NaN): % pedidos y % visitas. Corregirlos antes de sumar los CHECK', n_ped, n_vis;
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · La columna del diagnóstico
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos ADD COLUMN gps_diagnostico jsonb;
ALTER TABLE public.visitas_cliente ADD COLUMN gps_diagnostico jsonb;

ALTER TABLE public.pedidos ADD CONSTRAINT pedidos_gps_diagnostico_forma
  CHECK (jsonb_typeof(gps_diagnostico) = 'object' AND octet_length(gps_diagnostico::text) <= 300);
ALTER TABLE public.visitas_cliente ADD CONSTRAINT visitas_cliente_gps_diagnostico_forma
  CHECK (jsonb_typeof(gps_diagnostico) = 'object' AND octet_length(gps_diagnostico::text) <= 300);

COMMENT ON COLUMN public.pedidos.gps_diagnostico IS
  'El equipo al capturar el GPS (#1602): {permiso, error, instalada, navegador, so}. Lo arma diagnosticoGps (src/utils/ubicacionEquipo.ts). NULL antes de la mig NNN o si el cliente no lo mandó.';
COMMENT ON COLUMN public.visitas_cliente.gps_diagnostico IS
  'El equipo al capturar el GPS (#1602): {permiso, error, instalada, navegador, so}. Lo arma diagnosticoGps (src/utils/ubicacionEquipo.ts). NULL antes de la mig NNN o si el cliente no lo mandó.';

-- ---------------------------------------------------------------------------
-- 3 · VAR-01 · rangos (antes de las RPC: lo que escriban ya pasa por acá)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_gps_lat_rango      CHECK (gps_lat BETWEEN -90 AND 90),
  ADD CONSTRAINT pedidos_gps_lng_rango      CHECK (gps_lng BETWEEN -180 AND 180),
  ADD CONSTRAINT pedidos_gps_accuracy_rango CHECK (gps_accuracy >= 0 AND gps_accuracy <> 'NaN');
ALTER TABLE public.visitas_cliente
  ADD CONSTRAINT visitas_cliente_gps_lat_rango      CHECK (gps_lat BETWEEN -90 AND 90),
  ADD CONSTRAINT visitas_cliente_gps_lng_rango      CHECK (gps_lng BETWEEN -180 AND 180),
  ADD CONSTRAINT visitas_cliente_gps_accuracy_rango CHECK (gps_accuracy >= 0 AND gps_accuracy <> 'NaN');

-- ---------------------------------------------------------------------------
-- 2 · Las dos RPC, con `p_diagnostico` al final
-- ---------------------------------------------------------------------------
DROP FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamp with time zone, text);

CREATE FUNCTION public.registrar_geolocalizacion_pedido(p_pedido_id bigint, p_status text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric, p_capturado_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_motivo_omision text DEFAULT NULL::text, p_diagnostico jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_pedido RECORD;
  -- #1602: un extra; si no es un objeto chico, no se guarda (no se pierde el GPS).
  v_diag jsonb := CASE WHEN jsonb_typeof(p_diagnostico) = 'object' AND octet_length(p_diagnostico::text) <= 300
                       THEN p_diagnostico END;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;

  IF p_status NOT IN ('ok','denied','unavailable','timeout','error') THEN
    RETURN jsonb_build_object('success', false, 'error', 'gps_status invalido');
  END IF;

  IF p_status = 'ok' AND (p_lat IS NULL OR p_lng IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'lat y lng requeridos cuando status=ok');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id AND COALESCE(activo, true);

  SELECT id, usuario_id, sucursal_id, gps_status INTO v_pedido
  FROM pedidos
  WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no existe');
  END IF;

  IF v_pedido.sucursal_id IS DISTINCT FROM current_sucursal_id() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido fuera de la sucursal activa');
  END IF;

  -- #1048: con `<>` un rol NULL daba NULL y dejaba pasar.
  IF v_pedido.usuario_id IS DISTINCT FROM v_user_id AND v_user_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  IF v_pedido.gps_status = 'ok' THEN
    RETURN jsonb_build_object('success', true, 'ya_registrado', true);
  END IF;
  IF v_pedido.gps_status IS NOT NULL AND p_status <> 'ok' THEN
    RETURN jsonb_build_object('success', true, 'ya_registrado', true);
  END IF;

  UPDATE pedidos SET
    gps_status        = p_status,
    gps_lat           = CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    gps_lng           = CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    gps_accuracy      = CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    gps_capturado_at  = COALESCE(p_capturado_at, now()),
    gps_motivo_omision = CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END,
    gps_diagnostico   = v_diag
  WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true);
END;
$function$;

ALTER FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) TO authenticated, service_role;
COMMENT ON FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) IS
  'Registra el check-in GPS de un pedido. Solo el preventista dueno o un admin. Idempotente parcial: nunca sobrescribe un ok previo, pero permite escalar no-ok -> ok si el preventista re-intenta con permiso ya activo. p_diagnostico (mig NNN, #1602): el equipo al capturar; un bundle viejo no lo manda.';

DROP FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text);

CREATE FUNCTION public.registrar_visita_cliente(p_cliente_id bigint, p_status text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric, p_capturado_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_motivo_omision text DEFAULT NULL::text, p_diagnostico jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_cliente RECORD;
  v_autorizado boolean;
  v_visita_id bigint;
  -- #1602: un extra; si no es un objeto chico, no se guarda (no se pierde la visita).
  v_diag jsonb := CASE WHEN jsonb_typeof(p_diagnostico) = 'object' AND octet_length(p_diagnostico::text) <= 300
                       THEN p_diagnostico END;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_status NOT IN ('ok','denied','unavailable','timeout','error') THEN
    RETURN jsonb_build_object('success', false, 'error', 'gps_status invalido');
  END IF;
  IF p_status = 'ok' AND (p_lat IS NULL OR p_lng IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'lat y lng requeridos cuando status=ok');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id AND COALESCE(activo, true);
  -- #1056: con `NOT IN` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS NULL OR v_user_role NOT IN ('preventista', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rol no autorizado para marcar visitas');
  END IF;

  SELECT id, sucursal_id, reservado_admin, activo INTO v_cliente FROM clientes WHERE id = p_cliente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente no existe');
  END IF;
  IF v_cliente.sucursal_id IS DISTINCT FROM v_sucursal THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;
  -- #1319: marcar una visita es operar, y con un cliente dado de baja no se opera.
  IF NOT v_cliente.activo THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente dado de baja: reactivalo desde Clientes para marcarle visitas');
  END IF;

  IF v_user_role IN ('preventista') THEN
    SELECT (
      NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id)
      OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id AND cp.preventista_id = v_user_id)
    ) INTO v_autorizado;
    IF NOT v_autorizado THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente asignado a otro preventista');
    END IF;

    -- Reservado a administracion (mig 214). Sin excepcion de historial: marcar
    -- una visita es operar, no consultar el pasado.
    IF v_cliente.reservado_admin THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente reservado a administración');
    END IF;
  END IF;

  INSERT INTO visitas_cliente (
    preventista_id, cliente_id, sucursal_id,
    gps_lat, gps_lng, gps_accuracy, gps_capturado_at, gps_status, gps_motivo_omision,
    gps_diagnostico
  ) VALUES (
    v_user_id, p_cliente_id, v_sucursal,
    CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    COALESCE(p_capturado_at, now()),
    p_status,
    CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END,
    v_diag
  ) RETURNING id INTO v_visita_id;

  RETURN jsonb_build_object('success', true, 'visita_id', v_visita_id);
END;
$function$;

ALTER FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) TO authenticated, service_role;
COMMENT ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamp with time zone, text, jsonb) IS
  'Registra una visita de cliente (ping del preventista). Cada llamada crea un registro nuevo. Acepta motivo de omision cuando gps_status no es ok. p_diagnostico (mig NNN, #1602): el equipo al capturar; un bundle viejo no lo manda.';

-- ---------------------------------------------------------------------------
-- Poscondición: una sola firma de cada una, el cuerpo, el definer y los EXECUTE
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname IN ('registrar_geolocalizacion_pedido', 'registrar_visita_cliente')) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · quedó más de una sobrecarga de las RPC de GPS';
  END IF;
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)', '5c7e3295d8bf4c94d029fa775436f061'),
    ('public.registrar_visita_cliente(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)',          '7f017670fa2781a9b547b5517d078e0f')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h
       OR x.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
       OR x.def IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
