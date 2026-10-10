-- Ensayo de #1043: los siete checks de auditoria_integridad() que estaban en
-- rojo quedan en cero, y siguen mordiendo ante un caso NUEVO.
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
--   psql "$DATABASE_URL" -f scripts/test-checks-1043.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_suc     bigint := 1;
  v_admin   uuid;    -- admin de v_suc
  v_prod    bigint;  -- producto activo de v_suc con stock
  v_compra  bigint;  -- compra de v_suc con un renglón todavía acreditable
  v_prod_nc bigint;  -- producto de ese renglón, con stock
  v_promo   bigint;  -- promoción de v_suc con usos pendientes
  v_pedido  bigint;
  v_id      bigint;
  v_antes   int;
  v_despues int;
  v_json    jsonb;
  r         record;
  k         text;
BEGIN
  -- ----------------------------------------------------------- 1 · en cero ---
  FOREACH k IN ARRAY ARRAY['MERMA-I','COMPRA-A2','COMIS-01','COSTO-B','VENTA-I','VENTA-J','STK-D'] LOOP
    SELECT count(*), max((c->>'violaciones')::int) INTO v_antes, v_despues
      FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c
     WHERE c->>'id' = k;
    IF v_antes <> 1 THEN
      v_fallas := v_fallas || format('%s aparece %s veces en auditoria_integridad()', k, v_antes);
    ELSIF v_despues <> 0 THEN
      v_fallas := v_fallas || format('%s = %s (tiene que estar en 0)', k, v_despues);
    END IF;
  END LOOP;

  -- ------------------------------------------------------------ datos -------
  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  -- Los canarios bloquean sus filas hasta el final del DO (unos segundos): se
  -- eligen filas quietas, sin ventas recientes, para no trabar a nadie.
  SELECT p.id INTO v_prod FROM productos p
   WHERE p.sucursal_id = v_suc AND p.activo AND p.stock > 5
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
                      WHERE pi.producto_id = p.id AND pe.created_at > now() - interval '30 days')
   ORDER BY p.id LIMIT 1;

  SELECT ci.compra_id, ci.producto_id INTO v_compra, v_prod_nc
    FROM compra_items ci
    JOIN compras c ON c.id = ci.compra_id AND c.estado <> 'cancelada'
    JOIN productos p ON p.id = ci.producto_id AND p.sucursal_id = c.sucursal_id AND p.stock > 0
   WHERE c.sucursal_id = v_suc
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
                      WHERE pi.producto_id = p.id AND pe.created_at > now() - interval '30 days')
     AND ci.cantidad > COALESCE((SELECT sum(nci.cantidad) FROM nota_credito_items nci
                                   JOIN notas_credito nc ON nc.id = nci.nota_credito_id
                                  WHERE nc.compra_id = c.id AND nci.producto_id = ci.producto_id), 0)
   ORDER BY c.id LIMIT 1;

  SELECT id INTO v_promo FROM promociones
   WHERE sucursal_id = v_suc AND COALESCE(usos_pendientes, 0) > 0 ORDER BY id LIMIT 1;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- ------------------------------- 2 · la ficha de producto (REST directo) ---
  -- Un UPDATE de stock por PostgREST no puede setear app.stock_origen. Antes
  -- quedaba 'auto', sin usuario; ahora es 'ajuste_manual' de quien lo hizo.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  UPDATE productos SET stock = stock + 1 WHERE id = v_prod AND sucursal_id = v_suc;
  EXECUTE 'RESET ROLE';
  SELECT * INTO r FROM stock_historico WHERE producto_id = v_prod ORDER BY id DESC LIMIT 1;
  IF r.origen IS DISTINCT FROM 'ajuste_manual' OR r.usuario_id IS DISTINCT FROM v_admin THEN
    v_fallas := v_fallas || format('ficha · el UPDATE por REST quedó origen=%s, usuario=%s', r.origen, r.usuario_id);
  END IF;

  -- -------------------------------------- 3 · registrar_nota_credito ------
  IF v_compra IS NULL THEN
    v_saltados := v_saltados || 'registrar_nota_credito: no hay renglón acreditable con stock'::text;
  ELSE
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.registrar_nota_credito(v_compra, 'ENSAYO-1043', 'ensayo #1043', 0, 0, 1, v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_prod_nc, 'cantidad', 1,
                                           'costo_unitario', 1, 'subtotal', 1)), 0);
    EXECUTE 'RESET ROLE';
    IF NOT COALESCE((v_json->>'success')::boolean, false) THEN
      v_saltados := v_saltados || format('registrar_nota_credito no corrió: %s', v_json);
    ELSE
      SELECT * INTO r FROM stock_historico WHERE producto_id = v_prod_nc ORDER BY id DESC LIMIT 1;
      IF r.origen IS DISTINCT FROM 'nota_credito' OR r.referencia_tipo IS DISTINCT FROM 'notas_credito'
         OR r.referencia_id IS DISTINCT FROM (v_json->>'nota_credito_id')::bigint
         OR r.usuario_id IS DISTINCT FROM v_admin THEN
        v_fallas := v_fallas || format('registrar_nota_credito · origen=%s, ref=%s/%s, usuario=%s',
          r.origen, r.referencia_tipo, r.referencia_id, r.usuario_id);
      END IF;
    END IF;
  END IF;

  -- ---------------------------------- 4 · ajustar_stock_promocion_completo --
  IF v_promo IS NULL THEN
    v_saltados := v_saltados || 'ajustar_stock_promocion_completo: no hay promoción con usos pendientes'::text;
  ELSE
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_json := public.ajustar_stock_promocion_completo(v_promo, v_prod, 1, 1, v_admin, 'ensayo #1043');
    EXECUTE 'RESET ROLE';
    IF NOT COALESCE((v_json->>'success')::boolean, false) THEN
      v_saltados := v_saltados || format('ajustar_stock_promocion_completo no corrió: %s', v_json);
    ELSE
      SELECT * INTO r FROM stock_historico WHERE producto_id = v_prod ORDER BY id DESC LIMIT 1;
      IF r.origen IS DISTINCT FROM 'ajuste_promo' OR r.referencia_tipo IS DISTINCT FROM 'mermas_stock'
         OR r.referencia_id IS DISTINCT FROM (v_json->>'merma_id')::bigint
         OR r.usuario_id IS DISTINCT FROM v_admin THEN
        v_fallas := v_fallas || format('ajustar_stock_promocion_completo · origen=%s, ref=%s/%s, usuario=%s',
          r.origen, r.referencia_tipo, r.referencia_id, r.usuario_id);
      END IF;
    END IF;
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);

  -- ------------------------------ 5 · cada check muerde ante un caso nuevo --
  -- Cada canario corre en un sub-bloque que se deshace solo con un SQLSTATE
  -- centinela; se mide el delta del check, no su valor absoluto.

  -- STK-D · una función de servidor que mueve stock sin declarar el origen.
  BEGIN
    SELECT (c->>'violaciones')::int INTO v_antes FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='STK-D';
    UPDATE productos SET stock = stock + 1 WHERE id = v_prod;
    SELECT (c->>'violaciones')::int INTO v_despues FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='STK-D';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('STK-D no ve un movimiento nuevo sin origen (%s → %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;

  -- MERMA-I · una merma real sin usuario.
  BEGIN
    SELECT (c->>'violaciones')::int INTO v_antes FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='MERMA-I';
    UPDATE mermas_stock SET usuario_id = NULL
     WHERE id = (SELECT min(id) FROM mermas_stock WHERE usuario_id IS NOT NULL AND motivo NOT IN ('promociones','promociones_reversion'));
    SELECT (c->>'violaciones')::int INTO v_despues FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='MERMA-I';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('MERMA-I no ve una merma nueva sin usuario (%s → %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;

  -- COMPRA-A2 · una compra nueva con la cabecera desfasada de sus renglones.
  BEGIN
    SELECT (c->>'violaciones')::int INTO v_antes FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='COMPRA-A2';
    UPDATE compras SET subtotal = subtotal + 100
     WHERE id = (SELECT min(c.id) FROM compras c WHERE c.estado <> 'cancelada'
                    AND abs(COALESCE(c.subtotal, 0) - (SELECT sum(ci.subtotal) FROM compra_items ci
                                                          WHERE ci.compra_id = c.id)) <= 1.0);
    SELECT (c->>'violaciones')::int INTO v_despues FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='COMPRA-A2';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('COMPRA-A2 no ve una compra nueva desfasada (%s → %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;

  -- COMIS-01 · una venta entregada que pierde el vendedor.
  BEGIN
    SELECT (c->>'violaciones')::int INTO v_antes FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='COMIS-01';
    UPDATE pedidos SET usuario_id = NULL
     WHERE id = (SELECT min(id) FROM pedidos WHERE estado = 'entregado' AND canal = 'app' AND usuario_id IS NOT NULL);
    SELECT (c->>'violaciones')::int INTO v_despues FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='COMIS-01';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('COMIS-01 no ve una venta nueva sin vendedor (%s → %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;

  -- COSTO-B · un producto vendido cuya línea y ficha se quedan sin costo:
  -- costo_valuacion(...) IS NULL, el predicado canónico de "sin costo".
  BEGIN
    SELECT (c->>'violaciones')::int INTO v_antes FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='COSTO-B';
    SELECT pi.producto_id INTO v_id
      FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id
     WHERE p.estado = 'entregado' AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
       AND NOT pi.es_bonificacion AND pi.producto_id <> 186
       AND NOT EXISTS (SELECT 1 FROM pedido_items x JOIN pedidos xp ON xp.id = x.pedido_id
                        WHERE x.producto_id = pi.producto_id AND xp.created_at > now() - interval '30 days')
     ORDER BY pi.id LIMIT 1;
    UPDATE pedido_items SET costo_unitario_al_crear = NULL WHERE producto_id = v_id;
    UPDATE productos SET costo_promedio = NULL, costo_real = NULL, costo_sin_iva = NULL WHERE id = v_id;
    SELECT (c->>'violaciones')::int INTO v_despues FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='COSTO-B';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('COSTO-B no ve un producto nuevo vendido sin costo (%s → %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_saltados := v_saltados || format('canario COSTO-B: %s', SQLERRM);
  END;

  -- VENTA-I · un cancelado nuevo con un total distinto de 0.
  BEGIN
    SELECT (c->>'violaciones')::int INTO v_antes FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='VENTA-I';
    UPDATE pedidos SET total_neto = 1
     WHERE id = (SELECT min(id) FROM pedidos WHERE estado = 'cancelado' AND total = 0
                    AND COALESCE(total_neto, 0) = 0 AND COALESCE(total_iva, 0) = 0
                    AND COALESCE(total_real, 0) = 0);
    SELECT (c->>'violaciones')::int INTO v_despues FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='VENTA-I';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('VENTA-I no ve un cancelado nuevo con total (%s → %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_saltados := v_saltados || format('canario VENTA-I: %s', SQLERRM);
  END;

  -- VENTA-J · una venta entregada sin ítems. El canje (canal 'cambio') nace sin
  -- ítems por diseño y no cuenta; el mismo pedido como venta, sí.
  BEGIN
    SELECT (c->>'violaciones')::int INTO v_antes FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='VENTA-J';
    SELECT min(p.id) INTO v_pedido FROM pedidos p
     WHERE p.estado = 'entregado' AND p.canal = 'cambio'
       AND NOT EXISTS (SELECT 1 FROM pedido_items pi WHERE pi.pedido_id = p.id);
    IF v_pedido IS NULL THEN
      RAISE EXCEPTION 'no hay un canje entregado para el canario';
    END IF;
    UPDATE pedidos SET canal = 'app' WHERE id = v_pedido;
    SELECT (c->>'violaciones')::int INTO v_despues FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id'='VENTA-J';
    IF v_despues - v_antes <> 1 THEN
      v_fallas := v_fallas || format('VENTA-J no ve una venta entregada sin ítems (%s → %s)', v_antes, v_despues);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_saltados := v_saltados || format('canario VENTA-J: %s', SQLERRM);
  END;

  -- ------------------------------------------------------------ veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · % | saltados: %', array_to_string(v_fallas, ' | '),
      COALESCE(NULLIF(array_to_string(v_saltados, ' | '), ''), 'ninguno');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · los siete checks en 0 y mordiendo; ficha, nota de crédito y ajuste de promo con origen | saltados: %',
    COALESCE(NULLIF(array_to_string(v_saltados, ' | '), ''), 'ninguno');
END;
$ensayo$;
