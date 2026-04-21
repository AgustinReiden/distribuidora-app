-- Migracion: Agregar funcion RPC para actualizar orden_entrega en batch
-- Fecha: 2026-01-03
-- Descripcion: Funcion RPC mas eficiente y confiable para actualizar orden de entrega

-- 1. Primero asegurarse de que la columna existe (idempotente)
ALTER TABLE pedidos
ADD COLUMN IF NOT EXISTS orden_entrega INTEGER;

-- 2. Comentario para documentar el campo
COMMENT ON COLUMN pedidos.orden_entrega IS 'Orden de entrega optimizado por Google Routes API (1 = primera entrega, 2 = segunda, etc.)';

-- 3. Crear indice si no existe
CREATE INDEX IF NOT EXISTS idx_pedidos_transportista_orden ON pedidos(transportista_id, orden_entrega)
WHERE transportista_id IS NOT NULL AND orden_entrega IS NOT NULL;

-- 4. Crear tipo para el parametro de la funcion
DROP TYPE IF EXISTS orden_entrega_item CASCADE;
CREATE TYPE orden_entrega_item AS (
  pedido_id BIGINT,
  orden INTEGER
);

-- 5. Funcion RPC para actualizar orden_entrega en batch
-- Esta funcion es mas eficiente que hacer N updates individuales
CREATE OR REPLACE FUNCTION actualizar_orden_entrega_batch(ordenes orden_entrega_item[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  item orden_entrega_item;
BEGIN
  -- Iterar sobre cada item y actualizar
  FOREACH item IN ARRAY ordenes
  LOOP
    UPDATE pedidos
    SET orden_entrega = item.orden
    WHERE id = item.pedido_id;
  END LOOP;
END;
$$;

-- 6. Dar permisos a usuarios autenticados
GRANT EXECUTE ON FUNCTION actualizar_orden_entrega_batch(orden_entrega_item[]) TO authenticated;

-- 7. Funcion alternativa que acepta JSON (mas compatible con Supabase JS)
CREATE OR REPLACE FUNCTION actualizar_orden_entrega_batch(ordenes JSONB)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  item JSONB;
BEGIN
  -- Iterar sobre cada item del array JSON
  FOR item IN SELECT * FROM jsonb_array_elements(ordenes)
  LOOP
    UPDATE pedidos
    SET orden_entrega = (item->>'orden')::INTEGER
    WHERE id = (item->>'pedido_id')::BIGINT;
  END LOOP;
END;
$$;

-- 8. Dar permisos a usuarios autenticados para la version JSON
GRANT EXECUTE ON FUNCTION actualizar_orden_entrega_batch(JSONB) TO authenticated;

-- 9. Funcion para limpiar orden_entrega de un transportista
CREATE OR REPLACE FUNCTION limpiar_orden_entrega(p_transportista_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE pedidos
  SET orden_entrega = NULL
  WHERE transportista_id = p_transportista_id;
END;
$$;

GRANT EXECUTE ON FUNCTION limpiar_orden_entrega(UUID) TO authenticated;
