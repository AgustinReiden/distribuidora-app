-- Migración 014 - Bot Telegram: tablas de soporte y RPC de vinculación
--
-- Crea las tablas que necesita el agente de IA expuesto via Telegram para
-- operar contra el back de Supabase respetando los permisos de cada rol:
--
-- 1. bot_usuarios            : mapea telegram_user_id ↔ perfiles(id) y guarda
--                              snapshot del rol/sucursal al momento de vincular.
-- 2. bot_codigos_vinculacion : códigos OTP de un solo uso (6 chars uppercase)
--                              que la app web genera para que el usuario los
--                              escriba en el bot y se vincule.
-- 3. bot_audit_log           : auditoría completa de mensajes, tool calls,
--                              respuestas y errores del bot.
-- 4. bot_conversaciones      : memoria conversacional (últimos 12 turnos
--                              aproximadamente) por chat de Telegram.
--
-- RLS: las 4 tablas tienen ROW LEVEL SECURITY habilitado y NO tienen policies
-- amplias para anon/authenticated. Solo el service_role (que bypassa RLS)
-- puede leer/escribir desde el backend del bot. La única excepción es la
-- policy `codigos_self_read` que permite al usuario autenticado leer sus
-- propios códigos activos para mostrarlos en la UI web.
--
-- RPC `generar_codigo_vinculacion_bot`: SECURITY DEFINER, invocable por
-- usuarios authenticated. Invalida códigos previos del mismo perfil (un solo
-- código activo a la vez), genera un código único de 6 chars en mayúscula
-- con TTL de 10 minutos y reintenta hasta 5 veces ante colisiones.

-- ============================================================================
-- 1. bot_usuarios — mapping telegram_user_id ↔ perfil
-- ============================================================================

CREATE TABLE bot_usuarios (
  telegram_user_id   BIGINT       PRIMARY KEY,
  telegram_username  TEXT,
  perfil_id          UUID         NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  rol                TEXT         NOT NULL,
  sucursal_id        BIGINT       REFERENCES sucursales(id) ON DELETE SET NULL,
  vinculado_at       TIMESTAMPTZ  NOT NULL DEFAULT now(),
  activo             BOOLEAN      NOT NULL DEFAULT true,
  ultimo_uso_at      TIMESTAMPTZ,
  -- El rol del bot debe matchear el union de perfiles.rol. NO replicamos este
  -- check en bot_audit_log.rol porque ese campo guarda snapshots históricos
  -- y puede tener valores fantasma de usuarios cuyo rol cambió.
  CONSTRAINT bot_usuarios_rol_check CHECK (rol IN ('admin', 'preventista', 'transportista', 'deposito', 'encargado'))
);

CREATE INDEX idx_bot_usuarios_perfil ON bot_usuarios (perfil_id);

COMMENT ON TABLE bot_usuarios IS
  'Mapping de chat_id de Telegram a perfil de Supabase. Guarda snapshot del rol y sucursal al momento de vincular para evitar lookups extra en cada mensaje. activo=false bloquea acceso sin borrar el registro.';

-- ============================================================================
-- 2. bot_codigos_vinculacion — códigos OTP de un solo uso
-- ============================================================================

