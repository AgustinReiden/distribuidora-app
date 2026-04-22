-- 001_cliente_preventistas_nm.sql
--
-- Permite asignar uno o mas preventistas a un cliente (N-a-N).
-- Regla de visibilidad:
--   * rol 'preventista' solo ve clientes sin asignaciones O asignados a el.
--   * Resto de roles (admin, encargado, transportista, deposito, etc.) sigue
--     viendo todos los clientes de su sucursal.
-- La columna clientes.preventista_id queda como legado (deprecated) y se
-- migran sus valores a la nueva tabla. Se elimina en una migracion futura.

BEGIN;

-- 1. Tabla N-a-N
CREATE TABLE IF NOT EXISTS public.cliente_preventistas (
  cliente_id BIGINT NOT NULL REFERENCES public.clientes(id) ON DELETE CASCADE,
  preventista_id UUID NOT NULL REFERENCES public.perfiles(id) ON DELETE CASCADE,
  creado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (cliente_id, preventista_id)
);

COMMENT ON TABLE public.cliente_preventistas IS
  'Asignacion N-a-N entre clientes y preventistas. Si un cliente tiene filas aqui, solo esos preventistas (y admins/roles no-preventista) pueden verlo.';

CREATE INDEX IF NOT EXISTS idx_cliente_preventistas_prev
  ON public.cliente_preventistas(preventista_id);

CREATE INDEX IF NOT EXISTS idx_cliente_preventistas_cliente
  ON public.cliente_preventistas(cliente_id);

-- 2. Migrar asignaciones existentes desde clientes.preventista_id
INSERT INTO public.cliente_preventistas (cliente_id, preventista_id)
SELECT c.id, c.preventista_id
FROM public.clientes c
WHERE c.preventista_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- 3. Marcar la columna legado (deprecated) sin eliminarla todavia
COMMENT ON COLUMN public.clientes.preventista_id IS
  'DEPRECATED: usar public.cliente_preventistas. Mantenido por compatibilidad; se eliminara en una migracion futura.';

-- 4. RLS en cliente_preventistas
ALTER TABLE public.cliente_preventistas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cp_select" ON public.cliente_preventistas;
CREATE POLICY "cp_select"
  ON public.cliente_preventistas
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS "cp_insert" ON public.cliente_preventistas;
CREATE POLICY "cp_insert"
  ON public.cliente_preventistas
  FOR INSERT TO authenticated
  WITH CHECK (public.es_admin());

DROP POLICY IF EXISTS "cp_update" ON public.cliente_preventistas;
CREATE POLICY "cp_update"
  ON public.cliente_preventistas
  FOR UPDATE TO authenticated
  USING (public.es_admin())
  WITH CHECK (public.es_admin());

DROP POLICY IF EXISTS "cp_delete" ON public.cliente_preventistas;
CREATE POLICY "cp_delete"
  ON public.cliente_preventistas
  FOR DELETE TO authenticated
  USING (public.es_admin());

-- 5. Reemplazar policy de SELECT en clientes para filtrar preventistas
DROP POLICY IF EXISTS "mt_clientes_select" ON public.clientes;
CREATE POLICY "mt_clientes_select"
  ON public.clientes
  FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      -- Roles que no son preventista ven todos los clientes de su sucursal
      NOT EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol = 'preventista'
      )
      -- Preventistas: solo clientes sin asignaciones
      OR NOT EXISTS (
        SELECT 1 FROM public.cliente_preventistas cp
        WHERE cp.cliente_id = clientes.id
      )
      -- ...o clientes asignados a ellos
      OR EXISTS (
        SELECT 1 FROM public.cliente_preventistas cp
        WHERE cp.cliente_id = clientes.id AND cp.preventista_id = auth.uid()
      )
    )
  );

COMMIT;
