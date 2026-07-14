-- ============================================================================
-- 117 · Desglose fiscal de venta SERVER-SIDE en todos los caminos de pedido
-- ============================================================================
-- Antes el desglose neto/IVA/II por ítem lo calculaba el CLIENTE y varios
-- caminos no lo mandaban (offline queue, anular_salvedad) o lo mandaban con
-- datos envenenados (productos con porcentaje_iva=0 pre-mig-112). Ahora los
-- RPCs lo computan SIEMPRE desde los atributos fiscales del producto + el
-- tipo_factura del pedido (el cálculo client-side queda como preview de UI).
--
--   · calcular_desglose_venta(precio, iva%, ii%, tipo): ZZ → (precio,0,0);
--     FC → neto = precio/(1+iva/100+ii/100); iva = neto×iva%; ii = neto×ii%.
--     (Estructura validada contra factura A real: IVA = 21% exacto del neto.)
--   · crear_pedido_completo / _bot / actualizar_pedido_items: desglose e
--     historial de totales server-side; snapshot de costo pasa a
--     productos.costo_real (canónico mig 111) con fallback a la fórmula vieja.
--   · anular_salvedad: al reinsertar un ítem borrado repone el desglose y el
--     snapshot de costo, y recalcula total_neto/total_iva (antes solo total).
--   · sustituir_regalo_pedido: al cambiar el producto del regalo refresca
--     costo_unitario_al_crear al costo_real del producto NUEVO (el KPI de
--     bonificaciones valuaba el regalo al costo del producto viejo).
-- Los p_total_neto / p_total_iva del cliente se aceptan por compatibilidad
-- pero se SOBREESCRIBEN con el cálculo server-side.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.calcular_desglose_venta(
  p_precio numeric,
  p_pct_iva numeric,
  p_pct_ii numeric,
  p_tipo_factura text
) RETURNS TABLE(neto numeric, iva numeric, imp_internos numeric)
LANGUAGE sql IMMUTABLE
AS $$
  SELECT
    CASE WHEN p_tipo_factura = 'ZZ' THEN round(COALESCE(p_precio, 0), 2)
         ELSE round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100 + COALESCE(p_pct_ii, 0)/100), 2) END,
    CASE WHEN p_tipo_factura = 'ZZ' THEN 0::numeric
         ELSE round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100 + COALESCE(p_pct_ii, 0)/100) * COALESCE(p_pct_iva, 0)/100, 2) END,
    CASE WHEN p_tipo_factura = 'ZZ' THEN 0::numeric
         ELSE round(COALESCE(p_precio, 0) / (1 + COALESCE(p_pct_iva, 0)/100 + COALESCE(p_pct_ii, 0)/100) * COALESCE(p_pct_ii, 0)/100, 2) END;
$$;

COMMENT ON FUNCTION public.calcular_desglose_venta(numeric, numeric, numeric, text) IS
  'Desglose fiscal por unidad de venta (espejo de calcularNetoVenta TS). ZZ: todo el precio es ingreso neto. FC: neto/IVA/II derivados del precio final.';

