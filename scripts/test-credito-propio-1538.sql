-- Ensayo de la migración 489: la cancelación, la NC, el cambio de cliente y la baja de total de una boleta aplican sólo
-- el crédito que nace en esa operación, y los pagos viejos sin marcas se quitan de su boleta (#1538: B1 y B2).
--
-- En los casos de B1, un crédito K del cliente se aplica a una boleta y se quita con desimputar_pago («Quitar»): queda
-- suelto. Después pasa la operación, que antes de la 489 lo volvía a aplicar.
--   K1 · Cancelación: W de 100 (de la que se quitó K, 30) y X de 60 cobrada. Cancelar X le pasa a W sólo los 60 de X
--        (60/100). K sigue suelto (30) y credito_aplicado es 60.
--   N1 · NC: W de 50 (de la que se quitó K, 20) y Q de 100 entregada y cobrada. La NC de 30 sobre Q va entera a W
--        (30/50), K sigue suelto (20) y credito_aplicado_otras es 30.
--   C1 · Cambio de cliente 'cliente_original': C1 tiene Y de 100 (de la que se quitó K, 25) y X de 100 con un cobro de
--        60. Pasar X a C2 le devuelve a C1 los 60 y van a Y (60/100). K sigue suelto (25), aplicado_cliente_original
--        es 60, y C2 no queda con nada suelto.
--   C2 · Cambio de cliente 'pedido_nuevo' con excedente: C2 tiene Z de 50 y X (de C1) tiene un cobro de 100. Pasar X a
--        C2 con 70 deja 30 de excedente, que van a Z (30/50). El nuevo queda saldado y a C2 no le queda nada suelto.
--   R1 · Baja de total: W de 100 (de la que se quitó K, 30) e Y de 50 pagada con un pago a cuenta. Y baja a 20: los 30
--        de excedente van a W (30/100) y K sigue suelto.
--   R2 · Consecuencia aceptada por el dueño: W de 100 (de la que se quitó K, 30) sube a 120 y ya no absorbe K sola
--        (0/120, K suelto).
--   A1 · El alta sigue barriendo todo (decisión del dueño): con K quitado de W, una boleta nueva del cliente absorbe K
--        (FIFO, a la impaga más vieja).
--   D1 · Un crédito de NC imputado sin marcas (como los de antes de la 479): desimputar_pago lo quita (vuelve suelto).
--        Un cobro común da 22023 y el mensaje dice que no figura como saldo a favor aplicado, no que es un cobro.
--        Como authenticated, el DELETE REST de ese crédito de NC da 42501 con «Quitalo de la boleta».
--   B2 · (sólo donde están los pagos de prod) Los pagos 6492, 6829, 1668 y 1669 tienen a_cuenta, siguen en las boletas
--        6445, 6478 y 2618, y desimputar_pago los acepta (con un admin de la sucursal de cada uno).
--   En K1, N1, C1, C2, R1, R2, A1 y D1, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos para cada cliente
--   tocado, y las violaciones de CC-A de auditoria_integridad() en toda la base no cambian.
--   L1 · _aplicar_credito_pagos no tiene EXECUTE para anon ni authenticated, y aplicar_credito_cliente tampoco.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. La migración ya está aplicada: se corre solo. Sin la migración, K1,
-- N1, C1, R1, R2 y D1 dan 'ENSAYO FALLÓ'.
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
  VALUES (p_nombre, p_nombre, 'Ensayo 1538', p_suc)
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
    'ensayo 1538', 'efectivo', 'pendiente', p_fecha, 'ZZ');
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

