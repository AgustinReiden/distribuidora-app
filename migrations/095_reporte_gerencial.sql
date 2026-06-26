-- ============================================================================
-- 095 · Reportes Gerenciales: RPC de datos en vivo + tabla de análisis mensual
-- ============================================================================
-- Centraliza toda la lógica de los informes gerenciales (ventas, costos,
-- márgenes, bonificaciones, comisiones, cobranza, mermas) en una sola función
-- que devuelve un JSONB. La consumen tanto la app (vista /reportes-gerenciales)
-- como Claude Code (comando /reporte-mensual) — fuente única de verdad.
--
-- Convenciones (ver memoria analisis-financiero-reporting):
--   * Venta = pedidos estado='entregado', canal='app' (excluye cancelados).
--   * Bonificaciones = pedido_items.es_bonificacion: ingreso 0 + costo real.
--   * CMV con productos.costo_sin_iva (costo actual). Se marcan productos sin costo.
--   * Comisiones = 2% sobre pedidos NO cancelados (base del sistema).
--   * p_sucursal_id NULL ⇒ consolidado de sucursales activas (red).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Función principal: reporte_gerencial(sucursal, desde, hasta) -> JSONB
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reporte_gerencial(
  p_sucursal_id bigint,
  p_desde       date,
  p_hasta       date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_nombre      text;
  v_result      jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
BEGIN
  -- Auth: desde la app (con JWT) el usuario debe ser admin Y sólo puede ver las
  -- sucursales que tiene asignadas (usuario_sucursales). Si auth.uid() es NULL
  -- (service_role / Claude Code vía MCP) es contexto privilegiado: acceso total
  -- (lo usa el comando /reporte-mensual para generar todas las sucursales + red).
  IF NOT v_es_servicio THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
    FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  -- Sucursales objetivo.
  IF p_sucursal_id IS NULL THEN
    -- Consolidado: sucursales activas; para un usuario, sólo las que tiene
    -- asignadas (un admin de una sola sucursal NO ve datos de otras).
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales
      FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    -- Sucursal puntual: el usuario debe tenerla asignada.
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;

  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  WITH
  ped AS (
    SELECT id, cliente_id, usuario_id, total, fecha, forma_pago, estado_pago
    FROM pedidos
    WHERE estado = 'entregado' AND canal = 'app'
      AND fecha BETWEEN p_desde AND p_hasta
      AND sucursal_id = ANY(v_sucursales)
  ),
  it AS (
    SELECT p.id AS pedido_id, p.usuario_id, p.fecha,
           pi.cantidad, pi.subtotal, pi.es_bonificacion,
           prod.costo_sin_iva, prod.nombre AS prod_nombre,
           COALESCE(NULLIF(prod.categoria, ''), '(sin categoría)') AS categoria,
           (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva = 0) AS sin_costo
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod ON prod.id = pi.producto_id
  ),
  nc AS (  -- base de comisión: pedidos no cancelados, sólo de vendedores con perfil
    SELECT usuario_id, total
    FROM pedidos
    WHERE estado <> 'cancelado' AND canal = 'app'
      AND fecha BETWEEN p_desde AND p_hasta
      AND sucursal_id = ANY(v_sucursales)
      AND usuario_id IN (SELECT id FROM perfiles)
  ),
  -- KPIs --------------------------------------------------------------------
  k_ped AS (
    SELECT COUNT(*) AS pedidos, COALESCE(SUM(total),0) AS venta,
           COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(total)),0) AS ticket
    FROM ped
  ),
  k_it AS (
    SELECT
      COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
      COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE es_bonificacion),0) AS bonif,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades,
      COALESCE(SUM(cantidad) FILTER (WHERE es_bonificacion),0) AS unidades_bonif,
      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_sin_costo
    FROM it
  ),
  k_nc AS (SELECT COALESCE(SUM(total),0) AS base_comision FROM nc),
  k_merma AS (
    SELECT COALESCE(SUM(m.cantidad*prod.costo_sin_iva),0) AS mermas
    FROM mermas_stock m JOIN productos prod ON prod.id = m.producto_id
    WHERE m.sucursal_id = ANY(v_sucursales)
      AND m.created_at::date BETWEEN p_desde AND p_hasta
  ),
  k_compra AS (
    SELECT COALESCE(SUM(total),0) AS compras
    FROM compras
    WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta
  ),
  k_nuevos AS (
    SELECT COUNT(*) AS nuevos FROM (
      SELECT cliente_id, MIN(fecha) AS pc
      FROM pedidos
      WHERE estado='entregado' AND sucursal_id = ANY(v_sucursales)
      GROUP BY cliente_id
    ) t WHERE pc BETWEEN p_desde AND p_hasta
  ),
  -- Mensual -----------------------------------------------------------------
  m_ped AS (
    SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(total) AS venta,
           COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(total)) AS ticket
    FROM ped GROUP BY 1
  ),
  m_it AS (
    SELECT to_char(fecha,'YYYY-MM') AS mes,
           COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
           COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE es_bonificacion),0) AS bonif
    FROM it GROUP BY 1
  ),
  m_merma AS (
    SELECT to_char(m.created_at,'YYYY-MM') AS mes, SUM(m.cantidad*prod.costo_sin_iva) AS mermas
    FROM mermas_stock m JOIN productos prod ON prod.id = m.producto_id
    WHERE m.sucursal_id = ANY(v_sucursales) AND m.created_at::date BETWEEN p_desde AND p_hasta
    GROUP BY 1
  ),
  m_compra AS (
    SELECT to_char(fecha_compra,'YYYY-MM') AS mes, SUM(total) AS compras
    FROM compras WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta
    GROUP BY 1
  ),
  mensual AS (
    SELECT mp.mes, mp.pedidos, mp.venta, mp.clientes, mp.ticket,
           COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
           COALESCE(mm.mermas,0) AS mermas, COALESCE(mc.compras,0) AS compras
    FROM m_ped mp
    LEFT JOIN m_it mi ON mi.mes = mp.mes
    LEFT JOIN m_merma mm ON mm.mes = mp.mes
    LEFT JOIN m_compra mc ON mc.mes = mp.mes
  ),
  -- Vendedores --------------------------------------------------------------
  v_ent AS (
    SELECT usuario_id,
      COUNT(DISTINCT pedido_id) AS pedidos,
      SUM(subtotal) AS venta,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE es_bonificacion),0) AS bonif
    FROM it GROUP BY usuario_id
  ),
  v_nc AS (SELECT usuario_id, SUM(total) AS base_nc FROM nc GROUP BY usuario_id),
  vendedores AS (
    SELECT pf.nombre, pf.rol, e.pedidos, e.venta, e.margen_comercial, e.bonif,
           COALESCE(n.base_nc, e.venta) AS base_nc
    FROM v_ent e
    JOIN perfiles pf ON pf.id = e.usuario_id
    LEFT JOIN v_nc n ON n.usuario_id = e.usuario_id
  ),
  -- Categorías / productos / clientes ---------------------------------------
  categorias AS (
    SELECT categoria, SUM(subtotal) AS venta,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE es_bonificacion),0) AS bonif,
      bool_or(sin_costo) AS sin_costo
    FROM it GROUP BY categoria
  ),
  top_prod AS (
    SELECT prod_nombre AS nombre,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades,
      SUM(subtotal) AS venta,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_sin_iva) FILTER (WHERE NOT es_bonificacion),0) AS margen
    FROM it GROUP BY prod_nombre ORDER BY venta DESC LIMIT 10
  ),
  top_cli AS (
    SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS cliente,
           COUNT(DISTINCT p.id) AS pedidos, SUM(p.total) AS venta
    FROM ped p JOIN clientes c ON c.id = p.cliente_id
    GROUP BY 1 ORDER BY venta DESC LIMIT 10
  ),
  -- Cobranza ----------------------------------------------------------------
  formas AS (
    SELECT COALESCE(forma_pago,'(sin dato)') AS forma_pago, SUM(total) AS monto
    FROM ped GROUP BY 1
  ),
  cobr AS (
    SELECT
      COALESCE(SUM(total) FILTER (WHERE estado_pago = 'pagado'),0) AS cobrado,
      COALESCE(SUM(total) FILTER (WHERE estado_pago IN ('pendiente','parcial')),0) AS pendiente
    FROM ped
  ),
  serie AS (
    SELECT to_char(fecha,'DD/MM') AS dia, SUM(total) AS venta
    FROM ped GROUP BY fecha ORDER BY fecha
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre,'?'),
      'desde', p_desde, 'hasta', p_hasta, 'generado_at', now()
    ),
    'kpis', (
      SELECT jsonb_build_object(
        'venta', kp.venta, 'pedidos', kp.pedidos, 'clientes', kp.clientes, 'ticket', kp.ticket,
        'clientes_nuevos', kn.nuevos,
        'cmv', ki.cmv, 'bonif', ki.bonif, 'unidades', ki.unidades, 'unidades_bonif', ki.unidades_bonif,
        'margen_comercial', kp.venta - ki.cmv,
        'margen_neto', kp.venta - ki.cmv - ki.bonif,
        'base_comision', kc.base_comision, 'comision_pct_default', 2,
        'mermas', km.mermas, 'compras', kcp.compras,
        'ingreso_sin_costo', ki.ingreso_sin_costo
      )
      FROM k_ped kp, k_it ki, k_nc kc, k_merma km, k_compra kcp, k_nuevos kn
    ),
    'mensual', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.mes),'[]') FROM mensual m),
    'vendedores', (SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.venta DESC),'[]') FROM vendedores v),
    'categorias', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.venta DESC),'[]') FROM categorias c),
    'top_productos', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_prod t),
    'top_clientes', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_cli t),
    'cobranza', jsonb_build_object(
      'formas', (SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.monto DESC),'[]') FROM formas f),
      'cobrado', (SELECT cobrado FROM cobr), 'pendiente', (SELECT pendiente FROM cobr)
    ),
    'serie_diaria', (SELECT COALESCE(jsonb_agg(jsonb_build_array(s.dia, s.venta)),'[]') FROM serie s),
    'flags', (
      SELECT jsonb_build_object(
        'ingreso_sin_costo', ki.ingreso_sin_costo,
        'pct_sin_costo', CASE WHEN kp.venta > 0 THEN round(100.0*ki.ingreso_sin_costo/kp.venta, 1) ELSE 0 END
      ) FROM k_it ki, k_ped kp
    )
  ) INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.reporte_gerencial(bigint, date, date) IS
  'Devuelve JSONB con el dashboard gerencial (ventas/costos/márgenes/comisiones/cobranza) por sucursal o consolidado (sucursal NULL). Admin-only desde la app; service_role libre.';

