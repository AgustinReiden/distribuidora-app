-- Migración 251 — el guard de duplicados contesta rápido (#663)
--
-- Medido justo después de aplicar la 250: el peor caso —un alta que NO choca
-- con nada— tardaba 7,25 segundos. Es el guard del botón Guardar: inaceptable.
--
-- La causa: las dos sondas de nombre llamaban `relacion_nombres_cliente` FILA
-- POR FILA sobre los ~740 clientes de la sucursal. Esa función hace cuatro
-- cruces, cada uno con dos normalizaciones y dos tokenizaciones, y cada
-- tokenización volvía a normalizar: ~24 regexp+unaccent por fila, por sonda.
-- Y con `SET search_path` ninguna se puede inlinear.
--
-- Esta migración no cambia NI UN criterio. Cambia cómo se evalúa:
--   1. `tokens_nombre_cliente` deja de hacer un array_agg(DISTINCT) con
--      subconsulta. Para `<@` los repetidos dan igual, así que un
--      string_to_array pelado alcanza y cuesta una fracción.
--   2. Las dos sondas precalculan el lado del que se está cargando UNA vez y
--      comparan con predicados baratos por fila, en vez de llamar a
--      `relacion_nombres_cliente` por fila.
--   3. Dos índices funcionales sobre el nombre normalizado, para que la sonda
--      de igualdad sea un index scan y no un seq scan.
--
-- `relacion_nombres_cliente` SIGUE siendo la forma legible del criterio y la
-- que usa el ensayo. El riesgo de que la versión rápida y la legible se
-- separen lo cubre el bloque DO del final, que las compara sobre los mismos
-- pares.
--
-- Forward-only. No toca ni una fila de `clientes`.

-- ============================================================================
-- 1. tokens_nombre_cliente sin el agregado
-- ============================================================================
-- El DISTINCT era decorativo: `a <@ b` no cambia si `a` trae repetidos, y el
-- lado TypeScript compara con `every(includes)`, que tampoco.
CREATE OR REPLACE FUNCTION public.tokens_nombre_cliente(p_nombre text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE
           WHEN normalizar_nombre_cliente(p_nombre) = '' THEN '{}'::text[]
           ELSE string_to_array(normalizar_nombre_cliente(p_nombre), ' ')
         END;
$function$;

-- ¿Uno de los dos conjuntos de tokens está contenido en el otro? Dos conjuntos
-- iguales también cuentan; la igualdad exacta ya la atajó la sonda anterior.
CREATE OR REPLACE FUNCTION public.tokens_se_contienen(p_a text[], p_b text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT p_a IS NOT NULL AND p_b IS NOT NULL
     AND cardinality(p_a) > 0 AND cardinality(p_b) > 0
     AND (p_a <@ p_b OR p_b <@ p_a);
$function$;

REVOKE ALL ON FUNCTION public.tokens_se_contienen(text[], text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.tokens_se_contienen(text[], text[]) TO authenticated, service_role;

-- ============================================================================
-- 2. Índices para la sonda de igualdad de nombre
-- ============================================================================
-- Los idx_clientes_unaccent_* que ya existían no sirven acá: normalizan con
-- lower(f_unaccent(...)) pero NO colapsan puntuación ni espacios, que es
-- justamente lo que hace que "López Ricardo " y "Lopez Ricardo" sean el mismo.
CREATE INDEX IF NOT EXISTS idx_clientes_nombre_norm_razon
  ON public.clientes (sucursal_id, public.normalizar_nombre_cliente(razon_social));

CREATE INDEX IF NOT EXISTS idx_clientes_nombre_norm_fantasia
  ON public.clientes (sucursal_id, public.normalizar_nombre_cliente(nombre_fantasia));

-- ============================================================================
-- 3. El guard, con las dos sondas de nombre reescritas
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

  -- El lado del que se está cargando, calculado UNA vez. Las sondas de nombre
  -- comparan contra esto en vez de llamar a relacion_nombres_cliente por fila.
  v_norms     text[];
  v_tok_r     text[] := tokens_nombre_cliente(p_razon_social);
  v_tok_f     text[] := tokens_nombre_cliente(p_nombre_fantasia);

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

  v_norms := ARRAY(
    SELECT n FROM unnest(ARRAY[
      normalizar_nombre_cliente(p_razon_social),
      normalizar_nombre_cliente(p_nombre_fantasia)
    ]) n WHERE n <> ''
  );

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
  -- Equivale a relacion_nombres_cliente(...) = 'igual', pero como igualdad
  -- contra los dos nombres normalizados del que se carga: así entra por
  -- idx_clientes_nombre_norm_* en vez de recorrer la sucursal entera.
  -- Se evalúa aunque ya haya un aviso por distancia: un bloqueo lo pisa.
  IF NOT v_bloquea AND cardinality(v_norms) > 0 THEN
    SELECT c.id,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND (normalizar_nombre_cliente(c.razon_social)    = ANY (v_norms)
         OR normalizar_nombre_cliente(c.nombre_fantasia) = ANY (v_norms))
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
  -- Equivale a relacion_nombres_cliente(...) = 'subconjunto'. El LATERAL
  -- tokeniza cada fila UNA vez para los cuatro cruces.
  IF NOT v_bloquea AND NOT v_avisa
     AND (cardinality(v_tok_r) > 0 OR cardinality(v_tok_f) > 0) THEN
    SELECT c.id,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_nombre, t_activo, t_dist
      FROM clientes c
      CROSS JOIN LATERAL (
        SELECT tokens_nombre_cliente(c.razon_social)    AS tr,
               tokens_nombre_cliente(c.nombre_fantasia) AS tf
      ) t
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND (tokens_se_contienen(v_tok_r, t.tr)
         OR tokens_se_contienen(v_tok_r, t.tf)
         OR tokens_se_contienen(v_tok_f, t.tr)
         OR tokens_se_contienen(v_tok_f, t.tf))
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

-- ============================================================================
-- 4. Ensayo — la versión rápida y la legible tienen que coincidir
-- ============================================================================
-- El riesgo que abre esta migración es que el predicado rápido de las sondas y
-- `relacion_nombres_cliente` se separen. Esto los compara sobre los mismos
-- pares, incluidos los casos reales del 382/938.
DO $ensayo$
DECLARE
  v_pares constant text[][] := ARRAY[
    ARRAY['López Ricardo ', 'Lopez Ricardo'],
    ARRAY['Ricardo',        'Lopez Ricardo'],
    ARRAY['Kiosco',         'Kiosco Juan'],
    ARRAY['Kiosco Juan',    'Kiosco'],
    ARRAY['Panadería Nahuel', 'Pollería M&G'],
    ARRAY['',               'Lopez Ricardo'],
    ARRAY['Almacén Ramón ', 'Ramon'],
    ARRAY['CRECER TUCUMAN', 'Crecer Tucumán']
  ];
  v_a text;
  v_b text;
  v_rel text;
  v_rapido text;
  i int;
BEGIN
  FOR i IN 1 .. array_length(v_pares, 1) LOOP
    v_a := v_pares[i][1];
    v_b := v_pares[i][2];
    v_rel := relacion_nombre_cliente(v_a, v_b);

    -- El mismo criterio, escrito como lo evalúan las sondas.
    v_rapido := CASE
      WHEN normalizar_nombre_cliente(v_a) = '' OR normalizar_nombre_cliente(v_b) = ''
        THEN 'distinto'
      WHEN normalizar_nombre_cliente(v_a) = normalizar_nombre_cliente(v_b)
        THEN 'igual'
      WHEN tokens_se_contienen(tokens_nombre_cliente(v_a), tokens_nombre_cliente(v_b))
        THEN 'subconjunto'
      ELSE 'distinto'
    END;

    IF v_rel <> v_rapido THEN
      RAISE EXCEPTION 'el criterio legible y el rápido no coinciden en (%, %): % vs %',
        v_a, v_b, v_rel, v_rapido;
    END IF;
  END LOOP;

  -- Y los casos del incidente siguen dando lo mismo que en la 250.
  IF relacion_nombre_cliente('López Ricardo ', 'Lopez Ricardo') <> 'igual' THEN
    RAISE EXCEPTION 'regresión: "López Ricardo " ya no es igual a "Lopez Ricardo"';
  END IF;
  IF relacion_nombre_cliente('Ricardo', 'Lopez Ricardo') <> 'subconjunto' THEN
    RAISE EXCEPTION 'regresión: "Ricardo" ya no es subconjunto de "Lopez Ricardo"';
  END IF;
  IF tokens_nombre_cliente('') <> '{}'::text[] THEN
    RAISE EXCEPTION 'tokens_nombre_cliente('''') tiene que dar el array vacío';
  END IF;

  RAISE NOTICE 'Ensayo de equivalencia rápido/legible: OK';
END;
$ensayo$;
