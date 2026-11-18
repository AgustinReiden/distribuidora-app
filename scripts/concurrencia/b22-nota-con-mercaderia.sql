-- Fixtures de scripts/concurrencia/b22-nota-con-mercaderia.sh (tarjeta B22 de #1603): una nota de crédito
-- de venta que reingresa mercadería, a la vez que una venta del mismo producto, una salvedad de la misma
-- boleta u otra nota de la misma boleta.
--
-- Se carga y se CONFIRMA en una base descartable (`docker run … conc-base:<n>` con la migración de B22
-- aplicada), en el esquema b22c. NUNCA contra prod. Cada escenario arma su sucursal, su producto A (L1 20 y
-- L2 20, bolsa 0) y la boleta P1 (A×10, vendida de L1: huella L1:10); b22c.veredicto dice cómo quedó.
\set ON_ERROR_STOP 1
\set QUIET on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS b22c CASCADE;
CREATE SCHEMA b22c;

CREATE TABLE b22c.fx (k text PRIMARY KEY, v text);
CREATE FUNCTION b22c.fx(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM b22c.fx WHERE k = p_k $f$;
CREATE FUNCTION b22c.adm() RETURNS uuid LANGUAGE sql AS $f$ SELECT '00000000-0000-0000-0000-0000000004e7'::uuid $f$;

-- Corre p_sql como p_uid (authenticated, parado en p_suc).
CREATE FUNCTION b22c.como(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE x text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO x;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE;
  END;
  EXECUTE 'RESET ROLE';
  RETURN x;
END $f$;

-- Un escenario nuevo. Si p_con_nota, una nota de rechazo de A×4 sobre P1 (vuelve a L1).
CREATE FUNCTION b22c.escenario(p_con_nota boolean) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_s bigint; v_c bigint; v_c2 bigint; v_a bigint; v_p bigint; v_it bigint; v_r jsonb;
BEGIN
  DELETE FROM b22c.fx;
  INSERT INTO sucursales (nombre) VALUES ('B22 conc ' || left(gen_random_uuid()::text, 8)) RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (b22c.adm(), v_s) ON CONFLICT DO NOTHING;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B22 conc uno', 'B22 conc uno', 'x', v_s) RETURNING id INTO v_c;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('B22 conc dos', 'B22 conc dos', 'y', v_s) RETURNING id INTO v_c2;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES ('B22 conc A', 100, 40, 60, 60, 60, 60, v_s) RETURNING id INTO v_a;
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
    VALUES (v_a, v_s, public._tablero_hoy() + 30, 20, 20, 'manual'), (v_a, v_s, public._tablero_hoy() + 60, 20, 20, 'manual');
  -- creado_por: lo pide el centinela de atribución de auditoria_integridad (COMIS-05).
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, total, estado, fecha, fecha_entrega, canal,
                       retiro_deposito, tipo_factura)
    VALUES (v_c, v_s, b22c.adm(), b22c.adm(), 1000, 'entregado', public._tablero_hoy(), now(), 'app', true, 'ZZ')
    RETURNING id INTO v_p;
  INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id, costo_unitario_al_crear)
    VALUES (v_p, v_a, 10, 100, 1000, v_s, 60) RETURNING id INTO v_it;
  -- La venta, como el alta: con la bolsa en 0 sale de L1 y deja la huella de la línea.
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_p::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_it::text, true);
  UPDATE productos SET stock = stock - 10 WHERE id = v_a;
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  INSERT INTO b22c.fx VALUES ('s', v_s), ('c', v_c), ('c2', v_c2), ('a', v_a), ('p1', v_p), ('i1', v_it);
  IF p_con_nota THEN
    v_r := b22c.nc(4);
    INSERT INTO b22c.fx VALUES ('n', v_r->>'nota_credito_id');
  END IF;
END $f$;

-- La nota de rechazo (A×p) sobre P1, por la RPC.
CREATE FUNCTION b22c.nc(p int) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT b22c.como(b22c.adm(), b22c.fx('s')::bigint, format(
    'SELECT public.crear_nota_credito_venta(%s, %s, %L::jsonb, %L, %L, %L::uuid)::text',
    b22c.fx('p1'), b22c.fx('c'),
    jsonb_build_array(jsonb_build_object('pedido_item_id', b22c.fx('i1')::bigint, 'cantidad', p)),
    'cliente_rechaza', 'conc B22', gen_random_uuid()))::jsonb;
$f$;

