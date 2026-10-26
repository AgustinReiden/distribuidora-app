-- Ensayo de permisos de las funciones tablero_* (mig 392).
--
-- SEG-A las marcaba "sin guard de rol" porque el guard vive en el helper
-- _tablero_sucursales, que la heurística no conocía. Esto prueba la conducta,
-- no el texto: como lo hace PostgREST (`SET LOCAL ROLE authenticated` y el
-- `sub` en request.jwt.claims), un preventista y un transportista tienen que
-- recibir 'Acceso denegado' de cada una, y un admin tiene que poder usarlas.
--
-- Corre contra prod SIN dejar rastro: es un único DO que termina SIEMPRE en
-- RAISE EXCEPTION (molde de test-permisos-definer-sin-rol.sql).
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-tablero.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_admin   uuid;
  v_prev    uuid;
  v_transp  uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_quien   record;
  v_sql     text;
  v_llamadas text[];
  v_json    jsonb;
BEGIN
  SELECT p.id, us.sucursal_id INTO v_admin, v_suc FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'admin' AND COALESCE(p.activo, true)
   ORDER BY p.id, us.sucursal_id LIMIT 1;
  -- Sin roles extra: un preventista con el extra de encargado sí pasaría.
  SELECT p.id INTO v_prev FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
   WHERE p.rol = 'preventista' AND COALESCE(p.activo, true)
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id)
   ORDER BY p.id LIMIT 1;
  SELECT p.id INTO v_transp FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = v_suc
   WHERE p.rol = 'transportista' AND COALESCE(p.activo, true)
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id)
   ORDER BY p.id LIMIT 1;
  SELECT id INTO v_cliente FROM clientes WHERE sucursal_id = v_suc ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_prev IS NULL OR v_transp IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ensayo · faltan datos (admin %, preventista %, transportista %, cliente %)',
      v_admin, v_prev, v_transp, v_cliente;
  END IF;

  -- Las 9 que marcaba SEG-A, con la sucursal NULL (lo que manda el tablero) y la
  -- ficha de un cliente de la sucursal del admin.
  v_llamadas := ARRAY[
    'SELECT to_jsonb(public.tablero_buscar_clientes(''a'', NULL, 5))',
    'SELECT to_jsonb(public.tablero_categorias(NULL, NULL, NULL, NULL))',
    'SELECT to_jsonb(public.tablero_clientes_inactivos(NULL, 14, true))',
    'SELECT to_jsonb(public.tablero_cobertura(NULL, NULL))',
    'SELECT to_jsonb(public.tablero_facturacion_mensual(NULL, NULL))',
    format('SELECT to_jsonb(public.tablero_ficha_cliente(%s))', v_cliente),
    'SELECT to_jsonb(public.tablero_kpis(NULL, NULL))',
    'SELECT to_jsonb(public.tablero_productos_categoria(NULL, ''Sin categoria'', NULL, NULL, NULL, NULL))',
    'SELECT to_jsonb(public.tablero_top_clientes_zona(NULL, NULL, NULL, 5, 14))'
  ];

  FOR v_quien IN SELECT * FROM (VALUES ('preventista', v_prev), ('transportista', v_transp)) AS q(rol, id) LOOP
    FOREACH v_sql IN ARRAY v_llamadas LOOP
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_quien.id, 'role', 'authenticated')::text, true);
      BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE v_sql INTO v_json;
        EXECUTE 'RESET ROLE';
        v_fallas := v_fallas || format('%s respondió en vez de negar: %s', v_quien.rol, v_sql);
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'Acceso denegado%' THEN
          v_fallas := v_fallas || format('%s falló con otra cosa en %s: %s', v_quien.rol, v_sql, SQLERRM);
        END IF;
      END;
    END LOOP;
  END LOOP;

  FOREACH v_sql IN ARRAY v_llamadas LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE v_sql INTO v_json;
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
      v_fallas := v_fallas || format('admin no pudo usar %s: %s', v_sql, SQLERRM);
    END;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (todo revertido). % llamadas negadas a preventista y transportista y abiertas para admin, sucursal %.',
    cardinality(v_llamadas), v_suc;
END
$ensayo$;
