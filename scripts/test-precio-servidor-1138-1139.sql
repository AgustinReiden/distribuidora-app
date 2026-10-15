-- Ensayo de #1138 y #1139: el regalo va a precio 0 (CHECK y las dos RPCs) y el
-- precio de venta de quien no es admin no baja del piso de la lista.
--
-- Regla (decision del dueno, 2026-10-13):
--   * #1138: un regalo con precio distinto de 0 se rechaza en
--     crear_pedido_completo y actualizar_pedido_items, para cualquier rol, y el
--     CHECK pedido_items_regalo_a_precio_cero lo cierra en la tabla.
--   * #1139, para quien no es admin y fuera del VB: precio >= piso - 0,01, con
--     piso = round(LEAST(lista, menor escala aplicable) * (1 - % del cliente), 2).
--     Replay: solo el precio INMEDIATAMENTE anterior, > 0, vigente al menos 15
--     minutos y dentro de politicas_comerciales.ventana_precio_anterior_horas
--     (24 por defecto); idem la version anterior de cada escala. Edicion: el
--     precio guardado se conserva si ningun grupo del producto achica su total
--     ni sus productos distintos (sin grupo, siempre); nunca mira origen_precio.
--
-- Alta:
--   A1  regalo a $5: preventista, encargado y admin -> rechazo SIN efectos; por
--       crear_pedido_idempotente no sella offline_id; a $0 pasa.
--   A2  preventista a $0,01 -> rechazo SIN efectos (terminal); a lista pasa.
--   A3  fardo surtido que llega a la escala (6 + 6 de 12) -> pasa; 6 + 5 al
--       precio de escala -> rechazo.
--   A4  descuento general del 10% -> pasa; con la categoria al 0%, el mismo
--       precio -> rechazo y a lista pasa.
-- Ventana (filas de audit_logs con created_at llevado al pasado, como postgres):
--   W1  producto 0 -> 6550 en la misma transaccion y venta a $0,01 -> rechazo.
--   W2  21 -> 0,10 -> 2158 con el 0,10 vigente 5 minutos: a $0,10 y a $21
--       -> rechazo; a $2158 pasa.
--   W3  4450 -> 4570 con el anterior vigente 2 horas: a $4450 pasa; a $4440 no.
--   W4  4450 -> 4570 -> 4700: a $4570 pasa; a $4450 rechazo (solo el anterior).
--   W5  el cambio hace 30 h con ventana de 24 -> rechazo; con ventana de 48 pasa.
-- Escalas:
--   S1  precio de la escala subido en el lugar dentro de la ventana: el viejo
--       pasa; debajo del viejo no.
--   S2  umbral cambiado por DELETE + INSERT (12 -> 24): un pedido de 12 al
--       precio viejo pasa; uno de 11 no.
--   S3  escala desactivada en la ventana: pasa.
--   S4  grupo desactivado, o producto sacado del grupo -> rechazo (documentado).
-- Roles:
--   R1  encargado a $0,01 -> rechazo; admin a $0,01 -> pasa; VB de un
--       preventista -> pasa; editar ese VB (preventista y encargado) -> el
--       rechazo de siempre ("Un vale blanco no se edita"), sin efectos.
-- Edicion (el editor no-admin es el preventista con el corte de las 15:30
-- fijado en 24:00, y cada caso se repite con el encargado, con el corte en
-- 00:00, si la sucursal tiene uno: #1178; no depende de la hora de la corrida):
--   E1  baja del precio de una linea existente -> rechazo SIN efectos (editor y
--       encargado); subir la cantidad a lista pasa.
--   E2  50 fardos a escala, registrar_origen_precio_items 'manual' y editar a 5
--       -> rechazo; lo mismo sin registrar_origen -> rechazo.
--   E3  linea a un precio de admin bajo el piso: agregar otro producto la
--       conserva y pasa; achicar su grupo -> rechazo; bajar una linea sin grupo
--       a precio de admin pasa.
--   E4  linea nueva bajo el piso -> rechazo.
--   E5  regalo a $3 -> rechazo para el editor y para el admin.
--   E6  el admin edita libre ($0,01 pasa).
-- CHECK y gate:
--   C1  INSERT y UPDATE directos de un regalo con precio > 0 -> 23514.
--   C2  sustituir, dividir, salvedad sobre un regalo y su anulacion: terminan
--       bien y sin un regalo con precio o subtotal distinto de 0 (anular una
--       salvedad sobre un regalo hoy lo rechaza anular_salvedad: vale ese
--       rechazo).
--   C3  PRECIO-A = 0, y una funcion que inserta pedido_items sin el piso lo
--       sube a 1.
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE.
--
--   psql "$DATABASE_URL" -f scripts/test-precio-servidor-1138-1139.sql

CREATE OR REPLACE FUNCTION pg_temp.pp_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_como(p_user uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
END
$fn$;

-- Un producto sintetico con un lote (90 dias, 100, p_restante vivas) y
-- p_bolsa sin lote. Bolsa distinta de 0 a proposito (nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.pp_prod(p_suc bigint, p_admin uuid, p_cat text, p_precio numeric DEFAULT 100,
                                           p_bolsa int DEFAULT 20, p_restante int DEFAULT 50)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1139 ' || p_cat, p_precio, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1139 ' || p_cat)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.pp_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_promo(p_suc bigint, p_regalo bigint, p_disp bigint[],
                                            p_compra numeric DEFAULT 5, p_bonif numeric DEFAULT 2)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico)
  VALUES ('ZZ ensayo 1139', 'bonificacion', pg_temp.pp_hoy() - 1, p_suc, true, p_regalo, false)
  RETURNING id INTO v;
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  SELECT v, d, p_suc FROM unnest(p_disp) d;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v, 'cantidad_compra', p_compra, p_suc), (v, 'cantidad_bonificacion', p_bonif, p_suc);
  RETURN v;
