-- Ensayo de #1161, #1162, #1163 y #1164.
--
-- #1161: anular_salvedad, con la linea ya borrada, reinsertaba siempre una
-- linea nueva aunque el pedido ya tuviera otra del producto. Decision del
-- dueño (2026-10-14, opcion A): suma a la linea con la clave completa
-- (producto, si es regalo, promo y mismo precio); si no hay, inserta. Rechaza
-- 'pedido_editado' si hubo una edicion de items despues de la salvedad, y la
-- salvedad vieja a precio 0 con es_bonificacion NULL (un regalo).
-- #1162: v_toca_promo miraba todas las promos de la sucursal con el producto;
-- ahora solo las de la foto del pedido.
-- #1163: anular no miraba la nota de credito vigente; ahora la rechaza como
-- registrar_salvedad (mig 276).
-- #1164: la foto de la promo en el pedido (pedido_promo_reglas, la toma un
-- trigger al insertar el regalo y se rehace en cada edicion, no al dividir).
-- Las cuatro funciones de salvedades miden con ella (promos_del_pedido).
--
--   D1 · [F] A3 con una sola linea: S1 rechaza 5 y S2 15 (se borra la linea);
--        anular S1 inserta 5 y anular S2 le suma: una linea de 20.
--   D2 · [F] una edicion sin cambios (no deja historial) reinserta la linea:
--        anular reasocia y queda una sola linea.
--   D3 · [F] edicion con cambios despues de la salvedad: anular rechaza con
--        'pedido_editado' sin mover nada.
--   D3b · [R] la edicion con cambios ANTES de la salvedad no bloquea.
--   D4 · [R] no fusiona una venta con el regalo del mismo producto.
--   D5 · [R] con otra linea del producto a otro precio no fusiona.
--   D6 · [F] salvedad vieja (es_bonificacion y promocion_id NULL, precio 0):
--        rechaza con anulacion_toca_promociones (hoy tira check_violation).
--   P1 · [F] promo creada despues de la venta, sin regalo en el pedido: anular
--        pasa (antes la rechazaba v_toca_promo).
--   P2 · [R] el regalo lo borro la propia salvedad: anular sigue rechazando.
--   N1 · [F] con NC vigente anular rechaza con 'nota_credito_vigente'; anulada
--        la NC, pasa.
--   F1 · [F] el R5 nuevo: 10+2 editada a 10+1, rechazo de 10 sobre 20: el
--        regalo queda en 2 (la foto), y las dos simulaciones lo predicen.
--   F2 · [F] el R5b nuevo: el producto sale de la promo despues de la venta:
--        el rechazo entero recorta el regalo a 0 y anular rechaza.
--   F3 · [F] la edicion rehace la foto con la regla vigente (payload de la UI,
--        regalo recalculado a 2).
--   F3b · [F] la llamada directa que reenvia el regalo viejo (4) tambien rehace
--        la foto: es el comportamiento elegido; el caso lo deja a la vista.
--   F4 · [F] dividir el regalo no rehace la foto.
--   F5 · [F] sin foto, promos_del_pedido usa lo vigente (el R5 viejo: 3).
--   F6 · [F] el backfill: ninguna linea de regalo viva sin foto.
--
-- [F] falla sin la migracion y pasa con ella; [R] pasa antes y despues.
--
-- Tiempos: todo corre en una transaccion, asi que now() es el mismo para la
-- salvedad y para la edicion (salvedades_items.created_at y
-- pedido_historial.created_at tienen default now()). Para ordenarlas, D3 y
-- D3b retrasan un minuto la fila que tiene que ir primero; el guard de anular
-- sigue en `>`.
--
-- Corre contra prod SIN dejar rastro: cada caso se revierte en su subbloque y
-- el script termina con RAISE EXCEPTION 'ENSAYO_ROLLBACK', que revierte toda
-- la transaccion. Veredicto: 'ENSAYO FALLO (...)' con la lista de fallas, o,
-- si todo pasa, el unico error es 'ENSAYO_ROLLBACK' (el NOTICE dice ENSAYO OK).
--
--   psql "$DATABASE_URL" -1 -f scripts/test-salvedad-anular-1161-1164.sql
--
-- Los helpers t_* son los de scripts/test-salvedad-anular-1140-1142.sql.

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

