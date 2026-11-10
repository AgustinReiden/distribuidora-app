-- Ensayo de la 486 (#1519, tarjeta 8 de #1524): una sola fuente del rol, el personal fuera de
-- audit_logs, los pagos y las sustituciones que ve el preventista, y las fugas menores de personal.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de empleado_movimientos_id_seq y
-- rendicion_faltantes_id_seq que consumen los INSERT de G3): un único DO que termina SIEMPRE en una
-- excepción, y cada caso corre en su propio sub-bloque que se revierte al terminar. Las lecturas
-- van como PostgREST: `SET LOCAL ROLE authenticated`, el `sub` de un perfil real en
-- request.jwt.claims y la sucursal en x-sucursal-id. Lo único que se escribe es la preparación de
-- R3, G2 y G3, como el dueño de las tablas y adentro del sub-bloque que se revierte.
--
-- Las personas salen de prod: un admin sólo de la 1, uno sólo de la 2, uno de las dos, un
-- encargado, el preventista de una sola sucursal que más cobros de boletas ajenas veía, y un
-- transportista puro con boletas cobradas.
--
-- Sin la migración tiene que FALLAR en R1, R3, R5, A1, A3, P1, P2, S1, G1, G2 y G3. R2, R4, A2,
-- A4, P3, P4, P5 y S2 pasan antes y después (regresiones; R2 porque hoy todas las filas son 'mismo').
-- Medido el 10/11, en una transacción revertida: sin la migración, 16 fallas (el admin sólo de la
-- 1 leía 21 filas de personal; el preventista, 1116 pagos de boletas que no ve y 14 sustituciones
-- en vez de 6); con ella pegada antes, 'ENSAYO OK'.
--
-- R · el rol (SEG-02 · VTA-08)
--   R1  · ninguna función lee us.rol ni usuario_sucursales.rol; el CHECK fija 'mismo'; la firma
--         vieja de asignar_usuario_sucursal no está y la nueva la ejecuta authenticated, no anon
--   R2  · _rol_en_sucursal(u, s) es perfiles.rol en cada fila de usuario_sucursales, y NULL para
--         una sucursal que no es del usuario
--   R3  · obtener_sucursales_usuario da perfiles.rol en cada sucursal, y nada a un desactivado
--   R4  · reporte_stock_red: el admin sólo de la 2 entra; el encargado, no
--   R5  · asignar_usuario_sucursal: el preventista no asigna; el admin de las dos reasigna la
--         default de un preventista de la 1 y la fila sigue en 'mismo'
-- A · audit_logs (GTO-1)
--   A1  · el admin sólo de la 1 no lee ninguna fila de empleados ni de empleado_*, y sí las demás
--   A2  · el admin de las dos, en la 1, lee todas las de personal de la 1
--   A3  · es_admin_de_todas_las_sucursales(): true para el de las dos, false para el de una y el
--         encargado; la ejecuta authenticated y no anon
--   A4  · el encargado no lee audit_logs
-- P · pagos (SEG-04)
--   P1  · el preventista no ve ningún pago de una boleta que no ve
--   P2  · el preventista ve exactamente los pagos de sus boletas y los créditos sueltos de los
--         clientes que opera
--   P3  · el saldo de un cliente con cobros ajenos le llega igual que al servidor
--   P4  · el transportista ve los pagos de las boletas que reparte, como antes
--   P5  · el admin de la 1 ve todos los pagos de la 1
-- S · sustituciones (SEG-04)
--   S1  · el preventista ve sólo las de sus pedidos
--   S2  · el admin de la 1 ve todas las de la 1
-- G · personal (GTO-10)
--   G1  · cliente_admite_adelanto_sueldo: el admin de la 2 pregunta por la cuenta de un empleado
--         de la 1 → false; el de la 1 → true
--   G2  · empleados_para_elegir con un empleado «de las dos» cuyo usuario es sólo de la 1: el admin
--         sólo de la 2 y el encargado de la 2 lo ven sin usuario_id; el admin de las dos, con él
--   G3  · obtener_faltantes_rendiciones: el transportista ve sin empleado la línea cargada a otro y
--         con su nombre la suya; el admin ve las dos con nombre
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas.
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-rol-personal-pagos-1519.sql

