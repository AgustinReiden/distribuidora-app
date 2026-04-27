-- Migración 016 — Retención y constraints defensivos del bot Telegram
--
-- Phase 2 cierra con audit log creciendo sin tope (~3-4 rows por mensaje
-- entre `mensaje`, `comando`, `tool_call` entry+exit). Esta migración:
--
-- 1. Agrega un CHECK defensivo a `bot_conversaciones.mensajes` para que un
--    bug de truncado en el backend no haga crecer un row sin límite.
-- 2. Programa un job pg_cron mensual que borra rows de `bot_audit_log` con
--    más de 90 días, manteniendo el log acotado.
--
-- pg_cron debe estar habilitado en el cluster Supabase (en Dashboard:
-- Database > Extensions > pg_cron). Si no está, el `cron.schedule` falla.
-- En desarrollo local es opcional — si el cluster no lo tiene, comentá
-- el bloque y aplicá manualmente.

-- ============================================================================
-- 1. CHECK constraint en bot_conversaciones
-- ============================================================================

-- Backstop defensivo: el backend trunca los mensajes a ~12 turnos antes de
-- UPSERT. Si por un bug nunca trunca, este constraint impide que un row crezca
-- sin límite. 50 es 4x el límite teórico — deja margen para experimentación
-- en Phase 3 sin romper las queries existentes.
ALTER TABLE bot_conversaciones
  ADD CONSTRAINT bot_conversaciones_mensajes_max_length
  CHECK (jsonb_array_length(mensajes) <= 50);

COMMENT ON CONSTRAINT bot_conversaciones_mensajes_max_length ON bot_conversaciones IS
  'Backstop defensivo: máximo 50 turnos por chat. El backend trunca a ~12, este constraint protege contra bugs de truncado que dejarían crecer un row sin tope.';

-- ============================================================================
-- 2. pg_cron de retención de bot_audit_log
-- ============================================================================
-- Borra rows con más de 90 días el primero de cada mes a las 03:00 UTC.

DO $$
BEGIN
  -- Solo schedular si pg_cron está disponible (algunos clusters self-hosted
  -- no lo tienen por defecto).
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule(
      'bot-audit-log-retention',
      '0 3 1 * *',  -- "0 3 1 * *" = primer día del mes a las 03:00 UTC
      $cron$
        DELETE FROM bot_audit_log WHERE created_at < now() - INTERVAL '90 days';
      $cron$
    );
  END IF;
END;
$$;
