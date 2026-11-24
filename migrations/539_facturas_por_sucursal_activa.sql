-- =========================================================================
-- NNN · LAS FACTURAS ESCANEADAS, DE LA SUCURSAL ACTIVA
--       (plan #1603, ola 2, tanda 5, tarjeta C6: 1564-b7 de #1564, decisión del dueño D51)
--
-- Ensayo: scripts/test-facturas-sucursal-activa-ola2-1603.sql (sobre una base local hay que
-- armar antes storage.objects con scripts/ci/storage-minimo.sql). Se aplica en LF, en una sola
-- transacción o sentencia por sentencia.
--
-- D51: «Un usuario de dos sucursales ve las facturas escaneadas sólo de la sucursal en la que
-- está trabajando.» Las tres policies del bucket `facturas` (463) comparan el primer tramo del
-- path (`<sucursal_id>/…`) con TODAS las sucursales del usuario; pasan a compararlo con la
-- sucursal activa, current_sucursal_id().
--
-- DE QUÉ DEPENDE: current_sucursal_id() lee el header X-Sucursal-ID de request.headers. El front
-- lo manda en todo pedido, también a Storage (el fetch global de src/lib/supabase.ts), y
-- storage-api copia los headers del request a request.headers (src/http/plugins/db.ts y
-- src/internal/database/postgres/scope.ts del repo de supabase/storage). Si en producción no
-- llegara, falla CERRADO: sin header, current_sucursal_id() da la sucursal default del usuario,
-- y un admin o encargado de dos sucursales, parado en la que no es su default, no puede subir
-- ni abrir facturas (no ve nada de otra sucursal). Por eso se aplica con la prueba en el momento
-- y con el guion de deshacer a mano (vuelve a las tres policies de la 463).
--
-- No rompe ningún bundle del PWA: todos suben a `<sucursal activa>/…` con el header.
--
-- Sin storage.objects (la base local, el CI) no hace nada y lo avisa.
--
-- LOCKS: ACCESS EXCLUSIVE NOWAIT sobre storage.objects, al principio (lo pide DROP/CREATE POLICY).
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

DO $facturas$
DECLARE
  v_n integer;
BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE NOTICE 'no hay storage.objects (base local o CI): las policies de facturas no se tocan';
    RETURN;
  END IF;

  EXECUTE 'LOCK TABLE storage.objects IN ACCESS EXCLUSIVE MODE NOWAIT';

  -- Premisa: las tres de la 463, tal cual (comparan con las sucursales del usuario).
  SELECT count(*) INTO v_n
    FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname IN ('facturas_select_encargado_o_admin', 'facturas_insert_encargado_o_admin', 'facturas_delete_admin')
     AND COALESCE(qual, with_check) ~ 'usuario_sucursales';
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'premisa · esperaba las tres policies de facturas de la 463, hay %', v_n;
  END IF;

  -- El path es `<sucursal_id>/<uuid>.<ext>` (ModalCompra y escanear-factura/ruta.ts). Se compara
  -- como texto, sin cast: un path viejo (`facturas/…`) no tira error, sólo no matchea. Con un
  -- header de una sucursal que no es suya, current_sucursal_id() da NULL y no matchea nada.
  EXECUTE 'DROP POLICY facturas_select_encargado_o_admin ON storage.objects';
  EXECUTE 'DROP POLICY facturas_insert_encargado_o_admin ON storage.objects';
  EXECUTE 'DROP POLICY facturas_delete_admin ON storage.objects';

  EXECUTE $pol$
    CREATE POLICY facturas_select_encargado_o_admin ON storage.objects
      FOR SELECT TO authenticated
      USING (
        bucket_id = 'facturas'
        AND public.es_encargado_o_admin()
        AND (storage.foldername(name))[1] = public.current_sucursal_id()::text
      )
  $pol$;
  EXECUTE $pol$
    CREATE POLICY facturas_insert_encargado_o_admin ON storage.objects
      FOR INSERT TO authenticated
      WITH CHECK (
        bucket_id = 'facturas'
        AND public.es_encargado_o_admin()
        AND (storage.foldername(name))[1] = public.current_sucursal_id()::text
      )
  $pol$;
  EXECUTE $pol$
    CREATE POLICY facturas_delete_admin ON storage.objects
      FOR DELETE TO authenticated
      USING (
        bucket_id = 'facturas'
        AND public.es_admin()
        AND (storage.foldername(name))[1] = public.current_sucursal_id()::text
      )
  $pol$;

  -- Poscondición.
  SELECT count(*) INTO v_n
    FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname IN ('facturas_select_encargado_o_admin', 'facturas_insert_encargado_o_admin', 'facturas_delete_admin')
     AND COALESCE(qual, with_check) ~ 'current_sucursal_id\(\)'
     AND COALESCE(qual, with_check) !~ 'usuario_sucursales'
     AND roles = '{authenticated}';
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'poscondición · las policies de facturas no comparan con la sucursal activa (% de 3)', v_n;
  END IF;
END
$facturas$;

COMMIT;
