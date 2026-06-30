-- ============================================================================
-- 106 · reporte_gerencial: filtro de estado (entregadas vs todos los pedidos)
-- ============================================================================
-- Agrega p_incluir_no_entregados:
--   false (default) → solo estado='entregado' (venta entregada, comportamiento previo)
--   true            → estado IN ('entregado','asignado','pendiente') (todos los
--                     pedidos vigentes: incluye pendientes y en camino; excluye
--                     cancelados/anulados).
-- Afecta la CTE 'ped' (venta/CMV/márgenes/categorías/vendedores/etc.). La base de
-- comisión ('nc') NO cambia: siempre es sobre no-cancelados.
-- meta.incluye_no_entregados expone el modo para el front.
--
-- Se DROPea la firma de 3 args y se crea la de 4 (con default) para evitar
-- overloads ambiguos en PostgREST; los callers de 3 args siguen funcionando.
-- ============================================================================

DROP FUNCTION IF EXISTS public.reporte_gerencial(bigint, date, date);

CREATE OR REPLACE FUNCTION public.reporte_gerencial(
  p_sucursal_id bigint,
  p_desde date,
  p_hasta date,
  p_incluir_no_entregados boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[]; v_asignadas bigint[]; v_nombre text; v_result jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_estados text[] := CASE WHEN p_incluir_no_entregados
                           THEN ARRAY['entregado','asignado','pendiente']
                           ELSE ARRAY['entregado'] END;
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
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales,1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario'; END IF;

  WITH
  ped AS (
    SELECT id, cliente_id, usuario_id, total, fecha, forma_pago, estado_pago
    FROM pedidos WHERE estado = ANY(v_estados) AND canal='app'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
  ),
  it AS (
    SELECT p.id AS pedido_id, p.usuario_id, p.fecha,
           pi.cantidad, pi.subtotal, pi.es_bonificacion,
           COALESCE(pi.costo_unitario_al_crear, prod.costo_sin_iva*(1+COALESCE(prod.impuestos_internos,0)/100)) AS costo_unit,
           prod.nombre AS prod_nombre,
           COALESCE(NULLIF(prod.categoria,''),'(sin categoría)') AS categoria,
           (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva = 0) AS sin_costo,
           CASE WHEN pi.es_bonificacion THEN
             CASE WHEN pr.regalo_mueve_stock IS FALSE AND pr.unidades_por_bloque > 0
                  THEN pi.cantidad * COALESCE(pi.costo_unitario_al_crear, prod.costo_sin_iva*(1+COALESCE(prod.impuestos_internos,0)/100)) / pr.unidades_por_bloque
                  ELSE pi.cantidad * COALESCE(pi.costo_unitario_al_crear, prod.costo_sin_iva*(1+COALESCE(prod.impuestos_internos,0)/100)) END
           ELSE 0 END AS costo_bonif
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
  ),
  nc AS (
    SELECT usuario_id, total FROM pedidos
    WHERE estado<>'cancelado' AND canal='app'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
      AND usuario_id IN (SELECT id FROM perfiles)
  ),
  k_ped AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(total),0) AS venta,
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(total)),0) AS ticket FROM ped),
  k_it AS (
    SELECT COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
      COALESCE(SUM(costo_bonif),0) AS bonif,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades,
      COALESCE(SUM(cantidad) FILTER (WHERE es_bonificacion),0) AS unidades_bonif,
      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_sin_costo
    FROM it
  ),
  k_nc AS (SELECT COALESCE(SUM(total),0) AS base_comision FROM nc),
  k_merma AS (
    SELECT COALESCE(SUM(m.cantidad*prod.costo_sin_iva*(1+COALESCE(prod.impuestos_internos,0)/100)),0) AS mermas
    FROM mermas_stock m JOIN productos prod ON prod.id = m.producto_id
    WHERE m.sucursal_id = ANY(v_sucursales)
      AND (m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
      AND COALESCE(m.motivo,'') NOT IN ('promociones','promociones_reversion')
  ),
  k_compra AS (SELECT COALESCE(SUM(total),0) AS compras FROM compras
    WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta),
  k_nuevos AS (SELECT COUNT(*) AS nuevos FROM (
      SELECT cliente_id, MIN(fecha) AS pc FROM pedidos
      WHERE estado='entregado' AND sucursal_id = ANY(v_sucursales) GROUP BY cliente_id
    ) t WHERE pc BETWEEN p_desde AND p_hasta),
  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(total) AS venta,
            COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(total)) AS ticket FROM ped GROUP BY 1),
  m_it AS (SELECT to_char(fecha,'YYYY-MM') AS mes,
           COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
           COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY 1),
  m_merma AS (SELECT to_char(m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM') AS mes,
       SUM(m.cantidad*prod.costo_sin_iva*(1+COALESCE(prod.impuestos_internos,0)/100)) AS mermas
    FROM mermas_stock m JOIN productos prod ON prod.id = m.producto_id
    WHERE m.sucursal_id = ANY(v_sucursales)
      AND (m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
      AND COALESCE(m.motivo,'') NOT IN ('promociones','promociones_reversion') GROUP BY 1),
  m_compra AS (SELECT to_char(fecha_compra,'YYYY-MM') AS mes, SUM(total) AS compras
    FROM compras WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta GROUP BY 1),
  mensual AS (SELECT mp.mes, mp.pedidos, mp.venta, mp.clientes, mp.ticket,
      COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
      COALESCE(mm.mermas,0) AS mermas, COALESCE(mc.compras,0) AS compras
    FROM m_ped mp LEFT JOIN m_it mi ON mi.mes=mp.mes LEFT JOIN m_merma mm ON mm.mes=mp.mes LEFT JOIN m_compra mc ON mc.mes=mp.mes),
  v_ent AS (SELECT usuario_id, COUNT(DISTINCT pedido_id) AS pedidos, SUM(subtotal) AS venta,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY usuario_id),
  v_nc AS (SELECT usuario_id, SUM(total) AS base_nc FROM nc GROUP BY usuario_id),
  vendedores AS (SELECT pf.nombre, pf.rol, e.pedidos, e.venta, e.margen_comercial, e.bonif,
      COALESCE(n.base_nc, e.venta) AS base_nc
    FROM v_ent e JOIN perfiles pf ON pf.id=e.usuario_id LEFT JOIN v_nc n ON n.usuario_id=e.usuario_id),
  categorias AS (SELECT categoria, SUM(subtotal) AS venta,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      COALESCE(SUM(costo_bonif),0) AS bonif, bool_or(sin_costo) AS sin_costo
    FROM it GROUP BY categoria),
  top_prod AS (SELECT prod_nombre AS nombre,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades, SUM(subtotal) AS venta,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen
    FROM it GROUP BY prod_nombre ORDER BY venta DESC LIMIT 10),
  top_cli AS (SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS cliente,
      COUNT(DISTINCT p.id) AS pedidos, SUM(p.total) AS venta
    FROM ped p JOIN clientes c ON c.id=p.cliente_id GROUP BY 1 ORDER BY venta DESC LIMIT 10),
  bonif_det AS (SELECT prod_nombre AS nombre, SUM(cantidad) AS unidades, SUM(costo_bonif) AS costo
    FROM it WHERE es_bonificacion GROUP BY prod_nombre HAVING SUM(cantidad) > 0 ORDER BY costo DESC LIMIT 12),
  mermas_motivo AS (SELECT COALESCE(NULLIF(m.motivo,''),'(sin motivo)') AS motivo,
      SUM(m.cantidad) AS unidades, SUM(m.cantidad*prod.costo_sin_iva*(1+COALESCE(prod.impuestos_internos,0)/100)) AS costo
    FROM mermas_stock m JOIN productos prod ON prod.id=m.producto_id
    WHERE m.sucursal_id = ANY(v_sucursales)
      AND (m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
      AND COALESCE(m.motivo,'') NOT IN ('promociones','promociones_reversion') GROUP BY 1),
  formas AS (SELECT COALESCE(forma_pago,'(sin dato)') AS forma_pago, SUM(total) AS monto FROM ped GROUP BY 1),
  cobr AS (SELECT COALESCE(SUM(total) FILTER (WHERE estado_pago='pagado'),0) AS cobrado,
      COALESCE(SUM(total) FILTER (WHERE estado_pago IN ('pendiente','parcial')),0) AS pendiente FROM ped),
  serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(total) AS venta FROM ped GROUP BY fecha ORDER BY fecha)
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre,'?'),
      'desde', p_desde, 'hasta', p_hasta, 'generado_at', now(),
      'incluye_no_entregados', p_incluir_no_entregados),
    'kpis', (SELECT jsonb_build_object('venta', kp.venta, 'pedidos', kp.pedidos, 'clientes', kp.clientes, 'ticket', kp.ticket,
        'clientes_nuevos', kn.nuevos, 'cmv', ki.cmv, 'bonif', ki.bonif, 'unidades', ki.unidades,
        'unidades_bonif', ki.unidades_bonif, 'margen_comercial', kp.venta - ki.cmv,
        'margen_neto', kp.venta - ki.cmv - ki.bonif, 'base_comision', kc.base_comision, 'comision_pct_default', 2,
        'mermas', km.mermas, 'compras', kcp.compras, 'ingreso_sin_costo', ki.ingreso_sin_costo)
      FROM k_ped kp, k_it ki, k_nc kc, k_merma km, k_compra kcp, k_nuevos kn),
    'mensual', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.mes),'[]') FROM mensual m),
    'vendedores', (SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.venta DESC),'[]') FROM vendedores v),
    'categorias', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.venta DESC),'[]') FROM categorias c),
    'top_productos', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_prod t),
    'top_clientes', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_cli t),
    'bonif_detalle', (SELECT COALESCE(jsonb_agg(to_jsonb(b)),'[]') FROM bonif_det b),
    'mermas_motivo', (SELECT COALESCE(jsonb_agg(to_jsonb(mm) ORDER BY mm.costo DESC),'[]') FROM mermas_motivo mm),
    'cobranza', jsonb_build_object('formas', (SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.monto DESC),'[]') FROM formas f),
      'cobrado', (SELECT cobrado FROM cobr), 'pendiente', (SELECT pendiente FROM cobr)),
    'serie_diaria', (SELECT COALESCE(jsonb_agg(jsonb_build_array(s.dia, s.venta)),'[]') FROM serie s),
    'flags', (SELECT jsonb_build_object('ingreso_sin_costo', ki.ingreso_sin_costo,
        'pct_sin_costo', CASE WHEN kp.venta > 0 THEN round(100.0*ki.ingreso_sin_costo/kp.venta,1) ELSE 0 END)
      FROM k_it ki, k_ped kp)
  ) INTO v_result;
  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date, boolean) TO authenticated, service_role;
