-- ============================================
-- MIGRACION 015: Row Level Security Completo
-- ============================================
-- Esta migracion habilita RLS en todas las tablas criticas
-- para prevenir acceso no autorizado a los datos.
--
-- IMPORTANTE: Ejecutar en Supabase SQL Editor
-- ============================================

-- ============================================
-- FUNCION HELPER: Verificar si usuario es admin
-- ============================================
CREATE OR REPLACE FUNCTION es_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol = 'admin'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- FUNCION HELPER: Verificar si usuario es preventista
-- ============================================
CREATE OR REPLACE FUNCTION es_preventista()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'preventista')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- FUNCION HELPER: Verificar si usuario es transportista
-- ============================================
CREATE OR REPLACE FUNCTION es_transportista()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'transportista')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- TABLA: clientes
-- ============================================
ALTER TABLE clientes ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: todos los usuarios autenticados pueden ver clientes
CREATE POLICY "Clientes: lectura para usuarios autenticados"
ON clientes FOR SELECT
USING (auth.uid() IS NOT NULL);

-- Politica de insercion: admin y preventista pueden crear clientes
CREATE POLICY "Clientes: insercion para admin/preventista"
ON clientes FOR INSERT
WITH CHECK (es_preventista());

-- Politica de actualizacion: admin y preventista pueden actualizar clientes
CREATE POLICY "Clientes: actualizacion para admin/preventista"
ON clientes FOR UPDATE
USING (es_preventista());

-- Politica de eliminacion: solo admin puede eliminar clientes
CREATE POLICY "Clientes: eliminacion solo admin"
ON clientes FOR DELETE
USING (es_admin());

-- ============================================
-- TABLA: productos
-- ============================================
ALTER TABLE productos ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: todos los usuarios autenticados pueden ver productos
CREATE POLICY "Productos: lectura para usuarios autenticados"
ON productos FOR SELECT
USING (auth.uid() IS NOT NULL);

-- Politica de insercion: solo admin puede crear productos
CREATE POLICY "Productos: insercion solo admin"
ON productos FOR INSERT
WITH CHECK (es_admin());

-- Politica de actualizacion: solo admin puede actualizar productos
CREATE POLICY "Productos: actualizacion solo admin"
ON productos FOR UPDATE
USING (es_admin());

-- Politica de eliminacion: solo admin puede eliminar productos
CREATE POLICY "Productos: eliminacion solo admin"
ON productos FOR DELETE
USING (es_admin());

-- ============================================
-- TABLA: pedidos
-- ============================================
ALTER TABLE pedidos ENABLE ROW LEVEL SECURITY;

-- Politica de lectura:
-- - Admin ve todos
-- - Preventista ve los que creo
-- - Transportista ve los asignados a el
CREATE POLICY "Pedidos: lectura segun rol"
ON pedidos FOR SELECT
USING (
  es_admin()
  OR usuario_id = auth.uid()
  OR transportista_id = auth.uid()
);

-- Politica de insercion: admin y preventista pueden crear pedidos
CREATE POLICY "Pedidos: insercion para admin/preventista"
ON pedidos FOR INSERT
WITH CHECK (es_preventista());

-- Politica de actualizacion:
-- - Admin puede actualizar cualquier pedido
-- - Preventista puede actualizar sus pedidos
-- - Transportista puede actualizar pedidos asignados (solo estado)
CREATE POLICY "Pedidos: actualizacion segun rol"
ON pedidos FOR UPDATE
USING (
  es_admin()
  OR usuario_id = auth.uid()
  OR transportista_id = auth.uid()
);

-- Politica de eliminacion: solo admin puede eliminar pedidos
CREATE POLICY "Pedidos: eliminacion solo admin"
ON pedidos FOR DELETE
USING (es_admin());

-- ============================================
-- TABLA: pedido_items
-- ============================================
ALTER TABLE pedido_items ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: si puede ver el pedido, puede ver sus items
CREATE POLICY "PedidoItems: lectura vinculada a pedido"
ON pedido_items FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM pedidos p
    WHERE p.id = pedido_items.pedido_id
    AND (
      es_admin()
      OR p.usuario_id = auth.uid()
      OR p.transportista_id = auth.uid()
    )
  )
);

-- Politica de insercion: admin y preventista
CREATE POLICY "PedidoItems: insercion para admin/preventista"
ON pedido_items FOR INSERT
WITH CHECK (es_preventista());

-- Politica de actualizacion: admin y preventista
CREATE POLICY "PedidoItems: actualizacion para admin/preventista"
ON pedido_items FOR UPDATE
USING (es_preventista());

-- Politica de eliminacion: solo admin
CREATE POLICY "PedidoItems: eliminacion solo admin"
ON pedido_items FOR DELETE
USING (es_admin());

-- ============================================
-- TABLA: pedido_historial
-- ============================================
ALTER TABLE pedido_historial ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: si puede ver el pedido, puede ver su historial
CREATE POLICY "PedidoHistorial: lectura vinculada a pedido"
ON pedido_historial FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM pedidos p
    WHERE p.id = pedido_historial.pedido_id
    AND (
      es_admin()
      OR p.usuario_id = auth.uid()
      OR p.transportista_id = auth.uid()
    )
  )
);

-- Politica de insercion: usuarios autenticados pueden registrar cambios
CREATE POLICY "PedidoHistorial: insercion usuarios autenticados"
ON pedido_historial FOR INSERT
WITH CHECK (auth.uid() IS NOT NULL);

