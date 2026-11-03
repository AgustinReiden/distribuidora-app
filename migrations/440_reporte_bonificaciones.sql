-- 440 · Reporte de bonificaciones: lo regalado por promoción, agregado y desagregado.
--
-- reporte_bonificaciones(p_desde, p_hasta, p_sucursal_id, p_limite_detalle)
--
--   Hasta acá lo regalado se veía en dos lugares que no contestaban la pregunta:
--     - el gerencial: kpis.bonif (un número) y bonif_promos (promoción × producto),
--       sólo para admin y sin vendedor, cliente ni detalle;
--     - Mermas filtrado por "Promociones": la contrapartida en STOCK del regalo,
--       por día de CARGA. Cuenta pedidos todavía no entregados y queda fuera del
--       total de mermas, así que sus tarjetas daban $ 0.
--   Este reporte sale de los pedidos, con el criterio del gerencial, y cierra
--   EXACTO contra kpis.bonif, kpis.unidades_bonif y kpis.venta (lo verifica el
--   ensayo de abajo).
--
--   Base: pedidos entregados · canal <> 'cambio' · tipo_factura IS DISTINCT FROM
--   'VB' · por pedidos.fecha · sucursal en `_sucursales_red()` o la elegida. Es
--   el `ped` de reporte_gerencial con p_incluir_no_entregados = false.
--   Línea: pedido_items.es_bonificacion. Costo y valor de venta con las fórmulas
--   de `it` del gerencial: costo_valuacion() (la cascada canónica) dividido por
--   factor_bonificacion() (la botella de un fardo vale una fracción del fardo), y
--   el precio de lista de hoy con el mismo divisor. Un producto borrado sigue
--   contando (LEFT JOIN, #1262); sin costo, la línea suma 0 y se cuenta en
--   filas_sin_costo.
--
--   Cortes: por promoción, por producto, por promoción × producto, por vendedor
--   (pedidos.usuario_id, "(sin vendedor)" si falta) y por cliente (inactivos
--   incluidos: es historial). Los de vendedor y cliente traen su venta del
--   período para leer el regalo contra lo vendido. Detalle por línea, de lo más
--   nuevo a lo más viejo, hasta p_limite_detalle (tope 5000).
--
--   Acceso: admin y encargado, con la resolución de sucursales de
--   reporte_mermas (la familia de /reportes, donde el encargado ya ve costos).
--   SECURITY DEFINER de postgres; REVOKE FROM PUBLIC, anon.

CREATE OR REPLACE FUNCTION public.reporte_bonificaciones(
  p_desde date,
  p_hasta date,
  p_sucursal_id bigint DEFAULT NULL::bigint,
  p_limite_detalle integer DEFAULT 2000
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_nombre      text;
  v_limite      integer := LEAST(GREATEST(COALESCE(p_limite_detalle, 2000), 1), 5000);
  v_out         jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL OR p_desde > p_hasta THEN
    RAISE EXCEPTION 'Rango de fechas inválido';
  END IF;

  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := public._sucursales_red();
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no esta asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  WITH
  ped AS (
    SELECT id, fecha, sucursal_id, cliente_id, usuario_id,
           GREATEST(total - cargo_envio, 0) AS venta_prod
      FROM pedidos
     WHERE estado = 'entregado' AND canal <> 'cambio'
       AND tipo_factura IS DISTINCT FROM 'VB'
       AND fecha BETWEEN p_desde AND p_hasta
       AND sucursal_id = ANY(v_sucursales)
  ),
  lin AS (
    SELECT p.id AS pedido_id, p.fecha, p.sucursal_id, p.cliente_id, p.usuario_id,
           pi.promocion_id, pr.nombre AS promo_nombre,
           pi.producto_id, COALESCE(prod.nombre, '(producto borrado)') AS prod_nombre,
           prod.codigo AS prod_codigo,
           pi.cantidad, f.factor, (f.factor > 1) AS es_fraccion,
           -- cantidad y factor son integer: sin el cast, 6 botellas de un fardo de 12 dan 0 bultos.
           pi.cantidad::numeric / f.factor AS bultos,
           f.costo_unit,
           COALESCE(pi.cantidad * f.costo_unit / f.factor, 0) AS costo,
           pi.cantidad * COALESCE(prod.precio, 0) / f.factor AS valor_venta,
           (f.costo_unit IS NULL) AS sin_costo
      FROM ped p
      JOIN pedido_items pi ON pi.pedido_id = p.id AND pi.es_bonificacion
      LEFT JOIN productos prod ON prod.id = pi.producto_id
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id
      CROSS JOIN LATERAL (
        SELECT public.factor_bonificacion(
                 pi.unidades_por_bloque_al_crear,
                 CASE WHEN pi.unidades_por_bloque_al_crear IS NULL AND pi.promocion_id IS NOT NULL
                      THEN public._regalo_modo_del_pedido(pi.pedido_id, pi.promocion_id, pi.sucursal_id) END,
                 pr.unidades_por_bloque) AS factor,
               public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                      prod.costo_sin_iva, prod.impuestos_internos) AS costo_unit
      ) f
     WHERE pi.cantidad <> 0
  ),
  tot AS (
    SELECT COUNT(*) AS lineas,
           COUNT(DISTINCT pedido_id) AS pedidos_con_bonif,
           COUNT(DISTINCT cliente_id) AS clientes_con_bonif,
           COALESCE(SUM(cantidad), 0) AS unidades,
           COALESCE(SUM(bultos), 0) AS bultos,
           COALESCE(SUM(costo), 0) AS costo,
           COALESCE(SUM(valor_venta), 0) AS valor_venta,
           COUNT(*) FILTER (WHERE sin_costo) AS filas_sin_costo
      FROM lin
  ),
  tot_ped AS (
    SELECT COUNT(*) AS pedidos_entregados,
           COALESCE(SUM(venta_prod), 0) AS venta,
           COALESCE(SUM(venta_prod) FILTER (WHERE id IN (SELECT pedido_id FROM lin)), 0) AS venta_pedidos_con_bonif
      FROM ped
  ),
  por_promo AS (
    SELECT l.promocion_id, COALESCE(l.promo_nombre, '(sin promoción)') AS nombre,
           pr.activo, pr.fecha_inicio, pr.fecha_fin,
           COUNT(DISTINCT l.pedido_id) AS pedidos, COUNT(DISTINCT l.cliente_id) AS clientes,
           SUM(l.cantidad) AS unidades, SUM(l.bultos) AS bultos,
           SUM(l.costo) AS costo, SUM(l.valor_venta) AS valor_venta,
           COUNT(*) FILTER (WHERE l.sin_costo) AS filas_sin_costo
      FROM lin l LEFT JOIN promociones pr ON pr.id = l.promocion_id
     GROUP BY l.promocion_id, COALESCE(l.promo_nombre, '(sin promoción)'), pr.activo, pr.fecha_inicio, pr.fecha_fin
  ),
  por_prod AS (
    SELECT producto_id, prod_nombre AS nombre, prod_codigo AS codigo, bool_or(es_fraccion) AS es_fraccion,
           COUNT(DISTINCT pedido_id) AS pedidos,
           SUM(cantidad) AS unidades, SUM(bultos) AS bultos,
           SUM(costo) AS costo, SUM(valor_venta) AS valor_venta,
           COUNT(*) FILTER (WHERE sin_costo) AS filas_sin_costo
      FROM lin GROUP BY producto_id, prod_nombre, prod_codigo
  ),
  por_promo_prod AS (
    SELECT promocion_id, COALESCE(promo_nombre, '(sin promoción)') AS promocion,
           producto_id, prod_nombre AS producto, bool_or(es_fraccion) AS es_fraccion,
           SUM(cantidad) AS unidades, SUM(bultos) AS bultos,
           SUM(costo) AS costo, SUM(valor_venta) AS valor_venta
      FROM lin GROUP BY promocion_id, COALESCE(promo_nombre, '(sin promoción)'), producto_id, prod_nombre
  ),
  -- Vendedor y cliente parten de `ped`, no de `lin`: su venta y sus pedidos
  -- entregados son los del período, tengan regalo o no.
  por_vend AS (
    SELECT p.usuario_id, COALESCE(pf.nombre, '(sin vendedor)') AS nombre,
           COUNT(*) AS pedidos_entregados,
           COUNT(*) FILTER (WHERE b.pedido_id IS NOT NULL) AS pedidos_con_bonif,
           SUM(p.venta_prod) AS venta,
           COALESCE(SUM(b.bultos), 0) AS bultos,
           COALESCE(SUM(b.costo), 0) AS costo,
           COALESCE(SUM(b.valor_venta), 0) AS valor_venta
      FROM ped p
      LEFT JOIN (SELECT pedido_id, SUM(bultos) AS bultos, SUM(costo) AS costo, SUM(valor_venta) AS valor_venta
                   FROM lin GROUP BY pedido_id) b ON b.pedido_id = p.id
      LEFT JOIN perfiles pf ON pf.id = p.usuario_id
     GROUP BY p.usuario_id, COALESCE(pf.nombre, '(sin vendedor)')
    HAVING COUNT(*) FILTER (WHERE b.pedido_id IS NOT NULL) > 0
  ),
  por_cli AS (
    SELECT p.cliente_id, COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social) AS nombre,
           c.codigo, c.activo,
           COUNT(*) AS pedidos_entregados,
           COUNT(*) FILTER (WHERE b.pedido_id IS NOT NULL) AS pedidos_con_bonif,
           SUM(p.venta_prod) AS venta,
           COALESCE(SUM(b.bultos), 0) AS bultos,
           COALESCE(SUM(b.costo), 0) AS costo,
           COALESCE(SUM(b.valor_venta), 0) AS valor_venta
      FROM ped p
      LEFT JOIN (SELECT pedido_id, SUM(bultos) AS bultos, SUM(costo) AS costo, SUM(valor_venta) AS valor_venta
                   FROM lin GROUP BY pedido_id) b ON b.pedido_id = p.id
      LEFT JOIN clientes c ON c.id = p.cliente_id
     GROUP BY p.cliente_id, COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social), c.codigo, c.activo
    HAVING COUNT(*) FILTER (WHERE b.pedido_id IS NOT NULL) > 0
  ),
  det AS (
    SELECT l.pedido_id, l.fecha, s.nombre AS sucursal_nombre,
           l.cliente_id, COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social) AS cliente_nombre,
           c.activo AS cliente_activo,
           l.usuario_id, COALESCE(pf.nombre, '(sin vendedor)') AS vendedor_nombre,
           l.promocion_id, COALESCE(l.promo_nombre, '(sin promoción)') AS promocion_nombre,
           l.producto_id, l.prod_nombre AS producto_nombre, l.prod_codigo AS producto_codigo,
           l.cantidad, l.es_fraccion, l.factor, l.bultos,
           CASE WHEN l.costo_unit IS NULL THEN NULL ELSE l.costo_unit / l.factor END AS costo_unitario,
           l.costo, l.valor_venta, l.sin_costo
      FROM lin l
      LEFT JOIN sucursales s ON s.id = l.sucursal_id
      LEFT JOIN clientes c ON c.id = l.cliente_id
      LEFT JOIN perfiles pf ON pf.id = l.usuario_id
     ORDER BY l.fecha DESC, l.pedido_id DESC, l.prod_nombre
     LIMIT v_limite
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre, '?'),
      'desde', p_desde, 'hasta', p_hasta, 'generado_at', now(),
      'criterio', 'Pedidos entregados por fecha del pedido, sin canjes ni vales blancos. '
               || 'Costo con la cascada canónica (costo congelado de la línea primero); '
               || 'valor de venta a precio de lista de hoy. Cierra contra kpis.bonif del gerencial.'),
    'totales', (SELECT jsonb_build_object(
        'lineas', t.lineas, 'pedidos_con_bonif', t.pedidos_con_bonif,
        'clientes_con_bonif', t.clientes_con_bonif,
        'pedidos_entregados', tp.pedidos_entregados,
        'unidades', t.unidades, 'bultos', round(t.bultos, 2),
        'costo', round(t.costo, 2), 'valor_venta', round(t.valor_venta, 2),
        'venta', round(tp.venta, 2), 'venta_pedidos_con_bonif', round(tp.venta_pedidos_con_bonif, 2),
        'filas_sin_costo', t.filas_sin_costo)
      FROM tot t CROSS JOIN tot_ped tp),
    'por_promocion', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'promocion_id', x.promocion_id, 'nombre', x.nombre, 'activo', x.activo,
        'fecha_inicio', x.fecha_inicio, 'fecha_fin', x.fecha_fin,
        'pedidos', x.pedidos, 'clientes', x.clientes, 'unidades', x.unidades,
        'bultos', round(x.bultos, 2), 'costo', round(x.costo, 2),
        'valor_venta', round(x.valor_venta, 2), 'filas_sin_costo', x.filas_sin_costo)
        ORDER BY x.costo DESC, x.nombre), '[]'::jsonb) FROM por_promo x),
    'por_producto', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'producto_id', x.producto_id, 'nombre', x.nombre, 'codigo', x.codigo,
        'es_fraccion', x.es_fraccion, 'pedidos', x.pedidos, 'unidades', x.unidades,
        'bultos', round(x.bultos, 2), 'costo', round(x.costo, 2),
        'valor_venta', round(x.valor_venta, 2), 'filas_sin_costo', x.filas_sin_costo)
        ORDER BY x.costo DESC, x.nombre), '[]'::jsonb) FROM por_prod x),
    'por_promocion_producto', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'promocion_id', x.promocion_id, 'promocion', x.promocion,
        'producto_id', x.producto_id, 'producto', x.producto, 'es_fraccion', x.es_fraccion,
        'unidades', x.unidades, 'bultos', round(x.bultos, 2),
        'costo', round(x.costo, 2), 'valor_venta', round(x.valor_venta, 2))
        ORDER BY x.promocion, x.costo DESC), '[]'::jsonb) FROM por_promo_prod x),
    'por_vendedor', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'usuario_id', x.usuario_id, 'nombre', x.nombre,
        'pedidos_entregados', x.pedidos_entregados, 'pedidos_con_bonif', x.pedidos_con_bonif,
        'venta', round(x.venta, 2), 'bultos', round(x.bultos, 2),
        'costo', round(x.costo, 2), 'valor_venta', round(x.valor_venta, 2))
        ORDER BY x.costo DESC, x.nombre), '[]'::jsonb) FROM por_vend x),
    'por_cliente', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'cliente_id', x.cliente_id, 'nombre', x.nombre, 'codigo', x.codigo, 'activo', x.activo,
        'pedidos_entregados', x.pedidos_entregados, 'pedidos_con_bonif', x.pedidos_con_bonif,
        'venta', round(x.venta, 2), 'bultos', round(x.bultos, 2),
        'costo', round(x.costo, 2), 'valor_venta', round(x.valor_venta, 2))
        ORDER BY x.costo DESC, x.nombre), '[]'::jsonb) FROM por_cli x),
    'detalle', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'pedido_id', d.pedido_id, 'fecha', d.fecha, 'sucursal_nombre', d.sucursal_nombre,
        'cliente_id', d.cliente_id, 'cliente_nombre', d.cliente_nombre, 'cliente_activo', d.cliente_activo,
        'usuario_id', d.usuario_id, 'vendedor_nombre', d.vendedor_nombre,
        'promocion_id', d.promocion_id, 'promocion_nombre', d.promocion_nombre,
        'producto_id', d.producto_id, 'producto_nombre', d.producto_nombre,
        'producto_codigo', d.producto_codigo,
        'cantidad', d.cantidad, 'es_fraccion', d.es_fraccion, 'factor', d.factor,
        'bultos', round(d.bultos, 2),
        'costo_unitario', round(d.costo_unitario, 2), 'costo', round(d.costo, 2),
        'valor_venta', round(d.valor_venta, 2), 'sin_costo', d.sin_costo)
        ORDER BY d.fecha DESC, d.pedido_id DESC, d.producto_nombre), '[]'::jsonb) FROM det d),
    'detalle_total', (SELECT lineas FROM tot),
    'detalle_limite', v_limite,
    'detalle_truncado', (SELECT lineas FROM tot) > v_limite
  ) INTO v_out;

  RETURN v_out;
