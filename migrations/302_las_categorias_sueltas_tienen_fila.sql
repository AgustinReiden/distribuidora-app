-- Las categorías sueltas tienen fila (#763)
--
-- El "+ Nueva categoría" de la ficha de producto escribía el nombre sólo en
-- `productos.categoria` (texto) y no creaba la fila en `categorias`. El trigger
-- `sync_producto_categoria_id` (mig 146) no la encontraba y dejaba
-- `categoria_id` en NULL: el producto se veía con categoría en la lista, pero no
-- tenía ninguna para todo lo que trabaja por id —calcular_comisiones,
-- avance_metas_preventista, guardar_meta_preventista, guardar_comision_regla,
-- actualizar_minimo_venta_masivo, asignar_marca_masiva—. El botón ya crea la
-- fila; esto arregla los 25 productos que quedaron así (relevado en prod el
-- 22/09 y de nuevo el 07/10: los mismos 25).
--
-- DECISIÓN DE CATÁLOGO (aprobada por el dueño el 07/10)
--
--   · FRAU y MANITO no son categorías, son MARCAS: se cargaron así porque la
--     ficha no tenía "+ Nueva marca". En Tucumán se crean las dos marcas, se
--     asignan, y cada producto pasa a una categoría real:
--       FRAU   aceite → ACEITE · alcohol → ALCOHOL · vinagre → VINAGRE
--              franela, rejilla, trapo de piso → LIMPIEZA · repelente → REPELENTE
--       MANITO papas fritas → SNACKS (ya existía)
--     ACEITE, ALCOHOL y VINAGRE se llaman igual que en Taco Pozo, para que el
--     corte por categoría sea el mismo en las dos sucursales.
--   · Las seis de Taco Pozo (NACHOS, ALCOHOL, ALFAJORES, ACEITE, SALES,
--     VINAGRE) SÍ son categorías: se crea la fila y el nombre no cambia.
--   · Los cuatro productos FRAU de Taco Pozo (aceite, alcohol ×2, vinagre) no
--     tenían marca: se crea FRAU en la sucursal 2 y se les asigna. Su categoría
--     no cambia.
--
-- CÓMO SE RESUELVE EL ID
--   Crear la fila no alcanza: el trigger corre en INSERT OR UPDATE OF
--   categoria, sucursal_id sobre `productos`, no al insertar en `categorias`.
--   Por eso se vuelve a escribir `categoria` en cada producto (en Taco Pozo, con
--   el mismo valor: `UPDATE OF` dispara por la columna nombrada en el SET, no
--   porque cambie). Ninguno toca stock, así que el ledger de stock y los lotes
--   no se mueven.
--
-- Idempotente: las filas se crean sólo si faltan, y los UPDATE filtran por el
-- texto viejo, así que una segunda corrida no hace nada.

-- ============================================================================
-- 1. Las filas de categorias que faltan
-- ============================================================================
INSERT INTO public.categorias (nombre, sucursal_id)
SELECT v.nombre, v.sucursal_id
  FROM (VALUES
    (1::bigint, 'ACEITE'), (1, 'ALCOHOL'), (1, 'VINAGRE'), (1, 'LIMPIEZA'), (1, 'REPELENTE'),
    (2, 'NACHOS'), (2, 'ALCOHOL'), (2, 'ALFAJORES'), (2, 'ACEITE'), (2, 'SALES'), (2, 'VINAGRE')
  ) AS v(sucursal_id, nombre)
 WHERE NOT EXISTS (
   SELECT 1 FROM public.categorias c
    WHERE c.sucursal_id = v.sucursal_id
      AND c.parent_id IS NULL
      AND lower(btrim(c.nombre)) = lower(v.nombre)
 );

-- ============================================================================
-- 2. Las marcas
-- ============================================================================
INSERT INTO public.marcas (nombre, sucursal_id)
VALUES ('FRAU', 1), ('MANITO', 1), ('FRAU', 2)
ON CONFLICT (sucursal_id, nombre) DO NOTHING;

-- ============================================================================
-- 3. Tucumán: FRAU y MANITO pasan a marca, y cada producto a su categoría
-- ============================================================================
UPDATE public.productos p
   SET categoria = v.categoria,
       marca_id  = (SELECT m.id FROM public.marcas m WHERE m.sucursal_id = 1 AND m.nombre = v.marca)
  FROM (VALUES
    (359::bigint, 'FRAU',   'ACEITE'),     -- ACEITE GIRASOL x 900cc
    (353,         'FRAU',   'ALCOHOL'),    -- ALCOHOL PURO x 250cc
    (352,         'FRAU',   'ALCOHOL'),    -- ALCOHOL PURO x 500cc
    (354,         'FRAU',   'VINAGRE'),    -- VINAGRE ALCOHOL x 1 LT
    (355,         'FRAU',   'VINAGRE'),    -- VINAGRE DE MANZANA x 1 LT
    (358,         'FRAU',   'LIMPIEZA'),   -- FRANELA
    (357,         'FRAU',   'LIMPIEZA'),   -- REJILLA
    (356,         'FRAU',   'LIMPIEZA'),   -- TRAPO DE PISO
    (378,         'FRAU',   'REPELENTE'),  -- REPELENTE FRAU 200ML
    (379,         'MANITO', 'SNACKS'),     -- PAPA CLASICA MANITO 1 KG
    (381,         'MANITO', 'SNACKS'),     -- PAPA SAB. AJI 1 KG
    (380,         'MANITO', 'SNACKS'),     -- PAPA SAB. CHEDAR 1 KG
    (382,         'MANITO', 'SNACKS')      -- PAPA SAB. JAMON 1 KG
  ) AS v(id, marca, categoria)
 WHERE p.id = v.id
   AND p.sucursal_id = 1
   AND p.categoria = v.marca;

-- ============================================================================
-- 4. Taco Pozo: marca FRAU a sus cuatro productos FRAU
-- ============================================================================
UPDATE public.productos p
   SET marca_id = (SELECT m.id FROM public.marcas m WHERE m.sucursal_id = 2 AND m.nombre = 'FRAU')
 WHERE p.sucursal_id = 2
   AND p.id IN (385, 386, 387, 388)  -- aceite, alcohol 250 y 500, vinagre de manzana
   AND p.marca_id IS NULL;

-- ============================================================================
-- 5. Re-escribir el texto para que el trigger resuelva categoria_id
-- ============================================================================
UPDATE public.productos p
   SET categoria = p.categoria
 WHERE p.categoria IS NOT NULL
   AND btrim(p.categoria) <> ''
   AND p.categoria_id IS NULL
   AND EXISTS (
     SELECT 1 FROM public.categorias c
      WHERE c.sucursal_id = p.sucursal_id
        AND c.parent_id IS NULL
        AND lower(btrim(c.nombre)) = lower(btrim(p.categoria))
   );

-- ============================================================================
-- Verificación
-- ============================================================================
DO $verif$
DECLARE
  v_sueltos int;
  v_sin_marca int;
BEGIN
  -- La consulta de cierre del issue: ningún producto con texto y sin id.
  SELECT count(*) INTO v_sueltos
    FROM public.productos
   WHERE categoria IS NOT NULL AND btrim(categoria) <> '' AND categoria_id IS NULL;
  IF v_sueltos <> 0 THEN
    RAISE EXCEPTION 'quedan % productos con categoría sin fila (#763)', v_sueltos;
  END IF;

  -- Las marcas no quedaron como categoría en ningún lado.
  IF EXISTS (SELECT 1 FROM public.productos WHERE upper(btrim(categoria)) IN ('FRAU', 'MANITO')) THEN
    RAISE EXCEPTION 'FRAU o MANITO siguen como categoría de algún producto (#763)';
  END IF;

  SELECT count(*) INTO v_sin_marca
    FROM public.productos
   WHERE id IN (352, 353, 354, 355, 356, 357, 358, 359, 378, 379, 380, 381, 382, 385, 386, 387, 388)
     AND marca_id IS NULL;
  IF v_sin_marca <> 0 THEN
    RAISE EXCEPTION '% productos FRAU/MANITO quedaron sin marca (#763)', v_sin_marca;
  END IF;
END
$verif$;
