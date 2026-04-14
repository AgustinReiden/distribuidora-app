-- Migration 046: Actualizar RPCs para soporte de tipo_factura (ZZ/FC)
--
-- Cambios:
--   1. crear_pedido_completo: nuevo param p_tipo_factura, almacena desglose neto/iva
--   2. actualizar_pedido_items: almacena desglose neto/iva en items y recalcula totales
--   3. registrar_compra_completa: nuevo param p_tipo_factura, maneja ZZ sin IVA

-- =============================================================================
-- 1. DROP old overload de crear_pedido_completo (8 params)
-- =============================================================================

DROP FUNCTION IF EXISTS public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date);

-- =============================================================================
-- 2. crear_pedido_completo con tipo_factura
-- =============================================================================

CREATE OR REPLACE FUNCTION public.crear_pedido_completo(
  p_cliente_id bigint,
  p_total numeric,
  p_usuario_id uuid,
  p_items jsonb,
  p_notas text DEFAULT NULL::text,
  p_forma_pago text DEFAULT 'efectivo'::text,
  p_estado_pago text DEFAULT 'pendiente'::text,
  p_fecha date DEFAULT CURRENT_DATE,
  p_tipo_factura text DEFAULT 'ZZ',
  p_total_neto numeric DEFAULT NULL,
  p_total_iva numeric DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pedido_id INT;
  item JSONB;
  v_producto_id INT;
  v_cantidad INT;
  v_precio_unitario DECIMAL;
  v_es_bonificacion BOOLEAN;
  v_promocion_id BIGINT;
  v_neto_unitario DECIMAL;
  v_iva_unitario DECIMAL;
  v_imp_internos_unitario DECIMAL;
  v_porcentaje_iva DECIMAL;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
  v_cantidades_totales JSONB := '{}'::JSONB;
  v_cant_acumulada INT;
BEGIN
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos'));
  END IF;

  -- 1. Acumular cantidades totales por producto (SOLO items no bonificados)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id || ': debe ser mayor a 0');
      CONTINUE;
    END IF;

    IF NOT v_es_bonificacion THEN
      v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
      v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
    END IF;
  END LOOP;

  -- 2. Verificar stock usando cantidades acumuladas (con bloqueo)
  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales)
  LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;

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

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  -- 3. Crear el pedido con tipo_factura y desglose
  INSERT INTO pedidos (
    cliente_id, fecha, total, total_neto, total_iva, tipo_factura,
    estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago
  )
  VALUES (
    p_cliente_id, p_fecha, p_total,
    COALESCE(p_total_neto, p_total), -- Si no viene, asumir ZZ donde neto=total
    COALESCE(p_total_iva, 0),
    COALESCE(p_tipo_factura, 'ZZ'),
    'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago
  )
  RETURNING id INTO v_pedido_id;

  -- 4. Crear items y descontar stock
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_neto_unitario := (item->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((item->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((item->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((item->>'porcentaje_iva')::DECIMAL, 0);

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva
    )
    VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario,
      v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva
    );

    -- Stock: solo descontar si NO es bonificación
    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id;
    END IF;

    -- Contador de promos
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad
      WHERE id = v_promocion_id;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- =============================================================================
-- 3. actualizar_pedido_items con soporte tipo_factura
-- =============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(
  p_pedido_id BIGINT,
  p_items_nuevos JSONB,
  p_usuario_id UUID DEFAULT NULL,
  p_tipo_factura text DEFAULT NULL,
  p_total_neto numeric DEFAULT NULL,
  p_total_iva numeric DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item_original RECORD;
  v_item_nuevo JSONB;
  v_producto_id INT;
  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_precio_unitario DECIMAL;
  v_es_bonificacion BOOLEAN;
  v_promocion_id BIGINT;
  v_neto_unitario DECIMAL;
  v_iva_unitario DECIMAL;
  v_imp_internos_unitario DECIMAL;
  v_porcentaje_iva_item DECIMAL;
  v_diferencia INT;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_total_nuevo DECIMAL := 0;
  v_total_anterior DECIMAL;
  v_errores TEXT[] := '{}';
  v_items_originales JSONB;
  v_cantidades_nuevas JSONB := '{}'::JSONB;
  v_cantidades_originales JSONB := '{}'::JSONB;
  v_cant_acum INT;
BEGIN
  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- Guardar items originales para historial
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id,
    'cantidad', cantidad,
    'precio_unitario', precio_unitario,
    'es_bonificacion', es_bonificacion
  )) INTO v_items_originales
  FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Revertir usos_pendientes de bonificaciones anteriores
  FOR v_item_original IN
    SELECT promocion_id, cantidad FROM pedido_items
    WHERE pedido_id = p_pedido_id AND es_bonificacion = true AND promocion_id IS NOT NULL
  LOOP
    UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_item_original.cantidad, 0)
    WHERE id = v_item_original.promocion_id;
  END LOOP;

  -- Acumular cantidades originales por producto (solo NO bonificación)
  FOR v_item_original IN
    SELECT producto_id, SUM(cantidad) as cant_total
    FROM pedido_items WHERE pedido_id = p_pedido_id AND (es_bonificacion IS NULL OR es_bonificacion = false)
    GROUP BY producto_id
  LOOP
    v_cantidades_originales := v_cantidades_originales || jsonb_build_object(
      v_item_original.producto_id::TEXT, v_item_original.cant_total
    );
  END LOOP;

  -- Acumular cantidades nuevas por producto (solo NO bonificación)
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos)
  LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);

    IF NOT v_es_bonificacion THEN
      v_cant_acum := COALESCE((v_cantidades_nuevas->>v_producto_id::TEXT)::INT, 0) + v_cantidad_nueva;
      v_cantidades_nuevas := v_cantidades_nuevas || jsonb_build_object(v_producto_id::TEXT, v_cant_acum);
    END IF;
  END LOOP;

  -- Validar stock para incrementos
  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_nuevas)
  LOOP
    v_cantidad_nueva := (v_cantidades_nuevas->>v_producto_id::TEXT)::INT;
    v_cantidad_original := COALESCE((v_cantidades_originales->>v_producto_id::TEXT)::INT, 0);
    v_diferencia := v_cantidad_nueva - v_cantidad_original;

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id FOR UPDATE;

      IF v_stock_actual IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_producto_id || ' no encontrado');
      ELSIF v_stock_actual < v_diferencia THEN
        v_errores := array_append(v_errores,
          COALESCE(v_producto_nombre, 'Producto ' || v_producto_id) ||
          ': stock insuficiente (disponible: ' || v_stock_actual ||
          ', adicional requerido: ' || v_diferencia || ')');
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  -- Restaurar stock de items originales (solo NO bonificación)
  FOR v_item_original IN
    SELECT producto_id, cantidad FROM pedido_items
    WHERE pedido_id = p_pedido_id AND (es_bonificacion IS NULL OR es_bonificacion = false)
  LOOP
    UPDATE productos SET stock = stock + v_item_original.cantidad
    WHERE id = v_item_original.producto_id;
  END LOOP;

  -- Eliminar items actuales
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Insertar nuevos items con desglose fiscal
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos)
  LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;
    v_neto_unitario := (v_item_nuevo->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((v_item_nuevo->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((v_item_nuevo->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva_item := COALESCE((v_item_nuevo->>'porcentaje_iva')::DECIMAL, 0);

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva
    )
    VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva_item
    );

    IF NOT v_es_bonificacion THEN
      v_total_nuevo := v_total_nuevo + v_cantidad_nueva * v_precio_unitario;
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id;
    END IF;

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva
      WHERE id = v_promocion_id;
    END IF;
  END LOOP;

  -- Actualizar pedido con total y desglose fiscal
  UPDATE pedidos SET
    total = v_total_nuevo,
    tipo_factura = COALESCE(p_tipo_factura, tipo_factura),
    total_neto = COALESCE(p_total_neto, v_total_nuevo),
    total_iva = COALESCE(p_total_iva, 0),
    updated_at = NOW()
  WHERE id = p_pedido_id;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT);

  IF v_total_anterior <> v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$function$;

-- =============================================================================
-- 4. registrar_compra_completa con tipo_factura
-- =============================================================================

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
  p_items JSONB DEFAULT '[]',
  p_tipo_factura TEXT DEFAULT 'FC'
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
  v_tipo_factura TEXT;
BEGIN
  v_tipo_factura := COALESCE(p_tipo_factura, 'FC');

  -- Crear la compra
  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado, tipo_factura
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal,
    CASE WHEN v_tipo_factura = 'ZZ' THEN 0 ELSE p_iva END,
    p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida', v_tipo_factura
  ) RETURNING id INTO v_compra_id;

  -- Procesar cada item
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
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

    -- Costo con IVA depende del tipo de factura
    IF v_tipo_factura = 'ZZ' THEN
      -- ZZ: no hay IVA discriminado, costo_con_iva = costo_sin_iva (el IVA no existe)
      v_costo_con_iva := v_costo_neto;
      v_porcentaje_iva := 0;
    ELSE
      -- FC: IVA discriminado normalmente
      v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    END IF;

    -- Actualizar stock Y costos del producto
    UPDATE productos
    SET stock = v_stock_nuevo,
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
