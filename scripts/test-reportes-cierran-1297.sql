-- Ensayo de #1297: Rentabilidad, el rendimiento y "Por preventista" cierran
-- contra reporte_gerencial.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, y además no escribe nada.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración de #1297 falla en 2, 3, 4, 5 y 6. El rango arranca fijo en
-- 2026 porque ahí están los casos que muerden: 1.414 líneas de regalo fraccionado
-- y los dos únicos pedidos sin vendedor (872 y 904, de marzo). El paso 1 lo exige:
-- sin ellos, el resto daría verde sin probar nada.
--
--   psql "$DATABASE_URL" -f scripts/test-reportes-cierran-1297.sql

DO $ensayo$
DECLARE
  v_fallas     text[] := '{}';
  v_desde      constant date := DATE '2026-01-01';
  v_hoy        date := public._tablero_hoy();
  v_sucs       bigint[];
  v_suc        bigint;
  v_mes        date;
  v_hasta      date;
  v_red        text;
  v_g          jsonb;
  v_t          jsonb;
  v_rp         jsonb;
  v_vp         jsonb;
  v_b          jsonb;
  v_fila       jsonb;
  v_venta      numeric;
  v_costos     numeric;
  v_x          numeric;
  v_y          numeric;
  v_sv         numeric;
  v_n          int;
  v_tolerancia constant numeric := 0.01;  -- los reportes redondean a 2 decimales
