-- Ensayo de permisos de #1048: suplantar a un admin, el guard que no se
-- ejecuta, el rol NULL de la geolocalización y las comisiones entre sucursales.
--
-- Corre contra prod SIN dejar rastro: es un único DO que termina SIEMPRE en
-- RAISE EXCEPTION, así que todo lo que haya hecho —incluido lo que una función
-- con el bug llegue a escribir— se deshace. Simula una sesión real como lo hace
-- PostgREST: `SET LOCAL ROLE authenticated`, el `sub` del perfil en
-- request.jwt.claims y la sucursal en el header x-sucursal-id.
--
-- Lee el veredicto del mensaje del error final:
--   'ENSAYO OK …'      → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …'   → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en cada caso del bug; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-suplantar-admin-1048.sql

DO $ensayo$
DECLARE
  v_fallas    text[] := '{}';
  v_saltados  text[] := '{}';

  v_suc       bigint;   -- sucursal de los casos
  v_suc_ajena bigint;   -- sucursal ACTIVA que v_admin no tiene asignada
  v_admin     uuid;     -- admin de v_suc al que le falta alguna sucursal activa
  v_admin_red uuid;     -- admin asignado a todas las sucursales activas (si hay)
  v_suc_red   bigint;   -- una sucursal de v_admin_red
  v_prev      uuid;     -- preventista de v_suc
  v_prod      bigint;   -- producto de v_suc con stock >= 1
  v_pedido    bigint;   -- pedido de v_suc tomado por v_prev
  v_regla     bigint;   -- regla de comisión de v_suc_ajena (creada acá)
  v_global    bigint;   -- regla global (creada acá)
  v_otra_red  bigint;   -- otra sucursal asignada de v_admin_red, no la activa

  v_json      jsonb;
  v_id        bigint;
  v_n         int;
  v_stock     int;
  v_stock_ref int;
  v_estado    text;
  r           record;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'admin' AND COALESCE(p.activo, true)
     AND EXISTS (SELECT 1 FROM sucursales s
                  WHERE COALESCE(s.activa, true)
                    AND NOT EXISTS (SELECT 1 FROM usuario_sucursales u2
                                     WHERE u2.usuario_id = us.usuario_id AND u2.sucursal_id = s.id))
     AND EXISTS (SELECT 1 FROM perfiles pv JOIN usuario_sucursales uv ON uv.usuario_id = pv.id
                  WHERE pv.rol = 'preventista' AND COALESCE(pv.activo, true) AND uv.sucursal_id = us.sucursal_id)
   ORDER BY us.es_default DESC, us.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'ensayo · no hay admin con una sucursal activa sin asignar'; END IF;

  SELECT s.id INTO v_suc_ajena FROM sucursales s
   WHERE COALESCE(s.activa, true)
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales u WHERE u.usuario_id = v_admin AND u.sucursal_id = s.id)
   ORDER BY s.id LIMIT 1;

  SELECT pv.id INTO v_prev
    FROM perfiles pv JOIN usuario_sucursales uv ON uv.usuario_id = pv.id
   WHERE pv.rol = 'preventista' AND COALESCE(pv.activo, true) AND uv.sucursal_id = v_suc
   ORDER BY pv.id LIMIT 1;

  SELECT id, stock INTO v_prod, v_stock_ref FROM productos
   WHERE sucursal_id = v_suc AND stock >= 1 ORDER BY id LIMIT 1;
  IF v_prod IS NULL THEN RAISE EXCEPTION 'ensayo · no hay producto con stock en la sucursal %', v_suc; END IF;

  SELECT id INTO v_pedido FROM pedidos
   WHERE sucursal_id = v_suc AND usuario_id = v_prev AND gps_status IS DISTINCT FROM 'ok'
   ORDER BY id DESC LIMIT 1;

  SELECT p.id INTO v_admin_red
    FROM perfiles p
   WHERE p.rol = 'admin' AND COALESCE(p.activo, true)
     AND NOT EXISTS (SELECT 1 FROM sucursales s
                      WHERE COALESCE(s.activa, true)
                        AND NOT EXISTS (SELECT 1 FROM usuario_sucursales u
                                         WHERE u.usuario_id = p.id AND u.sucursal_id = s.id))
   ORDER BY p.id LIMIT 1;
  SELECT sucursal_id INTO v_suc_red FROM usuario_sucursales
   WHERE usuario_id = v_admin_red ORDER BY es_default DESC, sucursal_id LIMIT 1;

  -- Regla de la sucursal ajena, escrita como postgres.
  INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde)
  VALUES (v_suc_ajena, 1.5, current_date)
  RETURNING id INTO v_regla;
  INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde)
  VALUES (NULL, 1.5, current_date)
  RETURNING id INTO v_global;

  -- ------------------------------------- 1 · suplantar a un admin -----------
  -- Un preventista pasa el uuid del admin. Tiene que ser permiso denegado; con
  -- el bug, el JSON vuelve con success y el stock se mueve.
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  FOR r IN SELECT * FROM (VALUES
      ('registrar_ingreso_sucursal', 'preventista con el uuid del admin', v_prev),
      ('registrar_transferencia',    'preventista con el uuid del admin', v_prev),
      ('registrar_ingreso_sucursal', 'el admin mismo (nadie de la app la usa)', v_admin),
      ('registrar_transferencia',    'el admin mismo (nadie de la app la usa)', v_admin)) t(fn, quien, uid) LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE format('SELECT public.%I(%s::bigint, current_date, %L, 0, %L::uuid, %L::jsonb)',
                     r.fn, v_suc, 'ensayo #1048', v_admin,
                     jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1, 'costo_unitario', 0)))
        INTO v_json;
      EXECUTE 'RESET ROLE';
      SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
      v_fallas := v_fallas || format('%s · %s pudo ejecutarla: %s (stock %s → %s)',
                                     r.fn, r.quien, v_json, v_stock_ref, v_stock);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;

  -- ------------------------------- 2 · cerrar_recorridos_vencidos -----------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT cerrados INTO v_n FROM public.cerrar_recorridos_vencidos(v_suc_ajena);
    EXECUTE 'RESET ROLE';
    v_fallas := v_fallas || format('cerrar_recorridos_vencidos · un preventista cerró recorridos de la sucursal %s (%s)', v_suc_ajena, v_n);
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- ---------------------------- 3 · registrar_geolocalizacion_pedido --------
  -- El rol NULL no se puede fabricar sin tocar la tabla (perfiles.rol es NOT
  -- NULL y sin perfil no hay sucursal activa): se mira el cuerpo, y se prueba
  -- que el flujo legítimo sigue andando.
  IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text)'::regprocedure)
       ~ 'v_user_role\s*<>\s*''admin''' THEN
    v_fallas := v_fallas || 'registrar_geolocalizacion_pedido · sigue comparando el rol con <> (un NULL pasa)'::text;
  END IF;
  IF v_pedido IS NULL THEN
    v_saltados := v_saltados || 'geolocalización: el preventista no tiene pedidos sin gps ok'::text;
  ELSE
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.registrar_geolocalizacion_pedido(v_pedido, 'denied');
    EXECUTE 'RESET ROLE';
    IF NOT COALESCE((v_json->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('geolocalización · el dueño del pedido %s no pudo registrarla: %s', v_pedido, v_json);
    END IF;
  END IF;

  -- -------------------------------------------------- 4 · comisiones --------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- 4.1 · Lo que no puede: regla de sucursal ajena, regla global, editar o dar
  --       de baja una regla ajena, calcular sobre una sucursal ajena.
  FOR r IN SELECT * FROM (VALUES
      ('crear regla de la sucursal ajena',
       format('SELECT public.guardar_comision_regla(NULL, %s, NULL, NULL, 2, NULL, NULL, NULL, NULL)::text', v_suc_ajena)),
      ('crear regla global sin tener todas las sucursales',
       'SELECT public.guardar_comision_regla(NULL, NULL, NULL, NULL, 2, NULL, NULL, NULL, NULL)::text'),
      ('mover a su sucursal una regla ajena',
       format('SELECT public.guardar_comision_regla(%s, %s, NULL, NULL, 2, NULL, NULL, NULL, NULL)::text', v_regla, v_suc)),
      ('dar de baja una regla ajena',
       format('SELECT public.desactivar_comision_regla(%s)::text', v_regla)),
      ('editar una regla global sin tener todas las sucursales',
       format('SELECT public.guardar_comision_regla(%s, %s, NULL, NULL, 2, NULL, NULL, NULL, NULL)::text', v_global, v_suc)),
      ('dar de baja una regla global sin tener todas las sucursales',
       format('SELECT public.desactivar_comision_regla(%s)::text', v_global)),
      ('calcular comisiones de la sucursal ajena',
       format('SELECT public.calcular_comisiones(current_date - 30, current_date, ARRAY[%s]::bigint[])::text', v_suc_ajena))
    ) t(caso, sql) LOOP
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE r.sql INTO v_estado;
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || format('comisiones · un admin de la sucursal %s pudo %s', v_suc, r.caso);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
  END LOOP;

  -- 4.2 · La regla ajena no se lee por REST; la global sí.
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_n FROM comision_reglas WHERE id = v_regla;
  SELECT count(*) INTO v_id FROM comision_reglas WHERE id = v_global;
  EXECUTE 'RESET ROLE';
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('comisiones · un admin de la sucursal %s lee por REST la regla %s de la %s', v_suc, v_regla, v_suc_ajena);
  END IF;
  IF v_id <> 1 THEN
    v_fallas := v_fallas || format('comisiones · un admin de la sucursal %s no ve la regla global %s', v_suc, v_global);
  END IF;

  -- 4.2b · Un admin sin sucursales asignadas no calcula nada (antes veía
  --        TODAS). Las filas se borran en un sub-bloque que se deshace solo.
  BEGIN
    DELETE FROM usuario_sucursales WHERE usuario_id = v_admin;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      v_json := public.calcular_comisiones(current_date - 30, current_date, NULL);
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || 'comisiones · un admin sin sucursales asignadas calculó comisiones'::text;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- 4.3 · Lo que sí puede: su sucursal, su cálculo.
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_id := public.guardar_comision_regla(NULL, v_suc, NULL, NULL, 2, NULL, NULL, NULL, NULL);
    PERFORM public.guardar_comision_regla(v_id, v_suc, NULL, NULL, 2.5, NULL, NULL, NULL, NULL);
    PERFORM public.desactivar_comision_regla(v_id);
    SELECT count(*) INTO v_n FROM comision_reglas WHERE id = v_id;
    v_json := public.calcular_comisiones(current_date - 30, current_date, NULL);
    v_json := public.calcular_comisiones(current_date - 30, current_date, ARRAY[v_suc]);
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('comisiones · el admin no ve por REST la regla %s de su sucursal', v_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('comisiones · flujo legítimo del admin de la sucursal %s falló: %s', v_suc, SQLERRM);
  END;

  -- 4.4 · La regla global, para quien tiene todas las sucursales.
  IF v_admin_red IS NULL THEN
    v_saltados := v_saltados || 'comisiones: no hay admin asignado a todas las sucursales activas'::text;
  ELSE
    -- Una regla de otra sucursal suya que no es la activa: por REST no se ve
    -- (se lee la global y la de la activa); calcular_comisiones sí la usa.
    SELECT sucursal_id INTO v_otra_red FROM usuario_sucursales
     WHERE usuario_id = v_admin_red AND sucursal_id <> v_suc_red ORDER BY sucursal_id LIMIT 1;
    IF v_otra_red IS NOT NULL THEN
      INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde)
      VALUES (v_otra_red, 1.5, current_date) RETURNING id INTO v_id;
    END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_red, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc_red::text)::text, true);
    IF v_otra_red IS NOT NULL THEN
      EXECUTE 'SET LOCAL ROLE authenticated';
      SELECT count(*) INTO v_n FROM comision_reglas WHERE id = v_id;
      EXECUTE 'RESET ROLE';
      IF v_n <> 0 THEN
        v_fallas := v_fallas || format('comisiones · con la sucursal %s activa se lee por REST la regla de la %s', v_suc_red, v_otra_red);
      END IF;
    END IF;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      v_id := public.guardar_comision_regla(NULL, NULL, NULL, NULL, 2, NULL, NULL, NULL, NULL);
      PERFORM public.desactivar_comision_regla(v_id);
      v_json := public.calcular_comisiones(current_date - 30, current_date, NULL);
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('comisiones · el admin de toda la red no pudo manejar una regla global: %s', SQLERRM);
    END;
  END IF;

  -- ------------------------------------------------------ 5 · SEG-A ------
  -- El conteo en cero es una poscondición (ya daba cero con el SEG-A viejo,
  -- que no veía estas tres); lo que muerde es la segunda aserción.
  EXECUTE 'SELECT count(*) FROM public.auditoria_definer_sin_rol()' INTO v_n;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('SEG-A · %s funciones marcadas', v_n);
  END IF;
  -- El gate tiene que ver los tres moldes de #1048; antes no los veía.
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.auditoria_definer_sin_rol()'::regprocedure
                    AND prosrc ~ 'guard muerto' AND prosrc ~ 'el rol sale de un par') THEN
    v_fallas := v_fallas || 'SEG-A · no busca la suplantación ni el guard muerto'::text;
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %\nSaltados:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
  END IF;
  RAISE EXCEPTION E'ENSAYO OK (todo revertido). sucursal %, ajena %, admin %, admin red %, pedido %.\nSaltados:\n- %',
    v_suc, v_suc_ajena, v_admin, v_admin_red, v_pedido, COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
END
$ensayo$;
