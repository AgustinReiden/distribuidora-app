-- El total del pedido lo dice el servidor, y cancelar deja todo en cero
--
-- Tres agujeros del alta y la baja de un pedido, que comparten una misma forma:
-- el servidor le cree al caller un numero que puede calcular solo.
--
-- 1 · EL TOTAL VENIA DEL CLIENTE Y NADIE LO MIRABA
--
--    `crear_pedido_completo` (cuerpo vivo: mig 132 + los parches por ancla de
--    205/214/216) insertaba `p_total` tal cual en `pedidos.total` y en
--    `total_real`. Al cierre recalculaba `total_neto`, `total_iva` y
--    `total_real` desde los items, pero `total` nunca se comparaba contra
--    SUM(cantidad x precio_unitario). Un caller que manda items por $80.000 y
--    `p_total = 1` descontaba el stock de verdad, salteaba la compra minima
--    (mig 205, que valida sobre ese mismo p_total sin verificar) y le dejaba al
--    cliente una deuda de $1. VENTA-A lo veia recien en el gate del dia
--    siguiente, con la mercaderia ya en la calle.
--
--    Se compara, no se pisa: `p_total` sigue siendo el contrato y sigue siendo
--    lo que se inserta. Si no coincide con la suma de los items por mas de un
--    centavo -- la misma tolerancia que usa VENTA-A para el redondeo -- el
--    pedido no se crea y la respuesta dice los dos numeros. Y la compra minima
--    pasa a evaluarse contra el total CALCULADO: contra el declarado, el mismo
--    `p_total = 1` la salteaba.
--
--    Mismo tratamiento en `crear_pedido_completo_bot`, con `v_pendiente.total`
--    contra `v_pendiente.items` y su contrato de error (`error` string, no
--    `errores` array).
--
-- 2 · LA IDEMPOTENCIA DEL REPLAY OFFLINE NO SE SERIALIZABA
--
--    `crear_pedido_idempotente` (mig 071) buscaba el `offline_id` sin lock y lo
--    sellaba DESPUES de crear el pedido. Dos llamadas solapadas con la misma
--    clave -- el reintento del PWA cuando vuelve la senal es exactamente eso --
--    pasaban las dos por el lookup vacio: la segunda creaba el pedido entero
--    (stock descontado, promos consumidas) y moria con 23505 contra
--    `uq_pedidos_offline_id` al sellar. PostgREST lo devuelve como 409 y el
--    front no lo reintenta: el usuario veia un error crudo por un pedido que si
--    se habia creado.
--
--    `pg_advisory_xact_lock(hashtextextended(p_offline_id, 0))` al principio,
--    releer, recien entonces crear. Es el mismo molde de `pago_solicitud_abrir`
--    (mig 230) para el mismo problema, con la misma funcion de hash.
--
--    El lookup ademas no filtraba por sucursal: un replay hecho con la sesion
--    parada en otra sucursal recibia el `pedido_id` de la primera. Ahora el hit
--    idempotente solo cuenta si la fila es de la sucursal activa. El lookup en
--    si sigue leyendo global a proposito, porque `uq_pedidos_offline_id` ES
--    global (indice parcial sobre `offline_id`, sin `sucursal_id`): si se
--    filtrara de verdad, el caso cruzado volveria a terminar en 23505 despues
--    de haber descontado el stock, que es justo lo que esta migracion viene a
--    sacar. Se corta antes y se dice por que.
--
--    Y `p_offline_id` nulo apagaba la idempotencia en silencio. Sigue siendo
--    legal -- el front lo manda asi cuando no hay clave de alta -- pero ahora
--    queda un RAISE LOG. Un alta sin red de idempotencia tiene que poder
--    buscarse en el log del dia que aparezca un duplicado.
--
-- 3 · CANCELAR DEJABA TRES COSAS COLGADAS
--
--    `cancelar_pedido_con_stock` (mig 175), las tres verificadas en prod hoy:
--
--    (a) No llamaba a `revertir_bloques_auto_ajuste`: hacia
--        `GREATEST(usos_pendientes - cantidad, 0)` a mano. El clamp se come el
--        negativo, asi que el fardo que se mermo al completarse un bloque no
--        volvia nunca. Los otros tres caminos que devuelven regalos --
--        `actualizar_pedido_items`, `eliminar_pedido_completo`,
--        `registrar_salvedad` -- ya la llamaban. En prod: 79 pedidos cancelados
--        con 396 unidades de regalo en promos con auto-ajuste.
--
--    (b) Ponia `monto_pagado = 0` sin tocar `pagos`. El pago quedaba imputado a
--        un pedido cancelado: no reducia ninguna boleta viva ni quedaba como
--        saldo a favor. La plata desaparecia de la cuenta corriente del cliente
--        sin que nada fallara. Ahora se desimputa (`pedido_id = NULL`), que es
--        la representacion de saldo a favor que ya usan
--        `registrar_pago_cliente_fifo_impl` y `aplicar_credito_cliente`, y la
--        que CC-A cuenta como credito.
--
--        EXCEPCION, y por eso el GUC: `cambiar_cliente_pedido` cancela el
--        pedido viejo y despues hace `UPDATE pagos SET pedido_id = <nuevo>`
--        para que el cobro viaje con la venta. Si la cancelacion desimputara
--        primero, ese UPDATE no encontraria nada y el cobro quedaria como
--        credito del cliente EQUIVOCADO mientras el pedido nuevo figura impago.
--        `app.cancelacion_conserva_pagos` es el mismo escape hatch por
--        transaccion que `app.omitir_minimo_pedido` (205) y
--        `app.omitir_minimo_venta` (174), por el mismo motivo: un cambio de
--        cliente es una correccion administrativa, no una cancelacion.
--
--        Nota sobre caja cerrada: el guard `guard_pago_fecha_cerrada` es
--        BEFORE UPDATE **OF fecha, monto**, y la desimputacion no toca ninguna
--        de las dos. Es lo correcto: el monto, la fecha y la forma de pago no
--        cambian, asi que la caja de ese dia cierra por el mismo numero. Lo
--        unico que cambia es a que boleta se imputa.
--
--    (c) Cereaba `total`, `total_neto` y `total_iva` pero no `total_real`. En
--        prod: 113 pedidos cancelados con `total_real <> 0`, hasta $198.800, y
--        197 con `total_neto <> 0`. `total_real` es la base del margen y del
--        CMV: una venta cancelada que sigue declarando ingreso real infla el
--        reporte gerencial. Se agrega al UPDATE, se extiende VENTA-I a las tres
--        columnas y se backfillean las filas viejas.
--
--        Los 4 pedidos de abril con `total <> 0` que VENTA-I ya documenta
--        quedan como estan: son anteriores al camino actual de cancelacion y
--        tocarles el total reescribiria la facturacion de abril. Se les cerea
--        neto/iva/real como a todos, asi que VENTA-I sigue dando exactamente
--        esos 4 y no uno mas.
--
-- COMO SE PARCHEA
-- ---------------
-- Los cuerpos grandes (14k, 12k, 4.5k) pudieron driftar, asi que NO se copian
-- del archivo: se leen del catalogo vivo con `pg_get_functiondef` y se les
-- reemplaza un bloque que tiene que aparecer EXACTAMENTE UNA VEZ (patron de las
-- migs 176/191/193/195/205). `crear_pedido_idempotente` es chica y se reescribe
-- entera.

