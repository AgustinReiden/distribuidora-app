-- ===========================================================================
-- LIMPIEZA MANUAL — pedido 3602: el mismo pago cargado 3 veces
-- ===========================================================================
--
--   ⚠️  ESTO BORRA PLATA.
--
--   Agustín confirmó el 2026-08-05 que los pagos 3281 y 3282 fueron un error de
--   carga y que hay que borrarlos. Queda pendiente ejecutarlo contra prod.
--
-- Vive en `scripts/` y no en `migrations/` porque es un arreglo puntual de dato:
-- no tiene que aplicarse solo ni entrar en el ledger junto con el resto.
--
-- QUÉ PASÓ
-- El pedido 3602 (cliente 303, "MARCOS CHOFER") tiene el MISMO pago de $111.280
-- insertado 3 veces: `pagos` 3280, 3281 y 3282, el 2026-07-13 a las 22:53:20,
-- 22:53:27 y 22:53:37. Diecisiete segundos, mismo monto, misma forma de pago:
-- es un doble/triple clic sobre el botón de cobrar, no tres cobros reales.
--
-- Eso dejó al cliente con `saldo_cuenta = -222.560`. La migración 166 lo excluyó
-- a propósito del backfill de sobrepagos (ver su sección EXCLUSION): no es
-- crédito real del cliente, así que convertirlo en saldo a favor habría
-- propagado el error a boletas futuras.
--
-- La causa raíz ya está tapada por la migración 167 (idempotencia por
-- `client_request_id`). Esto es sólo el dato viejo.
--
-- QUÉ HACE
-- Borra los pagos 3281 y 3282 y deja el 3280, que es el cobro real. Los triggers
-- `recalcular_monto_pagado_pedido` y `actualizar_saldo_cliente` recalculan solos
-- `pedidos.monto_pagado` y `clientes.saldo_cuenta`; no hay que tocarlos a mano.
--
-- CÓMO USARLO
--   1. Correr el bloque 1 y mirar que los números den lo que dice acá arriba.
--   2. Con el OK de Agustín, correr el bloque 2. Aborta solo si algo no cuadra.
--   3. Correr el bloque 3 para confirmar cómo quedó.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- BLOQUE 1 — VERIFICAR ANTES (sólo lectura, se puede correr siempre)
-- ---------------------------------------------------------------------------

-- 1a. ¿Sigue siendo el único caso de pago duplicado en toda la base?
select pedido_id, cliente_id, monto, forma_pago, fecha, count(*) as veces,
       array_agg(id order by id) as pago_ids,
       max(created_at) - min(created_at) as ventana
  from pagos
 where pedido_id is not null
 group by pedido_id, cliente_id, monto, forma_pago, fecha
having count(*) > 1;

-- 1b. Las 3 filas del pedido 3602, como están hoy.
select id, pedido_id, cliente_id, monto, forma_pago, fecha, created_at, usuario_id
  from pagos
 where pedido_id = 3602
 order by id;

-- 1c. Estado del pedido y del cliente antes de tocar nada.
select p.id as pedido, p.total, p.monto_pagado, p.estado, p.estado_pago,
       c.id as cliente, c.nombre_fantasia, c.saldo_cuenta
  from pedidos p
  join clientes c on c.id = p.cliente_id
 where p.id = 3602;


-- ---------------------------------------------------------------------------
-- BLOQUE 2 — BORRAR (destructivo; sólo con el OK de Agustín)
-- ---------------------------------------------------------------------------
-- Corre entero en una transacción y se aborta solo si el estado no es
-- exactamente el esperado: si alguien ya lo arregló a mano, o los montos no son
-- los que decimos, no borra nada.

DO $limpieza$
DECLARE
  v_saldo_antes   numeric;
  v_saldo_despues numeric;
  v_pagado_antes  numeric;
  v_pagado_despues numeric;
  v_total         numeric;
  v_borradas      integer;
  v_cuantas       integer;
BEGIN
  -- Guarda 1: las dos filas a borrar tienen que existir, ser del pedido 3602 y
  -- valer $111.280 cada una.
  SELECT count(*) INTO v_cuantas
    FROM pagos
   WHERE id IN (3281, 3282)
     AND pedido_id = 3602
     AND monto = 111280;

  IF v_cuantas <> 2 THEN
    RAISE EXCEPTION 'ABORTA: esperaba los pagos 3281 y 3282 (pedido 3602, $111.280 c/u) y encontré % fila(s). Revisá el bloque 1: puede que ya se haya corregido.', v_cuantas;
  END IF;

  -- Guarda 2: el pago que se conserva tiene que seguir ahí.
  IF NOT EXISTS (SELECT 1 FROM pagos WHERE id = 3280 AND pedido_id = 3602 AND monto = 111280) THEN
    RAISE EXCEPTION 'ABORTA: no está el pago 3280, que es el cobro real que hay que conservar.';
  END IF;

  SELECT c.saldo_cuenta, p.monto_pagado, p.total
    INTO v_saldo_antes, v_pagado_antes, v_total
    FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
   WHERE p.id = 3602;

  DELETE FROM pagos WHERE id IN (3281, 3282);
  GET DIAGNOSTICS v_borradas = ROW_COUNT;

  SELECT c.saldo_cuenta, p.monto_pagado
    INTO v_saldo_despues, v_pagado_despues
    FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
   WHERE p.id = 3602;

  RAISE NOTICE 'borradas=% · monto_pagado % -> % (total %) · saldo_cuenta % -> %',
    v_borradas, v_pagado_antes, v_pagado_despues, v_total, v_saldo_antes, v_saldo_despues;

  -- Guarda 3: los triggers tienen que haber devuelto exactamente los $222.560.
  IF abs((v_pagado_antes - v_pagado_despues) - 222560) > 0.005 THEN
    RAISE EXCEPTION 'ABORTA: monto_pagado bajó % en vez de 222560. Los triggers no hicieron lo esperado.',
      v_pagado_antes - v_pagado_despues;
  END IF;

  IF abs((v_saldo_despues - v_saldo_antes) - 222560) > 0.005 THEN
    RAISE EXCEPTION 'ABORTA: saldo_cuenta subió % en vez de 222560.',
      v_saldo_despues - v_saldo_antes;
  END IF;

  -- Guarda 4: el pedido no puede quedar sobrepagado ni de más ni de menos
  -- (invariante de la mig 165).
  IF v_pagado_despues > v_total + 0.005 THEN
    RAISE EXCEPTION 'ABORTA: el pedido 3602 sigue sobrepagado (monto_pagado % > total %).',
      v_pagado_despues, v_total;
  END IF;
END
$limpieza$;


-- ---------------------------------------------------------------------------
-- BLOQUE 3 — VERIFICAR DESPUÉS
-- ---------------------------------------------------------------------------

select p.id as pedido, p.total, p.monto_pagado, p.estado_pago,
       c.id as cliente, c.nombre_fantasia, c.saldo_cuenta
  from pedidos p
  join clientes c on c.id = p.cliente_id
 where p.id = 3602;

-- Tiene que quedar una sola fila (el pago 3280).
select id, monto, forma_pago, fecha from pagos where pedido_id = 3602 order by id;

-- Y no debería quedar ningún pago duplicado en toda la base.
select pedido_id, cliente_id, monto, forma_pago, fecha, count(*) as veces
  from pagos
 where pedido_id is not null
 group by pedido_id, cliente_id, monto, forma_pago, fecha
having count(*) > 1;
