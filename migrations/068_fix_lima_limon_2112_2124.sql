-- 068_fix_lima_limon_2112_2124.sql
--
-- Contexto: la promo 12 ("1 Fardo Placer 500cc + 1 Manaos 600cc") cambio su
-- regalo a Lima Limon (producto 85) para entregas del 28/05 en adelante. Todos
-- los pedidos de promo 12 con entrega >= 28/05 quedaron en Lima Limon, salvo
-- DOS que se crearon el 27/05 y nunca se re-editaron, por lo que conservaron el
-- snapshot viejo "Pomelo Blanco 600cc" (producto 87):
--   - #2112 (item 7134, cantidad 2)
--   - #2124 (item 7167, cantidad 1)
-- La usuaria confirma que fisicamente se entrego Lima Limon en ambos.
--
-- Esto NO fue causado por las migraciones 066/067 (esas filtran promocion_id=13;
-- esto es promocion_id=12). Es el mismo problema de snapshot al cambiar el
-- regalo de una promo, que no se propaga a pedidos ya creados/no editados.
--
-- Stock: el modelo descuenta 1 fardo cada 12 botellas regaladas. Mover 3
-- botellas de Pomelo Blanco (87) a Lima Limon (85) no cruza ningun limite de
-- bloque:
--   Lima Limon 27 -> 30 botellas (floor/12 = 2 fardos, sin cambio)
--   Pomelo Blanco 449 -> 446 botellas (floor/12 = 37 fardos, sin cambio)
-- => No hay ajuste de fardos. Correccion solo de display + nomenclatura.

UPDATE pedido_items
   SET producto_id = 85,
       descripcion_regalo = '1 Botella Manaos Lima Limon 600cc'
 WHERE promocion_id = 12
   AND es_bonificacion = true
   AND producto_id = 87
   AND pedido_id IN (2112, 2124);
