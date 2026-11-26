-- =========================================================================
-- NNN · EL GPS DEL PEDIDO VA A UNA TABLA APARTE (ola 3 de #1603, tanda T8b; permisos-B4 de
-- #1677, #1690)
--
-- Ensayo: scripts/test-ola3-t8b-pedido-gps.sql (sin esta migración falla en A1; con ella,
-- ENSAYO OK). Corrige test-geolocalizacion-1602.sql, test-ola3-geo-visitas.sql,
-- test-suplantar-admin-1048.sql y test-canje-aplicado-y-hora-gps-1553.sql, que leían o
-- escribían el GPS en pedidos. Se aplica en LF, sobre la 554.
--
-- El problema: `authenticated` lee `pedidos` por tabla, y la policy mt_pedidos_select deja ver
-- un pedido a su chofer. Con eso el chofer leía, por REST, dónde estaba el preventista cuando
-- cargó el pedido (gps_lat, gps_lng, gps_accuracy, gps_capturado_at, gps_status,
-- gps_motivo_omision y gps_diagnostico). Es la privacidad del empleado.
--
-- Decisión del dueño (D10): esas columnas pasan a una tabla aparte que el chofer no lee.
--
-- 1 · pedido_gps: una fila por pedido con check-in (sin fila = el pedido no tiene check-in,
--     lo que antes era gps_status NULL). Las mismas columnas y los mismos nombres, así el
--     panel devuelve las mismas claves. FK compuesta (pedido_id, sucursal_id) → pedidos(id,
--     sucursal_id), como las del aislamiento, ON DELETE CASCADE (el GPS se iba con el pedido).
--     Es la única FK de la tabla: sin una segunda FK (a sucursales) PostgREST no la puede tomar
--     por una tabla puente entre pedidos y sucursales (PGRST201 en los embeds de hoy). En src/
--     no hay embeds pedidos↔pedido_gps. CHECK con freno de NaN y rango (lat −90..90, lng
--     −180..180, precisión ≥ 0), los de forma del diagnóstico, y la coherencia que la RPC ya
--     cumplía (ok ⇒ lat y lng; no ok ⇒ sin coordenadas ni precisión; ok ⇒ sin motivo). Prod
--     la cumple entera (medido el 26/11).
-- 2 · Quién la lee: sólo el admin, en su sucursal activa (es_admin(), que mira activo). Ni el
--     chofer, ni el encargado, ni el preventista, tampoco el propio GPS: es lo más cerrado, y si
--     el preventista debe ver el suyo lo decide el dueño (decisión abierta). Por REST sólo
--     SELECT (la policy lo acota); nadie la escribe por REST: escribe la RPC DEFINER. Nada para
--     anon. Sin secuencia (la clave es el pedido).
-- 3 · registrar_geolocalizacion_pedido (misma firma; un bundle viejo y la cola sin conexión
--     siguen andando) escribe en pedido_gps: las mismas reglas (un ok no se pisa; un no-ok no
--     pisa otro no-ok; un ok sí pisa un no-ok), y dos llamadas a la vez no chocan: el INSERT …
--     ON CONFLICT repite la regla con la fila tomada.
--     Ya no toca la fila de pedidos: registrar el GPS no le mueve la versión al pedido ni deja
--     una fila de audit_pedidos con las coordenadas.
-- 4 · obtener_geolocalizacion_preventistas (el panel, sólo admin) lee el GPS de pedido_gps con
--     un LEFT JOIN. Devuelve lo mismo, con las mismas claves.
-- 5 · Se copian los datos y se SACAN las columnas de pedidos (con sus CHECK y el índice
--     idx_pedidos_gps_capturado_at). Por qué sacarlas y no vaciarlas y revocarlas:
--     · pedidos se lee por tabla, y el front pide `*`. Revocar siete columnas obligaría a
--       conceder pedidos columna por columna, y ahí todo `select('*')` sobre pedidos (los de hoy
--       y los de los bundles viejos del PWA) da 42501 para todos (cuarto de la Trampa 5).
--     · ningún select de src/, ni de su historia, nombra una columna gps_ de pedidos: todo el
--       front las recibía por `*`. Un bundle viejo sigue andando; sólo deja de ver el chip del
--       GPS en la tarjeta del pedido (gps_status llega undefined y el chip no se dibuja).
--       check-embeds.mjs no tiene ningún select que las nombre.
--     · vaciarlas sería un UPDATE de cada pedido con GPS (6.605 en prod) que dispara los ~20
--       triggers de pedidos y deja una fila de auditoría por cada uno. Sacarlas es un cambio de
--       catálogo.
--     Así que no hace falta un segundo paso.
--
-- Lo que no cambia: las visitas (visitas_cliente) siguen con su GPS; las filas que audit_logs ya
-- guardó de pedidos traen las coordenadas en la foto de la fila, y las lee sólo el admin de la
-- sucursal (mt_audit_logs_select), igual que pedido_gps.
--
-- PREMISAS (abortan con el motivo): los cuerpos vivos de la 554 de las dos RPC, que ninguna
-- otra función ni vista lea las columnas gps_ de pedidos, que pedido_gps no exista, y que los
-- datos cumplan los CHECK nuevos.
--
-- LOCKS: ACCESS EXCLUSIVE NOWAIT sobre pedidos, al principio y de una vez (DROP COLUMN y la FK
-- nueva). DROP COLUMN no reescribe la tabla; la copia lee los pedidos con GPS una vez.
--
-- Revertir: ADD COLUMN de las siete en pedidos con sus CHECK y su índice, copiar de pedido_gps,
-- volver las dos RPC a los cuerpos de las premisas, DROP TABLE pedido_gps.
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

LOCK TABLE public.pedidos IN ACCESS EXCLUSIVE MODE NOWAIT;

-- -------------------------------------------------------------------------
-- Premisas
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
  n bigint;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)',
     '85603f3b5d2ec9b05b4f4bcf378c6ead'),
    ('public.obtener_geolocalizacion_preventistas(date,date)', 'de87050567303a6fe5a138ee503ed07b')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- Las otras dos funciones que nombran gps_ son de las visitas (visitas_cliente), con estos
  -- cuerpos; una función más que nombre gps_ podría leer las columnas que se sacan.
  SELECT string_agg(p.proname || ' ' || md5(p.prosrc), ', ' ORDER BY p.proname) INTO v
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.prosrc ~ 'gps_(lat|lng|accuracy|capturado_at|status|motivo_omision|diagnostico)'
     AND p.proname NOT IN ('registrar_geolocalizacion_pedido', 'obtener_geolocalizacion_preventistas');
  IF v IS DISTINCT FROM 'listar_visitas_hoy 2b01c13670d61b16ddcc89cacf3d65b0, registrar_visita_cliente 38fe24b6cd106fb28b0fa036da38813a' THEN
    RAISE EXCEPTION 'mig NNN · otra función nombra el GPS (%): revisar si lee el de pedidos', v;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_depend d
               JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
              WHERE d.refobjid = 'public.pedidos'::regclass AND a.attname LIKE 'gps\_%'
                AND d.classid IN ('pg_rewrite'::regclass, 'pg_trigger'::regclass, 'pg_policy'::regclass)) THEN
    RAISE EXCEPTION 'mig NNN · una vista, un trigger o una policy depende de una columna gps_ de pedidos';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'pedidos'
         AND column_name IN ('gps_lat', 'gps_lng', 'gps_accuracy', 'gps_capturado_at', 'gps_status',
                             'gps_motivo_omision', 'gps_diagnostico')) <> 7 THEN
    RAISE EXCEPTION 'mig NNN · pedidos no tiene las siete columnas gps_: rehacer sobre lo vigente';
  END IF;
  IF to_regclass('public.pedido_gps') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · pedido_gps ya existe: rehacer sobre lo vigente';
  END IF;

  -- Datos: lo que no entra en los CHECK nuevos (prod, 26/11: cero en cada uno).
  SELECT count(*) INTO n FROM public.pedidos
   WHERE gps_status IS NULL
     AND (gps_lat IS NOT NULL OR gps_lng IS NOT NULL OR gps_accuracy IS NOT NULL OR gps_capturado_at IS NOT NULL
          OR gps_motivo_omision IS NOT NULL OR gps_diagnostico IS NOT NULL);
  IF n > 0 THEN
    RAISE EXCEPTION 'mig NNN · % pedidos tienen datos de GPS sin gps_status: no se copiarían', n;
  END IF;
  SELECT count(*) INTO n FROM public.pedidos
   WHERE (gps_status = 'ok' AND (gps_lat IS NULL OR gps_lng IS NULL OR gps_motivo_omision IS NOT NULL))
      OR (gps_status <> 'ok' AND (gps_lat IS NOT NULL OR gps_lng IS NOT NULL OR gps_accuracy IS NOT NULL));
  IF n > 0 THEN
    RAISE EXCEPTION 'mig NNN · % pedidos tienen un GPS incoherente (ok sin coordenadas, o no-ok con ellas)', n;
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · La tabla
-- -------------------------------------------------------------------------
CREATE TABLE public.pedido_gps (
  pedido_id          bigint      NOT NULL,
  sucursal_id        bigint      NOT NULL,
  gps_status         text        NOT NULL,
  gps_lat            numeric(10,7),
  gps_lng            numeric(10,7),
  gps_accuracy       numeric(8,2),
  gps_capturado_at   timestamptz,
  gps_motivo_omision text,
  gps_diagnostico    jsonb,
  CONSTRAINT pedido_gps_pkey PRIMARY KEY (pedido_id),
  CONSTRAINT pedido_gps_pedido_fkey FOREIGN KEY (pedido_id, sucursal_id)
    REFERENCES public.pedidos (id, sucursal_id) ON DELETE CASCADE,
  CONSTRAINT pedido_gps_status_valido
    CHECK (gps_status IN ('ok', 'denied', 'unavailable', 'timeout', 'error')),
  CONSTRAINT pedido_gps_lat_rango
    CHECK (gps_lat <> 'NaN' AND gps_lat >= -90 AND gps_lat <= 90),
  CONSTRAINT pedido_gps_lng_rango
    CHECK (gps_lng <> 'NaN' AND gps_lng >= -180 AND gps_lng <= 180),
  CONSTRAINT pedido_gps_accuracy_rango
    CHECK (gps_accuracy <> 'NaN' AND gps_accuracy >= 0),
  CONSTRAINT pedido_gps_diagnostico_forma
    CHECK (jsonb_typeof(gps_diagnostico) = 'object' AND octet_length(gps_diagnostico::text) <= 300),
  CONSTRAINT pedido_gps_coherente
    CHECK (CASE WHEN gps_status = 'ok'
                THEN gps_lat IS NOT NULL AND gps_lng IS NOT NULL AND gps_motivo_omision IS NULL
                ELSE gps_lat IS NULL AND gps_lng IS NULL AND gps_accuracy IS NULL END)
);

