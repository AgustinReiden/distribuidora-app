-- Ensayo de CAT-6 (#1561, plan #1565 tarjeta 10; reescrito en la tarjeta C8 de #1603): un aumento a
-- 30.000 productos, mandado de a lotes como lo manda la pantalla (LOTE_PRECIOS_MASIVO = 500), termina
-- sin cortarse y SIN que el trabajo por producto crezca.
--
-- Por qué ya no afirma «cada lote entra en los 8 s del statement_timeout de authenticated»:
--   Ese ensayo se ponía rojo en el CI sin que el código hubiera cambiado (PR #1665 y #1668: 122, 307 y
--   546 s; el mismo commit pasaba al volver a correr; en local, con la máquina cargada, igual). Lo que se
--   pudo reproducir en local, y explica ese patrón, no es la velocidad del runner: es el PLAN. El ensayo
--   inserta 30.000 productos y no los analizaba; si el autovacuum había pasado por `productos` después
--   de un ensayo anterior (que deja sus filas muertas), el planner elegía `idx_productos_sucursal` (la
--   misma sucursal para todos: ~20.000 entradas por búsqueda) en vez de `productos_pkey`: 1.100 bloques
--   por producto en vez de 68 y 14 s por lote en vez de 1,5 s, con la misma máquina. Pasaba según cuándo
--   cayera el autovacuum.
--   Dos arreglos:
--     1. `ANALYZE productos` después de insertar: el plan sale de las estadísticas reales, como en
--        producción, y no de lo que dejó el ensayo de antes.
--     2. Afirmar TRABAJO y no reloj. Lo que importa del código es cuánto hace por producto, y eso se
--        cuenta: bloques de tabla e índice tocados (pg_stat_get_xact_blocks_fetched), llamadas a
--        funciones (los triggers de `productos`) y la FORMA (los últimos lotes no cuestan más que los
--        primeros: nada cuadrático en las filas tocadas). Son números de esta sesión, que no dependen
--        de la velocidad del runner: dos máquinas dan los mismos bloques y las mismas llamadas. (El WAL
--        no se mide: `pg_current_wal_insert_lsn` es el de todo el servidor, y un autovacuum que corre a
--        la vez lo infla 5 veces.) Un trigger que escanee `productos` por fila, o un plan que vuelva a
--        elegir el índice equivocado, los dispara aunque el runner sea rápido.
--   El tiempo queda como una medida RELATIVA y holgada: el lote mediano contra una referencia medida
--   en este mismo runner, justo antes y justo después (ver c_unidades). No es un número de segundos.
--
-- Cómo se probó que muerde y que no depende del reloj: scripts/ci/gates-muerden.sh arma a propósito un
-- trigger que cuenta `productos` por fila, uno que gasta CPU y uno que llama 25 veces a una función, y exige que
-- este ensayo diga FALLÓ con cada uno, y que un trigger barato de más (un cambio legítimo chico) lo
-- deje pasar. Con `-v lotes=<n>` corre sólo los primeros n lotes: lo usan esos controles.
--
-- Cada lote es su propia sentencia (con \gexec de psql), como cada llamada por PostgREST, como
-- `authenticated`. Todo va en una transacción que se deshace al final: no deja rastro (salvo valores de
-- secuencia y las estadísticas de `productos`, que el ANALYZE escribe sin transacción: el autovacuum las
-- vuelve a poner). El statement_timeout de cada lote es sólo una red contra un cuelgue (60 s).
--
-- Corre con psql, después de aplicar la migración:
--   docker exec -i <contenedor> psql -U postgres -v ON_ERROR_STOP=1 < scripts/test-precios-masivo-30000-1561.sql
-- Con ON_ERROR_STOP, un lote que se corta (57014) para todo: el ensayo falla. El final es un DO que
-- comprueba los 30.000 precios y las medidas, y termina en 'ENSAYO OK', o en el motivo.
-- Antes del arreglo de CAT-6: una sola llamada con los 30.000 se cortaba a los 8 s (57014).
-- También comprueba que esa llamada única hoy se rechaza en el acto, con su motivo.

\set ON_ERROR_STOP 1
\if :{?lotes}
\else
\set lotes 60
\endif

BEGIN;
-- 30 s y no 5: el ANALYZE de abajo espera, si el autovacuum está en `productos`, a que lo cancelen (1 s).
SET LOCAL lock_timeout = '30s';
-- Cuenta las llamadas a funciones de plpgsql (los triggers incluidos) de esta transacción.
SET LOCAL track_functions = 'pl';

CREATE TEMP TABLE ens1561_ctx ON COMMIT DROP AS
SELECT p.id AS admin_id, us.sucursal_id
  FROM perfiles p
  JOIN usuario_sucursales us ON us.usuario_id = p.id
  JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
 WHERE p.rol = 'admin' AND p.activo
 ORDER BY us.sucursal_id, p.id
 LIMIT 1;

-- La referencia de velocidad de ESTE runner: el mejor de 5 tramos de 1.500 vueltas de lo que hace un
-- trigger (una consulta de catálogo y armar un jsonb). Se mide antes de insertar y después de los lotes.
CREATE TEMP TABLE ens1561_ref (fase text, seg numeric) ON COMMIT DROP;
CREATE FUNCTION pg_temp.ens1561_referencia() RETURNS numeric LANGUAGE plpgsql AS $f$
DECLARE
  v_t0 timestamptz;
  v_mejor numeric;
  v_d numeric;
  v_c int;
BEGIN
  FOR r IN 1..5 LOOP
    v_t0 := clock_timestamp();
    FOR i IN 1..1500 LOOP
      SELECT count(*) INTO v_c FROM pg_attribute WHERE attrelid = 'public.productos'::regclass AND attname = 'sucursal_id';
      PERFORM jsonb_build_object('i', i, 'h', md5(i::text));
    END LOOP;
    v_d := extract(epoch FROM clock_timestamp() - v_t0);
    v_mejor := least(COALESCE(v_mejor, v_d), v_d);
  END LOOP;
  RETURN v_mejor;
END
$f$;
INSERT INTO ens1561_ref SELECT 'antes', pg_temp.ens1561_referencia();

-- Lo que consumió esta transacción hasta ahora (lo lee un lote tras otro). El reloj va sólo para
-- medir el lote contra la referencia.
CREATE TEMP VIEW ens1561_medida AS
SELECT extract(epoch FROM clock_timestamp()) AS t,
       (SELECT COALESCE(sum(pg_stat_get_xact_blocks_fetched(c.oid)), 0)::bigint
          FROM pg_class c
         WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'i')) AS bloques,
       (SELECT COALESCE(sum(pg_stat_get_xact_function_calls(p.oid)), 0)::bigint
          FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace) AS llamadas;
