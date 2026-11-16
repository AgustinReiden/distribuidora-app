-- =========================================================================
-- NNN · EL CAMBIO DE CLIENTE Y EL CANJE CUIDAN LOS LOTES
--       (reauditoría del 15/11: STK-1 y STK-2 de #1594, sus bajos 1594-b2 y
--        1594-b4; 1595-b3 y 1595-b8 de #1595; el comentario de COB-b6 de #1545.
--        Tarjeta M3 de #1603)
--
-- Parcha por ancla tres funciones (`cambiar_cliente_pedido`,
-- `_restaurar_lotes_fefo` y `_aplicar_cambio_producto`), con premisa de md5
-- sobre el cuerpo vivo leído el 15/11 (ledger en la 503) y poscondición de md5,
-- definer y ACL. No cambia tablas, firmas ni grants.
-- Ensayo: scripts/test-stock-cambio-cliente-y-canje-1594.sql. Se aplica en LF.
--
-- =========================================================================
-- STK-1 · EL CAMBIO DE CLIENTE PASABA UNIDADES DE LA BOLSA AL LOTE
-- =========================================================================
-- `cambiar_cliente_pedido` cancela X (`cancelar_pedido_con_stock` devuelve cada
-- línea a su lote por su huella) y da de alta el pedido nuevo
-- (`crear_pedido_completo`, cuya bajada come primero la bolsa). Si la bolsa
-- cambió desde la venta, la devolución y la bajada no se cancelan: con L1 en 20,
-- bolsa 20 y X con huella L1:30, el cambio dejaba L1 en 40, bolsa 0 y el pedido
-- nuevo con L1:10. El stock total cierra y ningún check lo ve.
-- Es lo que la edición y la sustitución ya resolvieron (#1097,
-- migrations/CLAUDE.md): la devolución de un camino que deshace y rehace líneas
-- se cancela con la bajada que viene después, así que va a la bolsa, y al final
-- `_rehacer_huella_lineas` conserva la huella que la cantidad nueva sigue
-- cubriendo y devuelve el resto a su lote. Acá la devolución la hace la
-- cancelación, que es de otra tarjeta y con su etiqueta de lista blanca tiene
-- que seguir volviendo a su lote cuando se cancela de verdad. Por eso el cambio
-- de cliente:
--   · antes de cancelar toma la foto de la huella de X (`_foto_huella_lineas`,
--     con el mismo predicado que la edición: la venta y el regalo que mueve
--     stock) y el contador de cada lote de esa huella, bloqueados (los
--     productos ya están tomados en el pre-bloqueo: producto antes que lote);
--   · después de cancelar saca de cada lote lo que la cancelación le devolvió,
--     con tope en la huella de la foto (así no toca lo que le haya devuelto otra
--     cosa, como el fardo de un contenedor del mismo lote): esas unidades
--     quedan en la bolsa, como en la edición. `productos.stock` no se mueve y el
--     ledger no cambia;
--   · el alta come esas unidades de la bolsa, y después de copiar las cadenas
--     de los regalos (la foto se traduce a la clave nueva de cada cadena),
--     `_rehacer_huella_lineas` le pone a las líneas nuevas la huella de X.
-- Con los mismos items el resultado es el de antes del cambio: los lotes, la
-- bolsa y la huella (ahora del pedido nuevo). Si los items cambian, la regla es
-- la de la edición.
--
-- =========================================================================
-- STK-2 · LO QUE VUELVE EN BUEN ESTADO EN UN CANJE ENTRABA A UN LOTE VENCIDO
-- =========================================================================
-- El devuelto sube con 'cambio_producto' (lista blanca) y no es de ningún
-- pedido: cae en la segunda pasada de `_restaurar_lotes_fefo`, que elegía el
-- lote más viejo con hueco sin mirar si venció. Al dar de baja ese lote se
-- mermaban como vencidas unidades buenas. Decisión del dueño (D8 del plan de
-- #1603): lo que reingresa por un canje va a un lote vigente con hueco y, si no
-- hay, a la bolsa.
-- El cambio va en la función compartida, porque la subida la hace el trigger,
-- pero sólo para el origen del canje ('cambio_producto') y sólo en la segunda
-- pasada:
--   · la primera pasada (la devolución que vuelve a SU lote por la huella) no
--     cambia aunque el lote haya vencido: esas unidades son de ese lote;
--   · los otros caminos que llegan a la segunda pasada (la devolución a nivel
--     pedido de una línea sin huella, anterior a la 256) no cambian: no se sabe
--     de dónde salieron sus unidades, y si un FEFO que consume o devuelve en
--     los lotes vencidos es correcto es la decisión del fork que dejó abierta
--     #1594 (FEFO consume los vencidos antes que los frescos). Extender la regla
--     del canje a esos caminos sería decidirla de paso.
-- Vencido es `fecha_vencimiento < _tablero_hoy()`, la regla de
-- `registrar_merma_manual`.
--
-- =========================================================================
-- BAJOS
-- =========================================================================
--   · 1594-b2 · el canje del mismo producto que reingresa mueve sólo la
--     diferencia desde #1558 (STK-20), pero pedía stock por la cantidad
--     entregada entera: con 5 en stock, devolver 10 y llevarse 12 se rechazaba.
--     Ahora pide la diferencia.
--   · 1594-b4 · la merma del canje que no reingresa asentaba las dos patas como
--     'cambio_producto_merma' del canje, y la fila de `mermas_stock` no decía de
--     qué canje era. Ahora es como la merma manual (232), la salvedad (234) y la
--     cancelación por falta de stock (269): la subida 'cambio_producto_merma'
--     del canje (fuera de la lista blanca: entra a la bolsa), la fila de la
--     merma nombra el canje (como la de la cancelación nombra su pedido) y la
--     bajada es 'merma' de esa fila. El neto y los lotes no cambian.
--   · 1595-b3 · `cambiar_cliente_pedido` prendía al empezar cuatro GUC locales
--     a la transacción (`app.omitir_minimo_pedido`, `app.cargo_envio_forzado`,
--     `app.cargo_envio_estado_forzado` y, con 'pedido_nuevo',
--     `app.cancelacion_conserva_pagos`) y no los apagaba, tampoco en un
--     rechazo. Ahora se prenden justo antes de cancelar, guardando lo que
--     tenían, y se restauran al salir. `app.omitir_minimo_venta` sigue prendido
--     hasta el final a propósito: lo lee un trigger diferido.
--   · 1595-b8 · el pedido nuevo tomaba el costo de hoy en cada línea
--     (`crear_pedido_completo`). La reatribución no es una venta nueva: cada
--     línea toma la foto de costo de la línea de X con el mismo producto, combo,
--     regalo y promo, por la cascada de `costo_valuacion` (la foto es el
--     snapshot; sin línea en X, el costo de hoy, como el alta). Y la comanda de
--     un canje (canal 'cambio', total 0 por CAMBIO-01) ya no cambia de cliente:
--     se cancelaba y volvía como una venta. Como en la edición (#1323), se
--     cancela y se registra de nuevo.
--   · COB-b6 · el comentario de la 1248 nombraba `zzz_pedidos_reconciliar_pagos`;
--     el trigger vivo es `trg_pedidos_reconciliar_pagos`.
--
-- Revertir: volver los tres cuerpos a los de la premisa.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 15/11 y las piezas con las que se cuenta
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '5ca686d53a299f1bec98e5b16e4fe68c'),
    ('public._restaurar_lotes_fefo(bigint,bigint,integer)', 'ff589d07652fc2fa1cfe6855235f4b23'),
    ('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)', '2f4e56e64fabf2e1e698fcf241dd0f6b'),
    -- No cambian, pero el arreglo cuenta con ellas como están: la foto y el
    -- rehacer de la huella (#1097), y la lista blanca del trigger de lotes.
    ('public._foto_huella_lineas(bigint[])', 'f03cb23ba02fbef46ae92ea53e9daafe'),
    ('public._rehacer_huella_lineas(jsonb,bigint[])', 'c862ed417fb9b1b22e223f00938b202c'),
    ('public.sincronizar_lotes_stock()', '94f541388723d5183b1e77a2c3534943')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 1 · _restaurar_lotes_fefo: el canje no vuelve a un lote vencido (STK-2)
-- =========================================================================
DO $parche_restaurar$
DECLARE
  v_def text := pg_get_functiondef('public._restaurar_lotes_fefo(bigint,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_linea_propia boolean := false;
BEGIN
$a$,
$r$  v_linea_propia boolean := false;
  -- STK-2 (#1594, decisión del dueño): lo que reingresa por un canje no va a un
  -- lote vencido. Sólo el origen del canje y sólo la segunda pasada: ver abajo.
  v_sin_vencidos boolean :=
    COALESCE(current_setting('app.stock_origen', true), '') = 'cambio_producto';
BEGIN
$r$, '_restaurar_lotes_fefo (declaración)');

  v_def := pg_temp.parche(v_def,
$a$                  ELSE NOT l.solo_traza AND l.cantidad_restante < l.cantidad
             END
$a$,
$r$                  ELSE NOT l.solo_traza AND l.cantidad_restante < l.cantidad
                       -- STK-2 (#1594): el devuelto de un canje en buen estado va a
                       -- un lote vigente con hueco y, si no hay, a la bolsa. Al dar
                       -- de baja un lote vencido se mermaban unidades buenas. La
                       -- primera pasada (vuelve a SU lote por la huella) no cambia
                       -- aunque el lote haya vencido, y la devolucion sin huella de
                       -- un pedido sigue FEFO como siempre: si FEFO mira los
                       -- vencidos es la decision del fork que dejo abierta #1594.
                       AND (NOT v_sin_vencidos OR l.fecha_vencimiento >= public._tablero_hoy())
             END
$r$, '_restaurar_lotes_fefo (segunda pasada)');

  EXECUTE v_def;
END
$parche_restaurar$;

-- =========================================================================
-- 2 · _aplicar_cambio_producto: stock por la diferencia y la merma asentada
--     como merma (1594-b2, 1594-b4)
-- =========================================================================
DO $parche_canje$
DECLARE
  v_def text := pg_get_functiondef('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_merma_motivo TEXT;
$a$,
$r$  v_merma_motivo TEXT;
  v_merma_id BIGINT;
$r$, '_aplicar_cambio_producto (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  IF v_stock_entregado < p_cantidad_entregada THEN
$a$,
$r$  -- 1594-b2 (#1594): el canje del mismo producto que reingresa mueve solo la
  -- diferencia (#1558, STK-20 abajo), asi que pide stock por la diferencia.
  IF v_stock_entregado < (CASE WHEN v_reingresa AND p_producto_devuelto_id = p_producto_entregado_id
                               THEN GREATEST(p_cantidad_entregada - p_cantidad_devuelta, 0)
                               ELSE p_cantidad_entregada END) THEN
$r$, '_aplicar_cambio_producto (stock del mismo producto)');

  v_def := pg_temp.parche(v_def,
$a$      PERFORM set_config('app.stock_origen', 'cambio_producto_merma', true);
      UPDATE productos SET stock = stock + p_cantidad_devuelta
       WHERE id = p_producto_devuelto_id
      RETURNING stock INTO v_stock_dev_now;
      UPDATE productos SET stock = stock - p_cantidad_devuelta
       WHERE id = p_producto_devuelto_id;
      PERFORM set_config('app.stock_origen', 'cambio_producto', true);
      v_merma_motivo := CASE COALESCE(p_motivo,'')
        WHEN 'vencimiento' THEN 'vencimiento'
        WHEN 'rotura' THEN 'rotura'
        ELSE 'decomiso'
      END;
      INSERT INTO mermas_stock (
        producto_id, cantidad, motivo, observaciones,
        stock_anterior, stock_nuevo, usuario_id, sucursal_id
      ) VALUES (
        p_producto_devuelto_id, p_cantidad_devuelta, v_merma_motivo,
        'Cambio: producto devuelto no reingresado al stock (' || COALESCE(p_motivo,'') || ')',
        v_stock_dev_now, v_stock_dev_now - p_cantidad_devuelta, p_usuario_id, p_sucursal_id
      );
$a$,
$r$      -- 1594-b4 (#1594): y la bajada es una merma, como en la merma manual (232),
      -- la salvedad (234) y la cancelacion por falta de stock (269): la subida es
      -- del canje, la fila de la merma nombra el canje y la bajada es 'merma' de
      -- esa fila. 'merma' tampoco esta en la lista blanca: el neto sigue en la
      -- bolsa y los lotes no se mueven.
      PERFORM set_config('app.stock_origen', 'cambio_producto_merma', true);
      UPDATE productos SET stock = stock + p_cantidad_devuelta
       WHERE id = p_producto_devuelto_id
      RETURNING stock INTO v_stock_dev_now;
      v_merma_motivo := CASE COALESCE(p_motivo,'')
        WHEN 'vencimiento' THEN 'vencimiento'
        WHEN 'rotura' THEN 'rotura'
        ELSE 'decomiso'
      END;
      INSERT INTO mermas_stock (
        producto_id, cantidad, motivo, observaciones,
        stock_anterior, stock_nuevo, usuario_id, sucursal_id
      ) VALUES (
        p_producto_devuelto_id, p_cantidad_devuelta, v_merma_motivo,
        'Cambio de producto #' || v_cambio_id || ': producto devuelto no reingresado al stock ('
          || COALESCE(p_motivo,'') || ')',
        v_stock_dev_now, v_stock_dev_now - p_cantidad_devuelta, p_usuario_id, p_sucursal_id
      ) RETURNING id INTO v_merma_id;
      PERFORM set_config('app.stock_origen', 'merma', true);
      PERFORM set_config('app.stock_ref_tipo', 'mermas_stock', true);
      PERFORM set_config('app.stock_ref_id', v_merma_id::TEXT, true);
      UPDATE productos SET stock = stock - p_cantidad_devuelta
       WHERE id = p_producto_devuelto_id;
      PERFORM set_config('app.stock_origen', 'cambio_producto', true);
      PERFORM set_config('app.stock_ref_tipo', 'cambios_productos', true);
      PERFORM set_config('app.stock_ref_id', v_cambio_id::TEXT, true);
$r$, '_aplicar_cambio_producto (merma del devuelto)');

  EXECUTE v_def;
END
$parche_canje$;

-- =========================================================================
-- 3 · cambiar_cliente_pedido: la huella de X, el costo de X, los GUC y la
--     comanda de un canje (STK-1, 1595-b3, 1595-b8, COB-b6)
-- =========================================================================
DO $parche_cambio$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_vuelven         BIGINT[];
BEGIN
$a$,
$r$  v_vuelven         BIGINT[];
  -- STK-1 (#1594): la huella de X, el contador de sus lotes y las lineas nuevas.
  v_foto            JSONB;
  v_lotes_x         BIGINT[];
  v_lotes_antes     JSONB;
  v_lineas_nuevas   BIGINT[];
  -- 1595-b3 (#1595): los GUC de la reatribucion como estaban antes.
  v_guc_previo      TEXT[];
BEGIN
$r$, 'cambiar_cliente_pedido (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  -- La reatribucion no es una venta nueva: el pedido ya cumplio (o no) el
  -- minimo cuando se creo. Ver mig 205.
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  -- mig 389 (#1220): la reatribucion conserva el cargo que el pedido ya tenia.
  PERFORM set_config('app.cargo_envio_forzado',
    COALESCE((SELECT cargo_envio::text FROM pedidos WHERE id = p_pedido_id), '0'), true);
  -- cargo_1_base: y su estado (un no_aplica o un bonificado no renacen gratis).
  PERFORM set_config('app.cargo_envio_estado_forzado',
    COALESCE((SELECT cargo_envio_estado FROM pedidos WHERE id = p_pedido_id), ''), true);

  -- Con 'pedido_nuevo' los pagos NO se desimputan al cancelar el viejo: mas
  -- abajo se reapuntan al pedido nuevo, para que el cobro viaje con la venta.
  -- Sin esto, la desimputacion de la mig 235 se los lleva antes y el UPDATE de
  -- mas abajo no encuentra nada. Con 'cliente_original' esa desimputacion es
  -- justo lo que se quiere: el cobro queda a favor del cliente que pago.
  IF p_destino_pagos = 'pedido_nuevo' THEN
    PERFORM set_config('app.cancelacion_conserva_pagos', '1', true);
  END IF;
$a$,
$r$  -- 1595-b3 (#1595): los GUC de la reatribucion (el minimo, el cargo y los
  -- pagos que viajan) se prenden justo antes de cancelar, y se restauran al salir.
$r$, 'cambiar_cliente_pedido (GUC al empezar)');

  v_def := pg_temp.parche(v_def,
$a$  IF v_pedido.estado IN ('entregado', 'cancelado') THEN
$a$,
$r$  -- 1595-b8 (#1595): la comanda de un canje no es una venta (total 0 por
  -- CAMBIO-01, y sus lineas las arma el canje): se cancelaba y volvia como un
  -- pedido comun del cliente nuevo. Como en la edicion (#1323).
  IF v_pedido.canal = 'cambio' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Un canje no cambia de cliente: cancelalo y registralo de nuevo al cliente correcto');
  END IF;

  IF v_pedido.estado IN ('entregado', 'cancelado') THEN
$r$, 'cambiar_cliente_pedido (comanda de un canje)');

  v_def := pg_temp.parche(v_def,
$a$  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
  IF NOT COALESCE((v_cancel->>'success')::boolean, false) THEN
    RETURN v_cancel;
  END IF;
$a$,
$r$  -- 1595-b3: lo que tenian, para restaurarlo al salir.
  v_guc_previo := ARRAY[current_setting('app.omitir_minimo_pedido', true),
                        current_setting('app.cargo_envio_forzado', true),
                        current_setting('app.cargo_envio_estado_forzado', true),
                        current_setting('app.cancelacion_conserva_pagos', true)];
  -- La reatribucion no es una venta nueva: el pedido ya cumplio (o no) el
  -- minimo cuando se creo. Ver mig 205.
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  -- mig 389 (#1220): la reatribucion conserva el cargo que el pedido ya tenia.
  PERFORM set_config('app.cargo_envio_forzado', COALESCE(v_pedido.cargo_envio::text, '0'), true);
  -- cargo_1_base: y su estado (un no_aplica o un bonificado no renacen gratis).
  PERFORM set_config('app.cargo_envio_estado_forzado', COALESCE(v_pedido.cargo_envio_estado, ''), true);
  -- Con 'pedido_nuevo' los pagos NO se desimputan al cancelar el viejo: mas
  -- abajo se reapuntan al pedido nuevo, para que el cobro viaje con la venta.
  -- Sin esto, la desimputacion de la mig 235 se los lleva antes y el UPDATE de
  -- mas abajo no encuentra nada. Con 'cliente_original' esa desimputacion es
  -- justo lo que se quiere: el cobro queda a favor del cliente que pago.
  IF p_destino_pagos = 'pedido_nuevo' THEN
    PERFORM set_config('app.cancelacion_conserva_pagos', '1', true);
  END IF;

  -- STK-1 (#1594): la cancelacion devuelve cada linea a su lote por su huella y
  -- el alta come primero la bolsa: si la bolsa cambio desde la venta, pasaban
  -- unidades de la bolsa al lote (L1 20, bolsa 20 y X con L1:30 terminaban en
  -- L1 40, bolsa 0 y el nuevo con L1:10). Es el patron de la edicion (#1097): la
  -- devolucion de un camino que deshace y rehace lineas va a la bolsa, y al
  -- final _rehacer_huella_lineas le pone a las lineas nuevas la huella que
  -- cubren. La foto antes de tocar nada, con el predicado de la edicion (la venta
  -- y el regalo que mueve stock), y el contador de cada lote de esa huella,
  -- bloqueado (los productos ya estan tomados arriba: producto antes que lote).
  SELECT public._foto_huella_lineas(array_agg(pi.id)) INTO v_foto
    FROM pedido_items pi
   WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
     AND (NOT COALESCE(pi.es_bonificacion, false)
          OR (pi.promocion_id IS NOT NULL
              AND COALESCE(public._regalo_modo_del_pedido(p_pedido_id, pi.promocion_id, v_sucursal), FALSE)));
  v_lotes_x := ARRAY(SELECT DISTINCT (y->>'lote')::bigint
                       FROM jsonb_array_elements(COALESCE(v_foto, '[]'::jsonb)) e,
                            jsonb_array_elements(COALESCE(e->'lotes', '[]'::jsonb)) y);
  PERFORM 1
     FROM producto_lotes
    WHERE id = ANY(v_lotes_x) AND sucursal_id = v_sucursal
    ORDER BY id
      FOR UPDATE;
  SELECT COALESCE(jsonb_object_agg(id::text, cantidad_restante), '{}'::jsonb) INTO v_lotes_antes
    FROM producto_lotes
   WHERE id = ANY(v_lotes_x) AND sucursal_id = v_sucursal;

  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
  IF NOT COALESCE((v_cancel->>'success')::boolean, false) THEN
    PERFORM set_config('app.omitir_minimo_pedido', COALESCE(v_guc_previo[1], ''), true);
    PERFORM set_config('app.cargo_envio_forzado', COALESCE(v_guc_previo[2], ''), true);
    PERFORM set_config('app.cargo_envio_estado_forzado', COALESCE(v_guc_previo[3], ''), true);
    PERFORM set_config('app.cancelacion_conserva_pagos', COALESCE(v_guc_previo[4], ''), true);
    RETURN v_cancel;
  END IF;

  -- STK-1: lo que la cancelacion le devolvio a cada lote de la huella de X
  -- vuelve a la bolsa, con tope en esa huella (lo que otra cosa le haya devuelto
  -- al mismo lote, como el fardo de un contenedor, no se toca). Solo el
  -- contador del lote: productos.stock no se mueve y el ledger no cambia.
  UPDATE producto_lotes l
     SET cantidad_restante = l.cantidad_restante
           - LEAST(h.huella, l.cantidad_restante - (v_lotes_antes->>l.id::text)::integer)
    FROM (SELECT (y->>'lote')::bigint AS lote, SUM((y->>'cant')::integer) AS huella
            FROM jsonb_array_elements(COALESCE(v_foto, '[]'::jsonb)) e,
                 jsonb_array_elements(COALESCE(e->'lotes', '[]'::jsonb)) y
           GROUP BY 1) h
   WHERE l.id = h.lote
     AND l.sucursal_id = v_sucursal
     AND v_lotes_antes ? l.id::text
     AND l.cantidad_restante > (v_lotes_antes->>l.id::text)::integer;
$r$, 'cambiar_cliente_pedido (foto y cancelación)');

  v_def := pg_temp.parche(v_def,
$a$      v_cadena_nueva := CASE WHEN v_par.cadena IS NOT NULL THEN gen_random_uuid() END;
$a$,
$r$      v_cadena_nueva := CASE WHEN v_par.cadena IS NOT NULL THEN gen_random_uuid() END;
      -- STK-1: la huella de X se reparte por linea de origen, y la clave de un
      -- regalo lleva su cadena: la foto pasa a la cadena nueva.
      IF v_par.cadena IS NOT NULL AND v_foto IS NOT NULL THEN
        v_foto := replace(v_foto::text, v_par.cadena::text, v_cadena_nueva::text)::jsonb;
      END IF;
$r$, 'cambiar_cliente_pedido (cadena en la foto)');

  v_def := pg_temp.parche(v_def,
$a$  -- #1473 (VTA-F-4): la reatribucion no es una venta nueva. crear_pedido_completo
$a$,
$r$  -- STK-1 (#1594): la huella de X sobre las lineas nuevas que movieron stock (la
  -- venta y el regalo que mueve stock, el modo de la foto que el pedido nuevo
  -- heredo arriba). Con los mismos items los lotes, la bolsa y la huella quedan
  -- como antes del cambio; con otros, la regla de la edicion.
  IF v_foto IS NOT NULL AND v_foto <> '[]'::jsonb THEN
    v_lineas_nuevas := ARRAY(
      SELECT pi.id FROM pedido_items pi
       WHERE pi.pedido_id = v_nuevo_id AND pi.sucursal_id = v_sucursal
         AND (NOT COALESCE(pi.es_bonificacion, false)
              OR (pi.promocion_id IS NOT NULL
                  AND COALESCE(public._regalo_modo_del_pedido(v_nuevo_id, pi.promocion_id, v_sucursal), FALSE)))
       ORDER BY pi.id);
    PERFORM public._rehacer_huella_lineas(v_foto, v_lineas_nuevas);
  END IF;

  -- 1595-b8 (#1595): y el costo. crear_pedido_completo pone en cada linea el
  -- costo de hoy; la reatribucion no es una venta nueva, asi que cada linea toma
  -- la foto de costo de la linea mas vieja de X con el mismo producto, combo,
  -- regalo y promo, por la cascada de costo_valuacion (la foto es el snapshot).
  -- Un item que X no tenia queda con el de hoy, como en el alta.
  UPDATE pedido_items n
     SET costo_unitario_al_crear = c.costo
    FROM (SELECT ni.id,
                 public.costo_valuacion(
                   (SELECT o.costo_unitario_al_crear
                      FROM pedido_items o
                     WHERE o.pedido_id = p_pedido_id AND o.sucursal_id = v_sucursal
                       AND o.producto_id = ni.producto_id
                       AND o.combo_id IS NOT DISTINCT FROM ni.combo_id
                       AND COALESCE(o.es_bonificacion, false) = COALESCE(ni.es_bonificacion, false)
                       AND o.promocion_id IS NOT DISTINCT FROM ni.promocion_id
                     ORDER BY o.id
                     LIMIT 1),
                   pr.costo_promedio, pr.costo_real, pr.costo_sin_iva,
                   COALESCE(pr.impuestos_internos, 0)) AS costo
            FROM pedido_items ni
            JOIN productos pr ON pr.id = ni.producto_id AND pr.sucursal_id = ni.sucursal_id
           WHERE ni.pedido_id = v_nuevo_id AND ni.sucursal_id = v_sucursal) c
   WHERE n.id = c.id
     AND n.costo_unitario_al_crear IS DISTINCT FROM c.costo;

  -- #1473 (VTA-F-4): la reatribucion no es una venta nueva. crear_pedido_completo
$r$, 'cambiar_cliente_pedido (huella y costo del pedido nuevo)');

  v_def := pg_temp.parche(v_def,
$a$quedaba atrapado en la boleta: zzz_pedidos_reconciliar_pagos es OF total$a$,
$r$quedaba atrapado en la boleta: trg_pedidos_reconciliar_pagos es OF total$r$,
    'cambiar_cliente_pedido (nombre del trigger, COB-b6)');

  v_def := pg_temp.parche(v_def,
$a$  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,
$a$,
$r$  -- 1595-b3: los GUC de la reatribucion vuelven a lo que tenian.
  -- app.omitir_minimo_venta no: lo lee un trigger diferido, al confirmar.
  PERFORM set_config('app.omitir_minimo_pedido', COALESCE(v_guc_previo[1], ''), true);
  PERFORM set_config('app.cargo_envio_forzado', COALESCE(v_guc_previo[2], ''), true);
  PERFORM set_config('app.cargo_envio_estado_forzado', COALESCE(v_guc_previo[3], ''), true);
  PERFORM set_config('app.cancelacion_conserva_pagos', COALESCE(v_guc_previo[4], ''), true);

  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,
$r$, 'cambiar_cliente_pedido (GUC al salir)');

  EXECUTE v_def;
END
$parche_cambio$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'd148a0c73c22966ca7d77af2ecb14d57', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._restaurar_lotes_fefo(bigint,bigint,integer)', '359fb1708b4385f6947d1127a2b8e439', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._aplicar_cambio_producto(integer,bigint,integer,bigint,integer,text,bigint,uuid,text)', 'aa4807ad2599bbba4c51bab7bfbfa808', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
