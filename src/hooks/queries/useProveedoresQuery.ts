/**
 * TanStack Query hooks para Proveedores
 * Maneja operaciones CRUD de proveedores con cache optimizado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { ProveedorDBExtended, ProveedorFormInputExtended } from '../../types'

// Query keys
export const proveedoresKeys = {
  all: ['proveedores'] as const,
  lists: () => [...proveedoresKeys.all, 'list'] as const,
  list: (filters: Record<string, unknown>) => [...proveedoresKeys.lists(), filters] as const,
  details: () => [...proveedoresKeys.all, 'detail'] as const,
  detail: (id: string) => [...proveedoresKeys.details(), id] as const,
  activos: () => [...proveedoresKeys.all, 'activos'] as const,
}

// Fetch functions
async function fetchProveedores(): Promise<ProveedorDBExtended[]> {
  const { data, error } = await supabase
    .from('proveedores')
    .select('*')
    .order('nombre')

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
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
    throw error
  }
  return (data || []) as ProveedorDBExtended[]
}

async function fetchProveedorById(id: string): Promise<ProveedorDBExtended | null> {
  const { data, error } = await supabase
    .from('proveedores')
    .select('*')
    .eq('id', id)
    .single()

  if (error) throw error
  return data as ProveedorDBExtended
}

// Mutation functions
async function createProveedor(proveedor: ProveedorFormInputExtended): Promise<ProveedorDBExtended> {
  // Validar CUIT duplicado
  if (proveedor.cuit) {
    const cuitLimpio = proveedor.cuit.replace(/[-\s]/g, '')
    const { data: existente } = await supabase
      .from('proveedores')
      .select('id, nombre')
      .eq('cuit', proveedor.cuit)
      .limit(1)
      .maybeSingle()
    if (!existente && cuitLimpio !== proveedor.cuit) {
      // Buscar también sin guiones
      const { data: existente2 } = await supabase
        .from('proveedores')
        .select('id, nombre, cuit')
        .not('cuit', 'is', null)
        .limit(100)
      const match = existente2?.find(p => p.cuit?.replace(/[-\s]/g, '') === cuitLimpio)
      if (match) {
        throw new Error(`Ya existe un proveedor con CUIT "${proveedor.cuit}": ${match.nombre}`)
      }
    } else if (existente) {
      throw new Error(`Ya existe un proveedor con CUIT "${proveedor.cuit}": ${existente.nombre}`)
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
      activo: true
    }])
    .select()
    .single()

  if (error) throw error
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
      activo: proveedor.activo !== undefined ? proveedor.activo : true
    })
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data as ProveedorDBExtended
}

async function toggleProveedorActivo(id: string, activo: boolean): Promise<ProveedorDBExtended> {
  const { data, error } = await supabase
    .from('proveedores')
    .update({ activo })
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data as ProveedorDBExtended
}

// Hooks

/**
 * Hook para obtener todos los proveedores
 */
export function useProveedoresQuery() {
  return useQuery({
    queryKey: proveedoresKeys.lists(),
    queryFn: fetchProveedores,
    staleTime: 10 * 60 * 1000, // 10 minutos - proveedores cambian poco
  })
}

/**
 * Hook para obtener solo proveedores activos
 */
export function useProveedoresActivosQuery() {
  return useQuery({
    queryKey: proveedoresKeys.activos(),
    queryFn: fetchProveedoresActivos,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener un proveedor por ID
 */
export function useProveedorQuery(id: string) {
  return useQuery({
    queryKey: proveedoresKeys.detail(id),
    queryFn: () => fetchProveedorById(id),
    enabled: !!id,
  })
}

/**
 * Hook para crear un proveedor
 */
export function useCrearProveedorMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createProveedor,
    onSuccess: (newProveedor) => {
      // Actualizar cache de lista
      queryClient.setQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(), (old) => {
        if (!old) return [newProveedor]
        return [...old, newProveedor].sort((a, b) => a.nombre.localeCompare(b.nombre))
      })
      // Invalidar activos también
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.activos() })
    },
  })
}

/**
 * Hook para actualizar un proveedor (con optimistic update)
 */
export function useActualizarProveedorMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateProveedor,
    // Optimistic update
    onMutate: async ({ id, data: proveedor }) => {
      await queryClient.cancelQueries({ queryKey: proveedoresKeys.lists() })

      const previousProveedores = queryClient.getQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists())

      // Aplicar cambios optimistamente
      queryClient.setQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(), (old) => {
        if (!old) return old
        return old.map(p => p.id === id ? { ...p, ...proveedor } as ProveedorDBExtended : p)
      })

      return { previousProveedores }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousProveedores) {
        queryClient.setQueryData(proveedoresKeys.lists(), context.previousProveedores)
      }
    },
    onSuccess: (updatedProveedor) => {
      // Actualizar cache de detalle
      queryClient.setQueryData(proveedoresKeys.detail(updatedProveedor.id), updatedProveedor)
    },
    onSettled: () => {
      // Revalidar para asegurar consistencia
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.lists() })
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.activos() })
    },
  })
}

/**
 * Hook para activar/desactivar un proveedor
 */
export function useToggleProveedorActivoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) =>
      toggleProveedorActivo(id, activo),
    // Optimistic update
    onMutate: async ({ id, activo }) => {
      await queryClient.cancelQueries({ queryKey: proveedoresKeys.lists() })

      const previousProveedores = queryClient.getQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists())

      queryClient.setQueryData<ProveedorDBExtended[]>(proveedoresKeys.lists(), (old) => {
        if (!old) return old
        return old.map(p => p.id === id ? { ...p, activo } : p)
      })

      return { previousProveedores }
    },
    onError: (_, __, context) => {
      if (context?.previousProveedores) {
        queryClient.setQueryData(proveedoresKeys.lists(), context.previousProveedores)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.lists() })
      queryClient.invalidateQueries({ queryKey: proveedoresKeys.activos() })
    },
  })
}
