-- El guard de duplicados ya no recibe nombres (#688)
--
-- La 260 sacó el nombre del criterio de `verificar_duplicado_cliente` pero dejó
-- `p_razon_social` y `p_nombre_fantasia` en la firma, con DEFAULT NULL e
-- ignorados: dropearlos cambiaba la firma, y un bundle viejo del PWA que todavía
-- los mandaba se habría comido un PGRST202 justo en el guard, que es
-- fail-closed —ese usuario no podía dar de alta clientes hasta recargar—.
--
-- Pasaron tres semanas desde la 260 (16/09): ya no quedan bundles viejos. Acá
-- se va la firma de seis y nace la de cuatro, en la misma migración: DROP de la
-- vieja y CREATE de la nueva, NUNCA las dos conviviendo, porque dos sobrecargas
-- con rangos de parámetros superpuestos son PGRST203 en runtime, invisible para
-- tsc y para los tests (trampa 5 de CLAUDE.md). El front nuevo ya llamaba sin
-- los dos nombres desde la 260; ahora además deja de declararlos.
--
-- El cuerpo es el de la 260 tal cual, sin el comentario que explicaba por qué
-- los nombres seguían en la firma. Criterio, reglas y visibilidad no se tocan.
--
-- Permisos: es una RPC que llama el front, así que vuelve a nacer con EXECUTE
-- para PUBLIC y anon —es una función nueva— y se revocan las dos mitades acá
-- mismo; queda sólo `authenticated` (y service_role).
--
-- Forward-only. No toca ni una fila.

DROP FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, text, text, bigint);

CREATE FUNCTION public.verificar_duplicado_cliente(
  p_latitud    numeric,
  p_longitud   numeric,
  p_direccion  text,
  p_excluir_id bigint DEFAULT NULL
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

  -- v_* es el candidato ELEGIDO; t_* es el de la sonda en curso. Van separados
  -- porque un SELECT ... INTO que no encuentra fila pone las variables en NULL,
  -- y sin esto una sonda vacía borraba el candidato que ya había encontrado la
  -- anterior.
  --
  -- v_codigo es `clientes.codigo`, el número que la app muestra y por el que
  -- busca. v_id es el interno: sirve para la FK de la notificación, nunca para
  -- imprimir (#685).
  v_id        bigint;
  v_codigo    integer;
  v_nombre    text;
  v_activo    boolean;
  v_dist      numeric;
  t_id        bigint;
  t_codigo    integer;
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
    SELECT c.id, c.codigo,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_codigo, t_nombre, t_activo, t_dist
      FROM clientes c
     WHERE c.sucursal_id = v_sucursal
       AND (p_excluir_id IS NULL OR c.id <> p_excluir_id)
       AND clave_direccion_cliente(c.direccion) = v_clave
     ORDER BY c.activo DESC, c.id
     LIMIT 1;

    IF FOUND THEN
      v_id := t_id; v_codigo := t_codigo; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      v_bloquea := true;
      v_motivo  := 'direccion';
    END IF;
  END IF;

  -- ---------- Bloqueo 2 / Aviso: el vecino más cercano --------------------
  IF NOT v_bloquea AND p_latitud IS NOT NULL AND p_longitud IS NOT NULL THEN
    v_dlat := c_aviso_m / c_m_x_grado;
    v_dlng := c_aviso_m / (c_m_x_grado * GREATEST(cos(radians(p_latitud)), 0.01));

    SELECT c.id, c.codigo,
           COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social),
           c.activo,
           haversine_m(p_latitud, p_longitud, c.latitud, c.longitud)
      INTO t_id, t_codigo, t_nombre, t_activo, t_dist
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
      v_id := t_id; v_codigo := t_codigo; v_nombre := t_nombre; v_activo := t_activo; v_dist := t_dist;
      IF v_dist < c_bloqueo_m THEN
        v_bloquea := true;
        v_motivo  := 'punto';
      ELSE
        v_avisa  := true;
        v_motivo := 'distancia';
      END IF;
    END IF;
  END IF;

  IF NOT v_bloquea AND NOT v_avisa THEN
    RETURN jsonb_build_object(
      'bloquea', false, 'avisa', false, 'motivo', NULL,
      'distancia_m', NULL, 'cliente_visible', NULL);
  END IF;

  -- ---------- ¿Puede el caller ver a ese cliente? -------------------------
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
          || '" (#' || v_codigo || '), que no tiene en su cartera'
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
      THEN jsonb_build_object('id', v_id, 'codigo', v_codigo, 'nombre', v_nombre, 'activo', v_activo)
      ELSE NULL END
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, bigint) TO authenticated, service_role;

COMMENT ON FUNCTION public.verificar_duplicado_cliente(numeric, numeric, text, bigint) IS
  'Única puerta del guard de clientes duplicados. Devuelve {bloquea, avisa, motivo, distancia_m, cliente_visible{id, codigo, nombre, activo}}. DOS reglas, las dos sobre el LUGAR: dirección normalizada con altura (bloqueo) y distancia real en metros (<1 m bloqueo, 1-30 m aviso). El nombre NO es parte del criterio desde la mig 260: marcaba homónimos, no duplicados; desde #688 tampoco está en la firma. El número que se le muestra al usuario es codigo, no id. SECURITY DEFINER: ve por encima de la RLS pero no revela la identidad de un cliente que al caller se le tapa; en ese caso le avisa a administración. Fail-closed sin sesión o sin sucursal.';

-- ============================================================================
-- Ensayo
-- ============================================================================
-- La RPC exige sesión, así que el chequeo es estructural: una sola sobrecarga,
-- la de cuatro, sin nombres, con las dos reglas del lugar y sin anon.
DO $ensayo$
DECLARE
  v_sobrecargas int;
  v_firma       text;
  d             text;
BEGIN
  SELECT count(*), max(p.oid::regprocedure::text) INTO v_sobrecargas, v_firma
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname = 'verificar_duplicado_cliente';
  IF v_sobrecargas <> 1 THEN
    RAISE EXCEPTION 'verificar_duplicado_cliente tiene % sobrecargas: PGRST203 (#688)', v_sobrecargas;
  END IF;
  IF v_firma <> 'verificar_duplicado_cliente(numeric,numeric,text,bigint)' THEN
    RAISE EXCEPTION 'firma inesperada: % (#688)', v_firma;
  END IF;

  d := pg_get_functiondef('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)'::regprocedure);
  IF position('p_razon_social' IN d) > 0 OR position('p_nombre_fantasia' IN d) > 0 THEN
    RAISE EXCEPTION 'el guard todavía menciona los parámetros de nombre (#688)';
  END IF;
  IF position($m$'direccion'$m$ IN d) = 0 OR position($m$'punto'$m$ IN d) = 0
     OR position($m$'distancia'$m$ IN d) = 0
     OR position('clave_direccion_cliente' IN d) = 0 OR position('haversine_m' IN d) = 0 THEN
    RAISE EXCEPTION 'se perdió alguna de las dos reglas que miran el lugar (#688)';
  END IF;

  IF has_function_privilege('anon', 'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar el guard (#688)';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.verificar_duplicado_cliente(numeric,numeric,text,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated no puede ejecutar el guard: el alta de clientes queda bloqueada (#688)';
  END IF;
END
$ensayo$;
