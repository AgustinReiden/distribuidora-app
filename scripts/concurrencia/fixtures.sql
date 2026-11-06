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
--   CONC-C: admin_c, admin_c2, enc_c, tr_c   (la repetición final: las variantes que confirman
--                            una rendición y no caben en la ventana de días de CONC-B)
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
  v_c bigint;
  i int;
  v_u record;
BEGIN
  SELECT id INTO v_a FROM public.sucursales WHERE nombre = 'CONC-A';
  IF v_a IS NULL THEN INSERT INTO public.sucursales (nombre, activa) VALUES ('CONC-A', true) RETURNING id INTO v_a; END IF;
  SELECT id INTO v_b FROM public.sucursales WHERE nombre = 'CONC-B';
  IF v_b IS NULL THEN INSERT INTO public.sucursales (nombre, activa) VALUES ('CONC-B', true) RETURNING id INTO v_b; END IF;
  SELECT id INTO v_c FROM public.sucursales WHERE nombre = 'CONC-C';
  IF v_c IS NULL THEN INSERT INTO public.sucursales (nombre, activa) VALUES ('CONC-C', true) RETURNING id INTO v_c; END IF;
  INSERT INTO conc.fx VALUES ('suc_a', v_a::text), ('suc_b', v_b::text), ('suc_c', v_c::text) ON CONFLICT (k) DO UPDATE SET v = excluded.v;

  FOR v_u IN
    SELECT * FROM (VALUES
      ('admin_a', 'admin', v_a), ('admin_a2', 'admin', v_a), ('enc_a', 'encargado', v_a),
      ('tr_a1', 'transportista', v_a), ('tr_a2', 'transportista', v_a),
      ('admin_b', 'admin', v_b), ('tr_b', 'transportista', v_b),
      ('admin_c', 'admin', v_c), ('admin_c2', 'admin', v_c), ('enc_c', 'encargado', v_c), ('tr_c', 'transportista', v_c)) t(k, rol, suc)
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
  IF conc.f('relleno_' || v_c) IS NULL THEN
    INSERT INTO conc.fx VALUES ('relleno_' || v_c, conc.nuevo_producto(v_c, 2000000000, 1, '[]', 'CONC-relleno')::text);
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
-- p_suf: 'b' (CONC-B, C6 a C6d) o 'c' (CONC-C, las variantes de la repetición final que también confirman rendiciones).
DROP FUNCTION IF EXISTS conc.c6_setup(int, boolean);
-- GO
CREATE OR REPLACE FUNCTION conc.c6_setup(p_ronda int, p_tocar boolean DEFAULT false, p_suf text DEFAULT 'b') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_' || p_suf)::bigint;
  v_adm uuid := conc.f('admin_' || p_suf)::uuid;
  v_tr uuid := conc.f('tr_' || p_suf)::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_cli2 bigint := conc.nuevo_cliente(v_suc);
  v_fecha date := conc.hoy() - CASE p_suf WHEN 'b' THEN 900 ELSE 1500 END + p_ronda;
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
-- C6e (#1359/#1369): un pedazo de pago que se vuelve a partir. Sucursal A, boleta de 100 de tr_a1
-- pagada por un pedazo Y de un crédito R de 140 que cargó admin_a (R queda en 40 a favor). Recortar
-- la boleta a 70 parte a Y: 70 y un pedazo Z de 30 a favor, hijo de Y y no de R. El día de cada
-- ronda es el siguiente al último cerrado de la sucursal, desde hoy - 2000: así se puede repetir
-- sobre la misma base, y la caja de A queda cerrada muy atrás de lo que usan C1–C5, C7 y C8.
CREATE OR REPLACE FUNCTION conc.c6e_setup(p_ronda int) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_tr uuid := conc.f('tr_a1')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_fecha date;
  v_ped bigint;
  v_r bigint;
  v_y bigint;
BEGIN
  SELECT GREATEST(COALESCE(max(fecha), conc.hoy() - 2000), conc.hoy() - 2000) + 1 INTO v_fecha
    FROM public.rendiciones_control
   WHERE sucursal_id = v_suc AND estado IN ('confirmada', 'resuelta');
  IF v_fecha > conc.hoy() - 1500 THEN RAISE EXCEPTION 'c6e_setup: se agotó el tramo de días'; END IF;
  v_ped := conc.pedido_de(v_adm, v_suc, v_cli, 100, v_fecha);
  UPDATE public.pedidos SET transportista_id = v_tr WHERE id = v_ped;
  INSERT INTO public.pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas)
  VALUES (v_cli, NULL, 140, 'efectivo', v_fecha, v_adm, v_suc, 'conc') RETURNING id INTO v_r;
  PERFORM public.aplicar_credito_cliente(v_cli, v_suc);
  SELECT id INTO v_y FROM public.pagos WHERE pedido_id = v_ped AND pago_origen_id = v_r AND monto = 100;
  IF v_y IS NULL THEN RAISE EXCEPTION 'c6e_setup: el crédito no se partió en 100 para la boleta'; END IF;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'tr', v_tr, 'cli', v_cli, 'pedido', v_ped, 'fecha', v_fecha,
                            'relleno', conc.f('relleno_' || v_suc)::bigint, 'r', v_r, 'y', v_y);
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
-- GO
-- C7g (tarjeta 2, #1375/#1397): dos recorridos de dos pedidos cada uno, para cruzar dos marcar_entregas_masivo SIN pedidos en común.
-- Cada recorrido tiene un pedido de cada masiva, en orden cruzado (a,d) y (b,c).
CREATE OR REPLACE FUNCTION conc.c7g_setup(p_ronda int, p_fecha_base int) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_enc uuid := conc.f('enc_a')::uuid;
  v_t1 uuid := conc.f('tr_a1')::uuid;
  v_t2 uuid := conc.f('tr_a2')::uuid;
  v_fecha date := conc.hoy() - 1 - p_fecha_base - p_ronda;
  a bigint; b bigint; c bigint; d bigint; r1 bigint; r2 bigint;
BEGIN
  a := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  b := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  c := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  d := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  PERFORM conc.como(v_enc, v_suc);
  r1 := public.aplicar_orden_ruta(v_t1, jsonb_build_array(jsonb_build_object('pedido_id', a, 'orden_entrega', 1), jsonb_build_object('pedido_id', d, 'orden_entrega', 2)), NULL, NULL, NULL, v_fecha);
  r2 := public.aplicar_orden_ruta(v_t2, jsonb_build_array(jsonb_build_object('pedido_id', b, 'orden_entrega', 1), jsonb_build_object('pedido_id', c, 'orden_entrega', 2)), NULL, NULL, NULL, v_fecha);
  RESET ROLE;
  RETURN jsonb_build_object('suc', v_suc, 'enc', v_enc, 'enc2', conc.f('admin_a2')::uuid, 'tr1', v_t1, 'tr2', v_t2,
                            'a', a, 'b', b, 'c', c, 'd', d, 'r1', r1, 'r2', r2);
END
$$;
-- GO
-- C10 (regalos, #1326): A dispara una promo "compra 10, lleva 2" cuyo regalo es B; C y D son los sustitutos. Los ids
-- quedan A < C < D < B: el original (B) es MAYOR que los sustitutos, el caso que antes se bloqueaba al revés. X = 10 de
-- A + 2 de regalo de B; `item` es la línea del regalo.
CREATE OR REPLACE FUNCTION conc.c10_setup(p_bolsa int DEFAULT 20) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli1 bigint := conc.nuevo_cliente(v_suc);
  v_a bigint; v_b bigint; v_c bigint; v_d bigint;
  v_promo bigint; v_x bigint; v_item bigint;
BEGIN
  v_a := conc.nuevo_producto(v_suc, p_bolsa * 3, 100, '[]', 'CONC-regalo-A');
  v_c := conc.nuevo_producto(v_suc, p_bolsa, 100, '[]', 'CONC-regalo-C');
  v_d := conc.nuevo_producto(v_suc, p_bolsa, 100, '[]', 'CONC-regalo-D');
  v_b := conc.nuevo_producto(v_suc, p_bolsa, 100, '[]', 'CONC-regalo-B');
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id, ajuste_automatico)
  VALUES ('CONC regalo', 'bonificacion', conc.hoy() - 1, v_suc, true, v_b, false) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_a, v_suc);
  v_x := conc.venta(v_adm, v_suc, v_cli1, jsonb_build_array(
           jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 100),
           jsonb_build_object('producto_id', v_b, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo)));
  SELECT id INTO v_item FROM public.pedido_items WHERE pedido_id = v_x AND producto_id = v_b AND COALESCE(es_bonificacion, false);
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'p2', conc.f('prev_a2')::uuid, 'cli1', v_cli1,
                            'pa', v_a, 'pc', v_c, 'pd', v_d, 'pb', v_b, 'promo', v_promo, 'x', v_x, 'item', v_item);
