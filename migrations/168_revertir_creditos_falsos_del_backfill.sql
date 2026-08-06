-- 168_revertir_creditos_falsos_del_backfill.sql
--
-- La mig 166 saco el excedente de las 8 boletas sobrepagadas y lo convirtio en saldo
-- a favor (pagos 4156..4163). Esa segunda mitad estaba mal: ese credito nunca existio
-- (ver el detalle de la evidencia en la mig 167). Los clientes no tenian plata a favor;
-- las boletas estaban cobradas de mas.
--
-- La primera mitad de la 166 SI era correcta y se conserva: los pagos ya quedaron
-- reducidos al total real de cada boleta.
--
-- Esta migracion borra solamente las 8 filas de credito inventado. Al borrarlas, los
-- triggers `recalcular_monto_pagado_pedido` y `actualizar_saldo_cliente` recalculan
-- solos el monto_pagado de las boletas y el saldo de cada cliente.
--
-- NO se toca el pago 2306 ($50 de TITA MALDONADO, imputado al pedido 3880): ese es un
-- saldo a favor genuino, generado por el FIFO el 2026-06-15 cuando sobro plata de un
-- pago combinado. Ahi el cliente si entrego la plata.
--
-- Resultado esperado:
--   #799 Despensa Dalma        39.410 -> 47.710  (= pendiente de la boleta 4452)
--   #529 Marina Alfaro         22.350 -> 28.850
--   #24  Los Redonditos       -10.200 ->      0
--   #65  Marcos                -7.000 ->      0
--   #523 Eugenio Mendez       -25.560 ->      0
--   #424 Comercial TP         -33.300 ->      0
--   #439 Refugio Comedor         -500 ->      0
--   #648 Juan Romano           -6.000 ->      0

DO $revert$
DECLARE
  v_borradas  integer;
  v_restantes integer;
BEGIN
  DELETE FROM pagos
   WHERE id BETWEEN 4156 AND 4163
     AND COALESCE(notas, '') NOT LIKE '%[pago combinado]%';

  GET DIAGNOSTICS v_borradas = ROW_COUNT;
  RAISE NOTICE 'creditos falsos borrados: %', v_borradas;

  IF v_borradas <> 8 THEN
    RAISE EXCEPTION 'ABORTA: se esperaban 8 filas a borrar y se borraron %', v_borradas;
  END IF;

  -- Ningun cliente puede quedar con saldo negativo por esta via: si quedo alguno es
  -- que habia credito genuino ademas, y hay que mirarlo a mano.
  SELECT count(*) INTO v_restantes
    FROM clientes
   WHERE id IN (539, 545, 77, 664, 455, 36, 440, 815)
     AND saldo_cuenta < -0.005;

  IF v_restantes > 0 THEN
    RAISE EXCEPTION 'ABORTA: quedaron % clientes con saldo negativo', v_restantes;
  END IF;
END;
$revert$;
