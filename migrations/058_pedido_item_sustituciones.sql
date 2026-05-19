-- =========================================================================
-- 058_pedido_item_sustituciones.sql
--
-- Sustituir un regalo X (de una promocion) por otro producto Y en un pedido
-- ya cargado. Hoy se hace "artesanal": el operador borra el item bonificacion
-- y agrega otro a mano, sin que se devuelva el stock del producto original
-- y sin audit trail.
--
-- Esta migracion:
--   1. Crea la tabla `pedido_item_sustituciones` como audit log dedicado.
--   2. Crea la RPC `sustituir_regalo_pedido` (SECURITY DEFINER), atomica y
--      con idempotencia via client_request_id (mismo patron que mig 049).
--
-- Reglas de stock (ortogonales al gatillo de la promo):
--   - Modo A (regalo_mueve_stock=TRUE): devuelve stock X + descuenta Y.
--   - Modo B (regalo_mueve_stock=FALSE, ajuste_automatico=TRUE): NO revierte
--     el bloque del contenedor (otros usos del bloque siguen vivos). Solo
--     descuenta Y. El bloque queda como costo de la promo entregada.
--
-- Cosas que NUNCA toca:
--   - promociones.usos_pendientes (el uso ya se conto)
--   - promo_ajustes ni revertir_bloques_auto_ajuste
--   - promocion_reglas / promocion_productos (el gatillo no cambia)
--
-- Solo admin o encargado pueden ejecutarla.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 1) Tabla audit de sustituciones
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.pedido_item_sustituciones (
  id                BIGSERIAL PRIMARY KEY,
  pedido_id         BIGINT NOT NULL REFERENCES public.pedidos(id) ON DELETE CASCADE,
  pedido_item_id    BIGINT NOT NULL REFERENCES public.pedido_items(id) ON DELETE CASCADE,
  promocion_id      BIGINT REFERENCES public.promociones(id),
  producto_original_id   BIGINT NOT NULL REFERENCES public.productos(id),
  producto_sustituto_id  BIGINT NOT NULL REFERENCES public.productos(id),
  -- NUMERIC: pedido_items.cantidad es NUMERIC; soporta fraccion (0.5, 0.75)
  cantidad_original      NUMERIC(10,2) NOT NULL CHECK (cantidad_original > 0),
  cantidad_sustituta     NUMERIC(10,2) NOT NULL CHECK (cantidad_sustituta > 0),
  -- Snapshot del modo de la promo al momento de la sustitucion
  regalo_mueve_stock_snapshot BOOLEAN,
  motivo            TEXT NOT NULL,
  autorizado_por    UUID NOT NULL REFERENCES public.perfiles(id),
  sucursal_id       BIGINT NOT NULL REFERENCES public.sucursales(id),
  created_at        TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  client_request_id UUID
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pedido_sustituciones_request_id
  ON public.pedido_item_sustituciones (client_request_id)
  WHERE client_request_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pedido_sustituciones_pedido
  ON public.pedido_item_sustituciones (pedido_id);

ALTER TABLE public.pedido_item_sustituciones ENABLE ROW LEVEL SECURITY;

-- Select: cualquier authenticated de la sucursal puede leer (para mostrar en
-- el historial del pedido).
DROP POLICY IF EXISTS "mt_sust_select" ON public.pedido_item_sustituciones;
CREATE POLICY "mt_sust_select"
  ON public.pedido_item_sustituciones FOR SELECT TO authenticated
  USING (sucursal_id = public.current_sucursal_id());

-- INSERT/UPDATE/DELETE: solo via la RPC SECURITY DEFINER. Sin policy directa.

GRANT SELECT ON public.pedido_item_sustituciones TO authenticated;
GRANT ALL ON public.pedido_item_sustituciones TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.pedido_item_sustituciones_id_seq TO authenticated;

-- -------------------------------------------------------------------------
-- 2) RPC sustituir_regalo_pedido
-- -------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sustituir_regalo_pedido(
  p_pedido_item_id     BIGINT,
  p_producto_nuevo_id  BIGINT,
  p_cantidad_nueva     NUMERIC,
  p_motivo             TEXT,
  p_client_request_id  UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_user_id            UUID := auth.uid();
  v_user_role          TEXT;
  v_sucursal           BIGINT := current_sucursal_id();
  v_item               RECORD;
  v_stock_nuevo        NUMERIC;
  v_regalo_mueve_stock BOOLEAN;
  v_sust_id            BIGINT;
  v_existing           RECORD;
  v_nuevo_nombre       TEXT;
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

  -- 1) Validar rol
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  IF v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false,
      'error', 'Solo admin o encargado pueden sustituir regalos');
  END IF;

  -- 2) Validar cantidad > 0
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
    SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
      FROM promociones
     WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
  END IF;
  -- Conservador: si no hay promo o si esta NULL, tratamos como Modo A
  -- (el item se habia descontado del stock). El admin justifica via motivo.
  v_regalo_mueve_stock := COALESCE(v_regalo_mueve_stock, TRUE);

  -- 5) Validar stock disponible del producto nuevo
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

  -- Nombre del nuevo producto (para snapshot en descripcion_regalo)
  SELECT nombre INTO v_nuevo_nombre
    FROM productos WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;

  -- 6) Contexto trigger registrar_cambio_stock (mig 038)
  PERFORM set_config('app.stock_origen', 'sustitucion_regalo', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', v_item.pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', v_user_id::TEXT, true);

  -- 7) Stock segun modo
  IF v_regalo_mueve_stock THEN
    -- Modo A: devolver al producto original
    UPDATE productos
       SET stock = stock + v_item.cantidad
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;
  -- En ambos modos: descontar Y
  UPDATE productos
     SET stock = stock - p_cantidad_nueva
   WHERE id = p_producto_nuevo_id AND sucursal_id = v_sucursal;

  -- 8) Actualizar item: cambia producto + cantidad + descripcion.
  --    NO cambia es_bonificacion (sigue siendo regalo), NO cambia promocion_id.
  --    NO recalcula subtotal porque sigue siendo precio_unitario=0 (regalo).
  UPDATE pedido_items
     SET producto_id = p_producto_nuevo_id,
         cantidad    = p_cantidad_nueva,
         subtotal    = 0,
         descripcion_regalo = COALESCE(descripcion_regalo, '') ||
                              ' [Sustituido por: ' || COALESCE(v_nuevo_nombre, '?') || ']'
   WHERE id = p_pedido_item_id;

  -- 9) Audit
  INSERT INTO pedido_item_sustituciones (
    pedido_id, pedido_item_id, promocion_id,
    producto_original_id, producto_sustituto_id,
    cantidad_original, cantidad_sustituta,
    regalo_mueve_stock_snapshot,
    motivo, autorizado_por, sucursal_id, client_request_id
  ) VALUES (
    v_item.pedido_id, p_pedido_item_id, v_item.promocion_id,
    v_item.producto_id, p_producto_nuevo_id,
    v_item.cantidad, p_cantidad_nueva,
    v_regalo_mueve_stock,
    p_motivo, v_user_id, v_sucursal, p_client_request_id
  ) RETURNING id INTO v_sust_id;

  -- 10) Trace en historial del pedido
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

ALTER FUNCTION public.sustituir_regalo_pedido(BIGINT, BIGINT, NUMERIC, TEXT, UUID)
  OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.sustituir_regalo_pedido(BIGINT, BIGINT, NUMERIC, TEXT, UUID)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.sustituir_regalo_pedido(BIGINT, BIGINT, NUMERIC, TEXT, UUID) IS
  'Sustituye un item bonificacion por otro producto. Solo admin/encargado. Devuelve stock del original (Modo A) o NO lo revierte (Modo B, bloques). Idempotente via client_request_id.';

COMMIT;
