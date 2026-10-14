-- La ventana de precio anterior se edita desde /configuracion, y solo la
-- edita el admin (#1157)
--
-- La 363 agrego politicas_comerciales.ventana_precio_anterior_horas (default
-- 24, CHECK 0..168): durante esas horas despues de un cambio de lista,
-- precio_fuera_de_politica acepta todavia el precio inmediatamente anterior,
-- para que un pedido cargado sin senal antes del cambio no se rechace al
-- sincronizar. Quedo sin RPC ni campo: cambiarla pedia SQL a mano.
--
-- Decision del dueno (2026-10-14, #1157-A): SOLO admin, no el molde de las
-- otras cuatro politicas (admin o encargado). La ventana afloja el piso y el
-- techo de precio_fuera_de_politica, y los dos rigen para el encargado: si la
-- pudiera cambiar, podria ampliar su propia tolerancia hasta 168 h y vender
-- una semana al precio anterior a una suba. El encargado la ve (el SELECT de
-- politicas_comerciales es de tabla) pero no la cambia.
--
-- Molde: actualizar_monto_minimo_pedido (SELECT rol de perfiles, no es_admin(),
-- para no cambiar de estilo; trampa 4 no aplica porque se pide 'admin'
-- literal). Upsert por sucursal_id sellando actualizado_por y actualizado_en
-- del lado del server. La validacion vive en dos lados, como dias_critico: el
-- CHECK de la tabla y el RAISE de aca, que da un mensaje legible.
--
-- El parametro va en INTEGER, nunca SMALLINT (trampa 5: PostgREST manda un
-- numero de JSON). Funcion nueva: no hay sobrecarga vieja que dropear. Nace
-- con EXECUTE para PUBLIC y Supabase se lo da a anon por separado: se revocan
-- las dos mitades aca (CLAUDE.md) y la llama el front como authenticated.

CREATE OR REPLACE FUNCTION public.actualizar_ventana_precio_anterior(p_horas integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_rol      text;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- Solo admin (decision #1157): la ventana afloja el piso y el techo de
  -- precio_fuera_de_politica, que rigen para el encargado; si la pudiera
  -- cambiar, ampliaria su propia tolerancia.
  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  IF p_horas IS NULL OR p_horas < 0 OR p_horas > 168 THEN
    RAISE EXCEPTION 'La ventana de precio anterior va de 0 a 168 horas';
  END IF;

  INSERT INTO public.politicas_comerciales (sucursal_id, ventana_precio_anterior_horas, actualizado_por, actualizado_en)
  VALUES (v_sucursal, p_horas, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET ventana_precio_anterior_horas = EXCLUDED.ventana_precio_anterior_horas,
        actualizado_por               = EXCLUDED.actualizado_por,
        actualizado_en                = EXCLUDED.actualizado_en;

  RETURN p_horas;
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_ventana_precio_anterior(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_ventana_precio_anterior(integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- Verificacion: ni anon ni PUBLIC la alcanzan (check-permisos.mjs), y
-- authenticated si (la llama el front).
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f text := 'public.actualizar_ventana_precio_anterior(integer)';
BEGIN
  IF has_function_privilege('anon', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'anon puede ejecutar %', f;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
              WHERE p.oid = f::regprocedure AND a.grantee = 0) THEN
    RAISE EXCEPTION 'PUBLIC sigue con EXECUTE sobre %', f;
  END IF;
  IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated no puede ejecutar %', f;
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = f::regprocedure)
     OR (SELECT proconfig FROM pg_proc WHERE oid = f::regprocedure) IS DISTINCT FROM ARRAY['search_path=public'] THEN
    RAISE EXCEPTION '% no quedo SECURITY DEFINER con search_path=public', f;
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                                     AND proname = 'actualizar_ventana_precio_anterior') <> 1 THEN
    RAISE EXCEPTION 'actualizar_ventana_precio_anterior tiene mas de una sobrecarga';
  END IF;
END
$verif$;
