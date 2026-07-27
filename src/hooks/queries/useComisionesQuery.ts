/**
 * Comisiones variables (migs 148-150).
 *
 * Reemplaza el cálculo que hacía el front (`ventas × % tipeado a mano`) por el
 * RPC `calcular_comisiones`, que resuelve la regla vigente ítem por ítem y usa
 * la MISMA base que `reporte_gerencial.base_comision`. Eso es lo que cierra
 * COMIS-04: hasta ahora había dos fórmulas distintas que coincidían de
 * casualidad.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { OrigenPrecio } from '../../utils/origenPrecio'

// =============================================================================
// TYPES
// =============================================================================

/** Origen tal como lo agrupa el RPC: los ítems viejos caen en 'sin_dato'. */
export type OrigenComision = OrigenPrecio | 'desconocido' | 'sin_dato'

export interface ComisionPorOrigen {
  origen: OrigenComision
  base: number
  comision: number
  items: number
}

export interface ComisionPreventista {
  id: string
  nombre: string
  email: string | null
  base: number
  comision: number
  items: number
  /** Ítems anteriores a la mig 148: sin origen, caen en la regla genérica. */
  items_sin_desglose: number
  base_sin_desglose: number
  por_origen: ComisionPorOrigen[]
}

export interface ComisionesResultado {
  desde: string
  hasta: string
  comision_default: number
  preventistas: ComisionPreventista[]
  totales: {
    base: number
    comision: number
    items: number
    items_sin_desglose: number
    base_sin_desglose: number
  }
}

export interface ComisionRegla {
  id: number
  sucursal_id: number | null
  preventista_id: string | null
  origen_precio: OrigenPrecio | null
  producto_id: number | null
  categoria_id: string | null
  porcentaje: number
  activo: boolean
  vigente_desde: string
  vigente_hasta: string | null
  created_at: string
}

export interface GuardarComisionReglaInput {
  id?: number | null
  sucursalId?: number | null
  preventistaId?: string | null
  origenPrecio?: OrigenPrecio | null
  porcentaje: number
  vigenteDesde?: string | null
  vigenteHasta?: string | null
}

// =============================================================================
// QUERY KEYS
// =============================================================================

export const comisionesKeys = {
  all: (sucursalId: number | null) => ['comisiones', sucursalId] as const,
  calculo: (sucursalId: number | null, desde: string, hasta: string) =>
    [...comisionesKeys.all(sucursalId), 'calculo', desde, hasta] as const,
  reglas: (sucursalId: number | null) => [...comisionesKeys.all(sucursalId), 'reglas'] as const,
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Comisión calculada del período. `enabled` permite no dispararlo hasta que la
 * pantalla tenga rango: el RPC es admin-only y tira 42501 a cualquier otro rol.
 */
export function useCalcularComisionesQuery(desde: string, hasta: string, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: comisionesKeys.calculo(currentSucursalId, desde, hasta),
    queryFn: async (): Promise<ComisionesResultado> => {
      const { data, error } = await supabase.rpc('calcular_comisiones', {
        p_desde: desde,
        p_hasta: hasta,
        // Sin sucursales explícitas el RPC usa las asignadas al admin.
        p_sucursal_ids: currentSucursalId != null ? [currentSucursalId] : null,
      })
      if (error) throw error
      return data as ComisionesResultado
    },
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 5 * 60 * 1000,
  })
}

/** Reglas vigentes y dadas de baja (la baja es lógica: el pasado se respeta). */
export function useComisionReglasQuery(enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: comisionesKeys.reglas(currentSucursalId),
    queryFn: async (): Promise<ComisionRegla[]> => {
      const { data, error } = await supabase
        .from('comision_reglas')
        .select('*')
        .order('activo', { ascending: false })
        .order('vigente_desde', { ascending: false })
        .order('id', { ascending: false })
      if (error) throw error
      return (data as ComisionRegla[]) || []
    },
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

export function useGuardarComisionReglaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (input: GuardarComisionReglaInput): Promise<number> => {
      const { data, error } = await supabase.rpc('guardar_comision_regla', {
        p_id: input.id ?? null,
        p_sucursal_id: input.sucursalId ?? null,
        p_preventista_id: input.preventistaId ?? null,
        p_origen_precio: input.origenPrecio ?? null,
        p_porcentaje: input.porcentaje,
        p_vigente_desde: input.vigenteDesde ?? null,
        p_vigente_hasta: input.vigenteHasta ?? null,
      })
      if (error) throw error
      return data as number
    },
    onSuccess: () => {
      // El cálculo depende de las reglas: invalidar los dos.
      queryClient.invalidateQueries({ queryKey: comisionesKeys.all(currentSucursalId) })
    },
  })
}

export function useDesactivarComisionReglaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (id: number): Promise<void> => {
      const { error } = await supabase.rpc('desactivar_comision_regla', { p_id: id })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: comisionesKeys.all(currentSucursalId) })
    },
  })
}
