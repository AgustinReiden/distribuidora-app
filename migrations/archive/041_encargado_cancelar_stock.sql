-- ============================================
-- MIGRACION 041: Rol Encargado + Cancelar con restauracion de stock
-- ============================================
--
-- Cambios:
-- 1. Nueva funcion helper es_encargado_o_admin()
-- 2. Actualizar es_preventista() para incluir 'encargado'
-- 3. Actualizar RLS policies para que encargado acceda (excepto usuarios y stock)
-- 4. Nueva RPC cancelar_pedido_con_stock() que restaura stock atomicamente
--
-- EJECUTAR EN: Supabase SQL Editor
-- ============================================

-- ============================================
-- PARTE 1: Funciones helper para rol encargado
-- ============================================

-- Helper: verificar si usuario es encargado o admin
CREATE OR REPLACE FUNCTION es_encargado_o_admin()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'encargado')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Actualizar es_preventista para incluir encargado
-- (encargado puede leer/crear pedidos y clientes igual que preventista)
CREATE OR REPLACE FUNCTION es_preventista()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'preventista', 'encargado')
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ============================================
-- PARTE 2: Actualizar RLS policies para encargado
-- ============================================

-- Pedidos: encargado puede leer todos los pedidos (como admin)
DROP POLICY IF EXISTS "Pedidos: lectura segun rol" ON pedidos;
CREATE POLICY "Pedidos: lectura segun rol"
ON pedidos FOR SELECT
USING (
  es_encargado_o_admin()
  OR usuario_id = auth.uid()
  OR transportista_id = auth.uid()
);

-- Pedidos: encargado puede actualizar (cambiar estado, etc.)
DROP POLICY IF EXISTS "Pedidos: actualizacion segun rol" ON pedidos;
CREATE POLICY "Pedidos: actualizacion segun rol"
ON pedidos FOR UPDATE
USING (
  es_encargado_o_admin()
  OR usuario_id = auth.uid()
  OR transportista_id = auth.uid()
);

-- Pedido items: encargado puede leer items
DROP POLICY IF EXISTS "PedidoItems: lectura vinculada a pedido" ON pedido_items;
CREATE POLICY "PedidoItems: lectura vinculada a pedido"
ON pedido_items FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM pedidos p
    WHERE p.id = pedido_items.pedido_id
    AND (
      es_encargado_o_admin()
      OR p.usuario_id = auth.uid()
      OR p.transportista_id = auth.uid()
    )
  )
);

-- Pagos: encargado puede leer y crear pagos
DROP POLICY IF EXISTS "Pagos: lectura para admin/preventista" ON pagos;
CREATE POLICY "Pagos: lectura para admin/preventista"
ON pagos FOR SELECT
USING (es_preventista()); -- es_preventista ya incluye encargado

DROP POLICY IF EXISTS "Pagos: insercion para admin/preventista" ON pagos;
CREATE POLICY "Pagos: insercion para admin/preventista"
ON pagos FOR INSERT
WITH CHECK (es_preventista());

-- Pagos: encargado puede actualizar pagos
DROP POLICY IF EXISTS "Pagos: actualizacion solo admin" ON pagos;
CREATE POLICY "Pagos: actualizacion para admin/encargado"
ON pagos FOR UPDATE
USING (es_encargado_o_admin());

-- Pedidos eliminados: encargado puede ver auditoria
DROP POLICY IF EXISTS "PedidosEliminados: lectura solo admin" ON pedidos_eliminados;
CREATE POLICY "PedidosEliminados: lectura para admin/encargado"
ON pedidos_eliminados FOR SELECT
USING (es_encargado_o_admin());

-- NOTA: Las siguientes policies NO se tocan - quedan admin-only:
-- - Productos: insercion/actualizacion/eliminacion (encargado no modifica stock)
-- - Perfiles: insercion/actualizacion/eliminacion (encargado no gestiona usuarios)
-- - Pedidos: eliminacion (queda admin-only, y ademas se va a desactivar del frontend)

-- ============================================
-- PARTE 3: RPC cancelar_pedido_con_stock
-- ============================================

CREATE OR REPLACE FUNCTION cancelar_pedido_con_stock(
  p_pedido_id BIGINT,
  p_motivo TEXT,
  p_usuario_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_pedido RECORD;
  v_item RECORD;
BEGIN
  -- Lock the pedido row for update
  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado');
  END IF;

  IF v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  -- Restaurar stock de cada item
  FOR v_item IN SELECT producto_id, cantidad, es_bonificacion FROM pedido_items WHERE pedido_id = p_pedido_id
  LOOP
    UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
  END LOOP;

  -- Cancelar el pedido
  UPDATE pedidos
  SET estado = 'cancelado', motivo_cancelacion = p_motivo
  WHERE id = p_pedido_id;

  -- Registrar en historial
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (p_pedido_id, p_usuario_id, 'estado', v_pedido.estado, 'cancelado - stock restaurado. Motivo: ' || COALESCE(p_motivo, 'Sin motivo'));

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido cancelado y stock restaurado');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
