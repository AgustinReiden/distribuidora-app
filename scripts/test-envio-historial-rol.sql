-- Ensayo de la migracion envio_historial_y_rol (#1231: el cargo de envio en
-- pedido_historial; #1232: el envio lo decide el rol de la sucursal).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (un producto propio, la politica de la
-- sucursal, el rol de la sucursal de dos usuarios, los pedidos) se deshace.
-- Cada caso va ademas en su subbloque, que se revierte con el SQLSTATE
-- centinela P0099.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Antes de la migracion tiene que FALLAR (no hay filas de cargo en el historial
-- y el envio se decide con perfiles.rol); despues, pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/399_envio_historial_y_rol.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Cada edicion se llama COMO EL FRONT: SET LOCAL ROLE authenticated con los
-- claims del usuario que edita (pg_temp.editar). Costura de reloj: el
-- preventista solo edita pedidos de hoy antes de las 15:30 (ARG); dentro de la
-- transaccion ese corte se corre a las 23:59:59 (se deshace con todo).
--
-- Politica forzada: escalas 5000 / 15000 / 500 (umbral de la franja 15000).
--   H · historial de actualizar_pedido_items:
--       H1 preventista 16000->12000: 'cargo_envio' 0.00->500.00 y
--          'cargo_envio_estado' gratis->cobrado, con el usuario que edita
--       H2 admin no_cobrar al cruzar hacia abajo: solo 'cargo_envio_estado'
--          gratis->bonificado (el cargo sigue en 0)
--       H3 edicion sin cruce: ninguna fila de cargo
--       H4 admin que cruza sin decidir: ninguna fila (no cambia nada)
--       H5 admin no_cobrar hacia arriba sobre un cobrado: 500.00->0.00 y
--          cobrado->gratis
--   C · cambiar_cliente_pedido de un cobrado: el nuevo conserva 500 cobrado y
--       no anota filas de cargo (solo cliente_id)
--   R · el rol de la sucursal:
--       R1 preventista en perfiles y encargado en la sucursal: sin decision
--          pide una (requiere_decision_envio); con no_cobrar -> bonificado
--       R2 admin en perfiles y preventista en la sucursal: cruza hacia abajo
--          sin decision -> automatico (cobrado 500), sin pregunta
--       R3 'mismo' en la sucursal: el admin pregunta como siempre
--   S · permisos de las dos funciones iguales a los de la viva; fuera de SEG-A;
--       _rol_en_sucursal sigue siendo de server
--
--   psql "$DATABASE_URL" -f scripts/test-envio-historial-rol.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_admin  uuid;
  v_prev   uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_cli2   bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_f      oid;
  r        jsonb;
  p        record;
  v_h      text;
  v_n      int;
  v_fn     regprocedure;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- --------------------------------------------------------- contexto ---
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'admin')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'preventista')
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin una sucursal activa con admin y preventista';
  END IF;
  SELECT us.usuario_id INTO v_admin FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_prev FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'preventista' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  -- Los dos con el rol de la sucursal en 'mismo' (R lo cambia).
  UPDATE usuario_sucursales SET rol = 'mismo' WHERE sucursal_id = v_suc AND usuario_id IN (v_admin, v_prev);
  -- Sin saldo a favor: un credito se imputaria a los pedidos del ensayo.
  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  SELECT c.id INTO v_cli2 FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND c.id <> v_cli
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cli2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin dos clientes activos en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);

  -- Costura de reloj: el corte del preventista, a las 23:59:59.
  FOR v_f IN SELECT oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'actualizar_pedido_items' LOOP
    EXECUTE replace(pg_get_functiondef(v_f), $q$v_hora_corte CONSTANT TIME := TIME '15:30'$q$,
                                             $q$v_hora_corte CONSTANT TIME := TIME '23:59:59'$q$);
  END LOOP;

  CREATE FUNCTION pg_temp.limpiar_gucs() RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
           set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
           set_config('app.stock_pedido_item_id', '', true), set_config('app.omitir_minimo_pedido', '', true),
           set_config('app.cargo_envio_forzado', '', true), set_config('app.cargo_envio_estado_forzado', '', true),
           set_config('app.cancelacion_conserva_pagos', '', true);
  $f$;

  CREATE FUNCTION pg_temp.editar(p_ped bigint, p_cant int, p_user uuid, p_dec text, p_prod bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_claims text := current_setting('request.jwt.claims', true);
    v_items  jsonb := jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 1000));
    v_r      jsonb;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    v_r := public.actualizar_pedido_items(p_ped, v_items, p_user, p_dec);
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', v_claims, true);
    PERFORM pg_temp.limpiar_gucs();
    RETURN v_r;
  END
  $f$;

  CREATE FUNCTION pg_temp.alta(p_cli bigint, p_cant int, p_admin uuid, p_prod bigint, p_duenio uuid)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_r jsonb;
    v_id bigint;
  BEGIN
    v_r := public.crear_pedido_completo(p_cli, p_cant * 1000, p_admin,
             jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 1000)),
             'ensayo envio historial', 'efectivo', 'pendiente', NULL, 'ZZ');
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'alta de % unidades: %', p_cant, v_r;
    END IF;
    v_id := (v_r->>'pedido_id')::bigint;
    IF p_duenio IS NOT NULL THEN
      UPDATE pedidos SET usuario_id = p_duenio WHERE id = v_id;
    END IF;
    PERFORM pg_temp.limpiar_gucs();
    RETURN v_id;
  END
  $f$;

  -- 'anterior->nuevo@usuario' de la unica fila de ese campo, '' si no hay,
  -- 'VARIAS' si hay mas de una.
  CREATE FUNCTION pg_temp.hist(p_ped bigint, p_campo text) RETURNS text LANGUAGE sql AS $f$
    SELECT CASE count(*) WHEN 0 THEN '' WHEN 1 THEN min(valor_anterior || '->' || valor_nuevo || '@' || usuario_id::text)
                         ELSE 'VARIAS' END
      FROM pedido_historial WHERE pedido_id = p_ped AND campo_modificado = p_campo;
  $f$;

  INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
  VALUES (v_suc, 'escalas', 5000, 15000, 500)
  ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
    monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
    cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;

  INSERT INTO productos (nombre, precio, stock, costo_promedio, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo envio historial', 1000, 1000, 600, 21, 0, v_suc)
  RETURNING id INTO v_prod;

  -- ============================================= H · el historial ===
  BEGIN
    -- H1 · preventista 16000 -> 12000: cobra y queda anotado
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, v_prev);
    r := pg_temp.editar(v_ped, 12, v_prev, NULL, v_prod);
    IF NOT COALESCE((r->>'success')::boolean, false)
       OR pg_temp.hist(v_ped, 'cargo_envio') <> '0.00->500.00@' || v_prev
       OR pg_temp.hist(v_ped, 'cargo_envio_estado') <> 'gratis->cobrado@' || v_prev THEN
      v_fallas := v_fallas || format('H1 preventista 16000->12000: %s; cargo [%s], estado [%s]; esperado 0.00->500.00 y gratis->cobrado de %s',
                                     r, pg_temp.hist(v_ped, 'cargo_envio'), pg_temp.hist(v_ped, 'cargo_envio_estado'), v_prev);
    END IF;

    -- H2 · admin no_cobrar hacia abajo: solo el estado
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, NULL);
    r := pg_temp.editar(v_ped, 12, v_admin, 'no_cobrar', v_prod);
    IF NOT COALESCE((r->>'success')::boolean, false)
       OR pg_temp.hist(v_ped, 'cargo_envio') <> ''
       OR pg_temp.hist(v_ped, 'cargo_envio_estado') <> 'gratis->bonificado@' || v_admin THEN
      v_fallas := v_fallas || format('H2 admin no_cobrar: %s; cargo [%s], estado [%s]; esperado sin cargo y gratis->bonificado de %s',
                                     r, pg_temp.hist(v_ped, 'cargo_envio'), pg_temp.hist(v_ped, 'cargo_envio_estado'), v_admin);
    END IF;

    -- H3 · sin cruce (bonificado 12000 -> 13000): nada de cargo
    r := pg_temp.editar(v_ped, 13, v_admin, NULL, v_prod);
    IF NOT COALESCE((r->>'success')::boolean, false)
       OR pg_temp.hist(v_ped, 'cargo_envio') <> ''
       OR pg_temp.hist(v_ped, 'cargo_envio_estado') <> 'gratis->bonificado@' || v_admin THEN
      v_fallas := v_fallas || format('H3 sin cruce: %s; cargo [%s], estado [%s]; esperado sin filas nuevas',
                                     r, pg_temp.hist(v_ped, 'cargo_envio'), pg_temp.hist(v_ped, 'cargo_envio_estado'));
    END IF;

    -- H4 · admin que cruza sin decidir: no cambia nada, no anota nada
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, NULL);
    r := pg_temp.editar(v_ped, 12, v_admin, NULL, v_prod);
    IF r->>'codigo' IS DISTINCT FROM 'requiere_decision_envio'
       OR pg_temp.hist(v_ped, 'cargo_envio') <> '' OR pg_temp.hist(v_ped, 'cargo_envio_estado') <> '' THEN
      v_fallas := v_fallas || format('H4 admin sin decision: %s; cargo [%s], estado [%s]; esperado requiere_decision_envio y sin filas',
                                     r, pg_temp.hist(v_ped, 'cargo_envio'), pg_temp.hist(v_ped, 'cargo_envio_estado'));
    END IF;

    -- H5 · un cobrado sube y el admin saca el envio
    v_ped := pg_temp.alta(v_cli, 12, v_admin, v_prod, NULL);
    r := pg_temp.editar(v_ped, 16, v_admin, 'no_cobrar', v_prod);
    IF NOT COALESCE((r->>'success')::boolean, false)
       OR pg_temp.hist(v_ped, 'cargo_envio') <> '500.00->0.00@' || v_admin
       OR pg_temp.hist(v_ped, 'cargo_envio_estado') <> 'cobrado->gratis@' || v_admin THEN
      v_fallas := v_fallas || format('H5 admin saca el envio: %s; cargo [%s], estado [%s]; esperado 500.00->0.00 y cobrado->gratis',
                                     r, pg_temp.hist(v_ped, 'cargo_envio'), pg_temp.hist(v_ped, 'cargo_envio_estado'));
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('H · error: %s', SQLERRM);
  END;

  -- ===================================== C · cambiar_cliente_pedido ===
  BEGIN
    v_ped := pg_temp.alta(v_cli, 12, v_admin, v_prod, NULL);
    SET LOCAL ROLE authenticated;
    r := public.cambiar_cliente_pedido(v_ped, v_cli2, v_admin,
           jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 12, 'precio_unitario', 1000)),
           12000);
    RESET ROLE;
    PERFORM pg_temp.limpiar_gucs();
    SELECT * INTO p FROM pedidos WHERE id = (r->>'nuevo_pedido_id')::bigint;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado'
       OR pg_temp.hist(p.id, 'cargo_envio') <> '' OR pg_temp.hist(p.id, 'cargo_envio_estado') <> ''
       OR pg_temp.hist(p.id, 'cliente_id') = '' THEN
      v_fallas := v_fallas || format('C reatribuir un cobrado: %s; cargo %s, estado %s, filas cargo [%s] estado [%s] cliente [%s]; esperado 500 cobrado, sin filas de cargo y con cliente_id',
                                     r, p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado',
                                     pg_temp.hist(p.id, 'cargo_envio'), pg_temp.hist(p.id, 'cargo_envio_estado'),
                                     pg_temp.hist(p.id, 'cliente_id'));
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('C · error: %s', SQLERRM);
  END;

  -- ============================================ R · rol de la sucursal ===
  BEGIN
    -- R1 · preventista en perfiles, encargado en la sucursal: decide
    UPDATE usuario_sucursales SET rol = 'encargado' WHERE sucursal_id = v_suc AND usuario_id = v_prev;
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, v_prev);
    r := pg_temp.editar(v_ped, 12, v_prev, NULL, v_prod);
    IF r->>'codigo' IS DISTINCT FROM 'requiere_decision_envio' THEN
      v_fallas := v_fallas || format('R1 encargado en la sucursal sin decision: %s; esperado requiere_decision_envio', r);
    END IF;
    r := pg_temp.editar(v_ped, 12, v_prev, 'no_cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 0
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'bonificado' THEN
      v_fallas := v_fallas || format('R1 encargado en la sucursal no_cobrar: %s; cargo %s, estado %s; esperado 0 bonificado',
                                     r, p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado');
    END IF;

    -- R2 · admin en perfiles, preventista en la sucursal: automatico
    UPDATE usuario_sucursales SET rol = 'preventista' WHERE sucursal_id = v_suc AND usuario_id = v_admin;
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, NULL);
    r := pg_temp.editar(v_ped, 12, v_admin, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('R2 preventista en la sucursal: %s; cargo %s, estado %s; esperado 500 cobrado sin pregunta',
                                     r, p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado');
    END IF;

    -- R3 · 'mismo': el admin pregunta como siempre
    UPDATE usuario_sucursales SET rol = 'mismo' WHERE sucursal_id = v_suc AND usuario_id = v_admin;
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, NULL);
    r := pg_temp.editar(v_ped, 12, v_admin, NULL, v_prod);
    IF r->>'codigo' IS DISTINCT FROM 'requiere_decision_envio' THEN
      v_fallas := v_fallas || format('R3 admin con mismo: %s; esperado requiere_decision_envio', r);
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('R · error: %s', SQLERRM);
  END;

  -- ===================================================== S · permisos ===
  BEGIN
    FOREACH v_fn IN ARRAY ARRAY[
      'public.actualizar_pedido_items(bigint,jsonb,uuid,text)'::regprocedure,
      'public.cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text)'::regprocedure]
    LOOP
      IF has_function_privilege('anon', v_fn, 'EXECUTE')
         OR EXISTS (SELECT 1 FROM pg_proc pp, aclexplode(pp.proacl) a WHERE pp.oid = v_fn AND a.grantee = 0)
         OR NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
         OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
        v_fallas := v_fallas || format('S permisos de %s distintos de la viva', v_fn);
      END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol()
                WHERE firma LIKE 'actualizar_pedido_items(%' OR firma LIKE 'cambiar_cliente_pedido(%') THEN
      v_fallas := v_fallas || 'S en rojo en SEG-A'::text;
    END IF;
    IF has_function_privilege('authenticated', 'public._rol_en_sucursal(uuid,bigint)', 'EXECUTE') THEN
      v_fallas := v_fallas || 'S _rol_en_sucursal alcanzable por authenticated'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('S · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · el cargo y su estado quedan en el historial con el usuario (cobra, bonifica, saca; sin cruce o sin decision no anota), la reatribucion conserva sin anotar, el envio lo decide el rol de la sucursal (encargado decide, preventista automatico, mismo = perfiles), permisos iguales';
END
$ensayo$;
