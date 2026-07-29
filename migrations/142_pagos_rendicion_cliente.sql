-- ============================================================================
-- 142 · obtener_pagos_rendicion_cliente — los pagos uno por uno
-- ============================================================================
-- PEDIDO (Pablo): poder hacer clic en el detalle de la rendición y ver los
-- datos del pago y del cliente, para manejar todo desde esa pantalla sin tener
-- que ir a buscarlo a otro lado.
--
-- El detalle de la 141 agrega por (cliente, cobrador). Esta RPC es el nivel de
-- abajo: una fila POR PAGO, con el mismo universo (misma fecha, misma sucursal
-- y mismo COALESCE(transportista del pedido, usuario que registró)) filtrando
-- además por cliente.
--
-- Va por RPC y no por un `.from('pagos')` del cliente por dos razones:
--   1) replicar el COALESCE(pd.transportista_id, pg.usuario_id) desde el front
--      obligaría a traer los pedidos aparte solo para poder filtrar;
--   2) la RLS de `pagos` exige es_preventista() — un transportista no puede
--      leer la tabla. SECURITY DEFINER + gate es_encargado_o_admin(), igual que
--      sus hermanas.
--
-- TIPOS: pagos.id, pagos.cliente_id y pagos.pedido_id son INTEGER (no bigint),
-- y forma_pago/referencia son varchar. Se castea todo explícitamente: declarar
-- de más un bigint es exactamente lo que rompió la mig 135 (ver mig 141).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_pagos_rendicion_cliente(
  p_fecha date,
  p_transportista_id uuid,
  p_cliente_id bigint
)
RETURNS TABLE(
  pago_id bigint,
  created_at timestamptz,
  monto numeric,
  forma_pago text,
  referencia text,
  notas text,
  pedido_id bigint,
  pedido_fecha date,
  pedido_estado text,
  pedido_total numeric,
  cobrado_por text,
  es_entrega_del_dia boolean
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
    pg.id::bigint AS pago_id,
    pg.created_at,
    pg.monto::numeric AS monto,
    pg.forma_pago::text AS forma_pago,
    pg.referencia::text AS referencia,
    pg.notas::text AS notas,
    pg.pedido_id::bigint AS pedido_id,
    pd.fecha AS pedido_fecha,
    pd.estado::text AS pedido_estado,
    pd.total::numeric AS pedido_total,
    COALESCE(u.nombre, 'Sin usuario')::text AS cobrado_por,
    -- Mismo criterio verde/azul que obtener_resumen_rendiciones (migs 133/136).
    (pg.pedido_id IS NOT NULL
     AND pd.estado = 'entregado'
     AND COALESCE(pd.fecha_entrega::date, pg.fecha) = pg.fecha) AS es_entrega_del_dia
  FROM pagos pg
  LEFT JOIN pedidos pd ON pd.id = pg.pedido_id
  LEFT JOIN perfiles u ON u.id = pg.usuario_id
  WHERE pg.fecha = p_fecha
    AND pg.sucursal_id = v_sucursal_id
    AND pg.cliente_id = p_cliente_id
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  ORDER BY pg.created_at ASC, pg.id ASC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.obtener_pagos_rendicion_cliente(date, uuid, bigint) TO authenticated;
