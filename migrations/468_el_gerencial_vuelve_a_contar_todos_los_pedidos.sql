-- 468 · El gerencial vuelve a contar todos los pedidos entregados (#1472, REP-F-2).
--
-- QUÉ PASABA
--   La 463d (REP-F-2) sacó de kpis.pedidos, fc_pedidos, zz_pedidos, ticket, mensual y top_cli
--   los pedidos sin venta (venta_prod = 0: el rechazo total, sin líneas), para que kpis.pedidos
--   diera Σ vendedores.pedidos. Pero "pedido de venta" es una definición que comparten 28
--   funciones que cuentan pedidos con el corte de "Venta por vendedor" (CLAUDE.md): el bot,
--   el tablero, rendimiento y jornadas, metas, posicion_fiscal, reporte_ventas_por_cliente,
--   tablero_facturacion_mensual... Ninguna saca los de venta 0. El cruce de reportes de
--   `check-integridad.mjs` (integridad.yml) se puso rojo en octubre: Taco Pozo 290 contra
--   291 y la Red 1.309 contra 1.310 (el pedido 7604).
--
-- QUÉ CAMBIA
--   reporte_gerencial vuelve a contar pedidos, fc_pedidos, zz_pedidos, ticket, mensual y los
--   pedidos de top_cli como antes de la 463d: todo pedido del corte de `ped`. Queda escrito al
--   lado de k_ped por qué kpis.pedidos puede no dar Σ vendedores.pedidos: vendedores sale de
--   las líneas, y un pedido sin líneas no tiene vendedor que sumar. Hoy son dos en toda la
--   historia (7604 y 652). #1472 lo admite ("o dejar escrito por qué no").
--
-- QUÉ NO CAMBIA
--   Lo demás de la 463d: los rankings por id (REP-F-1) y la Red de _sucursales_red() (REP-F-3).
--   La firma, el EXECUTE y SECURITY DEFINER.
--
-- Aplicar desde el contenido LF.

BEGIN ISOLATION LEVEL REPEATABLE READ;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 1 · Premisa: el cuerpo vivo es el que dejó la 463d
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(p.prosrc) INTO v_md5
    FROM pg_proc p WHERE p.oid = 'public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure;
  IF v_md5 IS DISTINCT FROM '040b57b910cd2121a9ae19766d7b083e' THEN
    RAISE EXCEPTION 'mig 468 · reporte_gerencial cambió en prod desde la 463d (md5 %, esperado 040b57b910cd2121a9ae19766d7b083e): rehacer sobre la definición vigente',
      v_md5;
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 2 · Foto de antes: el gerencial como el servidor (el que corre el gate), en la Red y cada
--     sucursal activa, en abril (el pedido 652), el mes pasado (el 7604) y el mes en curso.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _r5b_foto (etapa text, rango text, desde date, hasta date, suc bigint, todos boolean, valor jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp._r5b_fotografiar(p_etapa text) RETURNS integer
LANGUAGE plpgsql AS $f$
DECLARE
  v_claims text := current_setting('request.jwt.claims', true);
  v_hoy    date := public._tablero_hoy();
  v_r      record;
  v_suc    bigint;
  v_todos  boolean;
  v_n      integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  FOR v_r IN
    SELECT * FROM (VALUES
      ('abril',        DATE '2026-04-01', DATE '2026-04-30'),
      ('mes_pasado',   (date_trunc('month', v_hoy::timestamp) - interval '1 month')::date,
                       (date_trunc('month', v_hoy::timestamp) - interval '1 day')::date),
      ('mes_en_curso', date_trunc('month', v_hoy::timestamp)::date, v_hoy)
    ) AS t(rango, desde, hasta)
  LOOP
    FOR v_suc IN SELECT NULL::bigint UNION ALL (SELECT id FROM sucursales WHERE activa ORDER BY id) LOOP
      FOREACH v_todos IN ARRAY ARRAY[false, true] LOOP
        INSERT INTO _r5b_foto VALUES (p_etapa, v_r.rango, v_r.desde, v_r.hasta, v_suc, v_todos,
          public.reporte_gerencial(v_suc, v_r.desde, v_r.hasta, v_todos, NOT v_todos));
      END LOOP;
    END LOOP;
  END LOOP;
  PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
  SELECT count(*) INTO v_n FROM _r5b_foto WHERE etapa = p_etapa;
  RETURN v_n;
END
$f$;

SELECT pg_temp._r5b_fotografiar('antes');

-- ---------------------------------------------------------------------------
-- 3 · Parche por ancla: vuelven los conteos de antes de la 463d
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _r5b_parche (orden int, ancla text, reemplazo text) ON COMMIT DROP;

INSERT INTO _r5b_parche (orden, ancla, reemplazo) VALUES
(1,
$a$  -- #1472 (REP-F-2): un pedido sin venta (el rechazo total, que no tiene líneas) no es un
  -- pedido: no está en vendedores y diluía el ticket. Pedidos, ticket y su partición FC/ZZ
  -- cuentan venta_prod > 0, el corte de k_env; así kpis.pedidos = Σ vendedores.pedidos. La
  -- venta no cambia (suman 0), y `clientes` tampoco: #1472 pide pedidos y ticket.
  k_ped AS (SELECT COUNT(*) FILTER (WHERE venta_prod > 0) AS pedidos, COALESCE(SUM(venta_prod),0) AS venta, -- cargo_4
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(venta_prod) FILTER (WHERE venta_prod > 0)),0) AS ticket,
$a$,
$r$  -- #1472 (REP-F-2): un pedido es todo pedido del corte de `ped`, también el que quedó sin
  -- venta (el rechazo total). Es la definición de las ~28 funciones que cuentan pedidos de
  -- venta (reporte_ventas_por_cliente, tablero_facturacion_mensual, el bot...), y el cruce de
  -- check-integridad.mjs exige que cierren entre sí. Por eso kpis.pedidos puede dar más que
  -- Σ vendedores.pedidos: vendedores sale de las líneas (`it`), y un pedido sin líneas no
  -- tiene vendedor que sumar. Hasta el 06/11 son dos en toda la historia (7604 y 652).
  k_ped AS (SELECT COUNT(*) AS pedidos, COALESCE(SUM(venta_prod),0) AS venta, -- cargo_4
            COUNT(DISTINCT cliente_id) AS clientes, COALESCE(ROUND(AVG(venta_prod)),0) AS ticket,
$r$),
(2,
$a$            COUNT(*) FILTER (WHERE tipo_factura='FC' AND venta_prod > 0) AS fc_pedidos,
$a$,
$r$            COUNT(*) FILTER (WHERE tipo_factura='FC') AS fc_pedidos,
$r$),
(3,
$a$            COUNT(*) FILTER (WHERE tipo_factura='ZZ' AND venta_prod > 0) AS zz_pedidos
$a$,
$r$            COUNT(*) FILTER (WHERE tipo_factura='ZZ') AS zz_pedidos
$r$),
(4,
$a$  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) FILTER (WHERE venta_prod > 0) AS pedidos, SUM(venta_prod) AS venta, -- cargo_4, #1472
            SUM(total_real) AS venta_real,
            COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(venta_prod) FILTER (WHERE venta_prod > 0)) AS ticket FROM ped GROUP BY 1),
