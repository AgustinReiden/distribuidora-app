-- Ensayo de #1170 (la rama del transportista en un pedido propio), #1171 (el
-- trigger y la policy de clientes con el preventista como rol extra) y #1175
-- (un PATCH del chofer o del vendedor no reabre una caja controlada).
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia de
-- audit_logs y pedido_historial): un único DO que termina SIEMPRE en una
-- excepción, y cada caso corre en su propio sub-bloque que se revierte. Las
-- filas de fixture de rendiciones_control y perfil_roles van con id explícito
-- negativo, para no consumir sus secuencias.
--
-- Simula PostgREST como test-columnas-protegidas-1151-1155-1156.sql: `SET LOCAL
-- ROLE authenticated`, el `sub` de un perfil real en request.jwt.claims y la
-- sucursal en x-sucursal-id. Las aserciones se hacen de vuelta como postgres.
-- Los fixtures se escriben como postgres con los claims del admin, salvo las
-- asignaciones de cliente_preventistas, que van sin claims (el trigger
-- no_ajeno sale por auth.uid() IS NULL). Si un fixture no queda, el caso
-- falla: nunca se saltea.
--
-- Usuarios, elegidos por consulta (el ensayo falla si falta alguno): una
-- sucursal con un preventista activo con rol extra transportista (PX), un
-- transportista base sin extra (T), un admin y un encargado; y un preventista
-- base sin extra (PB) de cualquier sucursal (en la 2 de prod no hay ninguno).
-- Fechas: hoy+400 y hoy+401, sin controles reales (UNIQUE (fecha,
-- transportista_id, sucursal_id) de rendiciones_control).
--
-- #1170
--   P1  · PX guarda notas de un pedido propio que lleva T → OK
--   P2  · PX guarda fecha_entrega_programada de ese pedido → OK
--   P3  · PX guarda notas de un pedido propio que lleva él → OK
--   P4  · PX en un pedido ajeno que lleva él: notas y total → 42501 'Un
--         transportista solo puede confirmar'
--   P5  · T: notas → 42501; marca entregado con fecha desde NULL hacia un día
--         sin control → OK
--   P6  · PX cambia el total de su pedido → 42501
-- #1175 (base: un entregado con T y fecha_entrega hoy+400, y un control de T
-- en hoy+400)
--   C1  · control confirmada; T mueve la fecha a +401 → 42501 'ya fue
--         controlada', y el control sigue
--   C2  · ídem con resuelta → 42501
--   C3  · ídem con disconformidad → OK, y el control se borra (diseño)
--   C4  · sin control → OK
--   C5  · asignado con fecha NULL, control confirmada en +400: T marca
--         entregado en +400 → 42501; en +401 → OK
--   C6  · cancelado con transportista_id T: T pone fecha_entrega → 42501 'su
--         fecha de entrega no se cambia'
--   C6b · cancelado, control confirmada en +400: T manda estado entregado con
--         fecha +400 → 42501 'una baja no se deshace' (el de
--         pedidos_guard_baja, no el del guard de caja)
--   C7  · PX dueño de un entregado que llevó T, con control cerrado: mueve la
--         fecha (a), cambia el transportista (b), lo desmarca (c) → 42501 'ya
--         fue controlada' las tres, y el control sigue
--   C8  · el admin por REST mueve la fecha → OK, y el control se borra
-- #1171
--   KX1 · con perfil_roles_rol_check levantado dentro del sub-bloque, T recibe
--         el preventista como rol extra: PATCH de cuit de un cliente libre →
--         42501; PATCH de telefono de un cliente asignado a PX → 0 filas
--   KX2 · regresión: PB cambia el telefono de su cliente → OK y el cuit →
--         42501; el encargado cambia el cuit → OK
--   K1  · estructural: ACL del helper, la policy sin p.rol = 'preventista' y,
--         si la lista blanca ya lo tiene, SEG-A en 0
--
-- Sin la migración tiene que FALLAR en P1, P2, P3, C1, C2, C5, C6, C7, KX1 y
-- K1, y pasar en P4, P5, P6, C3, C4, C6b, C8 y KX2. Con la migración (inline
-- antes del DO) tiene que dar 'ENSAYO OK'.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre
-- como excepción (el MCP de Supabase no muestra NOTICEs).
--
--   psql "$DATABASE_URL" -f scripts/test-roles-columnas-caja-1170-1171-1175.sql

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_px      uuid;
  v_tr      uuid;
  v_adm     uuid;
  v_enc     uuid;
  v_pb      uuid;
  v_pb_suc  bigint;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_d400    date;
  v_d401    date;
  v_t400    text;
  v_t401    text;
  v_ped_px  bigint;   -- pedido propio de PX, abierto
  v_ped_px7 bigint;   -- pedido propio de PX para C7
  v_ped_otr bigint;   -- pedido abierto de otro usuario
  v_ped_ent bigint;   -- entregado sin control en su día
  v_ped_can bigint;   -- cancelado
  v_cli_lib bigint;   -- cliente libre de v_suc
  v_cli_asg bigint;   -- otro cliente libre de v_suc (se asigna a PX en KX1)
  v_cli_pb  bigint;   -- cliente libre de la sucursal de PB
  v_res     text;
  v_res2    text;
  v_t       text;
  v_estado  text;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
 BEGIN
  v_d400 := v_hoy + 400;
  v_d401 := v_hoy + 401;
  v_t400 := (v_d400::timestamp + interval '15 hours')::text;
  v_t401 := (v_d401::timestamp + interval '15 hours')::text;

  -- ------------------------------------------------------------- personas ---
  SELECT s.id, px.usuario_id, tr.usuario_id, a.usuario_id, e.usuario_id
    INTO v_suc, v_px, v_tr, v_adm, v_enc
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista'
                     AND EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id
                                    AND pr.sucursal_id = s.id AND pr.rol = 'transportista')
                     AND EXISTS (SELECT 1 FROM pedidos pe WHERE pe.usuario_id = pf.id AND pe.sucursal_id = s.id
                                    AND pe.estado IN ('pendiente', 'asignado'))
                   ORDER BY us.usuario_id LIMIT 1) px ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)
                   ORDER BY us.usuario_id LIMIT 1) tr ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado' ORDER BY us.usuario_id LIMIT 1) e ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con un preventista con extra transportista (y pedidos abiertos), un transportista base sin extra, un admin y un encargado';
  END IF;
  SELECT us.usuario_id, us.sucursal_id INTO v_pb, v_pb_suc
    FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE pf.activo AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id AND pr.sucursal_id = us.sucursal_id)
   ORDER BY (us.sucursal_id = v_suc) DESC, us.sucursal_id, us.usuario_id LIMIT 1;
  IF v_pb IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un preventista activo sin rol extra en alguna sucursal';
  END IF;

  -- ---------------------------------------------------------------- pedidos -
  -- Sin vales blancos: el chofer no los ve (mt_pedidos_select) y el CHECK
  -- pedidos_vb_coherente no deja volverlos a 'asignado'.
  SELECT id INTO v_ped_px FROM pedidos
   WHERE usuario_id = v_px AND sucursal_id = v_suc AND estado IN ('pendiente', 'asignado')
     AND tipo_factura IS DISTINCT FROM 'VB'
   ORDER BY id DESC LIMIT 1;
  SELECT id INTO v_ped_px7 FROM pedidos pe
   WHERE pe.usuario_id = v_px AND pe.sucursal_id = v_suc AND pe.estado IN ('entregado', 'pendiente', 'asignado')
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND NOT (pe.fecha_entrega IS NOT NULL AND pe.transportista_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM rendiciones_control rc WHERE rc.transportista_id = pe.transportista_id
                             AND rc.sucursal_id = pe.sucursal_id AND rc.fecha = pe.fecha_entrega::date))
     AND public.nota_credito_vigente_de_pedido(pe.id) IS NULL
   ORDER BY (pe.estado = 'entregado') DESC, pe.id DESC LIMIT 1;
  SELECT id INTO v_ped_ent FROM pedidos pe
   WHERE pe.sucursal_id = v_suc AND pe.estado = 'entregado' AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND pe.usuario_id IS DISTINCT FROM v_px AND pe.usuario_id IS DISTINCT FROM v_tr
     AND pe.fecha_entrega IS NOT NULL AND pe.transportista_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM rendiciones_control rc WHERE rc.transportista_id = pe.transportista_id
                        AND rc.sucursal_id = pe.sucursal_id AND rc.fecha = pe.fecha_entrega::date)
   ORDER BY pe.id DESC LIMIT 1;
  -- Un pedido de otro usuario que se pueda volver a 'asignado' (de preferencia
  -- ya abierto; si no, un entregado sin NC vigente ni control en su día).
  SELECT id INTO v_ped_otr FROM pedidos pe
   WHERE pe.sucursal_id = v_suc AND pe.usuario_id IS DISTINCT FROM v_px AND pe.usuario_id IS DISTINCT FROM v_tr
     AND pe.id IS DISTINCT FROM v_ped_ent
     AND pe.estado IN ('pendiente', 'asignado', 'entregado') AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND public.nota_credito_vigente_de_pedido(pe.id) IS NULL
     AND NOT (pe.fecha_entrega IS NOT NULL AND pe.transportista_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM rendiciones_control rc WHERE rc.transportista_id = pe.transportista_id
                             AND rc.sucursal_id = pe.sucursal_id AND rc.fecha = pe.fecha_entrega::date))
   ORDER BY (pe.estado IN ('pendiente', 'asignado')) DESC, pe.id DESC LIMIT 1;
  SELECT id INTO v_ped_can FROM pedidos
   WHERE sucursal_id = v_suc AND estado = 'cancelado' AND tipo_factura IS DISTINCT FROM 'VB'
     AND usuario_id IS DISTINCT FROM v_px AND usuario_id IS DISTINCT FROM v_tr
   ORDER BY id DESC LIMIT 1;
  IF v_ped_px IS NULL OR v_ped_px7 IS NULL OR v_ped_otr IS NULL OR v_ped_ent IS NULL OR v_ped_can IS NULL THEN
    RAISE EXCEPTION 'faltan pedidos para el ensayo: propio %, propio C7 %, ajeno %, entregado %, cancelado %',
      v_ped_px, v_ped_px7, v_ped_otr, v_ped_ent, v_ped_can;
  END IF;

  -- --------------------------------------------------------------- clientes -
  SELECT id INTO v_cli_lib FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT c.reservado_admin
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;
  SELECT id INTO v_cli_asg FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT c.reservado_admin AND c.id <> v_cli_lib
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;
  SELECT id INTO v_cli_pb FROM clientes c
   WHERE c.sucursal_id = v_pb_suc AND c.activo AND NOT c.reservado_admin
     AND c.id IS DISTINCT FROM v_cli_lib AND c.id IS DISTINCT FROM v_cli_asg
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;
  IF v_cli_lib IS NULL OR v_cli_asg IS NULL OR v_cli_pb IS NULL THEN
    RAISE EXCEPTION 'faltan clientes libres para el ensayo: % % %', v_cli_lib, v_cli_asg, v_cli_pb;
  END IF;

  -- Las fechas del ensayo no pueden tener controles reales.
  IF EXISTS (SELECT 1 FROM rendiciones_control WHERE fecha IN (v_d400, v_d401)) THEN
    RAISE EXCEPTION 'ya hay controles reales en % o %: mover las fechas del ensayo', v_d400, v_d401;
  END IF;

  v_notas := v_notas || format('suc %s, PX %s, T %s, PB %s (suc %s); pedidos propio %s, C7 %s, ajeno %s, entregado %s, cancelado %s',
                               v_suc, left(v_px::text, 8), left(v_tr::text, 8), left(v_pb::text, 8), v_pb_suc,
                               v_ped_px, v_ped_px7, v_ped_otr, v_ped_ent, v_ped_can);

  -- ---------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  -- Una sentencia como PostgREST: 'OK <filas>' o 'SQLSTATE mensaje'.
  CREATE OR REPLACE FUNCTION pg_temp.rest(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    RETURN 'OK ' || v;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Un fixture como postgres: tiene que tocar exactamente una fila.
  CREATE OR REPLACE FUNCTION pg_temp.fix(p_sql text) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    IF v <> 1 THEN
      RAISE EXCEPTION 'fixture: % filas en %', v, p_sql;
    END IF;
  END $f$;
  -- Control del día para (transportista, sucursal, fecha), como postgres.
  CREATE OR REPLACE FUNCTION pg_temp.control(p_id bigint, p_tr uuid, p_suc bigint, p_f date, p_estado text, p_adm uuid)
  RETURNS void LANGUAGE sql AS $f$
    INSERT INTO public.rendiciones_control (id, fecha, transportista_id, sucursal_id, estado, controlada_por)
    VALUES (p_id, p_f, p_tr, p_suc, p_estado, p_adm);
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.hay_control(p_tr uuid, p_suc bigint, p_f date) RETURNS boolean LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM public.rendiciones_control WHERE transportista_id = p_tr AND sucursal_id = p_suc AND fecha = p_f);
  $f$;
  -- Asignación de un cliente sin claims (el trigger no_ajeno sale por auth.uid() IS NULL).
  CREATE OR REPLACE FUNCTION pg_temp.asignar(p_cli bigint, p_prev uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v_claims text := current_setting('request.jwt.claims', true);
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (p_cli, p_prev);
    PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
    IF NOT EXISTS (SELECT 1 FROM public.cliente_preventistas WHERE cliente_id = p_cli AND preventista_id = p_prev) THEN
      RAISE EXCEPTION 'fixture: no quedó la asignación del cliente % a %', p_cli, p_prev;
    END IF;
  END $f$;

  -- ============================================================ #1170 =======
  -- P1 / P2 · PX en un pedido propio que lleva T
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L WHERE id = %s', v_tr, v_ped_px));
    PERFORM pg_temp.como(v_px, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET notas = COALESCE(notas, %L) || %L WHERE id = %s',
                                 '', ' [ensayo 1170]', v_ped_px));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('P1 · PX no guarda notas de su pedido que lleva otro: %s', v_res);
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET fecha_entrega_programada = %L WHERE id = %s', v_d400, v_ped_px));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('P2 · PX no guarda fecha_entrega_programada de su pedido: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('P1 · error inesperado: ' || SQLERRM);
  END;

  -- P3 · PX en un pedido propio que lleva él
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L WHERE id = %s', v_px, v_ped_px));
    PERFORM pg_temp.como(v_px, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET notas = COALESCE(notas, %L) || %L WHERE id = %s',
                                 '', ' [ensayo 1170]', v_ped_px));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('P3 · PX no guarda notas de su pedido que lleva él: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('P3 · error inesperado: ' || SQLERRM);
  END;

  -- P4 · PX en un pedido ajeno que lleva él: sigue la rama del chofer
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L WHERE id = %s', v_px, v_ped_otr));
    PERFORM pg_temp.como(v_px, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET notas = COALESCE(notas, %L) || %L WHERE id = %s',
                                 '', ' [ensayo 1170]', v_ped_otr));
    IF COALESCE(v_res, '') NOT LIKE '42501 Un transportista solo puede confirmar%' THEN
      v_fallas := v_fallas || format('P4 · PX guardó notas de un pedido ajeno que lleva (tenía que dar 42501): %s', v_res);
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET total = total + 1 WHERE id = %s', v_ped_otr));
    IF COALESCE(v_res, '') NOT LIKE '42501 %' THEN
      v_fallas := v_fallas || format('P4 · PX cambió el total de un pedido ajeno que lleva: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('P4 · error inesperado: ' || SQLERRM);
  END;

  -- P5 · T, transportista base
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET estado = %L, transportista_id = %L, fecha_entrega = NULL WHERE id = %s',
                               'asignado', v_tr, v_ped_otr));
    PERFORM pg_temp.como(v_tr, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET notas = COALESCE(notas, %L) || %L WHERE id = %s',
                                 '', ' [ensayo 1170]', v_ped_otr));
    IF COALESCE(v_res, '') NOT LIKE '42501 %' THEN
      v_fallas := v_fallas || format('P5 · T guardó notas: %s', v_res);
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET estado = %L, fecha_entrega = %L::timestamptz, updated_at = now() WHERE id = %s',
                                 'entregado', v_t400, v_ped_otr));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('P5 · T no marca entregado hacia un día sin control: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('P5 · error inesperado: ' || SQLERRM);
  END;

  -- P6 · PX no toca la plata de su pedido (rama general)
  BEGIN
    PERFORM pg_temp.como(v_px, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET total = total + 1 WHERE id = %s', v_ped_px));
    IF COALESCE(v_res, '') NOT LIKE '42501 %' THEN
      v_fallas := v_fallas || format('P6 · PX cambió el total de su pedido: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('P6 · error inesperado: ' || SQLERRM);
  END;

  -- ============================================================ #1175 =======
  -- C1 / C2 / C3 / C4 · T mueve la fecha de un entregado suyo
  FOREACH v_estado IN ARRAY ARRAY['confirmada', 'resuelta', 'disconformidad', '-'] LOOP
    v_t := CASE v_estado WHEN 'confirmada' THEN 'C1' WHEN 'resuelta' THEN 'C2'
                         WHEN 'disconformidad' THEN 'C3' ELSE 'C4' END;
    BEGIN
      PERFORM pg_temp.como(v_adm, v_suc);
      PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L, fecha_entrega = %L::timestamptz WHERE id = %s',
                                 v_tr, v_t400, v_ped_ent));
      IF v_estado <> '-' THEN
        PERFORM pg_temp.control(-911751, v_tr, v_suc, v_d400, v_estado, v_adm);
      END IF;
      PERFORM pg_temp.como(v_tr, v_suc);
      v_res := pg_temp.rest(format('UPDATE public.pedidos SET fecha_entrega = %L::timestamptz, updated_at = now() WHERE id = %s',
                                   v_t401, v_ped_ent));
      IF v_estado IN ('confirmada', 'resuelta') THEN
        IF COALESCE(v_res, '') NOT LIKE '42501 %ya fue controlada%' THEN
          v_fallas := v_fallas || format('%s · T movió la fecha con el control %s (tenía que dar 42501): %s', v_t, v_estado, v_res);
        END IF;
        IF NOT pg_temp.hay_control(v_tr, v_suc, v_d400) THEN
          v_fallas := v_fallas || format('%s · se borró el control %s', v_t, v_estado);
        END IF;
      ELSE
        IF v_res IS DISTINCT FROM 'OK 1' THEN
          v_fallas := v_fallas || format('%s · T no movió la fecha (control %s): %s', v_t, v_estado, v_res);
        END IF;
        IF v_estado = 'disconformidad' AND pg_temp.hay_control(v_tr, v_suc, v_d400) THEN
          v_fallas := v_fallas || format('%s · el control en disconformidad no se borró', v_t);
        END IF;
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || (v_t || ' · error inesperado: ' || SQLERRM);
    END;
  END LOOP;

  -- C5 · T marca entregado hacia un día ya controlado
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET estado = %L, transportista_id = %L, fecha_entrega = NULL WHERE id = %s',
                               'asignado', v_tr, v_ped_otr));
    PERFORM pg_temp.control(-911752, v_tr, v_suc, v_d400, 'confirmada', v_adm);
    PERFORM pg_temp.como(v_tr, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET estado = %L, fecha_entrega = %L::timestamptz, updated_at = now() WHERE id = %s',
                                 'entregado', v_t400, v_ped_otr));
    IF COALESCE(v_res, '') NOT LIKE '42501 %ya fue controlada%' THEN
      v_fallas := v_fallas || format('C5 · T marcó entregado hacia un día controlado (tenía que dar 42501): %s', v_res);
    END IF;
    IF NOT pg_temp.hay_control(v_tr, v_suc, v_d400) THEN
      v_fallas := v_fallas || 'C5 · se borró el control al marcar entregado'::text;
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET estado = %L, fecha_entrega = %L::timestamptz, updated_at = now() WHERE id = %s',
                                 'entregado', v_t401, v_ped_otr));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('C5 · T no marca entregado hacia un día sin control: %s', v_res);
    END IF;
    IF NOT pg_temp.hay_control(v_tr, v_suc, v_d400) THEN
      v_fallas := v_fallas || 'C5 · la entrega en otro día borró el control'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C5 · error inesperado: ' || SQLERRM);
  END;

  -- C6 / C6b · un cancelado que conserva el transportista
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L, fecha_entrega = NULL WHERE id = %s',
                               v_tr, v_ped_can));
    PERFORM pg_temp.como(v_tr, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET fecha_entrega = %L::timestamptz WHERE id = %s', v_t400, v_ped_can));
    IF COALESCE(v_res, '') NOT LIKE '42501 %su fecha de entrega no se cambia%' THEN
      v_fallas := v_fallas || format('C6 · T cambió la fecha de entrega de un cancelado (tenía que dar 42501): %s', v_res);
    END IF;
    PERFORM pg_temp.control(-911753, v_tr, v_suc, v_d400, 'confirmada', v_adm);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET estado = %L, fecha_entrega = %L::timestamptz WHERE id = %s',
                                 'entregado', v_t400, v_ped_can));
    IF COALESCE(v_res, '') NOT LIKE '42501 %una baja no se deshace%' THEN
      v_fallas := v_fallas || format('C6b · tenía que dar el 42501 de pedidos_guard_baja: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C6 · error inesperado: ' || SQLERRM);
  END;

  -- C7 · el preventista dueño de un entregado con control cerrado
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET estado = %L, transportista_id = %L, fecha_entrega = %L::timestamptz WHERE id = %s',
                               'entregado', v_tr, v_t400, v_ped_px7));
    PERFORM pg_temp.control(-911754, v_tr, v_suc, v_d400, 'confirmada', v_adm);
    PERFORM pg_temp.como(v_px, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET fecha_entrega = %L::timestamptz WHERE id = %s', v_t401, v_ped_px7));
    IF COALESCE(v_res, '') NOT LIKE '42501 %ya fue controlada%' THEN
      v_fallas := v_fallas || format('C7a · el dueño movió la fecha_entrega (tenía que dar 42501 de caja): %s', v_res);
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET transportista_id = NULL WHERE id = %s', v_ped_px7));
    IF COALESCE(v_res, '') NOT LIKE '42501 %ya fue controlada%' THEN
      v_fallas := v_fallas || format('C7b · el dueño cambió el transportista (tenía que dar 42501 de caja): %s', v_res);
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET estado = %L, fecha_entrega = NULL WHERE id = %s', 'pendiente', v_ped_px7));
    IF COALESCE(v_res, '') NOT LIKE '42501 %ya fue controlada%' THEN
      v_fallas := v_fallas || format('C7c · el dueño desmarcó el entregado (tenía que dar 42501 de caja): %s', v_res);
    END IF;
    IF NOT pg_temp.hay_control(v_tr, v_suc, v_d400) THEN
      v_fallas := v_fallas || 'C7 · se borró el control'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C7 · error inesperado: ' || SQLERRM);
  END;

  -- C8 · el admin sigue pudiendo (y el control se borra, por diseño)
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L, fecha_entrega = %L::timestamptz WHERE id = %s',
                               v_tr, v_t400, v_ped_ent));
    PERFORM pg_temp.control(-911755, v_tr, v_suc, v_d400, 'confirmada', v_adm);
    v_res := pg_temp.rest(format('UPDATE public.pedidos SET fecha_entrega = %L::timestamptz WHERE id = %s', v_t401, v_ped_ent));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('C8 · el admin no movió la fecha: %s', v_res);
    END IF;
    IF pg_temp.hay_control(v_tr, v_suc, v_d400) THEN
      v_fallas := v_fallas || 'C8 · el cambio del admin no borró el control'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C8 · error inesperado: ' || SQLERRM);
  END;

  -- ============================================================ #1171 =======
  -- KX1 · un transportista con el preventista como rol extra
  BEGIN
    PERFORM set_config('lock_timeout', '2s', true);
    ALTER TABLE public.perfil_roles DROP CONSTRAINT perfil_roles_rol_check;
    INSERT INTO public.perfil_roles (id, usuario_id, sucursal_id, rol) OVERRIDING SYSTEM VALUE
    VALUES (-911711, v_tr, v_suc, 'preventista');
    PERFORM pg_temp.asignar(v_cli_asg, v_px, v_suc);
    PERFORM pg_temp.como(v_tr, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.clientes SET cuit = CASE WHEN cuit = %L THEN %L ELSE %L END WHERE id = %s', '20000000009', '20000000008', '20000000009', v_cli_lib));
    IF COALESCE(v_res, '') NOT LIKE '42501 %no puede modificar estas columnas de clientes%cuit%' THEN
      v_fallas := v_fallas || format('KX1 · T con extra preventista cambió el cuit de un cliente libre (tenía que dar 42501): %s', v_res);
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.clientes SET telefono = COALESCE(telefono, %L) || %L WHERE id = %s', '', '9', v_cli_asg));
    IF v_res IS DISTINCT FROM 'OK 0' THEN
      v_fallas := v_fallas || format('KX1 · T con extra preventista editó un cliente asignado a otro (tenía que dar 0 filas): %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('KX1 · error inesperado: ' || SQLERRM);
  END;

  -- KX2 · regresión: el preventista base y el encargado
  BEGIN
    PERFORM pg_temp.asignar(v_cli_pb, v_pb, v_pb_suc);
    PERFORM pg_temp.como(v_pb, v_pb_suc);
    v_res := pg_temp.rest(format('UPDATE public.clientes SET telefono = COALESCE(telefono, %L) || %L WHERE id = %s', '', '9', v_cli_pb));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('KX2 · PB no cambia el telefono de su cliente: %s', v_res);
    END IF;
    v_res := pg_temp.rest(format('UPDATE public.clientes SET cuit = CASE WHEN cuit = %L THEN %L ELSE %L END WHERE id = %s', '20000000009', '20000000008', '20000000009', v_cli_pb));
    IF COALESCE(v_res, '') NOT LIKE '42501 %no puede modificar estas columnas de clientes%cuit%' THEN
      v_fallas := v_fallas || format('KX2 · PB cambió el cuit de su cliente (tenía que dar 42501): %s', v_res);
    END IF;
    PERFORM pg_temp.como(v_enc, v_suc);
    v_res := pg_temp.rest(format('UPDATE public.clientes SET cuit = CASE WHEN cuit = %L THEN %L ELSE %L END WHERE id = %s', '20000000009', '20000000008', '20000000009', v_cli_lib));
    IF v_res IS DISTINCT FROM 'OK 1' THEN
      v_fallas := v_fallas || format('KX2 · el encargado no cambia el cuit: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('KX2 · error inesperado: ' || SQLERRM);
  END;

  -- K1 · estructural
  BEGIN
    IF to_regprocedure('public.control_rendicion_cerrado(uuid,bigint,date)') IS NULL THEN
      v_fallas := v_fallas || 'K1 · no existe control_rendicion_cerrado(uuid,bigint,date)'::text;
    ELSE
      IF NOT has_function_privilege('authenticated', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
         OR has_function_privilege('anon', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE')
         OR has_function_privilege('public', 'public.control_rendicion_cerrado(uuid,bigint,date)', 'EXECUTE') THEN
        v_fallas := v_fallas || 'K1 · ACL de control_rendicion_cerrado: authenticated sí, anon y PUBLIC no'::text;
      END IF;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
                  AND policyname = 'mt_clientes_update'
                  AND (qual LIKE '%p.rol = ''preventista''%' OR with_check LIKE '%p.rol = ''preventista''%')) THEN
      v_fallas := v_fallas || 'K1 · mt_clientes_update sigue decidiendo por p.rol = ''preventista'''::text;
    END IF;
    IF position('control_rendicion_cerrado' IN pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure)) > 0 THEN
      IF (SELECT count(*) FROM public.auditoria_definer_sin_rol()) <> 0 THEN
        v_fallas := v_fallas || format('K1 · SEG-A no está en 0: %s',
          (SELECT string_agg(firma || ' (' || motivo || ')', '; ') FROM public.auditoria_definer_sin_rol()));
      END IF;
    ELSE
      v_notas := v_notas || 'K1 · la lista blanca de SEG-A todavía no tiene el helper: SEG-A no se mira'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K1 · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLO (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  RAISE EXCEPTION '%', v_t;
 END;
END
$ensayo$;
