-- =========================================================================
-- 147_producto_cantidad_minima_venta.sql
--
-- "La compra mínima de cada sabor quiero que sea 3 unidades" (ej: fideos).
--
-- Ya existía un MOQ, pero atado a las condiciones mayoristas
-- (grupo_precio_productos.cantidad_minima_pedido): un producto sin condición
-- mayorista no podía tener mínimo, y en prod nunca se usó (0 registros).
-- Además se validaba SOLO en el navegador: ni los RPCs ni el bot lo miraban.
--
-- El mínimo pasa a vivir en el producto, que es donde corresponde para
-- "mínimo por sabor", y se valida en la base para que valga en todos los
-- canales. El MOQ de grupo sigue existiendo; en el front gana el mayor de los
-- dos (obtenerMOQ en src/utils/precioMayorista.ts).
-- =========================================================================

ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS cantidad_minima_venta integer;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'productos_cantidad_minima_venta_check') THEN
    ALTER TABLE public.productos
      ADD CONSTRAINT productos_cantidad_minima_venta_check
      CHECK (cantidad_minima_venta IS NULL OR cantidad_minima_venta > 0);
  END IF;
END $$;

COMMENT ON COLUMN public.productos.cantidad_minima_venta IS
  'Mínimo de unidades por pedido para este producto. NULL = sin mínimo. Distinto de stock_minimo, que es alerta de reposición. Mig 147.';

-- -------------------------------------------------------------------------
-- Guarda server-side. Igual que la de precio (mig 139), por trigger: cubre
-- app, bot, edición y cola offline sin reescribir los RPCs.
-- Las bonificaciones quedan exentas: un regalo de 1 unidad es válido aunque
-- el mínimo de venta sea 3.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_minimo_venta_item()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_nombre text;
  v_minimo integer;
BEGIN
  IF COALESCE(NEW.es_bonificacion, false) THEN
    RETURN NEW;
  END IF;

  SELECT nombre, cantidad_minima_venta INTO v_nombre, v_minimo
  FROM productos WHERE id = NEW.producto_id;

  IF v_minimo IS NOT NULL AND NEW.cantidad < v_minimo THEN
    RAISE EXCEPTION 'La compra mínima de "%" es % unidades (se cargaron %)',
      COALESCE(v_nombre, NEW.producto_id::text), v_minimo, NEW.cantidad
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$fn$;

ALTER FUNCTION public.validar_minimo_venta_item() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_validar_minimo_venta_item ON public.pedido_items;
CREATE TRIGGER trg_validar_minimo_venta_item
  BEFORE INSERT OR UPDATE OF cantidad, producto_id, es_bonificacion
  ON public.pedido_items
  FOR EACH ROW
  EXECUTE FUNCTION public.validar_minimo_venta_item();

-- -------------------------------------------------------------------------
-- Carga masiva por categoría: "3 a todos los fideos" en un paso.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_minimo_venta_masivo(
  p_categoria_id uuid,
  p_cantidad     integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_actualizados integer := 0;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un admin o encargado puede cargar mínimos de venta'
      USING ERRCODE = '42501';
  END IF;

  IF p_cantidad IS NOT NULL AND p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad mínima debe ser mayor a 0 (o NULL para quitarla)';
  END IF;

  UPDATE productos
  SET cantidad_minima_venta = p_cantidad
  WHERE categoria_id = p_categoria_id
    AND sucursal_id = current_sucursal_id();
  GET DIAGNOSTICS v_actualizados = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'actualizados', v_actualizados);
END;
$fn$;

ALTER FUNCTION public.actualizar_minimo_venta_masivo(uuid, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.actualizar_minimo_venta_masivo(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.actualizar_minimo_venta_masivo(uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.actualizar_minimo_venta_masivo(uuid, integer) IS
  'Aplica un mínimo de venta a todos los productos de una categoría en la sucursal activa. NULL lo quita. Mig 147.';
