-- Ensayo de la migración que deja en el cliente original lo que la boleta trajo de su saldo a favor
-- o de un FIFO de su ficha cuando se cambia el cliente con 'pedido_nuevo' (#1489, tarjeta 12 de #1477).
--
-- C1 es el cliente original de la boleta X; C2, el nuevo. Los casos E1 a E4 fallan sin la migración
-- (la plata de C1 viaja a C2); E5, E6 y L1 pasan con y sin ella:
--
--   E1 · C1 tiene un crédito de 400 y X (1000) lo absorbe al nacer (463c). Pasar X a C2 con 'pedido_nuevo':
--        el pago vuelve a ser crédito suelto de C1 (el mismo pago, sin la marca), el pedido nuevo nace sin
--        cobros y la respuesta dice a_favor_cliente_original = 400.
--   E2 · Lo mismo con un crédito de 1500: X absorbe un pedazo de 1000 y quedan 500 sueltos. El pedazo
--        vuelve suelto a C1 con su pago_origen_id y su pago_padre_id, y C1 vuelve a tener 1500 a favor.
--   E3 · C1 con 400 absorbidos en X y un cobro de boleta de 300; C2 con un crédito de 50. El cobro de 300
--        viaja al pedido nuevo y a C2, el pedido nuevo absorbe los 50 de C2 (350 cobrados) y los 400 vuelven
--        a C1. C2 no queda con créditos.
--   E4 · Un pago a cuenta de 200 por el FIFO de la ficha de C1 cae en X (a_cuenta): no viaja, queda suelto
--        en C1.
--   E5 · 'cliente_original' con 400 absorbidos y 300 cobrados: C1 queda con sus dos pagos sueltos (700, sin
--        duplicar ninguno) y el pedido nuevo nace sin cobros.
--   E6 · Testigo: sólo un cobro de boleta de 300, 'pedido_nuevo': viaja entero y a_favor_cliente_original = 0.
--   En E1 a E6, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos (el predicado de CC-A) para
--   C1 y C2, X queda cancelada y sin pagos, y las violaciones de CC-A de auditoria_integridad() no cambian.
--   L1 · Los EXECUTE de cambiar_cliente_pedido no cambiaron (authenticated sí, anon no).
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una
-- excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado
-- detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar
-- 'ENSAYO FALLÓ', por E1 a E4.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1489', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 10, 10000, 1, p_suc)
  RETURNING id;
$fn$;

-- Una boleta de p_cant unidades a 10, de hoy.
CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_cant int, p_fecha date)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant * 10, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 10)),
    'ensayo 1489', 'efectivo', 'pendiente', p_fecha, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Pasar la boleta al cliente p_cli con p_cant unidades a 10.
CREATE OR REPLACE FUNCTION pg_temp.t_cambiar(p_ped bigint, p_cli bigint, p_admin uuid, p_prod bigint, p_cant int, p_destino text)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.cambiar_cliente_pedido(
    p_ped, p_cli, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 10)),
    p_cant * 10, NULL, 0, 'ensayo 1489', p_destino);
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

CREATE OR REPLACE FUNCTION pg_temp.t_cca()
RETURNS int LANGUAGE sql AS $fn$
  SELECT (e->>'violaciones')::int
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' = 'CC-A';
$fn$;

