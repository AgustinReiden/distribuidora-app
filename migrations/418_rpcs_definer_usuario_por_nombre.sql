-- =========================================================================
-- 418 · EL GATE DE LAS RPCs DEFINER RECONOCE UN USUARIO POR SU NOMBRE (#1291)
--
-- Arreglo de la 415 antes de mergear #1338. auditoria_rpcs_definer() tomaba
-- como usuario todo parámetro uuid salvo *request_id, categoria y marca. La 416
-- (aplicar_control_stock, #1295) sumó p_planilla_id, que es el id de una
-- descarga de la planilla de control: el gate lo marcaba sin acotar y
-- scripts/check-rpcs-definer.mjs quedaba en rojo. Cada uuid nuevo que no fuera
-- un usuario iba a hacer lo mismo.
--
-- Ahora un uuid es de usuario si su nombre lo dice: usuario, perfil,
-- preventista, transportista, vendedor, encargado, admin, chofer o deposito.
-- Son los nombres de todos los uuid de usuario de las RPCs de hoy (p_usuario_id,
-- p_perfil_id, p_preventista_id, p_nuevo_preventista_id, p_transportista_id).
-- Un uuid de usuario con otro nombre no lo ve: está en lo que NO ve el script.
-- Nada más cambia.
--
-- PERMISOS: los de la 415 (CREATE OR REPLACE conserva el ACL; se repite).
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · La función es la de la 415
-- -------------------------------------------------------------------------
DO $vivas$
BEGIN
  IF to_regprocedure('public.auditoria_rpcs_definer()') IS NULL
     OR (SELECT md5(prosrc) FROM pg_proc
          WHERE oid = to_regprocedure('public.auditoria_rpcs_definer()'))
        <> '7dbe506faf1c1d947bc73ea2f6789436' THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer no es la de la 415: rehacer la migración sobre la definición viva';
  END IF;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · La función
-- -------------------------------------------------------------------------
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
  c_nombre_usuario   CONSTANT text :=
    '(usuario|perfil|preventista|transportista|vendedor|encargado|admin|chofer|deposito)';
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
      -- Un uuid es de usuario por su nombre, no por el tipo (#1338): la 416 sumó
      -- p_planilla_id, que es una descarga de la planilla de control.
      v_clase := CASE
        WHEN v_param ~ 'sucursal' THEN 'sucursal'
        WHEN v_tipo = 'uuid'::regtype AND v_param ~ c_nombre_usuario THEN 'usuario'
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

REVOKE ALL ON FUNCTION public.auditoria_rpcs_definer() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_rpcs_definer() TO service_role;

-- -------------------------------------------------------------------------
-- 2 · Verificación
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_a jsonb := public.auditoria_rpcs_definer();
BEGIN
  IF has_function_privilege('anon', 'public.auditoria_rpcs_definer()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_rpcs_definer()', 'EXECUTE') THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer es alcanzable desde la API';
  END IF;

  -- Un uuid que no es un usuario ya no entra.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'parametros') p
              WHERE p->>'clase' = 'usuario'
                AND p->>'parametro' ~ '(planilla|request_id|categoria|marca)') THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer sigue tomando como usuario un uuid que no lo es';
  END IF;

  -- Y los de usuario siguen entrando: asignar_usuario_sucursal, acotado.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'parametros') p
                  WHERE p->>'nombre' = 'asignar_usuario_sucursal' AND p->>'parametro' = 'p_usuario_id'
                    AND p->>'clase' = 'usuario' AND (p->>'acotado')::boolean)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'parametros') p
                     WHERE p->>'parametro' = 'p_transportista_id' AND p->>'clase' = 'usuario') THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer dejó de ver los parámetros de usuario';
  END IF;
END
$verif$;

-- ROLLBACK: volver a aplicar la sección 3 de
-- migrations/415_permisos_el_admin_y_sus_usuarios.sql (auditoria_rpcs_definer).
