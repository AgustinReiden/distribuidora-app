-- ============================================================================
-- 132 · Fix: falso "stock insuficiente para regalo" en promos de Fracción
-- ============================================================================
-- BUG (reportado 17/07/26): al crear un pedido con una promo de Fracción
-- (regalo_mueve_stock=false, ajuste_automatico=true, unidades_por_bloque>1) el
-- RPC rechazaba con:
--   "MANAOS NARANJA 3LT x 6: stock insuficiente para regalo
--    (disponible: 5, solicitado: 6)"
-- aunque había stock. Fraccionar el pedido en pedidos más chicos lo "arreglaba".
--
-- CAUSA: la validación de stock previa (loop 2) comparaba, SIN convertir unidades:
--   · disponible = productos.stock            → en FARDOS (bloques)
--   · solicitado = cantidad del regalo        → en BOTELLAS/subunidades
-- En una "6+2" el regalo son 2 botellas por bloque; 6 botellas = 1 fardo, pero la
-- validación comparaba 5 fardos < 6 botellas → error. Fraccionar bajaba las
-- botellas de regalo por debajo del número de fardos y la comparación (mal hecha)
-- pasaba.
--
-- En las promos de Fracción el stock del contenedor NO lo descuenta la línea de
-- regalo: lo descuenta el AUTO-AJUSTE por bloques (loop 3), que sí convierte bien
-- (usos_pendientes / unidades_por_bloque → fardos) y ya tiene su propia guarda
-- unit-correct (RAISE 'Auto-ajuste: stock insuficiente en % ...'). Por eso la
-- validación previa de la línea de regalo Fracción está de más y en la unidad
-- equivocada.
--
-- FIX: separar la cantidad que realmente descuenta stock DIRECTO (en fardos) del
-- total por producto, y validar solo esa cantidad contra productos.stock:
--   · venta normal                      → cuenta para la validación (fardos)
--   · regalo con regalo_mueve_stock=true → cuenta (mismo producto, en fardos)
--   · regalo Fracción / sin promo        → NO cuenta (lo valida el auto-ajuste)
-- Un regalo Fracción puro queda con cantidad-stock = 0 → nunca dispara el error.
-- Un producto que es venta Y contenedor de un regalo Fracción valida solo la
-- parte de venta. Se elimina el mensaje "para regalo" (siempre engañoso ahora):
-- cualquier faltante que quede es una demanda real de stock en fardos.
--
-- Este es exactamente el patrón que actualizar_pedido_items (edición) ya aplica
-- (omite el regalo Fracción del chequeo previo, mig 129). Acá se replica en los
-- dos RPCs de CREACIÓN. No se toca actualizar_pedido_items ni el resto.
--
-- Base = definición vigente en prod (idéntica a mig 123/129 salvo este cambio).
-- Afecta a TODAS las promos de Fracción (no solo la "Manaos 6+2").
-- ============================================================================

