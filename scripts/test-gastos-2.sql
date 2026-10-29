-- Ensayo de la migracion gastos_2_posicion_fiscal (la posicion fiscal suma el
-- IVA y las percepciones de los gastos con factura A o M).
--
-- Corre contra prod SIN dejar rastro: un unico DO que termina SIEMPRE en RAISE
-- EXCEPTION, asi que los gastos que inserta se deshacen.
--
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplio.
--
-- Es ACUMULADO: necesita gastos_1 (la tabla gastos). Antes de gastos_2 tiene
-- que FALLAR (posicion_fiscal no tiene la clave 'gastos'); despues, pasar:
--
--   BEGIN; SET LOCAL lock_timeout = '5s';
--   <migrations/NNN_gastos_1_tablas_y_rpcs.sql>
--   <migrations/NNN_gastos_2_posicion_fiscal.sql>
--   <este archivo>
--   ROLLBACK;
--
-- EL "ANTES": el ensayo corre despues de la migracion, asi que la funcion de
-- antes se reconstruye de la viva deshaciendo los dos parches (cada fragmento
-- tiene que aparecer exactamente una vez) y se crea en pg_temp. Como la
-- migracion solo aplica esos dos reemplazos, eso ES la definicion de antes.
--
-- posicion_fiscal se llama como servicio (sin auth.uid()), igual que el cron
-- del reporte: ve todas las sucursales activas. Periodo: el mes en curso.
--
--   I  sin gastos en el periodo, el JSON de S1, S2 y la Red es identico al de
--      antes salvo la clave 'gastos' (en cero) y meta.generado_at
--   A  factura A en S1: 50000 con IVA 8677,69, percepcion de IVA 1000, de IIBB
--      300 y otros impuestos 2000 -> gastos.iva_credito 8677,69;
--      posicion.iva_credito = compras + 8677,69; saldo_tecnico baja 9677,69;
--      percepciones_a_favor sube 1300 (los otros impuestos no cuentan);
--      'compras' igual que antes
--   N  un ticket, un anulado y una factura A fuera del periodo no cuentan
--   C  compartido con factura M cargado en S1 (IVA 1000): cuenta en S1 y no
--      en S2; la Red los suma
--   P  posicion_fiscal sigue con una sola firma, DEFINER, sin anon
--
--   psql "$DATABASE_URL" -f scripts/test-gastos-2.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_def     text;
  v_antes   text;
  v_s1      bigint;
  v_s2      bigint;
  v_admin   uuid;
  v_rubro   bigint;
  v_desde   date := date_trunc('month', current_date)::date;
  v_hasta   date := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;
  v_suc     bigint;
  n         jsonb;
  a         jsonb;
  b1        jsonb;
  b2        jsonb;
  bred      jsonb;
  v_n       int;
