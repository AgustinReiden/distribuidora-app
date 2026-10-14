-- Ensayo de #1140, #1141 y #1142.
--
-- #1140: anular_salvedad restituia la linea a cantidad_original. Con dos
-- salvedades vivas sobre la misma linea, anular la primera borraba tambien lo
-- que recorto la segunda (y bajaba menos stock del que subia la linea).
-- Decision del dueño (2026-10-13), opcion A: anular suma cantidad_afectada; sin
-- linea, la reinserta con cantidad_afectada.
-- #1141: la resincronizacion de registrar_salvedad recortaba regalos de TODAS
-- las promos del pedido, tambien de las que la salvedad no toco. Decision B:
-- solo las promos que tienen el producto de la salvedad, ninguna si la salvedad
-- es sobre un regalo, y el recorte con tope en el impacto propio, medido con
-- las reglas vigentes. Las dos simulaciones de la UI, igual.
-- #1142: check LOTE-D en auditoria_integridad() (huella > linea), en high, y
-- el tope de la huella que repone anular_salvedad. La 364 la topaba con lo que
-- se le saco al lote (v_saca); desde la 365 (anular_repone_la_traza) se repone despues
-- de la bajada, con tope en lo que le falta a la linea: solo limita cuando la
-- bajada cayo por FEFO en otro lote, y si el lote quedo agotado o solo para la
-- traza la traza vuelve entera (#1073, el X5 de 1054-1073).
--
--   A1 · dos cliente_rechaza 5+5 sobre la linea de 20: anular S1 la deja en 15
--        (no en 20) y sus 5 salen de L1; anular S2 la deja en 20 y la foto en f0.
--   A2 · dos dañados 5+5 (el H7 de la 1126/1127): anular S1 deja 15, anular S2
--        deja 20, las dos mermas anuladas.
--   A3 · S1 rechaza 5 y S2 rechaza 15 (la linea se borra): anular S1 inserta 5
--        (no 20), anular S2 le suma 15 (desde #1161 a la misma linea; antes
--        insertaba otra). A4 · lo mismo en orden inverso.
--   A5 · #1140 contra v_toca_promo: anular S1 suma 1 (19, no 25) y el regalo no
--        se mueve; anular S2 se rechaza con anulacion_toca_promociones.
--   A6 · tope de huella con bolsa 0: el lote se vacio entre registrar y anular;
--        la huella de la linea queda en 20 (17 en L1 + 3 en L2), no en 23.
--        A6b · lo mismo con bolsa 40: huella 20 en L1, sin pasar por L2 (con
--        el tope v_saca de la 364 quedaba en 17).
--        A6c · el que motivo el tope, con bolsa distinta de 0 que no alcanza
--        (1): huella 18 en L1 + 2 en L2 = 20.
--   A7 · el X5 de 1054-1073: la linea entera rechazada (se borra; la anotacion
--        guarda la huella 5) y el lote queda agotado antes de anular, con la
--        bolsa suficiente: anular repone la huella 5 entera (la 364 la dejaba
--        en 0). A7b · lo mismo con el lote solo para la traza (se sacan los
--        vencimientos de la compra).
--   B1 · A7b con un lote sin hueco (50/50): solo para la traza con cantidad 1;
--        la huella vuelve entera (5, no 1) y la cantidad del lote sube a 5.
--   B2 · lote sin hueco, linea de 20 con huella 20, rechazo de 5 y el lote solo
--        para la traza (cantidad 15): anular deja la huella en 20 (no 15) y el
--        lote en cantidad 20, restante 0.
--   R4 · #1141, promo ajena editada: un rechazo sobre X recorta solo el regalo
--        de la promo de X; el de la promo de Y no se mueve. Las simulaciones
--        listan solo la de X.
--   R5 y R5b (promo propia editada y producto sacado de la promo) salieron de
--        este ensayo con #1164: desde la foto de la promo en el pedido
--        (pedido_promo_reglas) cambiaron a proposito y son F1 y F2 de
--        scripts/test-salvedad-anular-1161-1164.sql.
--   R6 · salvedad sobre el regalo con la promo editada: sin recorte extra.
--   R7 · regresion de #831 (regalo en dos sabores) y aritmetica de bloques con
--        cantidades que no son multiplo (25 con rechazos de 4, 6 y 16).
--   L1 · LOTE-D muerde: una huella mayor que la linea la cuenta.
--
-- Cada caso termina exigiendo LOTE-D en 0 para su pedido. La bolsa es distinta
-- de 0 salvo en A6, que pide bolsa 0 a proposito (A6c es lo mismo con bolsa 1) (CLAUDE.md: con bolsa 0 la
-- bajada cae en el lote por FEFO; aca es justo lo que se quiere ver).
--
-- Corre contra prod SIN dejar rastro: cada caso se revierte en su subbloque y
-- el script termina con RAISE EXCEPTION 'ENSAYO_ROLLBACK', que revierte toda
-- la transaccion. Veredicto: 'ENSAYO FALLO (...)' con la lista de fallas, o,
-- si todo pasa, el unico error es 'ENSAYO_ROLLBACK' (el NOTICE dice ENSAYO OK
-- y trae el reporte).
--
--   psql "$DATABASE_URL" -1 -f scripts/test-salvedad-anular-1140-1142.sql
--
-- Lo que va entre las marcas <casos> y </casos> se copio en la seccion 3 de la
-- migracion 364 (anular_suma_lo_suyo) tal como estaba al aplicarla. Despues
-- (la 365, anular_repone_la_traza) cambio A6b y se sumaron A6c, A7, A7b, B1 y B2.
-- Con #1161-#1164 (salvedad_promo_del_pedido) salieron R5 y R5b (ver arriba): la
-- copia embebida en la 364 queda vieja a proposito.

-- <casos>
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

-- Huella de todas las lineas en un lote, lo que el lote consumio, y el lote
-- como texto para los mensajes.
CREATE OR REPLACE FUNCTION pg_temp.t_huella_lote(p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes WHERE lote_id = p_lote;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_consumido(p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT cantidad - cantidad_restante FROM public.producto_lotes WHERE id = p_lote;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_lote_txt(p_lote bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('cantidad %s / restante %s / solo_traza %s', cantidad, cantidad_restante, solo_traza)
    FROM public.producto_lotes WHERE id = p_lote;
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

-- La edicion de la compra como la manda la app (sincronizar_lotes_compra), con
-- la foto completa de sus vencimientos para el producto ([{dias, cantidad}]).
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_compra bigint, p_prod bigint, p_lotes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sincronizar_lotes_compra(p_compra, COALESCE((
    SELECT jsonb_agg(jsonb_build_object('producto_id', p_prod,
                                        'fecha_vencimiento', pg_temp.t_hoy() + (x->>'dias')::int,
                                        'cantidad', (x->>'cantidad')::int))
      FROM jsonb_array_elements(p_lotes) x), '[]'::jsonb));
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar la compra: %', v_res;
  END IF;
  RETURN v_res;
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

-- El punto de partida de A5/R6/R7b: X con L1 (100, 50 vivas), bolsa 0;
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
--      (la linea se borra). Anular restituye lo de CADA salvedad (5 y 15), no
--      su cantidad_original: suman 20, total 2000, foto f0, huella 20. Desde
--      #1161 la segunda anulacion le suma a la linea que reinserto la primera
--      (misma clave), asi que queda una sola (D1 del ensayo de 1161-1164 lo
--      exige; este mide la suma). p_inverso: S2 primero.
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
--          trigger por FEFO de L2, con huella para la linea. La reposicion va
--          despues y cubre lo que le falta a la linea: L1 15 + 2 y L2 3, 20.
--          Antes de la 364 le reponia 5 en L1 y quedaba en 23.
--        bolsa 40 (A6b): las otras 3 salen de la bolsa, sin huella: la
--          reposicion vuelve entera, L1 20, sin L2 (la 364 la dejaba en 17).
--        bolsa 1 (A6c): 3 de la bolsa y 2 por FEFO de L2: L1 18 y L2 2.
--      En general: FEFO = max(3 - bolsa, 0), L1 = 20 - FEFO, L2 = FEFO.
CREATE OR REPLACE FUNCTION pg_temp.t_caso_a6(p_cli bigint, p_adm uuid, p_suc bigint, p_bolsa int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_l1 bigint; v_l2 bigint; v_ped bigint; v_item bigint; v_s1 bigint;
  f text[] := '{}'; v_f jsonb; v_esp jsonb; v_fefo int;
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
  v_fefo := GREATEST(3 - p_bolsa, 0);
  v_esp := jsonb_build_object('stock', 47 + p_bolsa, 'lotes', jsonb_build_array(0, 50 - v_fefo),
                              'bolsa', GREATEST(p_bolsa - 3, 0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 20 - v_fefo AND pg_temp.t_huella(v_item, v_l2) = v_fefo,
                    format('huella L1 %s / L2 %s, esperado %s / %s',
                           pg_temp.t_huella(v_item, v_l1), pg_temp.t_huella(v_item, v_l2), 20 - v_fefo, v_fefo));
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

CREATE OR REPLACE FUNCTION pg_temp.caso_a6c(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a6(p_cli, p_adm, p_suc, 1);
$fn$;

-- A7 · #1073, el X5 de 1054-1073. Un lote (90 dias, 100, 50 vivas) y bolsa 5.
--      Pedido de 10: 5 de la bolsa y 5 del lote (huella 5). Rechazo de la
--      linea entera: la linea se borra con su huella, las 5 de la huella
--      vuelven al lote y las otras 5 a la bolsa; la anotacion guarda huella 5.
--      Antes de anular, el lote se queda sin nada:
--        'agotado' (A7): un ajuste que no es de pedido se come las 55 y
--          despues entran 40 a la bolsa;
--        'solo_traza' (A7b): se sacan los vencimientos de la compra (mig 338):
--          el lote queda solo para la traza y sus 50 pasan a la bolsa.
--      Anular: la linea vuelve con 10, la bajada sale toda de la bolsa (no
--      escribe huella) y la huella 5 vuelve entera al lote: el cliente tiene
--      esas unidades de ese lote. La 364 la dejaba en 0 (v_saca = 0).
CREATE OR REPLACE FUNCTION pg_temp.t_caso_a7(p_cli bigint, p_adm uuid, p_suc bigint, p_como text,
                                             p_cant_lote int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_l bigint; v_ped bigint; v_item bigint; v_item2 bigint; v_s bigint;
  f text[] := '{}'; v_f jsonb; v_esp jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         jsonb_build_array(jsonb_build_object('dias', 90, 'cantidad', p_cant_lote, 'restante', 50)), 5);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10);
  v_ped := p->>'pedido'; v_item := p->>'item';
  IF pg_temp.t_foto(v_prod) <> '{"stock":45,"lotes":[45],"bolsa":0}' OR pg_temp.t_huella(v_item, v_l) <> 5 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, huella %s',
                              pg_temp.t_foto(v_prod), pg_temp.t_huella(v_item, v_l))));
  END IF;
  v_s := pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  IF p_como = 'agotado' THEN
    PERFORM pg_temp.t_baja(v_prod, 55);
    PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
    v_esp := '{"stock":40,"lotes":[0],"bolsa":40}';
  ELSE
    PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
    v_esp := '{"stock":55,"lotes":[0],"bolsa":55}';
  END IF;
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f = v_esp AND pg_temp.t_cant(v_item) IS NULL,
                    format('antes de anular: foto %s y linea %s; esperado %s y sin linea', v_f,
                           pg_temp.t_cant(v_item), v_esp));
  PERFORM pg_temp.t_anular(v_s);
  SELECT id INTO v_item2 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  v_f := pg_temp.t_foto(v_prod);
  v_esp := jsonb_set(jsonb_set(v_esp, '{stock}', to_jsonb((v_esp->>'stock')::int - 10)),
                     '{bolsa}', to_jsonb((v_esp->>'bolsa')::int - 10));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item2) = 10 AND pg_temp.t_huella(v_item2, v_l) = 5
                       AND pg_temp.t_huella(v_item2, NULL) = 5,
                    format('anular dejo linea %s con huella %s en el lote (%s en total), esperado 10 y 5 (la 364: 0)',
                           pg_temp.t_cant(v_item2), pg_temp.t_huella(v_item2, v_l), pg_temp.t_huella(v_item2, NULL)));
  f := pg_temp.t_si(f, v_f = v_esp, format('anular dejo foto %s, esperado %s', v_f, v_esp));
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.producto_lotes WHERE id = v_l),
                    'el lote con la huella anotada se borro');
  f := pg_temp.t_si(f, pg_temp.t_huella_lote(v_l) <= pg_temp.t_consumido(v_l),
                    format('el lote tiene huella %s y consumido %s', pg_temp.t_huella_lote(v_l), pg_temp.t_consumido(v_l)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_a7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a7(p_cli, p_adm, p_suc, 'agotado');
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_a7b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a7(p_cli, p_adm, p_suc, 'solo_traza');
$fn$;

-- B1 · A7b con un lote SIN hueco (50, 50 vivas), que es lo comun en prod. Tras
--      el rechazo el lote vuelve a 50/50 (consumido 0) y al sacar el
--      vencimiento queda solo para la traza con cantidad 1 (GREATEST(v_cons,
--      1)), restante 0. El tope por lote daba huella 1 en vez de 5; ahora la
--      huella vuelve entera y la cantidad del lote sube a 5.
CREATE OR REPLACE FUNCTION pg_temp.caso_b1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_a7(p_cli, p_adm, p_suc, 'solo_traza', 50);
$fn$;

-- B2 · lote sin hueco (50, 50 vivas), bolsa 0 al vender: la linea de 20 sale
--      entera del lote (huella 20) y despues entran 40 a la bolsa. Rechazo de 5
--      (vuelven al lote: 50/35, huella 15). Se saca el vencimiento: el lote
--      queda solo para la traza con cantidad 15 (lo consumido), y sus 35 pasan
--      a la bolsa (75). Anular: la linea vuelve a 20, la bajada sale de la
--      bolsa (70) y la huella vuelve a 20 (el tope por lote la dejaba en 15);
--      la cantidad del lote sube a 20.
CREATE OR REPLACE FUNCTION pg_temp.caso_b2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_l bigint; v_ped bigint; v_item bigint; v_s bigint;
  f text[] := '{}'; v_f jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":50,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l := v->'lotes'->>0;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 40);
  IF pg_temp.t_foto(v_prod) <> '{"stock":70,"lotes":[30],"bolsa":40}' OR pg_temp.t_huella(v_item, v_l) <> 20 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s, huella %s',
                              pg_temp.t_foto(v_prod), pg_temp.t_huella(v_item, v_l))));
  END IF;
  v_s := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  PERFORM pg_temp.t_editar((v->>'compra')::bigint, v_prod, '[]');
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f = '{"stock":75,"lotes":[0],"bolsa":75}' AND pg_temp.t_cant(v_item) = 15
                       AND pg_temp.t_huella(v_item, v_l) = 15
                       AND (SELECT solo_traza AND cantidad = 15 FROM public.producto_lotes WHERE id = v_l),
                    format('antes de anular: foto %s, linea %s, huella %s, lote %s', v_f, pg_temp.t_cant(v_item),
                           pg_temp.t_huella(v_item, v_l), pg_temp.t_lote_txt(v_l)));
  PERFORM pg_temp.t_anular(v_s);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 20 AND pg_temp.t_huella(v_item, v_l) = 20
                       AND pg_temp.t_huella(v_item, NULL) = 20,
                    format('anular dejo linea %s con huella %s en el lote (%s en total), esperado 20 y 20 (el tope por lote: 15)',
                           pg_temp.t_cant(v_item), pg_temp.t_huella(v_item, v_l), pg_temp.t_huella(v_item, NULL)));
  f := pg_temp.t_si(f, v_f = '{"stock":70,"lotes":[0],"bolsa":70}',
                    format('anular dejo foto %s, esperado {"stock":70,"lotes":[0],"bolsa":70}', v_f));
  f := pg_temp.t_si(f, (SELECT solo_traza AND cantidad = 20 AND cantidad_restante = 0
                          FROM public.producto_lotes WHERE id = v_l),
                    format('el lote quedo %s, esperado solo para la traza con cantidad 20 y restante 0',
                           pg_temp.t_lote_txt(v_l)));
  f := pg_temp.t_si(f, pg_temp.t_huella_lote(v_l) <= pg_temp.t_consumido(v_l),
                    format('el lote tiene huella %s y consumido %s', pg_temp.t_huella_lote(v_l), pg_temp.t_consumido(v_l)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
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

-- R5 y R5b: ver F1 y F2 de scripts/test-salvedad-anular-1161-1164.sql (#1164).

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
-- </casos>

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
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
    RAISE EXCEPTION 'el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada: no
  -- deja nada.
  FOREACH v_caso IN ARRAY ARRAY['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a6b', 'a6c', 'a7', 'a7b', 'b1', 'b2',
                                'r4', 'r6', 'r7a', 'r7b', 'l1'] LOOP
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
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK';
END
$ensayo$;

-- Nada de lo de arriba queda escrito: la transaccion se revierte entera.
DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
