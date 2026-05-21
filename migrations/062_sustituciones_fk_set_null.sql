-- =========================================================================
-- 062_sustituciones_fk_set_null.sql
--
-- Bug arquitectural de mig 058: la FK pedido_item_sustituciones.pedido_item_id
-- tiene ON DELETE CASCADE. Como `actualizar_pedido_items` ejecuta
-- `DELETE FROM pedido_items WHERE pedido_id = X` y reinserta, el CASCADE
-- borra automaticamente TODAS las sustituciones del pedido antes de que
-- mi trigger BEFORE INSERT (mig 060) tenga oportunidad de aplicarlas en
-- el nuevo INSERT.
--
-- Las sustituciones son audit historico. Deben sobrevivir al ciclo
-- DELETE/INSERT de pedido_items. Fix:
--   * Hacer `pedido_item_id` NULLABLE.
--   * Cambiar la FK a ON DELETE SET NULL: si se borra el item, la fila
--     de sustitucion sobrevive sin link al item viejo.
--
-- Adicionalmente reconcilia el pedido 1966 (caso reportado por el usuario):
--   * Re-inserta la fila de sustitucion (con pedido_item_id=NULL porque el
--     item original ya fue borrado).
--   * Actualiza el item bonificacion actual del pedido para que apunte al
--     producto sustituto (Naranja) en lugar del original (Pomelo Blanco).
--   * Agrega el "[Sustituido por: X]" al descripcion_regalo si no esta.
-- =========================================================================

BEGIN;

-- 1) Hacer pedido_item_id NULLABLE
ALTER TABLE public.pedido_item_sustituciones
  ALTER COLUMN pedido_item_id DROP NOT NULL;

-- 2) Cambiar FK de CASCADE a SET NULL
ALTER TABLE public.pedido_item_sustituciones
  DROP CONSTRAINT IF EXISTS pedido_item_sustituciones_pedido_item_id_fkey;

ALTER TABLE public.pedido_item_sustituciones
  ADD CONSTRAINT pedido_item_sustituciones_pedido_item_id_fkey
  FOREIGN KEY (pedido_item_id)
  REFERENCES public.pedido_items(id)
  ON DELETE SET NULL;

COMMENT ON COLUMN public.pedido_item_sustituciones.pedido_item_id IS
  'Referencia al item de pedido al momento de la sustitucion. Se setea a NULL si el item original es borrado por DELETE+INSERT (ej. actualizar_pedido_items). La fila de sustitucion sobrevive como audit historico. La logica de aplicar sustituciones usa (pedido_id, promocion_id, producto_original_id), no este campo.';

-- 3) Reconciliacion del pedido 1966
-- Re-insertar la sustitucion perdida por el CASCADE el 2026-05-20 21:57:07.
-- Datos verificados desde audit_logs:
--   - pedido_id=1966, promocion_id=12
--   - producto_original_id=87 (Pomelo Blanco), producto_sustituto_id=86 (Naranja)
--   - cantidad=12, motivo del usuario
--   - autorizado_por: usuario que hizo la sustitucion (d1614e4f-7a9c-49b9-90c3-49b007c5f242)
--   - sucursal_id=1
--
-- pedido_item_id queda NULL porque el item original (6585) ya fue borrado
-- y el item reinsertado (6590) tiene producto_id=87 (no es la fila a la
-- que la sustitucion apuntaba).
INSERT INTO public.pedido_item_sustituciones (
  pedido_id, pedido_item_id, promocion_id,
  producto_original_id, producto_sustituto_id,
  cantidad_original, cantidad_sustituta,
  regalo_mueve_stock_snapshot, ajuste_producto_id_nuevo,
  motivo, autorizado_por, sucursal_id, created_at
) VALUES (
  1966, NULL, 12,
  87, 86,
  12, 12,
  FALSE,  -- Promo 12 es modo B (regalo_mueve_stock=false)
  NULL,   -- Admin no eligio contenedor del sustituto en su momento
  'PIDIO QUE LE ENTREGUEMOS OTRO SABOR PORQUE LA POMELO BLANCO NO LE SALE [reconciliado mig 062]',
  'd1614e4f-7a9c-49b9-90c3-49b007c5f242'::UUID,
  1,
  '2026-05-20 21:50:57.141445+00'::TIMESTAMPTZ
);

-- 4) Restablecer el item bonificacion 6590 (que es el item reinsertado a
-- las 21:57:07) para que refleje la sustitucion: producto_id=86 (Naranja),
-- descripcion_regalo con el marker "[Sustituido por: X]".
UPDATE public.pedido_items
   SET producto_id = 86,
       descripcion_regalo = '1 Botella Manaos Pomelo Blanco 600cc [Sustituido por: MANAOS NARANJA 600 cc x 12]'
 WHERE id = 6590
   AND pedido_id = 1966
   AND es_bonificacion = TRUE;

-- 5) Trace en historial
INSERT INTO public.pedido_historial (
  pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id
) VALUES (
  1966, NULL, 'reconciliacion_sustitucion',
  'item 6590 con producto_id=87 (original, perdida la sustitucion)',
  'item 6590 con producto_id=86 (sustituto reconstruido por mig 062)',
  1
);

COMMIT;
