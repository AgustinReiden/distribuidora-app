-- 463 · Los helpers de rol miran `activo`, las facturas escaneadas son de su sucursal y nadie
--       edita su propio perfil (#1474, tarjeta 7 de #1477).
--
-- QUÉ PASABA
--   SEG-F-1 · Las tres policies del bucket `facturas` (mig 239) miraban sólo el rol. Un
--     encargado o admin de una sucursal listaba y leía las facturas de otra, con proveedores
--     y costos, y un admin borraba las de otra. Ningún gate miraba storage.objects.
--   SEG-F-2 · es_admin(), es_encargado_o_admin(), es_preventista(), es_transportista() y
--     current_sucursal_id() no miraban perfiles.activo. El ban de Auth (mig 403b) no invalida
--     un access token que ya está vivo: un usuario desactivado seguía entrando hasta que le
--     vencía el token.
--   SEG-F-3 · usuario_sucursales.rol admitía NULL, y _rol_en_sucursal() devolvía NULL para
--     ese miembro: los `NOT IN ('admin','encargado')` y `<> 'admin'` de los movimientos entre
--     sucursales lo dejaban pasar.
--   SEG-F-4 · perfiles_update_self dejaba a cualquiera cambiarse por REST el nombre, el email
--     y la zona: alcanzaba para ponerse el nombre de otro en los reportes de ventas.
--   SEG-F-6 · La guarda del último admin cubría sólo `activo = false`: el último admin podía
--     quitarse el rol (o un admin quitárselo al último), y la base quedaba sin nadie que
--     gestione usuarios.
--   SEG-F-7 · perfil_roles_write_admin dejaba a un admin darle un rol extra a un usuario que
--     no es de sus sucursales, o en una sucursal de la que el usuario no es miembro.
--
-- QUÉ CAMBIA
--   1 · Los cinco helpers devuelven false (o NULL, current_sucursal_id) para un perfil con
--       activo = false. El multi-rol queda igual (trampa 4 de CLAUDE.md): es_preventista()
--       sigue dando true a admin y encargado, es_transportista() a admin, y los dos siguen
--       cayendo a tiene_rol_extra(). tiene_rol_extra() no cambia: mira current_sucursal_id(),
--       que ya da NULL para el desactivado. La lista blanca de SEG-A
--       (auditoria_definer_sin_rol) pasa al md5 del cuerpo nuevo de current_sucursal_id().
--   2 · usuario_sucursales.rol pasa a NOT NULL con CHECK de dominio ('mismo' o un rol de
--       perfiles). _rol_en_sucursal() no cambia: con la columna así, para un miembro nunca da
--       NULL. Sigue dando NULL para quien NO es de esa sucursal, y eso es a propósito:
--       actualizar_pedido_items lo usa con COALESCE para caer al rol base. Los movimientos
--       verifican la pertenencia antes de mirar el rol.
--   3 · Se borra perfiles_update_self (decisión del dueño, 05/11: nadie edita su propio
--       perfil; no hay pantalla para eso). Lo edita un admin de todas sus sucursales, por
--       perfiles_update_admin (404). prevenir_autoescalada_perfil queda como segunda línea.
--   4 · La guarda del último admin (perfiles_guard_desactivacion) cubre también el cambio de
--       rol y el borrado: ningún UPDATE ni DELETE deja la base sin un admin activo. Toma un
--       advisory lock antes de contar, para que dos admins que se degradan a la vez no pasen
--       los dos.
--   5 · perfil_roles_write_admin pide además admin_abarca_sucursales_de(usuario_id), como
--       asignar_usuario_sucursal (#1291), y al escribir, que el usuario sea miembro de la
--       sucursal del rol extra.
--   6 · Las policies de `facturas` comparan el primer tramo del path (`<sucursal_id>/…`, como
--       ya suben el front y escanear-factura) con las sucursales del usuario. Los 19 archivos
--       viejos de `facturas/…` (escáner de n8n, ninguna compra los referencia) quedan sin
--       acceso desde la app, decisión del dueño (05/11); siguen en el bucket.
--   7 · auditoria_storage(), sólo de servidor, para el gate nuevo scripts/check-storage.mjs.
--
-- Ensayo: scripts/test-permisos-1474.sql.
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- md5(prosrc) de prod al 06/11. es_admin() lleva CRLF en prod.
DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.es_admin()',                      'e7ecd9318a961f2b2e019070bdc573a7'),
      ('public.es_encargado_o_admin()',          'ab922b24d382f82b359ddb4e7cfbaba8'),
      ('public.es_preventista()',                '4e0e53b6bcbf32928dd0f86a2e2129e7'),
      ('public.es_transportista()',              '2ed039537c887d14308983bbbf1066cf'),
      ('public.current_sucursal_id()',           '3a28cce558042e50d1f24eda2940c0d4'),
      ('public._rol_en_sucursal(uuid,bigint)',   '03b43259c9554937148aafb30b3579cb'),
      ('public.perfiles_guard_desactivacion()',  'b9f2aa3560955801bd9474bde8ea6ef8'),
      ('public.auditoria_definer_sin_rol()',     'bba1d0417fc2f41e529ab417583d5ef8')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) IS DISTINCT FROM r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma));
    END IF;
  END LOOP;

  -- Las policies que se reemplazan, por su huella (md5 de using|check).
  FOR r IN
    SELECT * FROM (VALUES
      ('storage', 'objects',      'facturas_select_encargado_o_admin', '0b32e18fa85f2446c5595f8b3c5309d6'),
      ('storage', 'objects',      'facturas_insert_encargado_o_admin', '68d4f8072bb9f33b8f200fb3002972b3'),
      ('storage', 'objects',      'facturas_delete_admin',             'd646f556379f8e5cb13bfe6518ff9b32'),
      ('public',  'perfiles',     'perfiles_update_self',              '2657526f2b2b4f74443519a2f7e3077b'),
      ('public',  'perfil_roles', 'perfil_roles_write_admin',          'fec6b2176bf3349fb845aed54ebddf9e')
    ) AS t(esquema, tabla, policy, huella)
  LOOP
    IF (SELECT md5(coalesce(qual, '') || '|' || coalesce(with_check, ''))
          FROM pg_policies
         WHERE schemaname = r.esquema AND tablename = r.tabla AND policyname = r.policy)
       IS DISTINCT FROM r.huella THEN
      RAISE EXCEPTION 'la policy %.% / % cambió en prod: rehacer el parche sobre la vigente',
        r.esquema, r.tabla, r.policy;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM public.usuario_sucursales WHERE rol IS NULL
               OR rol NOT IN ('mismo', 'admin', 'encargado', 'preventista', 'transportista', 'deposito')) THEN
    RAISE EXCEPTION 'hay filas de usuario_sucursales con rol NULL o fuera de dominio: resolverlas antes';
  END IF;

  -- Ningún cambio de esta migración deja la base sin un admin activo.
  IF NOT EXISTS (SELECT 1 FROM public.perfiles WHERE rol = 'admin' AND COALESCE(activo, true)) THEN
    RAISE EXCEPTION 'no hay ningún admin activo: no aplicar';
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · Los helpers de rol miran activo (SEG-F-2)
-- -------------------------------------------------------------------------
-- COALESCE(activo, true) como la guarda de desactivación y perfiles_sync_acceso_auth:
-- activo NULL es el default viejo, no una baja.