END
$$;
-- GO
-- C9 (#1342): dos pedidos X e Y de la sucursal A, sin entregar, de tr_a2 (C7 usa tr_a1: así lo
-- entregado de un día es sólo lo de la ronda). El día crece con la ronda, desde hoy - p_base:
-- una rendición confirmada cierra la caja de la sucursal hasta su día, y la variante con cobro
-- necesita que la ronda siguiente caiga después.
CREATE OR REPLACE FUNCTION conc.c9_setup(p_ronda int, p_base int) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_tr uuid := conc.f('tr_a2')::uuid;
  v_fecha date := conc.hoy() - p_base + p_ronda;
  v_x bigint; v_y bigint;
BEGIN
  v_x := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  v_y := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  RETURN jsonb_build_object('suc', v_suc, 'adm', v_adm, 'adm2', conc.f('admin_a2')::uuid, 'enc', conc.f('enc_a')::uuid,
                            'tr', v_tr, 'x', v_x, 'y', v_y, 'fecha', v_fecha);
END
$$;
-- GO
-- C12 (#1398): una promo en la que el regalo no mueve stock (modo B), con auto-ajuste: cada 2 de regalo cierra un
-- bloque y baja 1 del CONTENEDOR (promociones.ajuste_producto_id). A es el producto que se compra y S el sabor del
-- regalo. Los ids, según p_modo:
--   'menor'  C < A < S: el contenedor es menor que lo que bloquea la venta antes de llegar al motor de promos.
--   'mayor'  A < S < C: el contenedor es el mayor de todos.
--   'sabor'  C = S: el contenedor es el sabor, que es lo único que hay hoy en prod.
-- X (si p_con_x): 10 de A + 2 de regalo, tomado por el admin al cliente 1 (cierra un bloque: C queda en 19).
-- p_limite: limite_usos de la promo (NULL, sin límite). p_bot: deja además una confirmación del bot de prev_a2 para el
-- cliente 2 con la misma venta (10 de A + 2 de regalo), lista para crear_pedido_completo_bot.
CREATE OR REPLACE FUNCTION conc.c12_setup(p_modo text DEFAULT 'menor', p_limite int DEFAULT NULL,
                                          p_con_x boolean DEFAULT true, p_bot boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_p2 uuid := conc.f('prev_a2')::uuid;
  v_cli1 bigint := conc.nuevo_cliente(v_suc);
  v_cli2 bigint := conc.nuevo_cliente(v_suc);
  v_a bigint; v_s bigint; v_c bigint;
  v_promo bigint; v_x bigint; v_conf uuid;
  v_items jsonb;
BEGIN
  IF p_modo = 'menor' THEN
    v_c := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-c12-contenedor');
    v_a := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-c12-A');
    v_s := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-c12-sabor');
  ELSIF p_modo = 'mayor' THEN
    v_a := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-c12-A');
    v_s := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-c12-sabor');
    v_c := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-c12-contenedor');
  ELSIF p_modo = 'sabor' THEN
    v_a := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-c12-A');
    v_s := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-c12-sabor');
    v_c := v_s;
  ELSE
    RAISE EXCEPTION 'c12_setup: modo % desconocido', p_modo;
  END IF;
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                                  ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque, limite_usos)
  VALUES ('CONC c12', 'bonificacion', conc.hoy() - 1, v_suc, false, v_s, true, v_c, 2, 1, p_limite)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_a, v_suc);
  v_items := jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 100),
    jsonb_build_object('producto_id', v_s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo));
  IF p_con_x THEN
    v_x := conc.venta(v_adm, v_suc, v_cli1, v_items);
  END IF;
  IF p_bot THEN
    INSERT INTO public.bot_pedidos_pendientes (id, perfil_id, sucursal_id, cliente_id, items, total, forma_pago, notas,
                                               consumido, expires_at, cargo_mostrado)
    VALUES (gen_random_uuid(), v_p2, v_suc, v_cli2, v_items, 1000, 'efectivo', 'conc', false, now() + interval '10 minutes',
            public.pedido_cargo_envio(1000, v_suc))
    RETURNING id INTO v_conf;
  END IF;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'p1', conc.f('prev_a1')::uuid, 'p2', v_p2,
                            'cli1', v_cli1, 'cli2', v_cli2, 'pa', v_a, 'ps', v_s, 'pc', v_c, 'promo', v_promo,
                            'x', v_x, 'conf', v_conf, 'c0', 20, 'limite', p_limite);
