-- Medición de tiempos de la tarjeta B16 (ola 2 de #1603), H1 de su revisión: con una nota de crédito en
-- el lote, la v1 de _comision_lineas armaba un nested loop que reordenaba sus renglones una vez por renglón,
-- y /comisiones de un mes daba statement timeout.
--
-- No es un ensayo (por eso no se llama test-*.sql y el CI no lo corre): mide, no afirma.
--
-- Corre con psql (no es un DO: el statement_timeout se mide por sentencia) y no deja rastro: todo va en una
-- transacción que termina en ROLLBACK, y cada sentencia en su savepoint (ON_ERROR_ROLLBACK), así que un
-- timeout no corta el resto.
--
-- Datos: una sucursal nueva con 2.000 boletas entregadas del mes pasado (3 renglones cada una, 3
-- vendedores, 20 productos), una meta de facturación del mes por vendedor y 30 notas vigentes sobre
-- renglones de esas boletas, con un motivo que le descuenta al vendedor (cliente_rechaza, v3): sin
-- liquidar, restan de la comisión como en la v2. Todo determinístico.
--
-- Mide: calcular_comisiones del mes como authenticated (admin) con el statement_timeout de ese rol (8 s),
-- _comision_lineas de las 2.000 boletas, el gerencial, rendimiento, avance de metas y los dos del bot. Y
-- escribe el md5 del conjunto de filas de _comision_lineas en una forma que no depende de los ids (puesto
-- de la boleta, nombre de producto y de vendedor), para comparar entre bases con y sin la migración.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/tiempos-nc-mes-de-la-boleta-ola2-1603.sql

\set ON_ERROR_ROLLBACK on
\pset footer off
BEGIN;

CREATE TEMP TABLE b16p (k text PRIMARY KEY, v text);

DO $datos$
DECLARE
  v_s    bigint;
  v_adm  uuid := '00000000-0000-0000-0000-0000000004e7';
  v_ven  uuid[] := '{}';
  v_c    bigint[] := '{}';
  v_prod bigint[] := '{}';
  v_mes  date := (date_trunc('month', public._tablero_hoy()) - interval '1 month')::date;
  v_x    bigint;
  v_p    bigint;
  v_f    date;
  v_nc   bigint;
  v_u    uuid;
  k      int;
BEGIN
  INSERT INTO sucursales (nombre) VALUES ('B16 rendimiento') RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_adm, v_s) ON CONFLICT DO NOTHING;
  FOR k IN 1..3 LOOP
    v_u := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b16p-' || v_u || '@ensayo.invalid',
              jsonb_build_object('rol', 'preventista', 'sucursal_id', v_s), jsonb_build_object('nombre', 'B16p vendedor ' || k),
              now(), now());
    v_ven := v_ven || v_u;
  END LOOP;
  FOR k IN 1..40 LOOP
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
      VALUES ('B16p c' || k, 'B16p c' || k, 'x', v_s) RETURNING id INTO v_x;
    v_c := v_c || v_x;
  END LOOP;
  FOR k IN 1..20 LOOP
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
      VALUES ('B16p P' || lpad(k::text, 2, '0'), 10 * k, 1000000, 5 * k, v_s) RETURNING id INTO v_x;
    v_prod := v_prod || v_x;
  END LOOP;
  FOR k IN 1..2000 LOOP
    v_f := v_mes + (k % 28);
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal, retiro_deposito,
                         tipo_factura)
      VALUES (v_c[1 + k % 40], v_s, v_ven[1 + k % 3], 0, 'entregado', v_f,
              (v_f + time '12:00') AT TIME ZONE 'America/Argentina/Buenos_Aires', 'app', true, 'ZZ')
      RETURNING id INTO v_p;
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,
                              costo_unitario_al_crear, origen_precio)
      SELECT v_p, v_prod[1 + (k + j) % 20], 1 + j, 10 * (1 + (k + j) % 20), (1 + j) * 10 * (1 + (k + j) % 20), v_s, 5,
             'lista'
        FROM generate_series(0, 2) j;
    UPDATE pedidos SET total = (SELECT sum(subtotal) FROM pedido_items WHERE pedido_id = v_p) WHERE id = v_p;
  END LOOP;
  FOR k IN 1..3 LOOP
    INSERT INTO metas_preventista (sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta, valor_objetivo)
      VALUES (v_s, v_ven[k], v_mes, (v_mes + interval '1 month - 1 day')::date, 'facturacion', 10000000);
  END LOOP;
  -- 30 notas vigentes, una cada 66 boletas, por una unidad del último renglón (como las deja la RPC).
  FOR k IN 1..30 LOOP
    SELECT id INTO v_p FROM pedidos WHERE sucursal_id = v_s ORDER BY id OFFSET k * 66 - 1 LIMIT 1;
    INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
      SELECT v_s, p.cliente_id, p.id, p.fecha, 'cliente_rechaza', pi.precio_unitario, v_adm, pi.precio_unitario, 0
        FROM pedidos p
        JOIN LATERAL (SELECT * FROM pedido_items x WHERE x.pedido_id = p.id ORDER BY x.id DESC LIMIT 1) pi ON true
       WHERE p.id = v_p
      RETURNING id INTO v_nc;
    INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad,
                                          precio_unitario, subtotal)
      SELECT v_nc, v_s, pi.id, pi.producto_id, 1, pi.precio_unitario, pi.precio_unitario
        FROM pedido_items pi WHERE pi.pedido_id = v_p ORDER BY pi.id DESC LIMIT 1;
  END LOOP;
  INSERT INTO b16p VALUES ('s', v_s::text), ('v1', v_ven[1]::text), ('desde', v_mes::text),
                          ('hasta', ((v_mes + interval '1 month - 1 day')::date)::text);
