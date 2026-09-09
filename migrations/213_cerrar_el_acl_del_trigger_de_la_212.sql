-- Cerrar el ACL de completar_unidades_por_bloque_item() (mig 212)
--
-- La 212 le puso el REVOKE a `factor_bonificacion` pero NO a la funcion del
-- trigger, con el razonamiento de que la regla de la casa habla de funciones
-- SECURITY DEFINER y esta es invoker. Es un razonamiento equivocado:
-- `scripts/check-permisos.mjs` falla ante CUALQUIER funcion de `public`
-- alcanzable con la anon key, sea DEFINER o INVOKER. El gate la marco:
--
--   Ejecutables por anon:
--     completar_unidades_por_bloque_item()  (invoker, SIN GUARDA, solo lee)
--     acl: =X/postgres | postgres=X/postgres | authenticated=X/postgres | service_role=X/postgres
--
-- Ese `=X/postgres` sin grantee es el grant implicito a PUBLIC con el que nace
-- toda funcion nueva, mas el que Supabase le da a `authenticated` aparte.
--
-- Una funcion de trigger no necesita EXECUTE para NADIE: la invoca el executor
-- como parte del INSERT, no el caller. La prueba esta al lado, en produccion:
-- `completar_origen_precio_item()` (mig 148), `validar_precio_item_pedido()` y
-- `aplicar_sustituciones_regalo_pre_insert()` corren en cada alta de pedido con
-- el ACL reducido a `postgres` + `service_role`. Esta queda igual que esas tres.
--
-- Revertir: no. Devolverle el EXECUTE a PUBLIC deja el gate en rojo y no
-- habilita nada que hoy no funcione.
-- =========================================================================

BEGIN;

REVOKE ALL ON FUNCTION public.completar_unidades_por_bloque_item()
  FROM PUBLIC, anon, authenticated;

DO $verif$
DECLARE
  v_abiertas text;
  v_trigger  int;
BEGIN
  -- Ni PUBLIC (entrada sin grantee, arranca con '=') ni anon.
  SELECT array_to_string(array_agg(a::text), ' ') INTO v_abiertas
  FROM pg_proc p, unnest(p.proacl) a
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'completar_unidades_por_bloque_item'
    AND (a::text LIKE '=%' OR a::text LIKE 'anon=%');
  IF v_abiertas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 213: el ACL sigue abierto (%).', v_abiertas;
  END IF;

  -- Y el trigger sigue en pie: revocar el EXECUTE no lo da de baja.
  SELECT count(*) INTO v_trigger
  FROM pg_trigger
  WHERE tgrelid = 'public.pedido_items'::regclass
    AND tgname = 'trg_completar_unidades_por_bloque_item';
  IF v_trigger <> 1 THEN
    RAISE EXCEPTION 'mig 213: el trigger de la 212 no esta instalado.';
  END IF;
END
$verif$;

COMMIT;
