-- ============================================================================
-- 109 — RPC migraciones_aplicadas() (primitiva de verificación de drift)
-- ============================================================================
-- Expone el ledger real de migraciones (supabase_migrations.schema_migrations)
-- como un RPC en `public`. Razon: ese schema NO esta expuesto por PostgREST, asi
-- que ni supabase-js ni scripts/check-migrations.mjs pueden leerlo directo.
--
-- Con esto un script de CI / un humano puede contrastar lo aplicado en prod
-- contra los archivos de migrations/ (ver scripts/check-migrations.mjs y
-- migrations/MANIFEST.md). Un agente con el MCP de Supabase no necesita esto:
-- usa list_migrations directo.
--
-- Gate identico a auditoria_integridad (105): service_role (auth.uid() IS NULL)
-- o rol admin. Solo lectura, sin secretos (devuelve version + name).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.migraciones_aplicadas()
RETURNS TABLE (version text, name text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  RETURN QUERY
    SELECT m.version, m.name
    FROM supabase_migrations.schema_migrations m
    ORDER BY m.version;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.migraciones_aplicadas() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.migraciones_aplicadas() TO authenticated, service_role;
