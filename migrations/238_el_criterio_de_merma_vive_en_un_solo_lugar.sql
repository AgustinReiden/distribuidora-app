-- El criterio de merma vive en un solo lugar
--
-- EL PROBLEMA
-- -----------
-- Tres cosas distintas, el mismo origen: una regla de negocio escrita mas de una
-- vez, sin nadie que verifique que las copias sigan diciendo lo mismo.
--
--   1. #570 · El criterio de merma --cascada de costo, corte del dia argentino,
--      exclusion de `promociones`/`promociones_reversion`-- esta copiado VERBATIM
--      entre `reporte_gerencial` (130: CTEs `k_merma`, `m_merma`, `mermas_motivo`)
--      y `reporte_mermas` (226: CTE `base`). La 226 lo dice en su propia cabecera
--      --"se copian VERBATIM de la 130"-- y pide A MANO que si tocas una toques la
--      otra. Nada lo verifica. La invariante que las une,
--
--          reporte_mermas(d,h,s).totales.costo == reporte_gerencial(s,d,h).kpis.mermas
--
--      se sostenia sobre un comentario.
--
--   2. #511 · `reporte_gerencial` VALUA con la cascada completa
--      --COALESCE(snapshot, costo_promedio, costo_real, formula)-- pero decide
--      `sin_costo` mirando UNA sola pata: `costo_sin_iva IS NULL OR = 0`. Un
--      producto con `costo_promedio` cargado y `costo_sin_iva` en NULL se valua
--      bien y ademas cuenta como "producto sin costo": la alerta avisa que el
--      margen esta inflado cuando no lo esta. `reporte_alerta_detalle` (109)
--      repite ese predicado a mano, sin filtro de fecha y con `estado='entregado'`
--      fijo, asi que la lista detras de la alerta no cuadra con el KPI ni por
--      casualidad. Y `reporte_mermas` clasifica `origen_costo = 'sin_costo'` con
--      `COALESCE(costo_promedio, costo_real, costo_sin_iva) IS NULL`, que NO
--      captura `costo_sin_iva = 0`. Tres predicados, tres respuestas distintas
--      para la misma pregunta.
--
--      Decision (opcion A del issue): `sin_costo` es "la cascada COMPLETA no
--      encuentra nada". Un cero en `costo_sin_iva` no es un costo, es la ausencia
--      de uno, asi que entra a la cascada por `NULLIF(costo_sin_iva, 0)`.
--
--   3. D-8 · `check_promo_limite_usos` (baseline; trigger BEFORE UPDATE OF
--      usos_pendientes) apaga la promo cuando `usos_pendientes >= limite_usos`.
--      Era correcto cuando `usos_pendientes` contaba USOS. Desde las migs 220/221
--      es el RESTO de la barra en [0, N) para las promos con fraccion, y
--      `crear_pedido_completo` hace el bump en SUBUNIDADES **antes** del
--      auto-ajuste que lo baja a ese resto:
--
--          UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad   <- 392
--          ... recien despues: v_bloques_completos := usos_pendientes / unidades_por_bloque
--
--      Una sola boleta con 392 subunidades de regalo pasa por `392 >= 100` y
--      desactiva una promo de 100 usos, un instante antes de que el mismo
--      statement la deje en 2. El chip de VistaPromociones mostraba "2/100 usos"
--      sobre una promo ya apagada, o sea que la pantalla tampoco ayudaba a
--      entender por que.
--
-- LO QUE HACE ESTA MIGRACION
-- --------------------------
-- Cuatro funciones nuevas y tres reescrituras. NINGUN cambio de datos.
--
--   · `costo_valuacion(...)`        — LA cascada de costo, sola y pura.
--   · `costo_valuacion_origen(...)` — de que pata de la cascada salio el costo.
--   · `merma_clasificacion(motivo)` — los CUATRO valores de clasificacion.
--   · `mermas_valorizadas(d,h,suc)` — las filas de merma del periodo, ya valuadas
--     y clasificadas. Es la unica implementacion del criterio: `reporte_gerencial`
--     y `reporte_mermas` la CONSUMEN en vez de repetirla. Eso cierra #570 de raiz:
--     ya no hay dos textos que puedan desalinearse, hay uno.
--
-- POR QUE LOS NUMEROS NO SE MUEVEN (y la unica excepcion, que es el punto de #511)
-- ------------------------------------------------------------------------------
-- La cascada de valuacion ahora entra a `costo_sin_iva` por `NULLIF(..., 0)`. Para
-- un producto con `costo_sin_iva = 0` y ninguna otra pata cargada, el costo
-- unitario pasa de `0` a NULL. **El total no se mueve**: `SUM` ignora los NULL y
-- `cantidad * 0` es 0, asi que las dos formas suman igual. Lo que se gana es que
-- `costo_unitario IS NULL` pase a ser EXACTAMENTE `sin_costo`: un solo predicado
-- en vez de dos que hay que mantener de acuerdo a mano.
--
-- (Corolario operativo: donde antes un grupo entero sin costo sumaba `0`, ahora
-- sumaria `null`. Por eso las sumas de costo que no tenian `COALESCE(...,0)` lo
-- llevan: `bonif_promos.costo`, `mermas_motivo.costo`, `m_merma.mermas`.)
--
-- Lo que SI se mueve, a proposito, es `kpis.ingreso_sin_costo`,
-- `flags.pct_sin_costo`, `categorias[].sin_costo` y la alerta `productos_sin_costo`:
-- dejan de contar los productos que tienen `costo_promedio` o `costo_real`
-- cargados. Medido contra prod el 2026-09-14: hoy hay 3 productos sin ninguna pata
-- de costo, 0 productos "rescatados" por el cambio y `ingreso_sin_costo` da 0 en
-- los 3 meses y las 3 vistas, antes y despues. La diferencia aparece el dia que se
-- venda un producto con promedio y sin `costo_sin_iva`, que es cuando importa.
--
-- LO QUE NO SE TOCA
-- -----------------
-- · Los criterios de venta por vendedor y el filtro de canal (SQL-13 / D-1).
-- · `mermas_stock_snapshot_costo`, el trigger BEFORE INSERT que CONGELA el costo
--   de la merma. Repite la cascada una cuarta vez y ademas redondea a 4 decimales,
--   pero es un camino de ESCRITURA, no de lectura: las dos funciones de reporte
--   leen el mismo `m.costo_unitario` ya escrito, asi que la invariante no depende
--   de el. Unificarlo cambiaria los snapshots futuros; va por issue aparte.

BEGIN;

-- ===========================================================================
-- 1 · La cascada de costo, sola y pura
-- ===========================================================================
-- Sin `SET search_path` y sin referencias a objetos: el cuerpo es aritmetica de
-- `pg_catalog` y nada mas, asi el planner puede inlinearla en el SELECT que la
-- llama por fila. Mismo molde que `factor_bonificacion` (227).
--
-- El orden de la cascada es el de la mig 130 y NO cambia:
--   snapshot congelado > costo promedio ponderado > costo de reposicion > formula.
-- Lo unico nuevo es el `NULLIF(p_costo_sin_iva, 0)`. Ver la cabecera.

CREATE OR REPLACE FUNCTION public.costo_valuacion(
  p_snapshot           numeric,
  p_costo_promedio     numeric,
  p_costo_real         numeric,
  p_costo_sin_iva      numeric,
  p_impuestos_internos numeric DEFAULT 0
) RETURNS numeric
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT COALESCE(
    p_snapshot,
    p_costo_promedio,
    p_costo_real,
    NULLIF(p_costo_sin_iva, 0) * (1 + COALESCE(p_impuestos_internos, 0) / 100)
  );
$$;

COMMENT ON FUNCTION public.costo_valuacion(numeric, numeric, numeric, numeric, numeric) IS
  'LA cascada de costo unitario: snapshot > costo_promedio > costo_real > '
  'costo_sin_iva*(1+ii/100), con NULLIF(costo_sin_iva,0) porque un cero no es un '
  'costo. Devuelve NULL si y solo si no hay ninguna pata cargada: "IS NULL" ES el '
  'predicado sin_costo. mig 238 (#511).';

-- De que pata salio. Coherente con la de arriba POR CONSTRUCCION:
--   costo_valuacion(...) IS NULL  <=>  costo_valuacion_origen(...) = 'sin_costo'
-- El ensayo del final lo verifica sobre una grilla de 32 combinaciones.
CREATE OR REPLACE FUNCTION public.costo_valuacion_origen(
  p_snapshot       numeric,
  p_costo_promedio numeric,
  p_costo_real     numeric,
  p_costo_sin_iva  numeric
) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN p_snapshot IS NOT NULL THEN 'congelado'
    WHEN COALESCE(p_costo_promedio, p_costo_real, NULLIF(p_costo_sin_iva, 0)) IS NULL THEN 'sin_costo'
    ELSE 'estimado'
  END;
$$;

COMMENT ON FUNCTION public.costo_valuacion_origen(numeric, numeric, numeric, numeric) IS
  'De donde salio el costo que devuelve costo_valuacion(): congelado (snapshot al '
  'momento del hecho), estimado (costo de hoy) o sin_costo (ninguna pata cargada). '
  'mig 238 (#511).';

-- Los CUATRO valores de clasificacion. El gerencial usa tres porque EXCLUYE las
-- filas de promocion; `reporte_mermas` las deja entrar y las informa aparte. Con
-- una sola funcion, "excluir promociones" pasa a ser `clasificacion <> 'promocion'`
-- en los dos lados: literalmente el mismo predicado, no dos que se parecen.
CREATE OR REPLACE FUNCTION public.merma_clasificacion(p_motivo text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT CASE
    WHEN COALESCE(p_motivo, '') IN ('promociones', 'promociones_reversion')     THEN 'promocion'
    WHEN p_motivo IN ('vencimiento', 'rotura', 'robo', 'decomiso', 'devolucion') THEN 'perdida'
    WHEN p_motivo = 'muestra'                                                   THEN 'muestra'
    ELSE 'ajuste'
  END;
$$;

COMMENT ON FUNCTION public.merma_clasificacion(text) IS
  'Clasificacion de negocio de un motivo de merma: perdida | ajuste | muestra | '
  'promocion. Las de promocion NO son perdida --son la contrapartida de un regalo '
  'ya contabilizado como bonificacion-- y quedan fuera del total. mig 238 (#570).';

-- ===========================================================================
-- 2 · El criterio de merma, una sola vez
-- ===========================================================================
-- SECURITY INVOKER a proposito: no hace NINGUN control de acceso y recibe el array
-- de sucursales ya resuelto. Quien la llama --`reporte_gerencial` y
-- `reporte_mermas`, las dos SECURITY DEFINER de `postgres`-- ya autorizo. Por eso
-- tampoco se le da EXECUTE a `authenticated`: si alguien pudiera llamarla directo
-- le estaria pasando el array de sucursales que se le antoje.

CREATE OR REPLACE FUNCTION public.mermas_valorizadas(
  p_desde      date,
  p_hasta      date,
  p_sucursales bigint[]
) RETURNS TABLE (
  id                 bigint,
  created_at         timestamptz,
  fecha_local        date,
  sucursal_id        bigint,
  usuario_id         uuid,
  producto_id        bigint,
  producto_nombre    text,
  producto_codigo    text,
  producto_categoria text,
  motivo             text,
  clasificacion      text,
  cantidad           integer,
  costo_unitario     numeric,
  costo_total        numeric,
  precio_unitario    numeric,
  precio_total       numeric,
  origen_costo       text,
  observaciones      text,
  stock_anterior     integer,
  stock_nuevo        integer
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $fn$
  -- Todas las referencias van calificadas (`m.` / `prod.`): en una funcion SQL con
  -- RETURNS TABLE los nombres de salida son parametros, y una referencia suelta a
  -- `id` o a `cantidad` seria ambigua.
  SELECT
    m.id,
    m.created_at,
    (m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date            AS fecha_local,
    m.sucursal_id,
    m.usuario_id,
    m.producto_id,
    prod.nombre::text                                                            AS producto_nombre,
    prod.codigo::text                                                            AS producto_codigo,
    prod.categoria::text                                                         AS producto_categoria,
    COALESCE(NULLIF(m.motivo, ''), '(sin motivo)')::text                         AS motivo,
    public.merma_clasificacion(m.motivo)                                         AS clasificacion,
    m.cantidad,
    -- Sin ROUND: la 130 no redondea el costo unitario y redondear aca romperia el
    -- cruce con `kpis.mermas` sin que falle nada (lo dice la cabecera de la 226).
    public.costo_valuacion(m.costo_unitario, prod.costo_promedio, prod.costo_real,
                           prod.costo_sin_iva, prod.impuestos_internos)          AS costo_unitario,
    m.cantidad * public.costo_valuacion(m.costo_unitario, prod.costo_promedio, prod.costo_real,
                                        prod.costo_sin_iva, prod.impuestos_internos) AS costo_total,
    prod.precio                                                                  AS precio_unitario,
    m.cantidad * prod.precio                                                     AS precio_total,
    public.costo_valuacion_origen(m.costo_unitario, prod.costo_promedio,
                                  prod.costo_real, prod.costo_sin_iva)           AS origen_costo,
    m.observaciones,
    m.stock_anterior,
    m.stock_nuevo
  FROM mermas_stock m
  JOIN productos prod ON prod.id = m.producto_id
  WHERE m.sucursal_id = ANY(p_sucursales)
    -- El corte es por DIA ARGENTINO de carga, no por UTC: una merma cargada a las
    -- 22:00 del 31 es del 31, no del 1 del mes siguiente.
    AND (m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta;
$fn$;

COMMENT ON FUNCTION public.mermas_valorizadas(date, date, bigint[]) IS
  'LA implementacion del criterio de merma: corte por dia argentino de carga, costo '
  'por costo_valuacion() y clasificacion por merma_clasificacion(). La consumen '
  'reporte_gerencial (excluyendo clasificacion=promocion) y reporte_mermas '
  '(informandolas aparte), asi totales.costo cierra EXACTO contra kpis.mermas por '
  'construccion y no por copiar el texto. SECURITY INVOKER: no autoriza nada, '
  'recibe el array de sucursales ya resuelto. mig 238 (#570).';

-- ===========================================================================
-- 3 · reporte_gerencial: consume el criterio y unifica sin_costo
-- ===========================================================================
-- Texto base = el cuerpo VIVO en prod al 2026-09-14, que ya NO es el de la 130 (la
-- 227 le metio `factor_bonificacion` y `vendedores` gano `pf.id`). El diff es:
--
--   · `it`: `costo_unit` y `costo_bonif` pasan por `costo_valuacion()`, y
--     `sin_costo` deja de mirar solo `costo_sin_iva` para ser `costo_unit IS NULL`.
--   · `mv`: un CTE con las mermas del periodo ya valuadas y sin las de promocion.
--     `k_merma`, `m_merma` y `mermas_motivo` lo AGREGAN, en vez de re-escanear
--     `mermas_stock` con el criterio escrito tres veces. Referenciado tres veces,
--     Postgres lo materializa una sola: ademas de dejar de duplicarse, deja de
--     escanear la tabla tres veces.
--   · `COALESCE(...,0)` en las tres sumas de costo que no lo tenian. Ver cabecera.

CREATE OR REPLACE FUNCTION public.reporte_gerencial(
  p_sucursal_id bigint,
  p_desde date,
  p_hasta date,
  p_incluir_no_entregados boolean DEFAULT false,
  p_comparar boolean DEFAULT false
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[]; v_asignadas bigint[]; v_nombre text; v_result jsonb;
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_estados text[] := CASE WHEN p_incluir_no_entregados
                           THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                           ELSE ARRAY['entregado'] END;
  v_dias int := (p_hasta - p_desde) + 1;
  v_prev_hasta date := p_desde - 1;
  v_prev_desde date := (p_desde - 1) - ((p_hasta - p_desde));
  v_comparativo jsonb := NULL;
  v_prev jsonb;
  v_alertas jsonb := '[]'::jsonb;
  v_cat_neg int;
  v_cli_inact int;
  v_cob_venc numeric;
  v_cob_venc_cli int;
  v_venta numeric;
  v_prev_venta numeric;
  v_mermas numeric;
  v_prev_mermas numeric;
BEGIN
  IF NOT v_es_servicio THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin'; END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'; END IF;
  END IF;
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales,1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario'; END IF;

  WITH
  ped AS (
    SELECT id, cliente_id, usuario_id, total, monto_pagado, fecha, forma_pago, estado_pago,
           COALESCE(total_neto, total) AS total_neto, COALESCE(total_iva, 0) AS total_iva,
           COALESCE(tipo_factura, 'ZZ') AS tipo_factura,
           COALESCE(total_real,
             CASE WHEN COALESCE(tipo_factura, 'ZZ') = 'FC' THEN COALESCE(total_neto, total) ELSE total END
           ) AS total_real
    FROM pedidos WHERE estado = ANY(v_estados) AND canal='app'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
  ),
  it AS (
    SELECT p.id AS pedido_id, p.usuario_id, p.fecha,
           pi.cantidad, pi.subtotal, pi.es_bonificacion,
           public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                  prod.costo_sin_iva, prod.impuestos_internos) AS costo_unit,
           pi.cantidad * COALESCE(pi.ingreso_real_unitario,
             CASE WHEN p.tipo_factura = 'FC' THEN COALESCE(pi.neto_unitario, pi.precio_unitario)
                  ELSE pi.precio_unitario END) AS ingreso_real,
           prod.nombre AS prod_nombre,
           COALESCE(NULLIF(prod.categoria,''),'(sin categoría)') AS categoria,
           -- #511: sin_costo es "la cascada COMPLETA no encontro nada", no "falta
           -- costo_sin_iva". Un producto con costo_promedio cargado se valua bien
           -- y por lo tanto NO infla ningun margen.
           (public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                   prod.costo_sin_iva, prod.impuestos_internos) IS NULL) AS sin_costo,
           pr.nombre AS promo_nombre,
           (public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque) > 1) AS es_fraccion,
           public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque) AS unidades_por_bloque,
           COALESCE(prod.precio,0) AS precio_lista,
           -- `factor_bonificacion` devuelve >= 1 siempre, asi que la division cubre
           -- los dos casos que antes eran dos ramas de un CASE (227).
           CASE WHEN pi.es_bonificacion THEN
             pi.cantidad * public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio,
                                                  prod.costo_real, prod.costo_sin_iva, prod.impuestos_internos)
             / public.factor_bonificacion(pi.unidades_por_bloque_al_crear, pr.regalo_mueve_stock, pr.unidades_por_bloque)
           ELSE 0 END AS costo_bonif
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id
  ),
  nc AS (
    SELECT usuario_id, total FROM pedidos
    WHERE estado<>'cancelado' AND canal='app'
      AND fecha BETWEEN p_desde AND p_hasta AND sucursal_id = ANY(v_sucursales)
      AND usuario_id IN (SELECT id FROM perfiles)
  ),
  k_ped AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(total),0) AS venta,
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(total)),0) AS ticket,
            COALESCE(SUM(total_neto),0) AS venta_neta,
            COALESCE(SUM(total_iva),0) AS iva_debito,
            COALESCE(SUM(total_real),0) AS venta_real,
            COALESCE(SUM(total) FILTER (WHERE tipo_factura='FC'),0) AS fc_venta,
            COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_pedidos,
            COALESCE(SUM(total) FILTER (WHERE tipo_factura='ZZ'),0) AS zz_venta,
            COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_pedidos
            FROM ped),
  k_it AS (
    SELECT COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
      COALESCE(SUM(costo_bonif),0) AS bonif,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades,
      COALESCE(SUM(cantidad) FILTER (WHERE es_bonificacion),0) AS unidades_bonif,
      COALESCE(SUM(subtotal) FILTER (WHERE sin_costo AND NOT es_bonificacion),0) AS ingreso_sin_costo
    FROM it
  ),
  k_nc AS (SELECT COALESCE(SUM(total),0) AS base_comision FROM nc),
  -- #570: el criterio de merma ya no se escribe aca; se consume.
  -- `clasificacion <> 'promocion'` es EXACTAMENTE el viejo
  -- `COALESCE(motivo,'') NOT IN ('promociones','promociones_reversion')`.
  mv AS (
    SELECT * FROM public.mermas_valorizadas(p_desde, p_hasta, v_sucursales)
    WHERE clasificacion <> 'promocion'
  ),
  k_merma AS (
    SELECT COALESCE(SUM(costo_total),0) AS mermas,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'perdida'),0) AS mermas_perdida,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'ajuste'),0)  AS mermas_ajuste,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'muestra'),0) AS mermas_muestra
    FROM mv
  ),
  k_compra AS (SELECT COALESCE(SUM(total),0) AS compras FROM compras
    WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta
      AND COALESCE(estado,'') <> 'cancelada'),
  k_nuevos AS (SELECT COUNT(*) AS nuevos FROM (
      SELECT cliente_id, MIN(fecha) AS pc FROM pedidos
      WHERE estado='entregado' AND sucursal_id = ANY(v_sucursales) GROUP BY cliente_id
    ) t WHERE pc BETWEEN p_desde AND p_hasta),
  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(total) AS venta,
            SUM(total_real) AS venta_real,
            COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(total)) AS ticket FROM ped GROUP BY 1),
  m_it AS (SELECT to_char(fecha,'YYYY-MM') AS mes,
           COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS cmv,
           COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY 1),
  m_merma AS (SELECT to_char(fecha_local,'YYYY-MM') AS mes,
              COALESCE(SUM(costo_total),0) AS mermas FROM mv GROUP BY 1),
  m_compra AS (SELECT to_char(fecha_compra,'YYYY-MM') AS mes, SUM(total) AS compras
    FROM compras WHERE sucursal_id = ANY(v_sucursales) AND fecha_compra BETWEEN p_desde AND p_hasta
      AND COALESCE(estado,'') <> 'cancelada' GROUP BY 1),
  mensual AS (SELECT mp.mes, mp.pedidos, mp.venta, mp.venta_real, mp.clientes, mp.ticket,
      COALESCE(mi.cmv,0) AS cmv, COALESCE(mi.bonif,0) AS bonif,
      (mp.venta_real - COALESCE(mi.cmv,0)) AS margen_real,
      COALESCE(mm.mermas,0) AS mermas, COALESCE(mc.compras,0) AS compras
    FROM m_ped mp LEFT JOIN m_it mi ON mi.mes=mp.mes LEFT JOIN m_merma mm ON mm.mes=mp.mes LEFT JOIN m_compra mc ON mc.mes=mp.mes),
  v_ent AS (SELECT usuario_id, COUNT(DISTINCT pedido_id) AS pedidos, SUM(subtotal) AS venta,
      SUM(ingreso_real) AS venta_real,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif FROM it GROUP BY usuario_id),
  v_nc AS (SELECT usuario_id, SUM(total) AS base_nc FROM nc GROUP BY usuario_id),
  vendedores AS (SELECT pf.id, pf.nombre, pf.rol, e.pedidos, e.venta, e.venta_real, e.margen_comercial, e.margen_real, e.bonif,
      COALESCE(n.base_nc, e.venta) AS base_nc
    FROM v_ent e JOIN perfiles pf ON pf.id=e.usuario_id LEFT JOIN v_nc n ON n.usuario_id=e.usuario_id),
  categorias AS (SELECT categoria, SUM(subtotal) AS venta,
      SUM(ingreso_real) AS venta_real,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_comercial,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real,
      COALESCE(SUM(costo_bonif),0) AS bonif, bool_or(sin_costo) AS sin_costo
    FROM it GROUP BY categoria),
  top_prod AS (SELECT prod_nombre AS nombre,
      COALESCE(SUM(cantidad) FILTER (WHERE NOT es_bonificacion),0) AS unidades, SUM(subtotal) AS venta,
      SUM(ingreso_real) AS venta_real,
      SUM(subtotal) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen,
      SUM(ingreso_real) - COALESCE(SUM(cantidad*costo_unit) FILTER (WHERE NOT es_bonificacion),0) AS margen_real
    FROM it GROUP BY prod_nombre ORDER BY venta DESC LIMIT 10),
  top_cli AS (SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS cliente,
      COUNT(DISTINCT p.id) AS pedidos, SUM(p.total) AS venta
    FROM ped p JOIN clientes c ON c.id=p.cliente_id GROUP BY 1 ORDER BY venta DESC LIMIT 10),
  bonif_promos AS (SELECT COALESCE(promo_nombre,'(sin promoción)') AS promocion, prod_nombre AS producto,
      SUM(cantidad) AS unidades, bool_or(es_fraccion) AS es_fraccion,
      COALESCE(SUM(costo_bonif),0) AS costo,
      SUM(CASE WHEN es_fraccion THEN cantidad * precio_lista / unidades_por_bloque
               ELSE cantidad * precio_lista END) AS valor_venta
    FROM it WHERE es_bonificacion GROUP BY 1, 2 HAVING SUM(cantidad) > 0),
  mermas_motivo AS (SELECT motivo, clasificacion,
      SUM(cantidad) AS unidades, COALESCE(SUM(costo_total),0) AS costo
    FROM mv GROUP BY 1, 2),
  cobr AS (SELECT COALESCE(SUM(LEAST(COALESCE(monto_pagado,0), total)),0) AS cobrado,
      COALESCE(SUM(GREATEST(total - COALESCE(monto_pagado,0), 0)),0) AS pendiente FROM ped),
  pagos_ped AS (SELECT COALESCE(NULLIF(pg.forma_pago,''),'(sin dato)') AS forma_pago, SUM(pg.monto) AS monto
    FROM pagos pg JOIN ped ON ped.id = pg.pedido_id GROUP BY 1),
  formas AS (SELECT forma_pago, monto FROM pagos_ped
    UNION ALL
    SELECT '(sin registro de pago)', c.cobrado - COALESCE((SELECT SUM(monto) FROM pagos_ped),0)
    FROM cobr c
    WHERE c.cobrado - COALESCE((SELECT SUM(monto) FROM pagos_ped),0) > 0.01),
  serie AS (SELECT to_char(fecha,'DD/MM') AS dia, SUM(total) AS venta FROM ped GROUP BY fecha ORDER BY fecha)
  SELECT jsonb_build_object(
    'meta', jsonb_build_object('sucursal_id', p_sucursal_id, 'sucursal_nombre', COALESCE(v_nombre,'?'),
      'desde', p_desde, 'hasta', p_hasta, 'generado_at', now(),
      'incluye_no_entregados', p_incluir_no_entregados),
    'kpis', (SELECT jsonb_build_object('venta', kp.venta, 'pedidos', kp.pedidos, 'clientes', kp.clientes, 'ticket', kp.ticket,
        'clientes_nuevos', kn.nuevos, 'cmv', ki.cmv, 'bonif', ki.bonif, 'unidades', ki.unidades,
        'unidades_bonif', ki.unidades_bonif, 'margen_comercial', kp.venta - ki.cmv,
        'margen_neto', kp.venta - ki.cmv - ki.bonif, 'base_comision', kc.base_comision, 'comision_pct_default', 2,
        'mermas', km.mermas, 'mermas_perdida', km.mermas_perdida, 'mermas_ajuste', km.mermas_ajuste,
        'mermas_muestra', km.mermas_muestra, 'compras', kcp.compras, 'ingreso_sin_costo', ki.ingreso_sin_costo,
        'venta_neta', kp.venta_neta, 'iva_debito', kp.iva_debito,
        'margen_comercial_neto', kp.venta_neta - ki.cmv,
        'venta_real', kp.venta_real,
        'margen_real', kp.venta_real - ki.cmv,
        'margen_real_neto', kp.venta_real - ki.cmv - ki.bonif,
        'fc_venta', kp.fc_venta, 'fc_pedidos', kp.fc_pedidos,
        'zz_venta', kp.zz_venta, 'zz_pedidos', kp.zz_pedidos)
      FROM k_ped kp, k_it ki, k_nc kc, k_merma km, k_compra kcp, k_nuevos kn),
    'mensual', (SELECT COALESCE(jsonb_agg(to_jsonb(m) ORDER BY m.mes),'[]') FROM mensual m),
    'vendedores', (SELECT COALESCE(jsonb_agg(to_jsonb(v) ORDER BY v.venta DESC),'[]') FROM vendedores v),
    'categorias', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.venta DESC),'[]') FROM categorias c),
    'top_productos', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_prod t),
    'top_clientes', (SELECT COALESCE(jsonb_agg(to_jsonb(t)),'[]') FROM top_cli t),
    'bonif_promos', (SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.valor_venta DESC),'[]') FROM bonif_promos b),
    'mermas_motivo', (SELECT COALESCE(jsonb_agg(to_jsonb(mm) ORDER BY mm.costo DESC),'[]') FROM mermas_motivo mm),
    'cobranza', jsonb_build_object('formas', (SELECT COALESCE(jsonb_agg(to_jsonb(f) ORDER BY f.monto DESC),'[]') FROM formas f),
      'cobrado', (SELECT cobrado FROM cobr), 'pendiente', (SELECT pendiente FROM cobr)),
    'serie_diaria', (SELECT COALESCE(jsonb_agg(jsonb_build_array(s.dia, s.venta)),'[]') FROM serie s),
    'flags', (SELECT jsonb_build_object('ingreso_sin_costo', ki.ingreso_sin_costo,
        'pct_sin_costo', CASE WHEN kp.venta > 0 THEN round(100.0*ki.ingreso_sin_costo/kp.venta,1) ELSE 0 END)
      FROM k_it ki, k_ped kp)
  ) INTO v_result;

  IF p_comparar THEN
    v_prev := public.reporte_gerencial(p_sucursal_id, v_prev_desde, v_prev_hasta, p_incluir_no_entregados, false);
    v_comparativo := (v_prev->'kpis') || jsonb_build_object('desde', v_prev_desde, 'hasta', v_prev_hasta);
  END IF;

  v_venta := (v_result->'kpis'->>'venta')::numeric;
  v_mermas := (v_result->'kpis'->>'mermas')::numeric;
  v_prev_venta := (v_comparativo->>'venta')::numeric;
  v_prev_mermas := (v_comparativo->>'mermas')::numeric;

  IF p_comparar AND COALESCE(v_prev_venta,0) > 0 AND v_venta < v_prev_venta * 0.9 THEN
    v_alertas := v_alertas || jsonb_build_object(
      'severidad', CASE WHEN v_venta < v_prev_venta*0.8 THEN 'critical' ELSE 'warning' END,
      'codigo','venta_caida','titulo','Venta en baja',
      'detalle','Cayó '||round((1 - v_venta/v_prev_venta)*100)::text||'% vs período anterior',
      'valor', v_venta - v_prev_venta, 'seccion','evolucion');
  END IF;

  SELECT COALESCE(SUM(total - COALESCE(monto_pagado,0)),0), COUNT(DISTINCT cliente_id)
    INTO v_cob_venc, v_cob_venc_cli
  FROM pedidos
  WHERE estado='entregado' AND canal='app' AND sucursal_id = ANY(v_sucursales)
    AND COALESCE(estado_pago,'pendiente') IN ('pendiente','parcial')
    AND fecha < CURRENT_DATE - 30 AND total > COALESCE(monto_pagado,0);
  IF v_cob_venc > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','critical','codigo','cobranza_vencida','titulo','Cobranza vencida',
      'detalle', v_cob_venc_cli::text||' cliente(s) con saldo impago hace +30 días',
      'valor', v_cob_venc, 'seccion','cobranza');
  END IF;

  SELECT COUNT(*) INTO v_cli_inact FROM (
    SELECT p.cliente_id FROM pedidos p
    WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
    GROUP BY p.cliente_id
    HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
  ) t;
  IF v_cli_inact > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','clientes_inactivos','titulo','Clientes que dejaron de comprar',
      'detalle', v_cli_inact::text||' cliente(s) sin comprar hace +30 días (compraban hasta hace poco)',
      'valor', v_cli_inact, 'seccion','clientes');
  END IF;

  IF p_comparar AND COALESCE(v_prev_mermas,0) > 0 AND v_mermas > v_prev_mermas*1.3 AND v_mermas > 50000 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','mermas_alza','titulo','Mermas en alza',
      'detalle','Subieron '||round((v_mermas/v_prev_mermas - 1)*100)::text||'% vs período anterior',
      'valor', v_mermas, 'seccion','mermas');
  END IF;

  SELECT COUNT(*) INTO v_cat_neg FROM jsonb_array_elements(v_result->'categorias') c WHERE (c->>'margen_comercial')::numeric < 0;
  IF v_cat_neg > 0 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','warning','codigo','margen_categoria_negativo','titulo','Categorías con margen negativo',
      'detalle', v_cat_neg::text||' categoría(s) con margen comercial negativo',
      'valor', v_cat_neg, 'seccion','categorias');
  END IF;

  IF (v_result->'flags'->>'pct_sin_costo')::numeric >= 1 THEN
    v_alertas := v_alertas || jsonb_build_object('severidad','info','codigo','productos_sin_costo','titulo','Productos sin costo',
      'detalle', (v_result->'flags'->>'pct_sin_costo')::text||'% de la venta es de productos sin costo (margen sobreestimado)',
      'valor', (v_result->'flags'->>'ingreso_sin_costo')::numeric, 'seccion','categorias');
  END IF;

  SELECT COALESCE(jsonb_agg(a ORDER BY array_position(ARRAY['critical','warning','info'], a->>'severidad')), '[]'::jsonb)
    INTO v_alertas FROM jsonb_array_elements(v_alertas) a;

  v_result := v_result || jsonb_build_object('comparativo', COALESCE(v_comparativo,'null'::jsonb), 'alertas', v_alertas);
  RETURN v_result;
