-- Cobros 4 · #1246 · Sin INSERT REST sobre `pagos`.
--
-- Todo cobro pasa por una RPC (la 2). Se aplica despues de que el front que cobra
-- por `registrar_pagos_pedido` este en prod: el bundle viejo inserta por REST.
--
-- Tarjeta 2 de #1268 (cobros y cuenta corriente), en cuatro migraciones que se
-- aplican en orden: 1 formas de pago (#1249), 2 cobro por RPC (#1246, #1247),
-- 3 cambio de cliente y rendicion congelada (#1248), 4 sin INSERT REST (#1246).
-- La 4 va despues de que el front nuevo este en prod: hasta entonces el bundle
-- viejo cobra por REST, y sin el INSERT no podria cobrar.
--
-- Prod antes de esto: 0 pagos con monto <= 0, 0 con cliente distinto del de su
-- pedido, 0 pedidos sobrepagados, 0 pagos con fecha futura. Formas en `pagos`:
-- las seis de la lista mas 5 'combinado' y 1 'cuenta_corriente' heredados, todos
-- de abril de 2026.
--
-- Ensayo: scripts/test-cobros-por-rpc-1246-1249.sql (G1, G2).


-- Sin INSERT REST. Un REVOKE de tabla se lleva tambien los grants por columna
-- del mismo privilegio, que es lo que se quiere: no queda ningun INSERT.
DROP POLICY IF EXISTS mt_pagos_insert ON public.pagos;
REVOKE INSERT ON public.pagos FROM authenticated;
-- Ninguna funcion INVOKER inserta pagos: la secuencia ya no le hace falta.
REVOKE USAGE ON SEQUENCE public.pagos_id_seq FROM authenticated;
