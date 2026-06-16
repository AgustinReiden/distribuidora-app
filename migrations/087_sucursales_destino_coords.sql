-- 087_sucursales_destino_coords.sql
-- Punto de LLEGADA opcional por sucursal para la optimización de rutas.
--
-- Hoy la ruta arranca y termina en el depósito (deposito_lat/lng, mig 082).
-- Algunos choferes guardan el camión lejos del depósito: este punto permite
-- optimizar arrancando cerca del depósito y TERMINANDO cerca del garaje.
-- Es opcional: si destino_lat/lng son NULL, la ruta termina en el depósito
-- (comportamiento actual).
--
-- Aditiva (sin DROP): espejo de get/set_deposito_sucursal (mig 082).

ALTER TABLE public.sucursales
  ADD COLUMN IF NOT EXISTS destino_lat numeric,
  ADD COLUMN IF NOT EXISTS destino_lng numeric;

-- Lectura: cualquier usuario autenticado de la sucursal (scoped por current_sucursal_id()).
CREATE OR REPLACE FUNCTION public.get_destino_sucursal()
RETURNS TABLE(lat numeric, lng numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT destino_lat, destino_lng
  FROM sucursales
  WHERE id = current_sucursal_id();
$$;

-- Escritura: encargado/admin. Acepta NULL en ambos para LIMPIAR el punto de
-- llegada (la ruta vuelve a terminar en el depósito).
CREATE OR REPLACE FUNCTION public.set_destino_sucursal(p_lat numeric, p_lng numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para configurar el punto de llegada' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;
  UPDATE sucursales SET destino_lat = p_lat, destino_lng = p_lng WHERE id = v_sucursal;
END;
$$;
