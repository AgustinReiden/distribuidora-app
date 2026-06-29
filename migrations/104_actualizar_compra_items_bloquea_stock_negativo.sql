-- ============================================================================
-- 104 · actualizar_compra_items: rechazar si la edición deja stock negativo
-- ============================================================================
-- Antes: solo AVISABA (warning) y dejaba el stock negativo (ej. MOÑO MEDIANO −12).
-- Ahora: RAISE → el EXCEPTION WHEN OTHERS revierte toda la edición y devuelve el
-- error (mismo invariante que descontar_stock_atomico).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_compra_items(p_compra_id bigint, p_items_nuevos jsonb, p_subtotal numeric, p_iva numeric, p_total numeric, p_usuario_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  PERFORM set_config('app.stock_origen', 'compra_editada', true);
  PERFORM set_config('app.stock_ref_tipo', 'compra', true);
  PERFORM set_config('app.stock_ref_id', p_compra_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

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

  -- Invariante de no-negatividad: si la edición dejaría stock negativo, RECHAZAR
  -- (el EXCEPTION WHEN OTHERS revierte todo). Antes solo avisaba y dejaba el negativo.
  IF v_warnings_stock_negativo IS NOT NULL AND jsonb_array_length(v_warnings_stock_negativo) > 0 THEN
    RAISE EXCEPTION 'La edición dejaría stock negativo en: %. Ajustá las cantidades o reconciliá el stock primero.',
      (SELECT string_agg((w->>'nombre') || ' (' || (w->>'stock') || ')', ', ')
         FROM jsonb_array_elements(v_warnings_stock_negativo) w);
  END IF;

  DELETE FROM compra_items WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

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

    v_costo_neto := v_costo_unitario * (1 - v_bonificacion / 100);
    IF v_compra.tipo_factura = 'ZZ' THEN
      v_costo_con_iva  := v_costo_neto;
      v_porcentaje_iva := 0;
    ELSE
      v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    END IF;

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

  UPDATE compras
     SET subtotal = p_subtotal,
         iva = v_iva_efectivo,
         total = p_total,
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  v_warnings := NULL;

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
$function$;
