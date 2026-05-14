-- ============================================================================
-- 048 — actualizar_compra_items: fix doble carga de stock al editar
-- ============================================================================
-- Reemplaza la version de la migracion 046, que duplicaba stock cuando se
-- editaba una compra cuyo stock original ya habia sido consumido.
--
-- Bug en 046 (linea 108):
--   UPDATE productos SET stock = GREATEST(stock - v_old_item.cantidad, 0) ...
-- El GREATEST(_, 0) truncaba la "deuda" negativa cuando el stock ya estaba
-- en 0 (porque se vendio). Luego sumar la cantidad nueva (linea 147-150)
-- duplicaba el stock.
--
-- Ejemplo del bug:
--   1) Compra original: 31 azucares -> stock 0 -> 31
--   2) Pedido consume los 31 -> stock 31 -> 0
--   3) Usuaria edita compra solo para corregir precio (cantidad sigue en 31)
--   4) Reversion: GREATEST(0 - 31, 0) = 0 (no -31)
--   5) Insert nuevo item +31 -> stock = 0 + 31 = 31 (DUPLICADO)
--
-- Fix: aplicar delta = cantidad_nueva - cantidad_vieja por producto en un solo
-- UPDATE, sin GREATEST. Si una compra cuyo stock ya se consumio se edita sin
-- cambiar cantidad, delta=0 y el stock queda igual (correcto).
--
-- Stock negativo: si el delta deja el stock < 0 (escenario donde se vendio
-- mas de lo que realmente entro por compras), devolvemos warning en el
-- payload pero NO bloqueamos. Permite corregir y refleja la realidad
-- contable.
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
  v_snapshot_stock JSONB := '{}'::JSONB;
  v_warnings_stock_negativo JSONB;
  v_warnings JSONB;
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

  v_iva_efectivo := CASE WHEN v_compra.tipo_factura = 'ZZ' THEN 0 ELSE p_iva END;

  -- =========================================================================
  -- 1) Contexto para trigger registrar_cambio_stock (mig 038).
  -- =========================================================================
  PERFORM set_config('app.stock_origen', 'compra_editada', true);
  PERFORM set_config('app.stock_ref_tipo', 'compra', true);
  PERFORM set_config('app.stock_ref_id', p_compra_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

  -- =========================================================================
  -- 2) Lock pesimista en orden de id (deadlock-safe) sobre todos los
  --    productos involucrados (viejos + nuevos).
  -- =========================================================================
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     )
   ORDER BY id
   FOR UPDATE;

  -- =========================================================================
  -- 3) Snapshot del stock pre-edicion para auditoria en compra_items.
  -- =========================================================================
  SELECT jsonb_object_agg(id::text, stock) INTO v_snapshot_stock
    FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     );

  -- =========================================================================
  -- 4) Aplicar delta = qty_nueva - qty_vieja en un solo UPDATE.
  --    No usa GREATEST: si el resultado es negativo, queda negativo y se
  --    reporta como warning.
  -- =========================================================================
  WITH viejos AS (
    SELECT producto_id, SUM(cantidad)::INT AS qty_old
      FROM compra_items
     WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     GROUP BY producto_id
  ),
  nuevos AS (
    SELECT (item->>'producto_id')::BIGINT AS producto_id,
           SUM((item->>'cantidad')::INT)::INT AS qty_new
      FROM jsonb_array_elements(p_items_nuevos) AS item
     GROUP BY (item->>'producto_id')::BIGINT
  ),
  deltas AS (
    SELECT COALESCE(v.producto_id, n.producto_id) AS producto_id,
           COALESCE(n.qty_new, 0) - COALESCE(v.qty_old, 0) AS delta
      FROM viejos v FULL OUTER JOIN nuevos n USING (producto_id)
  )
  UPDATE productos p
     SET stock = p.stock + d.delta,
         updated_at = NOW()
    FROM deltas d
   WHERE p.id = d.producto_id
     AND p.sucursal_id = v_sucursal
     AND d.delta <> 0;

  -- =========================================================================
  -- 5) Capturar productos con stock negativo (warning, no bloquea).
  -- =========================================================================
  SELECT jsonb_agg(jsonb_build_object('producto_id', id, 'nombre', nombre, 'stock', stock))
    INTO v_warnings_stock_negativo
    FROM productos
   WHERE sucursal_id = v_sucursal
     AND stock < 0
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     );

  -- =========================================================================
  -- 6) Borrar items viejos (el stock ya fue actualizado por delta).
  -- =========================================================================
  DELETE FROM compra_items WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

  -- =========================================================================
  -- 7) Insertar items nuevos. stock_anterior/nuevo del item se calculan
  --    desde el snapshot pre-edicion (semantica: "este item contribuye con
  --    N al stock que habia antes de editar"). El UPDATE de stock global ya
  --    se hizo en el paso 4 via delta.
  -- =========================================================================
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

    v_stock_anterior := COALESCE((v_snapshot_stock->>v_producto_id::TEXT)::INTEGER, 0);
    v_stock_nuevo := v_stock_anterior + v_cantidad;

    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal
    );

    -- Costos efectivos del item.
    v_costo_neto := v_costo_unitario * (1 - v_bonificacion / 100);
    IF v_compra.tipo_factura = 'ZZ' THEN
      v_costo_con_iva  := v_costo_neto;
      v_porcentaje_iva := 0;
    ELSE
      v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    END IF;

    -- Solo se pisa productos.costo si esta compra es la mas reciente
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

  -- =========================================================================
  -- 8) Actualizar totales de la compra.
  -- =========================================================================
  UPDATE compras
     SET subtotal = p_subtotal,
         iva = v_iva_efectivo,
         total = p_total,
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  v_warnings := CASE
    WHEN v_warnings_stock_negativo IS NOT NULL
     AND jsonb_array_length(v_warnings_stock_negativo) > 0
    THEN jsonb_build_object('stock_negativo', v_warnings_stock_negativo)
    ELSE NULL
  END;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
    'items_procesados', v_items_procesados,
    'costo_actualizado', v_costo_actualizado,
    'warnings', v_warnings
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
