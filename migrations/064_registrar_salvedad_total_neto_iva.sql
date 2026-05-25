-- ============================================================================
-- 064 - registrar_salvedad: recalcular tambien total_neto y total_iva
-- ============================================================================
-- Bug: la rutina recalcula `total` (SUM(subtotal)) tras alterar pedido_items
-- pero NO recalcula `total_neto` ni `total_iva`. Resultado: pedidos editados
-- por salvedad quedan con total correcto pero neto/iva desactualizados, lo
-- que rompe reportes contables (~0,8% de las ventas del mes).
--
-- Fix: actualizar las DOS overloads de registrar_salvedad (la legacy de
-- mig 011 sin client_request_id y la idempotente de mig 049) para que el
-- UPDATE final tambien sume cantidad*neto_unitario y cantidad*iva_unitario
-- de los pedido_items no bonificados (los regalos no aportan a neto/iva).
--
-- Hotfix: UPDATE de los 27 pedidos detectados con total_neto desincronizado
-- (sucursales 1 y 2, abril+mayo 2026). Se recalcula desde pedido_items.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. registrar_salvedad LEGACY (sin p_client_request_id) - reemplazo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_salvedad(
  p_pedido_id         BIGINT,
  p_pedido_item_id    BIGINT,
  p_cantidad_afectada INTEGER,
  p_motivo            CHARACTER VARYING,
  p_descripcion       TEXT    DEFAULT NULL,
  p_foto_url          TEXT    DEFAULT NULL,
  p_devolver_stock    BOOLEAN DEFAULT TRUE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
    UPDATE pedido_items SET cantidad = v_cantidad_entregada, subtotal = v_subtotal_nuevo
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    DELETE FROM pedido_items WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  END IF;

  FOR v_bonif IN
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
  LOOP
    SELECT
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT,
      MAX(p.regalo_mueve_stock::INT)::BOOLEAN
    INTO v_cant_compra, v_cant_bonif, v_regalo_mueve_stock
    FROM promociones p
    LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
    WHERE p.id = v_bonif.promocion_id AND p.sucursal_id = v_sucursal
    GROUP BY p.id;

    IF v_cant_compra IS NULL OR v_cant_compra <= 0
       OR v_cant_bonif IS NULL OR v_cant_bonif <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(SUM(pi.cantidad), 0)::INT
      INTO v_total_qty
      FROM pedido_items pi
      JOIN promocion_productos pp ON pp.producto_id = pi.producto_id AND pp.promocion_id = v_bonif.promocion_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = FALSE;

    v_bloques        := v_total_qty / v_cant_compra;
    v_expected_bonif := v_bloques * v_cant_bonif;

    IF v_expected_bonif < v_bonif.cantidad THEN
      v_diff := v_bonif.cantidad - v_expected_bonif;

      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock + v_diff
         WHERE id = v_bonif.producto_id AND sucursal_id = v_sucursal;
      END IF;

      PERFORM public.revertir_bloques_auto_ajuste(
        v_bonif.promocion_id, v_diff, v_sucursal,
        v_usuario_id, 'Salvedad pedido #' || p_pedido_id
      );

      IF v_expected_bonif = 0 THEN
        DELETE FROM pedido_items WHERE id = v_bonif.id;
      ELSE
        UPDATE pedido_items
           SET cantidad = v_expected_bonif, subtotal = v_expected_bonif * COALESCE(precio_unitario, 0)
         WHERE id = v_bonif.id;
      END IF;
    END IF;
  END LOOP;

  UPDATE pedidos
     SET total = sub.total_recalc,
         total_neto = sub.neto_recalc,
         total_iva = sub.iva_recalc,
         updated_at = NOW()
    FROM (
      SELECT
        COALESCE(SUM(subtotal), 0) AS total_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(neto_unitario, precio_unitario)
                          ELSE 0 END), 0) AS neto_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(iva_unitario, 0)
                          ELSE 0 END), 0) AS iva_recalc
        FROM pedido_items
       WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
    ) sub
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  IF v_stock_devuelto THEN
    UPDATE productos SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;

  IF p_motivo IN ('producto_danado', 'producto_vencido') THEN
    SELECT stock INTO v_stock_actual
      FROM productos WHERE id = v_item.producto_id AND sucursal_id = v_sucursal FOR UPDATE;

    INSERT INTO mermas_stock (producto_id, cantidad, motivo, observaciones, stock_anterior, stock_nuevo, usuario_id, sucursal_id)
    VALUES (v_item.producto_id, p_cantidad_afectada,
      CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento' END,
      COALESCE(p_descripcion, 'Salvedad pedido #' || p_pedido_id || ': ' || p_motivo),
      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal);

    UPDATE productos SET stock = GREATEST(stock - p_cantidad_afectada, 0)
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    v_merma_registrada := TRUE;
  END IF;

  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object(
    'success', true, 'salvedad_id', v_salvedad_id,
    'monto_afectado', v_monto_afectado, 'cantidad_entregada', v_cantidad_entregada,
    'stock_devuelto', v_stock_devuelto, 'merma_registrada', v_merma_registrada,
    'nuevo_total_pedido', (SELECT total FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

-- ----------------------------------------------------------------------------
-- 2. registrar_salvedad IDEMPOTENTE (con p_client_request_id) - reemplazo
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.registrar_salvedad(
  p_pedido_id         BIGINT,
  p_pedido_item_id    BIGINT,
  p_cantidad_afectada INTEGER,
  p_motivo            CHARACTER VARYING,
  p_descripcion       TEXT    DEFAULT NULL,
  p_foto_url          TEXT    DEFAULT NULL,
  p_devolver_stock    BOOLEAN DEFAULT TRUE,
  p_client_request_id UUID    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal           BIGINT := current_sucursal_id();
  v_salvedad_id        BIGINT;
  v_item               RECORD;
  v_existing           RECORD;
  v_cantidad_entregada INTEGER;
  v_monto_afectado     DECIMAL;
  v_usuario_id         UUID;
  v_es_admin           BOOLEAN;
  v_subtotal_nuevo     DECIMAL;
  v_stock_devuelto     BOOLEAN := FALSE;
  v_merma_registrada   BOOLEAN := FALSE;
  v_stock_actual       INTEGER;
  v_bonif              RECORD;
  v_cant_compra        INT;
  v_cant_bonif         INT;
  v_total_qty          INT;
  v_bloques            INT;
  v_expected_bonif     INT;
  v_diff               INT;
  v_regalo_mueve_stock BOOLEAN;
BEGIN
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, motivo, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id
      INTO v_existing
      FROM salvedades_items
     WHERE client_request_id = p_client_request_id;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'salvedad_id', v_existing.id,
        'monto_afectado', v_existing.monto_afectado,
        'cantidad_entregada', v_existing.cantidad_entregada,
        'stock_devuelto', v_existing.stock_devuelto,
        'merma_registrada', v_existing.motivo IN ('producto_danado', 'producto_vencido'),
        'nuevo_total_pedido', (
          SELECT total FROM pedidos
           WHERE id = v_existing.pedido_id AND sucursal_id = v_sucursal
        ),
        'idempotent_replay', true
      );
    END IF;
  END IF;

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

  IF NOT FOUND THEN
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

  PERFORM set_config('app.stock_origen', 'salvedad', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', v_usuario_id::TEXT, true);

  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
    cantidad_entregada, motivo, descripcion, foto_url, monto_afectado, precio_unitario,
    reportado_por, stock_devuelto, stock_devuelto_at, estado_resolucion, sucursal_id,
    client_request_id
  ) VALUES (
    p_pedido_id, p_pedido_item_id, v_item.producto_id, v_item.cantidad, p_cantidad_afectada,
    v_cantidad_entregada, p_motivo, p_descripcion, p_foto_url, v_monto_afectado, v_item.precio_unitario,
    v_usuario_id, v_stock_devuelto, CASE WHEN v_stock_devuelto THEN NOW() ELSE NULL END, 'pendiente', v_sucursal,
    p_client_request_id
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

      UPDATE promociones
         SET usos_pendientes = GREATEST(COALESCE(usos_pendientes, 0) - v_diff, 0)
       WHERE id = v_bonif.promocion_id
         AND sucursal_id = v_sucursal;

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
     SET total = sub.total_recalc,
         total_neto = sub.neto_recalc,
         total_iva = sub.iva_recalc,
         updated_at = NOW()
    FROM (
      SELECT
        COALESCE(SUM(subtotal), 0) AS total_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(neto_unitario, precio_unitario)
                          ELSE 0 END), 0) AS neto_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(iva_unitario, 0)
                          ELSE 0 END), 0) AS iva_recalc
        FROM pedido_items
       WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
    ) sub
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
$function$;

