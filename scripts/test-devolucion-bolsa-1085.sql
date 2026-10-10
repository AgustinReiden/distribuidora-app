-- Ensayo de #1085: lo que salio de la bolsa vuelve a la bolsa.
--
-- Una linea que salio en parte de la bolsa (unidades sin vencimiento) y en
-- parte de un lote, al devolverse: la mig 338 hizo que la parte del lote
-- vuelva a su lote (la primera pasada de _restaurar_lotes_fefo, por la
-- huella). Lo que salio de la bolsa seguia entrando por FEFO a cualquier lote
-- con hueco: ese lote quedaba +N con unidades de otra fecha y la bolsa -N.
-- Decision del dueño (2026-10-10): si la linea (o el pedido) tiene huella, lo
-- que excede la huella vuelve a la bolsa; sin ninguna huella (bot, pedidos
-- anteriores a la 256, devoluciones que no son de un pedido) no hay forma de
-- saber de donde salio y sigue por FEFO.
--
--   B1 · salvedad sobre una linea 5 bolsa + 15 lote: las 15 al lote, las 3
--        que exceden la huella a la bolsa. Anular deja todo como estaba.
--   B2 · el lote de origen ya no tiene hueco: las unidades van a la bolsa y
--        la huella del cliente baja igual; anular se la repone entera.
--   B3 · cancelar el pedido entero (antes, el caso S4b de la 338 las mandaba
--        a otro lote).
--   B4 · cancelar un pedido con la linea y su regalo del mismo producto:
--        cada linea devuelve con su propia huella.
--   B5 · lo mismo, eliminando el pedido.
--   U1 · sin huella (la linea salio entera de la bolsa): FEFO, como siempre.
--   U2 · una devolucion que no es de un pedido: FEFO, como siempre.
--
-- Corre contra prod SIN dejar rastro: todo termina en un RAISE EXCEPTION.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'.
--
--   psql "$DATABASE_URL" -f scripts/test-devolucion-bolsa-1085.sql

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Un lote como {dias, cant, rest}; NULL si ya no existe.
CREATE OR REPLACE FUNCTION pg_temp.t_lote(p_id bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('dias', l.fecha_vencimiento - pg_temp.t_hoy(),
                            'cant', l.cantidad, 'rest', l.cantidad_restante)
    FROM public.producto_lotes l WHERE l.id = p_id;
$fn$;

-- El lote quedo solo para la traza (mig 338). Sin la columna, false.
CREATE OR REPLACE FUNCTION pg_temp.t_solo(p_id bigint)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
  v boolean;
BEGIN
  EXECUTE 'SELECT solo_traza FROM public.producto_lotes WHERE id = $1' INTO v USING p_id;
  RETURN COALESCE(v, false);
EXCEPTION WHEN undefined_column THEN
  RETURN false;
END
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
   WHERE pedido_item_id = p_item AND lote_id = p_lote;
$fn$;

-- pedido_item_lotes de las lineas de un producto: [{item, lote, cant}].
CREATE OR REPLACE FUNCTION pg_temp.t_huella_tabla(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('item', pil.pedido_item_id, 'lote', pil.lote_id,
                                               'cant', pil.cantidad)
                            ORDER BY pil.pedido_item_id, pil.lote_id), '[]'::jsonb)
    FROM public.pedido_item_lotes pil
    JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
   WHERE pi.producto_id = p_prod;
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
  VALUES ('ZZ ensayo 1085', 100,
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
    'ensayo 1085');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = p_prod));
END
$fn$;

-- La edicion de la compra, como la manda la app: la foto completa de los
-- vencimientos de la factura ([{dias, cantidad}] de un solo producto).
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

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo 1085: descripcion del caso', NULL, true, NULL);
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
  v_res := public.anular_salvedad(p_salv, 'ensayo 1085');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular: %', v_res;
  END IF;
