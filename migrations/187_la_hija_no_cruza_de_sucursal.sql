-- ============================================================================
-- 187 · Que la hija no pueda cruzar de sucursal
-- ============================================================================
-- Requiere la 186 (`_pares_sucursal_cruzada()` y `auditoria_sucursal_cruzada()`).
-- Leer el encabezado de la 186 para el planteo del agujero y por qué se cierra
-- con FK y no con RLS.
--
-- Acá se convierte cada FK de una columna entre dos tablas que tienen las dos
-- `sucursal_id` en una FK COMPUESTA `(columna, sucursal_id) -> padre(id,
-- sucursal_id)`. Mismo patrón estructural que la 183 usó para atar un cargo a su
-- compra, aplicado a todo lo que ya estaba suelto.
--
-- NO TOCA NI UNA FILA. Sólo constraints. Si algún dato hoy cruza de sucursal, la
-- migración ABORTA en la sección 2 con la lista completa en vez de aplicar la
-- mitad: no hay nada acá que "arregle" filas, porque cuál es la sucursal correcta
-- de una línea cruzada es una decisión de negocio, no de esta migración.
--
-- LAS UNIQUE DE LA SECCIÓN 3 NO PUEDEN RECHAZAR NADA. Para que una FK apunte a
-- `padre(columna, sucursal_id)` tiene que existir un UNIQUE sobre ese par. Y esa
-- UNIQUE es redundante por construcción: para ser destino de la FK original,
-- `columna` ya era única sola. Una fila que violara `(columna, sucursal_id)`
-- estaría violando primero la clave de una sola columna. Es el mismo razonamiento
-- de la sección 1 de la 183, que ya lo verificó con conteos contra prod.
--
-- LO QUE SÍ CAMBIA DE COMPORTAMIENTO: nada, si el dato está sano. Un INSERT o un
-- UPDATE que hoy cruza de sucursal pasa a fallar con
-- `23503 violates foreign key constraint`. Que es el punto.
-- ============================================================================

BEGIN;

-- Un DDL que espera detrás de una transacción larga bloquea la app entera, y
-- todo esto vive en un solo BEGIN/COMMIT. Mejor fallar en 10 segundos y volver
-- en un rato que dejar la app colgada: el rollback no deja nada a medias.
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '5min';

-- ----------------------------------------------------------------------------
-- 1 · Los pares a tocar, congelados antes de empezar
--
-- En una tabla temporal y no en un `FOR ... IN SELECT ... FROM pg_constraint`
-- porque el cuerpo del loop MODIFICA pg_constraint: iterar el catálogo mientras
-- se lo reescribe es pedirle al cursor que decida qué ve. Congelarlo primero
-- también deja la lista exacta de lo que se va a hacer disponible para el NOTICE.
--
-- `NOT protegida` alcanza como filtro: la 186 ya deja afuera todo lo que no es
-- esta forma —las FK de dos columnas de negocio, las que apuntan a `sucursales`—
-- y garantiza que `columna` sea siempre la de negocio y nunca `sucursal_id`.
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE _pares_a_componer ON COMMIT DROP AS
  SELECT p.*
    FROM public._pares_sucursal_cruzada() p
   WHERE NOT p.protegida;

DO $mig$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM _pares_a_componer;
  RAISE NOTICE '187 · pares a convertir en FK compuesta: %', v_n;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 2 · Preflight: que hoy no haya nada cruzado
--
-- La FK igual rechazaría la migración si hubiera filas divergentes, pero lo haría
-- con el error de UNA constraint y sin decir cuántas más vienen atrás. Esto las
-- lista todas de una, que es lo que hace falta para decidir qué hacer con ellas.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE v_txt text;
BEGIN
  SELECT string_agg(format('  %s.%s -> %s: %s de %s filas', a.hija, a.columna, a.padre,
                           a.divergentes, a.filas),
                    E'\n' ORDER BY a.hija, a.columna)
    INTO v_txt
    FROM public.auditoria_sucursal_cruzada() a
   WHERE a.divergentes > 0;

  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION E'Hay filas que YA cruzan de sucursal. La FK compuesta las rechazaría, así que no se aplica nada.\n%\n\nCada una hay que resolverla a mano: decidir cuál es la sucursal correcta de la fila hija y corregirla, o darla de baja. No hay un backfill automático posible — cuál de las dos sucursales es la buena es información que no está en la base.', v_txt;
  END IF;

  RAISE NOTICE '187 · preflight OK: ninguna fila cruza de sucursal.';
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 3 · Guard de versión
--
-- `ON DELETE SET NULL` sobre una FK compuesta anula TODAS las columnas
-- referenciantes, `sucursal_id` incluida — que es NOT NULL en las 60 hijas. O sea
-- que el borrado del padre pasaría de anular la referencia a fallar con un
-- 23502. Restringir el SET NULL a la columna de la FK (`SET NULL (columna)`)
-- existe recién en PostgreSQL 15.
--
-- No hay plan B decente: degradar esos SET NULL a NO ACTION cambiaría el
-- comportamiento del borrado de un producto o de un cliente sin avisar. Así que
-- si la versión no da, no se aplica nada y se dice por qué.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM _pares_a_componer
   WHERE confdeltype IN ('n','d') OR confupdtype IN ('n','d');

  IF v_n > 0 AND current_setting('server_version_num')::int < 150000 THEN
    RAISE EXCEPTION 'Se necesita PostgreSQL 15+ para % de estas FK (usan SET NULL / SET DEFAULT y hay que restringirlo a una columna). Esta base es la %.',
      v_n, current_setting('server_version');
  END IF;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 4 · Las UNIQUE de los padres y las FK compuestas
