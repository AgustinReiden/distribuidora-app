-- Ensayo de la migración 473: el replay del alta trae el saldo a favor que absorbió, y la rendición no le pasa ese
-- crédito al chofer de la boleta nueva (#1492, tarjeta 15 de #1477).
--
-- Los casos E pasan con y sin la migración; los L fallan sin ella:
--
--   L1 · Un cliente con un crédito de 30 y un alta de 100 por crear_pedido_idempotente: la primera respuesta trae
--        saldo_a_favor_aplicado 30. El reintento con la misma clave contesta idempotente, con el mismo
--        saldo_a_favor_aplicado, y cobrar lo que falta (70) entra: la boleta queda saldada.
--   E1 · El replay de un alta sin crédito: el mismo pedido, el total y el cargo de antes, y nada que descontar.
--   L2 · El crédito de 30, que cobró el admin, lo absorbe una boleta que reparte un transportista. En
--        _rendicion_pagos el crédito sigue siendo del admin, y un cobro de 10 que entra en la boleta es del transportista.
--   E2 · Un crédito suelto (sin boleta que lo absorba) es de quien lo cobró.
--   L3 · Los cuerpos y los EXECUTE de crear_pedido_idempotente y _rendicion_pagos son los de la migración.
--   L4 · SEG-A (auditoria_definer_sin_rol) no ve crear_pedido_idempotente: la lista blanca tiene el md5 del
--        cuerpo nuevo (mig 474). Falla después de la 473 y antes de la 474.
--   En L1, L2 y E2, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos (el predicado de CC-A).
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo,
-- sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1, L2
-- y L3 (y L4, que pide además la 474).
--
-- Fixtures: una sucursal activa con un admin activo, un transportista activo y la caja de hoy abierta. El resto nace
-- en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1492', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, 1000, 1, p_suc)
  RETURNING id;
$fn$;

-- Un alta de p_monto unidades de $1 por crear_pedido_idempotente, con la clave p_clave.
CREATE OR REPLACE FUNCTION pg_temp.t_alta(p_cli bigint, p_admin uuid, p_prod bigint, p_monto int, p_fecha date, p_clave text)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.crear_pedido_idempotente(
    p_cli, p_monto, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_monto, 'precio_unitario', 1)),
    'ensayo 1492', 'efectivo', 'pendiente', p_fecha, 'ZZ', NULL, 0, NULL, NULL, p_clave);
$fn$;

-- Un crédito (pago a cuenta sin boleta).
CREATE OR REPLACE FUNCTION pg_temp.t_credito(p_cli bigint, p_suc bigint, p_adm uuid, p_monto numeric, p_fecha date)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
  VALUES (p_cli, NULL, p_suc, p_monto, 'efectivo', p_fecha, p_adm, '[saldo a favor]', true)
  RETURNING id;
$fn$;

