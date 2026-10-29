-- Ensayo de #1248: la rendicion confirmada se congela (COB-4) y cambiar el
-- cliente de un pedido no deja sobrepago atrapado (COB-3).
--
-- Tienen que pasar:
--   K1  · se confirma la rendicion de un chofer con dos pagos (uno de su boleta,
--         un saldo a favor que cobro el). Se cancela la boleta y su credito se
--         aplica en parte a una boleta de otro chofer: el detalle, el drill por
--         cliente y el resumen del dia cerrado no cambian (170), el otro chofer
--         no recibe ni el pago ni el pedazo, y el total del dia sigue siendo 170.
--         Reabrirla (disconformidad) descarta la foto y muestra lo vivo; volver a
--         confirmarla toma la foto nueva; desmarcarla la borra por CASCADE.
--   K2  · lo entregado de un dia cerrado tampoco cambia si despues baja el total
--         de la boleta entregada.
--   K3  · el backfill: toda rendicion cerrada tiene foto (total_entregado_confirmado
--         no NULL), y la tabla de fotos no se lee por REST.
--   K4  · #1292, doble conteo: un credito de 600 (del admin) se parte el mismo
--         dia en un pedazo de 500 para la boleta del chofer. Se confirma la
--         rendicion del chofer: el detalle da 500, no 1000 (la foto y el pedazo
--         vivo), y al admin le quedan los 100 vivos.
--   K5  · #1292, perdida: el mismo pedazo, pero primero se confirma la rendicion
--         del admin (la raiz, 100). El pedazo ya existia: sigue vivo en la del
--         chofer (500) y entra a su foto al confirmarla.
--   K6  · #1292, el pedazo que nace despues de la foto: el credito de 600 ya esta
--         rendido cuando se aplica a una boleta del chofer. El pedazo no aparece
--         en la del chofer (su plata ya esta en la foto del admin, que sigue en
--         600): el total del dia es 600, no 1100.
--   K7  · #1298: una entrega a las 22:30 de Argentina es del dia argentino. Lo
--         entregado y el cobro de esa entrega caen en ese dia, el cobro cuenta
--         como entrega del dia (no como cuenta corriente), la foto guarda lo
--         mismo, y resolver_rendicion anota la hora argentina.
--   C1  · cambiar el cliente con el default ('pedido_nuevo'): pedido de 1000 cobrado,
--         el cliente nuevo paga 900. El pedido nuevo queda saldado en 900 y los 100
--         de mas se aplican a otra boleta impaga del cliente nuevo (50) y el resto
--         le queda a favor (50). El saldo de los dos clientes cierra.
--   C2  · con 'cliente_original': el cobro queda a favor del cliente original
--         (1000) y el pedido nuevo nace impago.
--   C3  · un destino invalido se rechaza sin tocar nada.
--
-- Contra prod sin la migracion falla en todos (K1 con el detalle en 70, K2 con
-- lo entregado en 150, C1 con el pedido nuevo en 1000, C2 y C3 por la firma).
-- Sin la de #1292/#1298 fallan K4 (detalle en 1000), K5 (el pedazo en 0) y K7
-- (lo entregado en el dia siguiente); K6 pasa con las dos: es la regla de la
-- raiz que la de #1292 conserva.
--
-- Fechas: los pagos y las rendiciones van con hoy + 400 y + 401 (nada mira fecha
-- futura en setup como postgres y asi no chocan con cajas reales). Clientes
-- nuevos en cada caso: aplicar_credito_cliente recorre todas las boletas del
-- cliente, y con uno real se iria a sus deudas viejas.
--
-- Simula PostgREST como test-pedido-baja-1131.sql (el molde). Corre contra prod
-- SIN dejar rastro: cada caso corre en un subbloque que se revierte, y el final
-- es un RAISE EXCEPTION.
--
--   psql "$DATABASE_URL" -f scripts/test-rendicion-congelada-1248.sql

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
  VALUES (p_nombre, p_nombre, 'Ensayo 1248', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1248', 100, 1000, 60, p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_items(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(p_cli, p_cant * 100, p_admin, pg_temp.t_items(p_prod, p_cant), 'ensayo 1248');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Un pago de setup, como postgres.
CREATE OR REPLACE FUNCTION pg_temp.t_pago(p_cli bigint, p_suc bigint, p_ped bigint, p_monto numeric, p_fecha date, p_usuario uuid)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas)
  VALUES (p_cli, p_ped, p_monto, 'efectivo', p_fecha, p_usuario, p_suc, 'ensayo 1248')
  RETURNING id;