CREATE TEMP TABLE ens1561_med (lote int, t float8, bloques bigint, llamadas bigint) ON COMMIT DROP;
GRANT SELECT ON ens1561_medida TO authenticated;
GRANT INSERT ON ens1561_med TO authenticated;

INSERT INTO productos (nombre, precio, stock, sucursal_id)
SELECT 'ENS1561 masivo ' || g, 10, 0, (SELECT sucursal_id FROM ens1561_ctx)
  FROM generate_series(1, 30000) g;
-- Sin esto el plan depende de lo que dejó el autovacuum después de un ensayo anterior (ver arriba).
ANALYZE productos;

GRANT SELECT ON ens1561_ctx TO authenticated;
SELECT set_config('request.jwt.claims', json_build_object('sub', admin_id, 'role', 'authenticated')::text, true),
       set_config('request.headers', json_build_object('x-sucursal-id', sucursal_id::text)::text, true)
  FROM ens1561_ctx;

CREATE TEMP TABLE ens1561_lotes ON COMMIT DROP AS
SELECT (row_number() OVER (ORDER BY id) - 1) / 500 AS lote,
       jsonb_build_object('producto_id', id, 'precio_final', 25, 'precio_neto', 20.66) AS item
  FROM productos WHERE nombre LIKE 'ENS1561 masivo %';