END;
$function$;

REVOKE ALL    ON FUNCTION public.reporte_gerencial(bigint, date, date, boolean, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_gerencial(bigint, date, date, boolean, boolean) TO authenticated, service_role;

-- ===========================================================================
-- 4 · reporte_mermas: el mismo criterio, del mismo lugar
-- ===========================================================================
-- Misma firma ⇒ CREATE OR REPLACE (no hay dos sobrecargas que puedan darle
-- PGRST203 a PostgREST). El unico diff contra la 226 es de DONDE salen las filas:
-- el CTE `base`, que era la copia verbatim del criterio, ahora es una llamada.
-- Los totales, el corte por motivo y el limite del detalle no cambian.
--
-- El payload gana un campo por fila del detalle: `fecha_local`, el dia argentino
-- con el que se corta el periodo. Es aditivo (la pantalla ya mostraba
-- `created_at`) y estaba calculado igual antes, solo que sin nombre.

CREATE OR REPLACE FUNCTION public.reporte_mermas(
  p_desde          date,
  p_hasta          date,
  p_sucursal_id    bigint  DEFAULT NULL,
  p_motivo         text    DEFAULT NULL,
  p_limite_detalle integer DEFAULT 500
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursales  bigint[];
  v_asignadas   bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  v_rol         text;
  v_nombre      text;
  v_limite      integer := LEAST(GREATEST(COALESCE(p_limite_detalle, 500), 1), 2000);
  v_out         jsonb;
BEGIN
  -- Guard identico al de la 208: es la familia de /reportes, donde
  -- `reporte_rentabilidad` ya expone costos a encargado.
  IF NOT v_es_servicio THEN
    SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
    IF v_rol IS NULL OR v_rol NOT IN ('admin', 'encargado') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin o encargado';
    END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas
      FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN
      RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas';
    END IF;
  END IF;

  -- Resolucion de sucursales calcada de la 130 (activas INTERSECT asignadas), NO
  -- de la 208 (todas las sucursales). Este reporte tiene que cerrar exacto contra
  -- kpis.mermas: si "Red" resuelve a conjuntos distintos, los dos numeros difieren
  -- y nadie sabe cual esta mal.
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas);
    END IF;
    v_nombre := 'Red (consolidado)';
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no esta asignada al usuario', p_sucursal_id;
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
    SELECT nombre INTO v_nombre FROM sucursales WHERE id = p_sucursal_id;
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles para el usuario';
  END IF;

  WITH
  -- #570: el criterio (cascada, dia argentino, clasificacion) sale de la MISMA
  -- funcion que consume `reporte_gerencial`. Aca las de promocion ENTRAN --para
  -- poder decir cuanto son y por que no cuentan-- y quedan fuera de los totales
  -- por `clasificacion <> 'promocion'`, que es el filtro que aplica el gerencial.
  calc AS (
    SELECT * FROM public.mermas_valorizadas(p_desde, p_hasta, v_sucursales)
    WHERE (p_motivo IS NULL OR motivo = p_motivo)
  ),
  -- Los totales y el corte por motivo se calculan sobre el CTE COMPLETO. Solo el
  -- detalle lleva LIMIT: truncar acorta la lista, nunca mueve un total. Ese era el
  -- defecto del modal que este reporte vino a reemplazar.
  tot AS (
    SELECT
      COUNT(*) FILTER (WHERE clasificacion <> 'promocion')                       AS registros,
      COALESCE(SUM(cantidad)     FILTER (WHERE clasificacion <> 'promocion'), 0) AS unidades,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion <> 'promocion'), 0) AS costo,
      COALESCE(SUM(precio_total) FILTER (WHERE clasificacion <> 'promocion'), 0) AS precio,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion = 'perdida'), 0)    AS costo_perdida,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion = 'ajuste'), 0)     AS costo_ajuste,
      COALESCE(SUM(costo_total)  FILTER (WHERE clasificacion = 'muestra'), 0)    AS costo_muestra,
      COUNT(*) FILTER (WHERE clasificacion = 'promocion')                        AS registros_ajuste_promocion,
      COALESCE(SUM(cantidad)    FILTER (WHERE clasificacion = 'promocion'), 0)   AS unidades_ajuste_promocion,
      COALESCE(SUM(costo_total) FILTER (WHERE clasificacion = 'promocion'), 0)   AS costo_ajuste_promocion,
      COUNT(*) FILTER (WHERE clasificacion <> 'promocion' AND origen_costo = 'estimado')  AS filas_costo_estimado,
      COUNT(*) FILTER (WHERE clasificacion <> 'promocion' AND origen_costo = 'sin_costo') AS filas_sin_costo
    FROM calc
  ),
  por_motivo AS (
    SELECT motivo, clasificacion,
           COUNT(*)                       AS registros,
           COALESCE(SUM(cantidad), 0)     AS unidades,
           COALESCE(SUM(costo_total), 0)  AS costo,
           COALESCE(SUM(precio_total), 0) AS precio,
           COUNT(*) FILTER (WHERE origen_costo = 'estimado')  AS filas_costo_estimado,
           COUNT(*) FILTER (WHERE origen_costo = 'sin_costo') AS filas_sin_costo
    FROM calc GROUP BY motivo, clasificacion
  ),
  det AS (
    SELECT c.*, per.nombre AS usuario_nombre, suc.nombre AS sucursal_nombre
    FROM calc c
    LEFT JOIN perfiles per   ON per.id = c.usuario_id
    LEFT JOIN sucursales suc ON suc.id = c.sucursal_id
    ORDER BY c.created_at DESC, c.id DESC
    LIMIT v_limite
  )
  SELECT jsonb_build_object(
    'meta', jsonb_build_object(
      'sucursal_id', p_sucursal_id,
      'sucursal_nombre', COALESCE(v_nombre, 'Sucursal ' || p_sucursal_id),
      'desde', p_desde,
      'hasta', p_hasta,
      'generado_at', now(),
      'filtro_motivo', p_motivo,
      'criterio', 'Mermas por dia argentino de carga (created_at), valuadas al costo congelado al momento de la merma (mig 119); las anteriores al snapshot van al costo de hoy. El total EXCLUYE promociones y reversion de promocion: no son perdida, son la contrapartida de un regalo ya contabilizado como bonificacion. El criterio no se copia de reporte_gerencial: los dos consumen mermas_valorizadas() (mig 238), y por eso cierran exacto. El precio de venta es el de HOY: la base no guarda a cuanto se vendia el dia de la merma.'
    ),
    'totales', (SELECT to_jsonb(t) FROM tot t),
    'por_motivo', COALESCE((SELECT jsonb_agg(to_jsonb(pm) ORDER BY pm.costo DESC) FROM por_motivo pm), '[]'::jsonb),
    'detalle', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.created_at DESC, d.id DESC) FROM det d), '[]'::jsonb),
    'detalle_total', (SELECT COUNT(*) FROM calc),
    'detalle_limite', v_limite,
    'detalle_truncado', ((SELECT COUNT(*) FROM calc) > v_limite)
  ) INTO v_out;

  RETURN v_out;
