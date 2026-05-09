-- Migration 038: endurecer creacion de pedidos + trazabilidad de stock
--
-- A) pedido_items.stock_al_crear: snapshot del stock disponible al momento
--    de validar el item en crear_pedido_completo / _bot. Permite auditar
--    reclamos del tipo "se vendio un producto sin stock" con evidencia
--    objetiva (no inferencia desde stock_historico).
--
-- B) Trigger registrar_cambio_stock: ahora lee referencia/usuario/origen
--    desde session settings (set_config local a la transaccion). Si la
--    RPC que origino el cambio los seteo, los persiste; sino, fallback a
--    'auto' como antes (comportamiento backward-compatible).
--
-- C) crear_pedido_completo + crear_pedido_completo_bot: dos cambios:
--    1. Validar stock para TODA cantidad pedida, incluyendo bonificaciones
--       con regalo_mueve_stock=false. El flag controla solo el descuento,
--       no la validacion.
--    2. Capturar v_stock_actual en el loop de validacion y propagarlo a
--       pedido_items.stock_al_crear (mismo valor para todos los items del
--       mismo producto en el mismo pedido).
--    3. Setear app.stock_origen, app.stock_ref_tipo, app.stock_ref_id,
--       app.stock_user_id antes de los UPDATE productos para que el
--       trigger registre la referencia.
--
-- D) cancelar_pedido_con_stock + eliminar_pedido_completo: setear los
--    mismos session settings con origen='pedido_cancelado' /
--    'pedido_eliminado' antes de restaurar stock.

-- ============================================================================
-- A. pedido_items.stock_al_crear
-- ============================================================================

ALTER TABLE public.pedido_items
  ADD COLUMN IF NOT EXISTS stock_al_crear INTEGER NULL;

COMMENT ON COLUMN public.pedido_items.stock_al_crear IS
  'Stock disponible del producto al momento de validar el item en crear_pedido_completo (antes del descuento). NULL en items previos a la migracion 038.';

-- ============================================================================
-- B. Trigger registrar_cambio_stock con contexto
-- ============================================================================

