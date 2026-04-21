-- Migration 070: Rendiciones automáticas + control diario
--
-- Reemplaza el flujo manual de rendiciones (crear_rendicion_recorrido /
-- crear_rendicion_por_fecha + presentar_rendicion + revisar_rendicion)
-- por un resumen auto-calculado por (fecha_entrega, transportista_id) sobre
-- los pedidos ya entregados. El admin solo marca el resumen como
-- "controlada" (o desmarca). Las tablas viejas (rendiciones,
-- rendicion_items, rendicion_ajustes) quedan para historia pero la UI
-- deja de usarlas.
--
-- Piezas:
--   1. Tabla rendiciones_control (fecha, transportista_id, sucursal_id)
--      con RLS multi-tenant consistente con el patrón 058/066.
--   2. RPC obtener_resumen_rendiciones(desde, hasta, transportista?)
--      retornando breakdown por cada forma_pago, total general, cantidad
--      de pedidos y estado de control.
--   3. RPC marcar_rendicion_controlada / desmarcar_rendicion_controlada.
--   4. RPC consultar_control_rendicion para la UI del edit de fecha_entrega.
--   5. Trigger sobre pedidos: si fecha_entrega cambia entre días distintos
--      (o el pedido pasa a cancelado), anula el control del día anterior
--      y del nuevo si existían.


-- ============================================================
-- 1. Tabla rendiciones_control
-- ============================================================

CREATE TABLE IF NOT EXISTS rendiciones_control (
  id BIGSERIAL PRIMARY KEY,
  fecha DATE NOT NULL,
  transportista_id UUID NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  sucursal_id BIGINT NOT NULL REFERENCES sucursales(id) ON DELETE CASCADE,
  controlada_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  controlada_por UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(fecha, transportista_id, sucursal_id)
);

