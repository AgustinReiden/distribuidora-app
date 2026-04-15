-- Migration 056: Fix registrar_compra_completa - restore p_tipo_factura parameter
-- Migration 051 recreated this function with security improvements but accidentally
-- dropped the p_tipo_factura parameter added in migration 046.
-- This restores it while keeping all security fixes (auth check, FOR UPDATE, SECURITY DEFINER).

-- Drop the broken version (12 params, no tipo_factura)
DROP FUNCTION IF EXISTS public.registrar_compra_completa(bigint, character varying, character varying, date, numeric, numeric, numeric, numeric, character varying, text, uuid, jsonb);

CREATE FUNCTION public.registrar_compra_completa(
  p_proveedor_id bigint,
  p_proveedor_nombre character varying,
  p_numero_factura character varying,
  p_fecha_compra date,
  p_subtotal numeric,
  p_iva numeric,
  p_otros_impuestos numeric,
  p_total numeric,
  p_forma_pago character varying,
  p_notas text,
  p_usuario_id uuid,
  p_items jsonb,
  p_tipo_factura text DEFAULT 'FC'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  v_tipo_factura TEXT;
  v_user_role TEXT;
BEGIN
  -- Auth check (from migration 051)
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  v_tipo_factura := COALESCE(p_tipo_factura, 'FC');

  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado, tipo_factura
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal,
    CASE WHEN v_tipo_factura = 'ZZ' THEN 0 ELSE p_iva END,
    p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida', v_tipo_factura
  ) RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    -- FOR UPDATE to prevent concurrent stock reads (from migration 051)
    SELECT id, stock INTO v_producto FROM productos WHERE id = (v_item->>'producto_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id'; END IF;

    v_stock_anterior := COALESCE(v_producto.stock, 0);
    v_stock_nuevo := v_stock_anterior + (v_item->>'cantidad')::INTEGER;
    v_bonificacion := COALESCE((v_item->>'bonificacion')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item->>'porcentaje_iva')::DECIMAL, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::DECIMAL, 0);

    INSERT INTO compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, bonificacion)
    VALUES (v_compra_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INTEGER,
            COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
            COALESCE((v_item->>'subtotal')::DECIMAL, 0),
            v_stock_anterior, v_stock_nuevo, v_bonificacion);

    v_costo_neto := COALESCE((v_item->>'costo_unitario')::DECIMAL, 0) * (1 - v_bonificacion / 100);

    -- Costo con IVA depende del tipo de factura (from migration 046)
    IF v_tipo_factura = 'ZZ' THEN
      v_costo_con_iva := v_costo_neto;
      v_porcentaje_iva := 0;
    ELSE
      v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    END IF;

    -- Use stock = stock + cantidad to prevent race conditions (from migration 051)
    UPDATE productos SET
      stock = stock + (v_item->>'cantidad')::INTEGER,
      costo_sin_iva = v_costo_neto,
      costo_con_iva = v_costo_con_iva,
      impuestos_internos = v_impuestos_internos,
      porcentaje_iva = v_porcentaje_iva,
      updated_at = NOW()
    WHERE id = (v_item->>'producto_id')::BIGINT;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id', (v_item->>'producto_id')::BIGINT,
      'cantidad', (v_item->>'cantidad')::INTEGER,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo', v_stock_nuevo,
      'costo_sin_iva', v_costo_neto,
      'costo_con_iva', v_costo_con_iva);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'compra_id', v_compra_id, 'items_procesados', v_items_procesados);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
