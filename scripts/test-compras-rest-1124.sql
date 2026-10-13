-- Ensayo de #1124: la familia compras (compras, compra_items, compra_cargos y
-- compra_cargo_repartos) no se escribe por REST; sólo por sus RPC DEFINER.
--
-- Antes de la migración, un admin por REST (y el depósito, en el INSERT) podía
-- cancelar o borrar una compra sin notas sin revertir el stock (el trigger de
-- la 224 le borra los lotes y la mercadería pasa a la bolsa), reescribir los
-- totales y escribir directo las líneas, los cargos y los repartos, salteando
-- los controles de actualizar_compra_items. La migración dropea las 12
-- policies de escritura y revoca INSERT/UPDATE/DELETE/TRUNCATE a
-- authenticated y anon.
--
-- Corre contra prod SIN dejar rastro: un único DO; todo pasa dentro de un
-- bloque que termina SIEMPRE en una excepción (atrapada si salió bien), así que
-- productos, compras, lotes, cargos y perfiles se deshacen. Además cada caso
-- corre en su propio sub-bloque que se revierte al terminar: los casos no se
-- pisan. No usa TRUNCATE, ni DISABLE TRIGGER, ni nada que tome AccessExclusive
-- sobre las tablas de compras (los casos A–E son DML sobre filas del fixture y
-- F es sólo catálogo).
--
-- Simula PostgREST como test-compra-nc-rest-1113.sql: `SET LOCAL ROLE
-- authenticated`, el `sub` de un admin real en request.jwt.claims y la sucursal
-- en x-sucursal-id.
--
-- Bolsa distinta de 0 y lote ajeno (lección de la 316): producto PP con stock
-- 180; compra P de 100 con su lote LP de 100 que vence a 90 días; un lote ajeno
-- L2 sin compra, de 30, que vence a 30 días (antes que LP); bolsa 50.
-- La compra Q nace por registrar_compra_completa con un flete prorrateado
-- (cargo + reparto) y su lote LQ por sincronizar_lotes_compra: producto PQ con
-- stock 150, lote 100, bolsa 50.
--
-- Casos REST (esperan 42501 y que nada cambie):
--   A · UPDATE compras SET estado = 'cancelada' sobre P (sin notas)
--   B · DELETE de la compra P
--   C · UPDATE de subtotal / iva / impuestos_internos / total de P
--   D · INSERT de una compra como admin y como depósito
--   E · INSERT / UPDATE / DELETE de compra_items, compra_cargos y
--       compra_cargo_repartos de Q
-- F · grants por catálogo: ni anon ni authenticated tienen INSERT, UPDATE,
--     DELETE ni TRUNCATE sobre las cuatro tablas (PostgREST no expone TRUNCATE;
--     se mira el grant, no se ejecuta).
-- Regresiones (iguales antes y después):
--   G · registrar_compra_completa con flete y reparto + sincronizar_lotes_compra
--       como admin REST
--   H · actualizar_compra_items con los mismos ítems y cargos sobre Q
--   I · anular_compra_atomica sobre P: stock 80, LP borrado, L2 intacto en 30,
--       bolsa 50 (con el orden de la 229 invertido quedaría L2 0 y bolsa 80)
--   J · cambiar_proveedor_compra sobre Q: el lote se reapunta al clon con su
--       cantidad_restante
--   S · admin y encargado por REST leen lo mismo que postgres en las cuatro
--
-- Veredicto: NOTICE 'ENSAYO OK (todo revertido)', o el error 'ENSAYO FALLÓ …'
-- con la lista de fallas. En los dos casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-compras-rest-1124.sql

DO $ensayo$
DECLARE
  v_admin   uuid;
  v_enc     uuid;
  v_dep     uuid;
  v_suc     bigint;
  v_hoy     date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  -- P: compra sin notas, con su lote, más un lote ajeno y bolsa
  v_pP      bigint;  v_P  bigint;  v_lP bigint;  v_l2 bigint;
  -- Q: compra por la RPC, con cargo y reparto
  v_pQ      bigint;  v_pQ2 bigint;  v_Q bigint;  v_lQ bigint;
  v_itQ     bigint;  v_itQ2 bigint;  v_cQ bigint;
  v_prisP   jsonb := '{"stock":180,"lotes":130,"bolsa":50}';
  v_prisQ   jsonb := '{"stock":150,"lotes":100,"bolsa":50}';
  v_cabP    text;
  v_famQ    text;
  v_res     jsonb;
  v_err     text;
  v_errs    text[];
  v_n       bigint;
  v_n2      bigint;
  v_t       text;
  v_rol     text;   -- ojo: plpgsql no distingue mayúsculas (v_p chocaría con v_P)
  v_priv    text;
  v_cab     record;
  v_items   jsonb;
  v_cargos  jsonb;
  v_hist    record;
  v_fallas  text[] := '{}';
