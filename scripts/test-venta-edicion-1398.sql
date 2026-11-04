-- Ensayo de la migración de la tarjeta 12 de #1378: la venta bloquea los contenedores de sus
-- promos junto con los productos (#1398), y la edición guarda fechas y notas en un paso (#1440,
-- punto 5).
--
-- El 40P01 lo mide el arnés (scripts/concurrencia, C12), porque hacen falta dos sesiones. Acá se
-- prueba en una sola sesión que la venta y el bot siguen haciendo lo mismo, que la edición nueva
-- hace lo que hacían la RPC y el PATCH juntos y con los mismos permisos, y que los cuerpos
-- quedaron con el lock antes del bucle de productos.
--
--   V1 · Una venta de preventista con el regalo de una promo con auto-ajuste y un contenedor
--        distinto del sabor: baja A, cierra un bloque (el contenedor baja 1), la barra queda en 0
--        y el sabor no se mueve (el regalo no mueve stock).
--   V2 · La misma venta por el bot.
--   E1 · El admin cambia notas y fecha de un pedido pendiente: se guardan, no vuelve a pendiente
--        y updated_at no se mueve.
--   E2 · El admin le cambia la fecha programada a un pedido asignado con su parada en una ruta en
--        curso: vuelve a pendiente, sin chofer y fuera de la ruta, con la fecha y las notas nuevas,
--        y devuelve el updated_at de antes y el nuevo.
--   E3 · A un asignado sólo se le cambian las notas: sigue asignado y en la ruta.
--   E4 · Todo o nada, con el preventista dueño de un pedido asignado. Dentro de su ventana (antes
--        de las 15:30 del día de carga) la vuelta a pendiente pasa y el UPDATE se rechaza, porque
--        la fecha del pedido no es suya (pedidos_proteger_columnas): no queda nada a medias. Fuera
--        de la ventana se rechaza la vuelta. En los dos casos el pedido queda como estaba, y el
--        resultado dice cuál de los dos corrió.
--   E5 · Un usuario que no puede editar el pedido (el chofer, en uno sin chofer): P0002. El PATCH
--        de antes no fallaba: no tocaba ninguna fila.
--   P1 · actualizar_fechas_y_notas_pedido es INVOKER, con EXECUTE para authenticated y no para anon.
--   L1 · Los cuerpos: crear_pedido_completo y el bot bloquean productos con contenedores, y las
--        promos, antes del bucle de productos.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre
-- en una excepción, y cada caso en un sub-bloque que se revierte. Antes de aplicar la migración se
-- corre pegado detrás de su cuerpo, sin el BEGIN y el COMMIT; después, solo. Solo y sin la
-- migración tiene que dar 'ENSAYO FALLÓ' por L1 y porque la función de la edición no existe (E1 a
-- E5 y P1); V1 y V2 pasan igual con y sin la migración.
--
-- Fixtures: una sucursal activa con un admin, un preventista y un transportista base activos. El
-- resto nace en el ensayo. Las rutas van en 2099, y los montos superan el mínimo y el envío gratis.