-- Lo mismo, y devuelve el error en texto (la segunda nota de V5 se rechaza).
CREATE FUNCTION b22c.nc_txt(p int) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  RETURN 'nota ' || (b22c.nc(p)->>'unidades_movidas') || ' u.';
EXCEPTION WHEN OTHERS THEN
  RETURN 'nota rechazada: ' || SQLERRM;
END $f$;

CREATE FUNCTION b22c.anular() RETURNS text LANGUAGE sql AS $f$
  SELECT 'anulada ' || (b22c.como(b22c.adm(), b22c.fx('s')::bigint, format(
    'SELECT public.anular_nota_credito_venta(%s, %L)::text', b22c.fx('n'), 'conc B22'))::jsonb->>'unidades_revertidas') || ' u.';
$f$;

-- Una venta de A×p a otro cliente, por crear_pedido_completo (como el front: el admin).
CREATE FUNCTION b22c.venta(p int) RETURNS text LANGUAGE sql AS $f$
  SELECT 'venta ' || (b22c.como(b22c.adm(), b22c.fx('s')::bigint, format(
    'SELECT public.crear_pedido_completo(%s, %s, %L::uuid, %L::jsonb, %L)::text',
    b22c.fx('c2'), 100 * p, b22c.adm(),
    jsonb_build_array(jsonb_build_object('producto_id', b22c.fx('a')::bigint, 'cantidad', p, 'precio_unitario', 100)),
    'conc B22'))::jsonb->>'success');
$f$;

-- Una salvedad de rechazo (A×p) sobre la misma línea de P1.
CREATE FUNCTION b22c.salvedad(p int) RETURNS text LANGUAGE sql AS $f$
  SELECT 'salvedad ' || (SELECT CASE WHEN (x->>'success')::boolean THEN 'ok' ELSE 'rechazada: ' || (x->>'error') END
                           FROM (SELECT b22c.como(b22c.adm(), b22c.fx('s')::bigint, format(
                                   'SELECT public.registrar_salvedad(%s, %s, %s, %L, %L)::text',
                                   b22c.fx('p1'), b22c.fx('i1'), p, 'cliente_rechaza', 'conc B22'))::jsonb AS x) y);
$f$;

CREATE FUNCTION b22c.foto() RETURNS text LANGUAGE sql AS $f$
  SELECT format('stock=%s lotes=[%s] bolsa=%s', p.stock,
    (SELECT string_agg(cantidad_restante::text, ',' ORDER BY fecha_vencimiento, id) FROM producto_lotes WHERE producto_id = p.id),
    p.stock - (SELECT sum(cantidad_restante) FROM producto_lotes WHERE producto_id = p.id))
    FROM productos p WHERE p.id = b22c.fx('a')::bigint
$f$;

-- «OK» si la foto es la esperada, la línea de P1 tiene la cantidad y la huella esperadas, el ledger de A
-- cierra (cada fila arranca donde terminó la anterior y la última es el stock) y los lotes no pasan el stock.
CREATE FUNCTION b22c.veredicto(p_foto text, p_linea int, p_huella int) RETURNS text LANGUAGE sql AS $f$
  WITH led AS (
    SELECT count(*) FILTER (WHERE prev IS NOT NULL AND prev <> stock_anterior) AS saltos
      FROM (SELECT stock_anterior, lag(stock_nuevo) OVER (ORDER BY id) AS prev
              FROM stock_historico WHERE producto_id = b22c.fx('a')::bigint) x
  ), ult AS (
    SELECT stock_nuevo FROM stock_historico WHERE producto_id = b22c.fx('a')::bigint ORDER BY id DESC LIMIT 1
  ), lin AS (
    SELECT pi.cantidad,
           (SELECT COALESCE(sum(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = pi.id) AS huella
      FROM pedido_items pi WHERE pi.id = b22c.fx('i1')::bigint
  )
  SELECT CASE WHEN b22c.foto() = p_foto AND led.saltos = 0
               AND ult.stock_nuevo = (SELECT stock FROM productos WHERE id = b22c.fx('a')::bigint)
               AND lin.cantidad = p_linea AND lin.huella = p_huella
              THEN 'OK' ELSE 'FALLA' END
         || format(' · %s (esperado %s) · línea %s u. con huella %s (esperado %s y %s) · saltos del ledger %s',
                   b22c.foto(), p_foto, lin.cantidad, lin.huella, p_linea, p_huella, led.saltos)
    FROM led, ult, lin
$f$;

\set QUIET off
SELECT 'fixtures b22c listas';
