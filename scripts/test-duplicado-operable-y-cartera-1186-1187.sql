-- Ensayo de #1186 y #1187 (mig 379): el aviso a administración de
-- verificar_duplicado_cliente mira OPERAR, no ver, y mt_clientes_select compara
-- las ramas que dependen de la fila contra (SELECT auth.uid()).
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia de
-- audit_logs, notificaciones, pedido_historial y cliente_preventistas): un
-- único DO que termina SIEMPRE en una excepción, y cada caso corre en su propio
-- sub-bloque que se revierte. Los fixtures van como postgres sin claims, con
-- los triggers prendidos: pedidos_proteger_columnas sale por current_user y
-- cliente_preventistas_no_ajeno por auth.uid() IS NULL. Cada llamada a la RPC
-- corre con los claims del usuario, el header x-sucursal-id y SET LOCAL ROLE
-- authenticated; las consultas van por EXECUTE para que el plan no se cachee
-- con otro rol. Las notificaciones se cuentan como postgres (RESET ROLE). Si un
-- fixture no queda, el caso falla: nunca se saltea.
--
-- Usuarios y clientes, elegidos por consulta (el ensayo falla si falta alguno).
-- En prod ninguna sucursal tiene a la vez un preventista base sin extra y uno
-- con el extra transportista, así que hay dos escenarios:
--   B · SB, la sucursal activa con más clientes que tenga un preventista base
--       sin extra (PB, el de más pedidos). CB es un cliente activo no reservado
--       de SB, con coordenadas y un pedido no VB (PEDB), sin ningún cliente de
--       SB (activo o inactivo) a menos de 40 m, y sin pedidos de PB (ni como
--       vendedor ni como transportista).
--   X · SX, una sucursal activa con un preventista base con el extra
--       transportista en ella (PXT). CX y PEDX, como CB pero en SX y sin pedidos
--       de PXT.
--   O es otro preventista activo (de SB si hay). ADM es un admin de SB y ENC un
--   encargado de SB o, si no hay, de SX (se prueba con el C de su sucursal).
--   NB y NX son las notificaciones que tiene que generar un aviso en cada
--   sucursal: los admin y encargados activos que elige _notificar_sucursal_roles,
--   sin el que dispara (se afirma > 0). M, para medir, es un preventista base sin
--   extra de la sucursal con más clientes (el de más pedidos).
--
-- Todas las llamadas son verificar_duplicado_cliente(lat, lng, NULL, NULL): sin
-- dirección, así el vecino lo elige sólo la distancia y es C por construcción.
-- Antes de cada caso se borran (en el sub-bloque) las 'cliente_duplicado_oculto'
-- sobre C, para que la deduplicación de un día no tape el aviso. Cada caso
-- afirma que el vecino es C: cliente_visible.id = C o, si viene null, que no
-- hay notificaciones nuevas del caller sobre otro cliente.
--
--   E1 · historial: CB asignado a O y PEDB vendido por PB. PB en las
--        coordenadas de CB → bloquea, cliente_visible.id = CB y +NB con título
--        'Alta de cliente bloqueada por duplicado' y cierre 'revisalo.' (sin
--        'asignáselo')
--   E8 · deduplicación: repetir E1 en el mismo sub-bloque → +0
--   E2 · reparto: CX asignado a O y PEDX repartido por PXT (que nunca le
--        vendió). PXT llama → cliente_visible.id = CX y +NX
--   E3 · reservado con historial: CB reservado y sin asignar, PEDB vendido por
--        PB → cliente_visible.id = CB y +NB
--   E4 · propio: CB asignado a PB → cliente_visible.id = CB y +0
--   E5 · huérfano no reservado: CB sin asignar → cliente_visible.id = CB y +0
--   E6 · oculto (regresión de #543): CB asignado a O, sin pedidos de PB →
--        cliente_visible null y +NB, todas sobre CB
--   E7 · ADM y ENC en las coordenadas de un C asignado a O → +0 (v_es_prev
--        false)
--   E9 · distancia: CB asignado a O y PEDB vendido por PB; PB a unos 10 m de CB
--        (sobre la latitud) → no bloquea, avisa, cliente_visible.id = CB y +NB
--        con título 'Alta de cliente muy cerca de otro que no es de su cartera'
--   R1 · equivalencia: para cada preventista activo (perfiles.rol =
--        'preventista') y cada sucursal activa suya, el md5 de los ids de
--        clientes que ve con la policy vigente es el mismo que con la de la 378
--        (reconstruida en un sub-bloque, md5 f715c808…, lock_timeout 2s). Los
--        demás roles pasan por la rama NOT EXISTS de perfiles: idénticos por
--        construcción.
--   R2 · rendimiento: count(*) de clientes como M, mínimo de 4 corridas con la
--        vigente y con la de la 378 en el mismo sub-bloque. Falla si la vigente
--        > vieja × 0,75.
--   K  · estructural: md5 de la qual de mt_clientes_select (c9a4aff2…), y
--        verificar_duplicado_cliente decide el aviso por v_operable, conserva la
--        rama de reparto, tiene los textos nuevos, una sobrecarga, DEFINER, ACL y
--        el COMMENT nuevo. Anota el md5 de pg_get_functiondef.
--
-- Sin la migración tiene que FALLAR en E1, E2, E3, E9, R2 y K (y pasar en el
-- resto). Con la migración (inline antes del DO) tiene que dar 'ENSAYO OK'.
-- R2 depende de tiempos: con la base cargada puede dar un falso rojo, repetir
-- antes de diagnosticar. El sub-bloque de R1/R2 toma un lock exclusivo sobre
-- clientes mientras mide: correrlo fuera del horario de carga.
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLO …' con la lista de fallas, siempre
-- como excepción (el MCP de Supabase no muestra NOTICEs).
--
--   psql "$DATABASE_URL" -f scripts/test-duplicado-operable-y-cartera-1186-1187.sql

DO $ensayo$
DECLARE
  v_sb      bigint;
  v_pb      uuid;
  v_cb      bigint;
  v_pedb    bigint;
  v_latb    numeric;
  v_lngb    numeric;
  v_nb      bigint;
  v_sx      bigint;
  v_pxt     uuid;
  v_cx      bigint;
  v_pedx    bigint;
  v_latx    numeric;
  v_lngx    numeric;
  v_nx      bigint;
  v_o       uuid;
  v_adm     uuid;
  v_enc     uuid;
  v_suc_enc bigint;
  v_m       uuid;
  v_suc_m   bigint;
  v_j       jsonb;
  v_n0      bigint;
  v_n1      bigint;
  v_n2      bigint;
  v_t       text;
  v_u       uuid;
  v_s       bigint;
  v_vis     jsonb := '{}';
  v_dif     text[] := '{}';
  v_combos  int := 0;
  v_filas_n bigint;
  v_filas_v bigint;
  v_nueva   numeric;
  v_vieja   numeric;
  v_src     text;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
 BEGIN
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
  -- Un texto por EXECUTE (el plan no se cachea con otro rol).
  CREATE OR REPLACE FUNCTION pg_temp.t(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE p_sql INTO v;
    RETURN v;
  END $f$;
  -- Un cliente de la sucursal con coordenadas, activo y no reservado, con un
  -- pedido no VB, sin otro cliente de la sucursal (activo o inactivo) a menos de
  -- 40 m y sin pedidos de los usuarios excluidos (vendedor o transportista).
  CREATE OR REPLACE FUNCTION pg_temp.elegir_c(p_suc bigint, p_excl uuid[],
      OUT o_id bigint, OUT o_lat numeric, OUT o_lng numeric, OUT o_ped bigint) LANGUAGE sql AS $f$
    SELECT c.id, c.latitud, c.longitud, pe.id
      FROM public.clientes c
      JOIN LATERAL (SELECT pe.id FROM public.pedidos pe
                     WHERE pe.cliente_id = c.id AND pe.tipo_factura IS DISTINCT FROM 'VB'
                     ORDER BY (pe.estado = 'entregado') DESC, pe.id DESC LIMIT 1) pe ON true
     WHERE c.sucursal_id = p_suc AND c.activo AND NOT c.reservado_admin
       AND c.latitud IS NOT NULL AND c.longitud IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.pedidos p2 WHERE p2.cliente_id = c.id
                          AND (p2.usuario_id = ANY (p_excl) OR p2.transportista_id = ANY (p_excl)))
       AND NOT EXISTS (SELECT 1 FROM public.clientes c2
                        WHERE c2.id <> c.id AND c2.sucursal_id = c.sucursal_id
                          AND c2.latitud BETWEEN c.latitud - 0.001 AND c.latitud + 0.001
                          AND c2.longitud BETWEEN c.longitud - 0.001 AND c.longitud + 0.001
                          AND public.haversine_m(c.latitud, c.longitud, c2.latitud, c2.longitud) < 40)
     ORDER BY c.id DESC
     LIMIT 1
  $f$;
  -- Cuántas notificaciones genera un aviso: la misma selección que
  -- _notificar_sucursal_roles (admin y encargado activos, sin el que dispara).
  CREATE OR REPLACE FUNCTION pg_temp.n_aviso(p_suc bigint, p_uid uuid) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(DISTINCT us.usuario_id)
      FROM public.usuario_sucursales us
      JOIN public.perfiles p ON p.id = us.usuario_id
     WHERE us.sucursal_id = p_suc
       AND (CASE WHEN us.rol = 'mismo' THEN p.rol ELSE us.rol END) IN ('admin', 'encargado')
       AND p.activo IS NOT FALSE
       AND us.usuario_id <> p_uid
  $f$;
  -- Avisos sobre un cliente (como postgres).
  CREATE OR REPLACE FUNCTION pg_temp.avisos(p_c bigint) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(*) FROM public.notificaciones n
     WHERE n.tipo = 'cliente_duplicado_oculto' AND n.entidad_id = p_c
  $f$;
  -- Punto de partida de un caso sobre C (como postgres): sin asignar, sin
  -- avisos previos (la deduplicación es de un día por vecino).
  CREATE OR REPLACE FUNCTION pg_temp.base(p_c bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    DELETE FROM public.cliente_preventistas WHERE cliente_id = p_c;
    DELETE FROM public.notificaciones WHERE tipo = 'cliente_duplicado_oculto' AND entidad_id = p_c;
  END $f$;
  -- La RPC como un usuario; vuelve a postgres antes de devolver.
  CREATE OR REPLACE FUNCTION pg_temp.verificar(p_uid uuid, p_suc bigint, p_lat numeric, p_lng numeric)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE 'SELECT public.verificar_duplicado_cliente($1, $2, NULL, NULL)' INTO v USING p_lat, p_lng;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN v;
  END $f$;
  -- Las afirmaciones comunes de un caso. p_visible: si cliente_visible tiene
  -- que ser C (true) o null (false). p_titulo: si no es NULL y hubo avisos,
  -- el título que tienen que tener, y el cierre nuevo.
  CREATE OR REPLACE FUNCTION pg_temp.chequear(p_caso text, p_j jsonb, p_c bigint, p_uid uuid,
      p_delta bigint, p_esperado bigint, p_visible boolean, p_titulo text) RETURNS text[] LANGUAGE plpgsql AS $f$
  DECLARE r text[] := '{}'; v_otros bigint; v_mal text;
  BEGIN
    IF p_visible AND (p_j -> 'cliente_visible' ->> 'id') IS DISTINCT FROM p_c::text THEN
      r := r || format('%s · cliente_visible no es C (%s): %s', p_caso, p_c, p_j);
    ELSIF NOT p_visible AND p_j -> 'cliente_visible' IS NOT NULL AND p_j -> 'cliente_visible' <> 'null'::jsonb THEN
      r := r || format('%s · cliente_visible tenía que venir null: %s', p_caso, p_j);
    END IF;
    IF p_delta IS DISTINCT FROM p_esperado THEN
      r := r || format('%s · %s notificaciones nuevas sobre C (%s), tenían que ser %s', p_caso, p_delta, p_c, p_esperado);
    END IF;
    SELECT count(*) INTO v_otros FROM public.notificaciones n
     WHERE n.tipo = 'cliente_duplicado_oculto' AND n.created_at >= now()
       AND n.entidad_id IS DISTINCT FROM p_c AND n.payload ->> 'preventista_id' = p_uid::text;
    IF v_otros > 0 THEN
      r := r || format('%s · %s notificaciones nuevas sobre otro vecino que no es C', p_caso, v_otros);
    END IF;
    IF p_titulo IS NOT NULL AND p_delta > 0 THEN
      SELECT n.titulo || ' / …' || right(n.mensaje, 60) INTO v_mal FROM public.notificaciones n
       WHERE n.tipo = 'cliente_duplicado_oculto' AND n.entidad_id = p_c
         AND (n.titulo IS DISTINCT FROM p_titulo OR n.mensaje NOT LIKE '%revisalo.'
              OR n.mensaje LIKE '%asignáselo%')
       LIMIT 1;
      IF v_mal IS NOT NULL THEN
        r := r || format('%s · el aviso no tiene el título %L o el cierre ''revisalo.'': %s', p_caso, p_titulo, v_mal);
      END IF;
    END IF;
    RETURN r;
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

  -- ------------------------------------------------------------- personas ---
  SELECT pf.id, us.sucursal_id INTO v_pb, v_sb
    FROM public.perfiles pf
    JOIN public.usuario_sucursales us ON us.usuario_id = pf.id
    JOIN public.sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE pf.activo AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM public.perfil_roles pr WHERE pr.usuario_id = pf.id)
   ORDER BY (SELECT count(*) FROM public.clientes c WHERE c.sucursal_id = us.sucursal_id) DESC,
            (SELECT count(*) FROM public.pedidos pe WHERE pe.usuario_id = pf.id) DESC, pf.id
   LIMIT 1;
  SELECT pf.id, us.sucursal_id INTO v_pxt, v_sx
    FROM public.perfiles pf
    JOIN public.usuario_sucursales us ON us.usuario_id = pf.id
    JOIN public.sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE pf.activo AND pf.rol = 'preventista'
     AND EXISTS (SELECT 1 FROM public.perfil_roles pr WHERE pr.usuario_id = pf.id
                    AND pr.sucursal_id = us.sucursal_id AND pr.rol = 'transportista')
   ORDER BY us.sucursal_id, pf.id
   LIMIT 1;
  SELECT pf.id INTO v_o
    FROM public.perfiles pf
   WHERE pf.activo AND pf.rol = 'preventista' AND pf.id <> v_pb AND pf.id <> v_pxt
   ORDER BY EXISTS (SELECT 1 FROM public.usuario_sucursales us
                     WHERE us.usuario_id = pf.id AND us.sucursal_id = v_sb) DESC, pf.id
   LIMIT 1;
  SELECT us.usuario_id INTO v_adm
    FROM public.usuario_sucursales us JOIN public.perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_sb AND pf.activo AND pf.rol = 'admin'
   ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id, us.sucursal_id INTO v_enc, v_suc_enc
    FROM public.usuario_sucursales us JOIN public.perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id IN (v_sb, v_sx) AND pf.activo AND pf.rol = 'encargado'
   ORDER BY (us.sucursal_id = v_sb) DESC, us.usuario_id LIMIT 1;
  SELECT pf.id, us.sucursal_id INTO v_m, v_suc_m
    FROM public.perfiles pf
    JOIN public.usuario_sucursales us ON us.usuario_id = pf.id
    JOIN public.sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE pf.activo AND pf.rol = 'preventista'
     AND NOT EXISTS (SELECT 1 FROM public.perfil_roles pr WHERE pr.usuario_id = pf.id)
   ORDER BY (SELECT count(*) FROM public.clientes c WHERE c.sucursal_id = us.sucursal_id) DESC,
            (SELECT count(*) FROM public.pedidos pe WHERE pe.usuario_id = pf.id) DESC, pf.id
   LIMIT 1;
  IF v_pb IS NULL OR v_pxt IS NULL OR v_o IS NULL OR v_adm IS NULL OR v_enc IS NULL OR v_m IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un preventista base sin extra (PB %), uno con el extra transportista (PXT %), otro preventista (O %), un admin de la sucursal de PB (ADM %), un encargado de alguna de las dos sucursales (ENC %) y uno para medir (M %)',
      v_pb, v_pxt, v_o, v_adm, v_enc, v_m;
  END IF;

  -- -------------------------------------------------------------- clientes ---
  SELECT o_id, o_lat, o_lng, o_ped INTO v_cb, v_latb, v_lngb, v_pedb FROM pg_temp.elegir_c(v_sb, ARRAY[v_pb]);
  SELECT o_id, o_lat, o_lng, o_ped INTO v_cx, v_latx, v_lngx, v_pedx FROM pg_temp.elegir_c(v_sx, ARRAY[v_pxt]);
  IF v_cb IS NULL OR v_cx IS NULL THEN
    RAISE EXCEPTION 'no hay un cliente con coordenadas, un pedido no VB y ningún otro cliente de su sucursal a menos de 40 m: CB % (suc %), CX % (suc %)',
      v_cb, v_sb, v_cx, v_sx;
  END IF;
  v_nb := pg_temp.n_aviso(v_sb, v_pb);
  v_nx := pg_temp.n_aviso(v_sx, v_pxt);
  IF v_nb < 1 OR v_nx < 1 THEN
    RAISE EXCEPTION 'un aviso no le llegaría a nadie: NB % (suc %), NX % (suc %)', v_nb, v_sb, v_nx, v_sx;
  END IF;

  v_notas := v_notas || format('SB %s, PB %s, CB %s (pedido %s), NB %s; SX %s, PXT %s, CX %s (pedido %s), NX %s; O %s, ADM %s, ENC %s (suc %s), M %s (suc %s)',
                               v_sb, left(v_pb::text, 8), v_cb, v_pedb, v_nb,
                               v_sx, left(v_pxt::text, 8), v_cx, v_pedx, v_nx,
                               left(v_o::text, 8), left(v_adm::text, 8), left(v_enc::text, 8), v_suc_enc,
                               left(v_m::text, 8), v_suc_m);

  -- ============================================================== #1186 ===
  -- E1 / E8 · historial: CB de O, PB le vendió
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET usuario_id = %L WHERE id = %s', v_pb, v_pedb));
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('E1 · %s', v_j);
    IF (v_j ->> 'bloquea') IS DISTINCT FROM 'true' THEN
      v_fallas := v_fallas || format('E1 · no bloqueó en las coordenadas exactas de CB: %s', v_j);
    END IF;
    v_fallas := v_fallas || pg_temp.chequear('E1', v_j, v_cb, v_pb, v_n1 - v_n0, v_nb, true,
                                             'Alta de cliente bloqueada por duplicado');
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n2 := pg_temp.avisos(v_cb);
    IF v_n2 IS DISTINCT FROM v_n1 THEN
      v_fallas := v_fallas || format('E8 · repetir E1 sumó %s notificaciones (tenía que sumar 0)', v_n2 - v_n1);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E1/E8 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- E2 · reparto: CX de O, PEDX repartido por PXT
  BEGIN
    PERFORM pg_temp.base(v_cx);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cx, v_o);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET transportista_id = %L WHERE id = %s', v_pxt, v_pedx));
    v_n0 := pg_temp.avisos(v_cx);
    v_j := pg_temp.verificar(v_pxt, v_sx, v_latx, v_lngx);
    v_n1 := pg_temp.avisos(v_cx);
    v_notas := v_notas || format('E2 · %s', v_j);
    v_fallas := v_fallas || pg_temp.chequear('E2', v_j, v_cx, v_pxt, v_n1 - v_n0, v_nx, true,
                                             'Alta de cliente bloqueada por duplicado');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E2 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- E3 · reservado y sin asignar, PB le vendió
  BEGIN
    PERFORM pg_temp.base(v_cb);
    PERFORM pg_temp.fix(format('UPDATE public.clientes SET reservado_admin = true WHERE id = %s', v_cb));
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET usuario_id = %L WHERE id = %s', v_pb, v_pedb));
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_fallas := v_fallas || pg_temp.chequear('E3', v_j, v_cb, v_pb, v_n1 - v_n0, v_nb, true,
                                             'Alta de cliente bloqueada por duplicado');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E3 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- E4 · propio: CB asignado a PB
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_pb);
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_fallas := v_fallas || pg_temp.chequear('E4', v_j, v_cb, v_pb, v_n1 - v_n0, 0, true, NULL);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E4 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- E5 · huérfano no reservado
  BEGIN
    PERFORM pg_temp.base(v_cb);
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_fallas := v_fallas || pg_temp.chequear('E5', v_j, v_cb, v_pb, v_n1 - v_n0, 0, true, NULL);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E5 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- E6 · oculto (#543): CB de O, sin pedidos de PB
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    -- Sin chequeo de textos: E6 es la regresión y tiene que pasar también sin
    -- la 379 (el cierre nuevo lo vigilan E1, E9 y K).
    v_fallas := v_fallas || pg_temp.chequear('E6', v_j, v_cb, v_pb, v_n1 - v_n0, v_nb, false, NULL);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E6 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- E7 · ADM (en SB, sobre CB) y ENC (en su sucursal, sobre su C), C asignado a O
  BEGIN
    PERFORM pg_temp.base(v_cb);
    PERFORM pg_temp.base(v_cx);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    IF v_cx <> v_cb THEN
      INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cx, v_o);
    END IF;
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_adm, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_fallas := v_fallas || pg_temp.chequear('E7 ADM', v_j, v_cb, v_adm, v_n1 - v_n0, 0, true, NULL);
    IF v_suc_enc = v_sb THEN
      v_n0 := pg_temp.avisos(v_cb);
      v_j := pg_temp.verificar(v_enc, v_sb, v_latb, v_lngb);
      v_n1 := pg_temp.avisos(v_cb);
      v_fallas := v_fallas || pg_temp.chequear('E7 ENC', v_j, v_cb, v_enc, v_n1 - v_n0, 0, true, NULL);
    ELSE
      v_n0 := pg_temp.avisos(v_cx);
      v_j := pg_temp.verificar(v_enc, v_sx, v_latx, v_lngx);
      v_n1 := pg_temp.avisos(v_cx);
      v_fallas := v_fallas || pg_temp.chequear('E7 ENC', v_j, v_cx, v_enc, v_n1 - v_n0, 0, true, NULL);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E7 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- E9 · distancia: PB a unos 10 m de CB (CB de O, PB le vendió)
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET usuario_id = %L WHERE id = %s', v_pb, v_pedb));
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb + 10 / 111320.0, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('E9 · %s', v_j);
    IF (v_j ->> 'bloquea') IS DISTINCT FROM 'false' OR (v_j ->> 'avisa') IS DISTINCT FROM 'true' THEN
      v_fallas := v_fallas || format('E9 · a 10 m tenía que avisar sin bloquear: %s', v_j);
    END IF;
    v_fallas := v_fallas || pg_temp.chequear('E9', v_j, v_cb, v_pb, v_n1 - v_n0, v_nb, true,
                                             'Alta de cliente muy cerca de otro que no es de su cartera');
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E9 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- ============================================================== #1187 ===
  -- R1 / R2 con la policy vigente
  FOR v_u, v_s IN
    SELECT pf.id, us.sucursal_id
      FROM public.perfiles pf
      JOIN public.usuario_sucursales us ON us.usuario_id = pf.id
      JOIN public.sucursales s ON s.id = us.sucursal_id AND s.activa
     WHERE pf.activo AND pf.rol = 'preventista'
     ORDER BY pf.id, us.sucursal_id
  LOOP
    PERFORM pg_temp.como(v_u, v_s);
    v_t := pg_temp.t('SELECT md5(COALESCE(string_agg(id::text, '','' ORDER BY id), '''')) FROM public.clientes');
    PERFORM pg_temp.como(NULL, NULL);
    v_vis := v_vis || jsonb_build_object(v_u::text || '/' || v_s, v_t);
    v_combos := v_combos + 1;
  END LOOP;
  PERFORM pg_temp.como(v_m, v_suc_m);
  SELECT p_ms, p_filas INTO v_nueva, v_filas_n FROM pg_temp.medir();
  PERFORM pg_temp.como(NULL, NULL);

  -- R1 / R2 con la policy de la 378 (sub-bloque que se revierte)
  BEGIN
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
            OR EXISTS (
              SELECT 1 FROM public.pedidos pe
              WHERE pe.cliente_id = clientes.id AND pe.transportista_id = (SELECT auth.uid())
                AND pe.tipo_factura IS DISTINCT FROM 'VB'
            )
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.perfiles pd
            WHERE pd.id = auth.uid() AND pd.rol = 'deposito'
          )
        )
    $pol$;
    IF (SELECT md5(qual) FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
           AND policyname = 'mt_clientes_select') IS DISTINCT FROM 'f715c80865fe01f8c0ab11f1a7c8a835' THEN
      v_fallas := v_fallas || 'R1/R2 · la policy de la 378 reconstruida no da el md5 f715c808… (la comparación no vale)'::text;
    END IF;
    FOR v_u, v_s IN
      SELECT pf.id, us.sucursal_id
        FROM public.perfiles pf
        JOIN public.usuario_sucursales us ON us.usuario_id = pf.id
        JOIN public.sucursales s ON s.id = us.sucursal_id AND s.activa
       WHERE pf.activo AND pf.rol = 'preventista'
       ORDER BY pf.id, us.sucursal_id
    LOOP
      PERFORM pg_temp.como(v_u, v_s);
      v_t := pg_temp.t('SELECT md5(COALESCE(string_agg(id::text, '','' ORDER BY id), '''')) FROM public.clientes');
      PERFORM pg_temp.como(NULL, NULL);
      IF (v_vis ->> (v_u::text || '/' || v_s)) IS DISTINCT FROM v_t THEN
        v_dif := v_dif || format('%s en suc %s', left(v_u::text, 8), v_s);
      END IF;
    END LOOP;
    PERFORM pg_temp.como(v_m, v_suc_m);
    SELECT p_ms, p_filas INTO v_vieja, v_filas_v FROM pg_temp.medir();
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R1/R2 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;
  PERFORM pg_temp.como(NULL, NULL);
  IF v_combos = 0 THEN
    v_fallas := v_fallas || 'R1 · no hubo ningún preventista activo para comparar'::text;
  ELSIF cardinality(v_dif) > 0 THEN
    v_fallas := v_fallas || format('R1 · la policy vigente y la de la 378 no muestran los mismos clientes a: %s',
                                   array_to_string(v_dif, ', '));
  END IF;
  v_notas := v_notas || format('R1 · %s combinaciones preventista–sucursal comparadas', v_combos);
  IF v_nueva IS NULL OR v_vieja IS NULL THEN
    v_fallas := v_fallas || 'R2 · no se pudo medir'::text;
  ELSE
    v_notas := v_notas || format('R2 · M ve %s filas con la vigente en %s ms y %s con la de la 378 en %s ms (mínimo de 4)',
                                 v_filas_n, round(v_nueva, 1), v_filas_v, round(v_vieja, 1));
    IF v_filas_n IS DISTINCT FROM v_filas_v THEN
      v_fallas := v_fallas || format('R2 · M ve %s filas con la vigente y %s con la de la 378', v_filas_n, v_filas_v);
    END IF;
    IF v_nueva > v_vieja * 0.75 THEN
      v_fallas := v_fallas || format('R2 · la policy vigente tarda %s ms contra %s ms de la de la 378 (límite vieja × 0,75)',
                                     round(v_nueva, 1), round(v_vieja, 1));
    END IF;
  END IF;

  -- ========================================================== estructural ===
  -- K
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    v_t := (SELECT qual FROM pg_policies WHERE schemaname = 'public' AND tablename = 'clientes'
              AND policyname = 'mt_clientes_select');
    IF md5(v_t) IS DISTINCT FROM 'c9a4aff2b69aabdb09bb712f66a05b55' THEN
      v_fallas := v_fallas || 'K · la qual de mt_clientes_select no es la de la 379 (md5 c9a4aff2…)'::text;
      IF position('pe.usuario_id = auth.uid()' IN v_t) > 0 THEN
        v_fallas := v_fallas || 'K · la rama de historial compara contra auth.uid() pelado'::text;
      END IF;
      IF position('cp.preventista_id = auth.uid()' IN v_t) > 0 THEN
        v_fallas := v_fallas || 'K · la rama de los suyos compara contra auth.uid() pelado'::text;
      END IF;
    END IF;
    v_t := 'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)';
    v_src := (SELECT prosrc FROM pg_proc WHERE oid = v_t::regprocedure);
    IF position('NOT v_operable THEN' IN v_src) = 0 OR position('NOT v_visible THEN' IN v_src) > 0 THEN
      v_fallas := v_fallas || 'K · verificar_duplicado_cliente no decide el aviso por v_operable'::text;
    END IF;
    IF position('transportista_id = v_uid' IN v_src) = 0 THEN
      v_fallas := v_fallas || 'K · verificar_duplicado_cliente perdió la rama de reparto de v_visible'::text;
    END IF;
    IF position('asignáselo' IN v_src) > 0 OR position('que no es de su cartera' IN v_src) = 0 THEN
      v_fallas := v_fallas || 'K · verificar_duplicado_cliente no tiene los textos nuevos del aviso'::text;
    END IF;
    IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
          AND proname = 'verificar_duplicado_cliente') <> 1 THEN
      v_fallas := v_fallas || 'K · hay más de una sobrecarga de verificar_duplicado_cliente'::text;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_t::regprocedure) THEN
      v_fallas := v_fallas || 'K · verificar_duplicado_cliente dejó de ser SECURITY DEFINER'::text;
    END IF;
    IF has_function_privilege('anon', v_t::regprocedure, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', v_t::regprocedure, 'EXECUTE') THEN
      v_fallas := v_fallas || 'K · verificar_duplicado_cliente: EXECUTE para anon o sin EXECUTE para authenticated'::text;
    END IF;
    IF position('v_operable' IN COALESCE(obj_description(v_t::regprocedure, 'pg_proc'), '')) = 0 THEN
      v_fallas := v_fallas || 'K · el COMMENT de verificar_duplicado_cliente no habla de v_operable'::text;
    END IF;
    v_notas := v_notas || format('K · md5 de pg_get_functiondef(verificar_duplicado_cliente) = %s',
                                 md5(pg_get_functiondef(v_t::regprocedure)));
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('K · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
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
