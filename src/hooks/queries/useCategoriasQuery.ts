/**
 * TanStack Query hooks para Categorías.
 *
 * La tabla `categorias` es la fuente de verdad para la gestión manual de
 * categorías (agregar, renombrar, eliminar). El campo `productos.categoria`
 * (string libre) se mantiene para compatibilidad y se actualiza en bloque
 * cuando se renombra o elimina una categoría.
 *
 * Requiere la migración 009_categorias_table.sql aplicada en Supabase.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'

// =============================================================================
// TYPES
// =============================================================================

export interface CategoriaDB {
  id: string
  nombre: string
  sucursal_id: number
  /** Subrubro (mig 276): id del rubro padre. null = es un rubro. Dos niveles como máximo. */
  parent_id?: string | null
  activa: boolean
  created_at: string
  updated_at: string
}

// =============================================================================
// QUERY KEYS
// =============================================================================

export const categoriasKeys = {
  all: (sucursalId: number | null) => ['categorias', sucursalId] as const,
  lists: (sucursalId: number | null) => [...categoriasKeys.all(sucursalId), 'list'] as const,
}

// =============================================================================
// FETCH
// =============================================================================

async function fetchCategorias(): Promise<CategoriaDB[]> {
  const { data, error } = await supabase
    .from('categorias')
    .select('*')
    .order('nombre')

  if (error) throw error
  return (data as CategoriaDB[]) || []
}

// =============================================================================
// MUTATIONS
// =============================================================================

async function createCategoria(nombre: string, sucursalId: number | null): Promise<CategoriaDB> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  const nombreLimpio = nombre.trim()
  if (!nombreLimpio) throw new Error('El nombre de la categoría no puede estar vacío')

  const { data, error } = await supabase
    .from('categorias')
    .insert([{ nombre: nombreLimpio, sucursal_id: sucursalId }])
    .select()
    .single()

  if (error) {
    // Conflict por unique (sucursal_id, nombre)
    if (error.code === '23505') {
      throw new Error(`Ya existe una categoría llamada "${nombreLimpio}"`)
    }
    throw error
  }
  return data as CategoriaDB
}

/**
 * Renombra una categoría y actualiza en bloque todos los productos que usan
 * el nombre viejo. Si la categoría no existe en la tabla (solo deriva de
 * productos) se hace UPSERT.
 */
async function renameCategoria(
  { id, nombreViejo, nombreNuevo, sucursalId }:
  { id: string | null; nombreViejo: string; nombreNuevo: string; sucursalId: number | null }
): Promise<void> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  const nuevoLimpio = nombreNuevo.trim()
  if (!nuevoLimpio) throw new Error('El nombre nuevo no puede estar vacío')
  if (nuevoLimpio === nombreViejo) return

  // 1) Update / upsert en la tabla de categorías
  if (id) {
    const { error: updateErr } = await supabase
      .from('categorias')
      .update({ nombre: nuevoLimpio })
      .eq('id', id)
    if (updateErr) {
      if (updateErr.code === '23505') {
        throw new Error(`Ya existe una categoría llamada "${nuevoLimpio}"`)
      }
      throw updateErr
    }
  } else {
    // Categoría solo derivada: insertarla con el nombre nuevo
    const { error: insertErr } = await supabase
      .from('categorias')
      .insert([{ nombre: nuevoLimpio, sucursal_id: sucursalId }])
    if (insertErr && insertErr.code !== '23505') throw insertErr
  }

  // 2) Bulk update de productos que usan el nombre viejo
  const { error: bulkErr } = await supabase
    .from('productos')
    .update({ categoria: nuevoLimpio })
    .eq('categoria', nombreViejo)
  if (bulkErr) throw bulkErr
}

/**
 * Elimina una categoría de la tabla y deja `productos.categoria = NULL` para
 * todos los productos que la usaban (no se borran los productos).
 */
async function deleteCategoria(
  { id, nombre }: { id: string | null; nombre: string }
): Promise<void> {
  // 1) Borrar de la tabla (si existe)
  if (id) {
    const { error: delErr } = await supabase
      .from('categorias')
      .delete()
      .eq('id', id)
    if (delErr) throw delErr
  }

  // 2) Dejar sin categoría a los productos afectados
  const { error: bulkErr } = await supabase
    .from('productos')
    .update({ categoria: null })
    .eq('categoria', nombre)
  if (bulkErr) throw bulkErr
}

// =============================================================================
// HOOKS
// =============================================================================

