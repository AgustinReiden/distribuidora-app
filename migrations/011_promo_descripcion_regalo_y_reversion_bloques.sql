-- Migration 011: descripcion_regalo para promos fraccionales + reversion exacta por bloques
--
-- Problema 1 (display): cuando una promo regala una fraccion (ej: 1 botella de
-- un fardo x12), producto_regalo_id apunta al fardo y la tarjeta del pedido
-- muestra "2 x fardo" cuando en realidad se regalaron 2 botellas sueltas. Se
-- agrega un campo `descripcion_regalo` en promociones (texto manual) y un
-- snapshot en pedido_items para que el front lo renderice tal cual se cargo.
--
-- Problema 2 (reversion): la logica actual de salvedad/cancelacion/edicion hace
-- GREATEST(usos_pendientes - delta, 0) pero no revierte el stock del
-- ajuste_producto_id cuando esos usos ya habian cerrado un bloque y se
-- descontaron fardos automaticamente. Se introduce un helper
-- revertir_bloques_auto_ajuste() que calcula cuantos bloques deben revertirse,
-- suma stock al producto contenedor, registra merma negativa y promo_ajustes
-- negativos, y deja usos_pendientes >= 0.
--
-- Compatible con promos que no usan ajuste_automatico (el helper se comporta
-- como el GREATEST anterior). Idempotente (CREATE OR REPLACE + IF NOT EXISTS).

-- ============================================================================
-- 1. Schema
-- ============================================================================

ALTER TABLE promociones  ADD COLUMN IF NOT EXISTS descripcion_regalo TEXT;
ALTER TABLE pedido_items ADD COLUMN IF NOT EXISTS descripcion_regalo TEXT;

-- Permitir cantidades negativas en mermas_stock para representar reversiones.
-- Se reemplaza el check `cantidad > 0` por `cantidad <> 0`.
ALTER TABLE mermas_stock DROP CONSTRAINT IF EXISTS mermas_stock_cantidad_check;
ALTER TABLE mermas_stock ADD  CONSTRAINT mermas_stock_cantidad_check CHECK (cantidad <> 0);

-- Nuevo motivo "promociones_reversion" para historico de reversiones por
-- salvedad/cancelacion cuando ya habia bloques auto-ajustados.
ALTER TABLE mermas_stock DROP CONSTRAINT IF EXISTS mermas_stock_motivo_check;
ALTER TABLE mermas_stock ADD  CONSTRAINT mermas_stock_motivo_check
  CHECK (motivo IN (
    'rotura','vencimiento','robo','decomiso','devolucion',
    'error_inventario','muestra','otro','promociones','promociones_reversion'
  ));

-- ============================================================================
-- 2. Helper: revertir bloques de auto-ajuste
-- ============================================================================
-- Baja usos_pendientes por p_usos_delta. Si la promo tiene auto-ajuste y el
-- decremento dejaria usos negativos, revierte tantos bloques completos como
-- haga falta: suma stock al ajuste_producto_id, registra merma negativa y
-- promo_ajustes negativo. Retorna los usos_pendientes finales (>= 0).
--
-- Si la promo NO tiene auto-ajuste configurado, hace el GREATEST(... - delta, 0)
-- clasico (mismo comportamiento que las RPCs anteriores).

