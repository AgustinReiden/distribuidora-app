-- Migración 081: RPC aplicar_orden_ruta
--
-- El flujo de "Aplicar Orden" del modal de gestión de rutas llamaba a una RPC
-- inexistente (actualizar_orden_entrega) sin chequear el error: el orden
-- optimizado nunca se persistía y nunca se creaban recorridos (la tabla
-- recorridos estaba en 0 filas).
--
-- Esta RPC hace todo en una transacción:
--   1. Actualiza pedidos.orden_entrega (scoped a la sucursal actual).
--   2. Cancela el recorrido 'en_curso' del día del transportista si existe
--      (diseño: UN recorrido vigente por transportista por día; el anterior
--      queda como 'cancelado' a modo de historial).
--   3. Crea el recorrido nuevo + recorrido_pedidos con distancia/duración.
--
-- El progreso del recorrido (entregados/cobrado) lo mantiene el trigger
-- existente trigger_actualizar_recorrido_entrega sobre pedidos.
--
-- Aplicada en prod el 2026-06-12 vía MCP (apply_migration: aplicar_orden_ruta)
-- y verificada en vivo con rollback: aplica orden, cancela el recorrido
-- anterior al reaplicar, y el gate bloquea a transportistas (42501).

CREATE OR REPLACE FUNCTION public.aplicar_orden_ruta(
  p_transportista_id uuid,
  p_pedidos jsonb,            -- [{ "pedido_id": 123, "orden_entrega": 1 }, ...]
  p_distancia numeric DEFAULT NULL,
  p_duracion integer DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item jsonb;
  v_recorrido_id BIGINT;
  v_total_facturado DECIMAL := 0;
BEGIN
  -- Gate de rol (mismo patrón que mig 070)
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para aplicar orden de ruta' USING ERRCODE = '42501';
  END IF;

  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;

  IF p_pedidos IS NULL OR jsonb_array_length(p_pedidos) = 0 THEN
    RAISE EXCEPTION 'No hay pedidos para aplicar orden';
  END IF;

  -- 1. Actualizar orden de entrega en pedidos
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_pedidos) LOOP
    UPDATE pedidos
    SET orden_entrega = (v_item->>'orden_entrega')::INTEGER
    WHERE id = (v_item->>'pedido_id')::BIGINT
      AND sucursal_id = v_sucursal;
  END LOOP;

  -- 2. Cancelar el recorrido vigente del día (si lo hay)
  UPDATE recorridos
  SET estado = 'cancelado'
  WHERE transportista_id = p_transportista_id
    AND fecha = CURRENT_DATE
    AND estado = 'en_curso'
    AND sucursal_id = v_sucursal;

  -- 3. Crear el recorrido nuevo
  SELECT COALESCE(SUM(total), 0) INTO v_total_facturado
  FROM pedidos
  WHERE id IN (SELECT (value->>'pedido_id')::BIGINT FROM jsonb_array_elements(p_pedidos))
    AND sucursal_id = v_sucursal;

  INSERT INTO recorridos
    (transportista_id, fecha, distancia_total, duracion_total, total_pedidos,
     total_facturado, estado, sucursal_id)
  VALUES
    (p_transportista_id, CURRENT_DATE, p_distancia, p_duracion,
     jsonb_array_length(p_pedidos), v_total_facturado, 'en_curso', v_sucursal)
  RETURNING id INTO v_recorrido_id;

  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, sucursal_id)
  SELECT v_recorrido_id,
         (value->>'pedido_id')::BIGINT,
         (value->>'orden_entrega')::INTEGER,
         v_sucursal
  FROM jsonb_array_elements(p_pedidos);

  RETURN v_recorrido_id;
END;
$$;

REVOKE ALL ON FUNCTION public.aplicar_orden_ruta(uuid, jsonb, numeric, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.aplicar_orden_ruta(uuid, jsonb, numeric, integer) TO authenticated;