BEGIN
  SET LOCAL lock_timeout = '5s';

  IF to_regclass('public.gastos') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no existe la tabla gastos (falta la migracion gastos_1)';
  END IF;
  v_def := pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure);
  IF position('gastos_k' IN v_def) = 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · posicion_fiscal no suma los gastos (falta la migracion gastos_2)';
  END IF;

  -- --------------------------------------------------------- contexto ---
  SELECT min(id) INTO v_s1 FROM sucursales WHERE activa;
  SELECT min(id) INTO v_s2 FROM sucursales WHERE activa AND id > v_s1;
  SELECT pf.id INTO v_admin FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE pf.rol = 'admin' AND pf.activo AND us.sucursal_id = v_s1 ORDER BY pf.id LIMIT 1;
  SELECT id INTO v_rubro FROM gasto_rubros WHERE activo ORDER BY id LIMIT 1;
  IF v_s2 IS NULL OR v_admin IS NULL OR v_rubro IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin contexto: S1 %, S2 %, admin %, rubro %', v_s1, v_s2, v_admin, v_rubro;
  END IF;
  -- Como servicio: sin claims, auth.uid() es NULL.
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);

  -- ------------------------------------------------- la funcion de antes ---
  CREATE FUNCTION pg_temp.deshacer(p_def text, p_nuevo text, p_viejo text, p_que text)
  RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    IF (length(p_def) - length(replace(p_def, p_nuevo, ''))) / length(p_nuevo) <> 1 THEN
      RAISE EXCEPTION 'ENSAYO FALLÓ · %: el parche no aparece exactamente una vez en la definicion viva', p_que;
    END IF;
    RETURN replace(p_def, p_nuevo, p_viejo);
  END
  $f$;

  v_antes := pg_temp.deshacer(v_def,
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
$v$    FROM compras_p
  )
  SELECT jsonb_build_object($v$,
    'CTE gastos_k');
  v_antes := pg_temp.deshacer(v_antes,
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
$v$      FROM compras_k c),
    'posicion', (SELECT jsonb_build_object(
        'saldo_tecnico', v.iva_debito - c.iva_credito - c.percepcion_iva,
        'iva_debito', v.iva_debito,
        'iva_credito', c.iva_credito,
        'percepciones_a_favor', c.percepcion_iva + c.percepcion_iibb)
      FROM ventas v, compras_k c)$v$,
    'claves gastos y posicion');
  IF position('gastos' IN replace(v_antes, 'posicion_fiscal', '')) > 0 THEN
    v_fallas := v_fallas || 'la definicion de antes reconstruida todavia menciona gastos'::text;
  END IF;
  EXECUTE replace(v_antes, 'FUNCTION public.posicion_fiscal(', 'FUNCTION pg_temp.posicion_fiscal_antes(');

  -- ================================================ I · identico sin gastos ===
  BEGIN
    SELECT count(*) INTO v_n FROM gastos WHERE fecha BETWEEN v_desde AND v_hasta;
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('I hay %s gastos en el periodo: el caso "sin gastos" no se puede probar', v_n);
    END IF;
    FOREACH v_suc IN ARRAY ARRAY[v_s1, v_s2, NULL] LOOP
      n := public.posicion_fiscal(v_suc, v_desde, v_hasta);
      a := pg_temp.posicion_fiscal_antes(v_suc, v_desde, v_hasta);
      IF (n - 'gastos') #- '{meta,generado_at}' IS DISTINCT FROM a #- '{meta,generado_at}' THEN
        v_fallas := v_fallas || format('I sucursal %s: el JSON cambio sin gastos. antes %s · ahora %s',
                                       COALESCE(v_suc::text, 'Red'), a #- '{meta,generado_at}', (n - 'gastos') #- '{meta,generado_at}');
      END IF;
      IF n->'gastos' IS DISTINCT FROM '{"cantidad": 0, "iva_credito": 0, "percepcion_iva": 0, "percepcion_iibb": 0}'::jsonb THEN
        v_fallas := v_fallas || format('I sucursal %s: la clave gastos sin gastos es %s', COALESCE(v_suc::text, 'Red'), n->'gastos');
      END IF;
    END LOOP;
    b1 := pg_temp.posicion_fiscal_antes(v_s1, v_desde, v_hasta);
    b2 := pg_temp.posicion_fiscal_antes(v_s2, v_desde, v_hasta);
    bred := pg_temp.posicion_fiscal_antes(NULL, v_desde, v_hasta);
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('I · error: %s', SQLERRM);
  END;

  -- ============================================ A · factura A en S1 ===
  BEGIN
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, alicuota_iva, iva,
                        percepcion_iva, percepcion_iibb, otros_impuestos, mes_imputado, creado_por)
    VALUES (v_s1, v_desde, v_rubro, 50000, 'factura_a', 21, 8677.69, 1000, 300, 2000, v_desde, v_admin);
    -- N · lo que no cuenta: ticket, anulado, fuera del periodo
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, mes_imputado, creado_por)
    VALUES (v_s1, v_desde, v_rubro, 8500, 'ticket', v_desde, v_admin);
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, alicuota_iva, iva, percepcion_iva,
                        mes_imputado, creado_por, anulado_at, anulado_por, motivo_anulacion)
    VALUES (v_s1, v_desde, v_rubro, 10000, 'factura_a', 21, 500, 50, v_desde, v_admin, now(), v_admin, 'ensayo');
    INSERT INTO gastos (sucursal_id, fecha, rubro_id, monto_total, comprobante, alicuota_iva, iva, percepcion_iva,
                        mes_imputado, creado_por)
    VALUES (v_s1, v_desde - 1, v_rubro, 10000, 'factura_a', 21, 700, 70,
            date_trunc('month', (v_desde - 1)::timestamp)::date, v_admin);

    n := public.posicion_fiscal(v_s1, v_desde, v_hasta);
    IF n->'gastos' IS DISTINCT FROM '{"cantidad": 1, "iva_credito": 8677.69, "percepcion_iva": 1000, "percepcion_iibb": 300}'::jsonb THEN
      v_fallas := v_fallas || format('A gastos de S1 = %s (esperado 1 gasto, 8677.69, 1000, 300: sin ticket, anulado ni fuera del periodo)', n->'gastos');
    END IF;
    IF (n->'posicion'->>'iva_credito')::numeric IS DISTINCT FROM (n->'compras'->>'iva_credito')::numeric + 8677.69 THEN
      v_fallas := v_fallas || format('A posicion.iva_credito %s <> compras %s + 8677.69',
                                     n->'posicion'->>'iva_credito', n->'compras'->>'iva_credito');
    END IF;
    IF (n->'posicion'->>'saldo_tecnico')::numeric IS DISTINCT FROM (b1->'posicion'->>'saldo_tecnico')::numeric - 9677.69 THEN
      v_fallas := v_fallas || format('A saldo_tecnico %s; antes %s, tenia que bajar 9677.69',
                                     n->'posicion'->>'saldo_tecnico', b1->'posicion'->>'saldo_tecnico');
    END IF;
    IF (n->'posicion'->>'percepciones_a_favor')::numeric IS DISTINCT FROM (b1->'posicion'->>'percepciones_a_favor')::numeric + 1300 THEN
      v_fallas := v_fallas || format('A percepciones_a_favor %s; antes %s, tenia que subir 1300 (sin los otros impuestos)',
                                     n->'posicion'->>'percepciones_a_favor', b1->'posicion'->>'percepciones_a_favor');
    END IF;
    IF n->'compras' IS DISTINCT FROM b1->'compras' OR n->'ventas' IS DISTINCT FROM b1->'ventas'
       OR n->'posicion'->'iva_debito' IS DISTINCT FROM b1->'posicion'->'iva_debito' THEN
      v_fallas := v_fallas || 'A ventas, compras o el debito cambiaron por un gasto'::text;
    END IF;

    -- =========================================== C · compartido con M en S1 ===
    INSERT INTO gastos (sucursal_id, compartido, fecha, rubro_id, monto_total, comprobante, alicuota_iva, iva,
                        mes_imputado, creado_por)
    VALUES (v_s1, true, v_hasta, v_rubro, 6000, 'factura_m', 21, 1000, v_desde, v_admin);
    n := public.posicion_fiscal(v_s1, v_desde, v_hasta);
    IF (n->'gastos'->>'cantidad')::int IS DISTINCT FROM 2
       OR (n->'gastos'->>'iva_credito')::numeric IS DISTINCT FROM 9677.69
       OR (n->'posicion'->>'saldo_tecnico')::numeric IS DISTINCT FROM (b1->'posicion'->>'saldo_tecnico')::numeric - 10677.69 THEN
      v_fallas := v_fallas || format('C el compartido con factura M no cuenta en S1: gastos %s, saldo %s', n->'gastos', n->'posicion'->>'saldo_tecnico');
    END IF;
    n := public.posicion_fiscal(v_s2, v_desde, v_hasta);
    IF (n - 'gastos') #- '{meta,generado_at}' IS DISTINCT FROM b2 #- '{meta,generado_at}'
       OR (n->'gastos'->>'cantidad')::int IS DISTINCT FROM 0 THEN
      v_fallas := v_fallas || format('C el compartido cargado en S1 cuenta en S2: gastos %s', n->'gastos');
    END IF;
    n := public.posicion_fiscal(NULL, v_desde, v_hasta);
    IF (n->'gastos'->>'cantidad')::int IS DISTINCT FROM 2
       OR (n->'posicion'->>'iva_credito')::numeric IS DISTINCT FROM (bred->'posicion'->>'iva_credito')::numeric + 9677.69 THEN
      v_fallas := v_fallas || format('C la Red no suma los gastos de S1: gastos %s', n->'gastos');
    END IF;
  EXCEPTION WHEN OTHERS THEN v_fallas := v_fallas || format('A/N/C · error: %s', SQLERRM);
  END;

  -- ===================================================== P · la funcion ===
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'posicion_fiscal') <> 1
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.posicion_fiscal(bigint,date,date)'::regprocedure)
     OR has_function_privilege('anon', 'public.posicion_fiscal(bigint,date,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.posicion_fiscal(bigint,date,date)', 'EXECUTE')
     OR EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() WHERE firma LIKE 'posicion_fiscal(%') THEN
    v_fallas := v_fallas || 'P posicion_fiscal cambio de firma, de permisos o quedo en rojo en SEG-A'::text;
  END IF;

  -- ---------------------------------------------------------- veredicto --
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · %', array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · posicion fiscal con gastos (S1=%, S2=%, % a %): sin gastos identica a la de antes en S1, S2 y Red; factura A suma 8677,69 de credito, saldo -9677,69 y percepciones +1300 sin los otros impuestos; ticket, anulado y fuera del periodo no cuentan; el compartido con M cuenta en S1 y no en S2; misma firma y permisos',
    v_s1, v_s2, v_desde, v_hasta;
END
$ensayo$;
