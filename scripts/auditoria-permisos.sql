-- ============================================================================
-- Auditoría de permisos EXECUTE del schema public — consulta de pre-vuelo
-- ============================================================================
-- Sólo LEE el catálogo. Pegar en el SQL editor del dashboard (o correr con
-- execute_sql) ANTES de aplicar la migración 188, para ver contra qué se está
-- comparando. Después de la 188, lo mismo lo devuelve el RPC
-- auditoria_permisos_execute() (mig 189) y lo chequea scripts/check-permisos.mjs.
--
-- Salvedad importante sobre la columna `menciona_guarda`: es un grep sobre el
-- cuerpo de la función, no un veredicto. Que una función mencione auth.uid() no
-- significa que se proteja con auth.uid() — puede usarlo sólo para estampar una
-- columna. Sirve para ordenar la cola de revisión. Lo que sí es duro es
-- `ejecuta_anon`, que sale del ACL.
-- ============================================================================

WITH f AS (
  SELECT
    p.oid,
    p.oid::regprocedure::text                                    AS firma,
    pg_get_userbyid(p.proowner)                                  AS owner,
    p.prosecdef                                                  AS security_definer,
    (t.typname = 'trigger')                                      AS es_trigger,
    COALESCE(array_to_string(p.proacl, ' | '), '(default: owner + PUBLIC)') AS acl,
    has_function_privilege('anon',          p.oid, 'EXECUTE')     AS ejecuta_anon,
    has_function_privilege('authenticated', p.oid, 'EXECUTE')     AS ejecuta_authenticated,
    (p.provolatile = 'v')                                         AS volatil,
    pg_get_functiondef(p.oid)                                     AS def
  FROM pg_proc p
  JOIN pg_type t ON t.oid = p.prorettype
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.prokind IN ('f', 'p')
    AND NOT EXISTS (                       -- funciones que trae una extensión: no son nuestras
      SELECT 1 FROM pg_depend d
      WHERE d.objid = p.oid
        AND d.classid = 'pg_proc'::regclass
        AND d.deptype = 'e'
    )
),
c AS (
  SELECT f.*,
    (def ~* 'auth\.uid\(\)|es_admin\(\)|es_encargado_o_admin\(\)|current_sucursal_id\(\)|es_preventista\(\)|es_transportista\(\)|_rol_en_sucursal\(')
      AS menciona_guarda,
    -- Grep + volatilidad: Postgres no deja escribir a una función STABLE, así
    -- que exigir VOLATILE descarta falsos positivos por comentarios o strings.
    (volatil AND def ~* '\m(insert|update|delete|truncate)\M') AS escribe
  FROM f
)

-- ---------------------------------------------------------------------------
-- (1) Resumen
-- ---------------------------------------------------------------------------
SELECT
  count(*)                                                                    AS total,
  count(*) FILTER (WHERE ejecuta_anon)                                        AS ejecuta_anon,
  count(*) FILTER (WHERE ejecuta_anon AND security_definer)                   AS anon_definer,
  count(*) FILTER (WHERE ejecuta_anon AND security_definer
                     AND NOT menciona_guarda)                                 AS anon_definer_sin_guarda,
  count(*) FILTER (WHERE ejecuta_anon AND security_definer
                     AND NOT menciona_guarda AND escribe)                     AS anon_definer_sin_guarda_escribe,
  -- Cómo llega el permiso: las dos mitades por separado.
  count(*) FILTER (WHERE ejecuta_anon AND acl LIKE '%anon=%')                 AS via_grant_explicito_a_anon,
  count(*) FILTER (WHERE ejecuta_anon AND (acl LIKE '=X/%' OR acl LIKE '%| =X/%'
                                            OR acl = '(default: owner + PUBLIC)')) AS via_public
FROM c;

-- ---------------------------------------------------------------------------
-- (2) Detalle ordenado por riesgo — arriba lo que escribe sin gate
-- ---------------------------------------------------------------------------
-- Descomentar para verlo (la CTE hay que repetirla; en el SQL editor conviene
-- correr un bloque por vez).
--
-- SELECT firma, owner, security_definer, es_trigger, menciona_guarda, escribe, acl
-- FROM c
-- WHERE ejecuta_anon
-- ORDER BY (security_definer AND NOT menciona_guarda AND escribe) DESC,
--          (security_definer AND NOT menciona_guarda)             DESC,
--          security_definer DESC,
--          firma;
