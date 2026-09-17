-- Las firmas del digest pasan de SMALLINT a INTEGER: si no, PostgREST no las encuentra.
--
-- La 261 declaró `bot_digest_destinatarios(SMALLINT, SMALLINT)` y
-- `bot_admin_guardar_config_digest(..., SMALLINT, SMALLINT[], ...)` para que
-- coincidieran con el tipo de las columnas. Error: los tipos de las COLUMNAS y
-- los de los PARÁMETROS no tienen por qué ser el mismo, y Postgres **no** hace
-- el downcast implícito de integer a smallint al resolver una función:
--
--   select bot_digest_destinatarios(7, 1);
--   ERROR 42883: function bot_digest_destinatarios(integer, integer) does not exist
--
-- Del otro lado, todo lo que llega por PostgREST es un número de JSON, o sea
-- integer: la edge function manda `{p_hora: 7, p_dow: 1}` y el panel manda
-- `{p_hora_local: 19, p_dias: [1,2,3]}`. Con las firmas en SMALLINT las dos
-- llamadas fallan en runtime — y ninguno de los dos caminos lo detecta antes:
-- no lo ve `tsc`, no lo ven los tests (que mockean la RPC) y no lo ve
-- `deno task check`. El digest se habría quedado mudo sin que fallara nada.
--
-- Las columnas siguen siendo SMALLINT: el cast va adentro, en el INSERT.
--
-- Se DROPEAN las firmas viejas en vez de dejarlas conviviendo: dos sobrecargas
-- con el mismo número de parámetros obligatorios le dan PGRST203 a PostgREST,
-- que es otro fallo de runtime invisible (ver CLAUDE.md § Trampas 5).

DROP FUNCTION IF EXISTS public.bot_digest_destinatarios(SMALLINT, SMALLINT);
DROP FUNCTION IF EXISTS public.bot_admin_guardar_config_digest(UUID, BOOLEAN, SMALLINT, SMALLINT[], TEXT[]);

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.bot_digest_destinatarios(
  p_hora INTEGER,
  p_dow  INTEGER
)
RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT COALESCE(
    json_agg(
      json_build_object(
        'telegram_user_id', t.telegram_user_id,
        'perfil_id',        t.perfil_id,
        'sucursal_id',      t.sucursal_id,
        'secciones',        t.secciones
      )
      ORDER BY t.telegram_user_id
    ),
    '[]'::json
  )
  FROM (
    SELECT
      bu.telegram_user_id,
      bu.perfil_id,
      bu.sucursal_id,
      -- COALESCE contra los defaults de la tabla: el admin sin fila de config
      -- recibe lo mismo que recibía antes de que la tabla existiera.
      COALESCE(c.activo,      TRUE)                             AS activo,
      COALESCE(c.hora_local,  7::SMALLINT)                      AS hora_local,
      COALESCE(c.dias_semana, ARRAY[1,2,3,4,5,6,7]::SMALLINT[]) AS dias_semana,
      COALESCE(
        c.secciones,
        ARRAY['ventas','top_clientes','stock_critico','deuda','vencimientos']::TEXT[]
      ) AS secciones
    FROM bot_usuarios bu
    JOIN perfiles p ON p.id = bu.perfil_id
    LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
    -- El rol y el alta salen de `perfiles`, no del snapshot de bot_usuarios
    -- (mig 237): el digest le llega a quien HOY es admin.
    WHERE bu.activo AND p.activo AND p.rol = 'admin'
  ) t
  WHERE t.activo
    AND t.hora_local = p_hora::SMALLINT
    AND p_dow::SMALLINT = ANY(t.dias_semana)
    -- Sin secciones no hay mensaje que mandar.
    AND array_length(t.secciones, 1) >= 1;
$fn$;

COMMENT ON FUNCTION public.bot_digest_destinatarios(INTEGER, INTEGER) IS
  'Admins que deben recibir el digest en la hora p_hora del día ISO p_dow (1=lunes). La hora la calcula la edge function en TZ Argentina.';

-- Sólo la llama la edge function con service_role: se revoca a las tres.
REVOKE ALL ON FUNCTION public.bot_digest_destinatarios(INTEGER, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_digest_destinatarios(INTEGER, INTEGER) TO service_role;

-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.bot_admin_guardar_config_digest(
  p_perfil_id  UUID,
  p_activo     BOOLEAN,
  p_hora_local INTEGER,
  p_dias       INTEGER[],
  p_secciones  TEXT[]
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_rol TEXT;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede configurar el digest';
  END IF;

  -- El destinatario tiene que ser un admin vinculado al bot. Sin este chequeo
  -- se podrían crear filas de config para perfiles que nunca van a recibir
  -- nada, y el panel mostraría gente que no está en el bot.
  IF NOT EXISTS (
    SELECT 1 FROM bot_usuarios bu
    JOIN perfiles p ON p.id = bu.perfil_id
    WHERE bu.perfil_id = p_perfil_id AND bu.activo AND p.activo AND p.rol = 'admin'
  ) THEN
    RAISE EXCEPTION 'El perfil % no es un admin vinculado al bot', p_perfil_id;
  END IF;

  INSERT INTO bot_digest_config (
    perfil_id, activo, hora_local, dias_semana, secciones,
    actualizado_at, actualizado_por
  )
  VALUES (
    p_perfil_id, p_activo, p_hora_local::SMALLINT, p_dias::SMALLINT[], p_secciones,
    now(), auth.uid()
  )
  ON CONFLICT (perfil_id) DO UPDATE SET
    activo          = EXCLUDED.activo,
    hora_local      = EXCLUDED.hora_local,
    dias_semana     = EXCLUDED.dias_semana,
    secciones       = EXCLUDED.secciones,
    actualizado_at  = now(),
    actualizado_por = auth.uid();

  RETURN json_build_object('success', true, 'perfil_id', p_perfil_id);
END;
$fn$;

REVOKE ALL ON FUNCTION public.bot_admin_guardar_config_digest(UUID, BOOLEAN, INTEGER, INTEGER[], TEXT[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_guardar_config_digest(UUID, BOOLEAN, INTEGER, INTEGER[], TEXT[])
  TO authenticated;
