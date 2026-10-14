-- Ensayo de #1123: el server valida el regalo de quien no es admin, al cargar
-- (crear_pedido_completo) y al editar (actualizar_pedido_items).
--
-- Regla (decision del dueno, 2026-10-13), para quien no es admin:
--   producto = el default vigente de la promo o uno de su misma categoria
--   (regalo_misma_categoria, #950); al editar, ademas, la linea que hereda
--   cadena o el mismo producto de la unica linea de regalo que la promo ya
--   tenia. Cantidad <= floor(venta de sus productos / cantidad_compra) *
--   cantidad_bonificacion, medida sobre lo que mando el llamador. Sin
--   promocion_id: rechazo (al editar, salvo la linea sin promo que el pedido
--   ya tenia, sin subir). El admin queda exento.
--
-- Fixture: V (venta), X (cat A, default de la promo), Y (cat A), Z (cat B).
-- Promo P: disparador V, compra 5, bonificacion 2 -> V10 da un tope de 4.
--
-- Alta:
--   A1  preventista, V10 + X4 (default, = tope) -> pasa.
--   A2  preventista, V10 + Z4 (otra categoria) -> rechazo SIN efectos.
--   A3  preventista, V10 + Y4 (misma categoria) -> pasa.
--   A4  preventista, V10 + X5 (tope + 1) -> rechazo SIN efectos.
--   A5  preventista, V10 + X2 (debajo del tope) -> pasa.
--   A6  regalo sin promocion_id: preventista -> rechazo; admin -> pasa.
--   A7  promo inexistente, y promo de otra sucursal si hay -> rechazo.
--   A8  encargado con A2 y A4 -> rechazo.
--   A9  admin, V10 + Z50 -> pasa.
--   A10 preventista por crear_pedido_idempotente con offline_id y Z4 ->
--       rechazo, no sella offline_id, y el mensaje es terminal (no calza con
--       el patron de stock ni con el de sesion de rechazoDeNegocio.ts).
--   A11 promo fraccion (compra 1, bonif 2), tres sabores x1 -> 6 pasa, 7 no.
--   A12 el regalo tambien es disparador: no suma al tope (V4 + regalo V1 con
--       compra 5 -> rechazo; V5 + regalo V1 -> pasa).
--   A13 VB con regalo -> sigue saliendo el mensaje del VB.
--   A14 admin, cambiar_cliente_pedido con un regalo de otra categoria y un
--       regalo sin promo -> pasa.
--   A15 A1 con SET LOCAL ROLE authenticated -> pasa (el REVOKE a
--       authenticated de las funciones nuevas no rompe a la definer).
--
-- Edicion (el editor no-admin es el preventista antes de las 15:30 ARG; si
-- no, el encargado; sin ninguno de los dos, se saltea):
--   E1  alta legal y edicion a X5 (tope + 1) -> rechazo SIN efectos.
--   E2  edicion a Z4 (otra categoria) -> rechazo SIN efectos.
--   E3a el admin sustituye X por Z (sustituir_regalo_pedido); el editor manda
--       la raiz X4 y despues el final Z4 -> pasan (heredan cadena).
--   E3b el encargado (o el admin) reparte X4 en X2 + Z2; el editor manda
--       V10 + X4 -> pasa y el reparto sigue.
--   E3c sobre E3b, el editor sube V a 15 y manda una sola linea Z6 -> rechazo
--       SIN efectos (la promo tiene dos lineas: sin exencion).
--   E4  alta V10 + X4, el default rota a Z (otra categoria) y el editor manda
--       X4 -> pasa (la linea unica que ya estaba).
--   E5  reparto de admin (X2 + Y2) y el editor manda las mismas lineas, o el
--       regalo en una linea -> pasa (R12 de #1112).
--   E6  edicion que agrega un regalo sin promo -> rechazo; un regalo cuya
--       promo se borro (promocion_id NULL) se conserva igual -> pasa, y si
--       sube -> rechazo.
--   E7  reparto conservado (X4 + Y4, tope 8) y el editor baja V a 1 con los
--       mismos cortes -> rechazo SIN efectos.
--   E8  reparto de admin por encima del tope (X3 + Y3, tope 4) y el editor
--       no toca el regalo -> rechazo con mensaje terminal (costo aceptado).
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenarlo con otra
-- sentencia en la misma transaccion).
--
--   psql "$DATABASE_URL" -f scripts/test-regalo-alta-1123.sql

CREATE OR REPLACE FUNCTION pg_temp.ra_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- set_config es por transaccion (CLAUDE.md): entre llamada y llamada se
-- limpian los GUCs de stock, asi una RPC no hereda la etiqueta de otra.
CREATE OR REPLACE FUNCTION pg_temp.ra_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_como(p_user uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
END
$fn$;

-- Stock, lotes y bolsa de unos productos.
CREATE OR REPLACE FUNCTION pg_temp.ra_fotos(p_prods bigint[])
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
CREATE OR REPLACE FUNCTION pg_temp.ra_prod(p_suc bigint, p_admin uuid, p_cat text, p_bolsa int DEFAULT 20, p_restante int DEFAULT 50)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1123 ' || p_cat, 100, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1123 ' || p_cat)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.ra_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

-- Una promo de bonificacion con su regalo default, sus disparadores y sus reglas.
CREATE OR REPLACE FUNCTION pg_temp.ra_promo(p_suc bigint, p_regalo bigint, p_disp bigint[],
                                            p_compra numeric DEFAULT 5, p_bonif numeric DEFAULT 2)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico)
  VALUES ('ZZ ensayo 1123', 'bonificacion', pg_temp.ra_hoy() - 1, p_suc, true, p_regalo, false)
  RETURNING id INTO v;
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  SELECT v, d, p_suc FROM unnest(p_disp) d;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v, 'cantidad_compra', p_compra, p_suc), (v, 'cantidad_bonificacion', p_bonif, p_suc);
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_total(p_items jsonb)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
    FROM jsonb_array_elements(p_items) e;