END
$$;
-- GO
-- C12m a C12o (#1442): una promo común (el regalo mueve stock, sin auto-ajuste) a la que se le cambia el tipo mientras una
-- venta se carga. A se compra y S es el regalo (stock 20). No hay X: la venta es el primer regalo de la promo, así que el
-- sello de la línea sale de la promo y la foto se toma en ese INSERT.
CREATE OR REPLACE FUNCTION conc.c12m_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_a bigint := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-c12m-A');
  v_s bigint := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-c12m-sabor');
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id, ajuste_automatico)
  VALUES ('CONC c12m', 'bonificacion', conc.hoy() - 1, v_suc, true, v_s, false) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_a, v_suc);
  RETURN jsonb_build_object('suc', v_suc, 'admin', conc.f('admin_a')::uuid, 'p2', conc.f('prev_a2')::uuid,
                            'cli2', conc.nuevo_cliente(v_suc), 'pa', v_a, 'ps', v_s, 'promo', v_promo);
END
$$;
-- GO
-- C12k (#1398): dos promos comunes (el regalo mueve stock, sin auto-ajuste) y dos ventas de admin sin ningún producto en
-- común: la 1 lleva el regalo de P1 y después el de P2; la 2, al revés. Lo único que comparten son las dos filas de
-- promociones, que aplicar_uso_promo_acumulador bloquea en el orden de las líneas del JSON. P1 < P2.
CREATE OR REPLACE FUNCTION conc.c12k_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_p1 bigint; v_p2 bigint;
  v_a1 bigint; v_b1 bigint; v_a2 bigint; v_b2 bigint;
  v_r1a bigint; v_r1b bigint; v_r2a bigint; v_r2b bigint;
BEGIN
  v_a1 := conc.nuevo_producto(v_suc, 50); v_b1 := conc.nuevo_producto(v_suc, 50);
  v_a2 := conc.nuevo_producto(v_suc, 50); v_b2 := conc.nuevo_producto(v_suc, 50);
  v_r1a := conc.nuevo_producto(v_suc, 20); v_r1b := conc.nuevo_producto(v_suc, 20);
  v_r2a := conc.nuevo_producto(v_suc, 20); v_r2b := conc.nuevo_producto(v_suc, 20);
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id, ajuste_automatico)
  VALUES ('CONC c12k uno', 'bonificacion', conc.hoy() - 1, v_suc, true, v_r1a, false) RETURNING id INTO v_p1;
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id, ajuste_automatico)
  VALUES ('CONC c12k dos', 'bonificacion', conc.hoy() - 1, v_suc, true, v_r2a, false) RETURNING id INTO v_p2;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_p1, 'cantidad_compra', 10, v_suc), (v_p1, 'cantidad_bonificacion', 2, v_suc),
         (v_p2, 'cantidad_compra', 10, v_suc), (v_p2, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_p1, v_a1, v_suc), (v_p1, v_b1, v_suc), (v_p2, v_a2, v_suc), (v_p2, v_b2, v_suc);
  RETURN jsonb_build_object('suc', v_suc, 'admin', conc.f('admin_a')::uuid, 'admin2', conc.f('admin_a2')::uuid,
                            'cli1', conc.nuevo_cliente(v_suc), 'cli2', conc.nuevo_cliente(v_suc),
                            'promo1', v_p1, 'promo2', v_p2, 'a1', v_a1, 'b1', v_b1, 'a2', v_a2, 'b2', v_b2,
                            'r1a', v_r1a, 'r1b', v_r1b, 'r2a', v_r2a, 'r2b', v_r2b);
END
$$;
-- GO
-- ===== T10 (#1439, #1424, plan #1378 tarjeta 10): cobros, créditos y stock contra el orden global de locks =====
-- Sucursal A (el origen de T10l es B). Las variantes que confirman rendiciones usan el tramo de días de 5000 a 4602
-- hacia atrás de hoy y lo eligen solas: cada setup toma el siguiente día del contador `t10_dia` (o el siguiente al
-- último cerrado de A, si es mayor), haya cerrado o no la ronda anterior. Las rutas usan choferes nuevos en cada
-- ronda y un día fijo del tramo (hoy - 4601), así que no gastan días. Correr `t10` antes que C6e y C9, o sobre una
-- base nueva: esas cierran la caja de A hasta hoy - 1500.

-- Un crédito (pago a cuenta sin boleta), como lo deja el FIFO cuando sobra plata.
CREATE OR REPLACE FUNCTION conc.t10_credito(p_suc bigint, p_cli bigint, p_monto numeric, p_fecha date, p_uid uuid) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas, a_cuenta)
  VALUES (p_cli, NULL, p_monto, 'efectivo', p_fecha, p_uid, p_suc, 'conc [saldo a favor]', true)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$$;
-- GO
-- registrar_ingreso_sucursal y aceptar_movimiento_sucursal se tragan los errores (EXCEPTION WHEN OTHERS) y devuelven
-- success:false. Esto lo vuelve a levantar, con 40P01 si fue un deadlock, para que el arnés lo cuente.
CREATE OR REPLACE FUNCTION conc.t10_exigir(r jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RAISE EXCEPTION '%', r->>'error'
      USING ERRCODE = CASE WHEN r->>'error' LIKE 'deadlock detected%' THEN '40P01' ELSE 'P0001' END;
  END IF;
  RETURN r;
END
$$;
-- GO
GRANT USAGE ON SCHEMA conc TO authenticated;
-- GO
GRANT EXECUTE ON FUNCTION conc.t10_exigir(jsonb) TO authenticated;
-- GO
-- El siguiente día del tramo de las variantes que confirman rendiciones (ver arriba). p_n: cuántos días consecutivos.
CREATE OR REPLACE FUNCTION conc.t10_dia(p_n int DEFAULT 1) RETURNS date LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_d date;
BEGIN
  SELECT GREATEST(COALESCE((SELECT max(fecha) FROM public.rendiciones_control
                             WHERE sucursal_id = v_suc AND estado IN ('confirmada', 'resuelta')), conc.hoy() - 5000),
                  COALESCE(conc.f('t10_dia')::date, conc.hoy() - 5000),
                  conc.hoy() - 5000) + 1
    INTO v_d;
  IF v_d + p_n - 1 > conc.hoy() - 4602 THEN
    RAISE EXCEPTION 't10_dia: se agotó el tramo de días (5000 a 4602 hacia atrás); reconstruir la base';
  END IF;
  INSERT INTO conc.fx VALUES ('t10_dia', (v_d + p_n - 1)::text) ON CONFLICT (k) DO UPDATE SET v = excluded.v;
  RETURN v_d;
END
$$;
-- GO
-- T10a/T10b: un cliente con un crédito C de 30 (de hoy) y una boleta X de 100 (de ayer) sin cobrar. Con p_con_y,
-- además una boleta Y de 100 de anteayer, la que el crédito paga primero (por fecha).
CREATE OR REPLACE FUNCTION conc.t10_credito_setup(p_con_y boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_x bigint; v_y bigint;
BEGIN
  v_x := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 1);
  IF p_con_y THEN v_y := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 2); END IF;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'cli', v_cli, 'x', v_x, 'y', v_y,
                            'c', conc.t10_credito(v_suc, v_cli, 30, conc.hoy(), v_adm),
                            'relleno', conc.f('relleno_' || v_suc)::bigint);
