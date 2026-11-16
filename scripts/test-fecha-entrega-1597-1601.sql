-- Ensayo de la fecha de entrega (GTO-15, #1597; 1598-b2, #1598) y de la guarda de
-- marcar_no_entregado (SEG-1, #1601). Migración: 505_fecha_entrega_con_rango.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja
-- rastro. Sin la migración falla en F0 (la función nueva no existe) y, si se la
-- saltea, en F1 (el encargado entrega con una fecha de hace un mes), en S1 (un
-- preventista marca la no entrega de un pedido sin chofer) y en S3 (el gate no ve
-- la guarda).
--
-- La regla (decisión del dueño, #1597): quien no es admin fecha una entrega de hoy
-- hasta politicas_comerciales.dias_atras_fecha_pedido días atrás (7 sin fila); el
-- admin, hasta 60 días atrás (_fecha_carga_piso, el piso de un gasto); nadie con
-- fecha futura. Sólo si el día cambia: una entrega vieja ya cargada se sigue
-- tocando. Sin piso, una entrega fechada en 2016 fabricaba la "rendición que
-- existe" y el gasto de ese día salteaba el piso de 60 días (GTO-10 de la
-- auditoría).
--
--   F0 · _fecha_entrega_fuera_de_rango existe, sin EXECUTE para PUBLIC ni anon, y
--        da los textos del rango (techo, piso del no admin, piso del admin).
--   F1 · marcar_entregas_masivo, encargado: hoy pasa; hoy-5 (la política de la
--        sucursal) pasa; hoy-6 y hoy-30 no; mañana no.
--   F2 · marcar_entregas_masivo, admin: hoy-60 pasa; hoy-61 y mañana no.
--   F3 · marcar_entrega_y_pago_masivo, admin: hoy-30 pasa (y el cobro va con esa
--        fecha); hoy-61 no. El encargado sigue sólo en hoy (la regla del cobro),
--        y con hoy-30 lo frena la fecha de entrega.
--   F4 · La entrega de a una por REST (el PATCH del chofer): hoy-2 pasa, hoy-6 y
--        mañana no. Mover la hora dentro del mismo día pasa aunque el día sea más
--        viejo que el piso. Un preventista que no puede entregar recibe el 42501
--        de siempre, no el motivo del rango.
--   F5 · Una entrega vieja (hoy-90) ya cargada: el encargado le cambia las notas
--        (actualizar_fechas_y_notas_pedido) y pasa; moverla a hoy-50 no; el admin
--        sí la mueve a hoy-50, pero no a hoy-61. Volverla a pendiente (fecha NULL)
--        pasa.
--   F6 · El ataque de GTO-10 entero: la entrega de 2016 no entra, y sin ella el
--        gasto de ese día tampoco.
--   S1 · marcar_no_entregado sobre un pedido de una ruta en curso sin chofer
--        (transportista_id NULL): el preventista, el depósito y el chofer de la ruta
--        no pasan; el encargado sí.
--   S2 · Con el chofer asignado, el chofer pasa y un preventista no (no cambió).
--   S3 · auditoria_rpcs_definer()->guardas_nulas ve `IF NOT (x = uid OR …)` y no la
--        forma con COALESCE; marcar_no_entregado ya no aparece.

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_enc    uuid;
  v_tra    uuid;
  v_tra2   uuid;
  v_prev   uuid;
  v_dep    uuid;
  v_cli    bigint;
  v_rub    bigint;
  v_rec    bigint;
  v_p      bigint[] := '{}';
  v_id     bigint;
  v_t      text;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------------- F0 ---
  IF to_regprocedure('public._fecha_entrega_fuera_de_rango(date,bigint,boolean)') IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA',
      MESSAGE = 'ENSAYO FALLÓ · F0: _fecha_entrega_fuera_de_rango(date,bigint,boolean) no existe (falta la migración)';
  END IF;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'm9-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'M9 ' || p_rol), now(), now());
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
  -- Corre p_sql como p_uid (authenticated) y devuelve 'PASA' o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.intenta(p_uid uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text;
  BEGIN
    PERFORM pg_temp.como(p_uid, 1);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql;
      r := 'PASA';
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- Un pedido pendiente de 100 en la sucursal 1, cargado por el server.
  CREATE FUNCTION pg_temp.ped(p_cli bigint, p_vend uuid, p_tra uuid) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura, transportista_id)
    VALUES (p_cli, 1, p_vend, 100, CASE WHEN p_tra IS NULL THEN 'pendiente' ELSE 'asignado' END,
            public._tablero_hoy(), 'app', 'ZZ', p_tra)
    RETURNING id INTO v;
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.dia(p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('%s %s', estado, COALESCE(((fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)::text, '-'))
      FROM public.pedidos WHERE id = p;
  $f$;

  -- ---------------------------------------------------------------- datos ---
  v_adm  := pg_temp.u('admin', 1);
  v_enc  := pg_temp.u('encargado', 1);
  v_tra  := pg_temp.u('transportista', 1);
  v_tra2 := pg_temp.u('transportista', 1);
  v_prev := pg_temp.u('preventista', 1);
  v_dep  := pg_temp.u('deposito', 1);
  -- La política de la sucursal: 5 días atrás para quien no es admin.
  INSERT INTO politicas_comerciales (sucursal_id, dias_atras_fecha_pedido) VALUES (1, 5)
  ON CONFLICT (sucursal_id) DO UPDATE SET dias_atras_fecha_pedido = 5;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('M9 cliente', 'M9 cliente', 'calle m9', 1) RETURNING id INTO v_cli;
  FOR i IN 1 .. 30 LOOP
    v_p := v_p || pg_temp.ped(v_cli, v_prev, NULL);
  END LOOP;

  -- F0 · los textos.
  v_t := public._fecha_entrega_fuera_de_rango(v_hoy + 1, 1, false);
  IF v_t IS NULL OR v_t NOT LIKE 'La fecha de entrega (%) no puede ser posterior a hoy.%' THEN
    v_fallas := v_fallas || format('F0 · techo del no admin: %s', COALESCE(v_t, 'NULL'));
  END IF;
  IF public._fecha_entrega_fuera_de_rango(v_hoy + 1, 1, true) IS NULL THEN
    v_fallas := v_fallas || 'F0 · el admin entra con fecha futura'::text;
  END IF;
  v_t := public._fecha_entrega_fuera_de_rango(v_hoy - 6, 1, false);
  IF v_t IS NULL OR v_t NOT LIKE '%no puede ser anterior al ' || to_char(v_hoy - 5, 'DD/MM/YYYY') || ': hasta 5 días atrás.%' THEN
    v_fallas := v_fallas || format('F0 · piso del no admin (5 días): %s', COALESCE(v_t, 'NULL'));
  END IF;
  IF public._fecha_entrega_fuera_de_rango(v_hoy - 5, 1, false) IS NOT NULL
     OR public._fecha_entrega_fuera_de_rango(v_hoy, 1, false) IS NOT NULL THEN
    v_fallas := v_fallas || 'F0 · hoy o hoy-5 no entran para el no admin'::text;
  END IF;
  -- Sin fila de política: 7.
  IF public._fecha_entrega_fuera_de_rango(v_hoy - 7, 2, false) IS NOT NULL
     OR public._fecha_entrega_fuera_de_rango(v_hoy - 8, 2, false) IS NULL THEN
    v_fallas := v_fallas || 'F0 · sin política no rige el default de 7 días'::text;
  END IF;
  v_t := public._fecha_entrega_fuera_de_rango(v_hoy - 61, 1, true);
  IF v_t IS NULL OR v_t NOT LIKE '%no puede ser anterior al ' || to_char(v_hoy - 60, 'DD/MM/YYYY') || ': hasta 60 días atrás.' THEN
    v_fallas := v_fallas || format('F0 · piso del admin: %s', COALESCE(v_t, 'NULL'));
  END IF;
  IF public._fecha_entrega_fuera_de_rango(v_hoy - 60, 1, true) IS NOT NULL
     OR public._fecha_entrega_fuera_de_rango(NULL, 1, false) IS NOT NULL THEN
    v_fallas := v_fallas || 'F0 · hoy-60 no entra para el admin, o NULL se juzga'::text;
  END IF;
  IF has_function_privilege('anon', 'public._fecha_entrega_fuera_de_rango(date,bigint,boolean)', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
                 WHERE p.oid = 'public._fecha_entrega_fuera_de_rango(date,bigint,boolean)'::regprocedure
                   AND a.grantee = 0) THEN
    v_fallas := v_fallas || 'F0 · la función nueva tiene EXECUTE para PUBLIC o anon'::text;
  END IF;

  -- ------------------------------------------------------------------- F1 ---
  DECLARE
    r record;
    k int := 0;
  BEGIN
    FOR r IN SELECT * FROM (VALUES ('hoy', 0, 'PASA'), ('hoy-5', 5, 'PASA'), ('hoy-6', 6, '22023'),
                                   ('hoy-30', 30, '22023'), ('mañana', -1, '22023')) AS x(n, d, e) LOOP
      k := k + 1;
      v_t := pg_temp.intenta(v_enc, format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, %L::date)',
                                           v_p[k], v_tra, v_hoy - r.d));
      IF left(v_t, length(r.e)) <> r.e THEN
        v_fallas := v_fallas || format('F1 · encargado, masivo con %s: esperaba %s y dio %s (%s)', r.n, r.e, v_t, pg_temp.dia(v_p[k]));
      END IF;
      v_notas := v_notas || format('F1 %s: %s', r.n, left(v_t, 120));
    END LOOP;
  END;

  -- ------------------------------------------------------------------- F2 ---
  DECLARE
    r record;
    k int := 5;
  BEGIN
    FOR r IN SELECT * FROM (VALUES ('hoy-60', 60, 'PASA'), ('hoy-61', 61, '22023'), ('mañana', -1, '22023')) AS x(n, d, e) LOOP
      k := k + 1;
      v_t := pg_temp.intenta(v_adm, format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, %L::date)',
                                           v_p[k], v_tra, v_hoy - r.d));
      IF left(v_t, length(r.e)) <> r.e THEN
        v_fallas := v_fallas || format('F2 · admin, masivo con %s: esperaba %s y dio %s (%s)', r.n, r.e, v_t, pg_temp.dia(v_p[k]));
      END IF;
      v_notas := v_notas || format('F2 %s: %s', r.n, left(v_t, 120));
    END LOOP;
  END;

  -- ------------------------------------------------------------------- F3 ---
  v_t := pg_temp.intenta(v_adm, format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', %L::date, NULL)',
                                       v_p[9], v_tra, v_hoy - 30));
  IF v_t <> 'PASA' OR pg_temp.dia(v_p[9]) <> format('entregado %s', v_hoy - 30)
     OR NOT EXISTS (SELECT 1 FROM pagos WHERE pedido_id = v_p[9] AND fecha = v_hoy - 30) THEN
    v_fallas := v_fallas || format('F3 · admin, entrega y pago con hoy-30: %s (%s)', v_t, pg_temp.dia(v_p[9]));
  END IF;
  v_t := pg_temp.intenta(v_adm, format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', %L::date, NULL)',
                                       v_p[10], v_tra, v_hoy - 61));
  IF left(v_t, 5) <> '22023' OR v_t NOT LIKE '%fecha de entrega%' THEN
    v_fallas := v_fallas || format('F3 · admin, entrega y pago con hoy-61: %s (%s)', v_t, pg_temp.dia(v_p[10]));
  END IF;
  v_notas := v_notas || format('F3 admin hoy-61: %s', left(v_t, 120));
  v_t := pg_temp.intenta(v_enc, format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', %L::date, NULL)',
                                       v_p[10], v_tra, v_hoy - 30));
  IF left(v_t, 5) <> '22023' OR v_t NOT LIKE '%fecha de entrega%' THEN
    v_fallas := v_fallas || format('F3 · encargado, entrega y pago con hoy-30: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_enc, format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', %L::date, NULL)',
                                       v_p[10], v_tra, v_hoy - 2));
  IF left(v_t, 5) <> '42501' THEN
    v_fallas := v_fallas || format('F3 · encargado, entrega y pago con hoy-2 (sólo hoy): %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_enc, format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', %L::date, NULL)',
                                       v_p[10], v_tra, v_hoy));
  IF v_t <> 'PASA' OR pg_temp.dia(v_p[10]) <> format('entregado %s', v_hoy) THEN
    v_fallas := v_fallas || format('F3 · encargado, entrega y pago con hoy: %s (%s)', v_t, pg_temp.dia(v_p[10]));
  END IF;

  -- ------------------------------------------------------------------- F4 ---
  UPDATE pedidos SET transportista_id = v_tra, estado = 'asignado' WHERE id = ANY (v_p[11:14]);
  v_t := pg_temp.intenta(v_tra, format(
    'UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L, updated_at = now() WHERE id = %s',
    (v_hoy - 2)::text || 'T12:00:00-03:00', v_p[11]));
  IF v_t <> 'PASA' OR pg_temp.dia(v_p[11]) <> format('entregado %s', v_hoy - 2) THEN
    v_fallas := v_fallas || format('F4 · chofer, PATCH con hoy-2: %s (%s)', v_t, pg_temp.dia(v_p[11]));
  END IF;
  v_t := pg_temp.intenta(v_tra, format(
    'UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L, updated_at = now() WHERE id = %s',
    (v_hoy - 6)::text || 'T12:00:00-03:00', v_p[12]));
  IF left(v_t, 5) <> '22023' OR pg_temp.dia(v_p[12]) <> 'asignado -' THEN
    v_fallas := v_fallas || format('F4 · chofer, PATCH con hoy-6: %s (%s)', v_t, pg_temp.dia(v_p[12]));
  END IF;
  v_notas := v_notas || format('F4 chofer hoy-6: %s', left(v_t, 160));
  v_t := pg_temp.intenta(v_tra, format(
    'UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L, updated_at = now() WHERE id = %s',
    (v_hoy + 1)::text || 'T12:00:00-03:00', v_p[13]));
  IF left(v_t, 5) <> '22023' THEN
    v_fallas := v_fallas || format('F4 · chofer, PATCH con mañana: %s (%s)', v_t, pg_temp.dia(v_p[13]));
  END IF;
  -- A quien no puede tocar la fecha le llega ese motivo (42501), no el del rango.
  v_t := pg_temp.intenta(v_prev, format(
    'UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L, transportista_id = %L WHERE id = %s',
    (v_hoy - 30)::text || 'T12:00:00-03:00', v_tra, v_p[17]));
  IF left(v_t, 5) <> '42501' THEN
    v_fallas := v_fallas || format('F4 · preventista, PATCH de entrega con hoy-30: esperaba 42501 y dio %s', v_t);
  END IF;
  -- Entregado viejo del chofer (lo dejó el server): mover la hora dentro del día pasa.
  UPDATE pedidos SET estado = 'entregado',
                     fecha_entrega = ((v_hoy - 20) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id = v_p[14];
  v_t := pg_temp.intenta(v_tra, format(
    'UPDATE public.pedidos SET fecha_entrega = %L WHERE id = %s', (v_hoy - 20)::text || 'T15:00:00-03:00', v_p[14]));
  IF v_t <> 'PASA' THEN
    v_fallas := v_fallas || format('F4 · chofer, mover la hora de una entrega vieja dentro del día: %s', v_t);
  END IF;

  -- ------------------------------------------------------------------- F5 ---
  UPDATE pedidos SET estado = 'entregado', transportista_id = v_tra,
                     fecha_entrega = ((v_hoy - 90) + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires'
   WHERE id = v_p[15];
  v_t := pg_temp.intenta(v_enc, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, %L)', v_p[15], 'nota M9'));
  IF v_t <> 'PASA' OR (SELECT notas FROM pedidos WHERE id = v_p[15]) IS DISTINCT FROM 'nota M9' THEN
    v_fallas := v_fallas || format('F5 · encargado, notas de una entrega de hoy-90: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_enc, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, NULL, NULL, %L::timestamptz)',
                                       v_p[15], (v_hoy - 50)::text || 'T12:00:00-03:00'));
  IF left(v_t, 5) <> '22023' OR pg_temp.dia(v_p[15]) <> format('entregado %s', v_hoy - 90) THEN
    v_fallas := v_fallas || format('F5 · encargado, mover a hoy-50: %s (%s)', v_t, pg_temp.dia(v_p[15]));
  END IF;
  v_t := pg_temp.intenta(v_enc, format('UPDATE public.pedidos SET fecha_entrega = %L WHERE id = %s',
                                       (v_hoy - 50)::text || 'T12:00:00-03:00', v_p[15]));
  IF left(v_t, 5) <> '22023' THEN
    v_fallas := v_fallas || format('F5 · encargado, PATCH a hoy-50: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm, format('UPDATE public.pedidos SET fecha_entrega = %L WHERE id = %s',
                                       (v_hoy - 61)::text || 'T12:00:00-03:00', v_p[15]));
  IF left(v_t, 5) <> '22023' THEN
    v_fallas := v_fallas || format('F5 · admin, PATCH a hoy-61: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_adm, format('UPDATE public.pedidos SET fecha_entrega = %L WHERE id = %s',
                                       (v_hoy - 50)::text || 'T12:00:00-03:00', v_p[15]));
  IF v_t <> 'PASA' OR pg_temp.dia(v_p[15]) <> format('entregado %s', v_hoy - 50) THEN
    v_fallas := v_fallas || format('F5 · admin, PATCH a hoy-50: %s (%s)', v_t, pg_temp.dia(v_p[15]));
  END IF;
  v_t := pg_temp.intenta(v_enc, format('UPDATE public.pedidos SET estado = ''pendiente'', fecha_entrega = NULL, transportista_id = NULL WHERE id = %s',
                                       v_p[15]));
  IF v_t <> 'PASA' THEN
    v_fallas := v_fallas || format('F5 · encargado, volver a pendiente una entrega vieja: %s', v_t);
  END IF;

  -- ------------------------------------------------------------------- F6 ---
  INSERT INTO gasto_rubros (nombre, grupo, activo, creado_por) VALUES ('M9 rubro', 'inmueble', true, v_adm)
  RETURNING id INTO v_rub;
  v_t := pg_temp.intenta(v_enc, format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, DATE ''2016-11-12'')',
                                       v_p[16], v_tra2));
  IF left(v_t, 5) <> '22023' THEN
    v_fallas := v_fallas || format('F6 · la entrega de 2016 entró: %s (%s)', v_t, pg_temp.dia(v_p[16]));
  END IF;
  v_t := pg_temp.intenta(v_enc, format('SELECT public.guardar_gasto(%L::jsonb)',
    jsonb_build_object('fecha', '2016-11-12', 'rubro_id', v_rub, 'monto_total', 1000, 'comprobante', 'ninguno',
                       'origen_pago', 'rendicion', 'rendicion_transportista_id', v_tra2, 'rendicion_fecha', '2016-11-12')::text));
  IF v_t = 'PASA' THEN
    v_fallas := v_fallas || 'F6 · el gasto de 2016 con la rendición de ese día entró'::text;
  END IF;
  v_notas := v_notas || format('F6 gasto 2016: %s', left(v_t, 120));

  -- ------------------------------------------------------------------- S1 ---
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id) VALUES (v_tra, v_hoy, 'en_curso', 1)
  RETURNING id INTO v_rec;
  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, sucursal_id)
  VALUES (v_rec, v_p[20], 1, 1), (v_rec, v_p[21], 2, 1);
  -- v_p[20] sin chofer (como lo deja la propia función tras una no entrega).
  UPDATE pedidos SET transportista_id = NULL, estado = 'pendiente' WHERE id = v_p[20];
  DECLARE
    r record;
  BEGIN
    FOR r IN SELECT * FROM (VALUES ('preventista', v_prev), ('deposito', v_dep), ('chofer de la ruta', v_tra)) AS x(n, u) LOOP
      v_t := pg_temp.intenta(r.u, format('SELECT public.marcar_no_entregado(%s, ''otro'', %L)', v_p[20], 'pisado por ' || r.n));
      IF left(v_t, 5) <> '42501' THEN
        v_fallas := v_fallas || format('S1 · %s, no entrega de un pedido sin chofer: %s', r.n, v_t);
      END IF;
      v_notas := v_notas || format('S1 %s: %s', r.n, left(v_t, 100));
    END LOOP;
  END;
  IF (SELECT nota_no_entrega FROM recorrido_pedidos WHERE pedido_id = v_p[20]) IS NOT NULL THEN
    v_fallas := v_fallas || format('S1 · la parada quedó pisada: %s', (SELECT nota_no_entrega FROM recorrido_pedidos WHERE pedido_id = v_p[20]));
  END IF;
  v_t := pg_temp.intenta(v_enc, format('SELECT public.marcar_no_entregado(%s, ''cerrado'', NULL)', v_p[20]));
  IF v_t <> 'PASA' THEN
    v_fallas := v_fallas || format('S1 · encargado, no entrega de un pedido sin chofer: %s', v_t);
  END IF;

  -- ------------------------------------------------------------------- S2 ---
  UPDATE pedidos SET transportista_id = v_tra, estado = 'asignado' WHERE id = v_p[21];
  v_t := pg_temp.intenta(v_prev, format('SELECT public.marcar_no_entregado(%s, ''cerrado'', NULL)', v_p[21]));
  IF left(v_t, 5) <> '42501' THEN
    v_fallas := v_fallas || format('S2 · preventista con chofer asignado: %s', v_t);
  END IF;
  v_t := pg_temp.intenta(v_tra, format('SELECT public.marcar_no_entregado(%s, ''cerrado'', NULL)', v_p[21]));
  IF v_t <> 'PASA' THEN
    v_fallas := v_fallas || format('S2 · el chofer asignado: %s', v_t);
  END IF;

  -- ------------------------------------------------------------------- S3 ---
  CREATE FUNCTION public.zz_1601_abierta(p bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $f$
  DECLARE
    v_uid uuid := auth.uid();
    v_chofer uuid;
  BEGIN
    SELECT transportista_id INTO v_chofer FROM pedidos WHERE id = p AND sucursal_id = current_sucursal_id();
    IF NOT (v_chofer = v_uid OR es_admin()) THEN RAISE EXCEPTION 'no'; END IF;
    RETURN 1;
  END $f$;
  CREATE FUNCTION public.zz_1601_cerrada(p bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $f$
  DECLARE
    v_uid uuid := auth.uid();
    v_chofer uuid;
  BEGIN
    SELECT transportista_id INTO v_chofer FROM pedidos WHERE id = p AND sucursal_id = current_sucursal_id();
    IF NOT (COALESCE(v_chofer = v_uid, false) OR es_admin()) THEN RAISE EXCEPTION 'no'; END IF;
    RETURN 1;
  END $f$;
  GRANT EXECUTE ON FUNCTION public.zz_1601_abierta(bigint), public.zz_1601_cerrada(bigint) TO authenticated;
  SELECT string_agg(g->>'nombre', ',' ORDER BY g->>'nombre') INTO v_t
    FROM jsonb_array_elements(public.auditoria_rpcs_definer()->'guardas_nulas') g
   WHERE g->>'nombre' LIKE 'zz\_1601\_%' OR g->>'nombre' = 'marcar_no_entregado';
  IF v_t IS DISTINCT FROM 'zz_1601_abierta' THEN
    v_fallas := v_fallas || format('S3 · guardas_nulas (de juguete y marcar_no_entregado): %s', COALESCE(v_t, 'ninguna'));
  END IF;

  RAISE EXCEPTION USING ERRCODE = 'ZZ001';
 EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas:\n  %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, E'\n  '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format(E'ENSAYO OK (todo revertido)\nnotas:\n  %s',
    array_to_string(v_notas, E'\n  '));
END
$ensayo$;
