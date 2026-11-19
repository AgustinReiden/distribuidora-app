/**
 * Lo que deciden los gates que leen el catálogo directo (check-realtime,
 * check-mensajes-trigger, check-cruce-ids y los complementos de check-rol-sin-activo,
 * check-rpcs-definer y check-tablas-anon).
 * Puro y sin dependencias: los scripts corren en CI sin node_modules, y los casos
 * viven en src/test/catalogo.test.ts.
 */

// -------------------------------------------------------------- Realtime ---

/** Qué tiene de malo una tabla publicada en Realtime (lista vacía = nada). */
export function problemasDeTabla(t) {
  const p = [];
  if (!t.rls) p.push('no tiene RLS: Realtime la manda entera');
  if (t.anon_algo) p.push('anon tiene SELECT (de tabla o de columna)');
  if (t.auth_columnas && !t.auth_tabla) {
    p.push(
      'authenticated la lee sólo por columnas (SELECT por columna): Realtime lee la fila entera, ' +
        'así que las columnas sin permiso viajarían por el canal',
    );
  }
  if (!t.auth_columnas && !t.auth_tabla) p.push('authenticated no la lee: no tiene nada que hacer en la publicación');
  return p;
}

// ---------------------------------------------------------------- Realtime ---

/**
 * La publicación de postgres_changes, `supabase_realtime`, y sus tablas. NO la otra de
 * Supabase (`supabase_realtime_messages_publication`, Broadcast): lleva las particiones
 * `realtime.messages_AAAA_MM_DD`, que cambian cada día, son de Supabase y authenticated no
 * las lee. Devuelve un jsonb {publicaciones, tablas}.
 */
export const SQL_REALTIME = String.raw`
SELECT jsonb_build_object(
  'publicaciones', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('nombre', p.pubname, 'todas', p.puballtables) ORDER BY p.pubname)
      FROM pg_publication p WHERE p.pubname = 'supabase_realtime'), '[]'::jsonb),
  'tablas', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'publicacion', pt.pubname,
             'tabla', pt.schemaname || '.' || pt.tablename,
             'rls', c.relrowsecurity,
             'columnas_publicadas', COALESCE(array_length(pt.attnames, 1), 0),
             'columnas_tabla', (SELECT count(*) FROM pg_attribute a
                                 WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
             'auth_tabla', has_table_privilege('authenticated', c.oid, 'SELECT'),
             'auth_columnas', has_any_column_privilege('authenticated', c.oid, 'SELECT'),
             'anon_algo', has_any_column_privilege('anon', c.oid, 'SELECT'))
           ORDER BY pt.pubname, pt.schemaname, pt.tablename)
      FROM pg_publication_tables pt
      JOIN pg_class c ON c.oid = (quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename))::regclass
     WHERE pt.pubname = 'supabase_realtime'), '[]'::jsonb))`;

// -------------------------------------------------- Tablas legibles por anon ---

/**
 * Lo que el RPC auditoria_tablas_anon() no ve: cuenta FILAS, así que una tabla legible
 * por anon pero vacía pasa hasta el día que tiene datos (1601-b8). Esto mira el
 * catálogo: el grant de SELECT de anon (de tabla, de columna o heredado de PUBLIC)
 * junto con lo que lo deja pasar —RLS apagada, o una policy permisiva que le aplica a
 * anon/PUBLIC y no filtra por la sesión (auth.*, current_sucursal_id(), es_*())—. Una
 * vista con SELECT de anon se marca siempre. Devuelve un jsonb: [{relacion, motivo}].
 */
export const SQL_TABLAS_ANON_CATALOGO = String.raw`
SELECT COALESCE(jsonb_agg(jsonb_build_object('relacion', x.relname, 'motivo', x.motivo) ORDER BY x.relname), '[]'::jsonb)
  FROM (
    SELECT c.relname::text,
           CASE
             WHEN c.relkind IN ('v', 'm', 'f') THEN 'anon tiene SELECT sobre una vista o tabla foránea'
             WHEN NOT c.relrowsecurity THEN 'anon tiene SELECT y la tabla no tiene RLS'
             ELSE 'anon tiene SELECT y la policy ' || (
               SELECT string_agg(pol.polname::text, ', ' ORDER BY pol.polname)
                 FROM pg_policy pol
                WHERE pol.polrelid = c.oid AND pol.polpermissive AND pol.polcmd IN ('r', '*')
                  AND (pol.polroles = '{0}'::oid[] OR (SELECT oid FROM pg_roles WHERE rolname = 'anon') = ANY (pol.polroles))
                  AND COALESCE(pg_get_expr(pol.polqual, pol.polrelid), 'true') !~* '^\(?\s*false\s*\)?$'
                  AND COALESCE(pg_get_expr(pol.polqual, pol.polrelid), 'true') !~* 'auth\.(uid|jwt|role)\s*\(|current_sucursal_id\s*\(|\mes_[a-z_]+\s*\(')
               || ' no filtra para anon'
           END AS motivo
      FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
       AND has_any_column_privilege('anon', c.oid, 'SELECT')
  ) x
 WHERE x.motivo IS NOT NULL`;

// ------------------------------------------- Rol sin activo: las _impl sin API ---

