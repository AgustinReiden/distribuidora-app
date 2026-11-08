-- Ensayo de la migración del replay de una salvedad anulada (#1504, punto 2).
--
-- Los casos L fallan sin la migración; los E pasan con y sin ella:
--
--   L1 · Una salvedad de 1 unidad con la clave K entra y un admin la anula. El reintento con K y los mismos datos
--        contesta success false con codigo 'salvedad_anulada', y no mueve ni el total ni el stock.
--   L2 · El reintento con K y otra cantidad también contesta 'salvedad_anulada' (va antes del chequeo de #1327).
--   E1 · La misma salvedad con una clave nueva entra como una salvedad nueva: el total baja y el stock vuelve.
--   E2 · El reintento de una salvedad viva con los mismos datos sigue contestando idempotent_replay, sin mover
--        nada, y con otros datos sigue contestando 'salvedad_ya_registrada'.
--   L3 · El cuerpo y los EXECUTE de registrar_salvedad son los de la migración.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo,
-- sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1,
-- L2 y L3.
--
-- Fixtures: una sucursal activa con un admin activo, un cliente activo que no sea de vale blanco y la caja de hoy
-- abierta. El producto y el pedido nacen en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.sa_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_stock(p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT stock FROM public.productos WHERE id = p_prod;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_total(p_ped bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT total FROM public.pedidos WHERE id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_salvedad(p_ped bigint, p_item bigint, p_cant int, p_clave uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, 'cliente_rechaza', 'ensayo 1504', NULL, true, p_clave);
  PERFORM pg_temp.sa_reset();
  RETURN v_res;
END
$fn$;

-- Un producto de $100 con stock 50 y un pedido de 5 unidades. Devuelve {producto, pedido, item}.
CREATE OR REPLACE FUNCTION pg_temp.sa_pedido(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint;
  v_res  jsonb;
  v_ped  bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1504', 100, 50, 60, p_suc)
  RETURNING id INTO v_prod;
  v_res := public.crear_pedido_completo(
    p_cli, 500, p_adm,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 5, 'precio_unitario', 100)),
    'ensayo 1504');
  PERFORM pg_temp.sa_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('producto', v_prod, 'pedido', v_ped,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod ORDER BY id LIMIT 1));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_caso_l1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f      text[] := '{}';
  x      jsonb := pg_temp.sa_pedido(p_cli, p_adm, p_suc);
  v_ped  bigint := (x->>'pedido')::bigint;
  v_item bigint := (x->>'item')::bigint;
  v_prod bigint := (x->>'producto')::bigint;
  k      uuid := gen_random_uuid();
  v_res  jsonb;
  v_tot  numeric;
  v_stk  int;
  v_n    int;
BEGIN
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 1, k);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la salvedad no entró: %', v_res;
  END IF;
  v_res := public.anular_salvedad((v_res->>'salvedad_id')::bigint, 'ensayo 1504');
  PERFORM pg_temp.sa_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la anulación no entró: %', v_res;
  END IF;
  v_tot := pg_temp.sa_total(v_ped);
  v_stk := pg_temp.sa_stock(v_prod);
  v_n := (SELECT count(*) FROM public.salvedades_items WHERE pedido_id = v_ped);

  v_res := pg_temp.sa_salvedad(v_ped, v_item, 1, k);
  f := pg_temp.sa_si(f, NOT COALESCE((v_res->>'success')::boolean, true) AND v_res->>'codigo' = 'salvedad_anulada',
                     format('el reintento sobre la anulada contestó %s', v_res));
  f := pg_temp.sa_si(f, pg_temp.sa_total(v_ped) = v_tot AND pg_temp.sa_stock(v_prod) = v_stk
                        AND (SELECT count(*) FROM public.salvedades_items WHERE pedido_id = v_ped) = v_n,
                     format('el reintento movió algo: total %s→%s, stock %s→%s', v_tot, pg_temp.sa_total(v_ped),
                            v_stk, pg_temp.sa_stock(v_prod)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_caso_l2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f      text[] := '{}';
  x      jsonb := pg_temp.sa_pedido(p_cli, p_adm, p_suc);
  v_ped  bigint := (x->>'pedido')::bigint;
  v_item bigint := (x->>'item')::bigint;
  k      uuid := gen_random_uuid();
  v_res  jsonb;
BEGIN
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 1, k);
  v_res := public.anular_salvedad((v_res->>'salvedad_id')::bigint, 'ensayo 1504');
  PERFORM pg_temp.sa_reset();
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 2, k);
  f := pg_temp.sa_si(f, NOT COALESCE((v_res->>'success')::boolean, true) AND v_res->>'codigo' = 'salvedad_anulada',
                     format('el reintento con otra cantidad sobre la anulada contestó %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_caso_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f      text[] := '{}';
  x      jsonb := pg_temp.sa_pedido(p_cli, p_adm, p_suc);
  v_ped  bigint := (x->>'pedido')::bigint;
  v_item bigint := (x->>'item')::bigint;
  v_prod bigint := (x->>'producto')::bigint;
  v_res  jsonb;
  v_tot  numeric;
  v_stk  int;
BEGIN
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 1, gen_random_uuid());
  v_res := public.anular_salvedad((v_res->>'salvedad_id')::bigint, 'ensayo 1504');
  PERFORM pg_temp.sa_reset();
  v_tot := pg_temp.sa_total(v_ped);
  v_stk := pg_temp.sa_stock(v_prod);
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 1, gen_random_uuid());
  f := pg_temp.sa_si(f, COALESCE((v_res->>'success')::boolean, false) AND (v_res->>'idempotent_replay') IS NULL,
                     format('la salvedad con clave nueva contestó %s', v_res));
  f := pg_temp.sa_si(f, pg_temp.sa_total(v_ped) = v_tot - 100 AND pg_temp.sa_stock(v_prod) = v_stk + 1,
                     format('la salvedad nueva dejó total %s (esperado %s) y stock %s (esperado %s)',
                            pg_temp.sa_total(v_ped), v_tot - 100, pg_temp.sa_stock(v_prod), v_stk + 1));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_caso_e2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f      text[] := '{}';
  x      jsonb := pg_temp.sa_pedido(p_cli, p_adm, p_suc);
  v_ped  bigint := (x->>'pedido')::bigint;
  v_item bigint := (x->>'item')::bigint;
  v_prod bigint := (x->>'producto')::bigint;
  k      uuid := gen_random_uuid();
  v_res  jsonb;
  v_tot  numeric;
  v_stk  int;
BEGIN
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 1, k);
  v_tot := pg_temp.sa_total(v_ped);
  v_stk := pg_temp.sa_stock(v_prod);
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 1, k);
  f := pg_temp.sa_si(f, COALESCE((v_res->>'success')::boolean, false) AND COALESCE((v_res->>'idempotent_replay')::boolean, false),
                     format('el replay de la viva contestó %s', v_res));
  f := pg_temp.sa_si(f, pg_temp.sa_total(v_ped) = v_tot AND pg_temp.sa_stock(v_prod) = v_stk,
                     'el replay de la viva movió el total o el stock');
  v_res := pg_temp.sa_salvedad(v_ped, v_item, 2, k);
  f := pg_temp.sa_si(f, NOT COALESCE((v_res->>'success')::boolean, true) AND v_res->>'codigo' = 'salvedad_ya_registrada',
                     format('el replay de la viva con otra cantidad contestó %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.sa_caso_l3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  r record;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS a INTO r
    FROM pg_proc
   WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
  f := pg_temp.sa_si(f, r.h = '2319b68994b913717cd3283d4123f823', format('registrar_salvedad tiene el md5 %s', r.h));
  f := pg_temp.sa_si(f, r.a = '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}',
                     format('registrar_salvedad tiene los EXECUTE %s', r.a));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1504$
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
   WHERE EXISTS (SELECT 1 FROM clientes c
                  WHERE c.sucursal_id = us.sucursal_id AND c.activo AND c.tipo_factura_default IS DISTINCT FROM 'VB')
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · hace falta un admin activo con una sucursal activa y un cliente activo en ella';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['l1', 'l2', 'e1', 'e2', 'l3'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.sa_reset();
      EXECUTE format('SELECT pg_temp.sa_caso_%s($1, $2, $3)', v_caso)
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
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas):\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK';
END
$ensayo1504$;
