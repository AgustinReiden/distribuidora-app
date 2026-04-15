-- Migration 051: Critical security fixes from backend audit
-- Fixes: run_sql injection, stock_historico RLS, missing auth checks on RPCs

-- ============================================================
-- 1. DROP run_sql - Critical SQL injection vulnerability
-- This SECURITY DEFINER function executes arbitrary SQL
-- ============================================================
DROP FUNCTION IF EXISTS public.run_sql(text);

-- ============================================================
-- 2. Enable RLS on stock_historico (only table without it)
-- ============================================================
ALTER TABLE public.stock_historico ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stock_historico_select_authenticated"
  ON public.stock_historico FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "stock_historico_insert_admin"
  ON public.stock_historico FOR INSERT
  TO authenticated
  WITH CHECK (es_admin());

-- ============================================================
-- 3. Fix cancelar_pedido_con_stock - add auth check
-- Currently SECURITY DEFINER with NO role verification
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
BEGIN
  -- Auth check: only admin or encargado can cancel
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
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
    COALESCE(p_usuario_id, auth.uid()),
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
-- 4. Fix eliminar_pedido_completo - add auth check + SECURITY DEFINER
-- Drop old overload with different param order
-- ============================================================
DROP FUNCTION IF EXISTS public.eliminar_pedido_completo(bigint, boolean, uuid, text);

CREATE OR REPLACE FUNCTION public.eliminar_pedido_completo(
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
  -- Auth check: only admin can delete orders
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
    FOR v_item IN SELECT producto_id, cantidad FROM pedido_items WHERE pedido_id = p_pedido_id LOOP
      UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
    END LOOP;
  END IF;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id;
  DELETE FROM pedidos WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$$;

-- ============================================================
-- 5. Fix descontar_stock_atomico - add auth check + SECURITY DEFINER
-- ============================================================
CREATE OR REPLACE FUNCTION public.descontar_stock_atomico(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item JSONB; v_producto_id INT; v_cantidad INT;
  v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
BEGIN
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

    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos WHERE id = v_producto_id FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
    ELSE
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id;
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  RETURN jsonb_build_object('success', true, 'errores', '[]'::jsonb);
END;
$$;

-- ============================================================
-- 6. Fix restaurar_stock_atomico - add auth check + SECURITY DEFINER
-- ============================================================
CREATE OR REPLACE FUNCTION public.restaurar_stock_atomico(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item JSONB; v_producto_id INT; v_cantidad INT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
BEGIN
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

    UPDATE productos SET stock = stock + v_cantidad WHERE id = v_producto_id;
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
-- 7. Fix registrar_compra_completa - add auth + FOR UPDATE + SECURITY DEFINER
-- Drop old overload with defaults and p_tipo_factura param
-- ============================================================
DROP FUNCTION IF EXISTS public.registrar_compra_completa(bigint, character varying, character varying, date, numeric, numeric, numeric, numeric, character varying, text, uuid, jsonb, text);
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
  -- Auth check
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  INSERT INTO compras (proveedor_id, proveedor_nombre, numero_factura, fecha_compra, subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado)
  VALUES (p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra, p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida')
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    -- Use FOR UPDATE to prevent concurrent stock reads
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

    -- Use stock = stock + cantidad to prevent race conditions
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
-- 8. Fix registrar_ingreso_sucursal - add auth check
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
  v_transferencia_id BIGINT; v_item JSONB;
  v_user_role TEXT;
BEGIN
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, estado)
  VALUES (p_sucursal_id, 'ingreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), 'completada')
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT, COALESCE((v_item->>'costo_unitario')::DECIMAL, 0));

    UPDATE productos SET stock = stock + (v_item->>'cantidad')::INT WHERE id = (v_item->>'producto_id')::BIGINT;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ============================================================
-- 9. Fix registrar_transferencia - add auth check
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
  v_transferencia_id BIGINT; v_item JSONB;
  v_stock_actual INT; v_producto_nombre TEXT;
  v_user_role TEXT;
BEGIN
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, estado)
  VALUES (p_sucursal_id, 'egreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), 'completada')
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos WHERE id = (v_item->>'producto_id')::BIGINT FOR UPDATE;

    IF v_stock_actual < (v_item->>'cantidad')::INT THEN
      RAISE EXCEPTION 'Stock insuficiente para %: disponible %, solicitado %',
        v_producto_nombre, v_stock_actual, (v_item->>'cantidad')::INT;
    END IF;

    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT, COALESCE((v_item->>'costo_unitario')::DECIMAL, 0));

    UPDATE productos SET stock = stock - (v_item->>'cantidad')::INT WHERE id = (v_item->>'producto_id')::BIGINT;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
