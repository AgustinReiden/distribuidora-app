-- Migración 022: Sistema de Salvedades en Items de Pedidos
-- Fecha: 2026-01-22
-- Descripción:
--   1. Crea tabla de salvedades para items con problemas de entrega
--   2. Crea tabla de historial de salvedades
--   3. Funciones RPC para registrar y resolver salvedades
--   4. Manejo automático de stock y totales

-- =====================================================
-- 1. TABLA PRINCIPAL: salvedades_items
-- =====================================================

CREATE TABLE IF NOT EXISTS salvedades_items (
  id BIGSERIAL PRIMARY KEY,
  pedido_id BIGINT NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  pedido_item_id BIGINT NOT NULL REFERENCES pedido_items(id) ON DELETE CASCADE,
  producto_id BIGINT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,

  -- Cantidades
  cantidad_original INTEGER NOT NULL,
  cantidad_afectada INTEGER NOT NULL CHECK (cantidad_afectada > 0),
  cantidad_entregada INTEGER NOT NULL DEFAULT 0,

  -- Motivo y detalles
  motivo VARCHAR(50) NOT NULL
    CHECK (motivo IN (
      'faltante_stock',
      'producto_danado',
      'cliente_rechaza',
      'error_pedido',
      'producto_vencido',
      'diferencia_precio',
      'otro'
    )),
  descripcion TEXT,

  -- Evidencia
  foto_url TEXT,

  -- Impacto financiero
  monto_afectado DECIMAL(12,2) NOT NULL,
  precio_unitario DECIMAL(12,2) NOT NULL,

  -- Resolución
  estado_resolucion VARCHAR(30) NOT NULL DEFAULT 'pendiente'
    CHECK (estado_resolucion IN (
      'pendiente',
      'reprogramada',
      'nota_credito',
      'descuento_transportista',
      'absorcion_empresa',
      'resuelto_otro',
      'anulada'
    )),

  -- Datos de resolución
  resolucion_notas TEXT,
  resolucion_fecha TIMESTAMP WITH TIME ZONE,
  resuelto_por UUID REFERENCES perfiles(id),

  -- Stock
  stock_devuelto BOOLEAN DEFAULT FALSE,
  stock_devuelto_at TIMESTAMP WITH TIME ZONE,

  -- Reprogramación (si aplica)
  pedido_reprogramado_id BIGINT REFERENCES pedidos(id),

  -- Auditoría
  reportado_por UUID NOT NULL REFERENCES perfiles(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices
CREATE INDEX IF NOT EXISTS idx_salvedades_pedido ON salvedades_items(pedido_id);
CREATE INDEX IF NOT EXISTS idx_salvedades_producto ON salvedades_items(producto_id);
CREATE INDEX IF NOT EXISTS idx_salvedades_estado ON salvedades_items(estado_resolucion);
CREATE INDEX IF NOT EXISTS idx_salvedades_motivo ON salvedades_items(motivo);
CREATE INDEX IF NOT EXISTS idx_salvedades_fecha ON salvedades_items(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_salvedades_reportado_por ON salvedades_items(reportado_por);

-- Comentarios
COMMENT ON TABLE salvedades_items IS 'Registro de items de pedidos con problemas de entrega (parcial o total)';
COMMENT ON COLUMN salvedades_items.motivo IS 'Motivo: faltante_stock, producto_danado, cliente_rechaza, error_pedido, producto_vencido, diferencia_precio, otro';
COMMENT ON COLUMN salvedades_items.estado_resolucion IS 'Estado: pendiente, reprogramada, nota_credito, descuento_transportista, absorcion_empresa, resuelto_otro, anulada';

-- =====================================================
-- 2. TABLA DE HISTORIAL: salvedad_historial
-- =====================================================

CREATE TABLE IF NOT EXISTS salvedad_historial (
  id BIGSERIAL PRIMARY KEY,
  salvedad_id BIGINT NOT NULL REFERENCES salvedades_items(id) ON DELETE CASCADE,
  accion VARCHAR(50) NOT NULL,
  estado_anterior VARCHAR(30),
  estado_nuevo VARCHAR(30),
  notas TEXT,
  usuario_id UUID REFERENCES perfiles(id),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_salvedad_historial_salvedad ON salvedad_historial(salvedad_id);

COMMENT ON TABLE salvedad_historial IS 'Historial de cambios en salvedades para auditoría';

-- =====================================================
-- 3. RLS POLICIES
-- =====================================================

ALTER TABLE salvedades_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE salvedad_historial ENABLE ROW LEVEL SECURITY;

-- Función helper para verificar admin
CREATE OR REPLACE FUNCTION es_admin_salvedades()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
    AND rol = 'admin'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Función helper para verificar transportista
CREATE OR REPLACE FUNCTION es_transportista_salvedades()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
    AND rol = 'transportista'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Políticas para salvedades_items
CREATE POLICY "Admin full access salvedades" ON salvedades_items
  FOR ALL USING (es_admin_salvedades());

CREATE POLICY "Transportista ve salvedades de sus pedidos" ON salvedades_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM pedidos p
      WHERE p.id = pedido_id
      AND p.transportista_id = auth.uid()
    )
  );

CREATE POLICY "Transportista crea salvedades" ON salvedades_items
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM pedidos p
      WHERE p.id = pedido_id
      AND (p.transportista_id = auth.uid() OR es_admin_salvedades())
    )
  );

