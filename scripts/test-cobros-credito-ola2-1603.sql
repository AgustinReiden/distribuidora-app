-- Ensayo de la migración NNN_cobros_credito_y_cancelacion (ola 2 del plan #1603, tarjeta B5): cobros, crédito, NC de
-- venta y cancelación. Un caso por punto, con los números de la boleta, del crédito suelto y del saldo del cliente.
--
--   B1 · 1595-b1: 505 boletas de $1 y un crédito suelto de 600. aplicar_credito_cliente las paga todas (505) y quedan 95
--        a favor; antes cortaba a las 500 por crédito: 5 abiertas y 100 a favor a la vez.
--   W1 · COB-b2: Q (de 100, la boleta de una NC, abierta), A y B (de 30), y el crédito suelto de la NC (30), que no se
--        imputa a Q. La ventana de _credito_bloquea_boletas toma Q y A (antes sólo Q: Q pesaba 100 en la cola y el bucle
--        pagaba A sin bloquearla). aplicar_credito_cliente deja A en 30/30, Q en 0/100, B en 0/30 y nada suelto.
--   N1 · COB-b5: cancelar_pedido_con_stock con 'cambio_de_cliente' por llamada directa (X de 100 cobrada 60, W de 100
--        abierta): se rechaza y X sigue 60/100, W 0/100, nada suelto (antes: X cancelada y 60 sueltos sin aplicar).
--        Por cambiar_cliente_pedido ('cliente_original') sigue andando: los 60 van a W (60/100).
--   M1 · 1559-b11 y 1559-b12: el cobro masivo de P1 (100, abierta, forma efectivo) y P2 (50, cobrada en efectivo) en
--        transferencia devuelve 1 (antes 2), P1 queda 100/100 en transferencia y P2 sigue en efectivo (antes la pisaba).
--   I1 · 1559-b14: el FIFO de la ficha con la clave U por 100 entra; el mismo cobro con U es un replay (no carga nada);
--        U con 200 se rechaza (22023) y no carga nada (antes devolvía el replay del de 100). registrar_pagos_pedido con la
--        clave de un cobro a X1, sobre X2: 22023. El cobro masivo con los ids en otro orden es el mismo cobro (replay).
--        Una solicitud sin contenido (de antes de la migración) no se compara.
--   S1 · SEG-1: las cuatro funciones leen el rol de quien llama con activo, y cancelar_pedido_con_stock ya no figura en
--        auditoria_rol_sin_activo().
--   K1 · 1559-b16: NC-A está y da lo mismo con una NC nueva; borrar el crédito suelto de la NC lo pone en +1.
--   G1 · 1558-b4: STK-G está y da 0; una función con `UPDATE public.productos SET stock = 5` sin origen lo pone en +1
--        (STK-F no la ve: sigue igual).
--   L1 · _credito_ventana y pago_solicitud_abrir no tienen EXECUTE para anon ni authenticated, y la firma vieja de
--        pago_solicitud_abrir no existe (dos firmas darían una llamada ambigua).
--   En cada caso, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos de cada cliente tocado, y CC-A, CC-B y
--   CC-C de auditoria_integridad() no cambian en toda la base.
--
-- COB-b1 (la cancelación y la NC miden la ventana otra vez con la boleta tomada) necesita dos sesiones: no entra en un
-- DO. Su intercalado está en el cuerpo del PR y en el informe de la tarjeta.
--
-- Corre sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción, y cada caso en
-- un sub-bloque que se revierte. Sin la migración da 'ENSAYO FALLÓ' por B1, W1, N1, M1, I1, S1, K1, G1 y L1.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo B5', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, 100000, 1, p_suc)
  RETURNING id;
$fn$;

-- El id de una boleta nueva de p_monto pesos (p_monto unidades de $1), del día p_fecha.
CREATE OR REPLACE FUNCTION pg_temp.t_alta(p_cli bigint, p_admin uuid, p_prod bigint, p_monto int, p_fecha date)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_monto, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_monto, 'precio_unitario', 1)),
    'ensayo B5', 'efectivo', 'pendiente', p_fecha, 'ZZ');
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Un cobro de la boleta (sin marcas).
CREATE OR REPLACE FUNCTION pg_temp.t_cobro(p_ped bigint, p_monto numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id)
  SELECT cliente_id, id, sucursal_id, p_monto, 'efectivo', public._tablero_hoy(), usuario_id
    FROM public.pedidos WHERE id = p_ped
  RETURNING id;
