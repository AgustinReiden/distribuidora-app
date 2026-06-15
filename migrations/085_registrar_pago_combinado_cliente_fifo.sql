-- ============================================================================
-- 085 — RPC registrar_pago_combinado_cliente_fifo
-- ============================================================================
-- Variante combinada (pago dividido / multiples formas de pago) de
-- registrar_pago_cliente_fifo (migracion 051).
--
-- Problema que resuelve: el "pago dividido" desde la ficha de cliente se
-- registraba con un loop en el frontend que insertaba filas en pagos con
-- pedido_id = NULL (cuenta general). El trigger recalcular_monto_pagado_pedido
-- (035) ignora filas con pedido_id NULL, asi que el pago no se imputaba a
-- ningun pedido y el saldo_cuenta del cliente nunca bajaba.
--
-- Esta RPC recibe varias formas de pago y, en UNA sola transaccion (atomico),
-- imputa cada una por FIFO sobre los pedidos pendientes mas antiguos. El
-- sobrante de cada metodo queda como saldo a favor (fila con pedido_id NULL).
-- Como cada INSERT dispara el trigger que recalcula pedidos.monto_pagado, el
-- metodo siguiente ya ve el saldo pendiente actualizado.
--
-- RBAC y gating identicos a registrar_pago_cliente_fifo:
--   - solo admin o encargado
--   - encargado: p_fecha = hoy y sin rendicion cerrada para (fecha, sucursal)
--
-- Reusa la misma cascada de triggers (035 en pagos, estado_pago/saldo en
-- pedidos), por eso solo hace inserts.
--
-- p_metodos: jsonb array, p.ej.
--   [{"monto": 98600, "forma_pago": "efectivo"},
--    {"monto": 25000, "forma_pago": "transferencia"}]
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.registrar_pago_combinado_cliente_fifo(
  p_cliente_id bigint,
  p_metodos jsonb,
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
  v_metodo jsonb;
  v_forma text;
  v_monto numeric;
  v_restante numeric;
  v_aplicar numeric;
  v_pedido record;
  v_pago_id bigint;
  v_pago_ids jsonb := '[]'::jsonb;
  v_aplicaciones jsonb := '[]'::jsonb;
  v_monto_total numeric := 0;
  v_sobrante_total numeric := 0;
  v_notas_imputado text;
BEGIN
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  -- p_metodos debe ser un array no vacio
  IF p_metodos IS NULL OR jsonb_typeof(p_metodos) <> 'array' OR jsonb_array_length(p_metodos) = 0 THEN
    RAISE EXCEPTION 'Debe enviar al menos una forma de pago' USING ERRCODE = '22023';
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

  -- Validar cada metodo y acumular el total
  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    v_monto := NULLIF(v_metodo->>'monto', '')::numeric;
    v_forma := v_metodo->>'forma_pago';
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'Cada forma de pago debe tener un monto mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF v_forma IS NULL OR length(trim(v_forma)) = 0 THEN
      RAISE EXCEPTION 'Forma de pago obligatoria' USING ERRCODE = '22023';
    END IF;
    v_monto_total := v_monto_total + v_monto;
  END LOOP;

  -- Nota base para filas imputadas: marca el pago como combinado (reportes/rendicion)
  v_notas_imputado := NULLIF(trim(COALESCE(p_notas, '') || ' [pago combinado]'), '');

  -- Imputacion FIFO por metodo, secuencial dentro de la misma transaccion.
  FOR v_metodo IN SELECT * FROM jsonb_array_elements(p_metodos) LOOP
    v_monto := (v_metodo->>'monto')::numeric;
    v_forma := trim(v_metodo->>'forma_pago');
    v_restante := v_monto;

    -- FIFO: pedidos con saldo pendiente, mas antiguos primero.
    -- Se re-consulta por metodo para ver el monto_pagado actualizado por el
    -- metodo anterior (trigger 035).
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
        p_cliente_id, v_pedido.id, v_aplicar, v_forma, p_fecha,
        p_referencia, v_notas_imputado, v_acting_user, v_sucursal_id
      )
      RETURNING id INTO v_pago_id;

      v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
      v_aplicaciones := v_aplicaciones || jsonb_build_object(
        'pago_id', v_pago_id,
        'pedido_id', v_pedido.id,
        'pedido_fecha', v_pedido.fecha,
        'forma_pago', v_forma,
        'monto', v_aplicar
      );

      v_restante := v_restante - v_aplicar;
    END LOOP;

    -- Sobrante de este metodo: queda como saldo a favor (pedido_id NULL)
    IF v_restante > 0 THEN
      INSERT INTO pagos (
        cliente_id, pedido_id, monto, forma_pago, fecha,
        referencia, notas, usuario_id, sucursal_id
      )
      VALUES (
        p_cliente_id, NULL, v_restante, v_forma, p_fecha,
        p_referencia,
        trim(COALESCE(p_notas, '') || ' [pago combinado] [saldo a favor]'),
        v_acting_user, v_sucursal_id
      )
      RETURNING id INTO v_pago_id;

      v_pago_ids := v_pago_ids || to_jsonb(v_pago_id);
      v_aplicaciones := v_aplicaciones || jsonb_build_object(
        'pago_id', v_pago_id,
        'pedido_id', NULL,
        'forma_pago', v_forma,
        'monto', v_restante,
        'saldo_a_favor', true
      );

      v_sobrante_total := v_sobrante_total + v_restante;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'monto_total', v_monto_total,
    'sobrante', v_sobrante_total,
    'pago_ids', v_pago_ids,
    'aplicaciones', v_aplicaciones
  );
END;
$$;

ALTER FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text) OWNER TO postgres;

COMMENT ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text) IS
  'Pago combinado (varias formas de pago) desde ficha de cliente. Imputa cada forma por FIFO sobre los pedidos mas antiguos con saldo pendiente, en una sola transaccion. Sobrante por metodo queda como saldo a favor (pedido_id NULL). Mismo RBAC que registrar_pago_cliente_fifo.';

GRANT EXECUTE ON FUNCTION public.registrar_pago_combinado_cliente_fifo(bigint, jsonb, date, text, text)
  TO authenticated, service_role;

COMMIT;
