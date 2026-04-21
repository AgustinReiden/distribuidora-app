-- Fix registrar_compra_completa: intentaba insertar porcentaje_iva/impuestos_internos
-- en compra_items, pero esas columnas nunca se agregaron a la tabla. Además, la
-- versión de 060_multi_tenant_fixups.sql regresionó la lógica de costos:
--   - no guardaba stock_anterior/stock_nuevo
--   - no actualizaba costo_sin_iva/costo_con_iva/porcentaje_iva/impuestos_internos en productos
--   - no aplicaba IVA 0 para tipo_factura = 'ZZ'
--   - no hacía FOR UPDATE ni chequeo de rol
--
-- Este fix recompone el comportamiento correcto manteniendo el aislamiento
-- multi-sucursal y devuelve items_procesados como antes.

CREATE OR REPLACE FUNCTION public.registrar_compra_completa(
  p_proveedor_id      BIGINT,
  p_proveedor_nombre  VARCHAR,
  p_numero_factura    VARCHAR,
  p_fecha_compra      DATE,
  p_subtotal          NUMERIC,
  p_iva               NUMERIC,
  p_otros_impuestos   NUMERIC,
  p_total             NUMERIC,
  p_forma_pago        VARCHAR,
  p_notas             TEXT,
  p_usuario_id        UUID,
  p_items             JSONB,
  p_tipo_factura      VARCHAR DEFAULT 'FC'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal            BIGINT := current_sucursal_id();
  v_compra_id           BIGINT;
  v_item                JSONB;
  v_producto            RECORD;
  v_stock_anterior      INTEGER;
  v_stock_nuevo         INTEGER;
  v_cantidad            INTEGER;
  v_bonificacion        NUMERIC;
  v_porcentaje_iva      NUMERIC;
  v_impuestos_internos  NUMERIC;
  v_costo_unitario      NUMERIC;
  v_costo_neto          NUMERIC;
  v_costo_con_iva       NUMERIC;
  v_tipo_factura        TEXT;
  v_items_procesados    JSONB := '[]'::JSONB;
  v_user_role           TEXT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  v_tipo_factura := COALESCE(p_tipo_factura, 'FC');

  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, otros_impuestos, total, forma_pago, notas,
    usuario_id, estado, tipo_factura, sucursal_id
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal,
    CASE WHEN v_tipo_factura = 'ZZ' THEN 0 ELSE p_iva END,
    p_otros_impuestos, p_total, p_forma_pago, p_notas,
    p_usuario_id, 'recibida', v_tipo_factura, v_sucursal
  )
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id, stock INTO v_producto
      FROM productos
     WHERE id = (v_item->>'producto_id')::BIGINT
       AND sucursal_id = v_sucursal
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id';
    END IF;

    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_stock_anterior     := COALESCE(v_producto.stock, 0);
    v_stock_nuevo        := v_stock_anterior + v_cantidad;
    v_costo_unitario     := COALESCE((v_item->>'costo_unitario')::NUMERIC, 0);
    v_bonificacion       := COALESCE((v_item->>'bonificacion')::NUMERIC, 0);
    v_porcentaje_iva     := COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::NUMERIC, 0);

    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id
    ) VALUES (
      v_compra_id,
      (v_item->>'producto_id')::BIGINT,
      v_cantidad,
      v_costo_unitario,
      COALESCE((v_item->>'subtotal')::NUMERIC, 0),
      v_stock_anterior,
      v_stock_nuevo,
      v_bonificacion,
      v_sucursal
    );

    v_costo_neto := v_costo_unitario * (1 - v_bonificacion / 100);

    IF v_tipo_factura = 'ZZ' THEN
      v_costo_con_iva  := v_costo_neto;
      v_porcentaje_iva := 0;
    ELSE
      v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    END IF;

    UPDATE productos
       SET stock              = stock + v_cantidad,
           costo_sin_iva      = v_costo_neto,
           costo_con_iva      = v_costo_con_iva,
           impuestos_internos = v_impuestos_internos,
           porcentaje_iva     = v_porcentaje_iva,
           updated_at         = NOW()
     WHERE id = (v_item->>'producto_id')::BIGINT
       AND sucursal_id = v_sucursal;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id',    (v_item->>'producto_id')::BIGINT,
      'cantidad',       v_cantidad,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo',    v_stock_nuevo,
      'costo_sin_iva',  v_costo_neto,
      'costo_con_iva',  v_costo_con_iva
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success',          true,
    'compra_id',        v_compra_id,
    'items_procesados', v_items_procesados
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
