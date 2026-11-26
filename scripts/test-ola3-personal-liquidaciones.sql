-- Ensayo de la migración NNN_ola3_personal_liquidaciones (ola 3, tarjeta T6 de #1677: personal y
-- liquidaciones; #1534, Com-B3, Com-B4 y Com-B5 de #1554/#1551, m2, m3, m4 y m5 de #1392).
--
-- No deja rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una excepción.
-- Antes de aplicar la migración tiene que FALLAR en 1, 2, 3, 4, 5, 6, 7, 8 y 9; después, dar
-- 'ENSAYO OK'. Corre en una base local con la semilla mínima o en una copia de prod.
--
-- Personas: un admin activo de todas las sucursales activas (sale de la base). El ensayo crea en
-- auth.users los preventistas, los choferes y un admin de una sola sucursal, para que nada se
-- cruce con datos reales. Los empleados, los movimientos, las liquidaciones y sus anulaciones van
-- por las RPC reales, como el front. Los pedidos entregados, los cobros en efectivo de cada
-- rendición, la cancelación de un pedido y el cierre de una rendición se arman como postgres
-- sobre las tablas (como test-gastos-personal-1521.sql): lo que importa es lo que ven la
-- comisión y la rendición. L es el lunes de hace dos semanas; S1 = [L, L+6] y S2 = [L+7, L+13].
--
-- 1 · #1534 el pago de una liquidación que sale de una rendición tiene tope en su efectivo.
--     Rendición con $ 5.000 de efectivo: liquidar pagando $ 5.000,01 de ahí se rechaza; $ 5.000
--     entra y deja la rendición en 0 (también en la cuenta del front, obtener_resumen_rendiciones);
--     otra liquidación que paga $ 1 de esa rendición se rechaza, y desde la oficina entra.
-- 2 · Com-B3 registrar_movimiento_empleado con clave (p_clave). Con saldo $ 1.000, un pago de
--     $ 1.000 con la clave K y el reintento con K devuelven el mismo movimiento (uno solo, saldo 0:
--     el reintento no choca con «más de lo que se le debe»). K con otro monto, o de otro admin,
--     22023. Sin clave (un PWA de antes), dos llamadas son dos movimientos. La firma vieja no
--     existe (nada de dos sobrecargas) y la nueva es de authenticated y no de anon.
-- 3 · Com-B3 liquidar_empleado con clave: el mismo JSON y la misma clave dos veces dan una sola
--     liquidación; otro JSON con la clave, 22023; sin clave el reintento sigue diciendo que el
--     período ya no es el próximo; si la liquidación del primer intento se anuló, el reintento lo
--     dice. Firma vieja fuera, grants como el resto.
-- 4 · Com-B4 un empleado de baja con sólo un ajuste negativo pendiente aparece «para liquidar»
--     (el período de _empleado_json, el mismo que da previsualizar_liquidacion).
-- 5 · Com-B5 (decisión del dueño, 25/11) un admin no cambia la ficha de cliente de su propia
--     ficha de empleado (ni la saca ni la cambia); editar lo demás sí, y otro admin sí se la cambia.
-- 6 · m2 el pago de una rendición cerrada llega a la cuenta con `rendicion.cerrada` (la regla del
--     server, control_rendicion_cerrado): true en la cerrada y false en la abierta; revertir
--     coincide (la cerrada se rechaza, la abierta entra).
-- 7 · m3 anular la liquidación de E1 después de pasarle su usuario a E2 dejaba los pedidos sin
--     dueño: ahora se rechaza con el motivo. La de un empleado sin comisiones liquidadas se anula
--     aunque le hayan vinculado un usuario después. 7b y 7c: sólo cuentan las comisiones
--     iniciales; un ajuste del usuario viejo vuelve a la ficha por empleado_id y no traba.
-- 8 · m4 (decisión del dueño, 25/11) un empleado con $ 2.000 de comisión sin liquidar no se pasa
--     de sucursal ni a «las dos»: el mensaje dice el monto y la sucursal. La pantalla lo ve antes
--     (comision_sin_liquidar_empleado). Liquidado, se pasa. 8b: con el período en curso ya
--     liquidado y una venta entregada hoy, el motivo dice desde qué lunes se puede liquidar.
--     8c (decisión del dueño, 26/11): con los mismos $ 2.000 tampoco se le saca el usuario a la
--     ficha ni se le pasa otro, con el motivo; la pantalla lo ve antes (aviso_usuario). Sí se
--     edita lo demás y se le vincula usuario a una ficha que no tenía; liquidado, se le cambia.
-- 9 · m5 una liquidación sin movimientos (sueldo 0, sin comisión, sin pago) adelanta el corte: el
--     ajuste de $ 1.000 que ya liquidó no vuelve a salir en la vista previa siguiente, que lo
--     cuenta en el saldo anterior.
-- 10 · auditoria_integridad: ningún critical/high nuevo.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-ola3-personal-liquidaciones.sql

DO $ensayo$
DECLARE
  v_s1     bigint;
  v_ua     uuid;
  v_hoy    date := public._tablero_hoy();
  v_l      date := date_trunc('week', public._tablero_hoy()::timestamp)::date - 14;
  v_c1     bigint;
  v_c2     bigint;
  v_prod   bigint;
  v_caja   bigint;
  v_t1     uuid;
  v_t6     uuid;
  v_t6b    uuid;
  v_p4     uuid;
  v_p7     uuid;
  v_p8     uuid;
  v_ax     uuid;
  v_a2     uuid;
  e1       bigint;
  e1b      bigint;
  e2       bigint;
  e3       bigint;
  e4       bigint;
  e5       bigint;
  e6       bigint;
  e7       bigint;
  e7b      bigint;
  e7c      bigint;
  e8       bigint;
  e8c      bigint;
  v_p8c    uuid;
  e9       bigint;
  e7d      bigint;
  v_q1     uuid;
  v_q2     uuid;
  v_ped    bigint;
  v_liq    bigint;
  v_liq2   bigint;
  v_mov    bigint;
  v_mov2   bigint;
  v_k      uuid;
  v_j      jsonb;
  v_x      jsonb;
  v_n      bigint;
  v_m      numeric;
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
  IF v_ua IS NULL OR (SELECT count(*) FROM sucursales WHERE activa) < 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hacen falta un admin activo de todas las sucursales activas y dos sucursales activas';
  END IF;
  -- Las fichas de empleado de un admin real no se cruzan con las del ensayo (usuario_id es UNIQUE).
  UPDATE empleados SET usuario_id = NULL WHERE usuario_id = v_ua;
  PERFORM set_config('t6.ua', v_ua::text, true);
  PERFORM set_config('t6.s1', v_s1::text, true);

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
    PERFORM pg_temp.claims(COALESCE(p_uid, current_setting('t6.ua')::uuid), current_setting('t6.s1')::bigint);
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

  -- El SQLSTATE con que falla la RPC ('' si anda).
  CREATE FUNCTION pg_temp.estado(p_sql text, p_uid uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_sql, p_uid);
    RETURN '';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN SQLSTATE;
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

  -- Un usuario nuevo de la sucursal (handle_new_user lo crea con la de app_metadata).
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE
    v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'ZZ t6 ' || p_rol), now(), now());
    RETURN v;
  END $f$;

  -- El alta como ModalEmpleado (guardar_empleado), con lo que cambie p.
  CREATE FUNCTION pg_temp.alta(p jsonb, p_sueldo numeric, p_comis boolean, p_uid uuid DEFAULT NULL) RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ t6 ' || gen_random_uuid(), 'puesto', 'preventista', 'sucursal_id', current_setting('t6.s1')::bigint,
      'de_las_dos', false, 'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', NULL, 'cliente_id', NULL,
      'vehiculo_id', NULL, 'saldo_inicial', NULL,
      'arreglo', jsonb_build_object('vigente_desde', date_trunc('week', public._tablero_hoy()::timestamp)::date - 14,
                                    'sueldo', p_sueldo, 'frecuencia', 'semanal', 'comisiona', p_comis)) || p), p_uid)::bigint;
  $f$;

  -- La edición como ModalEmpleado: la ficha entera, con lo que cambie p.
  CREATE FUNCTION pg_temp.edicion(p_emp bigint, p jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'id', e.id, 'nombre', e.nombre, 'puesto', e.puesto, 'sucursal_id', e.sucursal_id, 'de_las_dos', e.de_las_dos,
      'cuil', e.cuil, 'fecha_ingreso', e.fecha_ingreso, 'telefono', e.telefono, 'usuario_id', e.usuario_id,
      'cliente_id', e.cliente_id, 'vehiculo_id', e.vehiculo_id) || p)
      FROM public.empleados e WHERE e.id = p_emp;
  $f$;

  CREATE FUNCTION pg_temp.mov(p_emp bigint, p jsonb, p_clave uuid DEFAULT NULL) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_movimiento_empleado(p_empleado_id => %s, p_movimiento => %L::jsonb%s)', p_emp, p,
                  CASE WHEN p_clave IS NULL THEN '' ELSE format(', p_clave => %L::uuid', p_clave) END);
  $f$;

  CREATE FUNCTION pg_temp.rev(p_mov bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.revertir_movimiento_empleado(p_movimiento_id => %s, p_motivo => %L)', p_mov, 'Ensayo t6');
  $f$;

  CREATE FUNCTION pg_temp.plata(p_t uuid, p_d date) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('origen_pago', 'rendicion', 'rendicion_transportista_id', p_t, 'rendicion_fecha', p_d);
  $f$;

  CREATE FUNCTION pg_temp.pv(p_emp bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', p_emp))::jsonb;
  $f$;

  -- El JSON que manda ModalLiquidar para el próximo período, pagando p_pago con la plata de p_plata.
  CREATE FUNCTION pg_temp.lqj(p_emp bigint, p_pago numeric, p_plata jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('desde', v#>>'{periodo,desde}', 'hasta', v#>>'{periodo,hasta}',
                              'sueldo', (v#>>'{sueldo,propuesto}')::numeric, 'motivo_sueldo', NULL, 'pago', p_pago,
                              'fecha_pago', public._tablero_hoy(), 'a_pagar_esperado', (v->>'a_pagar')::numeric) || p_plata
      FROM (SELECT pg_temp.pv(p_emp) AS v) x;
  $f$;

  CREATE FUNCTION pg_temp.lqs(p_emp bigint, p_j jsonb, p_clave uuid DEFAULT NULL) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.liquidar_empleado(p_empleado_id => %s, p_liquidacion => %L::jsonb%s)', p_emp, p_j,
                  CASE WHEN p_clave IS NULL THEN '' ELSE format(', p_clave => %L::uuid', p_clave) END);
  $f$;

  CREATE FUNCTION pg_temp.lq(p_emp bigint, p_pago numeric, p_plata jsonb DEFAULT '{}') RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(pg_temp.lqs(p_emp, pg_temp.lqj(p_emp, p_pago, p_plata)))::bigint;
  $f$;

  CREATE FUNCTION pg_temp.an(p_liq bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.anular_liquidacion(p_liquidacion_id => %s, p_motivo => %L)', p_liq, 'Ensayo t6');
  $f$;

  CREATE FUNCTION pg_temp.saldo(p_emp bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos WHERE empleado_id = p_emp;
  $f$;

  -- Un pedido entregado de p_usr el día p_dia, por p_total.
  CREATE FUNCTION pg_temp.pedido(p_usr uuid, p_dia date, p_total numeric) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v bigint;
  BEGIN
    PERFORM pg_temp.claims(current_setting('t6.ua')::uuid, current_setting('t6.s1')::bigint);
    INSERT INTO pedidos (cliente_id, sucursal_id, fecha, total, usuario_id, creado_por)
    VALUES (current_setting('t6.c1')::bigint, current_setting('t6.s1')::bigint, p_dia, 0, p_usr, p_usr) RETURNING id INTO v;
    INSERT INTO pedido_items (pedido_id, sucursal_id, producto_id, cantidad, precio_unitario, subtotal, costo_unitario_al_crear)
    VALUES (v, current_setting('t6.s1')::bigint, current_setting('t6.prod')::bigint, p_total / 100, 100, p_total, 60);
    UPDATE pedidos SET total = p_total WHERE id = v;
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true,
                       fecha_entrega = (p_dia + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
     WHERE id = v;
    RETURN v;
  END $f$;

  -- Un cobro en efectivo del chofer ese día (sobre la boleta grande del ensayo).
  CREATE FUNCTION pg_temp.cobro(p_t uuid, p_d date, p_monto numeric) RETURNS void LANGUAGE sql AS $f$
    SELECT pg_temp.claims(current_setting('t6.ua')::uuid, current_setting('t6.s1')::bigint);
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (current_setting('t6.c1')::bigint, current_setting('t6.caja')::bigint, p_monto, 'efectivo', p_d, p_t,
            current_setting('t6.s1')::bigint);
  $f$;

  -- El efectivo a entregar como lo calcula el front (la fila de obtener_resumen_rendiciones).
  CREATE FUNCTION pg_temp.a_entregar(p_d date, p_t uuid) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE((f->>'total_efectivo')::numeric - (f->>'total_gastos')::numeric - (f->>'total_pagos_personal')::numeric
                    - COALESCE((f->>'total_faltantes_empleados')::numeric, 0), 0)
      FROM (SELECT pg_temp.como(format(
              'SELECT to_jsonb(r) FROM public.obtener_resumen_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, p_transportista_id => %L::uuid) r',
              p_d, p_d, p_t))::jsonb AS f) x;
  $f$;

  CREATE FUNCTION pg_temp.audit() RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.claims(current_setting('t6.ua')::uuid, current_setting('t6.s1')::bigint);
    RETURN public.auditoria_integridad();
  END $f$;

  IF cardinality(pg_temp.falla('canario', 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', 'SELECT 1/0', 'otro mensaje')) <> 1
     OR pg_temp.como('SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_ua, v_s1)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  v_ch_ini := (pg_temp.audit()->>'critical_high_en_rojo')::int;

  -- ---------------------------------------------------------------- datos ---
  PERFORM pg_temp.claims(v_ua, v_s1);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ t6 C1', 'ZZ t6 C1', 'Ensayo t6 1', v_s1) RETURNING id INTO v_c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ t6 C2', 'ZZ t6 C2', 'Ensayo t6 2', v_s1) RETURNING id INTO v_c2;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ t6 A', 100, 1000000, 60, v_s1) RETURNING id INTO v_prod;
  PERFORM set_config('t6.c1', v_c1::text, true);
  PERFORM set_config('t6.prod', v_prod::text, true);
  -- La boleta grande sobre la que van los cobros de las rendiciones (del admin: no comisiona en el ensayo).
  v_caja := pg_temp.pedido(v_ua, v_hoy - 10, 1000000);
  PERFORM set_config('t6.caja', v_caja::text, true);

  -- ==================== 1 · #1534 el tope del pago de una liquidación desde una rendición ===
  BEGIN
    v_t1 := pg_temp.u('transportista', v_s1);
    PERFORM pg_temp.cobro(v_t1, v_hoy - 1, 5000);
    v_fallas := v_fallas || pg_temp.chk(public._rendicion_efectivo_a_entregar(v_s1, v_t1, v_hoy - 1) = 5000
                  AND pg_temp.a_entregar(v_hoy - 1, v_t1) = 5000, '1 la rendición no arrancó con $ 5.000');
    e1 := pg_temp.alta('{}', 70000, false);
    v_fallas := v_fallas || pg_temp.falla('1 un centavo de más que el efectivo',
                  pg_temp.lqs(e1, pg_temp.lqj(e1, 5000.01, pg_temp.plata(v_t1, v_hoy - 1))),
                  'El pago supera el efectivo que le queda por entregar a esa rendición');
    v_liq := pg_temp.lq(e1, 5000, pg_temp.plata(v_t1, v_hoy - 1));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT desde FROM empleado_liquidaciones WHERE id = v_liq) = v_l
      AND (SELECT pagado FROM empleado_liquidaciones WHERE id = v_liq) = 5000
      AND public._rendicion_efectivo_a_entregar(v_s1, v_t1, v_hoy - 1) = 0
      AND pg_temp.a_entregar(v_hoy - 1, v_t1) = 0,
      format('1 el efectivo justo entra y deja la rendición en 0 (server %s, front %s)',
             public._rendicion_efectivo_a_entregar(v_s1, v_t1, v_hoy - 1), pg_temp.a_entregar(v_hoy - 1, v_t1)));
    e1b := pg_temp.alta('{}', 70000, false);
    v_fallas := v_fallas || pg_temp.falla('1 la rendición ya sin efectivo',
                  pg_temp.lqs(e1b, pg_temp.lqj(e1b, 1, pg_temp.plata(v_t1, v_hoy - 1))),
                  'El pago supera el efectivo que le queda por entregar a esa rendición');
    v_fallas := v_fallas || pg_temp.anda('1 desde la oficina no tiene ese tope', pg_temp.lqs(e1b, pg_temp.lqj(e1b, 70000)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  -- ================================= 2 · Com-B3 la clave de registrar_movimiento_empleado ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk(to_regprocedure('public.registrar_movimiento_empleado(bigint,jsonb)') IS NULL
                  AND to_regprocedure('public.registrar_movimiento_empleado(bigint,jsonb,uuid)') IS NOT NULL,
                  '2 la firma: tiene que quedar sólo (bigint, jsonb, uuid)');
    IF to_regprocedure('public.registrar_movimiento_empleado(bigint,jsonb,uuid)') IS NOT NULL THEN
      v_fallas := v_fallas || pg_temp.chk(
        has_function_privilege('authenticated', 'public.registrar_movimiento_empleado(bigint,jsonb,uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.registrar_movimiento_empleado(bigint,jsonb,uuid)', 'EXECUTE'),
        '2 los grants: authenticated sí, anon no');
    END IF;
    e2 := pg_temp.alta('{}', 70000, false);
    PERFORM pg_temp.como(pg_temp.mov(e2, '{"tipo":"ajuste","monto":1000,"observacion":"ensayo t6"}'));
    v_k := gen_random_uuid();
    v_mov := pg_temp.como(pg_temp.mov(e2, '{"tipo":"pago","monto":1000}', v_k))::bigint;
    -- El reintento: con el saldo ya en 0, sin la clave chocaría con «más de lo que se le debe».
    v_mov2 := pg_temp.como(pg_temp.mov(e2, '{"tipo":"pago","monto":1000}', v_k))::bigint;
    v_fallas := v_fallas || pg_temp.chk(v_mov = v_mov2 AND pg_temp.saldo(e2) = 0
                  AND (SELECT count(*) FROM empleado_movimientos WHERE empleado_id = e2 AND tipo = 'pago') = 1,
                  format('2 el reintento con la misma clave: %s y %s, saldo %s', v_mov, v_mov2, pg_temp.saldo(e2)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(pg_temp.mov(e2, '{"tipo":"pago","monto":900}', v_k)) = '22023',
                  '2 la misma clave con otro monto tiene que dar 22023');
    v_fallas := v_fallas || pg_temp.falla('2 la misma clave con otro monto',
                  pg_temp.mov(e2, '{"tipo":"pago","monto":900}', v_k), 'ya se registró con el intento anterior');
    v_a2 := pg_temp.u('admin', v_s1);
    v_fallas := v_fallas || pg_temp.falla('2 la clave de otro admin',
                  pg_temp.mov(e2, '{"tipo":"pago","monto":1000}', v_k), 'Esta clave ya se usó para otra operación', v_a2);
    -- Sin clave (un PWA de antes), como siempre: dos llamadas, dos movimientos.
    PERFORM pg_temp.como(pg_temp.mov(e2, '{"tipo":"adelanto","monto":10}'));
    PERFORM pg_temp.como(pg_temp.mov(e2, '{"tipo":"adelanto","monto":10}'));
    v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM empleado_movimientos WHERE empleado_id = e2 AND tipo = 'adelanto') = 2,
                  '2 sin clave, dos llamadas son dos movimientos');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- =========================================== 3 · Com-B3 la clave de liquidar_empleado ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk(to_regprocedure('public.liquidar_empleado(bigint,jsonb)') IS NULL
                  AND to_regprocedure('public.liquidar_empleado(bigint,jsonb,uuid)') IS NOT NULL,
                  '3 la firma: tiene que quedar sólo (bigint, jsonb, uuid)');
    IF to_regprocedure('public.liquidar_empleado(bigint,jsonb,uuid)') IS NOT NULL THEN
      v_fallas := v_fallas || pg_temp.chk(
        has_function_privilege('authenticated', 'public.liquidar_empleado(bigint,jsonb,uuid)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.liquidar_empleado(bigint,jsonb,uuid)', 'EXECUTE'),
        '3 los grants: authenticated sí, anon no');
    END IF;
    e3 := pg_temp.alta('{}', 70000, false);
    v_j := pg_temp.lqj(e3, 70000);
    v_k := gen_random_uuid();
    v_liq := pg_temp.como(pg_temp.lqs(e3, v_j, v_k))::bigint;
    v_liq2 := pg_temp.como(pg_temp.lqs(e3, v_j, v_k))::bigint;
    v_fallas := v_fallas || pg_temp.chk(v_liq = v_liq2 AND (SELECT count(*) FROM empleado_liquidaciones WHERE empleado_id = e3) = 1
                  AND pg_temp.saldo(e3) = 0,
                  format('3 el reintento con la misma clave: %s y %s', v_liq, v_liq2));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(pg_temp.lqs(e3, v_j || '{"pago":60000}', v_k)) = '22023',
                  '3 la misma clave con otro JSON tiene que dar 22023');
    v_fallas := v_fallas || pg_temp.falla('3 sin clave el reintento', pg_temp.lqs(e3, v_j),
                  'Ese período ya no es el próximo a liquidar');
    v_fallas := v_fallas || pg_temp.falla('3 la clave de un movimiento no sirve para liquidar',
                  pg_temp.lqs(e3, v_j, (SELECT clave FROM altas_por_clave WHERE operacion = 'movimiento_empleado' LIMIT 1)),
                  'Esta clave ya se usó para otra operación');
    PERFORM pg_temp.como(pg_temp.an(v_liq));
    v_fallas := v_fallas || pg_temp.falla('3 el reintento de una liquidación que se anuló', pg_temp.lqs(e3, v_j, v_k),
                  'y después se anuló');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ============================ 4 · Com-B4 el de baja con sólo un ajuste negativo pendiente ===
  BEGIN
    v_p4 := pg_temp.u('preventista', v_s1);
    e4 := pg_temp.alta(jsonb_build_object('usuario_id', v_p4), 0, true);
    v_ped := pg_temp.pedido(v_p4, v_l + 2, 100000);
    v_liq := pg_temp.lq(e4, 2000);
    v_fallas := v_fallas || pg_temp.chk((SELECT desde FROM empleado_liquidaciones WHERE id = v_liq) = v_l
                  AND (SELECT monto FROM empleado_liquidacion_conceptos WHERE liquidacion_id = v_liq AND concepto = 'comision') = 2000,
                  '4 el armado: la comisión de S1 no es $ 2.000');
    PERFORM pg_temp.como(format('SELECT public.dar_de_baja_empleado(p_empleado_id => %s, p_fecha => %L::date)', e4, v_l + 6));
    -- Se cancela el pedido ya liquidado: queda un ajuste de -$ 2.000.
    UPDATE pedidos SET estado = 'cancelado', motivo_cancelacion = 'Ensayo t6', total = 0 WHERE id = v_ped;
    v_j := pg_temp.pv(e4);
    v_x := pg_temp.como(format('SELECT public.obtener_cuenta_empleado(p_empleado_id => %s)', e4))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{ajustes,total}')::numeric = -2000 AND (v_j#>>'{comisiones,total}')::numeric = 0,
                  format('4 el armado: la vista previa no trae el ajuste de -$ 2.000 (%s)', v_j->'ajustes'));
    v_fallas := v_fallas || pg_temp.chk(v_x#>'{empleado,periodo}' IS NOT NULL AND jsonb_typeof(v_x#>'{empleado,periodo}') = 'object'
                  AND v_x#>>'{empleado,periodo,desde}' = v_j#>>'{periodo,desde}'
                  AND v_x#>>'{empleado,periodo,hasta}' = v_j#>>'{periodo,hasta}',
                  format('4 «para liquidar»: el empleado trae período %s y la vista previa %s', v_x#>'{empleado,periodo}', v_j->'periodo'));
    v_n := (SELECT count(*) FROM jsonb_array_elements(pg_temp.como('SELECT public.listar_personal()')::jsonb) x
             WHERE (x->>'id')::bigint = e4 AND jsonb_typeof(x->'periodo') = 'object');
    v_fallas := v_fallas || pg_temp.chk(v_n = 1, '4 la lista del personal no lo muestra para liquidar');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ===================================== 5 · Com-B5 la ficha de cliente de la cuenta propia ===
  BEGIN
    v_ax := pg_temp.u('admin', v_s1);
    e5 := pg_temp.alta(jsonb_build_object('usuario_id', v_ax, 'cliente_id', v_c1), 70000, false);
    v_fallas := v_fallas || pg_temp.falla('5 el admin se saca su ficha de cliente', pg_temp.edicion(e5, '{"cliente_id":null}'),
                  'no podés cambiar tu ficha de cliente', v_ax);
    v_fallas := v_fallas || pg_temp.falla('5 el admin se cambia su ficha de cliente',
                  pg_temp.edicion(e5, jsonb_build_object('cliente_id', v_c2)), 'no podés cambiar tu ficha de cliente', v_ax);
    v_fallas := v_fallas || pg_temp.chk((SELECT cliente_id FROM empleados WHERE id = e5) = v_c1, '5 la ficha de cliente cambió');
    v_fallas := v_fallas || pg_temp.anda('5 el admin edita lo demás de su ficha', pg_temp.edicion(e5, '{"telefono":"381 555 0000"}'), v_ax);
    v_fallas := v_fallas || pg_temp.anda('5 otro admin le cambia la ficha de cliente',
                  pg_temp.edicion(e5, jsonb_build_object('cliente_id', v_c2)));
    v_fallas := v_fallas || pg_temp.chk((SELECT cliente_id FROM empleados WHERE id = e5) = v_c2, '5 otro admin no se la pudo cambiar');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- ========================== 6 · m2 «Revertir» con la regla de la rendición del server ===
  BEGIN
    v_t6 := pg_temp.u('transportista', v_s1);
    v_t6b := pg_temp.u('transportista', v_s1);
    PERFORM pg_temp.cobro(v_t6, v_hoy - 2, 20000);
    PERFORM pg_temp.cobro(v_t6b, v_hoy - 2, 20000);
    e6 := pg_temp.alta('{}', 70000, false);
    PERFORM pg_temp.como(pg_temp.mov(e6, '{"tipo":"ajuste","monto":10000,"observacion":"ensayo t6"}'));
    v_mov := pg_temp.como(pg_temp.mov(e6, '{"tipo":"pago","monto":3000}'::jsonb || pg_temp.plata(v_t6, v_hoy - 2)))::bigint;
    v_mov2 := pg_temp.como(pg_temp.mov(e6, '{"tipo":"pago","monto":2000}'::jsonb || pg_temp.plata(v_t6b, v_hoy - 2)))::bigint;
    INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_por)
    VALUES (v_hoy - 2, v_t6, v_s1, 'confirmada', v_ua);
    v_x := pg_temp.como(format('SELECT public.obtener_cuenta_empleado(p_empleado_id => %s)', e6))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT x#>>'{rendicion,cerrada}' FROM jsonb_array_elements(v_x->'movimientos') x WHERE (x->>'id')::bigint = v_mov) = 'true'
      AND (SELECT x#>>'{rendicion,cerrada}' FROM jsonb_array_elements(v_x->'movimientos') x WHERE (x->>'id')::bigint = v_mov2) = 'false',
      format('6 la cuenta no dice qué rendición está cerrada: %s',
             (SELECT jsonb_agg(x->'rendicion') FROM jsonb_array_elements(v_x->'movimientos') x WHERE x->>'tipo' = 'pago')));
    v_fallas := v_fallas || pg_temp.falla('6 revertir el de la cerrada', pg_temp.rev(v_mov), 'salió de una rendición ya cerrada');
    v_fallas := v_fallas || pg_temp.anda('6 revertir el de la abierta', pg_temp.rev(v_mov2));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- ========================== 7 · m3 anular después de pasarle el usuario a otro empleado ===
  BEGIN
    v_p7 := pg_temp.u('preventista', v_s1);
    e7 := pg_temp.alta(jsonb_build_object('usuario_id', v_p7), 0, true);
    v_ped := pg_temp.pedido(v_p7, v_l + 2, 100000);
    v_liq := pg_temp.lq(e7, 2000);
    -- El usuario pasa a otra ficha, que no comisiona.
    PERFORM pg_temp.como(pg_temp.edicion(e7, '{"usuario_id":null}'));
    e7b := pg_temp.alta(jsonb_build_object('usuario_id', v_p7), 70000, false);
    v_fallas := v_fallas || pg_temp.falla('7 anular con el usuario en otra ficha', pg_temp.an(v_liq),
                  'el usuario con el que se calcularon sus comisiones ya no es el de este empleado');
    -- Y si se anula de verdad (pg_temp.falla deshace lo que anduvo): el pedido tiene que seguir con
    -- dueño, su línea liquidada vigente o pendiente de alguien.
    PERFORM pg_temp.estado(pg_temp.an(v_liq));
    v_fallas := v_fallas || pg_temp.chk(
      EXISTS (SELECT 1 FROM empleado_liquidacion_lineas WHERE pedido_id = v_ped AND vigente)
      OR EXISTS (SELECT 1 FROM empleados e, public._liquidacion_lineas(e, v_hoy) l WHERE e.id IN (e7, e7b) AND l.pedido_id = v_ped),
      '7 el pedido quedó sin dueño: ni liquidado ni pendiente de nadie');
    -- Sin comisiones liquidadas, el usuario vinculado después no traba la anulación.
    e7c := pg_temp.alta('{}', 70000, false);
    v_liq2 := pg_temp.lq(e7c, 0);
    PERFORM pg_temp.como(pg_temp.edicion(e7c, jsonb_build_object('usuario_id', pg_temp.u('preventista', v_s1))));
    v_fallas := v_fallas || pg_temp.anda('7 anular la de un empleado sin comisiones liquidadas', pg_temp.an(v_liq2));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- ===== 7b · m3 con usuarios mezclados: la inicial del usuario nuevo y el ajuste del viejo
  -- E liquida S1 con U1 (P de $ 100.000: $ 2.000). Pasa a U2, que vende $ 50.000 en S2, y P baja a
  -- $ 50.000: L2 queda con inicial:U2 (+1.000) y ajuste:U1 (-1.000). El ajuste vuelve a la ficha
  -- por empleado_id: L2 se anula con U2 vinculado, y no con U1 (la inicial de U2 quedaría sin dueño).
  BEGIN
    v_q1 := pg_temp.u('preventista', v_s1);
    v_q2 := pg_temp.u('preventista', v_s1);
    e7d := pg_temp.alta(jsonb_build_object('usuario_id', v_q1), 0, true);
    v_ped := pg_temp.pedido(v_q1, v_l + 2, 100000);
    PERFORM pg_temp.lq(e7d, 2000);
    PERFORM pg_temp.como(pg_temp.edicion(e7d, jsonb_build_object('usuario_id', v_q2)));
    PERFORM pg_temp.pedido(v_q2, v_l + 8, 50000);
    UPDATE pedido_items SET cantidad = 500, subtotal = 50000 WHERE pedido_id = v_ped;
    UPDATE pedidos SET total = 50000 WHERE id = v_ped;
    v_liq2 := pg_temp.lq(e7d, 0);
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT string_agg(tipo || ':' || CASE WHEN usuario_id = v_q1 THEN 'U1' WHEN usuario_id = v_q2 THEN 'U2' ELSE '?' END
                         || ':' || round(comision, 2), ',' ORDER BY tipo)
         FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq2) = 'ajuste:U1:-1000.00,inicial:U2:1000.00',
      '7b el armado: L2 no quedó con inicial:U2 y ajuste:U1');
    PERFORM pg_temp.como(pg_temp.edicion(e7d, jsonb_build_object('usuario_id', v_q1)));
    v_fallas := v_fallas || pg_temp.falla('7b anular con U1 de vuelta (la inicial de U2 sin dueño)', pg_temp.an(v_liq2),
                  'ya no es el de este empleado');
    PERFORM pg_temp.como(pg_temp.edicion(e7d, jsonb_build_object('usuario_id', v_q2)));
    v_fallas := v_fallas || pg_temp.anda('7b anular con U2 vinculado', pg_temp.an(v_liq2));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7b · error: %s', SQLERRM);
  END;

  -- ===== 7c · m3 con sólo el ajuste del usuario viejo: se anula, y el ajuste vuelve a la ficha
  BEGIN
    v_q1 := pg_temp.u('preventista', v_s1);
    v_q2 := pg_temp.u('preventista', v_s1);
    e7d := pg_temp.alta(jsonb_build_object('usuario_id', v_q1), 0, true);
    v_ped := pg_temp.pedido(v_q1, v_l + 2, 100000);
    PERFORM pg_temp.lq(e7d, 2000);
    PERFORM pg_temp.como(pg_temp.edicion(e7d, jsonb_build_object('usuario_id', v_q2)));
    UPDATE pedido_items SET cantidad = 500, subtotal = 50000 WHERE pedido_id = v_ped;
    UPDATE pedidos SET total = 50000 WHERE id = v_ped;
    v_liq2 := pg_temp.lq(e7d, 0);
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT string_agg(tipo || ':' || round(comision, 2), ',') FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq2)
        = 'ajuste:-1000.00', '7c el armado: L2 no quedó con sólo el ajuste de -$ 1.000');
    v_fallas := v_fallas || pg_temp.anda('7c anular con sólo el ajuste del usuario viejo', pg_temp.an(v_liq2));
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT string_agg(l.tipo || ':' || round(l.comision, 2), ',') FROM empleados e, public._liquidacion_lineas(e, v_hoy) l
        WHERE e.id = e7d) = 'ajuste:-1000.00', '7c el ajuste no volvió a la ficha');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7c · error: %s', SQLERRM);
  END;

  -- ============================= 8 · m4 lo pendiente no se arrastra de una sucursal a otra ===
  BEGIN
    v_p8 := pg_temp.u('preventista', v_s1);
    -- El usuario también es de la otra sucursal, así el cambio de la ficha pasaría sus vínculos.
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default)
    SELECT v_p8, s.id, false FROM sucursales s WHERE s.activa AND s.id <> v_s1 ORDER BY s.id LIMIT 1;
    e8 := pg_temp.alta(jsonb_build_object('usuario_id', v_p8), 0, true);
    PERFORM pg_temp.pedido(v_p8, v_l + 2, 100000);
    v_fallas := v_fallas || pg_temp.chk(to_regprocedure('public.comision_sin_liquidar_empleado(bigint)') IS NOT NULL,
                  '8 no existe comision_sin_liquidar_empleado (la pantalla no puede avisar antes)');
    IF to_regprocedure('public.comision_sin_liquidar_empleado(bigint)') IS NOT NULL THEN
      v_x := pg_temp.como(format('SELECT public.comision_sin_liquidar_empleado(p_empleado_id => %s)', e8))::jsonb;
      v_fallas := v_fallas || pg_temp.chk((v_x->>'monto')::numeric = 2000
                    AND v_x->>'aviso' = format('Tiene $ 2.000,00 de comisión sin liquidar en %s: liquidalo antes de pasarlo de sucursal',
                                               (SELECT nombre FROM sucursales WHERE id = v_s1)),
                    format('8 la pantalla ve %s y no $ 2.000 con el motivo del server', v_x));
      v_fallas := v_fallas || pg_temp.chk(
        has_function_privilege('authenticated', 'public.comision_sin_liquidar_empleado(bigint)', 'EXECUTE')
        AND NOT has_function_privilege('anon', 'public.comision_sin_liquidar_empleado(bigint)', 'EXECUTE')
        AND NOT has_function_privilege('authenticated', 'public._empleado_comision_sin_liquidar(public.empleados)', 'EXECUTE'),
        '8 los grants de la comisión sin liquidar');
      v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(format('SELECT public.comision_sin_liquidar_empleado(p_empleado_id => %s)', e8), v_p8) = '42501',
                    '8 un preventista no lee la comisión sin liquidar de una ficha');
    END IF;
    v_fallas := v_fallas || pg_temp.falla('8 pasarlo a la otra sucursal',
                  pg_temp.edicion(e8, jsonb_build_object('sucursal_id', (SELECT min(id) FROM sucursales WHERE activa AND id <> v_s1))),
                  format('Tiene $ 2.000,00 de comisión sin liquidar en %s: liquidalo antes de pasarlo de sucursal',
                         (SELECT nombre FROM sucursales WHERE id = v_s1)));
    v_fallas := v_fallas || pg_temp.falla('8 pasarlo a las dos', pg_temp.edicion(e8, '{"de_las_dos":true}'),
                  'Tiene $ 2.000,00 de comisión sin liquidar en');
    v_fallas := v_fallas || pg_temp.chk((SELECT sucursal_id = v_s1 AND NOT de_las_dos FROM empleados WHERE id = e8),
                  '8 la ficha se movió con la comisión sin liquidar');
    v_fallas := v_fallas || pg_temp.anda('8 editar sin moverlo', pg_temp.edicion(e8, '{"telefono":"381 555 0001"}'));
    PERFORM pg_temp.lq(e8, 2000);
    v_x := pg_temp.como(format('SELECT public.comision_sin_liquidar_empleado(p_empleado_id => %s)', e8))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_x->>'monto')::numeric = 0 AND v_x->'aviso' = 'null'::jsonb,
                  format('8 liquidado la pantalla ve %s', v_x));
    v_fallas := v_fallas || pg_temp.anda('8 liquidado, se pasa',
                  pg_temp.edicion(e8, jsonb_build_object('sucursal_id', (SELECT min(id) FROM sucursales WHERE activa AND id <> v_s1))));
    v_fallas := v_fallas || pg_temp.chk((SELECT sucursal_id <> v_s1 FROM empleados WHERE id = e8), '8 liquidado no se movió');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ===== 8b · m4 con el período en curso ya liquidado: el motivo dice desde cuándo se puede liquidar
  BEGIN
    v_p8 := pg_temp.u('preventista', v_s1);
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default)
    SELECT v_p8, s.id, false FROM sucursales s WHERE s.activa AND s.id <> v_s1 ORDER BY s.id LIMIT 1;
    -- El arreglo arranca este lunes: el período en curso se liquida hoy, sin nada.
    e8 := pg_temp.alta(jsonb_build_object('usuario_id', v_p8, 'arreglo', jsonb_build_object(
            'vigente_desde', v_l + 14, 'sueldo', 0, 'frecuencia', 'semanal', 'comisiona', true)), 0, true);
    v_liq := pg_temp.lq(e8, 0);
    -- Hoy se entrega una venta de $ 100.000: $ 2.000 que entran en la semana que viene.
    PERFORM pg_temp.pedido(v_p8, v_hoy, 100000);
    v_fallas := v_fallas || pg_temp.chk((SELECT desde FROM empleado_liquidaciones WHERE id = v_liq) = v_l + 14,
                  '8b el armado: no se liquidó la semana en curso');
    v_fallas := v_fallas || pg_temp.falla('8b liquidar ya', pg_temp.lqs(e8, pg_temp.lqj(e8, 0)), 'El período todavía no empezó');
    v_fallas := v_fallas || pg_temp.falla('8b pasarlo a la otra sucursal',
                  pg_temp.edicion(e8, jsonb_build_object('sucursal_id', (SELECT min(id) FROM sucursales WHERE activa AND id <> v_s1))),
                  format('Tiene $ 2.000,00 de comisión sin liquidar en %s, de esta semana: se puede liquidar desde el lunes %s; pasalo de sucursal después',
                         (SELECT nombre FROM sucursales WHERE id = v_s1), to_char(v_l + 21, 'FMDD/FMMM')));
    v_x := pg_temp.como(format('SELECT public.comision_sin_liquidar_empleado(p_empleado_id => %s)', e8))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_x->>'aviso' LIKE '%se puede liquidar desde el lunes ' || to_char(v_l + 21, 'FMDD/FMMM') || '%',
                  format('8b la pantalla no dice desde cuándo: %s', v_x));
    v_fallas := v_fallas || pg_temp.falla('8b sacarle el usuario', pg_temp.edicion(e8, '{"usuario_id":null}'),
                  format('se puede liquidar desde el lunes %s; cambiale o sacale el usuario después', to_char(v_l + 21, 'FMDD/FMMM')));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8b · error: %s', SQLERRM);
  END;

  -- ===== 8c · m4 (decisión del dueño, 26/11) con comisión sin liquidar no se le cambia ni se le saca el usuario
  BEGIN
    v_p8 := pg_temp.u('preventista', v_s1);
    v_p8c := pg_temp.u('preventista', v_s1);
    e8 := pg_temp.alta(jsonb_build_object('usuario_id', v_p8), 0, true);
    PERFORM pg_temp.pedido(v_p8, v_l + 2, 100000);
    v_x := pg_temp.como(format('SELECT public.comision_sin_liquidar_empleado(p_empleado_id => %s)', e8))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_x->>'monto')::numeric = 2000
                  AND v_x->>'aviso_usuario' = format('Tiene $ 2.000,00 de comisión sin liquidar en %s: liquidalo antes de cambiarle o sacarle el usuario',
                                                     (SELECT nombre FROM sucursales WHERE id = v_s1)),
                  format('8c la pantalla ve %s y no el motivo del usuario', v_x));
    v_fallas := v_fallas || pg_temp.falla('8c sacarle el usuario', pg_temp.edicion(e8, '{"usuario_id":null}'),
                  format('Tiene $ 2.000,00 de comisión sin liquidar en %s: liquidalo antes de cambiarle o sacarle el usuario',
                         (SELECT nombre FROM sucursales WHERE id = v_s1)));
    v_fallas := v_fallas || pg_temp.falla('8c pasarle otro usuario', pg_temp.edicion(e8, jsonb_build_object('usuario_id', v_p8c)),
                  'liquidalo antes de cambiarle o sacarle el usuario');
    v_fallas := v_fallas || pg_temp.chk((SELECT usuario_id FROM empleados WHERE id = e8) = v_p8,
                  '8c la ficha cambió de usuario con la comisión sin liquidar');
    v_fallas := v_fallas || pg_temp.anda('8c editar sin tocar el usuario', pg_temp.edicion(e8, '{"telefono":"381 555 0002"}'));
    -- Vincularle usuario a una ficha que no tenía no se frena (aunque comisione).
    e8c := pg_temp.alta('{}', 0, true);
    v_fallas := v_fallas || pg_temp.anda('8c vincular usuario a una ficha sin usuario',
                  pg_temp.edicion(e8c, jsonb_build_object('usuario_id', v_p8c)));
    v_fallas := v_fallas || pg_temp.chk((SELECT usuario_id FROM empleados WHERE id = e8c) = v_p8c, '8c la ficha sin usuario no quedó vinculada');
    -- Liquidado (pendiente 0), se le cambia.
    PERFORM pg_temp.lq(e8, 2000);
    v_x := pg_temp.como(format('SELECT public.comision_sin_liquidar_empleado(p_empleado_id => %s)', e8))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_x->'aviso_usuario' = 'null'::jsonb, format('8c liquidado la pantalla ve %s', v_x));
    v_fallas := v_fallas || pg_temp.anda('8c liquidado, se le saca el usuario', pg_temp.edicion(e8, '{"usuario_id":null}'));
    v_fallas := v_fallas || pg_temp.chk((SELECT usuario_id FROM empleados WHERE id = e8) IS NULL, '8c liquidado no se le sacó el usuario');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8c · error: %s', SQLERRM);
  END;

  -- ===================================== 9 · m5 la liquidación sin movimientos adelanta el corte ===
  BEGIN
    e9 := pg_temp.alta('{}', 0, true);
    PERFORM pg_temp.como(pg_temp.mov(e9, '{"tipo":"ajuste","monto":1000,"observacion":"ensayo t6"}'));
    v_j := pg_temp.pv(e9);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'a_pagar')::numeric = 1000 AND jsonb_array_length(v_j->'movimientos') = 1,
                  format('9 el armado: la vista previa de S1 no trae el ajuste (%s)', v_j));
    -- Sueldo 0, sin comisión y sin pago: la liquidación no escribe ningún movimiento.
    v_liq := pg_temp.lq(e9, 0);
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE liquidacion_id = v_liq),
                  '9 el armado: la liquidación escribió movimientos');
    v_j := pg_temp.pv(e9);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_l + 7 AND jsonb_array_length(v_j->'movimientos') = 0
                  AND (v_j->>'saldo_anterior')::numeric = 1000 AND (v_j->>'a_pagar')::numeric = 1000,
                  format('9 la vista previa de S2 repite lo ya liquidado: movimientos %s, saldo anterior %s',
                         v_j->'movimientos', v_j->'saldo_anterior'));
    PERFORM pg_temp.como(pg_temp.mov(e9, '{"tipo":"ajuste","monto":500,"observacion":"ensayo t6"}'));
    v_j := pg_temp.pv(e9);
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j->'movimientos') = 1 AND (v_j#>>'{movimientos,0,monto}')::numeric = 500
                  AND (v_j->>'saldo_anterior')::numeric = 1000 AND (v_j->>'a_pagar')::numeric = 1500,
                  format('9 lo nuevo después del corte: movimientos %s, saldo anterior %s', v_j->'movimientos', v_j->'saldo_anterior'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ============================================================== 10 · auditoría ===
  BEGIN
    v_ch_fin := (pg_temp.audit()->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin <= v_ch_ini,
                  format('10 auditoria_integridad: critical/high en rojo pasó de %s a %s', v_ch_ini, v_ch_fin));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · t6 personal y liquidaciones: 1 a 10, con 7b, 7c, 8b y 8c';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
END
$ensayo$;
