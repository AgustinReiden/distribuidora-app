-- Migración 017 — Bot Telegram Phase 3: tool RFM (sugerencias de visitas)
--
-- Fórmula RFM customizada sobre `pedidos` y `cliente_preventistas`:
--
-- Recencia:    días_desde_última_compra / frecuencia_promedio_personalizada
--              (capeada a 5x para no sesgar todo a clientes "muertos")
-- Frecuencia:  PERCENT_RANK del nº de pedidos en la cartera del preventista
-- Monetario:   PERCENT_RANK del ticket promedio en la cartera
--
-- Score = 0.5 R + 0.25 F + 0.25 M.
--
-- Output: top N clientes ordenados por score DESC, con `motivo` textual
-- para que el bot pueda armar una respuesta clara.
--
-- Como las otras RPCs `bot_*`, es service_role-only: el control de rol/sucursal
-- lo hace la edge function antes de invocar.

CREATE OR REPLACE FUNCTION public.bot_sugerir_visitas_rfm(
  p_preventista_id UUID,
  p_sucursal_id    BIGINT,
  p_limit          INTEGER DEFAULT 10
) RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH mis_clientes AS (
    SELECT
      c.id,
      c.codigo,
      COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, '(sin nombre)') AS nombre,
      c.saldo_cuenta,
      c.zona
    FROM clientes c
    JOIN cliente_preventistas cp ON cp.cliente_id = c.id
    WHERE cp.preventista_id = p_preventista_id
      AND c.sucursal_id = p_sucursal_id
      AND c.activo = TRUE
  ),
  intervalos AS (
    -- Pedidos de los últimos 180 días (no-cancelados) con el gap respecto al
    -- pedido anterior del mismo cliente. LAG(...) retorna NULL en el primer
    -- pedido — AVG ignora NULLs así que el cálculo de frecuencia promedio
    -- funciona sin filtrar manualmente.
    SELECT
      p.cliente_id,
      p.fecha,
      p.total,
      (p.fecha - LAG(p.fecha) OVER (PARTITION BY p.cliente_id ORDER BY p.fecha))::int AS gap_dias
    FROM pedidos p
    JOIN mis_clientes mc ON mc.id = p.cliente_id
    WHERE p.fecha >= CURRENT_DATE - INTERVAL '180 days'
      AND p.estado <> 'cancelado'
      AND p.sucursal_id = p_sucursal_id
  ),
  metricas AS (
    SELECT
      mc.id            AS cliente_id,
      mc.codigo,
      mc.nombre,
      mc.zona,
      mc.saldo_cuenta,
      MAX(i.fecha)     AS ultima_compra,
      AVG(i.gap_dias)  AS frecuencia_dias,
      AVG(i.total)     AS ticket_promedio,
      COUNT(i.fecha)   AS n_pedidos
    FROM mis_clientes mc
    LEFT JOIN intervalos i ON i.cliente_id = mc.id
    GROUP BY mc.id, mc.codigo, mc.nombre, mc.zona, mc.saldo_cuenta
  ),
  scored AS (
    SELECT
      m.*,
      COALESCE((CURRENT_DATE - m.ultima_compra)::int, 9999) AS dias_desde_ultima,
      -- Frecuencia efectiva: si el cliente tiene <3 pedidos en 180 días,
      -- no podemos confiar en el AVG (mucho ruido). Asumimos un default
      -- razonable de 21 días (~3 semanas) — alineado con la cadencia
      -- típica del rubro.
      CASE
        WHEN m.n_pedidos < 3 OR m.frecuencia_dias IS NULL THEN 21::numeric
        ELSE m.frecuencia_dias
      END AS freq_efectiva
    FROM metricas m
  ),
  ranking AS (
    SELECT
      s.*,
      LEAST(
        s.dias_desde_ultima::numeric / NULLIF(s.freq_efectiva, 0),
        5
      ) AS r_norm,
      PERCENT_RANK() OVER (ORDER BY s.n_pedidos)                   AS f_norm,
      PERCENT_RANK() OVER (ORDER BY s.ticket_promedio NULLS FIRST) AS m_norm
    FROM scored s
  ),
  final AS (
    SELECT
      cliente_id,
      codigo,
      nombre,
      zona,
      saldo_cuenta,
      ultima_compra,
      dias_desde_ultima,
      ROUND(freq_efectiva, 1)               AS frecuencia_dias,
      ROUND(COALESCE(ticket_promedio, 0), 2) AS ticket_promedio,
      n_pedidos,
      ROUND((r_norm * 0.5 + f_norm * 0.25 + m_norm * 0.25)::numeric, 3) AS score,
      (dias_desde_ultima > freq_efectiva * 1.3) AS vencido,
      CASE
        WHEN dias_desde_ultima > freq_efectiva * 2 THEN
          format('Atrasado: %s días sin comprar (compra cada ~%s)', dias_desde_ultima, ROUND(freq_efectiva))
        WHEN dias_desde_ultima > freq_efectiva * 1.3 THEN
          format('Próximo a re-pedido (cada ~%s días, lleva %s)', ROUND(freq_efectiva), dias_desde_ultima)
        WHEN saldo_cuenta > 0 THEN
          format('Tiene saldo $%s pendiente', ROUND(saldo_cuenta))
        WHEN n_pedidos >= 5 THEN
          'Cliente top por frecuencia'
        ELSE
          'Cliente activo'
      END AS motivo
    FROM ranking
    ORDER BY score DESC NULLS LAST
    LIMIT p_limit
  )
  SELECT json_build_object(
    'total', (SELECT COUNT(*) FROM final),
    'sugerencias', COALESCE(
      (SELECT json_agg(row_to_json(f) ORDER BY f.score DESC) FROM final f),
      '[]'::json
    )
  );
$$;

ALTER FUNCTION public.bot_sugerir_visitas_rfm(UUID, BIGINT, INTEGER) OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.bot_sugerir_visitas_rfm(UUID, BIGINT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_sugerir_visitas_rfm(UUID, BIGINT, INTEGER) TO service_role;

COMMENT ON FUNCTION public.bot_sugerir_visitas_rfm(UUID, BIGINT, INTEGER) IS
  'Sugerencias RFM de visitas para preventistas. Score = 0.5*Recencia + 0.25*Frecuencia + 0.25*Monto. La recencia se computa contra una frecuencia "personalizada" por cliente (avg gap entre pedidos en últimos 180 días). Top N por score DESC. Output JSON con total + sugerencias[]. Solo accesible por service_role: el control de rol/sucursal lo hace la edge function antes de invocar.';
