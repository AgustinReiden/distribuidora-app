-- Salvedades y promos: la foto de la promo en el pedido (#1164, #1162), la
-- linea que anular reasocia (#1161) y la nota de credito vigente (#1163).
--
-- #1164: registrar_salvedad, anular_salvedad y las dos simulaciones median el
-- regalo contra las reglas y los productos VIGENTES de la promo. Con la promo
-- editada despues de la venta (10+2 -> 10+1) un rechazo de 10 sobre 20 dejaba
-- 3 regalos en vez de 2; y si sacaban el producto de la promo, la salvedad ya
-- no recortaba el regalo y anular no lo veia (R5 y R5b de
-- scripts/test-salvedad-anular-1140-1142.sql). Decision del dueño
-- (2026-10-14, opcion A): una tabla por pedido x promo, pedido_promo_reglas,
-- que llena un trigger AFTER INSERT sobre pedido_items cuando entra una linea
-- de regalo. La foto se rehace cuando el regalo de la promo se vuelve a armar
-- desde cero: en el alta y en cada edicion (actualizar_pedido_items borra y
-- reinserta todas las lineas, y el modal de edicion recalcula el regalo con
-- la regla vigente). No se rehace al agregar una parte con otro regalo de la
-- promo vivo (dividir_regalo_pedido). Las cuatro funciones leen
-- promos_del_pedido(pedido): la foto, y sin foto lo vigente.
--
-- #1162: v_toca_promo de anular recorria todas las promos de la sucursal que
-- tienen el producto, tambien las que el pedido nunca tuvo (una promo creada
-- despues de la venta rechazaba la anulacion). Ahora mira solo las promos de
-- la foto del pedido. Backfill (decision del dueño: si): los pares con regalo
-- vivo y tambien los regalos ya borrados, que solo quedan en audit_logs (casi
-- siempre los borro la propia salvedad: es justo lo que v_toca_promo tiene que
-- seguir protegiendo). Con las reglas vigentes: no hay historia de
-- promocion_reglas ni de promocion_productos, y lo vigente coincide con lo
-- entregado en al menos el 99,7% de los pares.
--
-- #1161 (decision del dueño, opcion A): sin linea viva, anular buscaba nada y
-- reinsertaba siempre, aunque el pedido ya tuviera otra linea del producto (la
-- que reinserto otra anulacion). Ahora suma a la linea con la clave completa
-- (producto, si es regalo, promo y mismo precio), y si no hay, inserta como
-- antes. Dos rechazos nuevos antes de tocar nada: 'pedido_editado' (una
-- edicion de items posterior a la salvedad ya fijo las cantidades; sumar lo
-- restituiria dos veces) y la salvedad vieja a precio 0 con es_bonificacion
-- NULL (un regalo de antes de 2026-09-09: reinsertarla como venta tiraba
-- check_violation). En prod los 5 casos vivos sin linea y con otra del
-- producto (salvedades 56, 57, 132, 271 editadas despues y 264 regalo viejo)
-- pasan a rechazarse en vez de duplicar o sumar de mas. No tienen salida en
-- la app: el pedido entregado no se edita.
--
-- #1163: el guard de nota de credito vigente de registrar_salvedad (mig 276)
-- tambien en anular, despues del lock del pedido.
--
-- No se agrega ningun UPDATE productos.stock, ningun origen ni GUC, ni se
-- escribe costo: STK-F, STK-D y COSTO-D no se mueven (la seccion 6 lo compara).
--
-- Parche por ancla sobre pg_get_functiondef de PROD (cada fragmento tiene que
-- aparecer exactamente una vez o la migracion aborta), como la 365. Firmas,
-- SECURITY DEFINER, STABLE, search_path y permisos de las cuatro funciones:
-- como estaban (CREATE OR REPLACE conserva el ACL; la seccion 6 lo compara).

-- ---------------------------------------------------------------------------
-- 1 - La foto (#1164)
-- ---------------------------------------------------------------------------

-- La leen y la escriben solo funciones SECURITY DEFINER (el trigger, las
-- cuatro de salvedades): RLS sin policies y nada para anon ni authenticated.
-- El CASCADE hacia promociones acompaña al ON DELETE SET NULL (promocion_id)
-- de pedido_items: si la promo se borra, el regalo pierde su promo y la foto
-- no tiene a quien servir. Sin identity ni serial: no hay secuencia.
CREATE TABLE public.pedido_promo_reglas (
  pedido_id             bigint      NOT NULL,
  promocion_id          bigint      NOT NULL,
  sucursal_id           bigint      NOT NULL,
  cantidad_compra       integer,
  cantidad_bonificacion integer,
  regalo_mueve_stock    boolean     NOT NULL DEFAULT false,
  productos             bigint[]    NOT NULL,
  origen                text        NOT NULL CHECK (origen IN ('trigger', 'backfill_vivo', 'backfill_audit')),
  tomada_at             timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (pedido_id, promocion_id),
  FOREIGN KEY (pedido_id, sucursal_id) REFERENCES public.pedidos (id, sucursal_id) ON DELETE CASCADE,
  FOREIGN KEY (promocion_id, sucursal_id) REFERENCES public.promociones (id, sucursal_id) ON DELETE CASCADE
);
ALTER TABLE public.pedido_promo_reglas ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pedido_promo_reglas FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2 - Helpers (solo de server: los llaman funciones definer)
-- ---------------------------------------------------------------------------

-- Las reglas y los productos vigentes de una promo, en la forma de la foto.
CREATE FUNCTION public._promo_reglas_vigentes(p_promocion_id bigint)
RETURNS TABLE (cantidad_compra integer, cantidad_bonificacion integer,
               regalo_mueve_stock boolean, productos bigint[])
LANGUAGE sql STABLE
SET search_path = public
AS $fn$
  SELECT (SELECT MAX(CASE WHEN r.clave = 'cantidad_compra' THEN r.valor END)::int
            FROM promocion_reglas r WHERE r.promocion_id = p.id),
         (SELECT MAX(CASE WHEN r.clave = 'cantidad_bonificacion' THEN r.valor END)::int
            FROM promocion_reglas r WHERE r.promocion_id = p.id),
         COALESCE(p.regalo_mueve_stock, false),
         ARRAY(SELECT pp.producto_id FROM promocion_productos pp
                WHERE pp.promocion_id = p.id ORDER BY 1)
    FROM promociones p
   WHERE p.id = p_promocion_id;
$fn$;

-- Las promos de un pedido con las reglas y los productos con los que hay que
-- medir su regalo: la foto (pedido_promo_reglas) y, para una linea de regalo
-- viva sin foto, lo vigente.
CREATE FUNCTION public.promos_del_pedido(p_pedido_id bigint)
RETURNS TABLE (promocion_id bigint, cantidad_compra integer, cantidad_bonificacion integer,
               regalo_mueve_stock boolean, productos bigint[])
LANGUAGE sql STABLE
SET search_path = public
AS $fn$
  SELECT f.promocion_id, f.cantidad_compra, f.cantidad_bonificacion, f.regalo_mueve_stock, f.productos
    FROM pedido_promo_reglas f
   WHERE f.pedido_id = p_pedido_id
  UNION ALL
  SELECT s.promocion_id, v.cantidad_compra, v.cantidad_bonificacion, v.regalo_mueve_stock, v.productos
    FROM (SELECT DISTINCT pi.promocion_id
            FROM pedido_items pi
           WHERE pi.pedido_id = p_pedido_id
             AND COALESCE(pi.es_bonificacion, false)
             AND pi.promocion_id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pedido_promo_reglas f2
                              WHERE f2.pedido_id = p_pedido_id
                                AND f2.promocion_id = pi.promocion_id)) s
   CROSS JOIN LATERAL public._promo_reglas_vigentes(s.promocion_id) v;
$fn$;

REVOKE ALL ON FUNCTION public._promo_reglas_vigentes(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.promos_del_pedido(bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3 - El trigger que toma la foto
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER como audit_log_changes: la foto no depende de quien
-- inserta la linea. Funcion de trigger: no necesita EXECUTE para nadie.
CREATE FUNCTION public.capturar_promo_del_pedido()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT COALESCE(NEW.es_bonificacion, false) OR NEW.promocion_id IS NULL THEN
    RETURN NULL;
  END IF;
  /* #1164 (decision del dueño 2026-10-14, opcion A). La foto se rehace solo
     para la primera linea de regalo de la promo cuando no habia otra viva
     antes (o.id < NEW.id): pasa en el alta y en la edicion, que borra todo y
     reinserta, o sea en CADA edicion, con las reglas vigentes (el modal de
     edicion recalcula el regalo con esas mismas reglas). No pasa en
     dividir_regalo_pedido, que actualiza la linea original e inserta las
     partes. Con un INSERT de varias filas da lo mismo: el AFTER ROW ve todas
     las filas de la sentencia. El trigger no borra fotos: una edicion que deja
     el pedido sin regalo de la promo conserva la foto (del lado seguro:
     v_toca_promo puede rechazar de mas). */
  INSERT INTO pedido_promo_reglas (pedido_id, promocion_id, sucursal_id, cantidad_compra,
                                   cantidad_bonificacion, regalo_mueve_stock, productos, origen)
  SELECT NEW.pedido_id, NEW.promocion_id, NEW.sucursal_id,
         v.cantidad_compra, v.cantidad_bonificacion, v.regalo_mueve_stock, v.productos, 'trigger'
    FROM public._promo_reglas_vigentes(NEW.promocion_id) v
  ON CONFLICT (pedido_id, promocion_id) DO UPDATE
     SET cantidad_compra       = EXCLUDED.cantidad_compra,
         cantidad_bonificacion = EXCLUDED.cantidad_bonificacion,
         regalo_mueve_stock    = EXCLUDED.regalo_mueve_stock,
         productos             = EXCLUDED.productos,
         origen                = 'trigger',
         tomada_at             = now()
   WHERE NOT EXISTS (SELECT 1 FROM pedido_items o
                      WHERE o.pedido_id = NEW.pedido_id
                        AND o.id < NEW.id
                        AND COALESCE(o.es_bonificacion, false)
                        AND o.promocion_id = NEW.promocion_id);
  RETURN NULL;
END
$fn$;

REVOKE ALL ON FUNCTION public.capturar_promo_del_pedido() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_capturar_promo_del_pedido
  AFTER INSERT ON public.pedido_items
  FOR EACH ROW EXECUTE FUNCTION public.capturar_promo_del_pedido();

-- ---------------------------------------------------------------------------
-- 4 - Backfill (despues del trigger: lo que entre mientras tanto ya tiene foto)
-- ---------------------------------------------------------------------------

DO $backfill$
DECLARE
  v_vivo  int;
  v_audit int;
  v_falta int;
BEGIN
  -- a · los pares con una linea de regalo viva.
  INSERT INTO public.pedido_promo_reglas (pedido_id, promocion_id, sucursal_id, cantidad_compra,
                                          cantidad_bonificacion, regalo_mueve_stock, productos, origen)
  SELECT DISTINCT pi.pedido_id, pi.promocion_id, pi.sucursal_id,
         v.cantidad_compra, v.cantidad_bonificacion, v.regalo_mueve_stock, v.productos, 'backfill_vivo'
    FROM public.pedido_items pi
   CROSS JOIN LATERAL public._promo_reglas_vigentes(pi.promocion_id) v
   WHERE COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
  ON CONFLICT (pedido_id, promocion_id) DO NOTHING;
  GET DIAGNOSTICS v_vivo = ROW_COUNT;

  -- b · #1162: los regalos ya borrados, que solo quedan en audit_logs (se lee
  -- aca una sola vez). El pedido y la promo tienen que existir y ser de la
  -- misma sucursal; las filas viejas de audit_logs sin sucursal_id toman la
  -- del pedido.
  INSERT INTO public.pedido_promo_reglas (pedido_id, promocion_id, sucursal_id, cantidad_compra,
                                          cantidad_bonificacion, regalo_mueve_stock, productos, origen)
  SELECT DISTINCT p.id, q.id, p.sucursal_id,
         v.cantidad_compra, v.cantidad_bonificacion, v.regalo_mueve_stock, v.productos, 'backfill_audit'
    FROM public.audit_logs a
    JOIN public.pedidos p
      ON p.id = (a.old_data->>'pedido_id')::bigint
     AND (a.old_data->>'sucursal_id' IS NULL OR p.sucursal_id = (a.old_data->>'sucursal_id')::bigint)
    JOIN public.promociones q
      ON q.id = (a.old_data->>'promocion_id')::bigint AND q.sucursal_id = p.sucursal_id
   CROSS JOIN LATERAL public._promo_reglas_vigentes(q.id) v
   WHERE a.tabla = 'pedido_items' AND a.accion = 'DELETE'
     AND COALESCE((a.old_data->>'es_bonificacion')::boolean, false)
     AND a.old_data->>'promocion_id' IS NOT NULL
  ON CONFLICT (pedido_id, promocion_id) DO NOTHING;
  GET DIAGNOSTICS v_audit = ROW_COUNT;

  RAISE NOTICE 'pedido_promo_reglas: % fotos de regalos vivos, % de regalos borrados (audit_logs)',
    v_vivo, v_audit;

  SELECT count(*) INTO v_falta
    FROM public.pedido_items pi
   WHERE COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.pedido_promo_reglas f
                      WHERE f.pedido_id = pi.pedido_id AND f.promocion_id = pi.promocion_id);
  IF v_falta > 0 THEN
    RAISE EXCEPTION 'quedaron % lineas de regalo vivas sin foto', v_falta;
  END IF;
END
$backfill$;

-- ---------------------------------------------------------------------------
-- 5 - Parches
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

CREATE TEMP TABLE t_antes AS
SELECT p.oid::regprocedure::text AS f,
       p.proacl::text AS acl,
       pg_temp.contar(pg_get_functiondef(p.oid), 'set_config(') AS set_config,
       pg_temp.contar(pg_get_functiondef(p.oid), 'current_setting(''app.stock_') AS current_setting,
       pg_temp.contar(pg_get_functiondef(p.oid), 'UPDATE productos') AS updates_productos
  FROM pg_proc p
 WHERE p.oid IN ('public.anular_salvedad(bigint,text)'::regprocedure,
                 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure,
                 'public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure,
                 'public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure);

-- 5a · anular_salvedad
DO $anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  -- #1163 y #1161: despues del rechazo pedido_cancelado (y del lock del pedido).
  v_def := pg_temp.parchar(v_def,
$q$      'codigo', 'pedido_cancelado'
    );
  END IF;
$q$,
$q$      'codigo', 'pedido_cancelado'
    );
  END IF;

  -- #1163: lo mismo que registrar_salvedad (mig 276). Despues del lock del
  -- pedido: una NC concurrente (crear_nota_credito_venta_impl hace FOR UPDATE
  -- del pedido) espera o ya se ve. nota_credito_vigente_de_pedido no es
  -- definer: la ve porque esta funcion lo es.
  IF public.nota_credito_vigente_de_pedido(v_salvedad.pedido_id) IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido tiene la nota de crédito #' || public.nota_credito_vigente_de_pedido(v_salvedad.pedido_id)
      || ' vigente: anulala primero', 'codigo', 'nota_credito_vigente');
  END IF;

  -- #1161: una edicion de items posterior ya fijo las cantidades (y borro la
  -- linea: pedido_item_id queda NULL). Sumar lo de la salvedad lo restituiria
  -- dos veces. Solo actualizar_pedido_items escribe 'items' en
  -- pedido_historial (registrar_salvedad y anular no), asi que una segunda
  -- salvedad no bloquea. El pedido ya entregado no se puede editar: no hay
  -- salida en la app.
  IF EXISTS (SELECT 1 FROM pedido_historial h
              WHERE h.pedido_id = v_salvedad.pedido_id AND h.sucursal_id = v_sucursal
                AND h.campo_modificado = 'items' AND h.created_at > v_salvedad.created_at) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'El pedido se editó después de esta salvedad: la edición ya fijó las cantidades y anular sumaría de nuevo lo que la salvedad sacó. Ese camino no existe todavía: corregir a mano.',
      'codigo', 'pedido_editado');
  END IF;
