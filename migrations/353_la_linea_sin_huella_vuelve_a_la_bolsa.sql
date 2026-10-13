-- La linea sin huella vuelve a la bolsa (#1114)
--
-- La bajada del trigger come primero la bolsa (sincronizar_lotes_stock:
-- v_bolsa := OLD.stock - v_asignado), y lo que saca de un lote con la linea en
-- app.stock_pedido_item_id deja huella en pedido_item_lotes. El alta deja
-- huella desde la 256; la edicion y el bot, recien desde la 349. Una linea de
-- ESTE producto sin ninguna huella salio entonces de la bolsa. Pero
-- _restaurar_lotes_fefo cortaba la pasada 2 (FEFO) solo si habia huella
-- (`v_pasada = 2 AND v_huella_total > 0`, mig 342): sin huella, la devolucion
-- de esa linea -- cancelar_pedido_con_stock y eliminar_pedido_completo con
-- 'pedido_cancelado' / 'pedido_eliminado', y registrar_salvedad con
-- 'salvedad', las tres con la linea en el GUC -- entraba por FEFO a cualquier
-- lote con hueco: el lote quedaba +N y la bolsa -N, el contador que miente de
-- #1050 / #1097. Medido en prod con scripts/test-cancelar-sin-huella-1114.sql
-- (caso C1: L2 vacio que vence antes, L1 100/50, bolsa 40, pedido 20 de la
-- bolsa; cancelar dejaba L2 en 20 y la bolsa en 20, no L2 en 0 y bolsa 40).
-- Exposicion al momento de escribir esto: 17 lineas sin huella en pedidos
-- 'asignado' (8052 a 8063).
--
-- Decision del dueño (2026-10-13): el arreglo es central, en
-- _restaurar_lotes_fefo. Una linea de este producto (la del GUC, de esta
-- sucursal y de este producto) sin huella, o lo que excede su huella, vuelve
-- a la bolsa: la pasada 2 no corre. Cubre cancelar, eliminar y
-- registrar_salvedad (la linea y el exceso del regalo). FEFO queda solo para
-- la devolucion que NO dice su linea: a nivel pedido, o que no es de un pedido.
-- Esto invierte el caso U1 de la mig 342, que el dueño habia fijado el
-- 2026-10-10 ("sin huella, FEFO"), con su OK del 2026-10-13.
--
-- Lo que no se hace:
--   - No se reparan los lotes que quedaron +N por cancelaciones pasadas de
--     lineas sin huella: son como mucho 16 u. en 5 pedidos de entre la 256 y
--     la 349, y no hay forma de saber a que lote entraron (el ledger no guarda
--     el lote y la huella se borro al cancelar). Un ajuste a ciegas mueve el
--     error de lugar.
--   - Una linea sin huella que SI salio de un lote y no se detecto (ediciones
--     anteriores a la 349 con la bolsa en 0, el bot antes de la 349, pedidos
--     anteriores a la 256) ahora vuelve a la bolsa. Con FEFO tambien era una
--     suposicion. La unica viva y cancelable que se encontro es el pedido 6194
--     (VB entregado): sus lineas 22581 (producto 178) y 22582 (producto 183)
--     no tienen huella, pero segun stock_historico salieron de los lotes 40 y
--     41 (una edicion anterior a la 349 con la bolsa en 0). La seccion 0 les
--     siembra esa huella, verificada antes contra el ledger.
--
-- El chequeo de la fuga del GUC de linea (seccion 2) es un regex sobre el
-- codigo: una ayuda, no una prueba. La prueba es el caso U5 del ensayo.
--
-- Funcion parcheada en vivo (cada fragmento tiene que aparecer exactamente
-- una vez o la migracion aborta). Firma, SECURITY DEFINER, search_path y
-- GRANTs: como estaban. No toca productos.stock ni orígenes del ledger, asi
-- que STK-F y STK-D no cambian. cancelar_pedido_con_stock,
-- eliminar_pedido_completo y registrar_salvedad no se tocan: cambian por
-- _restaurar_lotes_fefo.

-- ---------------------------------------------------------------------------
-- 0 - La huella del pedido 6194, desde stock_historico
-- ---------------------------------------------------------------------------
-- Para cada linea se verifica, y si algo no coincide la migracion aborta:
--   - la linea es del pedido 6194, de ese producto, con esa cantidad, el
--     pedido no esta cancelado y la linea no tiene ninguna huella;
--   - el lote es el UNICO del producto, no es solo para la traza, nacio de una
--     compra cuya entrada partio de stock 0 y trajo exactamente lo que dice el
--     lote, y ningun movimiento cayo entre esa entrada y el alta del lote: la
--     bolsa arranco en 0;
--   - entre la entrada de la compra y la ultima bajada del pedido 6194 de ese
--     producto, ningun movimiento subio stock con un origen fuera de la lista
--     blanca de sincronizar_lotes_stock (eso habria llenado la bolsa): la
--     bolsa siguio en 0, asi que la bajada salio del lote;
--   - al lote le sobra consumo sin huella para cubrir la que se siembra.
-- No toca productos.stock ni cantidad_restante: las unidades ya salieron del
-- lote; solo falta la traza.

DO $huella6194$
DECLARE
  r       record;
  v_lote  public.producto_lotes%ROWTYPE;
  v_suc   bigint;
  v_m0    record;
  v_baja  bigint;
  v_n     integer;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES (22581::bigint, 40::bigint, 178::bigint, 2),
                          (22582::bigint, 41::bigint, 183::bigint, 2)) AS t(item, lote, prod, cant)
  LOOP
    SELECT pi.sucursal_id INTO v_suc
      FROM public.pedido_items pi
      JOIN public.pedidos p ON p.id = pi.pedido_id AND p.sucursal_id = pi.sucursal_id
     WHERE pi.id = r.item AND pi.pedido_id = 6194 AND pi.producto_id = r.prod
       AND pi.cantidad = r.cant AND p.estado <> 'cancelado';
    IF v_suc IS NULL THEN
      RAISE EXCEPTION 'huella 6194 · la linea % ya no es la que se midio (pedido 6194, producto %, % u., no cancelado)',
        r.item, r.prod, r.cant;
    END IF;
    IF EXISTS (SELECT 1 FROM public.pedido_item_lotes WHERE pedido_item_id = r.item) THEN
      RAISE EXCEPTION 'huella 6194 · la linea % ya tiene huella: revisar a mano', r.item;
    END IF;

    SELECT * INTO v_lote FROM public.producto_lotes
     WHERE id = r.lote AND producto_id = r.prod AND sucursal_id = v_suc;
    IF NOT FOUND OR v_lote.solo_traza
       OR (SELECT count(*) FROM public.producto_lotes WHERE producto_id = r.prod) <> 1 THEN
      RAISE EXCEPTION 'huella 6194 · el lote % no es el unico lote vivo del producto %', r.lote, r.prod;
    END IF;

    SELECT sh.id, sh.stock_anterior, sh.diferencia, sh.created_at INTO v_m0
      FROM public.stock_historico sh
     WHERE sh.producto_id = r.prod AND sh.referencia_tipo = 'compra' AND sh.referencia_id = v_lote.compra_id
     ORDER BY sh.id LIMIT 1;
    IF v_m0.id IS NULL OR v_m0.stock_anterior <> 0 OR v_m0.diferencia <> v_lote.cantidad
       OR EXISTS (SELECT 1 FROM public.stock_historico sh
                   WHERE sh.producto_id = r.prod AND sh.id > v_m0.id AND sh.created_at < v_lote.created_at) THEN
      RAISE EXCEPTION 'huella 6194 · la compra % del lote % no arranca con la bolsa en 0', v_lote.compra_id, r.lote;
    END IF;

    SELECT max(sh.id) INTO v_baja
      FROM public.stock_historico sh
     WHERE sh.producto_id = r.prod AND sh.referencia_tipo = 'pedido' AND sh.referencia_id = 6194
       AND sh.diferencia < 0;
    SELECT count(*) INTO v_n
      FROM public.stock_historico sh
     WHERE sh.producto_id = r.prod AND sh.id > v_m0.id AND sh.id <= v_baja AND sh.diferencia > 0
       AND sh.origen NOT IN ('pedido_creado', 'pedido_creado_bot', 'pedido_cancelado',
                             'pedido_eliminado', 'salvedad', 'sustitucion_regalo',
                             'auto_ajuste_promo', 'movimiento_denegado',
                             'movimiento_cancelado', 'cambio_producto',
                             'movimiento_editado');
    IF v_baja IS NULL OR v_n > 0 OR v_lote.created_at > (SELECT created_at FROM public.stock_historico WHERE id = v_baja) THEN
      RAISE EXCEPTION 'huella 6194 · entre la compra y la bajada del pedido 6194 la bolsa del producto % no siguio en 0', r.prod;
    END IF;

    IF (v_lote.cantidad - v_lote.cantidad_restante)
       - (SELECT COALESCE(SUM(cantidad), 0) FROM public.pedido_item_lotes WHERE lote_id = r.lote) < r.cant THEN
      RAISE EXCEPTION 'huella 6194 · al lote % no le sobra consumo sin huella para % u.', r.lote, r.cant;
    END IF;

    INSERT INTO public.pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)
    VALUES (r.item, r.lote, r.cant, v_suc);
  END LOOP;
