-- Migration 056: Fix all bugs from comprehensive audit
--
-- Fixes:
--   1. DROP orphaned actualizar_pedido_items 6-param overload (causes PostgREST ambiguity error)
--   2. Add auth.uid() validation to all SECURITY DEFINER RPCs (SEC-2)
--   3. Create anular_compra_atomica RPC (BUG-1: non-atomic stock reversal)

-- ============================================================
-- 1. CRITICAL: Drop orphaned 6-param overload from migration 046
--    Migration 053 recreated the 3-param version but never dropped the 6-param.
--    PostgREST cannot resolve which function to call.
-- ============================================================
DROP FUNCTION IF EXISTS public.actualizar_pedido_items(bigint, jsonb, uuid, text, numeric, numeric);

-- ============================================================
-- 2. Fix actualizar_pedido_items (3-param) - add auth.uid() check
-- ============================================================
DROP FUNCTION IF EXISTS public.actualizar_pedido_items(bigint, jsonb, uuid);

CREATE FUNCTION public.actualizar_pedido_items(
  p_pedido_id bigint,
  p_items_nuevos jsonb,
  p_usuario_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item_nuevo JSONB;
  v_producto_id INT;
  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_diferencia INT;
  v_es_bonificacion BOOLEAN;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_total_nuevo DECIMAL := 0;
  v_total_neto_nuevo DECIMAL := 0;
  v_total_iva_nuevo DECIMAL := 0;
  v_total_anterior DECIMAL;
  v_errores TEXT[] := '{}';
  v_items_originales JSONB;
  v_user_role TEXT;
  v_neto_unitario DECIMAL;
  v_iva_unitario DECIMAL;
  v_imp_internos_unitario DECIMAL;
  v_porcentaje_iva DECIMAL;
  v_precio_unitario DECIMAL;
  v_promocion_id BIGINT;
BEGIN
  -- Auth check: verify p_usuario_id matches the authenticated user
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['ID de usuario no coincide con la sesión autenticada']);
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- Save original items for historial
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Phase 1: Validate stock for new non-bonificacion items that need MORE stock
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);

    IF v_es_bonificacion THEN CONTINUE; END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = false;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id FOR UPDATE;

      IF v_stock_actual IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_producto_id || ' no encontrado');
      ELSIF v_stock_actual < v_diferencia THEN
        v_errores := array_append(v_errores, COALESCE(v_producto_nombre, 'Producto ' || v_producto_id)
          || ': stock insuficiente (disponible: ' || v_stock_actual || ', adicional: ' || v_diferencia || ')');
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  -- Phase 2: Restore stock for original NON-bonificacion items only
  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id;

  -- Restore promo usos for original bonificacion items
  UPDATE promociones pr
  SET usos_pendientes = GREATEST(pr.usos_pendientes - pi.cantidad, 0)
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND pr.id = pi.promocion_id;

  -- Phase 3: Delete old items and insert new ones
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;
    v_neto_unitario := (v_item_nuevo->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((v_item_nuevo->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((v_item_nuevo->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item_nuevo->>'porcentaje_iva')::DECIMAL, 0);

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva
    );

    -- Deduct stock only for non-bonificacion items
    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * COALESCE(v_neto_unitario, v_precio_unitario));
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
    END IF;

    -- Track promo usage for bonificaciones
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva
      WHERE id = v_promocion_id;
    END IF;
  END LOOP;

  -- Phase 4: Update pedido totals including fiscal fields
  UPDATE pedidos SET
    total = v_total_nuevo,
    total_neto = v_total_neto_nuevo,
    total_iva = v_total_iva_nuevo,
    updated_at = NOW()
  WHERE id = p_pedido_id;

  -- Phase 5: Record historial
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$$;

-- ============================================================
-- 3. Fix crear_pedido_completo - add auth.uid() validation
-- ============================================================
DROP FUNCTION IF EXISTS public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date);

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
  p_total_iva numeric DEFAULT 0,
  p_fecha_entrega_programada date DEFAULT NULL
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
  v_fecha_entrega DATE;
