-- Fixtures de scripts/concurrencia/c3-edicion-compra-y-venta.sh (tarjeta C3 de la tanda 5 de #1603): la
-- edición de una compra que trae sus vencimientos (una sola llamada, STK-13) a la vez que una venta del
-- mismo producto.
--
-- Se carga y se CONFIRMA en una base descartable (`docker run … conc-base:<n>` con la migración de C3
-- aplicada), en el esquema c3c. NUNCA contra prod. Cada escenario arma su sucursal, su cliente y su
-- producto A, y una ZZ de A×100 con lotes de 60 (vence en 30 días) y 40 (en 60), con la bolsa en 0;
-- c3c.veredicto dice cómo quedó.
\set ON_ERROR_STOP 1
\set QUIET on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS c3c CASCADE;
CREATE SCHEMA c3c;

CREATE TABLE c3c.fx (k text PRIMARY KEY, v text);
CREATE FUNCTION c3c.fx(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM c3c.fx WHERE k = p_k $f$;
CREATE FUNCTION c3c.adm() RETURNS uuid LANGUAGE sql AS $f$ SELECT '00000000-0000-0000-0000-0000000004e7'::uuid $f$;

-- Corre p_sql como p_uid (authenticated, parado en p_suc).
CREATE FUNCTION c3c.como(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
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

-- Los vencimientos de la compra: 60 a 30 días y 40 a 60 días, o lo que se diga.
CREATE FUNCTION c3c.lotes(p_l1 int, p_l2 int) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_array(
    jsonb_build_object('producto_id', c3c.fx('a')::bigint, 'fecha_vencimiento', public._tablero_hoy() + 30, 'cantidad', p_l1),
    jsonb_build_object('producto_id', c3c.fx('a')::bigint, 'fecha_vencimiento', public._tablero_hoy() + 60, 'cantidad', p_l2));
$f$;

-- Un escenario nuevo: la sucursal, el cliente, A, y la compra de A×100 a 10 con sus dos lotes.
CREATE FUNCTION c3c.escenario() RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_s bigint; v_c bigint; v_a bigint; v_r jsonb; v_lin jsonb;
BEGIN
  DELETE FROM c3c.fx;
  INSERT INTO sucursales (nombre) VALUES ('C3 conc ' || left(gen_random_uuid()::text, 8)) RETURNING id INTO v_s;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (c3c.adm(), v_s) ON CONFLICT DO NOTHING;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('C3 conc uno', 'C3 conc uno', 'x', v_s) RETURNING id INTO v_c;
  INSERT INTO productos (nombre, precio, stock, sucursal_id)
    VALUES ('C3 conc A', 100, 0, v_s) RETURNING id INTO v_a;
  INSERT INTO c3c.fx VALUES ('s', v_s), ('c', v_c), ('a', v_a);
  v_lin := jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 100, 'costo_unitario', 10,
             'subtotal', 1000, 'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0));
  v_r := c3c.como(c3c.adm(), v_s, format(
    'SELECT public.registrar_compra_completa(NULL, %L, %L, %L::date, 1000, 0, 0, 1000, %L, %L, %L::uuid, %L::jsonb, %L)::text',
    'C3 conc', 'C3-' || left(gen_random_uuid()::text, 8), public._tablero_hoy(), 'efectivo', 'conc C3', c3c.adm(), v_lin, 'ZZ'))::jsonb;
  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'la compra no se registró: %', v_r;
  END IF;
  INSERT INTO c3c.fx VALUES ('compra', v_r->>'compra_id');
  PERFORM c3c.como(c3c.adm(), v_s, format('SELECT public.sincronizar_lotes_compra(%s, %L::jsonb)::text',
    v_r->>'compra_id', c3c.lotes(60, 40)));
END $f$;

-- La edición de la compra a A×80 con sus vencimientos (50 y 30) en la misma llamada, como el front nuevo.
CREATE FUNCTION c3c.editar() RETURNS text LANGUAGE sql AS $f$
  SELECT 'edición ' || (SELECT CASE WHEN (x->>'success')::boolean THEN 'ok, lotes_sincronizados=' || (x->>'lotes_sincronizados')
                                     ELSE 'rechazada: ' || (x->>'error') END
                          FROM (SELECT c3c.como(c3c.adm(), c3c.fx('s')::bigint, format(
    'SELECT public.actualizar_compra_items(%s, %L::jsonb, 800, 0, 800, %L::uuid, p_cargos => ''[]''::jsonb, '
    || 'p_ii_declarado => ''{}''::jsonb, p_renglones_vistos => %L::bigint[], p_lotes => %L::jsonb)::text',
    c3c.fx('compra'),
    jsonb_build_array(jsonb_build_object('producto_id', c3c.fx('a')::bigint, 'cantidad', 80, 'costo_unitario', 10,
      'subtotal', 800, 'bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0)),
    c3c.adm(),
    (SELECT array_agg(id) FROM compra_items WHERE compra_id = c3c.fx('compra')::bigint),
    c3c.lotes(50, 30)))::jsonb AS x) y);
$f$;

-- Una venta de A×p, por crear_pedido_completo (como el front: el admin).
CREATE FUNCTION c3c.venta(p int) RETURNS text LANGUAGE sql AS $f$
  SELECT 'venta ' || (c3c.como(c3c.adm(), c3c.fx('s')::bigint, format(
    'SELECT public.crear_pedido_completo(%s, %s, %L::uuid, %L::jsonb, %L)::text',
    c3c.fx('c'), 100 * p, c3c.adm(),
    jsonb_build_array(jsonb_build_object('producto_id', c3c.fx('a')::bigint, 'cantidad', p, 'precio_unitario', 100)),
    'conc C3'))::jsonb->>'success');
$f$;

CREATE FUNCTION c3c.foto() RETURNS text LANGUAGE sql AS $f$
  SELECT format('stock=%s lotes=[%s] bolsa=%s compra=%s', p.stock,
    (SELECT string_agg(cantidad_restante || '/' || cantidad, ',' ORDER BY fecha_vencimiento, id) FROM producto_lotes WHERE producto_id = p.id),
    p.stock - (SELECT sum(cantidad_restante) FROM producto_lotes WHERE producto_id = p.id),
    (SELECT sum(cantidad) FROM compra_items WHERE compra_id = c3c.fx('compra')::bigint))
    FROM productos p WHERE p.id = c3c.fx('a')::bigint
$f$;

-- «OK» si la foto es la esperada y el ledger de A cierra (cada fila arranca donde terminó la anterior y la
-- última es el stock).
CREATE FUNCTION c3c.veredicto(p_foto text) RETURNS text LANGUAGE sql AS $f$
  WITH led AS (
    SELECT count(*) FILTER (WHERE prev IS NOT NULL AND prev <> stock_anterior) AS saltos
      FROM (SELECT stock_anterior, lag(stock_nuevo) OVER (ORDER BY id) AS prev
              FROM stock_historico WHERE producto_id = c3c.fx('a')::bigint) x
  ), ult AS (
    SELECT stock_nuevo FROM stock_historico WHERE producto_id = c3c.fx('a')::bigint ORDER BY id DESC LIMIT 1
  )
  SELECT CASE WHEN c3c.foto() = p_foto AND led.saltos = 0
               AND ult.stock_nuevo = (SELECT stock FROM productos WHERE id = c3c.fx('a')::bigint)
              THEN 'OK' ELSE 'FALLA' END
         || format(' · %s (esperado %s) · saltos del ledger %s', c3c.foto(), p_foto, led.saltos)
    FROM led, ult
$f$;

\set QUIET off
SELECT 'fixtures c3c listas';