BEGIN;

-- ---------------------------------------------------------------------------
-- Helper de parcheo: reemplaza un bloque que debe aparecer 1 sola vez.
-- Molde de `_mig205_insertar_tras_ancla`, con reemplazo en vez de insercion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig235_reemplazar(
  p_funcion regprocedure,
  p_viejo   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_viejo, ''))) / length(p_viejo);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;

  v_def := replace(v_def, p_viejo, p_nuevo);
  EXECUTE v_def;
END;
$fn$;

-- ===========================================================================
-- 1 · crear_pedido_completo  --  el total lo calcula el servidor
--     Contesta con `errores` (array de textos).
-- ===========================================================================
DO $patch$
DECLARE
  v_viejo text;
  v_nuevo text;
BEGIN
  v_viejo := $viejo$  -- Compra minima de la sucursal (mig 204/205). Va aca, antes de tocar stock
  -- o promociones, para que un pedido que no llega no deje nada a medias.
  DECLARE v_motivo_minimo TEXT;
  BEGIN
    v_motivo_minimo := public.pedido_incumple_minimo(p_total, v_sucursal);
    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(v_motivo_minimo));
    END IF;
  END;$viejo$;

  v_nuevo := $nuevo$  -- El total lo calcula el servidor (mig 235). Antes se insertaba p_total tal
  -- cual y nadie lo comparaba con los items: items por $80.000 con p_total = 1
  -- descontaban el stock de verdad, salteaban la compra minima y dejaban al
  -- cliente debiendo $1. Se compara, no se pisa -- el contrato de p_total no
  -- cambia -- y la tolerancia de un centavo es la misma de VENTA-A.
  DECLARE
    v_total_calc    NUMERIC;
    v_motivo_minimo TEXT;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::INT * (e->>'precio_unitario')::NUMERIC), 0)
      INTO v_total_calc
      FROM jsonb_array_elements(p_items) e;

    IF abs(COALESCE(p_total, 0) - v_total_calc) > 0.01 THEN
      RETURN jsonb_build_object(
        'success', false,
        'errores', jsonb_build_array(format(
          'El total enviado (%s) no coincide con la suma de los items (%s). El pedido no se creo.',
          to_char(COALESCE(p_total, 0), 'FM$999G999G999D00'),
          to_char(v_total_calc, 'FM$999G999G999D00'))),
        'total_enviado',   COALESCE(p_total, 0),
        'total_calculado', v_total_calc);
    END IF;

    -- Compra minima de la sucursal (mig 204/205). Va aca, antes de tocar stock
    -- o promociones, para que un pedido que no llega no deje nada a medias.
    -- Contra el total CALCULADO: contra el declarado, el mismo p_total = 1 la
    -- salteaba.
    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_sucursal);
    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(v_motivo_minimo));
    END IF;
  END;$nuevo$;

  PERFORM public._mig235_reemplazar(
    'public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid)'::regprocedure,
    v_viejo, v_nuevo);
