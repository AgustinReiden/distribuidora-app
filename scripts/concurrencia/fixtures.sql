-- =========================================================================
-- Fixtures del arnés de concurrencia (#1288, plan #1378 tarjeta 1)
--
-- Se cargan SÓLO en la rama de Supabase (nunca en prod), con
--   node scripts/concurrencia/run.mjs fixtures
-- que manda cada bloque (separados por las líneas "-- GO") a la edge function
-- `harness`. Todo vive en el schema `conc`, que PostgREST no expone, más las filas
-- de prueba (sucursales CONC-A y CONC-B, usuarios @conc.test, productos CONC-*).
-- Nada de datos reales de prod: la rama nace vacía.
--
-- Usuarios (se crean por auth.users, como el alta del panel: el trigger
-- handle_new_user arma perfiles y usuario_sucursales con el rol y la sucursal de
-- raw_app_meta_data, #1243):
--   CONC-A: admin_a, admin_a2, enc_a, tr_a1, tr_a2, prev_a1..prev_aN
--   CONC-B: admin_b, tr_b   (C6 vive en otra sucursal: una rendición confirmada
--                            bloquea todo cobro de su sucursal con fecha <= la suya)
-- =========================================================================
CREATE SCHEMA IF NOT EXISTS conc;
-- GO
CREATE TABLE IF NOT EXISTS conc.fx (k text PRIMARY KEY, v text NOT NULL);
-- GO
CREATE OR REPLACE FUNCTION conc.hoy() RETURNS date LANGUAGE sql STABLE AS $$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
$$;
-- GO
CREATE OR REPLACE FUNCTION conc.f(p_k text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT v FROM conc.fx WHERE k = p_k
$$;
-- GO
CREATE OR REPLACE FUNCTION conc.alta_usuario(p_email text, p_rol text, p_suc bigint) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id uuid := gen_random_uuid();
BEGIN
  -- Sin email_confirmed_at: el auth.users de la imagen local de Docker es un stub viejo que no lo tiene, y a la base le da lo mismo.
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', p_email, '',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc),
          jsonb_build_object('nombre', p_email), now(), now());
  RETURN v_id;
END
$$;
-- GO
-- Se hace pasar por un usuario, como PostgREST: claims, sucursal activa y rol.
-- SET LOCAL: dura hasta el final de la transacción.
CREATE OR REPLACE FUNCTION conc.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  SET LOCAL ROLE authenticated;
END
$$;
-- GO
CREATE OR REPLACE FUNCTION conc.nuevo_cliente(p_suc bigint, p_nombre text DEFAULT 'CONC-cli') RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'x', p_suc) RETURNING id INTO v_id;
  RETURN v_id;
END
$$;
-- GO
-- Producto con `p_bolsa` unidades sin lote y lotes ([{dias, cantidad}]) que
-- vencen en orden. stock = bolsa + suma de lo que queda en los lotes.
CREATE OR REPLACE FUNCTION conc.nuevo_producto(p_suc bigint, p_bolsa int, p_precio numeric DEFAULT 100,
                                               p_lotes jsonb DEFAULT '[]'::jsonb, p_nombre text DEFAULT 'CONC-prod')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_prod bigint;
  l jsonb;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, p_precio,
          p_bolsa + (SELECT COALESCE(SUM((x->>'cantidad')::int), 0) FROM jsonb_array_elements(p_lotes) x),
          60, p_suc)
  RETURNING id INTO v_prod;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante)
    VALUES (v_prod, p_suc, conc.hoy() + (l->>'dias')::int, (l->>'cantidad')::int, (l->>'cantidad')::int);
  END LOOP;
  RETURN v_prod;
END
$$;
-- GO
-- Una venta como la hace la app: crear_pedido_completo con el total que dicen las líneas.
CREATE OR REPLACE FUNCTION conc.venta(p_uid uuid, p_suc bigint, p_cli bigint, p_items jsonb, p_fecha date DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_total numeric;
  v_r jsonb;
BEGIN
  SELECT SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) INTO v_total
    FROM jsonb_array_elements(p_items) e;
  PERFORM conc.como(p_uid, p_suc);
  v_r := public.crear_pedido_completo(p_cli, v_total, p_uid, p_items, 'conc', 'efectivo', 'pendiente', p_fecha);
  RESET ROLE;
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'conc.venta: %', v_r;
  END IF;
  RETURN (v_r->>'pedido_id')::bigint;
