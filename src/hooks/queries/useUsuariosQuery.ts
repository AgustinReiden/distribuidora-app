/**
 * TanStack Query hooks para Usuarios/Perfiles
 * Reemplaza el hook useUsuarios con mejor cache y gestión de estado
 *
 * Multi-tenant (H11): las query keys están scopeadas por sucursalId. Los
 * usuarios visibles dependen de usuario_sucursales vía RLS, así que la
 * misma llamada devuelve distintas filas para distintas sucursales.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { PerfilDB } from '../../types'

// Query keys scoped by sucursalId (multi-tenant). Using function factories so
// every cache entry lives under its own tenant prefix and a sucursal switch
// invalidates cleanly via the `['usuarios', sucursalId]` prefix.
export const usuariosKeys = {
  all: (sucursalId: number | null) => ['usuarios', sucursalId] as const,
  lists: (sucursalId: number | null) => [...usuariosKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) =>
    [...usuariosKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...usuariosKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...usuariosKeys.details(sucursalId), id] as const,
  byRol: (sucursalId: number | null, rol: string) => [...usuariosKeys.all(sucursalId), 'rol', rol] as const,
  transportistas: (sucursalId: number | null) => [...usuariosKeys.all(sucursalId), 'transportistas'] as const,
  preventistas: (sucursalId: number | null) => [...usuariosKeys.all(sucursalId), 'preventistas'] as const,
}

// Types
interface UsuarioUpdateInput {
  nombre?: string
  rol?: string
  zona?: string | null
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
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.lists(currentSucursalId),
    queryFn: fetchUsuarios,
    staleTime: 10 * 60 * 1000, // 10 minutos - usuarios cambian poco
  })
}

/**
 * Hook para obtener un usuario por ID
 */
export function useUsuarioQuery(id: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.detail(currentSucursalId, id),
    queryFn: () => fetchUsuarioById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener usuarios por rol
 */
export function useUsuariosByRolQuery(rol: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.byRol(currentSucursalId, rol),
    queryFn: () => fetchUsuariosByRol(rol),
    enabled: !!rol,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener transportistas activos
 */
export function useTransportistasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.transportistas(currentSucursalId),
    queryFn: fetchTransportistas,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener preventistas activos
 */
export function usePreventistasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.preventistas(currentSucursalId),
    queryFn: fetchPreventistas,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para actualizar un usuario
 */
export function useActualizarUsuarioMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: updateUsuario,
    onSuccess: (updatedUsuario) => {
      // Actualizar cache de detalle
      queryClient.setQueryData(usuariosKeys.detail(currentSucursalId, updatedUsuario.id), updatedUsuario)
      // Actualizar cache de lista
      queryClient.setQueryData<PerfilDB[]>(usuariosKeys.lists(currentSucursalId), (old) => {
        if (!old) return [updatedUsuario]
        return old.map(u => u.id === updatedUsuario.id ? updatedUsuario : u)
      })
      // Invalidar listas por rol
      if (updatedUsuario.rol) {
        queryClient.invalidateQueries({ queryKey: usuariosKeys.byRol(currentSucursalId, updatedUsuario.rol) })
      }
      queryClient.invalidateQueries({ queryKey: usuariosKeys.transportistas(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: usuariosKeys.preventistas(currentSucursalId) })
    },
  })
}

/**
 * Hook para activar/desactivar un usuario
 */
export function useToggleUsuarioActivoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) => toggleUsuarioActivo(id, activo),
    onSuccess: (updatedUsuario) => {
      queryClient.setQueryData(usuariosKeys.detail(currentSucursalId, updatedUsuario.id), updatedUsuario)
      queryClient.setQueryData<PerfilDB[]>(usuariosKeys.lists(currentSucursalId), (old) => {
        if (!old) return [updatedUsuario]
        return old.map(u => u.id === updatedUsuario.id ? updatedUsuario : u)
      })
      queryClient.invalidateQueries({ queryKey: usuariosKeys.transportistas(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: usuariosKeys.preventistas(currentSucursalId) })
    },
  })
}
