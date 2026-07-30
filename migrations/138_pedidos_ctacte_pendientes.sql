-- ============================================================================
-- 138 · obtener_pedidos_ctacte_pendientes — detalle de deuda por pedido
-- ============================================================================
-- Pedido de Taco Pozo: "necesito de que listado o pantalla consulto el detalle y
-- el total de los pedidos entregados que quedaron en cuenta corriente, o sea
-- pendiente de pago, y que sea el mismo rango de fechas que estoy tomando en la
-- rendicion".
--
-- Hoy no existia: todo lo que agrega deuda lo hace POR CLIENTE y sin rango de
-- fechas (`obtener_deudores_mora` mig 075, ReporteCuentasPorCobrar) o da solo el
-- numero total sin detalle (`reporte_gerencial -> cobranza.pendiente`).
--
-- Devuelve una fila POR PEDIDO. El rango filtra por FECHA DE ENTREGA (el dia en
-- que se genero la deuda, que es la misma dimension que usa el bloque
-- "Entregado" de la rendicion), no por fecha de pago. Con p_desde/p_hasta NULL
-- devuelve toda la deuda viva.
--
-- Mismo predicado de deuda que mig 075 / 109: entregado + estado_pago
-- pendiente|parcial + saldo > 0.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_pedidos_ctacte_pendientes(
  p_desde date DEFAULT NULL,
  p_hasta date DEFAULT NULL,
  p_transportista_id uuid DEFAULT NULL
)
RETURNS TABLE(
  pedido_id bigint,
  fecha_pedido date,
  fecha_entrega date,
  dias integer,
  cliente_id bigint,
  cliente_nombre text,
  transportista_nombre text,
  total numeric,
  cobrado numeric,
  saldo numeric,
  estado_pago text
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
    p.id AS pedido_id,
    p.fecha AS fecha_pedido,
    (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS fecha_entrega,
    (CURRENT_DATE - (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)::integer AS dias,
    c.id AS cliente_id,
    COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente #' || c.id)::text AS cliente_nombre,
    COALESCE(tr.nombre, 'Sin asignar')::text AS transportista_nombre,
    p.total::numeric AS total,
    COALESCE(p.monto_pagado, 0)::numeric AS cobrado,
    (p.total - COALESCE(p.monto_pagado, 0))::numeric AS saldo,
    COALESCE(p.estado_pago, 'pendiente')::text AS estado_pago
  FROM pedidos p
  LEFT JOIN clientes c ON c.id = p.cliente_id
  LEFT JOIN perfiles tr ON tr.id = p.transportista_id
  WHERE p.sucursal_id = v_sucursal_id
    AND p.estado = 'entregado'
    AND COALESCE(p.estado_pago, 'pendiente') IN ('pendiente', 'parcial')
    AND p.total > COALESCE(p.monto_pagado, 0)
    AND (p_transportista_id IS NULL OR p.transportista_id = p_transportista_id)
    AND (p_desde IS NULL
         OR (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date >= p_desde)
    AND (p_hasta IS NULL
         OR (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date <= p_hasta)
  ORDER BY (p.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date ASC, p.id ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.obtener_pedidos_ctacte_pendientes(date, date, uuid) TO authenticated;
