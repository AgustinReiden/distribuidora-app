-- Ensayo de #1151 (segunda tanda del barrido de grants REST): SELECT sin
-- policy, secuencias, policies FOR ALL / TO public, UPDATE de pedidos y
-- recorridos por columna, y historial_cambios.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consumen los INSERT de zonas, productos, pedido_historial y stock_historico):
-- un único DO que termina SIEMPRE en una excepción, y cada caso corre en su
-- propio sub-bloque que se revierte al terminar. Nunca hace setval: Q1 es de
-- catálogo.
--
-- Simula PostgREST como test-grants-rest-1134-1135.sql: `SET LOCAL ROLE
-- authenticated`, el `sub` de un perfil real en request.jwt.claims y la
-- sucursal en x-sucursal-id. Usa una sucursal activa con admin, encargado,
-- preventista y transportista activos.
--
-- Sin la migración tiene que FALLAR en S1, Q1, Q3, P1, C1, C3 y C4. S2, Q2,
-- P2 y C2 pasan antes y después (regresiones). Con la migración (inline antes
-- del DO) tiene que dar 'ENSAYO OK'.
--
--   S1 · admin y preventista: SELECT de cada uno de los 12 bot_* → 42501
--        (antes daba 0 filas sin error)
--   S2 · admin: bot_admin_listar_config_digest() OK; el preventista lee
--        bot_codigos_vinculacion sin error
--   Q1 · catálogo: authenticated tiene USAGE en exactamente las 18 secuencias
--        de scripts/grants-rest.json y SELECT / UPDATE en ninguna
--   Q2 · admin INSERT en zonas (nextval); admin PATCH productos.stock + 1 →
--        una fila en stock_historico (identity, trigger INVOKER); el
--        preventista dueño PATCH pedidos.notas → +1 en pedido_historial
--        (serial, trigger INVOKER)
--   Q3 · una tabla nueva de postgres en public nace con su secuencia sin nada
--        para authenticated, y pg_default_acl no tiene una entrada de
--        postgres / public / secuencias para authenticated
--   P1 · ninguna policy FOR ALL sobre una tabla sin escritura de
--        authenticated, ninguna con rol PUBLIC; las 5 convertidas son FOR
--        SELECT TO authenticated con el USING de prod; admin y preventista leen
--        todas las sucursales
--   P2 · el preventista PATCH de su perfil → OK
--   C1 · admin y encargado: PATCH de pedidos.total, monto_pagado, estado_pago
--        y stock_descontado → 42501 «permission denied for table pedidos»
--   C2 · siguen: PATCH de notas del preventista dueño, de fecha y
--        fecha_entrega_programada del admin, asignar transportista
--        (transportista_id, estado) y la entrega del transportista (estado,
--        fecha_entrega, updated_at)
--   C3 · admin PATCH recorridos.total_cobrado → 42501; estado y completed_at OK
--   C4 · auditoria_grants_tablas(): select_sin_policy = [], policies_public =
--        [], 18 secuencias, pedidos.UPDATE con las 7 columnas y recorridos con
--        2; authenticated sin EXECUTE sobre ella; historial_cambios no existe
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenar un rollback).
--
--   psql "$DATABASE_URL" -f scripts/test-grants-rest-segunda-tanda-1151.sql

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_admin   uuid;
  v_enc     uuid;
  v_prev    uuid;
  v_trans   uuid;
  v_ps      bigint;   -- producto de v_suc
  v_ped     bigint;
  v_rec     bigint;
  v_err     text;
  v_errs    text[];
  v_res     text;
  v_n       bigint;
  v_n2      bigint;
  v_t       text;
  v_txt     text[];
  v_g       jsonb;
  r         record;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
  v_bots    text[] := ARRAY[
    'bot_audit_log', 'bot_avisos_atrasados_enviados', 'bot_avisos_vencimiento_enviados',
    'bot_conversaciones', 'bot_costo_llm_mensual', 'bot_digest_config', 'bot_digests_enviados',
    'bot_intentos_vinculacion', 'bot_pedidos_pendientes', 'bot_presupuesto_llm',
    'bot_updates_procesados', 'bot_usuarios'];
  -- = scripts/grants-rest.json («secuencias»)
  v_seqs    text[] := ARRAY[
    'cliente_descuentos_categoria_id_seq', 'clientes_codigo_seq', 'clientes_id_seq',
    'grupo_precio_escala_minimos_id_seq', 'grupo_precio_escalas_id_seq',
    'grupo_precio_productos_id_seq', 'grupos_precio_id_seq', 'ii_encuadres_id_seq',
    'pagos_id_seq', 'pedido_historial_id_seq', 'perfil_roles_id_seq', 'productos_id_seq',
    'promocion_productos_id_seq', 'promocion_reglas_id_seq', 'promociones_id_seq',
    'proveedores_id_seq', 'stock_historico_id_seq', 'zonas_id_seq'];
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, a.usuario_id, e.usuario_id, p.usuario_id, t.usuario_id
    INTO v_suc, v_admin, v_enc, v_prev, v_trans
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin' ORDER BY us.usuario_id LIMIT 1) a ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado' ORDER BY us.usuario_id LIMIT 1) e ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista' ORDER BY us.usuario_id LIMIT 1) p ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista' ORDER BY us.usuario_id LIMIT 1) t ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con admin, encargado, preventista y transportista activos';
  END IF;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  -- Una sentencia como PostgREST: NULL si pasó, o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Filas afectadas como PostgREST, o el error.
  CREATE FUNCTION pg_temp.rest_n(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Un SELECT escalar como PostgREST, o 'ERR SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest_val(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN COALESCE(v, '(null)');
  EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE || ' ' || SQLERRM;
  END $f$;
  CREATE FUNCTION pg_temp.es_42501(p_err text) RETURNS boolean LANGUAGE sql AS $f$
    SELECT p_err IS NOT NULL AND p_err LIKE '42501%';
  $f$;

  -- ---------------------------------------------------------------- fixture -
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1151 S', 100, 40, 10, v_suc) RETURNING id INTO v_ps;

  -- ========================================================= S · SELECT =====
  -- S1 · nadie lee los bot_* por REST
  BEGIN
    FOREACH v_t IN ARRAY v_bots LOOP
      PERFORM pg_temp.como(v_admin, v_suc);
      v_err := pg_temp.rest(format('SELECT count(*) FROM public.%I', v_t));
      IF NOT pg_temp.es_42501(v_err) THEN
        v_fallas := v_fallas || format('S1 · admin SELECT %s tenía que dar 42501; error %s', v_t, COALESCE(v_err, '(ninguno)'));
      END IF;
      PERFORM pg_temp.como(v_prev, v_suc);
      v_err := pg_temp.rest(format('SELECT count(*) FROM public.%I', v_t));
      IF NOT pg_temp.es_42501(v_err) THEN
        v_fallas := v_fallas || format('S1 · preventista SELECT %s tenía que dar 42501; error %s', v_t, COALESCE(v_err, '(ninguno)'));
      END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('S1 · error inesperado: ' || SQLERRM);
  END;

  -- S2 · las RPC del bot y la lectura con policy siguen
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_res := pg_temp.rest_val('SELECT count(*)::text FROM public.bot_admin_listar_config_digest()');
    IF v_res LIKE 'ERR%' THEN
      v_fallas := v_fallas || format('S2 · admin bot_admin_listar_config_digest(): %s', v_res);
    END IF;
    PERFORM pg_temp.como(v_prev, v_suc);
    v_err := pg_temp.rest('SELECT count(*) FROM public.bot_codigos_vinculacion');
    IF v_err IS NOT NULL THEN
      v_fallas := v_fallas || format('S2 · el preventista no lee bot_codigos_vinculacion: %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('S2 · error inesperado: ' || SQLERRM);
  END;

  -- ===================================================== Q · secuencias =====
  -- Q1 · catálogo
  BEGIN
    SELECT array_agg(c.relname::text ORDER BY c.relname) INTO v_txt
      FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'S'
       -- (CASE: sin él el planner evalúa la función sobre relaciones que no
       -- son secuencias y falla)
       AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('authenticated', c.oid, 'USAGE') END;
    IF v_txt IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(v_seqs) x) THEN
      v_fallas := v_fallas || format('Q1 · authenticated tiene USAGE en %s secuencias (tenían que ser las 18); sobran %s, faltan %s',
        COALESCE(cardinality(v_txt), 0),
        cardinality(ARRAY(SELECT unnest(v_txt) EXCEPT SELECT unnest(v_seqs))),
        ARRAY(SELECT unnest(v_seqs) EXCEPT SELECT unnest(v_txt) ORDER BY 1));
    END IF;
    SELECT array_agg(c.relname::text ORDER BY c.relname) INTO v_txt
      FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind = 'S'
       AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('authenticated', c.oid, 'SELECT')
                                       OR has_sequence_privilege('authenticated', c.oid, 'UPDATE') END;
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || format('Q1 · authenticated tiene SELECT o UPDATE (setval) en %s secuencias (p. ej. %s)',
        cardinality(v_txt), array_to_string(v_txt[1:3], ', '));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('Q1 · error inesperado: ' || SQLERRM);
  END;

  -- Q2 · los INSERT REST y los triggers INVOKER siguen sacando su id
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_err := pg_temp.rest_n(format('INSERT INTO public.zonas (nombre, sucursal_id) VALUES (%L, %s)', 'ZZ ensayo 1151', v_suc));
    IF v_err IS DISTINCT FROM '1' THEN
      v_fallas := v_fallas || format('Q2 · admin INSERT zonas por REST: %s', v_err);
    END IF;
    SELECT count(*) INTO v_n FROM stock_historico WHERE producto_id = v_ps;
    v_err := pg_temp.rest_n(format('UPDATE public.productos SET stock = stock + 1 WHERE id = %s', v_ps));
    SELECT count(*) INTO v_n2 FROM stock_historico WHERE producto_id = v_ps;
    IF v_err IS DISTINCT FROM '1' OR v_n2 <> v_n + 1 THEN
      v_fallas := v_fallas || format('Q2 · admin PATCH productos.stock: %s, stock_historico %s → %s', v_err, v_n, v_n2);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('Q2 · error inesperado: ' || SQLERRM);
  END;
  -- Q2 / C2 · el preventista dueño, PATCH de notas (trigger INVOKER a
  -- pedido_historial). De cualquier sucursal: el preventista con rol extra de
  -- transportista cae en la otra rama de pedidos_proteger_columnas.
  BEGIN
    SELECT pe.id, pe.usuario_id, pe.sucursal_id INTO r
      FROM pedidos pe
      JOIN perfiles pf ON pf.id = pe.usuario_id AND pf.activo AND pf.rol = 'preventista'
      JOIN usuario_sucursales us ON us.usuario_id = pe.usuario_id AND us.sucursal_id = pe.sucursal_id
     WHERE NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pe.usuario_id AND pr.rol = 'transportista')
       AND pe.transportista_id IS DISTINCT FROM pe.usuario_id
       AND pe.estado <> 'cancelado'
     ORDER BY pe.id DESC LIMIT 1;
    IF r.id IS NULL THEN
      v_fallas := v_fallas || 'Q2 · no hay pedido de un preventista (sin rol de transportista) para el PATCH de notas'::text;
    ELSE
      PERFORM pg_temp.como(r.usuario_id, r.sucursal_id);
      SELECT count(*) INTO v_n FROM pedido_historial WHERE pedido_id = r.id;
      v_err := pg_temp.rest_n(format('UPDATE public.pedidos SET notas = COALESCE(notas, %L) || %L WHERE id = %s', '', ' [ensayo 1151]', r.id));
      SELECT count(*) INTO v_n2 FROM pedido_historial WHERE pedido_id = r.id;
      IF v_err IS DISTINCT FROM '1' OR v_n2 <> v_n + 1 THEN
        v_fallas := v_fallas || format('Q2 · el preventista dueño, PATCH de notas: %s, historial %s → %s', v_err, v_n, v_n2);
      END IF;
      -- P2 · y su perfil
      v_err := pg_temp.rest_n('UPDATE public.perfiles SET nombre = nombre WHERE id = auth.uid()');
      IF v_err IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('P2 · el preventista no actualiza su perfil por REST: %s', v_err);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('Q2 · preventista, error inesperado: ' || SQLERRM);
  END;

  -- Q3 · una secuencia nueva nace sin nada para authenticated (en public: una
  -- temporal crea su secuencia en pg_temp, donde el default no aplica)
  BEGIN
    CREATE TABLE public.zz_ensayo_seq (id serial PRIMARY KEY);
    v_txt := '{}';
    FOREACH v_t IN ARRAY ARRAY['SELECT', 'UPDATE', 'USAGE'] LOOP
      IF has_sequence_privilege('authenticated', 'public.zz_ensayo_seq_id_seq', v_t) THEN
        v_txt := v_txt || ('authenticated secuencia ' || v_t);
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM pg_default_acl d, aclexplode(d.defaclacl) x
                WHERE d.defaclrole = 'postgres'::regrole AND d.defaclnamespace = 'public'::regnamespace
                  AND d.defaclobjtype = 'S' AND x.grantee = 'authenticated'::regrole) THEN
      v_txt := v_txt || 'pg_default_acl de postgres en public le da secuencias a authenticated'::text;
    END IF;
    IF cardinality(v_txt) > 0 THEN
      v_fallas := v_fallas || format('Q3 · una secuencia nueva nace con: %s', array_to_string(v_txt, ', '));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('Q3 · error inesperado: ' || SQLERRM);
  END;

  -- ======================================================= P · policies =====
  BEGIN
    SELECT array_agg(c.relname || '.' || p.polname ORDER BY 1) INTO v_txt
      FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
     WHERE c.relnamespace = 'public'::regnamespace AND p.polcmd = '*'
       AND NOT (has_any_column_privilege('authenticated', c.oid, 'INSERT')
                OR has_any_column_privilege('authenticated', c.oid, 'UPDATE')
                OR has_table_privilege('authenticated', c.oid, 'DELETE'));
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || format('P1 · policies FOR ALL sobre tablas sin escritura REST: %s', v_txt);
    END IF;
    SELECT array_agg(tablename || '.' || policyname ORDER BY 1) INTO v_txt
      FROM pg_policies WHERE schemaname = 'public' AND 'public' = ANY(roles);
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || format('P1 · policies con rol PUBLIC: %s', v_txt);
    END IF;
    -- El USING de prod de las 5 FOR ALL (2026-10-14).
    FOR r IN SELECT * FROM (VALUES
        ('proveedores_eliminados', 'proveedores_eliminados_select_admin',
         E'(EXISTS ( SELECT 1\n   FROM perfiles\n  WHERE ((perfiles.id = auth.uid()) AND (perfiles.rol = ''admin''::text))))'),
        ('usuario_sucursales', 'usuario_sucursales_select_admin', '(es_admin() AND (sucursal_id = current_sucursal_id()))'),
        ('transferencias_stock', 'mt_transferencias_stock_select_admin', '(es_admin() AND (tenant_sucursal_id = current_sucursal_id()))'),
        ('transferencia_items', 'mt_transferencia_items_select_admin', '(es_admin() AND (sucursal_id = current_sucursal_id()))'),
        ('promo_ajustes', 'mt_promo_ajustes_select_admin', '(es_admin() AND (sucursal_id = current_sucursal_id()))')) AS e(t, pol, q)
    LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_policies p
                      WHERE p.schemaname = 'public' AND p.tablename = r.t AND p.policyname = r.pol
                        AND p.cmd = 'SELECT' AND p.roles = ARRAY['authenticated']::name[]
                        AND p.with_check IS NULL AND p.qual = r.q) THEN
        v_fallas := v_fallas || format('P1 · %s no tiene %s FOR SELECT TO authenticated con el USING de prod', r.t, r.pol);
      END IF;
    END LOOP;
    -- Las sucursales las siguen leyendo todos.
    SELECT count(*) INTO v_n FROM sucursales;
    PERFORM pg_temp.como(v_admin, v_suc);
    v_res := pg_temp.rest_val('SELECT count(*)::text FROM public.sucursales');
    PERFORM pg_temp.como(v_prev, v_suc);
    v_t := pg_temp.rest_val('SELECT count(*)::text FROM public.sucursales');
    IF v_res IS DISTINCT FROM v_n::text OR v_t IS DISTINCT FROM v_n::text THEN
      v_fallas := v_fallas || format('P1 · sucursales legibles: admin %s, preventista %s, hay %s', v_res, v_t, v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('P1 · error inesperado: ' || SQLERRM);
  END;

  -- ===================================================== C · columnas =======
  -- C1 · las columnas derivadas de pedidos no se PATCHean
  BEGIN
    SELECT id INTO v_ped FROM pedidos WHERE sucursal_id = v_suc AND estado <> 'cancelado' ORDER BY id DESC LIMIT 1;
    v_txt := '{}';
    FOREACH v_t IN ARRAY ARRAY['admin', 'encargado'] LOOP
      PERFORM pg_temp.como(CASE WHEN v_t = 'admin' THEN v_admin ELSE v_enc END, v_suc);
      v_errs := ARRAY[
        pg_temp.rest(format('UPDATE public.pedidos SET total = total + 1 WHERE id = %s', v_ped)),
        pg_temp.rest(format('UPDATE public.pedidos SET monto_pagado = monto_pagado WHERE id = %s', v_ped)),
        pg_temp.rest(format('UPDATE public.pedidos SET estado_pago = estado_pago WHERE id = %s', v_ped)),
        pg_temp.rest(format('UPDATE public.pedidos SET stock_descontado = stock_descontado WHERE id = %s', v_ped))];
      FOR v_n IN 1 .. 4 LOOP
        IF COALESCE(v_errs[v_n], '') NOT LIKE '42501 permission denied for table pedidos%' THEN
          v_fallas := v_fallas || format('C1 · %s PATCH pedidos.%s tenía que cortar por grant; error %s', v_t,
            (ARRAY['total', 'monto_pagado', 'estado_pago', 'stock_descontado'])[v_n], COALESCE(v_errs[v_n], '(ninguno)'));
        END IF;
      END LOOP;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C1 · error inesperado: ' || SQLERRM);
  END;

  -- C2 · lo que el front escribe de pedidos sigue andando
  BEGIN
    PERFORM pg_temp.como(v_admin, v_suc);
    v_err := pg_temp.rest_n(format(
      'UPDATE public.pedidos SET notas = notas, fecha = fecha, fecha_entrega_programada = fecha_entrega_programada WHERE id = %s', v_ped));
    IF v_err IS DISTINCT FROM '1' THEN
      v_fallas := v_fallas || format('C2 · admin PATCH notas / fecha / fecha_entrega_programada: %s', v_err);
    END IF;
    SELECT id INTO v_n FROM pedidos
     WHERE sucursal_id = v_suc AND estado = 'pendiente' AND transportista_id IS NULL
     ORDER BY id DESC LIMIT 1;
    IF v_n IS NULL THEN
      v_notas := v_notas || 'C2 · sin pedido pendiente sin transportista: se saltea asignar / entregar'::text;
    ELSE
      v_err := pg_temp.rest_n(format('UPDATE public.pedidos SET transportista_id = %L, estado = %L WHERE id = %s',
                                     v_trans, 'asignado', v_n));
      IF v_err IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('C2 · admin asigna transportista: %s', v_err);
      ELSE
        PERFORM pg_temp.como(v_trans, v_suc);
        v_err := pg_temp.rest_n(format(
          'UPDATE public.pedidos SET estado = %L, fecha_entrega = now(), updated_at = now() WHERE id = %s', 'entregado', v_n));
        IF v_err IS DISTINCT FROM '1' THEN
          v_fallas := v_fallas || format('C2 · el transportista marca la entrega: %s', v_err);
        END IF;
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C2 · error inesperado: ' || SQLERRM);
  END;

  -- C3 · recorridos: los contadores no, estado y completed_at sí
  BEGIN
    SELECT id INTO v_rec FROM recorridos WHERE sucursal_id = v_suc ORDER BY id DESC LIMIT 1;
    IF v_rec IS NULL THEN
      v_notas := v_notas || 'C3 · sin recorrido en la sucursal: se saltea'::text;
    ELSE
      PERFORM pg_temp.como(v_admin, v_suc);
      v_err := pg_temp.rest(format('UPDATE public.recorridos SET total_cobrado = COALESCE(total_cobrado, 0) + 1 WHERE id = %s', v_rec));
      IF COALESCE(v_err, '') NOT LIKE '42501 permission denied for table recorridos%' THEN
        v_fallas := v_fallas || format('C3 · admin PATCH recorridos.total_cobrado tenía que cortar por grant; error %s', COALESCE(v_err, '(ninguno)'));
      END IF;
      v_err := pg_temp.rest_n(format('UPDATE public.recorridos SET estado = estado, completed_at = completed_at WHERE id = %s', v_rec));
      IF v_err IS DISTINCT FROM '1' THEN
        v_fallas := v_fallas || format('C3 · admin PATCH recorridos estado / completed_at: %s', v_err);
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C3 · error inesperado: ' || SQLERRM);
  END;

  -- C4 · lo que ve el gate
  BEGIN
    v_g := public.auditoria_grants_tablas();
    IF v_g->'select_sin_policy' IS DISTINCT FROM '[]'::jsonb THEN
      v_fallas := v_fallas || format('C4 · select_sin_policy = %s', COALESCE(v_g->>'select_sin_policy', '(no está)'));
    END IF;
    IF v_g->'policies_public' IS DISTINCT FROM '[]'::jsonb THEN
      v_fallas := v_fallas || format('C4 · policies_public = %s', COALESCE(v_g->>'policies_public', '(no está)'));
    END IF;
    IF (SELECT array_agg((s->>'secuencia') || '.' || (s->>'privilegio') ORDER BY 1)
          FROM jsonb_array_elements(COALESCE(v_g->'authenticated_secuencias', '[]')) s)
       IS DISTINCT FROM (SELECT array_agg(x || '.USAGE' ORDER BY 1) FROM unnest(v_seqs) x) THEN
      v_fallas := v_fallas || format('C4 · authenticated_secuencias no son las 18 con USAGE: %s',
        left(COALESCE(v_g->>'authenticated_secuencias', '(no está)'), 200));
    END IF;
    IF (SELECT jsonb_agg(e->'nivel') FROM jsonb_array_elements(v_g->'authenticated_escrituras') e
         WHERE e->>'tabla' = 'pedidos' AND e->>'privilegio' = 'UPDATE')
       IS DISTINCT FROM '[["estado", "fecha", "fecha_entrega", "fecha_entrega_programada", "notas", "transportista_id", "updated_at"]]'::jsonb THEN
      v_fallas := v_fallas || 'C4 · pedidos.UPDATE no es por las 7 columnas'::text;
    END IF;
    IF (SELECT jsonb_agg(e->'nivel') FROM jsonb_array_elements(v_g->'authenticated_escrituras') e
         WHERE e->>'tabla' = 'recorridos' AND e->>'privilegio' = 'UPDATE')
       IS DISTINCT FROM '[["completed_at", "estado"]]'::jsonb THEN
      v_fallas := v_fallas || 'C4 · recorridos.UPDATE no es por (completed_at, estado)'::text;
    END IF;
    IF has_function_privilege('authenticated', 'public.auditoria_grants_tablas()', 'EXECUTE')
       OR has_function_privilege('anon', 'public.auditoria_grants_tablas()', 'EXECUTE') THEN
      v_fallas := v_fallas || 'C4 · authenticated o anon pueden ejecutar auditoria_grants_tablas()'::text;
    END IF;
    IF to_regclass('public.historial_cambios') IS NOT NULL THEN
      v_fallas := v_fallas || 'C4 · historial_cambios sigue existiendo'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C4 · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  -- Se relanza afuera del bloque que escribió. Con ensayo.continuar = '1' el
  -- OK sale como NOTICE: el bloque ya se revirtió y quien encadena el ensayo
  -- cierra la transacción con su propio error.
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  IF v_t LIKE 'ENSAYO OK%' AND current_setting('ensayo.continuar', true) = '1' THEN
    RAISE NOTICE '%', v_t;
  ELSE
    RAISE EXCEPTION '%', v_t;
  END IF;
 END;
END
$ensayo$;
