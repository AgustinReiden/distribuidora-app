-- Ensayo de la limpieza de la tarjeta 10 de #1389: los pasos A y B (#1336, #1368, #1383).
--
--   Z1 · bot_buscar_cliente y bot_mis_clientes devuelven el nombre de la zona del cliente (de
--        `zonas`), y NULL sin zona.
--   Z2 · clientes_ritmo_compra da el nombre de la zona, o 'SIN ZONA'. Sólo lista clientes con
--        compras: si no aparecen, el resultado lo dice.
--   M1 · bot_metricas_admin_dia devuelve rendiciones_pendientes = {count: 0, dias_mas_vieja: 0}.
--   R1 · El preventista dueño le cambia notas y fecha programada a su pedido pendiente por
--        actualizar_fechas_y_notas_pedido (455, INVOKER: pasa por pedidos_proteger_columnas):
--        se guardan.
--   R2 · Lo mismo sobre su pedido asignado y en una ruta. Dentro de su ventana (antes de las
--        15:30 del día de carga) vuelve a pendiente, sin chofer y fuera de la ruta, con las notas
--        y la fecha nuevas. Fuera de la ventana se rechaza con el mensaje de las 15:30 y el pedido
--        queda como estaba. El resultado dice cuál de los dos corrió.
--   R3 · El PATCH viejo del vendedor (estado 'pendiente' y sin chofer sobre su asignado, como
--        authenticated). Antes del paso B pasa por la rama del vendedor; después da 42501 (#1383).
--   D1 · Después del paso B no quedan clientes.zona, clientes.preventista_id, las tres tablas
--        viejas, vista_rendiciones ni las tres funciones que se fueron con ellas.
--
-- R1 y R2 tienen que dar lo mismo antes y después del paso B: esa es la prueba de que la edición
-- de la 455 no dependía de la rama del vendedor. Z1, Z2 y M1 piden el paso A. El ensayo detecta
-- solo si el paso B está aplicado.
--
-- Corre contra prod sin dejar rastro (salvo valores de secuencia): un único DO que termina siempre
-- en una excepción, y cada caso en un sub-bloque que se revierte.
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

CREATE OR REPLACE FUNCTION pg_temp.t_venta(p_uid uuid, p_suc bigint, p_cli bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t_como(p_uid, p_suc);
  v_res := public.crear_pedido_completo(
    p_cli, (SELECT sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric) FROM jsonb_array_elements(p_items) e),
    p_uid, p_items, 'ensayo t10');
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

-- La edición como la manda el front: como authenticated. Devuelve lo que devolvió la RPC, o
-- {error, msg} si tiró.
CREATE OR REPLACE FUNCTION pg_temp.t_editar(p_uid uuid, p_suc bigint, p_ped bigint, p_notas text, p_programada date)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.t_como(p_uid, p_suc);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := public.actualizar_fechas_y_notas_pedido(p_ped, p_notas, NULL, NULL, p_programada);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_res := jsonb_build_object('error', SQLSTATE, 'msg', SQLERRM);
  END;
  EXECUTE 'RESET ROLE';
  RETURN v_res;
END
$fn$;

-- El PATCH de los bundles de antes de #1372: estado y chofer por REST, como authenticated.
CREATE OR REPLACE FUNCTION pg_temp.t_patch_vendedor(p_uid uuid, p_suc bigint, p_ped bigint)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_res text;
BEGIN
  PERFORM pg_temp.t_como(p_uid, p_suc);
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE public.pedidos SET estado = 'pendiente', transportista_id = NULL WHERE id = p_ped;
    v_res := 'ok';
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_estado(p_ped bigint, p_rec bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('%s|chofer=%s|prog=%s|notas=%s|parada=%s', p.estado, p.transportista_id IS NOT NULL,
                p.fecha_entrega_programada, COALESCE(p.notas, ''),
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
  v_z      bigint;
  v_cli    bigint;
  v_cli2   bigint;
  v_ped    bigint;
  v_r      bigint;
  v_items  jsonb;
  v_j      jsonb;
  v_antes  text;
  v_txt    text;
  v_b      boolean := to_regclass('public.rendiciones') IS NULL;  -- el paso B está aplicado
  v_r2     text := '';
  v_z2     text := '';
  v_fallas text[] := '{}';
  F CONSTANT date := DATE '2099-05-11';
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

  -- Una zona sin dueño (así el alta no reasigna) y dos clientes: con zona y sin zona.
  INSERT INTO zonas (nombre, sucursal_id) VALUES ('ZZ ensayo t10', v_suc) RETURNING id INTO v_z;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id, zona_id)
  VALUES ('ZZ ensayo t10 con zona', 'ZZ ensayo t10 con zona', 'Ensayo t10', v_suc, v_z) RETURNING id INTO v_cli;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo t10 sin zona', 'ZZ ensayo t10 sin zona', 'Ensayo t10', v_suc) RETURNING id INTO v_cli2;
  INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_cli, v_prev), (v_cli2, v_prev);
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo t10 A', 20000, 100, 12000, v_suc) RETURNING id INTO v_a;
  v_items := jsonb_build_array(jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'precio_unitario', 20000));

  -- Z1 · el bot
  SELECT string_agg(format('%s=%s', b.id, COALESCE(b.zona, 'NULL')), ',' ORDER BY b.id) INTO v_txt
    FROM public.bot_buscar_cliente('zz ensayo t10', v_prev, 'preventista', v_suc, 10) b;
  IF v_txt IS DISTINCT FROM format('%s=ZZ ensayo t10,%s=NULL', v_cli, v_cli2) THEN
    v_fallas := v_fallas || ('Z1 bot_buscar_cliente dio ' || COALESCE(v_txt, '(nada)'));
  END IF;
  SELECT string_agg(format('%s=%s', e->>'id', COALESCE(e->>'zona', 'NULL')), ',' ORDER BY (e->>'id')::bigint) INTO v_txt
    FROM json_array_elements(public.bot_mis_clientes(v_prev, v_suc, false, NULL, 1000)->'clientes') e
   WHERE (e->>'id')::bigint IN (v_cli, v_cli2);
  IF v_txt IS DISTINCT FROM format('%s=ZZ ensayo t10,%s=NULL', v_cli, v_cli2) THEN
    v_fallas := v_fallas || ('Z1 bot_mis_clientes dio ' || COALESCE(v_txt, '(nada)'));
  END IF;

  -- Z2 · el ritmo de compra
  SELECT string_agg(format('%s=%s', r.cliente_id, r.zona), ',' ORDER BY r.cliente_id) INTO v_txt
    FROM public.clientes_ritmo_compra(v_suc, 'admin', v_adm, NULL, NULL) r
   WHERE r.cliente_id IN (v_cli, v_cli2);
  IF v_txt IS NULL THEN
    v_z2 := ' (sin filas: los clientes del ensayo no tienen compras)';
  ELSIF v_txt IS DISTINCT FROM format('%s=ZZ ensayo t10,%s=SIN ZONA', v_cli, v_cli2) THEN
    v_fallas := v_fallas || ('Z2 clientes_ritmo_compra dio ' || v_txt);
  END IF;

  -- M1 · la métrica del digest
  v_j := public.bot_metricas_admin_dia(public._tablero_hoy() - 1, NULL)->'rendiciones_pendientes';
  IF v_j IS DISTINCT FROM '{"count": 0, "dias_mas_vieja": 0}'::jsonb THEN
    v_fallas := v_fallas || ('M1 rendiciones_pendientes dio ' || COALESCE(v_j::text, 'NULL'));
  END IF;

  -- R1 · el preventista edita su pendiente
  BEGIN
    v_ped := pg_temp.t_venta(v_prev, v_suc, v_cli, v_items);
    v_j := pg_temp.t_editar(v_prev, v_suc, v_ped, 'ensayo R1', F + 1);
    IF v_j ? 'error' OR (v_j->>'vuelto_a_pendiente')::boolean
       OR pg_temp.t_estado(v_ped, NULL) NOT LIKE format('pendiente|chofer=f|prog=%s|notas=ensayo R1|parada=f', F + 1) THEN
      v_fallas := v_fallas || format('R1 dio %s y dejó %s', v_j, pg_temp.t_estado(v_ped, NULL));
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZT10';
  EXCEPTION
    WHEN SQLSTATE 'ZZT10' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R1 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R2 · el preventista edita su asignado en ruta
  BEGIN
    v_ped := pg_temp.t_venta(v_prev, v_suc, v_cli, v_items);
    v_r := pg_temp.t_ruta(v_adm, v_suc, v_tr, F, v_ped);
    v_antes := pg_temp.t_estado(v_ped, v_r);
    IF v_antes NOT LIKE 'asignado|chofer=t|%|parada=t' THEN
      RAISE EXCEPTION 'R2 el fixture no quedó asignado y en la ruta: %', v_antes;
    END IF;
    v_j := pg_temp.t_editar(v_prev, v_suc, v_ped, 'ensayo R2', F + 1);
    IF public._preventista_en_ventana((SELECT created_at FROM pedidos WHERE id = v_ped)) THEN
      v_r2 := 'en ventana';
      IF v_j ? 'error' OR NOT (v_j->>'vuelto_a_pendiente')::boolean
         OR pg_temp.t_estado(v_ped, v_r) NOT LIKE format('pendiente|chofer=f|prog=%s|notas=ensayo R2|parada=f', F + 1) THEN
        v_fallas := v_fallas || format('R2 (en ventana) dio %s y dejó %s', v_j, pg_temp.t_estado(v_ped, v_r));
      END IF;
    ELSE
      v_r2 := 'fuera de la ventana';
      IF v_j->>'error' IS DISTINCT FROM '42501' OR v_j->>'msg' NOT LIKE '%antes de las 15:30%'
         OR pg_temp.t_estado(v_ped, v_r) IS DISTINCT FROM v_antes THEN
        v_fallas := v_fallas || format('R2 (fuera de la ventana) dio %s y dejó %s (antes %s)', v_j, pg_temp.t_estado(v_ped, v_r), v_antes);
      END IF;
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZT10';
  EXCEPTION
    WHEN SQLSTATE 'ZZT10' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R2 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- R3 · el PATCH viejo del vendedor
  BEGIN
    v_ped := pg_temp.t_venta(v_prev, v_suc, v_cli, v_items);
    v_r := pg_temp.t_ruta(v_adm, v_suc, v_tr, F, v_ped);
    v_txt := pg_temp.t_patch_vendedor(v_prev, v_suc, v_ped);
    IF v_b AND v_txt NOT LIKE '42501 %los cambia su chofer%' THEN
      v_fallas := v_fallas || ('R3 (después de B) el PATCH del vendedor tenía que dar 42501 y dio ' || v_txt);
    ELSIF NOT v_b AND v_txt IS DISTINCT FROM 'ok' THEN
      v_fallas := v_fallas || ('R3 (antes de B) la rama del vendedor tenía que dejarlo pasar y dio ' || v_txt);
    END IF;
    RAISE EXCEPTION 'volver' USING ERRCODE = 'ZZT10';
  EXCEPTION
    WHEN SQLSTATE 'ZZT10' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R3 dio %s: %s', SQLSTATE, SQLERRM);
  END;

  -- D1 · lo que se dropea
  IF v_b THEN
    SELECT string_agg(x, ', ') INTO v_txt FROM (
      SELECT 'clientes.' || attname AS x FROM pg_attribute
       WHERE attrelid = 'public.clientes'::regclass AND attnum > 0 AND NOT attisdropped
         AND attname IN ('zona', 'preventista_id')
      UNION ALL
      SELECT t FROM unnest(ARRAY['public.rendiciones', 'public.rendicion_items', 'public.rendicion_ajustes',
                                 'public.vista_rendiciones']) t WHERE to_regclass(t) IS NOT NULL
      UNION ALL
      SELECT f FROM unnest(ARRAY['public.update_rendiciones_updated_at()', 'public.crear_rendicion_por_fecha(uuid,date)',
                                 'public.obtener_estadisticas_rendiciones(date,date,uuid)']) f
       WHERE to_regprocedure(f) IS NOT NULL) s;
    IF v_txt IS NOT NULL THEN
      v_fallas := v_fallas || ('D1 quedó ' || v_txt);
    END IF;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ (%) · %', CASE WHEN v_b THEN 'después de B' ELSE 'antes de B' END,
      array_to_string(v_fallas, ' || ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (%) · Z1 Z2% M1 R1 R2 (%) R3%', CASE WHEN v_b THEN 'después de B' ELSE 'antes de B' END,
    v_z2, v_r2, CASE WHEN v_b THEN ' D1' ELSE '' END;
END
$ensayo$;
