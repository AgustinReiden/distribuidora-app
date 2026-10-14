-- #1151 · Barrido de grants REST, segunda tanda: lo que la 361 dejó a
-- sabiendas («LO QUE QUEDA»).
--
-- EL BUG
--   La 361 cerró la escritura REST tabla por tabla, pero dejó cuatro cosas en
--   las que el catálogo sigue diciendo más de lo que la app usa:
--   · authenticated tiene SELECT sobre 12 tablas bot_* con RLS y sin ninguna
--     policy de lectura. Hoy da 0 filas, pero basta una policy nueva para
--     abrirlas; nadie las lee por REST (el bot usa service_role).
--   · authenticated tiene SELECT, UPDATE y USAGE en las 67 secuencias de
--     public (UPDATE habilita setval), y el default de postgres se lo sigue
--     dando a cada secuencia nueva. Alcanza USAGE en las 18 por las que pasa
--     un INSERT REST o un trigger INVOKER que corre como authenticated.
--   · 6 policies FOR ALL sobre tablas sin ninguna escritura REST (sucursales,
--     proveedores_eliminados, usuario_sucursales, transferencias_stock,
--     transferencia_items, promo_ajustes) y 5 policies TO public (sucursales
--     ×2, proveedores_eliminados, perfiles ×2).
--   · El UPDATE de pedidos y de recorridos es de tabla entera: un admin o un
--     encargado puede PATCHear total, monto_pagado, estado_pago o
--     stock_descontado de un pedido, y los contadores de un recorrido
--     (total_cobrado, pedidos_entregados…), que mantienen las RPC y los
--     triggers. VENTA-A / CC-A lo ven después, no lo impiden.
--   · historial_cambios: 0 filas, sin funciones, triggers, vistas ni código que
--     la use (punto 6 de #1151, decisión del dueño 2026-10-14: opción a).
--
-- EL ARREGLO
--   0 · auditoria_grants_tablas() suma tres claves para el gate:
--       select_sin_policy (tablas que authenticated lee sin ninguna policy de
--       SELECT que le aplique), authenticated_secuencias y policies_public.
--   1 · REVOKE SELECT de los 12 bot_* a authenticated (service_role intacto).
--       Explícito SELECT y no ALL: el resto ya lo revocó la 361. Las vistas y
--       las tablas con policy de SELECT no se tocan: las gobierna la RLS.
--       audit_logs tampoco: la lee precio_fuera_de_politica (INVOKER).
--   2 · Secuencias: REVOKE ALL en todas para authenticated, USAGE en las 18 de
--       scripts/grants-rest.json («secuencias»), y el default de postgres en
--       public deja de darle nada a authenticated. Las 4 identity
--       (cliente_descuentos_categoria, ii_encuadres, perfil_roles,
--       stock_historico) probablemente no necesitan USAGE: se conservan igual,
--       para que la regla sea mecánica («la tabla tiene INSERT REST o la
--       escribe un trigger INVOKER ⇒ su secuencia tiene USAGE»).
--   3 · Policies: las 6 FOR ALL pasan a FOR SELECT TO authenticated con el mismo
--       USING (admin_sucursales se borra: read_sucursales ya deja leer a todo
--       authenticated), y las TO public pasan a TO authenticated. anon no tiene
--       grants desde la 361, así que para él nada cambia.
--   4 · UPDATE de pedidos por columna: estado, fecha, fecha_entrega,
--       fecha_entrega_programada, notas, transportista_id y updated_at (lo que
--       escribe el front). recorridos: completed_at y estado. Postgres chequea
--       el privilegio sobre la lista del SET: lo que ajusta un trigger BEFORE
--       (estado_pago, etc.) no pide grant, y los contadores de recorridos los
--       mantiene actualizar_recorrido_entrega, que es DEFINER.
--   5 · DROP TABLE historial_cambios (el $pre$ vuelve a exigir 0 filas y 0
--       dependientes).
--
-- NO CAMBIA
--   · Ningún cuerpo de función salvo auditoria_grants_tablas() (CREATE OR
--     REPLACE desde la de prod, = 361; su ACL queda sólo service_role).
--   · El default de postgres para TABLAS sigue dando SELECT a authenticated:
--     una tabla nueva con RLS y sin policy de SELECT para authenticated pone
--     rojo el gate (select_sin_policy) y el $verif$ de abajo. Es lo buscado:
--     su migración tiene que crearle la policy o revocarle el SELECT.
--   · productos (stock y costos los edita la ficha a propósito) y
--     promociones.usos_pendientes (promociones es FOR ALL sólo de admin, que
--     ya edita la promo entera): su UPDATE sigue de tabla.
--   · mt_pedidos_select (es de otro grupo) y perfil_roles_write_admin (tiene
--     INSERT y DELETE por REST).
--   · STK-F / STK-D / COSTO-D / CC-A: no se mueve stock, costo ni saldo.
--
-- Después de esta migración ningún PATCH REST nombra total ni monto_pagado,
-- así que actualizar_saldo_pedido (INVOKER, AFTER UPDATE OF total,
-- monto_pagado) deja de correr como authenticated: por_invoker.clientes del
-- JSON queda sólo con la escritura del front.
--
-- Ensayo: scripts/test-grants-rest-segunda-tanda-1151.sql (falla antes, pasa
-- después). Regresión: scripts/test-grants-rest-1134-1135.sql.
-- Gate:   scripts/grants-rest.json («escrituras» con el nivel de pedidos y
--         recorridos, «secuencias»), src/test/grantsRest.contract.test.ts y
--         scripts/check-grants-tablas.mjs.

SET LOCAL lock_timeout = '5s';

-- ------------------------------------------- 0 · auditoria_grants_tablas() ---
-- La de prod (= 361) más tres claves:
--   select_sin_policy: tabla con RLS (r/p) que authenticated puede leer y sin
--     ninguna policy FOR SELECT / FOR ALL que le aplique (roles authenticated
--     o public). Las vistas no: son security_invoker (lo exige
--     vistas_sin_invoker) y las gobierna la RLS de sus tablas.
--   authenticated_secuencias: cada (secuencia, privilegio) de authenticated.
--   policies_public: toda policy de public con el rol PUBLIC.
CREATE OR REPLACE FUNCTION public.auditoria_grants_tablas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
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
    -- #1151: authenticated lee una tabla que ninguna policy le deja leer. Hoy
    -- da 0 filas; con una policy nueva se abre. Va con su policy de SELECT o
    -- sin el SELECT.
    'select_sin_policy', COALESCE((
      SELECT jsonb_agg(r.relacion ORDER BY r.relacion)
        FROM rel r
       WHERE r.relkind IN ('r', 'p')
         AND has_any_column_privilege('authenticated', r.oid, 'SELECT')
         AND NOT EXISTS (SELECT 1 FROM pg_policies p
                          WHERE p.schemaname = 'public' AND p.tablename = r.relacion
                            AND p.cmd IN ('SELECT', 'ALL')
                            AND p.roles && ARRAY['authenticated', 'public']::name[])), '[]'::jsonb),
    -- #1151: alcanza USAGE en las secuencias de las tablas con INSERT REST o
    -- escritas por un trigger INVOKER (scripts/grants-rest.json, «secuencias»).
    'authenticated_secuencias', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('secuencia', relacion, 'privilegio', priv)
                       ORDER BY relacion, priv)
        FROM todo WHERE rol = 'authenticated' AND relkind = 'S'), '[]'::jsonb),
    -- #1151: una policy sin TO es de PUBLIC, o sea también de anon.
    'policies_public', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('tabla', tablename, 'policy', policyname, 'cmd', cmd)
                       ORDER BY tablename, policyname)
        FROM pg_policies
       WHERE schemaname = 'public' AND 'public' = ANY(roles)), '[]'::jsonb),
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
$function$;

