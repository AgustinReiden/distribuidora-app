-- NNN · Guardar una promo no vuelve a leer los contenedores con la promo tomada, el FIFO que el cambio de cliente
-- deja suelto es de quien lo cargó, y el riesgo de A2l queda escrito al lado del alta (#1501, puntos 1, 2 y 3).
--
-- QUÉ PASABA
--   1. cambiar_regalo_promocion con p_datos (472) arma la lista de contenedores a pre-bloquear con una lectura
--      sin lock: los de todas las promos y acumuladores de la sucursal, más el regalo y el contenedor viejos. Los
--      toma por id y recién entonces toma la promo. Su UPDATE nombra el factor, así que dispara
--      trg_promo_factor_bloquea_contenedores (de sentencia), que vuelve a leer la lista y la toma FOR UPDATE.
--      Si otra RPC hizo commit de un contenedor nuevo C' entre las dos lecturas, el trigger tomaba C' después
--      de la promo. Una venta con C' y una línea de esta promo toma C' y espera el contenedor de ésta, que
--      ya está tomado: 40P01. El admin veía un error y reintentar funcionaba.
--   2. Cuando un pedido cambia de cliente, el pago a cuenta (FIFO) que tenía la boleta vuelve a quedar suelto,
--      y en _rendicion_pagos un pago suelto es de quien lo cargó, no del chofer de la boleta de la que salió.
--      Nadie lo había decidido, y el encabezado de la 470 no lo decía.
--   3. A2l (463c): la venta toma en su fase 1 las boletas que su crédito alcanza en ese momento. Si mientras
--      espera un producto se anula el pago de una boleta más vieja Z, aplicar_credito_cliente alcanza a Z al
--      final y la pide después; si a la vez una edición de Z toma Z y espera una de las de la fase 1, es un
--      40P01. Medido en el arnés: 100 de 100 con el escenario forzado.
--
-- QUÉ CAMBIA
--   · promo_factor_bloquea_contenedores no hace nada si app.promo_contenedores_tomados no está vacío.
--   · cambiar_regalo_promocion, con p_datos, después de tomar la promo verifica que lo que piden los triggers de
--     fila de su UPDATE ya esté en lo que tomó: el contenedor nuevo, el regalo y el contenedor de la promo (la
--     rotación los vuelve contenedores de su barra) y los contenedores de sus acumuladores, que es lo que lee
--     renormalizar_bloques_por_cambio_factor. Si está todo, pone app.promo_contenedores_tomados sólo durante
--     esa sentencia, que cambia una sola promo, y el trigger de sentencia no vuelve a leer la lista. Si falta
--     algo (otro admin cambió esta misma promo entre la lectura y el lock), el trigger corre como antes.
--     El GUC se limpia apenas termina el UPDATE; si el UPDATE falla, lo deshace el bloque de excepción.
--   · _rendicion_pagos: la decisión del dueño (07/11) queda escrita al lado del código. El FIFO que el cambio
--     de cliente deja suelto es de quien lo cargó, porque el chofer no lo cobró. No cambia ninguna cuenta.
--   · _alta_bloquea_boletas_credito: el riesgo de A2l queda escrito al lado del código, como riesgo aceptado
--     (decisión del dueño, 07/11). Pide tres transacciones del mismo cliente en unos 100 ms, pierde una y
--     reintentar funciona. No cambia ningún lock ni cómo se aplica el saldo a favor.
--
-- UNA CORRECCIÓN A LA 472 (#1504, punto 3)
--   Su encabezado dice que sin p_datos «un bundle viejo del PWA […] sigue andando, igual que hoy». Vale sólo
--   para el bundle que ya llamaba a cambiar_regalo_promocion con cuatro argumentos y después mandaba el resto
--   por REST. Uno anterior, que manda el PATCH de promociones con producto_regalo_id y ajuste_producto_id,
--   recibe 42501 desde la 467, porque authenticated ya no tiene UPDATE sobre esas dos columnas. No rompe
--   datos y se acaba cuando el usuario acepta la actualización.
--
-- QUÉ NO CAMBIA
--   El pre-bloqueo de cambiar_regalo_promocion (la lista y su orden), el camino sin p_datos, el trigger para
--   cualquier otro UPDATE de promociones (REST incluido), renormalizar, la rotación ni los EXECUTE. Son parches
--   por ancla sobre los cuerpos vivos, con premisa de md5.
--
-- Ensayo: scripts/test-promo-contenedores-1501.sql. La ventana se mide con T6o en scripts/concurrencia/.
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
-- Premisas: los cuerpos vivos son los que se leyeron de prod (07/11)
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.promo_factor_bloquea_contenedores()'::regprocedure)
     <> '132df7f62ce68c73171bb7f7190f69bf' THEN
    RAISE EXCEPTION 'mig NNN · promo_factor_bloquea_contenedores cambió en prod desde que se leyó';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)'::regprocedure)
     <> 'b26fc2b93c6180e56e7a1780f69cda36' THEN
    RAISE EXCEPTION 'mig NNN · cambiar_regalo_promocion cambió en prod desde que se leyó';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public._rendicion_pagos(bigint,date,date,bigint)'::regprocedure)
     <> '8f3bf05f8fd2690373baeb4915f62a4c' THEN
    RAISE EXCEPTION 'mig NNN · _rendicion_pagos cambió en prod desde que se leyó';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public._alta_bloquea_boletas_credito(bigint,bigint)'::regprocedure)
     <> '981e18810fe5431f783298c1c81091c7' THEN
    RAISE EXCEPTION 'mig NNN · _alta_bloquea_boletas_credito cambió en prod desde que se leyó';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1a. El trigger de sentencia
-- ---------------------------------------------------------------------------
DO $parche_trg$
DECLARE
  v_def text := pg_get_functiondef('public.promo_factor_bloquea_contenedores()'::regprocedure);
  v_ancla text := $a1$BEGIN
  -- #1460 (C2): un UPDATE de unidades_por_bloque o stock_por_bloque tiene la fila$a1$;
  v_reemplazo text := $r1$BEGIN
  -- #1501: cambiar_regalo_promocion ya tomó, en orden y antes que la promo, lo que piden
  -- los triggers de fila de su UPDATE (que cambia una sola promo), y lo avisa con este GUC
  -- sólo durante esa sentencia. Volver a leer la lista acá, con la promo tomada, era tomar
  -- después de la promo un contenedor que otra RPC sumó en el medio: 40P01 contra una venta.
  IF COALESCE(current_setting('app.promo_contenedores_tomados', true), '') <> '' THEN
    RETURN NULL;
  END IF;

  -- #1460 (C2): un UPDATE de unidades_por_bloque o stock_por_bloque tiene la fila$r1$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · promo_factor_bloquea_contenedores: el ancla aparece % vez/veces', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche_trg$;

-- ---------------------------------------------------------------------------
-- 1b. La RPC: verifica lo que tomó y le avisa al trigger durante su UPDATE
-- ---------------------------------------------------------------------------
DO $parche_rpc$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)'::regprocedure);
  v_anclas text[] := ARRAY[
    $a2$  v_cont_stock   INT;
BEGIN$a2$,
    $a3$  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promoción no encontrada');
  END IF;
$a3$,
    $a4$  BEGIN
    UPDATE promociones
       SET nombre              =$a4$,
    $a5$     WHERE id = p_promocion_id AND sucursal_id = v_sucursal;

    IF v_prod_ids IS NOT NULL THEN$a5$];
  v_reemplazos text[] := ARRAY[
    $r2$  v_cont_stock   INT;
  v_tomados      BOOLEAN := false;
BEGIN$r2$,
    $r3$  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promoción no encontrada');
  END IF;

  -- #1501: lo que piden los triggers de fila del UPDATE de abajo es el contenedor nuevo,
  -- el regalo y el contenedor de la promo (la rotación los vuelve contenedores de su barra)
  -- y los contenedores de sus acumuladores (renormalizar_bloques_por_cambio_factor). Con la
  -- promo tomada nadie más los cambia; si están en lo que se tomó antes, el trigger de
  -- sentencia no tiene que volver a leer la lista de la sucursal. Si falta alguno (otro
  -- admin cambió esta promo entre la lectura y el lock), el trigger corre como antes.
  IF p_datos IS NOT NULL THEN
    v_tomados := NOT EXISTS (
      SELECT 1
        FROM unnest(ARRAY[p_ajuste_producto_id, v_promo.producto_regalo_id, v_promo.ajuste_producto_id]
                    || ARRAY(SELECT a.ajuste_producto_id FROM promo_acumuladores a
                              WHERE a.promocion_id = p_promocion_id AND a.sucursal_id = v_sucursal
                                AND a.ajuste_producto_id IS NOT NULL)) x
       WHERE x IS NOT NULL
         AND x <> ALL (array_remove(v_actualiza, NULL)));
  END IF;
$r3$,
    $r4$  BEGIN
    -- #1501: sólo durante esta sentencia, que cambia una sola promo. Si falla, el bloque
    -- de excepción deshace también el set_config.
    IF v_tomados THEN
      PERFORM set_config('app.promo_contenedores_tomados', p_promocion_id::text, true);
    END IF;
    UPDATE promociones
       SET nombre              =$r4$,
    $r5$     WHERE id = p_promocion_id AND sucursal_id = v_sucursal;
    PERFORM set_config('app.promo_contenedores_tomados', '', true);

    IF v_prod_ids IS NOT NULL THEN$r5$];
  v_n int;
