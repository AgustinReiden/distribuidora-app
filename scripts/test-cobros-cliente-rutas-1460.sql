-- Ensayo de la migración que hace que cambiar el cliente de un pedido e imputar un crédito tomen las boletas, las rutas
-- y los pagos antes que el cliente (#1460, C1 y C7).
--
-- Los 40P01 los mide el arnés (scripts/concurrencia, `t15`), porque hacen falta tres sesiones. Acá se prueba, en una
-- sola, que los dos caminos siguen haciendo lo mismo: qué se mueve, qué se imputa, a qué boleta y el saldo. Los casos
-- E pasan con y sin la migración; L falla sin ella:
--
--   E1 · Pasar X (de C1, cobrada 100) a C2 con 'pedido_nuevo' y un total de 80, con W de C2 impaga: el pedido nuevo
--        queda 80/80, los 20 de excedente van a W, y C2 no queda con créditos. X queda cancelada y sin pagos.
--   E2 · Lo mismo con 'cliente_original': los 100 quedan a favor de C1, el pedido nuevo nace impago y W no cobra nada.
--   E3 · Pasar a C2 una X sin cobrar, con un crédito de 30 en C2 y W impaga: el pedido nuevo nace sin cobros, y el
--        crédito, que estaba suelto, va a W al crearlo (FIFO, #1469). No se mueve ningún otro pago.
--   E4 · Imputar entero un crédito de 30 a Y: Y queda con 30 cobrados y el crédito apunta a Y.
--   E5 · Imputar 10 de un crédito de 30 a Y: un pedazo de 10 en Y (con su raíz y su padre) y 20 a favor.
--   En los cinco, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos (el predicado de CC-A) para cada
--   cliente que se toca, y las violaciones de CC-A de auditoria_integridad() en toda la base no cambian.
--   L1 · cambiar_cliente_pedido toma las boletas, los recorridos y los pagos por id antes de su lock de X, e
--        imputar_credito_a_pedido_impl toma los recorridos de la boleta entre su lock de la boleta y el del crédito.
--        Ninguna de las dos cambió sus EXECUTE.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo,
-- sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1460', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 1, 1000, 1, p_suc)
  RETURNING id;
$fn$;

-- Una boleta de p_monto pesos (p_monto unidades de $1), del día p_fecha.
CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_prod bigint, p_monto int, p_fecha date)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_monto, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_monto, 'precio_unitario', 1)),
    'ensayo 1460', 'efectivo', 'pendiente', p_fecha);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Pasar la boleta al cliente p_cli con p_monto unidades de $1 del mismo producto.
CREATE OR REPLACE FUNCTION pg_temp.t_cambiar(p_ped bigint, p_cli bigint, p_admin uuid, p_prod bigint, p_monto int, p_destino text)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.cambiar_cliente_pedido(
    p_ped, p_cli, p_admin,
    jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_monto, 'precio_unitario', 1)),
    p_monto, NULL, 0, 'ensayo 1460', p_destino);
$fn$;

-- Un crédito (pago a cuenta sin boleta).
CREATE OR REPLACE FUNCTION pg_temp.t_credito(p_cli bigint, p_suc bigint, p_adm uuid, p_monto numeric, p_fecha date)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
  VALUES (p_cli, NULL, p_suc, p_monto, 'efectivo', p_fecha, p_adm, '[saldo a favor]', true)
  RETURNING id;
$fn$;

-- '' si el saldo del cliente cierra contra sus boletas y sus créditos (el predicado de CC-A de
-- auditoria_integridad(), para un cliente); si no, el detalle.
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