END
$huella6194$;

-- ---------------------------------------------------------------------------
-- 1 - _restaurar_lotes_fefo
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

DO $restaurar$
DECLARE
  v_def text := pg_get_functiondef('public._restaurar_lotes_fefo(bigint,bigint,integer)'::regprocedure);
BEGIN
  -- 1a · si el caller dijo una linea de ESTE producto.
  v_def := pg_temp.parchar(v_def,
$q$  v_huella_total integer;
BEGIN
$q$,
$q$  v_huella_total integer;
  -- #1114: el caller dijo una linea de ESTE producto (de esta sucursal). Si la
  -- dijo, lo que no cubre su huella salio de la bolsa y vuelve a la bolsa.
  v_linea_propia boolean := false;
BEGIN
$q$, '1a');

  -- 1b · el comentario de la regla de la 342.
  v_def := pg_temp.parchar(v_def,
$q$  -- +N con unidades de otra fecha. La segunda pasada queda para lo que no
  -- tiene ninguna huella (bot, pedidos anteriores a la 256, devoluciones que no
  -- son de un pedido), donde no hay forma de saber de donde salio.
$q$,
$q$  -- +N con unidades de otra fecha. #1114: lo mismo si el caller dijo una
  -- linea de este producto aunque no tenga huella: la bajada come la bolsa
  -- primero y desde la 349 toda bajada con linea deja huella (el alta desde la
  -- 256; la edicion y el bot recien desde la 349), asi que esa linea salio de
  -- la bolsa. La segunda pasada (FEFO) queda para la devolucion que no dice su
  -- linea -- a nivel pedido, o que no es de un pedido --, donde no hay forma de
  -- saber de donde salio.
$q$, '1b');

  -- 1c · la pasada 2 no corre si hay huella o si la linea es de este producto.
  v_def := pg_temp.parchar(v_def,
$q$  FOR v_pasada IN 1..2 LOOP
    EXIT WHEN v_pendiente <= 0 OR (v_pasada = 2 AND v_huella_total > 0);
$q$,
$q$  IF v_item_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.pedido_items pi
       WHERE pi.id = v_item_id
         AND pi.sucursal_id = p_sucursal_id
         AND pi.producto_id = p_producto_id
    ) INTO v_linea_propia;
  END IF;

  FOR v_pasada IN 1..2 LOOP
    EXIT WHEN v_pendiente <= 0 OR (v_pasada = 2 AND (v_huella_total > 0 OR v_linea_propia));
