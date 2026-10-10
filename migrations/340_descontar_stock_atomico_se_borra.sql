-- =========================================================================
-- descontar_stock_atomico se borra (#1076)
--
-- Mismo caso que restaurar_stock_atomico (#617, mig 246), en la otra
-- direccion: la RPC era SECURITY DEFINER, authenticated la podia ejecutar
-- (el guard dejaba pasar a admin y preventista) y bajaba productos.stock de
-- cualquier producto de la sucursal activa sin ningun documento detras y sin
-- declarar app.stock_origen.
--
-- Sin caller, verificado antes de borrarla:
--   - src/: sólo la envolvian useDescontarStockMutation
--     (src/hooks/queries/useProductosQuery.ts) y useProductos().descontarStock
--     (src/hooks/supabase/useProductos.ts), sin ningun uso fuera de su
--     definicion y sus tests. Se borran en el mismo cambio.
--   - supabase/functions/: ninguna referencia.
--   - pg_proc / pg_views / pg_trigger / pg_depend: nada la referencia.
--   - pg_stat_statements (track = top, desde 2025-12-26): cero llamadas; el
--     unico statement que la nombra es el DDL de la mig 008.
--
-- La mig 336 la dejaba a sabiendas fuera de su verificacion "funciones que
-- escriben stock sin app.stock_origen"; con la funcion borrada ese hueco se
-- cierra y la verificacion de abajo lo replica sin la excepcion.
-- registrar_transferencia sigue afuera: revocada en #1048, no es de este issue.
--
-- Ensayo: scripts/test-descontar-stock-1076.sql (falla antes, pasa despues).
-- =========================================================================

BEGIN;

-- Una sola sobrecarga confirmada contra pg_proc en vivo.
DROP FUNCTION IF EXISTS public.descontar_stock_atomico(jsonb);

DO $verif$
DECLARE
  v_lista text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'descontar_stock_atomico'
  ) THEN
    RAISE EXCEPTION '#1076 · descontar_stock_atomico sigue existiendo.';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1) INTO v_lista
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
     AND pg_get_functiondef(p.oid) ~* 'UPDATE\s+(public\.)?productos\M'
     AND pg_get_functiondef(p.oid) ~* 'stock\s*='
     AND pg_get_functiondef(p.oid) !~ 'app\.stock_origen'
     AND p.proname <> 'registrar_transferencia';
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1076 · funciones que escriben stock sin app.stock_origen: %', v_lista;
  END IF;
END;
$verif$;

COMMIT;
