/**
 * Hooks de TanStack Query para "Visitas de cliente" (ping del preventista).
 *
 * - `useVisitasHoyQuery`: lista las visitas que el preventista logueado
 *   hizo hoy. Solo se llama cuando isPreventista, scope a la sucursal
 *   activa (vía la RPC `listar_visitas_hoy`).
 * - `useRegistrarVisitaMutation`: dispara el RPC `registrar_visita_cliente`
 *   con el GPS capturado. Cada llamada crea un registro nuevo (sin dedup).
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { geolocalizacionKeys } from './useGeolocalizacionPreventistasQuery'
import type { GpsStatus } from './useGeolocalizacionPreventistasQuery'

export interface VisitaHoy {
  visita_id: number
  cliente_id: number
  cliente_nombre: string | null
  cliente_direccion: string | null
  cliente_lat: number | null
  cliente_lng: number | null
  gps_lat: number | null
  gps_lng: number | null
  gps_status: GpsStatus | null
  gps_capturado_at: string | null
  created_at: string
  distancia_m: number | null
}

export const visitasKeys = {
  all: (sucursalId: number | null) => ['visitas', sucursalId] as const,
  hoy: (sucursalId: number | null, userId: string | null) =>
    ['visitas', sucursalId, 'hoy', userId] as const,
}

async function fetchVisitasHoy(): Promise<VisitaHoy[]> {
  const { data, error } = await supabase.rpc('listar_visitas_hoy')
  if (error) throw error
  return (data as VisitaHoy[]) ?? []
}

export function useVisitasHoyQuery(userId: string | null, options: { enabled?: boolean } = {}) {
  const { currentSucursalId } = useSucursal()
  const { enabled = true } = options
  return useQuery({
    queryKey: visitasKeys.hoy(currentSucursalId, userId),
    queryFn: fetchVisitasHoy,
    enabled: enabled && !!userId,
    staleTime: 15_000,
  })
}

export interface RegistrarVisitaInput {
  clienteId: number
  status: GpsStatus
  lat?: number | null
  lng?: number | null
  accuracy?: number | null
  capturadoAt?: string | null
  motivoOmision?: string | null
}

interface RegistrarVisitaResponse {
  success: boolean
  error?: string
  visita_id?: number
}

async function registrarVisita(input: RegistrarVisitaInput): Promise<RegistrarVisitaResponse> {
  const params: Record<string, unknown> = {
    p_cliente_id: input.clienteId,
    p_status: input.status,
  }
  if (input.status === 'ok') {
    params.p_lat = input.lat
    params.p_lng = input.lng
    params.p_accuracy = input.accuracy
    params.p_capturado_at = input.capturadoAt
  } else if (input.motivoOmision && input.motivoOmision.trim().length > 0) {
    params.p_motivo_omision = input.motivoOmision.trim()
  }
  const { data, error } = await supabase.rpc('registrar_visita_cliente', params)
  if (error) throw error
  return data as RegistrarVisitaResponse
}

export function useRegistrarVisitaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: registrarVisita,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: visitasKeys.all(currentSucursalId) })
      // El panel admin también refleja visitas en su data combinada.
      queryClient.invalidateQueries({ queryKey: geolocalizacionKeys.all(currentSucursalId) })
    },
  })
}
