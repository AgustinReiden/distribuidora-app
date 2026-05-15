-- =========================================================================
-- 053_editar_forma_pago_pago.sql
--
-- Permite a admin y encargado corregir la forma de pago de un pago ya
-- registrado en la tabla `pagos`, siempre que la rendicion del dia del pago
-- no este cerrada (confirmada/resuelta) en la sucursal activa.
--
-- Caso de uso: el operador marco un pedido pagado con la forma de pago
-- equivocada (ej. "efectivo" cuando era "transferencia") y necesita
-- corregirla sin tener que anular y re-registrar el pago (lo cual rompe
-- la fecha original y el rastro de auditoria).
--
-- Reglas:
--   - Solo admin o encargado (es_encargado_o_admin()).
--   - La rendicion del dia del pago no debe estar cerrada, NI para admin ni
--     para encargado (bloqueo unificado pedido por el usuario).
--   - El pago debe pertenecer a la sucursal activa.
--   - Forma de pago nueva debe estar en lista valida.
--   - Se sincroniza `pedidos.forma_pago` (denormalizado) al forma_pago del
--     pago con mayor monto del pedido. En empate gana el mas reciente por
--     created_at. Esto mantiene consistentes los reportes que leen
--     `pedidos.forma_pago` (rendicion_items, vistas legacy).
--   - Se inserta una fila en pedido_historial con campo_modificado =
--     'forma_pago_pago_<id>' para trazabilidad fina. El trigger BEFORE
--     existente en pedidos ya registra el cambio del campo denormalizado
--     `pedidos.forma_pago` cuando corresponde.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.actualizar_forma_pago_pago(
  p_pago_id bigint,
  p_forma_pago text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id bigint;
  v_pago RECORD;
  v_forma_anterior text;
  v_nueva_forma_pedido text;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden modificar la forma de pago'
      USING ERRCODE = '42501';
  END IF;

  IF p_forma_pago NOT IN (
    'efectivo', 'transferencia', 'cheque',
    'cuenta_corriente', 'tarjeta', 'vale_blanco'
  ) THEN
    RAISE EXCEPTION 'Forma de pago invalida: %', p_forma_pago
      USING ERRCODE = '22023';
  END IF;

  SELECT id, pedido_id, fecha, forma_pago
    INTO v_pago
    FROM pagos
   WHERE id = p_pago_id
     AND sucursal_id = v_sucursal_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pago no encontrado' USING ERRCODE = 'P0002';
  END IF;

  v_forma_anterior := COALESCE(v_pago.forma_pago, 'efectivo');

  IF v_forma_anterior = p_forma_pago THEN
    -- No-op: nada que cambiar.
    RETURN jsonb_build_object(
      'success', true,
      'pago_id', v_pago.id,
      'forma_pago_anterior', v_forma_anterior,
      'forma_pago_nueva', p_forma_pago,
      'pedido_forma_pago', NULL
    );
  END IF;

  -- Bloqueo unificado: ni admin ni encargado pueden editar si la rendicion
  -- del dia del pago ya esta cerrada (confirmada/resuelta).
  IF public.rendicion_dia_cerrada(v_pago.fecha, v_sucursal_id) THEN
    RAISE EXCEPTION 'Rendicion ya cerrada para esta fecha. No se puede modificar.'
      USING ERRCODE = '42501';
  END IF;

  UPDATE pagos
     SET forma_pago = p_forma_pago
   WHERE id = p_pago_id;

  -- Sincronizar pedidos.forma_pago si el pago esta asociado a un pedido.
  -- Toma la forma_pago del pago de mayor monto; en empate, el mas reciente.
  IF v_pago.pedido_id IS NOT NULL THEN
    SELECT forma_pago
      INTO v_nueva_forma_pedido
      FROM pagos
     WHERE pedido_id = v_pago.pedido_id
     ORDER BY monto DESC NULLS LAST, created_at DESC NULLS LAST
     LIMIT 1;

    UPDATE pedidos
       SET forma_pago = COALESCE(v_nueva_forma_pedido, p_forma_pago),
           updated_at = now()
     WHERE id = v_pago.pedido_id
       AND sucursal_id = v_sucursal_id;

    -- Trazabilidad fina del cambio puntual en `pagos`. El trigger BEFORE en
    -- pedidos ya graba el cambio de `pedidos.forma_pago` si aplica.
    INSERT INTO pedido_historial (
      pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id
    )
    VALUES (
      v_pago.pedido_id,
      auth.uid(),
      'forma_pago_pago_' || v_pago.id::text,
      v_forma_anterior,
      p_forma_pago,
      v_sucursal_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'pago_id', v_pago.id,
    'forma_pago_anterior', v_forma_anterior,
    'forma_pago_nueva', p_forma_pago,
    'pedido_forma_pago', v_nueva_forma_pedido
  );
END;
$$;

ALTER FUNCTION public.actualizar_forma_pago_pago(bigint, text) OWNER TO postgres;
COMMENT ON FUNCTION public.actualizar_forma_pago_pago(bigint, text) IS
  'Corrige la forma de pago de una fila de pagos. Admin/encargado, bloqueado si la rendicion del dia del pago esta cerrada. Resincroniza pedidos.forma_pago (denormalizado) al pago de mayor monto del pedido.';

GRANT EXECUTE ON FUNCTION public.actualizar_forma_pago_pago(bigint, text)
  TO authenticated;

COMMIT;
