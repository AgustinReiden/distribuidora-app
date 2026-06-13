-- Migración 082: ubicación del depósito por sucursal
--
-- Hasta ahora el depósito de optimización de rutas vivía en localStorage
-- (por dispositivo): el admin lo configuraba en su PC y el celular del
-- transportista, con localStorage vacío, caía al default → el mapa mostraba
-- la "D" en otro lado que el usado al optimizar. Esto lo persiste por sucursal.
--
-- Aplicada en prod el 2026-06-13 vía MCP (apply_migration:
-- sucursales_deposito_coords) y verificada en vivo con rollback: admin lee y
-- escribe, transportista lee pero no escribe (42501).

ALTER TABLE public.sucursales
  ADD COLUMN IF NOT EXISTS deposito_lat numeric,
  ADD COLUMN IF NOT EXISTS deposito_lng numeric;

-- Seed solo Tucumán (id=1): el default -26.8241,-65.2226 es San Miguel de
-- Tucumán, geográficamente válido solo para esa sucursal. Las otras quedan
-- NULL → el front cae al default hasta que el admin las configure.
UPDATE public.sucursales
SET deposito_lat = -26.8241, deposito_lng = -65.2226
WHERE id = 1 AND deposito_lat IS NULL;

-- Lectura: cualquier usuario autenticado de la sucursal (el transportista la
-- necesita para dibujar el mapa).
CREATE OR REPLACE FUNCTION public.get_deposito_sucursal()
RETURNS TABLE(lat numeric, lng numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT deposito_lat, deposito_lng
  FROM sucursales
  WHERE id = current_sucursal_id();
$$;

-- Escritura: solo encargado/admin, sobre la sucursal actual.
CREATE OR REPLACE FUNCTION public.set_deposito_sucursal(p_lat numeric, p_lng numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para configurar el depósito' USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;
  UPDATE sucursales SET deposito_lat = p_lat, deposito_lng = p_lng WHERE id = v_sucursal;
END;
$$;

REVOKE ALL ON FUNCTION public.get_deposito_sucursal() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deposito_sucursal() TO authenticated;
REVOKE ALL ON FUNCTION public.set_deposito_sucursal(numeric, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_deposito_sucursal(numeric, numeric) TO authenticated;
