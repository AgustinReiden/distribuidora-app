-- Migration 059: Multi-tenant RPC Functions
--
-- Makes ALL RPC functions multi-tenant aware using current_sucursal_id().
--
-- Why: RPCs use SECURITY DEFINER which BYPASSES RLS policies. Even though
-- migration 058 added RLS policies filtering by sucursal_id, any data
-- access through RPCs would still cross tenant boundaries without this fix.
--
-- Pattern for each function:
--   1. Declare v_sucursal BIGINT := current_sucursal_id();
--   2. Guard: IF v_sucursal IS NULL THEN return error
--   3. Add AND sucursal_id = v_sucursal to all SELECT/UPDATE/DELETE
--   4. Add sucursal_id = v_sucursal to all INSERT
--
-- Exception: transferencias_stock uses tenant_sucursal_id instead of sucursal_id

-- ============================================================
-- 1. crear_pedido_completo
-- ============================================================
DROP FUNCTION IF EXISTS public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date);

CREATE FUNCTION public.crear_pedido_completo(
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
  v_sucursal BIGINT := current_sucursal_id();
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
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa'));
  END IF;

  -- Auth check: verify p_usuario_id matches the authenticated user
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesion autenticada'));
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
      errores := array_append(errores, 'Cantidad invalida para producto ID ' || v_producto_id || ': debe ser mayor a 0');
      CONTINUE;
    END IF;

    IF NOT v_es_bonificacion THEN
      v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
      v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
    END IF;
  END LOOP;

  -- 2. Verificar stock usando cantidades acumuladas (con bloqueo) -- tenant-scoped
  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales)
  LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;

    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos
    WHERE id = v_producto_id AND sucursal_id = v_sucursal
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

  -- Calcular fecha de entrega programada (default: dia siguiente a la fecha del pedido)
  v_fecha_entrega := COALESCE(p_fecha_entrega_programada, (COALESCE(p_fecha, CURRENT_DATE) + INTERVAL '1 day')::date);

  -- 3. Crear el pedido -- tenant-scoped INSERT
  INSERT INTO pedidos (
    cliente_id, fecha, total, total_neto, total_iva, tipo_factura,
    estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago,
    fecha_entrega_programada, sucursal_id
  )
  VALUES (
    p_cliente_id, p_fecha, p_total,
    COALESCE(p_total_neto, p_total),
    COALESCE(p_total_iva, 0),
    COALESCE(p_tipo_factura, 'ZZ'),
    'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago,
    v_fecha_entrega, v_sucursal
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

    -- tenant-scoped INSERT
    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id
    )
    VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario,
      v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal
    );

    -- Stock: solo descontar si NO es bonificacion -- tenant-scoped
    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad
      WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    END IF;

    -- Contador de promos -- tenant-scoped
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad
      WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;


-- ============================================================
-- 2. actualizar_pedido_items
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
  v_sucursal BIGINT := current_sucursal_id();
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
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;

  -- Auth check
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['ID de usuario no coincide con la sesion autenticada']);
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  -- tenant-scoped pedido lookup
  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- Save original items for historial -- tenant-scoped
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  -- Phase 1: Validate stock for new non-bonificacion items that need MORE stock
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);

    IF v_es_bonificacion THEN CONTINUE; END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = false
      AND sucursal_id = v_sucursal;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

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

  -- Phase 2: Restore stock for original NON-bonificacion items only -- tenant-scoped
  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id
    AND p.sucursal_id = v_sucursal;

  -- Restore promo usos for original bonificacion items -- tenant-scoped
  UPDATE promociones pr
  SET usos_pendientes = GREATEST(pr.usos_pendientes - pi.cantidad, 0)
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND pr.id = pi.promocion_id
    AND pr.sucursal_id = v_sucursal;

  -- Phase 3: Delete old items and insert new ones -- tenant-scoped
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

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

    -- tenant-scoped INSERT
    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal
    );

    -- Deduct stock only for non-bonificacion items -- tenant-scoped
    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva
      WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * COALESCE(v_neto_unitario, v_precio_unitario));
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
    END IF;

    -- Track promo usage for bonificaciones -- tenant-scoped
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva
      WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  -- Phase 4: Update pedido totals -- tenant-scoped
  UPDATE pedidos SET
    total = v_total_nuevo,
    total_neto = v_total_neto_nuevo,
    total_iva = v_total_iva_nuevo,
    updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  -- Phase 5: Record historial -- tenant-scoped INSERT
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT, v_sucursal);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$$;


-- ============================================================
-- 3. cancelar_pedido_con_stock
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
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD;
  v_item RECORD;
  v_total_original DECIMAL;
  v_user_role TEXT;
  v_acting_user uuid;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  -- Use auth.uid() as primary, p_usuario_id only if it matches
  v_acting_user := auth.uid();
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM v_acting_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  -- Auth check: only admin or encargado can cancel
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden cancelar pedidos');
  END IF;

  -- tenant-scoped pedido lookup with lock
  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;

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

  -- tenant-scoped item loop
  FOR v_item IN
    SELECT producto_id, cantidad, COALESCE(es_bonificacion, false) as es_bonificacion, promocion_id
    FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
  LOOP
    IF v_item.es_bonificacion THEN
      IF v_item.promocion_id IS NOT NULL THEN
        UPDATE promociones
        SET usos_pendientes = GREATEST(usos_pendientes - v_item.cantidad, 0)
        WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad
      WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  -- tenant-scoped UPDATE
  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  -- tenant-scoped INSERT
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    p_pedido_id,
    v_acting_user,
    'estado',
    v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original,
    v_sucursal
  );

  RETURN jsonb_build_object(
    'success', true,
    'mensaje', 'Pedido cancelado, stock restaurado, saldo ajustado',
    'total_original', v_total_original
  );
END;
$$;


