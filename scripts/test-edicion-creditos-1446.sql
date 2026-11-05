-- Ensayo de la migración que hace que la edición que cambia el total tome las otras boletas y los créditos antes
-- que el cliente (#1446).
--
-- Los 40P01 los mide el arnés (scripts/concurrencia, `t10r` y `t13`), porque hacen falta tres sesiones. Acá se
-- prueba, en una sola, que editar sigue haciendo lo mismo: qué se recorta, qué se imputa, a qué boleta y el saldo.
-- Los casos E pasan con y sin la migración; L falla sin ella:
--
--   E1 · Subir el total de X con un crédito de 30 y una boleta Y más vieja: el crédito va a Y, X no cobra nada.
--   E2 · Bajar X cobrada (un cobro de 100) de 100 a 80, con el crédito y Y: el cobro se recorta a 80 y el crédito
--        va a Y.
--   E3 · Bajar X pagada con un crédito imputado (a cuenta) de 100 a 80, con Y: los 20 quedan a favor y van a Y.
--   E4 · Sin créditos ni excedente: subir X no mueve ningún pago.
--   En los cuatro, clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos (el predicado de CC-A), y las
--   violaciones de CC-A de auditoria_integridad() en toda la base no cambian. Como los E dan los mismos números con el
--   orden viejo (sin la migración) y con el nuevo, son la prueba de que el orden de los triggers no cambia qué se
--   calcula.
--   E5 · Una salvedad de 20 sobre X cobrada, con un crédito de 30 y una Y de id menor: X queda en 80 pagada, el
--        crédito va a Y. Anularla devuelve X a 100 con 80 cobrados, y el crédito sigue en Y.
--   E6 · Pasar X a vale blanco (el total va a costo, 60) con un crédito de 30 y una Y más vieja: X queda saldada sin
--        pagos y el crédito va a Y.
--   L1 · El trigger se llama trg_pedidos_reconciliar_pagos, corre antes que el de las rutas y el del saldo, ya no
--        está zzz_pedidos_reconciliar_pagos, y pedidos_reconciliar_pagos tiene el pre-bloqueo por id. Existe
--        _edicion_bloquea_boletas, sin EXECUTE para anon ni authenticated, y actualizar_pedido_items,
--        registrar_salvedad, anular_salvedad y cambiar_tipo_factura_pedido la llaman justo antes de su lock de la
--        boleta.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo,
-- sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por L1.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1446', p_suc)
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
    'ensayo 1446', 'efectivo', 'pendiente', p_fecha);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Editar la boleta a p_monto unidades de $1 del mismo producto.
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_ped bigint, p_admin uuid, p_prod bigint, p_monto int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.actualizar_pedido_items(
    p_ped, jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_monto, 'precio_unitario', 1)),
    p_admin, NULL, NULL);
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
              ELSE format(' saldo_cuenta=%s esperado=%s', c.saldo_cuenta, b.deuda - f.favor) END
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
  v_prod2  bigint;
  v_cli    bigint;
  v_x      bigint;
  v_y      bigint;
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

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1446');
  v_cca := pg_temp.t_cca();

  -- E1 · subir X con un crédito y una boleta más vieja
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1446 E1');
    v_x := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy);
    v_y := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy - 1);
    v_c := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy);
    v_j := pg_temp.t_editar(v_x, v_adm, v_prod, 120);
    v_txt := pg_temp.t_saldo(v_cli);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_y
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_x) IS DISTINCT FROM '120.00/0.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 30::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E1 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ446';
  EXCEPTION
    WHEN SQLSTATE 'ZZ446' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · bajar X cobrada, con un crédito y una boleta más vieja
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1446 E2');
    v_x := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy);
    v_y := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy - 1);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_c := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy);
    v_j := pg_temp.t_editar(v_x, v_adm, v_prod, 80);
    v_txt := pg_temp.t_saldo(v_cli);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_y
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_x) IS DISTINCT FROM '80.00/80.00'
       OR (SELECT string_agg(monto::text, ',' ORDER BY id) FROM pagos WHERE pedido_id = v_x) IS DISTINCT FROM '80.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 30::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_cli AND pedido_id IS NULL)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E2 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ446';
  EXCEPTION
    WHEN SQLSTATE 'ZZ446' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · bajar X pagada con un crédito imputado: lo que sobra queda a favor y va a la boleta más vieja
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1446 E3');
    v_x := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy);
    v_c := pg_temp.t_credito(v_cli, v_suc, v_adm, 100, v_hoy);
    v_j := public.imputar_credito_a_pedido_impl(v_c, v_x, NULL);
    v_y := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy - 1);
    v_j := pg_temp.t_editar(v_x, v_adm, v_prod, 80);
    v_txt := pg_temp.t_saldo(v_cli);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_x) IS DISTINCT FROM '80.00/80.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 20::numeric
       OR (SELECT count(*) FROM pagos WHERE pedido_id = v_y AND pago_origen_id = v_c) <> 1
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_cli AND pedido_id IS NULL)
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E3 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ446';
  EXCEPTION
    WHEN SQLSTATE 'ZZ446' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · sin créditos ni excedente
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1446 E4');
    v_x := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy);
    v_y := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy - 1);
    v_j := pg_temp.t_editar(v_x, v_adm, v_prod, 120);
    v_txt := pg_temp.t_saldo(v_cli);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF (SELECT total FROM pedidos WHERE id = v_x) IS DISTINCT FROM 120::numeric
       OR EXISTS (SELECT 1 FROM pagos WHERE cliente_id = v_cli)
       OR (SELECT saldo_cuenta FROM clientes WHERE id = v_cli) IS DISTINCT FROM 220::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E4 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ446';
  EXCEPTION
    WHEN SQLSTATE 'ZZ446' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E5 · una salvedad sobre X cobrada (con Y de id menor y el crédito) y su anulación
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1446 E5');
    v_y := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy - 1);
    v_x := pg_temp.t_pedido(v_cli, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb, v_hoy);
    v_c := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy);
    v_j := public.registrar_salvedad(v_x, (SELECT min(id) FROM pedido_items WHERE pedido_id = v_x), 20,
                                     'cliente_rechaza', 'ensayo 1446', NULL, true, NULL);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_x) IS DISTINCT FROM '80.00/80.00'
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_y THEN
      v_fallas := v_fallas || format('E5 salvedad dio %s', v_j);
    END IF;
    v_j := public.anular_salvedad((v_j->>'salvedad_id')::bigint, 'ensayo 1446');
    v_txt := pg_temp.t_saldo(v_cli);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_x) IS DISTINCT FROM '100.00/80.00'
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_y) IS DISTINCT FROM 30::numeric
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E5 anulación dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ446';
  EXCEPTION
    WHEN SQLSTATE 'ZZ446' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E6 · pasar X a vale blanco con un crédito y una boleta más vieja
  BEGIN
    v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1446 E6');
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1446 E6', 1, 1000, 0.6, v_suc)
    RETURNING id INTO v_prod2;
    v_y := pg_temp.t_pedido(v_cli, v_adm, v_prod2, 100, v_hoy - 1);
    v_x := pg_temp.t_pedido(v_cli, v_adm, v_prod2, 100, v_hoy);
    v_c := pg_temp.t_credito(v_cli, v_suc, v_adm, 30, v_hoy);
    UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = v_cli;
    v_j := public.cambiar_tipo_factura_pedido(v_x, 'VB', v_adm);
    v_txt := pg_temp.t_saldo(v_cli);
    IF pg_temp.t_cca() IS DISTINCT FROM v_cca THEN
      v_txt := v_txt || format(' CC-A de la base: %s, antes %s', pg_temp.t_cca(), v_cca);
    END IF;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT tipo_factura || '/' || total::text || '/' || monto_pagado::text FROM pedidos WHERE id = v_x)
          IS DISTINCT FROM 'VB/60.00/60.00'
       OR EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_x)
       OR (SELECT pedido_id FROM pagos WHERE id = v_c) IS DISTINCT FROM v_y
       OR v_txt <> '' THEN
      v_fallas := v_fallas || format('E6 dio %s%s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ446';
  EXCEPTION
    WHEN SQLSTATE 'ZZ446' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E6 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · el trigger, su lugar y el pre-bloqueo. Es lo único que falla sin la migración.
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass AND tgname = 'zzz_pedidos_reconciliar_pagos')
     OR ARRAY(SELECT tgname::text FROM pg_trigger
               WHERE tgrelid = 'public.pedidos'::regclass
                 AND tgname IN ('trg_pedidos_reconciliar_pagos', 'trigger_actualizar_recorrido_entrega', 'trigger_actualizar_saldo_pedido')
               ORDER BY tgname COLLATE "C")
        IS DISTINCT FROM ARRAY['trg_pedidos_reconciliar_pagos', 'trigger_actualizar_recorrido_entrega', 'trigger_actualizar_saldo_pedido'] THEN
    v_fallas := v_fallas || 'L1 la reconciliación no corre antes que las rutas y el saldo'::text;
  END IF;
  v_txt := (SELECT prosrc FROM pg_proc WHERE oid = 'public.pedidos_reconciliar_pagos()'::regprocedure);
  IF v_txt !~ 'WHERE id = ANY\(v_alcanza\)\s+ORDER BY id\s+FOR UPDATE;.*rp.pedido_id = ANY\(v_alcanza\)\)\s+ORDER BY id\s+FOR NO KEY UPDATE;.*ORDER BY id\s+FOR UPDATE;\s+END IF;\s+PERFORM public.desafectar_sobrepago_pedido' THEN
    v_fallas := v_fallas || 'L1 pedidos_reconciliar_pagos no tiene el pre-bloqueo'::text;
  END IF;
  IF to_regprocedure('public._edicion_bloquea_boletas(bigint,bigint)') IS NULL THEN
    v_fallas := v_fallas || 'L1 no existe _edicion_bloquea_boletas'::text;
  ELSIF has_function_privilege('anon', 'public._edicion_bloquea_boletas(bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._edicion_bloquea_boletas(bigint,bigint)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 _edicion_bloquea_boletas se puede ejecutar con anon o authenticated'::text;
  END IF;
  FOR v_j IN
    SELECT to_jsonb(t) FROM (VALUES
      ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
       'PERFORM public._edicion_bloquea_boletas\(p_pedido_id, v_sucursal\);\s+-- #826: FOR UPDATE serializa'),
      ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)',
       'PERFORM public._edicion_bloquea_boletas\(p_pedido_id, v_sucursal\);\s+PERFORM 1 FROM pedidos\s+WHERE id = p_pedido_id'),
      ('public.anular_salvedad(bigint,text)',
       'PERFORM public._edicion_bloquea_boletas\(v_salvedad.pedido_id, v_sucursal\);\s+PERFORM 1 FROM pedidos\s+WHERE id = v_salvedad.pedido_id'),
      ('public.cambiar_tipo_factura_pedido(bigint,character varying,uuid)',
       'PERFORM public._edicion_bloquea_boletas\(p_pedido_id, v_sucursal\);\s+SELECT id, estado, tipo_factura, cliente_id')
    ) AS t(firma, patron)
  LOOP
    IF (SELECT prosrc FROM pg_proc WHERE oid = (v_j->>'firma')::regprocedure) !~ (v_j->>'patron') THEN
      v_fallas := v_fallas || format('L1 %s no bloquea las boletas antes que la suya', v_j->>'firma');
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · E1 E2 E3 E4 E5 E6 L1';
 END;
END
$ensayo$;