CREATE INDEX IF NOT EXISTS idx_rendiciones_control_fecha
  ON rendiciones_control(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_rendiciones_control_transportista
  ON rendiciones_control(transportista_id);
CREATE INDEX IF NOT EXISTS idx_rendiciones_control_sucursal
  ON rendiciones_control(sucursal_id);

COMMENT ON TABLE rendiciones_control IS
  'Registro de control diario de rendiciones por (fecha, transportista). Se borra automáticamente si cambia la fecha_entrega de un pedido afectado.';


-- ============================================================
-- 2. RLS policies (multi-tenant, siguiendo patrón 058)
-- ============================================================

ALTER TABLE rendiciones_control ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mt_rendiciones_control_select ON rendiciones_control;
DROP POLICY IF EXISTS mt_rendiciones_control_insert ON rendiciones_control;
DROP POLICY IF EXISTS mt_rendiciones_control_delete ON rendiciones_control;

CREATE POLICY mt_rendiciones_control_select ON rendiciones_control
  FOR SELECT TO authenticated
  USING (
    es_encargado_o_admin()
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_rendiciones_control_insert ON rendiciones_control
  FOR INSERT TO authenticated
  WITH CHECK (
    es_encargado_o_admin()
    AND sucursal_id = current_sucursal_id()
  );

CREATE POLICY mt_rendiciones_control_delete ON rendiciones_control
  FOR DELETE TO authenticated
  USING (
    es_encargado_o_admin()
    AND sucursal_id = current_sucursal_id()
  );


-- ============================================================
-- 3. RPC: obtener_resumen_rendiciones
-- ============================================================

CREATE OR REPLACE FUNCTION obtener_resumen_rendiciones(
  p_fecha_desde DATE DEFAULT (CURRENT_DATE - INTERVAL '30 days')::DATE,
  p_fecha_hasta DATE DEFAULT CURRENT_DATE,
  p_transportista_id UUID DEFAULT NULL
)
RETURNS TABLE (
  fecha DATE,
  transportista_id UUID,
  transportista_nombre TEXT,
  total_efectivo NUMERIC,
  total_transferencia NUMERIC,
  total_cheque NUMERIC,
  total_cuenta_corriente NUMERIC,
  total_tarjeta NUMERIC,
  total_otros NUMERIC,
  total_general NUMERIC,
  cantidad_pedidos BIGINT,
  controlada BOOLEAN,
  controlada_at TIMESTAMPTZ,
  controlada_por_nombre TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  SELECT
    p.fecha_entrega::date AS fecha,
    p.transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'efectivo' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_efectivo,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'transferencia' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_transferencia,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'cheque' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_cheque,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'cuenta_corriente' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_cuenta_corriente,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'tarjeta' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_tarjeta,
    COALESCE(SUM(CASE WHEN p.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta')
                           OR p.forma_pago IS NULL THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_otros,
    COALESCE(SUM(p.monto_pagado), 0)::numeric AS total_general,
    COUNT(p.id)::bigint AS cantidad_pedidos,
    (rc.id IS NOT NULL) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre
  FROM pedidos p
  JOIN perfiles tr ON tr.id = p.transportista_id
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = p.fecha_entrega::date
   AND rc.transportista_id = p.transportista_id
   AND rc.sucursal_id = p.sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  WHERE p.estado = 'entregado'
    AND p.fecha_entrega IS NOT NULL
    AND p.transportista_id IS NOT NULL
    AND p.fecha_entrega::date BETWEEN p_fecha_desde AND p_fecha_hasta
    AND p.sucursal_id = v_sucursal_id
    AND (p_transportista_id IS NULL OR p.transportista_id = p_transportista_id)
  GROUP BY
    p.fecha_entrega::date,
    p.transportista_id,
    tr.nombre,
    rc.id,
    rc.controlada_at,
    cp.nombre
  ORDER BY p.fecha_entrega::date DESC, tr.nombre ASC;
END;
$$;

COMMENT ON FUNCTION obtener_resumen_rendiciones IS
  'Resumen auto-calculado de rendiciones por (fecha, transportista) con breakdown por forma de pago y estado de control.';


-- ============================================================
-- 4. RPC: marcar_rendicion_controlada
-- ============================================================

CREATE OR REPLACE FUNCTION marcar_rendicion_controlada(
  p_fecha DATE,
  p_transportista_id UUID
)
RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, controlada_por)
  VALUES (p_fecha, p_transportista_id, v_sucursal_id, auth.uid())
  ON CONFLICT (fecha, transportista_id, sucursal_id) DO UPDATE
    SET controlada_at = NOW(),
        controlada_por = auth.uid()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION marcar_rendicion_controlada IS
  'Marca la rendición diaria (fecha, transportista) como controlada. Idempotente (upsert).';


-- ============================================================
-- 5. RPC: desmarcar_rendicion_controlada
-- ============================================================

CREATE OR REPLACE FUNCTION desmarcar_rendicion_controlada(
  p_fecha DATE,
  p_transportista_id UUID
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  DELETE FROM rendiciones_control
  WHERE fecha = p_fecha
    AND transportista_id = p_transportista_id
    AND sucursal_id = v_sucursal_id;
END;
$$;

COMMENT ON FUNCTION desmarcar_rendicion_controlada IS
  'Quita el control de una rendición diaria (fecha, transportista).';


-- ============================================================
-- 6. RPC: consultar_control_rendicion (para UI de edit fecha_entrega)
-- ============================================================

CREATE OR REPLACE FUNCTION consultar_control_rendicion(
  p_transportista_id UUID,
  p_fecha DATE
)
RETURNS TABLE (
  controlada BOOLEAN,
  controlada_at TIMESTAMPTZ,
  controlada_por_nombre TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  SELECT
    (rc.id IS NOT NULL) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre
  FROM (SELECT 1) x
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = p_fecha
   AND rc.transportista_id = p_transportista_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por;
END;
$$;

COMMENT ON FUNCTION consultar_control_rendicion IS
  'Consulta si una rendición (fecha, transportista) ya fue controlada. Retorna una única fila siempre.';


-- ============================================================
-- 7. Trigger: anular control al editar fecha_entrega / cancelar pedido
-- ============================================================

CREATE OR REPLACE FUNCTION anular_control_por_cambio_fecha_entrega()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  -- Si el pedido tenía fecha_entrega y se movió/canceló/quitó, anular
  -- control del día anterior para ese transportista.
  IF OLD.fecha_entrega IS NOT NULL
     AND OLD.transportista_id IS NOT NULL
     AND (
       NEW.fecha_entrega IS NULL
       OR OLD.fecha_entrega::date IS DISTINCT FROM NEW.fecha_entrega::date
       OR (NEW.estado = 'cancelado' AND OLD.estado = 'entregado')
       OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id
     ) THEN
    DELETE FROM rendiciones_control
    WHERE transportista_id = OLD.transportista_id
      AND sucursal_id = OLD.sucursal_id
      AND fecha = OLD.fecha_entrega::date;
  END IF;

  -- Si ahora tiene fecha_entrega en un día distinto (o transportista
  -- distinto), anular control del nuevo día también.
  IF NEW.fecha_entrega IS NOT NULL
     AND NEW.transportista_id IS NOT NULL
     AND NEW.estado = 'entregado'
     AND (
       OLD.fecha_entrega IS NULL
       OR OLD.fecha_entrega::date IS DISTINCT FROM NEW.fecha_entrega::date
       OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id
     ) THEN
    DELETE FROM rendiciones_control
    WHERE transportista_id = NEW.transportista_id
      AND sucursal_id = NEW.sucursal_id
      AND fecha = NEW.fecha_entrega::date;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pedidos_anular_control ON pedidos;
CREATE TRIGGER trg_pedidos_anular_control
AFTER UPDATE OF fecha_entrega, estado, transportista_id ON pedidos
FOR EACH ROW
WHEN (
  OLD.fecha_entrega IS DISTINCT FROM NEW.fecha_entrega
  OR OLD.estado IS DISTINCT FROM NEW.estado
  OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id
)
EXECUTE FUNCTION anular_control_por_cambio_fecha_entrega();

COMMENT ON FUNCTION anular_control_por_cambio_fecha_entrega IS
  'Trigger: anula rendiciones_control de los días afectados cuando cambia fecha_entrega, estado=cancelado o transportista de un pedido entregado.';


-- ============================================================
-- 8. Grants (consistente con el patrón del repo)
-- ============================================================

GRANT EXECUTE ON FUNCTION obtener_resumen_rendiciones(DATE, DATE, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION marcar_rendicion_controlada(DATE, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION desmarcar_rendicion_controlada(DATE, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION consultar_control_rendicion(UUID, DATE) TO authenticated;
