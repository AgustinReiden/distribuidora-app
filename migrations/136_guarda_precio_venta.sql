-- =========================================================================
-- 136_guarda_precio_venta.sql
--
-- PROBLEMA (verificado en prod 2026-07-27):
--   4 productos con precio = 0 y stock disponible, vendibles a $0. Dos de
--   ellos creados ese mismo día en Taco Pozo con 30 unidades cada uno.
--   El modal de producto YA exige precio > 0 (modalProductoSchema), así que
--   el alta manual no es el vector: el producto lo crea el sistema en
--   `aceptar_movimiento_sucursal` (mig 076) con COALESCE(origen_precio, 0)
--   cuando llega un envío de un producto que no existe en la sucursal
--   destino. Por eso pasó sin que nadie lo notara.
--
--   Ninguno de los caminos de venta tiene red server-side: ni
--   crear_pedido_completo, ni crear_pedido_completo_bot, ni
--   actualizar_pedido_items validan el piso del precio. La única
--   validación vive en el navegador.
--
-- ENFOQUE: triggers, no reescritura de los RPCs.
--   Un trigger sobre pedido_items cubre TODOS los caminos de una sola vez
--   (app, bot, edición, cola offline y cualquier RPC futuro) sin tener que
--   reescribir tres funciones de 300+ líneas, que en este repo tienen
--   historial de cambios out-of-band no reflejados en migrations/.
--
-- SEGURIDAD DEL CAMBIO: en prod los 825 items con precio <= 0 son TODOS
--   es_bonificacion = true (regalos de promo, que van a $0 por diseño).
--   No hay un solo caso legítimo de venta a 0, así que la guarda no rompe
--   nada del histórico.
--
-- Orden de ejecución: `trg_aplicar_sustituciones_regalo` (BEFORE INSERT ya
--   existente) corre antes que este por orden alfabético, así que se valida
--   el valor final del item, no el previo a la sustitución.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Guarda: ningún item no bonificado puede venderse a precio 0, y ningún
--    producto sin precio de lista puede entrar a un pedido nuevo.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_precio_item_pedido()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_nombre       text;
  v_precio_lista numeric;
BEGIN
  -- Las bonificaciones de promoción van a $0 por diseño.
  IF COALESCE(NEW.es_bonificacion, false) THEN
    RETURN NEW;
  END IF;

  SELECT nombre, precio INTO v_nombre, v_precio_lista
  FROM productos WHERE id = NEW.producto_id;

  IF NEW.precio_unitario IS NULL OR NEW.precio_unitario <= 0 THEN
    RAISE EXCEPTION
      'El producto "%" no puede venderse a precio 0. Cargá el precio de venta antes de facturarlo.',
      COALESCE(v_nombre, NEW.producto_id::text)
      USING ERRCODE = 'check_violation';
  END IF;

  -- Solo en el alta. En UPDATE no se valida el precio de lista para no
  -- trabar la edición de pedidos históricos de un producto que hoy quedó
  -- sin precio (el item ya tiene su precio propio, validado arriba).
  IF TG_OP = 'INSERT' AND (v_precio_lista IS NULL OR v_precio_lista <= 0) THEN
    RAISE EXCEPTION
      'El producto "%" está pendiente de carga de precio de venta y no puede venderse.',
      COALESCE(v_nombre, NEW.producto_id::text)
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

ALTER FUNCTION public.validar_precio_item_pedido() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_validar_precio_item_pedido ON public.pedido_items;
CREATE TRIGGER trg_validar_precio_item_pedido
  BEFORE INSERT OR UPDATE OF precio_unitario, producto_id, es_bonificacion
  ON public.pedido_items
  FOR EACH ROW
  EXECUTE FUNCTION public.validar_precio_item_pedido();

-- -------------------------------------------------------------------------
-- 2. Aviso: cuando nace un producto sin precio (o uno existente se queda
--    sin precio), notificar a admins/encargados de esa sucursal.
--
--    Se hace por trigger en vez de tocar `aceptar_movimiento_sucursal` para
--    cubrir también cualquier otro camino de alta (imports, RPCs futuros).
--    Reusa el fan-out `_notificar_sucursal_roles` de la mig 076.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notificar_producto_sin_precio()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM _notificar_sucursal_roles(
    NEW.sucursal_id,
    NULL::uuid,
    'producto_sin_precio'::varchar,
    'Producto sin precio de venta'::text,
    format(
      '«%s» quedó sin precio de venta: no se puede vender hasta que lo cargues.',
      NEW.nombre
    )::text,
    'producto'::varchar,
    NEW.id,
    jsonb_build_object('producto_id', NEW.id, 'nombre', NEW.nombre)
  );
  RETURN NULL;
END;
$$;

ALTER FUNCTION public.notificar_producto_sin_precio() OWNER TO postgres;

-- Dos triggers separados: la cláusula WHEN no puede consultar OLD en INSERT
-- ni TG_OP en ninguno, así que no se puede unificar en uno solo.
DROP TRIGGER IF EXISTS trg_notificar_producto_sin_precio_ins ON public.productos;
CREATE TRIGGER trg_notificar_producto_sin_precio_ins
  AFTER INSERT ON public.productos
  FOR EACH ROW
  WHEN (NEW.precio IS NULL OR NEW.precio <= 0)
  EXECUTE FUNCTION public.notificar_producto_sin_precio();

DROP TRIGGER IF EXISTS trg_notificar_producto_sin_precio_upd ON public.productos;
CREATE TRIGGER trg_notificar_producto_sin_precio_upd
  AFTER UPDATE OF precio ON public.productos
  FOR EACH ROW
  WHEN ((NEW.precio IS NULL OR NEW.precio <= 0) AND OLD.precio > 0)
  EXECUTE FUNCTION public.notificar_producto_sin_precio();

COMMENT ON FUNCTION public.validar_precio_item_pedido() IS
  'Impide vender a precio 0 (salvo bonificaciones de promo) y bloquea el alta de items de productos sin precio de lista. Mig 136.';
COMMENT ON FUNCTION public.notificar_producto_sin_precio() IS
  'Avisa a admins/encargados cuando un producto queda sin precio de venta. Mig 136.';