$q$, '5a');

  -- #1161: el regalo viejo, despues del guard de regalo de la 234.
  v_def := pg_temp.parchar(v_def,
$q$ese camino no existe todavia: corregir a mano.',
      'codigo', 'anulacion_toca_promociones'
    );
  END IF;
$q$,
$q$ese camino no existe todavia: corregir a mano.',
      'codigo', 'anulacion_toca_promociones'
    );
  END IF;

  -- #1161: antes de 2026-09-09 la salvedad no guardaba es_bonificacion (183
  -- en NULL). Una a precio 0 es un regalo (la 264): reinsertarla como venta
  -- tira check_violation y fusionarla se lo cobraria al cliente.
  IF v_salvedad.es_bonificacion IS NULL AND v_salvedad.precio_unitario <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta salvedad es sobre una línea a precio 0 (un regalo anterior a que la salvedad guardara si lo era). Anularla tendría que reponer el regalo y ese camino no existe todavía: corregir a mano.',
      'codigo', 'anulacion_toca_promociones');
  END IF;
$q$, '5b');

  -- #1162 / #1164: v_toca_promo, solo las promos de la foto del pedido.
  v_def := pg_temp.parchar(v_def,
$q$  WITH promos AS (
    SELECT pr.id,
           MAX(CASE WHEN r.clave = 'cantidad_compra'       THEN r.valor END)::INT AS cant_compra,
           MAX(CASE WHEN r.clave = 'cantidad_bonificacion' THEN r.valor END)::INT AS cant_bonif
      FROM promociones pr
      JOIN promocion_productos pp
        ON pp.promocion_id = pr.id AND pp.producto_id = v_salvedad.producto_id
      LEFT JOIN promocion_reglas r ON r.promocion_id = pr.id
     WHERE pr.sucursal_id = v_sucursal
     GROUP BY pr.id
  ), disparadores AS (
    SELECT pm.cant_compra,
           (SELECT COALESCE(SUM(pi.cantidad), 0)::INT
              FROM pedido_items pi
              JOIN promocion_productos pp2
                ON pp2.producto_id = pi.producto_id
               AND pp2.promocion_id = pm.id
             WHERE pi.pedido_id   = v_salvedad.pedido_id
               AND pi.sucursal_id = v_sucursal
               AND COALESCE(pi.es_bonificacion, FALSE) = FALSE) AS qty
      FROM promos pm
     WHERE pm.cant_compra > 0 AND pm.cant_bonif > 0
  )
  SELECT EXISTS (
    SELECT 1 FROM disparadores
     WHERE (qty + v_salvedad.cantidad_afectada) / cant_compra <> qty / cant_compra
  ) INTO v_toca_promo;
$q$,
$q$  -- #1162 / #1164: solo las promos de las que el pedido tuvo regalo (su
  -- foto, pedido_promo_reglas), con las reglas y los productos de la venta.
  -- Sin foto, lo vigente (promos_del_pedido). Antes recorria todas las promos
  -- de la sucursal con el producto: una creada despues de la venta, sin
  -- regalo en el pedido, rechazaba la anulacion.
  WITH promos AS (
    SELECT h.cantidad_compra AS cant_compra, h.cantidad_bonificacion AS cant_bonif, h.productos
      FROM public.promos_del_pedido(v_salvedad.pedido_id) h
     WHERE v_salvedad.producto_id = ANY (h.productos)
  ), disparadores AS (
    SELECT pm.cant_compra,
           (SELECT COALESCE(SUM(pi.cantidad), 0)::INT
              FROM pedido_items pi
             WHERE pi.pedido_id   = v_salvedad.pedido_id
               AND pi.sucursal_id = v_sucursal
               AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
               AND pi.producto_id = ANY (pm.productos)) AS qty
      FROM promos pm
     WHERE pm.cant_compra > 0 AND pm.cant_bonif > 0
  )
  SELECT EXISTS (
    SELECT 1 FROM disparadores
     WHERE (qty + v_salvedad.cantidad_afectada) / cant_compra <> qty / cant_compra
  ) INTO v_toca_promo;