END
$patch$;

-- ===========================================================================
-- 2 · crear_pedido_completo_bot  --  lo mismo, con su contrato de error
--     El total y los items vienen de `bot_pedidos_pendientes`, ya bloqueada
--     con FOR UPDATE mas arriba. Contesta con `error` (string).
-- ===========================================================================
DO $patch$
DECLARE
  v_viejo text;
  v_nuevo text;
BEGIN
  v_viejo := $viejo$  -- Compra minima de la sucursal (mig 204/205). previsualizar_pedido ya avisa
  -- antes de que el preventista confirme; esto es la red de abajo, para que
  -- la regla valga aunque se llegue por otro lado.
  DECLARE v_motivo_minimo TEXT;
  BEGIN
    v_motivo_minimo := public.pedido_incumple_minimo(v_pendiente.total, v_pendiente.sucursal_id);
    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error', v_motivo_minimo);
    END IF;
  END;$viejo$;

  v_nuevo := $nuevo$  -- El total lo calcula el servidor (mig 235), igual que en
  -- crear_pedido_completo. Aca la confirmacion pendiente la escribe el bot, no
  -- el telefono, pero el pedido se crea desde lo que quedo guardado en la fila:
  -- si `total` e `items` se fueron por caminos distintos, el que manda es la
  -- suma de los items.
  DECLARE
    v_total_calc    NUMERIC;
    v_motivo_minimo TEXT;
  BEGIN
    SELECT COALESCE(SUM((e->>'cantidad')::INT * (e->>'precio_unitario')::NUMERIC), 0)
      INTO v_total_calc
      FROM jsonb_array_elements(v_pendiente.items) e;

    IF abs(COALESCE(v_pendiente.total, 0) - v_total_calc) > 0.01 THEN
      RETURN jsonb_build_object('success', false, 'error', format(
        'El total de la confirmacion (%s) no coincide con la suma de los items (%s). El pedido no se creo.',
        to_char(COALESCE(v_pendiente.total, 0), 'FM$999G999G999D00'),
        to_char(v_total_calc, 'FM$999G999G999D00')));
    END IF;

    -- Compra minima de la sucursal (mig 204/205). previsualizar_pedido ya avisa
    -- antes de que el preventista confirme; esto es la red de abajo, para que
    -- la regla valga aunque se llegue por otro lado.
    v_motivo_minimo := public.pedido_incumple_minimo(v_total_calc, v_pendiente.sucursal_id);
    IF v_motivo_minimo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'error', v_motivo_minimo);
    END IF;
  END;$nuevo$;

  PERFORM public._mig235_reemplazar(
    'public.crear_pedido_completo_bot(uuid, uuid)'::regprocedure,
    v_viejo, v_nuevo);