CREATE POLICY "Preventista ve salvedades de sus pedidos" ON salvedades_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM pedidos p
      WHERE p.id = pedido_id
      AND p.usuario_id = auth.uid()
    )
  );

-- Políticas para salvedad_historial
CREATE POLICY "Admin full access salvedad_historial" ON salvedad_historial
  FOR ALL USING (es_admin_salvedades());

CREATE POLICY "Ver historial de salvedades accesibles" ON salvedad_historial
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM salvedades_items s
      JOIN pedidos p ON p.id = s.pedido_id
      WHERE s.id = salvedad_id
      AND (es_admin_salvedades() OR p.transportista_id = auth.uid() OR p.usuario_id = auth.uid())
    )
  );

CREATE POLICY "Insertar historial" ON salvedad_historial
  FOR INSERT WITH CHECK (TRUE);

-- =====================================================
-- 4. FUNCIÓN RPC: Registrar salvedad
-- =====================================================

CREATE OR REPLACE FUNCTION registrar_salvedad(
  p_pedido_id BIGINT,
  p_pedido_item_id BIGINT,
  p_cantidad_afectada INTEGER,
  p_motivo VARCHAR,
  p_descripcion TEXT DEFAULT NULL,
  p_foto_url TEXT DEFAULT NULL,
  p_devolver_stock BOOLEAN DEFAULT TRUE
)
RETURNS JSONB AS $$
DECLARE
  v_salvedad_id BIGINT;
  v_item RECORD;
  v_cantidad_entregada INTEGER;
  v_monto_afectado DECIMAL;
  v_usuario_id UUID := auth.uid();
  v_es_admin BOOLEAN;
  v_subtotal_anterior DECIMAL;
  v_subtotal_nuevo DECIMAL;
