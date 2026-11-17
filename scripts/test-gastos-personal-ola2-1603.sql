-- Ensayo de la migración NNN_gastos_cuotas_reintegros_y_version (plan #1603, ola 2, tarjeta B8a:
-- 1562-c1 y 1562-b1 de #1562, 1597-b4 y 1597-b5 de #1597, GTO-B y GTO-E de #1545, 1599-b9 de #1599).
--
-- No deja rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una excepción.
-- Antes de aplicar la migración tiene que FALLAR en C1, B1, F1, F2, R1, S1, S2, E1, E2 y V1; después,
-- dar 'ENSAYO OK'. Corre en una base local con la semilla mínima o en una copia de prod.
--
-- Personas: un admin activo de todas las sucursales activas (sale de la base). El ensayo crea un
-- admin de una sola sucursal, los empleados, una liquidación a mano y el rubro.
--
-- 1562-c1 · el tope del IVA tolera un centavo por renglón de la factura (decisión del dueño, D40).
--   C1 · factura A de 254,34 al 27 % con dos renglones de neto 100,13: IVA 54,08 (27,04 + 27,04)
--        entra con 1 renglón (el tope estricto da 54,07); 54,09 no con 1 y sí con 2; 54,10 no con 2.
--        Renglones 0 y 100 no entran (de 1 a 99, decisión del dueño del 17/11); 99 sí. Una factura A
--        de $10 con $9,99 de IVA no entra ni con 99 renglones (tope 2,13 + 0,99). Editar sin mandar
--        los renglones conserva los guardados (2) y el gasto de 54,09 se sigue guardando. Una
--        factura B queda con 1.
-- 1562-b1 · _gasto_cuota no da una cuota negativa.
--   B1 · 0,60 en 120: 119 cuotas de 0,00 y la última 0,60. Para varios costos chicos y grandes y n de
--        1 a 120: ninguna cuota negativa, la suma es el costo al centavo, y donde la regla vieja no
--        daba una última negativa da lo mismo que antes (20,15 en 2: 10,08 + 10,07).
-- 1597-b4 · la fecha del reintegro sigue a la del gasto.
--   F1 · gasto de 1.000 pagado por el empleado E1 hace 5 días: reintegro +1.000 a hace 5 días, saldo
--        1.000. Fecha a hace 10 días: el mismo movimiento pasa a hace 10, saldo 1.000, un solo
--        movimiento. Fecha a hace 8 y monto 1.200: el reintegro original pasa a hace 8 y la
--        corrección (+200) es de hoy; saldo 1.200. Un gasto de hoy de 500 que pasa a 600 (corrección
--        +100 de hoy) y después a hace 3 días: el original va a hace 3 y la corrección queda hoy.
--   F2 · un reintegro que ya está dentro de una liquidación no se mueve: queda con su fecha.
-- 1597-b5 · los rubros de gasto los cambia sólo un admin de todas las sucursales (D46).
--   R1 · el admin de una sola sucursal no crea ni edita un rubro; el de todas, sí.
-- GTO-B · las palabras de sueldo (D45 y la decisión del dueño del 17/11).
--   S1 · son sueldo: «S.A.C.», «S-A-C», «S_A_C», «s. a. c.», «SAC», «Pago de SAC», «SAC 2026»,
--        «Vacaciones», «Vacaciones del personal», «Bolsas SAC» y «Seguro de vacaciones del vehículo»
--        (como hoy), «Remuneraciones», «Remuneración», «Comisiones de vendedores», «Comisión»; no:
--        «Saco», «Cargas sociales», «Combustible», «Luz, agua y gas», y la comisión de un medio de
--        cobro (banco, tarjeta, Mercado Pago o Libre, Posnet, Naranja X, Ualá, MODO, Rapipago,
--        transferencia). Los de antes siguen («Sueldos», «Aguinaldo»).
--   S2 · guardar_rubro_gasto rechaza «Remuneraciones» y «Pago de SAC», y crea «Comisión Posnet».
-- GTO-E · el reintegro toma el empleado FOR UPDATE (pgrowlocks), antes que la rendición.
--   E1 · anular un gasto que pagó un empleado deja su fila tomada FOR UPDATE (antes, sólo la FOR KEY
--        SHARE de la FK del movimiento).
--   E2 · guardar un gasto pagado por un empleado deja su fila tomada FOR UPDATE.
--   E3 · regresión: con el reintegro de 500 anulado, un pago de 500 al mismo empleado no entra
--        (saldo 0 después de la anulación).
-- 1599-b9 · la edición compara la versión (D47).
--   V1 · con el `updated_at` que vio entra; si alguien lo cambió en el medio, no («Este gasto cambió
--        desde que lo abriste…») y el gasto queda como lo dejó el otro guardado; sin la clave (un PWA
--        de antes) entra.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-gastos-personal-ola2-1603.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_ua     uuid;
  v_a2     uuid := gen_random_uuid();
  v_hoy    date := public._tablero_hoy();
  v_rubro  bigint;
  v_e1     bigint;
  v_e2     bigint;
  v_e3     bigint;
  v_e4     bigint;
  v_g      bigint;
  v_g2     bigint;
  v_liq    bigint;
  v_mov    bigint;
  v_u1     timestamptz;
  v_n      int;
  v_x      numeric;
  v_t      text;
  v_tope   text := 'El IVA no puede pasar del 27 % del neto';
  v_ver    text := 'Este gasto cambió desde que lo abriste';
  v_locks  boolean := true;
  v_notas  text := '';
  v_fallas text[] := '{}';
  r        record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------- personas ---
  SELECT us.sucursal_id, us.usuario_id INTO v_s1, v_ua
    FROM usuario_sucursales us
    JOIN perfiles p   ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE NOT EXISTS (SELECT 1 FROM sucursales s2
                      WHERE s2.activa
                        AND NOT EXISTS (SELECT 1 FROM usuario_sucursales u2
                                         WHERE u2.usuario_id = us.usuario_id AND u2.sucursal_id = s2.id))
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de todas las sucursales activas';
  END IF;
  IF (SELECT count(*) FROM sucursales WHERE activa) < 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hacen falta dos sucursales activas (1597-b5)';
  END IF;
  -- El admin de una sola sucursal (handle_new_user lo crea con la de app_metadata).
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_a2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b8a-' || v_a2 || '@ensayo.invalid',
          jsonb_build_object('rol', 'admin', 'sucursal_id', v_s1), '{}', now(), now());
  IF (SELECT count(*) FROM usuario_sucursales WHERE usuario_id = v_a2) <> 1
     OR NOT EXISTS (SELECT 1 FROM perfiles WHERE id = v_a2 AND rol = 'admin' AND activo) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · el admin de una sola sucursal no quedó como se esperaba';
  END IF;
  INSERT INTO gasto_rubros (nombre, grupo) VALUES ('ZZ ensayo b8a ' || gen_random_uuid(), 'otros')
  RETURNING id INTO v_rubro;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por) VALUES (v_s1, 'ZZ b8a uno', 'ayudante', v_ua)
  RETURNING id INTO v_e1;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por) VALUES (v_s1, 'ZZ b8a dos', 'ayudante', v_ua)
  RETURNING id INTO v_e2;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por) VALUES (v_s1, 'ZZ b8a tres', 'ayudante', v_ua)
  RETURNING id INTO v_e3;
  INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por) VALUES (v_s1, 'ZZ b8a cuatro', 'ayudante', v_ua)
  RETURNING id INTO v_e4;
  PERFORM set_config('eb8a.ua', v_ua::text, true);
  PERFORM set_config('eb8a.s1', v_s1::text, true);
  PERFORM set_config('eb8a.rubro', v_rubro::text, true);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.claims(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  -- Una RPC como el front: con el rol authenticated, como p_uid (el admin de todas si es NULL).
  CREATE FUNCTION pg_temp.como(p_sql text, p_uid uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM pg_temp.claims(COALESCE(p_uid, current_setting('eb8a.ua')::uuid), current_setting('eb8a.s1')::bigint);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  END $f$;

  -- '{}' si la RPC falla con el mensaje esperado; si no, lo que pasó.
  CREATE FUNCTION pg_temp.falla(p_que text, p_sql text, p_espera text, p_uid uuid DEFAULT NULL) RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_sql, p_uid);
    EXCEPTION WHEN SQLSTATE 'P0098' THEN RAISE;
      WHEN OTHERS THEN
        RESET ROLE;
        IF position(p_espera IN SQLERRM) > 0 THEN
          RETURN '{}';
        END IF;
        RETURN ARRAY[format('%s: falló con otro mensaje: %s (esperado: %s)', p_que, SQLERRM, p_espera)];
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RESET ROLE;
    RETURN ARRAY[format('%s: anduvo y tenía que fallar', p_que)];
  END $f$;

  -- '{}' si la RPC anda; si no, el error.
  CREATE FUNCTION pg_temp.anda(p_que text, p_sql text, p_uid uuid DEFAULT NULL) RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_sql, p_uid);
    RETURN '{}';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN ARRAY[format('%s: tenía que andar y falló: %s', p_que, SQLERRM)];
  END $f$;

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  -- guardar_gasto como ModalGasto, con lo que cambie p.
  CREATE FUNCTION pg_temp.gg(p jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)',
      jsonb_build_object('sucursal_id', current_setting('eb8a.s1')::bigint, 'compartido', false,
                         'fecha', public._tablero_hoy(), 'rubro_id', current_setting('eb8a.rubro')::bigint,
                         'monto_total', 1210, 'comprobante', 'ninguno', 'comprobante_numero', NULL,
                         'vehiculo_id', NULL, 'repartir_meses', 1, 'origen_pago', 'oficina',
                         'observacion', 'ensayo b8a') || p);
  $f$;

  -- La factura A de 254,34 al 27 % con el IVA y lo que cambie p.
  CREATE FUNCTION pg_temp.fa(p_iva numeric, p jsonb DEFAULT '{}') RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.gg(jsonb_build_object('comprobante', 'factura_a', 'monto_total', 254.34, 'iva', p_iva,
                                         'alicuota_iva', 27) || p);
  $f$;

  -- El id que devolvió la última RPC (como texto).
  CREATE FUNCTION pg_temp.id(p_sql text) RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_sql)::bigint;
  $f$;

  -- Las modalidades con que una transacción en curso tiene tomada la fila de un empleado.
  CREATE FUNCTION pg_temp.modos(p_emp bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    EXECUTE 'SELECT string_agg(m, '','' ORDER BY m) FROM pgrowlocks(''public.empleados'') l, unnest(l.modes) m
              WHERE l.locked_row = (SELECT ctid FROM public.empleados WHERE id = $1)' INTO v USING p_emp;
    RETURN COALESCE(v, '');
  END $f$;

  IF cardinality(pg_temp.falla('canario', 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'otro mensaje')) <> 1
     OR cardinality(pg_temp.anda('canario', 'SELECT 1')) <> 0
     OR cardinality(pg_temp.anda('canario', 'SELECT 1/0')) <> 1
     OR pg_temp.como('SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_ua, v_s1)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  -- pgrowlocks para GTO-E (se deshace con el ensayo).
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pgrowlocks;
  EXCEPTION WHEN OTHERS THEN
    v_locks := false;
    v_notas := v_notas || ' · sin pgrowlocks: E1 y E2 no se miran (' || SQLERRM || ')';
  END;

  -- ============================================================== 1562-c1 ===
  BEGIN
    v_fallas := v_fallas || pg_temp.anda('C1 IVA 54,08 sobre 254,34 con 1 renglón', pg_temp.fa(54.08));
    v_fallas := v_fallas || pg_temp.falla('C1 IVA 54,09 con 1 renglón', pg_temp.fa(54.09), v_tope);
    v_fallas := v_fallas || pg_temp.falla('C1 IVA 54,09 sin decir los renglones', pg_temp.fa(54.09), v_tope);
    v_g := pg_temp.id(pg_temp.fa(54.09, '{"renglones_factura": 2}'));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT iva = 54.09 AND renglones_factura = 2 FROM gastos WHERE id = v_g), 'C1 IVA 54,09 con 2 renglones no quedó');
    v_fallas := v_fallas || pg_temp.falla('C1 IVA 54,10 con 2 renglones', pg_temp.fa(54.10, '{"renglones_factura": 2}'), v_tope);
    v_fallas := v_fallas || pg_temp.falla('C1 renglones 0', pg_temp.fa(54.08, '{"renglones_factura": 0}'),
                  'Los renglones de la factura van de 1 a 99');
    v_fallas := v_fallas || pg_temp.falla('C1 renglones 100', pg_temp.fa(54.08, '{"renglones_factura": 100}'),
                  'Los renglones de la factura van de 1 a 99');
    v_fallas := v_fallas || pg_temp.anda('C1 renglones 99', pg_temp.fa(54.08, '{"renglones_factura": 99}'));
    -- La revisión adversarial: con 999 renglones una factura A de $10 entraba con $9,99 de IVA.
    v_fallas := v_fallas || pg_temp.falla('C1 factura A de 10 con IVA 9,99 y 99 renglones',
                  pg_temp.gg('{"comprobante": "factura_a", "monto_total": 10, "iva": 9.99, "alicuota_iva": 27, "renglones_factura": 99}'),
                  v_tope);
    -- Y el CHECK de la columna, aunque alguien escriba directo.
    BEGIN
      UPDATE gastos SET renglones_factura = 100 WHERE id = v_g;
      v_fallas := v_fallas || 'C1 el CHECK dejó 100 renglones'::text;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- Editar sin la clave (el PWA de antes) conserva los 2 renglones: el IVA de 54,09 sigue entrando.
    v_fallas := v_fallas || pg_temp.anda('C1 editar sin los renglones',
                  pg_temp.fa(54.09, jsonb_build_object('id', v_g, 'observacion', 'ensayo b8a editado')));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT renglones_factura = 2 AND observacion = 'ensayo b8a editado' FROM gastos WHERE id = v_g),
      'C1 la edición sin los renglones no conservó los 2');
    -- Una factura B no lleva IVA: los renglones quedan en 1 aunque vengan.
    v_g := pg_temp.id(pg_temp.gg('{"comprobante": "factura_b", "renglones_factura": 7}'));
    v_fallas := v_fallas || pg_temp.chk((SELECT renglones_factura = 1 FROM gastos WHERE id = v_g),
                  'C1 una factura B no quedó con 1 renglón');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('C1 ' || SQLERRM);
  END;

  -- ============================================================== 1562-b1 ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk(public._gasto_cuota(0.60, 120, 1) = 0 AND public._gasto_cuota(0.60, 120, 119) = 0
                    AND public._gasto_cuota(0.60, 120, 120) = 0.60,
                  format('B1 0,60 en 120 da %s … %s', public._gasto_cuota(0.60, 120, 1), public._gasto_cuota(0.60, 120, 120)));
    v_fallas := v_fallas || pg_temp.chk(public._gasto_cuota(20.15, 2, 1) = 10.08 AND public._gasto_cuota(20.15, 2, 2) = 10.07,
                  'B1 20,15 en 2 no da 10,08 + 10,07');
    v_fallas := v_fallas || pg_temp.chk(public._gasto_cuota(100, 3, 1) = 33.33 AND public._gasto_cuota(100, 3, 3) = 33.34,
                  'B1 100 en 3 no da 33,33 + 33,33 + 33,34');
    FOR r IN
      SELECT c.costo, n.n,
             sum(public._gasto_cuota(c.costo, n.n, k.k)) AS suma,
             min(public._gasto_cuota(c.costo, n.n, k.k)) AS minima,
             bool_and(round(c.costo / n.n, 2) * (n.n - 1) > c.costo
                      OR public._gasto_cuota(c.costo, n.n, k.k)
                         = CASE WHEN k.k < n.n THEN round(c.costo / n.n, 2)
                                ELSE c.costo - round(c.costo / n.n, 2) * (n.n - 1) END) AS igual_que_antes
        FROM unnest(ARRAY[0.01, 0.05, 0.37, 0.59, 0.60, 0.61, 1.19, 1.20, 5.55, 20.15, 99.99, 1000.01, 123456.78]::numeric[]) c(costo)
       CROSS JOIN generate_series(1, 120) n(n)
       CROSS JOIN LATERAL generate_series(1, n.n) k(k)
       GROUP BY c.costo, n.n
    LOOP
      IF r.suma <> r.costo OR r.minima < 0 OR NOT r.igual_que_antes THEN
        v_fallas := v_fallas || format('B1 %s en %s: suma %s, mínima %s, igual que antes %s', r.costo, r.n, r.suma, r.minima, r.igual_que_antes);
        EXIT;
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || ('B1 ' || SQLERRM);
  END;

  -- ============================================================== 1597-b4 ===
  BEGIN
    v_g := pg_temp.id(pg_temp.gg(jsonb_build_object('monto_total', 1000, 'fecha', v_hoy - 5,
                                                    'origen_pago', 'empleado', 'empleado_id', v_e1)));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT count(*) = 1 AND min(fecha) = v_hoy - 5 AND sum(monto) = 1000
         FROM empleado_movimientos WHERE empleado_id = v_e1 AND gasto_id = v_g),
      'F1 el reintegro no nació con la fecha del gasto');
    v_fallas := v_fallas || pg_temp.anda('F1 cambiar la fecha a hace 10 días',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 1000, 'fecha', v_hoy - 10,
                                                'origen_pago', 'empleado', 'empleado_id', v_e1)));
    SELECT count(*), min(fecha)::text || ' saldo ' || sum(monto) INTO v_n, v_t
      FROM empleado_movimientos WHERE empleado_id = v_e1;
    v_fallas := v_fallas || pg_temp.chk(v_n = 1 AND v_t = (v_hoy - 10)::text || ' saldo 1000.00',
                  format('F1 después de mover la fecha: %s movimientos, %s (esperado 1, %s saldo 1000.00)', v_n, v_t, v_hoy - 10));
    v_fallas := v_fallas || pg_temp.anda('F1 cambiar la fecha a hace 8 días y el monto a 1.200',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 1200, 'fecha', v_hoy - 8,
                                                'origen_pago', 'empleado', 'empleado_id', v_e1)));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT string_agg(fecha::text || ':' || monto, ' ' ORDER BY id) FROM empleado_movimientos WHERE empleado_id = v_e1)
        = format('%s:1000.00 %s:200.00', v_hoy - 8, v_hoy)
      AND (SELECT sum(monto) FROM empleado_movimientos WHERE empleado_id = v_e1) = 1200,
      format('F1 con fecha y monto: %s (esperado %s:1000.00 %s:200.00, saldo 1.200)',
             (SELECT string_agg(fecha::text || ':' || monto, ' ' ORDER BY id) FROM empleado_movimientos WHERE empleado_id = v_e1),
             v_hoy - 8, v_hoy));

    -- F2 · el reintegro liquidado no se mueve. Una liquidación a mano, como postgres: su sueldo es
    -- el movimiento de id más alto, así el reintegro queda adentro.
    INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                        saldo_anterior, a_pagar, pagado, fecha_pago, creado_por)
    VALUES (v_e1, v_hoy - 30, v_hoy - 1, 'mensual', v_s1, false, 1200, 1201, 0, v_hoy - 1, v_ua)
    RETURNING id INTO v_liq;
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, liquidacion_id, creado_por)
    VALUES (v_e1, v_hoy - 1, 'sueldo', 1, v_liq, v_ua);
    v_fallas := v_fallas || pg_temp.anda('F2 cambiar la fecha de un gasto ya liquidado',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 1200, 'fecha', v_hoy - 9,
                                                'origen_pago', 'empleado', 'empleado_id', v_e1)));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT string_agg(fecha::text, ' ' ORDER BY id) FROM empleado_movimientos WHERE empleado_id = v_e1 AND gasto_id = v_g)
        = format('%s %s', v_hoy - 8, v_hoy)
      AND (SELECT fecha FROM gastos WHERE id = v_g) = v_hoy - 9
      AND (SELECT sum(monto) FROM empleado_movimientos WHERE empleado_id = v_e1) = 1201,
      'F2 el reintegro liquidado cambió de fecha, o el gasto no');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('F ' || SQLERRM);
  END;

  -- F1 · la corrección del mismo día no se mueve (revisión adversarial, hallazgo 5): gasto de hoy de
  -- 500 de E4 que pasa a 600 (+100 con motivo, hoy) y después a hace 3 días.
  BEGIN
    v_g := pg_temp.id(pg_temp.gg(jsonb_build_object('monto_total', 500, 'origen_pago', 'empleado', 'empleado_id', v_e4)));
    v_fallas := v_fallas || pg_temp.anda('F1 subir el gasto de hoy a 600',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 600, 'origen_pago', 'empleado', 'empleado_id', v_e4)));
    v_fallas := v_fallas || pg_temp.anda('F1 pasar el gasto a hace 3 días',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 600, 'fecha', v_hoy - 3,
                                                'origen_pago', 'empleado', 'empleado_id', v_e4)));
    SELECT string_agg(fecha::text || ':' || monto, ' ' ORDER BY id) INTO v_t
      FROM empleado_movimientos WHERE empleado_id = v_e4 AND gasto_id = v_g;
    v_fallas := v_fallas || pg_temp.chk(v_t = format('%s:500.00 %s:100.00', v_hoy - 3, v_hoy),
                  format('F1 la corrección del mismo día: %s (esperado %s:500.00 %s:100.00)', v_t, v_hoy - 3, v_hoy));
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('F1b ' || SQLERRM);
  END;

  -- ============================================================== 1597-b5 ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('R1 el admin de una sola sucursal crea un rubro',
                  format('SELECT public.guardar_rubro_gasto(p_rubro => %L::jsonb)',
                         jsonb_build_object('nombre', 'ZZ b8a rubro de uno ' || gen_random_uuid(), 'grupo', 'otros')),
                  'Los rubros de gasto son de toda la empresa', v_a2);
    v_fallas := v_fallas || pg_temp.falla('R1 el admin de una sola sucursal edita un rubro',
                  format('SELECT public.guardar_rubro_gasto(p_rubro => %L::jsonb)',
                         jsonb_build_object('id', v_rubro, 'nombre', 'ZZ b8a renombrado por uno')),
                  'Los rubros de gasto son de toda la empresa', v_a2);
    v_fallas := v_fallas || pg_temp.anda('R1 el admin de todas edita un rubro',
                  format('SELECT public.guardar_rubro_gasto(p_rubro => %L::jsonb)',
                         jsonb_build_object('id', v_rubro, 'nombre', 'ZZ b8a renombrado por todas ' || gen_random_uuid())));
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('R ' || SQLERRM);
  END;

  -- ================================================================ GTO-B ===
  BEGIN
    SELECT string_agg(x.nombre, ', ') INTO v_t
      FROM unnest(ARRAY['S.A.C.', 'S-A-C', 'S_A_C', 's. a. c.', 'SAC', 'Pago de SAC', 'SAC 2026', 'Vacaciones',
                        'Vacaciones del personal', 'Bolsas SAC', 'Seguro de vacaciones del vehículo',
                        'Remuneraciones', 'Remuneración', 'Comisiones de vendedores', 'Comisión', 'Sueldos',
                        'Aguinaldo']) x(nombre)
     WHERE NOT public._rubro_es_sueldo(x.nombre);
    v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'S1 no los toma por sueldo: ' || v_t);
    SELECT string_agg(x.nombre, ', ') INTO v_t
      FROM unnest(ARRAY['Saco', 'Cargas sociales', 'Combustible', 'Faltantes de caja', 'Luz, agua y gas',
                        'Comisiones bancarias', 'Comisión de tarjeta de crédito', 'Comisiones Mercado  Pago',
                        'Comisión Mercado Libre', 'Comisión Posnet', 'Comisión Naranja X', 'Comisión Ualá',
                        'Comisión MODO', 'Comisión Rapipago', 'Comisión por transferencia']) x(nombre)
     WHERE public._rubro_es_sueldo(x.nombre);
    v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'S1 los toma por sueldo: ' || v_t);
    v_fallas := v_fallas || pg_temp.falla('S2 rubro «Remuneraciones»',
                  'SELECT public.guardar_rubro_gasto(p_rubro => ''{"nombre": "Remuneraciones", "grupo": "otros"}''::jsonb)',
                  'Los sueldos no son un gasto');
    v_fallas := v_fallas || pg_temp.falla('S2 rubro «Pago de SAC»',
                  'SELECT public.guardar_rubro_gasto(p_rubro => ''{"nombre": "Pago de SAC", "grupo": "otros"}''::jsonb)',
                  'Los sueldos no son un gasto');
    v_fallas := v_fallas || pg_temp.anda('S2 rubro «Comisión Posnet»',
                  'SELECT public.guardar_rubro_gasto(p_rubro => ''{"nombre": "ZZ b8a Comisión Posnet", "grupo": "otros"}''::jsonb)');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('S ' || SQLERRM);
  END;

  -- ================================================================ GTO-E ===
  BEGIN
    -- E1 · el gasto de 500 de E2 se carga como postgres: el trigger escribe el reintegro y la FK
    -- toma a E2 sólo FOR KEY SHARE. Anularlo tiene que tomarlo FOR UPDATE.
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, mes_imputado, origen_pago,
                        empleado_id, observacion, creado_por)
    VALUES (v_s1, v_hoy, v_rubro, 500, 'ninguno', date_trunc('month', v_hoy::timestamp)::date, 'empleado',
            v_e2, 'ensayo b8a', v_ua)
    RETURNING id INTO v_g2;
    v_fallas := v_fallas || pg_temp.chk((SELECT sum(monto) FROM empleado_movimientos WHERE empleado_id = v_e2) = 500,
                  'E1 el reintegro de 500 no está');
    IF v_locks THEN
      v_t := pg_temp.modos(v_e2);
      v_notas := v_notas || ' · E1 antes de anular: {' || v_t || '}';
      v_fallas := v_fallas || pg_temp.chk(position('Update' IN v_t) = 0, 'E1 el empleado ya estaba tomado FOR UPDATE: ' || v_t);
    END IF;
    v_fallas := v_fallas || pg_temp.anda('E1 anular el gasto del empleado',
                  format('SELECT public.anular_gasto(p_gasto_id => %s, p_motivo => %L)', v_g2, 'ensayo b8a'));
    IF v_locks THEN
      v_t := pg_temp.modos(v_e2);
      v_notas := v_notas || ', después: {' || v_t || '}';
      v_fallas := v_fallas || pg_temp.chk(position('For Update' IN v_t) > 0, 'E1 anular no tomó al empleado FOR UPDATE: {' || v_t || '}');
    END IF;
    -- E3 · regresión: con el reintegro anulado no se le pagan los 500.
    v_fallas := v_fallas || pg_temp.chk((SELECT sum(monto) FROM empleado_movimientos WHERE empleado_id = v_e2) = 0,
                  'E3 la anulación no dejó la cuenta en 0');
    v_fallas := v_fallas || pg_temp.falla('E3 pagarle 500 después de la anulación',
                  format('SELECT public.registrar_movimiento_empleado(p_empleado_id => %s, p_movimiento => %L::jsonb)',
                         v_e2, jsonb_build_object('tipo', 'pago', 'monto', 500, 'fecha', v_hoy)),
                  'No se le puede pagar más de lo que se le debe');

    -- E2 · guardar un gasto pagado por E3 lo toma FOR UPDATE.
    IF v_locks THEN
      v_fallas := v_fallas || pg_temp.chk(pg_temp.modos(v_e3) = '', 'E2 el empleado ya estaba tomado');
    END IF;
    v_fallas := v_fallas || pg_temp.anda('E2 guardar un gasto del empleado',
                  pg_temp.gg(jsonb_build_object('monto_total', 300, 'origen_pago', 'empleado', 'empleado_id', v_e3)));
    IF v_locks THEN
      v_t := pg_temp.modos(v_e3);
      v_notas := v_notas || ' · E2 después de guardar: {' || v_t || '}';
      v_fallas := v_fallas || pg_temp.chk(position('For Update' IN v_t) > 0, 'E2 guardar no tomó al empleado FOR UPDATE: {' || v_t || '}');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('E ' || SQLERRM);
  END;

  -- ============================================================== 1599-b9 ===
  BEGIN
    v_g := pg_temp.id(pg_temp.gg('{"monto_total": 700}'));
    SELECT updated_at INTO v_u1 FROM gastos WHERE id = v_g;
    v_fallas := v_fallas || pg_temp.anda('V1 editar con la versión que vio',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 710, 'updated_at_esperado', v_u1)));
    SELECT updated_at INTO v_u1 FROM gastos WHERE id = v_g;
    -- Otro lo guarda en el medio (su transacción le pone otro updated_at).
    UPDATE gastos SET monto_total = 720, updated_at = clock_timestamp() WHERE id = v_g;
    v_fallas := v_fallas || pg_temp.falla('V1 editar con una versión vieja',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 730, 'updated_at_esperado', v_u1)), v_ver);
    v_fallas := v_fallas || pg_temp.chk((SELECT monto_total FROM gastos WHERE id = v_g) = 720,
                  'V1 el segundo guardado pisó al primero');
    v_fallas := v_fallas || pg_temp.anda('V1 editar sin la clave (PWA de antes)',
                  pg_temp.gg(jsonb_build_object('id', v_g, 'monto_total', 740)));
    v_fallas := v_fallas || pg_temp.chk((SELECT monto_total FROM gastos WHERE id = v_g) = 740,
                  'V1 la edición sin la clave no quedó');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('V ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · C1 B1 F1 F2 R1 S1 S2 E1 E2 E3 V1%', v_notas;
END
$ensayo$;
