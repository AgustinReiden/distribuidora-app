-- ============================================================================
-- 131 · reporte_valuacion_inventario: stock valuado a costo promedio (CPP)
-- ============================================================================
-- Nuevo RPC. Devuelve el inventario valuado a costo promedio (mig 127) con
-- columna comparativa a costo de reposición (costo_real):
--   · productos: stock, cpp, reposición, valuacion_promedio, valuacion_reposicion
--   · agregados por categoría y por sucursal + totales generales
--   · calidad de datos: productos con stock negativo y con costo nulo
-- Permisos: admin y encargado, limitados a sus sucursales asignadas (mismo
-- patrón que reporte_gerencial; service_role sin restricción).
-- p_sucursal_id NULL ⇒ consolidado de las sucursales activas visibles.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.reporte_valuacion_inventario(
  p_sucursal_id bigint DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[]; v_asignadas bigint[]; v_nombre text; v_result jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol text;
BEGIN
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado'; END IF;
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
  base AS (
    SELECT p.id, p.nombre, p.stock, p.sucursal_id, s.nombre AS sucursal_nombre,
           COALESCE(NULLIF(p.categoria,''),'(sin categoría)') AS categoria,
           -- CPP con la misma cascada de fallback que los snapshots (mig 129)
           COALESCE(p.costo_promedio, p.costo_real,
                    round(p.costo_sin_iva*(1+COALESCE(p.impuestos_internos,0)/100), 4)) AS cpp,
           COALESCE(p.costo_real,
                    round(p.costo_sin_iva*(1+COALESCE(p.impuestos_internos,0)/100), 4)) AS reposicion,
           p.ultimo_tipo_compra
    FROM productos p
    JOIN sucursales s ON s.id = p.sucursal_id
    WHERE p.sucursal_id = ANY(v_sucursales)
  ),
  val AS (
    SELECT b.*,
           round(GREATEST(b.stock,0) * COALESCE(b.cpp,0), 2)        AS valuacion_promedio,
           round(GREATEST(b.stock,0) * COALESCE(b.reposicion,0), 2) AS valuacion_reposicion
    FROM base b
  ),
  con_stock AS (SELECT * FROM val WHERE stock <> 0),
  productos_j AS (
    SELECT jsonb_agg(jsonb_build_object(
        'producto_id', id, 'nombre', nombre, 'categoria', categoria,
        'sucursal_id', sucursal_id, 'sucursal_nombre', sucursal_nombre,
        'stock', stock,
        'costo_promedio', cpp, 'costo_reposicion', reposicion,
        'ultimo_tipo_compra', ultimo_tipo_compra,
        'valuacion_promedio', valuacion_promedio,
        'valuacion_reposicion', valuacion_reposicion,
        'diferencia', valuacion_reposicion - valuacion_promedio
      ) ORDER BY valuacion_promedio DESC, nombre) AS arr
    FROM con_stock
  ),
  categorias_j AS (
    SELECT jsonb_agg(to_jsonb(c) ORDER BY c.valuacion_promedio DESC) AS arr FROM (
      SELECT categoria,
             COUNT(*) AS productos,
             SUM(GREATEST(stock,0)) AS unidades,
             SUM(valuacion_promedio) AS valuacion_promedio,
             SUM(valuacion_reposicion) AS valuacion_reposicion,
             SUM(valuacion_reposicion) - SUM(valuacion_promedio) AS diferencia
      FROM con_stock GROUP BY categoria
    ) c
  ),
  sucursales_j AS (
    SELECT jsonb_agg(to_jsonb(s) ORDER BY s.valuacion_promedio DESC) AS arr FROM (
      SELECT sucursal_id, sucursal_nombre,
             COUNT(*) AS productos,
             SUM(GREATEST(stock,0)) AS unidades,
             SUM(valuacion_promedio) AS valuacion_promedio,
             SUM(valuacion_reposicion) AS valuacion_reposicion
      FROM con_stock GROUP BY sucursal_id, sucursal_nombre
    ) s
  ),
  tot AS (
    SELECT COUNT(*) AS productos,
           COALESCE(SUM(GREATEST(stock,0)),0) AS unidades,
           COALESCE(SUM(valuacion_promedio),0) AS valuacion_promedio,
           COALESCE(SUM(valuacion_reposicion),0) AS valuacion_reposicion
    FROM con_stock
  ),
  calidad AS (
    SELECT COUNT(*) FILTER (WHERE stock < 0) AS stock_negativo,
           COUNT(*) FILTER (WHERE cpp IS NULL OR cpp = 0) AS sin_costo,
           COALESCE(jsonb_agg(jsonb_build_object('producto_id', id, 'nombre', nombre, 'stock', stock))
             FILTER (WHERE stock < 0), '[]'::jsonb) AS detalle_stock_negativo
    FROM val
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre,'?'),
      'generado_at', now(), 'criterio', 'costo promedio ponderado (fallback: costo reposición)'),
    'totales', (SELECT jsonb_build_object(
        'productos', t.productos, 'unidades', t.unidades,
        'valuacion_promedio', t.valuacion_promedio,
        'valuacion_reposicion', t.valuacion_reposicion,
        'diferencia', t.valuacion_reposicion - t.valuacion_promedio) FROM tot t),
    'sucursales', (SELECT COALESCE(arr,'[]'::jsonb) FROM sucursales_j),
    'categorias', (SELECT COALESCE(arr,'[]'::jsonb) FROM categorias_j),
    'productos', (SELECT COALESCE(arr,'[]'::jsonb) FROM productos_j),
    'calidad_datos', (SELECT jsonb_build_object(
        'stock_negativo', c.stock_negativo, 'sin_costo', c.sin_costo,
        'detalle_stock_negativo', c.detalle_stock_negativo) FROM calidad c)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.reporte_valuacion_inventario(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_valuacion_inventario(bigint) TO authenticated, service_role;
