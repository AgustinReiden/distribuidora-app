-- Migración 029: Fix eliminar_pedido_completo — NULL transportista crash
--
-- Bug: La función usaba variables RECORD para transportista y eliminador,
-- pero solo las asignaba condicionalmente. Cuando un pedido no tiene
-- transportista asignado, PostgreSQL lanza:
--   "record v_transportista is not assigned yet"
--
-- Fix: Usar variables TEXT con default NULL en lugar de RECORD.

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
  v_cliente_nombre TEXT;
  v_cliente_direccion TEXT;
  v_usuario_creador_nombre TEXT;
  v_transportista_nombre TEXT := NULL;
  v_eliminador_nombre TEXT := NULL;
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
  SELECT nombre_fantasia, direccion INTO v_cliente_nombre, v_cliente_direccion
  FROM clientes WHERE id = v_pedido.cliente_id;

  -- Obtener nombre del usuario creador
  SELECT nombre INTO v_usuario_creador_nombre
  FROM perfiles WHERE id = v_pedido.usuario_id;

  -- Obtener nombre del transportista si existe
  IF v_pedido.transportista_id IS NOT NULL THEN
    SELECT nombre INTO v_transportista_nombre
    FROM perfiles WHERE id = v_pedido.transportista_id;
  END IF;

  -- Obtener nombre de quien elimina
  IF p_usuario_id IS NOT NULL THEN
    SELECT nombre INTO v_eliminador_nombre
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
    v_cliente_nombre,
    v_cliente_direccion,
    v_pedido.total,
    v_pedido.estado,
    v_pedido.estado_pago,
    v_pedido.forma_pago,
    v_pedido.monto_pagado,
    v_pedido.notas,
    COALESCE(v_items, '[]'::jsonb),
    v_pedido.usuario_id,
    v_usuario_creador_nombre,
    v_pedido.transportista_id,
    v_transportista_nombre,
    v_pedido.created_at,
    v_pedido.fecha_entrega,
    p_usuario_id,
    v_eliminador_nombre,
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
