-- Huella del schema `public` de una base, para comparar la local de Docker contra prod
-- sin pasar el schema entero por ningún lado (#1288, plan #1378 tarjeta 1).
--
-- Es SOLO LECTURA: sirve igual contra prod (por el MCP, execute_sql) que contra la
-- base local (docker-local.mjs la corre). La comparación es en tres etapas, de
-- menos a más detalle, y cada etapa cambia sólo la última sentencia (el `SELECT`
-- que sigue al CTE `items`):
--
--   ETAPA 1 (por categoría):  SELECT cat, count(*) n, md5(string_agg(key || '=' || val, '|' ORDER BY key)) h
--                               FROM items GROUP BY cat ORDER BY cat
--   ETAPA 2 (por cubo, de una categoría que difiere):
--                             SELECT substr(md5(key), 1, 2) b, count(*) n, md5(string_agg(key || '=' || val, '|' ORDER BY key)) h
--                               FROM items WHERE cat = '<cat>' GROUP BY 1 ORDER BY 1
--   ETAPA 3 (los ítems de los cubos que difieren):
--                             SELECT key, md5(val) FROM items WHERE cat = '<cat>' AND substr(md5(key), 1, 2) IN (...)
--
-- Cada ítem es una clave estable (nombre calificado) y un valor que cambia si cambia
-- el objeto. Las funciones se comparan por md5(prosrc) más su ACL y sus atributos.
WITH items(cat, key, val) AS (
  -- funciones: cuerpo (md5(prosrc)), ACL, SECURITY DEFINER, volatilidad, search_path
  SELECT 'funcion', p.oid::regprocedure::text,
         md5(p.prosrc) || '/' || COALESCE(p.proacl::text, '') || '/' || p.prosecdef::text || '/' || p.provolatile::text || '/' || COALESCE(p.proconfig::text, '')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'
  UNION ALL
  -- columnas: tipo, null, default, identidad
  SELECT 'columna', c.table_name || '.' || c.column_name,
         c.data_type || '/' || c.is_nullable || '/' || COALESCE(c.column_default, '') || '/' || c.is_identity || '/' || COALESCE(c.character_maximum_length::text, '') || '/' || COALESCE(c.numeric_precision::text, '') || '/' || COALESCE(c.numeric_scale::text, '')
    FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
   WHERE c.table_schema = 'public'
  UNION ALL
  -- Los CHECK se comparan sin paréntesis ni casts a text/varchar: el dump de prod trae `(ARRAY['a'::varchar, ..])::text[]`
  -- y al releerlo el parser de 17.6 lo guarda como `ARRAY[('a'::varchar)::text, ..]` (y aplana `(a AND b) AND c`).
  -- Es el mismo predicado impreso distinto; con el texto crudo 17 de 219 CHECK no coinciden.
  SELECT 'constraint', cl.relname || '.' || co.conname,
         CASE WHEN co.contype = 'c' THEN regexp_replace(regexp_replace(pg_get_constraintdef(co.oid), '::(character varying|text)(\[\])?', '', 'g'), '[()[:space:]]', '', 'g')
              ELSE pg_get_constraintdef(co.oid) END
    FROM pg_constraint co JOIN pg_class cl ON cl.oid = co.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE n.nspname = 'public'
  UNION ALL
  SELECT 'indice', i.indexname, i.indexdef FROM pg_indexes i WHERE i.schemaname = 'public'
  UNION ALL
  SELECT 'trigger', c.relname || '.' || t.tgname, pg_get_triggerdef(t.oid)
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND NOT t.tgisinternal
  UNION ALL
  SELECT 'policy', p.tablename || '.' || p.policyname,
         p.cmd || '/' || COALESCE(p.roles::text, '') || '/' || COALESCE(p.qual, '') || '/' || COALESCE(p.with_check, '')
    FROM pg_policies p WHERE p.schemaname = 'public'
  UNION ALL
  SELECT 'vista', v.viewname, md5(v.definition) FROM pg_views v WHERE v.schemaname = 'public'
  UNION ALL
  -- permisos de tabla y de columna (productos se concede columna por columna)
  SELECT 'acl_tabla', c.relname, COALESCE(c.relacl::text, '') || '/' || c.relrowsecurity::text || '/' || c.relkind::text
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p', 'S')
  UNION ALL
  SELECT 'acl_columna', c.relname || '.' || a.attname, a.attacl::text
    FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND a.attacl IS NOT NULL AND NOT a.attisdropped
  UNION ALL
  SELECT 'tipo', t.typname, COALESCE((SELECT string_agg(e.enumlabel, ',' ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid), t.typtype::text)
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd')
  UNION ALL
  SELECT 'extension', e.extname, e.extversion FROM pg_extension e
  UNION ALL
  -- triggers sobre auth.users: el alta de usuarios depende de ellos
  SELECT 'trigger_auth', t.tgname, pg_get_triggerdef(t.oid)
    FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'auth' AND c.relname = 'users' AND NOT t.tgisinternal
)
SELECT cat, count(*) AS n, md5(string_agg(key || '=' || val, '|' ORDER BY key)) AS h FROM items GROUP BY cat ORDER BY cat
