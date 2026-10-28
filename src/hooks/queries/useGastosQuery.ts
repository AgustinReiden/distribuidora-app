/**
 * Gastos (entrega 1). Se leen por REST con RLS y se escriben sólo por las RPCs
 * `guardar_gasto` y `anular_gasto`, que validan rol, sucursal y desglose.
 *
 * El mes se lee con la ventana `mes_imputado <= mes <= mes_fin`: un gasto
 * repartido aparece en cada mes que toca (la cuota la calcula `cuotaDelMes`).
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { Gasto, GuardarGastoPayload } from '../../types/gastos'
import { vehiculosKeys } from './useVehiculosQuery'

/** Columnas de `Gasto` a mano: un `*` no distingue lo que la tabla sume mañana. */
export const GASTO_COLUMNAS = [
  'id', 'sucursal_id', 'compartido', 'fecha', 'rubro_id', 'monto_total', 'comprobante',
  'comprobante_numero', 'alicuota_iva', 'iva', 'percepcion_iva', 'percepcion_iibb',
  'otros_impuestos', 'neto', 'costo', 'vehiculo_id', 'litros', 'mes_imputado',
  'repartir_meses', 'mes_fin', 'origen_pago', 'observacion', 'creado_por', 'anulado_at',
  'created_at',
  'rubro:gasto_rubros(id,nombre,grupo)',
  'vehiculo:vehiculos(id,patente,descripcion)',
].join(',')

export const gastosKeys = {
  all: (sucursalId: number | null) => ['gastos', sucursalId] as const,
  delMes: (sucursalId: number | null, mes: string) => ['gastos', sucursalId, 'mes', mes] as const,
}

export function useGastosDelMesQuery(mes: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: gastosKeys.delMes(currentSucursalId, mes),
    queryFn: async (): Promise<Gasto[]> => {
      const { data, error } = await supabase
        .from('gastos')
        .select(GASTO_COLUMNAS)
        .lte('mes_imputado', mes)
        .gte('mes_fin', mes)
        .is('anulado_at', null)
        .order('fecha', { ascending: false })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar los gastos. Revisá la señal e intentá de nuevo.')
      return (data ?? []) as unknown as Gasto[]
    },
    enabled: currentSucursalId != null && Boolean(mes),
    staleTime: 60 * 1000,
  })
}

export function useGuardarGastoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async (payload: GuardarGastoPayload): Promise<number> => {
      const { data, error } = await supabase.rpc('guardar_gasto', { p_gasto: payload })
      // `guardar_gasto` no es idempotente: si la respuesta se perdió, reintentar
      // a ciegas puede duplicar el gasto.
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el gasto. Revisá la lista del mes antes de reintentar, puede haber quedado registrado.')
      return data as number
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gastosKeys.all(currentSucursalId) })
      // La carga de combustible escribe la lectura de km del vehículo.
      queryClient.invalidateQueries({ queryKey: vehiculosKeys.all(currentSucursalId) })
    },
  })
}

export function useAnularGastoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ id, motivo }: { id: number; motivo: string }): Promise<void> => {
      const { error } = await supabase.rpc('anular_gasto', { p_gasto_id: id, p_motivo: motivo })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la anulación. Revisá la lista del mes antes de reintentar.')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gastosKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: vehiculosKeys.all(currentSucursalId) })
    },
  })
}

/**
 * La lectura de km que dejó la carga de combustible de este gasto (`vehiculo_km`
 * con `gasto_id`), para precargar "km del tablero" al editarlo: `guardar_gasto`
 * borra la lectura si el campo no viaja. `null` si no hay. Siempre fresca: se
 * lee cada vez que se abre la edición.
 */
export function useKmDelGastoQuery(gastoId: number | null) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...gastosKeys.all(currentSucursalId), 'km', gastoId] as const,
    queryFn: async (): Promise<number | null> => {
      const { data, error } = await supabase
        .from('vehiculo_km')
        .select('km')
        .eq('gasto_id', gastoId as number)
        .maybeSingle()
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron leer los km del tablero. Revisá la señal e intentá de nuevo.')
      return (data as { km: number } | null)?.km ?? null
    },
    enabled: currentSucursalId != null && gastoId != null,
    staleTime: 0,
  })
}
