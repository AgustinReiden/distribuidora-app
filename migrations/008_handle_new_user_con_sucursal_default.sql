-- Mejora handle_new_user(): además de crear el perfil, asigna automáticamente
-- al usuario nuevo a la sucursal default (1 = Tucuman, salvo override por
-- raw_user_meta_data->>'sucursal_id'). Antes solo se creaba el perfil y había
-- que insertar manualmente en usuario_sucursales — un usuario sin entrada en
-- esa tabla no puede usar la app porque SucursalContext.tsx queda en estado
-- "Usuario sin sucursales asignadas".
--
-- Comportamiento:
--   - Si raw_user_meta_data trae 'sucursal_id' válido (existe en sucursales),
--     usa ese.
--   - Si no, default a sucursal 1 (Tucuman).
--   - es_default = true para que SucursalContext la elija al login.
--   - rol en usuario_sucursales = 'mismo' (resuelve al rol global del perfil).
--
-- Idempotente: ON CONFLICT DO NOTHING evita errores si el trigger se re-dispara.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_meta_sucursal TEXT;
BEGIN
  -- 1) Crear el perfil (idéntico a la versión previa)
  INSERT INTO public.perfiles (id, email, nombre, rol, activo)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nombre', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'rol', 'preventista'),
    true
  )
  ON CONFLICT (id) DO NOTHING;

  -- 2) Resolver sucursal: meta override > default 1 (Tucuman)
  v_meta_sucursal := NEW.raw_user_meta_data->>'sucursal_id';
  IF v_meta_sucursal IS NOT NULL AND v_meta_sucursal <> '' THEN
    BEGIN
      v_sucursal_id := v_meta_sucursal::BIGINT;
      -- Validar que la sucursal exista; si no, fallback a 1
      IF NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id = v_sucursal_id) THEN
        v_sucursal_id := 1;
      END IF;
    EXCEPTION WHEN others THEN
      v_sucursal_id := 1;
    END;
  ELSE
    v_sucursal_id := 1;
  END IF;

  -- 3) Asignar a la sucursal con es_default=true
  INSERT INTO public.usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  VALUES (NEW.id, v_sucursal_id, 'mismo', true)
  ON CONFLICT (usuario_id, sucursal_id) DO NOTHING;

  RETURN NEW;
END;
$$;

-- El trigger ya existe (on_auth_user_created en auth.users); solo se reemplaza
-- la función. No hace falta DROP/CREATE TRIGGER.
