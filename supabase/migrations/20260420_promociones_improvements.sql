-- Promociones: fix 403 + prioridad + regalo_mueve_stock + ajuste acumulado
--
-- 1. Trigger generico que popula sucursal_id en INSERT (fix del 403 en promociones)
-- 2. Columnas `prioridad` y `regalo_mueve_stock` en promociones
-- 3. Columnas `unidades_ajustadas` y `merma_id` en promo_ajustes
-- 4. RPCs crear_pedido_completo / actualizar_pedido_items / cancelar_pedido_con_stock /
--    eliminar_pedido_completo honran `regalo_mueve_stock`
-- 5. Nueva RPC `ajustar_stock_promocion_completo` hace merma + stock + ajuste atomicos

-- ============================================================================
-- 1. Trigger generico set_sucursal_id_default
-- ============================================================================

CREATE OR REPLACE FUNCTION public.set_sucursal_id_default()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.sucursal_id IS NULL THEN
    NEW.sucursal_id := current_sucursal_id();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_promociones_sucursal ON promociones;
CREATE TRIGGER trg_promociones_sucursal
  BEFORE INSERT ON promociones
  FOR EACH ROW EXECUTE FUNCTION set_sucursal_id_default();

DROP TRIGGER IF EXISTS trg_promocion_productos_sucursal ON promocion_productos;
CREATE TRIGGER trg_promocion_productos_sucursal
  BEFORE INSERT ON promocion_productos
  FOR EACH ROW EXECUTE FUNCTION set_sucursal_id_default();

DROP TRIGGER IF EXISTS trg_promocion_reglas_sucursal ON promocion_reglas;
CREATE TRIGGER trg_promocion_reglas_sucursal
  BEFORE INSERT ON promocion_reglas
  FOR EACH ROW EXECUTE FUNCTION set_sucursal_id_default();

DROP TRIGGER IF EXISTS trg_promo_ajustes_sucursal ON promo_ajustes;
CREATE TRIGGER trg_promo_ajustes_sucursal
  BEFORE INSERT ON promo_ajustes
  FOR EACH ROW EXECUTE FUNCTION set_sucursal_id_default();

-- ============================================================================
-- 2. Columnas en promociones
-- ============================================================================

ALTER TABLE promociones
  ADD COLUMN IF NOT EXISTS prioridad INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS regalo_mueve_stock BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN promociones.prioridad IS 'Desempate manual cuando dos promos superpuestas aplican al mismo pedido. Mayor = gana.';
COMMENT ON COLUMN promociones.regalo_mueve_stock IS 'Si TRUE, el item bonificado descuenta stock del producto regalo (como una venta con precio 0). Si FALSE, el stock se ajusta manualmente via ajustar_stock_promocion_completo.';

CREATE INDEX IF NOT EXISTS idx_promociones_prioridad
  ON promociones(sucursal_id, activo, prioridad DESC);

-- ============================================================================
-- 3. Columnas en promo_ajustes
-- ============================================================================