END
$fn$;

-- Un grupo de precio activo con sus productos y escalas [{min, precio}].
-- Devuelve {grupo, escalas: [ids en el orden dado]}.
CREATE OR REPLACE FUNCTION pg_temp.pp_grupo(p_suc bigint, p_prods bigint[], p_escalas jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_g bigint; v_e bigint; v_ids jsonb := '[]'::jsonb; e jsonb;
BEGIN
  INSERT INTO public.grupos_precio (nombre, sucursal_id, activo)
  VALUES ('ZZ ensayo 1139', p_suc, true) RETURNING id INTO v_g;
  INSERT INTO public.grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id)
  SELECT v_g, d, p_suc FROM unnest(p_prods) d;
  FOR e IN SELECT * FROM jsonb_array_elements(p_escalas) LOOP
    INSERT INTO public.grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id)
    VALUES (v_g, (e->>'min')::int, (e->>'precio')::numeric, p_suc) RETURNING id INTO v_e;
    v_ids := v_ids || to_jsonb(v_e);
  END LOOP;
  RETURN jsonb_build_object('grupo', v_g, 'escalas', v_ids);
END
$fn$;

-- Lleva al pasado las filas de audit_logs de un registro. p_campo NULL: la del
-- INSERT. Si no: las de UPDATE o DELETE cuyo old_data->p_campo es p_viejo
-- (un literal json: '21', '0.10', 'true').
CREATE OR REPLACE FUNCTION pg_temp.pp_retro(p_tabla text, p_reg bigint, p_campo text, p_viejo text, p_hace interval)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE
  v_n integer;
BEGIN
  UPDATE public.audit_logs
     SET created_at = now() - p_hace
   WHERE tabla = p_tabla AND registro_id = p_reg::text
     AND CASE WHEN p_campo IS NULL THEN accion = 'INSERT'
              -- jsonb compara numeros por valor: '21' calza con 21.00.
              ELSE accion IN ('UPDATE', 'DELETE') AND old_data->p_campo = p_viejo::jsonb END;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$fn$;

