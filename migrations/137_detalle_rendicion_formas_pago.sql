-- ============================================================================
-- 137 · obtener_detalle_rendicion: todas las formas de pago por cliente
-- ============================================================================
-- Pedido de Taco Pozo: poder clickear un total del breakdown (p. ej.
-- "Transferencia $90.850") y ver QUE CLIENTES y QUE MONTOS lo componen. Idem
-- cheque, tarjeta, vale blanco, etc.
--
-- La version 135 solo devolvia efectivo / transferencia / otros, con lo cual el
-- drill-down de cheque/tarjeta/vale_blanco era imposible. Se agregan las tres
-- columnas y `otros` pasa a ser el resto real (ni efectivo, ni transferencia,
-- ni cheque, ni tarjeta, ni vale_blanco, ni cuenta_corriente).
--
-- `cuenta_corriente` como forma de pago esta deprecada (mig 074) pero sigue
-- existiendo en datos historicos: se expone aparte para que la suma de columnas
-- cierre siempre contra el total.
-- ============================================================================

DROP FUNCTION IF EXISTS public.obtener_detalle_rendicion(date, uuid);

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
  cheque numeric,
  tarjeta numeric,
  vale_blanco numeric,
  cuenta_corriente numeric,
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
    -- Mismo criterio que obtener_resumen_rendiciones (migs 133/136).
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
    SUM(CASE WHEN pg.forma_pago = 'cheque' THEN pg.monto ELSE 0 END)::numeric AS cheque,
    SUM(CASE WHEN pg.forma_pago = 'tarjeta' THEN pg.monto ELSE 0 END)::numeric AS tarjeta,
    SUM(CASE WHEN pg.forma_pago = 'vale_blanco' THEN pg.monto ELSE 0 END)::numeric AS vale_blanco,
    SUM(CASE WHEN pg.forma_pago = 'cuenta_corriente' THEN pg.monto ELSE 0 END)::numeric AS cuenta_corriente,
    SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia','cheque','tarjeta','vale_blanco','cuenta_corriente')
              OR pg.forma_pago IS NULL THEN pg.monto ELSE 0 END)::numeric AS otros,
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
