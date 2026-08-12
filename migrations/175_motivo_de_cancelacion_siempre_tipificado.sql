-- =========================================================================
-- 175_motivo_de_cancelacion_siempre_tipificado.sql
--
-- La mig 143 puso una lista cerrada de motivos de cancelación para poder
-- medir por qué no se entrega. Desde su backfill (27/07) se filtraron 9
-- cancelaciones sin tipificar, por tres caminos distintos:
--
--   1. `cambiar_cliente_pedido` cancela el pedido viejo llamando a
--      `cancelar_pedido_con_stock`, que no sabe de tipos. Nunca estampa uno.
--      Es un agujero permanente: 4 de las 9 (#4478, #4516, #4660, #4690) y
--      sigue sumando una por cada cambio de cliente.
--
--   2. El front guardaba el tipo con un UPDATE aparte, después del RPC. Va
--      por PostgREST con la sesión del usuario y sobre un pedido que ya
--      quedó cancelado, así que cualquier RLS o guarda lo rechaza; el catch
--      solo hacía console.error. El pedido queda cancelado y sin motivo, sin
--      que nadie se entere.
--
--   3. Pestañas con un bundle anterior al 27/07, que todavía mandaban texto
--      libre (#4549, #4552, #4555, #4572 el 10/08). Eso lo ataca el aviso de
--      versión nueva, no esta migración.
--
-- Acá se cierran 1 y 2, y se backfillean las 9.
--
-- Idempotente (CREATE OR REPLACE + DROP/ADD del CHECK).
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. El cambio de cliente es un motivo real y le faltaba lugar en la lista.
--    No es elegible en el desplegable: lo estampa solo el sistema.
-- -------------------------------------------------------------------------
ALTER TABLE public.pedidos
  DROP CONSTRAINT IF EXISTS pedidos_motivo_cancelacion_tipo_check;

ALTER TABLE public.pedidos
  ADD CONSTRAINT pedidos_motivo_cancelacion_tipo_check
  CHECK (motivo_cancelacion_tipo IS NULL OR motivo_cancelacion_tipo IN (
    'cerrado', 'sin_dinero', 'cliente_rechaza', 'ausente',
    'direccion_incorrecta', 'clima',
    'cliente_cancelo', 'error_de_carga', 'duplicado', 'unifica_pedidos',
    'prueba', 'cambio_de_cliente', 'otro'
  ));

COMMENT ON COLUMN public.pedidos.motivo_cancelacion_tipo IS
  'Motivo de cancelación tipificado. `motivo_cancelacion` (text) queda como nota complementaria. Migs 143 y 175.';

-- -------------------------------------------------------------------------
-- 2. cancelar_pedido_con_stock escribe el tipo en la misma transacción.
--    Antes el front lo hacía aparte y podía perderse en silencio.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancelar_pedido_con_stock(
  p_pedido_id  bigint,
  p_motivo     text,
  p_usuario_id uuid DEFAULT NULL::uuid,
  p_tipo       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD;
  v_item RECORD;
  v_total_original DECIMAL;
  v_user_role TEXT;
  v_acting_user uuid;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_acting_user := auth.uid();
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM v_acting_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user;
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cancelar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado');
  END IF;

  IF v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  v_total_original := v_pedido.total;

  FOR v_item IN
    SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
           pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
    FROM pedido_items pi
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
    WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
    IF v_item.es_bonificacion THEN
      IF v_item.promocion_id IS NOT NULL THEN
        UPDATE promociones
        SET usos_pendientes = GREATEST(usos_pendientes - v_item.cantidad, 0)
        WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
      END IF;
      IF v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad
      WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      -- NULL deja el tipo como estaba: quien no manda tipo no lo pisa.
      motivo_cancelacion_tipo = COALESCE(p_tipo, motivo_cancelacion_tipo),
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    p_pedido_id,
    v_acting_user,
    'estado',
    v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original,
    v_sucursal
  );

  RETURN jsonb_build_object(
    'success', true,
    'mensaje', 'Pedido cancelado, stock restaurado, saldo ajustado',
    'total_original', v_total_original
  );
END;
$fn$;

ALTER FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.cancelar_pedido_con_stock(bigint, text, uuid, text) IS
  'Cancela un pedido, restaura stock y estampa el motivo tipificado en la misma transaccion. Mig 175.';

-- -------------------------------------------------------------------------
-- 3. Se elimina la firma vieja de 3 args.
--
--    NO puede quedar como wrapper: con f(a,b,c) y f(a,b,c,d DEFAULT) vivas a
--    la vez, una llamada de 3 argumentos es ambigua y Postgres tira
--    "function cancelar_pedido_con_stock is not unique". Justo lo que hace
--    `cambiar_cliente_pedido` y lo que mandan los bundles viejos.
--
--    Sacarla no rompe a nadie: PostgREST resuelve por nombre de parámetro, y
--    un cliente que mande {p_pedido_id, p_motivo, p_usuario_id} matchea la de
--    4 args tomando p_tipo del default.
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.cancelar_pedido_con_stock(bigint, text, uuid);

-- -------------------------------------------------------------------------
-- 4. El cambio de cliente deja de ser un hueco en el reporte.
--    Unico cambio respecto de la mig 094: pasa el tipo al cancelar.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cambiar_cliente_pedido(
  p_pedido_id        bigint,
  p_nuevo_cliente_id bigint,
  p_usuario_id       uuid,
  p_items            jsonb,
  p_total            numeric,
  p_total_neto       numeric DEFAULT NULL::numeric,
  p_total_iva        numeric DEFAULT 0,
  p_motivo           text    DEFAULT 'Cambio de cliente'::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal     BIGINT := current_sucursal_id();
  v_acting       UUID := auth.uid();
  v_role         TEXT;
  v_pedido       RECORD;
  v_prev_role    TEXT;
  v_preventista  UUID := NULL;
  v_preventista_fallback BOOLEAN := false;
  v_cancel       JSONB;
  v_crear        JSONB;
  v_nuevo_id     BIGINT;
BEGIN
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

  IF v_pedido.usuario_id IS DISTINCT FROM p_usuario_id THEN
    SELECT p.rol INTO v_prev_role
    FROM perfiles p
    WHERE p.id = v_pedido.usuario_id
      AND p.activo = true
      AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = v_sucursal);
    IF v_prev_role IN ('admin', 'preventista') THEN
      v_preventista := v_pedido.usuario_id;
    ELSE
      v_preventista_fallback := true;
    END IF;
  END IF;

  v_cancel := cancelar_pedido_con_stock(p_pedido_id, p_motivo, p_usuario_id, 'cambio_de_cliente');
  IF NOT COALESCE((v_cancel->>'success')::boolean, false) THEN
    RETURN v_cancel;
  END IF;

  PERFORM quitar_pedido_de_recorridos_activos(p_pedido_id);

  v_crear := crear_pedido_completo(
    p_nuevo_cliente_id,
    p_total,
    p_usuario_id,
    p_items,
    v_pedido.notas,
    v_pedido.forma_pago,
    'pendiente',
    v_pedido.fecha,
    v_pedido.tipo_factura,
    p_total_neto,
    COALESCE(p_total_iva, 0),
    v_pedido.fecha_entrega_programada,
    v_preventista
  );
  IF NOT COALESCE((v_crear->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'No se pudo crear el pedido nuevo: %',
      COALESCE(v_crear->>'errores', v_crear->>'error', 'error desconocido');
  END IF;
  v_nuevo_id := (v_crear->>'pedido_id')::bigint;

  UPDATE pagos
     SET pedido_id = v_nuevo_id,
         cliente_id = p_nuevo_cliente_id
   WHERE pedido_id = p_pedido_id
     AND sucursal_id = v_sucursal;

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
$fn$;

ALTER FUNCTION public.cambiar_cliente_pedido(bigint, bigint, uuid, jsonb, numeric, numeric, numeric, text) OWNER TO postgres;

-- -------------------------------------------------------------------------
-- 5. Backfill de lo que se filtró. Mismos criterios que la mig 143, aplicados
--    solo a las que quedaron en NULL, así no se pisa nada ya clasificado.
-- -------------------------------------------------------------------------
UPDATE pedidos SET motivo_cancelacion_tipo = CASE
  WHEN motivo_cancelacion ~* 'cambio de cliente'                        THEN 'cambio_de_cliente'
  WHEN motivo_cancelacion ~* 'cerrad'                                   THEN 'cerrado'
  WHEN motivo_cancelacion ~* 'sin plata|no ten(i|í)a plata|sin dinero'  THEN 'sin_dinero'
  WHEN motivo_cancelacion ~* 'prueba'                                   THEN 'prueba'
  WHEN motivo_cancelacion ~* 'rechaz'                                   THEN 'cliente_rechaza'
  WHEN motivo_cancelacion ~* 'unifica'                                  THEN 'unifica_pedidos'
  WHEN motivo_cancelacion ~* 'duplicad'                                 THEN 'duplicado'
  WHEN motivo_cancelacion ~* 'clima|lluvia'                             THEN 'clima'
  WHEN motivo_cancelacion ~* 'no hab(i|í)a nadie|ausente'               THEN 'ausente'
  WHEN motivo_cancelacion ~* 'direcci(o|ó)n'                            THEN 'direccion_incorrecta'
  WHEN motivo_cancelacion ~* 'error de carga|mal cargad'                THEN 'error_de_carga'
  ELSE motivo_cancelacion_tipo
END
WHERE estado = 'cancelado'
  AND motivo_cancelacion_tipo IS NULL
  AND motivo_cancelacion IS NOT NULL;
