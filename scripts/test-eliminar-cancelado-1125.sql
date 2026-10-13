-- Ensayo de #1125: eliminar un pedido ya dado de baja no devuelve el stock
-- dos veces.
--
-- eliminar_pedido_completo con p_restaurar_stock = true sumaba al stock todas
-- las lineas de pedido_items sin mirar si el pedido ya estaba dado de baja.
-- cancelar_pedido_con_stock no borra las lineas y ya devolvio (o mermo, si fue
-- por falta de stock) esas unidades y consumio su huella, asi que la segunda
-- devolucion entraba a la bolsa (desde la 353): stock +N fantasma.
--
-- Decision del dueño (2026-10-13), opcion A: sobre un pedido dado de baja la
-- restauracion se fuerza a false, el pedido se borra igual y
-- pedidos_eliminados queda con stock_restaurado = false y una marca en
-- motivo_eliminacion.
--
-- "Dado de baja" = estado 'cancelado' o 'anulado' (#1080) o
-- motivo_cancelacion no nulo: un cancelado puede volver a otro estado por REST
-- sin que se le vuelva a descontar el stock (el pedido 1856 de prod).
--
--   E1 · L2 vacio que vence antes, L1 100/50, bolsa 40, pedido 20 de la
--        bolsa, cancelar, eliminar(true): la foto no cambia, ninguna fila
--        nueva en stock_historico (con cualquier origen), STK-F/STK-D iguales,
--        el pedido se borro y pedidos_eliminados dice stock_restaurado false
--        con la marca.
--   E2 · huella parcial (5 bolsa + 15 lote, despues 20 a la bolsa), cancelar,
--        eliminar(true): la foto no cambia.
--   E3 · cancelado por falta de stock, eliminar(true): la foto no cambia.
--   E4 · pedido con un regalo que mueve stock, cancelar, eliminar(true): la
--        foto no cambia y el contador de la promo no se revierte otra vez.
--   E5 · regresion: un pendiente, eliminar(true) restaura como siempre
--        (stock_restaurado true, sin marca).
--   E6 · eliminar(false): sobre un pendiente no restaura; sobre un cancelado
--        tampoco, y sin marca (no se pidio restaurar).
--   E7 · cancelado y vuelto a 'pendiente' por UPDATE (el 1856): eliminar(true)
--        no restaura.
--   E8 · 'anulado' por UPDATE sobre un pedido vivo: eliminar(true) no restaura.
--
-- La bolsa es distinta de 0 en todos los casos (CLAUDE.md: con bolsa 0 la
-- bajada cae en el lote por FEFO y da bien por casualidad).
--
-- Corre contra prod SIN dejar rastro: cada caso corre en un subbloque que se
-- revierte y todo termina en un RAISE EXCEPTION. Veredicto en el mensaje:
-- 'ENSAYO OK' o 'ENSAYO FALLO'. Es manual, no esta enganchado a CI.
--
--   psql "$DATABASE_URL" -f scripts/test-eliminar-cancelado-1125.sql

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
  VALUES ('ZZ ensayo 1125', 100,
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
    'ensayo 1125');
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
  VALUES ('ZZ ensayo 1125', 'bonificacion', CURRENT_DATE, p_suc, true, p_prod) RETURNING id INTO v_promo;
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

CREATE OR REPLACE FUNCTION pg_temp.t_cancelar(p_ped bigint, p_adm uuid, p_tipo text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1125', p_adm, p_tipo);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
END
$fn$;

-- Suma unidades a la bolsa con un origen fuera de la lista blanca (no van a
-- ningun lote).
CREATE OR REPLACE FUNCTION pg_temp.t_a_la_bolsa(p_prod bigint, p_n int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', 'ensayo_1125', true);
  UPDATE public.productos SET stock = stock + p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_origen', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_eliminar(p_ped bigint, p_adm uuid, p_restaurar boolean)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.eliminar_pedido_completo(p_ped, p_adm, 'ensayo 1125', p_restaurar);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'eliminar: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

-- Ultimo id de stock_historico (para contar las filas nuevas despues).
CREATE OR REPLACE FUNCTION pg_temp.t_ultimo_mov()
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT COALESCE(MAX(id), 0) FROM public.stock_historico;
$fn$;

-- Filas nuevas de stock_historico de estos productos, con CUALQUIER origen
-- ('auto' incluido, que es lo que mira STK-D).
CREATE OR REPLACE FUNCTION pg_temp.t_movs(p_prods bigint[], p_desde bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COUNT(*)::int FROM public.stock_historico
   WHERE id > p_desde AND producto_id = ANY(p_prods);
$fn$;

-- La fila de pedidos_eliminados del pedido.
CREATE OR REPLACE FUNCTION pg_temp.t_registro(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT to_jsonb(x) FROM (
    SELECT estado, stock_restaurado, motivo_eliminacion
      FROM public.pedidos_eliminados WHERE pedido_id = p_ped ORDER BY id DESC LIMIT 1) x;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_stk()
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_agg(x ORDER BY x->>'id') FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' IN ('STK-F', 'STK-D');
$fn$;

-- Comun a los casos "eliminar un dado de baja con restaurar = true": la foto
-- no cambia, ninguna fila nueva en el ledger, el pedido ya no existe y el
-- registro dice que no se restauro y por que.
CREATE OR REPLACE FUNCTION pg_temp.t_eliminar_baja(p_ped bigint, p_adm uuid, p_prods bigint[], p_estado text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_antes jsonb; v_despues jsonb; v_mov bigint; v_res jsonb; v_reg jsonb; v_n int;
BEGIN
  SELECT jsonb_agg(pg_temp.t_foto(x) ORDER BY x) INTO v_antes FROM unnest(p_prods) x;
  v_mov := pg_temp.t_ultimo_mov();
  v_res := pg_temp.t_eliminar(p_ped, p_adm, true);
  SELECT jsonb_agg(pg_temp.t_foto(x) ORDER BY x) INTO v_despues FROM unnest(p_prods) x;
  f := pg_temp.t_si(f, v_despues = v_antes,
                    format('eliminar(true) movio el stock: antes %s, despues %s (ya se habia devuelto)', v_antes, v_despues));
  v_n := pg_temp.t_movs(p_prods, v_mov);
  f := pg_temp.t_si(f, v_n = 0, format('eliminar(true) dejo %s filas nuevas en stock_historico', v_n));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pedidos WHERE id = p_ped), 'el pedido no se borro');
  v_reg := pg_temp.t_registro(p_ped);
  f := pg_temp.t_si(f, v_reg->>'estado' = p_estado, format('pedidos_eliminados.estado = %s, esperado %s', v_reg->>'estado', p_estado));
  f := pg_temp.t_si(f, (v_reg->>'stock_restaurado')::boolean IS FALSE,
                    format('pedidos_eliminados.stock_restaurado = %s, esperado false', v_reg->>'stock_restaurado'));
  f := pg_temp.t_si(f, v_reg->>'motivo_eliminacion' LIKE 'ensayo 1125%[stock ya devuelto por la cancelacion]',
                    format('motivo_eliminacion sin la marca: %s', v_reg->>'motivo_eliminacion'));
  f := pg_temp.t_si(f, (v_res->>'stock_restaurado')::boolean IS FALSE,
                    format('el RETURN no dice stock_restaurado false: %s', v_res));
  RETURN f;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- E1 · L2 (30 dias, 50, 0 vivas), L1 (90 dias, 100, 50 vivas), bolsa 40.
--      Pedido 20: sale de la bolsa. Cancelar: vuelve a la bolsa. Eliminar con
--      restaurar = true: nada se mueve (sin el parche, stock +20 y bolsa +20).
CREATE OR REPLACE FUNCTION pg_temp.caso_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_stk0 jsonb; v_stk1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":90,"lotes":[0,50],"bolsa":40}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida (despues de cancelar): %s', v_f0)));
  END IF;
  v_stk0 := pg_temp.t_stk();
  f := pg_temp.t_eliminar_baja((p->>'pedido')::bigint, p_adm, ARRAY[v_prod], 'cancelado');
  v_stk1 := pg_temp.t_stk();
  f := pg_temp.t_si(f, v_stk1 = v_stk0, format('STK-F/STK-D cambiaron: %s -> %s', v_stk0, v_stk1));
  v_f1 := pg_temp.t_foto(v_prod);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E2 · huella parcial. Bolsa 5, pedido 20: 5 de la bolsa y 15 de L1. Se suman
--      20 a la bolsa. Cancelar (15 a L1, 5 a la bolsa) y eliminar(true).
CREATE OR REPLACE FUNCTION pg_temp.caso_e2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; v_l1 bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 5);
  v_prod := v->>'prod'; v_l1 := v->'lotes'->>1;
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_a_la_bolsa(v_prod, 20);
  IF pg_temp.t_huella((p->>'item')::bigint, v_l1) <> 15 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array('punto de partida: la linea no tiene huella 15 en L1'));
  END IF;
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":75,"lotes":[0,50],"bolsa":25}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida (despues de cancelar): %s', v_f0)));
  END IF;
  f := pg_temp.t_eliminar_baja((p->>'pedido')::bigint, p_adm, ARRAY[v_prod], 'cancelado');
  v_f1 := pg_temp.t_foto(v_prod);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E3 · cancelado por falta de stock (neto 0: devuelve y merma). Eliminar(true)
--      no puede subir el stock: la mercaderia no existe.
CREATE OR REPLACE FUNCTION pg_temp.caso_e3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm, 'falta_stock');
  v_f0 := pg_temp.t_foto(v_prod);
  IF (v_f0->>'stock')::int <> 70 OR (v_f0->>'bolsa')::int = 0 THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida (despues de cancelar por falta de stock): %s', v_f0)));
  END IF;
  f := pg_temp.t_eliminar_baja((p->>'pedido')::bigint, p_adm, ARRAY[v_prod], 'cancelado');
  v_f1 := pg_temp.t_foto(v_prod);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E4 · linea de 20 (de la bolsa) y un regalo de 4 del mismo producto, de una
--      promo que mueve stock, con usos_pendientes = 10. Cancelar y
--      eliminar(true): ni el stock ni el contador de la promo se mueven otra vez.
CREATE OR REPLACE FUNCTION pg_temp.caso_e4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; v_r bigint; v_promo bigint; f text[] := '{}';
  v_f0 jsonb; v_f1 jsonb; v_u0 int; v_u1 int;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_r := pg_temp.t_regalo((p->>'pedido')::bigint, v_prod, p_suc, 4);
  SELECT promocion_id INTO v_promo FROM public.pedido_items WHERE id = v_r;
  UPDATE public.promociones SET usos_pendientes = 10 WHERE id = v_promo;
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  v_f0 := pg_temp.t_foto(v_prod);
  SELECT usos_pendientes INTO v_u0 FROM public.promociones WHERE id = v_promo;
  IF v_f0 <> '{"stock":90,"lotes":[0,50],"bolsa":40}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida (despues de cancelar): %s', v_f0)));
  END IF;
  f := pg_temp.t_eliminar_baja((p->>'pedido')::bigint, p_adm, ARRAY[v_prod], 'cancelado');
  SELECT usos_pendientes INTO v_u1 FROM public.promociones WHERE id = v_promo;
  f := pg_temp.t_si(f, v_u1 IS NOT DISTINCT FROM v_u0,
                    format('el contador de la promo se revirtio otra vez: %s -> %s', v_u0, v_u1));
  v_f1 := pg_temp.t_foto(v_prod);
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('fotos %s / %s, usos %s / %s', v_f0, v_f1, v_u0, v_u1));
END
$fn$;