-- ────────────────────────────────────────────────────────────────────────────
-- crear_pedido_completo (misma firma de 101 ⇒ OR REPLACE)
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.crear_pedido_completo(p_cliente_id bigint, p_total numeric, p_usuario_id uuid, p_items jsonb, p_notas text DEFAULT NULL::text, p_forma_pago text DEFAULT 'efectivo'::text, p_estado_pago text DEFAULT 'pendiente'::text, p_fecha date DEFAULT NULL::date, p_tipo_factura text DEFAULT 'ZZ'::text, p_total_neto numeric DEFAULT NULL::numeric, p_total_iva numeric DEFAULT 0, p_fecha_entrega_programada date DEFAULT NULL::date, p_preventista_id uuid DEFAULT NULL::uuid)
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
  v_stock_snapshot JSONB := '{}'::JSONB;
  v_stock_al_crear INT;
  v_costo_actual NUMERIC; v_imp_int_actual NUMERIC; v_pct_iva_actual NUMERIC; v_costo_real_actual NUMERIC;
  v_costo_snapshot JSONB := '{}'::JSONB; v_costo_al_crear NUMERIC;
  v_pct_iva_snapshot JSONB := '{}'::JSONB;
  v_pct_ii_snapshot JSONB := '{}'::JSONB;
  v_tipo_factura TEXT := COALESCE(p_tipo_factura, 'ZZ');
  v_total_neto_calc NUMERIC := 0;
  v_total_iva_calc NUMERIC := 0;
  v_es_regalo_no_mueve_stock JSONB := '{}'::JSONB;
  v_regalo_mueve_stock BOOLEAN;
  v_descripcion_regalo TEXT;
  v_regalo_default_id BIGINT;
  v_container_id INT;
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
  v_preventista_role TEXT;
  v_preventista_final UUID;
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesion autenticada')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'preventista_taco', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  IF p_preventista_id IS NULL OR p_preventista_id = p_usuario_id THEN
    v_preventista_final := p_usuario_id;
  ELSE
    IF v_user_role <> 'admin' THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('Solo admin puede asignar otro preventista al pedido'));
    END IF;
    SELECT p.rol INTO v_preventista_role
    FROM perfiles p
    WHERE p.id = p_preventista_id
      AND p.activo = true
      AND EXISTS (
        SELECT 1 FROM usuario_sucursales us
        WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal
      );
    IF v_preventista_role IS NULL OR v_preventista_role NOT IN ('admin', 'preventista', 'preventista_taco') THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('El usuario asignado no es admin ni preventista (o no pertenece a la sucursal)'));
    END IF;
    v_preventista_final := p_preventista_id;
  END IF;

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

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;
    SELECT stock, nombre, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_stock_actual, v_producto_nombre, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
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
      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        COALESCE(v_costo_real_actual,
          CASE WHEN v_costo_actual IS NULL THEN NULL
               ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END));
      v_pct_iva_snapshot := v_pct_iva_snapshot || jsonb_build_object(v_producto_id::TEXT, v_pct_iva_actual);
      v_pct_ii_snapshot := v_pct_ii_snapshot || jsonb_build_object(v_producto_id::TEXT, v_imp_int_actual);
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, tipo_factura, estado, usuario_id, creado_por, stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)
  VALUES (p_cliente_id, v_fecha_pedido, p_total, COALESCE(p_total_neto, p_total), COALESCE(p_total_iva, 0), v_tipo_factura, 'pendiente', v_preventista_final, p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)
  RETURNING id INTO v_pedido_id;

  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

  IF v_preventista_final IS DISTINCT FROM p_usuario_id THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (v_pedido_id, p_usuario_id, 'usuario_id', NULL, v_preventista_final::TEXT, v_sucursal);
  END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_stock_al_crear := (v_stock_snapshot->>v_producto_id::TEXT)::INT;
    v_costo_al_crear := (v_costo_snapshot->>v_producto_id::TEXT)::NUMERIC;

    -- Desglose fiscal SERVER-SIDE (ignora lo que mande el cliente)
    IF v_es_bonificacion THEN
      v_neto_unitario := 0; v_iva_unitario := 0; v_imp_internos_unitario := 0; v_porcentaje_iva := 0;
    ELSE
      SELECT d.neto, d.iva, d.imp_internos
        INTO v_neto_unitario, v_iva_unitario, v_imp_internos_unitario
        FROM calcular_desglose_venta(
          v_precio_unitario,
          (v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC,
          (v_pct_ii_snapshot->>v_producto_id::TEXT)::NUMERIC,
          v_tipo_factura) d;
      v_porcentaje_iva := CASE WHEN v_tipo_factura = 'ZZ' THEN 0
                               ELSE (v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC END;
      v_total_neto_calc := v_total_neto_calc + (v_cantidad * v_neto_unitario);
      v_total_iva_calc  := v_total_iva_calc  + (v_cantidad * v_iva_unitario);
    END IF;

    v_descripcion_regalo := NULL;
    v_regalo_default_id := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo, producto_regalo_id
        INTO v_descripcion_regalo, v_regalo_default_id
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF v_regalo_default_id IS DISTINCT FROM v_producto_id THEN
        v_descripcion_regalo := NULL;
      END IF;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id, descripcion_regalo, stock_al_crear, costo_unitario_al_crear
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal, v_descripcion_regalo, v_stock_al_crear, v_costo_al_crear
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
             stock_por_bloque, usos_pendientes, producto_regalo_id
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

      v_container_id := CASE WHEN v_promo.producto_regalo_id IS DISTINCT FROM v_producto_id
                             THEN v_producto_id ELSE v_promo.ajuste_producto_id END;

      IF v_promo.ajuste_automatico AND v_container_id IS NOT NULL
         AND COALESCE(v_promo.unidades_por_bloque, 0) > 0 AND COALESCE(v_promo.stock_por_bloque, 0) > 0 THEN
        v_usos_pendientes_actual := v_promo.usos_pendientes;
        v_bloques_completos := v_usos_pendientes_actual / v_promo.unidades_por_bloque;
        IF v_bloques_completos > 0 THEN
          v_ajustar_usos := v_bloques_completos * v_promo.unidades_por_bloque;
          v_ajustar_stock := v_bloques_completos * v_promo.stock_por_bloque;

          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
          FROM productos WHERE id = v_container_id AND sucursal_id = v_sucursal FOR UPDATE;

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
          VALUES (v_container_id, v_ajustar_stock, 'promociones', v_observacion,
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal)
          RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_container_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, usuario_id, observaciones, sucursal_id)
          VALUES (v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_container_id,
            v_merma_id, p_usuario_id, v_observacion, v_sucursal);

          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
    END IF;
  END LOOP;

  -- Totales fiscales autoritativos (server-side; pisa lo que mandó el cliente)
  UPDATE pedidos
     SET total_neto = round(v_total_neto_calc, 2),
         total_iva  = round(v_total_iva_calc, 2)
   WHERE id = v_pedido_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- ────────────────────────────────────────────────────────────────────────────
-- crear_pedido_completo_bot (misma firma ⇒ OR REPLACE). El bot es siempre ZZ:
-- neto = precio, iva/II = 0. Snapshot de costo pasa a costo_real.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.crear_pedido_completo_bot(p_perfil_id uuid, p_confirmacion_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_costo_actual NUMERIC; v_imp_int_actual NUMERIC; v_costo_real_actual NUMERIC;
  v_costo_snapshot JSONB := '{}'::JSONB; v_costo_al_crear NUMERIC;
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
  v_total_neto_calc NUMERIC := 0;
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
  SELECT * INTO v_pendiente FROM bot_pedidos_pendientes WHERE id = p_confirmacion_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Confirmación inválida'); END IF;
  IF v_pendiente.consumido THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido ya creado, revisalo en la app'); END IF;
  IF v_pendiente.expires_at < now() THEN RETURN jsonb_build_object('success', false, 'error', 'La confirmación expiró, hacé el pedido de nuevo'); END IF;
  IF v_pendiente.perfil_id <> p_perfil_id THEN RETURN jsonb_build_object('success', false, 'error', 'Confirmación no pertenece al usuario'); END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_perfil_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No tiene permisos para crear pedidos');
  END IF;

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
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
        IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN
          v_es_regalo_no_mueve_stock := v_es_regalo_no_mueve_stock || jsonb_build_object(v_producto_id::TEXT, true);
        END IF;
      ELSE
        v_es_regalo_no_mueve_stock := v_es_regalo_no_mueve_stock || jsonb_build_object(v_producto_id::TEXT, true);
      END IF;
    END IF;
  END LOOP;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;
    SELECT stock, nombre, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0)
      INTO v_stock_actual, v_producto_nombre, v_costo_real_actual, v_costo_actual, v_imp_int_actual
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
      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        COALESCE(v_costo_real_actual,
          CASE WHEN v_costo_actual IS NULL THEN NULL
               ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END));
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (
    cliente_id, fecha, total, total_neto, total_iva, tipo_factura,
    estado, usuario_id, creado_por, stock_descontado, notas, forma_pago,
    estado_pago, fecha_entrega_programada, sucursal_id, canal
  )
  VALUES (
    v_pendiente.cliente_id, v_fecha_pedido, v_pendiente.total,
    v_pendiente.total,   -- ZZ: neto = total
    0, 'ZZ',
    'pendiente', p_perfil_id, p_perfil_id, true, v_pendiente.notas, v_pendiente.forma_pago,
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
    v_stock_al_crear := (v_stock_snapshot->>v_producto_id::TEXT)::INT;
    v_costo_al_crear := (v_costo_snapshot->>v_producto_id::TEXT)::NUMERIC;

    -- ZZ server-side: neto = precio final; iva/II = 0
    v_neto_unitario := CASE WHEN v_es_bonificacion THEN 0 ELSE round(COALESCE(v_precio_unitario, 0), 2) END;
    IF NOT v_es_bonificacion THEN
      v_total_neto_calc := v_total_neto_calc + (v_cantidad * v_neto_unitario);
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id, neto_unitario, iva_unitario,
      impuestos_internos_unitario, porcentaje_iva, sucursal_id, stock_al_crear, costo_unitario_al_crear
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario,
      v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id, v_neto_unitario, 0,
      0, 0, v_pendiente.sucursal_id, v_stock_al_crear, v_costo_al_crear
    );

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
      END IF;
    END IF;

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
        INTO v_promo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;

      IF v_promo.ajuste_automatico AND v_promo.ajuste_producto_id IS NOT NULL
         AND COALESCE(v_promo.unidades_por_bloque, 0) > 0 AND COALESCE(v_promo.stock_por_bloque, 0) > 0 THEN
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

          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
            WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
        END IF;
      END IF;
    END IF;
  END LOOP;

  UPDATE pedidos
     SET total_neto = round(v_total_neto_calc, 2)
   WHERE id = v_pedido_id AND sucursal_id = v_pendiente.sucursal_id;

  UPDATE bot_pedidos_pendientes SET consumido = TRUE WHERE id = p_confirmacion_id;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id, 'total', v_pendiente.total);
