-- Ensayo de #1314, #1315 y #1316 (plan #1308, tarjeta 3): asignación, zonas y lecturas.
--   1 · #1315 ASG-1 · tablero_clientes_inactivos cuenta a los clientes sin zona:
--       su total es el de las tablas, y los sin zona salen "(sin zona)".
--   2 · #1315 ASG-6 · reporte_ventas_por_cliente cierra contra su propio total:
--       Σ vendedores = Σ clientes = Σ zonas = totales, y = la venta de pedidos.
--   3 · #1314 · el preventista de las lecturas sale de cliente_preventistas y la
--       zona de zonas: la ficha y el tablero no muestran el preventista_id legado
--       desfasado, y cuentas por cobrar trae el nombre de zonas.
--   4 · #1316 ASG-3 · la zona manda en el alta (servidor y encargado), al liberar
--       un reservado, y el preventista sin zonas no da de alta en la zona de otro.
--       El dueño que da de alta en su zona no recibe la fila del trigger (se la
--       pone la app).
--   5 · #1316 ASG-2 · cambiar el rol suelta la cartera y las zonas, y un cliente
--       asignado a mano vuelve al dueño de su zona; salir de la sucursal suelta lo
--       de esa sucursal; el UPDATE de rol/es_default de usuario_sucursales no.
--       perfil_roles no admite el extra preventista (CHECK): se saltea.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula PostgREST con
-- SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1, 2, 3, 4 y 5; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-asignacion-zonas-lecturas-1314-1316.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_suc      bigint;
  v_hoy      date := public._tablero_hoy();
  v_j        jsonb;
  v_n        bigint;
  v_m        bigint;
  v_x        numeric;
  v_y        numeric;
  v_txt      text;
  v_ok       boolean;

  v_z        bigint;   -- zona con dueño
  v_o        uuid;     -- su dueño
  v_z2       bigint;   -- otra zona con dueño, de otro preventista
  v_o2       uuid;
  v_p0       uuid;     -- preventista activo de v_suc sin zonas
  v_enc      uuid;     -- admin o encargado de v_suc (para el alta como sesión)
  v_c        bigint;
  v_k        bigint;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);

  -- ------------------------------------------------ 1 · tablero sin zona ---
  FOR v_suc IN SELECT id FROM sucursales WHERE activa ORDER BY id LOOP
    v_j := public.tablero_clientes_inactivos(v_suc, 14, true);
    WITH v AS (SELECT * FROM public._tablero_ventas(public._tablero_sucursales(v_suc), '2000-01-01', v_hoy)),
    agg AS (SELECT cliente_id, max(fecha) AS ultima FROM v GROUP BY cliente_id)
    SELECT count(*), count(*) FILTER (WHERE c.zona_id IS NULL)
      INTO v_n, v_m
      FROM clientes c LEFT JOIN agg a ON a.cliente_id = c.id
     WHERE c.sucursal_id = ANY (public._tablero_sucursales(v_suc)) AND COALESCE(c.activo, true)
       AND ((a.ultima IS NOT NULL AND v_hoy - a.ultima > 14) OR a.ultima IS NULL);
    IF (v_j->>'total')::bigint <> v_n
       OR jsonb_array_length(v_j->'clientes') <> v_n THEN
      v_fallas := v_fallas || format('1.1 · sucursal %s: el tablero trae %s clientes inactivos y las tablas dan %s',
                                     v_suc, v_j->>'total', v_n);
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j->'clientes') e
     WHERE e->>'zona' = '(sin zona)' AND e->>'zona_id' IS NULL;
    IF v_n <> v_m THEN
      v_fallas := v_fallas || format('1.2 · sucursal %s: %s clientes sin zona salen "(sin zona)", se esperaban %s', v_suc, v_n, v_m);
    END IF;
    SELECT count(*) - count(DISTINCT e->>'cliente_id') INTO v_n FROM jsonb_array_elements(v_j->'clientes') e;
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format('1.3 · sucursal %s: el tablero repite %s clientes', v_suc, v_n);
    END IF;
  END LOOP;

  -- ------------------------------------- 2 · ventas por cliente cierra ---
  v_j := public.reporte_ventas_por_cliente('2026-01-01', v_hoy, NULL, NULL);
  SELECT COALESCE(sum((e->>'total')::numeric), 0), COALESCE(sum((e->>'pedidos')::int), 0)
    INTO v_x, v_n FROM jsonb_array_elements(v_j->'vendedores') e;
  IF v_x <> (v_j->'totales'->>'total')::numeric OR v_n <> (v_j->'totales'->>'pedidos')::bigint THEN
    v_fallas := v_fallas || format('2.1 · Σ vendedores (%s en %s pedidos) no da el total (%s en %s)',
                                   v_x, v_n, v_j->'totales'->>'total', v_j->'totales'->>'pedidos');
  END IF;
  SELECT COALESCE(sum((e->>'total')::numeric), 0) INTO v_y FROM jsonb_array_elements(v_j->'zonas') e;
  SELECT COALESCE(sum(GREATEST(pe.total - pe.cargo_envio, 0)), 0) INTO v_x
    FROM pedidos pe
   WHERE pe.estado = 'entregado' AND COALESCE(pe.canal, 'app') <> 'cambio'
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND pe.fecha BETWEEN '2026-01-01' AND v_hoy
     AND pe.sucursal_id = ANY (public._sucursales_red());
  IF v_y <> v_x OR (v_j->'totales'->>'total')::numeric <> v_x THEN
    v_fallas := v_fallas || format('2.2 · totales %s, Σ zonas %s, venta de pedidos %s', v_j->'totales'->>'total', v_y, v_x);
  END IF;
  IF EXISTS (SELECT 1 FROM pedidos pe
              WHERE pe.usuario_id IS NULL AND pe.estado = 'entregado'
                AND pe.fecha BETWEEN '2026-01-01' AND v_hoy)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'vendedores') e
                      WHERE e->>'id' IS NULL AND e->>'nombre' = '(sin vendedor)') THEN
    v_fallas := v_fallas || '2.3 · hay pedidos sin vendedor y no está la fila "(sin vendedor)"'::text;
  END IF;
  -- La zona de cada cliente es la de zonas, sin el texto legado.
  SELECT count(*) INTO v_n
    FROM jsonb_array_elements(v_j->'clientes') e
    JOIN clientes c ON c.id = (e->>'cliente_id')::bigint
    LEFT JOIN zonas z ON z.id = c.zona_id
   WHERE e->>'zona' IS DISTINCT FROM COALESCE(z.nombre, 'SIN ZONA');
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('2.4 · %s clientes de ventas por cliente no traen la zona de zonas', v_n);
  END IF;

  -- -------------------------------- 3 · las lecturas no miran lo legado ---
  -- 3.1 · La ficha de un cliente con preventista_id desfasado (sin fila en
  -- cliente_preventistas) no muestra a ese preventista, salvo que sea el dueño
  -- de la zona.
  SELECT c.id INTO v_c
    FROM clientes c JOIN perfiles pf ON pf.id = c.preventista_id
   WHERE NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
     AND pf.nombre IS DISTINCT FROM (SELECT p2.nombre FROM preventista_zonas pz JOIN perfiles p2 ON p2.id = pz.perfil_id
                                      WHERE pz.zona_id = c.zona_id)
   ORDER BY c.id LIMIT 1;
  IF v_c IS NULL THEN
    v_saltados := v_saltados || '3.1: no hay cliente con preventista_id desfasado'::text;
  ELSE
    v_j := public.tablero_ficha_cliente(v_c);
    IF v_j->'cliente'->>'preventista' IS NOT DISTINCT FROM
       (SELECT pf.nombre FROM clientes c JOIN perfiles pf ON pf.id = c.preventista_id WHERE c.id = v_c) THEN
      v_fallas := v_fallas || format('3.1 · la ficha del cliente %s muestra el preventista_id legado (%s)', v_c, v_j->'cliente'->>'preventista');
    END IF;
  END IF;

  -- 3.2 · En el tablero, todo cliente con fila en cliente_preventistas trae ese
  -- preventista.
  SELECT count(*) INTO v_n
    FROM sucursales s
    CROSS JOIN LATERAL jsonb_array_elements(public.tablero_clientes_inactivos(s.id, 14, true)->'clientes') e
    JOIN cliente_preventistas cp ON cp.cliente_id = (e->>'cliente_id')::bigint
   WHERE s.activa AND (e->>'preventista_id')::uuid IS DISTINCT FROM cp.preventista_id;
  IF v_n > 0 THEN
    v_fallas := v_fallas || format('3.2 · %s clientes del tablero no traen el preventista de cliente_preventistas', v_n);
  END IF;

  -- 3.3 · Cuentas por cobrar trae el nombre de zonas.
  FOR v_suc IN SELECT id FROM sucursales WHERE activa ORDER BY id LOOP
    v_j := public.reporte_cuentas_por_cobrar(v_suc);
    SELECT count(*) INTO v_n
      FROM jsonb_array_elements(v_j->'clientes') e
      JOIN clientes c ON c.id = (e->'cliente'->>'id')::bigint
      LEFT JOIN zonas z ON z.id = c.zona_id
     WHERE e->'cliente'->>'zona' IS DISTINCT FROM z.nombre;
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('3.3 · sucursal %s: %s clientes de cuentas por cobrar no traen la zona de zonas', v_suc, v_n);
    END IF;
  END LOOP;

  -- 3.4 · La hoja de ruta del depósito no lee el texto legado.
  IF pg_get_functiondef('public.hojas_de_ruta_deposito(date)'::regprocedure) ~ '\mc\.zona\M' THEN
    v_fallas := v_fallas || '3.4 · hojas_de_ruta_deposito sigue leyendo clientes.zona'::text;
  END IF;
  -- Y corre (plpgsql no valida el SQL del cuerpo hasta ejecutarlo): como un
  -- admin, el último día con recorridos.
  SELECT p.id, min(us.sucursal_id) INTO v_enc, v_suc
    FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'admin' AND p.activo
   GROUP BY p.id ORDER BY p.id LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM public.hojas_de_ruta_deposito((SELECT max(fecha) FROM recorridos WHERE sucursal_id = v_suc));
  PERFORM set_config('request.jwt.claims', '', true);
  v_enc := NULL;

  -- ------------------------------------------- 4 · la zona manda (alta) ---
  -- Dos zonas con dueños distintos en la misma sucursal, un preventista activo
  -- de esa sucursal sin zonas y un admin o encargado de ella.
  SELECT pz.zona_id, pz.perfil_id, pz.sucursal_id INTO v_z, v_o, v_suc
    FROM preventista_zonas pz JOIN perfiles p ON p.id = pz.perfil_id
   WHERE p.rol = 'preventista' AND p.activo
   ORDER BY pz.zona_id LIMIT 1;
  SELECT pz.zona_id, pz.perfil_id INTO v_z2, v_o2
    FROM preventista_zonas pz JOIN perfiles p ON p.id = pz.perfil_id
   WHERE p.rol = 'preventista' AND p.activo AND pz.sucursal_id = v_suc AND pz.perfil_id <> v_o
   ORDER BY pz.zona_id LIMIT 1;
  -- El preventista sin zonas y el encargado pueden no trabajar en v_suc (o no
  -- existir): se los suma a la sucursal, y a falta de encargado se convierte a
  -- un transportista. Todo se deshace al final.
  SELECT p.id INTO v_p0
    FROM perfiles p
   WHERE p.rol = 'preventista' AND p.activo
     AND NOT EXISTS (SELECT 1 FROM preventista_zonas pz WHERE pz.perfil_id = p.id)
   ORDER BY p.id LIMIT 1;
  SELECT p.id INTO v_enc
    FROM perfiles p
   WHERE p.rol = 'encargado' AND p.activo
   ORDER BY p.id LIMIT 1;
  IF v_enc IS NULL THEN
    SELECT p.id INTO v_enc
      FROM perfiles p
     WHERE p.rol = 'transportista' AND p.activo
     ORDER BY p.id LIMIT 1;
    UPDATE perfiles SET rol = 'encargado' WHERE id = v_enc;
  END IF;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  SELECT u, v_suc, 'mismo', false FROM unnest(ARRAY[v_p0, v_enc]) AS u WHERE u IS NOT NULL AND v_suc IS NOT NULL
  ON CONFLICT (usuario_id, sucursal_id) DO NOTHING;

  IF v_z IS NULL OR v_z2 IS NULL THEN
    v_saltados := v_saltados || '4 y 5: no hay dos zonas con dueños distintos en una sucursal'::text;
  ELSE
    -- 4.1 · Alta por el servidor en la zona de O.
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES ('ENSAYO 1316 a', 'ENSAYO 1316 a', 'Ensayo 1', v_suc, v_z)
    RETURNING id INTO v_c;
    IF NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_c AND preventista_id = v_o)
       OR (SELECT count(*) FROM cliente_preventistas WHERE cliente_id = v_c) <> 1 THEN
      v_fallas := v_fallas || '4.1 · el cliente dado de alta en una zona con dueño no quedó asignado a su dueño'::text;
    END IF;

    -- 4.2 · Un reservado no recibe preventista; al liberarlo, pasa al dueño.
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id, reservado_admin)
    VALUES ('ENSAYO 1316 b', 'ENSAYO 1316 b', 'Ensayo 2', v_suc, v_z, true)
    RETURNING id INTO v_k;
    IF EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_k) THEN
      v_fallas := v_fallas || '4.2 · el reservado recibió preventista en el alta'::text;
    END IF;
    UPDATE clientes SET reservado_admin = false WHERE id = v_k;
    IF NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_k AND preventista_id = v_o) THEN
      v_fallas := v_fallas || '4.3 · el reservado liberado no pasó al dueño de su zona'::text;
    END IF;

    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    -- 4.4 · Alta de un encargado (sesión) en la zona de O.
    IF v_enc IS NULL THEN
      v_saltados := v_saltados || '4.4: no hay encargado ni transportista activo'::text;
    ELSE
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_enc, 'role', 'authenticated')::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE $q$INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
                 VALUES ('ENSAYO 1316 c', 'ENSAYO 1316 c', 'Ensayo 3', $1, $2) RETURNING id$q$
        INTO v_c USING v_suc, v_z;
      EXECUTE 'RESET ROLE';
      IF NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_c AND preventista_id = v_o) THEN
        v_fallas := v_fallas || '4.4 · el alta del encargado en una zona con dueño quedó sin asignar'::text;
      END IF;
    END IF;

    -- 4.5 · El preventista sin zonas no da de alta en la zona de O.
    IF v_p0 IS NULL THEN
      v_saltados := v_saltados || '4.5: no hay preventista activo sin zonas'::text;
    ELSE
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_p0, 'role', 'authenticated')::text, true);
      v_ok := false;
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE $q$INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
                   VALUES ('ENSAYO 1316 d', 'ENSAYO 1316 d', 'Ensayo 4', $1, $2)$q$
          USING v_suc, v_z;
        EXECUTE 'RESET ROLE';
      EXCEPTION WHEN insufficient_privilege THEN
        -- 42501 también es la RLS de mt_clientes_insert: tiene que ser el guard.
        v_ok := SQLERRM LIKE '%la atiende otro preventista%';
        IF NOT v_ok THEN
          v_fallas := v_fallas || format('4.5 · el alta del preventista sin zonas falló por otra cosa: %s', SQLERRM);
        END IF;
      END;
      IF NOT v_ok AND NOT EXISTS (SELECT 1 FROM unnest(v_fallas) f WHERE f LIKE '4.5 ·%') THEN
        v_fallas := v_fallas || '4.5 · el preventista sin zonas dio de alta un cliente en la zona de otro'::text;
      END IF;
    END IF;

    -- 4.6 · El dueño da de alta en su zona: el trigger no le pone la fila (la
    -- pone la app, y un bundle viejo con INSERT pelado daría 23505).
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_o, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE $q$INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
               VALUES ('ENSAYO 1316 e', 'ENSAYO 1316 e', 'Ensayo 5', $1, $2) RETURNING id$q$
      INTO v_c USING v_suc, v_z;
    EXECUTE $q$INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES ($1, $2)$q$ USING v_c, v_o;
    EXECUTE 'RESET ROLE';
    IF (SELECT count(*) FROM cliente_preventistas WHERE cliente_id = v_c) <> 1 THEN
      v_fallas := v_fallas || '4.6 · el alta del dueño en su zona no quedó con él solo'::text;
    END IF;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ------------------------------------------ 5 · soltar la cartera ---
    -- K: cliente de la zona de O2 asignado a mano a O.
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES ('ENSAYO 1316 f', 'ENSAYO 1316 f', 'Ensayo 6', v_suc, v_z2)
    RETURNING id INTO v_k;
    DELETE FROM cliente_preventistas WHERE cliente_id = v_k;
    INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_k, v_o);

    -- 5.1 · El UPDATE de asignar_usuario_sucursal (rol, es_default) no suelta nada.
    SELECT count(*) INTO v_n FROM cliente_preventistas WHERE preventista_id = v_o;
    UPDATE usuario_sucursales SET rol = rol, es_default = es_default
     WHERE usuario_id = v_o AND sucursal_id = v_suc;
    IF (SELECT count(*) FROM cliente_preventistas WHERE preventista_id = v_o) <> v_n THEN
      v_fallas := v_fallas || '5.1 · actualizar rol/es_default de usuario_sucursales soltó la cartera'::text;
    END IF;

    -- 5.2 · O pasa a transportista: suelta cartera y zonas; K vuelve a O2 y los
    -- de su zona quedan sin asignar.
    UPDATE perfiles SET rol = 'transportista' WHERE id = v_o;
    IF EXISTS (SELECT 1 FROM cliente_preventistas WHERE preventista_id = v_o)
       OR EXISTS (SELECT 1 FROM preventista_zonas WHERE perfil_id = v_o) THEN
      v_fallas := v_fallas || '5.2 · el preventista que pasó a transportista se quedó con cartera o zonas'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM cliente_preventistas WHERE cliente_id = v_k AND preventista_id = v_o2) THEN
      v_fallas := v_fallas || '5.3 · el cliente asignado a mano no volvió al dueño de su zona'::text;
    END IF;

    -- 5.4 · O2 sale de la sucursal: suelta lo de ahí.
    DELETE FROM usuario_sucursales WHERE usuario_id = v_o2 AND sucursal_id = v_suc;
    IF EXISTS (SELECT 1 FROM cliente_preventistas cp JOIN clientes c ON c.id = cp.cliente_id
                WHERE cp.preventista_id = v_o2 AND c.sucursal_id = v_suc)
       OR EXISTS (SELECT 1 FROM preventista_zonas WHERE perfil_id = v_o2 AND sucursal_id = v_suc) THEN
      v_fallas := v_fallas || '5.4 · el preventista que salió de la sucursal se quedó con su cartera o sus zonas ahí'::text;
    END IF;
  END IF;

  v_saltados := v_saltados || '5 (perfil_roles): el CHECK sólo admite el extra transportista'::text;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK #1314 #1315 #1316 (asignación, zonas y lecturas)%',
      CASE WHEN cardinality(v_saltados) > 0 THEN ' · saltados: ' || array_to_string(v_saltados, ' | ') ELSE '' END;
  ELSE
    RAISE EXCEPTION 'ENSAYO FALLÓ #1314 #1315 #1316: % %',
      array_to_string(v_fallas, ' | '),
      CASE WHEN cardinality(v_saltados) > 0 THEN ' · saltados: ' || array_to_string(v_saltados, ' | ') ELSE '' END;
  END IF;
END
$ensayo$;
