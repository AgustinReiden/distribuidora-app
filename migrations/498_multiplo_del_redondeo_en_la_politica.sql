-- =========================================================================
-- NNN · EL MÚLTIPLO DEL REDONDEO DE LOS PRECIOS EN MASA ES DE LA POLÍTICA
--       COMERCIAL (reauditoría completa del 12/11, #1561: CAT-8; plan #1565,
--       tarjeta 10)
--
-- Suma una columna a `politicas_comerciales` y una RPC para editarla. No
-- cambia ninguna función existente. Premisa: ni la columna ni la RPC existen
-- (prod con la 494 y la 495). Poscondición: md5, ACL y definer de la RPC, y
-- todas las sucursales con el múltiplo de hoy.
-- Ensayo: scripts/test-multiplo-redondeo-1561.sql. Se aplica en LF.
--
-- El aumento masivo redondeaba a múltiplo de $10, fijo en el front
-- (src/utils/precios.ts): una constante de la distribuidora que un súper no
-- comparte. Decisión del dueño (13/11): pasa a `politicas_comerciales` ahora,
-- una fila por sucursal, como todo parámetro de negocio que cambia.
--   · `multiplo_redondeo_precio numeric(10,2)`, default 10 (lo de hoy), de
--     0,01 (al centavo) a 10.000. El techo deja afuera el NaN, y la precisión,
--     el infinito.
--   · `actualizar_multiplo_redondeo_precio(numeric)`: sólo admin, como la ventana
--     de precio anterior y los días de la fecha del pedido; el aumento masivo
--     también es sólo de admin. `actualizado_por` lo sella el servidor.
--   · authenticated lee la tabla entera (GRANT SELECT de tabla): la columna
--     nueva se ve sin conceder nada, y no la puede escribir por REST.
-- El front pide la columna en el select de la política: el PR se mergea con
-- esta migración ya aplicada, o la consulta entera falla.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: ni la columna ni la RPC existen
-- ---------------------------------------------------------------------------
DO $premisas$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_attribute
              WHERE attrelid = 'public.politicas_comerciales'::regclass
                AND attname = 'multiplo_redondeo_precio' AND NOT attisdropped)
     OR EXISTS (SELECT 1 FROM pg_proc
                 WHERE pronamespace = 'public'::regnamespace
                   AND proname = 'actualizar_multiplo_redondeo_precio') THEN
    RAISE EXCEPTION 'mig NNN · el múltiplo del redondeo ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- La columna
-- ---------------------------------------------------------------------------
ALTER TABLE public.politicas_comerciales
  ADD COLUMN multiplo_redondeo_precio numeric(10,2) NOT NULL DEFAULT 10,
  ADD CONSTRAINT politicas_multiplo_redondeo_precio_rango
    CHECK (multiplo_redondeo_precio >= 0.01 AND multiplo_redondeo_precio <= 10000);

COMMENT ON COLUMN public.politicas_comerciales.multiplo_redondeo_precio IS
  'Múltiplo al que el aumento masivo redondea los precios (de 0,01 a 10.000; default 10). Lo usa el front (redondearPrecio, src/utils/precios.ts) y lo cambia sólo el admin por actualizar_multiplo_redondeo_precio. CAT-8 de #1561.';

-- ---------------------------------------------------------------------------
-- La RPC
-- ---------------------------------------------------------------------------
CREATE FUNCTION public.actualizar_multiplo_redondeo_precio(p_multiplo numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;

  -- Sólo admin, como el aumento masivo que lo usa. es_admin() mira activo (#1474).
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: se requiere rol admin';
  END IF;

  -- El mismo rango que el CHECK, con un mensaje. Un NaN no pasa el techo.
  IF p_multiplo IS NULL OR NOT (p_multiplo >= 0.01 AND p_multiplo <= 10000)
     OR p_multiplo <> round(p_multiplo, 2) THEN
    RAISE EXCEPTION 'El múltiplo del redondeo va de 0,01 a 10.000, con hasta dos decimales';
  END IF;

  INSERT INTO public.politicas_comerciales (sucursal_id, multiplo_redondeo_precio, actualizado_por, actualizado_en)
  VALUES (v_sucursal, p_multiplo, auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET multiplo_redondeo_precio = EXCLUDED.multiplo_redondeo_precio,
        actualizado_por          = EXCLUDED.actualizado_por,
        actualizado_en           = EXCLUDED.actualizado_en;

  RETURN p_multiplo;
END;
$function$;

REVOKE ALL ON FUNCTION public.actualizar_multiplo_redondeo_precio(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_multiplo_redondeo_precio(numeric) TO authenticated;

COMMENT ON FUNCTION public.actualizar_multiplo_redondeo_precio(numeric) IS
  'Fija el múltiplo al que el aumento masivo redondea los precios en la sucursal activa (de 0,01 a 10.000). Sólo admin. CAT-8 de #1561.';

-- ---------------------------------------------------------------------------
-- Poscondición
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  x record;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
    FROM pg_proc WHERE oid = 'public.actualizar_multiplo_redondeo_precio(numeric)'::regprocedure;
  IF x.h IS DISTINCT FROM 'a621b07323ee3bb73db29b44333c2df4'
     OR x.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
     OR x.def IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'mig NNN · actualizar_multiplo_redondeo_precio no quedó como en el repo (md5 %, acl %, definer %)', x.h, x.a, x.def;
  END IF;
  IF EXISTS (SELECT 1 FROM public.politicas_comerciales WHERE multiplo_redondeo_precio IS DISTINCT FROM 10) THEN
    RAISE EXCEPTION 'mig NNN · alguna sucursal no quedó con el múltiplo de hoy (10)';
  END IF;
END
$post$;

COMMIT;