-- «Quitar»: el crédito p_pago, que una boleta absorbió entero, vuelve suelto. Devuelve la boleta de la que salió.
CREATE OR REPLACE FUNCTION pg_temp.t_quitar(p_pago bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_ped bigint;
  v_j   jsonb;
BEGIN
  SELECT pedido_id INTO v_ped FROM public.pagos WHERE id = p_pago;
  IF v_ped IS NULL THEN
    RAISE EXCEPTION 'el crédito % no está en ninguna boleta: la boleta no lo absorbió', p_pago;
  END IF;
  v_j := public.desimputar_pago(p_pago, v_ped);
  IF NOT COALESCE((v_j->>'success')::boolean, false) OR (SELECT pedido_id FROM public.pagos WHERE id = p_pago) IS NOT NULL THEN
    RAISE EXCEPTION 'desimputar_pago no lo quitó: %', v_j;
  END IF;
  RETURN v_ped;
END
$fn$;

-- La boleta entregada (retiro en el depósito, sin chofer).
CREATE OR REPLACE FUNCTION pg_temp.t_entregar(p_ped bigint)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = p_ped;
$fn$;

-- La respuesta de la NC por p_cant unidades de la única línea de la boleta.
CREATE OR REPLACE FUNCTION pg_temp.t_nc(p_ped bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.crear_nota_credito_venta(
    p_ped, (SELECT cliente_id FROM public.pedidos WHERE id = p_ped),
    (SELECT jsonb_build_array(jsonb_build_object('pedido_item_id', min(id), 'cantidad', p_cant))
       FROM public.pedido_items WHERE pedido_id = p_ped),
    'producto_vencido', 'ensayo 1538', NULL);
$fn$;

-- Pasar la boleta p_ped al cliente p_cli con p_cant unidades del producto, como el front.
CREATE OR REPLACE FUNCTION pg_temp.t_cambiar(p_ped bigint, p_cli bigint, p_adm uuid, p_prod bigint, p_cant int, p_destino text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cambiar_cliente_pedido(
    p_ped, p_cli, p_adm,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 1)),
    p_cant, NULL, 0, 'ensayo 1538', p_destino);
  PERFORM pg_temp.t_reset();
  RETURN v_res;
END
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

-- Lo suelto de un cliente.
CREATE OR REPLACE FUNCTION pg_temp.t_suelto(p_cli bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(sum(monto), 0) FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL;
$fn$;

-- Las violaciones de CC-A de toda la base, de auditoria_integridad().
CREATE OR REPLACE FUNCTION pg_temp.t_cca()
RETURNS int LANGUAGE sql AS $fn$
  SELECT (e->>'violaciones')::int
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' = 'CC-A';
$fn$;

-- 'pagado/total' de una boleta, para comparar de una vez.
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
  v_k      bigint;
  v_w      bigint;
  v_x      bigint;
  v_q      bigint;
  v_y      bigint;
  v_z      bigint;
  v_p      bigint;
  v_nc     bigint;
  v_j      jsonb;
  v_txt    text;
  v_fallas text[] := '{}';
  v_hechos text[] := '{}';
  v_cca    int;
  v_adm1   uuid;
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

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1538');
  v_cca := pg_temp.t_cca();

  -- K1 · la cancelación aplica sólo lo que desimputó
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 K1');
    v_k := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy - 5);
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 4);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 60, v_hoy - 3);
    v_p := pg_temp.t_cobro(v_x, 60);
    IF pg_temp.t_quitar(v_k) IS DISTINCT FROM v_w THEN
      RAISE EXCEPTION 'K1: W no había absorbido K';
    END IF;
    v_j := public.cancelar_pedido_con_stock(v_x, 'ensayo 1538', v_adm, 'error_de_carga');
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'credito_aplicado')::numeric IS DISTINCT FROM 60
       OR pg_temp.t_estado(v_w) <> '60.00/100.00'
       OR pg_temp.t_suelto(v_cli) <> 30
       OR (SELECT pedido_id FROM pagos WHERE id = v_k) IS NOT NULL
       OR (SELECT pedido_id FROM pagos WHERE id = v_p) IS DISTINCT FROM v_w
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('K1 dio %s; W %s, suelto %s, K en %s%s', v_j, pg_temp.t_estado(v_w),
                                     pg_temp.t_suelto(v_cli), (SELECT pedido_id FROM pagos WHERE id = v_k), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('K1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N1 · la NC aplica sólo su crédito
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 N1');
    v_k := pg_temp.t_credito(v_cli, v_suc, v_adm, 20, v_hoy - 5);
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 50, v_hoy - 4);
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 3);
    PERFORM pg_temp.t_entregar(v_q);
    PERFORM pg_temp.t_cobro(v_q, 100);
    IF pg_temp.t_quitar(v_k) IS DISTINCT FROM v_w THEN
      RAISE EXCEPTION 'N1: W no había absorbido K';
    END IF;
    v_j := pg_temp.t_nc(v_q, 30);
    IF (v_j->>'credito_aplicado_pedido')::numeric IS DISTINCT FROM 0
       OR (v_j->>'credito_aplicado_otras')::numeric IS DISTINCT FROM 30
       OR (v_j->>'credito_disponible')::numeric IS DISTINCT FROM 0
       OR pg_temp.t_estado(v_w) <> '30.00/50.00'
       OR pg_temp.t_suelto(v_cli) <> 20
       OR (SELECT pedido_id FROM pagos WHERE id = v_k) IS NOT NULL
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('N1 dio %s; W %s, suelto %s%s', v_j, pg_temp.t_estado(v_w),
                                     pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C1 · el cambio de cliente le aplica al cliente original sólo lo que le vuelve
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 C1');
    v_cli2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 C1 nuevo');
    v_k := pg_temp.t_credito(v_cli, v_suc, v_adm, 25, v_hoy - 5);
    v_y := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 4);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 3);
    v_p := pg_temp.t_cobro(v_x, 60);
    IF pg_temp.t_quitar(v_k) IS DISTINCT FROM v_y THEN
      RAISE EXCEPTION 'C1: Y no había absorbido K';
    END IF;
    v_j := pg_temp.t_cambiar(v_x, v_cli2, v_adm, v_prod, 100, 'cliente_original');
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'aplicado_cliente_original')::numeric IS DISTINCT FROM 60
       OR pg_temp.t_estado(v_y) <> '60.00/100.00'
       OR pg_temp.t_suelto(v_cli) <> 25
       OR (SELECT pedido_id FROM pagos WHERE id = v_k) IS NOT NULL
       OR (SELECT pedido_id FROM pagos WHERE id = v_p) IS DISTINCT FROM v_y
       OR pg_temp.t_suelto(v_cli2) <> 0
       OR pg_temp.t_saldo(v_cli) <> '' OR pg_temp.t_saldo(v_cli2) <> '' THEN
      v_fallas := v_fallas || format('C1 dio %s; Y %s, suelto C1 %s, suelto C2 %s%s%s', v_j, pg_temp.t_estado(v_y),
                                     pg_temp.t_suelto(v_cli), pg_temp.t_suelto(v_cli2), pg_temp.t_saldo(v_cli), pg_temp.t_saldo(v_cli2));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C2 · el excedente de 'pedido_nuevo' se aplica a las boletas del cliente nuevo
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 C2');
    v_cli2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 C2 nuevo');
    v_z := pg_temp.t_alta(v_cli2, v_adm, v_prod, 50, v_hoy - 4);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 3);
    v_p := pg_temp.t_cobro(v_x, 100);
    v_j := pg_temp.t_cambiar(v_x, v_cli2, v_adm, v_prod, 70, 'pedido_nuevo');
    v_q := (v_j->>'nuevo_pedido_id')::bigint;
    IF v_q IS NULL THEN
      SELECT id INTO v_q FROM pedidos WHERE cliente_id = v_cli2 AND id <> v_z ORDER BY id DESC LIMIT 1;
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR pg_temp.t_estado(v_z) <> '30.00/50.00'
       OR pg_temp.t_estado(v_q) <> '70.00/70.00'
       OR pg_temp.t_suelto(v_cli2) <> 0
       OR pg_temp.t_suelto(v_cli) <> 0
       OR pg_temp.t_saldo(v_cli) <> '' OR pg_temp.t_saldo(v_cli2) <> '' THEN
      v_fallas := v_fallas || format('C2 dio %s; Z %s, nuevo %s, suelto C2 %s%s%s', v_j, pg_temp.t_estado(v_z),
                                     pg_temp.t_estado(v_q), pg_temp.t_suelto(v_cli2), pg_temp.t_saldo(v_cli), pg_temp.t_saldo(v_cli2));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R1 · la baja de total de una boleta aplica sólo su excedente
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 R1');
    v_k := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy - 6);
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 5);
    v_y := pg_temp.t_alta(v_cli, v_adm, v_prod, 50, v_hoy - 4);
    -- Y pagada con un pago a cuenta (#1329): lo que sobre al bajar el total es plata que entró.
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, a_cuenta)
    VALUES (v_cli, v_y, v_suc, 50, 'efectivo', v_hoy, v_adm, true)
    RETURNING id INTO v_p;
    IF pg_temp.t_quitar(v_k) IS DISTINCT FROM v_w THEN
      RAISE EXCEPTION 'R1: W no había absorbido K';
    END IF;
    UPDATE pedidos SET total = 20 WHERE id = v_y;
    IF pg_temp.t_estado(v_w) <> '30.00/100.00'
       OR pg_temp.t_estado(v_y) <> '20.00/20.00'
       OR (SELECT pedido_id FROM pagos WHERE id = v_k) IS NOT NULL
       OR pg_temp.t_suelto(v_cli) <> 30
       OR NOT EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_w AND pago_padre_id = v_p AND monto = 30)
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('R1 W %s, Y %s, suelto %s, K en %s%s', pg_temp.t_estado(v_w), pg_temp.t_estado(v_y),
                                     pg_temp.t_suelto(v_cli), (SELECT pedido_id FROM pagos WHERE id = v_k), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R2 · una boleta que sube de total ya no absorbe sola el crédito suelto (consecuencia aceptada por el dueño)
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 R2');
    v_k := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy - 6);
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 5);
    IF pg_temp.t_quitar(v_k) IS DISTINCT FROM v_w THEN
      RAISE EXCEPTION 'R2: W no había absorbido K';
    END IF;
    UPDATE pedidos SET total = 120 WHERE id = v_w;
    IF pg_temp.t_estado(v_w) <> '0.00/120.00'
       OR (SELECT pedido_id FROM pagos WHERE id = v_k) IS NOT NULL
       OR pg_temp.t_suelto(v_cli) <> 30
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('R2 W %s, suelto %s, K en %s%s', pg_temp.t_estado(v_w), pg_temp.t_suelto(v_cli),
                                     (SELECT pedido_id FROM pagos WHERE id = v_k), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- A1 · el alta sigue barriendo todo: absorbe lo quitado
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 A1');
    v_k := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy - 5);
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 4);
    PERFORM pg_temp.t_quitar(v_k);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 40, v_hoy);
    IF pg_temp.t_suelto(v_cli) <> 0
       OR (SELECT pedido_id FROM pagos WHERE id = v_k) IS DISTINCT FROM v_w
       OR pg_temp.t_estado(v_w) <> '30.00/100.00'
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('A1 el alta no absorbió lo quitado: W %s, suelto %s, K en %s%s', pg_temp.t_estado(v_w),
                                     pg_temp.t_suelto(v_cli), (SELECT pedido_id FROM pagos WHERE id = v_k), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('A1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- D1 · un crédito de NC imputado sin marcas se quita; un cobro no, y el mensaje no dice que es un cobro
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1538 D1');
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 3);
    PERFORM pg_temp.t_entregar(v_q);
    PERFORM pg_temp.t_cobro(v_q, 100);
    v_j := pg_temp.t_nc(v_q, 30);
    v_nc := (v_j->>'nota_credito_id')::bigint;
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 50, v_hoy);
    -- La NC quedó aplicada a W por el alta (con marcas). Se la reemplaza por una imputada a mano, sin
    -- marcas, como las de antes de la 479: un INSERT del servidor con la boleta puesta.
    DELETE FROM pagos WHERE nota_credito_id = v_nc;
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, nota_credito_id, notas)
    VALUES (v_cli, v_w, v_suc, 30, 'nota_credito', v_hoy, v_adm, v_nc, 'Nota de credito #' || v_nc)
    RETURNING id INTO v_p;
    IF (SELECT de_saldo_a_favor OR a_cuenta OR pago_origen_id IS NOT NULL FROM pagos WHERE id = v_p) THEN
      RAISE EXCEPTION 'D1: el crédito de NC nació con marcas';
    END IF;
    IF pg_temp.t_estado(v_w) <> '30.00/50.00' THEN
      RAISE EXCEPTION 'D1: W no quedó con la NC (%)', pg_temp.t_estado(v_w);
    END IF;

    -- Como authenticated, el DELETE REST dice cómo quitarlo.
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      DELETE FROM pagos WHERE id = v_p;
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || 'D1 el DELETE REST borró un crédito de NC aplicado'::text;
    EXCEPTION WHEN SQLSTATE '42501' THEN
      EXECUTE 'RESET ROLE';
      IF SQLERRM NOT LIKE '%Quitalo de la boleta%' THEN
        v_fallas := v_fallas || format('D1 el rechazo del DELETE REST no dice cómo quitarlo: %s', SQLERRM);
      END IF;
    END;

    v_j := public.desimputar_pago(v_p, v_w);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'ya_estaba_suelto')::boolean
       OR (SELECT pedido_id FROM pagos WHERE id = v_p) IS NOT NULL
       OR pg_temp.t_estado(v_w) <> '0.00/50.00'
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('D1 desimputar_pago con la NC dio %s; W %s%s', v_j, pg_temp.t_estado(v_w), pg_temp.t_saldo(v_cli));
    END IF;

    v_k := pg_temp.t_cobro(v_w, 10);
    BEGIN
      v_j := public.desimputar_pago(v_k, v_w);
      v_fallas := v_fallas || format('D1 quitó un cobro: %s', v_j);
    EXCEPTION WHEN SQLSTATE '22023' THEN
      IF SQLERRM NOT LIKE '%no figura como saldo a favor aplicado%' OR SQLERRM LIKE '%es un cobro%' THEN
        v_fallas := v_fallas || format('D1 el mensaje de un cobro dice: %s', SQLERRM);
      END IF;
    END;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
  EXCEPTION
    WHEN SQLSTATE 'ZZ538' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- B2 · los pagos 6492, 6829, 1668 y 1669 (sólo donde existen: prod). Se reconocen por id y boleta: en una base
  -- local esos ids pueden ser otros pagos.
  IF (SELECT count(*) FROM pagos WHERE (id, pedido_id) IN ((6492, 6445), (6829, 6478), (1668, 2618), (1669, 2618))) NOT IN (0, 4) THEN
    v_fallas := v_fallas || 'B2 están algunos de los pagos 6492, 6829, 1668 y 1669 en su boleta y otros no'::text;
  ELSIF EXISTS (SELECT 1 FROM pagos WHERE (id, pedido_id) IN ((6492, 6445), (6829, 6478), (1668, 2618), (1669, 2618))) THEN
    BEGIN
      IF (SELECT count(*) FROM pagos
           WHERE (id, pedido_id) IN ((6492, 6445), (6829, 6478), (1668, 2618), (1669, 2618))
             AND a_cuenta AND NOT de_saldo_a_favor AND pago_origen_id IS NULL) <> 4 THEN
        v_fallas := v_fallas || 'B2 los pagos 6492, 6829, 1668 y 1669 no están marcados en sus boletas'::text;
      END IF;
      FOR v_p, v_w IN SELECT id, pedido_id FROM pagos WHERE id IN (6492, 6829, 1668, 1669) ORDER BY id LOOP
        -- Un admin de la sucursal del pago (6492 y 6829 son de la 1; 1668 y 1669, de la 2).
        SELECT us.usuario_id INTO v_adm1
          FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
         WHERE us.sucursal_id = (SELECT sucursal_id FROM pagos WHERE id = v_p) AND pf.activo AND pf.rol = 'admin'
         ORDER BY us.usuario_id LIMIT 1;
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm1, 'role', 'authenticated')::text, true);
        PERFORM set_config('request.headers',
          json_build_object('x-sucursal-id', (SELECT sucursal_id FROM pagos WHERE id = v_p)::text)::text, true);
        v_j := public.desimputar_pago(v_p, v_w);
        IF NOT COALESCE((v_j->>'success')::boolean, false) OR (SELECT pedido_id FROM pagos WHERE id = v_p) IS NOT NULL THEN
          v_fallas := v_fallas || format('B2 desimputar_pago(%s, %s) dio %s', v_p, v_w, v_j);
        END IF;
      END LOOP;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ538';
    EXCEPTION
      WHEN SQLSTATE 'ZZ538' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('B2 dio %s: %s', SQLSTATE, SQLERRM);
    END;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    v_hechos := v_hechos || 'B2'::text;
  ELSE
    v_hechos := v_hechos || 'B2 (sin los pagos de prod: no corrió)'::text;
  END IF;

  IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
    v_fallas := v_fallas || format('CC-A pasó de %s a %s', v_cca, pg_temp.t_cca());
  END IF;

  -- L1 · EXECUTE
  IF has_function_privilege('anon', 'public._aplicar_credito_pagos(bigint,bigint,bigint[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._aplicar_credito_pagos(bigint,bigint,bigint[])', 'EXECUTE')
     OR has_function_privilege('anon', 'public.aplicar_credito_cliente(bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.aplicar_credito_cliente(bigint,bigint)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 _aplicar_credito_pagos o aplicar_credito_cliente tienen EXECUTE para anon o authenticated'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · K1 N1 C1 C2 R1 R2 A1 D1 % CC-A L1', array_to_string(v_hechos, ' ');
 END;
END
$ensayo$;
