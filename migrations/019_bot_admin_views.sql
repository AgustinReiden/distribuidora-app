-- Migración 019 — Bot Telegram Phase 4 task 4.2: vistas admin de observabilidad
--
-- Las tablas bot_usuarios, bot_audit_log y bot_digests_enviados (creadas en
-- migrations 014/018) tienen RLS habilitada SIN policies amplias: solo el
-- service_role puede leerlas desde el backend del bot.
--
-- Para que la app web (sesión authenticated, rol admin) pueda consumir estas
-- tablas en una vista de observabilidad, exponemos 5 RPCs SECURITY DEFINER que
-- gatean al inicio por `perfiles.rol = 'admin'`. Si la check falla, la RPC
-- lanza excepción y nunca lee datos.
--
-- Patrón uniforme:
--   * SECURITY DEFINER + SET search_path = public.
--   * Bloquear si auth.uid() no resuelve a un perfil con rol='admin'.
--   * REVOKE FROM PUBLIC + GRANT EXECUTE TO authenticated.
--
-- IMPORTANTE: estas RPCs son SOLO de lectura (excepto la 5, que es un toggle
-- de bot_usuarios.activo). NO exponen escritura sobre bot_audit_log ni sobre
-- bot_digests_enviados — la retención la maneja el cron de la migración 016.

-- ============================================================================
-- 1. bot_admin_listar_vinculados — lista de usuarios vinculados al bot
-- ============================================================================
-- JOIN con perfiles + sucursales (ambos LEFT JOIN porque sucursal_id puede
-- ser NULL si el perfil no tiene sucursal default; perfiles es FK NOT NULL
-- pero por seguridad usamos LEFT para no perder rows si el perfil fuera
-- borrado fuera de banda).

CREATE OR REPLACE FUNCTION public.bot_admin_listar_vinculados()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rol TEXT;
  v_resultado JSON;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede listar usuarios vinculados al bot';
  END IF;

  SELECT COALESCE(
    json_agg(
      json_build_object(
        'telegram_user_id',   bu.telegram_user_id,
        'telegram_username',  bu.telegram_username,
        'perfil_id',          bu.perfil_id,
        'perfil_nombre',      p.nombre,
        'perfil_email',       p.email,
        'rol',                bu.rol,
        'sucursal_id',        bu.sucursal_id,
        'sucursal_nombre',    s.nombre,
        'vinculado_at',       bu.vinculado_at,
        'ultimo_uso_at',      bu.ultimo_uso_at,
        'activo',             bu.activo
      )
      ORDER BY bu.vinculado_at DESC
    ),
    '[]'::json
  )
  INTO v_resultado
  FROM bot_usuarios bu
  LEFT JOIN perfiles p   ON p.id = bu.perfil_id
  LEFT JOIN sucursales s ON s.id = bu.sucursal_id;

  RETURN v_resultado;
END;
$$;

ALTER FUNCTION public.bot_admin_listar_vinculados() OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_admin_listar_vinculados() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_admin_listar_vinculados() TO authenticated;

COMMENT ON FUNCTION public.bot_admin_listar_vinculados() IS
  'Lista usuarios vinculados al bot Telegram con datos del perfil y sucursal. Solo admin (auth.uid() debe tener perfiles.rol = admin). Retorna JSON array ordenado por vinculado_at DESC.';

-- ============================================================================
-- 2. bot_admin_audit_log — eventos del bot con filtros y paginación simple
-- ============================================================================
-- Range filter: created_at >= p_desde AND created_at < p_hasta + 1 day
-- (incluye el día p_hasta entero). p_limit clampeado a [1, 1000].
-- Filtros opcionales: tipo (mensaje|comando|tool_call|respuesta|error) y
-- perfil_id. ORDER BY created_at DESC.

