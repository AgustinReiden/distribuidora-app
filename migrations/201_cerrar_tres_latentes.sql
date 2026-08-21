-- Tres latentes que hoy no muerden y van a morder (#498, #499, #501)
--
-- Ninguna arregla un sintoma actual: las tres cierran caminos por los que el
-- proximo bug ya tiene entrada abierta.

BEGIN;

-- ── 1. estado_pago NOT NULL (#498) ───────────────────────────────────────────
-- usePedidosQuery:1124 hace .neq('estado_pago','pagado'). En SQL, NULL <> 'x' da
-- NULL, no true: un pedido con estado_pago nulo DESAPARECE de esa consulta en vez
-- de aparecer como impago. Hoy hay 0 nulls, asi que se ataca la raiz en vez del
-- sintoma. El default ya era 'pendiente'; solo faltaba prohibir el NULL.
--
-- Las otras tres lineas del archivo (837, 897, 1125) filtran por `estado`, que ya
-- es NOT NULL. No habia nada que arreglar ahi.
UPDATE pedidos SET estado_pago = 'pendiente' WHERE estado_pago IS NULL;
ALTER TABLE pedidos ALTER COLUMN estado_pago SET NOT NULL;

-- ── 2. recorridos.fecha en hora argentina (#499) ─────────────────────────────
-- El default era CURRENT_DATE y la base corre en UTC. Entre las 21:00 y las 00:00
-- ART, CURRENT_DATE ya devuelve el dia siguiente, asi que una ruta armada de noche
-- -que es cuando se arma la del dia siguiente- se fechaba un dia mas adelante.
-- Mismo problema y misma solucion que la mig 182 para pagos.
--
-- Historico: de 91 recorridos solo 2 se crearon despues de las 21:00 ART, asi que
-- no se toca nada hacia atras; esto arregla de aca en adelante.
ALTER TABLE recorridos
  ALTER COLUMN fecha
  SET DEFAULT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;

COMMENT ON COLUMN recorridos.fecha IS
  'Fecha de reparto. Default en hora argentina, NO CURRENT_DATE: la base corre en '
  'UTC y despues de las 21:00 ART ese default fechaba el recorrido al dia siguiente '
  '(mig 201, mismo caso que pagos en la 182).';

-- ── 3. Un solo trigger de guarda en clientes (#501) ──────────────────────────
-- Habia DOS triggers protegiendo las mismas columnas ante preventistas, con
-- criterios opuestos:
--   clientes_guard_update_preventista  -> deny-list de 15 columnas
--   trg_clientes_proteger_columnas     -> allow-list de 13 columnas
--
-- Se queda el allow-list, y no es indistinto: con deny-list, cada columna nueva
-- nace DESPROTEGIDA hasta que alguien se acuerde de agregarla a la lista. Con
-- allow-list nace protegida, que es el lado seguro del error.
--
-- Verificado antes de dropear: ninguna de las 15 columnas del deny-list aparece
-- entre las 13 del allow-list, asi que el que queda es estrictamente mas
-- estricto. Ademas tiene dos guardas que al otro le faltaban: exime a
-- current_user <> 'authenticated' (RPCs SECURITY DEFINER, service_role) y a las
-- cascadas de otros triggers (pg_trigger_depth() > 1).
DROP TRIGGER IF EXISTS clientes_guard_update_preventista ON clientes;
DROP FUNCTION IF EXISTS public.clientes_guard_update_preventista();

COMMIT;
