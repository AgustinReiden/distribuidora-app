-- Ensayo de la migración de la tarjeta 14 de #1378 (#1460: C2, C3, C5 y C8): los caminos de stock
-- y promos que no seguían el orden global de locks, productos (con sus contenedores) por id y las
-- promos después.
--
-- El 40P01 lo mide el arnés (scripts/concurrencia, T14), porque hacen falta dos sesiones. Acá se
-- prueba en una sola sesión que cada camino sigue haciendo lo mismo, y que los cuerpos quedaron con
-- el lock antes de la primera fila.
--
--   V0 · Una venta de A con el regalo de una promo con auto-ajuste (el regalo no mueve stock y cada
--        2 cierran un bloque del contenedor C): A baja 10, C baja 1 y la barra queda en 0.
--   A1 · ajustar_stock_promocion_completo de 1 de C por 1 uso, con la barra en 1: C baja 1, la
--        barra queda en 0 y queda la merma 'promociones'.
--   A2 · Lo mismo por 5 usos con la barra en 0: el mismo rechazo de siempre, y nada se mueve.
--   F1 · Cambiar el factor de la promo (unidades_por_bloque 2 → 1) con la barra en 1: cierra un
--        bloque, C baja 1 y la barra queda en 0.
--   E1 · Editar X de A a B: A vuelve a 100, B baja 10, C queda igual (la barra vuelve y se cierra
--        de nuevo) y X queda con dos líneas.
--   S1 · Una salvedad de 5 de B en X (cliente_rechaza): B sube 5, el regalo cae (5 no alcanzan
--        para la promo) y su bloque se deshace: C sube 1.
--   D1 · eliminar_pedido_completo de X restaurando el stock (como el server: no tiene EXECUTE para
--        authenticated): B vuelve a 100, C queda igual (X ya no tiene regalo) y X ya no existe.
--   M1 · actualizar_precios_masivo con [B, A, "abc", un id fuera de rango]: actualiza B y A, y
--        devuelve los dos errores de siempre, uno por cada id que no sirve.
--   T1 · trg_promo_factor_bloquea_contenedores existe (BEFORE, de sentencia, OF las dos columnas
--        del factor), y su función es DEFINER y sin EXECUTE para anon ni authenticated.
--   L1 · Los cuerpos: cada pre-bloqueo está antes de la primera sentencia que toma filas.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre
-- en una excepción. Los casos van en orden sobre el mismo pedido, dentro de esa transacción. Antes
-- de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después,
-- solo. Solo y sin la migración tiene que dar 'ENSAYO FALLÓ' por T1 y L1, y nada más: V0, A1,
-- A2, F1, E1, S1, D1 y M1 pasan igual con y sin la migración.
--
-- Fixtures: una sucursal activa con un admin activo. El resto nace en el ensayo. Los montos
-- superan el mínimo y el envío gratis.

CREATE OR REPLACE FUNCTION pg_temp.t_como(p_uid uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text, p_stock int)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 2000, p_stock, 1200, p_suc)
  RETURNING id;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_a      bigint;
  v_b      bigint;
  v_s      bigint;
  v_c      bigint;
  v_promo  bigint;
  v_cli    bigint;
  v_ped    bigint;
  v_j      jsonb;
  v_txt    text;
  v_src    text;
  v_fallas text[] := '{}';
