-- =============================================================================
-- AUDIT LOGS - Sistema de Auditoría Inmutable
-- =============================================================================
-- Este sistema registra todos los cambios en tablas críticas para:
-- - Detectar fraude (modificación de pedidos, precios, stock)
-- - Compliance y trazabilidad
-- - Investigación de incidentes
--
-- IMPORTANTE: Esta tabla es INMUTABLE - no se puede UPDATE ni DELETE
-- =============================================================================

-- =============================================================================
-- TABLA: audit_logs
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Identificación del registro
  tabla TEXT NOT NULL,
  registro_id TEXT NOT NULL,

  -- Tipo de operación
  accion TEXT NOT NULL CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),

  -- Datos del cambio
  old_data JSONB,
  new_data JSONB,
  campos_modificados TEXT[], -- Lista de campos que cambiaron

  -- Quién y cuándo
  usuario_id UUID REFERENCES auth.users(id),
  usuario_email TEXT,
  usuario_rol TEXT,

  -- Contexto adicional
  ip_address INET,
  user_agent TEXT,
  session_id TEXT,

  -- Timestamp inmutable
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índices para búsquedas eficientes
CREATE INDEX IF NOT EXISTS idx_audit_logs_tabla ON public.audit_logs(tabla);
CREATE INDEX IF NOT EXISTS idx_audit_logs_registro_id ON public.audit_logs(registro_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_usuario_id ON public.audit_logs(usuario_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_accion ON public.audit_logs(accion);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_logs_tabla_registro ON public.audit_logs(tabla, registro_id);

-- Comentarios
COMMENT ON TABLE public.audit_logs IS 'Registro inmutable de auditoría para detectar fraude y mantener trazabilidad';
COMMENT ON COLUMN public.audit_logs.old_data IS 'Estado anterior del registro (NULL para INSERT)';
COMMENT ON COLUMN public.audit_logs.new_data IS 'Estado nuevo del registro (NULL para DELETE)';
COMMENT ON COLUMN public.audit_logs.campos_modificados IS 'Lista de campos que fueron modificados (solo para UPDATE)';

-- =============================================================================
-- RLS: Solo INSERT permitido - NADIE puede UPDATE o DELETE
-- =============================================================================

ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;

-- Cualquier usuario autenticado puede ver los logs (admin puede filtrar en frontend)
DROP POLICY IF EXISTS "audit_logs_select" ON public.audit_logs;
CREATE POLICY "audit_logs_select" ON public.audit_logs
  FOR SELECT USING (
    -- Solo admin puede ver todos los logs
    EXISTS (
      SELECT 1 FROM public.perfiles
      WHERE id = auth.uid() AND rol = 'admin'
    )
  );

-- Permitir INSERT desde triggers (SECURITY DEFINER)
DROP POLICY IF EXISTS "audit_logs_insert" ON public.audit_logs;
CREATE POLICY "audit_logs_insert" ON public.audit_logs
  FOR INSERT WITH CHECK (true);

-- NO HAY POLICY DE UPDATE - Imposible modificar
-- NO HAY POLICY DE DELETE - Imposible eliminar

-- =============================================================================
-- FUNCIÓN: Registrar cambio en audit_logs
-- =============================================================================

CREATE OR REPLACE FUNCTION public.audit_log_changes()
RETURNS TRIGGER AS $$
DECLARE
  v_old_data JSONB;
  v_new_data JSONB;
  v_campos_modificados TEXT[];
  v_usuario_id UUID;
  v_usuario_email TEXT;
  v_usuario_rol TEXT;
  v_registro_id TEXT;
  v_key TEXT;
BEGIN
  -- Obtener información del usuario actual
  v_usuario_id := auth.uid();

  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;

  -- Determinar el ID del registro
  IF TG_OP = 'DELETE' THEN
    v_registro_id := OLD.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_registro_id := NEW.id::TEXT;
    v_old_data := NULL;
    v_new_data := to_jsonb(NEW);
  ELSE -- UPDATE
    v_registro_id := NEW.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := to_jsonb(NEW);

    -- Calcular campos modificados
    v_campos_modificados := ARRAY[]::TEXT[];
    FOR v_key IN SELECT jsonb_object_keys(v_new_data)
    LOOP
      IF v_old_data->v_key IS DISTINCT FROM v_new_data->v_key THEN
        v_campos_modificados := array_append(v_campos_modificados, v_key);
      END IF;
    END LOOP;

    -- Si no hay cambios reales, no registrar
    IF array_length(v_campos_modificados, 1) IS NULL OR array_length(v_campos_modificados, 1) = 0 THEN
      IF TG_OP = 'DELETE' THEN
        RETURN OLD;
      ELSE
        RETURN NEW;
      END IF;
    END IF;
  END IF;

  -- Insertar registro de auditoría
  INSERT INTO public.audit_logs (
    tabla,
    registro_id,
    accion,
    old_data,
    new_data,
    campos_modificados,
    usuario_id,
    usuario_email,
    usuario_rol
  ) VALUES (
    TG_TABLE_NAME,
    v_registro_id,
    TG_OP,
    v_old_data,
    v_new_data,
    v_campos_modificados,
    v_usuario_id,
    v_usuario_email,
    v_usuario_rol
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  ELSE
    RETURN NEW;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- TRIGGERS: Tablas críticas a auditar
-- =============================================================================

-- PEDIDOS (crítico para fraude)
DROP TRIGGER IF EXISTS audit_pedidos ON public.pedidos;
CREATE TRIGGER audit_pedidos
  AFTER INSERT OR UPDATE OR DELETE ON public.pedidos
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- PEDIDO_ITEMS (cambios en cantidades/precios)
DROP TRIGGER IF EXISTS audit_pedido_items ON public.pedido_items;
CREATE TRIGGER audit_pedido_items
  AFTER INSERT OR UPDATE OR DELETE ON public.pedido_items
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- PRODUCTOS (cambios de precio/stock)
DROP TRIGGER IF EXISTS audit_productos ON public.productos;
CREATE TRIGGER audit_productos
  AFTER INSERT OR UPDATE OR DELETE ON public.productos
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- CLIENTES (datos sensibles)
DROP TRIGGER IF EXISTS audit_clientes ON public.clientes;
CREATE TRIGGER audit_clientes
  AFTER INSERT OR UPDATE OR DELETE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- PAGOS (crítico para fraude)
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'pagos') THEN
    DROP TRIGGER IF EXISTS audit_pagos ON public.pagos;
    CREATE TRIGGER audit_pagos
      AFTER INSERT OR UPDATE OR DELETE ON public.pagos
      FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();
    RAISE NOTICE 'Trigger audit_pagos creado';
  END IF;
END $$;

-- PERFILES (cambios de rol)
DROP TRIGGER IF EXISTS audit_perfiles ON public.perfiles;
CREATE TRIGGER audit_perfiles
  AFTER INSERT OR UPDATE OR DELETE ON public.perfiles
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- COMPRAS (para control de inventario)
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'compras') THEN
    DROP TRIGGER IF EXISTS audit_compras ON public.compras;
    CREATE TRIGGER audit_compras
      AFTER INSERT OR UPDATE OR DELETE ON public.compras
      FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();
    RAISE NOTICE 'Trigger audit_compras creado';
  END IF;
END $$;

-- RENDICIONES (dinero del transportista)
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = 'rendiciones') THEN
    DROP TRIGGER IF EXISTS audit_rendiciones ON public.rendiciones;
    CREATE TRIGGER audit_rendiciones
      AFTER INSERT OR UPDATE OR DELETE ON public.rendiciones
      FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();
    RAISE NOTICE 'Trigger audit_rendiciones creado';
  END IF;
