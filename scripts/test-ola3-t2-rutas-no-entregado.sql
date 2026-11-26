-- Ensayo de la migración 554_ola3_t2_rutas_no_entregado (tarjeta T2 de la ola 3, #1677;
-- #1432, VTA-06 de #1522, Rut-B7 y Rut-B12 de #1554, 1601-b1 de #1601 y #1697).
--
-- Un único DO que arma sus propios datos (gente, un cliente y pedidos nuevos en la sucursal 1,
-- y un chofer de la 2) y termina SIEMPRE en una excepción (ENSAYO OK / ENSAYO FALLÓ): no deja
-- rastro. Corre sobre la base de CI sin datos. Sin la migración falla; con ella, ENSAYO OK. Usa
-- el día argentino (`_tablero_hoy()`), nunca CURRENT_DATE. El orden de los bloqueos (#1432) lo
-- prueba scripts/concurrencia/t2-rutas-orden-de-bloqueos.sh, con dos sesiones. Eso incluye el
-- FOR UPDATE de marcar_no_entregado y el estado en el WHERE de su UPDATE (VTA-06): con una sola
-- sesión el pedido se lee siempre después de la entrega confirmada, así que sacar uno solo de
-- los dos no se ve acá (sacar los dos, sí: V6).
--
-- Gente: E (encargado de la 1), ED (encargado de la 1, desactivado), choferes A, B, C y D de la
-- 1, DX (chofer de la 1 desactivado), X2 (chofer de la 2), PV (preventista de la 1), F (chofer
-- de la 1 que se desactiva con un pedido asignado), G (chofer de la 1) y AD (admin de la 1).
--
--   R1 · #1697: en la ruta de hoy de A, P1 (sin programada), P2 (programada ayer), P3
--        (programada en 3 días) y P4 (programada hoy, motivo «Lo rechazó»). A los marca no
--        entregados: P1 pasa a mañana con fecha original hoy (el día de la ruta), P2 a mañana
--        con original ayer, P3 sigue en 3 días sin marca (no se adelanta), P4 sigue hoy sin
--        marca. La fecha del pedido no cambia en ninguno, y el armado se borra (Rut-B9).
--   R2 · P2 vuelve a hoy, sale en la ruta de B y B lo marca no entregado otra vez: mañana, y la
--        fecha original sigue siendo la primera (ayer).
--   R3 · La respuesta de marcar_no_entregado dice si refechó y a qué día.
--   R4 · Decisiones del dueño del 26/11 sobre P1 (refechado en R1): E le cambia la programada a
--        mano (actualizar_fechas_y_notas_pedido, en 2 días) y la marca sigue; se entrega y la
--        marca queda en NULL; se revierte la entrega y sigue en NULL. (P3 ya probó que una
--        programada futura no se adelanta: queda para su fecha.)
--   V6 · VTA-06: marcar_no_entregado de un pedido entregado se rechaza y el pedido sigue
--        entregado (control de lo que ya estaba).
--   B1 · 1601-b1: E, por REST, no le pone a un pedido asignado el chofer PV (preventista), X2
--        (de la otra sucursal) ni DX (desactivado): 23514. A sí. También aplicar sobre un
--        pedido pendiente (sin ruta) el chofer PV se rechaza.
--   B1c · cambiar_transportista_recorrido a PV se rechaza; a D pasa y los pedidos de la ruta
--        quedan a nombre de D.
--   B1d · P11 está asignado a F y F se desactiva: un UPDATE de P11 que no cambia el chofer
--        (transportista_id = transportista_id) pasa. Sólo se valida un chofer nuevo.
--   B7 · C, por REST, no completa su ruta con una parada sin marcar (23514, con cuántas);
--        marcada, sí. Y la ruta de A, con todas marcadas, se completa.
--   B7b · En la ruta de G quedan paradas pendientes que G no puede marcar: P13 ya entregado (la
--        parada quedó desfasada) y P14, que se le pasó a A. AD (un admin, que por REST ve
--        todos los pedidos; a G la RLS ya le esconde P14) completa la ruta igual: sólo cuentan
--        las paradas de pedidos asignados al chofer de la ruta, como en el cron.
--   B12 · P7, entregado en la ruta de B: quitar_pedido_de_recorridos_activos (E) no le borra la
--        parada entregada. ED (desactivado) no quita nada.
--   G   · La columna nueva la lee authenticated y no la escribe (el PATCH da 42501).
--   AUD · RUTA-A y RUTA-B de auditoria_integridad() quedan en 0.

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_tag    text := 'T2 ' || left(gen_random_uuid()::text, 8);
  v_e      uuid := gen_random_uuid();
  v_ed     uuid := gen_random_uuid();
  v_a      uuid := gen_random_uuid();
  v_b      uuid := gen_random_uuid();
  v_c      uuid := gen_random_uuid();
  v_d      uuid := gen_random_uuid();
  v_dx     uuid := gen_random_uuid();
  v_x2     uuid := gen_random_uuid();
  v_pv     uuid := gen_random_uuid();
  v_f      uuid := gen_random_uuid();
  v_g      uuid := gen_random_uuid();
  v_ad     uuid := gen_random_uuid();
  v_rg     bigint;
  v_cli    bigint;
  v_p      bigint[] := '{}';
  v_id     bigint;
  v_ra     bigint;
  v_rb     bigint;
  v_rc     bigint;
  v_n      int;
  v_txt    text;
  v_j      jsonb;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         't2-' || u.id || '@ensayo.invalid',
         jsonb_build_object('rol', u.rol, 'sucursal_id', u.suc),
         jsonb_build_object('nombre', v_tag || ' ' || u.que), now(), now()
    FROM (VALUES (v_e, 'encargado', 1, 'E'), (v_ed, 'encargado', 1, 'ED'),
                 (v_a, 'transportista', 1, 'A'), (v_b, 'transportista', 1, 'B'),
                 (v_c, 'transportista', 1, 'C'), (v_d, 'transportista', 1, 'D'),
                 (v_dx, 'transportista', 1, 'DX'), (v_x2, 'transportista', 2, 'X2'),
                 (v_pv, 'preventista', 1, 'PV'), (v_f, 'transportista', 1, 'F'),
                 (v_g, 'transportista', 1, 'G'), (v_ad, 'admin', 1, 'AD')) AS u(id, rol, suc, que);
  -- La baja sincroniza auth.users (trg_perfiles_sync_acceso_auth): en una base sin el schema
  -- de Auth completo (la de CI), sin triggers, como test-bot-alcance-1552.
  BEGIN
    UPDATE perfiles SET activo = false WHERE id IN (v_dx, v_ed);
  EXCEPTION WHEN OTHERS THEN
    SET LOCAL session_replication_role = replica;
    UPDATE perfiles SET activo = false WHERE id IN (v_dx, v_ed);
    SET LOCAL session_replication_role = origin;
  END;

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (v_tag, v_tag, 'Calle T2 1', 1) RETURNING id INTO v_cli;

  -- P1..P14, pendientes, cargados ayer (la fecha del pedido no tiene que moverse).
  FOR v_n IN 1..14 LOOP
    INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por,
                         sucursal_id, fecha_entrega_programada)
    VALUES (v_cli, v_hoy - 1, 'pendiente', 1000, 0, 'pendiente', 'app', v_e, v_e, 1,
            CASE v_n WHEN 2 THEN v_hoy - 1 WHEN 3 THEN v_hoy + 3 WHEN 4 THEN v_hoy END)
    RETURNING id INTO v_id;
    v_p := v_p || v_id;
  END LOOP;
  -- El armado de P2: tiene que borrarse al volver a pendiente (Rut-B9).
  UPDATE pedidos SET armado_por = v_e, armado_at = now() WHERE id = v_p[2];

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
  CREATE OR REPLACE FUNCTION pg_temp.v(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE p_sql INTO r;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.ruta(p_chofer uuid, p_pedidos bigint[], p_f date) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.aplicar_orden_ruta(%L::uuid, %L::jsonb, NULL, NULL, NULL, %L::date)',
                  p_chofer,
                  (SELECT jsonb_agg(jsonb_build_object('pedido_id', x.id, 'orden_entrega', x.n) ORDER BY x.n)
                     FROM unnest(p_pedidos) WITH ORDINALITY AS x(id, n)),
                  p_f);
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.ne(p_pedido bigint, p_motivo text) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.marcar_no_entregado(%s, %L, NULL)::text', p_pedido, p_motivo);
  $f$;
  -- 'programada|original|fecha' de un pedido.
  CREATE OR REPLACE FUNCTION pg_temp.fechas(p_pedido bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE format('SELECT concat_ws(''|'', COALESCE(fecha_entrega_programada::text, ''-''),
                                     COALESCE((to_jsonb(p)->>''entrega_refechada_desde''), ''-''), fecha::text)
                      FROM public.pedidos p WHERE id = %s', p_pedido) INTO v;
    RETURN v;
  END $f$;

  -- ------------------------------------------------------------------- R1 ---
  v_ra := pg_temp.v(v_e, 1, pg_temp.ruta(v_a, v_p[1:4], v_hoy))::bigint;
  v_j := pg_temp.v(v_a, 1, pg_temp.ne(v_p[1], 'cerrado'))::jsonb;
  v_txt := pg_temp.r(v_a, 1, pg_temp.ne(v_p[2], 'ausente'));
  IF v_txt <> 'PASA' THEN v_fallas := v_fallas || format('no entregado de %s (ausente): %s', v_p[2], v_txt); END IF;
  v_txt := pg_temp.r(v_a, 1, pg_temp.ne(v_p[3], 'sin_dinero'));
  IF v_txt <> 'PASA' THEN v_fallas := v_fallas || format('no entregado de %s (sin_dinero): %s', v_p[3], v_txt); END IF;
  v_txt := pg_temp.r(v_a, 1, pg_temp.ne(v_p[4], 'cliente_rechaza'));
  IF v_txt <> 'PASA' THEN v_fallas := v_fallas || format('no entregado de %s (cliente_rechaza): %s', v_p[4], v_txt); END IF;
  IF pg_temp.fechas(v_p[1]) IS DISTINCT FROM format('%s|%s|%s', v_hoy + 1, v_hoy, v_hoy - 1) THEN
    v_fallas := v_fallas || format('R1 · P1 (sin programada, «cerrado») quedó %s; se esperaba mañana, original hoy (la ruta)', pg_temp.fechas(v_p[1]));
  END IF;
  IF pg_temp.fechas(v_p[2]) IS DISTINCT FROM format('%s|%s|%s', v_hoy + 1, v_hoy - 1, v_hoy - 1) THEN
    v_fallas := v_fallas || format('R1 · P2 (programada ayer, «ausente») quedó %s; se esperaba mañana, original ayer', pg_temp.fechas(v_p[2]));
  END IF;
  IF pg_temp.fechas(v_p[3]) IS DISTINCT FROM format('%s|-|%s', v_hoy + 3, v_hoy - 1) THEN
    v_fallas := v_fallas || format('R1 · P3 (programada en 3 días) quedó %s; se esperaba sin cambios', pg_temp.fechas(v_p[3]));
  END IF;
  IF pg_temp.fechas(v_p[4]) IS DISTINCT FROM format('%s|-|%s', v_hoy, v_hoy - 1) THEN
    v_fallas := v_fallas || format('R1 · P4 («Lo rechazó») quedó %s; se esperaba sin cambios', pg_temp.fechas(v_p[4]));
  END IF;
  IF (SELECT armado_at FROM pedidos WHERE id = v_p[2]) IS NOT NULL
     OR (SELECT count(*) FROM pedidos WHERE id = ANY (v_p[1:4]) AND estado = 'pendiente' AND transportista_id IS NULL) <> 4 THEN
    v_fallas := v_fallas || 'R1 · los no entregados no quedaron pendientes, sin chofer y sin armado'::text;
  END IF;

  -- ------------------------------------------------------------------- R3 ---
  IF v_j IS NULL OR NOT COALESCE((v_j->>'refechado')::boolean, false)
     OR v_j->>'fecha_entrega_programada' IS DISTINCT FROM (v_hoy + 1)::text THEN
    v_fallas := v_fallas || ('R3 · la respuesta no dice el refechado: ' || COALESCE(v_j::text, 'NULL'));
  END IF;

  -- ------------------------------------------------------------------- R2 ---
  UPDATE pedidos SET fecha_entrega_programada = v_hoy WHERE id = v_p[2];
  v_rb := pg_temp.v(v_e, 1, pg_temp.ruta(v_b, ARRAY[v_p[2], v_p[7]], v_hoy))::bigint;
  v_txt := pg_temp.r(v_b, 1, pg_temp.ne(v_p[2], 'clima'));
  IF v_txt <> 'PASA' THEN v_fallas := v_fallas || format('no entregado de %s (clima): %s', v_p[2], v_txt); END IF;
  IF pg_temp.fechas(v_p[2]) IS DISTINCT FROM format('%s|%s|%s', v_hoy + 1, v_hoy - 1, v_hoy - 1) THEN
    v_fallas := v_fallas || format('R2 · P2 refechado dos veces quedó %s; se esperaba mañana con la original de la primera (ayer)', pg_temp.fechas(v_p[2]));
  END IF;

  -- ------------------------------------------------------------------- R4 ---
  -- En un sub-bloque que se deshace: P1 se entrega fuera de toda ruta y se revierte.
  BEGIN
    v_txt := pg_temp.r(v_e, 1, format('SELECT public.actualizar_fechas_y_notas_pedido(%s, NULL, NULL, NULL, %L::date)',
                                      v_p[1], v_hoy + 2));
    IF v_txt <> 'PASA' OR pg_temp.fechas(v_p[1]) IS DISTINCT FROM format('%s|%s|%s', v_hoy + 2, v_hoy, v_hoy - 1) THEN
      v_fallas := v_fallas || format('R4 · el cambio a mano de la programada no conservó la marca: %s (%s)', pg_temp.fechas(v_p[1]), v_txt);
    END IF;
    UPDATE pedidos SET estado = 'entregado', transportista_id = v_a, fecha_entrega = now() WHERE id = v_p[1];
    IF (SELECT to_jsonb(p)->>'entrega_refechada_desde' FROM pedidos p WHERE id = v_p[1]) IS NOT NULL THEN
      v_fallas := v_fallas || 'R4 · al entregarse, la marca de refechado no se borró'::text;
    END IF;
    UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_p[1];
    IF (SELECT to_jsonb(p)->>'entrega_refechada_desde' FROM pedidos p WHERE id = v_p[1]) IS NOT NULL THEN
      v_fallas := v_fallas || 'R4 · al revertir la entrega, la marca de refechado volvió'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ0DS';
  EXCEPTION WHEN SQLSTATE 'ZZ0DS' THEN NULL;
  END;

  -- ------------------------------------------------------------- V6 y B12 ---
  v_txt := pg_temp.r(v_e, 1, format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, %L::date)',
                                    v_p[7], v_b, v_hoy));
  IF v_txt <> 'PASA' OR (SELECT estado FROM pedidos WHERE id = v_p[7]) <> 'entregado' THEN
    v_fallas := v_fallas || ('V6 · no se pudo entregar P7 para el ensayo: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_b, 1, pg_temp.ne(v_p[7], 'cerrado'));
  IF v_txt = 'PASA' OR (SELECT estado FROM pedidos WHERE id = v_p[7]) <> 'entregado' THEN
    v_fallas := v_fallas || ('V6 · un entregado se marcó no entregado: ' || v_txt);
  END IF;

  v_txt := pg_temp.v(v_e, 1, format('SELECT public.quitar_pedido_de_recorridos_activos(%s)::text', v_p[7]));
  IF (SELECT estado_entrega FROM recorrido_pedidos WHERE recorrido_id = v_rb AND pedido_id = v_p[7]) IS DISTINCT FROM 'entregado' THEN
    v_fallas := v_fallas || ('B12 · quitar_pedido_de_recorridos_activos borró la parada entregada de P7: ' || v_txt);
  END IF;
  v_txt := pg_temp.v(v_ed, 1, format('SELECT public.quitar_pedido_de_recorridos_activos(%s)::text', v_p[5]));
  IF v_txt IS NULL OR COALESCE((v_txt::jsonb->>'success')::boolean, true) THEN
    v_fallas := v_fallas || ('B12 · un encargado desactivado quitó un pedido de la ruta: ' || COALESCE(v_txt, 'NULL'));
  END IF;

  -- ------------------------------------------------------------------- B1 ---
  v_rc := pg_temp.v(v_e, 1, pg_temp.ruta(v_c, ARRAY[v_p[5], v_p[6]], v_hoy))::bigint;
  FOR v_txt IN SELECT unnest(ARRAY[v_pv::text, v_x2::text, v_dx::text]) LOOP
    v_j := to_jsonb(pg_temp.r(v_e, 1, format('UPDATE public.pedidos SET transportista_id = %L::uuid WHERE id = %s', v_txt, v_p[5])));
    IF v_j #>> '{}' !~ '^23514 ' OR (SELECT transportista_id FROM pedidos WHERE id = v_p[5]) IS DISTINCT FROM v_c THEN
      v_fallas := v_fallas || format('B1 · E le puso al pedido el chofer %s (no es chofer activo de la sucursal): %s',
                                     (SELECT nombre FROM perfiles WHERE id = v_txt::uuid), v_j #>> '{}');
    END IF;
  END LOOP;
  UPDATE pedidos SET transportista_id = v_c WHERE id = v_p[5] AND transportista_id IS DISTINCT FROM v_c;
  v_txt := pg_temp.r(v_e, 1, format('UPDATE public.pedidos SET transportista_id = %L::uuid WHERE id = %s', v_pv, v_p[8]));
  IF v_txt !~ '^23514 ' THEN
    v_fallas := v_fallas || ('B1 · E le puso a un pendiente un preventista como chofer: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_e, 1, format('UPDATE public.pedidos SET transportista_id = %L::uuid WHERE id = %s', v_a, v_p[8]));
  IF v_txt <> 'PASA' THEN
    v_fallas := v_fallas || ('B1 · E no pudo ponerle a un pedido el chofer A: ' || v_txt);
  END IF;
  UPDATE pedidos SET transportista_id = NULL WHERE id = v_p[8];

  -- ------------------------------------------------------------------ B1c ---
  v_txt := pg_temp.r(v_e, 1, format('SELECT public.cambiar_transportista_recorrido(%s, %L::uuid)', v_rc, v_pv));
  IF v_txt = 'PASA' THEN
    v_fallas := v_fallas || 'B1c · la ruta de C pasó a un preventista'::text;
  END IF;
  v_txt := pg_temp.r(v_e, 1, format('SELECT public.cambiar_transportista_recorrido(%s, %L::uuid)', v_rc, v_d));
  IF v_txt <> 'PASA'
     OR (SELECT count(*) FROM pedidos WHERE id IN (v_p[5], v_p[6]) AND transportista_id = v_d) <> 2 THEN
    v_fallas := v_fallas || ('B1c · la ruta de C no pasó a D con sus pedidos: ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- B7 ---
  v_txt := pg_temp.r(v_d, 1, pg_temp.ne(v_p[5], 'cerrado'));
  IF v_txt <> 'PASA' THEN v_fallas := v_fallas || format('no entregado de %s (cerrado): %s', v_p[5], v_txt); END IF;
  v_txt := pg_temp.r(v_d, 1, format('UPDATE public.recorridos SET estado = ''completado'' WHERE id = %s', v_rc));
  IF v_txt !~ '^23514 .*1 parada' OR (SELECT estado FROM recorridos WHERE id = v_rc) <> 'en_curso' THEN
    v_fallas := v_fallas || ('B7 · D completó su ruta con una parada sin marcar: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_d, 1, pg_temp.ne(v_p[6], 'ausente'));
  IF v_txt <> 'PASA' THEN v_fallas := v_fallas || format('no entregado de %s (ausente): %s', v_p[6], v_txt); END IF;
  v_txt := pg_temp.r(v_d, 1, format('UPDATE public.recorridos SET estado = ''completado'' WHERE id = %s', v_rc));
  IF v_txt <> 'PASA' OR (SELECT estado FROM recorridos WHERE id = v_rc) <> 'completado' THEN
    v_fallas := v_fallas || ('B7 · D no pudo completar su ruta con todo marcado: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_a, 1, format('UPDATE public.recorridos SET estado = ''completado'' WHERE id = %s', v_ra));
  IF v_txt <> 'PASA' THEN
    v_fallas := v_fallas || ('B7 · A no pudo completar su ruta con todo marcado: ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------ B1d ---
  UPDATE pedidos SET estado = 'asignado', transportista_id = v_f WHERE id = v_p[11];
  BEGIN
    UPDATE perfiles SET activo = false WHERE id = v_f;
  EXCEPTION WHEN OTHERS THEN
    SET LOCAL session_replication_role = replica;
    UPDATE perfiles SET activo = false WHERE id = v_f;
    SET LOCAL session_replication_role = origin;
  END;
  v_txt := pg_temp.r(v_e, 1, format('UPDATE public.pedidos SET transportista_id = transportista_id WHERE id = %s', v_p[11]));
  IF v_txt <> 'PASA' THEN
    v_fallas := v_fallas || ('B1d · un UPDATE que no cambia el chofer (desactivado) se rechazó: ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------ B7b ---
  -- En un sub-bloque que se deshace: las paradas desfasadas a propósito pondrían RUTA-A en rojo.
  BEGIN
    v_rg := pg_temp.v(v_e, 1, pg_temp.ruta(v_g, v_p[12:14], v_hoy))::bigint;
    v_txt := pg_temp.r(v_g, 1, pg_temp.ne(v_p[12], 'cerrado'));
    IF v_txt <> 'PASA' THEN v_fallas := v_fallas || ('B7b · no entregado de P12: ' || v_txt); END IF;
    -- P13 entregado y su parada vuelta a pendiente (desfasada); P14 pasado a A.
    UPDATE pedidos SET estado = 'entregado', fecha_entrega = now() WHERE id = v_p[13];
    UPDATE recorrido_pedidos SET estado_entrega = 'pendiente', hora_entrega = NULL
     WHERE recorrido_id = v_rg AND pedido_id = v_p[13];
    UPDATE pedidos SET transportista_id = v_a WHERE id = v_p[14];
    v_txt := pg_temp.r(v_ad, 1, format('UPDATE public.recorridos SET estado = ''completado'' WHERE id = %s', v_rg));
    IF v_txt <> 'PASA' OR (SELECT estado FROM recorridos WHERE id = v_rg) <> 'completado' THEN
      v_fallas := v_fallas || ('B7b · la ruta de G no se completó por paradas que G no puede marcar: ' || v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ0DS';
  EXCEPTION WHEN SQLSTATE 'ZZ0DS' THEN NULL;
  END;

  -- -------------------------------------------------------------------- G ---
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.pedidos'::regclass
                    AND attname = 'entrega_refechada_desde' AND NOT attisdropped) THEN
    v_fallas := v_fallas || 'G · no existe pedidos.entrega_refechada_desde'::text;
  ELSIF NOT has_column_privilege('authenticated', 'public.pedidos', 'entrega_refechada_desde', 'SELECT') THEN
    v_fallas := v_fallas || 'G · authenticated no lee pedidos.entrega_refechada_desde'::text;
  ELSE
    v_txt := pg_temp.r(v_e, 1, format('UPDATE public.pedidos SET entrega_refechada_desde = %L::date WHERE id = %s', v_hoy, v_p[9]));
    IF v_txt !~ '^42501 ' THEN
      v_fallas := v_fallas || ('G · la marca de refechado se escribe por REST: ' || v_txt);
    END IF;
  END IF;

  -- ------------------------------------------------------------------ AUD ---
  SELECT string_agg(format('%s=%s', e->>'id', e->>'violaciones'), ', ')
    INTO v_txt
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' IN ('RUTA-A', 'RUTA-B') AND (e->>'violaciones')::bigint <> 0;
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || ('AUD · ' || v_txt);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = 'ENSAYO FALLÓ · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · R1 R2 R3 R4 V6 B12 B1 B1c B1d B7 B7b G AUD (hoy %s; rutas A %s, B %s, C %s)', v_hoy, v_ra, v_rb, v_rc);
 END;
END
$ensayo$;
