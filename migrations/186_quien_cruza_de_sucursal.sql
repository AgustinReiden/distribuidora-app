-- ============================================================================
-- 186 · Quién puede cruzar de sucursal: el reporte
-- ============================================================================
-- Sólo lectura. No crea ni una constraint y no toca ni una fila. Es el paso
-- previo a la 187, que es la que cierra el agujero.
--
-- EL AGUJERO. Las policies de las tablas hijas validan `sucursal_id =
-- current_sucursal_id()` sobre LA PROPIA FILA, y nada valida que el padre
-- referenciado sea de esa misma sucursal. Las FK no pasan por RLS. Entonces un
-- INSERT con `sucursal_id` = la mía apuntando a un `compra_id` de la otra
-- sucursal pasa las dos verificaciones y entra. Lo grave no es que se pueda: es
-- que la línea queda INVISIBLE para la sucursal dueña de la compra —su policy de
-- SELECT filtra por el `sucursal_id` de la línea, que dice otra cosa— mientras le
-- mueve el costo y el stock. Corrupción silenciosa con la víctima ciega.
--
-- Es el mismo agujero que la 183 cerró para `compra_cargos` con una FK compuesta,
-- y que su sección 3 dejó anotado como preexistente y de otro trabajo:
--   "Nada ata todavía compra_items.sucursal_id a compras.sucursal_id".
-- Éste es ese otro trabajo, generalizado a todo el esquema.
--
-- QUIÉN LLEGA. Todos. El baseline deja
-- `ALTER DEFAULT PRIVILEGES ... IN SCHEMA public GRANT ALL ON TABLES TO
-- authenticated`, así que toda tabla que cree `postgres` en `public` nace con
-- INSERT/UPDATE/DELETE para cualquier usuario logueado, la haya pedido alguien o
-- no. Buscar `GRANT` explícitos en las migraciones subestima el alcance: varias
-- de estas tablas no tienen ninguno y son escribibles igual. Lo único que las
-- separa de un `INSERT` directo por PostgREST es la policy, que es justamente lo
-- que no mira al padre.
--
-- POR QUÉ FK Y NO RLS. Un EXISTS sobre el padre en las policies taparía sólo el
-- camino de PostgREST. En esta base casi toda la escritura entra por RPCs
-- SECURITY DEFINER, que saltean RLS por definición: la policy no las ve pasar.
-- La FK las ve a todas. Y una policy la pisa cualquier CREATE POLICY futuro y
-- deja de filtrar sin fallar —ya pasó con `es_preventista()` en la 058—; una
-- constraint no se pisa por accidente.
--
-- POR QUÉ CATÁLOGO Y NO UNA LISTA. `migrations/` es una vista curada, no un
-- espejo de prod (MANIFEST, regla de oro), así que una lista sacada del repo nace
-- desalineada. Y una lista congelada no ve la tabla que alguien agregue mañana:
-- este reporte sí, porque los pares los descubre de pg_constraint. Ése es el
-- punto — el hallazgo no fue "compra_items está mal", fue "hay una CLASE de tabla
-- que está mal y nadie la estaba mirando".
--
-- El reporte recorre entera cada tabla hija, así que es una herramienta de
-- verificación y de CI, no algo para colgar de una pantalla.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1 · Los pares, salidos del catálogo
--
-- Un par es una FK entre dos tablas que tienen las dos `sucursal_id`. Ese
-- `sucursal_id` repetido en la hija es la premisa entera del problema: es un dato
-- derivable del padre que igual se guarda al lado, así que puede contradecirlo.
-- Si la hija no lo tuviera no habría nada que contradecir —`movimiento_sucursal_
-- items` es exactamente ese caso: resuelve la sucursal por join con el
-- movimiento, no la copia, y por eso no aparece acá ni puede divergir. Lo mismo
-- `compra_cargo_repartos` (mig 183).
--
-- El par se identifica por su COLUMNA DE NEGOCIO —la que no es `sucursal_id`—,
-- no por la aridad de la FK, y de eso depende que el reporte siga sirviendo
-- después de la 187:
--   · 1 columna                      → el par existe y NO está protegido;
--   · 2, y la segunda ata sucursal_id → el par existe y SÍ está protegido.
-- La primera versión de esto sólo miraba las FK de una columna, y después de
-- convertirlas el tablero quedaba vacío en vez de quedar en verde: un gate que
-- se apaga solo justo cuando empieza a tener algo que vigilar. Contar los pares
-- protegidos, y no sólo los rotos, es lo que lo mantiene vivo.
--
-- Quedan afuera las FK que no son de esta forma: las de dos columnas de negocio
-- (`compra_cargo_repartos`) y las que apuntan a `sucursales`, que es el ancla del
-- tenant y no tiene `sucursal_id` propio.
--
-- Interna a propósito: devuelve nombres de constraint y códigos de pg_constraint,
-- que son insumo de la 187, no algo para mostrarle a nadie. La cara pública es
-- auditoria_sucursal_cruzada().
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pares_sucursal_cruzada()
RETURNS TABLE (
  conname        text,
  hija           text,
  hija_oid       oid,
  columna        text,
  padre          text,
  padre_oid      oid,
  columna_padre  text,
  confdeltype    "char",
  confupdtype    "char",
  condeferrable  boolean,
  condeferred    boolean,
  convalidated   boolean,
  protegida      boolean
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  WITH cand AS (
    SELECT c.conname::text  AS conname,
           ch.relname::text AS hija,
           c.conrelid       AS hija_oid,
           pa.relname::text AS padre,
           c.confrelid      AS padre_oid,
           c.conkey, c.confkey,
           c.confdeltype, c.confupdtype,
           c.condeferrable, c.condeferred, c.convalidated
      FROM pg_constraint c
      JOIN pg_class     ch ON ch.oid = c.conrelid
      JOIN pg_class     pa ON pa.oid = c.confrelid
      JOIN pg_namespace nh ON nh.oid = ch.relnamespace AND nh.nspname = 'public'
      JOIN pg_namespace np ON np.oid = pa.relnamespace AND np.nspname = 'public'
     WHERE c.contype = 'f'
       AND cardinality(c.conkey) <= 2         -- las formas que este modelo cubre
       AND c.conrelid <> c.confrelid          -- la autorreferencia no cruza nada
       AND ch.relkind IN ('r', 'p')
       AND pa.relkind IN ('r', 'p')
       AND EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = c.conrelid  AND a.attname = 'sucursal_id'
                      AND a.attnum > 0 AND NOT a.attisdropped)
       AND EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = c.confrelid AND a.attname = 'sucursal_id'
                      AND a.attnum > 0 AND NOT a.attisdropped)
  ),
  -- Una fila por columna de la FK, con su contraparte en el padre. El WITH
  -- ORDINALITY es el que aparea hija y padre por POSICIÓN, que es como
  -- pg_constraint los relaciona.
  cols AS (
    SELECT cand.*,
           (SELECT a.attname::text FROM pg_attribute a
             WHERE a.attrelid = cand.hija_oid  AND a.attnum = k.ck)                 AS c_col,
           (SELECT a.attname::text FROM pg_attribute a
             WHERE a.attrelid = cand.padre_oid AND a.attnum = cand.confkey[k.ord])  AS p_col
      FROM cand, LATERAL unnest(cand.conkey) WITH ORDINALITY AS k(ck, ord)
  ),
  agg AS (
    SELECT conname, hija, hija_oid, padre, padre_oid,
           confdeltype, confupdtype, condeferrable, condeferred, convalidated,
           count(*)                                                        AS n_cols,
           count(*) FILTER (WHERE c_col <> 'sucursal_id')                  AS n_negocio,
           max(c_col) FILTER (WHERE c_col <> 'sucursal_id')                AS columna,
           max(p_col) FILTER (WHERE c_col <> 'sucursal_id')                AS columna_padre,
           bool_or(c_col = 'sucursal_id' AND p_col = 'sucursal_id')        AS ata_sucursal
      FROM cols
     GROUP BY conname, hija, hija_oid, padre, padre_oid,
              confdeltype, confupdtype, condeferrable, condeferred, convalidated
  )
  SELECT agg.conname, agg.hija, agg.hija_oid, agg.columna,
         agg.padre, agg.padre_oid, agg.columna_padre,
         agg.confdeltype, agg.confupdtype,
         agg.condeferrable, agg.condeferred, agg.convalidated,
         (agg.n_cols = 2 AND agg.ata_sucursal) AS protegida
    FROM agg
   WHERE agg.n_negocio = 1                          -- una sola columna de negocio
     AND (agg.n_cols = 1 OR agg.ata_sucursal)       -- suelta, o atada por sucursal_id
