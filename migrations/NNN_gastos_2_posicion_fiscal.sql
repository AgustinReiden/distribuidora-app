-- =========================================================================
-- GASTOS 2 · LA POSICION FISCAL SUMA LOS GASTOS (entrega 1 de 5 de gastos)
--
-- Diseno: docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md (1.6)
-- Plan:   docs/superpowers/plans/2026-10-28-gastos-1-vehiculos-rubros-y-gastos.md (tarea 3)
--
-- El IVA y las percepciones de un gasto con factura A o M son credito fiscal,
-- como los de una compra (mig 293: la M da credito igual que la A). Esta
-- migracion los suma a posicion_fiscal, por la FECHA del comprobante (el
-- resultado lo rige el mes del gasto, la posicion fiscal no).
--
-- QUE CAMBIA EN posicion_fiscal(p_sucursal_id, p_desde, p_hasta), misma firma:
--   * CTE gastos_k: gastos con factura A o M, no anulados, de las sucursales
--     pedidas y con fecha en el periodo. Un compartido cuenta en la sucursal
--     donde se cargo (posicion_fiscal es por sucursal; el modal le recuerda
--     al admin cargarlo desde la sucursal a cuyo nombre esta la factura).
--   * Clave nueva 'gastos': {cantidad, iva_credito, percepcion_iva,
--     percepcion_iibb}. Los otros impuestos (ITC) no son credito: no entran.
--   * 'posicion': iva_credito = compras + gastos; saldo_tecnico = debito -
--     (credito de compras + de gastos) - (percepcion de IVA de compras + de
--     gastos); percepciones_a_favor suma las dos percepciones de los gastos.
--   * 'compras' NO cambia: sigue siendo solo de compras.
--   Sin gastos en el periodo, el JSON es identico al de antes salvo la clave
--   'gastos' (lo prueba scripts/test-gastos-2.sql).
--
-- PARCHE POR ANCLA sobre la definicion VIVA: la tocaron las migraciones 348,
-- 352, 355, 394 y 397, y reescribirla entera arrastraria una copia vieja.
-- Cada ancla tiene que aparecer exactamente una vez o la migracion aborta.
--
-- ORDEN: despues de gastos_1 (lee la tabla gastos). El front que muestra la
-- clave 'gastos' la trata como opcional, asi que puede ir antes o despues.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- Mismo helper de parches que la 363 y la 380.
CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

DO $parche$
DECLARE
  v_def text := pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure);
BEGIN
  -- 1 · La CTE de los gastos, despues de compras_k.
  v_def := pg_temp.rr_parchar(v_def,
$v$    FROM compras_p
  )
  SELECT jsonb_build_object($v$,
$n$    FROM compras_p
  ),
  -- gastos 1/5: credito fiscal de los gastos con factura A o M, por la fecha
  -- del comprobante. Un compartido cuenta en la sucursal donde se cargo. Los
  -- otros impuestos (ITC) son costo, no credito.
  gastos_k AS (
    SELECT COUNT(*) AS cantidad,
           COALESCE(SUM(iva), 0) AS iva_credito,
           COALESCE(SUM(percepcion_iva), 0) AS percepcion_iva,
           COALESCE(SUM(percepcion_iibb), 0) AS percepcion_iibb
    FROM gastos
    WHERE comprobante IN ('factura_a', 'factura_m')
      AND anulado_at IS NULL
      AND sucursal_id = ANY(v_sucursales)
      AND fecha BETWEEN p_desde AND p_hasta
  )
  SELECT jsonb_build_object($n$,
    'posicion_fiscal: CTE gastos_k');

  -- 2 · La clave 'gastos' y la posicion con compras + gastos.
  v_def := pg_temp.rr_parchar(v_def,
$v$      FROM compras_k c),
    'posicion', (SELECT jsonb_build_object(
        'saldo_tecnico', v.iva_debito - c.iva_credito - c.percepcion_iva,
        'iva_debito', v.iva_debito,
        'iva_credito', c.iva_credito,
        'percepciones_a_favor', c.percepcion_iva + c.percepcion_iibb)
      FROM ventas v, compras_k c)$v$,
$n$      FROM compras_k c),
    'gastos', (SELECT jsonb_build_object(
        'cantidad', g.cantidad, 'iva_credito', g.iva_credito,
        'percepcion_iva', g.percepcion_iva, 'percepcion_iibb', g.percepcion_iibb)
      FROM gastos_k g),
    'posicion', (SELECT jsonb_build_object(
        'saldo_tecnico', v.iva_debito - (c.iva_credito + g.iva_credito) - (c.percepcion_iva + g.percepcion_iva),
        'iva_debito', v.iva_debito,
        'iva_credito', c.iva_credito + g.iva_credito,
        'percepciones_a_favor', c.percepcion_iva + c.percepcion_iibb + g.percepcion_iva + g.percepcion_iibb)
      FROM ventas v, compras_k c, gastos_k g)$n$,
    'posicion_fiscal: claves gastos y posicion');

  EXECUTE v_def;
END
$parche$;

-- -------------------------------------------------------------------------
-- Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_def text := pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure);
BEGIN
  IF position('gastos_k AS (' IN v_def) = 0 OR position('''gastos'', (SELECT' IN v_def) = 0
     OR position('FROM ventas v, compras_k c, gastos_k g)' IN v_def) = 0 THEN
    RAISE EXCEPTION 'posicion_fiscal no quedo con los gastos';
  END IF;
  -- Misma firma, mismos permisos (CREATE OR REPLACE los conserva) y DEFINER.
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'posicion_fiscal') <> 1
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.posicion_fiscal(bigint,date,date)'::regprocedure)
     OR has_function_privilege('anon', 'public.posicion_fiscal(bigint,date,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.posicion_fiscal(bigint,date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'posicion_fiscal cambio de firma o de permisos';
  END IF;
END
$verif$;
