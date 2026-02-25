/**
 * TanStack Query hooks para Pedidos
 * Reemplaza el hook usePedidos con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient, keepPreviousData } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { PedidoDB, PedidoItemDB, PerfilDB, FiltrosPedidosState } from '../../types'
import { productosKeys } from './useProductosQuery'

// Query keys
export const pedidosKeys = {
  all: ['pedidos'] as const,
  lists: () => [...pedidosKeys.all, 'list'] as const,
  list: (filters: Partial<FiltrosPedidosState>) => [...pedidosKeys.lists(), filters] as const,
  details: () => [...pedidosKeys.all, 'detail'] as const,
  detail: (id: string) => [...pedidosKeys.details(), id] as const,
  byTransportista: (transportistaId: string) => [...pedidosKeys.all, 'transportista', transportistaId] as const,
  byCliente: (clienteId: string) => [...pedidosKeys.all, 'cliente', clienteId] as const,
  historial: (pedidoId: string) => [...pedidosKeys.all, 'historial', pedidoId] as const,
  eliminados: () => [...pedidosKeys.all, 'eliminados'] as const,
  paginated: (page: number, pageSize: number, filters: Partial<FiltrosPedidosState>) =>
    [...pedidosKeys.all, 'paginated', page, pageSize, filters] as const,
}

// Types
interface PedidoItemInput {
  productoId?: string
  producto_id?: string
  cantidad: number
  precioUnitario?: number
  precio_unitario?: number
}

interface CrearPedidoInput {
  clienteId: string
  items: PedidoItemInput[]
  total: number
  usuarioId: string | null
  notas?: string
  formaPago?: string
  estadoPago?: string
  montoPagado?: number
}

interface ActualizarEstadoInput {
  pedidoId: string
  nuevoEstado: string
}

interface ActualizarPagoInput {
  pedidoId: string
  estadoPago: string
  montoPagado?: number | null
}

// Fetch functions
async function fetchPedidos(): Promise<PedidoDB[]> {
  const { data, error } = await supabase
    .from('pedidos')
    .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
    .order('created_at', { ascending: false })

  if (error) throw error

  // Enrich with perfiles
  const perfilIds = new Set<string>()
  for (const pedido of (data || [])) {
    if (pedido.usuario_id) perfilIds.add(pedido.usuario_id as string)
    if (pedido.transportista_id) perfilIds.add(pedido.transportista_id as string)
  }

  let perfilesMap: Record<string, PerfilDB> = {}
  if (perfilIds.size > 0) {
    const { data: perfiles } = await supabase
      .from('perfiles')
      .select('id, nombre, email')
      .in('id', Array.from(perfilIds))

    if (perfiles) {
      perfilesMap = Object.fromEntries(
        (perfiles as PerfilDB[]).map(p => [p.id, p])
      )
    }
  }

  // Enrich pedidos with perfil data
  const enrichedPedidos = (data || []).map(pedido => ({
    ...pedido,
    usuario: pedido.usuario_id ? perfilesMap[pedido.usuario_id] : null,
    transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id] : null,
  }))

  return enrichedPedidos as PedidoDB[]
}

async function fetchPedidoById(id: string): Promise<PedidoDB | null> {
  const { data, error } = await supabase
    .from('pedidos')
    .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
    .eq('id', id)
    .single()

  if (error) throw error
  return data as PedidoDB
}

async function fetchPedidosByTransportista(transportistaId: string): Promise<PedidoDB[]> {
  const { data, error } = await supabase
    .from('pedidos')
    .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
    .eq('transportista_id', transportistaId)
    .in('estado', ['asignado', 'en_camino'])
    .order('orden_entrega', { ascending: true, nullsFirst: false })

  if (error) throw error
  return (data || []) as PedidoDB[]
}

async function fetchPedidosByCliente(clienteId: string): Promise<PedidoDB[]> {
  const { data, error } = await supabase
    .from('pedidos')
    .select(`*, items:pedido_items(*, producto:productos(*))`)
    .eq('cliente_id', clienteId)
    .order('created_at', { ascending: false })
    .limit(50)

  if (error) throw error
  return (data || []) as PedidoDB[]
}

// Paginated fetch
export interface PaginatedResult<T> {
  data: T[]
  totalCount: number
}

async function fetchPedidosPaginated(
  page: number,
  pageSize: number,
  filters?: Partial<FiltrosPedidosState>,
  search?: string
): Promise<PaginatedResult<PedidoDB>> {
  const from = (page - 1) * pageSize
  const to = from + pageSize - 1

  let query = supabase
    .from('pedidos')
    .select('*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))', { count: 'exact' })
    .order('created_at', { ascending: false })

  // Apply server-side filters
  if (filters?.estado && filters.estado !== 'todos') {
    query = query.eq('estado', filters.estado)
  }
  if (filters?.estadoPago && filters.estadoPago !== 'todos') {
    query = query.eq('estado_pago', filters.estadoPago)
  }
  if (filters?.transportistaId && filters.transportistaId !== 'todos') {
    query = query.eq('transportista_id', filters.transportistaId)
  }
  if (filters?.fechaDesde) {
    query = query.gte('created_at', filters.fechaDesde + 'T00:00:00')
  }
  if (filters?.fechaHasta) {
    query = query.lte('created_at', filters.fechaHasta + 'T23:59:59')
  }

  // Search by client name (using the foreign key relationship)
  if (search && search.trim().length > 0) {
    query = query.or(`cliente.nombre_fantasia.ilike.%${search.trim()}%,cliente.cuit.ilike.%${search.trim()}%`)
  }

  query = query.range(from, to)

  const { data, error, count } = await query

  if (error) throw error

  // Enrich with perfiles (same logic as fetchPedidos)
  const perfilIds = new Set<string>()
  for (const pedido of (data || [])) {
    if (pedido.usuario_id) perfilIds.add(pedido.usuario_id as string)
    if (pedido.transportista_id) perfilIds.add(pedido.transportista_id as string)
  }

  let perfilesMap: Record<string, PerfilDB> = {}
  if (perfilIds.size > 0) {
    const { data: perfiles } = await supabase
      .from('perfiles')
      .select('id, nombre, email')
      .in('id', Array.from(perfilIds))

    if (perfiles) {
      perfilesMap = Object.fromEntries(
        (perfiles as PerfilDB[]).map(p => [p.id, p])
      )
    }
  }

  const enrichedPedidos = (data || []).map(pedido => ({
    ...pedido,
    usuario: pedido.usuario_id ? perfilesMap[pedido.usuario_id] : null,
    transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id] : null,
  }))

  return { data: enrichedPedidos as PedidoDB[], totalCount: count ?? 0 }
}

// Mutation functions
async function crearPedido(input: CrearPedidoInput): Promise<{ id: string }> {
  const itemsParaRPC = input.items.map(item => ({
    producto_id: item.productoId || item.producto_id,
    cantidad: item.cantidad,
    precio_unitario: item.precioUnitario || item.precio_unitario
  }))

  const { data, error } = await supabase.rpc('crear_pedido_completo', {
    p_cliente_id: input.clienteId,
    p_items: itemsParaRPC,
    p_total: input.total,
    p_usuario_id: input.usuarioId,
    p_notas: input.notas || null,
    p_forma_pago: input.formaPago || 'efectivo',
    p_estado_pago: input.estadoPago || 'pendiente',
    p_monto_pagado: input.montoPagado || 0
  })

  if (error) throw error

  const result = data as { success: boolean; pedido_id?: string; errores?: string[] }
  if (!result.success) {
    throw new Error(result.errores?.join(', ') || 'Error al crear pedido')
  }

  return { id: result.pedido_id! }
}

async function actualizarEstado(input: ActualizarEstadoInput): Promise<PedidoDB> {
  const { data, error } = await supabase
    .from('pedidos')
    .update({ estado: input.nuevoEstado })
    .eq('id', input.pedidoId)
    .select()
    .single()

  if (error) throw error
  return data as PedidoDB
}

async function actualizarPago(input: ActualizarPagoInput): Promise<PedidoDB> {
  const updateData: Record<string, unknown> = { estado_pago: input.estadoPago }
  if (input.montoPagado !== undefined) {
    updateData.monto_pagado = input.montoPagado
  }

  const { data, error } = await supabase
    .from('pedidos')
    .update(updateData)
    .eq('id', input.pedidoId)
    .select()
    .single()

  if (error) throw error
  return data as PedidoDB
}

async function asignarTransportista(pedidoId: string, transportistaId: string | null): Promise<PedidoDB> {
  const updateData: Record<string, unknown> = {
    transportista_id: transportistaId,
    estado: transportistaId ? 'asignado' : 'pendiente'
  }

  const { data, error } = await supabase
    .from('pedidos')
    .update(updateData)
    .eq('id', pedidoId)
    .select()
    .single()

  if (error) throw error
  return data as PedidoDB
}

async function eliminarPedido(id: string, motivo?: string, usuarioId?: string): Promise<void> {
  const { data, error } = await supabase.rpc('eliminar_pedido_seguro', {
    p_pedido_id: id,
    p_usuario_id: usuarioId || null,
    p_motivo: motivo || null
  })

  if (error) throw error

  const result = data as { success: boolean; error?: string }
  if (!result.success) {
    throw new Error(result.error || 'Error al eliminar pedido')
  }
}

// Hooks

/**
 * Hook para obtener todos los pedidos
 */
