-- Migration 068: pin search_path on 3 trigger helper functions.
--
-- Security advisor flagged these as "function_search_path_mutable" — a
-- search_path injection surface. All three are trivial NEW.updated_at
-- assignments or promo-activo toggles, so the fix is a metadata-only
-- ALTER FUNCTION ... SET search_path. Body is untouched.

ALTER FUNCTION public.update_promociones_updated_at() SET search_path = 'public';
ALTER FUNCTION public.check_promo_limite_usos()      SET search_path = 'public';
ALTER FUNCTION public.update_proveedores_updated_at() SET search_path = 'public';
