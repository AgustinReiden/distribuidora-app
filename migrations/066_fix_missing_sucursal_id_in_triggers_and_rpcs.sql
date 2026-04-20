-- Migration 066: Fix remaining sucursal_id NOT-NULL violations in triggers/RPCs
--
-- Context: Migration 057 added `sucursal_id BIGINT NOT NULL` to 34 tenant-
-- scoped tables, but only trigger/RPC bodies touching `pedido_historial`
-- were retrofitted (migrations 060, 065). The remaining functions still
-- INSERT without sucursal_id and blow up at runtime:
--
--   * registrar_cambio_stock          ← stock_historico (blocks pedido create)
--   * registrar_salvedad              ← salvedades_items, salvedad_historial,
--                                       wrong table name ('mermas' not
--                                       'mermas_stock')
--   * resolver_salvedad, anular_salvedad ← salvedad_historial
--   * anular_salvedad                 ← pedido_items (restore path)
--   * crear_recorrido                 ← recorridos, recorrido_pedidos
--   * crear_rendicion_por_fecha       ← rendiciones, rendicion_items
--   * crear_rendicion_recorrido       ← rendiciones, rendicion_items
--   * registrar_transferencia         ← transferencias_stock.tenant_sucursal_id,
--                                       transferencia_items, productos scope
--   * registrar_ingreso_sucursal      ← same as registrar_transferencia
--
-- Resolution strategy:
--   - Triggers: use NEW.sucursal_id (the row's own tenant) since the parent
--     table already carries the column.
--   - User-facing RPCs: use current_sucursal_id() (header-resolved in
--     migration 061) and bail out with the same error message used elsewhere
--     when the session has no tenant.
--   - Transferencias: the historical `sucursal_id` column stored the
--     *destination* sucursal (cross-sucursal shipping, pre-multitenant).
--     Multitenant added `tenant_sucursal_id` (057) for tenant scoping.
--     We must set both: the function param is still the destination; the
--     tenant comes from current_sucursal_id().
--   - registrar_salvedad's "mermas" insert targeted a ghost table that never
--     existed — replace with the real `mermas_stock` schema (which has the
--     stock_anterior/stock_nuevo/sucursal_id NOT NULL columns) so the merma
--     path actually works.

-- ============================================================
-- 1. Trigger: registrar_cambio_stock (fires on productos UPDATE)
-- ============================================================
-- This is THE bug that blocks pedido creation: crear_pedido_completo
-- UPDATEs productos.stock, the trigger fires, and the INSERT into
-- stock_historico dies on sucursal_id NOT NULL. NEW.sucursal_id is the
-- product's tenant and is always present post-057.

CREATE OR REPLACE FUNCTION public.registrar_cambio_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF OLD.stock IS DISTINCT FROM NEW.stock THEN
    INSERT INTO stock_historico (producto_id, stock_anterior, stock_nuevo, origen, sucursal_id)
    VALUES (NEW.id, OLD.stock, NEW.stock, 'auto', NEW.sucursal_id);
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. RPC: registrar_salvedad
-- ============================================================
-- Adds sucursal_id to salvedades_items + salvedad_historial and
-- rewrites the broken "mermas" insert to the real mermas_stock schema.

CREATE OR REPLACE FUNCTION public.registrar_salvedad(
  p_pedido_id bigint,
  p_pedido_item_id bigint,
  p_cantidad_afectada integer,
  p_motivo character varying,
  p_descripcion text DEFAULT NULL::text,
  p_foto_url text DEFAULT NULL::text,
  p_devolver_stock boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad_id BIGINT;
  v_item RECORD;
  v_cantidad_entregada INTEGER;
  v_monto_afectado DECIMAL;
  v_usuario_id UUID;
  v_es_admin BOOLEAN;
  v_subtotal_nuevo DECIMAL;
  v_stock_devuelto BOOLEAN := FALSE;
  v_merma_registrada BOOLEAN := FALSE;
  v_stock_actual INTEGER;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_usuario_id := auth.uid();
  IF v_usuario_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Usuario no autenticado');
  END IF;

  SELECT EXISTS (SELECT 1 FROM perfiles WHERE id = v_usuario_id AND rol = 'admin') INTO v_es_admin;

  IF NOT v_es_admin THEN
    IF NOT EXISTS (
      SELECT 1 FROM pedidos
      WHERE id = p_pedido_id AND transportista_id = v_usuario_id AND sucursal_id = v_sucursal
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'No autorizado para este pedido');
    END IF;
  END IF;

  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal
  INTO v_item
  FROM pedido_items pi
  WHERE pi.id = p_pedido_item_id
    AND pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal;

  IF v_item IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item de pedido no encontrado');
  END IF;

  IF p_cantidad_afectada > v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a cantidad del item');
  END IF;

  IF p_cantidad_afectada <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad debe ser mayor a 0');
  END IF;

  v_cantidad_entregada := v_item.cantidad - p_cantidad_afectada;
  v_monto_afectado := p_cantidad_afectada * v_item.precio_unitario;
  v_subtotal_nuevo := v_cantidad_entregada * v_item.precio_unitario;

  IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN
    v_stock_devuelto := TRUE;
  END IF;

  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
    cantidad_entregada, motivo, descripcion, foto_url, monto_afectado, precio_unitario,
    reportado_por, stock_devuelto, stock_devuelto_at, estado_resolucion, sucursal_id
  ) VALUES (
    p_pedido_id, p_pedido_item_id, v_item.producto_id, v_item.cantidad, p_cantidad_afectada,
    v_cantidad_entregada, p_motivo, p_descripcion, p_foto_url, v_monto_afectado, v_item.precio_unitario,
    v_usuario_id, v_stock_devuelto, CASE WHEN v_stock_devuelto THEN NOW() ELSE NULL END, 'pendiente', v_sucursal
  ) RETURNING id INTO v_salvedad_id;

  IF v_salvedad_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo crear la salvedad';
  END IF;

  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items
       SET cantidad = v_cantidad_entregada, subtotal = v_subtotal_nuevo
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    DELETE FROM pedido_items WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  END IF;

  UPDATE pedidos
     SET total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal),
         updated_at = NOW()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  IF v_stock_devuelto THEN
    UPDATE productos SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;

  -- Merma: the previous version inserted into a non-existent table
  -- `mermas`. The real table is `mermas_stock` and it requires
  -- stock_anterior/stock_nuevo/sucursal_id (all NOT NULL).
  IF p_motivo IN ('producto_danado', 'producto_vencido') THEN
    SELECT stock INTO v_stock_actual FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal FOR UPDATE;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_item.producto_id,
      p_cantidad_afectada,
      CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento' END,
      COALESCE(p_descripcion, 'Salvedad pedido #' || p_pedido_id || ': ' || p_motivo),
      v_stock_actual,
      GREATEST(v_stock_actual - p_cantidad_afectada, 0),
      v_usuario_id,
      v_sucursal
    );

    UPDATE productos SET stock = GREATEST(stock - p_cantidad_afectada, 0)
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    v_merma_registrada := TRUE;
  END IF;

  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object(
    'success', true, 'salvedad_id', v_salvedad_id, 'monto_afectado', v_monto_afectado,
    'cantidad_entregada', v_cantidad_entregada, 'stock_devuelto', v_stock_devuelto,
    'merma_registrada', v_merma_registrada,
    'nuevo_total_pedido', (SELECT total FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ============================================================
-- 3. RPC: resolver_salvedad
-- ============================================================

CREATE OR REPLACE FUNCTION public.resolver_salvedad(
  p_salvedad_id bigint,
  p_estado_resolucion character varying,
  p_notas text DEFAULT NULL::text,
  p_pedido_reprogramado_id bigint DEFAULT NULL::bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;

  SELECT * INTO v_salvedad FROM salvedades_items
   WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'No encontrada');
  END IF;

  IF v_salvedad.estado_resolucion != 'pendiente' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya resuelta');
  END IF;

  UPDATE salvedades_items SET
    estado_resolucion = p_estado_resolucion,
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    pedido_reprogramado_id = p_pedido_reprogramado_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;

  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'resolucion', v_salvedad.estado_resolucion, p_estado_resolucion, p_notas, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object('success', true, 'nuevo_estado', p_estado_resolucion);
END;
$$;

-- ============================================================
-- 4. RPC: anular_salvedad
-- ============================================================

CREATE OR REPLACE FUNCTION public.anular_salvedad(p_salvedad_id bigint, p_notas text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;

  SELECT * INTO v_salvedad FROM salvedades_items
   WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'No encontrada');
  END IF;

  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;

  -- Restaurar item
  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
    UPDATE pedido_items SET
      cantidad = v_salvedad.cantidad_original,
      subtotal = v_salvedad.cantidad_original * v_salvedad.precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES (v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_original,
            v_salvedad.precio_unitario, v_salvedad.cantidad_original * v_salvedad.precio_unitario, v_sucursal);
  END IF;

  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;

  IF v_salvedad.stock_devuelto THEN
    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
  END IF;

  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;

  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object('success', true);
END;
$$;

-- ============================================================
-- 5. RPC: crear_recorrido
-- ============================================================
-- recorridos + recorrido_pedidos both carry NOT NULL sucursal_id.

CREATE OR REPLACE FUNCTION public.crear_recorrido(
  p_transportista_id uuid,
  p_pedidos jsonb,
  p_distancia numeric DEFAULT NULL::numeric,
  p_duracion integer DEFAULT NULL::integer
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_recorrido_id BIGINT;
  v_pedido JSONB;
  v_total_facturado DECIMAL := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  SELECT COALESCE(SUM(total), 0) INTO v_total_facturado
    FROM pedidos
   WHERE id IN (SELECT (value->>'pedido_id')::BIGINT FROM jsonb_array_elements(p_pedidos) AS value)
     AND sucursal_id = v_sucursal;

  INSERT INTO recorridos (
    transportista_id, fecha, distancia_total, duracion_total,
    total_pedidos, total_facturado, estado, sucursal_id
  ) VALUES (
    p_transportista_id, CURRENT_DATE, p_distancia, p_duracion,
    jsonb_array_length(p_pedidos), v_total_facturado, 'en_curso', v_sucursal
  ) RETURNING id INTO v_recorrido_id;

  FOR v_pedido IN SELECT * FROM jsonb_array_elements(p_pedidos) LOOP
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
$$;

-- ============================================================
-- 6. RPC: crear_rendicion_por_fecha
-- ============================================================

CREATE OR REPLACE FUNCTION public.crear_rendicion_por_fecha(
  p_transportista_id uuid,
  p_fecha date DEFAULT CURRENT_DATE
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  IF EXISTS (
    SELECT 1 FROM rendiciones
    WHERE transportista_id = p_transportista_id AND fecha = p_fecha AND sucursal_id = v_sucursal
  ) THEN
    RAISE EXCEPTION 'Ya existe una rendición para este transportista en esta fecha';
  END IF;

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
    IF v_pedido.forma_pago = 'efectivo' THEN
      v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE
      v_total_otros := v_total_otros + v_pedido.monto_pagado;
    END IF;
  END LOOP;

  INSERT INTO rendiciones (
    recorrido_id, transportista_id, fecha,
    total_efectivo_esperado, total_otros_medios, estado, sucursal_id
  ) VALUES (
    NULL, p_transportista_id, p_fecha,
    v_total_efectivo, v_total_otros, 'pendiente', v_sucursal
  ) RETURNING id INTO v_rendicion_id;

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
$$;

-- ============================================================
-- 7. RPC: crear_rendicion_recorrido
-- ============================================================

CREATE OR REPLACE FUNCTION public.crear_rendicion_recorrido(
  p_recorrido_id bigint,
  p_transportista_id uuid DEFAULT NULL::uuid
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
  v_transportista_real UUID;
  v_es_admin BOOLEAN;
BEGIN
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

  IF NOT EXISTS (
    SELECT 1 FROM recorridos
    WHERE id = p_recorrido_id
      AND sucursal_id = v_sucursal
      AND (transportista_id = v_transportista_real OR v_es_admin)
  ) THEN
    RAISE EXCEPTION 'Recorrido no válido o no pertenece al transportista';
  END IF;

  IF EXISTS (SELECT 1 FROM rendiciones WHERE recorrido_id = p_recorrido_id AND sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'Ya existe una rendición para este recorrido';
  END IF;

  FOR v_pedido IN
    SELECT p.id, COALESCE(p.monto_pagado, 0) as monto_pagado, COALESCE(p.forma_pago, 'efectivo') as forma_pago
      FROM pedidos p
      JOIN recorrido_pedidos rp ON rp.pedido_id = p.id AND rp.sucursal_id = v_sucursal
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

  INSERT INTO rendiciones (
    recorrido_id, transportista_id, fecha,
    total_efectivo_esperado, total_otros_medios, estado, sucursal_id
  ) VALUES (
    p_recorrido_id, v_transportista_real, CURRENT_DATE,
    v_total_efectivo, v_total_otros, 'pendiente', v_sucursal
  ) RETURNING id INTO v_rendicion_id;

  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago, sucursal_id)
  SELECT v_rendicion_id, p.id,
         COALESCE(p.monto_pagado, 0),
         COALESCE(p.forma_pago, 'efectivo'),
         v_sucursal
    FROM pedidos p
    JOIN recorrido_pedidos rp ON rp.pedido_id = p.id AND rp.sucursal_id = v_sucursal
   WHERE rp.recorrido_id = p_recorrido_id
     AND rp.estado_entrega = 'entregado'
     AND p.estado = 'entregado'
     AND p.sucursal_id = v_sucursal;

  RETURN v_rendicion_id;
END;
$$;

-- ============================================================
-- 8. RPC: registrar_transferencia (egreso)
-- ============================================================
-- `sucursal_id` remains the destination (legacy cross-branch shipping),
-- `tenant_sucursal_id` is the multitenant owner (= current tenant).

CREATE OR REPLACE FUNCTION public.registrar_transferencia(
  p_sucursal_id bigint,
  p_fecha date DEFAULT CURRENT_DATE,
  p_notas text DEFAULT NULL::text,
  p_total_costo numeric DEFAULT 0,
  p_usuario_id uuid DEFAULT NULL::uuid,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_tenant BIGINT := current_sucursal_id();
  v_transferencia_id BIGINT;
  v_item JSONB;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_user_role TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- NOTE: transferencias_stock has no `estado` column in this deployment
  -- (the previous function body referenced one that was never added; the
  -- function has therefore been dead code since 057). Omit it here.
  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, tenant_sucursal_id)
  VALUES (p_sucursal_id, 'egreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), v_tenant)
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      RAISE EXCEPTION 'Producto % no encontrado en la sucursal', (v_item->>'producto_id');
    END IF;

    IF v_stock_actual < (v_item->>'cantidad')::INT THEN
      RAISE EXCEPTION 'Stock insuficiente para %: disponible %, solicitado %',
        v_producto_nombre, v_stock_actual, (v_item->>'cantidad')::INT;
    END IF;

    INSERT INTO transferencia_items (
      transferencia_id, producto_id, cantidad, costo_unitario,
      subtotal, stock_anterior, stock_nuevo, sucursal_id
    ) VALUES (
      v_transferencia_id,
      (v_item->>'producto_id')::BIGINT,
      (v_item->>'cantidad')::INT,
      COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
      (v_item->>'cantidad')::INT * COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
      v_stock_actual,
      v_stock_actual - (v_item->>'cantidad')::INT,
      v_tenant
    );

    UPDATE productos SET stock = stock - (v_item->>'cantidad')::INT
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ============================================================
-- 9. RPC: registrar_ingreso_sucursal
-- ============================================================

CREATE OR REPLACE FUNCTION public.registrar_ingreso_sucursal(
  p_sucursal_id bigint,
  p_fecha date DEFAULT CURRENT_DATE,
  p_notas text DEFAULT NULL::text,
  p_total_costo numeric DEFAULT 0,
  p_usuario_id uuid DEFAULT NULL::uuid,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_tenant BIGINT := current_sucursal_id();
  v_transferencia_id BIGINT;
  v_item JSONB;
  v_stock_actual INT;
  v_user_role TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, tenant_sucursal_id)
  VALUES (p_sucursal_id, 'ingreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), v_tenant)
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT stock INTO v_stock_actual
      FROM productos
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      RAISE EXCEPTION 'Producto % no encontrado en la sucursal', (v_item->>'producto_id');
    END IF;

    INSERT INTO transferencia_items (
      transferencia_id, producto_id, cantidad, costo_unitario,
      subtotal, stock_anterior, stock_nuevo, sucursal_id
    ) VALUES (
      v_transferencia_id,
      (v_item->>'producto_id')::BIGINT,
      (v_item->>'cantidad')::INT,
      COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
      (v_item->>'cantidad')::INT * COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
      v_stock_actual,
      v_stock_actual + (v_item->>'cantidad')::INT,
      v_tenant
    );

    UPDATE productos SET stock = stock + (v_item->>'cantidad')::INT
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
