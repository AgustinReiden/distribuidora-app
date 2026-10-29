-- Ensayo de #1261: el limite de usos de una promo se hace cumplir al vender.
--
-- Decision del dueno (2026-10-28): un uso es una UNIDAD DE REGALO en las lineas
-- de regalo de la promo de los pedidos no cancelados (subunidades en una promo
-- con fraccion), y no lo pasa nadie, tampoco el admin. Lo cuenta el constraint
-- trigger diferido trg_limite_usos_promo al confirmar la transaccion. Aca se lo
-- fuerza con SET CONSTRAINTS ... IMMEDIATE despues de cada RPC (pg_temp.lu_check),
-- que dispara lo pendiente con el estado final del RPC.
--
--   U1 · limite 5: regalo 3 pasa y la promo sigue activa; otro de 2 llega a 5,
--        pasa y la apaga.
--   U2 · limite 5: regalo 3 y despues 3 -> rechazado, "quedan 2 y este pedido
--        lleva 3". Lo carga el admin: no hay exencion.
--   U3 · limite 5: regalo 5 (la apaga), se cancela el pedido, se reactiva a
--        mano y otro regalo 5 pasa: la cancelacion devolvio el cupo.
--   U4 · limite 5: regalo 5; editar el pedido sin tocar el regalo pasa (la
--        edicion borra y reinserta lineas: el trigger diferido ve el final);
--        editarlo a regalo 6 se rechaza.
--   U5 · promo con fraccion (bloques de 6), limite 10 subunidades: regalo 6
--        pasa; 5 mas se rechaza, "quedan 4 y este pedido lleva 5".
--   U6 · promo sin limite: regalo 50 pasa y la promo sigue activa.
--   U7 · el trigger viejo no esta: subir usos_pendientes por encima del limite
--        no apaga la promo (el contador ya no decide).
--   U8 · las dos funciones de trigger no tienen EXECUTE para anon ni authenticated.
--   U9 · limite 5 con 3 regaladas: bajarlo a 2 se rechaza ("ya regaló 3
--        unidades"); bajarlo justo a 3 pasa y apaga la promo. Asi el conteo
--        nunca arranca pasado, y el trigger rechaza solo lo que suma.
--   U10 · en el limite (5 de 5), editar el pedido a regalo 4 pasa; despues
--        entra 1 (la unidad liberada) y la sexta se rechaza, "quedan 0".
--
-- La concurrencia no se ensaya en una sola transaccion: la serializa el
-- SELECT ... FOR UPDATE de la promo adentro del trigger.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto: 'ENSAYO FALLO (...)' con la lista de fallas, o, si todo pasa, el
-- unico error es 'ENSAYO_ROLLBACK' (el NOTICE dice ENSAYO OK). Para el ensayo
-- en seco de la migracion, las dos en una sola llamada:
--
--   psql "$DATABASE_URL" -1 -f migrations/408_combos_exactos_y_limite_de_usos.sql \
--                           -f scripts/test-limite-usos-1261.sql

CREATE OR REPLACE FUNCTION pg_temp.lu_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lu_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lu_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- Dispara lo que el trigger diferido tenga pendiente y lo vuelve a diferir.
-- NULL si paso; el mensaje si lo rechazo.
CREATE OR REPLACE FUNCTION pg_temp.lu_check()
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  SET CONSTRAINTS public.trg_limite_usos_promo IMMEDIATE;
  SET CONSTRAINTS public.trg_limite_usos_promo DEFERRED;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lu_prod(p_suc bigint, p_nombre text, p_stock int)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1261 ' || p_nombre, 100, p_stock, 60, p_suc)
  RETURNING id;
$fn$;

-- Promo de regalo p_regalo. p_fraccion: modo B con bloques de 6.
CREATE OR REPLACE FUNCTION pg_temp.lu_promo(p_suc bigint, p_regalo bigint, p_limite int, p_fraccion boolean)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, unidades_por_bloque,
                                  stock_por_bloque, ajuste_producto_id, limite_usos)
  VALUES ('ZZ ensayo 1261', 'bonificacion', pg_temp.lu_hoy() - 1, p_suc, NOT p_fraccion, p_regalo,
          p_fraccion, CASE WHEN p_fraccion THEN 6 END, CASE WHEN p_fraccion THEN 1 END,
          CASE WHEN p_fraccion THEN p_regalo END, p_limite)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lu_items(p_venta bigint, p_cant_venta int, p_regalo bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(
    jsonb_build_object('producto_id', p_venta, 'cantidad', p_cant_venta, 'precio_unitario', 100),
    jsonb_build_object('producto_id', p_regalo, 'cantidad', p_cant, 'precio_unitario', 0,
                       'es_bonificacion', true, 'promocion_id', p_promo));
$fn$;

-- El alta: V x10 a $100 mas p_cant de regalo.
CREATE OR REPLACE FUNCTION pg_temp.lu_alta(p_cli bigint, p_adm uuid, p_venta bigint, p_regalo bigint,
                                           p_cant int, p_promo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, 1000, p_adm, pg_temp.lu_items(p_venta, 10, p_regalo, p_cant, p_promo), 'ensayo 1261');
  PERFORM pg_temp.lu_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lu_activa(p_promo bigint)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT activo FROM public.promociones WHERE id = p_promo;
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.caso_u1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U1 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U1 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 5, false);
  e text;
