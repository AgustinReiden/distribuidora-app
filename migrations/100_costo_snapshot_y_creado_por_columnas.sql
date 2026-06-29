-- ============================================================================
-- 100 · Columnas: costo histórico por línea + creador del pedido
-- ============================================================================
-- Aditivas, sin cambio de comportamiento (se pueblan/usan en migs 101-103).
--
-- (1) pedido_items.costo_unitario_al_crear: costo REAL por unidad congelado al
--     alta = costo_sin_iva*(1+impuestos_internos/100). Resuelve que el reporte
--     valúe a costo VIVO del maestro (raíz del margen no reproducible y del
--     artefacto SALES). Patrón = pedido_items.stock_al_crear.
-- (2) pedidos.creado_por: quién CARGÓ el pedido (auditoría). usuario_id SIGUE
--     siendo el vendedor acreditado (cuando el admin elige preventista, queda el
--     preventista). Se eligió creado_por en vez de vendedor_id para NO tocar la
--     RLS de pedidos (da visibilidad al preventista por usuario_id=auth.uid()).
--     Histórico: solo fix forward (creado_por NULL en lo viejo).
-- ============================================================================

ALTER TABLE public.pedido_items
  ADD COLUMN IF NOT EXISTS costo_unitario_al_crear numeric NULL;
COMMENT ON COLUMN public.pedido_items.costo_unitario_al_crear IS
  'Costo real por unidad (costo_sin_iva*(1+imp_internos/100)) congelado al alta del pedido. NULL = línea vieja: el reporte cae al costo vivo del maestro.';

ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS creado_por uuid NULL;
COMMENT ON COLUMN public.pedidos.creado_por IS
  'Quién cargó el pedido (auth.uid del caller). usuario_id sigue siendo el vendedor acreditado. NULL = legacy (fix forward).';
