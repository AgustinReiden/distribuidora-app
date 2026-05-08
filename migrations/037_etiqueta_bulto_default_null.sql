-- Migration 037: etiqueta_bulto sin default 'FARDO' + backfill huérfanos
--
-- Contexto:
-- La migración 031 creó productos.etiqueta_bulto con DEFAULT 'FARDO'. Como
-- consecuencia, todo producto creado o tocado después de esa migración quedó
-- con etiqueta_bulto='FARDO' aunque nunca se configuraran fardos. La validación
-- cruzada del schema Zod (modalProductoSchema.refine) exigía
-- unidades_de_venta_por_fardo cuando había etiqueta, lo que dejó al 94%
-- del catálogo (152 de 161 productos en producción) sin poder guardarse.
--
-- Modelo correcto: la etiqueta es accesoria al fardo. Si un producto no tiene
-- unidades_de_venta_por_fardo configurado, no tiene concepto de fardo y la
-- etiqueta debe ser NULL. El refine del schema Zod se elimina en este mismo
-- cambio (src/lib/schemas.ts).
--
-- Idempotente: el UPDATE filtra por la condición a normalizar; correr dos veces
-- no produce cambios adicionales. El DROP DEFAULT también es idempotente.

-- 1) Quitar el default 'FARDO' para que los nuevos productos arranquen con NULL.
ALTER TABLE productos
  ALTER COLUMN etiqueta_bulto DROP DEFAULT;

-- 2) Backfill: limpiar etiqueta_bulto en productos que nunca configuraron
--    unidades. El 'FARDO' que tienen vino del DEFAULT, no de una decisión
--    del usuario, así que no se pierde información.
UPDATE productos
SET etiqueta_bulto = NULL
WHERE unidades_de_venta_por_fardo IS NULL
  AND etiqueta_bulto IS NOT NULL;

-- 3) Documentar la nueva semántica.
COMMENT ON COLUMN productos.etiqueta_bulto IS
  'Etiqueta del bulto (FARDO, CAJA, PACK, BULTO). NULL si el producto no usa fardos. Solo se persiste con valor cuando unidades_de_venta_por_fardo IS NOT NULL.';
