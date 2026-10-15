-- Ensayo de #1182 y #1183 (mig 378): el que reparte ve el cliente sin poder
-- operarlo, y sólo quien actúa como preventista tiene clientes asignados.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia de
-- audit_logs, notificaciones, pedido_historial y cliente_preventistas): un
-- único DO que termina SIEMPRE en una excepción, y cada caso corre en su propio
-- sub-bloque que se revierte. Los fixtures van como postgres sin claims, con
-- los triggers prendidos (session_replication_role no se puede tocar en
-- Supabase): pedidos_proteger_columnas y pedidos_vb_por_rpc salen por
-- current_user y cliente_preventistas_no_ajeno por auth.uid() IS NULL. Cada caso
-- corre con los claims del usuario, el header x-sucursal-id y SET LOCAL ROLE
-- authenticated; las consultas van por EXECUTE para que el plan no se cachee
-- con otro rol. Si un fixture no queda, el caso falla: nunca se saltea.
--
-- Usuarios, elegidos por consulta (el ensayo falla si falta alguno): una
-- sucursal activa S con un transportista base activo sin ningún extra (T), un
-- preventista base activo con extra transportista en S (PXT), otro preventista
-- activo de S (PX, distinto de PXT), un encargado (ENC) y un admin (ADM), los
-- cinco en S; otro preventista activo cualquiera (O, distinto de PXT y PX), y
-- un preventista base sin extra (PB) en la sucursal activa SB con más clientes
-- que tenga un huérfano (HB). M, para medir, es un preventista base sin extra
-- de la sucursal con más clientes (el de más pedidos).
-- Pedido P de S, no VB (de preferencia entregado y sin pagos, para que el
-- fixture VB de C5 sólo cambie el comprobante), cuyo cliente C es activo, no reservado, tiene
-- coordenadas que no comparte con otro cliente de S, y ningún pedido suyo es de
-- PXT ni de PX (ni como vendedor ni como transportista). Fixture base: C
-- asignado a O y P con transportista_id = PXT. H es un huérfano activo no
-- reservado de S (distinto de C), C9 otro cliente de S y Z una zona de S.
--
--   C1  · PXT ve C (count = 1)
--   C1b · PXT: JOIN pedido P → cliente C (count = 1; el embed de la hoja de ruta)
--   C2  · PXT: obtener_resumen_cuenta_cliente(C) → ok
--   C3  · PXT: verificar_duplicado_cliente en las coordenadas de C →
--         cliente_visible.id = C
--   C4  · PX (no reparte P) no ve C → 0, y el resumen → 42501 (regresión)
--   C5  · P pasa a VB (saldado) → PXT no ve C (0), resumen → 42501 y
--         verificar_duplicado_cliente sin cliente_visible. OJO: el filtro VB de la
--         policy es defensa en profundidad (la RLS de pedidos ya le oculta el VB
--         al transportista, así que el count = 0 sale igual sin él); los filtros VB
--         que C5 muerde de verdad son los de los espejos DEFINER, que no pasan por
--         esa RLS.
--   C6  · C reservado y sin asignar, P repartido por PXT → PXT ve C (1)
--   C8  · PXT hace UPDATE de C → 0 filas (ver no es operar)
--   D1  · T se asigna H → 42501 'Sólo un preventista puede tener clientes asignados…'
--   D2  · PB se asigna HB (en SB) → PASA
--   D3  · PXT se asigna H → PASA
--   D4  · PXT le asigna H a PX → 42501 'Solo un administrador…'
--   D4b · PXT le asigna H a T → 42501 'Solo un administrador…'
--   D5  · ENC se asigna H → 42501 'Sólo un preventista…' (cambio declarado de la 378)
--   D6  · ADM le asigna H a T → PASA
--   D7  · server, sin claims, le asigna H a T → PASA (el fixture C_T de la 1179)
--   D8  · T con el extra 'preventista' en S se asigna H → PASA (levanta
--         perfil_roles_rol_check en el sub-bloque, lock_timeout 2s)
--   D9  · Z con dueño PX; ENC le cambia la zona a C9 → C9 queda asignado a PX
--         (el INSERT de trg_clientes_zona_asigna_duenio va a depth 2 y sale antes)
--   D10 · ADM: asignar_preventista_zona(Z, PX) → pasa y los clientes no
--         reservados de Z quedan de PX
--   T1  · rendimiento: count(*) de clientes como M, mínimo de 4 corridas con la
--         policy vigente y con la vieja (md5 c2d80685…, se pone en un sub-bloque
--         que se revierte). Falla si la vigente > vieja × 1,25 + 10 ms.
--   K   · estructural: md5 de la qual de mt_clientes_select, una sobrecarga de
--         cada espejo y del trigger, DEFINER, ACL, enganche del trigger, ramas de
--         reparto en los espejos, el trigger llama a _actua_como_preventista y el
--         COMMENT de perfil_roles_rol_check ya no tiene el pendiente de #1183.
--
-- Sin la migración tiene que FALLAR en C1, C1b, C2, C3, C6, D1, D5 y K (y pasar
-- en el resto; C5 pasa también sin ella: sólo muerde si a un espejo se le saca el VB). Con la migración (inline antes del DO) tiene que dar 'ENSAYO OK'.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLO …' con la lista de fallas, siempre
-- como excepción (el MCP de Supabase no muestra NOTICEs).
--
--   psql "$DATABASE_URL" -f scripts/test-cartera-chofer-y-asignacion-1182-1183.sql

