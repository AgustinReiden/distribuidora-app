-- Controles negativos del arnés de concurrencia (#1288, plan #1378 tarjeta 1). Grupo 2: el ORDEN de los locks de productos.
-- El grupo 1, los locks de pagos y de stock, está en controles-negativos.sql. NO se corren juntos (ver M2 allá).
--
-- Las variantes forzadas de C9 y C10 sólo dicen algo si, rompiendo el orden, se ponen rojas. Acá se cambia el
-- `ORDER BY id` del lock de productos de tres funciones de la copia LOCAL de Docker por `ORDER BY id DESC`.
-- NUNCA contra prod ni contra una rama de Supabase compartida: es DDL sobre funciones de `public`.
--
--   1. psql -f controles-negativos-orden.sql   (guarda las definiciones originales en conc.mut_orig)
--   2. node run.mjs c9 --variante C9b --out <dir>      → 40P01 en las 100 rondas (la venta sube por id, la edición baja)
--      node run.mjs c10 --variante C10b --out <dir>    → 40P01 (sustituir lockea de mayor a menor)
--      node run.mjs c10 --variante C10d --out <dir>    → 40P01 (dividir)
--      (Una carpeta --out por variante.) C9a, C10a y C10c, de arranque simultáneo, caen en la ventana sólo a veces.
--      C9c (venta con los productos en el JSON como [B,A]) da lo mismo que C9b: la venta ordena por id adentro.
--   3. RESTAURAR (en controles-negativos.sql) y repetir `docker-local.mjs huella`: cero diferencias.
--
-- Qué se rompe:
--   M3  actualizar_pedido_items(): el lock de los productos pasa de `ORDER BY id` a `ORDER BY id DESC` (#1296).
--   M4  sustituir_regalo_pedido(): lo mismo (#1326).
--   M5  dividir_regalo_pedido(): lo mismo (#1326).

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname IN ('actualizar_pedido_items', 'sustituir_regalo_pedido', 'dividir_regalo_pedido')
ON CONFLICT DO NOTHING;
-- El patrón tiene que aparecer una sola vez (los demás ORDER BY de esas funciones no son el lock de productos).
DO $m$
DECLARE d text; pat text; f text;
BEGIN
  FOR f, pat IN SELECT * FROM (VALUES
      ('actualizar_pedido_items(%', '(v_sucursal\) c\)\s*ORDER BY id)(\s*FOR UPDATE;)'),
      ('sustituir_regalo_pedido(%', '(_contenedores_de_promos\(ARRAY\[v_item\.promocion_id\], v_sucursal\) c\)\s*ORDER BY id)(\s*FOR UPDATE;)'),
      ('dividir_regalo_pedido(%',   '(_contenedores_de_promos\(ARRAY\[v_item\.promocion_id\], v_sucursal\) c\)\s*ORDER BY id)(\s*FOR UPDATE;)')) v(f, pat)
  LOOP
    SELECT def INTO d FROM conc.mut_orig WHERE firma LIKE f;
    IF regexp_count(d, pat) <> 1 THEN RAISE EXCEPTION '%: el lock de productos aparece % veces, esperaba 1', f, regexp_count(d, pat); END IF;
    EXECUTE regexp_replace(d, pat, '\1 DESC /* MUTADO */\2');
  END LOOP;
END
$m$;
