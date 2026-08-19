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
-- Es el mismo agujero que la 183 cierra para `compra_cargos` con una FK
-- compuesta, y que su sección 3 dejó anotado como preexistente y de otro trabajo:
--   "Nada ata todavía compra_items.sucursal_id a compras.sucursal_id".
-- Éste es ese otro trabajo, generalizado a todo el esquema.
--
-- Verificado contra prod el 2026-08-19: **69 pares y 0 filas cruzadas**. Es un
-- agujero latente, no un incidente.
--
-- QUIÉN LLEGA. El baseline deja
-- `ALTER DEFAULT PRIVILEGES ... IN SCHEMA public GRANT ALL ON TABLES TO
-- authenticated`, así que toda tabla que cree `postgres` en `public` nace con
-- INSERT/UPDATE/DELETE para cualquier usuario logueado, la haya pedido alguien o
-- no: confirmado con `has_table_privilege` sobre las hijas, incluidas las que no
-- tienen ningún GRANT en las migraciones. Lo único que frena la escritura directa
-- por PostgREST es que exista o no una policy de escritura. Donde no la hay
-- —`recorrido_cambios`, `promo_acumuladores`, `pedido_item_sustituciones`,
-- `comision_reglas`, `metas_preventista`: sólo SELECT— el default-deny de RLS
-- alcanza, y el único camino de escritura son las RPCs SECURITY DEFINER. Que es
-- justo el camino que ninguna policy vigila.
--
-- POR QUÉ FK Y NO RLS. Un EXISTS sobre el padre en las policies taparía sólo el
-- camino de PostgREST. En esta base casi toda la escritura entra por RPCs
-- SECURITY DEFINER, que saltean RLS por definición: la policy no las ve pasar.
-- La FK las ve a todas. Y una policy la pisa cualquier CREATE POLICY futuro y
-- deja de filtrar sin fallar —ya pasó con `es_preventista()` en la 058—; una
-- constraint no se pisa por accidente.
--
-- POR QUÉ CATÁLOGO Y NO UNA LISTA. `migrations/` es una vista curada, no un
-- espejo de prod (MANIFEST, regla de oro), y acá se nota: el repo predice 60
-- pares y prod tiene 69. Los 9 que faltaban (`comision_reglas`,
-- `grupo_precio_escala_minimos`, `metas_preventista`, `productos.categoria_id`,
-- `productos.marca_id`, `pedido_item_sustituciones.ajuste_producto_id_nuevo`) los
-- encuentra el catálogo y los habría perdido una lista escrita a mano. Además
-- una lista congelada no ve la tabla que alguien agregue mañana. Ése es el punto
-- — el hallazgo no fue "compra_items está mal", fue "hay una CLASE de tabla que
-- está mal y nadie la estaba mirando".
--
-- El reporte recorre entera cada tabla hija, así que es una herramienta de
-- verificación y de CI, no algo para colgar de una pantalla.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1 · Cuál es la columna de tenant de cada tabla
--
-- NO siempre es `sucursal_id`, y asumirlo daba un falso positivo caro.
-- `transferencias_stock` tiene las DOS columnas y significan cosas distintas:
--
--   · `tenant_sucursal_id` es el tenant — es la que usa la policy de escritura
--     (`mt_transferencias_stock_all`: es_admin() AND tenant_sucursal_id = ...);
--   · `sucursal_id` es LA OTRA PUNTA del traslado, y por eso la policy de SELECT
--     es `tenant_sucursal_id = current OR sucursal_id = current`: las dos
--     sucursales tienen que poder ver el movimiento.
--
-- Comparar `transferencia_items.sucursal_id` contra `transferencias_stock.
-- sucursal_id` daba 4 de 13 filas "cruzadas" que en realidad son correctas: son
-- traslados entre sucursales, que por definición tienen las dos puntas distintas.
-- Contra `tenant_sucursal_id` dan 0. Si alguien "arreglaba" esas 4 filas rompía
-- historia buena.
--
-- La regla, entonces: el tenant es `tenant_sucursal_id` si la tabla lo tiene, y
-- si no `sucursal_id`. Hoy hay un solo caso, pero la regla se lee sola —una
-- columna que se llama "tenant" es el tenant— y evita que el próximo la pise.
-- `movimientos_sucursal` (mig 076) ni siquiera entra: tiene `sucursal_origen_id`
-- y `sucursal_destino_id` y ninguna columna de tenant, así que no hay nada que
-- atar.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._tenant_col_por_tabla()
RETURNS TABLE (reloid oid, tabla text, tcol text, tcol_nullable boolean)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  SELECT c.oid,
         c.relname::text,
         t.tcol,
         NOT a.attnotnull
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    CROSS JOIN LATERAL (
      SELECT CASE WHEN EXISTS (
                    SELECT 1 FROM pg_attribute x
                     WHERE x.attrelid = c.oid AND x.attname = 'tenant_sucursal_id'
                       AND x.attnum > 0 AND NOT x.attisdropped)
                  THEN 'tenant_sucursal_id' ELSE 'sucursal_id' END AS tcol
    ) t
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = t.tcol
                       AND a.attnum > 0 AND NOT a.attisdropped
   WHERE c.relkind IN ('r', 'p')