-- E5 · regresion: un pendiente se elimina con restaurar = true y el stock
--      vuelve como siempre (de la bolsa, a la bolsa).
CREATE OR REPLACE FUNCTION pg_temp.caso_e5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb; v_reg jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":70,"lotes":[0,50],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  PERFORM pg_temp.t_eliminar((p->>'pedido')::bigint, p_adm, true);
  v_f1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_f1 = '{"stock":90,"lotes":[0,50],"bolsa":40}',
                    format('eliminar un pendiente dejo %s, esperado {stock 90, lotes [0,50], bolsa 40}', v_f1));
  v_reg := pg_temp.t_registro((p->>'pedido')::bigint);
  f := pg_temp.t_si(f, (v_reg->>'stock_restaurado')::boolean IS TRUE AND v_reg->>'motivo_eliminacion' = 'ensayo 1125',
                    format('registro del pendiente: %s, esperado stock_restaurado true y motivo sin marca', v_reg));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E6 · eliminar(false): (a) un pendiente no restaura; (b) un cancelado
--      tampoco, y su registro no lleva la marca (no se pidio restaurar).
CREATE OR REPLACE FUNCTION pg_temp.caso_e6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_a0 jsonb; v_a1 jsonb; v_b0 jsonb; v_b1 jsonb; v_reg jsonb;
BEGIN
  -- (a) pendiente
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  v_a0 := pg_temp.t_foto(v_prod);
  PERFORM pg_temp.t_eliminar((p->>'pedido')::bigint, p_adm, false);
  v_a1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_a1 = v_a0, format('(a) eliminar(false) de un pendiente movio el stock: %s -> %s', v_a0, v_a1));
  v_reg := pg_temp.t_registro((p->>'pedido')::bigint);
  f := pg_temp.t_si(f, (v_reg->>'stock_restaurado')::boolean IS FALSE AND v_reg->>'motivo_eliminacion' = 'ensayo 1125',
                    format('(a) registro: %s', v_reg));

  -- (b) cancelado
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  v_b0 := pg_temp.t_foto(v_prod);
  PERFORM pg_temp.t_eliminar((p->>'pedido')::bigint, p_adm, false);
  v_b1 := pg_temp.t_foto(v_prod);
  f := pg_temp.t_si(f, v_b1 = v_b0, format('(b) eliminar(false) de un cancelado movio el stock: %s -> %s', v_b0, v_b1));
  v_reg := pg_temp.t_registro((p->>'pedido')::bigint);
  f := pg_temp.t_si(f, (v_reg->>'stock_restaurado')::boolean IS FALSE AND v_reg->>'motivo_eliminacion' = 'ensayo 1125',
                    format('(b) registro: %s', v_reg));
  RETURN jsonb_build_object('fallas', to_jsonb(f),
    'reporte', format('(a) %s / %s · (b) %s / %s', v_a0, v_a1, v_b0, v_b1));