$q$, '5c');

  -- #1161: sin linea viva, la del pedido con la misma clave.
  v_def := pg_temp.parchar(v_def,
$q$  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
    v_item_id := v_salvedad.pedido_item_id;
$q$,
$q$  SELECT pi.id INTO v_item_id FROM pedido_items pi
   WHERE pi.id = v_salvedad.pedido_item_id AND pi.sucursal_id = v_sucursal
     FOR UPDATE;
  IF v_item_id IS NULL THEN
    -- #1161 (decision del dueño 2026-10-14, opcion A): la linea se borro (la
    -- salvedad la dejo en 0). Si el pedido tiene otra con la misma clave (la
    -- reinsertada por otra anulacion), se le suma ahi: mismo precio, asi el
    -- total vuelve al de antes por construccion. Regalo y venta no se mezclan,
    -- ni dos precios. Sin ninguna, se inserta (abajo).
    SELECT pi.id INTO v_item_id FROM pedido_items pi
     WHERE pi.pedido_id = v_salvedad.pedido_id AND pi.sucursal_id = v_sucursal
       AND pi.producto_id = v_salvedad.producto_id
       AND COALESCE(pi.es_bonificacion, FALSE) = COALESCE(v_salvedad.es_bonificacion, FALSE)
       AND pi.promocion_id IS NOT DISTINCT FROM v_salvedad.promocion_id
       AND pi.precio_unitario = v_salvedad.precio_unitario
     ORDER BY pi.id
     LIMIT 1
       FOR UPDATE;
  END IF;
  IF v_item_id IS NOT NULL THEN
