-- Ensayo de cobros por RPC (#1246, #1249) y del lock de monto_pagado (#1247).
--
-- Tienen que rechazarse:
--   G2  · #1246: un INSERT REST en pagos, del preventista (pago a cuenta de
--         500000) y del admin -> 42501 permission denied
--   P1  · #1246: el preventista cobra un pedido que no vendio -> 42501; un
--         cobro sin pedido -> 22023
--   P2  · #1246: monto 0, monto negativo y un sobrepago -> 22023, sin filas
--   P3  · #1249: 'Efectivo', 'cuenta_corriente' y 'adelanto_sueldo' en el cobro
--         de una boleta -> 22023
--   P4  · #1246: fecha futura (admin) -> 22023; ayer (transportista) -> 42501
--   P5  · #1246: el transportista cobra un pedido que no tiene asignado -> 42501
--   P7  · #1246: cobrar un pedido cancelado -> 22023
--   F1  · #1249: el FIFO con 'mp', el masivo con 'otros' y el cambio de forma a
--         'cuenta_corriente' -> 22023
--   F2  · #1249/#1246: como postgres, un pago 'Efectivo' o con monto 0 -> 23514
--   S1  · #1246: el preventista no ve el pago de un cliente reservado que la RLS
--         de clientes le oculta
-- Tienen que pasar:
--   G1  · grants: sin INSERT ni USAGE de la secuencia para authenticated, sin
--         mt_pagos_insert, la RPC con EXECUTE y el _impl sin; los CHECK nuevos
--         VALID y el NOT VALID de la 074 ya no esta
--   P1  · el preventista cobra su pedido; el pago queda con el cliente del pedido
--         y a nombre del preventista
--   P2  · cobrar exacto lo que falta salda la boleta
--   P4  · el admin cobra con fecha de ayer
--   P5  · el transportista cobra el pedido que tiene asignado
--   P6  · el mismo client_request_id dos veces cobra una sola vez
--   F1  · formas_pago() es la lista; el cambio de forma a 'transferencia' anda
--   F2  · los 6 pagos heredados ('combinado', 'cuenta_corriente') se pueden
--         actualizar (con el NOT VALID de la 074 el 'cuenta_corriente' fallaba)
--   S1  · el admin ve ese pago; el preventista ve los de su cliente
--   D1  · desafectar_sobrepago_pedido borra un pago entero sin chocar con el
--         CHECK (monto > 0)
--   L1  · #1247: recalcular_monto_pagado_pedido y aplicar_credito_cliente
--         lockean el pedido (la carrera en si: test-concurrencia-monto-pagado-1247.sql)
--
-- Contra prod sin la migracion falla en G1, G2, P1-P7, F1, F2, S1 y L1; D1 pasa
-- igual.
--
-- Fechas: el cobro por RPC es de hoy (o ayer, el admin). Si la caja de la
-- sucursal esta cerrada desde ayer, el caso la reabre adentro de su subbloque
-- (se revierte). Los pagos de setup van con hoy + 400, como en los otros ensayos.
--
-- Simula PostgREST como test-pedido-baja-1131.sql (el molde): SET LOCAL ROLE,
-- el sub en request.jwt.claims y la sucursal en x-sucursal-id. Corre contra prod
-- SIN dejar rastro: cada caso corre en un subbloque que se revierte, y el final
-- es un RAISE EXCEPTION.
--
--   psql "$DATABASE_URL" -f scripts/test-cobros-por-rpc-1246-1249.sql

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Una sentencia como PostgREST: 'OK <filas>' o 'SQLSTATE mensaje'.
CREATE OR REPLACE FUNCTION pg_temp.t_rest(p_user uuid, p_sql text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_claims text := current_setting('request.jwt.claims', true);
  v_n      bigint;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', v_claims, true);
  RETURN 'OK ' || v_n;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

-- Una RPC (que devuelve jsonb) como PostgREST: su jsonb o {"exception": ...}.
CREATE OR REPLACE FUNCTION pg_temp.t_rpc(p_user uuid, p_sql text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_claims text := current_setting('request.jwt.claims', true);
  v        jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql INTO v;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', v_claims, true);
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('exception', SQLSTATE || ' ' || SQLERRM);
END
$fn$;

-- Como postgres (setup o el duenio de las RPC).
CREATE OR REPLACE FUNCTION pg_temp.t_pg(p_sql text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_n bigint;
BEGIN
  EXECUTE p_sql;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN 'OK ' || v_n;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_rech(p_f text[], p_que text, p_res text, p_code text, p_pat text DEFAULT '%')
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT pg_temp.t_si(p_f, p_res LIKE p_code || ' ' || p_pat,
                      format('%s: se esperaba un rechazo %s y dio "%s"', p_que, p_code, p_res));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_rech_j(p_f text[], p_que text, p_res jsonb, p_code text, p_pat text DEFAULT '%')
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT pg_temp.t_si(p_f, COALESCE(p_res->>'exception', '') LIKE p_code || ' ' || p_pat,
                      format('%s: se esperaba un rechazo %s y dio %s', p_que, p_code, p_res));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_ok_j(p_f text[], p_que text, p_res jsonb)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT pg_temp.t_si(p_f, p_res IS NOT NULL AND p_res->>'exception' IS NULL
                           AND COALESCE((p_res->>'success')::boolean, true),
                      format('%s: tenia que pasar y dio %s', p_que, p_res));
$fn$;

-- El cobro de una boleta como lo arma usePagos.
CREATE OR REPLACE FUNCTION pg_temp.t_sql_cobro(p_ped bigint, p_metodos jsonb, p_fecha date, p_uuid uuid DEFAULT NULL)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date, ''ensayo 1246'', NULL, %L::uuid)',
                COALESCE(p_ped::text, 'NULL'), p_metodos, p_fecha, p_uuid);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_metodo(p_monto numeric, p_forma text DEFAULT 'efectivo')
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('monto', p_monto, 'forma_pago', p_forma));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text, p_reservado boolean DEFAULT false)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id, reservado_admin)
  VALUES (p_nombre, p_nombre, 'Ensayo 1246', p_suc, p_reservado)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1246', 100, 1000, 60, p_suc)
  RETURNING id;