$fn$;

-- El alta como p_user (con p_prev de preventista si viene). No aborta.
CREATE OR REPLACE FUNCTION pg_temp.ra_alta(p_cli bigint, p_user uuid, p_items jsonb, p_prev uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.ra_como(p_user);
  v_res := public.crear_pedido_completo(
    p_cliente_id => p_cli, p_total => pg_temp.ra_total(p_items), p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1123', p_preventista_id => p_prev);
  PERFORM pg_temp.ra_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_edit(p_ped bigint, p_user uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.ra_como(p_user);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.ra_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

-- Rechazo (success = false) con un primer error que calza con p_patron (LIKE).
CREATE OR REPLACE FUNCTION pg_temp.ra_rechazo(p_res jsonb, p_patron text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT pg_temp.ra_ok(p_res) AND COALESCE(p_res->'errores'->>0, '') LIKE p_patron;
$fn$;

-- El mismo criterio que rechazoEsTerminal (src/utils/rechazoDeNegocio.ts).
CREATE OR REPLACE FUNCTION pg_temp.ra_terminal(p_msg text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT p_msg IS NOT NULL
     AND p_msg !~* 'stock insuficiente|sin stock|stock disponible'
     AND lower(p_msg) NOT LIKE '%no se pudo determinar la sucursal activa%'
     AND lower(p_msg) NOT LIKE '%jwt expired%'
     AND lower(p_msg) NOT LIKE '%token is expired%'
     AND lower(p_msg) NOT LIKE '%invalid claim%';
$fn$;

-- Lo que un alta rechazada no puede haber tocado.
CREATE OR REPLACE FUNCTION pg_temp.ra_estado(p_cli bigint, p_prods bigint[], p_promos bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'pedidos', (SELECT count(*) FROM public.pedidos WHERE cliente_id = p_cli),
    'lineas', (SELECT count(*) FROM public.pedido_items WHERE producto_id = ANY(p_prods)),
    'fotos', pg_temp.ra_fotos(p_prods),
    'usos', (SELECT jsonb_agg(jsonb_build_array(id, usos_pendientes) ORDER BY id)
               FROM public.promociones WHERE id = ANY(p_promos)),
    'acum', (SELECT COALESCE(jsonb_agg(jsonb_build_array(id, producto_regalo_id, usos_pendientes) ORDER BY id), '[]'::jsonb)
               FROM public.promo_acumuladores WHERE promocion_id = ANY(p_promos)));
$fn$;

-- Lo que una edicion rechazada no puede haber tocado.
CREATE OR REPLACE FUNCTION pg_temp.ra_estado_ped(p_ped bigint, p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'lineas', (SELECT COALESCE(jsonb_agg(jsonb_build_array(pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false),
                                                          pi.promocion_id, pi.regalo_cadena_id) ORDER BY pi.id), '[]'::jsonb)
                 FROM public.pedido_items pi WHERE pi.pedido_id = p_ped),
    'sust', (SELECT count(*) FROM public.pedido_item_sustituciones WHERE pedido_id = p_ped),
    'total', (SELECT total FROM public.pedidos WHERE id = p_ped),
    'fotos', pg_temp.ra_fotos(p_prods));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_n_regalos(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT count(*) FROM public.pedido_items WHERE pedido_id = p_ped AND COALESCE(es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_item_regalo(p_ped bigint, p_prod bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false)
   ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_pedido(p_res jsonb, p_que text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT pg_temp.ra_ok(p_res) THEN
    RAISE EXCEPTION 'no se pudo preparar %: %', p_que, p_res;
  END IF;
  RETURN (p_res->>'pedido_id')::bigint;
END
$fn$;

-- Un alta que tiene que rechazarse SIN efectos.
CREATE OR REPLACE FUNCTION pg_temp.ra_alta_rechazada(p_f text[], p_que text, p_cli bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_promos bigint[], p_patron text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.ra_estado(p_cli, p_prods, p_promos);
  v_res := pg_temp.ra_alta(p_cli, p_user, p_items);
  v_e1 := pg_temp.ra_estado(p_cli, p_prods, p_promos);
  f := pg_temp.ra_si(f, pg_temp.ra_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res) OR pg_temp.ra_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.ra_si(f, v_e1 = v_e0, format('%s: el alta rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

-- Una edicion que tiene que rechazarse SIN efectos.
CREATE OR REPLACE FUNCTION pg_temp.ra_edit_rechazada(p_f text[], p_que text, p_ped bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_patron text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.ra_estado_ped(p_ped, p_prods);
  v_res := pg_temp.ra_edit(p_ped, p_user, p_items);
  v_e1 := pg_temp.ra_estado_ped(p_ped, p_prods);
  f := pg_temp.ra_si(f, pg_temp.ra_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res) OR pg_temp.ra_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.ra_si(f, v_e1 = v_e0, format('%s: la edicion rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

-- Patrones de los mensajes.
CREATE OR REPLACE FUNCTION pg_temp.ra_pat_cat() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'El regalo de la promo "%" tiene que ser % o un producto de su misma categoría.%' $fn$;
CREATE OR REPLACE FUNCTION pg_temp.ra_pat_tope() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'El regalo de la promo "%" no puede pasar de % con lo que lleva el pedido%' $fn$;
CREATE OR REPLACE FUNCTION pg_temp.ra_pat_sin() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'Una línea de regalo tiene que venir de una promoción%' $fn$;
CREATE OR REPLACE FUNCTION pg_temp.ra_pat_noexiste() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'La promoción % no existe en esta sucursal.%' $fn$;

-- El fixture estandar: V, X, Y, Z y la promo P (regalo X, disparador V, 5 -> 2).
CREATE OR REPLACE FUNCTION pg_temp.ra_fix(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint; x bigint; y bigint; z bigint; p bigint;
  s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
BEGIN
  v := pg_temp.ra_prod(s, a, 'venta');
  x := pg_temp.ra_prod(s, a, 'cat A');
  y := pg_temp.ra_prod(s, a, 'cat A');
  z := pg_temp.ra_prod(s, a, 'cat B');
  p := pg_temp.ra_promo(s, x, ARRAY[v]);
  RETURN jsonb_build_object('v', v, 'x', x, 'y', y, 'z', z, 'p', p);
END
$fn$;

-- ===========================================================================
-- ALTA
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_res jsonb; v_ped bigint;
BEGIN
  v_res := pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'x')::bigint, 4, (k->>'p')::bigint)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('el regalo default al tope se rechazo: %s', v_res));
  IF pg_temp.ra_ok(v_res) THEN
    v_ped := (v_res->>'pedido_id')::bigint;
    f := pg_temp.ra_si(f, (SELECT cantidad FROM public.pedido_items
                            WHERE pedido_id = v_ped AND producto_id = (k->>'x')::bigint AND es_bonificacion) = 4,
                       'el regalo no quedo con cantidad 4');
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c);
BEGIN
  f := pg_temp.ra_alta_rechazada(f, 'Z4 de otra categoria', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'z')::bigint, 4, (k->>'p')::bigint)),
         ARRAY[(k->>'v')::bigint, (k->>'x')::bigint, (k->>'z')::bigint], ARRAY[(k->>'p')::bigint], pg_temp.ra_pat_cat());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_res jsonb;
BEGIN
  v_res := pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'y')::bigint, 4, (k->>'p')::bigint)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('un regalo de la misma categoria se rechazo: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c);
BEGIN
  f := pg_temp.ra_alta_rechazada(f, 'X5 (tope + 1)', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'x')::bigint, 5, (k->>'p')::bigint)),
         ARRAY[(k->>'v')::bigint, (k->>'x')::bigint], ARRAY[(k->>'p')::bigint], pg_temp.ra_pat_tope());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_res jsonb;
BEGIN
  v_res := pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'x')::bigint, 2, (k->>'p')::bigint)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('un regalo debajo del tope se rechazo: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a6(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_items jsonb; v_res jsonb;
BEGIN
  v_items := jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10),
               pg_temp.ra_r((k->>'x')::bigint, 2, NULL));
  f := pg_temp.ra_alta_rechazada(f, 'regalo sin promo (preventista)', (c->>'cli')::bigint, (c->>'prev')::uuid, v_items,
         ARRAY[(k->>'v')::bigint, (k->>'x')::bigint], ARRAY[(k->>'p')::bigint], pg_temp.ra_pat_sin());
  v_res := pg_temp.ra_alta((c->>'cli')::bigint, (c->>'adm')::uuid, v_items);
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('el admin no pudo cargar un regalo sin promo: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a7(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_otra bigint := (c->>'otra_suc')::bigint;
  v_promo_otra bigint; v_rep text;
BEGIN
  f := pg_temp.ra_alta_rechazada(f, 'promo inexistente', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10),
                           pg_temp.ra_r((k->>'x')::bigint, 2, (SELECT COALESCE(max(id), 0) + 1000000 FROM public.promociones))),
         ARRAY[(k->>'v')::bigint, (k->>'x')::bigint], ARRAY[(k->>'p')::bigint], pg_temp.ra_pat_noexiste());
  IF v_otra IS NOT NULL THEN
    INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, ajuste_automatico)
    VALUES ('ZZ ensayo 1123 otra sucursal', 'bonificacion', pg_temp.ra_hoy() - 1, v_otra, true, false)
    RETURNING id INTO v_promo_otra;
    f := pg_temp.ra_alta_rechazada(f, 'promo de otra sucursal', (c->>'cli')::bigint, (c->>'prev')::uuid,
           jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'x')::bigint, 2, v_promo_otra)),
           ARRAY[(k->>'v')::bigint, (k->>'x')::bigint], ARRAY[(k->>'p')::bigint], pg_temp.ra_pat_noexiste());
  ELSE
    v_rep := 'sin otra sucursal: la promo de otra sucursal se saltea';
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', v_rep);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a8(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb; v_enc uuid := (c->>'enc')::uuid;
BEGIN
  IF v_enc IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin encargado en la sucursal: A8 salteado');
  END IF;
  k := pg_temp.ra_fix(c);
  f := pg_temp.ra_alta_rechazada(f, 'encargado, Z4', (c->>'cli')::bigint, v_enc,
         jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'z')::bigint, 4, (k->>'p')::bigint)),
         ARRAY[(k->>'v')::bigint, (k->>'z')::bigint], ARRAY[(k->>'p')::bigint], pg_temp.ra_pat_cat());
  f := pg_temp.ra_alta_rechazada(f, 'encargado, X5', (c->>'cli')::bigint, v_enc,
         jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'x')::bigint, 5, (k->>'p')::bigint)),
         ARRAY[(k->>'v')::bigint, (k->>'x')::bigint], ARRAY[(k->>'p')::bigint], pg_temp.ra_pat_tope());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a9(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_res jsonb;
BEGIN
  v_res := pg_temp.ra_alta((c->>'cli')::bigint, (c->>'adm')::uuid,
             jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'z')::bigint, 50, (k->>'p')::bigint)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('el admin no pudo cargar Z50: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a10(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_res jsonb; v_items jsonb;
  v_oid text := 'ensayo-1123-' || gen_random_uuid()::text; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  v_items := jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'z')::bigint, 4, (k->>'p')::bigint));
  PERFORM pg_temp.ra_como(v_prev);
  v_res := public.crear_pedido_idempotente(
    p_cliente_id => (c->>'cli')::bigint, p_total => pg_temp.ra_total(v_items), p_usuario_id => v_prev,
    p_items => v_items, p_notas => 'ensayo 1123', p_offline_id => v_oid);
  PERFORM pg_temp.ra_reset();
  f := pg_temp.ra_si(f, pg_temp.ra_rechazo(v_res, pg_temp.ra_pat_cat()),
                     format('el replay con un regalo de otra categoria dio %s', v_res));
  f := pg_temp.ra_si(f, NOT EXISTS (SELECT 1 FROM public.pedidos WHERE offline_id = v_oid),
                     'el offline_id quedo sellado');
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res) OR pg_temp.ra_terminal(v_res->'errores'->>0),
                     format('el rechazo del replay no es terminal: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a11(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  v bigint; w bigint; u bigint; x bigint; p bigint; v_res jsonb; v_base jsonb;
BEGIN
  v := pg_temp.ra_prod(s, a, 'venta');
  w := pg_temp.ra_prod(s, a, 'venta');
  u := pg_temp.ra_prod(s, a, 'venta');
  x := pg_temp.ra_prod(s, a, 'cat A');
  p := pg_temp.ra_promo(s, x, ARRAY[v, w, u], 1, 2);
  v_base := jsonb_build_array(pg_temp.ra_v(v, 1), pg_temp.ra_v(w, 1), pg_temp.ra_v(u, 1));
  v_res := pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid, v_base || pg_temp.ra_r(x, 6, p));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('tres sabores x1 con regalo 6 se rechazo: %s', v_res));
  f := pg_temp.ra_alta_rechazada(f, 'tres sabores x1 con regalo 7', (c->>'cli')::bigint, (c->>'prev')::uuid,
         v_base || pg_temp.ra_r(x, 7, p), ARRAY[v, w, u, x], ARRAY[p], pg_temp.ra_pat_tope());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a12(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  v bigint; p bigint; v_res jsonb;
BEGIN
  v := pg_temp.ra_prod(s, a, 'venta');
  p := pg_temp.ra_promo(s, v, ARRAY[v], 5, 1);
  -- Si el regalo sumara, V4 + V1 = 5 daria un bloque.
  f := pg_temp.ra_alta_rechazada(f, 'V4 + regalo V1', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.ra_v(v, 4), pg_temp.ra_r(v, 1, p)), ARRAY[v], ARRAY[p], pg_temp.ra_pat_tope());
  v_res := pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 5), pg_temp.ra_r(v, 1, p)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('V5 + regalo V1 se rechazo: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a13(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_res jsonb; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = (c->>'cli')::bigint;
  PERFORM pg_temp.ra_como(v_prev);
  v_res := public.crear_pedido_completo(
    p_cliente_id => (c->>'cli')::bigint, p_total => 0, p_usuario_id => v_prev,
    p_items => jsonb_build_array(
      jsonb_build_object('producto_id', (k->>'v')::bigint, 'cantidad', 10, 'precio_unitario', 0),
      pg_temp.ra_r((k->>'z')::bigint, 4, (k->>'p')::bigint)),
    p_notas => 'ensayo 1123', p_tipo_factura => 'VB');
  PERFORM pg_temp.ra_reset();
  f := pg_temp.ra_si(f, pg_temp.ra_rechazo(v_res, 'Un vale blanco no lleva promociones ni regalos%'),
                     format('el VB con regalo dio %s, esperado el mensaje del VB', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a14(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb; v_res jsonb; v_ped bigint; v_items jsonb; a uuid := (c->>'adm')::uuid;
BEGIN
  IF c->>'cli2' IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin segundo cliente: A14 salteado');
  END IF;
  k := pg_temp.ra_fix(c);
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, a,
             jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'x')::bigint, 4, (k->>'p')::bigint))),
             'el alta de A14');
  v_items := jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10),
                               pg_temp.ra_r((k->>'z')::bigint, 4, (k->>'p')::bigint),
                               pg_temp.ra_r((k->>'y')::bigint, 1, NULL));
  PERFORM pg_temp.ra_como(a);
  v_res := public.cambiar_cliente_pedido(v_ped, (c->>'cli2')::bigint, a, v_items, 1000, NULL, 0, 'ensayo 1123');
  PERFORM pg_temp.ra_reset();
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res),
                     format('cambiar_cliente_pedido del admin con regalo de otra categoria y sin promo dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_a15(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_res jsonb; v_items jsonb; v_total numeric;
  v_prev uuid := (c->>'prev')::uuid; v_cli bigint := (c->>'cli')::bigint; v_err text;
BEGIN
  v_items := jsonb_build_array(pg_temp.ra_v((k->>'v')::bigint, 10), pg_temp.ra_r((k->>'x')::bigint, 4, (k->>'p')::bigint));
  v_total := pg_temp.ra_total(v_items);
  PERFORM pg_temp.ra_como(v_prev);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := public.crear_pedido_completo(
      p_cliente_id => v_cli, p_total => v_total, p_usuario_id => v_prev, p_items => v_items, p_notas => 'ensayo 1123');
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    EXECUTE 'RESET ROLE';
  END;
  PERFORM pg_temp.ra_reset();
  f := pg_temp.ra_si(f, v_err IS NULL AND pg_temp.ra_ok(v_res),
                     format('como authenticated el alta legal dio %s (error: %s)', v_res, v_err));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- EDICION
-- ===========================================================================
-- c->>'ed' es el editor no-admin (preventista antes de las 15:30, si no el
-- encargado). Los pedidos se cargan a nombre del preventista, asi el editor
-- preventista es su creador.

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v bigint := (k->>'v')::bigint;
  x bigint := (k->>'x')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p))), 'el alta de E1');
  f := pg_temp.ra_edit_rechazada(f, 'edicion a X5', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 5, p)), ARRAY[v, x], pg_temp.ra_pat_tope());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v bigint := (k->>'v')::bigint;
  x bigint := (k->>'x')::bigint; z bigint := (k->>'z')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p))), 'el alta de E2');
  f := pg_temp.ra_edit_rechazada(f, 'edicion a Z4', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(z, 4, p)), ARRAY[v, x, z], pg_temp.ra_pat_cat());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e3a(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v_res jsonb; a uuid := (c->>'adm')::uuid;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; z bigint := (k->>'z')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, a,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p)), (c->>'prev')::uuid), 'el alta de E3a');
  PERFORM pg_temp.ra_como(a);
  v_res := public.sustituir_regalo_pedido(pg_temp.ra_item_regalo(v_ped, x), z, 4, 'ensayo 1123', NULL, NULL);
  PERFORM pg_temp.ra_reset();
  IF NOT pg_temp.ra_ok(v_res) THEN
    RAISE EXCEPTION 'el admin no pudo sustituir el regalo: %', v_res;
  END IF;
  v_res := pg_temp.ra_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('la edicion con la raiz del regalo sustituido dio %s', v_res));
  v_res := pg_temp.ra_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(z, 4, p)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('la edicion con el final del regalo sustituido dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- El pedido con el regalo X4 repartido en X2 + Z2 por el encargado (o el admin).
CREATE OR REPLACE FUNCTION pg_temp.ra_reparto_x_z(c jsonb, k jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_ped bigint; v_res jsonb; v_rep uuid := COALESCE((c->>'enc')::uuid, (c->>'adm')::uuid);
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; z bigint := (k->>'z')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, (c->>'adm')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p)), (c->>'prev')::uuid), 'el alta del reparto');
  PERFORM pg_temp.ra_como(v_rep);
  v_res := public.dividir_regalo_pedido(pg_temp.ra_item_regalo(v_ped, x),
             jsonb_build_array(jsonb_build_object('producto_id', x, 'cantidad', 2),
                               jsonb_build_object('producto_id', z, 'cantidad', 2)), 'ensayo 1123');
  PERFORM pg_temp.ra_reset();
  IF NOT pg_temp.ra_ok(v_res) THEN
    RAISE EXCEPTION 'no se pudo repartir el regalo: %', v_res;
  END IF;
  RETURN v_ped;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e3b(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v_res jsonb;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_reparto_x_z(c, k);
  v_res := pg_temp.ra_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('la edicion que no toca un reparto X2 + Z2 dio %s', v_res));
  f := pg_temp.ra_si(f, pg_temp.ra_n_regalos(v_ped) = 2,
                     format('el reparto no se conservo: %s', pg_temp.ra_estado_ped(v_ped, '{}')));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e3c(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; z bigint := (k->>'z')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_reparto_x_z(c, k);
  f := pg_temp.ra_edit_rechazada(f, 'V15 y una sola linea Z6 sobre un reparto', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.ra_v(v, 15), pg_temp.ra_r(z, 6, p)), ARRAY[v, x, z], pg_temp.ra_pat_cat());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v_res jsonb;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; z bigint := (k->>'z')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p))), 'el alta de E4');
  -- El admin rota el default de la promo a otra categoria.
  UPDATE public.promociones SET producto_regalo_id = z WHERE id = p;
  v_res := pg_temp.ra_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('la edicion con el default viejo tras la rotacion dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v_res jsonb; v_i int; v_items jsonb;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; y bigint := (k->>'y')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, (c->>'adm')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 2, p), pg_temp.ra_r(y, 2, p)), (c->>'prev')::uuid),
             'el reparto del admin de E5');
  FOR v_i IN 1..2 LOOP
    v_items := CASE v_i
      WHEN 1 THEN jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 2, p), pg_temp.ra_r(y, 2, p))
      ELSE jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p)) END;
    v_res := pg_temp.ra_edit(v_ped, (c->>'ed')::uuid, v_items);
    f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('la edicion %s del reparto de un admin dio %s', v_i, v_res));
    f := pg_temp.ra_si(f, pg_temp.ra_n_regalos(v_ped) = 2,
                       format('tras la edicion %s el reparto no se conservo: %s', v_i, pg_temp.ra_estado_ped(v_ped, '{}')));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e6(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v_res jsonb;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; y bigint := (k->>'y')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p))), 'el alta de E6');
  f := pg_temp.ra_edit_rechazada(f, 'edicion que agrega un regalo sin promo', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p), pg_temp.ra_r(y, 1, NULL)),
         ARRAY[v, x, y], pg_temp.ra_pat_sin());
  -- La promo se borra: la FK ON DELETE SET NULL deja el regalo sin promocion_id.
  UPDATE public.pedido_items SET promocion_id = NULL
   WHERE pedido_id = v_ped AND COALESCE(es_bonificacion, false);
  v_res := pg_temp.ra_edit(v_ped, (c->>'ed')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, NULL)));
  f := pg_temp.ra_si(f, pg_temp.ra_ok(v_res), format('conservar el regalo de una promo borrada dio %s', v_res));
  f := pg_temp.ra_edit_rechazada(f, 'subir el regalo de una promo borrada', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 5, NULL)), ARRAY[v, x], pg_temp.ra_pat_sin());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e7(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  v bigint; x bigint; y bigint; p bigint; v_ped bigint;
BEGIN
  v := pg_temp.ra_prod(s, a, 'venta');
  x := pg_temp.ra_prod(s, a, 'cat A');
  y := pg_temp.ra_prod(s, a, 'cat A');
  p := pg_temp.ra_promo(s, x, ARRAY[v], 5, 4);   -- V10 -> tope 8
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, a,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 4, p), pg_temp.ra_r(y, 4, p)), (c->>'prev')::uuid),
             'el reparto del admin de E7');
  f := pg_temp.ra_edit_rechazada(f, 'V1 con los mismos cortes 4 + 4', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.ra_v(v, 1), pg_temp.ra_r(x, 4, p), pg_temp.ra_r(y, 4, p)), ARRAY[v, x, y],
         pg_temp.ra_pat_tope());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.ra_caso_e8(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.ra_fix(c); v_ped bigint; v_ed uuid := COALESCE((c->>'enc')::uuid, (c->>'ed')::uuid);
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; y bigint := (k->>'y')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.ra_pedido(pg_temp.ra_alta((c->>'cli')::bigint, (c->>'adm')::uuid,
             jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 3, p), pg_temp.ra_r(y, 3, p)), (c->>'prev')::uuid),
             'el reparto del admin por encima del tope de E8');
  f := pg_temp.ra_edit_rechazada(f, 'edicion que no toca un reparto por encima del tope', v_ped, v_ed,
         jsonb_build_array(pg_temp.ra_v(v, 10), pg_temp.ra_r(x, 3, p), pg_temp.ra_r(y, 3, p)), ARRAY[v, x, y],
         pg_temp.ra_pat_tope());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1123$