-- Las violaciones de CC-A de toda la base, de auditoria_integridad().
CREATE OR REPLACE FUNCTION pg_temp.t_cca()
RETURNS int LANGUAGE sql AS $fn$
  SELECT (e->>'violaciones')::int
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' = 'CC-A';
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
  v_w      bigint;
  v_y      bigint;
  v_n      bigint;
  v_c      bigint;
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

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1460');
  v_cca := pg_temp.t_cca();

  -- E1 · pasar X cobrada a C2 con 'pedido_nuevo' y excedente
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E1 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E1 C2');
    v_w := pg_temp.t_pedido(v_c2, v_adm, v_prod, 100, v_hoy - 1);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 80, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'excedente_a_favor')::numeric IS DISTINCT FROM 20::numeric
       OR (SELECT estado FROM pedidos WHERE id = v_x) IS DISTINCT FROM 'cancelado'
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_x)
       OR (SELECT cliente_id::text || '/' || total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n)
          IS DISTINCT FROM v_c2::text || '/80.00/80.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_w) IS DISTINCT FROM 20::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id IN (v_c1, v_c2) AND pedido_id IS NULL)
       OR (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_c2) IS DISTINCT FROM 100::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E1 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ460';
  EXCEPTION
    WHEN SQLSTATE 'ZZ460' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · lo mismo con 'cliente_original'
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E2 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E2 C2');
    v_w := pg_temp.t_pedido(v_c2, v_adm, v_prod, 100, v_hoy - 1);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 80, 'cliente_original');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT estado FROM pedidos WHERE id = v_x) IS DISTINCT FROM 'cancelado'
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n) IS DISTINCT FROM '80.00/0.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_w) IS DISTINCT FROM 0::numeric
       OR (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_c1 AND pedido_id IS NULL) IS DISTINCT FROM 100::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c2)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E2 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ460';
  EXCEPTION
    WHEN SQLSTATE 'ZZ460' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · pasar a C2 una X sin cobrar, con un crédito en C2
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E3 C1');
    v_c2 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E3 C2');
    v_w := pg_temp.t_pedido(v_c2, v_adm, v_prod, 100, v_hoy - 1);
    v_c := pg_temp.t_credito(v_c2, v_suc, v_adm, 30, v_hoy);
    v_x := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := pg_temp.t_cambiar(v_x, v_c2, v_adm, v_prod, 80, 'pedido_nuevo');
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    v_txt := pg_temp.t_saldo(v_c1) || pg_temp.t_saldo(v_c2);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'excedente_a_favor')::numeric IS DISTINCT FROM 0::numeric
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_n) IS DISTINCT FROM '80.00/0.00'
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_w
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_w) IS DISTINCT FROM 30::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_c1)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E3 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ460';
  EXCEPTION
    WHEN SQLSTATE 'ZZ460' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · imputar entero un crédito de 30 a Y
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E4');
    v_y := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy - 1);
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_j := public.imputar_credito_a_pedido_impl(v_c, v_y, NULL);
    v_txt := pg_temp.t_saldo(v_c1);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'monto_imputado')::numeric IS DISTINCT FROM 30::numeric
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_y
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 30::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E4 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ460';
  EXCEPTION
    WHEN SQLSTATE 'ZZ460' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E5 · imputar 10 de un crédito de 30 a Y
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1460 E5');
    v_y := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy - 1);
    v_c := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_j := public.imputar_credito_a_pedido_impl(v_c, v_y, 10);
    v_txt := pg_temp.t_saldo(v_c1);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (v_j->>'resto_a_favor')::numeric IS DISTINCT FROM 20::numeric
       OR (SELECT monto FROM pagos WHERE id = v_c AND pedido_id IS NULL) IS DISTINCT FROM 20::numeric
       OR (SELECT count(*) FROM pagos WHERE pedido_id = v_y AND monto = 10 AND pago_origen_id = v_c AND pago_padre_id = v_c) <> 1
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 10::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E5 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ460';
  EXCEPTION
    WHEN SQLSTATE 'ZZ460' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los pre-bloqueos y los EXECUTE. Es lo único que falla sin la migración.
  v_txt := (SELECT prosrc FROM pg_proc
             WHERE oid = 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)'::regprocedure);
  -- #1473 (tarjeta 6 de #1477): el pre-bloqueo de la 459 pasó al orden global, con los productos y las promos
  -- entre las boletas y las rutas, y los clientes al final. Las boletas, las rutas y los pagos siguen antes que X.
  IF v_txt !~ 'WHERE id = ANY\(v_alcanza\)\s+AND sucursal_id = v_sucursal\s+ORDER BY id\s+FOR UPDATE;.*rp.pedido_id = ANY\(v_alcanza\)\)\s+ORDER BY id\s+FOR NO KEY UPDATE;.*AND pg.pedido_id IS NULL\)\s+ORDER BY id\s+FOR UPDATE;.*SELECT \* INTO v_pedido FROM pedidos WHERE id = p_pedido_id' THEN
    v_fallas := v_fallas || 'L1 cambiar_cliente_pedido no toma las boletas, las rutas y los pagos antes que X'::text;
  END IF;
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)'::regprocedure);
  IF v_txt !~ 'PERFORM 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id FOR UPDATE;.*FROM recorridos\s+WHERE id IN \(SELECT rp.recorrido_id.*ORDER BY id\s+FOR NO KEY UPDATE;\s+SELECT id, cliente_id, pedido_id, monto' THEN
    v_fallas := v_fallas || 'L1 imputar_credito_a_pedido_impl no toma las rutas antes que el crédito'::text;
  END IF;
  IF has_function_privilege('anon', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 los EXECUTE de cambiar_cliente_pedido o de imputar_credito_a_pedido_impl cambiaron'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · E1 E2 E3 E4 E5 L1';
 END;
END
$ensayo$;
