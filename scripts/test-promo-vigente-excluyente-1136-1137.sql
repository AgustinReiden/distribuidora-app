-- Ensayo de #1136 y #1137: el regalo de quien no es admin tiene que ser de una
-- promo vigente (#1137) y de una sola promo por grupo excluyente (#1136), al
-- cargar (crear_pedido_completo) y al editar (actualizar_pedido_items).
--
-- Regla (decision del dueno, 2026-10-13), para quien no es admin:
--   vigencia: activo = true y vigente en LEAST(fecha del pedido, hoy) o en hoy
--   (hora argentina); al editar queda exenta la promo cuyo regalo el pedido ya
--   tenia. Exclusion: se rechaza si dos promos excluyentes con regalo en el
--   request comparten el producto de una linea de venta. El admin queda exento.
--
-- Fixture: V (venta), X (cat A, regalo default). Las promos nacen activas,
-- con fecha_inicio = ayer (hora argentina) y sin fecha_fin, salvo que el caso
-- diga otra cosa.
--
-- Vigencia en el alta (preventista salvo que se diga otra cosa):
--   V1  promo con activo = false -> rechazo SIN efectos.
--   V2  fecha_fin = ayer, sin p_fecha -> rechazo SIN efectos.
--   V3  fecha_fin = ayer, p_fecha = anteayer (replay offline) -> pasa.
--   V4  fecha_inicio = manana -> rechazo; fecha_inicio = hoy con p_fecha =
--       ayer (los pedidos 633 y 642) -> pasa.
--   V4b fecha_inicio = manana con p_fecha = manana (request armado con fecha
--       futura) -> rechazo (el tope LEAST).
--   V5  admin con la promo inactiva -> pasa.
--   V6  crear_pedido_idempotente con offline_id y la promo inactiva ->
--       rechazo terminal, sin sellar offline_id.
--   V7  encargado con la promo inactiva -> rechazo.
--
-- Vigencia en la edicion (preventista antes de las 15:30 ARG; si no, el
-- encargado; sin ninguno, se saltea):
--   VE1 alta legal, se apaga la promo y se edita con el mismo regalo -> pasa.
--       (request armado a mano: el modal de edicion hoy no conserva ese
--       regalo con la promo apagada; eso es del front, issue aparte)
--   VE2 la edicion agrega el regalo de una promo inactiva que el pedido no
--       tenia -> rechazo SIN efectos.
--   VE3 pedido con fecha anteayer; la promo termino ayer; la edicion agrega
--       su regalo -> pasa (vigente en la fecha del pedido).
--
-- Exclusion:
--   X1  A (excluyente, compra 5) y B (excluyente, compra 2) comparten V; V10 +
--       regalo de A + regalo de B -> rechazo SIN efectos.
--   X2  solo el regalo de B (la perdedora, con A quitada) -> pasa.
--   X3  A excluyente y C acumulable que comparten V, regalo de las dos -> pasa.
--   X4  cadena A-B-C (A y C no comparten): regalos de A y C -> pasa; de A y B
--       -> rechazo.
--   X5  admin con A y B -> pasa.
--   X6  edicion que agrega el regalo de B a un pedido con el de A -> rechazo
--       SIN efectos.
--   X7  alta legal con SET LOCAL ROLE authenticated -> pasa (la cadena
--       definer -> invoker -> invoker corre como postgres, y el REVOKE de las
--       funciones nuevas no la rompe).
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenarlo con otra
-- sentencia en la misma transaccion).
--
--   psql "$DATABASE_URL" -f scripts/test-promo-vigente-excluyente-1136-1137.sql

CREATE OR REPLACE FUNCTION pg_temp.pv_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- set_config es por transaccion (CLAUDE.md): entre llamada y llamada se
-- limpian los GUCs de stock, asi una RPC no hereda la etiqueta de otra.
CREATE OR REPLACE FUNCTION pg_temp.pv_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_como(p_user uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
END
$fn$;

-- Stock, lotes y bolsa de unos productos.
CREATE OR REPLACE FUNCTION pg_temp.pv_fotos(p_prods bigint[])
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
CREATE OR REPLACE FUNCTION pg_temp.pv_prod(p_suc bigint, p_admin uuid, p_cat text, p_bolsa int DEFAULT 20, p_restante int DEFAULT 50)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1136 ' || p_cat, 100, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1136 ' || p_cat)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.pv_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

