-- Ensayo de #1363 y #1376 (puntos 1 y 2), tarjeta 6 del plan #1389.
--
--   R1 · Rentabilidad: "Vendido" sin regalos y el regalo aparte, en bloques. Un
--        producto vendido y regalado en fracción (3 vendidas, 2 botellas de 6 =
--        0,33), uno que sólo salió como regalo de unidad entera (vendido 0, 2
--        bloques) y el disparador. El total cierra contra `unidades` del gerencial,
--        y el costo del regalo sigue en Costos (2 x 60 / 6 = 20).
--   V1 · sustituir_regalo_pedido mueve `pedidos.updated_at` y devuelve el de antes
--        y el nuevo: la edición con el viejo se rechaza, con el nuevo pasa. El
--        replay idempotente no devuelve versiones ni mueve nada.
--   V2 · lo mismo con dividir_regalo_pedido.
--   F1 · regalo_mueve_stock_foto: el modo de la foto, aunque la promo cambie de
--        tipo; NULL en una línea de venta y fuera de la sucursal activa. Permisos.
--
-- Contra prod sin la migración fallan todos. Corre SIN dejar rastro: cada caso en
-- un subbloque revertido, y todo termina en un RAISE. El veredicto es 'ENSAYO OK'
-- o 'ENSAYO FALLO' en el mensaje. En seco, en una sola transacción con la
-- migración SIN su BEGIN y su COMMIT (con ellos, `-1` la deja aplicada):
--
--   sed '/^BEGIN;$/d; /^COMMIT;$/d' migrations/NNN_regalos_vendido_y_foto.sql > /tmp/nnn.sql
--   psql "$DATABASE_URL" -1 -f /tmp/nnn.sql -f scripts/test-regalos-vendido-y-foto-1363-1376.sql

CREATE OR REPLACE FUNCTION pg_temp.rv_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- Un producto con bolsa y un lote, costo 60 (bolsa > 0 a propósito, nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.rv_prod(p_suc bigint, p_adm uuid, p_cat text)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1363 ' || p_cat, 100, 150, 60, p_suc, 'ZZ ensayo 1363 ' || p_cat)
  RETURNING id INTO v_prod;
  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_adm) RETURNING id INTO v_compra;
  INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                     cantidad_restante, usuario_id, compra_id)
  VALUES (v_prod, p_suc, pg_temp.rv_hoy() + 90, 50, 50, p_adm, v_compra);
  RETURN v_prod;
END
$fn$;

-- "Compra 10, lleva 2" sobre p_disparador. Fracción: bloque de 6, el contenedor es el regalo.
CREATE OR REPLACE FUNCTION pg_temp.rv_promo(p_suc bigint, p_regalo bigint, p_disparador bigint, p_mueve boolean)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, unidades_por_bloque,
                                  stock_por_bloque, ajuste_producto_id)
  VALUES ('ZZ ensayo 1363', 'bonificacion', pg_temp.rv_hoy() - 1, p_suc, p_mueve, p_regalo, NOT p_mueve,
          CASE WHEN NOT p_mueve THEN 6 END, CASE WHEN NOT p_mueve THEN 1 END,
          CASE WHEN NOT p_mueve THEN p_regalo END)
  RETURNING id INTO v;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v, 'cantidad_compra', 10, p_suc), (v, 'cantidad_bonificacion', 2, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v, p_disparador, p_suc);
  RETURN v;
END
$fn$;

-- Cambia el tipo de regalo de la promo, como lo guarda ModalPromocion.
CREATE OR REPLACE FUNCTION pg_temp.rv_cambiar_tipo(p_promo bigint, p_mueve boolean, p_contenedor bigint)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.promociones
     SET regalo_mueve_stock = p_mueve, ajuste_automatico = NOT p_mueve,
         unidades_por_bloque = CASE WHEN NOT p_mueve THEN 6 END,
         stock_por_bloque = CASE WHEN NOT p_mueve THEN 1 END,
         ajuste_producto_id = CASE WHEN NOT p_mueve THEN p_contenedor END
   WHERE id = p_promo;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_alta(p_cli bigint, p_adm uuid, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_adm, p_items, 'ensayo 1363');
  PERFORM pg_temp.rv_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_ok(p_res jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT COALESCE((p_res->>'success')::boolean, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_linea(p_ped bigint, p_prod bigint, p_regalo boolean DEFAULT true)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false) = p_regalo
   ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_editar(p_ped bigint, p_adm uuid, p_items jsonb, p_esperado timestamptz)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm, NULL, p_esperado);
  PERFORM pg_temp.rv_reset();
  RETURN v_res;
END
$fn$;