CREATE OR REPLACE FUNCTION public.bot_admin_audit_log(
  p_desde     DATE,
  p_hasta     DATE,
  p_tipo      TEXT  DEFAULT NULL,
  p_perfil_id UUID  DEFAULT NULL,
  p_limit     INT   DEFAULT 200
) RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rol       TEXT;
  v_limit     INT;
  v_resultado JSON;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede leer el audit log del bot';
  END IF;

  v_limit := GREATEST(LEAST(COALESCE(p_limit, 200), 1000), 1);

  SELECT COALESCE(
    json_agg(row_to_json(t) ORDER BY t.created_at DESC),
    '[]'::json
  )
  INTO v_resultado
  FROM (
    SELECT
      al.id,
      al.telegram_user_id,
      al.perfil_id,
      p.nombre AS perfil_nombre,
      al.rol,
      al.tipo,
      al.tool_name,
      al.parametros,
      al.resultado_meta,
      al.texto_usuario,
      al.texto_bot,
      al.created_at
    FROM bot_audit_log al
    LEFT JOIN perfiles p ON p.id = al.perfil_id
    WHERE al.created_at >= p_desde
      AND al.created_at <  p_hasta + interval '1 day'
      AND (p_tipo      IS NULL OR al.tipo      = p_tipo)
      AND (p_perfil_id IS NULL OR al.perfil_id = p_perfil_id)
    ORDER BY al.created_at DESC
    LIMIT v_limit
  ) t;

  RETURN v_resultado;
END;
$$;