CREATE OR REPLACE FUNCTION public.es_admin()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Un desactivado no es admin aunque su token siga vivo (#1474).
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol = 'admin' AND COALESCE(activo, true)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.es_encargado_o_admin()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Un desactivado no es encargado ni admin aunque su token siga vivo (#1474).
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'encargado') AND COALESCE(activo, true)
  );
END;
$function$;

-- Trampa 4 de CLAUDE.md: es_preventista() incluye a admin y encargado, y cae al rol extra.
CREATE OR REPLACE FUNCTION public.es_preventista()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rol text;
BEGIN
  -- Un desactivado no tiene ningún rol, tampoco el extra (#1474).
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);
  IF v_rol IS NULL THEN
    RETURN false;
  END IF;
  IF v_rol IN ('admin', 'preventista', 'encargado') THEN
    RETURN true;
  END IF;
  RETURN public.tiene_rol_extra('preventista');
END;
$function$;

-- Trampa 4 de CLAUDE.md: es_transportista() incluye a admin, y cae al rol extra.
CREATE OR REPLACE FUNCTION public.es_transportista()
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rol text;
BEGIN
  -- Un desactivado no tiene ningún rol, tampoco el extra (#1474).
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true);
  IF v_rol IS NULL THEN
    RETURN false;
  END IF;
  IF v_rol IN ('admin', 'transportista') THEN
    RETURN true;
  END IF;
  RETURN public.tiene_rol_extra('transportista');