$fn$;

-- Pedido de p_cant x 100, como el admin (setup).
CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1246');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Si la caja esta cerrada desde ayer, se reabre (adentro del subbloque del caso).
CREATE OR REPLACE FUNCTION pg_temp.t_abrir_caja(p_suc bigint)
RETURNS void LANGUAGE sql AS $fn$
  DELETE FROM public.rendiciones_control
   WHERE sucursal_id = p_suc AND fecha >= pg_temp.t_hoy() - 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_ped(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('total', total, 'monto_pagado', monto_pagado, 'estado_pago', estado_pago,
                            'pagos', (SELECT count(*) FROM public.pagos WHERE pedido_id = p_ped),
                            'suma', (SELECT COALESCE(SUM(monto), 0) FROM public.pagos WHERE pedido_id = p_ped))
    FROM public.pedidos WHERE id = p_ped;
$fn$;

-- ---------------------------------------------------------------------------
-- Casos. Firma comun: (admin, transportista, preventista, encargado o NULL, sucursal)
-- ---------------------------------------------------------------------------

-- G1 · grants, policy y constraints.
CREATE OR REPLACE FUNCTION pg_temp.caso_g1(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v_rpc  text := 'public.registrar_pagos_pedido(bigint,jsonb,date,text,text,uuid)';
  v_impl text := 'public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)';
BEGIN
  f := pg_temp.t_si(f, NOT has_table_privilege('authenticated', 'public.pagos', 'INSERT'),
                    'authenticated sigue con INSERT sobre pagos');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'pagos' AND policyname = 'mt_pagos_insert'),
                    'sigue la policy mt_pagos_insert');
  f := pg_temp.t_si(f, NOT has_sequence_privilege('authenticated', 'public.pagos_id_seq', 'USAGE'),
                    'authenticated sigue con USAGE sobre pagos_id_seq');
  f := pg_temp.t_si(f, to_regprocedure(v_rpc) IS NOT NULL AND has_function_privilege('authenticated', v_rpc, 'EXECUTE'),
                    'registrar_pagos_pedido no existe o authenticated no la ejecuta');
  f := pg_temp.t_si(f, to_regprocedure(v_rpc) IS NOT NULL AND NOT has_function_privilege('anon', v_rpc, 'EXECUTE'),
                    'anon ejecuta registrar_pagos_pedido');
  f := pg_temp.t_si(f, to_regprocedure(v_impl) IS NOT NULL AND NOT has_function_privilege('authenticated', v_impl, 'EXECUTE'),
                    'registrar_pagos_pedido_impl no existe o authenticated la ejecuta');
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pagos'::regclass
                                  AND conname = 'pagos_monto_positivo' AND convalidated),
                    'falta CHECK pagos_monto_positivo (VALID)');
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pagos'::regclass
                                  AND conname = 'pagos_forma_pago_valida' AND convalidated),
                    'falta CHECK pagos_forma_pago_valida (VALID)');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pagos'::regclass
                                      AND conname = 'pagos_forma_pago_no_cuenta_corriente'),
                    'sigue el CHECK NOT VALID de la 074');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- G2 · sin INSERT REST.
