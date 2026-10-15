-- Ensayo de #1152, #1153 y #1154: la fecha con que se mide la promo al editar,
-- el codigo del rechazo de regalo para el replay offline, y la revalidacion de
-- la promo cuando el bot confirma.
--
-- Regla (decision del dueno, 2026-10-14), para quien no es admin:
--   #1152 el alta y la edicion miden la vigencia en LEAST(fecha del pedido,
--         hoy) o en hoy (hora argentina): una fecha futura no adelanta promos.
--   #1153 el rechazo de regalo de crear_pedido_completo lleva
--         codigo = 'regalo_fuera_de_promo'; los demas rechazos no. El rechazo
--         no sella offline_id: el reintento sin el regalo usa la misma clave.
--   #1154 crear_pedido_completo_bot revalida con regalo_fuera_de_promo antes
--         de escribir; el rechazo va por 'error' y no consume la confirmacion.
--         El admin queda exento, como en la app.
--
-- Fixture: V (venta), X (cat A, regalo default). Las promos nacen activas,
-- con fecha_inicio = ayer (hora argentina) y sin fecha_fin, salvo que el caso
-- diga otra cosa.
--
-- Edicion (el preventista con el corte de las 15:30 fijado en 24:00, y cada
-- caso repetido con el encargado, corte 00:00, si la sucursal tiene uno:
-- #1178; no depende de la hora de la corrida):
--   F1  pedido con fecha hoy+3; la edicion agrega el regalo de una promo que
--       empieza manana -> rechazo SIN efectos, y el mensaje dice
--       "editado el <hoy>". (Antes de la migracion pasaba.)
--   F2  la misma edicion con una promo que empieza hoy -> pasa (control).
--   F3  pedido con fecha anteayer y la promo termino ayer -> pasa (control,
--       es el VE3 de 1136-1137).
--
-- Replay offline (crear_pedido_idempotente, preventista):
--   R1  offline_id K y la promo inactiva -> success = false,
--       codigo = 'regalo_fuera_de_promo', rechazo terminal y K sin sellar.
--   R2  la misma K con los items sin las lineas de regalo -> success = true,
--       el pedido queda sellado con K y su total es el de R1 (el regalo va a
--       precio 0).
--   R3  compra minima por encima del total (monto_minimo_pedido se sube dentro
--       del subbloque: en prod vale 0) -> success = false, mensaje de compra
--       minima y SIN codigo.
--
-- Bot (crear_pedido_completo_bot, con una confirmacion armada como la deja
-- previsualizar_pedido.ts):
--   B1  preventista, la promo se apaga antes de confirmar -> success = false,
--       'error' menciona 'desactivada', no hay pedido nuevo, consumido = false
--       y el stock no cambia. (Antes de la migracion creaba el pedido.)
--   B2  preventista, la promo activa y el regalo dentro del tope -> pasa.
--   B3  preventista, la promo termino ayer -> success = false, 'error' dice
--       'rige' y la fecha de fin, consumido = false.
--   B4  admin con la promo inactiva -> pasa (exencion).
--
--   G   anon y authenticated sin EXECUTE sobre regalo_fuera_de_promo y el bot;
--       authenticated con EXECUTE sobre crear_pedido_completo e idempotente.
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenarlo con otra
-- sentencia en la misma transaccion) y queda en el GUC ensayo.resultado.
--
--   psql "$DATABASE_URL" -f scripts/test-promo-fecha-replay-bot-1152-1153-1154.sql

CREATE OR REPLACE FUNCTION pg_temp.pf_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- set_config es por transaccion (CLAUDE.md): entre llamada y llamada se
-- limpian los GUCs de stock, asi una RPC no hereda la etiqueta de otra.
CREATE OR REPLACE FUNCTION pg_temp.pf_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_como(p_user uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
END
$fn$;

-- Stock, lotes y bolsa de unos productos.
CREATE OR REPLACE FUNCTION pg_temp.pf_fotos(p_prods bigint[])
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
CREATE OR REPLACE FUNCTION pg_temp.pf_prod(p_suc bigint, p_admin uuid, p_cat text, p_bolsa int DEFAULT 20, p_restante int DEFAULT 50)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1152 ' || p_cat, 100, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1152 ' || p_cat)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.pf_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

