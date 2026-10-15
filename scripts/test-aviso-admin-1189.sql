-- Ensayo de #1189 (mig 382): verificar_duplicado_cliente devuelve aviso_admin, que es
-- exactamente la condición con la que avisa a administración (v_es_prev AND NOT
-- v_operable; false sin vecino).
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia de
-- notificaciones, cliente_preventistas y audit_logs): un único DO que termina SIEMPRE
-- en una excepción, y cada caso corre en su propio sub-bloque que se revierte. Mismo
-- molde que scripts/test-duplicado-operable-y-cartera-1186-1187.sql: los fixtures van
-- como postgres sin claims; cada llamada a la RPC corre con los claims del usuario, el
-- header x-sucursal-id y SET LOCAL ROLE authenticated, por EXECUTE. Si un fixture no
-- queda, el caso falla: nunca se saltea.
--
-- SB es la sucursal activa con más clientes que tenga un preventista base sin extra (PB,
-- el de más pedidos). CB es un cliente activo no reservado de SB, con coordenadas y un
-- pedido no VB (PEDB), sin ningún cliente de SB a menos de 40 m y sin pedidos de PB. O es
-- otro preventista activo y ADM un admin de SB. NB son las notificaciones que genera un
-- aviso en SB (los admin y encargados activos, sin el que dispara; > 0).
--
-- Todas las llamadas van sin dirección, así el vecino lo elige la distancia y es CB.
--   A1 · historial: CB de O, PEDB vendido por PB → aviso_admin true, cliente_visible CB,
--        +NB notificaciones
--   A2 · deduplicación: repetir A1 → aviso_admin sigue true y +0
--   A3 · inactivo con historial: A1 con CB desactivado → aviso_admin true,
--        cliente_visible CB con activo false, +NB
--   A4 · propio: CB asignado a PB → aviso_admin false, cliente_visible CB, +0
--   A5 · oculto: CB de O, sin pedidos de PB → aviso_admin true, cliente_visible null, +NB
--   A6 · admin: ADM en las coordenadas de CB de O → aviso_admin false, +0
--   A7 · sin vecino: PB a 1 grado de latitud de CB → bloquea/avisa false,
--        aviso_admin false (el RETURN temprano)
--   K  · las dos ramas del JSON traen la clave aviso_admin (A1 y A7) y la función
--        quedó con una sobrecarga, DEFINER y el ACL de siempre. Anota el md5 de
--        pg_get_functiondef.
--
-- Sin la migración tiene que FALLAR (aviso_admin ausente en todos los casos). Con la
-- migración (inline antes del DO) tiene que dar 'ENSAYO OK'.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLO …', siempre como excepción (el MCP de Supabase
-- no muestra NOTICEs).
--
--   psql "$DATABASE_URL" -f scripts/test-aviso-admin-1189.sql

DO $ensayo$
DECLARE
  v_sb      bigint;
  v_pb      uuid;
  v_cb      bigint;
  v_pedb    bigint;
  v_latb    numeric;
  v_lngb    numeric;
  v_nb      bigint;
  v_o       uuid;
  v_adm     uuid;
  v_j       jsonb;
  v_n0      bigint;
  v_n1      bigint;
  v_n2      bigint;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
  f_dup     text := 'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)';
