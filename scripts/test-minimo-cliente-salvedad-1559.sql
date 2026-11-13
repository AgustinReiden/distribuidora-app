-- Ensayo de la migración de la tarjeta 6 de #1565 (CAT-3, SEG-1 y COB-1 de #1559).
--
-- Los casos L fallan sin la migración; los E pasan con y sin ella:
--
--   CAT-3 · el mínimo de venta rige lo nuevo y lo que baja (trigger diferido: SET CONSTRAINTS ALL IMMEDIATE)
--   L1 · Pedido con 5 u. de M1; el mínimo de M1 pasa a 12. Editar sumándole M2 (M1 sigue en 5) entra, y subir
--        M1 a 8 (todavía debajo de 12) también.
--   E1 · Bajar M1 a 4 se rechaza (23514), y sumar un producto nuevo M3 debajo de su mínimo también.
--
--   SEG-1 · el alta no nombra a un cliente de otra sucursal
--   L2 · Un preventista de la sucursal A carga un pedido de A con el id de un cliente de B asignado a otro
--        preventista, y con el de un cliente reservado de B: los dos responden exactamente lo mismo que un id
--        que no existe (23503, sin el nombre).
--   E2 · Con un cliente de A asignado a otro preventista de A sigue respondiendo 42501 con su nombre, y con uno
--        reservado de A, 42501 «reservado a administración».
--
--   COB-1 · anular una salvedad repone el cobro que recortó (decisión del dueño, 12/11)
--   L3 · Boleta de 100 cobrada entera por el chofer; salvedad de 20 (el cobro baja a 80); la anulación deja el
--        cobro en 100, la boleta pagada y el saldo del cliente en 0. La salvedad guardó el recorte.
--   L4 · Dos cobros de 50; salvedad de 60 (borra el más nuevo y deja el otro en 40); la anulación vuelve a 100:
--        el borrado vuelve como un cobro nuevo con su forma, su fecha y su chofer.
--   L5 · Dos salvedades (20 y 30) sobre la misma boleta, anuladas en el orden inverso: el cobro vuelve a 100.
--   E3 · El cobro recortado se borró a mano después: la anulación no lo inventa y lo informa (20 sin reponer).
--   E4 · Una boleta pagada por el FIFO de la ficha (a cuenta): la salvedad deja el excedente a favor y no
--        anota recorte; la anulación no repone nada.
--   L6 · Los cuerpos, el definer y los EXECUTE de las seis funciones son los de la migración.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una
-- excepción, y cada caso en un sub-bloque que se revierte. Crea sus usuarios, clientes y productos en las dos
-- primeras sucursales activas. Sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por los L.

CREATE OR REPLACE FUNCTION pg_temp.t6_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.omitir_minimo_venta', '', true);
  -- Lo que la edición anota para el mínimo dura la transacción: entre pasos se borra, como un COMMIT.
  PERFORM set_config('app.minimo_venta_previo', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_usuario(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'T6 ' || p_rol), now(), now());
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_cliente(p_suc bigint, p_nombre text, p_reservado boolean DEFAULT false)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id, reservado_admin)
  VALUES (p_nombre, p_nombre, 'Ensayo 1559', p_suc, p_reservado)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_producto(p_suc bigint, p_nombre text, p_precio numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, p_precio, 100000, 1, p_suc)
  RETURNING id;
$fn$;

