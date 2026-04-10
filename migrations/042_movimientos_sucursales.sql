-- ============================================================================
-- 042: Movimientos entre Sucursales - soporte ingreso desde sucursal
-- ============================================================================

-- 1. Agregar columna tipo a transferencias_stock
ALTER TABLE transferencias_stock
ADD COLUMN IF NOT EXISTS tipo VARCHAR(20) NOT NULL DEFAULT 'salida';

-- 2. RPC para registrar ingreso desde sucursal (aumenta stock)
CREATE OR REPLACE FUNCTION public.registrar_ingreso_sucursal(
  p_sucursal_id BIGINT,
  p_fecha DATE DEFAULT CURRENT_DATE,
  p_notas TEXT DEFAULT NULL,
  p_total_costo DECIMAL DEFAULT 0,
  p_usuario_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT '[]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trans_id BIGINT;
  v_item JSONB;
  v_stock_actual INTEGER;
  v_producto_id BIGINT;
  v_cantidad INTEGER;
  v_costo DECIMAL;
  v_sub DECIMAL;
BEGIN
  INSERT INTO transferencias_stock (sucursal_id, fecha, notas, total_costo, usuario_id, tipo)
  VALUES (p_sucursal_id, p_fecha, p_notas, p_total_costo, p_usuario_id, 'ingreso')
  RETURNING id INTO v_trans_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (v_item->>'producto_id')::BIGINT;
    v_cantidad := (v_item->>'cantidad')::INTEGER;
    v_costo := (v_item->>'costo_unitario')::DECIMAL;
    v_sub := (v_item->>'subtotal')::DECIMAL;

    SELECT stock INTO v_stock_actual FROM productos WHERE id = v_producto_id FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      RAISE EXCEPTION 'Producto % no encontrado', v_producto_id;
    END IF;

    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo)
    VALUES (v_trans_id, v_producto_id, v_cantidad, v_costo, v_sub, v_stock_actual, v_stock_actual + v_cantidad);

    UPDATE productos SET stock = v_stock_actual + v_cantidad WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_trans_id);
END;
$$;

COMMENT ON FUNCTION registrar_ingreso_sucursal IS 'Registra un ingreso de stock desde una sucursal (aumenta stock central)';
