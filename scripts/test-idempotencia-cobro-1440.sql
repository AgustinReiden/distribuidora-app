-- Ensayo de la migración del ledger de cobros, la clave vieja de pagos y los checks de la foto
-- y de los pedazos (#1399, puntos 2 y 3 de #1440).
--
--   I1 · Replay legítimo de registrar_pagos_pedido: la misma clave del mismo admin devuelve lo
--        guardado con idempotent_replay y no carga un segundo pago.
--   I2 · Replay legítimo de registrar_pago_cliente_fifo (un wrapper de la 167), igual que I1.
--   I3 · La clave de I1 en otra operación (el FIFO): 22023 y no se registra nada.
--   I4 · La clave de I1 en la misma operación pero de otro usuario (el transportista): 22023 y
--        no se registra nada.
--   E1 · Cada función que llama a pago_solicitud_abrir le pasa su propio nombre, así que su
--        replay es siempre de la misma operación.
--   C1 · #1399: los dos triggers ya no miran client_request_id y el índice no está.
--   C2 · #1399: el CHECK no deja cargar la clave en un pago nuevo (23514).
--   A0 · Los cinco checks nuevos están en auditoria_integridad() y dan 0.
--   A1 · REND-A muerde con una foto de una rendición abierta y con una cerrada sin totales.
--   A2 · REND-B muerde con un pago en la foto de dos rendiciones cerradas.
--   A3 · REND-C muerde con un pago posterior al corte de su foto.
--   A4 · REND-D muerde con un crédito de NC en una foto.
--   A5 · PAGO-A da 0 con un pedazo bien nacido y con su padre borrado, y muerde con otra raíz.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina
-- siempre en una excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la
-- migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT, y con
-- `SELECT set_config('ensayo_1440.previo', '1', true);` adelante: así no corre A1 a A5. El
-- DROP INDEX y el CHECK de la migración bloquean pagos hasta el final del ensayo, y A1 a A5
-- llaman nueve veces a auditoria_integridad(), de 3 s cada una. Después de aplicar, solo y
-- entero. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ', por I3, I4, C1, C2 y A0 (sin
-- los checks, A1 a A5 no corren).
--
-- Fixtures: una sucursal activa con un admin y un transportista base activos, y la caja de hoy
-- abierta. El resto nace en el ensayo. Las rendiciones van en 2099.

CREATE OR REPLACE FUNCTION pg_temp.t_como(p_usuario uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_usuario, 'role', 'authenticated')::text, true),
         set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$fn$;

-- Las violaciones de un check, o NULL si auditoria_integridad() no lo tiene.
CREATE OR REPLACE FUNCTION pg_temp.t_viol(p_id text)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT (c->>'violaciones')::bigint
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
   WHERE c->>'id' = p_id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_rendicion(p_suc bigint, p_tr uuid, p_fecha date, p_estado text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.rendiciones_control (fecha, transportista_id, sucursal_id, estado)
  VALUES (p_fecha, p_tr, p_suc, p_estado)
  RETURNING id;
$fn$;

-- Una fila de foto a mano: lo que el trigger nunca escribiría.
CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_rend bigint, p_pago bigint, p_forma text, p_corte bigint)
RETURNS void LANGUAGE sql AS $fn$
  INSERT INTO public.rendicion_pagos_confirmados (
    rendicion_id, pago_id, cliente_id, usuario_id, monto, forma_pago, es_entrega_del_dia, ultimo_pago_id)
  SELECT p_rend, pg.id, pg.cliente_id, pg.usuario_id, pg.monto, p_forma, false, p_corte
    FROM public.pagos pg WHERE pg.id = p_pago;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_tr     uuid;
  v_adm    uuid;
  v_cli    bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_pago   bigint;
  v_hijo   bigint;
  v_r      bigint;
  v_r2     bigint;
  v_j1     jsonb;
  v_j2     jsonb;
  v_n      bigint;
  v_txt    text;
  v_k      uuid;
  v_fallas text[] := '{}';
  v_hoy    CONSTANT date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  F        CONSTANT date := DATE '2099-05-11';
  v_metodo CONSTANT jsonb := '[{"forma_pago": "efectivo", "monto": 40}]';