-- Lineas: venta (precio dado) y regalo (precio 0 por defecto).
CREATE OR REPLACE FUNCTION pg_temp.pp_v(p_prod bigint, p_cant int, p_precio numeric DEFAULT 100)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_r(p_prod bigint, p_cant int, p_promo bigint, p_precio numeric DEFAULT 0)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_total(p_items jsonb)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
    FROM jsonb_array_elements(p_items) e;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_alta(p_cli bigint, p_user uuid, p_items jsonb, p_tipo text DEFAULT 'ZZ')
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.pp_como(p_user);
  v_res := public.crear_pedido_completo(
    p_cliente_id => p_cli, p_total => pg_temp.pp_total(p_items), p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1139', p_tipo_factura => p_tipo);
  PERFORM pg_temp.pp_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_edit(p_ped bigint, p_user uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.pp_como(p_user);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.pp_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_rechazo(p_res jsonb, p_patron text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT pg_temp.pp_ok(p_res) AND COALESCE(p_res->'errores'->>0, '') LIKE p_patron;
$fn$;

-- El mismo criterio que rechazoEsTerminal (src/utils/rechazoDeNegocio.ts).
CREATE OR REPLACE FUNCTION pg_temp.pp_terminal(p_msg text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT p_msg IS NOT NULL
     AND p_msg !~* 'stock insuficiente|sin stock|stock disponible'
     AND lower(p_msg) NOT LIKE '%no se pudo determinar la sucursal activa%'
     AND lower(p_msg) NOT LIKE '%jwt expired%'
     AND lower(p_msg) NOT LIKE '%token is expired%'
     AND lower(p_msg) NOT LIKE '%invalid claim%';
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_pedido(p_res jsonb, p_que text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT pg_temp.pp_ok(p_res) THEN
    RAISE EXCEPTION 'no se pudo preparar %: %', p_que, p_res;
  END IF;
  RETURN (p_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_fotos(p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_object_agg(pr.id::text, jsonb_build_object(
           'stock', pr.stock,
           'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                                FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb)))
    FROM public.productos pr WHERE pr.id = ANY(p_prods);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_estado(p_cli bigint, p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'pedidos', (SELECT count(*) FROM public.pedidos WHERE cliente_id = p_cli),
    'lineas', (SELECT count(*) FROM public.pedido_items WHERE producto_id = ANY(p_prods)),
    'fotos', pg_temp.pp_fotos(p_prods));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_estado_ped(p_ped bigint, p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'lineas', (SELECT COALESCE(jsonb_agg(jsonb_build_array(pi.producto_id, pi.cantidad, pi.precio_unitario,
                                                          COALESCE(pi.es_bonificacion, false)) ORDER BY pi.id), '[]'::jsonb)
                 FROM public.pedido_items pi WHERE pi.pedido_id = p_ped),
    'total', (SELECT total FROM public.pedidos WHERE id = p_ped),
    'fotos', pg_temp.pp_fotos(p_prods));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_pat_regalo() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'Un regalo va a precio 0: el regalo de % vino a %' $fn$;
CREATE OR REPLACE FUNCTION pg_temp.pp_pat_piso() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'El precio de % está por debajo del que permite la lista para este pedido (%). Solo un admin puede cargar otro precio.%' $fn$;

-- Un alta que tiene que rechazarse SIN efectos y con un mensaje terminal.
CREATE OR REPLACE FUNCTION pg_temp.pp_alta_rechazada(p_f text[], p_que text, p_cli bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_patron text, p_tipo text DEFAULT 'ZZ')
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.pp_estado(p_cli, p_prods);
  v_res := pg_temp.pp_alta(p_cli, p_user, p_items, p_tipo);
  v_e1 := pg_temp.pp_estado(p_cli, p_prods);
  f := pg_temp.pp_si(f, pg_temp.pp_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.pp_si(f, pg_temp.pp_ok(v_res) OR pg_temp.pp_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.pp_si(f, v_e1 = v_e0, format('%s: el alta rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_alta_pasa(p_f text[], p_que text, p_cli bigint, p_user uuid, p_items jsonb,
                                                p_tipo text DEFAULT 'ZZ')
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := pg_temp.pp_alta(p_cli, p_user, p_items, p_tipo);
  RETURN pg_temp.pp_si(p_f, pg_temp.pp_ok(v_res), format('%s: se esperaba que pase y dio %s', p_que, v_res));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_edit_rechazada(p_f text[], p_que text, p_ped bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_patron text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.pp_estado_ped(p_ped, p_prods);
  v_res := pg_temp.pp_edit(p_ped, p_user, p_items);
  v_e1 := pg_temp.pp_estado_ped(p_ped, p_prods);
  f := pg_temp.pp_si(f, pg_temp.pp_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.pp_si(f, pg_temp.pp_ok(v_res) OR pg_temp.pp_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.pp_si(f, v_e1 = v_e0, format('%s: la edicion rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_edit_pasa(p_f text[], p_que text, p_ped bigint, p_user uuid, p_items jsonb)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := pg_temp.pp_edit(p_ped, p_user, p_items);
  RETURN pg_temp.pp_si(p_f, pg_temp.pp_ok(v_res), format('%s: se esperaba que pase y dio %s', p_que, v_res));
END
$fn$;

-- Regalos de un pedido con precio o subtotal distinto de 0 (tiene que dar 0).
CREATE OR REPLACE FUNCTION pg_temp.pp_regalos_caros(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT count(*) FROM public.pedido_items
   WHERE pedido_id = p_ped AND COALESCE(es_bonificacion, false)
     AND (precio_unitario <> 0 OR subtotal <> 0);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_item(p_ped bigint, p_prod bigint, p_regalo boolean)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false) = p_regalo
   ORDER BY id LIMIT 1;
$fn$;

-- El fixture de la promo: V (venta), X (regalo default), Y (misma categoria
-- que X), promo P (disparador V, 5 -> 2).
CREATE OR REPLACE FUNCTION pg_temp.pp_fix_promo(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint; x bigint; y bigint; p bigint;
  s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
BEGIN
  v := pg_temp.pp_prod(s, a, 'venta');
  x := pg_temp.pp_prod(s, a, 'regalo');
  y := pg_temp.pp_prod(s, a, 'regalo');
  p := pg_temp.pp_promo(s, x, ARRAY[v]);
  RETURN jsonb_build_object('v', v, 'x', x, 'y', y, 'p', p);
END
$fn$;

-- #1178: fija la hora de corte del preventista reescribiendo la constante de
-- actualizar_pedido_items (molde: test-seg-b-predicado-pedidos.sql). Se llama
-- SOLO dentro del subbloque revertido de un caso: no sobrevive al caso, ni con
-- ensayo.continuar = '1'. Corre como duenio de la funcion (postgres).
-- 24:00 deja pasar al preventista a cualquier hora del dia; 00:00 lo rechaza
-- siempre (el encargado y el admin estan exentos del corte).
CREATE OR REPLACE FUNCTION pg_temp.pp_corte(p_corte time)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  c_re CONSTANT text := 'v_hora_corte CONSTANT TIME := TIME ''[^'']*''';
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  IF regexp_count(v_def, c_re) <> 1 THEN
    RAISE EXCEPTION 'ancla del corte (#1178) no encontrada una sola vez en actualizar_pedido_items';
  END IF;
  EXECUTE regexp_replace(v_def, c_re, format('v_hora_corte CONSTANT TIME := TIME %L', p_corte::text));
END
$fn$;

-- ===========================================================================
-- ALTA
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_a1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pp_fix_promo(c); v_res jsonb; v_items jsonb; u uuid;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint := (k->>'p')::bigint;
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
  v_oid text := 'ensayo-1139-' || gen_random_uuid()::text;
BEGIN
  v_items := jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_r(x, 2, p, 5));
  FOREACH u IN ARRAY ARRAY[v_prev, (c->>'enc')::uuid, (c->>'adm')::uuid] LOOP
    CONTINUE WHEN u IS NULL;
    f := pg_temp.pp_alta_rechazada(f, 'regalo a $5 (' || (SELECT rol FROM public.perfiles WHERE id = u) || ')',
                                   v_cli, u, v_items, ARRAY[v, x], pg_temp.pp_pat_regalo());
  END LOOP;

  PERFORM pg_temp.pp_como(v_prev);
  v_res := public.crear_pedido_idempotente(
    p_cliente_id => v_cli, p_total => pg_temp.pp_total(v_items), p_usuario_id => v_prev,
    p_items => v_items, p_notas => 'ensayo 1139', p_offline_id => v_oid);
  PERFORM pg_temp.pp_reset();
  f := pg_temp.pp_si(f, pg_temp.pp_rechazo(v_res, pg_temp.pp_pat_regalo()),
                     format('el replay con un regalo a $5 dio %s', v_res));
  f := pg_temp.pp_si(f, NOT EXISTS (SELECT 1 FROM public.pedidos WHERE offline_id = v_oid),
                     'el offline_id del replay rechazado quedo sellado');

  f := pg_temp.pp_alta_pasa(f, 'regalo a $0 (preventista)', v_cli, v_prev,
                            jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_r(x, 2, p)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_a2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'a2');
  w bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'a2 w');
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  -- El escenario del issue: una linea a lista y otra a $0,01.
  f := pg_temp.pp_alta_rechazada(f, 'preventista a $0,01', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_v(w, 50, 0.01)), ARRAY[v, w], pg_temp.pp_pat_piso());
  f := pg_temp.pp_alta_pasa(f, 'preventista a lista', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_v(w, 5)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_a3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  s1 bigint := pg_temp.pp_prod(s, a, 'a3 s1'); s2 bigint := pg_temp.pp_prod(s, a, 'a3 s2');
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  PERFORM pg_temp.pp_grupo(s, ARRAY[s1, s2], '[{"min": 12, "precio": 80}]');
  f := pg_temp.pp_alta_pasa(f, 'fardo surtido 6 + 6 a la escala', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 6, 80)));
  f := pg_temp.pp_alta_rechazada(f, 'fardo surtido 6 + 5 a la escala', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 5, 80)), ARRAY[s1, s2], pg_temp.pp_pat_piso());
  f := pg_temp.pp_alta_pasa(f, 'fardo surtido 6 + 5 a lista', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6), pg_temp.pp_v(s2, 5)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_a4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'a4');
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.clientes SET descuento_porcentaje = 10 WHERE id = v_cli;
  f := pg_temp.pp_alta_pasa(f, 'descuento general del 10%', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 10, 90)));
  INSERT INTO public.cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
  VALUES (v_cli, ' zz ensayo 1139 a4 ', 0);
  f := pg_temp.pp_alta_rechazada(f, 'categoria al 0% con el precio del general', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 10, 90)), ARRAY[v], pg_temp.pp_pat_piso());
  f := pg_temp.pp_alta_pasa(f, 'categoria al 0% a lista', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 10)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- VENTANA
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_w1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'w1', 0);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 6550 WHERE id = v;
  f := pg_temp.pp_alta_rechazada(f, '0 -> 6550 y venta a $0,01', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 0.01)), ARRAY[v], pg_temp.pp_pat_piso());
  f := pg_temp.pp_alta_pasa(f, '0 -> 6550 y venta a $6550', v_cli, v_prev, jsonb_build_array(pg_temp.pp_v(v, 2, 6550)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_w2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'w2', 21);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 0.10 WHERE id = v;
  UPDATE public.productos SET precio = 2158 WHERE id = v;
  PERFORM pg_temp.pp_retro('productos', v, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '21', interval '65 minutes');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '0.10', interval '60 minutes');
  f := pg_temp.pp_alta_rechazada(f, '0,10 vigente 5 minutos y venta a $0,10', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 0.10)), ARRAY[v], pg_temp.pp_pat_piso());
  f := pg_temp.pp_alta_rechazada(f, 'el precio de antes del tipeo ($21)', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 21)), ARRAY[v], pg_temp.pp_pat_piso());
  f := pg_temp.pp_alta_pasa(f, 'a $2158', v_cli, v_prev, jsonb_build_array(pg_temp.pp_v(v, 2, 2158)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_w3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'w3', 4450);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 4570 WHERE id = v;
  PERFORM pg_temp.pp_retro('productos', v, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '4450', interval '1 hour');
  f := pg_temp.pp_alta_pasa(f, 'replay a $4450 una hora despues de la suba', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4450)));
  f := pg_temp.pp_alta_rechazada(f, 'a $4440 (debajo del anterior)', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4440)), ARRAY[v], pg_temp.pp_pat_piso());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_w4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'w4', 4450);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 4570 WHERE id = v;
  UPDATE public.productos SET precio = 4700 WHERE id = v;
  PERFORM pg_temp.pp_retro('productos', v, NULL, NULL, interval '5 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '4450', interval '3 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '4570', interval '1 hour');
  f := pg_temp.pp_alta_pasa(f, 'dos subas: a $4570 (el anterior)', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4570)));
  f := pg_temp.pp_alta_rechazada(f, 'dos subas: a $4450 (el de antes del anterior)', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4450)), ARRAY[v], pg_temp.pp_pat_piso());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_w5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; v bigint := pg_temp.pp_prod(s, (c->>'adm')::uuid, 'w5', 4450);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 4570 WHERE id = v;
  PERFORM pg_temp.pp_retro('productos', v, NULL, NULL, interval '40 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '4450', interval '30 hours');
  UPDATE public.politicas_comerciales SET ventana_precio_anterior_horas = 24 WHERE sucursal_id = s;
  f := pg_temp.pp_alta_rechazada(f, 'suba hace 30 h con ventana de 24', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4450)), ARRAY[v], pg_temp.pp_pat_piso());
  INSERT INTO public.politicas_comerciales (sucursal_id, ventana_precio_anterior_horas)
  VALUES (s, 48)
  ON CONFLICT (sucursal_id) DO UPDATE SET ventana_precio_anterior_horas = 48;
  f := pg_temp.pp_alta_pasa(f, 'suba hace 30 h con ventana de 48', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4450)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- ESCALAS
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_s1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  s1 bigint := pg_temp.pp_prod(s, a, 's1 a'); s2 bigint := pg_temp.pp_prod(s, a, 's1 b');
  g jsonb; e bigint; v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  g := pg_temp.pp_grupo(s, ARRAY[s1, s2], '[{"min": 12, "precio": 80}]');
  e := (g->'escalas'->>0)::bigint;
  UPDATE public.grupo_precio_escalas SET precio_unitario = 85 WHERE id = e;
  PERFORM pg_temp.pp_retro('grupo_precio_escalas', e, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('grupo_precio_escalas', e, 'precio_unitario', '80', interval '1 hour');
  f := pg_temp.pp_alta_pasa(f, 'escala subida en el lugar: el precio viejo', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 6, 80)));
  f := pg_temp.pp_alta_rechazada(f, 'escala subida en el lugar: debajo del viejo', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 78), pg_temp.pp_v(s2, 6, 78)), ARRAY[s1, s2], pg_temp.pp_pat_piso());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_s2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  s1 bigint := pg_temp.pp_prod(s, a, 's2 a'); s2 bigint := pg_temp.pp_prod(s, a, 's2 b');
  g jsonb; e bigint; v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  g := pg_temp.pp_grupo(s, ARRAY[s1, s2], '[{"min": 12, "precio": 80}]');
  e := (g->'escalas'->>0)::bigint;
  -- La reconciliacion de updateGrupoPrecio: el umbral nuevo es otra fila.
  DELETE FROM public.grupo_precio_escalas WHERE id = e;
  INSERT INTO public.grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id)
  VALUES ((g->>'grupo')::bigint, 24, 80, s);
  PERFORM pg_temp.pp_retro('grupo_precio_escalas', e, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('grupo_precio_escalas', e, 'cantidad_minima', '12', interval '1 hour');
  f := pg_temp.pp_alta_pasa(f, 'umbral 12 -> 24 por DELETE + INSERT: 12 al precio viejo', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 6, 80)));
  f := pg_temp.pp_alta_rechazada(f, 'umbral 12 -> 24: 11 al precio de escala', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 5, 80)), ARRAY[s1, s2], pg_temp.pp_pat_piso());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_s3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  s1 bigint := pg_temp.pp_prod(s, a, 's3 a'); s2 bigint := pg_temp.pp_prod(s, a, 's3 b');
  g jsonb; e bigint; v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  g := pg_temp.pp_grupo(s, ARRAY[s1, s2], '[{"min": 12, "precio": 80}]');
  e := (g->'escalas'->>0)::bigint;
  UPDATE public.grupo_precio_escalas SET activo = false WHERE id = e;
  PERFORM pg_temp.pp_retro('grupo_precio_escalas', e, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('grupo_precio_escalas', e, 'activo', 'true', interval '1 hour');
  f := pg_temp.pp_alta_pasa(f, 'escala desactivada hace una hora: replay a su precio', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 6, 80)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_s4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  s1 bigint := pg_temp.pp_prod(s, a, 's4 a'); s2 bigint := pg_temp.pp_prod(s, a, 's4 b');
  t1 bigint := pg_temp.pp_prod(s, a, 's4 c'); t2 bigint := pg_temp.pp_prod(s, a, 's4 d');
  g1 jsonb; g2 jsonb; v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  g1 := pg_temp.pp_grupo(s, ARRAY[s1, s2], '[{"min": 12, "precio": 80}]');
  g2 := pg_temp.pp_grupo(s, ARRAY[t1, t2], '[{"min": 12, "precio": 80}]');
  UPDATE public.grupos_precio SET activo = false WHERE id = (g1->>'grupo')::bigint;
  f := pg_temp.pp_alta_rechazada(f, 'grupo desactivado (no se cubre)', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 6, 80)), ARRAY[s1, s2], pg_temp.pp_pat_piso());
  DELETE FROM public.grupo_precio_productos WHERE grupo_precio_id = (g2->>'grupo')::bigint AND producto_id = t1;
  f := pg_temp.pp_alta_rechazada(f, 'producto sacado del grupo (no se cubre)', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(t1, 6, 80), pg_temp.pp_v(t2, 6, 80)), ARRAY[t1, t2], pg_temp.pp_pat_piso());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- ROLES
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_r1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'r1');
  v_cli bigint := (c->>'cli')::bigint; v_cli2 bigint := (c->>'cli2')::bigint;
  v_vb jsonb; u uuid;
