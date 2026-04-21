-- Migration 047: Fix cancelar_pedido_con_stock para revertir TODOS los side-effects
--
-- Problemas en la versión anterior (migration 041):
--   1. No ajustaba saldo_cuenta del cliente (trigger solo escucha total/monto_pagado)
--   2. No decrementaba usos_pendientes de promociones para items bonificados
--   3. Restauraba stock de items bonificados (no debería: bonificados no descuentan stock)
--
-- Solución:
--   - Solo restaurar stock de items NO bonificados
--   - Decrementar usos_pendientes de promos para items bonificados
--   - Poner total=0 y monto_pagado=0 para activar trigger de saldo automáticamente

CREATE OR REPLACE FUNCTION cancelar_pedido_con_stock(
  p_pedido_id BIGINT,
  p_motivo TEXT,
  p_usuario_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_pedido RECORD;
  v_item RECORD;
  v_total_original DECIMAL;
BEGIN
  -- Lock the pedido row for atomic update
  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya está cancelado');
  END IF;

  IF v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  -- Guardar total original para el historial
  v_total_original := v_pedido.total;

  -- 1. Restaurar stock SOLO de items NO bonificados
  -- 2. Decrementar usos_pendientes de promos para items bonificados
  FOR v_item IN
    SELECT producto_id, cantidad, COALESCE(es_bonificacion, false) as es_bonificacion, promocion_id
    FROM pedido_items WHERE pedido_id = p_pedido_id
  LOOP
    IF v_item.es_bonificacion THEN
      -- Bonificados: revertir contador de promo (no restaurar stock porque nunca se descontó)
      IF v_item.promocion_id IS NOT NULL THEN
        UPDATE promociones
        SET usos_pendientes = GREATEST(usos_pendientes - v_item.cantidad, 0)
        WHERE id = v_item.promocion_id;
      END IF;
    ELSE
      -- No bonificados: restaurar stock
      UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
    END IF;
  END LOOP;

  -- 3. Cancelar pedido y poner total=0 para que el trigger de saldo revierta automáticamente
  --    El trigger actualizar_saldo_pedido() escucha UPDATE OF total, monto_pagado
  --    y calculará: saldo -= (total_viejo - monto_pagado_viejo) y sumará (0 - 0) = 0
  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id;

  -- 4. Registrar en historial con total original para auditoría
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (
    p_pedido_id,
    p_usuario_id,
    'estado',
    v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original
  );

  RETURN jsonb_build_object(
    'success', true,
    'mensaje', 'Pedido cancelado, stock restaurado, saldo ajustado',
    'total_original', v_total_original
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
