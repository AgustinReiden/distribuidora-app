-- Migration 034: Auto-actualizar costos de producto al registrar compra
-- Modifica registrar_compra_completa para que al registrar una compra,
-- actualice automáticamente costo_sin_iva, costo_con_iva e impuestos_internos
-- del producto con los valores de la última compra (costo neto con bonificación).

CREATE OR REPLACE FUNCTION registrar_compra_completa(
  p_proveedor_id BIGINT DEFAULT NULL,
  p_proveedor_nombre VARCHAR DEFAULT NULL,
  p_numero_factura VARCHAR DEFAULT NULL,
  p_fecha_compra DATE DEFAULT CURRENT_DATE,
  p_subtotal DECIMAL DEFAULT 0,
  p_iva DECIMAL DEFAULT 0,
  p_otros_impuestos DECIMAL DEFAULT 0,
  p_total DECIMAL DEFAULT 0,
  p_forma_pago VARCHAR DEFAULT 'efectivo',
  p_notas TEXT DEFAULT NULL,
  p_usuario_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT '[]'
)
RETURNS JSONB AS $$
DECLARE
  v_compra_id BIGINT;
  v_item JSONB;
  v_producto RECORD;
  v_stock_anterior INTEGER;
  v_stock_nuevo INTEGER;
  v_items_procesados JSONB := '[]'::JSONB;
  v_costo_neto DECIMAL;
  v_costo_con_iva DECIMAL;
  v_porcentaje_iva DECIMAL;
  v_impuestos_internos DECIMAL;
  v_bonificacion DECIMAL;
BEGIN
  -- Crear la compra
  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida'
  ) RETURNING id INTO v_compra_id;

  -- Procesar cada item
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    -- Obtener stock actual del producto
    SELECT id, stock INTO v_producto
    FROM productos
    WHERE id = (v_item->>'producto_id')::BIGINT;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id';
    END IF;

    v_stock_anterior := COALESCE(v_producto.stock, 0);
    v_stock_nuevo := v_stock_anterior + (v_item->>'cantidad')::INTEGER;

    -- Insertar item de compra
    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion
    ) VALUES (
      v_compra_id,
      (v_item->>'producto_id')::BIGINT,
      (v_item->>'cantidad')::INTEGER,
      COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
      COALESCE((v_item->>'subtotal')::DECIMAL, 0),
      v_stock_anterior,
      v_stock_nuevo,
      COALESCE((v_item->>'bonificacion')::DECIMAL, 0)
    );

    -- Calcular costos netos para actualizar el producto
    v_bonificacion := COALESCE((v_item->>'bonificacion')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item->>'porcentaje_iva')::DECIMAL, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::DECIMAL, 0);

    -- Costo neto = costo unitario con bonificación aplicada
    v_costo_neto := COALESCE((v_item->>'costo_unitario')::DECIMAL, 0) * (1 - v_bonificacion / 100);
    -- Costo con IVA
    v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);

    -- Actualizar stock Y costos del producto
    UPDATE productos
    SET stock = v_stock_nuevo,
        costo_sin_iva = v_costo_neto,
        costo_con_iva = v_costo_con_iva,
        impuestos_internos = v_impuestos_internos,
        porcentaje_iva = v_porcentaje_iva,
        updated_at = NOW()
    WHERE id = (v_item->>'producto_id')::BIGINT;

    -- Agregar a items procesados
    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id', (v_item->>'producto_id')::BIGINT,
      'cantidad', (v_item->>'cantidad')::INTEGER,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo', v_stock_nuevo,
      'costo_sin_iva', v_costo_neto,
      'costo_con_iva', v_costo_con_iva
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', v_compra_id,
    'items_procesados', v_items_procesados
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
