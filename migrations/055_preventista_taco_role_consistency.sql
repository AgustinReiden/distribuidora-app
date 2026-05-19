-- =========================================================================
-- 055_preventista_taco_role_consistency.sql
--
-- El rol `preventista_taco` fue agregado por la migracion 050 al CHECK
-- constraint de `perfiles.rol`, pero NO se propago al resto de la logica:
-- multiples RPCs validan `rol IN ('admin','preventista',...)` sin incluir
-- `preventista_taco`, y la RLS `mt_clientes_select` lo trata como "no
-- preventista", lo cual le devuelve TODA la sucursal en vez de filtrar por
-- `cliente_preventistas`. Resultado: el preventista_taco no puede crear
-- pedidos (RPC rechazado) y la app se le pone lenta porque carga miles de
-- clientes que no le corresponden.
--
-- Esta migracion corrige el inconsistente listado:
--
--   1. `es_preventista()`: amplia el WHERE para incluir `preventista_taco`.
--      Como la funcion se usa en muchas policies/RPCs, el cambio se
--      propaga solo.
--
--   2. RLS `mt_clientes_select`: la rama "es preventista" ahora pregunta
--      `rol IN ('preventista','preventista_taco')`. Asi el preventista_taco
--      cae en el filtro estricto por `cliente_preventistas`.
--
--   3. RPC `crear_pedido_completo` (mig 044): admite preventista_taco en
--      role check. Cuerpo identico al de 044.
--
--   4. RPC `actualizar_pedido_items` (mig 045): admite preventista_taco en
--      role check + rama de validaciones especificas. Cuerpo identico al
--      de 045.
--
--   5. RPC `obtener_geolocalizacion_preventistas` (mig 043): filtros
--      `per.rol IN ('preventista','preventista_taco')`. Cuerpo identico al
--      de 043 salvo los 3 lugares afectados.
--
--   6. RPC `registrar_visita_cliente` (mig 052): admite preventista_taco
--      en role check + rama de validacion de asignacion. Cuerpo identico
--      al de 052.
--
-- No requiere cambios en codigo TS: `isAnyPreventista` ya existe en
-- src/App.tsx y los permisos de lib/permisos.ts ya cubren ambos roles.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. es_preventista() ampliado
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.es_preventista() RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
      AND rol IN ('admin', 'preventista', 'preventista_taco', 'encargado')
  );
END;
$$;

-- -------------------------------------------------------------------------
-- 2. RLS mt_clientes_select: tratar preventista_taco como preventista
-- -------------------------------------------------------------------------

DROP POLICY IF EXISTS "mt_clientes_select" ON public.clientes;
CREATE POLICY "mt_clientes_select"
  ON public.clientes
  FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      -- Roles que no son preventista ven todos los clientes de su sucursal
      NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol IN ('preventista', 'preventista_taco')
      )
      -- Preventistas: solo clientes sin asignaciones
      OR NOT EXISTS (
        SELECT 1 FROM public.cliente_preventistas cp
        WHERE cp.cliente_id = clientes.id
      )
      -- ...o clientes asignados a ellos
      OR EXISTS (
        SELECT 1 FROM public.cliente_preventistas cp
        WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()
      )
    )
  );

-- -------------------------------------------------------------------------
-- 3. RPC crear_pedido_completo (cuerpo identico al de mig 044, role check
--    ampliado para preventista_taco)
-- -------------------------------------------------------------------------

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
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'preventista_taco', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  -- Loop 1: acumular cantidades por producto (incluye TODOS: ventas y regalos).
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
    IF v_stock_actual IS NOT NULL THEN
      v_stock_snapshot := v_stock_snapshot || jsonb_build_object(v_producto_id::TEXT, v_stock_actual);
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, tipo_factura, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)
  VALUES (p_cliente_id, v_fecha_pedido, p_total, COALESCE(p_total_neto, p_total), COALESCE(p_total_iva, 0), COALESCE(p_tipo_factura, 'ZZ'), 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)
  RETURNING id INTO v_pedido_id;

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