END;
$function$;

CREATE OR REPLACE FUNCTION public.current_sucursal_id()
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_header_val TEXT;
  v_sucursal_id BIGINT;
  v_authorized BOOLEAN;
BEGIN
  -- Un desactivado no tiene sucursal activa, aunque su token siga vivo (#1474): todas las
  -- policies y RPCs que acotan por current_sucursal_id() le quedan cerradas, también el
  -- rol extra de tiene_rol_extra().
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND COALESCE(activo, true)) THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_header_val := current_setting('request.headers', true)::json->>'x-sucursal-id';
  EXCEPTION WHEN others THEN
    v_header_val := NULL;
  END;

  IF v_header_val IS NOT NULL AND v_header_val <> '' THEN
    BEGIN
      v_sucursal_id := v_header_val::BIGINT;
    EXCEPTION WHEN others THEN
      v_sucursal_id := NULL;
    END;

    IF v_sucursal_id IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM usuario_sucursales
        WHERE usuario_id = auth.uid() AND sucursal_id = v_sucursal_id
      ) INTO v_authorized;

      IF v_authorized THEN
        RETURN v_sucursal_id;
      ELSE
        RETURN NULL;
      END IF;
    END IF;
  END IF;

  RETURN (
    SELECT sucursal_id FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND es_default = true
    LIMIT 1
  );
END;
$function$;

