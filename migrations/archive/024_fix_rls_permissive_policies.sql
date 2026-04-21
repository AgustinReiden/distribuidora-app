-- =====================================================
-- MIGRACIÓN 024: Corrección de Políticas RLS Permisivas
-- =====================================================
-- Esta migración elimina políticas RLS permisivas que pueden
-- haber quedado de migraciones anteriores y asegura que solo
-- existan las políticas restrictivas correctas.
--
-- PROBLEMA: La migración 007 creó políticas que permiten a
-- CUALQUIER usuario autenticado ver/modificar pagos. Estas
-- políticas pueden coexistir con las de 015, causando que
-- la más permisiva prevalezca.
--
-- EJECUTAR EN: Supabase SQL Editor
-- =====================================================

-- ============================================
-- 1. ELIMINAR POLÍTICAS PERMISIVAS DE PAGOS
-- ============================================

-- Eliminar las políticas permisivas de la migración 007
DROP POLICY IF EXISTS "Allow authenticated users to view payments" ON pagos;
DROP POLICY IF EXISTS "Allow authenticated users to insert payments" ON pagos;
DROP POLICY IF EXISTS "Allow authenticated users to update payments" ON pagos;
DROP POLICY IF EXISTS "Allow authenticated users to delete payments" ON pagos;

-- Verificar y recrear las políticas correctas
DROP POLICY IF EXISTS "Pagos: lectura para admin/preventista" ON pagos;
DROP POLICY IF EXISTS "Pagos: insercion para admin/preventista" ON pagos;
DROP POLICY IF EXISTS "Pagos: actualizacion solo admin" ON pagos;
DROP POLICY IF EXISTS "Pagos: eliminacion solo admin" ON pagos;

-- Recrear políticas restrictivas
CREATE POLICY "Pagos: lectura para admin/preventista"
ON pagos FOR SELECT
USING (es_preventista());

CREATE POLICY "Pagos: insercion para admin/preventista"
ON pagos FOR INSERT
WITH CHECK (es_preventista());

CREATE POLICY "Pagos: actualizacion solo admin"
ON pagos FOR UPDATE
USING (es_admin());

CREATE POLICY "Pagos: eliminacion solo admin"
ON pagos FOR DELETE
USING (es_admin());

-- ============================================
-- 2. VERIFICAR POLÍTICAS EN OTRAS TABLAS
-- ============================================

-- Verificar que pedidos tienen política restrictiva
-- (transportistas solo ven pedidos asignados a ellos)
DROP POLICY IF EXISTS "Pedidos: lectura segun rol" ON pedidos;
CREATE POLICY "Pedidos: lectura segun rol"
ON pedidos FOR SELECT
USING (
  es_admin()
  OR usuario_id = auth.uid()
  OR transportista_id = auth.uid()
);

-- ============================================
-- 3. AGREGAR POLÍTICA DE ZONA PARA TRANSPORTISTAS (opcional)
-- ============================================
-- Si quieres restringir aún más por zona, descomenta esto:

-- CREATE OR REPLACE FUNCTION get_user_zona()
-- RETURNS TEXT AS $$
-- BEGIN
--   RETURN (SELECT zona FROM perfiles WHERE id = auth.uid());
-- END;
-- $$ LANGUAGE plpgsql SECURITY DEFINER;

-- Política para que transportistas solo vean clientes de su zona
-- DROP POLICY IF EXISTS "Clientes: transportista ve su zona" ON clientes;
-- CREATE POLICY "Clientes: transportista ve su zona"
-- ON clientes FOR SELECT
-- USING (
--   es_preventista()
--   OR (es_transportista() AND zona = get_user_zona())
-- );

-- ============================================
-- 4. VERIFICACIÓN
-- ============================================
-- Ejecuta esto para verificar que las políticas están correctas:

-- SELECT
--   schemaname,
--   tablename,
--   policyname,
--   permissive,
--   roles,
--   cmd,
--   qual
-- FROM pg_policies
-- WHERE schemaname = 'public'
-- ORDER BY tablename, policyname;

-- ============================================
-- COMENTARIOS
-- ============================================
COMMENT ON POLICY "Pagos: lectura para admin/preventista" ON pagos IS
'Solo admin y preventista pueden ver pagos. Transportistas no tienen acceso.';

COMMENT ON POLICY "Pagos: insercion para admin/preventista" ON pagos IS
'Solo admin y preventista pueden registrar pagos.';

COMMENT ON POLICY "Pagos: actualizacion solo admin" ON pagos IS
'Solo admin puede modificar pagos existentes.';

COMMENT ON POLICY "Pagos: eliminacion solo admin" ON pagos IS
'Solo admin puede eliminar pagos.';
