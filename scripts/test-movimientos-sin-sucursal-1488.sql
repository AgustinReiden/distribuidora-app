-- Ensayo de #1488 (tarjeta 11 de #1477): los movimientos entre sucursales rechazan al que no es
-- de la sucursal y al desactivado con el token vivo.
--
-- Corre contra prod SIN dejar rastro (salvo valores de secuencia): un único DO que termina
-- SIEMPRE en una excepción, y cada caso corre en su propio sub-bloque que se revierte al
-- terminar. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el
-- COMMIT; después, solo.
--
-- Simula PostgREST como test-permisos-1474.sql: `SET LOCAL ROLE authenticated`, el `sub` de un
-- perfil real en request.jwt.claims y la sucursal en x-sucursal-id. Las personas salen de prod:
-- un admin sólo de la 1 (crea el envío de la 1 a la 2), un admin sólo de la 2, un preventista
-- sólo de la 1 y uno sólo de la 2. El producto nace en el ensayo, en la 1 con stock 10; el envío
-- lleva 2.
--
-- No miembro: el header nombra una sucursal que no es suya, current_sucursal_id() da NULL y
-- _rol_en_sucursal() también.
--   N1 · el preventista de la 1 con x-sucursal-id 2 deniega el envío
--   N2 · el preventista de la 1 con x-sucursal-id 2 lo acepta (crear_nuevo)
--   N3 · el preventista de la 2 con x-sucursal-id 1 lo edita (a 1 unidad)
--   N4 · el preventista de la 2 con x-sucursal-id 1 lo cancela
-- Desactivado con el token vivo: current_sucursal_id() da NULL desde la 463, y _rol_en_sucursal()
-- le sigue dando su rol.
--   D1 · el admin de la 2, desactivado, con x-sucursal-id 2, lo deniega
--   D2 · el admin de la 2, desactivado, con x-sucursal-id 2, lo acepta
--   D3 · el admin de la 1, desactivado, con x-sucursal-id 1, lo edita
--   D4 · el admin de la 1, desactivado, con x-sucursal-id 1, lo cancela
--   En los ocho: la RPC devuelve success false con "no tiene acceso a la sucursal", el envío
--   sigue pendiente con sus 2 unidades, el producto de la 1 sigue en 8 y en la 2 no nace nada.
-- Regresiones (pasan antes y después)
--   C1 · crear_movimiento_sucursal: el preventista de la 1 con x-sucursal-id 2 y el admin de la 1
--        desactivado → "Sucursal no seleccionada", sin envío nuevo
--   OK1 · el admin de la 2 con x-sucursal-id 2 deniega → success, el producto vuelve a 10
--   OK2 · el admin de la 2 con x-sucursal-id 2 acepta (crear_nuevo) → success, nace con 2 en la 2
--   OK3 · el admin de la 1 con x-sucursal-id 1 edita a 3 → success, el producto queda en 7
--   OK4 · el admin de la 1 con x-sucursal-id 1 cancela → success, el producto vuelve a 10
--   R1  · el admin de la 1 (es de la 1, no de la 2) con x-sucursal-id 1 acepta → "sucursal destino"
-- Cuerpos
--   G1 · ninguna de las cinco compara current_sucursal_id() ni _rol_en_sucursal() con <> o
--        NOT IN sin atajar el NULL
-- Gate (auditoria_rpcs_definer()->guardas_nulas)
--   A1 · cinco RPCs definer de juguete: marca la que hace `IF current_sucursal_id() <> p` y la
--        de `_rol_en_sucursal(…) NOT IN`; no marca la de IS DISTINCT FROM, la que chequea
--        `IS NULL` antes del `<>`, ni la del rol con COALESCE. Y no marca ninguna de movimientos.
--
-- Sin la migración tiene que FALLAR en N1–N4, D1–D4, G1 y A1; C1, OK1–OK4 y R1 pasan igual.
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenar un rollback).
--
--   psql "$DATABASE_URL" -f scripts/test-movimientos-sin-sucursal-1488.sql

