-- Migración 084: fecha de entrega elegible en aplicar_orden_ruta
--
-- La ruta del día se arma generalmente el día anterior. El admin ahora elige
-- la fecha de entrega (de hoy en adelante). aplicar_orden_ruta acepta p_fecha
-- (default CURRENT_DATE para compat); el recorrido se crea con esa fecha y la
-- cancelación del vigente del día se hace sobre la misma fecha.
--
-- Aplicada en prod el 2026-06-15 vía MCP (apply_migration:
-- aplicar_orden_ruta_fecha) y verificada con rollback (fecha futura + default).

DROP FUNCTION IF EXISTS public.aplicar_orden_ruta(uuid, jsonb, numeric, integer, jsonb);

CREATE OR REPLACE FUNCTION public.aplicar_orden_ruta(
  p_transportista_id uuid,
  p_pedidos jsonb,
  p_distancia numeric DEFAULT NULL,
  p_duracion integer DEFAULT NULL,
  p_polylines jsonb DEFAULT NULL,
  p_fecha date DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_fecha date := COALESCE(p_fecha, CURRENT_DATE);
  v_item jsonb;
  v_recorrido_id BIGINT;
  v_total_facturado DECIMAL := 0;
BEGIN
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

  -- 2. Cancelar el recorrido vigente de ESA fecha (si lo hay)
  UPDATE recorridos
  SET estado = 'cancelado'
  WHERE transportista_id = p_transportista_id
    AND fecha = v_fecha
    AND estado = 'en_curso'
    AND sucursal_id = v_sucursal;

  -- 3. Crear el recorrido nuevo con la fecha elegida
  SELECT COALESCE(SUM(total), 0) INTO v_total_facturado
  FROM pedidos
  WHERE id IN (SELECT (value->>'pedido_id')::BIGINT FROM jsonb_array_elements(p_pedidos))
    AND sucursal_id = v_sucursal;

  INSERT INTO recorridos
    (transportista_id, fecha, distancia_total, duracion_total, total_pedidos,
     total_facturado, estado, sucursal_id, polylines)
  VALUES
    (p_transportista_id, v_fecha, p_distancia, p_duracion,
     jsonb_array_length(p_pedidos), v_total_facturado, 'en_curso', v_sucursal, p_polylines)
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

REVOKE ALL ON FUNCTION public.aplicar_orden_ruta(uuid, jsonb, numeric, integer, jsonb, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.aplicar_orden_ruta(uuid, jsonb, numeric, integer, jsonb, date) TO authenticated;
