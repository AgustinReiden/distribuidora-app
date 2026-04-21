-- Migration 061: Session-scoped tenant resolver via X-Sucursal-ID header
--
-- Replaces the DB-state-based current_sucursal_id() (which reads
-- usuario_sucursales.es_default) with a header-based resolver. This
-- eliminates the multi-tab race where changing sucursal in one tab
-- moved the active tenant globally for the same user (H10).
--
-- The client sends X-Sucursal-ID on every PostgREST request. PostgREST
-- exposes it via current_setting('request.headers')::json. We parse it,
-- validate against usuario_sucursales (authorization), and return the
-- BIGINT. If header is missing, we fall back to es_default (backward
-- compat for calls that don't set the header: Edge Functions, direct
-- psql, triggers running outside a PostgREST request, etc.).

CREATE OR REPLACE FUNCTION current_sucursal_id()
RETURNS BIGINT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_header_val TEXT;
  v_sucursal_id BIGINT;
  v_authorized BOOLEAN;
BEGIN
  -- Try header first (session-scoped, per-tab)
  BEGIN
    v_header_val := current_setting('request.headers', true)::json->>'x-sucursal-id';
  EXCEPTION WHEN others THEN
    v_header_val := NULL;
  END;

  IF v_header_val IS NOT NULL AND v_header_val <> '' THEN
    BEGIN
      v_sucursal_id := v_header_val::BIGINT;
    EXCEPTION WHEN others THEN
      -- Malformed header value -> treat as missing
      v_sucursal_id := NULL;
    END;

    IF v_sucursal_id IS NOT NULL THEN
      -- Authorization check: user must have a row in usuario_sucursales
      SELECT EXISTS (
        SELECT 1 FROM usuario_sucursales
        WHERE usuario_id = auth.uid() AND sucursal_id = v_sucursal_id
      ) INTO v_authorized;

      IF v_authorized THEN
        RETURN v_sucursal_id;
      ELSE
        -- Header present but user lacks access -> treat as NULL (RPCs will error)
        RETURN NULL;
      END IF;
    END IF;
  END IF;

  -- Fallback: es_default (legacy path, e.g. triggers without request context)
  RETURN (
    SELECT sucursal_id FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND es_default = true
    LIMIT 1
  );
END;
$$;

-- cambiar_sucursal() remains from migration 057 as a best-effort
-- default updater -- switching is now purely client-side (set the header),
-- but we keep the es_default mutation so offline/Edge/trigger paths still
-- resolve correctly. No redefinition needed here.
