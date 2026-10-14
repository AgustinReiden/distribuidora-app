-- Ensayo de #1157 y #1159: la ventana de precio anterior se edita por RPC y solo
-- la edita el admin; el precio de venta de quien no es admin tampoco SUBE de la
-- lista (techo dentro de precio_fuera_de_politica). Y #1169: el preventista ya
-- no tiene regla propia de precio al editar (T7).
--
-- Regla (decisiones del dueno, 2026-10-14):
--   * #1157-A: actualizar_ventana_precio_anterior(p_horas integer), SOLO admin,
--     de 0 a 168 horas, upsert por sucursal sellando actualizado_por. Sin
--     EXECUTE para anon ni PUBLIC; authenticated si.
--   * #1159-O2: para quien no es admin y fuera del VB, en el alta y en la
--     edicion: precio <= techo + 0,01, con techo = GREATEST(lista de hoy,
--     precio inmediatamente anterior si califica: dentro de la ventana, > 0 y
--     vigente al menos 15 minutos); en la edicion, ademas, el maximo guardado
--     de la linea. Mensaje terminal, como el del piso.
--   * #1169-A: en actualizar_pedido_items el bloque del preventista conserva el
--     chequeo de creador y el de horario (en ese orden, los dos antes de la
--     politica) y pierde el loop de precio ('Como preventista no puede aumentar
--     precios'). El techo del preventista es el de precio_fuera_de_politica,
--     igual que el del encargado.
--
-- RPC:
--   V1  el admin fija 48 (devuelve 48, la fila queda en 48 con actualizado_por
--       = admin) y 0; encargado y preventista -> 'Acceso denegado: se requiere
--       rol admin'; 169, -1 y NULL -> error y la fila no cambia.
--   V2  anon y PUBLIC sin EXECUTE (aclexplode, grantee 0); authenticated con.
-- Techo:
--   T1  alta, lista 100: preventista a $101 -> rechazo SIN efectos (terminal);
--       a $100,01 pasa; encargado a $101 -> rechazo; admin a $150 pasa.
--   T2  replay tras una baja (4570 vigente 2 h, baja a 4450 hace 1 h): a $4570
--       pasa; a $4580 no.
--   T3  4450 -> 44500 vigente 5 minutos -> 4450: a $44500 -> rechazo (guarda de
--       15 minutos); a $4450 pasa.
--   T4  baja hace 30 h: con ventana de 24 a $4570 -> rechazo; con 48 pasa; con
--       ventana 0 una baja de hace 1 h tambien se rechaza.
--   T5  edicion como encargado (el real si la sucursal tiene uno; si no, el
--       preventista promovido dentro del subbloque revertido; nunca se
--       saltea) sobre un pedido del admin con una linea a $150 sobre lista 100:
--       agregar otro producto a lista pasa (se conserva el guardado); la linea
--       conservada a $151 -> rechazo; un producto nuevo a $101 -> rechazo; los
--       rechazos sin efectos.
--   T6  el mensaje del techo empieza con 'El precio de', dice 'por encima',
--       termina en ' El pedido no se creó.' y es terminal (no calza
--       PATRON_STOCK ni el patron de sesion).
--   T7  edicion como preventista (#1169), sobre un pedido suyo:
--       T7e (siempre) el preventista edita un pedido del admin -> 'Solo el
--           preventista que creo el pedido puede editarlo', sin efectos. Cubre
--           SOLO el chequeo de creador: no prueba el horario ni el orden
--           creador-antes-que-horario por comportamiento. Corre a cualquier hora
--           porque el creador se mira antes que el horario (lo vigila T7-E). No
--           usa regalos, asi que regalo_fuera_de_promo (que corre antes) no
--           interfiere.
--       Pasadas las 15:30 ART el preventista no edita: T7a-T7d se saltean con
--       una nota, y esa corrida no cuenta para aceptar #1169.
--       T7a el admin lleva la linea del preventista a $150 sobre lista 100; el
--           preventista agrega otro producto a lista conservando el $150 -> pasa
--           (maximo guardado).
--       T7b producto a 4570 que bajo a 4450 hace 1 h: el preventista lo agrega
--           a $4570 -> pasa (anterior que califica).
--       T7c el preventista lleva la linea conservada a $151 -> rechazo del
--           techo, sin efectos.
--       T7d el preventista agrega un producto nuevo a $101 -> rechazo del
--           techo, sin efectos.
--   T1-VB (al final, estructural) crear_pedido_completo sigue llamando a
--       precio_fuera_de_politica bajo v_tipo_factura <> 'VB'. Que el VB de un
--       preventista pasa lo cubre R1 de scripts/test-precio-servidor-1138-1139.sql.
--   T7-E (al final, estructural) actualizar_pedido_items ya no menciona 'no
--       puede aumentar precios' ni v_precio_actual; siguen los mensajes de
--       creador y de las 15:30, creador antes que horario y los dos antes de
--       public.precio_fuera_de_politica(. El chequeo horario queda cubierto
--       SOLO estructuralmente: no hay caso de comportamiento pasadas las 15:30.
--
-- Sin las migraciones: V1, V2 y T1-T5 fallan (la funcion no existe, o la venta
-- a $101, $4580, $44500 o $151 pasa). T7 falla: el bloque viejo rechaza T7a y
-- T7b con 'Como preventista no puede aumentar precios', T7c y T7d no calzan el
-- patron del techo, y T7-E ve el mensaje en la funcion. Despues de aplicar,
-- correr tambien entero scripts/test-precio-servidor-1138-1139.sql.
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE.
--
--   psql "$DATABASE_URL" -f scripts/test-politica-precios-1157-1159.sql

-- ---------------------------------------------------------------------------
-- Helpers: los de scripts/test-precio-servidor-1138-1139.sql
-- ---------------------------------------------------------------------------
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
  VALUES ('ZZ ensayo 1159 ' || p_cat, p_precio, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1159 ' || p_cat)
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

CREATE OR REPLACE FUNCTION pg_temp.pp_v(p_prod bigint, p_cant int, p_precio numeric DEFAULT 100)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio);
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
    p_notas => 'ensayo 1159', p_tipo_factura => p_tipo);
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

CREATE OR REPLACE FUNCTION pg_temp.pp_pat_techo() RETURNS text LANGUAGE sql AS
  $fn$ SELECT 'El precio de % está por encima del que permite la lista para este pedido (%). Solo un admin puede cargar otro precio.%' $fn$;

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

-- ---------------------------------------------------------------------------
-- Helpers nuevos
-- ---------------------------------------------------------------------------
-- La RPC de la ventana como p_user: {ok: valor devuelto} o {err: SQLERRM}.
-- Sin la migracion la funcion no existe y vuelve el err del 42883.
CREATE OR REPLACE FUNCTION pg_temp.pp_rpc_ventana(p_user uuid, p_horas integer)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res integer;
BEGIN
  PERFORM pg_temp.pp_como(p_user);
  BEGIN
    EXECUTE 'SELECT public.actualizar_ventana_precio_anterior($1)' INTO v_res USING p_horas;
    RETURN jsonb_build_object('ok', v_res, 'err', NULL);
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', NULL, 'err', SQLERRM);
  END;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_ventana_fila(p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('horas', ventana_precio_anterior_horas, 'por', actualizado_por)
    FROM public.politicas_comerciales WHERE sucursal_id = p_suc;
$fn$;

-- La ventana a mano (como W5 del ensayo 1138-1139): el techo no depende de la RPC.
CREATE OR REPLACE FUNCTION pg_temp.pp_ventana(p_suc bigint, p_horas integer)
RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO public.politicas_comerciales (sucursal_id, ventana_precio_anterior_horas)
  VALUES (p_suc, p_horas)
  ON CONFLICT (sucursal_id) DO UPDATE SET ventana_precio_anterior_horas = EXCLUDED.ventana_precio_anterior_horas;
$fn$;

-- El encargado del caso: el real de la sucursal si hay; si no, el preventista
-- promovido (el UPDATE queda dentro del subbloque del caso, que se revierte con
-- ZZ001). Sin ninguno de los dos, falla: el caso nunca se saltea.
CREATE OR REPLACE FUNCTION pg_temp.pp_encargado(c jsonb)
RETURNS uuid LANGUAGE plpgsql AS $fn$
BEGIN
  IF c->>'enc' IS NOT NULL THEN
    RETURN (c->>'enc')::uuid;
  END IF;
  IF c->>'prev' IS NULL THEN
    RAISE EXCEPTION 'sin encargado ni preventista para hacer de encargado';
  END IF;
  PERFORM pg_temp.pp_como((c->>'adm')::uuid);
  UPDATE public.perfiles SET rol = 'encargado' WHERE id = (c->>'prev')::uuid;
  IF (SELECT rol FROM public.perfiles WHERE id = (c->>'prev')::uuid) IS DISTINCT FROM 'encargado' THEN
    RAISE EXCEPTION 'no se pudo promover al preventista a encargado';
  END IF;
  RETURN (c->>'prev')::uuid;
END
$fn$;

-- ===========================================================================
-- RPC DE LA VENTANA
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_v1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  v_res jsonb; v_fila jsonb; u uuid; h integer; v_quien text;
BEGIN
  v_res := pg_temp.pp_rpc_ventana(a, 48);
  v_fila := pg_temp.pp_ventana_fila(s);
  f := pg_temp.pp_si(f, (v_res->>'ok')::integer = 48, format('el admin fija 48: dio %s', v_res));
  f := pg_temp.pp_si(f, (v_fila->>'horas')::integer = 48 AND v_fila->>'por' = a::text,
                     format('el admin fija 48: la fila quedo %s', v_fila));

  v_res := pg_temp.pp_rpc_ventana(a, 0);
  f := pg_temp.pp_si(f, (v_res->>'ok')::integer = 0 AND (pg_temp.pp_ventana_fila(s)->>'horas')::integer = 0,
                     format('el admin fija 0: dio %s, fila %s', v_res, pg_temp.pp_ventana_fila(s)));

  -- El preventista antes: si no hay encargado, pp_encargado lo promueve.
  FOREACH v_quien IN ARRAY ARRAY['preventista', 'encargado'] LOOP
    u := CASE v_quien WHEN 'preventista' THEN (c->>'prev')::uuid ELSE pg_temp.pp_encargado(c) END;
    v_fila := pg_temp.pp_ventana_fila(s);
    v_res := pg_temp.pp_rpc_ventana(u, 72);
    f := pg_temp.pp_si(f, v_res->>'ok' IS NULL AND v_res->>'err' = 'Acceso denegado: se requiere rol admin',
                       format('%s fija 72: se esperaba el acceso denegado y dio %s', v_quien, v_res));
    f := pg_temp.pp_si(f, pg_temp.pp_ventana_fila(s) = v_fila,
                       format('%s fija 72: la fila cambio a %s', v_quien, pg_temp.pp_ventana_fila(s)));
  END LOOP;

  FOREACH h IN ARRAY ARRAY[169, -1, NULL] LOOP
    v_fila := pg_temp.pp_ventana_fila(s);
    v_res := pg_temp.pp_rpc_ventana(a, h);
    f := pg_temp.pp_si(f, v_res->>'ok' IS NULL AND v_res->>'err' = 'La ventana de precio anterior va de 0 a 168 horas',
                       format('el admin fija %s: se esperaba el error de rango y dio %s', COALESCE(h::text, 'NULL'), v_res));
    f := pg_temp.pp_si(f, pg_temp.pp_ventana_fila(s) = v_fila,
                       format('el admin fija %s: la fila cambio a %s', COALESCE(h::text, 'NULL'), pg_temp.pp_ventana_fila(s)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_v2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_oid oid := to_regprocedure('public.actualizar_ventana_precio_anterior(integer)');
BEGIN
  IF v_oid IS NULL THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array('no existe public.actualizar_ventana_precio_anterior(integer)'));
  END IF;
  f := pg_temp.pp_si(f, NOT has_function_privilege('anon', v_oid, 'EXECUTE'), 'anon tiene EXECUTE');
  f := pg_temp.pp_si(f, NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) x WHERE p.oid = v_oid AND x.grantee = 0),
                     'PUBLIC tiene EXECUTE');
  f := pg_temp.pp_si(f, has_function_privilege('authenticated', v_oid, 'EXECUTE'), 'authenticated no tiene EXECUTE');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ===========================================================================
-- TECHO
-- ===========================================================================
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_t1(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 't1');
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid; v_enc uuid;
BEGIN
  f := pg_temp.pp_alta_rechazada(f, 'preventista a $101', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 101)), ARRAY[v], pg_temp.pp_pat_techo());
  f := pg_temp.pp_alta_pasa(f, 'preventista a $100,01', v_cli, v_prev, jsonb_build_array(pg_temp.pp_v(v, 2, 100.01)));
  v_enc := pg_temp.pp_encargado(c);
  f := pg_temp.pp_alta_rechazada(f, 'encargado a $101', v_cli, v_enc,
         jsonb_build_array(pg_temp.pp_v(v, 2, 101)), ARRAY[v], pg_temp.pp_pat_techo());
  f := pg_temp.pp_alta_pasa(f, 'admin a $150', v_cli, (c->>'adm')::uuid, jsonb_build_array(pg_temp.pp_v(v, 2, 150)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_t2(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 't2', 4570);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 4450 WHERE id = v;
  PERFORM pg_temp.pp_retro('productos', v, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '4570', interval '1 hour');
  f := pg_temp.pp_alta_pasa(f, 'replay a $4570 una hora despues de la baja', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4570)));
  f := pg_temp.pp_alta_rechazada(f, 'a $4580 (encima del anterior)', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4580)), ARRAY[v], pg_temp.pp_pat_techo());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_t3(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 't3', 4450);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 44500 WHERE id = v;
  UPDATE public.productos SET precio = 4450 WHERE id = v;
  PERFORM pg_temp.pp_retro('productos', v, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '4450', interval '65 minutes');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '44500', interval '60 minutes');
  f := pg_temp.pp_alta_rechazada(f, '44500 vigente 5 minutos y venta a $44500', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 44500)), ARRAY[v], pg_temp.pp_pat_techo());
  f := pg_temp.pp_alta_pasa(f, 'a $4450', v_cli, v_prev, jsonb_build_array(pg_temp.pp_v(v, 2, 4450)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_t4(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  v bigint := pg_temp.pp_prod(s, a, 't4 a', 4570); w bigint := pg_temp.pp_prod(s, a, 't4 b', 4570);
  v_cli bigint := (c->>'cli')::bigint; v_prev uuid := (c->>'prev')::uuid;
BEGIN
  UPDATE public.productos SET precio = 4450 WHERE id = v;
  PERFORM pg_temp.pp_retro('productos', v, NULL, NULL, interval '40 hours');
  PERFORM pg_temp.pp_retro('productos', v, 'precio', '4570', interval '30 hours');
  PERFORM pg_temp.pp_ventana(s, 24);
  f := pg_temp.pp_alta_rechazada(f, 'baja hace 30 h con ventana de 24, a $4570', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4570)), ARRAY[v], pg_temp.pp_pat_techo());
  PERFORM pg_temp.pp_ventana(s, 48);
  f := pg_temp.pp_alta_pasa(f, 'baja hace 30 h con ventana de 48, a $4570', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(v, 2, 4570)));

  UPDATE public.productos SET precio = 4450 WHERE id = w;
  PERFORM pg_temp.pp_retro('productos', w, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('productos', w, 'precio', '4570', interval '1 hour');
  PERFORM pg_temp.pp_ventana(s, 0);
  f := pg_temp.pp_alta_rechazada(f, 'baja hace 1 h con ventana 0, a $4570', v_cli, v_prev,
         jsonb_build_array(pg_temp.pp_v(w, 2, 4570)), ARRAY[w], pg_temp.pp_pat_techo());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_t5(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  v bigint := pg_temp.pp_prod(s, a, 't5 v'); w bigint := pg_temp.pp_prod(s, a, 't5 w');
  t bigint := pg_temp.pp_prod(s, a, 't5 t');
  v_enc uuid := pg_temp.pp_encargado(c); v_ped bigint;
BEGIN
  -- El admin vende sobre lista (exento).
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta((c->>'cli')::bigint, a, jsonb_build_array(pg_temp.pp_v(v, 2, 150))),
                             'el alta del admin a $150');
  f := pg_temp.pp_edit_pasa(f, 'encargado agrega otro producto a lista (conserva el $150)', v_ped, v_enc,
         jsonb_build_array(pg_temp.pp_v(v, 2, 150), pg_temp.pp_v(w, 1)));
  f := pg_temp.pp_edit_rechazada(f, 'encargado lleva la linea conservada a $151', v_ped, v_enc,
         jsonb_build_array(pg_temp.pp_v(v, 2, 151), pg_temp.pp_v(w, 1)), ARRAY[v, w], pg_temp.pp_pat_techo());
  f := pg_temp.pp_edit_rechazada(f, 'encargado agrega un producto nuevo a $101', v_ped, v_enc,
         jsonb_build_array(pg_temp.pp_v(v, 2, 150), pg_temp.pp_v(w, 1), pg_temp.pp_v(t, 1, 101)),
         ARRAY[v, w, t], pg_temp.pp_pat_techo());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.pp_caso_t6(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint := pg_temp.pp_prod((c->>'suc')::bigint, (c->>'adm')::uuid, 't6');
  v_res jsonb; v_msg text;
BEGIN
  v_res := pg_temp.pp_alta((c->>'cli')::bigint, (c->>'prev')::uuid, jsonb_build_array(pg_temp.pp_v(v, 2, 120)));
  v_msg := v_res->'errores'->>0;
  f := pg_temp.pp_si(f, NOT pg_temp.pp_ok(v_res) AND v_msg LIKE 'El precio de %' AND v_msg LIKE '%por encima%'
                        AND v_msg LIKE '% El pedido no se creó.',
                     format('el mensaje del techo no tiene la forma esperada: %s', v_res));
  f := pg_temp.pp_si(f, pg_temp.pp_terminal(v_msg), format('el mensaje del techo no es terminal: %s', v_msg));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- T7 (#1169): el preventista edita su pedido; el techo es el de la politica.
CREATE OR REPLACE FUNCTION pg_temp.pp_caso_t7(c jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; s bigint := (c->>'suc')::bigint; a uuid := (c->>'adm')::uuid;
  p uuid := (c->>'prev')::uuid; cli bigint := (c->>'cli')::bigint;
  v bigint := pg_temp.pp_prod(s, a, 't7 v'); w bigint := pg_temp.pp_prod(s, a, 't7 w');
  y bigint := pg_temp.pp_prod(s, a, 't7 y', 4570); t bigint := pg_temp.pp_prod(s, a, 't7 t');
  v_ped bigint; v_ped_adm bigint;
BEGIN
  -- T7e: el chequeo de creador sigue, a cualquier hora.
  v_ped_adm := pg_temp.pp_pedido(pg_temp.pp_alta(cli, a, jsonb_build_array(pg_temp.pp_v(t, 1))), 'el alta del admin');
  f := pg_temp.pp_edit_rechazada(f, 'T7e preventista edita un pedido del admin', v_ped_adm, p,
         jsonb_build_array(pg_temp.pp_v(t, 1), pg_temp.pp_v(w, 1)), ARRAY[t, w],
         'Solo el preventista que creo el pedido puede editarlo%');

  IF (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::time >= TIME '15:30' THEN
    RETURN jsonb_build_object('fallas', to_jsonb(f),
      'notas', jsonb_build_array('T7a-T7d · pasadas las 15:30 ART: el preventista no edita, salteado'));
  END IF;

  -- T7a: el admin le pone $150 a la linea del preventista; el preventista la conserva.
  v_ped := pg_temp.pp_pedido(pg_temp.pp_alta(cli, p, jsonb_build_array(pg_temp.pp_v(v, 2))), 'el alta del preventista');
  f := pg_temp.pp_edit_pasa(f, 'T7a admin lleva v a $150 (exento)', v_ped, a,
         jsonb_build_array(pg_temp.pp_v(v, 2, 150)));
  f := pg_temp.pp_edit_pasa(f, 'T7a preventista agrega w a lista y conserva v a $150', v_ped, p,
         jsonb_build_array(pg_temp.pp_v(v, 2, 150), pg_temp.pp_v(w, 1)));

  -- T7b: y bajo de 4570 a 4450 hace 1 h; el anterior califica.
  UPDATE public.productos SET precio = 4450 WHERE id = y;
  PERFORM pg_temp.pp_retro('productos', y, NULL, NULL, interval '3 hours');
  PERFORM pg_temp.pp_retro('productos', y, 'precio', '4570', interval '1 hour');
  f := pg_temp.pp_edit_pasa(f, 'T7b preventista agrega y a $4570 (anterior que califica)', v_ped, p,
         jsonb_build_array(pg_temp.pp_v(v, 2, 150), pg_temp.pp_v(w, 1), pg_temp.pp_v(y, 1, 4570)));

  -- T7c y T7d: sobre el techo se rechaza, con el mensaje de la politica.
  f := pg_temp.pp_edit_rechazada(f, 'T7c preventista lleva v a $151', v_ped, p,
         jsonb_build_array(pg_temp.pp_v(v, 2, 151), pg_temp.pp_v(w, 1), pg_temp.pp_v(y, 1, 4570)),
         ARRAY[v, w, y], pg_temp.pp_pat_techo());
  f := pg_temp.pp_edit_rechazada(f, 'T7d preventista agrega t a $101', v_ped, p,
         jsonb_build_array(pg_temp.pp_v(v, 2, 150), pg_temp.pp_v(w, 1), pg_temp.pp_v(y, 1, 4570),
                           pg_temp.pp_v(t, 1, 101)),
         ARRAY[v, w, y, t], pg_temp.pp_pat_techo());
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1157$
DECLARE
  v_admin   uuid;
  v_prev    uuid;
  v_enc     uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_ctx     jsonb;
  v_caso    text;
  v_out     jsonb;
  v_cre     text;
  v_api     text;
  v_pos_cre int;
  v_pos_hor int;
  v_pos_pfp int;
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
    v_notas := v_notas || 'sin encargado en la sucursal: el preventista hace de encargado'::text;
  END IF;

  v_ctx := jsonb_build_object('suc', v_suc, 'adm', v_admin, 'prev', v_prev, 'enc', v_enc, 'cli', v_cliente);

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['v1', 'v2', 't1', 't2', 't3', 't4', 't5', 't6', 't7'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.pp_reset();
      PERFORM pg_temp.pp_como(v_admin);
      EXECUTE format('SELECT pg_temp.pp_caso_%s($1)', v_caso) INTO v_out USING v_ctx;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || left(x, 260)
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
      v_notas := v_notas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                    FROM jsonb_array_elements_text(COALESCE(v_out->'notas', '[]')) x);
    END IF;
  END LOOP;

  -- T1-VB: el alta sigue eximiendo al VB (y al admin) antes de llamar al techo.
  SELECT pg_get_functiondef(p.oid) INTO v_cre FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'crear_pedido_completo';
  IF strpos(v_cre, 'IF v_user_role <> ''admin'' AND v_tipo_factura <> ''VB''') = 0
     OR strpos(substr(v_cre, strpos(v_cre, 'IF v_user_role <> ''admin'' AND v_tipo_factura <> ''VB'''), 300),
               'public.precio_fuera_de_politica(p_items, p_cliente_id, v_sucursal, NULL)') = 0 THEN
    v_fallas := v_fallas || 'T1-VB · crear_pedido_completo ya no llama a precio_fuera_de_politica bajo no-admin y no-VB'::text;
  END IF;

  -- T7-E (#1169): sin regla propia de precio del preventista; creador y horario
  -- siguen, en ese orden, antes de la politica.
  v_api := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
  v_pos_cre := strpos(v_api, 'Solo el preventista que creo el pedido puede editarlo');
  v_pos_hor := strpos(v_api, 'antes de las 15:30 (ARG)');
  v_pos_pfp := strpos(v_api, 'public.precio_fuera_de_politica(');
  IF strpos(v_api, 'no puede aumentar precios') > 0 OR strpos(v_api, 'v_precio_actual') > 0 THEN
    v_fallas := v_fallas || 'T7-E · actualizar_pedido_items conserva la regla propia de precio del preventista'::text;
  END IF;
  IF v_pos_cre = 0 OR v_pos_hor = 0 THEN
    v_fallas := v_fallas || 'T7-E · actualizar_pedido_items perdio el chequeo de creador o el de horario'::text;
  ELSIF v_pos_cre >= v_pos_hor THEN
    v_fallas := v_fallas || 'T7-E · el chequeo de creador ya no va antes que el de horario'::text;
  END IF;
  IF v_pos_pfp = 0 OR v_pos_cre >= v_pos_pfp OR v_pos_hor >= v_pos_pfp THEN
    v_fallas := v_fallas || 'T7-E · el chequeo de creador o el de horario va despues de precio_fuera_de_politica'::text;
  END IF;

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
$ensayo1157$;