// Un solo fetch y una sola caché para rubros y subrubros. `useCategoriasQuery`
// devuelve SOLO los rubros (parent_id NULL): todos los consumidores previos a la
// mig 276 siguen viendo lo mismo. Los subrubros salen por `useSubcategoriasQuery`.
const soloRubros = (todas: CategoriaDB[]) => todas.filter(c => !c.parent_id)
const soloSubrubros = (todas: CategoriaDB[]) => todas.filter(c => !!c.parent_id)

export function useCategoriasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: categoriasKeys.lists(currentSucursalId),
    queryFn: fetchCategorias,
    staleTime: 10 * 60 * 1000,
    select: soloRubros,
  })
}

/** Subrubros (categorías con `parent_id`) de la sucursal activa. */
export function useSubcategoriasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: categoriasKeys.lists(currentSucursalId),
    queryFn: fetchCategorias,
    staleTime: 10 * 60 * 1000,
    select: soloSubrubros,
  })
}

async function createSubcategoria(
  { nombre, parentId }: { nombre: string; parentId: string },
  sucursalId: number | null,
): Promise<CategoriaDB> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }
  const nombreLimpio = nombre.trim()
  if (!nombreLimpio) throw new Error('El nombre del subrubro no puede estar vacío')

  const { data, error } = await supabase
    .from('categorias')
    .insert([{ nombre: nombreLimpio, sucursal_id: sucursalId, parent_id: parentId }])
    .select()
    .single()
  if (error) {
    if (error.code === '23505') {
      throw new Error(`Ya existe un subrubro llamado "${nombreLimpio}" en ese rubro`)
    }
    throw error
  }
  return data as CategoriaDB
}

export function useCrearSubcategoriaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: (args: { nombre: string; parentId: string }) => createSubcategoria(args, currentSucursalId),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
    },
  })
}

/**
 * Renombra o elimina un subrubro. A diferencia del rubro no hay texto legado que
 * sincronizar (`productos.categoria` es el rubro): borrarlo deja a sus productos
 * con `subcategoria_id` NULL por la FK (mig 276).
 */
export function useRenombrarSubcategoriaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async ({ id, nombre }: { id: string; nombre: string }) => {
      const limpio = nombre.trim()
      if (!limpio) throw new Error('El nombre no puede estar vacío')
      const { error } = await supabase.from('categorias').update({ nombre: limpio }).eq('id', id)
      if (error) {
        if (error.code === '23505') throw new Error(`Ya existe un subrubro llamado "${limpio}" en ese rubro`)
        throw error
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
    },
  })
}

export function useEliminarSubcategoriaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('categorias').delete().eq('id', id)
      if (error) throw error
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
    },
  })
}

export function useCrearCategoriaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (nombre: string) => createCategoria(nombre, currentSucursalId),
    onSuccess: (nueva) => {
      queryClient.setQueryData<CategoriaDB[]>(categoriasKeys.lists(currentSucursalId), (old) => {
        if (!old) return [nueva]
        return [...old, nueva].sort((a, b) => a.nombre.localeCompare(b.nombre))
      })
    },
  })
}

export function useRenombrarCategoriaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (args: { id: string | null; nombreViejo: string; nombreNuevo: string }) =>
      renameCategoria({ ...args, sucursalId: currentSucursalId }),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
      // Los productos cambiaron su string de categoría; invalidar la lista
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
    },
  })
}

export function useEliminarCategoriaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: deleteCategoria,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
    },
  })
}

/**
 * Toggle soft-delete: marca la categoria como activa/inactiva sin borrarla.
 * Una categoria inactiva no aparece en selectores ni filtros. Los productos
 * que la tenian asignada se dejan con categoria NULL.
 */
async function toggleCategoriaActiva(
  { id, activa, nombre }: { id: string; activa: boolean; nombre: string }
): Promise<CategoriaDB> {
  const { data, error } = await supabase
    .from('categorias')
    .update({ activa })
    .eq('id', id)
    .select()
    .single()
  if (error) throw error

  // Si estamos desactivando, soltar la asignacion en productos para que no
  // sigan apareciendo con esa categoria en filtros.
  if (!activa) {
    const { error: bulkErr } = await supabase
      .from('productos')
      .update({ categoria: null })
      .eq('categoria', nombre)
    if (bulkErr) throw bulkErr
  }

  return data as CategoriaDB
}

export function useToggleCategoriaActivaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: toggleCategoriaActiva,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: categoriasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
    },
  })
}