DO $ensayo$
DECLARE
  v_a1     uuid;  -- admin sólo de la 1
  v_a2     uuid;  -- admin sólo de la 2
  v_a12    uuid;  -- admin de la 1 y la 2
  v_e      uuid;  -- encargado
  v_e_suc  bigint;
  v_p      uuid;  -- preventista de una sola sucursal que veía cobros de boletas ajenas
  v_p_suc  bigint;
  v_t      uuid;  -- transportista puro con boletas cobradas
  v_t_suc  bigint;
  v_emp_t  bigint;  -- el empleado del transportista
  v_emp_o  bigint;  -- otro empleado de la sucursal del transportista, con usuario
  v_cli    bigint;
  v_n      bigint;
  v_m      bigint;
  v_res    text;
  v_j      jsonb;
  v_mov    bigint;
  v_txt    text;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  CREATE FUNCTION pg_temp.sucs(p uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(sucursal_id::text, ',' ORDER BY sucursal_id) FROM public.usuario_sucursales WHERE usuario_id = p
  $f$;
  SELECT id INTO v_a1  FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '1'   ORDER BY id LIMIT 1;
  SELECT id INTO v_a2  FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '2'   ORDER BY id LIMIT 1;
  SELECT id INTO v_a12 FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '1,2' ORDER BY id LIMIT 1;
  SELECT p.id, us.sucursal_id INTO v_e, v_e_suc
    FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'encargado' AND p.activo ORDER BY p.id LIMIT 1;
  SELECT x.id, x.suc INTO v_p, v_p_suc
    FROM (SELECT p.id, pg_temp.sucs(p.id)::bigint AS suc,
                 (SELECT count(*) FROM pagos pg JOIN pedidos pd ON pd.id = pg.pedido_id
                   WHERE pd.usuario_id <> p.id AND pg.sucursal_id = pg_temp.sucs(p.id)::bigint
                     AND EXISTS (SELECT 1 FROM pedidos x WHERE x.cliente_id = pg.cliente_id AND x.usuario_id = p.id)) AS ajenos
            FROM perfiles p
           WHERE p.rol = 'preventista' AND p.activo AND pg_temp.sucs(p.id) ~ '^\d+$'
             AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id)) x
   ORDER BY x.ajenos DESC, x.id LIMIT 1;
  SELECT p.id, pg_temp.sucs(p.id)::bigint INTO v_t, v_t_suc
    FROM perfiles p
   WHERE p.rol = 'transportista' AND p.activo AND pg_temp.sucs(p.id) ~ '^\d+$'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id)
     AND EXISTS (SELECT 1 FROM empleados e WHERE e.usuario_id = p.id AND e.activo)
     AND EXISTS (SELECT 1 FROM pagos pg JOIN pedidos pd ON pd.id = pg.pedido_id WHERE pd.transportista_id = p.id)
   ORDER BY p.id LIMIT 1;
  SELECT id INTO v_emp_t FROM empleados WHERE usuario_id = v_t AND activo ORDER BY id LIMIT 1;
  SELECT e.id INTO v_emp_o FROM empleados e
   WHERE e.activo AND e.usuario_id IS NOT NULL AND e.usuario_id <> v_t AND e.sucursal_id = v_t_suc
     AND pg_temp.sucs(e.usuario_id) = v_t_suc::text
   ORDER BY e.id LIMIT 1;
  IF v_a1 IS NULL OR v_a2 IS NULL OR v_a12 IS NULL OR v_e IS NULL OR v_p IS NULL OR v_t IS NULL
     OR v_emp_t IS NULL OR v_emp_o IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: a1 % a2 % a12 % e % p % t % emp_t % emp_o %',
      v_a1, v_a2, v_a12, v_e, v_p, v_t, v_emp_t, v_emp_o;
  END IF;
  v_notas := v_notas || format('preventista %s (suc %s), transportista %s (suc %s)', v_p, v_p_suc, v_t, v_t_suc);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  CREATE FUNCTION pg_temp.servidor() RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', '{}', true);
    PERFORM set_config('request.headers', '{}', true);
  END $f$;
  -- Un SELECT escalar como PostgREST, o 'ERR SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest_val(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN COALESCE(v, '(null)');
  EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE || ' ' || SQLERRM;
  END $f$;

  -- ==================================================================== R ===
  BEGIN
    PERFORM pg_temp.servidor();
    -- R1 · catálogo
    SELECT string_agg(oid::regprocedure::text, ', ') INTO v_txt FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace AND prosrc ~ '(\mus\d?\.rol\M|usuario_sucursales\.rol\M)';
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || format('R1 · leen usuario_sucursales.rol: %s', v_txt);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.usuario_sucursales'::regclass
                     AND pg_get_constraintdef(oid) = 'CHECK (((rol)::text = ''mismo''::text))') THEN
      v_fallas := v_fallas || text 'R1 · usuario_sucursales.rol no está fija en mismo';
    END IF;
    IF to_regprocedure('public.asignar_usuario_sucursal(uuid,bigint,character varying,boolean)') IS NOT NULL
       OR to_regprocedure('public.asignar_usuario_sucursal(uuid,bigint,boolean)') IS NULL THEN
      v_fallas := v_fallas || text 'R1 · asignar_usuario_sucursal sigue con p_rol';
    ELSIF NOT has_function_privilege('authenticated', 'public.asignar_usuario_sucursal(uuid,bigint,boolean)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.asignar_usuario_sucursal(uuid,bigint,boolean)', 'EXECUTE') THEN
      v_fallas := v_fallas || text 'R1 · asignar_usuario_sucursal: EXECUTE distinto de authenticated sí, anon no';
    END IF;

    -- R2 · _rol_en_sucursal
    SELECT count(*) INTO v_n FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
     WHERE public._rol_en_sucursal(us.usuario_id, us.sucursal_id) IS DISTINCT FROM p.rol;
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('R2 · %s filas con _rol_en_sucursal distinto de perfiles.rol', v_n);
    END IF;
    IF public._rol_en_sucursal(v_a1, 2) IS NOT NULL THEN
      v_fallas := v_fallas || text 'R2 · _rol_en_sucursal da rol en una sucursal que no es del usuario';
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || ('R1-R2 · error inesperado: ' || SQLERRM);
  END;

  BEGIN
    -- R3 · obtener_sucursales_usuario
    PERFORM pg_temp.como(v_p, v_p_suc);
    v_res := pg_temp.rest_val('SELECT public.obtener_sucursales_usuario()::text');
    IF v_res LIKE 'ERR%' OR v_res = '(null)'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_res::jsonb) x WHERE x->>'rol' IS DISTINCT FROM 'preventista') THEN
      v_fallas := v_fallas || format('R3 · el preventista recibe %s', v_res);
    END IF;
    PERFORM pg_temp.servidor();
    UPDATE perfiles SET activo = false WHERE id = v_p;
    PERFORM pg_temp.como(v_p, v_p_suc);
    v_res := pg_temp.rest_val('SELECT public.obtener_sucursales_usuario()::text');
    IF v_res <> '(null)' THEN
      v_fallas := v_fallas || format('R3 · el preventista desactivado recibe %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R3 · error inesperado: ' || SQLERRM);
  END;

  BEGIN
    -- R4 · reporte_stock_red
    PERFORM pg_temp.como(v_a2, 2);
    v_res := pg_temp.rest_val('SELECT public.reporte_stock_red(NULL)->''meta''->>''sucursal_nombre''');
    IF v_res <> 'Red (consolidado)' THEN
      v_fallas := v_fallas || format('R4 · el admin de la 2 no entra a la red: %s', v_res);
    END IF;
    PERFORM pg_temp.como(v_e, v_e_suc);
    v_res := pg_temp.rest_val('SELECT public.reporte_stock_red(NULL)->''meta''->>''sucursal_nombre''');
    IF v_res NOT LIKE 'ERR % Acceso denegado%' THEN
      v_fallas := v_fallas || format('R4 · el encargado: %s', v_res);
    END IF;

    -- R5 · asignar_usuario_sucursal
    PERFORM pg_temp.como(v_p, v_p_suc);
    v_res := pg_temp.rest_val(format('SELECT public.asignar_usuario_sucursal(%L, %s, true)->>''error''', v_p, v_p_suc));
    IF v_res <> 'Solo admin puede asignar sucursales' THEN
      v_fallas := v_fallas || format('R5 · el preventista: %s', v_res);
    END IF;
    PERFORM pg_temp.como(v_a12, v_p_suc);
    v_res := pg_temp.rest_val(format('SELECT public.asignar_usuario_sucursal(%L, %s, true)::text', v_p, v_p_suc));
    PERFORM pg_temp.servidor();
    IF v_res <> '{"success": true}'
       OR (SELECT rol FROM usuario_sucursales WHERE usuario_id = v_p AND sucursal_id = v_p_suc) <> 'mismo'
       OR NOT (SELECT es_default FROM usuario_sucursales WHERE usuario_id = v_p AND sucursal_id = v_p_suc) THEN
      v_fallas := v_fallas || format('R5 · el admin de las dos: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R4-R5 · error inesperado: ' || SQLERRM);
  END;

  -- ==================================================================== A ===
  BEGIN
    PERFORM pg_temp.servidor();
    SELECT count(*) INTO v_m FROM audit_logs WHERE sucursal_id = 1 AND tabla LIKE 'empleado%';
    IF v_m = 0 THEN
      v_notas := v_notas || text 'A · no hay filas de personal en la 1: A1 y A2 no prueban nada';
    END IF;
    -- A1
    PERFORM pg_temp.como(v_a1, 1);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.audit_logs WHERE tabla LIKE ''empleado%''');
    IF v_res <> '0' THEN
      v_fallas := v_fallas || format('A1 · el admin sólo de la 1 lee %s filas de personal', v_res);
    END IF;
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.audit_logs WHERE tabla NOT LIKE ''empleado%''');
    IF v_res LIKE 'ERR%' OR v_res = '0' THEN
      v_fallas := v_fallas || format('A1 · el admin sólo de la 1 no lee las demás filas: %s', v_res);
    END IF;
    -- A2
    PERFORM pg_temp.como(v_a12, 1);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.audit_logs WHERE tabla LIKE ''empleado%''');
    IF v_res <> v_m::text THEN
      v_fallas := v_fallas || format('A2 · el admin de las dos lee %s filas de personal de %s', v_res, v_m);
    END IF;
    -- A3
    PERFORM pg_temp.como(v_a12, 1);
    v_txt := pg_temp.rest_val('SELECT public.es_admin_de_todas_las_sucursales()::text');
    PERFORM pg_temp.como(v_a1, 1);
    v_txt := v_txt || ' ' || pg_temp.rest_val('SELECT public.es_admin_de_todas_las_sucursales()::text');
    PERFORM pg_temp.como(v_e, v_e_suc);
    v_txt := v_txt || ' ' || pg_temp.rest_val('SELECT public.es_admin_de_todas_las_sucursales()::text');
    IF v_txt <> 'true false false' THEN
      v_fallas := v_fallas || format('A3 · de las dos, de una y encargado: %s', v_txt);
    END IF;
    IF to_regprocedure('public.es_admin_de_todas_las_sucursales()') IS NULL
       OR has_function_privilege('anon', 'public.es_admin_de_todas_las_sucursales()', 'EXECUTE') THEN
      v_fallas := v_fallas || text 'A3 · es_admin_de_todas_las_sucursales() no está o la ejecuta anon';
    END IF;
    -- A4
    PERFORM pg_temp.como(v_e, v_e_suc);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.audit_logs');
    IF v_res <> '0' THEN
      v_fallas := v_fallas || format('A4 · el encargado lee %s filas de audit_logs', v_res);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || ('A · error inesperado: ' || SQLERRM);
  END;

  -- ==================================================================== P ===
  BEGIN
    -- P1
    PERFORM pg_temp.como(v_p, v_p_suc);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.pagos pg WHERE pg.pedido_id IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM public.pedidos pd WHERE pd.id = pg.pedido_id)');
    IF v_res <> '0' THEN
      v_fallas := v_fallas || format('P1 · el preventista ve %s pagos de boletas que no ve', v_res);
    END IF;
    -- P2 · lo esperado, como el servidor
    PERFORM pg_temp.servidor();
    SELECT count(*) INTO v_m FROM pagos pg
     WHERE pg.sucursal_id = v_p_suc
       AND ((pg.pedido_id IS NOT NULL AND EXISTS (SELECT 1 FROM pedidos pd WHERE pd.id = pg.pedido_id AND pd.usuario_id = v_p))
            OR (pg.pedido_id IS NULL AND EXISTS (
                  SELECT 1 FROM clientes c WHERE c.id = pg.cliente_id AND NOT c.reservado_admin
                     AND (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
                          OR EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id AND cp.preventista_id = v_p)))));
    PERFORM pg_temp.como(v_p, v_p_suc);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.pagos');
    IF v_res <> v_m::text THEN
      v_fallas := v_fallas || format('P2 · el preventista ve %s pagos; esperado %s', v_res, v_m);
    END IF;
    v_notas := v_notas || format('P2 · el preventista ve %s pagos', v_m);
    -- P3 · el saldo de un cliente con cobros ajenos
    PERFORM pg_temp.servidor();
    SELECT pg.cliente_id INTO v_cli FROM pagos pg JOIN pedidos pd ON pd.id = pg.pedido_id
     WHERE pd.usuario_id <> v_p AND pg.sucursal_id = v_p_suc
       AND EXISTS (SELECT 1 FROM pedidos x WHERE x.cliente_id = pg.cliente_id AND x.usuario_id = v_p)
     ORDER BY pg.id DESC LIMIT 1;
    IF v_cli IS NOT NULL THEN
      SELECT saldo_cuenta::text INTO v_txt FROM clientes WHERE id = v_cli;
      PERFORM pg_temp.como(v_p, v_p_suc);
      v_res := pg_temp.rest_val(format('SELECT saldo_cuenta::text FROM public.clientes WHERE id = %s', v_cli));
      IF v_res IS DISTINCT FROM v_txt THEN
        v_fallas := v_fallas || format('P3 · saldo del cliente %s: %s, esperado %s', v_cli, v_res, v_txt);
      END IF;
    ELSE
      v_notas := v_notas || text 'P3 · sin cliente con cobros ajenos';
    END IF;
    -- P4 · el transportista
    PERFORM pg_temp.servidor();
    SELECT count(*) INTO v_m FROM pagos pg JOIN pedidos pd ON pd.id = pg.pedido_id
     WHERE pg.sucursal_id = v_t_suc AND pd.transportista_id = v_t AND pd.sucursal_id = v_t_suc;
    PERFORM pg_temp.como(v_t, v_t_suc);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.pagos');
    IF v_res <> v_m::text THEN
      v_fallas := v_fallas || format('P4 · el transportista ve %s pagos; esperado %s', v_res, v_m);
    END IF;
    -- P5 · el admin de la 1
    PERFORM pg_temp.servidor();
    SELECT count(*) INTO v_m FROM pagos WHERE sucursal_id = 1;
    PERFORM pg_temp.como(v_a1, 1);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.pagos');
    IF v_res <> v_m::text THEN
      v_fallas := v_fallas || format('P5 · el admin de la 1 ve %s pagos; esperado %s', v_res, v_m);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || ('P · error inesperado: ' || SQLERRM);
  END;

  -- ==================================================================== S ===
  BEGIN
    PERFORM pg_temp.servidor();
    SELECT count(*) INTO v_m FROM pedido_item_sustituciones s JOIN pedidos pd ON pd.id = s.pedido_id
     WHERE s.sucursal_id = v_p_suc AND pd.usuario_id = v_p;
    PERFORM pg_temp.como(v_p, v_p_suc);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.pedido_item_sustituciones');
    IF v_res <> v_m::text THEN
      v_fallas := v_fallas || format('S1 · el preventista ve %s sustituciones; esperado %s (las de sus pedidos)', v_res, v_m);
    END IF;
    PERFORM pg_temp.servidor();
    SELECT count(*) INTO v_m FROM pedido_item_sustituciones WHERE sucursal_id = 1;
    PERFORM pg_temp.como(v_a1, 1);
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.pedido_item_sustituciones');
    IF v_res <> v_m::text THEN
      v_fallas := v_fallas || format('S2 · el admin de la 1 ve %s sustituciones; esperado %s', v_res, v_m);
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || ('S · error inesperado: ' || SQLERRM);
  END;

  -- ==================================================================== G ===
  BEGIN
    -- G1 · la cuenta de un empleado de la 1
    PERFORM pg_temp.servidor();
    SELECT e.cliente_id INTO v_cli FROM empleados e JOIN clientes c ON c.id = e.cliente_id
     WHERE e.activo AND c.sucursal_id = 1 ORDER BY e.id LIMIT 1;
    IF v_cli IS NULL THEN
      v_notas := v_notas || text 'G1 · no hay cuentas de empleados en la 1';
    ELSE
      PERFORM pg_temp.como(v_a2, 2);
      v_txt := pg_temp.rest_val(format('SELECT public.cliente_admite_adelanto_sueldo(%s)::text', v_cli));
      PERFORM pg_temp.como(v_a1, 1);
      v_txt := v_txt || ' ' || pg_temp.rest_val(format('SELECT public.cliente_admite_adelanto_sueldo(%s)::text', v_cli));
      IF v_txt <> 'false true' THEN
        v_fallas := v_fallas || format('G1 · admin de la 2 y de la 1 por el cliente %s: %s', v_cli, v_txt);
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || ('G1 · error inesperado: ' || SQLERRM);
  END;

  BEGIN
    -- G2 · un empleado «de las dos» con un usuario sólo de la 1
    PERFORM pg_temp.servidor();
    UPDATE empleados SET de_las_dos = true WHERE id = v_emp_o;
    PERFORM pg_temp.como(v_a2, 2);
    v_res := pg_temp.rest_val('SELECT public.empleados_para_elegir()::text');
    v_txt := COALESCE((SELECT x->>'usuario_id' FROM jsonb_array_elements(v_res::jsonb) x WHERE (x->>'id')::bigint = v_emp_o), 'null');
    PERFORM pg_temp.como(v_e, v_e_suc);
    v_res := pg_temp.rest_val('SELECT public.empleados_para_elegir()::text');
    v_txt := v_txt || ' ' || COALESCE((SELECT x->>'usuario_id' FROM jsonb_array_elements(v_res::jsonb) x WHERE (x->>'id')::bigint = v_emp_o), 'null');
    PERFORM pg_temp.como(v_a12, 2);
    v_res := pg_temp.rest_val('SELECT public.empleados_para_elegir()::text');
    v_txt := v_txt || ' ' || COALESCE((SELECT x->>'usuario_id' FROM jsonb_array_elements(v_res::jsonb) x WHERE (x->>'id')::bigint = v_emp_o), 'null');
    PERFORM pg_temp.servidor();
    IF v_txt <> format('null null %s', (SELECT usuario_id FROM empleados WHERE id = v_emp_o)) THEN
      v_fallas := v_fallas || format('G2 · usuario_id para el admin de la 2, el encargado de la %s y el de las dos: %s', v_e_suc, v_txt);
    END IF;
    -- El de la sucursal activa sigue llegando: el admin de la 1 ve el del transportista.
    PERFORM pg_temp.como(v_a1, 1);
    v_res := pg_temp.rest_val('SELECT public.empleados_para_elegir()::text');
    IF COALESCE((SELECT x->>'usuario_id' FROM jsonb_array_elements(v_res::jsonb) x WHERE (x->>'id')::bigint = v_emp_t), '') <> v_t::text THEN
      v_fallas := v_fallas || format('G2 · el admin de la 1 no recibe el usuario del transportista: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('G2 · error inesperado: ' || SQLERRM);
  END;

  BEGIN
    -- G3 · dos líneas de una rendición del transportista: una a otro empleado, otra a él
    PERFORM pg_temp.servidor();
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, creado_por,
                                      rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
    VALUES (v_emp_o, DATE '2026-01-15', 'faltante', -100, v_a1, v_t, DATE '2026-01-15', v_t_suc)
    RETURNING id INTO v_mov;
    INSERT INTO rendicion_faltantes (rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id, causal,
                                     monto, empleado_id, movimiento_id, creado_por, created_at)
    VALUES (v_t, DATE '2026-01-15', v_t_suc, 'empleado', 100, v_emp_o, v_mov, v_a1, now());
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, creado_por,
                                      rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id)
    VALUES (v_emp_t, DATE '2026-01-15', 'faltante', -50, v_a1, v_t, DATE '2026-01-15', v_t_suc)
    RETURNING id INTO v_mov;
    INSERT INTO rendicion_faltantes (rendicion_transportista_id, rendicion_fecha, rendicion_sucursal_id, causal,
                                     monto, empleado_id, movimiento_id, creado_por, created_at)
    VALUES (v_t, DATE '2026-01-15', v_t_suc, 'empleado', 50, v_emp_t, v_mov, v_a1, now());

    PERFORM pg_temp.como(v_t, v_t_suc);
    v_res := pg_temp.rest_val('SELECT public.obtener_faltantes_rendiciones(DATE ''2026-01-15'', DATE ''2026-01-15'', NULL)::text');
    v_txt := (SELECT string_agg(COALESCE(x->'empleado'->>'id', 'null'), ' ' ORDER BY (x->>'monto')::numeric DESC)
                FROM jsonb_array_elements(v_res::jsonb) x);
    IF v_txt IS DISTINCT FROM format('null %s', v_emp_t) THEN
      v_fallas := v_fallas || format('G3 · el transportista ve los empleados %s (otro, él); esperado null %s', v_txt, v_emp_t);
    END IF;
    PERFORM pg_temp.como(v_a1, v_t_suc);
    v_res := pg_temp.rest_val('SELECT public.obtener_faltantes_rendiciones(DATE ''2026-01-15'', DATE ''2026-01-15'', NULL)::text');
    v_txt := (SELECT string_agg(COALESCE(x->'empleado'->>'id', 'null'), ' ' ORDER BY (x->>'monto')::numeric DESC)
                FROM jsonb_array_elements(v_res::jsonb) x);
    IF v_txt IS DISTINCT FROM format('%s %s', v_emp_o, v_emp_t) THEN
      v_fallas := v_fallas || format('G3 · el admin ve los empleados %s; esperado %s %s', v_txt, v_emp_o, v_emp_t);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('G3 · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  GET STACKED DIAGNOSTICS v_txt = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_txt;
 END;
END
$ensayo$;
