-- Ensayo de #1050: anular una salvedad que devolvio stock saca las unidades
-- del mismo lote al que volvieron, y el reintento idempotente de
-- registrar_salvedad no contesta antes de saber quien pregunta.
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en
-- RAISE EXCEPTION, asi que todo lo que crea (productos, lotes, pedidos,
-- salvedades) se deshace. Usa un admin y un usuario sin rol de entrega reales
-- de una sucursal activa, como los ensayos de las migraciones 316 y 323.
--
-- Por que bolsa distinta de 0: el ensayo de la 316 arrancaba con bolsa 0, y
-- con bolsa 0 la bajada de la anulacion no tiene de donde comer mas que del
-- lote, asi que daba bien por casualidad. Con bolsa > 0 la bajada come primero
-- de la bolsa (el camino de bajada del trigger no mira el origen) y el lote se
-- queda con unidades que ya no tiene.
--
-- Casos:
--   A · los 5 motivos que devuelven stock. Lote 100 con 50 vivas, bolsa 40.
--       Pedido de 10 (sale de la bolsa): stock 80, lote 50, bolsa 30.
--       Salvedad de 10 (vuelve al lote): stock 90, lote 60, bolsa 30.
--       Anular: tiene que volver a stock 80, lote 50, bolsa 30.
--   B · el MISMO lote, no el primero por FEFO. Lote A (vence antes) lleno 50/50,
--       lote B (vence despues) 40/100, bolsa 20. Pedido de 10 de la bolsa;
--       la salvedad vuelve a B (A no tiene hueco). Anular tiene que sacarlas
--       de B: A 50, B 40, bolsa 10. Por FEFO saldrian de A.
--   F · la huella lote -> cliente (pedido_item_lotes, mig 256). Bolsa 0: el
--       pedido sale del lote y deja huella. La salvedad se la saca (parcial:
--       _restaurar_lotes_fefo la descuenta; total: el DELETE de la linea la
--       borra en cascada). Anular la repone en la linea restituida. Y en A,
--       donde el pedido salio de la bolsa, anular no inventa huella.
--   H · dos lineas del mismo producto: la salvedad sobre una no le saca la
--       huella a la otra, y la anulacion no se la pasa.
--   G · lotes_devueltos no se escribe por REST (authenticated).
--   D · reintento idempotente: `merma_registrada` dice si HAY merma, no si el
--       motivo suele generarla. (Se modela con una salvedad por dañado sin fila
--       en mermas_stock, que es lo que deja un regalo con regalo_mueve_stock =
--       false.)
--   E · reintento idempotente sin sesion, con un usuario sin permiso sobre el
--       pedido y desde otra sucursal: no devuelve los datos de la salvedad.
--
-- Veredicto: NOTICE 'ENSAYO OK (todo revertido)', o el error 'ENSAYO FALLÓ …'
-- con la lista de fallas. En los dos casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-anular-salvedad-lote-bolsa.sql

DO $ensayo$
DECLARE
  v_admin    uuid;
  v_otro     uuid;
  v_suc      bigint;
  v_suc2     bigint;
  v_cliente  bigint;
  v_prod     bigint;
  v_lote_a   bigint;
  v_lote_b   bigint;
  v_res      jsonb;
  v_ped      bigint;
  v_item     bigint;
  v_salv     bigint;
  v_req      uuid;
  v_foto     jsonb;
  v_motivo   text;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fallas   text[] := '{}';
