-- Migración 073: backstop de crecimiento para bot_conversaciones (Auditoría 2026-05, P3-6 parcial)
--
-- El backend ya trunca el historial a ~12 turnos antes del UPSERT, pero el TODO de
-- migrations/014_bot_telegram.sql recomendaba un backstop defensivo por si hay un bug.
-- En vez de un CHECK (que rechazaría el insert y rompería el bot), usamos un trigger
-- que AUTO-RECORTA a los últimos 50 turnos. Nunca actúa en uso normal (≤ ~12);
-- solo es una red de seguridad ante crecimiento descontrolado.
--
-- Forward-only y aditivo: CREATE TRIGGER no dispara sobre filas existentes (no toca datos).
-- No afecta saldos/stock/pedidos.

CREATE OR REPLACE FUNCTION public.cap_bot_conversaciones_mensajes()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.mensajes IS NOT NULL
     AND jsonb_typeof(NEW.mensajes) = 'array'
     AND jsonb_array_length(NEW.mensajes) > 50 THEN
    NEW.mensajes := (
      SELECT COALESCE(jsonb_agg(elem ORDER BY ord), '[]'::jsonb)
      FROM (
        SELECT elem, ord
        FROM jsonb_array_elements(NEW.mensajes) WITH ORDINALITY AS t(elem, ord)
        ORDER BY ord DESC
        LIMIT 50
      ) ultimos
    );
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_cap_bot_conversaciones ON public.bot_conversaciones;
CREATE TRIGGER trg_cap_bot_conversaciones
  BEFORE INSERT OR UPDATE ON public.bot_conversaciones
  FOR EACH ROW EXECUTE FUNCTION public.cap_bot_conversaciones_mensajes();
