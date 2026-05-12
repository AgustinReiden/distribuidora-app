-- =========================================================================
-- 042_visitas_cliente.sql
--
-- "Marcar visita": permite a un preventista registrar que paso por un
-- cliente sin necesariamente cerrar pedido. Cada apretada del boton crea
-- un registro nuevo (sin dedup) para reflejar fielmente revisitas.
--
--   1. Tabla public.visitas_cliente
--   2. RLS: preventista ve/inserta las suyas, admin ve todas las de su
--      sucursal, encargado las de su sucursal en read-only.
--   3. RPC registrar_visita_cliente: SECURITY DEFINER, valida que el
--      cliente pertenezca a la sucursal y que el preventista pueda verlo
--      (cliente sin preventista_ids asignados o asignado a el).
--   4. RPC listar_visitas_hoy: devuelve las visitas de HOY del preventista
--      logueado (timeline modal del preventista).
--   5. Update obtener_geolocalizacion_preventistas: agrega array `visitas`
--      al output JSON para que el panel admin las muestre.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Tabla visitas_cliente
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.visitas_cliente (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  preventista_id uuid NOT NULL REFERENCES public.perfiles(id) ON DELETE CASCADE,
  cliente_id    bigint NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  sucursal_id   bigint NOT NULL REFERENCES public.sucursales(id),
  gps_lat       numeric(10,7),
  gps_lng       numeric(10,7),
  gps_accuracy  numeric(8,2),
  gps_capturado_at timestamptz,
  gps_status    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT visitas_cliente_gps_status_check
    CHECK (gps_status IS NULL OR gps_status IN ('ok','denied','unavailable','timeout','error'))
);

CREATE INDEX IF NOT EXISTS idx_visitas_cliente_preventista_created
  ON public.visitas_cliente (preventista_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_visitas_cliente_sucursal_created
  ON public.visitas_cliente (sucursal_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_visitas_cliente_cliente_created
  ON public.visitas_cliente (cliente_id, created_at DESC);

COMMENT ON TABLE public.visitas_cliente IS
  'Pings de visita marcados por el preventista (independientes de pedidos). Cada apretada de "Marcar visita" en la PWA crea un registro.';

-- -------------------------------------------------------------------------
-- 2. RLS
-- -------------------------------------------------------------------------

ALTER TABLE public.visitas_cliente ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS visitas_cliente_select ON public.visitas_cliente;
CREATE POLICY visitas_cliente_select ON public.visitas_cliente
  FOR SELECT
  TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      preventista_id = auth.uid()
      OR EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol IN ('admin', 'encargado')
      )
    )
  );

-- INSERT: solo via RPC (SECURITY DEFINER); no abrimos INSERT directo via
-- PostgREST para mantener invariantes (sucursal correcta, autorizacion,
-- snapshot de coordenadas).
DROP POLICY IF EXISTS visitas_cliente_insert ON public.visitas_cliente;
CREATE POLICY visitas_cliente_insert ON public.visitas_cliente
  FOR INSERT
  TO authenticated
  WITH CHECK (false);

-- -------------------------------------------------------------------------
-- 3. RPC registrar_visita_cliente
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_visita_cliente(
  p_cliente_id bigint,
  p_status text,
  p_lat numeric DEFAULT NULL,
  p_lng numeric DEFAULT NULL,
  p_accuracy numeric DEFAULT NULL,
  p_capturado_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_cliente RECORD;
  v_autorizado boolean;
  v_visita_id bigint;
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

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('preventista', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rol no autorizado para marcar visitas');
  END IF;

  -- Cliente debe existir y pertenecer a la sucursal activa.
  SELECT id, sucursal_id INTO v_cliente FROM clientes WHERE id = p_cliente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente no existe');
  END IF;
  IF v_cliente.sucursal_id IS DISTINCT FROM v_sucursal THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;

  -- Si es preventista, validar que el cliente este sin asignar a nadie o
  -- asignado a el (misma logica que el resto de la app). Admin: libre.
  IF v_user_role = 'preventista' THEN
    SELECT (
      NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id)
      OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id AND cp.preventista_id = v_user_id)
    ) INTO v_autorizado;
    IF NOT v_autorizado THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente asignado a otro preventista');
    END IF;
  END IF;

  INSERT INTO visitas_cliente (
    preventista_id, cliente_id, sucursal_id,
    gps_lat, gps_lng, gps_accuracy, gps_capturado_at, gps_status
  ) VALUES (
    v_user_id, p_cliente_id, v_sucursal,
    CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    COALESCE(p_capturado_at, now()),
    p_status
  ) RETURNING id INTO v_visita_id;

  RETURN jsonb_build_object('success', true, 'visita_id', v_visita_id);
END;
$$;

ALTER FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz) OWNER TO postgres;

COMMENT ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz) IS
  'Registra una visita de cliente (ping del preventista). Cada llamada crea un registro nuevo. Valida sucursal y visibilidad del cliente para el rol preventista.';

