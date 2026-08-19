-- ============================================================================
-- Migración 189: auditoria_permisos_execute() — el gate que evita la recaída
-- ============================================================================
-- Proyecto: hmuchlzmuqqxcldbzkgc (ManaosApp).
--
-- La 188 cierra el agujero de hoy. Esta lo deja medido, para que no vuelva:
--
--   * Devuelve la clasificación por riesgo del schema public (qué ejecuta anon,
--     qué es SECURITY DEFINER, qué tiene gate propio, qué escribe).
--   * scripts/check-permisos.mjs la consume y falla si `expuestas_a_anon > 0`.
--     Queda colgada del workflow "Integridad de datos", junto a
--     auditoria_integridad() (mig 105) y al drift-check de migraciones.
--
-- Sobre la clasificación: "menciona auth.uid()" NO es lo mismo que "se protege
-- con auth.uid()". Una función puede usarlo sólo para estampar una columna. Por
-- eso `tiene_guarda` es una PISTA (grep sobre el cuerpo), no un veredicto: sirve
-- para ordenar la cola de revisión, no para dar algo por seguro. Lo que sí es
-- veredicto es `ejecuta_anon`, que sale del ACL.
--
-- Sigue el patrón correcto de permisos, que ahora está en migrations/README.md:
-- REVOKE de las DOS mitades (PUBLIC y anon) + GRANT explícito a quien la usa.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.auditoria_permisos_execute()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
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

  'detalle_authenticated_sin_guarda', COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
        'firma', firma, 'escribe', escribe
      ) ORDER BY escribe DESC, firma)
     FROM c
     WHERE ejecuta_authenticated AND security_definer AND NOT menciona_guarda AND NOT es_trigger),
    '[]'::jsonb)
);
$fn$;

ALTER FUNCTION public.auditoria_permisos_execute() OWNER TO postgres;

-- Las DOS mitades del REVOKE. Ver migrations/README.md § Permisos.
REVOKE EXECUTE ON FUNCTION public.auditoria_permisos_execute() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.auditoria_permisos_execute() TO authenticated, service_role;

COMMENT ON FUNCTION public.auditoria_permisos_execute() IS
  'Clasifica por riesgo los permisos EXECUTE del schema public. Lo consume '
  'scripts/check-permisos.mjs, que falla si expuestas_a_anon > 0. Ver mig 188/189.';


-- ----------------------------------------------------------------------------
-- Verificación: la función nueva no nació abierta a anon
-- ----------------------------------------------------------------------------
-- Si la 188 se aplicó, el ALTER DEFAULT PRIVILEGES ya lo garantiza y esto es
-- redundante. Si alguien aplica la 189 sin la 188, esto lo detecta.

DO $verif$
DECLARE
  v_anon BOOLEAN;
BEGIN
  SELECT has_function_privilege('anon', 'public.auditoria_permisos_execute()'::regprocedure, 'EXECUTE')
    INTO v_anon;

  IF v_anon THEN
    RAISE EXCEPTION '[189] auditoria_permisos_execute() quedó ejecutable por anon. ¿Se aplicó la 188?';
  END IF;
END
$verif$;
