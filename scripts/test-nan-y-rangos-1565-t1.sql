-- Ensayo de la migración «NaN y rangos en las columnas» (tarjeta 1 de #1565; VTA-A de #1559, CMP-1 de #1557, CAT-4
-- de #1561 y el bajo de NaN de #1562).
--
--   V1 · VTA-A por RPC: un admin edita un pedido con precio 'NaN' (actualizar_pedido_items). Se rechaza, y el pedido y
--        el saldo del cliente quedan como estaban.
--   V2 · El camino del server (sin triggers, como un UPDATE de una función): precio_unitario y subtotal en 'NaN' o
--        negativos, pedidos.total en 'NaN' o negativo y cargo_envio en 'NaN' dan 23514 con su CHECK. Un regalo a 0 entra.
--   V3 · Por REST, como el admin: el UPDATE de pedido_items.precio_unitario y el de pedidos.total se rechazan.
--   V4 · pedido_items_combo_coherente: un precio sin combo 'NaN' da 23514, y 50 entra.
--   P1 · CAT-4 por REST, como el admin: porcentaje_iva 'NaN', −50 y 999,99; impuestos_internos 'NaN', −5 y 500;
--        costo_sin_iva 'NaN' y −10; costo_con_iva 'NaN'; costo_real y costo_promedio 'NaN'; unidades_de_venta_por_fardo
--        'NaN', 0 y −3 dan 23514 con su CHECK. Entran 21, NULL, 8,6957, un costo real −5 (sin piso: CMP-3 es de la RPC)
--        y un fardo de 2. El alta REST de un producto con IVA 'NaN' también da 23514.
--   K1 · clientes por REST: limite_credito 'NaN' y −100, dias_credito −5, 366 y 2147483647 dan 23514; 0, 30 y 365 entran.
--   C1 · CMP-1 por RPC: registrar_compra_completa con el II del renglón en 'NaN', con su IVA en 'NaN' o en 150, y con la
--        cabecera en 'NaN', no crea la compra ni mueve los costos del producto. Una compra válida entra.
--   C2 · La NC de ajuste por RPC: con los importes en 'NaN' o el II en 'Infinity' no se crea. Una válida entra.
--   C3 · El camino del server sobre compras y compra_items: la cabecera en 'NaN' o negativa da 23514, la bonificación
--        negativa entra (así se guarda) y en 'NaN' no; el IVA y el II del renglón fuera de 0 a 100, y el costo real
--        unitario en 'NaN', dan 23514, y un costo real −1 entra. Por REST, el UPDATE de compras se rechaza.
--   G1 · gastos.monto_total, empleado_movimientos.monto y empleado_arreglos.sueldo en 'NaN' dan 23514.
--   A1 · auditoria_nan() recorre todas las columnas numeric de public, entre ellas las 18 de esta migración, y no
--        encuentra filas.
--   L1 · Los 21 CHECK existen, están validados, y los seis reemplazados excluyen el NaN.
--
-- Un único DO que termina siempre en una excepción: no deja nada (salvo valores de secuencia). Cada caso corre en un
-- sub-bloque que se revierte. Sin la migración da 'ENSAYO FALLÓ' en todo menos lo que tiene que seguir entrando.
--
-- Fixtures: un admin activo de la sucursal 1. Los productos, clientes, pedidos, compras, gastos y empleados nacen en el
-- ensayo. El camino del server corre con session_replication_role = replica: apaga los triggers (y las FK), no los
-- CHECK, así que mide la columna sola.

DO $ensayo$
DECLARE
  v_adm   uuid;
  v_c     bigint;
  v_g     bigint;
  v_p     bigint;
  v_ped   bigint;
  v_it    bigint;
  v_cmp   bigint;
  v_ci    bigint;
  v_emp   bigint;
  v_r     jsonb;
  v_e     text;
  v_antes jsonb;
  v_n     bigint;
  f       text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ── Ayudas ────────────────────────────────────────────────────────────────
  CREATE FUNCTION pg_temp.t1_como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  CREATE FUNCTION pg_temp.t1_limpiar() RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.headers', '', true);
    PERFORM set_config('app.stock_origen', '', true);
    PERFORM set_config('app.stock_ref_tipo', '', true);
    PERFORM set_config('app.stock_ref_id', '', true);
    PERFORM set_config('app.stock_user_id', '', true);
    PERFORM set_config('app.stock_pedido_item_id', '', true);
  END $f$;

  -- Corre p_sql y lo revierte. p_modo: 'server' (postgres, sin triggers) o 'rest' (authenticated, como p_uid).
  -- Devuelve 'ok' o '<SQLSTATE> <constraint>'.
  CREATE FUNCTION pg_temp.t1_err(p_sql text, p_modo text, p_uid uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v_c text;
  BEGIN
    BEGIN
      IF p_modo = 'server' THEN
        SET LOCAL session_replication_role = replica;
      ELSE
        PERFORM pg_temp.t1_como(p_uid, 1);
        SET LOCAL ROLE authenticated;
      END IF;
      EXECUTE p_sql;
      RAISE EXCEPTION 'ok' USING ERRCODE = 'ZZT01';
    EXCEPTION
      WHEN SQLSTATE 'ZZT01' THEN RETURN 'ok';
      WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_c = CONSTRAINT_NAME;
        RETURN SQLSTATE || ' ' || COALESCE(NULLIF(v_c, ''), '-');
    END;
  END $f$;

  -- ¿p_sql cae en el CHECK p_check?
  CREATE FUNCTION pg_temp.t1_cae(p_sql text, p_check text, p_modo text, p_uid uuid DEFAULT NULL)
  RETURNS boolean LANGUAGE sql AS $f$
    SELECT pg_temp.t1_err(p_sql, p_modo, p_uid) = '23514 ' || p_check;
  $f$;

  CREATE FUNCTION pg_temp.t1_si(p_f text[], p_ok boolean, p_msg text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
  $f$;

  -- Una RPC que tiene que rechazar: devuelve 'rechazo' si dio success=false o una excepción, si no el JSON.
  CREATE FUNCTION pg_temp.t1_rpc(p_sql text, p_uid uuid) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v jsonb;
  BEGIN
    BEGIN
      PERFORM pg_temp.t1_como(p_uid, 1);
      EXECUTE p_sql INTO v;
      PERFORM pg_temp.t1_limpiar();
      IF COALESCE((v->>'success')::boolean, true) THEN
        RAISE EXCEPTION 'paso %', v USING ERRCODE = 'ZZT02';
      END IF;
      RETURN 'rechazo';
    EXCEPTION
      WHEN SQLSTATE 'ZZT02' THEN PERFORM pg_temp.t1_limpiar(); RETURN SQLERRM;
      WHEN OTHERS THEN PERFORM pg_temp.t1_limpiar(); RETURN 'rechazo';
    END;
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

  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('T1 ensayo', 'T1 ensayo ' || gen_random_uuid(), 'Calle 1', 1) RETURNING id INTO v_c;
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva,
                                sucursal_id, condicion_iva, porcentaje_iva, impuestos_internos)
  VALUES ('T1 ensayo ' || gen_random_uuid(), 100, 1000, 50, 50, 50, 60.5, 1, 'gravado', 21, 0)
  RETURNING id INTO v_g;

  -- ── V · La venta (VTA-A) ──────────────────────────────────────────────────
  PERFORM pg_temp.t1_como(v_adm, 1);
  v_r := public.crear_pedido_completo(v_c, 200, v_adm,
           jsonb_build_array(jsonb_build_object('producto_id', v_g, 'cantidad', 2, 'precio_unitario', 100)), 'ensayo t1');
  PERFORM pg_temp.t1_limpiar();
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO SIN FIXTURES: no se pudo crear el pedido: %', v_r;
  END IF;
  v_ped := (v_r->>'pedido_id')::bigint;
  SELECT id INTO v_it FROM public.pedido_items WHERE pedido_id = v_ped ORDER BY id LIMIT 1;
  v_antes := jsonb_build_object('total', (SELECT total FROM public.pedidos WHERE id = v_ped),
                                'saldo', (SELECT saldo_cuenta FROM public.clientes WHERE id = v_c));

  -- V1
  v_e := pg_temp.t1_rpc(format($s$SELECT public.actualizar_pedido_items(%s,
           '[{"producto_id": %s, "cantidad": 2, "precio_unitario": "NaN"}]'::jsonb, %L::uuid)$s$, v_ped, v_g, v_adm), v_adm);
  f := pg_temp.t1_si(f, v_e = 'rechazo', 'V1 la edición del admin con precio NaN pasó: ' || v_e);
  f := pg_temp.t1_si(f,
         jsonb_build_object('total', (SELECT total FROM public.pedidos WHERE id = v_ped),
                            'saldo', (SELECT saldo_cuenta FROM public.clientes WHERE id = v_c)) = v_antes,
         'V1 el pedido o el saldo cambiaron');

  -- V2
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedido_items SET precio_unitario = 'NaN' WHERE id = %s$s$, v_it),
         'pedido_items_precio_unitario_valido', 'server'), 'V2 precio_unitario NaN');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedido_items SET precio_unitario = -1 WHERE id = %s$s$, v_it),
         'pedido_items_precio_unitario_valido', 'server'), 'V2 precio_unitario -1');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedido_items SET subtotal = 'NaN' WHERE id = %s$s$, v_it),
         'pedido_items_subtotal_valido', 'server'), 'V2 subtotal NaN');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedido_items SET subtotal = -1 WHERE id = %s$s$, v_it),
         'pedido_items_subtotal_valido', 'server'), 'V2 subtotal -1');
  f := pg_temp.t1_si(f, pg_temp.t1_err(format($s$UPDATE public.pedido_items SET precio_unitario = 0, subtotal = 0 WHERE id = %s$s$, v_it),
         'server') = 'ok', 'V2 una línea a 0 no entra');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedidos SET total = 'NaN' WHERE id = %s$s$, v_ped),
         'pedidos_total_valido', 'server'), 'V2 pedidos.total NaN');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedidos SET total = -1 WHERE id = %s$s$, v_ped),
         'pedidos_total_valido', 'server'), 'V2 pedidos.total -1');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedidos SET cargo_envio = 'NaN' WHERE id = %s$s$, v_ped),
         'pedidos_cargo_envio_check', 'server'), 'V2 cargo_envio NaN');

  -- V3
  f := pg_temp.t1_si(f, pg_temp.t1_err(format($s$UPDATE public.pedido_items SET precio_unitario = 'NaN' WHERE id = %s$s$, v_it),
         'rest', v_adm) <> 'ok', 'V3 el REST de pedido_items.precio_unitario NaN pasó');
  f := pg_temp.t1_si(f, pg_temp.t1_err(format($s$UPDATE public.pedidos SET total = 'NaN' WHERE id = %s$s$, v_ped),
         'rest', v_adm) <> 'ok', 'V3 el REST de pedidos.total NaN pasó');

  -- V4
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.pedido_items SET combo_id = 999999999, origen_precio = 'combo',
           precio_sin_combo_unitario = 'NaN' WHERE id = %s$s$, v_it), 'pedido_items_combo_coherente', 'server'),
         'V4 precio sin combo NaN');
  f := pg_temp.t1_si(f, pg_temp.t1_err(format($s$UPDATE public.pedido_items SET combo_id = 999999999, origen_precio = 'combo',
           precio_sin_combo_unitario = 50 WHERE id = %s$s$, v_it), 'server') = 'ok', 'V4 un combo válido no entra');

  -- ── P · El catálogo (CAT-4), por REST ─────────────────────────────────────
  SELECT
    pg_temp.t1_si(f, bool_and(pg_temp.t1_cae(format('UPDATE public.productos SET %s WHERE id = %s', e.s, v_g), e.k, 'rest', v_adm)),
                  'P1 ' || string_agg(e.s, ', ') FILTER (WHERE NOT pg_temp.t1_cae(format('UPDATE public.productos SET %s WHERE id = %s', e.s, v_g), e.k, 'rest', v_adm)))
    INTO f
    FROM (VALUES
      ($$porcentaje_iva = 'NaN'$$, 'productos_porcentaje_iva_rango'),
      ('porcentaje_iva = -50', 'productos_porcentaje_iva_rango'),
      ('porcentaje_iva = 999.99', 'productos_porcentaje_iva_rango'),
      ($$impuestos_internos = 'NaN'$$, 'productos_impuestos_internos_rango'),
      ('impuestos_internos = -5', 'productos_impuestos_internos_rango'),
      ('impuestos_internos = 500', 'productos_impuestos_internos_rango'),
      ($$costo_sin_iva = 'NaN'$$, 'productos_costos_de_lista_validos'),
      ('costo_sin_iva = -10', 'productos_costos_de_lista_validos'),
      ($$costo_con_iva = 'NaN'$$, 'productos_costos_de_lista_validos'),
      ($$costo_real = 'NaN'$$, 'productos_costos_calculados_no_nan'),
      ($$costo_promedio = 'NaN'$$, 'productos_costos_calculados_no_nan'),
      ($$unidades_de_venta_por_fardo = 'NaN'$$, 'productos_unidades_de_venta_por_fardo_valida'),
      ('unidades_de_venta_por_fardo = 0', 'productos_unidades_de_venta_por_fardo_valida'),
      ('unidades_de_venta_por_fardo = -3', 'productos_unidades_de_venta_por_fardo_valida')
    ) AS e(s, k);
  SELECT pg_temp.t1_si(f, bool_and(pg_temp.t1_err(format('UPDATE public.productos SET %s WHERE id = %s', e.s, v_g), 'rest', v_adm) = 'ok'),
                       'P1 no entra: ' || string_agg(e.s || ' → ' || pg_temp.t1_err(format('UPDATE public.productos SET %s WHERE id = %s', e.s, v_g), 'rest', v_adm), ', '))
    INTO f
    FROM (VALUES ('porcentaje_iva = 21'), ('porcentaje_iva = NULL'), ('impuestos_internos = 8.6957'),
                 ('costo_real = -5'), ('unidades_de_venta_por_fardo = 2'), ('unidades_de_venta_por_fardo = NULL')) AS e(s);
  f := pg_temp.t1_si(f, pg_temp.t1_cae($s$INSERT INTO public.productos (nombre, precio, stock, sucursal_id, porcentaje_iva)
                                          VALUES ('T1 nan', 100, 10, 1, 'NaN')$s$,
                                       'productos_porcentaje_iva_rango', 'rest', v_adm), 'P1 alta REST con IVA NaN');

  -- ── K · Clientes, por REST ────────────────────────────────────────────────
  SELECT pg_temp.t1_si(f, bool_and(pg_temp.t1_cae(format('UPDATE public.clientes SET %s WHERE id = %s', e.s, v_c), e.k, 'rest', v_adm)),
                       'K1 ' || string_agg(e.s, ', '))
    INTO f
    FROM (VALUES ($$limite_credito = 'NaN'$$, 'clientes_limite_credito_valido'),
                 ('limite_credito = -100', 'clientes_limite_credito_valido'),
                 ('dias_credito = -5', 'clientes_dias_credito_rango'),
                 ('dias_credito = 366', 'clientes_dias_credito_rango'),
                 ('dias_credito = 2147483647', 'clientes_dias_credito_rango')) AS e(s, k);
  SELECT pg_temp.t1_si(f, bool_and(pg_temp.t1_err(format('UPDATE public.clientes SET %s WHERE id = %s', e.s, v_c), 'rest', v_adm) = 'ok'),
                       'K1 no entra alguno de: ' || string_agg(e.s, ', '))
    INTO f
    FROM (VALUES ('limite_credito = 0'), ('dias_credito = 0'), ('dias_credito = 30'), ('dias_credito = 365')) AS e(s);

  -- ── C · Compras y NC (CMP-1) ──────────────────────────────────────────────
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
  VALUES ('T1 compra ' || gen_random_uuid(), 150, 10, 100, 100, 100, 121, 1) RETURNING id INTO v_p;
  v_antes := (SELECT jsonb_build_object('cpp', costo_promedio, 'real', costo_real, 'sin', costo_sin_iva, 'con', costo_con_iva,
                                        'stock', stock) FROM public.productos WHERE id = v_p);
  v_n := (SELECT count(*) FROM public.compras);

  SELECT pg_temp.t1_si(f, bool_and(pg_temp.t1_rpc(format($s$SELECT public.registrar_compra_completa(NULL, 'T1', %L,
             public._tablero_hoy(), 1000, %s, 0, %s, 'efectivo', 't1', %L::uuid,
             jsonb_build_array(jsonb_build_object('producto_id', %s, 'cantidad', 10, 'costo_unitario', 100,
               'bonificacion', 0, 'porcentaje_iva', %s, 'impuestos_internos', %s, 'subtotal', 1000)), 'FC')$s$,
             'T1-' || e.k, e.iva_hdr, e.tot_hdr, v_adm, v_p, e.iva, e.ii), v_adm) = 'rechazo'),
                       'C1 alguna compra con NaN pasó: ' || string_agg(e.k, ', '))
    INTO f
    FROM (VALUES ('ii-nan', '210', '1210', '21', $$'NaN'$$),
                 ('iva-nan', '210', '1210', $$'NaN'$$, '0'),
                 ('iva-150', '210', '1210', '150', '0'),
                 ('cab-nan', $$'NaN'::numeric$$, $$'NaN'::numeric$$, '21', '0')) AS e(k, iva_hdr, tot_hdr, iva, ii);
  f := pg_temp.t1_si(f, (SELECT jsonb_build_object('cpp', costo_promedio, 'real', costo_real, 'sin', costo_sin_iva,
                                                   'con', costo_con_iva, 'stock', stock)
                           FROM public.productos WHERE id = v_p) = v_antes, 'C1 el producto cambió');
  f := pg_temp.t1_si(f, (SELECT count(*) FROM public.compras) = v_n, 'C1 quedó una compra');

  PERFORM pg_temp.t1_como(v_adm, 1);
  v_r := public.registrar_compra_completa(NULL, 'T1', 'T1-valida', public._tablero_hoy(), 1000, 210, 0, 1210,
           'efectivo', 't1', v_adm,
           jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100,
             'bonificacion', 0, 'porcentaje_iva', 21, 'impuestos_internos', 0, 'subtotal', 1000)), 'FC');
  PERFORM pg_temp.t1_limpiar();
  f := pg_temp.t1_si(f, COALESCE((v_r->>'success')::boolean, false), 'C1 la compra válida no entró: ' || v_r::text);
  v_cmp := (v_r->>'compra_id')::bigint;

  IF v_cmp IS NOT NULL THEN
    -- C2
    v_n := (SELECT count(*) FROM public.notas_credito WHERE compra_id = v_cmp);
    v_e := pg_temp.t1_rpc(format($s$SELECT public.registrar_nota_credito(%s, 'NC-T1a', 'ajuste t1', 'NaN', 'NaN', 'NaN',
             %L::uuid, '[]'::jsonb, 'NaN')$s$, v_cmp, v_adm), v_adm);
    f := pg_temp.t1_si(f, v_e = 'rechazo', 'C2 la NC de ajuste en NaN pasó: ' || v_e);
    v_e := pg_temp.t1_rpc(format($s$SELECT public.registrar_nota_credito(%s, 'NC-T1b', 'ajuste t1', 100, 21, 121,
             %L::uuid, '[]'::jsonb, 'Infinity')$s$, v_cmp, v_adm), v_adm);
    f := pg_temp.t1_si(f, v_e = 'rechazo', 'C2 la NC de ajuste con II infinito pasó: ' || v_e);
    f := pg_temp.t1_si(f, (SELECT count(*) FROM public.notas_credito WHERE compra_id = v_cmp) = v_n, 'C2 quedó una NC');
    v_e := pg_temp.t1_rpc(format($s$SELECT public.registrar_nota_credito(%s, 'NC-T1c', 'ajuste t1', 100, 21, 121,
             %L::uuid, '[]'::jsonb, 0)$s$, v_cmp, v_adm), v_adm);
    f := pg_temp.t1_si(f, v_e LIKE 'paso %', 'C2 la NC de ajuste válida no entró: ' || v_e);

    -- C3
    SELECT id INTO v_ci FROM public.compra_items WHERE compra_id = v_cmp ORDER BY id LIMIT 1;
    SELECT pg_temp.t1_si(f, bool_and(pg_temp.t1_cae(format('UPDATE public.compras SET %s WHERE id = %s', e.s, v_cmp),
                                                    'compras_importes_validos', 'server')),
                         'C3 la cabecera: ' || string_agg(e.s, ', '))
      INTO f
      FROM (VALUES ($$subtotal = 'NaN'$$), ($$iva = 'NaN'$$), ('iva = -1'), ($$otros_impuestos = 'NaN'$$),
                   ($$impuestos_internos = 'NaN'$$), ($$percepcion_iva = 'NaN'$$), ('percepcion_iibb = -1'),
                   ($$percepcion_iibb = 'NaN'$$), ($$no_gravado = 'NaN'$$), ($$total = 'NaN'$$), ('total = -1'),
                   ($$bonificaciones = 'NaN'$$)) AS e(s);
    f := pg_temp.t1_si(f, pg_temp.t1_err(format('UPDATE public.compras SET bonificaciones = -50 WHERE id = %s', v_cmp), 'server') = 'ok',
           'C3 la bonificación negativa no entra');
    SELECT pg_temp.t1_si(f, bool_and(pg_temp.t1_cae(format('UPDATE public.compra_items SET %s WHERE id = %s', e.s, v_ci), e.k, 'server')),
                         'C3 el renglón: ' || string_agg(e.s, ', '))
      INTO f
      FROM (VALUES ($$porcentaje_iva = 'NaN'$$, 'compra_items_porcentaje_iva_rango'),
                   ('porcentaje_iva = 101', 'compra_items_porcentaje_iva_rango'),
                   ('porcentaje_iva = -1', 'compra_items_porcentaje_iva_rango'),
                   ($$impuestos_internos = 'NaN'$$, 'compra_items_impuestos_internos_rango'),
                   ('impuestos_internos = 101', 'compra_items_impuestos_internos_rango'),
                   ($$costo_real_unitario = 'NaN'$$, 'compra_items_costo_real_no_nan')) AS e(s, k);
    f := pg_temp.t1_si(f, pg_temp.t1_err(format('UPDATE public.compra_items SET costo_real_unitario = -1 WHERE id = %s', v_ci), 'server') = 'ok',
           'C3 un costo real negativo no entra (no tiene piso)');
    f := pg_temp.t1_si(f, pg_temp.t1_err(format($s$UPDATE public.compras SET iva = 'NaN' WHERE id = %s$s$, v_cmp), 'rest', v_adm) <> 'ok',
           'C3 el REST de compras pasó');
    SELECT id INTO v_n FROM public.notas_credito WHERE compra_id = v_cmp ORDER BY id DESC LIMIT 1;
    IF v_n IS NOT NULL THEN
      SELECT pg_temp.t1_si(f, bool_and(pg_temp.t1_cae(format('UPDATE public.notas_credito SET %s WHERE id = %s', e.s, v_n), e.k, 'server')),
                           'C3 la NC: ' || string_agg(e.s, ', '))
        INTO f
        FROM (VALUES ($$subtotal = 'NaN'$$, 'notas_credito_importes_validos'), ('iva = -1', 'notas_credito_importes_validos'),
                     ($$total = 'NaN'$$, 'notas_credito_importes_validos'),
                     ($$impuestos_internos = 'NaN'$$, 'notas_credito_ii_no_negativo'),
                     ($$impuestos_internos = 'Infinity'$$, 'notas_credito_ii_no_negativo')) AS e(s, k);
    END IF;
  END IF;

  -- ── G · Gastos y personal (bajo de #1562), por el camino del server ────────
  BEGIN
    SET LOCAL session_replication_role = replica;
    INSERT INTO public.empleados (creado_por, sucursal_id, nombre, puesto)
    VALUES (v_adm, 1, 'T1 ensayo', 'otro') RETURNING id INTO v_emp;
    INSERT INTO public.empleado_movimientos (empleado_id, fecha, tipo, monto, observacion)
    VALUES (v_emp, public._tablero_hoy(), 'ajuste', 10, 't1');
    INSERT INTO public.empleado_arreglos (empleado_id, creado_por, comisiona, frecuencia, vigente_desde, sueldo)
    VALUES (v_emp, v_adm, false, 'mensual', public._tablero_hoy(), 1000);
    INSERT INTO public.gastos (creado_por, mes_imputado, comprobante, monto_total, rubro_id, fecha, sucursal_id)
    VALUES (v_adm, date_trunc('month', public._tablero_hoy())::date, 'ninguno', 100,
            COALESCE((SELECT min(id) FROM public.gasto_rubros), 1), public._tablero_hoy(), 1);
    SET LOCAL session_replication_role = origin;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'ENSAYO SIN FIXTURES: no se pudieron crear el empleado y el gasto: %', SQLERRM;
  END;
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.gastos SET monto_total = 'NaN' WHERE creado_por = %L AND rubro_id IS NOT NULL
                                                 AND id = (SELECT max(id) FROM public.gastos)$s$, v_adm),
                                       'gastos_monto_total_check', 'server'), 'G1 gastos.monto_total NaN');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.empleado_movimientos SET monto = 'NaN' WHERE empleado_id = %s$s$, v_emp),
                                       'empleado_movimientos_monto_check', 'server'), 'G1 empleado_movimientos.monto NaN');
  f := pg_temp.t1_si(f, pg_temp.t1_cae(format($s$UPDATE public.empleado_arreglos SET sueldo = 'NaN' WHERE empleado_id = %s$s$, v_emp),
                                       'empleado_arreglos_sueldo_check', 'server'), 'G1 empleado_arreglos.sueldo NaN');

  -- ── A · auditoria_nan() ───────────────────────────────────────────────────
  v_r := public.auditoria_nan();
  f := pg_temp.t1_si(f, jsonb_array_length(v_r->'con_nan') = 0, 'A1 auditoria_nan() encontró filas: ' || (v_r->'con_nan')::text);
  f := pg_temp.t1_si(f,
         (v_r->>'columnas')::int = (SELECT count(*) FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                                     WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
                                       AND a.attnum > 0 AND NOT a.attisdropped AND a.atttypid = 'numeric'::regtype),
         'A1 auditoria_nan() no recorre todas las columnas numeric');
  SELECT pg_temp.t1_si(f, bool_and(a.atttypid = 'numeric'::regtype), 'A1 auditoria_nan() no ve: ' || string_agg(e.t || '.' || e.c, ', '))
    INTO f
    FROM (VALUES ('pedido_items', 'precio_unitario'), ('pedido_items', 'subtotal'), ('pedidos', 'total'),
                 ('productos', 'porcentaje_iva'), ('productos', 'costo_sin_iva'), ('productos', 'costo_con_iva'),
                 ('productos', 'costo_real'), ('productos', 'costo_promedio'),
                 ('productos', 'unidades_de_venta_por_fardo'), ('clientes', 'limite_credito'),
                 ('compras', 'total'), ('compra_items', 'porcentaje_iva'), ('compra_items', 'impuestos_internos'),
                 ('notas_credito', 'total'), ('notas_credito', 'impuestos_internos'), ('gastos', 'monto_total'),
                 ('empleado_movimientos', 'monto'), ('empleado_arreglos', 'sueldo')) AS e(t, c)
    JOIN pg_attribute a ON a.attrelid = ('public.' || e.t)::regclass AND a.attname = e.c;

  -- ── L · Los CHECK ─────────────────────────────────────────────────────────
  SELECT pg_temp.t1_si(f, count(*) = 0, 'L1 faltan o no están validados: ' || string_agg(e.n, ', '))
    INTO f
    FROM unnest(ARRAY['pedido_items_precio_unitario_valido', 'pedido_items_subtotal_valido',
                      'pedido_items_combo_coherente', 'pedidos_total_valido', 'pedidos_cargo_envio_check',
                      'productos_porcentaje_iva_rango', 'productos_impuestos_internos_rango',
                      'productos_costos_de_lista_validos', 'productos_costos_calculados_no_nan',
                      'productos_unidades_de_venta_por_fardo_valida', 'clientes_limite_credito_valido',
                      'clientes_dias_credito_rango', 'compras_importes_validos', 'compra_items_porcentaje_iva_rango',
                      'compra_items_impuestos_internos_rango', 'compra_items_costo_real_no_nan',
                      'notas_credito_importes_validos', 'notas_credito_ii_no_negativo', 'gastos_monto_total_check',
                      'empleado_movimientos_monto_check', 'empleado_arreglos_sueldo_check']) AS e(n)
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                      WHERE c.conname = e.n AND c.connamespace = 'public'::regnamespace
                        AND c.contype = 'c' AND c.convalidated);
  SELECT pg_temp.t1_si(f, count(*) = 0, 'L1 no excluyen el NaN: ' || string_agg(conname, ', '))
    INTO f
    FROM pg_constraint
   WHERE connamespace = 'public'::regnamespace
     AND conname IN ('pedido_items_combo_coherente', 'pedidos_cargo_envio_check', 'notas_credito_ii_no_negativo',
                     'gastos_monto_total_check', 'empleado_movimientos_monto_check', 'empleado_arreglos_sueldo_check')
     AND position('''NaN''::numeric' in pg_get_constraintdef(oid)) = 0;

  IF cardinality(f) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK: NaN y rangos en las columnas (V1-V4, P1, K1, C1-C3, G1, A1, L1)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n  %', cardinality(f), array_to_string(f, E'\n  ');
END
$ensayo$;