-- Los créditos sueltos de un cliente.
CREATE OR REPLACE FUNCTION pg_temp.t_favor(p_cli bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE(sum(monto), 0) FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL;
$fn$;

-- Lo común de E1 a E6: saldos, CC-A de la base y X cancelada sin pagos.
CREATE OR REPLACE FUNCTION pg_temp.t_comun(p_c1 bigint, p_c2 bigint, p_x bigint, p_cca int, p_j jsonb)
RETURNS text LANGUAGE sql AS $fn$
  SELECT pg_temp.t_saldo(p_c1) || pg_temp.t_saldo(p_c2)
      || CASE WHEN pg_temp.t_cca() IS DISTINCT FROM p_cca
              THEN format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), p_cca) ELSE '' END
      || CASE WHEN NOT COALESCE((p_j->>'success')::boolean, false) THEN ' sin success' ELSE '' END
      || CASE WHEN (SELECT estado FROM public.pedidos WHERE id = p_x) IS DISTINCT FROM 'cancelado'
              THEN ' X no quedó cancelada' ELSE '' END
      || CASE WHEN EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = p_x) THEN ' X quedó con pagos' ELSE '' END;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_prod   bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_x      bigint;
  v_n      bigint;
  v_k      bigint;
  v_p      bigint;
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

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1489');
  v_cca := pg_temp.t_cca();

  -- E1 · el crédito absorbido entero vuelve a C1
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E1 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E1 C2');
    v_k := pg_temp.t_credito(v_c1, v_suc, v_adm, 400, v_hoy);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    IF (SELECT pedido_id::text || '/' || de_saldo_a_favor::text FROM pagos WHERE id = v_k)
       IS DISTINCT FROM v_x::text || '/true' THEN
      RAISE EXCEPTION 'precondición: X no absorbió el crédito de C1';
    END IF;
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 100, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_comun(v_c1, v_c2, v_x, v_cca, v_j);
    IF (SELECT cliente_id::text || '/' || COALESCE(pedido_id::text, 'suelto') || '/' || monto::text || '/'
               || de_saldo_a_favor::text FROM pagos WHERE id = v_k)
       IS DISTINCT FROM v_c1::text || '/suelto/400.00/false'
       OR (SELECT cliente_id::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n)
          IS DISTINCT FROM v_c2::text || '/0.00'
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c2)
       OR (v_j->>'a_favor_cliente_original')::numeric IS DISTINCT FROM 400::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E1 dio %s; pago K: %s%s', v_j,
        (SELECT row(cliente_id, pedido_id, monto, de_saldo_a_favor)::text FROM pagos WHERE id = v_k), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ489';
  EXCEPTION
    WHEN SQLSTATE 'ZZ489' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · un pedazo absorbido vuelve a C1 con su origen y su padre
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E2 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E2 C2');
    v_k := pg_temp.t_credito(v_c1, v_suc, v_adm, 1500, v_hoy);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    SELECT id INTO v_p FROM pagos WHERE pedido_id = v_x AND pago_padre_id = v_k AND de_saldo_a_favor AND monto = 1000;
    IF v_p IS NULL OR (SELECT monto FROM pagos WHERE id = v_k AND pedido_id IS NULL) IS DISTINCT FROM 500::numeric THEN
      RAISE EXCEPTION 'precondición: X no absorbió un pedazo de 1000 del crédito de C1';
    END IF;
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 100, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_comun(v_c1, v_c2, v_x, v_cca, v_j);
    IF (SELECT cliente_id::text || '/' || COALESCE(pedido_id::text, 'suelto') || '/' || monto::text || '/'
               || pago_origen_id::text || '/' || pago_padre_id::text || '/' || de_saldo_a_favor::text
          FROM pagos WHERE id = v_p)
       IS DISTINCT FROM format('%s/suelto/1000.00/%s/%s/false', v_c1, v_k, v_k)
       OR pg_temp.t_favor(v_c1) IS DISTINCT FROM 1500::numeric
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_n) IS DISTINCT FROM 0::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c2)
       OR (v_j->>'a_favor_cliente_original')::numeric IS DISTINCT FROM 1000::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E2 dio %s; a favor de C1 %s%s', v_j, pg_temp.t_favor(v_c1), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ489';
  EXCEPTION
    WHEN SQLSTATE 'ZZ489' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · viaja sólo el cobro de la boleta; el pedido nuevo absorbe el crédito de C2
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E3 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E3 C2');
    v_k := pg_temp.t_credito(v_c1, v_suc, v_adm, 400, v_hoy);
    PERFORM pg_temp.t_credito(v_c2, v_suc, v_adm, 50, v_hoy);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":300,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    IF (SELECT monto_pagado FROM pedidos WHERE id = v_x) IS DISTINCT FROM 700::numeric THEN
      RAISE EXCEPTION 'precondición: X no quedó con 700 cobrados (400 absorbidos y 300 de la boleta)';
    END IF;
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 100, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_comun(v_c1, v_c2, v_x, v_cca, v_j);
    IF (SELECT cliente_id::text || '/' || COALESCE(pedido_id::text, 'suelto') FROM pagos WHERE id = v_k)
       IS DISTINCT FROM v_c1::text || '/suelto'
       OR pg_temp.t_favor(v_c1) IS DISTINCT FROM 400::numeric
       OR (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_c1) IS DISTINCT FROM 400::numeric
       OR (SELECT cliente_id::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n)
          IS DISTINCT FROM v_c2::text || '/350.00'
       OR (SELECT count(*) FROM pagos WHERE pedido_id = v_n AND cliente_id = v_c2 AND monto = 300
                                         AND NOT de_saldo_a_favor) <> 1
       OR pg_temp.t_favor(v_c2) IS DISTINCT FROM 0::numeric
       OR (v_j->>'a_favor_cliente_original')::numeric IS DISTINCT FROM 400::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E3 dio %s; a favor C1 %s, C2 %s, nuevo %s%s', v_j, pg_temp.t_favor(v_c1),
        pg_temp.t_favor(v_c2), (SELECT monto_pagado FROM pedidos WHERE id = v_n), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ489';
  EXCEPTION
    WHEN SQLSTATE 'ZZ489' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · un pago a cuenta del FIFO de la ficha que cayó en X no viaja
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E4 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E4 C2');
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pago_cliente_fifo_impl(v_c1, 200, 'efectivo', v_hoy);
    SELECT id INTO v_p FROM pagos WHERE pedido_id = v_x AND a_cuenta AND NOT de_saldo_a_favor AND monto = 200;
    IF v_p IS NULL THEN
      RAISE EXCEPTION 'precondición: el FIFO no cargó los 200 en X (%)', v_j;
    END IF;
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 100, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_comun(v_c1, v_c2, v_x, v_cca, v_j);
    IF (SELECT cliente_id::text || '/' || COALESCE(pedido_id::text, 'suelto') || '/' || monto::text FROM pagos WHERE id = v_p)
       IS DISTINCT FROM v_c1::text || '/suelto/200.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_n) IS DISTINCT FROM 0::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c2)
       OR (v_j->>'a_favor_cliente_original')::numeric IS DISTINCT FROM 200::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E4 dio %s; pago FIFO: %s%s', v_j,
        (SELECT row(cliente_id, pedido_id, monto)::text FROM pagos WHERE id = v_p), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ489';
  EXCEPTION
    WHEN SQLSTATE 'ZZ489' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E5 · 'cliente_original': lo absorbido y lo cobrado quedan a favor de C1, una vez cada uno
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E5 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E5 C2');
    v_k := pg_temp.t_credito(v_c1, v_suc, v_adm, 400, v_hoy);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":300,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 100, 'cliente_original');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_comun(v_c1, v_c2, v_x, v_cca, v_j);
    IF (SELECT count(*)::text || '/' || sum(monto)::text FROM pagos WHERE cliente_id = v_c1)
       IS DISTINCT FROM '2/700.00'
       OR pg_temp.t_favor(v_c1) IS DISTINCT FROM 700::numeric
       OR (SELECT COALESCE(pedido_id::text, 'suelto') || '/' || de_saldo_a_favor::text FROM pagos WHERE id = v_k)
          IS DISTINCT FROM 'suelto/false'
       OR (SELECT saldo_cuenta FROM clientes WHERE id = v_c1) IS DISTINCT FROM -700::numeric
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_n) IS DISTINCT FROM 0::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c2)
       OR COALESCE((v_j->>'a_favor_cliente_original')::numeric, 0) <> 0
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E5 dio %s; a favor C1 %s, saldo C1 %s%s', v_j, pg_temp.t_favor(v_c1),
        (SELECT saldo_cuenta FROM clientes WHERE id = v_c1), v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ489';
  EXCEPTION
    WHEN SQLSTATE 'ZZ489' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E6 · testigo: el cobro de la boleta viaja entero
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E6 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1489 E6 C2');
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":300,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 100, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_comun(v_c1, v_c2, v_x, v_cca, v_j);
    IF (SELECT cliente_id::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n)
       IS DISTINCT FROM v_c2::text || '/300.00'
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c1)
       OR pg_temp.t_favor(v_c2) IS DISTINCT FROM 0::numeric
       OR COALESCE((v_j->>'a_favor_cliente_original')::numeric, 0) <> 0
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E6 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ489';
  EXCEPTION
    WHEN SQLSTATE 'ZZ489' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E6 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los EXECUTE no cambiaron
  IF has_function_privilege('anon', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 los EXECUTE de cambiar_cliente_pedido cambiaron'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · E1 E2 E3 E4 E5 E6 L1';
 END;
END
$ensayo$;