BEGIN
  IF c->>'enc' IS NOT NULL THEN
    f := pg_temp.pp_alta_rechazada(f, 'encargado a $0,01', v_cli, (c->>'enc')::uuid,
           jsonb_build_array(pg_temp.pp_v(v, 2, 0.01)), ARRAY[v], pg_temp.pp_pat_piso());
  END IF;
  f := pg_temp.pp_alta_pasa(f, 'admin a $0,01', v_cli, (c->>'adm')::uuid, jsonb_build_array(pg_temp.pp_v(v, 2, 0.01)));
  -- El VB lo precia el server: el preventista lo manda a 0.
  UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = v_cli2;
  v_vb := pg_temp.pp_alta(v_cli2, (c->>'prev')::uuid, jsonb_build_array(pg_temp.pp_v(v, 2, 0)), 'VB');
  f := pg_temp.pp_si(f, pg_temp.pp_ok(v_vb), format('VB de un preventista: se esperaba que pase y dio %s', v_vb));
  -- La edicion no necesita eximir al VB: actualizar_pedido_items lo rechaza
  -- antes de la guarda del piso, para cualquier rol (mig 3XA, N9). Si alguien
  -- saca ese rechazo, la guarda del piso tiene que aprender a saltear el VB.
  IF pg_temp.pp_ok(v_vb) THEN
    FOREACH u IN ARRAY ARRAY[(c->>'prev')::uuid, (c->>'enc')::uuid] LOOP
      CONTINUE WHEN u IS NULL;
      f := pg_temp.pp_edit_rechazada(f, 'editar el VB (' || (SELECT rol FROM public.perfiles WHERE id = u) || ')',
                                     (v_vb->>'pedido_id')::bigint, u, jsonb_build_array(pg_temp.pp_v(v, 3, 0)),
                                     ARRAY[v], 'Un vale blanco no se edita%');
    END LOOP;
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- EDICION
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_e1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'e1');
  v_ed uuid := (c->>'ed')::uuid; v_ped bigint; u uuid;
