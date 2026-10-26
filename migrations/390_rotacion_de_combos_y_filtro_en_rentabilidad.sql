-- Rotacion, combos rotos y filtro de combos en la rentabilidad (#1193, parte B
-- de la entrega 3/4 de #1190)
--
-- 1 · `reporte_combos_rotacion`: por combo, durante su vigencia dentro del
--     periodo,
--       * las unidades por semana de cada componente contra un periodo igual
--         de antes (el producto a mover, `producto_a_mover_id`, viene marcado);
--       * la conversion para "subir el ticket": pedidos con el combo / pedidos
--         con alguno de sus productos;
--     y, para todo el periodo, los combos que rompio el cliente
--     (`cliente_rechaza`, #1192) y el recargo que el pedido paga de mas.
--     Admin y encargado (los costos y los montos no son del deposito).
--
-- 2 · `reporte_rentabilidad` gana `p_combos` ('incluir' | 'excluir' | 'solo')
--     y, por producto, el margen separado: fuera de combo, dentro de combo y
--     total. Es un parametro nuevo con default, asi que se DROPEA la firma
--     vieja (date, date, bigint): dos sobrecargas con rangos superpuestos dan
--     PGRST203 en runtime y no las ve ni tsc ni los tests (CLAUDE.md, trampa 5).
--     El cuerpo es el de la 208/241/318 sin tocar: solo se suma el corte por
--     `combo_id`. La venta sigue siendo LA definicion (entregado, canal <>
--     'cambio', tipo_factura IS DISTINCT FROM 'VB', por pedidos.fecha).
--
-- Funciones nuevas / reemplazadas: se revocan las dos mitades (PUBLIC y anon);
-- las llama el front como authenticated y validan el rol adentro.

-- -------------------------------------------------------------------------
-- 1 · reporte_combos_rotacion
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reporte_combos_rotacion(
  p_sucursal_id bigint,
  p_desde date,
  p_hasta date,
  p_incluir_no_entregados boolean DEFAULT false
) RETURNS jsonb
  LANGUAGE plpgsql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursales bigint[];
  v_asignadas bigint[];
  v_estados text[] := CASE WHEN p_incluir_no_entregados
                           THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                           ELSE ARRAY['entregado'] END;
  v_result jsonb;
BEGIN
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
  ELSE
    IF NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no esta asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  WITH
  -- Vigencia del combo dentro del periodo, y el periodo igual de antes.
  vig AS (
    SELECT c.id AS combo_id, c.nombre, c.activo, c.producto_a_mover_id, c.sucursal_id,
           GREATEST(c.fecha_inicio, p_desde) AS a,
           LEAST(COALESCE(c.fecha_fin, p_hasta), p_hasta) AS b
      FROM combos c
     WHERE c.sucursal_id = ANY(v_sucursales)
       AND GREATEST(c.fecha_inicio, p_desde) <= LEAST(COALESCE(c.fecha_fin, p_hasta), p_hasta)
  ),
  vig2 AS (
    SELECT v.*, (v.b - v.a + 1) AS dias,
           (v.a - (v.b - v.a + 1)) AS prev_a, (v.a - 1) AS prev_b
      FROM vig v
  ),
  -- Los productos de cada combo: los que vendio, los de sus lugares (por
  -- producto o por categoria viva) y el producto a mover.
  prods AS (
    SELECT v.combo_id, cc.producto_id
      FROM vig2 v JOIN combo_componentes cc ON cc.combo_id = v.combo_id AND cc.producto_id IS NOT NULL
    UNION
    SELECT v.combo_id, p.id
      FROM vig2 v
      JOIN combo_componentes cc ON cc.combo_id = v.combo_id AND cc.categoria_id IS NOT NULL
      JOIN productos p ON p.sucursal_id = v.sucursal_id AND p.activo
                      AND (p.categoria_id = cc.categoria_id OR p.subcategoria_id = cc.categoria_id)
    UNION
    SELECT v.combo_id, v.producto_a_mover_id FROM vig2 v WHERE v.producto_a_mover_id IS NOT NULL
    UNION
    SELECT v.combo_id, pi.producto_id
      FROM vig2 v JOIN pedido_items pi ON pi.combo_id = v.combo_id
  ),
  ped AS (
    SELECT p.id, p.fecha, p.sucursal_id
      FROM pedidos p
     WHERE p.estado = ANY(v_estados)
       AND p.canal <> 'cambio'
       AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND p.sucursal_id = ANY(v_sucursales)
       AND p.fecha BETWEEN (SELECT COALESCE(MIN(prev_a), p_desde) FROM vig2) AND p_hasta
  ),
  -- Unidades vendidas de cada componente (por cualquier linea, con o sin
  -- combo, sin regalos) durante la vigencia y en el periodo previo.
  uni AS (
    SELECT v.combo_id, pr.producto_id,
           COALESCE(SUM(pi.cantidad) FILTER (WHERE p.fecha BETWEEN v.a AND v.b), 0) AS durante,
           COALESCE(SUM(pi.cantidad) FILTER (WHERE p.fecha BETWEEN v.prev_a AND v.prev_b), 0) AS antes
      FROM vig2 v
      JOIN prods pr ON pr.combo_id = v.combo_id
      LEFT JOIN pedido_items pi ON pi.producto_id = pr.producto_id AND NOT pi.es_bonificacion
      LEFT JOIN ped p ON p.id = pi.pedido_id AND p.sucursal_id = v.sucursal_id
     GROUP BY v.combo_id, pr.producto_id
  ),
  -- Conversion: pedidos con el combo / pedidos con alguno de sus productos.
  conv AS (
    SELECT v.combo_id,
           COUNT(DISTINCT p.id) FILTER (WHERE EXISTS (
             SELECT 1 FROM pedido_combos pc
              WHERE pc.pedido_id = p.id AND pc.combo_id = v.combo_id)) AS con_combo,
           COUNT(DISTINCT p.id) AS con_producto
      FROM vig2 v
      JOIN prods pr ON pr.combo_id = v.combo_id
      JOIN pedido_items pi ON pi.producto_id = pr.producto_id AND NOT pi.es_bonificacion
      JOIN ped p ON p.id = pi.pedido_id AND p.sucursal_id = v.sucursal_id
                AND p.fecha BETWEEN v.a AND v.b
     GROUP BY v.combo_id
  ),
  -- Combos rotos por el cliente y recargo, en el periodo (no solo en la vigencia).
  rotos AS (
    SELECT pc.combo_id, p.id AS pedido_id,
           pc.cantidad_combos_armados AS armados,
           (pc.cantidad_combos_armados - pc.cantidad_combos) AS rotos,
           pc.recargo
      FROM pedido_combos pc
      JOIN ped p ON p.id = pc.pedido_id AND p.fecha BETWEEN p_desde AND p_hasta
  ),
  rotos_combo AS (
    SELECT r.combo_id, SUM(r.armados) AS armados, SUM(r.rotos) AS rotos,
           COUNT(*) FILTER (WHERE r.rotos > 0) AS pedidos,
           COALESCE(SUM(r.recargo), 0) AS recargo
      FROM rotos r GROUP BY r.combo_id
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('desde', p_desde, 'hasta', p_hasta),
    'combos', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'combo_id', v.combo_id, 'nombre', v.nombre, 'activo', v.activo,
        'producto_a_mover_id', v.producto_a_mover_id,
        'vigencia_desde', v.a, 'vigencia_hasta', v.b, 'dias', v.dias,
        'previo_desde', v.prev_a, 'previo_hasta', v.prev_b,
        'pedidos_con_combo', COALESCE(cv.con_combo, 0),
        'pedidos_con_producto', COALESCE(cv.con_producto, 0),
        'productos', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'producto_id', u.producto_id, 'producto', prod.nombre,
            'es_a_mover', (u.producto_id = v.producto_a_mover_id),
            'unidades_durante', u.durante, 'unidades_antes', u.antes,
            'por_semana_durante', ROUND(u.durante * 7.0 / v.dias, 2),
            'por_semana_antes', ROUND(u.antes * 7.0 / v.dias, 2)
          ) ORDER BY (u.producto_id = v.producto_a_mover_id) DESC, u.durante DESC), '[]'::jsonb)
          FROM uni u JOIN productos prod ON prod.id = u.producto_id
         WHERE u.combo_id = v.combo_id)
      ) ORDER BY COALESCE(cv.con_combo, 0) DESC, v.nombre), '[]'::jsonb)
      FROM vig2 v
      LEFT JOIN conv cv ON cv.combo_id = v.combo_id
     WHERE v.activo OR COALESCE(cv.con_producto, 0) > 0),
    'rotos', jsonb_build_object(
      'combos_armados', (SELECT COALESCE(SUM(armados), 0) FROM rotos_combo),
      'combos_rotos', (SELECT COALESCE(SUM(rotos), 0) FROM rotos_combo),
      'pedidos_afectados', (SELECT COALESCE(SUM(pedidos), 0) FROM rotos_combo),
      'recargo_recuperado', (SELECT COALESCE(SUM(recargo), 0) FROM rotos_combo),
      'por_combo', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'combo_id', rc.combo_id, 'nombre', cb.nombre, 'armados', rc.armados,
          'rotos', rc.rotos, 'pedidos', rc.pedidos, 'recargo', rc.recargo
        ) ORDER BY rc.rotos DESC), '[]'::jsonb)
        FROM rotos_combo rc JOIN combos cb ON cb.id = rc.combo_id WHERE rc.rotos > 0))
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.reporte_combos_rotacion(bigint, date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_combos_rotacion(bigint, date, date, boolean) TO authenticated;

COMMENT ON FUNCTION public.reporte_combos_rotacion(bigint, date, date, boolean) IS
  'Rotacion, conversion y combos rotos por el cliente del reporte gerencial (#1193). Admin y encargado.';

-- -------------------------------------------------------------------------
-- 2 · reporte_rentabilidad con filtro de combos y margen separado
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.reporte_rentabilidad(date, date, bigint);

CREATE OR REPLACE FUNCTION public.reporte_rentabilidad(
  p_desde date DEFAULT NULL::date,
  p_hasta date DEFAULT NULL::date,
  p_sucursal_id bigint DEFAULT NULL::bigint,
  p_combos text DEFAULT 'incluir'
) RETURNS jsonb
  LANGUAGE plpgsql
  STABLE SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_out         jsonb;
BEGIN
  IF p_combos IS NULL OR p_combos NOT IN ('incluir', 'excluir', 'solo') THEN
    RAISE EXCEPTION 'p_combos invalido: %. Valores: incluir, excluir, solo', p_combos;
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
    v_sucursales := COALESCE(v_asignadas, ARRAY(SELECT id FROM sucursales));
  ELSE
    -- #982: la sucursal pedida tiene que ser una de las asignadas.
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  WITH ped AS (
    SELECT p.id, p.tipo_factura
    FROM pedidos p
    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      -- 3XB: el vale blanco va a costo; no es venta ni deja margen.
      AND p.tipo_factura IS DISTINCT FROM 'VB'
      AND p.sucursal_id = ANY(v_sucursales)
      AND (p_desde IS NULL OR p.fecha >= p_desde)
      AND (p_hasta IS NULL OR p.fecha <= p_hasta)
  ),
  it AS (
    SELECT pi.pedido_id,
           pi.producto_id,
           prod.nombre,
           prod.codigo,
           (pi.combo_id IS NOT NULL) AS en_combo,
           pi.cantidad,
           COALESCE(pi.subtotal, pi.cantidad * pi.precio_unitario) AS subtotal,
           pi.cantidad * COALESCE(
             pi.ingreso_real_unitario,
             CASE WHEN ped.tipo_factura = 'FC'
                  THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                  -- 3XB: rama VB explicita, no un ELSE por accidente. Sin IVA:
                  -- el precio ES el ingreso (y el costo). Hoy `ped` ya lo excluye.
                  WHEN ped.tipo_factura = 'VB'
                  THEN pi.precio_unitario
                  ELSE pi.precio_unitario END
           ) AS ingreso_real,
           pi.cantidad * COALESCE(pi.iva_unitario, 0)                AS iva,
           pi.cantidad * COALESCE(pi.impuestos_internos_unitario, 0) AS imp_internos,
           pi.cantidad * COALESCE(pi.neto_unitario,
             COALESCE(pi.ingreso_real_unitario, pi.precio_unitario)) AS neto,
           pi.cantidad * COALESCE(
             pi.costo_unitario_al_crear,
             prod.costo_promedio,
             prod.costo_real,
             ROUND(prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos,0)/100), 4)
           ) AS costo
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    JOIN productos prod ON prod.id = pi.producto_id
    -- #1193: incluir / excluir / sólo las líneas de combo.
    WHERE p_combos = 'incluir'
       OR (p_combos = 'excluir' AND pi.combo_id IS NULL)
       OR (p_combos = 'solo' AND pi.combo_id IS NOT NULL)
  ),
  por_producto AS (
    SELECT it.producto_id, it.nombre, it.codigo,
           SUM(it.cantidad)     AS cantidad_vendida,
           SUM(it.ingreso_real) AS ingresos,
           SUM(COALESCE(it.costo,0)) AS costos,
           SUM(it.cantidad)     FILTER (WHERE it.en_combo)     AS cant_combo,
           SUM(it.ingreso_real) FILTER (WHERE it.en_combo)     AS ing_combo,
           SUM(COALESCE(it.costo,0)) FILTER (WHERE it.en_combo) AS cos_combo,
           SUM(it.cantidad)     FILTER (WHERE NOT it.en_combo) AS cant_fuera,
           SUM(it.ingreso_real) FILTER (WHERE NOT it.en_combo) AS ing_fuera,
           SUM(COALESCE(it.costo,0)) FILTER (WHERE NOT it.en_combo) AS cos_fuera
    FROM it GROUP BY it.producto_id, it.nombre, it.codigo
  )
  SELECT jsonb_build_object(
    'productos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id',               pp.producto_id,
        'nombre',           pp.nombre,
        'codigo',           pp.codigo,
        'cantidadVendida',  pp.cantidad_vendida,
        'ingresos',         ROUND(pp.ingresos,2),
        'costos',           ROUND(pp.costos,2),
        'margen',           ROUND(pp.ingresos - pp.costos,2),
        'margenPorcentaje', CASE WHEN pp.ingresos > 0
                                 THEN ROUND((pp.ingresos - pp.costos) / pp.ingresos * 100, 2)
                                 ELSE 0 END,
        -- #1193: el margen del producto partido en fuera de combo y dentro de combo.
        'fueraDeCombo', jsonb_build_object(
          'cantidad', COALESCE(pp.cant_fuera, 0),
          'ingresos', ROUND(COALESCE(pp.ing_fuera, 0), 2),
          'costos',   ROUND(COALESCE(pp.cos_fuera, 0), 2),
          'margen',   ROUND(COALESCE(pp.ing_fuera, 0) - COALESCE(pp.cos_fuera, 0), 2)),
        'dentroDeCombo', jsonb_build_object(
          'cantidad', COALESCE(pp.cant_combo, 0),
          'ingresos', ROUND(COALESCE(pp.ing_combo, 0), 2),
          'costos',   ROUND(COALESCE(pp.cos_combo, 0), 2),
          'margen',   ROUND(COALESCE(pp.ing_combo, 0) - COALESCE(pp.cos_combo, 0), 2))
      ) ORDER BY (pp.ingresos - pp.costos) DESC)
      FROM por_producto pp
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'ingresosTotales',   COALESCE(ROUND(SUM(ingresos),2),0),
        'costosTotales',     COALESCE(ROUND(SUM(costos),2),0),
        'margenTotal',       COALESCE(ROUND(SUM(ingresos) - SUM(costos),2),0),
        'margenPorcentaje',  CASE WHEN COALESCE(SUM(ingresos),0) > 0
                                  THEN ROUND((SUM(ingresos)-SUM(costos))/SUM(ingresos)*100, 2)
                                  ELSE 0 END,
        -- Con el filtro de combos, los pedidos son los que tienen alguna linea que cuenta.
        'cantidadPedidos',   CASE WHEN p_combos = 'incluir'
                                  THEN (SELECT COUNT(*) FROM ped)
                                  ELSE (SELECT COUNT(DISTINCT pedido_id) FROM it) END,
        'ventasBrutas',      (SELECT COALESCE(ROUND(SUM(subtotal),2),0) FROM it),
        'ivaDiscriminado',   (SELECT COALESCE(ROUND(SUM(iva),2),0) FROM it),
        'impuestosInternos', (SELECT COALESCE(ROUND(SUM(imp_internos),2),0) FROM it),
        'ventasNetas',       (SELECT COALESCE(ROUND(SUM(neto),2),0) FROM it)
      ) FROM por_producto
    )
  ) INTO v_out;

  RETURN v_out;
END;
$function$;

ALTER FUNCTION public.reporte_rentabilidad(date, date, bigint, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_rentabilidad(date, date, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_rentabilidad(date, date, bigint, text) TO authenticated;

COMMENT ON FUNCTION public.reporte_rentabilidad(date, date, bigint, text) IS
  'Margen por producto agregado en la base, con la cascada de costo canonica '
  'de la mig 130 y el ingreso real del snapshot fiscal de la mig 123. mig 208. '
  'p_combos (incluir|excluir|solo) y margen fuera/dentro de combo: mig 390, #1193.';