-- ============================================================
-- 4. eliminar_pedido_completo
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
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD; v_items JSONB; v_cliente_nombre TEXT; v_cliente_direccion TEXT;
  v_usuario_creador_nombre TEXT; v_transportista_nombre TEXT := NULL;
  v_eliminador_nombre TEXT := NULL; v_item RECORD;
  v_user_role TEXT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  -- Auth check
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  -- Only admin can delete orders
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role != 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo administradores pueden eliminar pedidos');
  END IF;

  -- tenant-scoped pedido lookup
  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;

  -- tenant-scoped items lookup
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', pi.producto_id, 'producto_nombre', pr.nombre,
    'producto_codigo', pr.codigo, 'cantidad', pi.cantidad,
    'precio_unitario', pi.precio_unitario, 'subtotal', pi.subtotal))
  INTO v_items FROM pedido_items pi LEFT JOIN productos pr ON pr.id = pi.producto_id
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal;

  SELECT nombre_fantasia, direccion INTO v_cliente_nombre, v_cliente_direccion
  FROM clientes WHERE id = v_pedido.cliente_id AND sucursal_id = v_sucursal;
  SELECT nombre INTO v_usuario_creador_nombre FROM perfiles WHERE id = v_pedido.usuario_id;
  IF v_pedido.transportista_id IS NOT NULL THEN SELECT nombre INTO v_transportista_nombre FROM perfiles WHERE id = v_pedido.transportista_id; END IF;
  IF p_usuario_id IS NOT NULL THEN SELECT nombre INTO v_eliminador_nombre FROM perfiles WHERE id = p_usuario_id; END IF;

  -- tenant-scoped INSERT into pedidos_eliminados
  INSERT INTO pedidos_eliminados (
    pedido_id, cliente_id, cliente_nombre, cliente_direccion, total, estado,
    estado_pago, forma_pago, monto_pagado, notas, items,
    usuario_creador_id, usuario_creador_nombre, transportista_id, transportista_nombre,
    fecha_pedido, fecha_entrega, eliminado_por_id, eliminado_por_nombre,
    motivo_eliminacion, stock_restaurado, sucursal_id)
  VALUES (
    p_pedido_id, v_pedido.cliente_id, v_cliente_nombre, v_cliente_direccion,
    v_pedido.total, v_pedido.estado, v_pedido.estado_pago, v_pedido.forma_pago,
    v_pedido.monto_pagado, v_pedido.notas, COALESCE(v_items, '[]'::jsonb),
    v_pedido.usuario_id, v_usuario_creador_nombre, v_pedido.transportista_id,
    v_transportista_nombre, v_pedido.created_at, v_pedido.fecha_entrega,
    p_usuario_id, v_eliminador_nombre, p_motivo, p_restaurar_stock, v_sucursal);

  IF p_restaurar_stock THEN
    FOR v_item IN SELECT producto_id, cantidad, COALESCE(es_bonificacion, false) as es_bonificacion
    FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal LOOP
      IF NOT v_item.es_bonificacion THEN
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    END LOOP;
  END IF;

  -- tenant-scoped DELETEs
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$$;


