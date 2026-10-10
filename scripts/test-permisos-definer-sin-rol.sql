-- Ensayo de permisos de #1009 (funciones DEFINER sin rol) y #982 (reportes que
-- no cruzan la sucursal pedida con las asignadas).
--
-- Corre contra prod SIN dejar rastro: es un único DO que termina SIEMPRE en
-- RAISE EXCEPTION, así que todo lo que haya hecho —incluido lo que una función
-- con el bug llegue a escribir— se deshace. Simula una sesión real como lo hace
-- PostgREST: `SET LOCAL ROLE authenticated`, el `sub` del perfil en
-- request.jwt.claims y la sucursal en el header x-sucursal-id.
--
-- Lee el veredicto del mensaje del error final:
--   'ENSAYO OK …'      → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …'   → lista de lo que no se cumplió.
-- (Termina en error también cuando pasa, a propósito: el MCP de Supabase no
-- muestra NOTICEs y así nada queda escrito.)
--
-- Antes de la migración tiene que FALLAR en cada caso del bug; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-definer-sin-rol.sql

DO $ensayo$
DECLARE
  v_fallas    text[] := '{}';
  v_saltados  text[] := '{}';

  v_suc       bigint;   -- sucursal de los casos
  v_suc_ajena bigint;   -- sucursal que v_admin NO tiene asignada
  v_admin     uuid;     -- admin con v_suc asignada y alguna sin asignar
  v_pedido    bigint;   -- pedido de v_suc con deuda previa > 0
  v_dueno     uuid;     -- quien tomó v_pedido
  v_prev      uuid;     -- preventista de v_suc ajeno a v_pedido
  v_transp    uuid;     -- transportista de v_suc ajeno a v_pedido
  v_deposito  uuid;     -- perfil fabricado como depósito (dentro de la transacción)
  v_ped_bonif bigint;   -- pedido de v_suc con regalos, ajeno a v_prev
  v_item      bigint;   -- renglón no bonificado de v_ped_bonif que mueve un regalo
  v_cant      int;
  v_prov_propio bigint; -- proveedor de v_suc (si se puede, sin productos ni compras)
  v_prov_libre  boolean;-- v_prov_propio no tiene productos ni compras
  v_prov_ajeno  bigint; -- proveedor de otra sucursal

  v_num       numeric;
  v_ref       numeric;
  v_json      jsonb;
  v_n         int;
  v_n_ref     int;
  v_estado    text;
  v_fn        text;
  r           record;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  -- Se leen como postgres, antes de bajar de rol.
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'admin' AND COALESCE(p.activo, true)
     AND EXISTS (SELECT 1 FROM sucursales s
                  WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales u2
                                     WHERE u2.usuario_id = us.usuario_id AND u2.sucursal_id = s.id))
     AND EXISTS (SELECT 1 FROM pedidos pe WHERE pe.sucursal_id = us.sucursal_id
                    AND pe.total - COALESCE(pe.monto_pagado, 0) > 1)
   ORDER BY us.es_default DESC, us.usuario_id
   LIMIT 1;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'ensayo · no hay admin con una sucursal sin asignar'; END IF;

  SELECT s.id INTO v_suc_ajena FROM sucursales s
   WHERE NOT EXISTS (SELECT 1 FROM usuario_sucursales u
                      WHERE u.usuario_id = v_admin AND u.sucursal_id = s.id)
   ORDER BY s.id LIMIT 1;

  -- Un pedido con deuda anterior: el más nuevo de un cliente con boletas impagas
  -- previas, tomado por un preventista activo.
  SELECT pe.id, pe.usuario_id INTO v_pedido, v_dueno
    FROM pedidos pe
    JOIN perfiles pf ON pf.id = pe.usuario_id AND pf.rol = 'preventista' AND COALESCE(pf.activo, true)
   WHERE pe.sucursal_id = v_suc
     AND pe.estado NOT IN ('cancelado', 'anulado')
     AND EXISTS (SELECT 1 FROM pedidos p2
                  WHERE p2.cliente_id = pe.cliente_id AND p2.sucursal_id = pe.sucursal_id
                    AND p2.estado NOT IN ('cancelado', 'anulado')
                    AND (p2.created_at, p2.id) < (pe.created_at, pe.id)
                    AND p2.total - COALESCE(p2.monto_pagado, 0) > 1)
   ORDER BY pe.created_at DESC
   LIMIT 1;
  IF v_pedido IS NULL THEN RAISE EXCEPTION 'ensayo · no hay pedido con deuda previa en la sucursal %', v_suc; END IF;

  SELECT p.id INTO v_prev FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
   WHERE p.rol = 'preventista' AND COALESCE(p.activo, true) AND p.id <> v_dueno
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id)
   ORDER BY p.id LIMIT 1;

  SELECT p.id INTO v_transp FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
   WHERE p.rol = 'transportista' AND COALESCE(p.activo, true)
     AND p.id IS DISTINCT FROM (SELECT transportista_id FROM pedidos WHERE id = v_pedido)
   ORDER BY p.id LIMIT 1;

  IF v_prev IS NULL OR v_transp IS NULL THEN
    RAISE EXCEPTION 'ensayo · faltan perfiles ajenos (preventista %, transportista %)', v_prev, v_transp;
  END IF;

  -- Pedido con regalos, ajeno a v_prev, y un renglón que al bajarlo entero
  -- mueve un regalo (para que la simulación individual devuelva filas).
  SELECT pe.id, pi.id, pi.cantidad INTO v_ped_bonif, v_item, v_cant
    FROM pedidos pe
    JOIN pedido_items pi ON pi.pedido_id = pe.id AND NOT COALESCE(pi.es_bonificacion, false)
    JOIN promocion_productos pp ON pp.producto_id = pi.producto_id
    JOIN pedido_items b ON b.pedido_id = pe.id AND COALESCE(b.es_bonificacion, false)
                       AND b.promocion_id = pp.promocion_id
   WHERE pe.sucursal_id = v_suc
     AND pe.usuario_id IS DISTINCT FROM v_prev
     AND pe.transportista_id IS DISTINCT FROM v_prev
     AND pe.estado NOT IN ('cancelado', 'anulado')
   ORDER BY pe.created_at DESC
   LIMIT 1;

  -- Preferido: uno sin productos ni compras, para que el borrado legítimo del
  -- admin (4.3) pueda completarse. Si no hay, cualquiera de la sucursal sirve
  -- para el caso del bug (4.1).
  SELECT pr.id,
         NOT EXISTS (SELECT 1 FROM productos x WHERE x.proveedor_id = pr.id)
     AND NOT EXISTS (SELECT 1 FROM compras c WHERE c.proveedor_id = pr.id)
    INTO v_prov_propio, v_prov_libre
    FROM proveedores pr
   WHERE pr.sucursal_id = v_suc
   ORDER BY 2 DESC, pr.id LIMIT 1;
  SELECT pr.id INTO v_prov_ajeno FROM proveedores pr
   WHERE pr.sucursal_id <> v_suc ORDER BY pr.id LIMIT 1;

  -- Depósito: no hay ninguno en prod. Se fabrica con un preventista que no es
  -- v_prev ni v_dueno, sólo dentro de esta transacción.
  BEGIN
    SELECT p.id INTO v_deposito FROM perfiles p
      JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
     WHERE p.rol = 'preventista' AND COALESCE(p.activo, true)
       AND p.id NOT IN (v_prev, v_dueno)
       AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id)
     ORDER BY p.id LIMIT 1;
    IF v_deposito IS NOT NULL THEN
      UPDATE perfiles SET rol = 'deposito' WHERE id = v_deposito;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_deposito := NULL;
    v_saltados := v_saltados || ('depósito: no se pudo fabricar (' || SQLERRM || ')');
  END;

  -- ------------------------------------------------------- 1 · #982 -------
  -- Un admin pide un reporte de una sucursal que no tiene asignada → 42501.
  -- Y con NULL (lo que manda el front) y con la suya, sigue andando.
  FOREACH v_fn IN ARRAY ARRAY['reporte_cuentas_por_cobrar', 'reporte_ventas_por_preventista', 'reporte_rentabilidad'] LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      IF v_fn = 'reporte_cuentas_por_cobrar' THEN
        EXECUTE format('SELECT public.%I(%s)', v_fn, v_suc_ajena) INTO v_json;
      ELSE
        EXECUTE format('SELECT public.%I(NULL, NULL, %s)', v_fn, v_suc_ajena) INTO v_json;
      END IF;
      v_fallas := v_fallas || format('#982 · %s(sucursal ajena %s) respondió en vez de negar', v_fn, v_suc_ajena);
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
      WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'Acceso denegado%' THEN
          v_fallas := v_fallas || format('#982 · %s(ajena) falló con otra cosa: %s', v_fn, SQLERRM);
        END IF;
    END;

    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      IF v_fn = 'reporte_cuentas_por_cobrar' THEN
        EXECUTE format('SELECT public.%I(NULL)', v_fn) INTO v_json;
        EXECUTE format('SELECT public.%I(%s)', v_fn, v_suc) INTO v_json;
      ELSE
        EXECUTE format('SELECT public.%I(NULL, NULL, NULL)', v_fn) INTO v_json;
        EXECUTE format('SELECT public.%I(NULL, NULL, %s)', v_fn, v_suc) INTO v_json;
      END IF;
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('#982 · %s con NULL o con la sucursal propia dejó de andar: %s', v_fn, SQLERRM);
    END;
  END LOOP;

  -- ---------------------------------------------- 2 · deuda_previa -------
  -- Como PostgREST con rpc/deuda_previa y {"p":{"id":N}}: una fila inventada
  -- con sólo el id.
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- 2.1 · admin: el valor de referencia, que tiene que ser > 0.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT public.deuda_previa(jsonb_populate_record(NULL::public.pedidos, jsonb_build_object('id', v_pedido))),
         jsonb_array_length(public.deuda_previa_detalle(jsonb_populate_record(NULL::public.pedidos, jsonb_build_object('id', v_pedido))))
    INTO v_ref, v_n_ref;
  EXECUTE 'RESET ROLE';
  IF COALESCE(v_ref, 0) <= 0 OR COALESCE(v_n_ref, 0) = 0 THEN
    v_fallas := v_fallas || format('deuda_previa · el admin no ve la deuda del pedido %s (%s, %s boletas)', v_pedido, v_ref, v_n_ref);
  END IF;

  -- 2.2 · quien tomó el pedido: lo mismo que el admin.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_dueno, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT public.deuda_previa(jsonb_populate_record(NULL::public.pedidos, jsonb_build_object('id', v_pedido))) INTO v_num;
  EXECUTE 'RESET ROLE';
  IF v_num IS DISTINCT FROM v_ref THEN
    v_fallas := v_fallas || format('deuda_previa · el preventista que tomó el pedido ve %s y el admin %s', v_num, v_ref);
  END IF;

  -- 2.3 · ajenos: 0 y [].
  FOR r IN SELECT * FROM (VALUES ('preventista ajeno', v_prev), ('transportista ajeno', v_transp), ('depósito', v_deposito)) t(quien, uid)
           WHERE t.uid IS NOT NULL LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT public.deuda_previa(jsonb_populate_record(NULL::public.pedidos, jsonb_build_object('id', v_pedido))),
           jsonb_array_length(public.deuda_previa_detalle(jsonb_populate_record(NULL::public.pedidos, jsonb_build_object('id', v_pedido))))
      INTO v_num, v_n;
    EXECUTE 'RESET ROLE';
    IF COALESCE(v_num, 0) <> 0 OR COALESCE(v_n, 0) <> 0 THEN
      v_fallas := v_fallas || format('deuda_previa · %s lee la deuda del pedido %s: %s y %s boletas', r.quien, v_pedido, v_num, v_n);
    END IF;
  END LOOP;

  -- --------------------------------------------- 3 · simular_* -----------
  IF v_ped_bonif IS NULL THEN
    v_saltados := v_saltados || 'simular_*: no hay pedido con regalos en la sucursal'::text;
  ELSE
    -- 3.1 · admin: referencia > 0.
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n_ref FROM public.simular_salvedades_promo_impacto(v_ped_bonif, '[]'::jsonb);
    SELECT count(*) INTO v_n FROM public.simular_salvedad_promo_impacto(v_ped_bonif, v_item, v_cant);
    EXECUTE 'RESET ROLE';
    IF v_n_ref = 0 THEN
      v_fallas := v_fallas || format('simular_salvedades · el admin no ve los regalos del pedido %s', v_ped_bonif);
    END IF;
    IF v_n = 0 THEN
      v_saltados := v_saltados || format('simular_salvedad (individual): el renglón %s no mueve regalos; sólo se prueba la masiva', v_item);
    END IF;

    -- 3.2 · ajenos: nada.
    FOR r IN SELECT * FROM (VALUES ('preventista ajeno', v_prev), ('depósito', v_deposito)) t(quien, uid)
             WHERE t.uid IS NOT NULL LOOP
      PERFORM set_config('request.jwt.claims', json_build_object('sub', r.uid, 'role', 'authenticated')::text, true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      SELECT count(*) INTO v_n_ref FROM public.simular_salvedades_promo_impacto(v_ped_bonif, '[]'::jsonb);
      SELECT count(*) INTO v_num FROM public.simular_salvedad_promo_impacto(v_ped_bonif, v_item, v_cant);
      EXECUTE 'RESET ROLE';
      IF v_n_ref > 0 THEN
        v_fallas := v_fallas || format('simular_salvedades · %s ve %s regalos del pedido %s', r.quien, v_n_ref, v_ped_bonif);
      END IF;
      IF v_num > 0 THEN
        v_fallas := v_fallas || format('simular_salvedad · %s ve %s filas del pedido %s', r.quien, v_num, v_ped_bonif);
      END IF;
    END LOOP;
  END IF;

  -- ------------------------------------------ 4 · eliminar_proveedor -----
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  -- 4.1 · un preventista → 42501, y el proveedor sigue.
  IF v_prov_propio IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      SELECT public.eliminar_proveedor(v_prov_propio) INTO v_json;
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || format('eliminar_proveedor · un preventista no fue rechazado (%s)', v_json);
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id = v_prov_propio) THEN
      v_fallas := v_fallas || format('eliminar_proveedor · un preventista borró el proveedor %s', v_prov_propio);
    END IF;
  ELSE
    v_saltados := v_saltados || 'eliminar_proveedor 4.1/4.3: no hay proveedor en la sucursal'::text;
  END IF;

  -- 4.2 · un admin, con un proveedor de OTRA sucursal → no encontrado, y sigue.
  IF v_prov_ajeno IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      SELECT public.eliminar_proveedor(v_prov_ajeno) INTO v_json;
      EXECUTE 'RESET ROLE';
      IF COALESCE((v_json->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('eliminar_proveedor · un admin de la sucursal %s borró el proveedor %s de otra', v_suc, v_prov_ajeno);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('eliminar_proveedor · admin con proveedor ajeno: error inesperado %s', SQLERRM);
    END;
    IF NOT EXISTS (SELECT 1 FROM proveedores WHERE id = v_prov_ajeno) THEN
      v_fallas := v_fallas || format('eliminar_proveedor · el proveedor %s de otra sucursal desapareció', v_prov_ajeno);
    END IF;
  ELSE
    v_saltados := v_saltados || 'eliminar_proveedor 4.2: no hay proveedor de otra sucursal'::text;
  END IF;

  -- 4.3 · el admin con uno suyo: no lo rechaza el rol (el camino legítimo
  --       sigue andando). Si el proveedor no tiene referencias, además lo borra;
  --       si las tiene, la FK puede negarse y eso no es asunto de este ensayo.
  IF v_prov_propio IS NOT NULL AND EXISTS (SELECT 1 FROM proveedores WHERE id = v_prov_propio) THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      SELECT public.eliminar_proveedor(v_prov_propio) INTO v_json;
      EXECUTE 'RESET ROLE';
      IF v_prov_libre AND NOT COALESCE((v_json->>'success')::boolean, false) THEN
        v_fallas := v_fallas || format('eliminar_proveedor · el admin no pudo borrar su proveedor %s: %s', v_prov_propio, v_json);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('eliminar_proveedor · el admin falló con %s', SQLERRM);
    END;
  END IF;

  -- ------------------------------------- 5 · las que nadie del front llama --
  -- Como authenticated (aunque sea admin) → permiso denegado. Con el bug, las
  -- dos primeras ESCRIBEN (un recorrido, una rendición): se deshacen al final.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
  FOREACH v_fn IN ARRAY ARRAY[
    format('SELECT public.crear_recorrido(%L::uuid, %L::jsonb, NULL, NULL)::text', v_prev, jsonb_build_array(jsonb_build_object('pedido_id', v_pedido, 'orden_entrega', 1))),
    format('SELECT public.crear_rendicion_por_fecha(%L::uuid, %L::date)::text', v_transp, current_date),
    'SELECT public.obtener_estadisticas_rendiciones(NULL, NULL, NULL)::text',
    -- obtener_estadisticas_pedidos ya no está: la borró #1044.
    'SELECT public.pedido_bundle_para_promo(1, 1, 5)::text',
    'SELECT public.auditoria_permisos_execute()::text',
    'SELECT public.auditoria_funciones_costo_sin_valuacion()::text',
    'SELECT public.auditoria_funciones_stock_sin_origen()::text'
  ] LOOP
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE v_fn INTO v_estado;
      EXECUTE 'RESET ROLE';
      v_fallas := v_fallas || format('sin uso en el front · authenticated pudo ejecutar: %s', left(v_fn, 70));
    EXCEPTION WHEN insufficient_privilege THEN NULL;
      WHEN OTHERS THEN
        v_fallas := v_fallas || format('sin uso en el front · %s falló con otra cosa: %s', left(v_fn, 70), SQLERRM);
    END;
  END LOOP;

  -- ------------------------------------------------------ 6 · SEG-A ------
  IF to_regprocedure('public.auditoria_definer_sin_rol()') IS NULL THEN
    v_fallas := v_fallas || 'SEG-A · no existe auditoria_definer_sin_rol()'::text;
  ELSE
    EXECUTE 'SELECT count(*) FROM public.auditoria_definer_sin_rol()' INTO v_n;
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format('SEG-A · %s funciones DEFINER expuestas sin rol', v_n);
    END IF;
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %\nSaltados:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), COALESCE(array_to_string(v_saltados, E'\n- '), '(ninguno)');
  END IF;
  RAISE EXCEPTION E'ENSAYO OK (todo revertido). sucursal %, ajena %, pedido %, pedido con regalos %.\nSaltados:\n- %',
    v_suc, v_suc_ajena, v_pedido, v_ped_bonif, COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
END
$ensayo$;
