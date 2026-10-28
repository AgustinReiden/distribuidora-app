/**
 * Vehículos (entrega 1 de gastos). Se leen por REST con RLS y se escriben sólo
 * por RPC `SECURITY DEFINER` que valida rol y sucursal: el admin da de alta y
 * de baja, el encargado sólo los lee para elegirlos en un gasto.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { Vehiculo } from '../../types/gastos'

export const vehiculosKeys = {
  all: (sucursalId: number | null) => ['vehiculos', sucursalId] as const,
  list: (sucursalId: number | null, incluirInactivos: boolean) =>
    [...vehiculosKeys.all(sucursalId), 'lista', incluirInactivos] as const,
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