$fn$;

COMMENT ON FUNCTION public._tenant_col_por_tabla() IS
  'Interna (mig 186). Resuelve cuál columna es el tenant de cada tabla: tenant_sucursal_id si existe, si no sucursal_id. Existe porque transferencias_stock tiene las dos y significan cosas distintas — sucursal_id ahi es la otra punta del traslado, no el tenant.';

REVOKE ALL ON FUNCTION public._tenant_col_por_tabla() FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2 · Los pares, salidos del catálogo
--
-- Un par es una FK entre dos tablas que tienen las dos columna de tenant. Ese
-- tenant repetido en la hija es la premisa entera del problema: es un dato
-- derivable del padre que igual se guarda al lado, así que puede contradecirlo.
-- Si la hija no lo tuviera no habría nada que contradecir —`movimiento_sucursal_
-- items` es exactamente ese caso: resuelve la sucursal por join con el
-- movimiento, no la copia, y por eso no aparece acá ni puede divergir. Lo mismo
-- `compra_cargo_repartos` (mig 183).
--
-- El par se identifica por su COLUMNA DE NEGOCIO —la que no es el tenant—, no por
-- la aridad de la FK, y de eso depende que el reporte siga sirviendo después de
-- la 187:
--   · 1 columna                   → el par existe y NO está protegido;
--   · 2, y la segunda ata el tenant → el par existe y SÍ está protegido.
-- La primera versión de esto sólo miraba las FK de una columna, y después de
-- convertirlas el tablero quedaba vacío en vez de quedar en verde: un gate que se
-- apaga solo justo cuando empieza a tener algo que vigilar. Contar los pares
-- protegidos, y no sólo los rotos, es lo que lo mantiene vivo.
--
-- Quedan afuera las FK que no son de esta forma: las de dos columnas de negocio
-- (`compra_cargo_repartos`) y las que apuntan a `sucursales`, que es el ancla del
-- tenant y no tiene columna de tenant propia.
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
  tcol_hija      text,
  columna        text,
  padre          text,
  padre_oid      oid,
  tcol_padre     text,
  columna_padre  text,
  confdeltype    "char",
  confupdtype    "char",
  condeferrable  boolean,
  condeferred    boolean,
  convalidated   boolean,
  protegida      boolean,
  parcial        boolean
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  WITH cand AS (
    SELECT c.conname::text AS conname,
           th.tabla        AS hija,
           c.conrelid      AS hija_oid,
           th.tcol         AS tcol_hija,
           tp.tabla        AS padre,
           c.confrelid     AS padre_oid,
           tp.tcol         AS tcol_padre,
           th.tcol_nullable OR tp.tcol_nullable AS parcial,
           c.conkey, c.confkey,
           c.confdeltype, c.confupdtype,
           c.condeferrable, c.condeferred, c.convalidated
      FROM pg_constraint c
      JOIN public._tenant_col_por_tabla() th ON th.reloid = c.conrelid
      JOIN public._tenant_col_por_tabla() tp ON tp.reloid = c.confrelid
     WHERE c.contype = 'f'
       AND cardinality(c.conkey) <= 2         -- las formas que este modelo cubre
       AND c.conrelid <> c.confrelid          -- la autorreferencia no cruza nada
  ),
  -- Una fila por columna de la FK, con su contraparte en el padre. El WITH
  -- ORDINALITY es el que aparea hija y padre por POSICIÓN, que es como
  -- pg_constraint los relaciona.
  cols AS (
    SELECT cand.*,
           (SELECT a.attname::text FROM pg_attribute a
             WHERE a.attrelid = cand.hija_oid  AND a.attnum = k.ck)                AS c_col,
           (SELECT a.attname::text FROM pg_attribute a
             WHERE a.attrelid = cand.padre_oid AND a.attnum = cand.confkey[k.ord]) AS p_col
      FROM cand, LATERAL unnest(cand.conkey) WITH ORDINALITY AS k(ck, ord)
  ),
  agg AS (
    SELECT conname, hija, hija_oid, tcol_hija, padre, padre_oid, tcol_padre, parcial,
           confdeltype, confupdtype, condeferrable, condeferred, convalidated,
           count(*)                                                  AS n_cols,
           count(*) FILTER (WHERE c_col <> tcol_hija)                AS n_negocio,
           max(c_col) FILTER (WHERE c_col <> tcol_hija)              AS columna,
           max(p_col) FILTER (WHERE c_col <> tcol_hija)              AS columna_padre,
           bool_or(c_col = tcol_hija AND p_col = tcol_padre)         AS ata_tenant
      FROM cols
     GROUP BY conname, hija, hija_oid, tcol_hija, padre, padre_oid, tcol_padre, parcial,
              confdeltype, confupdtype, condeferrable, condeferred, convalidated
  )
  SELECT agg.conname, agg.hija, agg.hija_oid, agg.tcol_hija, agg.columna,
         agg.padre, agg.padre_oid, agg.tcol_padre, agg.columna_padre,
         agg.confdeltype, agg.confupdtype,
         agg.condeferrable, agg.condeferred, agg.convalidated,
         (agg.n_cols = 2 AND agg.ata_tenant) AS protegida,
         agg.parcial
    FROM agg
   WHERE agg.n_negocio = 1                        -- una sola columna de negocio
     AND (agg.n_cols = 1 OR agg.ata_tenant)       -- suelta, o atada por el tenant
