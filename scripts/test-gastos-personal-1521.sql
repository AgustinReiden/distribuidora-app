-- Ensayo de la migracion 488 (gastos y personal, #1521): topes de fechas y de
-- pagos, el pago de una liquidacion anulada y los rubros por clave.
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
--   <migrations/488_gastos_y_personal_topes_pagos_y_rubros.sql sin BEGIN ni COMMIT>
--   <este archivo>
--   ROLLBACK;
--
-- Las RPCs se llaman COMO EL FRONT (pg_temp.como, rol authenticated). Los
-- cobros que dan el efectivo de cada rendicion, y el cierre y la reapertura de
-- una rendicion, se arman como postgres sobre las tablas. a1 es un admin real
-- de Tucuman; los choferes los crea el ensayo en auth.users, uno por caso, para
-- que las rendiciones no se crucen.
--
--   1  GTO-3 el tope del alta           6  GTO-6 la fecha y el mes del gasto
--   2  GTO-3 el arreglo nuevo           7  GTO-8 el tope del pago suelto
--   3  GTO-3 corregir la fecha          8  GTO-9 los nombres de sueldo
--   4  GTO-3 lo liquidado no se mueve   9  GTO-9 el rubro de los faltantes
--   5  GTO-4 el pago de la anulada      10 invariantes y auditoria

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_hoy    date := public._tablero_hoy();
  v_mes    date := date_trunc('month', public._tablero_hoy()::timestamp)::date;
  v_t      bigint := 1;
  d4       date := public._tablero_hoy() - 3;
  d8       date := public._tablero_hoy() - 4;
  d9       date := public._tablero_hoy() - 5;
  v_a1     uuid;
  v_tra    uuid;
  v_trb    uuid;
  v_trc    uuid;
  c1       bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_varios bigint;
  v_falt   bigint;
  e1       bigint;
  e3       bigint;
  e4       bigint;
  e8       bigint;
  ev       bigint;
  a1       bigint;
  a2       bigint;
  av       bigint;
  v_liq    bigint;
  v_mov    bigint;
  v_n      bigint;
  v_m      numeric;
  v_j      jsonb;
  v_txt    text;
  v_ch_ini int;
  v_ch_fin int;
  g        record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regprocedure('public._arreglo_validar_desde(date)') IS NULL
     OR to_regprocedure('public._rendicion_efectivo_a_entregar(bigint,uuid,date)') IS NULL
     OR to_regprocedure('public._rubro_es_sueldo(text)') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existen las funciones nuevas (falta la migracion 488)';
  END IF;

  -- --------------------------------------------------------- contexto ---
  SELECT pf.id INTO v_a1 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_t]
   ORDER BY pf.id LIMIT 1;
  SELECT id INTO v_varios FROM gasto_rubros WHERE lower(btrim(nombre)) = 'varios' AND activo;
  SELECT id INTO v_falt FROM gasto_rubros WHERE lower(btrim(nombre)) = 'faltantes de caja';
  IF v_a1 IS NULL OR v_varios IS NULL OR v_falt IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: a1 %, rubro varios %, rubro faltantes %', v_a1, v_varios, v_falt;
  END IF;
  PERFORM set_config('g1521.a1', v_a1::text, true);

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

  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text)
  RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;

  CREATE FUNCTION pg_temp.claims(p_user uuid, p_suc bigint)
  RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  $f$;

  CREATE FUNCTION pg_temp.adm()
  RETURNS void LANGUAGE sql AS $f$
    SELECT pg_temp.claims(current_setting('g1521.a1')::uuid, 1);
  $f$;

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint)
  RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE
    v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'g1521-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), '{}', now(), now());
    RETURN v;
  END
  $f$;

  -- El alta como ModalEmpleado: el primer arreglo, semanal, desde p_desde.
  CREATE FUNCTION pg_temp.alta_sql(p_desde date)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ g1521 ' || gen_random_uuid(), 'puesto', 'preventista', 'sucursal_id', 1, 'de_las_dos', false,
      'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', NULL, 'cliente_id', NULL, 'vehiculo_id', NULL,
      'arreglo', jsonb_build_object('vigente_desde', p_desde, 'sueldo', 70000, 'frecuencia', 'semanal', 'comisiona', false),
      'saldo_inicial', NULL));
  $f$;

  CREATE FUNCTION pg_temp.alta(p_desde date)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(current_setting('g1521.a1')::uuid, 1, pg_temp.alta_sql(p_desde))::bigint;
  $f$;

  -- guardar_arreglo_empleado como ModalArregloEmpleado (con id, «Corregir el vigente»).
  CREATE FUNCTION pg_temp.arr(p_emp bigint, p_desde date, p_sueldo numeric DEFAULT 80000, p_id bigint DEFAULT NULL)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_arreglo_empleado(p_empleado_id => %s, p_arreglo => %L::jsonb)', p_emp,
      jsonb_build_object('vigente_desde', p_desde, 'sueldo', p_sueldo, 'frecuencia', 'semanal', 'comisiona', false)
      || CASE WHEN p_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('id', p_id) END);
  $f$;

  CREATE FUNCTION pg_temp.mov(p_emp bigint, p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_movimiento_empleado(p_empleado_id => %s, p_movimiento => %L::jsonb)', p_emp, p);
  $f$;

  CREATE FUNCTION pg_temp.rev(p_mov bigint)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.revertir_movimiento_empleado(p_movimiento_id => %s, p_motivo => %L)', p_mov, 'Ensayo 1521');
  $f$;

  CREATE FUNCTION pg_temp.plata(p_t uuid, p_d date)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('origen_pago', 'rendicion', 'rendicion_transportista_id', p_t, 'rendicion_fecha', p_d);
  $f$;

  CREATE FUNCTION pg_temp.pv(p_emp bigint)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(current_setting('g1521.a1')::uuid, 1,
                        format('SELECT public.previsualizar_liquidacion(p_empleado_id => %s)', p_emp))::jsonb;
  $f$;

  -- Liquida el proximo periodo como ModalLiquidar, pagando p_pago con la plata de p_plata.
  CREATE FUNCTION pg_temp.lq(p_emp bigint, p_pago numeric, p_plata jsonb)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(current_setting('g1521.a1')::uuid, 1, format(
      'SELECT public.liquidar_empleado(p_empleado_id => %s, p_liquidacion => %L::jsonb)', p_emp,
      jsonb_build_object('desde', v#>>'{periodo,desde}', 'hasta', v#>>'{periodo,hasta}',
                         'sueldo', (v#>>'{sueldo,propuesto}')::numeric, 'motivo_sueldo', NULL, 'pago', p_pago,
                         'fecha_pago', public._tablero_hoy(), 'a_pagar_esperado', (v->>'a_pagar')::numeric)
      || p_plata))::bigint
      FROM (SELECT pg_temp.pv(p_emp) AS v) x;
  $f$;

  CREATE FUNCTION pg_temp.an(p_liq bigint)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.anular_liquidacion(p_liquidacion_id => %s, p_motivo => %L)', p_liq, 'Ensayo 1521');
  $f$;

  CREATE FUNCTION pg_temp.saldo(p_emp bigint)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos WHERE empleado_id = p_emp;
  $f$;

  -- Un cobro del chofer ese dia, sobre el pedido del ensayo.
  CREATE FUNCTION pg_temp.cobro(p_t uuid, p_d date, p_monto numeric, p_forma text DEFAULT 'efectivo')
  RETURNS void LANGUAGE sql AS $f$
    SELECT pg_temp.adm();
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (current_setting('g1521.c1')::bigint, current_setting('g1521.ped')::bigint, p_monto, p_forma, p_d, p_t, 1);
  $f$;

  -- guardar_gasto como ModalGasto, desde la oficina, con lo que cambie p.
  CREATE FUNCTION pg_temp.gg(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)',
      jsonb_build_object('sucursal_id', 1, 'compartido', false, 'fecha', public._tablero_hoy(),
                         'rubro_id', current_setting('g1521.varios')::bigint, 'monto_total', 1000,
                         'comprobante', 'ninguno', 'comprobante_numero', NULL, 'vehiculo_id', NULL,
                         'repartir_meses', 1, 'origen_pago', 'oficina', 'observacion', 'ensayo 1521') || p);
  $f$;

  CREATE FUNCTION pg_temp.rub(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_rubro_gasto(p_rubro => %L::jsonb)', p);
  $f$;

  -- Lo que vio el modal del cierre: los gastos vivos de la rendicion.
  CREATE FUNCTION pg_temp.vis(p_d date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', g.id, 'updated_at', g.updated_at) ORDER BY g.id), '[]'::jsonb)
      FROM gastos g
     WHERE g.origen_pago = 'rendicion' AND g.sucursal_id = 1 AND g.rendicion_transportista_id = p_t
       AND g.rendicion_fecha = p_d AND g.anulado_at IS NULL;
  $f$;

  -- La fila de la rendicion en el resumen: lo que suma el front.
  CREATE FUNCTION pg_temp.fila(p_d date, p_t uuid)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(current_setting('g1521.a1')::uuid, 1, format(
      'SELECT to_jsonb(r) FROM public.obtener_resumen_rendiciones(p_fecha_desde => %L::date, p_fecha_hasta => %L::date, p_transportista_id => %L::uuid) r',
      p_d, p_d, p_t))::jsonb;
  $f$;

  -- El efectivo a entregar como lo calcula el cierre en el front.
  CREATE FUNCTION pg_temp.a_entregar(p_d date, p_t uuid)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT (f->>'total_efectivo')::numeric - (f->>'total_gastos')::numeric - (f->>'total_pagos_personal')::numeric
           - COALESCE((f->>'total_faltantes_empleados')::numeric, 0)
      FROM (SELECT pg_temp.fila(p_d, p_t) AS f) x;
  $f$;

  CREATE FUNCTION pg_temp.audit(p_adm uuid, p_suc bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.claims(p_adm, p_suc);
    RETURN public.auditoria_integridad();
  END
  $f$;

  IF cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'otro mensaje')) <> 1
     OR pg_temp.como(v_a1, v_t, 'SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_a1, v_t)
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  v_ch_ini := (pg_temp.audit(v_a1, v_t)->>'critical_high_en_rojo')::int;

  PERFORM set_config('g1521.varios', v_varios::text, true);
  PERFORM pg_temp.adm();
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ g1521 C1', 'ZZ g1521 C1', 'Ensayo', v_t) RETURNING id INTO c1;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ g1521 A', 100, 100000, 60, v_t) RETURNING id INTO v_prod;
  INSERT INTO pedidos (cliente_id, sucursal_id, fecha, total, usuario_id, creado_por)
  VALUES (c1, v_t, v_hoy - 10, 0, v_a1, v_a1) RETURNING id INTO v_ped;
  INSERT INTO pedido_items (pedido_id, sucursal_id, producto_id, cantidad, precio_unitario, subtotal, costo_unitario_al_crear)
  VALUES (v_ped, v_t, v_prod, 10000, 100, 1000000, 60);
  UPDATE pedidos SET total = 1000000 WHERE id = v_ped;
  UPDATE pedidos SET estado = 'entregado', retiro_deposito = true,
                     fecha_entrega = ((v_hoy - 10) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id = v_ped;
  PERFORM set_config('g1521.c1', c1::text, true);
  PERFORM set_config('g1521.ped', v_ped::text, true);

  v_tra := pg_temp.u('transportista', v_t);
  v_trb := pg_temp.u('transportista', v_t);
  v_trc := pg_temp.u('transportista', v_t);
  -- Todos los cobros antes de cerrar nada: un dia cerrado mueve los de antes.
  PERFORM pg_temp.cobro(v_trb, d8, 15000);
  PERFORM pg_temp.cobro(v_trb, d8, 7000, 'transferencia');
  PERFORM pg_temp.cobro(v_trc, d9, 10000);

  -- ============================================== 1 · GTO-3 el tope del alta ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('1 alta 61 dias adelante', v_a1, v_t, pg_temp.alta_sql(v_hoy + 61),
                  'hasta 60 días antes o después de hoy');
    v_fallas := v_fallas || pg_temp.falla('1 alta 61 dias atras', v_a1, v_t, pg_temp.alta_sql(v_hoy - 61),
                  format('entre el %s y el %s', to_char(v_hoy - 60, 'DD/MM/YYYY'), to_char(v_hoy + 60, 'DD/MM/YYYY')));
    e1 := pg_temp.alta(v_hoy - 60);
    v_n := pg_temp.alta(v_hoy + 60);
    v_fallas := v_fallas || pg_temp.chk(e1 IS NOT NULL AND v_n IS NOT NULL
                  AND (SELECT vigente_desde FROM empleado_arreglos WHERE empleado_id = e1) = v_hoy - 60
                  AND (SELECT vigente_desde FROM empleado_arreglos WHERE empleado_id = v_n) = v_hoy + 60, '1 los bordes entran');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  -- =========================================== 2 · GTO-3 el arreglo nuevo ===
  BEGIN
    SELECT id INTO a1 FROM empleado_arreglos WHERE empleado_id = e1;
    v_fallas := v_fallas || pg_temp.falla('2 nuevo 61 dias adelante', v_a1, v_t, pg_temp.arr(e1, v_hoy + 61),
                  'hasta 60 días antes o después de hoy');
    a2 := pg_temp.como(v_a1, v_t, pg_temp.arr(e1, v_hoy + 30))::bigint;
    v_fallas := v_fallas || pg_temp.falla('2 antes del vigente', v_a1, v_t, pg_temp.arr(e1, v_hoy + 10),
                  'para cambiarle la fecha al vigente, elegí «Corregir el vigente»');
    v_n := pg_temp.como(v_a1, v_t, pg_temp.arr(e1, v_hoy + 30, 90000))::bigint;
    v_fallas := v_fallas || pg_temp.chk(v_n = a2 AND (SELECT sueldo FROM empleado_arreglos WHERE id = a2) = 90000
                  AND (SELECT count(*) FROM empleado_arreglos WHERE empleado_id = e1) = 2, '2 la misma fecha corrige el vigente');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- ========================================== 3 · GTO-3 corregir la fecha ===
  BEGIN
    v_n := pg_temp.como(v_a1, v_t, pg_temp.arr(e1, v_hoy + 20, 95000, a2))::bigint;
    v_fallas := v_fallas || pg_temp.chk(v_n = a2 AND (SELECT vigente_desde = v_hoy + 20 AND sueldo = 95000 FROM empleado_arreglos WHERE id = a2)
                  AND (SELECT count(*) FROM empleado_arreglos WHERE empleado_id = e1) = 2, '3 corrige la fecha del ultimo');
    v_fallas := v_fallas || pg_temp.falla('3 no es el ultimo', v_a1, v_t, pg_temp.arr(e1, v_hoy - 50, 80000, a1),
                  'Sólo se corrige el último arreglo del empleado');
    v_fallas := v_fallas || pg_temp.falla('3 sobre el anterior', v_a1, v_t, pg_temp.arr(e1, v_hoy - 60, 80000, a2),
                  format('vale desde después del anterior (%s)', to_char(v_hoy - 60, 'DD/MM/YYYY')));
    v_fallas := v_fallas || pg_temp.falla('3 fuera del tope', v_a1, v_t, pg_temp.arr(e1, v_hoy + 61, 80000, a2),
                  'hasta 60 días antes o después de hoy');
    v_fallas := v_fallas || pg_temp.falla('3 id de otro empleado', v_a1, v_t, pg_temp.arr(e1, v_hoy + 20, 80000, -1),
                  'Sólo se corrige el último arreglo del empleado');

    -- Un arreglo viejo, de antes del tope: con su misma fecha se corrige, con o sin id.
    PERFORM pg_temp.adm();
    INSERT INTO empleados (sucursal_id, nombre, puesto, creado_por) VALUES (v_t, 'ZZ g1521 viejo', 'preventista', v_a1)
    RETURNING id INTO ev;
    INSERT INTO empleado_arreglos (empleado_id, vigente_desde, sueldo, frecuencia, comisiona, creado_por)
    VALUES (ev, v_hoy - 100, 50000, 'semanal', false, v_a1) RETURNING id INTO av;
    v_n := pg_temp.como(v_a1, v_t, pg_temp.arr(ev, v_hoy - 100, 51000))::bigint;
    v_fallas := v_fallas || pg_temp.chk(v_n = av AND (SELECT sueldo FROM empleado_arreglos WHERE id = av) = 51000, '3 el viejo sin id');
    v_n := pg_temp.como(v_a1, v_t, pg_temp.arr(ev, v_hoy - 100, 52000, av))::bigint;
    v_fallas := v_fallas || pg_temp.chk(v_n = av AND (SELECT sueldo FROM empleado_arreglos WHERE id = av) = 52000, '3 el viejo con id');
    v_fallas := v_fallas || pg_temp.falla('3 el viejo a otra fecha fuera del tope', v_a1, v_t, pg_temp.arr(ev, v_hoy - 90, 52000, av),
                  'hasta 60 días antes o después de hoy');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ================================== 4 · GTO-3 lo liquidado no se mueve ===
  BEGIN
    e3 := pg_temp.alta(v_hoy - 14);
    SELECT id INTO a1 FROM empleado_arreglos WHERE empleado_id = e3;
    v_liq := pg_temp.lq(e3, 0, '{"origen_pago":"oficina"}');
    v_fallas := v_fallas || pg_temp.falla('4 corregir el liquidado', v_a1, v_t, pg_temp.arr(e3, v_hoy - 13, 70000, a1),
                  'Ya se liquidó hasta el');
    v_fallas := v_fallas || pg_temp.chk((SELECT vigente_desde FROM empleado_arreglos WHERE id = a1) = v_hoy - 14, '4 quedo escrito');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ======================================= 5 · GTO-4 el pago de la anulada ===
  BEGIN
    e4 := pg_temp.alta(v_hoy - 14);
    v_m := round((pg_temp.pv(e4)->>'a_pagar')::numeric / 2, 2);
    v_liq := pg_temp.lq(e4, v_m, pg_temp.plata(v_tra, d4));
    SELECT id INTO v_mov FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'pago';
    PERFORM pg_temp.adm();
    INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, controlada_por)
    VALUES (d4, v_tra, v_t, 'confirmada', v_a1);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.an(v_liq));
    v_fallas := v_fallas || pg_temp.chk(v_m > 0 AND v_mov IS NOT NULL AND pg_temp.saldo(e4) = -v_m
                  AND NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE revierte_id = v_mov), '5 el pago sobrevive a la anulacion');

    -- Con la rendicion cerrada se corrige con un ajuste, como un pago suelto.
    v_fallas := v_fallas || pg_temp.falla('5 con la rendicion cerrada', v_a1, v_t, pg_temp.rev(v_mov),
                  'Ese pago salió de una rendición ya cerrada: no se revierte, corregilo con un ajuste');
    -- Reabierta, se revierte, y la plata vuelve a la rendicion.
    PERFORM pg_temp.adm();
    UPDATE rendiciones_control SET estado = 'pendiente' WHERE fecha = d4 AND transportista_id = v_tra AND sucursal_id = v_t;
    v_n := pg_temp.como(v_a1, v_t, pg_temp.rev(v_mov))::bigint;
    SELECT * INTO g FROM empleado_movimientos WHERE id = v_n;
    v_fallas := v_fallas || pg_temp.chk(g.revierte_id = v_mov AND g.monto = v_m AND g.tipo = 'pago'
                  AND g.rendicion_transportista_id = v_tra AND g.rendicion_fecha = d4 AND pg_temp.saldo(e4) = 0
                  AND public._rendicion_efectivo_a_entregar(v_t, v_tra, d4) = 0, format('5 reabierta se revierte: %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.falla('5 dos veces', v_a1, v_t, pg_temp.rev(v_mov), 'Ese movimiento ya está revertido');

    -- El pago de una liquidacion viva se sigue revirtiendo anulandola.
    v_m := round((pg_temp.pv(e4)->>'a_pagar')::numeric / 2, 2);
    v_liq := pg_temp.lq(e4, v_m, '{"origen_pago":"oficina"}');
    SELECT id INTO v_mov FROM empleado_movimientos WHERE liquidacion_id = v_liq AND tipo = 'pago';
    v_fallas := v_fallas || pg_temp.falla('5 la liquidacion viva', v_a1, v_t, pg_temp.rev(v_mov),
                  'Un pago de una liquidación se revierte anulando la liquidación');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- ================================== 6 · GTO-6 la fecha y el mes del gasto ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('6 fecha futura', v_a1, v_t,
                  pg_temp.gg(jsonb_build_object('fecha', v_hoy + 1)), 'La fecha del gasto no puede ser futura');
    v_fallas := v_fallas || pg_temp.falla('6 trece meses antes', v_a1, v_t,
                  pg_temp.gg(jsonb_build_object('mes_imputado', (v_mes - interval '13 months')::date)),
                  'El mes imputado va de 12 meses antes a 1 después del mes de la fecha del gasto');
    v_fallas := v_fallas || pg_temp.falla('6 dos meses despues', v_a1, v_t,
                  pg_temp.gg(jsonb_build_object('mes_imputado', (v_mes + interval '2 months')::date)),
                  'El mes imputado va de 12 meses antes a 1 después');
    v_n := pg_temp.como(v_a1, v_t, pg_temp.gg(jsonb_build_object('mes_imputado', (v_mes - interval '12 months')::date)))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT mes_imputado FROM gastos WHERE id = v_n) = (v_mes - interval '12 months')::date,
                  '6 doce meses antes entra');
    v_n := pg_temp.como(v_a1, v_t, pg_temp.gg(jsonb_build_object('mes_imputado', (v_mes + interval '1 month')::date)))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT mes_imputado FROM gastos WHERE id = v_n) = (v_mes + interval '1 month')::date,
                  '6 el mes que viene entra');
    -- Una edicion pasa por las mismas reglas.
    v_fallas := v_fallas || pg_temp.falla('6 editar a futura', v_a1, v_t,
                  pg_temp.gg(jsonb_build_object('id', v_n, 'fecha', v_hoy + 1)), 'La fecha del gasto no puede ser futura');
    -- El reintegro al empleado nace con la fecha del gasto, que ya no puede ser futura.
    v_n := pg_temp.como(v_a1, v_t, pg_temp.gg(jsonb_build_object('origen_pago', 'empleado', 'empleado_id', e1)))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT fecha FROM empleado_movimientos WHERE gasto_id = v_n AND tipo = 'reintegro') = v_hoy,
                  '6 el reintegro con la fecha del gasto');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- =================================== 7 · GTO-8 el tope del pago suelto ===
  BEGIN
    e8 := pg_temp.alta(v_hoy - 14);
    v_fallas := v_fallas || pg_temp.falla('7 sin saldo', v_a1, v_t, pg_temp.mov(e8, '{"tipo":"pago","monto":10}'),
                  'No se le puede pagar más de lo que se le debe: si le adelantás plata, cargá un adelanto');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.mov(e8, '{"tipo":"ajuste","monto":50000,"observacion":"ensayo 1521"}'));
    v_fallas := v_fallas || pg_temp.falla('7 un centavo de mas', v_a1, v_t, pg_temp.mov(e8, '{"tipo":"pago","monto":50000.01}'),
                  'No se le puede pagar más de lo que se le debe');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.mov(e8, '{"tipo":"pago","monto":30000}'));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e8) = 20000, '7 el pago justo entra');

    -- De una rendicion: el efectivo (15000; la transferencia no cuenta), no el saldo.
    v_fallas := v_fallas || pg_temp.chk(public._rendicion_efectivo_a_entregar(v_t, v_trb, d8) = 15000
                  AND pg_temp.a_entregar(d8, v_trb) = 15000,
                  format('7 efectivo a entregar: %s y el front %s', public._rendicion_efectivo_a_entregar(v_t, v_trb, d8), pg_temp.a_entregar(d8, v_trb)));
    v_fallas := v_fallas || pg_temp.falla('7 mas que el efectivo', v_a1, v_t,
                  pg_temp.mov(e8, '{"tipo":"pago","monto":20000}'::jsonb || pg_temp.plata(v_trb, d8)),
                  'El pago supera el efectivo que le queda por entregar a esa rendición');
    v_mov := pg_temp.como(v_a1, v_t, pg_temp.mov(e8, '{"tipo":"pago","monto":15000}'::jsonb || pg_temp.plata(v_trb, d8)))::bigint;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e8) = 5000 AND public._rendicion_efectivo_a_entregar(v_t, v_trb, d8) = 0
                  AND pg_temp.a_entregar(d8, v_trb) = 0, '7 el efectivo justo entra');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.mov(e8, '{"tipo":"ajuste","monto":10000,"observacion":"ensayo 1521"}'));
    v_fallas := v_fallas || pg_temp.falla('7 la rendicion sin efectivo', v_a1, v_t,
                  pg_temp.mov(e8, '{"tipo":"pago","monto":1}'::jsonb || pg_temp.plata(v_trb, d8)),
                  'El pago supera el efectivo que le queda por entregar a esa rendición');
    -- Revertir el pago devuelve el efectivo.
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rev(v_mov));
    v_fallas := v_fallas || pg_temp.chk(public._rendicion_efectivo_a_entregar(v_t, v_trb, d8) = 15000, '7 revertir devuelve el efectivo');
    -- El adelanto no tiene tope: deja el saldo negativo, como siempre.
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.mov(e8, '{"tipo":"adelanto","monto":100000}'));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e8) = -70000, format('7 el adelanto: saldo %s', pg_temp.saldo(e8)));
    v_fallas := v_fallas || pg_temp.falla('7 con saldo negativo', v_a1, v_t, pg_temp.mov(e8, '{"tipo":"pago","monto":1}'),
                  'No se le puede pagar más de lo que se le debe');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- ===================================== 8 · GTO-9 los nombres de sueldo ===
  BEGIN
    FOREACH v_txt IN ARRAY ARRAY['Haberes', 'Aguinaldo diciembre', 'Pago de SAC', 'Horas extra', 'Indemnización',
                                 'VACACIONES', 'Salario', 'Sueldos de octubre', 'Jornales', 'Presentismo']
    LOOP
      v_fallas := v_fallas || pg_temp.falla(format('8 %s', v_txt), v_a1, v_t,
                    pg_temp.rub(jsonb_build_object('nombre', 'ZZ ' || v_txt || ' 1521', 'grupo', 'otros')),
                    'Los sueldos no son un gasto: salen de las liquidaciones del personal');
    END LOOP;
    FOREACH v_txt IN ARRAY ARRAY['Cargas sociales', 'Comisiones bancarias', 'Sacos de arpillera', 'Sindicato', 'ART']
    LOOP
      v_n := pg_temp.como(v_a1, v_t, pg_temp.rub(jsonb_build_object('nombre', 'ZZ ' || v_txt || ' 1521', 'grupo', 'otros')))::bigint;
      v_fallas := v_fallas || pg_temp.chk(v_n IS NOT NULL, format('8 %s entra', v_txt));
    END LOOP;
    -- El CHECK es la misma regla.
    BEGIN
      INSERT INTO gasto_rubros (nombre, grupo) VALUES ('ZZ Salarios 1521', 'otros');
      v_fallas := v_fallas || '8 el CHECK dejo entrar Salarios'::text;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    -- Renombrar a un nombre de sueldo tampoco.
    v_fallas := v_fallas || pg_temp.falla('8 renombrar a haberes', v_a1, v_t,
                  pg_temp.rub(jsonb_build_object('id', v_varios, 'nombre', 'Varios y haberes')),
                  'Los sueldos no son un gasto');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ================================ 9 · GTO-9 el rubro de los faltantes ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk((SELECT clave FROM gasto_rubros WHERE id = v_falt) = 'faltantes_caja'
                  AND (SELECT count(*) FROM gasto_rubros WHERE clave IS NOT NULL) = 1, '9 la clave');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.rub(jsonb_build_object('id', v_falt, 'nombre', 'ZZ Robos y pérdidas 1521')));
    v_fallas := v_fallas || pg_temp.falla('9 darlo de baja', v_a1, v_t, pg_temp.rub(jsonb_build_object('id', v_falt, 'activo', false)),
                  'es el de los faltantes de caja de las rendiciones: se le puede cambiar el nombre, pero no darlo de baja');
    v_fallas := v_fallas || pg_temp.chk((SELECT activo AND nombre = 'ZZ Robos y pérdidas 1521' FROM gasto_rubros WHERE id = v_falt),
                  '9 renombrado y activo');
    -- Renombrado, resolver_rendicion lo sigue encontrando.
    PERFORM pg_temp.como(v_a1, v_t, format('SELECT public.confirmar_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, '
                  || 'p_estado => %L, p_observaciones => NULL, p_gastos_rendicion => %L::jsonb)', d9, v_trc, 'disconformidad',
                  jsonb_build_object('vistos', pg_temp.vis(d9, v_trc))));
    PERFORM pg_temp.como(v_a1, v_t, format('SELECT public.resolver_rendicion(p_fecha => %L::date, p_transportista_id => %L::uuid, '
                  || 'p_observaciones => %L, p_resolucion => %L::jsonb)', d9, v_trc, 'ensayo 1521',
                  jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('causal', 'robo_perdida', 'monto', 1000,
                                                                                    'observacion', 'ensayo 1521')),
                                     'vistos', pg_temp.vis(d9, v_trc), 'pagos_personal_visto', 0)));
    SELECT gs.* INTO g FROM gastos gs JOIN rendicion_faltantes f ON f.gasto_id = gs.id
     WHERE f.causal = 'robo_perdida' AND f.rendicion_fecha = d9 AND f.rendicion_transportista_id = v_trc;
    v_fallas := v_fallas || pg_temp.chk(g.rubro_id = v_falt AND g.monto_total = 1000 AND g.fecha = d9,
                  format('9 el robo va al rubro de la clave: %s', to_jsonb(g)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ===================================== 10 · invariantes y auditoria ===
  BEGIN
    SELECT count(*) INTO v_n FROM empleado_arreglos a
     WHERE a.created_at >= now() AND (a.vigente_desde < v_hoy - 60 OR a.vigente_desde > v_hoy + 60)
       AND a.id <> av;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('10 %s arreglos del ensayo fuera del tope', v_n));
    v_j := pg_temp.audit(v_a1, v_t);
    v_ch_fin := (v_j->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin = v_ch_ini, format('10 critical_high_en_rojo paso de %s a %s: %s', v_ch_ini, v_ch_fin,
                  (SELECT array_agg(c->>'id') FROM jsonb_array_elements(v_j->'checks') c
                    WHERE (c->>'ok')::boolean IS FALSE AND c->>'severidad' IN ('critical', 'high'))));
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j->'checks') c
     WHERE c->>'id' IN ('EMP-A', 'EMP-B', 'EMP-C', 'GASTO-A') AND (c->>'ok')::boolean;
    v_fallas := v_fallas || pg_temp.chk(v_n = 4, format('10 EMP-A a EMP-C y GASTO-A en verde: %s de 4', v_n));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gastos y personal 1521: casos 1 a 10; critical_high_en_rojo % al empezar y % al final',
    v_ch_ini, v_ch_fin;
END
$ensayo$;