BEGIN
  -- Como servidor (auth.uid() NULL): la Red son todas las activas.
  PERFORM set_config('request.jwt.claims', '', true);
  v_sucs := ARRAY[NULL::bigint] || ARRAY(SELECT id FROM sucursales WHERE activa ORDER BY id);

  -- ------------------------------ 1 · hay datos que hagan morder el ensayo
  SELECT count(*) INTO v_n
    FROM pedidos p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
   WHERE pi.es_bonificacion AND p.estado = 'entregado' AND p.canal <> 'cambio'
     AND p.tipo_factura IS DISTINCT FROM 'VB' AND p.fecha BETWEEN v_desde AND v_hoy
     AND public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock,
                                    pr.unidades_por_bloque) > 1;
  IF v_n = 0 THEN
    v_fallas := v_fallas || 'no hay regalos fraccionados en el rango: REP-N1 no se prueba'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pedidos p
                  WHERE p.usuario_id IS NULL AND p.estado = 'entregado' AND p.canal <> 'cambio'
                    AND p.tipo_factura IS DISTINCT FROM 'VB' AND p.fecha BETWEEN v_desde AND v_hoy) THEN
    v_fallas := v_fallas || 'no hay pedidos sin vendedor en el rango: REP-N2 no se prueba'::text;
  END IF;

  FOREACH v_suc IN ARRAY v_sucs LOOP
    v_red := COALESCE('suc ' || v_suc, 'Red');

    -- -------------- 2 · costos de Rentabilidad = cmv + bonif, en todo el rango
    v_g := public.reporte_gerencial(v_suc, v_desde, v_hoy, false, false);
    v_t := public.reporte_rentabilidad(v_desde, v_hoy, v_suc);
    v_costos := (v_g->'kpis'->>'cmv')::numeric + (v_g->'kpis'->>'bonif')::numeric;
    IF abs((v_t->'totales'->>'costosTotales')::numeric - v_costos) > v_tolerancia THEN
      v_fallas := v_fallas || format('%s · costosTotales %s <> cmv + bonif %s',
        v_red, v_t->'totales'->>'costosTotales', v_costos);
    END IF;

    -- --------------- 3 · "Por preventista" cierra contra la venta y los pedidos
    v_vp := public.reporte_ventas_por_preventista(v_desde, v_hoy, v_suc);
    v_x := (SELECT COALESCE(sum((e->>'totalVentas')::numeric), 0) FROM jsonb_array_elements(v_vp) e);
    v_venta := (v_g->'kpis'->>'venta')::numeric;
    IF abs(v_x - v_venta) > v_tolerancia THEN
      v_fallas := v_fallas || format('%s · Σ totalVentas %s <> venta %s', v_red, v_x, v_venta);
    END IF;
    v_n := (SELECT COALESCE(sum((e->>'cantidadPedidos')::int), 0) FROM jsonb_array_elements(v_vp) e);
    IF v_n <> (v_g->'kpis'->>'pedidos')::int THEN
      v_fallas := v_fallas || format('%s · Σ cantidadPedidos %s <> pedidos %s', v_red, v_n, v_g->'kpis'->>'pedidos');
    END IF;

    v_mes := v_desde;
    WHILE v_mes <= v_hoy LOOP
      v_hasta := (v_mes + interval '1 month - 1 day')::date;
      v_g := public.reporte_gerencial(v_suc, v_mes, v_hasta, false, false);
      v_venta := (v_g->'kpis'->>'venta')::numeric;

      -- Lo mismo mes por mes: un total anual puede cerrar compensando.
      v_t := public.reporte_rentabilidad(v_mes, v_hasta, v_suc);
      v_costos := (v_g->'kpis'->>'cmv')::numeric + (v_g->'kpis'->>'bonif')::numeric;
      IF abs((v_t->'totales'->>'costosTotales')::numeric - v_costos) > v_tolerancia THEN
        v_fallas := v_fallas || format('%s %s · costosTotales %s <> cmv + bonif %s',
          v_red, to_char(v_mes, 'YYYY-MM'), v_t->'totales'->>'costosTotales', v_costos);
      END IF;

      -- ----------------- 4 · el rendimiento cierra y trae la fila "(sin vendedor)"
      v_rp := public.rendimiento_preventistas(v_suc, v_mes);
      v_x := (SELECT COALESCE(sum((e->>'venta')::numeric), 0) FROM jsonb_array_elements(v_rp->'preventistas') e);
      IF abs(v_x - v_venta) > v_tolerancia THEN
        v_fallas := v_fallas || format('%s %s · Σ rendimiento.venta %s <> venta %s',
          v_red, to_char(v_mes, 'YYYY-MM'), v_x, v_venta);
      END IF;

      -- El rendimiento deja la venta sin costo fuera del margen; el gerencial la
      -- cuenta a costo 0. La diferencia tiene que ser exactamente esa.
      v_x := (SELECT COALESCE(sum((e->>'margen_comercial')::numeric + (e->>'venta_sin_costo')::numeric), 0)
                FROM jsonb_array_elements(v_rp->'preventistas') e);
      v_y := (SELECT COALESCE(sum((e->>'margen_comercial')::numeric), 0) FROM jsonb_array_elements(v_g->'vendedores') e);
      IF abs(v_x - v_y) > v_tolerancia THEN
        v_fallas := v_fallas || format('%s %s · margen + venta_sin_costo %s <> margen del gerencial %s',
          v_red, to_char(v_mes, 'YYYY-MM'), v_x, v_y);
      END IF;

      SELECT COALESCE(sum(GREATEST(p.total - p.cargo_envio, 0)), 0) INTO v_sv
        FROM pedidos p
       WHERE p.usuario_id IS NULL AND p.estado = 'entregado' AND p.canal <> 'cambio'
         AND p.tipo_factura IS DISTINCT FROM 'VB' AND p.fecha BETWEEN v_mes AND v_hasta
         AND (v_suc IS NULL OR p.sucursal_id = v_suc)
         AND (v_suc IS NOT NULL OR p.sucursal_id = ANY(public._sucursales_red()));
      v_fila := (SELECT e FROM jsonb_array_elements(v_rp->'preventistas') e WHERE e->>'preventista_id' IS NULL);
      IF v_sv > 0 AND (v_fila IS NULL OR v_fila->>'nombre' <> '(sin vendedor)'
                       OR (v_fila->>'venta')::numeric <> v_sv) THEN
        v_fallas := v_fallas || format('%s %s · rendimiento sin la fila "(sin vendedor)" de %s: %s',
          v_red, to_char(v_mes, 'YYYY-MM'), v_sv, v_fila);
      ELSIF v_sv = 0 AND v_fila IS NOT NULL THEN
        v_fallas := v_fallas || format('%s %s · fila "(sin vendedor)" sin pedidos: %s',
          v_red, to_char(v_mes, 'YYYY-MM'), v_fila);
      END IF;

      -- --------------- 5 · "Por preventista" trae la misma fila, con id NULL
      v_vp := public.reporte_ventas_por_preventista(v_mes, v_hasta, v_suc);
      v_fila := (SELECT e FROM jsonb_array_elements(v_vp) e WHERE e->>'id' IS NULL);
      IF v_sv > 0 AND (v_fila IS NULL OR v_fila->>'nombre' <> '(sin vendedor)'
                       OR (v_fila->>'totalVentas')::numeric <> v_sv) THEN
        v_fallas := v_fallas || format('%s %s · Por preventista sin la fila "(sin vendedor)" de %s: %s',
          v_red, to_char(v_mes, 'YYYY-MM'), v_sv, v_fila);
      ELSIF v_sv = 0 AND v_fila IS NOT NULL THEN
        v_fallas := v_fallas || format('%s %s · Por preventista con "(sin vendedor)" sin pedidos: %s',
          v_red, to_char(v_mes, 'YYYY-MM'), v_fila);
      END IF;

      -- ------- 6 · el bot, que consume "Por preventista", no se rompe con el NULL
      IF v_suc IS NOT NULL AND v_sv > 0 THEN
        v_b := public.bot_ventas_por_preventista(v_mes, v_hasta, v_suc, false, 25)::jsonb;
        IF abs((v_b->>'total_todos_los_roles')::numeric - v_venta) > v_tolerancia
           OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'preventistas') e
                           WHERE e->>'usuario_id' IS NULL AND e->>'nombre' = '(sin vendedor)') THEN
          v_fallas := v_fallas || format('%s %s · bot sin la fila: %s', v_red, to_char(v_mes, 'YYYY-MM'), v_b);
        END IF;
        v_b := public.bot_ventas_por_preventista(v_mes, v_hasta, v_suc, true, 25)::jsonb;
        IF abs((v_b->>'total_todos_los_roles')::numeric - v_venta) > v_tolerancia
           OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'excluidos') e
                           WHERE e->>'nombre' = '(sin vendedor)') THEN
          v_fallas := v_fallas || format('%s %s · bot no excluye la fila: %s', v_red, to_char(v_mes, 'YYYY-MM'), v_b);
        END IF;
      END IF;

      v_mes := (v_mes + interval '1 month')::date;
    END LOOP;
  END LOOP;

  -- ------------------- 7 · dividir el regalo no le borra la marca "sin costo"
  v_t := public.reporte_rentabilidad(v_desde, v_hoy, NULL);
  v_n := (SELECT count(*) FROM jsonb_array_elements(v_t->'productos') e WHERE (e->>'sinCosto')::boolean);
  IF v_n <> (SELECT count(DISTINCT pi.producto_id) + count(DISTINCT 1) FILTER (WHERE pi.producto_id IS NULL)
               FROM pedidos p
               JOIN pedido_items pi ON pi.pedido_id = p.id
               LEFT JOIN productos prod ON prod.id = pi.producto_id
              WHERE p.estado = 'entregado' AND p.canal <> 'cambio'
                AND p.tipo_factura IS DISTINCT FROM 'VB'
                AND p.fecha BETWEEN v_desde AND v_hoy
                AND p.sucursal_id = ANY(public._sucursales_red())
                AND public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                           prod.costo_sin_iva, prod.impuestos_internos) IS NULL) THEN
    v_fallas := v_fallas || format('rentabilidad · %s productos sinCosto, no coincide con las líneas', v_n);
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (todo revertido).';
END
$ensayo$;
