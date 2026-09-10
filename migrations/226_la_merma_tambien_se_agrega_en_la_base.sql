-- La merma tambien se agrega en la base
--
-- EL PROBLEMA
-- -----------
-- El gasto en mermas se podia ver en dos lados y en ninguno completo:
--
--   1. El gerencial devuelve `mermas_motivo[]` desde la mig 110, y ese array
--      NO se renderiza en ninguna pantalla: sale unicamente adentro del Excel.
--      El desglose ya estaba pago y era invisible.
--   2. ModalHistorialMermas bajaba las filas crudas por PostgREST y sumaba en
--      el navegador. La policy `mt_mermas_stock_select` lo ata a
--      `current_sucursal_id()`, asi que NO podia consolidar la red; y el corte
--      de 1.000 filas alimentaba los totales, o sea que truncar cambiaba los
--      numeros EN SILENCIO.
--
-- Este es el mismo camino que ya se recorrio en `reporte_ventas_por_cliente`
-- (197), `reporte_valuacion_inventario` (131) y los tres de la 208: que la base
-- devuelva la agregacion en vez de las filas.
--
-- LO QUE TIENE QUE CERRAR
-- -----------------------
-- La invariante que justifica todo el diseño:
--
--     reporte_mermas(d,h,s).totales.costo == reporte_gerencial(s,d,h).kpis.mermas
--
-- Por eso la cascada de costo, el corte del dia argentino y la exclusion de
-- promociones se copian VERBATIM de la 130 (verificado contra el cuerpo vivo de
-- `reporte_gerencial` el 2026-09-09: los CTEs `k_merma` y `mermas_motivo` son
-- identicos byte a byte). En particular la 130 NO redondea el costo unitario
-- --`reporte_rentabilidad` de la 208 si lo hace-- y redondear aca romperia el
-- cruce sin que falle nada.
--
-- LA CLASIFICACION TIENE CUATRO VALORES, NO TRES
-- ----------------------------------------------
-- El gerencial excluye `promociones`/`promociones_reversion` en el WHERE: son la
-- contrapartida de un regalo ya contabilizado como bonificacion, y contarlas
-- infla el total ~4x. Aca esas filas ENTRAN a la consulta pero quedan fuera de
-- `totales.costo`, bajo la clasificacion 'promocion'. Asi la pantalla puede
-- decir cuanto son y por que no cuentan, en vez de que el cliente lo re-derive.
--
-- NO SE TOCA NINGUNA TABLA. Es una funcion de lectura nueva.

BEGIN;

-- Una sola firma viva: dos sobrecargas con rangos [obligatorios, total]
-- superpuestos hacen que PostgREST tire PGRST203 en runtime, invisible para tsc
-- y para los tests (CLAUDE.md, trampa 5).
DROP FUNCTION IF EXISTS public.reporte_mermas(date, date, bigint, text, integer);

