-- Ensayo de la migracion alicuota_de_la_linea_recreada (#1274).
--
-- anular_salvedad, con la linea borrada, la recrea. La alicuota era
-- COALESCE(productos.porcentaje_iva, 21): la de hoy, y 21 para un exento sin
-- porcentaje. Ahora es la foto de la linea, que queda en la fila de su DELETE en
-- audit_logs, y si no la hay, _alicuota_iva_venta.
--
-- En prod los 355 productos son gravados al 21: un caso al 21 no prueba nada.
-- Cada caso vende 1 x 1.210 en FC y la salvedad borra la linea, asi que lo que
-- queda se lee directo: 21% = neto 1.000 e IVA 210; 10,5% = 1.095,02 y 114,98;
-- sin IVA = 1.210 y 0.
--
--   A · exento sin porcentaje              -> foto 0                     [F]
--   B · no gravado sin porcentaje          -> foto 0                     [F]
--   C · gravado al 10,5                    -> foto 10,5                  [R]
--   D · gravado sin porcentaje             -> foto 21                    [R]
--   E · vendido al 21, hoy al 10,5         -> foto 21, no el de hoy      [F]
--   F · vendido al 21, hoy exento          -> foto 21                    [F]
--   G · foto 0 de legado, hoy al 10,5      -> cae al producto: 10,5      [R]
--   H · sin fila en el log, hoy exento     -> _alicuota_iva_venta: 0     [F]
--   I · el regalo del mismo producto se borro despues, con foto 0
--                                          -> la de la venta: 21         [F]
--   J · el mismo producto en dos pedidos, con dos fotos
--                                          -> cada uno la suya           [F]
--   K · anular_salvedad sigue siendo definer, de authenticated y sin anon
--
-- [F] falla antes de la migracion, [R] es regresion. Corre contra prod SIN dejar
-- rastro: un unico DO que termina SIEMPRE en RAISE EXCEPTION, asi que todo lo que
-- escribe se deshace. Los helpers viven en pg_temp.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
--   psql "$DATABASE_URL" -1 -f scripts/test-alicuota-linea-recreada-1274.sql

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_condicion text, p_porcentaje numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, condicion_iva, porcentaje_iva,
                                impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo 1274', 1210, 1000, 600, p_condicion, p_porcentaje, 0, p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_vender(p_cli bigint, p_adm uuid, p_prod bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  r jsonb;
BEGIN
  r := public.crear_pedido_completo(p_cli, 1210, p_adm,
         jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', 1, 'precio_unitario', 1210)),
         'ensayo 1274', 'efectivo', 'pendiente', NULL, 'FC');
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', r;
  END IF;
  RETURN (r->>'pedido_id')::bigint;
END
$fn$;

-- La salvedad rechaza la linea entera, asi que la borra.
CREATE OR REPLACE FUNCTION pg_temp.t_borrar(p_ped bigint, p_prod bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  r jsonb;
  v_item bigint;
BEGIN
  SELECT id INTO STRICT v_item FROM public.pedido_items WHERE pedido_id = p_ped AND producto_id = p_prod;
  r := public.registrar_salvedad(p_ped, v_item, 1, 'cliente_rechaza',
                                 'ensayo 1274: descripcion del caso', NULL, true, NULL);
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar: %', r;
  END IF;
  IF EXISTS (SELECT 1 FROM public.pedido_items WHERE id = v_item) THEN
    RAISE EXCEPTION 'la salvedad no borro la linea %', v_item;
  END IF;
  RETURN (r->>'salvedad_id')::bigint;
END
$fn$;

-- Anula y compara la linea recreada y el pedido. NULL = todo bien.
CREATE OR REPLACE FUNCTION pg_temp.t_anular(p_caso text, p_ped bigint, p_prod bigint, p_salv bigint,
                                            p_foto numeric, p_neto numeric, p_iva numeric)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  r jsonb;
  l record;
  p record;
BEGIN
  r := public.anular_salvedad(p_salv, 'ensayo 1274');
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RETURN format('%s anular: %s', p_caso, r);
  END IF;
  SELECT porcentaje_iva, neto_unitario, iva_unitario INTO STRICT l
    FROM public.pedido_items WHERE pedido_id = p_ped AND producto_id = p_prod;
  SELECT total, total_neto, total_iva INTO STRICT p FROM public.pedidos WHERE id = p_ped;
  IF l.porcentaje_iva IS DISTINCT FROM p_foto OR l.neto_unitario IS DISTINCT FROM p_neto
     OR l.iva_unitario IS DISTINCT FROM p_iva OR p.total <> 1210
     OR p.total_neto <> p_neto OR p.total_iva <> p_iva THEN
    RETURN format('%s: foto %s, neto %s, IVA %s, pedido %s = %s + %s; esperado foto %s, neto %s, IVA %s',
                  p_caso, l.porcentaje_iva, l.neto_unitario, l.iva_unitario,
                  p.total, p.total_neto, p.total_iva, p_foto, p_neto, p_iva);
  END IF;
  RETURN NULL;
END
$fn$;

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_admin  uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_ped2   bigint;
  v_salv   bigint;
  v_salv2  bigint;
  c        record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- --------------------------------------------------------- contexto ---
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un admin activo con una sucursal activa';
  END IF;
  -- Sin saldo a favor: un credito se imputaria a los pedidos del ensayo.
  SELECT cl.id INTO v_cli FROM clientes cl
   WHERE cl.sucursal_id = v_suc AND cl.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = cl.id AND pg.pedido_id IS NULL)
   ORDER BY cl.id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);

  -- Sin cargo de envio ni compra minima que muevan los totales.
  INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
  VALUES (v_suc, 'bloquear', 0, 0, 500)
  ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
    monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
    cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;

  -- ======================================== A a D · los cuatro productos ===
  FOR c IN
    SELECT * FROM (VALUES
      ('A exento',     'exento',     NULL::numeric, 0::numeric, 1210::numeric, 0::numeric),
      ('B no gravado', 'no_gravado', NULL,          0,          1210,          0),
      ('C 10,5',       'gravado',    10.5,          10.5,       1095.02,       114.98),
      ('D sin %',      'gravado',    NULL,          21,         1000,          210)
    ) AS x(caso, condicion, porcentaje, foto, neto, iva)
  LOOP
    BEGIN
      v_prod := pg_temp.t_producto(v_suc, c.condicion, c.porcentaje);
      v_ped  := pg_temp.t_vender(v_cli, v_admin, v_prod);
      v_salv := pg_temp.t_borrar(v_ped, v_prod);
      v_fallas := v_fallas || pg_temp.t_anular(c.caso, v_ped, v_prod, v_salv, c.foto, c.neto, c.iva);
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('%s · error: %s', c.caso, SQLERRM);
    END;
  END LOOP;

  -- ===================================== E · el producto cambio al 10,5 ===
  BEGIN
    v_prod := pg_temp.t_producto(v_suc, 'gravado', 21);
    v_ped  := pg_temp.t_vender(v_cli, v_admin, v_prod);
    v_salv := pg_temp.t_borrar(v_ped, v_prod);
    UPDATE productos SET porcentaje_iva = 10.5 WHERE id = v_prod;
    v_fallas := v_fallas || pg_temp.t_anular('E hoy al 10,5', v_ped, v_prod, v_salv, 21, 1000, 210);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('E · error: %s', SQLERRM);
  END;

  -- ======================================= F · el producto paso a exento ===
  BEGIN
    v_prod := pg_temp.t_producto(v_suc, 'gravado', 21);
    v_ped  := pg_temp.t_vender(v_cli, v_admin, v_prod);
    v_salv := pg_temp.t_borrar(v_ped, v_prod);
    UPDATE productos SET condicion_iva = 'exento', porcentaje_iva = 0 WHERE id = v_prod;
    v_fallas := v_fallas || pg_temp.t_anular('F hoy exento', v_ped, v_prod, v_salv, 21, 1000, 210);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('F · error: %s', SQLERRM);
  END;

  -- ================================================ G · foto 0 de legado ===
  BEGIN
    v_prod := pg_temp.t_producto(v_suc, 'gravado', 21);
    v_ped  := pg_temp.t_vender(v_cli, v_admin, v_prod);
    UPDATE pedido_items SET porcentaje_iva = 0 WHERE pedido_id = v_ped;
    v_salv := pg_temp.t_borrar(v_ped, v_prod);
    UPDATE productos SET porcentaje_iva = 10.5 WHERE id = v_prod;
    v_fallas := v_fallas || pg_temp.t_anular('G foto 0', v_ped, v_prod, v_salv, 10.5, 1095.02, 114.98);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('G · error: %s', SQLERRM);
  END;

  -- ============================================= H · sin fila en el log ===
  BEGIN
    v_prod := pg_temp.t_producto(v_suc, 'gravado', 21);
    v_ped  := pg_temp.t_vender(v_cli, v_admin, v_prod);
    v_salv := pg_temp.t_borrar(v_ped, v_prod);
    DELETE FROM audit_logs
     WHERE tabla = 'pedido_items' AND accion = 'DELETE' AND old_data->>'pedido_id' = v_ped::text;
    IF NOT FOUND THEN
      v_fallas := v_fallas || 'H el borrado de la linea no dejo fila en audit_logs';
    END IF;
    UPDATE productos SET condicion_iva = 'exento', porcentaje_iva = NULL WHERE id = v_prod;
    v_fallas := v_fallas || pg_temp.t_anular('H sin log', v_ped, v_prod, v_salv, 0, 1210, 0);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('H · error: %s', SQLERRM);
  END;

  -- ======================================== I · el regalo no da la foto ===
  -- El borrado del regalo se simula: una salvedad que se lleve venta y regalo
  -- del mismo producto no pasa el guard de promos de anular. Va un segundo
  -- despues para que sea la fila mas nueva: dentro de la transaccion del
  -- ensayo, now() empata.
  BEGIN
    v_prod := pg_temp.t_producto(v_suc, 'gravado', 21);
    v_ped  := pg_temp.t_vender(v_cli, v_admin, v_prod);
    v_salv := pg_temp.t_borrar(v_ped, v_prod);
    INSERT INTO audit_logs (tabla, registro_id, accion, old_data, sucursal_id, created_at)
    VALUES ('pedido_items', '0', 'DELETE',
            jsonb_build_object('pedido_id', v_ped, 'producto_id', v_prod, 'porcentaje_iva', 0, 'es_bonificacion', true),
            v_suc, now() + interval '1 second');
    UPDATE productos SET porcentaje_iva = 10.5 WHERE id = v_prod;
    v_fallas := v_fallas || pg_temp.t_anular('I regalo', v_ped, v_prod, v_salv, 21, 1000, 210);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('I · error: %s', SQLERRM);
  END;

  -- ===================================== J · cada pedido con su foto ===
  BEGIN
    v_prod  := pg_temp.t_producto(v_suc, 'gravado', 21);
    v_ped   := pg_temp.t_vender(v_cli, v_admin, v_prod);
    v_salv  := pg_temp.t_borrar(v_ped, v_prod);
    UPDATE productos SET porcentaje_iva = 10.5 WHERE id = v_prod;
    v_ped2  := pg_temp.t_vender(v_cli, v_admin, v_prod);
    v_salv2 := pg_temp.t_borrar(v_ped2, v_prod);
    UPDATE productos SET porcentaje_iva = 21 WHERE id = v_prod;
    v_fallas := v_fallas || pg_temp.t_anular('J pedido al 21', v_ped, v_prod, v_salv, 21, 1000, 210);
    v_fallas := v_fallas || pg_temp.t_anular('J pedido al 10,5', v_ped2, v_prod, v_salv2, 10.5, 1095.02, 114.98);
  EXCEPTION WHEN OTHERS THEN
    v_fallas := v_fallas || format('J · error: %s', SQLERRM);
  END;

  -- ================================================== K · permisos ===
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure) THEN
    v_fallas := v_fallas || 'K anular_salvedad dejo de ser SECURITY DEFINER';
  END IF;
  IF has_function_privilege('anon', 'public.anular_salvedad(bigint,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.anular_salvedad(bigint,text)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'K los permisos de anular_salvedad cambiaron';
  END IF;

  v_fallas := array_remove(v_fallas, NULL);
  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · la linea recreada lleva la foto de su venta, y sin foto la regla sobre el producto';
END
$ensayo$;