CREATE TABLE bot_codigos_vinculacion (
  codigo                  TEXT         PRIMARY KEY,
  perfil_id               UUID         NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  expira_at               TIMESTAMPTZ  NOT NULL DEFAULT (now() + interval '10 minutes'),
  usado_at                TIMESTAMPTZ,
  usado_por_telegram_id   BIGINT,
  created_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Garantiza que cada perfil tiene como máximo 1 código activo (sin usar) a la vez.
-- Doble función: hard constraint contra race conditions en generar_codigo_vinculacion_bot
-- y acelera la query de validación al ingresar el código en el bot.
CREATE UNIQUE INDEX idx_codigos_perfil_activos
  ON bot_codigos_vinculacion (perfil_id)
  WHERE usado_at IS NULL;

COMMENT ON TABLE bot_codigos_vinculacion IS
  'Códigos OTP de 6 chars uppercase para vincular un chat de Telegram a un perfil. Generados desde la app web con generar_codigo_vinculacion_bot(). Un código activo (usado_at IS NULL y now() < expira_at) por perfil; al generar uno nuevo se invalidan los previos.';

-- ============================================================================
-- 3. bot_audit_log — auditoría de toda interacción con el bot
-- ============================================================================

CREATE TABLE bot_audit_log (
  id                BIGSERIAL    PRIMARY KEY,
  telegram_user_id  BIGINT,
  perfil_id         UUID         REFERENCES perfiles(id) ON DELETE SET NULL,
  rol               TEXT,
  tipo              TEXT         NOT NULL,
  tool_name         TEXT,
  parametros        JSONB,
  resultado_meta    JSONB,
  texto_usuario     TEXT,
  texto_bot         TEXT,
  created_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
  CONSTRAINT bot_audit_log_tipo_check CHECK (
    tipo IN ('mensaje', 'tool_call', 'respuesta', 'error', 'comando')
  )
);

CREATE INDEX idx_audit_perfil_fecha
  ON bot_audit_log (perfil_id, created_at DESC);

CREATE INDEX idx_audit_tipo_fecha
  ON bot_audit_log (tipo, created_at DESC);

COMMENT ON TABLE bot_audit_log IS
  'Bitácora de toda interacción con el bot de Telegram: mensajes entrantes, tool calls del agente IA, respuestas, errores y comandos. perfil_id puede ser NULL para registrar mensajes de usuarios todavía no vinculados (fines de auditoría/abuso).';

-- ============================================================================
-- 4. bot_conversaciones — memoria conversacional por chat
-- ============================================================================

CREATE TABLE bot_conversaciones (
  telegram_user_id  BIGINT       PRIMARY KEY,
  mensajes          JSONB        NOT NULL DEFAULT '[]'::jsonb,
  actualizado_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE bot_conversaciones IS
  'Memoria conversacional del bot por chat de Telegram. mensajes es un arreglo JSONB con los últimos N turnos (aprox. 12) en formato {role, content, ...} para alimentar al modelo en cada llamada. La rotación/truncado la maneja el backend del bot.';

-- ============================================================================
-- 5. RLS — habilitado en las 4 tablas, sin policies amplias
-- ============================================================================
-- Solo service_role (que bypassa RLS) puede operar desde el backend del bot.
-- No se crean policies para anon/authenticated salvo la excepción de abajo.

ALTER TABLE bot_usuarios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE bot_codigos_vinculacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE bot_audit_log           ENABLE ROW LEVEL SECURITY;
ALTER TABLE bot_conversaciones      ENABLE ROW LEVEL SECURITY;

-- Excepción: el usuario autenticado debe poder leer SUS propios códigos
-- activos para que la app web muestre el código que acaba de generar.
CREATE POLICY "codigos_self_read"
  ON bot_codigos_vinculacion
  FOR SELECT
  TO authenticated
  USING (perfil_id = auth.uid() AND usado_at IS NULL);

-- ============================================================================
-- 6. RPC: generar_codigo_vinculacion_bot
-- ============================================================================
-- Genera un código OTP de 6 chars uppercase para que el usuario authenticated
-- lo escriba en el bot de Telegram y vincule su chat. Invalida cualquier
-- código activo previo del mismo perfil (un solo código activo a la vez).
-- Reintenta hasta 5 veces ante colisión de PK; expira a los 10 minutos.

-- Asegura que pgcrypto esté disponible para gen_random_bytes en el RPC.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION public.generar_codigo_vinculacion_bot()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_codigo    TEXT;
  v_expira_at TIMESTAMPTZ;
  v_intentos  INT := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Invalidar códigos previos del mismo perfil (un solo código activo a la vez).
  UPDATE bot_codigos_vinculacion
     SET usado_at = now()
   WHERE perfil_id = auth.uid()
     AND usado_at IS NULL;

  -- Calcular expira_at una sola vez para que coincida exactamente entre
  -- el INSERT y el JSON retornado (el cliente usa este valor para el countdown,
  -- así evitamos drift entre reloj del servidor y reloj del navegador).
  v_expira_at := now() + interval '10 minutes';

  -- Generar código único de 6 chars uppercase, retry si colisiona.
  LOOP
    -- gen_random_bytes (pgcrypto, habilitada por defecto en Supabase) provee CSPRNG.
    -- 4 bytes -> 8 chars hex -> truncamos a 6 chars uppercase.
    v_codigo := upper(substring(encode(gen_random_bytes(4), 'hex') FROM 1 FOR 6));
    BEGIN
      INSERT INTO bot_codigos_vinculacion (codigo, perfil_id, expira_at)
        VALUES (v_codigo, auth.uid(), v_expira_at);
      RETURN jsonb_build_object('codigo', v_codigo, 'expira_at', v_expira_at);
    EXCEPTION WHEN unique_violation THEN
      v_intentos := v_intentos + 1;
      IF v_intentos >= 5 THEN
        RAISE EXCEPTION 'No se pudo generar código único';
      END IF;
    END;
  END LOOP;
END;
$$;

REVOKE ALL    ON FUNCTION public.generar_codigo_vinculacion_bot() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.generar_codigo_vinculacion_bot() TO authenticated;

COMMENT ON FUNCTION public.generar_codigo_vinculacion_bot() IS
  'Genera un código OTP de 6 chars uppercase con TTL de 10 minutos para vincular un chat de Telegram al perfil del usuario authenticated actual. Invalida códigos activos previos del mismo perfil. Retorna jsonb con shape { codigo: TEXT, expira_at: TIMESTAMPTZ } — el cliente usa expira_at del server para evitar drift de reloj. Lanza excepción si no hay sesión o si no se logra un código único tras 5 intentos.';

-- ============================================================================
-- 7. RPC: canjear_codigo_vinculacion_bot
-- ============================================================================
-- Canjea atómicamente un código OTP generado previamente y vincula el chat de
-- Telegram al perfil correspondiente. Invocado SOLO desde el backend del bot
-- (Edge Function telegram-webhook) usando la service_role key — por eso solo
-- tiene GRANT EXECUTE TO service_role.
--
-- Atomicidad: todo el flujo (validar código + leer perfil + leer sucursal +
-- marcar código como usado + UPSERT en bot_usuarios) corre dentro del bloque
-- de la función. Lockeo del row del código vía SELECT ... FOR UPDATE para
-- evitar canjeo concurrente del mismo OTP.
--
-- Retorna jsonb con shape:
--   { success: true,  perfil_id, rol, sucursal_id, nombre }                — éxito
--   { success: false, error: 'no_encontrado'|'expirado'|'ya_usado'|'perfil_invalido' }

CREATE OR REPLACE FUNCTION public.canjear_codigo_vinculacion_bot(
  p_codigo             TEXT,
  p_telegram_user_id   BIGINT,
  p_telegram_username  TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_codigo_row    bot_codigos_vinculacion%ROWTYPE;
  v_perfil_id     UUID;
  v_perfil_rol    TEXT;
  v_perfil_nombre TEXT;
  v_perfil_activo BOOLEAN;
  v_sucursal_id   BIGINT;
BEGIN
  -- 1) Lockear la fila del código (si existe) para canjeo atómico.
  SELECT *
    INTO v_codigo_row
    FROM bot_codigos_vinculacion
   WHERE codigo = p_codigo
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'no_encontrado');
  END IF;

  IF v_codigo_row.usado_at IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'ya_usado');
  END IF;

  IF v_codigo_row.expira_at <= now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'expirado');
  END IF;

  -- 2) Leer perfil asociado y validar que esté activo.
  SELECT id, rol, nombre, activo
    INTO v_perfil_id, v_perfil_rol, v_perfil_nombre, v_perfil_activo
    FROM perfiles
   WHERE id = v_codigo_row.perfil_id;

  IF NOT FOUND OR v_perfil_activo IS NOT TRUE THEN
    RETURN jsonb_build_object('success', false, 'error', 'perfil_invalido');
  END IF;

  -- 3) Sucursal default del perfil (puede ser NULL si no tiene asignación).
  SELECT sucursal_id
    INTO v_sucursal_id
    FROM usuario_sucursales
   WHERE usuario_id = v_perfil_id
     AND es_default = true
   LIMIT 1;

  -- 4) Marcar el código como usado.
  UPDATE bot_codigos_vinculacion
     SET usado_at = now(),
         usado_por_telegram_id = p_telegram_user_id
   WHERE codigo = p_codigo;

  -- 5) UPSERT en bot_usuarios (soporta re-vinculación del mismo chat a otro perfil).
  INSERT INTO bot_usuarios (
    telegram_user_id, telegram_username, perfil_id, rol, sucursal_id, vinculado_at, activo
  ) VALUES (
    p_telegram_user_id, p_telegram_username, v_perfil_id, v_perfil_rol, v_sucursal_id, now(), true
  )
  ON CONFLICT (telegram_user_id) DO UPDATE
     SET telegram_username = EXCLUDED.telegram_username,
         perfil_id         = EXCLUDED.perfil_id,
         rol               = EXCLUDED.rol,
         sucursal_id       = EXCLUDED.sucursal_id,
         vinculado_at      = now(),
         activo            = true;

  RETURN jsonb_build_object(
    'success',     true,
    'perfil_id',   v_perfil_id,
    'rol',         v_perfil_rol,
    'sucursal_id', v_sucursal_id,
    'nombre',      v_perfil_nombre
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.canjear_codigo_vinculacion_bot(TEXT, BIGINT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.canjear_codigo_vinculacion_bot(TEXT, BIGINT, TEXT) TO service_role;

COMMENT ON FUNCTION public.canjear_codigo_vinculacion_bot(TEXT, BIGINT, TEXT) IS
  'Canjea atómicamente un código OTP de vinculación de bot Telegram. Lockea la fila del código, valida vigencia, lee perfil + sucursal default y hace UPSERT en bot_usuarios. Solo invocable por service_role desde la Edge Function. Retorna jsonb con success bool y, en caso de error, code en {no_encontrado, expirado, ya_usado, perfil_invalido}.';

-- ============================================================================
-- TODO retención (Phase 2)
-- ============================================================================
-- bot_audit_log y bot_conversaciones crecen sin tope:
--   * audit log: 1 row por mensaje + 1 por tool_call. Con texto en español puede
--     ser GBs/año. Estrategia sugerida: pg_cron mensual que borre rows con
--     created_at < now() - interval '90 days'.
--   * conversaciones: el backend trunca a ~12 turnos antes de UPSERT, pero si
--     hay un bug puede crecer sin límite. Considerar CHECK
--     (jsonb_array_length(mensajes) <= 50) como backstop defensivo.
