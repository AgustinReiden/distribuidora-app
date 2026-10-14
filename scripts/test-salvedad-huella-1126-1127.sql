-- Ensayo de #1127 y #1126, con los dos hermanos de la misma tanda.
--
-- #1127: la salvedad por dañado, vencido o faltante devuelve y merma en el
-- mismo movimiento ('salvedad_merma', fuera de la lista blanca: el contador
-- del lote no se mueve), pero no bajaba la huella de la linea. La linea
-- quedaba en 10 con huella 20 y lotes_devueltos anotaba huella 0, asi que
-- anular no tenia nada que reponer. Decision del dueño (2026-10-13): la huella
-- baja por FEFO sobre la propia huella de la linea, LEAST(cantidad_afectada,
-- huella).
-- #1126: el exceso del regalo que recorta la resincronizacion NO se anota en
-- lotes_devueltos (decision A); anular_salvedad nunca baja stock por el regalo.
-- Hermano (a): cancelar_pedido_con_stock con 'falta_stock' borra la huella de
-- las lineas del pedido (misma regla, devolucion + merma).
-- Hermano (b): registrar_salvedad rechaza una salvedad sobre un pedido dado de
-- baja (cancelado, anulado o con motivo_cancelacion), sin efectos (#1125).
--
--   H1 · dañado 10 sobre una linea de 20 con huella 20: la foto no se mueve,
--        la huella baja a 10, se anota [[L1, 0, 10]]; anular la repone.
--   H2 · vencido 12 sobre una huella repartida en dos lotes: FEFO sobre la
--        huella (10 del que vence antes, 2 del otro); anular repone las dos.
--   H3 · faltante 10 sobre una huella parcial (5 bolsa + 15 lote): huella 5.
--   H4 · dañado sobre la linea entera: la cascada de #1073 (regresion).
--   H5 · dañado sobre una linea sin huella: nada que bajar, NULL (regresion).
--   H6 · cliente_rechaza: la devolucion que queda devuelta (regresion).
--   H7 · dos mermas sobre la misma linea; anular la primera repone sus 5
--        de huella y le suma 5 a la linea (#1140).
--   R1 · cliente_rechaza con un regalo del mismo producto con huella que la
--        promo recorta: la anotacion no lleva el regalo; anular rechaza.
--   R3 · lo mismo con dañado: sin doble baja de huella; anular rechaza.
--   F1 · hermano (a): cancelar por falta de stock deja la huella en 0.
--   B1 · hermano (b): salvedad sobre un cancelado, rechazada sin efectos; el
--        reintento idempotente de una salvedad previa sigue contestando.
--   B2 · lo mismo sobre un 'anulado' (#1080).
--   B3 · el cancelado que volvia a 'pendiente' (pedido 1856): desde #1131 el
--        UPDATE que lo reactiva se rechaza (42501) y nada cambia. Cambio de
--        sentido deliberado: ese estado ya no se puede construir.
--
-- La bolsa es distinta de 0 en todos los casos (CLAUDE.md: con bolsa 0 la
-- bajada cae en el lote por FEFO y da bien por casualidad).
--
-- Corre contra prod SIN dejar rastro: cada caso se revierte en su subbloque y
-- el script termina con RAISE EXCEPTION 'ENSAYO_ROLLBACK', que revierte toda
-- la transaccion. Veredicto: 'ENSAYO FALLO (...)' con la lista de fallas, o,
-- si todo pasa, el unico error es 'ENSAYO_ROLLBACK' (el NOTICE dice ENSAYO OK
-- y trae el reporte).
--
--   psql "$DATABASE_URL" -1 -f scripts/test-salvedad-huella-1126-1127.sql

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
--      huella 15 (20 menos las 5 de S2, que sigue viva), y la linea en 15:
--      desde #1140 anular suma lo suyo, no vuelve a cantidad_original (20).
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
  -- #1140: antes era un reporte; ahora se afirma.
  f := pg_temp.t_si(f, pg_temp.t_cant(v_item) = 15,
                    format('anular S1 dejo la linea en %s, esperado 15 (10 + las 5 de S1; S2 sigue viva, #1140)',
                           pg_temp.t_cant(v_item)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('cantidad de la linea tras anular S1: %s', pg_temp.t_cant(v_item)));
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

-- B3 · el caso del pedido 1856: cancelado y vuelto a otro estado por UPDATE
--      (sin volver a descontar stock). Desde #1131 la regla 1 de
--      pedidos_guard_baja lo rechaza para todos, postgres incluido: el UPDATE
--      falla con 42501 y nada cambia (foto, linea, estado y motivo). Antes este
--      caso armaba el reactivado y afirmaba que la salvedad lo rechazaba; ese
--      estado ya no se puede construir (cambio de sentido deliberado). La
--      salvedad sobre un cancelado sigue cubierta por B1.
CREATE OR REPLACE FUNCTION pg_temp.caso_b3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; v_item bigint; f text[] := '{}';
  v_err text; v_f0 jsonb; v_f1 jsonb; v_p record;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_cancelar(v_ped, p_adm);
  v_f0 := pg_temp.t_foto(v_prod);
  BEGIN
    UPDATE public.pedidos SET estado = 'pendiente' WHERE id = v_ped;
    v_err := 'paso';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLSTATE;
  END;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_err = '42501',
                    format('sacar de cancelado por UPDATE tenia que rechazarse con 42501 y dio %s', v_err));
  SELECT estado, motivo_cancelacion INTO v_p FROM public.pedidos WHERE id = v_ped;
  f := pg_temp.t_si(f, v_f1 = v_f0 AND pg_temp.t_cant(v_item) = 20
                       AND v_p.estado = 'cancelado' AND v_p.motivo_cancelacion IS NOT NULL,
                    format('el UPDATE rechazado dejo efectos: foto %s (antes %s), linea %s, pedido %s', v_f1, v_f0,
                           pg_temp.t_cant(v_item), to_jsonb(v_p)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('UPDATE %s', v_err));
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

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada: no
  -- deja nada.
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
      IF v_out ? 'reporte' THEN
        v_rep := v_rep || (upper(v_caso) || ' · ' || (v_out->>'reporte'));
      END IF;
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %\n\nREPORTE\n%',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_rep, E'\n');
  END IF;
  RAISE NOTICE E'ENSAYO OK\n\nREPORTE\n%', array_to_string(v_rep, E'\n');
END
$ensayo$;

-- Nada de lo de arriba queda escrito: la transaccion se revierte entera.
DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
