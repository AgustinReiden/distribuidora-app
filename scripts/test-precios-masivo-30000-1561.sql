-- Ensayo de CAT-6 (#1561, plan #1565 tarjeta 10): un aumento a 30.000 productos termina sin
-- cortarse, mandado de a lotes como lo manda la pantalla (LOTE_PRECIOS_MASIVO = 500).
--
-- No es un único DO como los demás ensayos: el statement_timeout mide cada SENTENCIA, y un DO es
-- una. Acá cada lote es su propia sentencia (con \gexec de psql), como cada llamada por PostgREST,
-- con el timeout de `authenticated` (8 s) y como `authenticated`. Todo va en una transacción que se
-- deshace al final: no deja rastro (salvo valores de secuencia).
--
-- Corre con psql, después de aplicar la migración:
--   docker exec -i <contenedor> psql -U postgres -v ON_ERROR_STOP=1 < scripts/test-precios-masivo-30000-1561.sql
-- Con ON_ERROR_STOP, un lote que se corta (57014) para todo: el ensayo falla. El final es un DO que
-- comprueba los 30.000 precios y termina en 'ENSAYO OK', o en el motivo.
-- Antes del arreglo: una sola llamada con los 30.000 se cortaba a los 8 s (57014).
-- También comprueba que esa llamada única hoy se rechaza en el acto, con su motivo.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE TEMP TABLE ens1561_ctx ON COMMIT DROP AS
SELECT p.id AS admin_id, us.sucursal_id
  FROM perfiles p
  JOIN usuario_sucursales us ON us.usuario_id = p.id
  JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
 WHERE p.rol = 'admin' AND p.activo
 ORDER BY us.sucursal_id, p.id
 LIMIT 1;

INSERT INTO productos (nombre, precio, stock, sucursal_id)
SELECT 'ENS1561 masivo ' || g, 10, 0, (SELECT sucursal_id FROM ens1561_ctx)
  FROM generate_series(1, 30000) g;

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
SET LOCAL statement_timeout = '8s';

-- La llamada única de antes: hoy se rechaza en el acto, sin cortarse.
INSERT INTO ens1561_res
SELECT -1, public.actualizar_precios_masivo((SELECT jsonb_agg(item) FROM ens1561_lotes));

-- Un lote por sentencia, como la pantalla.
SELECT format($q$INSERT INTO ens1561_res
  SELECT %1$s, public.actualizar_precios_masivo((SELECT jsonb_agg(item) FROM ens1561_lotes WHERE lote = %1$s))$q$, lote)
  FROM (SELECT DISTINCT lote FROM ens1561_lotes ORDER BY lote) l
\gexec

RESET statement_timeout;
RESET ROLE;

DO $t$
DECLARE
  v_unica jsonb := (SELECT r FROM ens1561_res WHERE lote = -1);
  v_lotes int := (SELECT count(*) FROM ens1561_res WHERE lote >= 0);
  v_ok int := (SELECT sum((r->>'actualizados')::int) FROM ens1561_res WHERE lote >= 0);
  v_mal int := (SELECT count(*) FROM ens1561_res WHERE lote >= 0 AND NOT (r->>'success')::boolean);
  v_precios int := (SELECT count(*) FROM productos WHERE nombre LIKE 'ENS1561 masivo %' AND precio = 25 AND precio_sin_iva = 20.66);
BEGIN
  IF (v_unica->>'actualizados')::int <> 0 OR v_unica->'errores'->>0 NOT LIKE '%de a lotes%' THEN
    RAISE EXCEPTION 'la llamada única no se rechazó con su motivo: %', v_unica;
  END IF;
  IF v_lotes <> 60 OR v_ok <> 30000 OR v_mal <> 0 OR v_precios <> 30000 THEN
    RAISE EXCEPTION 'lotes %, actualizados %, lotes con error %, precios nuevos %', v_lotes, v_ok, v_mal, v_precios;
  END IF;
  RAISE EXCEPTION 'ENSAYO OK: 30.000 productos en 60 lotes de 500, cada uno como authenticated con statement_timeout de 8 s';
END
$t$;

ROLLBACK;