$fn$;

COMMENT ON FUNCTION public._pares_sucursal_cruzada() IS
  'Interna (mig 186). Descubre en pg_constraint los pares hija->padre donde las dos tablas tienen columna de tenant y la FK es de una sola columna de negocio: el patrón que permite que la hija contradiga la sucursal del padre. La usan auditoria_sucursal_cruzada() y la migración 187.';

REVOKE ALL ON FUNCTION public._pares_sucursal_cruzada() FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3 · El reporte
--
-- Por cada par: cuántas filas cuelgan de un padre y en cuántas el tenant no
-- coincide. El JOIN interno ya descarta la FK nula, que es legal y no es un cruce.
--
-- `parcial` es la letra chica de `protegida`, y hay que decirla porque si no el
-- tablero promete de más. La FK compuesta es MATCH SIMPLE: se da por satisfecha
-- si CUALQUIERA de las columnas referenciantes es NULL. Con el tenant NOT NULL
-- —que es el caso de 68 de los 69 pares— eso no pasa nunca y la protección es
-- total. `comision_reglas.sucursal_id` es nullable (una regla de comisión sin
-- sucursal es global, y está bien que exista), así que ahí la FK cubre las filas
-- con sucursal y deja pasar las globales. Es mejor que nada y no se puede
-- endurecer sin romper la regla global; lo que no se puede es contarlo como
-- cubierto. Si alguien afloja un NOT NULL de tenant, ese par pasa a `parcial` y
-- se ve, en vez de perder la protección en silencio.
--
-- Por eso `divergentes` compara con las dos puntas NO NULAS y no con
-- `IS DISTINCT FROM`: un tenant NULL es "global", no "cruzada". Con
-- `IS DISTINCT FROM` una regla de comisión global —tenant NULL contra un producto
-- de la sucursal 2— contaba como divergencia y dejaba el preflight de la 187
-- abortando para siempre por una fila perfectamente legal. Contar exactamente lo
-- que la FK rechaza es también lo que mantiene al reporte y a la constraint
-- diciendo lo mismo.
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
  parcial      boolean,
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
      '       count(*) FILTER (WHERE h.%I IS NOT NULL AND p.%I IS NOT NULL'
      '                          AND h.%I <> p.%I)::bigint'
      '  FROM public.%I h JOIN public.%I p ON p.%I = h.%I',
      r.tcol_hija, r.tcol_padre, r.tcol_hija, r.tcol_padre,
      r.hija, r.padre, r.columna_padre, r.columna)
    INTO v_filas, v_div;

    hija        := r.hija;
    columna     := r.columna;
    padre       := r.padre;
    protegida   := r.protegida;
    parcial     := r.parcial;
    filas       := v_filas;
    divergentes := v_div;
    RETURN NEXT;
  END LOOP;
