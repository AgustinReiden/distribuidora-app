-- Ensayo de la migración 414 precio_redondeo_por_valor (#1299).
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escribe (un producto propio, la política de la
-- sucursal, los pedidos) se deshace. Los casos de alta van además en su
-- subbloque, que se revierte con el SQLSTATE centinela P0099.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en A, B y C (un precio de 3 decimales
-- mandado como texto en otro formato se salteaba el redondeo); después, pasar.
-- Ensayo en seco:
--
--   BEGIN; <migrations/414_precio_redondeo_por_valor.sql>; <este archivo>; (el DO aborta)
--
-- Molde: scripts/test-precio-iva-venta-1257-1258.sql (A1 y A2), con el precio
-- como texto. Corre como un admin: el piso y el techo de precio no lo alcanzan.
-- Política de la sucursal en 'bloquear' sin mínimo y con envío gratis desde 0.
--
-- Casos:
--   A · el escenario de #1299: alta FC de 100 x "1.0005e1" y de 100 x "+10.005"
--       con p_total 1.001,00 -> precio 10,01, subtotal y total 1.001,00, neto +
--       IVA = total
--   B · la misma alta con el total crudo (1.000,50) -> se rechaza (antes pasaba
--       y guardaba 10,01 x 100 con subtotal 1.000,50)
--   C · el helper solo: los formatos que la regex no veía se redondean
--   D · el helper solo: lo que no tiene que tocar (2 decimales o menos en
--       cualquier formato, lo que no es numeric, NaN, otros tipos)
--   E · el helper no lo ejecuta nadie de la API
--
--   psql "$DATABASE_URL" -f scripts/test-precio-redondeo-1299.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_admin  uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_grav   bigint;
  v_ped    bigint;
  v_txt    text;
  r        jsonb;
  p        record;
  l        record;
  c        record;
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
  -- Sin saldo a favor: un crédito se imputaría a los pedidos del ensayo.
  SELECT cl.id INTO v_cli FROM clientes cl
   WHERE cl.sucursal_id = v_suc AND cl.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = cl.id AND pg.pedido_id IS NULL)
   ORDER BY cl.id LIMIT 1;
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

  INSERT INTO productos (nombre, precio, stock, costo_promedio, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo 1299 gravado', 1210, 1000, 600, 21, 0, v_suc)
  RETURNING id INTO v_grav;

  -- ========================================== A y B · el alta de #1299 ===
  FOREACH v_txt IN ARRAY ARRAY['1.0005e1', '+10.005'] LOOP
    BEGIN
      -- A
      r := public.crear_pedido_completo(v_cli, 1001.00, v_admin,
             jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 100, 'precio_unitario', v_txt)),
             'ensayo 1299', 'efectivo', 'pendiente', NULL, 'FC');
      IF NOT COALESCE((r->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('A "%s" alta con p_total 1001,00 rechazada: %s', v_txt, r);
      ELSE
        v_ped := (r->>'pedido_id')::bigint;
        SELECT * INTO p FROM pedidos WHERE id = v_ped;
        SELECT precio_unitario, subtotal, neto_unitario, iva_unitario INTO l FROM pedido_items WHERE pedido_id = v_ped;
        IF l.precio_unitario <> 10.01 OR l.subtotal <> 1001.00 OR p.total <> 1001.00
           OR abs(p.total_neto + p.total_iva - p.total) > 0.01 THEN
          v_fallas := v_fallas || format('A "%s" precio %s, subtotal %s, total %s, neto %s + IVA %s; esperado 10,01, 1001, 1001 y neto + IVA = total',
                                         v_txt, l.precio_unitario, l.subtotal, p.total, p.total_neto, p.total_iva);
        END IF;
      END IF;

      -- B
      r := public.crear_pedido_completo(v_cli, 1000.50, v_admin,
             jsonb_build_array(jsonb_build_object('producto_id', v_grav, 'cantidad', 100, 'precio_unitario', v_txt)),
             'ensayo 1299', 'efectivo', 'pendiente', NULL, 'FC');
      IF COALESCE((r->>'success')::boolean, false) THEN
        v_ped := (r->>'pedido_id')::bigint;
        SELECT * INTO p FROM pedidos WHERE id = v_ped;
        SELECT precio_unitario, subtotal INTO l FROM pedido_items WHERE pedido_id = v_ped;
        v_fallas := v_fallas || format('B "%s" el total crudo (1000,50) tendría que rechazarse: guardó precio %s, subtotal %s, total %s, neto + IVA %s',
                                       v_txt, l.precio_unitario, l.subtotal, p.total, p.total_neto + p.total_iva);
      END IF;

      RAISE EXCEPTION USING ERRCODE = 'P0099';
    EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    END;
  END LOOP;

  -- ===================================================== C · redondea ===
  FOR c IN SELECT * FROM (VALUES
      ('"1.0005e1"', '10.01'), ('"+10.005"', '10.01'), ('" 10.005 "', '10.01'),
      ('"1e-3"', '0.00'), ('"10.004"', '10.00'), ('10.005', '10.01'), ('"10.000"', '10.00')) AS v(entrada, sale)
  LOOP
    v_txt := public._items_precio_redondeado(('[{"precio_unitario": ' || c.entrada || '}]')::jsonb)->0->>'precio_unitario';
    IF v_txt IS DISTINCT FROM c.sale THEN
      v_fallas := v_fallas || format('C %s salió %s; esperado %s', c.entrada, v_txt, c.sale);
    END IF;
  END LOOP;

  -- =============================================== D · no toca de más ===
  FOR c IN SELECT * FROM (VALUES
      ('[{"precio_unitario": "1.5e1"}]'), ('[{"precio_unitario": "+10.5"}]'), ('[{"precio_unitario": 10}]'),
      ('[{"precio_unitario": 7.5}]'), ('[{"precio_unitario": "abc"}]'), ('[{"precio_unitario": "NaN"}]'),
      ('[{"precio_unitario": null}]'), ('[{"precio_unitario": true}]'), ('[{"cantidad": 3}, 7]'), ('{}')) AS v(entrada)
  LOOP
    IF public._items_precio_redondeado(c.entrada::jsonb) IS DISTINCT FROM c.entrada::jsonb THEN
      v_fallas := v_fallas || format('D %s salió %s; no tenía que tocarlo',
                                     c.entrada, public._items_precio_redondeado(c.entrada::jsonb));
    END IF;
  END LOOP;
  IF public._items_precio_redondeado(NULL) IS NOT NULL THEN
    v_fallas := v_fallas || 'D NULL no sale NULL'::text;
  END IF;

  -- ================================================== E · sin la API ===
  IF has_function_privilege('anon', 'public._items_precio_redondeado(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._items_precio_redondeado(jsonb)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'E _items_precio_redondeado es ejecutable desde la API'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · el precio se redondea por su valor, en cualquier formato de texto';
END
$ensayo$;
