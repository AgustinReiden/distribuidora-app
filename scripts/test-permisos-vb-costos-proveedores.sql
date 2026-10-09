-- Ensayo de permisos de #1034 (el vale blanco sólo lo ven admin, encargado y
-- quien lo cargó), #1049 (pedido_items no se escribe por REST) y #1014 (el
-- encargado lee proveedores).
--
-- SÓLO LECTURA: no fabrica perfiles ni toca filas. Usa perfiles reales de la
-- sucursal con más vales blancos y simula cada sesión como PostgREST, con
-- `SET LOCAL ROLE authenticated` + el `sub` en request.jwt.claims. Termina
-- SIEMPRE en RAISE EXCEPTION (así se ve por el MCP de Supabase, que no muestra
-- NOTICEs): 'ENSAYO OK …' o 'ENSAYO FALLÓ …' con la lista de fallas.
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-vb-costos-proveedores.sql

BEGIN;

DO $ensayo$
DECLARE
  -- Lo que pide el front: src/lib/pedidoItemColumnas.ts (PEDIDO_ITEM_COLUMNAS).
  c_item_columnas CONSTANT text := 'id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque';
  v_suc       bigint;
  v_transp    uuid;    -- transportista que repartió VB que no cargó él
  v_prev      uuid;    -- preventista que cargó VB
  v_enc       uuid;
  v_adm       uuid;
  v_cli       bigint;  -- cliente VB con vales de ese preventista y de otros
  v_vb_suc    bigint[];
  v_vb_transp bigint[];
  v_vb_prev   bigint[];
  v_nvb_transp bigint;  -- pedidos NO VB del transportista: no se le tienen que ir
  v_prov      bigint;
  v_ci_prev   bigint;  -- VB vivos del cliente cargados por el preventista
  v_ci_total  bigint;  -- VB vivos del cliente, de todos
  v_vb_propios_transp bigint;  -- VB que cargó el propio transportista (multi-rol): ésos sí los ve
  v_item_vb   bigint;  -- una línea de un VB que el transportista repartió y no cargó
  v_item_ped  bigint;  -- y su pedido
  v_rec       record;  -- un recorrido con un VB que su transportista no cargó
  v_quien     record;
  v_n         bigint;
  v_j         json;
  v_priv      record;
  v_fallas    text[] := '{}';