END;
$fn$;

COMMENT ON FUNCTION public.auditoria_sucursal_cruzada() IS
  'Tablero de aislamiento por sucursal (mig 186). Una fila por par hija->padre donde las dos tablas tienen columna de tenant: protegida = la base ya impide el cruce con una FK compuesta; parcial = el tenant es nullable, así que la FK (MATCH SIMPLE) no cubre las filas sin sucursal; divergentes = filas que HOY contradicen el tenant del padre. El objetivo es 0 divergentes y protegida en todas. Recorre entera cada tabla hija: es para CI y verificación, no para una pantalla. Admin-only.';

REVOKE EXECUTE ON FUNCTION public.auditoria_sucursal_cruzada() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.auditoria_sucursal_cruzada() TO authenticated, service_role;

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
--   DROP FUNCTION IF EXISTS public.auditoria_sucursal_cruzada();
--   DROP FUNCTION IF EXISTS public._pares_sucursal_cruzada();
--   DROP FUNCTION IF EXISTS public._tenant_col_por_tabla();
--
-- Exacto: las tres son de sólo lectura y nadie más las llama salvo la 187 y el
-- gate de CI. Dropearlas con la 187 ya aplicada deja las FK compuestas en pie
-- (que es lo que protege) y ciego al gate (que es lo que avisa).
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación — números medidos contra prod el 2026-08-19
--
--   -- El tablero entero: 69 pares, 0 protegidos, 0 cruzados, 2 parciales
--   -- (comision_reglas, por su sucursal_id nullable).
--   SELECT * FROM auditoria_sucursal_cruzada() ORDER BY divergentes DESC, hija;
--
--   -- Lo único que hay que mirar antes de aplicar la 187 — tiene que dar 0 filas:
--   SELECT * FROM auditoria_sucursal_cruzada() WHERE divergentes > 0;
--
--   -- Y el resumen:
--   SELECT count(*)                              AS pares,
--          count(*) FILTER (WHERE protegida)     AS con_fk_compuesta,
--          count(*) FILTER (WHERE parcial)       AS tenant_nullable,
--          count(*) FILTER (WHERE divergentes>0) AS con_filas_cruzadas,
--          sum(divergentes)                      AS filas_cruzadas
--     FROM auditoria_sucursal_cruzada();
--   -- Antes de la 187:   69 |  0 | 2 | 0 | 0     (medido)
--   -- Después de la 187: 69 | 69 | 2 | 0 | 0
--
--   -- El caso que justifica _tenant_col_por_tabla(): contra la columna
--   -- equivocada dan 4 divergencias que son historia buena, contra la correcta 0.
--   SELECT count(*) FILTER (WHERE i.sucursal_id <> t.sucursal_id)        AS falso_positivo,
--          count(*) FILTER (WHERE i.sucursal_id <> t.tenant_sucursal_id) AS real
--     FROM transferencia_items i JOIN transferencias_stock t ON t.id = i.transferencia_id;
--   -- 4 | 0
-- ----------------------------------------------------------------------------
