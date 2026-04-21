-- Migration 049: Fecha de entrega programada
--
-- Agrega campo fecha_entrega_programada a pedidos para programar entregas futuras.
-- Default: día siguiente a la fecha del pedido.
-- Esto permite filtrar pedidos por día de reparto y mejorar la asignación a transportistas.

-- 1. Agregar columna
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS fecha_entrega_programada DATE;

-- 2. Backfill: pedidos no entregados/cancelados → fecha del pedido + 1 día
UPDATE pedidos
SET fecha_entrega_programada = (COALESCE(fecha, created_at::date) + INTERVAL '1 day')::date
WHERE fecha_entrega_programada IS NULL
  AND estado NOT IN ('entregado', 'cancelado');

-- 3. Pedidos entregados: usar fecha_entrega real
UPDATE pedidos
SET fecha_entrega_programada = COALESCE(fecha_entrega::date, updated_at::date)
WHERE fecha_entrega_programada IS NULL
  AND estado = 'entregado';

-- 4. Pedidos cancelados: usar fecha + 1
UPDATE pedidos
SET fecha_entrega_programada = (COALESCE(fecha, created_at::date) + INTERVAL '1 day')::date
WHERE fecha_entrega_programada IS NULL
  AND estado = 'cancelado';

-- 5. Index para filtros rápidos por fecha programada
CREATE INDEX IF NOT EXISTS idx_pedidos_fecha_entrega_programada
ON pedidos(fecha_entrega_programada) WHERE estado NOT IN ('entregado', 'cancelado');

-- 6. Actualizar crear_pedido_completo con soporte fecha_entrega_programada
-- Drop la versión anterior (11 params)
DROP FUNCTION IF EXISTS public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric);

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