END
$function$;

COMMENT ON FUNCTION public.reporte_bonificaciones(date, date, bigint, integer) IS
  'Bonificaciones (regalos de promoción) de los pedidos entregados del período, agregadas y por línea. '
  'Cierra contra kpis.bonif de reporte_gerencial. Admin y encargado.';

REVOKE ALL ON FUNCTION public.reporte_bonificaciones(date, date, bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_bonificaciones(date, date, bigint, integer) TO authenticated, service_role;

-- Ensayo: el reporte cierra contra el gerencial en cada sucursal y en la red,
-- en el mes en curso y en los dos anteriores, y sus cortes suman su total.
-- Corre como servidor (auth.uid() NULL), igual que el gerencial.
DO $ensayo_bonif$
DECLARE
  v_fallas text[] := '{}';
  v_suc    bigint;
  v_desde  date;
  v_hasta  date;
  v_g      jsonb;
  v_b      jsonb;
  v_hoy    date := public._tablero_hoy();
  v_m      int;
  v_corte  text;
  v_suma   numeric;
BEGIN
  FOR v_m IN 0..2 LOOP
    v_desde := (date_trunc('month', v_hoy) - make_interval(months => v_m))::date;
    v_hasta := LEAST((v_desde + interval '1 month - 1 day')::date, v_hoy);
    FOR v_suc IN SELECT NULL::bigint UNION ALL SELECT id FROM sucursales WHERE id = ANY(public._sucursales_red()) LOOP
      v_g := public.reporte_gerencial(v_suc, v_desde, v_hasta);
      v_b := public.reporte_bonificaciones(v_desde, v_hasta, v_suc);

      IF abs((v_g->'kpis'->>'bonif')::numeric - (v_b->'totales'->>'costo')::numeric) > 0.01 THEN
        v_fallas := v_fallas || format('suc %s %s..%s: costo %s vs kpis.bonif %s', COALESCE(v_suc::text, 'red'),
          v_desde, v_hasta, v_b->'totales'->>'costo', v_g->'kpis'->>'bonif');
      END IF;
      IF (v_g->'kpis'->>'unidades_bonif')::numeric IS DISTINCT FROM (v_b->'totales'->>'unidades')::numeric THEN
        v_fallas := v_fallas || format('suc %s %s..%s: unidades %s vs kpis.unidades_bonif %s', COALESCE(v_suc::text, 'red'),
          v_desde, v_hasta, v_b->'totales'->>'unidades', v_g->'kpis'->>'unidades_bonif');
      END IF;
      IF abs((v_g->'kpis'->>'venta')::numeric - (v_b->'totales'->>'venta')::numeric) > 0.01 THEN
        v_fallas := v_fallas || format('suc %s %s..%s: venta %s vs kpis.venta %s', COALESCE(v_suc::text, 'red'),
          v_desde, v_hasta, v_b->'totales'->>'venta', v_g->'kpis'->>'venta');
      END IF;
      SELECT COALESCE(SUM((x->>'valor_venta')::numeric), 0) INTO v_suma FROM jsonb_array_elements(v_g->'bonif_promos') x;
      IF abs(v_suma - (v_b->'totales'->>'valor_venta')::numeric) > 0.05 THEN
        v_fallas := v_fallas || format('suc %s %s..%s: valor_venta %s vs bonif_promos %s', COALESCE(v_suc::text, 'red'),
          v_desde, v_hasta, v_b->'totales'->>'valor_venta', v_suma);
      END IF;

      -- Cada corte suma el costo total (redondeado por fila: tolerancia de centavos).
      FOREACH v_corte IN ARRAY ARRAY['por_promocion', 'por_producto', 'por_promocion_producto', 'por_vendedor', 'por_cliente'] LOOP
        SELECT COALESCE(SUM((x->>'costo')::numeric), 0) INTO v_suma FROM jsonb_array_elements(v_b->v_corte) x;
        IF abs(v_suma - (v_b->'totales'->>'costo')::numeric) > 0.01 * GREATEST(jsonb_array_length(v_b->v_corte), 1) THEN
          v_fallas := v_fallas || format('suc %s %s..%s: %s suma %s, total %s', COALESCE(v_suc::text, 'red'),
            v_desde, v_hasta, v_corte, v_suma, v_b->'totales'->>'costo');
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ensayo bonificaciones · % fallas, la migracion no se aplica:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
END
$ensayo_bonif$;