BEGIN
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, v_ed, jsonb_build_array(pg_temp.pp_v(v, 10))),
                             'el alta de E1');
  FOREACH u IN ARRAY ARRAY[v_ed, (c->>'enc')::uuid] LOOP
    CONTINUE WHEN u IS NULL;
    f := pg_temp.pp_edit_rechazada(f, 'baja de precio (' || (SELECT rol FROM public.perfiles WHERE id = u) || ')',
                                   v_ped, u, jsonb_build_array(pg_temp.pp_v(v, 10, 90)), ARRAY[v], pg_temp.pp_pat_piso());
  END LOOP;
  f := pg_temp.pp_edit_pasa(f, 'subir la cantidad a lista', v_ped, v_ed, jsonb_build_array(pg_temp.pp_v(v, 12)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_e2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  s1 bigint := pg_temp.pp_prod(s, a, 'e2 a', 100, 20, 80); s2 bigint := pg_temp.pp_prod(s, a, 'e2 b', 100, 20, 80);
  v_ed uuid := (c->>'ed')::uuid; v_ped bigint; v_res jsonb; v_manual boolean;
BEGIN
  PERFORM pg_temp.pp_grupo(s, ARRAY[s1, s2], '[{"min": 40, "precio": 80}]');
  FOREACH v_manual IN ARRAY ARRAY[true, false] LOOP
    v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, v_ed,
               jsonb_build_array(pg_temp.pp_v(s1, 25, 80), pg_temp.pp_v(s2, 25, 80))), 'el alta de 50 fardos');
    IF v_manual THEN
      PERFORM pg_temp.pp_como(v_ed);
      v_res := public.registrar_origen_precio_items(v_ped, jsonb_build_array(
                 jsonb_build_object('producto_id', s1, 'origen_precio', 'manual'),
                 jsonb_build_object('producto_id', s2, 'origen_precio', 'manual')), v_ed);
      PERFORM pg_temp.pp_reset();
    END IF;
    f := pg_temp.pp_edit_rechazada(f, '50 fardos a 5 al precio de escala' || CASE WHEN v_manual THEN ' (origen manual)' ELSE '' END,
                                   v_ped, v_ed, jsonb_build_array(pg_temp.pp_v(s1, 3, 80), pg_temp.pp_v(s2, 2, 80)),
                                   ARRAY[s1, s2], pg_temp.pp_pat_piso());
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_e3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  s1 bigint := pg_temp.pp_prod(s, a, 'e3 a'); s2 bigint := pg_temp.pp_prod(s, a, 'e3 b');
  v bigint := pg_temp.pp_prod(s, a, 'e3 v'); t bigint := pg_temp.pp_prod(s, a, 'e3 t');
  v_ed uuid := (c->>'ed')::uuid; v_ped bigint; v_res jsonb;
