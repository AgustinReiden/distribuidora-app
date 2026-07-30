-- ============================================================================
-- 141 · FIX: obtener_detalle_rendicion fallaba SIEMPRE por un tipo mal declarado
-- ============================================================================
-- SINTOMA (reportado por Pablo): el "Detalle por cliente" de la rendición decía
-- "0 clientes" / "Ningún cliente pagó con esa forma ese día" y el botón
-- Exportar Excel quedaba en gris. El Excel no estaba roto: el botón se
-- deshabilita cuando el detalle viene vacío.
--
-- CAUSA: `pagos.cliente_id` es INTEGER, pero el RETURNS TABLE declaraba
-- `cliente_id bigint`. En un RETURN QUERY Postgres exige que el tipo de cada
-- columna coincida EXACTAMENTE y aborta con:
--     ERROR: structure of query does not match function result type
-- La función viene fallando así desde la mig 135: nunca devolvió una fila en
-- producción. El front tragaba el error (`if (error) setDetalle([])`) y lo
-- mostraba como "no hay datos", que es lo que lo mantuvo invisible.
--
-- Se castea explícitamente. Chequeado contra information_schema, el resto de
-- las columnas ya coincide: usuario_id es uuid, monto/SUM numeric, COUNT bigint
-- y los nombres van con ::text.
--
-- LECCION DE VERIFICACION: simular el SELECT interno con execute_sql NO prueba
-- nada — el RETURNS TABLE solo se valida al ejecutar la función. Verificar
-- siempre con `SELECT * FROM obtener_detalle_rendicion(...)`.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.obtener_detalle_rendicion(
  p_fecha date,
  p_transportista_id uuid
)
RETURNS TABLE(
  cliente_id bigint,
  cliente_nombre text,
  cobrado_por_id uuid,
  cobrado_por text,
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
    pg.cliente_id::bigint AS cliente_id,   -- <-- el fix: la columna es integer
    COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social, 'Cliente #' || pg.cliente_id)::text AS cliente_nombre,
    pg.usuario_id AS cobrado_por_id,
    COALESCE(u.nombre, 'Sin usuario')::text AS cobrado_por,
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
  LEFT JOIN perfiles u ON u.id = pg.usuario_id
  WHERE pg.fecha = p_fecha
    AND pg.sucursal_id = v_sucursal_id
    AND COALESCE(pd.transportista_id, pg.usuario_id) = p_transportista_id
  GROUP BY pg.cliente_id, c.nombre_fantasia, c.razon_social, pg.usuario_id, u.nombre
  ORDER BY SUM(pg.monto) DESC;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.obtener_detalle_rendicion(date, uuid) TO authenticated;
