-- Fixtures de scripts/concurrencia/c4b-combo-y-venta.sh (tarjeta C4b de #1603, H1 de su revisión
-- adversarial): guardar un combo MIENTRAS se vende o se edita un pedido con ese combo.
--
-- Se carga y se CONFIRMA en una base descartable (`docker run … conc-base:<n>` con la migración de
-- C4b aplicada y la semilla de los ensayos), en el esquema c4bc. NUNCA contra prod.
\set ON_ERROR_STOP 1
\set QUIET on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS c4bc CASCADE;
CREATE SCHEMA c4bc;

CREATE TABLE c4bc.fx (k text PRIMARY KEY, v text);
CREATE FUNCTION c4bc.fx(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM c4bc.fx WHERE k = p_k $f$;
CREATE FUNCTION c4bc.adm() RETURNS uuid LANGUAGE sql AS $f$ SELECT '00000000-0000-0000-0000-0000000004e7'::uuid $f$;

-- Corre p_sql como p_uid (authenticated, parado en la sucursal 1).
CREATE FUNCTION c4bc.como(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE x text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c4bc.adm(), 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', c4bc.adm()::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', '1')::text, true);
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

-- Dos productos con stock y lote, un cliente y el combo A + B a $1.800 (cada línea a $900).
CREATE FUNCTION c4bc.escenario() RETURNS void LANGUAGE plpgsql AS $f$
DECLARE
  v_a bigint; v_b bigint; v_cli bigint; v_compra bigint; v_combo jsonb;
BEGIN
  UPDATE public.sucursales SET activa = true WHERE id = 1;
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ C4bc A', 1000, 1000, 600, 1, 'ZZ C4bc') RETURNING id INTO v_a;
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ C4bc B', 1000, 1000, 600, 1, 'ZZ C4bc') RETURNING id INTO v_b;
  INSERT INTO public.compras (sucursal_id, estado, usuario_id) VALUES (1, 'recibida', c4bc.adm()) RETURNING id INTO v_compra;
  INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id, compra_id)
  VALUES (v_a, 1, public._tablero_hoy() + 365, 1000, 1000, c4bc.adm(), v_compra),
         (v_b, 1, public._tablero_hoy() + 365, 1000, 1000, c4bc.adm(), v_compra);
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ C4bc cliente', 'ZZ C4bc cliente', 'Calle C4bc ' || clock_timestamp()::text, 1) RETURNING id INTO v_cli;
  v_combo := c4bc.como(format('SELECT public.guardar_combo(%L::jsonb)::text', jsonb_build_object(
    'nombre', 'ZZ C4bc combo', 'precio', 1800, 'fecha_inicio', public._tablero_hoy(),
    'componentes', jsonb_build_array(jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_a)),
                                     jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(v_b))))))::jsonb;
  IF NOT COALESCE((v_combo->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el combo: %', v_combo;
  END IF;
  DELETE FROM c4bc.fx;
  INSERT INTO c4bc.fx VALUES ('a', v_a), ('b', v_b), ('cli', v_cli), ('combo', v_combo->>'id');
  -- Un pedido con el combo, para la edición.
  INSERT INTO c4bc.fx VALUES ('pedido', (c4bc.vender())::jsonb->>'pedido_id');
END $f$;

CREATE FUNCTION c4bc.items() RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_array(
    jsonb_build_object('producto_id', c4bc.fx('a')::bigint, 'cantidad', 1, 'precio_unitario', 900,
                       'combo_id', c4bc.fx('combo')::bigint, 'precio_sin_combo_unitario', 1000),
    jsonb_build_object('producto_id', c4bc.fx('b')::bigint, 'cantidad', 1, 'precio_unitario', 900,
                       'combo_id', c4bc.fx('combo')::bigint, 'precio_sin_combo_unitario', 1000))
$f$;

-- La venta REAL de un combo (crear_pedido_completo). Devuelve el JSON de la RPC.
CREATE FUNCTION c4bc.vender() RETURNS text LANGUAGE sql AS $f$
  SELECT c4bc.como(format('SELECT public.crear_pedido_completo(%s, 1800, %L::uuid, %L::jsonb, %L)::text',
                          c4bc.fx('cli'), c4bc.adm(), c4bc.items(), 'concurrencia C4b'))
$f$;

-- La edición REAL del pedido con el combo (actualizar_pedido_items), con las mismas líneas.
CREATE FUNCTION c4bc.editar() RETURNS text LANGUAGE sql AS $f$
  SELECT c4bc.como(format('SELECT public.actualizar_pedido_items(%s, %L::jsonb, %L::uuid)::text',
                          c4bc.fx('pedido'), c4bc.items(), c4bc.adm()))
$f$;

-- Lo que una venta o una edición ya tomó antes de escribir la línea del combo: el producto, FOR
-- UPDATE (crear_pedido_completo y actualizar_pedido_items lo toman al empezar, por el stock).
CREATE FUNCTION c4bc.tomar_producto() RETURNS text LANGUAGE sql AS $f$
  SELECT 'producto tomado ' || id FROM public.productos WHERE id = c4bc.fx('a')::bigint FOR UPDATE
$f$;

-- Guardar el combo (el mismo, con otro precio repartible) como el admin.
CREATE FUNCTION c4bc.guardar() RETURNS text LANGUAGE sql AS $f$
  SELECT c4bc.como(format('SELECT public.guardar_combo(%L::jsonb)::text', jsonb_build_object(
    'id', c4bc.fx('combo')::bigint, 'nombre', 'ZZ C4bc combo', 'precio', 1800, 'fecha_inicio', public._tablero_hoy(),
    'componentes', jsonb_build_array(jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(c4bc.fx('a')::bigint)),
                                     jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(c4bc.fx('b')::bigint))))))
$f$;

-- Control negativo: guardar_combo como lo dejaba la v2 (FOR UPDATE en el loop de los combos), y vuelta.
CREATE FUNCTION c4bc.poner_for_update(p_si boolean) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_def text := pg_get_functiondef('public.guardar_combo(jsonb)'::regprocedure);
  v_nuevo text;
BEGIN
  IF p_si THEN
    v_nuevo := replace(v_def, 'FROM combos WHERE id = v_x FOR NO KEY UPDATE', 'FROM combos WHERE id = v_x FOR UPDATE');
  ELSE
    v_nuevo := replace(v_def, 'FROM combos WHERE id = v_x FOR UPDATE', 'FROM combos WHERE id = v_x FOR NO KEY UPDATE');
  END IF;
  EXECUTE v_nuevo;
  RETURN CASE WHEN v_nuevo = v_def THEN 'sin cambio' ELSE 'cambiado' END;
END $f$;

-- Editar el cliente de la venta (guardar_cliente toma el cliente FOR NO KEY UPDATE: no choca con el
-- KEY SHARE de la FK de pedidos ni de pagos).
CREATE FUNCTION c4bc.guardar_cliente() RETURNS text LANGUAGE sql AS $f$
  SELECT c4bc.como(format('SELECT public.guardar_cliente(%L::jsonb)::text',
    jsonb_build_object('id', c4bc.fx('cli')::bigint, 'campos', jsonb_build_object('notas', 'C4bc ' || clock_timestamp()))))
$f$;
