-- El digest deja de ser uno solo para todos: cada admin elige qué recibe y cuándo.
--
-- Hasta acá el digest ejecutivo salía igual para los cuatro admins vinculados,
-- todos los días a las 07:00, con las mismas secciones fijas en el prompt. Esta
-- migración le pone una fila de configuración por persona y mueve la decisión de
-- "a quién le toca ahora" a SQL, que es donde se puede verificar.
--
-- Tres piezas:
--   * bot_digest_config      — una fila por perfil. LA FILA ES OPCIONAL: quien no
--                              tiene una recibe el default, que es exactamente lo
--                              que recibía antes. Por eso no hay backfill, y un
--                              admin que se vincule mañana arranca como hoy.
--   * bot_digest_destinatarios(hora, dow) — quién recibe en esta hora. La llama la
--                              edge function con service_role, una vez por hora.
--   * bot_admin_{listar,guardar}_config_digest — el panel de Bot Telegram.
--
-- La hora y el día de la semana los calcula la edge function (ya tiene la lógica
-- de TZ Argentina en `ayerEnArgentina`) y los pasa como parámetros: una sola
-- fuente de verdad para "qué hora es en Argentina", y estas funciones quedan
-- puras y testeables con cualquier hora.

-- ---------------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.bot_digest_config (
  perfil_id        UUID PRIMARY KEY REFERENCES public.perfiles(id) ON DELETE CASCADE,

  -- false = no recibe digest. Distinto de bot_usuarios.activo, que corta TODO
  -- el bot para esa persona: acá sigue pudiendo chatear con el bot, sólo no
  -- quiere el resumen automático de la mañana.
  activo           BOOLEAN NOT NULL DEFAULT TRUE,

  -- Hora local Argentina (0..23) a la que quiere recibirlo.
  hora_local       SMALLINT NOT NULL DEFAULT 7,

  -- Días ISO: 1 = lunes … 7 = domingo. Coincide con EXTRACT(ISODOW).
  dias_semana      SMALLINT[] NOT NULL DEFAULT ARRAY[1,2,3,4,5,6,7]::SMALLINT[],

  -- Secciones que entran al mensaje. El default es el juego exacto que armaba
  -- el prompt antes de esta migración — nadie nota el cambio hasta que toca el
  -- panel.
  secciones        TEXT[] NOT NULL DEFAULT ARRAY[
                     'ventas','top_clientes','stock_critico','deuda','vencimientos'
                   ]::TEXT[],

  actualizado_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  actualizado_por  UUID REFERENCES public.perfiles(id),

  CONSTRAINT bot_digest_config_hora_ck
    CHECK (hora_local BETWEEN 0 AND 23),

  -- Al menos un día, y ninguno fuera de 1..7. Un array vacío sería "activo pero
  -- nunca" — que es lo mismo que activo = false y se presta a confusión.
  CONSTRAINT bot_digest_config_dias_ck
    CHECK (
      array_length(dias_semana, 1) BETWEEN 1 AND 7
      AND dias_semana <@ ARRAY[1,2,3,4,5,6,7]::SMALLINT[]
    ),

  -- Lista blanca de secciones. Va como CHECK y no como tabla de catálogo
  -- porque el otro extremo de esta lista es un mapa en la edge function: si se
  -- desalinean, una sección nueva se guarda y no se muestra. Un CHECK falla en
  -- el INSERT, que es cuando todavía se puede arreglar.
  CONSTRAINT bot_digest_config_secciones_ck
    CHECK (
      secciones <@ ARRAY[
        'ventas','top_clientes','top_productos','stock_critico','deuda',
        'pendientes_entrega','pendientes_pago','recorridos','rendiciones',
        'vencimientos'
      ]::TEXT[]
    )
);

COMMENT ON TABLE public.bot_digest_config IS
  'Preferencias del digest de Telegram por admin. La fila es opcional: sin fila, el default de las columnas reproduce el digest previo a esta migración.';

ALTER TABLE public.bot_digest_config ENABLE ROW LEVEL SECURITY;
-- Sin políticas a propósito: se lee y escribe sólo por las RPCs de abajo
-- (SECURITY DEFINER, con gate de rol), igual que el resto de las tablas bot_*.

-- ---------------------------------------------------------------------------
-- 2. Quién recibe el digest en esta hora
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.bot_digest_destinatarios(
  p_hora SMALLINT,
  p_dow  SMALLINT
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
    AND t.hora_local = p_hora
    AND p_dow = ANY(t.dias_semana)
    -- Sin secciones no hay mensaje que mandar.
    AND array_length(t.secciones, 1) >= 1;
$fn$;

COMMENT ON FUNCTION public.bot_digest_destinatarios(SMALLINT, SMALLINT) IS
  'Admins que deben recibir el digest en la hora p_hora del día ISO p_dow (1=lunes). La hora la calcula la edge function en TZ Argentina.';

-- La llama la edge function con service_role. Nadie más.
REVOKE ALL ON FUNCTION public.bot_digest_destinatarios(SMALLINT, SMALLINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_digest_destinatarios(SMALLINT, SMALLINT) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. RPCs del panel
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.bot_admin_listar_config_digest()
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_rol       TEXT;
  v_resultado JSON;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede ver la configuración del digest';
  END IF;

  SELECT COALESCE(
    json_agg(
      json_build_object(
        'perfil_id',        bu.perfil_id,
        'perfil_nombre',    p.nombre,
        'telegram_user_id', bu.telegram_user_id,
        'sucursal_id',      bu.sucursal_id,
        'sucursal_nombre',  s.nombre,
        -- `configurado` distingue "eligió esto" de "nunca lo tocó y le quedó el
        -- default". Sin esa marca el panel no puede decir cuál es cuál.
        'configurado',      (c.perfil_id IS NOT NULL),
        'activo',           COALESCE(c.activo, TRUE),
        'hora_local',       COALESCE(c.hora_local, 7),
        'dias_semana',      COALESCE(c.dias_semana, ARRAY[1,2,3,4,5,6,7]::SMALLINT[]),
        'secciones',        COALESCE(
                              c.secciones,
                              ARRAY['ventas','top_clientes','stock_critico','deuda','vencimientos']::TEXT[]
                            ),
        'actualizado_at',   c.actualizado_at,
        'actualizado_por',  ap.nombre
      )
      ORDER BY p.nombre
    ),
    '[]'::json
  )
  INTO v_resultado
  FROM bot_usuarios bu
  JOIN perfiles p               ON p.id = bu.perfil_id
  LEFT JOIN sucursales s        ON s.id = bu.sucursal_id
  LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
  LEFT JOIN perfiles ap         ON ap.id = c.actualizado_por
  WHERE bu.activo AND p.activo AND p.rol = 'admin';

  RETURN v_resultado;
END;
$fn$;

REVOKE ALL ON FUNCTION public.bot_admin_listar_config_digest() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_listar_config_digest() TO authenticated;

CREATE OR REPLACE FUNCTION public.bot_admin_guardar_config_digest(
  p_perfil_id  UUID,
  p_activo     BOOLEAN,
  p_hora_local SMALLINT,
  p_dias       SMALLINT[],
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
    p_perfil_id, p_activo, p_hora_local, p_dias, p_secciones,
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

REVOKE ALL ON FUNCTION public.bot_admin_guardar_config_digest(UUID, BOOLEAN, SMALLINT, SMALLINT[], TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_admin_guardar_config_digest(UUID, BOOLEAN, SMALLINT, SMALLINT[], TEXT[]) TO authenticated;
