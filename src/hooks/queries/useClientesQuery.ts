/**
 * TanStack Query hooks para Clientes
 * Reemplaza el hook useClientes con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { ClienteDB } from '../../types'

// Query keys
export const clientesKeys = {
  all: (sucursalId: number | null) => ['clientes', sucursalId] as const,
  lists: (sucursalId: number | null) => [...clientesKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...clientesKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...clientesKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...clientesKeys.details(sucursalId), id] as const,
  byZona: (sucursalId: number | null, zona: string) => [...clientesKeys.all(sucursalId), 'zona', zona] as const,
  zonas: (sucursalId: number | null) => [...clientesKeys.all(sucursalId), 'zonas'] as const,
}

type ClienteRow = ClienteDB & {
  cliente_preventistas?: { preventista_id: string }[] | null
}

function flattenPreventistaIds(row: ClienteRow): ClienteDB {
  const { cliente_preventistas, ...rest } = row
  return {
    ...rest,
    preventista_ids: (cliente_preventistas || []).map(cp => cp.preventista_id)
  }
}

// Fetch functions
async function fetchClientes(): Promise<ClienteDB[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('*, cliente_preventistas(preventista_id)')
    .order('nombre_fantasia')

  if (error) throw error
  return ((data as ClienteRow[]) || []).map(flattenPreventistaIds)
}

async function fetchClienteById(id: string): Promise<ClienteDB | null> {
  const { data, error } = await supabase
    .from('clientes')
    .select('*, cliente_preventistas(preventista_id)')
    .eq('id', id)
    .single()

  if (error) throw error
  return data ? flattenPreventistaIds(data as ClienteRow) : null
}

/**
 * Reemplaza las filas en `cliente_preventistas` para un cliente dado.
 * Idempotente: si el array viene vacío borra todas las asignaciones.
 */
async function replacePreventistaAssignments(
  clienteId: string,
  preventistaIds: string[]
): Promise<void> {
  const { error: delError } = await supabase
    .from('cliente_preventistas')
    .delete()
    .eq('cliente_id', clienteId)
  if (delError) throw delError

  if (preventistaIds.length === 0) return

  const rows = preventistaIds.map(pid => ({ cliente_id: clienteId, preventista_id: pid }))
  const { error: insError } = await supabase
    .from('cliente_preventistas')
    .insert(rows)
  if (insError) throw insError
}

async function fetchClientesByZona(zona: string): Promise<ClienteDB[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('*')
    .eq('zona', zona)
    .order('nombre_fantasia')

  if (error) throw error
  return (data as ClienteDB[]) || []
}

async function fetchZonasUnicas(): Promise<string[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('zona')
    .not('zona', 'is', null)

  if (error) throw error

  const zonas = [...new Set((data || []).map(c => c.zona).filter(Boolean) as string[])]
  return zonas.sort()
}

// Mutation types
interface ClienteCreateInput {
  razon_social: string
  nombre_fantasia: string
  direccion: string
  telefono?: string
  cuit?: string
  zona?: string
  latitud?: number | null
  longitud?: number | null
  limite_credito?: number
  dias_credito?: number
  contacto?: string
  horarios_atencion?: string
  rubro?: string
  notas?: string
  preventista_id?: string | null
  preventista_ids?: string[]
}

// Mutation functions
async function createCliente(cliente: ClienteCreateInput, sucursalId: number | null): Promise<ClienteDB> {
  // La RLS multi-tenant requiere sucursal_id = current_sucursal_id() y la
  // columna es NOT NULL. Sin esto el INSERT falla con "Error al crear cliente".
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  // Detección de duplicados por ubicación (~0.2 metros de tolerancia)
  if (cliente.latitud != null && cliente.longitud != null) {
    const TOLERANCE = 0.000002 // ~0.2 metros (6 decimales de precisión)
    const { data: cercanos } = await supabase
      .from('clientes')
      .select('id, nombre_fantasia, razon_social')
      .gte('latitud', cliente.latitud - TOLERANCE)
      .lte('latitud', cliente.latitud + TOLERANCE)
      .gte('longitud', cliente.longitud - TOLERANCE)
      .lte('longitud', cliente.longitud + TOLERANCE)
      .limit(1)

    if (cercanos && cercanos.length > 0) {
      const nombre = cercanos[0].nombre_fantasia || cercanos[0].razon_social
      throw new Error(
        `Ya existe un cliente en esta ubicación: ${nombre}. ` +
        `Si necesitás crear otro, modificá ligeramente la dirección.`
      )
    }
  }

  const { preventista_ids, ...clienteFields } = cliente
  const { data, error } = await supabase
    .from('clientes')
    .insert([{
      razon_social: clienteFields.razon_social,
      nombre_fantasia: clienteFields.nombre_fantasia,
      direccion: clienteFields.direccion,
      telefono: clienteFields.telefono || null,
      cuit: clienteFields.cuit || null,
      zona: clienteFields.zona || null,
      latitud: clienteFields.latitud || null,
      longitud: clienteFields.longitud || null,
      limite_credito: clienteFields.limite_credito || 0,
      dias_credito: clienteFields.dias_credito || 30,
      contacto: clienteFields.contacto || null,
      horarios_atencion: clienteFields.horarios_atencion || null,
      rubro: clienteFields.rubro || null,
      notas: clienteFields.notas || null,
      sucursal_id: sucursalId,
      ...(clienteFields.preventista_id ? { preventista_id: clienteFields.preventista_id } : {})
    }])
    .select()
    .single()

  if (error) throw error
  const newCliente = data as ClienteDB

  if (preventista_ids !== undefined) {
    await replacePreventistaAssignments(newCliente.id, preventista_ids)
    newCliente.preventista_ids = preventista_ids
  }

  return newCliente
}

