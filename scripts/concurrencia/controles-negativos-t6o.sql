-- Control negativo de T6o (#1501, punto 1). Se corre sobre la copia LOCAL de Docker con la migración del arreglo aplicada
-- (476_guardar_promo_sin_releer_contenedores). NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre
-- `public`.
--
--   M65 promo_factor_bloquea_contenedores ignora el aviso app.promo_contenedores_tomados que le deja
--       cambiar_regalo_promocion durante su UPDATE: vuelve a leer la lista de contenedores de la sucursal con la promo
--       ya tomada, que es el cuerpo de la 472. T6o vuelve a dar 40P01 en todas las rondas (la RPC que guarda P1 toma el
--       contenedor nuevo CN después de su promo, contra la venta que tiene CN y espera el contenedor de P1).
--       La verificación de la RPC (lo que piden los triggers de fila ya está en lo que tomó) queda: lo único que se saca
--       es que el trigger la escuche.
--
--   psql -f controles-negativos-t6o.sql
--   node run.mjs t6 --variante T6o --out <dir>   (otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias contra prod más la migración.
--
-- Medido el 07/11 (base = prod hasta la 474 + la migración del arreglo), 100 rondas cada una:
--   sin el arreglo (prod), T6o: 100/100 correctas y 100 40P01;
--   con el arreglo, T6o: 100/100 y 0 40P01;
--   con el arreglo y M65, T6o: 100/100 y 100 40P01 (víctima: la RPC que guarda P1, en promo_factor_bloquea_contenedores
--   esperando CN).

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('promo_factor_bloquea_contenedores')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE
  d text := pg_get_functiondef('public.promo_factor_bloquea_contenedores()'::regprocedure);
  pat text := $p$IF COALESCE(current_setting('app.promo_contenedores_tomados', true), '') <> '' THEN$p$;
  rep text := $p$IF false /* MUTADO */ AND COALESCE(current_setting('app.promo_contenedores_tomados', true), '') <> '' THEN$p$;
BEGIN
  IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
    RAISE EXCEPTION 'M65: el aviso no aparece una sola vez (¿falta la migración del arreglo de #1501?)';
  END IF;
  EXECUTE replace(d, pat, rep);
END
$m$;

-- ===== RESTAURAR (correr aparte, después de la variante) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