END
$$;
-- GO
-- T10c/T10d: una boleta X de 100 cobrada hoy en dos pagos, P1 de 60 en efectivo y P2 de 40 por transferencia.
CREATE OR REPLACE FUNCTION conc.t10_cobrado_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_ped bigint;
  v_r jsonb;
  v_p1 bigint; v_p2 bigint;
BEGIN
  v_ped := conc.pedido_de(v_adm, v_suc, v_cli, 100);
  v_r := conc.cobro(v_adm, v_suc, v_ped, '[{"monto":60,"forma_pago":"efectivo"},{"monto":40,"forma_pago":"transferencia"}]'::jsonb);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't10_cobrado_setup cobro: %', v_r; END IF;
  SELECT min(id), max(id) INTO v_p1, v_p2 FROM public.pagos WHERE pedido_id = v_ped;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'cli', v_cli, 'pedido', v_ped, 'p1', v_p1, 'p2', v_p2);
END
$$;
-- GO
-- T10e/T10g: cuatro boletas de 50 del día hoy - 4601 (a < b < c < d), b y d del mismo cliente, en dos rutas de dos
-- choferes nuevos: r1 = [a, d] y r2 = [b, c] (r1 < r2). Cobrar [b, d] por fecha e id toma r2 y después r1; entregar
-- [a, c] toma r1 y después r2 (la 439).
CREATE OR REPLACE FUNCTION conc.t10_rutas_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_enc uuid := conc.f('enc_a')::uuid;
  v_fecha date := conc.hoy() - 4601;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_t1 uuid := conc.alta_usuario('t10-' || gen_random_uuid() || '@conc.test', 'transportista', v_suc);
  v_t2 uuid := conc.alta_usuario('t10-' || gen_random_uuid() || '@conc.test', 'transportista', v_suc);
  a bigint; b bigint; c bigint; d bigint; r1 bigint; r2 bigint;
BEGIN
  a := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  b := conc.pedido_de(v_adm, v_suc, v_cli, 50, v_fecha);
  c := conc.pedido_de(v_adm, v_suc, conc.nuevo_cliente(v_suc), 50, v_fecha);
  d := conc.pedido_de(v_adm, v_suc, v_cli, 50, v_fecha);
  PERFORM conc.como(v_enc, v_suc);
  r1 := public.aplicar_orden_ruta(v_t1, jsonb_build_array(jsonb_build_object('pedido_id', a, 'orden_entrega', 1), jsonb_build_object('pedido_id', d, 'orden_entrega', 2)), NULL, NULL, NULL, v_fecha);
  r2 := public.aplicar_orden_ruta(v_t2, jsonb_build_array(jsonb_build_object('pedido_id', b, 'orden_entrega', 1), jsonb_build_object('pedido_id', c, 'orden_entrega', 2)), NULL, NULL, NULL, v_fecha);
  RESET ROLE;
  -- aplicar_orden_ruta reescribió las boletas en el orden de las rutas (d antes que b). En prod la masiva las recorre
  -- por el índice (por id); en esta base chica, por orden físico. Tocar d la deja físicamente detrás de b.
  UPDATE public.pedidos SET notas = 'conc t10' WHERE id = d;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'enc', v_enc, 'enc2', conc.f('admin_a2')::uuid, 'cli', v_cli,
                            'tr1', v_t1, 'tr2', v_t2, 'a', a, 'b', b, 'c', c, 'd', d, 'r1', r1, 'r2', r2);
END
$$;
-- GO
-- T10f: un cliente con dos boletas de 50: X de ayer (creada primero, id menor) e Y de anteayer (id mayor). El FIFO las
-- toma por fecha (Y, X); una masiva, por id (X, Y).
CREATE OR REPLACE FUNCTION conc.t10_fifo_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_x bigint; v_y bigint;
BEGIN
  v_x := conc.pedido_de(v_adm, v_suc, v_cli, 50, conc.hoy() - 1);
  v_y := conc.pedido_de(v_adm, v_suc, v_cli, 50, conc.hoy() - 2);
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'enc', conc.f('enc_a')::uuid, 'cli', v_cli, 'x', v_x, 'y', v_y);
END
$$;
-- GO
-- T10h/T10i/T10j: contra la foto de la rendición del día D (tr_a1), que bloquea por id los pagos de A de ese día.
--   'eliminar': una boleta X de 100 de D cobrada ese día en P1 (60) y P2 (40). P1 se edita tocando una columna con
--               índice (created_at): su versión nueva queda físicamente detrás de P2 y la FK de pagos la recorre
--               después (si no, el setup falla).
--   'anular':   una NC de 50 sobre una boleta de D, con dos créditos sin imputar de ese día (P1 30, P2 20), P1 editado igual.
--   'aplicar':  una boleta X de 100 de D sin cobrar y dos créditos de tr_a1: P1 (30) del día D y P2 (20) del día D - 1,
--               cargado DESPUÉS de cerrar la rendición de D - 1 de tr_a1 (#1328: cae en D). P1 < P2 por id, pero
--               aplicar_credito_cliente los recorría por fecha: P2, P1.
CREATE OR REPLACE FUNCTION conc.t10_foto_setup(p_tipo text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_tr uuid := conc.f('tr_a1')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_d date;
  v_ped bigint;
  v_nc bigint;
  v_r jsonb;
  v_p1 bigint; v_p2 bigint;
BEGIN
  IF p_tipo = 'aplicar' THEN
    v_d := conc.t10_dia(2) + 1;
  ELSE
    v_d := conc.t10_dia(1);
  END IF;
  v_ped := conc.pedido_de(v_adm, v_suc, v_cli, 100, v_d);

  IF p_tipo = 'eliminar' THEN
    v_r := conc.cobro(v_adm, v_suc, v_ped, '[{"monto":60,"forma_pago":"efectivo"},{"monto":40,"forma_pago":"transferencia"}]'::jsonb, v_d);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't10_foto_setup cobro: %', v_r; END IF;
    SELECT min(id), max(id) INTO v_p1, v_p2 FROM public.pagos WHERE pedido_id = v_ped;
  ELSIF p_tipo = 'anular' THEN
    INSERT INTO public.notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, neto, iva, usuario_id)
    VALUES (v_suc, v_cli, v_ped, v_d, 'otro', 50, 50, 0, v_adm) RETURNING id INTO v_nc;
    INSERT INTO public.pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas, nota_credito_id)
    VALUES (v_cli, NULL, 30, 'nota_credito', v_d, v_adm, v_suc, 'conc NC', v_nc) RETURNING id INTO v_p1;
    INSERT INTO public.pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id, notas, nota_credito_id)
    VALUES (v_cli, NULL, 20, 'nota_credito', v_d, v_adm, v_suc, 'conc NC', v_nc) RETURNING id INTO v_p2;
  ELSIF p_tipo = 'aplicar' THEN
    v_p1 := conc.t10_credito(v_suc, v_cli, 30, v_d, v_tr);
    PERFORM conc.como(v_adm, v_suc);
    v_r := public.confirmar_rendicion(v_d - 1, v_tr, 'confirmada', '{}'::jsonb, 'conc');
    RESET ROLE;
    PERFORM set_config('app.reimputacion_pagos', 'on', true);
    v_p2 := conc.t10_credito(v_suc, v_cli, 20, v_d - 1, v_tr);
    PERFORM set_config('app.reimputacion_pagos', 'off', true);
    IF NOT EXISTS (SELECT 1 FROM public._rendicion_pagos(v_suc, v_d, v_d, NULL) v WHERE v.pago_id = v_p2) THEN
      RAISE EXCEPTION 't10_foto_setup: el crédito de D - 1 no cae en D (#1328); confirmar_rendicion dio %', v_r;
    END IF;
  ELSE
    RAISE EXCEPTION 't10_foto_setup: tipo %', p_tipo;
  END IF;

  IF p_tipo IN ('eliminar', 'anular') THEN
    UPDATE public.pagos SET created_at = created_at - interval '1 second', notas = trim(COALESCE(notas, '') || ' tocado')
     WHERE id = v_p1;
    IF (SELECT ctid FROM public.pagos WHERE id = v_p1) < (SELECT ctid FROM public.pagos WHERE id = v_p2) THEN
      RAISE EXCEPTION 't10_foto_setup: la versión nueva de P1 quedó antes que P2';
    END IF;
  END IF;

  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'tr', v_tr, 'cli', v_cli, 'pedido', v_ped, 'nc', v_nc,
                            'fecha', v_d, 'p1', v_p1, 'p2', v_p2);
