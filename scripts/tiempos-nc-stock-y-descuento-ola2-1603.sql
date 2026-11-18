-- Medición de tiempos de la tarjeta B22 (ola 2 de #1603): crear y anular una nota de crédito de venta que
-- mueve mercadería (reingreso y merma) o que es un descuento por monto, sobre una boleta de 30 renglones
-- cuyos productos tienen 20 lotes cada uno, con volumen alrededor (2.000 boletas de 3 renglones con su
-- huella y 300 notas). Antes y después de ANALYZE: lo que corre dentro de la nota no puede depender de las
-- estadísticas (a B16 un CTE en nested loop la llevó de 1 a 27 s).
--
-- No es un ensayo (no se llama test-*.sql y el CI no lo corre): mide, no afirma. Corre con psql, en una
-- transacción que termina en ROLLBACK; cada sentencia en su savepoint (ON_ERROR_ROLLBACK), así un timeout
-- no corta el resto. Las RPC corren como el admin (authenticated) con el statement_timeout de la API (8 s).
-- Sin la migración, los pasos por monto fallan (es lo esperable) y los de unidades no mueven stock.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/tiempos-nc-stock-y-descuento-ola2-1603.sql

\set ON_ERROR_ROLLBACK on
\pset footer off
BEGIN;

CREATE TEMP TABLE b22t (k text PRIMARY KEY, v text);

DO $datos$
DECLARE
  v_s    bigint;
  v_adm  uuid := '00000000-0000-0000-0000-0000000004e7';
  v_ven  uuid := gen_random_uuid();
  v_c    bigint;
  v_prod bigint[] := '{}';
  v_x    bigint;
  v_p    bigint;
  v_it   bigint;
  v_nc   bigint;
  k      int;
  j      int;
  v_bol  bigint;
  v_pc   bigint;
BEGIN
  INSERT INTO sucursales (nombre) VALUES ('B22 tiempos') RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, v_s) ON CONFLICT DO NOTHING;
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v_ven, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b22t-' || v_ven || '@ensayo.invalid',
            jsonb_build_object('rol', 'preventista', 'sucursal_id', v_s), '{"nombre":"B22t vendedor"}', now(), now());
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B22t cliente', 'B22t cliente', 'x', v_s) RETURNING id INTO v_c;
  -- 30 productos, cada uno con 20 lotes de 200 (y bolsa 0).
  FOR k IN 1..30 LOOP
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id, condicion_iva, porcentaje_iva)
      VALUES ('B22t p' || k, 100 + k, 4000, 60, v_s, 'gravado', CASE WHEN k % 3 = 0 THEN 10.5 ELSE 21 END)
      RETURNING id INTO v_x;
    v_prod := v_prod || v_x;
    FOR j IN 1..20 LOOP
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
        VALUES (v_x, v_s, public._tablero_hoy() + 10 * j, 200, 200, 'manual');
    END LOOP;
  END LOOP;
  -- 2.000 boletas de 3 renglones (de los mismos productos), vendidas como el alta: dejan huella.
  FOR k IN 1..2000 LOOP
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal, retiro_deposito, tipo_factura)
      VALUES (v_c, v_s, v_ven, 0, 'entregado', public._tablero_hoy(), now(), 'app', true, 'ZZ') RETURNING id INTO v_p;
    FOR j IN 0..2 LOOP
      INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
        VALUES (v_p, v_prod[1 + (k + j) % 30], 1, 100, 100, v_s, 60) RETURNING id INTO v_it;
      PERFORM set_config('app.stock_origen', 'pedido_creado', true);
      PERFORM set_config('app.stock_pedido_item_id', v_it::text, true);
      UPDATE productos SET stock = stock - 1 WHERE id = v_prod[1 + (k + j) % 30];
    END LOOP;
    UPDATE pedidos SET total = 300 WHERE id = v_p;
    -- 300 notas (de motivos que no mueven) sobre una de cada 7.
    IF k % 7 = 0 AND k <= 2100 THEN
      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
        VALUES (v_s, v_c, v_p, public._tablero_hoy(), 'otro', 100, v_adm, 100, 0) RETURNING id INTO v_nc;
      INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal)
        VALUES (v_nc, v_s, v_it, v_prod[1 + (k + 2) % 30], 1, 100, 100);
      INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, nota_credito_id)
        VALUES (v_c, NULL, v_s, 100, 'nota_credito', public._tablero_hoy(), v_adm, v_nc);
    END IF;
  END LOOP;
  -- La boleta medida: 30 renglones, 30 u. de cada producto; la bolsa está en 0, así que cada renglón sale
  -- de uno o dos lotes y deja su huella.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal, retiro_deposito, tipo_factura)
    VALUES (v_c, v_s, v_ven, 0, 'entregado', public._tablero_hoy(), now(), 'app', true, 'ZZ') RETURNING id INTO v_bol;
  FOR k IN 1..30 LOOP
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
      VALUES (v_bol, v_prod[k], 30, 100 + k, 30 * (100 + k), v_s, 60) RETURNING id INTO v_it;
    PERFORM set_config('app.stock_origen', 'pedido_creado', true);
    PERFORM set_config('app.stock_pedido_item_id', v_it::text, true);
    UPDATE productos SET stock = stock - 30 WHERE id = v_prod[k];
  END LOOP;
  UPDATE pedidos SET total = (SELECT sum(subtotal) FROM pedido_items WHERE pedido_id = v_bol) WHERE id = v_bol;
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);

  INSERT INTO b22t VALUES ('suc', v_s), ('cli', v_c), ('ped', v_bol),
    ('items_u', (SELECT jsonb_agg(jsonb_build_object('pedido_item_id', id, 'cantidad', 5) ORDER BY id)::text
                   FROM pedido_items WHERE pedido_id = v_bol)),
    ('items_m', '[{"monto": 1234.56}]');
