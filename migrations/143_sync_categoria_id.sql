-- =========================================================================
-- 143_sync_categoria_id.sql
--
-- Mantiene `productos.categoria_id` sincronizado con el texto `categoria`.
--
-- Por trigger y no en el front por el mismo motivo que la guarda de precios
-- (mig 136): cubre TODOS los caminos de alta y edición —modal de producto,
-- movimientos entre sucursales, imports, bot y cualquier RPC futuro— sin tener
-- que acordarse de resolver el FK en cada uno. Si el texto no matchea ninguna
-- categoría de esa sucursal, `categoria_id` queda NULL y el producto aparece
-- como "sin categoría", que es visible y corregible, en vez de apuntar a una
-- categoría equivocada.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.sync_producto_categoria_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
BEGIN
  IF NEW.categoria IS NULL OR trim(NEW.categoria) = '' THEN
    NEW.categoria_id := NULL;
    RETURN NEW;
  END IF;

  SELECT c.id INTO NEW.categoria_id
  FROM categorias c
  WHERE c.sucursal_id = NEW.sucursal_id
    AND lower(trim(c.nombre)) = lower(trim(NEW.categoria))
  LIMIT 1;

  RETURN NEW;
END;
$fn$;

ALTER FUNCTION public.sync_producto_categoria_id() OWNER TO postgres;

DROP TRIGGER IF EXISTS trg_sync_producto_categoria_id ON public.productos;
CREATE TRIGGER trg_sync_producto_categoria_id
  BEFORE INSERT OR UPDATE OF categoria, sucursal_id
  ON public.productos
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_producto_categoria_id();

COMMENT ON FUNCTION public.sync_producto_categoria_id() IS
  'Resuelve productos.categoria_id desde el texto de categoria, por sucursal. Mig 143.';