CREATE OR REPLACE FUNCTION pg_temp.caso_g2(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; r text; c bigint;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 G2');
  r := pg_temp.t_rest(pv, format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, pedido_id, forma_pago, fecha) '
                                 'VALUES (%s, 500000, %s, NULL, ''efectivo'', %L)', c, s, pg_temp.t_hoy()));
  f := pg_temp.t_rech(f, 'preventista: pago a cuenta por REST', r, '42501', '%permission denied%');
  r := pg_temp.t_rest(a, format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, pedido_id, forma_pago, fecha) '
                                'VALUES (%s, 100, %s, NULL, ''efectivo'', %L)', c, s, pg_temp.t_hoy()));
  f := pg_temp.t_rech(f, 'admin: pago por REST', r, '42501', '%permission denied%');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE cliente_id = c), 'entro un pago por REST');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- P1 · rol y cartera del preventista.
CREATE OR REPLACE FUNCTION pg_temp.caso_p1(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_prod bigint; v_suyo bigint; v_ajeno bigint; j jsonb; v_pago RECORD;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 P1');
  v_prod := pg_temp.t_prod(s);
  v_suyo := pg_temp.t_pedido(c, a, v_prod, 1);
  v_ajeno := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET usuario_id = pv WHERE id = v_suyo;

  j := pg_temp.t_rpc(pv, pg_temp.t_sql_cobro(v_ajeno, pg_temp.t_metodo(50), pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'preventista cobra un pedido que no vendio', j, '42501', '%No autorizado%');

  j := pg_temp.t_rpc(pv, pg_temp.t_sql_cobro(NULL, pg_temp.t_metodo(50), pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'cobro sin pedido', j, '22023', '%pago a cuenta%');

  j := pg_temp.t_rpc(pv, pg_temp.t_sql_cobro(v_suyo, pg_temp.t_metodo(50), pg_temp.t_hoy()));
  f := pg_temp.t_ok_j(f, 'preventista cobra su pedido', j);
  SELECT cliente_id, usuario_id, monto INTO v_pago FROM public.pagos WHERE pedido_id = v_suyo;
  f := pg_temp.t_si(f, v_pago.cliente_id = c AND v_pago.usuario_id = pv AND v_pago.monto = 50,
                    format('el pago no quedo con el cliente del pedido y a nombre del preventista: %s', to_jsonb(v_pago)));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ajeno),
                    'entro un pago al pedido ajeno');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- P2 · montos y sobrepago.
CREATE OR REPLACE FUNCTION pg_temp.caso_p2(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 P2');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);

  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(0), pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'monto 0', j, '22023', '%mayor a 0%');
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(-500000), pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'monto negativo', j, '22023', '%mayor a 0%');
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped,
         '[{"monto": 60, "forma_pago": "efectivo"}, {"monto": 50, "forma_pago": "transferencia"}]', pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'sobrepago combinado (110 sobre 100)', j, '22023', '%supera lo que falta%');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped), 'un rechazo dejo filas');

  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped,
         '[{"monto": 60, "forma_pago": "efectivo"}, {"monto": 40, "forma_pago": "transferencia"}]', pg_temp.t_hoy()));
  f := pg_temp.t_ok_j(f, 'cobro exacto combinado', j);
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'estado_pago') = 'pagado'
                       AND (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 100
                       AND (pg_temp.t_ped(v_ped)->>'pagos')::int = 2,
                    format('el cobro exacto no salda la boleta: %s', pg_temp.t_ped(v_ped)));
  f := pg_temp.t_si(f, jsonb_array_length(COALESCE(j->'pagos', '[]')) = 2
                       AND (j->'pagos'->0->>'monto')::numeric = 60,
                    format('la RPC no devolvio las filas: %s', j));
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(1), pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'cobrar una boleta saldada', j, '22023', '%supera lo que falta%');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- P3 · la forma del cobro de una boleta.
CREATE OR REPLACE FUNCTION pg_temp.caso_p3(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb; v_forma text;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 P3');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  FOREACH v_forma IN ARRAY ARRAY['Efectivo', 'cuenta_corriente', 'adelanto_sueldo', 'nota_credito', 'vale_blanco', ''] LOOP
    j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(10, v_forma), pg_temp.t_hoy()));
    f := pg_temp.t_rech_j(f, format('forma "%s"', v_forma), j, '22023', '%orma de pago%');
  END LOOP;
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped), 'una forma invalida dejo filas');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- P4 · la fecha.
CREATE OR REPLACE FUNCTION pg_temp.caso_p4(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_prod bigint; v_ped bigint; v_ped2 bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 P4');
  v_prod := pg_temp.t_prod(s);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 1);
  v_ped2 := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_ped2;

  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(10), pg_temp.t_hoy() + 1));
  f := pg_temp.t_rech_j(f, 'admin con fecha futura', j, '22023', '%no puede ser futura%');
  j := pg_temp.t_rpc(tr, pg_temp.t_sql_cobro(v_ped2, pg_temp.t_metodo(10), pg_temp.t_hoy() - 1));
  f := pg_temp.t_rech_j(f, 'transportista con fecha de ayer', j, '42501', '%Solo un admin%');
  IF en IS NOT NULL THEN
    j := pg_temp.t_rpc(en, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(10), pg_temp.t_hoy() - 1));
    f := pg_temp.t_rech_j(f, 'encargado con fecha de ayer', j, '42501', '%Solo un admin%');
  END IF;
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(10), pg_temp.t_hoy() - 1));
  f := pg_temp.t_ok_j(f, 'admin con fecha de ayer', j);
  f := pg_temp.t_si(f, (SELECT fecha FROM public.pagos WHERE pedido_id = v_ped) = pg_temp.t_hoy() - 1,
                    'el pago del admin no quedo con fecha de ayer');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- P5 · el transportista.
