-- Ensayo de la tarjeta C6 de la ola 2 del plan #1603 (1601-b9 y la RPC de 1601-b5 de #1601): el
-- linaje de un pago y los productos de una meta, de su sucursal; y el email de otro usuario por RPC.
-- Migración: 537_linaje_de_pagos_metas_y_emails.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la migración
-- fallan todos los casos menos los que dicen «regresión».
--
--   L1 · un pedazo de la sucursal 2 colgado de un pago (padre) VIVO de la sucursal 1: se rechaza.
--   L2 · lo mismo con la raíz (pago_origen_id): se rechaza.
--   L3 · regresión · un pedazo cuyo padre y raíz ya se borraron entra (el linaje sobrevive al
--        borrado a propósito: no hay FK).
--   L4 · regresión · desafectar_sobrepago_pedido con un crédito de NC: borra el pago y hace nacer
--        el pedazo con el padre borrado, y anda (la salvedad o la edición que bajan el total).
--   L5 · regresión · el admin borra lo que quedó de un pago partido (su pedazo sigue vivo), y
--        después un pedazo nuevo puede nacer del borrado.
--   L6 · auditoria_integridad() ve un pedazo con la raíz en otra sucursal que se escapó del
--        trigger (PAGO-B) y una meta con un producto ajeno (META-A), y da 0 sin ellos.
--   M1 · una meta con un producto de otra sucursal, escrita directo en la tabla: se rechaza.
--   M2 · una meta con un id de producto que no existe, o con un id repetido o nulo: se rechaza.
--   M3 · borrar un producto que está en una meta: se rechaza con el número de la meta.
--   M4 · regresión · una meta con productos de su sucursal entra por guardar_meta_preventista, y
--        un producto que no está en ninguna meta se borra.
--   E1 · emails_de_usuarios: admin y encargado reciben el email de otro de su sucursal;
--        preventista, chofer y un encargado desactivado, sólo el suyo.
--   P1 · un admin no edita su propia fila de perfiles por REST (nombre, email, zona): 42501 con el
--        motivo.
--   P2 · tampoco su propio rol, aunque quede otro admin activo.
--   P3 · ni se asigna ni se quita sus propios roles extra (perfil_roles).
--   P4 · regresión · el admin edita a OTRO usuario que abarca (perfiles y perfil_roles), y lo
--        desactiva (perfiles_guard_desactivacion sigue andando).
--   P5 · regresión · el server (service_role) edita cualquier perfil, también el del admin que
--        firma; asignar_usuario_sucursal (definer) y generar_codigo_vinculacion_bot andan.
--   P6 · regresión · un preventista sobre su propia fila sigue sin poder (0 filas, como hoy).
--
-- Los ids de pago se toman de los propios: nada de recorrer la secuencia (en el CI está en 10^9).
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-linaje-pagos-metas-y-emails-ola2-1603.sql

