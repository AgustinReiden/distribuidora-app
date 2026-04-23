-- Migration 010: registrar_salvedad — limpieza de bonificaciones obsoletas
--
-- Motivo: cuando un item que origina una promoción se marca como "entregado
-- con salvedad" (cantidad afectada > 0), el umbral de la promo deja de
-- cumplirse parcial o totalmente. La versión anterior de `registrar_salvedad`
-- sólo ajustaba el item afectado; dejaba las líneas de bonificación intactas,
-- quedando "regalos huérfanos" en el pedido y el stock/usos_pendientes
-- descuadrados.
--
-- Fix: tras reducir/eliminar el item, recorrer las bonificaciones del pedido,
-- recomputar la cantidad esperada según las reglas de cada promo y ajustar o
-- eliminar las líneas correspondientes, devolviendo stock cuando
-- `regalo_mueve_stock = TRUE` y decrementando `usos_pendientes`.
--
-- Compatible con pedidos sin bonificaciones (el loop es no-op).
-- Idempotente (CREATE OR REPLACE).

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
  -- Variables para la resincronización de bonificaciones
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

  -- ===========================================================================
  -- NUEVO: resincronizar bonificaciones tras la salvedad
  -- Recorremos cada bonificación del pedido; recomputamos la cantidad esperada
  -- según el total actual de items disparadores y las reglas de la promo. Si la
  -- cantidad esperada cayó, devolvemos stock (cuando aplica) y decrementamos
  -- usos_pendientes antes de reducir o eliminar la línea de regalo.
  -- ===========================================================================
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

    -- Si la promo no existe o falta alguna regla, saltamos (sin tocar la línea).
    IF v_cant_compra IS NULL OR v_cant_compra <= 0
       OR v_cant_bonif IS NULL OR v_cant_bonif <= 0 THEN
      CONTINUE;
    END IF;

    -- Total de unidades no-bonif de los productos disparadores de esta promo
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

    -- Sólo reducimos; nunca aumentamos la bonificación en este flujo
    -- (salvedad sólo puede restar productos del pedido).
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

  -- Recalcular total del pedido DESPUÉS de la limpieza de bonificaciones.
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