BEGIN
  SELECT s.id, a.usuario_id, adm.usuario_id
    INTO v_suc, v_tr, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y un transportista';
  END IF;

  PERFORM pg_temp.t_como(v_adm, v_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  IF public.ultima_fecha_caja_cerrada(v_suc) >= v_hoy THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: la caja de hoy de la sucursal % ya está cerrada', v_suc;
  END IF;

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1440', 'ZZ ensayo 1440', 'Ensayo 1440', v_suc)
  RETURNING id INTO v_cli;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1440', 100, 1000, 60, v_suc)
  RETURNING id INTO v_prod;
  v_j1 := public.crear_pedido_completo(
    v_cli, 100, v_adm,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'precio_unitario', 100)),
    'ensayo 1440');
  IF NOT COALESCE((v_j1->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no se pudo crear el pedido: %', v_j1;
  END IF;
  v_ped := (v_j1->>'pedido_id')::bigint;

  -- I1 a I4 · el ledger
  BEGIN
    v_k := gen_random_uuid();
    v_j1 := public.registrar_pagos_pedido(v_ped, v_metodo, v_hoy, 'ensayo 1440', NULL, v_k);
    v_j2 := public.registrar_pagos_pedido(v_ped, v_metodo, v_hoy, 'ensayo 1440', NULL, v_k);
    SELECT count(*) INTO v_n FROM pagos WHERE pedido_id = v_ped;
    IF v_j2->>'idempotent_replay' IS DISTINCT FROM 'true' OR (v_j2 - 'idempotent_replay') IS DISTINCT FROM v_j1
       OR v_n <> 1 THEN
      v_fallas := v_fallas || format('I1 replay de registrar_pagos_pedido: %s pagos, segunda respuesta %s', v_n, v_j2);
    END IF;

    -- I3 · la misma clave en otra operación
    BEGIN
      v_j2 := public.registrar_pago_cliente_fifo(v_cli, 40, 'efectivo', v_hoy, NULL, 'ensayo 1440', v_k);
      v_fallas := v_fallas || format('I3 la clave de un cobro de boleta entró al FIFO y devolvió %s', v_j2);
    EXCEPTION WHEN SQLSTATE '22023' THEN
      IF SQLERRM NOT LIKE 'La clave % ya es de otra solicitud%' THEN
        v_fallas := v_fallas || format('I3 dio 22023 por otra cosa: %s', SQLERRM);
      END IF;
    END;

    -- I4 · la misma clave y operación, de otro usuario
    BEGIN
      PERFORM pg_temp.t_como(v_tr, v_suc);
      v_j2 := public.registrar_pagos_pedido(v_ped, v_metodo, v_hoy, 'ensayo 1440', NULL, v_k);
      v_fallas := v_fallas || format('I4 la clave del admin le devolvió al transportista %s', v_j2);
    EXCEPTION WHEN SQLSTATE '22023' THEN
      IF SQLERRM NOT LIKE 'La clave % ya es de otra solicitud%' THEN
        v_fallas := v_fallas || format('I4 dio 22023 por otra cosa: %s', SQLERRM);
      END IF;
    END;
    PERFORM pg_temp.t_como(v_adm, v_suc);

    SELECT count(*) INTO v_n FROM pagos WHERE cliente_id = v_cli;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('I3-I4 dejaron %s pagos del cliente, no 1', v_n);
    END IF;

    -- I2 · replay legítimo del FIFO, con otra clave
    v_k := gen_random_uuid();
    v_j1 := public.registrar_pago_cliente_fifo(v_cli, 25, 'efectivo', v_hoy, NULL, 'ensayo 1440', v_k);
    v_j2 := public.registrar_pago_cliente_fifo(v_cli, 25, 'efectivo', v_hoy, NULL, 'ensayo 1440', v_k);
    SELECT count(*) INTO v_n FROM pagos WHERE cliente_id = v_cli;
    IF v_j2->>'idempotent_replay' IS DISTINCT FROM 'true' OR (v_j2 - 'idempotent_replay') IS DISTINCT FROM v_j1
       OR v_n <> 2 THEN
      v_fallas := v_fallas || format('I2 replay del FIFO: %s pagos del cliente, segunda respuesta %s', v_n, v_j2);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
  EXCEPTION
    WHEN SQLSTATE 'ZZ440' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('I1-I4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E1 · cada llamador pasa su propio nombre
  SELECT string_agg(format('%s pasa %s', f.proname, COALESCE(x.op, '(nada)')), ', ')
    INTO v_txt
    FROM pg_proc f
    CROSS JOIN LATERAL (SELECT substring(f.prosrc FROM 'pago_solicitud_abrir\([^,]+,\s*''([a-z_]+)''') AS op) x
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.proname <> 'pago_solicitud_abrir'
     AND f.prosrc ~ 'pago_solicitud_abrir\('
     AND x.op IS DISTINCT FROM f.proname::text;
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('E1 llamadores que no pasan su nombre: %s', v_txt);
  END IF;
  SELECT count(*) INTO v_n FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace AND f.proname <> 'pago_solicitud_abrir'
     AND f.prosrc ~ 'pago_solicitud_abrir\(';
  IF v_n <> 7 THEN
    v_fallas := v_fallas || format('E1 pago_solicitud_abrir tiene %s llamadores, no los 7 que se leyeron', v_n);
  END IF;

  -- C1 · las ramas y el índice de #1399
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.guard_pago_fecha_cerrada()'::regprocedure) ~ 'client_request_id'
     OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.pagos_rechazar_pedido_de_baja()'::regprocedure) ~ 'client_request_id' THEN
    v_fallas := v_fallas || 'C1 un trigger de pagos sigue mirando client_request_id'::text;
  END IF;
  IF to_regclass('public.idx_pagos_client_request_id') IS NOT NULL THEN
    v_fallas := v_fallas || 'C1 idx_pagos_client_request_id sigue en pie'::text;
  END IF;

  -- C2 · el CHECK congela la columna
  BEGIN
    INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas, client_request_id)
    VALUES (v_cli, 10, 'efectivo', v_hoy, v_adm, v_suc, 'ensayo 1440', gen_random_uuid());
    v_fallas := v_fallas || 'C2 un pago nuevo entró con client_request_id'::text;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
  EXCEPTION
    WHEN SQLSTATE 'ZZ440' THEN NULL;
    WHEN check_violation THEN
      IF SQLERRM NOT LIKE '%pagos_client_request_id_historico%' THEN
        v_fallas := v_fallas || format('C2 lo frenó otro CHECK: %s', SQLERRM);
      END IF;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- A0 · los checks nuevos, en 0
  v_j1 := public.auditoria_integridad();
  SELECT string_agg(format('%s = %s', i, COALESCE(c->>'violaciones', 'no está')), ', ')
    INTO v_txt
    FROM unnest(ARRAY['REND-A', 'REND-B', 'REND-C', 'REND-D', 'PAGO-A']) i
    LEFT JOIN jsonb_array_elements(v_j1->'checks') c ON c->>'id' = i
   WHERE c->>'violaciones' IS DISTINCT FROM '0';
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('A0 checks nuevos que no dan 0: %s', v_txt);
  ELSIF current_setting('ensayo_1440.previo', true) = '1' THEN
    NULL;
  ELSE
    -- El pago con el que se ensucian la foto y la cadena.
    INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas)
    VALUES (v_cli, 10, 'efectivo', v_hoy, v_adm, v_suc, 'ensayo 1440')
    RETURNING id INTO v_pago;

    -- A1 · REND-A: foto de una abierta, y una cerrada sin totales
    BEGIN
      v_r := pg_temp.t_rendicion(v_suc, v_tr, F, 'pendiente');
      PERFORM pg_temp.t_foto(v_r, v_pago, 'efectivo', v_pago);
      v_n := pg_temp.t_viol('REND-A');
      IF v_n IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('A1 REND-A con la foto de una abierta dio %s, no 1', v_n);
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
    EXCEPTION
      WHEN SQLSTATE 'ZZ440' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A1 dio %s: %s', SQLSTATE, SQLERRM);
    END;
    BEGIN
      v_r := pg_temp.t_rendicion(v_suc, v_tr, F, 'confirmada');
      v_n := pg_temp.t_viol('REND-A');
      IF v_n IS DISTINCT FROM 0 THEN
        v_fallas := v_fallas || format('A1 REND-A con una cerrada por el trigger dio %s, no 0', v_n);
      END IF;
      UPDATE rendiciones_control SET total_entregado_confirmado = NULL WHERE id = v_r;
      v_n := pg_temp.t_viol('REND-A');
      IF v_n IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('A1 REND-A con una cerrada sin totales dio %s, no 1', v_n);
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
    EXCEPTION
      WHEN SQLSTATE 'ZZ440' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A1b dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- A2 · REND-B: el mismo pago en dos fotos cerradas
    BEGIN
      v_r := pg_temp.t_rendicion(v_suc, v_tr, F, 'confirmada');
      v_r2 := pg_temp.t_rendicion(v_suc, v_tr, F + 1, 'confirmada');
      PERFORM pg_temp.t_foto(v_r, v_pago, 'efectivo', v_pago);
      PERFORM pg_temp.t_foto(v_r2, v_pago, 'efectivo', v_pago);
      v_n := pg_temp.t_viol('REND-B');
      IF v_n IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('A2 REND-B dio %s, no 1', v_n);
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
    EXCEPTION
      WHEN SQLSTATE 'ZZ440' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A2 dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- A3 · REND-C: un pago que nació después del corte
    BEGIN
      v_r := pg_temp.t_rendicion(v_suc, v_tr, F, 'confirmada');
      PERFORM pg_temp.t_foto(v_r, v_pago, 'efectivo', v_pago - 1);
      v_n := pg_temp.t_viol('REND-C');
      IF v_n IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('A3 REND-C dio %s, no 1', v_n);
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
    EXCEPTION
      WHEN SQLSTATE 'ZZ440' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A3 dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- A4 · REND-D: un crédito de NC en la foto
    BEGIN
      v_r := pg_temp.t_rendicion(v_suc, v_tr, F, 'confirmada');
      PERFORM pg_temp.t_foto(v_r, v_pago, 'nota_credito', v_pago);
      v_n := pg_temp.t_viol('REND-D');
      IF v_n IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('A4 REND-D dio %s, no 1', v_n);
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
    EXCEPTION
      WHEN SQLSTATE 'ZZ440' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A4 dio %s: %s', SQLSTATE, SQLERRM);
    END;

    -- A5 · PAGO-A: un pedazo bien nacido, su padre borrado, y una raíz cruzada
    BEGIN
      INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas,
                         pago_origen_id, pago_padre_id)
      VALUES (v_cli, 4, 'efectivo', v_hoy, v_adm, v_suc, 'ensayo 1440', v_pago, v_pago)
      RETURNING id INTO v_hijo;
      v_n := pg_temp.t_viol('PAGO-A');
      IF v_n IS DISTINCT FROM 0 THEN
        v_fallas := v_fallas || format('A5 PAGO-A con un pedazo bien nacido dio %s, no 0', v_n);
      END IF;

      -- Un pedazo de un pedazo lleva la raíz del abuelo (#1359): así da 0, y con el
      -- padre de raíz, 1.
      INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas,
                         pago_origen_id, pago_padre_id)
      VALUES (v_cli, 1, 'efectivo', v_hoy, v_adm, v_suc, 'ensayo 1440', v_pago, v_hijo);
      INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas,
                         pago_origen_id, pago_padre_id)
      VALUES (v_cli, 1, 'efectivo', v_hoy, v_adm, v_suc, 'ensayo 1440', v_hijo, v_hijo);
      v_n := pg_temp.t_viol('PAGO-A');
      IF v_n IS DISTINCT FROM 1 THEN
        v_fallas := v_fallas || format('A5 PAGO-A con un nieto bien nacido y otro con el padre de raíz dio %s, no 1', v_n);
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
    EXCEPTION
      WHEN SQLSTATE 'ZZ440' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A5 dio %s: %s', SQLSTATE, SQLERRM);
    END;
    BEGIN
      INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas,
                         pago_origen_id, pago_padre_id)
      VALUES (v_cli, 4, 'efectivo', v_hoy, v_adm, v_suc, 'ensayo 1440', v_pago, v_pago);
      DELETE FROM pagos WHERE id = v_pago;
      v_n := pg_temp.t_viol('PAGO-A');
      IF v_n IS DISTINCT FROM 0 THEN
        v_fallas := v_fallas || format('A5b PAGO-A con el padre borrado dio %s, no 0', v_n);
      END IF;
      RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ440';
    EXCEPTION
      WHEN SQLSTATE 'ZZ440' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A5b dio %s: %s', SQLSTATE, SQLERRM);
    END;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  IF current_setting('ensayo_1440.previo', true) = '1' THEN
    RAISE EXCEPTION 'ENSAYO OK · I1 I2 I3 I4 E1 C1 C2 A0 (previo: A1 a A5 corren después de aplicar)';
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · I1 I2 I3 I4 E1 C1 C2 A0 A1 A2 A3 A4 A5';
END
$ensayo$;
