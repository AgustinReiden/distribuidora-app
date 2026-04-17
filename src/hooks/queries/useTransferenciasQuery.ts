/**
 * TanStack Query hooks para Transferencias a Sucursales
 * Maneja envios de stock a sucursales (branch transfers)
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { fechaLocalISO } from '../../utils/formatters'
import { useSucursal } from '../../contexts/SucursalContext'
import type {
  TransferenciaDB,
  TransferenciaFormInput,
  SucursalDB,
} from '../../types'

// Query keys
export const transferenciasKeys = {
  all: (sucursalId: number | null) => ['transferencias', sucursalId] as const,
  lists: (sucursalId: number | null) => [...transferenciasKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...transferenciasKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...transferenciasKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...transferenciasKeys.details(sucursalId), id] as const,
}

export const sucursalesKeys = {
  all: ['sucursales'] as const,
  lists: () => [...sucursalesKeys.all, 'list'] as const,
}

// Fetch functions
async function fetchTransferencias(): Promise<TransferenciaDB[]> {
  const { data, error } = await supabase
    .from('transferencias_stock')
    .select(`
      *,
      sucursal:sucursales(*),
      items:transferencia_items(*, producto:productos(*)),
      usuario:perfiles(id, nombre)
    `)
    .order('created_at', { ascending: false })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as TransferenciaDB[]
}

async function fetchSucursales(): Promise<SucursalDB[]> {
  const { data, error } = await supabase
    .from('sucursales')
    .select('*')
    .eq('activa', true)
    .order('nombre', { ascending: true })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as SucursalDB[]
}

async function crearSucursal(input: { nombre: string; direccion?: string }): Promise<SucursalDB> {
  const { data, error } = await supabase
    .from('sucursales')
    .insert({
      nombre: input.nombre,
      direccion: input.direccion || null,
      activa: true,
    })
    .select()
    .single()

  if (error) throw error
  return data as SucursalDB
}

interface RPCResult {
  success: boolean
  transferencia_id: string
  error?: string
}

function buildItemsParaRPC(items: TransferenciaFormInput['items']) {
  return items.map(item => ({
    producto_id: item.productoId,
    cantidad: item.cantidad,
    costo_unitario: item.costoUnitario,
    subtotal: item.subtotal,
  }))
}

async function registrarTransferencia(formData: TransferenciaFormInput): Promise<{ success: boolean; transferenciaId: string }> {
  const itemsParaRPC = buildItemsParaRPC(formData.items)

  const { data, error } = await supabase.rpc('registrar_transferencia', {
    p_sucursal_id: formData.sucursalId,
    p_fecha: formData.fecha || fechaLocalISO(),
    p_notas: formData.notas || null,
    p_total_costo: formData.totalCosto,
    p_usuario_id: formData.usuarioId || null,
    p_items: itemsParaRPC,
  })

  if (error) throw error

  const result = data as RPCResult
  if (!result.success) {
    throw new Error(result.error || 'Error al registrar transferencia')
  }

  return { success: true, transferenciaId: result.transferencia_id }
}

async function registrarIngresoSucursal(formData: TransferenciaFormInput): Promise<{ success: boolean; transferenciaId: string }> {
  const itemsParaRPC = buildItemsParaRPC(formData.items)

  const { data, error } = await supabase.rpc('registrar_ingreso_sucursal', {
    p_sucursal_id: formData.sucursalId,
    p_fecha: formData.fecha || fechaLocalISO(),
    p_notas: formData.notas || null,
    p_total_costo: formData.totalCosto,
    p_usuario_id: formData.usuarioId || null,
    p_items: itemsParaRPC,
  })

  if (error) throw error

  const result = data as RPCResult
  if (!result.success) {
    throw new Error(result.error || 'Error al registrar ingreso')
  }

  return { success: true, transferenciaId: result.transferencia_id }
}

// Hooks

/**
 * Hook para obtener todas las transferencias
 */
export function useTransferenciasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: transferenciasKeys.lists(currentSucursalId),
    queryFn: fetchTransferencias,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener sucursales activas
 */
export function useSucursalesQuery() {
  return useQuery({
    queryKey: sucursalesKeys.lists(),
    queryFn: fetchSucursales,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para crear una sucursal
 */
export function useCrearSucursalMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: crearSucursal,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: sucursalesKeys.lists() })
    },
  })
}

/**
 * Hook para registrar una transferencia (salida)
 */
export function useRegistrarTransferenciaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: registrarTransferencia,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: transferenciasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}

/**
 * Hook para registrar un ingreso desde sucursal
 */
export function useRegistrarIngresoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: registrarIngresoSucursal,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: transferenciasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}
