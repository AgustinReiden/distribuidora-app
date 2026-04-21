-- Fix: Multiple RPC security issues + add fecha parameter to crear_pedido_completo
--
-- Problems fixed:
-- 1. Legacy eliminar_pedido_completo(integer, boolean) overload was NOT SECURITY DEFINER
-- 2. obtener_resumen_cuenta_cliente was NOT SECURITY DEFINER (incorrect data for preventistas)
-- 3. descontar_stock_atomico was NOT SECURITY DEFINER (failed for preventistas)
-- 4. restaurar_stock_atomico was NOT SECURITY DEFINER (failed for preventistas)
-- 5. crear_pedido_completo old overload (7 params without p_fecha) needed cleanup
-- 6. Added p_fecha parameter to crear_pedido_completo for user-selectable order date

-- Drop legacy eliminar_pedido_completo overload (non-SECURITY DEFINER)
DROP FUNCTION IF EXISTS public.eliminar_pedido_completo(integer, boolean);

-- Drop old crear_pedido_completo overload (7 params, without p_fecha)
DROP FUNCTION IF EXISTS public.crear_pedido_completo(integer, numeric, uuid, jsonb, text, text, text);

-- Make obtener_resumen_cuenta_cliente SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.obtener_resumen_cuenta_cliente(p_cliente_id integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_total_pedidos NUMERIC;
  v_total_pagado NUMERIC;
  v_saldo NUMERIC;
  v_user_role TEXT;
BEGIN
  -- Auth check
  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('error', 'No autorizado');
  END IF;

  SELECT COALESCE(SUM(total), 0) INTO v_total_pedidos
  FROM pedidos WHERE cliente_id = p_cliente_id AND estado != 'cancelado';

  SELECT COALESCE(SUM(monto), 0) INTO v_total_pagado
  FROM pagos WHERE cliente_id = p_cliente_id;

  v_saldo := v_total_pedidos - v_total_pagado;

  RETURN jsonb_build_object(
    'total_pedidos', v_total_pedidos,
    'total_pagado', v_total_pagado,
    'saldo', v_saldo
  );
END;
$function$;

-- Make descontar_stock_atomico SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.descontar_stock_atomico(p_producto_id integer, p_cantidad integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_user_role TEXT;
BEGIN
  -- Auth check
  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'deposito') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
  FROM productos WHERE id = p_producto_id FOR UPDATE;

  IF v_stock_actual IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Producto no encontrado');
  END IF;

  IF v_stock_actual < p_cantidad THEN
    RETURN jsonb_build_object('success', false, 'error',
      v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || p_cantidad || ')');
  END IF;

  UPDATE productos SET stock = stock - p_cantidad WHERE id = p_producto_id;

  RETURN jsonb_build_object('success', true, 'stock_anterior', v_stock_actual, 'stock_nuevo', v_stock_actual - p_cantidad);
END;
$function$;

-- Make restaurar_stock_atomico SECURITY DEFINER
CREATE OR REPLACE FUNCTION public.restaurar_stock_atomico(p_producto_id integer, p_cantidad integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_stock_actual INT;
  v_user_role TEXT;
BEGIN
  -- Auth check
  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'deposito') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  SELECT stock INTO v_stock_actual FROM productos WHERE id = p_producto_id FOR UPDATE;

  IF v_stock_actual IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Producto no encontrado');
  END IF;

  UPDATE productos SET stock = stock + p_cantidad WHERE id = p_producto_id;

  RETURN jsonb_build_object('success', true, 'stock_anterior', v_stock_actual, 'stock_nuevo', v_stock_actual + p_cantidad);
END;
$function$;

-- Updated crear_pedido_completo with p_fecha parameter
CREATE OR REPLACE FUNCTION public.crear_pedido_completo(
  p_cliente_id integer,
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
  v_stock_actual INT;
  v_producto_nombre TEXT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
BEGIN
  -- Authorization check: only admin and preventista can create orders
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos'));
  END IF;

  -- 1. Verificar stock de todos los productos (con bloqueo)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id || ': debe ser mayor a 0');
      CONTINUE;
    END IF;

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

  -- 2. Crear el pedido with user-selected fecha
  INSERT INTO pedidos (cliente_id, fecha, total, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago)
  VALUES (p_cliente_id, p_fecha, p_total, 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago)
  RETURNING id INTO v_pedido_id;

  -- 3. Crear los items y descontar stock
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;

    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal)
    VALUES (v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario);

    UPDATE productos
    SET stock = stock - v_cantidad
    WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;
