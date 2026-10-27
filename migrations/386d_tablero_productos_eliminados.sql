-- Tablero: un producto borrado ya no saca su venta de las categorías ni de la ficha.
--
-- Se aplicó directo en prod (ledger 20261023000252, name 'tablero_productos_eliminados') sin pasar por el repo.
-- Este archivo es el SQL de supabase_migrations.schema_migrations.statements, sin
-- tocar (md5 582a34486da81c1fb0fcf9ce8673750a), para que el drift-check lo encuentre. El número 386x
-- lo ubica entre la 386 (2026-10-16) y la 387 (2026-10-26), que es cuando corrió.
-- El aislamiento de metas_cobertura_zona.zona_id lo arregla la 393.

DO $$
DECLARE
  f text;
  d text;
BEGIN
  FOREACH f IN ARRAY ARRAY[
    'public.tablero_categorias(bigint, date, date, bigint)',
    'public.tablero_productos_categoria(uuid, text, bigint, date, date, bigint)',
    'public.tablero_ficha_cliente(bigint)'
  ] LOOP
    d := pg_get_functiondef(f::regprocedure);
    d := regexp_replace(d, '(\s)JOIN productos pr(\s+)ON pr\.id = pi\.producto_id', '\1LEFT JOIN productos pr ON pr.id = pi.producto_id', 'g');
    d := replace(d, 'pr.nombre AS producto', $r$COALESCE(pr.nombre, 'Producto eliminado #' || pi.producto_id) AS producto$r$);
    EXECUTE d;
  END LOOP;
END $$;
