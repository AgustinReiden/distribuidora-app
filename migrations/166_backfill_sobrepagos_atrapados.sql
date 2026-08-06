-- 166_backfill_sobrepagos_atrapados.sql
--
-- Corrige los sobrepagos historicos que quedaron enterrados en boletas cerradas
-- antes de la mig 165 (ver ahi el detalle del problema y del invariante).
--
-- Al 2026-08-05 habia 9 pedidos con monto_pagado > total, por $319.920. En todos
-- el patron es el mismo: se cobro la boleta completa y DESPUES se bajo el total,
-- por salvedad (1142, 1148, 1656, 3053, 3329) o por edicion manual (1821, 2083, 3251).
--
-- Que hace: saca el excedente de cada boleta a saldo a favor y lo imputa a las
-- boletas que el cliente todavia debe (FIFO). No mueve `saldo_cuenta` de nadie
-- ni crea o destruye plata: el credito ya estaba contabilizado en la ficha via
-- (total - monto_pagado) negativo, solo cambia donde vive.
--
-- EXCLUSION: el pedido 3602 (cliente 303 "MARCOS CHOFER", $222.560) NO entra. Ahi
-- no hubo salvedad: tiene el MISMO pago de $111.280 insertado 3 veces con 7 y 10
-- segundos de diferencia (pagos 3280/3281/3282, 2026-07-13) — un doble/triple clic
-- en el boton de cobrar, no un credito real del cliente. Convertirlo en saldo a
-- favor propagaria el error a boletas futuras. Requiere decision humana: si se
-- confirma que fue un error de carga, se borran los pagos 3281 y 3282.

DO $backfill$
DECLARE
  v_pedido            RECORD;
  v_cliente           RECORD;
  v_saldo_antes       numeric;
  v_saldo_despues     numeric;
  v_plata_antes       numeric;
  v_plata_despues     numeric;
  v_desafectado       numeric := 0;
  v_aplicado          numeric := 0;
  v_restantes         integer;
BEGIN
  SELECT COALESCE(SUM(saldo_cuenta), 0) INTO v_saldo_antes FROM clientes;
  SELECT COALESCE(SUM(monto), 0)        INTO v_plata_antes FROM pagos;

  -- 1. Sacar el excedente de cada boleta sobrepagada
  FOR v_pedido IN
    SELECT id, cliente_id, sucursal_id, (monto_pagado - total) AS excedente
      FROM pedidos
     WHERE estado NOT IN ('cancelado', 'anulado')
       AND monto_pagado > total + 0.005
       AND id <> 3602            -- ver EXCLUSION arriba
     ORDER BY id
  LOOP
    v_desafectado := v_desafectado + public.desafectar_sobrepago_pedido(v_pedido.id);
    RAISE NOTICE 'pedido % (cliente %): desafectados %',
      v_pedido.id, v_pedido.cliente_id, v_pedido.excedente;
  END LOOP;

  -- 2. Imputar el credito liberado a lo que cada cliente todavia debe
  FOR v_cliente IN
    SELECT DISTINCT cliente_id, sucursal_id
      FROM pagos
     WHERE pedido_id IS NULL
     ORDER BY cliente_id
  LOOP
    v_aplicado := v_aplicado + public.aplicar_credito_cliente(v_cliente.cliente_id, v_cliente.sucursal_id);
  END LOOP;

  SELECT COALESCE(SUM(saldo_cuenta), 0) INTO v_saldo_despues FROM clientes;
  SELECT COALESCE(SUM(monto), 0)        INTO v_plata_despues FROM pagos;

  SELECT count(*) INTO v_restantes
    FROM pedidos
   WHERE estado NOT IN ('cancelado', 'anulado')
     AND monto_pagado > total + 0.005
     AND id <> 3602;

  RAISE NOTICE 'desafectado=% aplicado=% saldo %->% plata %->%',
    v_desafectado, v_aplicado, v_saldo_antes, v_saldo_despues, v_plata_antes, v_plata_despues;

  -- Guardas: si alguna no se cumple, la migracion aborta y no queda aplicada a medias.
  IF abs(v_saldo_despues - v_saldo_antes) > 0.005 THEN
    RAISE EXCEPTION 'ABORTA: el saldo total de clientes cambio (% -> %). El backfill solo debe mover donde vive el credito, no cuanto es.',
      v_saldo_antes, v_saldo_despues;
  END IF;

  IF abs(v_plata_despues - v_plata_antes) > 0.005 THEN
    RAISE EXCEPTION 'ABORTA: el total de pagos cambio (% -> %). No se debe crear ni destruir plata.',
      v_plata_antes, v_plata_despues;
  END IF;

  IF v_restantes > 0 THEN
    RAISE EXCEPTION 'ABORTA: quedaron % pedidos con monto_pagado > total', v_restantes;
  END IF;
END;
$backfill$;
