-- Ensayo de la migración «Frenos de NaN y CHECKs que faltaban» (tarjeta B7 de la ola 2 de #1603).
--
--   N1 · 1567-1 / 1562-c1: gastos.iva, percepcion_iva, percepcion_iibb y otros_impuestos en 'NaN' dan 23514 (y con
--        ellos gastos_neto_positivo deja de pasar); −1 también; 0 y un valor normal entran. gastos.litros en 'NaN'.
--   N2 · 1567-5: compra_cargos.iva_monto 'NaN' y −1 dan 23514; 21 entra.
--   N3 · 1557-c1: compra_items.bonificacion 'NaN', 'Infinity', −1 y 101 dan 23514; 0, 15,5, 100 y NULL entran.
--        costo_promedio_anterior 'NaN', 'Infinity' y '-Infinity' dan 23514; −3 entra (calculado, sin piso).
--   N4 · 1567-6 / 1559-c3: notas_credito_venta.neto, iva y total en 'NaN' o 'Infinity' dan 23514; −1 y 0 (total)
--        también; un valor normal entra.
--   N5 · 1567-7 / 1559-c3: nota_credito_venta_items.precio_unitario y subtotal en 'NaN' o 'Infinity' dan 23514.
--   N6 · 1567-8 / 1567-9: pedido_combos.precio y las dos cantidades de pedido_item_sustituciones en 'NaN' dan 23514.
--   N7 · 1567-10: grupo_precio_escala_minimos.precio_unitario_override 'NaN' da 23514; NULL y 50 entran.
--   N8 · H4: pedido_items.costo_unitario_al_crear en 'NaN', 'Infinity' o '-Infinity', y precio_lista_al_crear o
--        descuento_pct en 'NaN', dan 23514; un costo −2 entra (sin piso).
--   N9 · 1596-b1: productos.precio −1, precio_sin_iva −1, stock_minimo −1, cantidad_minima_venta 0 y 100.001, y un
--        nombre vacío o de espacios dan 23514; 0, 100.000 y NULL entran. Por REST como admin, el nombre vacío también.
--   N10 · 1561-b13: clientes.razon_social, nombre_fantasia y direccion vacíos o de espacios dan 23514, por el camino
--        del server y por REST como admin; un texto normal entra.
--   N11 · El barrido: bot_costo_llm_mensual.usd, bot_pedidos_pendientes.cargo_mostrado, bot_presupuesto_llm
--        .techo_usd_mes, empleado_liquidaciones.pagado y rendicion_faltantes.monto en 'NaN'; bot_pedidos_pendientes
--        .total/total_iva/total_neto, movimiento_sucursal_items (9 columnas), movimientos_sucursal.total_costo,
--        rendicion_pagos_confirmados.monto y pedido_total, rendiciones_control.total_entregado_confirmado en 'NaN' o
--        'Infinity'; las coordenadas de sucursales fuera de rango o en 'NaN'. Todos dan 23514; un valor normal entra.
--   A1 · auditoria_nan() no encuentra filas y recorre todas las columnas numeric de public.
--   L1 · Ninguna columna numeric de public queda con un piso sin freno de NaN (barrido por CHECK) ni sin precisión
--        sin freno de infinito (salvo las calculadas por generación y las de la lista que no tienen piso).
--
-- Un único DO que termina siempre en una excepción: no deja nada (salvo valores de secuencia). Cada caso corre en un
-- sub-bloque que se revierte. Sin la migración da 'ENSAYO FALLÓ'. El camino del server corre con
-- session_replication_role = replica: apaga los triggers (y las FK), no los CHECK, así que mide la columna sola. Las
-- filas de prueba nacen con pg_temp.b7_fila, que llena las columnas obligatorias con un valor por tipo.

DO $ensayo$
DECLARE
  v_adm uuid;
  v     text;
  v_r   jsonb;
  f     text[] := '{}';
  rec   record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ── Ayudas ────────────────────────────────────────────────────────────────
  CREATE FUNCTION pg_temp.b7_como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  -- Inserta una fila en public.<p_t> por el camino del server (sin triggers ni FK) y devuelve su ctid. Las columnas
  -- obligatorias sin default se llenan con un valor por tipo; p_j pisa o agrega columnas.
  CREATE FUNCTION pg_temp.b7_fila(p_t text, p_j jsonb, p_uid uuid) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v_j    jsonb := '{}'::jsonb;
    v_cols text;
    v_ctid text;
  BEGIN
    SELECT COALESCE(jsonb_object_agg(a.attname,
             CASE WHEN a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype, 'numeric'::regtype)
                    THEN to_jsonb(1)
                  WHEN a.atttypid = 'bool'::regtype THEN to_jsonb(false)
                  WHEN a.atttypid = 'date'::regtype THEN to_jsonb(public._tablero_hoy())
                  WHEN a.atttypid IN ('timestamptz'::regtype, 'timestamp'::regtype) THEN to_jsonb(now())
                  WHEN a.atttypid = 'uuid'::regtype THEN to_jsonb(p_uid)
                  WHEN a.atttypid IN ('jsonb'::regtype, 'json'::regtype) THEN '[]'::jsonb
                  ELSE to_jsonb('b7 ensayo'::text) END), '{}'::jsonb)
      INTO v_j
      FROM pg_attribute a
     WHERE a.attrelid = ('public.' || p_t)::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attnotnull AND NOT a.atthasdef AND a.attidentity = '' AND a.attgenerated = '';
    v_j := v_j || p_j;
    SELECT string_agg(quote_ident(k), ', ') INTO v_cols FROM jsonb_object_keys(v_j) AS k;
    SET LOCAL session_replication_role = replica;
    EXECUTE format('INSERT INTO public.%I (%s) SELECT %s FROM jsonb_populate_record(NULL::public.%I, $1) RETURNING ctid::text',
                   p_t, v_cols, v_cols, p_t)
      USING v_j INTO v_ctid;
    SET LOCAL session_replication_role = origin;
    RETURN v_ctid;
  END $f$;

  -- Corre p_sql y lo revierte. p_modo: 'server' (postgres, sin triggers) o 'rest' (authenticated, como p_uid).
  -- Devuelve 'ok' o '<SQLSTATE> <constraint>'.
  CREATE FUNCTION pg_temp.b7_err(p_sql text, p_modo text, p_uid uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v_c text;
    v_n bigint;
  BEGIN
    BEGIN
      IF p_modo = 'server' THEN
        SET LOCAL session_replication_role = replica;
      ELSE
        PERFORM pg_temp.b7_como(p_uid, 1);
        SET LOCAL ROLE authenticated;
      END IF;
      EXECUTE p_sql;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 0 THEN
        RAISE EXCEPTION 'sin filas' USING ERRCODE = 'ZZB02';
      END IF;
      RAISE EXCEPTION 'ok' USING ERRCODE = 'ZZB01';
    EXCEPTION
      WHEN SQLSTATE 'ZZB01' THEN RETURN 'ok';
      WHEN SQLSTATE 'ZZB02' THEN RETURN 'el UPDATE no tocó ninguna fila';
      WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_c = CONSTRAINT_NAME;
        RETURN SQLSTATE || ' ' || COALESCE(NULLIF(v_c, ''), '-') || CASE WHEN SQLSTATE <> '23514' THEN ' ' || SQLERRM ELSE '' END;
    END;
  END $f$;

  -- Un UPDATE de la fila p_ctid de p_t con p_set: ¿cae en el CHECK p_check (o, con p_check NULL, entra)?
  CREATE FUNCTION pg_temp.b7_caso(p_f text[], p_t text, p_ctid text, p_set text, p_check text,
                                  p_modo text DEFAULT 'server', p_uid uuid DEFAULT NULL)
  RETURNS text[] LANGUAGE plpgsql AS $f$
  DECLARE
    v_e  text;
    v_id bigint;
  BEGIN
    IF p_modo = 'rest' THEN
      -- Por REST no hay SELECT sobre ctid (productos se concede por columna): se apunta por id.
      EXECUTE format('SELECT id FROM public.%I WHERE ctid = %L::tid', p_t, p_ctid) INTO v_id;
      v_e := pg_temp.b7_err(format('UPDATE public.%I SET %s WHERE id = %s', p_t, p_set, v_id), p_modo, p_uid);
    ELSE
      v_e := pg_temp.b7_err(format('UPDATE public.%I SET %s WHERE ctid = %L::tid', p_t, p_set, p_ctid), p_modo, p_uid);
    END IF;
    IF p_check IS NULL AND v_e <> 'ok' THEN
      RETURN p_f || format('%s.%s no entra (%s)', p_t, p_set, v_e);
    ELSIF p_check IS NOT NULL AND v_e <> '23514 ' || p_check THEN
      RETURN p_f || format('%s.%s → %s, se esperaba %s', p_t, p_set, v_e, p_check);
    END IF;
    RETURN p_f;
  END $f$;

  -- ── Fixtures ──────────────────────────────────────────────────────────────
  SELECT us.usuario_id INTO v_adm
    FROM public.usuario_sucursales us
    JOIN public.perfiles p ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
   WHERE us.sucursal_id = 1
   ORDER BY us.usuario_id LIMIT 1;
  IF v_adm IS NULL THEN
    RAISE EXCEPTION 'ENSAYO SIN FIXTURES: falta un admin activo de la sucursal 1';
  END IF;

  -- ── N1 · gastos ───────────────────────────────────────────────────────────
  v := pg_temp.b7_fila('gastos', jsonb_build_object('sucursal_id', 1, 'comprobante', 'factura_a', 'monto_total', 1000,
         'mes_imputado', date_trunc('month', public._tablero_hoy())::date, 'iva', 100, 'percepcion_iva', 10,
         'percepcion_iibb', 10, 'otros_impuestos', 10, 'alicuota_iva', 21, 'rubro_id',
         COALESCE((SELECT min(id) FROM public.gasto_rubros), 1)), v_adm);
  f := pg_temp.b7_caso(f, 'gastos', v, $$iva = 'NaN'$$, 'gastos_iva_check');
  f := pg_temp.b7_caso(f, 'gastos', v, 'iva = -1', 'gastos_iva_check');
  f := pg_temp.b7_caso(f, 'gastos', v, $$percepcion_iva = 'NaN'$$, 'gastos_percepcion_iva_check');
  f := pg_temp.b7_caso(f, 'gastos', v, $$percepcion_iibb = 'NaN'$$, 'gastos_percepcion_iibb_check');
  f := pg_temp.b7_caso(f, 'gastos', v, $$otros_impuestos = 'NaN'$$, 'gastos_otros_impuestos_check');
  f := pg_temp.b7_caso(f, 'gastos', v, 'otros_impuestos = -1', 'gastos_otros_impuestos_check');
  f := pg_temp.b7_caso(f, 'gastos', v, $$litros = 'NaN'$$, 'gastos_litros_check');
  f := pg_temp.b7_caso(f, 'gastos', v, 'iva = 0, percepcion_iva = 0, percepcion_iibb = 0, otros_impuestos = 0', NULL);
  f := pg_temp.b7_caso(f, 'gastos', v, 'iva = 173.55, litros = 40', NULL);
  f := pg_temp.b7_caso(f, 'gastos', v, 'litros = NULL', NULL);

  -- ── N2 · compra_cargos ────────────────────────────────────────────────────
  v := pg_temp.b7_fila('compra_cargos', jsonb_build_object('sucursal_id', 1, 'monto', 100, 'iva_monto', 21,
         'comprobante_tercero', true, 'en_factura', false, 'condicion_iva', 'gravado'), v_adm);
  f := pg_temp.b7_caso(f, 'compra_cargos', v, $$iva_monto = 'NaN'$$, 'compra_cargos_iva_monto_no_negativo');
  f := pg_temp.b7_caso(f, 'compra_cargos', v, 'iva_monto = -1', 'compra_cargos_iva_monto_no_negativo');
  f := pg_temp.b7_caso(f, 'compra_cargos', v, 'iva_monto = 21', NULL);

  -- ── N3 · compra_items ─────────────────────────────────────────────────────
  v := pg_temp.b7_fila('compra_items', jsonb_build_object('sucursal_id', 1, 'cantidad', 10, 'costo_unitario', 100,
         'bonificacion', 0, 'costo_promedio_anterior', 90), v_adm);
  f := pg_temp.b7_caso(f, 'compra_items', v, $$bonificacion = 'NaN'$$, 'compra_items_bonificacion_rango');
  f := pg_temp.b7_caso(f, 'compra_items', v, $$bonificacion = 'Infinity'$$, 'compra_items_bonificacion_rango');
  f := pg_temp.b7_caso(f, 'compra_items', v, 'bonificacion = -1', 'compra_items_bonificacion_rango');
  f := pg_temp.b7_caso(f, 'compra_items', v, 'bonificacion = 101', 'compra_items_bonificacion_rango');
  f := pg_temp.b7_caso(f, 'compra_items', v, 'bonificacion = 0', NULL);
  f := pg_temp.b7_caso(f, 'compra_items', v, 'bonificacion = 15.5', NULL);
  f := pg_temp.b7_caso(f, 'compra_items', v, 'bonificacion = 100', NULL);
  f := pg_temp.b7_caso(f, 'compra_items', v, 'bonificacion = NULL', NULL);
  f := pg_temp.b7_caso(f, 'compra_items', v, $$costo_promedio_anterior = 'NaN'$$, 'compra_items_costo_promedio_anterior_finito');
  f := pg_temp.b7_caso(f, 'compra_items', v, $$costo_promedio_anterior = 'Infinity'$$, 'compra_items_costo_promedio_anterior_finito');
  f := pg_temp.b7_caso(f, 'compra_items', v, $$costo_promedio_anterior = '-Infinity'$$, 'compra_items_costo_promedio_anterior_finito');
  f := pg_temp.b7_caso(f, 'compra_items', v, 'costo_promedio_anterior = -3', NULL);

  -- ── N4 · notas_credito_venta ──────────────────────────────────────────────
  v := pg_temp.b7_fila('notas_credito_venta', jsonb_build_object('sucursal_id', 1, 'neto', 100, 'iva', 21,
         'total', 121), v_adm);
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, $$neto = 'NaN'$$, 'notas_credito_venta_desglose_no_negativo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, $$neto = 'Infinity'$$, 'notas_credito_venta_desglose_no_negativo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, $$iva = 'NaN'$$, 'notas_credito_venta_desglose_no_negativo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, $$iva = 'Infinity'$$, 'notas_credito_venta_desglose_no_negativo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, 'iva = -1', 'notas_credito_venta_desglose_no_negativo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, $$total = 'NaN'$$, 'notas_credito_venta_total_positivo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, $$total = 'Infinity'$$, 'notas_credito_venta_total_positivo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, 'total = 0', 'notas_credito_venta_total_positivo');
  f := pg_temp.b7_caso(f, 'notas_credito_venta', v, 'neto = 200, iva = 42, total = 242', NULL);

  -- ── N5 · nota_credito_venta_items ─────────────────────────────────────────
  v := pg_temp.b7_fila('nota_credito_venta_items', jsonb_build_object('sucursal_id', 1, 'cantidad', 2,
         'precio_unitario', 50, 'subtotal', 100), v_adm);
  f := pg_temp.b7_caso(f, 'nota_credito_venta_items', v, $$precio_unitario = 'NaN'$$, 'nota_credito_venta_items_precio_unitario_check');
  f := pg_temp.b7_caso(f, 'nota_credito_venta_items', v, $$precio_unitario = 'Infinity'$$, 'nota_credito_venta_items_precio_unitario_check');
  f := pg_temp.b7_caso(f, 'nota_credito_venta_items', v, $$subtotal = 'NaN'$$, 'nota_credito_venta_items_subtotal_check');
  f := pg_temp.b7_caso(f, 'nota_credito_venta_items', v, $$subtotal = 'Infinity'$$, 'nota_credito_venta_items_subtotal_check');
  f := pg_temp.b7_caso(f, 'nota_credito_venta_items', v, 'subtotal = -1', 'nota_credito_venta_items_subtotal_check');
  f := pg_temp.b7_caso(f, 'nota_credito_venta_items', v, 'precio_unitario = 0, subtotal = 0', NULL);

  -- ── N6 · pedido_combos y pedido_item_sustituciones ────────────────────────
  v := pg_temp.b7_fila('pedido_combos', jsonb_build_object('sucursal_id', 1, 'precio', 500, 'cantidad_combos', 1,
         'cantidad_combos_armados', 1), v_adm);
  f := pg_temp.b7_caso(f, 'pedido_combos', v, $$precio = 'NaN'$$, 'pedido_combos_precio_check');
  f := pg_temp.b7_caso(f, 'pedido_combos', v, 'precio = 0', 'pedido_combos_precio_check');
  f := pg_temp.b7_caso(f, 'pedido_combos', v, 'precio = 750', NULL);

  v := pg_temp.b7_fila('pedido_item_sustituciones', jsonb_build_object('sucursal_id', 1, 'cantidad_original', 2,
         'cantidad_sustituta', 2, 'producto_sustituto_id', 2, 'cadena_id', gen_random_uuid()), v_adm);
  f := pg_temp.b7_caso(f, 'pedido_item_sustituciones', v, $$cantidad_original = 'NaN'$$, 'pedido_item_sustituciones_cantidad_original_check');
  f := pg_temp.b7_caso(f, 'pedido_item_sustituciones', v, $$cantidad_sustituta = 'NaN'$$, 'pedido_item_sustituciones_cantidad_sustituta_check');
  f := pg_temp.b7_caso(f, 'pedido_item_sustituciones', v, 'cantidad_sustituta = 0', 'pedido_item_sustituciones_cantidad_sustituta_check');
  f := pg_temp.b7_caso(f, 'pedido_item_sustituciones', v, 'cantidad_original = 3, cantidad_sustituta = 1.5', NULL);

  -- ── N7 · grupo_precio_escala_minimos ──────────────────────────────────────
  v := pg_temp.b7_fila('grupo_precio_escala_minimos', jsonb_build_object('sucursal_id', 1,
         'cantidad_minima_por_item', 1), v_adm);
  f := pg_temp.b7_caso(f, 'grupo_precio_escala_minimos', v, $$precio_unitario_override = 'NaN'$$, 'grupo_precio_escala_minimos_precio_unitario_override_check');
  f := pg_temp.b7_caso(f, 'grupo_precio_escala_minimos', v, 'precio_unitario_override = 0', 'grupo_precio_escala_minimos_precio_unitario_override_check');
  f := pg_temp.b7_caso(f, 'grupo_precio_escala_minimos', v, 'precio_unitario_override = 50', NULL);
  f := pg_temp.b7_caso(f, 'grupo_precio_escala_minimos', v, 'precio_unitario_override = NULL', NULL);

  -- ── N8 · H4: las fotos de pedido_items ────────────────────────────────────
  v := pg_temp.b7_fila('pedido_items', jsonb_build_object('sucursal_id', 1, 'cantidad', 2, 'precio_unitario', 100,
         'subtotal', 200, 'costo_unitario_al_crear', 60, 'precio_lista_al_crear', 100, 'descuento_pct', 0), v_adm);
  f := pg_temp.b7_caso(f, 'pedido_items', v, $$costo_unitario_al_crear = 'NaN'$$, 'pedido_items_fotos_validas');
  f := pg_temp.b7_caso(f, 'pedido_items', v, $$costo_unitario_al_crear = 'Infinity'$$, 'pedido_items_fotos_validas');
  f := pg_temp.b7_caso(f, 'pedido_items', v, $$costo_unitario_al_crear = '-Infinity'$$, 'pedido_items_fotos_validas');
  f := pg_temp.b7_caso(f, 'pedido_items', v, $$precio_lista_al_crear = 'NaN'$$, 'pedido_items_fotos_validas');
  f := pg_temp.b7_caso(f, 'pedido_items', v, $$descuento_pct = 'NaN'$$, 'pedido_items_fotos_validas');
  f := pg_temp.b7_caso(f, 'pedido_items', v, 'costo_unitario_al_crear = -2', NULL);
  f := pg_temp.b7_caso(f, 'pedido_items', v, 'costo_unitario_al_crear = NULL, precio_lista_al_crear = NULL, descuento_pct = NULL', NULL);

  -- ── N9 · productos (1596-b1) ──────────────────────────────────────────────
  v := pg_temp.b7_fila('productos', jsonb_build_object('nombre', 'B7 ensayo ' || gen_random_uuid(), 'precio', 100,
         'precio_sin_iva', 82.64, 'sucursal_id', 1, 'stock_minimo', 10), v_adm);
  f := pg_temp.b7_caso(f, 'productos', v, 'precio = -1', 'productos_precios_no_negativos');
  f := pg_temp.b7_caso(f, 'productos', v, 'precio_sin_iva = -1', 'productos_precios_no_negativos');
  f := pg_temp.b7_caso(f, 'productos', v, 'stock_minimo = -1', 'productos_stock_minimo_no_negativo');
  f := pg_temp.b7_caso(f, 'productos', v, 'cantidad_minima_venta = 0', 'productos_cantidad_minima_venta_check');
  f := pg_temp.b7_caso(f, 'productos', v, 'cantidad_minima_venta = 100001', 'productos_cantidad_minima_venta_check');
  f := pg_temp.b7_caso(f, 'productos', v, $$nombre = ''$$, 'productos_nombre_no_vacio');
  f := pg_temp.b7_caso(f, 'productos', v, $$nombre = '   '$$, 'productos_nombre_no_vacio');
  f := pg_temp.b7_caso(f, 'productos', v, 'precio = 0, precio_sin_iva = 0, stock_minimo = 0', NULL);
  f := pg_temp.b7_caso(f, 'productos', v, 'cantidad_minima_venta = 100000', NULL);
  f := pg_temp.b7_caso(f, 'productos', v, 'cantidad_minima_venta = NULL, stock_minimo = NULL, precio_sin_iva = NULL', NULL);
  -- Por REST, como el admin (un producto del ensayo de la sucursal 1).
  f := pg_temp.b7_caso(f, 'productos', v, $$nombre = ' '$$, 'productos_nombre_no_vacio', 'rest', v_adm);
  f := pg_temp.b7_caso(f, 'productos', v, 'stock_minimo = -5', 'productos_stock_minimo_no_negativo', 'rest', v_adm);
  f := pg_temp.b7_caso(f, 'productos', v, 'stock_minimo = 3', NULL, 'rest', v_adm);

  -- ── N10 · clientes (1561-b13) ─────────────────────────────────────────────
  v := pg_temp.b7_fila('clientes', jsonb_build_object('razon_social', 'B7 ensayo', 'nombre_fantasia',
         'B7 ensayo ' || gen_random_uuid(), 'direccion', 'Calle Falsa 123', 'sucursal_id', 1), v_adm);
  f := pg_temp.b7_caso(f, 'clientes', v, $$razon_social = ''$$, 'clientes_textos_no_vacios');
  f := pg_temp.b7_caso(f, 'clientes', v, $$nombre_fantasia = '  '$$, 'clientes_textos_no_vacios');
  f := pg_temp.b7_caso(f, 'clientes', v, $$direccion = ''$$, 'clientes_textos_no_vacios');
  f := pg_temp.b7_caso(f, 'clientes', v, $$direccion = 'Otra calle 456'$$, NULL);
  f := pg_temp.b7_caso(f, 'clientes', v, $$razon_social = ''$$, 'clientes_textos_no_vacios', 'rest', v_adm);
  f := pg_temp.b7_caso(f, 'clientes', v, $$direccion = '   '$$, 'clientes_textos_no_vacios', 'rest', v_adm);
  f := pg_temp.b7_caso(f, 'clientes', v, $$direccion = 'Pasaje 789'$$, NULL, 'rest', v_adm);

  -- ── N11 · El barrido ──────────────────────────────────────────────────────
  v := pg_temp.b7_fila('bot_costo_llm_mensual', jsonb_build_object('mes', '1999-01-01'::date, 'usd', 1), v_adm);
  f := pg_temp.b7_caso(f, 'bot_costo_llm_mensual', v, $$usd = 'NaN'$$, 'bot_costo_llm_mensual_usd_check');
  f := pg_temp.b7_caso(f, 'bot_costo_llm_mensual', v, 'usd = 2.5', NULL);

  v := pg_temp.b7_fila('bot_pedidos_pendientes', jsonb_build_object('sucursal_id', 1, 'total', 100, 'total_iva', 21,
         'total_neto', 79, 'cargo_mostrado', 0), v_adm);
  f := pg_temp.b7_caso(f, 'bot_pedidos_pendientes', v, $$cargo_mostrado = 'NaN'$$, 'bot_pedidos_pendientes_cargo_mostrado_no_negativo');
  FOREACH v_r IN ARRAY ARRAY['"total"', '"total_iva"', '"total_neto"']::jsonb[] LOOP
    f := pg_temp.b7_caso(f, 'bot_pedidos_pendientes', v, format($$%I = 'NaN'$$, v_r #>> '{}'), 'bot_pedidos_pendientes_totales_finitos');
    f := pg_temp.b7_caso(f, 'bot_pedidos_pendientes', v, format($$%I = 'Infinity'$$, v_r #>> '{}'), 'bot_pedidos_pendientes_totales_finitos');
    f := pg_temp.b7_caso(f, 'bot_pedidos_pendientes', v, format($$%I = '-Infinity'$$, v_r #>> '{}'), 'bot_pedidos_pendientes_totales_finitos');
  END LOOP;
  f := pg_temp.b7_caso(f, 'bot_pedidos_pendientes', v, 'total = 0, total_iva = 0, total_neto = 0, cargo_mostrado = 300', NULL);

  v := pg_temp.b7_fila('bot_presupuesto_llm', jsonb_build_object('techo_usd_mes', 10), v_adm);
  f := pg_temp.b7_caso(f, 'bot_presupuesto_llm', v, $$techo_usd_mes = 'NaN'$$, 'bot_presupuesto_llm_techo_usd_mes_check');
  f := pg_temp.b7_caso(f, 'bot_presupuesto_llm', v, 'techo_usd_mes = 25', NULL);

  v := pg_temp.b7_fila('empleado_liquidaciones', jsonb_build_object('frecuencia', 'mensual', 'pagado', 0,
         'saldo_anterior', 0, 'a_pagar', 0, 'sucursal_al_liquidar', 1), v_adm);
  f := pg_temp.b7_caso(f, 'empleado_liquidaciones', v, $$pagado = 'NaN'$$, 'empleado_liquidaciones_pagado_check');
  f := pg_temp.b7_caso(f, 'empleado_liquidaciones', v, 'pagado = 1500', NULL);

  v := pg_temp.b7_fila('rendicion_faltantes', jsonb_build_object('rendicion_sucursal_id', 1, 'monto', 100,
         'causal', 'empleado', 'empleado_id', 1, 'movimiento_id', 1), v_adm);
  f := pg_temp.b7_caso(f, 'rendicion_faltantes', v, $$monto = 'NaN'$$, 'rendicion_faltantes_monto_check');
  f := pg_temp.b7_caso(f, 'rendicion_faltantes', v, 'monto = 250', NULL);

  v := pg_temp.b7_fila('movimiento_sucursal_items', jsonb_build_object('cantidad', 1), v_adm);
  FOR rec IN SELECT unnest(ARRAY['costo_aplicado_destino', 'origen_costo_con_iva', 'origen_costo_promedio',
                                 'origen_costo_sin_iva', 'origen_impuestos_internos', 'origen_porcentaje_iva',
                                 'origen_precio', 'origen_precio_sin_iva', 'origen_unidades_por_fardo']) AS c LOOP
    f := pg_temp.b7_caso(f, 'movimiento_sucursal_items', v, format($$%I = 'NaN'$$, rec.c), 'movimiento_sucursal_items_valores_finitos');
    f := pg_temp.b7_caso(f, 'movimiento_sucursal_items', v, format($$%I = 'Infinity'$$, rec.c), 'movimiento_sucursal_items_valores_finitos');
    f := pg_temp.b7_caso(f, 'movimiento_sucursal_items', v, format('%I = 12.5', rec.c), NULL);
  END LOOP;

  v := pg_temp.b7_fila('movimientos_sucursal', jsonb_build_object('sucursal_origen_id', 1, 'sucursal_destino_id', 2), v_adm);
  f := pg_temp.b7_caso(f, 'movimientos_sucursal', v, $$total_costo = 'NaN'$$, 'movimientos_sucursal_total_costo_finito');
  f := pg_temp.b7_caso(f, 'movimientos_sucursal', v, $$total_costo = '-Infinity'$$, 'movimientos_sucursal_total_costo_finito');
  f := pg_temp.b7_caso(f, 'movimientos_sucursal', v, 'total_costo = 1234.5', NULL);

  v := pg_temp.b7_fila('rendicion_pagos_confirmados', jsonb_build_object('monto', 100, 'pedido_total', 100,
         'forma_pago', 'efectivo'), v_adm);
  f := pg_temp.b7_caso(f, 'rendicion_pagos_confirmados', v, $$monto = 'NaN'$$, 'rendicion_pagos_confirmados_montos_finitos');
  f := pg_temp.b7_caso(f, 'rendicion_pagos_confirmados', v, $$pedido_total = 'Infinity'$$, 'rendicion_pagos_confirmados_montos_finitos');
  f := pg_temp.b7_caso(f, 'rendicion_pagos_confirmados', v, 'monto = 50, pedido_total = 200', NULL);

  v := pg_temp.b7_fila('rendiciones_control', jsonb_build_object('sucursal_id', 1, 'fecha', '1999-01-01'::date,
         'transportista_id', gen_random_uuid()), v_adm);
  f := pg_temp.b7_caso(f, 'rendiciones_control', v, $$total_entregado_confirmado = 'NaN'$$, 'rendiciones_control_total_entregado_finito');
  f := pg_temp.b7_caso(f, 'rendiciones_control', v, $$total_entregado_confirmado = 'Infinity'$$, 'rendiciones_control_total_entregado_finito');
  f := pg_temp.b7_caso(f, 'rendiciones_control', v, 'total_entregado_confirmado = 9000', NULL);

  v := pg_temp.b7_fila('sucursales', jsonb_build_object('nombre', 'B7 ensayo ' || gen_random_uuid()), v_adm);
  f := pg_temp.b7_caso(f, 'sucursales', v, $$deposito_lat = 'NaN'$$, 'sucursales_coordenadas_rango');
  f := pg_temp.b7_caso(f, 'sucursales', v, $$deposito_lng = 'Infinity'$$, 'sucursales_coordenadas_rango');
  f := pg_temp.b7_caso(f, 'sucursales', v, 'destino_lat = 91', 'sucursales_coordenadas_rango');
  f := pg_temp.b7_caso(f, 'sucursales', v, 'destino_lng = -181', 'sucursales_coordenadas_rango');
  f := pg_temp.b7_caso(f, 'sucursales', v, 'deposito_lat = -26.8241, deposito_lng = -65.2226, destino_lat = -26.1, destino_lng = -64.9', NULL);
  f := pg_temp.b7_caso(f, 'sucursales', v, 'deposito_lat = NULL, destino_lng = NULL', NULL);

  -- ── A · auditoria_nan() ───────────────────────────────────────────────────
  v_r := public.auditoria_nan();
  IF jsonb_array_length(v_r->'con_nan') <> 0 THEN
    f := f || ('A1 auditoria_nan() encontró filas: ' || (v_r->'con_nan')::text);
  END IF;
  IF (v_r->>'columnas')::int <> (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                                  WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
                                    AND a.attnum > 0 AND NOT a.attisdropped AND a.atttypid = 'numeric'::regtype) THEN
    f := f || 'A1 auditoria_nan() no recorre todas las columnas numeric'::text;
  END IF;

  -- ── L · El barrido ────────────────────────────────────────────────────────
  -- L1a · Una columna numeric con un piso (`>= x` o `> x`) en algún CHECK, y sin 'NaN' ni techo (`<=`, `<`) en
  -- ninguno de los CHECK que la nombran, es un piso sin freno.
  SELECT f || COALESCE(array_agg('L1 piso sin freno de NaN: ' || x.t || '.' || x.c), '{}')
    INTO f
    FROM (
      SELECT c.relname AS t, a.attname AS c
        FROM pg_class c
        JOIN pg_attribute a ON a.attrelid = c.oid
       WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND a.attnum > 0
         AND NOT a.attisdropped AND a.atttypid = 'numeric'::regtype AND a.attgenerated = ''
         AND EXISTS (SELECT 1 FROM pg_constraint co
                      WHERE co.conrelid = c.oid AND co.contype = 'c' AND a.attnum = ANY (co.conkey)
                        AND pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M\)? >=? '))
         AND NOT EXISTS (SELECT 1 FROM pg_constraint co
                          WHERE co.conrelid = c.oid AND co.contype = 'c' AND a.attnum = ANY (co.conkey)
                            AND (pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M <> ''NaN''')
                                 OR pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M\)? <=? ')
                                 OR pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M BETWEEN')
                                 OR pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M <> ALL \(ARRAY\[''NaN''')))
    ) AS x;
  -- L1b · Una columna numeric sin precisión (no generada) sin 'Infinity' ni techo en sus CHECK.
  SELECT f || COALESCE(array_agg('L1 sin precisión y sin freno de infinito: ' || x.t || '.' || x.c), '{}')
    INTO f
    FROM (
      SELECT c.relname AS t, a.attname AS c
        FROM pg_class c
        JOIN pg_attribute a ON a.attrelid = c.oid
       WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p') AND a.attnum > 0
         AND NOT a.attisdropped AND a.atttypid = 'numeric'::regtype AND a.atttypmod = -1 AND a.attgenerated = ''
         AND NOT EXISTS (SELECT 1 FROM pg_constraint co
                          WHERE co.conrelid = c.oid AND co.contype = 'c' AND a.attnum = ANY (co.conkey)
                            AND (pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M <> ''Infinity''')
                                 OR pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M\)? <=? ')
                                 OR pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M BETWEEN')
                                 OR pg_get_constraintdef(co.oid) ~ ('\m' || a.attname || '\M <> ALL \(ARRAY\[''NaN''')))
    ) AS x;

  IF cardinality(f) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK: frenos de NaN y CHECKs que faltaban (N1-N11, A1, L1)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n  %', cardinality(f), array_to_string(f, E'\n  ');
END
$ensayo$;