END;
$function$;

-- ────────────────────────────────────────────────────────────────────────────
-- actualizar_pedido_items (misma firma ⇒ OR REPLACE): desglose server-side
-- desde los atributos del producto + tipo_factura del pedido.
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_descripcion_regalo TEXT;
  v_bonif RECORD;
  v_promo RECORD;
  v_usos_pendientes_actual INT;
  v_bloques_completos INT;
  v_ajustar_usos INT;
  v_ajustar_stock INT;
  v_stock_ajuste_anterior INT;
  v_stock_ajuste_nuevo INT;
  v_ajuste_producto_nombre TEXT;
  v_merma_id BIGINT;
  v_pedido_creator UUID;
  v_pedido_created_at TIMESTAMPTZ;
  v_tipo_factura TEXT;
  v_hora_corte CONSTANT TIME := TIME '15:30';
  v_precio_actual DECIMAL;
  v_costo_actual DECIMAL; v_imp_int_actual DECIMAL; v_costo_al_crear DECIMAL;
  v_costo_real_actual DECIMAL; v_pct_iva_actual DECIMAL;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['ID de usuario no coincide con la sesion autenticada']);
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista', 'preventista_taco') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  SELECT total, usuario_id, created_at, COALESCE(tipo_factura, 'ZZ')
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at, v_tipo_factura
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  IF v_user_role IN ('preventista', 'preventista_taco') THEN
    IF v_pedido_creator IS DISTINCT FROM p_usuario_id THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Solo el preventista que creo el pedido puede editarlo']);
    END IF;

    IF (v_pedido_created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
         IS DISTINCT FROM (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
       OR (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::time >= v_hora_corte
    THEN
      RETURN jsonb_build_object('success', false, 'errores',
        ARRAY['Como preventista solo puede editar pedidos del dia actual antes de las 15:30 (ARG)']);
    END IF;

    FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
      IF COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false) = true THEN
        CONTINUE;
      END IF;
      v_producto_id := (v_item_nuevo->>'producto_id')::INT;
      v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
      SELECT precio INTO v_precio_actual
        FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      IF v_precio_actual IS NULL THEN
        RETURN jsonb_build_object('success', false, 'errores',
          ARRAY['Producto ID ' || v_producto_id || ' no encontrado']);
      END IF;
      IF v_precio_unitario IS NULL OR v_precio_unitario > v_precio_actual THEN
        RETURN jsonb_build_object('success', false, 'errores',
          ARRAY['Como preventista no puede aumentar precios (producto ID ' || v_producto_id || ')']);
      END IF;
    END LOOP;
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

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

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
    AND p.id = pi.producto_id AND p.sucursal_id = v_sucursal;

  FOR v_bonif IN
    SELECT promocion_id, SUM(cantidad)::INT AS total_cantidad
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
       AND COALESCE(es_bonificacion, false) = true AND promocion_id IS NOT NULL
     GROUP BY promocion_id
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_bonif.promocion_id, v_bonif.total_cantidad, v_sucursal,
      p_usuario_id, 'Edicion pedido #' || p_pedido_id
    );
  END LOOP;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    SELECT costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    v_costo_al_crear := COALESCE(v_costo_real_actual,
      CASE WHEN v_costo_actual IS NULL THEN NULL
           ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END);

    -- Desglose fiscal SERVER-SIDE
    IF v_es_bonificacion THEN
      v_neto_unitario := 0; v_iva_unitario := 0; v_imp_internos_unitario := 0; v_porcentaje_iva := 0;
    ELSE
      SELECT d.neto, d.iva, d.imp_internos
        INTO v_neto_unitario, v_iva_unitario, v_imp_internos_unitario
        FROM calcular_desglose_venta(v_precio_unitario, v_pct_iva_actual, v_imp_int_actual, v_tipo_factura) d;
      v_porcentaje_iva := CASE WHEN v_tipo_factura = 'ZZ' THEN 0 ELSE v_pct_iva_actual END;
    END IF;

    v_descripcion_regalo := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo INTO v_descripcion_regalo FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id, descripcion_regalo, costo_unitario_al_crear
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal, v_descripcion_regalo, v_costo_al_crear
    );

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * v_neto_unitario);
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva WHERE id = v_promocion_id AND sucursal_id = v_sucursal;

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

          INSERT INTO mermas_stock (producto_id, cantidad, motivo, observaciones, stock_anterior, stock_nuevo, usuario_id, sucursal_id)
          VALUES (v_promo.ajuste_producto_id, v_ajustar_stock, 'promociones',
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || p_pedido_id || ', edicion)',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal)
          RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, usuario_id, observaciones, sucursal_id)
          VALUES (v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,
            v_merma_id, p_usuario_id, 'Auto-ajuste por edicion pedido #' || p_pedido_id, v_sucursal);

          UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
    END IF;
  END LOOP;

  UPDATE pedidos SET total = v_total_nuevo, total_neto = round(v_total_neto_nuevo, 2), total_iva = round(v_total_iva_nuevo, 2), updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT, v_sucursal);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$function$;