END
$fn$;

-- E7 · el 1856: cancelado y vuelto a 'pendiente' por UPDATE (como el REST de
--      admin), sin volver a descontar. motivo_cancelacion queda. Eliminar(true)
--      no restaura.
CREATE OR REPLACE FUNCTION pg_temp.caso_e7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  PERFORM pg_temp.t_cancelar((p->>'pedido')::bigint, p_adm);
  UPDATE public.pedidos SET estado = 'pendiente' WHERE id = (p->>'pedido')::bigint;
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":90,"lotes":[0,50],"bolsa":40}'
     OR (SELECT motivo_cancelacion FROM public.pedidos WHERE id = (p->>'pedido')::bigint) IS NULL THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida (reactivado): %s', v_f0)));
  END IF;
  f := pg_temp.t_eliminar_baja((p->>'pedido')::bigint, p_adm, ARRAY[v_prod], 'pendiente');
  v_f1 := pg_temp.t_foto(v_prod);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
END
$fn$;

-- E8 · 'anulado' (#1080) por UPDATE sobre un pedido vivo: eliminar(true) no
--      restaura.
CREATE OR REPLACE FUNCTION pg_temp.caso_e8(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb; v_prod bigint; p jsonb; f text[] := '{}'; v_f0 jsonb; v_f1 jsonb;
BEGIN
  v := pg_temp.t_prod(p_suc, p_adm,
         '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
  v_prod := v->>'prod';
  p := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20);
  UPDATE public.pedidos SET estado = 'anulado' WHERE id = (p->>'pedido')::bigint;
  v_f0 := pg_temp.t_foto(v_prod);
  IF v_f0 <> '{"stock":70,"lotes":[0,50],"bolsa":20}' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_f0)));
  END IF;
  f := pg_temp.t_eliminar_baja((p->>'pedido')::bigint, p_adm, ARRAY[v_prod], 'anulado');
  v_f1 := pg_temp.t_foto(v_prod);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('fotos %s / %s', v_f0, v_f1));
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

  FOREACH v_caso IN ARRAY ARRAY['e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8'] LOOP
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
