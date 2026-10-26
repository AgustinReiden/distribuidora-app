-- El analisis de combos del reporte gerencial (#1193, entrega 3/4 de #1190)
--
-- RPC `reporte_combos`: agrega en la base, por combo y por producto dentro del
-- combo, lo que el dueño necesita ver (mig 208: agregar en la base, no en la
-- app). Sale solo de las lineas de combo de `pedido_items` (combo_id,
-- precio_sin_combo_unitario, precio, costo, ingreso real) y de la foto
-- `pedido_combos`; no hay tablas nuevas.
--
-- Por que una RPC aparte y no una clave mas de `reporte_gerencial`: esa funcion
-- tiene ~600 lineas, es solo admin y la leen otros callers (bot, export); los
-- costos no se leen por REST (#974), y esta es la unica forma de dar costo y
-- margen por producto dentro de un combo. Va por RPC SECURITY DEFINER para
-- admin y encargado: el deposito no lee montos (307).
--
-- La venta usa LA definicion (migs 241/318): estado = 'entregado' (o los del
-- toggle "Todos"), canal <> 'cambio', tipo_factura IS DISTINCT FROM 'VB', por
-- pedidos.fecha. El margen es el REAL (mig 123/124): suma de
-- `ingreso_real_unitario` menos el costo por `costo_valuacion` (la misma
-- cascada que el resto del reporte, para que un combo y su producto fuera de
-- combo se valuen igual).
--
-- Cuidado contable: el descuento del combo (Σ (precio sin combo - precio) ×
-- cantidad) es INFORMATIVO. La venta ya entro mas barata, asi que restarlo en
-- la cascada o en el margen neto lo contaria dos veces. Esta funcion no toca
-- `reporte_gerencial` a proposito.
--
-- Combos vendidos = Σ pedido_combos.cantidad_combos (los VIVOS: un combo roto
-- por `cliente_rechaza`, #1192, ya no cuenta). Los parametros son BIGINT/DATE/
-- BOOLEAN: nada de SMALLINT (trampa 5).
--
-- Funcion nueva: se revocan las dos mitades (PUBLIC y anon) y la llama el front
-- como authenticated; el rol y la sucursal se validan adentro.

CREATE OR REPLACE FUNCTION public.reporte_combos(
  p_sucursal_id bigint,
  p_desde date,
  p_hasta date,
  p_incluir_no_entregados boolean DEFAULT false,
  p_comparar boolean DEFAULT false
) RETURNS jsonb
  LANGUAGE plpgsql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursales bigint[];
  v_asignadas bigint[];
  v_nombre text;
  v_estados text[] := CASE WHEN p_incluir_no_entregados
                           THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                           ELSE ARRAY['entregado'] END;
  v_prev_desde date := (p_desde - 1) - (p_hasta - p_desde);
  v_ini date;
  v_result jsonb;
BEGIN
  -- Rol PRINCIPAL admin o encargado (es_preventista() daria true al reves,
  -- trampa 4). Sin sesion no hay nada que leer: no hay camino de servicio.
  IF auth.uid() IS NULL OR NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
  END IF;
  SELECT array_agg(sucursal_id) INTO v_asignadas
    FROM usuario_sucursales WHERE usuario_id = auth.uid();
  IF v_asignadas IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
  END IF;

  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(s.id) INTO v_sucursales
      FROM sucursales s WHERE s.activa AND s.id = ANY(v_asignadas);
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no esta asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  v_ini := CASE WHEN p_comparar THEN v_prev_desde ELSE p_desde END;

  WITH
  ped AS (
    SELECT p.id, p.fecha, (p.fecha >= p_desde) AS actual,
           COALESCE(p.tipo_factura, 'ZZ') AS tipo_factura
      FROM pedidos p
     WHERE p.estado = ANY(v_estados)
       AND p.canal <> 'cambio'
       AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND p.fecha BETWEEN v_ini AND p_hasta
       AND p.sucursal_id = ANY(v_sucursales)
  ),
  lin AS (
    SELECT p.id AS pedido_id, p.fecha, p.actual, pi.combo_id, pi.producto_id,
           pi.cantidad,
           pi.subtotal AS venta,
           pi.cantidad * (COALESCE(pi.precio_sin_combo_unitario, pi.precio_unitario) - pi.precio_unitario) AS descuento,
           pi.cantidad * COALESCE(
             public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                    prod.costo_sin_iva, prod.impuestos_internos), 0) AS costo,
           pi.cantidad * COALESCE(pi.ingreso_real_unitario,
             CASE WHEN p.tipo_factura = 'FC' THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                  ELSE pi.precio_unitario END) AS ingreso_real,
           prod.nombre AS producto
      FROM ped p
      JOIN pedido_items pi ON pi.pedido_id = p.id
      JOIN productos prod ON prod.id = pi.producto_id
     WHERE pi.combo_id IS NOT NULL AND NOT pi.es_bonificacion
  ),
  -- Una fila por (pedido, combo): lo que vendio y cuantos combos vivos hay.
  pc AS (
    SELECT l.pedido_id, l.combo_id, l.fecha, l.actual,
           SUM(l.venta) AS venta, SUM(l.descuento) AS descuento,
           SUM(l.costo) AS costo, SUM(l.ingreso_real) AS ingreso_real,
           COALESCE(MAX(c.cantidad_combos), 0) AS combos
      FROM lin l
      LEFT JOIN pedido_combos c ON c.pedido_id = l.pedido_id AND c.combo_id = l.combo_id
     GROUP BY l.pedido_id, l.combo_id, l.fecha, l.actual
  ),
  por_combo AS (
    SELECT pc.combo_id, SUM(pc.combos) AS combos, SUM(pc.venta) AS venta,
           SUM(pc.descuento) AS descuento, SUM(pc.costo) AS costo,
           SUM(pc.ingreso_real) AS ingreso_real,
           SUM(pc.ingreso_real) - SUM(pc.costo) AS margen
      FROM pc WHERE pc.actual GROUP BY pc.combo_id
  ),
  por_producto AS (
    SELECT l.combo_id, l.producto_id, MAX(l.producto) AS producto,
           SUM(l.cantidad) AS unidades, SUM(l.venta) AS venta,
           SUM(l.descuento) AS descuento, SUM(l.costo) AS costo,
           SUM(l.ingreso_real) - SUM(l.costo) AS margen
      FROM lin l WHERE l.actual GROUP BY l.combo_id, l.producto_id
  ),
  mensual AS (
    SELECT to_char(pc.fecha, 'YYYY-MM') AS mes, pc.combo_id, SUM(pc.combos) AS combos,
           SUM(pc.venta) AS venta, SUM(pc.descuento) AS descuento,
           SUM(pc.ingreso_real) - SUM(pc.costo) AS margen
      FROM pc WHERE pc.actual GROUP BY 1, 2
  ),
  semanal AS (
    SELECT date_trunc('week', pc.fecha)::date AS semana, pc.combo_id, SUM(pc.combos) AS combos,
           SUM(pc.venta) AS venta, SUM(pc.descuento) AS descuento,
           SUM(pc.ingreso_real) - SUM(pc.costo) AS margen
      FROM pc WHERE pc.actual GROUP BY 1, 2
  ),
  tot AS (
    SELECT COALESCE(SUM(combos), 0) AS combos, COALESCE(SUM(venta), 0) AS venta,
           COALESCE(SUM(descuento), 0) AS descuento, COALESCE(SUM(costo), 0) AS costo,
           COALESCE(SUM(ingreso_real), 0) AS ingreso_real, COALESCE(SUM(margen), 0) AS margen
      FROM por_combo
  ),
  prev AS (
    SELECT COALESCE(SUM(pc.descuento), 0) AS descuento, COALESCE(SUM(pc.venta), 0) AS venta
      FROM pc WHERE NOT pc.actual
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('sucursal_id', p_sucursal_id, 'sucursal_nombre', v_nombre,
                               'desde', p_desde, 'hasta', p_hasta),
    'kpis', (SELECT jsonb_build_object(
               'combos_vendidos', t.combos, 'venta', t.venta, 'descuento', t.descuento,
               'costo', t.costo, 'ingreso_real', t.ingreso_real, 'margen', t.margen,
               'descuento_anterior', CASE WHEN p_comparar THEN pv.descuento END,
               'venta_anterior', CASE WHEN p_comparar THEN pv.venta END)
             FROM tot t, prev pv),
    'combos', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                 'combo_id', c.combo_id, 'nombre', cb.nombre, 'sucursal_id', cb.sucursal_id,
                 'combos_vendidos', c.combos, 'venta', c.venta, 'descuento', c.descuento,
                 'costo', c.costo, 'ingreso_real', c.ingreso_real, 'margen', c.margen,
                 'productos', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                      'producto_id', pp.producto_id, 'producto', pp.producto,
                      'unidades', pp.unidades, 'venta', pp.venta, 'descuento', pp.descuento,
                      'costo', pp.costo, 'margen', pp.margen) ORDER BY pp.venta DESC), '[]'::jsonb)
                    FROM por_producto pp WHERE pp.combo_id = c.combo_id))
               ORDER BY c.venta DESC), '[]'::jsonb)
               FROM por_combo c JOIN combos cb ON cb.id = c.combo_id),
    'mensual', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.mes, m.combo_id), '[]'::jsonb) FROM mensual m),
    'semanal', (SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.semana, s.combo_id), '[]'::jsonb) FROM semanal s)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.reporte_combos(bigint, date, date, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_combos(bigint, date, date, boolean, boolean) TO authenticated;

COMMENT ON FUNCTION public.reporte_combos(bigint, date, date, boolean, boolean) IS
  'Analisis de combos del reporte gerencial (#1193). Admin y encargado. El descuento es informativo: no se resta de ningun margen.';
