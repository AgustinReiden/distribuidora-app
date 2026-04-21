-- Migration 063: Admin RPCs to manage usuario_sucursales
--
-- Since new signups are NOT auto-assigned (see SinSucursalScreen on the
-- frontend), admins need a way to assign sucursales to users. These RPCs
-- are invoked from the SQL Editor for now (no admin UI yet).

CREATE OR REPLACE FUNCTION public.asignar_usuario_sucursal(
  p_usuario_id UUID,
  p_sucursal_id BIGINT,
  p_rol VARCHAR DEFAULT 'mismo',
  p_es_default BOOLEAN DEFAULT false
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede asignar sucursales');
  END IF;

  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  VALUES (p_usuario_id, p_sucursal_id, p_rol, p_es_default)
  ON CONFLICT (usuario_id, sucursal_id) DO UPDATE
    SET rol = EXCLUDED.rol,
        es_default = EXCLUDED.es_default;

  -- If this row was marked es_default, clear the flag on every other row
  -- for the same user so only one default exists at a time.
  IF p_es_default THEN
    UPDATE usuario_sucursales SET es_default = false
     WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.desasignar_usuario_sucursal(
  p_usuario_id UUID,
  p_sucursal_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede desasignar sucursales');
  END IF;

  DELETE FROM usuario_sucursales
   WHERE usuario_id = p_usuario_id AND sucursal_id = p_sucursal_id;

  RETURN jsonb_build_object('success', true);
END;
$$;