GRANT EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. Tabla de reportes mensuales (snapshot + análisis escrito por Claude Code)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reportes_mensuales (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sucursal_id   bigint REFERENCES sucursales(id),  -- NULL = red consolidada
  periodo       date NOT NULL,                      -- primer día del mes
  datos_snapshot jsonb,
  analisis_md   text,
  generado_por  text,
  generado_at   timestamptz DEFAULT now(),
  updated_at    timestamptz DEFAULT now()
);

COMMENT ON TABLE public.reportes_mensuales IS
  'Reporte gerencial mensual: snapshot de datos + análisis narrativo (escrito por Claude Code). sucursal_id NULL = red. UNIQUE por (sucursal_id, periodo) tratando NULL como -1.';

-- Único por (sucursal, periodo) tratando NULL (=red) como un valor concreto.
CREATE UNIQUE INDEX IF NOT EXISTS reportes_mensuales_suc_periodo_uidx
  ON public.reportes_mensuales (COALESCE(sucursal_id, -1), periodo);

ALTER TABLE public.reportes_mensuales ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reportes_mensuales_admin_select ON public.reportes_mensuales;
CREATE POLICY reportes_mensuales_admin_select ON public.reportes_mensuales
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));
-- Escritura: sólo vía RPC guardar_analisis_mensual (SECURITY DEFINER) o service_role.

-- ----------------------------------------------------------------------------
-- 3. RPC para persistir el análisis (lo llama Claude Code / el cron)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_analisis_mensual(
  p_sucursal_id bigint,
  p_periodo     date,
  p_analisis_md text,
  p_datos       jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  INSERT INTO reportes_mensuales (sucursal_id, periodo, analisis_md, datos_snapshot, generado_por, generado_at, updated_at)
  VALUES (p_sucursal_id, date_trunc('month', p_periodo)::date, p_analisis_md, p_datos,
          COALESCE(auth.uid()::text, 'claude-code'), now(), now())
  ON CONFLICT (COALESCE(sucursal_id, -1), periodo) DO UPDATE
    SET analisis_md    = EXCLUDED.analisis_md,
        datos_snapshot = COALESCE(EXCLUDED.datos_snapshot, reportes_mensuales.datos_snapshot),
        generado_por   = EXCLUDED.generado_por,
        updated_at     = now();
END;
$$;

GRANT EXECUTE ON FUNCTION public.guardar_analisis_mensual(bigint, date, text, jsonb) TO authenticated;
