-- Ensayo de permisos de #1003 (plata que se lee por REST), #1013 (mermas por
-- REST) y #1014 (el encargado lee compras).
--
-- Corre contra prod SIN dejar rastro: todo dentro de BEGIN ... ROLLBACK. Simula
-- una sesión real con `SET LOCAL ROLE authenticated` + el `sub` de un perfil
-- real en request.jwt.claims, que es lo que hace PostgREST con un JWT de usuario.
-- El depósito con transportista extra (el borde de #1003) se fabrica dentro de
-- la misma transacción, porque prod no tiene ninguno.
--
-- Junta TODAS las aserciones que no se cumplen y al final corta con un RAISE
-- EXCEPTION que las lista. Si llega al NOTICE final, pasó. (Por el MCP de Supabase, que no muestra NOTICEs, cambiá
-- ese NOTICE por un RAISE EXCEPTION para ver el resultado.)
--
-- Las aserciones de `pedido_items.costo_unitario_al_crear` dependen de la
-- segunda mitad (el REVOKE): entre una mitad y la otra, esa parte falla a
-- propósito.
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-plata-rest.sql

BEGIN;

DO $ensayo$
DECLARE
  -- Lo que pide el front: src/lib/pedidoItemColumnas.ts (PEDIDO_ITEM_COLUMNAS).
  c_item_columnas CONSTANT text := 'id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque';
  v_suc bigint;
  v_quien record;
  v_dep uuid;
  v_n bigint;
  v_lee boolean;
  v_tabla text;
  v_falla text;
  v_fallas text[] := '{}';
  v_total jsonb;         -- filas de cada tabla de compras en la sucursal, contadas como postgres
  v_prod record;         -- un producto de la sucursal, leído como postgres
BEGIN
  -- Una sucursal con los cuatro roles activos (y al menos dos preventistas,
  -- uno para fabricar el depósito); entre esas, la de más ítems vendidos, para
  -- que un "no ve nada" de abajo sea por permiso y no por falta de datos.
  SELECT us.sucursal_id INTO v_suc
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.activo AND p.rol IN ('preventista', 'transportista', 'encargado', 'admin')
   GROUP BY us.sucursal_id
  HAVING count(DISTINCT p.rol) = 4 AND count(*) FILTER (WHERE p.rol = 'preventista') >= 2
   ORDER BY (SELECT count(*) FROM pedido_items pi WHERE pi.sucursal_id = us.sucursal_id) DESC
   LIMIT 1;
  IF v_suc IS NULL THEN RAISE EXCEPTION 'ensayo · ninguna sucursal tiene los cuatro roles'; END IF;

  -- Depósito con transportista extra: un preventista de la sucursal (hay
  -- varios; transportistas puede haber uno solo, y hace falta para su propio
  -- caso) pasa a `deposito` como rol principal y recibe `transportista` como
  -- rol extra.
  SELECT p.id INTO v_dep FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default AND us.sucursal_id = v_suc
   WHERE p.activo AND p.rol = 'preventista' ORDER BY p.id DESC LIMIT 1;
  UPDATE perfiles SET rol = 'deposito' WHERE id = v_dep;
  INSERT INTO perfil_roles (usuario_id, sucursal_id, rol) VALUES (v_dep, v_suc, 'transportista')
    ON CONFLICT DO NOTHING;  -- puede tenerlo ya: hay preventistas con transportista extra

  -- Los cuatro roles más el depósito fabricado, o el ensayo no prueba nada.
  SELECT count(DISTINCT p.rol) INTO v_n FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
   WHERE p.activo AND p.rol IN ('preventista', 'transportista', 'encargado', 'admin') AND p.id <> v_dep;
  IF v_n < 4 THEN RAISE EXCEPTION 'ensayo · la sucursal % no tiene los cuatro roles (tiene %)', v_suc, v_n; END IF;

  SELECT jsonb_build_object(
    'compras',               (SELECT count(*) FROM compras WHERE sucursal_id = v_suc),
    'compra_items',          (SELECT count(*) FROM compra_items WHERE sucursal_id = v_suc),
    'compra_cargos',         (SELECT count(*) FROM compra_cargos WHERE sucursal_id = v_suc),
    'compra_cargo_repartos', (SELECT count(*) FROM compra_cargo_repartos r JOIN compra_cargos c ON c.id = r.cargo_id WHERE c.sucursal_id = v_suc),
    'notas_credito',         (SELECT count(*) FROM notas_credito WHERE sucursal_id = v_suc),
    'nota_credito_items',    (SELECT count(*) FROM nota_credito_items WHERE sucursal_id = v_suc)
  ) INTO v_total;

  -- Leído ANTES de bajar de rol: depósito no lee productos (#999), y un
  -- INSERT ... SELECT FROM productos le insertaría cero filas sin error, que el
  -- ensayo confundiría con "la policy lo dejó pasar".
  SELECT id, stock INTO v_prod FROM productos WHERE sucursal_id = v_suc ORDER BY id LIMIT 1;

  FOR v_quien IN
    SELECT * FROM (
      SELECT DISTINCT ON (p.rol) p.id, p.rol::text AS rol
        FROM perfiles p
        JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
       WHERE p.activo AND p.rol IN ('preventista', 'transportista', 'encargado', 'admin')
         AND p.id <> v_dep
       ORDER BY p.rol, p.id
    ) r
    UNION ALL SELECT v_dep, 'deposito+transportista'
  LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_quien.id, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- (1) #1003 · nadie lee pedido_items.costo_unitario_al_crear por SELECT
    -- directo, ni siquiera el admin: el costo sale por costos_pedido_items().
    v_lee := true;
    BEGIN
      EXECUTE 'SELECT count(costo_unitario_al_crear) FROM pedido_items' INTO v_n;
    EXCEPTION WHEN insufficient_privilege THEN
      v_lee := false;
    END;
    IF v_lee THEN
      v_fallas := v_fallas || format('#1003 · %s lee pedido_items.costo_unitario_al_crear por SELECT directo', v_quien.rol);
    END IF;

    -- (2) #1003 · lo que pide el front sigue andando para todos.
    EXECUTE format('SELECT count(*) FROM (SELECT %s FROM pedido_items) x', c_item_columnas) INTO v_n;

    -- (3) #1003 · la RPC: costos sólo para admin y encargado.
    BEGIN
      EXECUTE 'SELECT count(*) FROM public.costos_pedido_items($1)' INTO v_n
        USING (SELECT array_agg(id) FROM (SELECT id FROM pedido_items WHERE sucursal_id = v_suc ORDER BY id DESC LIMIT 50) x);
      IF v_quien.rol IN ('admin', 'encargado') AND v_n = 0 THEN
        v_fallas := v_fallas || format('#1003 · costos_pedido_items no le devuelve nada a %s', v_quien.rol);
      ELSIF v_quien.rol NOT IN ('admin', 'encargado') AND v_n > 0 THEN
        v_fallas := v_fallas || format('#1003 · costos_pedido_items le devuelve %s costos a %s', v_n, v_quien.rol);
      END IF;
    EXCEPTION WHEN undefined_function THEN
      v_fallas := v_fallas || format('#1003 · no existe costos_pedido_items (%s)', v_quien.rol);
    END;

    -- (4) #1003 · mermas_stock (con su costo_unitario): sólo admin.
    SELECT count(*) INTO v_n FROM mermas_stock;
    IF v_quien.rol <> 'admin' AND v_n > 0 THEN
      v_fallas := v_fallas || format('#1003 · %s lee %s mermas (con costo_unitario)', v_quien.rol, v_n);
    END IF;

    -- (5) #1003 · movimientos y transferencias entre sucursales: admin y encargado.
    FOREACH v_tabla IN ARRAY ARRAY['movimientos_sucursal', 'movimiento_sucursal_items',
                                   'transferencias_stock', 'transferencia_items'] LOOP
      EXECUTE format('SELECT count(*) FROM %I', v_tabla) INTO v_n;
      IF v_quien.rol NOT IN ('admin', 'encargado') AND v_n > 0 THEN
        v_fallas := v_fallas || format('#1003 · %s lee %s filas de %s', v_quien.rol, v_n, v_tabla);
      END IF;
    END LOOP;
    -- La función invoker que suma esos costos para /compras no le da nada a
    -- quien no puede leer las filas.
    SELECT count(*) INTO v_n FROM public.compras_transferencias_netas('2000-01-01', '2999-12-31', ARRAY[v_suc]);
    IF v_quien.rol NOT IN ('admin', 'encargado') AND v_n > 0 THEN
      v_fallas := v_fallas || format('#1003 · %s recibe %s filas de compras_transferencias_netas', v_quien.rol, v_n);
    END IF;

    -- (6) #1003 + #1014 · la familia de compras (compras, sus líneas y las notas
    -- de crédito de proveedor) la leen admin, encargado y depósito; nadie más.
    FOREACH v_tabla IN ARRAY ARRAY['compras', 'compra_items', 'compra_cargos', 'compra_cargo_repartos',
                                   'notas_credito', 'nota_credito_items'] LOOP
      EXECUTE format('SELECT count(*) FROM %I', v_tabla) INTO v_n;
      IF v_quien.rol IN ('preventista', 'transportista') AND v_n > 0 THEN
        v_fallas := v_fallas || format('#1003 · %s lee %s filas de %s', v_quien.rol, v_n, v_tabla);
      ELSIF v_quien.rol IN ('admin', 'encargado') AND v_n <> (v_total->>v_tabla)::bigint THEN
        v_fallas := v_fallas || format('#1014 · %s lee %s de %s filas de %s', v_quien.rol, v_n, v_total->>v_tabla, v_tabla);
      END IF;
    END LOOP;

    -- (7) #1013 · nadie salvo admin inserta una merma por REST.
    IF v_quien.rol <> 'admin' THEN
      v_falla := NULL;
      BEGIN
        INSERT INTO mermas_stock (producto_id, cantidad, motivo, stock_anterior, stock_nuevo, sucursal_id, usuario_id, costo_unitario)
        VALUES (v_prod.id, 1, 'ensayo', v_prod.stock, v_prod.stock, v_suc, v_quien.id, 1);
        v_falla := format('#1013 · %s inserta una merma por REST', v_quien.rol);
      EXCEPTION
        WHEN insufficient_privilege THEN
          NULL; -- lo esperado: lo corta la policy
        WHEN others THEN
          -- La policy lo dejó pasar y lo frenó otra cosa (un CHECK, un NOT NULL):
          -- para el ensayo es lo mismo que haber insertado.
          v_falla := format('#1013 · la policy deja insertar una merma a %s (cortó: %s)', v_quien.rol, SQLERRM);
      END;
      IF v_falla IS NOT NULL THEN v_fallas := v_fallas || v_falla; END IF;
    END IF;

    EXECUTE 'RESET ROLE';
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ensayo #1003/#1013/#1014 · % fallas:%', cardinality(v_fallas),
      E'\n  ' || array_to_string(v_fallas, E'\n  ');
  END IF;

  RAISE NOTICE 'ensayo #1003/#1013/#1014 OK · sucursal=% deposito+transportista=%', v_suc, v_dep;
END
$ensayo$;

ROLLBACK;
