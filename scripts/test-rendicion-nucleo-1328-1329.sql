-- Ensayo de #1328 (rendicion) y #1329 (los ocho caminos del nucleo).
--
-- Tienen que pasar:
--   R3  · REN-3: el encargado no confirma, resuelve, marca ni desmarca su propia
--         rendicion. La confirma el admin o otro encargado; el encargado sigue
--         confirmando la de un chofer, y el admin la suya.
--   R2  · REN-2: una reimputacion lleva un pago a un chofer con el dia confirmado.
--         La rendicion cerrada no cambia y el pago va al dia siguiente al ultimo que
--         cerro el chofer, como cuenta corriente. Confirmar ese dia lo guarda en su
--         foto, reabrirlo lo devuelve a lo vivo y reabrir el dia original lo
--         devuelve a su dia.
--   R4  · REN-2: el pago no cae en un hueco viejo. Con dias cerrados salteados, va
--         despues del ultimo.
--   P1  · posicion_fiscal arma la Red con _sucursales_red().
--   C1  · canje con diferencia: mueve el stock, guarda la diferencia y no toca
--         saldo_cuenta (CC-A sigue cerrando), para las dos puntas.
--   E1  · eliminar_pedido_completo no se ejecuta por REST y el sistema viejo no
--         tiene ninguna rendicion cerrada (se tacho en #1329).
--   D1  · un pago FIFO genuino no se pierde cuando baja el total de su boleta: lo
--         que sobra queda a favor del cliente, y lo mismo un credito imputado
--         entero. Un cobro de boleta y un adelanto de sueldo se siguen recortando.
--   S1  · el chofer no lee las salvedades de un vale blanco; las de su boleta comun
--         y las del vendedor del VB, si.
--   F1  · actualizar_forma_pago_pago usa el criterio del guard: un dia sin
--         rendicion confirmada, pero anterior a la ultima cerrada, esta cerrado.
--   V1  · el sistema viejo (crear_rendicion_recorrido, presentar_rendicion,
--         revisar_rendicion, es_admin_rendiciones) ya no existe.
--   O1  · registrar_origen_precio_items: con sesion, el pedido es de la sucursal
--         activa y p_perfil_id no puede ser otro; el server sigue pudiendo.
--
-- Contra prod sin las migraciones fallan R3, R2, R4, P1, C1, D1, F1, V1 y O1.
-- E1 y S1 pasan con y sin migracion: son el motivo por el que se tacharon. Al
-- chofer ya le oculta el VB la RLS de pedidos, que corre adentro del EXISTS de
-- mt_salvedades_items_select.
--
-- Fechas: hoy + 410 en adelante, como test-rendicion-congelada-1248.sql: nada mira
-- fecha futura en el setup y no choca con cajas reales. Clientes nuevos en cada
-- caso. Corre contra prod SIN dejar rastro: cada caso va en un subbloque que se
-- revierte y el final es un RAISE EXCEPTION.
--
--   psql "$DATABASE_URL" -f scripts/test-rendicion-nucleo-1328-1329.sql

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

CREATE OR REPLACE FUNCTION pg_temp.t_rechazo(p jsonb)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT jsonb_typeof(p) = 'object' AND p ? 'exception';
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1328', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_precio numeric DEFAULT 100)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1328', p_precio, 1000, 60, p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(p_cli, p_cant * 100, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100)),
    'ensayo 1328');
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
  VALUES (p_cli, p_ped, p_monto, 'efectivo', p_fecha, p_usuario, p_suc, 'ensayo 1328')
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_detalle(p_user uuid, p_fecha date, p_tr uuid)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT (pg_temp.t_rpc(p_user, format(
    'SELECT to_jsonb(COALESCE(SUM(total), 0)) FROM public.obtener_detalle_rendicion(%L::date, %L::uuid)',
    p_fecha, p_tr)) #>> '{}')::numeric;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_resumen(p_user uuid, p_fecha date, p_tr uuid)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format(
    'SELECT COALESCE(jsonb_agg(jsonb_build_object(''general'', total_general, ''entregas'', total_entregas, '
    '''ctacte'', total_ctascte, ''estado'', estado)), ''[]''::jsonb) '
    'FROM public.obtener_resumen_rendiciones(%L::date, %L::date, NULL) WHERE transportista_id = %L::uuid',
    p_fecha, p_fecha, p_tr));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_confirmar(p_user uuid, p_fecha date, p_tr uuid, p_estado text DEFAULT 'confirmada')
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format('SELECT to_jsonb(public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, p_estado => %L, p_observaciones => ''ensayo 1328'', p_gastos_rendicion => ''{"vistos":[],"guardar":[],"quitar":[]}''::jsonb))', p_fecha, p_tr, p_estado));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_resolver(p_user uuid, p_fecha date, p_tr uuid)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format('SELECT to_jsonb(public.resolver_rendicion(%L::date, %L::uuid, ''ensayo 1328''))', p_fecha, p_tr));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_desmarcar(p_user uuid, p_fecha date, p_tr uuid)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.t_rpc(p_user, format('SELECT ''{}''::jsonb FROM (SELECT public.desmarcar_rendicion_controlada(%L::date, %L::uuid)) x', p_fecha, p_tr));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_fecha date, p_tr uuid, p_suc bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(fo.monto), 0)
    FROM public.rendicion_pagos_confirmados fo
    JOIN public.rendiciones_control rc ON rc.id = fo.rendicion_id
   WHERE rc.fecha = p_fecha AND rc.transportista_id = p_tr AND rc.sucursal_id = p_suc;
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
-- Casos. Firma comun: (admin, transportista, encargado, sucursal)
-- ---------------------------------------------------------------------------

-- R3 · el encargado y su propia rendicion.
CREATE OR REPLACE FUNCTION pg_temp.caso_r3(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 410; c bigint; v_ped bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 R3');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = e WHERE id = v_ped;
  PERFORM pg_temp.t_pago(c, s, v_ped, 100, v_x, a);

  j := pg_temp.t_confirmar(e, v_x, e);
  f := pg_temp.t_si(f, pg_temp.t_rechazo(j), format('el encargado confirmo la suya: %s', j));
  f := pg_temp.t_si(f, position('42501' IN j->>'exception') = 1, format('el rechazo no es 42501: %s', j));
  j := pg_temp.t_confirmar(e, v_x, e, 'disconformidad');
  f := pg_temp.t_si(f, pg_temp.t_rechazo(j), format('el encargado marco la suya en disconformidad: %s', j));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.rendiciones_control
                                    WHERE fecha = v_x AND transportista_id = e AND sucursal_id = s),
                    'el rechazo dejo una fila de control');

  j := pg_temp.t_confirmar(a, v_x, e, 'disconformidad');
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el admin no pudo marcar la del encargado: %s', j));
  j := pg_temp.t_resolver(e, v_x, e);
  f := pg_temp.t_si(f, pg_temp.t_rechazo(j), format('el encargado resolvio la suya: %s', j));
  j := pg_temp.t_desmarcar(e, v_x, e);
  f := pg_temp.t_si(f, pg_temp.t_rechazo(j), format('el encargado borro su disconformidad: %s', j));
  j := pg_temp.t_rpc(e, format('SELECT to_jsonb(public.marcar_rendicion_controlada(%L::date, %L::uuid))', v_x, e));
  f := pg_temp.t_si(f, pg_temp.t_rechazo(j), format('el encargado firmo el control de la suya: %s', j));
  j := pg_temp.t_resolver(a, v_x, e);
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el admin no pudo resolver la del encargado: %s', j));

  -- Otro encargado si puede.
  UPDATE public.perfiles SET rol = 'encargado' WHERE id = tr;
  j := pg_temp.t_confirmar(tr, v_x + 1, e);
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('otro encargado no pudo confirmarla: %s', j));
  UPDATE public.perfiles SET rol = 'transportista' WHERE id = tr;

  j := pg_temp.t_confirmar(e, v_x + 2, tr);
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el encargado no pudo confirmar la de un chofer: %s', j));
  j := pg_temp.t_confirmar(a, v_x + 3, a);
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el admin no pudo confirmar la suya: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- R2 · el pago que llega a un dia cerrado va al primer dia abierto.
CREATE OR REPLACE FUNCTION pg_temp.caso_r2(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 420; c bigint; v_prod bigint;
  v_p1 bigint; v_p2 bigint; v_cred bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 R2');
  v_prod := pg_temp.t_prod(s);
  v_p1 := pg_temp.t_pedido(c, a, v_prod, 1);
  v_p2 := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id IN (v_p1, v_p2);
  PERFORM pg_temp.t_pago(c, s, v_p1, 100, v_x, a);
  -- Un credito que cobro el admin: no es de la rendicion del chofer.
  v_cred := pg_temp.t_pago(c, s, NULL, 60, v_x, a);

  j := pg_temp.t_confirmar(a, v_x, tr);
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('no se pudo confirmar: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_x, tr, s) = 100, format('la foto no da 100: %s', pg_temp.t_foto(v_x, tr, s)));

  -- La reimputacion mueve el credito a la boleta del chofer, con su fecha.
  PERFORM public.aplicar_credito_cliente(c, s);
  f := pg_temp.t_si(f, (SELECT pedido_id FROM public.pagos WHERE id = v_cred) = v_p2, 'el credito no se reimputo');

  f := pg_temp.t_si(f, pg_temp.t_detalle(a, v_x, tr) = 100,
                    format('el dia confirmado sumo el pago: %s', pg_temp.t_detalle(a, v_x, tr)));
  j := pg_temp.t_resumen(a, v_x, tr);
  f := pg_temp.t_si(f, (j->0->>'general')::numeric = 100, format('el resumen del dia confirmado cambio: %s', j));
  f := pg_temp.t_si(f, pg_temp.t_detalle(a, v_x + 1, tr) = 60,
                    format('el pago no fue al dia abierto: %s', pg_temp.t_detalle(a, v_x + 1, tr)));
  j := pg_temp.t_resumen(a, v_x + 1, tr);
  f := pg_temp.t_si(f, (j->0->>'general')::numeric = 60 AND (j->0->>'ctacte')::numeric = 60
                       AND (j->0->>'entregas')::numeric = 0 AND j->0->>'estado' = 'pendiente',
                    format('en el dia abierto no es cuenta corriente pendiente: %s', j));

  -- Confirmar el dia abierto lo guarda en su foto.
  j := pg_temp.t_confirmar(a, v_x + 1, tr);
  f := pg_temp.t_si(f, pg_temp.t_foto(v_x + 1, tr, s) = 60,
                    format('la foto del dia abierto no lo tiene: %s', pg_temp.t_foto(v_x + 1, tr, s)));
  f := pg_temp.t_si(f, pg_temp.t_detalle(a, v_x + 1, tr) = 60, 'el dia abierto, ya cerrado, cambio');
  f := pg_temp.t_si(f, pg_temp.t_detalle(a, v_x + 2, tr) = 0, 'el pago siguio de largo despues de la foto');

  -- Reabrirlo lo devuelve a lo vivo, en el mismo dia.
  j := pg_temp.t_desmarcar(a, v_x + 1, tr);
  f := pg_temp.t_si(f, pg_temp.t_detalle(a, v_x + 1, tr) = 60,
                    format('reabierto el dia, el pago no quedo vivo ahi: %s', pg_temp.t_detalle(a, v_x + 1, tr)));
  -- Reabrir el dia original lo devuelve a su fecha.
  j := pg_temp.t_desmarcar(a, v_x, tr);
  f := pg_temp.t_si(f, pg_temp.t_detalle(a, v_x, tr) = 160 AND pg_temp.t_detalle(a, v_x + 1, tr) = 0,
                    format('reabierto el dia original no da 160 + 0: %s + %s',
                           pg_temp.t_detalle(a, v_x, tr), pg_temp.t_detalle(a, v_x + 1, tr)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- R4 · dos dias seguidos cerrados.
CREATE OR REPLACE FUNCTION pg_temp.caso_r4(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 430; c bigint; v_prod bigint; v_p bigint;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 R4');
  v_prod := pg_temp.t_prod(s);
  v_p := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_p;
  PERFORM pg_temp.t_pago(c, s, NULL, 60, v_x, a);
  PERFORM pg_temp.t_confirmar(a, v_x, tr);
  PERFORM pg_temp.t_confirmar(a, v_x + 1, tr);
  -- v_x + 2 queda sin cerrar: es un hueco, y el pago no va ahi.
  PERFORM pg_temp.t_confirmar(a, v_x + 3, tr);
  PERFORM public.aplicar_credito_cliente(c, s);
  f := pg_temp.t_si(f, pg_temp.t_detalle(a, v_x, tr) = 0 AND pg_temp.t_detalle(a, v_x + 1, tr) = 0
                       AND pg_temp.t_detalle(a, v_x + 2, tr) = 0 AND pg_temp.t_detalle(a, v_x + 3, tr) = 0
                       AND pg_temp.t_detalle(a, v_x + 4, tr) = 60,
                    format('no fue despues del ultimo cerrado: %s, %s, %s, %s, %s', pg_temp.t_detalle(a, v_x, tr),
                           pg_temp.t_detalle(a, v_x + 1, tr), pg_temp.t_detalle(a, v_x + 2, tr),
                           pg_temp.t_detalle(a, v_x + 3, tr), pg_temp.t_detalle(a, v_x + 4, tr)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- P1 · la Red de posicion_fiscal.
CREATE OR REPLACE FUNCTION pg_temp.caso_p1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_rep jsonb; v_d date := date_trunc('month', pg_temp.t_hoy())::date;
BEGIN
  f := pg_temp.t_si(f, pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure) ~ '_sucursales_red\(\)',
                    'posicion_fiscal no usa _sucursales_red()');
  v_rep := pg_temp.t_rpc(a, format('SELECT public.posicion_fiscal(NULL, %L::date, %L::date)', v_d, pg_temp.t_hoy()));
  f := pg_temp.t_si(f, v_rep->'meta'->>'sucursal_nombre' = 'Red (consolidado)', format('la Red fallo: %s', v_rep));
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', format('iva debito Red %s', v_rep#>>'{posicion,iva_debito}'));
END
$fn$;

-- C1 · canje con diferencia.
CREATE OR REPLACE FUNCTION pg_temp.caso_c1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_barato bigint; v_caro bigint; j jsonb; v_sal jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 C1');
  v_barato := pg_temp.t_prod(s, 100);
  v_caro := pg_temp.t_prod(s, 300);

  -- Se lleva lo caro: diferencia +200.
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.registrar_cambio_producto(%s, %s, 1, %s, 1, ''ensayo 1328'', ''erroneo''))', c, v_barato, v_caro));
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el canje fallo: %s', j));
  v_sal := pg_temp.t_saldo(c);
  f := pg_temp.t_si(f, (v_sal->>'saldo')::numeric = (v_sal->>'cuenta')::numeric,
                    format('canje +200: saldo_cuenta no cierra (CC-A): %s', v_sal));
  f := pg_temp.t_si(f, (SELECT diferencia_monto FROM public.cambios_productos WHERE cliente_id = c ORDER BY id DESC LIMIT 1) = 200,
                    'la diferencia no quedo en cambios_productos');
  f := pg_temp.t_si(f, (SELECT stock FROM public.productos WHERE id = v_caro) = 999
                       AND (SELECT stock FROM public.productos WHERE id = v_barato) = 1001,
                    'el canje no movio el stock');

  -- Devuelve lo caro: diferencia -200.
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(public.registrar_cambio_producto(%s, %s, 1, %s, 1, ''ensayo 1328'', ''erroneo''))', c, v_caro, v_barato));
  v_sal := pg_temp.t_saldo(c);
  f := pg_temp.t_si(f, (v_sal->>'saldo')::numeric = (v_sal->>'cuenta')::numeric,
                    format('canje -200: saldo_cuenta no cierra (CC-A): %s', v_sal));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- E1 · eliminar_pedido_completo y las rendiciones cerradas del sistema viejo.
CREATE OR REPLACE FUNCTION pg_temp.caso_e1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_fn text := 'public.eliminar_pedido_completo(bigint,uuid,text,boolean)'; j jsonb;
BEGIN
  f := pg_temp.t_si(f, NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
                       AND NOT has_function_privilege('anon', v_fn, 'EXECUTE'),
                    'eliminar_pedido_completo se ejecuta por REST');
  j := pg_temp.t_rpc(a, format('SELECT public.eliminar_pedido_completo(1, %L, ''ensayo 1328'', true)', a));
  f := pg_temp.t_si(f, position('42501' IN COALESCE(j->>'exception', '')) = 1, format('el admin por REST: %s', j));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.rendiciones WHERE estado <> 'pendiente'),
                    'hay una rendicion del sistema viejo cerrada');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte',
    format('rendiciones viejas: %s, items: %s', (SELECT count(*) FROM public.rendiciones), (SELECT count(*) FROM public.rendicion_items)));
END
$fn$;

-- D1 · baja el total de una boleta pagada por FIFO, y de una cobrada por boleta.
CREATE OR REPLACE FUNCTION pg_temp.caso_d1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 440; c bigint; c2 bigint; v_prod bigint; v_ped bigint; v_ped2 bigint;
  j jsonb; v_sal jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 D1');
  v_prod := pg_temp.t_prod(s);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 2);
  j := pg_temp.t_rpc(a, format('SELECT public.registrar_pago_cliente_fifo(%s, 200, ''efectivo'', %L::date, NULL, ''ensayo 1328'', %L::uuid)',
                               c, v_x, gen_random_uuid()));
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el pago FIFO fallo: %s', j));

  UPDATE public.pedidos SET total = 150 WHERE id = v_ped;
  v_sal := pg_temp.t_saldo(c);
  f := pg_temp.t_si(f, (v_sal->>'saldo')::numeric = (v_sal->>'cuenta')::numeric, format('el saldo no cierra: %s', v_sal));
  f := pg_temp.t_si(f, (v_sal->>'a_favor')::numeric = 50,
                    format('los 50 del pago FIFO se perdieron: %s; pagos del dia %s', v_sal,
                           (SELECT SUM(monto) FROM public.pagos WHERE cliente_id = c)));
  f := pg_temp.t_si(f, (SELECT SUM(monto) FROM public.pagos WHERE cliente_id = c) = 200, 'la plata del dia cambio');

  -- Cobro de boleta: se recorta (la regla de 165-168), no deja credito.
  c2 := pg_temp.t_cliente(s, 'ZZ ensayo 1328 D1b');
  v_ped2 := pg_temp.t_pedido(c2, a, v_prod, 2);
  j := pg_temp.t_rpc(a, format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date, %L::uuid)',
                               v_ped2, '[{"forma_pago":"efectivo","monto":200}]', v_x - 800, gen_random_uuid()));
  IF pg_temp.t_rechazo(j) THEN
    PERFORM pg_temp.t_pago(c2, s, v_ped2, 200, v_x, a);
  END IF;
  UPDATE public.pedidos SET total = 150 WHERE id = v_ped2;
  v_sal := pg_temp.t_saldo(c2);
  f := pg_temp.t_si(f, (v_sal->>'a_favor')::numeric = 0
                       AND (SELECT SUM(monto) FROM public.pagos WHERE cliente_id = c2) = 150,
                    format('el cobro de boleta no se recorto: %s', v_sal));

  -- Un credito imputado entero, que no vino de un FIFO: tambien queda a favor.
  c2 := pg_temp.t_cliente(s, 'ZZ ensayo 1328 D1c');
  v_ped2 := pg_temp.t_pedido(c2, a, v_prod, 2);
  PERFORM pg_temp.t_pago(c2, s, NULL, 200, v_x, a);
  PERFORM public.aplicar_credito_cliente(c2, s);
  UPDATE public.pedidos SET total = 150 WHERE id = v_ped2;
  v_sal := pg_temp.t_saldo(c2);
  f := pg_temp.t_si(f, (v_sal->>'a_favor')::numeric = 50 AND (v_sal->>'saldo')::numeric = (v_sal->>'cuenta')::numeric,
                    format('el credito imputado se perdio: %s', v_sal));

  -- Un adelanto de sueldo por FIFO se recorta. Desde la mig 430 el adelanto
  -- sólo va a la ficha de cliente de un empleado (trigger pagos_cuenta_empleado):
  -- el cliente del caso es la ficha de un empleado creado acá (se deshace).
  c2 := pg_temp.t_cliente(s, 'ZZ ensayo 1328 D1d');
  INSERT INTO public.empleados (sucursal_id, nombre, puesto, cliente_id, creado_por)
  VALUES (s, 'ZZ ensayo 1328 D1d', 'otro', c2, a);
  v_ped2 := pg_temp.t_pedido(c2, a, v_prod, 2);
  j := pg_temp.t_rpc(a, format('SELECT public.registrar_pago_cliente_fifo(%s, 200, ''adelanto_sueldo'', %L::date, NULL, ''ensayo 1328'', %L::uuid)',
                               c2, v_x, gen_random_uuid()));
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el adelanto FIFO fallo: %s', j));
  UPDATE public.pedidos SET total = 150 WHERE id = v_ped2;
  v_sal := pg_temp.t_saldo(c2);
  f := pg_temp.t_si(f, (v_sal->>'a_favor')::numeric = 0
                       AND (SELECT SUM(monto) FROM public.pagos WHERE cliente_id = c2) = 150,
                    format('el adelanto no se recorto: %s', v_sal));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- S1 · las salvedades de un vale blanco.
CREATE OR REPLACE FUNCTION pg_temp.caso_s1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_prod bigint; v_vb bigint; v_comun bigint; v_item bigint; j jsonb;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 S1');
  v_prod := pg_temp.t_prod(s);
  v_vb := pg_temp.t_pedido(c, a, v_prod, 1);
  v_comun := pg_temp.t_pedido(c, a, v_prod, 1);
  UPDATE public.pedidos SET transportista_id = tr, estado = 'entregado' WHERE id IN (v_vb, v_comun);
  UPDATE public.pedidos SET tipo_factura = 'VB', total = total, monto_pagado = total, estado_pago = 'pagado' WHERE id = v_vb;

  FOR v_item IN SELECT id FROM public.pedido_items WHERE pedido_id IN (v_vb, v_comun) LOOP
    INSERT INTO public.salvedades_items (pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
                                         cantidad_entregada, motivo, monto_afectado, precio_unitario, reportado_por, sucursal_id)
    SELECT pi.pedido_id, pi.id, pi.producto_id, pi.cantidad, 1, 0, 'producto_danado', 60, 60, a, s
      FROM public.pedido_items pi WHERE pi.id = v_item;
  END LOOP;

  j := pg_temp.t_rpc(tr, format('SELECT to_jsonb(count(*)) FROM public.salvedades_items WHERE pedido_id = %s', v_vb));
  f := pg_temp.t_si(f, (j #>> '{}')::int = 0, format('el chofer ve la salvedad del VB: %s', j));
  j := pg_temp.t_rpc(tr, format('SELECT to_jsonb(count(*)) FROM public.salvedades_items WHERE pedido_id = %s', v_comun));
  f := pg_temp.t_si(f, (j #>> '{}')::int = 1, format('el chofer no ve la salvedad de su boleta: %s', j));
  j := pg_temp.t_rpc(a, format('SELECT to_jsonb(count(*)) FROM public.salvedades_items WHERE pedido_id = %s', v_vb));
  f := pg_temp.t_si(f, (j #>> '{}')::int = 1, format('el admin no ve la salvedad del VB: %s', j));
  -- El vendedor del VB sigue viendola: ve la linea entera por mt_pedido_items_select.
  UPDATE public.pedidos SET usuario_id = tr WHERE id = v_vb;
  j := pg_temp.t_rpc(tr, format('SELECT to_jsonb(count(*)) FROM public.salvedades_items WHERE pedido_id = %s', v_vb));
  f := pg_temp.t_si(f, (j #>> '{}')::int = 1, format('el vendedor no ve la salvedad de su VB: %s', j));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- F1 · el mismo criterio de caja cerrada.
CREATE OR REPLACE FUNCTION pg_temp.caso_f1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_x date := pg_temp.t_hoy() + 450; c bigint; v_ped bigint; v_pago bigint; j jsonb; v_guard text;
BEGIN
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 F1');
  v_ped := pg_temp.t_pedido(c, a, pg_temp.t_prod(s), 1);
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = tr WHERE id = v_ped;
  v_pago := pg_temp.t_pago(c, s, v_ped, 100, v_x, a);

  -- Ese dia nadie cerro; se cierra el siguiente.
  j := pg_temp.t_confirmar(a, v_x + 1, a);
  f := pg_temp.t_si(f, NOT public.rendicion_dia_cerrada(v_x, s), 'el setup cerro el dia del pago');

  BEGIN
    UPDATE public.pagos SET monto = 90 WHERE id = v_pago;
    v_guard := 'pasa';
  EXCEPTION WHEN OTHERS THEN
    v_guard := SQLSTATE;
  END;
  f := pg_temp.t_si(f, v_guard = '42501', format('el guard no rechazo el monto: %s', v_guard));

  j := pg_temp.t_rpc(a, format('SELECT public.actualizar_forma_pago_pago(%s, ''transferencia'')', v_pago));
  f := pg_temp.t_si(f, position('42501' IN COALESCE(j->>'exception', '')) = 1,
                    format('el guard rechaza y la forma de pago pasa: %s', j));
  f := pg_temp.t_si(f, (SELECT forma_pago FROM public.pagos WHERE id = v_pago) = 'efectivo', 'la forma de pago cambio');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- V1 · el sistema viejo.
CREATE OR REPLACE FUNCTION pg_temp.caso_v1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['public.crear_rendicion_recorrido(bigint,uuid)',
                           'public.presentar_rendicion(bigint,numeric,text)',
                           'public.revisar_rendicion(bigint,character varying,text)',
                           'public.es_admin_rendiciones()'] LOOP
    f := pg_temp.t_si(f, to_regprocedure(v) IS NULL, format('sigue viva: %s', v));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- O1 · el origen del precio.
CREATE OR REPLACE FUNCTION pg_temp.caso_o1(a uuid, tr uuid, e uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; c bigint; v_prod bigint; v_ped bigint; v_otra bigint; v_ped_otra bigint; j jsonb; v_or text;
  v_hdr text := current_setting('request.headers', true); v_skip text;
BEGIN
  v_or := '[]';
  c := pg_temp.t_cliente(s, 'ZZ ensayo 1328 O1');
  v_prod := pg_temp.t_prod(s);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 1);
  v_or := jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'origen_precio', 'manual'))::text;

  -- Con sesion, en su sucursal: anda como siempre. Sin p_perfil_id, como el front.
  j := pg_temp.t_rpc(a, format('SELECT public.registrar_origen_precio_items(%s, %L::jsonb)', v_ped, v_or));
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('en su sucursal fallo: %s', j));

  -- Con sesion, p_perfil_id de otro.
  j := pg_temp.t_rpc(a, format('SELECT public.registrar_origen_precio_items(%s, %L::jsonb, %L::uuid)', v_ped, v_or, tr));
  f := pg_temp.t_si(f, position('42501' IN COALESCE(j->>'exception', '')) = 1,
                    format('con sesion acepto el perfil de otro: %s', j));

  -- Con sesion, un pedido de otra sucursal.
  SELECT us.sucursal_id INTO v_otra FROM public.usuario_sucursales us
   WHERE us.usuario_id = a AND us.sucursal_id <> s ORDER BY 1 LIMIT 1;
  IF v_otra IS NULL THEN
    -- El admin del ensayo esta en una sola sucursal (la base local de pruebas):
    -- se lo suma a otra activa; el caso se deshace entero con su subbloque.
    SELECT x.id INTO v_otra FROM public.sucursales x WHERE x.activa AND x.id <> s ORDER BY x.id LIMIT 1;
    IF v_otra IS NULL THEN
      RAISE NOTICE 'O1: no hay una segunda sucursal activa; se saltea el caso del pedido de otra sucursal';
      v_skip := 'no hay una segunda sucursal activa: salteado';
    ELSE
      INSERT INTO public.usuario_sucursales (usuario_id, sucursal_id) VALUES (a, v_otra);
    END IF;
  END IF;
  IF v_otra IS NOT NULL THEN
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_otra::text)::text, true);
    c := pg_temp.t_cliente(v_otra, 'ZZ ensayo 1328 O1b');
    v_ped_otra := pg_temp.t_pedido(c, a, pg_temp.t_prod(v_otra), 1);
    PERFORM set_config('request.headers', v_hdr, true);
    j := pg_temp.t_rpc(a, format('SELECT public.registrar_origen_precio_items(%s, %L::jsonb)', v_ped_otra, v_or));
    f := pg_temp.t_si(f, position('42501' IN COALESCE(j->>'exception', '')) = 1,
                      format('escribio un pedido de otra sucursal: %s', j));
  END IF;

  -- El server, sin sesion: el dueno pasa, otro no.
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    j := public.registrar_origen_precio_items(v_ped, v_or::jsonb, a);
  EXCEPTION WHEN OTHERS THEN
    j := jsonb_build_object('exception', SQLSTATE || ' ' || SQLERRM);
  END;
  f := pg_temp.t_si(f, NOT pg_temp.t_rechazo(j), format('el server, con el dueno, fallo: %s', j));
  BEGIN
    j := public.registrar_origen_precio_items(v_ped, v_or::jsonb, tr);
  EXCEPTION WHEN OTHERS THEN
    j := jsonb_build_object('exception', SQLSTATE || ' ' || SQLERRM);
  END;
  f := pg_temp.t_si(f, pg_temp.t_rechazo(j), format('el server paso con un perfil que no es el dueno: %s', j));
  PERFORM set_config('request.jwt.claims', json_build_object('sub', a, 'role', 'authenticated')::text, true);
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', COALESCE(v_skip, ''));
END
$fn$;

-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_tr     uuid;
  v_enc    uuid;
  v_suc    bigint;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
  v_rep    text[] := '{}';
  v_salt   text[] := '{}';
BEGIN
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'admin')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'transportista')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'encargado')
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con admin, transportista y encargado activos';
  END IF;
  -- El admin con mas sucursales: O1 necesita dos.
  SELECT us.usuario_id INTO v_admin FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin'
   ORDER BY (SELECT count(*) FROM usuario_sucursales x WHERE x.usuario_id = us.usuario_id) DESC, us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_tr FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'transportista' ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_enc FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'encargado' ORDER BY us.usuario_id LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['r3', 'r2', 'r4', 'p1', 'c1', 'e1', 'd1', 's1', 'f1', 'v1', 'o1'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4)', v_caso)
        INTO v_out USING v_admin, v_tr, v_enc, v_suc;
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
        IF v_out->>'reporte' LIKE '%salteado%' THEN v_salt := v_salt || upper(v_caso); END IF;
      END IF;
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %\n\nREPORTE\n%',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_rep, E'\n');
  END IF;
  RAISE EXCEPTION E'ENSAYO OK%\n\nREPORTE\n%',
    CASE WHEN cardinality(v_salt) > 0 THEN format(' (salteados: %s)', array_to_string(v_salt, ', ')) ELSE '' END,
    array_to_string(v_rep, E'\n');
END
$ensayo$;