END
$datos$;

SELECT max(v) FILTER (WHERE k = 'suc') AS suc, max(v) FILTER (WHERE k = 'cli') AS cli, max(v) FILTER (WHERE k = 'ped') AS ped,
       max(v) FILTER (WHERE k = 'items_u') AS items_u, max(v) FILTER (WHERE k = 'items_m') AS items_m
  FROM b22t \gset
SELECT count(*) AS lotes FROM producto_lotes WHERE sucursal_id = :suc;
SELECT count(*) AS huellas FROM pedido_item_lotes WHERE sucursal_id = :suc;

SELECT set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000004e7', 'role', 'authenticated')::text, true),
       set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000004e7', true),
       set_config('request.headers', json_build_object('x-sucursal-id', :'suc')::text, true) \gset
SET LOCAL statement_timeout = '8s';

\echo '=== SIN ANALYZE (los datos recién cargados en esta transacción)'
\timing on
SET LOCAL ROLE authenticated;
SELECT (public.crear_nota_credito_venta(:ped, :cli, :'items_u'::jsonb, 'cliente_rechaza', 'tiempos', gen_random_uuid())->>'nota_credito_id') AS nc1 \gset
SELECT public.anular_nota_credito_venta(:nc1, 'tiempos')->>'unidades_revertidas' AS anular_reingreso;
SELECT (public.crear_nota_credito_venta(:ped, :cli, :'items_u'::jsonb, 'producto_vencido', 'tiempos', gen_random_uuid())->>'nota_credito_id') AS nc2 \gset
SELECT public.anular_nota_credito_venta(:nc2, 'tiempos')->>'unidades_revertidas' AS anular_merma;
SELECT (public.crear_nota_credito_venta(:ped, :cli, :'items_m'::jsonb, 'descuento_comercial', 'tiempos', gen_random_uuid())->>'nota_credito_id') AS nc3 \gset
SELECT public.anular_nota_credito_venta(:nc3, 'tiempos')->>'unidades_revertidas' AS anular_descuento;
RESET ROLE;
\timing off

ANALYZE;
\echo '=== CON ANALYZE'
\timing on
SET LOCAL ROLE authenticated;
SELECT (public.crear_nota_credito_venta(:ped, :cli, :'items_u'::jsonb, 'cliente_rechaza', 'tiempos', gen_random_uuid())->>'nota_credito_id') AS nc4 \gset
SELECT public.anular_nota_credito_venta(:nc4, 'tiempos')->>'unidades_revertidas' AS anular_reingreso;
SELECT (public.crear_nota_credito_venta(:ped, :cli, :'items_u'::jsonb, 'producto_vencido', 'tiempos', gen_random_uuid())->>'nota_credito_id') AS nc5 \gset
SELECT public.anular_nota_credito_venta(:nc5, 'tiempos')->>'unidades_revertidas' AS anular_merma;
SELECT (public.crear_nota_credito_venta(:ped, :cli, :'items_m'::jsonb, 'descuento_comercial', 'tiempos', gen_random_uuid())->>'nota_credito_id') AS nc6 \gset
SELECT public.anular_nota_credito_venta(:nc6, 'tiempos')->>'unidades_revertidas' AS anular_descuento;
RESET ROLE;
\timing off

-- Lo que quedó: las 30 líneas con su huella entera y el stock como al principio.
SELECT count(*) AS lineas_con_huella_entera
  FROM (SELECT pi.id FROM pedido_items pi JOIN pedido_item_lotes pil ON pil.pedido_item_id = pi.id
         WHERE pi.pedido_id = :ped GROUP BY pi.id, pi.cantidad HAVING sum(pil.cantidad) = pi.cantidad) x;

ROLLBACK;
