-- Borrar un cliente no se lleva sus pagos
--
-- La mig 199 (#490) les devolvio el cliente a los pedidos huerfanos, pero dejo
-- afuera la otra mitad del mismo borrado: pagos_cliente_id_fkey era (y hasta
-- aca seguia siendo) ON DELETE CASCADE. Cuando se deduplicaron clientes, el
-- DELETE del viejo desprendio sus pedidos (SET NULL, cerrado en la 200) y
-- BORRO sus pagos. El trigger de monto_pagado recalculo y las boletas cobradas
-- quedaron en 'pendiente'; mientras eran huerfanas no se veian en ninguna lista,
-- y al reaparecer con la 199 aparecieron como deuda "de la nada".
--
-- Medido en prod: 5 pagos en 3 borrados de clientes (395 el 02/05, 823 el
-- 05/07, 282 el 28/07):
--   pedido 418  $37.800  pendiente  <- el reclamo
--   pedido 1128 $34.800  pendiente
--   pedido 3081 $19.800  pendiente
--   pedido 849  $29.200  'pagado' sin ningun pago que lo respalde
--   pedido 1273 $23.950  'pagado' sin ningun pago que lo respalde
-- Los dos ultimos son el mismo agujero visto al reves: se borraron antes de que
-- existiera el trigger de recalculo (mig 035), asi que monto_pagado quedo en el
-- valor viejo. Restaurarlos no mueve su estado; les devuelve el respaldo.
--
-- Por que se puede restaurar sin miedo a cobrar dos veces (verificado al
-- escribir esto, y re-verificado abajo por la guarda):
--   - ninguno de los 5 pedidos tiene hoy un pago que cubra lo borrado;
--   - los clientes sucesores (653, 824, 335) no tienen pagos a cuenta que
--     pudieran haber saldado esa "deuda" por otro lado.
--
-- Se restaura cada pago con su id, fecha, monto, usuario y created_at
-- originales -- el audit_logs guardo la fila entera --, apuntando al cliente
-- que HOY tiene el pedido (la 199 ya lo reatribuyo). Se lee del audit, no se
-- hardcodean ids: la definicion es "pago borrado en la misma transaccion que
-- un cliente".
--
-- Y se cierra la puerta: la FK pasa a RESTRICT, como la de pedidos en la 200.
-- Un cobro es historial de caja; que desaparezca porque se borro la ficha del
-- cliente no es una consecuencia aceptable de nada.

BEGIN;

CREATE TEMP TABLE _pagos_perdidos ON COMMIT DROP AS
SELECT DISTINCT ON ((a.old_data->>'id')::int)
       (a.old_data->>'id')::int                AS id,
       (a.old_data->>'pedido_id')::int         AS pedido_id,
       (a.old_data->>'cliente_id')::int        AS cliente_borrado,
       (a.old_data->>'monto')::numeric         AS monto,
       a.old_data,
       a.created_at                            AS borrado_at
FROM audit_logs a
WHERE a.tabla = 'pagos'
  AND a.accion = 'DELETE'
  AND EXISTS (
    SELECT 1 FROM audit_logs c
    WHERE c.tabla = 'clientes' AND c.accion = 'DELETE'
      AND c.created_at = a.created_at
  )
  AND NOT EXISTS (SELECT 1 FROM pagos p WHERE p.id = (a.old_data->>'id')::int)
ORDER BY (a.old_data->>'id')::int, a.created_at DESC;

-- Guarda: sin pedido no hay a quien devolverselo (un pago a cuenta del cliente
-- borrado). Hoy no hay ninguno; si aparece, se decide a mano, no aca.
-- Y ninguno puede dejar su pedido sobrepagado.
DO $$
DECLARE
  v_sin_pedido int;
  v_sobrepago  text;
BEGIN
  SELECT count(*) INTO v_sin_pedido
  FROM _pagos_perdidos pp
  WHERE pp.pedido_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM pedidos pe WHERE pe.id = pp.pedido_id);
  IF v_sin_pedido > 0 THEN
    RAISE EXCEPTION '% pagos perdidos no tienen pedido al que volver', v_sin_pedido;
  END IF;

  SELECT string_agg(pe.id::text, ', ') INTO v_sobrepago
  FROM pedidos pe
  JOIN (SELECT pedido_id, SUM(monto) AS monto FROM _pagos_perdidos GROUP BY pedido_id) pp
    ON pp.pedido_id = pe.id
  WHERE pe.estado IN ('cancelado', 'anulado')
     OR COALESCE((SELECT SUM(x.monto) FROM pagos x WHERE x.pedido_id = pe.id), 0) + pp.monto > pe.total;
  IF v_sobrepago IS NOT NULL THEN
    RAISE EXCEPTION 'Restaurar dejaria sobrepagados o cobrados-cancelados a: %', v_sobrepago;
  END IF;
