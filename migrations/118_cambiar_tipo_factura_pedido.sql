-- ============================================================================
-- 118 · cambiar_tipo_factura_pedido: flip FC ↔ ZZ con redistribución del
--       desglose (el total NO cambia)
-- ============================================================================
-- La decisión de facturar (FC) muchas veces llega al momento de emitir la
-- factura por fuera, después de creado (o entregado) el pedido. Cambiar el
-- tipo solo redistribuye neto/IVA/II dentro del mismo precio final:
-- cobranza, pagos y saldo del cliente quedan intactos.
--   · admin: cualquier estado salvo cancelado.
--   · encargado: solo antes de la entrega.
--   · Recalcula el desglose por ítem desde los atributos fiscales ACTUALES
--     del producto (post-backfill 112 son los correctos) y actualiza
--     total_neto/total_iva. Deja rastro en pedido_historial.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cambiar_tipo_factura_pedido(
  p_pedido_id bigint,
  p_tipo varchar,
  p_usuario_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_user_role TEXT;
  v_pedido RECORD;
  v_item RECORD;
  v_pct_iva NUMERIC; v_pct_ii NUMERIC;
  v_neto NUMERIC; v_iva NUMERIC; v_ii NUMERIC;
  v_total_neto NUMERIC := 0;
  v_total_iva NUMERIC := 0;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;
  IF p_tipo NOT IN ('ZZ', 'FC') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Tipo de factura inválido (ZZ o FC)');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado');
  END IF;

  SELECT id, estado, tipo_factura INTO v_pedido
    FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;
  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el tipo de un pedido cancelado');
  END IF;
  IF v_user_role = 'encargado' AND v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede cambiar el tipo de un pedido entregado');
  END IF;
  IF COALESCE(v_pedido.tipo_factura, 'ZZ') = p_tipo THEN
    RETURN jsonb_build_object('success', true, 'sin_cambio', true);
  END IF;

  FOR v_item IN
    SELECT pi.id, pi.cantidad, pi.precio_unitario, COALESCE(pi.es_bonificacion, false) AS es_bonif,
           COALESCE(pr.porcentaje_iva, 21) AS pct_iva, COALESCE(pr.impuestos_internos, 0) AS pct_ii
      FROM pedido_items pi
      JOIN productos pr ON pr.id = pi.producto_id AND pr.sucursal_id = pi.sucursal_id
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
    IF v_item.es_bonif THEN
      UPDATE pedido_items
         SET neto_unitario = 0, iva_unitario = 0, impuestos_internos_unitario = 0, porcentaje_iva = 0
       WHERE id = v_item.id;
    ELSE
      SELECT d.neto, d.iva, d.imp_internos INTO v_neto, v_iva, v_ii
        FROM calcular_desglose_venta(v_item.precio_unitario, v_item.pct_iva, v_item.pct_ii, p_tipo) d;
      UPDATE pedido_items
         SET neto_unitario = v_neto,
             iva_unitario = v_iva,
             impuestos_internos_unitario = v_ii,
             porcentaje_iva = CASE WHEN p_tipo = 'ZZ' THEN 0 ELSE v_item.pct_iva END
       WHERE id = v_item.id;
      v_total_neto := v_total_neto + v_item.cantidad * v_neto;
      v_total_iva  := v_total_iva  + v_item.cantidad * v_iva;
    END IF;
  END LOOP;

  UPDATE pedidos
     SET tipo_factura = p_tipo,
         total_neto = round(v_total_neto, 2),
         total_iva  = round(v_total_iva, 2),
         updated_at = NOW()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'tipo_factura', COALESCE(v_pedido.tipo_factura, 'ZZ'), p_tipo, v_sucursal);

  RETURN jsonb_build_object('success', true, 'pedido_id', p_pedido_id,
    'tipo_factura', p_tipo, 'total_neto', round(v_total_neto, 2), 'total_iva', round(v_total_iva, 2));
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.cambiar_tipo_factura_pedido(bigint, varchar, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.cambiar_tipo_factura_pedido(bigint, varchar, uuid) FROM anon, public;
