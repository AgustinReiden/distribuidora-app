-- Ensayo de la tarjeta B6b de la ola 2 del plan #1603: usuarios, sucursales y retención de la
-- auditoría. Migración: NNN_usuarios_sucursal_default_y_retencion.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la migración
-- falla en C1, B5, B4.1 (y B4.2 en cascada), B4.4, B3 (B3.1 y, en cascada, B3.1b a B3.3), V1,
-- V1b, V1c y P1; C2, B4.3, G y V2 pasan en los dos (regresiones). Medido el 16/11 en o2-b6b: sin
-- la migración, 16 fallas; con la primera versión de la migración, sólo B4.4.
--
--   C1 · #1525: usuario_sucursales no tiene columna rol, y ninguna función la nombra.
--   C2 · El alta por app_metadata sigue armando perfil y sucursal (default) sin la columna.
--   B5 · 1596-b5 (D39): con la sucursal 1 inactiva, el alta del panel (sin app_metadata) va a la
--        primera activa, no a la 1; lo que diga el metadata del usuario no cambia nada; con
--        ninguna activa, el alta se rechaza.
--   B4 · 1596-b4: el admin de las dos asigna sin default la sucursal que ya era la default del
--        usuario → la conserva (B4.1); asignar otra sin default no mueve la marca (B4.2); con
--        default la mueve y queda una sola (B4.3); a quien no tenía ninguna (dato sucio), asignarle
--        una inactiva sin default le pone la marca en su primera activa, no en la inactiva (B4.4).
--   B3 · 1561-b3: desasignar la default pasa la marca a otra, la activa antes que la inactiva
--        (B3.1); desasignar una que no es la default no la toca (B3.2).
--   G  · #1291 sigue: el admin de una sola sucursal no asigna ni desasigna a un usuario que
--        también es de otra.
--   V1 · 1596-b10 (D38): una venta de 3 líneas no escribe filas de productos en audit_logs, y sí
--        las 3 de pedido_items; las 3 bajas están en stock_historico como 'pedido_creado'. Ni la
--        baja del bot (V1b) ni la de una edición (V1c) se auditan en productos.
--   V2 · Se siguen auditando en productos: una baja de stock con otro origen ('merma'), una
--        subida con un origen de venta, una baja de venta que además cambia el precio, y el
--        cambio de precio solo.
--   P1 · 1561-b10 (D38): purgar_retencion() existe, sólo la ejecuta service_role, borra los
--        avisos de más de 90 días y la auditoría de más de 24 meses, deja lo más nuevo, respeta
--        el lote y dice si quedan; como authenticated da 42501.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-usuarios-retencion-ola2-1603.sql

