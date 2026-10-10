-- Ensayo de #1079: la devolución por nota de crédito (registrar_nota_credito
-- con ítems) saca las unidades de los lotes de LA compra que se acredita, no
-- de la bolsa "sin vencimiento" ni del lote que vence primero de otra compra.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en
-- RAISE EXCEPTION, así que todo lo que crea (productos, compras, lotes, notas)
-- se deshace. Usa un admin real de una sucursal activa, como los ensayos de la
-- 328 y la 331.
--
-- Por qué bolsa distinta de 0 en todos los casos: con bolsa 0 la bajada del
-- trigger no tiene de dónde comer más que de los lotes, y si el único lote es
-- el de la compra da bien por casualidad (así se escondió el bug de la 316).
--
-- Casos (lote = cantidad_restante; bolsa = stock − suma de lotes):
--   A · el caso del issue. Compra C con un lote de 100 que tiene 50 vivas,
--       bolsa 40 (stock 90). Nota por 10 de C: lote 40, bolsa 40, stock 80.
--       Antes: lote 50, bolsa 30 (las 10 salían de la bolsa).
--   B · no el primero por FEFO global. Lote de otra compra D que vence ANTES,
--       30 vivas; lote de C que vence después, 50; bolsa 10 (stock 90). Nota por
--       10 de C: C 40, D 30, bolsa 10. Antes: bolsa 0, D 30, C 50.
--   C · FEFO dentro de la compra. C trae dos vencimientos: C1 (antes) con 5
--       vivas y C2 (después) con 50; bolsa 20 (stock 75). Nota por 10: C1 0,
--       C2 45, bolsa 20.
--   D · a los lotes de la compra no les alcanza. C con 5 vivas, D (otra compra,
--       vence antes) con 30, bolsa 20 (stock 55). Nota por 10: C 0, y las 5 que
--       faltan salen de la bolsa: bolsa 15, D 30.
--   E · stock menor que lo devuelto (la bajada se clampea a 0). C con 5 vivas,
--       bolsa 3 (stock 8). Nota por 10: stock 0, C 0, bolsa 0, sin error.
--       (Da igual con o sin el arreglo: el trigger recorta a 0. Es un "no
--       revienta", no una prueba del cambio.)
--   F · editar la compra después no devuelve lo que salió. Tras el caso A,
--       sincronizar_lotes_compra con el mismo vencimiento y la misma cantidad
--       (lo que la app manda en cada edición) deja el lote en 40.
--   G · el mismo producto en dos renglones de la nota (6 + 4): C sale 10.
--   H · producto sin lotes: baja el stock y nada más (no cambia).
--   I · el ledger: la bajada queda 'nota_credito' → notas_credito/<id>, y STK-D
--       no ve ningún 'auto' nuevo.
--   J · la nota sin ítems (ajuste) no toca stock ni lotes.
--   K · la puerta por lote y después la nota por factura, sobre la misma
--       compra. Lote 50 vivas, bolsa 40 (stock 90). Nota por lote de 10: lote
--       40, bolsa 40. Nota por factura de 10: lote 30, bolsa 40, stock 70.
--
-- Veredicto: NOTICE 'ENSAYO OK (todo revertido)', o el error 'ENSAYO FALLÓ …'
-- con la lista de fallas. En los dos casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-nota-credito-lotes-1079.sql

DO $ensayo$
DECLARE
  v_admin    uuid;
  v_suc      bigint;
  v_prov     bigint;
  v_prod     bigint;
  v_compra   bigint;
  v_otra     bigint;
  v_lote_c   bigint;
  v_lote_c2  bigint;
  v_lote_d   bigint;
  v_res      jsonb;
  v_foto     jsonb;
  v_hist     record;
  v_stkd     int;
  v_stkd0    int;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fallas   text[] := '{}';
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

  SELECT (c->>'violaciones')::int INTO v_stkd0
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c WHERE c->>'id' = 'STK-D';

  -- stock / suma de lotes / bolsa del producto
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('stock', pr.stock, 'lotes', l.r, 'bolsa', pr.stock - l.r)
      FROM public.productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM public.producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = p_prod;
  $f$;
  CREATE FUNCTION pg_temp.lote(p_lote bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT cantidad_restante FROM public.producto_lotes WHERE id = p_lote;
  $f$;
  -- una compra de 100 unidades del producto, con su línea
  CREATE FUNCTION pg_temp.compra(p_prod bigint, p_suc bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_id bigint;
  BEGIN
    INSERT INTO public.compras (sucursal_id, fecha_compra, subtotal, iva, total)
    VALUES (p_suc, CURRENT_DATE, 1000, 210, 1210) RETURNING id INTO v_id;
    INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
    VALUES (v_id, p_prod, 100, 10, 1000, p_suc);
    RETURN v_id;
  END $f$;
  -- un lote de la compra (o manual si p_compra es NULL)
  CREATE FUNCTION pg_temp.nuevo_lote(p_prod bigint, p_suc bigint, p_compra bigint, p_vence date,
                                     p_cant int, p_rest int) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, compra_id, origen)
    VALUES (p_prod, p_suc, p_vence, p_cant, p_rest, p_compra,
            CASE WHEN p_compra IS NULL THEN 'manual' ELSE 'compra' END)
    RETURNING id;
  $f$;
  -- la nota de crédito con ítems: [[cantidad], ...] del producto
  CREATE FUNCTION pg_temp.nota(p_compra bigint, p_prod bigint, p_cants int[]) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT public.registrar_nota_credito(
      p_compra, 'ENSAYO-1079', 'ensayo 1079', 0, 0, 0, NULL,
      (SELECT jsonb_agg(jsonb_build_object('producto_id', p_prod, 'cantidad', c,
                                           'costo_unitario', 10, 'subtotal', c * 10))
         FROM unnest(p_cants) c),
      NULL);
  $f$;

  -- -------------------------------------------------------------------------
  -- A · el caso del issue, y F · editar la compra después
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 A', 100, 90, 10, v_suc) RETURNING id INTO v_prod;
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote_c := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 50);

  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[10]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'A · la nota no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF v_foto <> '{"stock":80,"lotes":40,"bolsa":40}'::jsonb OR pg_temp.lote(v_lote_c) <> 40 THEN
    v_fallas := v_fallas || format('A · esperaba stock 80, lote 40, bolsa 40; quedó %s (lote C %s)',
                                   v_foto, pg_temp.lote(v_lote_c));
  END IF;

  -- I · el ledger de esa bajada
  SELECT origen, referencia_tipo, referencia_id INTO v_hist
    FROM stock_historico WHERE producto_id = v_prod ORDER BY id DESC LIMIT 1;
  IF v_hist.origen IS DISTINCT FROM 'nota_credito'
     OR v_hist.referencia_tipo IS DISTINCT FROM 'notas_credito'
     OR v_hist.referencia_id::text IS DISTINCT FROM (v_res->>'nota_credito_id') THEN
    v_fallas := v_fallas || format('I · la bajada quedó %s', to_jsonb(v_hist));
  END IF;

  v_res := public.sincronizar_lotes_compra(v_compra, jsonb_build_array(jsonb_build_object(
             'producto_id', v_prod, 'fecha_vencimiento', v_hoy + 60, 'cantidad', 100)));
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    v_fallas := v_fallas || format('F · sincronizar_lotes_compra falló: %s', v_res);
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF v_foto <> '{"stock":80,"lotes":40,"bolsa":40}'::jsonb THEN
    v_fallas := v_fallas || format('F · tras editar la compra esperaba stock 80, lote 40, bolsa 40; quedó %s', v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- B · no el primero por FEFO global
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 B', 100, 90, 10, v_suc) RETURNING id INTO v_prod;
  v_otra   := pg_temp.compra(v_prod, v_suc);
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote_d := pg_temp.nuevo_lote(v_prod, v_suc, v_otra,   v_hoy + 20, 100, 30);
  v_lote_c := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 50);

  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[10]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'B · la nota no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF pg_temp.lote(v_lote_c) <> 40 OR pg_temp.lote(v_lote_d) <> 30 OR v_foto->>'bolsa' <> '10'
     OR v_foto->>'stock' <> '80' THEN
    v_fallas := v_fallas || format('B · esperaba C 40, D 30, bolsa 10, stock 80; quedó C %s, D %s, %s',
                                   pg_temp.lote(v_lote_c), pg_temp.lote(v_lote_d), v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- C · FEFO dentro de la compra
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 C', 100, 75, 10, v_suc) RETURNING id INTO v_prod;
  v_compra  := pg_temp.compra(v_prod, v_suc);
  v_lote_c  := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 20, 50, 5);
  v_lote_c2 := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 50, 50);

  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[10]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'C · la nota no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF pg_temp.lote(v_lote_c) <> 0 OR pg_temp.lote(v_lote_c2) <> 45 OR v_foto->>'bolsa' <> '20'
     OR v_foto->>'stock' <> '65' THEN
    v_fallas := v_fallas || format('C · esperaba C1 0, C2 45, bolsa 20, stock 65; quedó C1 %s, C2 %s, %s',
                                   pg_temp.lote(v_lote_c), pg_temp.lote(v_lote_c2), v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- D · a los lotes de la compra no les alcanza
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 D', 100, 55, 10, v_suc) RETURNING id INTO v_prod;
  v_otra   := pg_temp.compra(v_prod, v_suc);
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote_d := pg_temp.nuevo_lote(v_prod, v_suc, v_otra,   v_hoy + 20, 100, 30);
  v_lote_c := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 5);

  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[10]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D · la nota no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF pg_temp.lote(v_lote_c) <> 0 OR pg_temp.lote(v_lote_d) <> 30 OR v_foto->>'bolsa' <> '15'
     OR v_foto->>'stock' <> '45' THEN
    v_fallas := v_fallas || format('D · esperaba C 0, D 30, bolsa 15, stock 45; quedó C %s, D %s, %s',
                                   pg_temp.lote(v_lote_c), pg_temp.lote(v_lote_d), v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- E · stock menor que lo devuelto
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 E', 100, 8, 10, v_suc) RETURNING id INTO v_prod;
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote_c := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 5);

  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[10]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('E · la nota no se registró: %s', v_res);
  ELSE
    v_foto := pg_temp.foto(v_prod);
    IF v_foto <> '{"stock":0,"lotes":0,"bolsa":0}'::jsonb THEN
      v_fallas := v_fallas || format('E · esperaba stock 0, lote 0, bolsa 0; quedó %s', v_foto);
    END IF;
  END IF;

  -- -------------------------------------------------------------------------
  -- G · el mismo producto en dos renglones
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 G', 100, 90, 10, v_suc) RETURNING id INTO v_prod;
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote_c := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 50);

  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[6, 4]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'G · la nota no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF v_foto <> '{"stock":80,"lotes":40,"bolsa":40}'::jsonb THEN
    v_fallas := v_fallas || format('G · esperaba stock 80, lote 40, bolsa 40; quedó %s', v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- H · producto sin lotes
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 H', 100, 30, 10, v_suc) RETURNING id INTO v_prod;
  v_compra := pg_temp.compra(v_prod, v_suc);

  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[10]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'H · la nota no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF v_foto <> '{"stock":20,"lotes":0,"bolsa":20}'::jsonb
     OR EXISTS (SELECT 1 FROM producto_lotes WHERE producto_id = v_prod) THEN
    v_fallas := v_fallas || format('H · esperaba stock 20 y ningún lote; quedó %s', v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- J · la nota sin ítems no toca stock ni lotes
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 J', 100, 90, 10, v_suc) RETURNING id INTO v_prod;
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote_c := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 50);

  v_res := public.registrar_nota_credito(v_compra, 'ENSAYO-1079', 'ajuste ensayo 1079',
                                         100, 21, 121, NULL, '[]'::jsonb, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_res->>'tipo' <> 'ajuste' THEN
    RAISE EXCEPTION 'J · el ajuste no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF v_foto <> '{"stock":90,"lotes":50,"bolsa":40}'::jsonb THEN
    v_fallas := v_fallas || format('J · el ajuste movió stock o lotes: %s', v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- K · la puerta por lote y después la nota por factura
  -- -------------------------------------------------------------------------
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1079 K', 100, 90, 10, v_suc) RETURNING id INTO v_prod;
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote_c := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 50);

  v_res := public.registrar_nota_credito_lote(v_lote_c, 10, 'ENSAYO-1079-L', 'ensayo 1079 por lote');
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'K · la nota por lote no se registró: %', v_res;
  END IF;
  v_res := pg_temp.nota(v_compra, v_prod, ARRAY[10]);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'K · la nota por factura no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  IF v_foto <> '{"stock":70,"lotes":30,"bolsa":40}'::jsonb THEN
    v_fallas := v_fallas || format('K · esperaba stock 70, lote 30, bolsa 40; quedó %s', v_foto);
  END IF;

  -- -------------------------------------------------------------------------
  -- I · STK-D no ve ningún 'auto' nuevo
  -- -------------------------------------------------------------------------
  SELECT (c->>'violaciones')::int INTO v_stkd
    FROM jsonb_array_elements(public.auditoria_integridad() -> 'checks') c WHERE c->>'id' = 'STK-D';
  IF v_stkd IS DISTINCT FROM v_stkd0 THEN
    v_fallas := v_fallas || format('I · STK-D pasó de %s a %s', v_stkd0, v_stkd);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1079-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo$;
