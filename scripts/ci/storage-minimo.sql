-- El esquema mínimo de Supabase Storage para probar las policies del bucket `facturas` en una
-- base LOCAL (la imagen conc-base y la del CI no traen storage.objects). Tarjeta C6 de #1603
-- (1564-b7). Arma lo que las policies y auditoria_storage() leen: storage.buckets,
-- storage.objects con RLS, storage.foldername() (copia de la de Supabase) y las tres policies
-- de facturas como están en producción desde la 463 (las sucursales del usuario).
--
-- Si storage.objects ya existe (producción, o una base que ya lo tiene) NO hace nada: nunca
-- reemplaza un storage de verdad.
--
-- Corre como supabase_admin (el dueño del esquema storage en la imagen; postgres no puede crear
-- ahí), y deja las tablas a nombre de postgres para que la migración, que corre como postgres,
-- pueda cambiar sus policies como lo hizo la 463 en producción:
--   docker exec -i <contenedor> psql -U supabase_admin -h localhost -d postgres -v ON_ERROR_STOP=1 -f - < scripts/ci/storage-minimo.sql
--
-- Después: aplicar 539_facturas_por_sucursal_activa y correr scripts/test-facturas-sucursal-activa-ola2-1603.sql.

DO $minimo$
BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    RAISE NOTICE 'storage.objects ya existe: no se toca nada';
    RETURN;
  END IF;

  CREATE SCHEMA IF NOT EXISTS storage;
  GRANT USAGE ON SCHEMA storage TO postgres, authenticated, anon, service_role;

  CREATE TABLE storage.buckets (
    id         text PRIMARY KEY,
    name       text NOT NULL,
    public     boolean DEFAULT false,
    created_at timestamptz DEFAULT now()
  );
  CREATE TABLE storage.objects (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bucket_id  text REFERENCES storage.buckets(id),
    name       text,
    owner      uuid,
    created_at timestamptz DEFAULT now(),
    metadata   jsonb
  );
  ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
  GRANT ALL ON storage.objects, storage.buckets TO authenticated, service_role;

  -- La de Supabase: las carpetas del path, sin el nombre del archivo.
  CREATE FUNCTION storage.foldername(name text) RETURNS text[]
  LANGUAGE plpgsql IMMUTABLE AS $f$
  DECLARE
    _parts text[];
  BEGIN
    SELECT string_to_array(name, '/') INTO _parts;
    RETURN _parts[1:array_length(_parts, 1) - 1];
  END
  $f$;
  GRANT EXECUTE ON FUNCTION storage.foldername(text) TO authenticated, anon, service_role;

  INSERT INTO storage.buckets (id, name, public) VALUES ('facturas', 'facturas', false);

  ALTER TABLE storage.buckets OWNER TO postgres;
  ALTER TABLE storage.objects OWNER TO postgres;
  ALTER FUNCTION storage.foldername(text) OWNER TO postgres;

  -- Las tres de la 463, tal cual.
  CREATE POLICY facturas_select_encargado_o_admin ON storage.objects
    FOR SELECT TO authenticated
    USING (
      bucket_id = 'facturas'
      AND public.es_encargado_o_admin()
      AND (storage.foldername(name))[1] IN (
        SELECT us.sucursal_id::text FROM public.usuario_sucursales us WHERE us.usuario_id = auth.uid())
    );
  CREATE POLICY facturas_insert_encargado_o_admin ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
      bucket_id = 'facturas'
      AND public.es_encargado_o_admin()
      AND (storage.foldername(name))[1] IN (
        SELECT us.sucursal_id::text FROM public.usuario_sucursales us WHERE us.usuario_id = auth.uid())
    );
  CREATE POLICY facturas_delete_admin ON storage.objects
    FOR DELETE TO authenticated
    USING (
      bucket_id = 'facturas'
      AND public.es_admin()
      AND (storage.foldername(name))[1] IN (
        SELECT us.sucursal_id::text FROM public.usuario_sucursales us WHERE us.usuario_id = auth.uid())
    );
END
$minimo$;
