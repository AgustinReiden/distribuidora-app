-- =============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- =============================================================================
-- Este archivo contiene las políticas de seguridad a nivel de fila para
-- proteger los datos en la base de datos de Supabase.
--
-- IMPORTANTE: Ejecutar este script en el SQL Editor de Supabase
-- =============================================================================

-- =============================================================================
-- FUNCIÓN HELPER: Obtener rol del usuario actual
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS TEXT AS $$
  SELECT rol FROM public.perfiles WHERE id = auth.uid();
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol = 'admin'
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_preventista()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'preventista')
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_transportista()
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'transportista')
  );
$$ LANGUAGE SQL SECURITY DEFINER STABLE;

-- =============================================================================
-- TABLA: perfiles
-- =============================================================================

ALTER TABLE public.perfiles ENABLE ROW LEVEL SECURITY;

-- Todos pueden ver perfiles (necesario para mostrar nombres de usuarios)
CREATE POLICY "perfiles_select_all" ON public.perfiles
  FOR SELECT USING (true);

-- Solo admin puede insertar/actualizar/eliminar perfiles
CREATE POLICY "perfiles_insert_admin" ON public.perfiles
  FOR INSERT WITH CHECK (public.is_admin());

CREATE POLICY "perfiles_update_admin" ON public.perfiles
  FOR UPDATE USING (public.is_admin());

CREATE POLICY "perfiles_delete_admin" ON public.perfiles
  FOR DELETE USING (public.is_admin());

-- Usuarios pueden actualizar su propio perfil (campos limitados)
CREATE POLICY "perfiles_update_self" ON public.perfiles
  FOR UPDATE USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- =============================================================================
-- TABLA: clientes
-- =============================================================================

ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;

-- Admin y preventistas pueden ver todos los clientes
CREATE POLICY "clientes_select" ON public.clientes
  FOR SELECT USING (public.is_preventista());

-- Transportistas solo ven clientes de sus pedidos asignados
CREATE POLICY "clientes_select_transportista" ON public.clientes
  FOR SELECT USING (
    public.get_user_role() = 'transportista' AND
    EXISTS (
      SELECT 1 FROM public.pedidos
      WHERE pedidos.cliente_id = clientes.id
        AND pedidos.transportista_id = auth.uid()
    )
  );

-- Admin y preventistas pueden crear clientes
CREATE POLICY "clientes_insert" ON public.clientes
  FOR INSERT WITH CHECK (public.is_preventista());

-- Admin y preventistas pueden actualizar clientes
CREATE POLICY "clientes_update" ON public.clientes
  FOR UPDATE USING (public.is_preventista());

-- Solo admin puede eliminar clientes
CREATE POLICY "clientes_delete" ON public.clientes
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: productos
-- =============================================================================

ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;

-- Todos los usuarios autenticados pueden ver productos
CREATE POLICY "productos_select" ON public.productos
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- Admin y depósito pueden crear/actualizar productos
CREATE POLICY "productos_insert" ON public.productos
  FOR INSERT WITH CHECK (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

CREATE POLICY "productos_update" ON public.productos
  FOR UPDATE USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

-- Solo admin puede eliminar productos
CREATE POLICY "productos_delete" ON public.productos
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: pedidos
-- =============================================================================

ALTER TABLE public.pedidos ENABLE ROW LEVEL SECURITY;

-- Admin ve todos los pedidos
CREATE POLICY "pedidos_select_admin" ON public.pedidos
  FOR SELECT USING (public.is_admin());

-- Preventistas ven pedidos que crearon
CREATE POLICY "pedidos_select_preventista" ON public.pedidos
  FOR SELECT USING (
    public.get_user_role() = 'preventista' AND
    usuario_id = auth.uid()
  );

-- Transportistas ven pedidos asignados a ellos
CREATE POLICY "pedidos_select_transportista" ON public.pedidos
  FOR SELECT USING (
    public.get_user_role() = 'transportista' AND
    transportista_id = auth.uid()
  );

-- Depósito ve pedidos en preparación
CREATE POLICY "pedidos_select_deposito" ON public.pedidos
  FOR SELECT USING (
    public.get_user_role() = 'deposito' AND
    estado IN ('pendiente', 'en_preparacion', 'preparado')
  );

-- Admin y preventistas pueden crear pedidos
CREATE POLICY "pedidos_insert" ON public.pedidos
  FOR INSERT WITH CHECK (public.is_preventista());

-- Admin puede actualizar cualquier pedido
CREATE POLICY "pedidos_update_admin" ON public.pedidos
  FOR UPDATE USING (public.is_admin());

-- Preventistas pueden actualizar sus propios pedidos (no entregados)
CREATE POLICY "pedidos_update_preventista" ON public.pedidos
  FOR UPDATE USING (
    public.get_user_role() = 'preventista' AND
    usuario_id = auth.uid() AND
    estado NOT IN ('entregado', 'cancelado')
  );

-- Transportistas pueden actualizar estado de pedidos asignados
CREATE POLICY "pedidos_update_transportista" ON public.pedidos
  FOR UPDATE USING (
    public.get_user_role() = 'transportista' AND
    transportista_id = auth.uid()
  );

-- Depósito puede actualizar estado de preparación
CREATE POLICY "pedidos_update_deposito" ON public.pedidos
  FOR UPDATE USING (
    public.get_user_role() = 'deposito' AND
    estado IN ('pendiente', 'en_preparacion')
  );

-- Solo admin puede eliminar pedidos
CREATE POLICY "pedidos_delete" ON public.pedidos
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: pedido_items
-- =============================================================================

ALTER TABLE public.pedido_items ENABLE ROW LEVEL SECURITY;

-- Ver items si puedes ver el pedido
CREATE POLICY "pedido_items_select" ON public.pedido_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.pedidos
      WHERE pedidos.id = pedido_items.pedido_id
    )
  );

