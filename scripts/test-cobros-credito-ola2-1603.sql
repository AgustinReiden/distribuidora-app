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
--   V1 · Revisión, hallazgo 1 (regresión): para un crédito común la ventana nueva es exactamente la vieja, para plata de
--        0,5 a 220 y con o sin una boleta excluida, en un cliente con una NC vigente (X, que debe 80) y una anulada (Z),
--        Y de 50 y 30 sueltos; y la pre-toma del alta toma {X}, como antes (la primera versión tomaba {X, Y}).
--   P1 · Revisión, hallazgo 1: en el alta, la edición que baja el total (con la baja de total del trigger), la
--        cancelación, la NC y el cambio de cliente con los dos destinos, lo que _aplicar_credito_pagos toma (sus
--        ventanas) y las boletas a las que les cambia lo pagado están dentro de lo que se pre-tomó antes de los
--        productos (se anota cada ventana que se pide, envolviendo _credito_ventana dentro del bloque). Con la plata:
--        alta → X 50/100; edición de W3 (pagada a cuenta) de 50 a 30 → X 40/100; cancelar W2 → X 80/100; NC de 10 sobre W → X 30/100;
--        cambio de W2 'cliente_original' → X 80/100; 'pedido_nuevo' por 40 → Nb 20/50.
--   En cada caso, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos de cada cliente tocado, y CC-A, CC-B y
--   CC-C de auditoria_integridad() no cambian en toda la base.
--
-- COB-b1 (la cancelación y la NC miden la ventana otra vez con la boleta tomada) necesita dos sesiones: no entra en un
-- DO. Su intercalado está en el cuerpo del PR y en el informe de la tarjeta.
--
-- Corre sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción, y cada caso en
-- un sub-bloque que se revierte. Sin la migración da 'ENSAYO FALLÓ' por B1, W1, N1, M1, I1, V1, P1, S1, K1, G1 y L1.
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

-- La ventana con la fórmula de antes de la migración (la cola de lo que deben las boletas anteriores, sin
-- mirar NC), para la regresión V1.
CREATE OR REPLACE FUNCTION pg_temp.t_ventana_vieja(p_cli bigint, p_suc bigint, p_plata numeric, p_sin bigint)
RETURNS bigint[] LANGUAGE sql AS $fn$
  SELECT COALESCE(array_agg(b.id ORDER BY b.id), '{}'::bigint[])
    FROM (SELECT p.id,
                 sum(p.total - COALESCE(p.monto_pagado, 0)) OVER (ORDER BY p.fecha, p.id)
                   - (p.total - COALESCE(p.monto_pagado, 0)) AS antes
            FROM public.pedidos p
           WHERE p.cliente_id = p_cli AND p.sucursal_id = p_suc
             AND p.id IS DISTINCT FROM p_sin
             AND p.estado NOT IN ('cancelado', 'anulado')
             AND p.total > COALESCE(p.monto_pagado, 0)) b
   WHERE p_plata > 0.005 AND b.antes < p_plata;
$fn$;

-- Cada ventana que se pide durante una operación (P1): quién la pidió y qué devolvió.
CREATE TEMP TABLE t_ventanas (n serial, llamador text, ids bigint[]);

-- El escenario de la revisión (hallazgo 1), más una NC anulada y dos boletas cobradas. Datos del cliente:
--   X de 100 entregada con una NC de 20 vigente (baja X: 20/100, debe 80), Z de 40 entregada y cobrada con una
--   NC de 10 anulada, Y de 50 abierta, W de 100 entregada y cobrada, W2 de 60 pendiente y cobrada, W3 de 50 pendiente y pagada con un
--   pago a cuenta (a_cuenta, lo que queda a favor si baja el total), y 30 sueltos comunes (un pago a cuenta). Devuelve
--   {cliente, X, Z, Y, W, W2, W3}.
CREATE OR REPLACE FUNCTION pg_temp.t_escenario(p_suc bigint, p_adm uuid, p_prod bigint, p_nombre text)
RETURNS bigint[] LANGUAGE plpgsql AS $fn$
DECLARE
  v_hoy date := public._tablero_hoy();
  c bigint; x bigint; z bigint; y bigint; w bigint; w2 bigint; w3 bigint;
  v_j jsonb;
