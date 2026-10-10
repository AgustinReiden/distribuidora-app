-- Ensayo de #1094 y #1097: editar un pedido, sustituir o repartir un regalo
-- conserva la huella lote -> linea, y una cantidad invalida se rechaza.
--
-- #1097: actualizar_pedido_items devolvia lo viejo con la huella del PEDIDO
-- (origen de la lista blanca, sin la linea) y volvia a bajar sin la linea: lo
-- que salio de la bolsa volvia por FEFO a un lote, la huella vieja se perdia
-- con el DELETE y la bajada nueva no dejaba ninguna. Despues de editar, el
-- lote quedaba +N, la bolsa -N y el retiro de ese lote no encontraba al
-- cliente. sustituir_regalo_pedido y dividir_regalo_pedido devolvian tambien
-- a nivel pedido: le comian la huella a OTRA linea del mismo producto. Y el
-- bot nunca dejaba huella.
-- #1094: un renglon en 0, negativo o fraccionario pasaba al lado de uno
-- valido (el -1 subia el stock; el 0.4 reventaba con un 22P02 crudo).
--
-- Decision del dueño (2026-10-10, opcion C del plan): la devolucion que se
-- cancela con la bajada que viene despues va SIN etiquetar (a la bolsa), la
-- bajada lleva su linea y al final _rehacer_huella_lineas conserva la huella
-- que la cantidad nueva sigue cubriendo -- primero por linea de origen y el
-- sobrante por producto -- y devuelve el resto a su lote (primero el que vence
-- antes, como una salvedad).
--
-- Base de los casos: L2 vence a 30 dias y esta vacio (50, 0 vivas); L1 vence a
-- 90 (100, 50 vivas). Ninguna bolsa en 0 (CLAUDE.md: con bolsa 0 la bajada
-- cae en el lote por FEFO y da bien por casualidad).
--
--   E1  · editar sin cambios: lotes, bolsa y huella identicos.
--   E2  · subir de 20 a 30.
--   E3  · bajar de 20 a 10: lo mismo que una salvedad de 10.
--   E1b · la linea salio entera de la bolsa: editar no toca los lotes.
--   E1c · X salio de la bolsa y su regalo R (mismo producto) de L1.
--   E4  · X y R del mismo producto, reenviados igual (con E5: #1083).
--   E4b · dos renglones (uno con huella, otro de la bolsa) fusionados en uno.
--   E4c · bajar X sin tocar su regalo R (mismo producto y lote): R conserva
--         su huella y cancelar despues da lo mismo que sin editar.
--   E6  · #1094: -1, 0, 0.4 y un regalo en 0 se rechazan con mensaje.
--   E7  · #1094: CHECK pedido_items_cantidad_positiva.
--   E8  · sustituir R (de P) por Q: X conserva su huella.
--   E8b · sustituir P -> P con mas cantidad.
--   E8c · sustituir con 0.4, 0.5 o 2.5 se rechaza con mensaje.
--   E9  · repartir R en [P 1, Q 3]: X conserva su huella.
--   E10 · cancelar despues de editar devuelve cada unidad a donde estaba.
--   E11 · el bot deja huella.
--   U1  · editar un producto sin lotes, como siempre.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'.
--
--   psql "$DATABASE_URL" -f scripts/test-huella-edicion-1094-1097.sql

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
   WHERE pedido_item_id = p_item AND lote_id = p_lote;
$fn$;

-- Toda la huella de una linea, en cualquier lote.
CREATE OR REPLACE FUNCTION pg_temp.t_huella_linea(p_item bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_item_lotes WHERE pedido_item_id = p_item;
$fn$;

-- La linea (no regalo / regalo) de un producto en un pedido.
CREATE OR REPLACE FUNCTION pg_temp.t_linea(p_ped bigint, p_prod bigint, p_regalo boolean)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false) = p_regalo
   ORDER BY id LIMIT 1;
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
  VALUES ('ZZ ensayo 1097', 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  IF jsonb_array_length(p_lotes) > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
  END IF;

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
    'ensayo 1097');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped, 'item', pg_temp.t_linea(v_ped, p_prod, false));
END
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote).
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1097', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