COMMENT ON TABLE public.pedido_gps IS
  'Check-in GPS del preventista al cargar el pedido (mig NNN, permisos-B4 / D10). Lo lee sólo el admin de la sucursal; lo escribe registrar_geolocalizacion_pedido. Sin fila = sin check-in.';

ALTER TABLE public.pedido_gps ENABLE ROW LEVEL SECURITY;

-- Los privilegios por defecto de postgres dan SELECT a authenticated; se dejan explícitos.
REVOKE ALL ON public.pedido_gps FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.pedido_gps TO authenticated;

CREATE POLICY pedido_gps_select_admin ON public.pedido_gps
  FOR SELECT TO authenticated
  USING ((SELECT public.es_admin()) AND sucursal_id = (SELECT public.current_sucursal_id()));

-- -------------------------------------------------------------------------
-- 5a · La copia, verificada contra lo que había
-- -------------------------------------------------------------------------
DO $copia$
DECLARE
  v_antes   text;
  v_despues text;
  n_antes   bigint;
  n_despues bigint;
BEGIN
  SELECT count(*), md5(COALESCE(string_agg(concat_ws('|', id, sucursal_id, gps_status, gps_lat, gps_lng, gps_accuracy,
                                                     gps_capturado_at, gps_motivo_omision, gps_diagnostico::text),
                                           E'\n' ORDER BY id), ''))
    INTO n_antes, v_antes
    FROM public.pedidos WHERE gps_status IS NOT NULL;

  INSERT INTO public.pedido_gps (pedido_id, sucursal_id, gps_status, gps_lat, gps_lng, gps_accuracy,
                                 gps_capturado_at, gps_motivo_omision, gps_diagnostico)
  SELECT id, sucursal_id, gps_status, gps_lat, gps_lng, gps_accuracy,
         gps_capturado_at, gps_motivo_omision, gps_diagnostico
    FROM public.pedidos
   WHERE gps_status IS NOT NULL;

  SELECT count(*), md5(COALESCE(string_agg(concat_ws('|', pedido_id, sucursal_id, gps_status, gps_lat, gps_lng, gps_accuracy,
                                                     gps_capturado_at, gps_motivo_omision, gps_diagnostico::text),
                                           E'\n' ORDER BY pedido_id), ''))
    INTO n_despues, v_despues
    FROM public.pedido_gps;

  IF n_antes IS DISTINCT FROM n_despues OR v_antes IS DISTINCT FROM v_despues THEN
    RAISE EXCEPTION 'mig NNN · la copia no da lo mismo (% filas, md5 %; quedaron %, md5 %)',
      n_antes, v_antes, n_despues, v_despues;
  END IF;
  RAISE NOTICE 'mig NNN · % check-ins copiados a pedido_gps (md5 %)', n_despues, v_despues;