BEGIN
  PERFORM pg_temp.pp_grupo(s, ARRAY[s1, s2], '[{"min": 12, "precio": 80}]');
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, v_ed,
             jsonb_build_array(pg_temp.pp_v(s1, 6, 80), pg_temp.pp_v(s2, 6, 80), pg_temp.pp_v(v, 10))), 'el alta de E3');
  -- El admin pone precios bajo el piso (exento).
  v_res := pg_temp.pp_edit(v_ped, a, jsonb_build_array(pg_temp.pp_v(s1, 6, 70), pg_temp.pp_v(s2, 6, 80), pg_temp.pp_v(v, 10, 50)));
  IF NOT pg_temp.pp_ok(v_res) THEN
    RAISE EXCEPTION 'el admin no pudo poner sus precios: %', v_res;
  END IF;
  f := pg_temp.pp_edit_pasa(f, 'agregar otro producto conserva los precios del admin', v_ped, v_ed,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 70), pg_temp.pp_v(s2, 6, 80), pg_temp.pp_v(v, 10, 50), pg_temp.pp_v(t, 1)));
  f := pg_temp.pp_edit_rechazada(f, 'achicar el grupo con el precio del admin', v_ped, v_ed,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 70), pg_temp.pp_v(s2, 5, 80), pg_temp.pp_v(v, 10, 50), pg_temp.pp_v(t, 1)),
         ARRAY[s1, s2, v, t], pg_temp.pp_pat_piso());
  f := pg_temp.pp_edit_pasa(f, 'bajar una linea sin grupo a precio de admin', v_ped, v_ed,
         jsonb_build_array(pg_temp.pp_v(s1, 6, 70), pg_temp.pp_v(s2, 6, 80), pg_temp.pp_v(v, 5, 50), pg_temp.pp_v(t, 1)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_e4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  v bigint := pg_temp.pp_prod(s, a, 'e4 v'); t bigint := pg_temp.pp_prod(s, a, 'e4 t');
  v_ed uuid := (c->>'ed')::uuid; v_ped bigint;
BEGIN
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, v_ed, jsonb_build_array(pg_temp.pp_v(v, 10))),
                             'el alta de E4');
  f := pg_temp.pp_edit_rechazada(f, 'linea nueva bajo el piso', v_ped, v_ed,
         jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_v(t, 2, 50)), ARRAY[v, t], pg_temp.pp_pat_piso());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_e5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pp_fix_promo(c); v_ed uuid := (c->>'ed')::uuid; v_ped bigint; u uuid;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint := (k->>'p')::bigint;
