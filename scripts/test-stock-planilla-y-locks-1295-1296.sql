-- Ensayo de #1295 y #1296: una planilla de control de stock se aplica una vez,
-- y cancelar y editar un pedido bloquean los productos por id.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-stock-planilla-y-locks-1295-1296.sql
--
--   0 · la forma: aplicar_control_stock es una sola, (jsonb, text, uuid), sin
--       la de dos argumentos; EXECUTE para authenticated y no para PUBLIC ni
--       anon; control_stock_sesiones.planilla_id es UNIQUE, authenticated la
--       lee y no escribe la tabla por REST.
--   1 · aplicar_control_stock (#1295):
--       A · la planilla X (p1 contado S1-2, p2 quedaría negativo): p1 queda en
--           S1-2, p2 va a rechazados, y la sesión guarda X.
--       B · el mismo archivo otra vez: se rechaza ("ya se cargó"), p1 sigue en
--           S1-2 (antes, S1-4) y no nace otra sesión.
--       C · el mismo archivo con la fila rechazada corregida: se rechaza
--           entero, p2 no se mueve.
--       D · una planilla nueva (Y), con el stock de después: se aplica.
--       E · sin id (dos argumentos, como el bundle viejo): se rechaza con el
--           mensaje y no nace sesión.
--       F · sigue bloqueando por id antes de mover (#1255), y el INSERT de la
--           sesión es ON CONFLICT (planilla_id) DO NOTHING: dos cargas a la par
--           de la misma planilla piden dos conexiones (ver
--           test-concurrencia-pago-fifo.sql); esto mira el código.
--   2 · el orden en el código (#1296): cancelar_pedido_con_stock y
--       actualizar_pedido_items bloquean los productos del pedido ORDER BY id
--       antes del primer FOR UPDATE o UPDATE de productos, y el cuerpo sin ese
--       bloque es byte a byte el de antes (md5 de prod del 2026-10-29).
--   3 · humo (#1296): un pedido real sin entregar (pendiente o asignado), con
--       dos productos o más y sin regalos, combos ni envío. Editarlo con las mismas líneas, en el JSON
--       al revés del id, sale bien y no mueve el stock; cancelarlo devuelve
--       cada línea. El deadlock en sí pide dos conexiones.

DO $ensayo$
DECLARE
  v_fallas    text[] := '{}';
  v_saltados  text[] := '{}';

  v_suc       bigint := 1;
  v_admin     uuid;
  v_quietos   bigint[];
  v_p1        bigint;    -- se cuenta y se aplica
  v_p2        bigint;    -- quedaría negativo: se rechaza
  v_p3        bigint;    -- el bundle viejo
  v_s1        int;
  v_s2        int;
  v_s3        int;
  v_x         uuid := gen_random_uuid();
  v_y         uuid := gen_random_uuid();
  v_planilla  jsonb;
  v_json      jsonb;
  v_err       text;
  v_n         int;
  v_m         int;
  v_sesiones  int;
  v_fn        regprocedure;
  v_src       text;
  v_ped       bigint;
  v_items     jsonb;
  v_antes     jsonb;
  v_columna   boolean;
  r           record;
BEGIN
  -- --------------------------------------------------------- 0 · la forma ---
  IF to_regprocedure('public.aplicar_control_stock(jsonb,text)') IS NOT NULL THEN
    v_fallas := v_fallas || 'forma · sigue la firma vieja aplicar_control_stock(jsonb,text)'::text;
  END IF;
  v_fn := to_regprocedure('public.aplicar_control_stock(jsonb,text,uuid)');
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'aplicar_control_stock';
  IF v_fn IS NULL OR v_n <> 1 THEN
    v_fallas := v_fallas || format('forma · aplicar_control_stock(jsonb,text,uuid) %s, y hay %s en public (tiene que haber una)',
      CASE WHEN v_fn IS NULL THEN 'no existe' ELSE 'existe' END, v_n);
  ELSE
    IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR has_function_privilege('anon', v_fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                   WHERE p.oid = v_fn AND a.grantee = 0 AND a.privilege_type = 'EXECUTE') THEN
      v_fallas := v_fallas || 'forma · EXECUTE de aplicar_control_stock: authenticated sí, PUBLIC y anon no'::text;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_fn) THEN
      v_fallas := v_fallas || 'forma · aplicar_control_stock no es SECURITY DEFINER'::text;
    END IF;
  END IF;
  v_columna := EXISTS (SELECT 1 FROM pg_attribute
                        WHERE attrelid = 'public.control_stock_sesiones'::regclass
                          AND attname = 'planilla_id' AND NOT attisdropped);
  IF NOT EXISTS (SELECT 1 FROM pg_constraint c
                  WHERE c.conrelid = 'public.control_stock_sesiones'::regclass AND c.contype = 'u'
                    AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
                                           WHERE attrelid = 'public.control_stock_sesiones'::regclass
                                             AND attname = 'planilla_id')]) THEN
    v_fallas := v_fallas || 'forma · control_stock_sesiones.planilla_id no existe o no es UNIQUE'::text;
  ELSIF NOT has_column_privilege('authenticated', 'public.control_stock_sesiones', 'planilla_id', 'SELECT')
     OR has_column_privilege('anon', 'public.control_stock_sesiones', 'planilla_id', 'SELECT') THEN
    v_fallas := v_fallas || 'forma · planilla_id: la lee authenticated, no anon'::text;
  END IF;
  IF has_table_privilege('authenticated', 'public.control_stock_sesiones', 'INSERT')
     OR has_table_privilege('authenticated', 'public.control_stock_sesiones', 'UPDATE') THEN
    v_fallas := v_fallas || 'forma · control_stock_sesiones tiene escritura REST para authenticated'::text;
  END IF;

  -- ------------------------------------------------------------ datos -------
  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  -- Filas quietas: se bloquean hasta el final del DO (unos segundos).
  SELECT array_agg(p.id ORDER BY p.id) INTO v_quietos
    FROM (SELECT p.id FROM productos p
           WHERE p.sucursal_id = v_suc AND p.activo AND p.stock BETWEEN 12 AND 5000
             AND NOT EXISTS (SELECT 1 FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
                              WHERE pi.producto_id = p.id AND pe.created_at > now() - interval '30 days')
             AND p.stock - COALESCE((SELECT sum(l.cantidad_restante) FROM producto_lotes l
                                      WHERE l.producto_id = p.id AND l.sucursal_id = p.sucursal_id), 0) >= 6
           ORDER BY p.id LIMIT 3) p;
  IF COALESCE(array_length(v_quietos, 1), 0) < 3 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay 3 productos quietos con stock en la sucursal %', v_suc;
  END IF;
  v_p1 := v_quietos[1]; v_p2 := v_quietos[2]; v_p3 := v_quietos[3];
  SELECT stock INTO v_s1 FROM productos WHERE id = v_p1;
  SELECT stock INTO v_s2 FROM productos WHERE id = v_p2;
  SELECT stock INTO v_s3 FROM productos WHERE id = v_p3;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- ------------------------------------------- 1 · aplicar_control_stock ----
  -- A · la planilla X.
  v_planilla := jsonb_build_array(
    jsonb_build_object('producto_id', v_p1::text, 'stock_real', v_s1 - 2, 'stock_planilla', v_s1),
    jsonb_build_object('producto_id', v_p2::text, 'stock_real', 0,         'stock_planilla', v_s2 + 10));
  v_err := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.aplicar_control_stock(v_planilla, 'ensayo #1295 A', v_x);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS NOT NULL THEN
    v_fallas := v_fallas || format('#1295 A · la primera carga de la planilla falló: %s', v_err);
  ELSE
    IF (SELECT stock FROM productos WHERE id = v_p1) <> v_s1 - 2 THEN
      v_fallas := v_fallas || format('#1295 A · p1 quedó en %s (tiene que ser S1-2 = %s)',
        (SELECT stock FROM productos WHERE id = v_p1), v_s1 - 2);
    END IF;
    IF (SELECT stock FROM productos WHERE id = v_p2) <> v_s2
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_json->'rechazados') x
                       WHERE (x->>'producto_id')::bigint = v_p2 AND x->>'motivo' = 'quedaria_negativo') THEN
      v_fallas := v_fallas || format('#1295 A · p2 se movió o no está en rechazados: %s', v_json->'rechazados');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM control_stock_sesiones
                    WHERE id = (v_json->>'sesion_id')::bigint AND planilla_id = v_x AND total_items = 1) THEN
      v_fallas := v_fallas || format('#1295 A · la sesión %s no guardó la planilla', v_json->>'sesion_id');
    END IF;
  END IF;

  -- B · el mismo archivo otra vez.
  v_err := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.aplicar_control_stock(v_planilla, 'ensayo #1295 B', v_x);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS NULL OR position('ya se cargó' IN v_err) = 0 OR position('planilla nueva' IN v_err) = 0 THEN
    v_fallas := v_fallas || format('#1295 B · la misma planilla otra vez tenía que rechazarse con "ya se cargó" y dio %s', COALESCE(v_err, 'OK'));
  END IF;
  IF (SELECT stock FROM productos WHERE id = v_p1) <> v_s1 - 2 THEN
    v_fallas := v_fallas || format('#1295 B · p1 quedó en %s: la diferencia se aplicó dos veces (tiene que ser S1-2 = %s)',
      (SELECT stock FROM productos WHERE id = v_p1), v_s1 - 2);
  END IF;
  -- Sin la columna (antes de la migración) estas consultas no se planifican:
  -- van en un IF aparte.
  IF v_columna THEN
    IF (SELECT count(*) FROM control_stock_sesiones WHERE planilla_id = v_x) > 1 THEN
      v_fallas := v_fallas || '#1295 B · nació otra sesión con la misma planilla'::text;
    END IF;
  END IF;

  -- C · el mismo archivo con la fila rechazada corregida (p2 ya no quedaría
  -- negativo): igual se rechaza entero.
  v_err := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.aplicar_control_stock(jsonb_build_array(
      jsonb_build_object('producto_id', v_p1::text, 'stock_real', v_s1 - 2,  'stock_planilla', v_s1),
      jsonb_build_object('producto_id', v_p2::text, 'stock_real', v_s2 + 9,  'stock_planilla', v_s2 + 10)),
      'ensayo #1295 C', v_x);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS NULL OR position('ya se cargó' IN v_err) = 0 THEN
    v_fallas := v_fallas || format('#1295 C · la planilla corregida tenía que rechazarse entera y dio %s', COALESCE(v_err, 'OK'));
  END IF;
  IF (SELECT stock FROM productos WHERE id = v_p1) <> v_s1 - 2 OR (SELECT stock FROM productos WHERE id = v_p2) <> v_s2 THEN
    v_fallas := v_fallas || format('#1295 C · se movió el stock: p1=%s (S1-2=%s) p2=%s (S2=%s)',
      (SELECT stock FROM productos WHERE id = v_p1), v_s1 - 2, (SELECT stock FROM productos WHERE id = v_p2), v_s2);
  END IF;

  -- D · una planilla nueva, bajada con el stock de después.
  v_err := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.aplicar_control_stock(jsonb_build_array(
      jsonb_build_object('producto_id', v_p1::text, 'stock_real', v_s1 - 3, 'stock_planilla', v_s1 - 2)),
      'ensayo #1295 D', v_y);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS NOT NULL OR (SELECT stock FROM productos WHERE id = v_p1) <> v_s1 - 3 THEN
    v_fallas := v_fallas || format('#1295 D · una planilla nueva no se aplicó: p1=%s (S1-3=%s), %s',
      (SELECT stock FROM productos WHERE id = v_p1), v_s1 - 3, COALESCE(v_err, 'sin error'));
  ELSIF NOT EXISTS (SELECT 1 FROM control_stock_sesiones WHERE planilla_id = v_y) THEN
    v_fallas := v_fallas || '#1295 D · la sesión de la planilla nueva no guardó su id'::text;
  END IF;

  -- E · sin id, como el bundle viejo (dos argumentos). Va al final: antes de
  -- la migración la firma vieja la aplica.
  SELECT count(*) INTO v_sesiones FROM control_stock_sesiones;
  v_err := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.aplicar_control_stock(jsonb_build_array(
      jsonb_build_object('producto_id', v_p3::text, 'stock_real', v_s3 - 1, 'stock_planilla', v_s3)), NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS NULL OR position('identificador' IN v_err) = 0 THEN
    v_fallas := v_fallas || format('#1295 E · sin id tenía que rechazarse con "identificador" y dio %s', COALESCE(v_err, 'OK'));
  END IF;
  IF (SELECT stock FROM productos WHERE id = v_p3) <> v_s3
     OR (SELECT count(*) FROM control_stock_sesiones) <> v_sesiones THEN
    v_fallas := v_fallas || format('#1295 E · sin id se movió algo: p3=%s (S3=%s)', (SELECT stock FROM productos WHERE id = v_p3), v_s3);
  END IF;

  -- F · el código.
  IF v_fn IS NOT NULL THEN
    v_src := (SELECT prosrc FROM pg_proc WHERE oid = v_fn);
    v_n := regexp_instr(v_src, 'FROM productos\s+WHERE sucursal_id = v_sucursal_id AND id = ANY\([^;]*ORDER BY id\s+FOR UPDATE');
    v_m := regexp_instr(v_src, 'UPDATE productos SET stock');
    IF v_n = 0 OR v_n > v_m THEN
      v_fallas := v_fallas || format('#1295 F · aplicar_control_stock no bloquea por id antes de mover (lock en %s, update en %s)', v_n, v_m);
    END IF;
    v_n := regexp_instr(v_src, 'INSERT INTO control_stock_sesiones[^;]*planilla_id\)[^;]*ON CONFLICT \(planilla_id\) DO NOTHING');
    v_m := regexp_instr(v_src, 'set_config\(''app\.stock_origen''');
    IF v_n = 0 OR v_n > v_m THEN
      v_fallas := v_fallas || format('#1295 F · la sesión no nace con ON CONFLICT (planilla_id) antes de etiquetar el stock (insert en %s, etiqueta en %s)', v_n, v_m);
    END IF;
  END IF;

  -- ------------------------------------------ 2 · el orden en el código -----
  FOR r IN SELECT * FROM (VALUES
      ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', '4cb9277b72122b47a018892b7dd239a0',
       'FOR v_item IN'),
      ('public.actualizar_pedido_items(bigint,jsonb,uuid,text)',  '9947f9a9a668572962c9a0faa6bc55ca',
       'FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE')
    ) t(firma, md5, primero)
  LOOP
    v_src := (SELECT prosrc FROM pg_proc WHERE oid = to_regprocedure(r.firma));
    v_n := regexp_instr(v_src, 'FROM productos\s+WHERE sucursal_id = v_sucursal\s+AND id IN \(SELECT pi\.producto_id FROM pedido_items pi[^;]*ORDER BY id\s+FOR UPDATE');
    v_m := LEAST(NULLIF(position(r.primero IN v_src), 0), NULLIF(position('UPDATE productos' IN v_src), 0));
    IF v_n = 0 OR v_m IS NULL OR v_n > v_m THEN
      v_fallas := v_fallas || format('#1296 · %s no bloquea los productos por id antes de tocarlos (lock en %s, primero en %s)',
        r.firma, v_n, v_m);
    END IF;
    IF md5(regexp_replace(v_src, '  -- #1296 · .*?      FOR UPDATE;\n\n', '')) <> r.md5 THEN
      v_fallas := v_fallas || format('#1296 · %s: el cuerpo sin el bloque del lock no es el de prod del 2026-10-29', r.firma);
    END IF;
  END LOOP;

  -- -------------------------------------------------------------- 3 · humo ---
  SELECT pe.id INTO v_ped
    FROM pedidos pe
   WHERE pe.sucursal_id = v_suc AND pe.estado IN ('pendiente', 'asignado')
     AND COALESCE(pe.tipo_factura, 'ZZ') <> 'VB' AND COALESCE(pe.cargo_envio, 0) = 0
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi
                      WHERE pi.pedido_id = pe.id
                        AND (COALESCE(pi.es_bonificacion, false) OR pi.promocion_id IS NOT NULL
                             OR pi.combo_id IS NOT NULL OR pi.producto_id IS NULL))
     AND (SELECT count(DISTINCT pi.producto_id) FROM pedido_items pi WHERE pi.pedido_id = pe.id) >= 2
     AND NOT EXISTS (SELECT 1 FROM salvedades_items s WHERE s.pedido_id = pe.id)
     AND public.nota_credito_vigente_de_pedido(pe.id) IS NULL
   ORDER BY pe.id DESC LIMIT 1;

  IF v_ped IS NULL THEN
    v_saltados := v_saltados || 'humo · no hay un pedido sin entregar, sin regalos ni combos, con dos productos'::text;
  ELSE
    SELECT jsonb_object_agg(p.id::text, p.stock) INTO v_antes
      FROM productos p WHERE p.id IN (SELECT producto_id FROM pedido_items WHERE pedido_id = v_ped);
    -- El JSON al revés del id: el pre-chequeo lo recorría en este orden.
    SELECT jsonb_agg(jsonb_build_object('producto_id', pi.producto_id, 'cantidad', pi.cantidad,
                                        'precio_unitario', pi.precio_unitario, 'es_bonificacion', false)
                     ORDER BY pi.producto_id DESC, pi.id)
      INTO v_items FROM pedido_items pi WHERE pi.pedido_id = v_ped;

    v_err := NULL;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      v_json := public.actualizar_pedido_items(v_ped, v_items, v_admin, NULL);
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_err IS NOT NULL OR (v_json->>'success')::boolean IS DISTINCT FROM true THEN
      v_fallas := v_fallas || format('humo · editar el pedido %s sin cambios falló: %s', v_ped, COALESCE(v_err, v_json::text));
    ELSIF EXISTS (SELECT 1 FROM productos p WHERE p.id IN (SELECT (k)::bigint FROM jsonb_object_keys(v_antes) k)
                   AND p.stock <> (v_antes->>p.id::text)::int) THEN
      v_fallas := v_fallas || format('humo · editar el pedido %s sin cambios movió el stock', v_ped);
    END IF;

    v_err := NULL;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      v_json := public.cancelar_pedido_con_stock(v_ped, 'ensayo #1296', v_admin, NULL);
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_err IS NOT NULL OR (v_json->>'success')::boolean IS DISTINCT FROM true THEN
      v_fallas := v_fallas || format('humo · cancelar el pedido %s falló: %s', v_ped, COALESCE(v_err, v_json::text));
    ELSE
      SELECT count(*) INTO v_n
        FROM (SELECT pi.producto_id, sum(pi.cantidad) AS cant FROM pedido_items pi
               WHERE pi.pedido_id = v_ped GROUP BY pi.producto_id) d
        JOIN productos p ON p.id = d.producto_id
       WHERE p.stock <> (v_antes->>p.id::text)::int + d.cant;
      IF v_n > 0 THEN
        v_fallas := v_fallas || format('humo · cancelar el pedido %s no devolvió cada línea (%s productos mal)', v_ped, v_n);
      END IF;
    END IF;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);

  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · % | saltados: %', array_to_string(v_fallas, ' | '),
      COALESCE(NULLIF(array_to_string(v_saltados, ' | '), ''), '-');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · la planilla se aplica una vez, y cancelar y editar bloquean por id (pedido %) | saltados: %',
    COALESCE(v_ped::text, '-'), COALESCE(NULLIF(array_to_string(v_saltados, ' | '), ''), '-');
END
$ensayo$;