DO $ensayo$
DECLARE
  v_a1     uuid;  -- admin sólo de la 1
  v_a2     uuid;  -- admin sólo de la 2
  v_p1     uuid;  -- preventista sólo de la 1
  v_p2     uuid;  -- preventista sólo de la 2
  v_prod   bigint;
  v_mov    bigint;
  v_item   bigint;
  v_movs   bigint;
  v_j      jsonb;
  v_res    text;
  v_t      text;
  v_caso   record;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  CREATE FUNCTION pg_temp.sucs(p uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(sucursal_id::text, ',' ORDER BY sucursal_id) FROM public.usuario_sucursales WHERE usuario_id = p
  $f$;
  SELECT id INTO v_a1 FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '1' ORDER BY id LIMIT 1;
  SELECT id INTO v_a2 FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '2' ORDER BY id LIMIT 1;
  SELECT id INTO v_p1 FROM perfiles WHERE rol = 'preventista' AND activo AND pg_temp.sucs(id) = '1' ORDER BY id LIMIT 1;
  SELECT id INTO v_p2 FROM perfiles WHERE rol = 'preventista' AND activo AND pg_temp.sucs(id) = '2' ORDER BY id LIMIT 1;
  IF v_a1 IS NULL OR v_a2 IS NULL OR v_p1 IS NULL OR v_p2 IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: a1 % a2 % p1 % p2 %', v_a1, v_a2, v_p1, v_p2;
  END IF;
  IF public._rol_en_sucursal(v_a1, 1) <> 'admin' OR public._rol_en_sucursal(v_a2, 2) <> 'admin' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture: los admins no son admin en su sucursal';
  END IF;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  CREATE FUNCTION pg_temp.servidor() RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', '{}', true);
    PERFORM set_config('request.headers', '{}', true);
  END $f$;
  -- La RPC como PostgREST (rol authenticated): su jsonb, o {"excepcion": …}.
  CREATE FUNCTION pg_temp.rpc(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN jsonb_build_object('excepcion', SQLSTATE || ' ' || SQLERRM);
  END $f$;
  -- El estado del envío, del producto de origen y de lo que nació en la 2, en una línea.
  CREATE FUNCTION pg_temp.estado(p_mov bigint, p_prod bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('estado=%s items=%s origen=%s destino=%s',
                  (SELECT estado FROM public.movimientos_sucursal WHERE id = p_mov),
                  (SELECT string_agg(cantidad::text, ',') FROM public.movimiento_sucursal_items WHERE movimiento_id = p_mov),
                  (SELECT stock FROM public.productos WHERE id = p_prod),
                  (SELECT COALESCE(sum(stock), 0) FROM public.productos WHERE sucursal_id = 2 AND nombre = 'ZZ ensayo 1488'))
  $f$;

  -- ------------------------------------------------------------- fixtures ---
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1488', 100, 10, 50, 1) RETURNING id INTO v_prod;
  PERFORM pg_temp.como(v_a1, 1);
  v_j := pg_temp.rpc(format('SELECT public.crear_movimiento_sucursal(2, %L, %L::jsonb)', 'ensayo 1488',
                            jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 2))));
  v_mov := (v_j->>'movimiento_id')::bigint;
  IF v_mov IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture: el admin de la 1 no pudo crear el envío: %', v_j;
  END IF;
  SELECT id INTO v_item FROM public.movimiento_sucursal_items WHERE movimiento_id = v_mov;
  PERFORM pg_temp.servidor();
  v_res := pg_temp.estado(v_mov, v_prod);
  IF v_res <> 'estado=pendiente items=2 origen=8 destino=0' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture: el envío nació como %', v_res;
  END IF;

  -- ---------------------------------------------------- N1–N4 y D1–D4 ---
  FOR v_caso IN
    SELECT * FROM (VALUES
      ('N1 · preventista de la 1 con header 2 deniega',  v_p1, 2::bigint, false, 'denegar'),
      ('N2 · preventista de la 1 con header 2 acepta',   v_p1, 2::bigint, false, 'aceptar'),
      ('N3 · preventista de la 2 con header 1 edita',    v_p2, 1::bigint, false, 'editar'),
      ('N4 · preventista de la 2 con header 1 cancela',  v_p2, 1::bigint, false, 'cancelar'),
      ('D1 · admin de la 2 desactivado deniega',         v_a2, 2::bigint, true,  'denegar'),
      ('D2 · admin de la 2 desactivado acepta',          v_a2, 2::bigint, true,  'aceptar'),
      ('D3 · admin de la 1 desactivado edita',           v_a1, 1::bigint, true,  'editar'),
      ('D4 · admin de la 1 desactivado cancela',         v_a1, 1::bigint, true,  'cancelar')
    ) AS c(nombre, uid, suc, desactivar, accion)
  LOOP
    BEGIN
      IF v_caso.desactivar THEN
        PERFORM pg_temp.servidor();
        UPDATE perfiles SET activo = false WHERE id = v_caso.uid;
      END IF;
      PERFORM pg_temp.como(v_caso.uid, v_caso.suc);
      v_j := pg_temp.rpc(CASE v_caso.accion
        WHEN 'denegar'  THEN format('SELECT public.denegar_movimiento_sucursal(%s, %L)', v_mov, 'ensayo 1488')
        WHEN 'cancelar' THEN format('SELECT public.cancelar_movimiento_sucursal(%s, %L)', v_mov, 'ensayo 1488')
        WHEN 'editar'   THEN format('SELECT public.editar_movimiento_sucursal(%s, %L, %L::jsonb)', v_mov, 'ensayo 1488',
                               jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1)))
        WHEN 'aceptar'  THEN format('SELECT public.aceptar_movimiento_sucursal(%s, %L::jsonb)', v_mov,
                               jsonb_build_array(jsonb_build_object('item_id', v_item, 'accion', 'crear_nuevo')))
      END);
      PERFORM pg_temp.servidor();
      v_res := pg_temp.estado(v_mov, v_prod);
      IF COALESCE((v_j->>'success')::boolean, true)
         OR position('no tiene acceso a la sucursal' IN COALESCE(v_j->>'error', '')) = 0
         OR v_res <> 'estado=pendiente items=2 origen=8 destino=0' THEN
        v_fallas := v_fallas || format('%s: %s · %s', v_caso.nombre, v_j, v_res);
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s: error inesperado %s', v_caso.nombre, SQLERRM);
    END;
  END LOOP;

  -- ------------------------------------------------------------------ C1 ---
  BEGIN
    SELECT count(*) INTO v_movs FROM public.movimientos_sucursal;
    PERFORM pg_temp.como(v_p1, 2);
    v_j := pg_temp.rpc(format('SELECT public.crear_movimiento_sucursal(1, %L, %L::jsonb)', 'ensayo 1488',
                              jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1))));
    IF COALESCE((v_j->>'success')::boolean, true) OR COALESCE(v_j->>'error', '') <> 'Sucursal no seleccionada' THEN
      v_fallas := v_fallas || format('C1 · el preventista de la 1 con header 2 crea: %s', v_j);
    END IF;
    PERFORM pg_temp.servidor();
    UPDATE perfiles SET activo = false WHERE id = v_a1;
    PERFORM pg_temp.como(v_a1, 1);
    v_j := pg_temp.rpc(format('SELECT public.crear_movimiento_sucursal(2, %L, %L::jsonb)', 'ensayo 1488',
                              jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1))));
    IF COALESCE((v_j->>'success')::boolean, true) OR COALESCE(v_j->>'error', '') <> 'Sucursal no seleccionada' THEN
      v_fallas := v_fallas || format('C1 · el admin de la 1 desactivado crea: %s', v_j);
    END IF;
    PERFORM pg_temp.servidor();
    IF (SELECT count(*) FROM public.movimientos_sucursal) <> v_movs THEN
      v_fallas := v_fallas || text 'C1 · nació un envío';
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('C1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------ OK1–OK4 ---
  FOR v_caso IN
    SELECT * FROM (VALUES
      ('OK1 · admin de la 2 deniega',  v_a2, 2::bigint, 'denegar',  'estado=denegada items=2 origen=10 destino=0'),
      ('OK2 · admin de la 2 acepta',   v_a2, 2::bigint, 'aceptar',  'estado=aceptada items=2 origen=8 destino=2'),
      ('OK3 · admin de la 1 edita a 3', v_a1, 1::bigint, 'editar',  'estado=pendiente items=3 origen=7 destino=0'),
      ('OK4 · admin de la 1 cancela',  v_a1, 1::bigint, 'cancelar', 'estado=cancelada items=2 origen=10 destino=0')
    ) AS c(nombre, uid, suc, accion, esperado)
  LOOP
    BEGIN
      PERFORM pg_temp.como(v_caso.uid, v_caso.suc);
      v_j := pg_temp.rpc(CASE v_caso.accion
        WHEN 'denegar'  THEN format('SELECT public.denegar_movimiento_sucursal(%s, %L)', v_mov, 'ensayo 1488')
        WHEN 'cancelar' THEN format('SELECT public.cancelar_movimiento_sucursal(%s, %L)', v_mov, 'ensayo 1488')
        WHEN 'editar'   THEN format('SELECT public.editar_movimiento_sucursal(%s, %L, %L::jsonb)', v_mov, 'ensayo 1488',
                               jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 3)))
        WHEN 'aceptar'  THEN format('SELECT public.aceptar_movimiento_sucursal(%s, %L::jsonb)', v_mov,
                               jsonb_build_array(jsonb_build_object('item_id', v_item, 'accion', 'crear_nuevo')))
      END);
      PERFORM pg_temp.servidor();
      v_res := pg_temp.estado(v_mov, v_prod);
      IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_res <> v_caso.esperado THEN
        v_fallas := v_fallas || format('%s: %s · %s', v_caso.nombre, v_j, v_res);
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s: error inesperado %s', v_caso.nombre, SQLERRM);
    END;
  END LOOP;

  -- ------------------------------------------------------------------ R1 ---
  BEGIN
    PERFORM pg_temp.como(v_a1, 1);
    v_j := pg_temp.rpc(format('SELECT public.aceptar_movimiento_sucursal(%s, %L::jsonb)', v_mov,
                              jsonb_build_array(jsonb_build_object('item_id', v_item, 'accion', 'crear_nuevo'))));
    PERFORM pg_temp.servidor();
    IF COALESCE((v_j->>'success')::boolean, true)
       OR position('sucursal destino' IN COALESCE(v_j->>'error', '')) = 0
       OR pg_temp.estado(v_mov, v_prod) <> 'estado=pendiente items=2 origen=8 destino=0' THEN
      v_fallas := v_fallas || format('R1 · el admin de la origen acepta: %s', v_j);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ G1 ---
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_res
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname ~ '_movimiento_sucursal$'
     AND (p.prosrc ~ 'current_sucursal_id\(\)\s*(<>|!=|NOT\s+IN)'
          OR p.prosrc ~ '_rol_en_sucursal\([^()]*(\([^()]*\)[^()]*)*\)\s*(<>|!=|NOT\s+IN)');
  IF v_res IS NOT NULL THEN
    v_fallas := v_fallas || ('G1 · comparan un NULL posible con <> o NOT IN: ' || v_res);
  END IF;
  v_notas := v_notas || format('envío %s, producto %s', v_mov, v_prod);

  -- ------------------------------------------------------------------ A1 ---
  BEGIN
    CREATE FUNCTION public.zz_1488_abierta(p bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $f$
    BEGIN
      IF current_sucursal_id() <> p THEN RAISE EXCEPTION 'no'; END IF;
      RETURN 1;
    END $f$;
    CREATE FUNCTION public.zz_1488_rol_abierto(p bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $f$
    BEGIN
      IF public._rol_en_sucursal(auth.uid(), p) NOT IN ('admin', 'encargado') THEN RAISE EXCEPTION 'no'; END IF;
      RETURN 1;
    END $f$;
    CREATE FUNCTION public.zz_1488_distinta(p bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $f$
    BEGIN
      IF current_sucursal_id() IS DISTINCT FROM p THEN RAISE EXCEPTION 'no'; END IF;
      RETURN 1;
    END $f$;
    CREATE FUNCTION public.zz_1488_nula_antes(p bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $f$
    DECLARE
      v_s bigint := current_sucursal_id();
    BEGIN
      IF v_s IS NULL THEN RAISE EXCEPTION 'no'; END IF;
      IF v_s <> p THEN RAISE EXCEPTION 'no'; END IF;
      RETURN 1;
    END $f$;
    CREATE FUNCTION public.zz_1488_rol_coalesce(p bigint) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $f$
    BEGIN
      IF COALESCE(public._rol_en_sucursal(auth.uid(), p), '') NOT IN ('admin', 'encargado') THEN RAISE EXCEPTION 'no'; END IF;
      RETURN 1;
    END $f$;
    v_j := public.auditoria_rpcs_definer()->'guardas_nulas';
    SELECT string_agg(g->>'nombre', ',' ORDER BY g->>'nombre') INTO v_res
      FROM jsonb_array_elements(COALESCE(v_j, '[]'::jsonb)) g
     WHERE g->>'nombre' LIKE 'zz\_1488\_%' OR g->>'nombre' LIKE '%\_movimiento\_sucursal';
    IF v_j IS NULL OR jsonb_typeof(v_j) <> 'array'
       OR v_res IS DISTINCT FROM 'zz_1488_abierta,zz_1488_rol_abierto' THEN
      v_fallas := v_fallas || format('A1 · guardas_nulas = %s (de juguete y movimientos: %s)', v_j, v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A1 · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  IF v_t LIKE 'ENSAYO OK%' AND current_setting('ensayo.continuar', true) = '1' THEN
    RAISE NOTICE '%', v_t;
  ELSE
    RAISE EXCEPTION '%', v_t;
  END IF;
 END;
END
$ensayo$;
