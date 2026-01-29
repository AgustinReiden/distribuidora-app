/**
 * TanStack Query hooks para Clientes
 * Reemplaza el hook useClientes con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { ClienteDB } from '../../types'

// Query keys
export const clientesKeys = {
  all: ['clientes'] as const,
  lists: () => [...clientesKeys.all, 'list'] as const,
  list: (filters: Record<string, unknown>) => [...clientesKeys.lists(), filters] as const,
  details: () => [...clientesKeys.all, 'detail'] as const,
  detail: (id: string) => [...clientesKeys.details(), id] as const,
  byZona: (zona: string) => [...clientesKeys.all, 'zona', zona] as const,
  zonas: () => [...clientesKeys.all, 'zonas'] as const,
}

// Fetch functions
async function fetchClientes(): Promise<ClienteDB[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('*')
    .eq('activo', true)
    .order('nombre_fantasia')

  if (error) throw error
  return (data as ClienteDB[]) || []
}

async function fetchClienteById(id: string): Promise<ClienteDB | null> {
  const { data, error } = await supabase
    .from('clientes')
    .select('*')
    .eq('id', id)
    .single()

  if (error) throw error
  return data as ClienteDB
}

async function fetchClientesByZona(zona: string): Promise<ClienteDB[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('*')
    .eq('activo', true)
    .eq('zona', zona)
    .order('nombre_fantasia')

  if (error) throw error
  return (data as ClienteDB[]) || []
}

async function fetchZonasUnicas(): Promise<string[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('zona')
    .eq('activo', true)
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
}

// Mutation functions
async function createCliente(cliente: ClienteCreateInput): Promise<ClienteDB> {
  const { data, error } = await supabase
    .from('clientes')
    .insert([{
      razon_social: cliente.razon_social,
      nombre_fantasia: cliente.nombre_fantasia,
      direccion: cliente.direccion,
      telefono: cliente.telefono || null,
      cuit: cliente.cuit || null,
      zona: cliente.zona || null,
      latitud: cliente.latitud || null,
      longitud: cliente.longitud || null,
      limite_credito: cliente.limite_credito || 0,
      dias_credito: cliente.dias_credito || 30,
      contacto: cliente.contacto || null,
      horarios_atencion: cliente.horarios_atencion || null,
      rubro: cliente.rubro || null,
      notas: cliente.notas || null,
      activo: true
    }])
    .select()
    .single()

  if (error) throw error
  return data as ClienteDB
}

async function updateCliente({ id, data: cliente }: { id: string; data: Partial<ClienteCreateInput> }): Promise<ClienteDB> {
  const { data, error } = await supabase
    .from('clientes')
    .update(cliente)
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data as ClienteDB
}

async function deleteCliente(id: string): Promise<void> {
  // Soft delete - marcar como inactivo
  const { error } = await supabase
    .from('clientes')
    .update({ activo: false })
    .eq('id', id)

  if (error) throw error
}

// Hooks

/**
 * Hook para obtener todos los clientes activos
 */
export function useClientesQuery() {
  return useQuery({
    queryKey: clientesKeys.lists(),
    queryFn: fetchClientes,
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para obtener un cliente por ID
 */
export function useClienteQuery(id: string) {
  return useQuery({
    queryKey: clientesKeys.detail(id),
    queryFn: () => fetchClienteById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener clientes por zona
 */
export function useClientesByZonaQuery(zona: string) {
  return useQuery({
    queryKey: clientesKeys.byZona(zona),
    queryFn: () => fetchClientesByZona(zona),
    enabled: !!zona,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener zonas únicas
 */
export function useZonasQuery() {
  return useQuery({
    queryKey: clientesKeys.zonas(),
    queryFn: fetchZonasUnicas,
    staleTime: 10 * 60 * 1000, // 10 minutos - zonas cambian poco
  })
}

/**
 * Hook para crear un cliente
 */
export function useCrearClienteMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createCliente,
    onSuccess: (newCliente) => {
      // Actualizar cache de lista
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(), (old) => {
        if (!old) return [newCliente]
        return [...old, newCliente].sort((a, b) =>
          (a.nombre_fantasia || '').localeCompare(b.nombre_fantasia || '')
        )
      })
      // Invalidar zonas por si es una nueva zona
      queryClient.invalidateQueries({ queryKey: clientesKeys.zonas() })
      // Invalidar clientes por zona si aplica
      if (newCliente.zona) {
        queryClient.invalidateQueries({ queryKey: clientesKeys.byZona(newCliente.zona) })
      }
    },
  })
}

/**
 * Hook para actualizar un cliente
 */
export function useActualizarClienteMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateCliente,
    onSuccess: (updatedCliente) => {
      // Actualizar cache de detalle
      queryClient.setQueryData(clientesKeys.detail(updatedCliente.id), updatedCliente)
      // Actualizar cache de lista
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(), (old) => {
        if (!old) return [updatedCliente]
        return old.map(c => c.id === updatedCliente.id ? updatedCliente : c)
      })
      // Invalidar zonas
      queryClient.invalidateQueries({ queryKey: clientesKeys.zonas() })
    },
  })
}

/**
 * Hook para eliminar (desactivar) un cliente
 */
export function useEliminarClienteMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: deleteCliente,
    onSuccess: (_, deletedId) => {
      // Remover de cache de detalle
      queryClient.removeQueries({ queryKey: clientesKeys.detail(deletedId) })
      // Actualizar cache de lista
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(), (old) => {
        if (!old) return []
        return old.filter(c => c.id !== deletedId)
      })
    },
  })
}
