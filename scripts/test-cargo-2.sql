-- Ensayo de la migracion cargo_2_edicion (la edicion recalcula o pregunta por
-- el cargo de envio; lo que falta de #1220, §1 del diseno).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que todo lo que escribe (un producto propio, la politica de la
-- sucursal, los pedidos) se deshace. Cada caso va ademas en su subbloque, que
-- se revierte con el SQLSTATE centinela P0099.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Es ACUMULADO: necesita cargo_1_base (la columna cargo_envio_estado y las
-- puras). Antes de esta migracion tiene que FALLAR (la firma de 4 parametros no
-- existe y la edicion conserva el cargo siempre); despues, pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/394_cargo_1_base.sql>
--   <migrations/395_cargo_2_edicion.sql>
--   <este archivo>
--   ROLLBACK;
--
-- Cada edicion se llama COMO EL FRONT: SET LOCAL ROLE authenticated con los
-- claims del usuario que edita (pg_temp.editar). Sin decision, con la firma de
-- TRES argumentos (la del front en produccion, que resuelve por el DEFAULT).
--
-- Costura de reloj: el preventista solo edita pedidos de hoy antes de las 15:30
-- (ARG). Para que el ensayo no dependa de la hora, dentro de la transaccion se
-- corre ese corte a las 23:59:59 en el cuerpo vivo (se deshace con todo).
--
-- Politica forzada: escalas 5000 / 15000 / 500 (umbral de la franja 15000).
--   P · preventista: 16000->12000 cobrado (total 12500, ZZ neto = lineas + 500,
--       IVA 0); 12000->16000 gratis (16000); 12000->13000 con el cargo vigente
--       en 700 conserva 500 (13500); manda no_cobrar al cruzar hacia abajo y se
--       ignora (cobrado 500)
--   D · admin que cruza sin decision: codigo requiere_decision_envio, cargo 500,
--       franja arriba; lineas, stock, total e historial SIN cambios. Decision
--       invalida: rechazo, sin cambios
--   B · admin no_cobrar hacia abajo -> bonificado (12000); despues el
--       preventista edita sin cruzar -> sigue bonificado (13000). Admin cobrar
--       hacia abajo -> cobrado 500. B4 (a): el bonificado sube y el admin no
--       decide -> gratis sin pregunta
--   U · (b) un cobrado que baja ya pagando (el umbral bajo de 20000 a 15000):
--       admin sin decidir -> sin cambios ni pregunta
--   K · modo cargo (umbral = minimo 15000): baja sin decidir pide agregar con
--       el texto es-AR ($12.000,00 / $500,00); cobrar -> 500; sube con el
--       vigente en 700 pide sacar 500; cobrar (c) conserva 500, no 700
--   E · encargado = admin: sin decision pide una; no_cobrar -> bonificado
--   Q · politica en bloquear: un cobrado que cruza no cambia (cargo 500, 16500)
--   N · no_aplica nunca gana: preventista y admin 'cobrar' al cruzar hacia abajo
--   F · FC: neto + IVA = total tras cada edicion (cobrar hacia abajo lleva
--       86,78 de IVA del envio; no_cobrar hacia arriba vuelve a cerrar sin envio)
--   V · VENTA-A en 0 con los pedidos editados (auditoria_integridad)
--   S · la firma de 3 args no existe; la de 4 con EXECUTE para authenticated y
--       service_role, nada para anon/PUBLIC; fuera de SEG-A
--
--   psql "$DATABASE_URL" -f scripts/test-cargo-2.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_admin  uuid;
  v_enc    uuid;
  v_prev   uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_prod   bigint;
  v_ped    bigint;
  v_ped2   bigint;
  v_f      oid;
  r        jsonb;
  p        record;
  v_stock  int;
  v_stock2 int;
  v_hist   int;
  v_hist2  int;
  v_items_antes jsonb;
  v_items_desp  jsonb;
  v_neto_items  numeric;
  v_iva_items   numeric;
  v_n      int;
  v_fn     regprocedure;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- --------------------------------------------------------- contexto ---
  -- Una sucursal activa con admin, encargado y preventista activos.
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'admin')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'encargado')
     AND EXISTS (SELECT 1 FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id AND pf.activo
                  WHERE us.sucursal_id = s.id AND pf.rol = 'preventista')
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin una sucursal activa con admin, encargado y preventista';
  END IF;
  SELECT us.usuario_id INTO v_admin FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_enc FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'encargado' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  SELECT us.usuario_id INTO v_prev FROM usuario_sucursales us JOIN perfiles pf ON pf.id = us.usuario_id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'preventista' AND pf.activo ORDER BY us.usuario_id LIMIT 1;
  -- Sin saldo a favor: un credito se imputaria a los pedidos del ensayo.
  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);

  -- Costura de reloj (ver el encabezado): el corte del preventista, a las 23:59:59.
  FOR v_f IN SELECT oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'actualizar_pedido_items' LOOP
    EXECUTE replace(pg_get_functiondef(v_f), $q$v_hora_corte CONSTANT TIME := TIME '15:30'$q$,
                                             $q$v_hora_corte CONSTANT TIME := TIME '23:59:59'$q$);
  END LOOP;

  -- Editar como el front: rol authenticated y los claims de quien edita. Sin
  -- decision, la firma de 3 argumentos.
  CREATE FUNCTION pg_temp.editar(p_ped bigint, p_cant int, p_user uuid, p_dec text, p_prod bigint)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_claims text := current_setting('request.jwt.claims', true);
    v_items  jsonb := jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 1000));
    v_r      jsonb;
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    IF p_dec IS NULL THEN
      v_r := public.actualizar_pedido_items(p_ped, v_items, p_user);
    ELSE
      EXECUTE 'SELECT public.actualizar_pedido_items($1, $2, $3, $4)' INTO v_r USING p_ped, v_items, p_user, p_dec;
    END IF;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', v_claims, true);
    -- Los GUC de stock son por transaccion: que no le lleguen al alta siguiente.
    PERFORM set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
            set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
            set_config('app.stock_pedido_item_id', '', true);
    RETURN v_r;
  END
  $f$;

  -- Alta como admin (con el usuario del pedido opcionalmente pasado a otro).
  CREATE FUNCTION pg_temp.alta(p_cli bigint, p_cant int, p_admin uuid, p_prod bigint, p_tipo text, p_duenio uuid)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_r jsonb;
    v_id bigint;
  BEGIN
    v_r := public.crear_pedido_completo(p_cli, p_cant * 1000, p_admin,
             jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 1000)),
             'ensayo cargo 2', 'efectivo', 'pendiente', NULL, p_tipo);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'alta de % unidades: %', p_cant, v_r;
    END IF;
    v_id := (v_r->>'pedido_id')::bigint;
    IF p_duenio IS NOT NULL THEN
      UPDATE pedidos SET usuario_id = p_duenio WHERE id = v_id;
    END IF;
    PERFORM set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
            set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
            set_config('app.stock_pedido_item_id', '', true);
    RETURN v_id;
  END
  $f$;

  CREATE FUNCTION pg_temp.politica(p_suc bigint, p_modo text, p_min numeric, p_gratis numeric, p_cargo numeric)
  RETURNS void LANGUAGE sql AS $f$
    INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
    VALUES (p_suc, p_modo, p_min, p_gratis, p_cargo)
    ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
      monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
      cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;
  $f$;

  -- Un producto propio: $1.000, IVA 21, sin internos, costo 600, sin lotes.
  INSERT INTO productos (nombre, precio, stock, costo_promedio, porcentaje_iva, impuestos_internos, sucursal_id)
  VALUES ('ZZ ensayo cargo 2', 1000, 1000, 600, 21, 0, v_suc)
  RETURNING id INTO v_prod;

  -- =================================================== P · preventista ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);

    -- P1 · 16000 -> 12000: cobra el envio vigente
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', v_prev);
    r := pg_temp.editar(v_ped, 12, v_prev, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    SELECT COALESCE(SUM(cantidad * neto_unitario), 0) INTO v_neto_items
      FROM pedido_items WHERE pedido_id = v_ped AND NOT COALESCE(es_bonificacion, false);
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 12500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('P1 preventista 16000->12000: %s; cargo %s, total %s, estado %s; esperado 500, 12500, cobrado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    IF p.total_neto <> round(v_neto_items, 2) + 500 OR p.total_iva <> 0 THEN
      v_fallas := v_fallas || format('P1 ZZ neto %s (lineas %s), IVA %s; esperado lineas + 500 y 0',
                                     p.total_neto, round(v_neto_items, 2), p.total_iva);
    END IF;

    -- P2 · 12000 -> 16000: gratis
    r := pg_temp.editar(v_ped, 16, v_prev, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 0 OR p.total <> 16000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'gratis' OR p.total_iva <> 0 THEN
      v_fallas := v_fallas || format('P2 preventista 12000->16000: %s; cargo %s, total %s, estado %s, IVA %s; esperado 0, 16000, gratis, 0',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado', p.total_iva);
    END IF;

    -- P3 · 12000 -> 13000 con el envio vigente en 700: sin cruce, conserva 500
    v_ped := pg_temp.alta(v_cli, 12, v_admin, v_prod, 'ZZ', v_prev);
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 700);
    r := pg_temp.editar(v_ped, 13, v_prev, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 13500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('P3 sin cruce con el vigente en 700: %s; cargo %s, total %s, estado %s; esperado 500, 13500, cobrado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);

    -- P4 · el preventista manda no_cobrar al cruzar hacia abajo: se ignora
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', v_prev);
    r := pg_temp.editar(v_ped, 12, v_prev, 'no_cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 12500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('P4 preventista con no_cobrar: %s; cargo %s, total %s, estado %s; esperado 500, 12500, cobrado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('P · error: %s', SQLERRM);
  END;

  -- ======================================= D · admin que cruza sin decidir ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);
    v_ped := pg_temp.alta(v_cli, 12, v_admin, v_prod, 'ZZ', NULL);
    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    SELECT count(*) INTO v_hist FROM pedido_historial WHERE pedido_id = v_ped;
    SELECT jsonb_agg(jsonb_build_object('p', producto_id, 'c', cantidad, 's', subtotal) ORDER BY id) INTO v_items_antes
      FROM pedido_items WHERE pedido_id = v_ped;

    r := pg_temp.editar(v_ped, 16, v_admin, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    SELECT stock INTO v_stock2 FROM productos WHERE id = v_prod;
    SELECT count(*) INTO v_hist2 FROM pedido_historial WHERE pedido_id = v_ped;
    SELECT jsonb_agg(jsonb_build_object('p', producto_id, 'c', cantidad, 's', subtotal) ORDER BY id) INTO v_items_desp
      FROM pedido_items WHERE pedido_id = v_ped;
    IF COALESCE((r->>'success')::boolean, true) OR r->>'codigo' IS DISTINCT FROM 'requiere_decision_envio'
       OR (r->>'cargo')::numeric IS DISTINCT FROM 500 OR r->>'franja' IS DISTINCT FROM 'arriba' THEN
      v_fallas := v_fallas || format('D admin cruza sin decidir: respuesta %s; esperado requiere_decision_envio, cargo 500, franja arriba', r);
    END IF;
    IF v_items_desp IS DISTINCT FROM v_items_antes OR v_stock2 <> v_stock OR v_hist2 <> v_hist
       OR p.total <> 12500 OR p.cargo_envio <> 500 THEN
      v_fallas := v_fallas || format('D sin decision cambio algo: lineas %s -> %s, stock %s -> %s, historial %s -> %s, total %s, cargo %s',
                                     v_items_antes, v_items_desp, v_stock, v_stock2, v_hist, v_hist2, p.total, p.cargo_envio);
    END IF;

    -- Decision invalida: rechazo y nada cambia.
    r := pg_temp.editar(v_ped, 16, v_admin, 'tal_vez', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF COALESCE((r->>'success')::boolean, true) OR p.total <> 12500 THEN
      v_fallas := v_fallas || format('D decision invalida: %s, total %s; esperado rechazo y 12500', r, p.total);
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('D · error: %s', SQLERRM);
  END;

  -- ================================== B · bonificado por el admin, y V ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);

    -- B1 · admin no_cobrar hacia abajo -> bonificado
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', NULL);
    r := pg_temp.editar(v_ped, 12, v_admin, 'no_cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 0 OR p.total <> 12000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'bonificado' THEN
      v_fallas := v_fallas || format('B1 admin no_cobrar: %s; cargo %s, total %s, estado %s; esperado 0, 12000, bonificado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;

    -- B2 · despues, el preventista edita sin cruzar: sigue bonificado
    UPDATE pedidos SET usuario_id = v_prev WHERE id = v_ped;
    r := pg_temp.editar(v_ped, 13, v_prev, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 0 OR p.total <> 13000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'bonificado' THEN
      v_fallas := v_fallas || format('B2 preventista sin cruce sobre un bonificado: %s; cargo %s, total %s, estado %s; esperado 0, 13000, bonificado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;

    -- B3 · admin cobrar hacia abajo -> cobrado
    v_ped2 := v_ped;  -- el bonificado de B1/B2, para B4
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', NULL);
    r := pg_temp.editar(v_ped, 12, v_admin, 'cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 12500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado'
       OR (r->>'total')::numeric IS DISTINCT FROM 12500 OR (r->>'cargo_envio')::numeric IS DISTINCT FROM 500 THEN
      v_fallas := v_fallas || format('B3 admin cobrar: %s; cargo %s, total %s, estado %s; esperado 500, 12500, cobrado (y en la respuesta)',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;

    -- B4 · (a) el bonificado de B1/B2 sube y el admin no decide nada: queda
    --      gratis sin que se le pregunte (no hay envio que sacar)
    r := pg_temp.editar(v_ped2, 16, v_admin, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped2;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.total <> 16000 OR p.cargo_envio <> 0
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'gratis' THEN
      v_fallas := v_fallas || format('B4 (a) bonificado que sube, admin sin decidir: %s; total %s, cargo %s, estado %s; esperado exito, 16000, 0, gratis',
                                     r, p.total, p.cargo_envio, to_jsonb(p)->>'cargo_envio_estado');
    END IF;

    -- V · VENTA-A en 0 con los pedidos editados de este bloque
    SELECT (c->>'violaciones')::int INTO v_n
      FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE c->>'id' = 'VENTA-A';
    IF v_n IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('V VENTA-A %s tras las ediciones; esperado 0', v_n);
    END IF;

    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('B/V · error: %s', SQLERRM);
  END;

  -- ============================================ E · encargado = admin ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', NULL);
    r := pg_temp.editar(v_ped, 12, v_enc, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF COALESCE((r->>'success')::boolean, true) OR r->>'codigo' IS DISTINCT FROM 'requiere_decision_envio'
       OR (r->>'cargo')::numeric IS DISTINCT FROM 500 OR r->>'franja' IS DISTINCT FROM 'debajo' OR p.total <> 16000 THEN
      v_fallas := v_fallas || format('E1 encargado sin decidir: %s, total %s; esperado requiere_decision_envio, cargo 500, debajo, 16000', r, p.total);
    END IF;
    r := pg_temp.editar(v_ped, 12, v_enc, 'no_cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 0 OR p.total <> 12000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'bonificado' THEN
      v_fallas := v_fallas || format('E2 encargado no_cobrar: %s; cargo %s, total %s, estado %s; esperado 0, 12000, bonificado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('E · error: %s', SQLERRM);
  END;

  -- ======================================== Q · la sucursal no cobra ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);
    v_ped := pg_temp.alta(v_cli, 12, v_admin, v_prod, 'ZZ', NULL);
    PERFORM pg_temp.politica(v_suc, 'bloquear', 0, 0, 0);
    r := pg_temp.editar(v_ped, 16, v_admin, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 16500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('Q bloquear: %s; cargo %s, total %s, estado %s; esperado 500, 16500, cobrado (nada cambia)',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('Q · error: %s', SQLERRM);
  END;

  -- ===================================== N · no_aplica nunca gana ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'bloquear', 0, 0, 0);
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', v_prev);
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);
    r := pg_temp.editar(v_ped, 12, v_prev, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 0 OR p.total <> 12000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'no_aplica' THEN
      v_fallas := v_fallas || format('N1 preventista sobre no_aplica: %s; cargo %s, total %s, estado %s; esperado 0, 12000, no_aplica',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    r := pg_temp.editar(v_ped, 16, v_admin, NULL, v_prod);
    r := pg_temp.editar(v_ped, 11, v_admin, 'cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 0 OR p.total <> 11000
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'no_aplica' THEN
      v_fallas := v_fallas || format('N2 admin cobrar sobre no_aplica: %s; cargo %s, total %s, estado %s; esperado 0, 11000, no_aplica',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('N · error: %s', SQLERRM);
  END;

  -- ===================== U · (b) baja ya pagando, tras cambiar el umbral ===
  BEGIN
    -- Con el gratis en 20000, un pedido de 16000 paga 500.
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 20000, 500);
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', NULL);
    -- El umbral baja a 15000: el pedido "estaba arriba" y al editar a 12000
    -- cruza hacia abajo, pero ya paga: nada que agregar, ni se pregunta.
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);
    r := pg_temp.editar(v_ped, 12, v_admin, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 12500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('U (b) cobrado que baja ya pagando, admin sin decidir: %s; cargo %s, total %s, estado %s; esperado exito, 500, 12500, cobrado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('U · error: %s', SQLERRM);
  END;

  -- ===================== K · modo cargo (el umbral es el minimo) y el texto ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'cargo', 15000, 0, 500);
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'ZZ', NULL);
    -- K1 · baja sin cargo, admin sin decidir: pide agregar, con montos es-AR
    r := pg_temp.editar(v_ped, 12, v_admin, NULL, v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF COALESCE((r->>'success')::boolean, true) OR r->>'codigo' IS DISTINCT FROM 'requiere_decision_envio'
       OR r->>'franja' IS DISTINCT FROM 'debajo' OR (r->>'cargo')::numeric IS DISTINCT FROM 500
       OR r->'errores'->>0 IS DISTINCT FROM 'El pedido quedó en $12.000,00. ¿Agregar envío de $500,00?'
       OR p.total <> 16000 THEN
      v_fallas := v_fallas || format('K1 modo cargo, baja sin decidir: %s, total %s; esperado debajo, 500, texto es-AR, 16000', r, p.total);
    END IF;
    -- K2 · cobrar: el vigente
    r := pg_temp.editar(v_ped, 12, v_admin, 'cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 12500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('K2 modo cargo, cobrar al bajar: %s; cargo %s, total %s, estado %s; esperado 500, 12500, cobrado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    -- K3 · sube con cargo y el vigente pasa a 700: pide sacar el que tiene (500)
    PERFORM pg_temp.politica(v_suc, 'cargo', 15000, 0, 700);
    r := pg_temp.editar(v_ped, 16, v_admin, NULL, v_prod);
    IF COALESCE((r->>'success')::boolean, true) OR r->>'franja' IS DISTINCT FROM 'arriba'
       OR (r->>'cargo')::numeric IS DISTINCT FROM 500
       OR r->'errores'->>0 IS DISTINCT FROM 'El pedido quedó en $16.000,00. ¿Sacar el envío de $500,00?' THEN
      v_fallas := v_fallas || format('K3 modo cargo, sube sin decidir: %s; esperado arriba, 500, texto es-AR', r);
    END IF;
    -- K4 · (c) cobrar al subir conserva el cargo del pedido, no el vigente
    r := pg_temp.editar(v_ped, 16, v_admin, 'cobrar', v_prod);
    SELECT * INTO p FROM pedidos WHERE id = v_ped;
    IF NOT COALESCE((r->>'success')::boolean, false) OR p.cargo_envio <> 500 OR p.total <> 16500
       OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM 'cobrado' THEN
      v_fallas := v_fallas || format('K4 modo cargo, cobrar al subir: %s; cargo %s, total %s, estado %s; esperado 500 (no 700), 16500, cobrado',
                                     r, p.cargo_envio, p.total, to_jsonb(p)->>'cargo_envio_estado');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('K · error: %s', SQLERRM);
  END;

  -- =================================================== F · factura C ===
  BEGIN
    PERFORM pg_temp.politica(v_suc, 'escalas', 5000, 15000, 500);
    v_ped := pg_temp.alta(v_cli, 16, v_admin, v_prod, 'FC', NULL);
    FOR v_n IN 1..2 LOOP
      IF v_n = 1 THEN
        r := pg_temp.editar(v_ped, 12, v_admin, 'cobrar', v_prod);
      ELSE
        r := pg_temp.editar(v_ped, 16, v_admin, 'no_cobrar', v_prod);
      END IF;
      SELECT * INTO p FROM pedidos WHERE id = v_ped;
      SELECT COALESCE(SUM(cantidad * iva_unitario), 0) INTO v_iva_items
        FROM pedido_items WHERE pedido_id = v_ped AND NOT COALESCE(es_bonificacion, false);
      IF NOT COALESCE((r->>'success')::boolean, false)
         OR p.total <> (CASE v_n WHEN 1 THEN 12500 ELSE 16000 END)
         OR abs(p.total_neto + p.total_iva - p.total) > 0.01
         OR abs(p.total_iva - round(v_iva_items, 2) - (CASE v_n WHEN 1 THEN 86.78 ELSE 0 END)) > 0.005
         OR (to_jsonb(p)->>'cargo_envio_estado') IS DISTINCT FROM (CASE v_n WHEN 1 THEN 'cobrado' ELSE 'gratis' END) THEN
        v_fallas := v_fallas || format('F paso %s: %s; total %s, neto %s + IVA %s (IVA de items %s), estado %s; esperado que cierre (%s)',
                                       v_n, r, p.total, p.total_neto, p.total_iva, round(v_iva_items, 2),
                                       to_jsonb(p)->>'cargo_envio_estado',
                                       CASE v_n WHEN 1 THEN '12500, IVA con 86,78, cobrado' ELSE '16000, sin envio, gratis' END);
      END IF;
    END LOOP;
    RAISE EXCEPTION USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || format('F · error: %s', SQLERRM);
  END;

  -- ==================================================== S · la firma ===
  BEGIN
    IF to_regprocedure('public.actualizar_pedido_items(bigint,jsonb,uuid)') IS NOT NULL THEN
      v_fallas := v_fallas || 'S la firma de 3 argumentos sigue existiendo'::text;
    END IF;
    v_fn := to_regprocedure('public.actualizar_pedido_items(bigint,jsonb,uuid,text)');
    IF v_fn IS NULL THEN
      v_fallas := v_fallas || 'S no existe actualizar_pedido_items(bigint, jsonb, uuid, text)'::text;
    ELSIF has_function_privilege('anon', v_fn, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc pp, aclexplode(pp.proacl) a WHERE pp.oid = v_fn AND a.grantee = 0)
       OR NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE') THEN
      v_fallas := v_fallas || 'S permisos de la firma nueva distintos de la viva'::text;
    END IF;
    IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() WHERE firma LIKE 'actualizar_pedido_items(%') THEN
      v_fallas := v_fallas || 'S actualizar_pedido_items en rojo en SEG-A'::text;
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('S · error: %s', SQLERRM);
  END;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · edicion del cargo: preventista automatico (cobra/gratis/conserva/ignora la decision), admin y encargado sin decision no tocan nada, no_cobrar bonifica y se conserva, cobrar, sin nada que sacar o agregar no pregunta, modo cargo y texto es-AR, bloquear no recalcula, no_aplica no gana, FC cierra, VENTA-A 0, firma de 3 args fuera';
END
$ensayo$;
