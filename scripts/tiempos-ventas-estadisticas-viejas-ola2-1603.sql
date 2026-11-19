-- Medición de tiempos de la tarjeta C5 (tanda 5 de la ola 2, #1603; N8 de la revisión de B22): el gerencial,
-- Rendimiento, tablero_categorias y bot_ventas_periodo con 8.000 boletas del mes de 3 renglones y 500 notas
-- de crédito, en las tres situaciones de estadísticas:
--   1 · sin ANALYZE (la base como viene);
--   2 · ANALYZE ANTES de cargar los datos: el planner cree que pedidos, pedido_items y clientes tienen las
--       filas de antes (las «estadísticas viejas» que deja un día de mucha carga hasta que pasa autovacuum);
--   3 · ANALYZE de todo, con los datos cargados.
-- En la 530, en la situación 2, _tablero_ventas y _ventas_nc se planean como nested loops que recorren
-- clientes, pedidos y pedido_items enteros por cada fila, y los cuatro reportes pasan los 8 s de la API.
-- No se cambió código (decisión de la coordinadora, 19/11): la receta que lo evita (buscar por índice
-- fila por fila) empeora el caso normal, y en producción las estadísticas están al día (autoanalyze).
-- La regla es correr ANALYZE después de una carga masiva (CLAUDE.md, «Correr y verificar»).
-- Ojo: la situación 2 depende de cuántas páginas muertas tengan las tablas (el planner estima por
-- páginas): corré el guion dos veces seguidas sobre la misma base para verla.
--
-- No es un ensayo (no se llama test-*.sql y el CI no lo corre): mide, no afirma. Además de los tiempos,
-- compara en cada situación _tablero_ventas y _ventas_nc con los cuerpos de la 530 (copiados acá) sobre
-- los mismos datos: «filas distintas» tiene que dar 0. Cada situación es una transacción que termina en
-- ROLLBACK; cada sentencia en su savepoint (ON_ERROR_ROLLBACK), así un timeout no corta el resto. El
-- gerencial y Rendimiento corren como el admin (authenticated), tablero y bot como service_role, con el
-- statement_timeout de la API (8 s). Corre ANALYZE sobre la base: usala en una base descartable.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/tiempos-ventas-estadisticas-viejas-ola2-1603.sql

\set ON_ERROR_ROLLBACK on
\pset footer off

-- Los datos, en una función de la sesión: cada situación la llama dentro de su transacción.
CREATE FUNCTION pg_temp.c5_datos() RETURNS void LANGUAGE plpgsql AS $d$
DECLARE
  v_s bigint; v_c bigint[] := '{}'; v_p bigint[] := '{}'; v_v uuid[] := '{}'; v_u uuid; v_x bigint; v_ped bigint;
  v_it bigint; v_nc bigint; k int; j int; v_ini date := date_trunc('month', public._tablero_hoy())::date;
BEGIN
  CREATE TEMP TABLE c5t (k text PRIMARY KEY, v text) ON COMMIT DROP;
  INSERT INTO sucursales (nombre) VALUES ('C5 tiempos') RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES ('00000000-0000-0000-0000-0000000004e7', v_s) ON CONFLICT DO NOTHING;
  FOR k IN 1..5 LOOP
    v_u := gen_random_uuid();
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      VALUES (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c5t-' || v_u || '@ensayo.invalid',
              jsonb_build_object('rol', 'preventista', 'sucursal_id', v_s), '{"nombre":"C5t"}', now(), now());
    v_v := v_v || v_u;
  END LOOP;
  FOR k IN 1..200 LOOP
    INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id) VALUES ('C5t ' || k, 'C5t ' || k, 'x', v_s) RETURNING id INTO v_x;
    v_c := v_c || v_x;
  END LOOP;
  FOR k IN 1..30 LOOP
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
      VALUES ('C5t p' || k, 1000, 100000, 700, v_s, 'C5t rubro ' || (k % 5)) RETURNING id INTO v_x;
    v_p := v_p || v_x;
  END LOOP;
  FOR k IN 1..8000 LOOP
    INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, fecha_entrega, canal, retiro_deposito, tipo_factura)
      VALUES (v_c[1 + k % 200], v_s, v_v[1 + k % 5], 3000, 'entregado', v_ini + (k % 15), now(), 'app', true, 'ZZ')
      RETURNING id INTO v_ped;
    FOR j IN 0..2 LOOP
      INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
        VALUES (v_ped, v_p[1 + (k + j) % 30], 1, 1000, 1000, v_s, 700) RETURNING id INTO v_it;
    END LOOP;
    IF k % 16 = 0 THEN
      INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, fecha, motivo, total, usuario_id, neto, iva)
        VALUES (v_s, v_c[1 + k % 200], v_ped, v_ini, CASE WHEN k % 32 = 0 THEN 'cliente_rechaza' ELSE 'otro' END, 1000,
                '00000000-0000-0000-0000-0000000004e7', 1000, 0) RETURNING id INTO v_nc;
      INSERT INTO nota_credito_venta_items (nota_credito_id, sucursal_id, pedido_item_id, producto_id, cantidad, precio_unitario, subtotal)
        VALUES (v_nc, v_s, v_it, v_p[1 + (k + 2) % 30], 1, 1000, 1000);
      IF k % 32 = 0 THEN
        UPDATE nota_credito_venta_items SET lotes_devueltos = '[]' WHERE nota_credito_id = v_nc;
      END IF;
    END IF;
  END LOOP;
  INSERT INTO c5t VALUES ('s', v_s::text), ('ini', v_ini::text), ('fin', (v_ini + 14)::text);