BEGIN
  -- #1049 · privilegios de escritura sobre pedido_items (no hace falta sesión).
  FOR v_priv IN
    SELECT r.rol, p.priv
      FROM unnest(ARRAY['authenticated', 'anon']) r(rol),
           unnest(ARRAY['INSERT', 'UPDATE']) p(priv)
  LOOP
    IF has_table_privilege(v_priv.rol, 'public.pedido_items', v_priv.priv) THEN
      v_fallas := v_fallas || format('#1049 · %s tiene %s sobre pedido_items', v_priv.rol, v_priv.priv);
    END IF;
    IF has_column_privilege(v_priv.rol, 'public.pedido_items', 'costo_unitario_al_crear', v_priv.priv) THEN
      v_fallas := v_fallas || format('#1049 · %s tiene %s sobre pedido_items.costo_unitario_al_crear', v_priv.rol, v_priv.priv);
    END IF;
  END LOOP;

  -- La sucursal con más vales blancos y sus perfiles reales.
  SELECT sucursal_id INTO v_suc FROM pedidos WHERE tipo_factura = 'VB'
   GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;

  SELECT pe.transportista_id INTO v_transp
    FROM pedidos pe JOIN perfiles pf ON pf.id = pe.transportista_id
   WHERE pe.sucursal_id = v_suc AND pe.tipo_factura = 'VB' AND pf.rol = 'transportista'
     AND pe.usuario_id IS DISTINCT FROM pe.transportista_id
   GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;

  SELECT pe.usuario_id INTO v_prev
    FROM pedidos pe JOIN perfiles pf ON pf.id = pe.usuario_id
   WHERE pe.sucursal_id = v_suc AND pe.tipo_factura = 'VB' AND pf.rol = 'preventista'
   GROUP BY 1 ORDER BY count(*) DESC LIMIT 1;

  SELECT p.id INTO v_enc FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
   WHERE p.activo AND p.rol = 'encargado' ORDER BY p.id LIMIT 1;

  SELECT p.id INTO v_adm FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
   WHERE p.activo AND p.rol = 'admin' ORDER BY p.id LIMIT 1;

  IF v_transp IS NULL OR v_prev IS NULL OR v_enc IS NULL OR v_adm IS NULL THEN
    RAISE EXCEPTION 'ensayo · a la sucursal % le falta un perfil (transp %, prev %, enc %, adm %)',
      v_suc, v_transp, v_prev, v_enc, v_adm;
  END IF;

  -- Lo que hay, contado como postgres.
  SELECT array_agg(id) INTO v_vb_suc FROM pedidos WHERE sucursal_id = v_suc AND tipo_factura = 'VB';
  SELECT array_agg(id) INTO v_vb_transp FROM pedidos
   WHERE sucursal_id = v_suc AND tipo_factura = 'VB' AND transportista_id = v_transp
     AND usuario_id IS DISTINCT FROM v_transp;
  SELECT array_agg(id) INTO v_vb_prev FROM pedidos
   WHERE sucursal_id = v_suc AND tipo_factura = 'VB' AND usuario_id = v_prev;
  SELECT count(*) INTO v_nvb_transp FROM pedidos
   WHERE sucursal_id = v_suc AND transportista_id = v_transp AND tipo_factura IS DISTINCT FROM 'VB';
  SELECT count(*) INTO v_prov FROM proveedores WHERE sucursal_id = v_suc;
  SELECT count(*) INTO v_vb_propios_transp FROM pedidos
   WHERE sucursal_id = v_suc AND tipo_factura = 'VB' AND usuario_id = v_transp;
  SELECT id, pedido_id INTO v_item_vb, v_item_ped FROM pedido_items
   WHERE pedido_id = ANY(v_vb_transp) ORDER BY id LIMIT 1;

  -- #1034 · bot_mi_recorrido (sólo el bot, sin sesión de app): un recorrido con
  -- un VB que su transportista no cargó no lo lista.
  SELECT r.transportista_id, r.sucursal_id, r.fecha, p.id AS pedido_id INTO v_rec
    FROM recorrido_pedidos rp JOIN recorridos r ON r.id = rp.recorrido_id
    JOIN pedidos p ON p.id = rp.pedido_id
   WHERE p.tipo_factura = 'VB' AND p.usuario_id IS DISTINCT FROM r.transportista_id
   ORDER BY r.id DESC LIMIT 1;
  IF v_rec.pedido_id IS NOT NULL THEN
    -- Sólo si es el recorrido que la RPC elige para esa fecha (el último).
    v_j := public.bot_mi_recorrido(v_rec.transportista_id, v_rec.sucursal_id, v_rec.fecha);
    IF EXISTS (SELECT 1 FROM json_array_elements(v_j -> 'pedidos') e
                WHERE (e ->> 'pedido_id')::bigint = v_rec.pedido_id) THEN
      v_fallas := v_fallas || format('#1034 · bot_mi_recorrido le lista al transportista el VB %s (con su total) que no cargó', v_rec.pedido_id);
    END IF;
  END IF;

  SELECT cliente_id INTO v_cli FROM pedidos
   WHERE sucursal_id = v_suc AND tipo_factura = 'VB'
   GROUP BY 1 HAVING bool_or(usuario_id = v_prev) AND bool_or(usuario_id <> v_prev)
   ORDER BY count(*) DESC LIMIT 1;
  SELECT count(*) FILTER (WHERE usuario_id = v_prev), count(*)
    INTO v_ci_prev, v_ci_total
    FROM pedidos WHERE cliente_id = v_cli AND tipo_factura = 'VB' AND estado IS DISTINCT FROM 'cancelado';

  IF cardinality(v_vb_transp) IS NULL OR v_nvb_transp = 0 OR v_prov = 0 OR v_cli IS NULL THEN
    RAISE EXCEPTION 'ensayo · faltan datos para probar (vb_transp %, no_vb_transp %, proveedores %, cliente %)',
      cardinality(v_vb_transp), v_nvb_transp, v_prov, v_cli;
  END IF;

  FOR v_quien IN
    SELECT * FROM (VALUES (v_transp, 'transportista'), (v_prev, 'preventista'),
                          (v_enc, 'encargado'), (v_adm, 'admin')) x(id, rol)
  LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_quien.id, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- #1034 · pedidos VB visibles.
    EXECUTE 'SELECT count(*) FROM pedidos WHERE id = ANY($1)' INTO v_n USING v_vb_suc;
    IF v_quien.rol IN ('admin', 'encargado') AND v_n <> cardinality(v_vb_suc) THEN
      v_fallas := v_fallas || format('#1034 · %s ve %s de los %s VB de la sucursal', v_quien.rol, v_n, cardinality(v_vb_suc));
    ELSIF v_quien.rol = 'preventista' AND v_n <> cardinality(v_vb_prev) THEN
      v_fallas := v_fallas || format('#1034 · el preventista ve %s VB y cargó %s', v_n, cardinality(v_vb_prev));
    ELSIF v_quien.rol = 'transportista' AND v_n <> v_vb_propios_transp THEN
      v_fallas := v_fallas || format('#1034 · el transportista ve %s VB y cargó %s', v_n, v_vb_propios_transp);
    END IF;

    IF v_quien.rol = 'transportista' THEN
      -- Ni las líneas, ni el historial (que guarda el total lista→costo de la 320).
      EXECUTE 'SELECT count(*) FROM pedido_items WHERE pedido_id = ANY($1)' INTO v_n USING v_vb_transp;
      IF v_n <> 0 THEN
        v_fallas := v_fallas || format('#1034 · el transportista lee %s líneas de VB', v_n);
      END IF;
      EXECUTE 'SELECT count(*) FROM pedido_historial WHERE pedido_id = ANY($1)' INTO v_n USING v_vb_transp;
      IF v_n <> 0 THEN
        v_fallas := v_fallas || format('#1034 · el transportista lee %s filas de historial de VB', v_n);
      END IF;
      -- registrar_salvedad es DEFINER y autoriza por su cuenta. Con cantidad 0
      -- contesta antes de escribir nada: si pasó la autorización dice "Cantidad
      -- debe ser mayor a 0"; si no, "No autorizado para este pedido".
      EXECUTE 'SELECT public.registrar_salvedad($1, $2, 0, ''danado'', NULL, NULL, false, NULL)::json'
        INTO v_j USING v_item_ped, v_item_vb;
      IF (v_j ->> 'error') IS DISTINCT FROM 'No autorizado para este pedido' THEN
        v_fallas := v_fallas || format('#1034 · registrar_salvedad deja pasar al transportista sobre el VB %s (contesta: %s)', v_item_ped, v_j ->> 'error');
      END IF;
      -- Y sus pedidos comunes siguen ahí.
      EXECUTE 'SELECT count(*) FROM pedidos WHERE transportista_id = $1 AND tipo_factura IS DISTINCT FROM ''VB'''
        INTO v_n USING v_transp;
      IF v_n <> v_nvb_transp THEN
        v_fallas := v_fallas || format('#1034 · el transportista ve %s de sus %s pedidos que no son VB', v_n, v_nvb_transp);
      END IF;
    END IF;

    IF v_quien.rol = 'preventista' THEN
      -- El que cargó el VB lo sigue viendo con sus líneas.
      EXECUTE format('SELECT count(*) FROM (SELECT %s FROM pedido_items WHERE pedido_id = ANY($1)) x', c_item_columnas)
        INTO v_n USING v_vb_prev;
      IF v_n = 0 THEN
        v_fallas := v_fallas || '#1034 · el preventista dejó de ver las líneas de los VB que cargó';
      END IF;
    END IF;

    -- #1034 · consumo interno de la ficha: admin y encargado, todo; el resto,
    -- sólo lo que cargó.
    EXECUTE 'SELECT public.obtener_resumen_cuenta_cliente($1)' INTO v_j USING v_cli::int;
    v_n := (v_j -> 'consumo_interno' ->> 'pedidos')::bigint;
    IF v_quien.rol IN ('admin', 'encargado') AND v_n IS DISTINCT FROM v_ci_total THEN
      v_fallas := v_fallas || format('#1034 · consumo_interno del cliente %s le cuenta %s VB a %s (son %s)', v_cli, v_n, v_quien.rol, v_ci_total);
    ELSIF v_quien.rol = 'preventista' AND v_n IS DISTINCT FROM v_ci_prev THEN
      v_fallas := v_fallas || format('#1034 · consumo_interno del cliente %s le cuenta %s VB al preventista (cargó %s)', v_cli, v_n, v_ci_prev);
    ELSIF v_quien.rol = 'transportista' AND v_n IS DISTINCT FROM 0::bigint THEN
      v_fallas := v_fallas || format('#1034 · consumo_interno del cliente %s le cuenta %s VB al transportista', v_cli, v_n);
    END IF;

    -- #1014 · proveedores.
    EXECUTE 'SELECT count(*) FROM proveedores' INTO v_n;
    IF v_quien.rol IN ('admin', 'encargado') AND v_n <> v_prov THEN
      v_fallas := v_fallas || format('#1014 · %s lee %s de los %s proveedores de la sucursal', v_quien.rol, v_n, v_prov);
    ELSIF v_quien.rol IN ('preventista', 'transportista') AND v_n <> 0 THEN
      v_fallas := v_fallas || format('#1014 · %s lee %s proveedores', v_quien.rol, v_n);
    END IF;

    -- Lo que pide el front de pedido_items sigue andando para todos.
    EXECUTE format('SELECT count(*) FROM (SELECT %s FROM pedido_items) x', c_item_columnas) INTO v_n;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, sucursal %):\n- %',
      cardinality(v_fallas), v_suc, array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (sucursal %, % VB, % proveedores, cliente %)',
    v_suc, cardinality(v_vb_suc), v_prov, v_cli;
END
$ensayo$;

ROLLBACK;
