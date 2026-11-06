-- Controles negativos de la tarjeta 6 de #1477 (#1473), grupo 2: ADV-1. Se corren sobre la copia LOCAL de Docker con
-- la migración de la tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre
-- `public`.
--
--   M64 cambiar_cliente_pedido no pre-bloquea los productos ni las promos (ni los de X ni los de los ítems nuevos):
--       vuelve el orden de la 459, boletas → rutas → pagos antes que los productos, que toma después la cancelación.
--       T6a y T6b vuelven a dar 40P01 en casi todas las rondas, y T6c (sin forzar) en una parte. T6d y T6e también
--       (sin productos en el pre-bloqueo tampoco están los nuevos).
-- No va con controles-negativos-t6.sql: M61 toca la misma función.
--
--   psql -f controles-negativos-t6b.sql
--   node run.mjs t6 --out <dir>   (otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('cambiar_cliente_pedido')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE
  d text; f text; pat text; rep text;
BEGIN
  FOR f, pat, rep IN SELECT v.f, v.pat, v.rep FROM (VALUES
      ('cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
       E'  PERFORM 1\n     FROM productos\n    WHERE sucursal_id = v_sucursal\n      AND id IN (SELECT pi.producto_id FROM pedido_items pi',
       E'  PERFORM 1\n     FROM productos\n    WHERE false /* MUTADO */ AND sucursal_id = v_sucursal\n      AND id IN (SELECT pi.producto_id FROM pedido_items pi'),
      ('cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
       E'  PERFORM 1\n     FROM promociones\n    WHERE sucursal_id = v_sucursal\n      AND id = ANY(v_promos)',
       E'  PERFORM 1\n     FROM promociones\n    WHERE false /* MUTADO */ AND sucursal_id = v_sucursal\n      AND id = ANY(v_promos)')
    ) v(f, pat, rep)
  LOOP
    d := pg_get_functiondef(f::regprocedure);
    IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
      RAISE EXCEPTION '%: el patrón no aparece una sola vez (¿falta la migración de la tarjeta 6?)', f;
    END IF;
    EXECUTE replace(d, pat, rep);
  END LOOP;
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
