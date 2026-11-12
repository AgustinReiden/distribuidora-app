-- 489 · La cancelación, la NC, el cambio de cliente y la baja de total de una boleta aplican sólo el
-- crédito que nace en esa operación, y cuatro pagos viejos sin marcas se pueden quitar de su boleta
-- (#1538: B1 y B2).
--
-- QUÉ PASABA
--   · B1 · Desde la 479 y la 480, la cancelación, la NC y el cambio de cliente llaman a
--     aplicar_credito_cliente, que barre TODOS los créditos sueltos del cliente, no sólo el que
--     nació en esa operación. Lo mismo pedidos_reconciliar_pagos, el trigger de cada cambio de
--     total de una boleta (una edición, una salvedad, VB a ZZ). Lo que se quitó de una boleta con
--     «Quitar» (desimputar_pago) volvía a la boleta impaga más vieja, casi siempre la misma: se
--     deshacía lo que hizo el botón.
--   · B2 · Los pagos 6492 (NC #1, en la boleta 6445) y 6829 (NC #24, en la 6478) son créditos de
--     NC imputados a mano antes de la 479, sin ninguna marca. desimputar_pago los rechazaba con
--     «es un cobro de la boleta…», que no es cierto, y el DELETE REST también: la única salida era
--     anular la NC. Los pagos 1668 y 1669 (boleta 2618, «[saldo a favor aplicado a pedido]», de
--     mayo) son saldo a favor aplicado de antes de las marcas y tenían el mismo problema.
--
-- QUÉ CAMBIA
--   · B1 · Decisión del dueño (11/11): la cancelación, la NC, el cambio de cliente y la baja de
--     total de una boleta aplican sólo el crédito que nace en esa operación. Lo quitado con «Quitar» queda suelto hasta el próximo
--     pedido, el próximo pago a cuenta o una imputación a mano (decisión del 10/11 para COB-2).
--     - El FIFO es una sola función, _aplicar_credito_pagos(cliente, sucursal, pagos): la de
--       aplicar_credito_cliente, que aplica sólo los créditos sueltos de la lista (todos con NULL).
--       aplicar_credito_cliente queda con su firma y su EXECUTE y la llama con NULL: el alta y el
--       FIFO de la ficha siguen barriendo todo.
--     - cancelar_pedido_con_stock: los pagos que desimputa (RETURNING id).
--     - crear_nota_credito_venta_impl: el crédito de esta NC (su pago, lo que quedó suelto
--       después de bajar su boleta).
--     - cambiar_cliente_pedido: al cliente original, los pagos que estaban en X y le quedaron
--       sueltos (el cobro con 'cliente_original'; lo que X trajo de su saldo a favor o de un FIFO
--       con los dos destinos, #1489). Al cliente nuevo, con 'pedido_nuevo', lo absorbido que se
--       suelta (#1492) y el excedente que deja _pagos_excedente_a_favor: los pagos de la boleta
--       nueva que quedaron sueltos o los pedazos que salieron de ellos.
--     - pedidos_reconciliar_pagos: el excedente que suelta desafectar_sobrepago_pedido cuando la
--       boleta baja de total (pagos enteros de la boleta o pedazos que salen de ellos). Consecuencia
--       aceptada por el dueño: si una boleta SUBE de total ya no absorbe sola el crédito suelto del
--       cliente; lo absorbe el próximo pedido, el próximo pago a cuenta o una imputación a mano.
--     El orden global no cambia: las cinco llamadas toman un subconjunto de lo que ya tomó el
--     pre-bloqueo de su llamador (_credito_bloquea_boletas y _credito_bloquea_rutas_y_creditos en
--     la 479, el de la 480 en el cambio de cliente, el del propio trigger), que cuenta todos los
--     créditos sueltos del cliente y por eso toma de más.
--   · B2 · Decisión del dueño (11/11): los pagos 6492, 6829, 1668 y 1669 llevan la marca que la 479
--     escribe en un crédito aplicado, a_cuenta = true (#1329: un crédito es plata que entró, no el
--     cobro de la boleta). Antes se verifica que sigan exactamente como están hoy (boleta, cliente,
--     sucursal, monto, forma, fecha, NC y marcas); si no, se aborta. No se toca
--     de_saldo_a_favor: lo decide trg_pagos_marcar_saldo_a_favor por el movimiento (un pago que
--     pasa de suelto a una boleta), y un UPDATE a mano lo deja como estaba. Fingir ese
--     movimiento (soltarlo y volver a imputarlo) le movería la boleta y la ruta dos veces para
--     dejar todo igual.
--     Y desimputar_pago y trg_pagos_guard_credito_aplicado reconocen además un pago de NC
--     (nota_credito_id): un crédito de NC nunca es un cobro de la boleta. El mensaje para lo que
--     no tiene ninguna marca ya no dice que es un cobro: dice que no figura como saldo a favor
--     aplicado: lo trata como un cobro, pero no afirma que lo sea.
--
-- QUÉ NO CAMBIA
--   La firma y el EXECUTE de aplicar_credito_cliente, su FIFO (fecha, id) y que no aplica el
--   crédito de una NC a su propia boleta (mig 283). _alta_aplicar_saldo_a_favor,
--   registrar_pago_*_fifo_impl y desafectar_sobrepago_pedido. El pre-bloqueo de cada camino. Qué
--   desimputa la cancelación, qué devuelve el cambio de cliente y qué suelta una baja de total:
--   sólo cuánto se vuelve a aplicar.
--
-- Ensayo: scripts/test-credito-propio-1538.sql (corre en prod sin dejar rastro), el de la 479
-- (scripts/test-credito-suelto-1512.sql), el de la 480 (scripts/test-cambio-cliente-conserva-1513.sql)
-- y las claves b1 y a2m del arnés. Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos son los que se leyeron de prod el 11/11
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.aplicar_credito_cliente(bigint,bigint)',                                                    'c56c4200f0ca10c4920629e8e552f21f'),
      ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)',                                          '3e6473cbe68550ed21514daae5e4a7f1'),
      ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)',                              'b5f15944ac98d4010766f03b6274a947'),
      ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',        '0768802558d380da8f17fd0c0e6c173c'),
      ('public.desimputar_pago(bigint,bigint)',                                                            '3d1b171b70e53663fbdaa7e96bd4af2c'),
      ('public.pagos_guard_borrar_credito_aplicado()',                                                     '438f53a96624182ab9190d917303f786'),
      ('public.pedidos_reconciliar_pagos()',                                                               '2d0eccc317dde64f8e38ac30a6942b37'),
      ('public.desafectar_sobrepago_pedido(bigint)',                                                       'f0a6c0bc96d4d5e3163bf7ff5faef30a'),
      -- No cambian, pero lo de abajo se apoya en cómo sueltan los pagos.
      ('public._pagos_excedente_a_favor(bigint)',                                                          '4198b16cb0fda45856c2407693c4abc3'),
      ('public.pagos_marcar_saldo_a_favor()',                                                              '7719a8d736c771e643f96b0c614305e4')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) IS DISTINCT FROM r.hash THEN
      RAISE EXCEPTION 'mig 489 · % cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace AND proname = '_aplicar_credito_pagos') THEN
    RAISE EXCEPTION 'mig 489 · ya existe _aplicar_credito_pagos: ¿se aplicó dos veces?';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · B1 · El FIFO, una sola vez: _aplicar_credito_pagos
-- ---------------------------------------------------------------------------
CREATE FUNCTION public._aplicar_credito_pagos(p_cliente_id bigint, p_sucursal_id bigint, p_pagos bigint[])
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_credito   RECORD;
  v_pedido    RECORD;
  v_restante  numeric;
  v_aplicar   numeric;
  v_aplicado  numeric := 0;
  v_vueltas   integer;
  v_excluir   bigint;
  v_alcanza   bigint[];
BEGIN
  -- #1538 (B1): el cuerpo de aplicar_credito_cliente, que la llama con p_pagos NULL (todos los
  -- creditos sueltos del cliente: el alta y el FIFO de la ficha). Con una lista aplica solo esos
  -- creditos: la cancelacion, la NC, el cambio de cliente y la baja de total de una boleta aplican
  -- el credito que nace en esa operacion, y lo que se quito de una boleta queda suelto (decision
  -- del dueño 11/11). Una lista vacia no aplica nada.
  IF p_cliente_id IS NULL OR p_sucursal_id IS NULL THEN
    RETURN 0;
  END IF;

  PERFORM set_config('app.reimputacion_pagos', 'on', true);

  -- #1424/#1439: el orden global antes del primer lock, si hay creditos. Las
  -- boletas que los creditos alcanzan a pagar en el orden del bucle (fecha, id),
  -- por id; sus recorridos por id (cada reimputacion llega a la ruta por el
  -- trigger de monto_pagado), y los creditos por id, como la foto de la
  -- rendicion. Son las filas que el bucle iba a tomar: sigue eligiendo por fecha
  -- y las vuelve a tomar ya bloqueadas. Si llega mas lejos (el credito de una NC
  -- no va a su boleta), toma esa en su orden, como antes. Antes tomaba los
  -- creditos y despues las boletas, al reves que imputar_credito_a_pedido.
  IF EXISTS (SELECT 1 FROM pagos
              WHERE cliente_id = p_cliente_id
                AND sucursal_id = p_sucursal_id
                AND pedido_id IS NULL
                AND (p_pagos IS NULL OR id = ANY(p_pagos))) THEN
    v_alcanza := ARRAY(
      SELECT b.id
        FROM (SELECT p.id,
                     sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                       - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                FROM pedidos p
               WHERE p.cliente_id = p_cliente_id
                 AND p.sucursal_id = p_sucursal_id
                 AND p.estado NOT IN ('cancelado', 'anulado')
                 AND p.total > COALESCE(p.monto_pagado, 0)) b
       WHERE b.antes < (SELECT sum(monto) FROM pagos
                         WHERE cliente_id = p_cliente_id
                           AND sucursal_id = p_sucursal_id
                           AND pedido_id IS NULL
                           AND (p_pagos IS NULL OR id = ANY(p_pagos))));

    PERFORM 1
       FROM pedidos
      WHERE id = ANY(v_alcanza)
      ORDER BY id
        FOR UPDATE;

    PERFORM 1
       FROM recorridos
      WHERE id IN (SELECT rp.recorrido_id
                     FROM recorrido_pedidos rp
                    WHERE rp.pedido_id = ANY(v_alcanza))
      ORDER BY id
        FOR NO KEY UPDATE;

    PERFORM 1
       FROM pagos
      WHERE cliente_id = p_cliente_id
        AND sucursal_id = p_sucursal_id
        AND pedido_id IS NULL
        AND (p_pagos IS NULL OR id = ANY(p_pagos))
      ORDER BY id
        FOR UPDATE;
  END IF;

  FOR v_credito IN
    SELECT id, monto, nota_credito_id
      FROM pagos
     WHERE cliente_id = p_cliente_id
       AND sucursal_id = p_sucursal_id
       AND pedido_id IS NULL
       AND (p_pagos IS NULL OR id = ANY(p_pagos))
     ORDER BY fecha ASC, id ASC
     -- FOR UPDATE: sin lock, un credito que `imputar_credito_a_pedido` movio o
     -- partio mientras tanto se reimputaba igual con el monto viejo (el UPDATE
     -- filtra solo por id): pisaba la eleccion o dejaba un saldo negativo. Con
     -- el lock Postgres re-evalua `pedido_id IS NULL` sobre la version nueva.
       FOR UPDATE
  LOOP
    v_restante := v_credito.monto;
    v_vueltas  := 0;

    -- mig 283: el credito de una NC no se imputa al pedido que la origino
    -- (seria bajarle el total sin salvedad). NULL si no es de NC.
    v_excluir := NULL;
    IF v_credito.nota_credito_id IS NOT NULL THEN
      SELECT pedido_id INTO v_excluir
        FROM notas_credito_venta
       WHERE id = v_credito.nota_credito_id;
    END IF;

    LOOP
      EXIT WHEN v_restante <= 0.005;

      -- Se relee en cada vuelta a proposito: el trigger de monto_pagado ya actualizo
      -- la boleta anterior, asi que esta consulta ve el estado fresco.
      -- #1247: FOR UPDATE. Sin lock, un cobro de esta misma boleta en otra
      -- transaccion (registrar_pagos_pedido la lockea y la salda) no se veia:
      -- el credito entraba igual y la dejaba sobrepagada. Con el lock se espera
      -- a ese cobro y se re-evalua `total > monto_pagado` sobre la version nueva;
      -- si ya no falta nada, la boleta sale y el LIMIT trae la siguiente.
      SELECT id, total - COALESCE(monto_pagado, 0) AS falta
        INTO v_pedido
        FROM pedidos
       WHERE cliente_id = p_cliente_id
         AND sucursal_id = p_sucursal_id
         AND estado NOT IN ('cancelado', 'anulado')
         AND total > COALESCE(monto_pagado, 0)
         AND id IS DISTINCT FROM v_excluir
       ORDER BY fecha ASC, id ASC
       LIMIT 1
       FOR UPDATE;

      EXIT WHEN NOT FOUND;

      v_vueltas := v_vueltas + 1;
      EXIT WHEN v_vueltas > 500;  -- backstop, no deberia alcanzarse nunca

      v_aplicar := LEAST(v_restante, v_pedido.falta);

      IF v_aplicar >= v_restante - 0.005 THEN
        UPDATE pagos
           SET pedido_id = v_pedido.id,
               -- #1329: un credito es plata que entro.
               a_cuenta = true,
               notas = NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), '')
         WHERE id = v_credito.id;

        v_aplicado := v_aplicado + v_restante;
        v_restante := 0;
      ELSE
        UPDATE pagos SET monto = monto - v_aplicar WHERE id = v_credito.id;

        -- mig 276 (#833): nota_credito_id viaja con el pedazo. #1248: y la raiz.
        -- #1359: y el padre directo.
        INSERT INTO pagos (
          cliente_id, pedido_id, monto, forma_pago, fecha,
          referencia, notas, usuario_id, sucursal_id, nota_credito_id, pago_origen_id,
          pago_padre_id
        )
        SELECT cliente_id, v_pedido.id, v_aplicar, forma_pago, fecha, referencia,
               NULLIF(trim(replace(COALESCE(notas, ''), '[saldo a favor]', '')), ''),
               usuario_id, sucursal_id, nota_credito_id, COALESCE(pago_origen_id, id),
               id
          FROM pagos
         WHERE id = v_credito.id;

        v_aplicado := v_aplicado + v_aplicar;
        v_restante := v_restante - v_aplicar;
      END IF;
    END LOOP;
  END LOOP;

  PERFORM set_config('app.reimputacion_pagos', 'off', true);

  RETURN v_aplicado;
END;
$function$;

REVOKE ALL ON FUNCTION public._aplicar_credito_pagos(bigint,bigint,bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._aplicar_credito_pagos(bigint,bigint,bigint[]) TO service_role;

-- Misma firma, mismo SECURITY DEFINER y mismo EXECUTE (CREATE OR REPLACE los conserva).
CREATE OR REPLACE FUNCTION public.aplicar_credito_cliente(p_cliente_id bigint, p_sucursal_id bigint)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- #1538 (B1): todos los creditos sueltos del cliente, FIFO por (fecha, id). La
  -- cuenta vive en _aplicar_credito_pagos; la cancelacion, la NC, el cambio de
  -- cliente y la reconciliacion de una boleta la llaman con la lista del credito que
  -- nace en cada una.
  RETURN public._aplicar_credito_pagos(p_cliente_id, p_sucursal_id, NULL);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · B1 · Cada operación aplica su crédito (parches por ancla)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _489_parche (funcion text, orden int, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _489_parche (funcion, orden, ancla, reemplazo) VALUES
-- La cancelación: 1 · la variable.
('cancelar', 1,
$a$  v_credito_aplicado NUMERIC := 0;
BEGIN
$a$,
$r$  v_credito_aplicado NUMERIC := 0;
  -- #1538 (B1)
  v_pagos_liberados BIGINT[];
BEGIN
$r$),
-- 2 · qué pagos va a desimputar. Antes del lock de la 447, que tiene que quedar pegado al UPDATE
-- (lo mira el L1 de scripts/test-cancelar-pagos-por-id-1423.sql).
('cancelar', 2,
$a$    PERFORM 1
       FROM pagos
      WHERE pedido_id = p_pedido_id
        AND sucursal_id = v_sucursal
      ORDER BY id
        FOR NO KEY UPDATE;
$a$,
$r$    -- #1538 (B1): cuales se desimputan, para aplicar solo esos. La boleta ya esta
    -- bloqueada: ningun pago le entra ni le sale hasta el UPDATE de abajo.
    v_pagos_liberados := ARRAY(SELECT id FROM pagos
                                WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
                                ORDER BY id);

    PERFORM 1
       FROM pagos
      WHERE pedido_id = p_pedido_id
        AND sucursal_id = v_sucursal
      ORDER BY id
        FOR NO KEY UPDATE;
$r$),
-- 3 · aplica sólo esos.
('cancelar', 3,
$a$    v_credito_aplicado := COALESCE(public.aplicar_credito_cliente(v_pedido.cliente_id, v_sucursal), 0);
$a$,
$r$    -- #1538 (B1, decision del dueño 11/11): solo lo que desimputo esta
    -- cancelacion, no los otros creditos sueltos del cliente: lo que se quito de
    -- una boleta queda suelto.
    v_credito_aplicado := COALESCE(public._aplicar_credito_pagos(v_pedido.cliente_id, v_sucursal, v_pagos_liberados), 0);
$r$),
-- La NC: aplica sólo su crédito.
('nc', 1,
$a$  IF v_total - v_aplicado > 0.005 THEN
    v_otras := COALESCE(public.aplicar_credito_cliente(p_cliente_id, v_sucursal), 0);
  END IF;
$a$,
$r$  -- #1538 (B1, decision del dueño 11/11): solo el credito de esta NC (su pago,
  -- con lo que quedo suelto despues de bajar su boleta), no los otros creditos
  -- sueltos del cliente: lo que se quito de una boleta queda suelto.
  IF v_total - v_aplicado > 0.005 THEN
    v_otras := COALESCE(public._aplicar_credito_pagos(p_cliente_id, v_sucursal, ARRAY[v_pago_id]), 0);
  END IF;
$r$),
-- El cambio de cliente: 1 · las variables.
('cambio', 1,
$a$  v_aplicado_viejo  NUMERIC := 0;
BEGIN
$a$,
$r$  v_aplicado_viejo  NUMERIC := 0;
  -- #1538 (B1)
  v_pagos_x         BIGINT[];
  v_reaplicados     BIGINT[];
  v_pagos_nuevo     BIGINT[];
  v_sueltos_antes   BIGINT[];
  v_nacen           BIGINT[];
  v_vuelven         BIGINT[];
BEGIN
$r$),
-- 2 · los pagos de X antes de cancelarla (ya tomados por el pre-bloqueo).
('cambio', 2,
$a$  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
$a$,
$r$  -- #1538 (B1): los pagos de X. Lo que le vuelve al cliente original son los que
  -- de aca le quedan sueltos.
  v_pagos_x := ARRAY(SELECT id FROM pagos
                      WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
                      ORDER BY id);

  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
$r$),
-- 3 · cuáles absorbidos se soltaron (#1492).
('cambio', 3,
$a$      UPDATE pagos
         SET pedido_id = NULL
       WHERE pedido_id = v_nuevo_id
         AND sucursal_id = v_sucursal
         AND de_saldo_a_favor;
      GET DIAGNOSTICS v_reaplicar = ROW_COUNT;
$a$,
$r$      -- #1538 (B1): cuales, para volver a aplicar solo esos.
      WITH r AS (
        UPDATE pagos
           SET pedido_id = NULL
         WHERE pedido_id = v_nuevo_id
           AND sucursal_id = v_sucursal
           AND de_saldo_a_favor
        RETURNING id
      )
      SELECT array_agg(id ORDER BY id) INTO v_reaplicados FROM r;
      v_reaplicar := COALESCE(cardinality(v_reaplicados), 0);
$r$),
-- 4 · al cliente nuevo, lo absorbido que se soltó y el excedente.
('cambio', 4,
$a$    v_excedente := public._pagos_excedente_a_favor(v_nuevo_id);
    IF v_excedente > 0 OR v_reaplicar > 0 THEN
      PERFORM public.aplicar_credito_cliente(p_nuevo_cliente_id, v_sucursal);
    END IF;
$a$,
$r$    -- #1538 (B1, decision del dueño 11/11): se aplica solo lo que nace aca: lo
    -- absorbido que se solto arriba y el excedente que suelta
    -- _pagos_excedente_a_favor (pagos enteros de la boleta nueva o pedazos que
    -- salen de ellos), no los otros creditos sueltos del cliente nuevo. Lo que ya
    -- estaba suelto antes no cuenta, aunque sea un pedazo de un pago de la boleta.
    v_pagos_nuevo := ARRAY(SELECT id FROM pagos
                            WHERE pedido_id = v_nuevo_id AND sucursal_id = v_sucursal);
    v_sueltos_antes := ARRAY(SELECT id FROM pagos
                              WHERE cliente_id = p_nuevo_cliente_id
                                AND sucursal_id = v_sucursal
                                AND pedido_id IS NULL);
    v_excedente := public._pagos_excedente_a_favor(v_nuevo_id);
    v_nacen := COALESCE(v_reaplicados, '{}'::bigint[]) || ARRAY(
      SELECT id FROM pagos
       WHERE cliente_id = p_nuevo_cliente_id
         AND sucursal_id = v_sucursal
         AND pedido_id IS NULL
         AND id <> ALL(v_sueltos_antes)
         AND (id = ANY(v_pagos_nuevo) OR pago_padre_id = ANY(v_pagos_nuevo))
       ORDER BY id);
    IF cardinality(v_nacen) > 0 THEN
      PERFORM public._aplicar_credito_pagos(p_nuevo_cliente_id, v_sucursal, v_nacen);
    END IF;
$r$),
-- 5 · al cliente original, lo que le volvió.
('cambio', 5,
$a$  IF EXISTS (SELECT 1 FROM pagos
              WHERE cliente_id = v_pedido.cliente_id
                AND sucursal_id = v_sucursal
                AND pedido_id IS NULL) THEN
    v_aplicado_viejo := COALESCE(public.aplicar_credito_cliente(v_pedido.cliente_id, v_sucursal), 0);
  END IF;
$a$,
$r$  -- #1538 (B1, decision del dueño 11/11): solo lo que le vuelve en este cambio
  -- (los pagos que estaban en X y le quedaron sueltos), no los otros creditos
  -- sueltos del cliente original: lo que se quito de una boleta queda suelto.
  v_vuelven := ARRAY(SELECT id FROM pagos
                      WHERE id = ANY(v_pagos_x)
                        AND cliente_id = v_pedido.cliente_id
                        AND sucursal_id = v_sucursal
                        AND pedido_id IS NULL
                      ORDER BY id);
  IF cardinality(v_vuelven) > 0 THEN
    v_aplicado_viejo := COALESCE(public._aplicar_credito_pagos(v_pedido.cliente_id, v_sucursal, v_vuelven), 0);
  END IF;
$r$),
-- La baja de total de una boleta: 1 · las variables.
('reconciliar', 1,
$a$  v_alcanza   bigint[];
BEGIN
$a$,
$r$  v_alcanza   bigint[];
  -- #1538 (B1)
  v_pagos     bigint[];
  v_sueltos   bigint[];
  v_nacen     bigint[];
BEGIN
$r$),
-- 2 · los pagos de la boleta y los créditos sueltos de antes, delante del pre-bloqueo (que tiene que
-- terminar pegado a desafectar_sobrepago_pedido: lo mira el L1 de scripts/test-edicion-creditos-1446.sql).
('reconciliar', 2,
$a$  -- #1446: el orden global antes del primer lock de desafectar y de aplicar. Este
$a$,
$r$  -- #1538 (B1): los pagos de esta boleta y los creditos sueltos del cliente antes de
  -- desafectar, para aplicar al final solo lo que se suelte aca. La boleta ya esta
  -- bloqueada por el UPDATE que dispara el trigger: ningun pago le entra ni le sale, y
  -- un credito suelto que aparezca en el medio no es un pago de ella ni un pedazo de uno.
  v_pagos := ARRAY(SELECT id FROM pagos WHERE pedido_id = NEW.id);
  v_sueltos := ARRAY(SELECT id FROM pagos
                      WHERE cliente_id = NEW.cliente_id
                        AND sucursal_id = NEW.sucursal_id
                        AND pedido_id IS NULL);

  -- #1446: el orden global antes del primer lock de desafectar y de aplicar. Este
$r$),
-- 3 · aplica sólo el excedente que suelta esta boleta.
('reconciliar', 3,
$a$  PERFORM public.aplicar_credito_cliente(NEW.cliente_id, NEW.sucursal_id);
$a$,
$r$  -- #1538 (B1, decision del dueño 11/11): se aplica solo el excedente que suelta
  -- esta boleta al bajar de total (desafectar_sobrepago_pedido: pagos enteros de la
  -- boleta o pedazos que salen de ellos), no los otros creditos sueltos del cliente:
  -- lo que se quito de una boleta queda suelto. Consecuencia aceptada por el dueño:
  -- una boleta que SUBE de total ya no absorbe sola el credito suelto del cliente; lo
  -- absorbe el proximo pedido, el proximo pago a cuenta o una imputacion a mano. El
  -- pre-bloqueo de arriba sigue contando todos los creditos sueltos: toma de mas.
  v_nacen := ARRAY(SELECT id FROM pagos
                    WHERE cliente_id = NEW.cliente_id
                      AND sucursal_id = NEW.sucursal_id
                      AND pedido_id IS NULL
                      AND id <> ALL(v_sueltos)
                      AND (id = ANY(v_pagos) OR pago_padre_id = ANY(v_pagos))
                    ORDER BY id);
  IF cardinality(v_nacen) > 0 THEN
    PERFORM public._aplicar_credito_pagos(NEW.cliente_id, NEW.sucursal_id, v_nacen);
  END IF;
$r$),
-- B2 · desimputar_pago: 1 · lee de qué NC es.
('desimputar', 1,
$a$  SELECT id, pedido_id, cliente_id, monto, de_saldo_a_favor, a_cuenta, pago_origen_id
    INTO v_pago
$a$,
$r$  SELECT id, pedido_id, cliente_id, monto, de_saldo_a_favor, a_cuenta, pago_origen_id,
         nota_credito_id
    INTO v_pago
$r$),
-- 2 · un pago de NC nunca es un cobro, y el mensaje no afirma lo que no sabe.
('desimputar', 2,
$a$  IF NOT (COALESCE(v_pago.de_saldo_a_favor, false) OR COALESCE(v_pago.a_cuenta, false)
          OR v_pago.pago_origen_id IS NOT NULL) THEN
    RAISE EXCEPTION 'El pago #% es un cobro de la boleta #%, no saldo a favor: se anula, no se quita',
      p_pago_id, p_pedido_id USING ERRCODE = '22023';
  END IF;
$a$,
$r$  -- #1538 (B2): un credito de NC (nota_credito_id) tampoco es un cobro de la
  -- boleta, tenga o no las marcas: los de antes de la 479 se imputaron sin ellas.
  -- Lo que no tiene ninguna de las cuatro no figura como saldo a favor aplicado:
  -- el sistema lo trata como un cobro, pero no puede saber si lo fue (hay creditos
  -- aplicados de antes de las marcas).
  IF NOT (COALESCE(v_pago.de_saldo_a_favor, false) OR COALESCE(v_pago.a_cuenta, false)
          OR v_pago.pago_origen_id IS NOT NULL OR v_pago.nota_credito_id IS NOT NULL) THEN
    RAISE EXCEPTION 'El pago #% de la boleta #% no figura como saldo a favor aplicado (no vino del saldo a favor, de un pago a cuenta, de otro pago ni de una nota de crédito): se anula como un cobro, no se quita',
      p_pago_id, p_pedido_id USING ERRCODE = '22023';
  END IF;
$r$),
-- B2 · el DELETE REST de un crédito de NC aplicado dice cómo quitarlo.
('guard', 1,
$a$     AND (COALESCE(OLD.de_saldo_a_favor, false) OR COALESCE(OLD.a_cuenta, false)
          OR OLD.pago_origen_id IS NOT NULL) THEN
$a$,
$r$     AND (COALESCE(OLD.de_saldo_a_favor, false) OR COALESCE(OLD.a_cuenta, false)
          OR OLD.pago_origen_id IS NOT NULL
          -- #1538 (B2): un credito de NC aplicado, como en desimputar_pago.
          OR OLD.nota_credito_id IS NOT NULL) THEN
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN
    SELECT * FROM (VALUES
      ('cancelar',   'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'),
      ('nc',         'public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)'),
      ('cambio',     'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'),
      ('desimputar', 'public.desimputar_pago(bigint,bigint)'),
      ('guard',      'public.pagos_guard_borrar_credito_aplicado()'),
      ('reconciliar', 'public.pedidos_reconciliar_pagos()')
    ) AS t(funcion, firma)
  LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _489_parche WHERE funcion = v_f.funcion ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig 489 · parche % %: el ancla aparece % vez/veces y se esperaba 1',
          v_p.funcion, v_p.orden, v_n;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;

  -- Ni la cancelación, ni la NC, ni el cambio de cliente, ni la reconciliación llaman ya a
  -- aplicar_credito_cliente.
  IF EXISTS (SELECT 1 FROM pg_proc p, regexp_split_to_table(p.prosrc, E'\n') l
              WHERE p.oid IN ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure,
                              'public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)'::regprocedure,
                              'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure,
                              'public.pedidos_reconciliar_pagos()'::regprocedure)
                AND l ~ 'aplicar_credito_cliente\s*\(' AND l !~ '^\s*--') THEN
    RAISE EXCEPTION 'mig 489 · queda una llamada a aplicar_credito_cliente en la cancelación, la NC, el cambio de cliente o la reconciliación';
  END IF;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 3 · B2 · Los pagos 6492, 6829, 1668 y 1669 llevan la marca de un crédito aplicado
-- ---------------------------------------------------------------------------
DO $b2$
DECLARE
  v_n int;
BEGIN
  -- Exactamente como están hoy (#1538): boleta, cliente, sucursal, monto, forma, fecha, NC, sin
  -- pedazo y sin ninguna marca.
  SELECT count(*) INTO v_n
    FROM pagos p
    JOIN (VALUES (6492::bigint, 6445::bigint, 818::bigint, 1::bigint, 10200.00::numeric, 'nota_credito'::text, DATE '2026-10-01', 1::bigint),
                 (6829, 6478, 97, 1, 17000.00, 'nota_credito', DATE '2026-10-07', 24),
                 (1668, 2618, 434, 2, 39000.00, 'transferencia', DATE '2026-05-22', NULL),
                 (1669, 2618, 434, 2, 5400.01, 'efectivo', DATE '2026-05-22', NULL))
         AS e(id, pedido_id, cliente_id, sucursal_id, monto, forma_pago, fecha, nota_credito_id)
      ON p.id = e.id
     AND p.pedido_id = e.pedido_id
     AND p.cliente_id = e.cliente_id
     AND p.sucursal_id = e.sucursal_id
     AND p.monto = e.monto
     AND p.forma_pago = e.forma_pago
     AND p.fecha = e.fecha
     AND p.nota_credito_id IS NOT DISTINCT FROM e.nota_credito_id
   WHERE p.de_saldo_a_favor IS FALSE
     AND p.a_cuenta IS FALSE
     AND p.pago_origen_id IS NULL
     AND p.pago_padre_id IS NULL
     AND (p.id NOT IN (1668, 1669) OR p.notas = '[saldo a favor aplicado a pedido]');
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'mig 489 · los pagos 6492, 6829, 1668 y 1669 ya no están como hoy (% de 4): revisar a mano antes de marcarlos', v_n;
  END IF;

  -- #1538 (B2, decision del dueño 11/11): a_cuenta, la marca que escriben la 479 y
  -- aplicar_credito_cliente en un credito aplicado (#1329). de_saldo_a_favor no:
  -- lo decide trg_pagos_marcar_saldo_a_favor por el movimiento, y un UPDATE a mano
  -- lo deja como estaba.
  UPDATE pagos SET a_cuenta = true WHERE id IN (6492, 6829, 1668, 1669);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'mig 489 · se marcaron % pagos y se esperaban 4', v_n;
  END IF;
END
$b2$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos son los del repo y los permisos, los esperados
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v_md5 text;
  v_acl text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public._aplicar_credito_pagos(bigint,bigint,bigint[])',                                         '9d2ecc6fd85b14407c6c85f579508b15',
       '{postgres=X/postgres,service_role=X/postgres}/false'),
      ('public.aplicar_credito_cliente(bigint,bigint)',                                                 'de9bc54d4198f7124e2c08b61b84fc63',
       '{postgres=X/postgres,service_role=X/postgres}/true'),
      ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)',                                       '9af5626c58c2e994a7968d74b62ad018',
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
      ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)',                           'f26fe6cc33d11afb81a4ec5d574318a1',
       '{postgres=X/postgres,service_role=X/postgres}/true'),
      ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',     '32838128c6f1aec5da55e890039494f6',
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
      ('public.desimputar_pago(bigint,bigint)',                                                         'e37884bac45972ca3c11b3a44c50b27f',
       '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
      ('public.pagos_guard_borrar_credito_aplicado()',                                                  '5798a5196eb5b3042c5addbef42f94b2',
       '{postgres=X/postgres,service_role=X/postgres}/false'),
      ('public.pedidos_reconciliar_pagos()',                                                            '145659fa600f0c58e7a558b7c9957843',
       '{postgres=X/postgres,service_role=X/postgres}/true')
    ) AS t(firma, hash, acl)
  LOOP
    SELECT md5(prosrc), proacl::text || '/' || prosecdef::text INTO v_md5, v_acl
      FROM pg_proc WHERE oid = r.firma::regprocedure;
    IF v_md5 IS DISTINCT FROM r.hash OR v_acl IS DISTINCT FROM r.acl THEN
      RAISE EXCEPTION 'mig 489 · % no quedó como en el repo (md5 %, acl %)', r.firma, v_md5, v_acl;
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM pagos WHERE id IN (6492, 6829, 1668, 1669) AND a_cuenta) <> 4 THEN
    RAISE EXCEPTION 'mig 489 · los pagos 6492, 6829, 1668 y 1669 no quedaron marcados';
  END IF;
END
$post$;

COMMIT;