CREATE OR REPLACE FUNCTION pg_temp.caso_p5(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_prod bigint; v_suyo bigint; v_otro bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 P5');
  v_prod := pg_temp.t_prod(s);
  v_suyo := pg_temp.t_pedido(c, a, v_prod, 1);
  v_otro := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_suyo;

  j := pg_temp.t_rpc(tr, pg_temp.t_sql_cobro(v_otro, pg_temp.t_metodo(100), pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'transportista cobra un pedido que no tiene', j, '42501', '%No autorizado%');
  j := pg_temp.t_rpc(tr, pg_temp.t_sql_cobro(v_suyo, pg_temp.t_metodo(100), pg_temp.t_hoy()));
  f := pg_temp.t_ok_j(f, 'transportista cobra su parada', j);
  f := pg_temp.t_si(f, (SELECT usuario_id FROM public.pagos WHERE pedido_id = v_suyo) = tr,
                    'el pago del transportista no quedo a su nombre');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- P6 · idempotencia.
CREATE OR REPLACE FUNCTION pg_temp.caso_p6(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb; v_uuid uuid := gen_random_uuid();
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 P6');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(40), pg_temp.t_hoy(), v_uuid));
  f := pg_temp.t_ok_j(f, 'primer intento', j);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(40), pg_temp.t_hoy(), v_uuid));
  f := pg_temp.t_si(f, COALESCE((j->>'idempotent_replay')::boolean, false),
                    format('el reintento no fue replay: %s', j));
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'suma')::numeric = 40,
                    format('el reintento cobro dos veces: %s', pg_temp.t_ped(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- P7 · pedido cancelado.
CREATE OR REPLACE FUNCTION pg_temp.caso_p7(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb; v_res jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 P7');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1246', a, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, pg_temp.t_metodo(10), pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'cobrar un cancelado', j, '22023', '%no admite pagos%');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- F1 · la lista y las otras RPCs.
CREATE OR REPLACE FUNCTION pg_temp.caso_f1(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; v_pago bigint; j jsonb; v_lista text;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  BEGIN
    SELECT string_agg(forma || ':' || se_registra || ':' || dineraria, ',' ORDER BY forma) INTO v_lista
      FROM public.formas_pago();
  EXCEPTION WHEN OTHERS THEN
    v_lista := SQLERRM;
  END;
  f := pg_temp.t_si(f, v_lista = 'adelanto_sueldo:true:false,cheque:true:true,efectivo:true:true,'
                                 'nota_credito:false:false,tarjeta:true:true,transferencia:true:true',
                    format('formas_pago() no es la lista: %s', v_lista));

  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 F1');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);

  j := pg_temp.t_rpc(a, format('SELECT public.registrar_pago_cliente_fifo(%s, 10, ''mp'', %L::date, NULL, NULL, NULL)',
                               c, pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'FIFO con "mp"', j, '22023', '%Forma de pago invalida%');
  j := pg_temp.t_rpc(a, format('SELECT public.registrar_pago_combinado_cliente_fifo(%s, %L::jsonb, %L::date, NULL, NULL, NULL)',
                               c, '[{"monto": 10, "forma_pago": "Efectivo"}]', pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'combinado con "Efectivo"', j, '22023', '%Forma de pago invalida%');
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.marcar_pagos_masivo(ARRAY[%s]::bigint[], ''otros'', %L::date, NULL))',
                               v_ped, pg_temp.t_hoy()));
  f := pg_temp.t_rech_j(f, 'masivo con "otros"', j, '22023', '%Forma de pago invalida%');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE cliente_id = c), 'una forma invalida dejo filas');

  j := pg_temp.t_rpc(a, format('SELECT public.registrar_pago_cliente_fifo(%s, 30, ''efectivo'', %L::date, NULL, NULL, NULL)',
                               c, pg_temp.t_hoy()));
  f := pg_temp.t_ok_j(f, 'FIFO con "efectivo"', j);
  SELECT id INTO v_pago FROM public.pagos WHERE pedido_id = v_ped;
  j := pg_temp.t_rpc(a, format('SELECT public.actualizar_forma_pago_pago(%s, ''cuenta_corriente'')', v_pago));
  f := pg_temp.t_rech_j(f, 'cambiar la forma a "cuenta_corriente"', j, '22023', '%Forma de pago invalida%');
  j := pg_temp.t_rpc(a, format('SELECT public.actualizar_forma_pago_pago(%s, ''transferencia'')', v_pago));
  f := pg_temp.t_ok_j(f, 'cambiar la forma a "transferencia"', j);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- F2 · los CHECK, tambien como postgres.
