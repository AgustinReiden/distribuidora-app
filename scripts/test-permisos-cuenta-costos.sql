-- Ensayo de permisos de #973 (cuenta del cliente) y #974 (costos de productos).
--
-- Corre contra prod SIN dejar rastro: todo dentro de BEGIN ... ROLLBACK. Simula
-- una sesión real con `SET LOCAL ROLE authenticated` + el `sub` de un perfil
-- real en request.jwt.claims, que es lo que hace PostgREST con un JWT de usuario.
-- Los casos de `reservado_admin` se fabrican con un UPDATE dentro de la misma
-- transacción, porque prod puede no tener uno que sirva.
--
-- Cualquier aserción que no se cumpla corta con RAISE EXCEPTION. Si llega al
-- NOTICE final, pasó. (Por el MCP de Supabase, que no muestra NOTICEs, cambiá
-- ese NOTICE por un RAISE EXCEPTION para ver el resultado.)
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-cuenta-costos.sql

BEGIN;

DO $ensayo$
DECLARE
  v_prev UUID;           -- un preventista activo con clientes propios
  v_admin UUID;          -- un admin de la misma sucursal
  v_suc BIGINT;
  v_propio BIGINT;       -- asignado a v_prev: visible
  v_ajeno BIGINT;        -- asignado sólo a otro preventista: NO visible
  v_otra_suc BIGINT;     -- de otra sucursal: NO visible
  v_res_sin_venta BIGINT;-- sin asignar, se marca reservado, v_prev nunca le vendió: NO visible
  v_res_con_venta BIGINT;-- sin asignar, se marca reservado, v_prev ya le vendió: visible
  v_res JSON;
  v_falla TEXT;
  v_cli BIGINT;
BEGIN
  -- Datos reales, leídos como postgres antes de bajar de rol.
  SELECT p.id, us.sucursal_id INTO v_prev, v_suc
  FROM perfiles p
  JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
  WHERE p.rol = 'preventista' AND p.activo
    AND EXISTS (SELECT 1 FROM cliente_preventistas cp JOIN clientes c ON c.id = cp.cliente_id
                WHERE cp.preventista_id = p.id AND c.sucursal_id = us.sucursal_id)
  ORDER BY p.id LIMIT 1;
  IF v_prev IS NULL THEN RAISE EXCEPTION 'ensayo · no hay preventista con clientes'; END IF;

  SELECT p.id INTO v_admin FROM perfiles p
  JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default AND us.sucursal_id = v_suc
  WHERE p.rol = 'admin' AND p.activo ORDER BY p.id LIMIT 1;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'ensayo · no hay admin en la sucursal %', v_suc; END IF;

  SELECT c.id INTO v_propio FROM clientes c JOIN cliente_preventistas cp ON cp.cliente_id = c.id
  WHERE cp.preventista_id = v_prev AND c.sucursal_id = v_suc AND NOT c.reservado_admin
  ORDER BY c.id LIMIT 1;

  SELECT c.id INTO v_ajeno FROM clientes c
  WHERE c.sucursal_id = v_suc
    AND EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
    AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id AND cp.preventista_id = v_prev)
  ORDER BY c.id LIMIT 1;

  SELECT c.id INTO v_otra_suc FROM clientes c WHERE c.sucursal_id <> v_suc ORDER BY c.id LIMIT 1;

  SELECT c.id INTO v_res_sin_venta FROM clientes c
  WHERE c.sucursal_id = v_suc AND NOT c.reservado_admin
    AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
    AND NOT EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_prev)
  ORDER BY c.id LIMIT 1;

  SELECT c.id INTO v_res_con_venta FROM clientes c
  WHERE c.sucursal_id = v_suc AND NOT c.reservado_admin
    AND NOT EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
    AND EXISTS (SELECT 1 FROM pedidos pe WHERE pe.cliente_id = c.id AND pe.usuario_id = v_prev)
  ORDER BY c.id LIMIT 1;

  IF v_propio IS NULL OR v_ajeno IS NULL OR v_otra_suc IS NULL
     OR v_res_sin_venta IS NULL OR v_res_con_venta IS NULL THEN
    RAISE EXCEPTION 'ensayo · faltan clientes: propio=% ajeno=% otra_suc=% res_sin_venta=% res_con_venta=%',
      v_propio, v_ajeno, v_otra_suc, v_res_sin_venta, v_res_con_venta;
  END IF;

  UPDATE clientes SET reservado_admin = true WHERE id IN (v_res_sin_venta, v_res_con_venta);

  ------------------------------------------------------------- preventista
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_prev, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  FOREACH v_cli IN ARRAY ARRAY[v_propio, v_res_con_venta] LOOP
    v_res := public.obtener_resumen_cuenta_cliente(v_cli::int);
    IF v_res IS NULL OR v_res::jsonb ? 'error' THEN
      RAISE EXCEPTION '#973 · el preventista no ve la cuenta de su cliente visible %: %', v_cli, v_res;
    END IF;
  END LOOP;

  FOREACH v_cli IN ARRAY ARRAY[v_ajeno, v_otra_suc, v_res_sin_venta] LOOP
    v_falla := NULL;
    BEGIN
      v_res := public.obtener_resumen_cuenta_cliente(v_cli::int);
      v_falla := format('#973 · el preventista lee la cuenta del cliente no visible %s: %s', v_cli, v_res);
    EXCEPTION WHEN insufficient_privilege THEN
      NULL; -- lo esperado
    END;
    IF v_falla IS NOT NULL THEN RAISE EXCEPTION '%', v_falla; END IF;
  END LOOP;

  ------------------------------------------------------------------- admin
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  FOREACH v_cli IN ARRAY ARRAY[v_propio, v_ajeno, v_res_sin_venta, v_res_con_venta] LOOP
    v_res := public.obtener_resumen_cuenta_cliente(v_cli::int);
    IF v_res IS NULL OR v_res::jsonb ? 'error' THEN
      RAISE EXCEPTION '#973 · el admin no ve la cuenta del cliente % de su sucursal: %', v_cli, v_res;
    END IF;
  END LOOP;
  EXECUTE 'RESET ROLE';

  RAISE NOTICE 'ensayo #973 OK · prev=% admin=% suc=% propio=% ajeno=% otra_suc=% res_sin_venta=% res_con_venta=%',
    v_prev, v_admin, v_suc, v_propio, v_ajeno, v_otra_suc, v_res_sin_venta, v_res_con_venta;