$q$, '1c');

  EXECUTE v_def;
END
$restaurar$;

DROP FUNCTION pg_temp.parchar(text, text, text, text);

-- ---------------------------------------------------------------------------
-- 2 - Verificacion estructural
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_res  text := pg_get_functiondef('public._restaurar_lotes_fefo(bigint,bigint,integer)'::regprocedure);
  v_sinc text := pg_get_functiondef('public.sincronizar_lotes_stock()'::regprocedure);
  r      record;
  v_tok  text;
  v_abierta boolean;
BEGIN
  IF v_res NOT LIKE '%SECURITY DEFINER%'
     OR v_res NOT LIKE '%EXIT WHEN v_pendiente <= 0 OR (v_pasada = 2 AND (v_huella_total > 0 OR v_linea_propia));%'
     OR v_res NOT LIKE '%AND pi.producto_id = p_producto_id%' THEN
    RAISE EXCEPTION '_restaurar_lotes_fefo no quedo como se esperaba';
  END IF;
  IF has_function_privilege('anon', 'public._restaurar_lotes_fefo(bigint,bigint,integer)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._restaurar_lotes_fefo(bigint,bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los permisos de _restaurar_lotes_fefo cambiaron';
  END IF;
  -- La devolucion de una edicion y la de un regalo rehecho se cancelan con la
  -- bajada que sigue: van a la bolsa por estar fuera de la lista blanca (349).
  IF v_sinc LIKE '%''pedido_editado''%' OR v_sinc LIKE '%''sustitucion_regalo_rehecha''%' THEN
    RAISE EXCEPTION 'la lista blanca de sincronizar_lotes_stock cambio: revisar #1114 contra la 349';
  END IF;

  -- Ayuda, no prueba (la prueba es el caso U5): toda funcion que pone una
  -- linea en app.stock_pedido_item_id la restaura antes de llamar a
  -- aplicar_uso_promo_acumulador, que puede mover stock del mismo producto
  -- sin decir su linea.
  FOR r IN
    SELECT p.oid::regprocedure AS f, pg_get_functiondef(p.oid) AS d
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f'
       AND pg_get_functiondef(p.oid) LIKE '%set_config(''app.stock_pedido_item_id''%'
  LOOP
    v_abierta := false;
    FOR v_tok IN
      SELECT m[1] FROM regexp_matches(
        regexp_replace(
          regexp_replace(
            regexp_replace(r.d,
              'set_config\(''app\.stock_pedido_item_id'',\s*(COALESCE\(v_(item_guc|g_item),\s*''''\)|'''')', '#R#', 'g'),
            'set_config\(''app\.stock_pedido_item_id'',', '#S#', 'g'),
          'aplicar_uso_promo_acumulador\(', '#A#', 'g'),
        '#([RSA])#', 'g') m
    LOOP
      IF v_tok = 'S' THEN v_abierta := true;
      ELSIF v_tok = 'R' THEN v_abierta := false;
      ELSIF v_abierta THEN
        RAISE EXCEPTION '% llama a aplicar_uso_promo_acumulador con una linea en app.stock_pedido_item_id', r.f;
      END IF;
    END LOOP;
    IF v_abierta THEN
      RAISE EXCEPTION '% deja una linea puesta en app.stock_pedido_item_id al terminar', r.f;
    END IF;
  END LOOP;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 3 - Ensayo con datos reales: los casos de
--     scripts/test-cancelar-sin-huella-1114.sql (ver ahi cada uno). La corrida
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
  VALUES ('ZZ ensayo 1114', 100,
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
    'ensayo 1114');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_prod));
