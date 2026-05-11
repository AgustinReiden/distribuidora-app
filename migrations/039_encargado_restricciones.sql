-- =========================================================================
-- 039_encargado_restricciones.sql
--
-- Refuerzo SQL de las restricciones del rol "encargado":
--
--   1. Helper public.rendicion_dia_cerrada(p_fecha, p_sucursal_id) -> boolean.
--      Devuelve true si existe rendicion confirmada o resuelta para esa
--      fecha y sucursal. Consumido por el frontend (banner en pagos masivos)
--      y por marcar_pagos_masivo (defensa en profundidad).
--
--   2. Reemplazo de marcar_pagos_masivo agregando guardas para encargado:
--        - fecha del pago debe ser CURRENT_DATE
--        - no puede haber rendicion cerrada para esa fecha + sucursal
--      Admin no se ve afectado.
--
--   3. Reemplazo de cancelar_pedido_con_stock: solo admin puede cancelar
--      pedidos (antes admitia admin o encargado).
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1. Helper: rendicion_dia_cerrada
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rendicion_dia_cerrada(
  p_fecha date,
  p_sucursal_id bigint DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal bigint;
BEGIN
  v_sucursal := COALESCE(p_sucursal_id, current_sucursal_id());
  IF v_sucursal IS NULL THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1 FROM rendiciones_control
    WHERE fecha = p_fecha
      AND sucursal_id = v_sucursal
      AND estado IN ('confirmada', 'resuelta')
  );
END;
$$;

ALTER FUNCTION public.rendicion_dia_cerrada(date, bigint) OWNER TO postgres;
COMMENT ON FUNCTION public.rendicion_dia_cerrada(date, bigint) IS
  'Devuelve true si existe rendicion confirmada o resuelta para (fecha, sucursal). Usado para bloquear pagos del encargado en dias ya cerrados.';

GRANT ALL ON FUNCTION public.rendicion_dia_cerrada(date, bigint) TO anon, authenticated, service_role;

-- -------------------------------------------------------------------------
-- 2. Reemplazo de marcar_pagos_masivo con restricciones de encargado
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.marcar_pagos_masivo(
  p_pedido_ids bigint[],
  p_forma_pago text,
  p_fecha date DEFAULT CURRENT_DATE
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar pagos masivos'
      USING ERRCODE = '42501';
  END IF;

  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();

  IF v_rol = 'encargado' THEN
    IF p_fecha <> CURRENT_DATE THEN
      RAISE EXCEPTION 'Encargado solo puede registrar pagos con fecha de hoy'
        USING ERRCODE = '42501';
    END IF;
    IF public.rendicion_dia_cerrada(p_fecha, v_sucursal_id) THEN
      RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. Pedi a un admin.'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- Insertar una fila en pagos por cada pedido pendiente. Monto = saldo
  -- pendiente (total - monto_pagado actual) para no duplicar parciales.
  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
  END LOOP;

  UPDATE pedidos
     SET monto_pagado = total,
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$$;

ALTER FUNCTION public.marcar_pagos_masivo(bigint[], text, date) OWNER TO postgres;
COMMENT ON FUNCTION public.marcar_pagos_masivo(bigint[], text, date) IS
  'Marca multiples pedidos como pagados en batch en una fecha dada. Encargado: solo p_fecha=hoy y sin rendicion cerrada. Admin: sin restricciones extra.';

-- -------------------------------------------------------------------------
-- 3. Reemplazo de cancelar_pedido_con_stock: solo admin
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancelar_pedido_con_stock(
  p_pedido_id bigint,
  p_motivo text,
  p_usuario_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cancelar pedidos');
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

ALTER FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid) OWNER TO postgres;
COMMENT ON FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid) IS
  'Cancela un pedido restaurando stock y revirtiendo promos. Solo admin (encargado bloqueado desde 039).';

COMMIT;