-- Una linea mas en el pedido, insertada a mano y bajada con su huella (como
-- la baja el alta).
CREATE OR REPLACE FUNCTION pg_temp.t_linea_extra(p_ped bigint, p_prod bigint, p_suc bigint, p_cant int,
                                                  p_promo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_item bigint;
BEGIN
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (p_ped, p_prod, p_cant, CASE WHEN p_promo IS NULL THEN 100 ELSE 0 END,
          CASE WHEN p_promo IS NULL THEN 100 * p_cant ELSE 0 END,
          p_suc, p_promo IS NOT NULL, p_promo)
  RETURNING id INTO v_item;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_item::text, true);
  UPDATE public.productos SET stock = stock - p_cant WHERE id = p_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  RETURN v_item;
END
$fn$;

-- Pedido con la linea X de 20 y el regalo R de 4 del MISMO producto, con una
-- promo que mueve stock. Lotes de la base, bolsa `p_bolsa`; despues del pedido
-- se suman `p_extra` a la bolsa. Devuelve {prod, pedido, promo, l2, l1, x, r}.
CREATE OR REPLACE FUNCTION pg_temp.t_pedido_con_regalo(p_cli bigint, p_adm uuid, p_suc bigint,
                                                        p_bolsa int, p_extra int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_ped bigint; v_promo bigint; v_regalo bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', p_bolsa);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';

  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1097', 'bonificacion', CURRENT_DATE, p_suc, true, v_prod) RETURNING id INTO v_promo;
  v_regalo := pg_temp.t_linea_extra(v_ped, v_prod, p_suc, 4, v_promo);

  PERFORM pg_temp.t_a_la_bolsa(v_prod, p_extra);
  RETURN jsonb_build_object('prod', v_prod, 'pedido', v_ped, 'promo', v_promo,
                            'l2', v->'lotes'->0, 'l1', v->'lotes'->1,
                            'x', p->'item', 'r', v_regalo);
END
$fn$;

-- La edicion, como la manda la app. Devuelve la respuesta de la RPC.
CREATE OR REPLACE FUNCTION pg_temp.t_editar_res(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN public.actualizar_pedido_items(p_ped, p_items, p_adm);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar el pedido: %', v_res;
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

-- La base de E1/E2/E3/E10: bolsa 5, pedido 20 = 5 de la bolsa + 15 de L1
-- (huella 15), despues +20 a la bolsa -> {55, [0,35], 20}.
CREATE OR REPLACE FUNCTION pg_temp.t_base_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  IF pg_temp.t_foto(v_prod) <> '{"stock":55,"lotes":[0,35],"bolsa":20}'
     OR pg_temp.t_huella((p->>'item')::bigint, (v->'lotes'->>1)::bigint) <> 15 THEN
    RAISE EXCEPTION 'punto de partida de E1: % (huella %)', pg_temp.t_foto(v_prod),
      pg_temp.t_huella((p->>'item')::bigint, (v->'lotes'->>1)::bigint);
  END IF;
  RETURN jsonb_build_object('prod', v_prod, 'pedido', p->'pedido', 'item', p->'item',
                            'l2', v->'lotes'->0, 'l1', v->'lotes'->1);
END
$fn$;

-- Edita el pedido de la base E1 a `p_cant` y compara contra lo esperado.
CREATE OR REPLACE FUNCTION pg_temp.t_e1_editar(p_cli bigint, p_adm uuid, p_suc bigint, p_cant int,
                                                p_foto jsonb, p_huella int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; v_nueva bigint; f text[] := '{}'; v_f1 jsonb;
BEGIN
  d := pg_temp.t_base_e1(p_cli, p_adm, p_suc);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, p_cant)));
  v_nueva := pg_temp.t_linea(v_ped, v_prod, false);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = p_foto, format('editar a %s dejo %s, esperado %s', p_cant, v_f1, p_foto));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_nueva, (d->>'l1')::bigint) = p_huella
                       AND pg_temp.t_huella_linea(v_nueva) = p_huella,
                    format('la linea nueva quedo con huella %s en L1 (%s en total), esperado %s',
                           pg_temp.t_huella(v_nueva, (d->>'l1')::bigint), pg_temp.t_huella_linea(v_nueva), p_huella));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- E1 · editar sin cambios. Antes: {55,[0,50],5} y sin huella.
CREATE OR REPLACE FUNCTION pg_temp.caso_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_e1_editar(p_cli, p_adm, p_suc, 20, '{"stock":55,"lotes":[0,35],"bolsa":20}', 15);
$fn$;

