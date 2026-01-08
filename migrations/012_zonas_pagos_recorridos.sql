-- Migración 012: Zonificación de preventistas, mejora de pagos parciales y registro de recorridos
-- Fecha: 2026-01-08
-- Descripción:
--   1. Agrega zona a perfiles para zonificar preventistas
--   2. Agrega monto_pagado a pedidos para pagos parciales
--   3. Crea tabla de recorridos para historial de entregas

-- =====================================================
-- 1. ZONIFICACIÓN DE PREVENTISTAS
-- =====================================================

-- Agregar campo zona a perfiles (alfanumérico para flexibilidad)
ALTER TABLE perfiles ADD COLUMN IF NOT EXISTS zona VARCHAR(50);

-- Índice para filtrar por zona
CREATE INDEX IF NOT EXISTS idx_perfiles_zona ON perfiles(zona);

-- Comentario de documentación
COMMENT ON COLUMN perfiles.zona IS 'Zona asignada al preventista (ej: 1, 2, 3, Norte, Sur, etc.)';

-- =====================================================
-- 2. MEJORA DE PAGOS PARCIALES
-- =====================================================

-- Agregar campo monto_pagado a pedidos para rastrear pagos parciales
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS monto_pagado DECIMAL(12,2) DEFAULT 0;

-- Comentario de documentación
COMMENT ON COLUMN pedidos.monto_pagado IS 'Monto total pagado por el cliente para este pedido';

-- Función para calcular automáticamente el estado de pago basado en monto_pagado
CREATE OR REPLACE FUNCTION actualizar_estado_pago_pedido()
RETURNS TRIGGER AS $$
BEGIN
  -- Si el monto pagado es >= al total, marcar como pagado
  IF NEW.monto_pagado >= NEW.total THEN
    NEW.estado_pago := 'pagado';
  -- Si hay algo pagado pero no todo, marcar como parcial
  ELSIF NEW.monto_pagado > 0 THEN
    NEW.estado_pago := 'parcial';
  -- Si no hay nada pagado, marcar como pendiente
  ELSE
    NEW.estado_pago := 'pendiente';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger para actualizar estado_pago automáticamente
DROP TRIGGER IF EXISTS trigger_actualizar_estado_pago ON pedidos;
CREATE TRIGGER trigger_actualizar_estado_pago
  BEFORE INSERT OR UPDATE OF monto_pagado, total ON pedidos
  FOR EACH ROW
  EXECUTE FUNCTION actualizar_estado_pago_pedido();

-- =====================================================
-- 3. REGISTRO DE RECORRIDOS DE TRANSPORTISTAS
-- =====================================================

-- Tabla principal de recorridos
CREATE TABLE IF NOT EXISTS recorridos (
  id BIGSERIAL PRIMARY KEY,
  transportista_id UUID NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  fecha DATE NOT NULL DEFAULT CURRENT_DATE,
  distancia_total DECIMAL(10,2), -- en km
  duracion_total INTEGER, -- en minutos
  total_pedidos INTEGER NOT NULL DEFAULT 0,
  pedidos_entregados INTEGER NOT NULL DEFAULT 0,
  total_facturado DECIMAL(12,2) DEFAULT 0,
  total_cobrado DECIMAL(12,2) DEFAULT 0,
  estado VARCHAR(20) DEFAULT 'en_curso', -- en_curso, completado, cancelado
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  completed_at TIMESTAMP WITH TIME ZONE,
  notas TEXT
);

-- Tabla de detalle de pedidos en cada recorrido
CREATE TABLE IF NOT EXISTS recorrido_pedidos (
  id BIGSERIAL PRIMARY KEY,
  recorrido_id BIGINT NOT NULL REFERENCES recorridos(id) ON DELETE CASCADE,
  pedido_id BIGINT NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  orden_entrega INTEGER NOT NULL,
  estado_entrega VARCHAR(20) DEFAULT 'pendiente', -- pendiente, entregado, no_entregado
  hora_entrega TIMESTAMP WITH TIME ZONE,
  notas TEXT,
  UNIQUE(recorrido_id, pedido_id)
);

