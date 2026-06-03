/**
 * TanStack Query hooks para Control de Stock (planilla → ajustes).
 *
 * - Sesiones: cabecera de cada carga de planilla (control_stock_sesiones).
 * - Detalle: filas de stock_historico con origen='control_stock' de una sesión.
 * - Aplicar: RPC aplicar_control_stock (solo admin; revalida es_admin() en DB).
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'

export interface AplicarControlStockResult {
  sesion_id: number
  total_items: number
  total_altas: number
  total_bajas: number
  aplicados: Array<{ producto_id: number; stock_anterior: number; stock_nuevo: number; diferencia: number }>
  no_encontrados: Array<{ producto_id: number }>
}

export interface ControlStockSesion {
  id: number
  fecha: string
  usuario_id: string | null
  total_items: number
  total_altas: number
  total_bajas: number
  observaciones: string | null
  usuario?: { nombre: string } | null
}

export interface ControlStockDetalle {
  id: number
  producto_id: number
  stock_anterior: number
  stock_nuevo: number
  diferencia: number | null
  created_at: string
}

const controlStockKeys = {
  all: (sucursalId: number | null) => ['control_stock', sucursalId] as const,
  sesiones: (sucursalId: number | null) => [...controlStockKeys.all(sucursalId), 'sesiones'] as const,
  detalle: (sucursalId: number | null, sesionId: number) => [...controlStockKeys.all(sucursalId), 'detalle', sesionId] as const,
}

async function fetchSesiones(): Promise<ControlStockSesion[]> {
  const { data, error } = await supabase
    .from('control_stock_sesiones')
    .select('id, fecha, usuario_id, total_items, total_altas, total_bajas, observaciones, usuario:perfiles(nombre)')
    .order('fecha', { ascending: false })
    .limit(100)
  if (error) throw error
  return (data as unknown as ControlStockSesion[]) || []
}

async function fetchDetalle(sesionId: number): Promise<ControlStockDetalle[]> {
  const { data, error } = await supabase
    .from('stock_historico')
    .select('id, producto_id, stock_anterior, stock_nuevo, diferencia, created_at')
    .eq('origen', 'control_stock')
    .eq('referencia_id', sesionId)
    .order('id', { ascending: true })
  if (error) throw error
  return (data as ControlStockDetalle[]) || []
}

export function useControlStockSesionesQuery(enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: controlStockKeys.sesiones(currentSucursalId),
    queryFn: fetchSesiones,
    enabled: enabled && !!currentSucursalId,
    staleTime: 60 * 1000,
  })
}

export function useControlStockDetalleQuery(sesionId: number | null) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: controlStockKeys.detalle(currentSucursalId, sesionId ?? -1),
    queryFn: () => fetchDetalle(sesionId as number),
    enabled: sesionId != null,
    staleTime: 60 * 1000,
  })
}

export function useAplicarControlStockMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async (ajustes: Array<{ producto_id: string; stock_real: number }>): Promise<AplicarControlStockResult> => {
      const { data, error } = await supabase.rpc('aplicar_control_stock', {
        p_ajustes: ajustes,
        p_observaciones: null,
      })
      if (error) throw error
      return data as AplicarControlStockResult
    },
    onSuccess: () => {
      // El stock cambió: refrescar productos y el histórico de sesiones.
      queryClient.invalidateQueries({ queryKey: productosKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: controlStockKeys.all(currentSucursalId) })
    },
  })
}
