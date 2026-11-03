-- Controles negativos del arnés de concurrencia (#1288, plan #1378 tarjeta 1). Grupo 1: los locks de pagos y de stock.
-- El grupo 2, el orden de los locks de productos, está en controles-negativos-orden.sql.
--
-- Un veredicto "200/200" sólo vale si el arnés habría dicho otra cosa con un bug. Acá se rompen a propósito dos
-- locks de la copia LOCAL de Docker, se corren las variantes que deberían ponerse rojas y se restauran.
-- NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre funciones de `public`.
--
--   1. psql -f controles-negativos.sql   (sección MUTAR; guarda las definiciones originales en conc.mut_orig)
--   2. node run.mjs c1 --variante C1c --out <dir>      → tiene que dar 0/40  (monto_pagado = 30 con pagos por 80)
--      node run.mjs c3 --variante C3a --out <dir>      → tiene que dar 0/300 (stock −1, dos ventas vivas)
--      node run.mjs c3 --variante C3d --out <dir>      → tiene que dar 0/100 (stock −4, ocho ventas vivas)
--      (Una carpeta --out por variante: run.mjs escribe <grupo>.md y pisa el de la variante anterior. Y no la de la
--      corrida limpia.) La auditoría también se pone roja (CC-B, STK-B).
--   3. RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.
--
-- Qué se rompe:
--   M1  recalcular_monto_pagado_pedido(): se saca el `PERFORM 1 FROM pedidos WHERE id = v_id FOR UPDATE` de #1247.
--       Lo muerde C1c (INSERT directo en pagos, sólo el trigger). C1a sigue en verde: la RPC registrar_pagos_pedido_impl
--       lockea la boleta por su cuenta, así que ese camino no depende del lock del trigger.
--   M2  crear_pedido_completo(): se saca el `FOR UPDATE` de la fila de productos al leer el stock. Lo muerden C3a y C3d.
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
  EXECUTE replace(d, 'FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;', 'FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal; -- MUTADO: sin lock');
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes; sirve para los dos grupos) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