END $$;

-- =============================================================================
-- FUNCIÓN: Consultar historial de un registro específico
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_audit_history(
  p_tabla TEXT,
  p_registro_id TEXT,
  p_limit INTEGER DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  accion TEXT,
  old_data JSONB,
  new_data JSONB,
  campos_modificados TEXT[],
  usuario_email TEXT,
  usuario_rol TEXT,
  created_at TIMESTAMPTZ
) AS $$
BEGIN
  -- Solo admin puede consultar
  IF NOT EXISTS (SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: solo administradores pueden ver auditoría';
  END IF;

  RETURN QUERY
  SELECT
    al.id,
    al.accion,
    al.old_data,
    al.new_data,
    al.campos_modificados,
    al.usuario_email,
    al.usuario_rol,
    al.created_at
  FROM public.audit_logs al
  WHERE al.tabla = p_tabla AND al.registro_id = p_registro_id
  ORDER BY al.created_at DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- FUNCIÓN: Resumen de actividad sospechosa
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_suspicious_activity(
  p_days INTEGER DEFAULT 7
)
RETURNS TABLE (
  usuario_email TEXT,
  usuario_rol TEXT,
  tabla TEXT,
  total_cambios BIGINT,
  deletes_count BIGINT,
  updates_precio_count BIGINT
) AS $$
BEGIN
  -- Solo admin puede consultar
  IF NOT EXISTS (SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: solo administradores pueden ver actividad sospechosa';
  END IF;

  RETURN QUERY
  SELECT
    al.usuario_email,
    al.usuario_rol,
    al.tabla,
    COUNT(*) as total_cambios,
    COUNT(*) FILTER (WHERE al.accion = 'DELETE') as deletes_count,
    COUNT(*) FILTER (
      WHERE al.accion = 'UPDATE'
      AND (
        'precio' = ANY(al.campos_modificados) OR
        'precio_unitario' = ANY(al.campos_modificados) OR
        'total' = ANY(al.campos_modificados) OR
        'monto' = ANY(al.campos_modificados)
      )
    ) as updates_precio_count
  FROM public.audit_logs al
  WHERE al.created_at > NOW() - (p_days || ' days')::INTERVAL
  GROUP BY al.usuario_email, al.usuario_rol, al.tabla
  HAVING
    COUNT(*) FILTER (WHERE al.accion = 'DELETE') > 5 OR
    COUNT(*) FILTER (
      WHERE al.accion = 'UPDATE'
      AND (
        'precio' = ANY(al.campos_modificados) OR
        'precio_unitario' = ANY(al.campos_modificados) OR
        'total' = ANY(al.campos_modificados)
      )
    ) > 10
  ORDER BY total_cambios DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =============================================================================
-- GRANT PERMISSIONS
-- =============================================================================

GRANT SELECT ON public.audit_logs TO authenticated;
GRANT INSERT ON public.audit_logs TO authenticated;
-- NO GRANT UPDATE
-- NO GRANT DELETE

GRANT EXECUTE ON FUNCTION public.get_audit_history TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_suspicious_activity TO authenticated;

-- =============================================================================
-- FIN DE MIGRACIÓN - AUDIT LOGS
-- =============================================================================

DO $$
BEGIN
  RAISE NOTICE '===========================================';
  RAISE NOTICE 'Audit Logs configurado exitosamente';
  RAISE NOTICE 'Tablas auditadas: pedidos, pedido_items, productos, clientes, perfiles';
  RAISE NOTICE 'Esta tabla es INMUTABLE - no se puede modificar ni eliminar';
  RAISE NOTICE '===========================================';
END $$;
