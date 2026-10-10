-- =========================================================================
-- registrar_transferencia se borra (#1108)
--
-- Era SECURITY DEFINER y bajaba productos.stock sin declarar
-- app.stock_origen: la ultima excepcion que le quedaba a la verificacion
-- "funciones que escriben stock sin app.stock_origen" de la 336 (repetida en
-- la 340). La mig 330 (#1048) ya se la habia revocado a PUBLIC, anon y
-- authenticated porque dejaba suplantar a un admin, y decidio no borrarla
-- para que el codigo quedara como referencia. Decision del dueno
-- (2026-10-10): se borra. El codigo sigue en git
-- (migrations/archive/037_notas_credito_y_transferencias.sql).
--
-- Sin caller, verificado antes de borrarla (sólo lectura):
--   - src/ y supabase/functions/: ninguna llamada. La reemplazo el flujo de
--     movimientos entre sucursales con aprobacion (useMovimientosQuery.ts).
--   - pg_proc / pg_depend: nada la referencia.
--   - pg_stat_statements (desde 2025-12-26): 5 llamadas en total, las 5
--     transferencias de transferencias_stock (la ultima, 2026-06-02).
--
-- Las tablas transferencias_stock (5 filas) y transferencia_items (13) NO se
-- tocan: son historial y no dependen de la funcion.
-- registrar_ingreso_sucursal tampoco: es una excepcion listada a proposito en
-- el check STK-F de auditoria_integridad().
--
-- Ensayo: scripts/test-registrar-transferencia-1108.sql (falla antes, pasa
-- despues).
-- =========================================================================

BEGIN;

-- Una sola sobrecarga confirmada contra pg_proc en vivo.
DROP FUNCTION IF EXISTS public.registrar_transferencia(bigint, date, text, numeric, uuid, jsonb);

DO $verif$
DECLARE
  v_lista text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_transferencia'
  ) THEN
    RAISE EXCEPTION '#1108 · registrar_transferencia sigue existiendo.';
  END IF;

  -- La verificacion de la 336, ya sin ninguna excepcion.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY 1) INTO v_lista
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
     AND pg_get_functiondef(p.oid) ~* 'UPDATE\s+(public\.)?productos\M'
     AND pg_get_functiondef(p.oid) ~* 'stock\s*='
     AND pg_get_functiondef(p.oid) !~ 'app\.stock_origen';
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '#1108 · funciones que escriben stock sin app.stock_origen: %', v_lista;
  END IF;
END;
$verif$;

COMMIT;
