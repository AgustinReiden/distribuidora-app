-- Ensayo de #1112: el reparto del regalo de una promo al cargar el pedido (dos
-- o mas lineas de regalo de la misma promo) es solo del admin.
--
-- Hasta la migracion XXX_el_reparto_del_alta_es_del_admin, crear_pedido_completo
-- lo aceptaba de cualquier rol que carga pedidos, y desde la 350 deja filas de
-- reparto con autorizado_por = quien cargo (un preventista). El front solo lo
-- ofrece al admin (ModalPedido).
--
--   R1 · preventista, V10 + Y2 + W2 de la misma promo -> rechazo con el mensaje
--        de rol y SIN efectos: ni pedido, ni lineas, ni filas de reparto, ni
--        stock, lotes o bolsa movidos (la guarda va antes de toda escritura).
--   R2 · encargado, el mismo pedido -> rechazo igual.
--   R3 · admin, el mismo pedido -> pasa: dos filas de reparto con el mismo
--        reparto_id, claves distintas, autorizado_por = admin, el stock del
--        alta de siempre (E3 de la 350).
--   R4 · preventista, un regalo de la promo A y uno de la B -> pasa.
--   R5 · preventista, dos lineas de VENTA del mismo producto y un regalo -> pasa.
--   R6 · admin carga a nombre de un preventista con reparto -> pasa, y
--        autorizado_por = el admin.
--   R7 · preventista con p_items NULL o no-array -> no es la guarda nueva la
--        que contesta (el modo de fallo de siempre).
--   R8 · admin: alta X4, dividir_regalo_pedido en X2 + Y2 y
--        cambiar_cliente_pedido con esas lineas -> pasa, el pedido nuevo tiene
--        sus dos filas de reparto con autorizado_por = admin (cambiar_cliente_
--        pedido atraviesa la guarda; hoy es solo admin).
--
--   R9 · preventista: alta [V10, X4] y despues actualizar_pedido_items con
--        [V10, X2, Y2] (parte el regalo en dos) -> rechazo con el mensaje de
--        la edicion y SIN efectos (lineas, filas de reparto, stock, lotes y
--        bolsa como antes). Es el hallazgo de la revision de #1112: sin la
--        guarda en la edicion, el reparto se armaba sin autorizado_por.
--   R10 · encargado, lo mismo que R9.
--   R11 · admin, lo mismo que R9 -> pasa.
--   R12 · el admin carga un reparto a nombre del preventista y el encargado
--         (o el preventista, antes de las 15:30) edita: mandando el regalo en
--         una linea o las mismas dos lineas del reparto, con el mismo total,
--         pasa y el reparto sigue (dos lineas de regalo, dos filas, aut = admin).
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenarlo con otra
-- sentencia en la misma transaccion).
--
--   psql "$DATABASE_URL" -f scripts/test-alta-reparto-rol-1112.sql