-- Toda la transacción tiene el mismo now(): la versión leída se corre para atrás.
CREATE OR REPLACE FUNCTION pg_temp.rv_version_vieja(p_ped bigint)
RETURNS timestamptz LANGUAGE sql AS $fn$
  UPDATE public.pedidos SET updated_at = now() - interval '1 hour' WHERE id = p_ped RETURNING updated_at;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_version(p_ped bigint)
RETURNS timestamptz LANGUAGE sql AS $fn$
  SELECT updated_at FROM public.pedidos WHERE id = p_ped;
$fn$;

-- Las dos versiones que devuelve la RPC, contra la fila y la edición.
CREATE OR REPLACE FUNCTION pg_temp.rv_chequear_version(p_f text[], p_que text, p_ped bigint, p_adm uuid,
                                                      p_leida timestamptz, p_res jsonb, p_items jsonb)
RETURNS text[] LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := p_f; v_res jsonb;
BEGIN
  f := pg_temp.rv_si(f, (p_res->>'updated_at_anterior')::timestamptz = p_leida,
                     format('%s: updated_at_anterior %s, esperado %s', p_que, p_res->>'updated_at_anterior', p_leida));
  f := pg_temp.rv_si(f, (p_res->>'updated_at')::timestamptz = pg_temp.rv_version(p_ped)
                        AND pg_temp.rv_version(p_ped) > p_leida,
                     format('%s: no movió la versión (%s, fila %s, leída %s)', p_que, p_res->>'updated_at',
                            pg_temp.rv_version(p_ped), p_leida));
  -- La edición abierta antes se rechaza: ya no disuelve el reparto en silencio.
  v_res := pg_temp.rv_editar(p_ped, p_adm, p_items, p_leida);
  f := pg_temp.rv_si(f, NOT pg_temp.rv_ok(v_res) AND v_res->>'codigo' = 'pedido_editado_por_otro',
                     format('%s: la edición con la versión vieja dio %s, esperado el rechazo', p_que, v_res));
  -- Y con la versión que devolvió la RPC (la que adopta el front) pasa.
  v_res := pg_temp.rv_editar(p_ped, p_adm, p_items, (p_res->>'updated_at')::timestamptz);
  f := pg_temp.rv_si(f, pg_temp.rv_ok(v_res),
                     format('%s: la edición con la versión nueva dio %s, esperado que pase', p_que, v_res));
  RETURN f;
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1363
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rv_caso_r1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; w bigint; r bigint; z bigint; v_frac bigint; v_entera bigint;
  p1 bigint; p2 bigint; v_dia date := pg_temp.rv_hoy() + 401;
  v_t jsonb; v_g jsonb; e jsonb; v_chofer uuid;
