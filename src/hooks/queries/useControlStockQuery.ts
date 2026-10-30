/**
 * TanStack Query hooks para Control de Stock (planilla → ajustes).
 *
 * - Sesiones: cabecera de cada carga de planilla (control_stock_sesiones).
 * - Detalle: filas de stock_historico con origen='control_stock' de una sesión.
 * - Aplicar: RPC aplicar_control_stock (solo admin; revalida es_admin() en DB).
 * - Carga previa: la sesión que ya aplicó una planilla, si la hay (#1295).
 */
import { useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'
import { errorDeSupabase } from '../../utils/errorDeSupabase'

/**
 * Un renglón contado de la planilla. La RPC aplica `stock_real − stock_planilla`
 * sobre el stock de ahora (#1254): sin `stock_planilla` la rechaza.
 */
export interface AjusteControlStock {
  producto_id: string
  stock_real: number
  stock_planilla: number
}

/**
 * Una planilla cargada. `planillaId` es el "ID de planilla" de la descarga: la
 * RPC no aplica dos veces el mismo (#1295) y sin él no aplica nada.
 */
export interface AplicarControlStockInput {
  planillaId: string
  ajustes: AjusteControlStock[]
}

/** La sesión que ya aplicó una planilla. */
export interface CargaPreviaPlanilla {
  id: number
  fecha: string
  total_items: number
}

export interface AplicarControlStockResult {
  sesion_id: number
  total_items: number
  total_altas: number
  total_bajas: number
  /** Ajustes aplicados sobre un stock que se movió desde la descarga. */
  movidos_desde_descarga: number
  aplicados: Array<{
    producto_id: number
    stock_planilla: number
    stock_contado: number
    stock_anterior: number
    stock_nuevo: number
    diferencia: number
    movido_desde_descarga: boolean
  }>
  no_encontrados: Array<{ producto_id: number }>
  /** Conteos que no se aplicaron: con lo vendido después, el stock quedaría negativo. */
  rechazados: Array<{
    producto_id: number
    stock_planilla: number
    stock_contado: number
    stock_actual: number
    motivo: 'quedaria_negativo'
  }>
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
  planilla: (sucursalId: number | null, planillaId: string) => [...controlStockKeys.all(sucursalId), 'planilla', planillaId] as const,
}

async function fetchSesiones(): Promise<ControlStockSesion[]> {
  const { data, error } = await supabase
    .from('control_stock_sesiones')
    .select('id, fecha, usuario_id, total_items, total_altas, total_bajas, observaciones, usuario:perfiles(nombre)')
    .order('fecha', { ascending: false })
    .limit(100)
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar las sesiones de control de stock. Revisá la señal e intentá de nuevo.')
  return (data as unknown as ControlStockSesion[]) || []
}

async function fetchDetalle(sesionId: number): Promise<ControlStockDetalle[]> {
  const { data, error } = await supabase
    .from('stock_historico')
    .select('id, producto_id, stock_anterior, stock_nuevo, diferencia, created_at')
    .eq('origen', 'control_stock')
    .eq('referencia_id', sesionId)
    .order('id', { ascending: true })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el detalle de la sesión. Revisá la señal e intentá de nuevo.')
  return (data as ControlStockDetalle[]) || []
}

async function fetchCargaPrevia(planillaId: string): Promise<CargaPreviaPlanilla | null> {
  const { data, error } = await supabase
    .from('control_stock_sesiones')
    .select('id, fecha, total_items')
    .eq('planilla_id', planillaId)
    .maybeSingle()
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo ver si la planilla ya se cargó.')
  return (data as CargaPreviaPlanilla | null) ?? null
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

/**
 * Busca si una planilla ya se aplicó, para avisarlo antes de que se intente
 * aplicar de nuevo (#1295). Siempre va al servidor (staleTime 0): un `null`
 * guardado de antes de aplicarla dejaría pasar la segunda carga. Ve las
 * sesiones de la sucursal activa; la RPC es la que decide.
 */
export function useBuscarCargaPreviaPlanilla() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useCallback(
    (planillaId: string) => queryClient.fetchQuery({
      queryKey: controlStockKeys.planilla(currentSucursalId, planillaId),
      queryFn: () => fetchCargaPrevia(planillaId),
      staleTime: 0,
    }),
    [queryClient, currentSucursalId],
  )
}

export function useAplicarControlStockMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ planillaId, ajustes }: AplicarControlStockInput): Promise<AplicarControlStockResult> => {
      const { data, error } = await supabase.rpc('aplicar_control_stock', {
        p_ajustes: ajustes,
        p_observaciones: null,
        p_planilla_id: planillaId,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el control de stock. Revisá si quedó hecho antes de reintentar.')
      return data as AplicarControlStockResult
    },
    onSuccess: () => {
      // El stock cambió: refrescar productos y el histórico de sesiones.
      queryClient.invalidateQueries({ queryKey: productosKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: controlStockKeys.all(currentSucursalId) })
    },
  })
}
