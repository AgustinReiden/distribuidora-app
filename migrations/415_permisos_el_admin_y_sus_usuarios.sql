-- =========================================================================
-- 415 · EL ADMIN ASIGNA A LOS DE SUS SUCURSALES, Y CINCO POLICIES MÁS MIRAN
--       LA SUCURSAL (#1291, #1272)
--
-- Ensayo: scripts/test-permisos-1291-1272.sql
-- Gate:   scripts/check-rpcs-definer.mjs (lee auditoria_rpcs_definer())
--
-- 1 · asignar_usuario_sucursal / desasignar_usuario_sucursal (#1291)
--   Las dos son SECURITY DEFINER con EXECUTE para authenticated, y sólo
--   controlaban que el admin fuera de p_sucursal_id, no que el usuario fuera
--   suyo. El admin de Taco Pozo se traía a la 2 a un usuario de Tucumán con su
--   uuid (lo muestra, por ejemplo, movimientos_sucursal.creado_por). Desde ahí
--   admin_comparte_sucursal_con() daba true: veía su email, su telegram, todo su
--   historial con el bot (también lo de Tucumán), y la sucursal default del
--   otro pasaba a ser Taco Pozo.
--   Ahora piden admin_abarca_sucursales_de(p_usuario_id), como cambiarle el rol
--   o el activo (404): las mueve un admin de TODAS las sucursales del usuario.
--   Un usuario sin sucursales no es de nadie (el helper da false), así que
--   desasignar tampoco deja a nadie sin sucursal: después ningún admin lo
--   podría volver a asignar desde la app.
--   El front no llama a ninguna de las dos; quedan con EXECUTE para
--   authenticated porque son la vía para asignar sucursales que nombra
--   SinSucursalScreen.
--
-- 2 · Las cinco policies que encontró el gate de #1244 (#1272)
--   * cliente_preventistas cp_delete / cp_insert: la rama admin ahora pide
--     cliente_de_sucursal_activa(cliente_id), como cliente_descuentos_categoria
--     en la 404. El trigger cliente_preventistas_no_ajeno sigue dejando pasar
--     al admin: con la policy acotada, eso ya no cruza de sucursal.
--   * metas_gerenciales / reportes_mensuales *_admin_select: tienen sucursal_id
--     (NULL = Red). El admin lee las de sus sucursales, y la de la Red sólo si
--     es admin de todas las activas: la Red que guarda /reporte-mensual es la
--     de todas las sucursales, y la Red de un admin de una sola es su sucursal
--     (_sucursales_red(), #1262). Lo decidió el dueño el 2026-10-29.
--     La condición va escrita en la policy y no como _sucursales_red(): esa es
--     de server (authenticated no la ejecuta) y la policy la evalúa el que lee.
--   * proveedores_eliminados_select_admin: la tabla no tenía sucursal_id. Se
--     le agrega, la completa un trigger con la del proveedor (que todavía existe
--     cuando eliminar_proveedor archiva la fila) y el admin lee las de sus
--     sucursales. Las 2 filas viejas quedan en NULL: su sucursal no se puede
--     saber (el proveedor ya no está y no tenía compras), así que no las lee
--     nadie por REST.
--
-- 3 · auditoria_rpcs_definer() (nueva, de server)
--   check-rama-admin.mjs sólo mira policies; una RPC SECURITY DEFINER no pasa
--   por RLS. Esta función le da a scripts/check-rpcs-definer.mjs dos listas:
--   * gestion_usuarios: las RPCs que escriben quién es de qué sucursal, con qué
--     rol, o su bot (usuario_sucursales, perfil_roles, perfiles, bot_usuarios,
--     bot_digest_config) y si acotan al usuario (un helper que lo relaciona con
--     las sucursales del que llama, o todas sus escrituras sobre auth.uid()).
--     Es la clase de #1291, y el gate falla con cualquiera.
--   * parametros: cada parámetro de usuario (uuid, salvo *request_id,
--     categoria, marca) o de sucursal que la RPC usa, y si el texto muestra que
--     lo acota. El gate falla con uno que no esté en
--     scripts/rpcs-definer-permitidas.json, que sólo se achica.
--   Es heurística de texto, como SEG-A: lo que no ve está en el script.
--
-- PERMISOS: sin tablas nuevas ni escritura REST (grants-rest.json no cambia;
-- la columna nueva de proveedores_eliminados entra por su GRANT SELECT de
-- tabla). auditoria_rpcs_definer y el trigger: REVOKE PUBLIC, anon,
-- authenticated.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Lo que se reemplaza es lo de hoy
-- -------------------------------------------------------------------------
-- md5(prosrc) y el texto de las policies de prod al escribir esto
-- (2026-10-29). Si otra migración las cambió en el medio, esta las pisaría sin
-- avisar: se aborta y se rehace sobre lo vivo.
DO $vivas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.asignar_usuario_sucursal(uuid,bigint,character varying,boolean)', 'f205ec08c80b7002b5aae6ca24b7cf4a'),
      ('public.desasignar_usuario_sucursal(uuid,bigint)', '85450386bcf85955d33d1324eda0cc87')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-10-29: rehacer la migración sobre la definición viva', r.firma;
    END IF;
  END LOOP;

  -- La huella de cada policy es la de su excepción en check-rama-admin.mjs:
  -- md5(coalesce(qual,'') || '|' || coalesce(with_check,'')).
  FOR r IN SELECT * FROM (VALUES
      ('cliente_preventistas', 'cp_delete', '004e99e26fd7fc30631b300cfdc132a7'),
      ('cliente_preventistas', 'cp_insert', 'b1d05cf3e4b34da57d149a492a16334c'),
      ('metas_gerenciales', 'metas_gerenciales_admin_select', '06852a325dfe50c66be752cb475d85f2'),
      ('proveedores_eliminados', 'proveedores_eliminados_select_admin', '06852a325dfe50c66be752cb475d85f2'),
      ('reportes_mensuales', 'reportes_mensuales_admin_select', '06852a325dfe50c66be752cb475d85f2')) AS v(tabla, policy, huella)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_policies p
       WHERE p.schemaname = 'public' AND p.tablename = r.tabla AND p.policyname = r.policy
         AND md5(coalesce(p.qual, '') || '|' || coalesce(p.with_check, '')) = r.huella) THEN
      RAISE EXCEPTION 'La policy %.% no es la de prod del 2026-10-29: rehacer la migración sobre la viva', r.tabla, r.policy;
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'public' AND table_name = 'proveedores_eliminados'
                AND column_name = 'sucursal_id') THEN
    RAISE EXCEPTION 'proveedores_eliminados ya tiene sucursal_id: rehacer la migración sobre lo vivo';
  END IF;

  IF to_regprocedure('public.auditoria_rpcs_definer()') IS NOT NULL
     OR to_regprocedure('public.proveedores_eliminados_sucursal()') IS NOT NULL THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer o proveedores_eliminados_sucursal ya existen: rehacer la migración sobre lo vivo';
  END IF;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · asignar_usuario_sucursal y desasignar_usuario_sucursal (#1291)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.asignar_usuario_sucursal(
  p_usuario_id uuid,
  p_sucursal_id bigint,
  p_rol character varying DEFAULT 'mismo'::character varying,
  p_es_default boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede asignar sucursales');
  END IF;

  -- Sin esto, un admin de la sucursal 1 se agrega a sí mismo a la 2 y
  -- current_sucursal_id() lo autoriza a partir de ahí.
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo podés asignar usuarios a una sucursal a la que pertenecés');
  END IF;

  -- #1291: y sin esto se trae a un usuario de otra sucursal con su uuid, y desde
  -- ahí lo ve entero (su email, su bot, su historial). Como cambiarle el rol o
  -- el activo (404), lo hace un admin de todas sus sucursales.
  IF NOT admin_abarca_sucursales_de(p_usuario_id) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Ese usuario no es de tus sucursales, o también trabaja en otras: lo asigna un admin de todas sus sucursales');
  END IF;

  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  VALUES (p_usuario_id, p_sucursal_id, p_rol, p_es_default)
  ON CONFLICT (usuario_id, sucursal_id) DO UPDATE
    SET rol = EXCLUDED.rol,
        es_default = EXCLUDED.es_default;

  IF p_es_default THEN
    UPDATE usuario_sucursales SET es_default = false
     WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.desasignar_usuario_sucursal(
  p_usuario_id uuid,
  p_sucursal_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede desasignar sucursales');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo podés desasignar usuarios de una sucursal a la que pertenecés');
  END IF;

  -- #1291: como asignar, lo hace un admin de todas las sucursales del usuario.
  IF NOT admin_abarca_sucursales_de(p_usuario_id) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Ese usuario no es de tus sucursales, o también trabaja en otras: lo desasigna un admin de todas sus sucursales');
  END IF;

  -- Un usuario sin sucursales no es de nadie: ningún admin lo vuelve a asignar
  -- desde la app (admin_abarca_sucursales_de da false).
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Es la única sucursal del usuario: asignalo a otra antes de sacarlo de ésta');
  END IF;

  DELETE FROM usuario_sucursales
   WHERE usuario_id = p_usuario_id AND sucursal_id = p_sucursal_id;

  RETURN jsonb_build_object('success', true);
END;
$fn$;

-- CREATE OR REPLACE conserva el ACL; se repite el de la 228.
REVOKE ALL ON FUNCTION public.asignar_usuario_sucursal(uuid, bigint, character varying, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.asignar_usuario_sucursal(uuid, bigint, character varying, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.desasignar_usuario_sucursal(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.desasignar_usuario_sucursal(uuid, bigint) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 2 · Las cinco policies (#1272)
-- -------------------------------------------------------------------------
-- cliente_preventistas: el admin asigna y desasigna preventistas de los
-- clientes de su sucursal activa. La rama del preventista no cambia: el
-- trigger cliente_preventistas_no_ajeno la acota.
ALTER POLICY cp_delete ON public.cliente_preventistas
  USING (es_admin() AND cliente_de_sucursal_activa(cliente_id));

ALTER POLICY cp_insert ON public.cliente_preventistas
  WITH CHECK ((es_admin() AND cliente_de_sucursal_activa(cliente_id))
              OR preventista_id = auth.uid());

-- metas_gerenciales y reportes_mensuales: lo de sus sucursales, y la Red
-- (sucursal_id NULL) sólo el admin de todas las activas. Es la cuenta de
-- _sucursales_red() escrita acá: esa función es de server y authenticated no
-- la ejecuta (la policy la evalúa el que lee, y daría 42501).
ALTER POLICY metas_gerenciales_admin_select ON public.metas_gerenciales
  USING (es_admin()
         AND (sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                               WHERE us.usuario_id = auth.uid())
              OR (sucursal_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM sucursales s
                                   WHERE s.activa
                                     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                                                      WHERE us.usuario_id = auth.uid()
                                                        AND us.sucursal_id = s.id)))));

ALTER POLICY reportes_mensuales_admin_select ON public.reportes_mensuales
  USING (es_admin()
         AND (sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                               WHERE us.usuario_id = auth.uid())
              OR (sucursal_id IS NULL
                  AND NOT EXISTS (SELECT 1 FROM sucursales s
                                   WHERE s.activa
                                     AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                                                      WHERE us.usuario_id = auth.uid()
                                                        AND us.sucursal_id = s.id)))));

-- proveedores_eliminados: la sucursal del proveedor, que la tabla no guardaba.
ALTER TABLE public.proveedores_eliminados
  ADD COLUMN sucursal_id bigint REFERENCES public.sucursales(id);

COMMENT ON COLUMN public.proveedores_eliminados.sucursal_id IS
  'Sucursal del proveedor eliminado (la completa trg_proveedores_eliminados_sucursal). '
  'NULL en las filas anteriores a #1272: no las lee nadie por REST.';

CREATE OR REPLACE FUNCTION public.proveedores_eliminados_sucursal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  -- eliminar_proveedor archiva la fila antes de borrar el proveedor: todavía
  -- está. Una sucursal que mande el que inserta se respeta.
  IF NEW.sucursal_id IS NULL THEN
    SELECT pr.sucursal_id INTO NEW.sucursal_id
      FROM proveedores pr
     WHERE pr.id = NEW.proveedor_id;
  END IF;
  RETURN NEW;
END;
$fn$;

-- De trigger: no necesita EXECUTE para nadie de la app (405).
REVOKE ALL ON FUNCTION public.proveedores_eliminados_sucursal() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_proveedores_eliminados_sucursal
  BEFORE INSERT ON public.proveedores_eliminados
  FOR EACH ROW EXECUTE FUNCTION public.proveedores_eliminados_sucursal();

ALTER POLICY proveedores_eliminados_select_admin ON public.proveedores_eliminados
  USING (es_admin()
         AND sucursal_id IN (SELECT us.sucursal_id FROM usuario_sucursales us
                              WHERE us.usuario_id = auth.uid()));

-- -------------------------------------------------------------------------
-- 3 · auditoria_rpcs_definer() (#1291)
-- -------------------------------------------------------------------------
-- Heurística de texto sobre el cuerpo sin comentarios. "Acota" un parámetro
-- cuando el cuerpo, con el parámetro o un alias suyo (v := p, v := COALESCE(p,
-- ...)):
--   · usuario: lo pasa a un helper que lo relaciona con las sucursales del que
--     llama, o lo compara con auth.uid() (o un alias), o lo cruza con
--     usuario_sucursales en un statement que también mira la sucursal activa o
--     al que llama;
--   · sucursal: lo compara con current_sucursal_id() (o un alias), lo busca
--     en un array (= ANY, <@), se lo pasa a _tablero_sucursales o
--     comision_regla_alcanzable, o lo cruza con usuario_sucursales en un
--     statement que mira al que llama.
CREATE OR REPLACE FUNCTION public.auditoria_rpcs_definer()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
  c_escribe_usuarios CONSTANT text :=
    '(insert\s+into|update|delete\s+from)\s+(public\.)?(usuario_sucursales|perfil_roles|perfiles|bot_usuarios|bot_digest_config)\M';
  c_helper_usuario   CONSTANT text :=
    '(admin_abarca_sucursales_de|admin_comparte_sucursal_con|bot_admin_puede_gestionar|perfil_de_sucursal_activa)';
  c_helper_sucursal  CONSTANT text := '(_tablero_sucursales|comision_regla_alcanzable)';
  c_op               CONSTANT text := '\s*(=|<>|!=|is\s+(not\s+)?distinct\s+from)\s*';
  r         record;
  v_stmts   text[];
  v_uid     text;  -- auth.uid() y sus alias, como alternativa de regex
  v_suc     text;  -- current_sucursal_id() y sus alias
  v_alias   text;  -- el parámetro y sus alias
  v_param   text;
  v_tipo    oid;
  v_clase   text;
  v_acotado boolean;
  v_tablas  text[];
  v_n       int := 0;
  v_gestion jsonb := '[]';
  v_params  jsonb := '[]';
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS firma,
           p.proname::text AS nombre,
           COALESCE(p.proargnames[1:p.pronargs], '{}') AS nombres,
           -- oidvector arranca en 0: se rearma para que vaya con proargnames.
           ARRAY(SELECT unnest(p.proargtypes::oid[])) AS tipos,
           lower(regexp_replace(regexp_replace(regexp_replace(
             p.prosrc, '/\*.*?\*/', ' ', 'g'), '--[^\n]*', ' ', 'g'), '\s+', ' ', 'g')) AS src
      FROM pg_proc p
      JOIN pg_type t ON t.oid = p.prorettype
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.prokind = 'f'
       AND p.prosecdef
       AND t.typname <> 'trigger'
       AND (has_function_privilege('authenticated', p.oid, 'EXECUTE')
            OR has_function_privilege('anon', p.oid, 'EXECUTE'))
       AND NOT EXISTS (SELECT 1 FROM pg_depend d
                        WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
     ORDER BY 1
  LOOP
    v_n := v_n + 1;
    v_stmts := regexp_split_to_array(r.src, ';');

    -- Los alias: `v := x` (y `v tipo := x` en el DECLARE) y `x INTO v`. Una
    -- palabra de más (el tipo, un THEN) entra como alias y no molesta.
    SELECT string_agg(DISTINCT a, '|') INTO v_uid FROM (
      SELECT 'auth\.uid\(\)' AS a
      UNION SELECT '\m' || m[1] || '\M' FROM regexp_matches(r.src, '([a-z_][a-z0-9_]*)\s*:=\s*auth\.uid\(\)', 'g') m
      UNION SELECT '\m' || m[1] || '\M' FROM regexp_matches(r.src, '([a-z_][a-z0-9_]*)\s+[a-z_][a-z0-9_]*\s*:=\s*auth\.uid\(\)', 'g') m
      UNION SELECT '\m' || m[1] || '\M' FROM regexp_matches(r.src, 'auth\.uid\(\)\s+into\s+([a-z_][a-z0-9_]*)', 'g') m
    ) x;
    SELECT string_agg(DISTINCT a, '|') INTO v_suc FROM (
      SELECT '(public\.)?current_sucursal_id\(\)' AS a
      UNION SELECT '\m' || m[1] || '\M' FROM regexp_matches(r.src, '([a-z_][a-z0-9_]*)\s*:=\s*(?:public\.)?current_sucursal_id\(\)', 'g') m
      UNION SELECT '\m' || m[1] || '\M' FROM regexp_matches(r.src, '([a-z_][a-z0-9_]*)\s+[a-z_][a-z0-9_]*\s*:=\s*(?:public\.)?current_sucursal_id\(\)', 'g') m
      UNION SELECT '\m' || m[1] || '\M' FROM regexp_matches(r.src, '(?:public\.)?current_sucursal_id\(\)\s+into\s+([a-z_][a-z0-9_]*)', 'g') m
    ) x;

    -- 1 · Gestión de usuarios: cada escritura de esas tablas pasa por un helper
    -- que acota al usuario, o es sobre el que llama.
    SELECT array_agg(DISTINCT m[3]) INTO v_tablas
      FROM regexp_matches(r.src, c_escribe_usuarios, 'g') m;
    IF v_tablas IS NOT NULL THEN
      v_gestion := v_gestion || jsonb_build_object(
        'firma', r.firma,
        'nombre', r.nombre,
        'tablas', to_jsonb(v_tablas),
        'acota', r.src ~ (c_helper_usuario || '\s*\(')
                 OR NOT EXISTS (SELECT 1 FROM unnest(v_stmts) s
                                 WHERE s ~ c_escribe_usuarios AND s !~ ('(' || v_uid || ')'))
      );
    END IF;

    -- 2 · Los parámetros de usuario y de sucursal que usa.
    FOR i IN 1 .. coalesce(array_length(r.nombres, 1), 0) LOOP
      v_param := lower(r.nombres[i]);
      v_tipo  := r.tipos[i];
      CONTINUE WHEN v_param IS NULL OR v_param = '';
      v_clase := CASE
        WHEN v_param ~ 'sucursal' THEN 'sucursal'
        WHEN v_tipo = 'uuid'::regtype AND v_param !~ '(request_id|categoria|marca)' THEN 'usuario'
      END;
      CONTINUE WHEN v_clase IS NULL OR r.src !~ ('\m' || v_param || '\M');

      SELECT string_agg(DISTINCT a, '|') INTO v_alias FROM (
        SELECT '\m' || v_param || '\M' AS a
        UNION SELECT '\m' || m[1] || '\M'
          FROM regexp_matches(r.src, '([a-z_][a-z0-9_]*)\s*:=\s*(?:coalesce\s*\(\s*)?' || v_param || '\M', 'g') m
      ) x;

      IF v_clase = 'usuario' THEN
        v_acotado :=
             r.src ~ (c_helper_usuario || '\s*\([^;]*?(' || v_alias || ')')
          OR r.src ~ ('(' || v_alias || ')' || c_op || '(' || v_uid || ')')
          OR r.src ~ ('(' || v_uid || ')' || c_op || '(' || v_alias || ')')
          OR EXISTS (SELECT 1 FROM unnest(v_stmts) s
                      WHERE s ~ ('(' || v_alias || ')') AND s ~ '\musuario_sucursales\M'
                        AND (s ~ ('(' || v_suc || ')') OR s ~ ('(' || v_uid || ')')));
      ELSE
        v_acotado :=
             r.src ~ ('(' || v_alias || ')' || c_op || '(' || v_suc || ')')
          OR r.src ~ ('(' || v_suc || ')' || c_op || '(' || v_alias || ')')
          OR r.src ~ ('(' || v_alias || ')\s*(=\s*any\s*\(|<@)')
          OR r.src ~ (c_helper_sucursal || '\s*\(\s*(' || v_alias || ')')
          OR EXISTS (SELECT 1 FROM unnest(v_stmts) s
                      WHERE s ~ ('(' || v_alias || ')') AND s ~ '\musuario_sucursales\M'
                        AND s ~ ('(' || v_uid || ')'));
      END IF;

      v_params := v_params || jsonb_build_object(
        'firma', r.firma, 'nombre', r.nombre, 'parametro', v_param,
        'clase', v_clase, 'acotado', v_acotado);
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'generado_at', now(),
    'funciones', v_n,
    'gestion_usuarios', v_gestion,
    'parametros', v_params);
END;
$fn$;

COMMENT ON FUNCTION public.auditoria_rpcs_definer() IS
  'RPCs SECURITY DEFINER alcanzables desde la API: las que escriben la gestión de usuarios y '
  'los parámetros de usuario y de sucursal que usan, con si el texto muestra que los acotan. '
  'La lee scripts/check-rpcs-definer.mjs. #1291.';

REVOKE ALL ON FUNCTION public.auditoria_rpcs_definer() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_rpcs_definer() TO service_role;

-- -------------------------------------------------------------------------
-- 4 · Verificación
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  r      record;
  v_a    jsonb;
BEGIN
  -- Las RPCs: authenticated sí, anon no.
  FOR r IN SELECT * FROM (VALUES
      ('public.asignar_usuario_sucursal(uuid,bigint,character varying,boolean)'),
      ('public.desasignar_usuario_sucursal(uuid,bigint)')) AS v(firma)
  LOOP
    IF NOT has_function_privilege('authenticated', r.firma, 'EXECUTE')
       OR has_function_privilege('anon', r.firma, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedó con el EXECUTE equivocado', r.firma;
    END IF;
  END LOOP;

  -- Lo de server: nadie de la API.
  FOR r IN SELECT * FROM (VALUES
      ('public.auditoria_rpcs_definer()'),
      ('public.proveedores_eliminados_sucursal()')) AS v(firma)
  LOOP
    IF has_function_privilege('anon', r.firma, 'EXECUTE')
       OR has_function_privilege('authenticated', r.firma, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                   WHERE p.oid = r.firma::regprocedure AND a.grantee = 0) THEN
      RAISE EXCEPTION '% es alcanzable desde la API', r.firma;
    END IF;
  END LOOP;

  -- Ninguna de las cinco policies tiene ya una rama admin sin sucursal (lo
  -- mismo que mira check-rama-admin.mjs, a ojo: todas nombran la sucursal).
  IF EXISTS (
    SELECT 1 FROM pg_policies p
     WHERE p.schemaname = 'public'
       AND (p.tablename, p.policyname) IN (
             ('cliente_preventistas', 'cp_delete'), ('cliente_preventistas', 'cp_insert'),
             ('metas_gerenciales', 'metas_gerenciales_admin_select'),
             ('proveedores_eliminados', 'proveedores_eliminados_select_admin'),
             ('reportes_mensuales', 'reportes_mensuales_admin_select'))
       AND coalesce(p.qual, '') || coalesce(p.with_check, '') !~ 'sucursal') THEN
    RAISE EXCEPTION 'Una de las cinco policies de #1272 sigue sin mirar la sucursal';
  END IF;

  -- El gate ve la clase de #1291: las dos RPCs acotan, y nada que escriba la
  -- gestión de usuarios queda sin acotar.
  v_a := public.auditoria_rpcs_definer();
  IF (SELECT count(*) FROM jsonb_array_elements(v_a->'gestion_usuarios') g
       WHERE g->>'nombre' IN ('asignar_usuario_sucursal', 'desasignar_usuario_sucursal')
         AND (g->>'acota')::boolean) <> 2 THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer no ve que asignar y desasignar acotan al usuario';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'gestion_usuarios') g
              WHERE NOT (g->>'acota')::boolean) THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer: hay RPCs de gestión de usuarios sin acotar: %',
      (SELECT string_agg(g->>'firma', ', ') FROM jsonb_array_elements(v_a->'gestion_usuarios') g
        WHERE NOT (g->>'acota')::boolean);
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'parametros') p
              WHERE p->>'nombre' IN ('asignar_usuario_sucursal', 'desasignar_usuario_sucursal')
                AND NOT (p->>'acotado')::boolean) THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer: asignar o desasignar tienen un parámetro sin acotar';
  END IF;
END
$verif$;

-- ROLLBACK: volver a aplicar asignar_usuario_sucursal y desasignar_usuario_sucursal
-- de migrations/228_cada_uno_ve_lo_de_su_sucursal.sql; las cinco policies con su
-- expresión de antes (cp_delete USING (es_admin()); cp_insert WITH CHECK
-- (es_admin() OR preventista_id = auth.uid()); las tres *_admin_select USING
-- (EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND
-- perfiles.rol = 'admin'))); DROP TRIGGER trg_proveedores_eliminados_sucursal,
-- DROP FUNCTION proveedores_eliminados_sucursal(), DROP COLUMN
-- proveedores_eliminados.sucursal_id; DROP FUNCTION auditoria_rpcs_definer().
