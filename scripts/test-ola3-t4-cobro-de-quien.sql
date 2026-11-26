-- Ensayo de la migración NNN_ola3_t4_cobro_de_quien (tarjeta T4 de la ola 3; D1 de #1507, #1710,
-- D8 de #1690, Rend-B5 de #1554).
--
-- Un único DO que arma sus propios datos (gente, clientes y boletas nuevas en la sucursal 1, y un
-- chofer de la 2) y termina SIEMPRE en una excepción (ENSAYO OK / ENSAYO FALLÓ): no deja rastro.
-- Corre sobre la base de CI sin datos. Sin la migración falla en A1; con ella, ENSAYO OK. Usa el
-- día argentino (`_tablero_hoy()`), nunca CURRENT_DATE. «Caja» es lo que _rendicion_pagos le da a
-- cada uno (el efectivo, salvo que diga otra forma).
--
-- Gente: A, B, C, D, F y G choferes de la 1; X2 chofer de la 2; E y E2 encargados de la 1; AD
-- admin de la 1. F tiene su ficha de empleado.
--
--   A1 · existe pagos.cobrado_por.
--   C1 · A cobra $ 10.000 en su parada: van a su caja (A = 10.000).
--   C2 · E cobra $ 3.000 en la oficina una boleta de A: van a la de E (A 10.000, E 3.000).
--   C3 · E carga la parada a nombre del chofer de la boleta ($ 2.000, A 12.000); a nombre de otro
--        chofer (B), 42501.
--   C4 · AD elige que cobró B una boleta de A ($ 1.500: B 1.500). A X2 (otra sucursal), 22023.
--   C5 · FIFO de la ficha: E carga $ 5.000 a cuenta y el FIFO los imputa a una boleta de A: son de
--        E (E 8.000, A sigue 12.000).
--   C6 · La boleta cobrada por E cambia de chofer (a B): las cajas no se mueven (REN-1, RUT-1).
--   C7 · Entrega y pago masivos de E a nombre de B ($ 4.000): de B (B 5.500).
--   C8 · Rend-B5: un cobro que entra con una sesión sin usuario ni chofer es del de la sesión.
--   C9 · Un pedazo es de la caja de su padre aunque lo cargue otro (el de A, cargado por AD).
--   G  · G marcó $ 100.000 como transferencia y eran efectivo: E lo corrige (G efectivo 100.000,
--        transferencia 0, la marca en las notas y una fila en audit_logs). E no corrige su
--        propia rendición, ni cambia quién cobró, ni corrige sin motivo.
--   D8 · D cobró $ 10.000; E lo marca en disconformidad. Un cobro de D que llega después con
--        fecha de hoy ($ 500) no entra en ella: va a mañana (hoy 10.000, mañana 500). En la
--        disconformidad, E no corrige; AD pasa los 10.000 a transferencia (hoy efectivo 0).
--   CF · C cobró $ 7.000 ayer y su rendición de ayer se confirma: pasarle ese pago a AD no
--        cambia la rendición (sigue 7.000, de la foto) y corregir_cobro_rendicion la rechaza.
--   F  · F marcó $ 10.000 cobrados y rindió $ 5.000: AD resuelve con un faltante de $ 5.000 a
--        cargo de F. El cliente paga esos $ 5.000 en la oficina a E: cobrar_faltante_rendicion
--        (por AD) los suma al efectivo de E (8.000 → 13.000), le deja la cuenta de F en 0, no cambia
--        la rendición de F (10.000) y no deja cobrar un peso más. E no lo puede cargar. Deshacer la
--        resolución de F se rechaza; anulado el cobro, E vuelve a 8.000 y deshacer pasa.
--   R  · La rendición de E la confirma un admin: E2 no (42501), AD sí.

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_tag    text := 'T4 ' || left(gen_random_uuid()::text, 8);
  v_a      uuid := gen_random_uuid();
  v_b      uuid := gen_random_uuid();
  v_c      uuid := gen_random_uuid();
  v_d      uuid := gen_random_uuid();
  v_f      uuid := gen_random_uuid();
  v_g      uuid := gen_random_uuid();
  v_x2     uuid := gen_random_uuid();
  v_e      uuid := gen_random_uuid();
  v_e2     uuid := gen_random_uuid();
  v_ad     uuid := gen_random_uuid();
  v_cli    bigint;
  v_cli2   bigint;
  v_p      bigint[] := '{}';
  v_id     bigint;
  v_pago   bigint;
  v_emp    bigint;
  v_falt   bigint;
  v_mov    bigint;
  v_n      int;
  v_txt    text;
  v_num    numeric;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pagos'::regclass
                    AND attname = 'cobrado_por' AND NOT attisdropped) THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = 'ENSAYO FALLÓ · A1 · no existe pagos.cobrado_por';
  END IF;

  -- ------------------------------------------------------------- personas ---
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         't4-' || u.id || '@ensayo.invalid',
         jsonb_build_object('rol', u.rol, 'sucursal_id', u.suc),
         jsonb_build_object('nombre', v_tag || ' ' || u.que), now(), now()
    FROM (VALUES (v_a, 'transportista', 1, 'A'), (v_b, 'transportista', 1, 'B'),
                 (v_c, 'transportista', 1, 'C'), (v_d, 'transportista', 1, 'D'),
                 (v_f, 'transportista', 1, 'F'), (v_g, 'transportista', 1, 'G'),
                 (v_x2, 'transportista', 2, 'X2'), (v_e, 'encargado', 1, 'E'),
                 (v_e2, 'encargado', 1, 'E2'), (v_ad, 'admin', 1, 'AD')) AS u(id, rol, suc, que);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (v_tag, v_tag, 'Calle T4 1', 1) RETURNING id INTO v_cli;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (v_tag || ' b', v_tag || ' b', 'Calle T4 2', 1) RETURNING id INTO v_cli2;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por, usuario_id)
  VALUES (1, v_tag || ' F', 'transportista', v_ad, v_f) RETURNING id INTO v_emp;

  -- Boletas asignadas, de hoy. p[1..4], p[6] y p[9..10]: de A; p[5]: del cliente 2, de A (la del FIFO);
  -- p[7]: sin chofer (C7); p[8]: de G; p[11]: de D; p[12]: de F; p[13]: de C (ayer); p[14]: sin chofer.
  FOR v_n IN 1..14 LOOP
    INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por,
                         sucursal_id, transportista_id)
    VALUES (CASE WHEN v_n = 5 THEN v_cli2 ELSE v_cli END,
            CASE WHEN v_n = 13 THEN v_hoy - 1 ELSE v_hoy END,
            CASE WHEN v_n IN (7, 14) THEN 'pendiente' ELSE 'asignado' END,
            CASE v_n WHEN 1 THEN 10000 WHEN 2 THEN 3000 WHEN 3 THEN 2000 WHEN 4 THEN 1500 WHEN 5 THEN 5000
                     WHEN 7 THEN 4000 WHEN 8 THEN 100000 WHEN 11 THEN 10500 WHEN 12 THEN 10000 WHEN 13 THEN 7000
                     ELSE 1000 END,
            0, 'pendiente', 'app', v_e, v_e, 1,
            CASE WHEN v_n IN (7, 14) THEN NULL WHEN v_n = 8 THEN v_g WHEN v_n = 11 THEN v_d
                 WHEN v_n = 12 THEN v_f WHEN v_n = 13 THEN v_c ELSE v_a END)
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
  -- Cobrar una boleta por la RPC: monto, forma y (opcional) quién cobró.
  CREATE OR REPLACE FUNCTION pg_temp.cobro(p_ped bigint, p_monto numeric, p_forma text, p_quien uuid) RETURNS text
  LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, public._tablero_hoy(), NULL, NULL, NULL, %L::uuid)::text',
                  p_ped, jsonb_build_array(jsonb_build_object('monto', p_monto, 'forma_pago', p_forma)), p_quien);
  $f$;
  -- La caja de alguien un día, por forma.
  CREATE OR REPLACE FUNCTION pg_temp.caja(p_t uuid, p_d date, p_forma text DEFAULT 'efectivo') RETURNS numeric
  LANGUAGE sql AS $f$
    SELECT COALESCE(sum(x.monto), 0) FROM public._rendicion_pagos(1, p_d, p_d) x
     WHERE x.t_id = p_t AND x.forma_pago = p_forma;
  $f$;

  -- ------------------------------------------------------------------- C1 ---
  v_txt := pg_temp.r(v_a, pg_temp.cobro(v_p[1], 10000, 'efectivo', NULL));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('C1 · A no cobró: ' || v_txt); END IF;
  IF pg_temp.caja(v_a, v_hoy) <> 10000 THEN
    v_fallas := v_fallas || format('C1 · caja de A %s, no 10000', pg_temp.caja(v_a, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- C2 ---
  v_txt := pg_temp.r(v_e, pg_temp.cobro(v_p[2], 3000, 'efectivo', NULL));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('C2 · E no cobró: ' || v_txt); END IF;
  IF pg_temp.caja(v_a, v_hoy) <> 10000 OR pg_temp.caja(v_e, v_hoy) <> 3000 THEN
    v_fallas := v_fallas || format('C2 · A %s (10000), E %s (3000)', pg_temp.caja(v_a, v_hoy), pg_temp.caja(v_e, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- C3 ---
  v_txt := pg_temp.r(v_e, pg_temp.cobro(v_p[3], 2000, 'efectivo', v_a));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('C3 · E a nombre de A: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, pg_temp.cobro(v_p[4], 1500, 'efectivo', v_b));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('C3 · E eligió a B (no es el chofer de la boleta): ' || v_txt); END IF;
  IF pg_temp.caja(v_a, v_hoy) <> 12000 OR pg_temp.caja(v_e, v_hoy) <> 3000 THEN
    v_fallas := v_fallas || format('C3 · A %s (12000), E %s (3000)', pg_temp.caja(v_a, v_hoy), pg_temp.caja(v_e, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- C4 ---
  v_txt := pg_temp.r(v_ad, pg_temp.cobro(v_p[4], 1500, 'efectivo', v_x2));
  IF v_txt !~ '^22023 ' THEN v_fallas := v_fallas || ('C4 · AD eligió a uno de otra sucursal: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, pg_temp.cobro(v_p[4], 1500, 'efectivo', v_b));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('C4 · AD eligió a B: ' || v_txt); END IF;
  IF pg_temp.caja(v_b, v_hoy) <> 1500 OR pg_temp.caja(v_a, v_hoy) <> 12000 OR pg_temp.caja(v_ad, v_hoy) <> 0 THEN
    v_fallas := v_fallas || format('C4 · B %s (1500), A %s (12000), AD %s (0)',
                                   pg_temp.caja(v_b, v_hoy), pg_temp.caja(v_a, v_hoy), pg_temp.caja(v_ad, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- C5 ---
  v_txt := pg_temp.r(v_e, format('SELECT public.registrar_pago_cliente_fifo(%s, 5000, ''efectivo'', public._tablero_hoy())::text', v_cli2));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('C5 · FIFO de E: ' || v_txt); END IF;
  IF (SELECT monto_pagado FROM pedidos WHERE id = v_p[5]) <> 5000 THEN
    v_fallas := v_fallas || 'C5 · el FIFO no imputó la boleta de A'::text;
  END IF;
  IF pg_temp.caja(v_e, v_hoy) <> 8000 OR pg_temp.caja(v_a, v_hoy) <> 12000 THEN
    v_fallas := v_fallas || format('C5 · E %s (8000), A %s (12000)', pg_temp.caja(v_e, v_hoy), pg_temp.caja(v_a, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- C6 ---
  UPDATE pedidos SET transportista_id = v_b WHERE id IN (v_p[2], v_p[5]);
  IF pg_temp.caja(v_e, v_hoy) <> 8000 OR pg_temp.caja(v_b, v_hoy) <> 1500 THEN
    v_fallas := v_fallas || format('C6 · al cambiar de chofer: E %s (8000), B %s (1500)', pg_temp.caja(v_e, v_hoy), pg_temp.caja(v_b, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- C7 ---
  v_txt := pg_temp.r(v_e, format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', public._tablero_hoy(), NULL)::text',
                                 v_p[7], v_b));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('C7 · entrega y pago masivos: ' || v_txt); END IF;
  IF pg_temp.caja(v_b, v_hoy) <> 5500 OR pg_temp.caja(v_e, v_hoy) <> 8000 THEN
    v_fallas := v_fallas || format('C7 · B %s (5500), E %s (8000)', pg_temp.caja(v_b, v_hoy), pg_temp.caja(v_e, v_hoy));
  END IF;

  -- ------------------------------------------------------------------- C8 ---
  -- Un cobro que entra con la sesión de AD sin usuario ni chofer (lo que haría una RPC nueva que se
  -- olvide de los dos): es de AD, no queda fuera de toda rendición.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ad, 'role', 'authenticated')::text, true);
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
  VALUES (v_cli, v_p[14], 100, 'efectivo', v_hoy, NULL, 1) RETURNING id INTO v_id;
  PERFORM set_config('request.jwt.claims', '', true);
  IF (SELECT cobrado_por FROM pagos WHERE id = v_id) IS DISTINCT FROM v_ad THEN
    v_fallas := v_fallas || 'C8 · un cobro sin usuario ni chofer quedó sin dueño (Rend-B5)'::text;
  END IF;
  DELETE FROM pagos WHERE id = v_id;

  -- ------------------------------------------------------------------- C9 ---
  SELECT id INTO v_pago FROM pagos WHERE pedido_id = v_p[1];
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, pago_origen_id, pago_padre_id)
  VALUES (v_cli, NULL, 100, 'efectivo', v_hoy, v_ad, 1, v_pago, v_pago)
  RETURNING id INTO v_id;
  IF (SELECT cobrado_por FROM pagos WHERE id = v_id) IS DISTINCT FROM v_a THEN
    v_fallas := v_fallas || 'C9 · el pedazo no quedó en la caja de su padre'::text;
  END IF;
  DELETE FROM pagos WHERE id = v_id;

  -- -------------------------------------------------------------------- G ---
  v_txt := pg_temp.r(v_g, pg_temp.cobro(v_p[8], 100000, 'transferencia', NULL));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('G · G no cobró: ' || v_txt); END IF;
  SELECT id INTO v_pago FROM pagos WHERE pedido_id = v_p[8];
  v_txt := pg_temp.r(v_e, format('SELECT public.corregir_cobro_rendicion(%s, ''efectivo'', NULL, '''')::text', v_pago));
  IF v_txt !~ '^22023 ' THEN v_fallas := v_fallas || ('G · corrigió sin motivo: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.corregir_cobro_rendicion(%s, NULL, %L::uuid, ''x'')::text', v_pago, v_a));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('G · E cambió quién cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.corregir_cobro_rendicion(%s, ''efectivo'', NULL, ''Marcó mal la forma'')::text', v_pago));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('G · E no corrigió la forma: ' || v_txt); END IF;
  IF pg_temp.caja(v_g, v_hoy) <> 100000 OR pg_temp.caja(v_g, v_hoy, 'transferencia') <> 0 THEN
    v_fallas := v_fallas || format('G · efectivo %s (100000), transferencia %s (0)',
                                   pg_temp.caja(v_g, v_hoy), pg_temp.caja(v_g, v_hoy, 'transferencia'));
  END IF;
  IF (SELECT notas FROM pagos WHERE id = v_pago) NOT LIKE '%Corregido en la rendición%Marcó mal la forma%' THEN
    v_fallas := v_fallas || 'G · no quedó la marca en las notas'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM audit_logs WHERE tabla = 'pagos' AND registro_id = v_pago::text AND accion = 'UPDATE') THEN
    v_fallas := v_fallas || 'G · no quedó la fila de auditoría'::text;
  END IF;
  -- Su propia rendición (el cobro de C2), no.
  SELECT id INTO v_id FROM pagos WHERE pedido_id = v_p[2];
  v_txt := pg_temp.r(v_e, format('SELECT public.corregir_cobro_rendicion(%s, ''transferencia'', NULL, ''x'')::text', v_id));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('G · E corrigió su propia rendición: ' || v_txt); END IF;

  -- ------------------------------------------------------------------- D8 ---
  v_txt := pg_temp.r(v_d, pg_temp.cobro(v_p[11], 10000, 'efectivo', NULL));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D8 · D no cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.confirmar_rendicion(public._tablero_hoy(), %L::uuid, ''disconformidad'', ''{}''::jsonb, ''faltan 5000'')::text', v_d));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D8 · disconformidad: ' || v_txt); END IF;
  -- Lo que llega después, con la fecha de hoy. Todo el ensayo corre en una transacción (un solo
  -- now()): el cobro de D se corre dos minutos para atrás y el corte uno.
  UPDATE pagos SET created_at = created_at - interval '2 minutes' WHERE pedido_id = v_p[11];
  UPDATE rendiciones_control SET disconformidad_at = disconformidad_at - interval '1 minute'
   WHERE transportista_id = v_d AND fecha = v_hoy;
  v_txt := pg_temp.r(v_d, pg_temp.cobro(v_p[11], 500, 'efectivo', NULL));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D8 · el cobro de después: ' || v_txt); END IF;
  IF pg_temp.caja(v_d, v_hoy) <> 10000 OR pg_temp.caja(v_d, v_hoy + 1) <> 500 THEN
    v_fallas := v_fallas || format('D8 · hoy %s (10000), mañana %s (500)', pg_temp.caja(v_d, v_hoy), pg_temp.caja(v_d, v_hoy + 1));
  END IF;
  SELECT id INTO v_id FROM pagos WHERE pedido_id = v_p[11] AND monto = 10000;
  v_txt := pg_temp.r(v_e, format('SELECT public.corregir_cobro_rendicion(%s, ''transferencia'', NULL, ''x'')::text', v_id));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('D8 · E corrigió en la disconformidad: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.corregir_cobro_rendicion(%s, ''transferencia'', NULL, ''Era transferencia'')::text', v_id));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('D8 · AD no corrigió en la disconformidad: ' || v_txt); END IF;
  IF pg_temp.caja(v_d, v_hoy) <> 0 OR pg_temp.caja(v_d, v_hoy, 'transferencia') <> 10000 THEN
    v_fallas := v_fallas || format('D8 · tras corregir: efectivo %s (0), transferencia %s (10000)',
                                   pg_temp.caja(v_d, v_hoy), pg_temp.caja(v_d, v_hoy, 'transferencia'));
  END IF;

  -- ------------------------------------------------------------------- CF ---
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
  VALUES (v_cli, v_p[13], 7000, 'efectivo', v_hoy - 1, v_c, 1) RETURNING id INTO v_pago;
  v_txt := pg_temp.r(v_ad, format('SELECT public.confirmar_rendicion(public._tablero_hoy() - 1, %L::uuid, ''confirmada'', ''{}''::jsonb, NULL)::text', v_c));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('CF · confirmar la de C: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.corregir_cobro_rendicion(%s, NULL, %L::uuid, ''x'')::text', v_pago, v_ad));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('CF · corrigió un cobro de una rendición confirmada: ' || v_txt); END IF;
  UPDATE pagos SET cobrado_por = v_ad WHERE id = v_pago;
  IF pg_temp.caja(v_c, v_hoy - 1) <> 7000 OR pg_temp.caja(v_ad, v_hoy - 1) <> 0 THEN
    v_fallas := v_fallas || format('CF · la confirmada cambió: C %s (7000), AD %s (0)',
                                   pg_temp.caja(v_c, v_hoy - 1), pg_temp.caja(v_ad, v_hoy - 1));
  END IF;

  -- -------------------------------------------------------------------- F ---
  v_txt := pg_temp.r(v_f, pg_temp.cobro(v_p[12], 10000, 'efectivo', NULL));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('F · F no cobró: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_e, format('SELECT public.confirmar_rendicion(public._tablero_hoy(), %L::uuid, ''disconformidad'', ''{}''::jsonb, ''rindió 5000'')::text', v_f));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('F · disconformidad: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.resolver_rendicion(public._tablero_hoy(), %L::uuid, ''Faltan 5000'', %L::jsonb)::text',
                                  v_f, jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object(
                                         'causal', 'empleado', 'monto', 5000, 'empleado_id', v_emp)),
                                                          'vistos', '[]'::jsonb, 'pagos_personal_visto', 0)));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('F · resolver: ' || v_txt); END IF;
  SELECT id INTO v_falt FROM rendicion_faltantes WHERE rendicion_transportista_id = v_f AND anulada_at IS NULL;
  v_txt := pg_temp.r(v_e, format('SELECT public.cobrar_faltante_rendicion(%s, 5000, ''efectivo'')::text', v_falt));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('F · E cargó el cobro contra el faltante: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.cobrar_faltante_rendicion(%s, 5000, ''efectivo'', %L::uuid, ''pagó en la oficina'')::text',
                                  v_falt, v_e));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('F · AD no cargó el cobro contra el faltante: ' || v_txt); END IF;
  v_mov := NULLIF(substr(v_txt, 6), '')::bigint;
  IF public._rendicion_efectivo_a_entregar(1, v_e, v_hoy) <> 13000 THEN
    v_fallas := v_fallas || format('F · efectivo a entregar de E %s (13000)', public._rendicion_efectivo_a_entregar(1, v_e, v_hoy));
  END IF;
  IF (SELECT COALESCE(sum(monto), 0) FROM empleado_movimientos WHERE empleado_id = v_emp) <> 0 THEN
    v_fallas := v_fallas || format('F · la cuenta de F quedó en %s (0)',
                                   (SELECT sum(monto) FROM empleado_movimientos WHERE empleado_id = v_emp));
  END IF;
  IF pg_temp.caja(v_f, v_hoy) <> 10000 THEN
    v_fallas := v_fallas || format('F · la rendición de F cambió: %s (10000)', pg_temp.caja(v_f, v_hoy));
  END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.cobrar_faltante_rendicion(%s, 1, ''efectivo'')::text', v_falt));
  IF v_txt !~ '^22023 ' THEN v_fallas := v_fallas || ('F · cobró más que el faltante: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.deshacer_resolucion_rendicion(public._tablero_hoy(), %L::uuid, ''x'')::text', v_f));
  IF v_txt NOT LIKE '22023 %' THEN v_fallas := v_fallas || ('F · deshizo con un cobro contra el faltante: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.anular_cobro_faltante(%s, ''me equivoqué'')::text', v_mov));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('F · anular el cobro: ' || v_txt); END IF;
  IF public._rendicion_efectivo_a_entregar(1, v_e, v_hoy) <> 8000 THEN
    v_fallas := v_fallas || format('F · tras anular, E %s (8000)', public._rendicion_efectivo_a_entregar(1, v_e, v_hoy));
  END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.deshacer_resolucion_rendicion(public._tablero_hoy(), %L::uuid, ''x'')::text', v_f));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('F · deshacer, ya sin el cobro: ' || v_txt); END IF;

  -- -------------------------------------------------------------------- R ---
  v_txt := pg_temp.r(v_e2, format('SELECT public.confirmar_rendicion(public._tablero_hoy(), %L::uuid, ''confirmada'', ''{}''::jsonb, NULL)::text', v_e));
  IF v_txt !~ '^42501 ' THEN v_fallas := v_fallas || ('R · otro encargado confirmó la de E: ' || v_txt); END IF;
  v_txt := pg_temp.r(v_ad, format('SELECT public.confirmar_rendicion(public._tablero_hoy(), %L::uuid, ''confirmada'', ''{}''::jsonb, NULL)::text', v_e));
  IF v_txt NOT LIKE 'PASA%' THEN v_fallas := v_fallas || ('R · AD no confirmó la de E: ' || v_txt); END IF;
  IF pg_temp.caja(v_e, v_hoy) <> 8000 THEN
    v_fallas := v_fallas || format('R · la foto de E: %s (8000)', pg_temp.caja(v_e, v_hoy));
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = 'ENSAYO FALLÓ · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · A1 C1 C2 C3 C4 C5 C6 C7 C8 C9 G D8 CF F R (hoy %s)', v_hoy);
 END;
END
$ensayo$;
