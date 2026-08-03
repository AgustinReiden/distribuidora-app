-- =========================================================================
-- 161_rendimiento_preventistas.sql
--
-- "Quiero una sección donde analizar el rendimiento de cada preventista:
--  ventas totales, facturación, facturación por categoría de venta."
--
-- POR QUÉ UN RPC NUEVO Y NO EXTENDER reporte_gerencial:
--  1. Agregarle un parámetro cambia la firma → obliga a DROP FUNCTION y a
--     reescribir sus ~200 líneas y 20 CTEs, que es exactamente lo que las
--     migs 124/130 lograron evitar.
--  2. El breakdown marca × preventista multiplica el costo del RPC más pesado
--     de la app, y lo pagarían todas las pantallas que lo consumen aunque no
--     miren metas.
--  3. El gerencial es de rango libre; las metas son estrictamente mensuales.
--     Un % de cumplimiento sobre un rango de 3 días no significa nada.
--
-- Misma base que avance_metas_preventista (mig 160): entregado + canal app,
-- sin bonificaciones. La cascada de costo se copia LITERAL de la mig 130 para
-- que el margen coincida con el del reporte gerencial.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.rendimiento_preventistas(
  p_sucursal_id bigint DEFAULT NULL,
  p_periodo     date   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_periodo    date := date_trunc('month', COALESCE(p_periodo, current_date))::date;
  v_hasta      date;
  v_sucursales bigint[];
  v_asignadas  bigint[];
  v_es_servicio boolean := auth.uid() IS NULL;
  v_result     jsonb;
BEGIN
  v_hasta := (v_periodo + interval '1 month' - interval '1 day')::date;

  IF NOT v_es_servicio AND NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el rendimiento del equipo' USING ERRCODE = '42501';
  END IF;

  -- Resolución de sucursales: mismo criterio que reporte_gerencial.
  -- p_sucursal_id NULL = red consolidada, acotada a las asignadas.
  IF v_es_servicio THEN
    SELECT array_agg(id) INTO v_asignadas FROM sucursales;
  ELSE
    SELECT array_agg(sucursal_id) INTO v_asignadas
    FROM usuario_sucursales WHERE usuario_id = auth.uid();
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := v_asignadas;
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles' USING ERRCODE = '42501';
  END IF;

  WITH
  ped AS MATERIALIZED (
    SELECT id, cliente_id, usuario_id, sucursal_id, total
    FROM pedidos
    WHERE estado = 'entregado' AND canal = 'app'
      AND fecha BETWEEN v_periodo AND v_hasta
      AND sucursal_id = ANY(v_sucursales)
  ),
  it AS MATERIALIZED (
    SELECT p.usuario_id, pi.cantidad, pi.subtotal,
           -- Cascada de costo de la mig 130, literal.
           pi.cantidad * COALESCE(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
             prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos, 0) / 100)) AS costo,
           COALESCE(mar.nombre, '(sin marca)')          AS marca,
           COALESCE(NULLIF(prod.categoria, ''), '(sin categoría)') AS categoria
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod  ON prod.id = pi.producto_id
    LEFT JOIN marcas mar ON mar.id = prod.marca_id
    WHERE pi.es_bonificacion IS NOT TRUE
  ),
  primer_pedido AS (
    SELECT DISTINCT ON (p.cliente_id, p.sucursal_id)
           p.cliente_id, p.sucursal_id, p.usuario_id, p.fecha
    FROM pedidos p
    WHERE p.estado = 'entregado' AND p.canal = 'app'
      AND p.sucursal_id = ANY(v_sucursales)
    ORDER BY p.cliente_id, p.sucursal_id, p.fecha, p.id
  ),
  base AS (
    SELECT p.usuario_id,
           COUNT(*)                        AS pedidos,
           COUNT(DISTINCT p.cliente_id)    AS cobertura,
           COALESCE(SUM(p.total), 0)       AS venta_pedidos
    FROM ped p GROUP BY p.usuario_id
  ),
  items AS (
    SELECT i.usuario_id,
           COALESCE(SUM(i.subtotal), 0) AS venta,
           COALESCE(SUM(i.cantidad), 0) AS unidades,
           COALESCE(SUM(i.subtotal - i.costo), 0) AS margen_comercial
    FROM it i GROUP BY i.usuario_id
  ),
  nuevos AS (
    SELECT pp.usuario_id, COUNT(*) AS clientes_nuevos
    FROM primer_pedido pp
    WHERE pp.fecha BETWEEN v_periodo AND v_hasta
    GROUP BY pp.usuario_id
  ),
  por_marca AS (
    SELECT t.usuario_id, jsonb_agg(jsonb_build_object(
             'marca', t.marca, 'venta', t.venta, 'unidades', t.unidades
           ) ORDER BY t.venta DESC) AS detalle
    FROM (SELECT usuario_id, marca, SUM(subtotal) AS venta, SUM(cantidad) AS unidades
          FROM it GROUP BY usuario_id, marca) t
    GROUP BY t.usuario_id
  ),
  por_categoria AS (
    SELECT t.usuario_id, jsonb_agg(jsonb_build_object(
             'categoria', t.categoria, 'venta', t.venta, 'unidades', t.unidades
           ) ORDER BY t.venta DESC) AS detalle
    FROM (SELECT usuario_id, categoria, SUM(subtotal) AS venta, SUM(cantidad) AS unidades
          FROM it GROUP BY usuario_id, categoria) t
    GROUP BY t.usuario_id
  ),
  metas AS (
    SELECT preventista_id, COUNT(*) AS total FROM metas_preventista
    WHERE periodo = v_periodo AND activo AND sucursal_id = ANY(v_sucursales)
    GROUP BY preventista_id
  )
  SELECT jsonb_build_object(
    'periodo', v_periodo,
    'preventistas', COALESCE(jsonb_agg(jsonb_build_object(
      'preventista_id', b.usuario_id,
      'nombre', COALESCE(pf.nombre, '(sin perfil)'),
      'rol', pf.rol,
      'pedidos', b.pedidos,
      'venta', COALESCE(i.venta, 0),
      'unidades', COALESCE(i.unidades, 0),
      'margen_comercial', COALESCE(i.margen_comercial, 0),
      'cobertura', b.cobertura,
      'clientes_nuevos', COALESCE(n.clientes_nuevos, 0),
      'ticket', ROUND(COALESCE(i.venta, 0) / NULLIF(b.pedidos, 0), 2),
      'metas_cargadas', COALESCE(mt.total, 0),
      'por_marca', COALESCE(pm.detalle, '[]'::jsonb),
      'por_categoria', COALESCE(pc.detalle, '[]'::jsonb)
    ) ORDER BY COALESCE(i.venta, 0) DESC), '[]'::jsonb)
  ) INTO v_result
  FROM base b
  LEFT JOIN perfiles pf     ON pf.id = b.usuario_id
  LEFT JOIN items i         ON i.usuario_id = b.usuario_id
  LEFT JOIN nuevos n        ON n.usuario_id = b.usuario_id
  LEFT JOIN por_marca pm    ON pm.usuario_id = b.usuario_id
  LEFT JOIN por_categoria pc ON pc.usuario_id = b.usuario_id
  LEFT JOIN metas mt        ON mt.preventista_id = b.usuario_id;

  RETURN v_result;
END;
$fn$;

ALTER FUNCTION public.rendimiento_preventistas(bigint, date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.rendimiento_preventistas(bigint, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rendimiento_preventistas(bigint, date) TO authenticated;

COMMENT ON FUNCTION public.rendimiento_preventistas(bigint, date) IS
  'Rendimiento mensual del equipo comercial: venta, unidades, margen, cobertura, clientes nuevos y breakdown por marca y categoría, por preventista. Admin-only. Misma base que avance_metas_preventista. Mig 161.';