-- Alta de una boleta; p_items es el JSON del alta. Devuelve el id.
CREATE OR REPLACE FUNCTION pg_temp.t6_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t6_claims(p_user, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  v_res := public.crear_pedido_completo(
    p_cli, (SELECT sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_user, p_items, 'ensayo 1559', 'efectivo', 'pendiente', public._tablero_hoy(), 'ZZ');
  PERFORM pg_temp.t6_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- La edición de ítems confirmada (los diferidos disparan): 'OK' o 'ERR <sqlstate>'.
CREATE OR REPLACE FUNCTION pg_temp.t6_editar(p_ped bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t6_reset();
  PERFORM pg_temp.t6_claims(p_user, p_suc);
  BEGIN
    v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t6_reset();
    RETURN 'ERR ' || SQLSTATE;
  END;
  PERFORM pg_temp.t6_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RETURN 'ERR ' || v_res::text;
  END IF;
  RETURN 'OK';
END
$fn$;

-- Una boleta de p_cant unidades de $1, entregada por el chofer p_tra.
CREATE OR REPLACE FUNCTION pg_temp.t6_boleta(p_cli bigint, p_adm uuid, p_tra uuid, p_suc bigint, p_prod bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_ped bigint;
BEGIN
  v_ped := pg_temp.t6_alta(p_cli, p_adm, p_suc,
             jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 1)));
  UPDATE public.pedidos SET transportista_id = p_tra, estado = 'entregado', fecha_entrega = now() WHERE id = v_ped;
  RETURN v_ped;
END
$fn$;

-- El chofer cobra la boleta (registrar_pagos_pedido), con los montos dados.
CREATE OR REPLACE FUNCTION pg_temp.t6_cobrar(p_ped bigint, p_tra uuid, p_suc bigint, p_montos numeric[])
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t6_claims(p_tra, p_suc);
  v_res := public.registrar_pagos_pedido(
    p_ped,
    (SELECT jsonb_agg(jsonb_build_object('monto', m, 'forma_pago', 'efectivo')) FROM unnest(p_montos) m),
    public._tablero_hoy());
  PERFORM pg_temp.t6_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, true) OR v_res ? 'error' THEN
    RAISE EXCEPTION 'no se pudo cobrar: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_salvedad(p_ped bigint, p_cant int, p_adm uuid, p_suc bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t6_claims(p_adm, p_suc);
  v_res := public.registrar_salvedad(p_ped, (SELECT min(id) FROM public.pedido_items WHERE pedido_id = p_ped),
                                     p_cant, 'cliente_rechaza', 'ensayo 1559', NULL, true, NULL);
  PERFORM pg_temp.t6_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la salvedad no entró: %', v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_anular(p_salv bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t6_claims(p_adm, p_suc);
  v_res := public.anular_salvedad(p_salv, 'ensayo 1559');
  PERFORM pg_temp.t6_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la anulación no entró: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

-- 'pagado/total estado_pago' de una boleta.
CREATE OR REPLACE FUNCTION pg_temp.t6_est(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(monto_pagado, 0)::numeric(12,2)::text || '/' || total::numeric(12,2)::text || ' ' || COALESCE(estado_pago, '?')
    FROM public.pedidos WHERE id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_saldo(p_cli bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(saldo_cuenta, 0) FROM public.clientes WHERE id = p_cli;
$fn$;

-- ---------------------------------------------------------------------------
-- CAT-3
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.t6_caso_l1(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc_a')::bigint;
  v_adm uuid := (a->>'adm_a')::uuid;
  v_cli bigint := pg_temp.t6_cliente(v_suc, 'T6 C moq');
  v_m1  bigint := pg_temp.t6_producto(v_suc, 'T6 M1', 100);
  v_m2  bigint := pg_temp.t6_producto(v_suc, 'T6 M2', 50);
  v_ped bigint;
  v_r   text;
BEGIN
  v_ped := pg_temp.t6_alta(v_cli, v_adm, v_suc,
             jsonb_build_array(jsonb_build_object('producto_id', v_m1, 'cantidad', 5, 'precio_unitario', 100)));
  UPDATE public.productos SET cantidad_minima_venta = 12 WHERE id = v_m1;

  v_r := pg_temp.t6_editar(v_ped, v_adm, v_suc, jsonb_build_array(
           jsonb_build_object('producto_id', v_m1, 'cantidad', 5, 'precio_unitario', 100),
           jsonb_build_object('producto_id', v_m2, 'cantidad', 1, 'precio_unitario', 50)));
  f := pg_temp.t6_si(f, v_r = 'OK', format('editar otra línea con M1 en 5 (mínimo 12) dio %s', v_r));
  f := pg_temp.t6_si(f, (SELECT total FROM public.pedidos WHERE id = v_ped) = 550,
                     format('el total quedó en %s y no en 550', (SELECT total FROM public.pedidos WHERE id = v_ped)));

  v_r := pg_temp.t6_editar(v_ped, v_adm, v_suc, jsonb_build_array(
           jsonb_build_object('producto_id', v_m1, 'cantidad', 8, 'precio_unitario', 100),
           jsonb_build_object('producto_id', v_m2, 'cantidad', 1, 'precio_unitario', 50)));
  f := pg_temp.t6_si(f, v_r = 'OK', format('subir M1 de 5 a 8 (sigue debajo de 12) dio %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_e1(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc_a')::bigint;
  v_adm uuid := (a->>'adm_a')::uuid;
  v_cli bigint := pg_temp.t6_cliente(v_suc, 'T6 C moq e');
  v_m1  bigint := pg_temp.t6_producto(v_suc, 'T6 M1 e', 100);
  v_m3  bigint := pg_temp.t6_producto(v_suc, 'T6 M3 e', 10);
  v_ped bigint;
  v_r   text;
BEGIN
  v_ped := pg_temp.t6_alta(v_cli, v_adm, v_suc,
             jsonb_build_array(jsonb_build_object('producto_id', v_m1, 'cantidad', 5, 'precio_unitario', 100)));
  UPDATE public.productos SET cantidad_minima_venta = 12 WHERE id = v_m1;
  UPDATE public.productos SET cantidad_minima_venta = 10 WHERE id = v_m3;

  v_r := pg_temp.t6_editar(v_ped, v_adm, v_suc, jsonb_build_array(
           jsonb_build_object('producto_id', v_m1, 'cantidad', 4, 'precio_unitario', 100)));
  f := pg_temp.t6_si(f, v_r = 'ERR 23514', format('bajar M1 de 5 a 4 (mínimo 12) dio %s', v_r));

  v_r := pg_temp.t6_editar(v_ped, v_adm, v_suc, jsonb_build_array(
           jsonb_build_object('producto_id', v_m1, 'cantidad', 5, 'precio_unitario', 100),
           jsonb_build_object('producto_id', v_m3, 'cantidad', 3, 'precio_unitario', 10)));
  f := pg_temp.t6_si(f, v_r = 'ERR 23514', format('sumar M3 con 3 (mínimo 10) dio %s', v_r));
  f := pg_temp.t6_si(f, (SELECT total FROM public.pedidos WHERE id = v_ped) = 500,
                     format('los rechazos movieron el total a %s', (SELECT total FROM public.pedidos WHERE id = v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- SEG-1
-- ---------------------------------------------------------------------------
-- El alta de un preventista: 'sqlstate|mensaje' del rechazo, u 'OK'.
CREATE OR REPLACE FUNCTION pg_temp.t6_alta_prev(p_cli bigint, p_prev uuid, p_suc bigint, p_prod bigint)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t6_claims(p_prev, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  BEGIN
    v_res := public.crear_pedido_completo(
      p_cli, 100, p_prev,
      jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', 1, 'precio_unitario', 100)),
      'ensayo 1559', 'efectivo', 'pendiente', public._tablero_hoy(), 'ZZ');
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.t6_reset();
    RETURN SQLSTATE || '|' || SQLERRM;
  END;
  PERFORM pg_temp.t6_reset();
  RETURN 'OK ' || v_res::text;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_l2(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f      text[] := '{}';
  v_sa   bigint := (a->>'suc_a')::bigint;
  v_sb   bigint := (a->>'suc_b')::bigint;
  v_p1   uuid := pg_temp.t6_usuario('preventista', v_sa);
  v_pb   uuid := pg_temp.t6_usuario('preventista', v_sb);
  v_prod bigint := pg_temp.t6_producto(v_sa, 'T6 SEG prod', 100);
  v_cb   bigint := pg_temp.t6_cliente(v_sb, 'T6 SEG ajeno asignado');
  v_cbr  bigint := pg_temp.t6_cliente(v_sb, 'T6 SEG ajeno reservado', true);
  v_nada text;
  v_r    text;
BEGIN
  INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_pb);
  v_nada := pg_temp.t6_alta_prev((SELECT COALESCE(max(id), 0) + 1000000 FROM public.clientes), v_p1, v_sa, v_prod);
  f := pg_temp.t6_si(f, v_nada LIKE '23503|%', format('el id que no existe dio %s', v_nada));

  v_r := pg_temp.t6_alta_prev(v_cb, v_p1, v_sa, v_prod);
  f := pg_temp.t6_si(f, v_r = v_nada, format('el cliente asignado de la otra sucursal dio «%s» y no lo mismo que un id que no existe', v_r));
  f := pg_temp.t6_si(f, position('T6 SEG' in v_r) = 0, 'el rechazo nombra al cliente de la otra sucursal');

  v_r := pg_temp.t6_alta_prev(v_cbr, v_p1, v_sa, v_prod);
  f := pg_temp.t6_si(f, v_r = v_nada, format('el cliente reservado de la otra sucursal dio «%s» y no lo mismo que un id que no existe', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_e2(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f      text[] := '{}';
  v_sa   bigint := (a->>'suc_a')::bigint;
  v_p1   uuid := pg_temp.t6_usuario('preventista', v_sa);
  v_p2   uuid := pg_temp.t6_usuario('preventista', v_sa);
  v_prod bigint := pg_temp.t6_producto(v_sa, 'T6 SEG prod e', 100);
  v_ca   bigint := pg_temp.t6_cliente(v_sa, 'T6 SEG propio asignado');
  v_car  bigint := pg_temp.t6_cliente(v_sa, 'T6 SEG propio reservado', true);
  v_r    text;
BEGIN
  INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_ca, v_p2);
  v_r := pg_temp.t6_alta_prev(v_ca, v_p1, v_sa, v_prod);
  f := pg_temp.t6_si(f, v_r LIKE '42501|Cliente asignado a otro preventista: T6 SEG propio asignado%',
                     format('el cliente de la sucursal asignado a otro dio %s', v_r));
  v_r := pg_temp.t6_alta_prev(v_car, v_p1, v_sa, v_prod);
  f := pg_temp.t6_si(f, v_r LIKE '42501|%reservado a administración%',
                     format('el cliente reservado de la sucursal dio %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- COB-1
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.t6_caso_l3(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc_a')::bigint;
  v_adm uuid := (a->>'adm_a')::uuid;
  v_tra uuid := pg_temp.t6_usuario('transportista', v_suc);
  v_cli bigint := pg_temp.t6_cliente(v_suc, 'T6 COB A');
  v_pr  bigint := pg_temp.t6_producto(v_suc, 'T6 COB prod A', 1);
  v_ped bigint;
  v_s   bigint;
  v_pg  bigint;
  v_res jsonb;
  v_rec jsonb;
BEGIN
  v_ped := pg_temp.t6_boleta(v_cli, v_adm, v_tra, v_suc, v_pr, 100);
  PERFORM pg_temp.t6_cobrar(v_ped, v_tra, v_suc, ARRAY[100]);
  SELECT id INTO v_pg FROM public.pagos WHERE pedido_id = v_ped;
  v_s := pg_temp.t6_salvedad(v_ped, 20, v_adm, v_suc);
  f := pg_temp.t6_si(f, pg_temp.t6_est(v_ped) = '80.00/80.00 pagado', format('tras la salvedad la boleta quedó %s', pg_temp.t6_est(v_ped)));
  SELECT to_jsonb(s)->'cobro_recortado' INTO v_rec FROM public.salvedades_items s WHERE s.id = v_s;
  f := pg_temp.t6_si(f, jsonb_array_length(COALESCE(v_rec, '[]')) = 1 AND (v_rec->0->>'pago_id')::bigint = v_pg
                        AND (v_rec->0->>'monto')::numeric = 20 AND NOT (v_rec->0->>'borrado')::boolean,
                     format('la salvedad anotó %s', v_rec));

  v_res := pg_temp.t6_anular(v_s, v_adm, v_suc);
  f := pg_temp.t6_si(f, pg_temp.t6_est(v_ped) = '100.00/100.00 pagado', format('tras anular la boleta quedó %s', pg_temp.t6_est(v_ped)));
  f := pg_temp.t6_si(f, (SELECT monto FROM public.pagos WHERE id = v_pg) = 100
                        AND (SELECT count(*) FROM public.pagos WHERE pedido_id = v_ped) = 1,
                     format('el cobro quedó %s en %s pago(s)', (SELECT monto FROM public.pagos WHERE id = v_pg),
                            (SELECT count(*) FROM public.pagos WHERE pedido_id = v_ped)));
  f := pg_temp.t6_si(f, pg_temp.t6_saldo(v_cli) = 0, format('el saldo del cliente quedó en %s', pg_temp.t6_saldo(v_cli)));
  f := pg_temp.t6_si(f, (v_res->>'cobro_repuesto')::numeric = 20 AND (v_res->>'cobro_sin_reponer')::numeric = 0,
                     format('la anulación respondió %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_l4(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f      text[] := '{}';
  v_suc  bigint := (a->>'suc_a')::bigint;
  v_adm  uuid := (a->>'adm_a')::uuid;
  v_tra  uuid := pg_temp.t6_usuario('transportista', v_suc);
  v_cli  bigint := pg_temp.t6_cliente(v_suc, 'T6 COB B');
  v_pr   bigint := pg_temp.t6_producto(v_suc, 'T6 COB prod B', 1);
  v_ped  bigint;
  v_s    bigint;
  v_pgs  bigint[];
  v_fec  date;
BEGIN
  v_ped := pg_temp.t6_boleta(v_cli, v_adm, v_tra, v_suc, v_pr, 100);
  PERFORM pg_temp.t6_cobrar(v_ped, v_tra, v_suc, ARRAY[50, 50]);
  v_pgs := ARRAY(SELECT id FROM public.pagos WHERE pedido_id = v_ped ORDER BY id);
  v_fec := (SELECT fecha FROM public.pagos WHERE id = v_pgs[2]);
  v_s := pg_temp.t6_salvedad(v_ped, 60, v_adm, v_suc);
  f := pg_temp.t6_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE id = v_pgs[2])
                        AND (SELECT monto FROM public.pagos WHERE id = v_pgs[1]) = 40,
                     'la salvedad de 60 no borró el cobro más nuevo y dejó el otro en 40');

  PERFORM pg_temp.t6_anular(v_s, v_adm, v_suc);
  f := pg_temp.t6_si(f, pg_temp.t6_est(v_ped) = '100.00/100.00 pagado', format('tras anular la boleta quedó %s', pg_temp.t6_est(v_ped)));
  f := pg_temp.t6_si(f, (SELECT monto FROM public.pagos WHERE id = v_pgs[1]) = 50,
                     format('el cobro recortado quedó en %s', (SELECT monto FROM public.pagos WHERE id = v_pgs[1])));
  f := pg_temp.t6_si(f, EXISTS (SELECT 1 FROM public.pagos
                                 WHERE pedido_id = v_ped AND id > v_pgs[2] AND monto = 50
                                   AND forma_pago = 'efectivo' AND fecha = v_fec AND usuario_id = v_tra),
                     'el cobro borrado no volvió como un cobro nuevo de 50 en efectivo, de su fecha y de su chofer');
  f := pg_temp.t6_si(f, pg_temp.t6_saldo(v_cli) = 0, format('el saldo del cliente quedó en %s', pg_temp.t6_saldo(v_cli)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_l5(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc_a')::bigint;
  v_adm uuid := (a->>'adm_a')::uuid;
  v_tra uuid := pg_temp.t6_usuario('transportista', v_suc);
  v_cli bigint := pg_temp.t6_cliente(v_suc, 'T6 COB C');
  v_pr  bigint := pg_temp.t6_producto(v_suc, 'T6 COB prod C', 1);
  v_ped bigint;
  v_s1  bigint;
  v_s2  bigint;
BEGIN
  v_ped := pg_temp.t6_boleta(v_cli, v_adm, v_tra, v_suc, v_pr, 100);
  PERFORM pg_temp.t6_cobrar(v_ped, v_tra, v_suc, ARRAY[100]);
  v_s1 := pg_temp.t6_salvedad(v_ped, 20, v_adm, v_suc);
  v_s2 := pg_temp.t6_salvedad(v_ped, 30, v_adm, v_suc);
  f := pg_temp.t6_si(f, pg_temp.t6_est(v_ped) = '50.00/50.00 pagado', format('tras las dos salvedades la boleta quedó %s', pg_temp.t6_est(v_ped)));
  PERFORM pg_temp.t6_anular(v_s2, v_adm, v_suc);
  f := pg_temp.t6_si(f, pg_temp.t6_est(v_ped) = '80.00/80.00 pagado', format('tras anular la de 30 la boleta quedó %s', pg_temp.t6_est(v_ped)));
  PERFORM pg_temp.t6_anular(v_s1, v_adm, v_suc);
  f := pg_temp.t6_si(f, pg_temp.t6_est(v_ped) = '100.00/100.00 pagado', format('tras anular las dos la boleta quedó %s', pg_temp.t6_est(v_ped)));
  f := pg_temp.t6_si(f, pg_temp.t6_saldo(v_cli) = 0, format('el saldo del cliente quedó en %s', pg_temp.t6_saldo(v_cli)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_e3(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc_a')::bigint;
  v_adm uuid := (a->>'adm_a')::uuid;
  v_tra uuid := pg_temp.t6_usuario('transportista', v_suc);
  v_cli bigint := pg_temp.t6_cliente(v_suc, 'T6 COB D');
  v_pr  bigint := pg_temp.t6_producto(v_suc, 'T6 COB prod D', 1);
  v_ped bigint;
  v_s   bigint;
  v_res jsonb;
BEGIN
  v_ped := pg_temp.t6_boleta(v_cli, v_adm, v_tra, v_suc, v_pr, 100);
  PERFORM pg_temp.t6_cobrar(v_ped, v_tra, v_suc, ARRAY[100]);
  v_s := pg_temp.t6_salvedad(v_ped, 20, v_adm, v_suc);
  -- Alguien anula el cobro después (lo que hace «Eliminar pago»).
  DELETE FROM public.pagos WHERE pedido_id = v_ped;
  v_res := pg_temp.t6_anular(v_s, v_adm, v_suc);
  f := pg_temp.t6_si(f, pg_temp.t6_est(v_ped) = '0.00/100.00 pendiente', format('tras anular la boleta quedó %s', pg_temp.t6_est(v_ped)));
  f := pg_temp.t6_si(f, NOT EXISTS (SELECT 1 FROM public.pagos WHERE cliente_id = v_cli),
                     'la anulación inventó un cobro que alguien había borrado');
  -- Sin la migración la respuesta no trae las cuentas: el caso mira la boleta y los pagos.
  f := pg_temp.t6_si(f, COALESCE((v_res->>'cobro_repuesto')::numeric, 0) = 0
                        AND (NOT v_res ? 'cobro_sin_reponer' OR (v_res->>'cobro_sin_reponer')::numeric = 20),
                     format('la anulación respondió %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_e4(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (a->>'suc_a')::bigint;
  v_adm uuid := (a->>'adm_a')::uuid;
  v_tra uuid := pg_temp.t6_usuario('transportista', v_suc);
  v_cli bigint := pg_temp.t6_cliente(v_suc, 'T6 COB E');
  v_pr  bigint := pg_temp.t6_producto(v_suc, 'T6 COB prod E', 1);
  v_ped bigint;
  v_s   bigint;
  v_res jsonb;
BEGIN
  v_ped := pg_temp.t6_boleta(v_cli, v_adm, v_tra, v_suc, v_pr, 100);
  PERFORM pg_temp.t6_claims(v_adm, v_suc);
  PERFORM public.registrar_pago_cliente_fifo(v_cli, 100, 'efectivo', public._tablero_hoy());
  PERFORM pg_temp.t6_reset();
  v_s := pg_temp.t6_salvedad(v_ped, 20, v_adm, v_suc);
  -- to_jsonb: sin la migración la columna no existe.
  f := pg_temp.t6_si(f, (SELECT to_jsonb(s)->'cobro_recortado' FROM public.salvedades_items s WHERE s.id = v_s) IS NULL
                        OR (SELECT to_jsonb(s)->'cobro_recortado' FROM public.salvedades_items s WHERE s.id = v_s) = 'null'::jsonb,
                     'la salvedad anotó como recorte de cobro un pago a cuenta');
  v_res := pg_temp.t6_anular(v_s, v_adm, v_suc);
  f := pg_temp.t6_si(f, COALESCE((v_res->>'cobro_repuesto')::numeric, 0) = 0,
                     format('la anulación repuso un pago a cuenta: %s', v_res));
  f := pg_temp.t6_si(f, pg_temp.t6_saldo(v_cli) = 0, format('el saldo del cliente quedó en %s', pg_temp.t6_saldo(v_cli)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6_caso_l6(a jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.validar_minimo_venta_item()', '265f7882a641a8475e80a4eee63677aa',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', '9bf3c42b9d4447172b9c96999f65ea00',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.pedidos_cliente_asignado()', '84754c312560f862e6f0c53d213b2f21',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.pedidos_cliente_reservado()', 'f3f82c5a401e4476b671287f6373bb62',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.desafectar_sobrepago_pedido(bigint)', 'b038256f1acf602b0ed20475215a3080',
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.anular_salvedad(bigint,text)', '2b6ef1cff1465406ef6ae78314d620ef',
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(fn, h, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS d INTO x FROM pg_proc WHERE oid = r.fn::regprocedure;
    f := pg_temp.t6_si(f, x.h = r.h AND x.a = r.acl AND x.d,
                       format('%s tiene md5 %s, EXECUTE %s, definer %s', r.fn, x.h, x.a, x.d));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1559$
DECLARE
  v_sa     bigint;
  v_sb     bigint;
  v_args   jsonb;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';
  SELECT min(id) INTO v_sa FROM sucursales WHERE activa;
  SELECT min(id) INTO v_sb FROM sucursales WHERE activa AND id > v_sa;
  IF v_sb IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · hacen falta dos sucursales activas';
  END IF;
  v_args := jsonb_build_object('suc_a', v_sa, 'suc_b', v_sb, 'adm_a', pg_temp.t6_usuario('admin', v_sa));

  FOREACH v_caso IN ARRAY ARRAY['l1', 'e1', 'l2', 'e2', 'l3', 'l4', 'l5', 'e3', 'e4', 'l6'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.t6_reset();
      EXECUTE format('SELECT pg_temp.t6_caso_%s($1)', v_caso) INTO v_out USING v_args;
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
  RAISE EXCEPTION 'ENSAYO OK · CAT-3, SEG-1 y COB-1 de #1559';
END
$ensayo1559$;
