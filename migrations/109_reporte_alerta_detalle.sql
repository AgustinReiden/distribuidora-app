-- ============================================================================
-- 109 · reporte_alerta_detalle: lista on-demand detrás de cada alerta (BI)
-- ============================================================================
-- Al hacer click en una alerta, el front trae acá la LISTA concreta que la
-- alerta referencia (clientes que deben, clientes inactivos, productos sin
-- costo). Lazy: solo se llama al click. Admin-only + scope de sucursal, igual
-- que reporte_gerencial. p_sucursal_id NULL = red.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reporte_alerta_detalle(
  p_sucursal_id bigint,
  p_codigo text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_sucursales bigint[];
  v_asignadas bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_result jsonb;
BEGIN
  IF NOT v_es_servicio THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin'; END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'; END IF;
  END IF;
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales,1) IS NULL THEN
    RETURN '[]'::jsonb; END IF;

  IF p_codigo = 'cobranza_vencida' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             SUM(p.total - COALESCE(p.monto_pagado,0)) AS valor,
             'hace ' || MAX(CURRENT_DATE - p.fecha) || ' días' AS detalle
      FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
      WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
        AND COALESCE(p.estado_pago,'pendiente') IN ('pendiente','parcial')
        AND p.fecha < CURRENT_DATE - 30 AND p.total > COALESCE(p.monto_pagado,0)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      LIMIT 100
    ) t;
  ELSIF p_codigo = 'clientes_inactivos' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC NULLS LAST), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             COALESCE(SUM(p.total) FILTER (WHERE p.fecha >= CURRENT_DATE - 90), 0) AS valor,
             'sin comprar hace ' || (CURRENT_DATE - MAX(p.fecha)) || ' días' AS detalle
      FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
      WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
      LIMIT 200
    ) t;
  ELSIF p_codigo = 'productos_sin_costo' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT prod.nombre AS nombre, SUM(pi.subtotal) AS valor, 'sin costo cargado' AS detalle
      FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id JOIN productos prod ON prod.id = pi.producto_id
      WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
        AND NOT pi.es_bonificacion AND (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva = 0)
      GROUP BY prod.id, prod.nombre
      LIMIT 100
    ) t;
  ELSE
    v_result := '[]'::jsonb;
  END IF;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.reporte_alerta_detalle(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_alerta_detalle(bigint, text) TO authenticated, service_role;
