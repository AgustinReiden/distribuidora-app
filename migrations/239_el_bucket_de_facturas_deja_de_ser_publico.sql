-- El bucket "facturas" deja de ser público
--
-- Este archivo fija en SQL una config que hasta ahora sólo vivía armada a mano
-- en el dashboard de Supabase (storage.buckets no tenía ninguna migración
-- previa).
--
-- NACIO COMO 228 Y SE APLICO COMO 239. Se escribió el 2026-09-13 confirmando
-- contra el ledger que la última aplicada era la 227 -- y se mergeó SIN
-- aplicar, con `[SQL - NO APLICADA]` en el mensaje del commit. Para cuando se
-- aplicó, el 228 ya se lo había llevado `228_cada_uno_ve_lo_de_su_sucursal`
-- (ledger 20260913212201, ese mismo día a las 21:22) y la cadena iba por la
-- 238. Es la trampa 3 de CLAUDE.md en vivo: **el número se reserva aplicando,
-- no escribiendo el archivo**, así que un archivo que espera dos días en
-- `main` llega con el número ocupado. El drift-check
-- (`scripts/check-migrations.mjs`) fue el que lo cazó: venía rojo en `main`
-- desde el 2026-09-14 con "archivo en migrations/ pero NO aplicado en prod".
--
-- La mitad del código YA estaba mergeada y en producción: `ModalCompra.tsx`
-- usa `createSignedUrl(fileName, 300)` desde el 2026-09-13. Las signed URLs
-- funcionan igual sobre un bucket público, así que nada se rompió -- pero el
-- beneficio de seguridad no existió hasta esta migración. El front estuvo dos
-- días listo para un bucket privado que seguía siendo público.
--
-- Estado verificado en prod el 2026-09-13 y RE-verificado sin cambios el
-- 2026-09-15, justo antes de aplicar (hmuchlzmuqqxcldbzkgc):
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
    RAISE EXCEPTION 'mig 239: el bucket facturas sigue publico.';
  END IF;
  IF v_bucket.file_size_limit IS DISTINCT FROM 8388608 THEN
    RAISE EXCEPTION 'mig 239: file_size_limit no quedo en 8MB.';
  END IF;
  IF v_bucket.allowed_mime_types IS NULL THEN
    RAISE EXCEPTION 'mig 239: allowed_mime_types sigue sin acotar.';
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
    RAISE EXCEPTION 'mig 239: faltan policies de facturas (esperaba 3, hay %).', v_policy_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'Allow authenticated uploads'
  ) THEN
    RAISE EXCEPTION 'mig 239: la policy vieja sigue viva.';
  END IF;
END
$verif$;

COMMIT;