$q$, '5d1');

  v_def := pg_temp.parchar(v_def,
$q$      subtotal = (cantidad + v_salvedad.cantidad_afectada) * precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
$q$,
$q$      subtotal = (cantidad + v_salvedad.cantidad_afectada) * precio_unitario
    WHERE id = v_item_id AND sucursal_id = v_sucursal;
  ELSE
$q$, '5d2');

  EXECUTE v_def;
END
$anular$;

-- 5b · registrar_salvedad
DO $registrar$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  FOR v_promo_sync IN
    SELECT pi.promocion_id, SUM(pi.cantidad)::INT AS total_bonif
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
$q$,
$q$  FOR v_promo_sync IN
    SELECT pi.promocion_id, SUM(pi.cantidad)::INT AS total_bonif,
           -- #1164: las reglas y los productos de la foto del pedido.
           h.cantidad_compra, h.cantidad_bonificacion, h.regalo_mueve_stock, h.productos
      FROM pedido_items pi
      JOIN public.promos_del_pedido(p_pedido_id) h ON h.promocion_id = pi.promocion_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
$q$, '6a');

  v_def := pg_temp.parchar(v_def,
$q$       AND NOT COALESCE(v_es_bonif, FALSE)
       AND EXISTS (SELECT 1 FROM promocion_productos pp0
                    WHERE pp0.promocion_id = pi.promocion_id
                      AND pp0.producto_id = v_item.producto_id)
     GROUP BY pi.promocion_id
  LOOP
    SELECT
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT,
      MAX(p.regalo_mueve_stock::INT)::BOOLEAN
    INTO v_cant_compra, v_cant_bonif, v_regalo_mueve_stock
    FROM promociones p
    LEFT JOIN promocion_reglas pr
      ON pr.promocion_id = p.id
    WHERE p.id = v_promo_sync.promocion_id
      AND p.sucursal_id = v_sucursal
    GROUP BY p.id;
$q$,
$q$       AND NOT COALESCE(v_es_bonif, FALSE)
       -- #1164: los productos de la venta (la foto), no los vigentes.
       AND v_item.producto_id = ANY (h.productos)
     GROUP BY pi.promocion_id, h.cantidad_compra, h.cantidad_bonificacion, h.regalo_mueve_stock, h.productos
  LOOP
    v_cant_compra        := v_promo_sync.cantidad_compra;
    v_cant_bonif         := v_promo_sync.cantidad_bonificacion;
    v_regalo_mueve_stock := v_promo_sync.regalo_mueve_stock;
$q$, '6b');

  v_def := pg_temp.parchar(v_def,
$q$    SELECT COALESCE(SUM(pi.cantidad), 0)::INT
      INTO v_total_qty
      FROM pedido_items pi
      JOIN promocion_productos pp
        ON pp.producto_id = pi.producto_id
       AND pp.promocion_id = v_promo_sync.promocion_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = FALSE;
$q$,
$q$    SELECT COALESCE(SUM(pi.cantidad), 0)::INT
      INTO v_total_qty
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
       AND pi.producto_id = ANY (v_promo_sync.productos);
$q$, '6c');

  v_def := pg_temp.parchar(v_def,
$q$        -- alcance de v_toca_promo). Pero las dos miden con las reglas y los
        -- productos VIGENTES de la promo, no con los de la venta: el pedido no
        -- guarda un snapshot. Con la promo editada despues de la venta el tope
        -- de arriba es una aproximacion (10+2 -> 10+1 y un rechazo de 10 sobre
        -- 20 deja 3 regalos; con las reglas de la venta serian 2). Y si sacaron
        -- el producto de la promo, una salvedad sobre el ya no recorta ese
        -- regalo, y anular tampoco lo ve. Las dos cosas esperan el snapshot de
        -- reglas y productos (issue aparte); el camino de alta de promos (mig
        -- 234) es el que tendria que reponer el regalo.