END
$d$;

-- Las filas de _tablero_ventas y _ventas_nc que difieren de los cuerpos de la 530 (0 = las mismas).
CREATE FUNCTION pg_temp.c5_distintas(p_s bigint, p_ini date, p_fin date) RETURNS TABLE(que text, filas bigint)
LANGUAGE sql AS $f$
  WITH tv AS (SELECT * FROM public._tablero_ventas(ARRAY[p_s], p_ini, p_fin)),
  tv530 AS (
    SELECT pe.id, pe.cliente_id, pe.fecha, GREATEST(pe.total - pe.cargo_envio, 0) AS total, pe.sucursal_id, c.zona_id
      FROM pedidos pe LEFT JOIN clientes c ON c.id = pe.cliente_id
     WHERE pe.estado = 'entregado' AND COALESCE(pe.canal, 'app') <> 'cambio' AND pe.tipo_factura IS DISTINCT FROM 'VB'
       AND pe.fecha BETWEEN p_ini AND p_fin AND pe.sucursal_id = ANY(ARRAY[p_s])),
  nc AS (SELECT * FROM public._ventas_nc(ARRAY[p_s], p_ini, p_fin)),
  nc530 AS (
    SELECT n.id, n.fecha, n.sucursal_id, n.pedido_id, n.cliente_id, c.zona_id, pe.usuario_id,
           COALESCE(pe.tipo_factura, 'ZZ')::text, i.pedido_item_id, i.producto_id, i.cantidad, i.subtotal,
           i.subtotal * n.iva / n.total,
           CASE WHEN pi.id IS NOT NULL AND i.subtotal = i.cantidad * pi.precio_unitario
                THEN i.cantidad * COALESCE(pi.ingreso_real_unitario,
                                           CASE WHEN pe.tipo_factura = 'FC' THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                                ELSE pi.precio_unitario END)
                WHEN pi.id IS NOT NULL AND pi.precio_unitario > 0
                THEN i.subtotal - round(i.subtotal * (pi.precio_unitario
                                        - COALESCE(pi.ingreso_real_unitario,
                                                   CASE WHEN pe.tipo_factura = 'FC' THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                                                        ELSE pi.precio_unitario END)) / pi.precio_unitario, 2)
                ELSE i.subtotal * CASE WHEN pe.tipo_factura = 'FC' THEN n.neto ELSE n.total END / n.total END,
           pi.costo_unitario_al_crear,
           CASE WHEN i.lotes_devueltos IS NOT NULL OR i.merma_id IS NOT NULL THEN i.cantidad ELSE 0 END
      FROM notas_credito_venta n
      JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
      JOIN pedidos pe ON pe.id = n.pedido_id
      LEFT JOIN pedido_items pi ON pi.id = i.pedido_item_id
      LEFT JOIN clientes c ON c.id = n.cliente_id
     WHERE NOT n.anulada AND n.total > 0 AND n.sucursal_id = ANY(ARRAY[p_s]) AND n.fecha BETWEEN p_ini AND p_fin
       AND pe.estado = 'entregado' AND COALESCE(pe.canal, 'app') <> 'cambio' AND pe.tipo_factura IS DISTINCT FROM 'VB')
  SELECT '_tablero_ventas', (SELECT count(*) FROM ((SELECT * FROM tv EXCEPT ALL SELECT * FROM tv530)
                                                   UNION ALL (SELECT * FROM tv530 EXCEPT ALL SELECT * FROM tv)) d)
  UNION ALL
  SELECT '_ventas_nc', (SELECT count(*) FROM ((SELECT * FROM nc EXCEPT ALL SELECT * FROM nc530)
                                              UNION ALL (SELECT * FROM nc530 EXCEPT ALL SELECT * FROM nc)) d)
  UNION ALL
  SELECT 'filas (tablero / notas)', (SELECT count(*) FROM tv) * 100000 + (SELECT count(*) FROM nc);
