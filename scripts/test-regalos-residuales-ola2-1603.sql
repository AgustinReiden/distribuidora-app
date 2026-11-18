-- Ensayo de la migración de la ola 2 del plan #1603, tanda 5, tarjeta C2:
-- migrations/NNN_regalos_tope_por_corte_y_factor_sin_stock.sql
--
-- Dos residuales de regalos y promos:
--   P1 · PRM-1 residual (#1592; H3 de la revisión de B4). Promo 2 V → 1 R (mueve stock); el pedido
--        lleva V×20 + R×10 y un admin cambió el regalo por valor a W×1 (W vale lo que 10 R, mismo
--        rubro): la línea queda W×1 con corte 10.
--        P1a · el encargado edita sin bajar la venta y manda W×1: entra (corte 10, tope 10).
--        P1b · el encargado baja la venta a V×10 (le tocan R×5) y manda W×1: se rechaza con el
--              motivo, y el pedido queda como estaba. Antes entraba con un regalo de R×10.
--        P1c · regresión: el mismo encargado manda R×10 (la unidad de la promo): se rechaza.
--        P1d · regresión: el admin baja la venta y manda W×1: entra (el admin no tiene tope).
--   P2 · PRM-2 residual (#1592; N2 de la revisión de B1). Promo de fracción (R cada 10 V, factor
--        12, contenedor K1) con tres pedidos entregados que cerraron un bloque en K1; el admin la
--        pasa a factor 4 con contenedor K2 (stock 1). Una salvedad del regalo de un pedido abre el
--        bloque (K1 vuelve a 50) y el recierre sólo puede cerrar uno en K2: la barra queda en 4,
--        pasada de N, con K2 en 0.
--        P2a · el admin cambia el factor a 2 por un UPDATE directo (un bundle anterior a la 472): se
--              rechaza (23514, productos_stock_no_negativo) con el motivo y el nombre de K2, y K2,
--              la barra y el factor quedan como estaban. Antes: el texto crudo del CHECK.
--        P2b · con K2 en 1 (los bloques piden 2): igual, «hay 1».
--        P2c · regresión: con K2 en 2 el cambio entra, cierra los dos bloques (K2 0, barra 0).
--        P2d · regresión: por la RPC del front (cambiar_regalo_promocion con p_datos), con K2 en 0,
--              vuelve {success: false, codigo: contenedor_sin_stock} con el nombre del contenedor.
--   A1 · ningún check de auditoria_integridad() suma violaciones.
--
-- Sin la migración tiene que FALLAR en P1b, P2a y P2b. P1a, P1c, P1d, P2c y P2d son regresión.
-- Corre contra una base con el schema de prod SIN dejar rastro (salvo valores de secuencia): un
-- único DO que termina SIEMPRE en una excepción. Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …'.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-regalos-residuales-ola2-1603.sql

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_enc    uuid;
  v_cli    bigint;
  vv       bigint;
  r        bigint;
  w        bigint;
  k1       bigint;
  k2       bigint;
  v_promo  bigint;
  v_x      bigint;
  v_p      bigint[];
  v_it     bigint;
  v_j      jsonb;
  v_res    text;
  v_antes  jsonb;
  v_checks jsonb;
  v_fallas text[] := '{}';
  k        text;
  i        int;
BEGIN
  SET LOCAL lock_timeout = '5s';
  SET CONSTRAINTS ALL IMMEDIATE;

  -- ------------------------------------------------------------- personas ---
  SELECT us.sucursal_id, us.usuario_id INTO v_suc, v_adm
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.activo AND pf.rol = 'admin'
    JOIN sucursales su ON su.id = us.sucursal_id AND su.activa
   ORDER BY us.sucursal_id, us.usuario_id
   LIMIT 1;
  IF v_adm IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de una sucursal activa';
  END IF;
  -- Un encargado propio de esa sucursal (el alta de auth.users lo deja con su perfil y su sucursal).
  v_enc := gen_random_uuid();
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_enc, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'c2-' || v_enc || '@ensayo.invalid', jsonb_build_object('rol', 'encargado', 'sucursal_id', v_suc),
          jsonb_build_object('nombre', 'ZZ ensayo C2 encargado'), now(), now());
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = v_enc AND rol = 'encargado' AND activo)
     OR NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_enc AND sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: el alta del encargado no le dejó perfil o sucursal';
  END IF;
  PERFORM set_config('e1603c2.suc', v_suc::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo C2', 'ZZ ensayo C2', 'calle 1', v_suc) RETURNING id INTO v_cli;

  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_antes
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;

  -- ---------------------------------------------------------------- helpers -
  -- Actuar como p_uid en la sucursal del ensayo.
  CREATE FUNCTION pg_temp.como(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', current_setting('e1603c2.suc'))::text, true);
  END $f$;

  -- Un producto con lotes [{dias, cantidad, restante}] y p_bolsa unidades sin lote.
  CREATE FUNCTION pg_temp.prod(p_lotes jsonb, p_bolsa int, p_precio numeric DEFAULT 100) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_prod bigint; l jsonb; v_s bigint := current_setting('e1603c2.suc')::bigint;
  BEGIN
    INSERT INTO productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva,
                           sucursal_id, categoria)
    VALUES ('ZZ ensayo C2 ' || gen_random_uuid(), p_precio,
            p_bolsa + (SELECT COALESCE(SUM((x->>'restante')::int), 0) FROM jsonb_array_elements(p_lotes) x),
            60, 60, 60, 60, v_s, 'ZZ ensayo C2 cat') RETURNING id INTO v_prod;
    FOR l IN SELECT * FROM jsonb_array_elements(p_lotes) LOOP
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
      VALUES (v_prod, v_s, public._tablero_hoy() + (l->>'dias')::int,
              (l->>'cantidad')::int, (l->>'restante')::int, 'manual');
    END LOOP;
    RETURN v_prod;
  END $f$;

  -- El stock, los lotes y el ledger de un producto cierran entre sí. '{}' si cierran.
  CREATE FUNCTION pg_temp.cierra(p_caso text, p_prod bigint) RETURNS text[] LANGUAGE sql AS $f$
    SELECT ARRAY(
      SELECT format('%s: %s', p_caso, m) FROM (
        SELECT 'la última fila del ledger no es el stock' AS m
         WHERE (SELECT stock_nuevo FROM stock_historico WHERE producto_id = p_prod ORDER BY id DESC LIMIT 1)
               IS DISTINCT FROM (SELECT stock FROM productos WHERE id = p_prod)
           AND EXISTS (SELECT 1 FROM stock_historico WHERE producto_id = p_prod)
        UNION ALL
        SELECT format('la fila %s del ledger arranca en %s y la anterior terminó en %s', x.id, x.stock_anterior, x.prev)
          FROM (SELECT id, stock_anterior, lag(stock_nuevo) OVER (ORDER BY id) AS prev
                  FROM stock_historico WHERE producto_id = p_prod) x
         WHERE x.prev IS NOT NULL AND x.prev <> x.stock_anterior
        UNION ALL
        SELECT 'los lotes suman más que el stock'
         WHERE (SELECT COALESCE(sum(cantidad_restante), 0) FROM producto_lotes WHERE producto_id = p_prod)
               > (SELECT stock FROM productos WHERE id = p_prod)) z);
  $f$;

  CREATE FUNCTION pg_temp.it(p_prod bigint, p_cant int) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
  $f$;
  CREATE FUNCTION pg_temp.reg(p_prod bigint, p_cant int, p_promo bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                              'es_bonificacion', true, 'promocion_id', p_promo);
  $f$;

  -- Las llamadas pisan GUCs de stock por transacción: se limpian entre una y otra.
  CREATE FUNCTION pg_temp.limpiar() RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('app.stock_origen', '', true);
    PERFORM set_config('app.stock_ref_tipo', '', true);
    PERFORM set_config('app.stock_ref_id', '', true);
    PERFORM set_config('app.stock_user_id', '', true);
    PERFORM set_config('app.stock_pedido_item_id', '', true);
  END $f$;

  CREATE FUNCTION pg_temp.alta(p_cli bigint, p_adm uuid, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v jsonb; v_tot numeric;
  BEGIN
    PERFORM pg_temp.como(p_adm);
    SELECT COALESCE(SUM((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
      FROM jsonb_array_elements(p_items) e;
    v := public.crear_pedido_completo(p_cli, v_tot, p_adm, p_items, 'ensayo C2');
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'alta: %', v; END IF;
    RETURN (v->>'pedido_id')::bigint;
  END $f$;

  -- La edición como p_uid; devuelve 'ok' o el rechazo.
  CREATE FUNCTION pg_temp.editar(p_ped bigint, p_uid uuid, p_items jsonb) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_uid);
    v := public.actualizar_pedido_items(p_ped, p_items, p_uid, NULL, NULL);
    PERFORM pg_temp.limpiar();
    IF COALESCE((v->>'success')::boolean, false) THEN RETURN 'ok'; END IF;
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.limpiar();
    RETURN SQLERRM;
  END $f$;

  -- Suma unidades a la bolsa (origen fuera de la lista blanca).
  CREATE FUNCTION pg_temp.bolsa(p_prod bigint, n int) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
    UPDATE productos SET stock = stock + n WHERE id = p_prod;
    PERFORM pg_temp.limpiar();
  END $f$;

  -- Cambia el factor por un UPDATE directo (como un bundle anterior a la 472); 'ok' o 'SQLSTATE restricción mensaje'.
  CREATE FUNCTION pg_temp.factor(p_promo bigint, p_n int) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v_c text;
  BEGIN
    UPDATE promociones SET unidades_por_bloque = p_n WHERE id = p_promo;
    RETURN 'ok';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_c = CONSTRAINT_NAME;
    RETURN SQLSTATE || ' ' || COALESCE(v_c, '-') || ' ' || SQLERRM;
  END $f$;

  -- Los regalos del pedido: 'prod×cant/corte'.
  CREATE FUNCTION pg_temp.regalos(p_ped bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(format('%s×%s/%s', producto_id, cantidad, regalo_corte), ' ' ORDER BY id), '-')
      FROM pedido_items WHERE pedido_id = p_ped AND es_bonificacion;
  $f$;

  -- ==================================================================== P1 ===
  BEGIN
    vv := pg_temp.prod('[]', 500);
    r  := pg_temp.prod('[]', 500);
    w  := pg_temp.prod('[]', 500, 1000);
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id, limite_usos)
    VALUES ('ZZ ensayo C2 2V1R', 'bonificacion', public._tablero_hoy() - 1, v_suc, true, r, 100) RETURNING id INTO v_promo;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_promo, 'cantidad_compra', 2, v_suc), (v_promo, 'cantidad_bonificacion', 1, v_suc);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, vv, v_suc);
    v_x := pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(vv, 20), pg_temp.reg(r, 10, v_promo)));
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = v_x AND es_bonificacion);
    PERFORM pg_temp.como(v_adm);
    v_j := public.sustituir_regalo_pedido(v_it, w, 1, 'ensayo C2', NULL, NULL);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN RAISE EXCEPTION 'sustituir: %', v_j; END IF;
    IF pg_temp.regalos(v_x) <> w || '×1/10' THEN
      RAISE EXCEPTION 'la sustitución dejó %', pg_temp.regalos(v_x);
    END IF;

    v_res := pg_temp.editar(v_x, v_enc, jsonb_build_array(pg_temp.it(vv, 20), pg_temp.reg(w, 1, v_promo)));
    IF v_res <> 'ok' OR pg_temp.regalos(v_x) <> w || '×1/10' THEN
      v_fallas := v_fallas || format('P1a el encargado sin bajar la venta, W×1: %s | %s', v_res, pg_temp.regalos(v_x));
    END IF;

    v_res := pg_temp.editar(v_x, v_enc, jsonb_build_array(pg_temp.it(vv, 10), pg_temp.reg(w, 1, v_promo)));
    IF v_res = 'ok' OR position('cuenta, para el tope de la promo' IN v_res) = 0
       OR position('no puede pasar de 5' IN v_res) = 0 THEN
      v_fallas := v_fallas || format('P1b el encargado baja la venta a V×10 y manda W×1: %s', left(v_res, 220));
    END IF;
    IF pg_temp.regalos(v_x) <> w || '×1/10'
       OR (SELECT cantidad FROM pedido_items WHERE pedido_id = v_x AND producto_id = vv) <> 20 THEN
      v_fallas := v_fallas || format('P1b el pedido cambió: %s, V×%s', pg_temp.regalos(v_x),
                                     (SELECT cantidad FROM pedido_items WHERE pedido_id = v_x AND producto_id = vv));
    END IF;

    v_res := pg_temp.editar(v_x, v_enc, jsonb_build_array(pg_temp.it(vv, 10), pg_temp.reg(r, 10, v_promo)));
    IF v_res = 'ok' OR position('no puede pasar de 5' IN v_res) = 0 THEN
      v_fallas := v_fallas || format('P1c el encargado manda R×10: %s', left(v_res, 220));
    END IF;

    v_res := pg_temp.editar(v_x, v_adm, jsonb_build_array(pg_temp.it(vv, 10), pg_temp.reg(w, 1, v_promo)));
    IF v_res <> 'ok' OR pg_temp.regalos(v_x) <> w || '×1/10' THEN
      v_fallas := v_fallas || format('P1d el admin baja la venta y manda W×1: %s | %s', left(v_res, 220), pg_temp.regalos(v_x));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('P1 error: %s', SQLERRM);
  END;

  -- ==================================================================== P2 ===
  BEGIN
    vv := pg_temp.prod('[]', 500);
    r  := pg_temp.prod('[]', 50);
    k1 := pg_temp.prod('[]', 50, 600);
    k2 := pg_temp.prod('[]', 1, 600);
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                             ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
    VALUES ('ZZ ensayo C2 fraccion', 'bonificacion', public._tablero_hoy() - 1, v_suc, false, r, true, k1, 12, 1)
    RETURNING id INTO v_promo;
    INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
    VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 4, v_suc);
    INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, vv, v_suc);
    v_p := '{}';
    FOR i IN 1..3 LOOP
      v_p := v_p || pg_temp.alta(v_cli, v_adm, jsonb_build_array(pg_temp.it(vv, 10), pg_temp.reg(r, 4, v_promo)));
    END LOOP;
    UPDATE pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = ANY(v_p);
    UPDATE promociones SET unidades_por_bloque = 4, ajuste_producto_id = k2 WHERE id = v_promo;
    IF (SELECT stock FROM productos WHERE id = k1) <> 49 OR (SELECT stock FROM productos WHERE id = k2) <> 1
       OR (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 0 THEN
      RAISE EXCEPTION 'el armado no dejó K1 49, K2 1 y la barra en 0';
    END IF;
    PERFORM pg_temp.como(v_adm);
    v_j := public.registrar_salvedad(v_p[1], (SELECT id FROM pedido_items WHERE pedido_id = v_p[1] AND es_bonificacion),
                                     4, 'cliente_rechaza', 'ensayo C2', NULL, true, NULL);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN RAISE EXCEPTION 'salvedad: %', v_j; END IF;
    IF (SELECT stock FROM productos WHERE id = k1) <> 50 OR (SELECT stock FROM productos WHERE id = k2) <> 0
       OR (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 4 THEN
      RAISE EXCEPTION 'la salvedad no dejó K1 50, K2 0 y la barra en 4 (K1 %, K2 %, barra %)',
        (SELECT stock FROM productos WHERE id = k1), (SELECT stock FROM productos WHERE id = k2),
        (SELECT usos_pendientes FROM promociones WHERE id = v_promo);
    END IF;

    -- P2a · K2 en 0
    v_res := pg_temp.factor(v_promo, 2);
    IF v_res NOT LIKE '23514 productos_stock_no_negativo El contenedor «ZZ ensayo C2 %» no tiene stock para el factor nuevo de la promoción (hay 0, y el cambio cierra 2 bloques que descuentan 2).%' THEN
      v_fallas := v_fallas || format('P2a factor 4 → 2 con K2 en 0: %s', v_res);
    END IF;
    IF (SELECT stock FROM productos WHERE id = k2) <> 0 OR (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 4
       OR (SELECT unidades_por_bloque FROM promociones WHERE id = v_promo) <> 4 THEN
      v_fallas := v_fallas || 'P2a el rechazo dejó cambios';
    END IF;
    -- P2b · K2 en 1
    PERFORM pg_temp.bolsa(k2, 1);
    v_res := pg_temp.factor(v_promo, 2);
    IF v_res NOT LIKE '23514 productos_stock_no_negativo El contenedor «ZZ ensayo C2 %» no tiene stock para el factor nuevo de la promoción (hay 1, y el cambio cierra 2 bloques que descuentan 2).%' THEN
      v_fallas := v_fallas || format('P2b factor 4 → 2 con K2 en 1: %s', v_res);
    END IF;
    -- P2d · por la RPC del front, con K2 en 0
    PERFORM pg_temp.bolsa(k2, -1);
    PERFORM pg_temp.como(v_adm);
    v_j := public.cambiar_regalo_promocion(v_promo, r, k2, true, jsonb_build_object(
      'nombre', 'ZZ ensayo C2 fraccion', 'tipo', 'bonificacion', 'fecha_inicio', public._tablero_hoy() - 1,
      'fecha_fin', NULL, 'limite_usos', NULL, 'prioridad', 0, 'regalo_mueve_stock', false,
      'modo_exclusion', 'acumulable', 'unidades_por_bloque', 2, 'stock_por_bloque', 1,
      'descripcion_regalo', NULL, 'producto_ids', jsonb_build_array(vv),
      'reglas', jsonb_build_array(jsonb_build_object('clave', 'cantidad_compra', 'valor', 10),
                                  jsonb_build_object('clave', 'cantidad_bonificacion', 'valor', 4))));
    PERFORM pg_temp.limpiar();
    IF v_j->>'codigo' IS DISTINCT FROM 'contenedor_sin_stock' OR position('ZZ ensayo C2' IN v_j->>'error') = 0
       OR (SELECT unidades_por_bloque FROM promociones WHERE id = v_promo) <> 4 THEN
      v_fallas := v_fallas || format('P2d por la RPC con K2 en 0: %s', v_j);
    END IF;
    -- P2c · K2 en 2: entra y cierra los dos bloques
    PERFORM pg_temp.bolsa(k2, 2);
    v_res := pg_temp.factor(v_promo, 2);
    IF v_res <> 'ok' OR (SELECT stock FROM productos WHERE id = k2) <> 0
       OR (SELECT usos_pendientes FROM promociones WHERE id = v_promo) <> 0 THEN
      v_fallas := v_fallas || format('P2c factor 4 → 2 con K2 en 2: %s, K2 %s, barra %s (esperado ok, 0 y 0)', v_res,
        (SELECT stock FROM productos WHERE id = k2), (SELECT usos_pendientes FROM promociones WHERE id = v_promo));
    END IF;
    v_fallas := v_fallas || pg_temp.cierra('P2 K2', k2) || pg_temp.cierra('P2 K1', k1);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('P2 error: %s', SQLERRM);
  END;

  -- ------------------------------------------------------------------- A1 ---
  SELECT jsonb_object_agg(x->>'id', (x->>'violaciones')::bigint) INTO v_checks
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x;
  FOR k IN SELECT jsonb_object_keys(v_checks) LOOP
    IF COALESCE((v_checks->>k)::bigint, 0) > COALESCE((v_antes->>k)::bigint, 0) THEN
      v_fallas := v_fallas || format('A1 %s: %s violaciones (antes %s)', k, v_checks->>k, v_antes->>k);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · P1a–P1d, P2a–P2d y A1 (el tope de un regalo cambiado por valor va en su corte, y el cambio de factor sin stock en el contenedor se rechaza con su motivo)';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
END
$ensayo$;
