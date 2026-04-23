-- Tabla `categorias` para gestionar categorías de productos como entidad propia
-- (hasta ahora `productos.categoria` era solo un string libre).
--
-- Motivo: el admin necesita poder agregar/renombrar/eliminar categorías desde
-- la UI sin depender de crear un producto antes. Se mantiene `productos.categoria`
-- como string para no romper queries existentes; la tabla `categorias` actúa
-- como fuente de verdad para la lista editable, y la UI muestra el UNION de
-- ambas fuentes (categorías de la tabla + derivadas de productos).
--
-- Multi-tenant: `sucursal_id` + RLS con current_sucursal_id() siguiendo el
-- patrón de `productos` (ver mt_productos_* en 000_baseline.sql).
-- Insert/update/delete restringidos a admin; select abierto a todos los
-- usuarios de la sucursal.
--
-- Idempotente: seguro para re-aplicar.

-- =============================================================================
-- TABLA
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.categorias (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre       text NOT NULL CHECK (length(btrim(nombre)) > 0),
  sucursal_id  bigint NOT NULL REFERENCES public.sucursales(id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sucursal_id, nombre)
);

CREATE INDEX IF NOT EXISTS idx_categorias_sucursal ON public.categorias (sucursal_id);

COMMENT ON TABLE public.categorias IS
  'Categorías de productos por sucursal. Fuente de verdad para la lista editable en UI. productos.categoria (string) se sigue usando para compatibilidad.';

-- =============================================================================
-- TRIGGER updated_at
-- =============================================================================
CREATE OR REPLACE FUNCTION public.categorias_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_categorias_updated_at ON public.categorias;
CREATE TRIGGER trg_categorias_updated_at
  BEFORE UPDATE ON public.categorias
  FOR EACH ROW
  EXECUTE FUNCTION public.categorias_set_updated_at();

-- =============================================================================
-- RLS POLICIES (patrón mt_productos_*)
-- =============================================================================
ALTER TABLE public.categorias ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mt_categorias_select ON public.categorias;
CREATE POLICY mt_categorias_select
  ON public.categorias FOR SELECT TO authenticated
  USING (sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_categorias_insert ON public.categorias;
CREATE POLICY mt_categorias_insert
  ON public.categorias FOR INSERT TO authenticated
  WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_categorias_update ON public.categorias;
CREATE POLICY mt_categorias_update
  ON public.categorias FOR UPDATE TO authenticated
  USING (public.es_admin() AND sucursal_id = public.current_sucursal_id())
  WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_categorias_delete ON public.categorias;
CREATE POLICY mt_categorias_delete
  ON public.categorias FOR DELETE TO authenticated
  USING (public.es_admin() AND sucursal_id = public.current_sucursal_id());

-- =============================================================================
-- BACKFILL: poblar con categorías existentes en productos
-- =============================================================================
INSERT INTO public.categorias (nombre, sucursal_id)
SELECT DISTINCT btrim(p.categoria), p.sucursal_id
FROM public.productos p
WHERE p.categoria IS NOT NULL
  AND btrim(p.categoria) <> ''
  AND p.sucursal_id IS NOT NULL
ON CONFLICT (sucursal_id, nombre) DO NOTHING;
