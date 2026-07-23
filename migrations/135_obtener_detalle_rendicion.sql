-- ============================================================================
-- 135 · obtener_detalle_rendicion(fecha, transportista) — detalle por cliente
-- ============================================================================
-- CONTEXTO (Taco Pozo, doc "Mejoras app Crecer"):
--   El "Detalle" de la rendicion solo mostraba el breakdown por forma de pago.
--   Pedido: ver por cliente cuanto es entrega vs ctas ctes, cuantos clientes y
--   el monto de ctas ctes del dia, y poder exportar a Excel.
--
-- Esta RPC devuelve una fila por cliente para una (fecha, transportista) dada,
-- con el mismo criterio de clasificacion Entregas/Ctas Ctes que
-- obtener_resumen_rendiciones (mig 133). El front agrega el conteo de clientes,
-- el total de ctas ctes del dia y el export a Excel.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_detalle_rendicion(
  p_fecha date,
  p_transportista_id uuid
)
RETURNS TABLE(
  cliente_id bigint,
  cliente_nombre text,
  total numeric,
  total_entregas numeric,
  total_ctascte numeric,
  efectivo numeric,
  transferencia numeric,
  otros numeric,
  cantidad_pagos bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id bigint;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  SELECT
    pg.cliente_id AS cliente_id,
    COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente #' || pg.cliente_id)::text AS cliente_nombre,
    SUM(pg.monto)::numeric AS total,
    SUM(CASE
      WHEN pg.pedido_id IS NOT NULL
       AND pd.estado = 'entregado'
       AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha
      THEN pg.monto ELSE 0 END)::numeric AS total_entregas,
    SUM(CASE
      WHEN pg.pedido_id IS NULL
        OR pd.estado IS DISTINCT FROM 'entregado'
        OR COALESCE(pd.fecha_entrega::date, pg.fecha) IS DISTINCT FROM pg.fecha
      THEN pg.monto ELSE 0 END)::numeric AS total_ctascte,
    SUM(CASE WHEN pg.forma_pago = 'efectivo' THEN pg.monto ELSE 0 END)::numeric AS efectivo,
    SUM(CASE WHEN pg.forma_pago = 'transferencia' THEN pg.monto ELSE 0 END)::numeric AS transferencia,
    SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia') OR pg.forma_pago IS NULL
             THEN pg.monto ELSE 0 END)::numeric AS otros,
    COUNT(*)::bigint AS cantidad_pagos
  FROM pagos pg
  LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
  LEFT JOIN clientes c ON c.id = pg.cliente_id
  WHERE pg.fecha = p_fecha
    AND pg.sucursal_id = v_sucursal_id
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  GROUP BY pg.cliente_id, c.nombre_fantasia, c.razon_social
  ORDER BY SUM(pg.monto) DESC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.obtener_detalle_rendicion(date, uuid) TO authenticated;