-- Crear items si puedes crear pedidos
CREATE POLICY "pedido_items_insert" ON public.pedido_items
  FOR INSERT WITH CHECK (public.is_preventista());

-- Actualizar items si puedes actualizar el pedido
CREATE POLICY "pedido_items_update" ON public.pedido_items
  FOR UPDATE USING (
    EXISTS (
      SELECT 1 FROM public.pedidos
      WHERE pedidos.id = pedido_items.pedido_id
        AND (public.is_admin() OR pedidos.usuario_id = auth.uid())
    )
  );

-- Eliminar items si eres admin
CREATE POLICY "pedido_items_delete" ON public.pedido_items
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: pagos
-- =============================================================================

ALTER TABLE public.pagos ENABLE ROW LEVEL SECURITY;

-- Admin ve todos los pagos
CREATE POLICY "pagos_select_admin" ON public.pagos
  FOR SELECT USING (public.is_admin());

-- Preventistas ven pagos que registraron
CREATE POLICY "pagos_select_preventista" ON public.pagos
  FOR SELECT USING (
    public.get_user_role() = 'preventista' AND
    usuario_id = auth.uid()
  );

-- Admin y preventistas pueden registrar pagos
CREATE POLICY "pagos_insert" ON public.pagos
  FOR INSERT WITH CHECK (public.is_preventista());

-- Solo admin puede actualizar/eliminar pagos
CREATE POLICY "pagos_update" ON public.pagos
  FOR UPDATE USING (public.is_admin());

CREATE POLICY "pagos_delete" ON public.pagos
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: compras
-- =============================================================================

ALTER TABLE public.compras ENABLE ROW LEVEL SECURITY;

-- Admin y depósito pueden ver compras
CREATE POLICY "compras_select" ON public.compras
  FOR SELECT USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