-- E2 · subir a 30: las 10 de mas salen de la bolsa, la huella sigue en 15.
CREATE OR REPLACE FUNCTION pg_temp.caso_e2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_e1_editar(p_cli, p_adm, p_suc, 30, '{"stock":45,"lotes":[0,35],"bolsa":10}', 15);
$fn$;

-- E3 · bajar a 10: 10 vuelven a L1 (primero las del lote, como una salvedad).
CREATE OR REPLACE FUNCTION pg_temp.caso_e3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_e1_editar(p_cli, p_adm, p_suc, 10, '{"stock":65,"lotes":[0,45],"bolsa":20}', 5);
$fn$;

-- E1b · bolsa 25: el pedido de 20 sale entero de la bolsa. Editar sin cambios
--       no toca los lotes. Antes: {55,[5,50],0} (la devolucion caia en L2).
CREATE OR REPLACE FUNCTION pg_temp.caso_e1b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 25);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20); v_ped := p->>'pedido';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":55,"lotes":[0,50],"bolsa":5}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20)));
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('editar sin cambios dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella_linea(pg_temp.t_linea(v_ped, v_prod, false)) = 0,
                    'la linea que salio de la bolsa quedo con huella');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E1c · X sale entero de la bolsa (bolsa 20) y su regalo R, del mismo
--       producto, de L1 (huella 4). Editar sin cambios: foto identica, X sin
--       huella y R con la suya.
CREATE OR REPLACE FUNCTION pg_temp.caso_e1c(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_x bigint; v_r bigint;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 20, 20);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":66,"lotes":[0,46],"bolsa":20}'
     OR pg_temp.t_huella_linea((d->>'x')::bigint) <> 0
     OR pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20),
                                                           pg_temp.t_r(v_prod, 4, (d->>'promo')::bigint)));
  v_x := pg_temp.t_linea(v_ped, v_prod, false); v_r := pg_temp.t_linea(v_ped, v_prod, true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('editar sin cambios dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella_linea(v_x) = 0,
                    format('X quedo con huella %s, esperado 0', pg_temp.t_huella_linea(v_x)));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_r, (d->>'l1')::bigint) = 4,
                    format('R quedo con huella %s en L1, esperado 4', pg_temp.t_huella(v_r, (d->>'l1')::bigint)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E4 · X de 20 (5 bolsa + 15 L1) y R de 4 (de L1) del mismo producto, modo
--       A, reenviados igual. E5 (#1083): el stock total cierra.
CREATE OR REPLACE FUNCTION pg_temp.caso_e4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_x bigint; v_r bigint;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":51,"lotes":[0,31],"bolsa":20}'
     OR pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) <> 15
     OR pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20),
                                                           pg_temp.t_r(v_prod, 4, (d->>'promo')::bigint)));
  v_x := pg_temp.t_linea(v_ped, v_prod, false); v_r := pg_temp.t_linea(v_ped, v_prod, true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1->'stock' = v_f0->'stock',
                    format('E5 · el stock quedo %s, antes %s (#1083)', v_f1->'stock', v_f0->'stock'));
  f := pg_temp.t_si(f, v_f1 = v_f0, format('editar sin cambios dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_x, (d->>'l1')::bigint) = 15
                       AND pg_temp.t_huella(v_r, (d->>'l1')::bigint) = 4,
                    format('huellas X %s / R %s en L1, esperado 15 / 4',
                           pg_temp.t_huella(v_x, (d->>'l1')::bigint), pg_temp.t_huella(v_r, (d->>'l1')::bigint)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E4c · X de 20 (5 bolsa + 15 L1) y R de 4 (de L1): se baja X a 10 y R
--       queda igual. X conserva 5 y R sus 4 (la regla de la salvedad, por
--       linea); cancelar despues deja lo mismo que cancelar sin editar.
--       Por producto, X se quedaba con las 9 y R en 0, y cancelar dejaba
--       L2 +4 y la bolsa -4, aun con un solo lote en la huella.
CREATE OR REPLACE FUNCTION pg_temp.caso_e4c(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; v_l1 bigint; v_res jsonb; f text[] := '{}';
  v_f0 jsonb; v_f1 jsonb; v_f2 jsonb; v_x bigint; v_r bigint;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  v_prod := d->>'prod'; v_ped := d->>'pedido'; v_l1 := d->>'l1';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":51,"lotes":[0,31],"bolsa":20}'
     OR pg_temp.t_huella((d->>'x')::bigint, v_l1) <> 15
     OR pg_temp.t_huella((d->>'r')::bigint, v_l1) <> 4 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 10),
                                                           pg_temp.t_r(v_prod, 4, (d->>'promo')::bigint)));
  v_x := pg_temp.t_linea(v_ped, v_prod, false); v_r := pg_temp.t_linea(v_ped, v_prod, true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":61,"lotes":[0,41],"bolsa":20}',
                    format('bajar X a 10 dejo %s, esperado {61,[0,41],20}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_x, v_l1) = 5 AND pg_temp.t_huella_linea(v_x) = 5
                       AND pg_temp.t_huella(v_r, v_l1) = 4 AND pg_temp.t_huella_linea(v_r) = 4,
                    format('huellas X %s / R %s, esperado 5 / 4 (R no cambio)',
                           pg_temp.t_huella_linea(v_x), pg_temp.t_huella_linea(v_r)));
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1097', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f2 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f2 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar despues de bajar X dejo %s, esperado {75,[0,50],25} (como sin editar)', v_f2));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s / %s', v_f0, v_f1, v_f2));
END
$fn$;