END
$fn$;

-- Un regalo de `p_n` del MISMO producto, de una promo que mueve stock, y su
-- bajada con su linea (como el alta). Con `p_compra`/`p_bonif` la promo tiene
-- reglas "cada p_compra, p_bonif de regalo" sobre el producto, para que la
-- resincronizacion de registrar_salvedad lo recorte. Devuelve el id del regalo.
CREATE OR REPLACE FUNCTION pg_temp.t_regalo(p_ped bigint, p_prod bigint, p_suc bigint, p_n int,
                                            p_compra int DEFAULT NULL, p_bonif int DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint; v_regalo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1114', 'bonificacion', CURRENT_DATE, p_suc, true, p_prod) RETURNING id INTO v_promo;
  IF p_compra IS NOT NULL THEN
    INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_promo, 'cantidad_compra', p_compra, p_suc),
           (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
    INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
    VALUES (v_promo, p_prod, p_suc);
  END IF;
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

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo 1114: descripcion del caso', NULL, true, NULL);
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
  v_res := public.anular_salvedad(p_salv, 'ensayo 1114');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cancelar(p_ped bigint, p_adm uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1114', p_adm, NULL);
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
  PERFORM set_config('app.stock_origen', 'ensayo_1114', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- Una devolucion "a mano" con los GUCs dados (vacio = sin poner).
CREATE OR REPLACE FUNCTION pg_temp.t_devolver(p_prod bigint, p_n int, p_origen text,
                                              p_ref_tipo text, p_ref_id bigint, p_item bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', p_origen, true);
  PERFORM set_config('app.stock_ref_tipo', COALESCE(p_ref_tipo, ''), true);
  PERFORM set_config('app.stock_ref_id', COALESCE(p_ref_id::text, ''), true);
  PERFORM set_config('app.stock_pedido_item_id', COALESCE(p_item::text, ''), true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- C1 · L2 vence a 30 dias y esta vacio (50, 0 vivas); L1 vence a 90 (100, 50
--      vivas). Bolsa 40. Pedido 20: sale entero de la bolsa, sin huella.
--      Cancelar: las 20 vuelven a la bolsa. Antes caian por FEFO en L2.
CREATE OR REPLACE FUNCTION pg_temp.caso_c1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":70,"lotes":[0,50],"bolsa":20}' OR pg_temp.t_huella((p->>'item')::bigint, NULL) <> 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":90,"lotes":[0,50],"bolsa":40}',
                    format('cancelar dejo %s, esperado {stock 90, lotes [0,50], bolsa 40}: salio de la bolsa, vuelve a la bolsa', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((p->>'item')::bigint, NULL) = 0, 'el pedido cancelado quedo con huella');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- C2 · lo mismo, eliminando el pedido con restauracion de stock.
CREATE OR REPLACE FUNCTION pg_temp.caso_c2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_res jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":70,"lotes":[0,50],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  v_res := public.eliminar_pedido_completo((p->>'pedido')::bigint, p_adm, 'ensayo 1114', true);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'eliminar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":90,"lotes":[0,50],"bolsa":40}',
                    format('eliminar dejo %s, esperado {stock 90, lotes [0,50], bolsa 40}', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- C3 · huella parcial. Bolsa 5, pedido 20: 5 de la bolsa y 15 de L1 (huella
--      15). Se suman 20 a la bolsa. Cancelar: 15 a L1 y 5 a la bolsa.
CREATE OR REPLACE FUNCTION pg_temp.caso_c3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":55,"lotes":[0,35],"bolsa":20}' OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 15 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar dejo %s, esperado {stock 75, lotes [0,50], bolsa 25}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((p->>'item')::bigint, NULL) = 0, 'el pedido cancelado quedo con huella');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- C4 · bolsa 0 al crear: la linea X de 20 sale de L1 (huella 20). Se suman 10
--      a la bolsa y despues el regalo R de 4 del mismo producto sale de la
--      bolsa (sin huella). Cancelar: X vuelve a L1 y R a la bolsa; ningun lote
--      queda por encima de como estaba antes del pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_c4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; p jsonb; v_r bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 10);
  v_r := pg_temp.t_regalo((p->>'pedido')::bigint, v_prod, p_suc, 4);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":36,"lotes":[0,30],"bolsa":6}'
     OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 20 OR pg_temp.t_huella(v_r, NULL) <> 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":60,"lotes":[0,50],"bolsa":10}',
                    format('cancelar dejo %s, esperado {stock 60, lotes [0,50], bolsa 10}: X a L1, R a la bolsa', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((p->>'item')::bigint, NULL) = 0 AND pg_temp.t_huella(v_r, NULL) = 0,
                    'el pedido cancelado quedo con huella');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- C5 · el U1 de la 342, invertido. L1 (100, 50 vivas), bolsa 40, pedido 20
--      de la bolsa. Salvedad de 10: a la bolsa, y lotes_devueltos sin ninguna
--      unidad en un lote. Anular deja todo como despues del pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_c5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_salv bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
  v_anot jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":70,"lotes":[50],"bolsa":20}' OR pg_temp.t_huella((p->>'item')::bigint, NULL) <> 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  v_salv := pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  SELECT lotes_devueltos INTO v_anot FROM public.salvedades_items WHERE id = v_salv;
  f := pg_temp.t_si(f, v_f1 = '{"stock":80,"lotes":[50],"bolsa":30}',
                    format('la salvedad dejo %s, esperado {stock 80, lotes [50], bolsa 30}: sin huella, a la bolsa', v_f1));
  f := pg_temp.t_si(f, v_anot IS NOT NULL AND NOT EXISTS (
                         SELECT 1 FROM jsonb_array_elements(v_anot) x WHERE (x->>'cantidad')::int > 0),
                    format('lotes_devueltos anoto unidades en un lote: %s', v_anot));
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s; despues del pedido era %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella((p->>'item')::bigint, NULL) = 0, 'anular le invento huella a la linea');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

-- C6 · salvedad por dañado (devolucion 'salvedad_merma' + merma). (a) Linea
--      sin huella: L1 (100, 50 vivas), bolsa 40, pedido 20 de la bolsa. (b)
--      Linea con huella: bolsa 0 al crear (sale de L1), despues 40 a la
--      bolsa. En los dos, la salvedad de 10 no mueve ni lotes ni bolsa.
CREATE OR REPLACE FUNCTION pg_temp.caso_c6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; p jsonb; f text[] := '{}';
  v_a0 jsonb; v_a1 jsonb; v_b0 jsonb; v_b1 jsonb;
BEGIN
  -- (a) sin huella
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_a0 := pg_temp.t_foto(v_prod);
  IF v_a0 <> '{"stock":70,"lotes":[50],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('(a) punto de partida: %s', v_a0)));
  END IF;
  PERFORM pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'producto_danado');
  v_a1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_a1 = v_a0, format('(a) sin huella, la salvedad por dañado dejo %s; antes %s', v_a1, v_a0));

  -- (b) con huella
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
  v_b0 := pg_temp.t_foto(v_prod);
  IF v_b0 <> '{"stock":70,"lotes":[30],"bolsa":40}' OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 20 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('(b) punto de partida: %s', v_b0)));
  END IF;
  PERFORM pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'producto_danado');
  v_b1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_b1 = v_b0, format('(b) con huella, la salvedad por dañado dejo %s; antes %s (el lote tiene que quedar en 30, no subir)', v_b1, v_b0));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('(a) %s / %s · (b) %s / %s, huella de la linea despues: %s',
                      v_a0, v_a1, v_b0, v_b1, pg_temp.t_huella((p->>'item')::bigint, NULL)));
