-- =====================================================
-- MIGRACIÓN 009: Corrección de parámetros crear_pedido_completo
-- Corrige el error "Producto ID X no encontrado" causado por orden incorrecto de parámetros
-- =====================================================

-- PROBLEMA: En PostgreSQL, los parámetros sin valor DEFAULT deben ir ANTES
-- de los parámetros con DEFAULT. La función original tenía p_items (sin DEFAULT)
-- como último parámetro, después de p_notas, p_forma_pago y p_estado_pago (todos con DEFAULT).
-- Esto causaba que al llamar la función por posición, los valores se asignaran incorrectamente.

-- SOLUCIÓN: Mover p_items a la 4ta posición (después de p_usuario_id, antes de los DEFAULTs)

-- Primero eliminamos la función existente (si existe) para recrearla con el orden correcto
DROP FUNCTION IF EXISTS crear_pedido_completo(INT, DECIMAL, UUID, TEXT, TEXT, TEXT, JSONB);

-- Recrear la función con el orden correcto de parámetros
CREATE OR REPLACE FUNCTION crear_pedido_completo(
  p_cliente_id INT,
  p_total DECIMAL,
  p_usuario_id UUID,
  p_items JSONB, -- Array de {producto_id, cantidad, precio_unitario} - AHORA EN 4TA POSICIÓN
  p_notas TEXT DEFAULT NULL,
  p_forma_pago TEXT DEFAULT 'efectivo',
  p_estado_pago TEXT DEFAULT 'pendiente'
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

-- Actualizar comentario de documentación
COMMENT ON FUNCTION crear_pedido_completo IS 'Crea un pedido con todos sus items y descuenta stock en una sola transacción. IMPORTANTE: p_items debe ser el 4to parámetro (antes de parámetros con DEFAULT)';