BEGIN
  -- La entrega va a nombre de un chofer de la sucursal (el admin no lo es).
  SELECT us.usuario_id INTO v_chofer
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = p_suc AND public._actua_como_transportista(us.usuario_id, p_suc)
   ORDER BY us.usuario_id LIMIT 1;
  IF v_chofer IS NULL THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array('no hay un chofer activo en la sucursal'));
  END IF;

  v := pg_temp.rv_prod(p_suc, p_adm, 'v');
  w := pg_temp.rv_prod(p_suc, p_adm, 'w');
  r := pg_temp.rv_prod(p_suc, p_adm, 'r');
  z := pg_temp.rv_prod(p_suc, p_adm, 'z');
  v_frac   := pg_temp.rv_promo(p_suc, r, v, false);
  v_entera := pg_temp.rv_promo(p_suc, z, w, true);
  p1 := pg_temp.rv_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rv_v(v, 10), pg_temp.rv_v(r, 3),
                                                       pg_temp.rv_r(r, 2, v_frac)));
  p2 := pg_temp.rv_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rv_v(w, 10), pg_temp.rv_r(z, 2, v_entera)));
  UPDATE public.pedidos
     SET estado = 'entregado', transportista_id = v_chofer, fecha = v_dia,
         fecha_entrega = (v_dia + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id IN (p1, p2);

  v_t := public.reporte_rentabilidad(v_dia, v_dia, p_suc);
  v_g := public.reporte_gerencial(p_suc, v_dia, v_dia, false, false);

  e := (SELECT x FROM jsonb_array_elements(v_t->'productos') x WHERE (x->>'id')::bigint = r);
  f := pg_temp.rv_si(f, (e->>'cantidadVendida')::numeric = 3 AND (e->>'cantidadRegalada')::numeric = 0.33,
                     format('vendido y regalado en fracción: %s, esperado Vendido 3 y Regalado 0,33', e));
  f := pg_temp.rv_si(f, (e->'fueraDeCombo'->>'cantidad')::numeric = 3,
                     format('fuera de combo cuenta el regalo: %s', e->'fueraDeCombo'));
  -- Costo: 3 vendidas a 60 y el regalo, 2 botellas de un bloque de 6, a 60 / 6.
  f := pg_temp.rv_si(f, (e->>'costos')::numeric = 200,
                     format('costos %s, esperado 180 + 20', e->>'costos'));

  e := (SELECT x FROM jsonb_array_elements(v_t->'productos') x WHERE (x->>'id')::bigint = z);
  f := pg_temp.rv_si(f, (e->>'cantidadVendida')::numeric = 0 AND (e->>'cantidadRegalada')::numeric = 2
                        AND (e->>'costos')::numeric = 120,
                     format('sólo regalo: %s, esperado Vendido 0, Regalado 2 y costo 120', e));

  e := (SELECT x FROM jsonb_array_elements(v_t->'productos') x WHERE (x->>'id')::bigint = v);
  f := pg_temp.rv_si(f, (e->>'cantidadVendida')::numeric = 10 AND (e->>'cantidadRegalada')::numeric = 0,
                     format('disparador: %s, esperado Vendido 10 y Regalado 0', e));

  f := pg_temp.rv_si(f, (v_t->'totales'->>'unidadesVendidas')::numeric = 23
                        AND (v_g->'kpis'->>'unidades')::numeric = 23,
                     format('unidadesVendidas %s y kpis.unidades %s, esperado 23 los dos',
                            v_t->'totales'->>'unidadesVendidas', v_g->'kpis'->>'unidades'));
  f := pg_temp.rv_si(f, (v_t->'totales'->>'unidadesRegaladas')::numeric = 2.33,
                     format('unidadesRegaladas %s, esperado 2,33', v_t->'totales'->>'unidadesRegaladas'));
  f := pg_temp.rv_si(f, abs((v_t->'totales'->>'costosTotales')::numeric
                            - (v_g->'kpis'->>'cmv')::numeric - (v_g->'kpis'->>'bonif')::numeric) <= 0.01,
                     format('costos %s <> cmv + bonif %s', v_t->'totales'->>'costosTotales',
                            (v_g->'kpis'->>'cmv')::numeric + (v_g->'kpis'->>'bonif')::numeric));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1376, punto 1
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rv_caso_v1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; r bigint; r2 bigint; v_promo bigint; v_ped bigint;
  v_leida timestamptz; v_res jsonb; v_replay jsonb; v_clave uuid := gen_random_uuid();
BEGIN
  v  := pg_temp.rv_prod(p_suc, p_adm, 'v');
  r  := pg_temp.rv_prod(p_suc, p_adm, 'r');
  r2 := pg_temp.rv_prod(p_suc, p_adm, 'r');
  v_promo := pg_temp.rv_promo(p_suc, r, v, true);
  v_ped := pg_temp.rv_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rv_v(v, 10), pg_temp.rv_r(r, 2, v_promo)));
  v_leida := pg_temp.rv_version_vieja(v_ped);

  v_res := public.sustituir_regalo_pedido(pg_temp.rv_linea(v_ped, r), r2, 2, 'ensayo 1363', NULL, v_clave);
  PERFORM pg_temp.rv_reset();
  f := pg_temp.rv_si(f, pg_temp.rv_ok(v_res), format('sustituir: %s', v_res));

  -- El replay no cambió nada: no trae versiones y la fila queda como la dejó.
  UPDATE public.pedidos SET updated_at = now() - interval '30 minutes' WHERE id = v_ped;
  v_replay := public.sustituir_regalo_pedido(pg_temp.rv_linea(v_ped, r2), r2, 2, 'ensayo 1363', NULL, v_clave);
  PERFORM pg_temp.rv_reset();
  f := pg_temp.rv_si(f, (v_replay->>'idempotent_replay')::boolean AND NOT (v_replay ? 'updated_at'),
                     format('el replay dio %s, esperado sin versiones', v_replay));
  f := pg_temp.rv_si(f, pg_temp.rv_version(v_ped) = now() - interval '30 minutes',
                     'el replay movió la versión');
  UPDATE public.pedidos SET updated_at = (v_res->>'updated_at')::timestamptz WHERE id = v_ped;

  f := pg_temp.rv_chequear_version(f, 'sustituir', v_ped, p_adm, v_leida, v_res,
                                   jsonb_build_array(pg_temp.rv_v(v, 10), pg_temp.rv_r(r, 2, v_promo)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_caso_v2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; r bigint; r2 bigint; v_promo bigint; v_ped bigint;
  v_leida timestamptz; v_res jsonb;
BEGIN
  v  := pg_temp.rv_prod(p_suc, p_adm, 'v');
  r  := pg_temp.rv_prod(p_suc, p_adm, 'r');
  r2 := pg_temp.rv_prod(p_suc, p_adm, 'r');
  v_promo := pg_temp.rv_promo(p_suc, r, v, true);
  v_ped := pg_temp.rv_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rv_v(v, 10), pg_temp.rv_r(r, 2, v_promo)));
  v_leida := pg_temp.rv_version_vieja(v_ped);

  v_res := public.dividir_regalo_pedido(pg_temp.rv_linea(v_ped, r),
    jsonb_build_array(jsonb_build_object('producto_id', r, 'cantidad', 1),
                      jsonb_build_object('producto_id', r2, 'cantidad', 1)), 'ensayo 1363');
  PERFORM pg_temp.rv_reset();
  f := pg_temp.rv_si(f, pg_temp.rv_ok(v_res), format('dividir: %s', v_res));

  f := pg_temp.rv_chequear_version(f, 'dividir', v_ped, p_adm, v_leida, v_res,
                                   jsonb_build_array(pg_temp.rv_v(v, 10), pg_temp.rv_r(r, 2, v_promo)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- #1376, punto 2
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rv_foto(p_item bigint)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT public.regalo_mueve_stock_foto(pi) FROM public.pedido_items pi WHERE pi.id = p_item;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rv_caso_f1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; w bigint; r bigint; z bigint; v_frac bigint; v_entera bigint;
  p1 bigint; p2 bigint; v_fn constant text := 'public.regalo_mueve_stock_foto(public.pedido_items)';
  v_headers text := current_setting('request.headers', true);
BEGIN
  v := pg_temp.rv_prod(p_suc, p_adm, 'v');
  w := pg_temp.rv_prod(p_suc, p_adm, 'w');
  r := pg_temp.rv_prod(p_suc, p_adm, 'r');
  z := pg_temp.rv_prod(p_suc, p_adm, 'z');
  v_frac   := pg_temp.rv_promo(p_suc, r, v, false);
  v_entera := pg_temp.rv_promo(p_suc, z, w, true);
  p1 := pg_temp.rv_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rv_v(v, 10), pg_temp.rv_r(r, 2, v_frac)));
  p2 := pg_temp.rv_alta(p_cli, p_adm, jsonb_build_array(pg_temp.rv_v(w, 10), pg_temp.rv_r(z, 2, v_entera)));

  f := pg_temp.rv_si(f, pg_temp.rv_foto(pg_temp.rv_linea(p1, r)) IS FALSE, 'fracción: la foto no dio false');
  f := pg_temp.rv_si(f, pg_temp.rv_foto(pg_temp.rv_linea(p2, z)) IS TRUE, 'unidad entera: la foto no dio true');
  f := pg_temp.rv_si(f, pg_temp.rv_foto(pg_temp.rv_linea(p1, v, false)) IS NULL, 'una línea de venta tiene modo');

  -- Las dos promos cambian de tipo: los pedidos que ya existen no.
  PERFORM pg_temp.rv_cambiar_tipo(v_frac, true, r);
  PERFORM pg_temp.rv_cambiar_tipo(v_entera, false, z);
  f := pg_temp.rv_si(f, pg_temp.rv_foto(pg_temp.rv_linea(p1, r)) IS FALSE,
                     'fracción que pasó a unidad entera: la foto leyó la promo de hoy');
  f := pg_temp.rv_si(f, pg_temp.rv_foto(pg_temp.rv_linea(p2, z)) IS TRUE,
                     'unidad entera que pasó a fracción: la foto leyó la promo de hoy');

  -- Fuera de la sucursal activa no dice nada: puede_leer_pedido la mira.
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', '-1')::text, true);
  f := pg_temp.rv_si(f, pg_temp.rv_foto(pg_temp.rv_linea(p1, r)) IS NULL, 'fuera de la sucursal activa devolvió el modo');
  PERFORM set_config('request.headers', v_headers, true);

  f := pg_temp.rv_si(f, (SELECT prosecdef FROM pg_proc WHERE oid = v_fn::regprocedure), 'no es SECURITY DEFINER');
  f := pg_temp.rv_si(f, NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() a WHERE a.firma LIKE 'regalo_mueve_stock_foto%'),
                     'SEG-A la marca sin guard de rol');
  f := pg_temp.rv_si(f, has_function_privilege('authenticated', v_fn, 'EXECUTE')
                        AND NOT has_function_privilege('anon', v_fn, 'EXECUTE'), 'permisos');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1363$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hace falta un admin activo con una sucursal activa y un cliente activo en ella';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['r1', 'v1', 'v2', 'f1'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.rv_reset();
      EXECUTE format('SELECT pg_temp.rv_caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas):\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK';
END
$ensayo1363$;