END
$fn$;

-- C7 · el exceso del regalo. Bolsa 0 al crear: X de 20 sale de L1 (huella
--      20). 10 a la bolsa. Regalo R de 4 (promo 10 + 2 sobre el producto) sale
--      de la bolsa (sin huella). Salvedad de 10 sobre X: X queda en 10, la
--      promo da 2 de regalo y recorta 2 de R. Las 10 de X vuelven a L1 y las
--      2 de R a la bolsa (antes, por FEFO, a L2).
CREATE OR REPLACE FUNCTION pg_temp.caso_c7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; p jsonb; v_r bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 10);
  v_r := pg_temp.t_regalo((p->>'pedido')::bigint, v_prod, p_suc, 4, 10, 2);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":36,"lotes":[0,30],"bolsa":6}'
     OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 20 OR pg_temp.t_huella(v_r, NULL) <> 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, (SELECT cantidad FROM public.pedido_items WHERE id = v_r) = 2,
                    format('la resincronizacion no recorto el regalo a 2: quedo %s',
                           (SELECT cantidad FROM public.pedido_items WHERE id = v_r)));
  f := pg_temp.t_si(f, v_f1 = '{"stock":48,"lotes":[0,40],"bolsa":8}',
                    format('la salvedad dejo %s, esperado {stock 48, lotes [0,40], bolsa 8}: X a L1, el exceso de R a la bolsa', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((p->>'item')::bigint, v_l1) = 10,
                    format('la huella de X en L1 quedo %s, esperado 10', pg_temp.t_huella((p->>'item')::bigint, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- U2 · una devolucion que no es de un pedido sigue por FEFO.
CREATE OR REPLACE FUNCTION pg_temp.caso_u2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  PERFORM pg_temp.t_devolver(v_prod, 10, 'movimiento_cancelado', 'movimiento', 1, NULL);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":100,"lotes":[60],"bolsa":40}',
                    format('la devolucion sin pedido dejo %s, esperado {stock 100, lotes [60], bolsa 40} (FEFO)', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- U3 · una devolucion a nivel pedido (sin linea), de un pedido sin huella,
--      sigue por FEFO.
CREATE OR REPLACE FUNCTION pg_temp.caso_u3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_devolver(v_prod, 10, 'pedido_cancelado', 'pedido', (p->>'pedido')::bigint, NULL);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":80,"lotes":[60],"bolsa":20}',
                    format('la devolucion a nivel pedido dejo %s, esperado {stock 80, lotes [60], bolsa 20} (FEFO)', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- U4 · el GUC apunta a una linea de OTRO producto (Q): la devolucion de P
--      sigue por FEFO.
CREATE OR REPLACE FUNCTION pg_temp.caso_u4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_p bigint; v_q bigint; q jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_p := v->>'prod';
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_q := v->>'prod';
  q := pg_temp.t_pedido(p_cli, p_adm, v_q, 20);
  PERFORM pg_temp.t_devolver(v_p, 10, 'salvedad', 'pedido', (q->>'pedido')::bigint, (q->>'item')::bigint);
  v_f1 := pg_temp.t_foto(v_p);
  f := pg_temp.t_si(f, v_f1 = '{"stock":100,"lotes":[60],"bolsa":40}',
                    format('con la linea de otro producto la devolucion dejo %s, esperado {stock 100, lotes [60], bolsa 40} (FEFO)', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- U5 · la fuga del GUC de linea, por comportamiento. Pedido X de 20 de la
--      bolsa. En el mismo cuerpo: devolucion de 5 CON la linea X (a la bolsa),
--      restauracion del GUC como la hacen los callers (229), y devolucion de 5
--      a nivel pedido, sin linea: esa sigue por FEFO (al lote), no hereda X.
CREATE OR REPLACE FUNCTION pg_temp.caso_u5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f1 jsonb; v_guc text;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM set_config('app.stock_origen', 'pedido_cancelado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', (p->>'pedido'), true);
  v_guc := current_setting('app.stock_pedido_item_id', true);
  PERFORM set_config('app.stock_pedido_item_id', (p->>'item'), true);
  UPDATE public.productos SET stock = stock + 5 WHERE id = v_prod;
  PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_guc, ''), true);
  UPDATE public.productos SET stock = stock + 5 WHERE id = v_prod;
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":80,"lotes":[55],"bolsa":25}',
                    format('dejo %s, esperado {stock 80, lotes [55], bolsa 25}: 5 de la linea a la bolsa, 5 sin linea por FEFO', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;
DO $ensayo1114$
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
    RAISE EXCEPTION 'ens1114 · el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'ens1114 · el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada,
  -- asi que no deja nada; si alguno falla, la migracion entera aborta.
  FOREACH v_caso IN ARRAY ARRAY['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'u2', 'u3', 'u4', 'u5'] LOOP
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
    RAISE EXCEPTION E'ens1114 · el ensayo fallo (% fallas), la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo1114$;

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