END
$$;
-- GO
-- T10l: un envío de B a A de dos productos (oA < oB, 2 de cada uno, sin descontar en el origen), que la resolución
-- empareja al revés con los de A: oA → dY y oB → dX (dX < dY). El bucle de aceptar_movimiento_sucursal va por el
-- producto de origen, así que tomaba dY antes que dX; una venta en A los toma por id.
CREATE OR REPLACE FUNCTION conc.t10_mov_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_a bigint := conc.f('suc_a')::bigint;
  v_b bigint := conc.f('suc_b')::bigint;
  v_dx bigint; v_dy bigint; v_oa bigint; v_ob bigint;
  v_mov bigint; v_i1 bigint; v_i2 bigint;
BEGIN
  v_dx := conc.nuevo_producto(v_a, 10, 100, '[]', 'CONC-t10-dX');
  v_dy := conc.nuevo_producto(v_a, 10, 100, '[]', 'CONC-t10-dY');
  v_oa := conc.nuevo_producto(v_b, 10, 100, '[]', 'CONC-t10-oA');
  v_ob := conc.nuevo_producto(v_b, 10, 100, '[]', 'CONC-t10-oB');
  INSERT INTO public.movimientos_sucursal (sucursal_origen_id, sucursal_destino_id, estado, creado_por, stock_descontado, notas)
  VALUES (v_b, v_a, 'pendiente', conc.f('admin_b')::uuid, false, 'conc') RETURNING id INTO v_mov;
  INSERT INTO public.movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre, origen_costo_promedio)
  VALUES (v_mov, v_oa, 2, 'CONC-t10-oA', 60) RETURNING id INTO v_i1;
  INSERT INTO public.movimiento_sucursal_items (movimiento_id, producto_origen_id, cantidad, origen_nombre, origen_costo_promedio)
  VALUES (v_mov, v_ob, 2, 'CONC-t10-oB', 60) RETURNING id INTO v_i2;
  RETURN jsonb_build_object('suc', v_a, 'admin', conc.f('admin_a')::uuid, 'p1', conc.f('prev_a1')::uuid,
                            'cli1', conc.nuevo_cliente(v_a), 'dx', v_dx, 'dy', v_dy, 'oa', v_oa, 'ob', v_ob, 'mov', v_mov,
                            'res', jsonb_build_array(
                              jsonb_build_object('item_id', v_i1, 'accion', 'match_existente', 'producto_destino_id', v_dy),
                              jsonb_build_object('item_id', v_i2, 'accion', 'match_existente', 'producto_destino_id', v_dx)));
END
$$;
-- GO
-- ===== T13 (#1446, plan #1378 tarjeta 13): la edición que cambia el total contra un camino que toma otra boleta =====
-- Sucursal A. Ninguna variante confirma rendiciones: no gastan días (el tramo 5401 a 5800 queda reservado).
-- Un cliente con dos boletas de 100: X de ayer (creada primero, id menor) e Y de anteayer (id mayor), la que un
-- crédito paga primero (por fecha), y un crédito C de p_credito (de hoy). Con p_x_cobrada, X cobrada entera hoy con
-- un cobro de boleta (no a cuenta): bajarle el total lo recorta. Con p_y_menor, Y se crea primero (id menor que X):
-- el FIFO, que toma las boletas por id (454), toma Y y después X. Devuelve también la línea de X (para la salvedad).
CREATE OR REPLACE FUNCTION conc.t13_setup(p_x_cobrada boolean DEFAULT false, p_credito numeric DEFAULT 30,
                                          p_y_menor boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_x bigint; v_y bigint;
  v_r jsonb;
BEGIN
  IF p_y_menor THEN v_y := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 2); END IF;
  v_x := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 1);
  IF NOT p_y_menor THEN v_y := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 2); END IF;
  IF p_x_cobrada THEN
    v_r := conc.cobro(v_adm, v_suc, v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't13_setup cobro: %', v_r; END IF;
  END IF;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'cli', v_cli, 'x', v_x, 'y', v_y,
                            'xi', (SELECT min(id) FROM public.pedido_items WHERE pedido_id = v_x),
                            'c', conc.t10_credito(v_suc, v_cli, p_credito, conc.hoy(), v_adm),
                            'relleno', conc.f('relleno_' || v_suc)::bigint);