-- ────────────────────────────────────────────────────────────────────────────
-- anular_salvedad: reinsertar con desglose + costo snapshot, y recalcular
-- total_neto/total_iva (antes solo total).
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.anular_salvedad(p_salvedad_id bigint, p_notas text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
  v_tipo_factura TEXT;
  v_pct_iva NUMERIC; v_pct_ii NUMERIC; v_costo_real NUMERIC; v_costo_sin NUMERIC;
  v_neto NUMERIC; v_iva NUMERIC; v_ii NUMERIC;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'No encontrada'); END IF;
  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;
  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
    UPDATE pedido_items SET
      cantidad = v_salvedad.cantidad_original,
      subtotal = v_salvedad.cantidad_original * v_salvedad.precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    -- Reinsertar con desglose fiscal y costo snapshot (mig 117; antes quedaba sin desglose)
    SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tipo_factura
      FROM pedidos WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
    SELECT COALESCE(porcentaje_iva, 21), COALESCE(impuestos_internos, 0), costo_real, costo_sin_iva
      INTO v_pct_iva, v_pct_ii, v_costo_real, v_costo_sin
      FROM productos WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    SELECT d.neto, d.iva, d.imp_internos INTO v_neto, v_iva, v_ii
      FROM calcular_desglose_venta(v_salvedad.precio_unitario, v_pct_iva, v_pct_ii, v_tipo_factura) d;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      costo_unitario_al_crear
    )
    VALUES (
      v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_original,
      v_salvedad.precio_unitario, v_salvedad.cantidad_original * v_salvedad.precio_unitario, v_sucursal,
      v_neto, v_iva, v_ii, CASE WHEN v_tipo_factura = 'ZZ' THEN 0 ELSE v_pct_iva END,
      COALESCE(v_costo_real,
        CASE WHEN v_costo_sin IS NULL THEN NULL ELSE round(v_costo_sin * (1 + v_pct_ii / 100), 4) END)
    );
  END IF;
  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_neto = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(neto_unitario, precio_unitario) ELSE 0 END), 0)
                    FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_iva = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(iva_unitario, 0) ELSE 0 END), 0)
                   FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
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

