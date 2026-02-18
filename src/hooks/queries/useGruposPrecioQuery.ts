/**
 * TanStack Query hooks para Grupos de Precio Mayorista
 * Maneja CRUD de grupos con productos y escalas
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type {
  GrupoPrecioDB,
  GrupoPrecioProductoDB,
  GrupoPrecioEscalaDB,
  GrupoPrecioConDetalles,
  GrupoPrecioFormInput
} from '../../types'
import type { PricingMap, GrupoPrecioInfo, EscalaPrecio } from '../../utils/precioMayorista'

// Query keys
export const gruposPrecioKeys = {
  all: ['grupos_precio'] as const,
  lists: () => [...gruposPrecioKeys.all, 'list'] as const,
  details: () => [...gruposPrecioKeys.all, 'detail'] as const,
  detail: (id: string) => [...gruposPrecioKeys.details(), id] as const,
  pricingMap: () => [...gruposPrecioKeys.all, 'pricing_map'] as const,
}

// =============================================================================
// FETCH FUNCTIONS
// =============================================================================

async function fetchGruposPrecio(): Promise<GrupoPrecioConDetalles[]> {
  // Fetch grupos
  const { data: grupos, error: errorGrupos } = await supabase
    .from('grupos_precio')
    .select('*')
    .order('nombre')

  if (errorGrupos) {
    if (errorGrupos.message.includes('does not exist')) return []
    throw errorGrupos
  }
  if (!grupos || grupos.length === 0) return []

  // Fetch productos de todos los grupos
  const { data: productos, error: errorProductos } = await supabase
    .from('grupo_precio_productos')
    .select('*')

  if (errorProductos && !errorProductos.message.includes('does not exist')) {
    throw errorProductos
  }

  // Fetch escalas de todos los grupos
  const { data: escalas, error: errorEscalas } = await supabase
    .from('grupo_precio_escalas')
    .select('*')
    .order('cantidad_minima')

  if (errorEscalas && !errorEscalas.message.includes('does not exist')) {
    throw errorEscalas
  }

  // Combinar datos
  return (grupos as GrupoPrecioDB[]).map(grupo => ({
    ...grupo,
    productos: (productos as GrupoPrecioProductoDB[] || []).filter(
      p => String(p.grupo_precio_id) === String(grupo.id)
    ),
    escalas: (escalas as GrupoPrecioEscalaDB[] || []).filter(
      e => String(e.grupo_precio_id) === String(grupo.id)
    ),
  }))
}

/**
 * Fetch denormalizado que construye el PricingMap para resolución O(1)
 */
async function fetchPricingMap(): Promise<PricingMap> {
  const grupos = await fetchGruposPrecio()
  const map: PricingMap = new Map()

  for (const grupo of grupos) {
    if (!grupo.activo) continue

    const escalasActivas = grupo.escalas
      .filter(e => e.activo !== false)
      .map((e): EscalaPrecio => ({
        cantidadMinima: e.cantidad_minima,
        precioUnitario: Number(e.precio_unitario),
        etiqueta: e.etiqueta || null,
      }))

    if (escalasActivas.length === 0) continue

    const productoIds = grupo.productos.map(p => String(p.producto_id))

    const grupoInfo: GrupoPrecioInfo = {
      grupoId: String(grupo.id),
      grupoNombre: grupo.nombre,
      escalas: escalasActivas,
      productoIds,
    }

    // Agregar el grupo a cada producto del grupo
    for (const productoId of productoIds) {
      const existing = map.get(productoId) || []
      existing.push(grupoInfo)
      map.set(productoId, existing)
    }
  }

  return map
}

// =============================================================================
// MUTATION FUNCTIONS
// =============================================================================

async function createGrupoPrecio(input: GrupoPrecioFormInput): Promise<GrupoPrecioConDetalles> {
  // Crear el grupo
  const { data: grupo, error: errorGrupo } = await supabase
    .from('grupos_precio')
    .insert([{ nombre: input.nombre, descripcion: input.descripcion || null }])
    .select()
    .single()

  if (errorGrupo) throw errorGrupo

  const grupoId = (grupo as GrupoPrecioDB).id

  // Insertar productos
  if (input.productoIds.length > 0) {
    const { error: errorProductos } = await supabase
      .from('grupo_precio_productos')
      .insert(input.productoIds.map(pid => ({
        grupo_precio_id: parseInt(grupoId),
        producto_id: parseInt(pid),
      })))

    if (errorProductos) throw errorProductos
  }

  // Insertar escalas
  if (input.escalas.length > 0) {
    const { error: errorEscalas } = await supabase
      .from('grupo_precio_escalas')
      .insert(input.escalas.map(e => ({
        grupo_precio_id: parseInt(grupoId),
        cantidad_minima: e.cantidadMinima,
        precio_unitario: e.precioUnitario,
        etiqueta: e.etiqueta || null,
      })))

    if (errorEscalas) throw errorEscalas
  }

  // Fetch completo para devolver
  const { data: productos } = await supabase
    .from('grupo_precio_productos')
    .select('*')
    .eq('grupo_precio_id', grupoId)

  const { data: escalas } = await supabase
    .from('grupo_precio_escalas')
    .select('*')
    .eq('grupo_precio_id', grupoId)
    .order('cantidad_minima')

  return {
    ...(grupo as GrupoPrecioDB),
    productos: (productos || []) as GrupoPrecioProductoDB[],
    escalas: (escalas || []) as GrupoPrecioEscalaDB[],
  }
}