$f$;

\echo '##### SITUACIÓN 1: sin ANALYZE'
BEGIN;
SELECT pg_temp.c5_datos();
SELECT v AS s FROM c5t WHERE k = 's' \gset
SELECT v AS ini FROM c5t WHERE k = 'ini' \gset
SELECT v AS fin FROM c5t WHERE k = 'fin' \gset
SELECT * FROM pg_temp.c5_distintas(:s, :'ini', :'fin');
SELECT set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000004e7', 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', :'s')::text, true) \g /dev/null
SET LOCAL statement_timeout = '8s';
SET LOCAL ROLE authenticated;
\timing on
SELECT 'gerencial' AS f, length(public.reporte_gerencial(:s, :'ini', :'fin')::text);
SELECT 'rendimiento' AS f, length(public.rendimiento_preventistas(:s, :'ini')::text);
\timing off
RESET ROLE;
SET LOCAL ROLE service_role;
\timing on
SELECT 'tablero_categorias' AS f, length(public.tablero_categorias(:s, :'ini', :'fin', NULL)::text);
SELECT 'bot_ventas_periodo' AS f, length(public.bot_ventas_periodo(:'ini', :'fin', :s, 10)::text);
\timing off
RESET ROLE;
ROLLBACK;

\echo '##### SITUACIÓN 2: ANALYZE antes de cargar (estadísticas viejas)'
ANALYZE;
BEGIN;
SELECT pg_temp.c5_datos();
SELECT v AS s FROM c5t WHERE k = 's' \gset
SELECT v AS ini FROM c5t WHERE k = 'ini' \gset
SELECT v AS fin FROM c5t WHERE k = 'fin' \gset
SELECT * FROM pg_temp.c5_distintas(:s, :'ini', :'fin');
SELECT set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000004e7', 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', :'s')::text, true) \g /dev/null
SET LOCAL statement_timeout = '8s';
SET LOCAL ROLE authenticated;
\timing on
SELECT 'gerencial' AS f, length(public.reporte_gerencial(:s, :'ini', :'fin')::text);
SELECT 'rendimiento' AS f, length(public.rendimiento_preventistas(:s, :'ini')::text);
\timing off
RESET ROLE;
SET LOCAL ROLE service_role;
\timing on
SELECT 'tablero_categorias' AS f, length(public.tablero_categorias(:s, :'ini', :'fin', NULL)::text);
SELECT 'bot_ventas_periodo' AS f, length(public.bot_ventas_periodo(:'ini', :'fin', :s, 10)::text);
\timing off
RESET ROLE;
ROLLBACK;

\echo '##### SITUACIÓN 3: ANALYZE de todo'
BEGIN;
SELECT pg_temp.c5_datos();
ANALYZE;
SELECT v AS s FROM c5t WHERE k = 's' \gset
SELECT v AS ini FROM c5t WHERE k = 'ini' \gset
SELECT v AS fin FROM c5t WHERE k = 'fin' \gset
SELECT * FROM pg_temp.c5_distintas(:s, :'ini', :'fin');
SELECT set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000004e7', 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', :'s')::text, true) \g /dev/null
SET LOCAL statement_timeout = '8s';
SET LOCAL ROLE authenticated;
\timing on
SELECT 'gerencial' AS f, length(public.reporte_gerencial(:s, :'ini', :'fin')::text);
SELECT 'rendimiento' AS f, length(public.rendimiento_preventistas(:s, :'ini')::text);
\timing off
RESET ROLE;
SET LOCAL ROLE service_role;
\timing on
SELECT 'tablero_categorias' AS f, length(public.tablero_categorias(:s, :'ini', :'fin', NULL)::text);
SELECT 'bot_ventas_periodo' AS f, length(public.bot_ventas_periodo(:'ini', :'fin', :s, 10)::text);
\timing off
RESET ROLE;
ROLLBACK;
