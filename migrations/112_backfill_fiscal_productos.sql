-- ============================================================================
-- 112 · Backfill fiscal de productos (revisado y aprobado por el usuario 2026-07-13)
-- ============================================================================
-- Tres pasos, con listas de ids congeladas tras revisión en prod:
--   1) Restaurar porcentaje_iva=21 en los 42 productos envenenados por el bug
--      de compras ZZ (mig 111 elimina la causa). IMPORTANTE: NO se toca
--      productos.precio (precio final de venta, es lo que factura el negocio);
--      solo el atributo fiscal y el derivado informativo precio_sin_iva.
--   2) Cargar tasas efectivas de impuestos internos según evidencia de la
--      factura Refres Now A 0005-00455160 (16/06/2026) + analogía aprobada:
--        8,6956% → cola / granadina / manzana / pomelo (blanco, amarillo,
--                  rosado) / tónica / Coca Cola
--        4,1667% → lima limón / limón / naranja / citrus / Placer / aguas
--        0%      → soda sifón / jugos Pindapoy / vinos
--      (La tasa es por contenido de jugo, NO por familia cítrica: la factura
--      muestra pomelo blanco a 8,6956 y naranja a 4,1667.)
--   3) Inicializar ultimo_tipo_compra desde la última compra no cancelada y
--      recomputar costo_real / costo_con_iva canónicos para todos.
-- Nota: NO se backfillea pedido_items.costo_unitario_al_crear (falsearía la
-- historia; el COALESCE del reporte ya maneja el NULL).
-- ============================================================================

-- ─── 1. porcentaje_iva = 21 (42 productos, sin tocar precio) ───────────────

UPDATE public.productos
   SET porcentaje_iva = 21,
       precio_sin_iva = round(precio / 1.21, 2),
       updated_at     = NOW()
 WHERE id IN (
   -- sucursal 1 (Tucumán)
   156,157,138,242,246,247,250,131,133,249,104,102,101,129,105,106,248,166,241,251,
   -- sucursal 2 (Taco Pozo)
   267,270,254,226,265,233,262,231,261,268,225,244,243,245,224,204,206,207,205,269,266,227
 )
   AND (porcentaje_iva = 0 OR porcentaje_iva IS NULL);

-- ─── 2. Tasas de impuestos internos ─────────────────────────────────────────

-- 8,6956% efectiva (colas y sabores sin jugo computable + tónica + Coca Cola)
UPDATE public.productos
   SET impuestos_internos = 8.6956, updated_at = NOW()
 WHERE id IN (
   -- suc 1: MANAOS COLA 1,5/3L/600, GRANADINA, MANZANA, POMELO BLANCO 1,5/3L/600
   130,78,84,83,82,133,81,87,
   -- suc 2: COLA 1500/2250/3000/600, GRANADINA, LATA COLA, MANZANA,
   --        POMELO BLANCO 1500/2250/3000, POMELO AMARILLO, POMELO ROSADO,
   --        LATA POMELO BLANCO, LATA TONICA, TONICA, COCA COLA
   239,177,178,219,198,179,185,236,212,189,188,190,182,253,214,226
 );

-- 4,1667% efectiva (sabores con jugo: lima limón/limón/naranja/citrus,
-- Placer, aguas con y sin gas, latas lima/naranja)
UPDATE public.productos
   SET impuestos_internos = 4.1667, updated_at = NOW()
 WHERE id IN (
   -- suc 1: LIMA LIMON 1,5/3L/600, NARANJA 1,5/3L/600, CITRUS, AGUA BIDON,
   --        AGUA C/GAS, AGUA S/GAS 2L/600, PLACER (todos)
   131,79,85,132,80,86,77,128,72,127,126,
   134,161,94,97,135,162,92,136,95,98,93,96,124,125,
   -- suc 2: LIMA LIMON 1500/2250/3000/600, LIMON, NARANJA 1500/2250/3000/600,
   --        CITRUS 2250/3000, LATA LIMA, LATA NARANJA, AGUA BIDON, AGUA C/GAS,
   --        AGUA S/GAS 2000/600, AGUA EL SANO, PLACER (todos)
   238,213,183,184,199,237,186,187,220,215,252,180,181,173,174,175,176,172,
   200,192,222,201,210,216,193,211,194,264,195,221,196,197
 );

-- 0% explícito (soda sifón / Bichy, jugos Pindapoy, vinos)
UPDATE public.productos
   SET impuestos_internos = 0, updated_at = NOW()
 WHERE id IN (89,158,191,208,217,209,218,227,266);

-- ─── 3. ultimo_tipo_compra + recomputo de costos canónicos ─────────────────

UPDATE public.productos p
   SET ultimo_tipo_compra = sub.tipo_factura
  FROM (
    SELECT DISTINCT ON (ci.producto_id, ci.sucursal_id)
           ci.producto_id, ci.sucursal_id, c.tipo_factura
      FROM compra_items ci
      JOIN compras c ON c.id = ci.compra_id
     WHERE c.estado <> 'cancelada'
     ORDER BY ci.producto_id, ci.sucursal_id, c.fecha_compra DESC, c.id DESC
  ) sub
 WHERE p.id = sub.producto_id
   AND p.sucursal_id = sub.sucursal_id;

UPDATE public.productos
   SET costo_real = costo_real_unitario(
         costo_sin_iva, impuestos_internos, COALESCE(ultimo_tipo_compra, 'FC')),
       costo_con_iva = costo_financiero_unitario(
         costo_sin_iva, porcentaje_iva, impuestos_internos, COALESCE(ultimo_tipo_compra, 'FC')),
       updated_at = NOW()
 WHERE costo_sin_iva IS NOT NULL;
