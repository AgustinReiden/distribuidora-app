-- Ensayo de #1248: la rendicion confirmada se congela (COB-4) y cambiar el
-- cliente de un pedido no deja sobrepago atrapado (COB-3).
--
-- Tienen que pasar:
--   K1  · se confirma la rendicion de un chofer con dos pagos (uno de su boleta,
--         un saldo a favor que cobro el). Se cancela la boleta y su credito se
--         aplica en parte a una boleta de otro chofer: el detalle, el drill por
--         cliente y el resumen del dia cerrado no cambian (170), el otro chofer
--         no recibe ni el pago ni el pedazo, y el total del dia sigue siendo 170.
--         Reabrirla (disconformidad) descarta la foto y muestra lo vivo; resolverla
--         toma la foto nueva. Una resuelta no se desmarca (#1547): el admin deshace
--         la resolucion, se confirma de nuevo, y desmarcar esa confirmada borra la
--         foto por CASCADE.
--   K2  · lo entregado de un dia cerrado tampoco cambia si despues baja el total
--         de la boleta entregada.
--   K3  · el backfill: toda rendicion cerrada tiene foto (total_entregado_confirmado
--         no NULL), y la tabla de fotos no se lee por REST.
--   K4  · #1292, doble conteo: un pago a cuenta de 500 a la boleta del chofer, que
--         cargo el admin, se parte el mismo dia al bajar la boleta: 300 (la raiz,
--         del chofer) y un pedazo de 200 a favor (del admin). Se confirma la
--         rendicion del admin: el detalle da 200 en un pago, no 400 (la foto y el
--         pedazo vivo), y al chofer le quedan los 300 vivos.
--   K5  · #1292, perdida: el mismo pedazo, pero primero se confirma la rendicion
--         del chofer (la raiz, 300). El pedazo ya existia: sigue vivo en la del
--         admin (200) y entra a su foto al confirmarla.
--         (Hasta #1492 el cruce de K4, K5 y K8 lo armaba un credito de 600 del
--         admin aplicado a la boleta del chofer; desde la 473 ese pedazo sigue
--         siendo del admin y no cruza.)
--   K6  · #1292, el pedazo que nace despues de la foto: el credito de 600 ya esta
--         rendido cuando se aplica a una boleta del chofer. El pedazo no aparece
--         en la del chofer (su plata ya esta en la foto del admin, que sigue en
--         600): el total del dia es 600, no 1100.
--   K7  · #1298: una entrega a las 22:30 de Argentina es del dia argentino. Lo
--         entregado y el cobro de esa entrega caen en ese dia, el cobro cuenta
--         como entrega del dia (no como cuenta corriente), la foto guarda lo
--         mismo, y resolver_rendicion anota la hora argentina.
--   K8  · #1369, perdida: el cruce de K4 (raiz de 300 del chofer, pedazo de 200 a
--         favor del admin). Se rinde la raiz, y despues el pedazo se aplica en
--         parte (100) a otra boleta del cliente. Esos 100 salieron del pedazo, no
--         de la raiz rendida: siguen vivos en el dia del admin junto a los 100 que
--         quedan a favor, y el dia rinde los 500.
--   K9  · #1359, doble conteo: un pago a cuenta de 500 a la boleta del chofer, que
--         cargo el admin, se parte al bajar la boleta: 300 y 200 a favor del
--         admin. Se rinde el admin (200, el pedazo) y no el chofer (la raiz).
--         Despues el credito se aplica en parte (100) a otra boleta del chofer:
--         ese pedazo ya esta en los 200 de la foto, y no aparece vivo.
--   K10 · la cadena: el credito de 600 se rinde entero, y despues se parte dos
--         veces (500 a la boleta, y de esos 50 vuelven a favor). Ni el pedazo ni
--         el pedazo del pedazo se leen vivos: su plata es la de la foto. Medir
--         contra el padre directo, sin subir por la cadena, los contaria.
--   K11 · todos los caminos que parten un pago guardan el padre directo:
--         imputar_credito_a_pedido sobre un pedazo, y los CHECK que exigen el
--         padre en todo pedazo y que nazca antes que el (sin ciclos).
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
-- Sin la de #1292/#1298 fallan K4 (detalle en 400), K5 (el pedazo en 0) y K7
-- (lo entregado en el dia siguiente); K6 pasa con las dos: es la regla de la
-- raiz que la de #1292 conserva.
-- Sin la de #1359/#1369 fallan K8 (el admin en 100), K9 (el chofer en 400), K11
-- (sin pago_padre_id) y el padre de C1; K10 pasa: es la regla de la raiz.
--
-- Fechas: los pagos y las rendiciones van en dias de 2016 (t_dia: 01/01/2015 mas
-- 400, 401...). Antes iban en hoy + 400, pero desde #1547 una rendicion de un dia
-- que no llego no se confirma. Son dias sin datos reales, y el ensayo elige una
-- sucursal que no tenga ninguna caja cerrada: guard_pago_fecha_cerrada rechaza
-- todo pago hasta la ultima cerrada de la sucursal, asi que con una cerrada el
-- setup no podria cargar pagos de 2016. Clientes
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

