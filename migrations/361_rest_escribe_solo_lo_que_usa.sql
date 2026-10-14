-- #1134 y #1135 (primera tanda) · Por REST se escribe sólo lo que el front
-- escribe; anon no tiene nada; las tablas nuevas nacen cerradas.
--
-- EL BUG
--   El baseline le hizo GRANT ALL a anon y a authenticated en cada tabla, vista
--   y secuencia de public (incluidos TRUNCATE, REFERENCES, TRIGGER y MAINTAIN),
--   y el ALTER DEFAULT PRIVILEGES de postgres hace lo mismo con cada tabla
--   nueva. Lo único que frenaba la escritura eran las policies, y varias dejan
--   escribir por PostgREST lo que se tendría que escribir sólo por una RPC:
--   · #1134 · mt_stock_historico_insert deja a un admin (o a un depósito)
--     hacer POST /stock_historico con cualquier origen: se puede falsear el
--     ledger que leen STK-D de auditoria_integridad() y el control de stock.
--   · #1135 · el mismo patrón que #1124 (compras) y #1113 (notas): un admin
--     puede, por REST, cambiar el monto de un pago, borrar líneas o pedidos,
--     insertar mermas, salvedades, rendiciones o auditoría, y reescribir el
--     historial de un pedido, salteando las RPC DEFINER que hacen eso con sus
--     controles. ii_alicuotas, producto_medidas y cargo_conceptos las escriben
--     RPCs INVOKER (cambiar_alicuota_ii, cancelar_alicuota_programada,
--     guardar_producto_medidas, asegurar_cargo_concepto), así que sus policies
--     de escritura tenían que quedar abiertas y por REST se podía, por ejemplo,
--     borrar la alícuota vigente de un encuadre.
--   · anon conserva todo: hoy no lee ni escribe nada sólo porque ninguna
--     policy lo deja pasar (check-tablas-anon da 0), pero cualquier policy sin
--     TO lo abre (pasó con perfiles, mig 228). TRUNCATE no pasa por RLS.
--
-- EL ARREGLO (decisión del dueño, 2026-10-13: #1134 opción A, #1135 tanda A)
--   0 · auditoria_grants_tablas(): lee el catálogo y devuelve lo que anon y
--       authenticated tienen sobre cada relación de public, con el NIVEL de
--       cada escritura (tabla entera o lista de columnas). La usan el $pre$ y
--       el $verif$ de esta migración y el gate scripts/check-grants-tablas.mjs.
--   1 · anon: REVOKE ALL en tablas, vistas y secuencias (lectura incluida, y
--       los grants por columna de productos y pedido_items).
--   2 · authenticated: REVOKE TRUNCATE, REFERENCES, TRIGGER y MAINTAIN en todo.
--   3 · Las 4 RPC INVOKER de configuración pasan a SECURITY DEFINER con ALTER
--       FUNCTION (el cuerpo de prod no se toca). Así sus tablas dejan de
--       necesitar grant y policy de escritura.
--   4 · authenticated: se revoca cada (tabla, INSERT/UPDATE/DELETE) que no
--       está en la lista blanca de abajo. Lo que está en la lista NO se toca:
--       ni REVOKE ni GRANT, así queda en el nivel que tenga (tabla o columnas).
--   5 · DROP de las policies de escritura que quedan sin grant.
--   6 · #1134: stock_historico conserva el GRANT INSERT (lo escribe el trigger
--       INVOKER de la ficha) y su policy sólo admite la fila de ese trigger.
--   7 · DEFAULT PRIVILEGES de postgres en public: nada para anon; para
--       authenticated, sólo SELECT en tablas.
--
-- INVENTARIO (leído en prod y en src/ el 2026-10-13)
--   Escrituras REST del front (`.from('t').insert/update/upsert/delete` en
--   src/, sin tests; upsert = INSERT + UPDATE; la cola offline y
--   useSyncManager sólo usan RPC; las edge functions escriben con
--   service_role):
--     categorias IUD · cliente_descuentos_categoria ID · cliente_preventistas ID
--     clientes IUD · grupo_precio_escala_minimos IUD · grupo_precio_escalas IUD
--     grupo_precio_productos IUD · grupos_precio IUD · ii_encuadres IU
--     marcas IUD · pagos ID · pedidos U · perfil_roles ID · perfiles U
--     productos IUD · promocion_productos ID · promocion_reglas IUD
--     promociones IUD · proveedores IU · recorridos U · zonas IUD
--   Escritores INVOKER que corren como authenticated (prosecdef = false):
--     registrar_cambio_stock (trigger de productos) → stock_historico I: queda
--       INVOKER (STK-D, CLAUDE.md); se cubre con la policy del paso 6.
--     registrar_cambio_pedido / registrar_creacion_pedido (triggers de
--       pedidos) → pedido_historial I: quedan; su policy ya exige
--       pg_trigger_depth() > 0.
--     actualizar_saldo_pedido (trigger de pedidos) → clientes U: ya concedido.
--     cambiar_alicuota_ii, cancelar_alicuota_programada → ii_alicuotas;
--     guardar_producto_medidas → producto_medidas; asegurar_cargo_concepto →
--       cargo_conceptos: pasan a DEFINER (paso 3).
--     _mov_lotes_descontar, _mov_lotes_registrar_salida: sin EXECUTE para
--       nadie, sólo las llaman DEFINER; no necesitan grant.
--   El resto de los escritores son DEFINER de postgres (BYPASSRLS, sin FORCE
--   RLS). Las acciones de FK corren como dueño de la tabla.
--
-- NO CAMBIA
--   · Ningún cuerpo de función (sólo el atributo SECURITY de las 4 del paso 3).
--     La única función nueva es auditoria_grants_tablas(), sólo service_role.
--   · El SELECT de authenticated (tabla y columnas) y las secuencias de
--     authenticated.
--   · Las policies de SELECT y las FOR ALL (también son el SELECT de alguien).
--   · mt_pedidos_update y el nivel del UPDATE de pedidos (#1131 lo decide).
--   · service_role, postgres y los triggers.
--   · STK-F / STK-D / COSTO-D: no se mueve stock ni costo. Las 4 RPC del paso 3
--     no mueven stock (la prohibición de DEFINER de CLAUDE.md es para las que
--     lo mueven) y ya validan el rol adentro.
--
-- LO QUE QUEDA (a sabiendas; issue de segunda tanda)
--   · La lista blanca es por TABLA: donde queda UPDATE, quedan escribibles las
--     columnas derivadas. Primer caso: clientes.saldo_cuenta, que admin y
--     encargado pueden escribir por PATCH (clientes_proteger_columnas_
--     preventista sólo frena al preventista; CC-A lo ve después).
--   · El SELECT de authenticated sobre tablas que nadie lee por REST (bot_*).
--   · Las secuencias de authenticated (rwU en todas; alcanza USAGE).
--   · Las policies FOR ALL sobre tablas sin escritura REST (sucursales,
--     proveedores_eliminados, usuario_sucursales, transferencias_stock,
--     transferencia_items, promo_ajustes) y las TO public (perfiles,
--     sucursales, proveedores_eliminados).
--   · El default de supabase_admin en public no se puede cambiar desde
--     postgres: lo vigila el gate.
--   · Una query sin sesión ahora da 42501 en vez de []. Con la anon key sólo se
--     ve PGRST200/201 (PostgREST lo resuelve antes de ir a la base); un 42501
--     significa que el embed resolvió (CLAUDE.md, trampa 5).
--   · Un trigger INVOKER encadenado que cambie stock como authenticated
--     (profundidad > 1) choca con la policy de stock_historico: ruidoso, a
--     propósito.
--
-- Ensayo: scripts/test-grants-rest-1134-1135.sql (falla antes, pasa después).
-- Gate:   scripts/grants-rest.json + src/test/grantsRest.contract.test.ts
--         (front y migraciones nuevas) y scripts/check-grants-tablas.mjs (prod).
-- Ajustados en el mismo cambio: scripts/test-permisos-menores-1074.sql (el
-- DELETE de proveedores del encargado ya da 42501 por grant; sólo acepta ese
-- mensaje) y scripts/test-anular-salvedad-lote-bolsa.sql (el caso G abre el
-- grant y una policy dentro de su sub-bloque para seguir llegando al trigger
-- de lotes_devueltos). El corte por grant de los dos lo prueba el caso F del
-- ensayo de esta migración.

SET LOCAL lock_timeout = '5s';

-- ----------------------------------------------------------- lista blanca ---
-- Las escrituras de authenticated que quedan. Es la misma que
-- scripts/grants-rest.json («escrituras»); el gate compara prod contra el JSON.
CREATE TEMP TABLE _grants_rest_lista (tabla text, priv text, PRIMARY KEY (tabla, priv)) ON COMMIT DROP;
INSERT INTO _grants_rest_lista (tabla, priv) VALUES
  ('categorias', 'INSERT'), ('categorias', 'UPDATE'), ('categorias', 'DELETE'),
  ('cliente_descuentos_categoria', 'INSERT'), ('cliente_descuentos_categoria', 'DELETE'),
  ('cliente_preventistas', 'INSERT'), ('cliente_preventistas', 'DELETE'),
  ('clientes', 'INSERT'), ('clientes', 'UPDATE'), ('clientes', 'DELETE'),
  ('grupo_precio_escala_minimos', 'INSERT'), ('grupo_precio_escala_minimos', 'UPDATE'), ('grupo_precio_escala_minimos', 'DELETE'),
  ('grupo_precio_escalas', 'INSERT'), ('grupo_precio_escalas', 'UPDATE'), ('grupo_precio_escalas', 'DELETE'),
  ('grupo_precio_productos', 'INSERT'), ('grupo_precio_productos', 'UPDATE'), ('grupo_precio_productos', 'DELETE'),
  ('grupos_precio', 'INSERT'), ('grupos_precio', 'UPDATE'), ('grupos_precio', 'DELETE'),
  ('ii_encuadres', 'INSERT'), ('ii_encuadres', 'UPDATE'),
  ('marcas', 'INSERT'), ('marcas', 'UPDATE'), ('marcas', 'DELETE'),
  ('pagos', 'INSERT'), ('pagos', 'DELETE'),
  ('pedidos', 'UPDATE'),
  ('perfil_roles', 'INSERT'), ('perfil_roles', 'DELETE'),
  ('perfiles', 'UPDATE'),
  ('productos', 'INSERT'), ('productos', 'UPDATE'), ('productos', 'DELETE'),
  ('promocion_productos', 'INSERT'), ('promocion_productos', 'DELETE'),
  ('promocion_reglas', 'INSERT'), ('promocion_reglas', 'UPDATE'), ('promocion_reglas', 'DELETE'),
  ('promociones', 'INSERT'), ('promociones', 'UPDATE'), ('promociones', 'DELETE'),
  ('proveedores', 'INSERT'), ('proveedores', 'UPDATE'),
  ('recorridos', 'UPDATE'),
  ('zonas', 'INSERT'), ('zonas', 'UPDATE'), ('zonas', 'DELETE'),
  -- Las escriben triggers INVOKER como authenticated (no el front):
  ('pedido_historial', 'INSERT'),   -- registrar_cambio_pedido / registrar_creacion_pedido
  ('stock_historico', 'INSERT');    -- registrar_cambio_stock (la ficha), paso 6

-- ------------------------------------------- 0 · auditoria_grants_tablas() ---
-- Sólo lee el catálogo. Una escritura se informa con su nivel: 'tabla' (grant
-- de tabla, aclexplode de relacl) o la lista ordenada de columnas (attacl).
-- Si una misma (tabla, privilegio) tiene los dos, salen dos filas.
-- MAINTAIN no aparece en information_schema.role_table_grants: por eso relacl.
CREATE FUNCTION public.auditoria_grants_tablas()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public, pg_catalog
AS $fn$
  WITH rel AS (
    SELECT c.oid, c.relname::text AS relacion, c.relkind::text AS relkind, c.relacl,
           c.relrowsecurity, c.reloptions
      FROM pg_class c
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')
  ),
  tab AS (
    SELECT r.relacion, r.relkind, g.rolname::text AS rol, x.privilege_type::text AS priv
      FROM rel r
      CROSS JOIN LATERAL aclexplode(r.relacl) x
      JOIN pg_roles g ON g.oid = x.grantee
     WHERE g.rolname IN ('anon', 'authenticated')
  ),
  col AS (
    SELECT r.relacion, r.relkind, g.rolname::text AS rol, x.privilege_type::text AS priv,
           array_agg(a.attname::text ORDER BY a.attname::text) AS columnas
      FROM rel r
      JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
                         AND a.attacl IS NOT NULL
      CROSS JOIN LATERAL aclexplode(a.attacl) x
      JOIN pg_roles g ON g.oid = x.grantee
     WHERE g.rolname IN ('anon', 'authenticated')
     GROUP BY 1, 2, 3, 4
  ),
  todo AS (
    SELECT relacion, relkind, rol, priv, to_jsonb('tabla'::text) AS nivel FROM tab
    UNION ALL
    SELECT relacion, relkind, rol, priv, to_jsonb(columnas) FROM col
  )
  SELECT jsonb_build_object(
    'generado_at', now(),
    'anon', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('relacion', relacion, 'relkind', relkind,
                                          'privilegio', priv, 'nivel', nivel)
                       ORDER BY relacion, priv, nivel::text)
        FROM todo WHERE rol = 'anon'), '[]'::jsonb),
    'authenticated_extras', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('relacion', relacion, 'relkind', relkind,
                                          'privilegio', priv, 'nivel', nivel)
                       ORDER BY relacion, priv, nivel::text)
        FROM todo
       WHERE rol = 'authenticated' AND relkind <> 'S'
         AND priv IN ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN')), '[]'::jsonb),
    'authenticated_escrituras', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('tabla', relacion, 'privilegio', priv, 'nivel', nivel)
                       ORDER BY relacion, priv, nivel::text)
        FROM todo
       WHERE rol = 'authenticated' AND relkind <> 'S'
         AND priv IN ('INSERT', 'UPDATE', 'DELETE')), '[]'::jsonb),
    'sin_rls', COALESCE((
      SELECT jsonb_agg(relacion ORDER BY relacion)
        FROM rel WHERE relkind IN ('r', 'p') AND NOT relrowsecurity), '[]'::jsonb),
    -- Una vista sin security_invoker lee con los permisos de su dueño
    -- (postgres, BYPASSRLS); una materializada no tiene RLS.
    'vistas_sin_invoker', COALESCE((
      SELECT jsonb_agg(relacion ORDER BY relacion)
        FROM rel
       WHERE relkind = 'm'
          OR (relkind = 'v' AND NOT EXISTS (
                SELECT 1 FROM unnest(COALESCE(reloptions, '{}'::text[])) o
                 WHERE o ~* '^security_invoker=(true|on|yes|1)$'))), '[]'::jsonb),
    'policies_escritura', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('tabla', p.tablename, 'policy', p.policyname,
                                          'cmd', p.cmd, 'roles', to_jsonb(p.roles))
                       ORDER BY p.tablename, p.cmd, p.policyname)
        FROM pg_policies p
       WHERE p.schemaname = 'public' AND p.cmd <> 'SELECT'), '[]'::jsonb),
    'default_acl', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('owner', pg_get_userbyid(d.defaclrole),
                                          'objtipo', d.defaclobjtype::text,
                                          'grantee', CASE WHEN x.grantee = 0 THEN 'PUBLIC'
                                                          ELSE pg_get_userbyid(x.grantee) END,
                                          'privilegio', x.privilege_type)
                       ORDER BY pg_get_userbyid(d.defaclrole), d.defaclobjtype::text,
                                x.grantee, x.privilege_type)
        FROM pg_default_acl d
        CROSS JOIN LATERAL aclexplode(d.defaclacl) x
       WHERE d.defaclnamespace = 'public'::regnamespace), '[]'::jsonb)
  );
