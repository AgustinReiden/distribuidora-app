-- =========================================================================
-- 060_sustitucion_regalo_fixes.sql
--
-- Tres fixes para que la sustitucion de regalos persista correctamente y
-- el stock se ajuste exactamente.
--
-- Causa raiz del bug (verificado en audit_logs del pedido 1966):
--   1. sustituir_regalo_pedido se ejecuto OK (UPDATE pedido_items
--      producto_id 87 -> 86 + INSERT en pedido_item_sustituciones).
--   2. 6 minutos despues, admin guardo el modal de edicion del pedido.
--      actualizar_pedido_items hizo DELETE FROM pedido_items + reinsert con
--      las bonificaciones regeneradas por usePromocionPedido (que no sabe
--      de sustituciones). El producto_id volvio a 87 (original).
--   3. El helper aplicar_uso_promo_acumulador no detecto cruces hacia abajo
--      cuando el acumulador paso de 0 a -12 (porque usaba
--      FLOOR(GREATEST(usos, 0) / unidades_por_bloque)).
--   4. El contenedor del sustituto heredaba el del original cuando admin
--      no eligio uno; por eso al cerrar el bloque del sustituto se descontaba
--      el fardo del original (mezcla semantica).
--
-- Fixes:
--   1. Trigger BEFORE INSERT en pedido_items que aplica sustituciones
--      automaticamente. Asi actualizar_pedido_items preserva sustituciones
--      vigentes sin importar lo que mande el cliente.
--   2. Helper aplicar_uso_promo_acumulador corregido: FLOOR sin GREATEST
--      detecta cruces hacia abajo cuando usos_pendientes pasa a negativo
--      (revierte fardos).
--   3. sustituir_regalo_pedido: si el admin NO eligio contenedor del
--      sustituto (p_ajuste_producto_id_nuevo IS NULL), pasar NULL al helper
--      (no fallback al del original). El sustituto queda sin ajuste
--      automatico de bloque hasta que admin defina contenedor.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1) Helper aplicar_uso_promo_acumulador corregido
-- -------------------------------------------------------------------------
-- Cambio: FLOOR(usos / unidades_por_bloque) sin GREATEST(usos, 0).
-- En PostgreSQL, FLOOR de un numero negativo redondea hacia menos infinito:
--   FLOOR(-12.0/12) = -1
--   FLOOR(0.0/12)   = 0
--   delta_blocks    = -1 - 0 = -1 -> revierte 1 fardo (suma al stock).
-- Esto soporta el caso de sustitucion: el acumulador del original baja a
-- negativos cuando el bloque ya estaba cerrado, y el cruce hacia abajo
-- devuelve el fardo descontado.

CREATE OR REPLACE FUNCTION public.aplicar_uso_promo_acumulador(
  p_promocion_id            BIGINT,
  p_producto_regalo_id      BIGINT,
  p_delta                   NUMERIC,
  p_ajuste_producto_id_def  BIGINT,
  p_sucursal_id             BIGINT,
  p_usuario_id              UUID,
  p_motivo                  TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_promo RECORD;
  v_acc   RECORD;
  v_old_blocks INT;
  v_new_blocks INT;
  v_delta_blocks INT;
  v_usos_nuevo NUMERIC;
BEGIN
  SELECT id, unidades_por_bloque, stock_por_bloque, ajuste_automatico,
         ajuste_producto_id, regalo_mueve_stock
    INTO v_promo
    FROM promociones
   WHERE id = p_promocion_id
     AND sucursal_id = p_sucursal_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'promo no encontrada');
  END IF;
  IF NOT COALESCE(v_promo.ajuste_automatico, FALSE) THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'promo no es modo B');
  END IF;
  IF COALESCE(v_promo.unidades_por_bloque, 0) <= 0
     OR COALESCE(v_promo.stock_por_bloque, 0) <= 0 THEN
    RETURN jsonb_build_object('aplicado', false, 'razon', 'config bloque invalida');
  END IF;

  SELECT id, ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_acc
    FROM promo_acumuladores
   WHERE promocion_id = p_promocion_id
     AND producto_regalo_id = p_producto_regalo_id
     AND sucursal_id = p_sucursal_id
   FOR UPDATE;

  IF NOT FOUND THEN
    INSERT INTO promo_acumuladores (
      promocion_id, producto_regalo_id, ajuste_producto_id,
      unidades_por_bloque, stock_por_bloque, usos_pendientes, sucursal_id
    ) VALUES (
      p_promocion_id, p_producto_regalo_id, p_ajuste_producto_id_def,
      v_promo.unidades_por_bloque, v_promo.stock_por_bloque, 0, p_sucursal_id
    )
    RETURNING id, ajuste_producto_id, unidades_por_bloque, stock_por_bloque, usos_pendientes
    INTO v_acc;
  END IF;

  -- FIX: sin GREATEST, FLOOR sobre numeros negativos redondea hacia menos
  -- infinito (PostgreSQL). Eso detecta cruces hacia abajo.
  v_old_blocks := FLOOR(v_acc.usos_pendientes / v_acc.unidades_por_bloque)::INT;
  v_usos_nuevo := v_acc.usos_pendientes + p_delta;

  UPDATE promo_acumuladores
     SET usos_pendientes = v_usos_nuevo,
         updated_at = NOW()
   WHERE id = v_acc.id;

  v_new_blocks := FLOOR(v_usos_nuevo / v_acc.unidades_por_bloque)::INT;
  v_delta_blocks := v_new_blocks - v_old_blocks;

  IF v_delta_blocks != 0 AND v_acc.ajuste_producto_id IS NOT NULL THEN
    PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

    UPDATE productos
       SET stock = stock - (v_delta_blocks * v_acc.stock_por_bloque),
           updated_at = NOW()
     WHERE id = v_acc.ajuste_producto_id
       AND sucursal_id = p_sucursal_id;

    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, usuario_id, observaciones, sucursal_id
    ) VALUES (
      p_promocion_id,
      v_delta_blocks * v_acc.unidades_por_bloque,
      v_delta_blocks * v_acc.stock_por_bloque,
      v_acc.ajuste_producto_id, p_usuario_id, p_motivo, p_sucursal_id
    );
  END IF;

  RETURN jsonb_build_object(
    'aplicado', true,
    'acumulador_id', v_acc.id,
    'usos_pendientes', v_usos_nuevo,
    'bloques_delta', v_delta_blocks
  );
