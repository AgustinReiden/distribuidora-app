-- Ensayo de la migración "un día controlado no se reabre como efecto secundario" (#1342).
--   1 · Por REST, con la sesión de cada rol, sobre un día con el control confirmado:
--       R1 el encargado no entrega con esa fecha;
--       R2 el admin tampoco;
--       R3 el admin no le saca la entrega a ese día (le cambia la fecha);
--       R4 el admin no revierte la entrega (vuelve a asignado, sin fecha);
--       R5 el chofer tampoco entrega con esa fecha (como antes);
--       y en todos el control sigue en pie.
--   2 · Lo que sigue igual:
--       R6 el encargado no entrega en un día con un control en disconformidad: desde la T5
--          (D8, decisión del dueño 26/11) cuenta como cerrada, y el control sigue;
--       S1 el server (DEFINER) sigue descartando el control al mover una entrega;
--       M1 las dos masivas rechazan el día controlado y el control sigue;
--       M2 marcar_entregas_masivo entrega en un día libre.
--       D1 el botón "Reabrir control" (desmarcar_rendicion_controlada): el encargado
--          reabre el día y la entrega con esa fecha ya entra;
--       D2 el encargado no reabre la suya (#1328);
--       B1 a una baja con chofer y fecha de un día controlado, el que no es oficina le
--          cambia la fecha y recibe el mensaje de la baja, no el del control.
--   3 · El orden de los locks (lo que el arnés mide en concurrencia, C9):
--       L1 las dos masivas toman la rendición (compartida) antes que los pedidos, y
--          miran el control después de tomarlos;
--       L2 el trigger toma la rendición compartida sin esperar (try) y vuelve a mirar
--          el control para lo que llega por REST;
--       L3 desmarcar_rendicion_controlada toma la rendición antes de borrar el control.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
-- Desde #1597 (mig 505) una entrega va de hoy hasta los días atrás de la política (7 sin fila; el
-- admin llega a 60) y desde #1440 un pago no es futuro: el 2099 ya no entra. Los días de los
-- controles y las entregas son seis de los últimos siete en que el chofer no tiene ningún
-- control propio (y corta con 'ENSAYO SIN DATOS' si no los hay): v_dc el controlado, v_dd otro
-- libre, v_ds y v_ds2 los del server, v_dis el de la disconformidad y v_dl el libre de la masiva.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en R1, R2, R3, R4, L1, L2 y L3 (y R5, M1 y M2
-- en cascada: R1 ya borró el control del 05); después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-dia-controlado-1342.sql

CREATE OR REPLACE FUNCTION pg_temp.t2_como(p_uid uuid, p_suc bigint) RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true),
         set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';

  v_suc     bigint;
  v_chofer  uuid;   -- reparte en v_suc, no es admin ni encargado
  v_enc     uuid;   -- encargado (o admin si no hay) de v_suc, distinto del chofer
  v_admin   uuid;   -- admin de v_suc
  v_cli     bigint; -- cliente activo de v_suc
  v_hoy     date := public._tablero_hoy();
  v_dias    date[];
  v_dc      date;   -- el día controlado (R1–R5, M1, D1, B1)
  v_dd      date;   -- otro día libre (R3, B1 y el control del encargado de D2)
  v_ds      date;   -- el día controlado que mueve el server (S1)
  v_ds2     date;   -- adonde lo mueve
  v_dis     date;   -- el día en disconformidad (R6)
  v_dl      date;   -- el día libre de la masiva (M2)

  v_ped     bigint; -- asignado a v_chofer, sin entregar
  v_pede    bigint; -- entregado el día controlado
  v_peds    bigint; -- entregado el día controlado, para el server
  v_pedb    bigint; -- cancelado, con chofer y fecha del día controlado
  v_res     text;
  v_n       int;
  v_src     text;
  v_caso    record;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, us.sucursal_id INTO v_chofer, v_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE COALESCE(pf.activo, true) AND pf.rol NOT IN ('admin', 'encargado')
     AND public._actua_como_transportista(pf.id, us.sucursal_id)
     AND EXISTS (SELECT 1 FROM perfiles p3 JOIN usuario_sucursales u3 ON u3.usuario_id = p3.id
                  WHERE u3.sucursal_id = us.sucursal_id AND p3.rol = 'admin' AND COALESCE(p3.activo, true))
   ORDER BY us.sucursal_id, pf.id LIMIT 1;
  IF v_chofer IS NULL THEN
    RAISE EXCEPTION 'ENSAYO SIN DATOS: no hay una sucursal con chofer (no staff) y admin';
  END IF;

  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' AND COALESCE(pf.activo, true)
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_enc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'encargado' AND COALESCE(pf.activo, true)
   ORDER BY pf.id LIMIT 1;
  v_enc := COALESCE(v_enc, v_admin);

  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT COALESCE(c.reservado_admin, false)
     AND c.tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY c.id LIMIT 1;

  v_dias := ARRAY(
    SELECT d::date
      FROM generate_series(v_hoy::timestamp,
                           (v_hoy - COALESCE((SELECT pc.dias_atras_fecha_pedido FROM politicas_comerciales pc
                                               WHERE pc.sucursal_id = v_suc), 7))::timestamp,
                           interval '-1 day') d
     WHERE NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                        WHERE rc.transportista_id = v_chofer AND rc.sucursal_id = v_suc AND rc.fecha = d::date)
     ORDER BY d DESC LIMIT 6);
  IF cardinality(v_dias) < 6 THEN
    RAISE EXCEPTION 'ENSAYO SIN DATOS: el chofer % no tiene seis días sin control en el rango de la fecha de entrega', v_chofer;
  END IF;
  v_dc := v_dias[1]; v_dd := v_dias[2]; v_ds := v_dias[3]; v_ds2 := v_dias[4]; v_dis := v_dias[5]; v_dl := v_dias[6];

  RAISE NOTICE 'datos: sucursal % · chofer % · encargado % · admin % · cliente % · días %',
    v_suc, v_chofer, v_enc, v_admin, v_cli, v_dias;

  -- Pedidos de prueba, como el server (postgres: los guards de API no corren).
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, stock_descontado, forma_pago, estado_pago)
  VALUES (v_cli, v_suc, v_admin, v_admin, v_hoy, 100, 100, 0, 100, 'ZZ', 'asignado', v_chofer, true, 'efectivo', 'pendiente')
  RETURNING id INTO v_ped;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, fecha_entrega, stock_descontado,
                       forma_pago, estado_pago)
  VALUES (v_cli, v_suc, v_admin, v_admin, v_hoy, 100, 100, 0, 100, 'ZZ', 'entregado', v_chofer,
          (v_dc::text || ' 22:30 America/Argentina/Buenos_Aires')::timestamptz, true, 'efectivo', 'pendiente')
  RETURNING id INTO v_pede;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, fecha_entrega, stock_descontado,
                       forma_pago, estado_pago)
  VALUES (v_cli, v_suc, v_admin, v_admin, v_hoy, 100, 100, 0, 100, 'ZZ', 'entregado', v_chofer,
          (v_ds::text || ' 12:00 America/Argentina/Buenos_Aires')::timestamptz, true, 'efectivo', 'pendiente')
  RETURNING id INTO v_peds;

  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, created_at, controlada_at, controlada_por)
  VALUES (v_dc, v_chofer, v_suc, 'confirmada', now(), now(), v_admin),
         (v_ds, v_chofer, v_suc, 'confirmada', now(), now(), v_admin),
         (v_dis, v_chofer, v_suc, 'disconformidad', now(), now(), v_admin);

  -- --------------------------------------------- 1 · REST sobre el día 05 ---
  FOR v_caso IN
    SELECT * FROM (VALUES
      ('R1 el encargado entregó con la fecha de un día controlado', v_enc, v_ped,
       format($q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = '%1$s 12:00-03', transportista_id = $2 WHERE id = $1$q$, v_dc, v_dd)),
      ('R2 el admin entregó con la fecha de un día controlado', v_admin, v_ped,
       format($q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = '%1$s 12:00-03', transportista_id = $2 WHERE id = $1$q$, v_dc, v_dd)),
      ('R3 el admin le sacó la entrega a un día controlado', v_admin, v_pede,
       format($q$UPDATE public.pedidos SET fecha_entrega = '%2$s 12:00-03' WHERE id = $1 AND $2 IS NOT NULL$q$, v_dc, v_dd)),
      ('R4 el admin revirtió una entrega de un día controlado', v_admin, v_pede,
       format($q$UPDATE public.pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = $1 AND $2 IS NOT NULL$q$, v_dc, v_dd)),
      ('R5 el chofer entregó con la fecha de un día controlado', v_chofer, v_ped,
       format($q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = '%1$s 12:00-03' WHERE id = $1 AND $2 IS NOT NULL$q$, v_dc, v_dd))
    ) AS t(nombre, actor, pedido, sql)
  LOOP
    PERFORM pg_temp.t2_como(v_caso.actor, v_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE v_caso.sql USING v_caso.pedido, v_chofer;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_res := 'ok ' || v_n;
    EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    SELECT count(*) INTO v_n FROM rendiciones_control
     WHERE fecha = v_dc AND transportista_id = v_chofer AND sucursal_id = v_suc;
    IF v_res NOT LIKE '42501%ya fue controlada%' OR v_n <> 1 THEN
      v_fallas := v_fallas || format('%s (%s, controles del día: %s)', v_caso.nombre, v_res, v_n);
    END IF;
  END LOOP;

  -- ---------------------------------------------------- 2 · lo que sigue ---
  -- R6 · el encargado entrega el 20, en disconformidad: desde la T5 (D8) no entra y el control sigue.
  PERFORM pg_temp.t2_como(v_enc, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE format($q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = '%s 22:30-03', transportista_id = $2 WHERE id = $1$q$, v_dis)
      USING v_ped, v_chofer;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM rendiciones_control
   WHERE fecha = v_dis AND transportista_id = v_chofer AND sucursal_id = v_suc;
  IF v_res NOT LIKE '42501%ya fue controlada%' OR v_n <> 1 THEN
    v_fallas := v_fallas || format('R6 la entrega en un día con una disconformidad entró o la descartó (%s, quedan %s)', v_res, v_n);
  END IF;

  -- S1 · el server mueve la entrega de un día controlado: descarta el control, por diseño.
  UPDATE pedidos SET fecha_entrega = (v_ds2::text || ' 12:00 America/Argentina/Buenos_Aires')::timestamptz WHERE id = v_peds;
  SELECT count(*) INTO v_n FROM rendiciones_control
   WHERE fecha = v_ds AND transportista_id = v_chofer AND sucursal_id = v_suc;
  IF v_n <> 0 THEN v_fallas := v_fallas || text 'S1 el server ya no descarta el control al mover una entrega'; END IF;

  -- M1 · las dos masivas, sobre el día controlado.
  UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_ped;
  PERFORM pg_temp.t2_como(v_admin, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.marcar_entregas_masivo(ARRAY[$1]::bigint[], $2, $3)$q$ INTO v_n USING v_ped, v_chofer, v_dc;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '42501%ya fue controlada%' THEN v_fallas := v_fallas || ('M1 marcar_entregas_masivo entregó en un día controlado: ' || v_res); END IF;

  PERFORM pg_temp.t2_como(v_admin, v_suc);
  BEGIN
    v_n := public.marcar_entrega_y_pago_masivo_impl(ARRAY[v_ped], v_chofer, 'efectivo', v_dc);
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  IF v_res NOT LIKE '42501%ya fue controlada%' THEN v_fallas := v_fallas || ('M1 entrega y pago entregó en un día controlado: ' || v_res); END IF;

  SELECT count(*) INTO v_n FROM rendiciones_control
   WHERE fecha = v_dc AND transportista_id = v_chofer AND sucursal_id = v_suc;
  IF v_n <> 1 THEN v_fallas := v_fallas || text 'M1 el control del día se borró'; END IF;

  -- M2 · la masiva entrega en un día libre. La de entrega y pago no: los controles
  -- de 2099 cierran la caja para toda fecha real y una fecha futura no se cobra. La
  -- mide el arnés (C9).
  PERFORM pg_temp.t2_como(v_admin, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.marcar_entregas_masivo(ARRAY[$1]::bigint[], $2, $3)$q$ INTO v_n USING v_ped, v_chofer, v_dl;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res <> 'ok 1' THEN v_fallas := v_fallas || ('M2 marcar_entregas_masivo no entregó en un día libre: ' || v_res); END IF;

  -- D1 · el botón "Reabrir control": el encargado reabre el día controlado del chofer, y después
  -- la entrega con esa fecha ya entra.
  UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_ped;
  PERFORM pg_temp.t2_como(v_enc, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE $q$SELECT public.desmarcar_rendicion_controlada($2, $1)$q$ USING v_chofer, v_dc;
    v_res := 'ok';
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO v_n FROM rendiciones_control
   WHERE fecha = v_dc AND transportista_id = v_chofer AND sucursal_id = v_suc;
  IF v_res = 'ok' AND v_n = 0 THEN
    PERFORM pg_temp.t2_como(v_enc, v_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE format($q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = '%s 12:00-03', transportista_id = $2 WHERE id = $1$q$, v_dc)
        USING v_ped, v_chofer;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_res := 'ok ' || v_n;
    EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_res <> 'ok 1' THEN v_fallas := v_fallas || ('D1 reabierto el control, la entrega con esa fecha no entró: ' || v_res); END IF;
  ELSE
    v_fallas := v_fallas || format('D1 el encargado no pudo reabrir el control (%s, quedan %s)', v_res, v_n);
  END IF;

  -- D2 · el encargado no reabre la suya (#1328). Sólo si hay un encargado de verdad.
  IF v_enc <> v_admin THEN
    INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, created_at, controlada_at, controlada_por)
    VALUES (v_dd, v_enc, v_suc, 'confirmada', now(), now(), v_admin);
    PERFORM pg_temp.t2_como(v_enc, v_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE $q$SELECT public.desmarcar_rendicion_controlada($2, $1)$q$ USING v_enc, v_dd;
      v_res := 'ok';
    EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_res NOT LIKE '42501%' THEN v_fallas := v_fallas || ('D2 el encargado reabrió su propia rendición: ' || v_res); END IF;
  ELSE
    RAISE NOTICE 'D2 salteado: la sucursal % no tiene encargado', v_suc;
  END IF;

  -- B1 · una baja del día controlado: el chofer le cambia la fecha. El mensaje es el
  -- de la baja, como antes de #1342.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, transportista_id, fecha_entrega, stock_descontado,
                       forma_pago, estado_pago, motivo_cancelacion)
  VALUES (v_cli, v_suc, v_admin, v_admin, v_hoy, 0, 0, 0, 0, 'ZZ', 'cancelado', v_chofer,
          (v_dc::text || ' 12:00 America/Argentina/Buenos_Aires')::timestamptz, false, 'efectivo', 'pendiente', 'ensayo #1342')
  RETURNING id INTO v_pedb;
  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, created_at, controlada_at, controlada_por)
  VALUES (v_dc, v_chofer, v_suc, 'confirmada', now(), now(), v_admin)
  ON CONFLICT (fecha, transportista_id, sucursal_id) DO NOTHING;
  PERFORM pg_temp.t2_como(v_chofer, v_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE format($q$UPDATE public.pedidos SET fecha_entrega = '%s 12:00-03' WHERE id = $1$q$, v_dd) USING v_pedb;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := 'ok ' || v_n;
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_res NOT LIKE '42501%está cancelado%' THEN
    v_fallas := v_fallas || ('B1 a la baja le llegó otro mensaje que el de la baja: ' || v_res);
  END IF;

  -- ---------------------------------------------------- 3 · los locks ---
  -- L1 · en las dos masivas: la rendición antes que el primer lock de pedidos, y el
  -- control mirado después del último (los recorridos).
  FOR v_caso IN
    SELECT * FROM (VALUES ('public.marcar_entregas_masivo(bigint[],uuid,date)'),
                          ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)')) AS t(firma)
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE oid = v_caso.firma::regprocedure;
    IF position('PERFORM pg_advisory_xact_lock_shared' in v_src) = 0
       OR position('PERFORM pg_advisory_xact_lock_shared' in v_src) > position('FROM pedidos' || E'\n' || '    WHERE id = ANY(p_pedido_ids)' in v_src)
       OR position('control_rendicion_cerrado' in v_src) < position('FROM recorridos' in v_src) THEN
      v_fallas := v_fallas || ('L1 ' || v_caso.firma || ' no toma la rendición antes que los pedidos o mira el control antes de tomarlos');
    END IF;
  END LOOP;

  -- L2 · el trigger: try de la rendición y control vuelto a mirar, para lo de REST.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = 'public.anular_control_por_cambio_fecha_entrega()'::regprocedure;
  IF position('pg_try_advisory_xact_lock_shared' in v_src) = 0 OR position('app.pedidos_por_rest' in v_src) = 0
     OR position('pg_advisory_xact_lock(' in v_src) > 0 THEN
    v_fallas := v_fallas || text 'L2 el trigger no toma la rendición con try (o la espera) para lo que llega por REST';
  END IF;

  -- L3 · el botón: la rendición antes que el control.
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = 'public.desmarcar_rendicion_controlada(date,uuid)'::regprocedure;
  IF position('_rendicion_bloquear' in v_src) = 0
     OR position('_rendicion_bloquear' in v_src) > position('DELETE FROM rendiciones_control' in v_src) THEN
    v_fallas := v_fallas || text 'L3 desmarcar_rendicion_controlada no toma la rendición antes de borrar el control';
  END IF;

  -- ---------------------------------------------------------- resultado ---
  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% de 18):\n%', array_length(v_fallas, 1), array_to_string(v_fallas, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK: 18 aserciones (#1342 R1–R6, S1, M1 ×3, M2, D1, D2, B1, L1 ×2, L2, L3)';
END
$ensayo$;