BEGIN
 BEGIN
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
  CREATE OR REPLACE FUNCTION pg_temp.fix(p_sql text) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    IF v <> 1 THEN
      RAISE EXCEPTION 'fixture: % filas en %', v, p_sql;
    END IF;
  END $f$;
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
  CREATE OR REPLACE FUNCTION pg_temp.n_aviso(p_suc bigint, p_uid uuid) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(DISTINCT us.usuario_id)
      FROM public.usuario_sucursales us
      JOIN public.perfiles p ON p.id = us.usuario_id
     WHERE us.sucursal_id = p_suc
       AND (CASE WHEN us.rol = 'mismo' THEN p.rol ELSE us.rol END) IN ('admin', 'encargado')
       AND p.activo IS NOT FALSE
       AND us.usuario_id <> p_uid
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.avisos(p_c bigint) RETURNS bigint LANGUAGE sql AS $f$
    SELECT count(*) FROM public.notificaciones n
     WHERE n.tipo = 'cliente_duplicado_oculto' AND n.entidad_id = p_c
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.base(p_c bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(NULL, NULL);
    DELETE FROM public.cliente_preventistas WHERE cliente_id = p_c;
    DELETE FROM public.notificaciones WHERE tipo = 'cliente_duplicado_oculto' AND entidad_id = p_c;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.verificar(p_uid uuid, p_suc bigint, p_lat numeric, p_lng numeric)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE 'SELECT public.verificar_duplicado_cliente($1, $2, NULL, NULL)' INTO v USING p_lat, p_lng;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN v;
  END $f$;
  -- p_aviso: el aviso_admin esperado. p_visible: cliente_visible CB (true) o null
  -- (false). p_delta/p_esperado: notificaciones nuevas sobre CB.
  CREATE OR REPLACE FUNCTION pg_temp.chequear(p_caso text, p_j jsonb, p_c bigint,
      p_aviso boolean, p_visible boolean, p_delta bigint, p_esperado bigint) RETURNS text[] LANGUAGE plpgsql AS $f$
  DECLARE r text[] := '{}';
  BEGIN
    IF NOT (p_j ? 'aviso_admin') THEN
      r := r || format('%s · el JSON no trae aviso_admin: %s', p_caso, p_j);
    ELSIF jsonb_typeof(p_j -> 'aviso_admin') <> 'boolean'
       OR (p_j ->> 'aviso_admin')::boolean IS DISTINCT FROM p_aviso THEN
      r := r || format('%s · aviso_admin tenía que ser %s: %s', p_caso, p_aviso, p_j);
    END IF;
    IF p_visible AND (p_j -> 'cliente_visible' ->> 'id') IS DISTINCT FROM p_c::text THEN
      r := r || format('%s · cliente_visible no es C (%s): %s', p_caso, p_c, p_j);
    ELSIF NOT p_visible AND p_j -> 'cliente_visible' IS NOT NULL AND p_j -> 'cliente_visible' <> 'null'::jsonb THEN
      r := r || format('%s · cliente_visible tenía que venir null: %s', p_caso, p_j);
    END IF;
    IF p_delta IS DISTINCT FROM p_esperado THEN
      r := r || format('%s · %s notificaciones nuevas sobre C (%s), tenían que ser %s', p_caso, p_delta, p_c, p_esperado);
    END IF;
    RETURN r;
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
  SELECT pf.id INTO v_o
    FROM public.perfiles pf
   WHERE pf.activo AND pf.rol = 'preventista' AND pf.id <> v_pb
   ORDER BY EXISTS (SELECT 1 FROM public.usuario_sucursales us
                     WHERE us.usuario_id = pf.id AND us.sucursal_id = v_sb) DESC, pf.id
   LIMIT 1;
  SELECT us.usuario_id INTO v_adm
    FROM public.usuario_sucursales us JOIN public.perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_sb AND pf.activo AND pf.rol = 'admin'
   ORDER BY us.usuario_id LIMIT 1;
  IF v_pb IS NULL OR v_o IS NULL OR v_adm IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un preventista base sin extra (PB %), otro preventista (O %) y un admin de la sucursal de PB (ADM %)',
      v_pb, v_o, v_adm;
  END IF;

  SELECT o_id, o_lat, o_lng, o_ped INTO v_cb, v_latb, v_lngb, v_pedb FROM pg_temp.elegir_c(v_sb, ARRAY[v_pb]);
  IF v_cb IS NULL THEN
    RAISE EXCEPTION 'no hay un cliente de la sucursal % con coordenadas, un pedido no VB y ningún otro cliente a menos de 40 m', v_sb;
  END IF;
  v_nb := pg_temp.n_aviso(v_sb, v_pb);
  IF v_nb < 1 THEN
    RAISE EXCEPTION 'un aviso no le llegaría a nadie: NB % (suc %)', v_nb, v_sb;
  END IF;
  v_notas := v_notas || format('SB %s, PB %s, CB %s (pedido %s), NB %s, O %s, ADM %s',
                               v_sb, left(v_pb::text, 8), v_cb, v_pedb, v_nb,
                               left(v_o::text, 8), left(v_adm::text, 8));

  -- A1 / A2 · historial: CB de O, PB le vendió
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET usuario_id = %L WHERE id = %s', v_pb, v_pedb));
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('A1 · %s', v_j);
    v_fallas := v_fallas || pg_temp.chequear('A1', v_j, v_cb, true, true, v_n1 - v_n0, v_nb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n2 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('A2 · %s', v_j);
    v_fallas := v_fallas || pg_temp.chequear('A2', v_j, v_cb, true, true, v_n2 - v_n1, 0);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A1/A2 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- A3 · inactivo con historial
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    PERFORM pg_temp.fix(format('UPDATE public.pedidos SET usuario_id = %L WHERE id = %s', v_pb, v_pedb));
    PERFORM pg_temp.fix(format('UPDATE public.clientes SET activo = false WHERE id = %s', v_cb));
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('A3 · %s', v_j);
    v_fallas := v_fallas || pg_temp.chequear('A3', v_j, v_cb, true, true, v_n1 - v_n0, v_nb);
    IF (v_j -> 'cliente_visible' ->> 'activo') IS DISTINCT FROM 'false' THEN
      v_fallas := v_fallas || format('A3 · cliente_visible.activo tenía que ser false: %s', v_j);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A3 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- A4 · propio: CB asignado a PB
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_pb);
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('A4 · %s', v_j);
    v_fallas := v_fallas || pg_temp.chequear('A4', v_j, v_cb, false, true, v_n1 - v_n0, 0);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A4 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- A5 · oculto: CB de O, sin pedidos de PB (elegir_c lo garantiza)
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('A5 · %s', v_j);
    v_fallas := v_fallas || pg_temp.chequear('A5', v_j, v_cb, true, false, v_n1 - v_n0, v_nb);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A5 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- A6 · admin
  BEGIN
    PERFORM pg_temp.base(v_cb);
    INSERT INTO public.cliente_preventistas (cliente_id, preventista_id) VALUES (v_cb, v_o);
    v_n0 := pg_temp.avisos(v_cb);
    v_j := pg_temp.verificar(v_adm, v_sb, v_latb, v_lngb);
    v_n1 := pg_temp.avisos(v_cb);
    v_notas := v_notas || format('A6 · %s', v_j);
    v_fallas := v_fallas || pg_temp.chequear('A6', v_j, v_cb, false, true, v_n1 - v_n0, 0);
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A6 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- A7 · sin vecino: el RETURN temprano
  BEGIN
    PERFORM pg_temp.base(v_cb);
    v_j := pg_temp.verificar(v_pb, v_sb, v_latb + 1, v_lngb);
    v_notas := v_notas || format('A7 · %s', v_j);
    IF (v_j ->> 'bloquea') IS DISTINCT FROM 'false' OR (v_j ->> 'avisa') IS DISTINCT FROM 'false' THEN
      v_fallas := v_fallas || format('A7 · a un grado de CB no tenía que haber vecino: %s', v_j);
    END IF;
    IF NOT (v_j ? 'aviso_admin') OR (v_j -> 'aviso_admin') IS DISTINCT FROM 'false'::jsonb THEN
      v_fallas := v_fallas || format('A7 · aviso_admin tenía que ser false: %s', v_j);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A7 · error inesperado: ' || SQLSTATE || ' ' || SQLERRM);
  END;

  -- K · estructural
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname = 'verificar_duplicado_cliente') <> 1 THEN
    v_fallas := v_fallas || 'K · hay más de una sobrecarga de verificar_duplicado_cliente'::text;
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f_dup::regprocedure) THEN
    v_fallas := v_fallas || 'K · verificar_duplicado_cliente no es SECURITY DEFINER'::text;
  END IF;
  IF has_function_privilege('anon', f_dup::regprocedure, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', f_dup::regprocedure, 'EXECUTE') THEN
    v_fallas := v_fallas || 'K · ACL: EXECUTE para anon o sin EXECUTE para authenticated'::text;
  END IF;
  v_notas := v_notas || format('md5 functiondef %s',
                               md5(pg_get_functiondef(f_dup::regprocedure)));
 END;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · %', array_to_string(v_notas, ' | ');
  ELSE
    RAISE EXCEPTION 'ENSAYO FALLO (%) · % || notas: %', cardinality(v_fallas),
      array_to_string(v_fallas, ' | '), array_to_string(v_notas, ' | ');
  END IF;
END
$ensayo$;