END
$patch$;

-- ===========================================================================
-- 3 · crear_pedido_idempotente  --  el lock antes del lookup
--     Es chica (1.4k) y se conoce entera: se reescribe en vez de parchearse.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.crear_pedido_idempotente(
  p_cliente_id                bigint,
  p_total                     numeric,
  p_usuario_id                uuid,
  p_items                     jsonb,
  p_notas                     text    DEFAULT NULL::text,
  p_forma_pago                text    DEFAULT 'efectivo'::text,
  p_estado_pago               text    DEFAULT 'pendiente'::text,
  p_fecha                     date    DEFAULT NULL::date,
  p_tipo_factura              text    DEFAULT 'ZZ'::text,
  p_total_neto                numeric DEFAULT NULL::numeric,
  p_total_iva                 numeric DEFAULT 0,
  p_fecha_entrega_programada  date    DEFAULT NULL::date,
  p_preventista_id            uuid    DEFAULT NULL::uuid,
  p_offline_id                text    DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal          BIGINT := current_sucursal_id();
  v_existing          INT;
  v_existing_sucursal BIGINT;
  v_result            JSONB;
BEGIN
  IF p_offline_id IS NULL THEN
    -- Sigue siendo legal: el front manda null cuando no tiene clave de alta.
    -- Pero deja de ser invisible. Un alta sin red de idempotencia tiene que
    -- poder buscarse en el log el dia que aparezca un duplicado.
    RAISE LOG 'crear_pedido_idempotente sin offline_id (usuario %, cliente %, sucursal %): el alta queda sin proteccion contra reintentos',
      p_usuario_id, p_cliente_id, v_sucursal;
  ELSE
    -- El lock va ANTES del lookup y se suelta al commit. Sin esto, dos llamadas
    -- solapadas con la misma clave --el reintento del PWA cuando vuelve la
    -- senal es exactamente eso-- pasaban las dos por el lookup vacio: la
    -- segunda creaba el pedido entero (stock descontado, promos consumidas) y
    -- moria con 23505 al sellar. Mismo molde que pago_solicitud_abrir (mig
    -- 230), misma funcion de hash.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_offline_id, 0));

    SELECT id, sucursal_id
      INTO v_existing, v_existing_sucursal
      FROM pedidos
     WHERE offline_id = p_offline_id;

    IF v_existing IS NOT NULL THEN
      IF v_existing_sucursal IS NOT DISTINCT FROM v_sucursal THEN
        RETURN jsonb_build_object('success', true, 'pedido_id', v_existing, 'idempotente', true);
      END IF;

      -- Hit de otra sucursal. El lookup lee global a proposito: el indice
      -- uq_pedidos_offline_id TAMBIEN es global (parcial sobre offline_id, sin
      -- sucursal_id). Si se filtrara de verdad por sucursal, este caso volveria
      -- a crear el pedido y a morir con 23505 al sellar, despues de haber
      -- descontado el stock -- justo lo que esta migracion viene a sacar. Se
      -- corta antes, y no se devuelve el pedido de la otra sucursal.
      RETURN jsonb_build_object(
        'success', false,
        'errores', jsonb_build_array(
          'Ese pedido offline ya se sincronizo en otra sucursal. Cambia de sucursal para verlo.'));
    END IF;
  END IF;

  v_result := public.crear_pedido_completo(
    p_cliente_id, p_total, p_usuario_id, p_items, p_notas, p_forma_pago,
    p_estado_pago, p_fecha, p_tipo_factura, p_total_neto, p_total_iva,
    p_fecha_entrega_programada, p_preventista_id
  );

  IF COALESCE((v_result->>'success')::boolean, false) AND p_offline_id IS NOT NULL THEN
    UPDATE pedidos SET offline_id = p_offline_id
    WHERE id = (v_result->>'pedido_id')::int AND offline_id IS NULL;
  END IF;

  RETURN v_result;
END;
$fn$;

COMMENT ON FUNCTION public.crear_pedido_idempotente(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid, text) IS
  'Envuelve crear_pedido_completo con idempotencia por offline_id. El advisory '
  'lock por transaccion serializa las llamadas con la misma clave: sin el, dos '
  'reintentos solapados creaban el pedido dos veces y el segundo moria con '
  '23505 al sellar. mig 235 (lock y sucursal) sobre mig 071.';

