-- Migration 048: Rendiciones sin dependencia de recorridos
--
-- Problema: crear_rendicion_recorrido() requiere un recorrido existente.
-- Solución: Nueva RPC crear_rendicion_por_fecha() que busca pedidos entregados
--           directamente por transportista_id + fecha, sin necesitar recorrido.
--
-- También hace recorrido_id nullable para soportar rendiciones creadas sin recorrido.

-- 1. Hacer recorrido_id nullable
ALTER TABLE rendiciones ALTER COLUMN recorrido_id DROP NOT NULL;

-- 2. Nueva RPC: crear rendición por transportista + fecha
CREATE OR REPLACE FUNCTION crear_rendicion_por_fecha(
  p_transportista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS BIGINT AS $$
DECLARE
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
  v_count INTEGER := 0;
BEGIN
  -- Verificar que no existe ya rendición para este transportista/fecha
  IF EXISTS (
    SELECT 1 FROM rendiciones
    WHERE transportista_id = p_transportista_id AND fecha = p_fecha
  ) THEN
    RAISE EXCEPTION 'Ya existe una rendición para este transportista en esta fecha';
  END IF;

  -- Calcular totales desde pedidos entregados por este transportista en esta fecha
  -- Usa COALESCE(fecha_entrega, updated_at) porque no todos los entregados tienen fecha_entrega
  FOR v_pedido IN
    SELECT p.id,
           COALESCE(p.total, 0) as total,
           COALESCE(p.monto_pagado, p.total, 0) as monto_pagado,
           COALESCE(p.forma_pago, 'efectivo') as forma_pago
    FROM pedidos p
    WHERE p.transportista_id = p_transportista_id
      AND p.estado = 'entregado'
      AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha
  LOOP
    v_count := v_count + 1;
    IF v_pedido.forma_pago = 'efectivo' THEN
      v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE
      v_total_otros := v_total_otros + v_pedido.monto_pagado;
    END IF;
  END LOOP;

  -- Crear rendición (recorrido_id = NULL)
  INSERT INTO rendiciones (
    recorrido_id, transportista_id, fecha,
    total_efectivo_esperado, total_otros_medios, estado
  ) VALUES (
    NULL, p_transportista_id, p_fecha,
    v_total_efectivo, v_total_otros, 'pendiente'
  ) RETURNING id INTO v_rendicion_id;

  -- Crear items para cada pedido entregado
  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago)
  SELECT v_rendicion_id, p.id,
         COALESCE(p.monto_pagado, p.total, 0),
         COALESCE(p.forma_pago, 'efectivo')
  FROM pedidos p
  WHERE p.transportista_id = p_transportista_id
    AND p.estado = 'entregado'
    AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha;

  RETURN v_rendicion_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- 3. Backfill: setear fecha_entrega para pedidos entregados que no la tienen
UPDATE pedidos
SET fecha_entrega = updated_at
WHERE estado = 'entregado'
  AND fecha_entrega IS NULL;
