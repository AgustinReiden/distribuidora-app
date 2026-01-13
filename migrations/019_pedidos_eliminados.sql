-- Migración 019: Sistema de registro de pedidos eliminados
-- Permite trazabilidad completa de pedidos que fueron eliminados

-- Tabla para almacenar pedidos eliminados
CREATE TABLE IF NOT EXISTS pedidos_eliminados (
  id BIGSERIAL PRIMARY KEY,
  pedido_id BIGINT NOT NULL,                    -- ID original del pedido
  cliente_id INT,                               -- ID del cliente
  cliente_nombre TEXT,                          -- Nombre del cliente (snapshot)
  cliente_direccion TEXT,                       -- Dirección del cliente (snapshot)
  total DECIMAL(12,2),                          -- Total del pedido
  estado VARCHAR(50),                           -- Estado al momento de eliminar
  estado_pago VARCHAR(50),                      -- Estado de pago al momento de eliminar
  forma_pago VARCHAR(50),                       -- Forma de pago
  monto_pagado DECIMAL(12,2),                   -- Monto pagado
  notas TEXT,                                   -- Notas del pedido
  items JSONB,                                  -- Items del pedido como JSON
  usuario_creador_id UUID,                      -- Quién creó el pedido originalmente
  usuario_creador_nombre TEXT,                  -- Nombre del creador (snapshot)
  transportista_id UUID,                        -- Transportista asignado
  transportista_nombre TEXT,                    -- Nombre del transportista (snapshot)
  fecha_pedido TIMESTAMP WITH TIME ZONE,        -- Fecha de creación original
  fecha_entrega TIMESTAMP WITH TIME ZONE,       -- Fecha de entrega si fue entregado
  -- Datos de la eliminación
  eliminado_por_id UUID NOT NULL,               -- Quién eliminó el pedido
  eliminado_por_nombre TEXT,                    -- Nombre de quien eliminó (snapshot)
  eliminado_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(), -- Cuándo se eliminó
  motivo_eliminacion TEXT,                      -- Motivo opcional de eliminación
  stock_restaurado BOOLEAN DEFAULT TRUE         -- Si se restauró el stock
);

-- Índices para búsquedas comunes
CREATE INDEX IF NOT EXISTS idx_pedidos_eliminados_pedido_id ON pedidos_eliminados(pedido_id);
CREATE INDEX IF NOT EXISTS idx_pedidos_eliminados_cliente ON pedidos_eliminados(cliente_id);
CREATE INDEX IF NOT EXISTS idx_pedidos_eliminados_fecha ON pedidos_eliminados(eliminado_at);
CREATE INDEX IF NOT EXISTS idx_pedidos_eliminados_eliminado_por ON pedidos_eliminados(eliminado_por_id);

-- Comentarios
COMMENT ON TABLE pedidos_eliminados IS 'Registro histórico de pedidos eliminados para trazabilidad';
COMMENT ON COLUMN pedidos_eliminados.items IS 'Snapshot de los items del pedido en formato JSON';

-- Modificar la función eliminar_pedido_completo para registrar antes de eliminar
CREATE OR REPLACE FUNCTION eliminar_pedido_completo(
  p_pedido_id BIGINT,
  p_restaurar_stock BOOLEAN DEFAULT TRUE,
  p_usuario_id UUID DEFAULT NULL,
  p_motivo TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_pedido RECORD;
  v_items JSONB;
  v_cliente RECORD;
  v_usuario_creador RECORD;
  v_transportista RECORD;
  v_usuario_eliminador RECORD;
  v_item RECORD;
BEGIN
  -- Obtener datos del pedido
  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  -- Obtener items del pedido como JSON
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', pi.producto_id,
    'producto_nombre', pr.nombre,
    'producto_codigo', pr.codigo,
    'cantidad', pi.cantidad,
    'precio_unitario', pi.precio_unitario,
    'subtotal', pi.subtotal
  )) INTO v_items
  FROM pedido_items pi
  LEFT JOIN productos pr ON pr.id = pi.producto_id
  WHERE pi.pedido_id = p_pedido_id;

  -- Obtener datos del cliente
  SELECT nombre_fantasia, direccion INTO v_cliente
  FROM clientes WHERE id = v_pedido.cliente_id;

  -- Obtener nombre del usuario creador
  SELECT nombre INTO v_usuario_creador
  FROM perfiles WHERE id = v_pedido.usuario_id;

  -- Obtener nombre del transportista si existe
  IF v_pedido.transportista_id IS NOT NULL THEN
    SELECT nombre INTO v_transportista
    FROM perfiles WHERE id = v_pedido.transportista_id;
  END IF;

  -- Obtener nombre de quien elimina
  IF p_usuario_id IS NOT NULL THEN
    SELECT nombre INTO v_usuario_eliminador
    FROM perfiles WHERE id = p_usuario_id;
  END IF;

  -- Registrar el pedido eliminado
  INSERT INTO pedidos_eliminados (
    pedido_id,
    cliente_id,
    cliente_nombre,
    cliente_direccion,
    total,
    estado,
    estado_pago,
    forma_pago,
    monto_pagado,
    notas,
    items,
    usuario_creador_id,
    usuario_creador_nombre,
    transportista_id,
    transportista_nombre,
    fecha_pedido,
    fecha_entrega,
    eliminado_por_id,
    eliminado_por_nombre,
    motivo_eliminacion,
    stock_restaurado
  ) VALUES (
    p_pedido_id,
    v_pedido.cliente_id,
    v_cliente.nombre_fantasia,
    v_cliente.direccion,
    v_pedido.total,
    v_pedido.estado,
    v_pedido.estado_pago,
    v_pedido.forma_pago,
    v_pedido.monto_pagado,
    v_pedido.notas,
    COALESCE(v_items, '[]'::jsonb),
    v_pedido.usuario_id,
    v_usuario_creador.nombre,
    v_pedido.transportista_id,
    v_transportista.nombre,
    v_pedido.created_at,
    v_pedido.fecha_entrega,
    p_usuario_id,
    v_usuario_eliminador.nombre,
    p_motivo,
    p_restaurar_stock
  );

  -- Restaurar stock si corresponde
  IF p_restaurar_stock THEN
    FOR v_item IN SELECT producto_id, cantidad FROM pedido_items WHERE pedido_id = p_pedido_id
    LOOP
      UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
    END LOOP;
  END IF;

  -- Eliminar items del pedido
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Eliminar historial del pedido
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id;

  -- Eliminar el pedido
  DELETE FROM pedidos WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Comentario actualizado
COMMENT ON FUNCTION eliminar_pedido_completo(BIGINT, BOOLEAN, UUID, TEXT) IS
'Elimina un pedido registrando todos sus datos en pedidos_eliminados para trazabilidad';

-- RLS para la tabla de pedidos eliminados (solo admin puede ver)
ALTER TABLE pedidos_eliminados ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admin puede ver pedidos eliminados" ON pedidos_eliminados
  FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

CREATE POLICY "Admin puede insertar pedidos eliminados" ON pedidos_eliminados
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );
