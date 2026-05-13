-- ============================================================================
-- 046 — actualizar_compra_items: edicion de items de compra por admin
-- ============================================================================
-- Permite que un admin edite los items (cantidad, costo, bonificacion,
-- porcentaje_iva, impuestos_internos) de una compra dentro de los 7 dias
-- desde su creacion.
--
-- Reglas:
--   - Solo rol 'admin' (encargado NO puede editar compras existentes).
--   - Estado != 'cancelada'.
--   - now() - created_at <= 7 dias.
--   - La cabecera (proveedor, fecha_compra, numero_factura, tipo_factura,
--     forma_pago, notas) queda inmutable. Solo se editan items y totales.
--
-- Efectos:
--   1) Revertir el stock que sumo cada item original al producto.
--   2) Borrar los compra_items actuales.
--   3) Insertar los nuevos compra_items + sumar el stock nuevo al producto.
--   4) Para cada producto editado, verificar si ESTA compra es la mas
--      reciente del producto (por compras.fecha_compra entre compras no
--      canceladas). Si lo es, actualizar productos.costo_sin_iva,
--      costo_con_iva, impuestos_internos y porcentaje_iva con el valor del
--      item editado. Si hay compras posteriores del mismo producto, NO se
--      pisa el costo (se asume que el costo del producto refleja la compra
--      mas reciente).
--   5) Actualizar compras.subtotal/iva/total con los totales recalculados
--      por el frontend (mismo patron que registrar_compra_completa, que
--      tampoco recalcula totales server-side).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_compra_items(
  p_compra_id BIGINT,
  p_items_nuevos JSONB,
  p_subtotal NUMERIC,
  p_iva NUMERIC,
  p_total NUMERIC,
  p_usuario_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_user_role TEXT;
  v_compra RECORD;
  v_dias NUMERIC;
  v_item JSONB;
  v_old_item RECORD;
  v_producto_id BIGINT;
  v_cantidad INTEGER;
  v_costo_unitario NUMERIC;
  v_bonificacion NUMERIC;
  v_porcentaje_iva NUMERIC;
  v_impuestos_internos NUMERIC;
  v_subtotal_item NUMERIC;
  v_costo_neto NUMERIC;
  v_costo_con_iva NUMERIC;
  v_stock_anterior INTEGER;
  v_stock_nuevo INTEGER;
  v_max_fecha DATE;
  v_es_mas_reciente BOOLEAN;
  v_iva_efectivo NUMERIC;
  v_items_procesados JSONB := '[]'::JSONB;
  v_costo_actualizado JSONB := '[]'::JSONB;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede editar compras');
  END IF;

  SELECT id, estado, tipo_factura, created_at, fecha_compra
    INTO v_compra
    FROM compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;

  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede editar una compra cancelada');
  END IF;

  v_dias := EXTRACT(EPOCH FROM (now() - v_compra.created_at)) / 86400;
  IF v_dias > 7 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se puede editar una compra creada hace mas de 7 dias');
  END IF;

  -- Si la compra es ZZ, fuerzo IVA total a 0 (sigue el patron de
  -- registrar_compra_completa).
  v_iva_efectivo := CASE WHEN v_compra.tipo_factura = 'ZZ' THEN 0 ELSE p_iva END;

  -- 1) Revertir stock de items actuales.
  FOR v_old_item IN
    SELECT producto_id, cantidad
      FROM compra_items
     WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
  LOOP
    UPDATE productos
       SET stock = GREATEST(stock - v_old_item.cantidad, 0),
           updated_at = NOW()
     WHERE id = v_old_item.producto_id AND sucursal_id = v_sucursal;
  END LOOP;

  -- 2) Borrar items actuales.
  DELETE FROM compra_items WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

  -- 3) Insertar items nuevos + sumar stock.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id        := (v_item->>'producto_id')::BIGINT;
    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_costo_unitario     := COALESCE((v_item->>'costo_unitario')::NUMERIC, 0);
    v_bonificacion       := COALESCE((v_item->>'bonificacion')::NUMERIC, 0);
    v_porcentaje_iva     := COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::NUMERIC, 0);
    v_subtotal_item      := COALESCE((v_item->>'subtotal')::NUMERIC, 0);

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      RAISE EXCEPTION 'Cantidad invalida para producto %', v_producto_id;
    END IF;

    SELECT stock INTO v_stock_anterior
      FROM productos
     WHERE id = v_producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;
    IF v_stock_anterior IS NULL THEN
      RAISE EXCEPTION 'Producto no encontrado: %', v_producto_id;
    END IF;
    v_stock_nuevo := v_stock_anterior + v_cantidad;

    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal
    );

    UPDATE productos
       SET stock = stock + v_cantidad,
           updated_at = NOW()
     WHERE id = v_producto_id AND sucursal_id = v_sucursal;

    -- Calculo de costos efectivos del item.
    v_costo_neto := v_costo_unitario * (1 - v_bonificacion / 100);
    IF v_compra.tipo_factura = 'ZZ' THEN
      v_costo_con_iva  := v_costo_neto;
      v_porcentaje_iva := 0;
    ELSE
      v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    END IF;

    -- 4) Solo se pisa productos.costo si esta compra es la mas reciente
    -- del producto (entre compras no canceladas, excluyendo esta misma).
    SELECT MAX(c.fecha_compra) INTO v_max_fecha
      FROM compras c
      JOIN compra_items ci ON ci.compra_id = c.id AND ci.sucursal_id = c.sucursal_id
     WHERE ci.producto_id = v_producto_id
       AND ci.sucursal_id = v_sucursal
       AND c.estado <> 'cancelada'
       AND c.id <> p_compra_id;

    v_es_mas_reciente := (v_max_fecha IS NULL) OR (v_compra.fecha_compra >= v_max_fecha);

    IF v_es_mas_reciente THEN
      UPDATE productos
         SET costo_sin_iva      = v_costo_neto,
             costo_con_iva      = v_costo_con_iva,
             impuestos_internos = v_impuestos_internos,
             porcentaje_iva     = v_porcentaje_iva,
             updated_at         = NOW()
       WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_costo_actualizado := v_costo_actualizado || jsonb_build_object(
        'producto_id', v_producto_id,
        'costo_sin_iva', v_costo_neto,
        'costo_con_iva', v_costo_con_iva
      );
    END IF;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id', v_producto_id,
      'cantidad', v_cantidad,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo', v_stock_nuevo,
      'costo_actualizado', v_es_mas_reciente
    );
  END LOOP;

  -- 5) Actualizar totales de la compra.
  UPDATE compras
     SET subtotal = p_subtotal,
         iva = v_iva_efectivo,
         total = p_total,
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
    'items_procesados', v_items_procesados,
    'costo_actualizado', v_costo_actualizado
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
