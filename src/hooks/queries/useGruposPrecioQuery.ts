/**
 * TanStack Query hooks para Grupos de Precio Mayorista
 * Maneja CRUD de grupos con productos y escalas
 */
import { useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import { condicionesDeProducto } from '../../utils/condicionesMayoristas'
import { traerTodo } from '../../utils/paginacion'
import { nuevoRequestId } from '../../utils/idempotencia'
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

/**
 * Trae todas las filas de una tabla de condiciones, paginando: PostgREST corta en
 * 1.000 sin avisar, y un súper tiene más de 1.000 productos en condiciones (#1561).
 * Una tabla que no existe (una base sin la migración) cuenta como vacía, como antes.
 */
async function traerCondiciones<T>(hacerQuery: () => unknown): Promise<T[]> {
  try {
    return await traerTodo<T>(hacerQuery as never, {
      etiqueta: 'las condiciones de precio',
      sinConexion: 'Sin conexión: no se pudo cargar las condiciones de precio. Revisá la señal e intentá de nuevo.',
    })
  } catch (e) {
    if (e instanceof Error && e.message.includes('does not exist')) return []
    throw e
  }
}

export async function fetchGruposPrecio(): Promise<GrupoPrecioConDetalles[]> {
  const grupos = await traerCondiciones<GrupoPrecioDB>(() => supabase.from('grupos_precio').select('*').order('nombre').order('id'))
  if (grupos.length === 0) return []

  const productos = await traerCondiciones<GrupoPrecioProductoDB>(() => supabase.from('grupo_precio_productos').select('*').order('id'))
  const escalas = await traerCondiciones<GrupoPrecioEscalaDB>(() => supabase.from('grupo_precio_escalas').select('*').order('cantidad_minima').order('id'))
  // Mínimos por producto por escala: sin la migración 004 la tabla no existe y
  // seguimos sin combinadas.
  const escalaMinimos = await traerCondiciones<GrupoPrecioEscalaMinimoDB>(() => supabase.from('grupo_precio_escala_minimos').select('*').order('id'))

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

/** Lo que devuelve `guardar_condicion_mayorista`: la condición y si era el reintento de un alta. */
export interface CondicionGuardada {
  id: string
  /** El alta ya había entrado con el intento anterior (misma clave): no se creó otra. */
  replay: boolean
}

/**
 * El JSON de `guardar_condicion_mayorista` (C4b, ola 2 de #1603). Con `id` es la edición; sin
 * `id`, el alta, con la clave del formulario: el reintento de la misma alta devuelve la condición
 * que ya entró y no crea otra. Los mínimos por producto van sólo los que tienen cantidad, como
 * antes; los que no vienen se borran.
 */
export function condicionParaGuardar(input: GrupoPrecioFormInput, id?: string): Record<string, unknown> {
  return {
    ...(id ? { id: Number(id) } : { clave: input.clave }),
    nombre: input.nombre,
    descripcion: input.descripcion || null,
    producto_ids: input.productoIds.map(Number),
    escalas: input.escalas.map(e => ({
      cantidad_minima: e.cantidadMinima,
      precio_unitario: e.precioUnitario,
      etiqueta: e.etiqueta || null,
      min_productos_distintos: e.minProductosDistintos ?? 1,
      minimos: Object.entries(e.minimosPorProducto ?? {})
        .filter(([, regla]) => regla && regla.cantidad > 0)
        .map(([productoId, regla]) => ({
          producto_id: Number(productoId),
          cantidad: regla.cantidad,
          precio_override: regla.precioOverride != null && regla.precioOverride > 0 ? regla.precioOverride : null,
        })),
    })),
  }
}

/**
 * Alta o edición de una condición mayorista entera —nombre, productos, escalas y mínimos— en UNA
 * llamada y una transacción (`guardar_condicion_mayorista`, C4b de #1603; 1561-b12). Antes eran
 * unas diez escrituras REST y, si una fallaba, el front borraba lo recién creado o avisaba que
 * había quedado a medias. Ahora, si algo falla, no entra nada y vuelve el motivo.
 */
async function guardarCondicion(
  input: GrupoPrecioFormInput,
  sucursalId: number | null,
  id?: string,
): Promise<CondicionGuardada> {
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }
  // El formulario manda su clave (una por vez que se abre). Sin ella, una nueva: no hay reintento
  // que reconocer.
  const datos = condicionParaGuardar(id ? input : { ...input, clave: input.clave ?? nuevoRequestId() }, id)
  const { data, error } = await supabase.rpc('guardar_condicion_mayorista', { p_condicion: datos })
  if (error) {
    throw errorDeSupabase(error, id
      ? 'Sin conexión: no se pudo confirmar que la condición se haya guardado. Revisá antes de reintentar.'
      : 'Sin conexión: no se pudo confirmar que la condición se haya creado. Podés volver a guardar: si ya había entrado, no se crea otra.')
  }
  const r = data as { id: number | string; replay?: boolean }
  return { id: String(r.id), replay: Boolean(r.replay) }
}

async function deleteGrupoPrecio(id: string): Promise<void> {
  const { error } = await supabase
    .from('grupos_precio')
    .delete()
    .eq('id', id)

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la condición se haya eliminado. Revisá antes de reintentar.')
}

async function toggleGrupoPrecioActivo(id: string, activo: boolean): Promise<GrupoPrecioDB> {
  const { data, error } = await supabase
    .from('grupos_precio')
    .update({ activo })
    .eq('id', id)
    .select()
    .single()

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la condición se haya actualizado. Revisá antes de reintentar.')
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
    mutationFn: (input: GrupoPrecioFormInput) => guardarCondicion(input, currentSucursalId),
    onSettled: () => {
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
      guardarCondicion(data, currentSucursalId, id),
    onSettled: () => {
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
 * Guardar la condición entera (`guardar_condicion_mayorista`) exige mandarla
 * completa: para corregir un precio desde la ficha del producto este UPDATE es
 * puntual.
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
        if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el precio se haya guardado. Revisá antes de reintentar.')
      } else {
        const { error } = await supabase
          .from('grupo_precio_escalas')
          .update({ precio_unitario: precio })
          .eq('id', escalaId)
        if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el precio se haya guardado. Revisá antes de reintentar.')
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

// =============================================================================
// GESTIÓN DESDE LA FICHA DEL PRODUCTO
// =============================================================================
//
// Todas operan por id sobre una sola tabla, nunca por `guardar_condicion_mayorista`:
// ésa reemplaza la condición entera y desde la ficha solo se toca una parte. La RLS
// ya exige es_admin() + sucursal, así que no hacen falta RPCs.

/** `unique_violation`: la condición ya tiene una escala con esa cantidad. */
function esCantidadDuplicada(error: unknown): boolean {
  return (error as { code?: string })?.code === '23505'
}

function errorCantidadDuplicada(cantidad: number): Error {
  return new Error(`Ya hay un precio para ${cantidad} unidades en esta condición`)
}

/**
 * Suma un producto a una condición que ya existe.
 *
 * Es el flujo que arregla el fardo surtido: al cargar un sabor nuevo entra al
 * fardo que ya está armado, en vez de nacer con una condición propia. Con una
 * condición por sabor, la suma entre productos —que es lo que hace
 * `escalaAplica`— nunca llega a activarse.
 */
export function useAgregarProductoACondicionMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({ grupoId, productoId }: { grupoId: string; productoId: string }) => {
      if (currentSucursalId == null) {
        throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
      }
      const { error } = await supabase
        .from('grupo_precio_productos')
        .upsert(
          {
            grupo_precio_id: parseInt(grupoId),
            producto_id: parseInt(productoId),
            sucursal_id: currentSucursalId,
          },
          { onConflict: 'grupo_precio_id,producto_id', ignoreDuplicates: true },
        )
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el producto se haya agregado a la condición. Revisá antes de reintentar.')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

/** Saca un producto de una condición sin tocar al resto de los que la comparten. */
export function useQuitarProductoDeCondicionMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({ grupoId, productoId }: { grupoId: string; productoId: string }) => {
      const { error } = await supabase
        .from('grupo_precio_productos')
        .delete()
        .eq('grupo_precio_id', grupoId)
        .eq('producto_id', productoId)
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que el producto se haya sacado de la condición. Revisá antes de reintentar.')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

export interface CrearEscalaInput {
  grupoId: string
  cantidadMinima: number
  precioUnitario: number
  etiqueta?: string | null
}

/** Agrega un precio por cantidad a una condición existente. */
export function useCrearEscalaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({ grupoId, cantidadMinima, precioUnitario, etiqueta }: CrearEscalaInput) => {
      if (currentSucursalId == null) {
        throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
      }
      if (!(cantidadMinima > 0)) throw new Error('La cantidad mínima debe ser mayor a 0')
      if (!(precioUnitario > 0)) throw new Error('El precio mayorista debe ser mayor a 0')

      const { data, error } = await supabase
        .from('grupo_precio_escalas')
        .insert({
          grupo_precio_id: parseInt(grupoId),
          cantidad_minima: cantidadMinima,
          precio_unitario: precioUnitario,
          etiqueta: etiqueta?.trim() || null,
          min_productos_distintos: 1,
          sucursal_id: currentSucursalId,
        })
        .select()
        .single()
      if (error) throw esCantidadDuplicada(error)
        ? errorCantidadDuplicada(cantidadMinima)
        : errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la escala se haya creado. Revisá antes de reintentar.')
      return data as GrupoPrecioEscalaDB
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

export interface ActualizarEscalaInput {
  escalaId: string
  cantidadMinima?: number
  precioUnitario?: number
  etiqueta?: string | null
}

/**
 * Edita una escala en el lugar. Conserva el id, que es lo que `pedido_items`
 * guarda para trazar qué escala fijó el precio (mig 148).
 */
export function useActualizarEscalaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({ escalaId, cantidadMinima, precioUnitario, etiqueta }: ActualizarEscalaInput) => {
      const campos: Record<string, unknown> = {}
      if (cantidadMinima !== undefined) {
        if (!(cantidadMinima > 0)) throw new Error('La cantidad mínima debe ser mayor a 0')
        campos.cantidad_minima = cantidadMinima
      }
      if (precioUnitario !== undefined) {
        if (!(precioUnitario > 0)) throw new Error('El precio mayorista debe ser mayor a 0')
        campos.precio_unitario = precioUnitario
      }
      if (etiqueta !== undefined) campos.etiqueta = etiqueta?.trim() || null
      if (Object.keys(campos).length === 0) return

      const { error } = await supabase
        .from('grupo_precio_escalas')
        .update(campos)
        .eq('id', escalaId)
      if (error) {
        throw esCantidadDuplicada(error) && cantidadMinima !== undefined
          ? errorCantidadDuplicada(cantidadMinima)
          : errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la escala se haya guardado. Revisá antes de reintentar.')
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Borra una escala. Los `pedido_items` viejos que la referencian quedan
 * apuntando a un id inexistente, igual que al borrar la condición entera: la
 * columna va sin FK a propósito (mig 148) y el dato que importa para el
 * histórico —precio cobrado y origen— vive en la fila del item.
 */
export function useEliminarEscalaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({ escalaId }: { escalaId: string }) => {
      const { error } = await supabase
        .from('grupo_precio_escalas')
        .delete()
        .eq('id', escalaId)
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la escala se haya eliminado. Revisá antes de reintentar.')
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

export interface CrearCondicionParaProductoInput {
  productoId: string
  cantidadMinima: number
  precioUnitario: number
  etiqueta?: string | null
  /** Nombre de la condición nueva. Sin esto, la RPC usa el del producto. */
  nombre?: string | null
}

/**
 * Le pone un precio por cantidad a un producto que todavía no está en ninguna
 * condición, sin salir de su ficha (mig 171).
 *
 * Va por RPC porque son tres inserts —grupo, producto y escala— y tienen que
 * ser atómicos: si falla el segundo queda un grupo huérfano. Eso ya pasó, son
 * los 3 grupos vacíos que hay en prod.
 */
export function useCrearCondicionParaProductoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({
      productoId,
      cantidadMinima,
      precioUnitario,
      etiqueta,
      nombre,
    }: CrearCondicionParaProductoInput) => {
      const { data, error } = await supabase.rpc('crear_condicion_para_producto', {
        p_producto_id: parseInt(productoId),
        p_cantidad_minima: cantidadMinima,
        p_precio_unitario: precioUnitario,
        p_etiqueta: etiqueta?.trim() || null,
        p_nombre: nombre?.trim() || null,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que la condición se haya creado. Revisá antes de reintentar.')
      return data as { grupo_id: number; escala_id: number; grupo_creado: boolean }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}

export interface ConsolidarCondicionesInput {
  grupoDestino: string
  gruposOrigen: string[]
  nombre?: string | null
}

/**
 * Fusiona varias condiciones en una sola (mig 170), para que la mezcla entre
 * sus productos sume. Va por RPC: mueve productos y escalas, repunta los
 * `pedido_items` que apuntaban a escalas duplicadas y borra los orígenes, todo
 * en una transacción. La RPC rechaza la fusión si cambiaría algún precio.
 */
export function useConsolidarCondicionesMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async ({ grupoDestino, gruposOrigen, nombre }: ConsolidarCondicionesInput) => {
      const { data, error } = await supabase.rpc('consolidar_condiciones', {
        p_grupo_destino: parseInt(grupoDestino),
        p_grupos_origen: gruposOrigen.map(id => parseInt(id)),
        p_nombre: nombre?.trim() || null,
      })
      if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar que las condiciones se hayan unificado. Revisá antes de reintentar.')
      return data as { grupos_borrados: number; items_repuntados: number }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: gruposPrecioKeys.all(currentSucursalId) })
    },
  })
}