$fn$;

COMMENT ON FUNCTION public.auditoria_grants_tablas() IS
  '#1135 · Grants de tabla de anon y authenticated en public, con el nivel (tabla o columnas) de cada escritura. Sólo service_role (scripts/check-grants-tablas.mjs).';

-- Función de server (CI con service_role): las tres mitades (CLAUDE.md).
REVOKE ALL ON FUNCTION public.auditoria_grants_tablas() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_grants_tablas() TO service_role;

-- ------------------------------------------------------- precondiciones ---
CREATE TEMP TABLE _grants_rest_pre (clave text PRIMARY KEY, valor jsonb) ON COMMIT DROP;

DO $pre$
DECLARE
  v_escritores text[];
  v_esperados  text[] := ARRAY[
    '_mov_lotes_descontar', '_mov_lotes_registrar_salida', 'actualizar_saldo_pedido',
    'asegurar_cargo_concepto', 'cambiar_alicuota_ii', 'cancelar_alicuota_programada',
    'guardar_producto_medidas', 'registrar_cambio_pedido', 'registrar_cambio_stock',
    'registrar_creacion_pedido'];
  v_fn   text;
  v_falta text[];
  v_g    jsonb := public.auditoria_grants_tablas();
BEGIN
  -- Escritores INVOKER de public. La regex se ancla al objeto escrito y sólo
  -- cuenta capturas que son relaciones de public: así no la disparan los
  -- comentarios ("UPDATE directo") ni el DO UPDATE SET de un ON CONFLICT.
  SELECT array_agg(DISTINCT f.proname::text ORDER BY f.proname::text) INTO v_escritores
    FROM pg_proc f
    CROSS JOIN LATERAL regexp_matches(f.prosrc, '(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(public\.)?(\w+)', 'gi') m
    JOIN pg_class c ON c.relname = lower(m[3]) AND c.relnamespace = 'public'::regnamespace
                   AND c.relkind IN ('r', 'p', 'v')
   WHERE f.pronamespace = 'public'::regnamespace
     AND NOT f.prosecdef
     AND f.prolang IN (SELECT oid FROM pg_language WHERE lanname IN ('plpgsql', 'sql'));
  IF v_escritores IS DISTINCT FROM v_esperados THEN
    RAISE EXCEPTION '#1135 · los escritores INVOKER de public cambiaron: sobran %, faltan %',
      ARRAY(SELECT unnest(v_escritores) EXCEPT SELECT unnest(v_esperados)),
      ARRAY(SELECT unnest(v_esperados) EXCEPT SELECT unnest(v_escritores));
  END IF;

  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.registrar_cambio_stock()'::regprocedure) THEN
    RAISE EXCEPTION '#1134 · registrar_cambio_stock ya es DEFINER: la policy de la ficha no aplica';
  END IF;

  FOREACH v_fn IN ARRAY ARRAY[
    'public.cambiar_alicuota_ii(bigint,numeric,date)',
    'public.cancelar_alicuota_programada(bigint)',
    'public.guardar_producto_medidas(jsonb)',
    'public.asegurar_cargo_concepto(text,integer,text,boolean,boolean,text,bigint)'] LOOP
    IF to_regprocedure(v_fn) IS NULL THEN
      RAISE EXCEPTION '#1135 · no existe %', v_fn;
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_fn)) THEN
      RAISE EXCEPTION '#1135 · % ya es DEFINER', v_fn;
    END IF;
    -- Van a pasar a DEFINER: sin search_path fijo, o con otro dueño, serían un
    -- hueco de escalada. Se exige antes del ALTER, no se supone.
    IF NOT EXISTS (SELECT 1 FROM pg_proc f, unnest(f.proconfig) c
                    WHERE f.oid = to_regprocedure(v_fn) AND c ~ '^search_path=') THEN
      RAISE EXCEPTION '#1135 · % no tiene SET search_path: no pasa a DEFINER así', v_fn;
    END IF;
    IF (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = to_regprocedure(v_fn)) <> 'postgres' THEN
      RAISE EXCEPTION '#1135 · % no es de postgres: no pasa a DEFINER así', v_fn;
    END IF;
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_fn), 'EXECUTE')
       OR has_function_privilege('anon', to_regprocedure(v_fn), 'EXECUTE') THEN
      RAISE EXCEPTION '#1135 · % no tiene el EXECUTE esperado (authenticated sí, anon no)', v_fn;
    END IF;
  END LOOP;

  -- Cada entrada de la lista blanca está concedida hoy (tabla o columnas).
  SELECT array_agg(l.tabla || '.' || l.priv ORDER BY l.tabla, l.priv) INTO v_falta
    FROM _grants_rest_lista l
   WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'authenticated_escrituras') e
                      WHERE e->>'tabla' = l.tabla AND e->>'privilegio' = l.priv);
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION '#1135 · la lista blanca pide privilegios que authenticated no tiene: %', v_falta;
  END IF;

  -- Foto de lo que no se tiene que mover: el nivel de cada entrada de la lista
  -- blanca y el SELECT de authenticated.
  INSERT INTO _grants_rest_pre VALUES
    ('niveles', (SELECT jsonb_agg(e ORDER BY e::text)
                   FROM jsonb_array_elements(v_g->'authenticated_escrituras') e
                   JOIN _grants_rest_lista l ON l.tabla = e->>'tabla' AND l.priv = e->>'privilegio')),
    ('select_tablas', to_jsonb((SELECT count(*) FROM pg_class c
                                 WHERE c.relnamespace = 'public'::regnamespace
                                   AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
                                   AND has_table_privilege('authenticated', c.oid, 'SELECT')))),
    ('select_columnas', (SELECT jsonb_object_agg(t, n) FROM (
                           SELECT c.relname::text AS t, count(*) AS n
                             FROM pg_class c
                             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                            WHERE c.relnamespace = 'public'::regnamespace
                              AND c.relname IN ('productos', 'pedido_items')
                              AND has_column_privilege('authenticated', c.oid, a.attnum, 'SELECT')
                            GROUP BY 1) s));