BEGIN
  c := pg_temp.t_cliente(p_suc, p_nombre);
  x := pg_temp.t_alta(c, p_adm, p_prod, 100, v_hoy - 6);
  z := pg_temp.t_alta(c, p_adm, p_prod, 40, v_hoy - 5);
  y := pg_temp.t_alta(c, p_adm, p_prod, 50, v_hoy - 4);
  w := pg_temp.t_alta(c, p_adm, p_prod, 100, v_hoy - 3);
  w2 := pg_temp.t_alta(c, p_adm, p_prod, 60, v_hoy - 2);
  w3 := pg_temp.t_alta(c, p_adm, p_prod, 50, v_hoy - 2);
  PERFORM pg_temp.t_entregar(x);
  PERFORM pg_temp.t_entregar(z);
  PERFORM pg_temp.t_entregar(w);
  PERFORM pg_temp.t_cobro(z, 40);
  PERFORM pg_temp.t_cobro(w, 100);
  PERFORM pg_temp.t_cobro(w2, 60);
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, a_cuenta)
  VALUES (c, w3, p_suc, 50, 'efectivo', v_hoy, p_adm, true);
  v_j := pg_temp.t_nc(x, 20);
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN RAISE EXCEPTION 'escenario: NC de X: %', v_j; END IF;
  v_j := pg_temp.t_nc(z, 10);
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN RAISE EXCEPTION 'escenario: NC de Z: %', v_j; END IF;
  v_j := public.anular_nota_credito_venta((v_j->>'nota_credito_id')::bigint, 'ensayo B5');
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN RAISE EXCEPTION 'escenario: anular la NC de Z: %', v_j; END IF;
  PERFORM pg_temp.t_credito(c, p_suc, p_adm, 30, v_hoy - 1);
  IF pg_temp.t_estado(x) <> '20.00/100.00' OR pg_temp.t_estado(y) <> '0.00/50.00'
     OR pg_temp.t_suelto(c) <> 30 THEN
    RAISE EXCEPTION 'escenario: X %, Y %, suelto %', pg_temp.t_estado(x), pg_temp.t_estado(y), pg_temp.t_suelto(c);
  END IF;
  RETURN ARRAY[c, x, z, y, w, w2, w3];
END
$fn$;

