/**
 * TanStack Query hooks para Transferencias a Sucursales
 * Maneja envios de stock a sucursales (branch transfers)
 *
 * Cambios mig 057:
 *   - La RLS ahora deja ver tanto egreso como ingreso (tenant o contraparte
 *     coinciden con la sucursal activa). El listado puede traer movimientos
 *     entrantes y salientes — bien.
 *   - `fetchTransferencias` ahora pagina (LIMIT 50 + offset) y filtra por
 *     rango de fecha (default ultimos 60 dias) para no traer todo el
 *     historial en una sola request.
 *   - El detalle (`items + producto`) sale del listado y se carga via
 *     `useTransferenciaItemsQuery` solo cuando se abre el modal de detalle.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { fechaLocalISO, fechaHaceDias } from '../../utils/formatters'
import { useSucursal } from '../../contexts/SucursalContext'
import type {
  TransferenciaDB,
  TransferenciaFormInput,
  TransferenciaItemDB,
  SucursalDB,
} from '../../types'

export const TRANSFERENCIAS_PAGE_SIZE = 50

export interface TransferenciasFiltros {
  desde?: string
  hasta?: string
  pagina?: number
}

// Query keys
export const transferenciasKeys = {
  all: (sucursalId: number | null) => ['transferencias', sucursalId] as const,
  lists: (sucursalId: number | null) => [...transferenciasKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...transferenciasKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...transferenciasKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...transferenciasKeys.details(sucursalId), id] as const,
  items: (sucursalId: number | null, id: string) => [...transferenciasKeys.detail(sucursalId, id), 'items'] as const,
}

export const sucursalesKeys = {
  all: ['sucursales'] as const,
  lists: () => [...sucursalesKeys.all, 'list'] as const,
}

interface FetchTransferenciasOpts {
  desde: string
  hasta: string
  limit: number
  offset: number
}

// Fetch functions
async function fetchTransferencias(opts: FetchTransferenciasOpts): Promise<TransferenciaDB[]> {
  // IMPORTANTE: transferencias_stock tiene DOS FK a sucursales (sucursal_id y
  // tenant_sucursal_id desde mig 057). Sin hint explicito de FK, PostgREST
  // devuelve "Could not embed because more than one relationship..." y la
  // tabla se ve vacia. Por eso especificamos !sucursal_id (la contraparte
  // del movimiento, que es lo que ya espera la vista).
  const { data, error } = await supabase
    .from('transferencias_stock')
    .select(`
      *,
      sucursal:sucursales!sucursal_id(id, nombre),
      usuario:perfiles!usuario_id(id, nombre)
    `)
    .gte('fecha', opts.desde)
    .lte('fecha', opts.hasta)
    .order('created_at', { ascending: false })
    .range(opts.offset, opts.offset + opts.limit - 1)

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as TransferenciaDB[]
}

async function fetchTransferenciaItems(transferenciaId: string): Promise<TransferenciaItemDB[]> {
  const { data, error } = await supabase
    .from('transferencia_items')
    .select('*, producto:productos(*)')
    .eq('transferencia_id', transferenciaId)
  if (error) throw error
  return (data || []) as TransferenciaItemDB[]
}

async function fetchSucursales(): Promise<SucursalDB[]> {
  // Multi-tenant (C3): filter out tenant rows (ManaosApp/TP Export, tipo
  // 'principal' / 'secundaria') from the transfer-destination dropdown.
  // Only sub-sucursales (tipo='distribuidora') are valid transfer targets;
  // otherwise the UI would let a user move stock into the tenant row itself,
  // which has no warehouse semantics.
  const { data, error } = await supabase
    .from('sucursales')
    .select('*')
    .eq('activa', true)
    .eq('tipo', 'distribuidora')
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
 * Hook para obtener transferencias paginadas con filtro de fecha.
 * Default: ultimos 60 dias, pagina 1, 50 filas. Para historial mayor, el
 * caller puede pasar `desde` / `hasta` y `pagina`.
 *
 * Importante: el listado NO trae items — solo el header + sucursal contraparte
 * + usuario. Para ver items, abrir el detalle con useTransferenciaItemsQuery.
 */
export function useTransferenciasQuery(filtros: TransferenciasFiltros = {}) {
  const { currentSucursalId } = useSucursal()
  const desde = filtros.desde ?? fechaHaceDias(60)
  const hasta = filtros.hasta ?? fechaLocalISO()
  const pagina = filtros.pagina ?? 1
  const limit = TRANSFERENCIAS_PAGE_SIZE
  return useQuery({
    queryKey: transferenciasKeys.list(currentSucursalId, { desde, hasta, pagina }),
    queryFn: () => fetchTransferencias({
      desde,
      hasta,
      limit,
      offset: (pagina - 1) * limit,
    }),
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para cargar los items de UNA transferencia. Se usa al abrir el modal
 * de detalle. Mantiene el listado liviano y evita el N+1 que tenia el query
 * original al traer items + producto en cada fila.
 */
export function useTransferenciaItemsQuery(transferenciaId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: transferenciasKeys.items(currentSucursalId, transferenciaId ?? ''),
    queryFn: () => fetchTransferenciaItems(transferenciaId!),
    enabled: !!transferenciaId,
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
      // Invalida TODAS las paginas y filtros del listado actual de sucursal.
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
      // Invalida TODAS las paginas y filtros del listado actual de sucursal.
      queryClient.invalidateQueries({ queryKey: transferenciasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}
