/**
 * Hooks de TanStack Query para "Visitas de cliente" (ping del preventista).
 *
 * - `useVisitasHoyQuery`: lista las visitas que el preventista logueado
 *   hizo hoy. Solo se llama cuando isPreventista, scope a la sucursal
 *   activa (vía la RPC `listar_visitas_hoy`).
 * - `useRegistrarVisitaMutation`: dispara el RPC `registrar_visita_cliente`
 *   con el GPS capturado y la clave del intento (Var-B1, T8 de la ola 3): el
 *   reintento de la misma visita (mismo cliente, la respuesta se perdió) manda la
 *   misma clave y el server devuelve la visita del primero en vez de crear otra.
 */
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { geolocalizacionKeys } from './useGeolocalizacionPreventistasQuery'
import type { GpsStatus } from './useGeolocalizacionPreventistasQuery'
import { rpcGpsConDiagnostico } from '../useRegistrarGeolocalizacionPedido'
import type { DiagnosticoGps } from '../../utils/ubicacionEquipo'
import { useRequestIdEstable } from '../useRequestIdEstable'

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
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar las visitas de hoy. Revisá la señal e intentá de nuevo.')
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
  /** El equipo, la app y el permiso al capturar (#1602). */
  diagnostico?: DiagnosticoGps | null
}

interface RegistrarVisitaResponse {
  success: boolean
  error?: string
  visita_id?: number
  /** La clave ya se había usado: es la visita del intento anterior (Var-B1). */
  replay?: boolean
}

async function registrarVisita(input: RegistrarVisitaInput, clave: string): Promise<RegistrarVisitaResponse> {
  const params: Record<string, unknown> = {
    p_cliente_id: input.clienteId,
    p_status: input.status,
    p_clave: clave,
  }
  if (input.status === 'ok') {
    params.p_lat = input.lat
    params.p_lng = input.lng
    params.p_accuracy = input.accuracy
    params.p_capturado_at = input.capturadoAt
  } else if (input.motivoOmision && input.motivoOmision.trim().length > 0) {
    params.p_motivo_omision = input.motivoOmision.trim()
  }
  if (input.diagnostico) params.p_diagnostico = input.diagnostico
  const { data, error } = await rpcGpsConDiagnostico('registrar_visita_cliente', params)
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la visita. Revisá las visitas de hoy antes de reintentar, puede haber quedado hecho.')
  return data as RegistrarVisitaResponse
}

export function useRegistrarVisitaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  // Var-B1 (T8 de la ola 3): una clave por visita a un cliente. El reintento (la respuesta se
  // perdió y se vuelve a tocar el cliente) lleva la misma aunque el GPS se haya vuelto a capturar:
  // es la misma visita. Después de una que salió bien, la próxima a ese cliente es otra visita.
  const claveVisita = useRequestIdEstable()
  return useMutation({
    mutationFn: async (input: RegistrarVisitaInput): Promise<RegistrarVisitaResponse> => {
      const huella = `${currentSucursalId ?? ''}|${input.clienteId}`
      const res = await registrarVisita(input, claveVisita(huella))
      if (res?.success) claveVisita.olvidar([huella])
      return res
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: visitasKeys.all(currentSucursalId) })
      // El panel admin también refleja visitas en su data combinada.
      queryClient.invalidateQueries({ queryKey: geolocalizacionKeys.all(currentSucursalId) })
    },
  })
}
