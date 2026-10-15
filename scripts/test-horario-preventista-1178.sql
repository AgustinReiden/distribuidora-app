-- Ensayo de #1178: el horario de edicion del preventista (corte de las 15:30 ART
-- en actualizar_pedido_items) se prueba POR COMPORTAMIENTO, a cualquier hora de
-- la corrida.
--
-- Regla (actualizar_pedido_items, bloque del rol preventista, en este orden):
--   1. solo edita el preventista que creo el pedido ('Solo el preventista que
--      creo el pedido puede editarlo');
--   2. solo pedidos del dia ART actual Y solo antes de v_hora_corte (15:30):
--      'Como preventista solo puede editar pedidos del dia actual antes de las
--      15:30 (ARG)'. Admin y encargado estan exentos de 1 y 2.
-- La hora de corte es una constante y se compara contra now(), que dentro de una
-- transaccion no se mueve. Para probar el rechazo a cualquier hora, cada caso
-- reescribe la constante por ancla (hp_corte, molde de
-- test-seg-b-predicado-pedidos.sql) dentro de su subbloque revertido y la fija
-- relativa al now() congelado: 24:00 = el preventista siempre pasa el horario,
-- 00:00 = nunca, hora actual = justo en el limite.
--
-- Casos (el preventista da de alta un pedido suyo con un producto y edita
-- agregando otro, a precio de lista):
--   H0  (estructural, sin parche) el ancla de la constante aparece una vez y
--       vale '15:30'; la comparacion '::time >= v_hora_corte' esta una vez; el
--       mensaje 'antes de las 15:30 (ARG)' esta; y pedido_items_guard_estado
--       tiene su propia copia de TIME '15:30' (una vez). Si falla, el corte
--       cambio: cambiar tambien HORA_CORTE_PREVENTISTA / MINUTO_CORTE_PREVENTISTA
--       en src/utils/permisosPedido.ts y pedido_items_guard_estado.
--   H1  corte = ahora + 1 microsegundo: pasa.
--   H2  corte = ahora (el limite: >= rechaza): rechazo del horario, sin efectos.
--   H3  corte 00:00: rechazo del horario, sin efectos.
--   H4  corte 24:00 y el pedido movido un dia atras: rechazo (otro dia), sin
--       efectos.
--   H4b corte 24:00 y el pedido en la medianoche ART de hoy - 1 microsegundo
--       (ayer en ART): rechazo, sin efectos.
--   H4c corte 24:00 y el pedido en la medianoche ART de hoy, exacta: pasa.
--   H5  corte 00:00: el admin y el encargado editan dos veces cada uno, un
--       pedido de hoy y uno movido a ayer (medianoche - 1 microsegundo): las
--       cuatro pasan (estan exentos).
--   H6  corte 00:00: el preventista edita un pedido del admin: el mensaje es el
--       del creador, no el del horario (el creador va antes).
--   H7  sin parche, con la hora real: pasa si ahora < 15:30; si no, rechazo del
--       horario. La nota dice que rama corrio.
--   M1..M4  mutantes: el ensayo prueba que sus casos muerden. Cada uno reescribe
--       una pieza de la regla y el caso que la cubre tiene que dejar de
--       rechazar.
--       M1  '>=' -> '>' con corte = ahora: pasa (H2 muerde).
--       M2  la clausula de la hora -> false con corte 00:00: pasa (H3 muerde).
--       M3  la clausula de la fecha -> sin efecto, con el pedido de ayer: pasa
--           (H4 muerde).
--       M4  la fecha del pedido y la de hoy en UTC en vez de ART: al menos uno
--           de H4b / H4c cambia de resultado (antes de las 21:00 ART lo agarra
--           H4b, despues H4c). La nota dice cual mordio.
--
-- Un caso cuyo helper de corte no encuentra el ancla se anota como falla
-- (WHEN OTHERS), nunca se saltea.
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido (la funcion reescrita tambien),
-- y todo termina en un RAISE. Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO
-- FALLO'. Con el GUC ensayo.continuar = '1' el OK sale como NOTICE. Hay que
-- correrlo como postgres (reescribe la funcion dentro de la transaccion).
--
--   psql "$DATABASE_URL" -f scripts/test-horario-preventista-1178.sql

-- ---------------------------------------------------------------------------
-- Helpers: los de scripts/test-politica-precios-1157-1159.sql (hp_ por pp_)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.hp_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_como(p_user uuid)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
END
$fn$;

-- Un producto sintetico con un lote (90 dias, 100, p_restante vivas) y
-- p_bolsa sin lote. Bolsa distinta de 0 a proposito (nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.hp_prod(p_suc bigint, p_admin uuid, p_cat text, p_precio numeric DEFAULT 100,
                                           p_bolsa int DEFAULT 20, p_restante int DEFAULT 50)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1178 ' || p_cat, p_precio, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1178 ' || p_cat)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.hp_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_v(p_prod bigint, p_cant int, p_precio numeric DEFAULT 100)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_total(p_items jsonb)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
    FROM jsonb_array_elements(p_items) e;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_alta(p_cli bigint, p_user uuid, p_items jsonb, p_tipo text DEFAULT 'ZZ')
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.hp_como(p_user);
  v_res := public.crear_pedido_completo(
    p_cliente_id => p_cli, p_total => pg_temp.hp_total(p_items), p_usuario_id => p_user, p_items => p_items,
    p_notas => 'ensayo 1178', p_tipo_factura => p_tipo);
  PERFORM pg_temp.hp_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_edit(p_ped bigint, p_user uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.hp_como(p_user);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.hp_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_rechazo(p_res jsonb, p_patron text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT NOT pg_temp.hp_ok(p_res) AND COALESCE(p_res->'errores'->>0, '') LIKE p_patron;
$fn$;

-- El mismo criterio que rechazoEsTerminal (src/utils/rechazoDeNegocio.ts).
CREATE OR REPLACE FUNCTION pg_temp.hp_terminal(p_msg text)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT p_msg IS NOT NULL
     AND p_msg !~* 'stock insuficiente|sin stock|stock disponible'
     AND lower(p_msg) NOT LIKE '%no se pudo determinar la sucursal activa%'
     AND lower(p_msg) NOT LIKE '%jwt expired%'
     AND lower(p_msg) NOT LIKE '%token is expired%'
     AND lower(p_msg) NOT LIKE '%invalid claim%';
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_pedido(p_res jsonb, p_que text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
BEGIN
  IF NOT pg_temp.hp_ok(p_res) THEN
    RAISE EXCEPTION 'no se pudo preparar %: %', p_que, p_res;
  END IF;
  RETURN (p_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_fotos(p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_object_agg(pr.id::text, jsonb_build_object(
           'stock', pr.stock,
           'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                                FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb)))
    FROM public.productos pr WHERE pr.id = ANY(p_prods);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_estado_ped(p_ped bigint, p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'lineas', (SELECT COALESCE(jsonb_agg(jsonb_build_array(pi.producto_id, pi.cantidad, pi.precio_unitario,
                                                          COALESCE(pi.es_bonificacion, false)) ORDER BY pi.id), '[]'::jsonb)
                 FROM public.pedido_items pi WHERE pi.pedido_id = p_ped),
    'total', (SELECT total FROM public.pedidos WHERE id = p_ped),
    'fotos', pg_temp.hp_fotos(p_prods));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_edit_rechazada(p_f text[], p_que text, p_ped bigint, p_user uuid, p_items jsonb,
                                                     p_prods bigint[], p_patron text)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_e0 jsonb; v_e1 jsonb; v_res jsonb;
BEGIN
  v_e0 := pg_temp.hp_estado_ped(p_ped, p_prods);
  v_res := pg_temp.hp_edit(p_ped, p_user, p_items);
  v_e1 := pg_temp.hp_estado_ped(p_ped, p_prods);
  f := pg_temp.hp_si(f, pg_temp.hp_rechazo(v_res, p_patron), format('%s: se esperaba el rechazo "%s" y dio %s', p_que, p_patron, v_res));
  f := pg_temp.hp_si(f, pg_temp.hp_ok(v_res) OR pg_temp.hp_terminal(v_res->'errores'->>0),
                     format('%s: el rechazo no es terminal: %s', p_que, v_res));
  f := pg_temp.hp_si(f, v_e1 = v_e0, format('%s: la edicion rechazada dejo efectos: antes %s, despues %s', p_que, v_e0, v_e1));
  RETURN f;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_edit_pasa(p_f text[], p_que text, p_ped bigint, p_user uuid, p_items jsonb)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := pg_temp.hp_edit(p_ped, p_user, p_items);
  RETURN pg_temp.hp_si(p_f, pg_temp.hp_ok(v_res), format('%s: se esperaba que pase y dio %s', p_que, v_res));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Helpers nuevos
-- ---------------------------------------------------------------------------
-- Fija la hora de corte del preventista reescribiendo la constante de
-- actualizar_pedido_items (molde: test-seg-b-predicado-pedidos.sql). Se llama
-- SOLO dentro del subbloque revertido de un caso: no sobrevive al caso, ni con
-- ensayo.continuar = '1'. Corre como duenio de la funcion (postgres).
-- 24:00 deja pasar al preventista a cualquier hora del dia; 00:00 lo rechaza
-- siempre (el encargado y el admin estan exentos del corte).
CREATE OR REPLACE FUNCTION pg_temp.hp_corte(p_corte time)
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

-- Un mutante: reemplaza p_de por p_a en la definicion VIGENTE de
-- actualizar_pedido_items (con el corte que haya fijado hp_corte). Exige
-- exactamente una ocurrencia de p_de: si el texto de la regla cambia, el
-- mutante falla en voz alta en vez de no mutar nada.
CREATE OR REPLACE FUNCTION pg_temp.hp_mutar(p_de text, p_a text)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  v_n   integer := (length(v_def) - length(replace(v_def, p_de, ''))) / length(p_de);
BEGIN
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'hp_mutar: "%" aparece % veces en actualizar_pedido_items (se esperaba 1)', p_de, v_n;
  END IF;
  EXECUTE replace(v_def, p_de, p_a);
END
$fn$;

-- Mueve la fecha de creacion de un pedido (como postgres: pedidos_proteger_columnas
-- solo frena a 'authenticated'). Si no movio exactamente esa fila, el caso falla.
CREATE OR REPLACE FUNCTION pg_temp.hp_correr_pedido(p_ped bigint, p_hacia timestamptz)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_n integer;
BEGIN
  UPDATE public.pedidos SET created_at = p_hacia WHERE id = p_ped;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'hp_correr_pedido: se esperaba mover 1 pedido y se movieron %', v_n;
  END IF;
  IF (SELECT created_at FROM public.pedidos WHERE id = p_ped) IS DISTINCT FROM p_hacia THEN
    RAISE EXCEPTION 'hp_correr_pedido: el pedido % no quedo en %', p_ped, p_hacia;
  END IF;
END
$fn$;

-- El corte "justo despues de ahora": la hora actual ART + 1 microsegundo (24:00
-- si ya es la ultima microsegundo del dia, para no dar la vuelta).
CREATE OR REPLACE FUNCTION pg_temp.hp_limite(c jsonb)
RETURNS time LANGUAGE sql AS $fn$
  SELECT CASE WHEN (c->>'ahora')::time >= TIME '23:59:59.999999' THEN TIME '24:00'
              ELSE (c->>'ahora')::time + interval '1 microsecond' END;
$fn$;

-- El encargado del caso: el real de la sucursal si hay; si no, el preventista
-- promovido (el UPDATE queda dentro del subbloque del caso, que se revierte con
-- ZZ001). Sin ninguno de los dos, falla: el caso nunca se saltea.
CREATE OR REPLACE FUNCTION pg_temp.hp_encargado(c jsonb)
RETURNS uuid LANGUAGE plpgsql AS $fn$
BEGIN
  IF c->>'enc' IS NOT NULL THEN
    RETURN (c->>'enc')::uuid;
  END IF;
  IF c->>'prev' IS NULL THEN
    RAISE EXCEPTION 'sin encargado ni preventista para hacer de encargado';
  END IF;
  PERFORM pg_temp.hp_como((c->>'adm')::uuid);
  UPDATE public.perfiles SET rol = 'encargado' WHERE id = (c->>'prev')::uuid;
  IF (SELECT rol FROM public.perfiles WHERE id = (c->>'prev')::uuid) IS DISTINCT FROM 'encargado' THEN
    RAISE EXCEPTION 'no se pudo promover al preventista a encargado';
  END IF;
  RETURN (c->>'prev')::uuid;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_pat_horario() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'Como preventista solo puede editar pedidos del dia actual%' $fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_pat_creador() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'Solo el preventista que creo el pedido puede editarlo%' $fn$;

-- Dos productos a lista y un pedido de p_user (por defecto el preventista del
-- caso) con el primero: {v, w, ped}. Cada caso edita agregando el segundo.
CREATE OR REPLACE FUNCTION pg_temp.hp_nuevo(c jsonb, p_tag text, p_user uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint := pg_temp.hp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, p_tag || ' v');
  w bigint := pg_temp.hp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, p_tag || ' w');
  v_ped bigint;
BEGIN
  v_ped := pg_temp.hp_pedido(
    pg_temp.hp_alta((c->>'cli')::bigint, COALESCE(p_user, (c->>'prev')::uuid), jsonb_build_array(pg_temp.hp_v(v, 2))),
    'el alta de ' || p_tag);
  RETURN jsonb_build_object('v', v, 'w', w, 'ped', v_ped);
END
$fn$;

-- La edicion de los casos: el producto del alta (cantidad p_cant) mas el otro.
CREATE OR REPLACE FUNCTION pg_temp.hp_items(n jsonb, p_cant int DEFAULT 2)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(pg_temp.hp_v((n->>'v')::bigint, p_cant), pg_temp.hp_v((n->>'w')::bigint, 1));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_prods(n jsonb)
RETURNS bigint[] LANGUAGE sql AS $fn$
  SELECT ARRAY[(n->>'v')::bigint, (n->>'w')::bigint];
$fn$;

-- ===========================================================================
-- CASOS
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h1'); p uuid := (c->>'prev')::uuid;
BEGIN
  PERFORM pg_temp.hp_corte(pg_temp.hp_limite(c));
  f := pg_temp.hp_edit_pasa(f, 'H1 corte = ahora + 1 microsegundo', (n->>'ped')::bigint, p, pg_temp.hp_items(n));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h2'); p uuid := (c->>'prev')::uuid;
BEGIN
  PERFORM pg_temp.hp_corte((c->>'ahora')::time);
  f := pg_temp.hp_edit_rechazada(f, 'H2 corte = ahora (el limite)', (n->>'ped')::bigint, p, pg_temp.hp_items(n),
         pg_temp.hp_prods(n), pg_temp.hp_pat_horario());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h3'); p uuid := (c->>'prev')::uuid;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '00:00');
  f := pg_temp.hp_edit_rechazada(f, 'H3 corte 00:00', (n->>'ped')::bigint, p, pg_temp.hp_items(n),
         pg_temp.hp_prods(n), pg_temp.hp_pat_horario());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h4'); p uuid := (c->>'prev')::uuid;
  v_ped bigint := (n->>'ped')::bigint;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '24:00');
  PERFORM pg_temp.hp_correr_pedido(v_ped, (SELECT created_at FROM public.pedidos WHERE id = v_ped) - interval '1 day');
  f := pg_temp.hp_edit_rechazada(f, 'H4 pedido de ayer, corte 24:00', v_ped, p, pg_temp.hp_items(n),
         pg_temp.hp_prods(n), pg_temp.hp_pat_horario());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h4b(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h4b'); p uuid := (c->>'prev')::uuid;
  v_ped bigint := (n->>'ped')::bigint;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '24:00');
  PERFORM pg_temp.hp_correr_pedido(v_ped, (c->>'medianoche')::timestamptz - interval '1 microsecond');
  f := pg_temp.hp_edit_rechazada(f, 'H4b pedido en la medianoche ART - 1 microsegundo, corte 24:00', v_ped, p,
         pg_temp.hp_items(n), pg_temp.hp_prods(n), pg_temp.hp_pat_horario());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h4c(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h4c'); p uuid := (c->>'prev')::uuid;
  v_ped bigint := (n->>'ped')::bigint;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '24:00');
  PERFORM pg_temp.hp_correr_pedido(v_ped, (c->>'medianoche')::timestamptz);
  f := pg_temp.hp_edit_pasa(f, 'H4c pedido en la medianoche ART exacta, corte 24:00', v_ped, p, pg_temp.hp_items(n));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n1 jsonb := pg_temp.hp_nuevo(c, 'h5 hoy'); n2 jsonb := pg_temp.hp_nuevo(c, 'h5 ayer');
  v_enc uuid; u uuid; v_cant int := 2; v_rol text;
BEGIN
  v_enc := pg_temp.hp_encargado(c);
  PERFORM pg_temp.hp_correr_pedido((n2->>'ped')::bigint, (c->>'medianoche')::timestamptz - interval '1 microsecond');
  PERFORM pg_temp.hp_corte(TIME '00:00');
  FOREACH u IN ARRAY ARRAY[(c->>'adm')::uuid, v_enc] LOOP
    v_rol := (SELECT rol FROM public.perfiles WHERE id = u);
    f := pg_temp.hp_edit_pasa(f, 'H5 ' || v_rol || ' edita un pedido de hoy con el corte en 00:00',
                              (n1->>'ped')::bigint, u, pg_temp.hp_items(n1, v_cant));
    f := pg_temp.hp_edit_pasa(f, 'H5 ' || v_rol || ' edita un pedido de ayer con el corte en 00:00',
                              (n2->>'ped')::bigint, u, pg_temp.hp_items(n2, v_cant));
    v_cant := v_cant + 1;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h6(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h6', (c->>'adm')::uuid); p uuid := (c->>'prev')::uuid;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '00:00');
  f := pg_temp.hp_edit_rechazada(f, 'H6 el preventista edita un pedido del admin (el creador va antes que el horario)',
         (n->>'ped')::bigint, p, pg_temp.hp_items(n), pg_temp.hp_prods(n), pg_temp.hp_pat_creador());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- H7: sin parche, con la hora real de la corrida. Pasa o se rechaza segun la
-- hora; la nota dice que rama corrio.
CREATE OR REPLACE FUNCTION pg_temp.hp_caso_h7(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'h7'); p uuid := (c->>'prev')::uuid;
  v_nota text;
BEGIN
  IF (c->>'ahora')::time < TIME '15:30' THEN
    f := pg_temp.hp_edit_pasa(f, 'H7 con la hora real (antes de las 15:30)', (n->>'ped')::bigint, p, pg_temp.hp_items(n));
    v_nota := 'H7 · hora real ' || (c->>'ahora') || ' ART, antes de las 15:30: el preventista pasa';
  ELSE
    f := pg_temp.hp_edit_rechazada(f, 'H7 con la hora real (desde las 15:30)', (n->>'ped')::bigint, p,
           pg_temp.hp_items(n), pg_temp.hp_prods(n), pg_temp.hp_pat_horario());
    v_nota := 'H7 · hora real ' || (c->>'ahora') || ' ART, desde las 15:30: el preventista se rechaza';
  END IF;
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'notas', jsonb_build_array(v_nota));
END
$fn$;

-- Mutantes: el caso que cubre la pieza tiene que dejar de rechazar.
CREATE OR REPLACE FUNCTION pg_temp.hp_caso_m1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'm1'); p uuid := (c->>'prev')::uuid;
BEGIN
  PERFORM pg_temp.hp_corte((c->>'ahora')::time);
  PERFORM pg_temp.hp_mutar('>= v_hora_corte', '> v_hora_corte');
  f := pg_temp.hp_edit_pasa(f, 'M1 con ">" en vez de ">=" y corte = ahora tendria que pasar: H2 no muerde',
                            (n->>'ped')::bigint, p, pg_temp.hp_items(n));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_m2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'm2'); p uuid := (c->>'prev')::uuid;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '00:00');
  PERFORM pg_temp.hp_mutar('(now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::time >= v_hora_corte', 'false');
  f := pg_temp.hp_edit_pasa(f, 'M2 sin la clausula de la hora y corte 00:00 tendria que pasar: H3 no muerde',
                            (n->>'ped')::bigint, p, pg_temp.hp_items(n));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.hp_caso_m3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; n jsonb := pg_temp.hp_nuevo(c, 'm3'); p uuid := (c->>'prev')::uuid;
  v_ped bigint := (n->>'ped')::bigint;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '24:00');
  -- La fecha del pedido pasa a ser la de hoy: la clausula de la fecha queda
  -- siempre en falso.
  PERFORM pg_temp.hp_mutar('(v_pedido_created_at AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date',
                           '(now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date');
  PERFORM pg_temp.hp_correr_pedido(v_ped, (SELECT created_at FROM public.pedidos WHERE id = v_ped) - interval '1 day');
  f := pg_temp.hp_edit_pasa(f, 'M3 sin la clausula de la fecha y el pedido de ayer tendria que pasar: H4 no muerde',
                            v_ped, p, pg_temp.hp_items(n));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- M4: la fecha en UTC en vez de ART. Antes de las 21:00 ART el pedido de la
-- medianoche - 1 microsegundo (ayer en ART) cae en el mismo dia UTC que hoy y
-- pasa (lo agarra H4b); desde las 21:00 ART hoy ya es otro dia UTC y el pedido
-- de la medianoche exacta se rechaza (lo agarra H4c).
CREATE OR REPLACE FUNCTION pg_temp.hp_caso_m4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; nb jsonb := pg_temp.hp_nuevo(c, 'm4 b'); nc jsonb := pg_temp.hp_nuevo(c, 'm4 c');
  p uuid := (c->>'prev')::uuid; v_rb jsonb; v_rc jsonb; v_muerde_b boolean; v_muerde_c boolean; v_nota text;
BEGIN
  PERFORM pg_temp.hp_corte(TIME '24:00');
  PERFORM pg_temp.hp_correr_pedido((nb->>'ped')::bigint, (c->>'medianoche')::timestamptz - interval '1 microsecond');
  PERFORM pg_temp.hp_correr_pedido((nc->>'ped')::bigint, (c->>'medianoche')::timestamptz);
  PERFORM pg_temp.hp_mutar('(v_pedido_created_at AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date',
                           '(v_pedido_created_at AT TIME ZONE ''UTC'')::date');
  PERFORM pg_temp.hp_mutar('IS DISTINCT FROM (now() AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date',
                           'IS DISTINCT FROM (now() AT TIME ZONE ''UTC'')::date');
  v_rb := pg_temp.hp_edit((nb->>'ped')::bigint, p, pg_temp.hp_items(nb));
  v_rc := pg_temp.hp_edit((nc->>'ped')::bigint, p, pg_temp.hp_items(nc));
  v_muerde_b := pg_temp.hp_ok(v_rb);      -- H4b rechaza con ART; con UTC pasa
  v_muerde_c := NOT pg_temp.hp_ok(v_rc);  -- H4c pasa con ART; con UTC se rechaza
  f := pg_temp.hp_si(f, v_muerde_b OR v_muerde_c,
                     format('M4 con la fecha en UTC ni H4b ni H4c cambian de resultado: la frontera del dia no muerde (b: %s, c: %s)', v_rb, v_rc));
  v_nota := 'M4 · la frontera del dia mordio ' ||
            CASE WHEN v_muerde_b AND v_muerde_c THEN 'en H4b y en H4c'
                 WHEN v_muerde_b THEN 'en H4b' WHEN v_muerde_c THEN 'en H4c' ELSE 'en ninguno' END;
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'notas', jsonb_build_array(v_nota));
END
$fn$;

DO $ensayo1178$
DECLARE
  v_admin     uuid;
  v_prev      uuid;
  v_enc       uuid;
  v_suc       bigint;
  v_cliente   bigint;
  v_ctx       jsonb;
  v_caso      text;
  v_out       jsonb;
  v_api       text;
  v_grd       text;
  v_ahora     time := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::time;
  v_medianoche timestamptz := date_trunc('day', now() AT TIME ZONE 'America/Argentina/Buenos_Aires')
                              AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_fallas    text[] := '{}';
  v_notas     text[] := '{}';
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
  -- Un cliente que el preventista puede operar y SIN descuentos.
  SELECT id INTO v_cliente FROM clientes cl
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
     AND preventista_id IS NULL AND NOT COALESCE(reservado_admin, false)
     AND COALESCE(descuento_porcentaje, 0) = 0
     AND NOT EXISTS (SELECT 1 FROM cliente_descuentos_categoria d WHERE d.cliente_id = cl.id)
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_prev IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hace falta una sucursal activa con un admin, un preventista y un cliente sin asignar';
  END IF;
  IF v_enc IS NULL THEN
    v_notas := v_notas || 'sin encargado en la sucursal: el preventista hace de encargado en H5'::text;
  END IF;

  v_ctx := jsonb_build_object('suc', v_suc, 'adm', v_admin, 'prev', v_prev, 'enc', v_enc, 'cli', v_cliente,
                              'ahora', v_ahora::text, 'medianoche', v_medianoche::text);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  -- H0 (estructural, sin parche): el corte sigue donde el ensayo lo espera.
  v_api := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  IF regexp_count(v_api, 'v_hora_corte CONSTANT TIME := TIME ''[^'']*''') <> 1
     OR strpos(v_api, 'v_hora_corte CONSTANT TIME := TIME ''15:30''') = 0 THEN
    v_fallas := v_fallas || 'H0 · la constante v_hora_corte de actualizar_pedido_items no aparece una sola vez o ya no vale 15:30: si cambiaste el corte, cambia tambien HORA_CORTE_PREVENTISTA/MINUTO_CORTE_PREVENTISTA en src/utils/permisosPedido.ts y pedido_items_guard_estado'::text;
  END IF;
  IF regexp_count(v_api, '::time >= v_hora_corte') <> 1 THEN
    v_fallas := v_fallas || 'H0 · la comparacion ::time >= v_hora_corte no aparece exactamente una vez en actualizar_pedido_items'::text;
  END IF;
  IF strpos(v_api, 'antes de las 15:30 (ARG)') = 0 THEN
    v_fallas := v_fallas || 'H0 · actualizar_pedido_items perdio el mensaje "antes de las 15:30 (ARG)"'::text;
  END IF;
  SELECT pg_get_functiondef(p.oid) INTO v_grd FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'pedido_items_guard_estado';
  IF v_grd IS NULL OR regexp_count(v_grd, 'TIME ''15:30''') <> 1 THEN
    v_fallas := v_fallas || 'H0 · pedido_items_guard_estado ya no tiene su copia del corte TIME ''15:30'' una sola vez: si cambiaste el corte, cambialo en las dos funciones y en src/utils/permisosPedido.ts'::text;
  END IF;

  FOREACH v_caso IN ARRAY ARRAY['h1', 'h2', 'h3', 'h4', 'h4b', 'h4c', 'h5', 'h6', 'h7', 'm1', 'm2', 'm3', 'm4'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.hp_reset();
      PERFORM pg_temp.hp_como(v_admin);
      EXECUTE format('SELECT pg_temp.hp_caso_%s($1)', v_caso) INTO v_out USING v_ctx;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || left(x, 300)
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
      v_notas := v_notas || ARRAY(SELECT x FROM jsonb_array_elements_text(COALESCE(v_out->'notas', '[]')) x);
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
$ensayo1178$;