END
$$;
-- GO
-- Un pedido de `p_monto` pesos (p_monto unidades de $1 del producto de relleno).
CREATE OR REPLACE FUNCTION conc.pedido_de(p_uid uuid, p_suc bigint, p_cli bigint, p_monto int, p_fecha date DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $$
  SELECT conc.venta(p_uid, p_suc, p_cli,
    jsonb_build_array(jsonb_build_object('producto_id', conc.f('relleno_' || p_suc)::bigint,
                                         'cantidad', p_monto, 'precio_unitario', 1)), p_fecha)
$$;
-- GO
-- El cobro de una boleta como lo arma la app.
CREATE OR REPLACE FUNCTION conc.cobro(p_uid uuid, p_suc bigint, p_ped bigint, p_metodos jsonb, p_fecha date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_r jsonb;
  v_fecha date := COALESCE(p_fecha, conc.hoy());
BEGIN
  PERFORM conc.como(p_uid, p_suc);
  v_r := public.registrar_pagos_pedido(p_ped, p_metodos, v_fecha, 'conc', NULL, NULL);
  RESET ROLE;
  RETURN v_r;
END
$$;
-- GO
-- Siembra única: sucursales, usuarios, producto de relleno y el catálogo de la carga.
CREATE OR REPLACE FUNCTION conc.sembrar(p_cajas int DEFAULT 16, p_productos int DEFAULT 200, p_clientes int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_a bigint;
  v_b bigint;
  i int;
  v_u record;
BEGIN
  SELECT id INTO v_a FROM public.sucursales WHERE nombre = 'CONC-A';
  IF v_a IS NULL THEN INSERT INTO public.sucursales (nombre, activa) VALUES ('CONC-A', true) RETURNING id INTO v_a; END IF;
  SELECT id INTO v_b FROM public.sucursales WHERE nombre = 'CONC-B';
  IF v_b IS NULL THEN INSERT INTO public.sucursales (nombre, activa) VALUES ('CONC-B', true) RETURNING id INTO v_b; END IF;
  INSERT INTO conc.fx VALUES ('suc_a', v_a::text), ('suc_b', v_b::text) ON CONFLICT (k) DO UPDATE SET v = excluded.v;

  FOR v_u IN
    SELECT * FROM (VALUES
      ('admin_a', 'admin', v_a), ('admin_a2', 'admin', v_a), ('enc_a', 'encargado', v_a),
      ('tr_a1', 'transportista', v_a), ('tr_a2', 'transportista', v_a),
      ('admin_b', 'admin', v_b), ('tr_b', 'transportista', v_b)) t(k, rol, suc)
  LOOP
    IF conc.f(v_u.k) IS NULL THEN
      INSERT INTO conc.fx VALUES (v_u.k, conc.alta_usuario(v_u.k || '@conc.test', v_u.rol, v_u.suc)::text);
    END IF;
  END LOOP;
  FOR i IN 1..p_cajas LOOP
    IF conc.f('prev_a' || i) IS NULL THEN
      INSERT INTO conc.fx VALUES ('prev_a' || i, conc.alta_usuario('prev_a' || i || '@conc.test', 'preventista', v_a)::text);
    END IF;
  END LOOP;

  -- producto de relleno ($1, stock enorme) para armar boletas de un monto exacto
  IF conc.f('relleno_' || v_a) IS NULL THEN
    INSERT INTO conc.fx VALUES ('relleno_' || v_a, conc.nuevo_producto(v_a, 2000000000, 1, '[]', 'CONC-relleno')::text);
  END IF;
  IF conc.f('relleno_' || v_b) IS NULL THEN
    INSERT INTO conc.fx VALUES ('relleno_' || v_b, conc.nuevo_producto(v_b, 2000000000, 1, '[]', 'CONC-relleno')::text);
  END IF;

  -- catálogo y clientes de la carga (C8)
  IF (SELECT count(*) FROM public.productos WHERE nombre LIKE 'CONC-P%' AND sucursal_id = v_a) < p_productos THEN
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    SELECT 'CONC-P' || lpad(g::text, 4, '0'), 100 + (g % 50), 1000000, 60, v_a
      FROM generate_series(1, p_productos) g
     WHERE NOT EXISTS (SELECT 1 FROM public.productos WHERE nombre = 'CONC-P' || lpad(g::text, 4, '0') AND sucursal_id = v_a);
  END IF;
  IF (SELECT count(*) FROM public.clientes WHERE razon_social LIKE 'CONC-C%' AND sucursal_id = v_a) < p_clientes THEN
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    SELECT 'CONC-C' || lpad(g::text, 4, '0'), 'CONC-C' || lpad(g::text, 4, '0'), 'x', v_a
      FROM generate_series(1, p_clientes) g
     WHERE NOT EXISTS (SELECT 1 FROM public.clientes WHERE razon_social = 'CONC-C' || lpad(g::text, 4, '0') AND sucursal_id = v_a);
  END IF;
  RETURN (SELECT jsonb_object_agg(k, v) FROM conc.fx);
END
$$;
-- GO
-- Estado normalizado de un producto: stock y lo que queda en cada lote (por vencimiento).
CREATE OR REPLACE FUNCTION conc.estado_prod(p_prod bigint) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT (SELECT stock FROM public.productos WHERE id = p_prod)::text || ':' ||
         COALESCE((SELECT string_agg(cantidad_restante::text, ',' ORDER BY fecha_vencimiento, id)
                     FROM public.producto_lotes WHERE producto_id = p_prod), '')
$$;
-- GO
-- Lo que tiene que cumplirse siempre, sea cual sea el orden: stock >= 0 y >= lo que
-- queda en lotes, y stock = inicial - lo vendido que sigue vivo (± ajustes).
CREATE OR REPLACE FUNCTION conc.stock_cierra(p_prod bigint, p_inicial int, p_ajuste int DEFAULT 0) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN s.stock < 0 THEN 'stock negativo: ' || s.stock
    WHEN s.stock < COALESCE(l.lotes, 0) THEN 'stock ' || s.stock || ' < lotes ' || l.lotes
    WHEN s.stock <> p_inicial - COALESCE(v.vivo, 0) + p_ajuste
      THEN 'stock ' || s.stock || ' <> ' || p_inicial || ' - vendido vivo ' || COALESCE(v.vivo, 0) || ' + ajuste ' || p_ajuste
    WHEN l.malos > 0 THEN 'lote fuera de rango'
    ELSE NULL END
  FROM (SELECT stock FROM public.productos WHERE id = p_prod) s,
       (SELECT SUM(cantidad_restante) AS lotes,
               COUNT(*) FILTER (WHERE cantidad_restante < 0 OR cantidad_restante > cantidad) AS malos
          FROM public.producto_lotes WHERE producto_id = p_prod) l,
       (SELECT SUM(pi.cantidad) AS vivo
          FROM public.pedido_items pi JOIN public.pedidos pe ON pe.id = pi.pedido_id
         WHERE pi.producto_id = p_prod AND COALESCE(pe.estado, '') NOT IN ('cancelado', 'anulado')) v
$$;
-- GO
-- Multiconjunto de pagos de un cliente (monto / a una boleta o a favor / en la foto
-- de una rendición), sin depender de los ids.
CREATE OR REPLACE FUNCTION conc.estado_pagos(p_cli bigint) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT COALESCE(string_agg(t.x, ',' ORDER BY t.x), '')
    FROM (SELECT round(pg.monto, 2)::text || '/' || CASE WHEN pg.pedido_id IS NULL THEN 'F' ELSE 'P' END || '/' ||
                 CASE WHEN EXISTS (SELECT 1 FROM public.rendicion_pagos_confirmados r WHERE r.pago_id = pg.id) THEN 'f' ELSE '-' END AS x
            FROM public.pagos pg WHERE pg.cliente_id = p_cli) t
$$;
-- GO
-- C1: una boleta de p_total sin pagar.
CREATE OR REPLACE FUNCTION conc.c1_setup(p_total int DEFAULT 80) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
BEGIN
  RETURN jsonb_build_object('admin', v_adm, 'suc', v_suc, 'cli', v_cli, 'total', p_total,
                            'pedido', conc.pedido_de(v_adm, v_suc, v_cli, p_total));
END
$$;
-- GO
-- C2: un cliente con tres boletas (100, 200 y 300) de días distintos.
CREATE OR REPLACE FUNCTION conc.c2_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_p1 bigint; v_p2 bigint; v_p3 bigint;
BEGIN
  v_p1 := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 3);
  v_p2 := conc.pedido_de(v_adm, v_suc, v_cli, 200, conc.hoy() - 2);
  v_p3 := conc.pedido_de(v_adm, v_suc, v_cli, 300, conc.hoy() - 1);
  RETURN jsonb_build_object('admin', v_adm, 'enc', conc.f('enc_a')::uuid, 'tr', conc.f('tr_a1')::uuid, 'suc', v_suc,
                            'cli', v_cli, 'p1', v_p1, 'p2', v_p2, 'p3', v_p3, 'ids', jsonb_build_array(v_p1, v_p2, v_p3));
END
$$;
-- GO
-- C3/C4/C5: n productos con stock p_bolsa y los lotes dados; dos clientes y dos preventistas.
-- p_mismo_cliente = true: las dos ventas son al mismo cliente (cruzan también el saldo).
CREATE OR REPLACE FUNCTION conc.c3_setup(p_n int, p_bolsa int, p_lotes jsonb DEFAULT '[]'::jsonb,
                                         p_mismo_cliente boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_prods jsonb := '[]'::jsonb;
  v_cli1 bigint := conc.nuevo_cliente(v_suc);
  v_cli2 bigint;
  i int;
BEGIN
  v_cli2 := CASE WHEN p_mismo_cliente THEN v_cli1 ELSE conc.nuevo_cliente(v_suc) END;
  FOR i IN 1..p_n LOOP
    v_prods := v_prods || to_jsonb(conc.nuevo_producto(v_suc, p_bolsa, 100, p_lotes));
  END LOOP;
  RETURN jsonb_build_object('suc', v_suc, 'admin', conc.f('admin_a')::uuid,
                            'p1', conc.f('prev_a1')::uuid, 'p2', conc.f('prev_a2')::uuid,
                            'cli1', v_cli1, 'cli2', v_cli2, 'prods', v_prods,
                            'pa', v_prods->0, 'pb', COALESCE(v_prods->1, v_prods->0),
                            'stock0', p_bolsa + (SELECT COALESCE(SUM((x->>'cantidad')::int), 0) FROM jsonb_array_elements(p_lotes) x));
END
$$;
-- GO
-- C4 (cancelar / editar): como c3_setup, más un pedido X de p_cant del producto A (y, si
-- p_dos, del B) tomado por el admin al cliente 1. stock0 es el de ANTES de X.
CREATE OR REPLACE FUNCTION conc.c4_setup(p_bolsa int, p_lotes jsonb, p_cant int, p_dos boolean DEFAULT false,
                                         p_mismo_cliente boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_c jsonb := conc.c3_setup(CASE WHEN p_dos THEN 2 ELSE 1 END, p_bolsa, p_lotes, p_mismo_cliente);
  v_items jsonb;
  v_x bigint;
BEGIN
  v_items := jsonb_build_array(jsonb_build_object('producto_id', (v_c->>'pa')::bigint, 'cantidad', p_cant, 'precio_unitario', 100));
  IF p_dos THEN
    v_items := v_items || jsonb_build_array(jsonb_build_object('producto_id', (v_c->>'pb')::bigint, 'cantidad', p_cant, 'precio_unitario', 100));
  END IF;
  v_x := conc.venta((v_c->>'admin')::uuid, (v_c->>'suc')::bigint, (v_c->>'cli1')::bigint, v_items);
  RETURN v_c || jsonb_build_object('x', v_x, 'items_x', v_items);
END
$$;
-- GO
-- C5: productos con stock, una planilla (uuid nuevo) que cuenta stock_real contra stock_planilla.
CREATE OR REPLACE FUNCTION conc.c5_setup(p_n int, p_stock int, p_real int, p_lotes jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_c jsonb := conc.c3_setup(p_n, p_stock, p_lotes, false);
  v_stock0 int := (v_c->>'stock0')::int;
  v_aj jsonb := '[]'::jsonb;
  v_p jsonb;
BEGIN
  FOR v_p IN SELECT * FROM jsonb_array_elements(v_c->'prods') LOOP
    v_aj := v_aj || jsonb_build_array(jsonb_build_object('producto_id', v_p, 'stock_real', p_real, 'stock_planilla', v_stock0));
  END LOOP;
  RETURN v_c || jsonb_build_object('planilla', gen_random_uuid(), 'ajustes', v_aj, 'diferencia', p_real - v_stock0);
END
$$;
-- GO
-- C6: sucursal B. Boleta de 100 con dos cobros del mismo día (60 + 40), de un día distinto
-- por ronda (creciente, para no chocar con la caja cerrada de la ronda anterior: una rendición
-- confirmada cierra la caja de la sucursal hasta su día y no se reabre). La ventana es de 900
-- días hacia atrás para que entren C6, C6b y C6c, cada una con su tramo (ver escenarios.mjs).
-- Devuelve también p1/p2 (los dos pagos, p1 el más viejo) y un segundo cliente (para C6c).
-- p_tocar: actualiza P1 después de crearlo, para que su versión vigente quede físicamente DESPUÉS de P2 (un
-- UPDATE ... WHERE pedido_id recorre en orden físico, no de id). Es lo que pasa con un pago que ya se editó.
CREATE OR REPLACE FUNCTION conc.c6_setup(p_ronda int, p_tocar boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_b')::bigint;
  v_adm uuid := conc.f('admin_b')::uuid;
  v_tr uuid := conc.f('tr_b')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_cli2 bigint := conc.nuevo_cliente(v_suc);
  v_fecha date := conc.hoy() - 900 + p_ronda;
  v_ped bigint;
  v_r jsonb;
  v_p1 bigint; v_p2 bigint;
BEGIN
  v_ped := conc.pedido_de(v_adm, v_suc, v_cli, 100, v_fecha);
  v_r := conc.cobro(v_adm, v_suc, v_ped, '[{"monto":60,"forma_pago":"efectivo"},{"monto":40,"forma_pago":"transferencia"}]'::jsonb, v_fecha);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 'c6_setup cobro: %', v_r; END IF;
  SELECT min(id), max(id) INTO v_p1, v_p2 FROM public.pagos WHERE pedido_id = v_ped;
  IF p_tocar THEN UPDATE public.pagos SET notas = trim(COALESCE(notas, '') || ' tocado') WHERE id = v_p1; END IF;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'tr', v_tr, 'cli', v_cli, 'cli2', v_cli2, 'pedido', v_ped, 'fecha', v_fecha,
                            'relleno', conc.f('relleno_' || v_suc)::bigint, 'p1', v_p1, 'p2', v_p2);
END
$$;
-- GO
-- C7: dos pedidos X e Y de la sucursal A en una ruta [X, Y] de tr_a1, de un día distinto por ronda.
CREATE OR REPLACE FUNCTION conc.c7_setup(p_ronda int, p_fecha_base int DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_enc uuid := conc.f('enc_a')::uuid;
  v_tr uuid := conc.f('tr_a1')::uuid;
  v_x bigint; v_y bigint;
  v_fecha date := conc.hoy() - 1 - p_fecha_base - p_ronda;
  v_rec bigint;
BEGIN
  v_x := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  v_y := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  PERFORM conc.como(v_enc, v_suc);
  v_rec := public.aplicar_orden_ruta(v_tr, jsonb_build_array(
             jsonb_build_object('pedido_id', v_x, 'orden_entrega', 1),
             jsonb_build_object('pedido_id', v_y, 'orden_entrega', 2)), NULL, NULL, NULL, v_fecha);
  RESET ROLE;
  RETURN jsonb_build_object('suc', v_suc, 'enc', v_enc, 'enc2', conc.f('admin_a2')::uuid, 'tr', v_tr, 'x', v_x, 'y', v_y,
                            'fecha', v_fecha, 'recorrido', v_rec);
END
$$;
