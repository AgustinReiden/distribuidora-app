-- =========================================================================
-- 158_marcas.sql
--
-- "Quiero ver cuánto facturó cada preventista en La Virginia, en Manaos, y
--  cuántas Placer y cuántas gaseosas vendió."
--
-- Hoy eso no se puede: no existe el concepto de marca. Las marcas están
-- metidas como filas de `categorias`, y cada sucursal lo hace distinto:
--
--   sucursal 1 (Tucumán): las categorías son MARCAS — ALICANTE (32 productos),
--     LA VIRGINIA (20), MANAOS (16), PLACER (14), MOLINO (12),
--     VILLAMANAOS//BICHY (6), PINDAPOY (2) — mezcladas con categorías reales
--     (FIDEOS, PAPAS FRITAS, NACHOS, PAPEL HIGIENICO, ALFAJORES, ...).
--   sucursal 2 (Taco Pozo): las categorías son CATEGORÍAS de verdad —
--     GASEOSAS, AGUAS, AGUAS SABORIZADAS, SNACKS, JUGOS, LATAS, VINOS — y la
--     marca vive dentro del nombre del producto ("PLACER NARANJA 1500CC X 6").
--
-- Con una sola dimensión no se puede pedir "Manaos gaseosas": marca y
-- categoría son ortogonales y necesitan columnas distintas.
--
-- BACKFILL: solo el determinístico — las categorías de la sucursal 1 que son
-- marcas, listadas por id explícito (precedente mig 145 §3: por id, nunca por
-- patrón de nombre). La sucursal 2 queda sin marcas asignadas y se completa
-- desde la UI con la asignación masiva de abajo, filtrando por nombre.
--
-- NO se desactivan las categorías que pasan a ser marcas: dejar productos con
-- categoria_id NULL rompería calcular_comisiones (mig 150) y el breakdown por
-- categoría de reporte_gerencial (mig 130). Esa reclasificación la hace el
-- dueño desde la UI, después y a mano.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Tabla. Espejo deliberado de `categorias` (mig 009): mismo tipo de id,
--    mismo UNIQUE por sucursal, mismas policies. Permite clonar los hooks y
--    la UI en vez de inventar una forma nueva.
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.marcas (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre       text NOT NULL CHECK (length(btrim(nombre)) > 0),
  sucursal_id  bigint NOT NULL REFERENCES public.sucursales(id) ON DELETE CASCADE,
  activa       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sucursal_id, nombre)
);

CREATE INDEX IF NOT EXISTS idx_marcas_sucursal ON public.marcas (sucursal_id);

