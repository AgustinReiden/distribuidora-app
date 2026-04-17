/**
 * TanStack Query hooks para Pedidos
 * Reemplaza el hook usePedidos con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient, keepPreviousData } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { PedidoDB, PedidoItemDB, PerfilDB, FiltrosPedidosState, PedidoSalvedadResumen } from '../../types'
import { productosKeys } from './useProductosQuery'

// Query keys
export const pedidosKeys = {
  all: (sucursalId: number | null) => ['pedidos', sucursalId] as const,
  lists: (sucursalId: number | null) => [...pedidosKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Partial<FiltrosPedidosState>) => [...pedidosKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...pedidosKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...pedidosKeys.details(sucursalId), id] as const,
  byTransportista: (sucursalId: number | null, transportistaId: string) => [...pedidosKeys.all(sucursalId), 'transportista', transportistaId] as const,
  byCliente: (sucursalId: number | null, clienteId: string) => [...pedidosKeys.all(sucursalId), 'cliente', clienteId] as const,
  historial: (sucursalId: number | null, pedidoId: string) => [...pedidosKeys.all(sucursalId), 'historial', pedidoId] as const,
  eliminados: (sucursalId: number | null) => [...pedidosKeys.all(sucursalId), 'eliminados'] as const,
  paginated: (sucursalId: number | null, page: number, pageSize: number, filters: Partial<FiltrosPedidosState>) =>
    [...pedidosKeys.all(sucursalId), 'paginated', page, pageSize, filters] as const,
  noEntregados: (sucursalId: number | null) => [...pedidosKeys.all(sucursalId), 'no-entregados'] as const,
  noPagados: (sucursalId: number | null) => [...pedidosKeys.all(sucursalId), 'no-pagados'] as const,
}

// Types
interface PedidoItemInput {
  productoId?: string
  producto_id?: string
  cantidad: number
  precioUnitario?: number
  precio_unitario?: number
  esBonificacion?: boolean
  promocionId?: string
  neto_unitario?: number
  iva_unitario?: number
  impuestos_internos_unitario?: number
  porcentaje_iva?: number
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
  fecha?: string
  tipoFactura?: 'ZZ' | 'FC'
  totalNeto?: number
  totalIva?: number
  fechaEntregaProgramada?: string
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

// Helper: cargar salvedades para un conjunto de pedidos
async function enrichWithSalvedades(pedidos: Record<string, unknown>[]): Promise<Record<string, PedidoSalvedadResumen[]>> {
  const pedidosEntregadosIds = pedidos
    .filter(p => p.estado === 'entregado')
    .map(p => p.id)

  if (pedidosEntregadosIds.length === 0) return {}

  const { data: salvedades } = await supabase
    .from('salvedades_items')
    .select('id, pedido_id, motivo, cantidad_afectada, monto_afectado, estado_resolucion, producto_id')
    .in('pedido_id', pedidosEntregadosIds)

  const salvedadesMap: Record<string, PedidoSalvedadResumen[]> = {}
  if (salvedades) {
    for (const s of salvedades) {
      const pedidoId = String(s.pedido_id)
      if (!salvedadesMap[pedidoId]) salvedadesMap[pedidoId] = []
      salvedadesMap[pedidoId].push({
        id: String(s.id),
        motivo: s.motivo,
        cantidad_afectada: s.cantidad_afectada,
        monto_afectado: Number(s.monto_afectado),
        estado_resolucion: s.estado_resolucion,
        producto_id: String(s.producto_id),
      })
    }
  }
  return salvedadesMap
}

// Fetch functions
async function fetchPedidos(): Promise<PedidoDB[]> {
  const { data, error } = await supabase
    .from('pedidos')
    .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
    .order('created_at', { ascending: false })
    .limit(500) // Limitar carga inicial para evitar consumo excesivo de memoria

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

  // Enrich with salvedades
  const salvedadesMap = await enrichWithSalvedades(data || [])

  // Enrich pedidos with perfil data + salvedades
  const enrichedPedidos = (data || []).map(pedido => ({
    ...pedido,
    usuario: pedido.usuario_id ? perfilesMap[pedido.usuario_id] : null,
    transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id] : null,
    salvedades: salvedadesMap[String(pedido.id)] || [],
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

  const hasSearch = search && search.trim().length > 0

  // Use !inner join when searching so PostgREST filters parent rows by client fields
  const selectStr = hasSearch
    ? '*, cliente:clientes!inner(*), items:pedido_items(*, producto:productos(*))'
    : '*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))'

  let query = supabase
    .from('pedidos')
    .select(selectStr, { count: 'exact' })
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
    query = query.gte('fecha', filters.fechaDesde)
  }
  if (filters?.fechaHasta) {
    query = query.lte('fecha', filters.fechaHasta)
  }
  if (filters?.ocultarCancelados) {
    query = query.neq('estado', 'cancelado')
  }
  if (filters?.fechaEntregaProgramada) {
    query = query.eq('fecha_entrega_programada', filters.fechaEntregaProgramada)
  }

  // Search by client fields using referencedTable for related table filtering
  if (hasSearch) {
    const trimmed = search!.trim()
    query = query.or(
      `nombre_fantasia.ilike.%${trimmed}%,razon_social.ilike.%${trimmed}%,cuit.ilike.%${trimmed}%,direccion.ilike.%${trimmed}%`,
      { referencedTable: 'clientes' }
    )
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

  // Enrich with salvedades
  const salvedadesMap = await enrichWithSalvedades(data || [])

  const enrichedPedidos = (data || []).map(pedido => ({
    ...pedido,
    usuario: pedido.usuario_id ? perfilesMap[pedido.usuario_id] : null,
    transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id] : null,
    salvedades: salvedadesMap[String(pedido.id)] || [],
  }))

  return { data: enrichedPedidos as PedidoDB[], totalCount: count ?? 0 }
}

// Mutation functions
async function crearPedido(input: CrearPedidoInput): Promise<{ id: string }> {
  const itemsParaRPC = input.items.map(item => ({
    producto_id: item.productoId || item.producto_id,
    cantidad: item.cantidad,
    precio_unitario: item.precioUnitario ?? item.precio_unitario ?? 0,
    ...(item.esBonificacion ? { es_bonificacion: true } : {}),
    ...(item.promocionId ? { promocion_id: item.promocionId } : {}),
    ...(item.neto_unitario != null ? { neto_unitario: item.neto_unitario } : {}),
    ...(item.iva_unitario != null ? { iva_unitario: item.iva_unitario } : {}),
    ...(item.impuestos_internos_unitario != null ? { impuestos_internos_unitario: item.impuestos_internos_unitario } : {}),
    ...(item.porcentaje_iva != null ? { porcentaje_iva: item.porcentaje_iva } : {}),
  }))

  const { data, error } = await supabase.rpc('crear_pedido_completo', {
    p_cliente_id: input.clienteId,
    p_total: input.total,
    p_usuario_id: input.usuarioId,
    p_items: itemsParaRPC,
    p_notas: input.notas || null,
    p_forma_pago: input.formaPago || 'efectivo',
    p_estado_pago: input.estadoPago || 'pendiente',
    ...(input.fecha ? { p_fecha: input.fecha } : {}),
    p_tipo_factura: input.tipoFactura || 'ZZ',
    p_total_neto: input.totalNeto ?? input.total,
    p_total_iva: input.totalIva ?? 0,
    ...(input.fechaEntregaProgramada ? { p_fecha_entrega_programada: input.fechaEntregaProgramada } : {})
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
  const { data, error } = await supabase.rpc('eliminar_pedido_completo', {
    p_pedido_id: id,
    p_restaurar_stock: true,
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
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: pedidosKeys.lists(currentSucursalId),
    queryFn: fetchPedidos,
    staleTime: 2 * 60 * 1000, // 2 minutos - pedidos cambian frecuentemente
  })
}

/**
 * Hook para obtener un pedido por ID
 */