-- Una promo de bonificacion con su regalo default, sus disparadores y sus
-- reglas. p_o: nombre, modo ('acumulable' | 'excluyente'), activo, inicio,
-- fin, prioridad. Por defecto: acumulable, activa, desde ayer, sin fin.
CREATE OR REPLACE FUNCTION pg_temp.pf_promo(p_suc bigint, p_regalo bigint, p_disp bigint[],
                                            p_compra numeric, p_bonif numeric, p_o jsonb DEFAULT '{}')
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, fecha_fin, activo, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, modo_exclusion, prioridad)
  VALUES (COALESCE(p_o->>'nombre', 'ZZ ensayo 1152'), 'bonificacion',
          COALESCE((p_o->>'inicio')::date, pg_temp.pf_hoy() - 1), (p_o->>'fin')::date,
          COALESCE((p_o->>'activo')::boolean, true), p_suc, true, p_regalo, false,
          COALESCE(p_o->>'modo', 'acumulable'), COALESCE((p_o->>'prioridad')::int, 0))
  RETURNING id INTO v;
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  SELECT v, d, p_suc FROM unnest(p_disp) d;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v, 'cantidad_compra', p_compra, p_suc), (v, 'cantidad_bonificacion', p_bonif, p_suc);
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_total(p_items jsonb)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
    FROM jsonb_array_elements(p_items) e;
$fn$;

