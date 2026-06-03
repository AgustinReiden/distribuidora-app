-- Migración 075: RPC obtener_deudores_mora
--
-- Lista los clientes en mora de la sucursal activa. La mora se cuenta desde la
-- FECHA DE ENTREGA (no desde la creación del pedido): días vencido =
-- hoy - (fecha_entrega + dias_credito del cliente). Solo cuentan pedidos
-- ENTREGADOS e impagos; los no entregados todavía no generan mora.
-- Para pedidos entregados sin fecha_entrega (datos viejos) se usa pedidos.fecha.
--
-- Devuelve, por cliente con al menos un pedido vencido >= p_dias_min días:
--   saldo (saldo_cuenta total), saldo_vencido (suma de pedidos entregados
--   impagos en mora), dias_mora_max (atraso del más viejo) y la fecha base de
--   ese pedido. Orden: más atrasado primero.
--
-- Gate: es_encargado_o_admin() + current_sucursal_id(). SECURITY DEFINER.

CREATE OR REPLACE FUNCTION public.obtener_deudores_mora(p_dias_min integer DEFAULT 1)
RETURNS TABLE(
  cliente_id bigint,
  nombre text,
  saldo numeric,
  saldo_vencido numeric,
  dias_mora_max integer,
  pedido_mas_viejo date
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
  WITH pedidos_vencidos AS (
    SELECT
      p.cliente_id AS cli_id,
      (p.total - COALESCE(p.monto_pagado, 0)) AS saldo_pedido,
      COALESCE(p.fecha_entrega::date, p.fecha) AS base_date,
      (CURRENT_DATE
        - (COALESCE(p.fecha_entrega::date, p.fecha) + COALESCE(c.dias_credito, 30)))::int AS dias_mora
    FROM pedidos p
    JOIN clientes c ON c.id = p.cliente_id
    WHERE p.sucursal_id = v_sucursal_id
      AND p.estado = 'entregado'
      AND COALESCE(p.estado_pago, 'pendiente') <> 'pagado'
      AND (p.total - COALESCE(p.monto_pagado, 0)) > 0
  )
  SELECT
    c.id AS cliente_id,
    c.nombre_fantasia AS nombre,
    COALESCE(c.saldo_cuenta, 0)::numeric AS saldo,
    COALESCE(SUM(pv.saldo_pedido) FILTER (WHERE pv.dias_mora >= p_dias_min), 0)::numeric AS saldo_vencido,
    MAX(pv.dias_mora)::int AS dias_mora_max,
    MIN(pv.base_date) AS pedido_mas_viejo
  FROM pedidos_vencidos pv
  JOIN clientes c ON c.id = pv.cli_id
  GROUP BY c.id, c.nombre_fantasia, c.saldo_cuenta
  HAVING MAX(pv.dias_mora) >= p_dias_min
  ORDER BY MAX(pv.dias_mora) DESC, COALESCE(c.saldo_cuenta, 0) DESC;
END;
$function$;

ALTER FUNCTION public.obtener_deudores_mora(integer) OWNER TO postgres;

GRANT ALL ON FUNCTION public.obtener_deudores_mora(integer) TO anon;
GRANT ALL ON FUNCTION public.obtener_deudores_mora(integer) TO authenticated;
GRANT ALL ON FUNCTION public.obtener_deudores_mora(integer) TO service_role;
