-- Controles negativos del arnés de concurrencia (#1288, plan #1378). Grupo 3: el lock de los contenedores de la venta
-- (#1398, tarjeta 12). Los grupos 1 y 2 están en controles-negativos.sql y controles-negativos-orden.sql; no se corren juntos.
--
-- Va DESPUÉS de aplicar la migración de #1398 en la copia LOCAL de Docker: cambia el `ORDER BY id` del pre-bloqueo de
-- productos y contenedores de crear_pedido_completo y crear_pedido_completo_bot por `ORDER BY id DESC`. La medición de
-- antes de la migración es el otro control (sin el pre-bloqueo); éste muestra que no alcanza con tomarlos juntos: tiene
-- que ser en el orden de los demás. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
--   1. psql -f controles-negativos-contenedores.sql   (guarda las definiciones originales en conc.mut_orig)
--   2. node run.mjs c12 --variante C12b --out <dir>   → 40P01: la venta toma S y C de mayor a menor, la cancelación de menor
--      node run.mjs c12 --variante C12e --out <dir>   → lo mismo con el bot
--      (Una carpeta --out por variante.)
--   3. RESTAURAR (en controles-negativos.sql) y repetir `docker-local.mjs huella`: cero diferencias contra prod con la
--      migración aplicada.
--
-- Qué se rompe:
--   M6  crear_pedido_completo(): el pre-bloqueo de productos y contenedores pasa a `ORDER BY id DESC`.
--   M7  crear_pedido_completo_bot(): lo mismo.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('crear_pedido_completo', 'crear_pedido_completo_bot')
ON CONFLICT DO NOTHING;
-- El patrón tiene que aparecer una sola vez (el lock de las promos, que viene después, no lleva contenedores).
DO $m$
DECLARE d text; pat text := '(_contenedores_de_promos\(v_promos_regalo, [a-z_.]+\) c\)\s*ORDER BY id)(\s*FOR UPDATE;)'; f text;
BEGIN
  FOR f IN SELECT unnest(ARRAY['crear_pedido_completo(bigint,%', 'crear_pedido_completo_bot(%']) LOOP
    SELECT def INTO d FROM conc.mut_orig WHERE firma LIKE f;
    IF regexp_count(d, pat) <> 1 THEN RAISE EXCEPTION '%: el pre-bloqueo aparece % veces, esperaba 1', f, regexp_count(d, pat); END IF;
    EXECUTE regexp_replace(d, pat, '\1 DESC /* MUTADO */\2');
  END LOOP;
END
$m$;
