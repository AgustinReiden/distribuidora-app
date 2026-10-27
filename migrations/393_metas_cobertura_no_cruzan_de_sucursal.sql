-- metas_cobertura_zona.zona_id pasa a FK compuesta (zona_id, sucursal_id).
--
-- La tabla nació en la 386b (tablero, aplicada directo en prod) con una FK
-- simple a zonas(id). Con eso una meta puede tener la sucursal_id de una
-- sucursal y colgarse de una zona de otra, y el check de aislamiento
-- (scripts/check-sucursal-cruzada.mjs, migs 186 y 187) la marca como agujero.
-- Mismo molde que la 187: se recrea con el mismo nombre y la misma acción
-- (ON DELETE CASCADE) contra la UNIQUE (id, sucursal_id) que zonas ya tiene
-- (zonas_id_sucursal_uk).
--
-- Validada de entrada: hoy la tabla no tiene filas, y la única escritura,
-- tablero_guardar_meta_cobertura, toma la sucursal de la propia zona.

ALTER TABLE public.metas_cobertura_zona
  DROP CONSTRAINT metas_cobertura_zona_zona_id_fkey,
  ADD CONSTRAINT metas_cobertura_zona_zona_id_fkey
    FOREIGN KEY (zona_id, sucursal_id) REFERENCES public.zonas (id, sucursal_id) ON DELETE CASCADE;

DO $verif$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.metas_cobertura_zona'::regclass
       AND conname = 'metas_cobertura_zona_zona_id_fkey'
       AND confrelid = 'public.zonas'::regclass
       AND array_length(conkey, 1) = 2
       AND confdeltype = 'c'
       AND convalidated) THEN
    RAISE EXCEPTION 'metas_cobertura_zona_zona_id_fkey no quedó compuesta, validada y con CASCADE';
  END IF;
  IF EXISTS (SELECT 1 FROM public.auditoria_sucursal_cruzada()
              WHERE NOT protegida AND hija = 'metas_cobertura_zona') THEN
    RAISE EXCEPTION 'auditoria_sucursal_cruzada sigue viendo metas_cobertura_zona sin proteger';
  END IF;
END
$verif$;