-- El alta como p_user, con p_fecha opcional. No aborta.
CREATE OR REPLACE FUNCTION pg_temp.pf_alta(p_cli bigint, p_user uuid, p_items jsonb, p_fecha date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.pf_como(p_user);
  v_res := public.crear_pedido_completo(
    p_cliente_id => p_cli, p_total => pg_temp.pf_total(p_items), p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1152', p_fecha => p_fecha);
  PERFORM pg_temp.pf_reset();
  RETURN v_res;
END
$fn$;

-- El replay offline como p_user, con su clave. No aborta.
CREATE OR REPLACE FUNCTION pg_temp.pf_replay(p_cli bigint, p_user uuid, p_items jsonb, p_oid text, p_fecha date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.pf_como(p_user);
  v_res := public.crear_pedido_idempotente(
    p_cliente_id => p_cli, p_total => pg_temp.pf_total(p_items), p_usuario_id => p_user,
    p_items => p_items, p_notas => 'ensayo 1153', p_fecha => p_fecha, p_offline_id => p_oid);
  PERFORM pg_temp.pf_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_edit(p_ped bigint, p_user uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.pf_como(p_user);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.pf_reset();
  RETURN v_res;
END
$fn$;

-- Una confirmacion del bot como la deja previsualizar_pedido.ts (el RPC lee
-- producto_id, cantidad, precio_unitario, es_bonificacion y promocion_id), y
-- la confirmacion por el boton.
CREATE OR REPLACE FUNCTION pg_temp.pf_pendiente(p_user uuid, p_suc bigint, p_cli bigint, p_items jsonb)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
  v uuid;
BEGIN
  INSERT INTO public.bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total)
  VALUES (p_user, p_suc, p_cli,
          (SELECT jsonb_agg(e || jsonb_build_object('es_bonificacion', COALESCE((e->>'es_bonificacion')::boolean, false),
                                                    'promocion_id', e->'promocion_id'))
             FROM jsonb_array_elements(p_items) e),
          pg_temp.pf_total(p_items))
  RETURNING id INTO v;
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_bot(p_user uuid, p_conf uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo_bot(p_user, p_conf);
  PERFORM pg_temp.pf_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

-- Rechazo (success = false) con un primer error que calza con p_patron (LIKE).
CREATE OR REPLACE FUNCTION pg_temp.pf_rechazo(p_res jsonb, p_patron text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT pg_temp.pf_ok(p_res) AND COALESCE(p_res->'errores'->>0, '') LIKE p_patron;
$fn$;

-- El mismo criterio que rechazoEsTerminal (src/utils/rechazoDeNegocio.ts).
CREATE OR REPLACE FUNCTION pg_temp.pf_terminal(p_msg text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT p_msg IS NOT NULL
     AND p_msg !~* 'stock insuficiente|sin stock|stock disponible'
     AND lower(p_msg) NOT LIKE '%no se pudo determinar la sucursal activa%'
     AND lower(p_msg) NOT LIKE '%jwt expired%'
     AND lower(p_msg) NOT LIKE '%token is expired%'
     AND lower(p_msg) NOT LIKE '%invalid claim%';
$fn$;

-- Lo que un alta rechazada (app o bot) no puede haber tocado.
CREATE OR REPLACE FUNCTION pg_temp.pf_estado(p_cli bigint, p_prods bigint[], p_promos bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'pedidos', (SELECT count(*) FROM public.pedidos WHERE cliente_id = p_cli),
    'lineas', (SELECT count(*) FROM public.pedido_items WHERE producto_id = ANY(p_prods)),
    'fotos', pg_temp.pf_fotos(p_prods),
    'usos', (SELECT jsonb_agg(jsonb_build_array(id, usos_pendientes) ORDER BY id)
               FROM public.promociones WHERE id = ANY(p_promos)),
    'acum', (SELECT COALESCE(jsonb_agg(jsonb_build_array(id, producto_regalo_id, usos_pendientes) ORDER BY id), '[]'::jsonb)
               FROM public.promo_acumuladores WHERE promocion_id = ANY(p_promos)));
$fn$;

-- Lo que una edicion rechazada no puede haber tocado.
CREATE OR REPLACE FUNCTION pg_temp.pf_estado_ped(p_ped bigint, p_prods bigint[], p_promos bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'lineas', (SELECT COALESCE(jsonb_agg(jsonb_build_array(pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false),
                                                          pi.promocion_id, pi.regalo_cadena_id) ORDER BY pi.id), '[]'::jsonb)
                 FROM public.pedido_items pi WHERE pi.pedido_id = p_ped),
    'total', (SELECT total FROM public.pedidos WHERE id = p_ped),
    'fotos', pg_temp.pf_fotos(p_prods),
    'usos', (SELECT jsonb_agg(jsonb_build_array(id, usos_pendientes) ORDER BY id)
               FROM public.promociones WHERE id = ANY(p_promos)));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_pedido(p_res jsonb, p_que text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT pg_temp.pf_ok(p_res) THEN
    RAISE EXCEPTION 'no se pudo preparar %: %', p_que, p_res;
  END IF;
  RETURN (p_res->>'pedido_id')::bigint;
END
$fn$;

-- Una edicion que tiene que rechazarse SIN efectos.
CREATE OR REPLACE FUNCTION pg_temp.pf_edit_rechazada(p_f text[], p_que text, p_ped bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_promos bigint[], p_patron text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.pf_estado_ped(p_ped, p_prods, p_promos);
  v_res := pg_temp.pf_edit(p_ped, p_user, p_items);
  v_e1 := pg_temp.pf_estado_ped(p_ped, p_prods, p_promos);
  f := pg_temp.pf_si(f, pg_temp.pf_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.pf_si(f, pg_temp.pf_ok(v_res) OR pg_temp.pf_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.pf_si(f, v_e1 = v_e0, format('%s: la edicion rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

-- Una confirmacion del bot que tiene que rechazarse SIN efectos ni consumirse.
CREATE OR REPLACE FUNCTION pg_temp.pf_bot_rechazado(p_f text[], p_que text, p_user uuid, p_conf uuid, p_cli bigint,
                                                    p_prods bigint[], p_promos bigint[], p_patron text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.pf_estado(p_cli, p_prods, p_promos);
  v_res := pg_temp.pf_bot(p_user, p_conf);
  v_e1 := pg_temp.pf_estado(p_cli, p_prods, p_promos);
  f := pg_temp.pf_si(f, NOT pg_temp.pf_ok(v_res) AND COALESCE(v_res->>'error', '') LIKE p_patron,
                     format('%s: se esperaba el error "%s" y dio %s', p_que, p_patron, v_res));
  -- 'error' y no 'errores': crear_pedido.ts antepone "Stock insuficiente:" a los errores.
  f := pg_temp.pf_si(f, v_res->'errores' IS NULL, format('%s: el rechazo vino por errores: %s', p_que, v_res));
  f := pg_temp.pf_si(f, v_e1 = v_e0, format('%s: el rechazo dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  f := pg_temp.pf_si(f, NOT (SELECT consumido FROM public.bot_pedidos_pendientes WHERE id = p_conf),
                     format('%s: la confirmacion quedo consumida', p_que));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_fix(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
BEGIN
  RETURN jsonb_build_object('v', pg_temp.pf_prod(s, a, 'venta'), 'x', pg_temp.pf_prod(s, a, 'cat A'));
END
$fn$;

-- #1178: fija la hora de corte del preventista reescribiendo la constante de
-- actualizar_pedido_items (molde: test-seg-b-predicado-pedidos.sql). Se llama
-- SOLO dentro del subbloque revertido de un caso: no sobrevive al caso, ni con
-- ensayo.continuar = '1'. Corre como duenio de la funcion (postgres).
-- 24:00 deja pasar al preventista a cualquier hora del dia; 00:00 lo rechaza
-- siempre (el encargado y el admin estan exentos del corte).
CREATE OR REPLACE FUNCTION pg_temp.pf_corte(p_corte time)
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
-- #1152 LA EDICION MIDE EN LEAST(FECHA, HOY)
-- ===========================================================================
-- c->>'ed' es el editor no-admin: el preventista con el corte de las 15:30
-- fijado en 24:00 (#1178), o el encargado en la pasada /enc, con el corte en
-- 00:00. Los pedidos se cargan a nombre del preventista.
CREATE OR REPLACE FUNCTION pg_temp.pf_caso_f1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_ped bigint; v_fecha date := pg_temp.pf_hoy() + 3;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2,
         jsonb_build_object('nombre', 'ZZ ensayo 1152 programada', 'inicio', pg_temp.pf_hoy() + 1));
  v_ped := pg_temp.pf_pedido(pg_temp.pf_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pf_v(v, 10)), v_fecha), 'el alta de F1');
  f := pg_temp.pf_si(f, (SELECT fecha FROM public.pedidos WHERE id = v_ped) = v_fecha,
                     'el pedido no quedo con la fecha futura');
  f := pg_temp.pf_edit_rechazada(f, 'edicion de un pedido con fecha futura con el regalo de una promo que empieza manana',
         v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p)),
         ARRAY[v, x], ARRAY[p],
         'La promo "%" rige %: su regalo no entra en un pedido del ' || to_char(v_fecha, 'DD/MM/YYYY')
         || ' editado el ' || to_char(pg_temp.pf_hoy(), 'DD/MM/YYYY') || '.%');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_caso_f2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_ped bigint; v_res jsonb;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, jsonb_build_object('inicio', pg_temp.pf_hoy()));
  v_ped := pg_temp.pf_pedido(pg_temp.pf_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pf_v(v, 10)), pg_temp.pf_hoy() + 3), 'el alta de F2');
  v_res := pg_temp.pf_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p)));
  f := pg_temp.pf_si(f, pg_temp.pf_ok(v_res),
                     format('agregar al pedido con fecha futura el regalo de una promo que empezo hoy dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_caso_f3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_ped bigint; v_res jsonb;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2,
         jsonb_build_object('inicio', pg_temp.pf_hoy() - 10, 'fin', pg_temp.pf_hoy() - 1));
  v_ped := pg_temp.pf_pedido(pg_temp.pf_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pf_v(v, 10)), pg_temp.pf_hoy() - 2), 'el alta de F3');
  v_res := pg_temp.pf_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p)));
  f := pg_temp.pf_si(f, pg_temp.pf_ok(v_res),
                     format('agregar el regalo de una promo vigente en la fecha (pasada) del pedido dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- #1153 EL CODIGO DEL RECHAZO Y EL REINTENTO SIN EL REGALO
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pf_caso_r1r2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_res jsonb; v_items jsonb; v_sin jsonb; v_ped bigint;
  v_oid text := 'ensayo-1153-' || gen_random_uuid()::text; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, '{"activo": false}');
  v_items := jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p));
  v_res := pg_temp.pf_replay((c->>'cli')::bigint, v_prev, v_items, v_oid, pg_temp.pf_hoy() - 1);
  f := pg_temp.pf_si(f, NOT pg_temp.pf_ok(v_res) AND v_res->>'codigo' = 'regalo_fuera_de_promo'
                        AND COALESCE(v_res->'errores'->>0, '') LIKE 'La promo "%" está desactivada:%El pedido no se creó.',
                     format('R1: el replay con el regalo de una promo inactiva dio %s', v_res));
  f := pg_temp.pf_si(f, NOT EXISTS (SELECT 1 FROM public.pedidos WHERE offline_id = v_oid),
                     'R1: el offline_id quedo sellado');
  f := pg_temp.pf_si(f, pg_temp.pf_ok(v_res) OR pg_temp.pf_terminal(v_res->'errores'->>0),
                     format('R1: el rechazo del replay no es terminal: %s', v_res));

  -- R2: el reintento sin las lineas de regalo, con la misma clave.
  SELECT jsonb_agg(e) INTO v_sin FROM jsonb_array_elements(v_items) e
   WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false);
  v_res := pg_temp.pf_replay((c->>'cli')::bigint, v_prev, v_sin, v_oid, pg_temp.pf_hoy() - 1);
  f := pg_temp.pf_si(f, pg_temp.pf_ok(v_res) AND NOT COALESCE((v_res->>'idempotente')::boolean, false),
                     format('R2: el reintento sin el regalo con la misma clave dio %s', v_res));
  v_ped := (v_res->>'pedido_id')::bigint;
  f := pg_temp.pf_si(f, (SELECT offline_id FROM public.pedidos WHERE id = v_ped) = v_oid,
                     'R2: el pedido no quedo sellado con la clave');
  f := pg_temp.pf_si(f, (SELECT total FROM public.pedidos WHERE id = v_ped) = pg_temp.pf_total(v_items),
                     format('R2: el total quedo %s, esperado %s (el de R1)',
                            (SELECT total FROM public.pedidos WHERE id = v_ped), pg_temp.pf_total(v_items)));
  f := pg_temp.pf_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items WHERE pedido_id = v_ped AND es_bonificacion),
                     'R2: el pedido quedo con una linea de regalo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_caso_r3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; v_res jsonb;