CREATE OR REPLACE FUNCTION pg_temp.t_como(p_uid uuid, p_suc bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_cliente(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1398', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_producto(p_suc bigint, p_nombre text, p_stock int)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (p_nombre, 2000, p_stock, 1200, p_suc)
  RETURNING id;
$fn$;

-- Una venta de crear_pedido_completo como `p_uid`. Falla si la RPC no la crea.
CREATE OR REPLACE FUNCTION pg_temp.t_venta(p_uid uuid, p_suc bigint, p_cli bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t_como(p_uid, p_suc);
  v_res := public.crear_pedido_completo(
    p_cli, (SELECT sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_uid, p_items, 'ensayo 1398');
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_ruta(p_adm uuid, p_suc bigint, p_tr uuid, p_fecha date, VARIADIC p_peds bigint[])
RETURNS bigint LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.t_como(p_adm, p_suc);
  RETURN public.aplicar_orden_ruta(
    p_tr,
    (SELECT jsonb_agg(jsonb_build_object('pedido_id', x, 'orden_entrega', o) ORDER BY o)
       FROM unnest(p_peds) WITH ORDINALITY AS t(x, o)),
    NULL, NULL, NULL, p_fecha);
END
$fn$;

-- La edición como la manda el front: como authenticated, con los claims y la sucursal del
-- usuario. Devuelve lo que devolvió la RPC, o {error, msg} si tiró.
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_uid uuid, p_suc bigint, p_ped bigint, p_notas text,
                                            p_fecha date, p_programada date)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t_como(p_uid, p_suc);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := public.actualizar_fechas_y_notas_pedido(p_ped, p_notas, p_fecha, NULL, p_programada);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_res := jsonb_build_object('error', SQLSTATE, 'msg', SQLERRM);
  END;
  EXECUTE 'RESET ROLE';
  RETURN v_res;
END
$fn$;

-- El ensayo es una sola transacción y now() no avanza: sin esto, la vuelta a pendiente dejaría
-- el mismo updated_at con el que nació el pedido y no se vería si lo movió.
CREATE OR REPLACE FUNCTION pg_temp.t_version_vieja(p_ped bigint)
RETURNS timestamptz LANGUAGE sql AS $fn$
  UPDATE public.pedidos SET updated_at = now() - interval '1 hour' WHERE id = p_ped RETURNING updated_at;
$fn$;

-- Lo que la edición puede tocar de un pedido, y si tiene parada en la ruta.
CREATE OR REPLACE FUNCTION pg_temp.t_estado(p_ped bigint, p_rec bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('%s|chofer=%s|fecha=%s|prog=%s|notas=%s|parada=%s', p.estado, p.transportista_id IS NOT NULL,
                p.fecha, p.fecha_entrega_programada, COALESCE(p.notas, ''),
                EXISTS (SELECT 1 FROM public.recorrido_pedidos rp WHERE rp.pedido_id = p.id AND rp.recorrido_id = p_rec))
    FROM public.pedidos p WHERE p.id = p_ped;
$fn$;

DO $ensayo$
DECLARE
  v_suc    bigint;
  v_adm    uuid;
  v_prev   uuid;
  v_tr     uuid;
  v_a      bigint;
  v_s      bigint;
  v_c      bigint;
  v_b      bigint;
  v_promo  bigint;
  v_cli    bigint;
  v_ped    bigint;
  v_r      bigint;
  v_conf   uuid;
  v_items  jsonb;
  v_j      jsonb;
  v_antes  text;
  v_ver    timestamptz;
  v_txt    text;
  v_bucle  int;
  v_e4     text := '';
  v_fallas text[] := '{}';
  F CONSTANT date := DATE '2099-04-11';
BEGIN
  SELECT s.id, adm.usuario_id, pv.usuario_id, tr.usuario_id
    INTO v_suc, v_adm, v_prev, v_tr
    FROM sucursales s
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'admin'
                   ORDER BY us.usuario_id LIMIT 1) adm ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'preventista'
                   ORDER BY us.usuario_id LIMIT 1) pv ON true
    JOIN LATERAL (SELECT us.usuario_id FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
                   WHERE us.sucursal_id = s.id AND pf.activo AND pf.rol = 'transportista'
                   ORDER BY us.usuario_id LIMIT 1) tr ON true
   WHERE s.activa
   ORDER BY s.id
   LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: ninguna sucursal activa con un admin, un preventista y un transportista';
  END IF;

  -- La promo de V1 y V2: el regalo no mueve stock y cada 2 cierra un bloque del contenedor C.
  v_c := pg_temp.t_producto(v_suc, 'ZZ ensayo 1398 contenedor', 20);
  v_a := pg_temp.t_producto(v_suc, 'ZZ ensayo 1398 A', 100);
  v_s := pg_temp.t_producto(v_suc, 'ZZ ensayo 1398 sabor', 20);
  v_b := pg_temp.t_producto(v_suc, 'ZZ ensayo 1398 B', 100);
  INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id,
                           ajuste_automatico, ajuste_producto_id, unidades_por_bloque, stock_por_bloque)
  VALUES ('ZZ ensayo 1398', 'bonificacion', public._tablero_hoy() - 1, v_suc, false, v_s, true, v_c, 2, 1)
  RETURNING id INTO v_promo;
  INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, v_suc), (v_promo, 'cantidad_bonificacion', 2, v_suc);
  INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_a, v_suc);
  v_items := jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 2000),
    jsonb_build_object('producto_id', v_s, 'cantidad', 2, 'precio_unitario', 0, 'es_bonificacion', true, 'promocion_id', v_promo));
  v_cli := pg_temp.t_cliente(v_suc, 'ZZ ensayo 1398');

  -- V1 · la venta de la app
  BEGIN
    v_ped := pg_temp.t_venta(v_prev, v_suc, v_cli, v_items);
    v_txt := (SELECT format('A=%s C=%s S=%s barra=%s lineas=%s',
                            (SELECT stock FROM productos WHERE id = v_a), (SELECT stock FROM productos WHERE id = v_c),
                            (SELECT stock FROM productos WHERE id = v_s), (SELECT usos_pendientes FROM promociones WHERE id = v_promo),
                            (SELECT count(*) FROM pedido_items WHERE pedido_id = v_ped)));
    IF v_txt IS DISTINCT FROM 'A=90 C=19 S=20 barra=0 lineas=2' THEN
      v_fallas := v_fallas || ('V1 la venta dejó ' || v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ398';
  EXCEPTION
    WHEN SQLSTATE 'ZZ398' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- V2 · la misma venta por el bot
  BEGIN
    -- El bot llega con la service key: sin usuario y sin sucursal activa.
    PERFORM set_config('request.jwt.claims', '{}', true);
    PERFORM set_config('request.headers', '{}', true);
    INSERT INTO bot_pedidos_pendientes (id, perfil_id, sucursal_id, cliente_id, items, total, forma_pago, notas,
                                        consumido, expires_at, cargo_mostrado)
    VALUES (gen_random_uuid(), v_prev, v_suc, v_cli, v_items, 20000, 'efectivo', 'ensayo 1398', false,
            now() + interval '10 minutes', public.pedido_cargo_envio(20000, v_suc))
    RETURNING id INTO v_conf;
    v_j := public.crear_pedido_completo_bot(v_prev, v_conf);
    v_txt := (SELECT format('ok=%s A=%s C=%s S=%s barra=%s', v_j->>'success',
                            (SELECT stock FROM productos WHERE id = v_a), (SELECT stock FROM productos WHERE id = v_c),
                            (SELECT stock FROM productos WHERE id = v_s), (SELECT usos_pendientes FROM promociones WHERE id = v_promo)));
    IF v_txt IS DISTINCT FROM 'ok=true A=90 C=19 S=20 barra=0' THEN
      v_fallas := v_fallas || format('V2 el bot dio %s y dejó %s', v_j, v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ398';
  EXCEPTION
    WHEN SQLSTATE 'ZZ398' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('V2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  v_items := jsonb_build_array(jsonb_build_object('producto_id', v_b, 'cantidad', 10, 'precio_unitario', 2000));

  -- E1 · un pendiente: notas y fecha, sin vuelta a pendiente
  BEGIN
    v_ped := pg_temp.t_venta(v_adm, v_suc, v_cli, v_items);
    v_ver := pg_temp.t_version_vieja(v_ped);
    v_j := pg_temp.t_editar(v_adm, v_suc, v_ped, 'ensayo E1', F - 1, NULL);
    IF v_j ? 'error' OR (v_j->>'vuelto_a_pendiente')::boolean
       OR (v_j->>'updated_at')::timestamptz IS DISTINCT FROM v_ver
       OR (v_j->>'updated_at_anterior')::timestamptz IS DISTINCT FROM v_ver
       OR pg_temp.t_estado(v_ped, NULL) IS DISTINCT FROM format('pendiente|chofer=f|fecha=%s|prog=%s|notas=ensayo E1|parada=f',
                                                               F - 1, (SELECT fecha_entrega_programada FROM pedidos WHERE id = v_ped)) THEN
      v_fallas := v_fallas || format('E1 dio %s y dejó %s', v_j, pg_temp.t_estado(v_ped, NULL));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ398';
  EXCEPTION
    WHEN SQLSTATE 'ZZ398' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E2 · un asignado en ruta al que se le cambia la fecha programada
  BEGIN
    v_ped := pg_temp.t_venta(v_adm, v_suc, v_cli, v_items);
    v_r := pg_temp.t_ruta(v_adm, v_suc, v_tr, F, v_ped);
    IF pg_temp.t_estado(v_ped, v_r) NOT LIKE 'asignado|chofer=t|%|parada=t' THEN
      RAISE EXCEPTION 'E2 el fixture no quedó asignado y en la ruta: %', pg_temp.t_estado(v_ped, v_r);
    END IF;
    v_ver := pg_temp.t_version_vieja(v_ped);
    v_j := pg_temp.t_editar(v_adm, v_suc, v_ped, 'ensayo E2', NULL, F + 1);
    IF v_j ? 'error' OR NOT (v_j->>'vuelto_a_pendiente')::boolean OR v_j->>'paradas_eliminadas' IS DISTINCT FROM '1'
       OR (v_j->>'updated_at_anterior')::timestamptz IS DISTINCT FROM v_ver
       OR (v_j->>'updated_at')::timestamptz IS NOT DISTINCT FROM v_ver
       OR (v_j->>'updated_at')::timestamptz IS DISTINCT FROM (SELECT updated_at FROM pedidos WHERE id = v_ped)
       OR pg_temp.t_estado(v_ped, v_r) NOT LIKE format('pendiente|chofer=f|%%|prog=%s|notas=ensayo E2|parada=f', F + 1) THEN
      v_fallas := v_fallas || format('E2 dio %s y dejó %s', v_j, pg_temp.t_estado(v_ped, v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ398';
  EXCEPTION
    WHEN SQLSTATE 'ZZ398' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E3 · un asignado al que sólo se le cambian las notas
  BEGIN
    v_ped := pg_temp.t_venta(v_adm, v_suc, v_cli, v_items);
    v_r := pg_temp.t_ruta(v_adm, v_suc, v_tr, F, v_ped);
    v_j := pg_temp.t_editar(v_adm, v_suc, v_ped, 'ensayo E3', NULL,
                            (SELECT fecha_entrega_programada FROM pedidos WHERE id = v_ped));
    IF v_j ? 'error' OR (v_j->>'vuelto_a_pendiente')::boolean
       OR pg_temp.t_estado(v_ped, v_r) NOT LIKE 'asignado|chofer=t|%|notas=ensayo E3|parada=t' THEN
      v_fallas := v_fallas || format('E3 dio %s y dejó %s', v_j, pg_temp.t_estado(v_ped, v_r));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ398';
  EXCEPTION
    WHEN SQLSTATE 'ZZ398' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E4 · todo o nada: el preventista dueño de un asignado
  BEGIN
    v_ped := pg_temp.t_venta(v_prev, v_suc, v_cli, v_items);
    v_r := pg_temp.t_ruta(v_adm, v_suc, v_tr, F, v_ped);
    v_antes := pg_temp.t_estado(v_ped, v_r);
    v_j := pg_temp.t_editar(v_prev, v_suc, v_ped, 'ensayo E4', F - 1, F + 1);
    IF public._preventista_en_ventana((SELECT created_at FROM pedidos WHERE id = v_ped)) THEN
      v_e4 := 'en ventana: la vuelta pasó y el UPDATE se rechazó';
      v_txt := '%modificar estas columnas%fecha%';
    ELSE
      v_e4 := 'fuera de la ventana: se rechazó la vuelta';
      v_txt := '%antes de las 15:30%';
    END IF;
    IF v_j->>'error' IS DISTINCT FROM '42501'
       OR v_j->>'msg' NOT LIKE v_txt
       OR pg_temp.t_estado(v_ped, v_r) IS DISTINCT FROM v_antes
       OR v_antes NOT LIKE 'asignado|chofer=t|%|parada=t' THEN
      v_fallas := v_fallas || format('E4 (%s) dio %s y dejó %s (antes %s)', v_e4, v_j, pg_temp.t_estado(v_ped, v_r), v_antes);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ398';
  EXCEPTION
    WHEN SQLSTATE 'ZZ398' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E4 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- E5 · quien no puede editar el pedido
  BEGIN
    v_ped := pg_temp.t_venta(v_adm, v_suc, v_cli, v_items);
    v_antes := pg_temp.t_estado(v_ped, NULL);
    v_j := pg_temp.t_editar(v_tr, v_suc, v_ped, 'ensayo E5', NULL, F + 1);
    IF v_j->>'error' IS DISTINCT FROM 'P0002' OR pg_temp.t_estado(v_ped, NULL) IS DISTINCT FROM v_antes THEN
      v_fallas := v_fallas || format('E5 dio %s y dejó %s', v_j, pg_temp.t_estado(v_ped, NULL));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZ398';
  EXCEPTION
    WHEN SQLSTATE 'ZZ398' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E5 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- P1 · los permisos de la función nueva
  IF to_regprocedure('public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)') IS NULL THEN
    v_fallas := v_fallas || 'P1 actualizar_fechas_y_notas_pedido no existe'::text;
  ELSIF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)'::regprocedure)
        OR NOT has_function_privilege('authenticated', 'public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)', 'EXECUTE')
        OR has_function_privilege('anon', 'public.actualizar_fechas_y_notas_pedido(bigint,text,date,timestamp with time zone,date)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'P1 actualizar_fechas_y_notas_pedido: tiene que ser INVOKER, con EXECUTE para authenticated y no para anon'::text;
  END IF;

  -- L1 · el lock antes del bucle de productos, en las dos
  FOR v_txt IN SELECT prosrc FROM pg_proc
                WHERE oid IN ('public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure,
                              'public.crear_pedido_completo_bot(uuid,uuid)'::regprocedure) LOOP
    v_bucle := position('FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP' IN v_txt);
    IF position('_contenedores_de_promos(v_promos_regalo' IN v_txt) NOT BETWEEN 1 AND v_bucle
       OR position('PERFORM 1 FROM promociones' IN v_txt) NOT BETWEEN 1 AND v_bucle THEN
      v_fallas := v_fallas || ('L1 ' || CASE WHEN v_txt LIKE '%v_pendiente%' THEN 'crear_pedido_completo_bot' ELSE 'crear_pedido_completo' END
                               || ' no bloquea los contenedores y las promos antes del bucle de productos');
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · V1 V2 E1 E2 E3 E4 (%) E5 P1 L1', v_e4;
END
$ensayo$;
