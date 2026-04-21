-- Migración: Mejoras en la funcionalidad de pedidos
-- Fecha: 2025-12-31
-- Descripción: Agrega campos de notas, forma de pago, estado de pago y tabla de historial

-- 1. Agregar campos nuevos a la tabla pedidos
ALTER TABLE pedidos
ADD COLUMN IF NOT EXISTS notas TEXT,
ADD COLUMN IF NOT EXISTS forma_pago TEXT DEFAULT 'efectivo',
ADD COLUMN IF NOT EXISTS estado_pago TEXT DEFAULT 'pendiente';

-- Comentarios para documentar los nuevos campos
COMMENT ON COLUMN pedidos.notas IS 'Observaciones o notas importantes para la preparación del pedido';
COMMENT ON COLUMN pedidos.forma_pago IS 'Método de pago: efectivo, transferencia, cheque, cuenta_corriente, etc.';
COMMENT ON COLUMN pedidos.estado_pago IS 'Estado del pago: pendiente, pagado, parcial';

-- 2. Crear tabla para historial de cambios en pedidos
CREATE TABLE IF NOT EXISTS pedido_historial (
  id BIGSERIAL PRIMARY KEY,
  pedido_id BIGINT NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,
  usuario_id UUID REFERENCES perfiles(id) ON DELETE SET NULL,
  campo_modificado TEXT NOT NULL,
  valor_anterior TEXT,
  valor_nuevo TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índices para mejorar el rendimiento de consultas
CREATE INDEX IF NOT EXISTS idx_pedido_historial_pedido_id ON pedido_historial(pedido_id);
CREATE INDEX IF NOT EXISTS idx_pedido_historial_created_at ON pedido_historial(created_at DESC);

-- Comentario en la tabla
COMMENT ON TABLE pedido_historial IS 'Registro de todos los cambios realizados en los pedidos (auditoría)';

-- 3. Función para registrar automáticamente cambios en el historial
-- Esta función se ejecutará mediante un trigger cuando se actualice un pedido
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

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. Crear trigger para registrar cambios automáticamente
DROP TRIGGER IF EXISTS trigger_registrar_cambio_pedido ON pedidos;
CREATE TRIGGER trigger_registrar_cambio_pedido
  AFTER UPDATE ON pedidos
  FOR EACH ROW
  EXECUTE FUNCTION registrar_cambio_pedido();

-- 5. Registrar la creación inicial de pedidos en el historial
CREATE OR REPLACE FUNCTION registrar_creacion_pedido()
RETURNS TRIGGER AS $$
DECLARE
  usuario_actual UUID;
BEGIN
  BEGIN
    usuario_actual := current_setting('app.current_user_id', true)::UUID;
  EXCEPTION
    WHEN OTHERS THEN
      usuario_actual := NEW.usuario_id;
  END;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (NEW.id, COALESCE(usuario_actual, NEW.usuario_id), 'creacion', NULL, 'Pedido creado');

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger para registrar la creación de pedidos
DROP TRIGGER IF EXISTS trigger_registrar_creacion_pedido ON pedidos;
CREATE TRIGGER trigger_registrar_creacion_pedido
  AFTER INSERT ON pedidos
  FOR EACH ROW
  EXECUTE FUNCTION registrar_creacion_pedido();