$fn$;

-- El total del detalle de (fecha, chofer), y la cantidad de pagos.
CREATE OR REPLACE FUNCTION pg_temp.t_detalle(p_user uuid, p_fecha date, p_tr uuid)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format(
    'SELECT jsonb_build_object(''total'', COALESCE(SUM(total), 0), ''pagos'', COALESCE(SUM(cantidad_pagos), 0), '
    '''efectivo'', COALESCE(SUM(efectivo), 0)) FROM public.obtener_detalle_rendicion(%L::date, %L::uuid)',
    p_fecha, p_tr));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_resumen(p_user uuid, p_fecha date, p_tr uuid)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format(
    'SELECT COALESCE(jsonb_agg(jsonb_build_object(''general'', total_general, ''entregado'', total_entregado, '
    '''pedidos'', cantidad_pedidos, ''estado'', estado)), ''[]''::jsonb) '
    'FROM public.obtener_resumen_rendiciones(%L::date, %L::date, NULL) WHERE transportista_id = %L::uuid',
    p_fecha, p_fecha, p_tr));
$fn$;

-- Lo cobrado en entregas del dia, del detalle de (fecha, chofer).
CREATE OR REPLACE FUNCTION pg_temp.t_entregas(p_user uuid, p_fecha date, p_tr uuid)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format(
    'SELECT jsonb_build_object(''entregas'', COALESCE(SUM(total_entregas), 0), ''ctacte'', COALESCE(SUM(total_ctascte), 0)) '
    'FROM public.obtener_detalle_rendicion(%L::date, %L::uuid)', p_fecha, p_tr));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_confirmar(p_user uuid, p_fecha date, p_tr uuid, p_estado text)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format('SELECT to_jsonb(public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_estado => %L, p_observaciones => ''ensayo 1248'', p_gastos_rendicion => ''{"vistos":[],"guardar":[],"quitar":[]}''::jsonb))', p_fecha, p_tr, p_estado));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_num(p jsonb, p_campo text)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT CASE WHEN p ? 'exception' THEN NULL ELSE (p->>p_campo)::numeric END;
$fn$;

-- saldo_cuenta del cliente contra la cuenta a mano (lo que mira CC-A).
CREATE OR REPLACE FUNCTION pg_temp.t_saldo(p_cli bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'saldo', (SELECT COALESCE(saldo_cuenta, 0) FROM public.clientes WHERE id = p_cli),
    'cuenta', COALESCE((SELECT SUM(total - COALESCE(monto_pagado, 0)) FROM public.pedidos
                         WHERE cliente_id = p_cli AND estado NOT IN ('cancelado', 'anulado')), 0)
              - COALESCE((SELECT SUM(monto) FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL), 0),
    'a_favor', COALESCE((SELECT SUM(monto) FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL), 0));
$fn$;

-- ---------------------------------------------------------------------------
-- Casos. Firma comun: (admin, transportista, sucursal)
-- ---------------------------------------------------------------------------