BEGIN
  -- Auth check: verify p_usuario_id matches the authenticated user
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesión autenticada'));
  END IF;

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

  -- Calcular fecha de entrega programada (default: día siguiente a la fecha del pedido)
  v_fecha_entrega := COALESCE(p_fecha_entrega_programada, (COALESCE(p_fecha, CURRENT_DATE) + INTERVAL '1 day')::date);

  -- 3. Crear el pedido con tipo_factura, desglose y fecha_entrega_programada
  INSERT INTO pedidos (
    cliente_id, fecha, total, total_neto, total_iva, tipo_factura,
    estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago,
    fecha_entrega_programada
  )
  VALUES (
    p_cliente_id, p_fecha, p_total,
    COALESCE(p_total_neto, p_total),
    COALESCE(p_total_iva, 0),
    COALESCE(p_tipo_factura, 'ZZ'),
    'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago,
    v_fecha_entrega
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

-- ============================================================
-- 4. Fix eliminar_pedido_completo - add auth.uid() validation
-- ============================================================
DROP FUNCTION IF EXISTS public.eliminar_pedido_completo(bigint, uuid, text, boolean);

CREATE FUNCTION public.eliminar_pedido_completo(
  p_pedido_id bigint,
  p_usuario_id uuid,
  p_motivo text DEFAULT NULL::text,
  p_restaurar_stock boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pedido RECORD; v_items JSONB; v_cliente_nombre TEXT; v_cliente_direccion TEXT;
  v_usuario_creador_nombre TEXT; v_transportista_nombre TEXT := NULL;
  v_eliminador_nombre TEXT := NULL; v_item RECORD;
  v_user_role TEXT;
BEGIN
  -- Auth check: verify p_usuario_id matches the authenticated user
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesión autenticada');
  END IF;

  -- Only admin can delete orders
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role != 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo administradores pueden eliminar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', pi.producto_id, 'producto_nombre', pr.nombre,
    'producto_codigo', pr.codigo, 'cantidad', pi.cantidad,
    'precio_unitario', pi.precio_unitario, 'subtotal', pi.subtotal))
  INTO v_items FROM pedido_items pi LEFT JOIN productos pr ON pr.id = pi.producto_id WHERE pi.pedido_id = p_pedido_id;

  SELECT nombre_fantasia, direccion INTO v_cliente_nombre, v_cliente_direccion FROM clientes WHERE id = v_pedido.cliente_id;
  SELECT nombre INTO v_usuario_creador_nombre FROM perfiles WHERE id = v_pedido.usuario_id;
  IF v_pedido.transportista_id IS NOT NULL THEN SELECT nombre INTO v_transportista_nombre FROM perfiles WHERE id = v_pedido.transportista_id; END IF;
  IF p_usuario_id IS NOT NULL THEN SELECT nombre INTO v_eliminador_nombre FROM perfiles WHERE id = p_usuario_id; END IF;

  INSERT INTO pedidos_eliminados (
    pedido_id, cliente_id, cliente_nombre, cliente_direccion, total, estado,
    estado_pago, forma_pago, monto_pagado, notas, items,
    usuario_creador_id, usuario_creador_nombre, transportista_id, transportista_nombre,
    fecha_pedido, fecha_entrega, eliminado_por_id, eliminado_por_nombre,
    motivo_eliminacion, stock_restaurado)
  VALUES (
    p_pedido_id, v_pedido.cliente_id, v_cliente_nombre, v_cliente_direccion,
    v_pedido.total, v_pedido.estado, v_pedido.estado_pago, v_pedido.forma_pago,
    v_pedido.monto_pagado, v_pedido.notas, COALESCE(v_items, '[]'::jsonb),
    v_pedido.usuario_id, v_usuario_creador_nombre, v_pedido.transportista_id,
    v_transportista_nombre, v_pedido.created_at, v_pedido.fecha_entrega,
    p_usuario_id, v_eliminador_nombre, p_motivo, p_restaurar_stock);

  IF p_restaurar_stock THEN
    FOR v_item IN SELECT producto_id, cantidad, COALESCE(es_bonificacion, false) as es_bonificacion
    FROM pedido_items WHERE pedido_id = p_pedido_id LOOP
      IF NOT v_item.es_bonificacion THEN
        UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
      END IF;
    END LOOP;
  END IF;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id;
  DELETE FROM pedidos WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$$;