$fn$;

COMMENT ON FUNCTION public._pares_sucursal_cruzada() IS
  'Interna (mig 186). Descubre en pg_constraint los pares hija->padre donde las dos tablas tienen sucursal_id y la FK es de una sola columna: el patrón que permite que la hija contradiga la sucursal del padre. La usan auditoria_sucursal_cruzada() y la migración 187.';

REVOKE ALL ON FUNCTION public._pares_sucursal_cruzada() FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2 · El reporte
--
-- Por cada par: cuántas filas cuelgan de un padre y en cuántas la sucursal no
-- coincide. El JOIN interno ya descarta la FK nula, que es legal y no es un cruce.
--
-- `IS DISTINCT FROM` y no `<>` por defensa, no por necesidad: hoy `sucursal_id`
-- es NOT NULL en los dos lados de los 60 pares —verificado sobre el esquema
-- entero—, y de eso depende que la FK compuesta de la 187 sirva para algo, porque
-- MATCH SIMPLE se da por satisfecha si CUALQUIERA de las columnas referenciantes
-- es NULL. Si alguna vez alguien afloja ese NOT NULL, la FK deja de mirar esas
-- filas y este reporte las cuenta como divergentes en vez de dejarlas pasar en
-- silencio. Es el único lugar donde el agujero podría volver sin que se note.
--
-- Admin-only con el mismo gate que auditoria_integridad(): service_role
-- (auth.uid() IS NULL) entra libre, que es como lo llama el CI.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_sucursal_cruzada()
RETURNS TABLE (
  hija         text,
  columna      text,
  padre        text,
  protegida    boolean,
  filas        bigint,
  divergentes  bigint
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  r        record;
  v_filas  bigint;
  v_div    bigint;
BEGIN
  IF auth.uid() IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  FOR r IN SELECT * FROM _pares_sucursal_cruzada() p ORDER BY p.hija, p.columna, p.padre
  LOOP
    EXECUTE format(
      'SELECT count(*)::bigint,'
      '       count(*) FILTER (WHERE h.sucursal_id IS DISTINCT FROM p.sucursal_id)::bigint'
      '  FROM public.%I h JOIN public.%I p ON p.%I = h.%I',
      r.hija, r.padre, r.columna_padre, r.columna)
    INTO v_filas, v_div;

    hija        := r.hija;
    columna     := r.columna;
    padre       := r.padre;
    protegida   := r.protegida;
    filas       := v_filas;
    divergentes := v_div;
    RETURN NEXT;
  END LOOP;
END;
$fn$;

COMMENT ON FUNCTION public.auditoria_sucursal_cruzada() IS
  'Tablero de aislamiento por sucursal (mig 186). Una fila por par hija->padre donde las dos tablas tienen sucursal_id: protegida = la base ya impide el cruce con una FK compuesta; divergentes = filas que HOY contradicen la sucursal del padre. El objetivo es 0 divergentes y protegida en todas. Recorre entera cada tabla hija: es para CI y verificación, no para una pantalla. Admin-only.';

REVOKE EXECUTE ON FUNCTION public.auditoria_sucursal_cruzada() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.auditoria_sucursal_cruzada() TO authenticated, service_role;

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
--   DROP FUNCTION IF EXISTS public.auditoria_sucursal_cruzada();
--   DROP FUNCTION IF EXISTS public._pares_sucursal_cruzada();
--
-- Exacto: las dos son de sólo lectura y nadie más las llama salvo la 187 y el
-- gate de CI. Dropearlas con la 187 ya aplicada deja las FK compuestas en pie
-- (que es lo que protege) y ciego al gate (que es lo que avisa).
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación
--
--   -- El tablero entero. Lo que predice el repo al 2026-08-19: 60 pares, 0
--   -- protegidos (61 y 1 si la 183 ya entró: `compra_cargos.compra_id` nace
--   -- con la FK compuesta puesta). Si prod devuelve otro número, gana prod:
--   -- `migrations/` no es 1:1 con producción (MANIFEST, regla de oro).
--   SELECT * FROM auditoria_sucursal_cruzada() ORDER BY divergentes DESC, hija;
--
--   -- Lo único que hay que mirar antes de aplicar la 187 — tiene que dar 0 filas:
--   SELECT * FROM auditoria_sucursal_cruzada() WHERE divergentes > 0;
--
--   -- Y el resumen:
--   SELECT count(*)                              AS pares,
--          count(*) FILTER (WHERE protegida)     AS con_fk_compuesta,
--          count(*) FILTER (WHERE divergentes>0) AS con_filas_cruzadas,
--          sum(divergentes)                      AS filas_cruzadas
--     FROM auditoria_sucursal_cruzada();
--   -- Antes de la 187:   60 |  0 | 0 | 0     (esperado)
--   -- Después de la 187: 60 | 60 | 0 | 0
-- ----------------------------------------------------------------------------
