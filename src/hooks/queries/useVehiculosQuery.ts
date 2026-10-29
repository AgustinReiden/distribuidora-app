/**
 * Vehículos (entrega 1 de gastos). Se leen por REST con RLS y se escriben sólo
 * por RPC `SECURITY DEFINER` que valida rol y sucursal: el admin da de alta y
 * de baja, el encargado sólo los lee para elegirlos en un gasto.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { mesDe, sumarMeses } from '../../utils/gastos'
import type { LecturaKm } from '../../utils/vehiculos'
import type { Gasto, Vehiculo } from '../../types/gastos'
import { GASTO_COLUMNAS } from './gastoColumnas'

export const vehiculosKeys = {
  all: (sucursalId: number | null) => ['vehiculos', sucursalId] as const,
  list: (sucursalId: number | null, incluirInactivos: boolean) =>
    [...vehiculosKeys.all(sucursalId), 'lista', incluirInactivos] as const,
  ficha: (sucursalId: number | null, vehiculoId: number) =>
    [...vehiculosKeys.all(sucursalId), 'ficha', vehiculoId] as const,
}

const VEHICULO_COLUMNAS = 'id,sucursal_id,patente,descripcion,activo'

export interface GuardarVehiculoInput {
  id?: number
  patente: string
  descripcion: string
  activo?: boolean
}

export function useVehiculosQuery({ incluirInactivos = false }: { incluirInactivos?: boolean } = {}) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: vehiculosKeys.list(currentSucursalId, incluirInactivos),
    queryFn: async (): Promise<Vehiculo[]> => {
      let consulta = supabase.from('vehiculos').select(VEHICULO_COLUMNAS)
      if (!incluirInactivos) consulta = consulta.eq('activo', true)
      const { data, error } = await consulta.order('patente')
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar los vehículos. Revisá la señal e intentá de nuevo.')
      return (data ?? []) as Vehiculo[]
    },
    enabled: currentSucursalId != null,
    staleTime: 5 * 60 * 1000,
  })
}

export function useGuardarVehiculoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async (vehiculo: GuardarVehiculoInput): Promise<number> => {
      const { data, error } = await supabase.rpc('guardar_vehiculo', { p_vehiculo: vehiculo })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el vehículo. Revisá la lista antes de reintentar, puede haber quedado guardado.')
      return data as number
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: vehiculosKeys.all(currentSucursalId) })
    },
  })
}

export function useRegistrarKmMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ vehiculoId, fecha, km }: { vehiculoId: number; fecha: string; km: number }): Promise<number> => {
      const { data, error } = await supabase.rpc('registrar_km_vehiculo', {
        p_vehiculo_id: vehiculoId,
        p_fecha: fecha,
        p_km: km,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la lectura de km. Revisá la ficha antes de reintentar, puede haber quedado registrada.')
      return data as number
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: vehiculosKeys.all(currentSucursalId) })
    },
  })
}

export interface FichaVehiculoDatos {
  /** Gastos del vehículo que tocan los últimos 12 meses, sin anulados. */
  gastos: Gasto[]
  lecturas: LecturaKm[]
}

/** El mes de hoy en Tucumán, no en UTC. */
const mesActualTucuman = (): string =>
  mesDe(new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' }))

/**
 * Lo que necesita la ficha de un vehículo: sus gastos de los últimos 12 meses
 * (un gasto repartido que empezó antes entra por su `mes_fin`) y sus lecturas
 * de km. Las lecturas las lee sólo el admin (RLS de `vehiculo_km`).
 */
export function useVehiculoFichaQuery(vehiculoId: number) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: vehiculosKeys.ficha(currentSucursalId, vehiculoId),
    queryFn: async (): Promise<FichaVehiculoDatos> => {
      const desde = sumarMeses(mesActualTucuman(), -11)
      const [gastos, lecturas] = await Promise.all([
        supabase
          .from('gastos')
          .select(GASTO_COLUMNAS)
          .eq('vehiculo_id', vehiculoId)
          .is('anulado_at', null)
          .gte('mes_fin', desde)
          .order('fecha', { ascending: false }),
        supabase
          .from('vehiculo_km')
          .select('fecha,km,origen,gasto_id')
          .eq('vehiculo_id', vehiculoId)
          .gte('fecha', desde)
          .order('fecha', { ascending: false }),
      ])
      if (gastos.error) throw errorDeSupabase(gastos.error, 'Sin conexión: no se pudo cargar la ficha del vehículo. Revisá la señal e intentá de nuevo.')
      if (lecturas.error) throw errorDeSupabase(lecturas.error, 'Sin conexión: no se pudo cargar la ficha del vehículo. Revisá la señal e intentá de nuevo.')
      return {
        gastos: (gastos.data ?? []) as unknown as Gasto[],
        lecturas: (lecturas.data ?? []) as LecturaKm[],
      }
    },
    enabled: currentSucursalId != null && vehiculoId > 0,
    staleTime: 60 * 1000,
  })
}
