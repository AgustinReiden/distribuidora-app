-- =========================================================================
-- 176_sobrecargas_ambiguas.sql
--
-- Al revisar la 175 salió que dos sobrecargas cuyas aridades se superponen
-- por defaults dejan la llamada ambigua. PostgREST no puede elegir y contesta
-- HTTP 300 `PGRST203`. Un barrido sobre todo el esquema encontró que quedaban
-- dos casos vivos, los dos verificados con curl contra prod:
--
--   1. `registrar_salvedad`: 7 args (wrapper de la mig 174) y 8 args
--      (idempotente, mig 167). Las dos tienen 4 obligatorios, así que
--      cualquier llamada de 4 a 7 argumentos es ambigua.
--      `useSalvedades.registrarSalvedad` manda exactamente 7 → PGRST203.
--      Hoy no lo rompe a nadie porque ningún componente usa ese hook (el
--      chofer va por handleRegistrarSalvedadSingle, que manda 8), pero es
--      una mina para el primero que lo use.
--
--   2. `actualizar_orden_entrega_batch(jsonb)` y `(orden_entrega_item[])`.
--      Este SÍ estaba fallando: las dos formas en que lo llama el front dan
--      PGRST203. No se notaba porque `usePedidos.actualizarOrdenEntrega`
--      cae a un fallback que actualiza pedido por pedido, y
--      `pedidoService` hace lo mismo en su catch. O sea: el orden de entrega
--      se guardaba igual, pero con N updates sueltos en vez de uno solo y
--      sin la atomicidad del RPC.
--
-- En los dos casos sobra una de las dos. Se dropea la sobrante en vez de
-- renombrarla: PostgREST resuelve por nombre de parámetro, así que los
-- clientes que mandan menos parámetros caen en la que queda y toman el resto
-- de los defaults. Verificado con curl + anon key antes y después.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. registrar_salvedad: queda solo la de 8 args.
--    Un cliente que mande los 7 de siempre matchea igual y `p_client_request_id`
--    sale del default, que es exactamente lo que hacía el wrapper.
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.registrar_salvedad(
  bigint, bigint, integer, character varying, text, text, boolean
);

-- -------------------------------------------------------------------------
-- 2. actualizar_orden_entrega_batch: queda la de jsonb.
--    Los dos cuerpos son idénticos salvo cómo desarman el parámetro, y las
--    dos formas en que llama el front (array de objetos y string JSON) son
--    JSON, no `orden_entrega_item[]`.
--
--    El tipo `orden_entrega_item` queda: no molesta y dropearlo es riesgo
--    innecesario para esta migración.
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.actualizar_orden_entrega_batch(public.orden_entrega_item[]);

COMMENT ON FUNCTION public.actualizar_orden_entrega_batch(jsonb) IS
  'Guarda el orden de entrega optimizado en un solo viaje. Unica sobrecarga desde la mig 176: convivia con una de orden_entrega_item[] y PostgREST no podia elegir (PGRST203).';

-- -------------------------------------------------------------------------
-- Para auditar esto en el futuro. Si devuelve filas, esas llamadas dan
-- PGRST203 y no lo va a ver ni tsc ni los tests: el nombre del RPC es un
-- string y el error aparece recien en runtime contra la base.
--
--   with f as (
--     select p.oid, p.proname, p.pronargs as total,
--            p.pronargs - p.pronargdefaults as oblig
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public' and p.prokind = 'f'
--       and p.prolang <> (select oid from pg_language where lanname = 'c')
--   )
--   select a.proname,
--          a.oid::regprocedure::text as firma_a,
--          b.oid::regprocedure::text as firma_b,
--          greatest(a.oblig, b.oblig) || '..' || least(a.total, b.total) as n_args_ambiguos
--   from f a join f b on a.proname = b.proname and a.oid < b.oid
--   where greatest(a.oblig, b.oblig) <= least(a.total, b.total);
-- -------------------------------------------------------------------------
