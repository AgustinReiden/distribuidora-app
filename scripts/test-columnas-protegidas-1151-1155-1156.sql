-- Ensayo de #1155 (pedidos.fecha), #1156 (descuento, límite y días de crédito
-- del cliente, sólo admin) y #1151 punto 5 (clientes.saldo_cuenta no se
-- escribe por REST).
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consumen el pago de S2 y el INSERT rechazado de K5): un único DO que termina
-- SIEMPRE en una excepción, y cada caso corre en su propio sub-bloque que se
-- revierte al terminar. Los INSERT de clientes pasan id y codigo explícitos
-- (negativos), para no consumir clientes_id_seq ni clientes_codigo_seq.
--
-- Simula PostgREST como test-grants-rest-1134-1135.sql: `SET LOCAL ROLE
-- authenticated`, el `sub` de un perfil real en request.jwt.claims y la
-- sucursal en x-sucursal-id. Usa una sucursal activa con admin, encargado y
-- preventista activos.
--
-- Sin la migración tiene que FALLAR en F1, K1, K2b, K3 y S1. F2, F3, K2, K4,
-- K5 y S2 pasan antes y después (regresiones). Con la migración (inline antes
-- del DO) tiene que dar 'ENSAYO OK'.
--
-- #1155 · pedidos.fecha
--   F1  · un preventista sin rol extra de transportista PATCH de
--         pedidos.fecha + 1 en un pedido propio → 42501 que nombra 'fecha'
--   F2  · el mismo PATCH con notas y la MISMA fecha (lo que manda
--         ModalEditarPedido) → OK
--   F3  · admin y encargado cambian la fecha → OK
-- #1156 · crédito del cliente
--   K1  · encargado PATCH descuento_porcentaje = 10, limite_credito = 1000 y
--         dias_credito = 15, cada uno por separado → 42501
--   K2  · encargado PATCH razon_social con las tres columnas idénticas a la
--         fila viva → OK
--   K2b · el admin cambia limite_credito; el encargado manda un PATCH de
--         direccion que reenvía el limite_credito viejo (el payload del front
--         antes del arreglo de ClientesContainer) → 42501
--   K3  · un preventista INSERT de un cliente con descuento 100 → 42501; con
--         0 / 0 / 30 → OK, en su zona
--   K4  · el admin PATCH e INSERT con descuento, límite y días → OK
--   K5  · encargado INSERT en cliente_descuentos_categoria → 42501 (ya pasaba:
--         la tabla es sólo del admin)
-- #1151.5 · saldo
--   S1  · admin y encargado PATCH saldo_cuenta + 1 → 42501; admin INSERT de un
--         cliente con saldo_cuenta 50 → 42501
--   S2  · admin INSERT y DELETE de un pago por REST: el saldo lo mueve
--         actualizar_saldo_cliente (DEFINER), sin error
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenar un rollback).
--
--   psql "$DATABASE_URL" -f scripts/test-columnas-protegidas-1151-1155-1156.sql

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_admin   uuid;
  v_enc     uuid;
  v_prev    uuid;
  v_zona    bigint;
  v_cli     bigint;
  v_ped     bigint;
  v_err     text;
  v_errs    text[];
  v_res     text;
  v_n       numeric;
  v_n2      numeric;
  v_t       text;
  r         record;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, a.usuario_id, e.usuario_id, p.usuario_id
    INTO v_suc, v_admin, v_enc, v_prev
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado' ORDER BY us.usuario_id LIMIT 1) e ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista' ORDER BY us.usuario_id LIMIT 1) p ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con admin, encargado y preventista activos';
  END IF;
  SELECT zona_id INTO v_zona FROM preventista_zonas WHERE perfil_id = v_prev AND sucursal_id = v_suc ORDER BY zona_id LIMIT 1;
  -- Un cliente activo, no reservado y sin crédito cargado, para K y S.
  SELECT id INTO v_cli FROM clientes
   WHERE sucursal_id = v_suc AND activo AND NOT reservado_admin
     AND descuento_porcentaje = 0 AND COALESCE(limite_credito, 0) = 0 AND COALESCE(dias_credito, 30) = 30
   ORDER BY id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo de la sucursal % con descuento 0, límite 0 y días 30', v_suc;
  END IF;
  SELECT id INTO v_ped FROM pedidos WHERE sucursal_id = v_suc AND estado <> 'cancelado' ORDER BY id DESC LIMIT 1;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  -- Filas afectadas como PostgREST, o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest_n(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Un SELECT escalar como PostgREST, o 'ERR SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest_val(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN COALESCE(v, '(null)');
  EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- INSERT de un cliente con id y codigo explícitos (no consume secuencias).
  CREATE FUNCTION pg_temp.alta(p_id bigint, p_suc bigint, p_zona bigint, p_desc numeric, p_lim numeric, p_dias int,
                               p_saldo numeric DEFAULT 0) RETURNS text LANGUAGE sql AS $f$
    SELECT format('INSERT INTO public.clientes (id, codigo, razon_social, nombre_fantasia, direccion, sucursal_id, zona_id, '
                  'descuento_porcentaje, limite_credito, dias_credito, saldo_cuenta) '
                  'VALUES (%s, %s, %L, %L, %L, %s, %s, %s, %s, %s, %s)',
                  p_id, p_id, 'ZZ ensayo 1156', 'ZZ ensayo 1156', 'Calle ensayo 1156', p_suc,
                  COALESCE(p_zona::text, 'NULL'), p_desc, p_lim, p_dias, p_saldo);
  $f$;

  -- ====================================================== #1155 · fecha =====
  -- F1 / F2 · el preventista dueño
  BEGIN
    SELECT pe.id, pe.usuario_id, pe.sucursal_id, pe.fecha INTO r
      FROM pedidos pe
      JOIN perfiles pf ON pf.id = pe.usuario_id AND pf.activo AND pf.rol = 'preventista'
      JOIN usuario_sucursales us ON us.usuario_id = pe.usuario_id AND us.sucursal_id = pe.sucursal_id
     WHERE NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pe.usuario_id AND pr.rol = 'transportista')
       AND pe.transportista_id IS DISTINCT FROM pe.usuario_id
       AND pe.estado <> 'cancelado'
     ORDER BY pe.id DESC LIMIT 1;
    IF r.id IS NULL THEN
      v_fallas := v_fallas || 'F1 · no hay pedido de un preventista sin rol de transportista'::text;
    ELSE
      PERFORM pg_temp.como(r.usuario_id, r.sucursal_id);
      v_err := pg_temp.rest_n(format('UPDATE public.pedidos SET fecha = fecha + 1 WHERE id = %s', r.id));
      IF COALESCE(v_err, '') NOT LIKE '42501%fecha%' THEN
        v_fallas := v_fallas || format('F1 · el preventista cambió la fecha de su pedido (tenía que dar 42501 con fecha): %s', v_err);
      END IF;
      v_err := pg_temp.rest_n(format('UPDATE public.pedidos SET notas = COALESCE(notas, %L) || %L, fecha = %L WHERE id = %s',
                                     '', ' [ensayo 1155]', r.fecha, r.id));
      IF v_err IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('F2 · el preventista no guarda notas con la misma fecha: %s', v_err);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('F1 · error inesperado: ' || SQLERRM);
  END;

  -- F3 · admin y encargado
  BEGIN
    FOREACH v_t IN ARRAY ARRAY['admin', 'encargado'] LOOP
      PERFORM pg_temp.como(CASE WHEN v_t = 'admin' THEN v_admin ELSE v_enc END, v_suc);
      v_err := pg_temp.rest_n(format('UPDATE public.pedidos SET fecha = fecha + 1 WHERE id = %s', v_ped));
      IF v_err IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('F3 · %s no cambia la fecha del pedido: %s', v_t, v_err);
      END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('F3 · error inesperado: ' || SQLERRM);
  END;

  -- ===================================================== #1156 · crédito ====
  -- K1 · el encargado no mueve ninguna de las tres
  BEGIN
    PERFORM pg_temp.como(v_enc, v_suc);
    v_errs := ARRAY[
      pg_temp.rest_n(format('UPDATE public.clientes SET descuento_porcentaje = 10 WHERE id = %s', v_cli)),
      pg_temp.rest_n(format('UPDATE public.clientes SET limite_credito = 1000 WHERE id = %s', v_cli)),
      pg_temp.rest_n(format('UPDATE public.clientes SET dias_credito = 15 WHERE id = %s', v_cli))];
    FOR i IN 1 .. 3 LOOP
      IF COALESCE(v_errs[i], '') NOT LIKE '42501%administrador%' THEN
        v_fallas := v_fallas || format('K1 · el encargado cambió %s (tenía que dar 42501): %s',
          (ARRAY['descuento_porcentaje', 'limite_credito', 'dias_credito'])[i], v_errs[i]);
      END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K1 · error inesperado: ' || SQLERRM);
  END;

  -- K2 · el PATCH del modal reenvía los valores vivos: pasa
  BEGIN
    PERFORM pg_temp.como(v_enc, v_suc);
    v_err := pg_temp.rest_n(format(
      'UPDATE public.clientes SET razon_social = razon_social, descuento_porcentaje = 0, limite_credito = %s, dias_credito = %s WHERE id = %s',
      COALESCE((SELECT limite_credito::text FROM clientes WHERE id = v_cli), 'NULL'),
      COALESCE((SELECT dias_credito::text FROM clientes WHERE id = v_cli), 'NULL'), v_cli));
    IF v_err IS DISTINCT FROM '1' THEN
      v_fallas := v_fallas || format('K2 · el encargado no guarda un PATCH con el crédito idéntico: %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K2 · error inesperado: ' || SQLERRM);
  END;

  -- K2b · el caché viejo: el admin subió el límite, el encargado reenvía el de
  -- antes
  BEGIN
    SELECT COALESCE(limite_credito, 0) INTO v_n FROM clientes WHERE id = v_cli;
    PERFORM pg_temp.como(v_admin, v_suc);
    v_err := pg_temp.rest_n(format('UPDATE public.clientes SET limite_credito = %s WHERE id = %s', v_n + 500, v_cli));
    IF v_err IS DISTINCT FROM '1' THEN
      v_fallas := v_fallas || format('K2b · el admin no cambia el límite: %s', v_err);
    ELSE
      PERFORM pg_temp.como(v_enc, v_suc);
      v_err := pg_temp.rest_n(format('UPDATE public.clientes SET direccion = direccion, limite_credito = %s WHERE id = %s', v_n, v_cli));
      IF COALESCE(v_err, '') NOT LIKE '42501%' THEN
        v_fallas := v_fallas || format('K2b · el PATCH del encargado con el límite viejo pisó el del admin (tenía que dar 42501): %s', v_err);
      END IF;
      IF (SELECT limite_credito FROM clientes WHERE id = v_cli) IS DISTINCT FROM v_n + 500 THEN
        v_fallas := v_fallas || 'K2b · el límite del admin no quedó'::text;
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K2b · error inesperado: ' || SQLERRM);
  END;

  -- K3 · el alta del preventista
  BEGIN
    PERFORM pg_temp.como(v_prev, v_suc);
    v_err := pg_temp.rest_n(pg_temp.alta(-911561, v_suc, v_zona, 100, 0, 30));
    IF COALESCE(v_err, '') NOT LIKE '42501%administrador%' THEN
      v_fallas := v_fallas || format('K3 · el preventista dio de alta un cliente con descuento 100 (tenía que dar 42501): %s', v_err);
    END IF;
    v_err := pg_temp.rest_n(pg_temp.alta(-911562, v_suc, v_zona, 0, 0, 30));
    IF v_err IS DISTINCT FROM '1' THEN
      v_fallas := v_fallas || format('K3 · el preventista no da de alta un cliente con los defaults (zona %s): %s', v_zona, v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K3 · error inesperado: ' || SQLERRM);
  END;

  -- K4 · el admin sí
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_errs := ARRAY[
      pg_temp.rest_n(format('UPDATE public.clientes SET descuento_porcentaje = 10, limite_credito = 1000, dias_credito = 15 WHERE id = %s', v_cli)),
      pg_temp.rest_n(pg_temp.alta(-911563, v_suc, NULL, 5, 100, 15))];
    IF v_errs[1] IS DISTINCT FROM '1' OR v_errs[2] IS DISTINCT FROM '1' THEN
      v_fallas := v_fallas || format('K4 · el admin: PATCH %s, INSERT %s', v_errs[1], v_errs[2]);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K4 · error inesperado: ' || SQLERRM);
  END;

  -- K5 · cliente_descuentos_categoria ya era sólo del admin
  BEGIN
    PERFORM pg_temp.como(v_enc, v_suc);
    v_err := pg_temp.rest_n(format(
      'INSERT INTO public.cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje) VALUES (%s, %L, 5)',
      v_cli, 'ZZ ensayo 1156'));
    IF COALESCE(v_err, '') NOT LIKE '42501%' THEN
      v_fallas := v_fallas || format('K5 · el encargado insertó un descuento por categoría: %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K5 · error inesperado: ' || SQLERRM);
  END;

  -- ===================================================== #1151.5 · saldo ====
  -- S1 · nadie escribe el saldo por REST
  BEGIN
    FOREACH v_t IN ARRAY ARRAY['admin', 'encargado'] LOOP
      PERFORM pg_temp.como(CASE WHEN v_t = 'admin' THEN v_admin ELSE v_enc END, v_suc);
      v_err := pg_temp.rest_n(format('UPDATE public.clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + 1 WHERE id = %s', v_cli));
      IF COALESCE(v_err, '') NOT LIKE '42501%saldo%' THEN
        v_fallas := v_fallas || format('S1 · %s PATCH saldo_cuenta (tenía que dar 42501): %s', v_t, v_err);
      END IF;
    END LOOP;
    PERFORM pg_temp.como(v_admin, v_suc);
    v_err := pg_temp.rest_n(pg_temp.alta(-911564, v_suc, NULL, 0, 0, 30, 50));
    IF COALESCE(v_err, '') NOT LIKE '42501%saldo%' THEN
      v_fallas := v_fallas || format('S1 · admin INSERT de un cliente con saldo 50 (tenía que dar 42501): %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('S1 · error inesperado: ' || SQLERRM);
  END;

  -- S2 · el saldo lo sigue moviendo el pago (trigger DEFINER)
  BEGIN
    SELECT COALESCE(saldo_cuenta, 0) INTO v_n FROM clientes WHERE id = v_cli;
    PERFORM pg_temp.como(v_admin, v_suc);
    v_res := pg_temp.rest_val(format(
      'WITH i AS (INSERT INTO public.pagos (cliente_id, monto, forma_pago, usuario_id, sucursal_id, notas) VALUES (%s, 1, %L, %L, %s, %L) RETURNING id) SELECT id::text FROM i',
      v_cli, 'efectivo', v_admin, v_suc, 'ensayo 1156'));
    SELECT COALESCE(saldo_cuenta, 0) INTO v_n2 FROM clientes WHERE id = v_cli;
    IF v_res LIKE 'ERR%' OR v_n2 <> v_n - 1 THEN
      v_fallas := v_fallas || format('S2 · admin INSERT pagos por REST: %s, saldo %s → %s', v_res, v_n, v_n2);
    ELSE
      v_err := pg_temp.rest_n(format('DELETE FROM public.pagos WHERE id = %s', v_res));
      SELECT COALESCE(saldo_cuenta, 0) INTO v_n2 FROM clientes WHERE id = v_cli;
      IF v_err IS DISTINCT FROM '1' OR v_n2 <> v_n THEN
        v_fallas := v_fallas || format('S2 · admin DELETE pagos por REST: %s, saldo %s → %s', v_err, v_n, v_n2);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('S2 · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió. Con ensayo.continuar = '1' el
  -- OK sale como NOTICE: el bloque ya se revirtió y quien encadena el ensayo
  -- cierra la transacción con su propio error.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  IF v_t LIKE 'ENSAYO OK%' AND current_setting('ensayo.continuar', true) = '1' THEN
    RAISE NOTICE '%', v_t;
  ELSE
    RAISE EXCEPTION '%', v_t;
  END IF;
 END;
END
$ensayo$;