CREATE OR REPLACE FUNCTION public.revertir_bloques_auto_ajuste(
  p_promocion_id  bigint,
  p_usos_delta    integer,
  p_sucursal_id   bigint,
  p_usuario_id    uuid,
  p_observaciones text DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_promo              RECORD;
  v_usos_antes         INT;
  v_usos_nuevos_raw    INT;
  v_bloques_a_revertir INT;
  v_usos_a_liberar     INT;
  v_usos_finales       INT;
  v_stock_a_devolver   INT;
  v_stock_anterior     INT;
  v_stock_nuevo        INT;
  v_merma_id           BIGINT;
BEGIN
  IF p_usos_delta IS NULL OR p_usos_delta <= 0 THEN
    RETURN COALESCE(
      (SELECT usos_pendientes FROM promociones
        WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id), 0);
  END IF;

  SELECT id, nombre, ajuste_automatico, ajuste_producto_id,
         unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_promo
    FROM promociones
   WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id
   FOR UPDATE;

  IF NOT FOUND THEN RETURN 0; END IF;

  v_usos_antes      := COALESCE(v_promo.usos_pendientes, 0);
  v_usos_nuevos_raw := v_usos_antes - p_usos_delta;

  -- Caso A: promo sin auto-ajuste → clampa y listo.
  IF NOT COALESCE(v_promo.ajuste_automatico, FALSE)
     OR v_promo.ajuste_producto_id IS NULL
     OR COALESCE(v_promo.unidades_por_bloque, 0) <= 0
     OR COALESCE(v_promo.stock_por_bloque, 0)   <= 0 THEN
    v_usos_finales := GREATEST(v_usos_nuevos_raw, 0);
    UPDATE promociones SET usos_pendientes = v_usos_finales
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
    RETURN v_usos_finales;
  END IF;

  -- Caso B: promo con auto-ajuste, decremento no cruza un bloque ya ajustado.
  IF v_usos_nuevos_raw >= 0 THEN
    UPDATE promociones SET usos_pendientes = v_usos_nuevos_raw
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
    RETURN v_usos_nuevos_raw;
  END IF;

  -- Caso C: reversion de bloques. Calcula cuantos bloques completos cubren el
  -- deficit y libera esa cantidad de usos; el resto vuelve al contador.
  v_bloques_a_revertir := CEIL(
    ABS(v_usos_nuevos_raw)::NUMERIC / v_promo.unidades_por_bloque::NUMERIC
  )::INT;
  v_usos_a_liberar   := v_bloques_a_revertir * v_promo.unidades_por_bloque;
  v_usos_finales     := v_usos_nuevos_raw + v_usos_a_liberar;
  v_stock_a_devolver := v_bloques_a_revertir * v_promo.stock_por_bloque;

  -- Devolver stock al producto contenedor.
  SELECT stock INTO v_stock_anterior
    FROM productos
   WHERE id = v_promo.ajuste_producto_id AND sucursal_id = p_sucursal_id
   FOR UPDATE;

  v_stock_nuevo := COALESCE(v_stock_anterior, 0) + v_stock_a_devolver;

  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
   WHERE id = v_promo.ajuste_producto_id AND sucursal_id = p_sucursal_id;

  -- Merma negativa (representa la reversion).
  INSERT INTO mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    v_promo.ajuste_producto_id, -v_stock_a_devolver, 'promociones_reversion',
    COALESCE(p_observaciones, 'Reversion auto-ajuste') || ' (Promo: ' || v_promo.nombre || ')',
    COALESCE(v_stock_anterior, 0), v_stock_nuevo, p_usuario_id, p_sucursal_id
  ) RETURNING id INTO v_merma_id;

  -- Ajuste negativo para cerrar contrapartida.
  INSERT INTO promo_ajustes (
    promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
    merma_id, usuario_id, observaciones, sucursal_id
  ) VALUES (
    p_promocion_id, -v_usos_a_liberar, -v_stock_a_devolver, v_promo.ajuste_producto_id,
    v_merma_id, p_usuario_id,
    COALESCE(p_observaciones, 'Reversion auto-ajuste'),
    p_sucursal_id
  );

  UPDATE promociones SET usos_pendientes = v_usos_finales
   WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;

  RETURN v_usos_finales;
END;
$$;

