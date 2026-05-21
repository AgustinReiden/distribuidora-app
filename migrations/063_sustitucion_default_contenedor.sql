-- =========================================================================
-- 063_sustitucion_default_contenedor.sql
--
-- Dos fixes complementarios al PR #334:
--
-- 1) RPC sustituir_regalo_pedido: cuando admin no indica contenedor del
--    sustituto, usar producto_sustituto_id como default (auto-inferencia).
--    En el 99% de los casos el producto regalo y su contenedor son el
--    mismo (ej: MANAOS POMELO BLANCO 3000 cc x 6 es a la vez el regalo y
--    el fardo a descontar). Antes pasaba NULL si no se elegia, dejando
--    al acumulador sin contenedor (no se descontaba nunca al cerrar bloque).
--
-- 2) Reconciliacion de acumuladores existentes con ajuste_producto_id mal
--    asignado o NULL: si un acumulador apunta a un contenedor distinto al
--    propio producto_regalo_id y la promo asociada tiene
--    producto_regalo_id = ajuste_producto_id (auto-contenedor), corregir
--    el acumulador para que use el propio producto_regalo_id.
-- =========================================================================

BEGIN;

-- 1) Refactor sustituir_regalo_pedido: COALESCE al producto sustituto

CREATE OR REPLACE FUNCTION public.sustituir_regalo_pedido(
  p_pedido_item_id           BIGINT,
  p_producto_nuevo_id        BIGINT,
  p_cantidad_nueva           NUMERIC,
  p_motivo                   TEXT,
  p_ajuste_producto_id_nuevo BIGINT DEFAULT NULL,
  p_client_request_id        UUID   DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id            UUID := auth.uid();
  v_user_role          TEXT;
  v_sucursal           BIGINT := current_sucursal_id();
  v_item               RECORD;
  v_promo              RECORD;
  v_stock_nuevo        NUMERIC;
  v_regalo_mueve_stock BOOLEAN;
  v_sust_id            BIGINT;
  v_existing           RECORD;
  v_nuevo_nombre       TEXT;
  v_promo_usos_default NUMERIC;
  v_acc_default        RECORD;
  v_ajuste_sustituto_efectivo BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autenticado');
  END IF;

  IF p_client_request_id IS NOT NULL THEN
    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true,
        'sustitucion_id', v_existing.id,
        'idempotent_replay', true);
    END IF;
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Solo admin o encargado pueden sustituir regalos');
  END IF;

  IF p_cantidad_nueva IS NULL OR p_cantidad_nueva <= 0 THEN
    RETURN jsonb_build_object('success', false,
      'error', 'La cantidad sustituta debe ser mayor a 0');
  END IF;

  SELECT pi.id, pi.pedido_id, pi.producto_id, pi.cantidad, pi.es_bonificacion,
         pi.promocion_id, pi.sucursal_id, p.estado AS pedido_estado
    INTO v_item
    FROM pedido_items pi
    JOIN pedidos p ON p.id = pi.pedido_id
   WHERE pi.id = p_pedido_item_id
     AND pi.sucursal_id = v_sucursal
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item no encontrado');
  END IF;
  IF NOT COALESCE(v_item.es_bonificacion, FALSE) THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Solo se pueden sustituir items marcados como bonificacion');
  END IF;
  IF v_item.pedido_estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false,
      'error', 'No se puede sustituir un regalo en un pedido ya entregado');
  END IF;

  IF v_item.promocion_id IS NOT NULL THEN
    SELECT id, regalo_mueve_stock, ajuste_automatico, producto_regalo_id,
           ajuste_producto_id, unidades_por_bloque, stock_por_bloque,
           usos_pendientes
      INTO v_promo
      FROM promociones
     WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
  END IF;
  v_regalo_mueve_stock := COALESCE(v_promo.regalo_mueve_stock, TRUE);

  -- DEFAULT auto-inferido del contenedor del sustituto: si el admin no
  -- eligio, usar el producto sustituto como su propio contenedor (cubre
  -- el 99% de casos donde producto_regalo_id = ajuste_producto_id).
  v_ajuste_sustituto_efectivo := COALESCE(p_ajuste_producto_id_nuevo, p_producto_nuevo_id);

  SELECT nombre INTO v_nuevo_nombre
    FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;

  IF v_regalo_mueve_stock THEN
    SELECT stock INTO v_stock_nuevo
      FROM productos
     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal
     FOR UPDATE;
    IF v_stock_nuevo IS NULL THEN
      RETURN jsonb_build_object('success', false,
        'error', 'Producto sustituto no existe en esta sucursal');
    END IF;
    IF v_stock_nuevo < p_cantidad_nueva THEN
      RETURN jsonb_build_object('success', false,
        'error', 'Stock insuficiente del producto sustituto (' || v_stock_nuevo || ' disponible)');
    END IF;

    PERFORM set_config('app.stock_origen', 'sustitucion_regalo', true);
    PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
    PERFORM set_config('app.stock_ref_id', v_item.pedido_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', v_user_id::TEXT, true);

    UPDATE productos
       SET stock = stock + v_item.cantidad
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    UPDATE productos
       SET stock = stock - p_cantidad_nueva
     WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;
  ELSE
    IF v_promo.producto_regalo_id IS NOT NULL THEN
      SELECT id, usos_pendientes
        INTO v_acc_default
        FROM promo_acumuladores
       WHERE promocion_id = v_promo.id
         AND producto_regalo_id = v_promo.producto_regalo_id
         AND sucursal_id = v_sucursal
       FOR UPDATE;

      IF FOUND THEN
        IF v_acc_default.usos_pendientes IS DISTINCT FROM COALESCE(v_promo.usos_pendientes, 0) THEN
          UPDATE promo_acumuladores
             SET usos_pendientes = COALESCE(v_promo.usos_pendientes, 0),
                 updated_at = NOW()
           WHERE id = v_acc_default.id;
        END IF;
      ELSE
        INSERT INTO promo_acumuladores (
          promocion_id, producto_regalo_id, ajuste_producto_id,
          unidades_por_bloque, stock_por_bloque,
          usos_pendientes, sucursal_id
        ) VALUES (
          v_promo.id, v_promo.producto_regalo_id, v_promo.ajuste_producto_id,
          v_promo.unidades_por_bloque, v_promo.stock_por_bloque,
          COALESCE(v_promo.usos_pendientes, 0), v_sucursal
        )
        ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id) DO NOTHING;
      END IF;
    END IF;

    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_promo.ajuste_producto_id, v_sucursal, v_user_id,
      'sustitucion: salida del producto regalo original'
    );

    -- USAR v_ajuste_sustituto_efectivo (auto-inferido a producto_nuevo si NULL).
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, p_producto_nuevo_id, p_cantidad_nueva,
      v_ajuste_sustituto_efectivo, v_sucursal, v_user_id,
      'sustitucion: entrada del producto regalo sustituto'
    );

    IF v_promo.producto_regalo_id IS NOT NULL THEN
      SELECT usos_pendientes INTO v_promo_usos_default
        FROM promo_acumuladores
       WHERE promocion_id = v_promo.id
         AND producto_regalo_id = v_promo.producto_regalo_id
         AND sucursal_id = v_sucursal;

      UPDATE promociones
         SET usos_pendientes = GREATEST(COALESCE(v_promo_usos_default, 0)::INT, 0)
       WHERE id = v_promo.id AND sucursal_id = v_sucursal;
    END IF;
  END IF;

  UPDATE pedido_items
     SET producto_id = p_producto_nuevo_id,
         cantidad    = p_cantidad_nueva,
         subtotal    = 0,
         descripcion_regalo = COALESCE(descripcion_regalo, '') ||
                              ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']'
   WHERE id = p_pedido_item_id;

  INSERT INTO pedido_item_sustituciones (
    pedido_id, pedido_item_id, promocion_id,
    producto_original_id, producto_sustituto_id,
    cantidad_original, cantidad_sustituta,
    regalo_mueve_stock_snapshot,
    ajuste_producto_id_nuevo,
    motivo, autorizado_por, sucursal_id, client_request_id
  ) VALUES (
    v_item.pedido_id, p_pedido_item_id, v_item.promocion_id,
    v_item.producto_id, p_producto_nuevo_id,
    v_item.cantidad, p_cantidad_nueva,
    v_regalo_mueve_stock,
    v_ajuste_sustituto_efectivo,  -- guardar el efectivo (no el original NULL)
    p_motivo, v_user_id, v_sucursal, p_client_request_id
  ) RETURNING id INTO v_sust_id;

  INSERT INTO pedido_historial (
    pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id
  ) VALUES (
    v_item.pedido_id, v_user_id, 'sustitucion_regalo',
    'producto_id=' || v_item.producto_id || ' cantidad=' || v_item.cantidad,
    'producto_id=' || p_producto_nuevo_id || ' cantidad=' || p_cantidad_nueva ||
      ' motivo=' || p_motivo,
    v_sucursal
  );

  RETURN jsonb_build_object(
    'success', true,
    'sustitucion_id', v_sust_id,
    'modo', CASE WHEN v_regalo_mueve_stock THEN 'A' ELSE 'B' END
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

ALTER FUNCTION public.sustituir_regalo_pedido(BIGINT, BIGINT, NUMERIC, TEXT, BIGINT, UUID)
  OWNER TO postgres;

-- 2) Reconciliacion: acumuladores con ajuste_producto_id mal seteado a un
--    producto distinto del propio producto_regalo_id, en promos donde la
--    config canonica es producto_regalo_id == ajuste_producto_id.
--
-- En el pedido 2000: el acumulador id=7 (promo=13, regalo=83) tiene
-- ajuste_producto_id=81 (heredado del original). Cuando se complete el
-- bloque del sustituto Granadina, descontaria 1 fardo Pomelo Blanco
-- (incorrecto). Lo cambiamos a 83 (Granadina = su propio fardo).
UPDATE public.promo_acumuladores acc
   SET ajuste_producto_id = acc.producto_regalo_id,
       updated_at = NOW()
  FROM public.promociones p
 WHERE acc.promocion_id = p.id
   AND p.producto_regalo_id = p.ajuste_producto_id  -- promo auto-contenedor
   AND acc.ajuste_producto_id IS DISTINCT FROM acc.producto_regalo_id
   AND acc.producto_regalo_id <> p.producto_regalo_id;  -- solo alternos (no default)

COMMIT;
