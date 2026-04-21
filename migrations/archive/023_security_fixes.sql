-- =====================================================
-- MIGRACIÓN 023: Fixes de Seguridad Críticos
-- 1. Auth check en actualizar_precios_masivo
-- 2. Validación de cantidades positivas en stock RPCs
-- =====================================================

-- =============================================================================
-- FIX 1: Agregar verificación de autorización a actualizar_precios_masivo
-- PROBLEMA: Cualquier usuario autenticado podía cambiar precios
-- =============================================================================

CREATE OR REPLACE FUNCTION actualizar_precios_masivo(
  p_productos JSONB -- [{producto_id, precio_neto, imp_internos, precio_final}]
)
RETURNS JSONB AS $$
DECLARE
  v_item JSONB;
  v_actualizados INT := 0;
  v_errores TEXT[] := '{}';
  v_producto_id INT;
BEGIN
  -- SECURITY FIX: Solo admins pueden actualizar precios masivamente
  IF NOT es_admin() THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No autorizado: Solo administradores pueden actualizar precios')
    );
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)
  LOOP
    BEGIN
      v_producto_id := (v_item->>'producto_id')::INT;

      UPDATE productos
      SET
        precio_sin_iva = COALESCE((v_item->>'precio_neto')::DECIMAL, precio_sin_iva),
        impuestos_internos = COALESCE((v_item->>'imp_internos')::DECIMAL, impuestos_internos),
        precio = COALESCE((v_item->>'precio_final')::DECIMAL, precio),
        updated_at = NOW()
      WHERE id = v_producto_id;

      IF FOUND THEN
        v_actualizados := v_actualizados + 1;
      ELSE
        v_errores := array_append(v_errores,
          'Producto ID ' || v_producto_id || ' no encontrado');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errores := array_append(v_errores,
        'Error en producto ID ' || COALESCE(v_producto_id::TEXT, 'desconocido') || ': ' || SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', array_length(v_errores, 1) IS NULL,
    'actualizados', v_actualizados,
    'errores', COALESCE(to_jsonb(v_errores), '[]'::jsonb)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- FIX 2: Validar cantidades positivas en descontar_stock_atomico
-- PROBLEMA: Cantidades negativas permitían manipular stock
-- =============================================================================

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

    -- SECURITY FIX: Validar que la cantidad sea positiva
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id || ': debe ser mayor a 0');
      CONTINUE;
    END IF;

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

-- =============================================================================
-- FIX 2b: Validar cantidades positivas en restaurar_stock_atomico
-- =============================================================================

CREATE OR REPLACE FUNCTION restaurar_stock_atomico(
  p_items JSONB -- Array de {producto_id, cantidad}
)
RETURNS JSONB AS $$
DECLARE
  item JSONB;
  v_producto_id INT;
  v_cantidad INT;
  errores TEXT[] := '{}';
BEGIN
  -- Validar todas las cantidades primero
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;

    -- SECURITY FIX: Validar que la cantidad sea positiva
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id || ': debe ser mayor a 0');
    END IF;
  END LOOP;

  -- Si hay errores de validación, abortar
  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  -- Restaurar stock
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

-- =============================================================================
-- FIX 2c: Validar cantidades positivas en crear_pedido_completo
-- =============================================================================

CREATE OR REPLACE FUNCTION crear_pedido_completo(
  p_cliente_id INT,
  p_total DECIMAL,
  p_usuario_id UUID,
  p_items JSONB, -- Array de {producto_id, cantidad, precio_unitario}
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

    -- SECURITY FIX: Validar que la cantidad sea positiva
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id || ': debe ser mayor a 0');
      CONTINUE;
    END IF;

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

-- Comentarios actualizados
COMMENT ON FUNCTION actualizar_precios_masivo(JSONB) IS
'Actualiza precios de múltiples productos. SOLO ADMINS. Recibe array de {producto_id, precio_neto, imp_internos, precio_final}';

COMMENT ON FUNCTION descontar_stock_atomico IS
'Descuenta stock de múltiples productos de forma atómica. Valida cantidades positivas y evita race conditions';

COMMENT ON FUNCTION restaurar_stock_atomico IS
'Restaura stock de múltiples productos de forma atómica. Valida cantidades positivas';

COMMENT ON FUNCTION crear_pedido_completo IS
'Crea un pedido con todos sus items y descuenta stock en una sola transacción. Valida cantidades positivas';
