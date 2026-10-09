-- Ensayo de #1055: no se anula una salvedad de un pedido cancelado.
--
-- Corre contra prod SIN dejar rastro: todo pasa dentro de un bloque que
-- termina SIEMPRE en una excepcion, asi que lo que crea se deshace.
--
-- El caso: pedido de 10 sobre un producto con stock 50. Salvedad de 4
-- ('cliente_rechaza', devuelve 4: stock 44). Cancelar el pedido devuelve las 6
-- que quedaban en la linea: stock 50, como antes del pedido. Anular la
-- salvedad restituia la linea a 10 sobre el pedido cancelado (total > 0,
-- VENTA-I en rojo) y bajaba 4 de stock que no habian salido (stock 46).
-- Ahora anular_salvedad rechaza: el pedido, la linea y el stock no se mueven.
--
-- Veredicto: NOTICE 'ENSAYO OK (todo revertido)', o el error 'ENSAYO FALLÓ …'.
--
--   psql "$DATABASE_URL" -f scripts/test-anular-salvedad-pedido-cancelado.sql

DO $ensayo1055$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_prod    bigint;
  v_res     jsonb;
  v_ped     bigint;
  v_item    bigint;
  v_salv    bigint;
  v_fallas  text[] := '{}';
BEGIN
 BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;

  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1055', 100, 50, 60, v_suc) RETURNING id INTO v_prod;

  v_res := public.crear_pedido_completo(
    v_cliente, 1000, v_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
    'ensayo 1055');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;

  v_res := public.registrar_salvedad(v_ped, v_item, 4, 'cliente_rechaza', NULL, NULL, true, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar: %', v_res;
  END IF;
  v_salv := (v_res->>'salvedad_id')::bigint;

  v_res := public.cancelar_pedido_con_stock(v_ped, 'ensayo 1055', NULL, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'cancelar: %', v_res;
  END IF;
  IF (SELECT stock FROM productos WHERE id = v_prod) <> 50 THEN
    RAISE EXCEPTION 'la cancelacion no dejo el stock en 50: %', (SELECT stock FROM productos WHERE id = v_prod);
  END IF;

  v_res := public.anular_salvedad(v_salv, 'ensayo 1055');
  IF COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('anular_salvedad acepto anular sobre un pedido cancelado: %s', v_res);
  ELSIF v_res->>'codigo' IS DISTINCT FROM 'pedido_cancelado' THEN
    v_fallas := v_fallas || format('anular_salvedad rechazo, pero no por el pedido cancelado: %s', v_res);
  END IF;

  IF (SELECT stock FROM productos WHERE id = v_prod) <> 50 THEN
    v_fallas := v_fallas || format('el stock quedo en %s; tenia que seguir en 50',
                                   (SELECT stock FROM productos WHERE id = v_prod));
  END IF;
  IF (SELECT total FROM pedidos WHERE id = v_ped) <> 0
     OR (SELECT cantidad FROM pedido_items WHERE id = v_item) <> 6 THEN
    v_fallas := v_fallas || format('el pedido cancelado quedo con total %s y la linea en %s',
                                   (SELECT total FROM pedidos WHERE id = v_ped),
                                   (SELECT cantidad FROM pedido_items WHERE id = v_item));
  END IF;
  IF (SELECT estado_resolucion FROM salvedades_items WHERE id = v_salv) = 'anulada' THEN
    v_fallas := v_fallas || 'la salvedad quedo anulada'::text;
  END IF;

  -- Y una salvedad sobre un pedido vivo se sigue anulando.
  v_res := public.crear_pedido_completo(
    v_cliente, 1000, v_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
    'ensayo 1055 vivo');
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  v_res := public.registrar_salvedad(v_ped, v_item, 4, 'cliente_rechaza', NULL, NULL, true, NULL);
  v_res := public.anular_salvedad((v_res->>'salvedad_id')::bigint, 'ensayo 1055 vivo');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('una salvedad de un pedido vivo ya no se anula: %s', v_res);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1055-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo1055$;