-- K1 · la foto no se mueve con la reimputacion.
CREATE OR REPLACE FUNCTION pg_temp.caso_k1(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 400; c bigint; v_prod bigint;
  v_p1 bigint; v_p2 bigint; v_pago_a bigint; v_rc bigint; j jsonb; v_res jsonb; v_drill jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K1');
  v_prod := pg_temp.t_prod(s);
  v_p1 := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_p1;
  -- La boleta de otro "chofer" (el admin) va antes que los creditos: cada cambio
  -- de total dispara la reconciliacion, que los aplicaria antes de tiempo.
  v_p2 := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = a, total = 30 WHERE id = v_p2;
  -- El pago de su boleta (lo cargo el admin, se le atribuye al chofer de la
  -- boleta) y un saldo a favor que cobro el chofer.
  v_pago_a := pg_temp.t_pago(c, s, v_p1, 100, v_x, a);
  PERFORM pg_temp.t_pago(c, s, NULL, 70, v_x, tr);

  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 170, format('antes de confirmar el detalle no da 170: %s', j));

  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_estado => ''confirmada'', p_observaciones => ''ensayo 1248'', p_gastos_rendicion => ''{"vistos":[],"guardar":[],"quitar":[]}''::jsonb))', v_x, tr));
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar_rendicion fallo: %s', j));
  SELECT id INTO v_rc FROM public.rendiciones_control WHERE fecha = v_x AND transportista_id = tr AND sucursal_id = s;
  BEGIN
    f := pg_temp.t_si(f, (SELECT count(*) FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc) = 2,
                      'la foto no tiene los 2 pagos');
  EXCEPTION WHEN OTHERS THEN
    f := f || ('sin tabla de fotos: ' || SQLERRM);
  END;

  -- Se cancela la boleta: su pago queda a favor y se atribuye al admin que lo
  -- cargo. La reconciliacion de la cancelacion aplica ese credito (el mas viejo)
  -- en parte a la boleta de 30 del otro chofer.
  v_res := public.cancelar_pedido_con_stock(v_p1, 'ensayo 1248', a, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  PERFORM public.aplicar_credito_cliente(c, s);
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_p2 AND monto = 30
                                  AND fecha = v_x AND COALESCE(pago_origen_id, -1) = v_pago_a),
                    'el credito no se aplico como pedazo del pago rendido');

  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 170 AND pg_temp.t_num(j, 'pagos') = 2,
                    format('el detalle de la rendicion cerrada cambio: %s', j));
  j := pg_temp.t_detalle(a, v_x, a);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 0,
                    format('el otro chofer recibio plata de la rendicion cerrada: %s', j));
  v_drill := pg_temp.t_rpc(a, format(
    'SELECT jsonb_build_object(''n'', count(*), ''suma'', COALESCE(SUM(monto), 0)) '
    'FROM public.obtener_pagos_rendicion_cliente(%L::date, %L::uuid, %s)', v_x, tr, c));
  f := pg_temp.t_si(f, pg_temp.t_num(v_drill, 'n') = 2 AND pg_temp.t_num(v_drill, 'suma') = 170,
                    format('el drill por cliente cambio: %s', v_drill));
  j := pg_temp.t_resumen(a, v_x, tr);
  f := pg_temp.t_si(f, jsonb_typeof(j) = 'array' AND (j->0->>'general')::numeric = 170,
                    format('el resumen de la rendicion cerrada cambio: %s', j));
  j := pg_temp.t_resumen(a, v_x, a);
  f := pg_temp.t_si(f, jsonb_typeof(j) = 'array' AND COALESCE((j->0->>'general')::numeric, 0) = 0,
                    format('el resumen del otro chofer recibio plata de la cerrada: %s', j));

  -- Reabrir descarta la foto: se ve lo vivo, y el total del dia sigue en 170.
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_estado => ''disconformidad'', p_observaciones => ''ensayo 1248'', p_gastos_rendicion => ''{"vistos":[],"guardar":[],"quitar":[]}''::jsonb))', v_x, tr));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc),
                    'reabrir no descarto la foto');
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, tr), 'total') = 70
                       AND pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 100,
                    format('reabierta, lo vivo no es 70 + 100: %s / %s',
                           pg_temp.t_detalle(a, v_x, tr), pg_temp.t_detalle(a, v_x, a)));
  -- Confirmar de nuevo toma la foto nueva.
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.resolver_rendicion(%L::date, %L::uuid, ''ensayo 1248''))', v_x, tr));
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc) = 1,
                    format('resolver no tomo la foto nueva: %s', j));
  -- Desmarcar la borra por CASCADE.
  j := pg_temp.t_rpc(a, format('SELECT ''{}''::jsonb FROM (SELECT public.desmarcar_rendicion_controlada(%L::date, %L::uuid)) x', v_x, tr));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc),
                    'desmarcar no borro la foto');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K2 · lo entregado del dia cerrado.