export function usePedidoQuery(id: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: pedidosKeys.detail(currentSucursalId, id),
    queryFn: () => fetchPedidoById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener pedidos de un transportista
 */
export function usePedidosByTransportistaQuery(transportistaId: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: pedidosKeys.byTransportista(currentSucursalId, transportistaId),
    queryFn: () => fetchPedidosByTransportista(transportistaId),
    enabled: !!transportistaId,
    staleTime: 1 * 60 * 1000, // 1 minuto
  })
}

/**
 * Hook para obtener pedidos de un cliente
 */
export function usePedidosByClienteQuery(clienteId: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: pedidosKeys.byCliente(currentSucursalId, clienteId),
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
  search?: string,
  enabled = true
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: pedidosKeys.paginated(currentSucursalId, page, pageSize, { ...filters, busqueda: search } as Partial<FiltrosPedidosState>),
    queryFn: () => fetchPedidosPaginated(page, pageSize, filters, search),
    staleTime: 2 * 60 * 1000,
    placeholderData: keepPreviousData,
    enabled,
  })
}

/**
 * Hook para crear un pedido
 */
export function useCrearPedidoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: crearPedido,
    onSuccess: () => {
      // Invalidar todas las queries de pedidos (list + paginated)
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
      // Invalidar productos (por cambio de stock)
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.stockBajo(currentSucursalId, 10) })
    },
  })
}

