-- Migración 018: RPC para actualizar items de un pedido existente
-- Maneja atómicamente: ajuste de stock, actualización de items, recálculo de total, historial

CREATE OR REPLACE FUNCTION actualizar_pedido_items(
  p_pedido_id BIGINT,
  p_items_nuevos JSONB, -- [{producto_id, cantidad, precio_unitario}]
  p_usuario_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_item_original RECORD;
  v_item_nuevo JSONB;
  v_producto_id INT;
  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_diferencia INT;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_total_nuevo DECIMAL := 0;
  v_total_anterior DECIMAL;
  v_errores TEXT[] := '{}';
  v_items_originales JSONB;
BEGIN
  -- Verificar que el pedido existe y no está entregado
  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  -- Verificar estado del pedido (no permitir editar pedidos entregados)
  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- Guardar items originales para historial
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id,
    'cantidad', cantidad,
    'precio_unitario', precio_unitario
  )) INTO v_items_originales
  FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- 1. Validar stock para items con cantidad aumentada o nuevos
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos)
  LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;

    -- Obtener cantidad original del item (si existe)
    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);

    -- Si aumenta la cantidad, validar stock disponible
    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id FOR UPDATE;

      IF v_stock_actual IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_producto_id || ' no encontrado');
      ELSIF v_stock_actual < v_diferencia THEN
        v_errores := array_append(v_errores,
          COALESCE(v_producto_nombre, 'Producto ' || v_producto_id) ||
          ': stock insuficiente (disponible: ' || v_stock_actual ||
          ', adicional requerido: ' || v_diferencia || ')');
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  -- 2. Restaurar stock de items que se eliminan
  FOR v_item_original IN
    SELECT pi.producto_id, pi.cantidad
    FROM pedido_items pi
    WHERE pi.pedido_id = p_pedido_id
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_items_nuevos) jn
      WHERE (jn->>'producto_id')::INT = pi.producto_id
    )
  LOOP
    UPDATE productos SET stock = stock + v_item_original.cantidad
    WHERE id = v_item_original.producto_id;
  END LOOP;

  -- 3. Para cada item existente, ajustar stock según diferencia
  FOR v_item_original IN
    SELECT pi.producto_id, pi.cantidad
    FROM pedido_items pi
    WHERE pi.pedido_id = p_pedido_id
    AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_items_nuevos) jn
      WHERE (jn->>'producto_id')::INT = pi.producto_id
    )
  LOOP
    -- Restaurar el stock original primero
    UPDATE productos SET stock = stock + v_item_original.cantidad
    WHERE id = v_item_original.producto_id;
  END LOOP;

  -- 4. Eliminar items actuales
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- 5. Insertar nuevos items y descontar stock
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos)
  LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;

    -- Descontar stock
    UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id;

    -- Insertar nuevo item
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal)
    VALUES (
      p_pedido_id,
      v_producto_id,
      v_cantidad_nueva,
      (v_item_nuevo->>'precio_unitario')::DECIMAL,
      v_cantidad_nueva * (v_item_nuevo->>'precio_unitario')::DECIMAL
    );

    v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * (v_item_nuevo->>'precio_unitario')::DECIMAL);
  END LOOP;

  -- 6. Actualizar total del pedido
  UPDATE pedidos SET total = v_total_nuevo, updated_at = NOW() WHERE id = p_pedido_id;

  -- 7. Registrar cambio en historial
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (
    p_pedido_id,
    p_usuario_id,
    'items',
    COALESCE(v_items_originales::TEXT, '[]'),
    p_items_nuevos::TEXT
  );

  -- También registrar cambio de total si cambió
  IF v_total_anterior <> v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (
      p_pedido_id,
      p_usuario_id,
      'total',
      v_total_anterior::TEXT,
      v_total_nuevo::TEXT
    );
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Comentario de documentación
COMMENT ON FUNCTION actualizar_pedido_items(BIGINT, JSONB, UUID) IS
'Actualiza los items de un pedido existente, ajustando stock automáticamente y registrando historial';
