-- Los topes de las alertas de combos (#1194)
--
-- El combo tiene precio fijo (#1190) y con inflacion queda viejo: si suben los
-- costos el margen se achica, y si suben las listas crece el descuento. El
-- panel de combos y el reporte gerencial avisan con dos topes por sucursal:
--
--   combo_margen_minimo_pct     margen del combo (sobre la venta sin IVA) por
--                               debajo del cual se avisa. Default 10.
--   combo_descuento_maximo_pct  descuento real (1 - precio fijo / suma de
--                               precios sin combo) por encima del cual se
--                               avisa. Default 30.
--
-- Son parametros de negocio: viven en politicas_comerciales, no en una
-- constante (CLAUDE.md). La alerta avisa, no bloquea: ninguna RPC de venta los
-- lee. Las cuentas son del front (src/utils/comboAlertas.ts).
--
-- Los edita SOLO el admin, por RPC, con el molde de
-- actualizar_ventana_precio_anterior (368): SELECT rol de perfiles con
-- 'admin' literal (trampa 4 no aplica), upsert por sucursal sellando
-- actualizado_por y actualizado_en del lado del server, validacion en el
-- CHECK y en el RAISE. Los dos topes viajan juntos: son una sola decision.
--
-- Columnas nuevas: el SELECT de politicas_comerciales para authenticated es de
-- tabla, asi que se ven sin GRANT por columna; no hay escritura REST (la tabla
-- se escribe solo por RPC). Parametros en NUMERIC (un numero de JSON resuelve
-- a numeric sin downcast; trampa 5 es contra SMALLINT). Funcion nueva: se
-- revocan las dos mitades (PUBLIC, anon) y la llama el front como
-- authenticated.

ALTER TABLE public.politicas_comerciales
  ADD COLUMN IF NOT EXISTS combo_margen_minimo_pct numeric NOT NULL DEFAULT 10,
  ADD COLUMN IF NOT EXISTS combo_descuento_maximo_pct numeric NOT NULL DEFAULT 30;

ALTER TABLE public.politicas_comerciales
  DROP CONSTRAINT IF EXISTS politicas_combo_margen_minimo_rango,
  ADD CONSTRAINT politicas_combo_margen_minimo_rango
    CHECK (combo_margen_minimo_pct >= 0 AND combo_margen_minimo_pct <= 100),
  DROP CONSTRAINT IF EXISTS politicas_combo_descuento_maximo_rango,
  ADD CONSTRAINT politicas_combo_descuento_maximo_rango
    CHECK (combo_descuento_maximo_pct >= 0 AND combo_descuento_maximo_pct <= 100);

COMMENT ON COLUMN public.politicas_comerciales.combo_margen_minimo_pct IS
  'Alerta de combos (#1194): margen minimo del combo, en % sobre la venta sin IVA. Avisa, no bloquea.';
COMMENT ON COLUMN public.politicas_comerciales.combo_descuento_maximo_pct IS
  'Alerta de combos (#1194): descuento maximo contra la suma de precios sin combo, en %. Avisa, no bloquea.';

CREATE OR REPLACE FUNCTION public.actualizar_alertas_combos(
  p_margen_minimo_pct numeric,
  p_descuento_maximo_pct numeric
)
RETURNS void
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

  SELECT rol INTO v_rol FROM public.perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  IF p_margen_minimo_pct IS NULL OR p_margen_minimo_pct < 0 OR p_margen_minimo_pct > 100 THEN
    RAISE EXCEPTION 'El margen minimo del combo va de 0 a 100%%';
  END IF;
  IF p_descuento_maximo_pct IS NULL OR p_descuento_maximo_pct < 0 OR p_descuento_maximo_pct > 100 THEN
    RAISE EXCEPTION 'El descuento maximo del combo va de 0 a 100%%';
  END IF;

  INSERT INTO public.politicas_comerciales
    (sucursal_id, combo_margen_minimo_pct, combo_descuento_maximo_pct, actualizado_por, actualizado_en)
  VALUES (v_sucursal, p_margen_minimo_pct, p_descuento_maximo_pct, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET combo_margen_minimo_pct    = EXCLUDED.combo_margen_minimo_pct,
        combo_descuento_maximo_pct = EXCLUDED.combo_descuento_maximo_pct,
        actualizado_por            = EXCLUDED.actualizado_por,
        actualizado_en             = EXCLUDED.actualizado_en;
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_alertas_combos(numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_alertas_combos(numeric, numeric) TO authenticated;

-- ---------------------------------------------------------------------------
-- Verificacion: ni anon ni PUBLIC la alcanzan (check-permisos.mjs),
-- authenticated si, y authenticated lee las columnas nuevas.
-- ---------------------------------------------------------------------------
DO $verif$
DECLARE
  f text := 'public.actualizar_alertas_combos(numeric, numeric)';
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
                                     AND proname = 'actualizar_alertas_combos') <> 1 THEN
    RAISE EXCEPTION 'actualizar_alertas_combos tiene mas de una sobrecarga';
  END IF;
  IF NOT has_column_privilege('authenticated', 'public.politicas_comerciales', 'combo_margen_minimo_pct', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.politicas_comerciales', 'combo_descuento_maximo_pct', 'SELECT') THEN
    RAISE EXCEPTION 'authenticated no lee los topes de combos';
  END IF;
  IF has_column_privilege('anon', 'public.politicas_comerciales', 'combo_margen_minimo_pct', 'SELECT') THEN
    RAISE EXCEPTION 'anon lee los topes de combos';
  END IF;
END
$verif$;