DO $ensayo$
DECLARE
  v_suc     bigint;
  v_tr      uuid;
  v_pxt     uuid;
  v_px      uuid;
  v_enc     uuid;
  v_adm     uuid;
  v_o       uuid;
  v_pb      uuid;
  v_suc_b   bigint;
  v_hb      bigint;
  v_m       uuid;
  v_suc_m   bigint;
  v_ped     bigint;
  v_cli     bigint;
  v_lat     numeric;
  v_lng     numeric;
  v_h       bigint;
  v_c9      bigint;
  v_z       bigint;
  v_res     text;
  v_t       text;
  v_j       jsonb;
  v_n       bigint;
  v_n2      bigint;
  v_nueva   numeric;
  v_vieja   numeric;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  SELECT s.id, tr.usuario_id, pxt.usuario_id, px.usuario_id, enc.usuario_id, adm.usuario_id
    INTO v_suc, v_tr, v_pxt, v_px, v_enc, v_adm
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
                   ORDER BY us.usuario_id LIMIT 1) px ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'encargado'
                   ORDER BY us.usuario_id LIMIT 1) enc ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con un transportista base sin extra, un preventista con extra transportista, otro preventista, un encargado y un admin, todos activos y de esa sucursal';
  END IF;
  SELECT id INTO v_o FROM perfiles
   WHERE activo AND rol = 'preventista' AND id <> v_pxt AND id <> v_px
   ORDER BY id LIMIT 1;
  SELECT pf.id, us.sucursal_id INTO v_pb, v_suc_b
    FROM perfiles pf
    JOIN usuario_sucursales us ON us.usuario_id = pf.id
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE pf.activo AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)
     AND EXISTS (SELECT 1 FROM clientes c WHERE c.sucursal_id = us.sucursal_id AND c.activo
                    AND NOT c.reservado_admin
                    AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id))
   ORDER BY (SELECT count(*) FROM clientes c WHERE c.sucursal_id = us.sucursal_id) DESC, pf.id
   LIMIT 1;
  SELECT pf.id, us.sucursal_id INTO v_m, v_suc_m
    FROM perfiles pf
    JOIN usuario_sucursales us ON us.usuario_id = pf.id
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE pf.activo AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = pf.id)
   ORDER BY (SELECT count(*) FROM clientes c WHERE c.sucursal_id = us.sucursal_id) DESC,
            (SELECT count(*) FROM pedidos pe WHERE pe.usuario_id = pf.id) DESC, pf.id
   LIMIT 1;
  IF v_o IS NULL OR v_pb IS NULL OR v_m IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita otro preventista (O), un preventista base sin extra con un huérfano en su sucursal (PB) y uno para medir (M): % % %', v_o, v_pb, v_m;
  END IF;

  -- --------------------------------------------------- pedidos y clientes ---
  SELECT pe.id, pe.cliente_id, c.latitud, c.longitud
    INTO v_ped, v_cli, v_lat, v_lng
    FROM pedidos pe
    JOIN clientes c ON c.id = pe.cliente_id
   WHERE pe.sucursal_id = v_suc
     AND pe.tipo_factura IS DISTINCT FROM 'VB'
     AND c.activo AND NOT c.reservado_admin
     AND c.latitud IS NOT NULL AND c.longitud IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pedidos p2 WHERE p2.cliente_id = c.id
                        AND (p2.usuario_id IN (v_pxt, v_px) OR p2.transportista_id IN (v_pxt, v_px)))
     AND NOT EXISTS (SELECT 1 FROM clientes c2 WHERE c2.id <> c.id AND c2.sucursal_id = c.sucursal_id
                        AND c2.latitud = c.latitud AND c2.longitud = c.longitud)
   ORDER BY (pe.estado = 'entregado' AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.pedido_id = pe.id)) DESC,
            pe.id DESC
   LIMIT 1;
  SELECT c.id INTO v_h FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT c.reservado_admin AND c.id <> v_cli
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;
  SELECT c.id INTO v_c9 FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT c.reservado_admin
     AND c.id <> v_cli AND c.id <> v_h
   ORDER BY c.id LIMIT 1;
  SELECT z.id INTO v_z FROM zonas z WHERE z.sucursal_id = v_suc ORDER BY z.activo DESC, z.id LIMIT 1;
  SELECT c.id INTO v_hb FROM clientes c
   WHERE c.sucursal_id = v_suc_b AND c.activo AND NOT c.reservado_admin
     AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
   ORDER BY c.id LIMIT 1;
  IF v_ped IS NULL OR v_h IS NULL OR v_c9 IS NULL OR v_z IS NULL OR v_hb IS NULL THEN
    RAISE EXCEPTION 'faltan fixtures en la sucursal %: pedido % cliente % huérfano % C9 % zona % HB %',
      v_suc, v_ped, v_cli, v_h, v_c9, v_z, v_hb;
  END IF;

  v_notas := v_notas || format('suc %s, T %s, PXT %s, PX %s, ENC %s, ADM %s, O %s, PB %s (suc %s, HB %s), M %s (suc %s); pedido %s cliente %s, H %s, C9 %s, zona %s',
                               v_suc, left(v_tr::text, 8), left(v_pxt::text, 8), left(v_px::text, 8),
                               left(v_enc::text, 8), left(v_adm::text, 8), left(v_o::text, 8),
                               left(v_pb::text, 8), v_suc_b, v_hb, left(v_m::text, 8), v_suc_m,
                               v_ped, v_cli, v_h, v_c9, v_z);

  -- ---------------------------------------------------------------- helpers -
  -- Sesión de un usuario en una sucursal (NULL = postgres sin claims, como el
  -- server). Con usuario, además SET LOCAL ROLE authenticated.
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
  -- Un fixture: tiene que tocar exactamente una fila.
  CREATE OR REPLACE FUNCTION pg_temp.fix(p_sql text) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    IF v <> 1 THEN
      RAISE EXCEPTION 'fixture: % filas en %', v, p_sql;
    END IF;
  END $f$;
  -- Un número por EXECUTE (el plan no se cachea con otro rol).
  CREATE OR REPLACE FUNCTION pg_temp.n(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE p_sql INTO v;
    RETURN v;
  END $f$;
  -- Una sentencia: 'PASA' o 'SQLSTATE mensaje'. Si pasa, el efecto queda hasta
  -- que se revierte el sub-bloque del caso.
  CREATE OR REPLACE FUNCTION pg_temp.intenta(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN 'PASA';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Filas afectadas por una sentencia.
  CREATE OR REPLACE FUNCTION pg_temp.filas(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    RETURN v;
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
  -- Mínimo de 4 corridas (más una de calentamiento) de count(*) de clientes,
  -- en milisegundos. Corre con la sesión que esté puesta.
  CREATE OR REPLACE FUNCTION pg_temp.medir(OUT p_ms numeric, OUT p_filas bigint) LANGUAGE plpgsql AS $f$
  DECLARE v_t0 timestamptz; v_ms numeric;
  BEGIN
    EXECUTE 'SELECT count(*) FROM public.clientes' INTO p_filas;
    FOR i IN 1..4 LOOP
      v_t0 := clock_timestamp();
      EXECUTE 'SELECT count(*) FROM public.clientes' INTO p_filas;
      v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
      p_ms := LEAST(COALESCE(p_ms, v_ms), v_ms);
    END LOOP;
  END $f$;

  -- ---------------------------------------------------------- fixture base -
  -- C asignado a O (no es de PXT ni de PX) y P repartido por PXT.
  PERFORM pg_temp.como(NULL, NULL);
  DELETE FROM public.cliente_preventistas WHERE cliente_id = v_cli;
  INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cli, v_o);
  PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L WHERE id = %s', v_pxt, v_ped));

  -- ============================================================== #1182 ===
  -- C1 / C1b / C2 / C3 / C8 · PXT
  BEGIN
    PERFORM pg_temp.como(v_pxt, v_suc);
    v_n := pg_temp.n(format('SELECT count(*) FROM public.clientes WHERE id = %s', v_cli));
    IF v_n IS DISTINCT FROM 1 THEN
      v_fallas := v_fallas || format('C1 · PXT no ve el cliente del pedido que reparte (count %s, tenía que dar 1)', v_n);
    END IF;
    v_n := pg_temp.n(format('SELECT count(*) FROM public.pedidos pe JOIN public.clientes c ON c.id = pe.cliente_id WHERE pe.id = %s', v_ped));
    IF v_n IS DISTINCT FROM 1 THEN
      v_fallas := v_fallas || format('C1b · el JOIN pedido → cliente de PXT da %s (tenía que dar 1)', v_n);
    END IF;
    v_res := pg_temp.intenta(format('SELECT public.obtener_resumen_cuenta_cliente(%s)', v_cli));
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('C2 · obtener_resumen_cuenta_cliente como PXT no pasó: %s', v_res);
    END IF;
    BEGIN
      EXECUTE 'SELECT public.verificar_duplicado_cliente($1, $2, NULL, NULL)' INTO v_j USING v_lat, v_lng;
      IF (v_j -> 'cliente_visible' ->> 'id') IS DISTINCT FROM v_cli::text THEN
        v_fallas := v_fallas || format('C3 · verificar_duplicado_cliente como PXT no muestra el cliente %s: %s', v_cli, v_j);
      END IF;
      v_notas := v_notas || format('C3 · %s', v_j);
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || ('C3 · verificar_duplicado_cliente como PXT falló: ' || SQLSTATE || ' ' || SQLERRM);
    END;
    v_n := pg_temp.filas(format('UPDATE public.clientes SET notas = notas WHERE id = %s', v_cli));
    IF v_n IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('C8 · PXT actualizó el cliente que sólo ve por reparto (%s filas, tenía que dar 0)', v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C1-C3/C8 · error inesperado: ' || SQLERRM);
  END;

  -- C4 · PX no reparte P: sigue sin ver C (regresión)
  BEGIN
    PERFORM pg_temp.como(v_px, v_suc);
    v_n := pg_temp.n(format('SELECT count(*) FROM public.clientes WHERE id = %s', v_cli));
    IF v_n IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('C4 · PX ve un cliente ajeno de un pedido que reparte otro (count %s, tenía que dar 0)', v_n);
    END IF;
    v_res := pg_temp.intenta(format('SELECT public.obtener_resumen_cuenta_cliente(%s)', v_cli));
    IF COALESCE(v_res, '') NOT LIKE '42501 %' THEN
      v_fallas := v_fallas || format('C4 · el resumen de un cliente ajeno como PX no dio 42501: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C4 · error inesperado: ' || SQLERRM);
  END;

  -- C5 · el pedido VB no da vista (el SET nombra total y monto_pagado: los
  -- triggers BEFORE dejan el VB saldado)
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET tipo_factura = ''VB'', total = total, monto_pagado = total WHERE id = %s', v_ped));
    PERFORM pg_temp.como(v_pxt, v_suc);
    v_n := pg_temp.n(format('SELECT count(*) FROM public.clientes WHERE id = %s', v_cli));
    IF v_n IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('C5 · PXT ve el cliente por un pedido VB que reparte (count %s, tenía que dar 0)', v_n);
    END IF;
    v_res := pg_temp.intenta(format('SELECT public.obtener_resumen_cuenta_cliente(%s)', v_cli));
    IF COALESCE(v_res, '') NOT LIKE '42501 %' THEN
      v_fallas := v_fallas || format('C5 · el resumen por un pedido VB como PXT no dio 42501: %s', v_res);
    END IF;
    BEGIN
      EXECUTE 'SELECT public.verificar_duplicado_cliente($1, $2, NULL, NULL)' INTO v_j USING v_lat, v_lng;
      IF (v_j -> 'cliente_visible') IS NOT NULL AND (v_j -> 'cliente_visible') <> 'null'::jsonb THEN
        v_fallas := v_fallas || format('C5 · verificar_duplicado_cliente como PXT muestra el cliente por un pedido VB que reparte: %s', v_j);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || ('C5 · verificar_duplicado_cliente como PXT falló: ' || SQLSTATE || ' ' || SQLERRM);
    END;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C5 · error inesperado: ' || SQLERRM);
  END;

  -- C6 · cliente reservado y sin asignar, pedido repartido por PXT
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    DELETE FROM public.cliente_preventistas WHERE cliente_id = v_cli;
    PERFORM pg_temp.fix(format('UPDATE public.clientes SET reservado_admin = true WHERE id = %s', v_cli));
    PERFORM pg_temp.como(v_pxt, v_suc);
    v_n := pg_temp.n(format('SELECT count(*) FROM public.clientes WHERE id = %s', v_cli));
    IF v_n IS DISTINCT FROM 1 THEN
      v_fallas := v_fallas || format('C6 · PXT no ve el cliente reservado del pedido que reparte (count %s, tenía que dar 1)', v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C6 · error inesperado: ' || SQLERRM);
  END;

  -- ============================================================== #1183 ===
  -- D1 · T se asigna un huérfano
  BEGIN
    PERFORM pg_temp.como(v_tr, v_suc);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_tr));
    v_notas := v_notas || ('D1 · ' || v_res);
    IF COALESCE(v_res, '') NOT LIKE '42501 Sólo un preventista puede tener clientes asignados%' THEN
      v_fallas := v_fallas || format('D1 · T se asignó un huérfano o lo frenó otra cosa (tenía que dar 42501 ''Sólo un preventista…''): %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D1 · error inesperado: ' || SQLERRM);
  END;

  -- D2 · PB se asigna un huérfano de su sucursal
  BEGIN
    PERFORM pg_temp.como(v_pb, v_suc_b);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_hb, v_pb));
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('D2 · PB no pudo asignarse un huérfano: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D2 · error inesperado: ' || SQLERRM);
  END;

  -- D3 · PXT se asigna un huérfano
  BEGIN
    PERFORM pg_temp.como(v_pxt, v_suc);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_pxt));
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('D3 · PXT no pudo asignarse un huérfano: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D3 · error inesperado: ' || SQLERRM);
  END;

  -- D4 / D4b · PXT le asigna un huérfano a otro (PX, y T)
  BEGIN
    PERFORM pg_temp.como(v_pxt, v_suc);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_px));
    IF COALESCE(v_res, '') NOT LIKE '42501 Solo un administrador puede asignarle un cliente a otro preventista%' THEN
      v_fallas := v_fallas || format('D4 · PXT le asignó un huérfano a PX o lo frenó otra cosa: %s', v_res);
    END IF;
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_tr));
    v_notas := v_notas || ('D4b · ' || v_res);
    IF COALESCE(v_res, '') NOT LIKE '42501 Solo un administrador puede asignarle un cliente a otro preventista%' THEN
      v_fallas := v_fallas || format('D4b · PXT le asignó un huérfano a T o lo frenó otra cosa: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D4 · error inesperado: ' || SQLERRM);
  END;

  -- D5 · el encargado ya no se autoasigna (cambio declarado de la 378)
  BEGIN
    PERFORM pg_temp.como(v_enc, v_suc);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_enc));
    v_notas := v_notas || ('D5 · ' || v_res);
    IF COALESCE(v_res, '') NOT LIKE '42501 Sólo un preventista puede tener clientes asignados%' THEN
      v_fallas := v_fallas || format('D5 · ENC se autoasignó un huérfano o lo frenó otra cosa (tenía que dar 42501 ''Sólo un preventista…''): %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D5 · error inesperado: ' || SQLERRM);
  END;

  -- D6 · el admin sigue sin restricción
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_tr));
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('D6 · ADM no pudo asignarle un huérfano a T: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D6 · error inesperado: ' || SQLERRM);
  END;

  -- D7 · el server (sin claims) sigue sin restricción
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_tr));
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('D7 · el server no pudo asignarle un huérfano a T: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D7 · error inesperado: ' || SQLERRM);
  END;

  -- D8 · T con el extra 'preventista' en S se asigna un huérfano
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM pg_temp.extra(-911891, v_tr, v_suc);
    PERFORM pg_temp.como(v_tr, v_suc);
    v_res := pg_temp.intenta(format('INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (%s, %L)', v_h, v_tr));
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('D8 · T con el extra preventista no pudo asignarse un huérfano: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D8 · error inesperado: ' || SQLERRM);
  END;

  -- D9 · zona con dueño PX; ENC le cambia la zona a C9 → C9 pasa a PX (depth 2)
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    DELETE FROM public.preventista_zonas WHERE zona_id = v_z;
    INSERT INTO public.preventista_zonas (perfil_id, zona_id, sucursal_id) VALUES (v_px, v_z, v_suc);
    PERFORM pg_temp.fix(format('UPDATE public.clientes SET zona_id = NULL WHERE id = %s', v_c9));
    PERFORM pg_temp.como(v_enc, v_suc);
    v_res := pg_temp.intenta(format('UPDATE public.clientes SET zona_id = %s WHERE id = %s', v_z, v_c9));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('D9 · ENC no pudo cambiarle la zona a un cliente: %s', v_res);
    ELSIF (SELECT array_agg(cp.preventista_id) FROM public.cliente_preventistas cp WHERE cp.cliente_id = v_c9)
          IS DISTINCT FROM ARRAY[v_px] THEN
      v_fallas := v_fallas || format('D9 · el cambio de zona no dejó al cliente %s asignado sólo al dueño de la zona', v_c9);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D9 · error inesperado: ' || SQLERRM);
  END;

  -- D10 · asignar_preventista_zona como admin
  BEGIN
    PERFORM pg_temp.como(v_adm, v_suc);
    v_res := pg_temp.intenta(format('SELECT public.asignar_preventista_zona(%s, %L, false)', v_z, v_px));
    PERFORM pg_temp.como(NULL, NULL);
    IF v_res IS DISTINCT FROM 'PASA' THEN
      v_fallas := v_fallas || format('D10 · asignar_preventista_zona como ADM falló: %s', v_res);
    ELSIF EXISTS (SELECT 1 FROM public.clientes c WHERE c.zona_id = v_z AND NOT c.reservado_admin
                     AND (NOT EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                                       WHERE cp.cliente_id = c.id AND cp.preventista_id = v_px)
                          OR EXISTS (SELECT 1 FROM public.cliente_preventistas cp
                                      WHERE cp.cliente_id = c.id AND cp.preventista_id <> v_px))) THEN
      v_fallas := v_fallas || format('D10 · después de asignar_preventista_zona quedan clientes de la zona %s que no son sólo de PX', v_z);
    END IF;
    v_notas := v_notas || format('D10 · clientes en la zona %s: %s', v_z,
                                 (SELECT count(*) FROM public.clientes c WHERE c.zona_id = v_z));
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D10 · error inesperado: ' || SQLERRM);
  END;

  -- ========================================================= rendimiento ===
  -- T1 · policy vigente contra la vieja (la de la 377), como M
  BEGIN
    PERFORM pg_temp.como(v_m, v_suc_m);
    SELECT p_ms, p_filas INTO v_nueva, v_n FROM pg_temp.medir();
    PERFORM pg_temp.como(NULL, NULL);
    PERFORM set_config('lock_timeout', '2s', true);
    EXECUTE $pol$
      ALTER POLICY mt_clientes_select ON public.clientes
        USING (
          sucursal_id = public.current_sucursal_id()
          AND (
            NOT EXISTS (
              SELECT 1 FROM public.perfiles p
              WHERE p.id = auth.uid() AND p.rol = 'preventista'
            )
            OR (
              (
                NOT EXISTS (
                  SELECT 1 FROM public.cliente_preventistas cp
                  WHERE cp.cliente_id = clientes.id
                )
                OR EXISTS (
                  SELECT 1 FROM public.cliente_preventistas cp
                  WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()
                )
              )
              AND NOT clientes.reservado_admin
            )
            OR EXISTS (
              SELECT 1 FROM public.pedidos pe
              WHERE pe.cliente_id = clientes.id AND pe.usuario_id = auth.uid()
            )
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.perfiles pd
            WHERE pd.id = auth.uid() AND pd.rol = 'deposito'
          )
        )
    $pol$;
    IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
           AND policyname = 'mt_clientes_select') IS DISTINCT FROM 'c2d80685d0b68199da4c855b352a9737' THEN
      v_fallas := v_fallas || 'T1 · la policy vieja reconstruida no da el md5 c2d80685… (la comparación no vale)'::text;
    END IF;
    PERFORM pg_temp.como(v_m, v_suc_m);
    SELECT p_ms, p_filas INTO v_vieja, v_n2 FROM pg_temp.medir();
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('T1 · error inesperado: ' || SQLERRM);
  END;
  IF v_nueva IS NOT NULL AND v_vieja IS NOT NULL THEN
    v_notas := v_notas || format('T1 · M ve %s filas con la vigente en %s ms y %s con la vieja en %s ms (mínimo de 4)',
                                 v_n, round(v_nueva, 1), v_n2, round(v_vieja, 1));
    IF v_nueva > v_vieja * 1.25 + 10 THEN
      v_fallas := v_fallas || format('T1 · la policy vigente tarda %s ms contra %s ms de la vieja (límite vieja × 1,25 + 10 ms)',
                                     round(v_nueva, 1), round(v_vieja, 1));
    END IF;
  END IF;

  -- ========================================================== estructural ===
  -- K
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
           AND policyname = 'mt_clientes_select') IS DISTINCT FROM 'c9a4aff2b69aabdb09bb712f66a05b55' THEN
      v_fallas := v_fallas || 'K · la qual de mt_clientes_select no es la de la 379 (md5 c9a4aff2…)'::text;
    END IF;
    IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
           AND proname IN ('obtener_resumen_cuenta_cliente', 'verificar_duplicado_cliente', 'cliente_preventistas_no_ajeno')) <> 3 THEN
      v_fallas := v_fallas || 'K · hay más de una sobrecarga de un espejo o del trigger'::text;
    END IF;
    FOREACH v_t IN ARRAY ARRAY['public.obtener_resumen_cuenta_cliente(integer)',
                               'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)'] LOOP
      IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_t::regprocedure) THEN
        v_fallas := v_fallas || format('K · %s dejó de ser SECURITY DEFINER', v_t);
      END IF;
      IF has_function_privilege('anon', v_t::regprocedure, 'EXECUTE')
         OR NOT has_function_privilege('authenticated', v_t::regprocedure, 'EXECUTE') THEN
        v_fallas := v_fallas || format('K · %s: EXECUTE para anon o sin EXECUTE para authenticated', v_t);
      END IF;
    END LOOP;
    IF position('transportista_id = auth.uid()' IN pg_get_functiondef('public.obtener_resumen_cuenta_cliente(integer)'::regprocedure)) = 0 THEN
      v_fallas := v_fallas || 'K · obtener_resumen_cuenta_cliente no tiene la rama de reparto'::text;
    END IF;
    IF position('transportista_id = v_uid' IN pg_get_functiondef('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)'::regprocedure)) = 0 THEN
      v_fallas := v_fallas || 'K · verificar_duplicado_cliente no tiene la rama de reparto'::text;
    END IF;
    v_t := 'public.cliente_preventistas_no_ajeno()';
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_t::regprocedure) THEN
      v_fallas := v_fallas || 'K · cliente_preventistas_no_ajeno dejó de ser SECURITY DEFINER'::text;
    END IF;
    IF position('_actua_como_preventista' IN (SELECT prosrc FROM pg_proc WHERE oid = v_t::regprocedure)) = 0 THEN
      v_fallas := v_fallas || 'K · cliente_preventistas_no_ajeno no llama a _actua_como_preventista'::text;
    END IF;
    IF has_function_privilege('public', v_t::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', v_t::regprocedure, 'EXECUTE')
       OR has_function_privilege('authenticated', v_t::regprocedure, 'EXECUTE') THEN
      v_fallas := v_fallas || 'K · cliente_preventistas_no_ajeno es alcanzable por PUBLIC, anon o authenticated'::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.cliente_preventistas'::regclass
                      AND tgname = 'trg_cliente_preventistas_no_ajeno' AND tgenabled = 'O'
                      AND tgfoid = v_t::regprocedure) THEN
      v_fallas := v_fallas || 'K · trg_cliente_preventistas_no_ajeno no está enganchado y habilitado'::text;
    END IF;
    IF position('Pendiente aparte' IN COALESCE(obj_description(
         (SELECT oid FROM pg_constraint WHERE conname = 'perfil_roles_rol_check'
            AND conrelid = 'public.perfil_roles'::regclass), 'pg_constraint'), '')) > 0 THEN
      v_fallas := v_fallas || 'K · el COMMENT de perfil_roles_rol_check sigue con el pendiente de #1183'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K · error inesperado: ' || SQLERRM);
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