$q$,
$q$        -- alcance de v_toca_promo). Desde #1164 las dos miden con la foto de
        -- la promo en el pedido (pedido_promo_reglas, via promos_del_pedido):
        -- las reglas y los productos de la ultima vez que se armo el regalo,
        -- no los vigentes. El camino de alta de promos (mig 234) es el que
        -- tendria que reponer el regalo.
$q$, '6d');

  EXECUTE v_def;
END
$registrar$;

-- 5c · simular_salvedad_promo_impacto
DO $simular$
DECLARE
  v_def text := pg_get_functiondef('public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$      p.descripcion_regalo,
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT AS cant_compra,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT AS cant_bonif
    FROM bonifs b
    JOIN promociones p ON p.id = b.promocion_id AND p.sucursal_id = v_sucursal
    LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
    -- #1141: el alcance de registrar_salvedad (y de v_toca_promo).
    WHERE EXISTS (SELECT 1 FROM promocion_productos pp0
                   WHERE pp0.promocion_id = b.promocion_id
                     AND pp0.producto_id = v_item.producto_id)
    GROUP BY b.cantidad, b.promocion_id, p.nombre, p.descripcion_regalo
  ),
  totales AS (
    SELECT
      pi.pedido_id, pp.promocion_id,
      SUM(
        CASE
          WHEN pi.id = p_pedido_item_id THEN GREATEST(pi.cantidad - p_cantidad_afectada, 0)
          ELSE pi.cantidad
        END
      )::INT AS total_qty_post
    FROM pedido_items pi
    JOIN promocion_productos pp ON pp.producto_id = pi.producto_id
    WHERE pi.pedido_id = p_pedido_id
      AND pi.sucursal_id = v_sucursal
      AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
    GROUP BY pi.pedido_id, pp.promocion_id
  )