BEGIN
  FOR i IN 1 .. cardinality(v_anclas) LOOP
    v_n := (length(v_def) - length(replace(v_def, v_anclas[i], ''))) / length(v_anclas[i]);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig NNN · cambiar_regalo_promocion: el ancla % aparece % vez/veces', i, v_n;
    END IF;
    v_def := replace(v_def, v_anclas[i], v_reemplazos[i]);
  END LOOP;
  EXECUTE v_def;
END
$parche_rpc$;

-- ---------------------------------------------------------------------------
-- 2. La decisión del FIFO reasignado, al lado del código
-- ---------------------------------------------------------------------------
DO $parche_rend$
DECLARE
  v_def text := pg_get_functiondef('public._rendicion_pagos(bigint,date,date,bigint)'::regprocedure);
  v_ancla text := $a6$   CROSS JOIN LATERAL (SELECT CASE WHEN pg.de_saldo_a_favor THEN pg.usuario_id$a6$;
  v_reemplazo text := $r6$    -- #1501 (decisión del dueño, 07/11): el pago a cuenta (FIFO) que cambiar_cliente_pedido
    -- saca de la boleta y deja suelto, con cualquier destino, es de quien lo cargó, no del
    -- chofer de la boleta de la que salió: el chofer no lo cobró. Si el día de ese chofer
    -- ya está confirmado, la foto lo conserva.
   CROSS JOIN LATERAL (SELECT CASE WHEN pg.de_saldo_a_favor THEN pg.usuario_id$r6$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · _rendicion_pagos: el ancla aparece % vez/veces', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche_rend$;

-- ---------------------------------------------------------------------------
-- 3. El riesgo aceptado de A2l, al lado del código
-- ---------------------------------------------------------------------------
DO $parche_alta$
DECLARE
  v_def text := pg_get_functiondef('public._alta_bloquea_boletas_credito(bigint,bigint)'::regprocedure);
  v_ancla text := $a7$  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_alcanza)
    ORDER BY id
      FOR UPDATE;$a7$;
  v_reemplazo text := $r7$  -- #1501 (A2l, decisión del dueño 07/11): riesgo aceptado. La lista es la de ahora. Si
  -- mientras la venta espera un producto se anula el pago de una boleta más vieja Z (id
  -- menor), aplicar_credito_cliente alcanza a Z al final y la pide después de éstas; si a la
  -- vez una edición de Z toma Z y espera una de éstas, es un 40P01 (A2l en
  -- scripts/concurrencia: 100 de 100 forzado). Pide tres transacciones del mismo cliente en
  -- unos 100 ms, pierde una y reintentar funciona: no rompe datos. Saltear la boleta trabada
  -- (SKIP LOCKED) rompería el FIFO en esa carrera, y tomar acá todas las boletas del cliente
  -- pondría en fila a las cajas de un cliente genérico.
  PERFORM 1
     FROM pedidos
    WHERE id = ANY(v_alcanza)
    ORDER BY id
      FOR UPDATE;$r7$;
  v_n int;
BEGIN
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · _alta_bloquea_boletas_credito: el ancla aparece % vez/veces', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche_alta$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT f.firma, f.md5, f.acl, md5(p.prosrc) AS h, p.proacl::text AS a
      FROM (VALUES
        ('public.promo_factor_bloquea_contenedores()', '859e10cd31a27610ef43c5b1b6f63eb7',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', '582dae61b953871c538470ccd69ce394',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public._rendicion_pagos(bigint,date,date,bigint)', '25f0aebcefe469fdc1a6e5205ea83efa',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public._alta_bloquea_boletas_credito(bigint,bigint)', '68fd4baf367b2074f95bb7be2ec97792',
         '{postgres=X/postgres,service_role=X/postgres}')
      ) AS f(firma, md5, acl)
      JOIN pg_proc p ON p.oid = f.firma::regprocedure
  LOOP
    IF r.h <> r.md5 OR r.a IS DISTINCT FROM r.acl THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %)', r.firma, r.h, r.a;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