END;
$fn$;

COMMENT ON FUNCTION public.reporte_mermas(date, date, bigint, text, integer) IS
  'Mermas agregadas por motivo + detalle acotado. El criterio (cascada de costo, '
  'dia argentino, clasificacion) sale de mermas_valorizadas(), la MISMA funcion que '
  'consume reporte_gerencial: totales.costo cierra EXACTO contra kpis.mermas por '
  'construccion. migs 226 y 238.';

-- ===========================================================================
-- 5 · reporte_alerta_detalle: la lista tiene que cuadrar con el KPI
-- ===========================================================================
-- CAMBIA LA FIRMA: se le agregan `p_desde`, `p_hasta` y `p_incluir_no_entregados`.
-- La vieja de 2 argumentos se DROPEA en la misma migracion: dos sobrecargas con
-- rangos [obligatorios, total] superpuestos --[2,2] y [2,5]-- hacen que PostgREST
-- no sepa cual llamar y tire PGRST203 en runtime, invisible para tsc y para los
-- tests (CLAUDE.md, trampa 5).
--
-- POR QUE `productos_sin_costo` necesitaba los tres:
--   · El KPI `ingreso_sin_costo` se calcula sobre el PERIODO elegido; la lista
--     sumaba TODO el historico. Los dos numeros no podian coincidir.
--   · El KPI respeta el toggle "Todos los pedidos / Ventas entregadas"; la lista
--     tenia `estado='entregado'` clavado.
--   · Y el predicado era la pata suelta de #511. Ahora es `costo_valuacion(...)
--     IS NULL`, el mismo que usa `it.sin_costo` en el gerencial.
--
-- Las otras dos alertas NO se filtran por periodo, y es a proposito: el gerencial
-- las calcula contra `CURRENT_DATE - 30/90`, no contra el rango de pantalla. Si la
-- lista se filtrara por periodo dejaria de mostrar justamente a los que la alerta
-- cuenta. Los parametros llegan igual (una sola firma) y se ignoran ahi.
--
-- `p_desde`/`p_hasta` en NULL = sin filtro de fecha, o sea el comportamiento viejo.

DROP FUNCTION IF EXISTS public.reporte_alerta_detalle(bigint, text);

CREATE FUNCTION public.reporte_alerta_detalle(
  p_sucursal_id           bigint,
  p_codigo                text,
  p_desde                 date    DEFAULT NULL,
  p_hasta                 date    DEFAULT NULL,
  p_incluir_no_entregados boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[];
  v_asignadas bigint[];
  v_es_servicio boolean := (auth.uid() IS NULL);
  -- Los MISMOS estados que reporte_gerencial, de la misma forma.
  v_estados text[] := CASE WHEN p_incluir_no_entregados
                           THEN ARRAY['entregado','asignado','pendiente','en_preparacion']
                           ELSE ARRAY['entregado'] END;
  v_result jsonb;
BEGIN
  IF NOT v_es_servicio THEN
    IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
      RAISE EXCEPTION 'Acceso denegado: se requiere rol admin'; END IF;
    SELECT array_agg(sucursal_id) INTO v_asignadas FROM usuario_sucursales WHERE usuario_id = auth.uid();
    IF v_asignadas IS NULL THEN RAISE EXCEPTION 'Acceso denegado: el usuario no tiene sucursales asignadas'; END IF;
  END IF;
  IF p_sucursal_id IS NULL THEN
    SELECT array_agg(id) INTO v_sucursales FROM sucursales WHERE activa;
    IF NOT v_es_servicio THEN
      SELECT array_agg(s) INTO v_sucursales FROM unnest(v_sucursales) AS s WHERE s = ANY(v_asignadas); END IF;
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id; END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;
  IF v_sucursales IS NULL OR array_length(v_sucursales,1) IS NULL THEN
    RETURN '[]'::jsonb; END IF;

  IF p_codigo = 'cobranza_vencida' THEN
    -- Sin filtro de periodo a proposito: la alerta es contra CURRENT_DATE - 30.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             SUM(p.total - COALESCE(p.monto_pagado,0)) AS valor,
             'hace ' || MAX(CURRENT_DATE - p.fecha) || ' días' AS detalle
      FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
      WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
        AND COALESCE(p.estado_pago,'pendiente') IN ('pendiente','parcial')
        AND p.fecha < CURRENT_DATE - 30 AND p.total > COALESCE(p.monto_pagado,0)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      ORDER BY valor DESC
      LIMIT 100
    ) t;
  ELSIF p_codigo = 'clientes_inactivos' THEN
    -- Idem: la alerta es contra CURRENT_DATE - 30/90.
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC NULLS LAST), '[]')
      INTO v_result FROM (
      SELECT COALESCE(NULLIF(c.nombre_fantasia,''), c.razon_social) AS nombre,
             COALESCE(SUM(p.total) FILTER (WHERE p.fecha >= CURRENT_DATE - 90), 0) AS valor,
             'sin comprar hace ' || (CURRENT_DATE - MAX(p.fecha)) || ' días' AS detalle
      FROM pedidos p JOIN clientes c ON c.id = p.cliente_id
      WHERE p.estado='entregado' AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
      GROUP BY c.id, c.nombre_fantasia, c.razon_social
      HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90
      ORDER BY valor DESC NULLS LAST
      LIMIT 200
    ) t;
  ELSIF p_codigo = 'productos_sin_costo' THEN
    -- Mismo periodo, mismos estados, mismo canal y mismo predicado que el KPI
    -- `ingreso_sin_costo`: la suma de esta lista ES ese numero (mientras no la
    -- trunque el LIMIT, que por eso ahora ordena antes de cortar).
    SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', nombre, 'valor', valor, 'detalle', detalle) ORDER BY valor DESC), '[]')
      INTO v_result FROM (
      SELECT prod.nombre AS nombre, SUM(pi.subtotal) AS valor, 'sin costo cargado' AS detalle
      FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id JOIN productos prod ON prod.id = pi.producto_id
      WHERE p.estado = ANY(v_estados) AND p.canal='app' AND p.sucursal_id = ANY(v_sucursales)
        AND (p_desde IS NULL OR p.fecha >= p_desde)
        AND (p_hasta IS NULL OR p.fecha <= p_hasta)
        AND NOT pi.es_bonificacion
        AND public.costo_valuacion(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
                                   prod.costo_sin_iva, prod.impuestos_internos) IS NULL
      GROUP BY prod.id, prod.nombre
      ORDER BY valor DESC
      LIMIT 100
    ) t;
  ELSE
    v_result := '[]'::jsonb;
  END IF;

  RETURN COALESCE(v_result, '[]'::jsonb);
END;
$function$;

COMMENT ON FUNCTION public.reporte_alerta_detalle(bigint, text, date, date, boolean) IS
  'Lista concreta detras de una alerta del gerencial. productos_sin_costo usa el '
  'MISMO periodo, estados y predicado (costo_valuacion() IS NULL) que el KPI '
  'ingreso_sin_costo, asi la lista cuadra. Las otras dos alertas son contra '
  'CURRENT_DATE y por eso ignoran p_desde/p_hasta. migs 109 y 238 (#511).';

ALTER FUNCTION public.reporte_alerta_detalle(bigint, text, date, date, boolean) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.reporte_alerta_detalle(bigint, text, date, date, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_alerta_detalle(bigint, text, date, date, boolean) TO authenticated, service_role;

-- ===========================================================================
-- 6 · check_promo_limite_usos: el limite cuenta USOS, no subunidades (D-8)
-- ===========================================================================
-- `usos_pendientes` dejo de ser un contador de usos en las migs 220/221: para las
-- promos CON fraccion (`regalo_mueve_stock = false`) es el resto de la barra en
-- [0, N), y `crear_pedido_completo` lo sube en SUBUNIDADES antes de que el
-- auto-ajuste lo baje a ese resto. El trigger miraba el pico intermedio.
--
-- Se acota a las promos SIN fraccion, donde `usos_pendientes` sigue contando lo
-- que el nombre dice y el limite sigue significando lo que significaba. Para las
-- promos con fraccion el limite por usos no esta implementado: el tope real es el
-- stock del producto de ajuste, que el auto-ajuste ya verifica y que hace fallar
-- el pedido con "stock insuficiente".
--
-- Funcion de trigger: NO necesita EXECUTE para nadie, la invoca el executor como
-- parte del DML. `CREATE OR REPLACE` preserva la ACL que ya tiene
-- (postgres + service_role), asi que no se toca.

CREATE OR REPLACE FUNCTION public.check_promo_limite_usos()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.regalo_mueve_stock
     AND NEW.limite_usos IS NOT NULL
     AND NEW.usos_pendientes >= NEW.limite_usos
     AND NEW.activo = true THEN
    NEW.activo := false;
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.check_promo_limite_usos() IS
  'Apaga la promo al llegar al limite de usos. Solo para promos SIN fraccion '
  '(regalo_mueve_stock): en las de fraccion usos_pendientes es el RESTO de la barra '
  'y crear_pedido_completo lo sube en subunidades antes del auto-ajuste, asi que una '
  'sola boleta grande disparaba el limite en el pico intermedio. mig 238 (D-8).';

-- ===========================================================================
-- 7 · Permisos de las cuatro funciones nuevas
-- ===========================================================================
-- Una funcion nueva de `public` no nace solo con EXECUTE para PUBLIC y `anon`:
-- Supabase ademas se lo concede a `authenticated` por default privileges, y
-- `GRANT TO authenticated` no revierte nada (MANIFEST, mig 237). Las cuatro se
-- revocan por las TRES mitades: el front no llama a ninguna --las llaman las
-- SECURITY DEFINER de `postgres`, que corren como su owner-- y `mermas_valorizadas`
-- ademas recibe el array de sucursales sin validar. `service_role` si, que es con
-- lo que corre el gate de CI (`scripts/check-integridad.mjs`).

ALTER FUNCTION public.costo_valuacion(numeric, numeric, numeric, numeric, numeric)     OWNER TO postgres;
ALTER FUNCTION public.costo_valuacion_origen(numeric, numeric, numeric, numeric)       OWNER TO postgres;
ALTER FUNCTION public.merma_clasificacion(text)                                        OWNER TO postgres;
ALTER FUNCTION public.mermas_valorizadas(date, date, bigint[])                          OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.costo_valuacion(numeric, numeric, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.costo_valuacion(numeric, numeric, numeric, numeric, numeric) TO service_role;

REVOKE ALL    ON FUNCTION public.costo_valuacion_origen(numeric, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.costo_valuacion_origen(numeric, numeric, numeric, numeric) TO service_role;

REVOKE ALL    ON FUNCTION public.merma_clasificacion(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merma_clasificacion(text) TO service_role;

REVOKE ALL    ON FUNCTION public.mermas_valorizadas(date, date, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mermas_valorizadas(date, date, bigint[]) TO service_role;

-- ===========================================================================
-- 8 · Verificacion estatica: una firma por funcion y ACLs como corresponde
-- ===========================================================================

DO $verif$
DECLARE
  v_acl    text;
  v_n      int;
  v_fallas text := '';
  r        record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('costo_valuacion',         false),
      ('costo_valuacion_origen',  false),
      ('merma_clasificacion',     false),
      ('mermas_valorizadas',      false),
      ('reporte_alerta_detalle',  true),
      ('reporte_gerencial',       true),
      ('reporte_mermas',          true)
    ) AS t(fn, la_llama_el_front)
  LOOP
    SELECT count(*) INTO v_n
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;

    -- Dos sobrecargas con rangos [obligatorios, total] superpuestos hacen que
    -- PostgREST tire PGRST203 en runtime, invisible para tsc y para los tests.
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format(' [%s quedo con %s firmas]', r.fn, v_n);
      CONTINUE;
    END IF;

    SELECT array_to_string(proacl, ',') INTO v_acl
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;

    IF v_acl IS NULL THEN
      v_fallas := v_fallas || format(' [%s quedo con ACL default (PUBLIC ejecuta)]', r.fn);
    ELSIF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
      v_fallas := v_fallas || format(' [%s quedo ejecutable por PUBLIC: %s]', r.fn, v_acl);
    ELSIF v_acl LIKE '%anon=%' THEN
      v_fallas := v_fallas || format(' [%s quedo ejecutable por anon: %s]', r.fn, v_acl);
    END IF;

    IF v_acl NOT LIKE '%service_role=X%' THEN
      v_fallas := v_fallas || format(' [%s no quedo ejecutable por service_role: %s]', r.fn, v_acl);
    END IF;

    IF r.la_llama_el_front AND v_acl NOT LIKE '%authenticated=X%' THEN
      v_fallas := v_fallas || format(' [%s no quedo ejecutable por authenticated: %s]', r.fn, v_acl);
    END IF;
    IF NOT r.la_llama_el_front AND v_acl LIKE '%authenticated=X%' THEN
      v_fallas := v_fallas || format(' [%s quedo ejecutable por authenticated: %s]', r.fn, v_acl);
    END IF;
  END LOOP;

  -- La firma vieja de 2 argumentos tiene que haber desaparecido.
  IF EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'reporte_alerta_detalle' AND p.pronargs = 2
  ) THEN
    v_fallas := v_fallas || ' [reporte_alerta_detalle(bigint,text) sigue viva: PGRST203 asegurado]';
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig238 · verificacion estatica:%', v_fallas;
  END IF;
  RAISE NOTICE 'mig238 · verificacion estatica OK';
END
$verif$;

-- ===========================================================================
-- 9 · ENSAYO FUNCIONAL
-- ===========================================================================
-- Corre contra las funciones que se acaban de escribir, adentro de una
-- subtransaccion que se revierte SIEMPRE (el bloque EXCEPTION de plpgsql). Mide
-- tres cosas que ningun test de vitest puede medir, porque viven en SQL:
--
--   A. La cascada sobre casos fijos --los 25 que se perdieron cuando se borro
--      `valorizacionMermas.test.ts` con el modulo TS (#572)-- mas la grilla de 81
--      combinaciones que verifica la coherencia entre `costo_valuacion()` y
--      `costo_valuacion_origen()`.
--   B. Filas de merma sinteticas: clasificacion, cascada con costo_promedio y sin
--      costo_sin_iva (el caso de #511), cantidad negativa, y el cruce
--      `reporte_mermas.totales.costo == reporte_gerencial.kpis.mermas` CON esas
--      filas adentro, que es cuando el cruce significa algo.
--   C. El trigger del limite de usos: 392 subunidades de regalo NO apagan una promo
--      con fraccion y limite 100; 100 usos SI apagan una sin fraccion (D-8).

DO $ensayo$
DECLARE
  v_fallas  text := '';
  v_notas   text := '';
  v_suc     bigint;
  v_prod    bigint;
  v_promo_f bigint;   -- con fraccion
  v_promo_s bigint;   -- sin fraccion
  v_desde   date;
  v_hasta   date;
  v_ger     numeric;
  v_mer     numeric;
  v_n       int;
  r         record;
  v_row     record;
BEGIN
  BEGIN
    -- ---------------------------------------------------------------------
    -- A · La cascada, sobre casos fijos
    -- ---------------------------------------------------------------------
    FOR r IN
      SELECT * FROM (VALUES
        ('snapshot gana sobre todo',        200::numeric, 120::numeric, 90::numeric, 50::numeric, 10::numeric, 200::numeric, 'congelado'),
        ('snapshot cero igual gana',          0,          120,          90,          50,          10,            0,          'congelado'),
        ('promedio gana sobre real',       NULL,          120,          90,          50,          10,          120,          'estimado'),
        ('real cuando no hay promedio',    NULL,         NULL,          90,          50,          10,           90,          'estimado'),
        ('formula con ii',                 NULL,         NULL,        NULL,          50,          10,           55,          'estimado'),
        ('formula sin ii',                 NULL,         NULL,        NULL,          50,           0,           50,          'estimado'),
        ('formula con ii NULL',            NULL,         NULL,        NULL,          50,        NULL,           50,          'estimado'),
        -- #511: costo_promedio cargado y costo_sin_iva en NULL NO es sin_costo.
        ('promedio solo (caso #511)',      NULL,          120,        NULL,        NULL,        NULL,          120,          'estimado'),
        ('real solo, sin_iva en cero',     NULL,         NULL,          90,           0,          10,           90,          'estimado'),
        -- El NULLIF: un cero en costo_sin_iva no es un costo.
        ('sin_iva cero => sin costo',      NULL,         NULL,        NULL,           0,          10,         NULL,          'sin_costo'),
        ('todo NULL => sin costo',         NULL,         NULL,        NULL,        NULL,          10,         NULL,          'sin_costo'),
        -- Edge documentado a proposito: el NULLIF va SOLO en costo_sin_iva, que es
        -- la decision del issue. Un cero en costo_promedio SI se toma como costo.
        ('promedio cero se toma',          NULL,            0,          90,          50,          10,            0,          'estimado')
      ) AS t(caso, snap, prom, rea, siva, ii, esp_costo, esp_origen)
    LOOP
      IF public.costo_valuacion(r.snap, r.prom, r.rea, r.siva, r.ii) IS DISTINCT FROM r.esp_costo THEN
        v_fallas := v_fallas || format(' [costo_valuacion/%s: esperaba %s, dio %s]',
          r.caso, COALESCE(r.esp_costo::text,'NULL'),
          COALESCE(public.costo_valuacion(r.snap, r.prom, r.rea, r.siva, r.ii)::text,'NULL'));
      END IF;
      IF public.costo_valuacion_origen(r.snap, r.prom, r.rea, r.siva) IS DISTINCT FROM r.esp_origen THEN
        v_fallas := v_fallas || format(' [costo_valuacion_origen/%s: esperaba %s, dio %s]',
          r.caso, r.esp_origen, public.costo_valuacion_origen(r.snap, r.prom, r.rea, r.siva));
      END IF;
    END LOOP;

    -- Coherencia: costo NULL <=> origen sin_costo. 81 combinaciones.
    SELECT count(*) INTO v_n FROM (
      SELECT s.v AS snap, p.v AS prom, x.v AS rea, c.v AS siva
        FROM (VALUES (NULL::numeric),(0),(7)) s(v),
             (VALUES (NULL::numeric),(0),(7)) p(v),
             (VALUES (NULL::numeric),(0),(7)) x(v),
             (VALUES (NULL::numeric),(0),(7)) c(v)
    ) g
    WHERE (public.costo_valuacion(g.snap, g.prom, g.rea, g.siva, 10) IS NULL)
       <> (public.costo_valuacion_origen(g.snap, g.prom, g.rea, g.siva) = 'sin_costo');
    IF v_n <> 0 THEN
      v_fallas := v_fallas || format(' [costo_valuacion y costo_valuacion_origen no coinciden en %s de 81 combinaciones]', v_n);
    END IF;

    -- La clasificacion, los diez motivos del CHECK vivo mas el vacio.
    FOR r IN
      SELECT * FROM (VALUES
        ('vencimiento','perdida'), ('rotura','perdida'), ('robo','perdida'),
        ('decomiso','perdida'),    ('devolucion','perdida'),
        ('muestra','muestra'),
        ('error_inventario','ajuste'), ('otro','ajuste'), ('','ajuste'), (NULL,'ajuste'),
        ('promociones','promocion'), ('promociones_reversion','promocion')
      ) AS t(motivo, esperado)
    LOOP
      IF public.merma_clasificacion(r.motivo) IS DISTINCT FROM r.esperado THEN
        v_fallas := v_fallas || format(' [merma_clasificacion(%s): esperaba %s, dio %s]',
          COALESCE(r.motivo,'NULL'), r.esperado, public.merma_clasificacion(r.motivo));
      END IF;
    END LOOP;

    v_notas := v_notas || ' cascada+clasificacion OK;';

    -- ---------------------------------------------------------------------
    -- B · Filas de merma sinteticas
    -- ---------------------------------------------------------------------
    SELECT id INTO v_suc FROM sucursales WHERE activa ORDER BY id LIMIT 1;
    IF v_suc IS NULL THEN
      RAISE EXCEPTION 'mig238: no hay ninguna sucursal activa; el ensayo no puede correr.';
    END IF;

    -- El producto del caso #511: costo_promedio cargado, costo_sin_iva en NULL.
    INSERT INTO productos (nombre, precio, stock, sucursal_id, categoria,
                           costo_promedio, costo_real, costo_sin_iva, impuestos_internos)
    VALUES ('ZZ ensayo mig238', 500, 0, v_suc, '(ensayo mig238)', 100, NULL, NULL, 0)
    RETURNING id INTO v_prod;

    -- El trigger BEFORE INSERT `trg_mermas_snapshot_costo` congela el costo, asi
    -- que estas cuatro nacen 'congelado'. La de rotura se des-congela abajo para
    -- ejercitar la pata 'estimado' de la cascada.
    INSERT INTO mermas_stock (producto_id, cantidad, motivo, stock_anterior, stock_nuevo, sucursal_id)
    VALUES (v_prod,  10, 'rotura',           100,  90, v_suc),
           (v_prod,   3, 'muestra',           90,  87, v_suc),
           (v_prod,  -5, 'error_inventario',  87,  92, v_suc),   -- cantidad NEGATIVA
           (v_prod,   7, 'promociones',       92,  85, v_suc);

    UPDATE mermas_stock SET costo_unitario = NULL
     WHERE producto_id = v_prod AND motivo = 'rotura';

    v_hasta := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
    v_desde := date_trunc('month', v_hasta)::date;

    FOR v_row IN
      SELECT * FROM public.mermas_valorizadas(v_desde, v_hasta, ARRAY[v_suc])
       WHERE producto_id = v_prod
    LOOP
      -- El caso #511 en una fila de verdad: sin costo_sin_iva pero con promedio,
      -- la cascada lo encuentra y la fila NO es 'sin_costo'.
      IF v_row.motivo = 'rotura' THEN
        IF v_row.origen_costo <> 'estimado' THEN
          v_fallas := v_fallas || format(' [rotura sin snapshot: esperaba origen estimado, dio %s]', v_row.origen_costo);
        END IF;
        IF v_row.costo_unitario IS DISTINCT FROM 100 THEN
          v_fallas := v_fallas || format(' [rotura: esperaba costo 100 del promedio, dio %s]', COALESCE(v_row.costo_unitario::text,'NULL'));
        END IF;
        IF v_row.clasificacion <> 'perdida' THEN
          v_fallas := v_fallas || format(' [rotura: esperaba clasificacion perdida, dio %s]', v_row.clasificacion);
        END IF;
      ELSIF v_row.motivo = 'muestra' THEN
        IF v_row.clasificacion <> 'muestra' OR v_row.origen_costo <> 'congelado' THEN
          v_fallas := v_fallas || format(' [muestra: dio clasificacion %s / origen %s]', v_row.clasificacion, v_row.origen_costo);
        END IF;
      ELSIF v_row.motivo = 'error_inventario' THEN
        -- Una cantidad negativa DEVUELVE costo: el total tiene que bajar, no subir.
        IF v_row.clasificacion <> 'ajuste' THEN
          v_fallas := v_fallas || format(' [error_inventario: esperaba ajuste, dio %s]', v_row.clasificacion);
        END IF;
        IF v_row.costo_total IS DISTINCT FROM -500 THEN
          v_fallas := v_fallas || format(' [cantidad negativa: esperaba costo_total -500, dio %s]', COALESCE(v_row.costo_total::text,'NULL'));
        END IF;
      ELSIF v_row.motivo = 'promociones' THEN
        IF v_row.clasificacion <> 'promocion' THEN
          v_fallas := v_fallas || format(' [promociones: esperaba clasificacion promocion, dio %s]', v_row.clasificacion);
        END IF;
      END IF;

      IF v_row.costo_total IS DISTINCT FROM v_row.cantidad * v_row.costo_unitario THEN
        v_fallas := v_fallas || format(' [fila %s: costo_total no es cantidad*costo_unitario]', v_row.id);
      END IF;
      IF v_row.fecha_local <> v_hasta THEN
        v_fallas := v_fallas || format(' [fila %s: fecha_local %s no es el dia argentino de hoy]', v_row.id, v_row.fecha_local);
      END IF;
    END LOOP;

    -- Las cuatro filas tienen que estar, y solo las tres que no son de promocion
    -- tienen que contar para el total.
    SELECT count(*) INTO v_n FROM public.mermas_valorizadas(v_desde, v_hasta, ARRAY[v_suc]) WHERE producto_id = v_prod;
    IF v_n <> 4 THEN
      v_fallas := v_fallas || format(' [mermas_valorizadas devolvio %s filas del producto de ensayo, esperaba 4]', v_n);
    END IF;

    -- El cruce que justifica todo el diseno, CON las filas sinteticas adentro:
    -- una negativa, una de promocion (que no cuenta) y dos normales.
    v_ger := (public.reporte_gerencial(v_suc, v_desde, v_hasta)->'kpis'->>'mermas')::numeric;
    v_mer := (public.reporte_mermas(v_desde, v_hasta, v_suc)->'totales'->>'costo')::numeric;
    IF v_ger IS DISTINCT FROM v_mer THEN
      v_fallas := v_fallas || format(' [el cruce no cierra con filas sinteticas: gerencial %s vs mermas %s]', v_ger, v_mer);
    END IF;

    -- Y la de promocion tiene que estar informada aparte, fuera del total.
    SELECT (public.reporte_mermas(v_desde, v_hasta, v_suc)->'totales'->>'costo_ajuste_promocion')::numeric INTO v_mer;
    IF COALESCE(v_mer, 0) <= 0 THEN
      v_fallas := v_fallas || ' [la merma de promocion no aparece en costo_ajuste_promocion]';
    END IF;

    v_notas := v_notas || ' filas de merma OK;';

    -- ---------------------------------------------------------------------
    -- C · El trigger del limite de usos (D-8)
    -- ---------------------------------------------------------------------
    -- Con fraccion: `usos_pendientes` es el resto de la barra y el bump llega en
    -- subunidades. 392 >= 100 NO puede apagarla.
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, activo,
                             limite_usos, usos_pendientes, regalo_mueve_stock, unidades_por_bloque)
    VALUES ('ZZ ensayo mig238 con fraccion', 'bonificacion', CURRENT_DATE, v_suc, true,
            100, 0, false, 6)
    RETURNING id INTO v_promo_f;

    UPDATE promociones SET usos_pendientes = usos_pendientes + 392 WHERE id = v_promo_f;
    SELECT (activo)::int INTO v_n FROM promociones WHERE id = v_promo_f;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || ' [una boleta de 392 subunidades apago una promo con fraccion y limite 100]';
    END IF;

    -- Y despues del auto-ajuste, que la deja en el resto, sigue viva.
    UPDATE promociones SET usos_pendientes = 2 WHERE id = v_promo_f;
    SELECT (activo)::int INTO v_n FROM promociones WHERE id = v_promo_f;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || ' [la promo con fraccion quedo apagada despues del auto-ajuste]';
    END IF;

    -- Sin fraccion: el limite sigue significando lo que siempre significo.
    INSERT INTO promociones (nombre, tipo, fecha_inicio, sucursal_id, activo,
                             limite_usos, usos_pendientes, regalo_mueve_stock)
    VALUES ('ZZ ensayo mig238 sin fraccion', 'bonificacion', CURRENT_DATE, v_suc, true,
            100, 0, true)
    RETURNING id INTO v_promo_s;

    UPDATE promociones SET usos_pendientes = 99 WHERE id = v_promo_s;
    SELECT (activo)::int INTO v_n FROM promociones WHERE id = v_promo_s;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || ' [la promo sin fraccion se apago antes de llegar al limite]';
    END IF;

    UPDATE promociones SET usos_pendientes = 100 WHERE id = v_promo_s;
    SELECT (activo)::int INTO v_n FROM promociones WHERE id = v_promo_s;
    IF v_n <> 0 THEN
      v_fallas := v_fallas || ' [la promo sin fraccion NO se apago al llegar al limite: se rompio el caso que el trigger si cubre]';
    END IF;

    v_notas := v_notas || ' limite de usos OK;';

    -- Todo lo de arriba se revierte aca. La subtransaccion del bloque EXCEPTION
    -- deshace los INSERT/UPDATE; los NOTICE ya emitidos no son transaccionales.
    RAISE EXCEPTION 'mig238_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig238_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig238 · el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig238 · el ensayo funcional encontro:%', v_fallas;
  END IF;
  RAISE NOTICE 'mig238 · ensayo funcional OK:%', v_notas;
END
$ensayo$;

-- ===========================================================================
-- 10 · El cruce sobre los datos REALES, sin tocar nada
-- ===========================================================================
-- Tres periodos x (las dos sucursales activas + la Red). Es la misma comparacion
-- que queda corriendo todos los dias en `scripts/check-integridad.mjs`; aca se
-- corre una vez mas, antes de que la migracion se de por aplicada.

DO $cruce$
DECLARE
  v_fallas text := '';
  v_n      int := 0;
  r        record;
  v_ger    numeric;
  v_mer    numeric;
BEGIN
  FOR r IN
    SELECT p.etiqueta, p.d, p.h, s.sid, COALESCE(s.snom, 'Red') AS snom
      FROM (VALUES
        ('mes corriente', date_trunc('month', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires'))::date,
                          (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date),
        ('mes anterior',  (date_trunc('month', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')) - interval '1 month')::date,
                          (date_trunc('month', (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')) - interval '1 day')::date),
        ('ultimos 12 meses', ((now() AT TIME ZONE 'America/Argentina/Buenos_Aires') - interval '12 months')::date,
                          (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)
      ) AS p(etiqueta, d, h)
      CROSS JOIN (
        SELECT id AS sid, nombre AS snom FROM sucursales WHERE activa
        UNION ALL SELECT NULL::bigint, NULL::text
      ) s
  LOOP
    v_ger := (public.reporte_gerencial(r.sid, r.d, r.h)->'kpis'->>'mermas')::numeric;
    v_mer := (public.reporte_mermas(r.d, r.h, r.sid)->'totales'->>'costo')::numeric;
    v_n := v_n + 1;
    IF v_ger IS DISTINCT FROM v_mer THEN
      v_fallas := v_fallas || format(' [%s / %s: gerencial %s vs mermas %s]', r.etiqueta, r.snom, v_ger, v_mer);
    END IF;
  END LOOP;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig238 · el cruce sobre datos reales no cierra:%', v_fallas;
  END IF;
  RAISE NOTICE 'mig238 · cruce sobre datos reales OK en % combinaciones', v_n;
END
$cruce$;

COMMIT;

-- ROLLBACK (si hiciera falta):
--   Las tres reescrituras vuelven con el texto de las migs 130 (mas la 227),
--   226 y 109 respectivamente, y el trigger con el del baseline. Las cuatro
--   funciones nuevas son aditivas:
--     DROP FUNCTION IF EXISTS public.mermas_valorizadas(date, date, bigint[]);
--     DROP FUNCTION IF EXISTS public.merma_clasificacion(text);
--     DROP FUNCTION IF EXISTS public.costo_valuacion_origen(numeric, numeric, numeric, numeric);
--     DROP FUNCTION IF EXISTS public.costo_valuacion(numeric, numeric, numeric, numeric, numeric);
--   Ojo con `reporte_alerta_detalle`: volver a la firma de 2 argumentos exige
--   dropear la de 5 en la MISMA transaccion, o quedan las dos y PostgREST tira
--   PGRST203.
