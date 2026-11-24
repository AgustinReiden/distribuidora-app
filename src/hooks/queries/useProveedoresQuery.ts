/**
 * TanStack Query hooks para Proveedores
 * Maneja operaciones CRUD de proveedores con cache optimizado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { ProveedorDBExtended, ProveedorFormInputExtended } from '../../types'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorCuitDuplicado, esCuitDuplicadoDeBase, mismoCuit, patronCuit } from '../../utils/cuitProveedor'

// Query keys
export const proveedoresKeys = {
  all: (sucursalId: number | null) => ['proveedores', sucursalId] as const,
  lists: (sucursalId: number | null) => [...proveedoresKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...proveedoresKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...proveedoresKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...proveedoresKeys.details(sucursalId), id] as const,
  activos: (sucursalId: number | null) => [...proveedoresKeys.all(sucursalId), 'activos'] as const,
}

// Fetch functions
async function fetchProveedores(): Promise<ProveedorDBExtended[]> {
  const { data, error } = await supabase
    .from('proveedores')
    .select('*')
    .order('nombre')

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar los proveedores. Revisá la señal e intentá de nuevo.')
  }
  return (data || []) as ProveedorDBExtended[]
}

async function fetchProveedoresActivos(): Promise<ProveedorDBExtended[]> {
  const { data, error } = await supabase
    .from('proveedores')
    .select('*')
    .eq('activo', true)
    .order('nombre')

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar los proveedores. Revisá la señal e intentá de nuevo.')
  }
  return (data || []) as ProveedorDBExtended[]
}

async function fetchProveedorById(id: string): Promise<ProveedorDBExtended | null> {
  const { data, error } = await supabase
    .from('proveedores')
    .select('*')
    .eq('id', id)
    .single()

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el proveedor. Revisá la señal e intentá de nuevo.')
  return data as ProveedorDBExtended
}

// Mutation functions
async function createProveedor(proveedor: ProveedorFormInputExtended, sucursalId: number | null): Promise<ProveedorDBExtended> {
  // La RLS multi-tenant requiere sucursal_id = current_sucursal_id() y la
  // columna es NOT NULL. Sin esto el INSERT falla.
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  // Validar CUIT duplicado: único por sucursal y comparado sin guiones (1557-b10,
  // decisión del dueño). La base achica con un patrón que acierta cualquier
  // separador entre los dígitos; el que decide es `mismoCuit`.
  const patron = patronCuit(proveedor.cuit)
  if (patron) {
    const { data: candidatos, error: errorBusqueda } = await supabase
      .from('proveedores')
      .select('id, nombre, cuit')
      .eq('sucursal_id', sucursalId)
      .ilike('cuit', patron)
    if (errorBusqueda) throw errorDeSupabase(errorBusqueda, 'Sin conexión: no se pudo verificar si el CUIT ya está cargado. Revisá la señal e intentá de nuevo.')
    const existente = (candidatos ?? []).find(p => mismoCuit(p.cuit, proveedor.cuit))
    if (existente) {
      throw errorCuitDuplicado(proveedor.cuit, existente.nombre)
    }
  }

  const { data, error } = await supabase
    .from('proveedores')
    .insert([{
      nombre: proveedor.nombre,
      cuit: proveedor.cuit || null,
      direccion: proveedor.direccion || null,
      latitud: proveedor.latitud || null,
      longitud: proveedor.longitud || null,
      telefono: proveedor.telefono || null,
      email: proveedor.email || null,
      contacto: proveedor.contacto || null,
      notas: proveedor.notas || null,
      activo: true,
      sucursal_id: sucursalId
    }])
    .select()
    .single()

  // El índice único del server cubre la carrera que la verificación de arriba no ve.
  if (error && esCuitDuplicadoDeBase(error)) throw errorCuitDuplicado(proveedor.cuit)
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el alta del proveedor. Revisá la lista antes de reintentar.')
  return data as ProveedorDBExtended
}

async function updateProveedor({ id, data: proveedor }: { id: string; data: ProveedorFormInputExtended }): Promise<ProveedorDBExtended> {
  const { data, error } = await supabase
    .from('proveedores')
    .update({
      nombre: proveedor.nombre,
      cuit: proveedor.cuit || null,
      direccion: proveedor.direccion || null,
      latitud: proveedor.latitud || null,
      longitud: proveedor.longitud || null,
      telefono: proveedor.telefono || null,
      email: proveedor.email || null,
      contacto: proveedor.contacto || null,
      notas: proveedor.notas || null,
      // `activo` no se manda (gestion-B4): lo cambia sólo `toggleProveedorActivo`. El formulario
      // lo trae de la copia de la lista, y si otro admin desactivó al proveedor mientras se
      // editaba, guardar lo reactivaba sin que nadie lo pidiera.
    })
    .eq('id', id)
    .select()
    .single()

  // Ponerle a un proveedor el CUIT de otro: lo frena el índice único del server.
  if (error && esCuitDuplicadoDeBase(error)) throw errorCuitDuplicado(proveedor.cuit)
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la edición del proveedor. Revisá sus datos antes de reintentar.')
  return data as ProveedorDBExtended
}

async function toggleProveedorActivo(id: string, activo: boolean): Promise<ProveedorDBExtended> {
  const { data, error } = await supabase
    .from('proveedores')
    .update({ activo })
    .eq('id', id)
    .select()
    .single()

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el cambio de estado del proveedor. Revisá la lista antes de reintentar.')
  return data as ProveedorDBExtended
}

interface EliminarProveedorResult {
  success: boolean
  nombre?: string
  error?: string
}

async function deleteProveedor(id: string): Promise<void> {
  const { data, error } = await supabase.rpc('eliminar_proveedor', {
    p_proveedor_id: parseInt(id, 10)
  })

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la eliminación del proveedor. Revisá la lista antes de reintentar.')

  const result = data as EliminarProveedorResult
  if (!result.success) {
    throw new Error(result.error || 'Error al eliminar proveedor')
  }
}

// Hooks

/**
 * Hook para obtener todos los proveedores
 */