-- '' si el saldo del cliente cierra contra sus boletas y sus créditos (el predicado de CC-A); si no, el detalle.
CREATE OR REPLACE FUNCTION pg_temp.t_saldo(p_cli bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT CASE WHEN abs(COALESCE(c.saldo_cuenta, 0) - (b.deuda - f.favor)) <= 0.01 THEN ''
              ELSE format(' saldo_cuenta de %s=%s esperado=%s', p_cli, c.saldo_cuenta, b.deuda - f.favor) END
    FROM public.clientes c,
         LATERAL (SELECT COALESCE(sum(total - COALESCE(monto_pagado, 0)), 0) AS deuda FROM public.pedidos
                   WHERE cliente_id = p_cli AND estado NOT IN ('cancelado', 'anulado')) b,
         LATERAL (SELECT COALESCE(sum(monto), 0) AS favor FROM public.pagos
                   WHERE cliente_id = p_cli AND pedido_id IS NULL) f
   WHERE c.id = p_cli;
$fn$;

-- El dueño que _rendicion_pagos le da a un pago (en una ventana amplia: un día cerrado lo corre).
CREATE OR REPLACE FUNCTION pg_temp.t_dueno(p_suc bigint, p_pago bigint, p_hoy date)
RETURNS uuid LANGUAGE sql AS $fn$
  SELECT t_id FROM public._rendicion_pagos(p_suc, p_hoy - 60, p_hoy + 60) WHERE pago_id = p_pago;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_tra    uuid;
  v_hoy    date := public._tablero_hoy();
  v_prod   bigint;
  v_c1     bigint;
  v_n      bigint;
  v_c      bigint;
  v_p      bigint;
  v_clave  text;
  v_txt    text;
  v_j      jsonb;
  v_r      jsonb;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id, tra.usuario_id
    INTO v_suc, v_adm, v_tra
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) tra ON true
   WHERE s.activa
     AND COALESCE(public.ultima_fecha_caja_cerrada(s.id), v_hoy - 1) < v_hoy
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin, un transportista y la caja de hoy abierta';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1492');

  -- L1 · el replay trae lo absorbido y el cobro de lo que falta entra
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1492 L1');
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_clave := 'ensayo-1492-' || gen_random_uuid();
    v_j := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy, v_clave);
    v_n := (v_j->>'pedido_id')::bigint;
    v_r := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy, v_clave);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'saldo_a_favor_aplicado')::numeric IS DISTINCT FROM 30::numeric
       OR NOT COALESCE((v_r->>'idempotente')::boolean, false)
       OR (v_r->>'pedido_id')::bigint IS DISTINCT FROM v_n
       OR (v_r->>'saldo_a_favor_aplicado')::numeric IS DISTINCT FROM (v_j->>'saldo_a_favor_aplicado')::numeric
       OR (v_r->>'total')::numeric IS DISTINCT FROM (v_j->>'total')::numeric THEN
      v_fallas := v_fallas || format('L1 dio %s y el replay %s', v_j, v_r);
    ELSE
      v_j := public.registrar_pagos_pedido_impl(
        v_n, jsonb_build_array(jsonb_build_object('monto', 100 - (v_r->>'saldo_a_favor_aplicado')::numeric,
                                                  'forma_pago', 'efectivo')), v_hoy);
      v_txt := pg_temp.t_saldo(v_c1);
      IF NOT COALESCE((v_j->>'success')::boolean, false)
         OR (SELECT monto_pagado::numeric(12,2)::text || '/' || estado_pago FROM pedidos WHERE id = v_n)
            IS DISTINCT FROM '100.00/pagado'
         OR v_txt <> '' THEN
        v_fallas := v_fallas || format('L1 el cobro de lo que falta dio %s%s', v_j, v_txt);
      END IF;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ492';
  EXCEPTION
    WHEN SQLSTATE 'ZZ492' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E1 · el replay de un alta sin crédito
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1492 E1');
    v_clave := 'ensayo-1492-' || gen_random_uuid();
    v_j := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy, v_clave);
    v_r := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy, v_clave);
    IF NOT COALESCE((v_r->>'idempotente')::boolean, false)
       OR (v_r->>'pedido_id') IS DISTINCT FROM (v_j->>'pedido_id')
       OR (v_r->>'total')::numeric IS DISTINCT FROM 100::numeric
       OR (v_r->>'cargo_envio')::numeric IS DISTINCT FROM (v_j->>'cargo_envio')::numeric
       OR COALESCE((v_r->>'saldo_a_favor_aplicado')::numeric, 0) <> 0
       OR (SELECT count(*) FROM pedidos WHERE cliente_id = v_c1) <> 1 THEN
      v_fallas := v_fallas || format('E1 dio %s y el replay %s', v_j, v_r);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ492';
  EXCEPTION
    WHEN SQLSTATE 'ZZ492' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L2 · el crédito absorbido sigue siendo de quien lo cobró
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1492 L2');
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_j := pg_temp.t_alta(v_c1, v_adm, v_prod, 100, v_hoy, 'ensayo-1492-' || gen_random_uuid());
    v_n := (v_j->>'pedido_id')::bigint;
    UPDATE pedidos SET transportista_id = v_tra WHERE id = v_n;
    v_j := public.registrar_pagos_pedido_impl(v_n, '[{"monto":10,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_p := (SELECT max(id) FROM pagos WHERE pedido_id = v_n AND NOT de_saldo_a_favor);
    v_txt := pg_temp.t_saldo(v_c1);
    IF (SELECT pedido_id::text || '/' || de_saldo_a_favor::text FROM pagos WHERE id = v_c) IS DISTINCT FROM v_n::text || '/true'
       OR pg_temp.t_dueno(v_suc, v_c, v_hoy) IS DISTINCT FROM v_adm
       OR v_p IS NULL
       OR pg_temp.t_dueno(v_suc, v_p, v_hoy) IS DISTINCT FROM v_tra
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('L2 el crédito quedó de %s (esperado el admin %s) y el cobro de %s (esperado %s)%s',
                                     pg_temp.t_dueno(v_suc, v_c, v_hoy), v_adm, pg_temp.t_dueno(v_suc, v_p, v_hoy), v_tra, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ492';
  EXCEPTION
    WHEN SQLSTATE 'ZZ492' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('L2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · un crédito suelto es de quien lo cobró
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1492 E2');
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_txt := pg_temp.t_saldo(v_c1);
    IF pg_temp.t_dueno(v_suc, v_c, v_hoy) IS DISTINCT FROM v_adm OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E2 el crédito suelto quedó de %s%s', pg_temp.t_dueno(v_suc, v_c, v_hoy), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ492';
  EXCEPTION
    WHEN SQLSTATE 'ZZ492' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L3 · los cuerpos y los EXECUTE
  IF (SELECT md5(prosrc) || ' ' || proacl::text || ' ' || prosecdef::text FROM pg_proc
       WHERE oid = 'public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text)'::regprocedure)
     IS DISTINCT FROM '63f0759223a668afdd04ce684aee18ef {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres} true'
     OR (SELECT md5(prosrc) || ' ' || proacl::text || ' ' || prosecdef::text FROM pg_proc
          WHERE oid = 'public._rendicion_pagos(bigint,date,date,bigint)'::regprocedure)
     IS DISTINCT FROM '8f3bf05f8fd2690373baeb4915f62a4c {postgres=X/postgres,service_role=X/postgres} false' THEN
    v_fallas := v_fallas || 'L3 crear_pedido_idempotente o _rendicion_pagos no son los de la migración 473'::text;
  END IF;

  -- L4 · SEG-A no ve el replay
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() h WHERE h.firma ~ '^crear_pedido_idempotente\(') THEN
    v_fallas := v_fallas || 'L4 SEG-A ve crear_pedido_idempotente: falta actualizar su md5 en la lista blanca (mig 474)'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · L1 E1 L2 E2 L3 L4';
 END;
END
$ensayo$;
