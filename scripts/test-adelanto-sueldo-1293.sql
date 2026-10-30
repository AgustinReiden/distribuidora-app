-- Ensayo de #1293: el adelanto de sueldo entra sólo por el FIFO de la ficha.
--
-- Decisión del dueño (2026-10-29): `registrar_pagos_pedido` cobra sólo plata, y
-- el adelanto de sueldo va por el FIFO de la ficha (admin y encargado), que lo
-- imputa a la boleta más vieja. El modal no lo ofrece con una boleta elegida
-- (ModalRegistrarPago.adelantoSueldo.test.tsx). Desde Gastos 3/5, además, el
-- trigger `trg_pagos_cuenta_empleado` lo acepta sólo sobre la ficha de un
-- empleado.
--
-- Tienen que pasar:
--   A1 · registrar_pagos_pedido con adelanto_sueldo sobre una boleta se rechaza
--        por la forma (no es plata) y no entra ningún pago.
--   A2 · el FIFO con adelanto sobre un cliente común: con el trigger de Gastos
--        vivo se rechaza con su mensaje; sin el trigger entra, como hasta hoy,
--        y el reporte lo dice.
--   A3 · el FIFO con adelanto sobre la ficha de un empleado entra y se imputa a
--        su boleta. Necesita la tabla `empleados` de Gastos 3/5: sin ella el
--        reporte lo dice.
-- Si la caja de hoy ya está cerrada, A2 y A3 no se pueden correr (el FIFO va con
-- la fecha de hoy) y el reporte lo dice.
--
-- Simula PostgREST como test-rendicion-congelada-1248.sql. Corre contra prod SIN
-- dejar rastro: cada caso corre en un subbloque que se revierte, y el final es
-- un RAISE EXCEPTION.
--
--   psql "$DATABASE_URL" -f scripts/test-adelanto-sueldo-1293.sql

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Una RPC como PostgREST: su resultado (jsonb) o {"exception": ...}.
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

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1293', p_suc)
  RETURNING id;
$fn$;

-- Una boleta de 100 del cliente, como la crea el alta.
CREATE OR REPLACE FUNCTION pg_temp.t_boleta(p_cli bigint, p_admin uuid, p_suc bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint;
  v_res  jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1293', 100, 1000, 60, p_suc)
  RETURNING id INTO v_prod;
  v_res := public.crear_pedido_completo(p_cli, 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 100)), 'ensayo 1293');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_fifo_adelanto(p_user uuid, p_cli bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format(
    'SELECT to_jsonb(public.registrar_pago_cliente_fifo(%s, 100, ''adelanto_sueldo'', %L::date, NULL, ''ensayo 1293''))',
    p_cli, pg_temp.t_hoy()));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_con_trigger_de_gastos()
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.pagos'::regclass AND tgname = 'trg_pagos_cuenta_empleado'
                    AND NOT tgisinternal);
$fn$;

-- ---------------------------------------------------------------------------
-- Casos. Firma común: (admin, sucursal)
-- ---------------------------------------------------------------------------

-- A1 · la boleta elegida se cobra sólo con plata.
CREATE OR REPLACE FUNCTION pg_temp.caso_a1(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1293 A1');
  v_ped := pg_temp.t_boleta(c, a, s);
  j := pg_temp.t_rpc(a, format(
    'SELECT public.registrar_pagos_pedido(%s, ''[{"monto": 100, "forma_pago": "adelanto_sueldo"}]''::jsonb, %L::date)',
    v_ped, pg_temp.t_hoy()));
  f := pg_temp.t_si(f, j->>'exception' LIKE '%Forma de pago invalida: adelanto_sueldo%',
                    format('registrar_pagos_pedido no rechazo el adelanto por la forma: %s', j));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped),
                    'entro un pago a la boleta');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j->>'exception');
END
$fn$;

-- A2 · el FIFO con adelanto sobre un cliente común.
CREATE OR REPLACE FUNCTION pg_temp.caso_a2(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb;
BEGIN
  IF public.ultima_fecha_caja_cerrada(s) >= pg_temp.t_hoy() THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'no corrio: la caja de hoy ya esta cerrada');
  END IF;
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1293 A2');
  v_ped := pg_temp.t_boleta(c, a, s);
  j := pg_temp.t_fifo_adelanto(a, c);
  IF pg_temp.t_con_trigger_de_gastos() THEN
    f := pg_temp.t_si(f, j->>'exception' LIKE '%El adelanto de sueldo es sólo para la ficha de cliente de un empleado%',
                      format('con el trigger de Gastos, el adelanto a un cliente comun no se rechazo: %s', j));
    f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE cliente_id = c),
                      'entro un pago al cliente comun');
    RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', 'con trigger: ' || COALESCE(j->>'exception', j::text));
  END IF;
  f := pg_temp.t_si(f, NOT (j ? 'exception')
                       AND EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped AND forma_pago = 'adelanto_sueldo'),
                    format('sin el trigger de Gastos, el FIFO no imputo el adelanto: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', 'sin el trigger de Gastos 3/5: el adelanto entra, como hasta hoy');
END
$fn$;

-- A3 · el FIFO con adelanto sobre la ficha de un empleado.
CREATE OR REPLACE FUNCTION pg_temp.caso_a3(a uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_ped bigint; j jsonb; v_puesto text;
BEGIN
  IF to_regclass('public.empleados') IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'no corrio: no esta la tabla empleados de Gastos 3/5');
  END IF;
  IF public.ultima_fecha_caja_cerrada(s) >= pg_temp.t_hoy() THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'no corrio: la caja de hoy ya esta cerrada');
  END IF;
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1293 A3');
  v_ped := pg_temp.t_boleta(c, a, s);
  -- Un puesto valido, del CHECK de la tabla de Gastos.
  SELECT (regexp_match(pg_get_constraintdef(co.oid), '''([^'']+)'''))[1] INTO v_puesto
    FROM pg_constraint co
   WHERE co.conrelid = 'public.empleados'::regclass AND co.contype = 'c'
     AND pg_get_constraintdef(co.oid) ~ 'puesto'
   LIMIT 1;
  EXECUTE format('INSERT INTO public.empleados (sucursal_id, nombre, puesto, cliente_id, creado_por) VALUES (%s, %L, %L, %s, %L)',
                 s, 'ZZ ensayo 1293', v_puesto, c, a);
  j := pg_temp.t_fifo_adelanto(a, c);
  f := pg_temp.t_si(f, NOT (j ? 'exception')
                       AND EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped AND forma_pago = 'adelanto_sueldo'
                                     AND monto = 100),
                    format('el adelanto a la ficha de un empleado no se imputo a su boleta: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
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
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'admin')
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con un admin activo';
  END IF;
  SELECT us.usuario_id INTO v_admin FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['a1', 'a2', 'a3'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2)', v_caso) INTO v_out USING v_admin, v_suc;
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
  -- Por el MCP no se ven los NOTICE: el reporte va en la excepcion final.
  RAISE EXCEPTION E'ENSAYO OK\n\nREPORTE\n%', array_to_string(v_rep, E'\n');
END
$ensayo$;
