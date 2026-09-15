-- Migración 248 — el mismo update de Telegram no se procesa dos veces (OPS-2, #640)
--
-- Telegram reintenta el webhook cuando no recibe 200 a tiempo, y una respuesta
-- lenta del LLM alcanza para llegar al timeout. Hoy cada reintento se reprocesa
-- entero: un mismo mensaje pasa dos veces por el agente, y un callback de
-- "confirmar pedido" puede intentar crear el pedido dos veces
-- (`crear_pedido_completo_bot` no es idempotente por update).
--
-- La dedup no puede vivir en memoria del isolate: Supabase lo recicla entre
-- invocaciones y un reintento puede caer en otro isolate. Va en la base.
--
-- Esta migración agrega:
--   1. bot_updates_procesados — un renglón por update_id visto.
--   2. bot_marcar_update(bigint) — INSERT ... ON CONFLICT DO NOTHING que
--      devuelve si insertó. El webhook la llama antes de delegar.
--   3. 'duplicado' como tipo válido de bot_audit_log.
--
-- Forward-only y aditivo: tabla nueva + función nueva + un CHECK que sólo
-- ensancha el dominio. No toca saldos, stock ni pedidos.

-- ============================================================================
-- 1. bot_updates_procesados
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.bot_updates_procesados (
  update_id    BIGINT       PRIMARY KEY,
  recibido_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Índice para que el barrido de retención (ver punto 2) toque sólo el rango
-- viejo en vez de escanear la tabla entera.
CREATE INDEX IF NOT EXISTS idx_bot_updates_procesados_recibido
  ON public.bot_updates_procesados (recibido_at);

-- RLS habilitada y sin policies, como el resto de las bot_* (mig 014):
-- solo service_role, que bypassa RLS, opera desde el backend del bot.
ALTER TABLE public.bot_updates_procesados ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.bot_updates_procesados IS
  'Idempotencia del webhook de Telegram: un renglón por update_id ya procesado. El webhook llama bot_marcar_update() antes de delegar; si el update ya está, responde 200 sin reprocesar. Retención: 7 días, barridos por la propia bot_marcar_update() — Telegram deja de reintentar mucho antes.';

-- ============================================================================
-- 2. bot_marcar_update(p_update_id) -> ¿es la primera vez que lo veo?
-- ============================================================================
-- Devuelve TRUE si insertó (procesalo) y FALSE si ya estaba (descartalo).
-- El INSERT ... ON CONFLICT DO NOTHING es atómico: dos reintentos concurrentes
-- en isolates distintos no pueden ganar los dos.
--
-- La retención va acá adentro, en el camino del INSERT, y no en un pg_cron:
-- pg_cron NO está instalado en este cluster, así que los crons de las
-- migraciones 016 (retención de bot_audit_log) y 018 (digest diario) nunca se
-- schedularon — bot_audit_log todavía tiene filas de hace meses y
-- bot_digests_enviados está vacía. Un job que no corre no es retención. El
-- mecanismo que sí funciona es el de la mig 073: la tabla se recorta sola en
-- el write. El DELETE es un rango por índice sobre una tabla chica (unos
-- cientos de updates por día × 7 días), y en régimen borra 0 filas.

CREATE OR REPLACE FUNCTION public.bot_marcar_update(p_update_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_inserto boolean;
BEGIN
  INSERT INTO public.bot_updates_procesados (update_id)
  VALUES (p_update_id)
  ON CONFLICT (update_id) DO NOTHING
  RETURNING true INTO v_inserto;

  -- INTO sin STRICT deja la variable en NULL cuando el INSERT no devolvió
  -- fila, o sea cuando el ON CONFLICT lo descartó: ya lo habíamos visto.
  IF v_inserto IS NULL THEN
    RETURN false;
  END IF;

  DELETE FROM public.bot_updates_procesados
  WHERE recibido_at < now() - INTERVAL '7 days';

  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public.bot_marcar_update(bigint) IS
  'Marca un update_id de Telegram como procesado. TRUE = primera vez (procesalo), FALSE = reintento (descartalo). Idempotente y atómica vía ON CONFLICT DO NOTHING. De paso barre los update_id de más de 7 días. La llama la edge function telegram-webhook con service_role.';

-- Toda función nueva de public nace con EXECUTE para PUBLIC y Supabase se lo
-- concede a anon por separado: hay que revocar las dos mitades acá.
REVOKE ALL ON FUNCTION public.bot_marcar_update(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_marcar_update(bigint) TO service_role;

-- ============================================================================
-- 3. bot_audit_log acepta tipo = 'duplicado'
-- ============================================================================
-- El webhook deja un renglón por cada reintento descartado, para que el
-- duplicado sea visible en la bitácora en vez de desaparecer en silencio.

ALTER TABLE public.bot_audit_log
  DROP CONSTRAINT IF EXISTS bot_audit_log_tipo_check;

ALTER TABLE public.bot_audit_log
  ADD CONSTRAINT bot_audit_log_tipo_check CHECK (
    tipo IN ('mensaje', 'tool_call', 'respuesta', 'error', 'comando', 'duplicado')
  );