END
$pre$;

-- ------------------------------------------------------- 1 · anon, entero ---
-- ALL TABLES incluye vistas; un REVOKE de tabla se lleva también los grants
-- por columna del mismo privilegio (el SELECT por columna de productos y
-- pedido_items, mig de #974).
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;

-- ------------------------------ 2 · authenticated: privilegios sin ningún uso ---
-- PostgREST no expone TRUNCATE (que no pasa por RLS), y la app no crea FKs ni
-- triggers ni hace VACUUM/ANALYZE.
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON ALL TABLES IN SCHEMA public FROM authenticated;

-- ------------------------------------ 3 · las 4 RPC INVOKER pasan a DEFINER ---
-- Con ALTER y no con CREATE OR REPLACE: el cuerpo vigente de prod no se toca
-- (trampa 3) y el ACL tampoco (authenticated y service_role). Las cuatro ya
-- tienen SET search_path TO 'public' y son de postgres (lo exigen el $pre$ y el
-- $verif$, no este comentario), y validan el rol adentro antes de
-- escribir (es_admin() las de alícuotas; admin, encargado o depósito las otras
-- dos). guardar_producto_medidas acota la sucursal por su cuenta: cada producto
-- tiene que ser de current_sucursal_id() (DEFINER, valida el header contra
-- usuario_sucursales) y borra e inserta con ese sucursal_id; sin RLS esa es la
-- valla, y la fija el caso I del ensayo. Los triggers de sus tablas
-- (validar_ii_alicuota, normalizar_cargo_concepto, trg_refrescar_ii_productos)
-- no miran current_user ni auth.uid(). La regla de CLAUDE.md que prohíbe
-- DEFINER es para las funciones que mueven stock (STK-D): éstas no lo mueven.
ALTER FUNCTION public.cambiar_alicuota_ii(bigint, numeric, date) SECURITY DEFINER;
ALTER FUNCTION public.cancelar_alicuota_programada(bigint) SECURITY DEFINER;
ALTER FUNCTION public.guardar_producto_medidas(jsonb) SECURITY DEFINER;
ALTER FUNCTION public.asegurar_cargo_concepto(text, integer, text, boolean, boolean, text, bigint) SECURITY DEFINER;

-- ------------- 4 · authenticated: se revoca sólo la escritura que sobra ---
-- No es "REVOKE en todas + GRANT de la lista blanca": un REVOKE de tabla borra
-- también los grants por columna del mismo privilegio, así que volver a
-- conceder a nivel tabla ensancharía en silencio lo que esté por columna (el
-- UPDATE de pedidos, si #1131 lo deja así). Lo que está en la lista blanca no
-- se toca; lo que no, se revoca entero (incluido el UPDATE por columna de
-- notificaciones, que el front marca leída por RPC). Las secuencias no entran.
DO $rev$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT DISTINCT e->>'tabla' AS tabla, e->>'privilegio' AS priv
      FROM jsonb_array_elements(public.auditoria_grants_tablas()->'authenticated_escrituras') e
     WHERE NOT EXISTS (SELECT 1 FROM _grants_rest_lista l
                        WHERE l.tabla = e->>'tabla' AND l.priv = e->>'privilegio')
     ORDER BY 1, 2
  LOOP
    EXECUTE format('REVOKE %s ON public.%I FROM authenticated', r.priv, r.tabla);
  END LOOP;
END
$rev$;

-- ------------------- 5 · policies de escritura que quedaron sin grant ---
-- Para que el catálogo no mienta (como la 355). Las de SELECT no cambian. Las
-- FOR ALL tampoco: también son el SELECT de alguien (van a la segunda tanda).
DROP POLICY mt_audit_logs_insert            ON public.audit_logs;
DROP POLICY mt_cambios_productos_insert     ON public.cambios_productos;
DROP POLICY mt_cambios_productos_delete     ON public.cambios_productos;
DROP POLICY cargo_conceptos_insert          ON public.cargo_conceptos;
DROP POLICY cargo_conceptos_update          ON public.cargo_conceptos;
DROP POLICY cargo_conceptos_delete          ON public.cargo_conceptos;
DROP POLICY cargo_medidas_insert            ON public.cargo_medidas;
DROP POLICY cargo_medidas_update            ON public.cargo_medidas;
DROP POLICY cargo_medidas_delete            ON public.cargo_medidas;
DROP POLICY cdc_update                      ON public.cliente_descuentos_categoria;
DROP POLICY cp_update                       ON public.cliente_preventistas;
DROP POLICY mt_historial_cambios_insert     ON public.historial_cambios;
DROP POLICY ii_encuadres_delete             ON public.ii_encuadres;
DROP POLICY ii_alicuotas_insert             ON public.ii_alicuotas;
DROP POLICY ii_alicuotas_update             ON public.ii_alicuotas;
DROP POLICY ii_alicuotas_delete             ON public.ii_alicuotas;
DROP POLICY mt_mermas_stock_insert          ON public.mermas_stock;
DROP POLICY mt_mermas_stock_update          ON public.mermas_stock;
DROP POLICY mt_mermas_stock_delete          ON public.mermas_stock;
DROP POLICY notif_update                    ON public.notificaciones;
DROP POLICY mt_pagos_update                 ON public.pagos;
DROP POLICY mt_pedido_historial_update      ON public.pedido_historial;
DROP POLICY mt_pedido_historial_delete      ON public.pedido_historial;
DROP POLICY mt_pedido_items_insert          ON public.pedido_items;
DROP POLICY mt_pedido_items_update          ON public.pedido_items;
DROP POLICY mt_pedido_items_delete          ON public.pedido_items;
DROP POLICY mt_pedidos_insert               ON public.pedidos;
DROP POLICY mt_pedidos_delete               ON public.pedidos;
DROP POLICY mt_pedidos_eliminados_insert    ON public.pedidos_eliminados;
DROP POLICY perfiles_insert_admin           ON public.perfiles;
DROP POLICY perfiles_delete_admin           ON public.perfiles;
DROP POLICY mt_politicas_comerciales_insert ON public.politicas_comerciales;
DROP POLICY mt_politicas_comerciales_update ON public.politicas_comerciales;
DROP POLICY producto_medidas_insert         ON public.producto_medidas;
DROP POLICY producto_medidas_update         ON public.producto_medidas;
DROP POLICY producto_medidas_delete         ON public.producto_medidas;
DROP POLICY mt_proveedores_delete           ON public.proveedores;
DROP POLICY mt_recorrido_pedidos_insert     ON public.recorrido_pedidos;
DROP POLICY mt_recorrido_pedidos_update     ON public.recorrido_pedidos;
DROP POLICY mt_recorridos_insert            ON public.recorridos;
DROP POLICY mt_recorridos_delete            ON public.recorridos;
DROP POLICY mt_rendicion_ajustes_insert     ON public.rendicion_ajustes;
DROP POLICY rg_insert                       ON public.rendicion_gastos;
DROP POLICY rg_update                       ON public.rendicion_gastos;
DROP POLICY rg_delete                       ON public.rendicion_gastos;
DROP POLICY mt_rendicion_items_insert       ON public.rendicion_items;
DROP POLICY mt_rendiciones_insert           ON public.rendiciones;
DROP POLICY mt_rendiciones_update           ON public.rendiciones;
DROP POLICY mt_rendiciones_delete           ON public.rendiciones;
DROP POLICY mt_rendiciones_control_insert   ON public.rendiciones_control;
DROP POLICY mt_rendiciones_control_delete   ON public.rendiciones_control;
DROP POLICY mt_salvedad_historial_insert    ON public.salvedad_historial;
DROP POLICY mt_salvedades_items_insert      ON public.salvedades_items;
DROP POLICY mt_salvedades_items_update      ON public.salvedades_items;
DROP POLICY mt_salvedades_items_delete      ON public.salvedades_items;
DROP POLICY visitas_cliente_insert          ON public.visitas_cliente;

-- ------------------------------------------------ 6 · #1134 stock_historico ---
-- El GRANT INSERT a authenticated se queda: lo usa registrar_cambio_stock, el
-- trigger AFTER UPDATE de productos, cuando la ficha edita el stock por REST
-- (corre como authenticated, a pg_trigger_depth() = 1, y asienta
-- 'ajuste_manual' de auth.uid()). Ese trigger no puede ser DEFINER: adentro de
-- una DEFINER current_user es postgres, la ficha se confundiría con una RPC sin
-- etiqueta y STK-D dejaría de verla (CLAUDE.md). La policy admite sólo esa
-- fila: un POST directo corre a profundidad 0 y queda afuera, igual que en
-- pedido_historial (mt_pedido_historial_insert). El rol es el mismo que el
-- UPDATE de productos (mt_productos_update). UPDATE y DELETE cayeron en el
-- paso 4; TRUNCATE y MAINTAIN, en el 2.
DROP POLICY mt_stock_historico_insert ON public.stock_historico;
CREATE POLICY mt_stock_historico_insert_ficha ON public.stock_historico
  FOR INSERT TO authenticated
  WITH CHECK (
    pg_trigger_depth() = 1
    AND origen = 'ajuste_manual'
    AND usuario_id = auth.uid()
    AND referencia_tipo IS NULL
    AND referencia_id IS NULL
    AND sucursal_id = public.current_sucursal_id()
    AND (public.es_admin()
         OR EXISTS (SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol = 'deposito'))
  );

-- ------------------------------------------------- 7 · default privileges ---
-- Lo que crea postgres en public de acá en adelante: nada para anon; para
-- authenticated, sólo SELECT en tablas (la lectura la gobierna la RLS, que el
-- gate exige en toda tabla). La migración que quiera escritura REST la concede
-- explícita y la suma a scripts/grants-rest.json. El default de supabase_admin
-- no se puede cambiar desde postgres: lo vigila el gate.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES    FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM authenticated;

-- ------------------------------------------------ verificación post-DDL ---
DO $verif$
DECLARE
  v_g      jsonb := public.auditoria_grants_tablas();
  v_set    text[];
  v_lista  text[];
  v_txt    text[];
  v_n      bigint;
  v_fn     text;
BEGIN
  -- anon: nada, ni por tabla ni por columna, MAINTAIN incluido.
  IF jsonb_array_length(v_g->'anon') > 0 THEN
    RAISE EXCEPTION '#1135 · anon conserva privilegios: %', v_g->'anon';
  END IF;

  -- authenticated: sin TRUNCATE / REFERENCES / TRIGGER / MAINTAIN.
  IF jsonb_array_length(v_g->'authenticated_extras') > 0 THEN
    RAISE EXCEPTION '#1135 · authenticated conserva extras: %', v_g->'authenticated_extras';
  END IF;

  -- Las escrituras de authenticated son exactamente la lista blanca.
  SELECT array_agg(DISTINCT (e->>'tabla') || '.' || (e->>'privilegio') ORDER BY (e->>'tabla') || '.' || (e->>'privilegio'))
    INTO v_set FROM jsonb_array_elements(v_g->'authenticated_escrituras') e;
  SELECT array_agg(tabla || '.' || priv ORDER BY tabla || '.' || priv) INTO v_lista FROM _grants_rest_lista;
  IF v_set IS DISTINCT FROM v_lista THEN
    RAISE EXCEPTION '#1135 · las escrituras de authenticated no son la lista blanca: sobran %, faltan %',
      ARRAY(SELECT unnest(v_set) EXCEPT SELECT unnest(v_lista)),
      ARRAY(SELECT unnest(v_lista) EXCEPT SELECT unnest(v_set));
  END IF;

  -- Y en el mismo nivel que antes (nada se ensanchó de columnas a tabla).
  IF (SELECT jsonb_agg(e ORDER BY e::text) FROM jsonb_array_elements(v_g->'authenticated_escrituras') e)
     IS DISTINCT FROM (SELECT valor FROM _grants_rest_pre WHERE clave = 'niveles') THEN
    RAISE EXCEPTION '#1135 · cambió el nivel de una escritura de la lista blanca: antes %, ahora %',
      (SELECT valor FROM _grants_rest_pre WHERE clave = 'niveles'), v_g->'authenticated_escrituras';
  END IF;

  -- El SELECT de authenticated no se movió.
  SELECT count(*) INTO v_n FROM pg_class c
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
     AND has_table_privilege('authenticated', c.oid, 'SELECT');
  IF to_jsonb(v_n) IS DISTINCT FROM (SELECT valor FROM _grants_rest_pre WHERE clave = 'select_tablas') THEN
    RAISE EXCEPTION '#1135 · authenticated lee % relaciones; antes %', v_n,
      (SELECT valor FROM _grants_rest_pre WHERE clave = 'select_tablas');
  END IF;
  IF (SELECT jsonb_object_agg(t, n) FROM (
        SELECT c.relname::text AS t, count(*) AS n
          FROM pg_class c
          JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
         WHERE c.relnamespace = 'public'::regnamespace
           AND c.relname IN ('productos', 'pedido_items')
           AND has_column_privilege('authenticated', c.oid, a.attnum, 'SELECT')
         GROUP BY 1) s)
     IS DISTINCT FROM (SELECT valor FROM _grants_rest_pre WHERE clave = 'select_columnas') THEN
    RAISE EXCEPTION '#1135 · cambiaron las columnas legibles de productos / pedido_items';
  END IF;

  -- service_role conserva la escritura en todas las tablas.
  SELECT array_agg(c.relname::text ORDER BY c.relname) INTO v_txt
    FROM pg_class c
   WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'p')
     AND NOT (has_table_privilege('service_role', c.oid, 'INSERT')
              AND has_table_privilege('service_role', c.oid, 'UPDATE')
              AND has_table_privilege('service_role', c.oid, 'DELETE'));
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION '#1135 · service_role perdió escritura en %', v_txt;
  END IF;

  -- Ninguna policy de INSERT / UPDATE / DELETE fuera de la lista blanca.
  SELECT array_agg(p.tablename || '.' || p.policyname ORDER BY p.tablename, p.policyname) INTO v_txt
    FROM pg_policies p
   WHERE p.schemaname = 'public' AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE')
     AND NOT EXISTS (SELECT 1 FROM _grants_rest_lista l
                      WHERE l.tabla = p.tablename AND l.priv = p.cmd);
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION '#1135 · quedaron policies de escritura sin grant: %', v_txt;
  END IF;

  -- #1134: stock_historico, la policy de la ficha y la de lectura, nada más.
  SELECT array_agg(policyname::text ORDER BY policyname) INTO v_txt
    FROM pg_policies WHERE schemaname = 'public' AND tablename = 'stock_historico';
  IF v_txt IS DISTINCT FROM ARRAY['mt_stock_historico_insert_ficha', 'mt_stock_historico_select'] THEN
    RAISE EXCEPTION '#1134 · las policies de stock_historico quedaron %', v_txt;
  END IF;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.registrar_cambio_stock()'::regprocedure)
     OR NOT EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgrelid = 'public.productos'::regclass AND tgname = 'trg_stock_historico'
                       AND tgfoid = 'public.registrar_cambio_stock()'::regprocedure
                       AND tgenabled = 'O') THEN
    RAISE EXCEPTION '#1134 · registrar_cambio_stock dejó de ser INVOKER o trg_stock_historico no está habilitado';
  END IF;

  -- Las 4 RPC: DEFINER, EXECUTE para authenticated y no para anon.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.cambiar_alicuota_ii(bigint,numeric,date)',
    'public.cancelar_alicuota_programada(bigint)',
    'public.guardar_producto_medidas(jsonb)',
    'public.asegurar_cargo_concepto(text,integer,text,boolean,boolean,text,bigint)'] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_fn::regprocedure)
       OR NOT has_function_privilege('authenticated', v_fn::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', v_fn::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION '#1135 · % no quedó DEFINER con EXECUTE sólo para authenticated', v_fn;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc f, unnest(f.proconfig) c
                    WHERE f.oid = v_fn::regprocedure AND c ~ '^search_path=')
       OR (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid = v_fn::regprocedure) <> 'postgres' THEN
      RAISE EXCEPTION '#1135 · % quedó DEFINER sin search_path fijo o con otro dueño que postgres', v_fn;
    END IF;
  END LOOP;

  -- Los defaults de postgres en public: nada para anon, sólo SELECT en tablas
  -- para authenticated.
  SELECT array_agg((d->>'objtipo') || ' ' || (d->>'grantee') || ' ' || (d->>'privilegio')) INTO v_txt
    FROM jsonb_array_elements(v_g->'default_acl') d
   WHERE d->>'owner' = 'postgres'
     AND (d->>'grantee' IN ('anon', 'PUBLIC') AND d->>'objtipo' IN ('r', 'S')
          OR (d->>'grantee' = 'authenticated' AND d->>'objtipo' = 'r' AND d->>'privilegio' <> 'SELECT'));
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION '#1135 · el default de postgres en public todavía concede %', v_txt;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'default_acl') d
                  WHERE d->>'owner' = 'postgres' AND d->>'objtipo' = 'r'
                    AND d->>'grantee' = 'authenticated' AND d->>'privilegio' = 'SELECT') THEN
    RAISE EXCEPTION '#1135 · el default de postgres en public le sacó el SELECT a authenticated';
  END IF;

  -- La función del gate es de server.
  IF has_function_privilege('anon', 'public.auditoria_grants_tablas()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_grants_tablas()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.auditoria_grants_tablas()', 'EXECUTE') THEN
    RAISE EXCEPTION '#1135 · auditoria_grants_tablas() tiene que ser sólo de service_role';
  END IF;
END
$verif$;
