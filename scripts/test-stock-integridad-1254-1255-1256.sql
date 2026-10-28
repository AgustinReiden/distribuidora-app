-- Ensayo de #1254, #1255 y #1256: control de stock por diferencia, orden de
-- locks de los escritores de lotes y los checks nuevos de auditoria_integridad().
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-stock-integridad-1254-1255-1256.sql
--
--   1 · auditoria_integridad(): 69 checks sin ids repetidos; STK-A, STK-D,
--       CC-B, CC-C, FISCAL-A y VENTA-N una vez cada uno y en 0; STK-D high.
--   2 · aplicar_control_stock (#1254):
--       A · planilla S, se cuentan S-2, se venden 3 → queda S-5 (antes, S-2),
--           con el ajuste marcado como movido desde la descarga.
--       B · 2.5 contado, "5" como texto, sin stock_planilla y un producto
--           repetido: se rechaza todo, no se redondea ni se aplica la mitad.
--       C · un conteo que dejaría el stock negativo no se aplica: va a
--           rechazados y el stock no se mueve.
--       D · se procesa por id ascendente aunque la planilla venga al revés.
--   3 · lotes (#1255), con BOLSA > 0 (con bolsa 0 la bajada cae en el lote
--       por FEFO y da bien por casualidad, CLAUDE.md):
--       A · dar_de_baja_lote baja el lote y el stock, la bolsa no se mueve.
--       B · ajustar_lote sigue validando y ajustando.
--       C · _clampear_lotes_a_stock recorta el exceso al stock.
--       D · el producto se bloquea antes que el lote en los tres, y el control
--           de stock bloquea por id. El deadlock en sí pide dos conexiones (ver
--           test-concurrencia-pago-fifo.sql): esto mira el orden en el código.
--   4 · los checks muerden ante un caso NUEVO:
--       STK-A · una fila del ledger con created_at más viejo que la anterior
--               (dos cajas en el mismo milisegundo) no lo pone en rojo, y por
--               created_at sí lo habría puesto.
--       STK-D · un UPDATE de stock sin origen lo pone en rojo y tumba overall_ok.
--       CC-B  · un pedido de hace más de 30 días con monto_pagado <> Σ pagos.
--       CC-C  · monto_pagado > total.
--       FISCAL-A · una FC con neto + IVA <> total.
--       VENTA-N  · una línea con subtotal <> cantidad × precio.
--   5 · auditoria_lectura_authenticated(): ve la trampa de productos (los
--       costos no son legibles), trae las FKs compuestas, y sólo la ejecuta
--       service_role.

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_suc     bigint := 1;
  v_admin   uuid;
  v_quietos bigint[];  -- productos de v_suc sin ventas en 30 días, con stock
  v_p1      bigint;    -- control de stock: escenario de #1254
  v_p2      bigint;    -- control de stock: quedaría negativo
  v_p3      bigint;    -- lotes, con bolsa > 0
  v_p4      bigint;    -- STK-A / STK-D
  v_s       int;
  v_s2      int;
  v_lote    bigint;
  v_bolsa   int;
  v_bolsa2  int;
  v_ped_cc  bigint;
  v_ped_ccb bigint;
  v_ped_fc  bigint;
  v_linea   bigint;
  v_json    jsonb;
  v_aud     jsonb;
  v_def     text;
  v_n       int;
  v_m       int;
  v_id      bigint;
  v_err     text;
  r         record;
  k         text;
  -- Ids de check que tiene que tener la función (los 66 de antes + 3).
  v_nuevos  text[] := ARRAY['STK-A','STK-D','CC-B','CC-C','FISCAL-A','VENTA-N'];
BEGIN
  -- ------------------------------------------------- 1 · la función nueva ---
  v_aud := public.auditoria_integridad();
  IF (v_aud->>'total_checks')::int <> 69 THEN
    v_fallas := v_fallas || format('total_checks = %s (tienen que ser 69)', v_aud->>'total_checks');
  END IF;
  SELECT count(*) - count(DISTINCT c->>'id') INTO v_n FROM jsonb_array_elements(v_aud->'checks') c;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('%s id(s) de check repetidos', v_n);
  END IF;
  FOREACH k IN ARRAY v_nuevos LOOP
    SELECT count(*), max((c->>'violaciones')::int) INTO v_n, v_m
      FROM jsonb_array_elements(v_aud->'checks') c WHERE c->>'id' = k;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('%s aparece %s veces', k, v_n);
    ELSIF v_m <> 0 THEN
      v_fallas := v_fallas || format('%s = %s (tiene que estar en 0)', k, v_m);
    END IF;
  END LOOP;
  IF (SELECT c->>'severidad' FROM jsonb_array_elements(v_aud->'checks') c WHERE c->>'id' = 'STK-D') <> 'high' THEN
    v_fallas := v_fallas || 'STK-D no es high'::text;
  END IF;
  IF NOT (v_aud->>'overall_ok')::boolean THEN
    v_saltados := v_saltados || format('overall_ok ya venía en false: %s',
      (SELECT string_agg(c->>'id' || '=' || (c->>'violaciones'), ', ')
         FROM jsonb_array_elements(v_aud->'checks') c
        WHERE NOT (c->>'ok')::boolean AND c->>'severidad' IN ('critical','high')));
  END IF;

  -- ------------------------------------------------------------ datos -------
  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  -- Filas quietas: se bloquean hasta el final del DO (unos segundos).
  SELECT array_agg(p.id ORDER BY p.id) INTO v_quietos
    FROM (SELECT p.id FROM productos p
           WHERE p.sucursal_id = v_suc AND p.activo AND p.stock BETWEEN 12 AND 5000
             AND NOT EXISTS (SELECT 1 FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
                              WHERE pi.producto_id = p.id AND pe.created_at > now() - interval '30 days')
             AND p.stock - COALESCE((SELECT sum(l.cantidad_restante) FROM producto_lotes l
                                      WHERE l.producto_id = p.id AND l.sucursal_id = p.sucursal_id), 0) >= 6
           ORDER BY p.id LIMIT 4) p;
  IF COALESCE(array_length(v_quietos, 1), 0) < 4 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay 4 productos quietos con stock en la sucursal %', v_suc;
  END IF;
  v_p1 := v_quietos[1]; v_p2 := v_quietos[2]; v_p3 := v_quietos[3]; v_p4 := v_quietos[4];

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- ------------------------------------------ 2 · aplicar_control_stock ----
  -- A · se descarga con S, se cuentan S-2 y DESPUÉS se venden 3.
  SELECT stock INTO v_s FROM productos WHERE id = v_p1;
  PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
  UPDATE productos SET stock = stock - 3 WHERE id = v_p1;            -- la venta
  PERFORM set_config('app.stock_origen', '', true);
  SELECT stock INTO v_s2 FROM productos WHERE id = v_p2;

  EXECUTE 'SET LOCAL ROLE authenticated';
  v_json := public.aplicar_control_stock(jsonb_build_array(
    -- D · al revés de propósito: p2 > p1.
    jsonb_build_object('producto_id', v_p2::text, 'stock_real', 0, 'stock_planilla', v_s2 + 10),
    jsonb_build_object('producto_id', v_p1::text, 'stock_real', v_s - 2, 'stock_planilla', v_s),
    jsonb_build_object('producto_id', v_p3::text, 'stock_real', NULL, 'stock_planilla', 1)
  ), 'ensayo #1254');
  EXECUTE 'RESET ROLE';

  IF (SELECT stock FROM productos WHERE id = v_p1) <> v_s - 5 THEN
    v_fallas := v_fallas || format('#1254 A · el stock quedó en %s (S=%s: tiene que ser S-5 = %s; pisar daría S-2)',
      (SELECT stock FROM productos WHERE id = v_p1), v_s, v_s - 5);
  END IF;
  IF (v_json->'aplicados'->0->>'diferencia')::int IS DISTINCT FROM -2
     OR (v_json->'aplicados'->0->>'movido_desde_descarga')::boolean IS DISTINCT FROM true
     OR (v_json->>'movidos_desde_descarga')::int IS DISTINCT FROM 1 THEN
    v_fallas := v_fallas || format('#1254 A · el resultado no describe la diferencia: %s', v_json);
  END IF;
  SELECT * INTO r FROM stock_historico WHERE producto_id = v_p1 ORDER BY id DESC LIMIT 1;
  IF r.origen IS DISTINCT FROM 'control_stock' OR r.diferencia IS DISTINCT FROM -2
     OR r.referencia_id IS DISTINCT FROM (v_json->>'sesion_id')::bigint OR r.usuario_id IS DISTINCT FROM v_admin THEN
    v_fallas := v_fallas || format('#1254 A · ledger: origen=%s dif=%s ref=%s usuario=%s',
      r.origen, r.diferencia, r.referencia_id, r.usuario_id);
  END IF;
  -- C · p2: S2 + 10 en la planilla, 0 contados → S2 - (S2 + 10) < 0.
  IF (SELECT stock FROM productos WHERE id = v_p2) <> v_s2
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_json->'rechazados') x
                     WHERE (x->>'producto_id')::bigint = v_p2 AND x->>'motivo' = 'quedaria_negativo') THEN
    v_fallas := v_fallas || format('#1254 C · el conteo que deja negativo se aplicó o no se informó: %s', v_json->'rechazados');
  END IF;
  -- La fila sin conteo (p3) no se toca, y sólo hay un aplicado.
  IF jsonb_array_length(v_json->'aplicados') <> 1 OR (v_json->>'total_items')::int <> 1 THEN
    v_fallas := v_fallas || format('#1254 · aplicados de más: %s', v_json->'aplicados');
  END IF;

  -- B · nada de redondear ni de aplicar a medias.
  FOR r IN SELECT * FROM (VALUES
      ('2,5 contado',        jsonb_build_object('producto_id', v_p3::text, 'stock_real', 2.5, 'stock_planilla', 1), 'entero'),
      ('contado como texto', jsonb_build_object('producto_id', v_p3::text, 'stock_real', '5', 'stock_planilla', 1), 'número entero'),
      ('sin stock_planilla', jsonb_build_object('producto_id', v_p3::text, 'stock_real', 5), 'Stock Sistema'),
      ('negativo contado',   jsonb_build_object('producto_id', v_p3::text, 'stock_real', -1, 'stock_planilla', 1), 'mayor o igual a 0')
    ) t(caso, ajuste, espera)
  LOOP
    v_err := NULL;
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      PERFORM public.aplicar_control_stock(jsonb_build_array(
        jsonb_build_object('producto_id', v_p4::text, 'stock_real', 1, 'stock_planilla', 0), r.ajuste), NULL);
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    IF v_err IS NULL OR position(r.espera IN v_err) = 0 THEN
      v_fallas := v_fallas || format('#1254 B · %s: tenía que rechazar con "%s" y dio %s', r.caso, r.espera, COALESCE(v_err, 'OK'));
    END IF;
  END LOOP;
  v_err := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.aplicar_control_stock(jsonb_build_array(
      jsonb_build_object('producto_id', v_p4::text, 'stock_real', 1, 'stock_planilla', 0),
      jsonb_build_object('producto_id', v_p4, 'stock_real', 2, 'stock_planilla', 0)), NULL);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS NULL OR position('más de una vez' IN v_err) = 0 THEN
    v_fallas := v_fallas || format('#1254 B · producto repetido: dio %s', COALESCE(v_err, 'OK'));
  END IF;

  -- -------------------------------------------------------- 3 · lotes -------
  SELECT p.stock - COALESCE((SELECT sum(l.cantidad_restante) FROM producto_lotes l
                              WHERE l.producto_id = p.id AND l.sucursal_id = p.sucursal_id), 0), p.stock
    INTO v_bolsa, v_s
    FROM productos p WHERE p.id = v_p3;

  EXECUTE 'SET LOCAL ROLE authenticated';
  v_json := public.crear_lote_manual(v_p3, current_date + 400, 3);
  v_lote := (v_json->>'lote_id')::bigint;
  -- A · baja de 1 con la bolsa en v_bolsa - 3 > 0.
  v_json := public.dar_de_baja_lote(v_lote, 1, 'ensayo #1255');
  EXECUTE 'RESET ROLE';

  SELECT p.stock - COALESCE((SELECT sum(l.cantidad_restante) FROM producto_lotes l
                              WHERE l.producto_id = p.id AND l.sucursal_id = p.sucursal_id), 0)
    INTO v_bolsa2 FROM productos p WHERE p.id = v_p3;
  IF (SELECT cantidad_restante FROM producto_lotes WHERE id = v_lote) <> 2
     OR (SELECT stock FROM productos WHERE id = v_p3) <> v_s - 1
     OR v_bolsa2 <> v_bolsa - 3 THEN
    v_fallas := v_fallas || format('#1255 A · baja de lote: restante=%s stock=%s (de %s) bolsa=%s (tenía que quedar en %s)',
      (SELECT cantidad_restante FROM producto_lotes WHERE id = v_lote),
      (SELECT stock FROM productos WHERE id = v_p3), v_s, v_bolsa2, v_bolsa - 3);
  END IF;

  -- B · ajustar_lote: vuelve a 3; y 4 no entra (el lote nació con 3).
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_json := public.ajustar_lote(v_lote, 3);
  EXECUTE 'RESET ROLE';
  IF (SELECT cantidad_restante FROM producto_lotes WHERE id = v_lote) <> 3 THEN
    v_fallas := v_fallas || format('#1255 B · ajustar_lote no ajustó: %s', v_json);
  END IF;
  v_err := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.ajustar_lote(v_lote, 4);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  IF v_err IS NULL OR position('nacio con' IN v_err) = 0 THEN
    v_fallas := v_fallas || format('#1255 B · ajustar_lote por encima de lo que nació: dio %s', COALESCE(v_err, 'OK'));
  END IF;

  -- C · _clampear_lotes_a_stock: se infla el lote por encima del stock y se
  -- recorta exactamente el exceso.
  SELECT stock INTO v_s FROM productos WHERE id = v_p3;
  SELECT COALESCE(sum(cantidad_restante), 0) INTO v_n FROM producto_lotes WHERE producto_id = v_p3 AND sucursal_id = v_suc AND id <> v_lote;
  UPDATE producto_lotes SET cantidad = v_s + 5, cantidad_restante = v_s + 5 - v_n WHERE id = v_lote;
  v_m := public._clampear_lotes_a_stock(v_p3, v_suc);
  IF v_m <> 5 OR (SELECT sum(cantidad_restante) FROM producto_lotes WHERE producto_id = v_p3 AND sucursal_id = v_suc) <> v_s THEN
    v_fallas := v_fallas || format('#1255 C · _clampear recortó %s (tenía que ser 5) y los lotes suman %s (stock %s)',
      v_m, (SELECT sum(cantidad_restante) FROM producto_lotes WHERE producto_id = v_p3 AND sucursal_id = v_suc), v_s);
  END IF;

  -- D · el orden en el código.
  FOREACH k IN ARRAY ARRAY['public.dar_de_baja_lote(bigint,integer,text)', 'public.ajustar_lote(bigint,integer)'] LOOP
    v_def := pg_get_functiondef(k::regprocedure);
    v_n := regexp_instr(v_def, 'FROM public\.productos\s+WHERE id = v_producto_id AND sucursal_id = v_sucursal\s+FOR UPDATE');
    v_m := regexp_instr(v_def, 'FROM public\.producto_lotes\s+WHERE id = p_lote_id AND sucursal_id = v_sucursal\s+FOR UPDATE');
    IF v_n = 0 OR v_m = 0 OR v_n > v_m THEN
      v_fallas := v_fallas || format('#1255 D · %s no bloquea el producto antes que el lote (producto en %s, lote en %s)', k, v_n, v_m);
    END IF;
  END LOOP;
  v_def := pg_get_functiondef('public._clampear_lotes_a_stock(bigint,bigint)'::regprocedure);
  IF regexp_instr(v_def, 'FROM public\.productos\s+WHERE id = p_producto_id AND sucursal_id = p_sucursal_id\s+FOR UPDATE') = 0 THEN
    v_fallas := v_fallas || '#1255 D · _clampear_lotes_a_stock no bloquea el producto'::text;
  END IF;
  v_def := pg_get_functiondef('public.aplicar_control_stock(jsonb,text)'::regprocedure);
  v_n := regexp_instr(v_def, 'FROM productos\s+WHERE sucursal_id = v_sucursal_id AND id = ANY\([^;]*ORDER BY id\s+FOR UPDATE');
  v_m := regexp_instr(v_def, 'UPDATE productos SET stock');
  IF v_n = 0 OR v_n > v_m THEN
    v_fallas := v_fallas || format('#1255 D · aplicar_control_stock no bloquea por id antes de mover (lock en %s, update en %s)', v_n, v_m);
  END IF;

  -- -------------------------------------------- 4 · los checks muerden ------
  -- Como postgres y sin contexto de stock: set_config es por transacción, y lo
  -- que dejaron las funciones de arriba (origen, referencia) etiquetaría el
  -- movimiento sin origen de STK-D.
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);

  -- STK-A · dos movimientos del mismo producto; el segundo queda con un
  -- created_at más viejo que el primero, como dos cajas en el mismo
  -- milisegundo. Por id está bien; por created_at, rojo.
  PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
  UPDATE productos SET stock = stock - 1 WHERE id = v_p4;
  UPDATE productos SET stock = stock - 1 WHERE id = v_p4;
  PERFORM set_config('app.stock_origen', '', true);
  SELECT max(id) INTO v_id FROM stock_historico WHERE producto_id = v_p4;
  UPDATE stock_historico SET created_at = created_at - interval '1 second' WHERE id = v_id;
  SELECT count(*) INTO v_n FROM productos p JOIN (SELECT DISTINCT ON (producto_id, sucursal_id) producto_id, sucursal_id, stock_nuevo
      FROM stock_historico WHERE producto_id = v_p4 ORDER BY producto_id, sucursal_id, created_at DESC, id DESC) u
      ON u.producto_id = p.id AND u.sucursal_id = p.sucursal_id WHERE p.stock <> u.stock_nuevo;
  IF v_n <> 1 THEN
    v_saltados := v_saltados || 'STK-A: el desorden simulado no rompía el orden viejo'::text;
  END IF;

  -- STK-D · un movimiento sin origen, como postgres: 'auto' sin referencia.
  UPDATE productos SET stock = stock + 1 WHERE id = v_p4;

  -- CC-C y CC-B · dos pedidos viejos (más de 30 días: el CC-B de antes no los
  -- miraba), entregados, no VB, con pagos y monto_pagado = Σ pagos (eso deja
  -- afuera a los 67 legacy, que no tienen filas en pagos). Sobrepagar el
  -- primero también lo descuadra con sus pagos: CC-B tiene que contar los dos.
  SELECT p.id INTO v_ped_cc FROM pedidos p
   WHERE p.estado = 'entregado' AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB' AND p.total > 10
     AND p.created_at < now() - interval '60 days' AND p.sucursal_id = v_suc
     AND EXISTS (SELECT 1 FROM pagos pg WHERE pg.pedido_id = p.id)
     AND COALESCE(p.monto_pagado, 0) = (SELECT sum(pg.monto) FROM pagos pg WHERE pg.pedido_id = p.id)
   ORDER BY p.id LIMIT 1;
  SELECT p.id INTO v_ped_ccb FROM pedidos p
   WHERE p.estado = 'entregado' AND COALESCE(p.tipo_factura, 'ZZ') <> 'VB'
     AND p.total - COALESCE(p.monto_pagado, 0) >= 1
     AND p.created_at < now() - interval '60 days' AND p.sucursal_id = v_suc AND p.id <> v_ped_cc
     AND COALESCE(p.monto_pagado, 0) = COALESCE((SELECT sum(pg.monto) FROM pagos pg WHERE pg.pedido_id = p.id), 0)
   ORDER BY p.id LIMIT 1;
  SELECT id INTO v_ped_fc FROM pedidos WHERE tipo_factura = 'FC' AND estado NOT IN ('cancelado', 'anulado') AND total > 0
   ORDER BY id LIMIT 1;
  SELECT pi.id INTO v_linea FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id
   WHERE p.estado = 'entregado' AND p.created_at < now() - interval '60 days' AND NOT pi.es_bonificacion
   ORDER BY pi.id LIMIT 1;

  BEGIN
    UPDATE pedidos SET monto_pagado = total + 1 WHERE id = v_ped_cc;
  EXCEPTION WHEN OTHERS THEN
    v_saltados := v_saltados || format('CC-C: no se pudo sobrepagar el pedido %s (%s)', v_ped_cc, SQLERRM);
  END;
  BEGIN
    UPDATE pedidos SET monto_pagado = COALESCE(monto_pagado, 0) + 1 WHERE id = v_ped_ccb;
  EXCEPTION WHEN OTHERS THEN
    v_saltados := v_saltados || format('CC-B: no se pudo mover monto_pagado del pedido %s (%s)', v_ped_ccb, SQLERRM);
  END;
  IF v_ped_fc IS NULL THEN
    v_saltados := v_saltados || 'FISCAL-A: no hay pedidos FC'::text;
  ELSE
    BEGIN
      UPDATE pedidos SET total_iva = COALESCE(total_iva, 0) + 1 WHERE id = v_ped_fc;
    EXCEPTION WHEN OTHERS THEN
      v_saltados := v_saltados || format('FISCAL-A: no se pudo mover el IVA del pedido %s (%s)', v_ped_fc, SQLERRM);
    END;
  END IF;
  BEGIN
    UPDATE pedido_items SET subtotal = subtotal + 1 WHERE id = v_linea;
  EXCEPTION WHEN OTHERS THEN
    v_saltados := v_saltados || format('VENTA-N: no se pudo mover el subtotal de la línea %s (%s)', v_linea, SQLERRM);
  END;

  v_aud := public.auditoria_integridad();
  FOR r IN SELECT * FROM (VALUES ('STK-A', 0), ('STK-D', 1), ('CC-B', 2), ('CC-C', 1), ('FISCAL-A', 1), ('VENTA-N', 1)) t(id, espera) LOOP
    SELECT (c->>'violaciones')::int INTO v_n FROM jsonb_array_elements(v_aud->'checks') c WHERE c->>'id' = r.id;
    IF v_n IS DISTINCT FROM r.espera THEN
      v_fallas := v_fallas || format('%s = %s después del caso nuevo (tenía que dar %s)', r.id, v_n, r.espera);
    END IF;
  END LOOP;
  IF (v_aud->>'overall_ok')::boolean THEN
    v_fallas := v_fallas || 'overall_ok sigue en true con STK-D en rojo'::text;
  END IF;

  -- ---------------------------- 5 · auditoria_lectura_authenticated() -------
  v_json := public.auditoria_lectura_authenticated();
  IF NOT (v_json->'tablas'->'productos'->'columnas') ? 'costo_real'
     OR (v_json->'tablas'->'productos'->'legibles') ? 'costo_real'
     OR NOT (v_json->'tablas'->'productos'->'legibles') ? 'nombre' THEN
    v_fallas := v_fallas || 'lectura · productos: costo_real tiene que estar en columnas y no en legibles, nombre en legibles'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_json->'fks') f
                  WHERE f->>'nombre' = 'pedidos_cliente_id_fkey' AND f->>'ref_tabla' = 'clientes'
                    AND jsonb_array_length(f->'columnas') = 2) THEN
    v_fallas := v_fallas || 'lectura · falta la FK compuesta pedidos_cliente_id_fkey'::text;
  END IF;
  IF has_function_privilege('anon', 'public.auditoria_lectura_authenticated()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_lectura_authenticated()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.auditoria_lectura_authenticated()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'lectura · tiene que ejecutarla sólo service_role'::text;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);

  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · % | saltados: %', array_to_string(v_fallas, ' | '),
      COALESCE(array_to_string(v_saltados, ' | '), '-');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · control de stock por diferencia, locks producto→lote, 69 checks y los seis mordiendo | saltados: %',
    COALESCE(NULLIF(array_to_string(v_saltados, ' | '), ''), '-');
END
$ensayo$;