END
$copia$;

-- -------------------------------------------------------------------------
-- 3 · La RPC que escribe
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_geolocalizacion_pedido(p_pedido_id bigint, p_status text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric, p_capturado_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_motivo_omision text DEFAULT NULL::text, p_diagnostico jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_pedido RECORD;
  v_n int;
  v_status_previo text;
  -- #1602: un extra; si no es un objeto chico, no se guarda (no se pierde el GPS).
  v_diag jsonb := CASE WHEN jsonb_typeof(p_diagnostico) = 'object' AND octet_length(p_diagnostico::text) <= 300
                       THEN p_diagnostico END;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;

  IF p_status NOT IN ('ok','denied','unavailable','timeout','error') THEN
    RETURN jsonb_build_object('success', false, 'error', 'gps_status invalido');
  END IF;

  IF p_status = 'ok' AND (p_lat IS NULL OR p_lng IS NULL) THEN
    RETURN jsonb_build_object('success', false, 'error', 'lat y lng requeridos cuando status=ok');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id AND COALESCE(activo, true);

  SELECT id, usuario_id, sucursal_id INTO v_pedido
  FROM pedidos
  WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no existe');
  END IF;

  IF v_pedido.sucursal_id IS DISTINCT FROM current_sucursal_id() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido fuera de la sucursal activa');
  END IF;

  -- #1048: con `<>` un rol NULL daba NULL y dejaba pasar.
  IF v_pedido.usuario_id IS DISTINCT FROM v_user_id AND v_user_role IS DISTINCT FROM 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- permisos-B4 (mig NNN): el GPS vive en pedido_gps, que el chofer no lee. Las reglas de antes:
  -- un ok no se pisa; un no-ok sólo lo pisa un ok.
  SELECT gps_status INTO v_status_previo FROM pedido_gps WHERE pedido_id = p_pedido_id;
  IF v_status_previo = 'ok' THEN
    RETURN jsonb_build_object('success', true, 'ya_registrado', true);
  END IF;
  IF v_status_previo IS NOT NULL AND p_status <> 'ok' THEN
    RETURN jsonb_build_object('success', true, 'ya_registrado', true);
  END IF;

  -- Dos llamadas a la vez (el alta y el replay de la cola): la segunda choca en la clave y
  -- aplica la misma regla con la fila ya tomada.
  INSERT INTO pedido_gps AS g (pedido_id, sucursal_id, gps_status, gps_lat, gps_lng, gps_accuracy,
                               gps_capturado_at, gps_motivo_omision, gps_diagnostico)
  VALUES (v_pedido.id, v_pedido.sucursal_id, p_status,
          CASE WHEN p_status = 'ok' THEN p_lat END,
          CASE WHEN p_status = 'ok' THEN p_lng END,
          CASE WHEN p_status = 'ok' THEN p_accuracy END,
          public._gps_hora_de_captura(p_capturado_at),
          CASE WHEN p_status = 'ok' THEN NULL ELSE p_motivo_omision END,
          v_diag)
  ON CONFLICT (pedido_id) DO UPDATE SET
    gps_status         = EXCLUDED.gps_status,
    gps_lat            = EXCLUDED.gps_lat,
    gps_lng            = EXCLUDED.gps_lng,
    gps_accuracy       = EXCLUDED.gps_accuracy,
    gps_capturado_at   = EXCLUDED.gps_capturado_at,
    gps_motivo_omision = EXCLUDED.gps_motivo_omision,
    gps_diagnostico    = EXCLUDED.gps_diagnostico
  WHERE g.gps_status <> 'ok' AND EXCLUDED.gps_status = 'ok';
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n = 0 THEN
    RETURN jsonb_build_object('success', true, 'ya_registrado', true);
  END IF;
  RETURN jsonb_build_object('success', true);
END;
$function$;

-- -------------------------------------------------------------------------
-- 4 · El panel
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_geolocalizacion_preventistas(p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_user_role text;
  v_sucursal bigint := current_sucursal_id();
  v_fecha_desde date := COALESCE(p_fecha_desde, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
  v_fecha_hasta date := COALESCE(p_fecha_hasta, v_fecha_desde);
  -- Var-B3 (decisión del dueño, 25/11): el día argentino de la carga. De la medianoche
  -- argentina del desde a la del día siguiente al hasta, sobre `created_at` (sus índices).
  v_desde_ts timestamptz := v_fecha_desde::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_hasta_ts timestamptz := (v_fecha_hasta + 1)::timestamp AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  -- #1056: con `<>` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admins pueden ver geolocalizacion de preventistas' USING ERRCODE = '42501';
  END IF;
  WITH pedidos_rango AS (
    SELECT
      p.id              AS pedido_id,
      p.usuario_id      AS preventista_id,
      p.fecha,
      p.created_at      AS pedido_created_at,
      p.total,
      -- permisos-B4 (mig NNN): el GPS del pedido vive en pedido_gps (sin fila = sin check-in).
      g.gps_lat,
      g.gps_lng,
      g.gps_accuracy,
      g.gps_capturado_at,
      g.gps_status,
      p.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(g.gps_lat, g.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM pedidos p
    LEFT JOIN pedido_gps g ON g.pedido_id = p.id
    LEFT JOIN clientes c ON c.id = p.cliente_id
    WHERE p.sucursal_id = v_sucursal
      AND p.created_at >= v_desde_ts
      AND p.created_at < v_hasta_ts
      AND p.usuario_id IS NOT NULL
      -- Var-B2: un pedido cancelado no es un pedido del día (ni «sin GPS»).
      AND p.estado <> 'cancelado'
  ),
  visitas_rango AS (
    SELECT
      v.id              AS visita_id,
      v.preventista_id,
      v.created_at      AS visita_created_at,
      v.gps_lat,
      v.gps_lng,
      v.gps_accuracy,
      v.gps_capturado_at,
      v.gps_status,
      v.cliente_id,
      c.nombre_fantasia AS cliente_nombre,
      c.latitud         AS cliente_lat,
      c.longitud        AS cliente_lng,
      public.haversine_m(v.gps_lat, v.gps_lng, c.latitud, c.longitud) AS distancia_m
    FROM visitas_cliente v
    LEFT JOIN clientes c ON c.id = v.cliente_id
    WHERE v.sucursal_id = v_sucursal
      AND v.created_at >= v_desde_ts
      AND v.created_at < v_hasta_ts
  ),
  -- #1623 (VAR-02): el preventista del día es el que cargó pedidos O marcó visitas.
  preventistas_rango AS (
    SELECT pr.preventista_id FROM pedidos_rango pr
    UNION
    SELECT v.preventista_id FROM visitas_rango v
  ),
  pedidos_por_preventista AS (
    SELECT
      pr.preventista_id,
      COUNT(*)::int AS total_pedidos,
      COUNT(*) FILTER (WHERE pr.gps_status = 'ok')::int AS pedidos_con_gps,
      COUNT(*) FILTER (WHERE pr.gps_status IS NULL OR pr.gps_status <> 'ok')::int AS pedidos_sin_gps,
      COUNT(*) FILTER (
        WHERE pr.gps_status = 'ok' AND pr.distancia_m IS NOT NULL AND pr.distancia_m >= 1000
      )::int AS pedidos_lejos
    FROM pedidos_rango pr
    GROUP BY pr.preventista_id
  ),
  preventistas_resumen AS (
    SELECT
      pv.preventista_id,
      per.nombre AS preventista_nombre,
      COALESCE(pp.total_pedidos, 0) AS total_pedidos,
      COALESCE(pp.pedidos_con_gps, 0) AS pedidos_con_gps,
      COALESCE(pp.pedidos_sin_gps, 0) AS pedidos_sin_gps,
      COALESCE(pp.pedidos_lejos, 0) AS pedidos_lejos,
      (SELECT COUNT(*) FROM visitas_rango v WHERE v.preventista_id = pv.preventista_id)::int AS total_visitas,
      (
        SELECT jsonb_build_object(
          'lat', e.lat,
          'lng', e.lng,
          'capturado_at', e.capturado_at,
          'tipo', e.tipo,
          'id', e.id
        )
        FROM (
          SELECT pr2.gps_lat AS lat, pr2.gps_lng AS lng, pr2.gps_capturado_at AS capturado_at,
                 'pedido'::text AS tipo, pr2.pedido_id AS id
          FROM pedidos_rango pr2
          WHERE pr2.preventista_id = pv.preventista_id AND pr2.gps_status = 'ok'
          UNION ALL
          SELECT v.gps_lat AS lat, v.gps_lng AS lng, v.gps_capturado_at AS capturado_at,
                 'visita'::text AS tipo, v.visita_id AS id
          FROM visitas_rango v
          WHERE v.preventista_id = pv.preventista_id AND v.gps_status = 'ok'
        ) e
        ORDER BY e.capturado_at DESC NULLS LAST
        LIMIT 1
      ) AS ultima_ubicacion
    FROM preventistas_rango pv
    JOIN perfiles per ON per.id = pv.preventista_id AND per.rol IN ('preventista')
    LEFT JOIN pedidos_por_preventista pp ON pp.preventista_id = pv.preventista_id
  )
  SELECT jsonb_build_object(
    'fecha_desde', v_fecha_desde,
    'fecha_hasta', v_fecha_hasta,
    'preventistas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(preventistas_resumen.*) ORDER BY preventista_nombre)
       FROM preventistas_resumen),
      '[]'::jsonb
    ),
    'pedidos', COALESCE(
      (SELECT jsonb_agg(to_jsonb(pr.*) ORDER BY pr.pedido_created_at NULLS LAST)
       FROM pedidos_rango pr
       JOIN perfiles per ON per.id = pr.preventista_id AND per.rol IN ('preventista')),
      '[]'::jsonb
    ),
    'visitas', COALESCE(
      (SELECT jsonb_agg(to_jsonb(v.*) ORDER BY v.visita_created_at NULLS LAST)
       FROM visitas_rango v
       JOIN perfiles per ON per.id = v.preventista_id AND per.rol IN ('preventista')),
      '[]'::jsonb
    )
  ) INTO v_result;
  RETURN v_result;
END;
$function$;

-- Los EXECUTE quedan como estaban (CREATE OR REPLACE los conserva): authenticated, sin PUBLIC ni anon.
REVOKE ALL ON FUNCTION public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.obtener_geolocalizacion_preventistas(date,date) FROM PUBLIC, anon;

-- -------------------------------------------------------------------------
-- 5b · Las columnas viejas se van (con sus CHECK y su índice)
-- -------------------------------------------------------------------------
ALTER TABLE public.pedidos
  DROP COLUMN gps_lat,
  DROP COLUMN gps_lng,
  DROP COLUMN gps_accuracy,
  DROP COLUMN gps_capturado_at,
  DROP COLUMN gps_status,
  DROP COLUMN gps_motivo_omision,
  DROP COLUMN gps_diagnostico;

-- -------------------------------------------------------------------------
-- Poscondiciones
-- -------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v text;
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'pedidos' AND column_name LIKE 'gps\_%') THEN
    RAISE EXCEPTION 'mig NNN · poscondición: quedó una columna gps_ en pedidos';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public' AND indexname = 'idx_pedidos_gps_capturado_at')
     OR EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.pedidos'::regclass AND conname LIKE 'pedidos\_gps\_%') THEN
    RAISE EXCEPTION 'mig NNN · poscondición: quedó un índice o un CHECK del GPS en pedidos';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.pedido_gps'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · poscondición: pedido_gps sin RLS';
  END IF;
  SELECT string_agg(grantee || ':' || privilege_type, ',' ORDER BY grantee, privilege_type) INTO v
    FROM information_schema.role_table_grants
   WHERE table_schema = 'public' AND table_name = 'pedido_gps' AND grantee IN ('anon', 'authenticated', 'PUBLIC');
  IF v IS DISTINCT FROM 'authenticated:SELECT' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: los grants REST de pedido_gps quedaron %', v;
  END IF;
  SELECT string_agg(polname || ':' || polcmd::text || ':' || polroles::regrole[]::text, ',' ORDER BY polname) INTO v
    FROM pg_policy WHERE polrelid = 'public.pedido_gps'::regclass;
  IF v IS DISTINCT FROM 'pedido_gps_select_admin:r:{authenticated}' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: las policies de pedido_gps quedaron %', v;
  END IF;
  IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'public.pedido_gps'::regclass AND contype = 'f') <> 1 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: pedido_gps tiene que tener una sola FK (la de pedidos)';
  END IF;

  FOR r IN SELECT * FROM (VALUES
    ('public.registrar_geolocalizacion_pedido(bigint,text,numeric,numeric,numeric,timestamp with time zone,text,jsonb)',
     'ebe0beb601d7c13523cca5d251722cad'),
    ('public.obtener_geolocalizacion_preventistas(date,date)', '035f72c1d1f8b9e9f0c3e45923b3b384')
  ) AS t(fn, h) LOOP
    SELECT md5(prosrc) AS h, (SELECT array_agg(a::text ORDER BY a::text) FROM unnest(proacl) a)::text AS a,
           prosecdef AS def, proconfig::text AS cfg INTO x
      FROM pg_proc WHERE oid = r.fn::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM '{authenticated=X/postgres,postgres=X/postgres,service_role=X/postgres}'
       OR NOT x.def OR x.cfg IS DISTINCT FROM '{"search_path=public, pg_temp"}' THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %, config %)', r.fn, x.h, x.a, x.def, x.cfg;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
       AND proname IN ('registrar_geolocalizacion_pedido', 'obtener_geolocalizacion_preventistas')) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · poscondición: hay más de una firma de las RPC del GPS';
  END IF;
END
$post$;

COMMIT;