CREATE OR REPLACE FUNCTION pg_temp.caso_k2(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 401; c bigint; v_ped bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K2');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 2);
  UPDATE public.pedidos
     SET estado = 'entregado', transportista_id = tr,
         fecha_entrega = (v_x::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz
   WHERE id = v_ped;
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_estado => ''confirmada'', p_observaciones => ''ensayo 1248'', p_gastos_rendicion => ''{"vistos":[],"guardar":[],"quitar":[]}''::jsonb))', v_x, tr));
  j := pg_temp.t_resumen(a, v_x, tr);
  f := pg_temp.t_si(f, (j->0->>'entregado')::numeric = 200 AND (j->0->>'pedidos')::numeric = 1,
                    format('al confirmar lo entregado no es 200: %s', j));
  UPDATE public.pedidos SET total = 150 WHERE id = v_ped;
  j := pg_temp.t_resumen(a, v_x, tr);
  f := pg_temp.t_si(f, (j->0->>'entregado')::numeric = 200,
                    format('lo entregado del dia cerrado cambio: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K3 · el backfill y los grants de la foto.
CREATE OR REPLACE FUNCTION pg_temp.caso_k3(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_sin bigint; v_cerradas bigint;
BEGIN
  SELECT count(*) FILTER (WHERE total_entregado_confirmado IS NULL), count(*)
    INTO v_sin, v_cerradas
    FROM public.rendiciones_control WHERE estado IN ('confirmada', 'resuelta');
  f := pg_temp.t_si(f, v_sin = 0, format('%s de %s rendiciones cerradas sin foto', v_sin, v_cerradas));
  f := pg_temp.t_si(f, NOT has_table_privilege('authenticated', 'public.rendicion_pagos_confirmados', 'SELECT')
                       AND NOT has_table_privilege('anon', 'public.rendicion_pagos_confirmados', 'SELECT'),
                    'la foto se lee por REST');
  f := pg_temp.t_si(f, (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.rendicion_pagos_confirmados'::regclass),
                    'la tabla de fotos no tiene RLS');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('%s cerradas con foto', v_cerradas));
END
$fn$;

-- K4 · #1292 · el pedazo que la foto rindio no sigue vivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_k4(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 402; c bigint; v_b1 bigint; v_x_id bigint; v_y bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K4');
  -- La boleta va antes que el credito: crearla dispara la reconciliacion.
  v_b1 := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 5);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_b1;
  v_x_id := pg_temp.t_pago(c, s, NULL, 600, v_x, a);
  PERFORM public.aplicar_credito_cliente(c, s);
  SELECT id INTO v_y FROM public.pagos WHERE pedido_id = v_b1 AND pago_origen_id = v_x_id AND monto = 500;
  f := pg_temp.t_si(f, v_y IS NOT NULL AND (SELECT monto FROM public.pagos WHERE id = v_x_id) = 100,
                    'el credito no se partio en 100 a favor y 500 para la boleta');

  j := pg_temp.t_confirmar(a, v_x, tr, 'confirmada');
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar_rendicion fallo: %s', j));
  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 500 AND pg_temp.t_num(j, 'pagos') = 1,
                    format('el chofer no tiene 500 en un pago (el pedazo se cuenta dos veces): %s', j));
  j := pg_temp.t_resumen(a, v_x, tr);
  f := pg_temp.t_si(f, jsonb_typeof(j) = 'array' AND (j->0->>'general')::numeric = 500,
                    format('el resumen del chofer no es 500: %s', j));
  j := pg_temp.t_detalle(a, v_x, a);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 100, format('al admin no le quedaron los 100 vivos: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K5 · #1292 · el pedazo que ya existia no se pierde cuando se rinde la raiz.
CREATE OR REPLACE FUNCTION pg_temp.caso_k5(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 403; c bigint; v_b1 bigint; v_x_id bigint; v_y bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K5');
  v_b1 := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 5);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_b1;
  v_x_id := pg_temp.t_pago(c, s, NULL, 600, v_x, a);
  PERFORM public.aplicar_credito_cliente(c, s);
  SELECT id INTO v_y FROM public.pagos WHERE pedido_id = v_b1 AND pago_origen_id = v_x_id;
  f := pg_temp.t_si(f, v_y IS NOT NULL, 'el credito no se partio');

  -- Se rinde primero la raiz (los 100 que le quedan al admin).
  j := pg_temp.t_confirmar(a, v_x, a, 'confirmada');
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar la del admin fallo: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 100,
                    format('la foto del admin no es 100: %s', pg_temp.t_detalle(a, v_x, a)));
  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 500,
                    format('el pedazo que ya existia se perdio de la rendicion del chofer: %s', j));

  j := pg_temp.t_confirmar(a, v_x, tr, 'confirmada');
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.rendicion_pagos_confirmados fo
                                 JOIN public.rendiciones_control rc ON rc.id = fo.rendicion_id
                                WHERE rc.fecha = v_x AND rc.transportista_id = tr AND fo.pago_id = v_y),
                    format('el pedazo no entro a la foto del chofer: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, tr), 'total') = 500,
                    format('la foto del chofer no es 500: %s', pg_temp.t_detalle(a, v_x, tr)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K6 · #1292 · el pedazo que nace despues de la foto de su raiz no se lee vivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_k6(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 404; c bigint; v_b1 bigint; v_x_id bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K6');
  v_x_id := pg_temp.t_pago(c, s, NULL, 600, v_x, a);
  j := pg_temp.t_confirmar(a, v_x, a, 'confirmada');
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 600,
                    format('la foto del admin no es 600: %s', pg_temp.t_detalle(a, v_x, a)));

  -- Recien ahora la boleta del chofer, y el credito rendido se le aplica.
  v_b1 := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 5);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_b1;
  PERFORM public.aplicar_credito_cliente(c, s);
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_b1 AND pago_origen_id = v_x_id
                                  AND monto = 500 AND fecha = v_x),
                    'el credito rendido no se aplico como pedazo');

  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 0,
                    format('el pedazo nacido despues de la foto aparece en la del chofer: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 600,
                    format('la foto del admin cambio: %s', pg_temp.t_detalle(a, v_x, a)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K7 · #1298 · la entrega de las 22:30 es del dia argentino.
CREATE OR REPLACE FUNCTION pg_temp.caso_k7(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 405; c bigint; v_ped bigint; v_rc bigint; j jsonb;
  v_marca text := to_char(now() AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY HH24:MI');
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K7');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 2);
  UPDATE public.pedidos
     SET estado = 'entregado', transportista_id = tr,
         fecha_entrega = (v_x::text || ' 22:30:00 America/Argentina/Buenos_Aires')::timestamptz
   WHERE id = v_ped;
  PERFORM pg_temp.t_pago(c, s, v_ped, 200, v_x, tr);

  j := pg_temp.t_resumen(a, v_x, tr);
  f := pg_temp.t_si(f, (j->0->>'entregado')::numeric = 200 AND (j->0->>'pedidos')::numeric = 1,
                    format('la entrega de las 22:30 no es del dia argentino: %s', j));
  j := pg_temp.t_resumen(a, v_x + 1, tr);
  f := pg_temp.t_si(f, COALESCE((j->0->>'entregado')::numeric, 0) = 0,
                    format('la entrega de las 22:30 cayo en el dia siguiente: %s', j));
  j := pg_temp.t_entregas(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'entregas') = 200 AND pg_temp.t_num(j, 'ctacte') = 0,
                    format('el cobro de la entrega no cuenta como entrega del dia: %s', j));

  j := pg_temp.t_confirmar(a, v_x, tr, 'disconformidad');
  SELECT id INTO v_rc FROM public.rendiciones_control WHERE fecha = v_x AND transportista_id = tr AND sucursal_id = s;
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.resolver_rendicion(%L::date, %L::uuid, ''ensayo 1298''))', v_x, tr));
  f := pg_temp.t_si(f, (SELECT total_entregado_confirmado = 200 AND cantidad_pedidos_confirmada = 1
                          FROM public.rendiciones_control WHERE id = v_rc),
                    'la foto no guardo la entrega del dia argentino');
  f := pg_temp.t_si(f, (SELECT bool_and(es_entrega_del_dia) FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc),
                    'la foto guardo el cobro como cuenta corriente');
  f := pg_temp.t_si(f, (SELECT observaciones FROM public.rendiciones_control WHERE id = v_rc)
                         LIKE '%[Resuelta por % el ' || v_marca || ']: ensayo 1298',
                    format('la marca de resolver_rendicion no tiene la hora argentina (%s): %s', v_marca,
                           (SELECT observaciones FROM public.rendiciones_control WHERE id = v_rc)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- C1 · cambiar el cliente con el default: el excedente le queda al nuevo.
CREATE OR REPLACE FUNCTION pg_temp.caso_c1(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_prod bigint; v_ped bigint; v_otra bigint; v_nuevo bigint; j jsonb;
BEGIN
  v_a := pg_temp.t_cliente(s, 'ZZ ensayo 1248 C1 A');
  v_b := pg_temp.t_cliente(s, 'ZZ ensayo 1248 C1 B');
  v_prod := pg_temp.t_prod(s);
  v_ped := pg_temp.t_pedido(v_a, a, v_prod, 10);
  PERFORM pg_temp.t_pago(v_a, s, v_ped, 1000, pg_temp.t_hoy() + 400, a);
  v_otra := pg_temp.t_pedido(v_b, a, v_prod, 1);
  UPDATE public.pedidos SET total = 50 WHERE id = v_otra;

  j := pg_temp.t_rpc(a, format(
    'SELECT public.cambiar_cliente_pedido(%s, %s, %L::uuid, %L::jsonb, 900, 900, 0, ''ensayo 1248'')',
    v_ped, v_b, a, pg_temp.t_items(v_prod, 9)));
  f := pg_temp.t_si(f, COALESCE((j->>'success')::boolean, false), format('cambiar_cliente_pedido fallo: %s', j));
  v_nuevo := (j->>'nuevo_pedido_id')::bigint;

  f := pg_temp.t_si(f, (SELECT monto_pagado = 900 AND estado_pago = 'pagado' FROM public.pedidos WHERE id = v_nuevo),
                    format('el pedido nuevo no quedo saldado en 900: %s',
                           (SELECT to_jsonb(p) - 'notas' FROM (SELECT total, monto_pagado, estado_pago FROM public.pedidos WHERE id = v_nuevo) p)));
  f := pg_temp.t_si(f, (SELECT monto_pagado FROM public.pedidos WHERE id = v_otra) = 50,
                    'el excedente no se aplico a la otra boleta del cliente nuevo');
  f := pg_temp.t_si(f, (pg_temp.t_saldo(v_b)->>'a_favor')::numeric = 50,
                    format('al cliente nuevo no le quedaron 50 a favor: %s', pg_temp.t_saldo(v_b)));
  f := pg_temp.t_si(f, (pg_temp.t_saldo(v_b)->>'saldo')::numeric = (pg_temp.t_saldo(v_b)->>'cuenta')::numeric
                       AND (pg_temp.t_saldo(v_a)->>'saldo')::numeric = (pg_temp.t_saldo(v_a)->>'cuenta')::numeric,
                    format('el saldo no cierra: A %s, B %s', pg_temp.t_saldo(v_a), pg_temp.t_saldo(v_b)));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE cliente_id = v_a),
                    'al cliente original le quedo un pago');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- C2 · 'cliente_original': el cobro queda a favor del que pago.
CREATE OR REPLACE FUNCTION pg_temp.caso_c2(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_prod bigint; v_ped bigint; v_nuevo bigint; j jsonb;
BEGIN
  v_a := pg_temp.t_cliente(s, 'ZZ ensayo 1248 C2 A');
  v_b := pg_temp.t_cliente(s, 'ZZ ensayo 1248 C2 B');
  v_prod := pg_temp.t_prod(s);
  v_ped := pg_temp.t_pedido(v_a, a, v_prod, 10);
  PERFORM pg_temp.t_pago(v_a, s, v_ped, 1000, pg_temp.t_hoy() + 400, a);

  j := pg_temp.t_rpc(a, format(
    'SELECT public.cambiar_cliente_pedido(%s, %s, %L::uuid, %L::jsonb, 900, 900, 0, ''ensayo 1248'', '
    'p_destino_pagos => ''cliente_original'')',
    v_ped, v_b, a, pg_temp.t_items(v_prod, 9)));
  f := pg_temp.t_si(f, COALESCE((j->>'success')::boolean, false), format('cambiar_cliente_pedido fallo: %s', j));
  v_nuevo := (j->>'nuevo_pedido_id')::bigint;

  f := pg_temp.t_si(f, (SELECT COALESCE(monto_pagado, 0) = 0 FROM public.pedidos WHERE id = v_nuevo),
                    'el pedido nuevo no nacio impago');
  f := pg_temp.t_si(f, (pg_temp.t_saldo(v_a)->>'a_favor')::numeric = 1000,
                    format('al cliente original no le quedaron 1000 a favor: %s', pg_temp.t_saldo(v_a)));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE cliente_id = v_b),
                    'al cliente nuevo le paso un pago');
  f := pg_temp.t_si(f, (pg_temp.t_saldo(v_b)->>'saldo')::numeric = (pg_temp.t_saldo(v_b)->>'cuenta')::numeric
                       AND (pg_temp.t_saldo(v_a)->>'saldo')::numeric = (pg_temp.t_saldo(v_a)->>'cuenta')::numeric,
                    format('el saldo no cierra: A %s, B %s', pg_temp.t_saldo(v_a), pg_temp.t_saldo(v_b)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- C3 · destino invalido.
CREATE OR REPLACE FUNCTION pg_temp.caso_c3(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_prod bigint; v_ped bigint; j jsonb;
BEGIN
  v_a := pg_temp.t_cliente(s, 'ZZ ensayo 1248 C3 A');
  v_b := pg_temp.t_cliente(s, 'ZZ ensayo 1248 C3 B');
  v_prod := pg_temp.t_prod(s);
  v_ped := pg_temp.t_pedido(v_a, a, v_prod, 1);
  j := pg_temp.t_rpc(a, format(
    'SELECT public.cambiar_cliente_pedido(%s, %s, %L::uuid, %L::jsonb, 100, 100, 0, ''ensayo 1248'', '
    'p_destino_pagos => ''al_otro'')',
    v_ped, v_b, a, pg_temp.t_items(v_prod, 1)));
  f := pg_temp.t_si(f, (j->>'success') = 'false' AND (j->>'error') LIKE 'Destino de los pagos invalido%',
                    format('un destino invalido no se rechazo: %s', j));
  f := pg_temp.t_si(f, (SELECT estado FROM public.pedidos WHERE id = v_ped) <> 'cancelado',
                    'el rechazo igual cancelo el pedido');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_tr     uuid;
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
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con admin y transportista activos';
  END IF;
  SELECT us.usuario_id INTO v_admin FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_tr FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'transportista' ORDER BY us.usuario_id LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['k1', 'k2', 'k3', 'k4', 'k5', 'k6', 'k7', 'c1', 'c2', 'c3'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_admin, v_tr, v_suc;
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
