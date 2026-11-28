-- Ensayo de la migración NNN_ola3_t5_reglas_rendicion (tarjeta T5 de la ola 3, #1690; D6 a D9).
--
-- Un único DO que arma sus propios datos (gente, clientes y boletas nuevas en la sucursal 1, y un
-- chofer de la 2) y termina SIEMPRE en una excepción (ENSAYO OK / ENSAYO FALLÓ): no deja rastro.
-- Corre sobre la base de CI sin datos. Sin la migración falla (D6 ya en el primer cobro); con
-- ella, ENSAYO OK. Usa el día argentino (`_tablero_hoy()`), nunca CURRENT_DATE. «Caja» es lo que
-- _rendicion_pagos le da a cada uno.
--
-- Gente: A, B, C, D, F, G, H, K, L, M choferes de la 1; X2 chofer de la 2; IN chofer de la 1
-- desactivado; E y E2 encargados de la 1; AD admin de la 1. N tiene ficha de empleado (y M, la suya).
--
--   D6 · A cobra $ 10.000 y AD le confirma la rendición de hoy. Después B cobra $ 30.000: entran
--        (B 30.000; A sigue en 10.000). A no puede cobrar $ 500 más (42501). E cobra $ 2.000 en la
--        oficina por el FIFO de la ficha y $ 1.000 con el pago masivo, a su nombre: entran (E 3.000).
--        E entrega y cobra en masivo una boleta de B ($ 700, B 30.700). AD le cambia la forma a un
--        cobro de B y anula otro ($ 100), pero no a uno de A (42501). E no puede cobrar en masivo a
--        nombre de A (42501). La caja de A cierra hoy; la de B, nunca;
--        la de la sucursal, hoy.
--   B1 · marcar_rendicion_controlada ya no existe.
--   D8 · D cobra $ 10.000; E la marca en disconformidad. control_rendicion_cerrado da true, y un
--        gasto de $ 300 cargado desde Gastos a esa rendición se rechaza («ya está cerrada»).
--   B2 · consultar_control_rendicion: la disconformidad de D está controlada; una fila «pendiente»
--        de C, no.
--   P2 · 1601-b2: IN (desactivado) no consulta control_rendicion_cerrado, ultima_fecha_caja_cerrada
--        ni rendicion_dia_cerrada (42501).
--   B6 · F: un pedido de hace 120 días entregado hoy ($ 7.000) cuenta en la jornada de hoy, y un
--        cancelado de hoy vale lo que tenía al cancelarse ($ 5.000, la foto), no su total_real
--        ($ 3.000). El detalle del día trae los dos.
--   B3 · 1564-b3: las jornadas de X2 (otra sucursal) no traen su nombre; las de F, sí.
--   B7 · G tiene un pago al personal de $ 100 de su rendición. Se revierte y se carga otro de
--        $ 100 (la suma sigue en 100): confirmar con la huella de antes se rechaza («pagos al
--        personal cambiaron»); con la nueva, pasa. obtener_resumen_rendiciones da las huellas.
--   M1 · H cobró $ 8.000 en efectivo; E la marca en disconformidad y AD corrige el cobro a
--        transferencia. Resolver con lo cobrado de antes (efectivo 8.000) se rechaza («los cobros
--        cambiaron»); con lo de ahora, pasa.
--   GC · GTO-C: M cobró $ 1.000; resolver con $ 1.500 imputados se rechaza («supera»).
--   S2 · SEG-2: M resuelta con $ 300 a cargo de N, $ 200 a cargo de M y $ 100 de robo o pérdida.
--        M ve las tres líneas sin quién las cargó ni el rubro, y la observación sólo de la suya; AD
--        las ve enteras.
--   G7 · GTO-7 / D9: E cobró en la oficina (D6). E no carga un gasto a su propia rendición (42501),
--        E2 tampoco a la de E (es de un encargado), AD sí ($ 400). AD no se carga uno a la suya
--        desde Gastos (42501), E sí a la de B ($ 250: B entrega 30.450).
--   D7 · AD cobra $ 5.000 en la oficina, marca su propia rendición en disconformidad y la resuelve
--        con $ 1.000 de robo o pérdida: pasa (el gasto del robo es de su rendición).
--   CL · La clave del cierre: AD confirma la de K con un gasto de $ 300 y una clave; el mismo
--        cierre otra vez devuelve el mismo control, sin otro gasto (K tiene 1). Otro cierre con la
--        misma clave, 22023.
--   RL · La clave de la resolución: AD resuelve la de L con una clave; otra vez, el mismo control.
--   AUD· FALT-*, REND-* y PAGO-* de auditoria_integridad() como estaban antes del ensayo.

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_tag    text := 'T5 ' || left(gen_random_uuid()::text, 8);
  v_a      uuid := gen_random_uuid();
  v_b      uuid := gen_random_uuid();
  v_c      uuid := gen_random_uuid();
  v_d      uuid := gen_random_uuid();
  v_f      uuid := gen_random_uuid();
  v_g      uuid := gen_random_uuid();
  v_h      uuid := gen_random_uuid();
  v_k      uuid := gen_random_uuid();
  v_l      uuid := gen_random_uuid();
  v_m      uuid := gen_random_uuid();
  v_n      uuid := gen_random_uuid();
  v_x2     uuid := gen_random_uuid();
  v_in     uuid := gen_random_uuid();
  v_e      uuid := gen_random_uuid();
  v_e2     uuid := gen_random_uuid();
  v_ad     uuid := gen_random_uuid();
  v_cli    bigint;
  v_cli2   bigint;
  v_p      bigint[] := '{}';
  v_id     bigint;
  v_id2    bigint;
  v_pago   bigint;
  v_emp_n  bigint;
  v_emp_m  bigint;
  v_emp_g  bigint;
  v_mov    bigint;
  v_i      int;
  v_txt    text;
  v_j      jsonb;
  v_h1     text;
  v_h2     text;
  v_clave  uuid := gen_random_uuid();
  v_clave2 uuid := gen_random_uuid();
  v_aud0   text;
  v_gasto  jsonb;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         't5-' || u.id || '@ensayo.invalid',
         jsonb_build_object('rol', u.rol, 'sucursal_id', u.suc),
         jsonb_build_object('nombre', v_tag || ' ' || u.que), now(), now()
    FROM (VALUES (v_a, 'transportista', 1, 'A'), (v_b, 'transportista', 1, 'B'),
                 (v_c, 'transportista', 1, 'C'), (v_d, 'transportista', 1, 'D'),
                 (v_f, 'transportista', 1, 'F'), (v_g, 'transportista', 1, 'G'),
                 (v_h, 'transportista', 1, 'H'), (v_k, 'transportista', 1, 'K'),
                 (v_l, 'transportista', 1, 'L'), (v_m, 'transportista', 1, 'M'),
                 (v_n, 'transportista', 1, 'N'), (v_in, 'transportista', 1, 'IN'),
                 (v_x2, 'transportista', 2, 'X2'), (v_e, 'encargado', 1, 'E'),
                 (v_e2, 'encargado', 1, 'E2'), (v_ad, 'admin', 1, 'AD')) AS u(id, rol, suc, que);
  -- El sync con auth.users (el ban) pide una columna que la base local no tiene: se apaga para esto.
  ALTER TABLE public.perfiles DISABLE TRIGGER trg_perfiles_sync_acceso_auth;
  UPDATE perfiles SET activo = false WHERE id = v_in;
  ALTER TABLE public.perfiles ENABLE TRIGGER trg_perfiles_sync_acceso_auth;

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (v_tag, v_tag, 'Calle T5 1', 1) RETURNING id INTO v_cli;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (v_tag || ' b', v_tag || ' b', 'Calle T5 2', 1) RETURNING id INTO v_cli2;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por, usuario_id)
  VALUES (1, v_tag || ' N', 'transportista', v_ad, v_n) RETURNING id INTO v_emp_n;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por, usuario_id)
  VALUES (1, v_tag || ' M', 'transportista', v_ad, v_m) RETURNING id INTO v_emp_m;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por, usuario_id)
  VALUES (1, v_tag || ' Gp', 'otro', v_ad, NULL) RETURNING id INTO v_emp_g;

  -- Boletas asignadas, de hoy (cliente 1 salvo p[5] y p[6]). p[1], p[2]: de A; p[3]: de B; p[4]: de D;
  -- p[5], p[6]: del cliente 2, de A (el FIFO y el masivo de E); p[7]: de H; p[8]: de M; p[9]: de K;
  -- p[10]: de L; p[11]: de A (la oficina de AD); p[12]: de B (la entrega masiva de E); p[13]: de B (el
  -- cobro que AD anula).
  FOR v_i IN 1..13 LOOP
    INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por,
                         sucursal_id, transportista_id)
    VALUES (CASE WHEN v_i IN (5, 6) THEN v_cli2 ELSE v_cli END, v_hoy, 'asignado',
            CASE v_i WHEN 1 THEN 10000 WHEN 2 THEN 500 WHEN 3 THEN 30000 WHEN 4 THEN 10000 WHEN 5 THEN 2000
                     WHEN 6 THEN 1000 WHEN 7 THEN 8000 WHEN 8 THEN 1000 WHEN 11 THEN 5000 WHEN 12 THEN 700 WHEN 13 THEN 100 ELSE 1000 END,
            0, 'pendiente', 'app', v_e, v_e, 1,
            CASE WHEN v_i IN (1, 2, 5, 6, 11) THEN v_a WHEN v_i IN (3, 12, 13) THEN v_b WHEN v_i = 4 THEN v_d
                 WHEN v_i = 7 THEN v_h WHEN v_i = 8 THEN v_m WHEN v_i = 9 THEN v_k ELSE v_l END)
    RETURNING id INTO v_id;
    v_p := v_p || v_id;
  END LOOP;

  -- ---------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
    IF p_uid IS NULL THEN
      EXECUTE 'RESET ROLE';
    ELSE
      EXECUTE 'SET LOCAL ROLE authenticated';
    END IF;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.r(p_uid uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    BEGIN
      EXECUTE p_sql INTO v;
      v := 'PASA ' || COALESCE(v, '');
    EXCEPTION WHEN OTHERS THEN
      v := SQLSTATE || ' ' || SQLERRM;
    END;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN v;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.cobro(p_ped bigint, p_monto numeric, p_forma text) RETURNS text
  LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, public._tablero_hoy())::text',
                  p_ped, jsonb_build_array(jsonb_build_object('monto', p_monto, 'forma_pago', p_forma)));
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.caja(p_t uuid, p_d date) RETURNS numeric
  LANGUAGE sql AS $f$
    SELECT COALESCE(sum(x.monto), 0) FROM public._rendicion_pagos(1, p_d, p_d) x WHERE x.t_id = p_t;
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.confirmar(p_t uuid, p_estado text, p_cierre jsonb) RETURNS text
  LANGUAGE sql AS $f$
    SELECT format('SELECT public.confirmar_rendicion(public._tablero_hoy(), %L::uuid, %L, %L::jsonb, ''T5'')::text',
                  p_t, p_estado, p_cierre);
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.resolver(p_t uuid, p_res jsonb) RETURNS text
  LANGUAGE sql AS $f$
    SELECT format('SELECT public.resolver_rendicion(public._tablero_hoy(), %L::uuid, ''Resuelta T5'', %L::jsonb)::text',
                  p_t, p_res);
  $f$;
  -- Un gasto de $ p_monto de la rendición de hoy de p_t, cargado desde Gastos.
  CREATE OR REPLACE FUNCTION pg_temp.gasto(p_t uuid, p_monto numeric) RETURNS text
  LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(%L::jsonb)::text',
                  jsonb_build_object('fecha', public._tablero_hoy(), 'rubro_id', 22, 'monto_total', p_monto,
                                     'comprobante', 'ninguno', 'origen_pago', 'rendicion',
                                     'rendicion_transportista_id', p_t, 'rendicion_fecha', public._tablero_hoy()));
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.cobros(c jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('efectivo', 0, 'transferencia', 0, 'cheque', 0, 'cuenta_corriente', 0,
                              'tarjeta', 0, 'otros', 0, 'entregas', 0) || c;
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.aud() RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(format('%s=%s', e->>'id', e->>'violaciones'), ', ')
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
     WHERE (e->>'id' LIKE 'FALT-%' OR e->>'id' LIKE 'REND-%' OR e->>'id' LIKE 'PAGO-%')
       AND (e->>'violaciones')::bigint <> 0;
  $f$;
  v_aud0 := pg_temp.aud();

  -- ------------------------------------------------------------------- D6 ---
  v_txt := pg_temp.r(v_a, pg_temp.cobro(v_p[1], 10000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D6 · A no cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.confirmar(v_a, 'confirmada', '{}'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D6 · AD no confirmó la de A: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_b, pg_temp.cobro(v_p[3], 30000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D6 · B no pudo cobrar con la de A confirmada: ' || v_txt); END IF;
  IF pg_temp.caja(v_b, v_hoy) <> 30000 OR pg_temp.caja(v_a, v_hoy) <> 10000 THEN
    v_fallas := v_fallas || format('D6 · B %s (30000), A %s (10000)', pg_temp.caja(v_b, v_hoy), pg_temp.caja(v_a, v_hoy));
  END IF;
  v_txt := pg_temp.r(v_a, pg_temp.cobro(v_p[2], 500, 'efectivo'));
  IF v_txt !~ '^42501 .*cerrada' THEN v_fallas := v_fallas || ('D6 · A cobró con su rendición confirmada: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.registrar_pago_cliente_fifo(%s, 2000, ''efectivo'', public._tablero_hoy())::text', v_cli2));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D6 · E no pudo cobrar por el FIFO: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.marcar_pagos_masivo(ARRAY[%s]::bigint[], ''efectivo'', public._tablero_hoy())::text', v_p[6]));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D6 · E no pudo cobrar en masivo: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', public._tablero_hoy())::text',
                                 v_p[12], v_b));
  IF v_txt NOT LIKE 'PASA%' OR pg_temp.caja(v_b, v_hoy) <> 30700 THEN
    v_fallas := v_fallas || format('D6 · E no entregó y cobró en masivo la de B (B %s, 30700): %s', pg_temp.caja(v_b, v_hoy), v_txt);
  END IF;
  IF pg_temp.caja(v_e, v_hoy) <> 3000 THEN
    v_fallas := v_fallas || format('D6 · caja de E %s (3000)', pg_temp.caja(v_e, v_hoy));
  END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.marcar_pagos_masivo(ARRAY[%s]::bigint[], ''efectivo'', public._tablero_hoy(), NULL, %L::uuid)::text',
                                 v_p[2], v_a));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('D6 · E cobró en masivo a nombre de A (confirmada): ' || v_txt); END IF;
  -- Corregir la forma y anular miran la misma caja (#1329): un cobro de B sí, uno de A no.
  SELECT id INTO v_pago FROM pagos WHERE pedido_id = v_p[3];
  v_txt := pg_temp.r(v_ad, format('SELECT public.actualizar_forma_pago_pago(%s, ''transferencia'')::text', v_pago));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D6 · AD no cambió la forma de un cobro de B: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.actualizar_forma_pago_pago(%s, ''efectivo'')::text', v_pago));
  SELECT id INTO v_pago FROM pagos WHERE pedido_id = v_p[1];
  v_txt := pg_temp.r(v_ad, format('SELECT public.actualizar_forma_pago_pago(%s, ''transferencia'')::text', v_pago));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('D6 · AD cambió la forma de un cobro de A (confirmada): ' || v_txt); END IF;
  v_txt := pg_temp.r(v_b, pg_temp.cobro(v_p[13], 100, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D6 · B no cobró los 100: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('WITH b AS (DELETE FROM public.pagos WHERE pedido_id = %s RETURNING 1) SELECT count(*)::text FROM b', v_p[13]));
  IF v_txt IS DISTINCT FROM 'PASA 1' THEN v_fallas := v_fallas || ('D6 · AD no anuló un cobro de B: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('WITH b AS (DELETE FROM public.pagos WHERE pedido_id = %s RETURNING 1) SELECT count(*)::text FROM b', v_p[1]));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('D6 · AD anuló un cobro de A (confirmada): ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT concat_ws(''/'', COALESCE(public.ultima_fecha_caja_cerrada(1, %L::uuid)::text, ''-''), COALESCE(public.ultima_fecha_caja_cerrada(1, %L::uuid)::text, ''-''), public.ultima_fecha_caja_cerrada(1), public.rendicion_dia_cerrada(public._tablero_hoy(), 1, %L::uuid)::text, public.rendicion_dia_cerrada(public._tablero_hoy(), 1, %L::uuid)::text)',
                                 v_a, v_b, v_a, v_b));
  IF v_txt IS DISTINCT FROM format('PASA %s/-/%s/true/false', v_hoy, v_hoy) THEN
    v_fallas := v_fallas || ('D6 · las cajas (A/B/sucursal, el día de A y de B): ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- B1 ---
  IF to_regprocedure('public.marcar_rendicion_controlada(date,uuid)') IS NOT NULL THEN
    v_fallas := v_fallas || 'B1 · marcar_rendicion_controlada sigue'::text;
  END IF;

  -- ------------------------------------------------------------------- D8 ---
  v_txt := pg_temp.r(v_d, pg_temp.cobro(v_p[4], 10000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D8 · D no cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, pg_temp.confirmar(v_d, 'disconformidad', '{}'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D8 · disconformidad de D: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.control_rendicion_cerrado(%L::uuid, 1, public._tablero_hoy())::text', v_d));
  IF v_txt IS DISTINCT FROM 'PASA true' THEN v_fallas := v_fallas || ('D8 · la disconformidad no cuenta como cerrada: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, pg_temp.gasto(v_d, 300));
  IF v_txt !~ 'ya está cerrada' THEN v_fallas := v_fallas || ('D8 · un gasto entró en la disconformidad: ' || v_txt); END IF;

  -- ------------------------------------------------------------------- B2 ---
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, controlada_por)
  VALUES (v_hoy, v_c, 1, v_e);
  v_txt := pg_temp.r(v_e, format('SELECT concat_ws(''/'', (SELECT controlada::text FROM public.consultar_control_rendicion(%L::uuid, public._tablero_hoy())), (SELECT controlada::text FROM public.consultar_control_rendicion(%L::uuid, public._tablero_hoy())), (SELECT controlada::text FROM public.consultar_control_rendicion(%L::uuid, public._tablero_hoy())))',
                                 v_d, v_c, v_b));
  IF v_txt IS DISTINCT FROM 'PASA true/false/false' THEN
    v_fallas := v_fallas || ('B2 · controlada (D en disconformidad / C pendiente / B sin fila): ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- P2 ---
  v_txt := pg_temp.r(v_in, format('SELECT public.control_rendicion_cerrado(%L::uuid, 1, public._tablero_hoy())::text', v_in));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('P2 · un desactivado consultó control_rendicion_cerrado: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_in, 'SELECT public.ultima_fecha_caja_cerrada(1)::text');
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('P2 · un desactivado consultó ultima_fecha_caja_cerrada: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_in, 'SELECT public.rendicion_dia_cerrada(public._tablero_hoy(), 1)::text');
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('P2 · un desactivado consultó rendicion_dia_cerrada: ' || v_txt); END IF;

  -- ------------------------------------------------------------------- B6 ---
  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por,
                       sucursal_id, transportista_id, fecha_entrega)
  VALUES (v_cli, v_hoy - 120, 'entregado', 7000, 0, 'pendiente', 'app', v_e, v_e, 1, v_f, now())
  RETURNING id INTO v_id;
  INSERT INTO pedidos (cliente_id, fecha, estado, total, total_real, monto_pagado, estado_pago, canal, usuario_id,
                       creado_por, sucursal_id, transportista_id, motivo_cancelacion)
  VALUES (v_cli, v_hoy, 'cancelado', 0, 3000, 0, 'pendiente', 'app', v_e, v_e, 1, v_f, 'no lo quiso')
  RETURNING id INTO v_id2;
  INSERT INTO pedido_cancelacion_foto (pedido_id, sucursal_id, estado_anterior, total)
  VALUES (v_id2, 1, 'asignado', 5000);
  v_txt := pg_temp.r(v_ad, format('SELECT public.jornadas_transportista(public._tablero_hoy(), public._tablero_hoy(), %L::uuid)::text', v_f));
  v_j := NULLIF(substr(v_txt, 6), '')::jsonb;
  IF v_txt NOT LIKE 'PASA%' OR (v_j->'dias'->0->>'entregados')::int IS DISTINCT FROM 1
     OR (v_j->'dias'->0->>'monto_entregado')::numeric IS DISTINCT FROM 7000
     OR (v_j->'dias'->0->>'monto_rechazado')::numeric IS DISTINCT FROM 5000 THEN
    v_fallas := v_fallas || ('B6 · la jornada de F (1 entregado de 7000, rechazado 5000): ' || left(v_txt, 300));
  END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.jornada_transportista_detalle(public._tablero_hoy(), %L::uuid)::text', v_f));
  v_j := NULLIF(substr(v_txt, 6), '')::jsonb;
  IF v_txt NOT LIKE 'PASA%'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e->>'pedido_id')::bigint = v_id AND (e->>'monto')::numeric = 7000)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e->>'pedido_id')::bigint = v_id2 AND (e->>'monto')::numeric = 5000) THEN
    v_fallas := v_fallas || ('B6 · el detalle de F (el viejo de 7000 y el cancelado de 5000): ' || left(v_txt, 300));
  END IF;

  -- ------------------------------------------------------------------- B3 ---
  v_txt := pg_temp.r(v_ad, format('SELECT concat_ws(''/'', COALESCE(public.jornadas_transportista(public._tablero_hoy(), public._tablero_hoy(), %L::uuid)->>''nombre'', ''-''), COALESCE(public.jornadas_preventista(public._tablero_hoy(), public._tablero_hoy(), %L::uuid)->>''nombre'', ''-''), COALESCE(public.jornadas_transportista(public._tablero_hoy(), public._tablero_hoy(), %L::uuid)->>''nombre'', ''-''))',
                                  v_x2, v_x2, v_f));
  IF v_txt IS DISTINCT FROM format('PASA -/-/%s F', v_tag) THEN
    v_fallas := v_fallas || ('B3 · el nombre (X2 de la otra sucursal / X2 / F): ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- B7 ---
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, creado_por,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_emp_g, v_hoy, 'pago', -100, v_ad, v_g, v_hoy, 1) RETURNING id INTO v_mov;
  v_txt := pg_temp.r(v_ad, format('SELECT huella_pagos_personal FROM public.obtener_resumen_rendiciones(public._tablero_hoy(), public._tablero_hoy(), %L::uuid)', v_g));
  v_h1 := substr(v_txt, 6);
  IF v_txt NOT LIKE 'PASA%' OR length(v_h1) <> 32 THEN
    v_fallas := v_fallas || ('B7 · el resumen no da la huella: ' || v_txt);
  END IF;
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, creado_por, revierte_id,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_emp_g, v_hoy, 'pago', 100, v_ad, v_mov, v_g, v_hoy, 1);
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, creado_por,
                                    rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
  VALUES (v_emp_g, v_hoy, 'pago', -100, v_ad, v_g, v_hoy, 1);
  v_txt := pg_temp.r(v_ad, pg_temp.confirmar(v_g, 'confirmada',
             jsonb_build_object('pagos_personal_visto', 100, 'huella_pagos_personal', v_h1)));
  IF v_txt !~ 'pagos al personal de esta rendición cambiaron' THEN
    v_fallas := v_fallas || ('B7 · confirmó con los pagos al personal cambiados (misma suma): ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT huella_pagos_personal FROM public.obtener_resumen_rendiciones(public._tablero_hoy(), public._tablero_hoy(), %L::uuid)', v_g));
  v_h2 := substr(v_txt, 6);
  v_txt := pg_temp.r(v_ad, pg_temp.confirmar(v_g, 'confirmada',
             jsonb_build_object('pagos_personal_visto', 100, 'huella_pagos_personal', v_h2)));
  IF v_txt NOT LIKE 'PASA%' OR v_h1 = v_h2 THEN
    v_fallas := v_fallas || ('B7 · con la huella nueva no confirmó: ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- M1 ---
  v_txt := pg_temp.r(v_h, pg_temp.cobro(v_p[7], 8000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('M1 · H no cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, pg_temp.confirmar(v_h, 'disconformidad', '{}'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('M1 · disconformidad de H: ' || v_txt); END IF;
  SELECT id INTO v_pago FROM pagos WHERE pedido_id = v_p[7];
  v_txt := pg_temp.r(v_ad, format('SELECT public.corregir_cobro_rendicion(%s, ''transferencia'', NULL, ''Era transferencia'')::text', v_pago));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('M1 · AD no corrigió: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.resolver(v_h, jsonb_build_object('lineas', '[]'::jsonb, 'vistos', '[]'::jsonb,
             'pagos_personal_visto', 0, 'cobros_visto', pg_temp.cobros('{"efectivo": 8000}'))));
  IF v_txt !~ 'cobros de esta rendición cambiaron' THEN
    v_fallas := v_fallas || ('M1 · resolvió con lo cobrado de antes: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.resolver(v_h, jsonb_build_object('lineas', '[]'::jsonb, 'vistos', '[]'::jsonb,
             'pagos_personal_visto', 0, 'cobros_visto', pg_temp.cobros('{"transferencia": 8000}'))));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('M1 · no resolvió con lo cobrado de ahora: ' || v_txt); END IF;

  -- ------------------------------------------------------------------- GC ---
  v_txt := pg_temp.r(v_m, pg_temp.cobro(v_p[8], 1000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('GC · M no cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, pg_temp.confirmar(v_m, 'disconformidad', '{}'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('GC · disconformidad de M: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.resolver(v_m, jsonb_build_object('lineas', jsonb_build_array(
             jsonb_build_object('causal', 'empleado', 'monto', 1500, 'empleado_id', v_emp_n)),
             'vistos', '[]'::jsonb, 'pagos_personal_visto', 0)));
  IF v_txt !~ 'supera' THEN v_fallas := v_fallas || ('GC · imputó más que el efectivo a entregar: ' || v_txt); END IF;

  -- ------------------------------------------------------------------- S2 ---
  v_txt := pg_temp.r(v_ad, pg_temp.resolver(v_m, jsonb_build_object('lineas', jsonb_build_array(
             jsonb_build_object('causal', 'empleado', 'monto', 300, 'empleado_id', v_emp_n, 'observacion', 'se lo lleva N'),
             jsonb_build_object('causal', 'empleado', 'monto', 200, 'empleado_id', v_emp_m, 'observacion', 'es de M'),
             jsonb_build_object('causal', 'robo_perdida', 'monto', 100, 'observacion', 'se perdió')),
             'vistos', '[]'::jsonb, 'pagos_personal_visto', 0)));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('S2 · no resolvió la de M: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_m, 'SELECT public.obtener_faltantes_rendiciones(public._tablero_hoy(), public._tablero_hoy())::text');
  v_j := NULLIF(substr(v_txt, 6), '')::jsonb;
  IF v_txt NOT LIKE 'PASA%' OR jsonb_array_length(v_j) <> 3
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                 WHERE e->>'creado_por_nombre' IS NOT NULL OR e->>'rubro_nombre' IS NOT NULL
                    OR (e->>'monto')::numeric IN (300, 100) AND e->>'observacion' IS NOT NULL
                    OR (e->>'monto')::numeric = 200 AND e->>'observacion' IS DISTINCT FROM 'es de M') THEN
    v_fallas := v_fallas || ('S2 · lo que ve M de sus faltantes: ' || left(v_txt, 400));
  END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.obtener_faltantes_rendiciones(public._tablero_hoy(), public._tablero_hoy(), %L::uuid)::text', v_m));
  v_j := NULLIF(substr(v_txt, 6), '')::jsonb;
  IF v_txt NOT LIKE 'PASA%'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                     WHERE e->>'observacion' = 'se lo lleva N' AND e->>'creado_por_nombre' = v_tag || ' AD')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                     WHERE e->>'causal' = 'robo_perdida' AND e->>'rubro_nombre' IS NOT NULL) THEN
    v_fallas := v_fallas || ('S2 · lo que ve AD de los faltantes de M: ' || left(v_txt, 400));
  END IF;

  -- ------------------------------------------------------------------- G7 ---
  v_txt := pg_temp.r(v_e, pg_temp.gasto(v_e, 400));
  IF v_txt !~ '^42501 .*propia rendición' THEN v_fallas := v_fallas || ('G7 · E se cargó un gasto: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e2, pg_temp.gasto(v_e, 400));
  IF v_txt !~ '^42501 .*encargado' THEN v_fallas := v_fallas || ('G7 · E2 cargó un gasto a la de E: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.gasto(v_e, 400));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('G7 · AD no cargó el gasto de E: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.cobro(v_p[11], 5000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('G7 · AD no cobró en la oficina: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.gasto(v_ad, 100));
  IF v_txt !~ '^42501 .*propia rendición' THEN v_fallas := v_fallas || ('G7 · AD se cargó un gasto desde Gastos: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, pg_temp.gasto(v_b, 250));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('G7 · E no cargó el gasto de B: ' || v_txt); END IF;
  IF public._rendicion_efectivo_a_entregar(1, v_e, v_hoy) <> 2600 OR public._rendicion_efectivo_a_entregar(1, v_b, v_hoy) <> 30450 THEN
    v_fallas := v_fallas || format('G7 · a entregar E %s (2600), B %s (30450)',
                                   public._rendicion_efectivo_a_entregar(1, v_e, v_hoy), public._rendicion_efectivo_a_entregar(1, v_b, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- D7 ---
  v_txt := pg_temp.r(v_ad, pg_temp.confirmar(v_ad, 'disconformidad', '{}'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D7 · AD no marcó la suya en disconformidad: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.resolver(v_ad, jsonb_build_object('lineas', jsonb_build_array(
             jsonb_build_object('causal', 'robo_perdida', 'monto', 1000)),
             'vistos', '[]'::jsonb, 'pagos_personal_visto', 0)));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D7 · AD no resolvió la suya: ' || v_txt); END IF;
  IF public._rendicion_efectivo_a_entregar(1, v_ad, v_hoy) <> 4000 THEN
    v_fallas := v_fallas || format('D7 · a entregar de AD %s (4000)', public._rendicion_efectivo_a_entregar(1, v_ad, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- CL ---
  v_txt := pg_temp.r(v_k, pg_temp.cobro(v_p[9], 1000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('CL · K no cobró: ' || v_txt); END IF;
  v_gasto := jsonb_build_object('vistos', '[]'::jsonb, 'clave', v_clave,
               'guardar', jsonb_build_array(jsonb_build_object('fecha', v_hoy, 'rubro_id', 22, 'monto_total', 300,
                                                               'comprobante', 'ninguno')));
  v_txt := pg_temp.r(v_e, pg_temp.confirmar(v_k, 'confirmada', v_gasto));
  v_h1 := v_txt;
  v_txt := pg_temp.r(v_e, pg_temp.confirmar(v_k, 'confirmada', v_gasto));
  IF v_h1 NOT LIKE 'PASA%' OR v_txt IS DISTINCT FROM v_h1 THEN
    v_fallas := v_fallas || format('CL · el reintento del cierre: %s, después %s', v_h1, v_txt);
  END IF;
  IF (SELECT count(*) FROM gastos WHERE rendicion_transportista_id = v_k AND anulado_at IS NULL) <> 1 THEN
    v_fallas := v_fallas || format('CL · K tiene %s gastos (1)',
                                   (SELECT count(*) FROM gastos WHERE rendicion_transportista_id = v_k AND anulado_at IS NULL));
  END IF;
  v_txt := pg_temp.r(v_e, pg_temp.confirmar(v_k, 'disconformidad', v_gasto));
  IF v_txt !~ '^22023 .*distinto' THEN v_fallas := v_fallas || ('CL · otro cierre con la misma clave: ' || v_txt); END IF;

  -- ------------------------------------------------------------------- RL ---
  v_txt := pg_temp.r(v_l, pg_temp.cobro(v_p[10], 1000, 'efectivo'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('RL · L no cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, pg_temp.confirmar(v_l, 'disconformidad', '{}'));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('RL · disconformidad de L: ' || v_txt); END IF;
  v_j := jsonb_build_object('lineas', '[]'::jsonb, 'vistos', '[]'::jsonb, 'pagos_personal_visto', 0, 'clave', v_clave2);
  v_h1 := pg_temp.r(v_ad, pg_temp.resolver(v_l, v_j));
  v_txt := pg_temp.r(v_ad, pg_temp.resolver(v_l, v_j));
  IF v_h1 NOT LIKE 'PASA%' OR v_txt IS DISTINCT FROM v_h1 THEN
    v_fallas := v_fallas || format('RL · el reintento de la resolución: %s, después %s', v_h1, v_txt);
  END IF;

  v_txt := pg_temp.aud();
  IF v_txt IS DISTINCT FROM v_aud0 THEN
    v_fallas := v_fallas || format('AUD · al final: %s (antes %s)', v_txt, v_aud0);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = 'ENSAYO FALLÓ · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · D6 B1 D8 B2 P2 B6 B3 B7 M1 GC S2 G7 D7 CL RL AUD (hoy %s)', v_hoy);
 END;
END
$ensayo$;