CREATE OR REPLACE FUNCTION pg_temp.t_huella(p_item bigint, p_lote bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes
   WHERE pedido_item_id = p_item AND (p_lote IS NULL OR lote_id = p_lote);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_huella_ped(p_ped bigint, p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(pil.cantidad), 0)::int
    FROM public.pedido_item_lotes pil
    JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.pedido_id = p_ped AND pi.producto_id = p_prod;
$fn$;

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

-- Cuantas lineas de venta (no regalo) tiene un producto en un pedido.
CREATE OR REPLACE FUNCTION pg_temp.t_lineas(p_ped bigint, p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT count(*)::int FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND NOT COALESCE(es_bonificacion, false);
$fn$;

-- La linea de venta (la de id mas bajo) de un producto en un pedido.
CREATE OR REPLACE FUNCTION pg_temp.t_linea(p_ped bigint, p_prod bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND NOT COALESCE(es_bonificacion, false)
   ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_regalos(p_ped bigint, p_promo bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_items
   WHERE pedido_id = p_ped AND promocion_id = p_promo AND COALESCE(es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_total(p_ped bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT total FROM public.pedidos WHERE id = p_ped;
$fn$;

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

-- La foto de la promo en el pedido (NULL si no hay). plpgsql a proposito: sin
-- la migracion la tabla no existe y una funcion sql no se podria crear.
CREATE OR REPLACE FUNCTION pg_temp.t_foto_promo(p_ped bigint, p_promo bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb;
BEGIN
  SELECT jsonb_build_object('compra', f.cantidad_compra, 'bonif', f.cantidad_bonificacion,
                            'productos', to_jsonb(f.productos), 'origen', f.origen)
    INTO v
    FROM public.pedido_promo_reglas f
   WHERE f.pedido_id = p_ped AND f.promocion_id = p_promo;
  RETURN v;
END
$fn$;

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
  VALUES ('ZZ ensayo 1161', 100,
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
    'ensayo 1161');
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

CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_prods bigint[], p_compra int, p_bonif int,
                                           p_regalo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1161', 'bonificacion', CURRENT_DATE, p_suc, true, p_regalo) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc),
         (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  SELECT v_promo, x, p_suc FROM unnest(p_prods) x;
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_editar_bonif(p_promo bigint, p_bonif int)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.promocion_reglas SET valor = p_bonif
   WHERE promocion_id = p_promo AND clave = 'cantidad_bonificacion';
$fn$;

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

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo 1161: descripcion del caso', NULL, true, NULL);
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
  v_res := public.anular_salvedad(p_salv, 'ensayo 1161');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

-- ¿anular rechazo con este codigo?
CREATE OR REPLACE FUNCTION pg_temp.t_rechaza(p_res jsonb, p_codigo text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT COALESCE((p_res->>'success')::boolean, false) AND p_res->>'codigo' = p_codigo;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_simular(p_ped bigint, p_item bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_array(s.promocion_id, s.bonif_esperada, s.delta) ORDER BY s.promocion_id),
                  '[]'::jsonb)
    FROM public.simular_salvedad_promo_impacto(p_ped, p_item, p_cant) s;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_simular_lote(p_ped bigint, p_salv jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_array(s.pedido_item_id, s.cantidad_final) ORDER BY s.pedido_item_id),
                  '[]'::jsonb)
    FROM public.simular_salvedades_promo_impacto(p_ped, p_salv) s
   WHERE s.delta > 0;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1161', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- Los GUCs de stock en blanco, despues de una RPC que los deja seteados.
CREATE OR REPLACE FUNCTION pg_temp.t_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- La edicion del pedido, como la manda la app (actualizar_pedido_items).
CREATE OR REPLACE FUNCTION pg_temp.t_editar_ped(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm);
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar el pedido: %', v_res;
  END IF;
END
$fn$;

-- Partir un regalo (dividir_regalo_pedido).
CREATE OR REPLACE FUNCTION pg_temp.t_dividir_regalo(p_item bigint, p_partes jsonb)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.dividir_regalo_pedido(p_item, p_partes, 'ensayo 1164', NULL);
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo dividir el regalo: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_x(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

-- L1 (100, 50 vivas), bolsa 0 al crear, pedido de 20 que sale entero de L1
-- (huella 20), y despues 40 a la bolsa. Foto {stock 70, lotes [30], bolsa 40}.
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

-- X con L1 (100, 50 vivas), bolsa 0; pedido de p_cant de X; promo 10 + 2
-- sobre X con regalo de X, linea de regalo de p_regalo (con la migracion, el
-- trigger le toma la foto 10+2). Despues 40 a la bolsa.
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
  RETURN jsonb_build_object('prod', v_prod, 'pedido', p->'pedido', 'item', p->'item', 'promo', v_promo,
                            'regalo', v_r);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- D1 · #1161, el A3 de 1140-1142 con una sola linea. S1 rechaza 5 (20 -> 15)
--      y S2 rechaza 15 (la linea se borra). Anular S1 inserta 5; anular S2 le
--      suma sus 15 a esa linea (misma clave): una linea de 20, total 2000,
--      foto f0, huella 20, LOTE-D 0. Antes quedaban dos lineas.
CREATE OR REPLACE FUNCTION pg_temp.caso_d1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s1 bigint; v_s2 bigint;
  f text[] := '{}'; v_f0 jsonb; v_f jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_s1 := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  v_s2 := pg_temp.t_salvedad(v_ped, v_item, 15, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) IS NULL, 'la salvedad sobre lo que quedaba no borro la linea');
  PERFORM pg_temp.t_anular(v_s1);
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, v_prod) = 1 AND pg_temp.t_cant_ped(v_ped, v_prod) = 5,
                    format('anular S1 dejo %s lineas con %s u., esperado 1 con 5',
                           pg_temp.t_lineas(v_ped, v_prod), pg_temp.t_cant_ped(v_ped, v_prod)));
  PERFORM pg_temp.t_anular(v_s2);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, v_prod) = 1 AND pg_temp.t_cant_ped(v_ped, v_prod) = 20,
                    format('anular S2 dejo %s lineas con %s u., esperado 1 linea de 20 (#1161)',
                           pg_temp.t_lineas(v_ped, v_prod), pg_temp.t_cant_ped(v_ped, v_prod)));
  f := pg_temp.t_si(f, pg_temp.t_total(v_ped) = 2000 AND v_f = v_f0 AND pg_temp.t_huella_ped(v_ped, v_prod) = 20,
                    format('total %s, foto %s (antes %s), huella %s; esperado 2000, f0, 20',
                           pg_temp.t_total(v_ped), v_f, v_f0, pg_temp.t_huella_ped(v_ped, v_prod)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- D2 · #1161. S rechaza 15 de 20 (la linea queda en 5). Una edicion SIN
--      cambios borra y reinserta las lineas (pedido_item_id de la salvedad
--      queda NULL) y no deja historial. Anular reasocia a la linea
--      reinsertada: una linea de 20, total 2000, foto f0, huella 20.
CREATE OR REPLACE FUNCTION pg_temp.caso_d2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint;
  f text[] := '{}'; v_f0 jsonb; v_f jsonb; v_hist int;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_f0 := pg_temp.t_foto(v_prod);
  v_s := pg_temp.t_salvedad(v_ped, v_item, 15, 'cliente_rechaza');
  PERFORM pg_temp.t_editar_ped(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 5)));
  SELECT count(*) INTO v_hist FROM public.pedido_historial WHERE pedido_id = v_ped AND campo_modificado = 'items';
  f := pg_temp.t_si(f, v_hist = 0 AND pg_temp.t_cant(v_item) IS NULL AND pg_temp.t_cant_ped(v_ped, v_prod) = 5
                       AND (SELECT pedido_item_id FROM public.salvedades_items WHERE id = v_s) IS NULL,
                    format('la edicion sin cambios: historial %s, linea vieja %s, %s u.; esperado 0, borrada, 5',
                           v_hist, pg_temp.t_cant(v_item), pg_temp.t_cant_ped(v_ped, v_prod)));
  PERFORM pg_temp.t_anular(v_s);
  v_f := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, v_prod) = 1 AND pg_temp.t_cant_ped(v_ped, v_prod) = 20,
                    format('anular dejo %s lineas con %s u., esperado 1 linea de 20 (#1161)',
                           pg_temp.t_lineas(v_ped, v_prod), pg_temp.t_cant_ped(v_ped, v_prod)));
  f := pg_temp.t_si(f, pg_temp.t_total(v_ped) = 2000 AND v_f = v_f0 AND pg_temp.t_huella_ped(v_ped, v_prod) = 20,
                    format('total %s, foto %s (antes %s), huella %s; esperado 2000, f0, 20',
                           pg_temp.t_total(v_ped), v_f, v_f0, pg_temp.t_huella_ped(v_ped, v_prod)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- D3 · #1161. S rechaza 5 (20 -> 15). Despues (se retrasa la salvedad un
--      minuto: en la transaccion now() es el mismo) una edicion con cambios
--      lleva la linea a 16. Anular rechaza con 'pedido_editado' y no mueve
--      cantidades, total ni stock. Antes sumaba 5 de mas.
CREATE OR REPLACE FUNCTION pg_temp.caso_d3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint;
  f text[] := '{}'; v_f jsonb; v_res jsonb; v_total numeric;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_s := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  UPDATE public.salvedades_items SET created_at = created_at - interval '1 minute' WHERE id = v_s;
  PERFORM pg_temp.t_editar_ped(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 16)));
  v_f := pg_temp.t_foto(v_prod); v_total := pg_temp.t_total(v_ped);
  f := pg_temp.t_si(f, pg_temp.t_cant_ped(v_ped, v_prod) = 16 AND v_total = 1600,
                    format('la edicion dejo %s u. y total %s, esperado 16 y 1600',
                           pg_temp.t_cant_ped(v_ped, v_prod), v_total));
  v_res := public.anular_salvedad(v_s, 'ensayo 1161');
  f := pg_temp.t_si(f, pg_temp.t_rechaza(v_res, 'pedido_editado'),
                    format('anular tendria que rechazar con pedido_editado: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_cant_ped(v_ped, v_prod) = 16 AND pg_temp.t_lineas(v_ped, v_prod) = 1
                       AND pg_temp.t_total(v_ped) = v_total AND pg_temp.t_foto(v_prod) = v_f
                       AND (SELECT estado_resolucion FROM public.salvedades_items WHERE id = v_s) = 'pendiente',
                    format('el rechazo movio algo: %s u. en %s lineas, total %s, foto %s (antes %s)',
                           pg_temp.t_cant_ped(v_ped, v_prod), pg_temp.t_lineas(v_ped, v_prod),
                           pg_temp.t_total(v_ped), pg_temp.t_foto(v_prod), v_f));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- D3b · #1161. La edicion con cambios (20 -> 21) es ANTERIOR a la salvedad
--       (se retrasa su fila de pedido_historial). S rechaza 5 (21 -> 16) y
--       anular pasa: la linea vuelve a 21.
CREATE OR REPLACE FUNCTION pg_temp.caso_d3b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint; f text[] := '{}';
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido';
  PERFORM pg_temp.t_editar_ped(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 21)));
  UPDATE public.pedido_historial SET created_at = created_at - interval '1 minute' WHERE pedido_id = v_ped;
  v_item := pg_temp.t_linea(v_ped, v_prod);
  v_s := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  PERFORM pg_temp.t_anular(v_s);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 21 AND pg_temp.t_lineas(v_ped, v_prod) = 1
                       AND pg_temp.t_total(v_ped) = 2100,
                    format('anular dejo la linea en %s (%s lineas), total %s; esperado 21, 1, 2100',
                           pg_temp.t_cant(v_item), pg_temp.t_lineas(v_ped, v_prod), pg_temp.t_total(v_ped)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- D4 · #1161. Pedido X 10 + Y 10, promo 10+1 sobre Y con regalo de X (linea de
--      regalo X 1, precio 0). S rechaza los 10 de X (la linea se borra).
--      Anular inserta una linea de venta de X aparte: no se fusiona con el
--      regalo, que sigue en 1 a precio 0.
CREATE OR REPLACE FUNCTION pg_temp.caso_d4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_x bigint; v_y bigint; p jsonb; v_ped bigint; v_ix bigint; v_promo bigint; v_r bigint; v_s bigint;
  f text[] := '{}';
