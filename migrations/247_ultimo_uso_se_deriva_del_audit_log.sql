-- =========================================================================
-- Migración 247: el último uso se deriva del audit log
--
-- Decisión del dueño (#626). `bot_admin_listar_vinculados()` (mig 237)
-- devolvía `bot_usuarios.ultimo_uso_at` tal cual estaba en la columna, y esa
-- columna nunca se escribe: no hay un solo `UPDATE bot_usuarios SET
-- ultimo_uso_at` en el repo (grep sobre `migrations/`, `src/` y
-- `supabase/functions/` antes de esta migración). El panel de admin mostraba
-- siempre NULL para "último uso".
--
-- `bot_audit_log` sí tiene una fila por mensaje, con `telegram_user_id` y
-- `created_at`, así que el último uso real es `max(created_at)` de ahí. Con
-- 4 filas en `bot_usuarios` y 538 en `bot_audit_log` (medido en prod), un
-- subquery escalar por fila resuelve en <1ms con seq scan sobre las dos
-- tablas (EXPLAIN ANALYZE, sin índice sobre `telegram_user_id`): al volumen
-- de hoy no hace falta ni el índice ni un LEFT JOIN LATERAL.
--
-- No se toca el edge function del bot ni `useBotAdmin.ts`: el tipo
-- `BotVinculado.ultimo_uso_at` sigue siendo `string | null`, solo cambia de
-- dónde sale el valor.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1 · bot_admin_listar_vinculados: ultimo_uso_at sale de bot_audit_log
-- ---------------------------------------------------------------------------
-- Mismo cuerpo que la 237, una sola línea cambiada.

CREATE OR REPLACE FUNCTION public.bot_admin_listar_vinculados()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
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
  LEFT JOIN sucursales s ON s.id = bu.sucursal_id;

  RETURN v_resultado;
END;
$fn$;

COMMENT ON FUNCTION public.bot_admin_listar_vinculados() IS
  'Lista usuarios vinculados al bot Telegram con datos del perfil y sucursal. El rol que devuelve es el VIVO de perfiles, no el snapshot de bot_usuarios.rol (mig 237). ultimo_uso_at es max(bot_audit_log.created_at) por telegram_user_id, no una columna escrita (mig 247, #626). Solo admin (auth.uid() debe tener perfiles.rol = admin). Retorna JSON array ordenado por vinculado_at DESC.';

-- ---------------------------------------------------------------------------
-- 2 · bot_usuarios.ultimo_uso_at deja de existir: nadie más la lee
-- ---------------------------------------------------------------------------

ALTER TABLE public.bot_usuarios DROP COLUMN ultimo_uso_at;

-- ---------------------------------------------------------------------------
-- 3 · Verificación
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_acl  text;
  v_def  text;
BEGIN
  -- La columna se fue de verdad.
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'bot_usuarios'
       AND column_name = 'ultimo_uso_at'
  ) THEN
    RAISE EXCEPTION 'bot_usuarios.ultimo_uso_at sigue existiendo';
  END IF;

  -- La función quedó apuntando a bot_audit_log, no a la columna borrada.
  SELECT pg_get_functiondef(p.oid) INTO v_def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'bot_admin_listar_vinculados';

  IF v_def IS NULL OR v_def NOT LIKE '%FROM bot_audit_log al%' THEN
    RAISE EXCEPTION 'bot_admin_listar_vinculados no quedo leyendo bot_audit_log: %', coalesce(v_def, '(no existe)');
  END IF;
  IF v_def LIKE '%bu.ultimo_uso_at%' THEN
    RAISE EXCEPTION 'bot_admin_listar_vinculados todavia referencia bu.ultimo_uso_at';
  END IF;

  -- El REPLACE no le tenía que tocar los permisos: sigue sin PUBLIC ni anon
  -- (mig 019/237), solo authenticated + el owner.
  SELECT array_to_string(p.proacl, ',') INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'bot_admin_listar_vinculados';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'bot_admin_listar_vinculados quedo con ACL default (= ejecutable por PUBLIC)';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'bot_admin_listar_vinculados quedo ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'bot_admin_listar_vinculados quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=%' THEN
    RAISE EXCEPTION 'bot_admin_listar_vinculados perdio el grant a authenticated: %', v_acl;
  END IF;
END
$verif$;

COMMIT;