END
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote). Sirve para que la bolsa no quede en 0 despues de un pedido que
-- llego a los lotes: con bolsa 0 la bajada cae en el lote por FEFO y da bien
-- por casualidad.
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1054', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- B1 · salvedad. L2 vence a 30 dias y esta vacio (50, 0 vivas); L1 vence a
--      90 (100, 50 vivas). Bolsa 5. Pedido 20: 5 de la bolsa y 15 de L1
--      (huella 15). Se suman 20 a la bolsa. Salvedad de 18: 15 vuelven a L1 y
--      las 3 que salieron de la bolsa vuelven a la bolsa, no a L2. Anular deja
--      todo como despues del pedido.
CREATE OR REPLACE FUNCTION pg_temp.caso_b1(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 15 OR v_f0 <> '{"stock":55,"lotes":[0,35],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 18, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":73,"lotes":[0,50],"bolsa":23}',
                    format('la devolucion dejo %s, esperado {stock 73, lotes [0,50], bolsa 23}: las 3 de la bolsa vuelven a la bolsa', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 0,
                    format('la huella en L1 quedo %s, esperado 0', pg_temp.t_huella(v_item, v_l1)));

  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s; despues del pedido era %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('despues de anular la huella en L1 quedo %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

-- B2 · el lote de donde salio la linea ya no tiene hueco. Como B1 hasta el
--      pedido (huella 15 en L1); despues L1 se vuelve a llenar (100/100) con
--      unidades de la bolsa. Salvedad de 10: no entran en L1, van a la bolsa
--      (no a L2), y la huella del cliente en L1 baja igual a 5.
CREATE OR REPLACE FUNCTION pg_temp.caso_b2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_salv bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_f2 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 65);
  UPDATE public.producto_lotes SET cantidad_restante = cantidad WHERE id = v_l1;
  v_f0 := pg_temp.t_foto(v_prod);
  IF pg_temp.t_huella(v_item, v_l1) <> 15 OR v_f0 <> '{"stock":100,"lotes":[0,100],"bolsa":0}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;

  v_salv := pg_temp.t_salvedad(v_ped, v_item, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":110,"lotes":[0,100],"bolsa":10}',
                    format('la devolucion dejo %s, esperado {stock 110, lotes [0,100], bolsa 10}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 5,
                    format('la huella en L1 quedo %s, esperado 5 (el cliente devolvio 10)', pg_temp.t_huella(v_item, v_l1)));

  -- Anular: lo que no entro en L1 no paso por su contador, asi que su huella
  -- vuelve entera (el tope "no mas que lo que el lote consumio" es para lo que
  -- volvio al lote).
  PERFORM pg_temp.t_anular(v_salv);
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = v_f0, format('anular dejo %s; antes de la salvedad era %s', v_f2, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 15,
                    format('despues de anular la huella en L1 quedo %s, esperado 15', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

-- B3 · cancelar el pedido entero (el caso S4b de la 338): las 15 de L1
--      vuelven a L1 y las 5 que salieron de la bolsa, a la bolsa.
CREATE OR REPLACE FUNCTION pg_temp.caso_b3(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l2 bigint; v_l1 bigint; p jsonb; v_ped bigint; v_item bigint; v_res jsonb;
  f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l2 := v->'lotes'->>0; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido'; v_item := p->>'item';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);

  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1085', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar dejo %s, esperado {stock 75, lotes [0,50], bolsa 25}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, v_l1) = 0,
                    format('el pedido cancelado sigue con huella %s en L1', pg_temp.t_huella(v_item, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- Arma el pedido de B4/B5: L0 vence a 30 dias y esta vacio (50, 0 vivas), L1
-- vence a 90 (100, 50 vivas), bolsa 5. Linea X de 20 (5 de la bolsa, 15 de L1:
-- huella 15) y regalo R de 4 del MISMO producto con una promo que mueve stock
-- (de L1: huella 4). Despues se suman 20 a la bolsa. Devuelve
-- {prod, pedido, l0, l1, x, r}.
CREATE OR REPLACE FUNCTION pg_temp.t_pedido_con_regalo(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_ped bigint; v_promo bigint; v_regalo bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';

  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1085', 'bonificacion', CURRENT_DATE, p_suc, true, v_prod) RETURNING id INTO v_promo;
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (v_ped, v_prod, 4, 0, 0, p_suc, true, v_promo) RETURNING id INTO v_regalo;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_regalo::text, true);
  UPDATE public.productos SET stock = stock - 4 WHERE id = v_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);

  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  RETURN jsonb_build_object('prod', v_prod, 'pedido', v_ped, 'l0', v->'lotes'->0, 'l1', v->'lotes'->1,
                            'x', p->'item', 'r', v_regalo);
END
$fn$;

-- B4 · cancelar un pedido con dos lineas del mismo producto (la linea y su
--      regalo). Cada linea devuelve con su propia huella: X pone 15 en L1 y 5
--      en la bolsa, R pone 4 en L1. Antes la primera devolucion (a nivel
--      pedido) se comia la huella de las dos y la segunda caia por FEFO en L0.
CREATE OR REPLACE FUNCTION pg_temp.caso_b4(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_res jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc);
  v_f0 := pg_temp.t_foto((d->>'prod')::bigint);
  IF v_f0 <> '{"stock":51,"lotes":[0,31],"bolsa":20}'
     OR pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) <> 15
     OR pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;

  v_res := public.cancelar_pedido_con_stock((d->>'pedido')::bigint, 'ensayo 1085', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto((d->>'prod')::bigint);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar dejo %s, esperado {stock 75, lotes [0,50], bolsa 25}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 0
                       AND pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 0,
                    'el pedido cancelado sigue con huella');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- B5 · lo mismo, eliminando el pedido con restauracion de stock.
CREATE OR REPLACE FUNCTION pg_temp.caso_b5(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_res jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc);
  v_res := public.eliminar_pedido_completo((d->>'pedido')::bigint, p_adm, 'ensayo 1085', true);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'eliminar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto((d->>'prod')::bigint);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('eliminar dejo %s, esperado {stock 75, lotes [0,50], bolsa 25}', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- U1 · sin huella no hay forma de saber de donde salio: sigue por FEFO. Una
--      linea que salio entera de la bolsa (lote 100 con 50 vivas, bolsa 40,
--      pedido 20): la salvedad de 10 entra al lote, como siempre.
CREATE OR REPLACE FUNCTION pg_temp.caso_u1(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_salvedad((p->>'pedido')::bigint, (p->>'item')::bigint, 10, 'cliente_rechaza');
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":80,"lotes":[60],"bolsa":20}',
                    format('sin huella la devolucion dejo %s, esperado {stock 80, lotes [60], bolsa 20} (FEFO)', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- U2 · una devolucion que no es de un pedido (sin linea ni pedido en los GUCs,
--      con un origen de la lista blanca) sigue por FEFO.
CREATE OR REPLACE FUNCTION pg_temp.caso_u2(p_cli bigint, p_adm uuid, p_suc bigint, p_otra bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; f text[] := '{}'; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  PERFORM set_config('app.stock_origen', 'movimiento_cancelado', true);
  PERFORM set_config('app.stock_ref_tipo', 'movimiento', true);
  PERFORM set_config('app.stock_ref_id', '1', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  UPDATE public.productos SET stock = stock + 10 WHERE id = v_prod;
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":100,"lotes":[60],"bolsa":40}',
                    format('la devolucion sin pedido dejo %s, esperado {stock 100, lotes [60], bolsa 40} (FEFO)', v_f1));
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
  v_otra    bigint;
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
  SELECT id INTO v_otra FROM sucursales WHERE id <> v_suc ORDER BY id LIMIT 1;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL OR v_otra IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal % y otra sucursal', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['b1', 'b2', 'b3', 'b4', 'b5', 'u1', 'u2'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc, v_otra;
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