$a$,
$r$  m_ped AS (SELECT to_char(fecha,'YYYY-MM') AS mes, COUNT(*) AS pedidos, SUM(venta_prod) AS venta, -- cargo_4
            SUM(total_real) AS venta_real,
            COUNT(DISTINCT cliente_id) AS clientes, ROUND(AVG(venta_prod)) AS ticket FROM ped GROUP BY 1),
$r$),
(5,
$a$  -- empate se desempata por id para que el puesto 10 no dependa del plan. Los pedidos de un
  -- cliente cuentan los que tienen venta, como kpis.pedidos (REP-F-2).
$a$,
$r$  -- empate se desempata por id para que el puesto 10 no dependa del plan. Los pedidos de un
  -- cliente cuentan como kpis.pedidos: todos los del corte de `ped`.
$r$),
(6,
$a$      COUNT(DISTINCT p.id) FILTER (WHERE p.venta_prod > 0) AS pedidos, SUM(p.venta_prod) AS venta -- cargo_4
$a$,
$r$      COUNT(DISTINCT p.id) AS pedidos, SUM(p.venta_prod) AS venta -- cargo_4
$r$);

DO $parches$
DECLARE
  v_p   record;
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
  v_n   int;
BEGIN
  FOR v_p IN SELECT * FROM _r5b_parche ORDER BY orden LOOP
    v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 468 · parche %: el ancla aparece % vez/veces y se esperaba 1', v_p.orden, v_n;
    END IF;
    v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
  END LOOP;
  EXECUTE v_def;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 4 · Ensayo: sólo cambian los conteos de pedidos, y cierran contra los dos reportes del
--     cruce de check-integridad.mjs.
-- ---------------------------------------------------------------------------
SELECT pg_temp._r5b_fotografiar('despues');

