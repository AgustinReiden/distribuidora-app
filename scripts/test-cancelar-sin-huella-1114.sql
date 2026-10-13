-- Ensayo de #1114: una linea sin huella vuelve a la bolsa.
--
-- La bajada del trigger come primero la bolsa, y desde la 349 toda bajada con
-- linea deja huella de lo que saca de un lote (el alta desde la 256; la
-- edicion y el bot recien desde la 349). Una linea de ESTE producto sin huella
-- salio entonces de la bolsa, y al devolverse (cancelar, eliminar, salvedad)
-- la pasada 2 de _restaurar_lotes_fefo la mandaba por FEFO a un lote con
-- hueco: lote +N y bolsa -N, el contador de #1050 / #1097. Lo mismo para lo
-- que excede la huella de una linea (eso ya lo hacia la 342) y para el exceso
-- de un regalo en una salvedad.
--
-- Decision del dueño (2026-10-13): arreglo central en _restaurar_lotes_fefo,
-- que invierte el caso U1 de la 342 (fijado el 2026-10-10). FEFO queda solo
-- para la devolucion que no dice su linea: a nivel pedido, o que no es de un
-- pedido.
--
--   C1 · cancelar un pedido cuya linea salio entera de la bolsa: vuelve a la
--        bolsa, no al lote que vence antes.
--   C2 · lo mismo, eliminando el pedido con restauracion de stock.
--   C3 · huella parcial (5 bolsa + 15 lote): las 15 a su lote, las 5 a la
--        bolsa (regresion de la 342).
--   C4 · una linea con huella y un regalo del mismo producto sin huella: al
--        cancelar, la linea vuelve a su lote y el regalo a la bolsa.
--   C5 · salvedad 'cliente_rechaza' sobre una linea sin huella (el U1 de la
--        342, invertido): a la bolsa, lotes_devueltos sin lotes; anular deja
--        todo como despues del pedido.
--   C6 · salvedad por dañado sobre una linea sin huella y sobre una con
--        huella, con bolsa distinta de 0: sin movimiento neto de lotes ni de
--        bolsa (la devolucion 'salvedad_merma' y la merma caen del mismo lado).
--   C7 · el exceso de un regalo sin huella que la salvedad recorta: a la bolsa.
--   U2 · una devolucion que no es de un pedido: FEFO, como siempre.
--   U3 · una devolucion a nivel pedido, sin linea: FEFO, como siempre.
--   U4 · el GUC apunta a una linea de OTRO producto: FEFO (la linea tiene que
--        ser de este producto para decidir).
--   U5 · el GUC de linea, restaurado como lo hacen los callers, no se filtra a
--        la devolucion siguiente sin linea del mismo producto (emulado: ningun
--        camino real devuelve sin linea en el mismo cuerpo).
--
-- La bolsa es distinta de 0 en todos los casos (CLAUDE.md: con bolsa 0 la
-- bajada cae en el lote por FEFO y da bien por casualidad).
--
-- Corre contra prod SIN dejar rastro: todo termina en un RAISE EXCEPTION.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'.
--
--   psql "$DATABASE_URL" -f scripts/test-cancelar-sin-huella-1114.sql

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
  v_rep     text[] := '{}';
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
      IF v_out ? 'reporte' THEN
        v_rep := v_rep || (upper(v_caso) || ' · ' || (v_out->>'reporte'));
      END IF;
    END IF;
  END LOOP;

  RAISE EXCEPTION E'%\n- %\n\nREPORTE\n%',
    CASE WHEN cardinality(v_fallas) = 0 THEN 'ENSAYO OK'
         ELSE format('ENSAYO FALLO (%s fallas)', cardinality(v_fallas)) END,
    array_to_string(v_fallas, E'\n- '),
    array_to_string(v_rep, E'\n');
END
$ensayo$;
