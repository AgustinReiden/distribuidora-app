-- 403b · El alta de un usuario no le cree al usuario (#1243, SEG-1).
--
-- handle_new_user() corre AFTER INSERT en auth.users y armaba el perfil con el
-- rol y la sucursal de raw_user_meta_data. Ese campo lo escribe el que se
-- registra: con el signup abierto, un POST /auth/v1/signup con la anon key y
-- data: {rol: 'admin', sucursal_id: 2} daba un admin activo de la sucursal 2.
-- Ahora el rol y la sucursal salen de raw_app_meta_data, que sólo escriben el
-- service_role (la admin API) y SQL.
--
-- Quién usaba el metadata para el alta: las altas por SQL o por la admin API que
-- traían rol y sucursal_id (transporte@crecertp.com el 24/04, guillermo@ el
-- 12/10). Las tres del 20/04 son la importación de TP Export (archive/062), que
-- copió el metadata del proyecto viejo. Ese camino sigue andando con los mismos
-- datos en app_metadata:
--   admin API: auth.admin.createUser({ email, password, email_confirm: true,
--                app_metadata:  { rol: 'preventista', sucursal_id: 2 },
--                user_metadata: { nombre: 'Juan' } })
--   SQL:       raw_app_meta_data = '{"provider":"email","providers":["email"],
--                                    "rol":"preventista","sucursal_id":"2"}'
-- Sin app_metadata (el alta desde el panel de Supabase) nace como hasta hoy:
-- preventista activo de la sucursal 1, y el admin lo ajusta desde /usuarios.
--
-- Lo que cambia para el que da de alta por app_metadata: un rol o una sucursal
-- que no existen frenan el alta con un error claro. Antes la sucursal inválida
-- caía en silencio en la 1. El usuario no puede llegar a esa rama: sólo la
-- recorre quien escribe app_metadata.
--
-- El nombre sigue saliendo de user_metadata: no da permisos. El gate
-- scripts/check-auth.mjs falla si un trigger de auth.users lee
-- raw_user_meta_data para otra cosa, o si el signup está abierto.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  -- Rol y sucursal: SÓLO de raw_app_meta_data (#1243). raw_user_meta_data lo
  -- escribe el propio usuario al registrarse.
  v_rol           TEXT := NULLIF(NEW.raw_app_meta_data->>'rol', '');
  v_meta_sucursal TEXT := NULLIF(NEW.raw_app_meta_data->>'sucursal_id', '');
  v_sucursal_id   BIGINT := 1;
BEGIN
  IF v_rol IS NOT NULL
     AND v_rol NOT IN ('admin', 'preventista', 'transportista', 'deposito', 'encargado') THEN
    RAISE EXCEPTION 'Alta de usuario: app_metadata.rol = % no es un rol de la app', v_rol;
  END IF;

  IF v_meta_sucursal IS NOT NULL THEN
    BEGIN
      v_sucursal_id := v_meta_sucursal::BIGINT;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      v_sucursal_id := NULL;
    END;
    IF v_sucursal_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id = v_sucursal_id) THEN
      RAISE EXCEPTION 'Alta de usuario: app_metadata.sucursal_id = % no es una sucursal', v_meta_sucursal;
    END IF;
  END IF;

  INSERT INTO public.perfiles (id, email, nombre, rol, activo)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nombre', split_part(NEW.email, '@', 1)),
    COALESCE(v_rol, 'preventista'),
    true
  )
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  VALUES (NEW.id, v_sucursal_id, 'mismo', true)
  ON CONFLICT (usuario_id, sucursal_id) DO NOTHING;

  RETURN NEW;
END;
$function$;

-- Función de trigger: no necesita EXECUTE para nadie de la app.
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;


-- Lo que lee el gate de Auth (scripts/check-auth.mjs): los triggers de
-- auth.users con el cuerpo de su función. La decisión (qué cuenta como leer el
-- metadata del usuario) la toma el script, que tiene tests.
CREATE OR REPLACE FUNCTION public.auditoria_auth()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT jsonb_build_object(
    'generado_at', now(),
    'triggers_auth_users', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'trigger',    t.tgname,
               'funcion',    t.tgfoid::regprocedure::text,
               'habilitado', t.tgenabled <> 'D',
               'cuerpo',     p.prosrc
             ) ORDER BY t.tgname)
        FROM pg_trigger t
        JOIN pg_proc p ON p.oid = t.tgfoid
       WHERE t.tgrelid = 'auth.users'::regclass
         AND NOT t.tgisinternal
    ), '[]'::jsonb)
  );
$function$;

-- Sólo la corre el gate, con la service_role: las tres mitades.
REVOKE EXECUTE ON FUNCTION public.auditoria_auth() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_auth() TO service_role;