END
$ensayo$;

-- #974 · costos de productos ------------------------------------------------
DO $ensayo974$
DECLARE
  -- Lo que pide el front: src/lib/productoColumnas.ts (PRODUCTO_COLUMNAS).
  c_columnas CONSTANT text := 'id, nombre, precio, stock, categoria, created_at, codigo, impuestos_internos, precio_sin_iva, stock_minimo, porcentaje_iva, proveedor_id, updated_at, sucursal_id, tp_import_id, unidades_de_venta_por_fardo, etiqueta_bulto, ultimo_tipo_compra, categoria_id, cantidad_minima_venta, marca_id, condicion_iva, subcategoria_id, ii_encuadre_id, activo, unidades_por_bulto';
  v_quien RECORD;
  v_n bigint;
  v_costos bigint;
  v_lee_costo boolean;
BEGIN
  -- Un perfil real por rol, todos de la misma sucursal (la 1 si la hay).
  FOR v_quien IN
    SELECT DISTINCT ON (p.rol) p.id, p.rol, us.sucursal_id
      FROM perfiles p
      JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
     WHERE p.activo AND p.rol IN ('preventista', 'encargado', 'admin')
       AND EXISTS (SELECT 1 FROM productos pr WHERE pr.sucursal_id = us.sucursal_id)
     ORDER BY p.rol, us.sucursal_id, p.id
  LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_quien.id, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- (a) Nadie lee un costo por SELECT directo, ni siquiera el admin.
    v_lee_costo := true;
    BEGIN
      EXECUTE 'SELECT count(costo_real) FROM productos' INTO v_n;
    EXCEPTION WHEN insufficient_privilege THEN
      v_lee_costo := false;
    END;
    IF v_lee_costo THEN
      RAISE EXCEPTION '#974 · % (%) lee productos.costo_real por SELECT directo', v_quien.rol, v_quien.id;
    END IF;

    -- (b) Lo que pide el front sigue andando y trae filas.
    EXECUTE format('SELECT count(*) FROM (SELECT %s FROM productos) x', c_columnas) INTO v_n;
    IF v_n = 0 THEN
      RAISE EXCEPTION '#974 · % (%) no ve ningún producto con PRODUCTO_COLUMNAS', v_quien.rol, v_quien.id;
    END IF;

    -- (c) La RPC: costos para admin y encargado, cero filas para el preventista.
    EXECUTE 'SELECT count(*) FROM public.costos_productos()' INTO v_costos;
    IF v_quien.rol IN ('admin', 'encargado') AND v_costos <> v_n THEN
      RAISE EXCEPTION '#974 · % (%) ve % productos pero la RPC le da costos de %', v_quien.rol, v_quien.id, v_n, v_costos;
    ELSIF v_quien.rol = 'preventista' AND v_costos <> 0 THEN
      RAISE EXCEPTION '#974 · el preventista % recibe % costos de la RPC', v_quien.id, v_costos;
    END IF;

    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'ensayo #974 · % % sucursal=% productos=% costos_rpc=%',
      v_quien.rol, v_quien.id, v_quien.sucursal_id, v_n, v_costos;
  END LOOP;

  -- (d) anon tampoco tiene los costos, y no ejecuta la RPC.
  IF has_column_privilege('anon', 'public.productos', 'costo_real', 'SELECT') THEN
    RAISE EXCEPTION '#974 · anon tiene SELECT sobre productos.costo_real';
  END IF;
  IF has_function_privilege('anon', 'public.costos_productos(bigint[])', 'EXECUTE') THEN
    RAISE EXCEPTION '#974 · anon ejecuta costos_productos';
  END IF;

  RAISE NOTICE 'ensayo #974 OK';
END
$ensayo974$;

ROLLBACK;
