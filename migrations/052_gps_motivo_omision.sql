-- =========================================================================
-- 052_gps_motivo_omision.sql
--
-- Endurece el flujo de check-in GPS para preventistas:
--
--   1. Agrega columna `gps_motivo_omision` (text, nullable) a `pedidos` y
--      `visitas_cliente`. Justificación escrita que el preventista deja
--      cuando el GPS no pudo capturar (status = timeout/unavailable/error).
--      `denied` no entra acá: bloquea el flujo en el cliente y nunca llega
--      a persistirse.
--
--   2. Re-crea `registrar_geolocalizacion_pedido` aceptando
--      `p_motivo_omision`. Ajusta la idempotencia: ya no es absoluta —
--      permite "completar" un pedido que quedó con status no-ok cuando
--      después se obtienen coordenadas válidas. Sigue impidiendo
--      sobrescribir un check-in `ok` ya registrado.
--
--   3. Re-crea `registrar_visita_cliente` aceptando `p_motivo_omision` (las
--      visitas no son idempotentes por diseño — cada llamada inserta).
--
-- Retro-compatible: registros existentes mantienen `gps_motivo_omision = NULL`.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Columnas
-- -------------------------------------------------------------------------

ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS gps_motivo_omision text;

ALTER TABLE public.visitas_cliente
  ADD COLUMN IF NOT EXISTS gps_motivo_omision text;

COMMENT ON COLUMN public.pedidos.gps_motivo_omision IS
  'Justificación del preventista cuando gps_status no es ok (timeout/unavailable/error). NULL si gps_status=ok o si el pedido es previo a la migración 052.';

COMMENT ON COLUMN public.visitas_cliente.gps_motivo_omision IS
  'Justificación del preventista cuando gps_status no es ok. NULL si gps_status=ok o si la visita es previa a la migración 052.';

-- -------------------------------------------------------------------------
-- 2. RPC registrar_geolocalizacion_pedido (con motivo + idempotencia ajustada)
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_geolocalizacion_pedido(
  p_pedido_id bigint,
  p_status text,
  p_lat numeric DEFAULT NULL,
  p_lng numeric DEFAULT NULL,
  p_accuracy numeric DEFAULT NULL,
  p_capturado_at timestamptz DEFAULT NULL,
  p_motivo_omision text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_pedido RECORD;
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

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;

  SELECT id, usuario_id, sucursal_id, gps_status INTO v_pedido
  FROM pedidos
  WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no existe');
  END IF;

  IF v_pedido.sucursal_id IS DISTINCT FROM current_sucursal_id() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido fuera de la sucursal activa');
  END IF;

  -- Autorizacion: dueño del pedido o admin.
  IF v_pedido.usuario_id IS DISTINCT FROM v_user_id AND v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- Idempotencia ajustada:
  --  - Si ya hay un check-in 'ok' registrado, no se sobrescribe (jamás).
  --  - Si hay un status no-ok previo (denied/timeout/etc) y el nuevo
  --    también es no-ok, tampoco se sobrescribe (no acumular ruido).
  --  - Sólo se permite ESCALAR de no-ok → 'ok' (caso: el preventista
  --    activó el GPS después y vuelve al pedido a "completarlo").
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
    gps_motivo_omision = CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END
  WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

ALTER FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamptz, text)
  OWNER TO postgres;

COMMENT ON FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamptz, text) IS
  'Registra el check-in GPS de un pedido. Solo el preventista dueño o un admin. Idempotente parcial: nunca sobrescribe un ok previo, pero permite escalar no-ok → ok si el preventista re-intenta con permiso ya activo.';

GRANT EXECUTE ON FUNCTION public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamptz, text)
  TO authenticated, service_role;

-- Drop firma vieja (sin p_motivo_omision) para evitar ambigüedad.
DROP FUNCTION IF EXISTS public.registrar_geolocalizacion_pedido(bigint, text, numeric, numeric, numeric, timestamptz);

-- -------------------------------------------------------------------------
-- 3. RPC registrar_visita_cliente (con motivo)
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_visita_cliente(
  p_cliente_id bigint,
  p_status text,
  p_lat numeric DEFAULT NULL,
  p_lng numeric DEFAULT NULL,
  p_accuracy numeric DEFAULT NULL,
  p_capturado_at timestamptz DEFAULT NULL,
  p_motivo_omision text DEFAULT NULL
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

  SELECT id, sucursal_id INTO v_cliente FROM clientes WHERE id = p_cliente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente no existe');
  END IF;
  IF v_cliente.sucursal_id IS DISTINCT FROM v_sucursal THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;

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
    gps_lat, gps_lng, gps_accuracy, gps_capturado_at, gps_status, gps_motivo_omision
  ) VALUES (
    v_user_id, p_cliente_id, v_sucursal,
    CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    COALESCE(p_capturado_at, now()),
    p_status,
    CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END
  ) RETURNING id INTO v_visita_id;

  RETURN jsonb_build_object('success', true, 'visita_id', v_visita_id);
END;
$$;

ALTER FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz, text)
  OWNER TO postgres;

COMMENT ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz, text) IS
  'Registra una visita de cliente (ping del preventista). Cada llamada crea un registro nuevo. Acepta motivo de omisión cuando gps_status no es ok.';

GRANT EXECUTE ON FUNCTION public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz, text)
  TO authenticated, service_role;

DROP FUNCTION IF EXISTS public.registrar_visita_cliente(bigint, text, numeric, numeric, numeric, timestamptz);

COMMIT;