CREATE FUNCTION public.reporte_mermas(
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
  -- de la 208 (todas las sucursales). Este reporte tiene que cerrar exacto
  -- contra kpis.mermas: si "Red" resuelve a conjuntos distintos, los dos numeros
  -- difieren y nadie sabe cual esta mal.
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

  WITH base AS (
    SELECT
      m.id, m.created_at, m.cantidad, m.observaciones,
      m.stock_anterior, m.stock_nuevo, m.usuario_id, m.sucursal_id, m.producto_id,
      COALESCE(NULLIF(m.motivo, ''), '(sin motivo)') AS motivo,
      CASE
        WHEN COALESCE(m.motivo, '') IN ('promociones', 'promociones_reversion') THEN 'promocion'
        WHEN m.motivo IN ('vencimiento', 'rotura', 'robo', 'decomiso', 'devolucion') THEN 'perdida'
        WHEN m.motivo = 'muestra' THEN 'muestra'
        ELSE 'ajuste'
      END AS clasificacion,
      -- Cascada canonica, verbatim de la 130. Sin ROUND: ver cabecera.
      COALESCE(m.costo_unitario, prod.costo_promedio, prod.costo_real,
               prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos, 0) / 100)) AS costo_unitario,
      -- Espejo SQL de valorizarMerma(): de donde salio el costo de esta fila.
      CASE
        WHEN m.costo_unitario IS NOT NULL THEN 'congelado'
        WHEN COALESCE(prod.costo_promedio, prod.costo_real, prod.costo_sin_iva) IS NULL THEN 'sin_costo'
        ELSE 'estimado'
      END AS origen_costo,
      prod.nombre AS producto_nombre,
      prod.codigo AS producto_codigo,
      prod.categoria AS producto_categoria,
      prod.precio AS precio_unitario
    FROM mermas_stock m
    JOIN productos prod ON prod.id = m.producto_id
    WHERE m.sucursal_id = ANY(v_sucursales)
      AND (m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
      AND (p_motivo IS NULL OR COALESCE(NULLIF(m.motivo, ''), '(sin motivo)') = p_motivo)
  ),
  calc AS (
    SELECT b.*,
           b.cantidad * b.costo_unitario  AS costo_total,
           b.cantidad * b.precio_unitario AS precio_total
    FROM base b
  ),
  -- Los totales y el corte por motivo se calculan sobre el CTE COMPLETO. Solo el
  -- detalle lleva LIMIT: truncar acorta la lista, nunca mueve un total. Ese era
  -- el defecto del modal.
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
      'criterio', 'Mermas por dia argentino de carga (created_at), valuadas al costo congelado al momento de la merma (mig 119); las anteriores al snapshot van al costo de hoy. El total EXCLUYE promociones y reversion de promocion: no son perdida, son la contrapartida de un regalo ya contabilizado como bonificacion. Mismo criterio que reporte_gerencial (mig 130), con el que cierra exacto. El precio de venta es el de HOY: la base no guarda a cuanto se vendia el dia de la merma.'
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
  'Mermas agregadas por motivo + detalle acotado. La cascada de costo, el corte '
  'del dia argentino y la exclusion de promociones son verbatim de la mig 130: '
  'totales.costo cierra EXACTO contra reporte_gerencial.kpis.mermas. Si tocas '
  'las mermas en reporte_gerencial, toca tambien esta. mig 226.';

-- ---------------------------------------------------------------------------
-- Permisos. Una SECURITY DEFINER nace ejecutable por PUBLIC y el GRANT a
-- authenticated no lo revierte (gate de CI: scripts/check-permisos.mjs).
-- ---------------------------------------------------------------------------

ALTER FUNCTION public.reporte_mermas(date, date, bigint, text, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reporte_mermas(date, date, bigint, text, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reporte_mermas(date, date, bigint, text, integer) TO authenticated, service_role;

DO $verif$
DECLARE
  v_acl text;
BEGIN
  SELECT array_to_string(proacl, ',') INTO v_acl
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'reporte_mermas';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'reporte_mermas quedo con ACL default (PUBLIC ejecuta)';
  END IF;
  IF v_acl LIKE '=X/%' OR v_acl LIKE '%,=X/%' THEN
    RAISE EXCEPTION 'reporte_mermas quedo ejecutable por PUBLIC: %', v_acl;
  END IF;
  IF v_acl LIKE '%anon=%' THEN
    RAISE EXCEPTION 'reporte_mermas quedo ejecutable por anon: %', v_acl;
  END IF;
  IF v_acl NOT LIKE '%authenticated=X%' THEN
    RAISE EXCEPTION 'reporte_mermas no quedo ejecutable por authenticated: %', v_acl;
  END IF;
END
$verif$;

COMMIT;

-- ROLLBACK (si hiciera falta):
--   DROP FUNCTION IF EXISTS public.reporte_mermas(date, date, bigint, text, integer);
-- La funcion es aditiva: no reemplaza nada. El front vuelve solo revirtiendo el commit.
