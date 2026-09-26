-- El pedido 622 vale lo que se entrego
--
-- La nota del pedido lo dice desde el 23/04: "se pago el pedido entero pero hubo
-- una diferencia porque no quiso todos los fideos cargados... 3 MONO MEDIANO
-- $2.610, 4 TALLARIN $4.360, TOTAL = $6.970. No lo editamos directamente por
-- una cuestion de no modificar el stock que fue corregido despues de este
-- pedido". El renglon que el cliente no quiso es el de 3 MOSTACHO a $750
-- ($2.250), y el pedido siguio valiendo $9.220 cinco meses.
--
-- Se saca ese renglon SIN devolver stock, que es lo que la nota pedia: esas
-- 3 unidades ya entraron en el conteo posterior, y devolverlas ahora las
-- contaria dos veces. Por eso esto va por DELETE directo y no por
-- actualizar_pedido_items, que si repone. pedido_items no tiene trigger de
-- stock: el que mueve productos.stock es la RPC, no la fila.
--
-- Lo que esto NO toca: el pago 856 por $2.250. Con el total en $6.970 el pedido
-- queda 'parcial' con $4.720 pendientes. La nota dice que se cobro entero, y el
-- 2.250 coincide exacto con el renglon que se va -- parece la diferencia
-- cargada como si fuera el cobro --, pero corregir un pago es mover la caja de
-- un dia y eso lo decide administracion, no una migracion.

BEGIN;

-- Guarda: el pedido tiene que estar exactamente como se lo encontro. Si alguien
-- lo edito desde que se escribio esto, no se pisa nada.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pedidos
    WHERE id = 622 AND total = 9220 AND total_real = 9220 AND estado = 'entregado'
  ) OR NOT EXISTS (
    SELECT 1 FROM pedido_items
    WHERE id = 1658 AND pedido_id = 622 AND producto_id = 141
      AND cantidad = 3 AND subtotal = 2250 AND NOT es_bonificacion
  ) OR (SELECT count(*) FROM pedido_items WHERE pedido_id = 622) <> 3 THEN
    RAISE EXCEPTION 'El pedido 622 ya no esta como se lo encontro; revisar a mano.';
  END IF;
END $$;

DELETE FROM pedido_items WHERE id = 1658;

-- Totales derivados de los dos renglones que quedan, con la misma cuenta que
-- guardo el alta (neto_unitario / ingreso_real_unitario congelados por renglon).
UPDATE pedidos pe
SET total      = s.total,
    total_neto = s.neto,
    total_real = s.real,
    notas      = concat_ws(E'\n', NULLIF(pe.notas, ''),
                   '[mig 266] se saco el renglon de 3 MOSTACHO ($2.250) que el cliente no quiso; total = $6.970. Stock sin tocar (ver nota de arriba).')
FROM (
  SELECT SUM(subtotal) AS total,
         SUM(ROUND(neto_unitario * cantidad, 2)) AS neto,
         SUM(ingreso_real_unitario * cantidad) AS real
  FROM pedido_items WHERE pedido_id = 622
) s
WHERE pe.id = 622;

-- Guarda: total = lo que se entrego, VENTA-A (total = Σ subtotales) y el saldo
-- del cliente cerrando con la formula canonica (CC-A).
DO $$
DECLARE
  v_total numeric;
  v_cli   bigint;
  v_saldo numeric;
  v_canon numeric;
BEGIN
  SELECT total, cliente_id INTO v_total, v_cli FROM pedidos WHERE id = 622;
  IF v_total <> 6970 THEN
    RAISE EXCEPTION 'El total del 622 quedo en %, se esperaba 6970', v_total;
  END IF;

  SELECT saldo_cuenta INTO v_saldo FROM clientes WHERE id = v_cli;
  v_canon :=
    COALESCE((SELECT SUM(p.total - COALESCE(p.monto_pagado, 0)) FROM pedidos p
              WHERE p.cliente_id = v_cli AND p.estado NOT IN ('cancelado', 'anulado')), 0)
    - COALESCE((SELECT SUM(pg.monto) FROM pagos pg
                WHERE pg.cliente_id = v_cli AND pg.pedido_id IS NULL), 0);
  IF v_saldo <> v_canon THEN
    RAISE EXCEPTION 'saldo_cuenta del cliente % quedo en %, la formula da %', v_cli, v_saldo, v_canon;
  END IF;
END $$;

COMMIT;