-- Admin y depósito pueden crear/actualizar compras
CREATE POLICY "compras_insert" ON public.compras
  FOR INSERT WITH CHECK (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

CREATE POLICY "compras_update" ON public.compras
  FOR UPDATE USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

-- Solo admin puede eliminar compras
CREATE POLICY "compras_delete" ON public.compras
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: compra_items
-- =============================================================================

ALTER TABLE public.compra_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "compra_items_select" ON public.compra_items
  FOR SELECT USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

CREATE POLICY "compra_items_insert" ON public.compra_items
  FOR INSERT WITH CHECK (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

CREATE POLICY "compra_items_update" ON public.compra_items
  FOR UPDATE USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

CREATE POLICY "compra_items_delete" ON public.compra_items
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: proveedores
-- =============================================================================

ALTER TABLE public.proveedores ENABLE ROW LEVEL SECURITY;

-- Admin y depósito pueden ver proveedores
CREATE POLICY "proveedores_select" ON public.proveedores
  FOR SELECT USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

-- Admin y depósito pueden gestionar proveedores
CREATE POLICY "proveedores_insert" ON public.proveedores
  FOR INSERT WITH CHECK (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

CREATE POLICY "proveedores_update" ON public.proveedores
  FOR UPDATE USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

CREATE POLICY "proveedores_delete" ON public.proveedores
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: mermas
-- =============================================================================

ALTER TABLE public.mermas ENABLE ROW LEVEL SECURITY;

-- Admin y depósito pueden ver mermas
CREATE POLICY "mermas_select" ON public.mermas
  FOR SELECT USING (
    public.is_admin() OR public.get_user_role() = 'deposito'
  );

-- Admin, depósito y transportistas pueden registrar mermas
CREATE POLICY "mermas_insert" ON public.mermas
  FOR INSERT WITH CHECK (
    public.is_admin() OR
    public.get_user_role() = 'deposito' OR
    public.get_user_role() = 'transportista'
  );

-- Solo admin puede actualizar/eliminar mermas
CREATE POLICY "mermas_update" ON public.mermas
  FOR UPDATE USING (public.is_admin());

CREATE POLICY "mermas_delete" ON public.mermas
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: recorridos
-- =============================================================================

ALTER TABLE public.recorridos ENABLE ROW LEVEL SECURITY;

-- Admin ve todos los recorridos
CREATE POLICY "recorridos_select_admin" ON public.recorridos
  FOR SELECT USING (public.is_admin());

-- Transportistas ven sus propios recorridos
CREATE POLICY "recorridos_select_transportista" ON public.recorridos
  FOR SELECT USING (
    public.get_user_role() = 'transportista' AND
    transportista_id = auth.uid()
  );

-- Admin puede crear/actualizar recorridos
CREATE POLICY "recorridos_insert" ON public.recorridos
  FOR INSERT WITH CHECK (public.is_admin());

CREATE POLICY "recorridos_update" ON public.recorridos
  FOR UPDATE USING (
    public.is_admin() OR
    (public.get_user_role() = 'transportista' AND transportista_id = auth.uid())
  );

CREATE POLICY "recorridos_delete" ON public.recorridos
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: rendiciones
-- =============================================================================

ALTER TABLE public.rendiciones ENABLE ROW LEVEL SECURITY;

-- Admin ve todas las rendiciones
CREATE POLICY "rendiciones_select_admin" ON public.rendiciones
  FOR SELECT USING (public.is_admin());

-- Transportistas ven sus propias rendiciones
CREATE POLICY "rendiciones_select_transportista" ON public.rendiciones
  FOR SELECT USING (
    public.get_user_role() = 'transportista' AND
    transportista_id = auth.uid()
  );

-- Transportistas y admin pueden crear rendiciones
CREATE POLICY "rendiciones_insert" ON public.rendiciones
  FOR INSERT WITH CHECK (
    public.is_admin() OR
    (public.get_user_role() = 'transportista' AND transportista_id = auth.uid())
  );

-- Transportistas pueden actualizar sus rendiciones pendientes, admin todas
CREATE POLICY "rendiciones_update" ON public.rendiciones
  FOR UPDATE USING (
    public.is_admin() OR
    (public.get_user_role() = 'transportista' AND
     transportista_id = auth.uid() AND
     estado IN ('pendiente', 'con_observaciones'))
  );

CREATE POLICY "rendiciones_delete" ON public.rendiciones
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: salvedades
-- =============================================================================

ALTER TABLE public.salvedades ENABLE ROW LEVEL SECURITY;

-- Admin ve todas las salvedades
CREATE POLICY "salvedades_select_admin" ON public.salvedades
  FOR SELECT USING (public.is_admin());

-- Transportistas ven salvedades de sus pedidos
CREATE POLICY "salvedades_select_transportista" ON public.salvedades
  FOR SELECT USING (
    public.get_user_role() = 'transportista' AND
    EXISTS (
      SELECT 1 FROM public.pedidos
      WHERE pedidos.id = salvedades.pedido_id
        AND pedidos.transportista_id = auth.uid()
    )
  );

-- Transportistas y admin pueden crear salvedades
CREATE POLICY "salvedades_insert" ON public.salvedades
  FOR INSERT WITH CHECK (
    public.is_admin() OR public.get_user_role() = 'transportista'
  );

-- Solo admin puede resolver/actualizar salvedades
CREATE POLICY "salvedades_update" ON public.salvedades
  FOR UPDATE USING (public.is_admin());

CREATE POLICY "salvedades_delete" ON public.salvedades
  FOR DELETE USING (public.is_admin());

-- =============================================================================
-- TABLA: historial_pedidos (auditoría)
-- =============================================================================

ALTER TABLE public.historial_pedidos ENABLE ROW LEVEL SECURITY;

-- Todos pueden ver historial (es auditoría)
CREATE POLICY "historial_pedidos_select" ON public.historial_pedidos
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- Sistema inserta automáticamente (trigger), permitir a usuarios autenticados
CREATE POLICY "historial_pedidos_insert" ON public.historial_pedidos
  FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- Nadie puede modificar ni eliminar historial
-- (No se crean policies de UPDATE/DELETE)

-- =============================================================================
-- GRANT USAGE
-- =============================================================================

GRANT USAGE ON SCHEMA public TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