/**
 * Lo que auditoria_rol_sin_activo() no ve (1595-b4): sólo mira las funciones con
 * EXECUTE para authenticated. Las `_impl` de los pagos y de la nota de crédito
 * (migs 167 y 405b) no lo tienen —las llama su wrapper, que es DEFINER—, así que
 * leen `perfiles.rol` de quien llama sin mirar `activo` y ningún gate las miraba.
 * Es la misma consulta del RPC con la condición del permiso invertida y sin las de
 * trigger. Un desactivado conserva su token: lo que la `_impl` decide por el rol lo
 * decide con un perfil dado de baja. Devuelve un jsonb {funciones, lecturas}.
 */
export const SQL_ROL_SIN_ACTIVO_SIN_API = String.raw`
  WITH f AS (
    SELECT p.oid::regprocedure::text AS firma,
           p.prosecdef AS definer,
           regexp_replace(regexp_replace(regexp_replace(p.prosrc,
             '/\*.*?\*/', ' ', 'g'),
             '--[^\n]*', ' ', 'g'),
             '''[^'']*''', '''''', 'g') AS src
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.prokind = 'f'
       AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')
       AND p.prorettype <> 'trigger'::regtype
       AND p.prosrc ~ '\mperfiles\M'
  ), alias AS (
    SELECT f.firma, array_agg(DISTINCT lower(m[1])) AS nombres
      FROM f, regexp_matches(f.src,
             '(\w+)\s*(?:uuid\s*)?(?::=|\mDEFAULT\M)\s*\(?\s*(?:SELECT\s+)?auth\.uid\s*\(\s*\)', 'gi') AS m
     GROUP BY f.firma
  ), sentencias AS (
    SELECT f.firma, f.definer, s.texto, a.nombres
      FROM f
      LEFT JOIN alias a USING (firma)
      CROSS JOIN LATERAL regexp_split_to_table(f.src, ';') AS s(texto)
  ), lecturas AS (
    SELECT DISTINCT firma, definer, left(regexp_replace(btrim(texto), '\s+', ' ', 'g'), 200) AS lectura
      FROM sentencias
     WHERE texto ~ '\mperfiles\M'
       AND texto ~* '\mrol\M'
       AND texto !~* '\mactivo\M'
       AND (texto ~ 'auth\.uid\s*\(\s*\)'
            OR EXISTS (SELECT 1 FROM unnest(nombres) AS n WHERE texto ~* ('\m' || n || '\M')))
  )
  SELECT jsonb_build_object(
    'funciones', (SELECT count(*) FROM f),
    'lecturas', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('firma', firma, 'definer', definer, 'lectura', lectura)
                       ORDER BY firma, lectura)
        FROM lecturas), '[]'::jsonb))`;

// ---------------------------------------------------- search_path de public ---

/**
 * El search_path de una función de public (1564-b8 y 1564-g4, plan #1603 B15).
 * Sin `pg_temp` escrito, Postgres busca PRIMERO en el esquema temporal de la sesión las
 * tablas, vistas, secuencias y tipos (las funciones y los operadores, no): quien llama crea
 * una tabla temporal `perfiles` y `es_admin()`, que corre como postgres, la lee. Y una INVOKER
 * con su propio `SET search_path = public` que llama una definer (o que dispara como trigger
 * de su DML) también corre como postgres y vuelve a poner pg_temp primero (los dos casos los
 * reproduce scripts/test-search-path-ola2-1603.sql). Con `pg_temp` AL FINAL se busca último.
 *
 * La regla: una SECURITY DEFINER fija search_path, y TODA función que lo fija lo termina en
 * pg_temp. Una INVOKER sin search_path está bien: hereda el de quien la llama (dentro de una
 * definer, el de la definer), y una SQL sin SET se inlinea, que es a propósito.
 * `proconfig` es el array de pg_proc (`["search_path=public, pg_temp", …]`), que Postgres
 * guarda con los elementos separados por «, » (el vacío, como `""`). Devuelve null si está
 * bien, o el motivo.
 */
export function problemaDeSearchPath(proconfig, definer = true) {
  const sp = (proconfig ?? []).find((c) => c.startsWith('search_path='));
  if (sp === undefined) return definer ? 'es SECURITY DEFINER y no fija search_path: usa el de quien la llama' : null;
  const valor = sp.slice('search_path='.length);
  const elementos = valor.split(', ');
  if (elementos[elementos.length - 1] === 'pg_temp') return null;
  return elementos.includes('pg_temp')
    ? `su search_path (${valor}) tiene pg_temp, pero no al final`
    : `su search_path (${valor}) no termina en pg_temp`;
}

/**
 * Las funciones de public que son SECURITY DEFINER o que fijan search_path, con su proconfig.
 * Devuelve un jsonb [{firma, definer, proconfig}].
 */
export const SQL_SEARCH_PATH_FUNCIONES = String.raw`
SELECT COALESCE(jsonb_agg(jsonb_build_object('firma', p.oid::regprocedure::text,
                                             'definer', p.prosecdef,
                                             'proconfig', COALESCE(to_jsonb(p.proconfig), '[]'::jsonb))
                          ORDER BY p.oid::regprocedure::text), '[]'::jsonb)
  FROM pg_proc p
 WHERE p.pronamespace = 'public'::regnamespace
   AND (p.prosecdef OR EXISTS (SELECT 1 FROM unnest(p.proconfig) c WHERE c LIKE 'search_path=%'))`;