BEGIN
  v_es_admin := es_admin_salvedades();

  -- Verificar que el usuario tiene permiso
  IF NOT v_es_admin AND NOT EXISTS (
    SELECT 1 FROM pedidos p
    WHERE p.id = p_pedido_id
    AND (p.transportista_id = v_usuario_id)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para registrar salvedad en este pedido');
  END IF;

  -- Obtener datos del item
  SELECT
    pi.id,
    pi.producto_id,
    pi.cantidad,
    pi.precio_unitario,
    pi.subtotal,
    pr.nombre AS producto_nombre,
    pr.stock AS stock_actual
  INTO v_item
  FROM pedido_items pi
  JOIN productos pr ON pr.id = pi.producto_id
  WHERE pi.id = p_pedido_item_id AND pi.pedido_id = p_pedido_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item de pedido no encontrado');
  END IF;

  -- Validar cantidad
  IF p_cantidad_afectada > v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a la cantidad del item');
  END IF;

  IF p_cantidad_afectada <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'La cantidad afectada debe ser mayor a 0');
  END IF;

  -- Calcular cantidad entregada y monto afectado
  v_cantidad_entregada := v_item.cantidad - p_cantidad_afectada;
  v_monto_afectado := p_cantidad_afectada * v_item.precio_unitario;
  v_subtotal_anterior := v_item.subtotal;
  v_subtotal_nuevo := v_cantidad_entregada * v_item.precio_unitario;

  -- Crear la salvedad
  INSERT INTO salvedades_items (
    pedido_id,
    pedido_item_id,
    producto_id,
    cantidad_original,
    cantidad_afectada,
    cantidad_entregada,
    motivo,
    descripcion,
    foto_url,
    monto_afectado,
    precio_unitario,
    reportado_por
  ) VALUES (
    p_pedido_id,
    p_pedido_item_id,
    v_item.producto_id,
    v_item.cantidad,
    p_cantidad_afectada,
    v_cantidad_entregada,
    p_motivo,
    p_descripcion,
    p_foto_url,
    v_monto_afectado,
    v_item.precio_unitario,
    v_usuario_id
  )
  RETURNING id INTO v_salvedad_id;

  -- Actualizar el item del pedido (reducir cantidad)
  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items SET
      cantidad = v_cantidad_entregada,
      subtotal = v_subtotal_nuevo
    WHERE id = p_pedido_item_id;
  ELSE
    -- Si la cantidad es 0, eliminar el item
    DELETE FROM pedido_items WHERE id = p_pedido_item_id;
  END IF;

  -- Recalcular total del pedido
  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = p_pedido_id),
    updated_at = NOW()
  WHERE id = p_pedido_id;

  -- Manejar devolución de stock según motivo
  IF p_devolver_stock THEN
    IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN
      -- Para estos motivos, el producto vuelve al stock
      UPDATE productos SET stock = stock + p_cantidad_afectada WHERE id = v_item.producto_id;
      UPDATE salvedades_items SET
        stock_devuelto = TRUE,
        stock_devuelto_at = NOW()
      WHERE id = v_salvedad_id;
    ELSE
      -- Para faltante_stock, producto_danado, producto_vencido: no vuelve al stock
      UPDATE salvedades_items SET stock_devuelto = FALSE WHERE id = v_salvedad_id;
    END IF;
  END IF;

  -- Registrar en historial de salvedad
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id);

  -- Registrar en historial del pedido si existe la tabla
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'pedido_historial') THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (
      p_pedido_id,
      v_usuario_id,
      'salvedad_item',
      v_item.cantidad::TEXT || ' unidades de ' || v_item.producto_nombre,
      v_cantidad_entregada::TEXT || ' unidades (salvedad: ' || p_motivo || ')'
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'salvedad_id', v_salvedad_id,
    'monto_afectado', v_monto_afectado,
    'cantidad_entregada', v_cantidad_entregada,
    'stock_devuelto', CASE WHEN p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN true ELSE false END,
    'nuevo_total_pedido', (SELECT total FROM pedidos WHERE id = p_pedido_id)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION registrar_salvedad IS 'Registra una salvedad en un item, ajusta cantidades y stock automáticamente';

-- =====================================================
-- 5. FUNCIÓN RPC: Resolver salvedad
-- =====================================================

CREATE OR REPLACE FUNCTION resolver_salvedad(
  p_salvedad_id BIGINT,
  p_estado_resolucion VARCHAR,
  p_notas TEXT DEFAULT NULL,
  p_pedido_reprogramado_id BIGINT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_salvedad RECORD;
  v_estado_anterior VARCHAR;
  v_usuario_id UUID := auth.uid();
BEGIN
  -- Solo admin puede resolver
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo administradores pueden resolver salvedades');
  END IF;

  -- Validar estado de resolución
  IF p_estado_resolucion NOT IN ('reprogramada', 'nota_credito', 'descuento_transportista', 'absorcion_empresa', 'resuelto_otro', 'anulada') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Estado de resolución no válido');
  END IF;

  -- Obtener salvedad actual
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Salvedad no encontrada');
  END IF;

  IF v_salvedad.estado_resolucion != 'pendiente' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La salvedad ya fue resuelta');
  END IF;

  v_estado_anterior := v_salvedad.estado_resolucion;

  -- Actualizar salvedad
  UPDATE salvedades_items SET
    estado_resolucion = p_estado_resolucion,
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    pedido_reprogramado_id = p_pedido_reprogramado_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id;

  -- Registrar en historial
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id)
  VALUES (p_salvedad_id, 'resolucion', v_estado_anterior, p_estado_resolucion, p_notas, v_usuario_id);

  RETURN jsonb_build_object('success', true, 'nuevo_estado', p_estado_resolucion);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION resolver_salvedad IS 'Marca una salvedad como resuelta con un tipo de resolución';

-- =====================================================
-- 6. FUNCIÓN: Obtener estadísticas de salvedades
-- =====================================================

CREATE OR REPLACE FUNCTION obtener_estadisticas_salvedades(
  p_fecha_desde DATE DEFAULT NULL,
  p_fecha_hasta DATE DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_resultado JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total', COUNT(*),
    'pendientes', COUNT(*) FILTER (WHERE estado_resolucion = 'pendiente'),
    'resueltas', COUNT(*) FILTER (WHERE estado_resolucion NOT IN ('pendiente', 'anulada')),
    'anuladas', COUNT(*) FILTER (WHERE estado_resolucion = 'anulada'),
    'monto_total_afectado', COALESCE(SUM(monto_afectado), 0),
    'monto_pendiente', COALESCE(SUM(monto_afectado) FILTER (WHERE estado_resolucion = 'pendiente'), 0),
    'por_motivo', (
      SELECT jsonb_object_agg(motivo, cnt)
      FROM (
        SELECT motivo, COUNT(*) as cnt
        FROM salvedades_items
        WHERE (p_fecha_desde IS NULL OR created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR created_at::date <= p_fecha_hasta)
        GROUP BY motivo
      ) t
    ),
    'por_resolucion', (
      SELECT jsonb_object_agg(estado_resolucion, cnt)
      FROM (
        SELECT estado_resolucion, COUNT(*) as cnt
        FROM salvedades_items
        WHERE (p_fecha_desde IS NULL OR created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR created_at::date <= p_fecha_hasta)
        GROUP BY estado_resolucion
      ) t
    ),
    'por_producto', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto_id', producto_id,
        'producto_nombre', producto_nombre,
        'cantidad', cnt,
        'monto', monto,
        'unidades_afectadas', unidades
      ))
      FROM (
        SELECT
          s.producto_id,
          p.nombre as producto_nombre,
          COUNT(*) as cnt,
          SUM(s.monto_afectado) as monto,
          SUM(s.cantidad_afectada) as unidades
        FROM salvedades_items s
        JOIN productos p ON p.id = s.producto_id
        WHERE (p_fecha_desde IS NULL OR s.created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR s.created_at::date <= p_fecha_hasta)
        GROUP BY s.producto_id, p.nombre
        ORDER BY cnt DESC
        LIMIT 10
      ) t
    ),
    'por_transportista', (
      SELECT jsonb_agg(jsonb_build_object(
        'transportista_id', transportista_id,
        'transportista_nombre', transportista_nombre,
        'cantidad', cnt,
        'monto', monto
      ))
      FROM (
        SELECT
          pe.transportista_id,
          pf.nombre as transportista_nombre,
          COUNT(*) as cnt,
          SUM(s.monto_afectado) as monto
        FROM salvedades_items s
        JOIN pedidos pe ON pe.id = s.pedido_id
        JOIN perfiles pf ON pf.id = pe.transportista_id
        WHERE (p_fecha_desde IS NULL OR s.created_at::date >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR s.created_at::date <= p_fecha_hasta)
        GROUP BY pe.transportista_id, pf.nombre
        ORDER BY cnt DESC
        LIMIT 10
      ) t
    )
  ) INTO v_resultado
  FROM salvedades_items
  WHERE (p_fecha_desde IS NULL OR created_at::date >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR created_at::date <= p_fecha_hasta);

  RETURN v_resultado;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 7. VISTA: Salvedades con detalles
