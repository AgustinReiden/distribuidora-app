-- La merma baja la huella (#1127, #1126, y dos hermanos de la misma tanda)
--
-- #1127. La salvedad por dañado, vencido o faltante devuelve y merma en el
-- mismo movimiento: la devolucion lleva 'salvedad_merma', a proposito FUERA de
-- la lista blanca de sincronizar_lotes_stock (mig 234, el corolario "la
-- devolucion que se cancela sola NO va etiquetada"), asi que las unidades no
-- vuelven a ningun lote y el contador no se mueve. Eso esta bien. Lo que
-- faltaba era la traza: la linea de 20 con huella 20 que recibia un dañado de
-- 10 quedaba en 10 con huella 20 (en un retiro de lote el cliente figuraba con
-- unidades de mas), y lotes_devueltos anotaba huella 0, asi que anular no tenia
-- nada que reponer. Visto en el caso C6(b) de
-- scripts/test-cancelar-sin-huella-1114.sql.
-- Decision del dueño (2026-10-13), opcion A: la huella de la linea baja por
-- FEFO sobre su propia huella, LEAST(cantidad_afectada, huella_total): la
-- misma regla que la pasada 1 de _restaurar_lotes_fefo para la devolucion que
-- si queda devuelta (#1085). Con huella completa (lo normal desde la 349) es
-- exacta; con huella parcial es una suposicion, como cualquier otra.
--
-- #1126. La resincronizacion de promos devuelve el exceso del regalo con el
-- GUC del regalo (vuelve a SU lote por la huella del regalo) y eso no se anota
-- en lotes_devueltos. Decision del dueño (2026-10-13), opcion A: no se anota, y
-- queda escrito por que al lado del codigo (2c). No cambia comportamiento.
--
-- Hermano (a), misma regla: cancelar_pedido_con_stock con p_tipo='falta_stock'
-- devuelve y merma con 'pedido_cancelado_merma' (fuera de la lista blanca) y
-- dejaba entera la huella del pedido cancelado. Ahora la borra.
--
-- Hermano (b), #1125: registrar_salvedad no miraba el estado del pedido. Sobre
-- un pedido ya cancelado (que conserva sus lineas) devolvia la linea OTRA vez y
-- le recalculaba el total (VENTA-I en rojo). Ahora rechaza, sin efectos, la
-- salvedad sobre un pedido dado de baja: cancelado, anulado, o con
-- motivo_cancelacion (un cancelado que volvio a otro estado por REST, como el
-- pedido 1856, no volvio a descontar stock).
--
-- Exposicion en prod al escribir esto: 0 salvedades de merma sobre lineas con
-- huella, 0 regalos con huella, 1 cancelacion por falta de stock (sin huella).
-- Sin backfill.
--
-- Lo que no se hace:
--   - No se toca el contador del lote, ni la bolsa, ni los origenes del
--     ledger: no hay ningun UPDATE productos.stock nuevo ni se escribe costo,
--     asi que STK-F, STK-D y COSTO-D no cambian.
--   - anular_salvedad, _restaurar_lotes_fefo y sincronizar_lotes_stock no se
--     tocan. anular ya repone una anotacion {cantidad 0, huella N} por la rama
--     de #1085.
--   - Quedan afuera, con su issue: anular_salvedad restituye la linea a
--     cantidad_original y no a cantidad + cantidad_afectada (mal con dos
--     salvedades vivas sobre la linea); la resincronizacion de
--     registrar_salvedad recorre todas las promos del pedido, tambien las que la
--     salvedad no toco; y un check LOTE-D (huella mayor que la linea).
--
-- Funciones parcheadas en vivo, por ancla sobre pg_get_functiondef de prod
-- (cada fragmento tiene que aparecer exactamente una vez o la migracion
-- aborta). Firma, SECURITY DEFINER, search_path y GRANTs: como estaban
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

-- El ACL de antes, para compararlo despues del parche (seccion 2).
CREATE TEMP TABLE t_acl_antes AS
SELECT p.oid::regprocedure::text AS f, p.proacl::text AS acl
  FROM pg_proc p
 WHERE p.oid IN ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure,
                 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);

DO $salvedad$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  -- 1a · DECLARE.
  v_def := pg_temp.parchar(v_def,
$q$  v_anotacion             JSONB;
BEGIN
$q$,
$q$  v_anotacion             JSONB;
  -- #1127: la huella de ESTA linea que baja por lo mermado.
  v_huella_pend           INT;
  v_huella_baja           INT;
  r_huella                RECORD;
BEGIN
$q$, '1a');

  -- 1b · #1125: sobre un pedido dado de baja no hay salvedad.
  v_def := pg_temp.parchar(v_def,
$q$  PERFORM 1 FROM pedidos
   WHERE id = p_pedido_id
     AND sucursal_id = v_sucursal
     FOR UPDATE;
$q$,
$q$  PERFORM 1 FROM pedidos
   WHERE id = p_pedido_id
     AND sucursal_id = v_sucursal
     FOR UPDATE;

  -- #1125 (decision del dueño 2026-10-13): sobre un pedido dado de baja no hay
  -- salvedad. La cancelacion ya devolvio la mercaderia (o la mermo, si fue por
  -- falta de stock) y dejo el total en 0, pero no borra las lineas: la
  -- salvedad las devolvia OTRA vez (unidades fantasma en la bolsa) y le
  -- recalculaba el total a un cancelado (VENTA-I en rojo). El caso tipico es el
  -- chofer con la hoja vieja sobre un pedido que el admin ya cancelo. Baja es
  -- cancelado o anulado (#1080, la baja es una sola), o con motivo_cancelacion:
  -- un cancelado que volvio a otro estado por REST no volvio a descontar stock
  -- (el pedido 1856), asi que lo que tiene ya se devolvio. Va despues del lock
  -- del pedido (una cancelacion concurrente espera, o ya esta confirmada y se
  -- ve) y despues del reintento idempotente de arriba: la salvedad que entro
  -- antes de cancelar sigue contestando lo que hizo. El mensaje no nombra el
  -- stock ni la sesion, asi que rechazoEsTerminal (src/utils/rechazoDeNegocio.ts)
  -- lo trata como definitivo; los modales del chofer muestran `error` tal cual.
  IF EXISTS (SELECT 1 FROM pedidos
              WHERE id = p_pedido_id
                AND sucursal_id = v_sucursal
                AND (estado IN ('cancelado', 'anulado') OR motivo_cancelacion IS NOT NULL)) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'El pedido #' || p_pedido_id || ' fue dado de baja (cancelado o anulado): no admite salvedades.',
      'codigo', 'pedido_cancelado'
    );
  END IF;
$q$, '1b');

  -- 1c · #1126: la decision escrita, sin cambio de codigo.
  v_def := pg_temp.parchar(v_def,
$q$        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
$q$,
$q$        -- #1126 (decision del dueño 2026-10-13): esta devolucion NO se anota
        -- en lotes_devueltos, a proposito. anular_salvedad no restituye el
        -- regalo ni baja stock por el en ningun camino: rechaza la salvedad
        -- sobre un regalo y, con v_toca_promo, la restitucion que devolveria el
        -- derecho a una promo que tiene el producto. Sin bajada, no hay lote +N
        -- ni bolsa -N posible, y la anotacion no tendria quien la lea. Peor: en
        -- el mismo array, con un regalo del mismo producto, anular le sacaria la
        -- bajada de la linea principal al lote del regalo y le repondria a la
        -- linea principal la huella del regalo (#1073 otra vez).
        -- El guard de anular NO es una garantia completa: con mas de una
        -- salvedad sobre la linea, o con una promo editada o ajena que esta
        -- resincronizacion recorta, puede quedar un regalo recortado sin que
        -- anular lo rechace. Son bugs conocidos, con su issue; el camino de alta
        -- de promos (mig 234) es el que tendria que reponer el regalo.
        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
$q$, '1c');

  -- 1d · #1127: la huella baja por lo mermado. Despues de la resincronizacion
  -- y del recalculo de totales, antes de la CTE que mide lo que se anota.
  -- El ancla NO lleva salto final: en prod el renglon sigue (" `cantidad`: a"),
  -- y el texto nuevo termina igual, para que ese resto quede pegado.
  v_def := pg_temp.parchar(v_def,
$q$  -- #1050 / #1073: lo que anular_salvedad tiene que deshacer.$q$,
$q$  -- #1127 (decision del dueño 2026-10-13): la merma (dañado, vencido,
  -- faltante) devuelve y merma en el mismo movimiento con 'salvedad_merma',
  -- fuera de la lista blanca (mig 234: la devolucion que se cancela sola NO va
  -- etiquetada), asi que las unidades no vuelven a ningun lote y el contador no
  -- se mueve. Pero el cliente ya no las tiene: sin esto la linea quedaba en 10
  -- con huella 20 y, en un retiro de lote, figuraba con unidades de mas. La
  -- huella baja con la regla de la pasada 1 de _restaurar_lotes_fefo para la
  -- devolucion que si queda devuelta (#1085): primero sus lotes, por FEFO sobre
  -- la propia huella de la linea, LEAST(cantidad_afectada, huella). Lo que
  -- excede la huella salio de la bolsa: no hay huella que bajar.
  --   - La CTE de abajo mide antes - despues, asi que recoge esta baja y la
  --     anota con cantidad 0 y la huella real; anular_salvedad la repone por
  --     la rama de #1085.
  --   - La linea entera (v_cantidad_entregada = 0) ya la cubre la cascada del
  --     DELETE (#1073).
  --   - Va despues de la resincronizacion: la huella del regalo ya la bajo su
  --     propia devolucion (con el GUC del regalo), y este bloque solo mira
  --     ESTA linea, asi que no hay doble baja.
  --   - Orden de locks: pedido, linea, producto, huella, el de la devolucion.
  --     No lockea producto_lotes: lotes antes que productos invertiria el
  --     orden de toda bajada de stock (productos, despues lotes).
  IF p_motivo IN ('producto_danado', 'producto_vencido', 'faltante_stock')
     AND v_mueve_stock AND v_cantidad_entregada > 0 THEN
    PERFORM 1 FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
       FOR UPDATE;
    v_huella_pend := p_cantidad_afectada;
    FOR r_huella IN
      SELECT pil.id, pil.cantidad
        FROM pedido_item_lotes pil
        JOIN producto_lotes l ON l.id = pil.lote_id
       WHERE pil.pedido_item_id = p_pedido_item_id
         AND pil.sucursal_id = v_sucursal
       ORDER BY l.fecha_vencimiento, l.id, pil.id
         FOR UPDATE OF pil
    LOOP
      EXIT WHEN v_huella_pend <= 0;
      v_huella_baja := LEAST(v_huella_pend, r_huella.cantidad);
      IF v_huella_baja >= r_huella.cantidad THEN
        DELETE FROM pedido_item_lotes WHERE id = r_huella.id;
      ELSE
        UPDATE pedido_item_lotes SET cantidad = cantidad - v_huella_baja WHERE id = r_huella.id;
      END IF;
      v_huella_pend := v_huella_pend - v_huella_baja;
    END LOOP;
  END IF;

  -- #1050 / #1073: lo que anular_salvedad tiene que deshacer.$q$, '1d');

  EXECUTE v_def;
END
$salvedad$;

DO $cancelar$
DECLARE
  v_def text := pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
BEGIN
  -- 1e · hermano (a): la cancelacion por falta de stock borra la huella.
  v_def := pg_temp.parchar(v_def,
$q$    -- set_config es por TRANSACCION (mig 229): se restauran las etiquetas de la
    -- cancelacion para lo que sigue (contenedores, y el caller si lo hubiera).
    PERFORM set_config('app.stock_origen',   'pedido_cancelado', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido',           true);
    PERFORM set_config('app.stock_ref_id',   p_pedido_id::TEXT,  true);
  END IF;
$q$,
$q$    -- #1127 (decision del dueño 2026-10-13): la misma regla que la merma de
    -- registrar_salvedad. Estas unidades se devolvieron y mermaron con
    -- 'pedido_cancelado_merma', fuera de la lista blanca: no vuelven a ningun
    -- lote y el contador no se mueve, pero el cliente no tiene nada de este
    -- pedido. Sin esto el cancelado quedaba con toda su huella y, en un retiro
    -- de lote, el cliente figuraba con unidades que nunca recibio. Se cancela
    -- entero, asi que no hace falta FEFO: se borra la huella de todas sus
    -- lineas, simetrico con la cancelacion normal, que la deja en 0 por la
    -- pasada 1 de _restaurar_lotes_fefo. Orden de locks: pedido, productos (la
    -- merma de arriba), huella.
    DELETE FROM pedido_item_lotes pil
     USING pedido_items pi
     WHERE pi.id = pil.pedido_item_id
       AND pi.sucursal_id = pil.sucursal_id
       AND pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal;

    -- set_config es por TRANSACCION (mig 229): se restauran las etiquetas de la
    -- cancelacion para lo que sigue (contenedores, y el caller si lo hubiera).
    PERFORM set_config('app.stock_origen',   'pedido_cancelado', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido',           true);
    PERFORM set_config('app.stock_ref_id',   p_pedido_id::TEXT,  true);
  END IF;
$q$, '1e');

  EXECUTE v_def;
END
$cancelar$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 2 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_sal  text := pg_get_functiondef(
    'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  v_can  text := pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure);
  v_sinc text := pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure);
  r      record;
BEGIN
  -- registrar_salvedad: la guarda despues del lock del pedido y antes de leer
  -- la linea; la baja de huella despues de la resincronizacion y antes de la
  -- CTE de anotacion; la decision de #1126 escrita.
  IF v_sal NOT LIKE '%SECURITY DEFINER%'
     OR position('''codigo'', ''pedido_cancelado''' IN v_sal) = 0
     OR position('''codigo'', ''pedido_cancelado''' IN v_sal) < position('FOR UPDATE;' IN v_sal)
     OR position('''codigo'', ''pedido_cancelado''' IN v_sal) > position('SELECT pi.id, pi.producto_id, pi.cantidad' IN v_sal)
     OR position('-- #1127 (decision' IN v_sal) = 0
     OR position('-- #1127 (decision' IN v_sal) < position('''Salvedad pedido #'' || p_pedido_id' IN v_sal)
     OR position('-- #1127 (decision' IN v_sal) > position('WITH lotes AS (' IN v_sal)
     OR position('-- #1126 (decision' IN v_sal) = 0 THEN
    RAISE EXCEPTION 'registrar_salvedad no quedo como se esperaba';
  END IF;

  -- cancelar_pedido_con_stock: el DELETE de huella dentro de la rama de falta
  -- de stock (despues de su merma, antes de los contenedores).
  IF v_can NOT LIKE '%SECURITY DEFINER%'
     OR position('DELETE FROM pedido_item_lotes pil' IN v_can) = 0
     OR position('DELETE FROM pedido_item_lotes pil' IN v_can) < position('''pedido_cancelado_merma''' IN v_can)
     OR position('DELETE FROM pedido_item_lotes pil' IN v_can) > position('mig 235: el fardo del regalo' IN v_can) THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock no quedo como se esperaba';
  END IF;

  -- ACL: identico al de antes; nada para PUBLIC ni anon; authenticated
  -- conserva EXECUTE (las dos son RPCs del front).
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

  -- Si la devolucion de la merma entrara a la lista blanca, la huella bajaria
  -- dos veces (la pasada 1 de _restaurar_lotes_fefo y estos bloques).
  IF v_sinc LIKE '%''salvedad_merma''%' OR v_sinc LIKE '%''pedido_cancelado_merma''%' THEN
    RAISE EXCEPTION 'la lista blanca de sincronizar_lotes_stock cambio: revisar #1127';
  END IF;

  -- Una sola sobrecarga de cada una (PGRST203).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
         AND proname IN ('registrar_salvedad', 'cancelar_pedido_con_stock')) <> 2 THEN
    RAISE EXCEPTION 'hay mas de una sobrecarga de registrar_salvedad o cancelar_pedido_con_stock';
  END IF;
END
$verif$;

DROP TABLE t_acl_antes;

-- ---------------------------------------------------------------------------
-- 3 - Ensayo con datos reales: los casos de
--     scripts/test-salvedad-huella-1126-1127.sql (ver ahi cada uno). La corrida
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

-- Cantidad de una linea (NULL si ya no existe).
CREATE OR REPLACE FUNCTION pg_temp.t_cant(p_item bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT cantidad FROM public.pedido_items WHERE id = p_item;
$fn$;

-- lotes_devueltos de una salvedad, reducido a [[lote, cantidad, huella], ...]
-- por lote. NULL si no se anoto nada.
CREATE OR REPLACE FUNCTION pg_temp.t_anot(p_salv bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT CASE WHEN s.lotes_devueltos IS NULL THEN NULL ELSE
    COALESCE((SELECT jsonb_agg(jsonb_build_array((x->>'lote_id')::bigint, (x->>'cantidad')::int,
                                                 (x->>'huella')::int)
                               ORDER BY (x->>'lote_id')::bigint)
                FROM jsonb_array_elements(s.lotes_devueltos) x), '[]'::jsonb) END
    FROM public.salvedades_items s WHERE s.id = p_salv;
$fn$;

-- ¿La salvedad tiene su merma viva?
CREATE OR REPLACE FUNCTION pg_temp.t_merma_viva(p_salv bigint)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.mermas_stock WHERE salvedad_id = p_salv AND anulada_at IS NULL);
$fn$;

-- Producto con lotes de una compra ([{dias, cantidad, restante}]) y `p_bolsa`
-- unidades sin lote. Devuelve {prod, compra, lotes: [ids en el orden dado]}.
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
  VALUES ('ZZ ensayo 1127', 100,
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

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1127');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_prod));
END
$fn$;

-- Un regalo de `p_n` del MISMO producto, de una promo que mueve stock con
-- reglas "cada p_compra, p_bonif de regalo" sobre el producto, y su bajada con
-- su linea (como el alta). Devuelve el id del regalo.
CREATE OR REPLACE FUNCTION pg_temp.t_regalo(p_ped bigint, p_prod bigint, p_suc bigint, p_n int,
                                            p_compra int, p_bonif int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint; v_regalo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1127', 'bonificacion', CURRENT_DATE, p_suc, true, p_prod) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc),
         (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_prod, p_suc);
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (p_ped, p_prod, p_n, 0, 0, p_suc, true, v_promo) RETURNING id INTO v_regalo;
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
CREATE OR REPLACE FUNCTION pg_temp.t_salvedad_res(p_ped bigint, p_item bigint, p_cant int, p_motivo text,
                                                  p_req uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                   'ensayo 1127: descripcion del caso', NULL, true, p_req);
$fn$;

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
  v_res := public.anular_salvedad(p_salv, 'ensayo 1127');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cancelar(p_ped bigint, p_adm uuid, p_tipo text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1127', p_adm, p_tipo);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
END
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote): para que la bolsa no quede en 0 despues de un pedido que
-- salio de un lote.
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1127', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- El punto de partida de H1/H4/H6/H7/F1: L1 (100, 50 vivas), bolsa 0 al crear,
-- pedido de 20 que sale entero de L1 (huella 20), y despues 40 a la bolsa.
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
  RETURN jsonb_build_object('prod', v_prod, 'l1', v_l1, 'compra', v->'compra',
                            'pedido', p->'pedido', 'item', p->'item');
END
$fn$;

-- El punto de partida de R1/R3: L1 (100, 50 vivas), bolsa 0. X de 20 sale de
-- L1 (huella 20). Regalo R de 4 del mismo producto, promo 10 + 2 sobre el
-- producto, sale de L1 (huella 4). Despues 40 a la bolsa.
-- Foto {stock 66, lotes [26], bolsa 40}.
CREATE OR REPLACE FUNCTION pg_temp.t_base_regalo(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_l1 bigint; v_r bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_r := pg_temp.t_regalo((p->>'pedido')::bigint, v_prod, p_suc, 4, 10, 2);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
  IF pg_temp.t_foto(v_prod) <> '{"stock":66,"lotes":[26],"bolsa":40}'
     OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 20 OR pg_temp.t_huella(v_r, v_l1) <> 4 THEN
    RAISE EXCEPTION 'punto de partida: foto %, huella X %, huella R %', pg_temp.t_foto(v_prod),
      pg_temp.t_huella((p->>'item')::bigint, v_l1), pg_temp.t_huella(v_r, v_l1);
  END IF;
  RETURN jsonb_build_object('prod', v_prod, 'l1', v_l1, 'pedido', p->'pedido', 'item', p->'item',
                            'regalo', v_r);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- H1 · #1127, el C6(b) de la 1114. Dañado 10 sobre la linea de 20 con huella
--      20: stock, lotes y bolsa no se mueven; la huella baja a 10 y se anota
--      {L1, cantidad 0, huella 10}. Anular repone la huella a 20.
CREATE OR REPLACE FUNCTION pg_temp.caso_h1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_item bigint; v_salv bigint; f text[] := '{}';
  v_f0 jsonb; v_f1 jsonb; v_f2 jsonb; v_anot jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_salv := pg_temp.t_salvedad((b->>'pedido')::bigint, v_item, 10, 'producto_danado');
  v_f1 := pg_temp.t_foto(v_prod);
  v_anot := pg_temp.t_anot(v_salv);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('la salvedad movio stock/lotes/bolsa: %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 10, format('la linea quedo en %s, esperado 10', pg_temp.t_cant(v_item)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 10,
                    format('la huella quedo en %s, esperado 10 (la linea tiene 10)', pg_temp.t_huella(v_item, v_l1)));
  f := pg_temp.t_si(f, v_anot = jsonb_build_array(jsonb_build_array(v_l1, 0, 10)),
                    format('lotes_devueltos %s, esperado [[L1, 0, 10]]', v_anot));
  f := pg_temp.t_si(f, (SELECT (lotes_devueltos->0->>'compra_id')::bigint = (b->>'compra')::bigint
                                 AND lotes_devueltos->0->>'fecha_vencimiento' IS NOT NULL
                          FROM public.salvedades_items WHERE id = v_salv),
                    'la anotacion no lleva compra_id/fecha_vencimiento del lote');
  f := pg_temp.t_si(f, pg_temp.t_merma_viva(v_salv), 'la salvedad no dejo su merma');
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s, esperado %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 20 AND pg_temp.t_huella(v_item, v_l1) = 20,
                    format('anular dejo la linea en %s con huella %s, esperado 20 y 20',
                           pg_temp.t_cant(v_item), pg_temp.t_huella(v_item, v_l1)));
  f := pg_temp.t_si(f, NOT pg_temp.t_merma_viva(v_salv), 'anular no anulo la merma');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('fotos %s / %s / %s, anotacion %s', v_f0, v_f1, v_f2, v_anot));
END
$fn$;

-- H2 · FEFO sobre la propia huella, varios lotes. L_early (10, 10 vivas, 30
--      dias) y L_late (100, 50 vivas, 90 dias), bolsa 0: el pedido de 20 deja
--      huella 10 + 10. Vencido 12: baja 10 de early y 2 de late.
CREATE OR REPLACE FUNCTION pg_temp.caso_h2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_e bigint; v_l bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb; v_anot jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":10,"restante":10},{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_e := v->'lotes'->>0; v_l := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":80,"lotes":[0,40],"bolsa":40}'
     OR pg_temp.t_huella(v_item, v_e) <> 10 OR pg_temp.t_huella(v_item, v_l) <> 10 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, v_item, 12, 'producto_vencido');
  v_f1 := pg_temp.t_foto(v_prod);
  v_anot := pg_temp.t_anot(v_salv);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('la salvedad movio stock/lotes/bolsa: %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_e) = 0 AND pg_temp.t_huella(v_item, v_l) = 8,
                    format('huella early %s / late %s, esperado 0 / 8 (FEFO sobre la huella)',
                           pg_temp.t_huella(v_item, v_e), pg_temp.t_huella(v_item, v_l)));
  f := pg_temp.t_si(f, v_anot = jsonb_build_array(jsonb_build_array(v_e, 0, 10), jsonb_build_array(v_l, 0, 2)),
                    format('lotes_devueltos %s, esperado [[early, 0, 10], [late, 0, 2]]', v_anot));
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s, esperado %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_e) = 10 AND pg_temp.t_huella(v_item, v_l) = 10,
                    format('anular dejo huella early %s / late %s, esperado 10 / 10',
                           pg_temp.t_huella(v_item, v_e), pg_temp.t_huella(v_item, v_l)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('fotos %s / %s / %s, anotacion %s', v_f0, v_f1, v_f2, v_anot));
END
$fn$;

-- H3 · huella parcial. L1 (100, 50 vivas), bolsa 5: el pedido de 20 sale 5 de
--      la bolsa y 15 de L1 (huella 15). Faltante 10: la huella baja 10, a 5.
CREATE OR REPLACE FUNCTION pg_temp.caso_h3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_l1 bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb; v_anot jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":75,"lotes":[35],"bolsa":40}' OR pg_temp.t_huella(v_item, v_l1) <> 15 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, v_item, 10, 'faltante_stock');
  v_f1 := pg_temp.t_foto(v_prod);
  v_anot := pg_temp.t_anot(v_salv);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('la salvedad movio stock/lotes/bolsa: %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 5,
                    format('la huella quedo en %s, esperado 5', pg_temp.t_huella(v_item, v_l1)));
  f := pg_temp.t_si(f, v_anot = jsonb_build_array(jsonb_build_array(v_l1, 0, 10)),
                    format('lotes_devueltos %s, esperado [[L1, 0, 10]]', v_anot));
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s, esperado %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('anular dejo la huella en %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('fotos %s / %s / %s, anotacion %s', v_f0, v_f1, v_f2, v_anot));
END
$fn$;

-- H4 · regresion de #1073: dañado sobre la linea entera. La linea se borra (y
--      su huella en cascada), se anota [[L1, 0, 20]], y anular la reinserta
--      con huella 20. La foto no se mueve en ningun momento.
CREATE OR REPLACE FUNCTION pg_temp.caso_h4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_item bigint; v_nuevo bigint; v_salv bigint; f text[] := '{}';
  v_f0 jsonb; v_f1 jsonb; v_f2 jsonb; v_anot jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_salv := pg_temp.t_salvedad((b->>'pedido')::bigint, v_item, 20, 'producto_danado');
  v_f1 := pg_temp.t_foto(v_prod);
  v_anot := pg_temp.t_anot(v_salv);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('la salvedad movio stock/lotes/bolsa: %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) IS NULL, 'la linea entera no se borro');
  f := pg_temp.t_si(f, v_anot = jsonb_build_array(jsonb_build_array(v_l1, 0, 20)),
                    format('lotes_devueltos %s, esperado [[L1, 0, 20]]', v_anot));
  PERFORM pg_temp.t_anular(v_salv);
  SELECT id INTO v_nuevo FROM public.pedido_items
   WHERE pedido_id = (b->>'pedido')::bigint AND producto_id = v_prod;
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s, esperado %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_nuevo) = 20 AND pg_temp.t_huella(v_nuevo, v_l1) = 20,
                    format('anular reinserto la linea con %s u. y huella %s, esperado 20 y 20',
                           pg_temp.t_cant(v_nuevo), pg_temp.t_huella(v_nuevo, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('fotos %s / %s / %s, anotacion %s', v_f0, v_f1, v_f2, v_anot));
END
$fn$;

-- H5 · el C6(a) de la 1114: la linea sin huella (salio de la bolsa). Dañado 10:
--      nada que bajar, lotes_devueltos queda NULL, y anular no inventa huella.
CREATE OR REPLACE FUNCTION pg_temp.caso_h5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_item := p->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":70,"lotes":[50],"bolsa":20}' OR pg_temp.t_huella(v_item, NULL) <> 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, v_item, 10, 'producto_danado');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('la salvedad movio stock/lotes/bolsa: %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_anot(v_salv) IS NULL,
                    format('sin huella, lotes_devueltos tendria que quedar NULL: %s', pg_temp.t_anot(v_salv)));
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s, esperado %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, NULL) = 0, 'anular le invento huella a la linea');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

-- H6 · regresion de la devolucion que queda devuelta: cliente_rechaza 10 sobre
--      la linea con huella 20. Las 10 vuelven a L1, la huella baja a 10, se
--      anota [[L1, 10, 10]]. Anular deja todo como despues del pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_h6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_item bigint; v_salv bigint; f text[] := '{}';
  v_f0 jsonb; v_f1 jsonb; v_f2 jsonb; v_anot jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_salv := pg_temp.t_salvedad((b->>'pedido')::bigint, v_item, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  v_anot := pg_temp.t_anot(v_salv);
  f := pg_temp.t_si(f, v_f1 = '{"stock":80,"lotes":[40],"bolsa":40}',
                    format('la salvedad dejo %s, esperado {stock 80, lotes [40], bolsa 40}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 10,
                    format('la huella quedo en %s, esperado 10', pg_temp.t_huella(v_item, v_l1)));
  f := pg_temp.t_si(f, v_anot = jsonb_build_array(jsonb_build_array(v_l1, 10, 10)),
                    format('lotes_devueltos %s, esperado [[L1, 10, 10]]', v_anot));
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s, esperado %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 20,
                    format('anular dejo la huella en %s, esperado 20', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('fotos %s / %s / %s, anotacion %s', v_f0, v_f1, v_f2, v_anot));
END
$fn$;

-- H7 · dos mermas sobre la misma linea. S1 dañado 5 y S2 dañado 5: la huella
--      baja a 15 y a 10, cada una anota [[L1, 0, 5]]. Anular S1 repone sus 5:
--      huella 15 (20 menos las 5 de S2, que sigue viva). La cantidad de la
--      linea NO se afirma: anular la deja en la cantidad_original de S1 (20),
--      que es un bug aparte con su issue; se informa en el reporte.
CREATE OR REPLACE FUNCTION pg_temp.caso_h7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_item bigint; v_s1 bigint; v_s2 bigint; f text[] := '{}';
  v_f0 jsonb; v_f2 jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_s1 := pg_temp.t_salvedad((b->>'pedido')::bigint, v_item, 5, 'producto_danado');
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15 AND pg_temp.t_anot(v_s1) = jsonb_build_array(jsonb_build_array(v_l1, 0, 5)),
                    format('S1 dejo huella %s y anotacion %s, esperado 15 y [[L1, 0, 5]]',
                           pg_temp.t_huella(v_item, v_l1), pg_temp.t_anot(v_s1)));
  v_s2 := pg_temp.t_salvedad((b->>'pedido')::bigint, v_item, 5, 'producto_danado');
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 10 AND pg_temp.t_anot(v_s2) = jsonb_build_array(jsonb_build_array(v_l1, 0, 5)),
                    format('S2 dejo huella %s y anotacion %s, esperado 10 y [[L1, 0, 5]]',
                           pg_temp.t_huella(v_item, v_l1), pg_temp.t_anot(v_s2)));
  PERFORM pg_temp.t_anular(v_s1);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular S1 dejo %s, esperado %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('anular S1 dejo la huella en %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('cantidad de la linea tras anular S1: %s (lo correcto seria 15; bug aparte de anular_salvedad)',
           pg_temp.t_cant(v_item)));
END
$fn$;

-- R1 · #1126, la decision escrita. Cliente_rechaza 10 sobre X: la promo
--      recorta R de 4 a 2 y esas 2 vuelven a L1 por la huella del regalo. La
--      anotacion de la salvedad es sólo la de X ([[L1, 10, 10]]): el exceso
--      del regalo no se anota, y anular la rechaza sin mover nada.
CREATE OR REPLACE FUNCTION pg_temp.caso_r1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_x bigint; v_r bigint; v_salv bigint; f text[] := '{}';
  v_f1 jsonb; v_f2 jsonb; v_anot jsonb; v_res jsonb;
BEGIN
  b := pg_temp.t_base_regalo(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_x := b->>'item'; v_r := b->>'regalo';
  v_salv := pg_temp.t_salvedad((b->>'pedido')::bigint, v_x, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  v_anot := pg_temp.t_anot(v_salv);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_r) = 2, format('el regalo quedo en %s, esperado 2', pg_temp.t_cant(v_r)));
  f := pg_temp.t_si(f, v_f1 = '{"stock":78,"lotes":[38],"bolsa":40}',
                    format('la salvedad dejo %s, esperado {stock 78, lotes [38], bolsa 40}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_x, v_l1) = 10 AND pg_temp.t_huella(v_r, v_l1) = 2,
                    format('huella X %s / R %s, esperado 10 / 2', pg_temp.t_huella(v_x, v_l1), pg_temp.t_huella(v_r, v_l1)));
  f := pg_temp.t_si(f, v_anot = jsonb_build_array(jsonb_build_array(v_l1, 10, 10)),
                    format('lotes_devueltos %s, esperado [[L1, 10, 10]] (sin las 2 del regalo)', v_anot));
  v_res := public.anular_salvedad(v_salv, 'ensayo 1127');
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false)
                       AND v_res->>'codigo' = 'anulacion_toca_promociones',
                    format('anular tendria que rechazar con anulacion_toca_promociones: %s', v_res));
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f1 AND pg_temp.t_huella(v_x, v_l1) = 10 AND pg_temp.t_huella(v_r, v_l1) = 2,
                    format('el rechazo de anular movio algo: %s, huella X %s / R %s', v_f2,
                           pg_temp.t_huella(v_x, v_l1), pg_temp.t_huella(v_r, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s, anotacion %s', v_f1, v_anot));
END
$fn$;

-- R3 · #1126 x #1127. Dañado 10 sobre X con el regalo del mismo producto con
--      huella: la promo recorta R a 2 (esas 2 vuelven a L1 por su huella) y la
--      huella de X baja a 10 sólo por el bloque de #1127, sin doble baja. La
--      merma deja la bolsa en 40. Anular rechaza sin mover nada.
CREATE OR REPLACE FUNCTION pg_temp.caso_r3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_l1 bigint; v_x bigint; v_r bigint; v_salv bigint; f text[] := '{}';
  v_f1 jsonb; v_f2 jsonb; v_anot jsonb; v_res jsonb;
BEGIN
  b := pg_temp.t_base_regalo(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_l1 := b->>'l1'; v_x := b->>'item'; v_r := b->>'regalo';
  v_salv := pg_temp.t_salvedad((b->>'pedido')::bigint, v_x, 10, 'producto_danado');
  v_f1 := pg_temp.t_foto(v_prod);
  v_anot := pg_temp.t_anot(v_salv);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_x) = 10 AND pg_temp.t_cant(v_r) = 2,
                    format('X quedo en %s y R en %s, esperado 10 y 2', pg_temp.t_cant(v_x), pg_temp.t_cant(v_r)));
  f := pg_temp.t_si(f, v_f1 = '{"stock":68,"lotes":[28],"bolsa":40}',
                    format('la salvedad dejo %s, esperado {stock 68, lotes [28], bolsa 40}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_x, v_l1) = 10 AND pg_temp.t_huella(v_r, v_l1) = 2,
                    format('huella X %s / R %s, esperado 10 / 2', pg_temp.t_huella(v_x, v_l1), pg_temp.t_huella(v_r, v_l1)));
  f := pg_temp.t_si(f, v_anot = jsonb_build_array(jsonb_build_array(v_l1, 0, 10)),
                    format('lotes_devueltos %s, esperado [[L1, 0, 10]] (sin las 2 del regalo)', v_anot));
  v_res := public.anular_salvedad(v_salv, 'ensayo 1127');
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false)
                       AND v_res->>'codigo' = 'anulacion_toca_promociones',
                    format('anular tendria que rechazar con anulacion_toca_promociones: %s', v_res));
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f1 AND pg_temp.t_huella(v_x, v_l1) = 10 AND pg_temp.t_huella(v_r, v_l1) = 2
                       AND pg_temp.t_merma_viva(v_salv),
                    format('el rechazo de anular movio algo: %s, huella X %s / R %s', v_f2,
                           pg_temp.t_huella(v_x, v_l1), pg_temp.t_huella(v_r, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s, anotacion %s', v_f1, v_anot));
END
$fn$;

-- F1 · hermano (a): cancelar por falta de stock un pedido con huella. La
--      devolucion 'pedido_cancelado_merma' y la merma no mueven stock, lotes ni
--      bolsa, pero el cliente no tiene nada: la huella del pedido queda en 0.
CREATE OR REPLACE FUNCTION pg_temp.caso_f1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_item bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  PERFORM pg_temp.t_cancelar((b->>'pedido')::bigint, p_adm, 'falta_stock');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('cancelar por falta de stock dejo %s, esperado %s', v_f1, v_f0));
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.mermas_stock m
                                WHERE m.producto_id = v_prod AND m.cantidad = 20 AND m.anulada_at IS NULL),
                    'cancelar por falta de stock no registro la merma de 20');
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, NULL) = 0,
                    format('el pedido cancelado por falta de stock quedo con huella %s, esperado 0',
                           pg_temp.t_huella(v_item, NULL)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- B1 · hermano (b): salvedad sobre un pedido cancelado. Se rechaza con
--      success=false y codigo 'pedido_cancelado', sin efectos: ni stock, ni
--      linea, ni total, ni fila de salvedad. Antes devolvia la linea OTRA vez.
--      La salvedad que entro ANTES de cancelar, reintentada con su mismo
--      client_request_id, sigue contestando lo que hizo (idempotente).
CREATE OR REPLACE FUNCTION pg_temp.caso_b1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; v_item bigint; f text[] := '{}';
  v_req uuid := gen_random_uuid(); v_res jsonb; v_rep jsonb; v_fc jsonb; v_f1 jsonb; v_n int;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_ped := p->>'pedido'; v_item := p->>'item';
  v_res := pg_temp.t_salvedad_res(v_ped, v_item, 5, 'cliente_rechaza', v_req);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('la salvedad previa fallo: %s', v_res)));
  END IF;
  PERFORM pg_temp.t_cancelar(v_ped, p_adm);
  v_fc := pg_temp.t_foto(v_prod);

  v_res := pg_temp.t_salvedad_res(v_ped, v_item, 5, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  SELECT count(*) INTO v_n FROM public.salvedades_items WHERE pedido_id = v_ped;
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false)
                       AND v_res->>'codigo' = 'pedido_cancelado'
                       AND v_res->>'error' LIKE 'El pedido #' || v_ped || ' fue dado de baja%',
                    format('la salvedad sobre el cancelado tendria que rechazarse con pedido_cancelado: %s', v_res));
  f := pg_temp.t_si(f, v_res->>'error' !~* 'stock insuficiente|sin stock|stock disponible|sucursal activa|jwt|token',
                    format('el mensaje parece reintentable para rechazoEsTerminal: %s', v_res->>'error'));
  f := pg_temp.t_si(f, v_f1 = v_fc, format('la salvedad sobre el cancelado movio stock: %s, antes %s', v_f1, v_fc));
  f := pg_temp.t_si(f, v_n = 1, format('quedaron %s salvedades sobre el pedido, esperado 1 (la previa)', v_n));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 15 AND (SELECT total FROM public.pedidos WHERE id = v_ped) = 0,
                    format('la linea quedo en %s y el total en %s, esperado 15 y 0', pg_temp.t_cant(v_item),
                           (SELECT total FROM public.pedidos WHERE id = v_ped)));

  v_rep := pg_temp.t_salvedad_res(v_ped, v_item, 5, 'cliente_rechaza', v_req);
  f := pg_temp.t_si(f, COALESCE((v_rep->>'success')::boolean, false)
                       AND COALESCE((v_rep->>'idempotent_replay')::boolean, false)
                       AND pg_temp.t_foto(v_prod) = v_fc,
                    format('el reintento de la salvedad previa tendria que contestar idempotente sin mover nada: %s', v_rep));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('respuesta %s', v_res));
END
$fn$;

-- B2 · la baja es una sola (#1080): 'anulado' se rechaza igual.
CREATE OR REPLACE FUNCTION pg_temp.caso_b2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; v_item bigint; f text[] := '{}';
  v_res jsonb; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_ped := p->>'pedido'; v_item := p->>'item';
  UPDATE public.pedidos SET estado = 'anulado' WHERE id = v_ped;
  v_f0 := pg_temp.t_foto(v_prod);
  v_res := pg_temp.t_salvedad_res(v_ped, v_item, 5, 'producto_danado');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'codigo' = 'pedido_cancelado',
                    format('la salvedad sobre el anulado tendria que rechazarse: %s', v_res));
  f := pg_temp.t_si(f, v_f1 = v_f0 AND pg_temp.t_cant(v_item) = 20
                       AND NOT EXISTS (SELECT 1 FROM public.salvedades_items WHERE pedido_id = v_ped),
                    format('la salvedad sobre el anulado dejo efectos: foto %s (antes %s), linea %s', v_f1, v_f0,
                           pg_temp.t_cant(v_item)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('respuesta %s', v_res));
END
$fn$;

-- B3 · el caso del pedido 1856: cancelado y vuelto a otro estado por REST (sin
--      volver a descontar stock). Conserva motivo_cancelacion: se rechaza.
CREATE OR REPLACE FUNCTION pg_temp.caso_b3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; v_item bigint; f text[] := '{}';
  v_res jsonb; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_cancelar(v_ped, p_adm);
  UPDATE public.pedidos SET estado = 'pendiente' WHERE id = v_ped;
  v_f0 := pg_temp.t_foto(v_prod);
  v_res := pg_temp.t_salvedad_res(v_ped, v_item, 5, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'codigo' = 'pedido_cancelado',
                    format('la salvedad sobre el cancelado reactivado tendria que rechazarse: %s', v_res));
  f := pg_temp.t_si(f, v_f1 = v_f0 AND pg_temp.t_cant(v_item) = 20
                       AND NOT EXISTS (SELECT 1 FROM public.salvedades_items WHERE pedido_id = v_ped),
                    format('la salvedad sobre el reactivado dejo efectos: foto %s (antes %s), linea %s', v_f1, v_f0,
                           pg_temp.t_cant(v_item)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('respuesta %s', v_res));
END
$fn$;

DO $ensayo1127$
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
    RAISE EXCEPTION 'ens1127 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1127 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada,
  -- asi que no deja nada; si alguno falla, la migracion entera aborta.
  FOREACH v_caso IN ARRAY ARRAY['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'h7', 'r1', 'r3', 'f1', 'b1', 'b2', 'b3'] LOOP
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
    RAISE EXCEPTION E'ens1127 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1127$;

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