-- ─── 1. crear_pedido_completo ───────────────────────────────────────────────

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
  v_neto_unitario DECIMAL; v_iva_unitario DECIMAL; v_ingreso_real DECIMAL;
  v_porcentaje_iva DECIMAL; v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}'; v_user_role TEXT;
  v_cantidades_totales JSONB := '{}'::JSONB; v_cant_acumulada INT;
  v_cantidades_stock JSONB := '{}'::JSONB; v_cant_stock INT;   -- mig 132: solo lo que descuenta stock directo (fardos)
  v_stock_snapshot JSONB := '{}'::JSONB;
  v_stock_al_crear INT;
  v_costo_actual NUMERIC; v_imp_int_actual NUMERIC; v_pct_iva_actual NUMERIC; v_costo_real_actual NUMERIC;
  v_costo_promedio_actual NUMERIC;
  v_costo_snapshot JSONB := '{}'::JSONB; v_costo_al_crear NUMERIC;
  v_pct_iva_snapshot JSONB := '{}'::JSONB;
  v_pct_ii_snapshot JSONB := '{}'::JSONB;
  v_tipo_factura TEXT := COALESCE(p_tipo_factura, 'ZZ');
  v_total_neto_calc NUMERIC := 0;
  v_total_iva_calc NUMERIC := 0;
  v_total_real_calc NUMERIC := 0;
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

    -- Total por producto: se usa para snapshotear stock/costo de TODOS los productos.
    v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
    v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);

    -- mig 132: acumular en v_cantidades_stock SOLO lo que descuenta stock directo (fardos).
    -- El regalo de Fracción (regalo_mueve_stock=false) NO se valida acá: su stock lo
    -- descuenta y valida el auto-ajuste por bloques (loop 3), en fardos.
    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      v_regalo_mueve_stock := NULL;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      END IF;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        v_cantidades_stock := v_cantidades_stock || jsonb_build_object(v_producto_id::TEXT,
          COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0) + v_cantidad);
      END IF;
    ELSE
      v_cantidades_stock := v_cantidades_stock || jsonb_build_object(v_producto_id::TEXT,
        COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0) + v_cantidad);
    END IF;
  END LOOP;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cant_stock := COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0);   -- mig 132: en fardos
    SELECT stock, nombre, costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_stock_actual, v_producto_nombre, v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cant_stock THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cant_stock || ')');
    END IF;
    IF v_stock_actual IS NOT NULL THEN
      v_stock_snapshot := v_stock_snapshot || jsonb_build_object(v_producto_id::TEXT, v_stock_actual);
      -- CPP primero (mig 129): valuación del stock que se vende; fallback reposición
      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        COALESCE(v_costo_promedio_actual, v_costo_real_actual,
          CASE WHEN v_costo_actual IS NULL THEN NULL
               ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END));
      v_pct_iva_snapshot := v_pct_iva_snapshot || jsonb_build_object(v_producto_id::TEXT, v_pct_iva_actual);
      v_pct_ii_snapshot := v_pct_ii_snapshot || jsonb_build_object(v_producto_id::TEXT, v_imp_int_actual);
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, total_real, tipo_factura, estado, usuario_id, creado_por, stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)
  VALUES (p_cliente_id, v_fecha_pedido, p_total, COALESCE(p_total_neto, p_total), COALESCE(p_total_iva, 0), p_total, v_tipo_factura, 'pendiente', v_preventista_final, p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)
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

    -- Terna de ingresos SERVER-SIDE (mig 123)
    IF v_es_bonificacion THEN
      v_neto_unitario := 0; v_iva_unitario := 0; v_ingreso_real := 0; v_porcentaje_iva := 0;
    ELSE
      SELECT d.neto, d.iva, d.ingreso_real
        INTO v_neto_unitario, v_iva_unitario, v_ingreso_real
        FROM calcular_desglose_venta(
          v_precio_unitario,
          (v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC,
          (v_pct_ii_snapshot->>v_producto_id::TEXT)::NUMERIC,
          v_tipo_factura) d;
      v_porcentaje_iva := (v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC;
      v_total_neto_calc := v_total_neto_calc + (v_cantidad * v_neto_unitario);
      v_total_iva_calc  := v_total_iva_calc  + (v_cantidad * v_iva_unitario);
      v_total_real_calc := v_total_real_calc + (v_cantidad * v_ingreso_real);
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
      ingreso_real_unitario,
      sucursal_id, descripcion_regalo, stock_al_crear, costo_unitario_al_crear
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, 0, v_porcentaje_iva,
      v_ingreso_real,
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

  -- Terna autoritativa server-side
  UPDATE pedidos
     SET total_neto = round(v_total_neto_calc, 2),
         total_iva  = round(v_total_iva_calc, 2),
         total_real = round(v_total_real_calc, 2)
   WHERE id = v_pedido_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- ─── 2. crear_pedido_completo_bot ───────────────────────────────────────────

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
  v_cantidades_stock JSONB := '{}'::JSONB; v_cant_stock INT;   -- mig 132: solo lo que descuenta stock directo (fardos)
  v_stock_snapshot JSONB := '{}'::JSONB;
  v_stock_al_crear INT;
  v_costo_actual NUMERIC; v_imp_int_actual NUMERIC; v_costo_real_actual NUMERIC; v_pct_iva_actual NUMERIC;
  v_costo_promedio_actual NUMERIC;
  v_costo_snapshot JSONB := '{}'::JSONB; v_costo_al_crear NUMERIC;
  v_pct_iva_snapshot JSONB := '{}'::JSONB;
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
  v_ingreso_real DECIMAL;
  v_total_neto_calc NUMERIC := 0;
  v_total_real_calc NUMERIC := 0;
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

    -- Total por producto (para snapshot de stock/costo de TODOS los productos).
    v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
    v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);

    -- mig 132: v_cantidades_stock solo acumula lo que descuenta stock directo (fardos).
    -- El regalo Fracción (regalo_mueve_stock=false) lo valida el auto-ajuste por bloques.
    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      v_regalo_mueve_stock := NULL;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
      END IF;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        v_cantidades_stock := v_cantidades_stock || jsonb_build_object(v_producto_id::TEXT,
          COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0) + v_cantidad);
      END IF;
    ELSE
      v_cantidades_stock := v_cantidades_stock || jsonb_build_object(v_producto_id::TEXT,
        COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0) + v_cantidad);
    END IF;
  END LOOP;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cant_stock := COALESCE((v_cantidades_stock->>v_producto_id::TEXT)::INT, 0);   -- mig 132: en fardos
    SELECT stock, nombre, costo_promedio, costo_real, costo_sin_iva, COALESCE(impuestos_internos, 0), COALESCE(porcentaje_iva, 21)
      INTO v_stock_actual, v_producto_nombre, v_costo_promedio_actual, v_costo_real_actual, v_costo_actual, v_imp_int_actual, v_pct_iva_actual
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cant_stock THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cant_stock || ')');
    END IF;
    IF v_stock_actual IS NOT NULL THEN
      v_stock_snapshot := v_stock_snapshot || jsonb_build_object(v_producto_id::TEXT, v_stock_actual);
      -- CPP primero (mig 129)
      v_costo_snapshot := v_costo_snapshot || jsonb_build_object(v_producto_id::TEXT,
        COALESCE(v_costo_promedio_actual, v_costo_real_actual,
          CASE WHEN v_costo_actual IS NULL THEN NULL
               ELSE round(v_costo_actual * (1 + COALESCE(v_imp_int_actual, 0) / 100), 4) END));
      v_pct_iva_snapshot := v_pct_iva_snapshot || jsonb_build_object(v_producto_id::TEXT, v_pct_iva_actual);
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (
    cliente_id, fecha, total, total_neto, total_iva, total_real, tipo_factura,
    estado, usuario_id, creado_por, stock_descontado, notas, forma_pago,
    estado_pago, fecha_entrega_programada, sucursal_id, canal
  )
  VALUES (
    v_pendiente.cliente_id, v_fecha_pedido, v_pendiente.total,
    v_pendiente.total,
    0,
    v_pendiente.total,   -- ZZ: real = final
    'ZZ',
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

    -- ZZ: real = precio final; neto = teórico sin IVA (tasa del producto)
    IF v_es_bonificacion THEN
      v_neto_unitario := 0; v_ingreso_real := 0;
    ELSE
      v_neto_unitario := round(COALESCE(v_precio_unitario, 0) /
        (1 + COALESCE((v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC, 21) / 100), 2);
      v_ingreso_real := round(COALESCE(v_precio_unitario, 0), 2);
      v_total_neto_calc := v_total_neto_calc + (v_cantidad * v_neto_unitario);
      v_total_real_calc := v_total_real_calc + (v_cantidad * v_ingreso_real);
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id, neto_unitario, iva_unitario,
      impuestos_internos_unitario, porcentaje_iva, ingreso_real_unitario,
      sucursal_id, stock_al_crear, costo_unitario_al_crear
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario,
      v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id, v_neto_unitario, 0,
      0, CASE WHEN v_es_bonificacion THEN 0 ELSE COALESCE((v_pct_iva_snapshot->>v_producto_id::TEXT)::NUMERIC, 21) END,
      v_ingreso_real,
      v_pendiente.sucursal_id, v_stock_al_crear, v_costo_al_crear
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
     SET total_neto = round(v_total_neto_calc, 2),
         total_real = round(v_total_real_calc, 2)
   WHERE id = v_pedido_id AND sucursal_id = v_pendiente.sucursal_id;

  UPDATE bot_pedidos_pendientes SET consumido = TRUE WHERE id = p_confirmacion_id;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id, 'total', v_pendiente.total);
END;
$function$;