-- Los dias del ensayo: pasados y lejanos (ver "Fechas" arriba).
CREATE OR REPLACE FUNCTION pg_temp.t_dia(p_n int)
RETURNS date LANGUAGE sql AS $fn$
  SELECT DATE '2015-01-01' + p_n;
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
  f text[] := '{}'; v_x date := pg_temp.t_dia(400); c bigint; v_prod bigint;
  v_p1 bigint; v_p2 bigint; v_pago_a bigint; v_rc bigint; j jsonb; v_res jsonb; v_drill jsonb;
  tr2 uuid := gen_random_uuid();
BEGIN
  -- El otro chofer es un chofer de verdad de la sucursal: desde la T2 de la ola 3 (1601-b1) un
  -- pedido no se le asigna a un admin (pedidos_entrega_con_chofer, _actua_como_transportista).
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (tr2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'e1248-' || tr2 || '@ensayo.invalid', jsonb_build_object('rol', 'transportista', 'sucursal_id', s),
          jsonb_build_object('nombre', 'ensayo 1248 K1 otro chofer'), now(), now());
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K1');
  v_prod := pg_temp.t_prod(s);
  v_p1 := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_p1;
  -- La boleta de otro chofer va antes que los creditos: cada cambio
  -- de total dispara la reconciliacion, que los aplicaria antes de tiempo.
  v_p2 := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr2, total = 30 WHERE id = v_p2;
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
  j := pg_temp.t_detalle(a, v_x, tr2);
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
  j := pg_temp.t_resumen(a, v_x, tr2);
  f := pg_temp.t_si(f, jsonb_typeof(j) = 'array' AND COALESCE((j->0->>'general')::numeric, 0) = 0,
                    format('el resumen del otro chofer recibio plata de la cerrada: %s', j));

  -- Reabrir descarta la foto: se ve lo vivo, y el total del dia sigue en 170. Desde la T4 (#1710)
  -- todo sigue siendo del chofer: el cobro es de quien lo cobró (pagos.cobrado_por) y no pasa al
  -- admin porque la boleta se cancele (antes, lo que quedaba suelto era de quien lo cargó).
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_estado => ''disconformidad'', p_observaciones => ''ensayo 1248'', p_gastos_rendicion => ''{"vistos":[],"guardar":[],"quitar":[]}''::jsonb))', v_x, tr));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc),
                    'reabrir no descarto la foto');
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, tr), 'total') = 170
                       AND pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 0,
                    format('reabierta, lo vivo no es 170 del chofer y 0 del admin: %s / %s',
                           pg_temp.t_detalle(a, v_x, tr), pg_temp.t_detalle(a, v_x, a)));
  -- Confirmar de nuevo toma la foto nueva.
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.resolver_rendicion(%L::date, %L::uuid, ''ensayo 1248''))', v_x, tr));
  -- Los tres pagos vivos del chofer: los 70 suyos, los 70 que quedaron sueltos y el pedazo de 30.
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc) = 3,
                    format('resolver no tomo la foto nueva: %s', j));
  -- #1547 (REN-4): una resuelta no se desmarca. El admin deshace la resolucion (queda en
  -- disconformidad, sin foto) y se confirma de nuevo, que toma otra foto.
  j := pg_temp.t_rpc(a, format('SELECT ''{}''::jsonb FROM (SELECT public.desmarcar_rendicion_controlada(%L::date, %L::uuid)) x', v_x, tr));
  f := pg_temp.t_si(f, j ? 'exception' AND (SELECT estado FROM public.rendiciones_control WHERE id = v_rc) = 'resuelta',
                    format('desmarcar una resuelta no se rechazo: %s', j));
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.deshacer_resolucion_rendicion(%L::date, %L::uuid, ''ensayo 1248''))', v_x, tr));
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('deshacer la resolucion fallo: %s', j));
  j := pg_temp.t_confirmar(a, v_x, tr, 'confirmada');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.rendicion_pagos_confirmados WHERE rendicion_id = v_rc) = 3,
                    format('confirmar de nuevo no tomo la foto: %s', j));
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
  f text[] := '{}'; v_x date := pg_temp.t_dia(401); c bigint; v_ped bigint; j jsonb;
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