-- E4b · dos renglones del mismo producto: A1 de 10 salio de L1 (huella 10) y
--       A2 de 10 de la bolsa. Se reenvian como una sola linea de 20: foto
--       identica y la linea nueva con huella 10. Antes L1 quedaba +10.
CREATE OR REPLACE FUNCTION pg_temp.caso_e4b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; v_ped bigint; v_l1 bigint; v_a2 bigint; v_nueva bigint;
  f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 0);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10); v_ped := p->>'pedido';
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 10);
  v_a2 := pg_temp.t_linea_extra(v_ped, v_prod, p_suc, 10, NULL);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":60,"lotes":[0,40],"bolsa":20}'
     OR pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 10 OR pg_temp.t_huella_linea(v_a2) <> 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20)));
  v_nueva := pg_temp.t_linea(v_ped, v_prod, false);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = v_f0, format('fusionar dejo %s, antes %s', v_f1, v_f0));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_nueva, v_l1) = 10,
                    format('la linea fusionada quedo con huella %s en L1, esperado 10', pg_temp.t_huella(v_nueva, v_l1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E6 · #1094: al lado de un renglon valido, -1, 0, 0.4 y un regalo en 0 se
--       rechazan con 'Cantidad invalida para producto ID ...', sin 22P02 ni
--       23514, y sin mover stock. Cada intento en su subbloque.
CREATE OR REPLACE FUNCTION pg_temp.caso_e6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  a jsonb; b jsonb; v_a bigint; v_b bigint; p jsonb; v_ped bigint;
  f text[] := '{}'; v_fa jsonb; v_fb jsonb; v_res jsonb; v_err text; v_sa jsonb; v_sb jsonb;
  v_nombre text; v_payload jsonb;
BEGIN
  a := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  b := pg_temp.t_prod(p_suc, p_adm, '[]', 50);
  v_a := a->>'prod'; v_b := b->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_a, 20); v_ped := p->>'pedido';
  v_fa := pg_temp.t_foto(v_a); v_fb := pg_temp.t_foto(v_b);

  FOR v_nombre, v_payload IN
    SELECT * FROM (VALUES
      ('-1',        jsonb_build_array(pg_temp.t_x(v_a, 20), pg_temp.t_x(v_b, -1))),
      ('0',         jsonb_build_array(pg_temp.t_x(v_a, 20), pg_temp.t_x(v_b, 0))),
      ('0.4',       jsonb_build_array(pg_temp.t_x(v_a, 20),
                                      jsonb_build_object('producto_id', v_b, 'cantidad', 0.4, 'precio_unitario', 100))),
      ('regalo 0',  jsonb_build_array(pg_temp.t_x(v_a, 20),
                                      jsonb_build_object('producto_id', v_b, 'cantidad', 0, 'precio_unitario', 0,
                                                         'es_bonificacion', true)))) t(n, j)
  LOOP
    v_res := NULL; v_err := NULL; v_sa := NULL; v_sb := NULL;
    BEGIN
      v_res := pg_temp.t_editar_res(v_ped, p_adm, v_payload);
      v_sa := pg_temp.t_foto(v_a); v_sb := pg_temp.t_foto(v_b);
      RAISE EXCEPTION USING ERRCODE = 'ZZ002';
    EXCEPTION
      WHEN SQLSTATE 'ZZ002' THEN NULL;
      WHEN OTHERS THEN v_err := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_err IS NOT NULL THEN
      f := f || format('%s: revento en vez de rechazar (%s)', v_nombre, v_err);
    ELSIF COALESCE((v_res->>'success')::boolean, true) THEN
      f := f || format('%s: acepto (stock de B %s -> %s)', v_nombre, v_fb->'stock', v_sb->'stock');
    ELSIF COALESCE(v_res->>'errores', '') NOT LIKE '%Cantidad invalida para producto ID ' || v_b || '%' THEN
      f := f || format('%s: rechazo con otro mensaje (%s)', v_nombre, v_res->>'errores');
    ELSIF v_sa IS DISTINCT FROM v_fa OR v_sb IS DISTINCT FROM v_fb THEN
      f := f || format('%s: rechazo pero movio stock (A %s -> %s, B %s -> %s)', v_nombre, v_fa, v_sa, v_fb, v_sb);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- E7 · #1094: el CHECK de pedido_items no deja una cantidad en 0.
CREATE OR REPLACE FUNCTION pg_temp.caso_e7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  a jsonb; p jsonb; v_estado text := 'paso'; v_con text;
BEGIN
  a := pg_temp.t_prod(p_suc, p_adm, '[]', 50);
  p := pg_temp.t_pedido(p_cli, p_adm, (a->>'prod')::bigint, 2);
  BEGIN
    INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES ((p->>'pedido')::bigint, (a->>'prod')::bigint, 0, 100, 0, p_suc);
  EXCEPTION
    WHEN check_violation THEN
      GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
      v_estado := 'check ' || COALESCE(v_con, '?');
    WHEN OTHERS THEN v_estado := 'otro error: ' || SQLSTATE || ' ' || SQLERRM;
  END;
  RETURN jsonb_build_object('fallas',
    CASE WHEN v_estado = 'check pedido_items_cantidad_positiva' THEN '[]'::jsonb
         ELSE jsonb_build_array(format('un renglon con cantidad 0: %s, esperado el CHECK pedido_items_cantidad_positiva', v_estado)) END);
END
$fn$;

-- E8 · sustituir R (4 de P, de L1) por 3 de Q (lote 100 con 10 vivas, bolsa
--      2). X conserva su huella (antes la devolucion a nivel pedido se comia
--      la de X); P recupera las 4 en L1; R deja 1 de huella en el lote de Q.
CREATE OR REPLACE FUNCTION pg_temp.caso_e8(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; q jsonb; v_prod bigint; v_q bigint; v_lq bigint; v_res jsonb;
  f text[] := '{}'; v_f1 jsonb; v_fq jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  q := pg_temp.t_prod(p_suc, p_adm, '[{"dias":60,"cantidad":100,"restante":10}]', 2);
  v_prod := d->>'prod'; v_q := q->>'prod'; v_lq := q->'lotes'->>0;
  v_res := public.sustituir_regalo_pedido((d->>'r')::bigint, v_q, 3, 'ensayo 1097', NULL, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'sustituir: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod); v_fq := pg_temp.t_foto(v_q);
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 15,
                    format('X quedo con huella %s en L1, esperado 15',
                           pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 0
                       AND pg_temp.t_huella((d->>'r')::bigint, (d->>'l2')::bigint) = 0,
                    'R sigue con huella en un lote de P');
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, v_lq) = 1,
                    format('R quedo con huella %s en el lote de Q, esperado 1', pg_temp.t_huella((d->>'r')::bigint, v_lq)));
  f := pg_temp.t_si(f, v_f1 = '{"stock":55,"lotes":[0,35],"bolsa":20}',
                    format('P quedo %s, esperado {55,[0,35],20}', v_f1));
  f := pg_temp.t_si(f, v_fq = '{"stock":9,"lotes":[9],"bolsa":0}',
                    format('Q quedo %s, esperado {9,[9],0}', v_fq));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('P %s / Q %s', v_f1, v_fq));
