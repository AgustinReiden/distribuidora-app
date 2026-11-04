-- Ensayo de la migración que lleva cobros, créditos y stock al orden global de locks (#1439, #1424) y rechaza la
-- fecha futura en los FIFO y las masivas de cobro (#1440 punto 1).
--
-- Los 40P01 los mide el arnés (scripts/concurrencia, `t10`), porque hacen falta tres sesiones. Acá se prueba, en una
-- sola, que cada camino sigue haciendo lo mismo. Los casos C pasan con y sin la migración; F y L fallan sin ella:
--
--   C1 · imputar_credito_a_pedido: un crédito de 30 a una boleta de 100 se mueve entero; uno de 150, en un pedazo de
--        100 y un resto de 50 a favor.
--   C2 · actualizar_forma_pago_pago: el pago cambia de forma y la boleta toma la del pago mayor.
--   C3 · El DELETE REST de un pago (como authenticated, admin): se borra y la boleta baja lo cobrado.
--   C4 · El FIFO con un crédito y dos boletas: primero el crédito, por fecha, y después la plata nueva.
--   C5 · El FIFO combinado y marcar_pagos_masivo saldan sus boletas.
--   C6 · anular_nota_credito_venta borra el crédito de la NC y la deja anulada.
--   C7 · eliminar_pedido_completo deja los pagos de la boleta a favor del cliente.
--   C8 · registrar_ingreso_sucursal con los productos en orden inverso suma el stock de cada uno.
--   C9 · aceptar_movimiento_sucursal con la resolución cruzada mueve el stock de los dos lados.
--   F1 · Los dos FIFO y las dos masivas de cobro rechazan una fecha futura (22023), también para un admin.
--   L1 · Los cuerpos: cada pre-bloqueo está, por id, y la policy mt_pagos_delete llama a _pago_borrado_bloquea_pedido.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una excepción,
-- y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se corre pegado detrás de su cuerpo,
-- sin el BEGIN y el COMMIT; después, solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', únicamente por F1 y L1.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta, y otra sucursal activa (el origen de
-- C9). El resto nace en el ensayo. Los cobros van con la fecha de hoy: la fecha futura ya no entra.

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1439', p_suc)
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
    'ensayo 1439', 'efectivo', 'pendiente', p_fecha);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Un crédito (pago a cuenta sin boleta).