-- Los conteos de antes de la 463d, recalculados aparte: todo pedido del corte de `ped`.
CREATE FUNCTION pg_temp._r5b_conteo(p_desde date, p_hasta date, p_sucs bigint[], p_todos boolean)
RETURNS jsonb LANGUAGE sql STABLE AS $f$
  SELECT jsonb_build_object('pedidos', count(*),
                            'fc_pedidos', count(*) FILTER (WHERE COALESCE(p.tipo_factura, 'ZZ') = 'FC'),
                            'zz_pedidos', count(*) FILTER (WHERE COALESCE(p.tipo_factura, 'ZZ') = 'ZZ'),
                            'ticket', COALESCE(round(avg(GREATEST(p.total - p.cargo_envio, 0))), 0))
    FROM pedidos p
   WHERE p.estado = ANY(CASE WHEN p_todos THEN ARRAY['entregado','asignado','pendiente','en_preparacion'] ELSE ARRAY['entregado'] END)
     AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
     AND p.fecha BETWEEN p_desde AND p_hasta AND p.sucursal_id = ANY(p_sucs);
$f$;

DO $ensayo$
DECLARE
  r        record;
  v_esp    jsonb;
  v_fallas text[] := '{}';
  v_sucs   bigint[];
  v_cli    jsonb;
  v_fac    jsonb;
  v_mes    jsonb;
  v_n      int := 0;
  v_cruces int := 0;
  v_saca   jsonb;
  v_m      jsonb;
  v_ini    date;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  FOR r IN
    SELECT a.rango, a.desde, a.hasta, a.suc, a.todos, a.valor AS antes, d.valor AS despues
      FROM _r5b_foto a JOIN _r5b_foto d
        ON d.etapa = 'despues' AND d.rango = a.rango AND d.suc IS NOT DISTINCT FROM a.suc AND d.todos = a.todos
     WHERE a.etapa = 'antes'
  LOOP
    v_n := v_n + 1;
    v_sucs := CASE WHEN r.suc IS NULL THEN public._sucursales_red() ELSE ARRAY[r.suc] END;

    -- Los conteos de después son los de antes de la 463d: kpis, cada mes y el comparativo.
    v_esp := pg_temp._r5b_conteo(r.desde, r.hasta, v_sucs, r.todos);
    IF (r.despues->'kpis') @> v_esp IS NOT TRUE THEN
      v_fallas := v_fallas || format('[%s suc %s todos %s: kpis %s, esperado %s]', r.rango, r.suc, r.todos,
        jsonb_build_object('pedidos', r.despues->'kpis'->'pedidos', 'ticket', r.despues->'kpis'->'ticket'), v_esp);
    END IF;
    FOR v_m IN SELECT e FROM jsonb_array_elements(r.despues->'mensual') e LOOP
      v_ini := to_date(v_m->>'mes' || '-01', 'YYYY-MM-DD');
      v_esp := pg_temp._r5b_conteo(GREATEST(r.desde, v_ini), LEAST(r.hasta, (v_ini + interval '1 month' - interval '1 day')::date),
                                   v_sucs, r.todos) - 'fc_pedidos' - 'zz_pedidos';
      IF v_m @> v_esp IS NOT TRUE THEN
        v_fallas := v_fallas || format('[%s suc %s todos %s: mensual %s, esperado %s]', r.rango, r.suc, r.todos, v_m, v_esp);
      END IF;
    END LOOP;
    IF jsonb_typeof(r.despues->'comparativo') = 'object' THEN
      v_esp := pg_temp._r5b_conteo((r.despues->'comparativo'->>'desde')::date, (r.despues->'comparativo'->>'hasta')::date, v_sucs, r.todos);
      IF (r.despues->'comparativo') @> v_esp IS NOT TRUE THEN
        v_fallas := v_fallas || format('[%s suc %s: comparativo %s/%s, esperado %s]', r.rango, r.suc,
          r.despues->'comparativo'->'pedidos', r.despues->'comparativo'->'ticket', v_esp);
      END IF;
    END IF;
    -- Los pedidos de top_clientes: los de cada cliente en el corte de `ped`.
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.despues->'top_clientes') e
                WHERE (e->>'pedidos')::int IS DISTINCT FROM
                      (SELECT count(*)::int FROM pedidos p
                        WHERE p.cliente_id = (e->>'cliente_id')::bigint
                          AND p.estado = ANY(CASE WHEN r.todos THEN ARRAY['entregado','asignado','pendiente','en_preparacion'] ELSE ARRAY['entregado'] END)
                          AND p.canal <> 'cambio' AND p.tipo_factura IS DISTINCT FROM 'VB'
                          AND p.fecha BETWEEN r.desde AND r.hasta AND p.sucursal_id = ANY(v_sucs))) THEN
      v_fallas := v_fallas || format('[%s suc %s todos %s: los pedidos de top_clientes no son los del corte]', r.rango, r.suc, r.todos);
    END IF;

    -- Fuera de esos números, de los de mensual y de los pedidos de top_clientes, nada cambia.
    v_saca := jsonb_build_object('a', r.antes, 'd', r.despues);
    IF (SELECT jsonb_set((x #- '{kpis,pedidos}' #- '{kpis,ticket}' #- '{kpis,fc_pedidos}' #- '{kpis,zz_pedidos}'
                            #- '{comparativo,pedidos}' #- '{comparativo,ticket}' #- '{comparativo,fc_pedidos}' #- '{comparativo,zz_pedidos}'),
                         '{mensual}', COALESCE((SELECT jsonb_agg(e - 'pedidos' - 'ticket') FROM jsonb_array_elements(x->'mensual') e), '[]'::jsonb))
              || jsonb_build_object('top_clientes', COALESCE((SELECT jsonb_agg(e - 'pedidos') FROM jsonb_array_elements(x->'top_clientes') e), '[]'::jsonb))
          FROM (SELECT v_saca->'a' AS x) s)
       IS DISTINCT FROM
       (SELECT jsonb_set((x #- '{kpis,pedidos}' #- '{kpis,ticket}' #- '{kpis,fc_pedidos}' #- '{kpis,zz_pedidos}'
                            #- '{comparativo,pedidos}' #- '{comparativo,ticket}' #- '{comparativo,fc_pedidos}' #- '{comparativo,zz_pedidos}'),
                         '{mensual}', COALESCE((SELECT jsonb_agg(e - 'pedidos' - 'ticket') FROM jsonb_array_elements(x->'mensual') e), '[]'::jsonb))
              || jsonb_build_object('top_clientes', COALESCE((SELECT jsonb_agg(e - 'pedidos') FROM jsonb_array_elements(x->'top_clientes') e), '[]'::jsonb))
          FROM (SELECT v_saca->'d' AS x) s) THEN
      v_fallas := v_fallas || format('[%s suc %s todos %s: cambió algo más que los pedidos]', r.rango, r.suc, r.todos);
    END IF;

    -- El cruce de check-integridad.mjs, con lo entregado (como corre el gate).
    IF NOT r.todos THEN
      v_cruces := v_cruces + 1;
      v_cli := public.reporte_ventas_por_cliente(r.desde, r.hasta, NULL, r.suc);
      IF (v_cli->'totales'->>'pedidos')::numeric IS DISTINCT FROM (r.despues->'kpis'->>'pedidos')::numeric THEN
        v_fallas := v_fallas || format('[%s suc %s: pedidos por cliente %s, gerencial %s]', r.rango, r.suc,
          v_cli->'totales'->>'pedidos', r.despues->'kpis'->>'pedidos');
      END IF;
      v_fac := public.tablero_facturacion_mensual(r.suc, extract(year FROM r.desde)::int);
      SELECT e INTO v_mes FROM jsonb_array_elements(v_fac->'meses') e WHERE (e->>'mes')::int = extract(month FROM r.desde)::int;
      IF (v_mes->>'pedidos')::numeric IS DISTINCT FROM (r.despues->'kpis'->>'pedidos')::numeric THEN
        v_fallas := v_fallas || format('[%s suc %s: facturación mensual %s, gerencial %s]', r.rango, r.suc,
          v_mes->>'pedidos', r.despues->'kpis'->>'pedidos');
      END IF;
    END IF;
  END LOOP;

  IF v_n < 6 OR v_cruces < 3 THEN
    RAISE EXCEPTION 'mig 468 · el ensayo comparó sólo % llamadas y % cruces', v_n, v_cruces;
  END IF;
  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION 'mig 468 · el ensayo falló: %', left(array_to_string(v_fallas, ' '), 6000);
  END IF;
  RAISE NOTICE 'mig 468 · ensayo OK: % llamadas, % cruces', v_n, v_cruces;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 5 · Poscondición: el cuerpo es el del repo, con el mismo EXECUTE y DEFINER
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  SELECT md5(p.prosrc) AS h, p.proacl::text AS a, p.prosecdef AS def INTO r
    FROM pg_proc p WHERE p.oid = 'public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure;
  IF r.h <> '5438f0188ab423bf13c7421078e9cef9'
     OR r.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
     OR NOT r.def THEN
    RAISE EXCEPTION 'mig 468 · reporte_gerencial no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.def;
  END IF;
END
$post$;

DROP FUNCTION pg_temp._r5b_fotografiar(text), pg_temp._r5b_conteo(date,date,bigint[],boolean);

COMMIT;
