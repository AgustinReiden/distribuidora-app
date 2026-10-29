-- 404 · El admin gestiona los usuarios, los bots y los descuentos de SUS
-- sucursales (#1244, SEG-2).
--
-- El admin ya se acotaba en el front (fetchUsuarios) y en
-- asignar_usuario_sucursal, pero no en tres piezas de la base:
--   · perfiles: perfiles_select_admin USING (es_admin()) y "Perfiles:
--     actualizacion propio o admin" USING (id = auth.uid() OR es_admin()). El
--     admin de Taco Pozo desactivaba o degradaba por REST a un usuario de
--     Tucumán, y perfiles_sync_acceso_auth lo baneaba y le borraba las sesiones.
--   · bot_admin_listar_vinculados / _toggle_usuario / _audit_log (y sus dos
--     hermanas de la misma pantalla, _audit_summary y _digests_enviados): sólo
--     miraban rol = 'admin'. Listaban los telegram_user_id y los emails de todas
--     las sucursales, apagaban bots ajenos y leían sus textos.
--   · cliente_descuentos_categoria: cdc_insert WITH CHECK (es_admin()) y
--     cdc_delete USING (es_admin()). Un descuento cargado por id a un cliente de
--     otra sucursal le bajaba el piso de precio_fuera_de_politica.
--
-- La regla (decisión del dueño, 2026-10-28):
--   · VER a un usuario: alcanza con compartir una sucursal con él
--     (admin_comparte_sucursal_con).
--   · CAMBIARLE el rol o el estado activo, o el bot: el admin tiene que estar en
--     TODAS las sucursales del usuario (admin_abarca_sucursales_de). El rol y el
--     activo valen para todas, así que el admin de Taco Pozo no puede desactivar
--     a quien también trabaja en Tucumán. Hoy eso deja la gestión de los
--     usuarios de las dos sucursales a los admins de las dos.
--   · Un descuento por categoría es de un cliente de la sucursal activa, como ya
--     lo leía cdc_select.
-- Efecto visible: el admin de una sola sucursal deja de ver el nombre de quien
-- creó o resolvió una transferencia desde la otra (el "por Fulano" de
-- /transferencias), igual que el encargado hoy. La pantalla ya lo tolera.
--
-- El gate scripts/check-rama-admin.mjs falla ante una policy cuya rama admin no
-- mira la sucursal.

-- ------------------------------------------------------------------ helpers ---
-- SECURITY DEFINER porque los evalúan las policies de perfiles como el usuario:
-- leer usuario_sucursales con RLS desde ahí recursa (su policy lee perfiles).
-- Dan false para quien no es admin, así que no le cuentan nada a nadie que la
-- tabla no le muestre.

CREATE OR REPLACE FUNCTION public.admin_comparte_sucursal_con(p_usuario_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT es_admin()
     AND EXISTS (
       SELECT 1
         FROM usuario_sucursales us_u
         JOIN usuario_sucursales us_a
           ON us_a.sucursal_id = us_u.sucursal_id AND us_a.usuario_id = auth.uid()
        WHERE us_u.usuario_id = p_usuario_id
     );
$function$;

CREATE OR REPLACE FUNCTION public.admin_abarca_sucursales_de(p_usuario_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  -- Comparte al menos una (un usuario sin sucursales no es de nadie) y no tiene
  -- ninguna que no sea del admin.
  SELECT es_admin()
     AND EXISTS (
       SELECT 1
         FROM usuario_sucursales us_u
         JOIN usuario_sucursales us_a
           ON us_a.sucursal_id = us_u.sucursal_id AND us_a.usuario_id = auth.uid()
        WHERE us_u.usuario_id = p_usuario_id
     )
     AND NOT EXISTS (
       SELECT 1
         FROM usuario_sucursales us_u
        WHERE us_u.usuario_id = p_usuario_id
          AND NOT EXISTS (
            SELECT 1 FROM usuario_sucursales us_a
             WHERE us_a.usuario_id = auth.uid() AND us_a.sucursal_id = us_u.sucursal_id
          )
     );
$function$;

-- Las evalúan las policies como el usuario: authenticated las necesita.
REVOKE EXECUTE ON FUNCTION public.admin_comparte_sucursal_con(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_abarca_sucursales_de(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_comparte_sucursal_con(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_abarca_sucursales_de(uuid) TO authenticated;


-- ----------------------------------------------------------------- perfiles ---
DROP POLICY IF EXISTS perfiles_select_admin ON public.perfiles;
CREATE POLICY perfiles_select_admin ON public.perfiles
  FOR SELECT TO authenticated
  USING (es_admin() AND admin_comparte_sucursal_con(id));

-- La rama propia ya la tiene perfiles_update_self (USING y WITH CHECK
-- id = auth.uid()); ésta queda sólo para el admin.
DROP POLICY IF EXISTS "Perfiles: actualizacion propio o admin" ON public.perfiles;
DROP POLICY IF EXISTS perfiles_update_admin ON public.perfiles;
CREATE POLICY perfiles_update_admin ON public.perfiles
  FOR UPDATE TO authenticated
  USING (es_admin() AND admin_abarca_sucursales_de(id))
  WITH CHECK (es_admin() AND admin_abarca_sucursales_de(id));


-- --------------------------------------------- cliente_descuentos_categoria ---
DROP POLICY IF EXISTS cdc_insert ON public.cliente_descuentos_categoria;
CREATE POLICY cdc_insert ON public.cliente_descuentos_categoria
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND cliente_de_sucursal_activa(cliente_id));

DROP POLICY IF EXISTS cdc_delete ON public.cliente_descuentos_categoria;
CREATE POLICY cdc_delete ON public.cliente_descuentos_categoria
  FOR DELETE TO authenticated
  USING (es_admin() AND cliente_de_sucursal_activa(cliente_id));


-- ---------------------------------------------------------------- bot_admin ---
CREATE OR REPLACE FUNCTION public.bot_admin_listar_vinculados()
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        -- Vivo, no el snapshot de bu.rol (mig 237).
        'rol',                p.rol,
        'sucursal_id',        bu.sucursal_id,
        'sucursal_nombre',    s.nombre,
        'vinculado_at',       bu.vinculado_at,
        -- Mig 247: derivado de bot_audit_log, no un snapshot escrito. La
        -- columna vieja nunca se escribía y siempre daba NULL.
        'ultimo_uso_at',      (
          SELECT max(al.created_at)
            FROM bot_audit_log al
           WHERE al.telegram_user_id = bu.telegram_user_id
        ),
        'activo',             bu.activo
      )
      ORDER BY bu.vinculado_at DESC
    ),
    '[]'::json
  )
  INTO v_resultado
  FROM bot_usuarios bu
  LEFT JOIN perfiles p   ON p.id = bu.perfil_id
  LEFT JOIN sucursales s ON s.id = bu.sucursal_id
  -- #1244: los de sus sucursales.
  WHERE admin_comparte_sucursal_con(bu.perfil_id);

  RETURN v_resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_admin_toggle_usuario(p_telegram_user_id bigint, p_activo boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rol      TEXT;
  v_filas    INT;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede activar/desactivar usuarios del bot';
  END IF;

  -- #1244: como el activo del perfil, lo cambia un admin de todas las
  -- sucursales del usuario.
  UPDATE bot_usuarios
     SET activo = p_activo
   WHERE telegram_user_id = p_telegram_user_id
     AND admin_abarca_sucursales_de(perfil_id);

  GET DIAGNOSTICS v_filas = ROW_COUNT;

  IF v_filas = 0 THEN
    IF EXISTS (SELECT 1 FROM bot_usuarios
                WHERE telegram_user_id = p_telegram_user_id
                  AND admin_comparte_sucursal_con(perfil_id)) THEN
      RAISE EXCEPTION 'Ese usuario también trabaja en sucursales que no son tuyas: su bot lo activa o lo desactiva un admin de todas ellas';
    END IF;
    RAISE EXCEPTION 'Usuario de bot no encontrado: %', p_telegram_user_id;
  END IF;

  RETURN json_build_object(
    'success',          true,
    'telegram_user_id', p_telegram_user_id,
    'activo',           p_activo
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_admin_audit_log(p_desde date, p_hasta date, p_tipo text DEFAULT NULL::text, p_perfil_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 200)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- mig 245 (#639) · created_at es timestamptz y p_desde/p_hasta son DATE:
    -- Postgres los promovia a medianoche UTC y el rango cortaba el dia tres
    -- horas tarde. Mismo corte por dia argentino que mermas_valorizadas (238).
    WHERE (al.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
      AND (p_tipo      IS NULL OR al.tipo      = p_tipo)
      AND (p_perfil_id IS NULL OR al.perfil_id = p_perfil_id)
      -- #1244: los de sus sucursales.
      AND admin_comparte_sucursal_con(al.perfil_id)
    ORDER BY al.created_at DESC
    LIMIT v_limit
  ) t;

  RETURN v_resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_admin_audit_summary(p_desde date, p_hasta date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- #1244: todo el resumen cuenta sólo los eventos de sus sucursales, los
  -- mismos que lista bot_admin_audit_log.
  SELECT COUNT(*)
    INTO v_total
    FROM bot_audit_log
   -- mig 245 (#639) · corte por dia argentino, como en bot_admin_audit_log.
   WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
     AND admin_comparte_sucursal_con(perfil_id);

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_por_tipo
    FROM (
      SELECT tipo, COUNT(*)::int AS count
        FROM bot_audit_log
       WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
         AND admin_comparte_sucursal_con(perfil_id)
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
      WHERE (al.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
        AND al.perfil_id IS NOT NULL
        AND admin_comparte_sucursal_con(al.perfil_id)
      GROUP BY al.perfil_id, p.nombre
      ORDER BY COUNT(*) DESC
      LIMIT 10
    ) t;

  SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.count DESC), '[]'::json)
    INTO v_tools_top
    FROM (
      SELECT tool_name, COUNT(*)::int AS count
        FROM bot_audit_log
       WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
         AND tool_name IS NOT NULL
         AND admin_comparte_sucursal_con(perfil_id)
       GROUP BY tool_name
       ORDER BY COUNT(*) DESC
       LIMIT 10
    ) t;

  SELECT COUNT(*)
    INTO v_errores_recientes
    FROM bot_audit_log
   WHERE tipo = 'error'
     AND created_at >= now() - interval '24 hours'
     AND admin_comparte_sucursal_con(perfil_id);

  RETURN json_build_object(
    'total_eventos',       v_total,
    'por_tipo',            v_por_tipo,
    'por_perfil',          v_por_perfil,
    'tools_top',           v_tools_top,
    'errores_recientes',   v_errores_recientes
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.bot_admin_digests_enviados(p_desde date, p_hasta date)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- #1244: los digests de los usuarios de sus sucursales.
      AND admin_comparte_sucursal_con(d.admin_perfil_id)
    ORDER BY d.fecha DESC, d.sent_at DESC
  ) t;

  RETURN v_resultado;
END;
$function$;


-- ------------------------------------------------- lo que lee el gate nuevo ---
-- scripts/check-rama-admin.mjs: las policies permisivas de public con su
-- expresión. La decisión (qué rama es de admin y si mira la sucursal) la toma
-- el script, que tiene tests (src/test/acceso.test.ts).
CREATE OR REPLACE FUNCTION public.auditoria_rama_admin()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT jsonb_build_object(
    'generado_at', now(),
    'politicas', COALESCE(jsonb_agg(jsonb_build_object(
        'tabla',             p.tablename,
        'policy',            p.policyname,
        'cmd',               p.cmd,
        'using',             p.qual,
        'check',             p.with_check,
        'tiene_sucursal_id', EXISTS (
          SELECT 1 FROM information_schema.columns c
           WHERE c.table_schema = 'public' AND c.table_name = p.tablename
             AND c.column_name = 'sucursal_id')
      ) ORDER BY p.tablename, p.policyname), '[]'::jsonb)
  )
  FROM pg_policies p
  WHERE p.schemaname = 'public'
    -- Una RESTRICTIVE se suma con AND: su rama admin no abre nada.
    AND p.permissive = 'PERMISSIVE';
$function$;

REVOKE EXECUTE ON FUNCTION public.auditoria_rama_admin() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_rama_admin() TO service_role;