-- Una promo de bonificacion con su regalo default, sus disparadores y sus
-- reglas. p_o: nombre, modo ('acumulable' | 'excluyente'), activo, inicio,
-- fin, prioridad. Por defecto: acumulable, activa, desde ayer, sin fin.
CREATE OR REPLACE FUNCTION pg_temp.pv_promo(p_suc bigint, p_regalo bigint, p_disp bigint[],
                                            p_compra numeric, p_bonif numeric, p_o jsonb DEFAULT '{}')
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, fecha_fin, activo, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, modo_exclusion, prioridad)
  VALUES (COALESCE(p_o->>'nombre', 'ZZ ensayo 1136'), 'bonificacion',
          COALESCE((p_o->>'inicio')::date, pg_temp.pv_hoy() - 1), (p_o->>'fin')::date,
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

CREATE OR REPLACE FUNCTION pg_temp.pv_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_total(p_items jsonb)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
    FROM jsonb_array_elements(p_items) e;
$fn$;

-- El alta como p_user, con p_fecha opcional. No aborta.
CREATE OR REPLACE FUNCTION pg_temp.pv_alta(p_cli bigint, p_user uuid, p_items jsonb, p_fecha date DEFAULT NULL,
                                           p_prev uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.pv_como(p_user);
  v_res := public.crear_pedido_completo(
    p_cliente_id => p_cli, p_total => pg_temp.pv_total(p_items), p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1136', p_fecha => p_fecha, p_preventista_id => p_prev);
  PERFORM pg_temp.pv_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_edit(p_ped bigint, p_user uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.pv_como(p_user);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.pv_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

-- Rechazo (success = false) con un primer error que calza con p_patron (LIKE).
CREATE OR REPLACE FUNCTION pg_temp.pv_rechazo(p_res jsonb, p_patron text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT pg_temp.pv_ok(p_res) AND COALESCE(p_res->'errores'->>0, '') LIKE p_patron;
$fn$;

-- El mismo criterio que rechazoEsTerminal (src/utils/rechazoDeNegocio.ts).
CREATE OR REPLACE FUNCTION pg_temp.pv_terminal(p_msg text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT p_msg IS NOT NULL
     AND p_msg !~* 'stock insuficiente|sin stock|stock disponible'
     AND lower(p_msg) NOT LIKE '%no se pudo determinar la sucursal activa%'
     AND lower(p_msg) NOT LIKE '%jwt expired%'
     AND lower(p_msg) NOT LIKE '%token is expired%'
     AND lower(p_msg) NOT LIKE '%invalid claim%';
$fn$;

-- Lo que un alta rechazada no puede haber tocado (incluye usos_pendientes).
CREATE OR REPLACE FUNCTION pg_temp.pv_estado(p_cli bigint, p_prods bigint[], p_promos bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'pedidos', (SELECT count(*) FROM public.pedidos WHERE cliente_id = p_cli),
    'lineas', (SELECT count(*) FROM public.pedido_items WHERE producto_id = ANY(p_prods)),
    'fotos', pg_temp.pv_fotos(p_prods),
    'usos', (SELECT jsonb_agg(jsonb_build_array(id, usos_pendientes) ORDER BY id)
               FROM public.promociones WHERE id = ANY(p_promos)),
    'acum', (SELECT COALESCE(jsonb_agg(jsonb_build_array(id, producto_regalo_id, usos_pendientes) ORDER BY id), '[]'::jsonb)
               FROM public.promo_acumuladores WHERE promocion_id = ANY(p_promos)));
$fn$;

-- Lo que una edicion rechazada no puede haber tocado.
CREATE OR REPLACE FUNCTION pg_temp.pv_estado_ped(p_ped bigint, p_prods bigint[], p_promos bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'lineas', (SELECT COALESCE(jsonb_agg(jsonb_build_array(pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false),
                                                          pi.promocion_id, pi.regalo_cadena_id) ORDER BY pi.id), '[]'::jsonb)
                 FROM public.pedido_items pi WHERE pi.pedido_id = p_ped),
    'total', (SELECT total FROM public.pedidos WHERE id = p_ped),
    'fotos', pg_temp.pv_fotos(p_prods),
    'usos', (SELECT jsonb_agg(jsonb_build_array(id, usos_pendientes) ORDER BY id)
               FROM public.promociones WHERE id = ANY(p_promos)));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_pedido(p_res jsonb, p_que text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT pg_temp.pv_ok(p_res) THEN
    RAISE EXCEPTION 'no se pudo preparar %: %', p_que, p_res;
  END IF;
  RETURN (p_res->>'pedido_id')::bigint;
END
$fn$;

-- Un alta que tiene que rechazarse SIN efectos.
CREATE OR REPLACE FUNCTION pg_temp.pv_alta_rechazada(p_f text[], p_que text, p_cli bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_promos bigint[], p_patron text,
                                                     p_fecha date DEFAULT NULL)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.pv_estado(p_cli, p_prods, p_promos);
  v_res := pg_temp.pv_alta(p_cli, p_user, p_items, p_fecha);
  v_e1 := pg_temp.pv_estado(p_cli, p_prods, p_promos);
  f := pg_temp.pv_si(f, pg_temp.pv_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res) OR pg_temp.pv_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.pv_si(f, v_e1 = v_e0, format('%s: el alta rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

-- Una edicion que tiene que rechazarse SIN efectos.
CREATE OR REPLACE FUNCTION pg_temp.pv_edit_rechazada(p_f text[], p_que text, p_ped bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_promos bigint[], p_patron text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.pv_estado_ped(p_ped, p_prods, p_promos);
  v_res := pg_temp.pv_edit(p_ped, p_user, p_items);
  v_e1 := pg_temp.pv_estado_ped(p_ped, p_prods, p_promos);
  f := pg_temp.pv_si(f, pg_temp.pv_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res) OR pg_temp.pv_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.pv_si(f, v_e1 = v_e0, format('%s: la edicion rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

-- Patrones de los mensajes.
CREATE OR REPLACE FUNCTION pg_temp.pv_pat_off() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'La promo "%" está desactivada: su regalo ya no entra en un pedido nuevo.%' $fn$;
CREATE OR REPLACE FUNCTION pg_temp.pv_pat_vig() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'La promo "%" rige %: su regalo no entra en un pedido del %' $fn$;
CREATE OR REPLACE FUNCTION pg_temp.pv_pat_exc() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'Las promos "%" y "%" son excluyentes y comparten productos de este pedido: lleva el regalo de una sola.%' $fn$;

-- El fixture estandar: V (venta) y X (regalo default).
CREATE OR REPLACE FUNCTION pg_temp.pv_fix(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
BEGIN
  RETURN jsonb_build_object('v', pg_temp.pv_prod(s, a, 'venta'), 'x', pg_temp.pv_prod(s, a, 'cat A'));
END
$fn$;

-- ===========================================================================
-- VIGENCIA EN EL ALTA
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, '{"activo": false}');
  f := pg_temp.pv_alta_rechazada(f, 'promo inactiva', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)), ARRAY[v, x], ARRAY[p], pg_temp.pv_pat_off());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2,
         jsonb_build_object('inicio', pg_temp.pv_hoy() - 10, 'fin', pg_temp.pv_hoy() - 1));
  f := pg_temp.pv_alta_rechazada(f, 'promo vencida ayer, pedido de hoy', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)), ARRAY[v, x], ARRAY[p], pg_temp.pv_pat_vig());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint;
  v_res jsonb;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2,
         jsonb_build_object('inicio', pg_temp.pv_hoy() - 10, 'fin', pg_temp.pv_hoy() - 1));
  v_res := pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)), pg_temp.pv_hoy() - 2);
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('el replay de anteayer con la promo que termino ayer dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; q bigint; v_res jsonb;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, jsonb_build_object('inicio', pg_temp.pv_hoy() + 1));
  f := pg_temp.pv_alta_rechazada(f, 'promo que empieza manana', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)), ARRAY[v, x], ARRAY[p], pg_temp.pv_pat_vig());
  q := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, jsonb_build_object('inicio', pg_temp.pv_hoy()));
  v_res := pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, q)), pg_temp.pv_hoy() - 1);
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('el alta con fecha ayer y la promo que empezo hoy dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v4b(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint; p bigint;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, jsonb_build_object('inicio', pg_temp.pv_hoy() + 1));
  f := pg_temp.pv_alta_rechazada(f, 'fecha futura armada a mano', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)), ARRAY[v, x], ARRAY[p], pg_temp.pv_pat_vig(),
         pg_temp.pv_hoy() + 1);
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_res jsonb;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, '{"activo": false}');
  v_res := pg_temp.pv_alta((c->>'cli')::bigint, (c->>'adm')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('el admin no pudo cargar el regalo de una promo inactiva: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v6(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_res jsonb; v_items jsonb;
  v_oid text := 'ensayo-1137-' || gen_random_uuid()::text; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, '{"activo": false}');
  v_items := jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p));
  PERFORM pg_temp.pv_como(v_prev);
  v_res := public.crear_pedido_idempotente(
    p_cliente_id => (c->>'cli')::bigint, p_total => pg_temp.pv_total(v_items), p_usuario_id => v_prev,
    p_items => v_items, p_notas => 'ensayo 1137', p_fecha => pg_temp.pv_hoy() - 1, p_offline_id => v_oid);
  PERFORM pg_temp.pv_reset();
  f := pg_temp.pv_si(f, pg_temp.pv_rechazo(v_res, pg_temp.pv_pat_off()),
                     format('el replay con el regalo de una promo inactiva dio %s', v_res));
  f := pg_temp.pv_si(f, NOT EXISTS (SELECT 1 FROM public.pedidos WHERE offline_id = v_oid),
                     'el offline_id quedo sellado');
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res) OR pg_temp.pv_terminal(v_res->'errores'->>0),
                     format('el rechazo del replay no es terminal: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_v7(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb; v bigint; x bigint; p bigint; v_enc uuid := (c->>'enc')::uuid;
BEGIN
  IF v_enc IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin encargado en la sucursal: V7 salteado');
  END IF;
  k := pg_temp.pv_fix(c); v := (k->>'v')::bigint; x := (k->>'x')::bigint;
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2, '{"activo": false}');
  f := pg_temp.pv_alta_rechazada(f, 'encargado, promo inactiva', (c->>'cli')::bigint, v_enc,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)), ARRAY[v, x], ARRAY[p], pg_temp.pv_pat_off());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- VIGENCIA EN LA EDICION