CREATE OR REPLACE FUNCTION public.registrar_cambio_stock()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.stock IS DISTINCT FROM NEW.stock THEN
    INSERT INTO stock_historico (
      producto_id, stock_anterior, stock_nuevo, origen,
      referencia_tipo, referencia_id, usuario_id, sucursal_id
    ) VALUES (
      NEW.id, OLD.stock, NEW.stock,
      COALESCE(NULLIF(current_setting('app.stock_origen', true), ''), 'auto'),
      NULLIF(current_setting('app.stock_ref_tipo', true), ''),
      NULLIF(current_setting('app.stock_ref_id', true), '')::BIGINT,
      NULLIF(current_setting('app.stock_user_id', true), '')::UUID,
      NEW.sucursal_id
    );
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================================
-- C. crear_pedido_completo (validacion completa + snapshot + contexto)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.crear_pedido_completo(
  p_cliente_id bigint, p_total numeric, p_usuario_id uuid, p_items jsonb,
  p_notas text DEFAULT NULL::text, p_forma_pago text DEFAULT 'efectivo'::text,
  p_estado_pago text DEFAULT 'pendiente'::text, p_fecha date DEFAULT NULL::date,
  p_tipo_factura text DEFAULT 'ZZ'::text, p_total_neto numeric DEFAULT NULL::numeric,
  p_total_iva numeric DEFAULT 0, p_fecha_entrega_programada date DEFAULT NULL::date
) RETURNS jsonb
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
  v_stock_snapshot JSONB := '{}'::JSONB;
  v_stock_al_crear INT;
  v_es_regalo_no_mueve_stock JSONB := '{}'::JSONB;
  v_regalo_mueve_stock BOOLEAN;
  v_descripcion_regalo TEXT;
  v_fecha_pedido DATE := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_fecha_entrega DATE := COALESCE(p_fecha_entrega_programada, (v_fecha_pedido + INTERVAL '1 day')::date);
  v_promo RECORD;
  v_usos_pendientes_actual INT;
  v_bloques_completos INT;
  v_ajustar_usos INT;
  v_ajustar_stock INT;
  v_stock_ajuste_anterior INT;
  v_stock_ajuste_nuevo INT;
  v_ajuste_producto_nombre TEXT;
  v_merma_id BIGINT;
  v_pedidos_bundle TEXT;
  v_observacion TEXT;
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesion autenticada')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- Loop 1: acumular cantidades por producto (incluye TODOS: ventas y regalos).
  -- Se marca por aparte si el item es regalo-no-mueve-stock para diferenciar
  -- el mensaje de error en la validacion.
  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN errores := array_append(errores, 'Cantidad invalida para producto ID ' || v_producto_id); CONTINUE; END IF;

    v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
    v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);

    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN
          v_es_regalo_no_mueve_stock := v_es_regalo_no_mueve_stock || jsonb_build_object(v_producto_id::TEXT, true);
        END IF;
      ELSE
        v_es_regalo_no_mueve_stock := v_es_regalo_no_mueve_stock || jsonb_build_object(v_producto_id::TEXT, true);
      END IF;
    END IF;
  END LOOP;

  -- Loop 2: validar stock por producto + capturar snapshot. Lock con FOR UPDATE.
  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      IF COALESCE((v_es_regalo_no_mueve_stock->>v_producto_id::TEXT)::BOOLEAN, FALSE) THEN
        errores := array_append(errores, v_producto_nombre || ': stock insuficiente para regalo (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
      ELSE
        errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
      END IF;
    END IF;
    -- snapshot incluso si fallo (sirve para diagnostico aguas abajo)
    IF v_stock_actual IS NOT NULL THEN
      v_stock_snapshot := v_stock_snapshot || jsonb_build_object(v_producto_id::TEXT, v_stock_actual);
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, tipo_factura, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)
  VALUES (p_cliente_id, v_fecha_pedido, p_total, COALESCE(p_total_neto, p_total), COALESCE(p_total_iva, 0), COALESCE(p_tipo_factura, 'ZZ'), 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)
  RETURNING id INTO v_pedido_id;

  -- Setear contexto para el trigger registrar_cambio_stock antes de los UPDATEs.
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

  -- Loop 3: INSERT items + UPDATE stock + auto-ajuste promos.
  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_neto_unitario := (item->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((item->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((item->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((item->>'porcentaje_iva')::DECIMAL, 0);
    v_stock_al_crear := (v_stock_snapshot->>v_producto_id::TEXT)::INT;

    v_descripcion_regalo := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo INTO v_descripcion_regalo FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id, descripcion_regalo, stock_al_crear
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal, v_descripcion_regalo, v_stock_al_crear
    );

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
    END IF;

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad WHERE id = v_promocion_id AND sucursal_id = v_sucursal;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

      IF v_promo.ajuste_automatico AND v_promo.ajuste_producto_id IS NOT NULL
         AND COALESCE(v_promo.unidades_por_bloque, 0) > 0 AND COALESCE(v_promo.stock_por_bloque, 0) > 0 THEN
        v_usos_pendientes_actual := v_promo.usos_pendientes;
        v_bloques_completos := v_usos_pendientes_actual / v_promo.unidades_por_bloque;
        IF v_bloques_completos > 0 THEN
          v_ajustar_usos := v_bloques_completos * v_promo.unidades_por_bloque;
          v_ajustar_stock := v_bloques_completos * v_promo.stock_por_bloque;

          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
          FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

          IF v_stock_ajuste_anterior IS NULL THEN
            RAISE EXCEPTION 'Auto-ajuste: producto destino no encontrado (promo %)', v_promocion_id;
          END IF;
          IF v_stock_ajuste_anterior < v_ajustar_stock THEN
            RAISE EXCEPTION 'Auto-ajuste: stock insuficiente en % (disponible: %, requerido: %)',
              v_ajuste_producto_nombre, v_stock_ajuste_anterior, v_ajustar_stock;
          END IF;

          v_stock_ajuste_nuevo := v_stock_ajuste_anterior - v_ajustar_stock;

          v_pedidos_bundle := public.pedido_bundle_para_promo(v_promocion_id, v_sucursal, 20);
          v_observacion := 'Auto-ajuste (Promo: ' || v_promo.nombre
                           || ', Pedidos: ' || COALESCE(v_pedidos_bundle, '#' || v_pedido_id) || ')';

          INSERT INTO mermas_stock (producto_id, cantidad, motivo, observaciones, stock_anterior, stock_nuevo, usuario_id, sucursal_id)
          VALUES (v_promo.ajuste_producto_id, v_ajustar_stock, 'promociones', v_observacion,
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal)
          RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, usuario_id, observaciones, sucursal_id)
          VALUES (v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,
            v_merma_id, p_usuario_id, v_observacion, v_sucursal);

          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- ============================================================================
-- D. crear_pedido_completo_bot (mismas tres mejoras)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.crear_pedido_completo_bot(
  p_perfil_id      UUID,
  p_confirmacion_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pendiente RECORD;
  v_user_role TEXT;
  v_pedido_id INT;
  v_fecha_pedido DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha_entrega DATE := (v_fecha_pedido + INTERVAL '1 day')::date;
  v_cantidades_totales JSONB := '{}'::JSONB;
  v_cant_acumulada INT;
  v_stock_snapshot JSONB := '{}'::JSONB;
  v_stock_al_crear INT;
  v_es_regalo_no_mueve_stock JSONB := '{}'::JSONB;
  v_regalo_mueve_stock BOOLEAN;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  errores TEXT[] := '{}';
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
  v_promo RECORD;
  v_usos_pendientes_actual INT;
  v_bloques_completos INT;
  v_ajustar_usos INT;
  v_ajustar_stock INT;
  v_stock_ajuste_anterior INT;
  v_stock_ajuste_nuevo INT;
  v_ajuste_producto_nombre TEXT;
  v_merma_id BIGINT;
BEGIN
  SELECT * INTO v_pendiente
    FROM bot_pedidos_pendientes
    WHERE id = p_confirmacion_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Confirmación inválida');
  END IF;

  IF v_pendiente.consumido THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido ya creado, revisalo en la app');
  END IF;

  IF v_pendiente.expires_at < now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'La confirmación expiró, hacé el pedido de nuevo');
  END IF;

  IF v_pendiente.perfil_id <> p_perfil_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'Confirmación no pertenece al usuario');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_perfil_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No tiene permisos para crear pedidos');
  END IF;

  -- Loop 1: acumular cantidades por producto (incluye ventas y regalos).
  FOR item IN SELECT * FROM jsonb_array_elements(v_pendiente.items) LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id);
      CONTINUE;
    END IF;

    v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
    v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);

    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
          FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
        IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN
          v_es_regalo_no_mueve_stock := v_es_regalo_no_mueve_stock || jsonb_build_object(v_producto_id::TEXT, true);
        END IF;
      ELSE
        v_es_regalo_no_mueve_stock := v_es_regalo_no_mueve_stock || jsonb_build_object(v_producto_id::TEXT, true);
      END IF;
    END IF;
  END LOOP;

  -- Loop 2: validar stock + snapshot.
  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      IF COALESCE((v_es_regalo_no_mueve_stock->>v_producto_id::TEXT)::BOOLEAN, FALSE) THEN
        errores := array_append(errores, v_producto_nombre || ': stock insuficiente para regalo (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
      ELSE
        errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
      END IF;
    END IF;
    IF v_stock_actual IS NOT NULL THEN
      v_stock_snapshot := v_stock_snapshot || jsonb_build_object(v_producto_id::TEXT, v_stock_actual);
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  INSERT INTO pedidos (
    cliente_id, fecha, total, total_neto, total_iva, tipo_factura,
    estado, usuario_id, stock_descontado, notas, forma_pago,
    estado_pago, fecha_entrega_programada, sucursal_id, canal
  )
  VALUES (
    v_pendiente.cliente_id, v_fecha_pedido, v_pendiente.total,
    COALESCE(v_pendiente.total_neto, v_pendiente.total),
    COALESCE(v_pendiente.total_iva, 0),
    'ZZ',
    'pendiente', p_perfil_id, true, v_pendiente.notas, v_pendiente.forma_pago,
    'pendiente', v_fecha_entrega, v_pendiente.sucursal_id, 'bot'
  )
  RETURNING id INTO v_pedido_id;

  PERFORM set_config('app.stock_origen', 'pedido_creado_bot', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_perfil_id::TEXT, true);

  FOR item IN SELECT * FROM jsonb_array_elements(v_pendiente.items) LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_neto_unitario := (item->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((item->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((item->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((item->>'porcentaje_iva')::DECIMAL, 0);
    v_stock_al_crear := (v_stock_snapshot->>v_producto_id::TEXT)::INT;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id, neto_unitario, iva_unitario,
      impuestos_internos_unitario, porcentaje_iva, sucursal_id, stock_al_crear
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario,
      v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id, v_neto_unitario, v_iva_unitario,
      v_imp_internos_unitario, v_porcentaje_iva, v_pendiente.sucursal_id, v_stock_al_crear
    );

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad
        WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad
          WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
      END IF;
    END IF;

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad
        WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
        INTO v_promo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;

      IF v_promo.ajuste_automatico
         AND v_promo.ajuste_producto_id IS NOT NULL
         AND COALESCE(v_promo.unidades_por_bloque, 0) > 0
         AND COALESCE(v_promo.stock_por_bloque, 0) > 0 THEN
        v_usos_pendientes_actual := v_promo.usos_pendientes;
        v_bloques_completos := v_usos_pendientes_actual / v_promo.unidades_por_bloque;
        IF v_bloques_completos > 0 THEN
          v_ajustar_usos := v_bloques_completos * v_promo.unidades_por_bloque;
          v_ajustar_stock := v_bloques_completos * v_promo.stock_por_bloque;

          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
            FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;

          IF v_stock_ajuste_anterior IS NULL THEN
            RAISE EXCEPTION 'Auto-ajuste: producto destino no encontrado (promo %)', v_promocion_id;
          END IF;
          IF v_stock_ajuste_anterior < v_ajustar_stock THEN
            RAISE EXCEPTION 'Auto-ajuste: stock insuficiente en % (disponible: %, requerido: %)',
              v_ajuste_producto_nombre, v_stock_ajuste_anterior, v_ajustar_stock;
          END IF;

          v_stock_ajuste_nuevo := v_stock_ajuste_anterior - v_ajustar_stock;

          INSERT INTO mermas_stock (
            producto_id, cantidad, motivo, observaciones,
            stock_anterior, stock_nuevo, usuario_id, sucursal_id
          ) VALUES (
            v_promo.ajuste_producto_id, v_ajustar_stock, 'promociones',
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || v_pedido_id || ' via bot)',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_perfil_id, v_pendiente.sucursal_id
          ) RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
            WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_pendiente.sucursal_id;

          INSERT INTO promo_ajustes (
            promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
            merma_id, usuario_id, observaciones, sucursal_id
          ) VALUES (
            v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,
            v_merma_id, p_perfil_id,
            'Auto-ajuste por pedido #' || v_pedido_id || ' via bot', v_pendiente.sucursal_id
          );

          UPDATE promociones
            SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
            WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
        END IF;
      END IF;
    END IF;
  END LOOP;

  UPDATE bot_pedidos_pendientes SET consumido = TRUE WHERE id = p_confirmacion_id;

  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', v_pedido_id,
    'total', v_pendiente.total
  );
END;
$$;

-- ============================================================================
-- E. cancelar_pedido_con_stock (set_config para trazabilidad)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cancelar_pedido_con_stock(
  p_pedido_id bigint, p_motivo text, p_usuario_id uuid DEFAULT NULL::uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;
  IF v_pedido.estado = 'cancelado' THEN RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado'); END IF;
  IF v_pedido.estado = 'entregado' THEN RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado'); END IF;

  v_total_original := v_pedido.total;

  PERFORM set_config('app.stock_origen', 'pedido_cancelado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', v_acting_user::TEXT, true);

  FOR v_item IN
    SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
           pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
    FROM pedido_items pi
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
    WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
    IF v_item.es_bonificacion THEN
      IF v_item.promocion_id IS NOT NULL THEN
        PERFORM public.revertir_bloques_auto_ajuste(
          v_item.promocion_id, v_item.cantidad::INT, v_sucursal,
          v_acting_user, 'Cancelacion pedido #' || p_pedido_id
        );
      END IF;
      IF v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  UPDATE pedidos
  SET estado = 'cancelado', motivo_cancelacion = p_motivo,
      total = 0, monto_pagado = 0, total_neto = 0, total_iva = 0, updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, v_acting_user, 'estado', v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original, v_sucursal);

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido cancelado, stock restaurado, saldo ajustado', 'total_original', v_total_original);
END;
$function$;

-- ============================================================================
-- F. eliminar_pedido_completo (set_config para trazabilidad)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.eliminar_pedido_completo(
  p_pedido_id bigint, p_usuario_id uuid, p_motivo text DEFAULT NULL::text, p_restaurar_stock boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD; v_items JSONB; v_cliente_nombre TEXT; v_cliente_direccion TEXT;
  v_usuario_creador_nombre TEXT; v_transportista_nombre TEXT := NULL;
  v_eliminador_nombre TEXT := NULL; v_item RECORD;
  v_user_role TEXT;
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa'); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada'); END IF;
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
    PERFORM set_config('app.stock_origen', 'pedido_eliminado', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
    PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

    FOR v_item IN
      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF NOT v_item.es_bonificacion OR v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
      IF v_item.es_bonificacion AND v_item.promocion_id IS NOT NULL THEN
        PERFORM public.revertir_bloques_auto_ajuste(
          v_item.promocion_id, v_item.cantidad::INT, v_sucursal,
          p_usuario_id, 'Eliminacion pedido #' || p_pedido_id
        );
      END IF;
    END LOOP;
  END IF;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$function$;