-- K4, K5 y K8 parten la raiz en una rendicion y el pedazo en otra. Desde #1492 (mig 473,
-- decision del dueno) el pedazo de un credito que se aplica a una boleta sigue siendo de
-- quien cobro el credito: ya no cruza al chofer de la boleta. Lo que si cruza es lo que
-- suelta la boleta: un pago a cuenta de la boleta del chofer (que cargo el admin) es del
-- chofer, y si la boleta baja, el pedazo que queda a favor es del admin que lo cargo
-- (#1329). Asi arman el cruce los tres.
CREATE OR REPLACE FUNCTION pg_temp.t_cruce(p_cli bigint, p_admin uuid, p_tr uuid, p_suc bigint, p_fecha date)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_b1 bigint; v_r bigint; v_y bigint;
BEGIN
  v_b1 := pg_temp.t_pedido(p_cli, p_admin, pg_temp.t_prod(p_suc), 5);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = p_tr WHERE id = v_b1;
  v_r := pg_temp.t_pago(p_cli, p_suc, v_b1, 500, p_fecha, p_admin);
  UPDATE public.pagos SET a_cuenta = true WHERE id = v_r;
  UPDATE public.pedidos SET total = 300 WHERE id = v_b1;
  SELECT id INTO v_y FROM public.pagos
   WHERE cliente_id = p_cli AND pedido_id IS NULL AND pago_origen_id = v_r AND pago_padre_id = v_r AND monto = 200;
  -- Desde la T4 (#1710) un pedazo es de la caja de su padre (pagos.cobrado_por). El cruce (la raíz
  -- de un dueño, el pedazo de otro) sigue en los pagos de antes de la T4, cuyo dueño se rellenó
  -- con la regla de entonces fila por fila: acá se arma a mano.
  UPDATE public.pagos SET cobrado_por = p_admin WHERE id = v_y;
  RETURN jsonb_build_object('boleta', v_b1, 'raiz', v_r, 'pedazo', v_y,
                            'raiz_monto', (SELECT monto FROM public.pagos WHERE id = v_r));
END
$fn$;

-- K4 · #1292 · el pedazo que la foto rindio no sigue vivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_k4(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_dia(402); c bigint; v_cruce jsonb; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K4');
  v_cruce := pg_temp.t_cruce(c, a, tr, s, v_x);
  f := pg_temp.t_si(f, v_cruce->>'pedazo' IS NOT NULL AND (v_cruce->>'raiz_monto')::numeric = 300,
                    format('el pago a cuenta no se partio en 300 para la boleta y 200 a favor: %s', v_cruce));

  -- Se rinde el pedazo (el admin): la foto lo tiene, y la raiz no esta en ninguna.
  j := pg_temp.t_confirmar(a, v_x, a, 'confirmada');
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar_rendicion fallo: %s', j));
  j := pg_temp.t_detalle(a, v_x, a);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 200 AND pg_temp.t_num(j, 'pagos') = 1,
                    format('el admin no tiene 200 en un pago (el pedazo se cuenta dos veces): %s', j));
  j := pg_temp.t_resumen(a, v_x, a);
  f := pg_temp.t_si(f, jsonb_typeof(j) = 'array' AND (j->0->>'general')::numeric = 200,
                    format('el resumen del admin no es 200: %s', j));
  -- Vivo, iria al dia siguiente al cerrado (#1328): ahi tambien se contaria dos veces.
  j := pg_temp.t_detalle(a, v_x + 1, a);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 0,
                    format('el pedazo rendido sigue vivo en el dia siguiente del admin: %s', j));
  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 300, format('al chofer no le quedaron los 300 vivos: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K5 · #1292 · el pedazo que ya existia no se pierde cuando se rinde la raiz.
CREATE OR REPLACE FUNCTION pg_temp.caso_k5(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_dia(403); c bigint; v_cruce jsonb; v_y bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K5');
  v_cruce := pg_temp.t_cruce(c, a, tr, s, v_x);
  v_y := (v_cruce->>'pedazo')::bigint;
  f := pg_temp.t_si(f, v_y IS NOT NULL, format('el pago a cuenta no se partio: %s', v_cruce));

  -- Se rinde primero la raiz (los 300 que le quedan al chofer).
  j := pg_temp.t_confirmar(a, v_x, tr, 'confirmada');
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar la del chofer fallo: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, tr), 'total') = 300,
                    format('la foto del chofer no es 300: %s', pg_temp.t_detalle(a, v_x, tr)));
  j := pg_temp.t_detalle(a, v_x, a);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 200,
                    format('el pedazo que ya existia se perdio de la rendicion del admin: %s', j));

  j := pg_temp.t_confirmar(a, v_x, a, 'confirmada');
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.rendicion_pagos_confirmados fo
                                 JOIN public.rendiciones_control rc ON rc.id = fo.rendicion_id
                                WHERE rc.fecha = v_x AND rc.transportista_id = a AND fo.pago_id = v_y),
                    format('el pedazo no entro a la foto del admin: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 200,
                    format('la foto del admin no es 200: %s', pg_temp.t_detalle(a, v_x, a)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K6 · #1292 · el pedazo que nace despues de la foto de su raiz no se lee vivo.
CREATE OR REPLACE FUNCTION pg_temp.caso_k6(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_dia(404); c bigint; v_b1 bigint; v_x_id bigint; j jsonb;
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
  f text[] := '{}'; v_x date := pg_temp.t_dia(405); c bigint; v_ped bigint; v_rc bigint; j jsonb;
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

-- K8 · #1369 · el pedazo de un pedazo no se mide contra la raiz rendida.
CREATE OR REPLACE FUNCTION pg_temp.caso_k8(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_dia(406); c bigint; v_cruce jsonb; v_b2 bigint;
  v_r bigint; v_y bigint; v_z bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K8');
  v_cruce := pg_temp.t_cruce(c, a, tr, s, v_x);
  v_r := (v_cruce->>'raiz')::bigint;
  v_y := (v_cruce->>'pedazo')::bigint;
  f := pg_temp.t_si(f, v_y IS NOT NULL, format('el pago a cuenta no se partio en 200 a favor: %s', v_cruce));

  -- Se rinde la raiz (los 300 del chofer). El pedazo de 200 ya existia: sigue vivo.
  j := pg_temp.t_confirmar(a, v_x, tr, 'confirmada');
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar la del chofer fallo: %s', j));

  -- Otra boleta del cliente, sin que el alta absorba el credito: se le aplica despues,
  -- y el pedazo se parte en 100 para la boleta y 100 que siguen a favor. Los dos son del
  -- admin, que cobro el credito (#1492).
  PERFORM set_config('app.reimputacion_pagos', 'on', true);
  v_b2 := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  PERFORM set_config('app.reimputacion_pagos', '', true);
  PERFORM public.aplicar_credito_cliente(c, s);
  SELECT id INTO v_z FROM public.pagos WHERE pedido_id = v_b2 AND pago_origen_id = v_r AND monto = 100;
  f := pg_temp.t_si(f, v_z IS NOT NULL AND (SELECT monto FROM public.pagos WHERE id = v_y) = 100,
                    'el credito no partio el pedazo en 100 para la boleta y 100 a favor');
  f := pg_temp.t_si(f, (SELECT pago_padre_id FROM public.pagos WHERE id = v_z) IS NOT DISTINCT FROM v_y
                       AND (SELECT pago_padre_id FROM public.pagos WHERE id = v_y) IS NOT DISTINCT FROM v_r,
                    'los pedazos no guardan su padre directo');

  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, tr), 'total') = 300,
                    format('la foto del chofer no es 300: %s', pg_temp.t_detalle(a, v_x, tr)));
  -- Los 100 que salieron del pedazo no salieron de la raiz rendida: siguen vivos en el
  -- admin, y el dia rinde los 500.
  j := pg_temp.t_detalle(a, v_x, a);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 200 AND pg_temp.t_num(j, 'pagos') = 2,
                    format('los 100 que salieron del pedazo se perdieron: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K9 · #1359 · el pedazo de un pedazo rendido no se cuenta dos veces.
CREATE OR REPLACE FUNCTION pg_temp.caso_k9(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_dia(408); c bigint; v_prod bigint; v_b1 bigint; v_b2 bigint;
  v_r bigint; v_q bigint; v_p bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K9');
  v_prod := pg_temp.t_prod(s);
  v_b1 := pg_temp.t_pedido(c, a, v_prod, 5);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_b1;
  -- Un pago a cuenta que cargo el admin: es del chofer de la boleta.
  v_r := pg_temp.t_pago(c, s, v_b1, 500, v_x, a);
  UPDATE public.pagos SET a_cuenta = true WHERE id = v_r;
  -- La boleta baja a 300: los 200 quedan a favor, y son del admin que los cargo.
  UPDATE public.pedidos SET total = 300 WHERE id = v_b1;
  SELECT id INTO v_q FROM public.pagos WHERE cliente_id = c AND pedido_id IS NULL AND pago_origen_id = v_r AND monto = 200;
  -- El cruce de antes de la T4, armado a mano (ver t_cruce).
  UPDATE public.pagos SET cobrado_por = a WHERE id = v_q;
  f := pg_temp.t_si(f, v_q IS NOT NULL AND (SELECT pago_padre_id FROM public.pagos WHERE id = v_q) IS NOT DISTINCT FROM v_r,
                    'la baja no dejo 200 a favor como pedazo del pago a cuenta');

  -- Se rinde el admin (el pedazo de 200), no el chofer (la raiz).
  j := pg_temp.t_confirmar(a, v_x, a, 'confirmada');
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar la del admin fallo: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 200,
                    format('la foto del admin no es 200: %s', pg_temp.t_detalle(a, v_x, a)));

  -- Otra boleta del chofer: crearla dispara la reconciliacion, que le aplica 100 del credito.
  v_b2 := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_b2;
  PERFORM public.aplicar_credito_cliente(c, s);
  SELECT id INTO v_p FROM public.pagos WHERE pedido_id = v_b2 AND monto = 100;
  f := pg_temp.t_si(f, v_p IS NOT NULL AND (SELECT monto FROM public.pagos WHERE id = v_q) = 100,
                    'el credito no se aplico en parte a la otra boleta');
  f := pg_temp.t_si(f, (SELECT pago_padre_id = v_q AND pago_origen_id = v_r FROM public.pagos WHERE id = v_p),
                    'el pedazo del pedazo no guarda su padre directo y su raiz');

  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 300,
                    format('el chofer cuenta otra vez plata que ya esta en la foto del admin: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 200
                       AND pg_temp.t_num(pg_temp.t_detalle(a, v_x + 1, a), 'total') = 0,
                    format('el admin cambio: %s / %s', pg_temp.t_detalle(a, v_x, a), pg_temp.t_detalle(a, v_x + 1, a)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K10 · la cadena: dos particiones despues de la foto de la raiz.
CREATE OR REPLACE FUNCTION pg_temp.caso_k10(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_dia(409); c bigint; v_b1 bigint; v_r bigint; v_y bigint; v_z bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K10');
  v_r := pg_temp.t_pago(c, s, NULL, 600, v_x, a);
  j := pg_temp.t_confirmar(a, v_x, a, 'confirmada');
  f := pg_temp.t_si(f, j ? 'exception' IS NOT TRUE, format('confirmar la del admin fallo: %s', j));

  v_b1 := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 5);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_b1;
  PERFORM public.aplicar_credito_cliente(c, s);
  SELECT id INTO v_y FROM public.pagos WHERE pedido_id = v_b1 AND pago_origen_id = v_r AND monto = 500;
  UPDATE public.pedidos SET total = 450 WHERE id = v_b1;
  SELECT id INTO v_z FROM public.pagos WHERE cliente_id = c AND pedido_id IS NULL AND pago_origen_id = v_r AND monto = 50;
  f := pg_temp.t_si(f, v_y IS NOT NULL AND v_z IS NOT NULL, 'el credito rendido no se partio dos veces');

  j := pg_temp.t_detalle(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_num(j, 'total') = 0,
                    format('el pedazo nacido despues de la foto aparece en la del chofer: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x + 1, a), 'total') = 0,
                    format('el pedazo del pedazo aparece vivo en el admin: %s', pg_temp.t_detalle(a, v_x + 1, a)));
  f := pg_temp.t_si(f, pg_temp.t_num(pg_temp.t_detalle(a, v_x, a), 'total') = 600,
                    format('la foto del admin cambio: %s', pg_temp.t_detalle(a, v_x, a)));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', j::text);
END
$fn$;

-- K11 · imputar sobre un pedazo guarda el padre, y el CHECK lo exige.
CREATE OR REPLACE FUNCTION pg_temp.caso_k11(a uuid, tr uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_dia(410); c bigint; v_prod bigint; v_b1 bigint; v_b2 bigint;
  v_r bigint; v_q bigint; v_p bigint; j jsonb; v_err text;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1248 K11');
  v_prod := pg_temp.t_prod(s);
  v_b1 := pg_temp.t_pedido(c, a, v_prod, 5);
  v_r := pg_temp.t_pago(c, s, v_b1, 500, v_x, a);
  UPDATE public.pagos SET a_cuenta = true WHERE id = v_r;
  UPDATE public.pedidos SET total = 300 WHERE id = v_b1;
  SELECT id INTO v_q FROM public.pagos WHERE cliente_id = c AND pedido_id IS NULL AND pago_origen_id = v_r;
  -- La boleta nueva, sin que la reconciliacion le aplique el credito: se imputa a mano.
  PERFORM set_config('app.reimputacion_pagos', 'on', true);
  v_b2 := pg_temp.t_pedido(c, a, v_prod, 1);
  PERFORM set_config('app.reimputacion_pagos', '', true);

  j := pg_temp.t_rpc(a, format('SELECT public.imputar_credito_a_pedido(%s, %s, 50)', v_q, v_b2));
  v_p := (j->>'pago_id')::bigint;
  f := pg_temp.t_si(f, COALESCE((j->>'success')::boolean, false) AND v_p IS DISTINCT FROM v_q,
                    format('imputar 50 del pedazo no lo partio: %s', j));
  f := pg_temp.t_si(f, (SELECT pago_padre_id = v_q AND pago_origen_id = v_r FROM public.pagos WHERE id = v_p),
                    'imputar no guarda el padre directo del pedazo');

  BEGIN
    INSERT INTO public.pagos (cliente_id, monto, forma_pago, fecha, usuario_id, sucursal_id, pago_origen_id)
    VALUES (c, 1, 'efectivo', v_x, a, s, v_r);
    v_err := 'sin error';
  EXCEPTION WHEN check_violation THEN
    v_err := NULL;
  WHEN OTHERS THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  f := pg_temp.t_si(f, v_err IS NULL, format('un pedazo sin padre no choca con el CHECK: %s', v_err));
  -- Un padre que no nacio antes que el pedazo armaria un ciclo.
  BEGIN
    UPDATE public.pagos SET pago_padre_id = v_p WHERE id = v_p;
    v_err := 'sin error';
  EXCEPTION WHEN check_violation THEN
    v_err := NULL;
  WHEN OTHERS THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  f := pg_temp.t_si(f, v_err IS NULL, format('un pedazo padre de si mismo no choca con el CHECK: %s', v_err));
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
  PERFORM pg_temp.t_pago(v_a, s, v_ped, 1000, pg_temp.t_dia(400), a);
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
  -- #1359: el excedente (_pagos_excedente_a_favor) y lo que se aplica de el
  -- (aplicar_credito_cliente) guardan su padre directo, que lleva a la raiz.
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pagos WHERE cliente_id = v_b AND pago_origen_id IS NOT NULL) >= 2
                       AND NOT EXISTS (
                         SELECT 1 FROM public.pagos h
                           LEFT JOIN public.pagos p ON p.id = h.pago_padre_id
                          WHERE h.cliente_id = v_b AND h.pago_origen_id IS NOT NULL
                            AND (p.id IS NULL OR COALESCE(p.pago_origen_id, p.id) <> h.pago_origen_id)),
                    format('los pedazos del cambio de cliente no guardan su padre: %s',
                           (SELECT jsonb_agg(jsonb_build_object('id', id, 'monto', monto, 'padre', pago_padre_id, 'raiz', pago_origen_id) ORDER BY id)
                              FROM public.pagos WHERE cliente_id = v_b)));
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
  PERFORM pg_temp.t_pago(v_a, s, v_ped, 1000, pg_temp.t_dia(400), a);

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
     AND NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                      WHERE rc.sucursal_id = s.id AND rc.estado IN ('confirmada', 'resuelta'))
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'admin')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'transportista')
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con admin y transportista activos y sin ninguna caja cerrada';
  END IF;
  SELECT us.usuario_id INTO v_admin FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_tr FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'transportista' ORDER BY us.usuario_id LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['k1', 'k2', 'k3', 'k4', 'k5', 'k6', 'k7', 'k8', 'k9', 'k10', 'k11', 'c1', 'c2', 'c3'] LOOP
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
