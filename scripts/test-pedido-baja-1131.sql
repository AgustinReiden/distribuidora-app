-- Ensayo de #1131 y #1133: la baja de un pedido no se deshace, no se escribe
-- por REST, no se entra en 'cancelado' sin motivo y un pago no se imputa a un
-- pedido de baja. Mas los dos ajustes de datos (1856 y 629).
--
-- Tienen que rechazarse (y la foto de stock y del pedido no cambia):
--   R1  · admin por REST: cancelado -> asignado y cancelado -> entregado (el 1856)
--   R2  · transportista por REST, sobre un cancelado que conserva su
--         transportista_id: -> entregado
--   R3  · preventista duenio por REST: vivo -> cancelado, vivo -> anulado,
--         escribir motivo, escribir motivo_tipo
--   R4  · admin por REST: vivo -> cancelado, escribir el motivo
--   R5  · como postgres: cancelado -> pendiente (regla 1); motivo sobre un vivo
--         (CHECK); estado = 'cancelado' sin motivo (regla 5)
--   R6  · cancelar_pedido_con_stock sobre un 'anulado' armado como postgres
--   R7  · INSERT con estado cancelado o con motivo: authenticated no tiene
--         INSERT en pedidos desde la 361 (42501 de grant); el guard se prueba
--         con service_role, y el control (el INSERT sin baja ni motivo) pasa
--         como service_role
--   R8  · pago por REST sobre un cancelado, como admin y como el transportista
--         que lo conserva (22023), y UPDATE pagos SET pedido_id = <cancelado>:
--         42501 de grant como authenticated, y el guard 22023 como postgres
--   R9  · cancelar_pedido_con_stock con p_motivo NULL y con '  '
--   R10 · service_role por REST: vivo -> cancelado, escribir el motivo
-- Tienen que pasar (regresion):
--   P1  · admin por REST: asignado -> entregado (con fecha_entrega), entregado
--         -> asignado, pendiente <-> en_preparacion, asignar y quitar transportista
--   P2  · transportista por REST: asignado -> entregado
--   P3  · preventista duenio por REST: UPDATE de notas
--   P4  · cancelar_pedido_con_stock normal y con falta_stock;
--         cambiar_cliente_pedido sin p_motivo (el viejo queda con 'Cambio de
--         cliente -> pedido #' y el pago viaja al nuevo); un VB entregado que se
--         cancela; aplicar_orden_ruta saltea el cancelado, marcar_no_entregado y
--         marcar_entregas_masivo; crear_pedido_completo
--   P5  · pago por REST sobre un vivo; la cancelacion lo desimputa
--   P6  · idempotencia de la 167: pago por REST con client_request_id sobre un
--         vivo, se cancela, el reintento con el mismo UUID da 23505 (no 22023)
--         y no duplica; con un UUID nuevo sigue el 22023, y reapuntar ese pago
--         al cancelado: 42501 de grant como authenticated, 22023 (el guard)
--         como postgres
-- Datos:
--   D1  · el 1856 sin motivo, con una sola fila de historial de motivo y
--         cobrado igual; el 629 con sus dos filas 'correccion_incidente' (+1 del
--         92 y +1 del 134), sin lotes; STK-F y STK-D en verde
--
-- Desde la 361 authenticated no tiene INSERT en pedidos ni UPDATE en pagos
-- (service_role si el INSERT): lo que antes cortaba el trigger por REST ahora
-- corta el grant, y los guards se prueban por un camino que si llega a ellos.
--
-- La bolsa es distinta de 0 en todos los fixtures (CLAUDE.md).
--
-- Simula PostgREST como test-compras-rest-1124.sql: SET LOCAL ROLE, el sub en
-- request.jwt.claims y la sucursal en x-sucursal-id.
--
-- Corre contra prod SIN dejar rastro: cada caso corre en un subbloque que se
-- revierte y todo termina en un RAISE EXCEPTION. Veredicto en el mensaje:
-- 'ENSAYO OK' o 'ENSAYO FALLO'. Contra prod sin la migracion tiene que dar
-- FALLO; con la migracion, OK.
--
--   psql "$DATABASE_URL" -f scripts/test-pedido-baja-1131.sql

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_prod bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'stock', pr.stock,
    'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                         FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
    'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                    FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int)
    FROM public.productos pr WHERE pr.id = p_prod;
$fn$;

-- La foto del pedido que una baja mal hecha cambiaria.
CREATE OR REPLACE FUNCTION pg_temp.t_ped(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('estado', estado, 'motivo', motivo_cancelacion, 'tipo', motivo_cancelacion_tipo,
                            'monto_pagado', monto_pagado, 'estado_pago', estado_pago, 'total', total)
    FROM public.pedidos WHERE id = p_ped;
$fn$;

-- Producto con lotes ([{dias, cantidad, restante}]) y `p_bolsa` unidades sin lote.
CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_admin uuid, p_lotes jsonb, p_bolsa int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
  l        jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1131', 100,
          p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;

  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;

  FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.t_hoy() + (l->>'dias')::int, (l->>'cantidad')::int,
            (l->>'restante')::int, p_admin, v_compra);
  END LOOP;
  RETURN v_prod;
END
$fn$;

-- El producto estandar: L2 vacio que vence antes, L1 100/50, bolsa 40 (stock 90).
CREATE OR REPLACE FUNCTION pg_temp.t_prod_std(p_suc bigint, p_admin uuid)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT pg_temp.t_prod(p_suc, p_admin,
           '[{"dias":30,"cantidad":50,"restante":0},{"dias":90,"cantidad":100,"restante":50}]', 40);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1131');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cancelar(p_ped bigint, p_adm uuid, p_tipo text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1131', p_adm, p_tipo);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
