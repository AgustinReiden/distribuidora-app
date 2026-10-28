-- 405 · Funciones de trigger sin EXECUTE para la app, y el depósito sin los
-- costos de compra (#1245, SEG-4 y SEG-5).
--
-- SEG-4 · perfiles_guard_desactivacion y perfiles_sync_acceso_auth tenían
-- EXECUTE para authenticated, contra la regla de CLAUDE.md: una función de
-- trigger la invoca el executor como parte del DML, no el caller. Llamarlas
-- directo falla, pero la segunda escribe en auth.users. Quedan en postgres +
-- service_role, como pagos_forzar_usuario (#1074). Y para que no vuelva:
-- auditoria_permisos_execute() informa toda función RETURNS trigger que anon o
-- authenticated puedan ejecutar, y scripts/check-permisos.mjs falla con una.
--
-- SEG-5 · El depósito leía compra_items.costo_unitario, costo_real_unitario y
-- costo_promedio_anterior, y nota_credito_items.costo_unitario: las policies de
-- SELECT de las dos tablas lo nombraban desde el baseline. Decisión del dueño
-- (2026-10-28): no tiene que verlos. Ninguna pantalla del depósito lee esas
-- tablas —/compras es de admin y encargado, el catálogo del depósito sale de
-- catalogo_deposito() y los vencimientos de producto_lotes—, así que se lo saca
-- de las dos policies en vez de cerrar columnas como en #974: una fila de esas
-- tablas es un costo, no hay nada en ellas que el depósito necesite.

-- ------------------------------------------------------------------- SEG-4 ---
REVOKE EXECUTE ON FUNCTION public.perfiles_guard_desactivacion() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.perfiles_sync_acceso_auth()    FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.auditoria_permisos_execute()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
WITH f AS (
  SELECT
    p.oid,
    p.oid::regprocedure::text                                   AS firma,
    pg_get_userbyid(p.proowner)                                 AS owner,
    p.prosecdef                                                 AS security_definer,
    (t.typname = 'trigger')                                     AS es_trigger,
    COALESCE(array_to_string(p.proacl, ' | '), '(default: owner + PUBLIC)') AS acl,
    has_function_privilege('anon',          p.oid, 'EXECUTE')    AS ejecuta_anon,
    has_function_privilege('authenticated', p.oid, 'EXECUTE')    AS ejecuta_authenticated,
    has_function_privilege('service_role',  p.oid, 'EXECUTE')    AS ejecuta_service_role,
    (p.provolatile = 'v')                                        AS volatil,
    pg_get_functiondef(p.oid)                                    AS def
  FROM pg_proc p
  JOIN pg_type t ON t.oid = p.prorettype
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.prokind IN ('f', 'p')
    -- Las funciones que trae una extensión (pg_trgm, unaccent, pgcrypto…) no
    -- son nuestras y no se tocan.
    AND NOT EXISTS (
      SELECT 1 FROM pg_depend d
      WHERE d.objid = p.oid
        AND d.classid = 'pg_proc'::regclass
        AND d.deptype = 'e'
    )
),
c AS (
  SELECT
    f.*,
    (f.def ~* 'auth\.uid\(\)|es_admin\(\)|es_encargado_o_admin\(\)|current_sucursal_id\(\)|es_preventista\(\)|es_transportista\(\)|_rol_en_sucursal\(')
      AS menciona_guarda,
    -- Heurística de escritura: grep sobre el cuerpo Y volatilidad. Postgres no
    -- deja que una función STABLE/IMMUTABLE haga INSERT/UPDATE/DELETE, así que
    -- exigir VOLATILE descarta los falsos positivos por comentarios, strings o
    -- una regex citada dentro del propio cuerpo (esta función se matcheaba sola).
    (f.volatil AND f.def ~* '\m(insert|update|delete|truncate)\M')
      AS escribe
  FROM f
)
SELECT jsonb_build_object(
  'generado_at', now(),

  'total_funciones',           (SELECT count(*) FROM c),
  'security_definer',          (SELECT count(*) FROM c WHERE security_definer),

  -- El veredicto duro: después de la 188 esto tiene que ser 0.
  'expuestas_a_anon',          (SELECT count(*) FROM c WHERE ejecuta_anon),
  'expuestas_a_anon_definer',  (SELECT count(*) FROM c WHERE ejecuta_anon AND security_definer),
  'expuestas_a_anon_sin_guarda',
    (SELECT count(*) FROM c WHERE ejecuta_anon AND security_definer AND NOT menciona_guarda),
  'expuestas_a_anon_sin_guarda_que_escriben',
    (SELECT count(*) FROM c WHERE ejecuta_anon AND security_definer AND NOT menciona_guarda AND escribe),

  -- El otro veredicto duro (#1245): una función de trigger no necesita EXECUTE
  -- para nadie de la app. Lo dispara el executor como parte del DML.
  'triggers_ejecutables_por_la_app',
    (SELECT count(*) FROM c WHERE es_trigger AND (ejecuta_anon OR ejecuta_authenticated)),

  -- Riesgo residual: lo que un usuario logueado puede invocar directo sin que la
  -- función chequee nada. No es un agujero abierto a internet, pero es la cola
  -- de revisión que queda después de la 188.
  'definer_sin_guarda_para_authenticated',
    (SELECT count(*) FROM c
      WHERE ejecuta_authenticated AND security_definer AND NOT menciona_guarda AND NOT es_trigger),

  'detalle_anon', COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
        'firma', firma, 'owner', owner,
        'security_definer', security_definer, 'trigger', es_trigger,
        'menciona_guarda', menciona_guarda, 'escribe', escribe,
        'acl', acl
      ) ORDER BY security_definer DESC, escribe DESC, firma)
     FROM c WHERE ejecuta_anon),
    '[]'::jsonb),

  'detalle_triggers_ejecutables', COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
        'firma', firma, 'anon', ejecuta_anon, 'authenticated', ejecuta_authenticated, 'acl', acl
      ) ORDER BY firma)
     FROM c WHERE es_trigger AND (ejecuta_anon OR ejecuta_authenticated)),
    '[]'::jsonb),

  'detalle_authenticated_sin_guarda', COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
        'firma', firma, 'escribe', escribe
      ) ORDER BY escribe DESC, firma)
     FROM c
     WHERE ejecuta_authenticated AND security_definer AND NOT menciona_guarda AND NOT es_trigger),
    '[]'::jsonb)
);
$function$;


-- ------------------------------------------------------------------- SEG-5 ---
DROP POLICY IF EXISTS mt_compra_items_select ON public.compra_items;
CREATE POLICY mt_compra_items_select ON public.compra_items
  FOR SELECT TO authenticated
  USING (es_encargado_o_admin() AND sucursal_id = current_sucursal_id());
COMMENT ON POLICY mt_compra_items_select ON public.compra_items IS
  'Sólo admin y encargado: cada línea es un costo de compra. El depósito no los ve (decisión del dueño, #1245, mig 405).';

DROP POLICY IF EXISTS mt_nota_credito_items_select ON public.nota_credito_items;
CREATE POLICY mt_nota_credito_items_select ON public.nota_credito_items
  FOR SELECT TO authenticated
  USING (es_encargado_o_admin() AND sucursal_id = current_sucursal_id());
COMMENT ON POLICY mt_nota_credito_items_select ON public.nota_credito_items IS
  'Sólo admin y encargado: cada línea lleva el costo de la compra que devuelve. El depósito no lo ve (decisión del dueño, #1245, mig 405).';