-- current_sucursal_id() no llama a un helper de rol: SEG-A (auditoria_definer_sin_rol) la
-- exime por firma + md5 del cuerpo, y con el cuerpo nuevo saldría en rojo. Se cambia sólo esa
-- entrada de la lista blanca, al md5 del cuerpo recién creado; el resto de la función queda
-- igual (la premisa de arriba fija su md5).
DO $lista_blanca$
DECLARE
  v_def   text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
  v_nuevo text := (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.current_sucursal_id()'::regprocedure);
BEGIN
  IF (length(v_def) - length(replace(v_def, '3a28cce558042e50d1f24eda2940c0d4', ''))) <> 32 THEN
    RAISE EXCEPTION 'auditoria_definer_sin_rol(): el md5 viejo de current_sucursal_id() no aparece una sola vez';
  END IF;
  EXECUTE replace(v_def, '3a28cce558042e50d1f24eda2940c0d4', v_nuevo);
END
$lista_blanca$;

-- -------------------------------------------------------------------------
-- 2 · usuario_sucursales.rol nunca es NULL (SEG-F-3)
-- -------------------------------------------------------------------------
ALTER TABLE public.usuario_sucursales ALTER COLUMN rol SET NOT NULL;
ALTER TABLE public.usuario_sucursales
  ADD CONSTRAINT usuario_sucursales_rol_check
  CHECK (rol IN ('mismo', 'admin', 'encargado', 'preventista', 'transportista', 'deposito'));

COMMENT ON FUNCTION public._rol_en_sucursal(uuid, bigint) IS
  'Rol de un usuario en una sucursal: el de usuario_sucursales, o el de perfiles si es ''mismo''. '
  'Para un miembro nunca es NULL (rol NOT NULL + CHECK, #1474). Es NULL si el usuario no es de esa '
  'sucursal: actualizar_pedido_items cae al rol base con COALESCE, y los movimientos verifican la '
  'pertenencia antes de mirar el rol.';

-- -------------------------------------------------------------------------
-- 3 · Nadie edita su propio perfil (SEG-F-4)
-- -------------------------------------------------------------------------
DROP POLICY perfiles_update_self ON public.perfiles;

-- -------------------------------------------------------------------------
-- 4 · Ningún cambio deja la base sin un admin activo (SEG-F-6)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.perfiles_guard_desactivacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_admins_activos INT;
  v_era_admin      BOOLEAN := COALESCE(OLD.rol, '') = 'admin' AND COALESCE(OLD.activo, true);
  v_sigue_admin    BOOLEAN := false;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF NOT COALESCE(NEW.activo, true) AND COALESCE(OLD.activo, true)
       AND auth.uid() IS NOT NULL AND NEW.id = auth.uid() THEN
      RAISE EXCEPTION 'No podes desactivar tu propio usuario: quedarias afuera de la app.';
    END IF;
    v_sigue_admin := COALESCE(NEW.rol, '') = 'admin' AND COALESCE(NEW.activo, true);
  END IF;

  IF v_era_admin AND NOT v_sigue_admin THEN
    -- Serializa a dos admins que se degradan a la vez: el segundo cuenta después del commit
    -- del primero (en READ COMMITTED cada sentencia toma su foto).
    PERFORM pg_advisory_xact_lock(hashtext('perfiles_ultimo_admin'));

    SELECT count(*) INTO v_admins_activos
    FROM public.perfiles
    WHERE rol = 'admin' AND COALESCE(activo, true) AND id <> OLD.id;

    IF v_admins_activos = 0 THEN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'No podes borrar al ultimo administrador activo: nadie podria gestionar los usuarios despues.';
      ELSIF NOT COALESCE(NEW.activo, true) THEN
        RAISE EXCEPTION 'No podes desactivar al ultimo administrador activo: nadie podria reactivarlo despues.';
      ELSE
        RAISE EXCEPTION 'No podes quitarle el rol de administrador al ultimo administrador activo: nadie podria gestionar los usuarios despues.';
      END IF;
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER trg_perfiles_guard_desactivacion ON public.perfiles;
CREATE TRIGGER trg_perfiles_guard_desactivacion
  BEFORE UPDATE OF activo, rol ON public.perfiles
  FOR EACH ROW
  WHEN (COALESCE(NEW.activo, true) IS DISTINCT FROM COALESCE(OLD.activo, true)
        OR NEW.rol IS DISTINCT FROM OLD.rol)
  EXECUTE FUNCTION public.perfiles_guard_desactivacion();

CREATE TRIGGER trg_perfiles_guard_borrado
  BEFORE DELETE ON public.perfiles
  FOR EACH ROW
  EXECUTE FUNCTION public.perfiles_guard_desactivacion();

-- -------------------------------------------------------------------------
-- 5 · El rol extra, a un usuario de las sucursales del admin (SEG-F-7)
-- -------------------------------------------------------------------------
DROP POLICY perfil_roles_write_admin ON public.perfil_roles;
CREATE POLICY perfil_roles_write_admin ON public.perfil_roles
  FOR ALL TO authenticated
  USING (
    es_admin()
    AND sucursal_id = current_sucursal_id()
    AND admin_abarca_sucursales_de(usuario_id)
  )
  WITH CHECK (
    es_admin()
    AND sucursal_id = current_sucursal_id()
    AND admin_abarca_sucursales_de(usuario_id)
    AND EXISTS (
      SELECT 1 FROM public.usuario_sucursales us
       WHERE us.usuario_id = perfil_roles.usuario_id
         AND us.sucursal_id = perfil_roles.sucursal_id
    )
  );

-- -------------------------------------------------------------------------
-- 6 · Las facturas escaneadas, de su sucursal (SEG-F-1)
-- -------------------------------------------------------------------------
-- El path es `<sucursal_id>/<uuid>.<ext>` (ModalCompra y escanear-factura/ruta.ts). Se
-- compara como texto, sin cast: un path viejo (`facturas/…`) no tira error, sólo no matchea.
DROP POLICY facturas_select_encargado_o_admin ON storage.objects;
DROP POLICY facturas_insert_encargado_o_admin ON storage.objects;
DROP POLICY facturas_delete_admin ON storage.objects;

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

-- -------------------------------------------------------------------------
-- 7 · El gate de storage (scripts/check-storage.mjs)
-- -------------------------------------------------------------------------
CREATE FUNCTION public.auditoria_storage()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT jsonb_build_object(
    'generado_at', now(),
    'politicas', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'policy',     p.policyname,
          'cmd',        p.cmd,
          'permissive', p.permissive,
          'roles',      to_jsonb(p.roles),
          'using',      p.qual,
          'check',      p.with_check
        ) ORDER BY p.policyname), '[]'::jsonb)
        FROM pg_policies p
       WHERE p.schemaname = 'storage' AND p.tablename = 'objects'),
    'buckets', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'public', b.public) ORDER BY b.id), '[]'::jsonb)
        FROM storage.buckets b)
  );
$function$;

REVOKE EXECUTE ON FUNCTION public.auditoria_storage() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_storage() TO service_role;

COMMIT;
