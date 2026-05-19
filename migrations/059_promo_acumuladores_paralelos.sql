-- =========================================================================
-- 059_promo_acumuladores_paralelos.sql
--
-- Soporta "barras paralelas" en promociones con `ajuste_automatico=true`:
-- una promo puede tener varios productos regalados a la vez (cuando admin
-- sustituye un regalo por otro vía `sustituir_regalo_pedido`). Cada
-- (promo, producto_regalo, sucursal) lleva su propio `usos_pendientes` y
-- su propio contenedor; cuando un acumulador completa un bloque se descuenta
-- 1 fardo del contenedor; cuando cruza hacia abajo (porque se sustituyo),
-- se devuelve 1 fardo al stock.
--
-- Estrategia de minimo invasivo:
--   * NO se refactorizan `crear_pedido_completo`, `actualizar_pedido_items`
--     ni `registrar_salvedad`. Esas RPCs siguen actualizando solo
--     `promociones.usos_pendientes` global (que corresponde al producto
--     regalado default).
--   * `sustituir_regalo_pedido` se encarga de sincronizar
--     `promociones.usos_pendientes` <-> `promo_acumuladores` (entry default)
--     al inicio y al final, y aplicar los deltas por producto en
--     `promo_acumuladores` via el helper.
--   * `promo_acumuladores` es la fuente para multi-barra en UI; cuando una
--     entry NO existe en la tabla (porque la promo nunca tuvo sustituciones)
--     la UI cae a `promociones.usos_pendientes` para mostrar la barra default.
--
-- Tambien:
--   * Se agrega columna `ajuste_producto_id_nuevo` a `pedido_item_sustituciones`
--     para auditar que contenedor eligio el admin al sustituir.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1) Tabla promo_acumuladores
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.promo_acumuladores (
  id                  BIGSERIAL PRIMARY KEY,
  promocion_id        BIGINT NOT NULL REFERENCES public.promociones(id) ON DELETE CASCADE,
  producto_regalo_id  BIGINT NOT NULL REFERENCES public.productos(id),
  ajuste_producto_id  BIGINT REFERENCES public.productos(id),
  unidades_por_bloque INT,
  stock_por_bloque    INT,
  usos_pendientes     NUMERIC(10,2) NOT NULL DEFAULT 0,
  sucursal_id         BIGINT NOT NULL REFERENCES public.sucursales(id),
  created_at          TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  updated_at          TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  UNIQUE (promocion_id, producto_regalo_id, sucursal_id)
);

CREATE INDEX IF NOT EXISTS idx_promo_acumuladores_promo
  ON public.promo_acumuladores (promocion_id, sucursal_id);

CREATE INDEX IF NOT EXISTS idx_promo_acumuladores_producto
  ON public.promo_acumuladores (sucursal_id, producto_regalo_id);

ALTER TABLE public.promo_acumuladores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "mt_promo_acumuladores_select" ON public.promo_acumuladores;
CREATE POLICY "mt_promo_acumuladores_select"
  ON public.promo_acumuladores FOR SELECT TO authenticated
  USING (sucursal_id = public.current_sucursal_id());

-- INSERT/UPDATE/DELETE: solo via RPCs SECURITY DEFINER. No policy directa.

GRANT SELECT ON public.promo_acumuladores TO authenticated;
GRANT ALL ON public.promo_acumuladores TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.promo_acumuladores_id_seq TO authenticated;

-- -------------------------------------------------------------------------
-- 2) Backfill: una fila por promo con ajuste_automatico=true
-- -------------------------------------------------------------------------

INSERT INTO public.promo_acumuladores (
  promocion_id, producto_regalo_id, ajuste_producto_id,
  unidades_por_bloque, stock_por_bloque,
  usos_pendientes, sucursal_id
)
SELECT id, producto_regalo_id, ajuste_producto_id,
       unidades_por_bloque, stock_por_bloque,
       COALESCE(usos_pendientes, 0), sucursal_id