BEGIN
 BEGIN
  -- Una sucursal activa con un admin y un encargado activos, y alguien más
  -- (no admin) para fabricar el depósito.
  SELECT a.usuario_id, a.sucursal_id, e.usuario_id
    INTO v_admin, v_suc, v_enc
    FROM usuario_sucursales a
    JOIN perfiles pa  ON pa.id = a.usuario_id AND pa.rol = 'admin' AND pa.activo
    JOIN sucursales s ON s.id = a.sucursal_id AND s.activa
    JOIN usuario_sucursales e ON e.sucursal_id = a.sucursal_id
    JOIN perfiles pe  ON pe.id = e.usuario_id AND pe.rol = 'encargado' AND pe.activo
   ORDER BY a.usuario_id, a.sucursal_id, e.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita una sucursal activa con un admin y un encargado activos';
  END IF;
  SELECT us.usuario_id INTO v_dep
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo AND pf.rol IN ('preventista', 'transportista')
   WHERE us.sucursal_id = v_suc
   ORDER BY us.usuario_id DESC
   LIMIT 1;
  IF v_dep IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un preventista o transportista en la sucursal % para fabricar el depósito', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- ---------------------------------------------------------------- helpers -
  -- Corre una sentencia como PostgREST (authenticated); NULL si pasó, o
  -- 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Una RPC como PostgREST: su jsonb, o {"exception": …}.
  CREATE FUNCTION pg_temp.rest_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('exception', SQLSTATE || ' ' || SQLERRM);
  END $f$;
  -- Un conteo como PostgREST (-1 si falla).
  CREATE FUNCTION pg_temp.rest_int(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    RETURN -1;
  END $f$;
  -- stock / suma de lotes / bolsa del producto
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('stock', pr.stock, 'lotes', l.r, 'bolsa', pr.stock - l.r)
      FROM public.productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM public.producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text, p_stock int) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES (p_nombre, 100, p_stock, 10, p_suc) RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.estado(p_compra bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT estado::text FROM public.compras WHERE id = p_compra;
  $f$;
  CREATE FUNCTION pg_temp.cabecera(p_compra bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT row(estado, subtotal, iva, impuestos_internos, total)::text FROM public.compras WHERE id = p_compra;
  $f$;
  -- Todo lo escrito de una compra: ítems, cargos y repartos.
  CREATE FUNCTION pg_temp.familia(p_compra bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT jsonb_build_object(
      'items',    (SELECT jsonb_agg(jsonb_build_object('id', id, 'producto_id', producto_id, 'cantidad', cantidad,
                                                       'costo_unitario', costo_unitario, 'subtotal', subtotal) ORDER BY id)
                     FROM public.compra_items WHERE compra_id = p_compra),
      'cargos',   (SELECT jsonb_agg(jsonb_build_object('id', id, 'orden', orden, 'concepto', concepto, 'monto', monto) ORDER BY id)
                     FROM public.compra_cargos WHERE compra_id = p_compra),
      'repartos', (SELECT jsonb_agg(jsonb_build_object('cargo_id', cargo_id, 'item', compra_item_id, 'peso', peso)
                                    ORDER BY cargo_id, compra_item_id)
                     FROM public.compra_cargo_repartos WHERE compra_id = p_compra))::text;
  $f$;
  CREATE FUNCTION pg_temp.es_42501(p_err text) RETURNS boolean LANGUAGE sql AS $f$
    SELECT p_err IS NOT NULL AND p_err LIKE '42501%';
  $f$;

  -- ---------------------------------------------------------------- fixture -
  -- P: compra cargada como postgres (como en el ensayo de la 1113), su lote y
  -- un lote ajeno sin compra que vence antes.
  v_pP := pg_temp.producto(v_suc, 'ZZ ensayo 1124 P', 180);
  INSERT INTO compras (sucursal_id, fecha_compra, subtotal, iva, total, estado)
  VALUES (v_suc, v_hoy, 1000, 210, 1210, 'recibida') RETURNING id INTO v_P;
  INSERT INTO compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
  VALUES (v_P, v_pP, 100, 10, 1000, v_suc);
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen)
  VALUES (v_pP, v_suc, v_hoy + 90, 100, 100, v_P, 'compra') RETURNING id INTO v_lP;
  INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen)
  VALUES (v_pP, v_suc, v_hoy + 30, 30, 30, NULL, 'manual') RETURNING id INTO v_l2;
  IF pg_temp.foto(v_pP) <> v_prisP THEN
    RAISE EXCEPTION 'fixture · P quedó %, esperaba %', pg_temp.foto(v_pP), v_prisP;
  END IF;
  v_cabP := pg_temp.cabecera(v_P);

  -- Q: por la RPC, como admin REST, con un flete que prorratea sobre la línea 0.
  -- La línea 1 (PQ2) queda sin reparto: es la que usa el INSERT de E.
  v_pQ  := pg_temp.producto(v_suc, 'ZZ ensayo 1124 Q', 50);
  v_pQ2 := pg_temp.producto(v_suc, 'ZZ ensayo 1124 Q2', 0);
  v_res := pg_temp.rest_json(format(
    'SELECT public.registrar_compra_completa(NULL, %L, %L, %L::date, 1100, 0, 0, 1100, %L, %L, %L::uuid, %L::jsonb, %L, p_cargos => %L::jsonb)',
    'ZZ proveedor ensayo 1124', 'ENSAYO-1124-Q', v_hoy, 'efectivo', 'ensayo 1124 Q', v_admin,
    jsonb_build_array(
      jsonb_build_object('producto_id', v_pQ,  'cantidad', 100, 'costo_unitario', 10, 'subtotal', 1000),
      jsonb_build_object('producto_id', v_pQ2, 'cantidad', 10,  'costo_unitario', 10, 'subtotal', 100)),
    'ZZ',
    jsonb_build_array(jsonb_build_object('concepto', 'Flete ensayo 1124', 'monto', 100,
                                         'condicion_iva', 'no_gravado', 'pesos', jsonb_build_object('0', 1)))));
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'fixture · Q no se registró: %', v_res;
  END IF;
  v_Q := (v_res->>'compra_id')::bigint;
  v_res := pg_temp.rest_json(format('SELECT public.sincronizar_lotes_compra(%s, %L::jsonb)', v_Q,
             jsonb_build_array(jsonb_build_object('producto_id', v_pQ, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 100))));
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'fixture · los vencimientos de Q no se cargaron: %', v_res;
  END IF;
  SELECT id INTO v_lQ  FROM producto_lotes WHERE compra_id = v_Q AND producto_id = v_pQ;
  SELECT id INTO v_itQ  FROM compra_items WHERE compra_id = v_Q AND producto_id = v_pQ;
  SELECT id INTO v_itQ2 FROM compra_items WHERE compra_id = v_Q AND producto_id = v_pQ2;
  SELECT id INTO v_cQ  FROM compra_cargos WHERE compra_id = v_Q;
  IF v_lQ IS NULL OR v_itQ IS NULL OR v_itQ2 IS NULL OR v_cQ IS NULL
     OR NOT EXISTS (SELECT 1 FROM compra_cargo_repartos WHERE cargo_id = v_cQ AND compra_item_id = v_itQ)
     OR pg_temp.foto(v_pQ) <> v_prisQ THEN
    RAISE EXCEPTION 'fixture · Q quedó lote %, ítems %/%, cargo %, foto %', v_lQ, v_itQ, v_itQ2, v_cQ, pg_temp.foto(v_pQ);
  END IF;
  v_famQ := pg_temp.familia(v_Q);

  -- ======================================================= casos REST =======
  -- A · cancelar P por PATCH: el bug. Sin el arreglo, P queda cancelada, el
  --     trigger de la 224 le borra LP y el stock sigue en 180 (bolsa 150).
  BEGIN
    v_err := pg_temp.rest(format('UPDATE public.compras SET estado = %L WHERE id = %s', 'cancelada', v_P));
    IF NOT pg_temp.es_42501(v_err) THEN
      v_fallas := v_fallas || format('A · cancelar por REST una compra sin notas tenía que dar 42501; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.estado(v_P) IS DISTINCT FROM 'recibida' OR pg_temp.foto(v_pP) <> v_prisP
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lP AND cantidad_restante = 100)
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_l2 AND cantidad_restante = 30) THEN
      v_fallas := v_fallas || format('A · P tenía que seguir recibida con %s, LP en 100 y L2 en 30; quedó %s, %s',
                                     v_prisP, pg_temp.estado(v_P), pg_temp.foto(v_pP));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A · error inesperado: ' || SQLERRM);
  END;

  -- B · DELETE de P: sin el arreglo se lleva por CASCADE ítems y lote sin
  --     tocar el stock.
  BEGIN
    v_err := pg_temp.rest(format('DELETE FROM public.compras WHERE id = %s', v_P));
    IF NOT pg_temp.es_42501(v_err) THEN
      v_fallas := v_fallas || format('B · borrar por REST una compra tenía que dar 42501; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.estado(v_P) IS DISTINCT FROM 'recibida'
       OR NOT EXISTS (SELECT 1 FROM compra_items WHERE compra_id = v_P)
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lP AND cantidad_restante = 100)
       OR pg_temp.foto(v_pP) <> v_prisP THEN
      v_fallas := v_fallas || format('B · P, sus ítems o su lote no sobrevivieron al DELETE; estado %s, foto %s',
                                     pg_temp.estado(v_P), pg_temp.foto(v_pP));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('B · error inesperado: ' || SQLERRM);
  END;

  -- C · reescribir los totales de P
  BEGIN
    v_err := pg_temp.rest(format(
      'UPDATE public.compras SET subtotal = 1, iva = 0, impuestos_internos = 0, total = 1 WHERE id = %s', v_P));
    IF NOT pg_temp.es_42501(v_err) THEN
      v_fallas := v_fallas || format('C · reescribir los totales por REST tenía que dar 42501; error %s', COALESCE(v_err, '(ninguno)'));
    END IF;
    IF pg_temp.cabecera(v_P) IS DISTINCT FROM v_cabP THEN
      v_fallas := v_fallas || format('C · la cabecera de P cambió: %s → %s', v_cabP, pg_temp.cabecera(v_P));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C · error inesperado: ' || SQLERRM);
  END;

  -- D · INSERT de una compra suelta (sin stock, sin lotes, sin ledger), como
  --     admin y como depósito (fabricado dentro del sub-bloque).
  BEGIN
    SELECT count(*) INTO v_n FROM compras WHERE sucursal_id = v_suc;
    v_errs := ARRAY[pg_temp.rest(format(
      'INSERT INTO public.compras (sucursal_id, fecha_compra, subtotal, iva, total, estado, notas) VALUES (%s, %L, 1, 0, 1, %L, %L)',
      v_suc, v_hoy, 'recibida', 'ensayo 1124 D admin'))];
    UPDATE perfiles SET rol = 'deposito' WHERE id = v_dep;
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_dep, 'role', 'authenticated')::text, true);
    v_errs := v_errs || pg_temp.rest(format(
      'INSERT INTO public.compras (sucursal_id, fecha_compra, subtotal, iva, total, estado, notas) VALUES (%s, %L, 1, 0, 1, %L, %L)',
      v_suc, v_hoy, 'recibida', 'ensayo 1124 D deposito'));
    IF NOT pg_temp.es_42501(v_errs[1]) OR NOT pg_temp.es_42501(v_errs[2]) THEN
      v_fallas := v_fallas || format('D · insertar una compra por REST tenía que dar 42501 (admin / depósito); errores %s / %s',
                                     COALESCE(v_errs[1], '(ninguno)'), COALESCE(v_errs[2], '(ninguno)'));
    END IF;
    SELECT count(*) INTO v_n2 FROM compras WHERE sucursal_id = v_suc;
    IF v_n2 <> v_n THEN
      v_fallas := v_fallas || format('D · la sucursal pasó de %s a %s compras', v_n, v_n2);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('D · error inesperado: ' || SQLERRM);
  END;

  -- E · líneas, cargos y repartos de Q escritos directo
  BEGIN
    v_errs := ARRAY[
      pg_temp.rest(format(
        'INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id) VALUES (%s, %s, 5, 10, 50, %s)',
        v_Q, v_pQ, v_suc)),
      pg_temp.rest(format('UPDATE public.compra_items SET cantidad = 1, subtotal = 10 WHERE id = %s', v_itQ)),
      pg_temp.rest(format('DELETE FROM public.compra_items WHERE id = %s', v_itQ2)),
      pg_temp.rest(format(
        'INSERT INTO public.compra_cargos (compra_id, sucursal_id, orden, concepto, monto, condicion_iva, en_factura, prorratea_al_costo, afecta_base_ii, base_prorrateo, comprobante_tercero) VALUES (%s, %s, 99, %L, 1, %L, true, false, false, %L, false)',
        v_Q, v_suc, 'ensayo 1124 E', 'no_gravado', 'unidades')),
      pg_temp.rest(format('UPDATE public.compra_cargos SET monto = 1 WHERE id = %s', v_cQ)),
      pg_temp.rest(format('DELETE FROM public.compra_cargos WHERE id = %s', v_cQ)),
      pg_temp.rest(format(
        'INSERT INTO public.compra_cargo_repartos (cargo_id, compra_item_id, compra_id, peso) VALUES (%s, %s, %s, 1)',
        v_cQ, v_itQ2, v_Q)),
      pg_temp.rest(format('UPDATE public.compra_cargo_repartos SET peso = 5 WHERE cargo_id = %s', v_cQ)),
      pg_temp.rest(format('DELETE FROM public.compra_cargo_repartos WHERE cargo_id = %s', v_cQ))];
    FOR v_n IN 1 .. cardinality(v_errs) LOOP
      IF NOT pg_temp.es_42501(v_errs[v_n]) THEN
        v_fallas := v_fallas || format('E · la escritura REST %s de %s (%s) tenía que dar 42501; error %s', v_n,
                                       (ARRAY['compra_items', 'compra_items', 'compra_items',
                                              'compra_cargos', 'compra_cargos', 'compra_cargos',
                                              'compra_cargo_repartos', 'compra_cargo_repartos', 'compra_cargo_repartos'])[v_n],
                                       (ARRAY['INSERT', 'UPDATE', 'DELETE'])[((v_n - 1) % 3) + 1],
                                       COALESCE(v_errs[v_n], '(ninguno)'));
      END IF;
    END LOOP;
    IF pg_temp.familia(v_Q) IS DISTINCT FROM v_famQ OR pg_temp.foto(v_pQ) <> v_prisQ THEN
      v_fallas := v_fallas || format('E · Q cambió: %s → %s, foto %s', v_famQ, pg_temp.familia(v_Q), pg_temp.foto(v_pQ));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('E · error inesperado: ' || SQLERRM);
  END;

  -- F · grants (catálogo; no se ejecuta nada sobre las tablas)
  BEGIN
    v_errs := '{}';
    FOREACH v_t IN ARRAY ARRAY['compras', 'compra_items', 'compra_cargos', 'compra_cargo_repartos'] LOOP
      FOREACH v_rol IN ARRAY ARRAY['anon', 'authenticated'] LOOP
        FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
          IF has_table_privilege(v_rol, 'public.' || v_t, v_priv) THEN
            v_errs := v_errs || format('%s %s %s', v_rol, v_priv, v_t);
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    IF cardinality(v_errs) > 0 THEN
      v_fallas := v_fallas || format('F · %s grants de escritura siguen en pie: %s', cardinality(v_errs),
                                     array_to_string(v_errs, ', '));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('F · error inesperado: ' || SQLERRM);
  END;

  -- ========================================================= regresiones ====
  -- G · alta con flete y reparto + vencimientos, como admin REST
  BEGIN
    v_n := pg_temp.producto(v_suc, 'ZZ ensayo 1124 G', 20);
    v_res := pg_temp.rest_json(format(
      'SELECT public.registrar_compra_completa(NULL, %L, %L, %L::date, 400, 0, 0, 400, %L, %L, %L::uuid, %L::jsonb, %L, p_cargos => %L::jsonb)',
      'ZZ proveedor ensayo 1124', 'ENSAYO-1124-G', v_hoy, 'efectivo', 'ensayo 1124 G', v_admin,
      jsonb_build_array(jsonb_build_object('producto_id', v_n, 'cantidad', 40, 'costo_unitario', 10, 'subtotal', 400)),
      'ZZ',
      jsonb_build_array(jsonb_build_object('concepto', 'Flete ensayo 1124 G', 'monto', 40,
                                           'condicion_iva', 'no_gravado', 'pesos', jsonb_build_object('0', 1)))));
    v_n2 := (v_res->>'compra_id')::bigint;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR (SELECT count(*) FROM compra_items  WHERE compra_id = v_n2) <> 1
       OR (SELECT count(*) FROM compra_cargos WHERE compra_id = v_n2) <> 1
       OR (SELECT count(*) FROM compra_cargo_repartos WHERE compra_id = v_n2) <> 1
       OR (SELECT cargos_unitarios FROM compra_items WHERE compra_id = v_n2) <> 1
       OR pg_temp.foto(v_n) <> '{"stock":60,"lotes":0,"bolsa":60}'::jsonb THEN
      v_fallas := v_fallas || format('G · registrar_compra_completa por REST: %s, foto %s', v_res, pg_temp.foto(v_n));
    ELSE
      v_res := pg_temp.rest_json(format('SELECT public.sincronizar_lotes_compra(%s, %L::jsonb)', v_n2,
                 jsonb_build_array(jsonb_build_object('producto_id', v_n, 'fecha_vencimiento', v_hoy + 45, 'cantidad', 40))));
      IF NOT COALESCE((v_res->>'ok')::boolean, false)
         OR pg_temp.foto(v_n) <> '{"stock":60,"lotes":40,"bolsa":20}'::jsonb THEN
        v_fallas := v_fallas || format('G · sincronizar_lotes_compra por REST: %s, foto %s', v_res, pg_temp.foto(v_n));
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('G · error inesperado: ' || SQLERRM);
  END;

  -- H · editar Q con los mismos ítems y cargos: nada cambia
  BEGIN
    SELECT subtotal, iva, total INTO v_cab FROM compras WHERE id = v_Q;
    SELECT jsonb_agg(jsonb_build_object(
             'producto_id', ci.producto_id, 'cantidad', ci.cantidad,
             'costo_unitario', ci.costo_unitario, 'subtotal', ci.subtotal,
             'bonificacion', COALESCE(ci.bonificacion, 0),
             'porcentaje_iva', COALESCE(ci.porcentaje_iva, 21),
             'condicion_iva', COALESCE(ci.condicion_iva, 'gravado'),
             'impuestos_internos', COALESCE(ci.impuestos_internos, 0)) ORDER BY ci.id)
      INTO v_items
      FROM compra_items ci WHERE ci.compra_id = v_Q;
    -- Los pesos del cargo van por índice de p_items_nuevos (base 0, en el
    -- mismo orden por id).
    SELECT jsonb_agg(jsonb_build_object(
             'concepto', cc.concepto, 'monto', cc.monto, 'condicion_iva', cc.condicion_iva,
             'en_factura', cc.en_factura, 'prorratea_al_costo', cc.prorratea_al_costo,
             'afecta_base_ii', cc.afecta_base_ii, 'base_prorrateo', cc.base_prorrateo,
             'pesos', (SELECT jsonb_object_agg(x.idx::text, r.peso)
                         FROM compra_cargo_repartos r
                         JOIN (SELECT id, row_number() OVER (ORDER BY id) - 1 AS idx
                                 FROM compra_items WHERE compra_id = v_Q) x ON x.id = r.compra_item_id
                        WHERE r.cargo_id = cc.id)) ORDER BY cc.orden)
      INTO v_cargos
      FROM compra_cargos cc WHERE cc.compra_id = v_Q;
    v_res := pg_temp.rest_json(format(
      'SELECT public.actualizar_compra_items(%s, %L::jsonb, %s, %s, %s, %L::uuid, p_cargos => %L::jsonb, p_ii_declarado => %L::jsonb)',
      v_Q, v_items, v_cab.subtotal, v_cab.iva, v_cab.total, v_admin, v_cargos, '{}'));
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR pg_temp.estado(v_Q) <> 'recibida'
       OR (SELECT row(subtotal, iva, total)::text FROM compras WHERE id = v_Q)
          IS DISTINCT FROM row(v_cab.subtotal, v_cab.iva, v_cab.total)::text
       OR (SELECT count(*) FROM compra_items  WHERE compra_id = v_Q) <> 2
       OR (SELECT count(*) FROM compra_cargos WHERE compra_id = v_Q) <> 1
       OR (SELECT count(*) FROM compra_cargo_repartos WHERE compra_id = v_Q) <> 1
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lQ AND compra_id = v_Q AND cantidad_restante = 100)
       OR pg_temp.foto(v_pQ) <> v_prisQ THEN
      v_fallas := v_fallas || format('H · actualizar_compra_items con los mismos ítems y cargos: %s, estado %s, cabecera %s → %s, familia %s, foto %s',
                                     v_res, pg_temp.estado(v_Q), row(v_cab.subtotal, v_cab.iva, v_cab.total)::text,
                                     (SELECT row(subtotal, iva, total)::text FROM compras WHERE id = v_Q),
                                     pg_temp.familia(v_Q), pg_temp.foto(v_pQ));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('H · error inesperado: ' || SQLERRM);
  END;

  -- I · anular P por la RPC: cancela primero (la 229), así que la bajada come
  --     la bolsa y no el lote ajeno L2, que vence antes.
  BEGIN
    v_res := pg_temp.rest_json(format('SELECT public.anular_compra_atomica(%s, %L::uuid)', v_P, v_admin));
    SELECT origen INTO v_hist FROM stock_historico WHERE producto_id = v_pP ORDER BY id DESC LIMIT 1;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR pg_temp.estado(v_P) <> 'cancelada'
       OR EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lP)
       OR NOT EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_l2 AND cantidad_restante = 30)
       OR pg_temp.foto(v_pP) <> '{"stock":80,"lotes":30,"bolsa":50}'::jsonb
       OR v_hist.origen IS DISTINCT FROM 'compra_anulada' THEN
      v_fallas := v_fallas || format('I · anular P: %s, estado %s, foto %s (esperaba stock 80, L2 30, bolsa 50), L2 %s, ledger %s',
                                     v_res, pg_temp.estado(v_P), pg_temp.foto(v_pP),
                                     (SELECT cantidad_restante FROM producto_lotes WHERE id = v_l2), v_hist.origen);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('I · error inesperado: ' || SQLERRM);
  END;

  -- J · cambiar el proveedor de Q: el lote es una identidad y pasa al clon
  BEGIN
    v_res := pg_temp.rest_json(format('SELECT public.cambiar_proveedor_compra(%s, %L::uuid, NULL, %L, %L)',
                                      v_Q, v_admin, 'ZZ otro proveedor ensayo 1124', 'ensayo 1124 J'));
    v_n := (v_res->>'nueva_compra_id')::bigint;
    IF NOT COALESCE((v_res->>'success')::boolean, false)
       OR pg_temp.estado(v_Q) <> 'cancelada'
       OR pg_temp.estado(v_n) IS DISTINCT FROM 'recibida'
       OR NOT EXISTS (SELECT 1 FROM producto_lotes
                       WHERE id = v_lQ AND compra_id = v_n AND cantidad_restante = 100)
       OR pg_temp.foto(v_pQ) <> v_prisQ THEN
      v_fallas := v_fallas || format('J · cambiar el proveedor de Q: %s, vieja %s, nueva %s, foto %s',
                                     v_res, pg_temp.estado(v_Q), pg_temp.estado(v_n), pg_temp.foto(v_pQ));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('J · error inesperado: ' || SQLERRM);
  END;

  -- S · la lectura sigue viva para admin y encargado
  BEGIN
    FOREACH v_err IN ARRAY ARRAY[v_admin::text, v_enc::text] LOOP
      PERFORM set_config('request.jwt.claims',
                         json_build_object('sub', v_err, 'role', 'authenticated')::text, true);
      FOREACH v_t IN ARRAY ARRAY['compras', 'compra_items', 'compra_cargos', 'compra_cargo_repartos'] LOOP
        v_n := pg_temp.rest_int(format('SELECT count(*) FROM public.%I', v_t));
        IF v_t = 'compra_cargo_repartos' THEN
          SELECT count(*) INTO v_n2 FROM compra_cargo_repartos r JOIN compra_cargos c ON c.id = r.cargo_id
           WHERE c.sucursal_id = v_suc;
        ELSE
          EXECUTE format('SELECT count(*) FROM public.%I WHERE sucursal_id = %s', v_t, v_suc) INTO v_n2;
        END IF;
        IF v_n IS DISTINCT FROM v_n2 OR v_n < 1 THEN
          v_fallas := v_fallas || format('S · %s por REST lee %s filas de %s; como postgres hay %s',
                                         CASE WHEN v_err = v_admin::text THEN 'el admin' ELSE 'el encargado' END,
                                         v_n, v_t, v_n2);
        END IF;
      END LOOP;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('S · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1124-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo$;