COMMENT ON FUNCTION public.auditoria_grants_tablas() IS
  '#1135/#1151 · Grants de tabla y secuencia de anon y authenticated en public, con el nivel (tabla o columnas) de cada escritura, las tablas legibles sin policy de SELECT y las policies TO public. Sólo service_role (scripts/check-grants-tablas.mjs).';

-- CREATE OR REPLACE conserva el ACL; se repite igual (función de server: las
-- tres mitades, CLAUDE.md).
REVOKE ALL ON FUNCTION public.auditoria_grants_tablas() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_grants_tablas() TO service_role;

-- ------------------------------------------------------- precondiciones ---
-- Las 18 secuencias que conservan USAGE (= scripts/grants-rest.json,
-- «secuencias»). Si al aplicar existe una tabla nueva con INSERT REST o
-- escrita por un trigger INVOKER, su secuencia se suma acá y al JSON.
CREATE TEMP TABLE _secuencias_rest (secuencia text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO _secuencias_rest (secuencia) VALUES
  ('cliente_descuentos_categoria_id_seq'), ('clientes_codigo_seq'), ('clientes_id_seq'),
  ('grupo_precio_escala_minimos_id_seq'), ('grupo_precio_escalas_id_seq'),
  ('grupo_precio_productos_id_seq'), ('grupos_precio_id_seq'), ('ii_encuadres_id_seq'),
  ('pagos_id_seq'), ('pedido_historial_id_seq'), ('perfil_roles_id_seq'), ('productos_id_seq'),
  ('promocion_productos_id_seq'), ('promocion_reglas_id_seq'), ('promociones_id_seq'),
  ('proveedores_id_seq'), ('stock_historico_id_seq'), ('zonas_id_seq');

CREATE TEMP TABLE _segunda_tanda_pre (clave text PRIMARY KEY, valor jsonb) ON COMMIT DROP;

DO $pre$
DECLARE
  v_escritores text[];
  v_esperados  text[] := ARRAY[
    '_mov_lotes_descontar', '_mov_lotes_registrar_salida', 'actualizar_saldo_pedido',
    'registrar_cambio_pedido', 'registrar_cambio_stock', 'registrar_creacion_pedido'];
  v_txt text[];
  v_n   bigint;
  v_g   jsonb := public.auditoria_grants_tablas();
BEGIN
  -- Los escritores INVOKER de public son los de siempre (la misma regex que la
  -- 361). Ninguno escribe pedidos ni recorridos: el UPDATE por columna no le
  -- corta nada a un trigger. Uno nuevo que inserte como authenticated
  -- necesitaría además USAGE de su secuencia.
  SELECT array_agg(DISTINCT f.proname::text ORDER BY f.proname::text) INTO v_escritores
    FROM pg_proc f
    CROSS JOIN LATERAL regexp_matches(f.prosrc, '(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+(public\.)?(\w+)', 'gi') m
    JOIN pg_class c ON c.relname = lower(m[3]) AND c.relnamespace = 'public'::regnamespace
                   AND c.relkind IN ('r', 'p', 'v')
   WHERE f.pronamespace = 'public'::regnamespace
     AND NOT f.prosecdef
     AND f.prolang IN (SELECT oid FROM pg_language WHERE lanname IN ('plpgsql', 'sql'));
  IF v_escritores IS DISTINCT FROM v_esperados THEN
    RAISE EXCEPTION '#1151 · los escritores INVOKER de public cambiaron: sobran %, faltan %. Revisar si escriben pedidos o recorridos (columnas) o si insertan con una secuencia (USAGE)',
      ARRAY(SELECT unnest(v_escritores) EXCEPT SELECT unnest(v_esperados)),
      ARRAY(SELECT unnest(v_esperados) EXCEPT SELECT unnest(v_escritores));
  END IF;

  -- Ninguna función INVOKER usa una secuencia a mano.
  SELECT array_agg(f.proname::text ORDER BY 1) INTO v_txt
    FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace AND NOT f.prosecdef
     AND f.prosrc ~* '\m(nextval|setval|currval|lastval)\M';
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION '#1151 · funciones INVOKER que usan secuencias a mano: %', v_txt;
  END IF;

  -- Las 18 existen.
  SELECT array_agg(s.secuencia ORDER BY s.secuencia) INTO v_txt
    FROM _secuencias_rest s
   WHERE to_regclass('public.' || s.secuencia) IS NULL
      OR (SELECT relkind FROM pg_class WHERE oid = to_regclass('public.' || s.secuencia)) <> 'S';
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION '#1151 · no existen las secuencias %', v_txt;
  END IF;

  -- pedidos y recorridos no tienen grants por columna: el REVOKE de tabla no
  -- se lleva nada que no se vuelva a conceder.
  IF EXISTS (SELECT 1 FROM pg_attribute
              WHERE attrelid IN ('public.pedidos'::regclass, 'public.recorridos'::regclass)
                AND attnum > 0 AND attacl IS NOT NULL) THEN
    RAISE EXCEPTION '#1151 · pedidos o recorridos ya tienen privilegios por columna: revisar a mano';
  END IF;

  -- historial_cambios: vacía y sin nada que dependa de ella (vistas, FKs
  -- entrantes, columnas de su tipo, funciones que la nombran).
  IF to_regclass('public.historial_cambios') IS NULL THEN
    RAISE EXCEPTION '#1151 · historial_cambios ya no existe';
  END IF;
  EXECUTE 'SELECT count(*) FROM public.historial_cambios' INTO v_n;
  IF v_n > 0 THEN
    RAISE EXCEPTION '#1151 · historial_cambios tiene % filas: no se borra', v_n;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE confrelid = 'public.historial_cambios'::regclass
                AND conrelid <> 'public.historial_cambios'::regclass)
     OR EXISTS (SELECT 1 FROM pg_depend d JOIN pg_rewrite w ON d.classid = 'pg_rewrite'::regclass AND w.oid = d.objid
                 WHERE d.refclassid = 'pg_class'::regclass AND d.refobjid = 'public.historial_cambios'::regclass
                   AND w.ev_class <> 'public.historial_cambios'::regclass)
     OR EXISTS (SELECT 1 FROM pg_depend d
                 WHERE d.refclassid = 'pg_type'::regclass
                   AND d.refobjid = (SELECT reltype FROM pg_class WHERE oid = 'public.historial_cambios'::regclass)
                   AND d.deptype = 'n')
     OR EXISTS (SELECT 1 FROM pg_proc f WHERE f.prosrc ~* '\mhistorial_cambios\M')
     OR EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgrelid = 'public.historial_cambios'::regclass AND NOT t.tgisinternal) THEN
    RAISE EXCEPTION '#1151 · historial_cambios tiene dependientes (vista, FK, columna, función o trigger): no se borra';
  END IF;

  -- Foto: las (tabla, privilegio) de escritura de authenticated no se mueven
  -- (sólo el nivel de pedidos.UPDATE y recorridos.UPDATE), y el USING de las
  -- FOR ALL que pasan a FOR SELECT.
  INSERT INTO _segunda_tanda_pre VALUES
    ('escrituras', (SELECT jsonb_agg(DISTINCT (e->>'tabla') || '.' || (e->>'privilegio'))
                      FROM jsonb_array_elements(v_g->'authenticated_escrituras') e)),
    ('quals', (SELECT jsonb_object_agg(tablename, qual) FROM pg_policies
                WHERE schemaname = 'public'
                  AND (tablename, policyname) IN (('proveedores_eliminados', 'Admin full access proveedores_eliminados'),
                                                  ('usuario_sucursales', 'usuario_sucursales_admin_all'),
                                                  ('transferencias_stock', 'mt_transferencias_stock_all'),
                                                  ('transferencia_items', 'mt_transferencia_items_all'),
                                                  ('promo_ajustes', 'mt_promo_ajustes_all'))));
  IF (SELECT jsonb_typeof(valor) FROM _segunda_tanda_pre WHERE clave = 'quals') IS DISTINCT FROM 'object'
     OR (SELECT (SELECT count(*) FROM jsonb_object_keys(valor)) FROM _segunda_tanda_pre WHERE clave = 'quals') <> 5 THEN
    RAISE EXCEPTION '#1151 · no están las 5 policies FOR ALL a convertir';
  END IF;
