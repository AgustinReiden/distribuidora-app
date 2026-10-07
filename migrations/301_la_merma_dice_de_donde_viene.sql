-- La merma dice de dónde viene (#847, pedido del dueño del 07/10)
--
-- Desde la 297 el faltante de una entrega con salvedad deja una merma
-- 'error_inventario'. El reporte de mermas la sumaba bien pero la MEZCLABA: el
-- corte por motivo junta bajo "Error inventario" tres cosas distintas,
--
--   · el faltante de una entrega con salvedad (297),
--   · la cancelacion de un pedido entero por falta de stock (269),
--   · el ajuste cargado a mano en Mermas (y otros caminos directos: baja de
--     lote, cambio de producto).
--
-- Ahora cada fila de `mermas_valorizadas` trae `procedencia`, y `reporte_mermas`
-- agrega el corte `por_procedencia` (procedencia × motivo). El TOTAL no se mueve:
-- es otra forma de partir las mismas filas, y por eso `totales.costo ==
-- kpis.mermas` sigue cerrando por construccion. El gate check-integridad.mjs
-- exige ademas que `por_procedencia` sume el total.
--
-- COMO SE DECIDE (merma_procedencia)
--
--   1. motivo promociones / promociones_reversion -> 'promocion'. Gana sobre
--      todo: es lo que queda FUERA del total, igual que en merma_clasificacion.
--   2. salvedad_id no nulo -> 'entrega_salvedad'. El vinculo es una columna
--      (mig 244), no un texto.
--   3. observaciones que empiezan con 'Cancelacion por falta de stock, pedido #'
--      -> 'cancelacion_falta_stock'. Ese texto lo escribe el CODIGO de
--      cancelar_pedido_con_stock (269), nunca una persona, y no hay columna que
--      vincule la merma al pedido. Es la debilidad de esta clasificacion: si
--      alguien cambia ese texto, la cancelacion pasaria a 'carga_directa' sin que
--      falle nada. Por eso el $verif$ de abajo exige que el prefijo siga en el
--      cuerpo vivo de cancelar_pedido_con_stock, y el comentario de la funcion lo
--      dice.
--   4. Todo lo demas -> 'carga_directa'.
--
-- Medido antes de aplicar (todas las filas de mermas_stock): 967 de promocion, 55
-- de entrega con salvedad (39 faltantes, 10 roturas, 6 vencimientos), 1 de
-- cancelacion por falta de stock y 119 de carga directa.
--
-- PERMISOS. `mermas_valorizadas` cambia de forma (una columna mas), asi que va
-- DROP + CREATE: CREATE OR REPLACE no puede cambiar un RETURNS TABLE. No tiene
-- dependientes registrados (sus dos llamadores son plpgsql). Se restauran los
-- permisos que tenia --postgres y service_role, nadie mas: el gate la llama con
-- la service_role key-- y `merma_procedencia` nace igual que
-- `merma_clasificacion`. Ninguna de las dos la llama el frontend, asi que se
-- revocan a las TRES (CLAUDE.md: funcion de server).

-- ---------------------------------------------------------------------------
-- 1. El criterio de procedencia, en una funcion pura
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.merma_procedencia(p_salvedad_id bigint, p_motivo text, p_observaciones text)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
SET search_path TO 'public'
AS $function$
  -- El prefijo de la cancelacion lo escribe cancelar_pedido_con_stock (mig 269).
  -- Si se cambia ese texto, hay que cambiarlo aca (el $verif$ de la 301 lo cuida).
  SELECT CASE
    WHEN COALESCE(p_motivo, '') IN ('promociones', 'promociones_reversion')        THEN 'promocion'
    WHEN p_salvedad_id IS NOT NULL                                               THEN 'entrega_salvedad'
    WHEN p_observaciones LIKE 'Cancelacion por falta de stock, pedido #%'        THEN 'cancelacion_falta_stock'
    ELSE 'carga_directa'
  END;
$function$;

REVOKE ALL ON FUNCTION public.merma_procedencia(bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merma_procedencia(bigint, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. mermas_valorizadas: el mismo cuerpo de la 244 + la columna procedencia
-- ---------------------------------------------------------------------------
DROP FUNCTION public.mermas_valorizadas(date, date, bigint[]);

CREATE FUNCTION public.mermas_valorizadas(p_desde date, p_hasta date, p_sucursales bigint[])
 RETURNS TABLE(id bigint, created_at timestamp with time zone, fecha_local date, sucursal_id bigint, usuario_id uuid, producto_id bigint, producto_nombre text, producto_codigo text, producto_categoria text, motivo text, clasificacion text, cantidad integer, costo_unitario numeric, costo_total numeric, precio_unitario numeric, precio_total numeric, origen_costo text, observaciones text, stock_anterior integer, stock_nuevo integer, procedencia text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
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
    m.stock_nuevo,
    -- mig 301 (#847): de donde vino la merma. Otro eje que el motivo.
    public.merma_procedencia(m.salvedad_id, m.motivo, m.observaciones)           AS procedencia
  FROM mermas_stock m
  JOIN productos prod ON prod.id = m.producto_id
  WHERE m.sucursal_id = ANY(p_sucursales)
    -- mig 244: la merma de una salvedad anulada no es una merma. La fila queda
    -- en la tabla como asiento; para valorizar, no existe.
    AND m.anulada_at IS NULL
    -- El corte es por DIA ARGENTINO de carga, no por UTC: una merma cargada a las
    -- 22:00 del 31 es del 31, no del 1 del mes siguiente.
    AND (m.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta;
$function$;

REVOKE ALL ON FUNCTION public.mermas_valorizadas(date, date, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mermas_valorizadas(date, date, bigint[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. reporte_mermas: el corte por procedencia. El detalle ya la trae (SELECT *).
-- ---------------------------------------------------------------------------
DO $reporte$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_mermas(date,date,bigint,text,integer)'::regprocedure);
  v_par text[][] := ARRAY[
    ARRAY[$q$  det AS ($q$,
          $q$  -- mig 301 (#847): las MISMAS filas partidas por de donde vinieron. El
  -- faltante de una entrega deja de mezclarse con los ajustes a mano bajo
  -- "Error inventario". Suma lo mismo que por_motivo (lo exige el gate).
  por_procedencia AS (
    SELECT procedencia, motivo, clasificacion,
           COUNT(*)                       AS registros,
           COALESCE(SUM(cantidad), 0)     AS unidades,
           COALESCE(SUM(costo_total), 0)  AS costo,
           COALESCE(SUM(precio_total), 0) AS precio
    FROM calc GROUP BY procedencia, motivo, clasificacion
  ),
  det AS ($q$],
    ARRAY[$q$    'por_motivo', COALESCE((SELECT jsonb_agg(to_jsonb(pm) ORDER BY pm.costo DESC) FROM por_motivo pm), '[]'::jsonb),$q$,
          $q$    'por_motivo', COALESCE((SELECT jsonb_agg(to_jsonb(pm) ORDER BY pm.costo DESC) FROM por_motivo pm), '[]'::jsonb),
    'por_procedencia', COALESCE((SELECT jsonb_agg(to_jsonb(pp) ORDER BY pp.costo DESC) FROM por_procedencia pp), '[]'::jsonb),$q$]
  ];
  v_i int;
BEGIN
  FOR v_i IN 1..array_length(v_par, 1) LOOP
    IF (length(v_def) - length(replace(v_def, v_par[v_i][1], ''))) / length(v_par[v_i][1]) <> 1 THEN
      RAISE EXCEPTION 'reporte_mermas: el fragmento % no aparece exactamente una vez: revisar a mano', v_i;
    END IF;
    v_def := replace(v_def, v_par[v_i][1], v_par[v_i][2]);
  END LOOP;
  EXECUTE v_def;
END
$reporte$;

-- ---------------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  v_caso record;
  v_r    jsonb;
  v_g    jsonb;
  v_suc  bigint;
  v_mes  date;
  v_pp   numeric;
  v_ppp  numeric;
  v_n    int;
BEGIN
  -- (a) Casos fijos del criterio.
  FOR v_caso IN
    SELECT * FROM (VALUES
      (1::bigint,    'error_inventario',      'Salvedad pedido #1: faltante_stock',          'entrega_salvedad'),
      (1::bigint,    'rotura',                NULL,                                          'entrega_salvedad'),
      (NULL::bigint, 'error_inventario',      'Cancelacion por falta de stock, pedido #7',   'cancelacion_falta_stock'),
      (NULL::bigint, 'error_inventario',      'conteo de fin de mes',                        'carga_directa'),
      (NULL::bigint, 'rotura',                NULL,                                          'carga_directa'),
      (NULL::bigint, NULL,                    NULL,                                          'carga_directa'),
      (NULL::bigint, 'promociones',           NULL,                                          'promocion'),
      (NULL::bigint, 'promociones_reversion', 'Cancelacion por falta de stock, pedido #7',   'promocion')
    ) AS t(salv, motivo, obs, esperado)
  LOOP
    IF public.merma_procedencia(v_caso.salv, v_caso.motivo, v_caso.obs) IS DISTINCT FROM v_caso.esperado THEN
      RAISE EXCEPTION 'merma_procedencia(%, %, %) dio % y se esperaba %', v_caso.salv, v_caso.motivo, v_caso.obs,
        public.merma_procedencia(v_caso.salv, v_caso.motivo, v_caso.obs), v_caso.esperado;
    END IF;
  END LOOP;

  -- (b) El prefijo del que depende 'cancelacion_falta_stock' sigue en el cuerpo vivo.
  IF pg_get_functiondef('public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure)
     NOT LIKE '%''Cancelacion por falta de stock, pedido #''%' THEN
    RAISE EXCEPTION 'cancelar_pedido_con_stock ya no escribe el prefijo que reconoce merma_procedencia';
  END IF;

  -- (c) Las filas reales: toda merma con su procedencia, y la del faltante donde va.
  SELECT count(*) INTO v_n
    FROM public.mermas_valorizadas('2000-01-01', '2100-01-01', ARRAY(SELECT id FROM sucursales)) mv
   WHERE mv.procedencia IS NULL
      OR mv.procedencia NOT IN ('entrega_salvedad','cancelacion_falta_stock','carga_directa','promocion');
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% mermas sin procedencia valida', v_n;
  END IF;
  SELECT count(*) INTO v_n
    FROM mermas_stock m
   WHERE m.salvedad_id IS NOT NULL AND m.anulada_at IS NULL
     AND public.merma_procedencia(m.salvedad_id, m.motivo, m.observaciones) <> 'entrega_salvedad';
  IF v_n <> 0 THEN
    RAISE EXCEPTION '% mermas de salvedad que no quedaron como entrega_salvedad', v_n;
  END IF;

  -- (d) El corte suma el total, y el total sigue cerrando contra el gerencial.
  FOR v_suc, v_mes IN
    SELECT s.id, m.mes
      FROM sucursales s
     CROSS JOIN (VALUES ('2026-06-01'::date), ('2026-09-01'::date), ('2026-10-01'::date)) m(mes)
     WHERE s.activa
  LOOP
    v_r := public.reporte_mermas(v_mes, (v_mes + interval '1 month - 1 day')::date, v_suc, NULL, NULL);
    v_g := public.reporte_gerencial(v_suc, v_mes, (v_mes + interval '1 month - 1 day')::date, false, false);
    SELECT COALESCE(SUM((x->>'costo')::numeric) FILTER (WHERE x->>'clasificacion' <> 'promocion'), 0),
           COALESCE(SUM((x->>'costo')::numeric) FILTER (WHERE x->>'clasificacion' = 'promocion'), 0)
      INTO v_pp, v_ppp
      FROM jsonb_array_elements(v_r->'por_procedencia') x;
    IF abs(v_pp - (v_r->'totales'->>'costo')::numeric) > 0.01
       OR abs(v_ppp - (v_r->'totales'->>'costo_ajuste_promocion')::numeric) > 0.01
       OR abs((v_r->'totales'->>'costo')::numeric - (v_g->'kpis'->>'mermas')::numeric) > 0.01 THEN
      RAISE EXCEPTION 'sucursal % mes %: por_procedencia % / promo % / totales % / gerencial %',
        v_suc, v_mes, v_pp, v_ppp, v_r->'totales'->>'costo', v_g->'kpis'->>'mermas';
    END IF;
    IF NOT (v_r->'detalle'->0 ? 'procedencia') AND jsonb_array_length(v_r->'detalle') > 0 THEN
      RAISE EXCEPTION 'el detalle de reporte_mermas no trae procedencia';
    END IF;
  END LOOP;

  -- (e) Permisos: nadie fuera del server.
  IF has_function_privilege('anon', 'public.mermas_valorizadas(date,date,bigint[])', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.mermas_valorizadas(date,date,bigint[])', 'EXECUTE')
     OR has_function_privilege('anon', 'public.merma_procedencia(bigint,text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.merma_procedencia(bigint,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.mermas_valorizadas(date,date,bigint[])', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.merma_procedencia(bigint,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'permisos de mermas_valorizadas / merma_procedencia fuera de lo esperado';
  END IF;
END
$verif$;