BEGIN
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, v_ed,
             jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_r(x, 2, p))), 'el alta de E5');
  FOREACH u IN ARRAY ARRAY[v_ed, (c->>'adm')::uuid] LOOP
    f := pg_temp.pp_edit_rechazada(f, 'regalo a $3 (' || (SELECT rol FROM public.perfiles WHERE id = u) || ')',
                                   v_ped, u, jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_r(x, 2, p, 3)),
                                   ARRAY[v, x], pg_temp.pp_pat_regalo());
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_e6(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 'e6');
  v_ped bigint;
BEGIN
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, (c->>'ed')::uuid,
             jsonb_build_array(pg_temp.pp_v(v, 10))), 'el alta de E6');
  f := pg_temp.pp_edit_pasa(f, 'el admin edita a $0,01', v_ped, (c->>'adm')::uuid,
         jsonb_build_array(pg_temp.pp_v(v, 10, 0.01)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- CHECK Y GATE
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_c1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pp_fix_promo(c); v_ped bigint; v_estado text;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint := (k->>'p')::bigint;
  s bigint := (c->>'suc')::bigint;
BEGIN
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, (c->>'adm')::uuid,
             jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_r(x, 2, p))), 'el alta de C1');
  v_estado := NULL;
  BEGIN
    UPDATE public.pedido_items SET precio_unitario = 5, subtotal = 10
     WHERE pedido_id = v_ped AND COALESCE(es_bonificacion, false);
  EXCEPTION WHEN check_violation THEN v_estado := SQLSTATE;
  END;
  f := pg_temp.pp_si(f, v_estado = '23514', 'el UPDATE directo de un regalo a $5 no dio 23514');
  v_estado := NULL;
  BEGIN
    INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                     sucursal_id, es_bonificacion, promocion_id)
    VALUES (v_ped, x, 1, 5, 5, s, true, p);
  EXCEPTION WHEN check_violation THEN v_estado := SQLSTATE;
  END;
  f := pg_temp.pp_si(f, v_estado = '23514', 'el INSERT directo de un regalo a $5 no dio 23514');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_c2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pp_fix_promo(c); v_ped bigint; v_res jsonb; v_salv bigint;
  v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; y bigint := (k->>'y')::bigint;
  p bigint := (k->>'p')::bigint; a uuid := (c->>'adm')::uuid; v_items jsonb;
BEGIN
  v_items := jsonb_build_array(pg_temp.pp_v(v, 10), pg_temp.pp_r(x, 4, p));

  -- sustituir
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, a, v_items), 'el alta de C2 sustituir');
  PERFORM pg_temp.pp_como(a);
  v_res := public.sustituir_regalo_pedido(pg_temp.pp_item(v_ped, x, true), y, 4, 'ensayo 1139', NULL, NULL);
  PERFORM pg_temp.pp_reset();
  f := pg_temp.pp_si(f, pg_temp.pp_ok(v_res), format('sustituir_regalo_pedido dio %s', v_res));
  f := pg_temp.pp_si(f, pg_temp.pp_regalos_caros(v_ped) = 0, 'sustituir dejo un regalo con precio');

  -- dividir
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, a, v_items), 'el alta de C2 dividir');
  PERFORM pg_temp.pp_como(a);
  v_res := public.dividir_regalo_pedido(pg_temp.pp_item(v_ped, x, true),
             jsonb_build_array(jsonb_build_object('producto_id', x, 'cantidad', 2),
                               jsonb_build_object('producto_id', y, 'cantidad', 2)), 'ensayo 1139');
  PERFORM pg_temp.pp_reset();
  f := pg_temp.pp_si(f, pg_temp.pp_ok(v_res), format('dividir_regalo_pedido dio %s', v_res));
  f := pg_temp.pp_si(f, pg_temp.pp_regalos_caros(v_ped) = 0, 'dividir dejo un regalo con precio');

  -- salvedad sobre el regalo y su anulacion
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, a, v_items), 'el alta de C2 salvedad');
  PERFORM pg_temp.pp_como(a);
  v_res := public.registrar_salvedad(v_ped, pg_temp.pp_item(v_ped, x, true), 1, 'producto_danado',
                                     'ensayo 1139: salvedad sobre el regalo', NULL, true, NULL);
  PERFORM pg_temp.pp_reset();
  f := pg_temp.pp_si(f, pg_temp.pp_ok(v_res), format('registrar_salvedad sobre el regalo dio %s', v_res));
  f := pg_temp.pp_si(f, pg_temp.pp_regalos_caros(v_ped) = 0, 'la salvedad dejo un regalo con precio');
  v_salv := (v_res->>'salvedad_id')::bigint;
  IF v_salv IS NOT NULL THEN
    PERFORM pg_temp.pp_como(a);
    v_res := public.anular_salvedad(v_salv, 'ensayo 1139');
    PERFORM pg_temp.pp_reset();
    -- Hoy anular una salvedad sobre un regalo no existe (la funcion lo
    -- rechaza y pide corregir a mano): vale ese rechazo o que pase, pero no
    -- un 23514 ni un regalo con precio.
    f := pg_temp.pp_si(f, pg_temp.pp_ok(v_res) OR COALESCE(v_res->>'error', '') LIKE '%sobre un regalo de promocion%',
                       format('anular_salvedad del regalo dio %s', v_res));
    f := pg_temp.pp_si(f, pg_temp.pp_regalos_caros(v_ped) = 0, 'anular la salvedad dejo un regalo con precio');
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_c3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_chk jsonb; v_n bigint;
BEGIN
  SELECT x INTO v_chk FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x WHERE x->>'id' = 'PRECIO-A';
  f := pg_temp.pp_si(f, v_chk IS NOT NULL AND (v_chk->>'violaciones')::bigint = 0 AND v_chk->>'severidad' = 'high',
                     format('PRECIO-A no esta en high y en 0: %s', v_chk));
  EXECUTE $def$
    CREATE FUNCTION public.zz_ensayo_1139_sin_piso(p_ped bigint) RETURNS void LANGUAGE plpgsql AS $b$
    BEGIN
      INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal)
      VALUES (p_ped, 0, 1, 1, 1);
    END $b$
  $def$;
  EXECUTE 'SELECT public.auditoria_funciones_pedido_items_sin_piso()' INTO v_n;
  f := pg_temp.pp_si(f, v_n = 1, format('una funcion que inserta pedido_items sin el piso dejo PRECIO-A en %s', v_n));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1139$
