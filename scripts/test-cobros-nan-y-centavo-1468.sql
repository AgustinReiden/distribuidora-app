-- Ensayo de los cobros con NaN, el centavo de tolerancia y la baja "anulado" (#1468).
--
-- Tienen que rechazarse:
--   N1  · el FIFO con monto NaN o Infinity -> 22023 "no es un número", sin pagos y con
--         la boleta sin tocar
--   N2  · el combinado con un método NaN (solo o junto a uno bueno) -> 22023
--   N3  · el cobro de boleta con un método "NaN" -> 22023
--   N4  · imputar un saldo a favor con monto NaN -> 22023 (antes imputaba el crédito
--         entero)
--   N5  · como postgres, un pago NaN -> 23514 pagos_monto_no_nan
--   C1  · el cobro de boleta de 100,005 sobre una falta de 100 -> 22023 "supera"
-- Tienen que pasar:
--   G1  · _monto_de_cobro existe y es de server; el CHECK está validado; los cuatro
--         _impl lo usan; el cobro de boleta ya no tiene el + 0.005; las dos lecturas
--         dan de baja 'cancelado' y 'anulado'
--   N4  · imputar 30 y después el resto (NULL) siguen andando
--   C1  · 100,004 sobre 100 salda la boleta con un pago de 100,00
--   C2  · el FIFO de 100,004 sobre una boleta de 100 deja un solo pago de 100 (antes
--         el pedazo de 0,004 chocaba con el CHECK); el de 100,005 devuelve el monto
--         redondeado y la suma de los pagos es ese monto
--   C3  · el combinado de 100,004 deja un solo pago de 100
--   B1  · obtener_resumen_cuenta_cliente y reporte_cuentas_por_cobrar no cuentan un
--         pedido anulado
--
-- Contra prod sin la migración falla en G1, N1-N5, C1, C2, C3 y B1.
--
-- Simula PostgREST como test-cobros-por-rpc-1246-1249.sql (el molde): SET LOCAL ROLE,
-- el sub en request.jwt.claims y la sucursal en x-sucursal-id. Corre contra prod SIN
-- dejar rastro: cada caso corre en un subbloque que se revierte, y el final es un
-- RAISE EXCEPTION.
--
--   psql "$DATABASE_URL" -f scripts/test-cobros-nan-y-centavo-1468.sql

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Una RPC como PostgREST: su jsonb o {"exception": ...}.
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

-- Como postgres: 'OK <filas>' o 'SQLSTATE mensaje'.
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

CREATE OR REPLACE FUNCTION pg_temp.t_sql_fifo(p_cli bigint, p_monto text)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('SELECT public.registrar_pago_cliente_fifo(%s, %L::numeric, ''efectivo'')', p_cli, p_monto);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_sql_combinado(p_cli bigint, p_metodos jsonb)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('SELECT public.registrar_pago_combinado_cliente_fifo(%s, %L::jsonb)', p_cli, p_metodos);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_sql_cobro(p_ped bigint, p_metodos jsonb)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date, ''ensayo 1468'', NULL, NULL)',
                p_ped, p_metodos, pg_temp.t_hoy());
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1468', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1468', 100, 1000, 60, p_suc)
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
    'ensayo 1468');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Si la caja está cerrada desde ayer, se reabre (adentro del subbloque del caso).
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

