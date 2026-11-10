-- Ensayo de la 480b: el cambio de cliente conserva las líneas de un producto desactivado (VTA-05 de #1513).
-- Pide la 480 y la 480b aplicadas. D1 y D2 fallan sin la 480b; D3 es el control.
--
--   D1 · X vende 3 de P; después P se desactiva. Pasar X a C2 funciona y el pedido nuevo lleva las 3 de P.
--   D2 · X regala 5 de R (una promo de P'); después R se desactiva. Pasar X a C2 funciona y el regalo pasa.
--   D3 · Control: un alta nueva con P desactivado se sigue rechazando ("está desactivado").
--   L1 · Los EXECUTE de crear_pedido_completo no cambiaron (authenticated sí, anon no).
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre en una
-- excepción, y cada caso en un sub-bloque que se revierte.
--
-- Fixtures: una sucursal activa con un admin activo y la caja de hoy abierta. El resto nace en el ensayo.

CREATE OR REPLACE FUNCTION pg_temp.d13_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.d13_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1513 480b', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.d13_producto(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1513 480b ' || p_nombre, 100, 1000, 60, p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.d13_alta(p_cli bigint, p_adm uuid, p_items jsonb, p_fecha date)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_adm, p_items, 'ensayo 1513 480b', 'efectivo', 'pendiente', p_fecha, NULL);
  PERFORM pg_temp.d13_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.d13_cambiar(p_ped bigint, p_cli bigint, p_adm uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.cambiar_cliente_pedido(
    p_ped, p_cli, p_adm, p_items,
    (SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
       FROM jsonb_array_elements(p_items) e WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)),
    NULL, 0, 'ensayo 1513 480b', 'pedido_nuevo');
  PERFORM pg_temp.d13_reset();
  RETURN v_res;
END
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_hoy    date := public._tablero_hoy();
  v_p      bigint;
  v_r      bigint;
  v_promo  bigint;
  v_c1     bigint;
  v_c2     bigint;
  v_x      bigint;
  v_n      bigint;
  v_items  jsonb;
  v_j      jsonb;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  SELECT s.id, adm.usuario_id
    INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
     AND COALESCE(public.ultima_fecha_caja_cerrada(s.id), v_hoy - 1) < v_hoy
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin y la caja de hoy abierta';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_adm, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  v_p := pg_temp.d13_producto(v_suc, 'P');
  v_r := pg_temp.d13_producto(v_suc, 'R');

  -- D1 · una línea de venta de un producto desactivado después del alta
  BEGIN
    v_c1 := pg_temp.d13_cliente(v_suc, 'ZZ ensayo 1513 480b D1 C1');
    v_c2 := pg_temp.d13_cliente(v_suc, 'ZZ ensayo 1513 480b D1 C2');
    v_items := jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 3, 'precio_unitario', 100));
    v_j := pg_temp.d13_alta(v_c1, v_adm, v_items, v_hoy);
    v_x := (v_j->>'pedido_id')::bigint;
    IF v_x IS NULL THEN RAISE EXCEPTION 'precondición: el alta no entró: %', v_j; END IF;
    UPDATE productos SET activo = false WHERE id = v_p;
    v_j := pg_temp.d13_cambiar(v_x, v_c2, v_adm, v_items);
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR (SELECT string_agg(producto_id || 'x' || cantidad, ',') FROM pedido_items WHERE pedido_id = v_n)
          IS DISTINCT FROM v_p || 'x3' THEN
      v_fallas := v_fallas || format('D1 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- D2 · el regalo de un producto desactivado después del alta
  BEGIN
    v_c1 := pg_temp.d13_cliente(v_suc, 'ZZ ensayo 1513 480b D2 C1');
    v_c2 := pg_temp.d13_cliente(v_suc, 'ZZ ensayo 1513 480b D2 C2');
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
    VALUES ('ZZ ensayo 1513 480b', 'bonificacion', v_hoy - 1, v_suc, true, v_r)
    RETURNING id INTO v_promo;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 5, v_suc);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_p, v_suc);
    v_items := jsonb_build_array(
      jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'precio_unitario', 100),
      jsonb_build_object('producto_id', v_r, 'cantidad', 5, 'precio_unitario', 0, 'es_bonificacion', true,
                         'promocion_id', v_promo));
    v_j := pg_temp.d13_alta(v_c1, v_adm, v_items, v_hoy);
    v_x := (v_j->>'pedido_id')::bigint;
    IF v_x IS NULL THEN RAISE EXCEPTION 'precondición: el alta no entró: %', v_j; END IF;
    UPDATE productos SET activo = false WHERE id = v_r;
    v_j := pg_temp.d13_cambiar(v_x, v_c2, v_adm, v_items);
    v_n := (v_j->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((v_j->>'success')::boolean, false)
       OR NOT EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_n AND producto_id = v_r AND es_bonificacion AND cantidad = 5) THEN
      v_fallas := v_fallas || format('D2 dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- D3 · control: un alta nueva con el producto desactivado se sigue rechazando
  BEGIN
    v_c1 := pg_temp.d13_cliente(v_suc, 'ZZ ensayo 1513 480b D3 C1');
    UPDATE productos SET activo = false WHERE id = v_p;
    v_j := pg_temp.d13_alta(v_c1, v_adm,
             jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 3, 'precio_unitario', 100)), v_hoy);
    IF COALESCE((v_j->>'success')::boolean, true) OR v_j::text NOT LIKE '%desactivado%' THEN
      v_fallas := v_fallas || format('D3 el alta con el producto desactivado dio %s', v_j);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ513';
  EXCEPTION
    WHEN SQLSTATE 'ZZ513' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- L1 · los EXECUTE de crear_pedido_completo no cambiaron
  IF has_function_privilege('anon', 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'L1 los EXECUTE de crear_pedido_completo cambiaron'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · D1 D2 D3 L1';
 END;
END
$ensayo$;