CREATE TEMP TABLE ens1561_res (lote int, r jsonb) ON COMMIT DROP;
GRANT SELECT ON ens1561_lotes TO authenticated;
GRANT INSERT ON ens1561_res TO authenticated;

SET LOCAL ROLE authenticated;
SET LOCAL statement_timeout = '60s';

-- La llamada única de antes: hoy se rechaza en el acto, sin cortarse.
INSERT INTO ens1561_res
SELECT -1, public.actualizar_precios_masivo((SELECT jsonb_agg(item) FROM ens1561_lotes));

-- La medida de partida (lote -1) y, después de cada lote, la suya. Un lote por sentencia, como la pantalla.
INSERT INTO ens1561_med SELECT -1, t, bloques, llamadas FROM ens1561_medida;
SELECT format($q$INSERT INTO ens1561_res
  SELECT %1$s, public.actualizar_precios_masivo((SELECT jsonb_agg(item) FROM ens1561_lotes WHERE lote = %1$s));
  INSERT INTO ens1561_med SELECT %1$s, t, bloques, llamadas FROM ens1561_medida$q$, lote)
  FROM (SELECT DISTINCT lote FROM ens1561_lotes WHERE lote < :lotes ORDER BY lote) l
\gexec

RESET statement_timeout;
RESET ROLE;

INSERT INTO ens1561_ref SELECT 'despues', pg_temp.ens1561_referencia();
-- psql no reemplaza variables dentro de un DO: la cantidad de lotes pedida pasa por una tabla.
CREATE TEMP TABLE ens1561_cfg ON COMMIT DROP AS SELECT :lotes::int AS lotes;

DO $t$
DECLARE
  -- Los topes. Hoy, con 30.000 productos y 60 lotes, cada producto cuesta unos 68 bloques y 7 llamadas
  -- (la auditoría, el stock, el rubro, los impuestos internos...), y un lote tarda
  -- unas 20 unidades de referencia. Los topes son el triple o más, a propósito: un trigger nuevo y
  -- barato (una llamada de más) no los toca; uno que recorra la tabla, que repita el trabajo de la
  -- auditoría o un plan que elija el índice equivocado, sí. Una mejora no obliga a tocar nada; un tope
  -- que se afloja se justifica en el PR.
  c_bloques_x_fila  CONSTANT numeric := 200;
  c_llamadas_x_fila CONSTANT numeric := 21;
  c_forma           CONSTANT numeric := 1.5;   -- bloques por producto: últimos lotes / primeros
  -- El lote mediano (no el más lento: una pausa del runner no cuenta) contra la referencia de este mismo
  -- runner. 100 unidades son los 8 s de producción en la máquina donde se calibró (referencia de 80 ms);
  -- en un runner el doble de lento, la referencia y el lote lo son los dos y la cuenta no cambia.
  c_unidades        CONSTANT numeric := 100;

  v_unica jsonb := (SELECT r FROM ens1561_res WHERE lote = -1);
  v_lotes int := (SELECT count(*) FROM ens1561_res WHERE lote >= 0);
  v_ok int := (SELECT sum((r->>'actualizados')::int) FROM ens1561_res WHERE lote >= 0);
  v_mal int := (SELECT count(*) FROM ens1561_res WHERE lote >= 0 AND NOT (r->>'success')::boolean);
  v_precios int := (SELECT count(*) FROM productos WHERE nombre LIKE 'ENS1561 masivo %' AND precio = 25 AND precio_sin_iva = 20.66);
  v_pedidos int := (SELECT lotes FROM ens1561_cfg);
  v_esperados int := least(60, v_pedidos);
  v_k int := greatest(1, least(10, v_pedidos / 3));
  v_bloques numeric;
  v_llamadas numeric;
  v_primeros numeric;
  v_ultimos numeric;
  v_forma numeric;
  v_seg_med numeric;
  v_seg_max numeric;
  v_ref numeric := (SELECT max(seg) FROM ens1561_ref);
  v_unidades numeric;
  v_fallas text[] := '{}';
