-- Ensayo de #1077: registrar_compra_completa y actualizar_compra_items rechazan
-- una cabecera cuyo subtotal no iguala la suma de los renglones (tolerancia 1,
-- la misma que COMPRA-A2), antes de tocar stock, y dejan pasar el redondeo.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-subtotal-compra-1077.sql

DO $ensayo$
DECLARE
  v_fallas    text[] := '{}';

  v_suc       bigint := 1;
  v_admin     uuid;
  v_prod      bigint;   -- producto activo de v_suc, quieto
  v_compra    bigint;   -- la compra que se crea acá, para editarla
  v_stock0    int;
  v_stock     int;
  v_n0        bigint;
  v_n         bigint;
  v_subtotal  numeric;
  v_items     jsonb;
  v_r         jsonb;
BEGIN
  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true) AND us.sucursal_id = v_suc
   ORDER BY pf.id LIMIT 1;

  -- El canario bloquea su fila hasta el final del DO: un producto sin ventas
  -- ni compras recientes, para no trabar a nadie.
  SELECT p.id INTO v_prod FROM productos p
   WHERE p.sucursal_id = v_suc AND p.activo
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi JOIN pedidos pe ON pe.id = pi.pedido_id
                      WHERE pi.producto_id = p.id AND pe.created_at > now() - interval '30 days')
     AND NOT EXISTS (SELECT 1 FROM compra_items ci JOIN compras c ON c.id = ci.compra_id
                      WHERE ci.producto_id = p.id AND c.created_at > now() - interval '30 days')
   ORDER BY p.id LIMIT 1;

  IF v_admin IS NULL OR v_prod IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay admin (%) o producto (%) para el canario', v_admin, v_prod;
  END IF;

  SELECT stock INTO v_stock0 FROM productos WHERE id = v_prod;
  SELECT count(*) INTO v_n0 FROM compras;

  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- Dos renglones que suman 1.000,00 (600 + 400).
  v_items := jsonb_build_array(
    jsonb_build_object('producto_id', v_prod, 'cantidad', 6, 'costo_unitario', 100, 'subtotal', 600,
                       'bonificacion', 0, 'porcentaje_iva', 21, 'impuestos_internos', 0),
    jsonb_build_object('producto_id', v_prod, 'cantidad', 4, 'costo_unitario', 100, 'subtotal', 400,
                       'bonificacion', 0, 'porcentaje_iva', 21, 'impuestos_internos', 0));

  -- ------------------------------------------- 1 · alta con cabecera desfasada
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_r := public.registrar_compra_completa(
    NULL, 'ENSAYO 1077', 'ENSAYO-1077-A', current_date,
    1500, 0, 0, 1500, 'efectivo', 'ensayo #1077', v_admin, v_items,
    'ZZ');
  EXECUTE 'RESET ROLE';

  IF COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || 'alta: aceptó subtotal 1.500 con renglones que suman 1.000'::text;
  ELSIF v_r->>'error' NOT ILIKE '%subtotal%' THEN
    v_fallas := v_fallas || format('alta: rechazó, pero no por el subtotal: %s', v_r->>'error');
  END IF;
  SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
  SELECT count(*) INTO v_n FROM compras;
  IF v_stock IS DISTINCT FROM v_stock0 OR v_n <> v_n0 THEN
    v_fallas := v_fallas || format('alta rechazada dejó rastro: stock %s → %s, compras %s → %s',
                                   v_stock0, v_stock, v_n0, v_n);
  END IF;

  -- ------------------------------- 1b · el borde: 1,50 de más también se rechaza
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_r := public.registrar_compra_completa(
    NULL, 'ENSAYO 1077', 'ENSAYO-1077-A2', current_date,
    1001.50, 0, 0, 1001.50, 'efectivo', 'ensayo #1077', v_admin, v_items,
    'ZZ');
  EXECUTE 'RESET ROLE';
  IF COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || 'alta: aceptó 1,50 de diferencia (la tolerancia es 1)'::text;
  END IF;

  -- -------------------------- 2 · alta dentro de la tolerancia (como la 73)
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_r := public.registrar_compra_completa(
    NULL, 'ENSAYO 1077', 'ENSAYO-1077-B', current_date,
    999.98, 0, 0, 999.98, 'efectivo', 'ensayo #1077', v_admin, v_items,
    'ZZ');
  EXECUTE 'RESET ROLE';

  IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('alta: rechazó una diferencia de 0,02: %s', v_r->>'error');
  ELSE
    v_compra := (v_r->>'compra_id')::bigint;
  END IF;

  IF v_compra IS NOT NULL THEN
    SELECT stock INTO v_stock0 FROM productos WHERE id = v_prod;

    -- ------------------------------------- 3 · edición con cabecera desfasada
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_r := public.actualizar_compra_items(
      v_compra, v_items, 300, 0, 300, v_admin,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb);
    EXECUTE 'RESET ROLE';

    IF COALESCE((v_r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || 'edición: aceptó subtotal 300 con renglones que suman 1.000'::text;
    ELSIF v_r->>'error' NOT ILIKE '%subtotal%' THEN
      v_fallas := v_fallas || format('edición: rechazó, pero no por el subtotal: %s', v_r->>'error');
    END IF;
    SELECT stock INTO v_stock FROM productos WHERE id = v_prod;
    SELECT subtotal INTO v_subtotal FROM compras WHERE id = v_compra;
    SELECT count(*) INTO v_n FROM compra_items WHERE compra_id = v_compra;
    IF v_stock IS DISTINCT FROM v_stock0 OR v_subtotal <> 999.98 OR v_n <> 2 THEN
      v_fallas := v_fallas || format('edición rechazada dejó rastro: stock %s → %s, subtotal 999,98 → %s, renglones 2 → %s',
                                     v_stock0, v_stock, v_subtotal, v_n);
    END IF;

    -- --------------------------- 3b · el borde: 1,50 de menos también se rechaza
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_r := public.actualizar_compra_items(
      v_compra, v_items, 998.50, 0, 998.50, v_admin,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb);
    EXECUTE 'RESET ROLE';
    IF COALESCE((v_r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || 'edición: aceptó 1,50 de diferencia (la tolerancia es 1)'::text;
    END IF;

    -- --------------------------------- 4 · edición dentro de la tolerancia
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_r := public.actualizar_compra_items(
      v_compra, v_items, 1000.02, 0, 1000.02, v_admin,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb);
    EXECUTE 'RESET ROLE';

    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('edición: rechazó una diferencia de 0,02: %s', v_r->>'error');
    END IF;
  END IF;

  -- ------------------------------------------------------------ veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · alta y edición rechazan el subtotal desfasado sin tocar stock, y aceptan 0,02';
END;
$ensayo$;
