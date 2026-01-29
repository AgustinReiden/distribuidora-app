/**
 * TanStack Query hooks para Usuarios/Perfiles
 * Reemplaza el hook useUsuarios con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { PerfilDB } from '../../types'

// Query keys
export const usuariosKeys = {
  all: ['usuarios'] as const,
  lists: () => [...usuariosKeys.all, 'list'] as const,
  list: (filters: Record<string, unknown>) => [...usuariosKeys.lists(), filters] as const,
  details: () => [...usuariosKeys.all, 'detail'] as const,
  detail: (id: string) => [...usuariosKeys.details(), id] as const,
  byRol: (rol: string) => [...usuariosKeys.all, 'rol', rol] as const,
  transportistas: () => [...usuariosKeys.all, 'transportistas'] as const,
  preventistas: () => [...usuariosKeys.all, 'preventistas'] as const,
}

// Types
interface UsuarioUpdateInput {
  nombre?: string
  rol?: string
  zona?: string
  activo?: boolean
}

// Fetch functions
async function fetchUsuarios(): Promise<PerfilDB[]> {
  const { data, error } = await supabase
    .from('perfiles')
    .select('*')
    .order('nombre')

  if (error) throw error
  return (data as PerfilDB[]) || []
}

async function fetchUsuarioById(id: string): Promise<PerfilDB | null> {
  const { data, error } = await supabase
    .from('perfiles')
    .select('*')
    .eq('id', id)
    .single()

  if (error) throw error
  return data as PerfilDB
}

async function fetchUsuariosByRol(rol: string): Promise<PerfilDB[]> {
  const { data, error } = await supabase
    .from('perfiles')
    .select('*')
    .eq('rol', rol)
    .eq('activo', true)
    .order('nombre')

  if (error) throw error
  return (data as PerfilDB[]) || []
}

async function fetchTransportistas(): Promise<PerfilDB[]> {
  const { data, error } = await supabase
    .from('perfiles')
    .select('*')
    .eq('rol', 'transportista')
    .eq('activo', true)
    .order('nombre')

  if (error) throw error
  return (data as PerfilDB[]) || []
}

async function fetchPreventistas(): Promise<PerfilDB[]> {
  const { data, error } = await supabase
    .from('perfiles')
    .select('*')
    .eq('rol', 'preventista')
    .eq('activo', true)
    .order('nombre')

  if (error) throw error
  return (data as PerfilDB[]) || []
}

// Mutation functions
async function updateUsuario({ id, data: usuario }: { id: string; data: UsuarioUpdateInput }): Promise<PerfilDB> {
  const { data, error } = await supabase
    .from('perfiles')
    .update(usuario)
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data as PerfilDB
}

async function toggleUsuarioActivo(id: string, activo: boolean): Promise<PerfilDB> {
  const { data, error } = await supabase
    .from('perfiles')
    .update({ activo })
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data as PerfilDB
}

// Hooks

/**
 * Hook para obtener todos los usuarios
 */
export function useUsuariosQuery() {
  return useQuery({
    queryKey: usuariosKeys.lists(),
    queryFn: fetchUsuarios,
    staleTime: 10 * 60 * 1000, // 10 minutos - usuarios cambian poco
  })
}

/**
 * Hook para obtener un usuario por ID
 */
export function useUsuarioQuery(id: string) {
  return useQuery({
    queryKey: usuariosKeys.detail(id),
    queryFn: () => fetchUsuarioById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener usuarios por rol
 */
export function useUsuariosByRolQuery(rol: string) {
  return useQuery({
    queryKey: usuariosKeys.byRol(rol),
    queryFn: () => fetchUsuariosByRol(rol),
    enabled: !!rol,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener transportistas activos
 */
export function useTransportistasQuery() {
  return useQuery({
    queryKey: usuariosKeys.transportistas(),
    queryFn: fetchTransportistas,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener preventistas activos
 */
export function usePreventistasQuery() {
  return useQuery({
    queryKey: usuariosKeys.preventistas(),
    queryFn: fetchPreventistas,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para actualizar un usuario
 */
export function useActualizarUsuarioMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateUsuario,
    onSuccess: (updatedUsuario) => {
      // Actualizar cache de detalle
      queryClient.setQueryData(usuariosKeys.detail(updatedUsuario.id), updatedUsuario)
      // Actualizar cache de lista
      queryClient.setQueryData<PerfilDB[]>(usuariosKeys.lists(), (old) => {
        if (!old) return [updatedUsuario]
        return old.map(u => u.id === updatedUsuario.id ? updatedUsuario : u)
      })
      // Invalidar listas por rol
      if (updatedUsuario.rol) {
        queryClient.invalidateQueries({ queryKey: usuariosKeys.byRol(updatedUsuario.rol) })
      }
      queryClient.invalidateQueries({ queryKey: usuariosKeys.transportistas() })
      queryClient.invalidateQueries({ queryKey: usuariosKeys.preventistas() })
    },
  })
}

/**
 * Hook para activar/desactivar un usuario
 */
export function useToggleUsuarioActivoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) => toggleUsuarioActivo(id, activo),
    onSuccess: (updatedUsuario) => {
      queryClient.setQueryData(usuariosKeys.detail(updatedUsuario.id), updatedUsuario)
      queryClient.setQueryData<PerfilDB[]>(usuariosKeys.lists(), (old) => {
        if (!old) return [updatedUsuario]
        return old.map(u => u.id === updatedUsuario.id ? updatedUsuario : u)
      })
      queryClient.invalidateQueries({ queryKey: usuariosKeys.transportistas() })
      queryClient.invalidateQueries({ queryKey: usuariosKeys.preventistas() })
    },
  })
}
