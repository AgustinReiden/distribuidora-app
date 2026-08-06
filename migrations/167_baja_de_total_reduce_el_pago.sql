-- 167_baja_de_total_reduce_el_pago.sql
--
-- CORRIGE LA POLITICA DE LA MIG 165.
--
-- La 165 asumia que si una boleta quedaba con monto_pagado > total, el cliente
-- habia pagado de mas y le quedaba credito a favor. Es falso para esta operacion.
--
-- Evidencia (los 8 casos historicos, reconstruidos desde audit_logs):
--
--   pedido | pago registrado | total previo a la baja
--   -------|-----------------|-----------------------
--    1142  |      46.360     |      46.360
--    1148  |      23.400     |      23.400
--    1656  |      60.000     |      60.000
--    1821  |      31.100     |      31.100
--    2083  |      21.500     |      21.500
--    3053  |      16.900     |      16.900
--    3251  |     628.300     |     628.300
--    3329  |      21.700     |      21.700
--
-- 8 de 8: el pago era EXACTAMENTE el total previo. Eso no es que el cliente
-- pagara de mas; es que se cobro la boleta por el total del pedido y despues se
-- bajo el total. Cuando el cliente rechaza mercaderia no la paga, simplemente
-- entrega menos. El pago quedo inflado por la diferencia.
--
-- Politica nueva: bajar el total de una boleta ya cobrada REDUCE el pago, no
-- genera credito. La plata que si entra de mas sigue generando saldo a favor por
-- el otro camino (`registrar_pago_cliente_fifo`, cuando sobra despues de cubrir
-- todas las boletas), que es un saldo a favor genuino y no se toca.
--
-- OJO — esto SI mueve la caja del dia, a diferencia de una reimputacion: si el
-- chofer nunca trajo esa plata, la rendicion de ese dia estaba inflada. Por eso
-- esta funcion, a diferencia de `aplicar_credito_cliente`, NO usa el escape del
-- guard de caja cerrada: si el dia ya fue rendido y cerrado, la operacion se
-- bloquea y hay que reabrir la rendicion. El UPDATE del monto va siempre primero
-- (aunque deje la fila en cero) justamente para que el guard corra.

CREATE OR REPLACE FUNCTION public.desafectar_sobrepago_pedido(p_pedido_id bigint)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_pedido     RECORD;
  v_pago       RECORD;
  v_excedente  numeric;
  v_quitar     numeric;
  v_quitado    numeric := 0;
BEGIN
  SELECT id, total, COALESCE(monto_pagado, 0) AS pagado, estado
    INTO v_pedido
    FROM pedidos
   WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  IF v_pedido.estado IN ('cancelado', 'anulado') THEN
    RETURN 0;
  END IF;

  v_excedente := v_pedido.pagado - v_pedido.total;
  IF v_excedente <= 0.005 THEN
    RETURN 0;
  END IF;

  -- Se recorta desde el pago mas nuevo: el excedente es lo ultimo que se cargo.
  FOR v_pago IN
    SELECT id, monto
      FROM pagos
     WHERE pedido_id = p_pedido_id
     ORDER BY fecha DESC, id DESC
  LOOP
    EXIT WHEN v_excedente <= 0.005;

    v_quitar := LEAST(v_pago.monto, v_excedente);

    -- Siempre pasa por el UPDATE de monto (aunque quede en cero) para que corra
    -- `guard_pago_fecha_cerrada`. Un DELETE directo no lo dispara y dejaria
    -- modificar en silencio una rendicion ya cerrada.
    UPDATE pagos
       SET monto = monto - v_quitar,
           notas = trim(COALESCE(notas, '') ||
                        ' [ajustado -' || trim(to_char(v_quitar, 'FM999999990.00')) ||
                        ' por baja de total del pedido ' || p_pedido_id || ']')
     WHERE id = v_pago.id;

    DELETE FROM pagos WHERE id = v_pago.id AND monto <= 0.005;

    v_excedente := v_excedente - v_quitar;
    v_quitado   := v_quitado + v_quitar;
  END LOOP;

  RETURN v_quitado;
END;
$function$;

REVOKE ALL ON FUNCTION public.desafectar_sobrepago_pedido(bigint) FROM PUBLIC, anon, authenticated;

-- `aplicar_credito_cliente` NO cambia: consumir saldo a favor genuino contra las
-- boletas pendientes sigue siendo correcto, y ahi el escape del guard si aplica
-- porque reimputar preserva fecha, forma de pago y monto total del dia.
