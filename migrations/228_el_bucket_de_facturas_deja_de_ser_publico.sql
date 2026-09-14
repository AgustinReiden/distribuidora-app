-- El bucket "facturas" deja de ser público
--
-- NO APLICADA TODAVIA. Este archivo fija en SQL una config que hasta ahora
-- sólo vivía armada a mano en el dashboard de Supabase (storage.buckets no
-- tenía ninguna migración previa). Antes de aplicar: confirmar el número
-- contra el ledger (`list_migrations` / `supabase_migrations.schema_migrations`)
-- y contra las ramas abiertas -- MISMA regla que toda migración nueva (ver
-- migrations/MANIFEST.md). Confirmado contra el ledger de prod el 2026-09-13:
-- la última aplicada es la 227. No aplicar en paralelo con otra sesión que
-- esté tocando la cadena de SQL.
--
-- Estado verificado en prod el 2026-09-13 (hmuchlzmuqqxcldbzkgc):
--   storage.buckets: id='facturas', public=true, file_size_limit=NULL,
--     allowed_mime_types=NULL
--   storage.objects policies sobre bucket_id='facturas': UNA sola,
--     "Allow authenticated uploads" (INSERT, rol authenticated, sin mirar
--     el rol de negocio -- cualquier usuario logueado sube lo que quiera).
--
-- ModalCompra.tsx sube la foto de la factura del proveedor a este bucket y
-- manda getPublicUrl al webhook de n8n para el escaneo. Con el bucket
-- público, esa URL queda servible PARA SIEMPRE a cualquiera que la consiga
-- (no hace falta estar logueado), sin tope de tamaño ni de tipo de archivo,
-- y sin que nadie pueda borrar lo subido por error o por abuso.
--
-- Qué cambia:
--   1. Bucket privado, con tope de 8MB (MAX_IMAGE_SIZE en ModalCompra.tsx) y
--      sólo imágenes o PDF. El front pasa a pedir una signed URL de 5
--      minutos (createSignedUrl) en vez de getPublicUrl para mandarle la
--      imagen a n8n -- ver el commit del código que acompaña a esta
--      migración.
--   2. INSERT pasa de "cualquier authenticated" a es_encargado_o_admin():
--      mismo gate que el resto de la sección de compras (/compras es
--      isAdminOrEncargado en el router).
--   3. SELECT se da a es_encargado_o_admin() TAMBIEN -- no sólo a admin --
--      porque createSignedUrl corre bajo la RLS del usuario que acaba de
--      subir la foto: si sólo admin tuviera SELECT, un encargado (que sí
--      puede entrar a /compras y escanear) se quedaría sin poder generar la
--      signed URL de su propia subida y el escaneo se le rompería.
--   4. DELETE queda sólo para admin: nadie más tiene que poder borrar un
--      comprobante ya subido. Mismo patrón que compra_cargo_repartos (mig
--      192): "depósito lee y carga, admin corrige y borra".
--
-- Rollback: revertir a público vuelve a exponer cualquier factura ya subida
-- a quien tenga la URL (quedan con el mismo nombre de archivo en el bucket).
-- Si hace falta volver atrás:
--
--   BEGIN;
--   UPDATE storage.buckets SET public = true, file_size_limit = NULL, allowed_mime_types = NULL WHERE id = 'facturas';
--   DROP POLICY IF EXISTS "facturas_insert_encargado_o_admin" ON storage.objects;
--   DROP POLICY IF EXISTS "facturas_select_encargado_o_admin" ON storage.objects;
--   DROP POLICY IF EXISTS "facturas_delete_admin" ON storage.objects;
--   CREATE POLICY "Allow authenticated uploads" ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'facturas');
--   COMMIT;
-- =========================================================================

BEGIN;

UPDATE storage.buckets
SET
  public = false,
  file_size_limit = 8388608, -- 8 MB, mismo tope que MAX_IMAGE_SIZE en ModalCompra.tsx
  allowed_mime_types = ARRAY[
    'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'
  ]
WHERE id = 'facturas';

DROP POLICY IF EXISTS "Allow authenticated uploads" ON storage.objects;

CREATE POLICY "facturas_insert_encargado_o_admin"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'facturas' AND public.es_encargado_o_admin());

CREATE POLICY "facturas_select_encargado_o_admin"
ON storage.objects FOR SELECT
TO authenticated
USING (bucket_id = 'facturas' AND public.es_encargado_o_admin());

CREATE POLICY "facturas_delete_admin"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'facturas' AND public.es_admin());

DO $verif$
DECLARE
  v_bucket record;
  v_policy_count int;
BEGIN
  SELECT public, file_size_limit, allowed_mime_types INTO v_bucket
  FROM storage.buckets WHERE id = 'facturas';

  IF v_bucket.public IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'mig 228: el bucket facturas sigue publico.';
  END IF;
  IF v_bucket.file_size_limit IS DISTINCT FROM 8388608 THEN
    RAISE EXCEPTION 'mig 228: file_size_limit no quedo en 8MB.';
  END IF;
  IF v_bucket.allowed_mime_types IS NULL THEN
    RAISE EXCEPTION 'mig 228: allowed_mime_types sigue sin acotar.';
  END IF;

  SELECT count(*) INTO v_policy_count
  FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname IN (
      'facturas_insert_encargado_o_admin',
      'facturas_select_encargado_o_admin',
      'facturas_delete_admin'
    );
  IF v_policy_count <> 3 THEN
    RAISE EXCEPTION 'mig 228: faltan policies de facturas (esperaba 3, hay %).', v_policy_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'Allow authenticated uploads'
  ) THEN
    RAISE EXCEPTION 'mig 228: la policy vieja sigue viva.';
  END IF;
END
$verif$;

COMMIT;