-- ----------------------------------------------------------------------------
-- 3. Hotfix: resincronizar total_neto y total_iva en los 27 pedidos afectados
-- ----------------------------------------------------------------------------
-- Se filtra a pedidos donde total ya esta correcto (= SUM(subtotal) o = 0 si
-- no quedan items) pero total_neto / total_iva no coinciden. Asi no tocamos
-- pedidos pre-columna (NULL legacy) que pueden ser un caso aparte.

WITH recalc AS (
  SELECT p.id AS pedido_id, p.sucursal_id,
         COALESCE((SELECT SUM(pi.subtotal)
                     FROM pedido_items pi
                    WHERE pi.pedido_id = p.id AND pi.sucursal_id = p.sucursal_id), 0)
           AS total_recalc,
         COALESCE((SELECT SUM(pi.cantidad * COALESCE(pi.neto_unitario, pi.precio_unitario))
                     FROM pedido_items pi
                    WHERE pi.pedido_id = p.id AND pi.sucursal_id = p.sucursal_id
                      AND COALESCE(pi.es_bonificacion, FALSE) = FALSE), 0)
           AS neto_recalc,
         COALESCE((SELECT SUM(pi.cantidad * COALESCE(pi.iva_unitario, 0))
                     FROM pedido_items pi
                    WHERE pi.pedido_id = p.id AND pi.sucursal_id = p.sucursal_id
                      AND COALESCE(pi.es_bonificacion, FALSE) = FALSE), 0)
           AS iva_recalc
    FROM pedidos p
   WHERE p.total_neto IS NOT NULL
)
UPDATE pedidos p
   SET total_neto = r.neto_recalc,
       total_iva  = r.iva_recalc,
       updated_at = NOW()
  FROM recalc r
 WHERE p.id = r.pedido_id
   AND p.sucursal_id = r.sucursal_id
   AND p.total = r.total_recalc
   AND (
     p.total_neto IS DISTINCT FROM r.neto_recalc
     OR p.total_iva IS DISTINCT FROM r.iva_recalc
   );
