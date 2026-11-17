-- =========================================================================
-- NNN · `notas_credito.anulada_por` SIN CLAVE FORÁNEA A `perfiles`
--       (plan #1603, ola 2: arreglo de una regresión de la 523)
--
-- La 523 sumó `notas_credito.anulada_por` con una FK a `perfiles`. La tabla ya
-- tenía otra (`usuario_id`), y con dos FK a la misma tabla el embed
-- `usuario:perfiles(id, nombre)` que hace el detalle de una compra
-- (`useNotasCreditoQuery.ts`) queda ambiguo: PostgREST rechaza la consulta
-- entera con PGRST201 y las notas de crédito de la compra no cargan.
--
-- Un bundle viejo del PWA no se arregla con un deploy, así que se saca la FK
-- en la base. La columna queda como está (uuid, hoy siempre NULL: la anulación
-- todavía no tiene botón). La FK puede volver cuando el front pida ese embed
-- con su relación explícita (`perfiles!notas_credito_usuario_id_fkey`) y ya
-- no queden bundles que lo pidan sin ella.
--
-- No cambia funciones, datos ni permisos. Toma sus locks al principio (NOWAIT).
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

LOCK TABLE public.notas_credito, public.perfiles IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $premisas$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.notas_credito'::regclass
                    AND conname = 'notas_credito_anulada_por_fkey'
                    AND contype = 'f'
                    AND confrelid = 'public.perfiles'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · notas_credito_anulada_por_fkey no existe o no apunta a perfiles: rehacer sobre lo vigente';
  END IF;
  IF (SELECT count(*) FROM pg_constraint
       WHERE conrelid = 'public.notas_credito'::regclass
         AND contype = 'f'
         AND confrelid = 'public.perfiles'::regclass) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · se esperaban dos claves foráneas de notas_credito a perfiles';
  END IF;
END
$premisas$;

ALTER TABLE public.notas_credito DROP CONSTRAINT notas_credito_anulada_por_fkey;

COMMENT ON COLUMN public.notas_credito.anulada_por IS
  'mig NNN: quién anuló la nota (id de perfiles). Va SIN clave foránea a propósito: con dos FK de notas_credito a perfiles, el embed `usuario:perfiles(...)` del front queda ambiguo (PGRST201) y la consulta entera falla.';

DO $post$
DECLARE
  v text;
BEGIN
  SELECT string_agg(conname, ', ' ORDER BY conname) INTO v
    FROM pg_constraint
   WHERE conrelid = 'public.notas_credito'::regclass
     AND contype = 'f'
     AND confrelid = 'public.perfiles'::regclass;
  IF v IS DISTINCT FROM 'notas_credito_usuario_id_fkey' THEN
    RAISE EXCEPTION 'mig NNN · poscondición: las claves foráneas de notas_credito a perfiles son «%» y tenía que quedar sólo notas_credito_usuario_id_fkey', v;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'notas_credito'
                    AND column_name = 'anulada_por' AND data_type = 'uuid') THEN
    RAISE EXCEPTION 'mig NNN · poscondición: la columna notas_credito.anulada_por tenía que quedar';
  END IF;
END
$post$;

NOTIFY pgrst, 'reload schema';

COMMIT;
