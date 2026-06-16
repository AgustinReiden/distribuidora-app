/**
 * Depósito de la sucursal (origen/cierre de las rutas de entrega).
 *
 * Reemplaza el viejo getDepositoCoords() basado en localStorage (por
 * dispositivo), que causaba que el admin y el transportista vieran depósitos
 * distintos. Ahora vive en sucursales.deposito_lat/lng (mig 082), así el
 * lado que optimiza y el que dibuja el mapa usan la MISMA fuente.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export interface DepositoCoords {
  lat: number
  lng: number
}

// Centro de San Miguel de Tucumán. Fallback cuando la sucursal aún no tiene
// depósito configurado (mismo valor histórico del default de localStorage).
export const DEPOSITO_DEFAULT: DepositoCoords = { lat: -26.8241, lng: -65.2226 }

export const depositoKeys = {
  all: (sucursalId: number | null) => ['deposito', sucursalId] as const,
}

async function fetchDeposito(): Promise<DepositoCoords> {
  const { data, error } = await supabase.rpc('get_deposito_sucursal')
  if (error) throw error
  const row = Array.isArray(data) ? data[0] : data
  if (row?.lat != null && row?.lng != null) {
    return { lat: Number(row.lat), lng: Number(row.lng) }
  }
  return DEPOSITO_DEFAULT
}

/**
 * Coordenadas del depósito de la sucursal actual. SIEMPRE devuelve un objeto
 * usable: el default mientras la query resuelve (placeholderData) y luego el
 * valor real. Pensado para reemplazar el viejo getDepositoCoords() síncrono.
 */
export function useDepositoCoords(): DepositoCoords {
  const { currentSucursalId } = useSucursal()
  const { data } = useQuery({
    queryKey: depositoKeys.all(currentSucursalId),
    queryFn: fetchDeposito,
    enabled: currentSucursalId != null,
    staleTime: 30 * 60 * 1000, // el depósito casi nunca cambia
    placeholderData: DEPOSITO_DEFAULT,
  })
  return data ?? DEPOSITO_DEFAULT
}

export function useSetDepositoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ lat, lng }: DepositoCoords) => {
      const { error } = await supabase.rpc('set_deposito_sucursal', { p_lat: lat, p_lng: lng })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: depositoKeys.all(currentSucursalId) })
    },
  })
}

// --- Punto de llegada (opcional, mig 087) ---
// Si la sucursal lo configura, la optimización TERMINA acá (p. ej. donde se
// guarda el camión) en vez de volver al depósito. null = sin punto de llegada.

export const destinoKeys = {
  all: (sucursalId: number | null) => ['destino-ruta', sucursalId] as const,
}

async function fetchDestino(): Promise<DepositoCoords | null> {
  const { data, error } = await supabase.rpc('get_destino_sucursal')
  if (error) throw error
  const row = Array.isArray(data) ? data[0] : data
  if (row?.lat != null && row?.lng != null) {
    return { lat: Number(row.lat), lng: Number(row.lng) }
  }
  return null
}

/** Punto de llegada de la sucursal actual, o null si no está configurado. */
export function useDestinoCoords(): DepositoCoords | null {
  const { currentSucursalId } = useSucursal()
  const { data } = useQuery({
    queryKey: destinoKeys.all(currentSucursalId),
    queryFn: fetchDestino,
    enabled: currentSucursalId != null,
    staleTime: 30 * 60 * 1000,
  })
  return data ?? null
}

export function useSetDestinoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    // null limpia el punto de llegada (la ruta vuelve a terminar en el depósito).
    mutationFn: async (coords: DepositoCoords | null) => {
      const { error } = await supabase.rpc('set_destino_sucursal', {
        p_lat: coords?.lat ?? null,
        p_lng: coords?.lng ?? null,
      })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: destinoKeys.all(currentSucursalId) })
    },
  })
}