END
$datos$;

ANALYZE pedidos;
ANALYZE pedido_items;
ANALYZE notas_credito_venta;
ANALYZE nota_credito_venta_items;

SELECT (SELECT count(*) FROM pedidos WHERE sucursal_id = (SELECT v::bigint FROM b16p WHERE k = 's')) AS boletas,
       (SELECT count(*) FROM notas_credito_venta WHERE sucursal_id = (SELECT v::bigint FROM b16p WHERE k = 's')) AS notas,
       (SELECT CASE WHEN prosrc LIKE '%_nc_resta_comision%' THEN 'v3'
                    WHEN prosrc LIKE '%nc_clave AS MATERIALIZED%' THEN 'v2'
                    WHEN prosrc LIKE '%nc_clave%' THEN 'v1' ELSE 'sin B16' END
          FROM pg_proc WHERE oid = 'public._comision_lineas(bigint[])'::regprocedure) AS version;

-- El resultado, sin ids: puesto de la boleta, vendedor, producto, combo, origen, base y %.
SELECT 'md5 _comision_lineas' AS que, md5(string_agg(f, E'\n' ORDER BY f)) AS md5, count(*) AS filas,
       round(sum(base), 2) AS base_total
  FROM (SELECT concat_ws('|', r.puesto, pf.nombre, prod.nombre, l.combo_id, l.origen_precio, round(l.base, 6), l.pct) AS f,
               l.base
          FROM public._comision_lineas(ARRAY(SELECT id FROM pedidos WHERE sucursal_id = (SELECT v::bigint FROM b16p WHERE k = 's'))) l
          JOIN (SELECT id, row_number() OVER (ORDER BY id) AS puesto FROM pedidos
                 WHERE sucursal_id = (SELECT v::bigint FROM b16p WHERE k = 's')) r ON r.id = l.pedido_id
          LEFT JOIN perfiles pf ON pf.id = l.usuario_id
          LEFT JOIN productos prod ON prod.id = l.producto_id) x;

\timing on
SELECT '_comision_lineas de las 2000 boletas' AS que, count(*)
  FROM public._comision_lineas(ARRAY(SELECT id FROM pedidos WHERE sucursal_id = (SELECT v::bigint FROM b16p WHERE k = 's')));
SELECT 'reporte_gerencial del mes' AS que,
       (public.reporte_gerencial((SELECT v::bigint FROM b16p WHERE k = 's'), (SELECT v::date FROM b16p WHERE k = 'desde'),
                                 (SELECT v::date FROM b16p WHERE k = 'hasta')))#>>'{kpis,base_comision}' AS base_comision;
SELECT 'bot_ventas_periodo del mes' AS que,
       (public.bot_ventas_periodo((SELECT v::date FROM b16p WHERE k = 'desde'), (SELECT v::date FROM b16p WHERE k = 'hasta'),
                                  (SELECT v::bigint FROM b16p WHERE k = 's'), 10))->>'total_ventas' AS total;
SELECT 'bot_mis_ventas del mes' AS que,
       (public.bot_mis_ventas((SELECT v::uuid FROM b16p WHERE k = 'v1'), (SELECT v::date FROM b16p WHERE k = 'desde'),
                              (SELECT v::date FROM b16p WHERE k = 'hasta'), (SELECT v::bigint FROM b16p WHERE k = 's'), 10))->>'total_ventas' AS total;
SELECT 'avance_metas_preventista' AS que,
       length(public.avance_metas_preventista((SELECT v::uuid FROM b16p WHERE k = 'v1'), (SELECT v::date FROM b16p WHERE k = 'desde'))::text);
\timing off

-- Como el front: authenticated (el admin, parado en la sucursal), con el statement_timeout de ese rol.
SELECT count(*) AS claims FROM (VALUES
  (set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000004e7', 'role', 'authenticated')::text, true)),
  (set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000004e7', true)),
  (set_config('request.headers', json_build_object('x-sucursal-id', (SELECT v FROM b16p WHERE k = 's'))::text, true)),
  (set_config('b16p.s', (SELECT v FROM b16p WHERE k = 's'), true)),
  (set_config('b16p.desde', (SELECT v FROM b16p WHERE k = 'desde'), true)),
  (set_config('b16p.hasta', (SELECT v FROM b16p WHERE k = 'hasta'), true))) c(x);
SET LOCAL ROLE authenticated;
SELECT 'statement_timeout de authenticated' AS que,
       (SELECT array_to_string(rolconfig, ',') FROM pg_roles WHERE rolname = 'authenticated') AS rolconfig;
SET LOCAL statement_timeout = '8s';
\timing on
SELECT 'calcular_comisiones del mes como authenticated' AS que,
       (public.calcular_comisiones(current_setting('b16p.desde')::date, current_setting('b16p.hasta')::date,
                                   ARRAY[current_setting('b16p.s')::bigint]))->'totales' AS totales;
SELECT 'rendimiento_preventistas del mes como authenticated' AS que,
       length(public.rendimiento_preventistas(current_setting('b16p.s')::bigint, current_setting('b16p.desde')::date)::text);
\timing off
RESET ROLE;

ROLLBACK;
