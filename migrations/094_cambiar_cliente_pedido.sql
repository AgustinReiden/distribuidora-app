-- 094_cambiar_cliente_pedido.sql
--
-- "Cambiar cliente" de un pedido cargado al cliente equivocado.
--
-- Caso: el usuario carga un pedido y elige mal el cliente. Hoy hay que recrearlo
-- a mano y borrar el viejo. Esta RPC lo hace en una sola operacion atomica:
-- cancela el pedido viejo (restaura stock + ajusta saldo del cliente viejo via
-- los triggers de cancelacion), lo saca de la ruta en curso si estaba asignado,
-- crea un pedido nuevo IDENTICO para el cliente correcto (con precios ya
-- recalculados en el front para ESE cliente) y transfiere los pagos del viejo al
-- nuevo.
--
-- Por que cancelar+recrear y no UPDATE cliente_id: el trigger
-- actualizar_saldo_pedido en su rama UPDATE solo ajusta el saldo de
-- NEW.cliente_id; un cambio directo de cliente_id dejaria la deuda pegada al
-- cliente viejo. Cancelar (baja la contribucion del viejo) + crear (suma la del
-- nuevo) dispara las ramas correctas y mueve el saldo solo.
--
-- Transferencia de pagos: un pago con pedido_id NO afecta saldo directo (lo hace
-- via monto_pagado del pedido, trigger recalcular_monto_pagado_pedido). Por eso
-- mover el pago es un simple UPDATE pagos SET pedido_id/cliente_id y los triggers
-- reajustan monto_pagado del nuevo y el saldo de ambos clientes.
--
-- Atomicidad: si crear_pedido_completo falla (ej. stock), se hace RAISE para
-- revertir TODA la transaccion, incluida la cancelacion -> el pedido viejo queda
-- intacto.
--
-- Solo admin. No aplica a pedidos entregados ni cancelados.

CREATE OR REPLACE FUNCTION public.cambiar_cliente_pedido(
  p_pedido_id bigint,
  p_nuevo_cliente_id bigint,
  p_usuario_id uuid,
  p_items jsonb,
  p_total numeric,
  p_total_neto numeric DEFAULT NULL,
  p_total_iva numeric DEFAULT 0,
  p_motivo text DEFAULT 'Cambio de cliente'
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal     BIGINT := current_sucursal_id();
  v_acting       UUID := auth.uid();
  v_role         TEXT;
  v_pedido       RECORD;
  v_prev_role    TEXT;
  v_preventista  UUID := NULL;            -- preventista del pedido nuevo (NULL = actor)
  v_preventista_fallback BOOLEAN := false;
  v_cancel       JSONB;
  v_crear        JSONB;
  v_nuevo_id     BIGINT;
BEGIN
  -- ---- Validaciones ----
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM v_acting THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_role FROM perfiles WHERE id = v_acting;
  IF v_role IS NULL OR v_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cambiar el cliente de un pedido');
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido nuevo no tiene items');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF v_pedido.estado IN ('entregado', 'cancelado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cambiar el cliente de un pedido ' || v_pedido.estado);
  END IF;

  IF p_nuevo_cliente_id = v_pedido.cliente_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo es el mismo que el actual');
  END IF;

  PERFORM 1 FROM clientes WHERE id = p_nuevo_cliente_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'El cliente nuevo no existe en esta sucursal');
  END IF;

  -- ---- Resolver preventista del pedido nuevo (conservar el del viejo) ----
  -- Si el preventista original sigue siendo asignable, se conserva (comisiones);
  -- si no (inactivo o fuera de la sucursal), el nuevo queda a nombre del actor.
  IF v_pedido.usuario_id IS DISTINCT FROM p_usuario_id THEN
    SELECT p.rol INTO v_prev_role
    FROM perfiles p
    WHERE p.id = v_pedido.usuario_id
      AND p.activo = true
      AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal);
    IF v_prev_role IN ('admin', 'preventista', 'preventista_taco') THEN
      v_preventista := v_pedido.usuario_id;
    ELSE
      v_preventista_fallback := true;     -- no asignable -> queda al actor
    END IF;
  END IF;

  -- ---- 1) Cancelar el pedido viejo (restaura stock, baja usos promo, ajusta saldo cliente viejo) ----
  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id);
  IF NOT COALESCE((v_cancel->>'success')::boolean, false) THEN
    RETURN v_cancel;   -- propaga el error (nada irreversible hecho aun)
  END IF;

  -- ---- 2) Sacar el pedido viejo de la ruta en curso (si estaba asignado) ----
  PERFORM quitar_pedido_de_recorridos_activos(p_pedido_id);

  -- ---- 3) Crear el pedido nuevo para el cliente correcto ----
  -- Preserva notas/forma_pago/fecha/tipo_factura/fecha_entrega_programada del viejo.
  v_crear := crear_pedido_completo(
    p_nuevo_cliente_id,
    p_total,
    p_usuario_id,
    p_items,
    v_pedido.notas,
    v_pedido.forma_pago,
    'pendiente',                          -- estado_pago se deriva al transferir pagos
    v_pedido.fecha,
    v_pedido.tipo_factura,
    p_total_neto,
    COALESCE(p_total_iva, 0),
    v_pedido.fecha_entrega_programada,
    v_preventista
  );
  IF NOT COALESCE((v_crear->>'success')::boolean, false) THEN
    -- Revertir TODA la transaccion (incluida la cancelacion del viejo).
    RAISE EXCEPTION 'No se pudo crear el pedido nuevo: %',
      COALESCE(v_crear->>'errores', v_crear->>'error', 'error desconocido');
  END IF;
  v_nuevo_id := (v_crear->>'pedido_id')::bigint;

  -- ---- 4) Transferir pagos del viejo al nuevo (triggers reajustan monto_pagado y saldos) ----
  UPDATE pagos
     SET pedido_id = v_nuevo_id,
         cliente_id = p_nuevo_cliente_id
   WHERE pedido_id = p_pedido_id
     AND sucursal_id = v_sucursal;

  -- ---- 5) Trazabilidad: referencia cruzada en el viejo y en el historial del nuevo ----
  UPDATE pedidos
     SET motivo_cancelacion = COALESCE(motivo_cancelacion, p_motivo) || ' -> pedido #' || v_nuevo_id
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    v_nuevo_id,
    v_acting,
    'cliente_id',
    v_pedido.cliente_id::text,
    p_nuevo_cliente_id::text || ' (cambio de cliente desde pedido #' || p_pedido_id || ')',
    v_sucursal
  );

  RETURN jsonb_build_object(
    'success', true,
    'nuevo_pedido_id', v_nuevo_id,
    'pedido_cancelado_id', p_pedido_id,
    'preventista_fallback', v_preventista_fallback
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text) TO authenticated;
