/**
 * TanStack Query hooks para Marcas (mig 158).
 *
 * La marca es ortogonal a la categoría: un producto tiene una marca (Manaos,
 * La Virginia) Y una categoría (gaseosas, fideos). Hasta la mig 158 ambas
 * cosas convivían mezcladas en `categorias`, lo que hacía imposible pedir
 * "cuánto vendió de gaseosas Manaos".
 *
 * A diferencia de `categorias`, acá no hay columna de texto espejo que
 * mantener: `productos.marca_id` es la única fuente. Renombrar una marca no
 * requiere tocar productos.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'

// =============================================================================
// TYPES
// =============================================================================

export interface MarcaDB {
  id: string
  nombre: string
  sucursal_id: number
  activa: boolean
  created_at: string
  updated_at: string
}

/** Args de la asignación masiva: por categoría entera o por lista de productos. */
export interface AsignarMarcaMasivaArgs {
  /** null quita la marca de los productos seleccionados. */
  marcaId: string | null
  categoriaId?: string | null
  productoIds?: string[]
}

// =============================================================================
// QUERY KEYS
// =============================================================================

export const marcasKeys = {
  all: (sucursalId: number | null) => ['marcas', sucursalId] as const,
  lists: (sucursalId: number | null) => [...marcasKeys.all(sucursalId), 'list'] as const,
}

// =============================================================================
// FETCH
// =============================================================================

async function fetchMarcas(): Promise<MarcaDB[]> {
  const { data, error } = await supabase
    .from('marcas')
    .select('*')
    .order('nombre')

  if (error) throw error
  return (data as MarcaDB[]) || []
}

// =============================================================================
// MUTATIONS
// =============================================================================

async function createMarca(nombre: string, sucursalId: number | null): Promise<MarcaDB> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  const nombreLimpio = nombre.trim()
  if (!nombreLimpio) throw new Error('El nombre de la marca no puede estar vacío')

  const { data, error } = await supabase
    .from('marcas')
    .insert([{ nombre: nombreLimpio, sucursal_id: sucursalId }])
    .select()
    .single()

  if (error) {
    if (error.code === '23505') {
      throw new Error(`Ya existe una marca llamada "${nombreLimpio}"`)
    }
    throw error
  }
  return data as MarcaDB
}

async function renameMarca({ id, nombreNuevo }: { id: string; nombreNuevo: string }): Promise<void> {
  const nuevoLimpio = nombreNuevo.trim()
  if (!nuevoLimpio) throw new Error('El nombre nuevo no puede estar vacío')

  const { error } = await supabase.from('marcas').update({ nombre: nuevoLimpio }).eq('id', id)
  if (error) {
    if (error.code === '23505') {
      throw new Error(`Ya existe una marca llamada "${nuevoLimpio}"`)
    }
    throw error
  }
}

/**
 * Borra la marca. `productos.marca_id` tiene ON DELETE SET NULL, así que los
 * productos quedan sin marca pero no se pierden.
 */
async function deleteMarca(id: string): Promise<void> {
  const { error } = await supabase.from('marcas').delete().eq('id', id)
  if (error) throw error
}

async function toggleMarcaActiva({ id, activa }: { id: string; activa: boolean }): Promise<void> {
  const { error } = await supabase.from('marcas').update({ activa }).eq('id', id)
  if (error) throw error
}

async function asignarMarcaMasiva(args: AsignarMarcaMasivaArgs): Promise<number> {
  const { data, error } = await supabase.rpc('asignar_marca_masiva', {
    p_marca_id: args.marcaId,
    p_categoria_id: args.categoriaId ?? null,
    // Los ids de productos son bigint en la base y string en el front.
    p_producto_ids: args.productoIds?.length ? args.productoIds.map(Number) : null,
  })
  if (error) throw error
  return (data as { actualizados?: number } | null)?.actualizados ?? 0
}

// =============================================================================
// HOOKS
// =============================================================================

export function useMarcasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: marcasKeys.lists(currentSucursalId),
    queryFn: fetchMarcas,
    staleTime: 10 * 60 * 1000,
  })
}

export function useCrearMarcaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (nombre: string) => createMarca(nombre, currentSucursalId),
    onSuccess: (nueva) => {
      queryClient.setQueryData<MarcaDB[]>(marcasKeys.lists(currentSucursalId), (old) => {
        if (!old) return [nueva]
        return [...old, nueva].sort((a, b) => a.nombre.localeCompare(b.nombre))
      })
    },
  })
}

export function useRenombrarMarcaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: renameMarca,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: marcasKeys.lists(currentSucursalId) })
    },
  })
}

export function useEliminarMarcaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: deleteMarca,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: marcasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
    },
  })
}

export function useToggleMarcaActivaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: toggleMarcaActiva,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: marcasKeys.lists(currentSucursalId) })
    },
  })
}

export function useAsignarMarcaMasivaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: asignarMarcaMasiva,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: marcasKeys.lists(currentSucursalId) })
    },
  })
}