--
-- El nombre de la FK nueva es EL MISMO de la vieja, a propósito: los mensajes de
-- error que ya conoce el equipo no cambian, y nada que busque una constraint por
-- nombre se rompe. Lo que cambia es de cuántas columnas es.
--
-- La UNIQUE del padre sigue la convención que estrenó la 183:
-- `<padre>_<columna>_sucursal_uk`. Si la 183 entró antes, `compras_id_sucursal_uk`
-- ya existe y el guard la saltea; si entra después, la encuentra hecha. Las dos
-- migraciones conviven en cualquier orden.
--
-- El DROP + ADD va adentro de la misma transacción, así que no hay ventana sin
-- integridad referencial. Y no hace falta ningún índice nuevo en la hija: el
-- chequeo al borrar un padre filtra `columna = X AND sucursal_id = Y`, y el
-- índice que ya existe sobre `columna` sirve igual.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  r      record;
  v_uk   text;
  v_del  text;
  v_upd  text;
  v_dfr  text;
  v_val  text;
  v_n    int := 0;
BEGIN
  FOR r IN SELECT * FROM _pares_a_componer ORDER BY hija, columna, padre
  LOOP
    -- 4.a · El destino: UNIQUE (columna_padre, sucursal_id) en el padre.
    v_uk := format('%s_%s_sucursal_uk', r.padre, r.columna_padre);
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = v_uk AND conrelid = r.padre_oid) THEN
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I UNIQUE (%I, sucursal_id)',
                     r.padre, v_uk, r.columna_padre);
      RAISE NOTICE '  + UNIQUE %(%, sucursal_id)', r.padre, r.columna_padre;
    END IF;

    -- 4.b · Las acciones referenciales de la vieja, preservadas al pie de la letra.
    v_del := CASE r.confdeltype
               WHEN 'a' THEN ''
               WHEN 'r' THEN ' ON DELETE RESTRICT'
               WHEN 'c' THEN ' ON DELETE CASCADE'
               WHEN 'n' THEN format(' ON DELETE SET NULL (%I)', r.columna)
               WHEN 'd' THEN format(' ON DELETE SET DEFAULT (%I)', r.columna)
             END;
    v_upd := CASE r.confupdtype
               WHEN 'a' THEN ''
               WHEN 'r' THEN ' ON UPDATE RESTRICT'
               WHEN 'c' THEN ' ON UPDATE CASCADE'
               WHEN 'n' THEN format(' ON UPDATE SET NULL (%I)', r.columna)
               WHEN 'd' THEN format(' ON UPDATE SET DEFAULT (%I)', r.columna)
             END;
    IF v_del IS NULL OR v_upd IS NULL THEN
      RAISE EXCEPTION 'FK % (%.%): acción referencial desconocida (del=%, upd=%). No se adivina.',
        r.conname, r.hija, r.columna, r.confdeltype, r.confupdtype;
    END IF;

    v_dfr := CASE WHEN r.condeferrable AND r.condeferred THEN ' DEFERRABLE INITIALLY DEFERRED'
                  WHEN r.condeferrable                   THEN ' DEFERRABLE'
                  ELSE '' END;
    -- Una FK que ya estaba NOT VALID se recrea NOT VALID: validarla de prepo
    -- convertiría esta migración en una que puede fallar por datos viejos que
    -- alguien decidió tolerar en su momento.
    v_val := CASE WHEN r.convalidated THEN '' ELSE ' NOT VALID' END;

    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.hija, r.conname);
    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I, sucursal_id) '
      'REFERENCES public.%I (%I, sucursal_id)%s%s%s%s',
      r.hija, r.conname, r.columna, r.padre, r.columna_padre, v_upd, v_del, v_dfr, v_val);

    v_n := v_n + 1;
    RAISE NOTICE '  ~ %.% -> %  (%)', r.hija, r.columna, r.padre, r.conname;
  END LOOP;

  RAISE NOTICE '187 · % FK convertidas en compuestas.', v_n;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 5 · Post-condición