-- ===========================================================================
-- c->>'ed' es el editor no-admin (preventista antes de las 15:30, si no el
-- encargado). Los pedidos se cargan a nombre del preventista, asi el editor
-- preventista es su creador.
CREATE OR REPLACE FUNCTION pg_temp.pv_caso_ve1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_ped bigint; v_res jsonb;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2);
  v_ped := pg_temp.pv_pedido(pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p))), 'el alta de VE1');
  UPDATE public.promociones SET activo = false WHERE id = p;
  v_res := pg_temp.pv_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.pv_v(v, 12), pg_temp.pv_r(x, 4, p)));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('editar un pedido con el regalo de una promo que se apago despues dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_ve2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; q bigint; v_ped bigint;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2);
  q := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 1, '{"activo": false}');
  v_ped := pg_temp.pv_pedido(pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p))), 'el alta de VE2');
  f := pg_temp.pv_edit_rechazada(f, 'edicion que agrega el regalo de una promo inactiva', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p), pg_temp.pv_r(x, 2, q)),
         ARRAY[v, x], ARRAY[p, q], pg_temp.pv_pat_off());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_ve3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  p bigint; v_ped bigint; v_res jsonb;
BEGIN
  p := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 2,
         jsonb_build_object('inicio', pg_temp.pv_hoy() - 10, 'fin', pg_temp.pv_hoy() - 1));
  -- El pedido es de anteayer, cuando la promo regia; se carga sin el regalo.
  v_ped := pg_temp.pv_pedido(pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10)), pg_temp.pv_hoy() - 2), 'el alta de VE3');
  v_res := pg_temp.pv_edit(v_ped, (c->>'ed')::uuid, jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 4, p)));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res),
                     format('agregar el regalo de una promo vigente en la fecha del pedido dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- EXCLUSION
-- ===========================================================================
-- A (excluyente, 5 -> 1) y B (excluyente, 2 -> 1) comparten V. Con V10 las dos
-- disparan y gana A (mayor cantidad_compra).
CREATE OR REPLACE FUNCTION pg_temp.pv_fix_ab(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  k jsonb := pg_temp.pv_fix(c); s bigint := (c->>'suc')::bigint; v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
BEGIN
  RETURN k || jsonb_build_object(
    'a', pg_temp.pv_promo(s, x, ARRAY[v], 5, 1, '{"modo": "excluyente", "nombre": "ZZ ensayo 1136 A"}'),
    'b', pg_temp.pv_promo(s, x, ARRAY[v], 2, 1, '{"modo": "excluyente", "nombre": "ZZ ensayo 1136 B"}'));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_x1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix_ab(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  a bigint := (k->>'a')::bigint; b bigint := (k->>'b')::bigint;
BEGIN
  f := pg_temp.pv_alta_rechazada(f, 'regalo de dos excluyentes', (c->>'cli')::bigint, (c->>'prev')::uuid,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 2, a), pg_temp.pv_r(x, 5, b)),
         ARRAY[v, x], ARRAY[a, b], pg_temp.pv_pat_exc());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_x2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix_ab(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  v_res jsonb;
BEGIN
  v_res := pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 5, (k->>'b')::bigint)));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('el regalo de la perdedora sola (ganadora quitada) dio %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_x3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix_ab(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  q bigint; v_res jsonb;
BEGIN
  q := pg_temp.pv_promo((c->>'suc')::bigint, x, ARRAY[v], 5, 1, '{"nombre": "ZZ ensayo 1136 C acumulable"}');
  v_res := pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 2, (k->>'a')::bigint), pg_temp.pv_r(x, 2, q)));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('una excluyente y una acumulable que comparten V dieron %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_x4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; ad uuid := (c->>'adm')::uuid;
  v bigint; w bigint; u bigint; t bigint; x bigint; pa bigint; pb bigint; pc bigint; v_res jsonb; v_base jsonb;
BEGIN
  v := pg_temp.pv_prod(s, ad, 'venta');
  w := pg_temp.pv_prod(s, ad, 'venta');
  u := pg_temp.pv_prod(s, ad, 'venta');
  t := pg_temp.pv_prod(s, ad, 'venta');
  x := pg_temp.pv_prod(s, ad, 'cat A');
  -- A = {V, W}, B = {W, U}, C = {U, T}: A y C no comparten.
  pa := pg_temp.pv_promo(s, x, ARRAY[v, w], 2, 1, '{"modo": "excluyente", "nombre": "ZZ ensayo 1136 cadena A"}');
  pb := pg_temp.pv_promo(s, x, ARRAY[w, u], 2, 1, '{"modo": "excluyente", "nombre": "ZZ ensayo 1136 cadena B"}');
  pc := pg_temp.pv_promo(s, x, ARRAY[u, t], 2, 1, '{"modo": "excluyente", "nombre": "ZZ ensayo 1136 cadena C"}');
  v_base := jsonb_build_array(pg_temp.pv_v(v, 2), pg_temp.pv_v(w, 2), pg_temp.pv_v(u, 2), pg_temp.pv_v(t, 2));
  v_res := pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid, v_base || pg_temp.pv_r(x, 1, pa) || pg_temp.pv_r(x, 1, pc));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('la cadena A-B-C con regalos de A y C (sin B) dio %s', v_res));
  f := pg_temp.pv_alta_rechazada(f, 'cadena con regalos de A y B', (c->>'cli')::bigint, (c->>'prev')::uuid,
         v_base || pg_temp.pv_r(x, 1, pa) || pg_temp.pv_r(x, 1, pb), ARRAY[v, w, u, t, x], ARRAY[pa, pb, pc],
         pg_temp.pv_pat_exc());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_x5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix_ab(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  v_res jsonb;
BEGIN
  v_res := pg_temp.pv_alta((c->>'cli')::bigint, (c->>'adm')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 2, (k->>'a')::bigint), pg_temp.pv_r(x, 5, (k->>'b')::bigint)));
  f := pg_temp.pv_si(f, pg_temp.pv_ok(v_res), format('el admin no pudo cargar el regalo de dos excluyentes: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_x6(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix_ab(c); v bigint := (k->>'v')::bigint; x bigint := (k->>'x')::bigint;
  a bigint := (k->>'a')::bigint; b bigint := (k->>'b')::bigint; v_ped bigint;
BEGIN
  v_ped := pg_temp.pv_pedido(pg_temp.pv_alta((c->>'cli')::bigint, (c->>'prev')::uuid,
             jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 2, a))), 'el alta de X6');
  f := pg_temp.pv_edit_rechazada(f, 'edicion que agrega el regalo de la otra excluyente', v_ped, (c->>'ed')::uuid,
         jsonb_build_array(pg_temp.pv_v(v, 10), pg_temp.pv_r(x, 2, a), pg_temp.pv_r(x, 5, b)),
         ARRAY[v, x], ARRAY[a, b], pg_temp.pv_pat_exc());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pv_caso_x7(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; k jsonb := pg_temp.pv_fix_ab(c); v_res jsonb; v_items jsonb; v_total numeric;
  v_prev uuid := (c->>'prev')::uuid; v_cli bigint := (c->>'cli')::bigint; v_err text;
BEGIN
  v_items := jsonb_build_array(pg_temp.pv_v((k->>'v')::bigint, 10), pg_temp.pv_r((k->>'x')::bigint, 2, (k->>'a')::bigint));
  v_total := pg_temp.pv_total(v_items);
  PERFORM pg_temp.pv_como(v_prev);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := public.crear_pedido_completo(
      p_cliente_id => v_cli, p_total => v_total, p_usuario_id => v_prev, p_items => v_items, p_notas => 'ensayo 1136');
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    EXECUTE 'RESET ROLE';
  END;
  PERFORM pg_temp.pv_reset();
  f := pg_temp.pv_si(f, v_err IS NULL AND pg_temp.pv_ok(v_res),
                     format('como authenticated el alta legal dio %s (error: %s)', v_res, v_err));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1136$
DECLARE
  v_admin   uuid;
  v_prev    uuid;
  v_enc     uuid;
  v_ed      uuid;
  v_suc     bigint;
  v_cliente bigint;
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
  -- Un cliente que el preventista puede operar: activo, sin asignar (visible
  -- para todos, mig 028) y no reservado al admin (mig 214).
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
     AND preventista_id IS NULL AND NOT COALESCE(reservado_admin, false)
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
                              'cli', v_cliente);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['v1', 'v2', 'v3', 'v4', 'v4b', 'v5', 'v6', 'v7',
                                've1', 've2', 've3',
                                'x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7'] LOOP
    v_out := NULL;
    IF (v_caso LIKE 've%' OR v_caso = 'x6') AND v_ed IS NULL THEN
      v_notas := v_notas || (upper(v_caso) || ' · sin encargado y pasadas las 15:30: salteado');
      CONTINUE;
    END IF;
    BEGIN
      PERFORM pg_temp.pv_reset();
      PERFORM pg_temp.pv_como(v_admin);
      EXECUTE format('SELECT pg_temp.pv_caso_%s($1)', v_caso) INTO v_out USING v_ctx;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || left(x, 220)
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
$ensayo1136$;
