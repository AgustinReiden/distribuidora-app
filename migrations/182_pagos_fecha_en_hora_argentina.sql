-- =========================================================================
-- 182_pagos_fecha_en_hora_argentina.sql
--
-- `pagos.fecha` cae en `CURRENT_DATE` cuando el caller no manda fecha, y la
-- base corre en UTC (`current_setting('TimeZone')` = 'UTC') mientras la
-- operacion es UTC-3. Entre las 21:00 y las 24:00 hora argentina, ese default
-- devuelve la fecha de MAÑANA: el cobro aterriza en la caja del dia siguiente
-- y descuadra los dos dias — el de la cobranza real, que queda corto, y el
-- siguiente, que aparece inflado.
--
-- POR QUE AHORA, SI NO HAY NINGUN CASO EN PRODUCCION
-- ---------------------------------------------------
-- Justamente: hay 0 casos sobre 589 pagos registrados despues de las 21:00.
-- No esta sangrando, y no se arregla nada del pasado. Se cierra porque es la
-- ULTIMA via sin guardia: hoy no dispara solo porque todos los callers vivos
-- pasan `fecha` explicita (`ModalRegistrarPago`, `ejecutarCreacionPedido`, las
-- RPC masivas). El dia que alguien agregue un camino que la omita —y omitirla
-- es lo natural, porque "es hoy"— el bug entra en silencio y se descubre en
-- una rendicion que no cierra.
--
-- ALCANCE: SOLO `pagos`
-- ----------------------
-- El mismo `CURRENT_DATE` esta en otras 7 columnas date. Se dejan afuera a
-- proposito:
--
--  · `pedidos.fecha` — YA resuelto donde importa. `crear_pedido_completo` hace
--    `COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)`.
--    Hay 116 pedidos con la firma del bug, pero el ultimo es del 2026-05-27 y
--    van 0 en los ultimos 60 dias: es una cohorte historica ya cerrada.
--
--  · `recorridos.fecha` — ambiguo, NO tocar a ciegas. Una ruta se arma HOY para
--    entregar MAÑANA, asi que "fecha = mañana" muchas veces es lo correcto y no
--    un corrimiento. Ademas `aplicar_orden_ruta` (el camino vivo) siempre manda
--    `p_fecha` explicita. Quedan 2 casos por revisar aparte, probablemente de
--    `crear_recorrido`, que si usa CURRENT_DATE.
--
--  · `compras`, `notas_credito`, `comision_reglas`, `rendiciones`,
--    `transferencias_stock` — fuera del alcance de esta auditoria.
--
-- Cambiar el default NO reescribe ninguna fila existente.
-- =========================================================================

ALTER TABLE public.pagos
  ALTER COLUMN fecha
  SET DEFAULT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;

COMMENT ON COLUMN public.pagos.fecha IS
  'Fecha contable del cobro. Default en hora argentina, NO CURRENT_DATE: la base '
  'corre en UTC y despues de las 21:00 ART ese default fechaba el pago al dia '
  'siguiente, mandandolo a la caja equivocada (mig 182).';