REVOKE ALL ON FUNCTION public.revertir_bloques_auto_ajuste(bigint, integer, bigint, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.revertir_bloques_auto_ajuste(bigint, integer, bigint, uuid, text) TO authenticated;

-- ============================================================================
-- 3. crear_pedido_completo: persistir descripcion_regalo en pedido_items
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
  v_regalo_mueve_stock BOOLEAN;
  v_descripcion_regalo TEXT;
  v_fecha_pedido DATE := COALESCE(
    p_fecha,
    (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
  );
  v_fecha_entrega DATE := COALESCE(
    p_fecha_entrega_programada,
    (v_fecha_pedido + INTERVAL '1 day')::date
  );
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
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesion autenticada')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN errores := array_append(errores, 'Cantidad invalida para producto ID ' || v_producto_id); CONTINUE; END IF;

    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
          v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
          v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
        END IF;
      END IF;
    ELSE
      v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
      v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
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

    -- Snapshot del texto manual del regalo (solo en items bonificacion).
    v_descripcion_regalo := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo INTO v_descripcion_regalo
        FROM promociones
       WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id, descripcion_regalo
    )
    VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal, v_descripcion_regalo
    );

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
    END IF;

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad
      WHERE id = v_promocion_id AND sucursal_id = v_sucursal;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

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
          FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

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
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || v_pedido_id || ')',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal
          ) RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (
            promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
            merma_id, usuario_id, observaciones, sucursal_id
          ) VALUES (
            v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,
            v_merma_id, p_usuario_id,
            'Auto-ajuste por pedido #' || v_pedido_id, v_sucursal
          );

          UPDATE promociones
          SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- ============================================================================
