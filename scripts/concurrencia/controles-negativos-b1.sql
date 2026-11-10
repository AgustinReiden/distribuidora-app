-- Control negativo de la tarjeta 1 de #1524 (#1512 COB-1, mig 479: la cancelación y la NC aplican el crédito suelto). Se
-- corre sobre la copia LOCAL de Docker con la migración aplicada. NUNCA contra prod ni contra una rama de Supabase
-- compartida: es DDL sobre `public`.
--
-- Saca el pre-bloqueo de las otras boletas: _credito_bloquea_boletas (lo llaman cancelar_pedido_con_stock y
-- crear_nota_credito_venta_impl) sigue calculando qué boletas alcanza el crédito y las devuelve (las rutas y los créditos
-- se siguen tomando), pero bloquea sólo la propia. Las otras las toma recién aplicar_credito_cliente, al final y con la
-- propia ya bloqueada: al revés que el FIFO, que las toma todas por id. B1b (X retenida) y B1f (Q retenida) tienen que
-- dar 40P01; las demás, testigos.
--
--   psql -f controles-negativos-b1.sql
--   node run.mjs b1 --variante B1b --out <dir>   (y B1f; otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_credito_bloquea_boletas'
ON CONFLICT DO NOTHING;
DO $m$
DECLARE
  d   text;
  pat text := E'    WHERE id = ANY(v_alcanza)\n';
  rep text := E'    WHERE id = p_pedido_id /* MUTADO: sólo la propia */\n';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = '_credito_bloquea_boletas';
  IF d IS NULL THEN
    RAISE EXCEPTION '_credito_bloquea_boletas no existe (¿falta la migración 479?)';
  END IF;
  IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
    RAISE EXCEPTION '_credito_bloquea_boletas: el patrón no aparece una sola vez';
  END IF;
  EXECUTE replace(d, pat, rep);
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
