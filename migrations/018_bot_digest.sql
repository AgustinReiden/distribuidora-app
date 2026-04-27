-- Migración 018 — Bot Telegram Phase 4: digest ejecutivo diario para admins
--
-- Componentes:
--   1. Tabla bot_digests_enviados (idempotencia: 1 digest por admin × fecha).
--   2. RPC bot_metricas_admin_dia(p_fecha, p_sucursal_id) → JSON con métricas
--      operativas del día anterior + comparativos vs últimos 7 días.
--   3. pg_cron schedule a las 10:00 UTC (= 07:00 ART) que invoca via pg_net
--      la edge function `telegram-digest`.
--
-- Como las otras RPCs `bot_*` (migrations 015, 017), la métrica RPC es
-- service_role-only: el control de rol/sucursal del admin se hace en la
-- edge function antes de invocar.
--
-- pg_cron + pg_net deben estar habilitados en el cluster Supabase (Dashboard:
-- Database > Extensions). Si pg_cron no está, el cron schedule no se crea
-- (el bloque DO es no-op). Si pg_net no está, el cron está creado pero el
-- net.http_post falla en runtime — verificar con `SELECT * FROM cron.job;`
-- y `SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;`.

-- ============================================================================
-- 1. Tabla bot_digests_enviados (idempotencia + auditoría)
-- ============================================================================

CREATE TABLE bot_digests_enviados (
  admin_perfil_id  UUID         NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  fecha            DATE         NOT NULL,
  sent_at          TIMESTAMPTZ  NOT NULL DEFAULT now(),
  telegram_user_id BIGINT,
  status           TEXT         NOT NULL,
  error_meta       JSONB,
  PRIMARY KEY (admin_perfil_id, fecha),
  CONSTRAINT bot_digests_enviados_status_check CHECK (status IN ('ok', 'error', 'skipped'))
);

CREATE INDEX idx_bot_digests_enviados_fecha ON bot_digests_enviados (fecha DESC);

ALTER TABLE bot_digests_enviados ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE bot_digests_enviados IS
  'Idempotencia + auditoría del digest diario por admin. PRIMARY KEY (admin_perfil_id, fecha) garantiza que dos retries del cron en el mismo día no manden 2 mensajes. status = ok|error|skipped; si error, error_meta tiene {stage, error}.';

-- ============================================================================
-- 2. RPC bot_metricas_admin_dia
-- ============================================================================
-- Retorna JSON con métricas del día p_fecha + comparativos.
-- p_sucursal_id puede ser NULL → todas las sucursales del admin.
--
-- Convenciones del esquema (verificadas contra 000_baseline.sql):
--   * pedidos.fecha (DATE), pedidos.estado, pedidos.estado_pago, pedidos.total,
--     pedidos.monto_pagado, pedidos.sucursal_id.
--   * Estados de pedidos vivos vistos en el baseline: pendiente, en_preparacion,
--     asignado, en_reparto, entregado, cancelado.
--   * pedido_items.precio_unitario.
--   * productos.codigo, productos.stock, productos.stock_minimo, productos.sucursal_id.
--   * recorridos.total_pedidos, recorridos.fecha, recorridos.estado.
--   * rendiciones NO tiene columna `controlada`. El control vive en
--     `rendiciones_control (fecha, transportista_id, sucursal_id)` que se
--     puebla cuando se controla. "Pendientes de controlar" = rendiciones
--     sin row matching en rendiciones_control.

