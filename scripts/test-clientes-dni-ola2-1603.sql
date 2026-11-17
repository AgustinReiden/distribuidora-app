-- Ensayo de la migración «Los DNI de clientes cargados como CUIT» (tarjeta B17 de la ola 2 de #1603, punto
-- 1561-b11 de #1561).
--
--   D0 · Sin nada que corregir, la corrección no toca nada y no mira los rangos (la foto del CI, una base vacía).
--   D1 · Premisa: un grupo fuera de su rango aborta sin tocar nada.
--   D2 · Premisa: un documento que empieza con 00 y no es un DNI reconocible aborta (dejaría inválido el CHECK).
--   D3 · La otra lectura de los ambiguos ('almacenamiento'): el valor queda y el tipo pasa a DNI.
--   D4 · La corrección, fila por fila: el DNI rellenado a 11 (de 8 y de 7 cifras, con y sin guiones, activo e
--        inactivo) queda 00-<últimos 8>-0 con tipo DNI; el ambiguo, con los últimos 8; el formato de
--        almacenamiento con tipo CUIT pasa a DNI y el que ya era DNI no se toca (tampoco el de 7 cifras, que
--        con tipo DNI no es ambiguo); el relleno 00-00000000-0 queda
--        NULL con tipo CUIT; el CUIT de verdad, el NULL y la cadena vacía no se tocan. El respaldo guarda el antes
--        y el después de cada fila tocada, y nada más. Cuenta el par de la misma sucursal con el mismo DNI.
--   D5 · No reasigna ni mueve saldos: la zona, los preventistas y el saldo del cliente quedan; audit_logs recibe
--        una fila por cliente corregido, sólo con cuit y tipo_documento.
--   D6 · Volver a correrla no toca nada.
--   D7 · El CHECK clientes_documento_con_su_tipo vuelve a validar sobre lo corregido.
--   D8 · El freno: el tipo sale del valor (alta y edición, por el server y por REST como un bundle viejo que no
--        manda el tipo), el relleno queda NULL, y un valor que empieza con 00 sin la forma de un DNI da 23514.
--   D9 · Permisos: las tres funciones sin EXECUTE para anon ni authenticated; el respaldo con RLS, sin policies y
--        sin grants.
--
-- Un único DO que termina siempre en una excepción: no deja nada (salvo valores de secuencia). Para armar el
-- estado de prod (todo con tipo CUIT y valores mal formados) saca el CHECK y apaga el trigger nuevo; los vuelve a
-- poner antes de D7. Datos inventados. Sin la migración da 'ENSAYO FALLÓ'.

DO $ensayo$
DECLARE
  v_adm   uuid := '00000000-0000-0000-0000-0000000004e7';
  v_def   text;
  v_zona  bigint;
  v_r     jsonb;
  v_n     int;
  v_id    bigint;
  v_t     text;
  f       text[] := '{}';
  -- Los clientes del ensayo.
  c_g1 bigint; c_g1_7 bigint; c_g1_inact bigint; c_g1_sg bigint; c_g2 bigint; c_g3 bigint; c_g3_dni bigint;
  c_g2_dni bigint; c_g4 bigint; c_cuit bigint; c_null bigint; c_vacio bigint; c_dup_a bigint; c_dup_b bigint; c_otra_suc bigint;
  v_ids bigint[];
  rec   record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regprocedure('public._clientes_dni_como_cuit_corregir(text, jsonb)') IS NULL
     OR to_regprocedure('public._clientes_documento_grupos(text)') IS NULL
     OR to_regclass('public.clientes_documento_respaldo') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.clientes'::regclass
                     AND conname = 'clientes_documento_con_su_tipo')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.clientes'::regclass
                     AND tgname = 'trg_clientes_tipo_documento_del_valor') THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: falta la migración (la corrección, el respaldo, el CHECK o el trigger del documento)';
  END IF;

  -- ── D0 · sin nada que corregir ────────────────────────────────────────────
  v_r := public._clientes_dni_como_cuit_corregir('ultimos_8', '{"dni_relleno_11": [100, 200]}'::jsonb);
  IF (v_r->>'actualizados')::int <> 0 THEN
    f := f || format('D0: la base ya tenía documentos para corregir: %s', v_r);
  END IF;

  -- ── El estado de prod: todo con tipo CUIT ─────────────────────────────────
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conrelid = 'public.clientes'::regclass AND conname = 'clientes_documento_con_su_tipo';
  ALTER TABLE public.clientes DROP CONSTRAINT clientes_documento_con_su_tipo;
  ALTER TABLE public.clientes DISABLE TRIGGER trg_clientes_tipo_documento_del_valor;

  CREATE FUNCTION pg_temp.b17_cli(p_nom text, p_suc bigint, p_cuit text, p_tipo text, p_activo boolean,
                                  p_zona bigint DEFAULT NULL)
  RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id, cuit, tipo_documento,
                                 activo, zona_id)
    VALUES (p_nom, p_nom, 'Calle Inventada 123', p_suc, p_cuit, p_tipo, p_activo, p_zona)
    RETURNING id
  $f$;

  INSERT INTO public.zonas (nombre, sucursal_id) VALUES ('B17 zona de ensayo', 1) RETURNING id INTO v_zona;

  c_g1       := pg_temp.b17_cli('B17 DNI rellenado',       1, '00-03012345-6', 'CUIT', true, v_zona);
  c_g1_7     := pg_temp.b17_cli('B17 DNI de 7 rellenado',  1, '00-00123456-7', 'CUIT', true);
  c_g1_inact := pg_temp.b17_cli('B17 DNI inactivo',        1, '00-02233445-5', 'CUIT', false);
  c_g1_sg    := pg_temp.b17_cli('B17 DNI sin guiones',     1, '00030123457',   'CUIT', true);
  c_g2       := pg_temp.b17_cli('B17 ambiguo',             1, '00-03012345-0', 'CUIT', true);
  c_g3       := pg_temp.b17_cli('B17 formato bien',        1, '00-31234567-0', 'CUIT', true);
  c_g3_dni   := pg_temp.b17_cli('B17 ya DNI',              1, '00-27654321-0', 'DNI',  true);
  c_g2_dni   := pg_temp.b17_cli('B17 ya DNI de 7',         1, '00-07654321-0', 'DNI',  true);
  c_g4       := pg_temp.b17_cli('B17 relleno',             1, '00-00000000-0', 'CUIT', true);
  c_cuit     := pg_temp.b17_cli('B17 CUIT',                1, '20-12345678-6', 'CUIT', true);
  c_null     := pg_temp.b17_cli('B17 sin documento',       1, NULL,            'CUIT', true);
  c_vacio    := pg_temp.b17_cli('B17 vacío',               1, '',              'CUIT', true);
  c_dup_a    := pg_temp.b17_cli('B17 duplicado A',         2, '00-04455667-7', 'CUIT', true);
  c_dup_b    := pg_temp.b17_cli('B17 duplicado B',         2, '00-44556677-0', 'CUIT', true);
  c_otra_suc := pg_temp.b17_cli('B17 mismo DNI otra suc',  1, '00-04455667-7', 'CUIT', true);

  -- c_g1 con dueño, preventista y saldo, para ver que la corrección no los toca.
  INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (c_g1, v_adm);
  UPDATE public.clientes SET saldo_cuenta = 1234.50 WHERE id = c_g1;

  -- ── D1 · un grupo fuera de su rango aborta ────────────────────────────────
  BEGIN
    PERFORM public._clientes_dni_como_cuit_corregir('ultimos_8', '{"dni_relleno_11": [0, 1]}'::jsonb);
    f := f || 'D1: con dni_relleno_11 fuera de su rango no abortó'::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'B17 · los grupos no son los que se midieron: dni_relleno_11=6 %' THEN
      f := f || format('D1: abortó con otro mensaje: %s', SQLERRM);
    END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.clientes_documento_respaldo)
     OR (SELECT cuit FROM public.clientes WHERE id = c_g1) <> '00-03012345-6' THEN
    f := f || 'D1: el aborto dejó algo tocado'::text;
  END IF;

  -- ── D2 · un 00 irreconocible aborta ───────────────────────────────────────
  BEGIN
    PERFORM pg_temp.b17_cli('B17 raro', 1, '00-1234567-8', 'CUIT', true);
    BEGIN
      PERFORM public._clientes_dni_como_cuit_corregir('ultimos_8', NULL);
      f := f || 'D2: con un documento 00 irreconocible no abortó'::text;
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM NOT LIKE 'B17 · 1 clientes tienen un documento que empieza con 00 y no es un DNI reconocible%' THEN
        f := f || format('D2: abortó con otro mensaje: %s', SQLERRM);
      END IF;
    END;
    -- Un DNI de menos de 7 cifras tampoco es un DNI: va a mano.
    UPDATE public.clientes SET cuit = '00-00000123-4' WHERE nombre_fantasia = 'B17 raro';
    BEGIN
      PERFORM public._clientes_dni_como_cuit_corregir('ultimos_8', NULL);
      f := f || 'D2: con un DNI de 3 cifras no abortó'::text;
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM NOT LIKE 'B17 · 1 clientes tienen un documento que empieza con 00%' THEN
        f := f || format('D2: (3 cifras) abortó con otro mensaje: %s', SQLERRM);
      END IF;
    END;
    RAISE EXCEPTION 'b17_deshacer';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'b17_deshacer' THEN f := f || format('D2: %s', SQLERRM); END IF;
  END;

  -- ── D3 · la lectura 'almacenamiento' de los ambiguos ──────────────────────
  BEGIN
    v_r := public._clientes_dni_como_cuit_corregir('almacenamiento', NULL);
    SELECT cuit || '/' || tipo_documento INTO v_t FROM public.clientes WHERE id = c_g2;
    IF v_t IS DISTINCT FROM '00-03012345-0/DNI' THEN
      f := f || format('D3: el ambiguo con ''almacenamiento'' quedó %s (esperado 00-03012345-0/DNI)', v_t);
    END IF;
    IF (SELECT regla_ambiguos FROM public.clientes_documento_respaldo WHERE cliente_id = c_g2)
       IS DISTINCT FROM 'almacenamiento' THEN
      f := f || 'D3: el respaldo no dice la regla del ambiguo'::text;
    END IF;
    RAISE EXCEPTION 'b17_deshacer';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'b17_deshacer' THEN f := f || format('D3: %s', SQLERRM); END IF;
  END;

  -- ── D4 · la corrección ────────────────────────────────────────────────────
  v_r := public._clientes_dni_como_cuit_corregir('ultimos_8', jsonb_build_object(
    'dni_relleno_11', jsonb_build_array(6, 6), 'ambiguo', jsonb_build_array(1, 1),
    'formato_almacenamiento', jsonb_build_array(4, 4), 'relleno_ceros', jsonb_build_array(1, 1),
    'cuit', jsonb_build_array(1, 1), 'otro', jsonb_build_array(0, 0), 'vacio', jsonb_build_array(1, 1)));
  IF (v_r->>'actualizados')::int <> 10 OR (v_r->>'inactivos_actualizados')::int <> 1
     OR (v_r->>'duplicados_dni')::int <> 1 OR v_r->>'regla_ambiguos' <> 'ultimos_8' THEN
    f := f || format('D4: la corrección devolvió %s (esperado 10 actualizados, 1 inactivo, 1 duplicado)', v_r);
  END IF;

  FOR rec IN
    SELECT t.id, t.esperado, c.cuit || '/' || COALESCE(c.tipo_documento, '∅') AS hay
      FROM (VALUES
        (c_g1,       '00-30123456-0/DNI'),
        (c_g1_7,     '00-01234567-0/DNI'),
        (c_g1_inact, '00-22334455-0/DNI'),
        (c_g1_sg,    '00-30123457-0/DNI'),
        (c_g2,       '00-30123450-0/DNI'),
        (c_g3,       '00-31234567-0/DNI'),
        (c_g3_dni,   '00-27654321-0/DNI'),
        (c_g2_dni,   '00-07654321-0/DNI'),
        (c_cuit,     '20-12345678-6/CUIT'),
        (c_vacio,    '/CUIT'),
        (c_dup_a,    '00-44556677-0/DNI'),
        (c_dup_b,    '00-44556677-0/DNI'),
        (c_otra_suc, '00-44556677-0/DNI')
      ) AS t(id, esperado)
      JOIN public.clientes c ON c.id = t.id
  LOOP
    IF rec.hay IS DISTINCT FROM rec.esperado THEN
      f := f || format('D4: el cliente %s quedó %s (esperado %s)', rec.id, rec.hay, rec.esperado);
    END IF;
  END LOOP;
  IF (SELECT cuit IS NULL AND tipo_documento = 'CUIT' FROM public.clientes WHERE id = c_g4) IS NOT TRUE THEN
    f := f || 'D4: el relleno 00-00000000-0 no quedó sin documento con tipo CUIT'::text;
  END IF;
  IF (SELECT cuit IS NULL FROM public.clientes WHERE id = c_null) IS NOT TRUE THEN
    f := f || 'D4: el cliente sin documento cambió'::text;
  END IF;
  -- El extractor del front lee el DNI de 7 sin el cero de adelante.
  IF ltrim(substr((SELECT cuit FROM public.clientes WHERE id = c_g1_7), 4, 8), '0') <> '1234567' THEN
    f := f || 'D4: el DNI de 7 cifras no quedó legible'::text;
  END IF;

  -- El respaldo: una fila por cliente tocado, con el antes y el después.
  SELECT array_agg(cliente_id ORDER BY cliente_id) INTO v_ids FROM public.clientes_documento_respaldo;
  IF v_ids IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(ARRAY[c_g1, c_g1_7, c_g1_inact, c_g1_sg,
                               c_g2, c_g3, c_g4, c_dup_a, c_dup_b, c_otra_suc]) x) THEN
    f := f || format('D4: el respaldo tiene a %s', v_ids);
  END IF;
  FOR rec IN
    SELECT t.id, t.esperado,
           concat_ws('|', r.grupo, r.regla_ambiguos, r.activo, r.cuit_anterior, r.tipo_documento_anterior,
                     r.cuit_nuevo, r.tipo_documento_nuevo) AS hay
      FROM (VALUES
        (c_g1,       'dni_relleno_11|t|00-03012345-6|CUIT|00-30123456-0|DNI'),
        (c_g1_inact, 'dni_relleno_11|f|00-02233445-5|CUIT|00-22334455-0|DNI'),
        (c_g1_sg,    'dni_relleno_11|t|00030123457|CUIT|00-30123457-0|DNI'),
        (c_g2,       'ambiguo|ultimos_8|t|00-03012345-0|CUIT|00-30123450-0|DNI'),
        (c_g3,       'formato_almacenamiento|t|00-31234567-0|CUIT|00-31234567-0|DNI'),
        (c_g4,       'relleno_ceros|t|00-00000000-0|CUIT|CUIT')
      ) AS t(id, esperado)
      LEFT JOIN public.clientes_documento_respaldo r ON r.cliente_id = t.id
  LOOP
    IF rec.hay IS DISTINCT FROM rec.esperado THEN
      f := f || format('D4: el respaldo de %s dice %s (esperado %s)', rec.id, rec.hay, rec.esperado);
    END IF;
  END LOOP;

  -- ── D5 · ni asignación, ni zona, ni saldo; audit_logs con lo justo ────────
  IF (SELECT zona_id = v_zona AND saldo_cuenta = 1234.50 FROM public.clientes WHERE id = c_g1) IS NOT TRUE
     OR (SELECT count(*) FROM public.cliente_preventistas WHERE cliente_id = c_g1 AND preventista_id = v_adm) <> 1 THEN
    f := f || 'D5: la corrección tocó la zona, el saldo o los preventistas del cliente'::text;
  END IF;
  -- Los clientes nacieron en este ensayo: sus filas de UPDATE con el documento son las de la corrección (la del
  -- saldo de c_g1 no lo nombra).
  SELECT count(*) INTO v_n FROM public.audit_logs
   WHERE tabla = 'clientes' AND accion = 'UPDATE' AND registro_id = ANY (v_ids::text[])
     AND campos_modificados && ARRAY['cuit', 'tipo_documento'];
  IF v_n <> 10 THEN
    f := f || format('D5: audit_logs tiene %s filas de UPDATE del documento de los corregidos (esperado 10)', v_n);
  END IF;
  IF EXISTS (SELECT 1 FROM public.audit_logs
              WHERE tabla = 'clientes' AND accion = 'UPDATE' AND registro_id = ANY (v_ids::text[])
                AND campos_modificados && ARRAY['cuit', 'tipo_documento']
                AND NOT (campos_modificados <@ ARRAY['cuit', 'tipo_documento'])) THEN
    f := f || 'D5: audit_logs registró otros campos además del documento'::text;
  END IF;

  -- ── D6 · otra vez no toca nada ────────────────────────────────────────────
  v_r := public._clientes_dni_como_cuit_corregir('ultimos_8', '{"dni_relleno_11": [100, 200]}'::jsonb);
  IF (v_r->>'actualizados')::int <> 0 OR (SELECT count(*) FROM public.clientes_documento_respaldo) <> 10 THEN
    f := f || format('D6: la segunda corrida tocó algo: %s', v_r);
  END IF;

  -- ── D7 · el CHECK valida sobre lo corregido ───────────────────────────────
  BEGIN
    EXECUTE format('ALTER TABLE public.clientes ADD CONSTRAINT clientes_documento_con_su_tipo %s', v_def);
  EXCEPTION WHEN check_violation THEN
    f := f || format('D7: el CHECK no valida después de la corrección: %s', SQLERRM);
    EXECUTE format('ALTER TABLE public.clientes ADD CONSTRAINT clientes_documento_con_su_tipo %s NOT VALID', v_def);
  END;
  ALTER TABLE public.clientes ENABLE TRIGGER trg_clientes_tipo_documento_del_valor;

  -- ── D8 · el freno ─────────────────────────────────────────────────────────
  -- Por el server.
  v_id := pg_temp.b17_cli('B17 alta DNI', 1, '00-30000001-0', 'CUIT', true);
  IF (SELECT tipo_documento FROM public.clientes WHERE id = v_id) IS DISTINCT FROM 'DNI' THEN
    f := f || 'D8: un alta con formato de DNI y tipo CUIT no quedó DNI'::text;
  END IF;
  v_id := pg_temp.b17_cli('B17 alta relleno', 1, '00-00000000-0', 'CUIT', true);
  IF (SELECT cuit FROM public.clientes WHERE id = v_id) IS NOT NULL THEN
    f := f || 'D8: un alta con el relleno 00-00000000-0 no quedó sin documento'::text;
  END IF;
  v_id := pg_temp.b17_cli('B17 alta CUIT', 1, '20-12345678-6', 'DNI', true);
  IF (SELECT tipo_documento FROM public.clientes WHERE id = v_id) IS DISTINCT FROM 'CUIT' THEN
    f := f || 'D8: un alta con un CUIT y tipo DNI no quedó CUIT'::text;
  END IF;
  UPDATE public.clientes SET cuit = '20-12345678-6' WHERE id = c_g1;
  IF (SELECT tipo_documento FROM public.clientes WHERE id = c_g1) IS DISTINCT FROM 'CUIT' THEN
    f := f || 'D8: pasar un DNI a un CUIT sin mandar el tipo no lo dejó CUIT'::text;
  END IF;
  UPDATE public.clientes SET tipo_documento = 'DNI' WHERE id = c_cuit;
  IF (SELECT tipo_documento FROM public.clientes WHERE id = c_cuit) IS DISTINCT FROM 'CUIT' THEN
    f := f || 'D8: un CUIT quedó con tipo DNI'::text;
  END IF;
  BEGIN
    PERFORM pg_temp.b17_cli('B17 DNI rellenado nuevo', 1, '00-03012346-8', 'CUIT', true);
    f := f || 'D8: un DNI rellenado a 11 con tipo CUIT entró'::text;
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM NOT LIKE '%clientes_documento_con_su_tipo%' THEN
      f := f || format('D8: el rechazo no nombra el CHECK: %s', SQLERRM);
    END IF;
  END;

  -- Por REST, como el alta y la edición de un bundle viejo: sin tipo_documento.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id, cuit)
    VALUES ('B17 REST', 'B17 REST', 'Calle Inventada 456', 1, '00-31112222-0');
    UPDATE public.clientes SET cuit = '00-00000000-0' WHERE id = c_g3;
  EXCEPTION WHEN OTHERS THEN
    f := f || format('D8: por REST como admin falló: %s (%s)', SQLERRM, SQLSTATE);
  END;
  EXECUTE 'RESET ROLE';
  IF (SELECT tipo_documento FROM public.clientes WHERE nombre_fantasia = 'B17 REST') IS DISTINCT FROM 'DNI' THEN
    f := f || 'D8: el alta por REST sin tipo con un DNI no quedó DNI'::text;
  END IF;
  IF (SELECT cuit FROM public.clientes WHERE id = c_g3) IS NOT NULL THEN
    f := f || 'D8: la edición por REST con el relleno no dejó el cliente sin documento'::text;
  END IF;

  -- ── D9 · permisos ─────────────────────────────────────────────────────────
  FOR rec IN SELECT unnest(ARRAY['public._clientes_dni_como_cuit_corregir(text, jsonb)',
                                 'public._clientes_documento_grupos(text)',
                                 'public.clientes_tipo_documento_del_valor()']) AS fn LOOP
    IF has_function_privilege('authenticated', rec.fn, 'EXECUTE') OR has_function_privilege('anon', rec.fn, 'EXECUTE') THEN
      f := f || format('D9: %s se puede ejecutar como anon o authenticated', rec.fn);
    END IF;
  END LOOP;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.clientes_documento_respaldo'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.clientes_documento_respaldo'::regclass)
     OR has_table_privilege('authenticated', 'public.clientes_documento_respaldo', 'SELECT')
     OR has_table_privilege('anon', 'public.clientes_documento_respaldo', 'SELECT') THEN
    f := f || 'D9: el respaldo no es sólo de server'::text;
  END IF;

  IF cardinality(f) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK: los DNI de clientes cargados como CUIT (D0-D9)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n  %', cardinality(f), array_to_string(f, E'\n  ');
END
$ensayo$;
