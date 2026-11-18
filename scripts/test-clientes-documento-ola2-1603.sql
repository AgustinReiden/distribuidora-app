-- Ensayo de la migración 528 (migrations/528_clientes_documento_limpieza.sql, «Limpieza del documento de los
-- clientes»; tarjeta B17 de la ola 2 de #1603, punto 1561-b11 de #1561).
--
--   D0 · Sin nada que limpiar, no toca nada y no mira los rangos. El ensayo no depende de que `clientes` esté
--        vacía: primero limpia lo que la base ya tuviera (adentro de esta transacción, que se deshace) y suma a sus
--        rangos lo que quedó de cada grupo.
--   D1 · Premisa: un grupo fuera de su rango aborta sin tocar nada.
--   D2 · Premisa: lo que no es de ningún grupo aborta: un 00 con 7 cifras (la frontera), uno de 10 dígitos, uno
--        de 8 cifras que no termina en 0, y un valor sin forma que no empieza con 00.
--   D3 · La limpieza, fila por fila: cada máscara de número inventado (00-00000NNN-N, 00-0000000N-N,
--        00-000000NN-N, 00-00000N0N-N, 00-00000000-N, 00-00000NN0-0 y las que terminan en 0, de 1 a 6 cifras,
--        con y sin guiones, activo e inactivo, dos números repetidos en dos clientes cada uno) queda sin documento
--        con tipo CUIT; los 18 rellenos, igual; el DNI en formato de almacenamiento con tipo CUIT (de 8 y de 7
--        cifras, activo e inactivo) pasa a DNI y el que ya era DNI no se toca; el CUIT válido, el de verificador
--        malo, el NULL y la cadena vacía no se tocan. El respaldo guarda el antes y el después de cada fila tocada.
--   D4 · No reasigna ni mueve saldos: la zona, los preventistas y el saldo del cliente quedan; audit_logs recibe
--        una fila por cliente corregido, sólo con cuit y tipo_documento.
--   D5 · Volver a correrla no toca nada.
--   D6 · El CHECK clientes_documento_con_su_tipo vuelve a validar sobre lo limpio.
--   D7 · El freno: el tipo sale del valor (alta y edición, por el server y por REST como un bundle viejo que no
--        manda el tipo); el relleno queda NULL; un número inventado (00-00000123-4, y uno que termina en 0) da
--        23514 nombrando el CHECK; un DNI con ceros de más (00-00012345-0) también.
--   D8 · Permisos: las tres funciones sin EXECUTE para anon ni authenticated; el respaldo con RLS, sin policies y
--        sin grants.
--
-- Un único DO que termina siempre en una excepción: no deja nada (salvo valores de secuencia). Para armar el
-- estado de prod (todo con tipo CUIT y los números inventados) saca el CHECK y apaga el trigger nuevo; los vuelve
-- a poner antes de D6. Datos inventados. Sin la migración da 'ENSAYO FALLÓ'.

DO $ensayo$
DECLARE
  v_adm   uuid := '00000000-0000-0000-0000-0000000004e7';
  v_def   text;
  v_zona  bigint;
  v_r     jsonb;
  v_base  jsonb;
  v_resp0 bigint;
  v_mios  bigint[];
  v_n     int;
  v_id    bigint;
  v_t     text;
  f       text[] := '{}';
  -- Los clientes del ensayo.
  c_inv1 bigint; c_inv2 bigint; c_inv3 bigint; c_inv4 bigint; c_inv5 bigint; c_inv6 bigint; c_inv7 bigint;
  c_inv8 bigint; c_inv9 bigint; c_inv10 bigint; c_inv_sg bigint; c_inv_inact bigint; c_rep_a bigint;
  c_rep_b bigint; c_rep_c bigint; c_rep_d bigint;
  c_dni8 bigint; c_dni7 bigint; c_dni_inact bigint; c_ya_dni bigint;
  c_cuit bigint; c_cuit_malo bigint; c_null bigint; c_vacio bigint;
  v_rellenos bigint[] := '{}';
  v_tocados bigint[];
  v_ids bigint[];
  rec   record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regprocedure('public._clientes_documento_limpiar(jsonb)') IS NULL
     OR to_regprocedure('public._clientes_documento_grupos()') IS NULL
     OR to_regclass('public.clientes_documento_respaldo') IS NULL
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.clientes'::regclass
                     AND conname = 'clientes_documento_con_su_tipo')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.clientes'::regclass
                     AND tgname = 'trg_clientes_tipo_documento_del_valor') THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: falta la migración (la limpieza, el respaldo, el CHECK o el trigger del documento)';
  END IF;

  -- ── D0 · sin nada que limpiar ─────────────────────────────────────────────
  -- Lo que la base ya tuviera para limpiar se limpia acá (se deshace al final).
  PERFORM public._clientes_documento_limpiar(NULL);
  v_base := public._clientes_documento_limpiar('{"inventado": [100, 200]}'::jsonb);
  IF (v_base->>'actualizados')::int <> 0 THEN
    f := f || format('D0: sin nada que limpiar tocó algo, o miró los rangos: %s', v_base);
  END IF;
  SELECT count(*) INTO v_resp0 FROM public.clientes_documento_respaldo;

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

  -- Las máscaras de los números inventados (N = cifra no cero).
  c_inv1      := pg_temp.b17_cli('B17 inv 00000NNN-N',   1, '00-00000123-4', 'CUIT', true, v_zona);
  c_inv2      := pg_temp.b17_cli('B17 inv 0000000N-N',   1, '00-00000005-7', 'CUIT', true);
  c_inv3      := pg_temp.b17_cli('B17 inv 000000NN-N',   1, '00-00000042-1', 'CUIT', true);
  c_inv4      := pg_temp.b17_cli('B17 inv 00000N0N-N',   1, '00-00000304-2', 'CUIT', true);
  c_inv5      := pg_temp.b17_cli('B17 inv 00000000-N',   1, '00-00000000-9', 'CUIT', true);
  c_inv6      := pg_temp.b17_cli('B17 inv 00000NN0-0',   1, '00-00000120-0', 'CUIT', true);
  c_inv7      := pg_temp.b17_cli('B17 inv 0000000N-0',   1, '00-00000007-0', 'CUIT', true);
  c_inv8      := pg_temp.b17_cli('B17 inv 0000NNNN-0',   1, '00-00001166-0', 'CUIT', true);
  c_inv9      := pg_temp.b17_cli('B17 inv 5 cifras',     1, '00-00040000-0', 'CUIT', true);
  c_inv10     := pg_temp.b17_cli('B17 inv 6 cifras',     1, '00-00012345-6', 'CUIT', true);
  c_inv_sg    := pg_temp.b17_cli('B17 inv sin guiones',  1, '00000000777',   'CUIT', true);
  c_inv_inact := pg_temp.b17_cli('B17 inv inactivo',     1, '00-00000088-8', 'CUIT', false);
  -- Dos números repetidos en dos clientes cada uno.
  c_rep_a     := pg_temp.b17_cli('B17 rep A',            1, '00-00000999-1', 'CUIT', true);
  c_rep_b     := pg_temp.b17_cli('B17 rep B',            1, '00-00000999-1', 'CUIT', true);
  c_rep_c     := pg_temp.b17_cli('B17 rep C',            1, '00-00000055-5', 'CUIT', true);
  c_rep_d     := pg_temp.b17_cli('B17 rep D',            1, '00-00000055-5', 'CUIT', false);
  -- Los DNI en formato de almacenamiento.
  c_dni8      := pg_temp.b17_cli('B17 DNI de 8',         1, '00-30123456-0', 'CUIT', true);
  c_dni7      := pg_temp.b17_cli('B17 DNI de 7',         1, '00-01234567-0', 'CUIT', true);
  c_dni_inact := pg_temp.b17_cli('B17 DNI inactivo',     1, '00-27654321-0', 'CUIT', false);
  c_ya_dni    := pg_temp.b17_cli('B17 ya DNI',           1, '00-07654321-0', 'DNI',  true);
  -- Los que no se tocan.
  c_cuit      := pg_temp.b17_cli('B17 CUIT',             1, '20-12345678-6', 'CUIT', true);
  c_cuit_malo := pg_temp.b17_cli('B17 CUIT malo',        2, '20-12345678-9', 'CUIT', true);
  c_null      := pg_temp.b17_cli('B17 sin documento',    1, NULL,            'CUIT', true);
  c_vacio     := pg_temp.b17_cli('B17 vacío',            1, '',              'CUIT', true);
  FOR v_n IN 1..18 LOOP
    v_rellenos := v_rellenos || pg_temp.b17_cli('B17 relleno ' || v_n, 1 + v_n % 2, '00-00000000-0', 'CUIT', v_n <> 1);
  END LOOP;

  -- c_inv1 con dueño, preventista y saldo, para ver que la limpieza no los toca.
  INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (c_inv1, v_adm);
  UPDATE public.clientes SET saldo_cuenta = 1234.50 WHERE id = c_inv1;

  v_tocados := ARRAY[c_inv1, c_inv2, c_inv3, c_inv4, c_inv5, c_inv6, c_inv7, c_inv8, c_inv9, c_inv10, c_inv_sg,
                     c_inv_inact, c_rep_a, c_rep_b, c_rep_c, c_rep_d, c_dni8, c_dni7, c_dni_inact] || v_rellenos;

  -- ── D1 · un grupo fuera de su rango aborta ────────────────────────────────
  BEGIN
    PERFORM public._clientes_documento_limpiar('{"inventado": [0, 1]}'::jsonb);
    f := f || 'D1: con inventado fuera de su rango no abortó'::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE format('B17 · los grupos no son los que se midieron: inventado=%s %%',
                               (v_base->>'inventado')::int + 16) THEN
      f := f || format('D1: abortó con otro mensaje: %s', SQLERRM);
    END IF;
  END;
  IF (SELECT count(*) FROM public.clientes_documento_respaldo) <> v_resp0
     OR (SELECT cuit FROM public.clientes WHERE id = c_inv1) <> '00-00000123-4' THEN
    f := f || 'D1: el aborto dejó algo tocado'::text;
  END IF;

  -- ── D2 · lo que no es de ningún grupo aborta ──────────────────────────────
  FOR rec IN SELECT * FROM (VALUES
      ('00-00123456-7', 'un 00 con 7 cifras (la frontera)'),
      ('00-1234567-8',  'un 00 de 10 dígitos'),
      ('00-03012345-6', 'un 00 de 8 cifras que no termina en 0'),
      ('2012345678',    'un valor de 10 dígitos que no empieza con 00')
    ) AS t(valor, que) LOOP
    BEGIN
      PERFORM pg_temp.b17_cli('B17 raro', 1, rec.valor, 'CUIT', true);
      BEGIN
        PERFORM public._clientes_documento_limpiar(NULL);
        f := f || format('D2: con %s no abortó', rec.que);
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'B17 · 1 clientes tienen un documento que no es un CUIT, ni un DNI, ni un número inventado%' THEN
          f := f || format('D2: con %s abortó con otro mensaje: %s', rec.que, SQLERRM);
        END IF;
      END;
      RAISE EXCEPTION 'b17_deshacer';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'b17_deshacer' THEN f := f || format('D2: %s', SQLERRM); END IF;
    END;
  END LOOP;

  -- ── D3 · la limpieza ──────────────────────────────────────────────────────
  -- Los rangos: lo del ensayo más lo que la base ya tenía de cada grupo.
  SELECT jsonb_object_agg(k, jsonb_build_array((v_base->>k)::int + n, (v_base->>k)::int + n)) INTO v_r
    FROM (VALUES ('inventado', 16), ('dni_almacenamiento', 4), ('relleno_ceros', 18), ('cuit_valido', 1),
                 ('cuit_verificador_malo', 1), ('vacio', 1)) AS t(k, n);
  v_r := public._clientes_documento_limpiar(v_r);
  IF (v_r->>'actualizados')::int <> 37 OR (v_r->>'vaciados')::int <> 34
     OR (v_r->>'inactivos_actualizados')::int <> 4 THEN
    f := f || format('D3: la limpieza devolvió %s (esperado 37 actualizados, 34 vaciados, 4 inactivos)', v_r);
  END IF;

  FOR rec IN
    SELECT t.id, t.esperado, COALESCE(c.cuit, '∅') || '/' || COALESCE(c.tipo_documento, '∅') AS hay
      FROM (SELECT unnest(ARRAY[c_inv1, c_inv2, c_inv3, c_inv4, c_inv5, c_inv6, c_inv7, c_inv8, c_inv9, c_inv10,
                                c_inv_sg, c_inv_inact, c_rep_a, c_rep_b, c_rep_c, c_rep_d] || v_rellenos) AS id,
                   '∅/CUIT' AS esperado
            UNION ALL
            SELECT * FROM (VALUES
              (c_dni8,      '00-30123456-0/DNI'),
              (c_dni7,      '00-01234567-0/DNI'),
              (c_dni_inact, '00-27654321-0/DNI'),
              (c_ya_dni,    '00-07654321-0/DNI'),
              (c_cuit,      '20-12345678-6/CUIT'),
              (c_cuit_malo, '20-12345678-9/CUIT'),
              (c_null,      '∅/CUIT'),
              (c_vacio,     '/CUIT')) AS v(id, esperado)) t
      JOIN public.clientes c ON c.id = t.id
  LOOP
    IF rec.hay IS DISTINCT FROM rec.esperado THEN
      f := f || format('D3: el cliente %s quedó %s (esperado %s)', rec.id, rec.hay, rec.esperado);
    END IF;
  END LOOP;

  -- El respaldo: una fila por cliente tocado, con el antes y el después.
  v_mios := v_tocados || ARRAY[c_ya_dni, c_cuit, c_cuit_malo, c_null, c_vacio];
  SELECT array_agg(cliente_id ORDER BY cliente_id) INTO v_ids FROM public.clientes_documento_respaldo
   WHERE cliente_id = ANY (v_mios);
  IF v_ids IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(v_tocados) x) THEN
    f := f || format('D3: el respaldo tiene a %s', v_ids);
  END IF;
  FOR rec IN
    SELECT t.id, t.esperado,
           concat_ws('|', r.grupo, r.activo, r.cuit_anterior, r.tipo_documento_anterior,
                     r.cuit_nuevo, r.tipo_documento_nuevo) AS hay
      FROM (VALUES
        (c_inv1,       'inventado|t|00-00000123-4|CUIT|CUIT'),
        (c_inv6,       'inventado|t|00-00000120-0|CUIT|CUIT'),
        (c_inv_sg,     'inventado|t|00000000777|CUIT|CUIT'),
        (c_inv_inact,  'inventado|f|00-00000088-8|CUIT|CUIT'),
        (c_dni8,       'dni_almacenamiento|t|00-30123456-0|CUIT|00-30123456-0|DNI'),
        (c_dni_inact,  'dni_almacenamiento|f|00-27654321-0|CUIT|00-27654321-0|DNI'),
        (v_rellenos[1], 'relleno_ceros|f|00-00000000-0|CUIT|CUIT')
      ) AS t(id, esperado)
      LEFT JOIN public.clientes_documento_respaldo r ON r.cliente_id = t.id
  LOOP
    IF rec.hay IS DISTINCT FROM rec.esperado THEN
      f := f || format('D3: el respaldo de %s dice %s (esperado %s)', rec.id, rec.hay, rec.esperado);
    END IF;
  END LOOP;

  -- ── D4 · ni asignación, ni zona, ni saldo; audit_logs con lo justo ────────
  IF (SELECT zona_id = v_zona AND saldo_cuenta = 1234.50 FROM public.clientes WHERE id = c_inv1) IS NOT TRUE
     OR (SELECT count(*) FROM public.cliente_preventistas WHERE cliente_id = c_inv1 AND preventista_id = v_adm) <> 1 THEN
    f := f || 'D4: la limpieza tocó la zona, el saldo o los preventistas del cliente'::text;
  END IF;
  -- Los clientes nacieron en este ensayo: sus filas de UPDATE con el documento son las de la limpieza (la del
  -- saldo de c_inv1 no lo nombra).
  SELECT count(*) INTO v_n FROM public.audit_logs
   WHERE tabla = 'clientes' AND accion = 'UPDATE' AND registro_id = ANY (v_ids::text[])
     AND campos_modificados && ARRAY['cuit', 'tipo_documento'];
  IF v_n <> 37 THEN
    f := f || format('D4: audit_logs tiene %s filas de UPDATE del documento de los tocados (esperado 37)', v_n);
  END IF;
  IF EXISTS (SELECT 1 FROM public.audit_logs
              WHERE tabla = 'clientes' AND accion = 'UPDATE' AND registro_id = ANY (v_ids::text[])
                AND campos_modificados && ARRAY['cuit', 'tipo_documento']
                AND NOT (campos_modificados <@ ARRAY['cuit', 'tipo_documento'])) THEN
    f := f || 'D4: audit_logs registró otros campos además del documento'::text;
  END IF;

  -- ── D5 · otra vez no toca nada ────────────────────────────────────────────
  v_r := public._clientes_documento_limpiar('{"inventado": [100, 200]}'::jsonb);
  IF (v_r->>'actualizados')::int <> 0 OR (SELECT count(*) FROM public.clientes_documento_respaldo) <> v_resp0 + 37 THEN
    f := f || format('D5: la segunda corrida tocó algo: %s', v_r);
  END IF;

  -- ── D6 · el CHECK valida sobre lo limpio ──────────────────────────────────
  BEGIN
    EXECUTE format('ALTER TABLE public.clientes ADD CONSTRAINT clientes_documento_con_su_tipo %s', v_def);
  EXCEPTION WHEN check_violation THEN
    f := f || format('D6: el CHECK no valida después de la limpieza: %s', SQLERRM);
    EXECUTE format('ALTER TABLE public.clientes ADD CONSTRAINT clientes_documento_con_su_tipo %s NOT VALID', v_def);
  END;
  ALTER TABLE public.clientes ENABLE TRIGGER trg_clientes_tipo_documento_del_valor;

  -- ── D7 · el freno ─────────────────────────────────────────────────────────
  -- Por el server.
  v_id := pg_temp.b17_cli('B17 alta DNI', 1, '00-30000001-0', 'CUIT', true);
  IF (SELECT tipo_documento FROM public.clientes WHERE id = v_id) IS DISTINCT FROM 'DNI' THEN
    f := f || 'D7: un alta con formato de DNI y tipo CUIT no quedó DNI'::text;
  END IF;
  v_id := pg_temp.b17_cli('B17 alta relleno', 1, '00-00000000-0', 'CUIT', true);
  IF (SELECT cuit FROM public.clientes WHERE id = v_id) IS NOT NULL THEN
    f := f || 'D7: un alta con el relleno 00-00000000-0 no quedó sin documento'::text;
  END IF;
  v_id := pg_temp.b17_cli('B17 alta CUIT', 1, '20-12345678-6', 'DNI', true);
  IF (SELECT tipo_documento FROM public.clientes WHERE id = v_id) IS DISTINCT FROM 'CUIT' THEN
    f := f || 'D7: un alta con un CUIT y tipo DNI no quedó CUIT'::text;
  END IF;
  UPDATE public.clientes SET cuit = '20-12345678-6' WHERE id = c_dni8;
  IF (SELECT tipo_documento FROM public.clientes WHERE id = c_dni8) IS DISTINCT FROM 'CUIT' THEN
    f := f || 'D7: pasar un DNI a un CUIT sin mandar el tipo no lo dejó CUIT'::text;
  END IF;
  UPDATE public.clientes SET tipo_documento = 'DNI' WHERE id = c_cuit;
  IF (SELECT tipo_documento FROM public.clientes WHERE id = c_cuit) IS DISTINCT FROM 'CUIT' THEN
    f := f || 'D7: un CUIT quedó con tipo DNI'::text;
  END IF;
  FOR rec IN SELECT * FROM (VALUES
      ('00-00000123-4', 'un número inventado'),
      ('00-00000120-0', 'un número inventado que termina en 0'),
      ('00-00012345-0', 'un DNI con ceros de más (6 cifras)')
    ) AS t(valor, que) LOOP
    BEGIN
      PERFORM pg_temp.b17_cli('B17 inventado nuevo', 1, rec.valor, 'CUIT', true);
      f := f || format('D7: %s entró', rec.que);
    EXCEPTION WHEN check_violation THEN
      IF SQLERRM NOT LIKE '%clientes_documento_con_su_tipo%' THEN
        f := f || format('D7: el rechazo de %s no nombra el CHECK: %s', rec.que, SQLERRM);
      END IF;
    END;
  END LOOP;

  -- Por REST, como el alta y la edición de un bundle viejo: sin tipo_documento.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id, cuit)
    VALUES ('B17 REST', 'B17 REST', 'Calle Inventada 456', 1, '00-31112222-0');
    UPDATE public.clientes SET cuit = '00-00000000-0' WHERE id = c_dni7;
  EXCEPTION WHEN OTHERS THEN
    f := f || format('D7: por REST como admin falló: %s (%s)', SQLERRM, SQLSTATE);
  END;
  BEGIN
    UPDATE public.clientes SET cuit = '00-00000321-5' WHERE id = c_cuit;
    f := f || 'D7: por REST, un número inventado entró'::text;
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  EXECUTE 'RESET ROLE';
  IF (SELECT tipo_documento FROM public.clientes WHERE nombre_fantasia = 'B17 REST') IS DISTINCT FROM 'DNI' THEN
    f := f || 'D7: el alta por REST sin tipo con un DNI no quedó DNI'::text;
  END IF;
  IF (SELECT cuit FROM public.clientes WHERE id = c_dni7) IS NOT NULL THEN
    f := f || 'D7: la edición por REST con el relleno no dejó el cliente sin documento'::text;
  END IF;

  -- ── D8 · permisos ─────────────────────────────────────────────────────────
  FOR rec IN SELECT unnest(ARRAY['public._clientes_documento_limpiar(jsonb)',
                                 'public._clientes_documento_grupos()',
                                 'public.clientes_tipo_documento_del_valor()']) AS fn LOOP
    IF has_function_privilege('authenticated', rec.fn, 'EXECUTE') OR has_function_privilege('anon', rec.fn, 'EXECUTE') THEN
      f := f || format('D8: %s se puede ejecutar como anon o authenticated', rec.fn);
    END IF;
  END LOOP;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.clientes_documento_respaldo'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.clientes_documento_respaldo'::regclass)
     OR has_table_privilege('authenticated', 'public.clientes_documento_respaldo', 'SELECT')
     OR has_table_privilege('anon', 'public.clientes_documento_respaldo', 'SELECT') THEN
    f := f || 'D8: el respaldo no es sólo de server'::text;
  END IF;

  IF cardinality(f) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK: limpieza del documento de los clientes (D0-D8)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n  %', cardinality(f), array_to_string(f, E'\n  ');
END
$ensayo$;