CREATE OR REPLACE FUNCTION pg_temp.t_credito(p_cli bigint, p_suc bigint, p_adm uuid, p_monto numeric, p_fecha date)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, notas, a_cuenta)
  VALUES (p_cli, NULL, p_suc, p_monto, 'efectivo', p_fecha, p_adm, '[saldo a favor]', true)
  RETURNING id;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_otra   bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_prod   bigint;
  v_c1     bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_pa     bigint;
  v_pb     bigint;
  v_n      bigint;
  v_num    numeric;
  v_txt    text;
  v_j      jsonb;
  v_fallas text[] := '{}';
  v_f      record;
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
  SELECT id INTO v_otra FROM sucursales WHERE activa AND id <> v_suc ORDER BY id LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_prod := pg_temp.t_producto(v_suc, 'ZZ ensayo 1439');

  -- C1 · imputar un crédito entero y uno partido
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 C1');
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_pa := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_j := public.imputar_credito_a_pedido_impl(v_pa, v_p1, NULL);
    IF (v_j->>'pago_id')::bigint IS DISTINCT FROM v_pa
       OR (SELECT pedido_id FROM pagos WHERE id = v_pa) IS DISTINCT FROM v_p1
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_p1) IS DISTINCT FROM 30::numeric THEN
      v_fallas := v_fallas || format('C1 entero dio %s', v_j);
    END IF;
    v_pb := pg_temp.t_credito(v_c1, v_suc, v_adm, 150, v_hoy);
    v_j := public.imputar_credito_a_pedido_impl(v_pb, v_p1, NULL);
    IF (v_j->>'monto_imputado')::numeric IS DISTINCT FROM 70::numeric
       OR (v_j->>'resto_a_favor')::numeric IS DISTINCT FROM 80::numeric
       OR (SELECT monto FROM pagos WHERE id = v_pb AND pedido_id IS NULL) IS DISTINCT FROM 80::numeric
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_p1) IS DISTINCT FROM 100::numeric THEN
      v_fallas := v_fallas || format('C1 partido dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C2 · cambiar la forma de pago de un pago de una boleta
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 C2');
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_p1, '[{"monto":60,"forma_pago":"efectivo"},{"monto":40,"forma_pago":"transferencia"}]'::jsonb, v_hoy);
    SELECT min(id) INTO v_pa FROM pagos WHERE pedido_id = v_p1;
    v_j := public.actualizar_forma_pago_pago(v_pa, 'cheque');
    IF (SELECT forma_pago FROM pagos WHERE id = v_pa) IS DISTINCT FROM 'cheque'
       OR (SELECT forma_pago FROM pedidos WHERE id = v_p1) IS DISTINCT FROM 'cheque' THEN
      v_fallas := v_fallas || format('C2 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C3 · el DELETE REST de un pago, como lo hace el front (authenticated, admin)
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 C3');
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_p1, '[{"monto":60,"forma_pago":"efectivo"},{"monto":40,"forma_pago":"transferencia"}]'::jsonb, v_hoy);
    SELECT min(id) INTO v_pa FROM pagos WHERE pedido_id = v_p1;
    EXECUTE 'SET LOCAL ROLE authenticated';
    DELETE FROM public.pagos WHERE id = v_pa;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 OR (SELECT monto_pagado FROM pedidos WHERE id = v_p1) IS DISTINCT FROM 40::numeric THEN
      v_fallas := v_fallas || format('C3 borró %s pagos y la boleta quedó en %s', v_n, (SELECT monto_pagado FROM pedidos WHERE id = v_p1));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C4 · FIFO con un crédito y dos boletas: el crédito va a la más vieja, y la plata nueva sigue por fecha
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 C4');
    v_p2 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy - 1);
    v_pa := pg_temp.t_credito(v_c1, v_suc, v_adm, 30, v_hoy);
    v_j := public.registrar_pago_cliente_fifo_impl(v_c1, 120, 'efectivo', v_hoy, NULL, 'ensayo 1439');
    IF (v_j->>'credito_aplicado')::numeric IS DISTINCT FROM 30::numeric
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_p1) IS DISTINCT FROM 100::numeric
       OR (SELECT monto_pagado FROM pedidos WHERE id = v_p2) IS DISTINCT FROM 50::numeric
       OR (v_j->>'sobrante')::numeric IS DISTINCT FROM 0::numeric THEN
      v_fallas := v_fallas || format('C4 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C5 · el FIFO combinado y marcar_pagos_masivo
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 C5');
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pago_combinado_cliente_fifo_impl(v_c1, '[{"monto":60,"forma_pago":"efectivo"},{"monto":40,"forma_pago":"transferencia"}]'::jsonb, v_hoy, NULL, 'ensayo 1439');
    IF (SELECT monto_pagado FROM pedidos WHERE id = v_p1) IS DISTINCT FROM 100::numeric THEN
      v_fallas := v_fallas || format('C5 combinado dio %s', v_j);
    END IF;
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_p2 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 50, v_hoy);
    v_n := public.marcar_pagos_masivo_impl(ARRAY[v_p2, v_p1], 'efectivo', v_hoy);
    IF v_n <> 2 OR EXISTS (SELECT 1 FROM pedidos WHERE id IN (v_p1, v_p2) AND monto_pagado <> total) THEN
      v_fallas := v_fallas || format('C5 masivo dio %s', v_n);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C6 · anular una NC sin usar
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 C6');
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, neto, iva, usuario_id)
    VALUES (v_suc, v_c1, v_p1, v_hoy, 'otro', 50, 50, 0, v_adm) RETURNING id INTO v_n;
    INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, nota_credito_id)
    VALUES (v_c1, NULL, v_suc, 30, 'nota_credito', v_hoy, v_adm, v_n), (v_c1, NULL, v_suc, 20, 'nota_credito', v_hoy, v_adm, v_n);
    v_j := public.anular_nota_credito_venta(v_n, 'ensayo 1439');
    IF (v_j->>'pagos_borrados')::int IS DISTINCT FROM 2
       OR EXISTS (SELECT 1 FROM pagos WHERE nota_credito_id = v_n)
       OR NOT (SELECT anulada FROM notas_credito_venta WHERE id = v_n) THEN
      v_fallas := v_fallas || format('C6 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C6 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C7 · eliminar una boleta cobrada: los pagos quedan a favor
  BEGIN
    v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 C7');
    v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
    v_j := public.registrar_pagos_pedido_impl(v_p1, '[{"monto":60,"forma_pago":"efectivo"},{"monto":40,"forma_pago":"transferencia"}]'::jsonb, v_hoy);
    SELECT min(id), max(id) INTO v_pa, v_pb FROM pagos WHERE pedido_id = v_p1;
    UPDATE pagos SET notas = 'editado' WHERE id = v_pa;
    v_j := public.eliminar_pedido_completo(v_p1, v_adm, 'ensayo 1439', true);
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR EXISTS (SELECT 1 FROM pedidos WHERE id = v_p1)
       OR (SELECT count(*) FROM pagos WHERE id IN (v_pa, v_pb) AND pedido_id IS NULL AND cliente_id = v_c1) <> 2 THEN
      v_fallas := v_fallas || format('C7 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C7 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C8 · un ingreso de sucursal con los productos en orden inverso
  BEGIN
    v_pa := pg_temp.t_producto(v_suc, 'ZZ ensayo 1439 A');
    v_pb := pg_temp.t_producto(v_suc, 'ZZ ensayo 1439 B');
    v_j := public.registrar_ingreso_sucursal(v_suc, v_hoy, 'ensayo 1439', 0, v_adm,
             jsonb_build_array(jsonb_build_object('producto_id', v_pb, 'cantidad', 3, 'costo_unitario', 1),
                               jsonb_build_object('producto_id', v_pa, 'cantidad', 2, 'costo_unitario', 1)));
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT stock FROM productos WHERE id = v_pa) IS DISTINCT FROM 1002
       OR (SELECT stock FROM productos WHERE id = v_pb) IS DISTINCT FROM 1003 THEN
      v_fallas := v_fallas || format('C8 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C8 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- C9 · aceptar un envío de la otra sucursal emparejado al revés (oA → dY, oB → dX)
  BEGIN
    IF v_otra IS NULL THEN
      RAISE EXCEPTION 'sin una segunda sucursal activa';
    END IF;
    DECLARE
      v_dx bigint := pg_temp.t_producto(v_suc, 'ZZ ensayo 1439 dX');
      v_dy bigint := pg_temp.t_producto(v_suc, 'ZZ ensayo 1439 dY');
      v_oa bigint := pg_temp.t_producto(v_otra, 'ZZ ensayo 1439 oA');
      v_ob bigint := pg_temp.t_producto(v_otra, 'ZZ ensayo 1439 oB');
      v_mov bigint;
      v_i1 bigint;
      v_i2 bigint;
    BEGIN
      INSERT INTO movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, creado_por, stock_descontado, notas)
      VALUES (v_otra, v_suc, 'pendiente', v_adm, false, 'ensayo 1439') RETURNING id INTO v_mov;
      INSERT INTO movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre, origen_costo_promedio)
      VALUES (v_mov, v_oa, 2, 'ZZ ensayo 1439 oA', 1) RETURNING id INTO v_i1;
      INSERT INTO movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre, origen_costo_promedio)
      VALUES (v_mov, v_ob, 3, 'ZZ ensayo 1439 oB', 1) RETURNING id INTO v_i2;
      v_j := public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(
               jsonb_build_object('item_id', v_i1, 'accion', 'match_existente', 'producto_destino_id', v_dy),
               jsonb_build_object('item_id', v_i2, 'accion', 'match_existente', 'producto_destino_id', v_dx)));
      IF NOT COALESCE((v_j->>'success')::boolean, false)
         OR (SELECT stock FROM productos WHERE id = v_dy) IS DISTINCT FROM 1002
         OR (SELECT stock FROM productos WHERE id = v_dx) IS DISTINCT FROM 1003
         OR (SELECT stock FROM productos WHERE id = v_oa) IS DISTINCT FROM 998
         OR (SELECT stock FROM productos WHERE id = v_ob) IS DISTINCT FROM 997 THEN
        v_fallas := v_fallas || format('C9 dio %s', v_j);
      END IF;
    END;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
  EXCEPTION
    WHEN SQLSTATE 'ZZ439' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C9 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- F1 · la fecha futura, también para un admin
  v_c1 := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1439 F1');
  v_p1 := pg_temp.t_pedido(v_c1, v_adm, v_prod, 100, v_hoy);
  FOR v_f IN
    SELECT * FROM (VALUES
      ('FIFO',      format('SELECT public.registrar_pago_cliente_fifo_impl(%s, 10, ''efectivo'', %L::date)', v_c1, v_hoy + 1)),
      ('combinado', format('SELECT public.registrar_pago_combinado_cliente_fifo_impl(%s, ''[{"monto":10,"forma_pago":"efectivo"}]''::jsonb, %L::date)', v_c1, v_hoy + 1)),
      ('masivo',    format('SELECT public.marcar_pagos_masivo_impl(ARRAY[%s]::bigint[], ''efectivo'', %L::date)', v_p1, v_hoy + 1)),
      ('entrega',   format('SELECT public.marcar_entrega_y_pago_masivo_impl(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', %L::date)', v_p1, v_adm, v_hoy + 1))
    ) AS t(nombre, sql)
  LOOP
    BEGIN
      EXECUTE v_f.sql;
      v_fallas := v_fallas || format('F1 %s aceptó la fecha de mañana', v_f.nombre);
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ439';
    EXCEPTION
      WHEN SQLSTATE 'ZZ439' THEN NULL;
      WHEN SQLSTATE '22023' THEN
        IF SQLERRM NOT LIKE '%no puede ser futura%' THEN
          v_fallas := v_fallas || format('F1 %s dio 22023 por otra cosa: %s', v_f.nombre, SQLERRM);
        END IF;
      WHEN OTHERS THEN v_fallas := v_fallas || format('F1 %s dio %s: %s', v_f.nombre, SQLSTATE, SQLERRM);
    END;
  END LOOP;

  -- L1 · los cuerpos y la policy. Es lo único, con F1, que falla sin la migración.
  FOR v_f IN
    SELECT * FROM (VALUES
      ('public.imputar_credito_a_pedido_impl(bigint,bigint,numeric)',
       'PERFORM 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal_id FOR UPDATE;\s+SELECT id, cliente_id, pedido_id, monto, forma_pago, fecha, nota_credito_id\s+INTO v_pago\s+FROM pagos'),
      ('public.actualizar_forma_pago_pago(bigint,text)',
       'FROM pedidos\s+WHERE id = \(SELECT pedido_id FROM pagos WHERE id = p_pago_id AND sucursal_id = v_sucursal_id\)\s+AND sucursal_id = v_sucursal_id\s+FOR UPDATE;\s+SELECT id, pedido_id, fecha, forma_pago'),
      ('public.aplicar_credito_cliente(bigint,bigint)',
       'WHERE id = ANY\(v_alcanza\)\s+ORDER BY id\s+FOR UPDATE;.*rp.pedido_id = ANY\(v_alcanza\)\)\s+ORDER BY id\s+FOR NO KEY UPDATE;.*AND pedido_id IS NULL\s+ORDER BY id\s+FOR UPDATE;\s+END IF;\s+FOR v_credito IN'),
      ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',
       'ORDER BY id\s+FOR UPDATE;\s+PERFORM 1\s+FROM recorridos.*ORDER BY id\s+FOR NO KEY UPDATE;\s+v_credito_aplicado := public.aplicar_credito_cliente'),
      ('public.registrar_pago_combinado_cliente_fifo_impl(bigint,jsonb,date,text,text)',
       'ORDER BY id\s+FOR UPDATE;\s+PERFORM 1\s+FROM recorridos.*ORDER BY id\s+FOR NO KEY UPDATE;\s+v_credito_aplicado := public.aplicar_credito_cliente'),
      ('public.marcar_pagos_masivo_impl(bigint[],text,date)',
       'WHERE id = ANY\(p_pedido_ids\)\s+AND sucursal_id = v_sucursal_id\s+ORDER BY id\s+FOR UPDATE;\s+PERFORM 1\s+FROM recorridos.*FOR NO KEY UPDATE;\s+FOR v_pedido IN.*ORDER BY id\s+FOR UPDATE\s+LOOP'),
      ('public.eliminar_pedido_completo(bigint,uuid,text,boolean)',
       'WHERE pedido_id = p_pedido_id\s+AND sucursal_id = v_sucursal\s+ORDER BY id\s+FOR NO KEY UPDATE;\s+DELETE FROM pedidos'),
      ('public.anular_nota_credito_venta(bigint,text)',
       'PERFORM 1 FROM pagos WHERE nota_credito_id = p_nota_credito_id ORDER BY id FOR UPDATE;'),
      ('public.registrar_ingreso_sucursal(bigint,date,text,numeric,uuid,jsonb)',
       'FROM productos\s+WHERE sucursal_id = v_tenant\s+AND id IN \(SELECT \(e->>''producto_id''\)::bigint FROM jsonb_array_elements\(p_items\) e\)\s+ORDER BY id\s+FOR UPDATE;\s+FOR v_item IN'),
      ('public.aceptar_movimiento_sucursal(bigint,jsonb)',
       'OR \(sucursal_id = v_destino.*ORDER BY id\s+FOR UPDATE;\s+FOR v_item IN SELECT \* FROM movimiento_sucursal_items')
    ) AS t(firma, patron)
  LOOP
    v_txt := (SELECT prosrc FROM pg_proc WHERE oid = v_f.firma::regprocedure);
    IF v_txt !~ v_f.patron THEN
      v_fallas := v_fallas || format('L1 %s no tiene el pre-bloqueo', v_f.firma);
    END IF;
  END LOOP;
  IF to_regprocedure('public._pago_borrado_bloquea_pedido(bigint)') IS NULL
     OR position('_pago_borrado_bloquea_pedido' IN
                 (SELECT pg_get_expr(polqual, polrelid) FROM pg_policy
                   WHERE polrelid = 'public.pagos'::regclass AND polname = 'mt_pagos_delete')) = 0 THEN
    v_fallas := v_fallas || 'L1 la policy mt_pagos_delete no bloquea la boleta'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · C1 C2 C3 C4 C5 C6 C7 C8 C9 F1 L1';
 END;
END
$ensayo$;
