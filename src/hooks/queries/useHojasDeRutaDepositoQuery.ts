/**
 * Hojas de ruta armadas para depósito (#782), por la RPC sin plata
 * `hojas_de_ruta_deposito` (mig 305). Depósito no lee `pedidos` por REST: la
 * RLS no lo deja, y si lo dejara vendrían los montos con la fila.
 *
 * `fecha` null = que el servidor elija la próxima ruta armada (la de mañana si
 * ya está, si no la de hoy, en hora argentina). La respuesta trae la fecha que
 * eligió, y la pantalla sigue desde ahí.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { normalizarHojasDeRuta, type HojasDeRutaDeposito } from '../../utils/hojasDeRutaDeposito'

export const hojasDeRutaDepositoKeys = {
  all: (sucursalId: number | null) => ['hojas-de-ruta-deposito', sucursalId] as const,
  fecha: (sucursalId: number | null, fecha: string | null) =>
    ['hojas-de-ruta-deposito', sucursalId, fecha ?? 'proxima'] as const,
}

export async function fetchHojasDeRutaDeposito(fecha: string | null): Promise<HojasDeRutaDeposito> {
  const { data, error } = await supabase.rpc('hojas_de_ruta_deposito', { p_fecha: fecha })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar las hojas de ruta. Revisá la señal e intentá de nuevo.')
  return normalizarHojasDeRuta(data)
}

export function useHojasDeRutaDepositoQuery(fecha: string | null) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: hojasDeRutaDepositoKeys.fecha(currentSucursalId, fecha),
    queryFn: () => fetchHojasDeRutaDeposito(fecha),
    enabled: currentSucursalId != null,
    staleTime: 30 * 1000,
    // La ruta se arma desde otra cuenta (admin): depósito no recibe el evento,
    // así que se refresca sola mientras la pantalla está abierta.
    refetchInterval: 60 * 1000,
    refetchOnWindowFocus: true,
  })
}
