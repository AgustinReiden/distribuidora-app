-- Migración 030 — Fix: regalo de promos "Fracción" usa el producto disparador
--
-- Bug: en el modal de promos, la sección de regalo (`producto_regalo_id`) sólo
-- se muestra para `tipo_regalo='unidad_entera'`. En modo "Fracción de unidad"
-- el form sólo guarda `ajuste_producto_id` + `descripcion_regalo` + `unidades_por_bloque`,
-- y persiste `producto_regalo_id = NULL`. El resolver del frontend
-- (src/utils/promociones.ts:102) hace fallback al primer producto disparador
-- del pedido, así que las bonificaciones se cargan apuntando al disparador
-- (Manaos Cola, Placer Anana, etc.) en lugar del producto contenedor real.
--
-- Visible en la hoja de ruta del 03/05/2026: "4x MANAOS COLA 3000 cc x 6"
-- gratis cuando deberían ser 4 botellas de Manaos Granadina, etc.
--
-- Fix en dos partes:
--   A. Backfill de promos: copiar ajuste_producto_id → producto_regalo_id en
--      promos Fracción que tienen NULL.
--   B. Backfill de pedido_items con es_bonificacion=TRUE cuyo producto_id es
--      un disparador de la promo (no el regalo). Reapunta al producto correcto
--      y snapshotea descripcion_regalo. NO toca cantidad ni precio.
--
-- Idempotente (los WHERE filtran lo que ya está bien). Stock NO se ajusta
-- porque las promos Fracción tienen `regalo_mueve_stock=false` — el stock
-- siempre se descuenta vía `ajuste_producto_id` en bloques completos, no por
-- el item bonif individual. Reapuntar el item no afecta stock alguno.

BEGIN;

-- ============================================================================
-- A. Promociones Fracción sin producto_regalo_id → setearlo al contenedor.
-- ============================================================================
UPDATE promociones
SET producto_regalo_id = ajuste_producto_id
WHERE producto_regalo_id IS NULL
  AND ajuste_producto_id IS NOT NULL
  AND ajuste_automatico = TRUE
  AND descripcion_regalo IS NOT NULL;

-- ============================================================================
-- B. pedido_items mal cargados: producto_id = disparador en vez de regalo.
-- ============================================================================
-- Sólo toca items donde el producto_id actual está en la lista de disparadores
-- de la promo (promocion_productos), evitando modificar items legítimos.
UPDATE pedido_items pi
SET producto_id = pr.producto_regalo_id,
    descripcion_regalo = pr.descripcion_regalo
FROM promociones pr
WHERE pi.promocion_id = pr.id
  AND pi.es_bonificacion = TRUE
  AND pr.producto_regalo_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM promocion_productos pp
    WHERE pp.promocion_id = pr.id
      AND pp.producto_id = pi.producto_id
  )
  AND pi.producto_id IS DISTINCT FROM pr.producto_regalo_id;

COMMIT;