export function usePedidosQuery() {
  return useQuery({
    queryKey: pedidosKeys.lists(),
    queryFn: fetchPedidos,
    staleTime: 2 * 60 * 1000, // 2 minutos - pedidos cambian frecuentemente
  })
}

/**
 * Hook para obtener un pedido por ID
 */
export function usePedidoQuery(id: string) {
  return useQuery({
    queryKey: pedidosKeys.detail(id),
    queryFn: () => fetchPedidoById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener pedidos de un transportista
 */
export function usePedidosByTransportistaQuery(transportistaId: string) {
  return useQuery({
    queryKey: pedidosKeys.byTransportista(transportistaId),
    queryFn: () => fetchPedidosByTransportista(transportistaId),
    enabled: !!transportistaId,
    staleTime: 1 * 60 * 1000, // 1 minuto
  })
}

/**
 * Hook para obtener pedidos de un cliente
 */
export function usePedidosByClienteQuery(clienteId: string) {
  return useQuery({
    queryKey: pedidosKeys.byCliente(clienteId),
    queryFn: () => fetchPedidosByCliente(clienteId),
    enabled: !!clienteId,
    staleTime: 2 * 60 * 1000,
  })
}

/**
 * Hook para obtener pedidos paginados con filtros server-side
 */
export function usePedidosPaginatedQuery(
  page: number,
  pageSize: number,
  filters?: Partial<FiltrosPedidosState>,
  search?: string
) {
  return useQuery({
    queryKey: pedidosKeys.paginated(page, pageSize, { ...filters, busqueda: search } as Partial<FiltrosPedidosState>),
    queryFn: () => fetchPedidosPaginated(page, pageSize, filters, search),
    staleTime: 2 * 60 * 1000,
    placeholderData: keepPreviousData,
  })
}

/**
 * Hook para crear un pedido
 */
export function useCrearPedidoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: crearPedido,
    onSuccess: () => {
      // Invalidar todas las queries de pedidos (list + paginated)
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all })
      // Invalidar productos (por cambio de stock)
      queryClient.invalidateQueries({ queryKey: productosKeys.lists() })
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(10) })
    },
  })
}