BEGIN
  SELECT s.id, adm.usuario_id INTO v_suc, v_adm
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin';
  END IF;
  PERFORM pg_temp.t_como(v_adm, v_suc);

  v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1460 contenedor', 20);
  v_a := pg_temp.t_producto(v_suc, 'ZZ ensayo 1460 A', 100);
  v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1460 B', 100);
  v_s := pg_temp.t_producto(v_suc, 'ZZ ensayo 1460 sabor', 20);
  INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                           ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
  VALUES ('ZZ ensayo 1460', 'bonificacion', public._tablero_hoy() - 1, v_suc, false, v_s, true, v_c, 2, 1)
  RETURNING id INTO v_promo;
  INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_a, v_suc), (v_promo, v_b, v_suc);
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo 1460', 'ZZ ensayo 1460', 'Ensayo 1460', v_suc) RETURNING id INTO v_cli;

  -- V0 · la venta
  v_j := public.crear_pedido_completo(v_cli, 20000, v_adm, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 2000),
    jsonb_build_object('producto_id', v_s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo)),
    'ensayo 1460');
  IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · V0 no se pudo crear el pedido: %', v_j;
  END IF;
  v_ped := (v_j->>'pedido_id')::bigint;
  v_txt := format('A=%s C=%s barra=%s', (SELECT stock FROM productos WHERE id = v_a), (SELECT stock FROM productos WHERE id = v_c),
                  (SELECT usos_pendientes FROM promociones WHERE id = v_promo));
  IF v_txt IS DISTINCT FROM 'A=90 C=19 barra=0' THEN
    v_fallas := v_fallas || ('V0 la venta dejó ' || v_txt);
  END IF;

  -- A1 · ajustar 1 de C por 1 uso
  UPDATE promociones SET usos_pendientes = 1 WHERE id = v_promo;
  v_j := public.ajustar_stock_promocion_completo(v_promo, v_c, 1, 1, v_adm, 'ensayo 1460');
  v_txt := format('ok=%s ant=%s nue=%s usos=%s C=%s barra=%s merma=%s', v_j->>'success', v_j->>'stock_anterior', v_j->>'stock_nuevo',
                  v_j->>'usos_ajustados', (SELECT stock FROM productos WHERE id = v_c),
                  (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
                  (SELECT motivo || '/' || cantidad FROM mermas_stock WHERE id = (v_j->>'merma_id')::bigint));
  IF v_txt IS DISTINCT FROM 'ok=true ant=19 nue=18 usos=1 C=18 barra=0 merma=promociones/1' THEN
    v_fallas := v_fallas || ('A1 ajustar dejó ' || v_txt);
  END IF;

  -- A2 · el rechazo de siempre
  v_j := public.ajustar_stock_promocion_completo(v_promo, v_c, 1, 5, v_adm, 'ensayo 1460');
  IF v_j IS DISTINCT FROM jsonb_build_object('success', false, 'error', 'No se pueden ajustar mas usos (5) que los pendientes (0)')
     OR (SELECT stock FROM productos WHERE id = v_c) <> 18 THEN
    v_fallas := v_fallas || ('A2 ajustar de más dio ' || v_j::text);
  END IF;

  -- F1 · cambiar el factor con la barra en 1
  UPDATE promociones SET usos_pendientes = 1 WHERE id = v_promo;
  UPDATE promociones SET unidades_por_bloque = 1 WHERE id = v_promo;
  v_txt := format('C=%s barra=%s ajuste=%s', (SELECT stock FROM productos WHERE id = v_c),
                  (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
                  (SELECT string_agg(usos_ajustados || '/' || unidades_ajustadas, ',' ORDER BY id) FROM promo_ajustes
                    WHERE promocion_id = v_promo AND producto_id = v_c AND merma_id IS NOT NULL
                      AND observaciones LIKE 'Cambio de factor%'));
  IF v_txt IS DISTINCT FROM 'C=17 barra=0 ajuste=1/1' THEN
    v_fallas := v_fallas || ('F1 el cambio de factor dejó ' || v_txt);
  END IF;
  UPDATE promociones SET unidades_por_bloque = 2 WHERE id = v_promo;

  -- E1 · editar X de A a B
  v_j := public.actualizar_pedido_items(v_ped, jsonb_build_array(
    jsonb_build_object('producto_id', v_b, 'cantidad', 10, 'precio_unitario', 2000),
    jsonb_build_object('producto_id', v_s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo)),
    v_adm, NULL, NULL);
  v_txt := format('ok=%s A=%s B=%s C=%s barra=%s lineas=%s', v_j->>'success', (SELECT stock FROM productos WHERE id = v_a),
                  (SELECT stock FROM productos WHERE id = v_b), (SELECT stock FROM productos WHERE id = v_c),
                  (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
                  (SELECT count(*) FROM pedido_items WHERE pedido_id = v_ped));
  IF v_txt IS DISTINCT FROM 'ok=true A=100 B=90 C=17 barra=0 lineas=2' THEN
    v_fallas := v_fallas || ('E1 la edición dejó ' || v_txt || ' ' || v_j::text);
  END IF;

  -- S1 · una salvedad de 5 de B en X: devuelve 5, el regalo cae y su bloque se deshace
  v_j := public.registrar_salvedad(v_ped, (SELECT id FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_b),
                                   5, 'cliente_rechaza', 'ensayo 1460', NULL, true, NULL);
  v_txt := format('ok=%s B=%s C=%s barra=%s regalo=%s', v_j->>'success', (SELECT stock FROM productos WHERE id = v_b),
                  (SELECT stock FROM productos WHERE id = v_c), (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
                  (SELECT COALESCE(sum(cantidad), 0) FROM pedido_items WHERE pedido_id = v_ped AND es_bonificacion));
  IF v_txt IS DISTINCT FROM 'ok=true B=95 C=18 barra=0 regalo=0' THEN
    v_fallas := v_fallas || ('S1 la salvedad dejó ' || v_txt || ' ' || v_j::text);
  END IF;

  -- D1 · eliminar X restaurando el stock
  v_j := public.eliminar_pedido_completo(v_ped, v_adm, 'ensayo 1460', true);
  v_txt := format('ok=%s rest=%s B=%s C=%s barra=%s existe=%s', v_j->>'success', v_j->>'stock_restaurado',
                  (SELECT stock FROM productos WHERE id = v_b), (SELECT stock FROM productos WHERE id = v_c),
                  (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
                  EXISTS (SELECT 1 FROM pedidos WHERE id = v_ped));
  IF v_txt IS DISTINCT FROM 'ok=true rest=true B=100 C=18 barra=0 existe=f' THEN
    v_fallas := v_fallas || ('D1 eliminar dejó ' || v_txt || ' ' || v_j::text);
  END IF;

  -- M1 · precios masivos con dos ids que no sirven
  v_j := public.actualizar_precios_masivo(jsonb_build_array(
    jsonb_build_object('producto_id', v_b, 'precio_final', 2222),
    jsonb_build_object('producto_id', v_a, 'precio_final', 1111),
    jsonb_build_object('producto_id', 'abc', 'precio_final', 1),
    jsonb_build_object('producto_id', '99999999999999999999', 'precio_final', 1)));
  v_txt := format('ok=%s act=%s err=%s A=%s B=%s', v_j->>'success', v_j->>'actualizados', jsonb_array_length(v_j->'errores'),
                  (SELECT precio FROM productos WHERE id = v_a), (SELECT precio FROM productos WHERE id = v_b));
  IF v_txt IS DISTINCT FROM 'ok=false act=2 err=2 A=1111.00 B=2222.00'
     OR (v_j->'errores'->>0) NOT LIKE 'Error en producto ID %: invalid input syntax for type integer: "abc"'
     OR (v_j->'errores'->>1) NOT LIKE 'Error en producto ID %: value "99999999999999999999" is out of range for type integer' THEN
    v_fallas := v_fallas || ('M1 precios masivos dio ' || v_txt || ' ' || v_j::text);
  END IF;

  -- T1 · el trigger del cambio de factor
  IF NOT EXISTS (SELECT 1 FROM pg_trigger t
                  WHERE t.tgrelid = 'public.promociones'::regclass AND t.tgname = 'trg_promo_factor_bloquea_contenedores'
                    AND pg_get_triggerdef(t.oid) = 'CREATE TRIGGER trg_promo_factor_bloquea_contenedores BEFORE UPDATE OF unidades_por_bloque, stock_por_bloque ON public.promociones FOR EACH STATEMENT EXECUTE FUNCTION promo_factor_bloquea_contenedores()') THEN
    v_fallas := v_fallas || 'T1 trg_promo_factor_bloquea_contenedores no existe o no es BEFORE de sentencia OF las dos columnas'::text;
  ELSIF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.promo_factor_bloquea_contenedores()'::regprocedure)
        OR has_function_privilege('authenticated', 'public.promo_factor_bloquea_contenedores()', 'EXECUTE')
        OR has_function_privilege('anon', 'public.promo_factor_bloquea_contenedores()', 'EXECUTE') THEN
    v_fallas := v_fallas || 'T1 promo_factor_bloquea_contenedores tiene que ser DEFINER y sin EXECUTE para anon ni authenticated'::text;
  END IF;

  -- L1 · cada pre-bloqueo antes de la primera sentencia que toma filas
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = 'public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)'::regprocedure);
  IF position('#1460 (C2)' IN v_src) NOT BETWEEN 1 AND position('FROM promociones WHERE id = p_promocion_id' IN v_src) THEN
    v_fallas := v_fallas || 'L1 ajustar_stock_promocion_completo no bloquea el producto antes que la promo'::text;
  END IF;
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = 'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
  IF position('#1460 (C3)' IN v_src) NOT BETWEEN position('_contenedores_de_promos(' IN v_src) AND position('aplicar_uso_promo_acumulador(' IN v_src) THEN
    v_fallas := v_fallas || 'L1 actualizar_pedido_items no bloquea las promos entre los productos y el motor'::text;
  END IF;
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
  IF position('#1460 (C4)' IN v_src) NOT BETWEEN position('_contenedores_de_promos(' IN v_src) AND position('UPDATE pedidos' IN v_src) THEN
    v_fallas := v_fallas || 'L1 registrar_salvedad no bloquea las promos entre los productos y el total'::text;
  END IF;
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = 'public.eliminar_pedido_completo(bigint,uuid,text,boolean)'::regprocedure);
  IF position('#1460 (C5)' IN v_src) NOT BETWEEN 1 AND position('FOR v_item IN' IN v_src) THEN
    v_fallas := v_fallas || 'L1 eliminar_pedido_completo no bloquea productos y promos antes del bucle'::text;
  END IF;
  v_src := (SELECT prosrc FROM pg_proc WHERE oid = 'public.actualizar_precios_masivo(jsonb)'::regprocedure);
  IF position('#1460 (C8)' IN v_src) NOT BETWEEN 1 AND position('FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)' IN v_src) THEN
    v_fallas := v_fallas || 'L1 actualizar_precios_masivo no bloquea los productos antes del bucle'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · V0 A1 A2 F1 E1 S1 D1 M1 T1 L1';
END
$ensayo$;
