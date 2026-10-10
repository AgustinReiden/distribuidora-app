-- Ensayo de #1095: una compra con notas de crédito no se anula.
--
-- anular_compra_atomica le restaba al stock TODO lo de compra_items, sin
-- descontar lo que ya habían bajado las notas de crédito de esa compra: lo
-- devuelto se restaba dos veces. La decisión (del dueño, 2026-10-10) es
-- rechazar la anulación mientras la compra tenga CUALQUIER nota (devolución o
-- ajuste), como ya hace cambiar_proveedor_compra.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en
-- RAISE EXCEPTION, así que todo lo que crea (productos, compras, lotes, notas)
-- se deshace. Usa un admin real de una sucursal activa.
--
-- Bolsa distinta de 0 en todos los casos (lección de la 316): con bolsa 0 la
-- bajada cae en el lote por FEFO y da bien por casualidad.
--
-- Casos (cada uno con su producto; stock 150, compra C de 100 u. con un lote
-- de 100 vivas, bolsa 50):
--   A · el caso del issue. Nota por 10 con registrar_nota_credito (stock 140,
--       lote 90). Anular C: rechazada, el error nombra las notas, stock 140,
--       C sigue 'recibida' y su lote sigue con 90. Antes: success y stock 40.
--   B · la compra sólo tiene una nota de AJUSTE (sin ítems): rechazada, stock
--       150, lote intacto. Antes: success y stock 50.
--   C · la nota salió por la puerta por lote: rechazada, stock 140.
--   D · regresión: una compra sin notas se sigue anulando. Stock 50, estado
--       'cancelada', lote borrado (224/229), ledger 'compra_anulada'.
--   E · registrar_nota_credito sobre la compra cancelada de D sigue rechazando
--       con 'Compra no encontrada o cancelada'.
--   F · registrar_nota_credito_lote sigue funcionando sobre una compra
--       recibida (la nota de C): lote −10, stock −10, nota de devolución,
--       ledger 'lote_devuelto_proveedor'.
--   G · lote manual (compra_id NULL): el mismo error de hoy ('no tiene compra
--       de origen').
--   H · un lote que apunta a una compra cancelada (no debería existir: la 224
--       los borra; acá se fabrica a mano) no genera nota: la puerta por lote
--       ahora mira el estado de la compra. Antes: creaba la nota.
--
-- Veredicto: NOTICE 'ENSAYO OK (todo revertido)', o el error 'ENSAYO FALLÓ …'
-- con la lista de fallas. En los dos casos no queda nada escrito.
--
--   psql "$DATABASE_URL" -f scripts/test-anular-compra-nc-1095.sql

DO $ensayo$
DECLARE
  v_admin    uuid;
  v_suc      bigint;
  v_prod     bigint;
  v_compra   bigint;
  v_lote     bigint;
  v_res      jsonb;
  v_foto     jsonb;
  v_estado   text;
  v_hist     record;
  v_err      text;
  v_n        int;
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

  -- stock / suma de lotes / bolsa del producto
  CREATE FUNCTION pg_temp.foto(p_prod bigint) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('stock', pr.stock, 'lotes', l.r, 'bolsa', pr.stock - l.r)
      FROM public.productos pr
      JOIN LATERAL (SELECT COALESCE(SUM(cantidad_restante), 0)::int AS r
                      FROM public.producto_lotes WHERE producto_id = pr.id) l ON true
     WHERE pr.id = p_prod;
  $f$;
  -- producto con stock 150
  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
    VALUES (p_nombre, 100, 150, 10, p_suc) RETURNING id;
  $f$;
  -- una compra recibida de 100 unidades del producto, con su línea
  CREATE FUNCTION pg_temp.compra(p_prod bigint, p_suc bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_id bigint;
  BEGIN
    INSERT INTO public.compras (sucursal_id, fecha_compra, subtotal, iva, total, estado)
    VALUES (p_suc, CURRENT_DATE, 1000, 210, 1210, 'recibida') RETURNING id INTO v_id;
    INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
    VALUES (v_id, p_prod, 100, 10, 1000, p_suc);
    RETURN v_id;
  END $f$;
  -- un lote (de la compra, o manual si p_compra es NULL)
  CREATE FUNCTION pg_temp.nuevo_lote(p_prod bigint, p_suc bigint, p_compra bigint, p_vence date,
                                     p_cant int, p_rest int) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, compra_id, origen)
    VALUES (p_prod, p_suc, p_vence, p_cant, p_rest, p_compra,
            CASE WHEN p_compra IS NULL THEN 'manual' ELSE 'compra' END)
    RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.estado(p_compra bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT estado::text FROM public.compras WHERE id = p_compra;
  $f$;
  CREATE FUNCTION pg_temp.lote(p_lote bigint) RETURNS int LANGUAGE sql AS $f$
    SELECT cantidad_restante FROM public.producto_lotes WHERE id = p_lote;
  $f$;

  -- -------------------------------------------------------------------------
  -- A · nota de devolución por factura y después anular
  -- -------------------------------------------------------------------------
  v_prod   := pg_temp.producto(v_suc, 'ZZ ensayo 1095 A');
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote   := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 100);

  v_res := public.registrar_nota_credito(v_compra, 'ENSAYO-1095', 'ensayo 1095', 0, 0, 0, NULL,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10,
                                                  'costo_unitario', 10, 'subtotal', 100)), NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'A · la nota no se registró: %', v_res;
  END IF;

  v_res := public.anular_compra_atomica(v_compra, v_admin);
  v_foto := pg_temp.foto(v_prod);
  IF COALESCE((v_res->>'success')::boolean, false)
     OR COALESCE(v_res->>'error', '') NOT ILIKE '%nota(s) de crédito%' THEN
    v_fallas := v_fallas || format('A · la anulación tenía que rechazarse nombrando las notas; devolvió %s', v_res);
  END IF;
  IF v_foto->>'stock' <> '140' OR pg_temp.estado(v_compra) <> 'recibida'
     OR pg_temp.lote(v_lote) IS DISTINCT FROM 90 THEN
    v_fallas := v_fallas || format('A · esperaba stock 140, compra recibida, lote 90; quedó %s, %s, lote %s',
                                   v_foto, pg_temp.estado(v_compra), pg_temp.lote(v_lote));
  END IF;

  -- -------------------------------------------------------------------------
  -- B · sólo una nota de ajuste
  -- -------------------------------------------------------------------------
  v_prod   := pg_temp.producto(v_suc, 'ZZ ensayo 1095 B');
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote   := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 100);

  v_res := public.registrar_nota_credito(v_compra, 'ENSAYO-1095', 'ajuste ensayo 1095',
                                         100, 21, 121, NULL, '[]'::jsonb, NULL);
  IF NOT COALESCE((v_res->>'success')::boolean, false) OR v_res->>'tipo' <> 'ajuste' THEN
    RAISE EXCEPTION 'B · el ajuste no se registró: %', v_res;
  END IF;

  v_res := public.anular_compra_atomica(v_compra, v_admin);
  v_foto := pg_temp.foto(v_prod);
  IF COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('B · la anulación con un ajuste tenía que rechazarse; devolvió %s', v_res);
  END IF;
  IF v_foto <> '{"stock":150,"lotes":100,"bolsa":50}'::jsonb OR pg_temp.estado(v_compra) <> 'recibida' THEN
    v_fallas := v_fallas || format('B · esperaba stock 150, lote 100, compra recibida; quedó %s, %s',
                                   v_foto, pg_temp.estado(v_compra));
  END IF;

  -- -------------------------------------------------------------------------
  -- C · la nota salió por la puerta por lote; F · esa puerta sigue andando
  -- -------------------------------------------------------------------------
  v_prod   := pg_temp.producto(v_suc, 'ZZ ensayo 1095 C');
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote   := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 100);

  v_res := public.registrar_nota_credito_lote(v_lote, 10, 'ENSAYO-1095-L', 'ensayo 1095 por lote');
  IF NOT COALESCE((v_res->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'F · la nota por lote no se registró: %', v_res;
  END IF;
  v_foto := pg_temp.foto(v_prod);
  SELECT origen, referencia_tipo, referencia_id INTO v_hist
    FROM stock_historico WHERE producto_id = v_prod ORDER BY id DESC LIMIT 1;
  IF v_foto <> '{"stock":140,"lotes":90,"bolsa":50}'::jsonb
     OR NOT EXISTS (SELECT 1 FROM notas_credito
                     WHERE id = (v_res->>'nota_credito_id')::bigint
                       AND compra_id = v_compra AND tipo = 'devolucion')
     OR v_hist.origen IS DISTINCT FROM 'lote_devuelto_proveedor'
     OR v_hist.referencia_id::text IS DISTINCT FROM (v_res->>'nota_credito_id') THEN
    v_fallas := v_fallas || format('F · esperaba stock 140, lote 90, bolsa 50, nota de devolución y ledger lote_devuelto_proveedor; quedó %s, ledger %s',
                                   v_foto, to_jsonb(v_hist));
  END IF;

  v_res := public.anular_compra_atomica(v_compra, v_admin);
  v_foto := pg_temp.foto(v_prod);
  IF COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('C · la anulación con una nota por lote tenía que rechazarse; devolvió %s', v_res);
  END IF;
  IF v_foto->>'stock' <> '140' OR pg_temp.estado(v_compra) <> 'recibida' THEN
    v_fallas := v_fallas || format('C · esperaba stock 140 y compra recibida; quedó %s, %s',
                                   v_foto, pg_temp.estado(v_compra));
  END IF;

  -- -------------------------------------------------------------------------
  -- D · una compra sin notas se sigue anulando; E · y ya no acepta notas
  -- -------------------------------------------------------------------------
  v_prod   := pg_temp.producto(v_suc, 'ZZ ensayo 1095 D');
  v_compra := pg_temp.compra(v_prod, v_suc);
  v_lote   := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 100);

  v_res := public.anular_compra_atomica(v_compra, v_admin);
  v_foto := pg_temp.foto(v_prod);
  SELECT origen, referencia_tipo, referencia_id INTO v_hist
    FROM stock_historico WHERE producto_id = v_prod ORDER BY id DESC LIMIT 1;
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D · la compra sin notas no se anuló: %s', v_res);
  ELSIF v_foto <> '{"stock":50,"lotes":0,"bolsa":50}'::jsonb
     OR pg_temp.estado(v_compra) <> 'cancelada'
     OR EXISTS (SELECT 1 FROM producto_lotes WHERE id = v_lote)
     OR v_hist.origen IS DISTINCT FROM 'compra_anulada' THEN
    v_fallas := v_fallas || format('D · esperaba stock 50, sin lotes, compra cancelada, ledger compra_anulada; quedó %s, %s, ledger %s',
                                   v_foto, pg_temp.estado(v_compra), to_jsonb(v_hist));
  END IF;

  v_res := public.registrar_nota_credito(v_compra, 'ENSAYO-1095', 'ensayo 1095', 0, 0, 0, NULL,
             jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 10,
                                                  'costo_unitario', 10, 'subtotal', 100)), NULL);
  IF COALESCE((v_res->>'success')::boolean, false)
     OR v_res->>'error' IS DISTINCT FROM 'Compra no encontrada o cancelada' THEN
    v_fallas := v_fallas || format('E · la nota sobre una compra cancelada tenía que rechazarse; devolvió %s', v_res);
  END IF;

  -- -------------------------------------------------------------------------
  -- H · un lote colgado de una compra cancelada no genera nota
  -- -------------------------------------------------------------------------
  v_lote := pg_temp.nuevo_lote(v_prod, v_suc, v_compra, v_hoy + 60, 100, 20);
  v_err := NULL;
  BEGIN
    v_res := public.registrar_nota_credito_lote(v_lote, 5, 'ENSAYO-1095-H', 'ensayo 1095 H');
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  SELECT count(*) INTO v_n FROM notas_credito WHERE compra_id = v_compra;
  IF v_err IS NULL OR v_err NOT ILIKE '%cancelada%' OR v_n <> 0 THEN
    v_fallas := v_fallas || format('H · la nota por lote sobre una compra cancelada tenía que rechazarse; error %s, notas %s',
                                   COALESCE(v_err, '(ninguno)'), v_n);
  END IF;

  -- -------------------------------------------------------------------------
  -- G · lote manual
  -- -------------------------------------------------------------------------
  v_prod := pg_temp.producto(v_suc, 'ZZ ensayo 1095 G');
  v_lote := pg_temp.nuevo_lote(v_prod, v_suc, NULL, v_hoy + 60, 100, 100);
  v_err := NULL;
  BEGIN
    v_res := public.registrar_nota_credito_lote(v_lote, 5, 'ENSAYO-1095-G', 'ensayo 1095 G');
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  IF v_err IS NULL OR v_err NOT ILIKE '%no tiene compra de origen%' THEN
    v_fallas := v_fallas || format('G · esperaba el error de lote manual; quedó %s', COALESCE(v_err, '(ninguno)'));
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ensayo-1095-ok' USING ERRCODE = 'ZZ0OK';
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' THEN
  RAISE NOTICE 'ENSAYO OK (todo revertido)';
 END;
END
$ensayo$;