END
$fn$;

-- Asignado a un transportista, como postgres (setup).
CREATE OR REPLACE FUNCTION pg_temp.t_asignar(p_ped bigint, p_tr uuid)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = p_tr WHERE id = p_ped;
$fn$;

-- Una sentencia como PostgREST con el rol y el usuario dados: 'OK <filas>' o
-- 'SQLSTATE mensaje'. Si falla, el subbloque revierte el rol y los claims.
CREATE OR REPLACE FUNCTION pg_temp.t_rest(p_user uuid, p_rol text, p_sql text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_claims text := current_setting('request.jwt.claims', true);
  v_n      bigint;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', p_rol)::text, true);
  EXECUTE format('SET LOCAL ROLE %I', p_rol);
  EXECUTE p_sql;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', v_claims, true);
  RETURN 'OK ' || v_n;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

-- Lo mismo como postgres (el duenio de las RPC, o una migracion).
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

-- Una RPC que devuelve jsonb, como postgres con los claims vigentes: su jsonb o
-- {"exception": "SQLSTATE mensaje"}.
CREATE OR REPLACE FUNCTION pg_temp.t_rpc(p_sql text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v jsonb;
BEGIN
  EXECUTE p_sql INTO v;
  RETURN v;
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('exception', SQLSTATE || ' ' || SQLERRM);
END
$fn$;

-- Se esperaba un rechazo con `p_code` (y, si se da, un mensaje que matchee).
CREATE OR REPLACE FUNCTION pg_temp.t_rech(p_f text[], p_que text, p_res text, p_code text, p_pat text DEFAULT '%')
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT pg_temp.t_si(p_f, p_res LIKE p_code || ' ' || p_pat,
                      format('%s: se esperaba un rechazo %s y dio "%s"', p_que, p_code, p_res));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pasa(p_f text[], p_que text, p_res text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT pg_temp.t_si(p_f, p_res = 'OK 1', format('%s: tenia que pasar (1 fila) y dio "%s"', p_que, p_res));
$fn$;

-- La foto del producto y del pedido no cambiaron.
CREATE OR REPLACE FUNCTION pg_temp.t_igual(p_f text[], p_que text, p_prod bigint, p_f0 jsonb, p_ped bigint, p_e0 jsonb)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT pg_temp.t_si(pg_temp.t_si(p_f,
           pg_temp.t_foto(p_prod) = p_f0,
           format('%s: el stock cambio %s -> %s', p_que, p_f0, pg_temp.t_foto(p_prod))),
         pg_temp.t_ped(p_ped) = p_e0,
         format('%s: el pedido cambio %s -> %s', p_que, p_e0, pg_temp.t_ped(p_ped)));
$fn$;

-- Un pago a mano como postgres (setup).
CREATE OR REPLACE FUNCTION pg_temp.t_pago(p_cli bigint, p_suc bigint, p_ped bigint, p_monto numeric)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.pagos (cliente_id, monto, sucursal_id, pedido_id, forma_pago, notas)
  VALUES (p_cli, p_monto, p_suc, p_ped, 'efectivo', 'ensayo 1131') RETURNING id INTO v;
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_sql_pago(p_cli bigint, p_suc bigint, p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, pedido_id, forma_pago, notas) '
                'VALUES (%s, 100, %s, %s, ''efectivo'', ''ensayo 1131'')', p_cli, p_suc, p_ped);
$fn$;

-- ---------------------------------------------------------------------------
-- Casos. Firma comun: (cliente, cliente2, admin, transportista, preventista, sucursal)
-- ---------------------------------------------------------------------------

-- R1 · admin por REST saca un cancelado de la baja.
CREATE OR REPLACE FUNCTION pg_temp.caso_r1(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; r text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  PERFORM pg_temp.t_cancelar(v_ped, a);
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  r := pg_temp.t_rest(a, 'authenticated', format('UPDATE public.pedidos SET estado = ''asignado'' WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'admin REST cancelado -> asignado', r, '42501', '%una baja no se deshace%');
  r := pg_temp.t_rest(a, 'authenticated',
         format('UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = now() WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'admin REST cancelado -> entregado', r, '42501', '%una baja no se deshace%');
  f := pg_temp.t_igual(f, 'R1', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- R2 · el transportista que el cancelado conserva lo marca entregado.
CREATE OR REPLACE FUNCTION pg_temp.caso_r2(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; r text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  PERFORM pg_temp.t_asignar(v_ped, tr);
  PERFORM pg_temp.t_cancelar(v_ped, a);
  IF (SELECT transportista_id FROM public.pedidos WHERE id = v_ped) IS DISTINCT FROM tr THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array('punto de partida: el cancelado no conserva el transportista'));
  END IF;
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  r := pg_temp.t_rest(tr, 'authenticated',
         format('UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = now(), updated_at = now() WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'transportista REST cancelado -> entregado', r, '42501', '%una baja no se deshace%');
  f := pg_temp.t_igual(f, 'R2', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- R3 · el preventista duenio da de baja o escribe el motivo por REST.
CREATE OR REPLACE FUNCTION pg_temp.caso_r3(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; r text; v_sql text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  UPDATE public.pedidos SET usuario_id = pv WHERE id = v_ped;
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  FOREACH v_sql IN ARRAY ARRAY['estado = ''cancelado''', 'estado = ''anulado''',
                               'motivo_cancelacion = ''ensayo''', 'motivo_cancelacion_tipo = ''otro'''] LOOP
    r := pg_temp.t_rest(pv, 'authenticated', format('UPDATE public.pedidos SET %s WHERE id = %s', v_sql, v_ped));
    f := pg_temp.t_rech(f, 'preventista REST ' || v_sql, r, '42501');
  END LOOP;
  f := pg_temp.t_igual(f, 'R3', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- R4 · admin por REST da de baja un vivo o le escribe el motivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_r4(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; r text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  r := pg_temp.t_rest(a, 'authenticated',
         format('UPDATE public.pedidos SET estado = ''cancelado'', motivo_cancelacion = ''x'' WHERE id = %s', v_ped));
  -- Desde #1151 (UPDATE de pedidos por columna) motivo_cancelacion no tiene
  -- grant: el corte puede ser el del grant y no el del trigger.
  f := pg_temp.t_si(f, r LIKE '42501 %Cancelar pedido%' OR r LIKE '42501 permission denied for table pedidos%',
                    format('admin REST vivo -> cancelado (con motivo): se esperaba un rechazo 42501 y dio "%s"', r));
  r := pg_temp.t_rest(a, 'authenticated', format('UPDATE public.pedidos SET estado = ''cancelado'' WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'admin REST vivo -> cancelado', r, '42501', '%Cancelar pedido%');
  r := pg_temp.t_rest(a, 'authenticated', format('UPDATE public.pedidos SET motivo_cancelacion = ''x'' WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'admin REST motivo sobre un vivo', r, '42501');
  f := pg_temp.t_igual(f, 'R4', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- R5 · como postgres (duenio de las RPC / migracion).
CREATE OR REPLACE FUNCTION pg_temp.caso_r5(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; v_viv bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; e1 jsonb; r text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  v_viv := pg_temp.t_pedido(c, a, v_prod, 10);
  PERFORM pg_temp.t_cancelar(v_ped, a);
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped); e1 := pg_temp.t_ped(v_viv);
  r := pg_temp.t_pg(format('UPDATE public.pedidos SET estado = ''pendiente'' WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'postgres cancelado -> pendiente', r, '42501', '%una baja no se deshace%');
  r := pg_temp.t_pg(format('UPDATE public.pedidos SET motivo_cancelacion = ''x'' WHERE id = %s', v_viv));
  f := pg_temp.t_rech(f, 'postgres motivo sobre un vivo', r, '23514');
  r := pg_temp.t_pg(format('UPDATE public.pedidos SET estado = ''cancelado'' WHERE id = %s', v_viv));
  f := pg_temp.t_rech(f, 'postgres vivo -> cancelado sin motivo', r, '23514');
  f := pg_temp.t_igual(f, 'R5 cancelado', v_prod, f0, v_ped, e0);
  f := pg_temp.t_igual(f, 'R5 vivo', v_prod, f0, v_viv, e1);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- R6 · cancelar_pedido_con_stock sobre un 'anulado' (solo frena 'cancelado').
CREATE OR REPLACE FUNCTION pg_temp.caso_r6(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; r text; v_res jsonb;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  r := pg_temp.t_pg(format('UPDATE public.pedidos SET estado = ''anulado'' WHERE id = %s', v_ped));
  IF r <> 'OK 1' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: anular como postgres dio %s', r)));
  END IF;
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  v_res := pg_temp.t_rpc(format('SELECT public.cancelar_pedido_con_stock(%s, ''ensayo 1131'', %L)', v_ped, a));
  f := pg_temp.t_si(f, v_res->>'exception' LIKE '42501 %una baja no se deshace%',
                    format('cancelar sobre un anulado tenia que rechazarse y dio %s', v_res));
  f := pg_temp.t_igual(f, 'R6', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', v_res::text);
END
$fn$;

-- R7 · INSERT con baja o con motivo. Desde la 361 authenticated no tiene INSERT
-- en pedidos: por REST nadie inserta (42501 de grant). El guard se prueba con
-- service_role, que conserva el INSERT, y el control pasa como service_role.
CREATE OR REPLACE FUNCTION pg_temp.caso_r7(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; r text; v_n0 bigint; v_base text; v_i int; v_sql text[]; v_que text[];
BEGIN
  SELECT count(*) INTO v_n0 FROM public.pedidos WHERE cliente_id = c;
  v_base := 'INSERT INTO public.pedidos (cliente_id, sucursal_id, total, notas, estado%s) VALUES (%s, %s, 0, ''ensayo 1131'', %L%s)';
  v_sql := ARRAY[
    format(v_base, ', motivo_cancelacion', c, s, 'cancelado', ', ''x'''),
    format(v_base, '', c, s, 'anulado', ''),
    format(v_base, ', motivo_cancelacion_tipo', c, s, 'pendiente', ', ''otro'''),
    format(v_base, '', c, s, 'pendiente', '')];
  v_que := ARRAY['cancelado con motivo', 'anulado', 'pendiente con motivo_tipo', 'pendiente (control)'];
  -- (a) desde la 361 authenticated no tiene INSERT en pedidos: nadie inserta por REST
  FOR v_i IN 1..4 LOOP
    r := pg_temp.t_rest(a, 'authenticated', v_sql[v_i]);
    f := pg_temp.t_rech(f, 'INSERT REST (authenticated) ' || v_que[v_i], r, '42501', 'permission denied for table pedidos%');
  END LOOP;
  -- (b) service_role conserva el INSERT: ahi tiene que cortar el trigger
  r := pg_temp.t_rest(a, 'service_role', v_sql[1]);
  f := pg_temp.t_rech(f, 'INSERT service_role cancelado con motivo', r, '42501', '%Cancelar pedido%');
  r := pg_temp.t_rest(a, 'service_role', v_sql[2]);
  f := pg_temp.t_rech(f, 'INSERT service_role anulado', r, '42501', '%Cancelar pedido%');
  r := pg_temp.t_rest(a, 'service_role', v_sql[3]);
  f := pg_temp.t_rech(f, 'INSERT service_role pendiente con motivo_tipo', r, '42501', '%motivo%');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pedidos WHERE cliente_id = c) = v_n0,
                    'algun INSERT rechazado dejo un pedido');
  -- control: sin baja ni motivo, el INSERT de service_role pasa
  r := pg_temp.t_rest(a, 'service_role', v_sql[4]);
  f := pg_temp.t_pasa(f, 'INSERT service_role pendiente (control)', r);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- R8 · un pago a un cancelado.
CREATE OR REPLACE FUNCTION pg_temp.caso_r8(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; r text; v_pago bigint;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  PERFORM pg_temp.t_asignar(v_ped, tr);
  PERFORM pg_temp.t_cancelar(v_ped, a);
  v_pago := pg_temp.t_pago(c, s, NULL, 100);   -- a cuenta
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  r := pg_temp.t_rest(a, 'authenticated', pg_temp.t_sql_pago(c, s, v_ped));
  f := pg_temp.t_rech(f, 'pago REST de admin a un cancelado', r, '22023', '%no admite pagos%');
  r := pg_temp.t_rest(tr, 'authenticated', pg_temp.t_sql_pago(c, s, v_ped));
  f := pg_temp.t_rech(f, 'pago REST del transportista a su cancelado', r, '22023', '%no admite pagos%');
  -- Desde la 361 authenticated no tiene UPDATE en pagos: el corte por REST es
  -- el del grant. El guard (22023) se prueba como postgres, que no tiene logica
  -- de rol (pagos_rechazar_pedido_de_baja es SECURITY DEFINER).
  r := pg_temp.t_rest(a, 'authenticated', format('UPDATE public.pagos SET pedido_id = %s WHERE id = %s', v_ped, v_pago));
  f := pg_temp.t_rech(f, 'reapuntar un pago a un cancelado (authenticated)', r, '42501', 'permission denied for table pagos%');
  r := pg_temp.t_pg(format('UPDATE public.pagos SET pedido_id = %s WHERE id = %s', v_ped, v_pago));
  f := pg_temp.t_rech(f, 'reapuntar un pago a un cancelado (guard, como postgres)', r, '22023', '%no admite pagos%');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped),
                    'quedo un pago imputado al cancelado');
  f := pg_temp.t_igual(f, 'R8', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- R9 · cancelar sin motivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_r9(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; v_res jsonb; v_m text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  FOREACH v_m IN ARRAY ARRAY['NULL', '''  '''] LOOP
    v_res := pg_temp.t_rpc(format('SELECT public.cancelar_pedido_con_stock(%s, %s, %L)', v_ped, v_m, a));
    f := pg_temp.t_si(f, v_res->>'exception' LIKE '23514 Un pedido se cancela con motivo%',
                      format('cancelar con motivo %s tenia que rechazarse y dio %s', v_m, v_res));
  END LOOP;
  f := pg_temp.t_igual(f, 'R9', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', v_res::text);
END
$fn$;

-- R10 · service_role (una edge function) no da de baja por REST.
CREATE OR REPLACE FUNCTION pg_temp.caso_r10(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; e0 jsonb; r text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  f0 := pg_temp.t_foto(v_prod); e0 := pg_temp.t_ped(v_ped);
  r := pg_temp.t_rest(a, 'service_role',
         format('UPDATE public.pedidos SET estado = ''cancelado'', motivo_cancelacion = ''x'' WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'service_role vivo -> cancelado', r, '42501', '%Cancelar pedido%');
  r := pg_temp.t_rest(a, 'service_role', format('UPDATE public.pedidos SET motivo_cancelacion = ''x'' WHERE id = %s', v_ped));
  f := pg_temp.t_rech(f, 'service_role motivo sobre un vivo', r, '42501');
  f := pg_temp.t_igual(f, 'R10', v_prod, f0, v_ped, e0);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- P1 · admin por REST: los cambios de estado de todos los dias.
CREATE OR REPLACE FUNCTION pg_temp.caso_p1(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text; v_set text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  FOREACH v_set IN ARRAY ARRAY[
    'estado = ''en_preparacion''',
    'estado = ''pendiente''',
    format('transportista_id = %L, estado = ''asignado''', tr),
    'transportista_id = NULL, estado = ''pendiente''',
    format('transportista_id = %L, estado = ''asignado''', tr),
    'estado = ''entregado'', fecha_entrega = now(), updated_at = now()',
    'estado = ''asignado'', fecha_entrega = NULL, updated_at = now()'] LOOP
    r := pg_temp.t_rest(a, 'authenticated', format('UPDATE public.pedidos SET %s WHERE id = %s', v_set, v_ped));
    f := pg_temp.t_pasa(f, 'admin REST ' || v_set, r);
  END LOOP;
  f := pg_temp.t_si(f, (SELECT estado FROM public.pedidos WHERE id = v_ped) = 'asignado',
                    format('P1 termino en %s', pg_temp.t_ped(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- P2 · transportista por REST: asignado -> entregado.
CREATE OR REPLACE FUNCTION pg_temp.caso_p2(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  PERFORM pg_temp.t_asignar(v_ped, tr);
  r := pg_temp.t_rest(tr, 'authenticated',
         format('UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = now(), updated_at = now() WHERE id = %s', v_ped));
  f := pg_temp.t_pasa(f, 'transportista REST asignado -> entregado', r);
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- P3 · preventista duenio por REST: notas.
CREATE OR REPLACE FUNCTION pg_temp.caso_p3(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  UPDATE public.pedidos SET usuario_id = pv WHERE id = v_ped;
  r := pg_temp.t_rest(pv, 'authenticated', format('UPDATE public.pedidos SET notas = ''ensayo 1131 bis'' WHERE id = %s', v_ped));
  f := pg_temp.t_pasa(f, 'preventista REST notas', r);
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- P4 · las RPC que entran en baja o tocan el estado.
CREATE OR REPLACE FUNCTION pg_temp.caso_p4(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; v_ped2 bigint; v_pago bigint; f text[] := '{}'; v_res jsonb; v_nuevo bigint;
  v_tf text; v_rep text[] := '{}';
BEGIN
  -- (a) cancelar normal: vuelve a la bolsa
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  PERFORM pg_temp.t_cancelar(v_ped, a);
  f := pg_temp.t_si(f, pg_temp.t_foto(v_prod) = '{"stock":90,"lotes":[0,50],"bolsa":40}'
                       AND pg_temp.t_ped(v_ped)->>'estado' = 'cancelado'
                       AND pg_temp.t_ped(v_ped)->>'motivo' = 'ensayo 1131',
                    format('(a) cancelar normal: %s / %s', pg_temp.t_foto(v_prod), pg_temp.t_ped(v_ped)));

  -- (b) cancelar por falta de stock: neto 0
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  PERFORM pg_temp.t_cancelar(v_ped, a, 'falta_stock');
  f := pg_temp.t_si(f, (pg_temp.t_foto(v_prod)->>'stock')::int = 70
                       AND pg_temp.t_ped(v_ped)->>'tipo' = 'falta_stock',
                    format('(b) cancelar por falta de stock: %s / %s', pg_temp.t_foto(v_prod), pg_temp.t_ped(v_ped)));

  -- (c) cambiar_cliente_pedido sin p_motivo: el viejo queda cancelado con el
  --     default, y el pago viaja al nuevo
  IF c2 IS NULL THEN
    v_rep := v_rep || '(c) sin segundo cliente: salteado'::text;
  ELSE
    v_prod := pg_temp.t_prod_std(s, a);
    v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
    v_pago := pg_temp.t_pago(c, s, v_ped, 100);
    v_res := pg_temp.t_rpc(format(
      'SELECT public.cambiar_cliente_pedido(%s, %s, %L, %L::jsonb, 2000)', v_ped, c2, a,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 20, 'precio_unitario', 100))));
    v_nuevo := (v_res->>'nuevo_pedido_id')::bigint;
    f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false)
                         AND pg_temp.t_ped(v_ped)->>'estado' = 'cancelado'
                         AND pg_temp.t_ped(v_ped)->>'motivo' = 'Cambio de cliente -> pedido #' || v_nuevo
                         AND (SELECT pedido_id FROM public.pagos WHERE id = v_pago) = v_nuevo,
                      format('(c) cambiar_cliente_pedido: %s / viejo %s / pago en %s', v_res, pg_temp.t_ped(v_ped),
                             (SELECT pedido_id FROM public.pagos WHERE id = v_pago)));
  END IF;

  -- (d) un VB entregado se cancela (el cliente se habilita para VB despues de
  --     cargar el pedido, en el subbloque que se revierte)
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  SELECT tipo_factura_default INTO v_tf FROM public.clientes WHERE id = c;
  UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = c;
  v_res := pg_temp.t_rpc(format('SELECT public.cambiar_tipo_factura_pedido(%s, ''VB'', %L)', v_ped, a));
  IF NOT COALESCE((v_res->>'success')::boolean, false) OR pg_temp.t_ped(v_ped)->>'estado' <> 'entregado' THEN
    f := f || format('(d) no se pudo armar el VB entregado: %s / %s', v_res, pg_temp.t_ped(v_ped));
  ELSE
    v_res := pg_temp.t_rpc(format('SELECT public.cancelar_pedido_con_stock(%s, ''ensayo 1131'', %L)', v_ped, a));
    f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false)
                         AND pg_temp.t_ped(v_ped)->>'estado' = 'cancelado',
                      format('(d) cancelar el VB entregado: %s / %s', v_res, pg_temp.t_ped(v_ped)));
  END IF;
  UPDATE public.clientes SET tipo_factura_default = v_tf WHERE id = c;

  -- (e) aplicar_orden_ruta saltea el cancelado; marcar_no_entregado y
  --     marcar_entregas_masivo. Fecha lejana: no pisa un recorrido real.
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 10);
  v_ped2 := pg_temp.t_pedido(c, a, v_prod, 10);
  PERFORM pg_temp.t_cancelar(v_ped2, a);
  v_res := pg_temp.t_rpc(format(
    'SELECT to_jsonb(public.aplicar_orden_ruta(%L, %L::jsonb, NULL, NULL, NULL, %L))', tr,
    jsonb_build_array(jsonb_build_object('pedido_id', v_ped, 'orden_entrega', 1),
                      jsonb_build_object('pedido_id', v_ped2, 'orden_entrega', 2)),
    pg_temp.t_hoy() + 400));
  f := pg_temp.t_si(f, NOT (v_res ? 'exception')
                       AND pg_temp.t_ped(v_ped)->>'estado' = 'asignado'
                       AND pg_temp.t_ped(v_ped2)->>'estado' = 'cancelado',
                    format('(e) aplicar_orden_ruta: %s / %s / %s', v_res, pg_temp.t_ped(v_ped), pg_temp.t_ped(v_ped2)));
  v_res := pg_temp.t_rpc(format('SELECT public.marcar_no_entregado(%s, ''cerrado'')', v_ped));
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false)
                       AND pg_temp.t_ped(v_ped)->>'estado' = 'pendiente',
                    format('(e) marcar_no_entregado: %s / %s', v_res, pg_temp.t_ped(v_ped)));
  v_res := pg_temp.t_rpc(format('SELECT to_jsonb(public.marcar_entregas_masivo(ARRAY[%s, %s]::bigint[], %L))', v_ped, v_ped2, tr));
  f := pg_temp.t_si(f, v_res = '1'::jsonb
                       AND pg_temp.t_ped(v_ped)->>'estado' = 'entregado'
                       AND pg_temp.t_ped(v_ped2)->>'estado' = 'cancelado',
                    format('(e) marcar_entregas_masivo: %s / %s / %s', v_res, pg_temp.t_ped(v_ped), pg_temp.t_ped(v_ped2)));

  -- (f) crear_pedido_completo nace vivo y sin motivo
  f := pg_temp.t_si(f, pg_temp.t_ped(pg_temp.t_pedido(c, a, v_prod, 1)) @> '{"estado":"pendiente","motivo":null,"tipo":null}',
                    '(f) crear_pedido_completo no nacio pendiente y sin motivo');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', array_to_string(v_rep, ' · '));
END
$fn$;

-- P5 · pagos sobre un vivo, y la desimputacion de la cancelacion.
CREATE OR REPLACE FUNCTION pg_temp.caso_p5(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text; v_pago bigint;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  r := pg_temp.t_rest(a, 'authenticated', pg_temp.t_sql_pago(c, s, v_ped));
  f := pg_temp.t_pasa(f, 'pago REST a un vivo', r);
  SELECT id INTO v_pago FROM public.pagos WHERE pedido_id = v_ped;
  f := pg_temp.t_si(f, (pg_temp.t_ped(v_ped)->>'monto_pagado')::numeric = 100,
                    format('el pago no se reflejo en el pedido: %s', pg_temp.t_ped(v_ped)));
  PERFORM pg_temp.t_cancelar(v_ped, a);
  f := pg_temp.t_si(f, (SELECT pedido_id IS NULL AND notas LIKE '%saldo a favor por cancelacion%'
                          FROM public.pagos WHERE id = v_pago),
                    format('la cancelacion no desimputo el pago: %s',
                           (SELECT to_jsonb(x) FROM (SELECT pedido_id, notas FROM public.pagos WHERE id = v_pago) x)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- P6 · el reintento de un pago que ya entro, con el pedido cancelado en el medio.
CREATE OR REPLACE FUNCTION pg_temp.caso_p6(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text; v_pago bigint;
  v_uuid uuid := gen_random_uuid(); v_sql text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 20);
  v_sql := format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, pedido_id, forma_pago, notas, client_request_id) '
                  'VALUES (%s, 100, %s, %s, ''efectivo'', ''ensayo 1131'', %L)', c, s, v_ped, v_uuid);
  r := pg_temp.t_rest(a, 'authenticated', v_sql);
  f := pg_temp.t_pasa(f, 'pago REST con UUID a un vivo', r);
  SELECT id INTO v_pago FROM public.pagos WHERE client_request_id = v_uuid;
  PERFORM pg_temp.t_cancelar(v_ped, a);
  f := pg_temp.t_si(f, (SELECT pedido_id IS NULL FROM public.pagos WHERE id = v_pago),
                    'la cancelacion no desimputo el pago con UUID');
  -- (a) el reintento con el mismo UUID choca con el indice unico, como antes
  r := pg_temp.t_rest(a, 'authenticated', v_sql);
  f := pg_temp.t_rech(f, 'reintento con el mismo UUID tras cancelar', r, '23505', '%idx_pagos_client_request_id%');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pagos WHERE client_request_id = v_uuid) = 1,
                    'el reintento duplico el pago');
  -- (b) un UUID nuevo al cancelado sigue rechazado por el guard
  r := pg_temp.t_rest(a, 'authenticated',
         format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, pedido_id, forma_pago, notas, client_request_id) '
                'VALUES (%s, 100, %s, %s, ''efectivo'', ''ensayo 1131'', %L)', c, s, v_ped, gen_random_uuid()));
  f := pg_temp.t_rech(f, 'pago REST con UUID nuevo a un cancelado', r, '22023', '%no admite pagos%');
  -- (c) reapuntar el pago con UUID al cancelado (UPDATE) sigue rechazado
  --     (authenticated no tiene UPDATE en pagos desde la 361: el corte por REST es
  --     el del grant, y el guard se prueba como postgres)
  r := pg_temp.t_rest(a, 'authenticated', format('UPDATE public.pagos SET pedido_id = %s WHERE id = %s', v_ped, v_pago));
  f := pg_temp.t_rech(f, 'reapuntar el pago con UUID al cancelado (authenticated)', r, '42501', 'permission denied for table pagos%');
  r := pg_temp.t_pg(format('UPDATE public.pagos SET pedido_id = %s WHERE id = %s', v_ped, v_pago));
  f := pg_temp.t_rech(f, 'reapuntar el pago con UUID al cancelado (guard, como postgres)', r, '22023', '%no admite pagos%');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped),
                    'quedo un pago imputado al cancelado');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- D1 · los dos ajustes de datos de la migracion.
CREATE OR REPLACE FUNCTION pg_temp.caso_d1(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_stk jsonb;
BEGIN
  f := pg_temp.t_si(f, pg_temp.t_ped(1856) @> '{"estado":"entregado","motivo":null,"tipo":null,"estado_pago":"pagado","monto_pagado":31200}',
                    format('el 1856 esta %s', pg_temp.t_ped(1856)));
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pedido_historial
                         WHERE pedido_id = 1856 AND campo_modificado = 'motivo_cancelacion') = 1,
                    'el 1856 no tiene exactamente una fila de historial del motivo');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.stock_historico
                         WHERE referencia_tipo = 'pedido' AND referencia_id = 629
                           AND origen = 'correccion_incidente' AND stock_nuevo - stock_anterior = 1
                           AND producto_id IN (92, 134)) = 2
                       AND (SELECT count(*) FROM public.stock_historico
                             WHERE referencia_tipo = 'pedido' AND referencia_id = 629
                               AND origen = 'correccion_incidente') = 2,
                    'el 629 no tiene sus dos filas correccion_incidente de +1 (92 y 134)');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.producto_lotes WHERE producto_id IN (92, 134)),
                    'el 92 o el 134 tienen lotes: el +1 no fue a la bolsa');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pedido_historial
                         WHERE pedido_id = 629 AND campo_modificado = 'stock') = 1,
                    'el 629 no tiene su fila de historial del ajuste');
  SELECT jsonb_object_agg(x->>'id', x->'ok') INTO v_stk
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' IN ('STK-F', 'STK-D');
  f := pg_temp.t_si(f, v_stk = '{"STK-F":true,"STK-D":true}', format('STK-F/STK-D: %s', v_stk));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin   uuid;
  v_tr      uuid;
  v_prev    uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_cli2    bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
  v_rep     text[] := '{}';
BEGIN
  -- Una sucursal activa con un admin, un transportista y un preventista activos.
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
  SELECT us.usuario_id INTO v_tr FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'transportista' ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_prev FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)
   ORDER BY us.usuario_id LIMIT 1;
  IF v_prev IS NULL THEN
    SELECT us.usuario_id INTO v_prev FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
     WHERE us.sucursal_id = v_suc AND pf.rol = 'preventista' ORDER BY us.usuario_id LIMIT 1;
  END IF;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  SELECT id INTO v_cli2 FROM clientes WHERE sucursal_id = v_suc AND activo AND id <> v_cliente ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['r1', 'r2', 'r3', 'r4', 'r5', 'r6', 'r7', 'r8', 'r9', 'r10',
                                'p1', 'p2', 'p3', 'p4', 'p5', 'p6', 'd1'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4, $5, $6)', v_caso)
        INTO v_out USING v_cliente, v_cli2, v_admin, v_tr, v_prev, v_suc;
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

  RAISE EXCEPTION E'%\n- %\n\nREPORTE\n%',
    CASE WHEN cardinality(v_fallas) = 0 THEN 'ENSAYO OK'
         ELSE format('ENSAYO FALLO (%s fallas)', cardinality(v_fallas)) END,
    array_to_string(v_fallas, E'\n- '),
    array_to_string(v_rep, E'\n');
END
$ensayo$;
