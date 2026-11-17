-- =========================================================================
-- NNN · STOCK Y LOTES: EL CAMBIO DE CLIENTE NO MUEVE EL FARDO NI LA BARRA,
--       LOS AJUSTES DE LOTE DEJAN RASTRO Y EL ALTA DE UN PRODUCTO TAMBIÉN
--       (ola 2 del plan #1603, tarjeta B3: 1556-c1 de #1556; 1558-b5, 1558-b6
--        y 1558-b7 de #1558; 1594-b1 de #1594; M3-1 de la revisión de la
--        tarjeta M3 de la ola 1)
--
-- Parcha por ancla cuatro funciones (`cambiar_cliente_pedido`, `ajustar_lote`,
-- `dar_de_baja_lote` y `aplicar_control_stock`), con premisa de md5 sobre el
-- cuerpo vivo del 16/11 (ledger en la 512) y poscondición de md5, definer y
-- ACL; crea una función de trigger (`registrar_alta_stock`) y su trigger sobre
-- `productos`. No cambia tablas, firmas ni grants de nada que exista.
-- Ensayo: scripts/test-stock-lotes-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · M3-1 · EL CAMBIO DE CLIENTE PASABA EL FARDO DEL CONTENEDOR DE LA BOLSA
--     AL LOTE
-- =========================================================================
-- La cancelación de X deshace los bloques de la barra y le devuelve a cada
-- lote el fardo que salió de él (STK-19, `promo_ajustes.lotes_pendientes`); el
-- alta del pedido nuevo vuelve a cerrar los mismos bloques, y su bajada come
-- primero la bolsa. Si la bolsa del contenedor cambió desde la venta, el fardo
-- quedaba en el lote y salía de la bolsa: con un lote de 100 con 49 (el fardo
-- de X ya afuera) y la bolsa en 10, el cambio dejaba el lote en 50 y la bolsa
-- en 9, y el bloque nuevo decía que su fardo salió de la bolsa. Dar de baja
-- ese lote después mermaba 50 en vez de 49. Es STK-1 (#1594, mig 508) para el
-- bloque, y el mismo patrón: lo que la cancelación le devuelve a un lote del
-- contenedor vuelve a la bolsa (sólo el contador del lote: el stock y el
-- ledger no se mueven), y después del alta el bloque nuevo hereda los lotes
-- del que se deshizo: la parte que su bajada sacó de la bolsa pasa a decir el
-- lote de donde salió de verdad. Lo que no se vuelve a cerrar vuelve a su lote.
-- Con los mismos items el contenedor queda como antes del cambio: los lotes,
-- la bolsa y de qué lote salió cada fardo.
-- La edición sin cambios (`actualizar_pedido_items`) tiene la misma deriva y
-- es de otra tarjeta: queda descripta en el informe de la tarjeta B3.
--
-- =========================================================================
-- 2 · 1556-c1 · EL CAMBIO DE CLIENTE DE UN PEDIDO DE UN TRAMO ANTERIOR
--     CONSUMÍA UN FARDO DE MÁS
-- =========================================================================
-- Un pedido de un tramo de fracción anterior al reinicio de la barra
-- (`pedido_promo_reglas.barra_anterior`, #1556) no entra en la barra viva: la
-- cancelación no le resta. Pero el pedido nuevo nacía con foto nueva, sin la
-- marca, y su alta lo sumaba a la barra viva (+4 en el ejemplo de #1556): las
-- mismas unidades contaban dos veces, una en la barra tirada y otra en la viva,
-- y la barra cerraba un fardo de más. Decisión del dueño (D3 del plan de #1603,
-- en #1556): NO se acepta, porque subvalúa el stock; el cambio tiene que ser
-- neto 0. Ahora:
--   · el pedido nuevo hereda la marca de la foto de X (como hereda el resto de
--     la foto desde la 480), así que tampoco entra en la barra viva después: su
--     cancelación, su edición y su salvedad lo tratan como al de X;
--   · lo que el alta le sumó a la barra viva por esas promos se deshace con el
--     mismo motor (`aplicar_uso_promo_acumulador` con la cantidad en negativo):
--     la barra queda donde estaba y, si el alta cerró un bloque, el fardo
--     vuelve a donde salió (su `lotes_pendientes`). Queda el asiento de ida y
--     vuelta en `promo_ajustes` y `mermas_stock` ('promociones' y
--     'promociones_reversion', fuera de los reportes de merma), con el stock
--     neto 0.
-- `crear_pedido_completo` (de otra tarjeta) suma a la barra sin mirar la
-- foto; si algún día dejara de sumar para estas promos, la compensación no
-- corre: se mide la barra antes y después del alta.
--
-- =========================================================================
-- 3 · 1558-b5 · `ajustar_lote` NO DEJABA RASTRO
-- =========================================================================
-- Pasa unidades entre un lote y la bolsa sin mover `productos.stock`, así que
-- el trigger del ledger no escribe nada. Decisión del dueño (D5, en #1558):
-- deja una fila en el historial de stock. La fila es `stock_anterior =
-- stock_nuevo` (el stock no cambia; STK-A sigue cerrando), origen
-- 'ajuste_lote', referencia el lote y el usuario. Un ajuste que no cambia
-- nada no deja fila.
--
-- =========================================================================
-- 4 · 1558-b6 · `dar_de_baja_lote` DE UN LOTE QUE NO VENCIÓ
-- =========================================================================
-- Decisión del dueño (D6, en #1558): se puede dar de baja un lote que no está
-- vencido (rotura, pérdida), con el motivo obligatorio. Vencido es
-- `fecha_vencimiento < _tablero_hoy()`, la regla de `registrar_merma_manual`
-- y del canje (508). El lote vencido sigue igual (motivo opcional, merma
-- 'vencimiento', ledger 'lote_vencido'). El que no venció sin motivo se
-- rechaza con un mensaje; con motivo, la merma va con motivo 'otro' y el texto
-- del usuario, y el ledger con 'lote_baja'. La firma no cambia (el front la
-- llama con `p_observaciones`).
--
-- =========================================================================
-- 5 · 1558-b7 · `aplicar_control_stock` ACEPTABA UN STOCK DE PLANILLA
--     NEGATIVO
-- =========================================================================
-- Validaba que fuera entero, no que fuera >= 0 (el contado ya lo validaba).
-- Un stock de sistema negativo no existe (`productos_stock_no_negativo`): es
-- un error de tipeo, y aplicaba una diferencia de más.
--
-- =========================================================================
-- 6 · 1594-b1 · EL ALTA DE UN PRODUCTO CON STOCK NO DEJABA RENGLÓN EN EL
--     LEDGER
-- =========================================================================
-- `trg_stock_historico` es AFTER UPDATE: el INSERT por REST de la ficha con un
-- stock inicial no dejaba fila, y el producto arrancaba su historia en un
-- stock que no venía de ningún lado. `registrar_alta_stock` (AFTER INSERT,
-- cuando el stock no es 0) deja `0 → stock` con origen 'alta_producto' y
-- referencia el producto. Es DEFINER porque la policy de la ficha
-- (`mt_stock_historico_insert_ficha`) sólo admite 'ajuste_manual', y una
-- función que mueve stock no es INVOKER (migrations/CLAUDE.md); es de
-- trigger: sin EXECUTE para nadie más que postgres y service_role.
--
-- Revertir: volver los cuatro cuerpos a los de la premisa, y
-- `DROP TRIGGER trg_stock_historico_alta ON public.productos;
--  DROP FUNCTION public.registrar_alta_stock();`.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- El único DDL sobre una tabla es el trigger nuevo de `productos` (6): el lock
-- se toma de una vez, al principio y sin esperar (LEEME de la ola 2 de #1603).
LOCK TABLE public.productos IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 16/11 y las piezas con las que se cuenta
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'd148a0c73c22966ca7d77af2ecb14d57'),
    ('public.ajustar_lote(bigint,integer)', 'a4bd01e7eb41d5763475c8b6aa9506e5'),
    ('public.dar_de_baja_lote(bigint,integer,text)', '71a90c229fd74b39d77b0cb4653b8152'),
    ('public.aplicar_control_stock(jsonb,text,uuid)', 'ec063d13c73313dc6f65595c6d2b484b'),
    -- No cambian, pero el arreglo cuenta con ellas como están: el FIFO de un
    -- lote y la lista de contenedores de unas promos.
    ('public._mov_lotes_devolver(bigint,jsonb)', '83ef22b3b0143bf318ead07069ac916e'),
    ('public._contenedores_de_promos(bigint[],bigint)', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF r.h IS NOT NULL AND v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- De otras tarjetas: se mira la forma de lo que se usa, no el md5 (pueden
  -- cambiar por otra cosa en la misma ola).
  --   · el bloque que cierra el motor anota de dónde salió el fardo, con la
  --     parte de la bolsa como {"lote_id": null} (STK-19, mig 492);
  --   · la cancelación sólo deshace la barra de una foto que vale
  --     (`_regalo_barra_vale`, #1324 y #1556).
  IF (SELECT prosrc FROM pg_proc
       WHERE oid = 'public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure)
     NOT LIKE '%jsonb_build_object(''lote_id'', NULL, ''cantidad''%' THEN
    RAISE EXCEPTION 'mig NNN · aplicar_uso_promo_acumulador ya no anota la bolsa como {"lote_id": null}: revisar el paso M3-1';
  END IF;
  IF (SELECT prosrc FROM pg_proc
       WHERE oid = 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure)
     NOT LIKE '%_regalo_barra_vale(p_pedido_id, pi.promocion_id, v_sucursal)%' THEN
    RAISE EXCEPTION 'mig NNN · cancelar_pedido_con_stock ya no deshace la barra sólo con _regalo_barra_vale: revisar el paso 1556-c1';
  END IF;
  IF to_regprocedure('public.registrar_alta_stock()') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · registrar_alta_stock() ya existe';
  END IF;
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
-- 1 y 2 · cambiar_cliente_pedido: el fardo del contenedor (M3-1) y el pedido
--         de un tramo anterior de la barra (1556-c1)
-- =========================================================================
DO $parche_cambio$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_guc_previo      TEXT[];
BEGIN
$a$,
$r$  v_guc_previo      TEXT[];
  -- M3-1 (#1603): los contenedores de las promos, lo que la cancelacion le
  -- devolvio a cada lote suyo y el ultimo bloque de esas promos antes del alta.
  v_conts           BIGINT[];
  v_fardos          JSONB := '[]'::jsonb;
  v_ajuste_max      BIGINT := 0;
  v_bloque          RECORD;
  v_el              JSONB;
  v_nuevos          JSONB;
  v_pend            INT;
  v_toma            INT;
  v_sobra           JSONB;
  -- 1556-c1 (#1556): las promos de X de un tramo anterior de la barra.
  v_tramo_anterior  BIGINT[];
  v_tramo           RECORD;
  v_barra_antes     JSONB;
BEGIN
$r$, 'cambiar_cliente_pedido (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  v_lotes_x := ARRAY(SELECT DISTINCT (y->>'lote')::bigint
                       FROM jsonb_array_elements(COALESCE(v_foto, '[]'::jsonb)) e,
                            jsonb_array_elements(COALESCE(e->'lotes', '[]'::jsonb)) y);
$a$,
$r$  v_lotes_x := ARRAY(SELECT DISTINCT (y->>'lote')::bigint
                       FROM jsonb_array_elements(COALESCE(v_foto, '[]'::jsonb)) e,
                            jsonb_array_elements(COALESCE(e->'lotes', '[]'::jsonb)) y);
  -- M3-1 (#1603): y los lotes de los contenedores de las promos (sus productos
  -- estan en el pre-bloqueo). La cancelacion les devuelve el fardo de cada
  -- bloque que deshace, y abajo esas unidades vuelven a la bolsa.
  v_conts := ARRAY(SELECT c FROM public._contenedores_de_promos(v_promos, v_sucursal) c ORDER BY c);
  v_lotes_x := v_lotes_x || ARRAY(SELECT l.id FROM producto_lotes l
                                   WHERE l.producto_id = ANY(v_conts) AND l.sucursal_id = v_sucursal
                                   ORDER BY l.id);
  -- 1556-c1 (#1556): las promos cuya foto en X es de un tramo anterior de la
  -- barra. La cancelacion no las resta de la barra viva (_regalo_barra_vale).
  v_tramo_anterior := ARRAY(SELECT f.promocion_id FROM pedido_promo_reglas f
                             WHERE f.pedido_id = p_pedido_id AND f.sucursal_id = v_sucursal
                               AND f.barra_anterior
                             ORDER BY f.promocion_id);
$r$, 'cambiar_cliente_pedido (lotes de los contenedores y tramo anterior)');

  v_def := pg_temp.parche(v_def,
$a$     AND v_lotes_antes ? l.id::text
     AND l.cantidad_restante > (v_lotes_antes->>l.id::text)::integer;

  PERFORM quitar_pedido_de_recorridos_activos(p_pedido_id);
$a$,
$r$     AND v_lotes_antes ? l.id::text
     AND l.cantidad_restante > (v_lotes_antes->>l.id::text)::integer;

  -- M3-1 (#1603): lo que la cancelacion le devolvio a un lote del contenedor
  -- (despues de sacarle arriba la huella de las lineas) es el fardo de los
  -- bloques que deshizo. Vuelve a la bolsa, como la huella: el alta vuelve a
  -- cerrar esos bloques y su bajada come primero la bolsa. Abajo, el bloque
  -- nuevo dice de que lote salio. Solo el contador del lote.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'lote_id', l.id, 'producto_id', l.producto_id,
           'cantidad', l.cantidad_restante - (v_lotes_antes->>l.id::text)::integer)
           ORDER BY l.fecha_vencimiento, l.id), '[]'::jsonb)
    INTO v_fardos
    FROM producto_lotes l
   WHERE l.producto_id = ANY(v_conts) AND l.sucursal_id = v_sucursal
     AND v_lotes_antes ? l.id::text
     AND l.cantidad_restante > (v_lotes_antes->>l.id::text)::integer;
  UPDATE producto_lotes l
     SET cantidad_restante = (v_lotes_antes->>l.id::text)::integer
   WHERE l.producto_id = ANY(v_conts) AND l.sucursal_id = v_sucursal
     AND v_lotes_antes ? l.id::text
     AND l.cantidad_restante > (v_lotes_antes->>l.id::text)::integer;
  -- Los bloques que cierre el alta son los de id mayor (las promos estan
  -- tomadas: nadie mas les escribe bloques).
  v_ajuste_max := COALESCE((SELECT max(pa.id) FROM promo_ajustes pa
                             WHERE pa.promocion_id = ANY(v_promos) AND pa.sucursal_id = v_sucursal), 0);
  -- 1556-c1: la barra de las promos de un tramo anterior, para saber si el
  -- alta le sumo.
  IF cardinality(v_tramo_anterior) > 0 THEN
    v_barra_antes := jsonb_build_object(
      'p', (SELECT jsonb_object_agg(pr.id::text, pr.usos_pendientes) FROM promociones pr
             WHERE pr.id = ANY(v_tramo_anterior) AND pr.sucursal_id = v_sucursal),
      'a', (SELECT jsonb_object_agg(pa.id::text, pa.usos_pendientes) FROM promo_acumuladores pa
             WHERE pa.promocion_id = ANY(v_tramo_anterior) AND pa.sucursal_id = v_sucursal));
  END IF;

  PERFORM quitar_pedido_de_recorridos_activos(p_pedido_id);
$r$, 'cambiar_cliente_pedido (el fardo vuelve a la bolsa)');

  v_def := pg_temp.parche(v_def,
$a$  PERFORM set_config('app.cambio_cliente_desde', '', true);
$a$,
$r$  PERFORM set_config('app.cambio_cliente_desde', '', true);

  -- 1556-c1 (#1556, decision del dueño D3 del plan #1603): un pedido de un
  -- tramo anterior de la barra no entra en la barra viva, y la cancelacion no
  -- lo resto de ella. El alta lo sumo (crear_pedido_completo suma todo regalo
  -- de promo): se deshace con el mismo motor, por promo y producto. La barra
  -- queda donde estaba y, si el alta cerro un bloque, el fardo vuelve a donde
  -- salio. Neto 0. Solo si el alta le sumo: se mide la barra.
  IF cardinality(v_tramo_anterior) > 0
     AND (v_barra_antes IS DISTINCT FROM jsonb_build_object(
            'p', (SELECT jsonb_object_agg(pr.id::text, pr.usos_pendientes) FROM promociones pr
                   WHERE pr.id = ANY(v_tramo_anterior) AND pr.sucursal_id = v_sucursal),
            'a', (SELECT jsonb_object_agg(pa.id::text, pa.usos_pendientes) FROM promo_acumuladores pa
                   WHERE pa.promocion_id = ANY(v_tramo_anterior) AND pa.sucursal_id = v_sucursal))
          OR EXISTS (SELECT 1 FROM promo_ajustes pa
                      WHERE pa.promocion_id = ANY(v_tramo_anterior) AND pa.sucursal_id = v_sucursal
                        AND pa.id > v_ajuste_max)) THEN
    FOR v_tramo IN
      SELECT pi.promocion_id, pi.producto_id, SUM(pi.cantidad) AS cantidad
        FROM pedido_items pi
       WHERE pi.pedido_id = v_nuevo_id AND pi.sucursal_id = v_sucursal
         AND COALESCE(pi.es_bonificacion, false)
         AND pi.promocion_id = ANY(v_tramo_anterior)
       GROUP BY 1, 2
       ORDER BY 1, 2
    LOOP
      PERFORM public.aplicar_uso_promo_acumulador(
        v_tramo.promocion_id, v_tramo.producto_id, -v_tramo.cantidad, v_tramo.producto_id,
        v_sucursal, p_usuario_id,
        'Cambio de cliente del pedido #' || p_pedido_id || ' al #' || v_nuevo_id
        || ': tramo anterior de la barra, no entra en la barra viva');
    END LOOP;
  END IF;
$r$, 'cambiar_cliente_pedido (tramo anterior: el alta no suma a la barra)');

  v_def := pg_temp.parche(v_def,
$a$         origen                = o.origen,
         tomada_at             = o.tomada_at
    FROM pedido_promo_reglas o
$a$,
$r$         origen                = o.origen,
         tomada_at             = o.tomada_at,
         -- 1556-c1 (#1556): y la marca del tramo anterior de la barra.
         barra_anterior        = o.barra_anterior
    FROM pedido_promo_reglas o
$r$, 'cambiar_cliente_pedido (la foto hereda la marca)');

  v_def := pg_temp.parche(v_def,
$a$  -- 1595-b8 (#1595): y el costo. crear_pedido_completo pone en cada linea el
$a$,
$r$  -- M3-1 (#1603): el bloque que cerro el alta dice de que lote salio su fardo.
  -- Su bajada comio la bolsa, donde la cancelacion dejo el fardo de los
  -- bloques que deshizo: la parte de la bolsa ({"lote_id": null}) pasa a ser
  -- del lote de donde salio, por contenedor y en el orden de los lotes
  -- (vencimiento, id). Solo cambia la anotacion: los contadores ya estan bien.
  -- Lo que el alta no volvio a cerrar vuelve a su lote. Estas filas solo las
  -- escribe aplicar_uso_promo_acumulador con la promo tomada, y las promos
  -- estan en el pre-bloqueo.
  IF jsonb_array_length(v_fardos) > 0 THEN
    FOR v_bloque IN
      SELECT pa.id, pa.producto_id, pa.lotes_pendientes
        FROM promo_ajustes pa
       WHERE pa.promocion_id = ANY(v_promos) AND pa.sucursal_id = v_sucursal
         AND pa.id > v_ajuste_max
         AND pa.lotes_pendientes IS NOT NULL
       ORDER BY pa.id
    LOOP
      v_nuevos := '[]'::jsonb;
      FOR v_el IN
        SELECT a.x FROM jsonb_array_elements(v_bloque.lotes_pendientes) WITH ORDINALITY AS a(x, ord)
         ORDER BY a.ord
      LOOP
        IF v_el->>'lote_id' IS NOT NULL THEN
          v_nuevos := v_nuevos || jsonb_build_array(v_el);
          CONTINUE;
        END IF;
        v_pend := (v_el->>'cantidad')::int;
        FOR i IN 0 .. jsonb_array_length(v_fardos) - 1 LOOP
          EXIT WHEN v_pend <= 0;
          CONTINUE WHEN (v_fardos->i->>'producto_id')::bigint IS DISTINCT FROM v_bloque.producto_id
                     OR (v_fardos->i->>'cantidad')::int <= 0;
          v_toma := LEAST(v_pend, (v_fardos->i->>'cantidad')::int);
          v_nuevos := v_nuevos || jsonb_build_array(jsonb_build_object(
                        'lote_id', (v_fardos->i->>'lote_id')::bigint, 'cantidad', v_toma));
          v_fardos := jsonb_set(v_fardos, ARRAY[i::text, 'cantidad'],
                                to_jsonb((v_fardos->i->>'cantidad')::int - v_toma));
          v_pend := v_pend - v_toma;
        END LOOP;
        IF v_pend > 0 THEN
          v_nuevos := v_nuevos || jsonb_build_array(jsonb_build_object('lote_id', NULL, 'cantidad', v_pend));
        END IF;
      END LOOP;
      IF v_nuevos IS DISTINCT FROM v_bloque.lotes_pendientes THEN
        UPDATE promo_ajustes SET lotes_pendientes = v_nuevos WHERE id = v_bloque.id;
      END IF;
    END LOOP;
    SELECT jsonb_agg(jsonb_build_object('lote_id', (x->>'lote_id')::bigint, 'cantidad', (x->>'cantidad')::int))
      INTO v_sobra
      FROM jsonb_array_elements(v_fardos) x
     WHERE (x->>'cantidad')::int > 0;
    IF v_sobra IS NOT NULL THEN
      PERFORM public._mov_lotes_devolver(v_sucursal, v_sobra);
    END IF;
  END IF;

  -- 1595-b8 (#1595): y el costo. crear_pedido_completo pone en cada linea el
$r$, 'cambiar_cliente_pedido (el bloque nuevo hereda los lotes)');

  EXECUTE v_def;
END
$parche_cambio$;

-- =========================================================================
-- 3 · ajustar_lote: deja una fila en el historial de stock (1558-b5)
-- =========================================================================
DO $parche_ajustar$
DECLARE
  v_def text := pg_get_functiondef('public.ajustar_lote(bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  UPDATE public.producto_lotes
     SET cantidad_restante = p_cantidad_restante
   WHERE id = p_lote_id;
$a$,
$r$  UPDATE public.producto_lotes
     SET cantidad_restante = p_cantidad_restante
   WHERE id = p_lote_id;

  -- 1558-b5 (#1558, decision del dueño D5): el ajuste pasa unidades entre el
  -- lote y la bolsa sin mover productos.stock, asi que el trigger del ledger
  -- no escribia nada. Deja su fila: el stock no cambia (anterior = nuevo, y
  -- STK-A sigue cerrando), con el lote como referencia y quien lo hizo.
  IF p_cantidad_restante <> v_lote.cantidad_restante THEN
    INSERT INTO public.stock_historico (
      producto_id, stock_anterior, stock_nuevo, origen,
      referencia_tipo, referencia_id, usuario_id, sucursal_id
    ) VALUES (
      v_lote.producto_id, v_stock, v_stock, 'ajuste_lote',
      'producto_lotes', p_lote_id, auth.uid(), v_sucursal
    );
  END IF;
$r$, 'ajustar_lote (fila del ledger)');

  EXECUTE v_def;
END
$parche_ajustar$;

-- =========================================================================
-- 4 · dar_de_baja_lote: el lote que no venció, con motivo (1558-b6)
-- =========================================================================
DO $parche_baja$
DECLARE
  v_def text := pg_get_functiondef('public.dar_de_baja_lote(bigint,integer,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_merma_id    bigint;
BEGIN
$a$,
$r$  v_merma_id    bigint;
  -- 1558-b6 (#1558): si el lote vencio, y el motivo que escribio el usuario.
  v_vencido     boolean;
  v_motivo      text := NULLIF(btrim(COALESCE(p_observaciones, '')), '');
BEGIN
$r$, 'dar_de_baja_lote (declaración)');

  v_def := pg_temp.parche(v_def,
$a$  IF p_cantidad > v_lote.cantidad_restante THEN
$a$,
$r$  -- 1558-b6 (#1558, decision del dueño D6): se puede dar de baja un lote que
  -- no vencio (rotura, perdida), con el motivo obligatorio. Vencido es la
  -- regla de registrar_merma_manual: la fecha ya paso en el dia argentino.
  v_vencido := v_lote.fecha_vencimiento < public._tablero_hoy();
  IF NOT v_vencido AND v_motivo IS NULL THEN
    RAISE EXCEPTION 'Este lote vence el % y todavía no venció: para darlo de baja (por rotura, pérdida u otro motivo) escribí el motivo. Si la pantalla no te lo pide, actualizá la app.',
      to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY');
  END IF;

  IF p_cantidad > v_lote.cantidad_restante THEN
$r$, 'dar_de_baja_lote (el lote que no venció)');

  v_def := pg_temp.parche(v_def,
$a$    v_lote.producto_id, p_cantidad, 'vencimiento',
    COALESCE(NULLIF(btrim(COALESCE(p_observaciones, '')), ''),
             'Lote vencido el ' || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY')),
$a$,
$r$    v_lote.producto_id, p_cantidad,
    -- 1558-b6: el que no vencio no es una merma por vencimiento.
    CASE WHEN v_vencido THEN 'vencimiento' ELSE 'otro' END,
    CASE WHEN v_vencido
         THEN COALESCE(v_motivo, 'Lote vencido el ' || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY'))
         ELSE 'Baja del lote que vence el ' || to_char(v_lote.fecha_vencimiento, 'DD/MM/YYYY')
              || ': ' || v_motivo END,
$r$, 'dar_de_baja_lote (la merma)');

  v_def := pg_temp.parche(v_def,
$a$  PERFORM set_config('app.stock_origen',   'lote_vencido',    true);
$a$,
$r$  PERFORM set_config('app.stock_origen',
                      CASE WHEN v_vencido THEN 'lote_vencido' ELSE 'lote_baja' END, true);
$r$, 'dar_de_baja_lote (el origen del ledger)');

  EXECUTE v_def;
END
$parche_baja$;

-- =========================================================================
-- 5 · aplicar_control_stock: el stock de la planilla no es negativo (1558-b7)
-- =========================================================================
DO $parche_control$
DECLARE
  v_def text := pg_get_functiondef('public.aplicar_control_stock(jsonb,text,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    v_num := (v_ajuste->>'stock_planilla')::numeric;
    IF v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'El stock de la planilla del producto % tiene que ser un número entero, y vino %',
$a$,
$r$    v_num := (v_ajuste->>'stock_planilla')::numeric;
    -- 1558-b7 (#1558): y no negativo, como el contado. Un stock de sistema
    -- negativo no existe (productos_stock_no_negativo): es un error de tipeo, y
    -- la diferencia que se aplicaba era de mas.
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'El stock de la planilla del producto % tiene que ser un entero mayor o igual a 0, y vino %',
$r$, 'aplicar_control_stock (stock de la planilla)');

  EXECUTE v_def;
END
$parche_control$;

-- =========================================================================
-- 6 · el alta de un producto con stock deja su renglón en el ledger (1594-b1)
-- =========================================================================
CREATE FUNCTION public.registrar_alta_stock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- 1594-b1 (#1594): trg_stock_historico es AFTER UPDATE, y el alta por REST de
  -- la ficha con un stock inicial no dejaba fila: la historia del producto
  -- arrancaba en un stock que no venia de ningun lado. DEFINER: la policy de la
  -- ficha (mt_stock_historico_insert_ficha) solo admite 'ajuste_manual'.
  INSERT INTO stock_historico (
    producto_id, stock_anterior, stock_nuevo, origen,
    referencia_tipo, referencia_id, usuario_id, sucursal_id
  ) VALUES (
    NEW.id, 0, NEW.stock, 'alta_producto',
    'productos', NEW.id,
    COALESCE(NULLIF(current_setting('app.stock_user_id', true), '')::uuid, auth.uid()),
    NEW.sucursal_id
  );
  RETURN NULL;
END;
$function$;

-- De trigger: la invoca el executor, no el que llama (CLAUDE.md).
REVOKE ALL ON FUNCTION public.registrar_alta_stock() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_alta_stock() TO service_role;

CREATE TRIGGER trg_stock_historico_alta
  AFTER INSERT ON public.productos
  FOR EACH ROW
  WHEN (NEW.stock IS DISTINCT FROM 0)
  EXECUTE FUNCTION public.registrar_alta_stock();

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', '0237d4b566ba9a30d34c3276eb4dc480', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.ajustar_lote(bigint,integer)', '4da033d4eeaec65dfe45f774ccc9d9b8', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.dar_de_baja_lote(bigint,integer,text)', 'b5f89e656f5341166e034b218819a500', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.aplicar_control_stock(jsonb,text,uuid)', '1de7b4e2272118f1abcf2c6e5f629c5e', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_alta_stock()', 'eecddacbff9d3d54dedc07a0acf0397c', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.productos'::regclass
                    AND tgname = 'trg_stock_historico_alta' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'mig NNN · falta el trigger trg_stock_historico_alta';
  END IF;
END
$post$;

COMMIT;
