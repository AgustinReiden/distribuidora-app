-- Controles negativos de la tarjeta 10 de #1378 (#1439, #1424). Se corren sobre la copia LOCAL de Docker con la
-- migración de la tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
-- La corrida de antes de la migración (las funciones de prod) es el control negativo de cada arreglo: cada variante
-- de `t10` cruza una función, y con el cuerpo viejo da 40P01. Acá se sacan dos PARTES del arreglo que esa corrida no
-- distingue, para ver que cada una hace falta:
--
--   1. psql -f controles-negativos-t10.sql   (guarda las definiciones en conc.mut_orig)
--   2. node run.mjs t10 --variante T10b --out <dir>     → 40P01 en casi todas las rondas
--      node run.mjs t10 --variante T10g --out <dir>     → 40P01 en casi todas las rondas
--      (una carpeta --out por variante)
--   3. RESTAURAR (en controles-negativos.sql) y repetir `docker-local.mjs huella`.
--
-- Qué se rompe:
--   M6  aplicar_credito_cliente(): se saca el pre-bloqueo de las boletas y de sus recorridos (queda el de los
--       créditos por id). Con imputar_credito_a_pedido_impl tomando la boleta antes que el crédito, la edición que
--       ya tiene el crédito pide la boleta que la imputación tomó: T10b.
--   M7  registrar_pago_cliente_fifo_impl(): se saca el pre-bloqueo de los recorridos (queda el de las boletas). Los
--       pagos llegan a las rutas en el orden del bucle (fecha, id) y no por id: T10g.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('aplicar_credito_cliente', 'registrar_pago_cliente_fifo_impl')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE d text; f text; pat text; rep text;
BEGIN
  FOR f, pat, rep IN SELECT * FROM (VALUES
      ('aplicar_credito_cliente(%',          'WHERE id = ANY(v_alcanza)',                        'WHERE false /* MUTADO */ AND id = ANY(v_alcanza)'),
      ('aplicar_credito_cliente(%',          'WHERE rp.pedido_id = ANY(v_alcanza))',             'WHERE false /* MUTADO */ AND rp.pedido_id = ANY(v_alcanza))'),
      ('registrar_pago_cliente_fifo_impl(%', E'FROM recorridos\n    WHERE id IN',                E'FROM recorridos\n    WHERE false /* MUTADO */ AND id IN')) v(f, pat, rep)
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO d FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.oid::regprocedure::text LIKE f;
    IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
      RAISE EXCEPTION '%: "%" no aparece una sola vez (¿está aplicada la migración de la tarjeta 10?)', f, pat;
    END IF;
    EXECUTE replace(d, pat, rep);
  END LOOP;
END
$m$;