FROM public.promociones
WHERE ajuste_automatico = TRUE
  AND producto_regalo_id IS NOT NULL
ON CONFLICT (promocion_id, producto_regalo_id, sucursal_id) DO NOTHING;

-- -------------------------------------------------------------------------
-- 3) Helper: aplicar_uso_promo_acumulador
-- -------------------------------------------------------------------------
-- Aplica un delta (positivo o negativo) al acumulador y maneja:
--   * cruce hacia arriba de multiplo de unidades_por_bloque -> descuenta
--     stock_por_bloque del contenedor.
--   * cruce hacia abajo -> devuelve stock_por_bloque al contenedor.
-- Loguea en promo_ajustes con valores positivos o negativos segun corresponda.
-- Solo opera si la promo es modo B (ajuste_automatico=true) y la entry tiene
-- contenedor + unidades_por_bloque + stock_por_bloque validos.
-- Crea la entry si no existe.

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

  -- Obtener / crear acumulador con FOR UPDATE
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

  v_old_blocks := FLOOR(GREATEST(v_acc.usos_pendientes, 0) / v_acc.unidades_por_bloque)::INT;
  v_usos_nuevo := v_acc.usos_pendientes + p_delta;

  UPDATE promo_acumuladores
     SET usos_pendientes = v_usos_nuevo,
         updated_at = NOW()
   WHERE id = v_acc.id;

  v_new_blocks := FLOOR(GREATEST(v_usos_nuevo, 0) / v_acc.unidades_por_bloque)::INT;
  v_delta_blocks := v_new_blocks - v_old_blocks;

  IF v_delta_blocks != 0 AND v_acc.ajuste_producto_id IS NOT NULL THEN
    -- Contexto para trigger registrar_cambio_stock (mig 038)
    PERFORM set_config('app.stock_origen', 'auto_ajuste_promo', true);
    PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
    PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
    PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

    -- v_delta_blocks > 0: completa bloque => descontar stock (resta).
    -- v_delta_blocks < 0: revierte bloque => devolver stock (suma).
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

ALTER FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT)
  OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.aplicar_uso_promo_acumulador(BIGINT, BIGINT, NUMERIC, BIGINT, BIGINT, UUID, TEXT) IS
  'Aplica delta al acumulador (promo,producto_regalo,sucursal). Cruza umbrales hacia arriba/abajo y descuenta/devuelve fardos del contenedor. Crea entry si no existe.';

-- -------------------------------------------------------------------------
-- 4) Ampliacion de pedido_item_sustituciones: audit del contenedor sustituto
-- -------------------------------------------------------------------------

ALTER TABLE public.pedido_item_sustituciones
  ADD COLUMN IF NOT EXISTS ajuste_producto_id_nuevo BIGINT REFERENCES public.productos(id);

COMMENT ON COLUMN public.pedido_item_sustituciones.ajuste_producto_id_nuevo IS
  'Contenedor (fardo) que el admin eligio para el producto sustituto en Modo B. NULL si Modo A o si admin opto por "sin contenedor".';

-- -------------------------------------------------------------------------
-- 5) Redefinir sustituir_regalo_pedido
-- -------------------------------------------------------------------------
-- Cambios respecto a mig 058:
--   * Acepta p_ajuste_producto_id_nuevo (contenedor del sustituto).
--   * Modo B: NO mueve stock unitario. Usa aplicar_uso_promo_acumulador
--     para ajustar acumuladores y disparar reversion/descuento de bloques.
--   * Modo A: comportamiento sigue igual (devuelve original, descuenta nuevo).
--   * Modo B: sincroniza promociones.usos_pendientes <-> entry default
--     al inicio y al final (porque crear_pedido_completo solo actualiza
--     promociones.usos_pendientes).