END
$fn$;

-- E8b · R de 4 (huella 4 en L1), bolsa de P 10; sustituir P -> P x6 (el
--       front lo bloquea, la RPC lo acepta): L1 igual, la bolsa -2, R con 4.
CREATE OR REPLACE FUNCTION pg_temp.caso_e8b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_res jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 10);
  v_prod := d->>'prod';
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":41,"lotes":[0,31],"bolsa":10}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  v_res := public.sustituir_regalo_pedido((d->>'r')::bigint, v_prod, 6, 'ensayo 1097', NULL, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'sustituir: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":39,"lotes":[0,31],"bolsa":8}',
                    format('P quedo %s, esperado {39,[0,31],8}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 4
                       AND pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 15,
                    format('huellas R %s / X %s en L1, esperado 4 / 15',
                           pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint),
                           pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E8c · sustituir con 0.4, 0.5 o 2.5 se rechaza con mensaje y sin mover
--       nada. Antes la linea (INTEGER) redondeaba para un lado y la bajada
--       de stock para el otro: 2.5 dejaba la linea en 3 y bajaba 2, y 0.5
--       dejaba 1 sin bajar nada.
CREATE OR REPLACE FUNCTION pg_temp.caso_e8c(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; q jsonb; v_q bigint; v_res jsonb; v_err text; v_c numeric;
  v_fq0 jsonb; v_fq jsonb; v_lin jsonb; f text[] := '{}';
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  q := pg_temp.t_prod(p_suc, p_adm, '[]', 20);
  v_q := q->>'prod';
  v_fq0 := pg_temp.t_foto(v_q);
  FOREACH v_c IN ARRAY ARRAY[0.4, 0.5, 2.5]::numeric[] LOOP
    v_res := NULL; v_err := NULL; v_fq := NULL; v_lin := NULL;
    BEGIN
      v_res := public.sustituir_regalo_pedido((d->>'r')::bigint, v_q, v_c, 'ensayo 1097', NULL, NULL);
      v_fq := pg_temp.t_foto(v_q);
      SELECT jsonb_build_object('producto', producto_id, 'cantidad', cantidad) INTO v_lin
        FROM public.pedido_items WHERE id = (d->>'r')::bigint;
      RAISE EXCEPTION USING ERRCODE = 'ZZ003';
    EXCEPTION
      WHEN SQLSTATE 'ZZ003' THEN NULL;
      WHEN OTHERS THEN v_err := SQLSTATE || ' ' || SQLERRM;
    END;
    IF v_err IS NOT NULL THEN
      f := f || format('sustituir con %s revento (%s)', v_c, v_err);
    ELSIF COALESCE((v_res->>'success')::boolean, true) THEN
      f := f || format('sustituir con %s acepto: la linea quedo %s y Q %s -> %s',
                       v_c, v_lin, v_fq0->'stock', v_fq->'stock');
    ELSIF v_res->>'error' IS DISTINCT FROM 'La cantidad sustituta tiene que ser un numero entero' THEN
      f := f || format('sustituir con %s rechazo con otro mensaje (%s)', v_c, v_res->>'error');
    ELSIF v_fq IS DISTINCT FROM v_fq0 OR (v_lin->>'producto')::bigint <> (d->>'prod')::bigint
          OR (v_lin->>'cantidad')::int <> 4 THEN
      f := f || format('sustituir con %s rechazo pero movio algo (linea %s, Q %s)', v_c, v_lin, v_fq);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- E9 · repartir R (4 de P) en [P 1, Q 3]: X conserva 15, R queda con 1 en L1
--      y L1 recupera 3; la parte Q deja 1 de huella en su lote.
CREATE OR REPLACE FUNCTION pg_temp.caso_e9(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; q jsonb; v_prod bigint; v_q bigint; v_lq bigint; v_res jsonb; v_parte_q bigint;
  f text[] := '{}'; v_f1 jsonb; v_fq jsonb;
BEGIN
  d := pg_temp.t_pedido_con_regalo(p_cli, p_adm, p_suc, 5, 20);
  q := pg_temp.t_prod(p_suc, p_adm, '[{"dias":60,"cantidad":100,"restante":10}]', 2);
  v_prod := d->>'prod'; v_q := q->>'prod'; v_lq := q->'lotes'->>0;
  v_res := public.dividir_regalo_pedido((d->>'r')::bigint,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1),
                               jsonb_build_object('producto_id', v_q, 'cantidad', 3)),
             'ensayo 1097', NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'dividir: %', v_res;
  END IF;
  v_parte_q := pg_temp.t_linea((d->>'pedido')::bigint, v_q, true);
  v_f1 := pg_temp.t_foto(v_prod); v_fq := pg_temp.t_foto(v_q);
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint) = 15,
                    format('X quedo con huella %s en L1, esperado 15',
                           pg_temp.t_huella((d->>'x')::bigint, (d->>'l1')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint) = 1,
                    format('R (P x1) quedo con huella %s en L1, esperado 1',
                           pg_temp.t_huella((d->>'r')::bigint, (d->>'l1')::bigint)));
  f := pg_temp.t_si(f, v_f1 = '{"stock":54,"lotes":[0,34],"bolsa":20}',
                    format('P quedo %s, esperado {54,[0,34],20}', v_f1));
  f := pg_temp.t_si(f, pg_temp.t_huella(v_parte_q, v_lq) = 1,
                    format('la parte Q quedo con huella %s en su lote, esperado 1', pg_temp.t_huella(v_parte_q, v_lq)));
  f := pg_temp.t_si(f, v_fq = '{"stock":9,"lotes":[9],"bolsa":0}',
                    format('Q quedo %s, esperado {9,[9],0}', v_fq));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('P %s / Q %s', v_f1, v_fq));