-- '' si lo que _aplicar_credito_pagos tomó (sus ventanas) y las boletas que cambiaron de monto_pagado están
-- dentro de lo que se pre-tomó, más las propias y las que nacieron en la operación; si no, el detalle.
CREATE OR REPLACE FUNCTION pg_temp.t_dentro(p_que text, p_propias bigint[], p_id_antes bigint, p_pagado_antes jsonb, p_cli bigint[])
RETURNS text LANGUAGE sql AS $fn$
  WITH pre AS (
    SELECT COALESCE(array_agg(DISTINCT i), '{}'::bigint[]) AS ids
      FROM t_ventanas v, unnest(v.ids) i
     WHERE v.llamador IN ('_credito_bloquea_boletas', '_alta_bloquea_boletas_credito', '_edicion_bloquea_boletas',
                          'pedidos_reconciliar_pagos', 'cambiar_cliente_pedido')
  ), apl AS (
    SELECT COALESCE(array_agg(DISTINCT i), '{}'::bigint[]) AS ids
      FROM t_ventanas v, unnest(v.ids) i
     WHERE v.llamador = '_aplicar_credito_pagos'
  ), movidas AS (
    SELECT COALESCE(array_agg(p.id), '{}'::bigint[]) AS ids
      FROM public.pedidos p
     WHERE p.cliente_id = ANY(p_cli)
       AND p.id <= p_id_antes
       AND COALESCE(p.monto_pagado, 0) IS DISTINCT FROM (p_pagado_antes->>p.id::text)::numeric
  ), fuera AS (
    SELECT ARRAY(SELECT i FROM unnest((SELECT ids FROM apl) || (SELECT ids FROM movidas)) i
                  WHERE i <= p_id_antes
                    AND i <> ALL ((SELECT ids FROM pre) || p_propias)
                  ORDER BY i) AS ids
  )
  SELECT CASE WHEN cardinality(fuera.ids) = 0
                   AND (SELECT count(*) FROM t_ventanas WHERE llamador = '_aplicar_credito_pagos') > 0 THEN ''
              WHEN cardinality(fuera.ids) = 0 THEN format(' %s: _aplicar_credito_pagos no pidió ninguna ventana', p_que)
              ELSE format(' %s: tomó o pagó %s fuera de la pre-toma %s (aplicar %s)', p_que, fuera.ids,
                          (SELECT ids FROM pre), (SELECT ids FROM apl)) END
    FROM fuera;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pagado(p_cli bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_object_agg(id::text, COALESCE(monto_pagado, 0)), '{}'::jsonb)
    FROM public.pedidos WHERE cliente_id = ANY(p_cli);
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
  v_e      bigint[];
  v_e2     bigint[];
  v_max    bigint;
  v_pag    jsonb;
  v_comun  bigint;
  v_plata  numeric;
  v_dif    text;
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

  -- V1 · hallazgo 1 de la revisión: para un crédito común la ventana es exactamente la de antes, aunque el
  -- cliente tenga una NC vigente (X) y una anulada (Z); y la pre-toma del alta toma lo mismo que antes ({X}).
  BEGIN
    v_e := pg_temp.t_escenario(v_suc, v_adm, v_prod, 'ZZ ensayo B5 V1');
    v_cli := v_e[1];
    SELECT id INTO v_comun FROM pagos WHERE cliente_id = v_cli AND pedido_id IS NULL;
    v_dif := NULL;
    FOR v_i IN 1..440 LOOP
      v_plata := v_i / 2.0;
      IF public._credito_ventana(v_cli, v_suc, v_plata, NULL, ARRAY[v_comun])
           IS DISTINCT FROM pg_temp.t_ventana_vieja(v_cli, v_suc, v_plata, NULL)
         OR public._credito_ventana(v_cli, v_suc, v_plata, v_e[6], ARRAY[v_comun])
           IS DISTINCT FROM pg_temp.t_ventana_vieja(v_cli, v_suc, v_plata, v_e[6]) THEN
        v_dif := format('con %s: nueva %s, vieja %s', v_plata,
                        public._credito_ventana(v_cli, v_suc, v_plata, NULL, ARRAY[v_comun]),
                        pg_temp.t_ventana_vieja(v_cli, v_suc, v_plata, NULL));
        EXIT;
      END IF;
    END LOOP;
    v_ids := ARRAY(SELECT x FROM unnest(public._alta_bloquea_boletas_credito(v_cli, v_suc)) x ORDER BY x);
    IF v_dif IS NOT NULL OR v_ids IS DISTINCT FROM ARRAY[v_e[2]]
       OR pg_temp.t_ventana_vieja(v_cli, v_suc, 30, NULL) IS DISTINCT FROM ARRAY[v_e[2]] THEN
      v_fallas := v_fallas || format('V1 la ventana de un crédito común cambió (%s); el alta pre-toma %s (antes {X=%s})',
                                     COALESCE(v_dif, 'igual'), v_ids, v_e[2]);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P1 · hallazgo 1: en cada camino (alta, edición con baja de total, cancelación, NC, cambio de cliente con
  -- los dos destinos), lo que _aplicar_credito_pagos toma (sus ventanas) y las boletas a las que les cambia lo
  -- pagado están dentro de lo que se pre-tomó antes de los productos. Se anota cada ventana que se pide
  -- (_credito_ventana se envuelve, dentro de este bloque que se revierte, con una que anota quién la pidió).
  BEGIN
    IF to_regprocedure('public._credito_ventana(bigint,bigint,numeric,bigint,bigint[])') IS NULL THEN
      RAISE EXCEPTION 'no existe _credito_ventana(bigint,bigint,numeric,bigint,bigint[])';
    END IF;
    ALTER FUNCTION public._credito_ventana(bigint, bigint, numeric, bigint, bigint[]) RENAME TO zz_credito_ventana_real;
    EXECUTE $f$CREATE FUNCTION public._credito_ventana(a bigint, b bigint, c numeric, d bigint, e bigint[])
      RETURNS bigint[] LANGUAGE plpgsql SET search_path TO 'public' AS $b$
      DECLARE r bigint[]; ctx text;
      BEGIN
        r := public.zz_credito_ventana_real(a, b, c, d, e);
        GET DIAGNOSTICS ctx = PG_CONTEXT;
        INSERT INTO pg_temp.t_ventanas (llamador, ids)
        VALUES (substring(ctx from E'\n[^\n]*?PL/pgSQL function (?:public\\.)?(\\w+)\\('), r);
        RETURN r;
      END $b$$f$;

    -- a · el alta: los 30 sueltos van a X (50/100), no a Y.
    BEGIN
      v_e := pg_temp.t_escenario(v_suc, v_adm, v_prod, 'ZZ ensayo B5 P1a');
      SELECT max(id) INTO v_max FROM pedidos; v_pag := pg_temp.t_pagado(ARRAY[v_e[1]]);
      DELETE FROM pg_temp.t_ventanas;
      PERFORM pg_temp.t_alta(v_e[1], v_adm, v_prod, 10, v_hoy);
      v_txt := pg_temp.t_dentro('alta', '{}', v_max, v_pag, ARRAY[v_e[1]]);
      IF v_txt <> '' OR pg_temp.t_estado(v_e[2]) <> '50.00/100.00' OR pg_temp.t_estado(v_e[4]) <> '0.00/50.00'
         OR pg_temp.t_saldo(v_e[1]) <> '' THEN
        v_fallas := v_fallas || format('P1%s; X %s, Y %s%s', v_txt, pg_temp.t_estado(v_e[2]), pg_temp.t_estado(v_e[4]),
                                       pg_temp.t_saldo(v_e[1]));
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB52';
    EXCEPTION
      WHEN SQLSTATE 'ZZB52' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('P1 alta dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- b · la edición que baja el total: W3 de 50, pagada a cuenta, pasa a 30 y los 20 que suelta van a X (40/100).
    BEGIN
      v_e := pg_temp.t_escenario(v_suc, v_adm, v_prod, 'ZZ ensayo B5 P1b');
      SELECT max(id) INTO v_max FROM pedidos; v_pag := pg_temp.t_pagado(ARRAY[v_e[1]]);
      DELETE FROM pg_temp.t_ventanas;
      v_j := public.actualizar_pedido_items(
        v_e[7], jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 30, 'precio_unitario', 1)),
        v_adm, NULL, NULL);
      PERFORM pg_temp.t_reset();
      v_txt := pg_temp.t_dentro('edición', ARRAY[v_e[7]], v_max, v_pag, ARRAY[v_e[1]]);
      IF v_txt <> '' OR NOT COALESCE((v_j->>'success')::boolean, false)
         OR pg_temp.t_estado(v_e[7]) <> '30.00/30.00' OR pg_temp.t_estado(v_e[2]) <> '40.00/100.00'
         OR pg_temp.t_saldo(v_e[1]) <> '' THEN
        v_fallas := v_fallas || format('P1%s; edición %s, W3 %s, X %s%s', v_txt, v_j, pg_temp.t_estado(v_e[7]),
                                       pg_temp.t_estado(v_e[2]), pg_temp.t_saldo(v_e[1]));
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB52';
    EXCEPTION
      WHEN SQLSTATE 'ZZB52' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('P1 edición dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- d · la cancelación de W2 (cobrada 60): los 60 van a X (80/100).
    BEGIN
      v_e := pg_temp.t_escenario(v_suc, v_adm, v_prod, 'ZZ ensayo B5 P1d');
      SELECT max(id) INTO v_max FROM pedidos; v_pag := pg_temp.t_pagado(ARRAY[v_e[1]]);
      DELETE FROM pg_temp.t_ventanas;
      v_j := public.cancelar_pedido_con_stock(v_e[6], 'ensayo B5', v_adm, 'error_de_carga');
      PERFORM pg_temp.t_reset();
      v_txt := pg_temp.t_dentro('cancelación', ARRAY[v_e[6]], v_max, v_pag, ARRAY[v_e[1]]);
      IF v_txt <> '' OR NOT COALESCE((v_j->>'success')::boolean, false)
         OR pg_temp.t_estado(v_e[2]) <> '80.00/100.00' OR pg_temp.t_estado(v_e[4]) <> '0.00/50.00'
         OR pg_temp.t_saldo(v_e[1]) <> '' THEN
        v_fallas := v_fallas || format('P1%s; cancelación %s, X %s, Y %s%s', v_txt, v_j, pg_temp.t_estado(v_e[2]),
                                       pg_temp.t_estado(v_e[4]), pg_temp.t_saldo(v_e[1]));
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB52';
    EXCEPTION
      WHEN SQLSTATE 'ZZB52' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('P1 cancelación dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- e · una NC de 10 sobre W (entregada y cobrada): su crédito va a X (30/100).
    BEGIN
      v_e := pg_temp.t_escenario(v_suc, v_adm, v_prod, 'ZZ ensayo B5 P1e');
      SELECT max(id) INTO v_max FROM pedidos; v_pag := pg_temp.t_pagado(ARRAY[v_e[1]]);
      DELETE FROM pg_temp.t_ventanas;
      v_j := pg_temp.t_nc(v_e[5], 10);
      v_txt := pg_temp.t_dentro('NC', ARRAY[v_e[5]], v_max, v_pag, ARRAY[v_e[1]]);
      IF v_txt <> '' OR (v_j->>'credito_aplicado_otras')::numeric IS DISTINCT FROM 10
         OR pg_temp.t_estado(v_e[2]) <> '30.00/100.00' OR pg_temp.t_saldo(v_e[1]) <> '' THEN
        v_fallas := v_fallas || format('P1%s; NC %s, X %s%s', v_txt, v_j, pg_temp.t_estado(v_e[2]), pg_temp.t_saldo(v_e[1]));
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB52';
    EXCEPTION
      WHEN SQLSTATE 'ZZB52' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('P1 NC dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- f · el cambio de cliente de W2 'cliente_original': los 60 le vuelven al original y van a X (80/100).
    BEGIN
      v_e := pg_temp.t_escenario(v_suc, v_adm, v_prod, 'ZZ ensayo B5 P1f');
      v_cli2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 P1f nuevo');
      SELECT max(id) INTO v_max FROM pedidos; v_pag := pg_temp.t_pagado(ARRAY[v_e[1], v_cli2]);
      DELETE FROM pg_temp.t_ventanas;
      v_j := public.cambiar_cliente_pedido(
        v_e[6], v_cli2, v_adm,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 60, 'precio_unitario', 1)),
        60, NULL, 0, 'ensayo B5', 'cliente_original');
      PERFORM pg_temp.t_reset();
      v_txt := pg_temp.t_dentro('cambio de cliente (original)', ARRAY[v_e[6]], v_max, v_pag, ARRAY[v_e[1], v_cli2]);
      IF v_txt <> '' OR NOT COALESCE((v_j->>'success')::boolean, false)
         OR pg_temp.t_estado(v_e[2]) <> '80.00/100.00' OR pg_temp.t_saldo(v_e[1]) <> '' OR pg_temp.t_saldo(v_cli2) <> '' THEN
        v_fallas := v_fallas || format('P1%s; cambio %s, X %s%s%s', v_txt, v_j, pg_temp.t_estado(v_e[2]),
                                       pg_temp.t_saldo(v_e[1]), pg_temp.t_saldo(v_cli2));
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB52';
    EXCEPTION
      WHEN SQLSTATE 'ZZB52' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('P1 cambio de cliente (original) dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- g · el cambio de cliente de W2 'pedido_nuevo' a N, que debe Nb de 50, por 40: el excedente de 20 va a Nb.
    BEGIN
      v_e := pg_temp.t_escenario(v_suc, v_adm, v_prod, 'ZZ ensayo B5 P1g');
      v_cli2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo B5 P1g nuevo');
      v_b := pg_temp.t_alta(v_cli2, v_adm, v_prod, 50, v_hoy - 3);
      SELECT max(id) INTO v_max FROM pedidos; v_pag := pg_temp.t_pagado(ARRAY[v_e[1], v_cli2]);
      DELETE FROM pg_temp.t_ventanas;
      v_j := public.cambiar_cliente_pedido(
        v_e[6], v_cli2, v_adm,
        jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 40, 'precio_unitario', 1)),
        40, NULL, 0, 'ensayo B5', 'pedido_nuevo');
      PERFORM pg_temp.t_reset();
      v_txt := pg_temp.t_dentro('cambio de cliente (pedido nuevo)', ARRAY[v_e[6]], v_max, v_pag, ARRAY[v_e[1], v_cli2]);
      IF v_txt <> '' OR NOT COALESCE((v_j->>'success')::boolean, false)
         OR pg_temp.t_estado(v_b) <> '20.00/50.00' OR pg_temp.t_saldo(v_e[1]) <> '' OR pg_temp.t_saldo(v_cli2) <> '' THEN
        v_fallas := v_fallas || format('P1%s; cambio %s, Nb %s%s%s', v_txt, v_j, pg_temp.t_estado(v_b),
                                       pg_temp.t_saldo(v_e[1]), pg_temp.t_saldo(v_cli2));
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB52';
    EXCEPTION
      WHEN SQLSTATE 'ZZB52' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('P1 cambio de cliente (pedido nuevo) dio %s: %s', SQLSTATE, SQLERRM);
    END;

    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZB51';
  EXCEPTION
    WHEN SQLSTATE 'ZZB51' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P1 dio %s: %s', SQLSTATE, SQLERRM);
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
  IF to_regprocedure('public._credito_ventana(bigint,bigint,numeric,bigint,bigint[])') IS NULL
     OR to_regprocedure('public.pago_solicitud_abrir(uuid,text,jsonb)') IS NULL THEN
    v_fallas := v_fallas || 'L1 faltan _credito_ventana o pago_solicitud_abrir(uuid,text,jsonb)'::text;
  ELSIF has_function_privilege('anon', 'public._credito_ventana(bigint,bigint,numeric,bigint,bigint[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._credito_ventana(bigint,bigint,numeric,bigint,bigint[])', 'EXECUTE')
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
  RAISE EXCEPTION 'ENSAYO OK · B1 W1 N1 M1 I1 V1 P1 S1 K1 G1 L1 y CC (%)', v_cc;
 END;
END
$ensayo$;