END
$$;
-- GO
-- '' si las boletas y el saldo del cliente cierran: ninguna boleta pagada de más, monto_pagado = sus pagos, y
-- clientes.saldo_cuenta = Σ (total − monto_pagado) − Σ créditos. Si no, el detalle.
CREATE OR REPLACE FUNCTION conc.t13_cierra(p_cli bigint) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT concat_ws(' ',
           CASE WHEN b.malas > 0 THEN 'boletas mal=' || b.malas END,
           CASE WHEN c.saldo_cuenta <> b.deuda - f.favor THEN format('saldo_cuenta=%s esperado=%s', c.saldo_cuenta, b.deuda - f.favor) END)
    FROM public.clientes c,
         -- Un vale blanco tiene monto_pagado = total y ningún pago, por diseño (317/318).
         LATERAL (SELECT count(*) FILTER (WHERE p.monto_pagado > p.total
                                            OR (p.tipo_factura IS DISTINCT FROM 'VB'
                                                AND p.monto_pagado <> COALESCE((SELECT sum(monto) FROM public.pagos WHERE pedido_id = p.id), 0))) AS malas,
                         COALESCE(sum(p.total - COALESCE(p.monto_pagado, 0)) FILTER (WHERE p.estado NOT IN ('cancelado', 'anulado')), 0) AS deuda
                    FROM public.pedidos p WHERE p.cliente_id = p_cli) b,
         LATERAL (SELECT COALESCE(sum(monto), 0) AS favor FROM public.pagos WHERE cliente_id = p_cli AND pedido_id IS NULL) f
   WHERE c.id = p_cli
$$;
-- GO
-- T13k/T13l: lo mismo que t13_setup, con el cliente habilitado para vale blanco: pasar X a VB le cambia el total (a
-- costo) por cambiar_tipo_factura_pedido.
DROP FUNCTION IF EXISTS conc.t13_vb_setup();
-- GO
CREATE OR REPLACE FUNCTION conc.t13_vb_setup(p_y_menor boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_c jsonb := conc.t13_setup(false, 30, p_y_menor);
BEGIN
  UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = (v_c->>'cli')::bigint;
  RETURN v_c;
END
$$;
-- GO
-- T13m: lo de t13_setup, más una boleta W del mismo cliente (de ayer, después de X: el crédito no la alcanza) en una
-- ruta R con Y, de un chofer nuevo y del día hoy - 5401 (no gasta días: no confirma rendiciones). Cobrar W toma W, R
-- y después el cliente; la edición de X llega a R por los recorridos de Y.
CREATE OR REPLACE FUNCTION conc.t13_ruta_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_c jsonb := conc.t13_setup(false, 30, false);
  v_suc bigint := (v_c->>'suc')::bigint;
  v_adm uuid := (v_c->>'admin')::uuid;
  v_enc uuid := conc.f('enc_a')::uuid;
  v_t uuid := conc.alta_usuario('t13-' || gen_random_uuid() || '@conc.test', 'transportista', v_suc);
  v_w bigint := conc.pedido_de(v_adm, v_suc, (v_c->>'cli')::bigint, 100, conc.hoy() - 1);
  v_r bigint;
BEGIN
  PERFORM conc.como(v_enc, v_suc);
  v_r := public.aplicar_orden_ruta(v_t, jsonb_build_array(jsonb_build_object('pedido_id', (v_c->>'y')::bigint, 'orden_entrega', 1),
                                                          jsonb_build_object('pedido_id', v_w, 'orden_entrega', 2)),
                                   NULL, NULL, NULL, conc.hoy() - 5401);
  RESET ROLE;
  RETURN v_c || jsonb_build_object('w', v_w, 'r', v_r);
END
$$;
-- GO
-- ===== T14 (#1460, plan #1378 tarjeta 14): stock y promos contra el orden global de locks =====
-- Productos (con sus contenedores) por id, y las promos después, por id. Sucursal A. No confirman rendiciones ni gastan
-- días: todo es de hoy.

-- C2 y C5: una promo con auto-ajuste cuyo contenedor C es el menor de todos (C < A < B < S). Se compra A o B (10 dan
-- 2 de regalo S, que no mueve stock) y cada 2 de regalo sale 1 de C. X es una venta de A con su regalo, a cli1. La
-- barra queda en `p_barra`: lo que pide ajustar_stock_promocion_completo, o un cambio de factor que cierre un bloque.
CREATE OR REPLACE FUNCTION conc.t14_setup(p_barra int DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli1 bigint := conc.nuevo_cliente(v_suc);
  v_c bigint := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-t14-contenedor');
  v_a bigint := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-t14-A');
  v_b bigint := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-t14-B');
  v_s bigint := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-t14-sabor');
  v_promo bigint; v_x bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                                  ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
  VALUES ('CONC t14', 'bonificacion', conc.hoy() - 1, v_suc, false, v_s, true, v_c, 2, 1)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_a, v_suc), (v_promo, v_b, v_suc);
  v_x := conc.venta(v_adm, v_suc, v_cli1, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 100),
    jsonb_build_object('producto_id', v_s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo)));
  UPDATE public.promociones SET usos_pendientes = p_barra WHERE id = v_promo;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'admin2', conc.f('admin_a2')::uuid,
                            'cli1', v_cli1, 'cli2', conc.nuevo_cliente(v_suc),
                            'pc', v_c, 'pa', v_a, 'pb', v_b, 'ps', v_s, 'promo', v_promo, 'x', v_x);
END
$$;
-- GO
-- C3: lo de c12k_setup (dos promos comunes P1 < P2 sin productos en común entre las dos ventas), más una boleta X de
-- cli1. Con `p_x_con_p2`, X ya lleva a2 con el regalo de P2; si no, sólo a1.
CREATE OR REPLACE FUNCTION conc.t14k_setup(p_x_con_p2 boolean DEFAULT true) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_c jsonb := conc.c12k_setup();
  v_x bigint;
BEGIN
  v_x := conc.venta((v_c->>'admin')::uuid, (v_c->>'suc')::bigint, (v_c->>'cli1')::bigint,
    CASE WHEN p_x_con_p2 THEN jsonb_build_array(
           jsonb_build_object('producto_id', (v_c->>'a2')::bigint, 'cantidad', 10, 'precio_unitario', 100),
           jsonb_build_object('producto_id', (v_c->>'r2a')::bigint, 'cantidad', 2, 'precio_unitario', 0,
                              'es_bonificacion', true, 'promocion_id', (v_c->>'promo2')::bigint))
         ELSE jsonb_build_array(jsonb_build_object('producto_id', (v_c->>'a1')::bigint, 'cantidad', 10, 'precio_unitario', 100)) END);
  RETURN v_c || jsonb_build_object('x', v_x);