DROP FUNCTION IF EXISTS public.sustituir_regalo_pedido(BIGINT, BIGINT, NUMERIC, TEXT, UUID);

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

  -- 0) Idempotencia
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

  -- 1) Rol
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Solo admin o encargado pueden sustituir regalos');
  END IF;

  -- 2) Cantidad > 0
  IF p_cantidad_nueva IS NULL OR p_cantidad_nueva <= 0 THEN
    RETURN jsonb_build_object('success', false,
      'error', 'La cantidad sustituta debe ser mayor a 0');
  END IF;

  -- 3) Cargar item + pedido + lock
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

  -- 4) Modo de la promo
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

  -- 5) Stock movement segun modo
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
    -- Modo B: barras paralelas. NO se mueve stock unitario.
    -- 5.B.1) Sincronizar promociones.usos_pendientes -> promo_acumuladores
    -- para la entry default (producto regalo original de la promo) ANTES
    -- de aplicar los deltas. Esto cubre incrementos hechos por
    -- crear_pedido_completo que no escribieron en promo_acumuladores.
    IF v_promo.producto_regalo_id IS NOT NULL THEN
      SELECT id, usos_pendientes
        INTO v_acc_default
        FROM promo_acumuladores
       WHERE promocion_id = v_promo.id
         AND producto_regalo_id = v_promo.producto_regalo_id
         AND sucursal_id = v_sucursal
       FOR UPDATE;

      IF FOUND THEN
        -- Si el acumulador default difiere de promociones.usos_pendientes,
        -- "alinear" el acumulador al valor global ANTES de aplicar el delta
        -- de la sustitucion. Esto reproduce los cierres de bloque que
        -- ya ocurrieron en crear_pedido_completo SIN tocar stock (porque
        -- el stock ya fue descontado por la RPC vieja).
        IF v_acc_default.usos_pendientes IS DISTINCT FROM COALESCE(v_promo.usos_pendientes, 0) THEN
          UPDATE promo_acumuladores
             SET usos_pendientes = COALESCE(v_promo.usos_pendientes, 0),
                 updated_at = NOW()
           WHERE id = v_acc_default.id;
        END IF;
      ELSE
        -- No habia entry default (backfill no la creo porque la promo
        -- no era ajuste_automatico al momento del backfill, p.ej.).
        -- Crearla con el usos_pendientes actual.
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

    -- 5.B.2) Decrementar acumulador del producto original.
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, v_item.producto_id, -v_item.cantidad,
      v_promo.ajuste_producto_id, v_sucursal, v_user_id,
      'sustitucion: salida del producto regalo original'
    );

    -- 5.B.3) Incrementar acumulador del producto sustituto.
    PERFORM public.aplicar_uso_promo_acumulador(
      v_promo.id, p_producto_nuevo_id, p_cantidad_nueva,
      COALESCE(p_ajuste_producto_id_nuevo, v_promo.ajuste_producto_id),
      v_sucursal, v_user_id,
      'sustitucion: entrada del producto regalo sustituto'
    );

    -- 5.B.4) Re-sincronizar promociones.usos_pendientes <- entry default.
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

  -- 6) Update pedido_item
  UPDATE pedido_items
     SET producto_id = p_producto_nuevo_id,
         cantidad    = p_cantidad_nueva,
         subtotal    = 0,
         descripcion_regalo = COALESCE(descripcion_regalo, '') ||
                              ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']'
   WHERE id = p_pedido_item_id;

  -- 7) Audit en pedido_item_sustituciones
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

  -- 8) Trace en pedido_historial
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

GRANT EXECUTE ON FUNCTION public.sustituir_regalo_pedido(BIGINT, BIGINT, NUMERIC, TEXT, BIGINT, UUID)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.sustituir_regalo_pedido(BIGINT, BIGINT, NUMERIC, TEXT, BIGINT, UUID) IS
  'Sustituye un item bonificacion. Modo A: devuelve stock X + descuenta Y. Modo B: ajusta barras paralelas en promo_acumuladores, devuelve/descuenta fardos al cruzar umbrales de bloque. Solo admin/encargado. Idempotente.';

COMMIT;