ALTER TABLE promo_ajustes
  ADD COLUMN IF NOT EXISTS unidades_ajustadas INT,
  ADD COLUMN IF NOT EXISTS producto_id BIGINT REFERENCES productos(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS merma_id BIGINT REFERENCES mermas_stock(id) ON DELETE SET NULL;

COMMENT ON COLUMN promo_ajustes.unidades_ajustadas IS 'Unidades descontadas del stock del producto ajustado (puede diferir de usos_ajustados si hay conversion de unidades).';
COMMENT ON COLUMN promo_ajustes.producto_id IS 'Producto al que se le descontó el stock en este ajuste.';
COMMENT ON COLUMN promo_ajustes.merma_id IS 'Referencia a la merma_stock generada por este ajuste.';

-- ============================================================================
-- 4. RPC crear_pedido_completo: honrar regalo_mueve_stock
-- ============================================================================

CREATE OR REPLACE FUNCTION public.crear_pedido_completo(
  p_cliente_id bigint,
  p_total numeric,
  p_usuario_id uuid,
  p_items jsonb,
  p_notas text DEFAULT NULL::text,
  p_forma_pago text DEFAULT 'efectivo'::text,
  p_estado_pago text DEFAULT 'pendiente'::text,
  p_fecha date DEFAULT NULL::date,
  p_tipo_factura text DEFAULT 'ZZ'::text,
  p_total_neto numeric DEFAULT NULL::numeric,
  p_total_iva numeric DEFAULT 0,
  p_fecha_entrega_programada date DEFAULT NULL::date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido_id INT; item JSONB; v_producto_id INT; v_cantidad INT;
  v_precio_unitario DECIMAL; v_es_bonificacion BOOLEAN; v_promocion_id BIGINT;
  v_neto_unitario DECIMAL; v_iva_unitario DECIMAL; v_imp_internos_unitario DECIMAL;
  v_porcentaje_iva DECIMAL; v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}'; v_user_role TEXT;
  v_cantidades_totales JSONB := '{}'::JSONB; v_cant_acumulada INT;
  v_regalo_mueve_stock BOOLEAN;
  v_fecha_pedido DATE := COALESCE(
    p_fecha,
    (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
  );
  v_fecha_entrega DATE := COALESCE(
    p_fecha_entrega_programada,
    (v_fecha_pedido + INTERVAL '1 day')::date
  );
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesion autenticada')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- Acumular cantidades por producto para bonificaciones (bonif NO consume stock aquí salvo que mueva_stock)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN errores := array_append(errores, 'Cantidad invalida para producto ID ' || v_producto_id); CONTINUE; END IF;

    -- Consume stock si no es bonif, O si es bonif con regalo_mueve_stock
    IF NOT v_es_bonificacion THEN
      v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
      v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
        v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
      END IF;
    END IF;
  END LOOP;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')'); END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, tipo_factura, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)
  VALUES (p_cliente_id, v_fecha_pedido, p_total, COALESCE(p_total_neto, p_total), COALESCE(p_total_iva, 0), COALESCE(p_tipo_factura, 'ZZ'), 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)
  RETURNING id INTO v_pedido_id;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_neto_unitario := (item->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((item->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((item->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((item->>'porcentaje_iva')::DECIMAL, 0);
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id)
    VALUES (v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario, v_es_bonificacion, v_promocion_id, v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva, v_sucursal);

    -- Descontar stock
    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- ============================================================================
-- 5. RPC actualizar_pedido_items: honrar regalo_mueve_stock en restore/deduct
-- ============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(
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
  v_regalo_mueve_stock BOOLEAN;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['ID de usuario no coincide con la sesion autenticada']);
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  -- Phase 1: validar stock para items nuevos que requieren MAS stock
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    IF v_es_bonificacion THEN
      IF v_promocion_id IS NULL THEN CONTINUE; END IF;
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN CONTINUE; END IF;
    END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
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

  -- Phase 2: restaurar stock de items originales no-bonif
  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id
    AND p.sucursal_id = v_sucursal;

  -- Phase 2b: restaurar stock de items originales bonif cuando la promo movia stock
  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
    AND p.id = pi.producto_id
    AND p.sucursal_id = v_sucursal;

  -- Restaurar usos_pendientes originales
  UPDATE promociones pr
  SET usos_pendientes = GREATEST(pr.usos_pendientes - pi.cantidad, 0)
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND pr.id = pi.promocion_id
    AND pr.sucursal_id = v_sucursal;

  -- Phase 3: borrar items viejos e insertar nuevos
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

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva
      WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * COALESCE(v_neto_unitario, v_precio_unitario));
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva
        WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva
      WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  UPDATE pedidos SET
    total = v_total_nuevo,
    total_neto = v_total_neto_nuevo,
    total_iva = v_total_iva_nuevo,
    updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT, v_sucursal);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$$;

-- ============================================================================
-- 6. RPC cancelar_pedido_con_stock: restaurar stock de bonif con mueve_stock
-- ============================================================================

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
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_acting_user := auth.uid();
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM v_acting_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden cancelar pedidos');
  END IF;

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

  FOR v_item IN
    SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
           pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
    FROM pedido_items pi
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
    WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
    IF v_item.es_bonificacion THEN
      IF v_item.promocion_id IS NOT NULL THEN
        UPDATE promociones
        SET usos_pendientes = GREATEST(usos_pendientes - v_item.cantidad, 0)
        WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
      END IF;
      IF v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad
      WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
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
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

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

-- ============================================================================
-- 7. RPC eliminar_pedido_completo: restaurar stock de bonif con mueve_stock
-- ============================================================================

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
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD; v_items JSONB; v_cliente_nombre TEXT; v_cliente_direccion TEXT;
  v_usuario_creador_nombre TEXT; v_transportista_nombre TEXT := NULL;
  v_eliminador_nombre TEXT := NULL; v_item RECORD;
  v_user_role TEXT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role != 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo administradores pueden eliminar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;

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
    FOR v_item IN
      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF NOT v_item.es_bonificacion OR v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    END LOOP;
  END IF;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$$;

-- ============================================================================
-- 8. RPC ajustar_stock_promocion_completo: merma + stock + ajuste atomicos
-- ============================================================================

CREATE OR REPLACE FUNCTION public.ajustar_stock_promocion_completo(
  p_promocion_id BIGINT,
  p_producto_id BIGINT,
  p_cantidad_stock INT,
  p_usos_ajustados INT,
  p_usuario_id UUID,
  p_observaciones TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_user_role TEXT;
  v_stock_anterior INT;
  v_stock_nuevo INT;
  v_producto_nombre TEXT;
  v_usos_pendientes INT;
  v_promo_nombre TEXT;
  v_merma_id BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role != 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede ajustar stock por promos');
  END IF;

  IF p_cantidad_stock IS NULL OR p_cantidad_stock <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'La cantidad a descontar del stock debe ser mayor a 0');
  END IF;

  IF p_usos_ajustados IS NULL OR p_usos_ajustados <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Los usos a resolver deben ser mayor a 0');
  END IF;

  SELECT nombre, usos_pendientes INTO v_promo_nombre, v_usos_pendientes
  FROM promociones WHERE id = p_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promocion no encontrada');
  END IF;

  IF p_usos_ajustados > COALESCE(v_usos_pendientes, 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se pueden ajustar mas usos (' || p_usos_ajustados || ') que los pendientes (' || COALESCE(v_usos_pendientes, 0) || ')');
  END IF;

  SELECT stock, nombre INTO v_stock_anterior, v_producto_nombre
  FROM productos WHERE id = p_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Producto no encontrado');
  END IF;

  IF v_stock_anterior < p_cantidad_stock THEN
    RETURN jsonb_build_object('success', false, 'error',
      v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_anterior || ', solicitado: ' || p_cantidad_stock || ')');
  END IF;

  v_stock_nuevo := v_stock_anterior - p_cantidad_stock;

  INSERT INTO mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    p_producto_id, p_cantidad_stock, 'promociones',
    COALESCE(p_observaciones, '') || ' (Promo: ' || v_promo_nombre || ')',
    v_stock_anterior, v_stock_nuevo, p_usuario_id, v_sucursal
  )
  RETURNING id INTO v_merma_id;

  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
  WHERE id = p_producto_id AND sucursal_id = v_sucursal;

  INSERT INTO promo_ajustes (
    promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
    merma_id, usuario_id, observaciones, sucursal_id
  ) VALUES (
    p_promocion_id, p_usos_ajustados, p_cantidad_stock, p_producto_id,
    v_merma_id, p_usuario_id, p_observaciones, v_sucursal
  );

  UPDATE promociones
  SET usos_pendientes = GREATEST(usos_pendientes - p_usos_ajustados, 0)
  WHERE id = p_promocion_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'success', true,
    'merma_id', v_merma_id,
    'stock_anterior', v_stock_anterior,
    'stock_nuevo', v_stock_nuevo,
    'usos_ajustados', p_usos_ajustados
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.ajustar_stock_promocion_completo(BIGINT, BIGINT, INT, INT, UUID, TEXT) TO authenticated;
