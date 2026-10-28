-- Ensayo de la migracion precio_e_iva_de_la_venta (#1257, #1258).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (dos productos propios, la politica de
-- la sucursal, los pedidos, la NC) se deshace. Cada caso va ademas en su
-- subbloque, que se revierte con el SQLSTATE centinela P0099.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR (el precio crudo arma el subtotal, el
-- exento se vende al 21, ZZ->FC toma el IVA de hoy, la NC no guarda IVA y
-- posicion_fiscal no la descuenta); despues, pasar. Ensayo en seco:
--
--   BEGIN; <migrations/NNN_precio_e_iva_de_la_venta.sql>; <este archivo>; (el DO aborta)
--
-- Politica de la sucursal en 'bloquear' sin minimo: sin cargo de envio ni
-- compra minima que muevan los totales. Corre como un admin: el piso y el techo
-- de precio no lo alcanzan.
--
-- Casos:
--   A · precio redondeado al entrar (#1258)
--       A1 alta FC de 100 x 10,005 con p_total 1.001,00 -> precio 10,01,
--          subtotal y total 1.001,00, neto + IVA = total
--       A2 la misma alta con el total crudo (1.000,50) -> se rechaza
--       A3 un precio de 2 decimales no se toca (100 x 12,10 -> 1.210,00)
--       A4 la edicion de A3 a 100 x 10,005 -> precio 10,01, subtotal y total 1.001,00
--   B · exento sin porcentaje (#1258)
--       B1 alta FC 2 x 1.000 -> foto 0, IVA 0, neto 2.000
--       B2 la edicion a 3 -> sigue IVA 0, foto 0
--       B3 bot con 2 x 500,005 (total 1.000,02) -> foto 0, neto unitario 500,01,
--          subtotal = cantidad x precio, total = suma de subtotales
--   C · cambiar_tipo_factura_pedido respeta la foto (#1258)
--       C1 alta ZZ 1 x 1.210 al 21, el producto pasa a 10,5, ZZ->FC -> foto 21,
--          IVA 210, neto 1.000
--       C2 una foto 0 de legado cae al producto (10,5) -> IVA 114,98
--   D · NC de venta y posicion_fiscal (#1257)
--       D1 FC 1 x 1.210 entregado, NC por la linea -> NC neto 1.000 e IVA 210
--       D2 posicion_fiscal del dia: iva_debito -210, fc_venta -1.210,
--          fc_neto -1.000, saldo_tecnico -210, nc_fc_iva +210
--       D3 ZZ<->FC con la NC vigente -> se rechaza
--       D4 anulada la NC, la posicion vuelve a la de antes
--   E · los helpers no los ejecuta nadie de la API
--
--   psql "$DATABASE_URL" -f scripts/test-precio-iva-venta-1257-1258.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_admin  uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_grav   bigint;
  v_exento bigint;
  v_ped    bigint;
  v_item   bigint;
  v_nc     bigint;
  v_bot    uuid;
  v_hoy    date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_pf0    jsonb;
  v_pf1    jsonb;
  v_n      jsonb;
  v_fn     text;
  r        jsonb;
  r2       jsonb;
  p        record;
  l        record;
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

  INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
  VALUES (v_suc, 'bloquear', 0, 0, 500)
  ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
    monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
    cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;

  -- Dos productos propios: gravado al 21 y exento SIN porcentaje (el CHECK lo deja).
  INSERT INTO productos (nombre, precio, stock, costo_promedio, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo 1258 gravado', 1210, 1000, 600, 21, 0, v_suc)
  RETURNING id INTO v_grav;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, condicion_iva, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo 1258 exento', 1000, 1000, 600, 'exento', NULL, 0, v_suc)
  RETURNING id INTO v_exento;

  -- ============================================ A · precio redondeado ===
  BEGIN
    -- A1
    r := public.crear_pedido_completo(v_cli, 1001.00, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 100, 'precio_unitario', 10.005)),
           'ensayo 1258', 'efectivo', 'pendiente', NULL, 'FC');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('A1 alta con p_total 1001,00 rechazada: %s', r);
    ELSE
      v_ped := (r->>'pedido_id')::bigint;
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      SELECT precio_unitario, subtotal, neto_unitario, iva_unitario INTO l FROM pedido_items WHERE pedido_id = v_ped;
      IF l.precio_unitario <> 10.01 OR l.subtotal <> 1001.00 OR p.total <> 1001.00
         OR abs(p.total_neto + p.total_iva - p.total) > 0.01
         OR l.neto_unitario + l.iva_unitario <> 10.01 THEN
        v_fallas := v_fallas || format('A1 precio %s, subtotal %s, total %s, neto %s + IVA %s, unitario %s + %s; esperado 10,01, 1001, 1001 y neto + IVA = total',
                                       l.precio_unitario, l.subtotal, p.total, p.total_neto, p.total_iva, l.neto_unitario, l.iva_unitario);
      END IF;
    END IF;

    -- A2
    r := public.crear_pedido_completo(v_cli, 1000.50, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 100, 'precio_unitario', 10.005)),
           'ensayo 1258', 'efectivo', 'pendiente', NULL, 'FC');
    IF COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('A2 el total crudo (1000,50) tendria que rechazarse: pedido %s', r->>'pedido_id');
    END IF;

    -- A3 + A4
    r := public.crear_pedido_completo(v_cli, 1210, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 100, 'precio_unitario', 12.10)),
           'ensayo 1258', 'efectivo', 'pendiente', NULL, 'FC');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('A3 alta: %s', r);
    ELSE
      v_ped := (r->>'pedido_id')::bigint;
      SELECT precio_unitario, subtotal INTO l FROM pedido_items WHERE pedido_id = v_ped;
      IF l.precio_unitario <> 12.10 OR l.subtotal <> 1210 THEN
        v_fallas := v_fallas || format('A3 precio %s, subtotal %s; esperado 12,10 y 1210', l.precio_unitario, l.subtotal);
      END IF;

      r2 := public.actualizar_pedido_items(v_ped,
              jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 100, 'precio_unitario', 10.005)),
              v_admin);
      IF NOT COALESCE((r2->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('A4 edicion: %s', r2);
      ELSE
        SELECT * INTO p FROM pedidos WHERE id = v_ped;
        SELECT precio_unitario, subtotal, neto_unitario, iva_unitario INTO l FROM pedido_items WHERE pedido_id = v_ped;
        IF l.precio_unitario <> 10.01 OR l.subtotal <> 1001.00 OR p.total <> 1001.00
           OR abs(p.total_neto + p.total_iva - p.total) > 0.01 THEN
          v_fallas := v_fallas || format('A4 precio %s, subtotal %s, total %s, neto %s + IVA %s; esperado 10,01, 1001, 1001 y neto + IVA = total',
                                         l.precio_unitario, l.subtotal, p.total, p.total_neto, p.total_iva);
        END IF;
      END IF;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('A · error: %s', SQLERRM);
  END;

  -- ================================================ B · exento sin % ===
  BEGIN
    -- B1
    r := public.crear_pedido_completo(v_cli, 2000, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_exento, 'cantidad', 2, 'precio_unitario', 1000)),
           'ensayo 1258', 'efectivo', 'pendiente', NULL, 'FC');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('B1 alta: %s', r);
    ELSE
      v_ped := (r->>'pedido_id')::bigint;
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      SELECT porcentaje_iva, iva_unitario, neto_unitario INTO l FROM pedido_items WHERE pedido_id = v_ped;
      IF l.porcentaje_iva <> 0 OR l.iva_unitario <> 0 OR l.neto_unitario <> 1000
         OR p.total_iva <> 0 OR p.total_neto <> 2000 THEN
        v_fallas := v_fallas || format('B1 foto %s, IVA unitario %s, neto unitario %s, IVA %s, neto %s; esperado 0, 0, 1000, 0, 2000',
                                       l.porcentaje_iva, l.iva_unitario, l.neto_unitario, p.total_iva, p.total_neto);
      END IF;

      -- B2
      r2 := public.actualizar_pedido_items(v_ped,
              jsonb_build_array(jsonb_build_object('producto_id', v_exento, 'cantidad', 3, 'precio_unitario', 1000)),
              v_admin);
      IF NOT COALESCE((r2->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('B2 edicion: %s', r2);
      ELSE
        SELECT * INTO p FROM pedidos WHERE id = v_ped;
        SELECT porcentaje_iva, iva_unitario INTO l FROM pedido_items WHERE pedido_id = v_ped;
        IF l.porcentaje_iva <> 0 OR l.iva_unitario <> 0 OR p.total_iva <> 0 OR p.total_neto <> 3000 OR p.total <> 3000 THEN
          v_fallas := v_fallas || format('B2 foto %s, IVA unitario %s, IVA %s, neto %s, total %s; esperado 0, 0, 0, 3000, 3000',
                                         l.porcentaje_iva, l.iva_unitario, p.total_iva, p.total_neto, p.total);
        END IF;
      END IF;
    END IF;

    -- B3 · bot
    INSERT INTO bot_pedidos_pendientes (perfil_id, sucursal_id, cliente_id, items, total)
    VALUES (v_admin, v_suc, v_cli,
            jsonb_build_array(jsonb_build_object('producto_id', v_exento, 'cantidad', 2, 'precio_unitario', 500.005)),
            1000.02)
    RETURNING id INTO v_bot;
    r := public.crear_pedido_completo_bot(v_admin, v_bot);
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('B3 bot: %s', r);
    ELSE
      v_ped := (r->>'pedido_id')::bigint;
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      SELECT porcentaje_iva, neto_unitario, precio_unitario, subtotal, cantidad INTO l FROM pedido_items WHERE pedido_id = v_ped;
      IF l.porcentaje_iva <> 0 OR l.neto_unitario <> 500.01 OR l.subtotal <> l.cantidad * l.precio_unitario
         OR p.total <> (SELECT SUM(subtotal) FROM pedido_items WHERE pedido_id = v_ped) THEN
        v_fallas := v_fallas || format('B3 bot foto %s, neto unitario %s, %s x %s = subtotal %s, total %s; esperado 0, 500,01, subtotal = cantidad x precio, total = suma',
                                       l.porcentaje_iva, l.neto_unitario, l.cantidad, l.precio_unitario, l.subtotal, p.total);
      END IF;
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B · error: %s', SQLERRM);
  END;

  -- ======================================= C · la foto en ZZ <-> FC ===
  BEGIN
    r := public.crear_pedido_completo(v_cli, 1210, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 1, 'precio_unitario', 1210)),
           'ensayo 1258', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'C alta: %', r;
    END IF;
    v_ped := (r->>'pedido_id')::bigint;
    UPDATE productos SET porcentaje_iva = 10.5 WHERE id = v_grav;

    -- C1
    r2 := public.cambiar_tipo_factura_pedido(v_ped, 'FC', v_admin);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    SELECT porcentaje_iva, iva_unitario, neto_unitario INTO l FROM pedido_items WHERE pedido_id = v_ped;
    IF NOT COALESCE((r2->>'success')::boolean, false)
       OR l.porcentaje_iva <> 21 OR l.iva_unitario <> 210 OR l.neto_unitario <> 1000 OR p.total_iva <> 210 THEN
      v_fallas := v_fallas || format('C1 ZZ->FC con el producto en 10,5: foto %s, IVA unitario %s, neto %s, IVA %s (%s); esperado 21, 210, 1000, 210',
                                     l.porcentaje_iva, l.iva_unitario, l.neto_unitario, p.total_iva, r2);
    END IF;

    -- C2 · foto 0 de legado
    r2 := public.cambiar_tipo_factura_pedido(v_ped, 'ZZ', v_admin);
    UPDATE pedido_items SET porcentaje_iva = 0 WHERE pedido_id = v_ped;
    r2 := public.cambiar_tipo_factura_pedido(v_ped, 'FC', v_admin);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    SELECT porcentaje_iva, iva_unitario INTO l FROM pedido_items WHERE pedido_id = v_ped;
    IF NOT COALESCE((r2->>'success')::boolean, false)
       OR l.porcentaje_iva <> 10.5 OR l.iva_unitario <> 114.98 OR p.total_iva <> 114.98 THEN
      v_fallas := v_fallas || format('C2 foto 0 -> foto %s, IVA unitario %s, IVA %s (%s); esperado 10,5, 114,98, 114,98',
                                     l.porcentaje_iva, l.iva_unitario, p.total_iva, r2);
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C · error: %s', SQLERRM);
  END;

  -- ================================== D · NC de venta y posicion_fiscal ===
  BEGIN
    r := public.crear_pedido_completo(v_cli, 1210, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 1, 'precio_unitario', 1210)),
           'ensayo 1257', 'efectivo', 'pendiente', NULL, 'FC');
    IF NOT COALESCE((r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'D alta: %', r;
    END IF;
    v_ped := (r->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped;
    -- Sin chofer: retiro en deposito (mig 385; lo marca un admin, y el ensayo lo es).
    UPDATE pedidos SET estado = 'entregado', fecha_entrega = now(), retiro_deposito = true, updated_at = now()
     WHERE id = v_ped;
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF p.total_iva <> 210 OR p.total_neto <> 1000 THEN
      RAISE EXCEPTION 'D el FC no nacio con neto 1000 e IVA 210: % / %', p.total_neto, p.total_iva;
    END IF;

    v_pf0 := public.posicion_fiscal(v_suc, v_hoy, v_hoy);

    -- D1
    r2 := public.crear_nota_credito_venta_impl(v_ped, v_cli,
            jsonb_build_array(jsonb_build_object('pedido_item_id', v_item, 'cantidad', 1)), 'otro', 'ensayo 1257');
    v_nc := (r2->>'nota_credito_id')::bigint;
    SELECT to_jsonb(n) INTO v_n FROM notas_credito_venta n WHERE id = v_nc;
    IF (v_n->>'neto')::numeric IS DISTINCT FROM 1000 OR (v_n->>'iva')::numeric IS DISTINCT FROM 210
       OR (v_n->>'total')::numeric IS DISTINCT FROM 1210 THEN
      v_fallas := v_fallas || format('D1 NC neto %s, IVA %s, total %s; esperado 1000, 210, 1210',
                                     v_n->>'neto', v_n->>'iva', v_n->>'total');
    END IF;

    -- D2
    v_pf1 := public.posicion_fiscal(v_suc, v_hoy, v_hoy);
    IF (v_pf0#>>'{ventas,iva_debito}')::numeric - (v_pf1#>>'{ventas,iva_debito}')::numeric <> 210
       OR (v_pf0#>>'{ventas,fc_venta}')::numeric - (v_pf1#>>'{ventas,fc_venta}')::numeric <> 1210
       OR (v_pf0#>>'{ventas,fc_neto}')::numeric - (v_pf1#>>'{ventas,fc_neto}')::numeric <> 1000
       OR (v_pf0#>>'{posicion,saldo_tecnico}')::numeric - (v_pf1#>>'{posicion,saldo_tecnico}')::numeric <> 210
       OR COALESCE((v_pf1#>>'{ventas,nc_fc_iva}')::numeric, 0) - COALESCE((v_pf0#>>'{ventas,nc_fc_iva}')::numeric, 0) <> 210 THEN
      v_fallas := v_fallas || format('D2 posicion antes %s / despues %s; esperado iva_debito -210, fc_venta -1210, fc_neto -1000, saldo -210, nc_fc_iva +210',
                                     v_pf0->'ventas', v_pf1->'ventas');
    END IF;

    -- D3
    r2 := public.cambiar_tipo_factura_pedido(v_ped, 'ZZ', v_admin);
    IF COALESCE((r2->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('D3 FC->ZZ con la NC #%s vigente tendria que rechazarse: %s', v_nc, r2);
    END IF;

    -- D4
    UPDATE notas_credito_venta SET anulada = true, anulada_at = now(), anulada_por = v_admin,
           motivo_anulacion = 'ensayo 1257' WHERE id = v_nc;
    v_pf1 := public.posicion_fiscal(v_suc, v_hoy, v_hoy);
    IF ((v_pf1->'ventas') - ARRAY['nc_fc_notas', 'nc_fc_monto', 'nc_fc_neto', 'nc_fc_iva', 'nc_zz_monto'])
       IS DISTINCT FROM ((v_pf0->'ventas') - ARRAY['nc_fc_notas', 'nc_fc_monto', 'nc_fc_neto', 'nc_fc_iva', 'nc_zz_monto']) THEN
      v_fallas := v_fallas || format('D4 anulada la NC la venta no volvio: antes %s, despues %s', v_pf0->'ventas', v_pf1->'ventas');
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D · error: %s', SQLERRM);
  END;

  -- ================================================= E · permisos ===
  FOREACH v_fn IN ARRAY ARRAY['public._alicuota_iva_venta(text,numeric)', 'public._items_precio_redondeado(jsonb)'] LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      v_fallas := v_fallas || format('E no existe %s', v_fn);
    ELSIF has_function_privilege('anon', v_fn, 'EXECUTE')
       OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc pp, aclexplode(pp.proacl) a WHERE pp.oid = to_regprocedure(v_fn) AND a.grantee = 0) THEN
      v_fallas := v_fallas || format('E %s es alcanzable desde la API', v_fn);
    END IF;
  END LOOP;

  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · precio redondeado, IVA por condicion, foto en ZZ<->FC, NC con IVA y posicion_fiscal neta';
END
$ensayo$;
