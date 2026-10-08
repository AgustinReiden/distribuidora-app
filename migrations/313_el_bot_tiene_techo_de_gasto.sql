-- =============================================================================
-- 313 · El bot tiene techo de gasto
-- =============================================================================
--
-- PR 3a del plan del bot (#979). Decisión del dueño (2026-10-07): el asistente
-- no puede gastar más de USD 10 por mes en el modelo.
--
-- La edge function calcula el costo de cada respuesta con el uso de tokens que
-- devuelve el proveedor y los precios de llm/modelo.ts, y lo suma acá. Antes
-- de cada respuesta lee en qué nivel está el mes:
--   * ok       — normal;
--   * aviso    — pasó el 80%: a los admins vinculados les llega un aviso por
--                Telegram, UNA vez por mes;
--   * agotado  — llegó al 100%: el agente pasa al modelo más barato, o a sólo
--                comandos y botones si ya estaba en el más barato. También se
--                avisa una vez.
--
-- El "una vez" lo garantiza el UPDATE ... WHERE aviso_80_at IS NULL de abajo:
-- de dos respuestas que cruzan el 80% al mismo tiempo, sólo una lo marca.
--
-- El techo vive en una tabla de una fila y no en una constante: se cambia sin
-- deploy. No va en `politicas_comerciales` porque no es política comercial ni
-- es por sucursal: es lo que la empresa paga por el asistente.
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.bot_presupuesto_llm (
  -- Una sola fila: la PK es un booleano que sólo puede ser true.
  id              BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
  techo_usd_mes   NUMERIC(10,2) NOT NULL DEFAULT 10 CHECK (techo_usd_mes > 0),
  actualizado_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.bot_presupuesto_llm (id, techo_usd_mes) VALUES (TRUE, 10)
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE public.bot_presupuesto_llm IS
  'Techo de gasto mensual del asistente de Telegram en USD (mig 313). Una fila.';

CREATE TABLE IF NOT EXISTS public.bot_costo_llm_mensual (
  -- Primer día del mes, en día argentino.
  mes             DATE PRIMARY KEY CHECK (EXTRACT(DAY FROM mes) = 1),
  usd             NUMERIC(12,6) NOT NULL DEFAULT 0 CHECK (usd >= 0),
  llamadas        INTEGER NOT NULL DEFAULT 0 CHECK (llamadas >= 0),
  aviso_80_at     TIMESTAMPTZ,
  agotado_at      TIMESTAMPTZ,
  actualizado_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.bot_costo_llm_mensual IS
  'Gasto acumulado del asistente de Telegram por mes (mig 313). Lo escribe la edge function con bot_costo_llm_sumar.';

-- Sin políticas a propósito: se lee y escribe sólo por las RPCs de abajo,
-- igual que el resto de las tablas bot_*.
ALTER TABLE public.bot_presupuesto_llm ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bot_costo_llm_mensual ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------------
-- En qué nivel está el mes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_costo_llm_estado()
RETURNS json
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH m AS (
    SELECT date_trunc('month', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires'))::date AS mes
  ),
  t AS (SELECT COALESCE((SELECT techo_usd_mes FROM bot_presupuesto_llm WHERE id), 10) AS techo),
  g AS (SELECT COALESCE((SELECT usd FROM bot_costo_llm_mensual c, m WHERE c.mes = m.mes), 0) AS usd)
  SELECT json_build_object(
    'mes', m.mes,
    'usd', ROUND(g.usd, 4),
    'techo', t.techo,
    'nivel', CASE WHEN g.usd >= t.techo THEN 'agotado'
                  WHEN g.usd >= 0.8 * t.techo THEN 'aviso'
                  ELSE 'ok' END
  )
  FROM m, t, g;
$function$;


-- ---------------------------------------------------------------------------
-- Sumar lo que costó una respuesta
-- ---------------------------------------------------------------------------
-- Devuelve el estado después de sumar, y `avisar` = '80' o 'agotado' sólo a
-- la llamada que cruzó ese umbral por primera vez en el mes.
CREATE OR REPLACE FUNCTION public.bot_costo_llm_sumar(p_usd NUMERIC, p_llamadas INTEGER)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_mes    DATE := date_trunc('month', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires'))::date;
  v_techo  NUMERIC := COALESCE((SELECT techo_usd_mes FROM bot_presupuesto_llm WHERE id), 10);
  v_usd    NUMERIC;
  v_avisar TEXT;
BEGIN
  -- Una respuesta del bot cuesta centésimos de centavo. Un valor negativo o
  -- de cientos de dólares es un bug del cálculo, no un gasto: no se suma.
  IF p_usd IS NULL OR p_usd < 0 OR p_usd > 50 OR p_llamadas IS NULL OR p_llamadas < 0 THEN
    RAISE EXCEPTION 'bot_costo_llm_sumar: valores fuera de rango (usd %, llamadas %)', p_usd, p_llamadas;
  END IF;

  INSERT INTO bot_costo_llm_mensual AS c (mes, usd, llamadas)
  VALUES (v_mes, p_usd, p_llamadas)
  ON CONFLICT (mes) DO UPDATE SET
    usd = c.usd + EXCLUDED.usd,
    llamadas = c.llamadas + EXCLUDED.llamadas,
    actualizado_at = now()
  RETURNING usd INTO v_usd;

  -- El aviso de agotado gana al del 80% si una sola respuesta cruza los dos.
  UPDATE bot_costo_llm_mensual SET agotado_at = now(), aviso_80_at = COALESCE(aviso_80_at, now())
   WHERE mes = v_mes AND agotado_at IS NULL AND usd >= v_techo
  RETURNING 'agotado' INTO v_avisar;
  IF v_avisar IS NULL THEN
    UPDATE bot_costo_llm_mensual SET aviso_80_at = now()
     WHERE mes = v_mes AND aviso_80_at IS NULL AND usd >= 0.8 * v_techo
    RETURNING '80' INTO v_avisar;
  END IF;

  RETURN json_build_object(
    'mes', v_mes,
    'usd', ROUND(v_usd, 4),
    'techo', v_techo,
    'nivel', CASE WHEN v_usd >= v_techo THEN 'agotado'
                  WHEN v_usd >= 0.8 * v_techo THEN 'aviso'
                  ELSE 'ok' END,
    'avisar', v_avisar
  );
END;
$function$;

-- Las dos sólo desde la edge function (CLAUDE.md: server-only, las tres mitades).
REVOKE EXECUTE ON FUNCTION public.bot_costo_llm_estado() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.bot_costo_llm_sumar(NUMERIC, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_costo_llm_estado() TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_costo_llm_sumar(NUMERIC, INTEGER) TO service_role;


-- ---------------------------------------------------------------------------
-- Ensayo: cruzar el 80% y el 100% avisa una sola vez cada uno
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_j json;
BEGIN
  BEGIN
    UPDATE bot_presupuesto_llm SET techo_usd_mes = 1 WHERE id;
    DELETE FROM bot_costo_llm_mensual;

    v_j := bot_costo_llm_sumar(0.5, 1);
    IF v_j ->> 'nivel' <> 'ok' OR v_j ->> 'avisar' IS NOT NULL THEN
      RAISE EXCEPTION 'ensayo 313: con 50%% avisa (%)', v_j;
    END IF;
    v_j := bot_costo_llm_sumar(0.35, 1);
    IF v_j ->> 'nivel' <> 'aviso' OR v_j ->> 'avisar' IS DISTINCT FROM '80' THEN
      RAISE EXCEPTION 'ensayo 313: al cruzar el 80%% no avisa (%)', v_j;
    END IF;
    v_j := bot_costo_llm_sumar(0.01, 1);
    IF v_j ->> 'avisar' IS NOT NULL THEN
      RAISE EXCEPTION 'ensayo 313: avisa el 80%% dos veces (%)', v_j;
    END IF;
    v_j := bot_costo_llm_sumar(0.2, 1);
    IF v_j ->> 'nivel' <> 'agotado' OR v_j ->> 'avisar' IS DISTINCT FROM 'agotado' THEN
      RAISE EXCEPTION 'ensayo 313: al llegar al 100%% no avisa (%)', v_j;
    END IF;
    IF bot_costo_llm_estado() ->> 'nivel' <> 'agotado' THEN
      RAISE EXCEPTION 'ensayo 313: el estado no ve el mes agotado';
    END IF;
    IF (bot_costo_llm_sumar(0.01, 1) ->> 'avisar') IS NOT NULL THEN
      RAISE EXCEPTION 'ensayo 313: avisa el agotado dos veces';
    END IF;
    BEGIN
      PERFORM bot_costo_llm_sumar(-1, 1);
      RAISE EXCEPTION 'ensayo 313: acepta un costo negativo';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM LIKE 'ensayo 313%' THEN RAISE; END IF;
    END;

    RAISE EXCEPTION 'ensayo313_deshacer';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'ensayo313_deshacer' THEN RAISE; END IF;
  END;

  IF (SELECT techo_usd_mes FROM bot_presupuesto_llm WHERE id) <> 10 THEN
    RAISE EXCEPTION 'ensayo 313: el techo no quedó en USD 10';
  END IF;
  RAISE NOTICE 'ensayo 313: techo, avisos y estado OK';
END;
$ensayo$;

COMMIT;