DO $ensayo$
DECLARE
  v_adm      uuid;
  v_enc      uuid;
  v_pre      uuid;
  v_tra      uuid;
  v_des      uuid;
  v_adm2     uuid;
  v_cli1     bigint;
  v_cli2     bigint;
  v_p1       bigint;
  v_p2       bigint;
  v_borrado  bigint;
  v_prod1    bigint;
  v_prod1b   bigint;
  v_prod2    bigint;
  v_prod_lib bigint;
  v_meta     bigint;
  v_r        text;
  v_t        text;
  v_n        bigint;
  v_aud      jsonb;
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
  -- Corre p_sql como un usuario (authenticated) parado en p_suc; devuelve 'PASA <valor>' o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.como_usuario(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text; x text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql INTO x;
      r := 'PASA' || COALESCE(' ' || x, '');
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- Las violaciones de un check de auditoria_integridad() (NULL si el check no existe).
  CREATE FUNCTION pg_temp.check_de(p_aud jsonb, p_id text) RETURNS bigint LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::bigint FROM jsonb_array_elements(p_aud->'checks') c WHERE c->>'id' = p_id
  $f$;

  -- --------------------------------------------------------------- fixtures -
  v_adm := pg_temp.u('admin', 1);
  v_enc := pg_temp.u('encargado', 1);
  v_pre := pg_temp.u('preventista', 1);
  v_tra := pg_temp.u('transportista', 1);
  v_des := pg_temp.u('encargado', 1);
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'auth.users'::regclass AND attname = 'banned_until') THEN
    ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
    UPDATE perfiles SET activo = false WHERE id = v_des;
    ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;
  ELSE
    UPDATE perfiles SET activo = false WHERE id = v_des;
  END IF;
  UPDATE perfiles SET email = 'c6-' || id || '@ensayo.invalid'
   WHERE id IN (v_adm, v_enc, v_pre, v_tra, v_des) AND email IS NULL;

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('C6 uno', 'C6 uno', 'Calle Falsa 1', 1) RETURNING id INTO v_cli1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('C6 dos', 'C6 dos', 'Calle Falsa 2', 2) RETURNING id INTO v_cli2;

  -- Un pago que se borra (su id queda libre y menor que los que siguen), y un pago a cuenta de la
  -- 1 y otro de la 2 (saldo a favor, sin boleta).
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, a_cuenta)
  VALUES (v_cli1, NULL, 5, 'efectivo', public._tablero_hoy(), 1, true) RETURNING id INTO v_borrado;
  DELETE FROM pagos WHERE id = v_borrado;
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, a_cuenta)
  VALUES (v_cli1, NULL, 100, 'efectivo', public._tablero_hoy(), 1, true) RETURNING id INTO v_p1;
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, a_cuenta)
  VALUES (v_cli2, NULL, 100, 'efectivo', public._tablero_hoy(), 2, true) RETURNING id INTO v_p2;

  -- ------------------------------------------------------------ L1, L2, L3 -
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
     VALUES (%s, 10, ''efectivo'', public._tablero_hoy(), 2, true, %s, %s)', v_cli2, v_borrado, v_borrado));
  IF v_r <> 'PASA' THEN
    v_fallas := v_fallas || ('L3 · un pedazo de un padre ya borrado no entró: ' || v_r);
  END IF;

  -- -------------------------------------------------------------------- L4 -
  -- La rama del crédito de NC de desafectar_sobrepago_pedido: un pedido de 100 pagado con un
  -- crédito de NC de 100; el total baja a 0 y el crédito vuelve a saldo a favor como pedazo del
  -- pago borrado. Se llama a la función como la llama el trigger de la baja de total.
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
    -- La baja del total sin el trigger de reconciliación (que llamaría a la misma función y
    -- además reaplicaría el crédito): se mide sólo el DELETE + el pedazo.
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
  v_r := pg_temp.como_usuario(v_adm, 1, format('DELETE FROM pagos WHERE id = %s RETURNING id::text', v_p1));
  SELECT count(*) INTO v_n FROM pagos WHERE id = v_p1;
  IF v_r NOT LIKE 'PASA%' OR v_n <> 0 THEN
    v_fallas := v_fallas || format('L5 · el admin no pudo borrar lo que quedó del pago partido: %s (quedan %s)', v_r, v_n);
  END IF;
  v_r := pg_temp.server(format(
    'INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, a_cuenta, pago_origen_id, pago_padre_id)
     VALUES (%s, 5, ''efectivo'', public._tablero_hoy(), 1, true, %s, %s)', v_cli1, v_p1, v_p1));
  IF v_r <> 'PASA' THEN
    v_fallas := v_fallas || ('L5 · un pedazo de un pago ya borrado no entró: ' || v_r);
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
      FROM (VALUES ('inexistente', format('ARRAY[%s, %s]::bigint[]', v_prod1, v_prod_lib + 1000000)),
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
  IF v_meta IS NOT NULL THEN
    v_r := pg_temp.server(format('UPDATE metas_preventista SET producto_ids = ARRAY[%s, %s]::bigint[] WHERE id = %s', v_prod1, v_prod2, v_meta));
    IF v_r NOT LIKE '23503%' THEN
      v_fallas := v_fallas || ('M1 · la edición de una meta con un producto de la 2 entró: ' || v_r);
    END IF;
  END IF;

  -- M3: el producto de la meta no se borra; el libre sí (M4).
  v_r := pg_temp.como_usuario(v_adm, 1, format('DELETE FROM productos WHERE id = %s RETURNING id::text', v_prod1b));
  SELECT count(*) INTO v_n FROM productos WHERE id = v_prod1b;
  IF v_n <> 1 THEN
    v_fallas := v_fallas || ('M3 · se borró un producto que está en una meta: ' || v_r);
  ELSIF v_r NOT LIKE '23503%' OR v_r NOT LIKE '%#' || v_meta || '%' THEN
    v_fallas := v_fallas || ('M3 · el borrado de un producto en una meta no dice cuál: ' || v_r);
  END IF;
  v_r := pg_temp.como_usuario(v_adm, 1, format('DELETE FROM productos WHERE id = %s RETURNING id::text', v_prod_lib));
  SELECT count(*) INTO v_n FROM productos WHERE id = v_prod_lib;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || ('M4 · un producto sin metas ni historial no se borró: ' || v_r);
  END IF;

  -- -------------------------------------------------------------------- L6 -
  -- Sin nada roto, los dos checks dan 0; con un pedazo y una meta que se escapan de sus
  -- triggers (apagados sólo para armarlos, todo se deshace), dan 1.
  v_aud := public.auditoria_integridad();
  IF pg_temp.check_de(v_aud, 'PAGO-B') IS DISTINCT FROM 0 OR pg_temp.check_de(v_aud, 'META-A') IS DISTINCT FROM 0 THEN
    v_fallas := v_fallas || format('L6 · sin nada roto: PAGO-B %s, META-A %s (esperado 0 y 0)',
                                   pg_temp.check_de(v_aud, 'PAGO-B'), pg_temp.check_de(v_aud, 'META-A'));
  END IF;
  ALTER TABLE public.pagos DISABLE TRIGGER USER;
  ALTER TABLE public.metas_preventista DISABLE TRIGGER USER;
  -- La raíz, el último pago vivo de la 1 (el pedazo de L5); el padre, uno de la 2.
  INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, a_cuenta, pago_origen_id, pago_padre_id)
  VALUES (v_cli2, 1, 'efectivo', public._tablero_hoy(), 2, true, (SELECT max(id) FROM pagos WHERE sucursal_id = 1), v_p2);
  INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, producto_ids, valor_objetivo)
  VALUES (1, v_tra, date_trunc('month', public._tablero_hoy())::date,
          (date_trunc('month', public._tablero_hoy()) + interval '1 month - 1 day')::date, 'unidades', ARRAY[v_prod2], 10);
  ALTER TABLE public.pagos ENABLE TRIGGER USER;
  ALTER TABLE public.metas_preventista ENABLE TRIGGER USER;
  v_aud := public.auditoria_integridad();
  IF pg_temp.check_de(v_aud, 'PAGO-B') IS DISTINCT FROM 1 OR pg_temp.check_de(v_aud, 'META-A') IS DISTINCT FROM 1 THEN
    v_fallas := v_fallas || format('L6 · con un pedazo y una meta cruzados: PAGO-B %s, META-A %s (esperado 1 y 1)',
                                   pg_temp.check_de(v_aud, 'PAGO-B'), pg_temp.check_de(v_aud, 'META-A'));
  END IF;

  -- ----------------------------------------------------------------- P1..P6 -
  -- El admin que se edita (v_adm, de la 1) tiene otro admin activo (v_adm2, de la 1 y la 2), así
  -- que el guard del último admin no es lo que frena.
  v_adm2 := pg_temp.u('admin', 1);
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_adm2, 2, false);
  FOR v_t IN
    SELECT format('%s · %s: %s (esperado %s)', caso, que, s.visto, esperado) FROM (VALUES
        ('P1', 'el admin se cambia el nombre, el email y la zona', v_adm,
         format('UPDATE perfiles SET nombre = ''C6 yo'', email = ''c6-yo@ensayo.invalid'', zona = ''Z'' WHERE id = %L RETURNING id::text', v_adm),
         '42501 No podés editar tu propio usuario'),
        ('P2', 'el admin se baja a preventista', v_adm,
         format('UPDATE perfiles SET rol = ''preventista'' WHERE id = %L RETURNING id::text', v_adm),
         '42501 No podés editar tu propio usuario'),
        ('P3', 'el admin se da el extra de chofer', v_adm,
         format('INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (%L, 1, ''transportista'') RETURNING usuario_id::text', v_adm),
         '42501 No podés cambiar tus propios roles'),
        ('P4', 'el admin edita a un preventista de la 1', v_adm,
         format('UPDATE perfiles SET nombre = ''C6 otro'' WHERE id = %L RETURNING nombre', v_pre),
         'PASA C6 otro'),
        ('P4', 'el admin le da el extra de chofer a un preventista de la 1', v_adm,
         format('INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (%L, 1, ''transportista'') RETURNING rol', v_pre),
         'PASA transportista'),
        ('P4', 'el admin le saca ese extra', v_adm,
         format('DELETE FROM perfil_roles WHERE usuario_id = %L AND sucursal_id = 1 AND rol = ''transportista'' RETURNING rol', v_pre),
         'PASA transportista'),
        ('P5', 'asignar_usuario_sucursal (definer) suma la 2 a un preventista', v_adm2,
         format('SELECT (public.asignar_usuario_sucursal(%L, 2, false) IS NOT NULL)::text', v_pre),
         'PASA true'),
        ('P5', 'generar_codigo_vinculacion_bot', v_adm,
         'SELECT (public.generar_codigo_vinculacion_bot() IS NOT NULL)::text',
         'PASA true'),
        ('P6', 'el preventista se cambia el nombre', v_pre,
         format('UPDATE perfiles SET nombre = ''C6 yo'' WHERE id = %L RETURNING id::text', v_pre),
         'PASA')
      ) AS t(caso, que, u, sql, esperado),
      LATERAL (SELECT pg_temp.como_usuario(u, 1, sql) AS visto) s
     WHERE CASE WHEN esperado = 'PASA' THEN s.visto <> 'PASA' ELSE s.visto NOT LIKE esperado || '%' END
  LOOP
    v_fallas := v_fallas || v_t;
  END LOOP;
  -- P3 al revés: un extra propio que ya tenía (lo puso el server) no se lo quita.
  INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_adm, 1, 'transportista') ON CONFLICT DO NOTHING;
  v_r := pg_temp.como_usuario(v_adm, 1, format(
    'DELETE FROM perfil_roles WHERE usuario_id = %L AND sucursal_id = 1 RETURNING rol', v_adm));
  IF v_r NOT LIKE '42501 No podés cambiar tus propios roles%' THEN
    v_fallas := v_fallas || ('P3 · el admin se sacó su propio extra: ' || v_r);
  END IF;
  -- P4: el admin desactiva a otro (el chofer); queda un admin activo, el guard lo deja.
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'auth.users'::regclass AND attname = 'banned_until') THEN
    ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
  END IF;
  v_r := pg_temp.como_usuario(v_adm, 1, format('UPDATE perfiles SET activo = false WHERE id = %L RETURNING activo::text', v_tra));
  IF v_r <> 'PASA false' THEN
    v_fallas := v_fallas || ('P4 · el admin no pudo desactivar a otro: ' || v_r);
  END IF;
  -- P5: el server (service_role) edita al admin que firma.
  PERFORM pg_temp.como(v_adm, 1);
  EXECUTE 'SET LOCAL ROLE service_role';
  BEGIN
    UPDATE perfiles SET zona = 'C6 server' WHERE id = v_adm;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('P5 · el server no pudo editar el perfil del admin: ' || SQLSTATE || ' ' || SQLERRM);
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.como(NULL, NULL);
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'auth.users'::regclass AND attname = 'banned_until') THEN
    ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;
  END IF;
  IF (SELECT nombre FROM perfiles WHERE id = v_pre) IS DISTINCT FROM 'C6 otro'
     OR (SELECT rol FROM perfiles WHERE id = v_adm) <> 'admin'
     OR (SELECT zona FROM perfiles WHERE id = v_adm) IS DISTINCT FROM 'C6 server' THEN
    v_fallas := v_fallas || format('P · cómo quedaron: nombre del preventista %s, rol del admin %s, zona del admin %s',
      (SELECT nombre FROM perfiles WHERE id = v_pre), (SELECT rol FROM perfiles WHERE id = v_adm),
      (SELECT zona FROM perfiles WHERE id = v_adm));
  END IF;

  -- -------------------------------------------------------------------- E1 -
  IF to_regprocedure('public.emails_de_usuarios(uuid[])') IS NULL THEN
    v_fallas := v_fallas || 'E1 · no existe emails_de_usuarios(uuid[])'::text;
  ELSE
    FOR v_t IN
      SELECT format('%s pide el de %s: %s (esperado %s)', quien, de_quien, s.visto, esperado) FROM (VALUES
          ('admin', v_adm, 'preventista', v_pre, 'PASA 1'),
          ('encargado', v_enc, 'preventista', v_pre, 'PASA 1'),
          ('encargado', v_enc, 'chofer', v_tra, 'PASA 1'),
          ('preventista', v_pre, 'chofer', v_tra, 'PASA 0'),
          ('preventista', v_pre, 'sí mismo', v_pre, 'PASA 1'),
          ('chofer', v_tra, 'encargado', v_enc, 'PASA 0'),
          ('encargado desactivado', v_des, 'preventista', v_pre, 'PASA 0')
        ) AS t(quien, u, de_quien, otro, esperado),
        LATERAL (SELECT pg_temp.como_usuario(u, 1, format(
          'SELECT count(*)::text FROM public.emails_de_usuarios(ARRAY[%L]::uuid[]) e WHERE e.email = ''c6-'' || e.id || ''@ensayo.invalid''', otro)) AS visto) s
       WHERE s.visto <> esperado
    LOOP
      v_fallas := v_fallas || ('E1 · ' || v_t);
    END LOOP;
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK' USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