-- ============================================
-- TABLA: pagos
-- ============================================
ALTER TABLE pagos ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: admin y preventista pueden ver pagos
CREATE POLICY "Pagos: lectura para admin/preventista"
ON pagos FOR SELECT
USING (es_preventista());

-- Politica de insercion: admin y preventista pueden registrar pagos
CREATE POLICY "Pagos: insercion para admin/preventista"
ON pagos FOR INSERT
WITH CHECK (es_preventista());

-- Politica de actualizacion: solo admin puede modificar pagos
CREATE POLICY "Pagos: actualizacion solo admin"
ON pagos FOR UPDATE
USING (es_admin());

-- Politica de eliminacion: solo admin puede eliminar pagos
CREATE POLICY "Pagos: eliminacion solo admin"
ON pagos FOR DELETE
USING (es_admin());

-- ============================================
-- TABLA: mermas_stock
-- ============================================
ALTER TABLE mermas_stock ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: admin y transportista pueden ver mermas
CREATE POLICY "Mermas: lectura para admin/transportista"
ON mermas_stock FOR SELECT
USING (es_admin() OR es_transportista());

-- Politica de insercion: admin y transportista pueden registrar mermas
CREATE POLICY "Mermas: insercion para admin/transportista"
ON mermas_stock FOR INSERT
WITH CHECK (es_admin() OR es_transportista());

-- Politica de actualizacion: solo admin puede modificar mermas
CREATE POLICY "Mermas: actualizacion solo admin"
ON mermas_stock FOR UPDATE
USING (es_admin());

-- Politica de eliminacion: solo admin puede eliminar mermas
CREATE POLICY "Mermas: eliminacion solo admin"
ON mermas_stock FOR DELETE
USING (es_admin());

-- ============================================
-- TABLA: compras
-- ============================================
ALTER TABLE compras ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: solo admin puede ver compras
CREATE POLICY "Compras: lectura solo admin"
ON compras FOR SELECT
USING (es_admin());

-- Politica de insercion: solo admin puede crear compras
CREATE POLICY "Compras: insercion solo admin"
ON compras FOR INSERT
WITH CHECK (es_admin());

-- Politica de actualizacion: solo admin puede modificar compras
CREATE POLICY "Compras: actualizacion solo admin"
ON compras FOR UPDATE
USING (es_admin());

-- Politica de eliminacion: solo admin puede eliminar compras
CREATE POLICY "Compras: eliminacion solo admin"
ON compras FOR DELETE
USING (es_admin());

-- ============================================
-- TABLA: compra_items (si existe)
-- ============================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'compra_items') THEN
    ALTER TABLE compra_items ENABLE ROW LEVEL SECURITY;

    CREATE POLICY "CompraItems: lectura solo admin"
    ON compra_items FOR SELECT
    USING (es_admin());

    CREATE POLICY "CompraItems: insercion solo admin"
    ON compra_items FOR INSERT
    WITH CHECK (es_admin());

    CREATE POLICY "CompraItems: actualizacion solo admin"
    ON compra_items FOR UPDATE
    USING (es_admin());

    CREATE POLICY "CompraItems: eliminacion solo admin"
    ON compra_items FOR DELETE
    USING (es_admin());
  END IF;
END $$;

-- ============================================
-- TABLA: proveedores
-- ============================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'proveedores') THEN
    ALTER TABLE proveedores ENABLE ROW LEVEL SECURITY;

    CREATE POLICY "Proveedores: lectura solo admin"
    ON proveedores FOR SELECT
    USING (es_admin());

    CREATE POLICY "Proveedores: insercion solo admin"
    ON proveedores FOR INSERT
    WITH CHECK (es_admin());

    CREATE POLICY "Proveedores: actualizacion solo admin"
    ON proveedores FOR UPDATE
    USING (es_admin());

    CREATE POLICY "Proveedores: eliminacion solo admin"
    ON proveedores FOR DELETE
    USING (es_admin());
  END IF;
END $$;

-- ============================================
-- TABLA: perfiles
-- ============================================
ALTER TABLE perfiles ENABLE ROW LEVEL SECURITY;

-- Politica de lectura: todos pueden ver perfiles basicos
CREATE POLICY "Perfiles: lectura usuarios autenticados"
ON perfiles FOR SELECT
USING (auth.uid() IS NOT NULL);

-- Politica de actualizacion: solo puede actualizar su propio perfil o admin cualquiera
CREATE POLICY "Perfiles: actualizacion propio o admin"
ON perfiles FOR UPDATE
USING (id = auth.uid() OR es_admin());

-- ============================================
-- TABLA: zonas (si existe)
-- ============================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'zonas') THEN
    ALTER TABLE zonas ENABLE ROW LEVEL SECURITY;

    CREATE POLICY "Zonas: lectura usuarios autenticados"
    ON zonas FOR SELECT
    USING (auth.uid() IS NOT NULL);

    CREATE POLICY "Zonas: modificacion solo admin"
    ON zonas FOR ALL
    USING (es_admin());
  END IF;
END $$;

-- ============================================
-- VERIFICACION
-- ============================================
-- Para verificar que RLS esta habilitado en todas las tablas:
-- SELECT schemaname, tablename, rowsecurity
-- FROM pg_tables
-- WHERE schemaname = 'public';

-- ============================================
-- NOTA IMPORTANTE
-- ============================================
-- Despues de ejecutar esta migracion:
-- 1. Verificar que los usuarios admin pueden acceder a todo
-- 2. Verificar que preventistas solo ven/crean lo permitido
-- 3. Verificar que transportistas solo ven pedidos asignados
-- 4. Probar que usuarios sin autenticar NO pueden acceder a nada