CREATE OR REPLACE FUNCTION pg_temp.t_pagos_cli(p_cli bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('filas', count(*), 'suma', COALESCE(SUM(monto), 0)::text,
                            'a_favor', count(*) FILTER (WHERE pedido_id IS NULL))
    FROM public.pagos WHERE cliente_id = p_cli;
$fn$;

-- ---------------------------------------------------------------------------
-- Casos. Firma común: (admin, sucursal)
-- ---------------------------------------------------------------------------

-- G1 · el helper, el CHECK y los cuerpos.
CREATE OR REPLACE FUNCTION pg_temp.caso_g1(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v_h text := 'public._monto_de_cobro(numeric)';
  v_firma text;
BEGIN
  f := pg_temp.t_si(f, to_regprocedure(v_h) IS NOT NULL, 'no existe _monto_de_cobro');
  IF to_regprocedure(v_h) IS NOT NULL THEN
    f := pg_temp.t_si(f, NOT has_function_privilege('authenticated', v_h, 'EXECUTE')
                         AND NOT has_function_privilege('anon', v_h, 'EXECUTE'),
                      '_monto_de_cobro se puede llamar con una sesión o con la anon key');
  END IF;
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pagos'::regclass
                                  AND conname = 'pagos_monto_no_nan' AND convalidated),
                    'falta CHECK pagos_monto_no_nan (VALID)');
  FOREACH v_firma IN ARRAY ARRAY[
    'public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',
    'public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)',
    'public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)',
    'public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)'] LOOP
    f := pg_temp.t_si(f, pg_get_functiondef(v_firma::regprocedure) ~ '_monto_de_cobro\(',
                      format('%s no pasa el monto por _monto_de_cobro', v_firma));
  END LOOP;
  f := pg_temp.t_si(f, pg_get_functiondef('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)'::regprocedure)
                         !~ 'v_falta \+ 0\.005',
                    'registrar_pagos_pedido_impl sigue con la tolerancia de 0,005');
  FOREACH v_firma IN ARRAY ARRAY['public.obtener_resumen_cuenta_cliente(integer)',
                                 'public.reporte_cuentas_por_cobrar(bigint)'] LOOP
    f := pg_temp.t_si(f, pg_get_functiondef(v_firma::regprocedure) !~ '(IS DISTINCT FROM|<>) ''cancelado''',
                      format('%s sigue dando de baja sólo ''cancelado''', v_firma));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- N1 · el FIFO con NaN e Infinity.
