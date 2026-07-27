-- =========================================================================
-- 142_categorias_normalizadas.sql
--
-- `productos.categoria` es texto libre y no tiene FK, aunque existe la tabla
-- `categorias`. Consecuencias verificadas en prod:
--   - 5 categorías en uso NO existen en la tabla (LA VIRGINIA 21, ALICANTE 15,
--     PAPEL 3, AZUCAR 1 en Taco Pozo, CEPILLO DE DIENTES 1);
--   - 14 productos sin categoría, de los cuales 7 SON FIDEOS. Esos quedarían
--     fuera de un "mínimo 3 por sabor" cargado a la categoría Fideos, que es
--     justamente el caso de uso de la fase siguiente;
--   - la misma categoría escrita distinto en cada sucursal (FIDEO/FIDEOS,
--     PAPEL/PAPEL HIGIENICO), lo que hace incomparables los reportes de red.
--
-- NOTA: las categorías son POR SUCURSAL (UNIQUE (sucursal_id, nombre)), así que
-- FIDEO y FIDEOS no eran un duplicado dentro de una misma sucursal: se unifica
-- el NOMBRE para consistencia, no se mezclan productos entre sucursales.
--
-- Decisiones del dueño: AGUAS y AGUAS SABORIZADAS son distintas y quedan
-- separadas; se unifican los nombres entre sucursales; se asignan por nombre
-- solo los productos evidentes y los 5 restantes los clasifica él.
--
-- `productos.categoria` (text) se mantiene sincronizada para no romper el
-- código que todavía la lee (filtros, bot, PDFs). La migración a categoria_id
-- es gradual.
--
-- Resultado: 217 de 222 productos con categoria_id. Fideos alcanzables por el
-- mínimo por categoría: de 30 a 37 (Tucumán 22, Taco Pozo 15).
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Unificar nombres entre sucursales
-- -------------------------------------------------------------------------
UPDATE categorias SET nombre = 'FIDEOS', updated_at = now()
WHERE sucursal_id = 2 AND nombre = 'FIDEO'
  AND NOT EXISTS (SELECT 1 FROM categorias c2 WHERE c2.sucursal_id = 2 AND c2.nombre = 'FIDEOS');

UPDATE productos SET categoria = 'FIDEOS' WHERE sucursal_id = 2 AND trim(categoria) = 'FIDEO';
UPDATE productos SET categoria = 'PAPEL HIGIENICO' WHERE sucursal_id = 2 AND trim(categoria) = 'PAPEL';

-- -------------------------------------------------------------------------
-- 2. Crear las categorías que se usaban pero no existían en la tabla
-- -------------------------------------------------------------------------
INSERT INTO categorias (nombre, sucursal_id)
SELECT v.nombre, v.sucursal_id
FROM (VALUES
  ('LA VIRGINIA', 1::bigint),
  ('ALICANTE', 1::bigint),
  ('CEPILLO DE DIENTES', 1::bigint),
  ('PAPEL HIGIENICO', 2::bigint),
  ('AZUCAR', 2::bigint)
) AS v(nombre, sucursal_id)
WHERE NOT EXISTS (
  SELECT 1 FROM categorias c WHERE c.sucursal_id = v.sucursal_id AND c.nombre = v.nombre
);

-- -------------------------------------------------------------------------
-- 3. Asignar categoría a los productos evidentes que no la tenían.
--    Por id explícito, no por patrón de nombre: es un backfill puntual y no
--    conviene que una regex agarre de más.
--
--    Quedan sin categoría a propósito, para que los clasifique el dueño:
--    FERNET 750ML, ALBUM PANINI, FIGUERITA PANINI, LAUREL HOJA, MATE COCIDO.
-- -------------------------------------------------------------------------
UPDATE productos SET categoria = 'FIDEOS'
WHERE id IN (304, 305, 321, 322, 255, 256, 257)
  AND (categoria IS NULL OR trim(categoria) = '');

UPDATE productos SET categoria = 'VINOS'
WHERE id = 266 AND (categoria IS NULL OR trim(categoria) = '');

UPDATE productos SET categoria = 'AZUCAR'
WHERE id = 270 AND (categoria IS NULL OR trim(categoria) = '');

-- -------------------------------------------------------------------------
-- 4. FK real
-- -------------------------------------------------------------------------
ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS categoria_id uuid REFERENCES public.categorias(id);

CREATE INDEX IF NOT EXISTS idx_productos_categoria_id ON public.productos(categoria_id);

UPDATE productos p
SET categoria_id = c.id
FROM categorias c
WHERE c.sucursal_id = p.sucursal_id
  AND lower(trim(c.nombre)) = lower(trim(p.categoria))
  AND p.categoria_id IS DISTINCT FROM c.id;

COMMENT ON COLUMN public.productos.categoria_id IS
  'FK a categorias (por sucursal). Fuente de verdad de la categoría. `categoria` (text) se mantiene sincronizada hasta migrar todos los consumidores. Mig 142.';
