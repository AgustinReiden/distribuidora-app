-- 067_revertir_pomelo_blanco_4_pedidos.sql
--
-- Contexto: la promo 13 ("Promo Manaos 6 + 2 3L") cambio su producto regalo de
-- Pomelo Blanco (81) a Manzana (82) a mitad del 26/05/2026. Los usuarios ya
-- habian comprometido entregar Pomelo Blanco para los pedidos viejos y recien
-- entregan Manzana desde el 27/05. La migracion 066 retropropago "Manzana" a
-- esos pedidos, que quedo al reves.
--
-- Regla: pedidos creados <= 26/05 -> Pomelo Blanco (81); creados >= 27/05 ->
-- Manzana (82). Solo 4 pedidos creados el 26/05 quedaron mal: 2077, 2093, 2097,
-- 2108. Los 7 del 27/05 y la promo (apunta a Manzana) quedan como estan.
--
-- Stock (modo fraccion: 6 botellas regaladas = 1 fardo): mover las 18 botellas
-- de esos 4 pedidos de Manzana a Pomelo = exactamente 3 fardos. Ajuste neto:
-- Pomelo (81) -3, Manzana (82) +3. El contador promociones.usos_pendientes no
-- cambia (movimiento de bloques completos). No se tocan inconsistencias
-- historicas previas del ledger ni promo_acumuladores.

-- Paso 1: corregir producto + texto del regalo en los 4 pedidos (lo que ven
-- tarjetas, hoja de ruta y comandas). Sin triggers de stock sobre pedido_items.
UPDATE pedido_items
   SET producto_id = 81,
       descripcion_regalo = '2 Botellas Manaos Pomelo Blanco 3L'
 WHERE promocion_id = 13
   AND es_bonificacion = true
   AND producto_id = 82
   AND pedido_id IN (2077, 2093, 2097, 2108);

-- Paso 2: ajuste neto de stock (3 fardos) + auditoria en mermas_stock /
-- promo_ajustes. Idempotente via marcador en observaciones.
DO $$
DECLARE
  v_suc     bigint := 1;
  v_marker  text   := 'Correccion Promo 13 (mig 067): 4 pedidos 26/05 reasignados Manzana->Pomelo Blanco';
  v_old     int;
  v_new     int;
  v_merma   bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM mermas_stock WHERE observaciones = v_marker) THEN
    RAISE NOTICE 'Ajuste de stock 067 ya aplicado; se omite.';
    RETURN;
  END IF;

  PERFORM set_config('app.stock_origen', 'correccion_mig_067', true);

  -- Pomelo Blanco (81): descontar 3 fardos
  SELECT stock INTO v_old FROM productos WHERE id = 81 AND sucursal_id = v_suc FOR UPDATE;
  v_new := v_old - 3;
  UPDATE productos SET stock = v_new WHERE id = 81 AND sucursal_id = v_suc;
  INSERT INTO mermas_stock (producto_id, cantidad, motivo, observaciones, stock_anterior, stock_nuevo, sucursal_id)
  VALUES (81, 3, 'promociones', v_marker, v_old, v_new, v_suc)
  RETURNING id INTO v_merma;
  INSERT INTO promo_ajustes (promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, sucursal_id, observaciones)
  VALUES (13, 18, 3, 81, v_merma, v_suc, v_marker);

  -- Manzana (82): devolver 3 fardos
  SELECT stock INTO v_old FROM productos WHERE id = 82 AND sucursal_id = v_suc FOR UPDATE;
  v_new := v_old + 3;
  UPDATE productos SET stock = v_new WHERE id = 82 AND sucursal_id = v_suc;
  INSERT INTO mermas_stock (producto_id, cantidad, motivo, observaciones, stock_anterior, stock_nuevo, sucursal_id)
  VALUES (82, -3, 'promociones_reversion', v_marker, v_old, v_new, v_suc)
  RETURNING id INTO v_merma;
  INSERT INTO promo_ajustes (promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, sucursal_id, observaciones)
  VALUES (13, -18, -3, 82, v_merma, v_suc, v_marker);
END $$;
