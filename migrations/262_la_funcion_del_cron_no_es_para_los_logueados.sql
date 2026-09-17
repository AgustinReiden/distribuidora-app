-- `bot_digest_destinatarios` no tiene por qué ser ejecutable por un usuario logueado.
--
-- La 261 la creó con `REVOKE ... FROM PUBLIC, anon` + `GRANT TO service_role`,
-- que es la receta que documenta CLAUDE.md. Pero esa receta está pensada para
-- las funciones que SÍ usa el frontend: cierra la mitad `anon` y deja la mitad
-- `authenticated` viva porque las RPCs normales la necesitan.
--
-- Ésta no la necesita: la llama únicamente la edge function del digest, con
-- service_role. El GRANT por default de Supabase a `authenticated` quedó en
-- pie, y devuelve `telegram_user_id`, `perfil_id` y `sucursal_id` de todos los
-- admins — o sea que cualquier preventista logueado podía enumerar las horas y
-- sacar la lista. `scripts/check-permisos.mjs` no lo ve: ese gate falla ante
-- funciones alcanzables con la **anon key**, y ésta no lo era.
--
-- Regla, entonces: una función que sólo corre desde el server se revoca a las
-- TRES (PUBLIC, anon y authenticated), no a las dos de la receta general.

REVOKE ALL ON FUNCTION public.bot_digest_destinatarios(SMALLINT, SMALLINT)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.bot_digest_destinatarios(SMALLINT, SMALLINT)
  TO service_role;