CREATE OR REPLACE FUNCTION pg_temp.rr_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- set_config es por transaccion (CLAUDE.md): entre llamada y llamada se
-- limpian los GUCs de stock, asi una RPC no hereda la etiqueta de otra.
CREATE OR REPLACE FUNCTION pg_temp.rr_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- La sesion de un usuario (auth.uid()).
CREATE OR REPLACE FUNCTION pg_temp.rr_como(p_user uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
END
$fn$;

-- Stock, lotes y bolsa de unos productos.
CREATE OR REPLACE FUNCTION pg_temp.rr_fotos(p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_object_agg(pr.id::text, jsonb_build_object(
           'stock', pr.stock,
           'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                                FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
           'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                           FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int))
    FROM public.productos pr WHERE pr.id = ANY(p_prods);
$fn$;

-- Un producto sintetico con un lote (90 dias, 100, p_restante vivas) y
-- p_bolsa sin lote. Bolsa distinta de 0 a proposito (nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.rr_prod(p_suc bigint, p_admin uuid, p_cat text, p_bolsa int, p_restante int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1112 ' || p_cat, 100, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1112 ' || p_cat)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.rr_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_promo(p_suc bigint, p_regalo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico)
  VALUES ('ZZ ensayo 1112', 'bonificacion', CURRENT_DATE, p_suc, true, p_regalo, false)
  RETURNING id INTO v;
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

-- El alta como p_user (con p_prev de preventista si viene). Devuelve el jsonb
-- de la RPC, sin abortar.
CREATE OR REPLACE FUNCTION pg_temp.rr_alta(p_cli bigint, p_user uuid, p_items jsonb, p_prev uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.rr_como(p_user);
  v_res := public.crear_pedido_completo(
    p_cliente_id => p_cli, p_total => 1000, p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1112', p_preventista_id => p_prev);
  PERFORM pg_temp.rr_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_es_guarda(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT pg_temp.rr_ok(p_res)
     AND COALESCE(p_res->'errores'->>0, '') LIKE 'Solo un admin puede repartir el regalo de una promo%';
$fn$;

-- Las filas de reparto de un pedido.
CREATE OR REPLACE FUNCTION pg_temp.rr_filas(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('reparto', s.reparto_id, 'cadena', s.cadena_id,
                                               'aut', s.autorizado_por, 'sust', s.producto_sustituto_id)
                            ORDER BY s.producto_sustituto_id), '[]'::jsonb)
    FROM public.pedido_item_sustituciones s WHERE s.pedido_id = p_ped AND s.reparto_id IS NOT NULL;
$fn$;

-- Dos filas de reparto del mismo reparto_id, claves distintas, autorizadas por p_aut.
CREATE OR REPLACE FUNCTION pg_temp.rr_reparto_ok(p_filas jsonb, p_aut uuid)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT jsonb_array_length(p_filas) = 2
     AND p_filas->0->>'reparto' = p_filas->1->>'reparto'
     AND p_filas->0->>'cadena' IS NOT NULL AND p_filas->0->>'cadena' <> p_filas->1->>'cadena'
     AND (p_filas->0->>'aut')::uuid = p_aut AND (p_filas->1->>'aut')::uuid = p_aut;
$fn$;

-- ---------------------------------------------------------------------------
-- R1/R2/R3 · el mismo alta con reparto, por rol
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_rol(p_cli bigint, p_adm uuid, p_suc bigint, p_user uuid, p_rol text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; v_promo bigint;
  v_res jsonb; v_f0 jsonb; v_f1 jsonb; v_n0 bigint[]; v_n1 bigint[]; v_ped bigint; v_hist jsonb; v_esp jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  v_promo := pg_temp.rr_promo(p_suc, x);

  v_f0 := pg_temp.rr_fotos(ARRAY[v, x, y, w]);
  v_n0 := ARRAY[(SELECT count(*) FROM public.pedidos WHERE cliente_id = p_cli),
                (SELECT count(*) FROM public.pedido_items WHERE producto_id IN (v, x, y, w)),
                (SELECT count(*) FROM public.pedido_item_sustituciones WHERE promocion_id = v_promo)];

  v_res := pg_temp.rr_alta(p_cli, p_user, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 2, v_promo),
                                                            pg_temp.rr_r(w, 2, v_promo)));

  IF p_rol <> 'admin' THEN
    v_f1 := pg_temp.rr_fotos(ARRAY[v, x, y, w]);
    v_n1 := ARRAY[(SELECT count(*) FROM public.pedidos WHERE cliente_id = p_cli),
                  (SELECT count(*) FROM public.pedido_items WHERE producto_id IN (v, x, y, w)),
                  (SELECT count(*) FROM public.pedido_item_sustituciones WHERE promocion_id = v_promo)];
    f := pg_temp.rr_si(f, pg_temp.rr_es_guarda(v_res),
                       format('el %s cargo un reparto en el alta: %s, esperado el rechazo de rol', p_rol, v_res));
    f := pg_temp.rr_si(f, v_n1 = v_n0,
                       format('pedidos/lineas/filas de reparto antes %s y despues %s', v_n0, v_n1));
    f := pg_temp.rr_si(f, v_f1 = v_f0, format('stock/lotes/bolsa antes %s y despues %s', v_f0, v_f1));
  ELSE
    f := pg_temp.rr_si(f, pg_temp.rr_ok(v_res), format('el admin no pudo cargar el reparto: %s', v_res));
    IF pg_temp.rr_ok(v_res) THEN
      v_ped := (v_res->>'pedido_id')::bigint;
      f := pg_temp.rr_si(f, pg_temp.rr_reparto_ok(pg_temp.rr_filas(v_ped), p_adm),
                         format('las filas de reparto del admin quedaron %s', pg_temp.rr_filas(v_ped)));
      SELECT jsonb_agg(jsonb_build_array(h.producto_id, h.diferencia, h.origen) ORDER BY h.producto_id, h.id)
        INTO v_hist
        FROM public.stock_historico h WHERE h.referencia_tipo = 'pedido' AND h.referencia_id = v_ped;
      SELECT jsonb_agg(e ORDER BY (e->>0)::bigint) INTO v_esp
        FROM jsonb_array_elements(jsonb_build_array(jsonb_build_array(v, -10, 'pedido_creado'),
                                                    jsonb_build_array(y, -2, 'pedido_creado'),
                                                    jsonb_build_array(w, -2, 'pedido_creado'))) e;
      f := pg_temp.rr_si(f, v_hist = v_esp, format('el stock del alta fue %s, esperado %s', v_hist, v_esp));
    END IF;
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r1(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE sql AS $fn$ SELECT pg_temp.rr_caso_rol(p_cli, p_adm, p_suc, p_prev, 'preventista'); $fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r2(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  IF p_enc IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin encargado en la sucursal: R2 salteado');
  END IF;
  RETURN pg_temp.rr_caso_rol(p_cli, p_adm, p_suc, p_enc, 'encargado');
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r3(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE sql AS $fn$ SELECT pg_temp.rr_caso_rol(p_cli, p_adm, p_suc, p_adm, 'admin'); $fn$;

-- ---------------------------------------------------------------------------
-- R4 · preventista: un regalo de la promo A y uno de la B (no es reparto)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r4(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; z bigint; pa bigint; pb bigint; v_res jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50);
  pa := pg_temp.rr_promo(p_suc, x);
  pb := pg_temp.rr_promo(p_suc, z);
  v_res := pg_temp.rr_alta(p_cli, p_prev, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 2, pa),
                                                            pg_temp.rr_r(z, 2, pb)));
  f := pg_temp.rr_si(f, pg_temp.rr_ok(v_res), format('un regalo por promo se rechazo: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- R5 · preventista: dos lineas de venta del mismo producto y un regalo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r5(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; pa bigint; v_res jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  pa := pg_temp.rr_promo(p_suc, x);
  v_res := pg_temp.rr_alta(p_cli, p_prev, jsonb_build_array(pg_temp.rr_v(v, 5), pg_temp.rr_v(v, 5),
                                                            pg_temp.rr_r(x, 2, pa)));
  f := pg_temp.rr_si(f, NOT pg_temp.rr_es_guarda(v_res),
                     format('dos lineas de venta del mismo producto dispararon la guarda: %s', v_res));
  f := pg_temp.rr_si(f, pg_temp.rr_ok(v_res), format('el alta con dos lineas de venta se rechazo: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- R6 · admin carga a nombre de un preventista con reparto
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r6(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; pa bigint; v_res jsonb; v_ped bigint;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  pa := pg_temp.rr_promo(p_suc, x);
  v_res := pg_temp.rr_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 2, pa),
                                                           pg_temp.rr_r(w, 2, pa)), p_prev);
  f := pg_temp.rr_si(f, pg_temp.rr_ok(v_res), format('el admin a nombre de un preventista no pudo: %s', v_res));
  IF pg_temp.rr_ok(v_res) THEN
    v_ped := (v_res->>'pedido_id')::bigint;
    f := pg_temp.rr_si(f, (SELECT usuario_id FROM public.pedidos WHERE id = v_ped) = p_prev,
                       'el pedido no quedo a nombre del preventista');
    f := pg_temp.rr_si(f, pg_temp.rr_reparto_ok(pg_temp.rr_filas(v_ped), p_adm),
                       format('las filas de reparto quedaron %s, esperado autorizado_por = admin',
                              pg_temp.rr_filas(v_ped)));
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- R7 · preventista con p_items NULL o no-array: no contesta la guarda nueva
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r7(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_items jsonb; v_out text; v_res jsonb; v_rep text[] := '{}';
BEGIN
  FOREACH v_items IN ARRAY ARRAY[NULL::jsonb, '{}'::jsonb, '"x"'::jsonb] LOOP
    BEGIN
      v_res := pg_temp.rr_alta(p_cli, p_prev, v_items);
      v_out := v_res::text;
      f := pg_temp.rr_si(f, NOT pg_temp.rr_ok(v_res), format('p_items %s se acepto: %s', v_items, v_res));
    EXCEPTION WHEN OTHERS THEN
      v_out := 'error: ' || SQLERRM;
    END;
    f := pg_temp.rr_si(f, v_out NOT LIKE '%Solo un admin puede repartir%',
                       format('p_items %s lo contesto la guarda nueva: %s', v_items, v_out));
    v_rep := v_rep || format('%s -> %s', COALESCE(v_items::text, 'NULL'), left(v_out, 120));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', array_to_string(v_rep, '; '));
END
$fn$;

-- ---------------------------------------------------------------------------
-- R8 · admin: dividir y despues cambiar el cliente con las lineas repartidas
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r8(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; pa bigint; v_res jsonb; v_ped bigint; v_item bigint; v_nuevo bigint;
BEGIN
  IF p_cli2 IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin segundo cliente: R8 salteado');
  END IF;
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  pa := pg_temp.rr_promo(p_suc, x);
  v_res := pg_temp.rr_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 4, pa)));
  IF NOT pg_temp.rr_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM public.pedido_items
   WHERE pedido_id = v_ped AND producto_id = x AND COALESCE(es_bonificacion, false);

  PERFORM pg_temp.rr_como(p_adm);
  v_res := public.dividir_regalo_pedido(v_item, jsonb_build_array(jsonb_build_object('producto_id', x, 'cantidad', 2),
                                                                  jsonb_build_object('producto_id', y, 'cantidad', 2)),
                                        'ensayo 1112');
  PERFORM pg_temp.rr_reset();
  IF NOT pg_temp.rr_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo dividir el regalo: %', v_res;
  END IF;

  PERFORM pg_temp.rr_como(p_adm);
  v_res := public.cambiar_cliente_pedido(v_ped, p_cli2, p_adm,
             jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 2, pa), pg_temp.rr_r(y, 2, pa)),
             1000, NULL, 0, 'ensayo 1112');
  PERFORM pg_temp.rr_reset();
  f := pg_temp.rr_si(f, pg_temp.rr_ok(v_res), format('cambiar_cliente_pedido con un reparto dio %s', v_res));
  IF pg_temp.rr_ok(v_res) THEN
    v_nuevo := (v_res->>'nuevo_pedido_id')::bigint;
    f := pg_temp.rr_si(f, pg_temp.rr_reparto_ok(pg_temp.rr_filas(v_nuevo), p_adm),
                       format('el pedido nuevo quedo con las filas de reparto %s', pg_temp.rr_filas(v_nuevo)));
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- R9/R10/R11 · la edicion que parte el regalo en dos, por rol
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_edit(p_ped bigint, p_user uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.rr_como(p_user);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.rr_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_es_guarda_edit(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT pg_temp.rr_ok(p_res)
     AND COALESCE(p_res->'errores'->>0, '') LIKE 'Solo un admin puede repartir el regalo de una promo%al editar el pedido%';
$fn$;

-- Las lineas de un pedido, para comparar antes y despues.
CREATE OR REPLACE FUNCTION pg_temp.rr_lineas(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_array(pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false),
                                              pi.regalo_cadena_id) ORDER BY pi.id), '[]'::jsonb)
    FROM public.pedido_items pi WHERE pi.pedido_id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_edicion(p_cli bigint, p_adm uuid, p_suc bigint, p_user uuid, p_rol text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; v_promo bigint; v_res jsonb; v_ped bigint;
  v_f0 jsonb; v_f1 jsonb; v_l0 jsonb; v_l1 jsonb; v_s0 jsonb; v_s1 jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  v_promo := pg_temp.rr_promo(p_suc, x);

  v_res := pg_temp.rr_alta(p_cli, p_user, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 4, v_promo)));
  IF NOT pg_temp.rr_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido de %: %', p_rol, v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;

  v_f0 := pg_temp.rr_fotos(ARRAY[v, x, y]);
  v_l0 := pg_temp.rr_lineas(v_ped);
  v_s0 := pg_temp.rr_filas(v_ped);

  v_res := pg_temp.rr_edit(v_ped, p_user, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 2, v_promo),
                                                           pg_temp.rr_r(y, 2, v_promo)));
  v_f1 := pg_temp.rr_fotos(ARRAY[v, x, y]);
  v_l1 := pg_temp.rr_lineas(v_ped);
  v_s1 := pg_temp.rr_filas(v_ped);

  IF p_rol <> 'admin' THEN
    f := pg_temp.rr_si(f, pg_temp.rr_es_guarda_edit(v_res),
                       format('el %s partio el regalo en la edicion: %s, esperado el rechazo de rol', p_rol, v_res));
    f := pg_temp.rr_si(f, v_l1 = v_l0, format('las lineas antes %s y despues %s', v_l0, v_l1));
    f := pg_temp.rr_si(f, v_s1 = v_s0, format('las filas de reparto antes %s y despues %s', v_s0, v_s1));
    f := pg_temp.rr_si(f, v_f1 = v_f0, format('stock/lotes/bolsa antes %s y despues %s', v_f0, v_f1));
  ELSE
    f := pg_temp.rr_si(f, pg_temp.rr_ok(v_res), format('el admin no pudo partir el regalo en la edicion: %s', v_res));
    f := pg_temp.rr_si(f, (SELECT count(*) FROM public.pedido_items
                            WHERE pedido_id = v_ped AND COALESCE(es_bonificacion, false)) = 2,
                       format('el admin esperaba 2 lineas de regalo y quedaron %s', pg_temp.rr_lineas(v_ped)));
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r9(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE sql AS $fn$ SELECT pg_temp.rr_caso_edicion(p_cli, p_adm, p_suc, p_prev, 'preventista'); $fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r10(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  IF p_enc IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin encargado en la sucursal: R10 salteado');
  END IF;
  RETURN pg_temp.rr_caso_edicion(p_cli, p_adm, p_suc, p_enc, 'encargado');
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r11(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE sql AS $fn$ SELECT pg_temp.rr_caso_edicion(p_cli, p_adm, p_suc, p_adm, 'admin'); $fn$;

-- ---------------------------------------------------------------------------
-- R12 · el reparto que hizo un admin sobrevive a la edicion de otro rol
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_r12(p_cli bigint, p_adm uuid, p_suc bigint, p_prev uuid, p_enc uuid, p_cli2 bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; v_promo bigint; v_res jsonb; v_ped bigint;
  v_user uuid; v_i int; v_items jsonb;
BEGIN
  IF p_enc IS NOT NULL THEN
    v_user := p_enc;
  ELSIF (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::time < TIME '15:30' THEN
    v_user := p_prev;
  ELSE
    RETURN jsonb_build_object('fallas', '[]'::jsonb,
      'reporte', 'sin encargado y pasadas las 15:30 el preventista no edita: R12 salteado');
  END IF;
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50);
  v_promo := pg_temp.rr_promo(p_suc, x);

  v_res := pg_temp.rr_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 2, v_promo),
                                                           pg_temp.rr_r(w, 2, v_promo)), p_prev);
  IF NOT pg_temp.rr_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo cargar el reparto: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;

  FOR v_i IN 1..2 LOOP
    -- 1: el regalo en una linea (lo que manda el front); 2: las dos lineas del reparto.
    v_items := CASE v_i
      WHEN 1 THEN jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 4, v_promo))
      ELSE jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 2, v_promo), pg_temp.rr_r(w, 2, v_promo)) END;
    v_res := pg_temp.rr_edit(v_ped, v_user, v_items);
    f := pg_temp.rr_si(f, pg_temp.rr_ok(v_res), format('la edicion %s del reparto de un admin dio %s', v_i, v_res));
    f := pg_temp.rr_si(f, (SELECT count(*) FROM public.pedido_items
                            WHERE pedido_id = v_ped AND COALESCE(es_bonificacion, false)) = 2,
                       format('tras la edicion %s las lineas de regalo quedaron %s', v_i, pg_temp.rr_lineas(v_ped)));
    f := pg_temp.rr_si(f, pg_temp.rr_reparto_ok(pg_temp.rr_filas(v_ped), p_adm),
                       format('tras la edicion %s las filas de reparto quedaron %s', v_i, pg_temp.rr_filas(v_ped)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1112$
DECLARE
  v_admin   uuid;
  v_prev    uuid;
  v_enc     uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_cli2    bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
  -- Una sucursal activa con un admin y un preventista activos (y un encargado,
  -- si hay); se prefiere la que tiene los tres.
  SELECT s.id,
         (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
           WHERE us.sucursal_id = s.id AND pf.rol = 'admin' AND pf.activo ORDER BY us.usuario_id LIMIT 1),
         (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
           WHERE us.sucursal_id = s.id AND pf.rol = 'preventista' AND pf.activo ORDER BY us.usuario_id LIMIT 1),
         (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
           WHERE us.sucursal_id = s.id AND pf.rol = 'encargado' AND pf.activo ORDER BY us.usuario_id LIMIT 1)
    INTO v_suc, v_admin, v_prev, v_enc
    FROM sucursales s
   WHERE s.activa
   ORDER BY (SELECT count(DISTINCT pf.rol) FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
              WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol IN ('admin', 'preventista', 'encargado')) DESC,
            s.id
   LIMIT 1;
  -- Clientes que el preventista puede operar: activos, sin asignar (visibles
  -- para todos, mig 028) y no reservados al admin (mig 214).
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
     AND preventista_id IS NULL AND NOT COALESCE(reservado_admin, false)
   ORDER BY id LIMIT 1;
  SELECT id INTO v_cli2 FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
     AND preventista_id IS NULL AND NOT COALESCE(reservado_admin, false) AND id <> v_cliente
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_prev IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hace falta una sucursal activa con un admin, un preventista y un cliente sin asignar';
  END IF;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r9', 'r10', 'r11', 'r12'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.rr_reset();
      PERFORM pg_temp.rr_como(v_admin);
      EXECUTE format('SELECT pg_temp.rr_caso_%s($1, $2, $3, $4, $5, $6)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc, v_prev, v_enc, v_cli2;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
      IF v_out->>'reporte' IS NOT NULL THEN
        v_notas := v_notas || (upper(v_caso) || ' · ' || (v_out->>'reporte'));
      END IF;
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas):\n- %\nnotas: %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | ');
  END IF;
  IF current_setting('ensayo.continuar', true) = '1' THEN
    RAISE NOTICE 'ENSAYO OK · notas: %', array_to_string(v_notas, ' | ');
  ELSE
    RAISE EXCEPTION 'ENSAYO OK · notas: %', array_to_string(v_notas, ' | ');
  END IF;
END
$ensayo1112$;