GRANT EXECUTE ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz)
  TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 4. RPC listar_visitas_hoy
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listar_visitas_hoy()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_sucursal bigint := current_sucursal_id();
  v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.created_at), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT
      v.id              AS visita_id,
      v.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.direccion       AS cliente_direccion,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      v.gps_lat,
      v.gps_lng,
      v.gps_status,
      v.gps_capturado_at,
      v.created_at,
      public.haversine_m(v.gps_lat, v.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM visitas_cliente v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    WHERE v.preventista_id = v_user_id
      AND v.sucursal_id = v_sucursal
      AND (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date = v_hoy
  ) t;

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.listar_visitas_hoy() OWNER TO postgres;

COMMENT ON FUNCTION public.listar_visitas_hoy() IS
  'Devuelve las visitas marcadas HOY por el preventista logueado, con datos del cliente y distancia. Usado por el modal "Visitas del dia".';

GRANT EXECUTE ON FUNCTION public.listar_visitas_hoy() TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 5. Update obtener_geolocalizacion_preventistas (suma array `visitas`)
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_geolocalizacion_preventistas(
  p_fecha_desde date DEFAULT NULL,
  p_fecha_hasta date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_fecha_desde date := COALESCE(p_fecha_desde, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_fecha_hasta date := COALESCE(p_fecha_hasta, v_fecha_desde);
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role <> 'admin' THEN
    RAISE EXCEPTION 'Solo admins pueden ver geolocalizacion de preventistas' USING ERRCODE = '42501';
  END IF;

  WITH pedidos_rango AS (
    SELECT
      p.id              AS pedido_id,
      p.usuario_id      AS preventista_id,
      p.fecha,
      p.created_at      AS pedido_created_at,
      p.total,
      p.gps_lat,
      p.gps_lng,
      p.gps_accuracy,
      p.gps_capturado_at,
      p.gps_status,
      p.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(p.gps_lat, p.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM pedidos p
    LEFT JOIN clientes c ON c.id = p.cliente_id
    WHERE p.sucursal_id = v_sucursal
      AND p.fecha BETWEEN v_fecha_desde AND v_fecha_hasta
      AND p.usuario_id IS NOT NULL
  ),
  visitas_rango AS (
    SELECT
      v.id              AS visita_id,
      v.preventista_id,
      v.created_at      AS visita_created_at,
      v.gps_lat,
      v.gps_lng,
      v.gps_accuracy,
      v.gps_capturado_at,
      v.gps_status,
      v.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(v.gps_lat, v.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM visitas_cliente v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    WHERE v.sucursal_id = v_sucursal
      AND (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN v_fecha_desde AND v_fecha_hasta
  ),
  preventistas_resumen AS (
    SELECT
      pr.preventista_id,
      per.nombre AS preventista_nombre,
      COUNT(*)::int AS total_pedidos,
      COUNT(*) FILTER (WHERE pr.gps_status = 'ok')::int AS pedidos_con_gps,
      COUNT(*) FILTER (WHERE pr.gps_status IS NULL OR pr.gps_status <> 'ok')::int AS pedidos_sin_gps,
      COUNT(*) FILTER (
        WHERE pr.gps_status = 'ok' AND pr.distancia_m IS NOT NULL AND pr.distancia_m >= 2000
      )::int AS pedidos_lejos,
      (
        SELECT COUNT(*) FROM visitas_rango v WHERE v.preventista_id = pr.preventista_id
      )::int AS total_visitas,
      (
        SELECT jsonb_build_object(
          'lat', e.lat,
          'lng', e.lng,
          'capturado_at', e.capturado_at,
          'tipo', e.tipo,
          'id', e.id
        )
        FROM (
          SELECT pr2.gps_lat AS lat, pr2.gps_lng AS lng, pr2.gps_capturado_at AS capturado_at,
                 'pedido'::text AS tipo, pr2.pedido_id AS id
          FROM pedidos_rango pr2
          WHERE pr2.preventista_id = pr.preventista_id AND pr2.gps_status = 'ok'
          UNION ALL
          SELECT v.gps_lat AS lat, v.gps_lng AS lng, v.gps_capturado_at AS capturado_at,
                 'visita'::text AS tipo, v.visita_id AS id
          FROM visitas_rango v
          WHERE v.preventista_id = pr.preventista_id AND v.gps_status = 'ok'
        ) e
        ORDER BY e.capturado_at DESC NULLS LAST
        LIMIT 1
      ) AS ultima_ubicacion
    FROM pedidos_rango pr
    LEFT JOIN perfiles per ON per.id = pr.preventista_id
    WHERE per.rol = 'preventista'
    GROUP BY pr.preventista_id, per.nombre
  )
  SELECT jsonb_build_object(
    'fecha_desde', v_fecha_desde,
    'fecha_hasta', v_fecha_hasta,
    'preventistas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(preventistas_resumen.*) ORDER BY preventista_nombre)
       FROM preventistas_resumen),
      '[]'::jsonb
    ),
    'pedidos', COALESCE(
      (SELECT jsonb_agg(to_jsonb(pr.*) ORDER BY pr.pedido_created_at NULLS LAST)
       FROM pedidos_rango pr
       JOIN perfiles per ON per.id = pr.preventista_id AND per.rol = 'preventista'),
      '[]'::jsonb
    ),
    'visitas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(v.*) ORDER BY v.visita_created_at NULLS LAST)
       FROM visitas_rango v
       JOIN perfiles per ON per.id = v.preventista_id AND per.rol = 'preventista'),
      '[]'::jsonb
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.obtener_geolocalizacion_preventistas(date, date) IS
  'Panel admin de geolocalizacion: resumen por preventista + detalle de pedidos y visitas con GPS, distancia al cliente y timestamp. Scope a current_sucursal_id().';

COMMIT;