$q$,
$q$      p.descripcion_regalo,
      -- #1164: las reglas y los productos de la foto del pedido.
      h.cantidad_compra AS cant_compra,
      h.cantidad_bonificacion AS cant_bonif,
      h.productos
    FROM bonifs b
    JOIN promociones p ON p.id = b.promocion_id AND p.sucursal_id = v_sucursal
    JOIN public.promos_del_pedido(p_pedido_id) h ON h.promocion_id = b.promocion_id
    -- #1141: el alcance de registrar_salvedad (y de v_toca_promo).
    WHERE v_item.producto_id = ANY (h.productos)
  ),
  totales AS (
    SELECT
      pm.promocion_id,
      SUM(
        CASE
          WHEN pi.id = p_pedido_item_id THEN GREATEST(pi.cantidad - p_cantidad_afectada, 0)
          ELSE pi.cantidad
        END
      )::INT AS total_qty_post
    FROM promo_info pm
    JOIN pedido_items pi
      ON pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal
     AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
     AND pi.producto_id = ANY (pm.productos)
    GROUP BY pm.promocion_id
  )
$q$, '7a');

  EXECUTE v_def;
END
$simular$;

-- 5d · simular_salvedades_promo_impacto
DO $simular_lote$
DECLARE
  v_def text := pg_get_functiondef('public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parchar(v_def,
$q$  reglas AS (
    SELECT p.id AS promocion_id, p.nombre, p.descripcion_regalo,
           MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT AS cant_compra,
           MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT AS cant_bonif
      FROM promociones p
      LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
     WHERE p.sucursal_id = current_sucursal_id()
     GROUP BY p.id, p.nombre, p.descripcion_regalo
  ),
  totales AS (
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
$q$,
$q$  -- #1164: las promos del pedido, con las reglas y los productos de su foto.
  reglas AS (
    SELECT p.id AS promocion_id, p.nombre, p.descripcion_regalo,
           h.cantidad_compra AS cant_compra, h.cantidad_bonificacion AS cant_bonif, h.productos
      FROM public.promos_del_pedido(p_pedido_id) h
      JOIN promociones p ON p.id = h.promocion_id AND p.sucursal_id = current_sucursal_id()
  ),
  totales AS (
    SELECT r.promocion_id, SUM(i.cantidad_post)::INT AS qty_post,
           SUM(i.cantidad)::INT AS qty_pre
      FROM reglas r
      JOIN items i ON NOT i.es_bonif AND i.producto_id = ANY (r.productos)
     GROUP BY r.promocion_id
  ),
  -- #1141: el alcance de registrar_salvedad: las promos que tienen el
  -- producto de alguna linea afectada que no es regalo.
  tocadas AS (
    SELECT DISTINCT r.promocion_id
      FROM reglas r
      JOIN items i ON NOT i.es_bonif AND i.producto_id = ANY (r.productos)
      JOIN afectadas a ON a.item_id = i.id AND a.cant > 0
  ),
$q$, '7b');

  EXECUTE v_def;
END
$simular_lote$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 6 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_anu text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_reg text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_s1  text := pg_get_functiondef('public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure);
  v_s2  text := pg_get_functiondef('public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure);
  v_a   record;
  v_def text;
  v_aud jsonb;
  v_f   text;
BEGIN
  -- La tabla: RLS, sin policies, nada para anon ni authenticated.
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pedido_promo_reglas'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'pedido_promo_reglas')
     OR has_table_privilege('anon', 'public.pedido_promo_reglas', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     OR has_table_privilege('authenticated', 'public.pedido_promo_reglas', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     OR has_any_column_privilege('anon', 'public.pedido_promo_reglas', 'SELECT,INSERT,UPDATE,REFERENCES')
     OR has_any_column_privilege('authenticated', 'public.pedido_promo_reglas', 'SELECT,INSERT,UPDATE,REFERENCES') THEN
    RAISE EXCEPTION 'pedido_promo_reglas quedo sin RLS, con policies o con permisos para anon/authenticated';
  END IF;

  -- Las tres funciones nuevas: de server, nadie mas que postgres/service_role.
  FOREACH v_f IN ARRAY ARRAY['public._promo_reglas_vigentes(bigint)', 'public.promos_del_pedido(bigint)',
                             'public.capturar_promo_del_pedido()'] LOOP
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) x
                WHERE p.oid = v_f::regprocedure
                  AND (x.grantee = 0 OR x.grantee IN ('anon'::regrole, 'authenticated'::regrole)))
       OR has_function_privilege('anon', v_f::regprocedure, 'EXECUTE')
       OR has_function_privilege('authenticated', v_f::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable por PUBLIC, anon o authenticated', v_f;
    END IF;
  END LOOP;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.capturar_promo_del_pedido()'::regprocedure)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_capturar_promo_del_pedido'
                       AND tgrelid = 'public.pedido_items'::regclass AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'el trigger de la foto no quedo como se esperaba';
  END IF;

  -- Las cuatro: mismo ACL, mismos GUCs y bajadas, una sola sobrecarga,
  -- SECURITY DEFINER (y STABLE las simulaciones).
  FOR v_a IN SELECT * FROM t_antes LOOP
    v_def := pg_get_functiondef(v_a.f::regprocedure);
    IF v_a.acl IS DISTINCT FROM (SELECT proacl::text FROM pg_proc WHERE oid = v_a.f::regprocedure) THEN
      RAISE EXCEPTION 'el ACL de % cambio', v_a.f;
    END IF;
    IF pg_temp.contar(v_def, 'set_config(') <> v_a.set_config
       OR pg_temp.contar(v_def, 'current_setting(''app.stock_') <> v_a.current_setting
       OR pg_temp.contar(v_def, 'UPDATE productos') <> v_a.updates_productos THEN
      RAISE EXCEPTION '% cambio sus GUCs o sus UPDATE de productos', v_a.f;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_a.f::regprocedure)
       OR (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
              AND proname = (SELECT proname FROM pg_proc WHERE oid = v_a.f::regprocedure)) <> 1 THEN
      RAISE EXCEPTION '% dejo de ser SECURITY DEFINER o tiene mas de una sobrecarga', v_a.f;
    END IF;
    IF position('promocion_reglas ' IN v_def) > 0 OR position('promocion_productos ' IN v_def) > 0
       OR position('promos_del_pedido(' IN v_def) = 0 THEN
      RAISE EXCEPTION '% sigue leyendo las reglas vigentes o no lee la foto', v_a.f;
    END IF;
  END LOOP;
  IF (SELECT provolatile FROM pg_proc WHERE oid = 'public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure) <> 's'
     OR (SELECT provolatile FROM pg_proc WHERE oid = 'public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure) <> 's' THEN
    RAISE EXCEPTION 'las simulaciones dejaron de ser STABLE';
  END IF;

  -- Los guards nuevos de anular, en orden: cancelado, NC, editado, regalo
  -- (234), regalo viejo, v_toca_promo, la linea.
  IF position('''codigo'', ''nota_credito_vigente''' IN v_anu) = 0
     OR position('''pedido_editado''' IN v_anu) = 0
     OR position('v_salvedad.es_bonificacion IS NULL AND v_salvedad.precio_unitario <= 0' IN v_anu) = 0
     OR position('''pedido_cancelado''' IN v_anu) > position('nota_credito_vigente_de_pedido' IN v_anu)
     OR position('nota_credito_vigente_de_pedido' IN v_anu) > position('''pedido_editado''' IN v_anu)
     OR position('''pedido_editado''' IN v_anu) > position('v_salvedad.es_bonificacion IS NULL AND' IN v_anu)
     OR position('v_salvedad.es_bonificacion IS NULL AND' IN v_anu) > position('INTO v_toca_promo' IN v_anu)
     OR position('pi.precio_unitario = v_salvedad.precio_unitario' IN v_anu) = 0
     OR position('WHERE id = v_salvedad.pedido_item_id' IN v_anu) > 0
     OR pg_temp.contar(v_anu, 'INSERT INTO pedido_items') <> 1 THEN
    RAISE EXCEPTION 'anular_salvedad no quedo como se esperaba';
  END IF;

  -- registrar: el guard de NC de la 276 sigue.
  IF position('nota_credito_vigente_de_pedido(p_pedido_id)' IN v_reg) = 0
     OR position('v_item.producto_id = ANY (h.productos)' IN v_reg) = 0
     OR position('v_promo_sync.productos' IN v_reg) = 0 THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;
  IF position('puede_leer_pedido' IN v_s1) = 0 OR position('puede_leer_pedido' IN v_s2) = 0 THEN
    RAISE EXCEPTION 'una simulacion perdio el filtro puede_leer_pedido';
  END IF;

  -- LOTE-D en high y en 0.
  v_aud := public.auditoria_integridad();
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_aud->'checks') x
                  WHERE x->>'id' = 'LOTE-D' AND x->>'severidad' = 'high'
                    AND (x->>'violaciones')::int = 0) THEN
    RAISE EXCEPTION 'LOTE-D no esta en high o no da 0';
  END IF;
END
$verif$;

DROP TABLE t_antes;
DROP FUNCTION pg_temp.contar(text, text);