-- ============================================================
-- 5. Fix cancelar_pedido_con_stock - add auth.uid() validation
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancelar_pedido_con_stock(
  p_pedido_id bigint,
  p_motivo text,
  p_usuario_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pedido RECORD;
  v_item RECORD;
  v_total_original DECIMAL;
  v_user_role TEXT;
  v_acting_user uuid;
BEGIN
  -- Use auth.uid() as primary, p_usuario_id only if it matches
  v_acting_user := auth.uid();
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM v_acting_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesión autenticada');
  END IF;

  -- Auth check: only admin or encargado can cancel
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden cancelar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado');
  END IF;

  IF v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  v_total_original := v_pedido.total;

  FOR v_item IN
    SELECT producto_id, cantidad, COALESCE(es_bonificacion, false) as es_bonificacion, promocion_id
    FROM pedido_items WHERE pedido_id = p_pedido_id
  LOOP
    IF v_item.es_bonificacion THEN
      IF v_item.promocion_id IS NOT NULL THEN
        UPDATE promociones
        SET usos_pendientes = GREATEST(usos_pendientes - v_item.cantidad, 0)
        WHERE id = v_item.promocion_id;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
    END IF;
  END LOOP;

  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (
    p_pedido_id,
    v_acting_user,
    'estado',
    v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original
  );

  RETURN jsonb_build_object(
    'success', true,
    'mensaje', 'Pedido cancelado, stock restaurado, saldo ajustado',
    'total_original', v_total_original
  );
END;
$$;

-- ============================================================
-- 6. Fix registrar_compra_completa - add auth.uid() validation
-- ============================================================
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
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_compra_id BIGINT; v_item JSONB; v_producto RECORD; v_stock_anterior INTEGER; v_stock_nuevo INTEGER;
  v_items_procesados JSONB := '[]'::JSONB; v_costo_neto DECIMAL; v_costo_con_iva DECIMAL;
  v_porcentaje_iva DECIMAL; v_impuestos_internos DECIMAL; v_bonificacion DECIMAL;
  v_user_role TEXT;
BEGIN
  -- Auth check: verify p_usuario_id matches the authenticated user
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesión autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  INSERT INTO compras (proveedor_id, proveedor_nombre, numero_factura, fecha_compra, subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado)
  VALUES (p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra, p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida')
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
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
    v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);

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

-- ============================================================
-- 7. NEW: anular_compra_atomica RPC (BUG-1)
--    Replaces non-atomic client-side stock reversal in useCompras.ts
-- ============================================================
CREATE OR REPLACE FUNCTION public.anular_compra_atomica(
  p_compra_id bigint,
  p_usuario_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_compra RECORD;
  v_item RECORD;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_user_role TEXT;
  v_errores TEXT[] := '{}';
BEGIN
  -- Auth check: verify p_usuario_id matches the authenticated user
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesión autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden anular compras');
  END IF;

  SELECT * INTO v_compra FROM compras WHERE id = p_compra_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;

  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra ya está cancelada');
  END IF;

  -- Validate stock availability before reverting (prevent negative stock)
  FOR v_item IN
    SELECT ci.producto_id, ci.cantidad, p.stock, p.nombre
    FROM compra_items ci
    JOIN productos p ON p.id = ci.producto_id
    WHERE ci.compra_id = p_compra_id
    FOR UPDATE OF p  -- Lock product rows
  LOOP
    IF v_item.stock < v_item.cantidad THEN
      v_errores := array_append(v_errores,
        COALESCE(v_item.nombre, 'Producto ' || v_item.producto_id)
        || ': stock insuficiente para revertir (actual: ' || v_item.stock || ', necesario: ' || v_item.cantidad || ')');
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede anular: ' || array_to_string(v_errores, '; '));
  END IF;

  -- Revert stock atomically
  UPDATE productos p
  SET stock = p.stock - ci.cantidad,
      updated_at = NOW()
  FROM compra_items ci
  WHERE ci.compra_id = p_compra_id
    AND p.id = ci.producto_id;

  -- Mark compra as cancelled
  UPDATE compras
  SET estado = 'cancelada',
      updated_at = NOW()
  WHERE id = p_compra_id;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Compra anulada y stock revertido correctamente');
END;
$$;
