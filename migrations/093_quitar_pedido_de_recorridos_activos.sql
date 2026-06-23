-- 093_quitar_pedido_de_recorridos_activos.sql
--
-- Soporte para re-rutear pedidos no entregados. Cuando un pedido 'asignado' se
-- vuelve a 'pendiente' (boton "Volver a pendiente"), debe salir de la ruta
-- (recorrido) en curso a la que pertenece; si no, queda como parada fantasma en
-- la ruta de hoy aunque ya no se entregue ese dia.
--
-- recorrido_pedidos NO tiene policy de DELETE (solo INSERT/SELECT/UPDATE), asi
-- que el cliente no puede borrar la parada. Esta RPC SECURITY DEFINER lo hace,
-- con chequeo de rol (admin/encargado) y scope por sucursal. Solo toca
-- recorridos en_curso (no altera el historico de rutas finalizadas).

CREATE OR REPLACE FUNCTION public.quitar_pedido_de_recorridos_activos(p_pedido_id bigint)
RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_role     TEXT;
  v_borradas INT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  SELECT rol INTO v_role FROM perfiles WHERE id = auth.uid();
  IF v_role IS NULL OR v_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  DELETE FROM recorrido_pedidos rp
   USING recorridos r
   WHERE rp.recorrido_id = r.id
     AND rp.pedido_id = p_pedido_id
     AND rp.sucursal_id = v_sucursal
     AND r.estado = 'en_curso';
  GET DIAGNOSTICS v_borradas = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'paradas_eliminadas', v_borradas);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.quitar_pedido_de_recorridos_activos(bigint) TO authenticated;
