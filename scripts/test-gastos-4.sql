-- Ensayo de la migracion gastos_4_personal (entrega 3 de 5 de gastos: los
-- empleados, su arreglo y su cuenta, con la mercaderia y el reintegro que
-- entran solos por trigger).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (empleados, clientes, pedido, pagos,
-- gastos) se deshace. Lo que tiene que fallar corre en un subbloque que se
-- revierte solo.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR (no existe listar_personal); despues,
-- pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/NNN_gastos_4_personal.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Cada RPC se llama COMO EL FRONT (pg_temp.como): SET LOCAL ROLE authenticated,
-- los claims del usuario y el header x-sucursal-id, con los argumentos por
-- nombre como PostgREST y el payload entero de GuardarEmpleadoPayload. Lo que
-- "se cambia a mano" (pagos partidos, borrados o que cambian de cliente) corre
-- como postgres, que es como lo hacen las RPCs DEFINER de cobros.
--
-- Usuarios elegidos en runtime (perfiles + usuario_sucursales):
--   T     · Tucuman (1) y TP, Taco Pozo (2): las dos sucursales activas
--   a1    · un admin con SOLO T; at, uno con SOLO TP; ad, uno de las dos
--   en    · un encargado activo (hoy el unico es de TP)
--   tr    · un transportista activo de T
-- Clientes, pedido, vehiculos y empleados los crea el ensayo: C1, C3 y CX en T,
-- C2 en TP, y un pedido pendiente de 15000 de C1.
--
--   1  alta y visibilidad: a1 da de alta a E1 (semanal desde el lunes, saldo
--      al empezar -5000); at no lo ve ni lee su cuenta; a1 no carga uno de las
--      dos; ad carga a E2 de las dos y a1 no lo ve; en y tr reciben 42501 en
--      listar_personal; empleados_para_elegir le da a en solo cinco claves
--   2  vinculos: E1 con tr, C1 y un vehiculo de T anda; usuario y cliente
--      repetidos, usuario sin la sucursal, cliente y vehiculo de TP fallan;
--      E2 (de las dos) con C2 anda
--   3  uno mismo: a1 no se da de alta; sobre E3 (con el usuario de a1, cargado
--      por ad) a1 no carga movimientos, ni arreglo, ni baja, ni toca el usuario,
--      pero si el telefono; tampoco un gasto que pago E3, ni borra por REST un
--      adelanto de la ficha de E3
--   4  mercaderia: FIFO con adelanto de 10000 sobre C1 deja -10000 en E1 con su
--      pago y su pedido; sobre CX se rechaza; en efectivo no deja nada
--   5  sigue al pago: a 7000 deja +3000; partido (4000 + pedazo de 3000) la
--      familia da -7000; borrar el pedazo y la raiz la deja en 0
--   5b el pedazo va a su cliente: FIFO, aplicar_credito_cliente y
--      cambiar_cliente_pedido (con _pagos_excedente_a_favor) reales, y al
--      reves a mano; cada empleado termina en -(lo vivo de sus fichas)
--   6  historicos: con el cliente 376 vinculado, cambiar el 7777, borrar el
--      7776 y partir el 7775 no deja nada ni rechaza nada
--   6b REST directo: un adelanto con pago_origen_id (de un historico o del
--      libro) se rechaza; sin el, la regla de siempre
--   7  cambio de cliente: a CX se rechaza; a C3 (de E4) pasa el movimiento, y
--      un cambio de monto despues lo sigue en E4
--   8  reintegro: 8000 de E1, a 9000, a E2, anulado; uno de la oficina no deja
--      nada; uno que pasa a la oficina compensa; en carga uno de E2 en TP; sin
--      empleado y con uno de TP fallan
--   9  a mano: adelanto, ajustes, reversiones y sus rechazos; fecha futura
--   10 arreglos: anterior, el mismo dia (corrige), posterior y vigente_hasta
--   11 baja: futura, antes del primer arreglo, la baja, otra vez, el adelanto
--      y el gasto rechazados, el arreglo rechazado, un ajuste anda, reactivar
--   12 GAS-1: editar sin litros ni km los conserva (y la lectura sigue la
--      fecha); con null los borra; con un rubro que no los pide, se van
--   13 permisos: tablas sin privilegios ni policies, EXECUTE, SEG-A, fechas UTC
--   14 invariantes EMP-A y EMP-B (de #1330) y critical_high_en_rojo
--
--   psql "$DATABASE_URL" -f scripts/test-gastos-4.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_hoy     date := public._tablero_hoy();
  v_lunes   date := date_trunc('week', public._tablero_hoy()::timestamp)::date;
  v_t       bigint := 1;
  v_tp      bigint := 2;
  v_a1      uuid;
  v_at      uuid;
  v_ad      uuid;
  v_en      uuid;
  v_tr      uuid;
  r_lib     bigint;
  r_comb    bigint;
  v_veh     bigint;
  v_veh_tp  bigint;
  c1        bigint;
  c2        bigint;
  c3        bigint;
  cx        bigint;
  v_prod    bigint;
  v_ped     bigint;
  e1        bigint;
  e2        bigint;
  e3        bigint;
  e4        bigint;
  e5        bigint;
  e7        bigint;
  p1        bigint;
  p2        bigint;
  pz        bigint;
  g1        bigint;
  g2        bigint;
  g_of      bigint;
  g_en      bigint;
  g_comb    bigint;
  m1        bigint;
  m_rev     bigint;
  m_aj      bigint;
  m_merc    bigint;
  c4        bigint;
  c5        bigint;
  c6        bigint;
  e6        bigint;
  e8        bigint;
  e9        bigint;
  v_ped5    bigint;
  v_s       bigint;
  v_z       bigint;
  v_w       bigint;
  v_s2      bigint;
  v_z2      bigint;
  v_w2      bigint;
  v_pe3     bigint;
  v_emp     jsonb;
  v_arr     jsonb;
  v_gasto   jsonb;
  v_comb    jsonb;
  v_j       jsonb;
  v_txt     text;
  v_n       int;
  v_m       numeric;
  v_ch_ini  int;
  v_ch_fin  int;
  g         record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regprocedure('public.listar_personal()') IS NULL OR to_regclass('public.empleado_movimientos') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existen listar_personal ni empleado_movimientos (falta la migracion gastos_4)';
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
  SELECT pf.id INTO v_en FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'encargado' AND pf.activo AND us.sucursal_id = v_tp ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_tr FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'transportista' AND pf.activo AND us.sucursal_id = v_t ORDER BY pf.id LIMIT 1;
  SELECT id INTO r_lib FROM gasto_rubros WHERE nombre = 'Librería' AND activo AND NOT pide_litros_km;
  SELECT id INTO r_comb FROM gasto_rubros WHERE nombre = 'Combustible' AND activo AND pide_litros_km;
  IF v_a1 IS NULL OR v_at IS NULL OR v_ad IS NULL OR v_en IS NULL OR v_tr IS NULL OR r_lib IS NULL OR r_comb IS NULL
     OR NOT EXISTS (SELECT 1 FROM sucursales WHERE id = v_t AND activa)
     OR NOT EXISTS (SELECT 1 FROM sucursales WHERE id = v_tp AND activa)
     OR (SELECT count(*) FROM sucursales WHERE activa) <> 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: a1 %, at %, ad %, en %, tr %, rubros % %', v_a1, v_at, v_ad, v_en, v_tr, r_lib, r_comb;
  END IF;

  -- Como el front: rol authenticated, claims y header. Con p_user NULL corre
  -- como postgres (lo que en prod hacen las RPCs DEFINER de cobros).
  CREATE FUNCTION pg_temp.como(p_user uuid, p_suc bigint, p_sql text)
  RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    IF p_user IS NULL THEN
      EXECUTE p_sql INTO v;
      RETURN v;
    END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  END
  $f$;

  -- Lo que tiene que fallar con un mensaje que contenga p_espera. Si anda, lo
  -- deshace (P0098) y lo anota.
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

  -- El SQLSTATE con que falla, o 'OK' (y lo deshace).
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

  CREATE FUNCTION pg_temp.ge(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', p);
  $f$;

  CREATE FUNCTION pg_temp.gg(p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)', p);
  $f$;

  CREATE FUNCTION pg_temp.mov(p_emp bigint, p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_movimiento_empleado(p_empleado_id => %s, p_movimiento => %L::jsonb)', p_emp, p);
  $f$;

  CREATE FUNCTION pg_temp.rev(p_mov bigint, p_motivo text)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.revertir_movimiento_empleado(p_movimiento_id => %s, p_motivo => %L)', p_mov, p_motivo);
  $f$;

  CREATE FUNCTION pg_temp.arr(p_emp bigint, p jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_arreglo_empleado(p_empleado_id => %s, p_arreglo => %L::jsonb)', p_emp, p);
  $f$;

  -- registrar_pago_cliente_fifo como ModalRegistrarPago desde la ficha.
  CREATE FUNCTION pg_temp.fifo(p_cli bigint, p_monto numeric, p_forma text)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_pago_cliente_fifo(p_cliente_id => %s, p_monto => %s, p_forma_pago => %L, '
                  || 'p_fecha => %L::date, p_referencia => NULL, p_notas => NULL, p_client_request_id => %L::uuid)',
                  p_cli, p_monto, p_forma, public._tablero_hoy(), gen_random_uuid());
  $f$;

  CREATE FUNCTION pg_temp.lista(p_user uuid, p_suc bigint)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, 'SELECT public.listar_personal()')::jsonb;
  $f$;

  CREATE FUNCTION pg_temp.ids(p jsonb)
  RETURNS bigint[] LANGUAGE sql AS $f$
    SELECT COALESCE(array_agg((e->>'id')::bigint ORDER BY (e->>'id')::bigint), '{}') FROM jsonb_array_elements(p) e;
  $f$;

  CREATE FUNCTION pg_temp.cuenta(p_user uuid, p_suc bigint, p_emp bigint)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_user, p_suc, format('SELECT public.obtener_cuenta_empleado(p_empleado_id => %s)', p_emp))::jsonb;
  $f$;

  -- Lo que hay en la cuenta, leido de la tabla (postgres).
  CREATE FUNCTION pg_temp.saldo(p_emp bigint)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos WHERE empleado_id = p_emp;
  $f$;

  CREATE FUNCTION pg_temp.de_pagos(p_pagos bigint[], p_emp bigint)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos
     WHERE pago_id = ANY (p_pagos) AND (p_emp IS NULL OR empleado_id = p_emp);
  $f$;

  CREATE FUNCTION pg_temp.de_gasto(p_gasto bigint, p_emp bigint)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM public.empleado_movimientos
     WHERE gasto_id = p_gasto AND (p_emp IS NULL OR empleado_id = p_emp);
  $f$;

  CREATE FUNCTION pg_temp.ultimo(p_emp bigint)
  RETURNS public.empleado_movimientos LANGUAGE sql AS $f$
    SELECT * FROM public.empleado_movimientos WHERE empleado_id = p_emp ORDER BY id DESC LIMIT 1;
  $f$;

  -- auditoria_integridad() pide un admin en los claims.
  CREATE FUNCTION pg_temp.audit(p_adm uuid, p_suc bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_adm, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    RETURN public.auditoria_integridad();
  END
  $f$;

  -- Canarios de los helpers: sin esto, un falla() que no muerde daria un OK vacio.
  IF cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1', 'x')) <> 1
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'by zero')) <> 0
     OR cardinality(pg_temp.falla('canario', v_a1, v_t, 'SELECT 1/0', 'otro mensaje')) <> 1
     OR cardinality(pg_temp.falla('canario', NULL, NULL, 'SELECT 1/0', 'by zero')) <> 0
     OR pg_temp.estado(v_a1, v_t, 'SELECT 1/0') <> '22012'
     OR pg_temp.estado(v_a1, v_t, 'SELECT 1') <> 'OK'
     OR pg_temp.como(v_a1, v_t, 'SELECT current_user || '' '' || auth.uid() || '' '' || public.current_sucursal_id()')
        IS DISTINCT FROM format('authenticated %s %s', v_a1, v_t)
     OR pg_temp.como(NULL, NULL, 'SELECT current_user') = 'authenticated'
     OR current_user = 'authenticated' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · los helpers del ensayo no hacen lo que dicen';
  END IF;

  v_ch_ini := (pg_temp.audit(v_a1, v_t)->>'critical_high_en_rojo')::int;

  -- Setup como postgres, con el molde de test-gastos-3: clientes, un pedido
  -- pendiente de 15000 de C1 y dos vehiculos.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a1, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_t::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo gastos 4 C1', 'ZZ ensayo gastos 4 C1', 'Ensayo gastos 4', v_t) RETURNING id INTO c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo gastos 4 C2', 'ZZ ensayo gastos 4 C2', 'Ensayo gastos 4', v_tp) RETURNING id INTO c2;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo gastos 4 C3', 'ZZ ensayo gastos 4 C3', 'Ensayo gastos 4', v_t) RETURNING id INTO c3;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo gastos 4 CX', 'ZZ ensayo gastos 4 CX', 'Ensayo gastos 4', v_t) RETURNING id INTO cx;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo gastos 4 C4', 'ZZ ensayo gastos 4 C4', 'Ensayo gastos 4', v_t) RETURNING id INTO c4;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo gastos 4 C5', 'ZZ ensayo gastos 4 C5', 'Ensayo gastos 4', v_t) RETURNING id INTO c5;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo gastos 4 C6', 'ZZ ensayo gastos 4 C6', 'Ensayo gastos 4', v_t) RETURNING id INTO c6;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo gastos 4', 100, 1000, 60, v_t) RETURNING id INTO v_prod;
  v_j := public.crear_pedido_completo(c1, 15000, v_a1,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 150, 'precio_unitario', 100)),
           'ensayo gastos 4');
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no se pudo crear el pedido de C1: %', v_j;
  END IF;
  v_ped := (v_j->>'pedido_id')::bigint;
  v_veh := pg_temp.como(v_a1, v_t,
             format('SELECT public.guardar_vehiculo(%L::jsonb)', '{"patente":"ENS4001","descripcion":"Ensayo gastos 4"}'))::bigint;
  v_veh_tp := pg_temp.como(v_at, v_tp,
             format('SELECT public.guardar_vehiculo(%L::jsonb)', '{"patente":"ENS4002","descripcion":"Ensayo gastos 4 TP"}'))::bigint;

  -- Lo que arma el modal de alta: todas las claves de GuardarEmpleadoPayload.
  v_arr := jsonb_build_object('vigente_desde', v_lunes, 'sueldo', 150000, 'frecuencia', 'semanal', 'comisiona', false);
  v_emp := jsonb_build_object(
    'nombre', 'ZZ Ensayo E1', 'puesto', 'transportista', 'sucursal_id', v_t, 'de_las_dos', false,
    'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL,
    'usuario_id', NULL, 'cliente_id', NULL, 'vehiculo_id', NULL,
    'arreglo', v_arr, 'saldo_inicial', NULL);

  -- ============================================ 1 · alta y visibilidad ===
  BEGIN
    e1 := pg_temp.como(v_a1, v_t, pg_temp.ge(v_emp || jsonb_build_object('saldo_inicial', -5000)))::bigint;
    SELECT * INTO g FROM empleado_movimientos WHERE empleado_id = e1;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e1) = -5000 AND g.tipo = 'ajuste' AND g.observacion = 'Saldo al empezar'
                                        AND g.fecha = v_lunes AND g.creado_por = v_a1
                                        AND (SELECT count(*) FROM empleado_movimientos WHERE empleado_id = e1) = 1,
                  format('1 E1 nacio con saldo %s y %s', pg_temp.saldo(e1), to_jsonb(g)));
    v_j := (SELECT e FROM jsonb_array_elements(pg_temp.lista(v_a1, v_t)) e WHERE (e->>'id')::bigint = e1);
    v_fallas := v_fallas || pg_temp.chk((v_j->>'saldo')::numeric = -5000 AND (v_j->'arreglo'->>'sueldo')::numeric = 150000
                                        AND v_j->'arreglo'->>'frecuencia' = 'semanal' AND v_j->>'arranque' = v_lunes::text
                                        AND NOT (v_j->>'es_propio')::boolean AND (v_j->>'activo')::boolean
                                        AND v_j ? 'usuario' AND v_j ? 'cliente' AND v_j ? 'vehiculo',
                  format('1 a1 lee E1 asi: %s', v_j));
    v_fallas := v_fallas || pg_temp.chk(NOT (e1 = ANY (pg_temp.ids(pg_temp.lista(v_at, v_tp)))),
                  '1 at (solo TP) ve a E1 en listar_personal');
    v_fallas := v_fallas || pg_temp.falla('1 at lee la cuenta de E1', v_at, v_tp,
                  format('SELECT public.obtener_cuenta_empleado(p_empleado_id => %s)', e1), 'Ese empleado no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('1 a1 carga uno de las dos', v_a1, v_t,
                  pg_temp.ge(v_emp || '{"nombre": "ZZ Ensayo dos", "de_las_dos": true}'),
                  'Sólo un admin de todas las sucursales carga un empleado de las dos');
    v_fallas := v_fallas || pg_temp.falla('1 a1 carga uno en TP', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ Ensayo TP', 'sucursal_id', v_tp)),
                  'No tenés asignada esa sucursal: el empleado va en una de tus sucursales');
    e2 := pg_temp.como(v_ad, v_t, pg_temp.ge(v_emp || '{"nombre": "ZZ Ensayo E2", "de_las_dos": true, "puesto": "ayudante"}'))::bigint;
    v_fallas := v_fallas || pg_temp.chk(NOT (e2 = ANY (pg_temp.ids(pg_temp.lista(v_a1, v_t))))
                                        AND e1 = ANY (pg_temp.ids(pg_temp.lista(v_a1, v_t)))
                                        AND pg_temp.ids(pg_temp.lista(v_ad, v_t)) @> ARRAY[e1, e2],
                  format('1 a1 ve %s y ad %s (E1 %s, E2 %s)', pg_temp.ids(pg_temp.lista(v_a1, v_t)),
                         pg_temp.ids(pg_temp.lista(v_ad, v_t)), e1, e2));
    v_txt := pg_temp.estado(v_en, v_tp, 'SELECT public.listar_personal()');
    v_fallas := v_fallas || pg_temp.chk(v_txt = '42501', format('1 el encargado en listar_personal da %s (esperado 42501)', v_txt));
    v_txt := pg_temp.estado(v_tr, v_t, 'SELECT public.listar_personal()');
    v_fallas := v_fallas || pg_temp.chk(v_txt = '42501', format('1 el transportista en listar_personal da %s (esperado 42501)', v_txt));
    v_txt := pg_temp.estado(v_tr, v_t, 'SELECT public.empleados_para_elegir()');
    v_fallas := v_fallas || pg_temp.chk(v_txt = '42501', format('1 el transportista en empleados_para_elegir da %s (esperado 42501)', v_txt));
    v_j := pg_temp.como(v_en, v_tp, 'SELECT public.empleados_para_elegir()')::jsonb;
    v_fallas := v_fallas || pg_temp.chk(
                  e2 = ANY (pg_temp.ids(v_j)) AND NOT (e1 = ANY (pg_temp.ids(v_j)))
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                                   WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e) k)
                                         <> ARRAY['activo', 'id', 'nombre', 'usuario_id', 'vehiculo_id']),
                  format('1 el encargado elige entre %s', v_j));
    -- El admin de una sucursal elige como el encargado: los de las dos tambien.
    v_j := pg_temp.como(v_a1, v_t, 'SELECT public.empleados_para_elegir()')::jsonb;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.ids(v_j) @> ARRAY[e1, e2],
                  format('1 a1 elige entre %s (esperado E1 y E2, de las dos)', v_j));
    -- El saldo al empezar de un arreglo que empieza la semana que viene va hoy.
    e9 := pg_temp.como(v_a1, v_t, pg_temp.ge(v_emp || jsonb_build_object(
            'nombre', 'ZZ Ensayo E9', 'saldo_inicial', 700,
            'arreglo', v_arr || jsonb_build_object('vigente_desde', v_lunes + 7))))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT fecha FROM empleado_movimientos WHERE empleado_id = e9) = v_hoy,
                  format('1 el saldo al empezar de E9 quedo del %s (esperado hoy)',
                         (SELECT fecha FROM empleado_movimientos WHERE empleado_id = e9)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  -- ======================================================== 2 · vinculos ===
  BEGIN
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.ge(v_emp || jsonb_build_object(
              'id', e1, 'usuario_id', v_tr, 'cliente_id', c1, 'vehiculo_id', v_veh, 'cuil', '20-30123456-7')));
    SELECT * INTO g FROM empleados WHERE id = e1;
    v_fallas := v_fallas || pg_temp.chk(g.usuario_id = v_tr AND g.cliente_id = c1 AND g.vehiculo_id = v_veh
                                        AND g.cuil = '20301234567'
                                        AND (SELECT count(*) FROM empleado_arreglos WHERE empleado_id = e1) = 1
                                        AND pg_temp.saldo(e1) = -5000,
                  format('2 E1 quedo %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.falla('2 otro con el mismo usuario', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ dup', 'usuario_id', v_tr)),
                  'Ese usuario ya está vinculado a otro empleado');
    v_fallas := v_fallas || pg_temp.falla('2 otro con el mismo cliente', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ dup', 'cliente_id', c1)),
                  'Esa ficha de cliente ya está vinculada a otro empleado');
    v_fallas := v_fallas || pg_temp.falla('2 usuario sin la sucursal', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ dup', 'usuario_id', v_at)),
                  'Ese usuario no tiene asignada la sucursal del empleado');
    v_fallas := v_fallas || pg_temp.falla('2 E1 con C2', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('id', e1, 'usuario_id', v_tr, 'cliente_id', c2)),
                  'El cliente tiene que ser de la sucursal del empleado');
    v_fallas := v_fallas || pg_temp.falla('2 E1 con un vehiculo de TP', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('id', e1, 'usuario_id', v_tr, 'cliente_id', c1, 'vehiculo_id', v_veh_tp)),
                  'El vehículo no es de la sucursal del empleado o está dado de baja');
    v_fallas := v_fallas || pg_temp.falla('2 CUIL corto', v_a1, v_t,
                  pg_temp.ge(v_emp || '{"nombre": "ZZ dup", "cuil": "20-301"}'), 'El CUIL tiene que tener 11 números');
    v_fallas := v_fallas || pg_temp.falla('2 sin nombre', v_a1, v_t,
                  pg_temp.ge(v_emp || '{"nombre": "  "}'), 'Falta el nombre y apellido');
    v_fallas := v_fallas || pg_temp.falla('2 puesto raro', v_a1, v_t,
                  pg_temp.ge(v_emp || '{"puesto": "gerente"}'), 'Elegí el puesto');
    v_fallas := v_fallas || pg_temp.falla('2 sin arreglo', v_a1, v_t,
                  pg_temp.ge(v_emp || '{"arreglo": null}'), 'Falta el primer arreglo');
    v_fallas := v_fallas || pg_temp.falla('2 fecha rota', v_a1, v_t,
                  pg_temp.ge(v_emp || '{"fecha_ingreso": "ayer"}'), 'Hay un dato del empleado con un formato inválido');
    v_fallas := v_fallas || pg_temp.falla('2 a1 le cambia la sucursal a E1', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('id', e1, 'usuario_id', v_tr, 'cliente_id', c1, 'de_las_dos', true)),
                  'La sucursal y «las dos» sólo las cambia un admin de todas las sucursales');
    PERFORM pg_temp.como(v_ad, v_t, pg_temp.ge(v_emp || jsonb_build_object(
              'id', e2, 'nombre', 'ZZ Ensayo E2', 'de_las_dos', true, 'puesto', 'ayudante', 'cliente_id', c2)));
    v_fallas := v_fallas || pg_temp.chk((SELECT cliente_id FROM empleados WHERE id = e2) = c2,
                  '2 E2 (de las dos) no quedo con C2');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- =================================================== 3 · uno mismo ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('3 a1 se da de alta', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ yo', 'usuario_id', v_a1)),
                  'Tu propia cuenta la maneja otro admin');
    e3 := pg_temp.como(v_ad, v_t, pg_temp.ge(v_emp || jsonb_build_object(
            'nombre', 'ZZ Ensayo E3', 'puesto', 'administracion', 'usuario_id', v_a1)))::bigint;
    v_fallas := v_fallas || pg_temp.falla('3 a1 se carga un movimiento', v_a1, v_t,
                  pg_temp.mov(e3, jsonb_build_object('tipo', 'ajuste', 'monto', 1000, 'fecha', v_hoy, 'observacion', 'yo')),
                  'Tu propia cuenta la maneja otro admin');
    v_fallas := v_fallas || pg_temp.falla('3 a1 se cambia el arreglo', v_a1, v_t,
                  pg_temp.arr(e3, v_arr || '{"sueldo": 900000}'), 'Tu propia cuenta la maneja otro admin');
    v_fallas := v_fallas || pg_temp.falla('3 a1 se da de baja', v_a1, v_t,
                  format('SELECT public.dar_de_baja_empleado(p_empleado_id => %s, p_fecha => %L::date)', e3, v_hoy),
                  'Tu propia cuenta la maneja otro admin');
    v_fallas := v_fallas || pg_temp.falla('3 a1 se saca el usuario', v_a1, v_t,
                  pg_temp.ge(v_emp || jsonb_build_object('id', e3, 'nombre', 'ZZ Ensayo E3', 'puesto', 'administracion')),
                  'Tu propia cuenta la maneja otro admin');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.ge(v_emp || jsonb_build_object(
              'id', e3, 'nombre', 'ZZ Ensayo E3', 'puesto', 'administracion', 'usuario_id', v_a1, 'telefono', '381 555 1234')));
    v_j := (SELECT e FROM jsonb_array_elements(pg_temp.lista(v_a1, v_t)) e WHERE (e->>'id')::bigint = e3);
    v_fallas := v_fallas || pg_temp.chk(v_j->>'telefono' = '381 555 1234' AND (v_j->>'es_propio')::boolean
                                        AND v_j->'usuario'->>'id' = v_a1::text,
                  format('3 a1 no pudo corregir su telefono o no se ve propio: %s', v_j));
    v_fallas := v_fallas || pg_temp.falla('3 a1 carga un gasto que pago el', v_a1, v_t,
                  pg_temp.gg(jsonb_build_object(
                    'fecha', v_hoy, 'rubro_id', r_lib, 'monto_total', 1000, 'comprobante', 'ticket', 'sucursal_id', v_t,
                    'origen_pago', 'empleado', 'empleado_id', e3)),
                  'Un gasto que pagaste vos lo carga otro admin o el encargado');
    -- Otro admin si le carga a E3.
    PERFORM pg_temp.como(v_ad, v_t, pg_temp.mov(e3, jsonb_build_object('tipo', 'adelanto', 'monto', 1000, 'fecha', v_hoy,
                                                                       'observacion', NULL)));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e3) = -1000, format('3 ad no pudo cargarle un adelanto a E3: %s', pg_temp.saldo(e3)));
    -- eliminarPago (DELETE REST) de un adelanto de su propia ficha: a1 no.
    PERFORM pg_temp.como(v_ad, v_t, pg_temp.ge(v_emp || jsonb_build_object(
              'id', e3, 'nombre', 'ZZ Ensayo E3', 'puesto', 'administracion', 'usuario_id', v_a1, 'cliente_id', c4)));
    v_j := pg_temp.como(v_ad, v_t, pg_temp.fifo(c4, 1500, 'adelanto_sueldo'))::jsonb;
    v_pe3 := (v_j->'pago_ids'->>0)::bigint;
    PERFORM set_config('request.method', 'DELETE', true);
    PERFORM set_config('request.path', '/pagos', true);
    v_fallas := v_fallas || pg_temp.falla('3 a1 borra por REST un adelanto de su ficha', v_a1, v_t,
                  format('DELETE FROM pagos WHERE id = %s RETURNING id', v_pe3),
                  'Un adelanto de sueldo de tu propia ficha lo anula otro admin');
    PERFORM set_config('request.method', '', true);
    PERFORM set_config('request.path', '', true);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e3) = -2500 AND EXISTS (SELECT 1 FROM pagos WHERE id = v_pe3),
                  format('3 E3 quedo en %s (esperado -2500) o el pago no esta', pg_temp.saldo(e3)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- ===================================================== 4 · mercaderia ===
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, pg_temp.fifo(c1, 10000, 'adelanto_sueldo'))::jsonb;
    p1 := (v_j->'pago_ids'->>0)::bigint;
    SELECT * INTO g FROM empleado_movimientos WHERE pago_id = p1;
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j->'pago_ids') = 1 AND g.empleado_id = e1 AND g.monto = -10000
                                        AND g.tipo = 'mercaderia' AND g.pedido_id = v_ped AND g.fecha = v_hoy
                                        AND g.observacion IS NULL AND g.creado_por = v_a1
                                        AND pg_temp.saldo(e1) = -15000,
                  format('4 el adelanto dejo %s (resultado %s, saldo %s)', to_jsonb(g), v_j, pg_temp.saldo(e1)));
    v_fallas := v_fallas || pg_temp.falla('4 adelanto a un cliente sin vinculo', v_a1, v_t, pg_temp.fifo(cx, 10000, 'adelanto_sueldo'),
                  'El adelanto de sueldo es sólo para la ficha de cliente de un empleado: vinculala desde Personal o elegí otra forma de pago');
    v_n := (SELECT count(*) FROM empleado_movimientos);
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.fifo(c1, 2000, 'efectivo'));
    v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM empleado_movimientos) = v_n,
                  '4 un pago en efectivo sobre C1 dejo un movimiento');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ================================================== 5 · sigue al pago ===
  BEGIN
    UPDATE pagos SET monto = 7000 WHERE id = p1;
    g := pg_temp.ultimo(e1);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_pagos(ARRAY[p1], NULL) = -7000 AND g.monto = 3000
                                        AND g.observacion = 'El pago cambió de monto' AND g.fecha = v_hoy AND g.pago_id = p1,
                  format('5 a 7000: la cuenta del pago da %s y el ultimo es %s', pg_temp.de_pagos(ARRAY[p1], NULL), to_jsonb(g)));
    -- Partirlo como aplicar_credito_cliente: baja la raiz y nace el pedazo.
    UPDATE pagos SET monto = 4000 WHERE id = p1;
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, pago_origen_id)
    SELECT cliente_id, NULL, 3000, forma_pago, fecha, usuario_id, sucursal_id, id FROM pagos WHERE id = p1
    RETURNING id INTO pz;
    g := pg_temp.ultimo(e1);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_pagos(ARRAY[p1, pz], NULL) = -7000
                                        AND pg_temp.de_pagos(ARRAY[pz], e1) = -3000 AND g.pago_id = pz AND g.observacion IS NULL,
                  format('5 partido: la familia da %s, el pedazo %s', pg_temp.de_pagos(ARRAY[p1, pz], NULL),
                         pg_temp.de_pagos(ARRAY[pz], NULL)));
    DELETE FROM pagos WHERE id = pz;
    g := pg_temp.ultimo(e1);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_pagos(ARRAY[p1, pz], NULL) = -4000 AND g.monto = 3000
                                        AND g.observacion = 'Se borró el pago',
                  format('5 sin el pedazo la familia da %s (esperado -4000), el ultimo %s', pg_temp.de_pagos(ARRAY[p1, pz], NULL), to_jsonb(g)));
    DELETE FROM pagos WHERE id = p1;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_pagos(ARRAY[p1, pz], NULL) = 0 AND pg_temp.saldo(e1) = -5000,
                  format('5 sin la raiz la familia da %s y E1 %s', pg_temp.de_pagos(ARRAY[p1, pz], NULL), pg_temp.saldo(e1)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- ==================================== 5b · el pedazo va a su cliente ===
  -- Con las funciones de cobro reales: la FIFO deja S a favor en C5 (ficha de
  -- E6); aplicar_credito_cliente parte S y nace Z sobre la boleta P;
  -- cambiar_cliente_pedido pasa P a C6 (ficha de E8) y, con el pedido nuevo
  -- mas barato, _pagos_excedente_a_favor parte Z y nace W en C6, colgado de S.
  -- Al reves, a mano: la raiz S2 pasa a C6 y se parte el pedazo Z2 que quedo
  -- en C5. Cada empleado termina en -(lo vivo de sus fichas).
  BEGIN
    e6 := pg_temp.como(v_a1, v_t, pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ Ensayo E6', 'cliente_id', c5)))::bigint;
    e8 := pg_temp.como(v_a1, v_t, pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ Ensayo E8', 'cliente_id', c6)))::bigint;
    v_j := pg_temp.como(v_a1, v_t, pg_temp.fifo(c5, 5000, 'adelanto_sueldo'))::jsonb;
    v_s := (v_j->'pago_ids'->>0)::bigint;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a1, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_t::text)::text, true);
    v_j := public.crear_pedido_completo(c5, 4000, v_a1,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 40, 'precio_unitario', 100)),
             'ensayo gastos 4 P');
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'no se pudo crear P: %', v_j;
    END IF;
    v_ped5 := (v_j->>'pedido_id')::bigint;
    PERFORM public.aplicar_credito_cliente(c5, v_t);
    SELECT id INTO v_z FROM pagos WHERE pago_origen_id = v_s AND pedido_id = v_ped5;
    v_j := pg_temp.como(v_a1, v_t, format(
             'SELECT public.cambiar_cliente_pedido(p_pedido_id => %s, p_nuevo_cliente_id => %s, p_usuario_id => %L::uuid, '
             || 'p_items => %L::jsonb, p_total => 1000, p_motivo => %L, p_destino_pagos => %L)',
             v_ped5, c6, v_a1, jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
             'ensayo gastos 4', 'pedido_nuevo'))::jsonb;
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'cambiar_cliente_pedido no anduvo: %', v_j;
    END IF;
    SELECT id INTO v_w FROM pagos WHERE pago_origen_id = v_s AND cliente_id = c6 AND id <> v_z ORDER BY id DESC LIMIT 1;
    v_fallas := v_fallas || pg_temp.chk(v_z IS NOT NULL AND v_w IS NOT NULL
                                        AND (SELECT cliente_id FROM pagos WHERE id = v_z) = c6,
                  format('5b no se armo la familia: S %s, Z %s, W %s', v_s, v_z, v_w));
    -- Al reves, a mano.
    v_j := pg_temp.como(v_a1, v_t, pg_temp.fifo(c5, 3000, 'adelanto_sueldo'))::jsonb;
    v_s2 := (v_j->'pago_ids'->>(jsonb_array_length(v_j->'pago_ids') - 1))::bigint;
    UPDATE pagos SET monto = monto - 1000 WHERE id = v_s2;
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, pago_origen_id)
    SELECT cliente_id, NULL, 1000, forma_pago, fecha, usuario_id, sucursal_id, id FROM pagos WHERE id = v_s2
    RETURNING id INTO v_z2;
    UPDATE pagos SET cliente_id = c6 WHERE id = v_s2;
    UPDATE pagos SET monto = 400 WHERE id = v_z2;
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, pago_origen_id)
    SELECT cliente_id, NULL, 600, forma_pago, fecha, usuario_id, sucursal_id, v_s2 FROM pagos WHERE id = v_z2
    RETURNING id INTO v_w2;
    v_fallas := v_fallas || pg_temp.chk(
                  pg_temp.saldo(e6) = -(SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = c5 AND forma_pago = 'adelanto_sueldo')
                  AND pg_temp.saldo(e8) = -(SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = c6 AND forma_pago = 'adelanto_sueldo')
                  AND pg_temp.de_pagos(ARRAY[v_w2], e6) = -600 AND pg_temp.de_pagos(ARRAY[v_w], e8) <> 0,
                  format('5b E6 %s (vivo en C5 %s) y E8 %s (vivo en C6 %s)', pg_temp.saldo(e6),
                         (SELECT sum(monto) FROM pagos WHERE cliente_id = c5 AND forma_pago = 'adelanto_sueldo'), pg_temp.saldo(e8),
                         (SELECT sum(monto) FROM pagos WHERE cliente_id = c6 AND forma_pago = 'adelanto_sueldo')));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5b · error: %s', SQLERRM);
  END;

  -- ===================================================== 6 · historicos ===
  BEGIN
    e7 := pg_temp.como(v_ad, v_t, pg_temp.ge(v_emp || '{"nombre": "ZZ Ensayo E7", "puesto": "preventista", "cliente_id": 376}'))::bigint;
    -- Como lo hace una reimputacion: si la caja de esos dias se cerro, el
    -- cambio igual tiene que llegar al trigger.
    PERFORM set_config('app.reimputacion_pagos', 'on', true);
    BEGIN
      UPDATE pagos SET monto = monto - 10 WHERE id = 7777;
    EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 cambiar el 7777: %s', SQLERRM);
    END;
    BEGIN
      DELETE FROM pagos WHERE id = 7776;
    EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 borrar el 7776: %s', SQLERRM);
    END;
    BEGIN
      UPDATE pagos SET monto = monto - 100 WHERE id = 7775;
      INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, pago_origen_id)
      SELECT cliente_id, NULL, 100, forma_pago, fecha, usuario_id, sucursal_id, id FROM pagos WHERE id = 7775
      RETURNING id INTO pz;
    EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 partir el 7775: %s', SQLERRM);
    END;
    PERFORM set_config('app.reimputacion_pagos', '', true);
    -- 6b · Un INSERT REST directo (#1246 sigue abierto) no arma pedazos de un
    --      adelanto: ni colgado de un historico ni de uno del libro. Sin
    --      pago_origen_id sigue la regla de siempre.
    PERFORM set_config('request.method', 'POST', true);
    PERFORM set_config('request.path', '/pagos', true);
    v_fallas := v_fallas || pg_temp.falla('6b REST: pedazo de un historico', v_a1, v_t,
                  format('INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, pago_origen_id) '
                         || 'VALUES (%s, 100, %L, %L::date, %s, 7777) RETURNING id', cx, 'adelanto_sueldo', v_hoy, v_t),
                  'Un pedazo de un adelanto de sueldo lo arma el servidor');
    v_fallas := v_fallas || pg_temp.falla('6b REST: pedazo de uno del libro', v_a1, v_t,
                  format('INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id, pago_origen_id) '
                         || 'VALUES (%s, 100, %L, %L::date, %s, %s) RETURNING id', c5, 'adelanto_sueldo', v_hoy, v_t, v_s),
                  'Un pedazo de un adelanto de sueldo lo arma el servidor');
    v_fallas := v_fallas || pg_temp.falla('6b REST: adelanto sin vinculo', v_a1, v_t,
                  format('INSERT INTO pagos (cliente_id, monto, forma_pago, fecha, sucursal_id) '
                         || 'VALUES (%s, 100, %L, %L::date, %s) RETURNING id', cx, 'adelanto_sueldo', v_hoy, v_t),
                  'El adelanto de sueldo es sólo para la ficha de cliente de un empleado');
    PERFORM set_config('request.method', '', true);
    PERFORM set_config('request.path', '', true);
    v_fallas := v_fallas || pg_temp.chk((SELECT forma_pago FROM pagos WHERE id = 7777) = 'adelanto_sueldo'
                                        AND (SELECT cliente_id FROM empleados WHERE id = e7) = 376
                                        AND NOT EXISTS (SELECT 1 FROM empleado_movimientos
                                                         WHERE pago_id IN (7775, 7776, 7777, pz) OR empleado_id = e7),
                  format('6 los historicos dejaron movimientos: %s',
                         (SELECT jsonb_agg(to_jsonb(m)) FROM empleado_movimientos m WHERE pago_id IN (7775, 7776, 7777, pz) OR empleado_id = e7)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- ============================================= 7 · cambio de cliente ===
  -- La FK de pagos a clientes es compuesta (cliente_id, sucursal_id): un pago
  -- no pasa a un cliente de otra sucursal. Por eso el destino es C3 (de E4, en
  -- T), no la ficha de E2, que es de TP.
  BEGIN
    e4 := pg_temp.como(v_a1, v_t, pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ Ensayo E4', 'cliente_id', c3)))::bigint;
    v_j := pg_temp.como(v_a1, v_t, pg_temp.fifo(c1, 5000, 'adelanto_sueldo'))::jsonb;
    p2 := (v_j->'pago_ids'->>0)::bigint;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_pagos(ARRAY[p2], e1) = -5000,
                  format('7 el adelanto de 5000 dejo %s en E1', pg_temp.de_pagos(ARRAY[p2], e1)));
    v_fallas := v_fallas || pg_temp.falla('7 el adelanto pasa a un cliente sin vinculo', NULL, NULL,
                  format('UPDATE pagos SET cliente_id = %s WHERE id = %s RETURNING id', cx, p2),
                  'Este pago es un adelanto de sueldo y el cliente nuevo no es la ficha de un empleado: anulá el pago antes de cambiar el cliente');
    UPDATE pagos SET cliente_id = c3 WHERE id = p2;
    g := (SELECT m FROM empleado_movimientos m WHERE m.pago_id = p2 AND m.empleado_id = e1 ORDER BY m.id DESC LIMIT 1);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_pagos(ARRAY[p2], e1) = 0 AND pg_temp.de_pagos(ARRAY[p2], e4) = -5000
                                        AND g.monto = 5000 AND g.observacion = 'El pago pasó a otro cliente',
                  format('7 a C3: E1 %s y E4 %s (esperado 0 y -5000), el de E1 %s', pg_temp.de_pagos(ARRAY[p2], e1),
                         pg_temp.de_pagos(ARRAY[p2], e4), to_jsonb(g)));
    UPDATE pagos SET monto = 4000 WHERE id = p2;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_pagos(ARRAY[p2], e1) = 0 AND pg_temp.de_pagos(ARRAY[p2], e4) = -4000,
                  format('7 bajado a 4000 despues del cambio: E1 %s y E4 %s (esperado 0 y -4000)', pg_temp.de_pagos(ARRAY[p2], e1),
                         pg_temp.de_pagos(ARRAY[p2], e4)));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- Lo que arma ModalGasto: todas las claves de GuardarGastoPayload.
  v_gasto := jsonb_build_object(
    'fecha', v_hoy, 'rubro_id', r_lib, 'monto_total', 8000, 'comprobante', 'ticket', 'comprobante_numero', NULL,
    'alicuota_iva', NULL, 'iva', 0, 'percepcion_iva', 0, 'percepcion_iibb', 0, 'otros_impuestos', 0,
    'sucursal_id', v_t, 'compartido', false, 'vehiculo_id', NULL, 'litros', NULL, 'km_tablero', NULL,
    'mes_imputado', to_char(date_trunc('month', v_hoy), 'YYYY-MM-DD'), 'repartir_meses', 1,
    'origen_pago', 'empleado', 'empleado_id', e1, 'rendicion_transportista_id', NULL, 'rendicion_fecha', NULL,
    'observacion', NULL);

  -- ====================================================== 8 · reintegro ===
  BEGIN
    g1 := pg_temp.como(v_a1, v_t, pg_temp.gg(v_gasto))::bigint;
    SELECT * INTO g FROM empleado_movimientos WHERE gasto_id = g1;
    v_fallas := v_fallas || pg_temp.chk(g.empleado_id = e1 AND g.monto = 8000 AND g.tipo = 'reintegro' AND g.fecha = v_hoy
                                        AND g.observacion IS NULL AND (SELECT empleado_id FROM gastos WHERE id = g1) = e1,
                  format('8 el gasto de 8000 dejo %s', to_jsonb(g)));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.gg(v_gasto || jsonb_build_object('id', g1, 'monto_total', 9000)));
    g := pg_temp.ultimo(e1);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_gasto(g1, e1) = 9000 AND g.monto = 1000 AND g.observacion = 'El gasto cambió de monto',
                  format('8 a 9000: E1 %s, ultimo %s', pg_temp.de_gasto(g1, e1), to_jsonb(g)));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.gg(v_gasto || jsonb_build_object('id', g1, 'monto_total', 9000, 'empleado_id', e2)));
    g := pg_temp.ultimo(e1);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_gasto(g1, e1) = 0 AND pg_temp.de_gasto(g1, e2) = 9000
                                        AND g.monto = -9000 AND g.observacion = 'El gasto pasó a otro empleado',
                  format('8 a E2: E1 %s, E2 %s, ultimo de E1 %s', pg_temp.de_gasto(g1, e1), pg_temp.de_gasto(g1, e2), to_jsonb(g)));
    PERFORM pg_temp.como(v_a1, v_t, format('SELECT public.anular_gasto(p_gasto_id => %s, p_motivo => %L)', g1, 'ensayo gastos 4'));
    g := pg_temp.ultimo(e2);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_gasto(g1, NULL) = 0 AND g.monto = -9000 AND g.observacion = 'Se anuló el gasto',
                  format('8 anulado: queda %s, ultimo de E2 %s', pg_temp.de_gasto(g1, NULL), to_jsonb(g)));
    g_of := pg_temp.como(v_a1, v_t, pg_temp.gg(v_gasto || '{"origen_pago": "oficina"}'))::bigint;
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE gasto_id = g_of)
                                        AND (SELECT empleado_id FROM gastos WHERE id = g_of) IS NULL,
                  '8 un gasto de la oficina dejo un movimiento o un empleado');
    g2 := pg_temp.como(v_a1, v_t, pg_temp.gg(v_gasto || '{"monto_total": 5000}'))::bigint;
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.gg(v_gasto || jsonb_build_object('id', g2, 'monto_total', 5000, 'origen_pago', 'oficina')));
    g := pg_temp.ultimo(e1);
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_gasto(g2, NULL) = 0 AND g.observacion = 'El gasto dejó de estar pagado por un empleado'
                                        AND (SELECT empleado_id FROM gastos WHERE id = g2) IS NULL,
                  format('8 a la oficina: queda %s, ultimo %s', pg_temp.de_gasto(g2, NULL), to_jsonb(g)));
    g_en := pg_temp.como(v_en, v_tp, pg_temp.gg(v_gasto || jsonb_build_object('sucursal_id', v_tp, 'empleado_id', e2, 'monto_total', 1500)))::bigint;
    v_fallas := v_fallas || pg_temp.chk(pg_temp.de_gasto(g_en, e2) = 1500,
                  format('8 el encargado cargo un gasto de E2 y dejo %s', pg_temp.de_gasto(g_en, e2)));
    v_fallas := v_fallas || pg_temp.falla('8 sin empleado', v_a1, v_t, pg_temp.gg(v_gasto || '{"empleado_id": null}'),
                  'Elegí qué empleado pagó el gasto');
    e5 := pg_temp.como(v_at, v_tp, pg_temp.ge(v_emp || jsonb_build_object('nombre', 'ZZ Ensayo E5', 'sucursal_id', v_tp)))::bigint;
    v_fallas := v_fallas || pg_temp.falla('8 un empleado de TP', v_a1, v_t, pg_temp.gg(v_gasto || jsonb_build_object('empleado_id', e5)),
                  'Ese empleado no es de la sucursal del gasto');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ========================================================= 9 · a mano ===
  BEGIN
    v_m := pg_temp.saldo(e1);
    m1 := pg_temp.como(v_a1, v_t, pg_temp.mov(e1, jsonb_build_object('tipo', 'adelanto', 'monto', 20000, 'fecha', v_hoy,
                                                                    'observacion', NULL)))::bigint;
    SELECT * INTO g FROM empleado_movimientos WHERE id = m1;
    v_fallas := v_fallas || pg_temp.chk(g.tipo = 'adelanto' AND g.monto = -20000 AND g.creado_por = v_a1
                                        AND pg_temp.saldo(e1) = v_m - 20000,
                  format('9 el adelanto quedo %s', to_jsonb(g)));
    v_fallas := v_fallas || pg_temp.falla('9 ajuste sin observacion', v_a1, v_t,
                  pg_temp.mov(e1, jsonb_build_object('tipo', 'ajuste', 'monto', 3000, 'fecha', v_hoy, 'observacion', ' ')),
                  'El ajuste necesita una observación que diga por qué');
    v_fallas := v_fallas || pg_temp.falla('9 ajuste en cero', v_a1, v_t,
                  pg_temp.mov(e1, jsonb_build_object('tipo', 'ajuste', 'monto', 0, 'fecha', v_hoy, 'observacion', 'x')),
                  'El ajuste no puede ser cero');
    v_fallas := v_fallas || pg_temp.falla('9 adelanto en cero', v_a1, v_t,
                  pg_temp.mov(e1, jsonb_build_object('tipo', 'adelanto', 'monto', 0, 'fecha', v_hoy)),
                  'El monto tiene que ser mayor a cero');
    v_fallas := v_fallas || pg_temp.falla('9 tipo mercaderia', v_a1, v_t,
                  pg_temp.mov(e1, jsonb_build_object('tipo', 'mercaderia', 'monto', 10, 'fecha', v_hoy)),
                  'Un movimiento a mano es un adelanto en efectivo o un ajuste');
    v_fallas := v_fallas || pg_temp.falla('9 fecha futura', v_a1, v_t,
                  pg_temp.mov(e1, jsonb_build_object('tipo', 'adelanto', 'monto', 10, 'fecha', v_hoy + 1)),
                  'La fecha del movimiento no puede ser futura');
    m_aj := pg_temp.como(v_a1, v_t, pg_temp.mov(e1, jsonb_build_object('tipo', 'ajuste', 'monto', 3000, 'fecha', v_hoy,
                                                                      'observacion', 'ensayo gastos 4')))::bigint;
    m_rev := pg_temp.como(v_a1, v_t, pg_temp.rev(m1, 'ensayo gastos 4'))::bigint;
    SELECT * INTO g FROM empleado_movimientos WHERE id = m_rev;
    v_fallas := v_fallas || pg_temp.chk(g.tipo = 'adelanto' AND g.monto = 20000 AND g.revierte_id = m1 AND g.fecha = v_hoy
                                        AND g.observacion = 'ensayo gastos 4' AND pg_temp.saldo(e1) = v_m + 3000,
                  format('9 la reversion quedo %s y E1 %s (esperado %s)', to_jsonb(g), pg_temp.saldo(e1), v_m + 3000));
    v_fallas := v_fallas || pg_temp.falla('9 revertir dos veces', v_a1, v_t, pg_temp.rev(m1, 'otra'), 'Ese movimiento ya está revertido');
    v_fallas := v_fallas || pg_temp.falla('9 revertir la reversion', v_a1, v_t, pg_temp.rev(m_rev, 'otra'),
                  'Un movimiento que revierte a otro no se revierte: cargá uno nuevo');
    SELECT id INTO m_merc FROM empleado_movimientos WHERE empleado_id = e1 AND tipo = 'mercaderia' ORDER BY id LIMIT 1;
    v_fallas := v_fallas || pg_temp.falla('9 revertir una mercaderia', v_a1, v_t, pg_temp.rev(m_merc, 'otra'),
                  'Sólo se revierte un movimiento cargado a mano');
    v_fallas := v_fallas || pg_temp.falla('9 revertir sin motivo', v_a1, v_t, pg_temp.rev(m_aj, '  '), 'Escribí por qué se revierte');
    v_j := pg_temp.cuenta(v_a1, v_t, e1);
    v_fallas := v_fallas || pg_temp.chk(
                  (v_j->'movimientos'->0->>'saldo')::numeric = pg_temp.saldo(e1)
                  AND (v_j->'empleado'->>'saldo')::numeric = pg_temp.saldo(e1)
                  AND (SELECT (e->>'revertido')::boolean FROM jsonb_array_elements(v_j->'movimientos') e WHERE (e->>'id')::bigint = m1)
                  AND NOT (SELECT (e->>'revertido')::boolean FROM jsonb_array_elements(v_j->'movimientos') e WHERE (e->>'id')::bigint = m_aj)
                  AND (SELECT e->>'creado_por_nombre' FROM jsonb_array_elements(v_j->'movimientos') e WHERE (e->>'id')::bigint = m1)
                      = (SELECT nombre FROM perfiles WHERE id = v_a1)
                  AND (SELECT e->'gasto'->>'rubro' FROM jsonb_array_elements(v_j->'movimientos') e
                        WHERE jsonb_typeof(e->'gasto') = 'object' LIMIT 1) = 'Librería'
                  AND (SELECT count(*) FROM jsonb_array_elements(v_j->'movimientos')) = (SELECT count(*) FROM empleado_movimientos WHERE empleado_id = e1),
                  format('9 la cuenta de E1: %s', v_j->'movimientos'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ======================================================= 10 · arreglos ===
  BEGIN
    v_fallas := v_fallas || pg_temp.falla('10 arreglo anterior al vigente', v_a1, v_t,
                  pg_temp.arr(e1, v_arr || jsonb_build_object('vigente_desde', v_lunes - 7)),
                  format('Un arreglo nuevo vale desde después del vigente (%s)', to_char(v_lunes, 'DD/MM/YYYY')));
    v_fallas := v_fallas || pg_temp.falla('10 sueldo negativo', v_a1, v_t, pg_temp.arr(e1, v_arr || '{"sueldo": -1}'),
                  'El sueldo no puede ser negativo');
    v_fallas := v_fallas || pg_temp.falla('10 sin sueldo y sin comision', v_a1, v_t, pg_temp.arr(e1, v_arr || '{"sueldo": 0}'),
                  'Un arreglo sin sueldo fijo tiene que comisionar');
    v_fallas := v_fallas || pg_temp.falla('10 frecuencia diaria', v_a1, v_t, pg_temp.arr(e1, v_arr || '{"frecuencia": "diaria"}'),
                  'El sueldo es semanal o mensual');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.arr(e1, v_arr || '{"sueldo": 160000}'));
    v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM empleado_arreglos WHERE empleado_id = e1) = 1
                                        AND (SELECT sueldo FROM empleado_arreglos WHERE empleado_id = e1) = 160000,
                  '10 el arreglo del mismo dia no corrigio el vigente');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.arr(e1, v_arr || jsonb_build_object('vigente_desde', v_lunes + 7, 'sueldo', 0,
                                                                                'comisiona', true)));
    v_j := pg_temp.cuenta(v_a1, v_t, e1);
    v_fallas := v_fallas || pg_temp.chk(
                  (SELECT count(*) FROM empleado_arreglos WHERE empleado_id = e1) = 2
                  AND v_j->'arreglos'->0->>'vigente_desde' = (v_lunes + 7)::text
                  AND v_j->'arreglos'->0->'vigente_hasta' = 'null'::jsonb
                  AND v_j->'arreglos'->1->>'vigente_hasta' = (v_lunes + 6)::text
                  AND v_j->'empleado'->'arreglo'->>'vigente_desde' = v_lunes::text
                  AND v_j->'empleado'->'arreglo'->>'vigente_hasta' = (v_lunes + 6)::text
                  AND (v_j->'empleado'->'arreglo'->>'sueldo')::numeric = 160000
                  AND v_j->'empleado'->>'arranque' = v_lunes::text,
                  format('10 la cuenta da arreglos %s y vigente %s', v_j->'arreglos', v_j->'empleado'->'arreglo'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  -- =========================================================== 11 · baja ===
  BEGIN
    v_fallas := v_fallas || pg_temp.chk(pg_temp.como(v_a1, v_t,
                    format('SELECT public.cliente_admite_adelanto_sueldo(p_cliente_id => %s)', c1))::boolean
                  AND NOT pg_temp.como(v_a1, v_t, format('SELECT public.cliente_admite_adelanto_sueldo(p_cliente_id => %s)', cx))::boolean,
                  '11 cliente_admite_adelanto_sueldo no da true para C1 activo y false para CX');
    v_fallas := v_fallas || pg_temp.falla('11 baja futura', v_a1, v_t,
                  format('SELECT public.dar_de_baja_empleado(p_empleado_id => %s, p_fecha => %L::date)', e1, v_hoy + 1),
                  'La baja no puede ser de un día que todavía no llegó');
    v_fallas := v_fallas || pg_temp.falla('11 baja antes del primer arreglo', v_a1, v_t,
                  format('SELECT public.dar_de_baja_empleado(p_empleado_id => %s, p_fecha => %L::date)', e1, v_lunes - 1),
                  'La baja no puede ser antes de que empiece su primer arreglo');
    PERFORM pg_temp.como(v_a1, v_t, format('SELECT public.dar_de_baja_empleado(p_empleado_id => %s, p_fecha => %L::date)', e1, v_hoy));
    SELECT * INTO g FROM empleados WHERE id = e1;
    v_fallas := v_fallas || pg_temp.chk(NOT g.activo AND g.fecha_baja = v_hoy, format('11 la baja dejo %s / %s', g.activo, g.fecha_baja));
    v_fallas := v_fallas || pg_temp.falla('11 baja otra vez', v_a1, v_t,
                  format('SELECT public.dar_de_baja_empleado(p_empleado_id => %s, p_fecha => %L::date)', e1, v_hoy),
                  'Ese empleado ya está dado de baja');
    v_fallas := v_fallas || pg_temp.falla('11 adelanto a un empleado dado de baja', v_a1, v_t, pg_temp.fifo(c1, 1000, 'adelanto_sueldo'),
                  'Ese cliente es la ficha de un empleado dado de baja: ya no se le dan adelantos de sueldo');
    v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.como(v_a1, v_t,
                    format('SELECT public.cliente_admite_adelanto_sueldo(p_cliente_id => %s)', c1))::boolean,
                  '11 cliente_admite_adelanto_sueldo(C1) da true con E1 dado de baja');
    v_fallas := v_fallas || pg_temp.falla('11 arreglo de un dado de baja', v_a1, v_t,
                  pg_temp.arr(e1, v_arr || jsonb_build_object('vigente_desde', v_lunes + 14)),
                  'Ese empleado está dado de baja: reactivalo para cambiarle el arreglo');
    v_fallas := v_fallas || pg_temp.falla('11 gasto de un dado de baja', v_a1, v_t, pg_temp.gg(v_gasto),
                  'Ese empleado está dado de baja');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.mov(e1, jsonb_build_object('tipo', 'ajuste', 'monto', -100, 'fecha', v_hoy,
                                                                     'observacion', 'ensayo: el que se fue')));
    v_fallas := v_fallas || pg_temp.chk((pg_temp.ultimo(e1)).monto = -100, '11 un dado de baja no recibio un ajuste');
    PERFORM pg_temp.como(v_a1, v_t, format('SELECT public.reactivar_empleado(p_empleado_id => %s)', e1));
    SELECT * INTO g FROM empleados WHERE id = e1;
    v_fallas := v_fallas || pg_temp.chk(g.activo AND g.fecha_baja IS NULL, '11 reactivar no dejo activo a E1');
    v_fallas := v_fallas || pg_temp.falla('11 reactivar otra vez', v_a1, v_t,
                  format('SELECT public.reactivar_empleado(p_empleado_id => %s)', e1), 'Ese empleado ya está activo');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('11 · error: %s', SQLERRM);
  END;

  -- ========================================================== 12 · GAS-1 ===
  BEGIN
    v_comb := v_gasto || jsonb_build_object('rubro_id', r_comb, 'monto_total', 40000, 'vehiculo_id', v_veh,
                                            'litros', 40, 'km_tablero', 10000, 'origen_pago', 'oficina', 'empleado_id', NULL);
    g_comb := pg_temp.como(v_a1, v_t, pg_temp.gg(v_comb))::bigint;
    -- Como el modal con un rubro que no conoce: sin las dos claves.
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.gg((v_comb - 'litros' - 'km_tablero')
                                               || jsonb_build_object('id', g_comb, 'monto_total', 41000, 'fecha', v_hoy - 1)));
    v_fallas := v_fallas || pg_temp.chk((SELECT litros FROM gastos WHERE id = g_comb) = 40
                                        AND (SELECT monto_total FROM gastos WHERE id = g_comb) = 41000
                                        AND (SELECT km FROM vehiculo_km WHERE gasto_id = g_comb) = 10000
                                        AND (SELECT fecha FROM vehiculo_km WHERE gasto_id = g_comb) = v_hoy - 1,
                  format('12 sin las claves: litros %s, km %s del %s', (SELECT litros FROM gastos WHERE id = g_comb),
                         (SELECT km FROM vehiculo_km WHERE gasto_id = g_comb), (SELECT fecha FROM vehiculo_km WHERE gasto_id = g_comb)));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.gg(v_comb || jsonb_build_object('id', g_comb, 'litros', NULL, 'km_tablero', NULL)));
    v_fallas := v_fallas || pg_temp.chk((SELECT litros FROM gastos WHERE id = g_comb) IS NULL
                                        AND NOT EXISTS (SELECT 1 FROM vehiculo_km WHERE gasto_id = g_comb),
                  '12 con null explicito no borro litros ni km');
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.gg(v_comb || jsonb_build_object('id', g_comb, 'litros', 30, 'km_tablero', 11000)));
    PERFORM pg_temp.como(v_a1, v_t, pg_temp.gg((v_comb - 'litros' - 'km_tablero') || jsonb_build_object('id', g_comb, 'rubro_id', r_lib)));
    v_fallas := v_fallas || pg_temp.chk((SELECT litros FROM gastos WHERE id = g_comb) IS NULL
                                        AND NOT EXISTS (SELECT 1 FROM vehiculo_km WHERE gasto_id = g_comb),
                  '12 pasado a un rubro sin litros ni km los conservo');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('12 · error: %s', SQLERRM);
  END;

  -- ======================================================= 13 · permisos ===
  BEGIN
    FOR g IN SELECT f FROM unnest(ARRAY[
               'public._empleado_visible(bigint,boolean)', 'public._empleado_json(empleados)',
               'public._cuenta_empleado_conciliar(text,bigint,bigint,bigint,bigint,bigint,numeric,date,bigint,text)',
               'public.pagos_cuenta_empleado()', 'public.gastos_cuenta_empleado()', 'public._guardar_gasto(jsonb,boolean)',
               'public.listar_personal()', 'public.obtener_cuenta_empleado(bigint)', 'public.empleados_para_elegir()',
               'public.cliente_admite_adelanto_sueldo(bigint)', 'public.guardar_empleado(jsonb)',
               'public.guardar_arreglo_empleado(bigint,jsonb)', 'public.dar_de_baja_empleado(bigint,date)',
               'public.reactivar_empleado(bigint)', 'public.registrar_movimiento_empleado(bigint,jsonb)',
               'public.revertir_movimiento_empleado(bigint,text)']) f LOOP
      IF has_function_privilege('anon', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('13 anon ejecuta %s', g.f);
      END IF;
      IF (g.f ~ '^public\._' OR g.f ~ '_cuenta_empleado\(\)$') AND has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('13 authenticated ejecuta %s', g.f);
      END IF;
      IF g.f !~ '^public\._' AND g.f !~ '_cuenta_empleado\(\)$' AND NOT has_function_privilege('authenticated', g.f, 'EXECUTE') THEN
        v_fallas := v_fallas || format('13 authenticated no ejecuta %s', g.f);
      END IF;
    END LOOP;
    FOR g IN SELECT t FROM unnest(ARRAY['public.empleados', 'public.empleado_arreglos', 'public.empleado_movimientos']) t LOOP
      IF has_table_privilege('anon', g.t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_table_privilege('authenticated', g.t, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
         OR has_any_column_privilege('anon', g.t, 'SELECT,INSERT,UPDATE,REFERENCES')
         OR has_any_column_privilege('authenticated', g.t, 'SELECT,INSERT,UPDATE,REFERENCES') THEN
        v_fallas := v_fallas || format('13 %s tiene privilegios para anon o authenticated', g.t);
      END IF;
      IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = g.t::regclass)
         OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = g.t::regclass) THEN
        v_fallas := v_fallas || format('13 %s sin RLS o con policies', g.t);
      END IF;
    END LOOP;
    v_fallas := v_fallas || pg_temp.chk(has_column_privilege('authenticated', 'public.gastos', 'empleado_id', 'SELECT')
                                        AND NOT has_column_privilege('authenticated', 'public.gastos', 'empleado_id', 'UPDATE')
                                        AND NOT has_column_privilege('anon', 'public.gastos', 'empleado_id', 'SELECT'),
                  '13 gastos.empleado_id no quedo legible para authenticated y cerrado al resto');
    SELECT count(*) INTO v_n FROM public.auditoria_definer_sin_rol()
     WHERE firma ~ '^(_?guardar_gasto|listar_personal|obtener_cuenta_empleado|empleados_para_elegir|cliente_admite_adelanto_sueldo|guardar_empleado|guardar_arreglo_empleado|dar_de_baja_empleado|reactivar_empleado|registrar_movimiento_empleado|revertir_movimiento_empleado|_empleado_visible|_empleado_json|_cuenta_empleado_conciliar)\(';
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('13 %s funciones de esta migracion en rojo en SEG-A', v_n));
    v_j := public.auditoria_fechas_utc();
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j->'funciones') f
                                                     WHERE f->>'nombre' ~ '(empleado|personal|_guardar_gasto)'),
                  format('13 auditoria_fechas_utc ve funciones de esta migracion: %s', v_j->'funciones'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('13 · error: %s', SQLERRM);
  END;

  -- ===================================================== 14 · invariantes ===
  BEGIN
    -- EMP-A por empleado: lo vivo de cada pago del libro va entero al empleado
    -- cuyo movimiento lleva el cliente de hoy del pago, y 0 a los demas; un
    -- pago del libro sin ese movimiento tambien cuenta.
    SELECT count(*) INTO v_n FROM (
      SELECT m.pago_id, m.empleado_id, sum(m.monto) AS s,
             COALESCE((SELECT -p.monto FROM pagos p
                        WHERE p.id = m.pago_id AND p.forma_pago = 'adelanto_sueldo'
                          AND EXISTS (SELECT 1 FROM empleado_movimientos m2
                                       WHERE m2.pago_id = m.pago_id AND m2.empleado_id = m.empleado_id
                                         AND m2.cliente_id = p.cliente_id)), 0) AS obj
        FROM empleado_movimientos m WHERE m.pago_id IS NOT NULL GROUP BY m.pago_id, m.empleado_id) x
     WHERE x.s <> x.obj;
    v_n := v_n + (SELECT count(*) FROM pagos p
                   WHERE p.forma_pago = 'adelanto_sueldo'
                     AND EXISTS (SELECT 1 FROM empleado_movimientos m WHERE m.pago_id = p.id)
                     AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m WHERE m.pago_id = p.id AND m.cliente_id = p.cliente_id));
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('14 EMP-A por empleado: %s pagos o empleados no cuadran', v_n));
    -- EMP-A: lo de cada pago, borrados incluidos, es -monto vivo, o 0.
    SELECT count(*) INTO v_n FROM (
      SELECT m.pago_id, sum(m.monto) AS s,
             COALESCE((SELECT -p.monto FROM pagos p WHERE p.id = m.pago_id AND p.forma_pago = 'adelanto_sueldo'), 0) AS obj
        FROM empleado_movimientos m WHERE m.pago_id IS NOT NULL GROUP BY m.pago_id) x
     WHERE x.s <> x.obj;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('14 EMP-A: %s pagos no cuadran con su cuenta', v_n));
    -- EMP-B: lo de cada gasto, por empleado, es +monto para el suyo si es de un
    -- empleado y no esta anulado, o 0; y no falta ninguno.
    SELECT count(*) INTO v_n FROM (
      SELECT m.gasto_id, m.empleado_id, sum(m.monto) AS s,
             (SELECT CASE WHEN gg.origen_pago = 'empleado' AND gg.anulado_at IS NULL AND gg.empleado_id = m.empleado_id
                          THEN gg.monto_total ELSE 0 END FROM gastos gg WHERE gg.id = m.gasto_id) AS obj
        FROM empleado_movimientos m WHERE m.gasto_id IS NOT NULL GROUP BY m.gasto_id, m.empleado_id) x
     WHERE x.s <> x.obj;
    v_n := v_n + (SELECT count(*) FROM gastos gg
                   WHERE gg.origen_pago = 'empleado' AND gg.anulado_at IS NULL
                     AND NOT EXISTS (SELECT 1 FROM empleado_movimientos m WHERE m.gasto_id = gg.id AND m.empleado_id = gg.empleado_id));
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('14 EMP-B: %s gastos no cuadran con su cuenta', v_n));
    -- Nadie quedo con un movimiento de un pago que no es adelanto ni lo fue.
    v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM empleado_movimientos) > 20,
                  format('14 el ensayo dejo solo %s movimientos: algun caso no corrio', (SELECT count(*) FROM empleado_movimientos)));
    v_ch_fin := (pg_temp.audit(v_a1, v_t)->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin = v_ch_ini, format('14 critical_high_en_rojo paso de %s a %s', v_ch_ini, v_ch_fin));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('14 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gastos 4 (lunes %, E1 %, E2 %, C1 %, pedido %): alta con saldo al empezar y visibilidad por sucursal y de las dos; encargado y transportista sin listar_personal y el encargado con cinco claves; vinculos y sus rechazos; nadie se toca a si mismo; mercaderia por FIFO y su rechazo sin vinculo; el movimiento sigue al pago al bajarlo, partirlo y borrarlo; historicos afuera; cambio de cliente; reintegro por alta, monto, empleado, anulacion y oficina; movimientos a mano y reversiones; arreglos; baja y reactivacion; GAS-1; permisos; EMP-A y EMP-B; critical_high_en_rojo % al empezar y % al final',
    v_lunes, e1, e2, c1, v_ped, v_ch_ini, v_ch_fin;
END
$ensayo$;
