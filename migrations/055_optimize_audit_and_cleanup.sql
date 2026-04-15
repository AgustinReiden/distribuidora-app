-- Migration 055: Optimize audit logging and cleanup
--
-- Fixes:
-- 1. audit_log_changes stores full JSONB for OLD and NEW on every update
--    Now stores only changed fields for UPDATE operations (saves ~80% storage)
-- 2. proveedores trigger uses wrong function (update_compras_updated_at)
-- 3. Drop duplicate English role functions (keep Spanish ones as canonical)

-- ============================================================
-- 1. Optimize audit_log_changes to store only changed fields
-- ============================================================
CREATE OR REPLACE FUNCTION public.audit_log_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT; v_key TEXT;
  v_old_changed JSONB; v_new_changed JSONB;
BEGIN
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_registro_id := OLD.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_registro_id := NEW.id::TEXT;
    v_old_data := NULL;
    v_new_data := to_jsonb(NEW);
  ELSE
    v_registro_id := NEW.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := to_jsonb(NEW);

    -- Find changed fields and store only those
    v_campos_modificados := ARRAY[]::TEXT[];
    v_old_changed := '{}'::JSONB;
    v_new_changed := '{}'::JSONB;

    FOR v_key IN SELECT jsonb_object_keys(v_new_data) LOOP
      IF v_old_data->v_key IS DISTINCT FROM v_new_data->v_key THEN
        v_campos_modificados := array_append(v_campos_modificados, v_key);
        v_old_changed := v_old_changed || jsonb_build_object(v_key, v_old_data->v_key);
        v_new_changed := v_new_changed || jsonb_build_object(v_key, v_new_data->v_key);
      END IF;
    END LOOP;

    -- Skip if nothing actually changed
    IF array_length(v_campos_modificados, 1) IS NULL OR array_length(v_campos_modificados, 1) = 0 THEN
      RETURN NEW;
    END IF;

    -- Store only the changed fields, not full row
    v_old_data := v_old_changed;
    v_new_data := v_new_changed;
  END IF;

  INSERT INTO public.audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados, usuario_id, usuario_email, usuario_rol)
  VALUES (TG_TABLE_NAME, v_registro_id, TG_OP, v_old_data, v_new_data, v_campos_modificados, v_usuario_id, v_usuario_email, v_usuario_rol);

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

-- ============================================================
-- 2. Fix proveedores trigger using wrong function
-- ============================================================
DROP TRIGGER IF EXISTS trigger_update_proveedores_timestamp ON public.proveedores;

CREATE OR REPLACE FUNCTION public.update_proveedores_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_update_proveedores_timestamp
  BEFORE UPDATE ON public.proveedores
  FOR EACH ROW
  EXECUTE FUNCTION update_proveedores_updated_at();

-- ============================================================
-- 3. English role functions (is_admin, is_preventista, is_transportista)
-- NOT dropped: 40+ RLS policies depend on them. Kept as aliases.
-- ============================================================
