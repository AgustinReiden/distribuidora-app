-- Controles negativos de la tarjeta 2 de #1477 (#1469, mig 463c: la boleta nueva absorbe el saldo a favor). Se corren sobre
-- la copia LOCAL de Docker con la migración aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL
-- sobre `public`.
--
-- Saca los dos pre-bloqueos del alta, cada uno en su función auxiliar (los llaman crear_pedido_completo y el bot):
--   M1 _alta_bloquea_boletas_credito calcula qué boletas alcanzan los créditos (y las devuelve, para que el alta siga
--      aplicando el saldo a favor al final) pero no las lockea.
--   M2 _alta_bloquea_creditos no lockea ni los recorridos de esas boletas ni los créditos.
-- La venta sigue aplicando el saldo a favor al final (aplicar_credito_cliente), pero toma la boleta y el crédito DESPUÉS
-- del cliente (el INSERT del pedido), al revés que el FIFO y la imputación de un crédito: A2a a A2f vuelven a dar 40P01.
--   Medido (06/11, 100 rondas cada una): A2a (el cliente retenido) da 40P01 en 97 y A2d en 80; A2b (Y retenida) en 6 y
--   A2e (C retenida) en 8. A2c, A2f (sin forzar) y A2g (sólo crédito) dan 0: la ventana es de microsegundos. El estado
--   final es correcto en todas (el deadlock lo resuelve Postgres abortando una). A2h (cambio de cliente contra la
--   venta; A2i no se corrió) no depende de estos dos: sigue en 0 (testigo).
--
--   psql -f controles-negativos-a2.sql
--   node run.mjs a2 --out <dir>   (otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('_alta_bloquea_boletas_credito', '_alta_bloquea_creditos')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE
  d text; f text; pat text; rep text;
BEGIN
  FOR f, pat, rep IN SELECT v.f, v.pat, v.rep FROM (VALUES
      ('_alta_bloquea_boletas_credito(bigint,bigint)',
       E'    ORDER BY id\n      FOR UPDATE;\n\n  RETURN v_alcanza;',
       E'    ORDER BY id /* MUTADO: sin lock */;\n\n  RETURN v_alcanza;'),
      ('_alta_bloquea_creditos(bigint,bigint,bigint[])',
       E'    ORDER BY id\n      FOR NO KEY UPDATE;',
       E'    ORDER BY id /* MUTADO: sin lock */;'),
      ('_alta_bloquea_creditos(bigint,bigint,bigint[])',
       E'    ORDER BY id\n      FOR UPDATE;\nEND;',
       E'    ORDER BY id /* MUTADO: sin lock */;\nEND;')
    ) v(f, pat, rep)
  LOOP
    -- la segunda mutación de _alta_bloquea_creditos parte de la función ya mutada
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.oid::regprocedure::text = f;
    IF d IS NULL THEN
      RAISE EXCEPTION '%: no existe (¿falta la migración 463c?)', f;
    END IF;
    IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
      RAISE EXCEPTION '%: el patrón no aparece una sola vez', f;
    END IF;
    EXECUTE replace(d, pat, rep);
  END LOOP;
END
$m$;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
