-- Migración 070: gates de rol/sucursal en RPCs mutadoras/lectura sin protección (Auditoría 2026-05, P1-3/P1-4)
-- Reversible (recrea funciones). No toca datos.
-- Contexto: estas funciones SECURITY DEFINER bypassan RLS y no validaban rol ni sucursal.
--   069 ya cerró el acceso anónimo; 070 agrega el gate de rol + scope de sucursal.
-- Verificado: ninguna función interna las llama (no rompe cadenas de definer);
--   actualizar_orden_entrega_batch se usa en la optimización de ruta (usePedidos.ts:470).
-- Roles permitidos: orden de entrega -> encargado/admin/transportista; resumen compras -> encargado/admin.

-- ============================================================
-- P1-3: orden de entrega — gate de rol + scope de sucursal
-- ============================================================
CREATE OR REPLACE FUNCTION public.actualizar_orden_entrega_batch(ordenes jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  item JSONB;
BEGIN
  IF NOT (es_encargado_o_admin() OR es_transportista()) THEN
    RAISE EXCEPTION 'No autorizado para reordenar entregas';
  END IF;
  FOR item IN SELECT * FROM jsonb_array_elements(ordenes)
  LOOP
    UPDATE pedidos
    SET orden_entrega = (item->>'orden')::INTEGER
    WHERE id = (item->>'pedido_id')::BIGINT
      AND sucursal_id = current_sucursal_id();
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.actualizar_orden_entrega_batch(ordenes orden_entrega_item[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  item orden_entrega_item;
BEGIN
  IF NOT (es_encargado_o_admin() OR es_transportista()) THEN
    RAISE EXCEPTION 'No autorizado para reordenar entregas';
  END IF;
  FOREACH item IN ARRAY ordenes
  LOOP
    UPDATE pedidos
    SET orden_entrega = item.orden
    WHERE id = item.pedido_id
      AND sucursal_id = current_sucursal_id();
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.limpiar_orden_entrega(p_transportista_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (es_encargado_o_admin() OR es_transportista()) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  UPDATE pedidos
  SET orden_entrega = NULL
  WHERE transportista_id = p_transportista_id
    AND sucursal_id = current_sucursal_id();
END;
$function$;

-- ============================================================
-- P1-4: resumen de compras — filtrar por sucursal + gate de rol
-- ============================================================
CREATE OR REPLACE FUNCTION public.obtener_resumen_compras(p_fecha_desde date DEFAULT NULL::date, p_fecha_hasta date DEFAULT NULL::date)
RETURNS TABLE(total_compras bigint, monto_total numeric, promedio_compra numeric, productos_comprados bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  RETURN QUERY
  SELECT
    COUNT(DISTINCT c.id)::BIGINT as total_compras,
    COALESCE(SUM(c.total), 0)::DECIMAL as monto_total,
    COALESCE(AVG(c.total), 0)::DECIMAL as promedio_compra,
    COALESCE(SUM(ci.cantidad), 0)::BIGINT as productos_comprados
  FROM compras c
  LEFT JOIN compra_items ci ON c.id = ci.compra_id
  WHERE c.estado != 'cancelada'
    AND c.sucursal_id = current_sucursal_id()
    AND (p_fecha_desde IS NULL OR c.fecha_compra >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR c.fecha_compra <= p_fecha_hasta);
END;
$function$;
