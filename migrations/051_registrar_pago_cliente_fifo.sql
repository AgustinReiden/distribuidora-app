-- ============================================================================
-- 051 — RPC registrar_pago_cliente_fifo
-- ============================================================================
-- Permite registrar un pago de cliente desde la ficha (no asociado a un pedido
-- particular) y distribuirlo automaticamente sobre los pedidos pendientes mas
-- antiguos primero (FIFO). El sobrante (si lo hay) queda como saldo a favor:
-- una fila en pagos con pedido_id = NULL.
--
-- RBAC: solo admin o encargado. Encargado ademas:
--   - p_fecha debe ser hoy
--   - no puede haber rendicion confirmada/resuelta para (fecha, sucursal)
--   (mismo gating que marcar_pagos_masivo, migracion 039).
--
-- Reusa la cascada existente:
--   - trigger AFTER en pagos (migracion 035) recalcula pedidos.monto_pagado
--   - trigger BEFORE en pedidos recalcula estado_pago.
-- Por eso esta RPC solo hace inserts; los totales de pedidos quedan correctos.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.registrar_pago_cliente_fifo(
  p_cliente_id bigint,
  p_monto numeric,
  p_forma_pago text,
  p_fecha date DEFAULT CURRENT_DATE,
  p_referencia text DEFAULT NULL,
  p_notas text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id bigint := current_sucursal_id();
  v_acting_user uuid := auth.uid();
  v_rol text;
  v_restante numeric := p_monto;
  v_aplicar numeric;
  v_pedido record;
  v_pago_id bigint;
  v_pago_ids jsonb := '[]'::jsonb;
  v_aplicaciones jsonb := '[]'::jsonb;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF p_monto IS NULL OR p_monto <= 0 THEN
    RAISE EXCEPTION 'Monto debe ser mayor a 0' USING ERRCODE = '22023';
  END IF;

  IF p_forma_pago IS NULL OR length(trim(p_forma_pago)) = 0 THEN
    RAISE EXCEPTION 'Forma de pago obligatoria' USING ERRCODE = '22023';
  END IF;

  -- RBAC: solo admin o encargado
  SELECT rol INTO v_rol FROM perfiles WHERE id = v_acting_user;
  IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

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

  -- FIFO: pedidos con saldo pendiente, mas antiguos primero
  FOR v_pedido IN
    SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, fecha
    FROM pedidos
    WHERE cliente_id = p_cliente_id
      AND sucursal_id = v_sucursal_id
      AND estado <> 'cancelado'
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
    ORDER BY fecha ASC, id ASC
  LOOP
    EXIT WHEN v_restante <= 0;
    v_aplicar := LEAST(v_restante, v_pedido.total - v_pedido.pagado);

    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      p_cliente_id, v_pedido.id, v_aplicar, p_forma_pago, p_fecha,
      p_referencia, p_notas, v_acting_user, v_sucursal_id
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
    v_aplicaciones := v_aplicaciones || jsonb_build_object(
      'pago_id', v_pago_id,
      'pedido_id', v_pedido.id,
      'pedido_fecha', v_pedido.fecha,
      'monto', v_aplicar
    );

    v_restante := v_restante - v_aplicar;
  END LOOP;

  -- Sobrante: queda como saldo a favor (pedido_id NULL)
  IF v_restante > 0 THEN
    INSERT INTO pagos (
      cliente_id, pedido_id, monto, forma_pago, fecha,
      referencia, notas, usuario_id, sucursal_id
    )
    VALUES (
      p_cliente_id, NULL, v_restante, p_forma_pago, p_fecha,
      p_referencia,
      COALESCE(NULLIF(p_notas, '') || ' ', '') || '[saldo a favor]',
      v_acting_user, v_sucursal_id
    )
    RETURNING id INTO v_pago_id;

    v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
    v_aplicaciones := v_aplicaciones || jsonb_build_object(
      'pago_id', v_pago_id,
      'pedido_id', NULL,
      'monto', v_restante,
      'saldo_a_favor', true
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'monto_total', p_monto,
    'sobrante', v_restante,
    'pago_ids', v_pago_ids,
    'aplicaciones', v_aplicaciones
  );
END;
$$;

ALTER FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text) OWNER TO postgres;

COMMENT ON FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text) IS
  'Registra un pago de cliente y lo distribuye automaticamente sobre los pedidos mas antiguos con saldo pendiente. Sobrante queda como saldo a favor (pedido_id NULL). Solo admin o encargado. Encargado: solo fecha=hoy, sin rendicion cerrada.';

GRANT EXECUTE ON FUNCTION public.registrar_pago_cliente_fifo(bigint, numeric, text, date, text, text)
  TO authenticated, service_role;

COMMIT;