END
$$;
-- GO
-- C4: una promo común P (5 dan 1 de regalo) sin contenedor, como 5 de las 6 de prod. X (cli) compra 10 de A con 2 de
-- regalo s1, y después la promo cambia de tipo (#1324: se puede con pedidos abiertos, y X sigue con el modo de su
-- foto). La venta de B con 1 de regalo s2 al mismo cliente no comparte productos con X.
CREATE OR REPLACE FUNCTION conc.t14m_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_a bigint := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-t14m-A');
  v_b bigint := conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-t14m-B');
  v_s1 bigint := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-t14m-s1');
  v_s2 bigint := conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-t14m-s2');
  v_promo bigint; v_x bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id, ajuste_automatico)
  VALUES ('CONC t14m', 'bonificacion', conc.hoy() - 1, v_suc, true, v_s1, false) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 5, v_suc), (v_promo, 'cantidad_bonificacion', 1, v_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_a, v_suc), (v_promo, v_b, v_suc);
  v_x := conc.venta(v_adm, v_suc, v_cli, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 100),
    jsonb_build_object('producto_id', v_s1, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo)));
  UPDATE public.promociones SET regalo_mueve_stock = false WHERE id = v_promo;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'admin2', conc.f('admin_a2')::uuid, 'cli', v_cli,
                            'pa', v_a, 'pb', v_b, 's1', v_s1, 's2', v_s2, 'promo', v_promo, 'x', v_x,
                            'xi', (SELECT id FROM public.pedido_items WHERE pedido_id = v_x AND producto_id = v_a));
END
$$;
-- GO
-- C8: dos productos A < B a $100.
CREATE OR REPLACE FUNCTION conc.t14p_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
BEGIN
  RETURN jsonb_build_object('suc', v_suc, 'admin', conc.f('admin_a')::uuid, 'admin2', conc.f('admin_a2')::uuid,
                            'cli', conc.nuevo_cliente(v_suc),
                            'pa', conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-t14p-A'),
                            'pb', conc.nuevo_producto(v_suc, 100, 100, '[]', 'CONC-t14p-B'));
END
$$;
-- GO
-- actualizar_precios_masivo atrapa el error de cada producto (EXCEPTION WHEN OTHERS) y lo devuelve en `errores`: un
-- 40P01 ahí no aborta la transacción, deja ese producto con el precio viejo. Se lo vuelve a tirar con su código.
CREATE OR REPLACE FUNCTION conc.t14_exigir_masivo(r jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RAISE EXCEPTION '%', r->>'errores'
      USING ERRCODE = CASE WHEN r->>'errores' LIKE '%deadlock detected%' THEN '40P01' ELSE 'P0001' END;
  END IF;
  RETURN r;
END
$$;
-- GO
GRANT EXECUTE ON FUNCTION conc.t14_exigir_masivo(jsonb) TO authenticated;
-- GO
-- C4, los otros caminos que hacen UPDATE de la cantidad de un regalo (anular una salvedad, sustituir y dividir el
-- regalo): lo de t14m_setup, con X de 12 de A (12 y 10 dan los mismos 2 de regalo) y una salvedad de 2 de A ya
-- registrada antes del cambio de tipo, que anular_salvedad puede deshacer sin tocar la promo. s3 es otro sabor para
-- sustituir o repartir el regalo.
CREATE OR REPLACE FUNCTION conc.t14n_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_c jsonb := conc.t14m_setup();
  v_suc bigint := (v_c->>'suc')::bigint;
  v_adm uuid := (v_c->>'admin')::uuid;
  v_x bigint := (v_c->>'x')::bigint;
  v_r jsonb;
BEGIN
  -- t14m_setup ya cambió el tipo: se vuelve, se agrega, se registra la salvedad y se cambia de nuevo.
  UPDATE public.promociones SET regalo_mueve_stock = true WHERE id = (v_c->>'promo')::bigint;
  PERFORM conc.como(v_adm, v_suc);
  v_r := public.actualizar_pedido_items(v_x, jsonb_build_array(
    jsonb_build_object('producto_id', (v_c->>'pa')::bigint, 'cantidad', 12, 'precio_unitario', 100),
    jsonb_build_object('producto_id', (v_c->>'s1')::bigint, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true,
                       'promocion_id', (v_c->>'promo')::bigint)), v_adm, NULL, NULL);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't14n_setup: edición %', v_r; END IF;
  v_r := public.registrar_salvedad(v_x, (SELECT id FROM public.pedido_items WHERE pedido_id = v_x AND producto_id = (v_c->>'pa')::bigint),
                                   2, 'cliente_rechaza', 'conc', NULL, true, NULL);
  RESET ROLE;
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't14n_setup: salvedad %', v_r; END IF;
  UPDATE public.promociones SET regalo_mueve_stock = false WHERE id = (v_c->>'promo')::bigint;
  RETURN v_c || jsonb_build_object(
    'sv', (SELECT max(id) FROM public.salvedades_items WHERE pedido_id = v_x),
    'xr', (SELECT id FROM public.pedido_items WHERE pedido_id = v_x AND es_bonificacion),
    's3', conc.nuevo_producto(v_suc, 20, 100, '[]', 'CONC-t14n-s3'));
END
$$;
-- GO
-- ===== T15 (#1460 C1, C6 y C7, plan #1378 tarjeta 15): cobros, cliente y rutas =====
-- Sucursal A. Ninguna variante confirma rendiciones; las rutas son de un chofer nuevo por ronda y del día hoy - 6201
-- (el tramo 6201 a 6600 queda reservado): no gastan días.
--
-- C1: dos clientes. C2 tiene W (de anteayer, 100 sin cobrar) e Y (de ayer, 100 cobrada entera); C1 tiene X (de ayer,
-- 100 cobrada entera). Pasar X a C2 con 'pedido_nuevo' y un total de 80 deja 20 de excedente, que
-- aplicar_credito_cliente(C2) lleva a W. Editar Y toma W e Y por id (_edicion_bloquea_boletas) y después C2.
CREATE OR REPLACE FUNCTION conc.t15_cambio_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_c1 bigint := conc.nuevo_cliente(v_suc);
  v_c2 bigint := conc.nuevo_cliente(v_suc);
  v_w bigint; v_y bigint; v_x bigint;
  v_r jsonb;
BEGIN
  v_w := conc.pedido_de(v_adm, v_suc, v_c2, 100, conc.hoy() - 2);
  v_y := conc.pedido_de(v_adm, v_suc, v_c2, 100, conc.hoy() - 1);
  v_x := conc.pedido_de(v_adm, v_suc, v_c1, 100, conc.hoy() - 1);
  v_r := conc.cobro(v_adm, v_suc, v_y, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't15_cambio_setup cobro Y: %', v_r; END IF;
  v_r := conc.cobro(v_adm, v_suc, v_x, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't15_cambio_setup cobro X: %', v_r; END IF;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'c1', v_c1, 'c2', v_c2, 'w', v_w, 'y', v_y, 'x', v_x,
                            'yi', (SELECT min(id) FROM public.pedido_items WHERE pedido_id = v_y),
                            'relleno', conc.f('relleno_' || v_suc)::bigint);
END
$$;
-- GO
-- C6: un cliente con Y (de anteayer, 100 cobrada en un pago P1) y X (de ayer, 100 sin cobrar), las dos en una ruta R de
-- un chofer nuevo. El DELETE REST de P1 toma Y (la policy), P1, y por los triggers la ruta y el cliente; editar X toma
-- X, la ruta y el cliente.
CREATE OR REPLACE FUNCTION conc.t15_borrar_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_enc uuid := conc.f('enc_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_t uuid := conc.alta_usuario('t15-' || gen_random_uuid() || '@conc.test', 'transportista', v_suc);
  v_y bigint; v_x bigint; v_rec bigint;
  v_r jsonb;
BEGIN
  v_y := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 2);
  v_x := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 1);
  v_r := conc.cobro(v_adm, v_suc, v_y, '[{"monto":100,"forma_pago":"efectivo"}]'::jsonb);
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN RAISE EXCEPTION 't15_borrar_setup cobro: %', v_r; END IF;
  PERFORM conc.como(v_enc, v_suc);
  v_rec := public.aplicar_orden_ruta(v_t, jsonb_build_array(jsonb_build_object('pedido_id', v_y, 'orden_entrega', 1),
                                                            jsonb_build_object('pedido_id', v_x, 'orden_entrega', 2)),
                                     NULL, NULL, NULL, conc.hoy() - 6201);
  RESET ROLE;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'cli', v_cli, 'y', v_y, 'x', v_x, 'r', v_rec,
                            'p1', (SELECT min(id) FROM public.pagos WHERE pedido_id = v_y),
                            'relleno', conc.f('relleno_' || v_suc)::bigint);
END
$$;
-- GO
-- C7: un cliente con Z (de hace tres días, 100 sin cobrar y sin ruta), Y (de anteayer) y X (de ayer), de 100 sin cobrar
-- y las dos en una ruta R de un chofer nuevo, y un crédito C de 30 (de hoy). El crédito alcanza sólo a Z (la más vieja),
-- así que editar X toma Z, X, la ruta de X y el crédito, y no toma Y. Imputar C a Y toma Y, C y por los triggers la ruta.
CREATE OR REPLACE FUNCTION conc.t15_imputar_setup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_enc uuid := conc.f('enc_a')::uuid;
  v_cli bigint := conc.nuevo_cliente(v_suc);
  v_t uuid := conc.alta_usuario('t15-' || gen_random_uuid() || '@conc.test', 'transportista', v_suc);
  v_z bigint; v_y bigint; v_x bigint; v_rec bigint;
BEGIN
  v_z := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 3);
  v_y := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 2);
  v_x := conc.pedido_de(v_adm, v_suc, v_cli, 100, conc.hoy() - 1);
  PERFORM conc.como(v_enc, v_suc);
  v_rec := public.aplicar_orden_ruta(v_t, jsonb_build_array(jsonb_build_object('pedido_id', v_y, 'orden_entrega', 1),
                                                            jsonb_build_object('pedido_id', v_x, 'orden_entrega', 2)),
                                     NULL, NULL, NULL, conc.hoy() - 6201);
  RESET ROLE;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'cli', v_cli, 'z', v_z, 'y', v_y, 'x', v_x, 'r', v_rec,
                            'c', conc.t10_credito(v_suc, v_cli, 30, conc.hoy(), v_adm),
                            'relleno', conc.f('relleno_' || v_suc)::bigint);