async function updateGrupoPrecio(
  { id, data: input }: { id: string; data: GrupoPrecioFormInput }
): Promise<GrupoPrecioConDetalles> {
  // Actualizar grupo
  const { data: grupo, error: errorGrupo } = await supabase
    .from('grupos_precio')
    .update({ nombre: input.nombre, descripcion: input.descripcion || null })
    .eq('id', id)
    .select()
    .single()

  if (errorGrupo) throw errorGrupo

  // Reemplazar productos: borrar existentes e insertar nuevos
  await supabase
    .from('grupo_precio_productos')
    .delete()
    .eq('grupo_precio_id', id)

  if (input.productoIds.length > 0) {
    const { error: errorProductos } = await supabase
      .from('grupo_precio_productos')
      .insert(input.productoIds.map(pid => ({
        grupo_precio_id: parseInt(id),
        producto_id: parseInt(pid),
      })))

    if (errorProductos) throw errorProductos
  }

  // Reemplazar escalas
  await supabase
    .from('grupo_precio_escalas')
    .delete()
    .eq('grupo_precio_id', id)

  if (input.escalas.length > 0) {
    const { error: errorEscalas } = await supabase
      .from('grupo_precio_escalas')
      .insert(input.escalas.map(e => ({
        grupo_precio_id: parseInt(id),
        cantidad_minima: e.cantidadMinima,
        precio_unitario: e.precioUnitario,
        etiqueta: e.etiqueta || null,
      })))

    if (errorEscalas) throw errorEscalas
  }

  // Fetch completo
  const { data: productos } = await supabase
    .from('grupo_precio_productos')
    .select('*')
    .eq('grupo_precio_id', id)

  const { data: escalas } = await supabase
    .from('grupo_precio_escalas')
    .select('*')
    .eq('grupo_precio_id', id)
    .order('cantidad_minima')

  return {
    ...(grupo as GrupoPrecioDB),
    productos: (productos || []) as GrupoPrecioProductoDB[],
    escalas: (escalas || []) as GrupoPrecioEscalaDB[],
  }
}

async function deleteGrupoPrecio(id: string): Promise<void> {
  const { error } = await supabase
    .from('grupos_precio')
    .delete()
    .eq('id', id)

  if (error) throw error
}

async function toggleGrupoPrecioActivo(id: string, activo: boolean): Promise<GrupoPrecioDB> {
  const { data, error } = await supabase
    .from('grupos_precio')
    .update({ activo })
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  return data as GrupoPrecioDB
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para obtener todos los grupos de precio con sus productos y escalas
 */
export function useGruposPrecioQuery() {
  return useQuery({
    queryKey: gruposPrecioKeys.lists(),
    queryFn: fetchGruposPrecio,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para obtener el PricingMap denormalizado (para resolución de precios)
 * Cache 10 minutos, usado por usePrecioMayorista
 */
export function usePricingMapQuery() {
  return useQuery({
    queryKey: gruposPrecioKeys.pricingMap(),
    queryFn: fetchPricingMap,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para crear un grupo de precio
 */
export function useCrearGrupoPrecioMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createGrupoPrecio,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all })
    },
  })
}

/**
 * Hook para actualizar un grupo de precio
 */
export function useActualizarGrupoPrecioMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: updateGrupoPrecio,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all })
    },
  })
}

/**
 * Hook para eliminar un grupo de precio
 */
export function useEliminarGrupoPrecioMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: deleteGrupoPrecio,
    onMutate: async (id: string) => {
      await queryClient.cancelQueries({ queryKey: gruposPrecioKeys.lists() })
      const previous = queryClient.getQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists())
      queryClient.setQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists(), (old) => {
        if (!old) return old
        return old.filter(g => g.id !== id)
      })
      return { previous }
    },
    onError: (_, __, context) => {
      if (context?.previous) {
        queryClient.setQueryData(gruposPrecioKeys.lists(), context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all })
    },
  })
}

/**
 * Hook para activar/desactivar un grupo de precio
 */
export function useToggleGrupoPrecioActivoMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) =>
      toggleGrupoPrecioActivo(id, activo),
    onMutate: async ({ id, activo }) => {
      await queryClient.cancelQueries({ queryKey: gruposPrecioKeys.lists() })
      const previous = queryClient.getQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists())
      queryClient.setQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists(), (old) => {
        if (!old) return old
        return old.map(g => g.id === id ? { ...g, activo } : g)
      })
      return { previous }
    },
    onError: (_, __, context) => {
      if (context?.previous) {
        queryClient.setQueryData(gruposPrecioKeys.lists(), context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all })
    },
  })
}