-- =====================================================

CREATE OR REPLACE VIEW vista_salvedades AS
SELECT
  s.id,
  s.pedido_id,
  s.pedido_item_id,
  s.producto_id,
  pr.nombre AS producto_nombre,
  pr.codigo AS producto_codigo,
  s.cantidad_original,
  s.cantidad_afectada,
  s.cantidad_entregada,
  s.motivo,
  s.descripcion,
  s.foto_url,
  s.monto_afectado,
  s.precio_unitario,
  s.estado_resolucion,
  s.resolucion_notas,
  s.resolucion_fecha,
  s.stock_devuelto,
  s.pedido_reprogramado_id,
  s.created_at,
  s.updated_at,
  -- Datos del pedido
  p.cliente_id,
  c.nombre_fantasia AS cliente_nombre,
  p.transportista_id,
  tp.nombre AS transportista_nombre,
  p.estado AS pedido_estado,
  p.total AS pedido_total,
  -- Datos de auditoría
  s.reportado_por,
  rp.nombre AS reportado_por_nombre,
  s.resuelto_por,
  res.nombre AS resuelto_por_nombre
FROM salvedades_items s
JOIN productos pr ON pr.id = s.producto_id
JOIN pedidos p ON p.id = s.pedido_id
JOIN clientes c ON c.id = p.cliente_id
JOIN perfiles rp ON rp.id = s.reportado_por
LEFT JOIN perfiles tp ON tp.id = p.transportista_id
LEFT JOIN perfiles res ON res.id = s.resuelto_por
ORDER BY s.created_at DESC;

