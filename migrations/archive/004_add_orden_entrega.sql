-- Migración: Agregar campo orden_entrega para optimización de rutas
-- Fecha: 2026-01-02
-- Descripción: Agrega campo para almacenar el orden de entrega optimizado por Google Routes

-- 1. Agregar campo orden_entrega a la tabla pedidos
ALTER TABLE pedidos
ADD COLUMN IF NOT EXISTS orden_entrega INTEGER;

-- Comentario para documentar el campo
COMMENT ON COLUMN pedidos.orden_entrega IS 'Orden de entrega optimizado por Google Routes API (1 = primera entrega, 2 = segunda, etc.)';

-- 2. Crear índice para ordenar por orden_entrega cuando se consultan pedidos de un transportista
CREATE INDEX IF NOT EXISTS idx_pedidos_transportista_orden ON pedidos(transportista_id, orden_entrega)
WHERE transportista_id IS NOT NULL AND orden_entrega IS NOT NULL;

-- 3. Registrar cambio en orden_entrega en el historial
-- Actualizar la función para incluir orden_entrega
CREATE OR REPLACE FUNCTION registrar_cambio_pedido()
RETURNS TRIGGER AS $$
DECLARE
  usuario_actual UUID;
BEGIN
  -- Intentar obtener el usuario actual de la sesión (si está disponible)
  BEGIN
    usuario_actual := current_setting('app.current_user_id', true)::UUID;
  EXCEPTION
    WHEN OTHERS THEN
      usuario_actual := NULL;
  END;

  -- Registrar cambio en estado
  IF OLD.estado IS DISTINCT FROM NEW.estado THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (NEW.id, usuario_actual, 'estado', OLD.estado, NEW.estado);
  END IF;

  -- Registrar cambio en transportista
  IF OLD.transportista_id IS DISTINCT FROM NEW.transportista_id THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (NEW.id, usuario_actual, 'transportista_id',
            COALESCE(OLD.transportista_id::TEXT, 'sin asignar'),
            COALESCE(NEW.transportista_id::TEXT, 'sin asignar'));
  END IF;

  -- Registrar cambio en notas
  IF OLD.notas IS DISTINCT FROM NEW.notas THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (NEW.id, usuario_actual, 'notas',
            COALESCE(OLD.notas, '(sin notas)'),
            COALESCE(NEW.notas, '(sin notas)'));
  END IF;

  -- Registrar cambio en forma de pago
  IF OLD.forma_pago IS DISTINCT FROM NEW.forma_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (NEW.id, usuario_actual, 'forma_pago',
            COALESCE(OLD.forma_pago, 'efectivo'),
            COALESCE(NEW.forma_pago, 'efectivo'));
  END IF;

  -- Registrar cambio en estado de pago
  IF OLD.estado_pago IS DISTINCT FROM NEW.estado_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (NEW.id, usuario_actual, 'estado_pago',
            COALESCE(OLD.estado_pago, 'pendiente'),
            COALESCE(NEW.estado_pago, 'pendiente'));
  END IF;

  -- Registrar cambio en total
  IF OLD.total IS DISTINCT FROM NEW.total THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (NEW.id, usuario_actual, 'total',
            OLD.total::TEXT,
            NEW.total::TEXT);
  END IF;

  -- Registrar cambio en orden_entrega
  IF OLD.orden_entrega IS DISTINCT FROM NEW.orden_entrega THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (NEW.id, usuario_actual, 'orden_entrega',
            COALESCE(OLD.orden_entrega::TEXT, 'sin orden'),
            COALESCE(NEW.orden_entrega::TEXT, 'sin orden'));
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
