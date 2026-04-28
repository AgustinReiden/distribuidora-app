-- Migración 020 — Bot Telegram: búsqueda de clientes accent-insensitive multi-word
--
-- El bot tiene la tool `buscar_cliente` que se invoca cuando el LLM responde a
-- preguntas tipo "Buscame el cliente Pepe". La implementación previa (PostgREST
-- chain con .or().ilike()) tenía dos limitaciones:
--
--   1. ILIKE es case-insensitive pero NO accent-insensitive — el cliente
--      "Almacén Gabriel" (id=565) no se encontraba al buscar "almacen gabriel".
--      Confirmado: `nombre_fantasia ILIKE '%almacen gabriel%'` → FALSE.
--   2. La búsqueda exigía que todas las palabras del query estuvieran en el
--      mismo campo como substring contigua, así que "almacen gabriel" no
--      matcheaba clientes con "Gabriel" en razon_social y "Almacén" en
--      nombre_fantasia separados.
--
-- Esta migración:
--   * Habilita la extensión `unaccent` en el schema.
--   * Crea la RPC `bot_buscar_cliente` que:
--     - Splittea el query en palabras (lowercased + unaccent).
--     - Exige que TODAS las palabras matcheen al menos uno de
--       nombre_fantasia / razon_social / codigo (lowercased + unaccent).
--     - Aplica scoping por sucursal y, para preventistas, por
--       cliente_preventistas (igual que la tool previa).
--   * Crea índices funcionales sobre las versiones unaccent+lower de los
--     campos de texto para que el LIKE no haga seq scan.
--
-- Patrón de seguridad igual a 015_bot_rpcs_phase2.sql: SECURITY DEFINER,
-- SET search_path = public, REVOKE FROM PUBLIC, GRANT EXECUTE solo a
-- service_role. La edge function ya valida el rol y el perfil antes de
-- llamar al RPC; este RPC no debe ejecutarse desde authenticated/anon.

-- ============================================================================
-- 1. Extensión unaccent + wrapper IMMUTABLE
-- ============================================================================
-- `unaccent()` es STABLE por default (depende del diccionario configurado),
-- así que Postgres rechaza usarla directamente en index expressions
-- (ERROR 42P17). El recipe estándar es envolverla en una función SQL
-- IMMUTABLE que pasa el diccionario explícito (`public.unaccent`).
-- Ver: https://www.postgresql.org/docs/current/unaccent.html

CREATE EXTENSION IF NOT EXISTS unaccent;

CREATE OR REPLACE FUNCTION public.f_unaccent(TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
STRICT
AS $func$ SELECT public.unaccent('public.unaccent', $1) $func$;

ALTER FUNCTION public.f_unaccent(TEXT) OWNER TO postgres;

-- ============================================================================
-- 2. RPC bot_buscar_cliente
-- ============================================================================

CREATE OR REPLACE FUNCTION public.bot_buscar_cliente(
  p_q TEXT,
  p_perfil_id UUID,
  p_rol TEXT,
  p_sucursal_id BIGINT,
  p_limit INTEGER DEFAULT 10
)
RETURNS TABLE(
  id BIGINT,
  codigo INTEGER,
  nombre_fantasia TEXT,
  razon_social TEXT,
  saldo_cuenta NUMERIC,
  direccion TEXT,
  zona TEXT,
  sucursal_id BIGINT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH terms AS (
    -- Lowercase + unaccent + trim, después split por espacios y descartar
    -- elementos vacíos (que aparecen si hay espacios consecutivos).
    SELECT array_remove(
      string_to_array(
        trim(lower(f_unaccent(coalesce(p_q, '')))),
        ' '
      ),
      ''
    ) AS words
  )
  SELECT
    c.id,
    c.codigo,
    c.nombre_fantasia,
    c.razon_social,
    c.saldo_cuenta,
    c.direccion,
    c.zona,
    c.sucursal_id
  FROM clientes c, terms t
  WHERE
    -- Multi-tenancy: scoping obligatorio por sucursal del bot user.
    c.sucursal_id = p_sucursal_id
    AND (
      -- admin ve todo el universo de la sucursal; preventista solo sus
      -- clientes asignados (mismo gate que la tool original).
      p_rol = 'admin'
      OR EXISTS(
        SELECT 1
        FROM cliente_preventistas cp
        WHERE cp.cliente_id = c.id
          AND cp.preventista_id = p_perfil_id
      )
    )
    AND (
      -- Query vacío → matchea todo (la tool ya tiene un guard de q.length<2,
      -- pero por defensa-en-profundidad replicamos acá).
      array_length(t.words, 1) IS NULL
      OR (
        -- Para cada palabra del query, exigimos que aparezca como substring
        -- en al menos uno de los campos relevantes (lowercased + unaccent).
        -- bool_and AND lo exige para TODAS las palabras.
        SELECT bool_and(
          lower(f_unaccent(coalesce(c.nombre_fantasia, ''))) LIKE '%' || w || '%'
          OR lower(f_unaccent(coalesce(c.razon_social, ''))) LIKE '%' || w || '%'
          OR lower(coalesce(c.codigo::TEXT, '')) LIKE '%' || w || '%'
        )
        FROM unnest(t.words) AS w
      )
    )
  ORDER BY c.nombre_fantasia
  LIMIT p_limit;
$$;

ALTER FUNCTION public.bot_buscar_cliente(TEXT, UUID, TEXT, BIGINT, INTEGER)
  OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.bot_buscar_cliente(TEXT, UUID, TEXT, BIGINT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_buscar_cliente(TEXT, UUID, TEXT, BIGINT, INTEGER) TO service_role;

-- ============================================================================
-- 3. Índices funcionales para que el LIKE sobre unaccent(lower(...)) no haga
--    seq scan en tablas grandes. Útil cuando clientes pase los miles.
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_clientes_unaccent_nombre_fantasia
  ON public.clientes (lower(f_unaccent(coalesce(nombre_fantasia, ''))));

CREATE INDEX IF NOT EXISTS idx_clientes_unaccent_razon_social
  ON public.clientes (lower(f_unaccent(coalesce(razon_social, ''))));