COMMENT ON VIEW vista_salvedades IS 'Vista de salvedades con información completa del producto, pedido y cliente';

-- =====================================================
-- 8. TRIGGER: Actualizar updated_at
-- =====================================================

CREATE OR REPLACE FUNCTION update_salvedades_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_salvedades_updated_at ON salvedades_items;
CREATE TRIGGER trigger_salvedades_updated_at
  BEFORE UPDATE ON salvedades_items
  FOR EACH ROW
  EXECUTE FUNCTION update_salvedades_updated_at();

-- =====================================================
-- 9. FUNCIÓN: Anular salvedad (admin)
-- =====================================================

CREATE OR REPLACE FUNCTION anular_salvedad(
  p_salvedad_id BIGINT,
  p_notas TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
BEGIN
  -- Solo admin puede anular
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo administradores pueden anular salvedades');
  END IF;

  -- Obtener salvedad
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Salvedad no encontrada');
  END IF;

  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La salvedad ya está anulada');
  END IF;

  -- Restaurar item del pedido si aún existe
  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id) THEN
    -- Restaurar cantidad original
    UPDATE pedido_items SET
      cantidad = v_salvedad.cantidad_original,
      subtotal = v_salvedad.cantidad_original * v_salvedad.precio_unitario
    WHERE id = v_salvedad.pedido_item_id;
  ELSE
    -- Recrear el item si fue eliminado
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal)
    VALUES (
      v_salvedad.pedido_id,
      v_salvedad.producto_id,
      v_salvedad.cantidad_original,
      v_salvedad.precio_unitario,
      v_salvedad.cantidad_original * v_salvedad.precio_unitario
    );
  END IF;

  -- Recalcular total del pedido
  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id),
    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id;

  -- Si se había devuelto stock, revertir
  IF v_salvedad.stock_devuelto THEN
    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada WHERE id = v_salvedad.producto_id;
  END IF;

  -- Marcar como anulada
  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id;

  -- Registrar en historial
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id)
  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id);

  RETURN jsonb_build_object('success', true, 'message', 'Salvedad anulada correctamente');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION anular_salvedad IS 'Anula una salvedad y restaura el item original del pedido';