-- -------------------------------------------------------------------------
-- 4. RPC actualizar_pedido_items (cuerpo identico al de mig 045, role check
--    ampliado para preventista_taco en ambas referencias)
-- -------------------------------------------------------------------------

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
  v_pedido_creator UUID;
  v_pedido_created_at TIMESTAMPTZ;
  v_hora_corte CONSTANT TIME := TIME '15:30';
  v_precio_actual DECIMAL;
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

  SELECT total, usuario_id, created_at
    INTO v_total_anterior, v_pedido_creator, v_pedido_created_at
    FROM pedidos
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- Validaciones especificas para preventista (incluye preventista_taco).
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

    -- No puede SUBIR precios. Acepta precio base o cualquier descuento
    -- mayorista (que por construccion es <= productos.precio).
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
    v_neto_unitario := (v_item_nuevo->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((v_item_nuevo->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((v_item_nuevo->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item_nuevo->>'porcentaje_iva')::DECIMAL, 0);

    v_descripcion_regalo := NULL;
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      SELECT descripcion_regalo INTO v_descripcion_regalo FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
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
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * COALESCE(v_neto_unitario, v_precio_unitario));
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

  UPDATE pedidos SET total = v_total_nuevo, total_neto = v_total_neto_nuevo, total_iva = v_total_iva_nuevo, updated_at = NOW()
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

-- -------------------------------------------------------------------------
-- 5. RPC obtener_geolocalizacion_preventistas (cuerpo identico al de mig
--    043, los 3 filtros `per.rol = 'preventista'` se amplian para incluir
--    preventista_taco)
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_geolocalizacion_preventistas(
  p_fecha_desde date DEFAULT NULL,
  p_fecha_hasta date DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_fecha_desde date := COALESCE(p_fecha_desde, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_fecha_hasta date := COALESCE(p_fecha_hasta, v_fecha_desde);
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role <> 'admin' THEN
    RAISE EXCEPTION 'Solo admins pueden ver geolocalizacion de preventistas' USING ERRCODE = '42501';
  END IF;
  WITH pedidos_rango AS (
    SELECT
      p.id              AS pedido_id,
      p.usuario_id      AS preventista_id,
      p.fecha,
      p.created_at      AS pedido_created_at,
      p.total,
      p.gps_lat,
      p.gps_lng,
      p.gps_accuracy,
      p.gps_capturado_at,
      p.gps_status,
      p.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(p.gps_lat, p.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM pedidos p
    LEFT JOIN clientes c ON c.id = p.cliente_id
    WHERE p.sucursal_id = v_sucursal
      AND p.fecha BETWEEN v_fecha_desde AND v_fecha_hasta
      AND p.usuario_id IS NOT NULL
  ),
  visitas_rango AS (
    SELECT
      v.id              AS visita_id,
      v.preventista_id,
      v.created_at      AS visita_created_at,
      v.gps_lat,
      v.gps_lng,
      v.gps_accuracy,
      v.gps_capturado_at,
      v.gps_status,
      v.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(v.gps_lat, v.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM visitas_cliente v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    WHERE v.sucursal_id = v_sucursal
      AND (v.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN v_fecha_desde AND v_fecha_hasta
  ),
  preventistas_resumen AS (
    SELECT
      pr.preventista_id,
      per.nombre AS preventista_nombre,
      COUNT(*)::int AS total_pedidos,
      COUNT(*) FILTER (WHERE pr.gps_status = 'ok')::int AS pedidos_con_gps,
      COUNT(*) FILTER (WHERE pr.gps_status IS NULL OR pr.gps_status <> 'ok')::int AS pedidos_sin_gps,
      COUNT(*) FILTER (
        WHERE pr.gps_status = 'ok' AND pr.distancia_m IS NOT NULL AND pr.distancia_m >= 1000
      )::int AS pedidos_lejos,
      (SELECT COUNT(*) FROM visitas_rango v WHERE v.preventista_id = pr.preventista_id)::int AS total_visitas,
      (
        SELECT jsonb_build_object(
          'lat', e.lat,
          'lng', e.lng,
          'capturado_at', e.capturado_at,
          'tipo', e.tipo,
          'id', e.id
        )
        FROM (
          SELECT pr2.gps_lat AS lat, pr2.gps_lng AS lng, pr2.gps_capturado_at AS capturado_at,
                 'pedido'::text AS tipo, pr2.pedido_id AS id
          FROM pedidos_rango pr2
          WHERE pr2.preventista_id = pr.preventista_id AND pr2.gps_status = 'ok'
          UNION ALL
          SELECT v.gps_lat AS lat, v.gps_lng AS lng, v.gps_capturado_at AS capturado_at,
                 'visita'::text AS tipo, v.visita_id AS id
          FROM visitas_rango v
          WHERE v.preventista_id = pr.preventista_id AND v.gps_status = 'ok'
        ) e
        ORDER BY e.capturado_at DESC NULLS LAST
        LIMIT 1
      ) AS ultima_ubicacion
    FROM pedidos_rango pr
    LEFT JOIN perfiles per ON per.id = pr.preventista_id
    WHERE per.rol IN ('preventista', 'preventista_taco')
    GROUP BY pr.preventista_id, per.nombre
  )
  SELECT jsonb_build_object(
    'fecha_desde', v_fecha_desde,
    'fecha_hasta', v_fecha_hasta,
    'preventistas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(preventistas_resumen.*) ORDER BY preventista_nombre)
       FROM preventistas_resumen),
      '[]'::jsonb
    ),
    'pedidos', COALESCE(
      (SELECT jsonb_agg(to_jsonb(pr.*) ORDER BY pr.pedido_created_at NULLS LAST)
       FROM pedidos_rango pr
       JOIN perfiles per ON per.id = pr.preventista_id AND per.rol IN ('preventista', 'preventista_taco')),
      '[]'::jsonb
    ),
    'visitas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(v.*) ORDER BY v.visita_created_at NULLS LAST)
       FROM visitas_rango v
       JOIN perfiles per ON per.id = v.preventista_id AND per.rol IN ('preventista', 'preventista_taco')),
      '[]'::jsonb
    )
  ) INTO v_result;
  RETURN v_result;
END;
$$;

-- -------------------------------------------------------------------------
-- 6. RPC registrar_visita_cliente (cuerpo identico al de mig 052, role
--    check ampliado para preventista_taco)
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_visita_cliente(
  p_cliente_id bigint,
  p_status text,
  p_lat numeric DEFAULT NULL,
  p_lng numeric DEFAULT NULL,
  p_accuracy numeric DEFAULT NULL,
  p_capturado_at timestamptz DEFAULT NULL,
  p_motivo_omision text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_cliente RECORD;
  v_autorizado boolean;
  v_visita_id bigint;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_status NOT IN ('ok','denied','unavailable','timeout','error') THEN
    RETURN jsonb_build_object('success', false, 'error', 'gps_status invalido');
  END IF;
  IF p_status = 'ok' AND (p_lat IS NULL OR p_lng IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'lat y lng requeridos cuando status=ok');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('preventista', 'preventista_taco', 'admin') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rol no autorizado para marcar visitas');
  END IF;

  SELECT id, sucursal_id INTO v_cliente FROM clientes WHERE id = p_cliente_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente no existe');
  END IF;
  IF v_cliente.sucursal_id IS DISTINCT FROM v_sucursal THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cliente fuera de la sucursal activa');
  END IF;

  IF v_user_role IN ('preventista', 'preventista_taco') THEN
    SELECT (
      NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id)
      OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = p_cliente_id AND cp.preventista_id = v_user_id)
    ) INTO v_autorizado;
    IF NOT v_autorizado THEN
      RETURN jsonb_build_object('success', false, 'error', 'Cliente asignado a otro preventista');
    END IF;
  END IF;

  INSERT INTO visitas_cliente (
    preventista_id, cliente_id, sucursal_id,
    gps_lat, gps_lng, gps_accuracy, gps_capturado_at, gps_status, gps_motivo_omision
  ) VALUES (
    v_user_id, p_cliente_id, v_sucursal,
    CASE WHEN p_status = 'ok' THEN p_lat ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_lng ELSE NULL END,
    CASE WHEN p_status = 'ok' THEN p_accuracy ELSE NULL END,
    COALESCE(p_capturado_at, now()),
    p_status,
    CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END
  ) RETURNING id INTO v_visita_id;

  RETURN jsonb_build_object('success', true, 'visita_id', v_visita_id);
END;
$$;

COMMIT;
