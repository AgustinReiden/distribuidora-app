-- Ensayo de #1108: registrar_transferencia, función sin caller que bajaba
-- productos.stock sin declarar app.stock_origen. Era la última excepción de la
-- verificación "funciones que escriben stock sin app.stock_origen" (336/340).
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en 1 y 2; la 3 pasa antes y después.
--
--   psql "$DATABASE_URL" -f scripts/test-registrar-transferencia-1108.sql

DO $ensayo$
DECLARE
  v_fallas text[] := '{}';
  v_lista  text;
  v_n      int;
BEGIN
  -- ------------------------------------------------ 1 · la función no existe
  IF EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_transferencia'
  ) THEN
    v_fallas := v_fallas || 'registrar_transferencia · sigue existiendo en public'::text;
  END IF;

  -- ------- 2 · la verificación 7.2 de la mig 336, ya sin ninguna excepción --
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1) INTO v_lista
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
     AND pg_get_functiondef(p.oid) ~* 'UPDATE\s+(public\.)?productos\M'
     AND pg_get_functiondef(p.oid) ~* 'stock\s*='
     AND pg_get_functiondef(p.oid) !~ 'app\.stock_origen';
  IF v_lista IS NOT NULL THEN
    v_fallas := v_fallas || format('funciones que escriben stock sin app.stock_origen: %s', v_lista);
  END IF;

  -- ------------------------ 3 · el historial de transferencias queda intacto
  SELECT count(*) INTO v_n FROM transferencias_stock;
  IF v_n <> 5 THEN
    v_fallas := v_fallas || format('transferencias_stock · %s filas, se esperaban las 5 históricas', v_n);
  END IF;
  SELECT count(*) INTO v_n FROM transferencia_items;
  IF v_n <> 13 THEN
    v_fallas := v_fallas || format('transferencia_items · %s filas, se esperaban las 13 históricas', v_n);
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas, todo revertido):\n- %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK (todo revertido).';
END
$ensayo$;