CREATE OR REPLACE FUNCTION pg_temp.caso_n1(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb; v_m text;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 N1');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  FOREACH v_m IN ARRAY ARRAY['NaN', 'Infinity'] LOOP
    j := pg_temp.t_rpc(a, pg_temp.t_sql_fifo(c, v_m));
    f := pg_temp.t_rech_j(f, format('FIFO con %s', v_m), j, '22023', '%no es un número%');
  END LOOP;
  f := pg_temp.t_si(f, (pg_temp.t_pagos_cli(c)->>'filas')::int = 0,
                    format('el FIFO con NaN dejó pagos: %s', pg_temp.t_pagos_cli(c)));
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 0,
                    format('el FIFO con NaN saldó la boleta: %s', pg_temp.t_ped(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- N2 · el combinado con un método NaN.
CREATE OR REPLACE FUNCTION pg_temp.caso_n2(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 N2');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_combinado(c, '[{"monto": "NaN", "forma_pago": "efectivo"}]'));
  f := pg_temp.t_rech_j(f, 'combinado con un NaN', j, '22023', '%no es un número%');
  j := pg_temp.t_rpc(a, pg_temp.t_sql_combinado(c,
         '[{"monto": 50, "forma_pago": "efectivo"}, {"monto": "NaN", "forma_pago": "transferencia"}]'));
  f := pg_temp.t_rech_j(f, 'combinado con 50 y un NaN', j, '22023', '%no es un número%');
  f := pg_temp.t_si(f, (pg_temp.t_pagos_cli(c)->>'filas')::int = 0
                       AND (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 0,
                    format('el combinado con NaN dejó pagos: %s', pg_temp.t_pagos_cli(c)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- N3 · el cobro de boleta con un "NaN".
CREATE OR REPLACE FUNCTION pg_temp.caso_n3(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 N3');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, '[{"monto": "NaN", "forma_pago": "efectivo"}]'));
  f := pg_temp.t_rech_j(f, 'cobro de boleta con NaN', j, '22023', '%no es un número%');
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'pagos')::int = 0,
                    format('el cobro con NaN dejó pagos: %s', pg_temp.t_ped(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- N4 · imputar un saldo a favor con NaN; con monto y sin monto sigue andando.
CREATE OR REPLACE FUNCTION pg_temp.caso_n4(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; v_pago bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 N4');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha, pedido_id, a_cuenta)
  VALUES (c, 50, s, 'efectivo', pg_temp.t_hoy(), NULL, true) RETURNING id INTO v_pago;

  j := pg_temp.t_rpc(a, format('SELECT public.imputar_credito_a_pedido(%s, %s, %L::numeric)', v_pago, v_ped, 'NaN'));
  f := pg_temp.t_rech_j(f, 'imputar NaN', j, '22023', '%no es un número%');
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 0,
                    format('imputar NaN imputó: %s', pg_temp.t_ped(v_ped)));

  j := pg_temp.t_rpc(a, format('SELECT public.imputar_credito_a_pedido(%s, %s, 30)', v_pago, v_ped));
  f := pg_temp.t_ok_j(f, 'imputar 30', j);
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 30,
                    format('imputar 30 no dejó 30 en la boleta: %s', pg_temp.t_ped(v_ped)));
  j := pg_temp.t_rpc(a, format('SELECT public.imputar_credito_a_pedido(%s, %s)', v_pago, v_ped));
  f := pg_temp.t_ok_j(f, 'imputar el resto (NULL)', j);
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 50,
                    format('imputar el resto no dejó 50 en la boleta: %s', pg_temp.t_ped(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- N5 · el CHECK: un pago NaN no entra ni como postgres.
CREATE OR REPLACE FUNCTION pg_temp.caso_n5(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; r text;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 N5');
  r := pg_temp.t_pg(format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, fecha, a_cuenta) '
                           'VALUES (%s, ''NaN''::numeric, %s, ''efectivo'', %L, true)', c, s, pg_temp.t_hoy() + 400));
  f := pg_temp.t_rech(f, 'INSERT de un pago NaN', r, '23514', '%pagos_monto_no_nan%');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- C1 · el cobro de boleta sin tolerancia, al centavo.
CREATE OR REPLACE FUNCTION pg_temp.caso_c1(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 C1');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, '[{"monto": 100.005, "forma_pago": "efectivo"}]'));
  f := pg_temp.t_rech_j(f, '100,005 sobre 100', j, '22023', '%supera lo que falta%');
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'pagos')::int = 0,
                    format('100,005 dejó pagos: %s', pg_temp.t_ped(v_ped)));

  j := pg_temp.t_rpc(a, pg_temp.t_sql_cobro(v_ped, '[{"monto": 100.004, "forma_pago": "efectivo"}]'));
  f := pg_temp.t_ok_j(f, '100,004 sobre 100', j);
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'suma')::numeric = 100
                       AND (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 100
                       AND (pg_temp.t_ped(v_ped)->>'estado_pago') = 'pagado'
                       AND (j->>'monto_total')::numeric = 100,
                    format('100,004 no saldó la boleta con 100,00: %s / %s', pg_temp.t_ped(v_ped), j->>'monto_total'));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- C2 · el FIFO al centavo.
CREATE OR REPLACE FUNCTION pg_temp.caso_c2(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; c2 bigint; v_prod bigint; v_ped bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  v_prod := pg_temp.t_prod(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 C2a');
  v_ped := pg_temp.t_pedido(c, a, v_prod, 1);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_fifo(c, '100.004'));
  f := pg_temp.t_ok_j(f, 'FIFO de 100,004 sobre 100', j);
  f := pg_temp.t_si(f, (pg_temp.t_pagos_cli(c)->>'filas')::int = 1
                       AND (pg_temp.t_pagos_cli(c)->>'suma')::numeric = 100
                       AND (pg_temp.t_ped(v_ped)->>'estado_pago') = 'pagado'
                       AND (j->>'monto_total')::numeric = 100,
                    format('el FIFO de 100,004 no dejó un solo pago de 100: %s / %s', pg_temp.t_pagos_cli(c), j));

  c2 := pg_temp.t_cliente(s, 'ZZ ensayo 1468 C2b');
  PERFORM pg_temp.t_pedido(c2, a, v_prod, 1);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_fifo(c2, '100.005'));
  f := pg_temp.t_ok_j(f, 'FIFO de 100,005 sobre 100', j);
  f := pg_temp.t_si(f, (j->>'monto_total')::numeric = 100.01
                       AND (pg_temp.t_pagos_cli(c2)->>'suma')::numeric = 100.01
                       AND (j->>'sobrante')::numeric = 0.01,
                    format('el FIFO de 100,005 no cierra contra el monto redondeado: %s / %s', pg_temp.t_pagos_cli(c2), j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- C3 · el combinado al centavo.
CREATE OR REPLACE FUNCTION pg_temp.caso_c3(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb;
BEGIN
  PERFORM pg_temp.t_abrir_caja(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 C3');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  j := pg_temp.t_rpc(a, pg_temp.t_sql_combinado(c, '[{"monto": 100.004, "forma_pago": "efectivo"}]'));
  f := pg_temp.t_ok_j(f, 'combinado de 100,004 sobre 100', j);
  f := pg_temp.t_si(f, (pg_temp.t_pagos_cli(c)->>'filas')::int = 1
                       AND (pg_temp.t_pagos_cli(c)->>'suma')::numeric = 100
                       AND (j->>'monto_total')::numeric = 100,
                    format('el combinado de 100,004 no dejó un solo pago de 100: %s / %s', pg_temp.t_pagos_cli(c), j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- B1 · un pedido anulado no cuenta en la cuenta del cliente ni en cuentas por cobrar.
CREATE OR REPLACE FUNCTION pg_temp.caso_b1(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_prod bigint; v_anul bigint; r text; j jsonb; v_fila jsonb;
BEGIN
  v_prod := pg_temp.t_prod(s);
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1468 B1');
  PERFORM pg_temp.t_pedido(c, a, v_prod, 1);
  v_anul := pg_temp.t_pedido(c, a, v_prod, 2);
  r := pg_temp.t_pg(format('UPDATE public.pedidos SET estado = ''anulado'' WHERE id = %s', v_anul));
  f := pg_temp.t_si(f, r = 'OK 1', format('no se pudo anular el pedido de setup: %s', r));

  j := pg_temp.t_rpc(a, format('SELECT public.obtener_resumen_cuenta_cliente(%s)::jsonb', c));
  f := pg_temp.t_si(f, j->>'exception' IS NULL
                       AND (j->>'total_pedidos')::int = 1
                       AND (j->>'total_compras')::numeric = 100
                       AND (j->>'pedidos_pendientes_pago')::int = 1,
                    format('el resumen cuenta el pedido anulado: %s', j));

  j := pg_temp.t_rpc(a, format('SELECT public.reporte_cuentas_por_cobrar(%s)', s));
  SELECT x INTO v_fila FROM jsonb_array_elements(COALESCE(j->'clientes', '[]')) x
   WHERE (x->'cliente'->>'id')::bigint = c;
  f := pg_temp.t_si(f, j->>'exception' IS NULL AND v_fila IS NOT NULL
                       AND (v_fila->>'pedidosPendientes')::int = 1
                       AND (v_fila->>'saldoPendiente')::numeric = 100,
                    format('cuentas por cobrar cuenta el pedido anulado: %s', COALESCE(v_fila::text, left(j::text, 300))));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', COALESCE(v_fila::text, ''));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
  v_rep    text[] := '{}';
BEGIN
  SELECT s.id, us.usuario_id INTO v_suc, v_admin
    FROM sucursales s
    JOIN usuario_sucursales us ON us.sucursal_id = s.id
    JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo AND pf.rol = 'admin'
   WHERE s.activa
   ORDER BY s.id, us.usuario_id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con un admin activo';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['g1', 'n1', 'n2', 'n3', 'n4', 'n5', 'c1', 'c2', 'c3', 'b1'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2)', v_caso)
        INTO v_out USING v_admin, v_suc;
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