END
$pre$;

-- ------------------------------------------------ 1 · SELECT sin policy ---
REVOKE SELECT ON public.bot_audit_log, public.bot_avisos_atrasados_enviados,
  public.bot_avisos_vencimiento_enviados, public.bot_conversaciones,
  public.bot_costo_llm_mensual, public.bot_digest_config, public.bot_digests_enviados,
  public.bot_intentos_vinculacion, public.bot_pedidos_pendientes, public.bot_presupuesto_llm,
  public.bot_updates_procesados, public.bot_usuarios
  FROM authenticated;

-- ---------------------------------------------------------- 2 · secuencias ---
-- USAGE alcanza para nextval (el default de un serial); SELECT (currval) y
-- UPDATE (setval) no los usa nadie como authenticated.
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM authenticated;
GRANT USAGE ON SEQUENCE public.cliente_descuentos_categoria_id_seq, public.clientes_codigo_seq,
  public.clientes_id_seq, public.grupo_precio_escala_minimos_id_seq, public.grupo_precio_escalas_id_seq,
  public.grupo_precio_productos_id_seq, public.grupos_precio_id_seq, public.ii_encuadres_id_seq,
  public.pagos_id_seq, public.pedido_historial_id_seq, public.perfil_roles_id_seq, public.productos_id_seq,
  public.promocion_productos_id_seq, public.promocion_reglas_id_seq, public.promociones_id_seq,
  public.proveedores_id_seq, public.stock_historico_id_seq, public.zonas_id_seq TO authenticated;
