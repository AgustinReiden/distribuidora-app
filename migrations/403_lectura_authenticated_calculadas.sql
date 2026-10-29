-- 403 · auditoria_lectura_authenticated() informa también los campos calculados.
--
-- La 402 le dio a scripts/check-embeds.mjs el mapa de lo que authenticated puede
-- leer de cada tabla, pero sólo con columnas. La primera corrida en CI dio 12
-- falsos rojos: `deuda_previa` y `deuda_previa_detalle` de pedidos son campos
-- calculados de PostgREST (una función f(pedidos) en public que se pide en el
-- select como si fuera una columna) y el gate los daba por inexistentes. Para
-- authenticated un campo calculado no es un grant de columna sino EXECUTE sobre
-- la función: sin él, la consulta entera da 42501 igual que una columna sin
-- SELECT. Ahora cada tabla trae `calculadas`: { nombre: authenticated ejecuta }.
--
-- Sólo cambia esta función, que es de server (service_role) y no la usa nada
-- más que el gate.

CREATE OR REPLACE FUNCTION public.auditoria_lectura_authenticated()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'tablas', (
      SELECT COALESCE(jsonb_object_agg(c.relname, jsonb_build_object(
               'columnas', (SELECT COALESCE(jsonb_agg(a.attname ORDER BY a.attnum), '[]'::jsonb)
                              FROM pg_attribute a
                             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
               'legibles', (SELECT COALESCE(jsonb_agg(a.attname ORDER BY a.attnum), '[]'::jsonb)
                              FROM pg_attribute a
                             WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                               AND has_column_privilege('authenticated', c.oid, a.attnum, 'SELECT')),
               -- Campos calculados: funciones de public con un único argumento
               -- del tipo fila de la tabla, que PostgREST expone como columnas.
               'calculadas', (SELECT COALESCE(jsonb_object_agg(p.proname,
                                       has_function_privilege('authenticated', p.oid, 'EXECUTE')), '{}'::jsonb)
                                FROM pg_proc p
                               WHERE p.pronamespace = n.oid AND p.pronargs = 1
                                 AND p.proargtypes[0] = c.reltype)
             )), '{}'::jsonb)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
    ),
    'fks', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'nombre',       con.conname,
               'tabla',        cl.relname,
               'columnas',     (SELECT jsonb_agg(a.attname ORDER BY k.ord)
                                  FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                                  JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum),
               'ref_tabla',    rf.relname,
               'ref_columnas', (SELECT jsonb_agg(a.attname ORDER BY k.ord)
                                  FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                                  JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum)
             ) ORDER BY con.conname), '[]'::jsonb)
        FROM pg_constraint con
        JOIN pg_class cl ON cl.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = cl.relnamespace
        JOIN pg_class rf ON rf.oid = con.confrelid
       WHERE con.contype = 'f' AND n.nspname = 'public'
    )
  );
$function$;

REVOKE ALL ON FUNCTION public.auditoria_lectura_authenticated() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_lectura_authenticated() TO service_role;