BEGIN
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 3, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('regalo 3 de 5 rechazado: %s', e));
  f := pg_temp.lu_si(f, pg_temp.lu_activa(p), 'con 3 de 5 la promo se apago');
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 2, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('llegar justo a 5 rechazado: %s', e));
  f := pg_temp.lu_si(f, NOT pg_temp.lu_activa(p), 'al llegar a 5 la promo sigue activa');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U2 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U2 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 5, false);
  e text;
BEGIN
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 3, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('el primero (3 de 5) rechazado: %s', e));
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 3, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NOT NULL, 'el admin paso el limite (3 + 3 de 5)');
  f := pg_temp.lu_si(f, e LIKE '%límite de 5 unidades de regalo: quedan 2 y este pedido lleva 3%',
                     format('mensaje inesperado: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U3 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U3 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 5, false);
  v_ped bigint;
  v_res jsonb;
  e text;
BEGIN
  v_ped := pg_temp.lu_alta(p_cli, p_adm, v, r, 5, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL AND NOT pg_temp.lu_activa(p), format('regalo 5 de 5: %s / activa %s', e, pg_temp.lu_activa(p)));
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1261', p_adm, NULL);
  PERFORM pg_temp.lu_reset();
  f := pg_temp.lu_si(f, COALESCE((v_res->>'success')::boolean, false), format('no se pudo cancelar: %s', v_res));
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('cancelar rechazado: %s', e));
  f := pg_temp.lu_si(f, NOT pg_temp.lu_activa(p), 'la cancelacion reactivo la promo sola');
  UPDATE public.promociones SET activo = true WHERE id = p;
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 5, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('tras cancelar, otro regalo 5 rechazado: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U4 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U4 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 5, false);
  v_ped bigint;
  v_res jsonb;
  e text;
BEGIN
  v_ped := pg_temp.lu_alta(p_cli, p_adm, v, r, 5, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('regalo 5 de 5 rechazado: %s', e));

  v_res := public.actualizar_pedido_items(v_ped, pg_temp.lu_items(v, 12, r, 5, p), p_adm);
  PERFORM pg_temp.lu_reset();
  f := pg_temp.lu_si(f, COALESCE((v_res->>'success')::boolean, false), format('editar sin tocar el regalo: %s', v_res));
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('editar sin tocar el regalo rechazado por el limite: %s', e));

  v_res := public.actualizar_pedido_items(v_ped, pg_temp.lu_items(v, 12, r, 6, p), p_adm);
  PERFORM pg_temp.lu_reset();
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, NOT COALESCE((v_res->>'success')::boolean, false) OR e IS NOT NULL,
                     'editar a regalo 6 de 5 paso');
  f := pg_temp.lu_si(f, e IS NULL OR e LIKE '%quedan 5 y este pedido lleva 6%', format('mensaje inesperado: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U5 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U5 regalo fraccion', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 10, true);
  e text;
BEGIN
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 6, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('fraccion: 6 de 10 subunidades rechazado: %s', e));
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 5, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e LIKE '%quedan 4 y este pedido lleva 5%',
                     format('fraccion: 6 + 5 de 10 no se rechazo como se esperaba: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U6 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U6 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, NULL, false);
  e text;
BEGIN
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 50, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('sin limite, regalo 50 rechazado: %s', e));
  f := pg_temp.lu_si(f, pg_temp.lu_activa(p), 'sin limite, la promo se apago');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u7(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  r bigint := pg_temp.lu_prod(p_suc, 'U7 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 5, false);
BEGIN
  UPDATE public.promociones SET usos_pendientes = 99 WHERE id = p;
  f := pg_temp.lu_si(f, pg_temp.lu_activa(p), 'usos_pendientes 99 de 5 apago la promo: el trigger viejo sigue');
  f := pg_temp.lu_si(f, NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_check_promo_limite'),
                     'trg_check_promo_limite sigue existiendo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u9(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U9 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U9 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 5, false);
  e text;
BEGIN
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 3, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('regalo 3 de 5 rechazado: %s', e));
  BEGIN
    UPDATE public.promociones SET limite_usos = 2 WHERE id = p;
    f := f || 'bajar el limite a 2 con 3 ya regaladas paso';
  EXCEPTION WHEN OTHERS THEN
    f := pg_temp.lu_si(f, SQLERRM LIKE '%ya regaló 3 unidades%', format('mensaje al bajar el limite: %s', SQLERRM));
  END;
  UPDATE public.promociones SET limite_usos = 3 WHERE id = p;
  f := pg_temp.lu_si(f, NOT pg_temp.lu_activa(p), 'bajar el limite justo a lo regalado no apago la promo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- En el limite, lo que no suma no se rechaza: la edicion que baja el regalo
-- pasa, y despues entra exactamente lo que libero.
CREATE OR REPLACE FUNCTION pg_temp.caso_u10(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.lu_prod(p_suc, 'U10 venta', 500);
  r bigint := pg_temp.lu_prod(p_suc, 'U10 regalo', 500);
  p bigint := pg_temp.lu_promo(p_suc, r, 5, false);
  v_ped bigint;
  v_res jsonb;
  e text;
BEGIN
  v_ped := pg_temp.lu_alta(p_cli, p_adm, v, r, 5, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('regalo 5 de 5 rechazado: %s', e));
  v_res := public.actualizar_pedido_items(v_ped, pg_temp.lu_items(v, 10, r, 4, p), p_adm);
  PERFORM pg_temp.lu_reset();
  f := pg_temp.lu_si(f, COALESCE((v_res->>'success')::boolean, false), format('editar a regalo 4: %s', v_res));
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('bajar el regalo en el limite rechazado: %s', e));
  UPDATE public.promociones SET activo = true WHERE id = p;
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 1, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e IS NULL, format('la unidad liberada no entro: %s', e));
  PERFORM pg_temp.lu_alta(p_cli, p_adm, v, r, 1, p);
  e := pg_temp.lu_check();
  f := pg_temp.lu_si(f, e LIKE '%quedan 0 y este pedido lleva 1%', format('la sexta unidad no se rechazo: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_u8(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  f := pg_temp.lu_si(f, NOT has_function_privilege('anon', 'public.validar_limite_usos_promo()', 'EXECUTE'),
                     'anon puede ejecutar validar_limite_usos_promo');
  f := pg_temp.lu_si(f, NOT has_function_privilege('authenticated', 'public.validar_limite_usos_promo()', 'EXECUTE'),
                     'authenticated puede ejecutar validar_limite_usos_promo');
  f := pg_temp.lu_si(f, NOT has_function_privilege('anon', 'public.limite_usos_no_baja_de_lo_regalado()', 'EXECUTE'),
                     'anon puede ejecutar limite_usos_no_baja_de_lo_regalado');
  f := pg_temp.lu_si(f, NOT has_function_privilege('authenticated', 'public.limite_usos_no_baja_de_lo_regalado()', 'EXECUTE'),
                     'authenticated puede ejecutar limite_usos_no_baja_de_lo_regalado');
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
  SELECT c.id INTO v_cliente FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['u1', 'u2', 'u3', 'u4', 'u5', 'u6', 'u7', 'u8', 'u9', 'u10'] LOOP
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
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK';
END
$ensayo$;

-- Nada de lo de arriba queda escrito: la transaccion se revierte entera.
DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