DO $ensayo$
DECLARE
  v_adm    uuid;   -- admin de la 1 y la 2
  v_a1     uuid;   -- admin sólo de la 1
  v_u      uuid;
  v_id     uuid;
  v_cli    bigint;
  v_prods  bigint[] := '{}';
  v_p      bigint;
  v_items  jsonb := '[]';
  v_res    jsonb;
  v_t      text;
  v_n      bigint;
  v_ok     boolean;
  v_app    jsonb := '{"provider":"email","providers":["email"]}';
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_tag text, p_app jsonb, p_user jsonb) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'b6b-' || p_tag || '-' || v || '@ensayo.invalid', p_app, p_user, now(), now());
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
  END $f$;
  -- Corre p_sql como p_uid (authenticated, sucursal p_suc) y devuelve 'PASA <valor>' o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.intenta(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text; x text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql INTO x;
      r := 'PASA ' || COALESCE(x, '');
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- Las sucursales de un usuario: '1*,2' (con * la default).
  CREATE FUNCTION pg_temp.sucs(p uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(sucursal_id || CASE WHEN es_default THEN '*' ELSE '' END, ',' ORDER BY sucursal_id), '(ninguna)')
      FROM public.usuario_sucursales WHERE usuario_id = p
  $f$;
  CREATE FUNCTION pg_temp.asignar(p_adm uuid, p_u uuid, p_suc bigint, p_def boolean) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_adm, 1, format('SELECT public.asignar_usuario_sucursal(%L, %s, %s)::text', p_u, p_suc, p_def::text))
  $f$;
  CREATE FUNCTION pg_temp.desasignar(p_adm uuid, p_u uuid, p_suc bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT pg_temp.intenta(p_adm, 1, format('SELECT public.desasignar_usuario_sucursal(%L, %s)::text', p_u, p_suc))
  $f$;
  -- Filas de audit_logs de un producto (las del ensayo: todo pasa en esta transacción).
  CREATE FUNCTION pg_temp.audit_prod(p bigint) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(*) FROM public.audit_logs WHERE tabla = 'productos' AND registro_id = p::text AND accion = 'UPDATE'
  $f$;

  IF (SELECT count(*) FROM sucursales WHERE id IN (1, 2)) <> 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · hacen falta las sucursales 1 y 2';
  END IF;
  UPDATE sucursales SET activa = true WHERE id IN (1, 2);

  -- ---------------------------------------------------------------- datos ---
  v_adm := pg_temp.u('adm', v_app || '{"rol":"admin","sucursal_id":1}', '{}');
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_adm, 2, false);
  v_a1 := pg_temp.u('a1', v_app || '{"rol":"admin","sucursal_id":1}', '{}');

  -- ------------------------------------------------------------------- C1 ---
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.usuario_sucursales'::regclass
               AND attname = 'rol' AND NOT attisdropped) THEN
    v_fallas := v_fallas || text 'C1 · usuario_sucursales todavía tiene la columna rol';
  END IF;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_t
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND (p.prosrc ~* 'usuario_sucursales\.rol\M'
          OR p.prosrc ~* 'usuario_sucursales\s*\([^)]*\mrol\M'
          OR p.prosrc ~* 'UPDATE\s+(public\.)?usuario_sucursales\s+SET[^;]*\mrol\M'
          OR p.prosrc ~ '\mus\d?\.rol\M');
  IF v_t IS NOT NULL THEN
    v_fallas := v_fallas || format('C1 · todavía nombran usuario_sucursales.rol: %s', v_t);
  END IF;

  -- ------------------------------------------------------------------- C2 ---
  v_u := pg_temp.u('c2', v_app || '{"rol":"encargado","sucursal_id":"2"}', '{"nombre":"B6b C2"}');
  v_t := (SELECT rol FROM perfiles WHERE id = v_u) || ' ' || pg_temp.sucs(v_u);
  IF v_t IS DISTINCT FROM 'encargado 2*' THEN
    v_fallas := v_fallas || format('C2 · el alta con app_metadata de la 2 dio %s', v_t);
  END IF;

  -- ------------------------------------------------------------------- B5 ---
  BEGIN
    UPDATE sucursales SET activa = false WHERE id = 1;
    -- El alta del panel: sin nada en app_metadata.
    v_u := pg_temp.u('b5a', v_app, '{"email_verified": true}');
    v_t := (SELECT rol FROM perfiles WHERE id = v_u) || ' ' || pg_temp.sucs(v_u);
    IF v_t IS DISTINCT FROM 'preventista 2*' THEN
      v_fallas := v_fallas || format('B5.1 · con la 1 inactiva, el alta del panel quedó en %s (esperaba preventista 2*)', v_t);
    END IF;
    -- Lo que diga el que se registra no cambia nada (#1243).
    v_u := pg_temp.u('b5b', v_app, '{"rol":"admin","sucursal_id":"1","nombre":"B6b B5"}');
    v_t := (SELECT rol FROM perfiles WHERE id = v_u) || ' ' || pg_temp.sucs(v_u);
    IF v_t IS DISTINCT FROM 'preventista 2*' THEN
      v_fallas := v_fallas || format('B5.2 · un signup con data {admin, 1} quedó en %s (esperaba preventista 2*)', v_t);
    END IF;
    -- app_metadata manda, aunque nombre la inactiva (como antes).
    v_u := pg_temp.u('b5c', v_app || '{"rol":"deposito","sucursal_id":1}', '{}');
    v_t := (SELECT rol FROM perfiles WHERE id = v_u) || ' ' || pg_temp.sucs(v_u);
    IF v_t IS DISTINCT FROM 'deposito 1*' THEN
      v_fallas := v_fallas || format('B5.3 · el alta con app_metadata de la 1 dio %s', v_t);
    END IF;
    -- Sin ninguna activa, no hay alta.
    UPDATE sucursales SET activa = false WHERE id = 2;
    v_ok := false;
    BEGIN
      PERFORM pg_temp.u('b5d', v_app, '{}');
    EXCEPTION WHEN raise_exception THEN
      v_ok := SQLERRM LIKE '%ninguna sucursal activa%';
      v_notas := v_notas || ('B5.4 · ' || SQLERRM);
    END;
    IF NOT v_ok THEN
      v_fallas := v_fallas || text 'B5.4 · sin ninguna sucursal activa, el alta del panel no se rechazó con su motivo';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B5 · error: %s %s', SQLSTATE, SQLERRM);
  END;

  -- ------------------------------------------------------------------- B4 ---
  v_u := pg_temp.u('b4', v_app || '{"rol":"preventista","sucursal_id":1}', '{}');
  v_t := pg_temp.asignar(v_adm, v_u, 1, false);
  IF v_t IS DISTINCT FROM 'PASA {"success": true}' OR pg_temp.sucs(v_u) IS DISTINCT FROM '1*' THEN
    v_fallas := v_fallas || format('B4.1 · asignar sin default la que ya era la default: %s → %s (esperaba 1*)', v_t, pg_temp.sucs(v_u));
  END IF;
  v_t := pg_temp.asignar(v_adm, v_u, 2, false);
  IF v_t IS DISTINCT FROM 'PASA {"success": true}' OR pg_temp.sucs(v_u) IS DISTINCT FROM '1*,2' THEN
    v_fallas := v_fallas || format('B4.2 · asignar otra sin default: %s → %s (esperaba 1*,2)', v_t, pg_temp.sucs(v_u));
  END IF;
  v_t := pg_temp.asignar(v_adm, v_u, 2, true);
  IF v_t IS DISTINCT FROM 'PASA {"success": true}' OR pg_temp.sucs(v_u) IS DISTINCT FROM '1,2*' THEN
    v_fallas := v_fallas || format('B4.3 · asignar con default: %s → %s (esperaba 1,2*)', v_t, pg_temp.sucs(v_u));
  END IF;

  -- B4.4 · Sin ninguna default (dato sucio) y asignándole una inactiva sin default, la marca
  -- va a la primera activa de las suyas, no a la inactiva (lente B6b, hallazgo 2).
  BEGIN
    v_id := pg_temp.u('b44', v_app || '{"rol":"preventista","sucursal_id":1}', '{}');
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_id, 2, false);
    UPDATE usuario_sucursales SET es_default = false WHERE usuario_id = v_id;
    INSERT INTO sucursales (nombre, activa) VALUES ('B6b inactiva', false) RETURNING id INTO v_n;
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_adm, v_n, false);
    v_t := pg_temp.asignar(v_adm, v_id, v_n, false);
    IF v_t IS DISTINCT FROM 'PASA {"success": true}' OR pg_temp.sucs(v_id) IS DISTINCT FROM format('1*,2,%s', v_n) THEN
      v_fallas := v_fallas || format('B4.4 · asignar una inactiva sin default a quien no tenía ninguna: %s → %s (esperaba 1*,2,%s)',
                                     v_t, pg_temp.sucs(v_id), v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B4.4 · error: %s %s', SQLSTATE, SQLERRM);
  END;

  -- -------------------------------------------------------------------- G ---
  v_t := pg_temp.asignar(v_a1, v_u, 1, true);
  IF v_t NOT LIKE 'PASA {"error": "Ese usuario no es de tus sucursales%' OR pg_temp.sucs(v_u) IS DISTINCT FROM '1,2*' THEN
    v_fallas := v_fallas || format('G · el admin sólo de la 1 asignó a un usuario de las dos: %s → %s', v_t, pg_temp.sucs(v_u));
  END IF;
  v_t := pg_temp.desasignar(v_a1, v_u, 1);
  IF v_t NOT LIKE 'PASA {"error": "Ese usuario no es de tus sucursales%' OR pg_temp.sucs(v_u) IS DISTINCT FROM '1,2*' THEN
    v_fallas := v_fallas || format('G · el admin sólo de la 1 desasignó a un usuario de las dos: %s → %s', v_t, pg_temp.sucs(v_u));
  END IF;

  -- ------------------------------------------------------------------- B3 ---
  -- B3.1 · Sale de la 2, su default: la marca pasa a la 1.
  v_t := pg_temp.desasignar(v_adm, v_u, 2);
  IF v_t IS DISTINCT FROM 'PASA {"success": true}' OR pg_temp.sucs(v_u) IS DISTINCT FROM '1*' THEN
    v_fallas := v_fallas || format('B3.1 · desasignar la default: %s → %s (esperaba 1*)', v_t, pg_temp.sucs(v_u));
  END IF;
  -- B3.1b · Con una inactiva y una activa, la marca va a la activa aunque tenga id mayor.
  BEGIN
    INSERT INTO sucursales (nombre, activa) VALUES ('B6b tercera', true) RETURNING id INTO v_n;
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_adm, v_n, false);
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_u, 2, false), (v_u, v_n, true);
    UPDATE usuario_sucursales SET es_default = false WHERE usuario_id = v_u AND sucursal_id = 1;
    UPDATE sucursales SET activa = false WHERE id = 1;
    v_t := pg_temp.desasignar(v_adm, v_u, v_n);
    IF v_t IS DISTINCT FROM 'PASA {"success": true}' OR pg_temp.sucs(v_u) IS DISTINCT FROM '1,2*' THEN
      v_fallas := v_fallas || format('B3.1b · desasignar la default con la 1 inactiva: %s → %s (esperaba 1,2*)', v_t, pg_temp.sucs(v_u));
    END IF;
    -- B3.2 · Sacarlo de una que no es la default no mueve la marca.
    v_t := pg_temp.desasignar(v_adm, v_u, 1);
    IF v_t IS DISTINCT FROM 'PASA {"success": true}' OR pg_temp.sucs(v_u) IS DISTINCT FROM '2*' THEN
      v_fallas := v_fallas || format('B3.2 · desasignar una que no es la default: %s → %s (esperaba 2*)', v_t, pg_temp.sucs(v_u));
    END IF;
    -- Y la única no se saca (#1291).
    v_t := pg_temp.desasignar(v_adm, v_u, 2);
    IF v_t NOT LIKE 'PASA {"error": "Es la única sucursal del usuario%' OR pg_temp.sucs(v_u) IS DISTINCT FROM '2*' THEN
      v_fallas := v_fallas || format('B3.3 · desasignar la única: %s → %s', v_t, pg_temp.sucs(v_u));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B3 · error: %s %s', SQLSTATE, SQLERRM);
  END;

  -- ------------------------------------------------------------------- V1 ---
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('B6b cliente', 'B6b cliente', 'calle b6b', 1) RETURNING id INTO v_cli;
  FOR i IN 1..3 LOOP
    INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('B6b ' || i || ' ' || gen_random_uuid(), 100, 50, 1) RETURNING id INTO v_p;
    v_prods := v_prods || v_p;
    v_items := v_items || jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 2, 'precio_unitario', 100));
  END LOOP;
  v_t := pg_temp.intenta(v_adm, 1, format('SELECT public.crear_pedido_completo(%s, 600, %L, %L::jsonb, %L)::text',
                                         v_cli, v_adm, v_items, 'ensayo b6b'));
  IF v_t NOT LIKE 'PASA {%"success": true%' THEN
    v_fallas := v_fallas || format('V1 · la venta no entró: %s', v_t);
  ELSE
    SELECT count(*) INTO v_n FROM audit_logs WHERE tabla = 'productos' AND registro_id = ANY (SELECT unnest(v_prods)::text) AND accion = 'UPDATE';
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format('V1 · una venta de 3 líneas escribió %s filas de productos en audit_logs (esperaba 0)', v_n);
    END IF;
    SELECT count(*) INTO v_n FROM audit_logs a
     WHERE a.tabla = 'pedido_items' AND a.accion = 'INSERT'
       AND (a.new_data->>'pedido_id')::bigint = ((substr(v_t, 6))::jsonb->>'pedido_id')::bigint;
    IF v_n <> 3 THEN
      v_fallas := v_fallas || format('V1 · las líneas de la venta: %s filas de pedido_items en audit_logs (esperaba 3)', v_n);
    END IF;
    SELECT count(*) INTO v_n FROM stock_historico
     WHERE producto_id = ANY (v_prods) AND origen = 'pedido_creado' AND stock_anterior = 50 AND stock_nuevo = 48;
    IF v_n <> 3 THEN
      v_fallas := v_fallas || format('V1 · stock_historico tiene %s de las 3 bajas de la venta', v_n);
    END IF;
  END IF;

  -- ------------------------------------------------------------------- V2 ---
  -- Cuenta lo que agrega cada UPDATE (la venta de V1 puede haber dejado filas antes).
  BEGIN
    -- Una merma (otro origen): se audita.
    v_n := pg_temp.audit_prod(v_prods[1]);
    PERFORM set_config('app.stock_origen', 'merma', true);
    UPDATE productos SET stock = stock - 1 WHERE id = v_prods[1];
    IF pg_temp.audit_prod(v_prods[1]) - v_n <> 1 THEN
      v_fallas := v_fallas || format('V2.1 · una baja por merma agregó %s filas a audit_logs (esperaba 1)', pg_temp.audit_prod(v_prods[1]) - v_n);
    END IF;
    -- Una subida con un origen de venta (la edición que devuelve): se audita.
    v_n := pg_temp.audit_prod(v_prods[2]);
    PERFORM set_config('app.stock_origen', 'pedido_editado', true);
    UPDATE productos SET stock = stock + 1 WHERE id = v_prods[2];
    IF pg_temp.audit_prod(v_prods[2]) - v_n <> 1 THEN
      v_fallas := v_fallas || format('V2.2 · una subida por edición agregó %s filas (esperaba 1)', pg_temp.audit_prod(v_prods[2]) - v_n);
    END IF;
    -- Una baja de venta que además cambia el precio: se audita.
    v_n := pg_temp.audit_prod(v_prods[3]);
    PERFORM set_config('app.stock_origen', 'pedido_creado', true);
    UPDATE productos SET stock = stock - 1, precio = 101 WHERE id = v_prods[3];
    IF pg_temp.audit_prod(v_prods[3]) - v_n <> 1 THEN
      v_fallas := v_fallas || format('V2.3 · una baja de venta con cambio de precio agregó %s filas (esperaba 1)', pg_temp.audit_prod(v_prods[3]) - v_n);
    END IF;
    -- El precio solo, sin origen: se audita.
    v_n := pg_temp.audit_prod(v_prods[3]);
    PERFORM set_config('app.stock_origen', '', true);
    UPDATE productos SET precio = 102 WHERE id = v_prods[3];
    IF pg_temp.audit_prod(v_prods[3]) - v_n <> 1 THEN
      v_fallas := v_fallas || format('V2.4 · el cambio de precio agregó %s filas (esperaba 1)', pg_temp.audit_prod(v_prods[3]) - v_n);
    END IF;
    -- V1b · La baja de venta del bot, sola: no se audita.
    v_n := pg_temp.audit_prod(v_prods[3]);
    PERFORM set_config('app.stock_origen', 'pedido_creado_bot', true);
    UPDATE productos SET stock = stock - 1 WHERE id = v_prods[3];
    IF pg_temp.audit_prod(v_prods[3]) - v_n <> 0 THEN
      v_fallas := v_fallas || format('V1b · la baja del bot agregó %s filas a audit_logs (esperaba 0)', pg_temp.audit_prod(v_prods[3]) - v_n);
    END IF;
    -- V1c · Ni la baja de una edición de venta.
    v_n := pg_temp.audit_prod(v_prods[3]);
    PERFORM set_config('app.stock_origen', 'pedido_editado', true);
    UPDATE productos SET stock = stock - 1 WHERE id = v_prods[3];
    IF pg_temp.audit_prod(v_prods[3]) - v_n <> 0 THEN
      v_fallas := v_fallas || format('V1c · la baja de una edición agregó %s filas a audit_logs (esperaba 0)', pg_temp.audit_prod(v_prods[3]) - v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V2 · error: %s %s', SQLSTATE, SQLERRM);
  END;
  PERFORM set_config('app.stock_origen', '', true);

  -- ------------------------------------------------------------------- P1 ---
  IF to_regprocedure('public.purgar_retencion(integer)') IS NULL THEN
    v_fallas := v_fallas || text 'P1 · no existe purgar_retencion(integer)';
  ELSE
    IF has_function_privilege('anon', 'public.purgar_retencion(integer)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.purgar_retencion(integer)', 'EXECUTE')
       OR NOT has_function_privilege('service_role', 'public.purgar_retencion(integer)', 'EXECUTE') THEN
      v_fallas := v_fallas || text 'P1.1 · purgar_retencion: EXECUTE distinto de sólo service_role';
    END IF;
    v_t := pg_temp.intenta(v_adm, 1, 'SELECT public.purgar_retencion(10)::text');
    IF v_t NOT LIKE '42501 %' THEN
      v_fallas := v_fallas || format('P1.1 · el admin llamó a purgar_retencion: %s', v_t);
    END IF;
    BEGIN
      -- Todo lo viejo que hubiera queda fuera: el ensayo mira sólo sus filas.
      DELETE FROM notificaciones WHERE created_at < now() - interval '90 days';
      DELETE FROM audit_logs WHERE created_at < now() - interval '24 months';
      INSERT INTO notificaciones (usuario_id, sucursal_id, tipo, titulo, created_at) VALUES
        (v_adm, 1, 'b6b', 'b6b viejo 1', now() - interval '91 days'),
        (v_adm, 1, 'b6b', 'b6b viejo 2', now() - interval '200 days'),
        (v_adm, 1, 'b6b', 'b6b nuevo',   now() - interval '89 days');
      INSERT INTO audit_logs (tabla, registro_id, accion, created_at) VALUES
        ('b6b', 'viejo', 'INSERT', now() - interval '25 months'),
        ('b6b', 'nuevo', 'INSERT', now() - interval '23 months');
      -- De a uno: borra el más viejo de cada tabla y dice que quedan.
      SET LOCAL ROLE service_role;
      v_res := public.purgar_retencion(1);
      RESET ROLE;
      IF (v_res->>'notificaciones')::int <> 1 OR (v_res->>'audit_logs')::int <> 1 OR NOT (v_res->>'quedan')::boolean
         OR NOT EXISTS (SELECT 1 FROM notificaciones WHERE titulo = 'b6b viejo 1')
         OR EXISTS (SELECT 1 FROM notificaciones WHERE titulo = 'b6b viejo 2') THEN
        v_fallas := v_fallas || format('P1.2 · el lote de 1: %s', v_res);
      END IF;
      SET LOCAL ROLE service_role;
      v_res := public.purgar_retencion(1000);
      RESET ROLE;
      IF (v_res->>'notificaciones')::int <> 1 OR (v_res->>'audit_logs')::int <> 0 OR (v_res->>'quedan')::boolean THEN
        v_fallas := v_fallas || format('P1.3 · el segundo lote: %s', v_res);
      END IF;
      SELECT string_agg(titulo, ',' ORDER BY titulo) INTO v_t FROM notificaciones WHERE tipo = 'b6b';
      IF v_t IS DISTINCT FROM 'b6b nuevo' THEN
        v_fallas := v_fallas || format('P1.4 · quedaron los avisos %s (esperaba sólo el de 89 días)', v_t);
      END IF;
      SELECT string_agg(registro_id, ',' ORDER BY registro_id) INTO v_t FROM audit_logs WHERE tabla = 'b6b';
      IF v_t IS DISTINCT FROM 'nuevo' THEN
        v_fallas := v_fallas || format('P1.5 · quedó la auditoría %s (esperaba sólo la de 23 meses)', v_t);
      END IF;
      v_notas := v_notas || ('P1 · ' || v_res::text);
      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('P1 · error: %s %s', SQLSTATE, SQLERRM);
    END;
  END IF;

  RAISE EXCEPTION USING ERRCODE = 'P0098';
 EXCEPTION WHEN SQLSTATE 'P0098' THEN NULL;
 END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK B6b (#1525, 1596-b4/b5/b10, 1561-b3/b10) · %', array_to_string(v_notas, ' | ');
  ELSE
    RAISE EXCEPTION E'ENSAYO FALLÓ B6b (% fallas, todo revertido):\n- %\nnotas: %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | ');
  END IF;
END
$ensayo$;