CREATE OR REPLACE FUNCTION public.bot_metricas_admin_dia(
  p_fecha       DATE,
  p_sucursal_id BIGINT DEFAULT NULL
) RETURNS JSON
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH
  -- Pedidos del día (excluye cancelados).
  pedidos_dia AS (
    SELECT id, total, cliente_id, sucursal_id
    FROM pedidos
    WHERE fecha = p_fecha
      AND estado <> 'cancelado'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  -- Pedidos de los 7 días previos (no incluye p_fecha).
  pedidos_7d AS (
    SELECT total
    FROM pedidos
    WHERE fecha >= p_fecha - INTERVAL '7 days'
      AND fecha <  p_fecha
      AND estado <> 'cancelado'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  ventas_dia AS (
    SELECT
      COUNT(*)                                                   AS pedidos,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS total,
      CASE
        WHEN COUNT(*) > 0 THEN (COALESCE(SUM(total), 0) / COUNT(*))::numeric(14,2)
        ELSE 0::numeric(14,2)
      END                                                        AS ticket_promedio
    FROM pedidos_dia
  ),
  promedio_7d AS (
    SELECT
      ROUND(COUNT(*) / 7.0, 2)                                   AS pedidos_dia_avg,
      ROUND(COALESCE(SUM(total), 0) / 7.0, 2)                    AS total_dia_avg
    FROM pedidos_7d
  ),
  top_clientes AS (
    SELECT
      pd.cliente_id,
      COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, '(sin nombre)') AS nombre,
      COUNT(*)                                                   AS pedidos,
      SUM(pd.total)::numeric(14,2)                               AS total
    FROM pedidos_dia pd
    LEFT JOIN clientes c ON c.id = pd.cliente_id
    GROUP BY pd.cliente_id, c.nombre_fantasia, c.razon_social
    ORDER BY SUM(pd.total) DESC
    LIMIT 5
  ),
  top_productos AS (
    SELECT
      pi.producto_id,
      pr.nombre,
      pr.codigo,
      SUM(pi.cantidad)::int                                      AS cantidad,
      SUM(pi.cantidad * pi.precio_unitario)::numeric(14,2)       AS monto
    FROM pedido_items pi
    JOIN pedidos_dia  pd ON pd.id = pi.pedido_id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    GROUP BY pi.producto_id, pr.nombre, pr.codigo
    ORDER BY SUM(pi.cantidad) DESC
    LIMIT 5
  ),
  -- Pedidos vivos pendientes de entrega (de los últimos 14 días).
  pendientes_entrega AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(SUM(total), 0)::numeric(14,2)                     AS monto
    FROM pedidos
    WHERE estado IN ('pendiente', 'en_preparacion', 'asignado', 'en_reparto')
      AND fecha >= p_fecha - INTERVAL '14 days'
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  -- Pedidos pendientes de pago (estado_pago != pagado, no cancelados, saldo > 0).
  pendientes_pago AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(SUM(total - COALESCE(monto_pagado, 0)), 0)::numeric(14,2) AS saldo
    FROM pedidos
    WHERE estado_pago IN ('pendiente', 'parcial')
      AND estado <> 'cancelado'
      AND total > COALESCE(monto_pagado, 0)
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  -- Stock crítico: stock <= stock_minimo. Top 5 con mayor déficit.
  stock_critico_base AS (
    SELECT
      id, codigo, nombre, stock, stock_minimo,
      ROW_NUMBER() OVER (
        ORDER BY (COALESCE(stock_minimo, 10) - COALESCE(stock, 0)) DESC, id ASC
      ) AS rn
    FROM productos
    WHERE COALESCE(stock, 0) <= COALESCE(stock_minimo, 10)
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  stock_critico AS (
    SELECT
      (SELECT COUNT(*) FROM stock_critico_base)::int AS count,
      COALESCE(
        (SELECT json_agg(
          json_build_object(
            'id',           s.id,
            'codigo',       s.codigo,
            'nombre',       s.nombre,
            'stock',        s.stock,
            'stock_minimo', s.stock_minimo
          )
          ORDER BY s.rn
        )
        FROM stock_critico_base s
        WHERE s.rn <= 5),
        '[]'::json
      ) AS top
  ),
  cxc AS (
    SELECT
      COUNT(*) FILTER (WHERE saldo_cuenta > 0)::int              AS clientes_con_saldo,
      COALESCE(SUM(saldo_cuenta) FILTER (WHERE saldo_cuenta > 0), 0)::numeric(14,2) AS deuda_total
    FROM clientes
    WHERE activo = TRUE
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  ),
  -- Cuentas por cobrar vencidas: pedidos con saldo > 0 cuya fecha + dias_credito
  -- del cliente está en el pasado.
  cxc_vencido AS (
    SELECT
      COUNT(*)::int                                              AS pedidos_vencidos,
      COALESCE(SUM(p.total - COALESCE(p.monto_pagado, 0)), 0)::numeric(14,2) AS monto_vencido
    FROM pedidos p
    JOIN clientes c ON c.id = p.cliente_id
    WHERE p.estado <> 'cancelado'
      AND p.estado_pago IN ('pendiente', 'parcial')
      AND p.total > COALESCE(p.monto_pagado, 0)
      AND p.fecha + (COALESCE(c.dias_credito, 30) || ' days')::interval < CURRENT_DATE
      AND (p_sucursal_id IS NULL OR p.sucursal_id = p_sucursal_id)
  ),
  -- Rendiciones pendientes de controlar (sin row en rendiciones_control)
  -- de más de 2 días. Match por (fecha, transportista_id, sucursal_id).
  rendiciones_pendientes AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COALESCE(MAX(CURRENT_DATE - r.fecha), 0)::int              AS dias_mas_vieja
    FROM rendiciones r
    LEFT JOIN rendiciones_control rc
      ON  rc.fecha = r.fecha
      AND rc.transportista_id = r.transportista_id
      AND rc.sucursal_id = r.sucursal_id
    WHERE rc.id IS NULL
      AND r.fecha < CURRENT_DATE - INTERVAL '2 days'
      AND (p_sucursal_id IS NULL OR r.sucursal_id = p_sucursal_id)
  ),
  recorridos_hoy AS (
    SELECT
      COUNT(*)::int                                              AS count,
      COUNT(*) FILTER (WHERE estado = 'en_curso')::int           AS en_curso,
      COALESCE(SUM(total_pedidos), 0)::int                       AS total_paradas
    FROM recorridos
    WHERE fecha = CURRENT_DATE
      AND (p_sucursal_id IS NULL OR sucursal_id = p_sucursal_id)
  )
  SELECT json_build_object(
    'fecha',                  p_fecha,
    'sucursal_id',            p_sucursal_id,
    'ventas_dia',             (SELECT row_to_json(v) FROM ventas_dia v),
    'promedio_7d',            (SELECT row_to_json(p) FROM promedio_7d p),
    'delta_pct',
      CASE
        WHEN (SELECT total_dia_avg FROM promedio_7d) > 0 THEN
          ROUND(
            (((SELECT total FROM ventas_dia) - (SELECT total_dia_avg FROM promedio_7d))
             / (SELECT total_dia_avg FROM promedio_7d) * 100)::numeric, 1
          )
        ELSE NULL
      END,
    'top_clientes',           COALESCE((SELECT json_agg(row_to_json(t)) FROM top_clientes t), '[]'::json),
    'top_productos',          COALESCE((SELECT json_agg(row_to_json(t)) FROM top_productos t), '[]'::json),
    'pendientes_entrega',     (SELECT row_to_json(x) FROM pendientes_entrega x),
    'pendientes_pago',        (SELECT row_to_json(x) FROM pendientes_pago x),
    'stock_critico',          (SELECT row_to_json(x) FROM stock_critico x),
    'cuentas_por_cobrar',     (SELECT row_to_json(x) FROM cxc x),
    'cxc_vencido',            (SELECT row_to_json(x) FROM cxc_vencido x),
    'rendiciones_pendientes', (SELECT row_to_json(x) FROM rendiciones_pendientes x),
    'recorridos_hoy',         (SELECT row_to_json(x) FROM recorridos_hoy x)
  );
$$;

ALTER FUNCTION public.bot_metricas_admin_dia(DATE, BIGINT) OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.bot_metricas_admin_dia(DATE, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_metricas_admin_dia(DATE, BIGINT) TO service_role;

COMMENT ON FUNCTION public.bot_metricas_admin_dia(DATE, BIGINT) IS
  'Métricas operativas del día p_fecha para el digest del bot Telegram. Filtra por sucursal_id si se pasa (NULL = todas). Incluye comparativo vs promedio últimos 7 días, top 5 clientes/productos del día, pendientes de entrega/pago, stock crítico (top 5 con mayor déficit), CxC + CxC vencido (con dias_credito por cliente), rendiciones sin controlar (>2 días) y recorridos del día. Service_role-only: el control de acceso del admin lo hace la edge function.';

-- ============================================================================
-- 3. pg_cron schedule del digest diario
-- ============================================================================
-- 10:00 UTC todos los días = 07:00 ART (UTC-3, Argentina sin DST).
-- Llama a la edge function /telegram-digest via pg_net.http_post; la edge
-- function arma el digest por cada admin vinculado.
--
-- IMPORTANTE: requiere las settings:
--   ALTER DATABASE postgres SET app.settings.bot_digest_url      = 'https://<ref>.supabase.co/functions/v1/telegram-digest';
--   ALTER DATABASE postgres SET app.settings.service_role_key    = '<eyJ...>';
-- Si las settings no están, el net.http_post llama a un placeholder y queda
-- registrado en cron.job_run_details como error — no rompe la migración.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    PERFORM cron.schedule(
      'bot-telegram-digest-diario',
      '0 10 * * *',  -- 07:00 ART = 10:00 UTC, Argentina UTC-3 sin DST
      $cron$
        SELECT net.http_post(
          url     := COALESCE(
            current_setting('app.settings.bot_digest_url', true),
            'https://example.supabase.co/functions/v1/telegram-digest'
          ),
          headers := jsonb_build_object(
            'Authorization', 'Bearer ' || COALESCE(
              current_setting('app.settings.service_role_key', true),
              ''
            ),
            'Content-Type', 'application/json'
          ),
          body    := jsonb_build_object('source', 'pg_cron')
        );
      $cron$
    );
  END IF;
END;
$$;