CREATE OR REPLACE FUNCTION pg_temp.caso_f2(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; r text; v_heredados bigint;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 F2');
  r := pg_temp.t_pg(format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha) '
                           'VALUES (%s, 10, %s, ''Efectivo'', %L)', c, s, pg_temp.t_hoy() + 400));
  f := pg_temp.t_rech(f, 'postgres: forma "Efectivo"', r, '23514', '%pagos_forma_pago_valida%');
  r := pg_temp.t_pg(format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha) '
                           'VALUES (%s, 10, %s, ''combinado'', %L)', c, s, pg_temp.t_hoy() + 400));
  f := pg_temp.t_rech(f, 'postgres: forma heredada nueva', r, '23514', '%pagos_forma_pago_valida%');
  r := pg_temp.t_pg(format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha) '
                           'VALUES (%s, 0, %s, ''efectivo'', %L)', c, s, pg_temp.t_hoy() + 400));
  f := pg_temp.t_rech(f, 'postgres: monto 0', r, '23514', '%pagos_monto_positivo%');

  SELECT count(*) INTO v_heredados FROM public.pagos WHERE forma_pago IN ('combinado', 'cuenta_corriente');
  r := pg_temp.t_pg('UPDATE public.pagos SET notas = notas WHERE forma_pago IN (''combinado'', ''cuenta_corriente'')');
  f := pg_temp.t_si(f, r = 'OK ' || v_heredados,
                    format('los %s pagos heredados no se pueden actualizar: %s', v_heredados, r));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- S1 · lo que ve el preventista.
