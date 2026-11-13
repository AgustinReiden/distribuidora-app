-- Ensayo del alta en zona propia (#1553, VAR-03; mig NNN_alta_en_zona_propia_asigna_al_duenio).
--
-- Corre SIN dejar rastro: un único DO que termina SIEMPRE en una excepción
-- (`ENSAYO OK` o `ENSAYO FALLO …`). Arma su contexto con gente que ya existe
-- (una sucursal activa con un admin, un encargado y tres preventistas de rol
-- base), y crea tres zonas y los clientes que necesita adentro del DO.
-- Antes de aplicar la migración se corre pegado detrás de su cuerpo sin el
-- BEGIN/COMMIT. Sin ella falla en A1 (las dos), A2, A4 y B7; A3 pasa igual,
-- porque sin la migración la fila todavía no existe cuando llega.
--
--   A1 · P1, dueño de Z1, da de alta un cliente en Z1: queda asignado a P1, y
--        sólo a P1, en el mismo INSERT (antes: sin asignar), y ASG-A no se
--        mueve antes del segundo pedido.
--   A2 · P3 (otro preventista) no lo ve.
--   A3 · El segundo pedido de un bundle viejo del PWA (DELETE de todas las
--        filas, que al preventista no le borra nada, + INSERT pelado) no falla
--        y no duplica.
--   A4 · El mismo INSERT repetido otra vez (el bundle de hoy, o un reintento)
--        tampoco falla.
--   A5 · Las guardas corren antes que la absorción del repetido: P3 que
--        reinserta la fila (cliente, P1) choca con 42501.
--   B1 · Un admin da de alta en Z2 (dueño P2): queda de P2.
--   B2 · Un encargado da de alta en Z2: queda de P2.
--   B3 · Alta en Z3, sin dueño: queda sin asignar.
--   B4 · Alta de un reservado (admin) en Z1: sin preventistas.
--   B5 · P2 da de alta en Z1 (zona ajena): 42501, como antes.
--   B6 · Cambio de zona de un cliente existente (el de B1, de Z2 a Z1): pasa a P1.
--   B7 · Un admin repite la asignación del cliente de A1: no falla.
--   C  · ASG-A y ASG-B quedan como estaban antes del ensayo.

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_enc    uuid;
  v_p1     uuid;
  v_p2     uuid;
  v_p3     uuid;
  v_z1     bigint;
  v_z2     bigint;
  v_z3     bigint;
  v_ca     bigint;
  v_cb1    bigint;
  v_cb2    bigint;
  v_cb3    bigint;
  v_cb4    bigint;
  v_n      bigint;
  v_lst    text;
  v_err    text;
  v_asga0  text;
  v_asgb0  text;
  v_asga1  text;
  v_asgb1  text;
  v_tag    text := 'E1553-' || substr(md5(clock_timestamp()::text), 1, 6);
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, adm.id, enc.id, pv.ids[1], pv.ids[2], pv.ids[3]
    INTO v_suc, v_adm, v_enc, v_p1, v_p2, v_p3
    FROM sucursales s
    JOIN LATERAL (SELECT pf.id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY pf.id LIMIT 1) adm ON true
    JOIN LATERAL (SELECT pf.id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado'
                   ORDER BY pf.id LIMIT 1) enc ON true
    JOIN LATERAL (SELECT array_agg(x.id ORDER BY x.id) AS ids
                    FROM (SELECT pf.id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                           WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista'
                           ORDER BY pf.id LIMIT 3) x) pv ON cardinality(pv.ids) = 3
   WHERE s.activa
   ORDER BY s.id DESC
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures: ninguna sucursal activa con admin, encargado y tres preventistas';
  END IF;

  SELECT max(e->>'violaciones') FILTER (WHERE e->>'id' = 'ASG-A'),
         max(e->>'violaciones') FILTER (WHERE e->>'id' = 'ASG-B')
    INTO v_asga0, v_asgb0
    FROM jsonb_array_elements(auditoria_integridad()->'checks') e;

  -- ---------------------------------------------------------------- zonas ---
  INSERT INTO zonas (nombre, sucursal_id) VALUES (v_tag || '-Z1', v_suc) RETURNING id INTO v_z1;
  INSERT INTO zonas (nombre, sucursal_id) VALUES (v_tag || '-Z2', v_suc) RETURNING id INTO v_z2;
  INSERT INTO zonas (nombre, sucursal_id) VALUES (v_tag || '-Z3', v_suc) RETURNING id INTO v_z3;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM asignar_preventista_zona(v_z1, v_p1);
  PERFORM asignar_preventista_zona(v_z2, v_p2);
  EXECUTE 'RESET ROLE';

  -- ------------------------------------------------- A1 · alta en zona propia ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p1, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES (v_tag || '-A', v_tag || '-A', 'dir', v_suc, v_z1) RETURNING id INTO v_ca;
  EXECUTE 'RESET ROLE';

  SELECT string_agg(preventista_id::text, ',') INTO v_lst FROM cliente_preventistas WHERE cliente_id = v_ca;
  IF v_lst IS DISTINCT FROM v_p1::text THEN
    v_fallas := v_fallas || format('A1: el alta del dueño en su zona quedó asignada a [%s], no a P1', COALESCE(v_lst, 'nadie'));
  END IF;
  -- El estado del hallazgo: el segundo pedido todavía no llegó.
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT max(e->>'violaciones') FILTER (WHERE e->>'id' = 'ASG-A') INTO v_asga1
    FROM jsonb_array_elements(auditoria_integridad()->'checks') e;
  IF v_asga1 IS DISTINCT FROM v_asga0 THEN
    v_fallas := v_fallas || format('A1: antes del segundo pedido ASG-A pasó de %s a %s', v_asga0, v_asga1);
  END IF;

  -- ------------------------------------------------- A2 · otro preventista ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p3, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_n FROM clientes WHERE id = v_ca;
  EXECUTE 'RESET ROLE';
  IF v_n <> 0 THEN
    v_fallas := v_fallas || 'A2: otro preventista ve el cliente dado de alta por el dueño de la zona'::text;
  END IF;

  -- ------------------------------------ A3 · segundo pedido del bundle viejo ---
  v_err := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p1, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    DELETE FROM cliente_preventistas WHERE cliente_id = v_ca;
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_ca, v_p1);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN others THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM cliente_preventistas WHERE cliente_id = v_ca;
  IF v_err IS NOT NULL OR v_n <> 1 THEN
    v_fallas := v_fallas || format('A3: el segundo pedido del bundle viejo dio [%s] y quedaron %s filas', COALESCE(v_err, 'ok'), v_n);
  END IF;

  -- ------------------------------------------------ A4 · el repetido otra vez ---
  v_err := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p1, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_ca, v_p1);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN others THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM cliente_preventistas WHERE cliente_id = v_ca;
  IF v_err IS NOT NULL OR v_n <> 1 THEN
    v_fallas := v_fallas || format('A4: reinsertar la asignación existente dio [%s] y quedaron %s filas', COALESCE(v_err, 'ok'), v_n);
  END IF;

  -- ---------------------------------- A5 · las guardas corren antes que la absorción ---
  v_err := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p3, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_ca, v_p1);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN others THEN
    v_err := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS DISTINCT FROM '42501' THEN
    v_fallas := v_fallas || format('A5: otro preventista que reinserta la fila del dueño dio [%s], no 42501', COALESCE(v_err, 'ok'));
  END IF;

  -- -------------------------------------------- B1 · admin en zona con dueño ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES (v_tag || '-B1', v_tag || '-B1', 'dir', v_suc, v_z2) RETURNING id INTO v_cb1;
  EXECUTE 'RESET ROLE';
  SELECT string_agg(preventista_id::text, ',') INTO v_lst FROM cliente_preventistas WHERE cliente_id = v_cb1;
  IF v_lst IS DISTINCT FROM v_p2::text THEN
    v_fallas := v_fallas || format('B1: el alta del admin en Z2 quedó asignada a [%s], no a P2', COALESCE(v_lst, 'nadie'));
  END IF;

  -- ----------------------------------------- B2 · encargado en zona con dueño ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES (v_tag || '-B2', v_tag || '-B2', 'dir', v_suc, v_z2) RETURNING id INTO v_cb2;
  EXECUTE 'RESET ROLE';
  SELECT string_agg(preventista_id::text, ',') INTO v_lst FROM cliente_preventistas WHERE cliente_id = v_cb2;
  IF v_lst IS DISTINCT FROM v_p2::text THEN
    v_fallas := v_fallas || format('B2: el alta del encargado en Z2 quedó asignada a [%s], no a P2', COALESCE(v_lst, 'nadie'));
  END IF;

  -- ---------------------------------------------------- B3 · zona sin dueño ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES (v_tag || '-B3', v_tag || '-B3', 'dir', v_suc, v_z3) RETURNING id INTO v_cb3;
  -- ------------------------------------------------------- B4 · reservado ---
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id, reservado_admin)
  VALUES (v_tag || '-B4', v_tag || '-B4', 'dir', v_suc, v_z1, true) RETURNING id INTO v_cb4;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM cliente_preventistas WHERE cliente_id = v_cb3;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('B3: el alta en una zona sin dueño quedó con %s preventistas', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM cliente_preventistas WHERE cliente_id = v_cb4;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('B4: el reservado quedó con %s preventistas', v_n);
  END IF;

  -- ----------------------------------------------------- B5 · zona ajena ---
  v_err := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p2, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES (v_tag || '-B5', v_tag || '-B5', 'dir', v_suc, v_z1);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN others THEN
    v_err := SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS DISTINCT FROM '42501' THEN
    v_fallas := v_fallas || format('B5: el alta de P2 en la zona de P1 dio [%s], no 42501', COALESCE(v_err, 'ok'));
  END IF;

  -- ------------------------------------------------- B6 · cambio de zona ---
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  UPDATE clientes SET zona_id = v_z1 WHERE id = v_cb1;
  EXECUTE 'RESET ROLE';
  SELECT string_agg(preventista_id::text, ',') INTO v_lst FROM cliente_preventistas WHERE cliente_id = v_cb1;
  IF v_lst IS DISTINCT FROM v_p1::text THEN
    v_fallas := v_fallas || format('B6: el cambio de zona a Z1 dejó [%s], no a P1', COALESCE(v_lst, 'nadie'));
  END IF;

  -- ------------------------------------------ B7 · un admin repite la fila ---
  v_err := NULL;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_ca, v_p1);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN others THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM cliente_preventistas WHERE cliente_id = v_ca;
  IF v_err IS NOT NULL OR v_n <> 1 THEN
    v_fallas := v_fallas || format('B7: el admin que repite la asignación dio [%s] y quedaron %s filas', COALESCE(v_err, 'ok'), v_n);
  END IF;

  -- ------------------------------------------------------ C · ASG-A/ASG-B ---
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT max(e->>'violaciones') FILTER (WHERE e->>'id' = 'ASG-A'),
         max(e->>'violaciones') FILTER (WHERE e->>'id' = 'ASG-B')
    INTO v_asga1, v_asgb1
    FROM jsonb_array_elements(auditoria_integridad()->'checks') e;
  IF v_asga1 IS DISTINCT FROM v_asga0 OR v_asgb1 IS DISTINCT FROM v_asgb0 THEN
    v_fallas := v_fallas || format('C: ASG-A pasó de %s a %s y ASG-B de %s a %s', v_asga0, v_asga1, v_asgb0, v_asgb1);
  END IF;

 EXCEPTION WHEN others THEN
  RAISE EXCEPTION 'ENSAYO FALLO (error inesperado): % %', SQLSTATE, SQLERRM;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLO (%): %', cardinality(v_fallas), array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (sucursal %, ASG-A %→%, ASG-B %→%)', v_suc, v_asga0, v_asga1, v_asgb0, v_asgb1;
END
$ensayo$;
