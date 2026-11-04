-- Ensayo de la migracion gastos_7_roturas (entrega 7 de gastos: roturas a
-- cargo del empleado).
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
--   <migrations/450_gastos_7_roturas.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Las RPCs se llaman COMO EL FRONT (pg_temp.como, rol authenticated). El
-- producto, el pedido y las salvedades se arman como postgres con los claims
-- del admin. a1 es un admin real de Tucuman, ad uno de las dos; el encargado lo
-- crea el ensayo.
--
--   1  merma con dos cargos          8  bundle viejo de resolver
--   2  merma sin cargo               9  revertir la de salvedad: no
--   3  cargos rechazados             10 revertir la de merma: si
--   4  salvedad: quien y cuando      11 anular revierte las roturas
--   5  salvedad con cargo            12 anular la que te cargo a vos: no
--   6  ya resuelta                   13 la cuenta ve merma_id y salvedad_id
--   7  cliente_rechaza no se carga   14 invariantes y auditoria

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_t      bigint := 1;
  v_tp     bigint := 2;
  v_a1     uuid;
  v_ad     uuid;
  v_en     uuid;
  v_cli    bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_item   bigint;
  s_dan    bigint;
  s_ven    bigint;
  s_rech   bigint;
  e1       bigint;
  e2       bigint;
  e_baja   bigint;
  e_tp     bigint;
  e_a1     bigint;
  v_merma  bigint;
  v_mov    bigint;
  v_n      bigint;
  v_m      numeric;
  v_j      jsonb;
  v_res    jsonb;
  v_stock  integer;
  v_ch_ini int;
  v_ch_fin int;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regprocedure('public.registrar_merma_manual(bigint,integer,text,text,bigint,jsonb)') IS NULL
     OR to_regprocedure('public.resolver_salvedad(bigint,character varying,text,bigint,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existen las RPCs con p_cargos (falta la migracion gastos_7)';
  END IF;

  -- --------------------------------------------------------- contexto ---
  SELECT pf.id INTO v_a1 FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_t]
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_ad FROM perfiles pf WHERE pf.rol = 'admin' AND pf.activo
     AND (SELECT array_agg(us.sucursal_id ORDER BY us.sucursal_id) FROM usuario_sucursales us WHERE us.usuario_id = pf.id) = ARRAY[v_t, v_tp]
   ORDER BY pf.id LIMIT 1;
  SELECT cl.id INTO v_cli FROM clientes cl
   WHERE cl.sucursal_id = v_t AND cl.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = cl.id AND pg.pedido_id IS NULL)
   ORDER BY cl.id LIMIT 1;
  IF v_a1 IS NULL OR v_ad IS NULL OR v_cli IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: a1 %, ad %, cliente %', v_a1, v_ad, v_cli;
  END IF;
  PERFORM set_config('g7.a1', v_a1::text, true);

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

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint)
  RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE
    v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'g7-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), '{}', now(), now());
    RETURN v;
  END
  $f$;

  CREATE FUNCTION pg_temp.alta(p_adm uuid, p_suc bigint)
  RETURNS bigint LANGUAGE sql AS $f$
    SELECT pg_temp.como(p_adm, p_suc, format('SELECT public.guardar_empleado(p_empleado => %L::jsonb)', jsonb_build_object(
      'nombre', 'ZZ g7 ' || gen_random_uuid(), 'puesto', 'preventista', 'sucursal_id', p_suc, 'de_las_dos', false,
      'cuil', NULL, 'fecha_ingreso', NULL, 'telefono', NULL, 'usuario_id', NULL, 'cliente_id', NULL, 'vehiculo_id', NULL,
      'arreglo', jsonb_build_object('vigente_desde', public._tablero_hoy() - 30, 'sueldo', 70000, 'frecuencia', 'semanal',
                                    'comisiona', false),
      'saldo_inicial', NULL)))::bigint;
  $f$;

  -- Una linea de cargo.
  CREATE FUNCTION pg_temp.lc(p_e bigint, p_monto numeric)
  RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('empleado_id', p_e, 'monto', p_monto);
  $f$;

  -- registrar_merma_manual como useMermasQuery: por nombre.
  CREATE FUNCTION pg_temp.mm(p_prod bigint, p_cant int, p_cargos jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_merma_manual(p_producto_id => %s, p_cantidad => %s, p_motivo => %L, '
                  'p_observaciones => %L, p_sucursal_id => 1, p_cargos => %L::jsonb)::text',
                  p_prod, p_cant, 'rotura', 'ensayo gastos 7', p_cargos);
  $f$;

  -- resolver_salvedad como useSalvedadesQuery: por nombre.
  CREATE FUNCTION pg_temp.rs(p_salv bigint, p_estado text, p_cargos jsonb)
  RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.resolver_salvedad(p_salvedad_id => %s, p_estado_resolucion => %L, '
                  'p_notas => %L, p_pedido_reprogramado_id => NULL, p_cargos => %L::jsonb)::text',
                  p_salv, p_estado, 'ensayo gastos 7', p_cargos);
  $f$;

  CREATE FUNCTION pg_temp.saldo(p_e bigint)
  RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum(monto), 0) FROM empleado_movimientos WHERE empleado_id = p_e AND tipo = 'rotura';
  $f$;

  CREATE FUNCTION pg_temp.audit(p_adm uuid, p_suc bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.claims(p_adm, p_suc);
    RETURN public.auditoria_integridad();
  END
  $f$;

  v_ch_ini := (pg_temp.audit(v_a1, v_t)->>'critical_high_en_rojo')::int;

  -- ----------------------------------------------------------- armado ---
  v_en := pg_temp.u('encargado', v_t);
  e1 := pg_temp.alta(v_a1, v_t);
  e2 := pg_temp.alta(v_a1, v_t);
  e_baja := pg_temp.alta(v_a1, v_t);
  e_tp := pg_temp.alta(v_ad, v_tp);
  PERFORM pg_temp.claims(v_a1, v_t);
  UPDATE empleados SET activo = false, fecha_baja = public._tablero_hoy() WHERE id = e_baja;
  SELECT id INTO e_a1 FROM empleados WHERE usuario_id = v_a1 AND activo AND sucursal_id = v_t ORDER BY id LIMIT 1;
  IF e_a1 IS NULL THEN
    INSERT INTO empleados (sucursal_id, nombre, puesto, usuario_id, creado_por)
    VALUES (v_t, 'ZZ g7 la de a1', 'preventista', v_a1, v_ad) RETURNING id INTO e_a1;
  END IF;

  -- Sin cargo de envio ni compra minima que muevan los totales.
  INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
  VALUES (v_t, 'bloquear', 0, 0, 500)
  ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
    monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
    cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;

  -- Un producto a 600 de costo, y un pedido de 10 con tres salvedades.
  INSERT INTO productos (nombre, precio, stock, costo_promedio, condicion_iva, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo g7', 1210, 100, 600, 'gravado', 21, 0, v_t)
  RETURNING id INTO v_prod;
  v_res := public.crear_pedido_completo(v_cli, 12100, v_a1,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 1210)),
             'ensayo gastos 7', 'efectivo', 'pendiente', NULL, 'FC');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO STRICT v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', 'ensayo g7 dañado', NULL, true, NULL);
  s_dan := (v_res->>'salvedad_id')::bigint;
  v_res := public.registrar_salvedad(v_ped, v_item, 1, 'producto_vencido', 'ensayo g7 vencido', NULL, true, NULL);
  s_ven := (v_res->>'salvedad_id')::bigint;
  v_res := public.registrar_salvedad(v_ped, v_item, 1, 'cliente_rechaza', 'ensayo g7 rechazo', NULL, true, NULL);
  s_rech := (v_res->>'salvedad_id')::bigint;
  IF s_dan IS NULL OR s_ven IS NULL OR s_rech IS NULL
     OR NOT EXISTS (SELECT 1 FROM mermas_stock WHERE salvedad_id = s_dan AND anulada_at IS NULL) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · el armado no dejo las tres salvedades (%, %, %) y la merma de la dañada: %',
      s_dan, s_ven, s_rech, v_res;
  END IF;

  -- ------------------------------------------- 1 · merma con dos cargos ---
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, pg_temp.mm(v_prod, 3, jsonb_build_array(pg_temp.lc(e1, 1000), pg_temp.lc(e2, 800.004))))::jsonb;
    v_merma := (v_j->'merma'->>'id')::bigint;
    v_fallas := v_fallas || pg_temp.chk(jsonb_array_length(v_j->'cargos') = 2, format('1 cargos: %s', v_j->'cargos'));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e1) = -1000 AND pg_temp.saldo(e2) = -800,
                  format('1 saldos %s y %s, esperados -1000 y -800', pg_temp.saldo(e1), pg_temp.saldo(e2)));
    SELECT count(*) INTO v_n FROM empleado_movimientos
     WHERE merma_id = v_merma AND tipo = 'rotura' AND salvedad_id IS NULL AND fecha = public._tablero_hoy()
       AND creado_por = v_a1 AND observacion = 'Rotura: 3 u. de ZZ ensayo g7' AND liquidacion_id IS NULL;
    v_fallas := v_fallas || pg_temp.chk(v_n = 2, format('1 %s lineas con merma, fecha, autor y observacion', v_n));
    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'stock')::int = v_stock, format('1 stock %s y la respuesta %s', v_stock, v_j->>'stock'));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('1 · error: %s', SQLERRM);
  END;

  -- -------------------------------------------- 2 · merma sin cargo ---
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, pg_temp.mm(v_prod, 1, NULL))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->'cargos' = '[]'::jsonb AND (v_j->>'ok')::boolean,
                  format('2 sin cargo: %s', v_j));
    v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE merma_id = (v_j->'merma'->>'id')::bigint),
                  '2 la merma sin cargo dejo movimientos');
    v_j := pg_temp.como(v_a1, v_t, pg_temp.mm(v_prod, 1, '[]'))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->'cargos' = '[]'::jsonb, '2 con [] tambien es sin cargo');
    -- El bundle viejo: cinco argumentos.
    v_j := pg_temp.como(v_a1, v_t, format('SELECT public.registrar_merma_manual(p_producto_id => %s, p_cantidad => 1, '
                                          'p_motivo => %L, p_observaciones => NULL, p_sucursal_id => 1)::text', v_prod, 'otro'))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'ok')::boolean, '2 el bundle viejo no da de baja');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('2 · error: %s', SQLERRM);
  END;

  -- --------------------------------------------- 3 · cargos rechazados ---
  BEGIN
    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    v_n := (SELECT count(*) FROM mermas_stock WHERE producto_id = v_prod);
    v_fallas := v_fallas || pg_temp.falla('3 a si mismo', v_a1, v_t, pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(e_a1, 10))),
                  'no podés cargarte una rotura');
    v_fallas := v_fallas || pg_temp.falla('3 repetido', v_a1, v_t,
                  pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(e1, 10), pg_temp.lc(e1, 20))), 'aparece en dos líneas');
    v_fallas := v_fallas || pg_temp.falla('3 otra sucursal', v_a1, v_t, pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(e_tp, 10))),
                  'no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('3 otra sucursal, admin de las dos', v_ad, v_t,
                  pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(e_tp, 10))), 'no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.falla('3 de baja', v_a1, v_t, pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(e_baja, 10))),
                  'está dado de baja');
    v_fallas := v_fallas || pg_temp.falla('3 monto 0', v_a1, v_t, pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(e1, 0.004))),
                  'monto mayor a 0');
    v_fallas := v_fallas || pg_temp.falla('3 monto negativo', v_a1, v_t, pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(e1, -5))),
                  'monto mayor a 0');
    v_fallas := v_fallas || pg_temp.falla('3 sin monto', v_a1, v_t, pg_temp.mm(v_prod, 1, '[{"empleado_id": 1}]'),
                  'formato inválido');
    v_fallas := v_fallas || pg_temp.falla('3 monto texto', v_a1, v_t,
                  pg_temp.mm(v_prod, 1, jsonb_build_array(jsonb_build_object('empleado_id', e1, 'monto', 'diez'))), 'formato inválido');
    v_fallas := v_fallas || pg_temp.falla('3 no es arreglo', v_a1, v_t, pg_temp.mm(v_prod, 1, pg_temp.lc(e1, 10)),
                  'formato inválido');
    v_fallas := v_fallas || pg_temp.falla('3 empleado inexistente', v_a1, v_t, pg_temp.mm(v_prod, 1, jsonb_build_array(pg_temp.lc(-1, 10))),
                  'no existe o no lo podés ver');
    v_fallas := v_fallas || pg_temp.chk((SELECT stock FROM productos WHERE id = v_prod) = v_stock
                                        AND (SELECT count(*) FROM mermas_stock WHERE producto_id = v_prod) = v_n,
                  '3 un cargo rechazado dejo la merma o movio el stock');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('3 · error: %s', SQLERRM);
  END;

  -- -------------------------------------- 4 · salvedad: quien y cuando ---
  BEGIN
    v_j := pg_temp.como(v_en, v_t, pg_temp.rs(s_dan, 'descuento_transportista', jsonb_build_array(pg_temp.lc(e1, 700))))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->>'error' = 'Sólo un admin le carga una salvedad a un empleado', format('4 encargado: %s', v_j));
    v_j := pg_temp.como(v_en, v_t, pg_temp.rs(s_dan, 'absorcion_empresa', jsonb_build_array(pg_temp.lc(e1, 700))))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->>'error' LIKE 'Sólo «A cargo de empleados»%', format('4 cargo con otra resolución: %s', v_j));
    v_j := pg_temp.como(v_a1, v_t, pg_temp.rs(s_dan, 'descuento_transportista', NULL))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->>'error' LIKE 'Elegí al menos un empleado%', format('4 sin cargos: %s', v_j));
    v_j := pg_temp.como(v_a1, v_t, pg_temp.rs(s_dan, 'descuento_transportista', jsonb_build_array(pg_temp.lc(e_a1, 700))))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->>'error' LIKE '%no podés cargarte una rotura%', format('4 a si mismo: %s', v_j));
    v_fallas := v_fallas || pg_temp.chk((SELECT estado_resolucion FROM salvedades_items WHERE id = s_dan) = 'pendiente'
                                        AND NOT EXISTS (SELECT 1 FROM empleado_movimientos WHERE salvedad_id = s_dan),
                  '4 un rechazo dejo la salvedad resuelta o un movimiento');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('4 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------- 5 · salvedad con cargo ---
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, pg_temp.rs(s_dan, 'descuento_transportista',
                                              jsonb_build_array(pg_temp.lc(e2, 500), pg_temp.lc(e1, 700))))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'success')::boolean AND jsonb_array_length(v_j->'cargos') = 2,
                  format('5 resolver: %s', v_j));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e1) = -1700 AND pg_temp.saldo(e2) = -1300,
                  format('5 saldos %s y %s, esperados -1700 y -1300', pg_temp.saldo(e1), pg_temp.saldo(e2)));
    SELECT count(*) INTO v_n FROM empleado_movimientos
     WHERE salvedad_id = s_dan AND merma_id IS NULL AND tipo = 'rotura'
       AND observacion = 'Rotura: 2 u. de ZZ ensayo g7 · salvedad #' || s_dan;
    v_fallas := v_fallas || pg_temp.chk(v_n = 2, format('5 %s lineas con la salvedad y su observacion', v_n));
    v_fallas := v_fallas || pg_temp.chk((SELECT estado_resolucion FROM salvedades_items WHERE id = s_dan) = 'descuento_transportista',
                  '5 la salvedad no quedo resuelta');
    -- La vencida, cargada por ad a la ficha de a1 (para el caso 12).
    v_j := pg_temp.como(v_ad, v_t, pg_temp.rs(s_ven, 'descuento_transportista', jsonb_build_array(pg_temp.lc(e_a1, 600))))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'success')::boolean, format('5 ad le carga a a1: %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('5 · error: %s', SQLERRM);
  END;

  -- -------------------------------------------------- 6 · ya resuelta ---
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, pg_temp.rs(s_dan, 'descuento_transportista', jsonb_build_array(pg_temp.lc(e1, 700))))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->>'error' = 'Ya resuelta' AND pg_temp.saldo(e1) = -1700, format('6: %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('6 · error: %s', SQLERRM);
  END;

  -- ------------------------------------- 7 · cliente_rechaza no se carga ---
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, pg_temp.rs(s_rech, 'descuento_transportista', jsonb_build_array(pg_temp.lc(e1, 100))))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->>'error' LIKE 'Sólo una salvedad por mercadería dañada%', format('7: %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('7 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------- 8 · bundle viejo ---
  BEGIN
    v_j := pg_temp.como(v_en, v_t, format('SELECT public.resolver_salvedad(p_salvedad_id => %s, p_estado_resolucion => %L, '
                                          'p_notas => %L, p_pedido_reprogramado_id => NULL)::text', s_rech, 'absorcion_empresa', 'viejo'))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'success')::boolean AND v_j->'cargos' = '[]'::jsonb, format('8 encargado con 4 args: %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('8 · error: %s', SQLERRM);
  END;

  -- ------------------------------------ 9 · revertir la de salvedad: no ---
  BEGIN
    SELECT id INTO v_mov FROM empleado_movimientos WHERE salvedad_id = s_dan AND empleado_id = e1;
    v_fallas := v_fallas || pg_temp.falla('9 rotura de salvedad', v_a1, v_t,
                  format('SELECT public.revertir_movimiento_empleado(%s, %L)::text', v_mov, 'ensayo'),
                  'Una rotura de salvedad se deshace anulando la salvedad');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('9 · error: %s', SQLERRM);
  END;

  -- ------------------------------------- 10 · revertir la de merma: si ---
  BEGIN
    SELECT id INTO v_mov FROM empleado_movimientos WHERE merma_id = v_merma AND empleado_id = e1;
    v_n := pg_temp.como(v_a1, v_t, format('SELECT public.revertir_movimiento_empleado(%s, %L)::text', v_mov, 'era de otro'))::bigint;
    v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM empleado_movimientos
                                                 WHERE id = v_n AND revierte_id = v_mov AND tipo = 'rotura' AND monto = 1000
                                                   AND merma_id = v_merma AND salvedad_id IS NULL),
                  '10 la reversion no es la rotura +1000 de la misma merma');
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e1) = -700, format('10 saldo de e1 %s, esperado -700', pg_temp.saldo(e1)));
    v_fallas := v_fallas || pg_temp.falla('10 dos veces', v_a1, v_t,
                  format('SELECT public.revertir_movimiento_empleado(%s, %L)::text', v_mov, 'otra vez'), 'ya está revertido');
    v_fallas := v_fallas || pg_temp.falla('10 la reversion', v_a1, v_t,
                  format('SELECT public.revertir_movimiento_empleado(%s, %L)::text', v_n, 'otra vez'), 'revierte a otro');
    -- Una rotura liquidada tambien se revierte (la de e2).
    SELECT id INTO v_mov FROM empleado_movimientos WHERE merma_id = v_merma AND empleado_id = e2;
    UPDATE empleado_movimientos SET liquidacion_id = (SELECT min(id) FROM empleado_liquidaciones) WHERE id = v_mov;
    v_n := pg_temp.como(v_a1, v_t, format('SELECT public.revertir_movimiento_empleado(%s, %L)::text', v_mov, 'liquidada'))::bigint;
    v_fallas := v_fallas || pg_temp.chk((SELECT liquidacion_id FROM empleado_movimientos WHERE id = v_n) IS NULL,
                  '10 la reversion de una liquidada no quedo para la liquidacion siguiente');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('10 · error: %s', SQLERRM);
  END;

  -- ---------------------------------- 11 · anular revierte las roturas ---
  BEGIN
    v_m := pg_temp.saldo(e1);
    v_j := pg_temp.como(v_a1, v_t, format('SELECT public.anular_salvedad(%s, %L)::text', s_dan, 'ensayo g7'))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'success')::boolean, format('11 anular: %s', v_j));
    SELECT count(*) INTO v_n FROM empleado_movimientos r JOIN empleado_movimientos o ON o.id = r.revierte_id
     WHERE o.salvedad_id = s_dan AND r.salvedad_id = s_dan AND r.tipo = 'rotura' AND r.monto = -o.monto
       AND r.observacion = 'Anulación de la salvedad #' || s_dan || ': ensayo g7';
    v_fallas := v_fallas || pg_temp.chk(v_n = 2, format('11 %s reversiones de la salvedad', v_n));
    v_fallas := v_fallas || pg_temp.chk(pg_temp.saldo(e1) = v_m + 700 AND pg_temp.saldo(e1) = 0,
                  format('11 saldo de e1 %s, esperado 0', pg_temp.saldo(e1)));
    v_fallas := v_fallas || pg_temp.chk((SELECT anulada_at FROM mermas_stock WHERE salvedad_id = s_dan ORDER BY id LIMIT 1) IS NOT NULL,
                  '11 la merma de la salvedad no quedo anulada');
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('11 · error: %s', SQLERRM);
  END;

  -- --------------------------- 12 · anular la que te cargo a vos: no ---
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, format('SELECT public.anular_salvedad(%s, %L)::text', s_ven, 'mia'))::jsonb;
    v_fallas := v_fallas || pg_temp.chk(v_j->>'codigo' = 'rotura_propia'
                                        AND (SELECT estado_resolucion FROM salvedades_items WHERE id = s_ven) = 'descuento_transportista',
                  format('12 a1 anula la suya: %s', v_j));
    v_j := pg_temp.como(v_ad, v_t, format('SELECT public.anular_salvedad(%s, %L)::text', s_ven, 'la anula otro'))::jsonb;
    v_fallas := v_fallas || pg_temp.chk((v_j->>'success')::boolean
                                        AND (SELECT COALESCE(sum(monto), 0) FROM empleado_movimientos WHERE salvedad_id = s_ven) = 0,
                  format('12 ad la anula: %s', v_j));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('12 · error: %s', SQLERRM);
  END;

  -- --------------------------- 13 · la cuenta ve merma_id y salvedad_id ---
  BEGIN
    v_j := pg_temp.como(v_a1, v_t, format('SELECT public.obtener_cuenta_empleado(%s)::text', e1))::jsonb;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j->'movimientos') m
     WHERE m->>'tipo' = 'rotura' AND m ? 'merma_id' AND m ? 'salvedad_id'
       AND num_nonnulls(m->>'merma_id', m->>'salvedad_id') = 1;
    v_fallas := v_fallas || pg_temp.chk(v_n = 4, format('13 %s roturas de e1 con su origen, esperadas 4', v_n));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('13 · error: %s', SQLERRM);
  END;

  -- ------------------------------------- 14 · invariantes y auditoria ---
  BEGIN
    SELECT count(*) INTO v_n FROM empleado_movimientos
     WHERE tipo = 'rotura' AND revierte_id IS NULL AND monto >= 0;
    v_fallas := v_fallas || pg_temp.chk(v_n = 0, format('14 %s roturas sin signo', v_n));
    BEGIN
      INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion)
      VALUES (e1, public._tablero_hoy(), 'rotura', -10, 'sin origen');
      v_fallas := v_fallas || '14 una rotura sin merma ni salvedad entro'::text;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
      INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, merma_id)
      VALUES (e1, public._tablero_hoy(), 'ajuste', -10, 'ajuste con merma', v_merma);
      v_fallas := v_fallas || '14 un ajuste con merma entro'::text;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    v_j := pg_temp.audit(v_a1, v_t);
    v_ch_fin := (v_j->>'critical_high_en_rojo')::int;
    v_fallas := v_fallas || pg_temp.chk(v_ch_fin = v_ch_ini, format('14 critical_high_en_rojo paso de %s a %s: %s', v_ch_ini, v_ch_fin,
                  (SELECT array_agg(c->>'id') FROM jsonb_array_elements(v_j->'checks') c
                    WHERE (c->>'ok')::boolean IS FALSE AND c->>'severidad' IN ('critical', 'high'))));
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('14 · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · gastos 7 (roturas %, revertidas %): casos 1 a 14; critical_high_en_rojo % al empezar y % al final',
    (SELECT count(*) FROM empleado_movimientos WHERE tipo = 'rotura' AND revierte_id IS NULL),
    (SELECT count(*) FROM empleado_movimientos WHERE tipo = 'rotura' AND revierte_id IS NOT NULL),
    v_ch_ini, v_ch_fin;
END
$ensayo$;