CREATE OR REPLACE FUNCTION pg_temp.caso_s1(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_oculto bigint; v_suyo bigint; v_ped bigint; r text;
BEGIN
  v_oculto := pg_temp.t_cliente(s, 'ZZ ensayo 1246 S1 reservado', true);
  v_suyo := pg_temp.t_cliente(s, 'ZZ ensayo 1246 S1 suyo');
  v_ped := pg_temp.t_pedido(v_suyo, a, pg_temp.t_prod(s), 1);
  UPDATE public.pedidos SET usuario_id = pv WHERE id = v_ped;
  INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha, pedido_id)
  VALUES (v_oculto, 100, s, 'efectivo', pg_temp.t_hoy() + 400, NULL),
         (v_suyo, 50, s, 'efectivo', pg_temp.t_hoy() + 400, v_ped);

  r := pg_temp.t_rest(pv, format('SELECT 1 FROM public.pagos WHERE cliente_id = %s', v_oculto));
  f := pg_temp.t_si(f, r = 'OK 0', format('el preventista ve el pago de un cliente reservado: %s', r));
  r := pg_temp.t_rest(a, format('SELECT 1 FROM public.pagos WHERE cliente_id = %s', v_oculto));
  f := pg_temp.t_si(f, r = 'OK 1', format('el admin no ve el pago del reservado: %s', r));
  r := pg_temp.t_rest(pv, format('SELECT 1 FROM public.pagos WHERE cliente_id = %s', v_suyo));
  f := pg_temp.t_si(f, r = 'OK 1', format('el preventista no ve el pago de su cliente: %s', r));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- D1 · desafectar un pago entero con el CHECK (monto > 0).
CREATE OR REPLACE FUNCTION pg_temp.caso_d1(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; r text;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1246 D1');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha, pedido_id)
  VALUES (c, 60, s, 'efectivo', pg_temp.t_hoy() + 400, v_ped);
  INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha, pedido_id)
  VALUES (c, 40, s, 'transferencia', pg_temp.t_hoy() + 400, v_ped);
  -- Baja el total a 50: el de 40 (el mas nuevo) se va entero y al de 60 le sacan 10.
  r := pg_temp.t_pg(format('UPDATE public.pedidos SET total = 50 WHERE id = %s', v_ped));
  f := pg_temp.t_si(f, r = 'OK 1', format('bajar el total fallo: %s', r));
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'suma')::numeric = 50 AND (pg_temp.t_ped(v_ped)->>'pagos')::int = 1,
                    format('desafectar no dejo un pago de 50: %s', pg_temp.t_ped(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- L1 · #1247: el lock, mirado en el cuerpo.
CREATE OR REPLACE FUNCTION pg_temp.caso_l1(a uuid, tr uuid, pv uuid, en uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  f := pg_temp.t_si(f, pg_get_functiondef('public.recalcular_monto_pagado_pedido()'::regprocedure)
                         ~ 'PERFORM 1 FROM pedidos WHERE id = v_id FOR UPDATE',
                    'recalcular_monto_pagado_pedido no lockea el pedido antes de sumar');
  f := pg_temp.t_si(f, pg_get_functiondef('public.aplicar_credito_cliente(bigint,bigint)'::regprocedure)
                         ~ 'LIMIT 1\s+FOR UPDATE',
                    'aplicar_credito_cliente no lockea la boleta que elige');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_tr     uuid;
  v_prev   uuid;
  v_enc    uuid;
  v_suc    bigint;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
  v_rep    text[] := '{}';
BEGIN
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'admin')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'transportista')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'preventista')
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con admin, transportista y preventista activos';
  END IF;
  SELECT us.usuario_id INTO v_admin FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1;
  -- Puros (sin rol extra): las ramas de la policy y de la RPC que interesan.
  SELECT us.usuario_id INTO v_tr FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'transportista'
   ORDER BY (EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)), us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_prev FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'preventista'
   ORDER BY (EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)), us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_enc FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'encargado' ORDER BY us.usuario_id LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['g1', 'g2', 'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'p7', 'f1', 'f2', 's1', 'd1', 'l1'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4, $5)', v_caso)
        INTO v_out USING v_admin, v_tr, v_prev, v_enc, v_suc;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
      IF COALESCE(v_out->>'reporte', '') <> '' THEN
        v_rep := v_rep || (upper(v_caso) || ' · ' || (v_out->>'reporte'));
      END IF;
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %\n\nREPORTE\n%',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_rep, E'\n');
  END IF;
  RAISE NOTICE E'ENSAYO OK\n\nREPORTE\n%', array_to_string(v_rep, E'\n');
END
$ensayo$;

DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
