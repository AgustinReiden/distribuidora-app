-- ============================================================================
-- 121 · posicion_fiscal: IVA débito/crédito, percepciones e imp. internos
-- ============================================================================
-- Reporte de gestión del período (NO reemplaza la liquidación del contador):
--   · Ventas: mix FC/ZZ (montos y counts), IVA débito (Σ total_iva de FC),
--     II contenido en ventas FC (Σ impuestos_internos_unitario × cantidad).
--   · Compras: mix FC/ZZ, IVA crédito (Σ compras.iva), II soportado,
--     percepciones IVA/IIBB acumuladas (créditos fiscales, mig 113).
--   · saldo_tecnico = iva_debito − iva_credito − percepcion_iva (positivo =
--     IVA a pagar estimado; negativo = crédito a favor).
-- Mismo gate/scoping que reporte_gerencial (admin + usuario_sucursales;
-- service role sin restricción). Ventas = entregadas, canal 'app'.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.posicion_fiscal(
  p_sucursal_id bigint,
  p_desde date,
  p_hasta date
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursales bigint[]; v_asignadas bigint[]; v_nombre text; v_result jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
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
    SELECT id, total, COALESCE(total_neto, total) AS total_neto,
           COALESCE(total_iva, 0) AS total_iva, COALESCE(tipo_factura, 'ZZ') AS tipo_factura
    FROM pedidos
    WHERE estado = 'entregado' AND canal = 'app'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
  ),
  v_fc AS (
    SELECT COALESCE(SUM(pi.cantidad * COALESCE(pi.impuestos_internos_unitario, 0)), 0) AS ii_ventas
    FROM ped p JOIN pedido_items pi ON pi.pedido_id = p.id
    WHERE p.tipo_factura = 'FC' AND NOT COALESCE(pi.es_bonificacion, false)
  ),
  ventas AS (
    SELECT COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_pedidos,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'), 0) AS fc_venta,
           COALESCE(SUM(total_neto) FILTER (WHERE tipo_factura='FC'), 0) AS fc_neto,
           COALESCE(SUM(total_iva) FILTER (WHERE tipo_factura='FC'), 0) AS iva_debito,
           COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_pedidos,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'), 0) AS zz_venta
    FROM ped
  ),
  compras_p AS (
    SELECT COALESCE(tipo_factura, 'FC') AS tipo_factura, subtotal, iva,
           COALESCE(impuestos_internos, 0) AS impuestos_internos,
           COALESCE(percepcion_iva, 0) AS percepcion_iva,
           COALESCE(percepcion_iibb, 0) AS percepcion_iibb, total
    FROM compras
    WHERE sucursal_id = ANY(v_sucursales)
      AND fecha_compra BETWEEN p_desde AND p_hasta
      AND COALESCE(estado, '') <> 'cancelada'
  ),
  compras_k AS (
    SELECT COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_compras,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'), 0) AS fc_total,
           COALESCE(SUM(subtotal) FILTER (WHERE tipo_factura='FC'), 0) AS fc_neto,
           COALESCE(SUM(iva), 0) AS iva_credito,
           COALESCE(SUM(impuestos_internos), 0) AS ii_compras,
           COALESCE(SUM(percepcion_iva), 0) AS percepcion_iva,
           COALESCE(SUM(percepcion_iibb), 0) AS percepcion_iibb,
           COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_compras,
           COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'), 0) AS zz_total
    FROM compras_p
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre, '?'),
      'desde', p_desde, 'hasta', p_hasta, 'generado_at', now(),
      'nota', 'Estimación de gestión; no reemplaza la liquidación del contador. II es costo; percepciones son créditos.'),
    'ventas', (SELECT jsonb_build_object(
        'fc_pedidos', v.fc_pedidos, 'fc_venta', v.fc_venta, 'fc_neto', v.fc_neto,
        'iva_debito', v.iva_debito, 'ii_ventas_fc', f.ii_ventas,
        'zz_pedidos', v.zz_pedidos, 'zz_venta', v.zz_venta,
        'pct_fc', CASE WHEN v.fc_venta + v.zz_venta > 0
                       THEN round(100.0 * v.fc_venta / (v.fc_venta + v.zz_venta), 1) ELSE 0 END)
      FROM ventas v, v_fc f),
    'compras', (SELECT jsonb_build_object(
        'fc_compras', c.fc_compras, 'fc_total', c.fc_total, 'fc_neto', c.fc_neto,
        'iva_credito', c.iva_credito, 'ii_compras', c.ii_compras,
        'percepcion_iva', c.percepcion_iva, 'percepcion_iibb', c.percepcion_iibb,
        'zz_compras', c.zz_compras, 'zz_total', c.zz_total,
        'pct_fc', CASE WHEN c.fc_total + c.zz_total > 0
                       THEN round(100.0 * c.fc_total / (c.fc_total + c.zz_total), 1) ELSE 0 END)
      FROM compras_k c),
    'posicion', (SELECT jsonb_build_object(
        'saldo_tecnico', v.iva_debito - c.iva_credito - c.percepcion_iva,
        'iva_debito', v.iva_debito,
        'iva_credito', c.iva_credito,
        'percepciones_a_favor', c.percepcion_iva + c.percepcion_iibb)
      FROM ventas v, compras_k c)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.posicion_fiscal(bigint, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.posicion_fiscal(bigint, date, date) TO authenticated, service_role;
