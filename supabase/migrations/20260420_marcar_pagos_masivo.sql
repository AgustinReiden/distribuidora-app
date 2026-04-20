-- ============================================================================
-- RPC: marcar_pagos_masivo
--
-- Reemplaza el loop cliente-side que hacia N+1 UPDATEs individuales.
-- Un solo UPDATE batch filtrado por sucursal activa y rol.
-- Los triggers existentes (audit_pedidos, trigger_registrar_cambio_pedido,
-- trigger_actualizar_estado_pago) registran el historial automaticamente.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.marcar_pagos_masivo(
  p_pedido_ids BIGINT[],
  p_forma_pago TEXT
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar pagos masivos'
      USING ERRCODE = '42501';
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE pedidos
     SET estado_pago = 'pagado',
         monto_pagado = total,
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$$;

COMMENT ON FUNCTION public.marcar_pagos_masivo IS
  'Marca multiples pedidos como pagados en batch. Restringido a encargado/admin '
  'y a la sucursal activa. Retorna cantidad de filas afectadas.';
