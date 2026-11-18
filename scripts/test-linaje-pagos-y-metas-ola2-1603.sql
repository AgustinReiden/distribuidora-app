-- Ensayo de la tarjeta C6 de la ola 2 del plan #1603 (1601-b9 de #1601): el linaje de un pago
-- y los productos de una meta, atados a su sucursal.
-- Migración: NNN_linaje_de_pagos_y_productos_de_metas.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la migración
-- fallan todos los casos menos los que dicen «regresión».
--
--   L1 · un pedazo de la sucursal 2 colgado de un pago (padre) de la sucursal 1: se rechaza.
--   L2 · lo mismo con la raíz (pago_origen_id): se rechaza.
--   L3 · un pedazo colgado de un id de pago que nunca existió: se rechaza.
--   L4 · regresión · desafectar_sobrepago_pedido con un crédito de NC: borra el pago y hace nacer
--        el pedazo con el padre borrado, y anda (la salvedad o la edición que bajan el total).
--   L5 · regresión · el admin borra lo que quedó de un pago partido (su pedazo sigue vivo), y
--        después un pedazo nuevo puede nacer del borrado.
--   L6 · regresión · un pago común (sin linaje) entra y queda en el registro.
--   M1 · una meta con un producto de otra sucursal, escrita directo en la tabla: se rechaza.
--   M2 · una meta con un id de producto que no existe, o con un id repetido o nulo: se rechaza.
--   M3 · borrar un producto que está en una meta: se rechaza con el número de la meta.
--   M4 · regresión · una meta con productos de su sucursal entra por guardar_meta_preventista, y
--        un producto que no está en ninguna meta se borra.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-linaje-pagos-y-metas-ola2-1603.sql

