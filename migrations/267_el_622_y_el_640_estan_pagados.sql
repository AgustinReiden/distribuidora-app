-- El 622 y el 640 estan pagados (#812)
--
-- En la regularizacion de pagos del 05/05 se cargaron 22 pedidos de una vez. En
-- 20 el pago es igual al total; en los dos que tenian nota se cargo la cifra de
-- la NOTA como si fuera lo cobrado:
--   622  nota "se pago el pedido entero"          -> se cargo $2.250 (la diferencia)
--   640  nota "le mando por mensaje que debe $10.000" -> se cargo $10.000
-- Confirmado por el dueño (26/09): los dos estan pagados enteros y los clientes
-- no deben nada de esos pedidos. Para el 640 eso contradice la nota, que era
-- de abril; manda la confirmacion, no la nota.
--
-- Se corrige el monto de los pagos EXISTENTES (856 y 857) y no se carga uno
-- nuevo: el cobro ya estaba registrado con su fecha (11/04); lo que estaba mal
-- era el monto. Un pago nuevo nacería con fecha de hoy y metería $104.320 en la
-- caja del 26/09. La sucursal no tiene cajas cerradas, asi que el guard de
-- fecha cerrada no se opone -- y si alguna vez la tuviera, esto fallaria en
-- vez de pasarla por arriba.
--
-- Los triggers de pagos recalculan monto_pagado -> estado_pago -> saldo.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pagos WHERE id = 856 AND pedido_id = 622 AND monto = 2250)
     OR NOT EXISTS (SELECT 1 FROM pagos WHERE id = 857 AND pedido_id = 640 AND monto = 10000)
     OR (SELECT count(*) FROM pagos WHERE pedido_id IN (622, 640)) <> 2
     OR NOT EXISTS (SELECT 1 FROM pedidos WHERE id = 622 AND total = 6970)
     OR NOT EXISTS (SELECT 1 FROM pedidos WHERE id = 640 AND total = 109600) THEN
    RAISE EXCEPTION 'Los pedidos 622/640 o sus pagos ya no estan como se los encontro; revisar a mano.';
  END IF;
END $$;

UPDATE pagos p
SET monto = pe.total,
    notas = concat_ws(E'\n', NULLIF(p.notas, ''),
      format('[mig 267, #812] monto corregido de %s a %s: en la regularizacion del 05/05 se cargo la cifra de la nota del pedido en vez de lo cobrado.',
             p.monto, pe.total))
FROM pedidos pe
WHERE pe.id = p.pedido_id AND p.id IN (856, 857);

DO $$
DECLARE v_malos text;
BEGIN
  SELECT string_agg(id::text, ', ') INTO v_malos
  FROM pedidos
  WHERE id IN (622, 640) AND (estado_pago <> 'pagado' OR monto_pagado <> total);
  IF v_malos IS NOT NULL THEN
    RAISE EXCEPTION 'No quedaron pagados: %', v_malos;
  END IF;

  SELECT string_agg(c.id::text, ', ') INTO v_malos
  FROM clientes c
  WHERE c.id IN (SELECT cliente_id FROM pedidos WHERE id IN (622, 640))
    AND c.saldo_cuenta <>
      COALESCE((SELECT SUM(p.total - COALESCE(p.monto_pagado, 0)) FROM pedidos p
                WHERE p.cliente_id = c.id AND p.estado NOT IN ('cancelado', 'anulado')), 0)
      - COALESCE((SELECT SUM(pg.monto) FROM pagos pg
                  WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL), 0);
  IF v_malos IS NOT NULL THEN
    RAISE EXCEPTION 'saldo_cuenta no cierra con la formula canonica en clientes: %', v_malos;
  END IF;
END $$;

COMMIT;
