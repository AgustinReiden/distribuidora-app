-- Ensayo de #1385 (tarjeta 3 del plan #1389): `cliente_preventistas` entra a la auditoría.
--
-- Corre SIN dejar rastro: un único DO que termina SIEMPRE en una excepción, y cada caso
-- en su bloque que se deshace (ZZ001). Los fixtures son filas nuevas, de una sucursal,
-- una zona y unos clientes del ensayo, así que corre igual en prod que en una base sin
-- datos. Sólo pide un admin, y dos preventistas activos de la misma sucursal.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR. Antes de aplicarla se corre pegado detrás de
-- su cuerpo, sin el BEGIN/COMMIT; después, solo.
--
-- Cada asignación se hace por el camino real, con la sesión real:
--   1 · La ficha del admin, por REST: alta y baja, con usuario, rol y sucursal.
--   2 · La secuencia de #1385, de punta a punta: el admin asigna a mano a quien no es el
--       dueño, otro vincula la zona, y el rastro dice de quién a quién y por dónde.
--       El que ya era del dueño no deja rastro: ON CONFLICT DO NOTHING.
--   3 · Cambiarle la zona a un cliente, y reservarlo: los dos triggers de clientes.
--   4 · Desactivar a un preventista (_soltar_cartera).
--   5 · El server: auth.uid() NULL. No se cae, y deja el rastro sin usuario.
--   6 · El token de un usuario que ya no existe: no se cae por la FK de audit_logs.
--   7 · Borrar el cliente: la FK en cascada, y sin sucursal por la que preguntar.
--   8 · Un UPDATE, que hoy sólo puede hacer el server.
--   9 · Una zona grande: deja el tiempo en la nota del resultado.
--  10 · Los permisos y los triggers.

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_otro   uuid;     -- el dueño de la zona
  v_ajeno  uuid;     -- el que vende y no es el dueño
  v_suc    bigint;
  v_zona   bigint;
  v_zona2  bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_c3     bigint;
  v_n      bigint;
  v_txt    text;
  v_r      record;
  v_t0     timestamptz;
  v_ms1    numeric;
  v_ids    bigint[];
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  SELECT us.sucursal_id, min(a.id::text)::uuid INTO v_suc, v_adm
    FROM perfiles a
    JOIN usuario_sucursales us ON us.usuario_id = a.id
    JOIN auth.users u ON u.id = a.id
   WHERE a.activo AND a.rol = 'admin'
     AND (SELECT count(*) FROM perfiles p JOIN usuario_sucursales x ON x.usuario_id = p.id
           WHERE p.activo AND p.rol = 'preventista' AND x.sucursal_id = us.sucursal_id) >= 2
   GROUP BY us.sucursal_id ORDER BY us.sucursal_id LIMIT 1;
  IF v_adm IS NULL THEN
    RAISE EXCEPTION 'ENSAYO · falta un admin y dos preventistas activos en una sucursal';
  END IF;

  SELECT min(p.id::text)::uuid, max(p.id::text)::uuid INTO v_otro, v_ajeno
    FROM perfiles p JOIN usuario_sucursales x ON x.usuario_id = p.id
   WHERE p.activo AND p.rol = 'preventista' AND x.sucursal_id = v_suc;

  CREATE OR REPLACE FUNCTION pg_temp.sesion(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    IF p_uid IS NULL THEN
      PERFORM set_config('request.jwt.claims', '', true),
              set_config('request.jwt.claim.sub', '', true),
              set_config('request.headers', '{}', true),
              set_config('role', 'none', true);
    ELSE
      PERFORM set_config('request.jwt.claims',
                         json_build_object('sub', p_uid, 'role', 'authenticated')::text, true),
              set_config('request.jwt.claim.sub', p_uid::text, true),
              set_config('request.headers', json_build_object('x-sucursal-id', p_suc)::text, true),
              set_config('role', 'authenticated', true);
    END IF;
  END;
  $f$;

  -- El rastro de un cliente como texto que se lee. Acá todo es una transacción y comparte
  -- created_at, así que va por acción y camino: lo que se prueba es qué filas hay.
  CREATE OR REPLACE FUNCTION pg_temp.rastro(p_cliente bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(
             format('%s %s por %s', a.accion, COALESCE(a.new_data, a.old_data)->>'preventista_id',
                    COALESCE(a.new_data, a.old_data)->>'camino'),
             ' | ' ORDER BY a.accion, COALESCE(a.new_data, a.old_data)->>'camino'), '')
      FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = p_cliente::text;
  $f$;

  CREATE OR REPLACE FUNCTION pg_temp.limpiar(p_cliente bigint) RETURNS void LANGUAGE sql AS $f$
    DELETE FROM audit_logs WHERE tabla = 'cliente_preventistas' AND registro_id = p_cliente::text;
  $f$;

  -- ------------------------------------------------------------------ fixtures -
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZONA ENSAYO 1385', v_suc) RETURNING id INTO v_zona;
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZONA ENSAYO 1385 B', v_suc) RETURNING id INTO v_zona2;
  INSERT INTO preventista_zonas (perfil_id, zona_id, sucursal_id) VALUES (v_otro, v_zona2, v_suc);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES ('ENSAYO 1385 UNO', 'ENSAYO 1385 UNO', 'Calle 1', v_suc, v_zona) RETURNING id INTO v_c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES ('ENSAYO 1385 DOS', 'ENSAYO 1385 DOS', 'Calle 2', v_suc, v_zona) RETURNING id INTO v_c2;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES ('ENSAYO 1385 TRES', 'ENSAYO 1385 TRES', 'Calle 3', v_suc, v_zona) RETURNING id INTO v_c3;

  -- ---------------------------------------------------- 1 · La ficha, por REST -
  BEGIN
    PERFORM pg_temp.sesion(v_adm, v_suc);
    EXECUTE $q$INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)$q$ USING v_c1, v_ajeno;
    EXECUTE $q$DELETE FROM cliente_preventistas WHERE cliente_id = $1 AND preventista_id = $2$q$ USING v_c1, v_ajeno;
    PERFORM pg_temp.sesion(NULL, NULL);

    SELECT count(*) INTO v_n FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text;
    IF v_n <> 2 THEN v_fallas := v_fallas || format('1 · se esperaban 2 filas y hay %s', v_n); END IF;

    SELECT * INTO v_r FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text AND a.accion = 'INSERT';
    IF v_r.usuario_id IS DISTINCT FROM v_adm OR v_r.usuario_rol IS DISTINCT FROM 'admin'
       OR v_r.usuario_email IS NULL OR v_r.sucursal_id IS DISTINCT FROM v_suc
       OR v_r.old_data IS NOT NULL OR v_r.campos_modificados IS NOT NULL
       OR v_r.new_data->>'preventista_id' IS DISTINCT FROM v_ajeno::text
       OR v_r.new_data->>'camino' IS DISTINCT FROM 'directo' THEN
      v_fallas := v_fallas || format('1 · el alta no quedó bien: %s', to_jsonb(v_r));
    END IF;

    SELECT * INTO v_r FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text AND a.accion = 'DELETE';
    IF v_r.usuario_id IS DISTINCT FROM v_adm OR v_r.new_data IS NOT NULL
       OR v_r.old_data->>'preventista_id' IS DISTINCT FROM v_ajeno::text
       OR v_r.old_data->>'camino' IS DISTINCT FROM 'directo' THEN
      v_fallas := v_fallas || format('1 · la baja no quedó bien: %s', to_jsonb(v_r));
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ------------------------------------------ 2 · La secuencia de #1385, entera -
  BEGIN
    PERFORM pg_temp.sesion(v_adm, v_suc);
    -- El admin asigna a mano a quien no es el dueño. El c2 ya es del que va a ser dueño.
    EXECUTE $q$INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)$q$ USING v_c1, v_ajeno;
    EXECUTE $q$INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)$q$ USING v_c2, v_otro;
    PERFORM pg_temp.sesion(NULL, NULL);
    PERFORM pg_temp.limpiar(v_c2);

    PERFORM pg_temp.sesion(v_adm, v_suc);
    PERFORM asignar_preventista_zona(v_zona, v_otro, false);
    PERFORM pg_temp.sesion(NULL, NULL);

    v_txt := pg_temp.rastro(v_c1);
    IF v_txt <> format('DELETE %1$s por asignar_preventista_zona > _asignar_clientes_a | INSERT %2$s por asignar_preventista_zona > _asignar_clientes_a | INSERT %1$s por directo',
                       v_ajeno, v_otro) THEN
      v_fallas := v_fallas || format('2 · la secuencia no se reconstruye: %s', v_txt);
    END IF;

    v_txt := pg_temp.rastro(v_c2);
    IF v_txt <> '' THEN
      v_fallas := v_fallas || format('2 · el que ya era del dueño dejó rastro: %s', v_txt);
    END IF;
    v_txt := pg_temp.rastro(v_c3);
    IF v_txt <> format('INSERT %s por asignar_preventista_zona > _asignar_clientes_a', v_otro) THEN
      v_fallas := v_fallas || format('2 · el sin asignar no quedó: %s', v_txt);
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ----------------------------- 3 · Cambiarle la zona, y reservar al cliente -
  BEGIN
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_c1, v_ajeno);
    PERFORM pg_temp.limpiar(v_c1);

    PERFORM pg_temp.sesion(v_adm, v_suc);
    EXECUTE $q$UPDATE clientes SET zona_id = $1 WHERE id = $2$q$ USING v_zona2, v_c1;
    PERFORM pg_temp.sesion(NULL, NULL);

    v_txt := pg_temp.rastro(v_c1);
    IF v_txt <> format('DELETE %1$s por clientes_zona_asigna_duenio > _asignar_clientes_a | INSERT %2$s por clientes_zona_asigna_duenio > _asignar_clientes_a',
                       v_ajeno, v_otro) THEN
      v_fallas := v_fallas || format('3 · el cambio de zona: %s', v_txt);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM audit_logs a
                    WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text
                      AND a.accion = 'INSERT' AND a.usuario_id = v_adm) THEN
      v_fallas := v_fallas || '3 · el rastro del trigger perdió al usuario que lo disparó'::text;
    END IF;

    PERFORM pg_temp.limpiar(v_c1);
    PERFORM pg_temp.sesion(v_adm, v_suc);
    EXECUTE $q$UPDATE clientes SET reservado_admin = true WHERE id = $1$q$ USING v_c1;
    PERFORM pg_temp.sesion(NULL, NULL);

    v_txt := pg_temp.rastro(v_c1);
    IF v_txt <> format('DELETE %s por clientes_reservado_limpia_asignaciones', v_otro) THEN
      v_fallas := v_fallas || format('3 · reservar: %s', v_txt);
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ------------------------------------------------ 4 · Soltar una cartera -
  BEGIN
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_c1, v_ajeno);
    PERFORM pg_temp.limpiar(v_c1);
    PERFORM _soltar_cartera(v_ajeno, v_suc);

    v_txt := pg_temp.rastro(v_c1);
    IF v_txt <> format('DELETE %s por _soltar_cartera', v_ajeno) THEN
      v_fallas := v_fallas || format('4 · soltar la cartera: %s', v_txt);
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ------------------------------------------------------------- 5 · El server -
  BEGIN
    PERFORM pg_temp.sesion(NULL, NULL);
    IF auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'ENSAYO · esto no es el server'; END IF;
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_c1, v_ajeno);
    PERFORM _asignar_clientes_a(ARRAY[v_c1], v_otro);

    SELECT count(*) INTO v_n FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text;
    IF v_n <> 3 THEN v_fallas := v_fallas || format('5 · se esperaban 3 filas y hay %s', v_n); END IF;

    IF EXISTS (SELECT 1 FROM audit_logs a
                WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text
                  AND (a.usuario_id IS NOT NULL OR a.usuario_email IS NOT NULL OR a.usuario_rol IS NOT NULL
                       OR a.sucursal_id IS DISTINCT FROM v_suc)) THEN
      v_fallas := v_fallas || '5 · sin sesión hay usuario, o se perdió la sucursal del cliente'::text;
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- -------------------------------------- 6 · Un token sin usuario en auth.users -
  BEGIN
    -- Se borra: la baja no pasa por cliente_preventistas_no_ajeno, que frenaría el alta.
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_c1, v_ajeno);
    PERFORM pg_temp.limpiar(v_c1);
    PERFORM pg_temp.sesion('00000000-0000-4000-8000-000000001385'::uuid, v_suc);
    PERFORM set_config('role', 'none', true);
    DELETE FROM cliente_preventistas WHERE cliente_id = v_c1;
    PERFORM pg_temp.sesion(NULL, NULL);

    IF NOT EXISTS (SELECT 1 FROM audit_logs a
                    WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text
                      AND a.accion = 'DELETE' AND a.usuario_id IS NULL AND a.sucursal_id = v_suc) THEN
      v_fallas := v_fallas || '6 · no quedó el rastro sin usuario'::text;
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ------------------------------------------------------ 7 · La cascada -
  BEGIN
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_c1, v_ajeno);
    PERFORM pg_temp.limpiar(v_c1);
    PERFORM pg_temp.sesion(v_adm, v_suc);
    PERFORM set_config('role', 'none', true);
    DELETE FROM clientes WHERE id = v_c1;
    PERFORM pg_temp.sesion(NULL, NULL);

    SELECT * INTO v_r FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text;
    IF NOT FOUND OR v_r.accion <> 'DELETE' OR v_r.old_data->>'camino' IS DISTINCT FROM 'cascada'
       OR v_r.sucursal_id IS DISTINCT FROM v_suc THEN
      v_fallas := v_fallas || format('7 · la cascada: %s', to_jsonb(v_r));
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- ------------------------------------------------------------- 8 · Un UPDATE -
  BEGIN
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_c1, v_ajeno);
    PERFORM pg_temp.limpiar(v_c1);
    UPDATE cliente_preventistas SET creado_en = creado_en - interval '1 day' WHERE cliente_id = v_c1;
    SELECT * INTO v_r FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = v_c1::text;
    IF NOT FOUND OR v_r.accion <> 'UPDATE' OR v_r.campos_modificados IS DISTINCT FROM ARRAY['creado_en']
       OR v_r.old_data IS NULL OR v_r.new_data IS NULL THEN
      v_fallas := v_fallas || format('8 · cambiar la fecha: %s', to_jsonb(v_r));
    END IF;

    PERFORM pg_temp.limpiar(v_c1);
    UPDATE cliente_preventistas SET preventista_id = v_otro WHERE cliente_id = v_c1;
    v_txt := pg_temp.rastro(v_c1);
    IF v_txt NOT LIKE '%' || v_ajeno || '%' OR v_txt NOT LIKE '%' || v_otro || '%' THEN
      v_fallas := v_fallas || format('8 · cambiar el preventista: %s', v_txt);
    END IF;

    PERFORM pg_temp.limpiar(v_c1);
    UPDATE cliente_preventistas SET creado_en = creado_en WHERE cliente_id = v_c1;
    IF pg_temp.rastro(v_c1) <> '' THEN
      v_fallas := v_fallas || '8 · un UPDATE que no cambia nada dejó rastro'::text;
    END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  -- --------------------------------------------------- 9 · Una zona de 200 -
  -- Es casi el triple de la más grande de prod (74). No se compara acá contra los
  -- triggers apagados: un ALTER TABLE tomaría la tabla entera mientras corre el ensayo.
  BEGIN
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    SELECT 'ENSAYO 1385 G' || g, 'ENSAYO 1385 G' || g, 'Calle ' || g, v_suc, v_zona FROM generate_series(1, 200) g;
    SELECT array_agg(id) INTO v_ids FROM clientes WHERE zona_id = v_zona AND razon_social LIKE 'ENSAYO 1385 G%';
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) SELECT unnest(v_ids), v_ajeno;

    PERFORM pg_temp.sesion(v_adm, v_suc);
    v_t0 := clock_timestamp();
    PERFORM asignar_preventista_zona(v_zona, v_otro, false);
    v_ms1 := EXTRACT(epoch FROM clock_timestamp() - v_t0) * 1000;
    PERFORM pg_temp.sesion(NULL, NULL);

    SELECT count(*) INTO v_n FROM audit_logs a
     WHERE a.tabla = 'cliente_preventistas' AND a.registro_id = ANY (SELECT unnest(v_ids)::text);
    -- El alta de los fixtures, y la baja y el alta de la vinculación.
    IF v_n <> 600 THEN v_fallas := v_fallas || format('9 · se esperaban 600 filas y hay %s', v_n); END IF;
    RAISE EXCEPTION 'deshacer' USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
  END;

  v_notas := v_notas || format('9: vincular 200 clientes tardó %s ms', round(v_ms1));

  -- ---------------------------------------------------------- 10 · Permisos -
  IF has_function_privilege('anon', 'public.audit_cliente_preventistas()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.audit_cliente_preventistas()', 'EXECUTE') THEN
    v_fallas := v_fallas || '10 · la función de trigger es ejecutable por la app'::text;
  END IF;
  IF NOT has_function_privilege('service_role', 'public.audit_cliente_preventistas()', 'EXECUTE') THEN
    v_fallas := v_fallas || '10 · service_role perdió el EXECUTE'::text;
  END IF;
  IF has_table_privilege('authenticated', 'public.audit_logs', 'INSERT') THEN
    v_fallas := v_fallas || '10 · authenticated escribe audit_logs: el SECURITY DEFINER no se está probando'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ') USING ERRCODE = 'ZZ002';
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · % · %', v_adm, array_to_string(v_notas, ' || ') USING ERRCODE = 'ZZ003';
 END;
END
$ensayo$;
