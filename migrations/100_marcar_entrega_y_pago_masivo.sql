-- ============================================================================
-- 100 · Acción masiva combinada: marcar_entrega_y_pago_masivo()
-- ============================================================================
-- Equivalente masivo del botón individual "entregar y pagar" (handleEntregarConPago).
-- Hoy las acciones masivas separan "Entregas Masivas" (marcar_entregas_masivo)
-- y "Pagos Masivos" (marcar_pagos_masivo). Esta RPC las combina en UN SOLO paso
-- atómico: entrega + cobro de los pedidos seleccionados, eligiendo transportista
-- + una forma de pago.
--
-- Es la unión literal de las dos funciones probadas en prod, con un único UPDATE
-- (los triggers de pedidos se disparan una sola vez). NO toca a las dos RPC
-- existentes.
--
-- Semántica:
--   1) Por cada pedido NO pagado del lote: inserta una fila real en `pagos` por
--      el saldo pendiente (total - monto_pagado) con la forma de pago elegida.
--   2) Un solo UPDATE deja estado='entregado', fecha_entrega (mediodía AR),
--      transportista_id, monto_pagado=total y forma_pago.
--
-- Autorización: es_encargado_o_admin(). Para encargado, mismo gate de rendición
-- que marcar_pagos_masivo (fecha = hoy y rendición no cerrada), porque registra
-- pagos.
--
-- NOTA: defs basadas en la versión EN VIVO de prod (no en el repo).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.marcar_entrega_y_pago_masivo(
  p_pedido_ids bigint[],
  p_transportista_id uuid,
  p_forma_pago text,
  p_fecha date DEFAULT CURRENT_DATE
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
  v_rol TEXT;
  v_fecha_ts TIMESTAMPTZ;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entrega y pago masivos'
      USING ERRCODE = '42501';
  END IF;

  -- Mismo gate de rendición que marcar_pagos_masivo (esta RPC registra pagos)
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

  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- 1) Registrar pago por el saldo pendiente (solo pedidos NO pagados)
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

  -- 2) Entregar + saldar en un solo UPDATE (transportista_id SE asigna)
  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         monto_pagado = total,
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.marcar_entrega_y_pago_masivo(bigint[], uuid, text, date) TO authenticated;
