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
  ultimo_uso_at      TIMESTAMPTZ
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
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_codigo   TEXT;
  v_intentos INT := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Invalidar códigos previos del mismo perfil (un solo código activo a la vez).
  UPDATE bot_codigos_vinculacion
     SET usado_at = now()
   WHERE perfil_id = auth.uid()
     AND usado_at IS NULL;

  -- Generar código único de 6 chars uppercase, retry si colisiona.
  LOOP
    -- gen_random_bytes (pgcrypto, habilitada por defecto en Supabase) provee CSPRNG.
    -- 4 bytes -> 8 chars hex -> truncamos a 6 chars uppercase.
    v_codigo := upper(substring(encode(gen_random_bytes(4), 'hex') FROM 1 FOR 6));
    BEGIN
      INSERT INTO bot_codigos_vinculacion (codigo, perfil_id, expira_at)
        VALUES (v_codigo, auth.uid(), now() + interval '10 minutes');
      RETURN v_codigo;
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
  'Genera un código OTP de 6 chars uppercase con TTL de 10 minutos para vincular un chat de Telegram al perfil del usuario authenticated actual. Invalida códigos activos previos del mismo perfil. Lanza excepción si no hay sesión o si no se logra un código único tras 5 intentos.';

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