-- 4. actualizar_pedido_items: persistir descripcion_regalo + usar helper para
--    reversion de bloques al recalcular.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(
  p_pedido_id bigint, p_items_nuevos jsonb, p_usuario_id uuid
) RETURNS jsonb
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

  -- Validacion previa: stock suficiente para los deltas positivos.
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

  -- Devolver stock de items no-bonif actuales.
  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id
    AND p.sucursal_id = v_sucursal;

  -- Devolver stock de bonificaciones que mueven stock.
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

  -- Revertir usos_pendientes con helper (maneja reversion de bloques).
  FOR v_bonif IN
    SELECT promocion_id, SUM(cantidad)::INT AS total_cantidad
      FROM pedido_items
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
       AND COALESCE(es_bonificacion, false) = true
       AND promocion_id IS NOT NULL
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
    v_neto_unitario := (v_item_nuevo->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((v_item_nuevo->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((v_item_nuevo->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item_nuevo->>'porcentaje_iva')::DECIMAL, 0);

    v_descripcion_regalo := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo INTO v_descripcion_regalo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id, descripcion_regalo
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal, v_descripcion_regalo
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

      -- Auto-ajuste si corresponde (misma logica que crear_pedido_completo).
      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

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
          FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

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
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || p_pedido_id || ', edicion)',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal
          ) RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (
            promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
            merma_id, usuario_id, observaciones, sucursal_id
          ) VALUES (
            v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,
            v_merma_id, p_usuario_id,
            'Auto-ajuste por edicion pedido #' || p_pedido_id, v_sucursal
          );

          UPDATE promociones
          SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
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
$function$;

-- ============================================================================
-- 5. cancelar_pedido_con_stock: usar helper para reversion de bloques
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
        PERFORM public.revertir_bloques_auto_ajuste(
          v_item.promocion_id, v_item.cantidad::INT, v_sucursal,
          v_acting_user, 'Cancelacion pedido #' || p_pedido_id
        );
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
$function$;

-- ============================================================================
-- 6. eliminar_pedido_completo: decrementar usos_pendientes + reversion
--    (antes no se decrementaba — bug menor subsanado acá)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.eliminar_pedido_completo(
  p_pedido_id bigint, p_usuario_id uuid,
  p_motivo text DEFAULT NULL::text, p_restaurar_stock boolean DEFAULT true
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

      -- Revertir contador y bloques auto-ajustados de promo (antes no se hacia).
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

-- ============================================================================
-- 7. registrar_salvedad: usar helper para reversion de bloques
-- ============================================================================

CREATE OR REPLACE FUNCTION public.registrar_salvedad(
  p_pedido_id       bigint,
  p_pedido_item_id  bigint,
  p_cantidad_afectada integer,
  p_motivo          character varying,
  p_descripcion     text    DEFAULT NULL,
  p_foto_url        text    DEFAULT NULL,
  p_devolver_stock  boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal          BIGINT := current_sucursal_id();
  v_salvedad_id       BIGINT;
  v_item              RECORD;
  v_cantidad_entregada INTEGER;
  v_monto_afectado    DECIMAL;
  v_usuario_id        UUID;
  v_es_admin          BOOLEAN;
  v_subtotal_nuevo    DECIMAL;
  v_stock_devuelto    BOOLEAN := FALSE;
  v_merma_registrada  BOOLEAN := FALSE;
  v_stock_actual      INTEGER;
  v_bonif             RECORD;
  v_cant_compra       INT;
  v_cant_bonif        INT;
  v_total_qty         INT;
  v_bloques           INT;
  v_expected_bonif    INT;
  v_diff              INT;
  v_regalo_mueve_stock BOOLEAN;
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
  v_monto_afectado     := p_cantidad_afectada * v_item.precio_unitario;
  v_subtotal_nuevo     := v_cantidad_entregada * v_item.precio_unitario;

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
       SET cantidad = v_cantidad_entregada,
           subtotal = v_subtotal_nuevo
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    DELETE FROM pedido_items
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  END IF;

  -- Resincronizar bonificaciones: recalcular cantidad esperada, devolver stock
  -- del regalo cuando aplica, y usar el helper para decrementar usos_pendientes
  -- con reversion de bloques cuando corresponda.
  FOR v_bonif IN
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
  LOOP
    SELECT
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT,
      MAX(p.regalo_mueve_stock::INT)::BOOLEAN
    INTO v_cant_compra, v_cant_bonif, v_regalo_mueve_stock
    FROM promociones p
    LEFT JOIN promocion_reglas pr
      ON pr.promocion_id = p.id
    WHERE p.id = v_bonif.promocion_id
      AND p.sucursal_id = v_sucursal
    GROUP BY p.id;

    IF v_cant_compra IS NULL OR v_cant_compra <= 0
       OR v_cant_bonif IS NULL OR v_cant_bonif <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(SUM(pi.cantidad), 0)::INT
      INTO v_total_qty
      FROM pedido_items pi
      JOIN promocion_productos pp
        ON pp.producto_id = pi.producto_id
       AND pp.promocion_id = v_bonif.promocion_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = FALSE;

    v_bloques        := v_total_qty / v_cant_compra;
    v_expected_bonif := v_bloques * v_cant_bonif;

    IF v_expected_bonif < v_bonif.cantidad THEN
      v_diff := v_bonif.cantidad - v_expected_bonif;

      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos
           SET stock = stock + v_diff
         WHERE id = v_bonif.producto_id
           AND sucursal_id = v_sucursal;
      END IF;

      PERFORM public.revertir_bloques_auto_ajuste(
        v_bonif.promocion_id, v_diff, v_sucursal,
        v_usuario_id, 'Salvedad pedido #' || p_pedido_id
      );

      IF v_expected_bonif = 0 THEN
        DELETE FROM pedido_items WHERE id = v_bonif.id;
      ELSE
        UPDATE pedido_items
           SET cantidad = v_expected_bonif,
               subtotal = v_expected_bonif * COALESCE(precio_unitario, 0)
         WHERE id = v_bonif.id;
      END IF;
    END IF;
  END LOOP;

  UPDATE pedidos
     SET total = (
           SELECT COALESCE(SUM(subtotal), 0)
             FROM pedido_items
            WHERE pedido_id = p_pedido_id
              AND sucursal_id = v_sucursal
         ),
         updated_at = NOW()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  IF v_stock_devuelto THEN
    UPDATE productos
       SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;

  IF p_motivo IN ('producto_danado', 'producto_vencido') THEN
    SELECT stock INTO v_stock_actual
      FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_item.producto_id, p_cantidad_afectada,
      CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento' END,
      COALESCE(p_descripcion, 'Salvedad pedido #' || p_pedido_id || ': ' || p_motivo),
      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal
    );

    UPDATE productos
       SET stock = GREATEST(stock - p_cantidad_afectada, 0)
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    v_merma_registrada := TRUE;
  END IF;

  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object(
    'success', true,
    'salvedad_id', v_salvedad_id,
    'monto_afectado', v_monto_afectado,
    'cantidad_entregada', v_cantidad_entregada,
    'stock_devuelto', v_stock_devuelto,
    'merma_registrada', v_merma_registrada,
    'nuevo_total_pedido', (
      SELECT total FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal
    )
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