BEGIN
  UPDATE public.politicas_comerciales SET monto_minimo_pedido = 1000000 WHERE sucursal_id = (c->>'suc')::bigint;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'la sucursal no tiene politica comercial: R3 salteado');
  END IF;
  -- El GUC de escape lo pone el bloque principal; aca tiene que regir el minimo.
  PERFORM set_config('app.omitir_minimo_pedido', '', true);
  v_res := pg_temp.pf_alta((c->>'cli')::bigint, (c->>'prev')::uuid, jsonb_build_array(pg_temp.pf_v(v, 10)));
  f := pg_temp.pf_si(f, pg_temp.pf_rechazo(v_res, 'El pedido no alcanza la compra minima de %'),
                     format('el alta por debajo del minimo dio %s', v_res));
  f := pg_temp.pf_si(f, v_res->'codigo' IS NULL, format('el rechazo por compra minima trajo codigo: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- #1154 EL BOT REVALIDA LA PROMO AL CONFIRMAR
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pf_caso_b1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_conf uuid;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2);
  v_conf := pg_temp.pf_pendiente((c->>'prev')::uuid, (c->>'suc')::bigint, (c->>'cli')::bigint,
              jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p)));
  -- Entre la previsualizacion y el boton, el admin apaga la promo.
  UPDATE public.promociones SET activo = false WHERE id = p;
  f := pg_temp.pf_bot_rechazado(f, 'bot con la promo apagada antes de confirmar', (c->>'prev')::uuid, v_conf,
         (c->>'cli')::bigint, ARRAY[v, x], ARRAY[p],
         'La promo "%" está desactivada:%Hacé el pedido de nuevo. El pedido no se creó.');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_caso_b2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_conf uuid; v_res jsonb;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2);
  -- V10 con compra 5 y bonificacion 2: el tope es 4.
  v_conf := pg_temp.pf_pendiente((c->>'prev')::uuid, (c->>'suc')::bigint, (c->>'cli')::bigint,
              jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p)));
  v_res := pg_temp.pf_bot((c->>'prev')::uuid, v_conf);
  f := pg_temp.pf_si(f, pg_temp.pf_ok(v_res), format('el bot con la promo activa y el regalo en el tope dio %s', v_res));
  f := pg_temp.pf_si(f, (SELECT consumido FROM public.bot_pedidos_pendientes WHERE id = v_conf),
                     'la confirmacion aceptada no quedo consumida');
  f := pg_temp.pf_si(f, EXISTS (SELECT 1 FROM public.pedido_items
                                 WHERE pedido_id = (v_res->>'pedido_id')::bigint AND es_bonificacion AND promocion_id = p),
                     'el pedido del bot no quedo con el regalo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_caso_b3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_conf uuid;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2,
         jsonb_build_object('inicio', pg_temp.pf_hoy() - 10, 'fin', pg_temp.pf_hoy() - 1));
  v_conf := pg_temp.pf_pendiente((c->>'prev')::uuid, (c->>'suc')::bigint, (c->>'cli')::bigint,
              jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p)));
  f := pg_temp.pf_bot_rechazado(f, 'bot con la promo vencida ayer', (c->>'prev')::uuid, v_conf,
         (c->>'cli')::bigint, ARRAY[v, x], ARRAY[p],
         'La promo "%" rige del % al ' || to_char(pg_temp.pf_hoy() - 1, 'DD/MM/YYYY')
         || ':%Hacé el pedido de nuevo. El pedido no se creó.');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pf_caso_b4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pf_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_conf uuid; v_res jsonb;
