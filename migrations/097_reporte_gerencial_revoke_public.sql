-- ============================================================================
-- 097 · Seguridad: quitar EXECUTE de PUBLIC/anon en las funciones de reportes
-- ============================================================================
-- Postgres otorga EXECUTE a PUBLIC por defecto al CREAR una función. Por eso
-- reporte_gerencial y guardar_analisis_mensual (mig 095) quedaron ejecutables
-- por el rol `anon` (la anon key es pública, va en el bundle del frontend).
-- Como el RPC trata `auth.uid() IS NULL` como contexto de servicio (acceso
-- total a cualquier sucursal/red), cualquiera con la anon key podía leer TODOS
-- los datos financieros. Este es el cierre del agujero.
--
-- Se quita el acceso de PUBLIC y anon; sólo quedan:
--   * authenticated → usuarios logueados de la app (el RPC valida admin +
--     sucursales asignadas internamente).
--   * service_role  → Claude Code vía MCP (comando /reporte-mensual) y crons.
-- (Aplicado en prod vía MCP el 2026-06-29; este archivo lo deja en el historial.)

REVOKE EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date)            FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.guardar_analisis_mensual(bigint, date, text, jsonb) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date)            TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_analisis_mensual(bigint, date, text, jsonb) TO authenticated, service_role;