async function updateCliente({ id, data: cliente }: { id: string; data: Partial<ClienteCreateInput> }): Promise<ClienteDB> {
  const { preventista_ids, ...clienteFields } = cliente

  const { data, error } = await supabase
    .from('clientes')
    .update(clienteFields)
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  const updated = data as ClienteDB

  if (preventista_ids !== undefined) {
    await replacePreventistaAssignments(id, preventista_ids)
    updated.preventista_ids = preventista_ids
  }

  return updated
}

async function deleteCliente(id: string): Promise<void> {
  const { error } = await supabase
    .from('clientes')
    .delete()
    .eq('id', id)

  if (error) throw error
}

// Hooks

/**
 * Hook para obtener todos los clientes activos
 */
export function useClientesQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: clientesKeys.lists(currentSucursalId),
    queryFn: fetchClientes,
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para obtener un cliente por ID
 */
export function useClienteQuery(id: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: clientesKeys.detail(currentSucursalId, id),
    queryFn: () => fetchClienteById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener clientes por zona
 */
export function useClientesByZonaQuery(zona: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: clientesKeys.byZona(currentSucursalId, zona),
    queryFn: () => fetchClientesByZona(zona),
    enabled: !!zona,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener zonas únicas
 */
export function useZonasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: clientesKeys.zonas(currentSucursalId),
    queryFn: fetchZonasUnicas,
    staleTime: 10 * 60 * 1000, // 10 minutos - zonas cambian poco
  })
}

/**
 * Hook para crear un cliente
 */
export function useCrearClienteMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (cliente: ClienteCreateInput) => createCliente(cliente, currentSucursalId),
    onSuccess: (newCliente) => {
      // Actualizar cache de lista
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(currentSucursalId), (old) => {
        if (!old) return [newCliente]
        return [...old, newCliente].sort((a, b) =>
          (a.nombre_fantasia || '').localeCompare(b.nombre_fantasia || '')
        )
      })
      // Invalidar zonas por si es una nueva zona
      queryClient.invalidateQueries({ queryKey: clientesKeys.zonas(currentSucursalId) })
      // Invalidar clientes por zona si aplica
      if (newCliente.zona) {
        queryClient.invalidateQueries({ queryKey: clientesKeys.byZona(currentSucursalId, newCliente.zona) })
      }
    },
  })
}

/**
 * Hook para actualizar un cliente (con optimistic update)
 */
export function useActualizarClienteMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: updateCliente,
    // Optimistic update
    onMutate: async ({ id, data: cliente }) => {
      await queryClient.cancelQueries({ queryKey: clientesKeys.lists(currentSucursalId) })

      const previousClientes = queryClient.getQueryData<ClienteDB[]>(clientesKeys.lists(currentSucursalId))

      // Aplicar cambios optimistamente
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.map(c => c.id === id ? { ...c, ...cliente } as ClienteDB : c)
      })

      return { previousClientes }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousClientes) {
        queryClient.setQueryData(clientesKeys.lists(currentSucursalId), context.previousClientes)
      }
    },
    onSuccess: (updatedCliente) => {
      // Actualizar cache de detalle con datos reales del servidor
      queryClient.setQueryData(clientesKeys.detail(currentSucursalId, updatedCliente.id), updatedCliente)
    },
    onSettled: () => {
      // Revalidar para asegurar consistencia
      queryClient.invalidateQueries({ queryKey: clientesKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: clientesKeys.zonas(currentSucursalId) })
    },
  })
}

/**
 * Hook para eliminar (desactivar) un cliente
 */
export function useEliminarClienteMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: deleteCliente,
    onSuccess: (_, deletedId) => {
      // Remover de cache de detalle
      queryClient.removeQueries({ queryKey: clientesKeys.detail(currentSucursalId, deletedId) })
      // Actualizar cache de lista
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(currentSucursalId), (old) => {
        if (!old) return []
        return old.filter(c => c.id !== deletedId)
      })
    },
  })
}