BEGIN
  p := pg_temp.pf_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, '{"activo": false}');
  v_conf := pg_temp.pf_pendiente((c->>'adm')::uuid, (c->>'suc')::bigint, (c->>'cli')::bigint,
              jsonb_build_array(pg_temp.pf_v(v, 10), pg_temp.pf_r(x, 4, p)));
  v_res := pg_temp.pf_bot((c->>'adm')::uuid, v_conf);
  f := pg_temp.pf_si(f, pg_temp.pf_ok(v_res), format('el admin por el bot con la promo inactiva dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- GRANTS
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pf_caso_g(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  f_fue regprocedure := 'public.regalo_fuera_de_promo(jsonb,jsonb,bigint,bigint,date)'::regprocedure;
  f_bot regprocedure := 'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure;
  f_cre regprocedure := 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure;
  f_idm regprocedure := 'public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)'::regprocedure;
  r text; g regprocedure;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    FOREACH g IN ARRAY ARRAY[f_fue, f_bot] LOOP
      f := pg_temp.pf_si(f, NOT has_function_privilege(r, g, 'EXECUTE'), format('%s tiene EXECUTE sobre %s', r, g));
    END LOOP;
  END LOOP;
  FOREACH g IN ARRAY ARRAY[f_cre, f_idm] LOOP
    f := pg_temp.pf_si(f, has_function_privilege('authenticated', g, 'EXECUTE'), format('authenticated perdio EXECUTE sobre %s', g));
    f := pg_temp.pf_si(f, NOT has_function_privilege('anon', g, 'EXECUTE'), format('anon tiene EXECUTE sobre %s', g));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1152$
DECLARE
  v_admin   uuid;
  v_prev    uuid;
  v_enc     uuid;
  v_ed      uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_ctx     jsonb;
  v_caso    text;
  v_pasada  text;
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
  -- Un cliente que el preventista puede operar: activo, sin asignar (visible
  -- para todos, mig 028) y no reservado al admin (mig 214). No VB: el bot lo
  -- rechaza.
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
     AND preventista_id IS NULL AND NOT COALESCE(reservado_admin, false)
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_prev IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hace falta una sucursal activa con un admin, un preventista y un cliente sin asignar';
  END IF;

  -- #1178: el editor no-admin es siempre el preventista (corte fijado en 24:00
  -- por caso); la pasada /enc repite los casos f% con el encargado y el corte
  -- en 00:00.
  v_ed := v_prev;

  v_ctx := jsonb_build_object('suc', v_suc, 'adm', v_admin, 'prev', v_prev, 'enc', v_enc, 'ed', v_ed,
                              'cli', v_cliente);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['f1', 'f2', 'f3', 'r1r2', 'r3', 'b1', 'b2', 'b3', 'b4', 'g'] LOOP
    FOREACH v_pasada IN ARRAY CASE WHEN v_caso LIKE 'f%' AND v_enc IS NOT NULL
                                   THEN ARRAY['', '/enc'] ELSE ARRAY[''] END LOOP
      v_out := NULL;
      BEGIN
        PERFORM pg_temp.pf_reset();
        PERFORM pg_temp.pf_como(v_admin);
        IF v_caso LIKE 'f%' THEN
          -- #1178: el preventista edita con el corte en 24:00; el encargado, con
          -- el corte en 00:00 (esta exento).
          PERFORM pg_temp.pf_corte(CASE v_pasada WHEN '' THEN TIME '24:00' ELSE TIME '00:00' END);
        END IF;
        EXECUTE format('SELECT pg_temp.pf_caso_%s($1)', v_caso) INTO v_out
          USING CASE v_pasada WHEN '' THEN v_ctx ELSE v_ctx || jsonb_build_object('ed', v_enc) END;
        RAISE EXCEPTION USING ERRCODE = 'ZZ001';
      EXCEPTION
        WHEN SQLSTATE 'ZZ001' THEN NULL;
        WHEN OTHERS THEN v_fallas := v_fallas || format('%s%s · error: %s', upper(v_caso), v_pasada, SQLERRM);
      END;
      IF v_out IS NOT NULL THEN
        v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || v_pasada || ' · ' || left(x, 300)
                                        FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
        IF v_out->>'reporte' IS NOT NULL THEN
          v_notas := v_notas || (upper(v_caso) || v_pasada || ' · ' || (v_out->>'reporte'));
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  v_notas := v_notas || CASE WHEN v_enc IS NULL
                             THEN 'sin encargado en la sucursal: sin la pasada /enc de F1-F3'
                             ELSE 'F1-F3 con el preventista (corte 24:00) y con el encargado (/enc, corte 00:00)' END;
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas):\n- %\nnotas: %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | ');
  END IF;
  IF current_setting('ensayo.continuar', true) = '1' THEN
    -- ensayo.resultado: para quien no ve los NOTICE (el SQL editor, el MCP).
    PERFORM set_config('ensayo.resultado', 'ENSAYO OK · notas: ' || array_to_string(v_notas, ' | '), true);
    RAISE NOTICE 'ENSAYO OK · notas: %', array_to_string(v_notas, ' | ');
  ELSE
    RAISE EXCEPTION 'ENSAYO OK · notas: %', array_to_string(v_notas, ' | ');
  END IF;
END
$ensayo1152$;
