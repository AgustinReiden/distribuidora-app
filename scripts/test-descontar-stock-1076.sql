-- Ensayo de #1076: descontar_stock_atomico, RPC sin caller que authenticated
-- podía ejecutar y que bajaba productos.stock sin declarar app.stock_origen.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Simula la sesión como
-- PostgREST (SET LOCAL ROLE authenticated + request.jwt.claims + x-sucursal-id).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en cada caso; después, pasar.
--
--   psql "$DATABASE_URL" -f scripts/test-descontar-stock-1076.sql

DO $ensayo$
DECLARE
  v_fallas   text[] := '{}';
  v_saltados text[] := '{}';

  v_admin    uuid;    -- admin activo con sucursal
  v_suc      bigint;  -- su sucursal
  v_prod     bigint;  -- producto de v_suc con stock
  v_antes    int;
  v_despues  int;
  v_lista    text;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, us.sucursal_id INTO v_admin, v_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND COALESCE(pf.activo, true)
   ORDER BY us.sucursal_id, pf.id LIMIT 1;
  SELECT id, stock INTO v_prod, v_antes FROM productos
   WHERE sucursal_id = v_suc AND activo AND stock > 0 ORDER BY id LIMIT 1;

  -- ------------------------------------------------ 1 · la función no existe
  IF EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'descontar_stock_atomico'
  ) THEN
    v_fallas := v_fallas || 'descontar_stock_atomico · sigue existiendo en public'::text;
  END IF;

  -- ----------------------------- 2 · un admin no puede bajar stock por ahí --
  -- La llamada va por EXECUTE para que el DO compile también sin la función.
  IF v_prod IS NULL THEN
    v_saltados := v_saltados || 'llamada como admin: no hay producto con stock en la sucursal'::text;
  ELSE
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
    BEGIN
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE 'SELECT public.descontar_stock_atomico($1)'
        USING jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 1));
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN undefined_function OR insufficient_privilege THEN NULL;
    END;
    SELECT stock INTO v_despues FROM productos WHERE id = v_prod;
    IF v_despues < v_antes THEN
      v_fallas := v_fallas || format(
        'descontar_stock_atomico · un admin bajó el stock del producto %s de %s a %s sin documento ni origen',
        v_prod, v_antes, v_despues);
    END IF;
  END IF;

  -- -------- 3 · la verificación 7.2 de la mig 336, sin excepción para ésta --
  -- La 336 la dejaba afuera a sabiendas; registrar_transferencia sigue afuera
  -- (revocada en #1048, no es de este issue).
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1) INTO v_lista
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
     AND pg_get_functiondef(p.oid) ~* 'UPDATE\s+(public\.)?productos\M'
     AND pg_get_functiondef(p.oid) ~* 'stock\s*='
     AND pg_get_functiondef(p.oid) !~ 'app\.stock_origen'
     AND p.proname <> 'registrar_transferencia';
  IF v_lista IS NOT NULL THEN
    v_fallas := v_fallas || format('funciones que escriben stock sin app.stock_origen: %s', v_lista);
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %\nSaltados:\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
  END IF;
  RAISE EXCEPTION E'ENSAYO OK (todo revertido). sucursal %, admin %, producto %.\nSaltados:\n- %',
    v_suc, v_admin, v_prod, COALESCE(NULLIF(array_to_string(v_saltados, E'\n- '), ''), '(ninguno)');
END
$ensayo$;