COMMENT ON TABLE public.marcas IS
  'Marcas comerciales por sucursal (Manaos, La Virginia, Placer...). Ortogonal a categorias: un producto tiene una marca Y una categoría. Mig 158.';

ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS marca_id uuid REFERENCES public.marcas(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_productos_marca_id ON public.productos (marca_id);

COMMENT ON COLUMN public.productos.marca_id IS
  'FK a marcas. NULL = sin marca asignada (los reportes por marca lo informan como cobertura incompleta). Mig 158.';

-- -------------------------------------------------------------------------
-- 2. updated_at + RLS (patrón mt_categorias_*)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.marcas_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_marcas_updated_at ON public.marcas;
CREATE TRIGGER trg_marcas_updated_at
  BEFORE UPDATE ON public.marcas
  FOR EACH ROW
  EXECUTE FUNCTION public.marcas_set_updated_at();

ALTER TABLE public.marcas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mt_marcas_select ON public.marcas;
CREATE POLICY mt_marcas_select
  ON public.marcas FOR SELECT TO authenticated
  USING (sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_marcas_insert ON public.marcas;
CREATE POLICY mt_marcas_insert
  ON public.marcas FOR INSERT TO authenticated
  WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_marcas_update ON public.marcas;
CREATE POLICY mt_marcas_update
  ON public.marcas FOR UPDATE TO authenticated
  USING (public.es_admin() AND sucursal_id = public.current_sucursal_id())
  WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS mt_marcas_delete ON public.marcas;
CREATE POLICY mt_marcas_delete
  ON public.marcas FOR DELETE TO authenticated
  USING (public.es_admin() AND sucursal_id = public.current_sucursal_id());

-- -------------------------------------------------------------------------
-- 3. Backfill determinístico: categorías de la sucursal 1 que son marcas.
--    Por id explícito. Idempotente.
-- -------------------------------------------------------------------------
INSERT INTO public.marcas (nombre, sucursal_id)
SELECT c.nombre, c.sucursal_id
FROM public.categorias c
WHERE c.id IN (
  '334430bf-62d8-4c15-a940-3e6204e0c8f9',  -- ALICANTE
  '26c9d4f3-00bb-42d0-b0e5-8623ad568918',  -- LA VIRGINIA
  'e7ab6a04-ac9e-44af-bcb4-010b0342643a',  -- MANAOS
  'e0669c9e-73dc-4aa1-aa83-a8c86cad99bc',  -- PLACER
  '8af81b1b-d5f9-4f00-9f0e-06ea6de368d4',  -- MOLINO
  '739fd3b8-37e2-494f-9c74-c0e6379d2c21',  -- VILLAMANAOS//BICHY
  '5acbef81-2ce8-42f7-aa1c-13f530d1f6ba'   -- PINDAPOY
)
ON CONFLICT (sucursal_id, nombre) DO NOTHING;

-- Los productos que cuelgan de esas categorías heredan la marca homónima.
-- Solo se pisa marca_id si está NULL: re-aplicar no deshace correcciones
-- manuales hechas desde la UI.
UPDATE public.productos p
SET marca_id = m.id
FROM public.categorias c
JOIN public.marcas m
  ON m.sucursal_id = c.sucursal_id
 AND lower(btrim(m.nombre)) = lower(btrim(c.nombre))
WHERE p.categoria_id = c.id
  AND p.sucursal_id = c.sucursal_id
  AND p.marca_id IS NULL
  AND c.id IN (
    '334430bf-62d8-4c15-a940-3e6204e0c8f9',
    '26c9d4f3-00bb-42d0-b0e5-8623ad568918',
    'e7ab6a04-ac9e-44af-bcb4-010b0342643a',
    'e0669c9e-73dc-4aa1-aa83-a8c86cad99bc',
    '8af81b1b-d5f9-4f00-9f0e-06ea6de368d4',
    '739fd3b8-37e2-494f-9c74-c0e6379d2c21',
    '5acbef81-2ce8-42f7-aa1c-13f530d1f6ba'
  );

-- -------------------------------------------------------------------------
-- 4. Asignación masiva. Clon de actualizar_minimo_venta_masivo (mig 147) con
--    dos modos, porque el trabajo real es mixto: "toda esta categoría es
--    Manaos" (sucursal 1) y "estos 14 productos que filtré por nombre son
--    Placer" (sucursal 2).
--
--    p_marca_id NULL quita la marca (permite deshacer una asignación errada).
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.asignar_marca_masiva(
  p_marca_id     uuid,
  p_categoria_id uuid    DEFAULT NULL,
  p_producto_ids bigint[] DEFAULT NULL
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
    RAISE EXCEPTION 'Solo un admin o encargado puede asignar marcas'
      USING ERRCODE = '42501';
  END IF;

  IF p_categoria_id IS NULL AND (p_producto_ids IS NULL OR cardinality(p_producto_ids) = 0) THEN
    RAISE EXCEPTION 'Indicá una categoría o una lista de productos';
  END IF;

  -- La marca tiene que ser de la sucursal activa: sin este chequeo se podría
  -- pegar un producto de una sucursal a una marca de la otra.
  IF p_marca_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM marcas
    WHERE id = p_marca_id AND sucursal_id = current_sucursal_id()
  ) THEN
    RAISE EXCEPTION 'La marca no existe en esta sucursal';
  END IF;

  UPDATE productos
  SET marca_id = p_marca_id
  WHERE sucursal_id = current_sucursal_id()
    AND (
      (p_categoria_id IS NOT NULL AND categoria_id = p_categoria_id)
      OR (p_producto_ids IS NOT NULL AND id = ANY (p_producto_ids))
    );
  GET DIAGNOSTICS v_actualizados = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'actualizados', v_actualizados);
END;
$fn$;

ALTER FUNCTION public.asignar_marca_masiva(uuid, uuid, bigint[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.asignar_marca_masiva(uuid, uuid, bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.asignar_marca_masiva(uuid, uuid, bigint[]) TO authenticated;

COMMENT ON FUNCTION public.asignar_marca_masiva(uuid, uuid, bigint[]) IS
  'Asigna una marca a todos los productos de una categoría o a una lista de productos, en la sucursal activa. p_marca_id NULL la quita. Mig 158.';
