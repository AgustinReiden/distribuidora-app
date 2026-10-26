-- Ensayo de la migracion cargo_1_base (cargo de envio: estado, regla sin
-- productos, puras y desglose fiscal; lo que falta de #1220).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (un producto propio, la politica de la
-- sucursal, los pedidos) se deshace. Cada caso va ademas en su subbloque, que
-- se revierte con el SQLSTATE centinela P0099: la politica forzada de un caso
-- no la ve el siguiente.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR (no existe cargo_envio_estado, el
-- puro regalo paga envio, el neto/IVA no tiene el envio, faltan las puras);
-- despues, pasar. Ensayo en seco de la migracion:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/NNN_cargo_1_base.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Casos (politica forzada en cada uno):
--   A · escalas 5000/15000/500
--       A1 alta ZZ de 12000 -> cargo 500, 'cobrado', respuesta con total 12500,
--          neto = neto de las lineas + 500, IVA 0
--       A2 alta de 16000 -> 'gratis', cargo 0
--       A3 alta FC de 12000 -> neto + IVA = total (±0,01) y el IVA lleva 86,78;
--          salvedad parcial -> cierra; rechazo total -> total 0 y neto/IVA sin
--          el envio; anular el rechazo -> vuelven el cargo y su desglose
--       A4 ZZ -> FC -> ZZ sobre un pedido con cargo -> neto/IVA cierran en cada paso
--          (FC: neto + IVA = total y el IVA lleva 86,78; ZZ: lineas + 500 y 0)
--       A5 crear_pedido_idempotente reintentado -> devuelve total y cargo_envio
--       A6 CHECK pedidos_cargo_estado_coherente muerde: 'cobrado' con cargo 0,
--          y 'gratis' con cargo 500
--   B · bloquear (cargo 500 cargado) -> alta 'no_aplica', cargo 0
--   C · vale blanco con la politica cobrando -> 'no_aplica', cargo 0
--   D · cargo 15000/500, alta de puro regalo -> cargo 0, total 0, VENTA-A en 0
--   E · las puras dan seis casos del fixture; permisos: anon y authenticated
--       sin EXECUTE, service_role si
--   F · crear_pedido_idempotente sigue exenta en SEG-A (md5 de la lista blanca)
--
--   psql "$DATABASE_URL" -f scripts/test-cargo-1.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_admin  uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_item   bigint;
  v_salv   bigint;
  r        jsonb;
  r2       jsonb;
  p        record;
  v_iva_items numeric;
  v_neto_items numeric;
  v_n      int;
  v_clave  text;
  v_d      record;
  v_t      record;
  v_fn     text;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- --------------------------------------------------------- contexto ---
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un admin activo con una sucursal activa';
  END IF;
  -- Sin saldo a favor: un credito se imputaria a los pedidos del ensayo.
  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);

  -- Un producto propio: $1.000, IVA 21, sin internos, costo 600, sin lotes.
  INSERT INTO productos (nombre, precio, stock, costo_promedio, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo cargo 1', 1000, 1000, 600, 21, 0, v_suc)
  RETURNING id INTO v_prod;

  -- ======================================================= A · escalas ===
  -- A1 + A2 + A5 + A6
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'escalas', 5000, 15000, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;

    -- A1
    r := public.crear_pedido_completo(v_cli, 12000, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A1 alta: %', r;
    END IF;
    v_ped := (r->>'pedido_id')::bigint;
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF p.cargo_envio <> 500 OR p.cargo_envio_estado <> 'cobrado' OR p.total <> 12500 THEN
      v_fallas := v_fallas || format('A1 cargo %s, estado %s, total %s; esperado 500, cobrado, 12500',
                                     p.cargo_envio, p.cargo_envio_estado, p.total);
    END IF;
    IF (r->>'total')::numeric IS DISTINCT FROM 12500 OR (r->>'cargo_envio')::numeric IS DISTINCT FROM 500 THEN
      v_fallas := v_fallas || format('A1 respuesta total %s, cargo %s; esperado 12500 y 500', r->>'total', r->>'cargo_envio');
    END IF;
    -- En ZZ el neto de las lineas es sin IVA (calcular_desglose_venta) y el IVA
    -- es 0; el envio entra entero al neto.
    SELECT COALESCE(SUM(cantidad * neto_unitario), 0) INTO v_neto_items
      FROM pedido_items WHERE pedido_id = v_ped AND NOT COALESCE(es_bonificacion, false);
    IF p.total_neto <> round(v_neto_items, 2) + 500 OR p.total_iva <> 0 THEN
      v_fallas := v_fallas || format('A1 ZZ neto %s (lineas %s) e IVA %s; esperado lineas + 500 y 0',
                                     p.total_neto, round(v_neto_items, 2), p.total_iva);
    END IF;

    -- A4 · ZZ -> FC -> ZZ sobre A1
    r2 := public.cambiar_tipo_factura_pedido(v_ped, 'FC', v_admin);
    IF NOT COALESCE((r2->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('A4 ZZ->FC: %s', r2);
    ELSE
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      SELECT COALESCE(SUM(cantidad * iva_unitario), 0) INTO v_iva_items
        FROM pedido_items WHERE pedido_id = v_ped AND NOT COALESCE(es_bonificacion, false);
      IF abs(p.total_neto + p.total_iva - p.total) > 0.01 OR abs(p.total_iva - round(v_iva_items, 2) - 86.78) > 0.005
         OR (r2->>'total_iva')::numeric IS DISTINCT FROM p.total_iva THEN
        v_fallas := v_fallas || format('A4 en FC: neto %s + IVA %s vs total %s (IVA items %s, respuesta %s)',
                                       p.total_neto, p.total_iva, p.total, v_iva_items, r2->>'total_iva');
      END IF;
      r2 := public.cambiar_tipo_factura_pedido(v_ped, 'ZZ', v_admin);
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      SELECT COALESCE(SUM(cantidad * neto_unitario), 0) INTO v_neto_items
        FROM pedido_items WHERE pedido_id = v_ped AND NOT COALESCE(es_bonificacion, false);
      IF NOT COALESCE((r2->>'success')::boolean, false)
         OR p.total_neto <> round(v_neto_items, 2) + 500 OR p.total_iva <> 0 OR p.total <> 12500
         OR (r2->>'total_neto')::numeric IS DISTINCT FROM p.total_neto THEN
        v_fallas := v_fallas || format('A4 de vuelta en ZZ: neto %s (lineas %s), IVA %s, total %s (%s); esperado lineas + 500, 0, 12500',
                                       p.total_neto, round(v_neto_items, 2), p.total_iva, p.total, r2);
      END IF;
    END IF;

    -- A2
    r := public.crear_pedido_completo(v_cli, 16000, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 16, 'precio_unitario', 1000)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A2 alta: %', r;
    END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'pedido_id')::bigint;
    IF p.cargo_envio <> 0 OR p.cargo_envio_estado <> 'gratis' OR p.total <> 16000
       OR (r->>'total')::numeric IS DISTINCT FROM 16000 THEN
      v_fallas := v_fallas || format('A2 cargo %s, estado %s, total %s (respuesta %s); esperado 0, gratis, 16000',
                                     p.cargo_envio, p.cargo_envio_estado, p.total, r->>'total');
    END IF;

    -- A6 · el CHECK muerde en las dos direcciones
    BEGIN
      UPDATE pedidos SET cargo_envio_estado = 'cobrado' WHERE id = p.id;
      v_fallas := v_fallas || 'A6 el CHECK dejo un cobrado con cargo 0';
    EXCEPTION WHEN check_violation THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A6 cobrado/0: %s', SQLERRM);
    END;
    BEGIN
      UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado WHERE id = p.id;
      v_fallas := v_fallas || 'A6 el CHECK dejo un gratis con cargo 500';
    EXCEPTION WHEN check_violation THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A6 gratis/500: %s', SQLERRM);
    END;

    -- A5 · idempotente
    v_clave := 'ensayo-cargo-1-' || gen_random_uuid();
    r := public.crear_pedido_idempotente(v_cli, 12000, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ', NULL, 0, NULL, NULL, v_clave);
    r2 := public.crear_pedido_idempotente(v_cli, 12000, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ', NULL, 0, NULL, NULL, v_clave);
    IF NOT COALESCE((r2->>'idempotente')::boolean, false)
       OR r2->>'pedido_id' IS DISTINCT FROM r->>'pedido_id'
       OR (r2->>'total')::numeric IS DISTINCT FROM 12500
       OR (r2->>'cargo_envio')::numeric IS DISTINCT FROM 500 THEN
      v_fallas := v_fallas || format('A5 reintento %s (alta %s); esperado idempotente con total 12500 y cargo 500', r2, r);
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('A1/A2/A4/A5/A6 · error: %s', SQLERRM);
  END;

  -- A3 · FC, salvedad parcial, rechazo total y su anulacion
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'escalas', 5000, 15000, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;

    r := public.crear_pedido_completo(v_cli, 12000, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'FC');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A3 alta FC: %', r;
    END IF;
    v_ped := (r->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped;

    FOR v_n IN 1..4 LOOP
      -- 1 alta · 2 salvedad parcial (5 de 12) · 3 rechazo total (las 7) · 4 anular el rechazo
      IF v_n = 2 THEN
        r := public.registrar_salvedad(v_ped, v_item, 5, 'cliente_rechaza', 'ensayo cargo 1: parcial', NULL, true, NULL);
        IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'A3 salvedad parcial: %', r; END IF;
      ELSIF v_n = 3 THEN
        r := public.registrar_salvedad(v_ped, v_item, 7, 'cliente_rechaza', 'ensayo cargo 1: total', NULL, true, NULL);
        IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'A3 rechazo total: %', r; END IF;
        v_salv := (r->>'salvedad_id')::bigint;
      ELSIF v_n = 4 THEN
        r := public.anular_salvedad(v_salv, 'ensayo cargo 1');
        IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'A3 anular: %', r; END IF;
      END IF;
      PERFORM set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
              set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
              set_config('app.stock_pedido_item_id', '', true);

      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      SELECT COALESCE(SUM(cantidad * iva_unitario), 0) INTO v_iva_items
        FROM pedido_items WHERE pedido_id = v_ped AND NOT COALESCE(es_bonificacion, false);
      IF v_n = 3 THEN
        IF p.total <> 0 OR abs(p.total_neto) > 0.01 OR abs(p.total_iva) > 0.01 OR p.cargo_envio <> 500
           OR p.cargo_envio_estado <> 'cobrado' THEN
          v_fallas := v_fallas || format('A3 rechazo total: total %s, neto %s, IVA %s, cargo %s, estado %s; esperado 0/0/0, el cargo y su estado intactos',
                                         p.total, p.total_neto, p.total_iva, p.cargo_envio, p.cargo_envio_estado);
        END IF;
      ELSE
        IF p.total <> (CASE v_n WHEN 1 THEN 12500 ELSE 7500 END)
           OR abs(p.total_neto + p.total_iva - p.total) > 0.01
           OR abs(p.total_iva - round(v_iva_items, 2) - 86.78) > 0.005 THEN
          v_fallas := v_fallas || format('A3 paso %s: total %s, neto %s + IVA %s (IVA de items %s); esperado que cierre y lleve 86,78',
                                         v_n, p.total, p.total_neto, p.total_iva, round(v_iva_items, 2));
        END IF;
      END IF;
    END LOOP;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('A3 · error: %s', SQLERRM);
  END;

  -- ====================================================== B · bloquear ===
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'bloquear', 0, 0, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    r := public.crear_pedido_completo(v_cli, 12000, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'B alta: %', r;
    END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'pedido_id')::bigint;
    IF p.cargo_envio <> 0 OR p.cargo_envio_estado <> 'no_aplica' OR p.total <> 12000 THEN
      v_fallas := v_fallas || format('B bloquear: cargo %s, estado %s, total %s; esperado 0, no_aplica, 12000',
                                     p.cargo_envio, p.cargo_envio_estado, p.total);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B · error: %s', SQLERRM);
  END;

  -- =================================================== C · vale blanco ===
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'cargo', 15000, 0, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    UPDATE clientes SET tipo_factura_default = 'VB' WHERE id = v_cli;
    r := public.crear_pedido_completo(v_cli, 0, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2, 'precio_unitario', 0)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'VB');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'C alta VB: %', r;
    END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'pedido_id')::bigint;
    IF p.cargo_envio <> 0 OR p.cargo_envio_estado <> 'no_aplica' OR p.tipo_factura <> 'VB' THEN
      v_fallas := v_fallas || format('C VB: cargo %s, estado %s, tipo %s; esperado 0, no_aplica, VB',
                                     p.cargo_envio, p.cargo_envio_estado, p.tipo_factura);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C · error: %s', SQLERRM);
  END;

  -- ================================================== D · puro regalo ===
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'cargo', 15000, 0, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    r := public.crear_pedido_completo(v_cli, 0, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2, 'precio_unitario', 0,
                                                'es_bonificacion', true)),
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'D alta de puro regalo: %', r;
    END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'pedido_id')::bigint;
    SELECT (c->>'violaciones')::int INTO v_n
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-A';
    IF p.cargo_envio <> 0 OR p.total <> 0 OR p.cargo_envio_estado <> 'gratis' OR v_n IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('D puro regalo: cargo %s, total %s, estado %s, VENTA-A %s; esperado 0, 0, gratis, 0',
                                     p.cargo_envio, p.total, p.cargo_envio_estado, v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D · error: %s', SQLERRM);
  END;

  -- ========================================== E · puras y sus permisos ===
  BEGIN
    -- cargo_envio_pedido: "cargo: debajo del minimo paga", "escalas: el gratis exacto no paga"
    IF public.cargo_envio_pedido_puro(14999.99, 'cargo', 15000, 0, 500) IS DISTINCT FROM 500::numeric
       OR public.cargo_envio_pedido_puro(15000, 'escalas', 5000, 15000, 500) IS DISTINCT FROM 0::numeric THEN
      v_fallas := v_fallas || 'E cargo_envio_pedido_puro no da los casos del fixture';
    END IF;
    -- desglose: "FC 500", "null tratado como ZZ"
    SELECT * INTO v_d FROM public.cargo_envio_desglose(500, 'FC');
    IF v_d.neto <> 413.22 OR v_d.iva <> 86.78 THEN
      v_fallas := v_fallas || format('E desglose FC 500 = %s/%s', v_d.neto, v_d.iva);
    END IF;
    SELECT * INTO v_d FROM public.cargo_envio_desglose(500, NULL);
    IF v_d.neto <> 500 OR v_d.iva <> 0 THEN
      v_fallas := v_fallas || format('E desglose null 500 = %s/%s', v_d.neto, v_d.iva);
    END IF;
    -- tras_edicion: "admin cruza hacia arriba sin decidir: pide decision",
    -- "preventista hacia abajo: cobra aunque diga no_cobrar"
    SELECT * INTO v_t FROM public.cargo_tras_edicion('cobrado', 500, 12000, 16000, 'escalas', 5000, 15000, 500, false, NULL);
    IF v_t.cargo <> 500 OR v_t.estado <> 'cobrado' OR NOT v_t.requiere_decision THEN
      v_fallas := v_fallas || format('E tras_edicion admin sin decidir = %s/%s/%s', v_t.cargo, v_t.estado, v_t.requiere_decision);
    END IF;
    SELECT * INTO v_t FROM public.cargo_tras_edicion('gratis', 0, 16000, 12000, 'escalas', 5000, 15000, 500, true, 'no_cobrar');
    IF v_t.cargo <> 500 OR v_t.estado <> 'cobrado' OR v_t.requiere_decision THEN
      v_fallas := v_fallas || format('E tras_edicion preventista hacia abajo = %s/%s/%s', v_t.cargo, v_t.estado, v_t.requiere_decision);
    END IF;

    FOREACH v_fn IN ARRAY ARRAY[
        'public.cargo_envio_pedido_puro(numeric, text, numeric, numeric, numeric)',
        'public.cargo_envio_desglose(numeric, text)',
        'public.cargo_tras_edicion(text, numeric, numeric, numeric, text, numeric, numeric, numeric, boolean, text)'] LOOP
      IF has_function_privilege('anon', v_fn, 'EXECUTE') OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
         OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
        v_fallas := v_fallas || format('E permisos de %s', v_fn);
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('E · error: %s', SQLERRM);
  END;

  -- ========================================================= F · SEG-A ===
  BEGIN
    IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() WHERE firma LIKE 'crear_pedido_idempotente(%') THEN
      v_fallas := v_fallas || 'F crear_pedido_idempotente en rojo en SEG-A';
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('F · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · alta (cobrado/gratis/no_aplica/VB/puro regalo), desglose FC en alta, salvedades, anulacion y ZZ<->FC, idempotente, CHECK, puras y SEG-A';
END
$ensayo$;
