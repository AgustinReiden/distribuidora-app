-- Ensayo de los seguimientos de la baja (#1147, #1149, #1150).
--
-- Tienen que rechazarse:
--   E1  · #1147: admin por REST llama eliminar_pedido_completo -> 42501
--         permission denied, y el pedido sigue. ACL: PUBLIC, anon y
--         authenticated sin EXECUTE; service_role con EXECUTE (solo control
--         de ACL: por la service key la funcion no corre, auth.uid() es NULL)
--   C2  · #1150 (controles con la caja cerrada): un UUID nuevo, un pago sin
--         UUID y el UPDATE del monto de un pago con UUID siguen dando 42501
--         'caja cerrada': el corte es solo para el reintento en INSERT
-- Tienen que pasar:
--   C1  · #1150: pago por REST con UUID, se cierra la caja de su fecha, el
--         reintento con el mismo UUID da 23505 (no 42501 'caja cerrada') y no
--         duplica
--   E2  · regresion #1147: como postgres con los claims del admin, cancelar y
--         despues eliminar_pedido_completo sigue andando (no restaura de nuevo,
--         deja su fila en pedidos_eliminados)
--   C3  · #1149 con #1150, regresion de la decision A: el transportista paga
--         con UUID un pedido suyo, se cancela, conserva transportista_id, el
--         pago queda desimputado y el reintento del transportista da 23505 (no
--         42501 de RLS ni 22023 de la 360). Control: una NC a mano por REST
--         sigue rechazada por pagos_guard_nota_credito
--   K1  · #1149: el COMMENT ON COLUMN de pedidos.transportista_id
--
-- Contra prod sin la migracion falla en E1, C1 y K1, y solo ahi (C1 con 42501
-- 'caja ... cerrada'); E2, C2 y C3 pasan igual.
--
-- Fechas de pago futuras (hoy + 400 y + 401): ninguna regla de pagos ni de
-- rendiciones_control mira fecha futura, y asi no chocan con las cajas reales
-- ni con el UNIQUE (fecha, transportista_id, sucursal_id) de
-- rendiciones_control. La bolsa es distinta de 0 en todos los fixtures
-- (CLAUDE.md).
--
-- Simula PostgREST como test-pedido-baja-1131.sql (el molde): SET LOCAL ROLE,
-- el sub en request.jwt.claims y la sucursal en x-sucursal-id.
--
-- Corre contra prod SIN dejar rastro: cada caso corre en un subbloque que se
-- revierte. Si algo falla, el bloque corta con RAISE EXCEPTION 'ENSAYO FALLO'
-- y la lista; si no, avisa 'ENSAYO OK' (NOTICE) y todo termina en RAISE
-- EXCEPTION 'ENSAYO_ROLLBACK'.
--
--   psql "$DATABASE_URL" -f scripts/test-seguimientos-baja-1147-1149-1150.sql

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
  VALUES ('ZZ ensayo 1147-1150', 100,
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
    'ensayo 1147-1150');
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
  v_res := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1147-1150', p_adm, p_tipo);
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

-- El INSERT de un pago como lo arma el front, con UUID (o sin el, si es NULL) y fecha.
CREATE OR REPLACE FUNCTION pg_temp.t_sql_pago(p_cli bigint, p_suc bigint, p_ped bigint, p_uuid uuid, p_fecha date)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, pedido_id, forma_pago, notas, client_request_id, fecha) '
                'VALUES (%s, 100, %s, %s, ''efectivo'', ''ensayo 1150'', %L, %L)',
                p_cli, p_suc, COALESCE(p_ped::text, 'NULL'), p_uuid, p_fecha);
$fn$;

-- Cierra la caja de `p_fecha` (control confirmado), como postgres (setup).
CREATE OR REPLACE FUNCTION pg_temp.t_cerrar_caja(p_fecha date, p_tr uuid, p_suc bigint, p_adm uuid)
RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO public.rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_por)
  VALUES (p_fecha, p_tr, p_suc, 'confirmada', p_adm)
  ON CONFLICT (fecha, transportista_id, sucursal_id) DO UPDATE SET estado = 'confirmada';
$fn$;

-- ---------------------------------------------------------------------------
-- Casos. Firma comun: (cliente, cliente2, admin, transportista, preventista, sucursal)
-- ---------------------------------------------------------------------------

