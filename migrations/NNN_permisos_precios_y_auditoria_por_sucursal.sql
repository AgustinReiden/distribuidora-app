-- NNN · Los precios masivos se acotan a la sucursal, la auditoría queda para el servidor y el
--       gate ve las definer que no nombran la sucursal (#1438).
--
-- QUÉ PASABA
--   Tres funciones SECURITY DEFINER viejas sólo pedían el rol admin. Una definer no pasa por
--   RLS, así que saltaban la regla de #1243/#1244: el admin gestiona lo de SUS sucursales.
--   · actualizar_precios_masivo(jsonb) hacía UPDATE productos ... WHERE id = ... sin mirar la
--     sucursal. La policy REST mt_productos_update pide sucursal_id = current_sucursal_id();
--     la RPC no. Un admin de la 1 le cambiaba el precio a un producto de la 2 armando la
--     llamada a mano (el front sólo manda los de la sucursal activa).
--   · get_audit_history(text,text,integer) y get_suspicious_activity(integer) leían
--     audit_logs sin mirar audit_logs.sucursal_id, y las filas de productos traen los costos.
--     audit_logs no tiene policies: eran la única entrada a la tabla desde la API.
--   El gate de #1291 (scripts/check-rpcs-definer.mjs) no las veía: mira las definer que
--   reciben un usuario o una sucursal por parámetro, y éstas reciben ids o nombres de tabla.
--
-- QUÉ CAMBIA
--   1 · actualizar_precios_masivo actualiza sólo los productos de la sucursal activa, como la
--       policy. El de otra sucursal cuenta como error, igual que el que no existe y con el
--       mismo texto: no dice si el id existe en otra. Sin sucursal activa (current_sucursal_id()
--       da NULL si el header pide una que no es del usuario) no toca nada y lo dice. El resto
--       no cambia: sigue siendo de admin, sigue sin ser todo o nada (actualiza los que puede
--       y devuelve un error por cada uno que no) y la firma y el EXECUTE son los mismos.
--   2 · get_audit_history y get_suspicious_activity quedan sólo para el servidor: REVOKE de
--       PUBLIC, anon y authenticated (decisión del dueño, 04/11). Nadie las llama desde src/ ni
--       desde el bot. Los cuerpos no cambian.
--   3 · auditoria_rpcs_definer() suma 'tablas_sucursal': cada definer alcanzable desde la API
--       que lee o escribe (FROM, JOIN, UPDATE, INTO) una tabla o vista de public con
--       sucursal_id, y si su cuerpo nombra alguna sucursal. El gate falla ante una que no la
--       nombra y no está en scripts/rpcs-definer-permitidas.json ("tablas"). Lo demás de la
--       función no cambia.
--
-- Ensayo: scripts/test-permisos-sucursal-1438.sql.
-- Aplicar desde el contenido LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

DO $premisas$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('public.actualizar_precios_masivo(jsonb)', 'b096f898fa0abe6068b0d926cfbcb6ee'),
      ('public.get_audit_history(text,text,integer)', '21de982546f830ad2253cf2f127fb024'),
      ('public.get_suspicious_activity(integer)', '5f5d5a943b72bc2b6d6c02081edaa334'),
      ('public.auditoria_rpcs_definer()', 'b66fb7afbcdd6192d0e05f316153b380')
    ) AS t(firma, hash)
  LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure) <> r.hash THEN
      RAISE EXCEPTION '% cambió en prod (md5 %): rehacer el parche sobre el cuerpo vigente',
        r.firma, (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.firma::regprocedure);
    END IF;
  END LOOP;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · Los precios masivos, de la sucursal activa
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.actualizar_precios_masivo(p_productos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_item JSONB;
  v_actualizados INT := 0;
  v_errores TEXT[] := '{}';
  v_producto_id INT;
  v_sucursal_id BIGINT;
BEGIN
  -- SECURITY FIX: Solo admins pueden actualizar precios masivamente
  IF NOT es_admin() THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No autorizado: Solo administradores pueden actualizar precios')
    );
  END IF;

  -- #1438: una definer no pasa por RLS. Como la policy mt_productos_update, sólo los
  -- productos de la sucursal activa. current_sucursal_id() da NULL si el header pide una
  -- sucursal que no es del usuario.
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No hay una sucursal activa: recargá la página e intentá de nuevo')
    );
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)
  LOOP
    BEGIN
      v_producto_id := (v_item->>'producto_id')::INT;

      UPDATE productos
      SET
        precio_sin_iva = COALESCE((v_item->>'precio_neto')::DECIMAL, precio_sin_iva),
        impuestos_internos = COALESCE((v_item->>'imp_internos')::DECIMAL, impuestos_internos),
        precio = COALESCE((v_item->>'precio_final')::DECIMAL, precio),
        updated_at = NOW()
      WHERE id = v_producto_id
        AND sucursal_id = v_sucursal_id;

      -- El de otra sucursal cuenta como el que no existe, con el mismo texto.
      IF FOUND THEN
        v_actualizados := v_actualizados + 1;
      ELSE
        v_errores := array_append(v_errores,
          'Producto ID ' || v_producto_id || ' no encontrado en la sucursal activa');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errores := array_append(v_errores,
        'Error en producto ID ' || COALESCE(v_producto_id::TEXT, 'desconocido') || ': ' || SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', array_length(v_errores, 1) IS NULL,
    'actualizados', v_actualizados,
    'errores', COALESCE(to_jsonb(v_errores), '[]'::jsonb)
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.actualizar_precios_masivo(jsonb) FROM PUBLIC, anon;

-- -------------------------------------------------------------------------
-- 2 · La auditoría, sólo para el servidor
-- -------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.get_audit_history(text, text, integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_suspicious_activity(integer) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 3 · El gate ve las definer que no nombran la sucursal
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
  v_re_suc  text;  -- las tablas y vistas de public con sucursal_id, detrás de FROM/JOIN/UPDATE/INTO
  v_n       int := 0;
  v_gestion jsonb := '[]';
  v_params  jsonb := '[]';
  v_suc_tablas jsonb := '[]';
BEGIN
  -- Lo que lee `from x.` es una columna calificada, no la tabla: de ahí el lookahead.
  SELECT '\m(from|join|update|into)\s+(public\.)?('
         || string_agg(c.relname::text, '|' ORDER BY length(c.relname::text) DESC, c.relname::text)
         || ')\M(?!\s*\.)'
    INTO v_re_suc
    FROM pg_class c
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'sucursal_id' AND NOT a.attisdropped
   WHERE c.relnamespace = 'public'::regnamespace
     AND c.relkind IN ('r', 'p', 'v', 'm');
  IF v_re_suc IS NULL THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer: ninguna tabla de public tiene sucursal_id; no puede mirar';
  END IF;

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

    -- 3 · Las tablas con sucursal que lee o escribe (#1438). Si el cuerpo no nombra
    -- ninguna sucursal (sucursal_id, current_sucursal_id(), _sucursales_red(), un
    -- parámetro o una variable de sucursal), no la está acotando. Las tablas
    -- sucursales y usuario_sucursales no cuentan como nombrarla.
    SELECT array_agg(DISTINCT m[3] ORDER BY m[3]) INTO v_tablas
      FROM regexp_matches(r.src, v_re_suc, 'g') m;
    IF v_tablas IS NOT NULL THEN
      v_suc_tablas := v_suc_tablas || jsonb_build_object(
        'firma', r.firma,
        'nombre', r.nombre,
        'tablas', to_jsonb(v_tablas),
        'nombra_sucursal', EXISTS (
          SELECT 1 FROM regexp_matches(r.src, '\m([a-z0-9_]*sucursal[a-z0-9_]*)\M', 'g') m
           WHERE m[1] NOT IN ('sucursales', 'usuario_sucursales')));
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'generado_at', now(),
    'funciones', v_n,
    'gestion_usuarios', v_gestion,
    'parametros', v_params,
    'tablas_sucursal', v_suc_tablas);
END;
$fn$;

REVOKE ALL ON FUNCTION public.auditoria_rpcs_definer() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_rpcs_definer() TO service_role;

-- -------------------------------------------------------------------------
-- 4 · Verificación
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_a jsonb := public.auditoria_rpcs_definer();
BEGIN
  -- La de precios ahora nombra la sucursal.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'tablas_sucursal') t
                  WHERE t->>'firma' = 'actualizar_precios_masivo(jsonb)'
                    AND t->'tablas' ? 'productos' AND (t->>'nombra_sucursal')::boolean) THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer no ve que actualizar_precios_masivo nombra la sucursal';
  END IF;
  -- Las de auditoría ya no son alcanzables desde la API: el gate no las mira.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'tablas_sucursal') t
              WHERE t->>'nombre' IN ('get_audit_history', 'get_suspicious_activity')) THEN
    RAISE EXCEPTION 'get_audit_history o get_suspicious_activity siguen alcanzables desde la API';
  END IF;
  -- Y los parámetros siguen viéndose como antes.
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_a->'parametros') p
                  WHERE p->>'nombre' = 'asignar_usuario_sucursal' AND p->>'parametro' = 'p_usuario_id'
                    AND (p->>'acotado')::boolean) THEN
    RAISE EXCEPTION 'auditoria_rpcs_definer dejó de ver los parámetros de usuario';
  END IF;
END
$verif$;

DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT t.firma, t.hash, t.acl, md5(p.prosrc) AS h, p.proacl::text AS a
      FROM (VALUES
        ('public.actualizar_precios_masivo(jsonb)', '71d752586e664aa900cca7cea606f32d',
         '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
        ('public.get_audit_history(text,text,integer)', '21de982546f830ad2253cf2f127fb024',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.get_suspicious_activity(integer)', '5f5d5a943b72bc2b6d6c02081edaa334',
         '{postgres=X/postgres,service_role=X/postgres}'),
        ('public.auditoria_rpcs_definer()', '38f466a6f15ed94b2e19cc37e4bc370e',
         '{postgres=X/postgres,service_role=X/postgres}')
      ) AS t(firma, hash, acl)
      JOIN pg_proc p ON p.oid = t.firma::regprocedure
  LOOP
    IF r.h <> r.hash OR r.a IS DISTINCT FROM r.acl THEN
      RAISE EXCEPTION '% no quedó como en el repo (md5 %, acl %)', r.firma, r.h, r.a;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
