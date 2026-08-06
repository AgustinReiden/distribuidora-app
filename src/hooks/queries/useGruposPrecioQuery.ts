/**
 * TanStack Query hooks para Grupos de Precio Mayorista
 * Maneja CRUD de grupos con productos y escalas
 */
import { useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { condicionesDeProducto } from '../../utils/condicionesMayoristas'
import type {
  GrupoPrecioDB,
  GrupoPrecioProductoDB,
  GrupoPrecioEscalaDB,
  GrupoPrecioEscalaMinimoDB,
  GrupoPrecioConDetalles,
  GrupoPrecioFormInput
} from '../../types'
import type { PricingMap, GrupoPrecioInfo, EscalaPrecio } from '../../utils/precioMayorista'

// Query keys
export const gruposPrecioKeys = {
  all: (sucursalId: number | null) => ['grupos_precio', sucursalId] as const,
  lists: (sucursalId: number | null) => [...gruposPrecioKeys.all(sucursalId), 'list'] as const,
  details: (sucursalId: number | null) => [...gruposPrecioKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...gruposPrecioKeys.details(sucursalId), id] as const,
  pricingMap: (sucursalId: number | null) => [...gruposPrecioKeys.all(sucursalId), 'pricing_map'] as const,
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

  // Fetch minimos por producto por escala (tabla nueva). Tolerante: si la
  // migracion 004 no corrio aun, la tabla no existe y seguimos sin combinadas.
  const { data: escalaMinimos, error: errorMinimos } = await supabase
    .from('grupo_precio_escala_minimos')
    .select('*')

  if (errorMinimos && !errorMinimos.message.includes('does not exist')) {
    throw errorMinimos
  }

  // Indexar minimos por escalaId
  const minimosPorEscala: Record<string, GrupoPrecioEscalaMinimoDB[]> = {}
  for (const m of (escalaMinimos as GrupoPrecioEscalaMinimoDB[] || [])) {
    const key = String(m.escala_id)
    if (!minimosPorEscala[key]) minimosPorEscala[key] = []
    minimosPorEscala[key].push(m)
  }

  // Combinar datos
  return (grupos as GrupoPrecioDB[]).map(grupo => {
    const escalasDelGrupo = (escalas as GrupoPrecioEscalaDB[] || []).filter(
      e => String(e.grupo_precio_id) === String(grupo.id)
    )
    const escalaMinimosDelGrupo: Record<string, GrupoPrecioEscalaMinimoDB[]> = {}
    for (const e of escalasDelGrupo) {
      const key = String(e.id)
      if (minimosPorEscala[key]) escalaMinimosDelGrupo[key] = minimosPorEscala[key]
    }
    return {
      ...grupo,
      productos: (productos as GrupoPrecioProductoDB[] || []).filter(
        p => String(p.grupo_precio_id) === String(grupo.id)
      ),
      escalas: escalasDelGrupo,
      escalaMinimos: escalaMinimosDelGrupo,
    }
  })
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
      .map((e): EscalaPrecio => {
        const minimosRows = grupo.escalaMinimos?.[String(e.id)] || []
        const minimosPorProducto = new Map<string, { cantidad: number; precioOverride?: number | null }>()
        for (const m of minimosRows) {
          minimosPorProducto.set(String(m.producto_id), {
            cantidad: Number(m.cantidad_minima_por_item),
            precioOverride: m.precio_unitario_override != null ? Number(m.precio_unitario_override) : null,
          })
        }
        return {
          // Se arrastra el id para poder registrar en `pedido_items` qué escala
          // fijó el precio (mig 148/149).
          escalaId: String(e.id),
          cantidadMinima: e.cantidad_minima,
          precioUnitario: Number(e.precio_unitario),
          etiqueta: e.etiqueta || null,
          minProductosDistintos: e.min_productos_distintos ?? 1,
          minimosPorProducto,
        }
      })

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

async function createGrupoPrecio(input: GrupoPrecioFormInput, sucursalId: number | null): Promise<GrupoPrecioConDetalles> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  // Crear el grupo
  const { data: grupo, error: errorGrupo } = await supabase
    .from('grupos_precio')
    .insert([{ nombre: input.nombre, descripcion: input.descripcion || null, sucursal_id: sucursalId }])
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
        sucursal_id: sucursalId,
      })))

    if (errorProductos) throw errorProductos
  }

  // Insertar escalas y recuperar los IDs para asociar minimos
  if (input.escalas.length > 0) {
    const { data: escalasInsertadas, error: errorEscalas } = await supabase
      .from('grupo_precio_escalas')
      .insert(input.escalas.map(e => ({
        grupo_precio_id: parseInt(grupoId),
        cantidad_minima: e.cantidadMinima,
        precio_unitario: e.precioUnitario,
        etiqueta: e.etiqueta || null,
        min_productos_distintos: e.minProductosDistintos ?? 1,
        sucursal_id: sucursalId,
      })))
      .select()

    if (errorEscalas) throw errorEscalas

    // Insertar los minimos por producto para las escalas combinadas.
    // Match por cantidad_minima (es UNIQUE dentro del grupo).
    const filasMinimos = buildFilasMinimos(
      input.escalas,
      (escalasInsertadas as GrupoPrecioEscalaDB[]) || [],
      sucursalId
    )
    if (filasMinimos.length > 0) {
      const { error: errorMinimos } = await supabase
        .from('grupo_precio_escala_minimos')
        .insert(filasMinimos)
      if (errorMinimos) throw errorMinimos
    }
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

/**
 * Arma las filas de grupo_precio_escala_minimos a partir del input del form
 * y las escalas ya insertadas (para obtener sus IDs). Hace match por
 * cantidad_minima, que es UNIQUE dentro de un grupo.
 */
interface FilaMinimoInsert {
  escala_id: number
  producto_id: number
  cantidad_minima_por_item: number
  precio_unitario_override: number | null
  sucursal_id: number
}

function buildFilasMinimos(
  escalasInput: GrupoPrecioFormInput['escalas'],
  escalasDB: GrupoPrecioEscalaDB[],
  sucursalId: number
): FilaMinimoInsert[] {
  const filas: FilaMinimoInsert[] = []
  for (const e of escalasInput) {
    if (!e.minimosPorProducto) continue
    const entries = Object.entries(e.minimosPorProducto).filter(([, v]) => v && v.cantidad > 0)
    if (entries.length === 0) continue
    const escalaDB = escalasDB.find(db => db.cantidad_minima === e.cantidadMinima)
    if (!escalaDB) continue
    for (const [productoId, regla] of entries) {
      filas.push({
        escala_id: parseInt(String(escalaDB.id)),
        producto_id: parseInt(productoId),
        cantidad_minima_por_item: regla.cantidad,
        precio_unitario_override:
          regla.precioOverride != null && regla.precioOverride > 0 ? regla.precioOverride : null,
        sucursal_id: sucursalId,
      })
    }
  }
  return filas
}

async function updateGrupoPrecio(
  { id, data: input, sucursalId }: { id: string; data: GrupoPrecioFormInput; sucursalId: number | null }
): Promise<GrupoPrecioConDetalles> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  // Actualizar grupo
  const { data: grupo, error: errorGrupo } = await supabase
    .from('grupos_precio')
    .update({ nombre: input.nombre, descripcion: input.descripcion || null })
    .eq('id', id)
    .select()
    .single()

  if (errorGrupo) throw errorGrupo

  // Productos: reconciliar por producto_id en vez de barrer y reinsertar.
  const { data: productosActuales, error: errorLeerProductos } = await supabase
    .from('grupo_precio_productos')
    .select('id, producto_id')
    .eq('grupo_precio_id', id)
  if (errorLeerProductos) throw errorLeerProductos

  const filasProducto = (productosActuales || []) as Array<{ id: string; producto_id: string }>
  const productoIdsDeseados = new Set(input.productoIds.map(String))
  const productoIdsActuales = new Set(filasProducto.map(p => String(p.producto_id)))

  const productosAQuitar = filasProducto.filter(p => !productoIdsDeseados.has(String(p.producto_id)))
  if (productosAQuitar.length > 0) {
    const { error } = await supabase
      .from('grupo_precio_productos')
      .delete()
      .in('id', productosAQuitar.map(p => p.id))
    if (error) throw error
  }

  const productosAAgregar = input.productoIds.filter(pid => !productoIdsActuales.has(String(pid)))
  if (productosAAgregar.length > 0) {
    const { error } = await supabase
      .from('grupo_precio_productos')
      .insert(productosAAgregar.map(pid => ({
        grupo_precio_id: parseInt(id),
        producto_id: parseInt(pid),
        sucursal_id: sucursalId,
      })))
    if (error) throw error
  }

  // Escalas: reconciliar por cantidad_minima, que es UNIQUE dentro del grupo.
  //
  // Antes se borraban todas y se reinsertaban. Eso rotaba los ids en cada
  // edición y dejaba huérfano el `grupo_precio_escala_id` que `pedido_items`
  // guarda para trazar qué escala fijó el precio (mig 148): en prod ya hay 11
  // de 149 items apuntando a escalas que no existen. Actualizar en el lugar
  // conserva el id, así el histórico sigue siendo legible.
  const { data: escalasActuales, error: errorLeerEscalas } = await supabase
    .from('grupo_precio_escalas')
    .select('id, cantidad_minima')
    .eq('grupo_precio_id', id)
  if (errorLeerEscalas) throw errorLeerEscalas

  const filasEscala = (escalasActuales || []) as Array<{ id: string; cantidad_minima: number }>
  const idPorCantidad = new Map<number, string>()
  for (const e of filasEscala) idPorCantidad.set(Number(e.cantidad_minima), String(e.id))

  // Primero las bajas: si una escala cambia de cantidad a una ya ocupada por
  // otra que se va, borrar antes evita chocar contra el UNIQUE.
  const cantidadesDeseadas = new Set(input.escalas.map(e => e.cantidadMinima))
  const escalasAQuitar = filasEscala.filter(e => !cantidadesDeseadas.has(Number(e.cantidad_minima)))
  if (escalasAQuitar.length > 0) {
    const { error } = await supabase
      .from('grupo_precio_escalas')
      .delete()
      .in('id', escalasAQuitar.map(e => e.id))
    if (error) throw error
  }

  const escalasFinales: GrupoPrecioEscalaDB[] = []
  for (const e of input.escalas) {
    const existenteId = idPorCantidad.get(e.cantidadMinima)
    const campos = {
      precio_unitario: e.precioUnitario,
      etiqueta: e.etiqueta || null,
      min_productos_distintos: e.minProductosDistintos ?? 1,
    }
    if (existenteId) {
      const { data, error } = await supabase
        .from('grupo_precio_escalas')
        .update(campos)
        .eq('id', existenteId)
        .select()
        .single()
      if (error) throw error
      escalasFinales.push(data as GrupoPrecioEscalaDB)
    } else {
      const { data, error } = await supabase
        .from('grupo_precio_escalas')
        .insert({
          grupo_precio_id: parseInt(id),
          cantidad_minima: e.cantidadMinima,
          sucursal_id: sucursalId,
          ...campos,
        })
        .select()
        .single()
      if (error) throw error
      escalasFinales.push(data as GrupoPrecioEscalaDB)
    }
  }

  // Los mínimos por producto sí se reemplazan enteros: son configuración de la
  // escala, no historia. Antes los limpiaba el CASCADE al borrar la escala;
  // ahora que las escalas sobreviven hay que borrarlos a mano.
  if (escalasFinales.length > 0) {
    const { error: errorBorrarMinimos } = await supabase
      .from('grupo_precio_escala_minimos')
      .delete()
      .in('escala_id', escalasFinales.map(e => e.id))
    if (errorBorrarMinimos) throw errorBorrarMinimos

    const filasMinimos = buildFilasMinimos(input.escalas, escalasFinales, sucursalId)
    if (filasMinimos.length > 0) {
      const { error: errorMinimos } = await supabase
        .from('grupo_precio_escala_minimos')
        .insert(filasMinimos)
      if (errorMinimos) throw errorMinimos
    }
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
export function useGruposPrecioQuery(options?: { enabled?: boolean }) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: gruposPrecioKeys.lists(currentSucursalId),
    queryFn: fetchGruposPrecio,
    staleTime: 10 * 60 * 1000,
    // Solo el admin ve las condiciones: para el resto son 4 queries al pedo.
    enabled: options?.enabled ?? true,
  })
}