END $$;

INSERT INTO pagos (
  id, cliente_id, pedido_id, monto, forma_pago, referencia, notas,
  usuario_id, created_at, sucursal_id, fecha, client_request_id
)
SELECT
  pp.id,
  pe.cliente_id,
  pp.pedido_id,
  pp.monto,
  COALESCE(pp.old_data->>'forma_pago', 'efectivo'),
  pp.old_data->>'referencia',
  concat_ws(E'\n', NULLIF(pp.old_data->>'notas', ''),
    format('[mig 265] restaurado: lo borro el CASCADE al eliminar el cliente %s el %s.',
           pp.cliente_borrado, to_char(pp.borrado_at AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY'))),
  (pp.old_data->>'usuario_id')::uuid,
  (pp.old_data->>'created_at')::timestamptz,
  pe.sucursal_id,
  (pp.old_data->>'fecha')::date,
  (pp.old_data->>'client_request_id')::uuid
FROM _pagos_perdidos pp
JOIN pedidos pe ON pe.id = pp.pedido_id;

-- Guarda: cada pedido tocado quedo con monto_pagado = Σ pagos, y el saldo de
-- sus clientes sigue cerrando con la formula canonica (check CC-A).
DO $$
DECLARE
  v_malos text;
BEGIN
  SELECT string_agg(pe.id::text, ', ') INTO v_malos
  FROM pedidos pe
  WHERE pe.id IN (SELECT pedido_id FROM _pagos_perdidos)
    AND pe.monto_pagado <> COALESCE((SELECT SUM(x.monto) FROM pagos x WHERE x.pedido_id = pe.id), 0);
  IF v_malos IS NOT NULL THEN
    RAISE EXCEPTION 'monto_pagado no quedo igual a la suma de pagos en: %', v_malos;
  END IF;

  SELECT string_agg(c.id::text, ', ') INTO v_malos
  FROM clientes c
  WHERE c.id IN (SELECT pe.cliente_id FROM pedidos pe WHERE pe.id IN (SELECT pedido_id FROM _pagos_perdidos))
    AND c.saldo_cuenta <>
      COALESCE((SELECT SUM(p.total - COALESCE(p.monto_pagado, 0)) FROM pedidos p
                WHERE p.cliente_id = c.id AND p.estado NOT IN ('cancelado', 'anulado')), 0)
      - COALESCE((SELECT SUM(pg.monto) FROM pagos pg
                  WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL), 0);
  IF v_malos IS NOT NULL THEN
    RAISE EXCEPTION 'saldo_cuenta no cierra con la formula canonica en clientes: %', v_malos;
  END IF;
END $$;

-- OJO: la FK es COMPUESTA (cliente_id, sucursal_id) -> clientes(id, sucursal_id),
-- el aislamiento por sucursal de las migs 186/187. Se recrea igual de compuesta;
-- lo unico que cambia es la accion de borrado.
ALTER TABLE pagos DROP CONSTRAINT pagos_cliente_id_fkey;
ALTER TABLE pagos ADD CONSTRAINT pagos_cliente_id_fkey
  FOREIGN KEY (cliente_id, sucursal_id) REFERENCES clientes(id, sucursal_id)
  ON DELETE RESTRICT;

COMMIT;
