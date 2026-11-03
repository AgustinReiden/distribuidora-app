-- Ensayo de la migracion gastos_5_liquidaciones (entrega 4 de 5 de gastos:
-- liquidaciones y comisiones congeladas).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe se deshace.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR; despues, pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/437_gastos_5_liquidaciones.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Las RPCs se llaman COMO EL FRONT (pg_temp.como). Los pedidos, sus cambios
-- (salvedad, edicion, cancelacion, volver a pendiente) y el cierre de una
-- rendicion se arman como postgres sobre las tablas: lo que importa es lo que
-- ve la comision. actualizar_preventista_pedido es la real.
--
-- a1, at y ad son admins reales (Tucuman, Taco Pozo y las dos). Los vendedores,
-- el encargado y los choferes los crea el ensayo en auth.users, sin ventas
-- reales que se mezclen. L es el lunes de hace cuatro semanas.
--
--   1  una sola comision        11 anular
--   2  periodos                 12 guardas
--   3  sueldo                   13 uno mismo
--   4  baja                     14 mostrar de mas
--   5  reactivar                15 pago suelto
--   6  que entra                16 personal_por_mes
--   7  congelar                 17 rendicion
--   8  ajustes (a a i)          18 permisos
--   9  pago                     19 invariantes LIQ-A, B y C
--   10 orden y en curso

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_hoy    date := public._tablero_hoy();
  v_lunes  date := date_trunc('week', public._tablero_hoy()::timestamp)::date;
  v_l      date := date_trunc('week', public._tablero_hoy()::timestamp)::date - 28;
  v_t      bigint := 1;
  v_tp     bigint := 2;
  v_a1     uuid;
  v_at     uuid;
  v_ad     uuid;
  v_en     uuid;
  v_tr     uuid;
  v_tr2    uuid;
  v_tr3    uuid;
  v_u      uuid;
  v_u2     uuid;
  c1       bigint;
  c2       bigint;
  c_ad     bigint;
  v_p2     bigint;
  v_combo  bigint;
  v_regla  bigint;
  e        bigint;
  e2       bigint;
  v_ped    bigint;
  v_ped2   bigint;
  v_ped3   bigint;
  v_ped4   bigint;
  v_liq    bigint;
  v_liq2   bigint;
  v_mov    bigint;
  v_d      date;
  v_j      jsonb;
  v_k      jsonb;
  v_txt    text;
  v_n      bigint;
  v_m      numeric;
  v_lc     numeric := 0;
  v_ch_ini int;
  v_ch_fin int;
  g        record;
  h        record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regprocedure('public.liquidar_empleado(bigint,jsonb)') IS NULL OR to_regclass('public.empleado_liquidaciones') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existen liquidar_empleado ni empleado_liquidaciones (falta la migracion gastos_5)';
  END IF;

  -- --------------------------------------------------------- contexto ---
  SELECT pf.id INTO v_a1 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_t]
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_at FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_tp]
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_ad FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_t, v_tp]
   ORDER BY pf.id LIMIT 1;
  IF v_a1 IS NULL OR v_at IS NULL OR v_ad IS NULL
     OR (SELECT pct_preventista FROM comision_pct_vigencias WHERE sucursal_id = v_t AND vigente_desde <= v_l
          ORDER BY vigente_desde DESC LIMIT 1) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: a1 %, at %, ad %, o el %% no es 2', v_a1, v_at, v_ad;
  END IF;
  -- Desde el 02/11 todos los admins de Tucuman tienen ficha, y el caso 13 le
  -- crea una a a1 (usuario_id es UNIQUE): la suya queda sin usuario en el ensayo.
  UPDATE empleados SET usuario_id = NULL WHERE usuario_id = v_a1;

  CREATE FUNCTION pg_temp.como(p_user uuid, p_suc bigint, p_sql text)
  RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  END
  $f$;

  CREATE FUNCTION pg_temp.falla(p_que text, p_user uuid, p_suc bigint, p_sql text, p_espera text)
  RETURNS text[] LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_user, p_suc, p_sql);
    EXCEPTION WHEN SQLSTATE 'P0098' THEN RAISE;
      WHEN OTHERS THEN
        IF position(p_espera IN SQLERRM) > 0 THEN
          RETURN '{}';
        END IF;
        RETURN ARRAY[format('%s: fallo con otro mensaje: %s (esperado: %s)', p_que, SQLERRM, p_espera)];
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RETURN ARRAY[format('%s: anduvo y tenia que fallar', p_que)];
  END
  $f$;

  CREATE FUNCTION pg_temp.estado(p_user uuid, p_suc bigint, p_sql text)
  RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      PERFORM pg_temp.como(p_user, p_suc, p_sql);
    EXCEPTION WHEN OTHERS THEN
      RETURN SQLSTATE;
    END;
    RAISE EXCEPTION USING ERRCODE = 'P0098';
  EXCEPTION WHEN SQLSTATE 'P0098' THEN
    RETURN 'OK';
  END
  $f$;

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text)
  RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  -- Lo que corre como postgres, con los claims de a1: el historial del pedido
  -- los lee, y un chofer o el encargado no los tienen que dejar puestos.
  CREATE FUNCTION pg_temp.adm()
  RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', json_build_object('sub', current_setting('g5.a1'), 'role', 'authenticated')::text, true);
    SELECT set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
  $f$;

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint)
  RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE
    v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'g5-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), '{}', now(), now());
    RETURN v;
  END
  $f$;

  CREATE FUNCTION pg_temp.alta(p_adm uuid, p_suc bigint, p_usr uuid, p_desde date, p_comis boolean DEFAULT true,
                               p_frec text DEFAULT 'semanal', p_sueldo numeric DEFAULT 70000, p_dos boolean DEFAULT false)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_adm, p_suc, format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ g5 ' || gen_random_uuid(), 'puesto', 'preventista', 'sucursal_id', p_suc, 'de_las_dos', p_dos,
      'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', p_usr, 'cliente_id', NULL, 'vehiculo_id', NULL,
      'arreglo', jsonb_build_object('vigente_desde', p_desde, 'sueldo', p_sueldo, 'frecuencia', p_frec, 'comisiona', p_comis),
      'saldo_inicial', NULL)))::bigint;
  $f$;

  -- Un empleado de T con el arreglo de siempre, de a1.
  CREATE FUNCTION pg_temp.a(p_usr uuid, p_desde date, p_comis boolean DEFAULT true)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.alta(current_setting('g5.a1')::uuid, 1, p_usr, p_desde, p_comis);
  $f$;

  CREATE FUNCTION pg_temp.ar(p_d date, p_h time DEFAULT '12:00')
  RETURNS timestamptz LANGUAGE sql AS $f$
    SELECT (p_d + p_h) AT TIME ZONE 'America/Argentina/Buenos_Aires';
  $f$;

  -- Una linea mas en el pedido, y el total sigue a las lineas.
  CREATE FUNCTION pg_temp.li(p_ped bigint, p_prod bigint, p_monto numeric, p_combo bigint DEFAULT NULL)
  RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE
    v_suc bigint;
  BEGIN
    SELECT sucursal_id INTO v_suc FROM pedidos WHERE id = p_ped;
    INSERT INTO pedido_items (pedido_id, sucursal_id, producto_id, cantidad, precio_unitario, subtotal,
                              costo_unitario_al_crear, combo_id, precio_sin_combo_unitario, origen_precio)
    VALUES (p_ped, v_suc, p_prod, (p_monto / 100)::int, 100, p_monto, 60, p_combo,
            CASE WHEN p_combo IS NOT NULL THEN 110 END, CASE WHEN p_combo IS NOT NULL THEN 'combo' END);
    UPDATE pedidos SET total = total + p_monto WHERE id = p_ped;
  END
  $f$;

  -- Un pedido de p_monto, de p_dia, entregado ese dia al mediodia.
  CREATE FUNCTION pg_temp.ped(p_usr uuid, p_dia date, p_monto numeric DEFAULT 100000, p_cli bigint DEFAULT NULL, p_entrega timestamptz DEFAULT NULL)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_cli bigint := COALESCE(p_cli, current_setting('g5.c1')::bigint);
    v_suc bigint;
    v_id  bigint;
  BEGIN
    PERFORM pg_temp.adm();
    SELECT sucursal_id INTO v_suc FROM clientes WHERE id = v_cli;
    INSERT INTO pedidos (cliente_id, sucursal_id, fecha, total, usuario_id, creado_por)
    VALUES (v_cli, v_suc, p_dia, 0, p_usr, p_usr) RETURNING id INTO v_id;
    PERFORM pg_temp.li(v_id, current_setting('g5.p' || v_suc)::bigint, p_monto);
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = COALESCE(p_entrega, pg_temp.ar(p_dia))
     WHERE id = v_id;
    RETURN v_id;
  END
  $f$;

  CREATE FUNCTION pg_temp.pvc(p_user uuid, p_suc bigint, p_emp bigint)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', p_emp))::jsonb;
  $f$;

  CREATE FUNCTION pg_temp.pv(p_emp bigint)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.pvc(current_setting('g5.a1')::uuid, 1, p_emp);
  $f$;

  -- LiquidarPayload armado de la vista previa, como ModalLiquidar.
  CREATE FUNCTION pg_temp.pay(v jsonb, x jsonb DEFAULT '{}')
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object(
      'desde', v#>>'{periodo,desde}', 'hasta', v#>>'{periodo,hasta}', 'sueldo', (v#>>'{sueldo,propuesto}')::numeric,
      'motivo_sueldo', NULL, 'pago', 0, 'fecha_pago', public._tablero_hoy(),
      'a_pagar_esperado', (v->>'a_pagar')::numeric - (v#>>'{sueldo,propuesto}')::numeric
                          + COALESCE((x->>'sueldo')::numeric, (v#>>'{sueldo,propuesto}')::numeric),
      'origen_pago', 'oficina', 'rendicion_transportista_id', NULL, 'rendicion_fecha', NULL) || x;
  $f$;

  CREATE FUNCTION pg_temp.liq(p_emp bigint, p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.liquidar_empleado(p_empleado_id => %s, p_liquidacion => %L::jsonb)', p_emp, p);
  $f$;

  CREATE FUNCTION pg_temp.lqc(p_user uuid, p_suc bigint, p_emp bigint, x jsonb DEFAULT '{}')
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, pg_temp.liq(p_emp, pg_temp.pay(pg_temp.pvc(p_user, p_suc, p_emp), x)))::bigint;
  $f$;

  CREATE FUNCTION pg_temp.lq(p_emp bigint, x jsonb DEFAULT '{}')
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.lqc(current_setting('g5.a1')::uuid, 1, p_emp, x);
  $f$;

  CREATE FUNCTION pg_temp.an(p_liq bigint, p_mot text DEFAULT 'Ensayo')
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.anular_liquidacion(p_liquidacion_id => %s, p_motivo => %L)', p_liq, p_mot);
  $f$;

  CREATE FUNCTION pg_temp.ob(p_liq bigint)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.obtener_liquidacion(p_liquidacion_id => %s)', p_liq);
  $f$;

  CREATE FUNCTION pg_temp.mov(p_emp bigint, p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_movimiento_empleado(p_empleado_id => %s, p_movimiento => %L::jsonb)', p_emp, p);
  $f$;

  CREATE FUNCTION pg_temp.rev(p_mov bigint, p_motivo text DEFAULT 'Ensayo')
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.revertir_movimiento_empleado(p_movimiento_id => %s, p_motivo => %L)', p_mov, p_motivo);
  $f$;

  CREATE FUNCTION pg_temp.arr(p_emp bigint, p_desde date, p_sueldo numeric DEFAULT 84000, p_comis boolean DEFAULT false)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_arreglo_empleado(p_empleado_id => %s, p_arreglo => %L::jsonb)', p_emp,
                  jsonb_build_object('vigente_desde', p_desde, 'sueldo', p_sueldo, 'frecuencia', 'semanal', 'comisiona', p_comis));
  $f$;

  CREATE FUNCTION pg_temp.baja(p_emp bigint, p_d date)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.dar_de_baja_empleado(p_empleado_id => %s, p_fecha => %L::date)', p_emp, p_d);
  $f$;

  CREATE FUNCTION pg_temp.saldo(p_emp bigint)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos WHERE empleado_id = p_emp;
  $f$;

  CREATE FUNCTION pg_temp.tiene(p jsonb, p_ped bigint)
  RETURNS boolean LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p) x WHERE (x->>'pedido_id')::bigint = p_ped);
  $f$;

  CREATE FUNCTION pg_temp.tiene_mov(p_v jsonb, p_tipo text)
  RETURNS boolean LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_v->'movimientos') x WHERE x->>'tipo' = p_tipo);
  $f$;

  -- Empleado de T desde L con un pedido de 100000 entregado en L+1, ya liquidado.
  CREATE FUNCTION pg_temp.arm(p_l date, OUT e bigint, OUT u uuid, OUT p bigint, OUT lq bigint)
  LANGUAGE plpgsql AS $f$
  BEGIN
    u := pg_temp.u('preventista', 1);
    e := pg_temp.a(u, p_l);
    p := pg_temp.ped(u, p_l + 1);
    lq := pg_temp.lq(e);
    PERFORM pg_temp.adm();
  END
  $f$;

  CREATE FUNCTION pg_temp.res(p_user uuid, p_suc bigint, p_d date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(r)), ''[]'') FROM public.obtener_resumen_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, p_transportista_id => %s) r',
      p_d, p_d, COALESCE(quote_literal(p_t::text) || '::uuid', 'NULL')))::jsonb;
  $f$;

  CREATE FUNCTION pg_temp.tpp(p_suc bigint, p_d date, p_t uuid)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum((x->>'total_pagos_personal')::numeric), 0)
      FROM jsonb_array_elements(pg_temp.res(CASE p_suc WHEN 1 THEN current_setting('g5.a1')::uuid ELSE current_setting('g5.ad')::uuid END,
                                            p_suc, p_d, p_t)) x;
  $f$;

  CREATE FUNCTION pg_temp.cr(p_fecha date, p_t uuid, p_gastos jsonb, p_estado text DEFAULT 'confirmada')
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, '
                  || 'p_estado => %L, p_observaciones => NULL, p_gastos_rendicion => %L::jsonb)', p_fecha, p_t, p_estado, p_gastos);
  $f$;

  CREATE FUNCTION pg_temp.plata(p_t uuid, p_d date)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('origen_pago', 'rendicion', 'rendicion_transportista_id', p_t, 'rendicion_fecha', p_d);
  $f$;

  CREATE FUNCTION pg_temp.audit(p_adm uuid, p_suc bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    RETURN public.auditoria_integridad();
  END
  $f$;

  IF cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'otro mensaje')) <> 1
     OR pg_temp.estado(v_a1, v_t, 'SELECT 1/0') <> '22012'
     OR pg_temp.estado(v_a1, v_t, 'SELECT 1') <> 'OK'
     OR pg_temp.como(v_a1, v_t, 'SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_a1, v_t)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  v_ch_ini := (pg_temp.audit(v_a1, v_t)->>'critical_high_en_rojo')::int;

  PERFORM set_config('g5.a1', v_a1::text, true);
  PERFORM set_config('g5.ad', v_ad::text, true);
  PERFORM pg_temp.adm();
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ g5 C1', 'ZZ g5 C1', 'Ensayo', v_t) RETURNING id INTO c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ g5 C2', 'ZZ g5 C2', 'Ensayo', v_tp) RETURNING id INTO c2;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ g5 ficha', 'ZZ g5 ficha', 'Ensayo', v_t) RETURNING id INTO c_ad;
  PERFORM set_config('g5.c1', c1::text, true);
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ g5 A', 100, 100000, 60, v_t) RETURNING id INTO v_n;
  PERFORM set_config('g5.p1', v_n::text, true);
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ g5 B', 100, 100000, 60, v_t) RETURNING id INTO v_p2;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ g5 TP', 100, 100000, 60, v_tp) RETURNING id INTO v_n;
  PERFORM set_config('g5.p2', v_n::text, true);
  INSERT INTO combos (sucursal_id, nombre, fecha_inicio, precio) VALUES (v_t, 'ZZ g5', v_l, 100) RETURNING id INTO v_combo;
  -- La ficha de un empleado sin usuario: los pagos con adelanto caen ahi.
  e := pg_temp.a(NULL, v_l, false);
  UPDATE empleados SET cliente_id = c_ad WHERE id = e;

  v_en := pg_temp.u('encargado', v_t);
  v_tr := pg_temp.u('transportista', v_t);
  v_tr2 := pg_temp.u('transportista', v_tp);
  v_tr3 := pg_temp.u('transportista', v_t);

  -- ================================================ 1 · una sola comision ===
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, format(
      'SELECT public.calcular_comisiones(p_desde => %L::date, p_hasta => %L::date, p_sucursal_ids => ARRAY[%s]::bigint[])',
      '2026-10-01', '2026-10-31', v_t))::jsonb;
    SELECT count(*) INTO v_n
      FROM (SELECT l.usuario_id, round(sum(l.base), 2) AS b, round(sum(l.base * l.pct / 100.0), 2) AS c
              FROM public._comision_lineas(ARRAY(SELECT id FROM pedidos WHERE fecha BETWEEN '2026-10-01' AND '2026-10-31'
                                                                          AND sucursal_id = v_t)) l
             GROUP BY l.usuario_id) x
      FULL JOIN jsonb_to_recordset(v_j->'preventistas') AS r(id uuid, base numeric, comision numeric) ON r.id = x.usuario_id
     WHERE x.b IS DISTINCT FROM r.base OR x.c IS DISTINCT FROM r.comision;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0 AND jsonb_array_length(v_j->'preventistas') > 0,
                  format('1 _comision_lineas no da lo de calcular_comisiones en %s vendedores', v_n));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  -- ========================================================= 2 · periodos ===
  BEGIN
    e := pg_temp.a(NULL, v_l, false);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_l AND (v_j#>>'{periodo,hasta}')::date = v_l + 6
                                        AND (v_j#>>'{periodo,mas_vencidos}')::int = 3 AND (v_j->>'puede_liquidar')::boolean
                                        AND NOT (v_j->>'en_curso')::boolean, format('2 E1: %s', v_j->'periodo'));
    PERFORM pg_temp.lq(e);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_l + 7 AND (v_j#>>'{periodo,hasta}')::date = v_l + 13
                                        AND (v_j#>>'{periodo,mas_vencidos}')::int = 2, format('2 E1 despues: %s', v_j->'periodo'));
    v_d := date_trunc('month', (v_hoy - 40)::timestamp)::date;
    e := pg_temp.alta(v_a1, v_t, NULL, v_d, false, 'mensual');
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_d
                                        AND (v_j#>>'{periodo,hasta}')::date = (v_d + interval '1 month')::date - 1,
                  format('2 mensual: %s', v_j->'periodo'));
    e := pg_temp.a(NULL, v_l + 2, false);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_l + 2 AND (v_j#>>'{periodo,hasta}')::date = v_l + 6,
                  format('2 arranque miercoles: %s', v_j->'periodo'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- =========================================================== 3 · sueldo ===
  BEGIN
    e := pg_temp.a(NULL, v_l, false);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{sueldo,propuesto}')::numeric = 70000 AND v_j->'avisos' = '[]'::jsonb
                                        AND (v_j->>'a_pagar')::numeric = 70000, format('3 semanal: %s', v_j->'sueldo'));
    v_fallas := v_fallas || pg_temp.falla('3 sin motivo', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"sueldo":50000}')), 'por qué cambia el sueldo');
    v_fallas := v_fallas || pg_temp.falla('3 con blancos', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"sueldo":50000,"motivo_sueldo":"  "}')), 'por qué cambia el sueldo');
    v_fallas := v_fallas || pg_temp.falla('3 negativo', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"sueldo":-1,"motivo_sueldo":"x"}')), 'no puede ser negativo');
    v_liq := pg_temp.lq(e, '{"sueldo":50000,"motivo_sueldo":"Faltó dos días"}');
    SELECT * INTO g FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'sueldo';
    v_fallas := v_fallas || pg_temp.chk(g.monto = 50000 AND g.observacion = 'Faltó dos días' AND g.fecha = v_l + 6,
                  format('3 corregido: %s', to_jsonb(g)));
    SELECT detalle INTO v_k FROM empleado_liquidacion_conceptos WHERE liquidacion_id = v_liq AND concepto = 'sueldo';
    v_fallas := v_fallas || pg_temp.chk((v_k->>'propuesto')::numeric = 70000 AND v_k->>'motivo' = 'Faltó dos días', format('3 concepto: %s', v_k));
    v_liq := pg_temp.lq(e, '{"sueldo":0,"motivo_sueldo":"No vino"}');
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE liquidacion_id = v_liq)
                                        AND EXISTS (SELECT 1 FROM empleado_liquidacion_conceptos WHERE liquidacion_id = v_liq AND concepto = 'sueldo' AND monto = 0),
                  '3 sueldo 0: movimiento de mas o sin concepto');
    v_j := pg_temp.como(v_a1, v_t, pg_temp.ob(v_liq))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'sueldo_propuesto')::numeric = 70000 AND v_j->>'motivo_sueldo' = 'No vino', format('3 detalle: %s', v_j));

    e := pg_temp.a(NULL, v_l + 2, false);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{sueldo,propuesto}')::numeric = 70000 AND v_j->'avisos' = '["periodo_parcial"]'::jsonb,
                  format('3 arranque miercoles: %s', v_j->'avisos'));

    e := pg_temp.a(NULL, v_l, false);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.arr(e, v_l + 2));
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{sueldo,propuesto}')::numeric = 70000 AND v_j->'avisos' = '["arreglo_cambia"]'::jsonb,
                  format('3 cambia el arreglo: %s', v_j->'avisos'));
    PERFORM pg_temp.lq(e);
    v_fallas := v_fallas || pg_temp.chk((pg_temp.pv(e)#>>'{sueldo,propuesto}')::numeric = 84000, '3 la semana siguiente no propone 84000');

    e := pg_temp.a(NULL, v_l);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.pv(e)->'avisos' = '["comisiona_sin_usuario"]'::jsonb, '3 sin usuario y comisiona');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ============================================================= 4 · baja ===
  BEGIN
    v_u := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_l);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.baja(e, v_l + 2));
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{sueldo,propuesto}')::numeric = 70000 AND v_j->'avisos' = '["periodo_parcial"]'::jsonb,
                  format('4 semana de la baja: %s', v_j->'avisos'));
    PERFORM pg_temp.lq(e);
    v_ped := pg_temp.ped(v_u, v_l + 1, 100000, NULL, pg_temp.ar(v_l + 4));
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{sueldo,propuesto}')::numeric = 0 AND (v_j#>>'{comisiones,total}')::numeric = 2000
                                        AND (v_j#>>'{periodo,desde}')::date = v_l + 7, format('4 despues de la baja: %s', v_j));
    v_k := pg_temp.pay(v_j);
    PERFORM pg_temp.lq(e);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.pv(e) IS NULL, '4 sin nada pendiente la vista previa no da NULL');
    v_fallas := v_fallas || pg_temp.falla('4 rechaza', v_a1, v_t,
                  pg_temp.liq(e, v_k || jsonb_build_object('desde', v_l + 14, 'hasta', v_l + 20, 'a_pagar_esperado', 0)), 'no tiene nada para liquidar');
    v_j := (SELECT x FROM jsonb_array_elements(pg_temp.como(v_a1, v_t, 'SELECT public.listar_personal()')::jsonb) x WHERE (x->>'id')::bigint = e);
    v_fallas := v_fallas || pg_temp.chk(v_j->'periodo' = 'null'::jsonb, format('4 la tarjeta sigue con periodo: %s', v_j->'periodo'));
    -- Una entrega mas de un periodo despues del que sigue: el periodo salta
    -- hasta ella, o no se liquidaria nunca.
    v_ped := pg_temp.ped(v_u, v_l + 2, 100000, NULL, pg_temp.ar(v_l + 22));
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_l + 21 AND (v_j#>>'{periodo,hasta}')::date = v_l + 27
                                        AND pg_temp.tiene(v_j#>'{comisiones,detalle}', v_ped), format('4 entrega tardia: %s', v_j->'periodo'));
    v_k := (SELECT x FROM jsonb_array_elements(pg_temp.como(v_a1, v_t, 'SELECT public.listar_personal()')::jsonb) x WHERE (x->>'id')::bigint = e);
    v_fallas := v_fallas || pg_temp.chk((v_k#>>'{periodo,desde}')::date = v_l + 21, format('4 la tarjeta no la ve: %s', v_k->'periodo'));
    PERFORM pg_temp.lq(e);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.pv(e) IS NULL AND pg_temp.saldo(e) = 74000, format('4 cierre: saldo %s', pg_temp.saldo(e)));
    -- Un pedido con comision 0 no traba al que sigue, ni deja un periodo en la tarjeta.
    v_u := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_l);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.baja(e, v_l + 1));
    PERFORM pg_temp.lq(e);
    INSERT INTO comision_reglas (sucursal_id, preventista_id, producto_id, porcentaje, vigente_desde, usuario_id, created_at)
    VALUES (v_t, v_u, v_p2, 0, v_l - 40, v_a1, (v_l - 40)::timestamp);
    v_ped := pg_temp.ped(v_u, v_l + 15);
    UPDATE pedido_items SET producto_id = v_p2 WHERE pedido_id = v_ped;
    v_k := (SELECT x FROM jsonb_array_elements(pg_temp.como(v_a1, v_t, 'SELECT public.listar_personal()')::jsonb) x WHERE (x->>'id')::bigint = e);
    v_fallas := v_fallas || pg_temp.chk(v_k->'periodo' = 'null'::jsonb AND pg_temp.pv(e) IS NULL, format('4 comision 0: %s', v_k->'periodo'));
    v_ped2 := pg_temp.ped(v_u, v_l + 22);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_l + 21 AND (v_j#>>'{comisiones,total}')::numeric = 2000
                                        AND pg_temp.tiene(v_j#>'{comisiones,detalle}', v_ped) AND pg_temp.tiene(v_j#>'{comisiones,detalle}', v_ped2),
                  format('4 comision 0 con otro atras: %s', v_j->'comisiones'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ======================================================== 5 · reactivar ===
  BEGIN
    v_u := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_l);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.baja(e, v_l + 1));
    PERFORM pg_temp.como(v_a1, v_t, format('SELECT public.reactivar_empleado(p_empleado_id => %s)', e));
    v_ped := pg_temp.ped(v_u, v_l + 3);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{sueldo,propuesto}')::numeric = 70000 AND v_j->'avisos' = '[]'::jsonb
                                        AND (v_j#>>'{comisiones,total}')::numeric = 2000 AND pg_temp.saldo(e) = 0
                                        AND NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE empleado_id = e), format('5 %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- ========================================================= 6 · que entra ===
  BEGIN
    v_u := pg_temp.u('preventista', v_t);
    v_u2 := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_l + 7);
    v_ped := pg_temp.ped(v_u, v_l + 8);                                            -- entra
    v_ped2 := pg_temp.ped(v_u, v_l + 13, 100000, NULL, pg_temp.ar(v_l + 13, '22:30')); -- domingo a la noche: entra
    v_ped3 := pg_temp.ped(v_u, v_l + 9);                                           -- sin fecha_entrega: por pedidos.fecha
    UPDATE pedidos SET fecha_entrega = NULL WHERE id = v_ped3;
    v_ped4 := pg_temp.ped(v_u, v_l + 11, 100000, NULL, pg_temp.ar(v_l + 14));      -- tomado viernes, entregado lunes: la que sigue
    -- Antes del arranque, cancelado, canje, VB, de otro usuario y de otra sucursal.
    PERFORM pg_temp.ped(v_u, v_l + 3);
    v_n := pg_temp.ped(v_u, v_l + 8);
    UPDATE pedidos SET estado = 'cancelado', motivo_cancelacion = 'Ensayo', total = 0 WHERE id = v_n;
    v_liq2 := pg_temp.ped(v_u, v_l + 8);
    UPDATE pedidos SET canal = 'cambio' WHERE id = v_liq2;
    v_n := pg_temp.ped(v_u, v_l + 8);
    UPDATE pedidos SET tipo_factura = 'VB', monto_pagado = total, total = total WHERE id = v_n;
    PERFORM pg_temp.ped(v_u2, v_l + 8);
    PERFORM pg_temp.ped(v_u, v_l + 8, 100000, c2);
    -- Con adelanto: en parte, con el factor; entero, no entra.
    v_mov := pg_temp.ped(v_u, v_l + 10, 100000, c_ad);
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (c_ad, v_mov, 25000, 'adelanto_sueldo', v_l + 10, v_a1, v_t);
    v_n := pg_temp.ped(v_u, v_l + 10, 100000, c_ad);
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (c_ad, v_n, 100000, 'adelanto_sueldo', v_l + 10, v_a1, v_t);

    v_j := pg_temp.pv(e);
    v_k := v_j#>'{comisiones,detalle}';
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tiene(v_k, v_ped) AND pg_temp.tiene(v_k, v_ped2) AND pg_temp.tiene(v_k, v_ped3)
                                        AND pg_temp.tiene(v_k, v_mov) AND jsonb_array_length(v_k) = 4
                                        AND (v_j#>>'{comisiones,base}')::numeric = 375000
                                        AND (v_j#>>'{comisiones,total}')::numeric = 7500, format('6 %s', v_j->'comisiones'));
    PERFORM pg_temp.lq(e);
    -- Un canje con total pone rojos CAMBIO-01 y CAMBIO-03: ya dio lo que tenia que dar.
    UPDATE pedidos SET canal = 'app', estado = 'cancelado', motivo_cancelacion = 'Ensayo', total = 0 WHERE id = v_liq2;
    v_k := pg_temp.pv(e)#>'{comisiones,detalle}';
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tiene(v_k, v_ped4) AND jsonb_array_length(v_k) = 1, format('6 el del lunes: %s', v_k));

    v_u := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_l, false);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.arr(e, v_l + 7, 70000, true));
    PERFORM pg_temp.ped(v_u, v_l + 3);
    v_fallas := v_fallas || pg_temp.chk((pg_temp.pv(e)#>>'{comisiones,total}')::numeric = 0, '6 entrego sin comisionar y entro');
    PERFORM pg_temp.lq(e);
    v_fallas := v_fallas || pg_temp.chk((pg_temp.pv(e)#>>'{comisiones,total}')::numeric = 0, '6 entro cuando empezo a comisionar');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- ========================================================== 7 · congelar ===
  BEGIN
    v_u := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_l);
    INSERT INTO comision_reglas (sucursal_id, preventista_id, producto_id, porcentaje, vigente_desde, usuario_id, created_at)
    VALUES (v_t, v_u, v_p2, 5, v_l - 40, v_a1, (v_l - 40)::timestamp) RETURNING id INTO v_regla;
    v_ped := pg_temp.ped(v_u, v_l + 1);
    PERFORM pg_temp.li(v_ped, v_p2, 50000);
    PERFORM pg_temp.li(v_ped, current_setting('g5.p1')::bigint, 20000, v_combo);
    PERFORM pg_temp.li(v_ped, current_setting('g5.p1')::bigint, 30000);
    v_liq := pg_temp.lq(e);
    SELECT * INTO g FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq AND producto_id = v_p2;
    v_fallas := v_fallas || pg_temp.chk(g.base = 50000 AND g.pct = 5 AND g.comision = 2500 AND g.regla_id = v_regla
                                        AND g.tipo = 'inicial' AND g.usuario_id = v_u AND g.entregado_el = v_l + 1, format('7 regla: %s', to_jsonb(g)));
    SELECT * INTO g FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq AND producto_id <> v_p2 AND combo_id IS NULL;
    v_fallas := v_fallas || pg_temp.chk(g.base = 130000 AND g.pct = 2 AND g.comision = 2600 AND g.regla_id IS NULL, format('7 dos iguales: %s', to_jsonb(g)));
    SELECT * INTO g FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq AND combo_id = v_combo;
    v_fallas := v_fallas || pg_temp.chk(g.base = 20000 AND g.comision = 400 AND g.origen_precio = 'combo', format('7 combo: %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq) = 3, '7 no son tres claves');
    SELECT * INTO g FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'comision';
    v_fallas := v_fallas || pg_temp.chk(g.monto = 5500, format('7 movimiento: %s', g.monto));
    v_j := (pg_temp.como(v_a1, v_t, format('SELECT public.obtener_cuenta_empleado(p_empleado_id => %s)', e))::jsonb);
    v_fallas := v_fallas || pg_temp.chk((SELECT (x#>>'{liquidacion,pedidos}')::int FROM jsonb_array_elements(v_j->'movimientos') x WHERE x->>'tipo' = 'comision') = 1
                                        AND (v_j#>>'{liquidaciones,0,comision}')::numeric = 5500 AND (v_j#>>'{liquidaciones,0,es_la_ultima}')::boolean,
                  format('7 cuenta: %s', v_j->'liquidaciones'));
    v_j := pg_temp.como(v_a1, v_t, pg_temp.ob(v_liq))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{pedidos,0,comision}')::numeric = 5500 AND (v_j#>>'{pedidos,0,base}')::numeric = 200000, format('7 detalle: %s', v_j->'pedidos'));

    -- g: dar de baja la regla o subir el % no da ningun ajuste.
    BEGIN
      UPDATE comision_reglas SET activo = false, baja_desde = v_l - 39 WHERE id = v_regla;
      UPDATE comision_pct_vigencias SET pct_preventista = 5 WHERE sucursal_id = v_t;
      v_k := pg_temp.pv(e)->'ajustes';
      RAISE EXCEPTION USING ERRCODE = 'P0097';
    EXCEPTION WHEN SQLSTATE 'P0097' THEN NULL;
    END;
    PERFORM pg_temp.adm();
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = 0 AND v_k->'detalle' = '[]'::jsonb, format('8g %s', v_k));
    -- Una linea de combo sin su foto pone rojo COMBO-A: ya dio lo que tenia que dar.
    UPDATE pedido_items SET combo_id = NULL, precio_sin_combo_unitario = NULL, origen_precio = 'lista'
     WHERE pedido_id = v_ped AND combo_id = v_combo;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- =========================================================== 8 · ajustes ===
  BEGIN
    -- a: baja la base 10000, con el % de hoy en 5.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    UPDATE pedido_items SET cantidad = cantidad - 100, subtotal = subtotal - 10000 WHERE pedido_id = g.p;
    UPDATE pedidos SET total = total - 10000 WHERE id = g.p;
    BEGIN
      UPDATE comision_pct_vigencias SET pct_preventista = 5 WHERE sucursal_id = v_t;
      v_k := pg_temp.pv(g.e)->'ajustes';
      RAISE EXCEPTION USING ERRCODE = 'P0097';
    EXCEPTION WHEN SQLSTATE 'P0097' THEN NULL;
    END;
    PERFORM pg_temp.adm();
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = -200 AND v_k#>>'{detalle,0,motivo}' = 'Cambió la boleta del pedido', format('8a %s', v_k));
    v_liq := pg_temp.lq(g.e);
    SELECT * INTO h FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq;
    v_fallas := v_fallas || pg_temp.chk(h.tipo = 'ajuste' AND h.base = -10000 AND h.comision = -200 AND h.pct = 2, format('8a fila: %s', to_jsonb(h)));
    v_fallas := v_fallas || pg_temp.chk((SELECT monto FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'ajuste_comision') = -200, '8a movimiento');

    -- b: borrar y reinsertar las lineas iguales, con ids nuevos.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    SELECT id, producto_id, subtotal INTO h FROM pedido_items WHERE pedido_id = g.p;
    DELETE FROM pedido_items WHERE pedido_id = g.p;
    UPDATE pedidos SET total = 0 WHERE id = g.p;
    PERFORM pg_temp.li(g.p, h.producto_id, h.subtotal);
    v_k := pg_temp.pv(g.e)->'ajustes';
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = 0 AND v_k->'detalle' = '[]'::jsonb
                                        AND (SELECT id FROM pedido_items WHERE pedido_id = g.p) <> h.id, format('8b %s', v_k));

    -- c: una linea nueva usa la regla vigente a pedidos.fecha.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    INSERT INTO comision_reglas (sucursal_id, preventista_id, producto_id, porcentaje, vigente_desde, usuario_id, created_at)
    VALUES (v_t, g.u, v_p2, 5, v_l - 40, v_a1, (v_l - 40)::timestamp) RETURNING id INTO v_regla;
    PERFORM pg_temp.li(g.p, v_p2, 50000);
    v_k := pg_temp.pv(g.e)->'ajustes';
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = 2500 AND v_k#>>'{detalle,0,motivo}' = 'Línea nueva en el pedido', format('8c %s', v_k));
    v_liq := pg_temp.lq(g.e);
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM empleado_liquidacion_lineas WHERE liquidacion_id = v_liq
                                                  AND tipo = 'linea_nueva' AND pct = 5 AND regla_id = v_regla), '8c fila');

    -- d: cancelarlo.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    UPDATE pedidos SET estado = 'cancelado', motivo_cancelacion = 'Ensayo', total = 0 WHERE id = g.p;
    v_k := pg_temp.pv(g.e)->'ajustes';
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = -2000 AND v_k#>>'{detalle,0,motivo}' = 'Se canceló el pedido', format('8d %s', v_k));

    -- e: vuelve a pendiente y se entrega de nuevo, con el % congelado.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    UPDATE pedidos SET estado = 'pendiente', fecha_entrega = NULL WHERE id = g.p;
    v_k := pg_temp.pv(g.e)->'ajustes';
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = -2000 AND v_k#>>'{detalle,0,motivo}' = 'El pedido volvió a pendiente', format('8e %s', v_k));
    PERFORM pg_temp.lq(g.e);
    PERFORM pg_temp.adm();
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = pg_temp.ar(v_l + 9) WHERE id = g.p;
    BEGIN
      UPDATE comision_pct_vigencias SET pct_preventista = 5 WHERE sucursal_id = v_t;
      v_j := pg_temp.pv(g.e);
      RAISE EXCEPTION USING ERRCODE = 'P0097';
    EXCEPTION WHEN SQLSTATE 'P0097' THEN NULL;
    END;
    PERFORM pg_temp.adm();
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{ajustes,total}')::numeric = 2000 AND (v_j#>>'{comisiones,total}')::numeric = 0, format('8e vuelve: %s', v_j->'ajustes'));
    PERFORM pg_temp.lq(g.e);
    v_fallas := v_fallas || pg_temp.chk((SELECT sum(comision) FROM empleado_liquidacion_lineas WHERE empleado_id = g.e AND vigente) = 2000, '8e neto');

    -- f: un adelanto de sueldo cargado despues baja la base por el factor.
    v_u := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_l);
    v_ped := pg_temp.ped(v_u, v_l + 1, 100000, c_ad);
    PERFORM pg_temp.lq(e);
    PERFORM pg_temp.adm();
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (c_ad, v_ped, 25000, 'adelanto_sueldo', v_l + 10, v_a1, v_t);
    v_fallas := v_fallas || pg_temp.chk((pg_temp.pv(e)#>>'{ajustes,total}')::numeric = -500, '8f');

    -- h: el usuario se revincula a E2, sin cambiar el vendedor del pedido.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    UPDATE empleados SET usuario_id = NULL WHERE id = g.e;
    e2 := pg_temp.a(g.u, v_l);
    PERFORM pg_temp.adm();
    UPDATE pedido_items SET cantidad = cantidad - 100, subtotal = subtotal - 10000 WHERE pedido_id = g.p;
    UPDATE pedidos SET total = total - 10000 WHERE id = g.p;
    v_j := pg_temp.pv(e2);
    v_fallas := v_fallas || pg_temp.chk((pg_temp.pv(g.e)#>>'{ajustes,total}')::numeric = -200
                                        AND (v_j#>>'{comisiones,total}')::numeric = 0 AND (v_j#>>'{ajustes,total}')::numeric = 0, format('8h E2: %s', v_j));

    -- i: el pedido pasa a otro vendedor, y vuelve.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    v_u2 := pg_temp.u('preventista', v_t);
    e2 := pg_temp.a(v_u2, v_l);
    v_txt := pg_temp.como(v_a1, v_t, format('SELECT public.actualizar_preventista_pedido(%s, %L::uuid)', g.p, v_u2));
    v_fallas := v_fallas || pg_temp.chk((v_txt::jsonb->>'success')::boolean, format('8i cambio: %s', v_txt));
    v_k := pg_temp.pv(g.e)->'ajustes';
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = -2000 AND v_k#>>'{detalle,0,motivo}' = 'El pedido pasó a otro vendedor', format('8i anterior: %s', v_k));
    v_j := pg_temp.pv(e2);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{comisiones,total}')::numeric = 2000 AND pg_temp.tiene(v_j#>'{comisiones,detalle}', g.p), format('8i nuevo: %s', v_j->'comisiones'));
    PERFORM pg_temp.lq(e2);
    PERFORM pg_temp.lq(g.e);
    v_txt := pg_temp.como(v_a1, v_t, format('SELECT public.actualizar_preventista_pedido(%s, %L::uuid)', g.p, g.u));
    v_k := pg_temp.pv(e2)->'ajustes';
    v_fallas := v_fallas || pg_temp.chk((v_k->>'total')::numeric = -2000 AND v_k#>>'{detalle,0,motivo}' = 'El pedido pasó a otro vendedor', format('8i le sale al nuevo: %s', v_k));
    v_j := pg_temp.pv(g.e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{ajustes,total}')::numeric = 2000 AND (v_j#>>'{comisiones,total}')::numeric = 0, format('8i vuelve: %s', v_j->'ajustes'));
    PERFORM pg_temp.lq(e2);
    PERFORM pg_temp.lq(g.e);
    v_fallas := v_fallas || pg_temp.chk((SELECT sum(comision) FROM empleado_liquidacion_lineas WHERE empleado_id = g.e AND vigente) = 2000
                                        AND (SELECT sum(comision) FROM empleado_liquidacion_lineas WHERE empleado_id = e2 AND vigente) = 0
                                        AND (SELECT sum(monto) FROM empleado_movimientos WHERE empleado_id = g.e AND tipo IN ('comision', 'ajuste_comision')) = 2000
                                        AND (SELECT sum(monto) FROM empleado_movimientos WHERE empleado_id = e2 AND tipo IN ('comision', 'ajuste_comision')) = 0,
                  '8i el neto no cierra');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ============================================================== 9 · pago ===
  BEGIN
    e := pg_temp.a(NULL, v_l, false);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.falla('9 de mas', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"pago":70000.01}')), 'más de lo que le toca');
    v_fallas := v_fallas || pg_temp.falla('9 negativo', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"pago":-1}')), 'El pago no puede ser negativo');
    v_fallas := v_fallas || pg_temp.falla('9 futura', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, jsonb_build_object('pago', 1, 'fecha_pago', v_hoy + 1))), 'no puede ser futura');
    v_fallas := v_fallas || pg_temp.falla('9 formato', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"pago":"x"}')), 'formato inválido');
    v_fallas := v_fallas || pg_temp.falla('9 viejo', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"a_pagar_esperado":69000}')), 'Algo cambió');
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM empleado_liquidaciones WHERE empleado_id = e), '9 quedo escrito');
    PERFORM pg_temp.lq(e, '{"pago":70000}');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e) = 0, '9 pagar todo');
    v_liq := pg_temp.lq(e, '{"pago":50000}');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e) = 20000 AND (SELECT pagado FROM empleado_liquidaciones WHERE id = v_liq) = 50000, '9 parcial');
    v_liq := pg_temp.lq(e);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e) = 90000 AND NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'pago'), '9 pago 0');
    e := pg_temp.a(NULL, v_l, false);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.mov(e, '{"tipo":"adelanto","monto":100000}'));
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'a_pagar')::numeric = -30000 AND (v_j->>'saldo_anterior')::numeric = 0
                                        AND (v_j->>'saldo_actual')::numeric = -100000 AND pg_temp.tiene_mov(v_j, 'adelanto'), format('9 debe: %s', v_j));
    v_fallas := v_fallas || pg_temp.falla('9 el que debe no cobra', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j, '{"pago":1}')), 'más de lo que le toca');
    PERFORM pg_temp.lq(e);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e) = -30000 AND (v_j->>'saldo_anterior')::numeric = -30000
                                        AND jsonb_array_length(v_j->'movimientos') = 0, format('9 despues: %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ================================================= 10 · orden y en curso ===
  BEGIN
    e := pg_temp.a(NULL, v_l, false);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.falla('10 no es el siguiente', v_a1, v_t,
                  pg_temp.liq(e, pg_temp.pay(v_j) || jsonb_build_object('desde', v_l + 7, 'hasta', v_l + 13)), 'ya no es el próximo');
    v_k := pg_temp.pay(v_j);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.liq(e, v_k));
    v_fallas := v_fallas || pg_temp.falla('10 reintento', v_a1, v_t, pg_temp.liq(e, v_k), 'ya no es el próximo');
    v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM empleado_liquidaciones WHERE empleado_id = e) = 1, '10 duplico');
    BEGIN
      INSERT INTO empleado_liquidaciones (empleado_id, desde, hasta, frecuencia, sucursal_al_liquidar, de_las_dos,
                                          saldo_anterior, a_pagar, pagado, fecha_pago, creado_por)
      VALUES (e, v_l, v_l + 6, 'semanal', v_t, false, 0, 0, 0, v_hoy, v_a1);
      v_fallas := v_fallas || '10 el indice unico no freno'::text;
    EXCEPTION WHEN unique_violation THEN NULL;
    END;

    v_u := pg_temp.u('preventista', v_t);
    e := pg_temp.a(v_u, v_lunes);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'en_curso')::boolean AND (v_j->>'puede_liquidar')::boolean, format('10 en curso: %s', v_j));
    PERFORM pg_temp.lq(e);
    v_ped := pg_temp.ped(v_u, v_lunes);
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{periodo,desde}')::date = v_lunes + 7 AND pg_temp.tiene(v_j#>'{comisiones,detalle}', v_ped)
                                        AND NOT (v_j->>'puede_liquidar')::boolean, format('10 el siguiente: %s', v_j->'periodo'));
    v_fallas := v_fallas || pg_temp.falla('10 no empezo', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j)), 'todavía no empezó');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  -- ============================================================ 11 · anular ===
  BEGIN
    SELECT * INTO g FROM pg_temp.arm(v_l);
    v_m := pg_temp.saldo(g.e);
    v_j := pg_temp.pv(g.e);
    v_liq2 := pg_temp.lq(g.e, '{"pago":1000}');
    v_fallas := v_fallas || pg_temp.falla('11 no es la ultima', v_a1, v_t, pg_temp.an(g.lq), 'Sólo se anula la última');
    v_fallas := v_fallas || pg_temp.falla('11 sin motivo', v_a1, v_t, pg_temp.an(v_liq2, '  '), 'por qué se anula');
    v_n := (SELECT count(*) FROM empleado_movimientos WHERE liquidacion_id = v_liq2);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq2));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(g.e) = v_m
                                        AND (SELECT count(*) FROM empleado_movimientos WHERE liquidacion_id = v_liq2 AND revierte_id IS NOT NULL) = v_n
                                        AND (SELECT count(*) FROM empleado_movimientos WHERE liquidacion_id = v_liq2) = 2 * v_n
                                        AND (SELECT motivo_anulacion FROM empleado_liquidaciones WHERE id = v_liq2) = 'Ensayo', format('11 saldo %s', pg_temp.saldo(g.e)));
    v_fallas := v_fallas || pg_temp.falla('11 ya anulada', v_a1, v_t, pg_temp.an(v_liq2), 'ya está anulada');
    v_k := pg_temp.pv(g.e);
    v_fallas := v_fallas || pg_temp.chk(v_k->'a_pagar' = v_j->'a_pagar' AND (v_k#>>'{periodo,desde}')::date = v_l + 7, format('11 igual: %s %s', v_k->'a_pagar', v_j->'a_pagar'));
    -- Los pedidos quedan libres.
    v_liq := pg_temp.lq(g.e);
    PERFORM pg_temp.adm();
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(g.lq));
    v_j := pg_temp.pv(g.e);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tiene(v_j#>'{comisiones,detalle}', g.p) AND pg_temp.saldo(g.e) = 0, format('11 libres: %s', v_j->'comisiones'));
    v_j := pg_temp.como(v_a1, v_t, format('SELECT public.obtener_cuenta_empleado(p_empleado_id => %s)', g.e))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j#>>'{liquidaciones,0,es_la_ultima}')::boolean IS FALSE AND jsonb_array_length(v_j->'liquidaciones') = 3
                                        AND (SELECT bool_and((x#>>'{liquidacion,anulada}')::boolean) FROM jsonb_array_elements(v_j->'movimientos') x), format('11 cuenta: %s', v_j->'liquidaciones'));
    -- Anular una con ajustes los deja pendientes de nuevo.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    UPDATE pedidos SET estado = 'cancelado', motivo_cancelacion = 'Ensayo', total = 0 WHERE id = g.p;
    v_liq := pg_temp.lq(g.e);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq));
    v_fallas := v_fallas || pg_temp.chk((pg_temp.pv(g.e)#>>'{ajustes,total}')::numeric = -2000, '11 el ajuste no volvio');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('11 · error: %s', SQLERRM);
  END;

  -- =========================================================== 12 · guardas ===
  BEGIN
    SELECT * INTO g FROM pg_temp.arm(v_l);
    v_fallas := v_fallas || pg_temp.falla('12 arreglo adentro', v_a1, v_t, pg_temp.arr(g.e, v_l + 3), 'un arreglo nuevo vale desde el día siguiente');
    v_fallas := v_fallas || pg_temp.falla('12 corregir', v_a1, v_t, pg_temp.arr(g.e, v_l), to_char(v_l + 6, 'DD/MM/YYYY'));
    v_fallas := v_fallas || pg_temp.falla('12 baja', v_a1, v_t, pg_temp.baja(g.e, v_l + 3), 'la baja va desde esa fecha');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_a1, v_t, pg_temp.baja(g.e, v_l + 6)) = 'OK', '12 la baja el ultimo dia no anda');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(g.lq));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_a1, v_t, pg_temp.arr(g.e, v_l + 3)) = 'OK', '12 el arreglo no anda despues de anular');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_a1, v_t, pg_temp.baja(g.e, v_l + 3)) = 'OK', '12 la baja no anda despues de anular');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('12 · error: %s', SQLERRM);
  END;

  -- ========================================================= 13 · uno mismo ===
  BEGIN
    e := pg_temp.alta(v_ad, v_t, v_a1, v_l, false);
    v_j := pg_temp.pvc(v_a1, v_t, e);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'puede_liquidar')::boolean IS FALSE, '13 puede liquidarse');
    v_fallas := v_fallas || pg_temp.falla('13 liquidar', v_a1, v_t, pg_temp.liq(e, pg_temp.pay(v_j)), 'no podés liquidarte');
    v_fallas := v_fallas || pg_temp.falla('13 pago', v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":100}'), 'no podés liquidarte ni registrarte pagos');
    v_liq := pg_temp.lqc(v_ad, v_t, e);
    v_fallas := v_fallas || pg_temp.falla('13 anular', v_a1, v_t, pg_temp.an(v_liq), 'no podés liquidarte');
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, creado_por) VALUES (e, v_hoy, 'adelanto', -100, v_a1);
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, creado_por) VALUES (e, v_hoy, 'adelanto', -200, v_ad);
    v_j := pg_temp.pvc(v_ad, v_t, e);
    v_fallas := v_fallas || pg_temp.chk((SELECT array_agg((x->>'por_el_mismo')::boolean ORDER BY (x->>'id')::bigint)
                                           FROM jsonb_array_elements(v_j->'movimientos') x) = ARRAY[true, false], format('13 marca: %s', v_j->'movimientos'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('13 · error: %s', SQLERRM);
  END;

  -- ==================================================== 14 · mostrar de mas ===
  BEGIN
    SELECT * INTO g FROM pg_temp.arm(v_l);
    v_txt := format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', g.e);
    v_fallas := v_fallas || pg_temp.falla('14 at vista', v_at, v_tp, v_txt, 'no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('14 at liquidar', v_at, v_tp, pg_temp.liq(g.e, '{}'), 'no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('14 at anular', v_at, v_tp, pg_temp.an(g.lq), 'no existe o no la podés ver');
    v_fallas := v_fallas || pg_temp.falla('14 at detalle', v_at, v_tp, pg_temp.ob(g.lq), 'no existe o no la podés ver');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_en, v_t, v_txt) = '42501' AND pg_temp.estado(v_en, v_t, pg_temp.liq(g.e, '{}')) = '42501'
                                        AND pg_temp.estado(v_en, v_t, pg_temp.an(g.lq)) = '42501' AND pg_temp.estado(v_en, v_t, pg_temp.ob(g.lq)) = '42501', '14 el encargado no recibe 42501');
    e := pg_temp.alta(v_ad, v_t, NULL, v_l, false, 'semanal', 70000, true);
    v_liq := pg_temp.lqc(v_ad, v_t, e);
    v_fallas := v_fallas || pg_temp.falla('14 a1 de las dos', v_a1, v_t, format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', e), 'no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('14 a1 detalle de las dos', v_a1, v_t, pg_temp.ob(v_liq), 'no existe o no la podés ver');
    v_j := pg_temp.como(v_en, v_t, 'SELECT public.empleados_para_elegir()')::jsonb;
    v_fallas := v_fallas || pg_temp.chk((SELECT array_agg(DISTINCT k ORDER BY k) FROM jsonb_array_elements(v_j) x, jsonb_object_keys(x) k)
                                        = ARRAY['activo', 'id', 'nombre', 'usuario_id', 'vehiculo_id'], '14 empleados_para_elegir suma claves');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('14 · error: %s', SQLERRM);
  END;

  -- ======================================================= 15 · pago suelto ===
  BEGIN
    e := pg_temp.a(NULL, v_l, false);
    v_mov := pg_temp.como(v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":1000}'))::bigint;
    SELECT * INTO g FROM empleado_movimientos WHERE id = v_mov;
    v_fallas := v_fallas || pg_temp.chk(g.monto = -1000 AND g.tipo = 'pago' AND g.observacion IS NULL AND g.rendicion_fecha IS NULL, format('15 %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.falla('15 cero', v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":0}'), 'mayor a cero');
    v_fallas := v_fallas || pg_temp.falla('15 otro tipo', v_a1, v_t, pg_temp.mov(e, '{"tipo":"sueldo","monto":10}'), 'un adelanto en efectivo, un pago o un ajuste');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rev(v_mov));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e) = 0 AND (SELECT tipo FROM empleado_movimientos WHERE revierte_id = v_mov) = 'pago', '15 reversion');
    v_liq := pg_temp.lq(e, '{"pago":1000}');
    v_fallas := v_fallas || pg_temp.falla('15 de una liquidacion', v_a1, v_t,
                  pg_temp.rev((SELECT id FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'pago')), 'se revierte anulando la liquidación');
    v_fallas := v_fallas || pg_temp.falla('15 el sueldo', v_a1, v_t,
                  pg_temp.rev((SELECT id FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'sueldo')), 'Sólo se revierte un movimiento cargado a mano');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('15 · error: %s', SQLERRM);
  END;

  -- =================================================== 16 · personal_por_mes ===
  BEGIN
    -- Una semana terminada que cruza de mes.
    v_d := (SELECT d::date FROM generate_series(v_lunes - 7 * 12, v_lunes - 7, interval '7 days') d
             WHERE date_trunc('month', d) <> date_trunc('month', d + interval '6 days') ORDER BY d DESC LIMIT 1);
    e := pg_temp.alta(v_a1, v_t, NULL, v_d, false, 'semanal', 100000.01);
    v_liq := pg_temp.lq(e);
    SELECT count(*), sum(p.monto), bool_and(NOT p.compartido AND p.sucursal_id = v_t) INTO g
      FROM public.personal_por_mes(v_d - 40, v_d + 40, ARRAY[v_t]) p WHERE p.empleado_id = e AND p.concepto = 'sueldo';
    v_fallas := v_fallas || pg_temp.chk(g.count = 2 AND g.sum = 100000.01 AND g.bool_and, format('16 cruza de mes: %s', to_jsonb(g)));
    e2 := pg_temp.alta(v_ad, v_t, NULL, v_d, false, 'semanal', 70000, true);
    PERFORM pg_temp.lqc(v_ad, v_t, e2);
    SELECT count(*), sum(p.monto), bool_and(p.compartido) INTO g
      FROM public.personal_por_mes(v_d - 40, v_d + 40, ARRAY[v_tp]) p WHERE p.empleado_id = e2;
    v_fallas := v_fallas || pg_temp.chk(g.sum = 70000 AND g.bool_and, format('16 de las dos: %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM public.personal_por_mes(v_d - 40, v_d + 40, ARRAY[v_tp]) p WHERE p.empleado_id = e), '16 trajo otra sucursal');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq));
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM public.personal_por_mes(v_d - 40, v_d + 40, ARRAY[v_t]) p WHERE p.empleado_id = e), '16 la anulada cuenta');
    -- La comision al mes de entrega, en la sucursal del pedido; el ajuste, al del hasta.
    SELECT * INTO g FROM pg_temp.arm(v_l);
    UPDATE pedidos SET estado = 'cancelado', motivo_cancelacion = 'Ensayo', total = 0 WHERE id = g.p;
    PERFORM pg_temp.lq(g.e);
    v_fallas := v_fallas || pg_temp.chk(
      (SELECT sum(p.monto) FROM public.personal_por_mes(v_l - 40, v_hoy, ARRAY[v_t]) p WHERE p.empleado_id = g.e AND p.concepto = 'comision') = 2000
      AND (SELECT sum(p.monto) FROM public.personal_por_mes(v_l - 40, v_hoy, ARRAY[v_t]) p WHERE p.empleado_id = g.e AND p.concepto = 'ajuste_comision') = -2000
      AND (SELECT min(p.mes) FROM public.personal_por_mes(v_l - 40, v_hoy, ARRAY[v_t]) p WHERE p.empleado_id = g.e AND p.concepto = 'comision')
          = date_trunc('month', (v_l + 1)::timestamp)::date, '16 comision y ajuste');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('16 · error: %s', SQLERRM);
  END;

  -- ========================================================= 17 · rendicion ===
  BEGIN
    e := pg_temp.a(NULL, v_l, false);
    v_liq := pg_temp.lq(e, '{"pago":60000}'::jsonb || pg_temp.plata(v_tr, v_hoy));
    SELECT * INTO g FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'pago';
    v_fallas := v_fallas || pg_temp.chk(g.rendicion_transportista_id = v_tr AND g.rendicion_fecha = v_hoy AND g.rendicion_sucursal_id = v_t AND g.monto = -60000, format('17 movimiento: %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tpp(v_t, v_hoy, v_tr) = 60000, format('17 total: %s', pg_temp.tpp(v_t, v_hoy, v_tr)));
    v_j := pg_temp.res(v_a1, v_t, v_hoy, v_tr);
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j) = 1 AND (v_j#>>'{0,total_efectivo}')::numeric = 0, format('17 grilla: %s', v_j));
    v_k := pg_temp.como(v_a1, v_t, format('SELECT public.obtener_cuenta_empleado(p_empleado_id => %s)', e))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_k#>>'{liquidaciones,0,rendicion,fecha}' = v_hoy::text AND v_k#>>'{liquidaciones,0,rendicion,transportista_nombre}' IS NOT NULL
                                        AND (SELECT x#>>'{rendicion,fecha}' FROM jsonb_array_elements(v_k->'movimientos') x WHERE x->>'tipo' = 'pago') = v_hoy::text,
                  format('17 cuenta: %s', v_k->'liquidaciones'));
    -- El encargado lee el total, sin nombres; el chofer, solo su fila.
    -- total_faltantes_empleados (gastos 6) es un total, no un nombre.
    PERFORM pg_temp.lq(pg_temp.a(NULL, v_l, false), '{"pago":5000}'::jsonb || pg_temp.plata(v_tr3, v_hoy));
    v_j := pg_temp.res(v_en, v_t, v_hoy, NULL);
    v_txt := (SELECT nombre FROM empleados WHERE id = e);
    v_fallas := v_fallas || pg_temp.chk((SELECT (x->>'total_pagos_personal')::numeric FROM jsonb_array_elements(v_j) x WHERE (x->>'transportista_id')::uuid = v_tr) = 60000
                                        AND position(v_txt IN v_j::text) = 0
                                        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x, jsonb_object_keys(x) k WHERE k ~ 'empleado' AND k <> 'total_faltantes_empleados'), format('17 encargado: %s', v_j));
    v_j := pg_temp.res(v_tr, v_t, v_hoy, NULL);
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j) = 1 AND (v_j#>>'{0,transportista_id}')::uuid = v_tr, format('17 chofer: %s', v_j));

    v_fallas := v_fallas || pg_temp.falla('17 sin chofer', v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":10,"origen_pago":"rendicion"}'), 'Elegí de qué rendición');
    v_fallas := v_fallas || pg_temp.falla('17 futuro', v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":10}'::jsonb || pg_temp.plata(v_tr, v_hoy + 1)), 'todavía no llegó');
    v_fallas := v_fallas || pg_temp.falla('17 otra sucursal', v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":10}'::jsonb || pg_temp.plata(v_tr2, v_hoy)), 'no es de esta sucursal');
    v_fallas := v_fallas || pg_temp.falla('17 otro origen', v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":10,"origen_pago":"x"}'), 'formato inválido');

    -- Un pago suelto suma, y su fecha es la de la rendicion; el adelanto no acepta rendicion.
    v_mov := pg_temp.como(v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":1000}'::jsonb || pg_temp.plata(v_tr, v_hoy - 2)))::bigint;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tpp(v_t, v_hoy - 2, v_tr) = 1000 AND (SELECT fecha FROM empleado_movimientos WHERE id = v_mov) = v_hoy - 2, '17 suelto');
    v_k := (SELECT x FROM jsonb_array_elements(pg_temp.pv(e)->'movimientos') x WHERE (x->>'id')::bigint = v_mov);
    v_fallas := v_fallas || pg_temp.chk(v_k#>>'{rendicion,fecha}' = (v_hoy - 2)::text AND v_k#>>'{rendicion,transportista_nombre}' IS NOT NULL
                                        AND v_k->'liquidacion' = 'null'::jsonb, format('17 suelto en la vista previa: %s', v_k));
    v_n := pg_temp.como(v_a1, v_t, pg_temp.mov(e, '{"tipo":"adelanto","monto":10}'::jsonb || pg_temp.plata(v_tr, v_hoy)))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT rendicion_fecha FROM empleado_movimientos WHERE id = v_n) IS NULL, '17 el adelanto tomo la rendicion');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rev(v_mov));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tpp(v_t, v_hoy - 2, v_tr) = 0 AND jsonb_array_length(pg_temp.res(v_a1, v_t, v_hoy - 2, v_tr)) = 0, '17 revertir devuelve la plata');

    -- Anular con la rendicion pendiente: el total vuelve a 0.
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tpp(v_t, v_hoy, v_tr) = 0, '17 anular con la pendiente');

    -- Cerrada: se rechaza; anular deja el pago; la nueva lo descuenta.
    e := pg_temp.alta(v_a1, v_t, NULL, v_l, false, 'semanal', 150000);
    v_d := v_hoy - 3;
    v_liq := pg_temp.lq(e, '{"pago":100000}'::jsonb || pg_temp.plata(v_tr, v_d));
    INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_por) VALUES (v_d, v_tr, v_t, 'confirmada', v_a1);
    v_lc := v_lc + 100000;
    v_fallas := v_fallas || pg_temp.falla('17 cerrada', v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":10}'::jsonb || pg_temp.plata(v_tr, v_d)), 'ya está cerrada');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.tpp(v_t, v_d, v_tr) = 100000 AND pg_temp.saldo(e) = -100000
                                        AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m JOIN empleado_movimientos o ON o.id = m.revierte_id
                                                         WHERE o.liquidacion_id = v_liq AND o.tipo = 'pago'), '17 anular con la cerrada');
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'a_pagar')::numeric = 50000 AND pg_temp.tiene_mov(v_j, 'pago') AND (v_j->>'saldo_anterior')::numeric = 0
                                        AND (v_j#>>'{sueldo,propuesto}')::numeric = 150000, format('17 la nueva: %s', v_j));
    v_k := (SELECT x FROM jsonb_array_elements(v_j->'movimientos') x WHERE x->>'tipo' = 'pago');
    v_fallas := v_fallas || pg_temp.chk((v_k#>>'{liquidacion,anulada}')::boolean AND (v_k#>>'{liquidacion,id}')::bigint = v_liq
                                        AND (v_k#>>'{liquidacion,desde}')::date = v_l AND v_k#>>'{rendicion,fecha}' = v_d::text,
                  format('17 el pago de la anulada en la vista previa: %s', v_k));
    PERFORM pg_temp.lq(e, '{"pago":50000}');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e) = 0, '17 cuenta dos veces');
    v_j := pg_temp.pv(e);
    v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.tiene_mov(v_j, 'pago'), '17 el pago sigue en la vista previa');

    v_d := v_hoy - 4;
    v_mov := pg_temp.como(v_a1, v_t, pg_temp.mov(e, '{"tipo":"pago","monto":1000}'::jsonb || pg_temp.plata(v_tr, v_d)))::bigint;
    INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_por) VALUES (v_d, v_tr, v_t, 'confirmada', v_a1);
    v_lc := v_lc + 1000;
    v_fallas := v_fallas || pg_temp.falla('17 suelto cerrado', v_a1, v_t, pg_temp.rev(v_mov), 'corregilo con un ajuste');

    -- El cierre compara los pagos con lo que vio el modal, como los gastos.
    e := pg_temp.alta(v_a1, v_t, NULL, v_l, false, 'semanal', 150000);
    v_d := v_hoy - 5;
    v_liq := pg_temp.lq(e, '{"pago":100000}'::jsonb || pg_temp.plata(v_tr3, v_d));
    v_fallas := v_fallas || pg_temp.falla('17 cierre con visto 0', v_a1, v_t, pg_temp.cr(v_d, v_tr3, '{"pagos_personal_visto":0}'),
                  'Los pagos al personal de esta rendición cambiaron mientras la cerrabas');
    v_fallas := v_fallas || pg_temp.falla('17 cierre sin la clave', v_a1, v_t, pg_temp.cr(v_d, v_tr3, '{}'),
                  'Los pagos al personal de esta rendición cambiaron mientras la cerrabas');
    v_fallas := v_fallas || pg_temp.falla('17 disconformidad con visto 0', v_a1, v_t,
                  pg_temp.cr(v_d, v_tr3, '{"pagos_personal_visto":0}', 'disconformidad'), 'Los pagos al personal de esta rendición cambiaron');
    v_fallas := v_fallas || pg_temp.falla('17 visto con otro formato', v_a1, v_t, pg_temp.cr(v_d, v_tr3, '{"pagos_personal_visto":"x"}'),
                  'Los gastos del cierre vienen con un formato inválido');
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM rendiciones_control WHERE fecha = v_d AND transportista_id = v_tr3),
                  '17 el cierre rechazado creo el control');
    v_txt := pg_temp.estado(v_a1, v_t, pg_temp.cr(v_d, v_tr3, '{"pagos_personal_visto":100000}'));
    v_fallas := v_fallas || pg_temp.chk(v_txt = 'OK', format('17 el cierre con lo que vio da %s', v_txt));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.cr(v_d, v_tr3, '{"pagos_personal_visto":0}'));
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM rendiciones_control WHERE fecha = v_d AND transportista_id = v_tr3
                                                  AND estado = 'confirmada'), '17 despues de anular, visto 0 no cierra');

    -- Un empleado cambiado de sucursal despues del pago: a1 no tiene la de la rendicion.
    e := pg_temp.alta(v_ad, v_tp, NULL, v_l, false);
    v_liq := pg_temp.lqc(v_ad, v_tp, e, '{"pago":1000}'::jsonb || pg_temp.plata(v_tr2, v_hoy));
    v_mov := pg_temp.como(v_ad, v_tp, pg_temp.mov(e, '{"tipo":"pago","monto":500}'::jsonb || pg_temp.plata(v_tr2, v_hoy)))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT rendicion_sucursal_id FROM empleado_movimientos WHERE id = v_mov) = v_tp AND pg_temp.tpp(v_tp, v_hoy, v_tr2) = 1500, '17 sucursal 2');
    UPDATE empleados SET sucursal_id = v_t WHERE id = e;
    v_n := pg_temp.saldo(e);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_a1, v_t, pg_temp.an(v_liq)) = '42501', '17 a1 anula sin la sucursal');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.estado(v_a1, v_t, pg_temp.rev(v_mov)) = '42501', '17 a1 revierte sin la sucursal');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e) = v_n AND (SELECT anulada_at FROM empleado_liquidaciones WHERE id = v_liq) IS NULL, '17 quedo escrito');

    -- Sin contar las rendiciones que armo este caso.
    SELECT count(*) AS n, count(*) FILTER (WHERE x.total_pagos_personal <> 0 AND x.transportista_id <> v_tr) AS m INTO g
      FROM jsonb_to_recordset(pg_temp.como(v_a1, v_t,
             'SELECT jsonb_agg(to_jsonb(r)) FROM public.obtener_resumen_rendiciones(p_fecha_desde => ''2026-10-01''::date, p_fecha_hasta => ''2026-10-31''::date) r')::jsonb)
           AS x(transportista_id uuid, total_pagos_personal numeric);
    v_fallas := v_fallas || pg_temp.chk(g.n > 0 AND g.m = 0, format('17 octubre: %s', to_jsonb(g)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('17 · error: %s', SQLERRM);
  END;

  -- ========================================================== 18 · permisos ===
  BEGIN
    FOR g IN SELECT f FROM unnest(ARRAY[
               'public._comision_lineas(bigint[])', 'public._empleado_dia_de_entrega(timestamptz,date)',
               'public._periodo_que_contiene(date,text)', 'public._empleado_ultima_hasta(bigint)',
               'public._empleado_periodo_siguiente(empleados)', 'public._liquidacion_sueldo_propuesto(empleados,date,date)',
               'public._liquidacion_lineas(empleados,date)', 'public._liquidacion_json(empleados,date,date,numeric)',
               'public._liquidacion_resumen_json(empleado_liquidaciones)', 'public._movimiento_origen_json(empleado_movimientos)',
               'public._pago_de_rendicion(jsonb)',
               'public.personal_por_mes(date,date,bigint[])', 'public.empleado_arreglos_periodo_cerrado()',
               'public.empleados_periodo_cerrado()']) f LOOP
      IF has_function_privilege('anon', g.f, 'EXECUTE') OR has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('18 alcanzable: %s', g.f);
      END IF;
    END LOOP;
    FOR g IN SELECT f FROM unnest(ARRAY[
               'public.previsualizar_liquidacion(bigint)', 'public.liquidar_empleado(bigint,jsonb)',
               'public.anular_liquidacion(bigint,text)', 'public.obtener_liquidacion(bigint)',
               'public.obtener_resumen_rendiciones(date,date,uuid)',
               'public.confirmar_rendicion(date,uuid,text,jsonb,text)']) f LOOP
      IF has_function_privilege('anon', g.f, 'EXECUTE') OR NOT has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('18 EXECUTE de %s', g.f);
      END IF;
    END LOOP;
    FOR g IN SELECT t FROM unnest(ARRAY['public.empleado_liquidaciones', 'public.empleado_liquidacion_conceptos', 'public.empleado_liquidacion_lineas']) t LOOP
      IF has_table_privilege('anon', g.t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_table_privilege('authenticated', g.t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_any_column_privilege('authenticated', g.t, 'SELECT,INSERT,UPDATE,REFERENCES')
         OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = g.t::regclass)
         OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = g.t::regclass) THEN
        v_fallas := v_fallas || format('18 tabla %s', g.t);
      END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM public.auditoria_definer_sin_rol()
     WHERE firma ~ '^(_?liquidacion|_comision_lineas|_empleado_|_periodo_|_pago_de_|personal_por_mes|previsualizar_|liquidar_|anular_liquidacion|obtener_liquidacion|obtener_resumen_rendiciones)';
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('18 %s funciones en auditoria_definer_sin_rol', v_n));
    SELECT count(*) INTO v_n FROM public.auditoria_sucursal_cruzada() WHERE hija ~ '^empleado_' ;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('18 %s pares nuevos en auditoria_sucursal_cruzada', v_n));
    v_k := public.auditoria_fechas_utc();
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_k->'funciones') f
                                                     WHERE f->>'nombre' ~ '(empleado|personal|liquidacion|comision_lineas|periodo_que)'),
                  format('18 auditoria_fechas_utc: %s', v_k->'funciones'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('18 · error: %s', SQLERRM);
  END;

  -- ======================================================= 19 · invariantes ===
  BEGIN
    SELECT count(*) INTO v_n FROM empleado_liquidaciones l
     WHERE l.anulada_at IS NULL
       AND COALESCE((SELECT sum(m.monto) FROM empleado_movimientos m WHERE m.liquidacion_id = l.id), 0)
           <> COALESCE((SELECT sum(c.monto) FROM empleado_liquidacion_conceptos c WHERE c.liquidacion_id = l.id), 0) - l.pagado;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('19 LIQ-A: %s liquidaciones no cuadran', v_n));
    SELECT count(*) INTO v_n FROM (SELECT 1 FROM empleado_liquidacion_lineas WHERE vigente AND tipo <> 'ajuste'
                                    GROUP BY pedido_id, clave, usuario_id HAVING count(*) > 1) x;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('19 LIQ-B: %s lineas repetidas', v_n));
    SELECT COALESCE(-sum(m.monto), 0) INTO v_m FROM empleado_movimientos m
      JOIN rendiciones_control rc ON rc.transportista_id = m.rendicion_transportista_id AND rc.fecha = m.rendicion_fecha
                                 AND rc.sucursal_id = m.rendicion_sucursal_id AND rc.estado IN ('confirmada', 'resuelta');
    v_fallas := v_fallas || pg_temp.chk(v_m = v_lc, format('19 LIQ-C: las rendiciones cerradas tienen %s y tenian %s', v_m, v_lc));
    SELECT count(*) INTO v_n FROM empleado_liquidaciones;
    v_fallas := v_fallas || pg_temp.chk(v_n > 30, format('19 el ensayo dejo solo %s liquidaciones: algun caso no corrio', v_n));
    v_fallas := v_fallas || pg_temp.chk(public.auditoria_comision_mes_cerrado() = 0, format('19 auditoria_comision_mes_cerrado da %s', public.auditoria_comision_mes_cerrado()));
    v_j := pg_temp.audit(v_a1, v_t);
    v_ch_fin := (v_j->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin = v_ch_ini, format('19 critical_high_en_rojo paso de %s a %s: %s', v_ch_ini, v_ch_fin,
                  (SELECT array_agg(c->>'id') FROM jsonb_array_elements(v_j->'checks') c
                    WHERE (c->>'ok')::boolean IS FALSE AND c->>'severidad' IN ('critical', 'high'))));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('19 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gastos 5 (L %, liquidaciones %, C1 %): casos 1 a 19; critical_high_en_rojo % al empezar y % al final',
    v_l, (SELECT count(*) FROM empleado_liquidaciones), c1, v_ch_ini, v_ch_fin;
END
$ensayo$;
