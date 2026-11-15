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
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'
import { traerTodo } from '../../utils/paginacion'

// =============================================================================
// TYPES
// =============================================================================

export interface CategoriaDB {
  id: string
  nombre: string
  sucursal_id: number
  /** Subrubro (mig 270): id del rubro padre. null = es un rubro. Dos niveles como máximo. */
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

// PostgREST corta en 1.000 filas sin avisar: el catálogo de un súper tiene miles
// de productos (#1561). Paginado, con un orden único (`id` de desempate).
async function fetchCategorias(): Promise<CategoriaDB[]> {
  return traerTodo<CategoriaDB>(
    () => supabase.from('categorias').select('*').order('nombre').order('id') as never,
    { etiqueta: 'las categorías', sinConexion: 'Sin conexión: no se pudo cargar las categorías. Revisá la señal e intentá de nuevo.' },
  )
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
    throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la categoría se haya creado. Revisá antes de reintentar.')
  }
  return data as CategoriaDB
}

/**
 * Renombra un rubro por la RPC `renombrar_rubro` (#1561, CAT-1 y CAT-5): en una
 * transacción cambia la fila (o se la crea al rubro que sólo existía como texto
 * de productos), pasa sus productos al nombre nuevo y le pasa el descuento por
 * rubro a cada cliente. Antes eran escrituras REST sueltas que no tocaban
 * `cliente_descuentos_categoria`: el descuento se resuelve por el NOMBRE, y
 * renombrar «Bebidas» dejaba sin efecto el descuento de «Bebidas».
 * La base rechaza (23505) un nombre que ya es de otro rubro: no fusiona.
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

  const { error } = await supabase.rpc('renombrar_rubro', {
    p_categoria_id: id,
    p_nombre_actual: nombreViejo,
    p_nombre_nuevo: nuevoLimpio,
  })
  if (error) {
    if (error.code === '23505') {
      throw new Error(`Ya existe una categoría llamada "${nuevoLimpio}"`)
    }
    throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la categoría se haya renombrado. Revisá antes de reintentar.')
  }
}

/** Lo que haría eliminar un rubro, y lo que lo frena (`eliminar_rubro` con `p_solo_ver`). */
export interface ImpactoEliminarRubro {
  nombre: string
  productos: number
  subrubros: number
  /** Descuentos por este rubro de clientes de la sucursal: se borran. */
  descuentos: number
  /** Metas de venta por este rubro o un subrubro: caen con él. */
  metas: number
  /** Combos o reglas de comisión que lo usan: con alguno, no se puede eliminar. */
  bloqueos: string[]
}

async function fetchImpactoEliminarRubro({ id, nombre }: { id: string | null; nombre: string }): Promise<ImpactoEliminarRubro> {
  const { data, error } = await supabase.rpc('eliminar_rubro', {
    p_categoria_id: id,
    p_nombre: nombre,
    p_solo_ver: true,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo ver qué se llevaría eliminar la categoría. Revisá la señal e intentá de nuevo.')
  return data as ImpactoEliminarRubro
}

/**
 * Elimina un rubro por la RPC `eliminar_rubro` (#1561, CAT-5): en una transacción
 * deja sus productos sin rubro ni subrubro, borra los descuentos por ese rubro y
 * la fila. Antes se borraba primero la fila y la FK de los productos lo
 * rechazaba: un rubro con productos no se podía eliminar nunca. La base frena
 * (23503, con el motivo) si el rubro está en un combo o en una regla de comisión.
 */
async function deleteCategoria(
  { id, nombre }: { id: string | null; nombre: string }
): Promise<void> {
  const { error } = await supabase.rpc('eliminar_rubro', {
    p_categoria_id: id,
    p_nombre: nombre,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la categoría se haya eliminado. Revisá antes de reintentar.')
}

// =============================================================================
// HOOKS
// =============================================================================

// Un solo fetch y una sola caché para rubros y subrubros. `useCategoriasQuery`
// devuelve SOLO los rubros (parent_id NULL): todos los consumidores previos a la
// mig 270 siguen viendo lo mismo. Los subrubros salen por `useSubcategoriasQuery`.
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
    throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el subrubro se haya creado. Revisá antes de reintentar.')
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
 * con `subcategoria_id` NULL por la FK (mig 270).
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
        throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el subrubro se haya renombrado. Revisá antes de reintentar.')
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
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el subrubro se haya eliminado. Revisá antes de reintentar.')
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
      // Y los descuentos por rubro de los clientes (#1561).
      queryClient.invalidateQueries({ queryKey: ['clientes', currentSucursalId] })
    },
  })
}

/** Lo que haría eliminar el rubro, para avisarlo antes de confirmar. `null` = no se está por eliminar. */
export function useImpactoEliminarRubroQuery(rubro: { id: string | null; nombre: string } | null) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...categoriasKeys.all(currentSucursalId), 'impacto', rubro?.id ?? null, rubro?.nombre ?? null],
    queryFn: () => fetchImpactoEliminarRubro(rubro as { id: string | null; nombre: string }),
    enabled: rubro != null,
    staleTime: 0,
  })
}

export function useEliminarCategoriaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: deleteCategoria,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: categoriasKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['clientes', currentSucursalId] })
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
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la categoría se haya actualizado. Revisá antes de reintentar.')

  // Si estamos desactivando, soltar la asignacion en productos para que no
  // sigan apareciendo con esa categoria en filtros.
  if (!activa) {
    const { error: bulkErr } = await supabase
      .from('productos')
      .update({ categoria: null })
      .eq('categoria', nombre)
    if (bulkErr) throw errorDeSupabase(bulkErr, 'Sin conexión: no se pudo confirmar que los productos se hayan dejado sin categoría. Revisá antes de reintentar.')
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