END;
$$;

-- -------------------------------------------------------------------------
-- 2) Trigger BEFORE INSERT en pedido_items: aplicar sustitucion automatica
-- -------------------------------------------------------------------------
-- Si el item INSERT-ado es bonificacion con promocion_id, busca la sustitucion
-- mas reciente para (pedido, promo, producto_original) en
-- pedido_item_sustituciones. Si encontro, reemplaza NEW.producto_id por el
-- sustituto y annade " [Sustituido por: X]" al descripcion_regalo si no
-- estaba. Asi actualizar_pedido_items preserva sustituciones.
--
-- NO toca cantidad (mantiene la que mande el caller). Si la cantidad nueva
-- es distinta a la original, el admin podria querer re-sustituir
-- manualmente.

CREATE OR REPLACE FUNCTION public.aplicar_sustituciones_regalo_pre_insert()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sust RECORD;
  v_nombre_sustituto TEXT;
BEGIN
  -- Solo aplica a items bonificacion con promocion_id.
  IF NOT COALESCE(NEW.es_bonificacion, FALSE) THEN
    RETURN NEW;
  END IF;
  IF NEW.promocion_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Buscar la sustitucion mas reciente para este (pedido, promo, producto).
  SELECT producto_sustituto_id, cantidad_sustituta, ajuste_producto_id_nuevo
    INTO v_sust
    FROM pedido_item_sustituciones
   WHERE pedido_id = NEW.pedido_id
     AND promocion_id = NEW.promocion_id
     AND producto_original_id = NEW.producto_id
     AND sucursal_id = NEW.sucursal_id
   ORDER BY created_at DESC
   LIMIT 1;

  IF FOUND THEN
    -- Append " [Sustituido por: X]" si no esta ya
    IF COALESCE(NEW.descripcion_regalo, '') NOT LIKE '%[Sustituido por:%' THEN
      SELECT nombre INTO v_nombre_sustituto
        FROM productos
       WHERE id = v_sust.producto_sustituto_id
         AND sucursal_id = NEW.sucursal_id;
      NEW.descripcion_regalo := COALESCE(NEW.descripcion_regalo, '') ||
                                ' [Sustituido por: ' || COALESCE(v_nombre_sustituto, '?') || ']';
    END IF;
    NEW.producto_id := v_sust.producto_sustituto_id;
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.aplicar_sustituciones_regalo_pre_insert() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_aplicar_sustituciones_regalo ON public.pedido_items;
CREATE TRIGGER trg_aplicar_sustituciones_regalo
  BEFORE INSERT ON public.pedido_items
  FOR EACH ROW EXECUTE FUNCTION public.aplicar_sustituciones_regalo_pre_insert();

COMMENT ON FUNCTION public.aplicar_sustituciones_regalo_pre_insert() IS
  'Trigger BEFORE INSERT en pedido_items: si el item es bonificacion con promocion_id y existe una sustitucion en pedido_item_sustituciones para (pedido,promo,producto_original), reemplaza NEW.producto_id por el sustituto. Garantiza que actualizar_pedido_items preserve sustituciones.';

-- -------------------------------------------------------------------------
-- 3) sustituir_regalo_pedido corregida
-- -------------------------------------------------------------------------
-- Fix: si admin NO eligio contenedor para el sustituto
-- (p_ajuste_producto_id_nuevo IS NULL), pasar NULL al helper en vez de
-- v_promo.ajuste_producto_id (que es el contenedor del ORIGINAL). Asi el
-- sustituto queda sin ajuste automatico de bloque hasta que admin defina
-- contenedor explicitamente.
--
-- El resto identico a mig 059.

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

  SELECT nombre INTO v_nuevo_nombre
    FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;

  IF v_regalo_mueve_stock THEN
    -- Modo A: validar stock + devolver X + descontar Y
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
    -- Modo B: barras paralelas, NO mueve stock unitario.
    -- 1) Sincronizar promociones.usos_pendientes -> entry default (cubre
    --    incrementos hechos por crear_pedido_completo que no escribieron
    --    en promo_acumuladores).
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

    -- 2) Decrementar acumulador del original (puede revertir fardo si cruza
    --    hacia abajo, gracias al fix del helper).
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_promo.ajuste_producto_id, v_sucursal, v_user_id,
      'sustitucion: salida del producto regalo original'
    );

    -- 3) Incrementar acumulador del sustituto. FIX: pasar
    --    p_ajuste_producto_id_nuevo DIRECTAMENTE (no fallback al original).
    --    Si admin no eligio contenedor, el acumulador queda sin
    --    ajuste_producto_id y no descuenta fardo automatico al cerrar bloque.
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, p_producto_nuevo_id, p_cantidad_nueva,
      p_ajuste_producto_id_nuevo, v_sucursal, v_user_id,
      'sustitucion: entrada del producto regalo sustituto'
    );

    -- 4) Resincronizar promociones.usos_pendientes con el default.
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
    p_ajuste_producto_id_nuevo,
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

COMMIT;
