-- Fix: rendicion_items INSERT en crear_rendicion_recorrido
-- El INSERT de items no filtraba por p.estado = 'entregado',
-- causando que se incluyeran pedidos no entregados en el detalle.

CREATE OR REPLACE FUNCTION crear_rendicion_recorrido(
  p_recorrido_id BIGINT,
  p_transportista_id UUID DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
  v_transportista_real UUID;
  v_es_admin BOOLEAN;
BEGIN
  -- Verificar si es admin
  v_es_admin := es_admin_rendiciones();

  -- Si es admin y no se especifica transportista, obtenerlo del recorrido
  IF v_es_admin THEN
    IF p_transportista_id IS NULL THEN
      SELECT transportista_id INTO v_transportista_real
      FROM recorridos WHERE id = p_recorrido_id;
    ELSE
      v_transportista_real := p_transportista_id;
    END IF;
  ELSE
    v_transportista_real := auth.uid();
  END IF;

  -- Verificar que el recorrido existe y pertenece al transportista (o es admin)
  IF NOT EXISTS (
    SELECT 1 FROM recorridos
    WHERE id = p_recorrido_id
    AND (transportista_id = v_transportista_real OR v_es_admin)
  ) THEN
    RAISE EXCEPTION 'Recorrido no válido o no pertenece al transportista';
  END IF;

  -- Verificar que no existe ya una rendición para este recorrido
  IF EXISTS (SELECT 1 FROM rendiciones WHERE recorrido_id = p_recorrido_id) THEN
    RAISE EXCEPTION 'Ya existe una rendición para este recorrido';
  END IF;

  -- Calcular totales por forma de pago de pedidos entregados
  FOR v_pedido IN
    SELECT p.id, COALESCE(p.monto_pagado, 0) as monto_pagado, COALESCE(p.forma_pago, 'efectivo') as forma_pago
    FROM pedidos p
    JOIN recorrido_pedidos rp ON rp.pedido_id = p.id
    WHERE rp.recorrido_id = p_recorrido_id
    AND rp.estado_entrega = 'entregado'
    AND p.estado = 'entregado'
  LOOP
    IF v_pedido.forma_pago = 'efectivo' THEN
      v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE
      v_total_otros := v_total_otros + v_pedido.monto_pagado;
    END IF;
  END LOOP;

  -- Crear la rendición
  INSERT INTO rendiciones (
    recorrido_id,
    transportista_id,
    fecha,
    total_efectivo_esperado,
    total_otros_medios,
    estado
  ) VALUES (
    p_recorrido_id,
    v_transportista_real,
    CURRENT_DATE,
    v_total_efectivo,
    v_total_otros,
    'pendiente'
  )
  RETURNING id INTO v_rendicion_id;

  -- Crear items de rendición para cada pedido entregado
  -- FIX: agregar filtro p.estado = 'entregado' para consistencia con el calculo de totales
  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago)
  SELECT
    v_rendicion_id,
    p.id,
    COALESCE(p.monto_pagado, 0),
    COALESCE(p.forma_pago, 'efectivo')
  FROM pedidos p
  JOIN recorrido_pedidos rp ON rp.pedido_id = p.id
  WHERE rp.recorrido_id = p_recorrido_id
  AND rp.estado_entrega = 'entregado'
  AND p.estado = 'entregado';

  RETURN v_rendicion_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