-- ===========================================================================
-- 4 · cancelar_pedido_con_stock  --  (a) el fardo vuelve, (b) el cobro queda
--     como saldo a favor, (c) total_real tambien va a cero.
-- ===========================================================================

-- 4.a · la variable del loop nuevo
DO $patch$
BEGIN
  PERFORM public._mig235_reemplazar(
    'public.cancelar_pedido_con_stock(bigint, text, uuid, text)'::regprocedure,
    $viejo$  v_quitar jsonb;
BEGIN$viejo$,
    $nuevo$  v_quitar jsonb;
  v_promo_rev RECORD;
BEGIN$nuevo$);
END
$patch$;

-- 4.b · el regalo devuelve el fardo, por promocion y no por renglon
DO $patch$
BEGIN
  PERFORM public._mig235_reemplazar(
    'public.cancelar_pedido_con_stock(bigint, text, uuid, text)'::regprocedure,
    $viejo$    IF v_item.es_bonificacion THEN
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
  END LOOP;$viejo$,
    $nuevo$    IF v_item.es_bonificacion THEN
      IF v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad
      WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  -- mig 235: el fardo del regalo vuelve al contenedor. Aca habia un
  -- GREATEST(usos_pendientes - cantidad, 0) a mano, adentro del loop: el clamp
  -- se comia el negativo, asi que el bloque que se mermo al completarse no
  -- volvia NUNCA. Los otros tres caminos que devuelven regalos
  -- --actualizar_pedido_items, eliminar_pedido_completo, registrar_salvedad--
  -- ya llamaban a revertir_bloques_auto_ajuste; este no.
  --
  -- Agrupado por promocion a proposito: dos renglones de la misma promo son un
  -- solo delta y dejan un solo promo_ajustes, no dos.
  --
  -- El helper guarda y restaura los cuatro GUCs de app.stock_* alrededor de su
  -- UPDATE (mig 229), asi que el 'pedido_cancelado' de arriba sigue valiendo
  -- para el resto del cuerpo.
  FOR v_promo_rev IN
    SELECT pi.promocion_id AS promocion_id, SUM(pi.cantidad)::INT AS cantidad
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, false) = true
       AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id
  LOOP
    PERFORM public.revertir_bloques_auto_ajuste(
      v_promo_rev.promocion_id, v_promo_rev.cantidad, v_sucursal,
      v_acting_user, 'Cancelacion pedido #' || p_pedido_id);
  END LOOP;$nuevo$);
END
$patch$;

-- 4.c · el cobro queda como saldo a favor, y total_real tambien va a cero
DO $patch$
BEGIN
  PERFORM public._mig235_reemplazar(
    'public.cancelar_pedido_con_stock(bigint, text, uuid, text)'::regprocedure,
    $viejo$  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      motivo_cancelacion_tipo = COALESCE(p_tipo, motivo_cancelacion_tipo),
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;$viejo$,
    $nuevo$  -- mig 235: el cobro de un pedido cancelado no se evapora, queda como saldo
  -- a favor. Antes esto ponia monto_pagado = 0 y no tocaba `pagos`: el pago
  -- seguia imputado al pedido cancelado, no reducia ninguna boleta viva ni
  -- contaba como credito, y la plata desaparecia de la cuenta corriente del
  -- cliente sin que fallara nada. `pedido_id = NULL` es la representacion de
  -- saldo a favor que ya usan registrar_pago_cliente_fifo_impl y
  -- aplicar_credito_cliente, y la que CC-A cuenta como credito.
  --
  -- Caja cerrada: guard_pago_fecha_cerrada es BEFORE UPDATE OF fecha, monto, y
  -- esto no toca ninguna de las dos. Esta bien que no se dispare -- el monto,
  -- la fecha y la forma de pago no cambian, asi que la caja de ese dia cierra
  -- por el mismo numero. Lo unico que cambia es a que boleta se imputa.
  --
  -- La excepcion es cambiar_cliente_pedido, que cancela el viejo y DESPUES
  -- reapunta los pagos al nuevo para que el cobro viaje con la venta. Si se
  -- desimputara primero, ese UPDATE no encontraria nada y el cobro quedaria de
  -- credito en el cliente equivocado mientras el pedido nuevo figura impago.
  -- Mismo escape hatch por transaccion que app.omitir_minimo_pedido (205).
  IF COALESCE(current_setting('app.cancelacion_conserva_pagos', true), '') <> '1' THEN
    UPDATE pagos
       SET pedido_id = NULL,
           notas = TRIM(BOTH ' ' FROM COALESCE(notas, '') || ' [saldo a favor por cancelacion]')
     WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  END IF;

  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      motivo_cancelacion_tipo = COALESCE(p_tipo, motivo_cancelacion_tipo),
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      -- mig 235: faltaba. total_real es la base del margen y del CMV: una venta
      -- cancelada que sigue declarando ingreso real infla el gerencial.
      total_real = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;$nuevo$);