export function useProveedoresQuery() {
  const { currentSucursalId } = useSucursal()

  return useQuery({
    queryKey: proveedoresKeys.lists(currentSucursalId),
    queryFn: fetchProveedores,
    staleTime: 10 * 60 * 1000, // 10 minutos - proveedores cambian poco
  })
}

/**
 * Hook para obtener solo proveedores activos
 */
export function useProveedoresActivosQuery() {
  const { currentSucursalId } = useSucursal()

  return useQuery({
    queryKey: proveedoresKeys.activos(currentSucursalId),
    queryFn: fetchProveedoresActivos,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener un proveedor por ID
 */
export function useProveedorQuery(id: string) {
  const { currentSucursalId } = useSucursal()

  return useQuery({
    queryKey: proveedoresKeys.detail(currentSucursalId, id),
    queryFn: () => fetchProveedorById(id),
    enabled: !!id,
  })
}

/**
 * Hook para crear un proveedor
 */
export function useCrearProveedorMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (proveedor: ProveedorFormInputExtended) => createProveedor(proveedor, currentSucursalId),
    onSuccess: (newProveedor) => {
      // Actualizar cache de lista
      // Sin lista en caché (la consulta había fallado) no se siembra una de una sola fila:
      // quedaba «fresca» 10 minutos y el selector mostraba un solo proveedor (gestion-B3).
      if (queryClient.getQueryData(proveedoresKeys.lists(currentSucursalId)) === undefined) {
        queryClient.invalidateQueries({ queryKey: proveedoresKeys.lists(currentSucursalId) })
      } else {
        queryClient.setQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(currentSucursalId), (old) => {
          if (!old) return old
          return [...old, newProveedor].sort((a, b) => a.nombre.localeCompare(b.nombre))
        })
      }
      // Invalidar activos también
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.activos(currentSucursalId) })
    },
  })
}

/**
 * Hook para actualizar un proveedor (con optimistic update)
 */
export function useActualizarProveedorMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: updateProveedor,
    // Optimistic update
    onMutate: async ({ id, data: proveedor }) => {
      await queryClient.cancelQueries({ queryKey: proveedoresKeys.lists(currentSucursalId) })

      const previousProveedores = queryClient.getQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(currentSucursalId))

      // Aplicar cambios optimistamente
      // Sin `activo`: el estado no lo cambia esta edición (gestion-B4).
      const { activo: _activo, ...cambios } = proveedor
      queryClient.setQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.map(p => p.id === id ? { ...p, ...cambios } as ProveedorDBExtended : p)
      })

      return { previousProveedores }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousProveedores) {
        queryClient.setQueryData(proveedoresKeys.lists(currentSucursalId), context.previousProveedores)
      }
    },
    onSuccess: (updatedProveedor) => {
      // Actualizar cache de detalle
      queryClient.setQueryData(proveedoresKeys.detail(currentSucursalId, updatedProveedor.id), updatedProveedor)
    },
    onSettled: () => {
      // Revalidar para asegurar consistencia
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.activos(currentSucursalId) })
    },
  })
}

/**
 * Hook para activar/desactivar un proveedor
 */
export function useToggleProveedorActivoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) =>
      toggleProveedorActivo(id, activo),
    // Optimistic update
    onMutate: async ({ id, activo }) => {
      await queryClient.cancelQueries({ queryKey: proveedoresKeys.lists(currentSucursalId) })

      const previousProveedores = queryClient.getQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(currentSucursalId))

      queryClient.setQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.map(p => p.id === id ? { ...p, activo } : p)
      })

      return { previousProveedores }
    },
    onError: (_, __, context) => {
      if (context?.previousProveedores) {
        queryClient.setQueryData(proveedoresKeys.lists(currentSucursalId), context.previousProveedores)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.activos(currentSucursalId) })
    },
  })
}

/**
 * Hook para eliminar un proveedor permanentemente (con auditoría)
 */
export function useEliminarProveedorMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: deleteProveedor,
    onMutate: async (id: string) => {
      await queryClient.cancelQueries({ queryKey: proveedoresKeys.lists(currentSucursalId) })
      const previousProveedores = queryClient.getQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(currentSucursalId))
      queryClient.setQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.filter(p => p.id !== id)
      })
      return { previousProveedores }
    },
    onError: (_, __, context) => {
      if (context?.previousProveedores) {
        queryClient.setQueryData(proveedoresKeys.lists(currentSucursalId), context.previousProveedores)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.activos(currentSucursalId) })
    },
  })
}
