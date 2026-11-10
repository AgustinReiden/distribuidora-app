-- Ensayo de la migración 479: el crédito de una cancelación o de una NC se aplica a las boletas abiertas, anular una
-- NC aplicada la desimputa, y el saldo a favor de una boleta se quita en vez de borrarse (#1512: COB-1, COB-2 y COB-3;
-- #1520: VTA-10; tarjeta 1 de #1524).
--
--   K1 · Una boleta W de 100 impaga y una X de 60 cobrada entera: cancelar X le pasa los 60 a W (60/100), con la marca
--        de_saldo_a_favor, y el cliente no queda con crédito suelto. La respuesta trae credito_aplicado 60.
--   K2 · W de 30 y X de 50 cobrada: cancelar X salda W (30/30) con un pedazo y quedan 20 sueltos. credito_aplicado 30.
--   K3 · Igual que K1 con p_tipo = 'cambio_de_cliente': la cancelación no aplica nada (lo hace cambiar_cliente_pedido) y
--        los 60 quedan sueltos. Sin cobros, cancelar no aplica nada (credito_aplicado 0).
--   N1 · Una boleta Q entregada e impaga de 100 y una NC de 30: el crédito baja Q (30/100) con la marca y el
--        nota_credito_id, y no queda nada suelto. La respuesta trae credito_aplicado_pedido 30 y otras 0.
--   N2 · Q de 100 cobrada 80 y otra boleta W de 50 impaga: una NC de 60 salda Q con un pedazo de 20 (raíz y padre en el
--        crédito de la NC) y los 40 que sobran van a W (40/50). aplicado_pedido 20, otras 40, disponible 0.
--   N3 · Q cobrada entera y sin otras boletas: la NC de 30 queda suelta (credito_disponible 30).
--   A1 · Anular la NC de N2: se borran todos sus pagos, Q vuelve a 80/100 y W a 0/50. La respuesta trae
--        credito_desimputado 60 y los dos pedidos.
--   D1 · Un crédito de 50 y una boleta nueva de 30 que absorbe un pedazo: desimputar_pago lo quita (la boleta vuelve a
--        0/30, el crédito suelto vuelve a 50), saldo_cuenta no cambia, y el pago no se reaplica solo. El reintento
--        contesta ya_estaba_suelto. Desimputar un cobro, o con la boleta equivocada, da 22023.
--   D2 · Como authenticated (admin), el DELETE REST de un pago con de_saldo_a_favor da 42501 con el texto de qué
--        hacer, y el de un cobro de la boleta sigue andando.
--   T1 · Con la política en modo cargo (mínimo 1000, envío 150), una boleta ZZ de 40 nace con envío 150; pasada a VB
--        queda en 0 y 'no_aplica', y de vuelta a ZZ recupera 150 y 'cobrado', con total 190, total_real 40 y el envío
--        dentro de total_neto. Una de 1200 ida y vuelta a FC queda en 0 y 'gratis'.
--   T2 · ZZ → VB con un pago: el mensaje dice anulá los cobros y quitá el saldo a favor.
--   En K, N, A y D, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos (el predicado de CC-A) para cada
--   cliente que se toca, y las violaciones de CC-A de auditoria_integridad() en toda la base no cambian.
--   L1 · Los helpers y la función del trigger no tienen EXECUTE para anon ni authenticated; desimputar_pago lo tiene
--        para authenticated y no para anon; el trigger está prendido.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. La migración ya está aplicada: se corre solo.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1512', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, 100000, 1, p_suc)
  RETURNING id;
$fn$;

-- El id de una boleta nueva de p_monto pesos (p_monto unidades de $1), del día p_fecha.
CREATE OR REPLACE FUNCTION pg_temp.t_alta(p_cli bigint, p_admin uuid, p_prod bigint, p_monto int, p_fecha date,
                                          p_tipo text DEFAULT 'ZZ')
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_monto, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_monto, 'precio_unitario', 1)),
    'ensayo 1512', 'efectivo', 'pendiente', p_fecha, p_tipo);
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

-- Los ítems de una NC por p_cant unidades de la única línea de la boleta.
CREATE OR REPLACE FUNCTION pg_temp.t_items_nc(p_ped bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('pedido_item_id', min(id), 'cantidad', p_cant))
    FROM public.pedido_items WHERE pedido_id = p_ped;
$fn$;

