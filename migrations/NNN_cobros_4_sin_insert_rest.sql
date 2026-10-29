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


-- Un bundle viejo (anterior al deploy del 2026-10-29 13 h UTC) que intente
-- cobrar por REST recibe 42501 y el pago no entra: el error se ve en el modal y
-- el pedido sigue impago, no hay nada que deshacer. La cola offline no encola
-- pagos (SYNC_PAGO no tiene productor desde #509), asi que no queda ningun
-- reintento en segundo plano. Al recargar, el front cobra por la RPC.
-- Tambien cierra COB-N2 (#1246): por REST se podia insertar un pago con el
-- pago_origen_id de un pago rendido, y _rendicion_pagos lo dejaba fuera de toda
-- rendicion (un pedazo nacido despues de la foto de su raiz, #1292).
--
-- Tarjeta 2 de #1306: aplicada recien cuando todos los cobros entraban por RPC.


-- Sin INSERT REST. Un REVOKE de tabla se lleva tambien los grants por columna
-- del mismo privilegio, que es lo que se quiere: no queda ningun INSERT.
DROP POLICY IF EXISTS mt_pagos_insert ON public.pagos;
REVOKE INSERT ON public.pagos FROM authenticated;
-- Ninguna funcion INVOKER inserta pagos: la secuencia ya no le hace falta.
REVOKE USAGE ON SEQUENCE public.pagos_id_seq FROM authenticated;

DO $verif$
BEGIN
  IF has_table_privilege('authenticated', 'public.pagos', 'INSERT')
     OR has_any_column_privilege('authenticated', 'public.pagos', 'INSERT')
     OR has_sequence_privilege('authenticated', 'public.pagos_id_seq', 'USAGE')
     OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'pagos' AND cmd = 'INSERT') THEN
    RAISE EXCEPTION 'pagos sigue teniendo INSERT REST para authenticated';
  END IF;
  -- Lo que inserta pagos es todo DEFINER: el revoke no le saca nada.
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE pronamespace = 'public'::regnamespace AND NOT prosecdef
                AND prosrc ~* 'insert\s+into\s+(public\.)?pagos\M') THEN
    RAISE EXCEPTION 'una funcion INVOKER inserta pagos: con el revoke daria 42501';
  END IF;
END
$verif$;