DECLARE
  v_admin   uuid;
  v_prev    uuid;
  v_enc     uuid;
  v_ed      uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_cli2    bigint;
  v_ctx     jsonb;
  v_caso    text;
  v_pasada  text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
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
  -- Clientes que el preventista puede operar y SIN descuentos (los casos que
  -- los necesitan los ponen en su subbloque).
  SELECT id INTO v_cliente FROM clientes cl
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
     AND preventista_id IS NULL AND NOT COALESCE(reservado_admin, false)
     AND COALESCE(descuento_porcentaje, 0) = 0
     AND NOT EXISTS (SELECT 1 FROM cliente_descuentos_categoria d WHERE d.cliente_id = cl.id)
   ORDER BY id LIMIT 1;
  SELECT id INTO v_cli2 FROM clientes cl
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
     AND preventista_id IS NULL AND NOT COALESCE(reservado_admin, false) AND id <> v_cliente
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_prev IS NULL OR v_cliente IS NULL OR v_cli2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hace falta una sucursal activa con un admin, un preventista y dos clientes sin asignar';
  END IF;

  -- #1178: el editor no-admin es siempre el preventista (corte fijado en
  -- 24:00 por caso); la pasada /enc repite los casos de edicion con el
  -- encargado y el corte en 00:00.
  v_ed := v_prev;

  v_ctx := jsonb_build_object('suc', v_suc, 'adm', v_admin, 'prev', v_prev, 'enc', v_enc, 'ed', v_ed,
                              'cli', v_cliente, 'cli2', v_cli2);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['a1', 'a2', 'a3', 'a4', 'w1', 'w2', 'w3', 'w4', 'w5',
                                's1', 's2', 's3', 's4', 'r1',
                                'e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'c1', 'c2', 'c3'] LOOP
    FOREACH v_pasada IN ARRAY CASE WHEN v_caso LIKE 'e%' AND v_enc IS NOT NULL
                                   THEN ARRAY['', '/enc'] ELSE ARRAY[''] END LOOP
      v_out := NULL;
      BEGIN
        PERFORM pg_temp.pp_reset();
        PERFORM pg_temp.pp_como(v_admin);
        IF v_caso LIKE 'e%' THEN
          -- #1178: el preventista edita con el corte en 24:00; el encargado, con
          -- el corte en 00:00 (esta exento).
          PERFORM pg_temp.pp_corte(CASE v_pasada WHEN '' THEN TIME '24:00' ELSE TIME '00:00' END);
        END IF;
        EXECUTE format('SELECT pg_temp.pp_caso_%s($1)', v_caso) INTO v_out
          USING CASE v_pasada WHEN '' THEN v_ctx ELSE v_ctx || jsonb_build_object('ed', v_enc) END;
        RAISE EXCEPTION USING ERRCODE = 'ZZ001';
      EXCEPTION
        WHEN SQLSTATE 'ZZ001' THEN NULL;
        WHEN OTHERS THEN v_fallas := v_fallas || format('%s%s · error: %s', upper(v_caso), v_pasada, SQLERRM);
      END;
      IF v_out IS NOT NULL THEN
        v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || v_pasada || ' · ' || left(x, 220)
                                        FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
      END IF;
    END LOOP;
  END LOOP;

  v_notas := v_notas || CASE WHEN v_enc IS NULL
                             THEN 'sin encargado en la sucursal: sin la pasada /enc de E1-E6'
                             ELSE 'E1-E6 con el preventista (corte 24:00) y con el encargado (/enc, corte 00:00)' END;

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
$ensayo1139$;
