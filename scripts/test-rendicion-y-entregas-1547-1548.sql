-- Ensayo de la mig NNN_rendicion_y_entregas_validan (#1547: FRT-03, REN-2, REN-4;
-- #1548: RUT-2, RUT-4).
--
-- Un único DO que arma su contexto con gente y pedidos que ya existen y termina SIEMPRE
-- en una excepción (ENSAYO OK / ENSAYO FALLO): no deja rastro. Cada caso corre en su
-- bloque y se deshace solo. Sin la migración tiene que dar FALLO; con ella, OK. Para
-- probarla antes de aplicarla se pega detrás de su cuerpo sin el BEGIN/COMMIT.
--
-- Contexto: una sucursal S con un chofer A que tiene una entrega de un día pasado D sin
-- control, otro chofer B, un encargado E, un admin ADM, un preventista PV sin el rol extra,
-- un chofer X de otra sucursal, y dos pedidos pendientes P1 y P2 sin parada.
--
--   R2F · E confirma (y marca) la rendición de A de hoy + 30 → rechazo; la caja no se cierra.
--   R2X · E confirma (y marca) la rendición de hoy de X, que no tiene nada en S → rechazo.
--   R2P · SIGUE: E confirma el día pasado D de A (con lo cobrado que muestra la tarjeta);
--         reabre esa confirmada no resuelta; y con A desactivado y fuera de S, la confirma de
--         nuevo.
--   F   · hoy, con A:
--         U0  SIGUE: E le arma la ruta a A (chofer válido) y A entrega P1 por REST.
--         T1  A le borra la fecha a P1 (entregado) → rechazo (CHECK).
--         T2  SIGUE: A le corrige el día a otra fecha no nula, y lo vuelve a hoy.
--         F1  A cobra 100, E abre el cierre, A cobra 50, E confirma con lo que vio → rechazo.
--         F2  cobros_visto que no es un objeto → formato inválido.
--         F3  SIGUE: E marca disconformidad con lo cobrado de ahora; ADM la resuelve (robo).
--         R4a E «Reabrir control» sobre la resuelta → rechazo; sigue resuelta con su línea.
--         R4b E «Editar cierre» sobre la resuelta → rechazo.
--         R4c ADM tampoco: ni reabre ni edita; deshace la resolución.
--         B1  SIGUE: E confirma con el cierre de un bundle viejo (sin cobros_visto).
--         R4d SIGUE: E reabre esa confirmada no resuelta.
--   U   · RUT-2:
--         U1  ruta a nombre de PV (preventista sin el extra) → rechazo.
--         U2  ruta y masiva a nombre de X (chofer de otra sucursal) → rechazo.
--         U3  ruta y masiva con cobro a nombre de B desactivado → rechazo, sin pago.
--         U4  SIGUE: PV con el extra de chofer en S: ruta y masiva SIN fecha → entregado hoy a
--             las 12:00 ART (T3: la masiva sin fecha ya no deja el entregado sin fecha).
--   G   · _actua_como_transportista sin EXECUTE para anon ni authenticated.

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_otra   bigint;
  v_a      uuid;
  v_b      uuid;
  v_e      uuid;
  v_adm    uuid;
  v_pv     uuid;
  v_x      uuid;
  v_p1     bigint;
  v_p2     bigint;
  v_d      date;
  v_hoy    date := public._tablero_hoy();
  v_ts     timestamptz;
  v_txt    text;
  v_j      jsonb;
  v_c0     jsonb;
  v_c1     jsonb;
  v_n      bigint;
  v_t      text;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  -- A: un chofer activo de S con una entrega de un día pasado sin control (la más reciente).
  SELECT p.sucursal_id, p.transportista_id, (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
    INTO v_suc, v_a, v_d
    FROM pedidos p
    JOIN perfiles pf ON pf.id = p.transportista_id AND pf.activo AND pf.rol = 'transportista'
    JOIN sucursales s ON s.id = p.sucursal_id AND s.activa
   WHERE p.estado = 'entregado' AND p.fecha_entrega IS NOT NULL
     AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
     AND (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date < v_hoy
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id = p.sucursal_id)
     AND NOT EXISTS (SELECT 1 FROM rendiciones_control rc
                      WHERE rc.transportista_id = p.transportista_id AND rc.sucursal_id = p.sucursal_id
                        AND rc.fecha = (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)
   ORDER BY p.fecha_entrega DESC
   LIMIT 1;

  SELECT us.usuario_id INTO v_b FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.activo AND pf.rol = 'transportista' AND pf.id <> v_a
   ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_e FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.activo AND pf.rol = 'encargado'
   ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_adm FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.activo AND pf.rol = 'admin'
   ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_pv FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.activo AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id AND pr.rol = 'transportista')
   ORDER BY us.usuario_id LIMIT 1;
  SELECT pf.id INTO v_x FROM perfiles pf
   WHERE pf.activo AND pf.rol = 'transportista'
     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = pf.id AND us.sucursal_id = v_suc)
   ORDER BY pf.id LIMIT 1;
  SELECT s.id INTO v_otra FROM sucursales s WHERE s.activa AND s.id <> v_suc ORDER BY s.id LIMIT 1;

  SELECT min(p.id), max(p.id) INTO v_p1, v_p2
    FROM (SELECT p.id FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
           WHERE p.sucursal_id = v_suc AND c.activo
             AND p.tipo_factura IS DISTINCT FROM 'VB' AND p.canal IS DISTINCT FROM 'cambio'
             AND p.estado = 'pendiente' AND p.total > 0
             AND NOT EXISTS (SELECT 1 FROM recorrido_pedidos rp WHERE rp.pedido_id = p.id)
           ORDER BY p.id DESC LIMIT 2) p;

  IF v_a IS NULL OR v_b IS NULL OR v_e IS NULL OR v_adm IS NULL OR v_pv IS NULL OR v_x IS NULL
     OR v_otra IS NULL OR v_p1 IS NULL OR v_p1 = v_p2 THEN
    RAISE EXCEPTION 'ENSAYO FALLO · sin contexto: suc %, A %, D %, B %, E %, ADM %, PV %, X %, otra %, P1 %, P2 %',
      v_suc, v_a, v_d, v_b, v_e, v_adm, v_pv, v_x, v_otra, v_p1, v_p2;
  END IF;
  v_notas := v_notas || format('suc %s, A %s (día %s), B %s, E %s, ADM %s, PV %s, X %s; P1 %s, P2 %s, hoy %s',
                               v_suc, left(v_a::text, 8), v_d, left(v_b::text, 8), left(v_e::text, 8),
                               left(v_adm::text, 8), left(v_pv::text, 8), left(v_x::text, 8), v_p1, v_p2, v_hoy);

  -- ---------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
    IF p_uid IS NULL THEN
      EXECUTE 'RESET ROLE';
    ELSE
      EXECUTE 'SET LOCAL ROLE authenticated';
    END IF;
  END $f$;
  -- Corre p_sql como p_uid en p_suc: 'PASA' o el SQLSTATE y el mensaje.
  CREATE OR REPLACE FUNCTION pg_temp.r(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    BEGIN
      EXECUTE p_sql;
      v := 'PASA';
    EXCEPTION WHEN OTHERS THEN
      v := SQLSTATE || ' ' || SQLERRM;
    END;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN v;
  END $f$;
  -- El valor de p_sql como p_uid en p_suc.
  CREATE OR REPLACE FUNCTION pg_temp.v(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE p_sql INTO r;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  -- Lo cobrado que muestra la tarjeta de la rendición, como lo arma el front (cobros_visto).
  CREATE OR REPLACE FUNCTION pg_temp.cobros(p_uid uuid, p_suc bigint, p_f date, p_tr uuid) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE r jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    SELECT jsonb_build_object('efectivo', x.total_efectivo, 'transferencia', x.total_transferencia,
                              'cheque', x.total_cheque, 'cuenta_corriente', x.total_cuenta_corriente,
                              'tarjeta', x.total_tarjeta, 'otros', x.total_otros, 'entregas', x.total_entregas)
      INTO r
      FROM public.obtener_resumen_rendiciones(p_f, p_f, p_tr) x
     WHERE x.transportista_id = p_tr AND x.fecha = p_f;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN COALESCE(r, '{"efectivo":0,"transferencia":0,"cheque":0,"cuenta_corriente":0,"tarjeta":0,"otros":0,"entregas":0}'::jsonb);
  END $f$;
  -- El cierre que manda el modal: los gastos vivos como vistos, sin cambios.
  CREATE OR REPLACE FUNCTION pg_temp.cierre(p_suc bigint, p_tr uuid, p_f date, p_faltantes numeric, p_cobros jsonb) RETURNS jsonb
  LANGUAGE sql AS $f$
    SELECT jsonb_build_object(
             'vistos', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', g.id, 'updated_at', g.updated_at))
                                   FROM public.gastos g
                                  WHERE g.origen_pago = 'rendicion' AND g.anulado_at IS NULL
                                    AND g.sucursal_id = p_suc AND g.rendicion_transportista_id = p_tr
                                    AND g.rendicion_fecha = p_f), '[]'::jsonb),
             'guardar', '[]'::jsonb, 'quitar', '[]'::jsonb,
             'pagos_personal_visto', 0, 'faltantes_visto', p_faltantes)
           || CASE WHEN p_cobros IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('cobros_visto', p_cobros) END;
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.confirmar(p_f date, p_tr uuid, p_estado text, p_cierre jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.confirmar_rendicion(%L::date, %L::uuid, %L, %L::jsonb, %L)',
                  p_f, p_tr, p_estado, p_cierre, 'ensayo 1547');
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.ruta(p_chofer uuid, p_pedido bigint, p_f date) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.aplicar_orden_ruta(%L::uuid, %L::jsonb, NULL, NULL, NULL, %L::date)',
                  p_chofer, jsonb_build_array(jsonb_build_object('pedido_id', p_pedido, 'orden_entrega', 1)), p_f);
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.estado_rc(p_suc bigint, p_tr uuid, p_f date) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT estado FROM public.rendiciones_control
                      WHERE sucursal_id = p_suc AND transportista_id = p_tr AND fecha = p_f), '-');
  $f$;
  -- Activa o desactiva un perfil. trg_perfiles_sync_acceso_auth escribe auth.users.banned_until,
  -- que el stub de auth de la base local de Docker no tiene: ahí (y sólo ahí) se salta los triggers.
  CREATE OR REPLACE FUNCTION pg_temp.activo(p_uid uuid, p_activo boolean) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    BEGIN
      UPDATE public.perfiles SET activo = p_activo WHERE id = p_uid;
    EXCEPTION WHEN undefined_column THEN
      SET LOCAL session_replication_role = replica;
      UPDATE public.perfiles SET activo = p_activo WHERE id = p_uid;
      SET LOCAL session_replication_role = origin;
    END;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.lineas(p_suc bigint, p_tr uuid, p_f date) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(*) FROM public.rendicion_faltantes
     WHERE rendicion_sucursal_id = p_suc AND rendicion_transportista_id = p_tr
       AND rendicion_fecha = p_f AND anulada_at IS NULL;
  $f$;

  v_ts := (v_hoy::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  -- ------------------------------------------------------------------ R2F ---
  BEGIN
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_hoy + 30, v_a, 'confirmada',
                                                     pg_temp.cierre(v_suc, v_a, v_hoy + 30, 0, NULL)));
    IF v_txt !~ '^22023 .*todavía no se puede cerrar' OR pg_temp.estado_rc(v_suc, v_a, v_hoy + 30) <> '-' THEN
      v_fallas := v_fallas || ('R2F · confirmar hoy + 30: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_e, v_suc, format('SELECT public.marcar_rendicion_controlada(%L::date, %L::uuid)', v_hoy + 30, v_a));
    IF v_txt !~ '^22023 .*todavía no se puede cerrar' OR pg_temp.estado_rc(v_suc, v_a, v_hoy + 30) <> '-' THEN
      v_fallas := v_fallas || ('R2F · marcar hoy + 30: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R2F · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ R2X ---
  BEGIN
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_hoy, v_x, 'confirmada', pg_temp.cierre(v_suc, v_x, v_hoy, 0, NULL)));
    IF v_txt !~ '^22023 No hay nada que rendir' OR pg_temp.estado_rc(v_suc, v_x, v_hoy) <> '-' THEN
      v_fallas := v_fallas || ('R2X · confirmar a X: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_e, v_suc, format('SELECT public.marcar_rendicion_controlada(%L::date, %L::uuid)', v_hoy, v_x));
    IF v_txt !~ '^22023 No hay nada que rendir' OR pg_temp.estado_rc(v_suc, v_x, v_hoy) <> '-' THEN
      v_fallas := v_fallas || ('R2X · marcar a X: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R2X · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ R2P ---
  BEGIN
    v_c0 := pg_temp.cobros(v_e, v_suc, v_d, v_a);
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_d, v_a, 'confirmada', pg_temp.cierre(v_suc, v_a, v_d, 0, v_c0)));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_d) <> 'confirmada' THEN
      v_fallas := v_fallas || format('R2P · confirmar el día pasado %s: %s', v_d, v_txt);
    END IF;
    v_txt := pg_temp.r(v_e, v_suc, format('SELECT public.desmarcar_rendicion_controlada(%L::date, %L::uuid)', v_d, v_a));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_d) <> '-' THEN
      v_fallas := v_fallas || ('R2P · reabrir una confirmada no resuelta: ' || v_txt);
    END IF;
    -- A se desactiva y deja la sucursal (pasa a otra, nadie queda sin sucursal).
    PERFORM pg_temp.activo(v_a, false);
    INSERT INTO usuario_sucursales (usuario_id, sucursal_id)
    SELECT v_a, v_otra WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_a AND sucursal_id = v_otra);
    DELETE FROM usuario_sucursales WHERE usuario_id = v_a AND sucursal_id = v_suc;
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_d, v_a, 'confirmada', pg_temp.cierre(v_suc, v_a, v_d, 0, v_c0)));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_d) <> 'confirmada' THEN
      v_fallas := v_fallas || ('R2P · confirmar el día pasado de A desactivado y fuera de S: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R2P · error inesperado: ' || SQLERRM);
  END;

  -- -------------------------------------------------------------------- F ---
  BEGIN
    -- U0 · ruta y entrega por REST con un chofer válido
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.ruta(v_a, v_p1, v_hoy));
    IF v_txt <> 'PASA' OR (SELECT transportista_id FROM pedidos WHERE id = v_p1) IS DISTINCT FROM v_a THEN
      v_fallas := v_fallas || ('U0 · ruta a A: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_a, v_suc, format(
      'UPDATE public.pedidos SET estado = ''entregado'', fecha_entrega = %L::timestamptz WHERE id = %s', v_ts, v_p1));
    IF v_txt <> 'PASA' OR (SELECT estado FROM pedidos WHERE id = v_p1) <> 'entregado' THEN
      v_fallas := v_fallas || ('U0 · A entrega P1 por REST: ' || v_txt);
    END IF;

    -- T1 · el chofer le borra la fecha
    v_txt := pg_temp.r(v_a, v_suc, format('UPDATE public.pedidos SET fecha_entrega = NULL WHERE id = %s', v_p1));
    IF v_txt !~ '^23514 ' OR (SELECT fecha_entrega FROM pedidos WHERE id = v_p1) IS DISTINCT FROM v_ts THEN
      v_fallas := v_fallas || ('T1 · el chofer borró la fecha de su entrega: ' || v_txt);
    END IF;
    -- T2 · le corrige el día a otra fecha, y lo vuelve
    v_txt := pg_temp.r(v_a, v_suc, format('UPDATE public.pedidos SET fecha_entrega = %L::timestamptz WHERE id = %s',
                                          v_ts - interval '1 day', v_p1));
    IF v_txt <> 'PASA' OR (SELECT fecha_entrega FROM pedidos WHERE id = v_p1) IS DISTINCT FROM v_ts - interval '1 day' THEN
      v_fallas := v_fallas || ('T2 · el chofer corrige el día de su entrega: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_a, v_suc, format('UPDATE public.pedidos SET fecha_entrega = %L::timestamptz WHERE id = %s', v_ts, v_p1));
    IF v_txt <> 'PASA' THEN
      v_fallas := v_fallas || ('T2 · el chofer vuelve el día de su entrega: ' || v_txt);
    END IF;

    -- F1 · el cobro que entra con el cierre abierto
    v_txt := pg_temp.v(v_a, v_suc, format(
      'SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date, %L, NULL, %L::uuid)::text',
      v_p1, '[{"forma_pago":"efectivo","monto":100}]', v_hoy, 'ensayo 1547', gen_random_uuid()));
    IF (v_txt::jsonb->>'success') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'F · el primer cobro de A no entró: %', v_txt;
    END IF;
    v_c0 := pg_temp.cobros(v_e, v_suc, v_hoy, v_a);
    v_txt := pg_temp.v(v_a, v_suc, format(
      'SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date, %L, NULL, %L::uuid)::text',
      v_p1, '[{"forma_pago":"efectivo","monto":50}]', v_hoy, 'ensayo 1547', gen_random_uuid()));
    IF (v_txt::jsonb->>'success') IS DISTINCT FROM 'true' THEN
      RAISE EXCEPTION 'F · el segundo cobro de A no entró: %', v_txt;
    END IF;
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_hoy, v_a, 'confirmada', pg_temp.cierre(v_suc, v_a, v_hoy, 0, v_c0)));
    IF v_txt !~ 'Los cobros de esta rendición cambiaron mientras la cerrabas' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> '-' THEN
      v_fallas := v_fallas || format('F1 · se confirmó con lo cobrado viejo (visto %s): %s', v_c0->>'efectivo', v_txt);
    END IF;

    -- F2 · formato
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_hoy, v_a, 'confirmada',
                                                     pg_temp.cierre(v_suc, v_a, v_hoy, 0, NULL) || '{"cobros_visto":"150"}'::jsonb));
    IF v_txt !~ 'formato inválido' THEN
      v_fallas := v_fallas || ('F2 · cobros_visto que no es un objeto: ' || v_txt);
    END IF;

    -- F3 · disconformidad con lo cobrado de ahora, y el admin la resuelve como robo
    v_c1 := pg_temp.cobros(v_e, v_suc, v_hoy, v_a);
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_hoy, v_a, 'disconformidad', pg_temp.cierre(v_suc, v_a, v_hoy, 0, v_c1)));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> 'disconformidad' THEN
      RAISE EXCEPTION 'F3 · disconformidad con lo cobrado de ahora (%): %', v_c1, v_txt;
    END IF;
    v_txt := pg_temp.r(v_adm, v_suc, format('SELECT public.resolver_rendicion(%L::date, %L::uuid, %L, %L::jsonb)',
      v_hoy, v_a, 'ensayo 1547: faltan 30',
      jsonb_build_object('lineas', jsonb_build_array(jsonb_build_object('causal', 'robo_perdida', 'monto', 30, 'observacion', 'ensayo')),
                         'vistos', pg_temp.cierre(v_suc, v_a, v_hoy, 0, NULL)->'vistos', 'pagos_personal_visto', 0)));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> 'resuelta' OR pg_temp.lineas(v_suc, v_a, v_hoy) <> 1 THEN
      RAISE EXCEPTION 'F3 · el admin no pudo resolver: %', v_txt;
    END IF;

    -- R4a · el encargado reabre la resuelta
    v_txt := pg_temp.r(v_e, v_suc, format('SELECT public.desmarcar_rendicion_controlada(%L::date, %L::uuid)', v_hoy, v_a));
    IF v_txt !~ 'deshacer la resolución' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> 'resuelta' OR pg_temp.lineas(v_suc, v_a, v_hoy) <> 1 THEN
      v_fallas := v_fallas || format('R4a · reabrir la resuelta (queda %s, %s líneas): %s',
                                     pg_temp.estado_rc(v_suc, v_a, v_hoy), pg_temp.lineas(v_suc, v_a, v_hoy), v_txt);
    END IF;
    -- R4b · el encargado edita el cierre de la resuelta
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_hoy, v_a, 'confirmada', pg_temp.cierre(v_suc, v_a, v_hoy, 0, v_c1)));
    IF v_txt !~ 'deshacer la resolución' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> 'resuelta' THEN
      v_fallas := v_fallas || format('R4b · editar el cierre de la resuelta (queda %s): %s', pg_temp.estado_rc(v_suc, v_a, v_hoy), v_txt);
    END IF;
    -- R4c · el admin tampoco, y deshace la resolución
    v_txt := pg_temp.r(v_adm, v_suc, format('SELECT public.desmarcar_rendicion_controlada(%L::date, %L::uuid)', v_hoy, v_a));
    IF v_txt !~ 'deshacer la resolución' THEN
      v_fallas := v_fallas || ('R4c · el admin reabrió la resuelta: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_adm, v_suc, pg_temp.confirmar(v_hoy, v_a, 'confirmada', pg_temp.cierre(v_suc, v_a, v_hoy, 0, v_c1)));
    IF v_txt !~ 'deshacer la resolución' THEN
      v_fallas := v_fallas || ('R4c · el admin editó el cierre de la resuelta: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_adm, v_suc, format('SELECT public.deshacer_resolucion_rendicion(%L::date, %L::uuid, %L)',
                                            v_hoy, v_a, 'ensayo 1547'));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> 'disconformidad' OR pg_temp.lineas(v_suc, v_a, v_hoy) <> 0 THEN
      RAISE EXCEPTION 'R4c · deshacer la resolución: %', v_txt;
    END IF;

    -- B1 · el cierre de un bundle viejo, sin cobros_visto
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.confirmar(v_hoy, v_a, 'confirmada', pg_temp.cierre(v_suc, v_a, v_hoy, 0, NULL)));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> 'confirmada' THEN
      v_fallas := v_fallas || ('B1 · confirmar con un bundle viejo: ' || v_txt);
    END IF;
    -- R4d · reabrir una confirmada no resuelta
    v_txt := pg_temp.r(v_e, v_suc, format('SELECT public.desmarcar_rendicion_controlada(%L::date, %L::uuid)', v_hoy, v_a));
    IF v_txt <> 'PASA' OR pg_temp.estado_rc(v_suc, v_a, v_hoy) <> '-' THEN
      v_fallas := v_fallas || ('R4d · reabrir una confirmada no resuelta: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('F · error inesperado: ' || SQLERRM);
  END;

  -- -------------------------------------------------------------------- U ---
  BEGIN
    -- U1 · ruta a nombre de un preventista sin el extra
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.ruta(v_pv, v_p1, v_hoy));
    IF v_txt !~ '^42501 .*no es un chofer activo de esta sucursal'
       OR (SELECT transportista_id FROM pedidos WHERE id = v_p1) IS NOT NULL THEN
      v_fallas := v_fallas || ('U1 · ruta a nombre de un preventista: ' || v_txt);
    END IF;
    -- U2 · ruta y masiva a nombre de un chofer de otra sucursal
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.ruta(v_x, v_p1, v_hoy));
    IF v_txt !~ '^42501 .*no es un chofer activo de esta sucursal' THEN
      v_fallas := v_fallas || ('U2 · ruta a nombre de X: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_e, v_suc, format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, %L::date)',
                                          v_p1, v_x, v_hoy));
    IF v_txt !~ '^23514 .*no es chofer en esta sucursal' OR (SELECT estado FROM pedidos WHERE id = v_p1) = 'entregado' THEN
      v_fallas := v_fallas || ('U2 · masiva a nombre de X: ' || v_txt);
    END IF;
    -- U3 · a nombre de B desactivado
    PERFORM pg_temp.activo(v_b, false);
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.ruta(v_b, v_p1, v_hoy));
    IF v_txt !~ '^42501 .*no es un chofer activo de esta sucursal' THEN
      v_fallas := v_fallas || ('U3 · ruta a nombre de B desactivado: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_e, v_suc, format(
      'SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s]::bigint[], %L::uuid, ''efectivo'', %L::date, %L::uuid)',
      v_p1, v_b, v_hoy, gen_random_uuid()));
    SELECT count(*) INTO v_n FROM pagos WHERE pedido_id = v_p1;
    IF v_txt !~ '^23514 .*no es chofer en esta sucursal' OR v_n <> 0 OR (SELECT estado FROM pedidos WHERE id = v_p1) = 'entregado' THEN
      v_fallas := v_fallas || format('U3 · masiva con cobro a nombre de B desactivado (%s pagos): %s', v_n, v_txt);
    END IF;
    PERFORM pg_temp.activo(v_b, true);

    -- U4 · PV con el extra de chofer en S: ruta y masiva sin fecha
    INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_pv, v_suc, 'transportista');
    v_txt := pg_temp.r(v_e, v_suc, pg_temp.ruta(v_pv, v_p2, v_hoy));
    IF v_txt <> 'PASA' OR (SELECT transportista_id FROM pedidos WHERE id = v_p2) IS DISTINCT FROM v_pv THEN
      v_fallas := v_fallas || ('U4 · ruta a nombre de un chofer de rol extra: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_e, v_suc, format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, NULL)', v_p2, v_pv));
    IF v_txt <> 'PASA' OR (SELECT estado FROM pedidos WHERE id = v_p2) <> 'entregado'
       OR (SELECT fecha_entrega FROM pedidos WHERE id = v_p2) IS DISTINCT FROM v_ts THEN
      v_fallas := v_fallas || format('U4 · masiva sin fecha a nombre de un chofer de rol extra (queda %s, %s): %s',
        (SELECT estado FROM pedidos WHERE id = v_p2), COALESCE((SELECT fecha_entrega FROM pedidos WHERE id = v_p2)::text, 'sin fecha'), v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('U · error inesperado: ' || SQLERRM);
  END;

  -- -------------------------------------------------------------------- G ---
  IF has_function_privilege('anon', 'public._actua_como_transportista(uuid,bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._actua_como_transportista(uuid,bigint)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'G · _actua_como_transportista con EXECUTE para anon o authenticated'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLO (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · R2F R2X R2P U0 T1 T2 F1 F2 F3 R4a R4b R4c B1 R4d U1 U2 U3 U4 G · notas: %s',
    array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_t;
 END;
END
$ensayo$;