BEGIN
  IF (v_unica->>'actualizados')::int <> 0 OR v_unica->'errores'->>0 NOT LIKE '%de a lotes%' THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: la llamada única no se rechazó con su motivo: %', v_unica;
  END IF;
  IF v_lotes <> v_esperados OR v_ok <> v_esperados * 500 OR v_mal <> 0 OR v_precios <> v_esperados * 500 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: lotes % de %, actualizados %, lotes con error %, precios nuevos %',
      v_lotes, v_esperados, v_ok, v_mal, v_precios;
  END IF;

  -- El total de los lotes, por producto cambiado.
  SELECT (max(bloques) - min(bloques))::numeric / v_ok, (max(llamadas) - min(llamadas))::numeric / v_ok
    INTO v_bloques, v_llamadas
    FROM ens1561_med;

  -- La forma: los bloques por producto de los últimos v_k lotes contra los de los primeros v_k.
  WITH d AS (
    SELECT lote, bloques - lag(bloques) OVER (ORDER BY lote) AS b
      FROM ens1561_med
  )
  SELECT avg(b) FILTER (WHERE lote BETWEEN 0 AND v_k - 1) / 500,
         avg(b) FILTER (WHERE lote BETWEEN v_lotes - v_k AND v_lotes - 1) / 500
    INTO v_primeros, v_ultimos
    FROM d WHERE lote >= 0;
  v_forma := v_ultimos / NULLIF(v_primeros, 0);

  -- El tiempo de cada lote.
  WITH d AS (
    SELECT lote, t - lag(t) OVER (ORDER BY lote) AS s FROM ens1561_med
  )
  SELECT (percentile_cont(0.5) WITHIN GROUP (ORDER BY s))::numeric, max(s)::numeric
    INTO v_seg_med, v_seg_max
    FROM d WHERE lote >= 0;
  v_unidades := v_seg_med / NULLIF(v_ref, 0);

  RAISE NOTICE 'medidas por producto: % bloques, % llamadas; forma (últimos/primeros lotes) %; lote mediano % s (% unidades de la referencia de % ms de este runner) y más lento % s',
    round(v_bloques, 1), round(v_llamadas, 2), round(v_forma, 2), round(v_seg_med, 2), round(v_unidades, 1), round(v_ref * 1000), round(v_seg_max, 2);

  -- Un instrumento que mide cero no mide: un gate que no puede mirar es rojo.
  IF v_bloques IS NULL OR v_bloques < 5 OR v_llamadas IS NULL OR v_llamadas < 1
     OR v_ref IS NULL OR v_ref <= 0 THEN
    v_fallas := v_fallas || format('la medida no anda (bloques %s, llamadas %s por producto, referencia %s s): el ensayo no puede mirar', v_bloques, v_llamadas, v_ref);
  END IF;
  IF v_bloques > c_bloques_x_fila THEN
    v_fallas := v_fallas || format('cada producto toca %s bloques (tope %s): algo recorre una tabla o un índice por fila, o el plan eligió otro índice', round(v_bloques, 1), c_bloques_x_fila);
  END IF;
  IF v_llamadas > c_llamadas_x_fila THEN
    v_fallas := v_fallas || format('cada producto dispara %s llamadas a funciones (tope %s): un trigger de más', round(v_llamadas, 2), c_llamadas_x_fila);
  END IF;
  IF v_forma IS NULL OR v_forma > c_forma THEN
    v_fallas := v_fallas || format('el costo crece con las filas tocadas: los últimos lotes tocan %s veces los bloques de los primeros (tope %s)', round(v_forma, 2), c_forma);
  END IF;
  IF v_unidades > c_unidades THEN
    v_fallas := v_fallas || format('el lote mediano tarda %s unidades de la referencia de este mismo runner (%s ms; tope %s): el código se puso lento, no el runner', round(v_unidades, 1), round(v_ref * 1000), c_unidades);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (el aumento masivo de precios hace más trabajo por producto que antes):\n  - %', array_to_string(v_fallas, E'\n  - ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK: % productos en % lotes de 500, cada uno como authenticated; % bloques y % llamadas por producto, sin crecer con las filas tocadas',
    v_ok, v_lotes, round(v_bloques), round(v_llamadas, 1);
END
$t$;

ROLLBACK;