-- E1 · #1147: la app ya no ejecuta eliminar_pedido_completo.
CREATE OR REPLACE FUNCTION pg_temp.caso_e1(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_fn text := 'public.eliminar_pedido_completo(bigint,uuid,text,boolean)';
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text;
BEGIN
  f := pg_temp.t_si(f, NOT has_function_privilege('authenticated', v_fn, 'EXECUTE'), 'authenticated tiene EXECUTE');
  f := pg_temp.t_si(f, NOT has_function_privilege('anon', v_fn, 'EXECUTE'), 'anon tiene EXECUTE');
  f := pg_temp.t_si(f, NOT has_function_privilege('public', v_fn, 'EXECUTE'), 'PUBLIC tiene EXECUTE');
  f := pg_temp.t_si(f, has_function_privilege('service_role', v_fn, 'EXECUTE'), 'service_role perdio EXECUTE');
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 5);
  r := pg_temp.t_rest(a, 'authenticated',
         format('SELECT public.eliminar_pedido_completo(%s, %L, ''ensayo 1147'', true)', v_ped, a));
  f := pg_temp.t_rech(f, 'admin REST eliminar_pedido_completo', r, '42501',
                      '%permission denied for function eliminar_pedido_completo%');
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.pedidos WHERE id = v_ped),
                    'el admin borro el pedido por REST');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- E2 · regresion #1147: como postgres con los claims del admin, sigue andando.
CREATE OR REPLACE FUNCTION pg_temp.caso_e2(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; f0 jsonb; v_res jsonb;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 5);
  PERFORM pg_temp.t_cancelar(v_ped, a);
  f0 := pg_temp.t_foto(v_prod);
  v_res := pg_temp.t_rpc(format('SELECT public.eliminar_pedido_completo(%s, %L, ''ensayo 1147'', true)', v_ped, a));
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false),
                    format('eliminar_pedido_completo como postgres no anduvo: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_prod) = f0,
                    format('eliminar un cancelado volvio a restaurar: %s -> %s', f0, pg_temp.t_foto(v_prod)));
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pedidos_eliminados WHERE pedido_id = v_ped) = 1,
                    'no quedo exactamente una fila en pedidos_eliminados');
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pedidos WHERE id = v_ped),
                    'el pedido sigue existiendo');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', v_res::text);
END
$fn$;

-- C1 · #1150: el reintento con la caja cerrada en el medio llega al 23505.
CREATE OR REPLACE FUNCTION pg_temp.caso_c1(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text;
  v_uuid uuid := gen_random_uuid(); v_f date := pg_temp.t_hoy() + 400; v_sql text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 5);
  v_sql := pg_temp.t_sql_pago(c, s, v_ped, v_uuid, v_f);
  r := pg_temp.t_rest(a, 'authenticated', v_sql);
  f := pg_temp.t_pasa(f, 'pago con UUID', r);
  PERFORM pg_temp.t_cerrar_caja(v_f, tr, s, a);
  f := pg_temp.t_si(f, public.ultima_fecha_caja_cerrada(s) = v_f, 'la caja del ensayo no quedo cerrada');
  r := pg_temp.t_rest(a, 'authenticated', v_sql);
  f := pg_temp.t_rech(f, 'reintento con caja cerrada en el medio', r, '23505', '%idx_pagos_client_request_id%');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pagos WHERE client_request_id = v_uuid) = 1,
                    'el reintento duplico el pago');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- C2 · #1150, controles: con la caja cerrada todo lo demas sigue rechazado.
CREATE OR REPLACE FUNCTION pg_temp.caso_c2(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text; v_pago bigint;
  v_uuid uuid := gen_random_uuid(); v_f date := pg_temp.t_hoy() + 400;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 5);
  r := pg_temp.t_rest(a, 'authenticated', pg_temp.t_sql_pago(c, s, v_ped, v_uuid, v_f));
  f := pg_temp.t_pasa(f, 'pago con UUID', r);
  SELECT id INTO v_pago FROM public.pagos WHERE client_request_id = v_uuid;
  PERFORM pg_temp.t_cerrar_caja(v_f, tr, s, a);
  -- (a) un UUID nuevo con fecha cerrada
  r := pg_temp.t_rest(a, 'authenticated', pg_temp.t_sql_pago(c, s, v_ped, gen_random_uuid(), v_f));
  f := pg_temp.t_rech(f, 'UUID nuevo con caja cerrada', r, '42501', '%caja de la sucursal esta cerrada%');
  -- (b) sin client_request_id
  r := pg_temp.t_rest(a, 'authenticated', pg_temp.t_sql_pago(c, s, v_ped, NULL, v_f));
  f := pg_temp.t_rech(f, 'pago sin UUID con caja cerrada', r, '42501', '%caja de la sucursal esta cerrada%');
  -- (c) UPDATE del monto del pago con UUID: el corte es solo para INSERT
  r := pg_temp.t_pg(format('UPDATE public.pagos SET monto = 101 WHERE id = %s', v_pago));
  f := pg_temp.t_rech(f, 'UPDATE monto de un pago con UUID y caja cerrada', r, '42501', '%caja de la sucursal esta cerrada%');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pagos WHERE pedido_id = v_ped) = 1
                       AND (SELECT monto FROM public.pagos WHERE id = v_pago) = 100,
                    'con la caja cerrada entro o cambio un pago');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- C3 · #1149 + #1150: el reintento del transportista sobre su pedido cancelado.