-- Una secuencia nueva nace sin nada para authenticated: la migración de una
-- tabla con INSERT REST le concede USAGE y la suma a grants-rest.json.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM authenticated;

-- ------------------------------------------------------------ 3 · policies ---
-- sucursales: read_sucursales ya deja leer a todo authenticated; la FOR ALL de
-- admin no agrega lectura y no hay escritura REST.
DROP POLICY admin_sucursales ON public.sucursales;
ALTER POLICY read_sucursales ON public.sucursales TO authenticated;

-- Las otras 5 FOR ALL: FOR SELECT TO authenticated con el mismo USING de prod
-- (el $verif$ lo compara contra la foto del $pre$). En proveedores_eliminados
-- y transferencia_items la FOR ALL es lectura que ninguna otra policy cubre
-- entera; en las demás se convierte igual, para no mover lo legible.
DROP POLICY "Admin full access proveedores_eliminados" ON public.proveedores_eliminados;
CREATE POLICY proveedores_eliminados_select_admin ON public.proveedores_eliminados
  FOR SELECT TO authenticated
  USING (EXISTS ( SELECT 1
   FROM perfiles
  WHERE ((perfiles.id = auth.uid()) AND (perfiles.rol = 'admin'::text))));

DROP POLICY usuario_sucursales_admin_all ON public.usuario_sucursales;
CREATE POLICY usuario_sucursales_select_admin ON public.usuario_sucursales
  FOR SELECT TO authenticated
  USING ((es_admin() AND (sucursal_id = current_sucursal_id())));

