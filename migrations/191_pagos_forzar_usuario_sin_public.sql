-- ============================================================================
-- 191 · Sacarle a PUBLIC el EXECUTE de pagos_forzar_usuario()
-- ============================================================================
-- Lo encontró `scripts/check-permisos.mjs` en la primera corrida real del gate
-- (2026-08-19): 212 funciones en `public`, 1 ejecutable por `anon`.
--
-- No es un descuido de quien escribió la 190: es el comportamiento por defecto
-- que la **188** vino a cerrar y que vuelve solo con cada función nueva.
-- Supabase le da EXECUTE a `anon` explícitamente Y deja el grant implícito a
-- PUBLIC, y a PUBLIC no se lo puede sacar del default privilege. Por eso la 188
-- dejó el gate de CI: la única defensa posible es detectarlo cada vez, no
-- prevenirlo de una.
--
-- El ACL vivo lo muestra: `=X/postgres` (PUBLIC) es lo que la deja abierta.
--
-- SOBRE LA GRAVEDAD, sin inflarla: `pagos_forzar_usuario()` es una función de
-- TRIGGER (`RETURNS trigger`), y PostgreSQL **no deja invocar directamente** una
-- función de trigger — muere con "trigger functions can only be called as
-- triggers". Así que el EXECUTE abierto no era explotable. Se cierra igual, por
-- dos razones: la regla del gate es "cero funciones alcanzables por anon" y una
-- regla con excepciones caso por caso deja de ser verificable; y el día que
-- alguien la convierta en una función normal, la puerta ya estaría abierta.
--
-- `REVOKE ... FROM PUBLIC, anon` con las DOS mitades, que es la lección de la
-- 188: sacarle a una sola no alcanza porque `anon` entra por las dos vías.
-- ============================================================================

BEGIN;

REVOKE EXECUTE ON FUNCTION public.pagos_forzar_usuario() FROM PUBLIC, anon;

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
--   GRANT EXECUTE ON FUNCTION public.pagos_forzar_usuario() TO PUBLIC;
--
-- No hay motivo para hacerlo: el trigger sigue disparando igual, porque un
-- trigger no pasa por el EXECUTE de quien escribe en la tabla.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación
--
--   SELECT has_function_privilege('anon','public.pagos_forzar_usuario()','EXECUTE');
--   -- false
--
--   -- Y el gate entero, que es lo que importa — expuestas_a_anon = 0:
--   SELECT auditoria_permisos_execute();
--
--   -- El trigger sigue vivo y forzando el usuario:
--   SELECT tgname, tgenabled FROM pg_trigger
--    WHERE tgrelid = 'public.pagos'::regclass AND NOT tgisinternal;
-- ----------------------------------------------------------------------------