BEGIN
 -- Todo corre en este bloque interno, que termina SIEMPRE en una excepcion:
 -- lo que crea se deshace. El OK se atrapa abajo y queda como NOTICE, asi el
 -- mismo DO sirve suelto y como compuerta dentro de la migracion.
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

  -- Alguien de la misma sucursal que no es admin, ni encargado, ni el
  -- transportista del pedido (el pedido del ensayo no tiene transportista).
  SELECT us.usuario_id INTO v_otro
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo AND pf.rol NOT IN ('admin', 'encargado')
   WHERE us.sucursal_id = v_suc
   ORDER BY us.usuario_id
   LIMIT 1;
  -- Y otra sucursal activa del mismo admin, si tiene.
  SELECT us.sucursal_id INTO v_suc2
    FROM usuario_sucursales us
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE us.usuario_id = v_admin AND us.sucursal_id <> v_suc
   ORDER BY us.sucursal_id
   LIMIT 1;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo ORDER BY id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  -- stock / suma de lotes / bolsa, y cada lote por id.
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('stock', pr.stock, 'lote', l.r, 'bolsa', pr.stock - l.r)
      FROM public.productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM public.producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.lote(p_lote bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT cantidad_restante FROM public.producto_lotes WHERE id = p_lote;
  $f$;
  -- huella del pedido sobre los lotes de un producto
  CREATE FUNCTION pg_temp.huella(p_ped bigint, p_prod bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT COALESCE(SUM(pil.cantidad), 0)::int
      FROM public.pedido_item_lotes pil
      JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
     WHERE pi.pedido_id = p_ped AND pi.producto_id = p_prod;
  $f$;

  -- -------------------------------------------------------------------------
  -- A · los cinco motivos que devuelven stock
  -- -------------------------------------------------------------------------
  FOREACH v_motivo IN ARRAY ARRAY['cliente_rechaza', 'error_pedido', 'diferencia_precio',
                                  'entregado_otro_cliente', 'otro']
  LOOP
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1050 ' || v_motivo, 100, 90, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo 1050');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A/% · no se pudo crear el pedido: %', v_motivo, v_res;
    END IF;
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;

    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":80,"lote":50,"bolsa":30}'::jsonb THEN
      RAISE EXCEPTION 'A/% · el pedido no dejo el punto de partida esperado: %', v_motivo, v_foto;
    END IF;

    v_res := public.registrar_salvedad(v_ped, v_item, 10, v_motivo,
                                       'ensayo 1050, se anula enseguida', NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR NOT COALESCE((v_res->>'stock_devuelto')::boolean, false) THEN
      RAISE EXCEPTION 'A/% · registrar: %', v_motivo, v_res;
    END IF;
    v_salv := (v_res->>'salvedad_id')::bigint;

    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":90,"lote":60,"bolsa":30}'::jsonb THEN
      RAISE EXCEPTION 'A/% · la salvedad no volvio al lote: %', v_motivo, v_foto;
    END IF;

    v_res := public.anular_salvedad(v_salv, 'ensayo 1050');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'A/% · anular: %', v_motivo, v_res;
    END IF;

    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":80,"lote":50,"bolsa":30}'::jsonb THEN
      v_fallas := v_fallas || format('A/%s · anular dejo %s; tenia que volver a {"stock":80,"lote":50,"bolsa":30}',
                                     v_motivo, v_foto);
    END IF;
    IF pg_temp.huella(v_ped, v_prod) <> 0 THEN
      v_fallas := v_fallas || format('A/%s · el pedido salio de la bolsa y anular le dejo %s de huella en el lote',
                                     v_motivo, pg_temp.huella(v_ped, v_prod));
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- B · el mismo lote al que volvieron, no el primero por FEFO
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1050 B', 100, 110, 60, v_suc) RETURNING id INTO v_prod;
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
  VALUES (v_prod, v_suc, v_hoy + 30, 50, 50, v_admin) RETURNING id INTO v_lote_a;
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
  VALUES (v_prod, v_suc, v_hoy + 90, 100, 40, v_admin) RETURNING id INTO v_lote_b;

  v_res := public.crear_pedido_completo(
    v_cliente, 1000, v_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
    'ensayo 1050 B');
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;

  v_res := public.registrar_salvedad(v_ped, v_item, 10, 'otro', 'ensayo 1050 B, mismo lote', NULL, true, NULL);
  v_salv := (v_res->>'salvedad_id')::bigint;
  IF pg_temp.lote(v_lote_a) <> 50 OR pg_temp.lote(v_lote_b) <> 50 THEN
    RAISE EXCEPTION 'B · la salvedad no volvio al lote B: A % B %', pg_temp.lote(v_lote_a), pg_temp.lote(v_lote_b);
  END IF;

  v_res := public.anular_salvedad(v_salv, 'ensayo 1050 B');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'B · anular: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF pg_temp.lote(v_lote_a) <> 50 OR pg_temp.lote(v_lote_b) <> 40
     OR v_foto <> '{"stock":100,"lote":90,"bolsa":10}'::jsonb THEN
    v_fallas := v_fallas || format('B · anular dejo lote A %s, lote B %s, %s; tenia que ser A 50, B 40, {"stock":100,"lote":90,"bolsa":10}',
                                   pg_temp.lote(v_lote_a), pg_temp.lote(v_lote_b), v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- F · la huella vuelve al cliente (parcial y total)
  -- -------------------------------------------------------------------------
  FOREACH v_motivo IN ARRAY ARRAY['parcial', 'total']
  LOOP
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1050 F ' || v_motivo, 100, 50, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin) RETURNING id INTO v_lote_a;

    v_res := public.crear_pedido_completo(
      v_cliente, 1000, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
      'ensayo 1050 F');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
    IF pg_temp.huella(v_ped, v_prod) <> 10 OR pg_temp.foto(v_prod) <> '{"stock":40,"lote":40,"bolsa":0}'::jsonb THEN
      RAISE EXCEPTION 'F/% · el pedido no salio del lote con huella: huella %, %',
        v_motivo, pg_temp.huella(v_ped, v_prod), pg_temp.foto(v_prod);
    END IF;

    v_res := public.registrar_salvedad(v_ped, v_item, CASE v_motivo WHEN 'parcial' THEN 4 ELSE 10 END,
                                       'cliente_rechaza', NULL, NULL, true, NULL);
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'F/% · registrar: %', v_motivo, v_res;
    END IF;
    v_salv := (v_res->>'salvedad_id')::bigint;
    IF pg_temp.huella(v_ped, v_prod) <> (CASE v_motivo WHEN 'parcial' THEN 6 ELSE 0 END) THEN
      RAISE EXCEPTION 'F/% · la salvedad no le saco la huella al cliente: %', v_motivo, pg_temp.huella(v_ped, v_prod);
    END IF;

    v_res := public.anular_salvedad(v_salv, 'ensayo 1050 F');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'F/% · anular: %', v_motivo, v_res;
    END IF;
    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":40,"lote":40,"bolsa":0}'::jsonb OR pg_temp.huella(v_ped, v_prod) <> 10
       OR NOT EXISTS (SELECT 1 FROM pedido_item_lotes pil JOIN pedido_items pi ON pi.id = pil.pedido_item_id
                       WHERE pi.pedido_id = v_ped AND pil.lote_id = v_lote_a AND pil.cantidad = 10) THEN
      v_fallas := v_fallas || format('F/%s · anular dejo %s y huella %s; tenia que ser {"stock":40,"lote":40,"bolsa":0} y 10 en el lote',
                                     v_motivo, v_foto, pg_temp.huella(v_ped, v_prod));
    END IF;
  END LOOP;

  -- -------------------------------------------------------------------------
  -- H · la huella es de la linea, no del pedido: dos lineas del mismo producto.
  --     Bolsa 24, lote 100 con 50. Linea A de 24 (sale de la bolsa) y linea B
  --     de 2 (sale del lote: huella B = 2). Salvedad de 5 sobre A: vuelve al
  --     lote, pero A no tenia huella ahi; la de B no se toca. Anular: A sigue
  --     sin huella y B con 2. Antes de #1050 la devolucion le sacaba la huella
  --     a B y la anulacion se la daba a A.
  -- -------------------------------------------------------------------------
  DECLARE
    v_a bigint;
    v_b bigint;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES ('ZZ ensayo 1050 H', 100, 74, 60, v_suc) RETURNING id INTO v_prod;
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, usuario_id)
    VALUES (v_prod, v_suc, v_hoy + 90, 100, 50, v_admin);
    v_res := public.crear_pedido_completo(
      v_cliente, 2600, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 24, 'precio_unitario', 100),
                        jsonb_build_object('producto_id', v_prod, 'cantidad', 2, 'precio_unitario', 100)),
      'ensayo 1050 H');
    v_ped := (v_res->>'pedido_id')::bigint;
    SELECT min(id), max(id) INTO v_a, v_b FROM pedido_items WHERE pedido_id = v_ped;
    IF (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b) <> 2
       OR (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_a) <> 0 THEN
      RAISE EXCEPTION 'H · el alta no dejo la huella esperada (A 0, B 2)';
    END IF;

    v_res := public.registrar_salvedad(v_ped, v_a, 5, 'cliente_rechaza', NULL, NULL, true, NULL);
    v_salv := (v_res->>'salvedad_id')::bigint;
    IF (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b) <> 2 THEN
      v_fallas := v_fallas || format('H · la salvedad sobre A le saco la huella a B: B quedo en %s',
        (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b));
    END IF;

    v_res := public.anular_salvedad(v_salv, 'ensayo 1050 H');
    IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'H · anular: %', v_res;
    END IF;
    IF (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_a) <> 0
       OR (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b) <> 2 THEN
      v_fallas := v_fallas || format('H · despues de anular la huella quedo A %s, B %s; tenia que ser A 0, B 2',
        (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_a),
        (SELECT COALESCE(SUM(cantidad), 0) FROM pedido_item_lotes WHERE pedido_item_id = v_b));
    END IF;
  END;

  -- -------------------------------------------------------------------------
  -- G · lotes_devueltos no se escribe por REST
  -- -------------------------------------------------------------------------
  DECLARE
    v_n int;
  BEGIN
    SET LOCAL ROLE authenticated;
    UPDATE salvedades_items SET lotes_devueltos = '[]'::jsonb WHERE id = v_salv;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RAISE EXCEPTION 'filas %', v_n USING ERRCODE = 'ZZ002';
  EXCEPTION
    WHEN SQLSTATE '42501' THEN
      IF SQLERRM NOT LIKE '%lotes_devueltos%' THEN
        v_fallas := v_fallas || format('G · error inesperado al escribir lotes_devueltos como authenticated: %s', SQLERRM);
      END IF;
    WHEN SQLSTATE 'ZZ002' THEN
      v_fallas := v_fallas || format('G · authenticated escribio lotes_devueltos (%s)', SQLERRM);
  END;

  -- -------------------------------------------------------------------------
  -- D · reintento: merma_registrada dice si hay merma
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1050 D', 100, 90, 60, v_suc) RETURNING id INTO v_prod;
  v_res := public.crear_pedido_completo(
    v_cliente, 1000, v_admin,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10, 'precio_unitario', 100)),
    'ensayo 1050 D');
  v_ped := (v_res->>'pedido_id')::bigint;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_prod;
  v_req := gen_random_uuid();

  -- La fila que deja una salvedad por dañado sobre un regalo que no mueve
  -- stock: motivo de merma, sin devolucion y sin fila en mermas_stock.
  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
    cantidad_entregada, motivo, monto_afectado, precio_unitario, reportado_por,
    stock_devuelto, estado_resolucion, sucursal_id, client_request_id, es_bonificacion
  ) VALUES (
    v_ped, v_item, v_prod, 10, 2, 8, 'producto_danado', 0, 0, v_admin,
    false, 'pendiente', v_suc, v_req, true
  ) RETURNING id INTO v_salv;

  v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
  IF NOT COALESCE((v_res->>'idempotent_replay')::boolean, false) THEN
    RAISE EXCEPTION 'D · el reintento no reconocio la salvedad: %', v_res;
  END IF;
  IF COALESCE((v_res->>'merma_registrada')::boolean, true) THEN
    v_fallas := v_fallas || format('D · el reintento dice merma_registrada = %s y no hay merma', v_res->>'merma_registrada');
  END IF;

  -- -------------------------------------------------------------------------
  -- E · reintento sin sesion / sin permiso / desde otra sucursal
  -- -------------------------------------------------------------------------
  -- (sigue usando la salvedad de D: tiene client_request_id)
  PERFORM set_config('request.jwt.claims', '{}', true);
  v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
  IF v_res ? 'salvedad_id' OR COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('E · sin sesion, el reintento devolvio los datos: %s', v_res);
  END IF;

  IF v_otro IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_otro)::text, true);
    v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
    IF v_res ? 'salvedad_id' OR COALESCE((v_res->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('E · un usuario sin permiso sobre el pedido recibio los datos: %s', v_res);
    END IF;
  ELSE
    v_fallas := v_fallas || 'E · no hay un usuario sin rol de entrega en la sucursal para probar el permiso'::text;
  END IF;

  IF v_suc2 IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc2::text)::text, true);
    v_res := public.registrar_salvedad(v_ped, v_item, 2, 'producto_danado', NULL, NULL, true, v_req);
    IF v_res ? 'salvedad_id' OR COALESCE((v_res->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('E · desde otra sucursal el reintento devolvio los datos: %s', v_res);
    END IF;
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1050-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo$;