--
-- Que no quede ni un par sin cubrir. Si la sección 4 se saltó algo por una rama
-- que no previmos, acá se entera la migración y no producción.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE v_txt text;
BEGIN
  SELECT string_agg(format('%s.%s -> %s', p.hija, p.columna, p.padre), ', ' ORDER BY p.hija)
    INTO v_txt
    FROM public._pares_sucursal_cruzada() p
   WHERE NOT p.protegida;

  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION 'Quedaron pares sin FK compuesta: %', v_txt;
  END IF;
END;
$mig$;

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
-- No hay uno de una línea, y conviene decirlo en vez de fingirlo: la migración
-- no crea constraints nuevas con nombre propio, REEMPLAZA las que ya estaban.
-- Volver atrás es hacer el camino inverso — dejar cada FK en una sola columna
-- conservando su nombre y su ON DELETE:
--
--   DO $rb$
--   DECLARE r record; v_del text;
--   BEGIN
--     FOR r IN
--       SELECT c.conname, ch.relname AS hija, pa.relname AS padre, c.confdeltype,
--              (SELECT a.attname FROM pg_attribute a
--                WHERE a.attrelid=c.conrelid AND a.attnum=c.conkey[1]
--                  AND a.attname <> 'sucursal_id') AS columna,
--              (SELECT a.attname FROM pg_attribute a
--                WHERE a.attrelid=c.confrelid AND a.attnum=c.confkey[1]
--                  AND a.attname <> 'sucursal_id') AS columna_padre
--         FROM pg_constraint c
--         JOIN pg_class ch ON ch.oid=c.conrelid
--         JOIN pg_class pa ON pa.oid=c.confrelid
--        WHERE c.contype='f' AND cardinality(c.conkey)=2
--          AND 'sucursal_id' = ANY (SELECT a.attname FROM pg_attribute a
--                                    WHERE a.attrelid=c.conrelid AND a.attnum=ANY(c.conkey))
--     LOOP
--       v_del := CASE r.confdeltype WHEN 'c' THEN ' ON DELETE CASCADE'
--                                   WHEN 'n' THEN ' ON DELETE SET NULL'
--                                   WHEN 'r' THEN ' ON DELETE RESTRICT' ELSE '' END;
--       EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.hija, r.conname);
--       EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES public.%I (%I)%s',
--                      r.hija, r.conname, r.columna, r.padre, r.columna_padre, v_del);
--     END LOOP;
--   END $rb$;
--
-- OJO: ese loop toma TODAS las FK de dos columnas con `sucursal_id`, o sea que se
-- llevaría puestas también las que creó la 183 a mano (compra_cargos ->
-- compras). Si la 183 está aplicada, hay que excluirla.
--
-- Las UNIQUE `<padre>_<col>_sucursal_uk` se pueden dejar: son redundantes con la
-- clave de una columna y no rechazan nada. Dropearlas es opcional y hay que
-- hacerlo DESPUÉS de las FK, no antes.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación
--
--   -- 1. El tablero, que es el resultado que importa: 0 sin proteger, 0 cruzadas.
--   SELECT count(*)                               AS pares,
--          count(*) FILTER (WHERE NOT protegida)  AS sin_proteger,
--          sum(divergentes)                       AS filas_cruzadas
--     FROM auditoria_sucursal_cruzada();
--   -- esperado: 60 | 0 | 0
--
--   -- 2. Las FK compuestas, una por par (más las 3 que ya trae la 183):
--   SELECT conrelid::regclass AS hija, conname, pg_get_constraintdef(oid) AS def
--     FROM pg_constraint
--    WHERE contype='f' AND cardinality(conkey)=2
--      AND connamespace='public'::regnamespace
--    ORDER BY 1, 2;
--
--   -- 3. Que ningún ON DELETE se haya perdido en el cambio. Tiene que dar 0:
--   --    toda FK compuesta con SET NULL debe traer su lista de columnas, si no
--   --    el borrado del padre va a fallar contra el NOT NULL de sucursal_id.
--   SELECT count(*) FROM pg_constraint
--    WHERE contype='f' AND cardinality(conkey)=2 AND confdeltype='n'
--      AND connamespace='public'::regnamespace
--      AND pg_get_constraintdef(oid) NOT LIKE '%SET NULL (%';
--
--   -- 4. La prueba de fuego, en una transacción que se descarta. Tiene que
--   --    fallar con 23503 (ajustar los ids a dos sucursales distintas):
--   BEGIN;
--     INSERT INTO compra_items (compra_id, producto_id, sucursal_id, cantidad, costo_unitario, subtotal)
--     SELECT c.id, p.id, p.sucursal_id, 1, 1, 1
--       FROM compras c, productos p
--      WHERE c.sucursal_id <> p.sucursal_id
--      LIMIT 1;
--   ROLLBACK;
-- ----------------------------------------------------------------------------