END
$patch$;

-- ===========================================================================
-- 5 · cambiar_cliente_pedido  --  prende el escape hatch de los pagos
--     Se engancha al lado del que ya le puso la mig 205: mismo criterio, una
--     reatribucion no es una venta nueva ni una cancelacion de verdad.
-- ===========================================================================
DO $patch$
BEGIN
  PERFORM public._mig235_reemplazar(
    (SELECT p.oid::regprocedure FROM pg_proc p
      WHERE p.pronamespace = 'public'::regnamespace
        AND p.proname = 'cambiar_cliente_pedido'),
    $viejo$  PERFORM set_config('app.omitir_minimo_pedido', '1', true);$viejo$,
    $nuevo$  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Y los pagos NO se desimputan al cancelar el viejo: mas abajo se reapuntan
  -- al pedido nuevo, para que el cobro viaje con la venta. Sin esto, la
  -- desimputacion de la mig 235 se los lleva antes y el UPDATE de mas abajo no
  -- encuentra nada: el cobro quedaria de credito en el cliente equivocado y el
  -- pedido nuevo figuraria impago.
  PERFORM set_config('app.cancelacion_conserva_pagos', '1', true);$nuevo$);
END
$patch$;

DROP FUNCTION public._mig235_reemplazar(regprocedure, text, text);

-- ===========================================================================
-- 6 · VENTA-I mira las cuatro columnas, y el backfill de lo viejo
--
-- El invariante decia solo `total = 0`. Por eso los 113 cancelados con
-- total_real <> 0 y los 197 con total_neto <> 0 no lo despertaron nunca.
--
-- Los 4 pedidos de abril con `total <> 0` que la descripcion ya documenta
-- quedan con su total: son anteriores al camino actual de cancelacion y
-- tocarlos reescribiria la facturacion de abril. Se les cerea neto/iva/real
-- como a todos los demas, asi que VENTA-I sigue dando exactamente esos 4.
-- ===========================================================================
UPDATE pedidos
   SET total_neto = 0,
       total_iva  = 0,
       total_real = 0
 WHERE estado = 'cancelado'
   AND (COALESCE(total_neto, 0) <> 0
     OR COALESCE(total_iva, 0)  <> 0
     OR COALESCE(total_real, 0) <> 0);

DO $patch$
DECLARE
  v_def   text;
  v_veces int;
  v_viejo text;
  v_nuevo text;