END
$$;
-- GO
-- ===== A4 (#1471, plan #1477 tarjeta 4): notas de crédito de compra contra una venta =====
-- Sucursal A. Ninguna variante confirma rendiciones: no gastan días (el tramo 7401 a 7800 queda reservado).
-- Una compra recibida, sin bonificación y a costo 100 con IVA gravado al 21 %, así que la nota de una unidad acredita
-- 100 + 21 y la base la recalcula igual que el front. Una unidad del producto A y una del B por ronda.
--   p_lotes = true  (A4a): A con la bolsa en 0 y dos lotes de la compra (5 + 5, el primero vence antes): el stock de A
--                   es lo que hay en los lotes, así que la venta, con el producto ya tomado, baja al lote (FEFO) por
--                   trg_lotes_sincronizar. Devuelve el lote (el primero) que se le devuelve al proveedor.
--   p_lotes = false (A4b): A y B con 10 de stock en la bolsa y la compra con 10 de cada uno (sin lotes).
CREATE OR REPLACE FUNCTION conc.a4_setup(p_lotes boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suc bigint := conc.f('suc_a')::bigint;
  v_adm uuid := conc.f('admin_a')::uuid;
  v_pa bigint; v_pb bigint; v_compra bigint; v_lote bigint;
  v_n int := CASE WHEN p_lotes THEN 1 ELSE 2 END;
BEGIN
  IF p_lotes THEN
    v_pa := conc.nuevo_producto(v_suc, 0, 100, '[{"dias":30,"cantidad":5},{"dias":60,"cantidad":5}]'::jsonb, 'CONC-a4-A');
  ELSE
    v_pa := conc.nuevo_producto(v_suc, 10, 100, '[]'::jsonb, 'CONC-a4-A');
    v_pb := conc.nuevo_producto(v_suc, 10, 100, '[]'::jsonb, 'CONC-a4-B');
  END IF;
  INSERT INTO public.compras (proveedor_nombre, numero_factura, fecha_compra, subtotal, iva, total, forma_pago, estado,
                              usuario_id, tipo_factura, sucursal_id)
  VALUES ('CONC-prov', 'conc-a4-' || gen_random_uuid(), conc.hoy(), 1000 * v_n, 210 * v_n, 1210 * v_n, 'cuenta_corriente',
          'recibida', v_adm, 'FC', v_suc)
  RETURNING id INTO v_compra;
  INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo,
                                   bonificacion, sucursal_id, porcentaje_iva, condicion_iva)
  VALUES (v_compra, v_pa, 10, 100, 1000, 0, 10, 0, v_suc, 21, 'gravado');
  IF NOT p_lotes THEN
    INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo,
                                     bonificacion, sucursal_id, porcentaje_iva, condicion_iva)
    VALUES (v_compra, v_pb, 10, 100, 1000, 0, 10, 0, v_suc, 21, 'gravado');
  ELSE
    UPDATE public.producto_lotes SET compra_id = v_compra WHERE producto_id = v_pa;
    SELECT id INTO v_lote FROM public.producto_lotes WHERE producto_id = v_pa ORDER BY fecha_vencimiento, id LIMIT 1;
  END IF;
  RETURN jsonb_build_object('suc', v_suc, 'admin', v_adm, 'p1', conc.f('prev_a1')::uuid, 'cli1', conc.nuevo_cliente(v_suc),
                            'pa', v_pa, 'pb', COALESCE(v_pb, v_pa), 'compra', v_compra, 'lote', v_lote);
END
$$;