-- ────────────────────────────────────────────────────────────────────────────
-- sustituir_regalo_pedido: refrescar costo_unitario_al_crear al producto NUEVO
-- (única línea agregada al body vivo: el UPDATE de pedido_items).
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sustituir_regalo_pedido(p_pedido_item_id bigint, p_producto_nuevo_id bigint, p_cantidad_nueva numeric, p_motivo text, p_ajuste_producto_id_nuevo bigint DEFAULT NULL::bigint, p_client_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id            UUID := auth.uid();
  v_user_role          TEXT;
  v_sucursal           BIGINT := current_sucursal_id();
  v_item               RECORD;
  v_promo              RECORD;
  v_stock_nuevo        NUMERIC;
  v_regalo_mueve_stock BOOLEAN;
  v_sust_id            BIGINT;
  v_existing           RECORD;
  v_nuevo_nombre       TEXT;
  v_promo_usos_default NUMERIC;
  v_acc_default        RECORD;
  v_ajuste_sustituto_efectivo BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;
  IF p_client_request_id IS NOT NULL THEN
    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin o encargado pueden sustituir regalos');
  END IF;
  IF p_cantidad_nueva IS NULL OR p_cantidad_nueva <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'La cantidad sustituta debe ser mayor a 0');
  END IF;
  SELECT pi.id, pi.pedido_id, pi.producto_id, pi.cantidad, pi.es_bonificacion,
         pi.promocion_id, pi.sucursal_id, p.estado AS pedido_estado
    INTO v_item
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.id = p_pedido_item_id AND pi.sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item no encontrado');
  END IF;
  IF NOT COALESCE(v_item.es_bonificacion, FALSE) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo se pueden sustituir items marcados como bonificacion');
  END IF;
  IF v_item.pedido_estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede sustituir un regalo en un pedido ya entregado');
  END IF;
  IF v_item.promocion_id IS NOT NULL THEN
    SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
           ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
      INTO v_promo FROM promociones WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
  END IF;
  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);
  v_ajuste_sustituto_efectivo := COALESCE(p_ajuste_producto_id_nuevo, p_producto_nuevo_id);
  SELECT nombre INTO v_nuevo_nombre FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
  IF v_regalo_mueve_stock THEN
    SELECT stock INTO v_stock_nuevo FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_nuevo IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'Producto sustituto no existe en esta sucursal');
    END IF;
    IF v_stock_nuevo < p_cantidad_nueva THEN
      RETURN jsonb_build_object('success', false, 'error', 'Stock insuficiente del producto sustituto (' || v_stock_nuevo || ' disponible)');
    END IF;
    PERFORM set_config('app.stock_origen', 'sustitucion_regalo', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
    PERFORM set_config('app.stock_ref_id', v_item.pedido_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', v_user_id::TEXT, true);
    UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    UPDATE productos SET stock = stock - p_cantidad_nueva WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
  ELSE
    IF v_promo.producto_regalo_id IS NOT NULL THEN
      SELECT id, usos_pendientes INTO v_acc_default
        FROM promo_acumuladores
       WHERE promocion_id = v_promo.id AND producto_regalo_id = v_promo.producto_regalo_id AND sucursal_id = v_sucursal
       FOR UPDATE;
      IF FOUND THEN
        IF v_acc_default.usos_pendientes IS DISTINCT FROM COALESCE(v_promo.usos_pendientes, 0) THEN
          UPDATE promo_acumuladores SET usos_pendientes = COALESCE(v_promo.usos_pendientes, 0), updated_at = NOW()
           WHERE id = v_acc_default.id;
        END IF;
      ELSE
        INSERT INTO promo_acumuladores (promocion_id, producto_regalo_id, ajuste_producto_id,
          unidades_por_bloque, stock_por_bloque, usos_pendientes, sucursal_id)
        VALUES (v_promo.id, v_promo.producto_regalo_id, v_promo.ajuste_producto_id,
          v_promo.unidades_por_bloque, v_promo.stock_por_bloque, COALESCE(v_promo.usos_pendientes, 0), v_sucursal)
        ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id) DO NOTHING;
      END IF;
    END IF;
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_promo.ajuste_producto_id, v_sucursal, v_user_id,
      'sustitucion: salida del producto regalo original'
    );
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, p_producto_nuevo_id, p_cantidad_nueva,
      v_ajuste_sustituto_efectivo, v_sucursal, v_user_id,
      'sustitucion: entrada del producto regalo sustituto'
    );
    IF v_promo.producto_regalo_id IS NOT NULL THEN
      SELECT usos_pendientes INTO v_promo_usos_default
        FROM promo_acumuladores
       WHERE promocion_id = v_promo.id AND producto_regalo_id = v_promo.producto_regalo_id AND sucursal_id = v_sucursal;
      UPDATE promociones SET usos_pendientes = GREATEST(COALESCE(v_promo_usos_default, 0)::INT, 0)
       WHERE id = v_promo.id AND sucursal_id = v_sucursal;
    END IF;
  END IF;
  UPDATE pedido_items
     SET producto_id = p_producto_nuevo_id, cantidad = p_cantidad_nueva, subtotal = 0,
         descripcion_regalo = COALESCE(descripcion_regalo, '') || ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']',
         -- mig 117: el KPI de bonificaciones debe valuar el regalo al costo del producto NUEVO
         costo_unitario_al_crear = (SELECT costo_real FROM productos
                                     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal)
   WHERE id = p_pedido_item_id;
  INSERT INTO pedido_item_sustituciones (
    pedido_id, pedido_item_id, promocion_id, producto_original_id, producto_sustituto_id,
    cantidad_original, cantidad_sustituta, regalo_mueve_stock_snapshot, ajuste_producto_id_nuevo,
    motivo, autorizado_por, sucursal_id, client_request_id
  ) VALUES (
    v_item.pedido_id, p_pedido_item_id, v_item.promocion_id, v_item.producto_id, p_producto_nuevo_id,
    v_item.cantidad, p_cantidad_nueva, v_regalo_mueve_stock, v_ajuste_sustituto_efectivo,
    p_motivo, v_user_id, v_sucursal, p_client_request_id
  ) RETURNING id INTO v_sust_id;
  INSERT INTO pedido_historial (
    pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id
  ) VALUES (
    v_item.pedido_id, v_user_id, 'sustitucion_regalo',
    'producto_id=' || v_item.producto_id || ' cantidad=' || v_item.cantidad,
    'producto_id=' || p_producto_nuevo_id || ' cantidad=' || p_cantidad_nueva || ' motivo=' || p_motivo,
    v_sucursal
  );
  RETURN jsonb_build_object('success', true, 'sustitucion_id', v_sust_id,
    'modo', CASE WHEN v_regalo_mueve_stock THEN 'A' ELSE 'B' END);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;