BEGIN
  v_viejo := $viejo$    ('VENTA-I','low','pedido cancelado debe tener total=0 (4 legacy de abril)',
      (SELECT count(*) FROM pedidos WHERE estado='cancelado' AND total<>0)),$viejo$;

  v_nuevo := $nuevo$    ('VENTA-I','low','pedido cancelado debe tener total, total_neto, total_iva y total_real en 0 (4 legacy de abril, ver mig 235)',
      (SELECT count(*) FROM pedidos WHERE estado='cancelado'
         AND (total<>0 OR COALESCE(total_neto,0)<>0 OR COALESCE(total_iva,0)<>0 OR COALESCE(total_real,0)<>0))),$nuevo$;

  v_def := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);

  v_veces := (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'VENTA-I aparece % veces en auditoria_integridad (se esperaba 1). Revisar a mano.', v_veces;
  END IF;

  EXECUTE replace(v_def, v_viejo, v_nuevo);
END
$patch$;

-- ===========================================================================
-- 7 · ACL
--
-- CREATE OR REPLACE conserva el ACL, asi que esto no cambia nada hoy: esta
-- para que si alguna vez alguien dropea y recrea alguna de estas, no nazca
-- ejecutable por PUBLIC ni por anon (ver CLAUDE.md, y el gate
-- scripts/check-permisos.mjs). `crear_pedido_completo_bot` es del bot y no la
-- toca `authenticated`.
-- ===========================================================================
REVOKE ALL ON FUNCTION public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_pedido_completo(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.crear_pedido_completo_bot(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_pedido_completo_bot(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.crear_pedido_idempotente(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_pedido_idempotente(bigint, numeric, uuid, jsonb, text, text, text, date, text, numeric, numeric, date, uuid, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.auditoria_integridad() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.auditoria_integridad() TO authenticated, service_role;

-- ===========================================================================
-- 8 · Verificacion: los seis parches entraron y ninguna quedo abierta
-- ===========================================================================
DO $verif$
DECLARE
  v_def  text;
  v_acl  text;
  v_fn   text;
  v_viol int;
BEGIN
  -- 1 y 2: el total del servidor, en los dos caminos de alta
  FOREACH v_fn IN ARRAY ARRAY['crear_pedido_completo', 'crear_pedido_completo_bot'] LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;

    IF v_def NOT LIKE '%no coincide con la suma de los items%' THEN
      RAISE EXCEPTION '% no quedo con la verificacion del total', v_fn;
    END IF;
    IF v_def NOT LIKE '%pedido_incumple_minimo(v_total_calc%' THEN
      RAISE EXCEPTION '% sigue evaluando la compra minima contra el total declarado', v_fn;
    END IF;
  END LOOP;

  -- 3: el lock antes del lookup
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'crear_pedido_idempotente';
  IF v_def NOT LIKE '%pg_advisory_xact_lock%' THEN
    RAISE EXCEPTION 'crear_pedido_idempotente quedo sin el advisory lock';
  END IF;

  -- 4: los tres de la cancelacion
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cancelar_pedido_con_stock';
  IF v_def NOT LIKE '%revertir_bloques_auto_ajuste%' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock no devuelve los bloques de auto-ajuste';
  END IF;
  IF v_def LIKE '%GREATEST(usos_pendientes - v_item.cantidad, 0)%' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock conservo el clamp a mano de usos_pendientes';
  END IF;
  IF v_def NOT LIKE '%saldo a favor por cancelacion%' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock no desimputa los pagos';
  END IF;
  IF v_def NOT LIKE '%total_real = 0%' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock no cerea total_real';
  END IF;

  -- 5: el escape hatch del cambio de cliente
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'cambiar_cliente_pedido';
  IF v_def NOT LIKE '%cancelacion_conserva_pagos%' THEN
    RAISE EXCEPTION 'cambiar_cliente_pedido quedo sin el escape hatch: la cancelacion se llevaria los pagos antes de que se reapunten';
  END IF;

  -- 6: VENTA-I mira las cuatro columnas y sigue dando los 4 legacy de abril
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'auditoria_integridad';
  IF v_def NOT LIKE '%COALESCE(total_real,0)<>0%' THEN
    RAISE EXCEPTION 'VENTA-I sigue mirando solo total';
  END IF;

  SELECT count(*) INTO v_viol FROM pedidos
   WHERE estado='cancelado'
     AND (COALESCE(total_neto,0)<>0 OR COALESCE(total_iva,0)<>0 OR COALESCE(total_real,0)<>0);
  IF v_viol <> 0 THEN
    RAISE EXCEPTION 'quedaron % pedidos cancelados con neto/iva/real distinto de 0', v_viol;
  END IF;

  -- 7: ninguna quedo alcanzable con la anon key
  FOREACH v_fn IN ARRAY ARRAY['crear_pedido_completo', 'crear_pedido_completo_bot',
                              'crear_pedido_idempotente', 'cancelar_pedido_con_stock',
                              'cambiar_cliente_pedido', 'auditoria_integridad'] LOOP
    SELECT array_to_string(proacl, ',') INTO v_acl
    FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = v_fn;

    IF v_acl IS NOT NULL AND (v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' OR v_acl LIKE '%anon=%') THEN
      RAISE EXCEPTION '% quedo ejecutable por PUBLIC o anon: %', v_fn, v_acl;
    END IF;
  END LOOP;
END
$verif$;

COMMIT;