-- Índices para mejorar rendimiento
CREATE INDEX IF NOT EXISTS idx_recorridos_transportista ON recorridos(transportista_id);
CREATE INDEX IF NOT EXISTS idx_recorridos_fecha ON recorridos(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_recorridos_estado ON recorridos(estado);
CREATE INDEX IF NOT EXISTS idx_recorrido_pedidos_recorrido ON recorrido_pedidos(recorrido_id);
CREATE INDEX IF NOT EXISTS idx_recorrido_pedidos_pedido ON recorrido_pedidos(pedido_id);

-- Comentarios de documentación
COMMENT ON TABLE recorridos IS 'Registro de recorridos diarios de transportistas para rendición y estadísticas';
COMMENT ON TABLE recorrido_pedidos IS 'Detalle de pedidos incluidos en cada recorrido con orden de entrega';
COMMENT ON COLUMN recorridos.estado IS 'Estado del recorrido: en_curso, completado, cancelado';
COMMENT ON COLUMN recorrido_pedidos.estado_entrega IS 'Estado de entrega: pendiente, entregado, no_entregado';

-- Función RPC para crear un nuevo recorrido con sus pedidos
CREATE OR REPLACE FUNCTION crear_recorrido(
  p_transportista_id UUID,
  p_pedidos JSONB, -- Array de {pedido_id, orden_entrega}
  p_distancia DECIMAL DEFAULT NULL,
  p_duracion INTEGER DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
  v_recorrido_id BIGINT;
  v_pedido JSONB;
  v_total_facturado DECIMAL := 0;
BEGIN
  -- Calcular total facturado
  SELECT COALESCE(SUM(total), 0) INTO v_total_facturado
  FROM pedidos
  WHERE id IN (SELECT (value->>'pedido_id')::BIGINT FROM jsonb_array_elements(p_pedidos) AS value);

  -- Crear el recorrido
  INSERT INTO recorridos (
    transportista_id,
    fecha,
    distancia_total,
    duracion_total,
    total_pedidos,
    total_facturado,
    estado
  )
  VALUES (
    p_transportista_id,
    CURRENT_DATE,
    p_distancia,
    p_duracion,
    jsonb_array_length(p_pedidos),
    v_total_facturado,
    'en_curso'
  )
  RETURNING id INTO v_recorrido_id;

  -- Insertar los pedidos del recorrido
  FOR v_pedido IN SELECT * FROM jsonb_array_elements(p_pedidos)
  LOOP
    INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega)
    VALUES (
      v_recorrido_id,
      (v_pedido->>'pedido_id')::BIGINT,
      (v_pedido->>'orden_entrega')::INTEGER
    );
  END LOOP;

  RETURN v_recorrido_id;
END;
$$ LANGUAGE plpgsql;

-- Función para actualizar estadísticas del recorrido cuando se entrega un pedido
CREATE OR REPLACE FUNCTION actualizar_recorrido_entrega()
RETURNS TRIGGER AS $$
DECLARE
  v_recorrido_id BIGINT;
  v_monto_pedido DECIMAL;
BEGIN
  -- Buscar si el pedido está en algún recorrido activo
  SELECT rp.recorrido_id INTO v_recorrido_id
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id = NEW.id
    AND r.fecha = CURRENT_DATE
    AND r.estado = 'en_curso'
  LIMIT 1;

  IF v_recorrido_id IS NOT NULL THEN
    -- Actualizar el estado de entrega del pedido en el recorrido
    IF NEW.estado = 'entregado' AND (OLD.estado IS NULL OR OLD.estado != 'entregado') THEN
      UPDATE recorrido_pedidos
      SET estado_entrega = 'entregado', hora_entrega = NOW()
      WHERE recorrido_id = v_recorrido_id AND pedido_id = NEW.id;

      -- Actualizar contadores del recorrido
      UPDATE recorridos
      SET
        pedidos_entregados = pedidos_entregados + 1,
        total_cobrado = total_cobrado + COALESCE(NEW.monto_pagado, 0)
      WHERE id = v_recorrido_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger para actualizar recorrido cuando se entrega un pedido
DROP TRIGGER IF EXISTS trigger_actualizar_recorrido_entrega ON pedidos;
CREATE TRIGGER trigger_actualizar_recorrido_entrega
  AFTER UPDATE OF estado ON pedidos
  FOR EACH ROW
  EXECUTE FUNCTION actualizar_recorrido_entrega();

-- Vista para obtener resumen de recorridos por día
CREATE OR REPLACE VIEW vista_recorridos_diarios AS
SELECT
  r.id,
  r.fecha,
  r.transportista_id,
  p.nombre as transportista_nombre,
  r.total_pedidos,
  r.pedidos_entregados,
  r.total_facturado,
  r.total_cobrado,
  r.distancia_total,
  r.duracion_total,
  r.estado,
  r.created_at,
  r.completed_at,
  CASE
    WHEN r.total_pedidos > 0 THEN
      ROUND((r.pedidos_entregados::DECIMAL / r.total_pedidos) * 100, 1)
    ELSE 0
  END as porcentaje_completado
FROM recorridos r
JOIN perfiles p ON p.id = r.transportista_id
ORDER BY r.fecha DESC, r.created_at DESC;
