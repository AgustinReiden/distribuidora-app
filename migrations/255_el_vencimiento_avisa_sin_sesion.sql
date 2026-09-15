-- =========================================================================
-- El vencimiento avisa sin sesión
--
-- EL PROBLEMA
-- ---------------------------------------------------------------------------
-- #565 pide un aviso por Telegram de los lotes que entran en el umbral crítico.
-- Los datos ya están: `reporte_vencimientos(p_dias_horizonte)` (224, con la
-- fecha argentina desde la 245) y `politicas_comerciales.dias_alerta_vencimiento`
-- / `dias_critico_vencimiento` por sucursal (204/223).
--
-- Pero el bot no puede llamar a `reporte_vencimientos`. No es un problema de
-- GRANT —en prod hoy ya tiene EXECUTE para `service_role`, aunque la 224 no lo
-- diga: el ACL vivo es `{postgres,authenticated,service_role}`—, es que la
-- función **depende de la sesión**. Su cuerpo arranca con
-- `current_sucursal_id()` y con `SELECT rol FROM perfiles WHERE id = auth.uid()`,
-- y con la service_role key `auth.uid()` es NULL: la primera línea que se
-- ejecuta es `RAISE 'No se pudo determinar la sucursal activa'`. Un GRANT más no
-- arregla una sesión que no existe.
--
-- POR QUÉ UNA FUNCIÓN NUEVA Y NO UN ARGUMENTO MÁS
-- ---------------------------------------------------------------------------
-- La salida obvia sería agregarle `p_sucursal_id` a `reporte_vencimientos`. No:
-- el front la llama sin ese argumento (`src/hooks/queries/useLotesQuery.ts`), y
-- dejar las dos firmas conviviendo es `PGRST203` en runtime —invisible para
-- `tsc`, para eslint y para los tests— por rangos de aridad superpuestos
-- (Trampa 5). Así que `reporte_vencimientos` **no se toca**, ni su cuerpo ni su
-- GRANT, y el bot estrena su propia puerta con la convención `bot_*` (018):
-- sucursal explícita por parámetro, sin `auth.uid()`, y sólo `service_role`.
--
-- El `RETURNS TABLE` es idéntico al de la original, columna por columna, para
-- que el front pueda reusar los tipos y para que las dos contesten lo mismo.
-- El `SELECT` es el mismo calco: el CTE `asignado`, el join
-- `producto_lotes`/`productos` por `(producto_id, sucursal_id)`, y los días
-- restantes contra `(now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date`
-- —nunca `CURRENT_DATE`, que es el día del servidor en UTC y entre las 21 y las
-- 00 hora argentina le descuenta un día de vida a cada lote (245, #639)—.
--
-- El control de acceso se corre de lugar, no se pierde: acá no hay rol que
-- chequear porque no hay caller humano. Quién recibe el aviso lo decide la edge
-- function, que resuelve el perfil con `bot_resolver_usuario` (237) y mira
-- `perfiles` en vivo. Esta función es service_role-only, igual que
-- `bot_metricas_admin_dia` (018).
--
-- LA IDEMPOTENCIA NECESITA SU PROPIA TABLA
-- ---------------------------------------------------------------------------
-- `bot_digests_enviados` no sirve para esto: su PK es `(admin_perfil_id, fecha)`
-- y asume un digest por admin por día. El aviso de vencimientos es por
-- **(perfil, sucursal, día)** —un encargado con dos sucursales asignadas recibe
-- dos avisos distintos el mismo día, y reusar esa PK haría que el segundo se
-- descarte como duplicado—. De ahí `bot_avisos_vencimiento_enviados`.
--
-- Las FKs van **simples, no compuestas**. La regla de la FK compuesta de
-- aislamiento (`(cliente_id, sucursal_id) → clientes(id, sucursal_id)`) no
-- aplica: `perfiles` no tiene columna `sucursal_id` —la asignación vive en
-- `usuario_sucursales`, y es N a N desde la 233—, así que no hay a dónde
-- apuntar. Y si la hubiera estaría mal: la fila legítima es "este perfil, esta
-- sucursal que tiene asignada", que es exactamente lo que una FK contra la
-- sucursal *default* del perfil rechazaría.
-- =========================================================================

BEGIN;

-- ============================================================================
-- 1. RPC bot_reporte_vencimientos
-- ============================================================================

CREATE OR REPLACE FUNCTION public.bot_reporte_vencimientos(
  p_sucursal_id     bigint,
  p_dias_horizonte  integer DEFAULT 3650
)
RETURNS TABLE(
  lote_id            bigint,
  producto_id        bigint,
  producto_nombre    text,
  producto_codigo    text,
  fecha_vencimiento  date,
  cantidad           integer,
  cantidad_restante  integer,
  dias_restantes     integer,
  origen             text,
  compra_id          bigint,
  stock_producto     integer,
  bolsa_producto     integer
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Sin sesión no hay `current_sucursal_id()` que valga: la sucursal es un
  -- parámetro y es obligatoria. NULL acá sería "todas las sucursales de una",
  -- que es justo lo que el aislamiento por sucursal no permite.
  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'p_sucursal_id es obligatorio';
  END IF;

  RETURN QUERY
  WITH asignado AS (
    SELECT pl.producto_id AS pid, SUM(pl.cantidad_restante)::integer AS total
      FROM public.producto_lotes pl
     WHERE pl.sucursal_id = p_sucursal_id
     GROUP BY pl.producto_id
  )
  SELECT l.id,
         l.producto_id,
         p.nombre::text,
         p.codigo::text,
         l.fecha_vencimiento,
         l.cantidad,
         l.cantidad_restante,
         -- mig 245 (#639) · misma fecha de aca que usan la 230, la 231 y la
         -- original. CURRENT_DATE seria el dia del servidor en UTC.
         (l.fecha_vencimiento - (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)::integer,
         l.origen,
         l.compra_id,
         p.stock,
         (p.stock - COALESCE(a.total, 0))::integer
    FROM public.producto_lotes l
    JOIN public.productos p
      ON p.id = l.producto_id AND p.sucursal_id = l.sucursal_id
    LEFT JOIN asignado a ON a.pid = l.producto_id
   WHERE l.sucursal_id = p_sucursal_id
     AND l.cantidad_restante > 0
     AND (l.fecha_vencimiento - (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) <= COALESCE(p_dias_horizonte, 3650)
   ORDER BY l.fecha_vencimiento ASC, p.nombre ASC;
END;
$function$;

ALTER FUNCTION public.bot_reporte_vencimientos(bigint, integer) OWNER TO postgres;

-- Las DOS mitades: Supabase le concede EXECUTE a `anon` por separado, además
-- del grant implícito a PUBLIC, y revocar una sola no cierra nada.
-- `authenticated` también se va: el que tiene sesión usa `reporte_vencimientos`,
-- que sí le chequea el rol.
REVOKE ALL    ON FUNCTION public.bot_reporte_vencimientos(bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_reporte_vencimientos(bigint, integer) TO service_role;

COMMENT ON FUNCTION public.bot_reporte_vencimientos(bigint, integer) IS
  'Lotes con stock vivo de p_sucursal_id que vencen dentro de p_dias_horizonte dias, para el aviso de vencimientos del bot Telegram (#565). Calco del SELECT de reporte_vencimientos(integer) con la sucursal explicita en vez de current_sucursal_id() y sin el chequeo de rol por auth.uid(): con la service_role key auth.uid() es NULL y la original aborta. Mismo RETURNS TABLE que la original, a proposito. dias_restantes se calcula contra la fecha argentina (mig 245), nunca CURRENT_DATE. Service_role-only: quien recibe el aviso lo decide la edge function.';

-- ============================================================================
-- 2. Tabla bot_avisos_vencimiento_enviados (idempotencia del aviso)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.bot_avisos_vencimiento_enviados (
  perfil_id    uuid        NOT NULL REFERENCES public.perfiles(id)   ON DELETE CASCADE,
  sucursal_id  bigint      NOT NULL REFERENCES public.sucursales(id) ON DELETE CASCADE,
  fecha        date        NOT NULL,
  enviado_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (perfil_id, sucursal_id, fecha)
);

CREATE INDEX IF NOT EXISTS idx_bot_avisos_vencimiento_fecha
  ON public.bot_avisos_vencimiento_enviados (fecha DESC);

-- RLS habilitada y sin policies: es la forma de decir "sólo service_role", que
-- pasa de largo la RLS. Igual que el resto de las bot_* (018). Con RLS on y
-- cero policies, anon y authenticated no ven una fila aunque el baseline les
-- haya hecho GRANT — y el gate `check-tablas-anon.mjs` lo verifica haciendo el
-- SELECT con el sombrero de anon, no leyendo el catálogo.
ALTER TABLE public.bot_avisos_vencimiento_enviados ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.bot_avisos_vencimiento_enviados IS
  'Idempotencia + auditoria del aviso de vencimientos criticos del bot (#565). PRIMARY KEY (perfil_id, sucursal_id, fecha): dos disparos el mismo dia no mandan dos mensajes, pero un perfil con dos sucursales asignadas si recibe un aviso por cada una — por eso no reusa bot_digests_enviados, cuya PK (admin_perfil_id, fecha) descartaria el segundo. Sin policies a proposito: solo service_role.';

-- ============================================================================
-- 3. Verificación del ACL (el gate de la 188/189, en la misma migración)
-- ============================================================================

DO $verificar$
DECLARE
  v_acl text;
BEGIN
  IF has_function_privilege('anon', 'public.bot_reporte_vencimientos(bigint, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'bot_reporte_vencimientos quedó ejecutable por anon';
  END IF;

  IF has_function_privilege('authenticated', 'public.bot_reporte_vencimientos(bigint, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'bot_reporte_vencimientos quedó ejecutable por authenticated';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.bot_reporte_vencimientos(bigint, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'bot_reporte_vencimientos NO es ejecutable por service_role';
  END IF;

  SELECT proacl::text INTO v_acl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'bot_reporte_vencimientos';

  IF v_acl IS NULL THEN
    RAISE EXCEPTION 'bot_reporte_vencimientos quedó con proacl NULL (= default: EXECUTE para PUBLIC)';
  END IF;

  IF NOT (SELECT relrowsecurity
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public'
             AND c.relname = 'bot_avisos_vencimiento_enviados') THEN
    RAISE EXCEPTION 'bot_avisos_vencimiento_enviados quedó sin RLS';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname = 'public'
                AND tablename = 'bot_avisos_vencimiento_enviados') THEN
    RAISE EXCEPTION 'bot_avisos_vencimiento_enviados tiene policies y no debería';
  END IF;

  RAISE NOTICE 'OK · bot_reporte_vencimientos acl=% · tabla con RLS y sin policies', v_acl;
END
$verificar$;

COMMIT;
