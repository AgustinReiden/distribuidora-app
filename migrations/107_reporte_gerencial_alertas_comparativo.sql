-- ============================================================================
-- 107 · reporte_gerencial: comparativo plegado + alertas (BI Fase 1)
-- ============================================================================
-- Agrega 5º parámetro p_comparar. Cuando true, la función:
--   * calcula el período anterior (misma duración, justo antes) llamándose a sí
--     misma con p_comparar=false (DRY: reusa toda la agregación) y expone sus
--     KPIs en `comparativo`. ⇒ reemplaza la 2ª llamada que hacía el front.
--   * arma `alertas[]` (qué requiere atención) de data ya agregada + 2 queries
--     baratas (clientes inactivos, cobranza vencida).
-- Single function de 5 args (DROP de la de 4) para evitar overloads ambiguos;
-- los callers de 3/4 args siguen andando por los defaults.
-- ============================================================================

DROP FUNCTION IF EXISTS public.reporte_gerencial(bigint, date, date, boolean);

CREATE OR REPLACE FUNCTION public.reporte_gerencial(
  p_sucursal_id bigint,
  p_desde date,
  p_hasta date,
  p_incluir_no_entregados boolean DEFAULT false,
  p_comparar boolean DEFAULT false
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
  v_dias int := (p_hasta - p_desde) + 1;
  v_prev_hasta date := p_desde - 1;
  v_prev_desde date := (p_desde - 1) - ((p_hasta - p_desde));
  v_comparativo jsonb := NULL;
  v_prev jsonb;
  v_alertas jsonb := '[]'::jsonb;
  v_cat_neg int;
  v_cli_inact int;
  v_cob_venc numeric;
  v_cob_venc_cli int;
  v_venta numeric;
  v_prev_venta numeric;
  v_mermas numeric;
  v_prev_mermas numeric;
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

  -- ----- Comparativo: período anterior (recursivo, sin volver a comparar) -----
  IF p_comparar THEN
    v_prev := public.reporte_gerencial(p_sucursal_id, v_prev_desde, v_prev_hasta, p_incluir_no_entregados, false);
    v_comparativo := (v_prev->'kpis') || jsonb_build_object('desde', v_prev_desde, 'hasta', v_prev_hasta);
  END IF;

  -- ----- Alertas: "qué requiere tu atención" -----
  v_venta := (v_result->'kpis'->>'venta')::numeric;
  v_mermas := (v_result->'kpis'->>'mermas')::numeric;
  v_prev_venta := (v_comparativo->>'venta')::numeric;
  v_prev_mermas := (v_comparativo->>'mermas')::numeric;

  IF p_comparar AND COALESCE(v_prev_venta,0) > 0 AND v_venta < v_prev_venta * 0.9 THEN
    v_alertas := v_alertas || jsonb_build_object(
      'severidad', CASE WHEN v_venta < v_prev_venta*0.8 THEN 'critical' ELSE 'warning' END,
      'codigo','venta_caida','titulo','Venta en baja',
      'detalle','Cayó '||round((1 - v_venta/v_prev_venta)*100)::text||'% vs período anterior',
      'valor', v_venta - v_prev_venta, 'seccion','evolucion');
  END IF;

  SELECT COALESCE(SUM(total - COALESCE(monto_pagado,0)),0), COUNT(DISTINCT cliente_id)
    INTO v_cob_venc, v_cob_venc_cli
  FROM pedidos
  WHERE estado='entregado' AND canal='app' AND sucursal_id = ANY(v_sucursales)
    AND COALESCE(estado_pago,'pendiente') IN ('pendiente','parcial')
    AND fecha < CURRENT_DATE - 30 AND total > COALESCE(monto_pagado,0);
  IF v_cob_venc > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','critical','codigo','cobranza_vencida','titulo','Cobranza vencida',
      'detalle', v_cob_venc_cli::text||' cliente(s) con saldo impago hace +30 días',
      'valor', v_cob_venc, 'seccion','cobranza');
  END IF;

  SELECT COUNT(*) INTO v_cli_inact FROM (
    SELECT p.cliente_id FROM pedidos p
    WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
    GROUP BY p.cliente_id
    HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
  ) t;
  IF v_cli_inact > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','clientes_inactivos','titulo','Clientes que dejaron de comprar',
      'detalle', v_cli_inact::text||' cliente(s) sin comprar hace +30 días (compraban hasta hace poco)',
      'valor', v_cli_inact, 'seccion','clientes');
  END IF;

  IF p_comparar AND COALESCE(v_prev_mermas,0) > 0 AND v_mermas > v_prev_mermas*1.3 AND v_mermas > 50000 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','mermas_alza','titulo','Mermas en alza',
      'detalle','Subieron '||round((v_mermas/v_prev_mermas - 1)*100)::text||'% vs período anterior',
      'valor', v_mermas, 'seccion','mermas');
  END IF;

  SELECT COUNT(*) INTO v_cat_neg FROM jsonb_array_elements(v_result->'categorias') c WHERE (c->>'margen_comercial')::numeric < 0;
  IF v_cat_neg > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','margen_categoria_negativo','titulo','Categorías con margen negativo',
      'detalle', v_cat_neg::text||' categoría(s) con margen comercial negativo',
      'valor', v_cat_neg, 'seccion','categorias');
  END IF;

  IF (v_result->'flags'->>'pct_sin_costo')::numeric >= 1 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','info','codigo','productos_sin_costo','titulo','Productos sin costo',
      'detalle', (v_result->'flags'->>'pct_sin_costo')::text||'% de la venta es de productos sin costo (margen sobreestimado)',
      'valor', (v_result->'flags'->>'ingreso_sin_costo')::numeric, 'seccion','categorias');
  END IF;

  -- Ordenar por severidad
  SELECT COALESCE(jsonb_agg(a ORDER BY array_position(ARRAY['critical','warning','info'], a->>'severidad')), '[]'::jsonb)
    INTO v_alertas FROM jsonb_array_elements(v_alertas) a;

  v_result := v_result || jsonb_build_object('comparativo', COALESCE(v_comparativo,'null'::jsonb), 'alertas', v_alertas);
  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date, boolean, boolean) TO authenticated, service_role;