/**
 * Hook para obtener el PricingMap denormalizado (para resolución de precios)
 * Cache 10 minutos, usado por usePrecioMayorista
 */
export function usePricingMapQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: gruposPrecioKeys.pricingMap(currentSucursalId),
    queryFn: fetchPricingMap,
    staleTime: 10 * 60 * 1000,
  })
}

/**
 * Hook para crear un grupo de precio
 */
export function useCrearGrupoPrecioMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (input: GrupoPrecioFormInput) => createGrupoPrecio(input, currentSucursalId),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para actualizar un grupo de precio
 */
export function useActualizarGrupoPrecioMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ id, data }: { id: string; data: GrupoPrecioFormInput }) =>
      updateGrupoPrecio({ id, data, sucursalId: currentSucursalId }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para eliminar un grupo de precio
 */
export function useEliminarGrupoPrecioMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: deleteGrupoPrecio,
    onMutate: async (id: string) => {
      await queryClient.cancelQueries({ queryKey: gruposPrecioKeys.lists(currentSucursalId) })
      const previous = queryClient.getQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists(currentSucursalId))
      queryClient.setQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.filter(g => g.id !== id)
      })
      return { previous }
    },
    onError: (_, __, context) => {
      if (context?.previous) {
        queryClient.setQueryData(gruposPrecioKeys.lists(currentSucursalId), context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para activar/desactivar un grupo de precio
 */
export function useToggleGrupoPrecioActivoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) =>
      toggleGrupoPrecioActivo(id, activo),
    onMutate: async ({ id, activo }) => {
      await queryClient.cancelQueries({ queryKey: gruposPrecioKeys.lists(currentSucursalId) })
      const previous = queryClient.getQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists(currentSucursalId))
      queryClient.setQueryData<GrupoPrecioConDetalles[]>(gruposPrecioKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.map(g => g.id === id ? { ...g, activo } : g)
      })
      return { previous }
    },
    onError: (_, __, context) => {
      if (context?.previous) {
        queryClient.setQueryData(gruposPrecioKeys.lists(currentSucursalId), context.previous)
      }
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

// =============================================================================
// VISTA POR PRODUCTO (ficha de producto)
// =============================================================================

/**
 * Condiciones mayoristas que incluyen a un producto, para mostrarlas en su
 * ficha. Se deriva de `useGruposPrecioQuery` en vez de pedir de nuevo a la DB:
 * comparte la misma entrada de cache (y su staleTime de 10 min), así abrir la
 * ficha no dispara ninguna query extra si la lista de grupos ya se cargó.
 */
export function useGruposPrecioPorProductoQuery(productoId: string | undefined) {
  const { data: grupos, isLoading, error } = useGruposPrecioQuery()

  const condiciones = useMemo(
    () => (productoId && grupos ? condicionesDeProducto(grupos, productoId) : []),
    [grupos, productoId],
  )

  return { condiciones, isLoading, error }
}

/**
 * Cambia el precio de UNA escala sin pasar por el form completo del grupo.
 *
 * `updateGrupoPrecio` borra y reinserta productos y escalas enteras: usarlo para
 * corregir un precio desde la ficha del producto rotaría los ids de todas las
 * escalas y exigiría mandar el grupo completo. Este UPDATE es puntual.
 *
 * - `alcance: 'override'` toca `grupo_precio_escala_minimos.precio_unitario_override`
 *   → afecta SOLO a este producto.
 * - `alcance: 'grupo'` toca `grupo_precio_escalas.precio_unitario`
 *   → afecta a todos los productos del grupo. La UI lo avisa antes.
 */
export interface ActualizarPrecioEscalaInput {
  escalaId: string
  productoId: string
  precio: number
  alcance: 'grupo' | 'override'
}

export function useActualizarPrecioEscalaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({ escalaId, productoId, precio, alcance }: ActualizarPrecioEscalaInput) => {
      if (!(precio > 0)) throw new Error('El precio debe ser mayor a 0')

      if (alcance === 'override') {
        const { error } = await supabase
          .from('grupo_precio_escala_minimos')
          .update({ precio_unitario_override: precio })
          .eq('escala_id', escalaId)
          .eq('producto_id', productoId)
        if (error) throw error
      } else {
        const { error } = await supabase
          .from('grupo_precio_escalas')
          .update({ precio_unitario: precio })
          .eq('id', escalaId)
        if (error) throw error
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}