/**
 * Hook para cambiar estado de un pedido (optimistic update)
 */
export function useCambiarEstadoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: actualizarEstado,
    // Optimistic update
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: pedidosKeys.lists(currentSucursalId) })

      const previousPedidos = queryClient.getQueryData<PedidoDB[]>(pedidosKeys.lists(currentSucursalId))

      queryClient.setQueryData<PedidoDB[]>(pedidosKeys.lists(currentSucursalId), (old) => {
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
        queryClient.setQueryData(pedidosKeys.lists(currentSucursalId), context.previousPedidos)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para actualizar estado de pago (optimistic update)
 */
export function useActualizarPagoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: actualizarPago,
    onMutate: async (input) => {
      await queryClient.cancelQueries({ queryKey: pedidosKeys.lists(currentSucursalId) })

      const previousPedidos = queryClient.getQueryData<PedidoDB[]>(pedidosKeys.lists(currentSucursalId))

      queryClient.setQueryData<PedidoDB[]>(pedidosKeys.lists(currentSucursalId), (old) => {
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
        queryClient.setQueryData(pedidosKeys.lists(currentSucursalId), context.previousPedidos)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para asignar transportista
 */
export function useAsignarTransportistaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ pedidoId, transportistaId }: { pedidoId: string; transportistaId: string | null }) =>
      asignarTransportista(pedidoId, transportistaId),
    onSuccess: (_, { transportistaId }) => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
      if (transportistaId) {
        queryClient.invalidateQueries({ queryKey: pedidosKeys.byTransportista(currentSucursalId, transportistaId) })
      }
    },
  })
}

/**
 * Hook para eliminar un pedido
 */
export function useEliminarPedidoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ id, motivo, usuarioId }: { id: string; motivo?: string; usuarioId?: string }) =>
      eliminarPedido(id, motivo, usuarioId),
    onSuccess: (_, { id }) => {
      // Remover de cache
      queryClient.removeQueries({ queryKey: pedidosKeys.detail(currentSucursalId, id) })
      // Actualizar lista (optimistic for legacy query)
      queryClient.setQueryData<PedidoDB[]>(pedidosKeys.lists(currentSucursalId), (old) => {
        if (!old) return []
        return old.filter(p => p.id !== id)
      })
      // Invalidar todas las queries de pedidos (list + paginated)
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
      // Invalidar productos (stock restaurado)
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
    },
  })
}

// =========================================================================
// Entregas Masivas
// =========================================================================

async function fetchPedidosNoEntregados(): Promise<PedidoDB[]> {
  const { data, error } = await supabase
    .from('pedidos')
    .select('*, cliente:clientes(id, nombre_fantasia, direccion)')
    .not('estado', 'in', '("entregado","cancelado")')
    .order('created_at', { ascending: false })

  if (error) throw error

  // Enrich with transportista names
  const transportistaIds = new Set<string>()
  for (const pedido of (data || [])) {
    if (pedido.transportista_id) transportistaIds.add(pedido.transportista_id as string)
  }

  let perfilesMap: Record<string, PerfilDB> = {}
  if (transportistaIds.size > 0) {
    const { data: perfiles } = await supabase
      .from('perfiles')
      .select('id, nombre, email')
      .in('id', Array.from(transportistaIds))

    if (perfiles) {
      perfilesMap = Object.fromEntries(
        (perfiles as PerfilDB[]).map(p => [p.id, p])
      )
    }
  }

  return (data || []).map(pedido => ({
    ...pedido,
    transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id] : null,
  })) as PedidoDB[]
}

/**
 * Hook para obtener todos los pedidos no entregados/cancelados (sin paginacion)
 * Se habilita solo cuando enabled=true (modal abierto)
 */
export function usePedidosNoEntregadosQuery(enabled = false) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: pedidosKeys.noEntregados(currentSucursalId),
    queryFn: fetchPedidosNoEntregados,
    enabled,
    staleTime: 30 * 1000, // 30 segundos
  })
}

