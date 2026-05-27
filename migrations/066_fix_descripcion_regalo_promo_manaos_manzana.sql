-- 066_fix_descripcion_regalo_promo_manaos_manzana.sql
--
-- Fix: la promoción "Promo Manaos 6 + 2 3L" (id=13) cambió de producto regalo
-- de POMELO BLANCO a MANZANA el 2026-05-26, pero el texto `descripcion_regalo`
-- quedó stale ("2 Botellas Manaos Pomelo Blanco 3L"). Ese texto se copia a
-- pedido_items.descripcion_regalo en cada pedido nuevo (RPC crear_pedido_completo,
-- ver migration 011) y es lo que imprimen la hoja de ruta y las comandas.
--
-- Esta migración:
--   a) Actualiza el snapshot en la promoción para que los pedidos nuevos
--      arranquen con el texto correcto.
--   b) Backfilea los pedido_items donde producto_id ya apunta al nuevo regalo
--      (Manzana, id=82) pero el texto quedó con "Pomelo Blanco". El match
--      estricto evita pisar pedidos viejos de la era Pomelo Blanco.

UPDATE promociones
   SET descripcion_regalo = '2 Botellas Manaos Manzana 3000 cc'
 WHERE id = 13
   AND descripcion_regalo = '2 Botellas Manaos Pomelo Blanco 3L';

UPDATE pedido_items
   SET descripcion_regalo = '2 Botellas Manaos Manzana 3000 cc'
 WHERE promocion_id = 13
   AND es_bonificacion = true
   AND producto_id = 82
   AND descripcion_regalo = '2 Botellas Manaos Pomelo Blanco 3L';
