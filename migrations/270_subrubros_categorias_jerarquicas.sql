-- Subrubros: categorias jerarquicas de dos niveles (#828)
--
-- El deposito agrupa la mercaderia por rubro y subrubro (Gaseosas -> Manaos
-- 3000cc). Rubro = `categorias` (ya existe, por sucursal). Subrubro = hija de un
-- rubro: `categorias.parent_id`. Marca sigue siendo `productos.marca_id`.
--
-- Modelo elegido para el producto: `categoria_id` SIGUE siendo el rubro y se
-- agrega `subcategoria_id` (opcion b). Asi nadie que hoy agrupe por categoria_id
-- (comisiones, metas, reportes, bot, `productos.categoria` texto de la 146) ve
-- cambiar el significado de la columna. El subrubro es un dato extra.
--
-- Invariantes:
--  * misma sucursal que el padre: FK compuesta (parent_id, sucursal_id) ->
--    categorias(id, sucursal_id), la misma tecnica del aislamiento por sucursal;
--  * dos niveles como maximo: trigger (un padre no puede tener padre, y quien
--    tiene hijos no puede pasar a ser hijo);
--  * la subcategoria de un producto pertenece a SU categoria: trigger. Si el
--    front viejo cambia `categoria` (texto) y deja la subcategoria vieja, se
--    la suelta en vez de fallar el UPDATE (compatibilidad hacia atras).
--
-- El UNIQUE (sucursal_id, nombre) pasa a ser por padre: "Manaos" puede existir
-- bajo Gaseosas y bajo Aguas. Los rubros (parent_id NULL) siguen siendo unicos
-- por sucursal, asi el 23505 del front actual sigue significando lo mismo.
--
-- `sync_producto_categoria_id` (146) busca el rubro por NOMBRE: hay que acotarlo
-- a los rubros, o un subrubro homonimo le robaria el id al producto.
-- RLS: las hijas viven en la misma tabla, heredan las policies mt_categorias_*.

BEGIN;

ALTER TABLE public.categorias ADD COLUMN parent_id uuid;

ALTER TABLE public.categorias
  ADD CONSTRAINT categorias_parent_fkey
  FOREIGN KEY (parent_id, sucursal_id)
  REFERENCES public.categorias (id, sucursal_id) ON DELETE CASCADE;

ALTER TABLE public.categorias
  ADD CONSTRAINT categorias_parent_no_self CHECK (parent_id IS DISTINCT FROM id);

ALTER TABLE public.categorias DROP CONSTRAINT categorias_sucursal_id_nombre_key;
CREATE UNIQUE INDEX categorias_sucursal_padre_nombre_uk
  ON public.categorias (sucursal_id, COALESCE(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), nombre);

CREATE INDEX categorias_parent_id_idx ON public.categorias (parent_id) WHERE parent_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.validar_categoria_jerarquia()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.parent_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM categorias WHERE id = NEW.parent_id AND parent_id IS NOT NULL) THEN
      RAISE EXCEPTION 'Un subrubro no puede tener subrubros: la jerarquia es de dos niveles.'
        USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'UPDATE' AND EXISTS (SELECT 1 FROM categorias WHERE parent_id = NEW.id) THEN
      RAISE EXCEPTION 'Un rubro con subrubros no puede pasar a ser subrubro.'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_categorias_jerarquia
  BEFORE INSERT OR UPDATE OF parent_id ON public.categorias
  FOR EACH ROW EXECUTE FUNCTION public.validar_categoria_jerarquia();

ALTER TABLE public.productos ADD COLUMN subcategoria_id uuid;

ALTER TABLE public.productos
  ADD CONSTRAINT productos_subcategoria_id_fkey
  FOREIGN KEY (subcategoria_id, sucursal_id)
  REFERENCES public.categorias (id, sucursal_id) ON DELETE SET NULL (subcategoria_id);

CREATE INDEX productos_subcategoria_id_idx ON public.productos (subcategoria_id) WHERE subcategoria_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.validar_subcategoria_producto()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.subcategoria_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.categoria_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM categorias c
    WHERE c.id = NEW.subcategoria_id AND c.parent_id = NEW.categoria_id
  ) THEN
    RETURN NEW;
  END IF;

  -- Cambio el rubro (p. ej. un front viejo escribiendo el texto `categoria`)
  -- y la subcategoria quedo huerfana: se suelta, no se rechaza el UPDATE.
  IF TG_OP = 'UPDATE' AND NEW.subcategoria_id IS NOT DISTINCT FROM OLD.subcategoria_id THEN
    NEW.subcategoria_id := NULL;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'La subcategoria no pertenece a la categoria del producto.'
    USING ERRCODE = '23514';
END;
$$;

-- Nombre > 'trg_sync_producto_categoria_id': corre despues de que el texto
-- `categoria` ya resolvio `categoria_id`.
CREATE TRIGGER trg_validar_subcategoria_producto
  BEFORE INSERT OR UPDATE ON public.productos
  FOR EACH ROW EXECUTE FUNCTION public.validar_subcategoria_producto();

CREATE OR REPLACE FUNCTION public.sync_producto_categoria_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.categoria IS NULL OR trim(NEW.categoria) = '' THEN
    NEW.categoria_id := NULL;
    RETURN NEW;
  END IF;

  SELECT c.id INTO NEW.categoria_id
  FROM categorias c
  WHERE c.sucursal_id = NEW.sucursal_id
    AND c.parent_id IS NULL
    AND lower(trim(c.nombre)) = lower(trim(NEW.categoria))
  LIMIT 1;

  RETURN NEW;
END;
$$;

-- Funciones de trigger: no necesitan EXECUTE para nadie.
REVOKE EXECUTE ON FUNCTION public.validar_categoria_jerarquia() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.validar_subcategoria_producto() FROM PUBLIC, anon, authenticated;

COMMIT;
