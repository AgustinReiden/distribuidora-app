-- Controles negativos del arnés de concurrencia (#1288, plan #1378 tarjeta 1). Grupo 1: los locks de pagos y de stock.
-- El grupo 2, el orden de los locks de productos, está en controles-negativos-orden.sql.
--
-- Un veredicto "200/200" sólo vale si el arnés habría dicho otra cosa con un bug. Acá se rompen a propósito dos
-- locks de la copia LOCAL de Docker, se corren las variantes que deberían ponerse rojas y se restauran.
-- NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre funciones de `public`.
--
--   1. psql -f controles-negativos.sql   (sección MUTAR; guarda las definiciones originales en conc.mut_orig)
--   2. node run.mjs c1 --variante C1c --out <dir>      → tiene que dar 0/40  (monto_pagado = 30 con pagos por 80)
--      node run.mjs c3 --variante C3a --out <dir>      → casi todas las rondas en rojo por 23514 (ver M2)
--      node run.mjs c3 --variante C3d --out <dir>      → 0/100, por 23514 (ver M2)
--      (Una carpeta --out por variante: run.mjs escribe <grupo>.md y pisa el de la variante anterior. Y no la de la
--      corrida limpia.) La auditoría se pone roja en CC-B (por M1); STK-B ya no (ver M2).
--   3. RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.
--
-- Qué se rompe:
--   M1  recalcular_monto_pagado_pedido(): se saca el `PERFORM 1 FROM pedidos WHERE id = v_id FOR UPDATE` de #1247.
--       Lo muerde C1c (INSERT directo en pagos, sólo el trigger). C1a sigue en verde: la RPC registrar_pagos_pedido_impl
--       lockea la boleta por su cuenta, así que ese camino no depende del lock del trigger.
--   M2  crear_pedido_completo(): se saca el `FOR UPDATE` de la fila de productos al leer el stock y, desde #1499, también
--       el pre-bloqueo de productos y contenedores (455): con ése solo, las dos ventas se siguen serializando y C3a y C3d
--       daban 300/300 y 100/100. Sin los dos, la segunda venta lee el stock viejo, pasa el chequeo y su UPDATE de stock
--       lo deja negativo, pero el CHECK productos_stock_no_negativo (466) lo rechaza: el síntoma es un 23514 en la venta
--       que llega segunda, no stock −1 / −4 ni STK-B (el stock nunca queda negativo y el verify de stock pasa). La ronda
--       sale en rojo por el error inesperado.
--       Medido el 07/11 (base = prod hasta la 474): sin la mutación, C3a 300/300 y C3d 100/100; con M2, C3a 22/300
--       (278 rondas con 23514: 126 en venta1 y 152 en venta2) y C3d 0/100 (un 23514 en cada ronda, en las cajas que
--       llegan tarde). Con M1, C1c 0/40 y CC-B en rojo (40).
--       NO se corre junto con el grupo 2: sin ese lock la venta toma los productos recién en su UPDATE de stock, en el
--       orden del JSON, y las variantes de orden (C10, C11) dejan de medir lo que dicen.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('recalcular_monto_pagado_pedido', 'crear_pedido_completo')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE d text;
BEGIN
  SELECT def INTO d FROM conc.mut_orig WHERE firma = 'recalcular_monto_pagado_pedido()';
  IF position('PERFORM 1 FROM pedidos WHERE id = v_id FOR UPDATE;' IN d) = 0 THEN RAISE EXCEPTION 'M1: no encontré el lock'; END IF;
  EXECUTE replace(d, 'PERFORM 1 FROM pedidos WHERE id = v_id FOR UPDATE;', 'NULL; -- MUTADO: sin lock');
  SELECT def INTO d FROM conc.mut_orig WHERE firma LIKE 'crear_pedido_completo(%';
  IF position('FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;' IN d) = 0 THEN RAISE EXCEPTION 'M2: no encontré el lock'; END IF;
  d := replace(d, 'FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;', 'FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal; -- MUTADO: sin lock');
  -- #1499: y el pre-bloqueo de productos y contenedores de la 455, que si no serializa las dos ventas por su cuenta.
  IF (length(d) - length(replace(d, E'   ORDER BY id\n     FOR UPDATE;\n  PERFORM 1 FROM promociones', ''))) / length(E'   ORDER BY id\n     FOR UPDATE;\n  PERFORM 1 FROM promociones') <> 1 THEN
    RAISE EXCEPTION 'M2: el pre-bloqueo de productos no aparece una sola vez';
  END IF;
  EXECUTE replace(d, E'   ORDER BY id\n     FOR UPDATE;\n  PERFORM 1 FROM promociones', E'   ORDER BY id; -- MUTADO: sin pre-bloqueo\n  PERFORM 1 FROM promociones');
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes; sirve para los dos grupos) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
