-- Migration 064: audit_log_changes must tolerate global (non-tenant) tables
--
-- Context: Migration 060 hardened the trigger to RAISE EXCEPTION when
-- sucursal_id cannot be resolved — correct for tenant-scoped tables, but
-- a regression for GLOBAL tables (perfiles, sucursales, usuario_sucursales,
-- etc.) whose rows legitimately have no sucursal_id column at all. That
-- broke `handle_new_user`: signing up a new auth user inserts into
-- public.perfiles, which fires this trigger, which raised because
-- current_sucursal_id() was NULL for the Supabase Auth internal connection.
--
-- Fix: detect whether the audited table has a sucursal_id column via
-- information_schema. If it does and we still couldn't resolve one, fail
-- (the original H7 fail-fast). If it doesn't, log with NULL sucursal_id —
-- global-table audit rows are intentionally untenanted.
--
-- Also relaxes audit_logs.sucursal_id to be nullable to accommodate the
-- global-table rows. Tenant-scoped rows remain enforced by the trigger's
-- fail-fast path.
--
-- This migration was originally applied as an emergency hotfix directly to
-- production while running the TP Export import preparation; it is recorded
-- here so the migration chain stays reproducible from a clean DB.

ALTER TABLE public.audit_logs ALTER COLUMN sucursal_id DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.audit_log_changes()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT; v_key TEXT;
  v_old_changed JSONB; v_new_changed JSONB;
  v_sucursal_id BIGINT;
  v_has_sucursal_col BOOLEAN;
BEGIN
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;

  -- Does the audited table have a sucursal_id column?
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = TG_TABLE_SCHEMA
       AND table_name   = TG_TABLE_NAME
       AND column_name  = 'sucursal_id'
  ) INTO v_has_sucursal_col;

  IF TG_OP = 'DELETE' THEN
    v_registro_id := OLD.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := NULL;
    v_sucursal_id := COALESCE((to_jsonb(OLD)->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSIF TG_OP = 'INSERT' THEN
    v_registro_id := NEW.id::TEXT;
    v_old_data := NULL;
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE((to_jsonb(NEW)->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSE
    v_registro_id := NEW.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE(
      (to_jsonb(NEW)->>'sucursal_id')::BIGINT,
      (to_jsonb(OLD)->>'sucursal_id')::BIGINT,
      current_sucursal_id()
    );

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
    IF array_length(v_campos_modificados, 1) IS NULL OR array_length(v_campos_modificados, 1) = 0 THEN
      RETURN NEW;
    END IF;
    v_old_data := v_old_changed;
    v_new_data := v_new_changed;
  END IF;

  -- FIX H7 (refined): only fail when the table HAS sucursal_id but we
  -- couldn't resolve one. For global tables (perfiles, sucursales, etc.)
  -- log with NULL sucursal_id - those rows are not tenant-scoped.
  IF v_has_sucursal_col AND v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'audit_log_changes: cannot determine sucursal_id for tenant-scoped table %', TG_TABLE_NAME;
  END IF;

  INSERT INTO public.audit_logs (
    tabla, registro_id, accion, old_data, new_data, campos_modificados,
    usuario_id, usuario_email, usuario_rol, sucursal_id
  ) VALUES (
    TG_TABLE_NAME, v_registro_id, TG_OP, v_old_data, v_new_data, v_campos_modificados,
    v_usuario_id, v_usuario_email, v_usuario_rol, v_sucursal_id
  );

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;