DROP POLICY mt_transferencias_stock_all ON public.transferencias_stock;
CREATE POLICY mt_transferencias_stock_select_admin ON public.transferencias_stock
  FOR SELECT TO authenticated
  USING ((es_admin() AND (tenant_sucursal_id = current_sucursal_id())));

DROP POLICY mt_transferencia_items_all ON public.transferencia_items;
CREATE POLICY mt_transferencia_items_select_admin ON public.transferencia_items
  FOR SELECT TO authenticated
  USING ((es_admin() AND (sucursal_id = current_sucursal_id())));

DROP POLICY mt_promo_ajustes_all ON public.promo_ajustes;
CREATE POLICY mt_promo_ajustes_select_admin ON public.promo_ajustes
  FOR SELECT TO authenticated
  USING ((es_admin() AND (sucursal_id = current_sucursal_id())));

-- perfiles conserva el UPDATE REST (useUsuariosQuery): cambia sólo el rol.
ALTER POLICY "Perfiles: actualizacion propio o admin" ON public.perfiles TO authenticated;
ALTER POLICY perfiles_update_self ON public.perfiles TO authenticated;

-- ------------------------------------------------- 4 · UPDATE por columna ---
-- Las columnas que escribe el front (PedidosContainer: notas y las fechas de
-- ModalEditarPedido; usePedidosQuery: cambiarEstado y asignarTransportista;
-- useRecorridos: completar). El resto lo escriben RPC DEFINER y triggers.
REVOKE UPDATE ON public.pedidos FROM authenticated;
GRANT UPDATE (estado, fecha, fecha_entrega, fecha_entrega_programada, notas, transportista_id, updated_at)
  ON public.pedidos TO authenticated;
