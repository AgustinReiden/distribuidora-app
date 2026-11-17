-- Las secuencias de public a un valor alto, después de cargar la foto del esquema.
--
-- `pg_dump --schema-only` no trae los valores de las secuencias: en la base de CI todas arrancan
-- en 1, y un CHECK que se apoya en un id de prod se comporta distinto que allá. Caso real:
-- `pagos_client_request_id_historico` es `id <= 8049` (mig 453); con ids chicos pasa, y el ensayo
-- test-idempotencia-cobro-1440 fallaba en CI por eso y no por un bug (H4 de la lente de #1645).
-- Con 10^9 los ids nuevos quedan por encima de cualquier id histórico, como en prod.
--
-- Se saltea sucursales_id_seq: la semilla de docker-local.mjs la deja en 4 a propósito (las
-- sucursales 1 y 2 son las de prod). NUNCA contra prod: sólo base local.
DO $secuencias$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT schemaname, sequencename, max_value
      FROM pg_sequences
     WHERE schemaname = 'public' AND sequencename <> 'sucursales_id_seq' AND increment_by > 0
  LOOP
    PERFORM setval(format('%I.%I', r.schemaname, r.sequencename)::regclass, LEAST(1000000000::bigint, r.max_value - 1));
  END LOOP;
END
$secuencias$;
