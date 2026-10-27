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
-- despues, pasar.
--
-- Tiene DOS PARTES, separadas por la linea que EMPIEZA con la marca
-- "-- @@ MIGRACION": la parte 0 va ANTES de la migracion (arma pedidos con la
-- forma de la 389 para el backfill, caso H) y el DO del ensayo DESPUES. Ensayo
-- en seco de la migracion:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <este archivo hasta la marca>        (sed -n '1,/^-- @@ MIGRACION/p')
--   <migrations/NNN_cargo_1_base.sql>
--   <este archivo desde la marca>        (sed -n '/^-- @@ MIGRACION/,$p')
--   ROLLBACK;
--
-- Ensayo solo: el archivo entero, de corrido (el caso H falla: sin la
-- migracion nadie completa el neto/IVA).
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
--   R · reatribucion (cambiar_cliente_pedido): R1 un puro regalo con cargo 500 /
--       cobrado -> el nuevo sin cargo, total 0, gratis, VENTA-A 0; R2 no_aplica y
--       R3 bonificado conservan el estado (no renacen gratis); R4 cobrado con
--       productos conserva cargo y estado aunque la politica ya no cobre
--   G · bot: crear_pedido_completo_bot con una confirmacion pendiente -> cargo,
--       estado y neto/IVA
--   F · crear_pedido_idempotente sigue exenta en SEG-A (md5 de la lista blanca)
--   H · backfill de la 389: un FC y un ZZ entregados a los que la parte 0 les
--       cobro 500 con la forma de la 389 (total += 500, neto/IVA sin el envio)
--       -> FC neto + 413,22 e IVA + 86,78; ZZ neto + 500 e IVA igual. Un rechazo
--       total con cargo 500 (total 0, cargo efectivo 0) y un cancelado con
--       cargo no se tocan.
--
-- El estado se lee con to_jsonb(p)->>'cargo_envio_estado' y se afirma aparte:
-- antes de la migracion da NULL y cada canario falla por lo suyo (cargo, total,
-- VENTA-A), no por la columna que falta.
--
--   psql "$DATABASE_URL" -f scripts/test-cargo-1.sql

-- ============================================================ PARTE 0 =====
-- Pedidos con la forma de la 389 (se deshacen con el ROLLBACK). Corre antes
-- de la migracion: sin cargo_envio_estado, como estaba prod.
DROP TABLE IF EXISTS pg_temp._cargo1_canario;
CREATE TEMP TABLE _cargo1_canario (
  caso          text PRIMARY KEY,
  id            bigint NOT NULL,
  esperado_neto numeric,
  esperado_iva  numeric
);

DO $antes$
DECLARE
  r record;
BEGIN
  -- Un FC y un ZZ entregados con productos y sin cargo: la 389 les cobraba el
  -- envio en total y dejaba el neto/IVA como estaban.
  FOR r IN
    SELECT DISTINCT ON (p.tipo_factura) p.id, p.tipo_factura, p.total_neto, p.total_iva
      FROM pedidos p
     WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IN ('FC', 'ZZ')
       AND p.total > 0 AND p.cargo_envio = 0
       AND p.total_neto IS NOT NULL AND p.total_iva IS NOT NULL
     ORDER BY p.tipo_factura, p.id DESC
  LOOP
    UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado WHERE id = r.id;
    INSERT INTO _cargo1_canario VALUES (r.tipo_factura, r.id,
      r.total_neto + CASE WHEN r.tipo_factura = 'FC' THEN 413.22 ELSE 500 END,
      r.total_iva + CASE WHEN r.tipo_factura = 'FC' THEN 86.78 ELSE 0 END);
  END LOOP;

  -- Un rechazo total con cargo (total 0: el envio no se cobra): no se toca.
  SELECT p.id, p.total_neto, p.total_iva INTO r
    FROM pedidos p
   WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.total = 0 AND p.cargo_envio = 0 AND p.total_neto IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pedido_items i WHERE i.pedido_id = p.id)
   ORDER BY p.id DESC LIMIT 1;
  IF r.id IS NOT NULL THEN
    UPDATE pedidos SET cargo_envio = 500, total = total, monto_pagado = monto_pagado WHERE id = r.id;
    INSERT INTO _cargo1_canario VALUES ('sin_productos', r.id, r.total_neto, r.total_iva);
  END IF;

  -- Un cancelado con cargo (dato viejo): no se toca.
  SELECT p.id, p.total_neto, p.total_iva INTO r
    FROM pedidos p
   WHERE p.estado = 'cancelado' AND p.cargo_envio = 0 AND p.total_neto IS NOT NULL
   ORDER BY p.id DESC LIMIT 1;
  IF r.id IS NOT NULL THEN
    UPDATE pedidos SET cargo_envio = 500, total = total, monto_pagado = monto_pagado WHERE id = r.id;
    INSERT INTO _cargo1_canario VALUES ('cancelado', r.id, r.total_neto, r.total_iva);
  END IF;
