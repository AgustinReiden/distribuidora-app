-- =====================================================
-- MIGRACIÓN 008: Operaciones Atómicas
-- Soluciona race conditions y operaciones sin transacción
-- =====================================================

-- 1. FUNCIÓN: Descontar stock de forma atómica
-- Evita race conditions en pedidos simultáneos
CREATE OR REPLACE FUNCTION descontar_stock_atomico(
  p_items JSONB -- Array de {producto_id, cantidad}
)
RETURNS JSONB AS $$
DECLARE
  item JSONB;
  v_producto_id INT;
  v_cantidad INT;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  errores TEXT[] := '{}';
BEGIN
  -- Verificar stock de todos los productos primero (con bloqueo)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;

    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos
    WHERE id = v_producto_id
    FOR UPDATE; -- Bloqueo para evitar race condition

    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
    END IF;
  END LOOP;

  -- Si hay errores, retornar sin hacer cambios
  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  -- Descontar stock de todos los productos
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;

    UPDATE productos
    SET stock = stock - v_cantidad
    WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql;

-- 2. FUNCIÓN: Restaurar stock de forma atómica
CREATE OR REPLACE FUNCTION restaurar_stock_atomico(
  p_items JSONB -- Array de {producto_id, cantidad}
)
RETURNS JSONB AS $$
DECLARE
  item JSONB;
  v_producto_id INT;
  v_cantidad INT;
BEGIN
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;

    UPDATE productos
    SET stock = stock + v_cantidad
    WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql;

-- 3. FUNCIÓN: Crear pedido completo (pedido + items + descuento stock) en una transacción
CREATE OR REPLACE FUNCTION crear_pedido_completo(
  p_cliente_id INT,
  p_total DECIMAL,
  p_usuario_id UUID,
  p_notas TEXT DEFAULT NULL,
  p_forma_pago TEXT DEFAULT 'efectivo',
  p_estado_pago TEXT DEFAULT 'pendiente',
  p_items JSONB -- Array de {producto_id, cantidad, precio_unitario}
)
RETURNS JSONB AS $$
DECLARE
  v_pedido_id INT;
  item JSONB;
  v_producto_id INT;
  v_cantidad INT;
  v_precio_unitario DECIMAL;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  errores TEXT[] := '{}';
BEGIN
  -- 1. Verificar stock de todos los productos (con bloqueo)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;

    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos
    WHERE id = v_producto_id
    FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
    END IF;
  END LOOP;

  -- Si hay errores de stock, abortar
  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  -- 2. Crear el pedido
  INSERT INTO pedidos (cliente_id, total, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago)
  VALUES (p_cliente_id, p_total, 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago)
  RETURNING id INTO v_pedido_id;

  -- 3. Crear los items y descontar stock
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;

    -- Insertar item
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal)
    VALUES (v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario);

    -- Descontar stock
    UPDATE productos
    SET stock = stock - v_cantidad
    WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$$ LANGUAGE plpgsql;

-- 4. FUNCIÓN: Eliminar pedido completo (items + pedido + restaurar stock) en una transacción
CREATE OR REPLACE FUNCTION eliminar_pedido_completo(
  p_pedido_id INT,
  p_restaurar_stock BOOLEAN DEFAULT true
)
RETURNS JSONB AS $$
DECLARE
  v_stock_descontado BOOLEAN;
  item RECORD;
BEGIN
  -- Verificar si el pedido existe y obtener info de stock
  SELECT stock_descontado INTO v_stock_descontado
  FROM pedidos
  WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  -- Si hay que restaurar stock y fue descontado
  IF p_restaurar_stock AND v_stock_descontado THEN
    FOR item IN
      SELECT producto_id, cantidad
      FROM pedido_items
      WHERE pedido_id = p_pedido_id
    LOOP
      UPDATE productos
      SET stock = stock + item.cantidad
      WHERE id = item.producto_id;
    END LOOP;
  END IF;

  -- Eliminar items
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Eliminar historial si existe
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id;

  -- Eliminar pedido
  DELETE FROM pedidos WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true);
END;
$$ LANGUAGE plpgsql;

-- Comentarios de documentación
COMMENT ON FUNCTION descontar_stock_atomico IS 'Descuenta stock de múltiples productos de forma atómica, evitando race conditions';
COMMENT ON FUNCTION restaurar_stock_atomico IS 'Restaura stock de múltiples productos de forma atómica';
COMMENT ON FUNCTION crear_pedido_completo IS 'Crea un pedido con todos sus items y descuenta stock en una sola transacción';
COMMENT ON FUNCTION eliminar_pedido_completo IS 'Elimina un pedido, sus items, historial y opcionalmente restaura el stock en una sola transacción';