async function entregarPedidosMasivo(pedidoIds: string[], transportistaId: string): Promise<void> {
  const ahora = new Date().toISOString()

  const { error } = await supabase
    .from('pedidos')
    .update({
      transportista_id: transportistaId,
      estado: 'entregado',
      fecha_entrega: ahora,
    })
    .in('id', pedidoIds)

  if (error) throw error

  // Registrar historial best-effort
  const historialEntries = pedidoIds.map(pedidoId => ({
    pedido_id: pedidoId,
    accion: 'entregado',
    descripcion: `Entrega masiva - Transportista: ${transportistaId}`,
    fecha: ahora,
  }))

  await supabase.from('pedido_historial').insert(historialEntries).then(() => {})
}

/**
 * Hook para marcar multiples pedidos como entregados
 */
export function useEntregasMasivasMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ pedidoIds, transportistaId }: { pedidoIds: string[]; transportistaId: string }) =>
      entregarPedidosMasivo(pedidoIds, transportistaId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
    },
  })
}

// =========================================================================
// Cancelar Pedido
// =========================================================================

async function cancelarPedido(pedidoId: string, motivo: string, usuarioId?: string): Promise<void> {
  const { data, error } = await supabase.rpc('cancelar_pedido_con_stock', {
    p_pedido_id: pedidoId,
    p_motivo: motivo,
    p_usuario_id: usuarioId || null,
  })

  if (error) throw error

  const result = data as { success: boolean; error?: string }
  if (!result.success) {
    throw new Error(result.error || 'Error al cancelar pedido')
  }
}

/**
 * Hook para cancelar un pedido con motivo (restaura stock automaticamente)
 */
export function useCancelarPedidoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ pedidoId, motivo, usuarioId }: { pedidoId: string; motivo: string; usuarioId?: string }) =>
      cancelarPedido(pedidoId, motivo, usuarioId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.all(currentSucursalId) })
    },
  })
}

// =========================================================================
// Pagos Masivos
// =========================================================================

async function fetchPedidosNoPagados(): Promise<PedidoDB[]> {
  const { data, error } = await supabase
    .from('pedidos')
    .select('*, cliente:clientes(id, nombre_fantasia, direccion)')
    .neq('estado_pago', 'pagado')
    .neq('estado', 'cancelado')
    .order('created_at', { ascending: false })

  if (error) throw error

  // Enrich with transportista names
  const transportistaIds = new Set<string>()
  for (const pedido of (data || [])) {
    if (pedido.transportista_id) transportistaIds.add(pedido.transportista_id as string)
  }

  let perfilesMap: Record<string, PerfilDB> = {}
  if (transportistaIds.size > 0) {
    const { data: perfiles } = await supabase
      .from('perfiles')
      .select('id, nombre, email')
      .in('id', Array.from(transportistaIds))

    if (perfiles) {
      perfilesMap = Object.fromEntries(
        (perfiles as PerfilDB[]).map(p => [p.id, p])
      )
    }
  }

  return (data || []).map(pedido => ({
    ...pedido,
    transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id] : null,
  })) as PedidoDB[]
}

/**
 * Hook para obtener todos los pedidos no pagados (sin paginacion)
 * Se habilita solo cuando enabled=true (modal abierto)
 */
export function usePedidosNoPagadosQuery(enabled = false) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: pedidosKeys.noPagados(currentSucursalId),
    queryFn: fetchPedidosNoPagados,
    enabled,
    staleTime: 30 * 1000,
  })
}

async function marcarPagosMasivo(pedidoIds: string[], formaPago: string): Promise<void> {
  // First get the totals for each pedido to set monto_pagado correctly
  const { data: pedidos, error: fetchError } = await supabase
    .from('pedidos')
    .select('id, total')
    .in('id', pedidoIds)

  if (fetchError) throw fetchError

  // Update each pedido with its own total as monto_pagado
  for (const pedido of (pedidos || [])) {
    const { error } = await supabase
      .from('pedidos')
      .update({
        estado_pago: 'pagado',
        monto_pagado: pedido.total,
        forma_pago: formaPago,
      })
      .eq('id', pedido.id)

    if (error) throw error
  }

  // Registrar historial best-effort
  const ahora = new Date().toISOString()
  const historialEntries = pedidoIds.map(pedidoId => ({
    pedido_id: pedidoId,
    accion: 'pago_registrado',
    descripcion: `Pago masivo - Forma: ${formaPago}`,
    fecha: ahora,
  }))

  await supabase.from('pedido_historial').insert(historialEntries).then(() => {})
}

/**
 * Hook para marcar multiples pedidos como pagados
 */
export function usePagosMasivosMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ pedidoIds, formaPago }: { pedidoIds: string[]; formaPago: string }) =>
      marcarPagosMasivo(pedidoIds, formaPago),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all(currentSucursalId) })
    },
  })
}