END
$antes$;

-- @@ MIGRACION @@ ============================================ PARTE 1 =====

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_admin  uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_cli2   bigint;
  v_bot    uuid;
  v_hay_estado boolean;
  v_items12 jsonb;
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
  -- Otro, para la reatribucion (cambiar_cliente_pedido).
  SELECT c.id INTO v_cli2 FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND c.id <> v_cli
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cli2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un segundo cliente activo en la sucursal %', v_suc;
  END IF;
  -- Antes de la migracion la columna no existe: el armado de R saltea el
  -- estado y los canarios muerden por el cargo, el total y VENTA-A.
  v_hay_estado := EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = 'public' AND table_name = 'pedidos'
                             AND column_name = 'cargo_envio_estado');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);

  -- Un producto propio: $1.000, IVA 21, sin internos, costo 600, sin lotes.
  INSERT INTO productos (nombre, precio, stock, costo_promedio, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo cargo 1', 1000, 1000, 600, 21, 0, v_suc)
  RETURNING id INTO v_prod;
  v_items12 := jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000));

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
    IF p.cargo_envio <> 500 OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' OR p.total <> 12500 THEN
      v_fallas := v_fallas || format('A1 cargo %s, estado %s, total %s; esperado 500, cobrado, 12500',
                                     p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado', p.total);
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
    IF p.cargo_envio <> 0 OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'gratis' OR p.total <> 16000
       OR (r->>'total')::numeric IS DISTINCT FROM 16000 THEN
      v_fallas := v_fallas || format('A2 cargo %s, estado %s, total %s (respuesta %s); esperado 0, gratis, 16000',
                                     p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado', p.total, r->>'total');
    END IF;

    -- A6 · el CHECK muerde en las dos direcciones
    BEGIN
      UPDATE pedidos SET cargo_envio_estado = 'cobrado' WHERE id = p.id;
      v_fallas := v_fallas || 'A6 el CHECK dejo un cobrado con cargo 0'::text;
    EXCEPTION WHEN check_violation THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('A6 cobrado/0: %s', SQLERRM);
    END;
    BEGIN
      UPDATE pedidos SET cargo_envio = 500, total = total + 500, monto_pagado = monto_pagado WHERE id = p.id;
      v_fallas := v_fallas || 'A6 el CHECK dejo un gratis con cargo 500'::text;
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
           OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
          v_fallas := v_fallas || format('A3 rechazo total: total %s, neto %s, IVA %s, cargo %s, estado %s; esperado 0/0/0, el cargo y su estado intactos',
                                         p.total, p.total_neto, p.total_iva, p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado');
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
    IF p.cargo_envio <> 0 OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'no_aplica' OR p.total <> 12000 THEN
      v_fallas := v_fallas || format('B bloquear: cargo %s, estado %s, total %s; esperado 0, no_aplica, 12000',
                                     p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado', p.total);
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
    IF p.cargo_envio <> 0 OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'no_aplica' OR p.tipo_factura <> 'VB' THEN
      v_fallas := v_fallas || format('C VB: cargo %s, estado %s, tipo %s; esperado 0, no_aplica, VB',
                                     p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado', p.tipo_factura);
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
    -- Primero lo que no depende de la columna nueva: asi, antes de la
    -- migracion, el canario muestra el cargo y VENTA-A mordiendo por si solos.
    IF p.cargo_envio <> 0 OR p.total <> 0 OR v_n IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('D puro regalo: cargo %s, total %s, VENTA-A %s; esperado 0, 0, 0',
                                     p.cargo_envio, p.total, v_n);
    END IF;
    IF (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'gratis' THEN
      v_fallas := v_fallas || format('D puro regalo: estado %s; esperado gratis', to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D · error: %s', SQLERRM);
  END;

  -- ===================================== R · reatribucion de cliente ===
  -- R1 · un pedido de puro regalo con cargo 500 / cobrado (como los que dejaba
  --      la 389) se reatribuye: el nuevo no paga envio, nace gratis, VENTA-A 0.
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
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R1 alta: %', r; END IF;
    v_ped := (r->>'pedido_id')::bigint;
    IF v_hay_estado THEN
      EXECUTE 'UPDATE pedidos SET cargo_envio = 500, cargo_envio_estado = ''cobrado'', total = 500,
                      monto_pagado = monto_pagado WHERE id = $1' USING v_ped;
    ELSE
      UPDATE pedidos SET cargo_envio = 500, total = 500, monto_pagado = monto_pagado WHERE id = v_ped;
    END IF;
    r := public.cambiar_cliente_pedido(v_ped, v_cli2, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2, 'precio_unitario', 0,
                                                'es_bonificacion', true)),
           0, NULL, 0, 'ensayo cargo 1');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R1 reatribucion: %', r; END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'nuevo_pedido_id')::bigint;
    SELECT (c->>'violaciones')::int INTO v_n
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-A';
    IF p.cargo_envio <> 0 OR p.total <> 0 OR v_n IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('R1 puro regalo reatribuido: cargo %s, total %s, VENTA-A %s; esperado 0, 0, 0',
                                     p.cargo_envio, p.total, v_n);
    END IF;
    IF (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'gratis' THEN
      v_fallas := v_fallas || format('R1 puro regalo reatribuido: estado %s; esperado gratis', to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1 · error: %s', SQLERRM);
  END;

  -- R2 · no_aplica (nacio con bloquear) se reatribuye con la politica ya
  --      cobrando: sigue no_aplica, sin cargo (no lo gana por reatribuirse).
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'bloquear', 0, 0, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    r := public.crear_pedido_completo(v_cli, 12000, v_admin, v_items12,
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R2 alta: %', r; END IF;
    v_ped := (r->>'pedido_id')::bigint;
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'escalas', 5000, 15000, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    r := public.cambiar_cliente_pedido(v_ped, v_cli2, v_admin, v_items12, 12000, NULL, 0, 'ensayo cargo 1');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R2 reatribucion: %', r; END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'nuevo_pedido_id')::bigint;
    IF p.cargo_envio <> 0 OR p.total <> 12000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'no_aplica' THEN
      v_fallas := v_fallas || format('R2 no_aplica reatribuido: cargo %s, total %s, estado %s; esperado 0, 12000, no_aplica',
                                     p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R2 · error: %s', SQLERRM);
  END;

  -- R3 · bonificado (12000, el admin no lo cobro) se reatribuye: sigue
  --      bonificado, sin cargo (no renace gratis).
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'escalas', 5000, 15000, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    r := public.crear_pedido_completo(v_cli, 12000, v_admin, v_items12,
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R3 alta: %', r; END IF;
    v_ped := (r->>'pedido_id')::bigint;
    IF v_hay_estado THEN
      EXECUTE 'UPDATE pedidos SET cargo_envio = 0, cargo_envio_estado = ''bonificado'', total = 12000,
                      monto_pagado = monto_pagado WHERE id = $1' USING v_ped;
    ELSE
      UPDATE pedidos SET cargo_envio = 0, total = 12000, monto_pagado = monto_pagado WHERE id = v_ped;
    END IF;
    r := public.cambiar_cliente_pedido(v_ped, v_cli2, v_admin, v_items12, 12000, NULL, 0, 'ensayo cargo 1');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R3 reatribucion: %', r; END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'nuevo_pedido_id')::bigint;
    IF p.cargo_envio <> 0 OR p.total <> 12000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'bonificado' THEN
      v_fallas := v_fallas || format('R3 bonificado reatribuido: cargo %s, total %s, estado %s; esperado 0, 12000, bonificado',
                                     p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R3 · error: %s', SQLERRM);
  END;

  -- R4 · cobrado con productos, reatribuido con la politica ya en bloquear:
  --      conserva cargo y estado (la reatribucion no es una venta nueva).
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'escalas', 5000, 15000, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    r := public.crear_pedido_completo(v_cli, 12000, v_admin, v_items12,
           'ensayo cargo 1', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R4 alta: %', r; END IF;
    v_ped := (r->>'pedido_id')::bigint;
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'bloquear', 0, 0, 0)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    r := public.cambiar_cliente_pedido(v_ped, v_cli2, v_admin, v_items12, 12000, NULL, 0, 'ensayo cargo 1');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'R4 reatribucion: %', r; END IF;
    SELECT * INTO p FROM pedidos WHERE id = (r->>'nuevo_pedido_id')::bigint;
    IF p.cargo_envio <> 500 OR p.total <> 12500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('R4 cobrado reatribuido: cargo %s, total %s, estado %s; esperado 500, 12500, cobrado',
                                     p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R4 · error: %s', SQLERRM);
  END;

  -- ============================================================== G · bot ===
  -- La confirmacion pendiente y crear_pedido_completo_bot, como los corre el
  -- bot con service_role: 12000 en escalas -> cargo 500, cobrado, total 12500,
  -- neto = lineas + 500 (ZZ), IVA 0.
  BEGIN
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (v_suc, 'escalas', 5000, 15000, 500)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
    INSERT INTO bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total)
    VALUES (v_admin, v_suc, v_cli, v_items12, 12000)
    RETURNING id INTO v_bot;
    r := public.crear_pedido_completo_bot(v_admin, v_bot);
    IF NOT COALESCE((r->>'success')::boolean, false) THEN RAISE EXCEPTION 'G bot: %', r; END IF;
    v_ped := (r->>'pedido_id')::bigint;
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    SELECT COALESCE(SUM(cantidad * neto_unitario), 0) INTO v_neto_items
      FROM pedido_items WHERE pedido_id = v_ped AND NOT COALESCE(es_bonificacion, false);
    IF p.cargo_envio <> 500 OR p.total <> 12500 OR (r->>'total')::numeric IS DISTINCT FROM 12500
       OR p.total_neto <> round(v_neto_items, 2) + 500 OR p.total_iva <> 0 THEN
      v_fallas := v_fallas || format('G bot: cargo %s, total %s (respuesta %s), neto %s (lineas %s), IVA %s; esperado 500, 12500, lineas + 500, 0',
                                     p.cargo_envio, p.total, r->>'total', p.total_neto, round(v_neto_items, 2), p.total_iva);
    END IF;
    IF (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('G bot: estado %s; esperado cobrado', to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('G · error: %s', SQLERRM);
  END;

  -- ========================================== E · puras y sus permisos ===
  BEGIN
    -- cargo_envio_pedido: "cargo: debajo del minimo paga", "escalas: el gratis exacto no paga"
    IF public.cargo_envio_pedido_puro(14999.99, 'cargo', 15000, 0, 500) IS DISTINCT FROM 500::numeric
       OR public.cargo_envio_pedido_puro(15000, 'escalas', 5000, 15000, 500) IS DISTINCT FROM 0::numeric THEN
      v_fallas := v_fallas || 'E cargo_envio_pedido_puro no da los casos del fixture'::text;
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
      v_fallas := v_fallas || 'F crear_pedido_idempotente en rojo en SEG-A'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('F · error: %s', SQLERRM);
  END;

  -- ================================================ H · backfill de la 389 ===
  BEGIN
    IF (SELECT count(*) FROM _cargo1_canario WHERE caso IN ('FC', 'ZZ')) <> 2 THEN
      v_fallas := v_fallas || 'H sin un FC y un ZZ de la 389 (falta la parte 0 o no hay blancos)'::text;
    END IF;
    FOR p IN
      SELECT c.caso, c.id, c.esperado_neto, c.esperado_iva, pe.total_neto, pe.total_iva
        FROM _cargo1_canario c JOIN pedidos pe ON pe.id = c.id
       ORDER BY c.caso
    LOOP
      IF p.total_neto IS DISTINCT FROM p.esperado_neto OR p.total_iva IS DISTINCT FROM p.esperado_iva THEN
        v_fallas := v_fallas || format('H backfill %s (pedido %s): neto/IVA %s/%s, esperado %s/%s',
                                       p.caso, p.id, p.total_neto, p.total_iva, p.esperado_neto, p.esperado_iva);
      END IF;
    END LOOP;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('H · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · alta (cobrado/gratis/no_aplica/VB/puro regalo), desglose FC en alta, salvedades, anulacion y ZZ<->FC, idempotente, CHECK, reatribucion R1-R4, bot, puras, SEG-A y backfill de la 389';
END
$ensayo$;