ALTER FUNCTION public.bot_admin_audit_log(DATE, DATE, TEXT, UUID, INT) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_admin_audit_log(DATE, DATE, TEXT, UUID, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_admin_audit_log(DATE, DATE, TEXT, UUID, INT) TO authenticated;

COMMENT ON FUNCTION public.bot_admin_audit_log(DATE, DATE, TEXT, UUID, INT) IS
  'Eventos del bot Telegram en el rango [p_desde, p_hasta] (inclusive a ambos lados). Filtros opcionales por tipo (mensaje|comando|tool_call|respuesta|error) y perfil_id. p_limit clampeado a [1, 1000], default 200. ORDER BY created_at DESC. Solo admin.';

-- ============================================================================
-- 3. bot_admin_audit_summary — agregados para el dashboard
-- ============================================================================
-- Devuelve: total_eventos, por_tipo (todos), por_perfil (top 10), tools_top
-- (top 10 excluyendo NULL) y errores_recientes (count de tipo='error' en
-- las últimas 24h, independiente del rango — sirve como tarjeta operativa).

CREATE OR REPLACE FUNCTION public.bot_admin_audit_summary(
  p_desde DATE,
  p_hasta DATE
) RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rol               TEXT;
  v_total             BIGINT;
  v_por_tipo          JSON;
  v_por_perfil        JSON;
  v_tools_top         JSON;
  v_errores_recientes BIGINT;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede leer el resumen de auditoría del bot';
  END IF;

  SELECT COUNT(*)
    INTO v_total
    FROM bot_audit_log
   WHERE created_at >= p_desde
     AND created_at <  p_hasta + interval '1 day';

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_por_tipo
    FROM (
      SELECT tipo, COUNT(*)::int AS count
        FROM bot_audit_log
       WHERE created_at >= p_desde
         AND created_at <  p_hasta + interval '1 day'
       GROUP BY tipo
    ) t;

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_por_perfil
    FROM (
      SELECT
        al.perfil_id,
        p.nombre AS perfil_nombre,
        COUNT(*)::int AS count
      FROM bot_audit_log al
      LEFT JOIN perfiles p ON p.id = al.perfil_id
      WHERE al.created_at >= p_desde
        AND al.created_at <  p_hasta + interval '1 day'
        AND al.perfil_id IS NOT NULL
      GROUP BY al.perfil_id, p.nombre
      ORDER BY COUNT(*) DESC
      LIMIT 10
    ) t;

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_tools_top
    FROM (
      SELECT tool_name, COUNT(*)::int AS count
        FROM bot_audit_log
       WHERE created_at >= p_desde
         AND created_at <  p_hasta + interval '1 day'
         AND tool_name IS NOT NULL
       GROUP BY tool_name
       ORDER BY COUNT(*) DESC
       LIMIT 10
    ) t;

  SELECT COUNT(*)
    INTO v_errores_recientes
    FROM bot_audit_log
   WHERE tipo = 'error'
     AND created_at >= now() - interval '24 hours';

  RETURN json_build_object(
    'total_eventos',       v_total,
    'por_tipo',            v_por_tipo,
    'por_perfil',          v_por_perfil,
    'tools_top',           v_tools_top,
    'errores_recientes',   v_errores_recientes
  );
END;
$$;

ALTER FUNCTION public.bot_admin_audit_summary(DATE, DATE) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_admin_audit_summary(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_admin_audit_summary(DATE, DATE) TO authenticated;

COMMENT ON FUNCTION public.bot_admin_audit_summary(DATE, DATE) IS
  'Agregados del audit log del bot en el rango [p_desde, p_hasta]. Retorna total_eventos, por_tipo (todos), por_perfil (top 10), tools_top (top 10 excluyendo NULL) y errores_recientes (count de tipo=error en últimas 24h, independiente del rango). Solo admin.';

-- ============================================================================
-- 4. bot_admin_digests_enviados — histórico de digests con joins
-- ============================================================================

CREATE OR REPLACE FUNCTION public.bot_admin_digests_enviados(
  p_desde DATE,
  p_hasta DATE
) RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rol       TEXT;
  v_resultado JSON;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede leer el histórico de digests del bot';
  END IF;

  SELECT COALESCE(
    json_agg(row_to_json(t) ORDER BY t.fecha DESC, t.sent_at DESC),
    '[]'::json
  )
  INTO v_resultado
  FROM (
    SELECT
      d.admin_perfil_id,
      p.nombre   AS perfil_nombre,
      s.nombre   AS sucursal_nombre,
      d.fecha,
      d.sent_at,
      d.telegram_user_id,
      d.status,
      d.error_meta
    FROM bot_digests_enviados d
    LEFT JOIN perfiles    p ON p.id = d.admin_perfil_id
    LEFT JOIN bot_usuarios bu ON bu.telegram_user_id = d.telegram_user_id
    LEFT JOIN sucursales  s ON s.id = bu.sucursal_id
    WHERE d.fecha >= p_desde
      AND d.fecha <= p_hasta
    ORDER BY d.fecha DESC, d.sent_at DESC
  ) t;

  RETURN v_resultado;
END;
$$;

ALTER FUNCTION public.bot_admin_digests_enviados(DATE, DATE) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_admin_digests_enviados(DATE, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_admin_digests_enviados(DATE, DATE) TO authenticated;

COMMENT ON FUNCTION public.bot_admin_digests_enviados(DATE, DATE) IS
  'Histórico de digests enviados por el bot Telegram en el rango [p_desde, p_hasta] (inclusive). JOIN con perfiles para el nombre del admin y con bot_usuarios+sucursales para el contexto del envío. Order by fecha DESC, sent_at DESC. Solo admin.';

-- ============================================================================
-- 5. bot_admin_toggle_usuario — activar/desactivar un usuario vinculado
-- ============================================================================
-- Cambia bot_usuarios.activo. activo=false bloquea el acceso del usuario al
-- bot sin borrar el row (mantenemos historial de vinculación).

CREATE OR REPLACE FUNCTION public.bot_admin_toggle_usuario(
  p_telegram_user_id BIGINT,
  p_activo           BOOLEAN
) RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rol      TEXT;
  v_filas    INT;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede activar/desactivar usuarios del bot';
  END IF;

  UPDATE bot_usuarios
     SET activo = p_activo
   WHERE telegram_user_id = p_telegram_user_id;

  GET DIAGNOSTICS v_filas = ROW_COUNT;

  IF v_filas = 0 THEN
    RAISE EXCEPTION 'Usuario de bot no encontrado: %', p_telegram_user_id;
  END IF;

  RETURN json_build_object(
    'success',          true,
    'telegram_user_id', p_telegram_user_id,
    'activo',           p_activo
  );
END;
$$;

ALTER FUNCTION public.bot_admin_toggle_usuario(BIGINT, BOOLEAN) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.bot_admin_toggle_usuario(BIGINT, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_admin_toggle_usuario(BIGINT, BOOLEAN) TO authenticated;

COMMENT ON FUNCTION public.bot_admin_toggle_usuario(BIGINT, BOOLEAN) IS
  'Activa/desactiva un usuario vinculado al bot Telegram (UPDATE bot_usuarios.activo). Solo admin. Lanza excepción si el telegram_user_id no existe. Retorna {success, telegram_user_id, activo}.';
