-- Anular suma lo suyo (#1140), la resincronizacion de regalos solo mira lo que
-- la salvedad toco (#1141), y el check LOTE-D con el tope de huella que lo hace
-- posible (#1142).
--
-- #1140. anular_salvedad restituia la linea a cantidad_original. Con dos
-- salvedades vivas sobre la misma linea, anular la primera borraba tambien lo
-- que recorto la segunda, que seguia viva; con devolucion, encima subia la
-- linea mas de lo que bajaba el stock, y v_toca_promo evaluaba una cantidad
-- distinta de la que quedaba. En prod: la linea 14159 (salvedades 178 y 179):
-- anular la 178 la dejaba en 3 en vez de 2. Decision del dueño (2026-10-13),
-- opcion A: cada anulacion deshace solo lo suyo, cantidad + cantidad_afectada;
-- sin linea (la salvedad la dejo en 0 y se borro), se reinserta con
-- cantidad_afectada. El resultado no depende del orden en que se anulen.
--
-- #1141. La resincronizacion de registrar_salvedad recorria TODAS las promos
-- con regalo del pedido y recortaba el regalo hasta lo que dan las reglas
-- vigentes: una salvedad sobre X le recortaba el regalo (ya entregado) a una
-- promo ajena o editada, y devolvia a stock unidades que el cliente tiene.
-- Decision del dueño, opcion B: solo las promos que tienen el producto de la
-- salvedad (el alcance de v_toca_promo), ninguna si la salvedad es sobre un
-- regalo, y el recorte con tope en el impacto propio:
-- LEAST(total_bonif - esperado_despues, esperado_antes - esperado_despues).
-- Es una aproximacion con las reglas y los productos VIGENTES (no hay snapshot
-- de la promo en el pedido; issue aparte). Regresion aceptada (decision 3): si
-- sacaron el producto de la promo despues de la venta, una salvedad sobre el ya
-- no recorta ese regalo. Las dos simulaciones de la UI, el mismo alcance y el
-- mismo tope.
--
-- #1142. LOTE-D en auditoria_integridad(), en high: lineas con mas huella en
-- lotes que cantidad. Y el unico camino conocido que la puede violar, que es
-- anular_salvedad: la huella que le repone a la linea por lo que habia vuelto a
-- un lote tenia un tope ((cantidad - restante) - huella de todos) que no limita
-- en un lote con consumo sin huella (9 de 13 en prod). Si el lote se vacio
-- entre registrar y anular, con bolsa 0 la bajada cae por FEFO en otro lote y
-- le escribe otra huella a la linea: 20 unidades, 23 de huella. Ahora la parte
-- devuelta no pasa de lo que efectivamente se le saco al lote (v_saca).
--
-- Exposicion en prod al escribir esto: 0 salvedades anuladas (anular nunca se
-- uso), 1 linea con dos salvedades vivas, 0 pares (pedido, promo) con regalo
-- de mas, LOTE-D en 0. Sin backfill.
--
-- Lo que no se hace (CLAUDE.md, nada de refactors de paso; van a issues):
--   - anular sobre una linea recreada inserta una linea duplicada;
--   - v_toca_promo rechaza de mas (mira promos de las que el pedido nunca
--     tuvo regalo);
--   - anular_salvedad no mira la nota de credito vigente;
--   - el snapshot de reglas y productos de la promo en el pedido.
--   No se agrega ningun UPDATE productos.stock, no cambia ningun origen ni se
--   escribe costo: STK-F, STK-D y COSTO-D no se mueven.
--
-- Funciones parcheadas en vivo, por ancla sobre pg_get_functiondef de prod
-- (cada fragmento tiene que aparecer exactamente una vez o la migracion
-- aborta). Firma, SECURITY DEFINER, STABLE, search_path y GRANTs: como estaban
-- (CREATE OR REPLACE conserva el ACL; la seccion 2 lo compara). Ninguna
-- funcion nueva: no hay REVOKE que hacer.

-- ---------------------------------------------------------------------------
-- 1 - Parches
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.contar(p_def text, p_que text)
RETURNS int LANGUAGE sql AS $fn$
  SELECT (length(p_def) - length(replace(p_def, p_que, ''))) / length(p_que);
$fn$;

-- El ACL de antes, para compararlo despues del parche (seccion 2).
CREATE TEMP TABLE t_acl_antes AS
SELECT p.oid::regprocedure::text AS f, p.proacl::text AS acl
  FROM pg_proc p
 WHERE p.oid IN ('public.anular_salvedad(bigint,text)'::regprocedure,
                 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure,
                 'public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure,
                 'public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure,
                 'public.auditoria_integridad()'::regprocedure);

-- Los GUCs de stock que anular guarda, setea y restaura: el parche no los toca.
CREATE TEMP TABLE t_gucs_antes AS
SELECT pg_temp.contar(d, 'set_config(') AS set_config,
       pg_temp.contar(d, 'current_setting(''app.stock_') AS current_setting
  FROM (SELECT pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure) AS d) x;

DO $anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  -- 1a · #1140: la rama UPDATE suma lo suyo.
  v_def := pg_temp.parchar(v_def,
$q$    UPDATE pedido_items SET
      cantidad = v_salvedad.cantidad_original,
      subtotal = v_salvedad.cantidad_original * v_salvedad.precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
$q$,
$q$    -- #1140 (decision del dueño 2026-10-13, opcion A): se suma lo que ESTA
    -- salvedad saco, no se vuelve a cantidad_original. Con otra salvedad viva
    -- sobre la misma linea, volver al original borraba tambien lo que recorto
    -- la otra (y con devolucion la linea subia mas de lo que bajaba el stock).
    -- Cada anulacion deshace solo lo suyo, asi que el resultado no depende del
    -- orden; y v_toca_promo, arriba, ya mide la linea + cantidad_afectada. En
    -- el SET, `cantidad` es el valor viejo en las dos expresiones; el precio es
    -- el de la fila, que registrar_salvedad no cambia.
    UPDATE pedido_items SET
      cantidad = cantidad + v_salvedad.cantidad_afectada,
      subtotal = (cantidad + v_salvedad.cantidad_afectada) * precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
$q$, '1a');

  -- 1b · #1140: sin linea (estaba en 0), se reinserta lo de esta salvedad.
  v_def := pg_temp.parchar(v_def,
$q$      v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_original,
      v_salvedad.precio_unitario, v_salvedad.cantidad_original * v_salvedad.precio_unitario, v_sucursal,$q$,
$q$      -- #1140: la linea no existe (esta en 0): vuelve lo de esta salvedad.
      v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_afectada,
      v_salvedad.precio_unitario, v_salvedad.cantidad_afectada * v_salvedad.precio_unitario, v_sucursal,$q$, '1b');

  -- 1c · el comentario del minimo de venta.
  v_def := pg_temp.parchar(v_def,
$q$  -- Devolver la linea a su cantidad original no es cargar un pedido nuevo:$q$,
$q$  -- Restituir lo que la salvedad saco no es cargar un pedido nuevo:$q$, '1c');

  -- 1d · #1142: el tope de la huella que se repone por lo devuelto al lote.
  v_def := pg_temp.parchar(v_def,
$q$      -- Tope: la huella de lo que volvio a este lote no pasa lo que el lote
      -- consumio. #1085: la que el cliente perdio sin que las unidades
      -- entraran al lote (sin hueco, o solo para la traza: fueron a la bolsa)
      -- no paso por su contador, y se repone entera.
      v_huella := GREATEST(LEAST(
        LEAST(r_lote.huella, r_lote.devuelto),
$q$,
$q$      -- Tope: la huella de lo que volvio a este lote no pasa lo que el lote
      -- consumio. #1085: la que el cliente perdio sin que las unidades
      -- entraran al lote (sin hueco, o solo para la traza: fueron a la bolsa)
      -- no paso por su contador, y se repone entera.
      -- #1142 (decision del dueño 2026-10-13): y la parte devuelta no pasa de
      -- lo que efectivamente se le saco al lote (v_saca). Lo que el lote ya no
      -- tiene lo cubre la bajada etiquetada de abajo: sale de la bolsa (sin
      -- huella) o por FEFO de otro lote, y ahi _consumir_lotes_fefo le escribe
      -- su propia huella a la linea (app.stock_pedido_item_id = la linea). El
      -- segundo termino del LEAST no alcanza: en un lote con consumo sin huella
      -- (lo comun) no limita nada. Escenario: bolsa 0, el lote se vacio entre
      -- registrar y anular; la linea de 20 quedaba con huella 23 (LOTE-D).
      v_huella := GREATEST(LEAST(
        LEAST(r_lote.huella, r_lote.devuelto, v_saca),
$q$, '1d');

  EXECUTE v_def;
END
$anular$;

DO $salvedad$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  -- 1e · #1141: solo las promos que tienen el producto de la salvedad, y
  -- ninguna si la salvedad es sobre un regalo.
  v_def := pg_temp.parchar(v_def,
$q$       AND pi.promocion_id IS NOT NULL
     GROUP BY pi.promocion_id
  LOOP
$q$,
$q$       AND pi.promocion_id IS NOT NULL
       -- #1141 (decision del dueño 2026-10-13, opcion B): solo las promos que
       -- tienen el producto de la salvedad, el mismo alcance que v_toca_promo
       -- de anular_salvedad. Las otras no cambiaron su cuenta de bloques: lo
       -- que les sobre es deriva (una promo editada despues de la venta) y no
       -- es de esta salvedad. Y ninguna si la salvedad es sobre un regalo: el
       -- regalo ya bajo arriba (aplicar_uso_promo_acumulador) y lo vendido no
       -- cambio.
       AND NOT COALESCE(v_es_bonif, FALSE)
       AND EXISTS (SELECT 1 FROM promocion_productos pp0
                    WHERE pp0.promocion_id = pi.promocion_id
                      AND pp0.producto_id = v_item.producto_id)
     GROUP BY pi.promocion_id
  LOOP
$q$, '1e');

  -- 1f · #1141: el recorte, con tope en el impacto propio.
  v_def := pg_temp.parchar(v_def,
$q$    IF v_expected_bonif < v_promo_sync.total_bonif THEN
      v_exceso := v_promo_sync.total_bonif - v_expected_bonif;
$q$,
$q$    -- #1141: el recorte no pasa de lo que ESTA salvedad le saco a la cuenta
    -- de bloques: esperado antes - esperado despues, con la misma aritmetica
    -- (division entera). v_total_qty ya es la cantidad de despues (la linea ya
    -- se recorto o se borro) y el producto de la salvedad esta en la suma (el
    -- EXISTS de arriba), asi que antes = despues + p_cantidad_afectada. Con
    -- datos coherentes da lo mismo que recortar todo el exceso.
    v_exceso := LEAST(v_promo_sync.total_bonif - v_expected_bonif,
                      ((v_total_qty + p_cantidad_afectada) / v_cant_compra) * v_cant_bonif - v_expected_bonif);
    IF v_exceso > 0 THEN
$q$, '1f');

  -- 1g · lo que queda abierto, escrito sin presentar el tope como exacto.
  v_def := pg_temp.parchar(v_def,
$q$        -- El guard de anular NO es una garantia completa: con mas de una
        -- salvedad sobre la linea, o con una promo editada o ajena que esta
        -- resincronizacion recorta, puede quedar un regalo recortado sin que
        -- anular lo rechace. Son bugs conocidos, con su issue; el camino de alta
        -- de promos (mig 234) es el que tendria que reponer el regalo.
$q$,
$q$        -- Desde #1140/#1141 anular suma solo lo suyo y esta resincronizacion
        -- solo recorta las promos que tienen el producto de la salvedad (el
        -- alcance de v_toca_promo). Pero las dos miden con las reglas y los
        -- productos VIGENTES de la promo, no con los de la venta: el pedido no
        -- guarda un snapshot. Con la promo editada despues de la venta el tope
        -- de arriba es una aproximacion (10+2 -> 10+1 y un rechazo de 10 sobre
        -- 20 deja 3 regalos; con las reglas de la venta serian 2). Y si sacaron
        -- el producto de la promo, una salvedad sobre el ya no recorta ese
        -- regalo, y anular tampoco lo ve. Las dos cosas esperan el snapshot de
        -- reglas y productos (issue aparte); el camino de alta de promos (mig
        -- 234) es el que tendria que reponer el regalo.
$q$, '1g');

  EXECUTE v_def;
END
$salvedad$;

DO $simular$
DECLARE
  v_def text := pg_get_functiondef('public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure);
BEGIN
  -- 1h · #1141, el espejo de registrar_salvedad: solo las promos que tienen el
  -- producto de la linea.
  v_def := pg_temp.parchar(v_def,
$q$    LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
    GROUP BY b.cantidad, b.promocion_id, p.nombre, p.descripcion_regalo
$q$,
$q$    LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
    -- #1141: el alcance de registrar_salvedad (y de v_toca_promo).
    WHERE EXISTS (SELECT 1 FROM promocion_productos pp0
                   WHERE pp0.promocion_id = b.promocion_id
                     AND pp0.producto_id = v_item.producto_id)
    GROUP BY b.cantidad, b.promocion_id, p.nombre, p.descripcion_regalo
$q$, '1h');

  -- 1i · #1141: el corte, con tope en el impacto propio (la aritmetica de
  -- registrar_salvedad: esperado_antes = (post + afectada) / compra * bonif).
  v_def := pg_temp.parchar(v_def,
$q$  SELECT
    pi.promocion_id,
    pi.promo_nombre::TEXT,
    pi.bonif_qty AS bonif_actual,
    (COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif AS bonif_esperada,
    pi.bonif_qty - ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif) AS delta,
    pi.descripcion_regalo,
    ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif) = 0 AS sera_eliminada
  FROM promo_info pi
  LEFT JOIN totales t ON t.promocion_id = pi.promocion_id
  WHERE pi.cant_compra IS NOT NULL AND pi.cant_compra > 0
    AND pi.cant_bonif  IS NOT NULL AND pi.cant_bonif  > 0
    AND pi.bonif_qty > ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif);
$q$,
$q$  SELECT
    c.promocion_id,
    c.promo_nombre,
    c.bonif_actual,
    c.bonif_actual - c.corte AS bonif_esperada,
    c.corte AS delta,
    c.descripcion_regalo,
    (c.bonif_actual - c.corte) = 0 AS sera_eliminada
  FROM (
    SELECT
      pi.promocion_id,
      pi.promo_nombre::TEXT AS promo_nombre,
      pi.bonif_qty AS bonif_actual,
      pi.descripcion_regalo,
      -- #1141: LEAST(bonif - esperado_despues, esperado_antes - esperado_despues).
      -- NULLIF como antes: el orden de evaluacion de los filtros no esta
      -- garantizado si el planner empuja `corte > 0` adentro.
      LEAST(pi.bonif_qty - (COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif,
            ((COALESCE(t.total_qty_post, 0) + p_cantidad_afectada) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif
              - (COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif)::INT AS corte
    FROM promo_info pi
    LEFT JOIN totales t ON t.promocion_id = pi.promocion_id
    WHERE pi.cant_compra IS NOT NULL AND pi.cant_compra > 0
      AND pi.cant_bonif  IS NOT NULL AND pi.cant_bonif  > 0
  ) c
  WHERE c.corte > 0;
$q$, '1i');

  EXECUTE v_def;
END
$simular$;

DO $simular_lote$
DECLARE
  v_def text := pg_get_functiondef('public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure);
BEGIN
  -- 1j · #1141: lo vendido antes, y las promos que la tanda toca.
  v_def := pg_temp.parchar(v_def,
$q$  totales AS (
    SELECT pp.promocion_id, SUM(i.cantidad_post)::INT AS qty_post
      FROM items i
      JOIN promocion_productos pp ON pp.producto_id = i.producto_id
     WHERE NOT i.es_bonif
     GROUP BY pp.promocion_id
  ),
$q$,
$q$  totales AS (
    SELECT pp.promocion_id, SUM(i.cantidad_post)::INT AS qty_post,
           SUM(i.cantidad)::INT AS qty_pre
      FROM items i
      JOIN promocion_productos pp ON pp.producto_id = i.producto_id
     WHERE NOT i.es_bonif
     GROUP BY pp.promocion_id
  ),
  -- #1141: el alcance de registrar_salvedad: las promos que tienen el
  -- producto de alguna linea afectada que no es regalo.
  tocadas AS (
    SELECT DISTINCT pp.promocion_id
      FROM items i
      JOIN afectadas a ON a.item_id = i.id AND a.cant > 0
      JOIN promocion_productos pp ON pp.producto_id = i.producto_id
     WHERE NOT i.es_bonif
  ),
$q$, '1j');

  v_def := pg_temp.parchar(v_def,
$q$           r.cant_compra, r.cant_bonif, t.qty_post,
$q$,
$q$           r.cant_compra, r.cant_bonif, t.qty_post, t.qty_pre,
           (tc.promocion_id IS NOT NULL) AS tocada,
$q$, '1k');

  v_def := pg_temp.parchar(v_def,
$q$      LEFT JOIN totales t ON t.promocion_id = b.promocion_id
     WHERE b.es_bonif
$q$,
$q$      LEFT JOIN totales t ON t.promocion_id = b.promocion_id
      LEFT JOIN tocadas tc ON tc.promocion_id = b.promocion_id
     WHERE b.es_bonif
$q$, '1l');

  -- 1m · #1141: el exceso de la promo, con tope en el impacto de la tanda.
  -- registrar_salvedad recorta salvedad por salvedad, cada una con tope en su
  -- propio impacto; en cadena, el total es LEAST(post - esperado_despues,
  -- esperado_antes - esperado_despues). Supone el orden de
  -- ModalEntregaConSalvedad: primero las salvedades sobre regalos (que no
  -- resincronizan y ya estan en post_promo), despues las demas.
  v_def := pg_temp.parchar(v_def,
$q$                 GREATEST(b.post_promo - (COALESCE(b.qty_post, 0) / b.cant_compra) * b.cant_bonif, 0)
$q$,
$q$                 CASE WHEN b.tocada THEN
                   LEAST(GREATEST(b.post_promo - (COALESCE(b.qty_post, 0) / b.cant_compra) * b.cant_bonif, 0),
                         GREATEST((COALESCE(b.qty_pre, 0) / b.cant_compra) * b.cant_bonif
                                  - (COALESCE(b.qty_post, 0) / b.cant_compra) * b.cant_bonif, 0))
                 ELSE 0 END
$q$, '1m');

  EXECUTE v_def;
END
$simular_lote$;

DO $auditoria$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  -- 1n · #1142: LOTE-D, en high, con la familia LOTE.
  v_def := pg_temp.parchar(v_def,
$q$    ('PROMO-A','high','promo_ajustes:$q$,
$q$    -- #1142: la huella en lotes de una linea no supera su cantidad (#1127, y
    -- el tope de anular_salvedad de la misma migracion). Todos los estados.
    ('LOTE-D','high','lineas de pedido cuya huella en lotes supera la cantidad de la linea (#1142)',
      (SELECT count(*) FROM (SELECT pil.pedido_item_id FROM pedido_item_lotes pil
         JOIN pedido_items pi ON pi.id = pil.pedido_item_id
        GROUP BY pil.pedido_item_id, pi.cantidad HAVING SUM(pil.cantidad) > pi.cantidad) x)),
    ('PROMO-A','high','promo_ajustes:$q$, '1n');

  EXECUTE v_def;
END
$auditoria$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 2 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_anu  text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_sal  text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_sim  text := pg_get_functiondef('public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure);
  v_siml text := pg_get_functiondef('public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure);
  v_sinc text := pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure);
  v_g    record;
  v_aud  jsonb;
  v_guc  text;
  r      record;
BEGIN
  -- anular_salvedad: suma lo suyo en las dos ramas, el tope nuevo, y sigue
  -- SECURITY DEFINER (pedido_items_guard_estado depende de eso).
  IF v_anu NOT LIKE '%SECURITY DEFINER%'
     OR position('cantidad = cantidad + v_salvedad.cantidad_afectada' IN v_anu) = 0
     OR position('cantidad = v_salvedad.cantidad_original' IN v_anu) > 0
     OR position('v_salvedad.cantidad_original,' IN v_anu) > 0
     OR position('v_salvedad.cantidad_afectada * v_salvedad.precio_unitario, v_sucursal,' IN v_anu) = 0
     OR position('LEAST(r_lote.huella, r_lote.devuelto, v_saca)' IN v_anu) = 0
     OR position('GREATEST(r_lote.huella - r_lote.devuelto, 0)' IN v_anu) = 0
     OR position('''salvedad_anulada''' IN v_anu) = 0 THEN
    RAISE EXCEPTION 'anular_salvedad no quedo como se esperaba';
  END IF;
  -- Los 5 GUCs de stock (origen, ref_tipo, ref_id, user_id, pedido_item_id):
  -- los mismos set_config y current_setting que antes, y cada uno se guarda y
  -- se restaura.
  SELECT * INTO v_g FROM t_gucs_antes;
  IF pg_temp.contar(v_anu, 'set_config(') <> v_g.set_config
     OR pg_temp.contar(v_anu, 'current_setting(''app.stock_') <> v_g.current_setting THEN
    RAISE EXCEPTION 'anular_salvedad cambio sus GUCs: set_config % -> %, current_setting % -> %',
      v_g.set_config, pg_temp.contar(v_anu, 'set_config('),
      v_g.current_setting, pg_temp.contar(v_anu, 'current_setting(''app.stock_');
  END IF;
  FOREACH v_guc IN ARRAY ARRAY['stock_origen', 'stock_ref_tipo', 'stock_ref_id', 'stock_user_id',
                               'stock_pedido_item_id'] LOOP
    IF position('current_setting(''app.' || v_guc || ''', true)' IN v_anu) = 0
       OR v_anu !~ ('set_config\(''app\.' || v_guc || ''',\s+COALESCE\(v_g_') THEN
      RAISE EXCEPTION 'anular_salvedad ya no guarda y restaura app.%', v_guc;
    END IF;
  END LOOP;

  -- registrar_salvedad: el filtro antes del LOOP del FOR v_promo_sync, el tope
  -- antes del loop de recorte, y las decisiones de #1126/#1127 intactas.
  IF v_sal NOT LIKE '%SECURITY DEFINER%'
     OR position('pp0.producto_id = v_item.producto_id' IN v_sal) = 0
     OR position('NOT COALESCE(v_es_bonif, FALSE)' IN v_sal) = 0
     OR position('pp0.producto_id = v_item.producto_id' IN v_sal) > position('v_bloques        := v_total_qty' IN v_sal)
     OR position('NOT COALESCE(v_es_bonif, FALSE)' IN v_sal) > position('v_bloques        := v_total_qty' IN v_sal)
     OR position('v_exceso := LEAST(v_promo_sync.total_bonif' IN v_sal) = 0
     OR position('v_exceso := LEAST(v_promo_sync.total_bonif' IN v_sal) > position('FOR v_bonif IN' IN v_sal)
     OR position('IF v_expected_bonif < v_promo_sync.total_bonif' IN v_sal) > 0
     OR position('-- #1126 (decision' IN v_sal) = 0
     OR position('-- #1127 (decision' IN v_sal) = 0
     OR position('EXCEPTION WHEN OTHERS' IN v_sal) = 0 THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;

  -- Las simulaciones: mismo alcance y mismo tope; STABLE y DEFINER, con el
  -- filtro de #1009.
  IF v_sim NOT LIKE '%STABLE SECURITY DEFINER%'
     OR position('pp0.producto_id = v_item.producto_id' IN v_sim) = 0
     OR position('p_cantidad_afectada) / NULLIF(pi.cant_compra, 0)' IN v_sim) = 0
     OR position('puede_leer_pedido' IN v_sim) = 0 THEN
    RAISE EXCEPTION 'simular_salvedad_promo_impacto no quedo como se esperaba';
  END IF;
  IF v_siml NOT LIKE '%STABLE SECURITY DEFINER%'
     OR position('tocadas AS (' IN v_siml) = 0
     OR position('CASE WHEN b.tocada THEN' IN v_siml) = 0
     OR position('puede_leer_pedido' IN v_siml) = 0 THEN
    RAISE EXCEPTION 'simular_salvedades_promo_impacto no quedo como se esperaba';
  END IF;

  -- ACL: identico al de antes; nada para PUBLIC ni anon; authenticated
  -- conserva EXECUTE (son RPCs del front, y auditoria_integridad la llama el
  -- panel del admin).
  FOR r IN SELECT a.f, a.acl, p.proacl::text AS ahora, p.oid
             FROM t_acl_antes a JOIN pg_proc p ON p.oid = a.f::regprocedure LOOP
    IF r.acl IS DISTINCT FROM r.ahora THEN
      RAISE EXCEPTION 'el ACL de % cambio: % -> %', r.f, r.acl, r.ahora;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x
                WHERE p.oid = r.oid
                  AND (x.grantee = 0 OR x.grantee = 'anon'::regrole)) THEN
      RAISE EXCEPTION '% quedo alcanzable por PUBLIC o anon', r.f;
    END IF;
    IF NOT has_function_privilege('authenticated', r.oid, 'EXECUTE') THEN
      RAISE EXCEPTION '% perdio el EXECUTE de authenticated', r.f;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM t_acl_antes) <> 5 THEN
    RAISE EXCEPTION 'falta alguna de las 5 funciones en el ACL de antes';
  END IF;

  -- Una sola sobrecarga de cada una (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname IN ('anular_salvedad', 'registrar_salvedad', 'simular_salvedad_promo_impacto',
                         'simular_salvedades_promo_impacto', 'auditoria_integridad')) <> 5 THEN
    RAISE EXCEPTION 'hay mas de una sobrecarga de alguna de las funciones parcheadas';
  END IF;

  -- auditoria_integridad: ids unicos (la salida es una lista: un id repetido
  -- no falla solo), LOTE-D presente, en high y en 0.
  v_aud := public.auditoria_integridad();
  IF (SELECT count(*) <> count(DISTINCT x->>'id') FROM jsonb_array_elements(v_aud->'checks') x) THEN
    RAISE EXCEPTION 'auditoria_integridad() tiene ids repetidos: %',
      (SELECT string_agg(i, ', ') FROM (SELECT x->>'id' AS i FROM jsonb_array_elements(v_aud->'checks') x
                                         GROUP BY 1 HAVING count(*) > 1) d);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_aud->'checks') x
                  WHERE x->>'id' = 'LOTE-D' AND x->>'severidad' = 'high'
                    AND (x->>'violaciones')::int = 0) THEN
    RAISE EXCEPTION 'LOTE-D no esta en high o no da 0: %',
      (SELECT x FROM jsonb_array_elements(v_aud->'checks') x WHERE x->>'id' = 'LOTE-D');
  END IF;

  -- Si la devolucion de la merma entrara a la lista blanca, la huella bajaria
  -- dos veces (mig 357).
  IF v_sinc LIKE '%''salvedad_merma''%' THEN
    RAISE EXCEPTION 'la lista blanca de sincronizar_lotes_stock cambio: revisar #1127';
  END IF;
END
$verif$;

DROP TABLE t_acl_antes;
DROP TABLE t_gucs_antes;
DROP FUNCTION pg_temp.contar(text, text);

-- ---------------------------------------------------------------------------
-- 3 - Ensayo con datos reales: los casos de
--     scripts/test-salvedad-anular-1140-1142.sql (ver ahi cada uno). La corrida
--     de aca solo aborta si algo falla.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'stock', pr.stock,
    'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                         FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
    'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                    FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int)
    FROM public.productos pr WHERE pr.id = p_prod;
$fn$;

-- Huella de una linea en un lote, o en todos (p_lote NULL).
CREATE OR REPLACE FUNCTION pg_temp.t_huella(p_item bigint, p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes
   WHERE pedido_item_id = p_item AND (p_lote IS NULL OR lote_id = p_lote);
$fn$;

-- Huella de todas las lineas de un producto en un pedido.
CREATE OR REPLACE FUNCTION pg_temp.t_huella_ped(p_ped bigint, p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(pil.cantidad), 0)::int
    FROM public.pedido_item_lotes pil
    JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.pedido_id = p_ped AND pi.producto_id = p_prod;
$fn$;

-- Cantidad de una linea (NULL si ya no existe).
CREATE OR REPLACE FUNCTION pg_temp.t_cant(p_item bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT cantidad FROM public.pedido_items WHERE id = p_item;
$fn$;

-- Lo vendido (no regalo) de un producto en un pedido, sumando sus lineas.
CREATE OR REPLACE FUNCTION pg_temp.t_cant_ped(p_ped bigint, p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND NOT COALESCE(es_bonificacion, false);
$fn$;

-- Regalo de una promo en un pedido, sumando sus lineas.
CREATE OR REPLACE FUNCTION pg_temp.t_regalos(p_ped bigint, p_promo bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_items
   WHERE pedido_id = p_ped AND promocion_id = p_promo AND COALESCE(es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_total(p_ped bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT total FROM public.pedidos WHERE id = p_ped;
$fn$;

-- ¿La salvedad tiene su merma viva?
CREATE OR REPLACE FUNCTION pg_temp.t_merma_viva(p_salv bigint)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.mermas_stock WHERE salvedad_id = p_salv AND anulada_at IS NULL);
$fn$;

-- El predicado de LOTE-D, restringido a un pedido.
CREATE OR REPLACE FUNCTION pg_temp.t_lote_d(p_ped bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT count(*)::int FROM (
    SELECT pil.pedido_item_id
      FROM public.pedido_item_lotes pil
      JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
     WHERE pi.pedido_id = p_ped
     GROUP BY pil.pedido_item_id, pi.cantidad
    HAVING SUM(pil.cantidad) > pi.cantidad) x;
$fn$;

-- Producto con lotes de una compra ([{dias, cantidad, restante}]) y `p_bolsa`
-- unidades sin lote. Devuelve {prod, compra, lotes: [ids en el orden dado]}.
-- Un lote creado con restante < cantidad tiene consumo sin huella: el tope
-- viejo de anular_salvedad no lo limita (#1142).
CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_admin uuid, p_lotes jsonb, p_bolsa int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
  v_id     bigint;
  v_ids    jsonb := '[]'::jsonb;
  l        jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1140', 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;

  FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.t_hoy() + (l->>'dias')::int, (l->>'cantidad')::int,
            (l->>'restante')::int, p_admin, v_compra)
    RETURNING id INTO v_id;
    v_ids := v_ids || to_jsonb(v_id);
  END LOOP;

  RETURN jsonb_build_object('prod', v_prod, 'compra', v_compra, 'lotes', v_ids);
END
$fn$;

-- Pedido con varias lineas ([{prod, cant}], precio 100). Devuelve
-- {pedido, items: {prod: item}}.
CREATE OR REPLACE FUNCTION pg_temp.t_pedido_n(p_cli bigint, p_admin uuid, p_lineas jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT SUM((x->>'cant')::int * 100) FROM jsonb_array_elements(p_lineas) x),
    p_admin,
    (SELECT jsonb_agg(jsonb_build_object('producto_id', (x->>'prod')::bigint, 'cantidad', (x->>'cant')::int,
                                         'precio_unitario', 100))
       FROM jsonb_array_elements(p_lineas) x),
    'ensayo 1140');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'items', (SELECT jsonb_object_agg(producto_id::text, id) FROM public.pedido_items WHERE pedido_id = v_ped));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  p jsonb;
BEGIN
  p := pg_temp.t_pedido_n(p_cli, p_admin, jsonb_build_array(jsonb_build_object('prod', p_prod, 'cant', p_cant)));
  RETURN jsonb_build_object('pedido', p->'pedido', 'item', p->'items'->(p_prod::text));
END
$fn$;

-- Promo "cada p_compra, p_bonif de regalo" sobre p_prods, que mueve stock, con
-- el regalo p_regalo. Devuelve su id.
CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_prods bigint[], p_compra int, p_bonif int,
                                           p_regalo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1140', 'bonificacion', CURRENT_DATE, p_suc, true, p_regalo) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc),
         (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  SELECT v_promo, x, p_suc FROM unnest(p_prods) x;
  RETURN v_promo;
END
$fn$;

-- Edita la bonificacion de una promo despues de la venta (lo que hace
-- updatePromocion).
CREATE OR REPLACE FUNCTION pg_temp.t_editar_bonif(p_promo bigint, p_bonif int)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.promocion_reglas SET valor = p_bonif
   WHERE promocion_id = p_promo AND clave = 'cantidad_bonificacion';
$fn$;

-- Una linea de regalo de `p_n` de `p_prod` para la promo, y su bajada con su
-- linea (como el alta). Devuelve el id de la linea.
CREATE OR REPLACE FUNCTION pg_temp.t_regalo_linea(p_ped bigint, p_promo bigint, p_prod bigint, p_suc bigint, p_n int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_regalo bigint;
BEGIN
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (p_ped, p_prod, p_n, 0, 0, p_suc, true, p_promo) RETURNING id INTO v_regalo;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_regalo::text, true);
  UPDATE public.productos SET stock = stock - p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  RETURN v_regalo;
END
$fn$;

-- registrar_salvedad tal cual (atrapa todo y devuelve success/error).
CREATE OR REPLACE FUNCTION pg_temp.t_salvedad_res(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                   'ensayo 1140: descripcion del caso', NULL, true, NULL);
$fn$;

-- Chequea success: registrar se traga los errores con EXCEPTION WHEN OTHERS.
CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := pg_temp.t_salvedad_res(p_ped, p_item, p_cant, p_motivo);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar %: %', p_motivo, v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_anular(p_salv bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.anular_salvedad(p_salv, 'ensayo 1140');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

-- simular_salvedad_promo_impacto reducido a [[promo, bonif_esperada, delta], ...].
CREATE OR REPLACE FUNCTION pg_temp.t_simular(p_ped bigint, p_item bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_array(s.promocion_id, s.bonif_esperada, s.delta) ORDER BY s.promocion_id),
                  '[]'::jsonb)
    FROM public.simular_salvedad_promo_impacto(p_ped, p_item, p_cant) s;
$fn$;

-- simular_salvedades_promo_impacto, solo las lineas que cambian, reducido a
-- [[linea, cantidad_final], ...].
CREATE OR REPLACE FUNCTION pg_temp.t_simular_lote(p_ped bigint, p_salv jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_array(s.pedido_item_id, s.cantidad_final) ORDER BY s.pedido_item_id),
                  '[]'::jsonb)
    FROM public.simular_salvedades_promo_impacto(p_ped, p_salv) s
   WHERE s.delta > 0;
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote).
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1140', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- Baja stock con un ajuste etiquetado que no es de pedido: come la bolsa y
-- despues los lotes por FEFO, sin huella (no hay linea en el GUC).
CREATE OR REPLACE FUNCTION pg_temp.t_baja(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1140', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  UPDATE public.productos SET stock = stock - p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- El punto de partida de A1-A4: L1 (100, 50 vivas), bolsa 0 al crear, pedido
-- de 20 que sale entero de L1 (huella 20), y despues 40 a la bolsa.
-- Foto {stock 70, lotes [30], bolsa 40}.
CREATE OR REPLACE FUNCTION pg_temp.t_base_l1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_l1 bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
  IF pg_temp.t_foto(v_prod) <> '{"stock":70,"lotes":[30],"bolsa":40}'
     OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 20 THEN
    RAISE EXCEPTION 'punto de partida: foto %, huella %', pg_temp.t_foto(v_prod),
      pg_temp.t_huella((p->>'item')::bigint, v_l1);
  END IF;
  RETURN jsonb_build_object('prod', v_prod, 'l1', v_l1, 'pedido', p->'pedido', 'item', p->'item');
END
$fn$;

-- El punto de partida de R5/R5b/R6/R7b: X con L1 (100, 50 vivas), bolsa 0;
-- pedido de p_cant de X (sale de L1, con huella); promo 10 + 2 sobre X con
-- regalo de X, linea de regalo de p_regalo (tambien de L1, con huella).
-- Despues 40 a la bolsa.
CREATE OR REPLACE FUNCTION pg_temp.t_base_promo(p_cli bigint, p_adm uuid, p_suc bigint, p_cant int, p_regalo int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_promo bigint; v_r bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, p_cant);
  v_promo := pg_temp.t_promo(p_suc, ARRAY[v_prod], 10, 2, v_prod);
  v_r := pg_temp.t_regalo_linea((p->>'pedido')::bigint, v_promo, v_prod, p_suc, p_regalo);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
  IF pg_temp.t_huella((p->>'item')::bigint, NULL) <> p_cant OR pg_temp.t_huella(v_r, NULL) <> p_regalo THEN
    RAISE EXCEPTION 'punto de partida: huella X %, huella R %', pg_temp.t_huella((p->>'item')::bigint, NULL),
      pg_temp.t_huella(v_r, NULL);
  END IF;
  RETURN jsonb_build_object('prod', v_prod, 'pedido', p->'pedido', 'item', p->'item', 'promo', v_promo,
                            'regalo', v_r);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- A1 · #1140. Dos cliente_rechaza 5+5 sobre la linea de 20 (huella 20 en L1).
--      Anular S1 la deja en 15 (no en 20): suma sus 5, que salen de L1. Anular
--      S2 la deja en 20, con la foto, la huella y el total de antes.
CREATE OR REPLACE FUNCTION pg_temp.caso_a1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_ped bigint; v_item bigint; v_s1 bigint; v_s2 bigint;
  f text[] := '{}'; v_f0 jsonb; v_f jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_s1 := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  v_s2 := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 10 AND pg_temp.t_huella(v_item, v_l1) = 10
                       AND v_f = '{"stock":80,"lotes":[40],"bolsa":40}',
                    format('tras S1 y S2: linea %s, huella %s, foto %s; esperado 10, 10, {80,[40],40}',
                           pg_temp.t_cant(v_item), pg_temp.t_huella(v_item, v_l1), v_f));
  PERFORM pg_temp.t_anular(v_s1);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 15,
                    format('anular S1 dejo la linea en %s, esperado 15 (10 + las 5 de S1; S2 sigue viva)',
                           pg_temp.t_cant(v_item)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15 AND v_f = '{"stock":75,"lotes":[35],"bolsa":40}',
                    format('anular S1: huella %s, foto %s; esperado 15 y {75,[35],40} (las 5 salen de L1)',
                           pg_temp.t_huella(v_item, v_l1), v_f));
  PERFORM pg_temp.t_anular(v_s2);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 20 AND v_f = v_f0 AND pg_temp.t_huella(v_item, v_l1) = 20
                       AND pg_temp.t_total(v_ped) = 2000,
                    format('anular S2: linea %s, foto %s (antes %s), huella %s, total %s; esperado 20, f0, 20, 2000',
                           pg_temp.t_cant(v_item), v_f, v_f0, pg_temp.t_huella(v_item, v_l1), pg_temp.t_total(v_ped)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- A2 · #1140, el H7 de la 1126/1127. Dos dañados 5+5: anular S1 deja la linea
--      en 15 y la foto quieta; anular S2 la deja en 20 con huella 20 y las dos
--      mermas anuladas (SALV-A en 0 para estas salvedades).
CREATE OR REPLACE FUNCTION pg_temp.caso_a2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_ped bigint; v_item bigint; v_s1 bigint; v_s2 bigint;
  f text[] := '{}'; v_f0 jsonb; v_f jsonb; v_salv_a int;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_s1 := pg_temp.t_salvedad(v_ped, v_item, 5, 'producto_danado');
  v_s2 := pg_temp.t_salvedad(v_ped, v_item, 5, 'producto_danado');
  PERFORM pg_temp.t_anular(v_s1);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 15 AND v_f = v_f0 AND pg_temp.t_huella(v_item, v_l1) = 15,
                    format('anular S1: linea %s, foto %s (antes %s), huella %s; esperado 15, f0, 15',
                           pg_temp.t_cant(v_item), v_f, v_f0, pg_temp.t_huella(v_item, v_l1)));
  PERFORM pg_temp.t_anular(v_s2);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 20 AND v_f = v_f0 AND pg_temp.t_huella(v_item, v_l1) = 20
                       AND pg_temp.t_total(v_ped) = 2000,
                    format('anular S2: linea %s, foto %s, huella %s, total %s; esperado 20, f0, 20, 2000',
                           pg_temp.t_cant(v_item), v_f, pg_temp.t_huella(v_item, v_l1), pg_temp.t_total(v_ped)));
  SELECT count(*) INTO v_salv_a
    FROM public.mermas_stock m JOIN public.salvedades_items s ON s.id = m.salvedad_id
   WHERE s.id IN (v_s1, v_s2) AND s.estado_resolucion = 'anulada' AND m.anulada_at IS NULL;
  f := pg_temp.t_si(f, NOT pg_temp.t_merma_viva(v_s1) AND NOT pg_temp.t_merma_viva(v_s2) AND v_salv_a = 0,
                    format('quedaron mermas vivas (SALV-A %s)', v_salv_a));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- A3/A4 · #1140 con la linea borrada. S1 rechaza 5 (20 -> 15) y S2 rechaza 15
--      (la linea se borra). Anular reinserta lo de CADA salvedad (5 y 15), no
--      su cantidad_original: suman 20, total 2000, foto f0, huella 20. Quedan
--      dos lineas del mismo producto (issue aparte). p_inverso: S2 primero.
CREATE OR REPLACE FUNCTION pg_temp.t_caso_a34(p_cli bigint, p_adm uuid, p_suc bigint, p_inverso boolean)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s1 bigint; v_s2 bigint;
  f text[] := '{}'; v_f0 jsonb; v_f jsonb; v_primera int;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_s1 := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  v_s2 := pg_temp.t_salvedad(v_ped, v_item, 15, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) IS NULL AND pg_temp.t_cant_ped(v_ped, v_prod) = 0,
                    'la salvedad sobre lo que quedaba no borro la linea');
  PERFORM pg_temp.t_anular(CASE WHEN p_inverso THEN v_s2 ELSE v_s1 END);
  v_primera := CASE WHEN p_inverso THEN 15 ELSE 5 END;
  f := pg_temp.t_si(f, pg_temp.t_cant_ped(v_ped, v_prod) = v_primera
                       AND pg_temp.t_huella_ped(v_ped, v_prod) = v_primera,
                    format('la primera anulacion dejo %s u. con huella %s, esperado %s y %s (lo de esa salvedad)',
                           pg_temp.t_cant_ped(v_ped, v_prod), pg_temp.t_huella_ped(v_ped, v_prod),
                           v_primera, v_primera));
  PERFORM pg_temp.t_anular(CASE WHEN p_inverso THEN v_s1 ELSE v_s2 END);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_cant_ped(v_ped, v_prod) = 20 AND pg_temp.t_total(v_ped) = 2000
                       AND v_f = v_f0 AND pg_temp.t_huella_ped(v_ped, v_prod) = 20,
                    format('tras las dos: %s u., total %s, foto %s (antes %s), huella %s; esperado 20, 2000, f0, 20',
                           pg_temp.t_cant_ped(v_ped, v_prod), pg_temp.t_total(v_ped), v_f, v_f0,
                           pg_temp.t_huella_ped(v_ped, v_prod)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_a3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a34(p_cli, p_adm, p_suc, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_a4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a34(p_cli, p_adm, p_suc, true);
$fn$;

-- A5 · #1140 contra v_toca_promo. Promo 10+2, linea 25, regalo 4. S1 rechaza
--      1 (24, regalo 4) y S2 rechaza 6 (18, regalo 2). Anular S1 deja 19 (no
--      25) y el regalo en 2: v_toca_promo midio 18 + 1, que es lo que queda.
--      Anular S2 se rechaza con anulacion_toca_promociones, sin mover nada.
CREATE OR REPLACE FUNCTION pg_temp.caso_a5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_s1 bigint; v_s2 bigint;
  f text[] := '{}'; v_res jsonb; v_f jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 25, 4);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo';
  v_s1 := pg_temp.t_salvedad(v_ped, v_item, 1, 'cliente_rechaza');
  v_s2 := pg_temp.t_salvedad(v_ped, v_item, 6, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 18 AND pg_temp.t_regalos(v_ped, v_promo) = 2,
                    format('tras S1 y S2: linea %s y regalo %s, esperado 18 y 2',
                           pg_temp.t_cant(v_item), pg_temp.t_regalos(v_ped, v_promo)));
  PERFORM pg_temp.t_anular(v_s1);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 19 AND pg_temp.t_regalos(v_ped, v_promo) = 2,
                    format('anular S1 dejo la linea en %s y el regalo en %s, esperado 19 y 2',
                           pg_temp.t_cant(v_item), pg_temp.t_regalos(v_ped, v_promo)));
  v_f := pg_temp.t_foto(v_prod);
  v_res := public.anular_salvedad(v_s2, 'ensayo 1140');
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false)
                       AND v_res->>'codigo' = 'anulacion_toca_promociones',
                    format('anular S2 tendria que rechazar con anulacion_toca_promociones: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 19 AND pg_temp.t_foto(v_prod) = v_f,
                    format('el rechazo de anular S2 movio algo: linea %s, foto %s (antes %s)',
                           pg_temp.t_cant(v_item), pg_temp.t_foto(v_prod), v_f));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- A6 · #1142, el tope de huella. L1 (vence antes) y L2, los dos con consumo
--      sin huella (100, 50 vivas: el tope viejo no limita). Pedido de 20, que
--      sale de L1 (huella 20). S1 rechaza 5: vuelven a L1 por la huella. Un
--      ajuste que no es de pedido deja L1 en 2. p_bolsa unidades a la bolsa y
--      anular S1:
--        bolsa 0 (A6): a L1 se le sacan 2 (v_saca) y las otras 3 las baja el
--          trigger por FEFO de L2, con huella para la linea. La huella queda en
--          L1 15 + 2 y L2 3: 20 = la linea. Con el tope viejo le reponia 5 en
--          L1 y quedaba en 23.
--        bolsa 40 (A6b): las otras 3 salen de la bolsa. Huella 17, sin L2.
CREATE OR REPLACE FUNCTION pg_temp.t_caso_a6(p_cli bigint, p_adm uuid, p_suc bigint, p_bolsa int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; v_ped bigint; v_item bigint; v_s1 bigint;
  f text[] := '{}'; v_f jsonb; v_esp jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":100,"restante":50},{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0; v_l2 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_ped := p->>'pedido'; v_item := p->>'item';
  IF pg_temp.t_foto(v_prod) <> '{"stock":80,"lotes":[30,50],"bolsa":0}' OR pg_temp.t_huella(v_item, v_l1) <> 20 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', pg_temp.t_foto(v_prod))));
  END IF;
  v_s1 := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  PERFORM pg_temp.t_baja(v_prod, 33);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, p_bolsa);
  v_f := pg_temp.t_foto(v_prod);
  v_esp := jsonb_build_object('stock', 52 + p_bolsa, 'lotes', jsonb_build_array(2, 50), 'bolsa', p_bolsa);
  f := pg_temp.t_si(f, v_f = v_esp AND pg_temp.t_huella(v_item, v_l1) = 15 AND pg_temp.t_cant(v_item) = 15,
                    format('antes de anular: foto %s, huella %s, linea %s; esperado %s, 15, 15', v_f,
                           pg_temp.t_huella(v_item, v_l1), pg_temp.t_cant(v_item), v_esp));
  PERFORM pg_temp.t_anular(v_s1);
  v_f := pg_temp.t_foto(v_prod);
  IF p_bolsa = 0 THEN
    v_esp := '{"stock":47,"lotes":[0,47],"bolsa":0}';
    f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 17 AND pg_temp.t_huella(v_item, v_l2) = 3,
                      format('huella L1 %s / L2 %s, esperado 17 / 3 (con el tope viejo: 20 / 3, total 23)',
                             pg_temp.t_huella(v_item, v_l1), pg_temp.t_huella(v_item, v_l2)));
  ELSE
    v_esp := jsonb_build_object('stock', 47 + p_bolsa, 'lotes', jsonb_build_array(0, 50), 'bolsa', p_bolsa - 3);
    f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 17 AND pg_temp.t_huella(v_item, v_l2) = 0,
                      format('huella L1 %s / L2 %s, esperado 17 / 0',
                             pg_temp.t_huella(v_item, v_l1), pg_temp.t_huella(v_item, v_l2)));
  END IF;
  f := pg_temp.t_si(f, v_f = v_esp AND pg_temp.t_cant(v_item) = 20,
                    format('anular dejo foto %s y linea %s, esperado %s y 20', v_f, pg_temp.t_cant(v_item), v_esp));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, NULL) <= pg_temp.t_cant(v_item) AND pg_temp.t_lote_d(v_ped) = 0,
                    format('la huella de la linea (%s) supera su cantidad (%s): LOTE-D %s',
                           pg_temp.t_huella(v_item, NULL), pg_temp.t_cant(v_item), pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_a6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a6(p_cli, p_adm, p_suc, 0);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_a6b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a6(p_cli, p_adm, p_suc, 40);
$fn$;

-- R4 · #1141, promo ajena editada. Promo A sobre X y B sobre Y, 10+2, que
--      mueven stock, con regalos GA 4 (de X) y GB 4 (de Y) con huella. B se
--      edita a 10+1 despues de la venta. Un rechazo de 1 sobre X recorta GA a
--      2 y deja GB en 4 (antes lo recortaba a 2: la deriva de una promo que la
--      salvedad no toco); Y, su huella y la de GB no se mueven. Las dos
--      simulaciones listan solo A.
CREATE OR REPLACE FUNCTION pg_temp.caso_r4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_x bigint; v_y bigint; p jsonb; v_ped bigint; v_ix bigint; v_iy bigint; v_a bigint; v_b bigint;
  v_ga bigint; v_gb bigint; f text[] := '{}'; v_fy jsonb; v_sim jsonb; v_lote jsonb;
BEGIN
  v_x := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  v_y := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  p := pg_temp.t_pedido_n(p_cli, p_adm, jsonb_build_array(jsonb_build_object('prod', v_x, 'cant', 20),
                                                          jsonb_build_object('prod', v_y, 'cant', 20)));
  v_ped := p->>'pedido'; v_ix := p->'items'->>(v_x::text); v_iy := p->'items'->>(v_y::text);
  v_a := pg_temp.t_promo(p_suc, ARRAY[v_x], 10, 2, v_x);
  v_b := pg_temp.t_promo(p_suc, ARRAY[v_y], 10, 2, v_y);
  v_ga := pg_temp.t_regalo_linea(v_ped, v_a, v_x, p_suc, 4);
  v_gb := pg_temp.t_regalo_linea(v_ped, v_b, v_y, p_suc, 4);
  PERFORM pg_temp.t_a_la_bolsa(v_x, 40);
  PERFORM pg_temp.t_a_la_bolsa(v_y, 40);
  PERFORM pg_temp.t_editar_bonif(v_b, 1);
  v_fy := pg_temp.t_foto(v_y);

  v_sim := pg_temp.t_simular(v_ped, v_ix, 1);
  f := pg_temp.t_si(f, v_sim = jsonb_build_array(jsonb_build_array(v_a, 2, 2)),
                    format('simular_salvedad_promo_impacto %s, esperado solo A: [[A, 2, 2]]', v_sim));
  v_lote := pg_temp.t_simular_lote(v_ped, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ix,
                                                                                 'cantidad_afectada', 1)));
  f := pg_temp.t_si(f, v_lote = jsonb_build_array(jsonb_build_array(v_ga, 2)),
                    format('simular_salvedades_promo_impacto %s, esperado solo GA: [[GA, 2]]', v_lote));

  PERFORM pg_temp.t_salvedad(v_ped, v_ix, 1, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_cant(v_ga) = 2 AND pg_temp.t_cant(v_gb) = 4,
                    format('GA quedo en %s y GB en %s, esperado 2 y 4 (B no tiene X)',
                           pg_temp.t_cant(v_ga), pg_temp.t_cant(v_gb)));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_y) = v_fy AND pg_temp.t_huella(v_gb, NULL) = 4
                       AND pg_temp.t_huella(v_iy, NULL) = 20 AND pg_temp.t_cant(v_iy) = 20,
                    format('Y se movio: foto %s (antes %s), huella GB %s, huella Y %s',
                           pg_temp.t_foto(v_y), v_fy, pg_temp.t_huella(v_gb, NULL), pg_temp.t_huella(v_iy, NULL)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- R5 · #1141, promo propia editada despues de la venta (10+2 -> 10+1), regalo
--      4, linea de 20. Un rechazo de 10 deja el regalo en 3 y la simulacion
--      predice 3. COMPORTAMIENTO CONOCIDO, NO "CORRECTO": el tope mide con las
--      reglas vigentes; con las de la venta serian 2. Cambia a proposito el dia
--      que exista el snapshot de reglas y productos de la promo en el pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_r5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; v_item bigint; v_promo bigint; f text[] := '{}'; v_sim jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo';
  PERFORM pg_temp.t_editar_bonif(v_promo, 1);
  v_sim := pg_temp.t_simular(v_ped, v_item, 10);
  f := pg_temp.t_si(f, v_sim = jsonb_build_array(jsonb_build_array(v_promo, 3, 1)),
                    format('la simulacion dio %s, esperado [[promo, 3, 1]] (aproximacion con reglas vigentes)', v_sim));
  PERFORM pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 3,
                    format('el regalo quedo en %s; el comportamiento conocido es 3 (aproximacion con las reglas '
                           'vigentes: con las de la venta serian 2, hasta que exista el snapshot)',
                           pg_temp.t_regalos(v_ped, v_promo)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- R5b · #1141, decision 3 del dueño. A X lo sacan de la promo con el pedido en
--      ruta. Un rechazo de toda la linea de X deja el regalo en 4 (antes lo
--      recortaba a 0, por accidente), la simulacion no lista nada y anular no
--      lo ve (v_toca_promo filtra igual). COMPORTAMIENTO CONOCIDO: lo arregla el
--      snapshot de reglas y productos de la promo en el pedido (issue aparte).
CREATE OR REPLACE FUNCTION pg_temp.caso_r5b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_s bigint; f text[] := '{}';
  v_sim jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo';
  DELETE FROM public.promocion_productos WHERE promocion_id = v_promo AND producto_id = v_prod;
  v_sim := pg_temp.t_simular(v_ped, v_item, 20);
  f := pg_temp.t_si(f, v_sim = '[]'::jsonb, format('la simulacion dio %s, esperado [] (comportamiento conocido)', v_sim));
  v_s := pg_temp.t_salvedad(v_ped, v_item, 20, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 4,
                    format('el regalo quedo en %s; el comportamiento conocido es 4 (el producto ya no esta en la '
                           'promo: lo arregla el snapshot, issue aparte)', pg_temp.t_regalos(v_ped, v_promo)));
  PERFORM pg_temp.t_anular(v_s);
  f := pg_temp.t_si(f, pg_temp.t_cant_ped(v_ped, v_prod) = 20 AND pg_temp.t_regalos(v_ped, v_promo) = 4,
                    format('anular dejo %s u. y regalo %s, esperado 20 y 4',
                           pg_temp.t_cant_ped(v_ped, v_prod), pg_temp.t_regalos(v_ped, v_promo)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- R6 · #1141, salvedad sobre el regalo con la promo editada (10+2 -> 10+1). Una
--      salvedad de 1 sobre el regalo lo deja en 3, sin recorte extra (antes la
--      resincronizacion lo bajaba a 2 por la deriva). La linea X no se mueve.
CREATE OR REPLACE FUNCTION pg_temp.caso_r6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; v_item bigint; v_promo bigint; v_r bigint; f text[] := '{}'; v_sim jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo'; v_r := b->>'regalo';
  PERFORM pg_temp.t_editar_bonif(v_promo, 1);
  v_sim := pg_temp.t_simular(v_ped, v_r, 1);
  f := pg_temp.t_si(f, v_sim = '[]'::jsonb, format('la simulacion sobre un regalo dio %s, esperado []', v_sim));
  PERFORM pg_temp.t_salvedad(v_ped, v_r, 1, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 3 AND pg_temp.t_cant(v_item) = 20,
                    format('el regalo quedo en %s y X en %s, esperado 3 y 20 (sin recorte extra)',
                           pg_temp.t_regalos(v_ped, v_promo), pg_temp.t_cant(v_item)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- R7a · regresion de #831: el regalo repartido en dos sabores (G1 2 y G2 2,
--       la de G2 mas nueva), datos coherentes. Un rechazo de 10 sobre X de 20
--       recorta 2, de la linea mas nueva hacia atras: G2 se borra, G1 queda en
--       2. Las dos simulaciones lo predicen linea a linea.
CREATE OR REPLACE FUNCTION pg_temp.caso_r7a(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_x bigint; v_g1 bigint; v_g2 bigint; p jsonb; v_ped bigint; v_ix bigint; v_promo bigint;
  v_l1 bigint; v_l2 bigint; f text[] := '{}'; v_sim jsonb; v_lote jsonb;
BEGIN
  v_x  := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  v_g1 := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  v_g2 := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_x, 20);
  v_ped := p->>'pedido'; v_ix := p->>'item';
  v_promo := pg_temp.t_promo(p_suc, ARRAY[v_x], 10, 2, v_g1);
  v_l1 := pg_temp.t_regalo_linea(v_ped, v_promo, v_g1, p_suc, 2);
  v_l2 := pg_temp.t_regalo_linea(v_ped, v_promo, v_g2, p_suc, 2);
  PERFORM pg_temp.t_a_la_bolsa(v_x, 40);
  PERFORM pg_temp.t_a_la_bolsa(v_g1, 40);
  PERFORM pg_temp.t_a_la_bolsa(v_g2, 40);
  v_sim := pg_temp.t_simular(v_ped, v_ix, 10);
  f := pg_temp.t_si(f, v_sim = jsonb_build_array(jsonb_build_array(v_promo, 2, 2)),
                    format('simular_salvedad_promo_impacto %s, esperado [[promo, 2, 2]]', v_sim));
  v_lote := pg_temp.t_simular_lote(v_ped, jsonb_build_array(jsonb_build_object('pedido_item_id', v_ix,
                                                                                 'cantidad_afectada', 10)));
  f := pg_temp.t_si(f, v_lote = jsonb_build_array(jsonb_build_array(v_l2, 0)),
                    format('simular_salvedades_promo_impacto %s, esperado [[G2, 0]]', v_lote));
  PERFORM pg_temp.t_salvedad(v_ped, v_ix, 10, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_cant(v_l2) IS NULL AND pg_temp.t_cant(v_l1) = 2,
                    format('G1 quedo en %s y G2 en %s, esperado 2 y borrada',
                           pg_temp.t_cant(v_l1), pg_temp.t_cant(v_l2)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- R7b · la aritmetica de bloques, con cantidades que no son multiplo. Linea 25,
--       promo 10+2, regalo 4. Rechazo de 4 (25 -> 21, no cruza): corte 0. De 6
--       (25 -> 19): corte 2. De 16 (25 -> 9, cruza dos bloques): corte 4. La
--       simulacion predice lo mismo que hace registrar.
CREATE OR REPLACE FUNCTION pg_temp.caso_r7b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; v_item bigint; v_promo bigint; v_r bigint; f text[] := '{}';
  v_sim jsonb; v_lote jsonb; v_rech int; v_corte int; v_esp jsonb;
BEGIN
  FOR v_rech, v_corte IN SELECT * FROM (VALUES (4, 0), (6, 2), (16, 4)) c(r, k) LOOP
    b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 25, 4);
    v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo'; v_r := b->>'regalo';
    v_sim := pg_temp.t_simular(v_ped, v_item, v_rech);
    v_esp := CASE WHEN v_corte = 0 THEN '[]'::jsonb
                  ELSE jsonb_build_array(jsonb_build_array(v_promo, 4 - v_corte, v_corte)) END;
    f := pg_temp.t_si(f, v_sim = v_esp, format('rechazo %s: la simulacion dio %s, esperado %s', v_rech, v_sim, v_esp));
    v_lote := pg_temp.t_simular_lote(v_ped, jsonb_build_array(jsonb_build_object('pedido_item_id', v_item,
                                                                                   'cantidad_afectada', v_rech)));
    v_esp := CASE WHEN v_corte = 0 THEN '[]'::jsonb
                  ELSE jsonb_build_array(jsonb_build_array(v_r, 4 - v_corte)) END;
    f := pg_temp.t_si(f, v_lote = v_esp,
                      format('rechazo %s: la simulacion por lote dio %s, esperado %s', v_rech, v_lote, v_esp));
    PERFORM pg_temp.t_salvedad(v_ped, v_item, v_rech, 'cliente_rechaza');
    f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 4 - v_corte,
                      format('rechazo %s: el regalo quedo en %s, esperado %s', v_rech,
                             pg_temp.t_regalos(v_ped, v_promo), 4 - v_corte));
    f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0,
                      format('rechazo %s: LOTE-D del pedido: %s', v_rech, pg_temp.t_lote_d(v_ped)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- L1 · #1142, el check muerde. Una huella mayor que la linea suma 1 a LOTE-D
--      (que tiene que existir, en high). El caso se revierte entero.
CREATE OR REPLACE FUNCTION pg_temp.caso_l1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_item bigint; f text[] := '{}'; v0 jsonb; v1 jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_item := b->>'item';
  SELECT x INTO v0 FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x WHERE x->>'id' = 'LOTE-D';
  UPDATE public.pedido_item_lotes SET cantidad = cantidad + 1 WHERE pedido_item_id = v_item;
  SELECT x INTO v1 FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x WHERE x->>'id' = 'LOTE-D';
  f := pg_temp.t_si(f, v0 IS NOT NULL AND v0->>'severidad' = 'high',
                    format('auditoria_integridad() no tiene LOTE-D en high: %s', v0));
  f := pg_temp.t_si(f, (v1->>'violaciones')::int = (v0->>'violaciones')::int + 1,
                    format('LOTE-D no conto la huella de mas: %s -> %s', v0->>'violaciones', v1->>'violaciones'));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1140$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ens1140 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1140 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada,
  -- asi que no deja nada; si alguno falla, la migracion entera aborta.
  FOREACH v_caso IN ARRAY ARRAY['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a6b', 'r4', 'r5', 'r5b', 'r6', 'r7a', 'r7b',
                                'l1'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ens1140 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1140$;

-- Las auxiliares del ensayo no se quedan en la sesion.
DO $limpieza$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS f
      FROM pg_proc p
     WHERE p.pronamespace = pg_my_temp_schema()
       AND (p.proname LIKE 't\_%' OR p.proname LIKE 'caso\_%')
  LOOP
    EXECUTE 'DROP FUNCTION ' || r.f::text;
  END LOOP;
END
$limpieza$;
