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
  preventistasAsignables: (sucursalId: number | null) => [...usuariosKeys.all(sucursalId), 'preventistasAsignables'] as const,
  rolesExtra: (sucursalId: number | null, id: string) =>
    [...usuariosKeys.all(sucursalId), 'rolesExtra', id] as const,
}

// Types
interface UsuarioUpdateInput {
  nombre?: string
  rol?: string
  zona?: string | null
  activo?: boolean
}

// Fetch functions
//
// Multi-tenant: filtramos perfiles por sucursal activa via inner join con
// usuario_sucursales. Un preventista/encargado/etc. solo debe ser visible en
// la(s) sucursal(es) donde fue asignado. Requiere policy RLS
// `usuario_sucursales_select_sucursal_activa` (migración 007) para que el
// join sea visible a admin/encargado.
async function fetchUsuarios(sucursalId: number | null): Promise<PerfilDB[]> {
  if (!sucursalId) return []
  const { data, error } = await supabase
    .from('perfiles')
    .select('*, usuario_sucursales!inner(sucursal_id)')
    .eq('usuario_sucursales.sucursal_id', sucursalId)
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

async function fetchUsuariosByRol(sucursalId: number | null, rol: string): Promise<PerfilDB[]> {
  if (!sucursalId) return []
  const { data, error } = await supabase
    .from('perfiles')
    .select('*, usuario_sucursales!inner(sucursal_id)')
    .eq('rol', rol)
    .eq('activo', true)
    .eq('usuario_sucursales.sucursal_id', sucursalId)
    .order('nombre')

  if (error) throw error
  return (data as PerfilDB[]) || []
}

// Quien puede recibir la ruta del dia: el rol primario `transportista` MAS
// quien tenga esa capacidad extra en la sucursal (perfil_roles, mig 155) — el
// preventista que acompaña al camion. Por eso no se puede filtrar con
// .eq('rol', 'transportista'): traemos los activos de la sucursal (son pocos,
// menos de 15 por sucursal) y resolvemos el rol efectivo en memoria.
async function fetchTransportistas(sucursalId: number | null): Promise<PerfilDB[]> {
  if (!sucursalId) return []
  const { data, error } = await supabase
    .from('perfiles')
    .select('*, usuario_sucursales!inner(sucursal_id), perfil_roles(rol, sucursal_id)')
    .eq('activo', true)
    .eq('usuario_sucursales.sucursal_id', sucursalId)
    .order('nombre')

  if (error) throw error

  type ConRolesExtra = PerfilDB & { perfil_roles?: Array<{ rol: string; sucursal_id: number }> }
  return ((data ?? []) as ConRolesExtra[]).filter(p =>
    p.rol === 'transportista'
    || (p.perfil_roles ?? []).some(r => r.rol === 'transportista' && r.sucursal_id === sucursalId)
  )
}

// Roles extra de un usuario en la sucursal activa (mig 155).
async function fetchPerfilRoles(usuarioId: string, sucursalId: number): Promise<string[]> {
  const { data, error } = await supabase
    .from('perfil_roles')
    .select('rol')
    .eq('usuario_id', usuarioId)
    .eq('sucursal_id', sucursalId)

  if (error) throw error
  return ((data ?? []) as Array<{ rol: string }>).map(r => r.rol)
}

// Reemplaza el set completo de roles extra del usuario EN ESA SUCURSAL.
// Delete + insert como en asignarZonasPreventista: son 0..1 filas por usuario,
// no vale la pena diferenciar altas de bajas.
async function asignarPerfilRoles(
  usuarioId: string,
  sucursalId: number,
  roles: string[],
): Promise<void> {
  const { error: errorDelete } = await supabase
    .from('perfil_roles')
    .delete()
    .eq('usuario_id', usuarioId)
    .eq('sucursal_id', sucursalId)

  if (errorDelete) throw errorDelete
  if (roles.length === 0) return

  const { error } = await supabase
    .from('perfil_roles')
    .insert(roles.map(rol => ({ usuario_id: usuarioId, sucursal_id: sucursalId, rol })))

  if (error) throw error
}

async function fetchPreventistas(sucursalId: number | null): Promise<PerfilDB[]> {
  if (!sucursalId) return []
  const { data, error } = await supabase
    .from('perfiles')
    .select('*, usuario_sucursales!inner(sucursal_id)')
    .eq('rol', 'preventista')
    .eq('activo', true)
    .eq('usuario_sucursales.sucursal_id', sucursalId)
    .order('nombre')

  if (error) throw error
  return (data as PerfilDB[]) || []
}

// Lista de usuarios que pueden ser asignados como preventista de un pedido:
// admin + preventista. Usada por admin para asignar quien "tomo" el pedido
// (etiquetas, estadisticas, comisiones).
async function fetchPreventistasAsignables(sucursalId: number | null): Promise<PerfilDB[]> {
  if (!sucursalId) return []
  const { data, error } = await supabase
    .from('perfiles')
    .select('*, usuario_sucursales!inner(sucursal_id)')
    .in('rol', ['admin', 'preventista'])
    .eq('activo', true)
    .eq('usuario_sucursales.sucursal_id', sucursalId)
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
    queryFn: () => fetchUsuarios(currentSucursalId),
    enabled: !!currentSucursalId,
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
    queryFn: () => fetchUsuariosByRol(currentSucursalId, rol),
    enabled: !!rol && !!currentSucursalId,
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
    queryFn: () => fetchTransportistas(currentSucursalId),
    enabled: !!currentSucursalId,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Roles extra del usuario en la sucursal activa (mig 155). Solo admin/encargado
 * ven los de otros; cualquiera ve los propios.
 */
export function usePerfilRolesQuery(usuarioId: string | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.rolesExtra(currentSucursalId, usuarioId || ''),
    queryFn: () => fetchPerfilRoles(usuarioId!, currentSucursalId!),
    enabled: !!usuarioId && !!currentSucursalId,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Reemplaza los roles extra del usuario en la sucursal activa. Solo admin
 * (lo hace cumplir la policy perfil_roles_write_admin).
 */
export function useAsignarPerfilRolesMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ usuarioId, roles }: { usuarioId: string; roles: string[] }) => {
      if (!currentSucursalId) {
        return Promise.reject(new Error('No hay sucursal activa'))
      }
      return asignarPerfilRoles(usuarioId, currentSucursalId, roles)
    },
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({
        queryKey: usuariosKeys.rolesExtra(currentSucursalId, variables.usuarioId),
      })
      // El picker de "quien lleva la ruta" tiene staleTime de 10 min: sin esta
      // invalidacion, quien arma la ruta no veria al usuario recien habilitado.
      queryClient.invalidateQueries({
        queryKey: usuariosKeys.transportistas(currentSucursalId),
      })
    },
  })
}

/**
 * Hook para obtener preventistas activos
 */
export function usePreventistasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.preventistas(currentSucursalId),
    queryFn: () => fetchPreventistas(currentSucursalId),
    enabled: !!currentSucursalId,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener todos los usuarios que pueden ser asignados como
 * preventista de un pedido (admin + preventista activos).
 */
export function usePreventistasAsignablesQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: usuariosKeys.preventistasAsignables(currentSucursalId),
    queryFn: () => fetchPreventistasAsignables(currentSucursalId),
    enabled: !!currentSucursalId,
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
      queryClient.invalidateQueries({ queryKey: usuariosKeys.preventistasAsignables(currentSucursalId) })
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
      queryClient.invalidateQueries({ queryKey: usuariosKeys.preventistasAsignables(currentSucursalId) })
    },
  })
}