END
$fn$;

-- E10 · cancelar despues de editar sin cambios: las 15 vuelven a L1 y las 5
--       de la bolsa a la bolsa. Antes la edicion dejaba la linea sin huella y
--       la cancelacion las mandaba por FEFO a L2.
CREATE OR REPLACE FUNCTION pg_temp.caso_e10(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  d jsonb; v_prod bigint; v_ped bigint; v_res jsonb; f text[] := '{}'; v_f1 jsonb;
BEGIN
  d := pg_temp.t_base_e1(p_cli, p_adm, p_suc);
  v_prod := d->>'prod'; v_ped := d->>'pedido';
  PERFORM pg_temp.t_editar(v_ped, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 20)));
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1097', p_adm, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":75,"lotes":[0,50],"bolsa":25}',
                    format('cancelar despues de editar dejo %s, esperado {75,[0,50],25}', v_f1));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('foto %s', v_f1));
END
$fn$;

-- E11 · el bot: lote 100 con 50 vivas y bolsa 5; un pedido de 20 deja 15 de
--       huella en la linea.
CREATE OR REPLACE FUNCTION pg_temp.caso_e11(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_conf uuid; v_res jsonb; v_item bigint; f text[] := '{}';
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod';
  INSERT INTO public.bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total)
  VALUES (p_adm, p_suc, p_cli, jsonb_build_array(pg_temp.t_x(v_prod, 20)), 2000)
  RETURNING id INTO v_conf;
  v_res := public.crear_pedido_completo_bot(p_adm, v_conf);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'bot: %', v_res;
  END IF;
  v_item := pg_temp.t_linea((v_res->>'pedido_id')::bigint, v_prod, false);
  f := pg_temp.t_si(f, pg_temp.t_huella(v_item, (v->'lotes'->>0)::bigint) = 15,
                    format('la linea del bot quedo con huella %s, esperado 15',
                           pg_temp.t_huella(v_item, (v->'lotes'->>0)::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_prod) = '{"stock":35,"lotes":[35],"bolsa":0}',
                    format('el producto quedo %s, esperado {35,[35],0}', pg_temp.t_foto(v_prod)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- U1 · un producto sin lotes se edita como siempre.
CREATE OR REPLACE FUNCTION pg_temp.caso_u1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; p jsonb; v_prod bigint; f text[] := '{}';
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm, '[]', 50);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 10);
  PERFORM pg_temp.t_editar((p->>'pedido')::bigint, p_adm, jsonb_build_array(pg_temp.t_x(v_prod, 12)));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_prod) = '{"stock":38,"lotes":[],"bolsa":38}',
                    format('sin lotes quedo %s, esperado stock 38', pg_temp.t_foto(v_prod)));
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
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['e1', 'e2', 'e3', 'e1b', 'e1c', 'e4', 'e4b', 'e4c', 'e6', 'e7',
                                'e8', 'e8b', 'e8c', 'e9', 'e10', 'e11', 'u1'] LOOP
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