/**
 * Hook para cambiar estado de un pedido (optimistic update)
 */
export function useCambiarEstadoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: actualizarEstado,
    // Optimistic update
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: pedidosKeys.lists() })

      const previousPedidos = queryClient.getQueryData<PedidoDB[]>(pedidosKeys.lists())

      queryClient.setQueryData<PedidoDB[]>(pedidosKeys.lists(), (old) => {
        if (!old) return old
        return old.map(p =>
          p.id === input.pedidoId ? { ...p, estado: input.nuevoEstado as PedidoDB['estado'] } : p
        )
      })

      return { previousPedidos }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousPedidos) {
        queryClient.setQueryData(pedidosKeys.lists(), context.previousPedidos)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all })
    },
  })
}

/**
 * Hook para actualizar estado de pago (optimistic update)
 */
export function useActualizarPagoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: actualizarPago,
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: pedidosKeys.lists() })

      const previousPedidos = queryClient.getQueryData<PedidoDB[]>(pedidosKeys.lists())

      queryClient.setQueryData<PedidoDB[]>(pedidosKeys.lists(), (old) => {
        if (!old) return old
        return old.map(p =>
          p.id === input.pedidoId
            ? { ...p, estado_pago: input.estadoPago as PedidoDB['estado_pago'], monto_pagado: input.montoPagado ?? p.monto_pagado }
            : p
        )
      })

      return { previousPedidos }
    },
    onError: (_, __, context) => {
      if (context?.previousPedidos) {
        queryClient.setQueryData(pedidosKeys.lists(), context.previousPedidos)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all })
    },
  })
}

/**
 * Hook para asignar transportista
 */
export function useAsignarTransportistaMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ pedidoId, transportistaId }: { pedidoId: string; transportistaId: string | null }) =>
      asignarTransportista(pedidoId, transportistaId),
    onSuccess: (_, { transportistaId }) => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all })
      if (transportistaId) {
        queryClient.invalidateQueries({ queryKey: pedidosKeys.byTransportista(transportistaId) })
      }
    },
  })
}

/**
 * Hook para eliminar un pedido
 */
export function useEliminarPedidoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ id, motivo, usuarioId }: { id: string; motivo?: string; usuarioId?: string }) =>
      eliminarPedido(id, motivo, usuarioId),
    onSuccess: (_, { id }) => {
      // Remover de cache
      queryClient.removeQueries({ queryKey: pedidosKeys.detail(id) })
      // Actualizar lista (optimistic for legacy query)
      queryClient.setQueryData<PedidoDB[]>(pedidosKeys.lists(), (old) => {
        if (!old) return []
        return old.filter(p => p.id !== id)
      })
      // Invalidar todas las queries de pedidos (list + paginated)
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all })
      // Invalidar productos (stock restaurado)
      queryClient.invalidateQueries({ queryKey: productosKeys.lists() })
    },
  })
}