DECLARE
  v_admin   uuid;
  v_prev    uuid;
  v_enc     uuid;
  v_ed      uuid;
  v_suc     bigint;
  v_otra    bigint;
  v_cliente bigint;
  v_cli2    bigint;
  v_ctx     jsonb;
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
  SELECT id INTO v_otra FROM sucursales WHERE id <> v_suc ORDER BY id LIMIT 1;
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

  -- El editor no-admin: el preventista solo edita antes de las 15:30 (ARG).
  IF (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::time < TIME '15:30' THEN
    v_ed := v_prev;
  ELSE
    v_ed := v_enc;
  END IF;

  v_ctx := jsonb_build_object('suc', v_suc, 'adm', v_admin, 'prev', v_prev, 'enc', v_enc, 'ed', v_ed,
                              'cli', v_cliente, 'cli2', v_cli2, 'otra_suc', v_otra);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10', 'a11', 'a12',
                                'a13', 'a14', 'a15',
                                'e1', 'e2', 'e3a', 'e3b', 'e3c', 'e4', 'e5', 'e6', 'e7', 'e8'] LOOP
    v_out := NULL;
    IF v_caso LIKE 'e%' AND v_ed IS NULL THEN
      v_notas := v_notas || (upper(v_caso) || ' · sin encargado y pasadas las 15:30: salteado');
      CONTINUE;
    END IF;
    BEGIN
      PERFORM pg_temp.ra_reset();
      PERFORM pg_temp.ra_como(v_admin);
      EXECUTE format('SELECT pg_temp.ra_caso_%s($1)', v_caso) INTO v_out USING v_ctx;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || left(x, 160)
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
$ensayo1123$;