-- La respuesta de la NC, o una excepción.
CREATE OR REPLACE FUNCTION pg_temp.t_nc(p_ped bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.crear_nota_credito_venta(p_ped, (SELECT cliente_id FROM public.pedidos WHERE id = p_ped),
                                         pg_temp.t_items_nc(p_ped, p_cant), 'producto_vencido', 'ensayo 1512', NULL);
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
  v_w      bigint;
  v_x      bigint;
  v_q      bigint;
  v_p      bigint;
  v_c      bigint;
  v_nc     bigint;
  v_saldo  numeric;
  v_txt    text;
  v_j      jsonb;
  v_fallas text[] := '{}';
  v_cca    int;
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

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1512');
  v_cca := pg_temp.t_cca();

  -- K1 · cancelar una boleta cobrada le pasa lo cobrado a la otra abierta
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 K1');
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 2);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 60, v_hoy);
    v_p := pg_temp.t_cobro(v_x, 60);
    v_j := public.cancelar_pedido_con_stock(v_x, 'ensayo 1512', v_adm, 'error_de_carga');
    v_txt := pg_temp.t_saldo(v_cli);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'credito_aplicado')::numeric IS DISTINCT FROM 60
       OR pg_temp.t_estado(v_w) <> '60.00/100.00'
       OR pg_temp.t_suelto(v_cli) <> 0
       OR (SELECT pedido_id FROM pagos WHERE id = v_p) IS DISTINCT FROM v_w
       OR NOT (SELECT de_saldo_a_favor FROM pagos WHERE id = v_p)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('K1 dio %s; W %s, suelto %s, pago en %s%s', v_j, pg_temp.t_estado(v_w),
                                     pg_temp.t_suelto(v_cli), (SELECT pedido_id FROM pagos WHERE id = v_p), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('K1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- K2 · con excedente: salda la otra con un pedazo y el resto queda suelto
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 K2');
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 30, v_hoy - 2);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 50, v_hoy);
    v_p := pg_temp.t_cobro(v_x, 50);
    v_j := public.cancelar_pedido_con_stock(v_x, 'ensayo 1512', v_adm, 'error_de_carga');
    v_txt := pg_temp.t_saldo(v_cli);
    IF (v_j->>'credito_aplicado')::numeric IS DISTINCT FROM 30
       OR pg_temp.t_estado(v_w) <> '30.00/30.00'
       OR pg_temp.t_suelto(v_cli) <> 20
       OR NOT EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_w AND pago_padre_id = v_p AND pago_origen_id = v_p
                        AND monto = 30 AND de_saldo_a_favor)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('K2 dio %s; W %s, suelto %s%s', v_j, pg_temp.t_estado(v_w), pg_temp.t_suelto(v_cli), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('K2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- K3 · en un cambio de cliente la cancelación no aplica nada; sin cobros, tampoco
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 K3');
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 2);
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 60, v_hoy);
    v_p := pg_temp.t_cobro(v_x, 60);
    v_j := public.cancelar_pedido_con_stock(v_x, 'ensayo 1512', v_adm, 'cambio_de_cliente');
    IF (v_j->>'credito_aplicado')::numeric IS DISTINCT FROM 0
       OR pg_temp.t_estado(v_w) <> '0.00/100.00'
       OR pg_temp.t_suelto(v_cli) <> 60
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('K3 cambio de cliente dio %s; W %s, suelto %s%s', v_j, pg_temp.t_estado(v_w),
                                     pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli));
    END IF;
    -- sin cobros (el crédito de 60 sigue suelto: no lo aplica nadie)
    v_x := pg_temp.t_alta(v_cli, v_adm, v_prod, 10, v_hoy);
    v_j := public.cancelar_pedido_con_stock(v_x, 'ensayo 1512', v_adm, 'error_de_carga');
    IF (v_j->>'credito_aplicado')::numeric IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('K3 sin cobros dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('K3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N1 · la NC baja su propia boleta impaga
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 N1');
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy);
    PERFORM pg_temp.t_entregar(v_q);
    v_j := pg_temp.t_nc(v_q, 30);
    v_nc := (v_j->>'nota_credito_id')::bigint;
    IF (v_j->>'credito_aplicado_pedido')::numeric IS DISTINCT FROM 30
       OR (v_j->>'credito_aplicado_otras')::numeric IS DISTINCT FROM 0
       OR (v_j->>'credito_disponible')::numeric IS DISTINCT FROM 0
       OR pg_temp.t_estado(v_q) <> '30.00/100.00'
       OR pg_temp.t_suelto(v_cli) <> 0
       OR NOT EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_q AND nota_credito_id = v_nc AND monto = 30
                         AND de_saldo_a_favor AND forma_pago = 'nota_credito')
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('N1 dio %s; Q %s, suelto %s%s', v_j, pg_temp.t_estado(v_q),
                                     pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N2 y A1 · lo que sobra va FIFO a otra boleta; anular la NC lo desimputa todo
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 N2');
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy - 3);
    PERFORM pg_temp.t_entregar(v_q);
    PERFORM pg_temp.t_cobro(v_q, 80);
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 50, v_hoy);
    v_j := pg_temp.t_nc(v_q, 60);
    v_nc := (v_j->>'nota_credito_id')::bigint;
    IF (v_j->>'credito_aplicado_pedido')::numeric IS DISTINCT FROM 20
       OR (v_j->>'credito_aplicado_otras')::numeric IS DISTINCT FROM 40
       OR (v_j->>'credito_disponible')::numeric IS DISTINCT FROM 0
       OR pg_temp.t_estado(v_q) <> '100.00/100.00'
       OR pg_temp.t_estado(v_w) <> '40.00/50.00'
       OR NOT EXISTS (SELECT 1 FROM pagos pz JOIN pagos r ON r.id = pz.pago_origen_id
                       WHERE pz.pedido_id = v_q AND pz.nota_credito_id = v_nc AND pz.monto = 20
                         AND pz.pago_padre_id = r.id AND r.nota_credito_id = v_nc AND pz.de_saldo_a_favor)
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('N2 dio %s; Q %s, W %s%s', v_j, pg_temp.t_estado(v_q),
                                     pg_temp.t_estado(v_w), pg_temp.t_saldo(v_cli));
    END IF;

    v_saldo := (SELECT saldo_cuenta FROM clientes WHERE id = v_cli);
    v_j := public.anular_nota_credito_venta(v_nc, 'ensayo 1512');
    IF (v_j->>'credito_desimputado')::numeric IS DISTINCT FROM 60
       OR (v_j->>'credito_revertido')::numeric IS DISTINCT FROM 60
       OR NOT (v_j->'pedidos_desimputados' @> to_jsonb(ARRAY[v_q, v_w]))
       OR EXISTS (SELECT 1 FROM pagos WHERE nota_credito_id = v_nc)
       OR NOT (SELECT anulada FROM notas_credito_venta WHERE id = v_nc)
       OR pg_temp.t_estado(v_q) <> '80.00/100.00'
       OR pg_temp.t_estado(v_w) <> '0.00/50.00'
       OR (SELECT saldo_cuenta FROM clientes WHERE id = v_cli) <> v_saldo + 60
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('A1 dio %s; Q %s, W %s%s', v_j, pg_temp.t_estado(v_q),
                                     pg_temp.t_estado(v_w), pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N2/A1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- N3 · sin nada que deba, la NC queda suelta
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 N3');
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 100, v_hoy);
    PERFORM pg_temp.t_entregar(v_q);
    PERFORM pg_temp.t_cobro(v_q, 100);
    v_j := pg_temp.t_nc(v_q, 30);
    IF (v_j->>'credito_aplicado_pedido')::numeric IS DISTINCT FROM 0
       OR (v_j->>'credito_disponible')::numeric IS DISTINCT FROM 30
       OR pg_temp.t_suelto(v_cli) <> 30
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('N3 dio %s%s', v_j, pg_temp.t_saldo(v_cli));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- D1 · quitar de la boleta el saldo a favor absorbido
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 D1');
    v_c := pg_temp.t_credito(v_cli, v_suc, v_adm, 50, v_hoy);
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 30, v_hoy);
    SELECT id INTO v_p FROM pagos WHERE pedido_id = v_q AND de_saldo_a_favor;
    v_saldo := (SELECT saldo_cuenta FROM clientes WHERE id = v_cli);
    IF v_p IS NULL OR pg_temp.t_estado(v_q) <> '30.00/30.00' THEN
      v_fallas := v_fallas || format('D1 la boleta no absorbió el crédito: %s', pg_temp.t_estado(v_q));
    END IF;
    v_j := public.desimputar_pago(v_p, v_q);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'ya_estaba_suelto')::boolean
       OR (v_j->>'saldo_a_favor')::numeric IS DISTINCT FROM 50
       OR pg_temp.t_estado(v_q) <> '0.00/30.00'
       OR pg_temp.t_suelto(v_cli) <> 50
       OR (SELECT de_saldo_a_favor FROM pagos WHERE id = v_p)
       OR (SELECT notas FROM pagos WHERE id = v_p) NOT LIKE '%[quitado del pedido #' || v_q || '] [saldo a favor]'
       OR (SELECT saldo_cuenta FROM clientes WHERE id = v_cli) IS DISTINCT FROM v_saldo
       OR pg_temp.t_saldo(v_cli) <> '' THEN
      v_fallas := v_fallas || format('D1 dio %s; Q %s, suelto %s%s', v_j, pg_temp.t_estado(v_q),
                                     pg_temp.t_suelto(v_cli), pg_temp.t_saldo(v_cli));
    END IF;
    v_j := public.desimputar_pago(v_p, v_q);
    IF NOT COALESCE((v_j->>'ya_estaba_suelto')::boolean, false) THEN
      v_fallas := v_fallas || format('D1 el reintento dio %s', v_j);
    END IF;
    -- un cobro de la boleta no se quita
    v_c := pg_temp.t_cobro(v_q, 10);
    BEGIN
      v_j := public.desimputar_pago(v_c, v_q);
      v_fallas := v_fallas || format('D1 quitó un cobro: %s', v_j);
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;
    -- con la boleta equivocada
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 20, v_hoy);
    SELECT id INTO v_p FROM pagos WHERE pedido_id = v_w AND de_saldo_a_favor LIMIT 1;
    BEGIN
      v_j := public.desimputar_pago(v_p, v_q);
      v_fallas := v_fallas || format('D1 quitó con la boleta equivocada: %s', v_j);
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- D2 · el DELETE REST del saldo a favor aplicado se rechaza; el de un cobro, no
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 D2');
    v_c := pg_temp.t_credito(v_cli, v_suc, v_adm, 50, v_hoy);
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 30, v_hoy);
    SELECT id INTO v_p FROM pagos WHERE pedido_id = v_q AND de_saldo_a_favor;
    v_w := pg_temp.t_alta(v_cli, v_adm, v_prod, 40, v_hoy);
    v_c := pg_temp.t_cobro(v_w, 15);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      DELETE FROM pagos WHERE id = v_p;
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || 'D2 el DELETE REST borró el saldo a favor aplicado'::text;
    EXCEPTION WHEN SQLSTATE '42501' THEN
      IF SQLERRM NOT LIKE '%Quitalo de la boleta%' THEN
        v_fallas := v_fallas || format('D2 el rechazo no dice qué hacer: %s', SQLERRM);
      END IF;
    END;
    EXECUTE 'SET LOCAL ROLE authenticated';
    DELETE FROM pagos WHERE id = v_c;
    EXECUTE 'RESET ROLE';
    IF EXISTS (SELECT 1 FROM pagos WHERE id = v_c) OR pg_temp.t_estado(v_w) <> '20.00/40.00' THEN
      v_fallas := v_fallas || format('D2 el DELETE REST de un cobro no anduvo: W %s', pg_temp.t_estado(v_w));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- T1 · ZZ → VB → ZZ recupera el envío, calculado como en el alta
  BEGIN
    -- El GUC del ensayo también apaga el envío en pedido_cargo_envio: acá, no.
    PERFORM set_config('app.omitir_minimo_pedido', '', true);
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 T1');
    UPDATE clientes SET tipo_factura_default = 'VB' WHERE id = v_cli;
    UPDATE politicas_comerciales
       SET modo_minimo_pedido = 'cargo', monto_minimo_pedido = 1000, cargo_envio_pedido = 150
     WHERE sucursal_id = v_suc;
    IF NOT FOUND THEN
      INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, cargo_envio_pedido)
      VALUES (v_suc, 'cargo', 1000, 150);
    END IF;
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 40, v_hoy);
    IF (SELECT row(cargo_envio, cargo_envio_estado)::text FROM pedidos WHERE id = v_q) <> '(150.00,cobrado)' THEN
      v_fallas := v_fallas || format('T1 el alta no cobró el envío: %s',
        (SELECT row(cargo_envio, cargo_envio_estado)::text FROM pedidos WHERE id = v_q));
    END IF;
    v_j := public.cambiar_tipo_factura_pedido(v_q, 'VB', v_adm);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT row(cargo_envio, cargo_envio_estado)::text FROM pedidos WHERE id = v_q) <> '(0.00,no_aplica)' THEN
      v_fallas := v_fallas || format('T1 ZZ → VB dio %s', v_j);
    END IF;
    v_j := public.cambiar_tipo_factura_pedido(v_q, 'ZZ', v_adm);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'cargo_envio')::numeric IS DISTINCT FROM 150
       OR (v_j->>'mensaje') NOT LIKE '%Incluye el envío%'
       OR (SELECT row(cargo_envio, cargo_envio_estado, total, total_real)::text FROM pedidos WHERE id = v_q)
          <> '(150.00,cobrado,190.00,40.00)'
       OR (SELECT p.total_neto - (SELECT sum(i.cantidad * i.neto_unitario) FROM pedido_items i WHERE i.pedido_id = p.id)
             FROM pedidos p WHERE p.id = v_q) <> 150 THEN
      v_fallas := v_fallas || format('T1 VB → ZZ debajo del mínimo dio %s; pedido %s', v_j,
        (SELECT row(cargo_envio, cargo_envio_estado, total, total_real, total_neto)::text FROM pedidos WHERE id = v_q));
    END IF;
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 1200, v_hoy);
    PERFORM public.cambiar_tipo_factura_pedido(v_q, 'VB', v_adm);
    v_j := public.cambiar_tipo_factura_pedido(v_q, 'FC', v_adm);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'cargo_envio')::numeric IS DISTINCT FROM 0
       OR (SELECT row(cargo_envio, cargo_envio_estado, total)::text FROM pedidos WHERE id = v_q)
          <> '(0.00,gratis,1200.00)' THEN
      v_fallas := v_fallas || format('T1 VB → FC arriba del mínimo dio %s; pedido %s', v_j,
        (SELECT row(cargo_envio, cargo_envio_estado, total)::text FROM pedidos WHERE id = v_q));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('T1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- T2 · ZZ → VB con un pago: el mensaje dice qué hacer con cada cosa
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1512 T2');
    UPDATE clientes SET tipo_factura_default = 'VB' WHERE id = v_cli;
    v_q := pg_temp.t_alta(v_cli, v_adm, v_prod, 40, v_hoy);
    PERFORM pg_temp.t_cobro(v_q, 10);
    v_j := public.cambiar_tipo_factura_pedido(v_q, 'VB', v_adm);
    IF COALESCE((v_j->>'success')::boolean, true)
       OR v_j->>'error' NOT LIKE '%Anulá los cobros y quitá de la boleta el saldo a favor%' THEN
      v_fallas := v_fallas || format('T2 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ512';
  EXCEPTION
    WHEN SQLSTATE 'ZZ512' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('T2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
    v_fallas := v_fallas || format('CC-A pasó de %s a %s', v_cca, pg_temp.t_cca());
  END IF;

  -- L1 · EXECUTE y el trigger
  IF EXISTS (SELECT 1
               FROM unnest(ARRAY['public._credito_bloquea_boletas(bigint,bigint,bigint,numeric)',
                                 'public._credito_bloquea_rutas_y_creditos(bigint[],bigint,bigint,bigint)',
                                 'public.pagos_guard_borrar_credito_aplicado()',
                                 'public.crear_nota_credito_venta_impl(bigint,bigint,jsonb,text,text)']) f
              WHERE has_function_privilege('anon', f, 'EXECUTE')
                 OR has_function_privilege('authenticated', f, 'EXECUTE')) THEN
    v_fallas := v_fallas || 'L1 un helper, la función del trigger o el _impl tienen EXECUTE para anon o authenticated'::text;
  END IF;
  IF has_function_privilege('anon', 'public.desimputar_pago(bigint,bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.desimputar_pago(bigint,bigint)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 desimputar_pago no es de authenticated sin anon'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'trg_pagos_guard_credito_aplicado'
                    AND tgrelid = 'public.pagos'::regclass AND tgenabled = 'O') THEN
    v_fallas := v_fallas || 'L1 trg_pagos_guard_credito_aplicado no está prendido'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · K1 K2 K3 N1 N2 A1 N3 D1 D2 T1 T2 CC-A L1';
 END;
END
$ensayo$;
