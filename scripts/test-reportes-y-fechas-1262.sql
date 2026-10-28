-- Ensayo de #1262 y #1250 (mig 410): los reportes cierran contra su propio
-- total, la Red es una sola, y nada de la tarjeta 7 mira el día UTC.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace (no escribe nada).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la 410 falla en 1, 2, 3, 5 y 6 (y no llega al 7 ni al 8: las dos
-- funciones nuevas no existen). El antes/después con los números está en la
-- propia migración.
--
--   psql "$DATABASE_URL" -f scripts/test-reportes-y-fechas-1262.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_hoy     date := public._tablero_hoy();
  v_desde   date := date_trunc('year', public._tablero_hoy())::date;
  v_admin   uuid;
  v_g       jsonb;
  v_r       jsonb;
  v_lista   jsonb;
  v_x       numeric;
  v_y       numeric;
  v_n       int;
  v_sucs    bigint[];
  v_suc     bigint;
  v_txt     text;
BEGIN
  -- Como servidor (auth.uid() NULL): la Red son todas las activas.
  PERFORM set_config('request.jwt.claims', '', true);
  v_sucs := ARRAY(SELECT id FROM sucursales WHERE activa ORDER BY id);
  v_g := public.reporte_gerencial(NULL, v_desde, v_hoy, false, false);

  -- -------------------- 1 · Σ categorías = Σ vendedores = venta de las líneas
  v_x := (SELECT COALESCE(sum((e->>'venta')::numeric), 0) FROM jsonb_array_elements(v_g->'categorias') e);
  v_y := (SELECT COALESCE(sum((e->>'venta')::numeric), 0) FROM jsonb_array_elements(v_g->'vendedores') e);
  IF v_x <> v_y THEN
    v_fallas := v_fallas || format('gerencial · Σ categorías %s <> Σ vendedores %s', v_x, v_y);
  END IF;
  SELECT COALESCE(sum(pi.subtotal), 0) INTO v_y
    FROM pedidos p JOIN pedido_items pi ON pi.pedido_id = p.id
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN v_desde AND v_hoy AND p.sucursal_id = ANY(v_sucs);
  IF v_x <> v_y THEN
    v_fallas := v_fallas || format('gerencial · Σ categorías %s <> Σ subtotal de las líneas %s (¿se pierden líneas?)', v_x, v_y);
  END IF;

  -- ---------------- 2 · las líneas de productos borrados están, como tales
  SELECT COALESCE(sum(pi.subtotal), 0) INTO v_y
    FROM pedidos p JOIN pedido_items pi ON pi.pedido_id = p.id
   WHERE pi.producto_id IS NULL
     AND p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN v_desde AND v_hoy AND p.sucursal_id = ANY(v_sucs);
  v_x := (SELECT (e->>'venta')::numeric FROM jsonb_array_elements(v_g->'categorias') e
           WHERE e->>'categoria' = '(producto borrado)');
  IF v_y > 0 AND v_x IS DISTINCT FROM v_y THEN
    v_fallas := v_fallas || format('gerencial · categoría "(producto borrado)" = %s, las líneas sin producto suman %s', v_x, v_y);
  END IF;

  -- --------------------------------- 3 · los pedidos sin vendedor están
  SELECT COALESCE(sum(pi.subtotal), 0) INTO v_y
    FROM pedidos p JOIN pedido_items pi ON pi.pedido_id = p.id
   WHERE p.usuario_id IS NULL
     AND p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN v_desde AND v_hoy AND p.sucursal_id = ANY(v_sucs);
  v_x := (SELECT (e->>'venta')::numeric FROM jsonb_array_elements(v_g->'vendedores') e WHERE e->>'id' IS NULL);
  IF v_y > 0 AND (v_x IS DISTINCT FROM v_y) THEN
    v_fallas := v_fallas || format('gerencial · "(sin vendedor)" = %s, los pedidos sin usuario suman %s', v_x, v_y);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'vendedores') e
              WHERE e->>'id' IS NULL AND ((e->>'base_nc')::numeric <> 0 OR e->>'nombre' <> '(sin vendedor)')) THEN
    v_fallas := v_fallas || 'gerencial · la fila sin vendedor no se llama "(sin vendedor)" o tiene base de comisión'::text;
  END IF;

  -- -------- 4 · el detalle de la alerta suma lo mismo que el KPI sin costo
  v_lista := public.reporte_alerta_detalle(NULL, 'productos_sin_costo', v_desde, v_hoy, false);
  v_x := (SELECT COALESCE(sum((e->>'valor')::numeric), 0) FROM jsonb_array_elements(v_lista) e);
  IF jsonb_array_length(v_lista) < 100 AND v_x <> (v_g->'kpis'->>'ingreso_sin_costo')::numeric THEN
    v_fallas := v_fallas || format('alerta productos_sin_costo · suma %s, el KPI dice %s', v_x, v_g->'kpis'->'ingreso_sin_costo');
  END IF;

  -- ---------- 5 · mensual sale de un calendario: un mes por cada mes hasta hoy,
  -- y Σ mensual.compras = kpis.compras. Por sucursal: Taco Pozo empezó a vender
  -- en marzo y antes perdía enero y febrero.
  FOR v_suc IN SELECT s.id FROM sucursales s WHERE s.activa ORDER BY s.id LOOP
    v_g := public.reporte_gerencial(v_suc, v_desde, v_hoy, false, false);
    v_n := (SELECT count(*) FROM generate_series(date_trunc('month', v_desde::timestamp),
                                                 date_trunc('month', v_hoy::timestamp), interval '1 month'));
    IF (SELECT count(*) FROM jsonb_array_elements(v_g->'mensual') e
         WHERE e->>'mes' <= to_char(v_hoy, 'YYYY-MM')) <> v_n THEN
      v_fallas := v_fallas || format('gerencial suc %s · mensual tiene %s meses hasta hoy, el calendario %s',
        v_suc, jsonb_array_length(v_g->'mensual'), v_n);
    END IF;
    v_x := (SELECT COALESCE(sum((e->>'compras')::numeric), 0) FROM jsonb_array_elements(v_g->'mensual') e);
    IF v_x <> (v_g->'kpis'->>'compras')::numeric THEN
      v_fallas := v_fallas || format('gerencial suc %s · Σ mensual.compras %s <> kpis.compras %s', v_suc, v_x, v_g->'kpis'->'compras');
    END IF;
  END LOOP;

  -- ------------------- 6 · rentabilidad: la fila del borrado y la marca sin costo
  v_r := public.reporte_rentabilidad(v_desde, v_hoy, NULL);
  IF EXISTS (SELECT 1 FROM pedidos p JOIN pedido_items pi ON pi.pedido_id = p.id
              WHERE pi.producto_id IS NULL AND p.estado = 'entregado' AND p.canal <> 'cambio'
                AND p.tipo_factura IS DISTINCT FROM 'VB'
                AND p.fecha BETWEEN v_desde AND v_hoy AND p.sucursal_id = ANY(v_sucs))
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'productos') e
                      WHERE e->>'id' IS NULL AND e->>'nombre' = '(producto borrado)'
                        AND (e->>'sinCosto')::boolean) THEN
    v_fallas := v_fallas || 'rentabilidad · falta la fila "(producto borrado)" marcada sin costo'::text;
  END IF;
  IF NOT ((v_r->'totales') ? 'ingresosSinCosto') THEN
    v_fallas := v_fallas || 'rentabilidad · totales sin ingresosSinCosto'::text;
  END IF;

  -- ------------------------------------ 7 · la Red es activas ∩ asignadas
  IF public._sucursales_red() IS DISTINCT FROM v_sucs THEN
    v_fallas := v_fallas || format('_sucursales_red() como servidor = %s, las activas son %s', public._sucursales_red(), v_sucs);
  END IF;
  SELECT us.usuario_id INTO v_admin
    FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.rol = 'admin'
   GROUP BY us.usuario_id ORDER BY count(*) DESC, us.usuario_id LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  IF public._sucursales_red() IS DISTINCT FROM ARRAY(
       SELECT s.id FROM sucursales s JOIN usuario_sucursales us ON us.sucursal_id = s.id
        WHERE s.activa AND us.usuario_id = v_admin ORDER BY s.id) THEN
    v_fallas := v_fallas || format('_sucursales_red() del admin = %s', public._sucursales_red());
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  -- ------------------------------ 8 · nada de la tarjeta 7 mira el día UTC
  v_g := public.auditoria_fechas_utc();
  SELECT string_agg(f->>'nombre', ', ') INTO v_txt
    FROM jsonb_array_elements(v_g->'funciones') f
   WHERE f->>'nombre' IN ('reporte_gerencial', 'reporte_alerta_detalle', 'reporte_cuentas_por_cobrar',
                          'avance_metas_preventista', 'rendimiento_preventistas', 'obtener_deudores_mora',
                          'bot_metricas_admin_dia');
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('siguen con el día UTC: %s', v_txt);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'defaults') d WHERE d->>'columna' = 'pedidos.fecha') THEN
    v_fallas := v_fallas || 'pedidos.fecha sigue con DEFAULT CURRENT_DATE'::text;
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (todo revertido).';
END
$ensayo$;