CREATE OR REPLACE FUNCTION pg_temp.caso_c3(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod bigint; v_ped bigint; f text[] := '{}'; r text; v_pago bigint;
  v_uuid uuid := gen_random_uuid(); v_sql text;
BEGIN
  v_prod := pg_temp.t_prod_std(s, a);
  v_ped := pg_temp.t_pedido(c, a, v_prod, 5);
  PERFORM pg_temp.t_asignar(v_ped, tr);
  v_sql := pg_temp.t_sql_pago(c, s, v_ped, v_uuid, pg_temp.t_hoy() + 401);
  r := pg_temp.t_rest(tr, 'authenticated', v_sql);
  f := pg_temp.t_pasa(f, 'pago del transportista con UUID', r);
  SELECT id INTO v_pago FROM public.pagos WHERE client_request_id = v_uuid;
  PERFORM pg_temp.t_cancelar(v_ped, a);
  f := pg_temp.t_si(f, (SELECT transportista_id = tr FROM public.pedidos WHERE id = v_ped),
                    'la baja no conservo el transportista_id');
  f := pg_temp.t_si(f, (SELECT pedido_id IS NULL FROM public.pagos WHERE id = v_pago),
                    'la cancelacion no desimputo el pago del transportista');
  r := pg_temp.t_rest(tr, 'authenticated', v_sql);
  f := pg_temp.t_rech(f, 'reintento del transportista tras cancelar', r, '23505', '%idx_pagos_client_request_id%');
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.pagos WHERE client_request_id = v_uuid) = 1,
                    'el reintento del transportista duplico el pago');
  -- control: una NC a mano por REST sigue rechazada por pagos_guard_nota_credito
  r := pg_temp.t_rest(a, 'authenticated',
         format('INSERT INTO public.pagos (cliente_id, monto, sucursal_id, forma_pago, notas, client_request_id) '
                'VALUES (%s, 100, %s, ''nota_credito'', ''ensayo 1150'', %L)', c, s, gen_random_uuid()));
  f := pg_temp.t_rech(f, 'NC a mano por REST', r, '42501', '%no se registra a mano%');
  RETURN jsonb_build_object('fallas', to_jsonb(f), 'reporte', r);
END
$fn$;

-- K1 · #1149: la decision queda dicha en la columna.
CREATE OR REPLACE FUNCTION pg_temp.caso_k1(c bigint, c2 bigint, a uuid, tr uuid, pv uuid, s bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  f := pg_temp.t_si(f, col_description('public.pedidos'::regclass,
         (SELECT attnum FROM pg_attribute WHERE attrelid = 'public.pedidos'::regclass AND attname = 'transportista_id'))
         LIKE '%#1149%',
       'pedidos.transportista_id no tiene el COMMENT de #1149');
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
  -- Un transportista puro (sin rol extra): la rama de RLS que interesa en C3.
  SELECT us.usuario_id INTO v_tr FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
   WHERE us.sucursal_id = v_suc AND pf.rol = 'transportista'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)
   ORDER BY us.usuario_id LIMIT 1;
  IF v_tr IS NULL THEN
    SELECT us.usuario_id INTO v_tr FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
     WHERE us.sucursal_id = v_suc AND pf.rol = 'transportista' ORDER BY us.usuario_id LIMIT 1;
  END IF;
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

  FOREACH v_caso IN ARRAY ARRAY['e1', 'e2', 'c1', 'c2', 'c3', 'k1'] LOOP
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

  -- La falla corta aca (y revierte); el OK sigue hasta el ENSAYO_ROLLBACK de
  -- abajo, asi que llegar a el ya dice que dio OK.
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %\n\nREPORTE\n%',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_rep, E'\n');
  END IF;
  RAISE NOTICE E'ENSAYO OK\n\nREPORTE\n%', array_to_string(v_rep, E'\n');
END
$ensayo$;

DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