BEGIN
  v_x := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  v_y := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  p := pg_temp.t_pedido_n(p_cli, p_adm, jsonb_build_array(jsonb_build_object('prod', v_x, 'cant', 10),
                                                          jsonb_build_object('prod', v_y, 'cant', 10)));
  v_ped := p->>'pedido'; v_ix := p->'items'->>(v_x::text);
  v_promo := pg_temp.t_promo(p_suc, ARRAY[v_y], 10, 1, v_x);
  v_r := pg_temp.t_regalo_linea(v_ped, v_promo, v_x, p_suc, 1);
  PERFORM pg_temp.t_a_la_bolsa(v_x, 40);
  PERFORM pg_temp.t_a_la_bolsa(v_y, 40);
  v_s := pg_temp.t_salvedad(v_ped, v_ix, 10, 'cliente_rechaza');
  PERFORM pg_temp.t_anular(v_s);
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, v_x) = 1 AND pg_temp.t_cant_ped(v_ped, v_x) = 10
                       AND (SELECT precio_unitario FROM public.pedido_items
                             WHERE id = pg_temp.t_linea(v_ped, v_x)) = 100,
                    format('venta de X: %s lineas con %s u., esperado 1 linea de 10 a 100',
                           pg_temp.t_lineas(v_ped, v_x), pg_temp.t_cant_ped(v_ped, v_x)));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_r) = 1 AND pg_temp.t_regalos(v_ped, v_promo) = 1
                       AND (SELECT precio_unitario FROM public.pedido_items WHERE id = v_r) = 0,
                    format('el regalo quedo en %s (promo %s), esperado 1 a precio 0',
                           pg_temp.t_cant(v_r), pg_temp.t_regalos(v_ped, v_promo)));
  f := pg_temp.t_si(f, pg_temp.t_total(v_ped) = 2000, format('total %s, esperado 2000', pg_temp.t_total(v_ped)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- D5 · #1161. S rechaza los 20 de X (la linea se borra). Despues el pedido
--      tiene otra linea de X a 150. Anular no le suma ahi: inserta una linea
--      de 20 a 100 (el precio de la salvedad). Total 750 + 2000.
CREATE OR REPLACE FUNCTION pg_temp.caso_d5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint; v_otra bigint; f text[] := '{}';
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_s := pg_temp.t_salvedad(v_ped, v_item, 20, 'cliente_rechaza');
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
  VALUES (v_ped, v_prod, 5, 150, 750, p_suc) RETURNING id INTO v_otra;
  PERFORM pg_temp.t_anular(v_s);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_otra) = 5 AND pg_temp.t_lineas(v_ped, v_prod) = 2
                       AND EXISTS (SELECT 1 FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod
                                      AND id <> v_otra AND cantidad = 20 AND precio_unitario = 100),
                    format('la linea a 150 quedo en %s y hay %s lineas, esperado 5 y 2 (una de 20 a 100)',
                           pg_temp.t_cant(v_otra), pg_temp.t_lineas(v_ped, v_prod)));
  f := pg_temp.t_si(f, pg_temp.t_total(v_ped) = 2750, format('total %s, esperado 2750', pg_temp.t_total(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- D6 · #1161. Salvedad vieja sobre un regalo: la linea de regalo X 2 (precio
--      0, promo sobre Y) rechazada entera, y la fila con es_bonificacion y
--      promocion_id en NULL, como las anteriores a 2026-09-09 (la 264). Anular
--      rechaza con anulacion_toca_promociones sin mover nada; antes intentaba
--      reinsertarla como venta a precio 0 y tiraba check_violation.
CREATE OR REPLACE FUNCTION pg_temp.caso_d6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_x bigint; v_y bigint; p jsonb; v_ped bigint; v_promo bigint; v_r bigint; v_s bigint;
  f text[] := '{}'; v_res jsonb; v_f jsonb;
BEGIN
  v_x := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  v_y := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 0)->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_x, 20);
  v_ped := p->>'pedido';
  v_promo := pg_temp.t_promo(p_suc, ARRAY[v_y], 10, 1, v_x);
  v_r := pg_temp.t_regalo_linea(v_ped, v_promo, v_x, p_suc, 2);
  PERFORM pg_temp.t_a_la_bolsa(v_x, 40);
  v_s := pg_temp.t_salvedad(v_ped, v_r, 2, 'cliente_rechaza');
  UPDATE public.salvedades_items SET es_bonificacion = NULL, promocion_id = NULL WHERE id = v_s;
  v_f := pg_temp.t_foto(v_x);
  v_res := public.anular_salvedad(v_s, 'ensayo 1161');
  f := pg_temp.t_si(f, pg_temp.t_rechaza(v_res, 'anulacion_toca_promociones'),
                    format('anular tendria que rechazar con anulacion_toca_promociones: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_r) IS NULL AND pg_temp.t_regalos(v_ped, v_promo) = 0
                       AND pg_temp.t_cant_ped(v_ped, v_x) = 20 AND pg_temp.t_lineas(v_ped, v_x) = 1
                       AND pg_temp.t_foto(v_x) = v_f AND pg_temp.t_total(v_ped) = 2000,
                    format('el rechazo movio algo: regalo %s, X %s u. en %s lineas, foto %s (antes %s), total %s',
                           pg_temp.t_regalos(v_ped, v_promo), pg_temp.t_cant_ped(v_ped, v_x),
                           pg_temp.t_lineas(v_ped, v_x), pg_temp.t_foto(v_x), v_f, pg_temp.t_total(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- P1 · #1162. S rechaza 10 de 20. Despues se crea una promo 10+2 sobre X: el
--      pedido nunca tuvo regalo de ella. Anular pasa y la linea vuelve a 20
--      (antes v_toca_promo la rechazaba: 10 + 10 cruza un bloque).
CREATE OR REPLACE FUNCTION pg_temp.caso_p1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint; f text[] := '{}'; v_res jsonb;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_s := pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  PERFORM pg_temp.t_promo(p_suc, ARRAY[v_prod], 10, 2, v_prod);
  v_res := public.anular_salvedad(v_s, 'ensayo 1161');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false) AND pg_temp.t_cant(v_item) = 20,
                    format('anular dio %s y dejo la linea en %s, esperado success y 20', v_res, pg_temp.t_cant(v_item)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- P2 · #1162. Promo 10+2, linea 20, regalo 4. S rechaza los 20: el regalo se
--      recorta a 0 (se borra). Anular sigue rechazando con
--      anulacion_toca_promociones: la foto recuerda la promo.
CREATE OR REPLACE FUNCTION pg_temp.caso_p2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_s bigint;
  f text[] := '{}'; v_res jsonb; v_f jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo';
  v_s := pg_temp.t_salvedad(v_ped, v_item, 20, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 0 AND pg_temp.t_cant_ped(v_ped, v_prod) = 0,
                    format('tras el rechazo: regalo %s, X %s; esperado 0 y 0',
                           pg_temp.t_regalos(v_ped, v_promo), pg_temp.t_cant_ped(v_ped, v_prod)));
  v_f := pg_temp.t_foto(v_prod);
  v_res := public.anular_salvedad(v_s, 'ensayo 1161');
  f := pg_temp.t_si(f, pg_temp.t_rechaza(v_res, 'anulacion_toca_promociones'),
                    format('anular tendria que rechazar con anulacion_toca_promociones: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_cant_ped(v_ped, v_prod) = 0 AND pg_temp.t_regalos(v_ped, v_promo) = 0
                       AND pg_temp.t_foto(v_prod) = v_f,
                    format('el rechazo movio algo: X %s, regalo %s, foto %s (antes %s)',
                           pg_temp.t_cant_ped(v_ped, v_prod), pg_temp.t_regalos(v_ped, v_promo),
                           pg_temp.t_foto(v_prod), v_f));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- N1 · #1163. S rechaza 5 de 20 (15). El pedido se entrega y se le emite una
--      NC de 1 u. Anular rechaza con 'nota_credito_vigente' y el mensaje de la
--      276, sin mover nada. Anulada la NC, anular pasa y la linea vuelve a 20.
CREATE OR REPLACE FUNCTION pg_temp.caso_n1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint; v_nc bigint;
  f text[] := '{}'; v_res jsonb; v_f jsonb; v_cli bigint;
BEGIN
  b := pg_temp.t_base_l1(p_cli, p_adm, p_suc);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item';
  v_s := pg_temp.t_salvedad(v_ped, v_item, 5, 'cliente_rechaza');
  UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = now(), updated_at = now() WHERE id = v_ped;
  SELECT cliente_id INTO v_cli FROM public.pedidos WHERE id = v_ped;
  PERFORM public.crear_nota_credito_venta_impl(v_ped, v_cli,
    jsonb_build_array(jsonb_build_object('pedido_item_id', v_item, 'cantidad', 1)), 'otro', 'ensayo 1163');
  SELECT max(id) INTO v_nc FROM public.notas_credito_venta WHERE pedido_id = v_ped AND NOT anulada;
  f := pg_temp.t_si(f, v_nc IS NOT NULL, 'no se creo la nota de credito');
  v_f := pg_temp.t_foto(v_prod);
  v_res := public.anular_salvedad(v_s, 'ensayo 1163');
  f := pg_temp.t_si(f, pg_temp.t_rechaza(v_res, 'nota_credito_vigente')
                       AND v_res->>'error' = 'El pedido tiene la nota de crédito #' || v_nc || ' vigente: anulala primero',
                    format('anular tendria que rechazar con nota_credito_vigente (NC %s): %s', v_nc, v_res));
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 15 AND pg_temp.t_total(v_ped) = 1500 AND pg_temp.t_foto(v_prod) = v_f
                       AND (SELECT estado_resolucion FROM public.salvedades_items WHERE id = v_s) = 'pendiente',
                    format('el rechazo movio algo: linea %s, total %s, foto %s (antes %s)',
                           pg_temp.t_cant(v_item), pg_temp.t_total(v_ped), pg_temp.t_foto(v_prod), v_f));
  v_res := public.anular_nota_credito_venta(v_nc, 'ensayo 1163');
  f := pg_temp.t_si(f, (SELECT anulada FROM public.notas_credito_venta WHERE id = v_nc),
                    format('no se pudo anular la NC: %s', v_res));
  PERFORM pg_temp.t_reset();
  PERFORM pg_temp.t_anular(v_s);
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 20 AND pg_temp.t_total(v_ped) = 2000,
                    format('anulada la NC, anular dejo la linea en %s y total %s; esperado 20 y 2000',
                           pg_temp.t_cant(v_item), pg_temp.t_total(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- F1 · #1164, el R5 de 1140-1142 con la foto. Promo 10+2, linea 20, regalo 4;
--      la promo se edita a 10+1 despues de la venta. Un rechazo de 10 deja el
--      regalo en 2 (las reglas de la venta) y las dos simulaciones lo
--      predicen. Con las reglas vigentes daba 3.
CREATE OR REPLACE FUNCTION pg_temp.caso_f1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; v_item bigint; v_promo bigint; v_r bigint; f text[] := '{}'; v_sim jsonb; v_lote jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo'; v_r := b->>'regalo';
  PERFORM pg_temp.t_editar_bonif(v_promo, 1);
  v_sim := pg_temp.t_simular(v_ped, v_item, 10);
  f := pg_temp.t_si(f, v_sim = jsonb_build_array(jsonb_build_array(v_promo, 2, 2)),
                    format('simular_salvedad_promo_impacto %s, esperado [[promo, 2, 2]]', v_sim));
  v_lote := pg_temp.t_simular_lote(v_ped, jsonb_build_array(jsonb_build_object('pedido_item_id', v_item,
                                                                                 'cantidad_afectada', 10)));
  f := pg_temp.t_si(f, v_lote = jsonb_build_array(jsonb_build_array(v_r, 2)),
                    format('simular_salvedades_promo_impacto %s, esperado [[regalo, 2]]', v_lote));
  PERFORM pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 2,
                    format('el regalo quedo en %s, esperado 2 (las reglas de la venta)', pg_temp.t_regalos(v_ped, v_promo)));
  f := pg_temp.t_si(f, pg_temp.t_lote_d(v_ped) = 0, format('LOTE-D del pedido: %s', pg_temp.t_lote_d(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- F2 · #1164, el R5b de 1140-1142 con la foto. A X lo sacan de la promo
--      despues de la venta. La simulacion predice el recorte entero, el
--      rechazo de los 20 deja el regalo en 0, y anular rechaza con
--      anulacion_toca_promociones sin mover nada.
CREATE OR REPLACE FUNCTION pg_temp.caso_f2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_s bigint;
  f text[] := '{}'; v_sim jsonb; v_res jsonb; v_f jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo';
  DELETE FROM public.promocion_productos WHERE promocion_id = v_promo AND producto_id = v_prod;
  v_sim := pg_temp.t_simular(v_ped, v_item, 20);
  f := pg_temp.t_si(f, v_sim = jsonb_build_array(jsonb_build_array(v_promo, 0, 4)),
                    format('la simulacion dio %s, esperado [[promo, 0, 4]]', v_sim));
  v_s := pg_temp.t_salvedad(v_ped, v_item, 20, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 0,
                    format('el regalo quedo en %s, esperado 0 (los productos de la venta)', pg_temp.t_regalos(v_ped, v_promo)));
  v_f := pg_temp.t_foto(v_prod);
  v_res := public.anular_salvedad(v_s, 'ensayo 1164');
  f := pg_temp.t_si(f, pg_temp.t_rechaza(v_res, 'anulacion_toca_promociones'),
                    format('anular tendria que rechazar con anulacion_toca_promociones: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_cant_ped(v_ped, v_prod) = 0 AND pg_temp.t_regalos(v_ped, v_promo) = 0
                       AND pg_temp.t_foto(v_prod) = v_f,
                    format('el rechazo movio algo: X %s, regalo %s, foto %s (antes %s)',
                           pg_temp.t_cant_ped(v_ped, v_prod), pg_temp.t_regalos(v_ped, v_promo),
                           pg_temp.t_foto(v_prod), v_f));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- F3 · #1164. Pedido con regalo 10+2 (foto del trigger: 10+2). La regla pasa
--      a 10+1 y la edicion por el camino real (actualizar_pedido_items) con el
--      payload que armaria la UI: regalo recalculado a 2 (p_regalo). La foto
--      queda en 10+1, origen 'trigger'. F3b: lo mismo reenviando el regalo
--      viejo (4), como una llamada directa: la foto queda en 10+1 igual. Es lo
--      elegido, no un bug: el caso existe para que un cambio lo haga visible.
CREATE OR REPLACE FUNCTION pg_temp.t_caso_f3(p_cli bigint, p_adm uuid, p_suc bigint, p_regalo int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_ped bigint; v_promo bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_promo := b->>'promo';
  v_foto := pg_temp.t_foto_promo(v_ped, v_promo);
  f := pg_temp.t_si(f, v_foto->>'bonif' = '2' AND v_foto->>'compra' = '10' AND v_foto->>'origen' = 'trigger'
                       AND v_foto->'productos' = jsonb_build_array(v_prod),
                    format('la foto del alta es %s, esperado 10+2 [X] de trigger', v_foto));
  PERFORM pg_temp.t_editar_bonif(v_promo, 1);
  PERFORM pg_temp.t_editar_ped(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20),
                                                               pg_temp.t_r(v_prod, p_regalo, v_promo)));
  v_foto := pg_temp.t_foto_promo(v_ped, v_promo);
  f := pg_temp.t_si(f, v_foto->>'bonif' = '1' AND v_foto->>'origen' = 'trigger'
                       AND pg_temp.t_regalos(v_ped, v_promo) = p_regalo,
                    format('tras la edicion la foto es %s y el regalo %s; esperado 10+1 de trigger y %s',
                           v_foto, pg_temp.t_regalos(v_ped, v_promo), p_regalo));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_f3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_f3(p_cli, p_adm, p_suc, 2);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_f3b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_caso_f3(p_cli, p_adm, p_suc, 4);
$fn$;

-- F4 · #1164. Regalo vivo con foto 10+2; la regla pasa a 10+1 y se divide el
--      regalo (X 2 + Y 2) con dividir_regalo_pedido: la foto sigue en 10+2
--      (la linea original sigue viva cuando entran las partes).
CREATE OR REPLACE FUNCTION pg_temp.caso_f4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_prod bigint; v_y bigint; v_ped bigint; v_promo bigint; v_r bigint; f text[] := '{}'; v_foto jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_prod := b->>'prod'; v_ped := b->>'pedido'; v_promo := b->>'promo'; v_r := b->>'regalo';
  v_y := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 10)->>'prod';
  PERFORM pg_temp.t_editar_bonif(v_promo, 1);
  PERFORM pg_temp.t_dividir_regalo(v_r, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2),
                                                          jsonb_build_object('producto_id', v_y, 'cantidad', 2)));
  v_foto := pg_temp.t_foto_promo(v_ped, v_promo);
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pedido_items
                         WHERE pedido_id = v_ped AND promocion_id = v_promo AND es_bonificacion) = 2
                       AND pg_temp.t_regalos(v_ped, v_promo) = 4,
                    format('la division dejo %s u. de regalo, esperado 4 en dos lineas', pg_temp.t_regalos(v_ped, v_promo)));
  f := pg_temp.t_si(f, v_foto->>'bonif' = '2',
                    format('tras dividir la foto es %s, esperado 10+2 (la division no la rehace)', v_foto));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- F5 · #1164. Sin foto, promos_del_pedido usa lo vigente: se borra la foto del
--      pedido y el R5 viejo vuelve a dar 3 (simulacion y salvedad).
CREATE OR REPLACE FUNCTION pg_temp.caso_f5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; v_item bigint; v_promo bigint; f text[] := '{}'; v_sim jsonb;
BEGIN
  b := pg_temp.t_base_promo(p_cli, p_adm, p_suc, 20, 4);
  v_ped := b->>'pedido'; v_item := b->>'item'; v_promo := b->>'promo';
  PERFORM pg_temp.t_editar_bonif(v_promo, 1);
  DELETE FROM public.pedido_promo_reglas WHERE pedido_id = v_ped;
  v_sim := pg_temp.t_simular(v_ped, v_item, 10);
  f := pg_temp.t_si(f, v_sim = jsonb_build_array(jsonb_build_array(v_promo, 3, 1)),
                    format('sin foto la simulacion dio %s, esperado [[promo, 3, 1]] (lo vigente)', v_sim));
  PERFORM pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 3,
                    format('sin foto el regalo quedo en %s, esperado 3 (lo vigente)', pg_temp.t_regalos(v_ped, v_promo)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- F6 · #1164. El backfill: ninguna linea de regalo viva (con promo) sin foto.
CREATE OR REPLACE FUNCTION pg_temp.caso_f6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_n int; f text[] := '{}';
BEGIN
  SELECT count(*) INTO v_n
    FROM public.pedido_items pi
    JOIN public.pedidos p ON p.id = pi.pedido_id
   WHERE COALESCE(pi.es_bonificacion, false) AND pi.promocion_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.pedido_promo_reglas r
                      WHERE r.pedido_id = pi.pedido_id AND r.promocion_id = pi.promocion_id);
  f := pg_temp.t_si(f, v_n = 0, format('%s lineas de regalo vivas sin foto', v_n));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

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
  FOREACH v_caso IN ARRAY ARRAY['d1', 'd2', 'd3', 'd3b', 'd4', 'd5', 'd6', 'p1', 'p2', 'n1',
                                'f1', 'f2', 'f3', 'f3b', 'f4', 'f5', 'f6'] LOOP
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
