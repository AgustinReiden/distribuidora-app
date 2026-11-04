-- Controles negativos del arnés de concurrencia (#1288, plan #1378). Grupo 4: el lock de las promos de la venta (#1398 y
-- #1442, tarjeta 12). No se corre junto con los otros grupos.
--
-- Va DESPUÉS de aplicar la migración de #1398 en la copia LOCAL de Docker, y con la 451 aplicada (el sello del modo en la
-- línea). Saca de crear_pedido_completo y del bot el `PERFORM 1 FROM promociones ... FOR UPDATE` que bloquea las promos de
-- los regalos antes del bucle de productos, y deja el de productos y contenedores. Es la venta de antes de la migración en
-- lo que toca a las promos. NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre `public`.
--
--   1. psql -f controles-negativos-promos.sql   (guarda las definiciones originales en conc.mut_orig)
--   2. node run.mjs c12 --variante C12k2 --out <dir>  → 40P01: cada venta toma las promos en el orden de sus líneas
--      node run.mjs c12 --variante C12m --out <dir>   → 40001 de trg_verificar_modo_regalo_item: la línea se selló con el
--                                                       modo viejo y la foto se tomó con el nuevo (#1442)
--      (Una carpeta --out por variante.)
--   3. RESTAURAR (en controles-negativos.sql) y repetir `docker-local.mjs huella`.
--
-- Qué se rompe:
--   M8  crear_pedido_completo(): sin el pre-bloqueo de las promos.
--   M9  crear_pedido_completo_bot(): lo mismo.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('crear_pedido_completo', 'crear_pedido_completo_bot')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE d text; pat text := 'PERFORM 1 FROM promociones\s+WHERE sucursal_id = [a-z_.]+ AND id = ANY \(v_promos_regalo\)\s+ORDER BY id\s+FOR UPDATE;'; f text;
BEGIN
  FOR f IN SELECT unnest(ARRAY['crear_pedido_completo(bigint,%', 'crear_pedido_completo_bot(%']) LOOP
    SELECT def INTO d FROM conc.mut_orig WHERE firma LIKE f;
    IF regexp_count(d, pat) <> 1 THEN RAISE EXCEPTION '%: el pre-bloqueo de promos aparece % veces, esperaba 1', f, regexp_count(d, pat); END IF;
    EXECUTE regexp_replace(d, pat, '/* MUTADO: sin el lock de las promos */');
  END LOOP;
END
$m$;
