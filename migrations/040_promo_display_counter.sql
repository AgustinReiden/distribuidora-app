-- Migración 040: Mejoras de display y contador de promos
--
-- Cambios:
--   1. Agregar columna promocion_id a pedido_items para trazabilidad
--   2. Agregar columna producto_regalo_id a promociones (producto que se regala)
--   3. Actualizar RPCs para incluir promocion_id en INSERT y usar v_cantidad en contador

-- =============================================================================
-- 1. Agregar promocion_id a pedido_items
-- =============================================================================

ALTER TABLE pedido_items ADD COLUMN IF NOT EXISTS promocion_id BIGINT REFERENCES promociones(id) ON DELETE SET NULL;

-- =============================================================================
-- 2. Agregar producto_regalo_id a promociones
-- =============================================================================

ALTER TABLE promociones ADD COLUMN IF NOT EXISTS producto_regalo_id BIGINT REFERENCES productos(id) ON DELETE SET NULL;
COMMENT ON COLUMN promociones.producto_regalo_id IS 'Producto específico que se regala en la bonificación (si NULL, se usa el primer producto del pedido)';

-- =============================================================================
-- 2. RPC crear_pedido_completo — incluir promocion_id + contador por cantidad
-- =============================================================================

CREATE OR REPLACE FUNCTION public.crear_pedido_completo(
  p_cliente_id bigint,
  p_total numeric,
  p_usuario_id uuid,
  p_items jsonb,
  p_notas text DEFAULT NULL::text,
  p_forma_pago text DEFAULT 'efectivo'::text,
  p_estado_pago text DEFAULT 'pendiente'::text,
  p_fecha date DEFAULT CURRENT_DATE
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

  -- 3. Crear el pedido
  INSERT INTO pedidos (cliente_id, fecha, total, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago)
  VALUES (p_cliente_id, p_fecha, p_total, 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago)
  RETURNING id INTO v_pedido_id;

  -- 4. Crear items y descontar stock (solo para items no bonificados)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;

    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id)
    VALUES (
      v_pedido_id,
      v_producto_id,
      v_cantidad,
      v_precio_unitario,
      v_cantidad * v_precio_unitario,
      v_es_bonificacion,
      v_promocion_id
    );

    -- Stock: solo descontar si NO es bonificación
    IF NOT v_es_bonificacion THEN
      UPDATE productos
      SET stock = stock - v_cantidad
      WHERE id = v_producto_id;
    END IF;

    -- Contador: incrementar por cantidad de unidades bonificadas
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad
      WHERE id = v_promocion_id;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- =============================================================================
-- 3. RPC actualizar_pedido_items — incluir promocion_id + contador por cantidad
-- =============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(
  p_pedido_id BIGINT,
  p_items_nuevos JSONB,
  p_usuario_id UUID DEFAULT NULL
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

  -- Insertar nuevos items
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos)
  LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id)
    VALUES (
      p_pedido_id,
      v_producto_id,
      v_cantidad_nueva,
      v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion,
      v_promocion_id
    );

    -- Solo sumar al total si NO es bonificación
    IF NOT v_es_bonificacion THEN
      v_total_nuevo := v_total_nuevo + v_cantidad_nueva * v_precio_unitario;
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id;
    END IF;

    -- Contador: incrementar por cantidad de unidades bonificadas
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva
      WHERE id = v_promocion_id;
    END IF;
  END LOOP;

  UPDATE pedidos SET total = v_total_nuevo, updated_at = NOW() WHERE id = p_pedido_id;

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
-- 4. Comentarios
-- =============================================================================

COMMENT ON COLUMN pedido_items.promocion_id IS 'Referencia a la promoción que generó este item bonificado';
COMMENT ON COLUMN promociones.usos_pendientes IS 'Cantidad de unidades bonificadas pendientes de ajuste de stock (merma)';
