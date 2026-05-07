-- ============================================================================
-- 036 — agregar columna total_vale_blanco a la RPC obtener_resumen_rendiciones
-- ============================================================================
-- Suma la nueva forma de pago "vale_blanco" como su propio bucket en el
-- desglose por dia/transportista, alineado con el comportamiento de las
-- otras formas (total_efectivo, total_transferencia, etc).
--
-- DROP FUNCTION (no CREATE OR REPLACE) porque el RETURNS TABLE cambia.
-- ============================================================================

DROP FUNCTION IF EXISTS public.obtener_resumen_rendiciones(date, date, uuid);

CREATE OR REPLACE FUNCTION public.obtener_resumen_rendiciones(
  p_fecha_desde date DEFAULT ((CURRENT_DATE - '30 days'::interval))::date,
  p_fecha_hasta date DEFAULT CURRENT_DATE,
  p_transportista_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
  fecha date,
  transportista_id uuid,
  transportista_nombre text,
  total_efectivo numeric,
  total_transferencia numeric,
  total_cheque numeric,
  total_cuenta_corriente numeric,
  total_tarjeta numeric,
  total_vale_blanco numeric,
  total_otros numeric,
  total_general numeric,
  cantidad_pedidos bigint,
  total_entregado numeric,
  total_gastos numeric,
  cantidad_gastos bigint,
  estado text,
  observaciones text,
  controlada boolean,
  controlada_at timestamp with time zone,
  controlada_por_nombre text,
  resuelta_at timestamp with time zone,
  resuelta_por_nombre text
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  WITH pagos_agg AS (
    SELECT
      pd.transportista_id AS t_id,
      pg.fecha AS f,
      SUM(CASE WHEN pg.forma_pago = 'efectivo' THEN pg.monto ELSE 0 END)::numeric AS tot_ef,
      SUM(CASE WHEN pg.forma_pago = 'transferencia' THEN pg.monto ELSE 0 END)::numeric AS tot_tr,
      SUM(CASE WHEN pg.forma_pago = 'cheque' THEN pg.monto ELSE 0 END)::numeric AS tot_ch,
      SUM(CASE WHEN pg.forma_pago = 'cuenta_corriente' THEN pg.monto ELSE 0 END)::numeric AS tot_cc,
      SUM(CASE WHEN pg.forma_pago = 'tarjeta' THEN pg.monto ELSE 0 END)::numeric AS tot_tj,
      SUM(CASE WHEN pg.forma_pago = 'vale_blanco' THEN pg.monto ELSE 0 END)::numeric AS tot_vb,
      SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta','vale_blanco')
                OR pg.forma_pago IS NULL THEN pg.monto ELSE 0 END)::numeric AS tot_ot,
      SUM(pg.monto)::numeric AS tot_gen
    FROM pagos pg
    JOIN pedidos pd ON pd.id = pg.pedido_id
    WHERE pg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pd.sucursal_id = v_sucursal_id
      AND pd.transportista_id IS NOT NULL
      AND (p_transportista_id IS NULL OR pd.transportista_id = p_transportista_id)
    GROUP BY pd.transportista_id, pg.fecha
  ),
  entregas_agg AS (
    SELECT
      pd.transportista_id AS t_id,
      pd.fecha_entrega::date AS f,
      SUM(pd.total)::numeric AS tot_entregado,
      COUNT(*)::bigint AS cant
    FROM pedidos pd
    WHERE pd.estado = 'entregado'
      AND pd.fecha_entrega IS NOT NULL
      AND pd.transportista_id IS NOT NULL
      AND pd.fecha_entrega::date BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pd.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR pd.transportista_id = p_transportista_id)
    GROUP BY pd.transportista_id, pd.fecha_entrega::date
  ),
  gastos_agg AS (
    SELECT
      rg.transportista_id AS t_id,
      rg.fecha AS f,
      SUM(rg.monto)::numeric AS tot_g,
      COUNT(*)::bigint AS cant_g
    FROM rendicion_gastos rg
    WHERE rg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND rg.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR rg.transportista_id = p_transportista_id)
    GROUP BY rg.transportista_id, rg.fecha
  ),
  fechas_activas AS (
    SELECT t_id, f FROM pagos_agg
    UNION
    SELECT t_id, f FROM entregas_agg
  )
  SELECT
    fa.f::date AS fecha,
    fa.t_id AS transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(pagos_agg.tot_ef, 0)::numeric AS total_efectivo,
    COALESCE(pagos_agg.tot_tr, 0)::numeric AS total_transferencia,
    COALESCE(pagos_agg.tot_ch, 0)::numeric AS total_cheque,
    COALESCE(pagos_agg.tot_cc, 0)::numeric AS total_cuenta_corriente,
    COALESCE(pagos_agg.tot_tj, 0)::numeric AS total_tarjeta,
    COALESCE(pagos_agg.tot_vb, 0)::numeric AS total_vale_blanco,
    COALESCE(pagos_agg.tot_ot, 0)::numeric AS total_otros,
    COALESCE(pagos_agg.tot_gen, 0)::numeric AS total_general,
    COALESCE(entregas_agg.cant, 0)::bigint AS cantidad_pedidos,
    COALESCE(entregas_agg.tot_entregado, 0)::numeric AS total_entregado,
    COALESCE(gastos_agg.tot_g, 0)::numeric AS total_gastos,
    COALESCE(gastos_agg.cant_g, 0)::bigint AS cantidad_gastos,
    COALESCE(rc.estado, 'pendiente')::text AS estado,
    rc.observaciones,
    (rc.id IS NOT NULL AND COALESCE(rc.estado, 'pendiente') IN ('confirmada','resuelta')) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre,
    rc.resuelta_at,
    rp.nombre::text AS resuelta_por_nombre
  FROM fechas_activas fa
  JOIN perfiles tr ON tr.id = fa.t_id
  LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
  LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
  LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = fa.f
   AND rc.transportista_id = fa.t_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  LEFT JOIN perfiles rp ON rp.id = rc.resuelta_por
  ORDER BY fa.f DESC, tr.nombre ASC;
END;
$function$;

ALTER FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) OWNER TO postgres;

GRANT ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO anon;
GRANT ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO service_role;
