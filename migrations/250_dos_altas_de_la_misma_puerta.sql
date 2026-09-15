-- Migración 250 — dos altas de la misma puerta no son dos clientes (#663)
--
-- El detector de duplicados es por coordenadas EXACTAS (0.000002 grados, ~0,2 m)
-- desde el commit 4f5a6ee. Las coordenadas de un alta salen de dos caminos que
-- nunca dan el mismo punto (autocomplete de Google Places y GPS del teléfono con
-- reverse geocoding), así que dos altas de la misma puerta caen a metros de
-- distancia y el guard no ve nada. Caso testigo: 382 y 938, misma dirección
-- formateada, 17,5 m. Detalle completo en #663 y en migrations/MANIFEST.md.
--
-- Tres reglas, escritas una vez y consumidas por las dos mitades del guard:
--   1. Dirección normalizada CON ALTURA -> bloqueo duro (ataja el 382/938).
--   2. Distancia real en metros: <1 m bloqueo, 1-30 m aviso, >30 m nada.
--   3. Nombre por tokens sin acentos contra razón social Y fantasía, cruzados:
--      igualdad = bloqueo, subconjunto = aviso.
--
-- La versión de referencia es src/utils/duplicadoCliente.ts con sus tests; el
-- bloque DO del final fija los mismos casos en SQL.
--
-- El índice de la regla 1 es NO ÚNICO y tiene que serlo: la clave ya se repite
-- en 19 grupos (38 clientes) de la base, y varios son comercios distintos en la
-- misma puerta. La regla rige el ALTA, no retroactivamente. La consolidación de
-- los duplicados que ya existen es el issue #664.
--
-- Forward-only. No toca ni una fila de `clientes`.

-- ============================================================================
-- 1. El criterio, en piezas IMMUTABLE reutilizables
-- ============================================================================

CREATE OR REPLACE FUNCTION public.clave_direccion_cliente(p_direccion text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
           WHEN v.clave = '' OR v.clave !~ '[0-9]' THEN NULL
           ELSE v.clave
         END
  FROM (
    SELECT trim(regexp_replace(
             lower(f_unaccent(split_part(COALESCE(p_direccion, ''), ',', 1))),
             '[^a-z0-9]+', ' ', 'g')) AS clave
  ) v;
$function$;

COMMENT ON FUNCTION public.clave_direccion_cliente(text) IS
  'Clave normalizada de la dirección de un cliente para detectar duplicados: primer segmento, sin acentos ni puntuación. NULL si no tiene altura (un barrio no es una puerta). Espejo de claveDireccionConAltura() en src/utils/duplicadoCliente.ts.';

CREATE OR REPLACE FUNCTION public.normalizar_nombre_cliente(p_nombre text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT trim(regexp_replace(
           lower(f_unaccent(COALESCE(p_nombre, ''))),
           '[^a-z0-9]+', ' ', 'g'));
$function$;

CREATE OR REPLACE FUNCTION public.tokens_nombre_cliente(p_nombre text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    (SELECT array_agg(DISTINCT t)
       FROM unnest(string_to_array(normalizar_nombre_cliente(p_nombre), ' ')) t
      WHERE t <> ''),
    '{}'::text[]);
$function$;

CREATE OR REPLACE FUNCTION public.relacion_nombre_cliente(p_a text, p_b text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN normalizar_nombre_cliente(p_a) = '' OR normalizar_nombre_cliente(p_b) = ''
      THEN 'distinto'
    WHEN normalizar_nombre_cliente(p_a) = normalizar_nombre_cliente(p_b)
      THEN 'igual'
    WHEN tokens_nombre_cliente(p_a) <@ tokens_nombre_cliente(p_b)
      OR tokens_nombre_cliente(p_b) <@ tokens_nombre_cliente(p_a)
      THEN 'subconjunto'
    ELSE 'distinto'
  END;
$function$;

CREATE OR REPLACE FUNCTION public.relacion_nombres_cliente(
  p_a_razon text, p_a_fantasia text, p_b_razon text, p_b_fantasia text
)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
    WHEN 'igual'       = ANY (x.r) THEN 'igual'
    WHEN 'subconjunto' = ANY (x.r) THEN 'subconjunto'
    ELSE 'distinto'
  END
  FROM (SELECT ARRAY[
          relacion_nombre_cliente(p_a_razon,    p_b_razon),
          relacion_nombre_cliente(p_a_razon,    p_b_fantasia),
          relacion_nombre_cliente(p_a_fantasia, p_b_razon),
          relacion_nombre_cliente(p_a_fantasia, p_b_fantasia)
        ] AS r) x;
$function$;

COMMENT ON FUNCTION public.relacion_nombres_cliente(text, text, text, text) IS
  'Relación entre los nombres de dos clientes cruzando razón social y fantasía de los dos lados: igual (bloqueo) / subconjunto (aviso) / distinto. Espejo de relacionEntre() en src/utils/duplicadoCliente.ts.';

CREATE INDEX IF NOT EXISTS idx_clientes_clave_direccion
  ON public.clientes (sucursal_id, public.clave_direccion_cliente(direccion))
  WHERE public.clave_direccion_cliente(direccion) IS NOT NULL;

-- ============================================================================
-- 2. verificar_duplicado_cliente — la única puerta del guard
-- ============================================================================

CREATE OR REPLACE FUNCTION public.verificar_duplicado_cliente(
  p_latitud          numeric,
  p_longitud         numeric,
  p_direccion        text,
  p_razon_social     text,
  p_nombre_fantasia  text,
  p_excluir_id       bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  c_bloqueo_m constant numeric := 1;
  c_aviso_m   constant numeric := 30;
  c_m_x_grado constant numeric := 111320;

  v_uid       uuid   := auth.uid();
  v_sucursal  bigint := current_sucursal_id();
  v_clave     text   := clave_direccion_cliente(p_direccion);
  v_dlat      numeric;
  v_dlng      numeric;

  -- v_* es el candidato ELEGIDO; t_* es el de la sonda en curso. Van
  -- separados porque un SELECT ... INTO que no encuentra fila pone las
  -- variables en NULL, y sin esto la sonda del nombre borraba el candidato
  -- que ya había encontrado la de distancia.
  v_id        bigint;
  v_nombre    text;
  v_activo    boolean;
  v_dist      numeric;
  t_id        bigint;
  t_nombre    text;
  t_activo    boolean;
  t_dist      numeric;

  v_bloquea   boolean := false;
  v_avisa     boolean := false;
  v_motivo    text;

  v_visible   boolean := true;
  v_es_prev   boolean;
  v_quien     text;
BEGIN
  IF v_uid IS NULL OR v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo verificar duplicados: sin sesión o sin sucursal activa'
      USING ERRCODE = '42501';
  END IF;

  -- ---------- Bloqueo 1: misma dirección con altura -----------------------
  IF v_clave IS NOT NULL THEN
    SELECT c.id,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND clave_direccion_cliente(c.direccion) = v_clave
     ORDER BY c.activo DESC, c.id
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      v_bloquea := true;
      v_motivo  := 'direccion';
    END IF;
  END IF;

  -- ---------- Bloqueo 2 / Aviso 1: el vecino más cercano ------------------
  IF NOT v_bloquea AND p_latitud IS NOT NULL AND p_longitud IS NOT NULL THEN
    -- Prefiltro por box para seguir usando idx_clientes_coordenadas. Se calcula
    -- por eje: un grado de longitud mide menos cuanto más lejos del ecuador
    -- (en Tucumán ~89 km contra los 111 de la latitud). La decisión la toma la
    -- distancia haversine, no el box.
    v_dlat := c_aviso_m / c_m_x_grado;
    v_dlng := c_aviso_m / (c_m_x_grado * GREATEST(cos(radians(p_latitud)), 0.01));

    SELECT c.id,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND c.latitud  IS NOT NULL
       AND c.longitud IS NOT NULL
       AND c.latitud  BETWEEN p_latitud  - v_dlat AND p_latitud  + v_dlat
       AND c.longitud BETWEEN p_longitud - v_dlng AND p_longitud + v_dlng
       AND haversine_m(p_latitud, p_longitud, c.latitud, c.longitud) <= c_aviso_m
     ORDER BY haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      IF v_dist < c_bloqueo_m THEN
        v_bloquea := true;
        v_motivo  := 'punto';
      ELSE
        v_avisa  := true;
        v_motivo := 'distancia';
      END IF;
    END IF;
  END IF;

  -- ---------- Bloqueo 3: mismo nombre exacto ------------------------------
  -- Se evalúa aunque ya haya un aviso por distancia: un bloqueo lo pisa.
  IF NOT v_bloquea THEN
    SELECT c.id,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND relacion_nombres_cliente(p_razon_social, p_nombre_fantasia,
                                    c.razon_social, c.nombre_fantasia) = 'igual'
     ORDER BY c.activo DESC, c.id
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      v_bloquea := true;
      v_avisa   := false;
      v_motivo  := 'nombre_igual';
    END IF;
  END IF;

  -- ---------- Aviso 2: un nombre contenido en el otro ---------------------
  IF NOT v_bloquea AND NOT v_avisa THEN
    SELECT c.id,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND relacion_nombres_cliente(p_razon_social, p_nombre_fantasia,
                                    c.razon_social, c.nombre_fantasia) = 'subconjunto'
     ORDER BY c.activo DESC, c.id
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      v_avisa  := true;
      v_motivo := 'nombre_subconjunto';
    END IF;
  END IF;

  IF NOT v_bloquea AND NOT v_avisa THEN
    RETURN jsonb_build_object(
      'bloquea', false, 'avisa', false, 'motivo', NULL,
      'distancia_m', NULL, 'cliente_visible', NULL);
  END IF;

  -- ---------- ¿Puede el caller ver a ese cliente? -------------------------
  -- Espejo de la policy mt_clientes_select. Si no lo ve, no le decimos quién
  -- es: sería filtrar por la ventana lo que la RLS tapa por la puerta (#543).
  v_es_prev := EXISTS (SELECT 1 FROM perfiles p WHERE p.id = v_uid AND p.rol = 'preventista');

  IF v_es_prev THEN
    SELECT (
        (NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id))
        OR EXISTS (SELECT 1 FROM cliente_preventistas cp
                    WHERE cp.cliente_id = c.id AND cp.preventista_id = v_uid)
      )
      AND (
        NOT c.reservado_admin
        OR EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_uid)
      )
      INTO v_visible
      FROM clientes c
     WHERE c.id = v_id;
  END IF;

  -- ---------- Aviso a administración cuando el vecino está tapado ---------
  IF v_es_prev AND NOT v_visible THEN
    IF NOT EXISTS (
      SELECT 1 FROM notificaciones n
       WHERE n.tipo = 'cliente_duplicado_oculto'
         AND n.entidad_id = v_id
         AND n.created_at > now() - interval '1 day'
    ) THEN
      SELECT p.nombre INTO v_quien FROM perfiles p WHERE p.id = v_uid;

      PERFORM _notificar_sucursal_roles(
        v_sucursal,
        v_uid,
        'cliente_duplicado_oculto',
        CASE WHEN v_bloquea
             THEN 'Alta de cliente bloqueada por duplicado'
             ELSE 'Alta de cliente muy cerca de otro que el preventista no ve' END,
        COALESCE(v_quien, 'Un preventista')
          || ' intentó cargar un cliente que choca con "'
          || COALESCE(v_nombre, 'sin nombre')
          || '" (#' || v_id || '), que no tiene en su cartera'
          || CASE WHEN v_bloquea THEN '. Se bloqueó el alta. '
                  ELSE '. Se le pidió que confirme. ' END
          || 'Puede ser el mismo comercio: si corresponde, asignáselo.',
        'cliente',
        v_id,
        jsonb_build_object(
          'preventista_id', v_uid,
          'motivo', v_motivo,
          'distancia_m', CASE WHEN v_dist IS NULL THEN NULL ELSE round(v_dist, 1) END,
          'latitud', p_latitud,
          'longitud', p_longitud
        )
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'bloquea', v_bloquea,
    'avisa',   v_avisa,
    'motivo',  v_motivo,
    'distancia_m', CASE WHEN v_dist IS NULL THEN NULL ELSE round(v_dist, 1) END,
    'cliente_visible', CASE WHEN v_visible
      THEN jsonb_build_object('id', v_id, 'nombre', v_nombre, 'activo', v_activo)
      ELSE NULL END
  );
END;
$function$;

COMMENT ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, text, text, bigint) IS
  'Única puerta del guard de clientes duplicados. Devuelve {bloquea, avisa, motivo, distancia_m, cliente_visible}. Tres reglas: dirección normalizada con altura (bloqueo), distancia real en metros (<1 m bloqueo, 1-30 m aviso) y nombre por tokens contra razón social y fantasía (igual = bloqueo, subconjunto = aviso). SECURITY DEFINER: ve por encima de la RLS pero no revela la identidad de un cliente que al caller se le tapa; en ese caso le avisa a administración. Fail-closed sin sesión o sin sucursal. Reemplaza a existe_cliente_en_ubicacion (mig 217).';

-- ============================================================================
-- 3. Permisos
-- ============================================================================
REVOKE ALL ON FUNCTION public.clave_direccion_cliente(text)                    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.normalizar_nombre_cliente(text)                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.tokens_nombre_cliente(text)                      FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.relacion_nombre_cliente(text, text)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.relacion_nombres_cliente(text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, text, text, bigint)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.clave_direccion_cliente(text)                    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.normalizar_nombre_cliente(text)                  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tokens_nombre_cliente(text)                      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.relacion_nombre_cliente(text, text)              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.relacion_nombres_cliente(text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, text, text, bigint)
  TO authenticated, service_role;

-- ============================================================================
-- 4. Se va la función vieja (Trampa 5: no dejar las dos conviviendo)
-- ============================================================================
DROP FUNCTION IF EXISTS public.existe_cliente_en_ubicacion(numeric, numeric);

-- ============================================================================
-- 5. Ensayo — los mismos casos que src/utils/duplicadoCliente.test.ts
-- ============================================================================

DO $ensayo$
DECLARE
  c_dir_382 constant text := 'Pje. Vera y Aragon 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina';
  c_dir_938 constant text := 'Pje. Vera y Aragon 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina';
  v_dist numeric;
  v_txt  text;
BEGIN
  -- 1. La clave de dirección
  v_txt := clave_direccion_cliente(c_dir_382);
  IF v_txt IS DISTINCT FROM 'pje vera y aragon 2551' THEN
    RAISE EXCEPTION 'clave_direccion_cliente(382) dio %', COALESCE(v_txt, '<null>');
  END IF;
  IF clave_direccion_cliente(c_dir_938) IS DISTINCT FROM clave_direccion_cliente(c_dir_382) THEN
    RAISE EXCEPTION 'las dos altas del par 382/938 no dan la misma clave de dirección';
  END IF;
  IF clave_direccion_cliente('  Av.   Benjamín   Aráoz  800 , Tucumán') IS DISTINCT FROM 'av benjamin araoz 800' THEN
    RAISE EXCEPTION 'la clave no está colapsando acentos/espacios';
  END IF;

  -- 2. Sin altura NO hay clave: un barrio no es una puerta.
  IF clave_direccion_cliente('B° Esperanza') IS NOT NULL THEN
    RAISE EXCEPTION 'B° Esperanza no debería dar clave: bloquearía 170 clientes de la sucursal 2';
  END IF;
  IF clave_direccion_cliente('B° Sagrado Corazón, Tucumán, Argentina') IS NOT NULL THEN
    RAISE EXCEPTION 'B° Sagrado no debería dar clave';
  END IF;

  -- 3. Los 17,5 metros que el detector de 0,2 m no veía.
  v_dist := haversine_m(-26.8375164, -65.2398268, -26.8375488, -65.2396541);
  IF v_dist < 17 OR v_dist > 18 THEN
    RAISE EXCEPTION 'la distancia 382-938 dio % m, se esperaban ~17,5', round(v_dist, 2);
  END IF;
  IF v_dist <= 1 OR v_dist > 30 THEN
    RAISE EXCEPTION 'los 17,5 m tienen que caer en la banda de aviso (1-30 m)';
  END IF;

  -- 4. Nombres
  IF normalizar_nombre_cliente('López Ricardo ') IS DISTINCT FROM 'lopez ricardo' THEN
    RAISE EXCEPTION 'normalizar_nombre_cliente no saca acento ni espacio final';
  END IF;
  IF relacion_nombre_cliente('López Ricardo ', 'Lopez Ricardo') <> 'igual' THEN
    RAISE EXCEPTION '"López Ricardo " contra "Lopez Ricardo" tiene que ser igual (bloqueo)';
  END IF;
  IF relacion_nombre_cliente('Ricardo', 'Lopez Ricardo') <> 'subconjunto' THEN
    RAISE EXCEPTION '"Ricardo" dentro de "Lopez Ricardo" tiene que ser subconjunto (aviso)';
  END IF;
  IF relacion_nombre_cliente('Kiosco', 'Kiosco Juan') <> 'subconjunto' THEN
    RAISE EXCEPTION '"Kiosco" dentro de "Kiosco Juan" no puede ser bloqueo';
  END IF;
  IF relacion_nombre_cliente('Panadería Nahuel', 'Pollería M&G') <> 'distinto' THEN
    RAISE EXCEPTION 'dos nombres sin relación tienen que dar distinto';
  END IF;
  IF relacion_nombre_cliente('', 'Lopez Ricardo') <> 'distinto' THEN
    RAISE EXCEPTION 'un nombre vacío no relaciona con nada';
  END IF;

  -- 5. El cruce razón social × fantasía: el 938 se delata por la fantasía.
  IF relacion_nombres_cliente('Ricardo', 'López Ricardo ',
                              'Lopez Ricardo', 'PASAJE VERA Y ARAGON 2551') <> 'igual' THEN
    RAISE EXCEPTION 'el cruce fantasía-938 × razón-382 tiene que dar igual';
  END IF;
  IF relacion_nombres_cliente('Ricardo', NULL, 'Lopez Ricardo', NULL) <> 'subconjunto' THEN
    RAISE EXCEPTION 'sólo "Ricardo" contra "Lopez Ricardo" tiene que avisar, no bloquear';
  END IF;

  RAISE NOTICE 'Ensayo del criterio de duplicados: OK';
END;
$ensayo$;