-- ============================================================
-- 5. descontar_stock_atomico (jsonb overload)
-- ============================================================
CREATE OR REPLACE FUNCTION public.descontar_stock_atomico(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item JSONB; v_producto_id INT; v_cantidad INT;
  v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa'));
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No autorizado para descontar stock'));
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::INT;
    v_cantidad := (v_item->>'cantidad')::INT;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad invalida para producto ' || v_producto_id);
      CONTINUE;
    END IF;

    -- tenant-scoped SELECT FOR UPDATE
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
    ELSE
      -- tenant-scoped UPDATE
      UPDATE productos SET stock = stock - v_cantidad
      WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  RETURN jsonb_build_object('success', true, 'errores', '[]'::jsonb);
END;
$$;


-- ============================================================
-- 6. restaurar_stock_atomico (jsonb overload)
-- ============================================================
CREATE OR REPLACE FUNCTION public.restaurar_stock_atomico(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item JSONB; v_producto_id INT; v_cantidad INT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa'));
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No autorizado para restaurar stock'));
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::INT;
    v_cantidad := (v_item->>'cantidad')::INT;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad invalida para producto ' || v_producto_id);
      CONTINUE;
    END IF;

    -- tenant-scoped UPDATE
    UPDATE productos SET stock = stock + v_cantidad
    WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    IF NOT FOUND THEN
      errores := array_append(errores, 'Producto ' || v_producto_id || ' no encontrado');
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  RETURN jsonb_build_object('success', true, 'errores', '[]'::jsonb);
END;
$$;


-- ============================================================
-- 7. registrar_compra_completa (12-param overload)
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
  v_sucursal BIGINT := current_sucursal_id();
  v_compra_id BIGINT; v_item JSONB; v_producto RECORD; v_stock_anterior INTEGER; v_stock_nuevo INTEGER;
  v_items_procesados JSONB := '[]'::JSONB; v_costo_neto DECIMAL; v_costo_con_iva DECIMAL;
  v_porcentaje_iva DECIMAL; v_impuestos_internos DECIMAL; v_bonificacion DECIMAL;
  v_user_role TEXT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  -- Auth check
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  -- tenant-scoped INSERT
  INSERT INTO compras (proveedor_id, proveedor_nombre, numero_factura, fecha_compra, subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado, sucursal_id)
  VALUES (p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra, p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida', v_sucursal)
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    -- tenant-scoped SELECT FOR UPDATE
    SELECT id, stock INTO v_producto FROM productos
    WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id'; END IF;

    v_stock_anterior := COALESCE(v_producto.stock, 0);
    v_stock_nuevo := v_stock_anterior + (v_item->>'cantidad')::INTEGER;
    v_bonificacion := COALESCE((v_item->>'bonificacion')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item->>'porcentaje_iva')::DECIMAL, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::DECIMAL, 0);

    -- tenant-scoped INSERT
    INSERT INTO compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, bonificacion, sucursal_id)
    VALUES (v_compra_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INTEGER,
            COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
            COALESCE((v_item->>'subtotal')::DECIMAL, 0),
            v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal);

    v_costo_neto := COALESCE((v_item->>'costo_unitario')::DECIMAL, 0) * (1 - v_bonificacion / 100);
    v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);

    -- tenant-scoped UPDATE
    UPDATE productos SET
      stock = stock + (v_item->>'cantidad')::INTEGER,
      costo_sin_iva = v_costo_neto,
      costo_con_iva = v_costo_con_iva,
      impuestos_internos = v_impuestos_internos,
      porcentaje_iva = v_porcentaje_iva,
      updated_at = NOW()
    WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal;

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
-- 8. actualizar_precios_masivo
-- ============================================================
CREATE OR REPLACE FUNCTION actualizar_precios_masivo(
  p_productos JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item JSONB;
  v_actualizados INT := 0;
  v_errores TEXT[] := '{}';
  v_producto_id INT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)
  LOOP
    BEGIN
      v_producto_id := (v_item->>'producto_id')::INT;

      -- tenant-scoped UPDATE
      UPDATE productos
      SET
        precio_sin_iva = COALESCE((v_item->>'precio_neto')::DECIMAL, precio_sin_iva),
        impuestos_internos = COALESCE((v_item->>'imp_internos')::DECIMAL, impuestos_internos),
        precio = COALESCE((v_item->>'precio_final')::DECIMAL, precio),
        updated_at = NOW()
      WHERE id = v_producto_id AND sucursal_id = v_sucursal;

      IF FOUND THEN
        v_actualizados := v_actualizados + 1;
      ELSE
        v_errores := array_append(v_errores,
          'Producto ID ' || v_producto_id || ' no encontrado');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errores := array_append(v_errores,
        'Error en producto ID ' || COALESCE(v_producto_id::TEXT, 'desconocido') || ': ' || SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', array_length(v_errores, 1) IS NULL,
    'actualizados', v_actualizados,
    'errores', COALESCE(to_jsonb(v_errores), '[]'::jsonb)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 9. registrar_nota_credito
-- ============================================================
CREATE OR REPLACE FUNCTION public.registrar_nota_credito(
  p_compra_id BIGINT,
  p_numero_nota VARCHAR DEFAULT NULL,
  p_motivo TEXT DEFAULT NULL,
  p_subtotal DECIMAL DEFAULT 0,
  p_iva DECIMAL DEFAULT 0,
  p_total DECIMAL DEFAULT 0,
  p_usuario_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT '[]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_nota_id BIGINT;
  v_item JSONB;
  v_stock_actual INTEGER;
  v_producto_id BIGINT;
  v_cantidad INTEGER;
  v_costo DECIMAL;
  v_sub DECIMAL;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  -- tenant-scoped compra check
  IF NOT EXISTS (SELECT 1 FROM compras WHERE id = p_compra_id AND estado != 'cancelada' AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada o cancelada');
  END IF;

  -- tenant-scoped INSERT
  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id)
  VALUES (p_compra_id, p_numero_nota, CURRENT_DATE, p_subtotal, p_iva, p_total, p_motivo, p_usuario_id, v_sucursal)
  RETURNING id INTO v_nota_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (v_item->>'producto_id')::BIGINT;
    v_cantidad := (v_item->>'cantidad')::INTEGER;
    v_costo := (v_item->>'costo_unitario')::DECIMAL;
    v_sub := (v_item->>'subtotal')::DECIMAL;

    -- tenant-scoped SELECT FOR UPDATE
    SELECT stock INTO v_stock_actual FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      RAISE EXCEPTION 'Producto % no encontrado', v_producto_id;
    END IF;

    -- tenant-scoped INSERT
    INSERT INTO nota_credito_items (nota_credito_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, sucursal_id)
    VALUES (v_nota_id, v_producto_id, v_cantidad, v_costo, v_sub, v_stock_actual, GREATEST(0, v_stock_actual - v_cantidad), v_sucursal);

    -- tenant-scoped UPDATE
    UPDATE productos SET stock = GREATEST(0, v_stock_actual - v_cantidad)
    WHERE id = v_producto_id AND sucursal_id = v_sucursal;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id);
END;
$$;


-- ============================================================
-- 10. registrar_salvedad
-- ============================================================
CREATE OR REPLACE FUNCTION registrar_salvedad(
  p_pedido_id BIGINT,
  p_pedido_item_id BIGINT,
  p_cantidad_afectada INTEGER,
  p_motivo VARCHAR,
  p_descripcion TEXT DEFAULT NULL,
  p_foto_url TEXT DEFAULT NULL,
  p_devolver_stock BOOLEAN DEFAULT TRUE
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad_id BIGINT;
  v_item RECORD;
  v_cantidad_entregada INTEGER;
  v_monto_afectado DECIMAL;
  v_usuario_id UUID := auth.uid();
  v_es_admin BOOLEAN;
  v_subtotal_anterior DECIMAL;
  v_subtotal_nuevo DECIMAL;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_es_admin := es_admin_salvedades();

  -- Verificar que el usuario tiene permiso -- tenant-scoped
  IF NOT v_es_admin AND NOT EXISTS (
    SELECT 1 FROM pedidos p
    WHERE p.id = p_pedido_id
    AND p.sucursal_id = v_sucursal
    AND (p.transportista_id = v_usuario_id)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para registrar salvedad en este pedido');
  END IF;

  -- Obtener datos del item -- tenant-scoped
  SELECT
    pi.id,
    pi.producto_id,
    pi.cantidad,
    pi.precio_unitario,
    pi.subtotal,
    pr.nombre AS producto_nombre,
    pr.stock AS stock_actual
  INTO v_item
  FROM pedido_items pi
  JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = v_sucursal
  WHERE pi.id = p_pedido_item_id AND pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item de pedido no encontrado');
  END IF;

  IF p_cantidad_afectada > v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a la cantidad del item');
  END IF;

  IF p_cantidad_afectada <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'La cantidad afectada debe ser mayor a 0');
  END IF;

  v_cantidad_entregada := v_item.cantidad - p_cantidad_afectada;
  v_monto_afectado := p_cantidad_afectada * v_item.precio_unitario;
  v_subtotal_anterior := v_item.subtotal;
  v_subtotal_nuevo := v_cantidad_entregada * v_item.precio_unitario;

  -- tenant-scoped INSERT
  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id,
    cantidad_original, cantidad_afectada, cantidad_entregada,
    motivo, descripcion, foto_url,
    monto_afectado, precio_unitario, reportado_por, sucursal_id
  ) VALUES (
    p_pedido_id, p_pedido_item_id, v_item.producto_id,
    v_item.cantidad, p_cantidad_afectada, v_cantidad_entregada,
    p_motivo, p_descripcion, p_foto_url,
    v_monto_afectado, v_item.precio_unitario, v_usuario_id, v_sucursal
  )
  RETURNING id INTO v_salvedad_id;

  -- Actualizar el item del pedido -- tenant-scoped
  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items SET
      cantidad = v_cantidad_entregada,
      subtotal = v_subtotal_nuevo
    WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    DELETE FROM pedido_items WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  END IF;

  -- Recalcular total del pedido -- tenant-scoped
  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal),
    updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  -- Manejar devolucion de stock segun motivo
  IF p_devolver_stock THEN
    IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN
      -- tenant-scoped UPDATE
      UPDATE productos SET stock = stock + p_cantidad_afectada
      WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      UPDATE salvedades_items SET
        stock_devuelto = TRUE,
        stock_devuelto_at = NOW()
      WHERE id = v_salvedad_id;
    ELSE
      UPDATE salvedades_items SET stock_devuelto = FALSE WHERE id = v_salvedad_id;
    END IF;
  END IF;

  -- tenant-scoped historial INSERT
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);

  -- Registrar en historial del pedido
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'pedido_historial') THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (
      p_pedido_id,
      v_usuario_id,
      'salvedad_item',
      v_item.cantidad::TEXT || ' unidades de ' || v_item.producto_nombre,
      v_cantidad_entregada::TEXT || ' unidades (salvedad: ' || p_motivo || ')',
      v_sucursal
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'salvedad_id', v_salvedad_id,
    'monto_afectado', v_monto_afectado,
    'cantidad_entregada', v_cantidad_entregada,
    'stock_devuelto', CASE WHEN p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN true ELSE false END,
    'nuevo_total_pedido', (SELECT total FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 11. resolver_salvedad
-- ============================================================
CREATE OR REPLACE FUNCTION resolver_salvedad(
  p_salvedad_id BIGINT,
  p_estado_resolucion VARCHAR,
  p_notas TEXT DEFAULT NULL,
  p_pedido_reprogramado_id BIGINT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_estado_anterior VARCHAR;
  v_usuario_id UUID := auth.uid();
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo administradores pueden resolver salvedades');
  END IF;

  IF p_estado_resolucion NOT IN ('reprogramada', 'nota_credito', 'descuento_transportista', 'absorcion_empresa', 'resuelto_otro', 'anulada') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Estado de resolucion no valido');
  END IF;

  -- tenant-scoped lookup
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Salvedad no encontrada');
  END IF;

  IF v_salvedad.estado_resolucion != 'pendiente' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La salvedad ya fue resuelta');
  END IF;

  v_estado_anterior := v_salvedad.estado_resolucion;

  -- tenant-scoped UPDATE
  UPDATE salvedades_items SET
    estado_resolucion = p_estado_resolucion,
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    pedido_reprogramado_id = p_pedido_reprogramado_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;

  -- tenant-scoped INSERT
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'resolucion', v_estado_anterior, p_estado_resolucion, p_notas, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object('success', true, 'nuevo_estado', p_estado_resolucion);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 12. anular_salvedad
-- ============================================================
CREATE OR REPLACE FUNCTION anular_salvedad(
  p_salvedad_id BIGINT,
  p_notas TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo administradores pueden anular salvedades');
  END IF;

  -- tenant-scoped lookup
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Salvedad no encontrada');
  END IF;

  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La salvedad ya esta anulada');
  END IF;

  -- Restaurar item del pedido si aun existe -- tenant-scoped
  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
    UPDATE pedido_items SET
      cantidad = v_salvedad.cantidad_original,
      subtotal = v_salvedad.cantidad_original * v_salvedad.precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    -- Recrear el item si fue eliminado -- tenant-scoped INSERT
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES (
      v_salvedad.pedido_id,
      v_salvedad.producto_id,
      v_salvedad.cantidad_original,
      v_salvedad.precio_unitario,
      v_salvedad.cantidad_original * v_salvedad.precio_unitario,
      v_sucursal
    );
  END IF;

  -- Recalcular total del pedido -- tenant-scoped
  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;

  -- Si se habia devuelto stock, revertir -- tenant-scoped
  IF v_salvedad.stock_devuelto THEN
    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
    WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
  END IF;

  -- Marcar como anulada -- tenant-scoped
  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;

  -- tenant-scoped INSERT
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object('success', true, 'message', 'Salvedad anulada correctamente');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 13. crear_recorrido
-- ============================================================
CREATE OR REPLACE FUNCTION crear_recorrido(
  p_transportista_id UUID,
  p_pedidos JSONB,
  p_distancia DECIMAL DEFAULT NULL,
  p_duracion INTEGER DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_recorrido_id BIGINT;
  v_pedido JSONB;
  v_total_facturado DECIMAL := 0;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- tenant-scoped total calculation
  SELECT COALESCE(SUM(total), 0) INTO v_total_facturado
  FROM pedidos
  WHERE id IN (SELECT (value->>'pedido_id')::BIGINT FROM jsonb_array_elements(p_pedidos) AS value)
    AND sucursal_id = v_sucursal;

  -- tenant-scoped INSERT
  INSERT INTO recorridos (
    transportista_id, fecha, distancia_total, duracion_total,
    total_pedidos, total_facturado, estado, sucursal_id
  )
  VALUES (
    p_transportista_id, CURRENT_DATE, p_distancia, p_duracion,
    jsonb_array_length(p_pedidos), v_total_facturado, 'en_curso', v_sucursal
  )
  RETURNING id INTO v_recorrido_id;

  -- tenant-scoped INSERT
  FOR v_pedido IN SELECT * FROM jsonb_array_elements(p_pedidos)
  LOOP
    INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, sucursal_id)
    VALUES (
      v_recorrido_id,
      (v_pedido->>'pedido_id')::BIGINT,
      (v_pedido->>'orden_entrega')::INTEGER,
      v_sucursal
    );
  END LOOP;

  RETURN v_recorrido_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 14. crear_rendicion_recorrido
-- ============================================================
CREATE OR REPLACE FUNCTION crear_rendicion_recorrido(
  p_recorrido_id BIGINT,
  p_transportista_id UUID DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
  v_transportista_real UUID;
  v_es_admin BOOLEAN;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  v_es_admin := es_admin_rendiciones();

  IF v_es_admin THEN
    IF p_transportista_id IS NULL THEN
      SELECT transportista_id INTO v_transportista_real
      FROM recorridos WHERE id = p_recorrido_id AND sucursal_id = v_sucursal;
    ELSE
      v_transportista_real := p_transportista_id;
    END IF;
  ELSE
    v_transportista_real := auth.uid();
  END IF;

  -- tenant-scoped recorrido check
  IF NOT EXISTS (
    SELECT 1 FROM recorridos
    WHERE id = p_recorrido_id AND sucursal_id = v_sucursal
    AND (transportista_id = v_transportista_real OR v_es_admin)
  ) THEN
    RAISE EXCEPTION 'Recorrido no valido o no pertenece al transportista';
  END IF;

  -- tenant-scoped rendicion check
  IF EXISTS (SELECT 1 FROM rendiciones WHERE recorrido_id = p_recorrido_id AND sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'Ya existe una rendicion para este recorrido';
  END IF;

  -- Calcular totales -- tenant-scoped
  FOR v_pedido IN
    SELECT p.id, COALESCE(p.monto_pagado, 0) as monto_pagado, COALESCE(p.forma_pago, 'efectivo') as forma_pago
    FROM pedidos p
    JOIN recorrido_pedidos rp ON rp.pedido_id = p.id
    WHERE rp.recorrido_id = p_recorrido_id
    AND rp.estado_entrega = 'entregado'
    AND p.estado = 'entregado'
    AND p.sucursal_id = v_sucursal
  LOOP
    IF v_pedido.forma_pago = 'efectivo' THEN
      v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE
      v_total_otros := v_total_otros + v_pedido.monto_pagado;
    END IF;
  END LOOP;

  -- tenant-scoped INSERT
  INSERT INTO rendiciones (
    recorrido_id, transportista_id, fecha,
    total_efectivo_esperado, total_otros_medios, estado, sucursal_id
  ) VALUES (
    p_recorrido_id, v_transportista_real, CURRENT_DATE,
    v_total_efectivo, v_total_otros, 'pendiente', v_sucursal
  )
  RETURNING id INTO v_rendicion_id;

  -- tenant-scoped INSERT
  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago, sucursal_id)
  SELECT
    v_rendicion_id, p.id,
    COALESCE(p.monto_pagado, 0),
    COALESCE(p.forma_pago, 'efectivo'),
    v_sucursal
  FROM pedidos p
  JOIN recorrido_pedidos rp ON rp.pedido_id = p.id
  WHERE rp.recorrido_id = p_recorrido_id
  AND rp.estado_entrega = 'entregado'
  AND p.estado = 'entregado'
  AND p.sucursal_id = v_sucursal;

  RETURN v_rendicion_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 15. crear_rendicion_por_fecha
-- ============================================================
CREATE OR REPLACE FUNCTION crear_rendicion_por_fecha(
  p_transportista_id UUID,
  p_fecha DATE DEFAULT CURRENT_DATE
)
RETURNS BIGINT AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
  v_count INTEGER := 0;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- tenant-scoped rendicion check
  IF EXISTS (
    SELECT 1 FROM rendiciones
    WHERE transportista_id = p_transportista_id AND fecha = p_fecha AND sucursal_id = v_sucursal
  ) THEN
    RAISE EXCEPTION 'Ya existe una rendicion para este transportista en esta fecha';
  END IF;

  -- tenant-scoped pedidos query
  FOR v_pedido IN
    SELECT p.id,
           COALESCE(p.total, 0) as total,
           COALESCE(p.monto_pagado, p.total, 0) as monto_pagado,
           COALESCE(p.forma_pago, 'efectivo') as forma_pago
    FROM pedidos p
    WHERE p.transportista_id = p_transportista_id
      AND p.estado = 'entregado'
      AND p.sucursal_id = v_sucursal
      AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha
  LOOP
    v_count := v_count + 1;
    IF v_pedido.forma_pago = 'efectivo' THEN
      v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE
      v_total_otros := v_total_otros + v_pedido.monto_pagado;
    END IF;
  END LOOP;

  -- tenant-scoped INSERT
  INSERT INTO rendiciones (
    recorrido_id, transportista_id, fecha,
    total_efectivo_esperado, total_otros_medios, estado, sucursal_id
  ) VALUES (
    NULL, p_transportista_id, p_fecha,
    v_total_efectivo, v_total_otros, 'pendiente', v_sucursal
  ) RETURNING id INTO v_rendicion_id;

  -- tenant-scoped INSERT
  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago, sucursal_id)
  SELECT v_rendicion_id, p.id,
         COALESCE(p.monto_pagado, p.total, 0),
         COALESCE(p.forma_pago, 'efectivo'),
         v_sucursal
  FROM pedidos p
  WHERE p.transportista_id = p_transportista_id
    AND p.estado = 'entregado'
    AND p.sucursal_id = v_sucursal
    AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha;

  RETURN v_rendicion_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 16. presentar_rendicion
-- ============================================================
CREATE OR REPLACE FUNCTION presentar_rendicion(
  p_rendicion_id BIGINT,
  p_monto_rendido DECIMAL,
  p_justificacion TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_transportista_id UUID;
  v_estado VARCHAR;
  v_diferencia DECIMAL;
  v_es_admin BOOLEAN;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_es_admin := es_admin_rendiciones();

  -- tenant-scoped rendicion lookup
  SELECT transportista_id, estado INTO v_transportista_id, v_estado
  FROM rendiciones
  WHERE id = p_rendicion_id AND sucursal_id = v_sucursal;

  IF v_transportista_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rendicion no encontrada');
  END IF;

  IF v_estado NOT IN ('pendiente', 'con_observaciones') THEN
    RETURN jsonb_build_object('success', false, 'error', 'La rendicion no esta en estado editable');
  END IF;

  IF v_transportista_id != auth.uid() AND NOT v_es_admin THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- tenant-scoped UPDATE
  UPDATE rendiciones SET
    monto_rendido = p_monto_rendido,
    justificacion_transportista = p_justificacion,
    estado = 'presentada',
    presentada_at = NOW(),
    updated_at = NOW()
  WHERE id = p_rendicion_id AND sucursal_id = v_sucursal;

  SELECT diferencia INTO v_diferencia
  FROM rendiciones WHERE id = p_rendicion_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'success', true,
    'diferencia', v_diferencia,
    'requiere_justificacion', ABS(v_diferencia) > 0
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 17. revisar_rendicion
-- ============================================================
CREATE OR REPLACE FUNCTION revisar_rendicion(
  p_rendicion_id BIGINT,
  p_accion VARCHAR,
  p_observaciones TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_nuevo_estado VARCHAR;
  v_recorrido_id BIGINT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF NOT es_admin_rendiciones() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo administradores pueden revisar rendiciones');
  END IF;

  -- tenant-scoped check
  IF NOT EXISTS (SELECT 1 FROM rendiciones WHERE id = p_rendicion_id AND estado = 'presentada' AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rendicion no encontrada o no esta presentada');
  END IF;

  v_nuevo_estado := CASE p_accion
    WHEN 'aprobar' THEN 'aprobada'
    WHEN 'rechazar' THEN 'rechazada'
    WHEN 'observar' THEN 'con_observaciones'
    ELSE NULL
  END;

  IF v_nuevo_estado IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Accion no valida');
  END IF;

  SELECT recorrido_id INTO v_recorrido_id FROM rendiciones WHERE id = p_rendicion_id AND sucursal_id = v_sucursal;

  -- tenant-scoped UPDATE
  UPDATE rendiciones SET
    estado = v_nuevo_estado,
    observaciones_admin = p_observaciones,
    revisada_at = NOW(),
    revisada_por = auth.uid(),
    updated_at = NOW()
  WHERE id = p_rendicion_id AND sucursal_id = v_sucursal;

  -- If approved, mark recorrido as completed -- tenant-scoped
  IF v_nuevo_estado = 'aprobada' AND v_recorrido_id IS NOT NULL THEN
    UPDATE recorridos SET
      estado = 'completado',
      completed_at = NOW()
    WHERE id = v_recorrido_id AND sucursal_id = v_sucursal;
  END IF;

  RETURN jsonb_build_object('success', true, 'nuevo_estado', v_nuevo_estado);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 18. obtener_estadisticas_rendiciones
-- ============================================================
CREATE OR REPLACE FUNCTION obtener_estadisticas_rendiciones(
  p_fecha_desde DATE DEFAULT NULL,
  p_fecha_hasta DATE DEFAULT NULL,
  p_transportista_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_resultado JSONB;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT jsonb_build_object(
    'total', COUNT(*),
    'pendientes', COUNT(*) FILTER (WHERE estado IN ('pendiente', 'presentada')),
    'aprobadas', COUNT(*) FILTER (WHERE estado = 'aprobada'),
    'rechazadas', COUNT(*) FILTER (WHERE estado = 'rechazada'),
    'con_observaciones', COUNT(*) FILTER (WHERE estado = 'con_observaciones'),
    'total_efectivo_esperado', COALESCE(SUM(total_efectivo_esperado), 0),
    'total_rendido', COALESCE(SUM(monto_rendido) FILTER (WHERE estado = 'aprobada'), 0),
    'total_diferencias', COALESCE(SUM(diferencia) FILTER (WHERE estado = 'aprobada'), 0),
    'por_transportista', (
      SELECT jsonb_agg(jsonb_build_object(
        'transportista_id', transportista_id,
        'transportista_nombre', p.nombre,
        'rendiciones', cnt,
        'total_rendido', total_rend,
        'total_diferencias', total_dif
      ))
      FROM (
        SELECT
          r.transportista_id,
          COUNT(*) as cnt,
          SUM(r.monto_rendido) as total_rend,
          SUM(r.diferencia) as total_dif
        FROM rendiciones r
        WHERE r.sucursal_id = v_sucursal
          AND (p_fecha_desde IS NULL OR r.fecha >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR r.fecha <= p_fecha_hasta)
          AND (p_transportista_id IS NULL OR r.transportista_id = p_transportista_id)
        GROUP BY r.transportista_id
      ) t
      JOIN perfiles p ON p.id = t.transportista_id
    )
  ) INTO v_resultado
  FROM rendiciones
  WHERE sucursal_id = v_sucursal
    AND (p_fecha_desde IS NULL OR fecha >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR fecha <= p_fecha_hasta)
    AND (p_transportista_id IS NULL OR transportista_id = p_transportista_id);

  RETURN v_resultado;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 19. obtener_resumen_compras
-- ============================================================
CREATE OR REPLACE FUNCTION obtener_resumen_compras(
  p_fecha_desde DATE DEFAULT NULL,
  p_fecha_hasta DATE DEFAULT NULL
)
RETURNS TABLE (
  total_compras BIGINT,
  monto_total DECIMAL,
  promedio_compra DECIMAL,
  productos_comprados BIGINT
) AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
BEGIN
  RETURN QUERY
  SELECT
    COUNT(DISTINCT c.id)::BIGINT as total_compras,
    COALESCE(SUM(c.total), 0)::DECIMAL as monto_total,
    COALESCE(AVG(c.total), 0)::DECIMAL as promedio_compra,
    COALESCE(SUM(ci.cantidad), 0)::BIGINT as productos_comprados
  FROM compras c
  LEFT JOIN compra_items ci ON c.id = ci.compra_id
  WHERE c.estado != 'cancelada'
    AND c.sucursal_id = v_sucursal
    AND (p_fecha_desde IS NULL OR c.fecha_compra >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR c.fecha_compra <= p_fecha_hasta);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- 20. obtener_resumen_cuenta_cliente
-- ============================================================
CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente(p_cliente_id integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_total_pedidos NUMERIC;
  v_total_pagado NUMERIC;
  v_saldo NUMERIC;
  v_user_role TEXT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('error', 'No autorizado');
  END IF;

  -- tenant-scoped queries
  SELECT COALESCE(SUM(total), 0) INTO v_total_pedidos
  FROM pedidos WHERE cliente_id = p_cliente_id AND estado != 'cancelado' AND sucursal_id = v_sucursal;

  SELECT COALESCE(SUM(monto), 0) INTO v_total_pagado
  FROM pagos WHERE cliente_id = p_cliente_id AND sucursal_id = v_sucursal;

  v_saldo := v_total_pedidos - v_total_pagado;

  RETURN jsonb_build_object(
    'total_pedidos', v_total_pedidos,
    'total_pagado', v_total_pagado,
    'saldo', v_saldo
  );
END;
$function$;


-- ============================================================
-- 21. registrar_transferencia
-- ============================================================
CREATE OR REPLACE FUNCTION public.registrar_transferencia(
  p_sucursal_id bigint,
  p_fecha date DEFAULT CURRENT_DATE,
  p_notas text DEFAULT NULL,
  p_total_costo numeric DEFAULT 0,
  p_usuario_id uuid DEFAULT NULL,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_transferencia_id BIGINT; v_item JSONB;
  v_stock_actual INT; v_producto_nombre TEXT;
  v_user_role TEXT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- tenant-scoped INSERT (uses tenant_sucursal_id for transferencias_stock)
  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, estado, tenant_sucursal_id)
  VALUES (p_sucursal_id, 'egreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), 'completada', v_sucursal)
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    -- tenant-scoped SELECT FOR UPDATE
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal FOR UPDATE;

    IF v_stock_actual < (v_item->>'cantidad')::INT THEN
      RAISE EXCEPTION 'Stock insuficiente para %: disponible %, solicitado %',
        v_producto_nombre, v_stock_actual, (v_item->>'cantidad')::INT;
    END IF;

    -- tenant-scoped INSERT
    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario, sucursal_id)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT,
            COALESCE((v_item->>'costo_unitario')::DECIMAL, 0), v_sucursal);

    -- tenant-scoped UPDATE
    UPDATE productos SET stock = stock - (v_item->>'cantidad')::INT
    WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


-- ============================================================
-- 22. registrar_ingreso_sucursal
-- ============================================================
CREATE OR REPLACE FUNCTION public.registrar_ingreso_sucursal(
  p_sucursal_id bigint,
  p_fecha date DEFAULT CURRENT_DATE,
  p_notas text DEFAULT NULL,
  p_total_costo numeric DEFAULT 0,
  p_usuario_id uuid DEFAULT NULL,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_transferencia_id BIGINT; v_item JSONB;
  v_user_role TEXT;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- tenant-scoped INSERT (uses tenant_sucursal_id for transferencias_stock)
  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, estado, tenant_sucursal_id)
  VALUES (p_sucursal_id, 'ingreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), 'completada', v_sucursal)
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    -- tenant-scoped INSERT
    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario, sucursal_id)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT,
            COALESCE((v_item->>'costo_unitario')::DECIMAL, 0), v_sucursal);

    -- tenant-scoped UPDATE
    UPDATE productos SET stock = stock + (v_item->>'cantidad')::INT
    WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


-- ============================================================
-- 23. anular_compra_atomica
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
  v_sucursal BIGINT := current_sucursal_id();
  v_compra RECORD;
  v_item RECORD;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_user_role TEXT;
  v_errores TEXT[] := '{}';
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden anular compras');
  END IF;

  -- tenant-scoped compra lookup
  SELECT * INTO v_compra FROM compras WHERE id = p_compra_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;

  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra ya esta cancelada');
  END IF;

  -- Validate stock availability -- tenant-scoped
  FOR v_item IN
    SELECT ci.producto_id, ci.cantidad, p.stock, p.nombre
    FROM compra_items ci
    JOIN productos p ON p.id = ci.producto_id AND p.sucursal_id = v_sucursal
    WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal
    FOR UPDATE OF p
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

  -- Revert stock atomically -- tenant-scoped
  UPDATE productos p
  SET stock = p.stock - ci.cantidad,
      updated_at = NOW()
  FROM compra_items ci
  WHERE ci.compra_id = p_compra_id
    AND ci.sucursal_id = v_sucursal
    AND p.id = ci.producto_id
    AND p.sucursal_id = v_sucursal;

  -- Mark compra as cancelled -- tenant-scoped
  UPDATE compras
  SET estado = 'cancelada',
      updated_at = NOW()
  WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Compra anulada y stock revertido correctamente');
END;
$$;


-- ============================================================
-- 24. obtener_estadisticas_pedidos (may not exist yet as CREATE)
--     This function is referenced in migration 033 but never fully
--     defined in migrations. We create it here with tenant scope.
-- ============================================================
CREATE OR REPLACE FUNCTION public.obtener_estadisticas_pedidos(
  p_fecha_desde TIMESTAMPTZ DEFAULT NULL,
  p_fecha_hasta TIMESTAMPTZ DEFAULT NULL,
  p_usuario_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_resultado JSONB;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT jsonb_build_object(
    'total', COUNT(*),
    'pendientes', COUNT(*) FILTER (WHERE estado = 'pendiente'),
    'en_preparacion', COUNT(*) FILTER (WHERE estado = 'en_preparacion'),
    'en_reparto', COUNT(*) FILTER (WHERE estado = 'en_reparto'),
    'entregados', COUNT(*) FILTER (WHERE estado = 'entregado'),
    'cancelados', COUNT(*) FILTER (WHERE estado = 'cancelado'),
    'monto_total', COALESCE(SUM(total) FILTER (WHERE estado != 'cancelado'), 0),
    'monto_cobrado', COALESCE(SUM(monto_pagado) FILTER (WHERE estado = 'entregado'), 0)
  ) INTO v_resultado
  FROM pedidos
  WHERE sucursal_id = v_sucursal
    AND (p_fecha_desde IS NULL OR created_at >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR created_at <= p_fecha_hasta)
    AND (p_usuario_id IS NULL OR usuario_id = p_usuario_id);

  RETURN v_resultado;
END;
$$;


-- ============================================================
-- 25. audit_log_changes (TRIGGER FUNCTION)
--     Copy sucursal_id from the row being modified into audit_logs
-- ============================================================
CREATE OR REPLACE FUNCTION public.audit_log_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT; v_key TEXT;
  v_old_changed JSONB; v_new_changed JSONB;
  v_sucursal_id BIGINT;
BEGIN
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;

  -- Multi-tenant: extract sucursal_id from the row being modified
  -- Use NEW for INSERT/UPDATE, OLD for DELETE, fallback to current_sucursal_id()
  IF TG_OP = 'DELETE' THEN
    v_registro_id := OLD.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := NULL;
    v_sucursal_id := COALESCE((to_jsonb(OLD)->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSIF TG_OP = 'INSERT' THEN
    v_registro_id := NEW.id::TEXT;
    v_old_data := NULL;
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE((to_jsonb(NEW)->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSE
    v_registro_id := NEW.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE((to_jsonb(NEW)->>'sucursal_id')::BIGINT, (to_jsonb(OLD)->>'sucursal_id')::BIGINT, current_sucursal_id());

    -- Find changed fields and store only those
    v_campos_modificados := ARRAY[]::TEXT[];
    v_old_changed := '{}'::JSONB;
    v_new_changed := '{}'::JSONB;

    FOR v_key IN SELECT jsonb_object_keys(v_new_data) LOOP
      IF v_old_data->v_key IS DISTINCT FROM v_new_data->v_key THEN
        v_campos_modificados := array_append(v_campos_modificados, v_key);
        v_old_changed := v_old_changed || jsonb_build_object(v_key, v_old_data->v_key);
        v_new_changed := v_new_changed || jsonb_build_object(v_key, v_new_data->v_key);
      END IF;
    END LOOP;

    -- Skip if nothing actually changed
    IF array_length(v_campos_modificados, 1) IS NULL OR array_length(v_campos_modificados, 1) = 0 THEN
      RETURN NEW;
    END IF;

    v_old_data := v_old_changed;
    v_new_data := v_new_changed;
  END IF;

  INSERT INTO public.audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados, usuario_id, usuario_email, usuario_rol, sucursal_id)
  VALUES (TG_TABLE_NAME, v_registro_id, TG_OP, v_old_data, v_new_data, v_campos_modificados, v_usuario_id, v_usuario_email, v_usuario_rol, COALESCE(v_sucursal_id, 1));

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;


-- ============================================================
-- 26. registrar_cambio_stock (TRIGGER FUNCTION)
--     Copy sucursal_id from NEW into stock_historico
-- ============================================================
-- Note: This function was created via Supabase UI and referenced in migration 033.
-- We recreate it here with multi-tenant support.
CREATE OR REPLACE FUNCTION public.registrar_cambio_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.stock IS DISTINCT FROM NEW.stock THEN
    INSERT INTO stock_historico (producto_id, stock_anterior, stock_nuevo, diferencia, usuario_id, sucursal_id)
    VALUES (
      NEW.id,
      OLD.stock,
      NEW.stock,
      NEW.stock - OLD.stock,
      auth.uid(),
      NEW.sucursal_id
    );
  END IF;
  RETURN NEW;
END;
$$;


-- ============================================================
-- 27. actualizar_saldo_pedido (TRIGGER FUNCTION)
--     Filter clientes UPDATE by the pedido's sucursal_id
-- ============================================================
CREATE OR REPLACE FUNCTION actualizar_saldo_pedido()
RETURNS TRIGGER AS $$
DECLARE
  saldo_anterior NUMERIC;
  saldo_nuevo NUMERIC;
BEGIN
  IF TG_OP = 'INSERT' THEN
    saldo_nuevo := NEW.total - COALESCE(NEW.monto_pagado, 0);
    UPDATE clientes
    SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + saldo_nuevo
    WHERE id = NEW.cliente_id AND sucursal_id = NEW.sucursal_id;

  ELSIF TG_OP = 'DELETE' THEN
    saldo_anterior := OLD.total - COALESCE(OLD.monto_pagado, 0);
    UPDATE clientes
    SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - saldo_anterior
    WHERE id = OLD.cliente_id AND sucursal_id = OLD.sucursal_id;

  ELSIF TG_OP = 'UPDATE' THEN
    saldo_anterior := OLD.total - COALESCE(OLD.monto_pagado, 0);
    saldo_nuevo := NEW.total - COALESCE(NEW.monto_pagado, 0);

    IF saldo_anterior != saldo_nuevo THEN
      UPDATE clientes
      SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - saldo_anterior + saldo_nuevo
      WHERE id = NEW.cliente_id AND sucursal_id = NEW.sucursal_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- 28. obtener_estadisticas_salvedades
--     Add tenant filtering to all queries
-- ============================================================
CREATE OR REPLACE FUNCTION obtener_estadisticas_salvedades(
  p_fecha_desde DATE DEFAULT NULL,
  p_fecha_hasta DATE DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_resultado JSONB;
BEGIN
  -- Multi-tenant guard
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT jsonb_build_object(
    'total', COUNT(*),
    'pendientes', COUNT(*) FILTER (WHERE estado_resolucion = 'pendiente'),
    'resueltas', COUNT(*) FILTER (WHERE estado_resolucion NOT IN ('pendiente', 'anulada')),
    'anuladas', COUNT(*) FILTER (WHERE estado_resolucion = 'anulada'),
    'monto_total_afectado', COALESCE(SUM(monto_afectado), 0),
    'monto_pendiente', COALESCE(SUM(monto_afectado) FILTER (WHERE estado_resolucion = 'pendiente'), 0),
    'por_motivo', (
      SELECT jsonb_object_agg(motivo, cnt)
      FROM (
        SELECT motivo, COUNT(*) as cnt
        FROM salvedades_items
        WHERE sucursal_id = v_sucursal
          AND (p_fecha_desde IS NULL OR created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR created_at::date <= p_fecha_hasta)
        GROUP BY motivo
      ) t
    ),
    'por_resolucion', (
      SELECT jsonb_object_agg(estado_resolucion, cnt)
      FROM (
        SELECT estado_resolucion, COUNT(*) as cnt
        FROM salvedades_items
        WHERE sucursal_id = v_sucursal
          AND (p_fecha_desde IS NULL OR created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR created_at::date <= p_fecha_hasta)
        GROUP BY estado_resolucion
      ) t
    ),
    'por_producto', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto_id', producto_id,
        'producto_nombre', producto_nombre,
        'cantidad', cnt,
        'monto', monto,
        'unidades_afectadas', unidades
      ))
      FROM (
        SELECT
          s.producto_id,
          p.nombre as producto_nombre,
          COUNT(*) as cnt,
          SUM(s.monto_afectado) as monto,
          SUM(s.cantidad_afectada) as unidades
        FROM salvedades_items s
        JOIN productos p ON p.id = s.producto_id
        WHERE s.sucursal_id = v_sucursal
          AND (p_fecha_desde IS NULL OR s.created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR s.created_at::date <= p_fecha_hasta)
        GROUP BY s.producto_id, p.nombre
        ORDER BY cnt DESC
        LIMIT 10
      ) t
    ),
    'por_transportista', (
      SELECT jsonb_agg(jsonb_build_object(
        'transportista_id', transportista_id,
        'transportista_nombre', transportista_nombre,
        'cantidad', cnt,
        'monto', monto
      ))
      FROM (
        SELECT
          pe.transportista_id,
          pf.nombre as transportista_nombre,
          COUNT(*) as cnt,
          SUM(s.monto_afectado) as monto
        FROM salvedades_items s
        JOIN pedidos pe ON pe.id = s.pedido_id
        JOIN perfiles pf ON pf.id = pe.transportista_id
        WHERE s.sucursal_id = v_sucursal
          AND (p_fecha_desde IS NULL OR s.created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR s.created_at::date <= p_fecha_hasta)
        GROUP BY pe.transportista_id, pf.nombre
        ORDER BY cnt DESC
        LIMIT 10
      ) t
    )
  ) INTO v_resultado
  FROM salvedades_items
  WHERE sucursal_id = v_sucursal
    AND (p_fecha_desde IS NULL OR created_at::date >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR created_at::date <= p_fecha_hasta);

  RETURN v_resultado;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;


-- ============================================================
-- End of migration 059
-- ============================================================
