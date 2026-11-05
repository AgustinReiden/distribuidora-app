-- 459 · Cambiar el cliente e imputar un crédito toman las boletas, las rutas y los pagos antes que el cliente (#1460).
--
-- QUÉ PASABA
--   Dos caminos de cobro tomaban filas fuera del orden global (pedidos por id → recorridos por id →
--   paradas → pagos por id, y el cliente al final), y se cruzaban con la edición de otra boleta del
--   mismo cliente: 40P01, sin datos rotos. Medido en el arnés (scripts/concurrencia, clave t15).
--   · C1 · cambiar_cliente_pedido con 'pedido_nuevo' toma X, la cancela (sus productos y el cliente
--     viejo), crea el pedido nuevo (los productos y, en el INSERT, el cliente nuevo C2) y, si sobra
--     lo cobrado, aplicar_credito_cliente(C2) toma W, otra boleta impaga de C2, sus rutas y los
--     créditos de C2. Una edición de una boleta Y cobrada de C2 (actualizar_pedido_items, una
--     salvedad, pasar a vale blanco) toma W e Y por id (_edicion_bloquea_boletas, 457) y después los
--     productos y C2. El cambio iba productos → W y C2 → W; la edición, W → productos → C2.
--   · C7 · imputar_credito_a_pedido_impl toma la boleta Y y el crédito C, y el UPDATE de pagos llega
--     a la ruta de Y recién por el trigger de monto_pagado. La edición de otra boleta X de la misma
--     ruta toma la ruta y después los créditos (pedidos_reconciliar_pagos, 457). Crédito → ruta
--     contra ruta → crédito.
--   C6 (el DELETE REST de un pago contra la edición de otra boleta de la misma ruta) se midió y no
--   muerde: actualizar_saldo_cliente sólo toma el cliente cuando el pago es un crédito, y un crédito
--   no tiene boleta ni ruta. El orden de los triggers de pagos no se toca.
--
-- QUÉ CAMBIA (sólo el orden de los locks)
--   · cambiar_cliente_pedido, con 'pedido_nuevo' y algo cobrado en X, antes de su lock de X: X y las
--     boletas de C2 que lo cobrado de X más los créditos de C2 alcanzan a pagar en el orden de
--     aplicar_credito_cliente (fecha, id), juntas y por id; sus recorridos por id, y los pagos de X y
--     los créditos de C2 por id. Todavía no se sabe el excedente: la cota es todo lo cobrado de X.
--     Toma de más, nunca de menos. Con 'cliente_original', o sin nada cobrado, no toma nada nuevo.
--   · imputar_credito_a_pedido_impl, después de su lock de la boleta y antes del crédito: las rutas
--     de la boleta por id, como aplicar_credito_cliente (454).
--
-- QUÉ NO CAMBIA
--   Qué se recorta, qué se imputa, a qué boleta, el saldo, los mensajes, las firmas y los EXECUTE.
--   aplicar_credito_cliente, desafectar_sobrepago_pedido, crear_pedido_completo y
--   _edicion_bloquea_boletas no se tocan.
--
-- Ensayo: scripts/test-cobros-cliente-rutas-1460.sql (corre en prod sin dejar rastro).
-- Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos son los que se leyeron de prod (05/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '5b5ba426282006156c980daf3f82cf3a'),
        ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',                                '8f5768b8269401dee69e05ab6c9622bd')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 459 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;
END
$premisas$;

CREATE TEMP TABLE _nnn_parche (firma text, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _nnn_parche (firma, ancla, reemplazo) VALUES
('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
$a$  v_excedente    NUMERIC := 0;
BEGIN
$a$,
$r$  v_excedente    NUMERIC := 0;
  -- #1460: las boletas que el cobro de X puede pagar en el cliente nuevo.
  v_alcanza      BIGINT[];
BEGIN
$r$),
('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
$a$  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
$a$,
$r$  -- #1460: el orden global (pedidos, recorridos, pagos) antes del primer lock.
  -- Con 'pedido_nuevo' el cobro de X viaja al pedido nuevo, y lo que sobre lo
  -- lleva aplicar_credito_cliente a las otras boletas del cliente nuevo, sus
  -- rutas y sus creditos: despues de que la cancelacion tomo los productos y de
  -- que el INSERT del pedido nuevo tomo al cliente. Una edicion de una de esas
  -- boletas las toma por id y despues los productos y el cliente: 40P01. Aca, si
  -- X tiene algo cobrado: X y las boletas del cliente nuevo que ese cobro mas sus
  -- creditos alcanzan a pagar en el orden de aplicar_credito_cliente (fecha, id),
  -- por id; sus recorridos por id, y los pagos de X y los creditos del cliente
  -- nuevo por id. Todavia no se sabe el excedente: la cota es todo lo cobrado de
  -- X, toma de mas, nunca de menos. Lee sin lock: el SELECT de abajo vuelve a
  -- tomar X y valida.
  IF p_destino_pagos = 'pedido_nuevo'
     AND (SELECT COALESCE(monto_pagado, 0) FROM pedidos
           WHERE id = p_pedido_id
             AND sucursal_id = v_sucursal
             AND tipo_factura IS DISTINCT FROM 'VB') > 0.005 THEN
    v_alcanza := ARRAY(
      SELECT b.id
        FROM (SELECT p.id,
                     sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                       - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
                FROM pedidos p
               WHERE p.cliente_id = p_nuevo_cliente_id
                 AND p.sucursal_id = v_sucursal
                 AND p.estado NOT IN ('cancelado', 'anulado')
                 AND p.total > COALESCE(p.monto_pagado, 0)) b
       WHERE b.antes < (SELECT COALESCE(monto_pagado, 0) FROM pedidos WHERE id = p_pedido_id)
                       + COALESCE((SELECT sum(monto) FROM pagos
                                    WHERE cliente_id = p_nuevo_cliente_id
                                      AND sucursal_id = v_sucursal
                                      AND pedido_id IS NULL), 0)) || p_pedido_id;

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
      WHERE id IN (SELECT pg.id
                     FROM pagos pg
                    WHERE pg.pedido_id = p_pedido_id
                      AND pg.sucursal_id = v_sucursal
                   UNION ALL
                   SELECT pg.id
                     FROM pagos pg
                    WHERE pg.cliente_id = p_nuevo_cliente_id
                      AND pg.sucursal_id = v_sucursal
                      AND pg.pedido_id IS NULL)
      ORDER BY id
        FOR UPDATE;
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
$r$),
('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
$a$  PERFORM 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id FOR UPDATE;
$a$,
$r$  PERFORM 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id FOR UPDATE;

  -- #1460: y sus recorridos por id, antes que el credito. El UPDATE de pagos de
  -- abajo llega a la ruta por el trigger de monto_pagado, con el credito ya
  -- tomado; la edicion de otra boleta de la misma ruta toma la ruta y despues
  -- los creditos (pedidos_reconciliar_pagos): 40P01. Es el orden de
  -- aplicar_credito_cliente.
  PERFORM 1
     FROM recorridos
    WHERE id IN (SELECT rp.recorrido_id
                   FROM recorrido_pedidos rp
                   JOIN pedidos pd ON pd.id = rp.pedido_id
                  WHERE rp.pedido_id = p_pedido_id
                    AND pd.sucursal_id = v_sucursal_id)
    ORDER BY id
      FOR NO KEY UPDATE;
$r$);

DO $parches$
DECLARE
  v_firma text;
  v_p     record;
  v_def   text;
  v_n     int;
BEGIN
  -- Todas las anclas de una función sobre el mismo cuerpo, y un solo CREATE: la
  -- variable nueva de cambiar_cliente_pedido y el bloque que la usa entran juntos.
  FOR v_firma IN SELECT DISTINCT firma FROM _nnn_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_firma::regprocedure);
    FOR v_p IN SELECT * FROM _nnn_parche WHERE firma = v_firma ORDER BY ancla LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig 459 · %: el ancla aparece % vez/veces y se esperaba 1', v_firma, v_n;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, x.acl, md5(p.prosrc) AS md5_vivo, p.proacl::text || '/' || p.prosecdef::text AS acl_viva
      FROM (VALUES
        ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '2e006a55197171eeb28934bf4992fad6', '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true'),
        ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',                                '59db660b20b9f8e36ad918990ac65150', '{postgres=X/postgres,service_role=X/postgres}/true')
      ) AS x(firma, md5, acl)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 OR v_f.acl_viva <> v_f.acl THEN
      RAISE EXCEPTION 'mig 459 · % no quedó como en el repo (md5 %, acl %)', v_f.firma, v_f.md5_vivo, v_f.acl_viva;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
