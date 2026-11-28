-- Ensayo de la migración NNN_ola3_t7_comisiones_metas (ola 3, tarjeta T7 de #1677: comisiones y
-- metas; COM-1, COM-2, Com-B2, Com-B6, Com-B7, Com-B8, Fr-B8, SEG-03/VTA-09, REP-7 y D11 de #1690,
-- #1551, #1554 y #1522).
--
-- No deja rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una excepción.
-- Antes de aplicar la migración tiene que FALLAR en 1 a 8; después, dar 'ENSAYO OK'. R1 y R2
-- son regresiones (pasan también antes). Corre en una base local con la semilla mínima (un admin
-- activo de las sucursales 1 y 2) o en una copia de prod: arma sus propias personas, clientes,
-- productos y pedidos. Usa el día argentino (_tablero_hoy()). Los pedidos entregados y los pagos se
-- arman como postgres sobre las tablas (como test-ola3-personal-liquidaciones.sql); las reglas, los
-- %, el origen del precio y las metas, por las RPC reales, como el front.
--
-- 1 · COM-2 (D3) el ejemplo de Juan: preventista al 3 %, vende y entrega $ 300.000 hace 10 días;
--     hoy pasa a encargado (que comisiona 0 %) y carga otro pedido de $ 100.000. La comisión de lo
--     pendiente es $ 9.000 (el primero con su rol al vender) y $ 0 el segundo, en _comision_lineas y
--     en calcular_comisiones. El cambio queda anotado en perfil_rol_cambios.
--     1b · 'preventista_taco' (rol de mayo) cuenta como preventista; un rol viejo de admin, no.
--     1c · el cambio de cliente: Lucas, preventista, carga hace 10 días un pedido de $ 1.000; hoy pasa
--     a encargado y el admin le cambia el cliente. El pedido nuevo (created_at de hoy) comisiona al 3 %
--     ($ 30), con el rol de la venta original (pedidos.vendido_at), y vendido_at no se cambia después.
-- 2 · COM-1 (D2) el admin que se carga su %: A2 se pone el 50 % → 42501 y no queda regla. A le
--     carga a A2 el 5 % → entra; A2 no la edita ni la da de baja. La regla de Pedro la carga A al 5 %
--     y la edita A2 al 4 %: usuario_id pasa a A2 (Com-B2) y la auditoría anota el alta y la edición.
--     En la pantalla de liquidar (4) dice A2 y hoy: quien dejó el % y cuándo, aunque la regla se haya
--     creado hace 5 días.
--     2b · la regla para todas las sucursales que carga el server, sin sesión, entra y queda auditada.
-- 3 · Fr-B8 el doble toque: el mismo alta dos veces da el mismo id y una sola regla; el mismo día
--     con otro % se rechaza (23505, con su motivo).
-- 4 · La pantalla de liquidar: _liquidacion_json de Juan trae comisiones.porcentajes con el 3 % por
--     defecto de preventista y quién lo cargó; el de Pedro, el 4 % de la regla y A2.
-- 5 · D11 el % de la simulación del gerencial: nace en 2; el admin lo pone en 3,5 y el gerencial lo
--     devuelve en kpis.comision_pct_default; el encargado no lo cambia (42501), NaN y 101 se rechazan;
--     politica_comercial_reservada() lo da al admin, nada al preventista, y por REST no se lee.
-- 6 · SEG-03 el origen del precio lo pone el server: lista 100, cliente con 10 % y 20 % en su
--     categoría, escala de 10 u. a $ 70. El teléfono manda «manual», «lista», «lista» y «mayorista»
--     con una escala inventada; quedan desc_cliente (90), desc_categoria (80), mayorista con la
--     escala de verdad (12 u. a 70), manual (55) y lista (100).
-- 7 · Com-B7 y Com-B8 las metas de Ana: boleta de $ 1.000 con $ 400 de adelanto (a una ficha de
--     empleado), boleta de $ 0 a otro cliente, boleta de $ 500 pagada entera con adelanto y boleta de
--     $ 300. Facturación 900 (antes 1.800), igual a la base de su comisión; cobertura 2 (antes 4).
-- 8 · REP-7 calcular_comisiones sin sucursales deja afuera una sucursal inactiva del admin.
-- 9 · Com-B6 un preventista desactivado no ve sus metas (avance 42501, la policy 0 filas), un
--     chofer tampoco; el preventista activo sí (regresión).
-- R1 · Un preventista no cobra una boleta con adelanto de sueldo (registrar_pagos_pedido sólo acepta
--     formas dinerarias).
-- R2 · auditoria_integridad: ningún critical/high nuevo.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-ola3-t7-comisiones-metas.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_s2     bigint;
  v_ua     uuid;
  v_hoy    date := public._tablero_hoy();
  v_mes    date := date_trunc('month', public._tablero_hoy())::date;
  v_a2     uuid;
  v_juan   uuid;
  v_lucas  uuid;
  v_q      bigint;
  v_qn     bigint;
  v_pedro  uuid;
  v_ana    uuid;
  v_ana2   uuid;
  v_pr2    uuid;
  v_enc    uuid;
  v_t      uuid;
  v_c1     bigint;
  v_c2     bigint;
  v_c3     bigint;
  v_c6     bigint;
  v_ce1    bigint;
  v_ce2    bigint;
  v_cs2    bigint;
  v_prod   bigint;
  v_ps2    bigint;
  v_x      bigint;
  v_y      bigint;
  v_z      bigint;
  v_w      bigint;
  v_v      bigint;
  v_grupo  bigint;
  v_esc    bigint;
  e_juan   bigint;
  e_pedro  bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_pp     bigint;
  v_pa1    bigint;
  v_pa2    bigint;
  v_pa3    bigint;
  v_pa4    bigint;
  v_po     bigint;
  v_pv     bigint;
  v_m_fac  bigint;
  v_m_cob  bigint;
  v_m_a2   bigint;
  v_r1     bigint;
  v_r2     bigint;
  v_j      jsonb;
  v_n      bigint;
  v_m      numeric;
  v_t1     text;
  v_ch_ini int;
  v_ch_fin int;
  v_fallas text[] := '{}';
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
  SELECT s.id INTO v_s2 FROM sucursales s
   WHERE s.activa AND s.id <> v_s1
     AND EXISTS (SELECT 1 FROM usuario_sucursales u WHERE u.usuario_id = v_ua AND u.sucursal_id = s.id)
   ORDER BY s.id LIMIT 1;
  IF v_ua IS NULL OR v_s2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hacen falta un admin activo de todas las sucursales activas y dos sucursales activas';
  END IF;
  UPDATE empleados SET usuario_id = NULL WHERE usuario_id = v_ua;
  PERFORM set_config('t7.ua', v_ua::text, true);
  PERFORM set_config('t7.s1', v_s1::text, true);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.claims(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  CREATE FUNCTION pg_temp.como(p_sql text, p_uid uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM pg_temp.claims(COALESCE(p_uid, current_setting('t7.ua')::uuid), current_setting('t7.s1')::bigint);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  END $f$;

  CREATE FUNCTION pg_temp.falla(p_que text, p_sql text, p_espera text, p_uid uuid DEFAULT NULL) RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_sql, p_uid);
    EXCEPTION WHEN SQLSTATE 'P0098' THEN RAISE;
      WHEN OTHERS THEN
        RESET ROLE;
        IF position(p_espera IN SQLERRM) > 0 OR p_espera = SQLSTATE THEN
          RETURN '{}';
        END IF;
        RETURN ARRAY[format('%s: falló con otro mensaje: %s [%s] (esperado: %s)', p_que, SQLERRM, SQLSTATE, p_espera)];
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RESET ROLE;
    RETURN ARRAY[format('%s: anduvo y tenía que fallar', p_que)];
  END $f$;

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

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE
    v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't7-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'ZZ t7 ' || p_rol), now(), now());
    RETURN v;
  END $f$;

  -- Ficha de empleado que comisiona desde hace 40 días, por guardar_empleado.
  CREATE FUNCTION pg_temp.alta(p jsonb) RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ t7 ' || gen_random_uuid(), 'puesto', 'preventista', 'sucursal_id', current_setting('t7.s1')::bigint,
      'de_las_dos', false, 'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', NULL, 'cliente_id', NULL,
      'vehiculo_id', NULL, 'saldo_inicial', NULL,
      'arreglo', jsonb_build_object('vigente_desde', public._tablero_hoy() - 40,
                                    'sueldo', 0, 'frecuencia', 'mensual', 'comisiona', true)) || p))::bigint;
  $f$;

  -- Un pedido entregado de p_usr, del cliente p_cli, el día p_dia, por p_total (0: sin renglones).
  CREATE FUNCTION pg_temp.pedido(p_usr uuid, p_cli bigint, p_dia date, p_total numeric, p_suc bigint DEFAULT NULL,
                                 p_prod bigint DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v bigint;
    v_suc bigint := COALESCE(p_suc, current_setting('t7.s1')::bigint);
  BEGIN
    PERFORM pg_temp.claims(current_setting('t7.ua')::uuid, v_suc);
    INSERT INTO pedidos (cliente_id, sucursal_id, fecha, total, usuario_id, creado_por)
    VALUES (p_cli, v_suc, p_dia, 0, p_usr, p_usr) RETURNING id INTO v;
    IF p_total > 0 THEN
      INSERT INTO pedido_items (pedido_id, sucursal_id, producto_id, cantidad, precio_unitario, subtotal, costo_unitario_al_crear)
      VALUES (v, v_suc, COALESCE(p_prod, current_setting('t7.prod')::bigint), p_total / 100, 100, p_total, 60);
      UPDATE pedidos SET total = p_total WHERE id = v;
    END IF;
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true,
                       fecha_entrega = (p_dia + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
     WHERE id = v;
    RETURN v;
  END $f$;

  CREATE FUNCTION pg_temp.comision(p_ids bigint[]) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(round(sum(l.base * l.pct / 100), 2), 0) FROM public._comision_lineas(p_ids) l;
  $f$;

  CREATE FUNCTION pg_temp.regla(p_id bigint, p_prev uuid, p_pct numeric) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_comision_regla(p_id => %s, p_sucursal_id => %s, p_preventista_id => %L::uuid, p_origen_precio => NULL, p_porcentaje => %s)',
                  COALESCE(p_id::text, 'NULL'), current_setting('t7.s1'), p_prev, p_pct);
  $f$;

  CREATE FUNCTION pg_temp.audit() RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.claims(current_setting('t7.ua')::uuid, current_setting('t7.s1')::bigint);
    RETURN public.auditoria_integridad();
  END $f$;

  IF cardinality(pg_temp.falla('canario', 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'by zero')) <> 0
     OR pg_temp.como('SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_ua, v_s1)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  v_ch_ini := (pg_temp.audit()->>'critical_high_en_rojo')::int;

  -- ---------------------------------------------------------------- datos ---
  PERFORM pg_temp.claims(v_ua, v_s1);
  v_a2    := pg_temp.u('admin', v_s1);
  v_juan  := pg_temp.u('preventista', v_s1);
  v_lucas := pg_temp.u('preventista', v_s1);
  v_pedro := pg_temp.u('preventista', v_s1);
  v_ana   := pg_temp.u('preventista', v_s1);
  v_ana2  := pg_temp.u('preventista', v_s1);
  v_enc   := pg_temp.u('encargado', v_s1);
  v_t     := pg_temp.u('transportista', v_s1);
  v_pr2   := pg_temp.u('preventista', v_s2);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES
    ('ZZ t7 C1', 'ZZ t7 C1', 'Ensayo t7 1', v_s1) RETURNING id INTO v_c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES
    ('ZZ t7 C2', 'ZZ t7 C2', 'Ensayo t7 2', v_s1) RETURNING id INTO v_c2;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, descuento_porcentaje) VALUES
    ('ZZ t7 C3', 'ZZ t7 C3', 'Ensayo t7 3', v_s1, 10) RETURNING id INTO v_c3;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES
    ('ZZ t7 C6', 'ZZ t7 C6', 'Ensayo t7 6', v_s1) RETURNING id INTO v_c6;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES
    ('ZZ t7 CE1', 'ZZ t7 CE1', 'Ensayo t7 e1', v_s1) RETURNING id INTO v_ce1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES
    ('ZZ t7 CE2', 'ZZ t7 CE2', 'Ensayo t7 e2', v_s1) RETURNING id INTO v_ce2;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ t7 A', 100, 1000000, 60, v_s1) RETURNING id INTO v_prod;
  PERFORM set_config('t7.prod', v_prod::text, true);
  PERFORM pg_temp.claims(v_ua, v_s2);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES
    ('ZZ t7 CS2', 'ZZ t7 CS2', 'Ensayo t7 s2', v_s2) RETURNING id INTO v_cs2;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ t7 S2', 100, 1000000, 60, v_s2) RETURNING id INTO v_ps2;
  PERFORM pg_temp.claims(v_ua, v_s1);
  -- El % por defecto de la sucursal 1: 3 % preventistas, 0 % el resto, cargado por A.
  DELETE FROM comision_pct_vigencias WHERE sucursal_id = v_s1;
  INSERT INTO comision_pct_vigencias (sucursal_id, vigente_desde, pct_preventista, pct_otros, usuario_id, actualizado_en)
  -- La base del 2000 con una fecha de antes del corte de COMIS-06 (la que dejó la 421).
  VALUES (v_s1, DATE '2000-01-01', 3, 0, v_ua, TIMESTAMPTZ '2026-10-30 00:00:00+00');
  UPDATE comision_reglas SET activo = false, baja_desde = DATE '2000-01-02', vigente_hasta = DATE '2000-01-01'
   WHERE activo AND (sucursal_id = v_s1 OR sucursal_id IS NULL) AND vigente_desde <= DATE '2000-01-01';
  DELETE FROM comision_reglas WHERE activo AND (sucursal_id = v_s1 OR sucursal_id IS NULL);

  -- ======================================= 1 · COM-2 el rol al vender (Juan) ===
  BEGIN
    e_juan := pg_temp.alta(jsonb_build_object('usuario_id', v_juan));
    v_p1 := pg_temp.pedido(v_juan, v_c1, v_hoy - 10, 300000);
    UPDATE pedidos SET created_at = now() - interval '10 days' WHERE id = v_p1;
    -- El 15 (hoy, en el ensayo) pasa a encargado.
    UPDATE perfiles SET rol = 'encargado' WHERE id = v_juan;
    v_p2 := pg_temp.pedido(v_juan, v_c1, v_hoy, 100000);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.comision(ARRAY[v_p1]) = 9000,
                  format('1 Juan: lo vendido como preventista comisiona %s y no 9.000', pg_temp.comision(ARRAY[v_p1])));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.comision(ARRAY[v_p2]) = 0,
                  format('1 Juan: lo vendido ya como encargado comisiona %s y no 0', pg_temp.comision(ARRAY[v_p2])));
    v_j := pg_temp.como(format('SELECT public.calcular_comisiones(p_desde => %L::date, p_hasta => %L::date, p_sucursal_ids => ARRAY[%s]::bigint[])',
                               v_hoy - 20, v_hoy, v_s1))::jsonb;
    v_m := (SELECT (x->>'comision')::numeric FROM jsonb_array_elements(v_j->'preventistas') x WHERE x->>'id' = v_juan::text);
    v_fallas := v_fallas || pg_temp.chk(v_m = 9000, format('1 Juan: calcular_comisiones le da %s y no 9.000', v_m));
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM perfil_rol_cambios c WHERE c.usuario_id = v_juan
                                                   AND c.rol_anterior = 'preventista' AND c.rol_nuevo = 'encargado'),
                  '1 Juan: el cambio de rol no quedó en perfil_rol_cambios');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  BEGIN
    -- 1b · un rol de mayo: preventista_taco cuenta como preventista; uno de admin, no.
    INSERT INTO perfil_rol_cambios (usuario_id, cambiado_at, rol_anterior, rol_nuevo, origen)
    VALUES (v_pedro, now() - interval '30 days', 'preventista_taco', 'preventista', 'audit_logs'),
           (v_ana2, now() - interval '30 days', 'admin', 'preventista', 'audit_logs');
    v_fallas := v_fallas || pg_temp.chk(public._actua_como_preventista_al(v_pedro, v_s1, now() - interval '40 days')
                                        AND NOT public._actua_como_preventista_al(v_ana2, v_s1, now() - interval '40 days')
                                        AND public._actua_como_preventista_al(v_ana2, v_s1, now() - interval '20 days'),
                  '1b el rol a un momento: preventista_taco, admin o el de hoy no dan lo esperado');
    DELETE FROM perfil_rol_cambios WHERE usuario_id IN (v_pedro, v_ana2);
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1b · error: %s', SQLERRM);
  END;

  -- ================= 1c · COM-2 el cambio de cliente conserva el rol de la venta original ===
  BEGIN
    -- Lucas carga el pedido como el front (crear_pedido_completo), hace 10 días.
    PERFORM pg_temp.claims(v_lucas, v_s1);
    v_j := public.crear_pedido_completo(v_c1, 1000, v_lucas,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
             'ensayo t7', 'efectivo', 'pendiente', v_hoy, NULL);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'no se pudo crear el pedido de Lucas: %', v_j;
    END IF;
    v_q := (v_j->>'pedido_id')::bigint;
    UPDATE pedidos SET created_at = now() - interval '10 days' WHERE id = v_q;
    PERFORM pg_temp.claims(v_ua, v_s1);
    UPDATE perfiles SET rol = 'encargado' WHERE id = v_lucas;
    v_j := public.cambiar_cliente_pedido(v_q, v_c2, v_ua,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
             1000, NULL, 0, 'ensayo t7', 'pedido_nuevo');
    PERFORM set_config('app.stock_origen', '', true);
    PERFORM set_config('app.stock_ref_tipo', '', true);
    PERFORM set_config('app.stock_ref_id', '', true);
    PERFORM set_config('app.stock_user_id', '', true);
    v_qn := (SELECT id FROM pedidos WHERE cliente_id = v_c2 AND usuario_id = v_lucas ORDER BY id DESC LIMIT 1);
    IF v_qn IS NULL OR v_qn = v_q THEN
      RAISE EXCEPTION 'el cambio de cliente no dejó un pedido nuevo: %', v_j;
    END IF;
    PERFORM pg_temp.claims(v_ua, v_s1);
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true,
                       fecha_entrega = (v_hoy + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
     WHERE id = v_qn;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.comision(ARRAY[v_qn]) = 30,
                  format('1c Lucas: el pedido del cambio de cliente comisiona %s y no 30 (vendido_at %s, created_at %s)',
                         pg_temp.comision(ARRAY[v_qn]), (SELECT vendido_at FROM pedidos WHERE id = v_qn),
                         (SELECT created_at FROM pedidos WHERE id = v_qn)));
    UPDATE pedidos SET vendido_at = now() WHERE id = v_qn;
    v_fallas := v_fallas || pg_temp.chk((SELECT vendido_at FROM pedidos WHERE id = v_qn) = now() - interval '10 days',
                  '1c vendido_at se pudo cambiar después del alta');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1c · error: %s', SQLERRM);
  END;

  -- =================================== 2 · COM-1 y Com-B2 nadie se fija su % ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('2 A2 se pone el 50 %', pg_temp.regla(NULL, v_a2, 50), '42501', v_a2);
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM comision_reglas WHERE preventista_id = v_a2),
                  '2 quedó una regla de A2 cargada por A2');
    v_m_a2 := pg_temp.como(pg_temp.regla(NULL, v_a2, 5))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT usuario_id FROM comision_reglas WHERE id = v_m_a2) = v_ua,
                  '2 la regla de A2 cargada por A no dice que la cargó A');
    v_fallas := v_fallas || pg_temp.falla('2 A2 edita su propia regla', pg_temp.regla(v_m_a2, v_a2, 50), '42501', v_a2);
    -- … tampoco pasándosela a otro: sigue siendo la suya hasta que la cambie otro admin.
    v_fallas := v_fallas || pg_temp.falla('2 A2 le pasa su regla a Pedro', pg_temp.regla(v_m_a2, v_pedro, 50), '42501', v_a2);
    v_fallas := v_fallas || pg_temp.falla('2 A2 da de baja su propia regla',
                  format('SELECT public.desactivar_comision_regla(p_id => %s)', v_m_a2), '42501', v_a2);
    v_fallas := v_fallas || pg_temp.chk((SELECT porcentaje FROM comision_reglas WHERE id = v_m_a2) = 5
                                        AND (SELECT preventista_id FROM comision_reglas WHERE id = v_m_a2) = v_a2
                                        AND (SELECT activo FROM comision_reglas WHERE id = v_m_a2),
                  '2 la regla de A2 cambió por A2');
    -- La de Pedro: la carga A al 5 % y la edita A2 al 4 % (la regla nace este mes: se edita en el lugar).
    v_r1 := pg_temp.como(pg_temp.regla(NULL, v_pedro, 5))::bigint;
    -- La regla se creó hace 5 días (la edición es hoy): «cargado el» tiene que ser el de la edición.
    UPDATE comision_reglas SET created_at = now() - interval '5 days' WHERE id = v_r1;
    v_r2 := pg_temp.como(pg_temp.regla(v_r1, v_pedro, 4), v_a2)::bigint;
    v_fallas := v_fallas || pg_temp.chk(v_r2 = v_r1 AND (SELECT porcentaje FROM comision_reglas WHERE id = v_r1) = 4
                                        AND (SELECT usuario_id FROM comision_reglas WHERE id = v_r1) = v_a2,
                  format('2 Com-B2: editada por A2 la regla %s quedó con %s y usuario %s',
                         v_r1, (SELECT porcentaje FROM comision_reglas WHERE id = v_r1),
                         (SELECT usuario_id = v_a2 FROM comision_reglas WHERE id = v_r1)));
    v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM audit_logs WHERE tabla = 'comision_reglas'
                                          AND registro_id = v_r1::text AND accion IN ('INSERT', 'UPDATE')) >= 2,
                  '2 Com-B2: comision_reglas no quedó auditada (alta y edición)');
    -- 2b · la regla para todas las sucursales que carga el server (sin sesión ni sucursal activa):
    -- entra y queda auditada (audit_log_changes la rechazaba por no tener sucursal).
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.headers', '', true);
    INSERT INTO comision_reglas (sucursal_id, porcentaje, vigente_desde) VALUES (NULL, 1.5, v_hoy) RETURNING id INTO v_r2;
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM audit_logs WHERE tabla = 'comision_reglas'
                                                   AND registro_id = v_r2::text AND accion = 'INSERT'),
                  '2b la regla global del server no quedó auditada');
    DELETE FROM comision_reglas WHERE id = v_r2;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- ========================================== 3 · Fr-B8 el alta no duplica ===
  BEGIN
    v_r1 := pg_temp.como(pg_temp.regla(NULL, v_ana, 2.5))::bigint;
    v_r2 := pg_temp.como(pg_temp.regla(NULL, v_ana, 2.5))::bigint;
    v_n := (SELECT count(*) FROM comision_reglas WHERE preventista_id = v_ana AND activo);
    v_fallas := v_fallas || pg_temp.chk(v_r1 = v_r2 AND v_n = 1,
                  format('3 el doble toque dio las reglas %s y %s (%s activas)', v_r1, v_r2, v_n));
    v_fallas := v_fallas || pg_temp.falla('3 la misma regla el mismo día con otro %', pg_temp.regla(NULL, v_ana, 7), 'Ya hay una regla igual');
    -- No le cambia nada a Ana: se da de baja (A, no es la propia).
    PERFORM pg_temp.como(format('SELECT public.desactivar_comision_regla(p_id => %s)', v_r1));
    DELETE FROM comision_reglas WHERE id = v_r1;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ====================================== 4 · la pantalla de liquidar: % y quién ===
  BEGIN
    SELECT public._liquidacion_json(e, v_hoy - 40, v_hoy) INTO v_j FROM empleados e WHERE e.id = e_juan;
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{comisiones,total}')::numeric = 9000,
                  format('4 Juan: la liquidación le da %s y no 9.000', v_j#>>'{comisiones,total}'));
    v_fallas := v_fallas || pg_temp.chk(EXISTS (
                    SELECT 1 FROM jsonb_array_elements(v_j#>'{comisiones,porcentajes}') x
                     WHERE (x->>'pct')::numeric = 3 AND x->>'origen' = 'por_defecto' AND x->>'rol' = 'preventista'
                       AND x->>'cargado_por' = (SELECT nombre FROM perfiles WHERE id = v_ua)
                       AND (x->>'comision')::numeric = 9000),
                  format('4 Juan: los porcentajes no dicen 3 %% por defecto de preventista cargado por A: %s', v_j#>'{comisiones,porcentajes}'));
    e_pedro := pg_temp.alta(jsonb_build_object('usuario_id', v_pedro));
    v_pp := pg_temp.pedido(v_pedro, v_c1, v_hoy, 100000);
    SELECT public._liquidacion_json(e, v_hoy - 40, v_hoy) INTO v_j FROM empleados e WHERE e.id = e_pedro;
    v_fallas := v_fallas || pg_temp.chk(EXISTS (
                    SELECT 1 FROM jsonb_array_elements(v_j#>'{comisiones,porcentajes}') x
                     WHERE (x->>'pct')::numeric = 4 AND x->>'origen' = 'regla'
                       AND x->>'cargado_por' = (SELECT nombre FROM perfiles WHERE id = v_a2)
                       AND (x->>'cargado_el')::date = v_hoy
                       AND (x->>'comision')::numeric = 4000),
                  format('4 Pedro: los porcentajes no dicen 4 %% de la regla que dejó A2 hoy: %s', v_j#>'{comisiones,porcentajes}'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ============================= 5 · D11 el % de la simulación del gerencial ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk((SELECT comision_pct_simulacion FROM politicas_comerciales WHERE sucursal_id = v_s1) = 2,
                  '5 el % de la simulación no nace en 2');
    v_fallas := v_fallas || pg_temp.anda('5 el admin lo pone en 3,5', 'SELECT public.actualizar_comision_pct_simulacion(p_pct => 3.5)');
    v_fallas := v_fallas || pg_temp.falla('5 el encargado lo cambia', 'SELECT public.actualizar_comision_pct_simulacion(p_pct => 9)', '42501', v_enc);
    v_fallas := v_fallas || pg_temp.falla('5 NaN', 'SELECT public.actualizar_comision_pct_simulacion(p_pct => ''NaN''::numeric)', '22023');
    v_fallas := v_fallas || pg_temp.falla('5 101', 'SELECT public.actualizar_comision_pct_simulacion(p_pct => 101)', '22023');
    -- El freno de la columna, también fuera de la RPC (el server o un admin por SQL).
    BEGIN
      UPDATE politicas_comerciales SET comision_pct_simulacion = 'NaN' WHERE sucursal_id = v_s1;
      v_fallas := v_fallas || '5 la columna acepta NaN'::text;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    v_j := pg_temp.como(format('SELECT public.reporte_gerencial(p_sucursal_id => %s, p_desde => %L::date, p_hasta => %L::date)',
                               v_s1, v_mes, v_hoy))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{kpis,comision_pct_default}')::numeric = 3.5,
                  format('5 el gerencial simula con %s y no con 3,5', v_j#>>'{kpis,comision_pct_default}'));
    v_t1 := pg_temp.como('SELECT (SELECT r.comision_pct_simulacion FROM public.politica_comercial_reservada() r)::text');
    v_fallas := v_fallas || pg_temp.chk(v_t1 = '3.50', format('5 la RPC reservada le da %s al admin', v_t1));
    v_t1 := pg_temp.como('SELECT count(*)::text FROM public.politica_comercial_reservada()', v_ana);
    v_fallas := v_fallas || pg_temp.chk(v_t1 = '0', '5 la RPC reservada le da fila al preventista');
    v_fallas := v_fallas || pg_temp.chk(NOT has_column_privilege('authenticated', 'public.politicas_comerciales',
                                                                 'comision_pct_simulacion', 'SELECT'),
                  '5 el % de la simulación se lee por REST');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- ================================== 6 · SEG-03 el origen lo pone el server ===
  BEGIN
    PERFORM pg_temp.claims(v_ua, v_s1);
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
    VALUES ('ZZ t7 X', 100, 1000, 60, v_s1, 'ZZ t7 Varios') RETURNING id INTO v_x;
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
    VALUES ('ZZ t7 Y', 100, 1000, 60, v_s1, 'ZZ t7 Gaseosas') RETURNING id INTO v_y;
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ t7 Z', 100, 1000, 60, v_s1) RETURNING id INTO v_z;
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ t7 W', 100, 1000, 60, v_s1) RETURNING id INTO v_w;
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ t7 V', 100, 1000, 60, v_s1) RETURNING id INTO v_v;
    INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
    VALUES (v_c3, ' zz t7 gaseosas ', 20);
    INSERT INTO grupos_precio (nombre, sucursal_id, activo) VALUES ('ZZ t7 grupo', v_s1, true) RETURNING id INTO v_grupo;
    INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (v_grupo, v_z, v_s1);
    INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id, min_productos_distintos)
    VALUES (v_grupo, 10, 70, true, v_s1, 1) RETURNING id INTO v_esc;
    INSERT INTO pedidos (cliente_id, sucursal_id, fecha, total, usuario_id, creado_por)
    VALUES (v_c3, v_s1, v_hoy, 0, v_pedro, v_pedro) RETURNING id INTO v_po;
    INSERT INTO pedido_items (pedido_id, sucursal_id, producto_id, cantidad, precio_unitario, subtotal, costo_unitario_al_crear) VALUES
      (v_po, v_s1, v_x, 1, 90, 90, 60),
      (v_po, v_s1, v_y, 1, 80, 80, 60),
      (v_po, v_s1, v_z, 12, 70, 840, 60),
      (v_po, v_s1, v_w, 1, 55, 55, 60),
      (v_po, v_s1, v_v, 1, 100, 100, 60);
    UPDATE pedidos SET total = 1165 WHERE id = v_po;
    -- El teléfono miente en todo.
    PERFORM pg_temp.como(format('SELECT public.registrar_origen_precio_items(p_pedido_id => %s, p_origenes => %L::jsonb)', v_po,
              jsonb_build_array(
                jsonb_build_object('producto_id', v_x, 'es_bonificacion', false, 'origen_precio', 'manual'),
                jsonb_build_object('producto_id', v_y, 'es_bonificacion', false, 'origen_precio', 'lista'),
                jsonb_build_object('producto_id', v_z, 'es_bonificacion', false, 'origen_precio', 'lista'),
                jsonb_build_object('producto_id', v_w, 'es_bonificacion', false, 'origen_precio', 'mayorista',
                                   'grupo_precio_escala_id', v_esc))), v_pedro);
    SELECT string_agg(pr.nombre || '=' || COALESCE(pi.origen_precio, '∅') || COALESCE('#' || pi.grupo_precio_escala_id, ''), ' ' ORDER BY pr.nombre)
      INTO v_t1
      FROM pedido_items pi JOIN productos pr ON pr.id = pi.producto_id WHERE pi.pedido_id = v_po;
    v_fallas := v_fallas || pg_temp.chk(v_t1 = format('ZZ t7 V=lista ZZ t7 W=manual ZZ t7 X=desc_cliente ZZ t7 Y=desc_categoria ZZ t7 Z=mayorista#%s', v_esc),
                  format('6 el origen de las líneas: %s', v_t1));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- ========================= 7 · Com-B7 y Com-B8 las metas de Ana ===
  BEGIN
    PERFORM pg_temp.alta(jsonb_build_object('cliente_id', v_ce1));
    PERFORM pg_temp.alta(jsonb_build_object('cliente_id', v_ce2));
    PERFORM pg_temp.claims(v_ua, v_s1);
    INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo, usuario_id)
    VALUES (v_s1, v_ana, v_mes, (v_mes + interval '1 month - 1 day')::date, 'facturacion', 100000, v_ua) RETURNING id INTO v_m_fac;
    INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo, usuario_id)
    VALUES (v_s1, v_ana, v_mes, (v_mes + interval '1 month - 1 day')::date, 'cobertura', 10, v_ua) RETURNING id INTO v_m_cob;
    v_pa1 := pg_temp.pedido(v_ana, v_ce1, v_hoy, 1000);
    v_pa2 := pg_temp.pedido(v_ana, v_c2, v_hoy, 0);
    v_pa3 := pg_temp.pedido(v_ana, v_ce2, v_hoy, 500);
    v_pa4 := pg_temp.pedido(v_ana, v_c6, v_hoy, 300);
    PERFORM pg_temp.claims(v_ua, v_s1);
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id) VALUES
      (v_ce1, v_pa1, 400, 'adelanto_sueldo', v_hoy, v_ua, v_s1),
      (v_ce2, v_pa3, 500, 'adelanto_sueldo', v_hoy, v_ua, v_s1);
    v_m := (SELECT logrado FROM public._metas_logrado(ARRAY[v_m_fac]));
    v_fallas := v_fallas || pg_temp.chk(v_m = 900, format('7 Com-B7: la facturación de Ana es %s y no 900', v_m));
    v_fallas := v_fallas || pg_temp.chk(v_m = (SELECT sum(base) FROM public._comision_lineas(ARRAY[v_pa1, v_pa2, v_pa3, v_pa4])),
                  format('7 Com-B7: la meta (%s) no cierra con la base de la comisión (%s)', v_m,
                         (SELECT sum(base) FROM public._comision_lineas(ARRAY[v_pa1, v_pa2, v_pa3, v_pa4]))));
    v_m := (SELECT logrado FROM public._metas_logrado(ARRAY[v_m_cob]));
    v_fallas := v_fallas || pg_temp.chk(v_m = 2, format('7 Com-B8: la cobertura de Ana es %s y no 2', v_m));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- ========================= 8 · REP-7 calcular_comisiones, la Red ===
  BEGIN
    v_pv := pg_temp.pedido(v_pr2, v_cs2, v_hoy, 50000, v_s2, v_ps2);
    UPDATE sucursales SET activa = false WHERE id = v_s2;
    v_j := pg_temp.como(format('SELECT public.calcular_comisiones(p_desde => %L::date, p_hasta => %L::date, p_sucursal_ids => NULL)',
                               v_hoy - 1, v_hoy))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'preventistas') x WHERE x->>'id' = v_pr2::text),
                  '8 REP-7: sin sucursales, calcular_comisiones cuenta una sucursal inactiva');
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'preventistas') x WHERE x->>'id' = v_ana::text),
                  '8 REP-7: sin sucursales, calcular_comisiones deja afuera la sucursal activa');
    UPDATE sucursales SET activa = true WHERE id = v_s2;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ========================= 9 · Com-B6 las metas propias piden un rol activo ===
  BEGIN
    PERFORM pg_temp.claims(v_ua, v_s1);
    INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo, usuario_id)
    VALUES (v_s1, v_ana2, v_mes, (v_mes + interval '1 month - 1 day')::date, 'facturacion', 1000, v_ua);
    v_fallas := v_fallas || pg_temp.anda('9 Ana activa ve su avance',
                  format('SELECT public.avance_metas_preventista(p_preventista_id => NULL, p_periodo => %L::date)::text', v_hoy), v_ana);
    v_t1 := pg_temp.como('SELECT count(*)::text FROM public.metas_preventista', v_ana);
    v_fallas := v_fallas || pg_temp.chk(v_t1 = '2', format('9 Ana activa ve %s metas y no 2', v_t1));
    PERFORM pg_temp.claims(v_ua, v_s1);
    -- La base local no trae el Auth completo (banned_until): sin triggers, como test-ola3-t2.
    BEGIN
      UPDATE perfiles SET activo = false WHERE id = v_ana2;
    EXCEPTION WHEN OTHERS THEN
      SET LOCAL session_replication_role = replica;
      UPDATE perfiles SET activo = false WHERE id = v_ana2;
      SET LOCAL session_replication_role = origin;
    END;
    v_fallas := v_fallas || pg_temp.falla('9 desactivado ve su avance',
                  format('SELECT public.avance_metas_preventista(p_preventista_id => NULL, p_periodo => %L::date)::text', v_hoy), '42501', v_ana2);
    v_t1 := pg_temp.como('SELECT count(*)::text FROM public.metas_preventista', v_ana2);
    v_fallas := v_fallas || pg_temp.chk(v_t1 = '0', format('9 el desactivado lee %s metas suyas por REST', v_t1));
    v_fallas := v_fallas || pg_temp.falla('9 un chofer pide su avance',
                  format('SELECT public.avance_metas_preventista(p_preventista_id => NULL, p_periodo => %L::date)::text', v_hoy), '42501', v_t);
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ========================= R1 · un preventista no cobra con adelanto ===
  BEGIN
    PERFORM pg_temp.claims(v_ua, v_s1);
    UPDATE perfiles SET rol = 'preventista' WHERE id = v_juan;
    INSERT INTO pedidos (cliente_id, sucursal_id, fecha, total, usuario_id, creado_por)
    VALUES (v_ce1, v_s1, v_hoy, 0, v_juan, v_juan) RETURNING id INTO v_n;
    INSERT INTO pedido_items (pedido_id, sucursal_id, producto_id, cantidad, precio_unitario, subtotal, costo_unitario_al_crear)
    VALUES (v_n, v_s1, v_prod, 1, 100, 100, 60);
    UPDATE pedidos SET total = 100 WHERE id = v_n;
    v_fallas := v_fallas || pg_temp.falla('R1 el preventista cobra con adelanto de sueldo',
                  format('SELECT public.registrar_pagos_pedido(p_pedido_id => %s, p_metodos => %L::jsonb, p_fecha => %L::date)::text', v_n,
                         jsonb_build_array(jsonb_build_object('forma_pago', 'adelanto_sueldo', 'monto', 100)), v_hoy),
                  'Forma de pago invalida', v_juan);
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('R1 · error: %s', SQLERRM);
  END;

  -- ============================================================== R2 · auditoría ===
  BEGIN
    v_ch_fin := (pg_temp.audit()->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin <= v_ch_ini,
                  format('R2 auditoria_integridad: critical/high en rojo pasó de %s a %s (%s)', v_ch_ini, v_ch_fin,
                         (SELECT string_agg(c->>'id', ', ') FROM jsonb_array_elements(pg_temp.audit()->'checks') c
                           WHERE NOT (c->>'ok')::boolean AND c->>'severidad' IN ('critical', 'high'))));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('R2 · error: %s', SQLERRM);
  END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · t7 comisiones y metas: 1 a 9, con 1b, 1c, 2b, R1 y R2';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
END
$ensayo$;
