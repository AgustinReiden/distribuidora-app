-- Ensayo de #1179: los triggers BEFORE INSERT de pedidos (reservado y cartera)
-- tratan como preventista a quien tiene el preventista como rol extra en la
-- sucursal del pedido, con el helper _actua_como_preventista(uuid, sucursal).
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia de
-- audit_logs y pedido_historial): un único DO que termina SIEMPRE en una
-- excepción, y cada caso corre en su propio sub-bloque que se revierte. Los
-- pedidos y las filas de perfil_roles van con id explícito negativo, para no
-- consumir sus secuencias. El rol extra 'preventista' no entra por el CHECK:
-- cada sub-bloque que lo necesita levanta perfil_roles_rol_check (lock_timeout
-- 2s) y se revierte con él.
--
-- Los pedidos se insertan como postgres (pedidos_proteger_columnas y
-- pedidos_vb_por_rpc salen por current_user), así que el rol lo deciden sólo
-- los dos triggers. Por defecto sin claims: v_autor sale de creado_por, como en
-- el bot. A1s pone los claims de T y creado_por NULL, para que v_autor salga de
-- auth.uid(), como en la app. Las asignaciones de cliente_preventistas van sin
-- claims (el trigger no_ajeno sale por auth.uid() IS NULL). Si un fixture no
-- queda, el caso falla: nunca se saltea.
--
-- Usuarios, elegidos por consulta (el ensayo falla si falta alguno): una
-- sucursal activa S con un transportista base activo sin ningún extra (T), un
-- preventista base activo con extra transportista en S (PXT) y otro preventista
-- base activo (PX, distinto de PXT), los tres en S; un admin (ADM), un encargado
-- (ENC) y un preventista base sin extra (PB, distinto de PX) de cualquier
-- sucursal: ni los triggers ni el helper miran la pertenencia. S2 es otra
-- sucursal cualquiera. Clientes de S, activos, huérfanos y no reservados:
-- C_lib, C_res (se reserva en el sub-bloque), C_otro (se asigna a PX) y C_T (se
-- asigna a T).
--
--   R1  · T con extra, pedido para C_res → 42501 'reservado a administración'
--   R2  · T sin extra, pedido para C_res → OK
--   A1  · T con extra, pedido para C_otro → 42501 'Cliente asignado a otro
--         preventista' (camino del bot: v_autor = creado_por)
--   A1s · ídem con los claims de T y creado_por NULL (camino de la app:
--         v_autor = auth.uid()) → 42501 del mismo trigger
--   A2  · T con extra, pedido para C_T (asignado a T) → OK
--   A3  · PB, pedido para C_otro → 42501 (regresión)
--   A3b · PXT, pedido para C_otro → 42501 (regresión, la población real)
--   A3h · _actua_como_preventista(PXT, S) = true
--   A4  · ADM y ENC como autores, pedido para C_otro y para C_res → OK
--   A5  · T con el extra en S2, pedido en S para C_otro → OK (el extra es por
--         sucursal)
--   H1  · helper: (T,S) true con extra y false sin extra; (PX,S) true; (ADM,S)
--         false aunque tenga un extra insertado; (ENC,S) false
--   H2  · con el extra de T en S, (T,S2) false
--   K1  · estructural: el helper (una sobrecarga, INVOKER, sin EXECUTE para
--         PUBLIC/anon/authenticated), los cuerpos de los triggers, su ACL y su
--         enganche, la qual de mt_clientes_select (la de la 379, md5 c9a4aff2…)
--         y el CHECK sin cambios
--
-- Sin la migración tiene que FALLAR en R1, A1, A1s, A3h, H1, H2 y K1 (los
-- últimos cuatro por la función inexistente), y pasar en R2, A2, A3, A3b, A4 y
-- A5. Con la migración (inline antes del DO) tiene que dar 'ENSAYO OK'.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLO …' con la lista de fallas, siempre
-- como excepción (el MCP de Supabase no muestra NOTICEs).
--
--   psql "$DATABASE_URL" -f scripts/test-rol-preventista-extra-1179.sql

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_suc2    bigint;
  v_tr      uuid;
  v_px      uuid;
  v_pxt     uuid;
  v_adm     uuid;
  v_enc     uuid;
  v_pb      uuid;
  v_cli_lib bigint;
  v_cli_res bigint;
  v_cli_otr bigint;
  v_cli_t   bigint;
  v_res     text;
  v_t       text;
  v_u       uuid;
  v_c       bigint;
  v_i       int := 0;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, tr.usuario_id, pxt.usuario_id, px.usuario_id
    INTO v_suc, v_tr, v_pxt, v_px
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)
                   ORDER BY us.usuario_id LIMIT 1) tr ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista'
                     AND EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id
                                    AND pr.sucursal_id = s.id AND pr.rol = 'transportista')
                   ORDER BY us.usuario_id LIMIT 1) pxt ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista'
                     AND pf.id <> pxt.usuario_id
                   ORDER BY (EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)), us.usuario_id
                   LIMIT 1) px ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con un transportista base sin extra, un preventista con extra transportista y otro preventista base, todos activos';
  END IF;
  SELECT id INTO v_suc2 FROM sucursales WHERE id <> v_suc ORDER BY activa DESC, id LIMIT 1;
  SELECT id INTO v_adm FROM perfiles WHERE activo AND rol = 'admin' ORDER BY id LIMIT 1;
  SELECT id INTO v_enc FROM perfiles WHERE activo AND rol = 'encargado' ORDER BY id LIMIT 1;
  SELECT pf.id INTO v_pb FROM perfiles pf
   WHERE pf.activo AND pf.rol = 'preventista' AND pf.id <> v_px AND pf.id <> v_pxt
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)
   ORDER BY pf.id LIMIT 1;
  IF v_adm IS NULL OR v_enc IS NULL OR v_pb IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un admin, un encargado y un preventista sin extra (distinto de PX), activos: % % %', v_adm, v_enc, v_pb;
  END IF;

  -- --------------------------------------------------------------- clientes -
  SELECT max(id) FILTER (WHERE rn = 1), max(id) FILTER (WHERE rn = 2),
         max(id) FILTER (WHERE rn = 3), max(id) FILTER (WHERE rn = 4)
    INTO v_cli_lib, v_cli_res, v_cli_otr, v_cli_t
    FROM (SELECT c.id, row_number() OVER (ORDER BY c.id) rn FROM clientes c
           WHERE c.sucursal_id = v_suc AND c.activo AND NOT c.reservado_admin
             AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)) x
   WHERE rn <= 4;
  IF v_cli_lib IS NULL OR v_cli_res IS NULL OR v_cli_otr IS NULL OR v_cli_t IS NULL THEN
    RAISE EXCEPTION 'faltan clientes huérfanos en la sucursal %: % % % %', v_suc, v_cli_lib, v_cli_res, v_cli_otr, v_cli_t;
  END IF;

  v_notas := v_notas || format('suc %s (S2 %s), T %s, PXT %s, PX %s, PB %s, ADM %s, ENC %s; clientes lib %s, res %s, otro %s, T %s',
                               v_suc, v_suc2, left(v_tr::text, 8), left(v_pxt::text, 8), left(v_px::text, 8),
                               left(v_pb::text, 8), left(v_adm::text, 8), left(v_enc::text, 8),
                               v_cli_lib, v_cli_res, v_cli_otr, v_cli_t);

  -- ---------------------------------------------------------------- helpers -
  -- Claims de un usuario (NULL = sin claims, como el bot con service_role).
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
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
  -- Asignación de un cliente sin claims (el trigger no_ajeno sale por auth.uid() IS NULL).
  CREATE OR REPLACE FUNCTION pg_temp.asignar(p_cli bigint, p_prev uuid) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v_claims text := current_setting('request.jwt.claims', true);
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (p_cli, p_prev);
    PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
    IF NOT EXISTS (SELECT 1 FROM public.cliente_preventistas WHERE cliente_id = p_cli AND preventista_id = p_prev) THEN
      RAISE EXCEPTION 'fixture: no quedó la asignación del cliente % a %', p_cli, p_prev;
    END IF;
  END $f$;
  -- El rol extra 'preventista' (levanta el CHECK en la transacción del sub-bloque).
  CREATE OR REPLACE FUNCTION pg_temp.extra(p_id bigint, p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('lock_timeout', '2s', true);
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.perfil_roles'::regclass
                  AND conname = 'perfil_roles_rol_check') THEN
      EXECUTE 'ALTER TABLE public.perfil_roles DROP CONSTRAINT perfil_roles_rol_check';
    END IF;
    INSERT INTO public.perfil_roles (id, usuario_id, sucursal_id, rol) OVERRIDING SYSTEM VALUE
    VALUES (p_id, p_uid, p_suc, 'preventista');
  END $f$;
  -- Un pedido como postgres: 'OK' o 'SQLSTATE mensaje'. Se revierte solo si falla.
  CREATE OR REPLACE FUNCTION pg_temp.pedido(p_id bigint, p_cli bigint, p_suc bigint, p_usuario uuid, p_creado uuid)
  RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    INSERT INTO public.pedidos (id, cliente_id, sucursal_id, total, estado, usuario_id, creado_por)
    VALUES (p_id, p_cli, p_suc, 0, 'pendiente', p_usuario, p_creado);
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- El helper, por EXECUTE: sin la migración no existe y el sub-bloque lo
  -- cuenta como falla.
  CREATE OR REPLACE FUNCTION pg_temp.actua(p_uid uuid, p_suc bigint) RETURNS boolean LANGUAGE plpgsql AS $f$
  DECLARE v boolean;
  BEGIN
    EXECUTE 'SELECT public._actua_como_preventista($1, $2)' INTO v USING p_uid, p_suc;
    RETURN v;
  END $f$;

  -- ============================================================ reservado ===
  -- R1 · T con extra, pedido para un reservado
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.fix(format('UPDATE public.clientes SET reservado_admin = true WHERE id = %s', v_cli_res));
    PERFORM pg_temp.extra(-911791, v_tr, v_suc);
    v_res := pg_temp.pedido(-911701, v_cli_res, v_suc, v_tr, v_tr);
    IF COALESCE(v_res, '') NOT LIKE '42501 %reservado a administración%' THEN
      v_fallas := v_fallas || format('R1 · T con extra preventista cargó un pedido para un reservado (tenía que dar 42501): %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R1 · error inesperado: ' || SQLERRM);
  END;

  -- R2 · T sin extra, pedido para un reservado
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.fix(format('UPDATE public.clientes SET reservado_admin = true WHERE id = %s', v_cli_res));
    v_res := pg_temp.pedido(-911702, v_cli_res, v_suc, v_tr, v_tr);
    IF v_res IS DISTINCT FROM 'OK' THEN
      v_fallas := v_fallas || format('R2 · T sin extra no cargó un pedido para un reservado: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R2 · error inesperado: ' || SQLERRM);
  END;

  -- ============================================================== cartera ===
  -- A1 · T con extra, cliente de otro preventista (camino del bot)
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.asignar(v_cli_otr, v_px);
    PERFORM pg_temp.extra(-911791, v_tr, v_suc);
    v_res := pg_temp.pedido(-911703, v_cli_otr, v_suc, v_tr, v_tr);
    IF COALESCE(v_res, '') NOT LIKE '42501 Cliente asignado a otro preventista%' THEN
      v_fallas := v_fallas || format('A1 · T con extra preventista cargó un pedido para un cliente ajeno (tenía que dar 42501): %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A1 · error inesperado: ' || SQLERRM);
  END;

  -- A1s · ídem por auth.uid() (camino de la app)
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.asignar(v_cli_otr, v_px);
    PERFORM pg_temp.extra(-911791, v_tr, v_suc);
    PERFORM pg_temp.como(v_tr, v_suc);
    v_res := pg_temp.pedido(-911704, v_cli_otr, v_suc, v_tr, NULL);
    PERFORM pg_temp.como(NULL, NULL);
    IF COALESCE(v_res, '') NOT LIKE '42501 Cliente asignado a otro preventista%' THEN
      v_fallas := v_fallas || format('A1s · T con extra preventista (por auth.uid()) cargó un pedido para un cliente ajeno o lo frenó otra cosa (tenía que dar el 42501 de la cartera): %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A1s · error inesperado: ' || SQLERRM);
  END;

  -- A2 · T con extra, cliente asignado a T
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.asignar(v_cli_t, v_tr);
    PERFORM pg_temp.extra(-911791, v_tr, v_suc);
    v_res := pg_temp.pedido(-911705, v_cli_t, v_suc, v_tr, v_tr);
    IF v_res IS DISTINCT FROM 'OK' THEN
      v_fallas := v_fallas || format('A2 · T con extra no cargó un pedido para su cliente: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A2 · error inesperado: ' || SQLERRM);
  END;

  -- A3 / A3b · regresión: preventistas base con un cliente ajeno
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.asignar(v_cli_otr, v_px);
    v_res := pg_temp.pedido(-911706, v_cli_otr, v_suc, v_pb, v_pb);
    IF COALESCE(v_res, '') NOT LIKE '42501 Cliente asignado a otro preventista%' THEN
      v_fallas := v_fallas || format('A3 · PB cargó un pedido para un cliente ajeno (tenía que dar 42501): %s', v_res);
    END IF;
    v_res := pg_temp.pedido(-911707, v_cli_otr, v_suc, v_pxt, v_pxt);
    IF COALESCE(v_res, '') NOT LIKE '42501 Cliente asignado a otro preventista%' THEN
      v_fallas := v_fallas || format('A3b · PXT cargó un pedido para un cliente ajeno (tenía que dar 42501): %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A3 · error inesperado: ' || SQLERRM);
  END;

  -- A3h · el helper con la población real
  BEGIN
    IF pg_temp.actua(v_pxt, v_suc) IS DISTINCT FROM true THEN
      v_fallas := v_fallas || 'A3h · _actua_como_preventista(PXT, S) no dio true'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A3h · error inesperado: ' || SQLERRM);
  END;

  -- A4 · admin y encargado no pasan por la cartera ni por el reservado
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.asignar(v_cli_otr, v_px);
    PERFORM pg_temp.fix(format('UPDATE public.clientes SET reservado_admin = true WHERE id = %s', v_cli_res));
    FOREACH v_u IN ARRAY ARRAY[v_adm, v_enc] LOOP
      FOREACH v_c IN ARRAY ARRAY[v_cli_otr, v_cli_res] LOOP
        v_i := v_i + 1;
        v_res := pg_temp.pedido(-911710 - v_i, v_c, v_suc, v_u, v_u);
        IF v_res IS DISTINCT FROM 'OK' THEN
          v_fallas := v_fallas || format('A4 · %s no cargó un pedido para el cliente %s: %s',
                                         CASE WHEN v_u = v_adm THEN 'ADM' ELSE 'ENC' END, v_c, v_res);
        END IF;
      END LOOP;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A4 · error inesperado: ' || SQLERRM);
  END;

  -- A5 · el extra es por sucursal
  IF v_suc2 IS NULL THEN
    v_notas := v_notas || 'A5/H2 · hay una sola sucursal: se omiten'::text;
  ELSE
    BEGIN
      PERFORM pg_temp.como(NULL, NULL);
      PERFORM pg_temp.asignar(v_cli_otr, v_px);
      PERFORM pg_temp.extra(-911792, v_tr, v_suc2);
      v_res := pg_temp.pedido(-911708, v_cli_otr, v_suc, v_tr, v_tr);
      IF v_res IS DISTINCT FROM 'OK' THEN
        v_fallas := v_fallas || format('A5 · el extra de T en otra sucursal lo frenó en S: %s', v_res);
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || ('A5 · error inesperado: ' || SQLERRM);
    END;
  END IF;

  -- =============================================================== helper ===
  -- H1 / H2
  BEGIN
    IF pg_temp.actua(v_tr, v_suc) IS DISTINCT FROM false THEN
      v_fallas := v_fallas || 'H1 · (T,S) sin extra no dio false'::text;
    END IF;
    IF pg_temp.actua(v_px, v_suc) IS DISTINCT FROM true THEN
      v_fallas := v_fallas || 'H1 · (PX,S) no dio true'::text;
    END IF;
    IF pg_temp.actua(v_enc, v_suc) IS DISTINCT FROM false THEN
      v_fallas := v_fallas || 'H1 · (ENC,S) no dio false'::text;
    END IF;
    PERFORM pg_temp.extra(-911791, v_tr, v_suc);
    PERFORM pg_temp.extra(-911793, v_adm, v_suc);
    PERFORM pg_temp.extra(-911794, v_enc, v_suc);
    IF pg_temp.actua(v_tr, v_suc) IS DISTINCT FROM true THEN
      v_fallas := v_fallas || 'H1 · (T,S) con extra no dio true'::text;
    END IF;
    IF pg_temp.actua(v_adm, v_suc) IS DISTINCT FROM false THEN
      v_fallas := v_fallas || 'H1 · (ADM,S) con un extra insertado no dio false'::text;
    END IF;
    IF pg_temp.actua(v_enc, v_suc) IS DISTINCT FROM false THEN
      v_fallas := v_fallas || 'H1 · (ENC,S) con un extra insertado no dio false'::text;
    END IF;
    IF v_suc2 IS NOT NULL AND pg_temp.actua(v_tr, v_suc2) IS DISTINCT FROM false THEN
      v_fallas := v_fallas || 'H2 · (T,S2) con el extra en S no dio false'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('H1/H2 · error inesperado: ' || SQLERRM);
  END;

  -- ========================================================== estructural ===
  -- K1
  BEGIN
    IF to_regprocedure('public._actua_como_preventista(uuid,bigint)') IS NULL THEN
      v_fallas := v_fallas || 'K1 · no existe _actua_como_preventista(uuid,bigint)'::text;
    ELSE
      IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
             AND proname = '_actua_como_preventista') <> 1 THEN
        v_fallas := v_fallas || 'K1 · hay más de una sobrecarga de _actua_como_preventista'::text;
      END IF;
      IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public._actua_como_preventista(uuid,bigint)'::regprocedure) THEN
        v_fallas := v_fallas || 'K1 · _actua_como_preventista es SECURITY DEFINER'::text;
      END IF;
      IF has_function_privilege('public', 'public._actua_como_preventista(uuid,bigint)', 'EXECUTE')
         OR has_function_privilege('anon', 'public._actua_como_preventista(uuid,bigint)', 'EXECUTE')
         OR has_function_privilege('authenticated', 'public._actua_como_preventista(uuid,bigint)', 'EXECUTE') THEN
        v_fallas := v_fallas || 'K1 · _actua_como_preventista es alcanzable por PUBLIC, anon o authenticated'::text;
      END IF;
    END IF;
    FOREACH v_t IN ARRAY ARRAY['pedidos_cliente_reservado', 'pedidos_cliente_asignado'] LOOP
      v_res := (SELECT prosrc FROM pg_proc WHERE oid = ('public.' || v_t || '()')::regprocedure);
      IF position('_actua_como_preventista' IN v_res) = 0
         OR position('p.rol = ''preventista''' IN v_res) > 0
         OR position('p.rol IN (''preventista'')' IN v_res) > 0 THEN
        v_fallas := v_fallas || format('K1 · %s no llama a _actua_como_preventista o sigue mirando p.rol crudo', v_t);
      END IF;
      IF has_function_privilege('anon', ('public.' || v_t || '()')::regprocedure, 'EXECUTE')
         OR has_function_privilege('authenticated', ('public.' || v_t || '()')::regprocedure, 'EXECUTE') THEN
        v_fallas := v_fallas || format('K1 · %s tiene EXECUTE para anon o authenticated', v_t);
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pedidos'::regclass
                        AND tgname = 'trg_' || v_t AND tgenabled = 'O') THEN
        v_fallas := v_fallas || format('K1 · trg_%s no está enganchado y habilitado', v_t);
      END IF;
    END LOOP;
    IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
           AND policyname = 'mt_clientes_select') IS DISTINCT FROM 'c9a4aff2b69aabdb09bb712f66a05b55' THEN
      v_fallas := v_fallas || 'K1 · la qual de mt_clientes_select no es la de la 379 (md5 c9a4aff2…)'::text;
    END IF;
    IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
         WHERE conrelid = 'public.perfil_roles'::regclass AND conname = 'perfil_roles_rol_check')
       IS DISTINCT FROM 'CHECK ((rol = ''transportista''::text))' THEN
      v_fallas := v_fallas || 'K1 · perfil_roles_rol_check cambió'::text;
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