REVOKE UPDATE ON public.recorridos FROM authenticated;
GRANT UPDATE (completed_at, estado) ON public.recorridos TO authenticated;

-- --------------------------------------------- 5 · historial_cambios (6a) ---
DROP TABLE public.historial_cambios;

-- ------------------------------------------------ verificación post-DDL ---
DO $verif$
DECLARE
  v_g     jsonb := public.auditoria_grants_tablas();
  v_txt   text[];
  v_esp   text[];
  v_q     jsonb := (SELECT valor FROM _segunda_tanda_pre WHERE clave = 'quals');
BEGIN
  -- Ninguna tabla legible sin policy. El mensaje nombra cada tabla: si es de
  -- otra migración aplicada antes, la salida es suya.
  IF jsonb_array_length(v_g->'select_sin_policy') > 0 THEN
    RAISE EXCEPTION '#1151 · authenticated lee tablas sin ninguna policy de SELECT: %. A cada una, crearle una policy FOR SELECT TO authenticated o quitarle el SELECT a authenticated en su migración',
      (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(v_g->'select_sin_policy') x);
  END IF;

  IF jsonb_array_length(v_g->'policies_public') > 0 THEN
    RAISE EXCEPTION '#1151 · quedan policies con rol PUBLIC: %', v_g->'policies_public';
  END IF;

  -- Secuencias: USAGE en exactamente las 18, y nada más.
  SELECT array_agg((s->>'secuencia') || '.' || (s->>'privilegio') ORDER BY 1) INTO v_txt
    FROM jsonb_array_elements(v_g->'authenticated_secuencias') s;
  SELECT array_agg(secuencia || '.USAGE' ORDER BY 1) INTO v_esp FROM _secuencias_rest;
  IF v_txt IS DISTINCT FROM v_esp THEN
    RAISE EXCEPTION '#1151 · las secuencias de authenticated no son las 18 con USAGE: sobran %, faltan %',
      ARRAY(SELECT unnest(v_txt) EXCEPT SELECT unnest(v_esp)),
      ARRAY(SELECT unnest(v_esp) EXCEPT SELECT unnest(v_txt));
  END IF;

  -- Ninguna FOR ALL sobre una tabla sin escritura de authenticated.
  SELECT array_agg(c.relname || '.' || p.polname ORDER BY 1) INTO v_txt
    FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
   WHERE c.relnamespace = 'public'::regnamespace AND p.polcmd = '*'
     AND NOT (has_any_column_privilege('authenticated', c.oid, 'INSERT')
              OR has_any_column_privilege('authenticated', c.oid, 'UPDATE')
              OR has_table_privilege('authenticated', c.oid, 'DELETE'));
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION '#1151 · quedan policies FOR ALL sobre tablas sin escritura REST: %', v_txt;
  END IF;

  -- Las 5 convertidas: FOR SELECT TO authenticated con el USING de antes.
  SELECT array_agg(t ORDER BY t) INTO v_txt FROM (VALUES
      ('proveedores_eliminados', 'proveedores_eliminados_select_admin'),
      ('usuario_sucursales', 'usuario_sucursales_select_admin'),
      ('transferencias_stock', 'mt_transferencias_stock_select_admin'),
      ('transferencia_items', 'mt_transferencia_items_select_admin'),
      ('promo_ajustes', 'mt_promo_ajustes_select_admin')) AS e(t, pol)
   WHERE NOT EXISTS (SELECT 1 FROM pg_policies p
                      WHERE p.schemaname = 'public' AND p.tablename = e.t AND p.policyname = e.pol
                        AND p.cmd = 'SELECT' AND p.roles = ARRAY['authenticated']::name[]
                        AND p.with_check IS NULL AND p.qual = v_q->>e.t);
  IF v_txt IS NOT NULL THEN
    RAISE EXCEPTION '#1151 · la policy FOR SELECT de % no quedó con el USING de la FOR ALL', v_txt;
  END IF;

  -- Las (tabla, privilegio) de escritura no se movieron.
  IF (SELECT jsonb_agg(DISTINCT (e->>'tabla') || '.' || (e->>'privilegio'))
        FROM jsonb_array_elements(v_g->'authenticated_escrituras') e)
     IS DISTINCT FROM (SELECT valor FROM _segunda_tanda_pre WHERE clave = 'escrituras') THEN
    RAISE EXCEPTION '#1151 · cambiaron las escrituras de authenticated: antes %, ahora %',
      (SELECT valor FROM _segunda_tanda_pre WHERE clave = 'escrituras'), v_g->'authenticated_escrituras';
  END IF;

  -- pedidos.UPDATE y recorridos.UPDATE, sólo por columna y con estas columnas.
  IF (SELECT jsonb_agg(e->'nivel') FROM jsonb_array_elements(v_g->'authenticated_escrituras') e
       WHERE e->>'tabla' = 'pedidos' AND e->>'privilegio' = 'UPDATE')
     IS DISTINCT FROM '[["estado", "fecha", "fecha_entrega", "fecha_entrega_programada", "notas", "transportista_id", "updated_at"]]'::jsonb THEN
    RAISE EXCEPTION '#1151 · pedidos.UPDATE no quedó en sus 7 columnas: %', v_g->'authenticated_escrituras';
  END IF;
  IF (SELECT jsonb_agg(e->'nivel') FROM jsonb_array_elements(v_g->'authenticated_escrituras') e
       WHERE e->>'tabla' = 'recorridos' AND e->>'privilegio' = 'UPDATE')
     IS DISTINCT FROM '[["completed_at", "estado"]]'::jsonb THEN
    RAISE EXCEPTION '#1151 · recorridos.UPDATE no quedó en (completed_at, estado): %', v_g->'authenticated_escrituras';
  END IF;

  -- El default de postgres en public no le da nada a authenticated en
  -- secuencias.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_g->'default_acl') d
              WHERE d->>'owner' = 'postgres' AND d->>'objtipo' = 'S' AND d->>'grantee' = 'authenticated') THEN
    RAISE EXCEPTION '#1151 · el default de postgres en public todavía le da secuencias a authenticated';
  END IF;

  IF to_regclass('public.historial_cambios') IS NOT NULL THEN
    RAISE EXCEPTION '#1151 · historial_cambios sigue existiendo';
  END IF;

  -- La función del gate sigue siendo de server.
  IF has_function_privilege('anon', 'public.auditoria_grants_tablas()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_grants_tablas()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.auditoria_grants_tablas()', 'EXECUTE') THEN
    RAISE EXCEPTION '#1151 · auditoria_grants_tablas() tiene que ser sólo de service_role';
  END IF;
END
$verif$;
