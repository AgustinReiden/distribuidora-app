-- No se anula una salvedad de un pedido cancelado (#1055)
--
-- EL BUG
--
--   anular_salvedad no miraba el estado del pedido. Para un vale blanco,
--   cancelar_pedido_con_stock ya rechaza si hay salvedades vivas (317), pero un
--   pedido comun se puede cancelar con salvedades vivas y despues anularlas.
--   Medido en prod con scripts/test-anular-salvedad-pedido-cancelado.sql:
--   pedido de 10 con stock 50, salvedad de 4 (stock 44), cancelar (vuelven las
--   6 de la linea: stock 50), anular la salvedad -> success, la linea vuelve a
--   10 sobre el pedido CANCELADO (total 1000: VENTA-I en rojo) y el stock baja
--   a 46: 4 unidades que no salieron a ningun lado. Desde la 328, ademas, se le
--   reponia huella de lote a un pedido cancelado.
--
--   En prod hay 2 expuestos (2026-10-09): los pedidos #740 y #741, cancelados
--   el 14/04 con una salvedad 'error_pedido' viva cada uno. Quedan como estan.
--
-- DECISION DEL DUEÑO (2026-10-09)
--
--   anular_salvedad rechaza si el pedido esta cancelado (o anulado): cancelar ya
--   devolvio todo lo que quedaba en la linea, no hay nada que restituir.
--   cancelar_pedido_con_stock no cambia.
--
-- El guard lockea el pedido (FOR UPDATE): una cancelacion concurrente no se
-- cuela entre el chequeo y la restitucion. El orden de locks es el de
-- cancelar_pedido_con_stock (pedido, despues stock).
--
-- Firma, SECURITY DEFINER y GRANTs de anular_salvedad: como estaban (se parchea
-- el cuerpo vivo; el ancla tiene que aparecer exactamente una vez).

DO $anular$
DECLARE
  v_fn    constant regprocedure := 'public.anular_salvedad(bigint,text)'::regprocedure;
  v_def   text := pg_get_functiondef(v_fn);
  v_viejo constant text := replace($a$  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;
$a$, E'\r', '');
  v_nuevo constant text := replace($n$  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;

  -- #1055: sobre un pedido cancelado no hay nada que restituir: la
  -- cancelacion ya devolvio lo que quedaba en la linea. Anular igual volvia a
  -- poner la linea en un pedido cancelado (total > 0) y bajaba stock que no
  -- salio. Primero el lock del pedido: una cancelacion concurrente espera, o
  -- ya esta confirmada y se ve.
  PERFORM 1 FROM pedidos
   WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF EXISTS (SELECT 1 FROM pedidos
              WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal
                AND estado IN ('cancelado', 'anulado')) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'El pedido de esta salvedad esta cancelado: la cancelacion ya devolvio la mercaderia y no hay nada que restituir.',
      'codigo', 'pedido_cancelado'
    );
  END IF;
$n$, E'\r', '');
BEGIN
  IF (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo) <> 1 THEN
    RAISE EXCEPTION 'anular_salvedad no tiene exactamente un chequeo de Ya anulada: el cuerpo vivo cambio, revisar a mano';
  END IF;
  EXECUTE replace(v_def, v_viejo, v_nuevo);
END
$anular$;

DO $verif$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  IF v_def NOT LIKE '%''codigo'', ''pedido_cancelado''%'
     OR v_def NOT LIKE '%SECURITY DEFINER%'
     OR position('pedido_cancelado' IN v_def) > position('UPDATE pedido_items' IN v_def) THEN
    RAISE EXCEPTION 'anular_salvedad no quedo con el guard antes de restituir';
  END IF;
  IF has_function_privilege('anon', 'public.anular_salvedad(bigint,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anular_salvedad quedo ejecutable por anon';
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- Ensayo #1055 con datos reales (se deshace solo). Es
-- scripts/test-anular-salvedad-pedido-cancelado.sql, que antes de esta
-- migracion daba 3 fallas (anular aceptaba, stock 46, pedido con total 1000).
-- ---------------------------------------------------------------------------
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
