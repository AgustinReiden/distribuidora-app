-- Ensayo de la tarjeta B8b de la ola 2 del plan #1603: los reportes cierran entre sí.
-- Migración: NNN_reportes_que_cierran_entre_si.
--
-- Un único DO con datos propios (una sucursal nueva, sus clientes, productos, pedidos, notas y
-- compras) que termina SIEMPRE en una excepción: no deja rastro (salvo valores de secuencia).
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la migración falla en 29 casos (todos
-- los puntos); D4, F3, K3 y los cruces del mes (X), que ya cerraban, pasan en los dos.
--
-- Los datos, en la sucursal S (todo dentro de los últimos 10 días, salvo P3):
--   A: rubro «Bebidas B8b» (en el producto, «bebidas b8b»), costo 60. B: sin rubro, sin costo.
--   P1 · ZZ, C1, vendedor V: A×10 a 100 y B×5 a 50 (1.250). Cobrado 300 en efectivo.
--   P2 · FC, C2, el admin: A×2 a 121 (neto 100, IVA 21; 242).
--   P3 · ZZ, C3, el admin, hace 20 días (fuera del período): A×1 a 100.
--   Notas de venta en el período: P1 A×2 (200), P1 B×1 (50, sin costo), P2 A×1 (121, IVA 21),
--   P3 A×1 (100); y una anulada (P1 B×1) que no cuenta. El crédito de la primera se imputa a P1.
--   Compra de 5.000 con una NC de devolución de 800 y una de ajuste de 200.
--
--   D  · REP-D (#1545, D44): la venta del gerencial es neta de notas: 1.492 − 471 = 1.021, y
--        venta_bruta, notas_credito_venta, IVA débito, venta neta, FC/ZZ, vendedores, rubros y
--        top de clientes también; los pedidos no cambian. Ventas por cliente (C3 sólo con una
--        nota: −100, 0 pedidos, no se cuenta como cliente), por zona y por preventista dan lo
--        mismo; el bot de preventistas lo hereda.
--   M  · 1562-b6 (#1562, D42): lo sin costo queda fuera del margen: margen comercial 301
--        (1.021 − 200 sin costo − 720 de CMV + 200 de la NC de ajuste del proveedor; antes 972),
--        el rubro «Sin rubro» con margen 0 y su venta aparte, y la lista de la alerta «Productos
--        sin costo» suma el KPI (200, M5). Rentabilidad: B margen 0, total 480 (antes 730).
--   R  · 1562-b7 (#1562, D43): el rubro es «Bebidas B8b» y «Sin rubro» en el gerencial,
--        Rendimiento, Stock, Valuación y el tablero.
--   C  · 1557-b3 (#1557, D9): compras 4.000 con notas 1.000 aparte, en el gerencial (kpis y
--        mensual) y en el bot; obtener_resumen_compras, 4.000.
--   F  · 1562-b9: el gerencial rechaza fechas vacías o invertidas; Rentabilidad y Ventas por
--        preventista rechazan las invertidas y aceptan las vacías.
--   P  · 1597-b1: el pagado de V es 300 (el crédito de la nota no es plata).
--   K  · 1597-b2: tablero_ficha_cliente mira el rol antes que el id, y un cliente ajeno da lo
--        mismo que uno que no existe.
--   T  · 1545-b3: tablero_kpis cierra activos_30 + sin_compra_30 + nunca = cartera.
--   X  · Los cruces de check-integridad.mjs sobre S: el gerencial del mes contra Ventas por
--        cliente, por preventista, tablero_categorias, la facturación mensual y la cobertura
--        contra el top por zona (X1 y X2 ya cerraban).
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-reportes-ola2-1603.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_desde  date := public._tablero_hoy() - 10;
  v_mes    date := date_trunc('month', public._tablero_hoy())::date;
  v_finmes date := (date_trunc('month', public._tablero_hoy()) + interval '1 month - 1 day')::date;
  v_s      bigint;
  v_z      bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_c3     bigint;
  v_cat    uuid;
  v_a      bigint;
  v_b      bigint;
  v_adm    uuid := '00000000-0000-0000-0000-0000000004e7';
  v_ven    uuid;
  v_adm1   uuid;
  v_adms   uuid;
  v_p1     bigint;
  v_p2     bigint;
  v_p3     bigint;
  v_i1a    bigint;
  v_i1b    bigint;
  v_i2     bigint;
  v_i3     bigint;
  v_nc     bigint;
  v_co     bigint;
  v_g      jsonb;
  v_k      jsonb;
  v_j      jsonb;
  v_t      text;
  v_t2     text;
  v_x      numeric;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b8b-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'B8b ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  -- Corre p_sql como p_uid (authenticated, parado en p_suc) y devuelve 'PASA <valor>' o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.intenta(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text; x text;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql INTO x;
      r := 'PASA ' || COALESCE(x, '');
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.headers', '', true);
    RETURN r;
  END $f$;
  -- El error de una llamada de server, o 'PASA'.
  CREATE FUNCTION pg_temp.error_de(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE p_sql;
    RETURN 'PASA';
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  CREATE FUNCTION pg_temp.suma(p jsonb, p_campo text) RETURNS numeric LANGUAGE sql AS $f$
    SELECT COALESCE(sum((e->>p_campo)::numeric), 0) FROM jsonb_array_elements(COALESCE(p, '[]'::jsonb)) e
  $f$;
  -- El elemento de un arreglo cuyo campo p_campo vale p_valor.
  CREATE FUNCTION pg_temp.fila(p jsonb, p_campo text, p_valor text) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT e FROM jsonb_array_elements(COALESCE(p, '[]'::jsonb)) e WHERE e->>p_campo IS NOT DISTINCT FROM p_valor LIMIT 1
  $f$;
  CREATE FUNCTION pg_temp.igual(a numeric, b numeric) RETURNS boolean LANGUAGE sql AS $f$
    SELECT a IS NOT NULL AND b IS NOT NULL AND abs(a - b) < 0.005
  $f$;

  -- ------------------------------------------------------------------- datos -
  INSERT INTO sucursales (nombre) VALUES ('B8b ensayo ' || left(gen_random_uuid()::text, 8)) RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, v_s) ON CONFLICT DO NOTHING;
  v_ven  := pg_temp.u('preventista', v_s);
  v_adm1 := pg_temp.u('admin', 1);
  v_adms := pg_temp.u('admin', v_s);
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('B8b zona', v_s) RETURNING id INTO v_z;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES ('B8b uno', 'B8b uno', 'Calle 1', v_s, v_z) RETURNING id INTO v_c1;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES ('B8b dos', 'B8b dos', 'Calle 2', v_s, v_z) RETURNING id INTO v_c2;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
    VALUES ('B8b tres', 'B8b tres', 'Calle 3', v_s, v_z) RETURNING id INTO v_c3;
  INSERT INTO categorias (nombre, sucursal_id) VALUES ('Bebidas B8b', v_s) RETURNING id INTO v_cat;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
    VALUES ('B8b A', 100, 1000, 60, v_s, 'bebidas b8b') RETURNING id INTO v_a;
  INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('B8b B', 50, 1000, v_s) RETURNING id INTO v_b;
  IF (SELECT categoria_id FROM productos WHERE id = v_a) IS DISTINCT FROM v_cat THEN
    v_notas := v_notas || text 'el texto del producto no se ligó a su rubro (sync_producto_categoria_id)';
  END IF;

  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal,
                       retiro_deposito, tipo_factura)
    VALUES (v_c1, v_s, v_ven, 1250, 'entregado', v_hoy - 2, now(), 'app', true, 'ZZ') RETURNING id INTO v_p1;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES (v_p1, v_a, 10, 100, 1000, v_s) RETURNING id INTO v_i1a;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES (v_p1, v_b, 5, 50, 250, v_s) RETURNING id INTO v_i1b;

  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, total_neto, total_iva, estado, fecha,
                       fecha_entrega, canal, retiro_deposito, tipo_factura)
    VALUES (v_c2, v_s, v_adm, 242, 200, 42, 'entregado', v_hoy - 3, now(), 'app', true, 'FC') RETURNING id INTO v_p2;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, neto_unitario, iva_unitario,
                            subtotal, sucursal_id)
    VALUES (v_p2, v_a, 2, 121, 100, 21, 242, v_s) RETURNING id INTO v_i2;

  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal,
                       retiro_deposito, tipo_factura)
    VALUES (v_c3, v_s, v_adm, 100, 'entregado', v_hoy - 20, now(), 'app', true, 'ZZ') RETURNING id INTO v_p3;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES (v_p3, v_a, 1, 100, 100, v_s) RETURNING id INTO v_i3;

  -- Las notas de venta (como las deja crear_nota_credito_venta: total, neto e IVA de la foto).
  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (v_s, v_c1, v_p1, v_hoy, 'producto_vencido', 200, v_adm, 200, 0) RETURNING id INTO v_nc;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc, v_s, v_i1a, v_a, 2, 100, 200);
  -- su crédito, imputado a P1 (no es plata), y 300 en efectivo
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id, nota_credito_id)
    VALUES (v_c1, v_p1, v_s, 200, 'nota_credito', v_hoy, v_adm, v_nc);
  INSERT INTO pagos (cliente_id, pedido_id, sucursal_id, monto, forma_pago, fecha, usuario_id)
    VALUES (v_c1, v_p1, v_s, 300, 'efectivo', v_hoy, v_adm);

  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (v_s, v_c1, v_p1, v_hoy - 1, 'producto_vencido', 50, v_adm, 50, 0) RETURNING id INTO v_nc;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc, v_s, v_i1b, v_b, 1, 50, 50);

  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (v_s, v_c2, v_p2, v_hoy - 1, 'producto_vencido', 121, v_adm, 100, 21) RETURNING id INTO v_nc;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc, v_s, v_i2, v_a, 1, 121, 121);

  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
    VALUES (v_s, v_c3, v_p3, v_hoy, 'producto_vencido', 100, v_adm, 100, 0) RETURNING id INTO v_nc;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc, v_s, v_i3, v_a, 1, 100, 100);

  -- anulada: no cuenta
  INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva,
                                   anulada, anulada_at)
    VALUES (v_s, v_c1, v_p1, v_hoy, 'producto_vencido', 50, v_adm, 50, 0, true, now()) RETURNING id INTO v_nc;
  INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                        precio_unitario, subtotal)
    VALUES (v_nc, v_s, v_i1b, v_b, 1, 50, 50);

  -- La compra y sus notas
  INSERT INTO compras (sucursal_id, fecha_compra, subtotal, total, estado, tipo_factura, proveedor_nombre)
    VALUES (v_s, v_hoy - 2, 5000, 5000, 'recibida', 'ZZ', 'B8b proveedor') RETURNING id INTO v_co;
  INSERT INTO notas_credito (compra_id, sucursal_id, fecha, subtotal, total, tipo, motivo)
    VALUES (v_co, v_s, v_hoy, 800, 800, 'devolucion', 'B8b');
  INSERT INTO notas_credito (compra_id, sucursal_id, fecha, subtotal, total, tipo, motivo)
    VALUES (v_co, v_s, v_hoy - 1, 200, 200, 'ajuste', 'B8b');


  -- ================================================================== D · REP-D
  v_g := public.reporte_gerencial(v_s, v_desde, v_hoy);
  v_k := v_g->'kpis';
  IF NOT pg_temp.igual((v_k->>'venta')::numeric, 1021) THEN
    v_fallas := v_fallas || format('D1 venta del gerencial: esperaba 1021 (1492 − 471 de notas), dio %s', v_k->>'venta');
  END IF;
  IF NOT pg_temp.igual((v_k->>'venta_bruta')::numeric, 1492)
     OR NOT pg_temp.igual((v_k->>'notas_credito_venta')::numeric, 471)
     OR (v_k->>'notas_credito_venta_n')::int IS DISTINCT FROM 4 THEN
    v_fallas := v_fallas || format('D2 venta bruta 1492 y 4 notas por 471: dio %s, %s, %s',
      v_k->>'venta_bruta', v_k->>'notas_credito_venta', v_k->>'notas_credito_venta_n');
  END IF;
  IF NOT pg_temp.igual((v_k->>'iva_debito')::numeric, 21) OR NOT pg_temp.igual((v_k->>'venta_neta')::numeric, 1000)
     OR NOT pg_temp.igual((v_k->>'fc_venta')::numeric, 121) OR NOT pg_temp.igual((v_k->>'zz_venta')::numeric, 900) THEN
    v_fallas := v_fallas || format('D3 IVA 21, neta 1000, FC 121, ZZ 900: dio %s, %s, %s, %s',
      v_k->>'iva_debito', v_k->>'venta_neta', v_k->>'fc_venta', v_k->>'zz_venta');
  END IF;
  IF (v_k->>'pedidos')::int IS DISTINCT FROM 2 OR (v_k->>'clientes')::int IS DISTINCT FROM 2 THEN
    v_fallas := v_fallas || format('D4 las notas no son pedidos ni clientes: 2 y 2, dio %s y %s', v_k->>'pedidos', v_k->>'clientes');
  END IF;
  IF NOT pg_temp.igual(pg_temp.suma(v_g->'vendedores', 'venta'), 1021)
     OR NOT pg_temp.igual((pg_temp.fila(v_g->'vendedores', 'id', v_ven::text)->>'venta')::numeric, 1000)
     OR NOT pg_temp.igual((pg_temp.fila(v_g->'vendedores', 'id', v_adm::text)->>'venta')::numeric, 21)
     OR (pg_temp.fila(v_g->'vendedores', 'id', v_ven::text)->>'pedidos')::int IS DISTINCT FROM 1 THEN
    v_fallas := v_fallas || format('D5 vendedores V 1000 (1 pedido) y admin 21: %s', v_g->'vendedores');
  END IF;
  IF NOT pg_temp.igual(pg_temp.suma(v_g->'categorias', 'venta'), 1021)
     OR NOT pg_temp.igual(pg_temp.suma(v_g->'mensual', 'venta'), 1021)
     OR NOT pg_temp.igual((SELECT sum((e->>1)::numeric) FROM jsonb_array_elements(v_g->'serie_diaria') e), 1021) THEN
    v_fallas := v_fallas || format('D6 Σ rubros, Σ mensual y Σ serie = 1021: %s, %s, %s',
      pg_temp.suma(v_g->'categorias', 'venta'), pg_temp.suma(v_g->'mensual', 'venta'),
      (SELECT sum((e->>1)::numeric) FROM jsonb_array_elements(v_g->'serie_diaria') e));
  END IF;
  IF NOT pg_temp.igual((pg_temp.fila(v_g->'top_clientes', 'cliente_id', v_c1::text)->>'venta')::numeric, 1000)
     OR NOT pg_temp.igual((pg_temp.fila(v_g->'top_clientes', 'cliente_id', v_c3::text)->>'venta')::numeric, -100) THEN
    v_fallas := v_fallas || format('D7 top de clientes C1 1000 y C3 −100: %s', v_g->'top_clientes');
  END IF;

  v_j := public.reporte_ventas_por_cliente(v_desde, v_hoy, NULL, v_s);
  IF NOT pg_temp.igual((v_j->'totales'->>'total')::numeric, 1021)
     OR NOT pg_temp.igual(pg_temp.suma(v_j->'clientes', 'total'), 1021)
     OR NOT pg_temp.igual(pg_temp.suma(v_j->'zonas', 'total'), 1021)
     OR NOT pg_temp.igual(pg_temp.suma(v_j->'vendedores', 'total'), 1021) THEN
    v_fallas := v_fallas || format('D8 ventas por cliente: total, Σ clientes, Σ zonas y Σ vendedores 1021: %s, %s, %s, %s',
      v_j->'totales'->>'total', pg_temp.suma(v_j->'clientes', 'total'), pg_temp.suma(v_j->'zonas', 'total'),
      pg_temp.suma(v_j->'vendedores', 'total'));
  END IF;
  IF (v_j->'totales'->>'pedidos')::int IS DISTINCT FROM 2 OR (v_j->'totales'->>'clientes')::int IS DISTINCT FROM 2
     OR (pg_temp.fila(v_j->'zonas', 'zona_id', v_z::text)->>'clientes')::int IS DISTINCT FROM 2
     OR (pg_temp.fila(v_j->'clientes', 'cliente_id', v_c3::text)->>'pedidos')::int IS DISTINCT FROM 0
     OR NOT pg_temp.igual((pg_temp.fila(v_j->'clientes', 'cliente_id', v_c3::text)->>'total')::numeric, -100) THEN
    v_fallas := v_fallas || format('D9 2 pedidos, 2 clientes compradores, C3 −100 con 0 pedidos: %s / %s',
      v_j->'totales', pg_temp.fila(v_j->'clientes', 'cliente_id', v_c3::text));
  END IF;

  v_j := public.reporte_ventas_por_preventista(v_desde, v_hoy, v_s);
  IF NOT pg_temp.igual(pg_temp.suma(v_j, 'totalVentas'), 1021)
     OR NOT pg_temp.igual((pg_temp.fila(v_j, 'id', v_ven::text)->>'totalVentas')::numeric, 1000)
     OR NOT pg_temp.igual(pg_temp.suma(v_j, 'cantidadPedidos'), 2) THEN
    v_fallas := v_fallas || format('D10 ventas por preventista: Σ 1021, V 1000, 2 pedidos: %s', v_j);
  END IF;
  v_j := public.bot_ventas_por_preventista(v_desde, v_hoy, v_s, false)::jsonb;
  IF NOT pg_temp.igual((v_j->>'total_todos_los_roles')::numeric, 1021) THEN
    v_fallas := v_fallas || format('D11 el bot de preventistas lo hereda: 1021, dio %s', v_j->>'total_todos_los_roles');
  END IF;

  -- ================================================================== M · 1562-b6
  IF NOT pg_temp.igual((v_k->>'margen_comercial')::numeric, 301)
     OR NOT pg_temp.igual((v_k->>'margen_neto')::numeric, 301)
     OR NOT pg_temp.igual((v_k->>'ingreso_sin_costo')::numeric, 200) THEN
    v_fallas := v_fallas || format('M1 margen comercial y neto 301 (1021 − 200 sin costo − 720 de CMV + 200 de la NC de ajuste del proveedor), sin costo 200: dio %s, %s, %s, %s',
      v_k->>'margen_comercial', v_k->>'margen_neto', v_k->>'ingreso_sin_costo', v_k->>'cmv');
  END IF;
  IF NOT pg_temp.igual((pg_temp.fila(v_g->'categorias', 'categoria', 'Sin rubro')->>'margen_comercial')::numeric, 0)
     OR NOT pg_temp.igual((pg_temp.fila(v_g->'categorias', 'categoria', 'Sin rubro')->>'venta_sin_costo')::numeric, 200)
     OR NOT pg_temp.igual((pg_temp.fila(v_g->'categorias', 'categoria', 'Bebidas B8b')->>'margen_comercial')::numeric, 101)
     OR NOT pg_temp.igual((pg_temp.fila(v_g->'vendedores', 'id', v_ven::text)->>'margen_comercial')::numeric, 200)
     OR NOT pg_temp.igual((pg_temp.fila(v_g->'vendedores', 'id', v_ven::text)->>'venta_sin_costo')::numeric, 200) THEN
    v_fallas := v_fallas || format('M2 «Sin rubro» margen 0 y 200 aparte, «Bebidas B8b» 101, V margen 200 y 200 sin costo: %s / %s',
      v_g->'categorias', pg_temp.fila(v_g->'vendedores', 'id', v_ven::text));
  END IF;
  IF (v_g->'alertas')::text LIKE '%sobreestimado%' THEN
    v_fallas := v_fallas || text 'M3 la alerta de productos sin costo todavía dice «margen sobreestimado»';
  END IF;
  -- M5 · la lista de la alerta «Productos sin costo» suma el KPI (B: 250 − 50 de su nota)
  v_j := public.reporte_alerta_detalle(v_s, 'productos_sin_costo', v_desde, v_hoy);
  IF NOT pg_temp.igual(pg_temp.suma(v_j, 'valor'), (v_k->>'ingreso_sin_costo')::numeric)
     OR NOT pg_temp.igual(pg_temp.suma(v_j, 'valor'), 200) THEN
    v_fallas := v_fallas || format('M5 la lista de productos sin costo suma el KPI (200): %s / %s', v_j, v_k->>'ingreso_sin_costo');
  END IF;
  v_j := public.reporte_rentabilidad(v_desde, v_hoy, v_s, 'incluir');
  IF NOT pg_temp.igual((pg_temp.fila(v_j->'productos', 'id', v_b::text)->>'margen')::numeric, 0)
     OR NOT pg_temp.igual((v_j->'totales'->>'margenTotal')::numeric, 480)
     OR NOT pg_temp.igual((v_j->'totales'->>'ingresosSinCosto')::numeric, 250) THEN
    v_fallas := v_fallas || format('M4 rentabilidad: B margen 0, total 480 (1450 − 250 − 720), sin costo 250 aparte: %s / %s',
      pg_temp.fila(v_j->'productos', 'id', v_b::text), v_j->'totales');
  END IF;

  -- ================================================================== R · 1562-b7
  IF pg_temp.fila(v_g->'categorias', 'categoria', 'Bebidas B8b') IS NULL
     OR pg_temp.fila(v_g->'categorias', 'categoria', 'Sin rubro') IS NULL THEN
    v_fallas := v_fallas || format('R1 gerencial: los rubros «Bebidas B8b» y «Sin rubro»: %s',
      (SELECT jsonb_agg(e->'categoria') FROM jsonb_array_elements(v_g->'categorias') e));
  END IF;
  v_j := public.rendimiento_preventistas(v_s, v_hoy - 2);
  v_j := pg_temp.fila(v_j->'preventistas', 'preventista_id', v_ven::text);
  IF pg_temp.fila(v_j->'por_categoria', 'categoria', 'Bebidas B8b') IS NULL
     OR pg_temp.fila(v_j->'por_categoria', 'categoria', 'Sin rubro') IS NULL THEN
    v_fallas := v_fallas || format('R2 rendimiento: «Bebidas B8b» y «Sin rubro»: %s', v_j->'por_categoria');
  END IF;
  v_j := public.reporte_stock_red(v_s);
  v_t := (SELECT string_agg(DISTINCT e->>'categoria', ', ') FROM jsonb_array_elements(v_j->'productos') e);
  IF v_t IS DISTINCT FROM 'Bebidas B8b, Sin rubro' THEN
    v_fallas := v_fallas || format('R3 stock de la red: «Bebidas B8b, Sin rubro», dio «%s»', v_t);
  END IF;
  v_j := public.reporte_valuacion_inventario(v_s);
  v_t := (SELECT string_agg(e->>'categoria', ', ' ORDER BY e->>'categoria') FROM jsonb_array_elements(v_j->'categorias') e);
  IF v_t IS DISTINCT FROM 'Bebidas B8b, Sin rubro' THEN
    v_fallas := v_fallas || format('R4 valuación: «Bebidas B8b, Sin rubro», dio «%s»', v_t);
  END IF;
  IF to_regprocedure('public.tablero_categorias(bigint,date,date,bigint)') IS NOT NULL THEN
    v_j := public.tablero_categorias(v_s, v_desde, v_hoy);
    v_t := (SELECT string_agg(e->>'nombre', ', ' ORDER BY e->>'nombre') FROM jsonb_array_elements(v_j->'categorias') e);
    IF v_t IS DISTINCT FROM 'Bebidas B8b, Sin rubro' OR NOT pg_temp.igual((v_j->>'total')::numeric, 1021) THEN
      v_fallas := v_fallas || format('R5 tablero de rubros: «Bebidas B8b, Sin rubro» y total 1021, dio «%s» y %s', v_t, v_j->>'total');
    END IF;
  ELSE
    v_notas := v_notas || text 'R5 sin tablero_categorias (SEG-3)';
  END IF;

  -- ================================================================== C · 1557-b3
  IF NOT pg_temp.igual((v_k->>'compras')::numeric, 4000)
     OR NOT pg_temp.igual((v_k->>'compras_notas_credito')::numeric, 1000)
     OR NOT pg_temp.igual((v_k->>'compras_facturas')::numeric, 5000)
     OR NOT pg_temp.igual(pg_temp.suma(v_g->'mensual', 'compras'), 4000)
     OR NOT pg_temp.igual(pg_temp.suma(v_g->'mensual', 'compras_notas_credito'), 1000) THEN
    v_fallas := v_fallas || format('C1 gerencial: compras 4000, notas 1000, facturas 5000 (y Σ mensual): dio %s, %s, %s, %s',
      v_k->>'compras', v_k->>'compras_notas_credito', v_k->>'compras_facturas', pg_temp.suma(v_g->'mensual', 'compras'));
  END IF;
  v_j := public.bot_compras_periodo(v_desde, v_hoy, v_s)::jsonb;
  IF NOT pg_temp.igual((v_j->>'total_compras')::numeric, 4000)
     OR NOT pg_temp.igual((v_j->>'compras_notas_credito')::numeric, 1000)
     OR NOT pg_temp.igual((v_j->>'compras_facturas')::numeric, 5000) THEN
    v_fallas := v_fallas || format('C2 bot: total 4000, notas 1000, facturas 5000: dio %s, %s, %s',
      v_j->>'total_compras', v_j->>'compras_notas_credito', v_j->>'compras_facturas');
  END IF;
  IF to_regprocedure('public.obtener_resumen_compras(date,date)') IS NOT NULL THEN
    v_t := pg_temp.intenta(v_adms, v_s, format(
      'SELECT monto_total::text FROM public.obtener_resumen_compras(%L, %L)', v_desde, v_hoy));
    IF v_t IS DISTINCT FROM 'PASA 4000.00' AND v_t IS DISTINCT FROM 'PASA 4000' THEN
      v_fallas := v_fallas || format('C3 obtener_resumen_compras: 4000, dio %s', v_t);
    END IF;
  ELSE
    v_notas := v_notas || text 'C3 sin obtener_resumen_compras (SEG-3)';
  END IF;

  -- ================================================================== F · 1562-b9
  v_t := pg_temp.error_de(format('SELECT public.reporte_gerencial(%s, NULL, %L)', v_s, v_hoy));
  v_t2 := pg_temp.error_de(format('SELECT public.reporte_gerencial(%s, %L, %L)', v_s, v_hoy, v_hoy - 1));
  IF v_t NOT LIKE '22023 %fechas%' OR v_t2 NOT LIKE '22023 %posterior%' THEN
    v_fallas := v_fallas || format('F1 gerencial sin fechas / invertidas: 22023 con el motivo, dio «%s» / «%s»', v_t, v_t2);
  END IF;
  v_t := pg_temp.error_de(format('SELECT public.reporte_rentabilidad(%L, %L, %s)', v_hoy, v_hoy - 1, v_s));
  v_t2 := pg_temp.error_de(format('SELECT public.reporte_ventas_por_preventista(%L, %L, %s)', v_hoy, v_hoy - 1, v_s));
  IF v_t NOT LIKE '22023 %posterior%' OR v_t2 NOT LIKE '22023 %posterior%' THEN
    v_fallas := v_fallas || format('F2 rentabilidad / preventistas con fechas invertidas: 22023, dio «%s» / «%s»', v_t, v_t2);
  END IF;
  v_t := pg_temp.error_de(format('SELECT public.reporte_rentabilidad(NULL, NULL, %s)', v_s));
  v_t2 := pg_temp.error_de(format('SELECT public.reporte_ventas_por_preventista(NULL, NULL, %s)', v_s));
  IF v_t <> 'PASA' OR v_t2 <> 'PASA' THEN
    v_fallas := v_fallas || format('F3 sin fechas siguen siendo «todo»: dio «%s» / «%s»', v_t, v_t2);
  END IF;

  -- ================================================================== P · 1597-b1
  v_j := public.reporte_ventas_por_preventista(v_desde, v_hoy, v_s);
  IF NOT pg_temp.igual((pg_temp.fila(v_j, 'id', v_ven::text)->>'totalPagado')::numeric, 300) THEN
    v_fallas := v_fallas || format('P1 el pagado de V es plata: 300 (sin los 200 de la nota), dio %s',
      pg_temp.fila(v_j, 'id', v_ven::text)->>'totalPagado');
  END IF;

  -- ================================================================== K · 1597-b2
  IF to_regprocedure('public.tablero_ficha_cliente(bigint)') IS NOT NULL THEN
    v_t  := pg_temp.intenta(v_ven, v_s, format('SELECT public.tablero_ficha_cliente(%s)::text', v_c1));
    v_t2 := pg_temp.intenta(v_ven, v_s, 'SELECT public.tablero_ficha_cliente(-1)::text');
    IF v_t NOT LIKE '%Acceso denegado%' OR v_t2 NOT LIKE '%Acceso denegado%' THEN
      v_fallas := v_fallas || format('K1 un preventista recibe el rechazo del rol con un id que existe y con uno que no: «%s» / «%s»', v_t, v_t2);
    END IF;
    v_t  := pg_temp.intenta(v_adm1, 1, format('SELECT public.tablero_ficha_cliente(%s)::text', v_c1));
    v_t2 := pg_temp.intenta(v_adm1, 1, 'SELECT public.tablero_ficha_cliente(-1)::text');
    IF v_t <> replace(v_t2, '-1', v_c1::text) THEN
      v_fallas := v_fallas || format('K2 un admin de otra sucursal: un cliente ajeno da lo mismo que uno inexistente: «%s» / «%s»', v_t, v_t2);
    END IF;
    v_t := pg_temp.intenta(v_adms, v_s, format('SELECT (public.tablero_ficha_cliente(%s)->''resumen''->>''pedidos_hist'')', v_c1));
    IF v_t <> 'PASA 1' THEN
      v_fallas := v_fallas || format('K3 el admin de la sucursal ve la ficha: «%s»', v_t);
    END IF;
  ELSE
    v_notas := v_notas || text 'K sin tablero_ficha_cliente (SEG-3)';
  END IF;

  -- ================================================================== T · 1545-b3
  IF to_regprocedure('public.tablero_kpis(bigint,integer)') IS NOT NULL THEN
    v_j := public.tablero_kpis(v_s);
    IF (v_j->>'clientes_sin_compra_30') IS NULL
       OR (v_j->>'clientes_activos_30')::int + (v_j->>'clientes_sin_compra_30')::int + (v_j->>'clientes_nunca')::int
          IS DISTINCT FROM (v_j->>'clientes_cartera')::int THEN
      v_fallas := v_fallas || format('T1 activos_30 + sin_compra_30 + nunca = cartera: %s', v_j);
    END IF;
  ELSE
    v_notas := v_notas || text 'T sin tablero_kpis (SEG-3)';
  END IF;

  -- ================================================================== X · los cruces del mes
  v_k := public.reporte_gerencial(v_s, v_mes, v_hoy)->'kpis';
  v_j := public.reporte_ventas_por_cliente(v_mes, v_hoy, NULL, v_s);
  IF NOT pg_temp.igual((v_j->'totales'->>'total')::numeric, (v_k->>'venta')::numeric)
     OR (v_j->'totales'->>'pedidos')::int IS DISTINCT FROM (v_k->>'pedidos')::int THEN
    v_fallas := v_fallas || format('X1 gerencial del mes contra ventas por cliente: %s / %s', v_k->>'venta', v_j->'totales');
  END IF;
  v_j := public.reporte_ventas_por_preventista(v_mes, v_hoy, v_s);
  IF NOT pg_temp.igual(pg_temp.suma(v_j, 'totalVentas'), (v_k->>'venta')::numeric) THEN
    v_fallas := v_fallas || format('X2 gerencial del mes contra ventas por preventista: %s / %s', v_k->>'venta', pg_temp.suma(v_j, 'totalVentas'));
  END IF;
  IF to_regprocedure('public.tablero_facturacion_mensual(bigint,integer)') IS NOT NULL THEN
    v_j := public.tablero_facturacion_mensual(v_s, extract(year FROM v_hoy)::int);
    v_j := pg_temp.fila(v_j->'meses', 'mes', extract(month FROM v_hoy)::int::text);
    IF NOT pg_temp.igual((v_j->>'total')::numeric, (v_k->>'venta')::numeric)
       OR (v_j->>'pedidos')::int IS DISTINCT FROM (v_k->>'pedidos')::int THEN
      v_fallas := v_fallas || format('X3 facturación mensual del mes contra el gerencial: %s / %s', v_j, v_k->>'venta');
    END IF;
  END IF;
  IF to_regprocedure('public.tablero_categorias(bigint,date,date,bigint)') IS NOT NULL THEN
    v_j := public.tablero_categorias(v_s, v_mes, v_hoy);
    IF NOT pg_temp.igual((v_j->>'total')::numeric, (v_k->>'venta')::numeric)
       OR NOT pg_temp.igual(pg_temp.suma(v_j->'categorias', 'monto'), (v_k->>'venta')::numeric) THEN
      v_fallas := v_fallas || format('X4 tablero de rubros del mes contra el gerencial: %s / %s', v_j->>'total', v_k->>'venta');
    END IF;
  END IF;
  IF to_regprocedure('public.tablero_top_clientes_zona(bigint,date,date,integer,integer)') IS NOT NULL
     AND to_regprocedure('public.tablero_cobertura(bigint,date)') IS NOT NULL THEN
    v_k := public.reporte_gerencial(v_s, v_mes, v_finmes)->'kpis';
    v_j := public.tablero_top_clientes_zona(v_s, v_mes, v_finmes);
    v_x := pg_temp.suma(v_j->'zonas', 'total');
    v_j := public.tablero_cobertura(v_s, v_mes);
    IF NOT pg_temp.igual(v_x, (v_j->'totales'->>'facturacion')::numeric)
       OR NOT pg_temp.igual(v_x, (v_k->>'venta')::numeric) THEN
      v_fallas := v_fallas || format('X5 top por zona, cobertura y gerencial del mes: %s, %s, %s',
        v_x, v_j->'totales'->>'facturacion', v_k->>'venta');
    END IF;
  END IF;

  -- X6 · La venta en curso del bot es el gerencial con «Todos» menos el de entregadas, también
  -- con notas (las dos restan las mismas), y el comparativo corre.
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura)
    VALUES (v_c1, v_s, v_ven, 300, 'pendiente', v_hoy, 'app', 'ZZ');
  v_k := public.reporte_gerencial(v_s, v_desde, v_hoy)->'kpis';
  v_g := public.reporte_gerencial(v_s, v_desde, v_hoy, true, true);
  v_j := public.bot_ventas_periodo(v_desde, v_hoy, v_s)::jsonb;
  IF NOT pg_temp.igual((v_j->>'en_curso_monto')::numeric, (v_g->'kpis'->>'venta')::numeric - (v_k->>'venta')::numeric)
     OR NOT pg_temp.igual((v_j->>'en_curso_monto')::numeric, 300)
     OR v_g->'comparativo'->>'venta' IS NULL THEN
    v_fallas := v_fallas || format('X6 en curso 300 = todos − entregadas, y el comparativo: %s, %s, %s, %s',
      v_j->>'en_curso_monto', v_g->'kpis'->>'venta', v_k->>'venta', v_g->'comparativo'->>'venta');
  END IF;

  IF array_length(v_fallas, 1) IS NULL THEN
    RAISE EXCEPTION 'ENSAYO OK · 0 fallas%', CASE WHEN array_length(v_notas, 1) IS NULL THEN ''
                                                ELSE ' · notas: ' || array_to_string(v_notas, ' | ') END;
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · % · %', array_length(v_fallas, 1), array_to_string(v_fallas, ' | ');
 END;
END
$ensayo$;