$fn$;

-- Un crédito (pago a cuenta sin boleta).
CREATE OR REPLACE FUNCTION pg_temp.t_credito(p_cli bigint, p_suc bigint, p_adm uuid, p_monto numeric, p_fecha date)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
  VALUES (p_cli, NULL, p_suc, p_monto, 'efectivo', p_fecha, p_adm, '[saldo a favor]', true)
  RETURNING id;
$fn$;

-- La boleta entregada (retiro en el depósito, sin chofer).
CREATE OR REPLACE FUNCTION pg_temp.t_entregar(p_ped bigint)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = p_ped;
$fn$;

-- La NC por p_cant unidades de la única línea de la boleta.
CREATE OR REPLACE FUNCTION pg_temp.t_nc(p_ped bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.crear_nota_credito_venta(
    p_ped, (SELECT cliente_id FROM public.pedidos WHERE id = p_ped),
    (SELECT jsonb_build_array(jsonb_build_object('pedido_item_id', min(id), 'cantidad', p_cant))
       FROM public.pedido_items WHERE pedido_id = p_ped),
    'producto_vencido', 'ensayo B5', NULL);
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

CREATE OR REPLACE FUNCTION pg_temp.t_suelto(p_cli bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(sum(monto), 0) FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL;
$fn$;

-- Las violaciones de un check, o NULL si auditoria_integridad() no lo tiene.
CREATE OR REPLACE FUNCTION pg_temp.t_viol(p_id text)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT (c->>'violaciones')::bigint
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
   WHERE c->>'id' = p_id;
$fn$;

-- CC-A, CC-B y CC-C juntos, para comparar de una vez.
CREATE OR REPLACE FUNCTION pg_temp.t_cc()
RETURNS text LANGUAGE sql AS $fn$
  SELECT string_agg(c->>'id' || '=' || (c->>'violaciones'), ' ' ORDER BY c->>'id')
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
   WHERE c->>'id' IN ('CC-A', 'CC-B', 'CC-C');
$fn$;

-- 'pagado/total' de una boleta.
CREATE OR REPLACE FUNCTION pg_temp.t_estado(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(monto_pagado, 0)::numeric(12,2)::text || '/' || total::numeric(12,2)::text FROM public.pedidos WHERE id = p_ped;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_prod   bigint;
  v_cli    bigint;
  v_cli2   bigint;
  v_q      bigint;
  v_a      bigint;
  v_b      bigint;
  v_x      bigint;
  v_w      bigint;
  v_p      bigint;
  v_n      bigint;
  v_i      int;
  v_u      uuid;
  v_j      jsonb;
  v_j2     jsonb;
  v_ids    bigint[];
  v_txt    text;
  v_fallas text[] := '{}';
  v_cc     text;
  v_stkf   bigint;
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id
    INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
     AND COALESCE(public.ultima_fecha_caja_cerrada(s.id), v_hoy - 1) < v_hoy
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y la caja de hoy abierta';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo B5');
  v_cc := pg_temp.t_cc();

  -- B1 · 1595-b1: el crédito no se corta a las 500 boletas
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 B1');
    FOR v_i IN 1..505 LOOP
      PERFORM pg_temp.t_alta(v_cli, v_adm, v_prod, 1, v_hoy - 5);
    END LOOP;
    PERFORM pg_temp.t_credito(v_cli, v_suc, v_adm, 600, v_hoy - 6);
    v_j := to_jsonb(public.aplicar_credito_cliente(v_cli, v_suc));
    SELECT count(*) INTO v_n FROM pedidos WHERE cliente_id = v_cli AND total > COALESCE(monto_pagado, 0);
    IF v_n <> 0 OR pg_temp.t_suelto(v_cli) <> 95 OR (v_j #>> '{}')::numeric <> 505 OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('B1 aplicó %s: quedaron %s boletas abiertas y %s a favor (se esperaba 0 y 95)%s',
                                     v_j, v_n, pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- W1 · COB-b2: la boleta de la NC no pesa en la ventana
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 W1');
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 5);
    v_a := pg_temp.t_alta(v_cli, v_adm, v_prod, 30, v_hoy - 4);
    v_b := pg_temp.t_alta(v_cli, v_adm, v_prod, 30, v_hoy - 3);
    PERFORM pg_temp.t_entregar(v_q);
    PERFORM pg_temp.t_cobro(v_q, 100);
    PERFORM pg_temp.t_cobro(v_a, 30);
    PERFORM pg_temp.t_cobro(v_b, 30);
    -- La NC de 30 sobre Q: Q está paga y no hay otra abierta, así que el crédito queda suelto.
    v_j := pg_temp.t_nc(v_q, 30);
    IF pg_temp.t_suelto(v_cli) <> 30 THEN
      RAISE EXCEPTION 'W1: el crédito de la NC no quedó suelto (%; %)', pg_temp.t_suelto(v_cli), v_j;
    END IF;
    -- Las tres vuelven a deber (se borran sus cobros): Q 0/100, A 0/30, B 0/30.
    DELETE FROM pagos WHERE pedido_id IN (v_q, v_a, v_b) AND nota_credito_id IS NULL;
    v_ids := public._credito_bloquea_boletas(NULL, v_cli, v_suc, 0);
    IF NOT (v_a = ANY(v_ids)) THEN
      v_fallas := v_fallas || format('W1 la ventana de un crédito de 30 tomó %s: le falta A (%s), que es la que paga', v_ids, v_a);
    END IF;
    v_j := to_jsonb(public.aplicar_credito_cliente(v_cli, v_suc));
    IF pg_temp.t_estado(v_a) <> '30.00/30.00' OR pg_temp.t_estado(v_q) <> '0.00/100.00'
       OR pg_temp.t_estado(v_b) <> '0.00/30.00' OR pg_temp.t_suelto(v_cli) <> 0
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('W1 aplicó %s: Q %s, A %s, B %s, suelto %s%s', v_j, pg_temp.t_estado(v_q),
                                     pg_temp.t_estado(v_a), pg_temp.t_estado(v_b), pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('W1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N1 · COB-b5: 'cambio_de_cliente' sólo desde el cambio de cliente
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 N1');
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 4);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 3);
    PERFORM pg_temp.t_cobro(v_x, 60);
    v_j := public.cancelar_pedido_con_stock(v_x, 'ensayo B5', v_adm, 'cambio_de_cliente');
    PERFORM pg_temp.t_reset();
    IF COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT estado FROM pedidos WHERE id = v_x) = 'cancelado'
       OR pg_temp.t_estado(v_x) <> '60.00/100.00' OR pg_temp.t_estado(v_w) <> '0.00/100.00'
       OR pg_temp.t_suelto(v_cli) <> 0 OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('N1 la cancelación directa con cambio_de_cliente dio %s: X %s (%s), W %s, suelto %s%s',
                                     v_j, pg_temp.t_estado(v_x), (SELECT estado FROM pedidos WHERE id = v_x),
                                     pg_temp.t_estado(v_w), pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli));
    END IF;
    -- Por el cambio de cliente sí: lo cobrado vuelve al original y va a W.
    v_cli2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 N1 nuevo');
    v_j := public.cambiar_cliente_pedido(
      v_x, v_cli2, v_adm,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 100, 'precio_unitario', 1)),
      100, NULL, 0, 'ensayo B5', 'cliente_original');
    PERFORM pg_temp.t_reset();
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.t_estado(v_w) <> '60.00/100.00' OR pg_temp.t_suelto(v_cli) <> 0
       OR pg_temp.t_saldo(v_cli) <> '' OR pg_temp.t_saldo(v_cli2) <> '' THEN
      v_fallas := v_fallas || format('N1 el cambio de cliente dio %s: W %s, suelto %s%s%s', v_j, pg_temp.t_estado(v_w),
                                     pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli), pg_temp.t_saldo(v_cli2));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- M1 · 1559-b11 y 1559-b12: el cobro masivo toca y cuenta lo que cobró
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 M1');
    v_a := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 2);
    v_b := pg_temp.t_alta(v_cli, v_adm, v_prod, 50, v_hoy - 2);
    PERFORM pg_temp.t_cobro(v_b, 50);
    v_n := public.marcar_pagos_masivo(ARRAY[v_a, v_b], 'transferencia', v_hoy, NULL);
    IF v_n <> 1
       OR pg_temp.t_estado(v_a) <> '100.00/100.00' OR pg_temp.t_estado(v_b) <> '50.00/50.00'
       OR (SELECT forma_pago FROM pedidos WHERE id = v_a) IS DISTINCT FROM 'transferencia'
       OR (SELECT forma_pago FROM pedidos WHERE id = v_b) IS DISTINCT FROM 'efectivo'
       OR (SELECT count(*) FROM pagos WHERE pedido_id = v_b) <> 1
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('M1 el cobro masivo devolvió %s (se esperaba 1): P1 %s en %s, P2 %s en %s (se esperaba efectivo)%s',
                                     v_n, pg_temp.t_estado(v_a), (SELECT forma_pago FROM pedidos WHERE id = v_a),
                                     pg_temp.t_estado(v_b), (SELECT forma_pago FROM pedidos WHERE id = v_b), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('M1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- I1 · 1559-b14: el replay compara lo que se cobra
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 I1');
    v_a := pg_temp.t_alta(v_cli, v_adm, v_prod, 300, v_hoy - 2);
    v_b := pg_temp.t_alta(v_cli, v_adm, v_prod, 300, v_hoy - 1);
    v_u := gen_random_uuid();
    v_j := public.registrar_pago_cliente_fifo(v_cli, 100, 'efectivo', v_hoy, NULL, 'ensayo B5', v_u);
    v_j2 := public.registrar_pago_cliente_fifo(v_cli, 100, 'efectivo', v_hoy, NULL, 'ensayo B5', v_u);
    IF pg_temp.t_estado(v_a) <> '100.00/300.00' OR NOT COALESCE((v_j2->>'idempotent_replay')::boolean, false) THEN
      v_fallas := v_fallas || format('I1 el replay legítimo del FIFO dio %s; A %s', v_j2, pg_temp.t_estado(v_a));
    END IF;
    -- La misma clave con otro monto: no es un reintento.
    BEGIN
      v_j2 := public.registrar_pago_cliente_fifo(v_cli, 200, 'efectivo', v_hoy, NULL, 'ensayo B5', v_u);
      v_fallas := v_fallas || format('I1 la clave de un FIFO de 100 con 200 dio %s (A %s): se esperaba 22023',
                                     v_j2, pg_temp.t_estado(v_a));
    EXCEPTION WHEN SQLSTATE '22023' THEN
      IF SQLERRM !~ 'otro cobro' THEN
        v_fallas := v_fallas || format('I1 la clave con otro monto dio 22023 por otra cosa: %s', SQLERRM);
      END IF;
    END;
    IF pg_temp.t_estado(v_a) <> '100.00/300.00' OR pg_temp.t_suelto(v_cli) <> 0 THEN
      v_fallas := v_fallas || format('I1 después del rechazo A %s, suelto %s', pg_temp.t_estado(v_a), pg_temp.t_suelto(v_cli));
    END IF;
    -- registrar_pagos_pedido: la clave de un cobro a A, sobre B.
    v_u := gen_random_uuid();
    v_j := public.registrar_pagos_pedido(v_a, jsonb_build_array(jsonb_build_object('monto', 10, 'forma_pago', 'efectivo')),
                                         v_hoy, NULL, NULL, v_u);
    BEGIN
      v_j2 := public.registrar_pagos_pedido(v_b, jsonb_build_array(jsonb_build_object('monto', 10, 'forma_pago', 'efectivo')),
                                            v_hoy, NULL, NULL, v_u);
      v_fallas := v_fallas || format('I1 la clave de un cobro a A usada sobre B dio %s (B %s): se esperaba 22023',
                                     v_j2, pg_temp.t_estado(v_b));
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;
    -- El replay legítimo del mismo cobro (con 10.0 en vez de 10: el mismo número) devuelve lo guardado.
    v_j2 := public.registrar_pagos_pedido(v_a, jsonb_build_array(jsonb_build_object('monto', 10.0, 'forma_pago', 'efectivo')),
                                          v_hoy, NULL, NULL, v_u);
    IF NOT COALESCE((v_j2->>'idempotent_replay')::boolean, false) OR pg_temp.t_estado(v_a) <> '110.00/300.00'
       OR pg_temp.t_estado(v_b) <> '0.00/300.00' THEN
      v_fallas := v_fallas || format('I1 el replay del cobro a A dio %s: A %s, B %s', v_j2, pg_temp.t_estado(v_a), pg_temp.t_estado(v_b));
    END IF;
    -- El cobro masivo: los mismos ids en otro orden son el mismo cobro.
    v_u := gen_random_uuid();
    v_n := public.marcar_pagos_masivo(ARRAY[v_a, v_b], 'efectivo', v_hoy, v_u);
    v_i := public.marcar_pagos_masivo(ARRAY[v_b, v_a], 'efectivo', v_hoy, v_u);
    IF v_i IS DISTINCT FROM v_n::int OR pg_temp.t_estado(v_a) <> '300.00/300.00' OR pg_temp.t_estado(v_b) <> '300.00/300.00'
       OR (SELECT count(*) FROM pagos WHERE pedido_id IN (v_a, v_b)) <> 4 THEN
      v_fallas := v_fallas || format('I1 el replay del masivo con los ids en otro orden dio %s y %s: A %s, B %s', v_n, v_i,
                                     pg_temp.t_estado(v_a), pg_temp.t_estado(v_b));
    END IF;
    -- Una solicitud sin contenido (como las de antes de la migración) no se compara.
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pagos_solicitudes'::regclass
                AND attname = 'contenido' AND NOT attisdropped) THEN
      EXECUTE 'UPDATE public.pagos_solicitudes SET contenido = NULL WHERE client_request_id = $1' USING v_u;
      v_i := public.marcar_pagos_masivo(ARRAY[v_a], 'efectivo', v_hoy, v_u);
      IF v_i IS DISTINCT FROM v_n::int THEN
        v_fallas := v_fallas || format('I1 el replay de una solicitud sin contenido dio %s (se esperaba %s)', v_i, v_n);
      END IF;
    END IF;
    IF pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || ('I1' || pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('I1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- S1 · SEG-1: el rol de quien llama, con activo
  SELECT string_agg(f, ', ') INTO v_txt
    FROM (VALUES ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'),
                 ('public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)'),
                 ('public.marcar_pagos_masivo_impl(bigint[],text,date)'),
                 ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)')) t(f)
   WHERE (SELECT prosrc FROM pg_proc WHERE oid = t.f::regprocedure)
         !~ 'SELECT rol INTO \w+ FROM perfiles WHERE id = (v_acting_user|v_user|auth\.uid\(\)) AND COALESCE\(activo, true\);';
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('S1 leen el rol de quien llama sin activo: %s', v_txt);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_rol_sin_activo()->'lecturas') l
              WHERE l->>'firma' = 'cancelar_pedido_con_stock(bigint,text,uuid,text)') THEN
    v_fallas := v_fallas || 'S1 auditoria_rol_sin_activo() todavía marca cancelar_pedido_con_stock'::text;
  END IF;

  -- K1 · 1559-b16: NC-A
  BEGIN
    IF pg_temp.t_viol('NC-A') IS NULL THEN
      RAISE EXCEPTION 'NC-A no está en auditoria_integridad()';
    END IF;
    v_n := pg_temp.t_viol('NC-A');
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 K1');
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 3);
    PERFORM pg_temp.t_entregar(v_q);
    PERFORM pg_temp.t_cobro(v_q, 100);
    v_j := pg_temp.t_nc(v_q, 40);
    IF pg_temp.t_viol('NC-A') <> v_n THEN
      v_fallas := v_fallas || format('K1 NC-A pasó de %s a %s con una NC bien nacida (%s)', v_n, pg_temp.t_viol('NC-A'), v_j);
    END IF;
    DELETE FROM pagos WHERE nota_credito_id = (v_j->>'nota_credito_id')::bigint AND pedido_id IS NULL;
    IF pg_temp.t_viol('NC-A') <> v_n + 1 THEN
      v_fallas := v_fallas || format('K1 NC-A dio %s con el crédito de la NC borrado (se esperaba %s)', pg_temp.t_viol('NC-A'), v_n + 1);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('K1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- G1 · 1558-b4: STK-G
  BEGIN
    IF pg_temp.t_viol('STK-G') IS NULL THEN
      RAISE EXCEPTION 'STK-G no está en auditoria_integridad()';
    END IF;
    IF pg_temp.t_viol('STK-G') <> 0 THEN
      v_fallas := v_fallas || format('G1 STK-G da %s en la base', pg_temp.t_viol('STK-G'));
    END IF;
    v_stkf := pg_temp.t_viol('STK-F');
    EXECUTE $f$CREATE FUNCTION public.zz_ensayo_b5_stock() RETURNS void LANGUAGE sql AS $b$
      UPDATE public.productos SET stock = 5 WHERE id = -1;
    $b$$f$;
    IF pg_temp.t_viol('STK-G') <> 1 OR pg_temp.t_viol('STK-F') <> v_stkf THEN
      v_fallas := v_fallas || format('G1 con una asignación absoluta sin origen STK-G dio %s (se esperaba 1) y STK-F %s (era %s)',
                                     pg_temp.t_viol('STK-G'), pg_temp.t_viol('STK-F'), v_stkf);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('G1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · permisos y una sola firma
  IF to_regprocedure('public._credito_ventana(bigint,bigint,numeric,bigint)') IS NULL
     OR to_regprocedure('public.pago_solicitud_abrir(uuid,text,jsonb)') IS NULL THEN
    v_fallas := v_fallas || 'L1 faltan _credito_ventana o pago_solicitud_abrir(uuid,text,jsonb)'::text;
  ELSIF has_function_privilege('anon', 'public._credito_ventana(bigint,bigint,numeric,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._credito_ventana(bigint,bigint,numeric,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.pago_solicitud_abrir(uuid,text,jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.pago_solicitud_abrir(uuid,text,jsonb)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 _credito_ventana o pago_solicitud_abrir tienen EXECUTE para anon o authenticated'::text;
  END IF;
  IF to_regprocedure('public.pago_solicitud_abrir(uuid,text)') IS NOT NULL THEN
    v_fallas := v_fallas || 'L1 la firma vieja pago_solicitud_abrir(uuid,text) sigue viva'::text;
  END IF;

  IF pg_temp.t_cc() IS DISTINCT FROM v_cc THEN
    v_fallas := v_fallas || format('CC pasó de %s a %s', v_cc, pg_temp.t_cc());
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · B1 W1 N1 M1 I1 S1 K1 G1 L1 y CC (%)', v_cc;
 END;
END
$ensayo$;