DO $ensayo$
DECLARE
  v_adm      uuid;
  v_pre      uuid;
  v_cli1     bigint;
  v_cli2     bigint;
  v_p1       bigint;
  v_p2       bigint;
  v_hijo     bigint;
  v_prod1    bigint;
  v_prod1b   bigint;
  v_prod2    bigint;
  v_prod_lib bigint;
  v_meta     bigint;
  v_r        text;
  v_n        bigint;
  v_fallas   text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c6-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'C6 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
  END $f$;
  -- Corre p_sql como postgres (el server, como una RPC definer) y devuelve 'PASA' o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.server(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN 'PASA';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Lo mismo como un usuario (authenticated) parado en p_suc.
  CREATE FUNCTION pg_temp.como_usuario(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql;
      r := 'PASA';
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;

  -- --------------------------------------------------------------- fixtures -
  v_adm := pg_temp.u('admin', 1);
  v_pre := pg_temp.u('preventista', 1);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('C6 uno', 'C6 uno', 'Calle Falsa 1', 1) RETURNING id INTO v_cli1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('C6 dos', 'C6 dos', 'Calle Falsa 2', 2) RETURNING id INTO v_cli2;

  -- Un pago a cuenta de la 1 y otro de la 2 (saldo a favor, sin boleta).
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, a_cuenta)
  VALUES (v_cli1, NULL, 100, 'efectivo', public._tablero_hoy(), 1, true) RETURNING id INTO v_p1;
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, a_cuenta)
  VALUES (v_cli2, NULL, 100, 'efectivo', public._tablero_hoy(), 2, true) RETURNING id INTO v_p2;

  -- ------------------------------------------------------------ L1, L2, L3 -
  -- L3: un id menor que el del pedazo (pagos_padre_anterior) que no es de ningún pago.
  SELECT g INTO v_n FROM generate_series(1, v_p2) g WHERE NOT EXISTS (SELECT 1 FROM pagos x WHERE x.id = g) LIMIT 1;
  v_r := pg_temp.server(format(
    'INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, a_cuenta, pago_origen_id, pago_padre_id)
     VALUES (%s, 10, ''efectivo'', public._tablero_hoy(), 2, true, %s, %s)', v_cli2, v_p2, v_p1));
  IF v_r NOT LIKE '23503%' THEN
    v_fallas := v_fallas || ('L1 · un pedazo de la 2 con el padre en la 1 entró: ' || v_r);
  END IF;
  v_r := pg_temp.server(format(
    'INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, a_cuenta, pago_origen_id, pago_padre_id)
     VALUES (%s, 10, ''efectivo'', public._tablero_hoy(), 2, true, %s, %s)', v_cli2, v_p1, v_p2));
  IF v_r NOT LIKE '23503%' THEN
    v_fallas := v_fallas || ('L2 · un pedazo de la 2 con la raíz en la 1 entró: ' || v_r);
  END IF;
  v_r := pg_temp.server(format(
    'INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, a_cuenta, pago_origen_id, pago_padre_id)
     VALUES (%s, 10, ''efectivo'', public._tablero_hoy(), 1, true, %s, %s)', v_cli1, v_n, v_n));
  IF v_r NOT LIKE '23503%' THEN
    v_fallas := v_fallas || ('L3 · un pedazo colgado de un pago que nunca existió entró: ' || v_r);
  END IF;

  -- -------------------------------------------------------------------- L4 -
  -- La rama del crédito de NC de desafectar_sobrepago_pedido: un pedido de 100 pagado
  -- con un crédito de NC de 100; el total baja a 60 y el sobrante (40) vuelve a saldo a favor.
  -- Se arma a mano lo mínimo: la NC, la boleta y el pago, y se llama a la función como la llama
  -- el trigger de la baja de total.
  DECLARE
    v_ped   bigint;
    v_ped2  bigint;
    v_nc    bigint;
    v_pago  bigint;
    v_quit  numeric;
  BEGIN
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura)
    VALUES (v_cli1, 1, v_pre, 100, 'pendiente', public._tablero_hoy(), 'app', 'ZZ') RETURNING id INTO v_ped;
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura)
    VALUES (v_cli1, 1, v_pre, 100, 'pendiente', public._tablero_hoy(), 'app', 'ZZ') RETURNING id INTO v_ped2;
    INSERT INTO notas_credito_venta (pedido_id, cliente_id, sucursal_id, motivo, total, neto, iva, usuario_id)
    VALUES (v_ped2, v_cli1, 1, 'otro', 100, 100, 0, v_adm) RETURNING id INTO v_nc;
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, nota_credito_id)
    VALUES (v_cli1, v_ped, 100, 'nota_credito', public._tablero_hoy(), 1, v_nc) RETURNING id INTO v_pago;
    -- La baja del total sin pasar por el trigger de reconciliación (que llamaría a la misma
    -- función y además reaplicaría el crédito): se mide sólo el DELETE + el pedazo.
    PERFORM set_config('app.reimputacion_pagos', 'on', true);
    ALTER TABLE public.pedidos DISABLE TRIGGER USER;
    UPDATE pedidos SET total = 0 WHERE id = v_ped;
    ALTER TABLE public.pedidos ENABLE TRIGGER USER;
    PERFORM set_config('app.reimputacion_pagos', '', true);
    BEGIN
      v_quit := public.desafectar_sobrepago_pedido(v_ped);
      SELECT count(*) INTO v_n FROM pagos
       WHERE pago_padre_id = v_pago AND NOT EXISTS (SELECT 1 FROM pagos x WHERE x.id = v_pago);
      IF v_quit <> 100 OR v_n <> 1 THEN
        v_fallas := v_fallas || format('L4 · la baja de total con un crédito de NC: quitado %s, pedazos con el padre borrado %s (esperado 100 y 1)', v_quit, v_n);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || ('L4 · la baja de total con un crédito de NC falló: ' || SQLSTATE || ' ' || SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('L4 · no armó: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- -------------------------------------------------------------------- L5 -
  -- El pago de la 1 se parte: 30 van a un pedazo; después el admin borra lo que quedó (70), y de
  -- ese id borrado nace otro pedazo (como el del crédito de NC).
  v_r := pg_temp.server(format(
    'INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, a_cuenta, pago_origen_id, pago_padre_id)
     VALUES (%s, 30, ''efectivo'', public._tablero_hoy(), 1, true, %s, %s)', v_cli1, v_p1, v_p1));
  IF v_r <> 'PASA' THEN
    v_fallas := v_fallas || ('L5 · el pedazo legítimo no entró: ' || v_r);
  END IF;
  UPDATE pagos SET monto = 70 WHERE id = v_p1;
  -- Un pago a cuenta sin boleta: el guard de crédito aplicado no lo frena. El admin lo borra.
  v_r := pg_temp.como_usuario(v_adm, 1, format('DELETE FROM pagos WHERE id = %s', v_p1));
  SELECT count(*) INTO v_n FROM pagos WHERE id = v_p1;
  IF v_r <> 'PASA' OR v_n <> 0 THEN
    v_fallas := v_fallas || format('L5 · el admin no pudo borrar lo que quedó del pago partido: %s (quedan %s)', v_r, v_n);
  END IF;
  v_r := pg_temp.server(format(
    'INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, a_cuenta, pago_origen_id, pago_padre_id)
     VALUES (%s, 5, ''efectivo'', public._tablero_hoy(), 1, true, %s, %s)', v_cli1, v_p1, v_p1));
  IF v_r <> 'PASA' THEN
    v_fallas := v_fallas || ('L5 · un pedazo de un pago ya borrado no entró: ' || v_r);
  END IF;

  -- -------------------------------------------------------------------- L6 -
  IF to_regclass('public.pagos_linaje') IS NULL THEN
    v_fallas := v_fallas || 'L6 · no existe el registro pagos_linaje'::text;
  ELSE
    EXECUTE format('SELECT count(*) FROM public.pagos_linaje WHERE id = %s AND sucursal_id = 2', v_p2) INTO v_n;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || 'L6 · el pago nuevo no quedó en el registro con su sucursal'::text;
    END IF;
  END IF;

  -- ----------------------------------------------------------------- M1..M4 -
  INSERT INTO productos (nombre, precio, sucursal_id) VALUES ('C6 prod uno', 10, 1) RETURNING id INTO v_prod1;
  INSERT INTO productos (nombre, precio, sucursal_id) VALUES ('C6 prod uno b', 10, 1) RETURNING id INTO v_prod1b;
  INSERT INTO productos (nombre, precio, sucursal_id) VALUES ('C6 prod dos', 10, 2) RETURNING id INTO v_prod2;
  INSERT INTO productos (nombre, precio, sucursal_id) VALUES ('C6 prod libre', 10, 1) RETURNING id INTO v_prod_lib;

  v_r := pg_temp.server(format(
    'INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, producto_ids, valor_objetivo)
     VALUES (1, %L, date_trunc(''month'', public._tablero_hoy())::date, (date_trunc(''month'', public._tablero_hoy()) + interval ''1 month - 1 day'')::date,
             ''unidades'', ARRAY[%s, %s]::bigint[], 10)', v_pre, v_prod1, v_prod2));
  IF v_r NOT LIKE '23503%' THEN
    v_fallas := v_fallas || ('M1 · una meta de la 1 con un producto de la 2 entró: ' || v_r);
  END IF;

  FOR v_r IN
    SELECT format('%s: %s', caso, pg_temp.server(format(
      'INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, producto_ids, valor_objetivo)
       VALUES (1, %L, date_trunc(''month'', public._tablero_hoy())::date, (date_trunc(''month'', public._tablero_hoy()) + interval ''1 month - 1 day'')::date,
               ''unidades'', %s, 10)', v_pre, arr)))
      FROM (VALUES ('inexistente', format('ARRAY[%s, 900000000]::bigint[]', v_prod1)),
                   ('repetido',    format('ARRAY[%s, %s]::bigint[]', v_prod1, v_prod1)),
                   ('nulo',        format('ARRAY[%s, NULL]::bigint[]', v_prod1))) AS t(caso, arr)
  LOOP
    IF v_r LIKE '%: PASA' THEN
      v_fallas := v_fallas || ('M2 · una meta con un producto ' || v_r);
    END IF;
  END LOOP;

  -- M4 (la meta buena, por la RPC, como admin parado en la 1).
  PERFORM pg_temp.como(v_adm, 1);
  BEGIN
    v_meta := public.guardar_meta_preventista(NULL, 1, v_pre, date_trunc('month', public._tablero_hoy())::date,
                                              'unidades', 10, NULL, NULL, ARRAY[v_prod1, v_prod1b], NULL);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('M4 · la meta buena por guardar_meta_preventista no entró: ' || SQLSTATE || ' ' || SQLERRM);
  END;
  PERFORM pg_temp.como(NULL, NULL);
  -- Y un UPDATE que la deja con un producto de otra sucursal, directo en la tabla (M1 en la edición).
  IF v_meta IS NOT NULL THEN
    v_r := pg_temp.server(format('UPDATE metas_preventista SET producto_ids = ARRAY[%s, %s]::bigint[] WHERE id = %s', v_prod1, v_prod2, v_meta));
    IF v_r NOT LIKE '23503%' THEN
      v_fallas := v_fallas || ('M1 · la edición de una meta con un producto de la 2 entró: ' || v_r);
    END IF;
  END IF;

  -- M3: el producto de la meta no se borra (ni como admin ni como server); el libre sí (M4).
  v_r := pg_temp.como_usuario(v_adm, 1, format('DELETE FROM productos WHERE id = %s', v_prod1b));
  SELECT count(*) INTO v_n FROM productos WHERE id = v_prod1b;
  IF v_n <> 1 THEN
    v_fallas := v_fallas || ('M3 · se borró un producto que está en una meta: ' || v_r);
  ELSIF v_r NOT LIKE '23503%' OR v_r NOT LIKE '%#' || v_meta || '%' THEN
    v_fallas := v_fallas || ('M3 · el borrado de un producto en una meta no dice cuál: ' || v_r);
  END IF;
  v_r := pg_temp.como_usuario(v_adm, 1, format('DELETE FROM productos WHERE id = %s', v_prod_lib));
  SELECT count(*) INTO v_n FROM productos WHERE id = v_prod_lib;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || ('M4 · un producto sin metas ni historial no se borró: ' || v_r);
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK' USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
