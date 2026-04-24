/**
 * TanStack Query hooks para Promociones
 * Fetch de promos activas + CRUD para admin panel + ajuste de stock
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'
import type {
  PromocionDB,
  PromocionProductoDB,
  PromocionReglaDB,
} from '../../types'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

// Query keys
export const promocionesKeys = {
  all: (sucursalId: number | null) => ['promociones', sucursalId] as const,
  lists: (sucursalId: number | null) => [...promocionesKeys.all(sucursalId), 'list'] as const,
  promoMap: (sucursalId: number | null, fechaReferencia?: string) =>
    [...promocionesKeys.all(sucursalId), 'promo_map', fechaReferencia ?? 'today'] as const,
}

// =============================================================================
// TIPOS PARA ADMIN PANEL
// =============================================================================

export interface PromocionConDetalles extends PromocionDB {
  productos: PromocionProductoDB[]
  reglas: PromocionReglaDB[]
  usos_pendientes: number
  limite_usos?: number | null
}

export interface PromocionFormInput {
  nombre: string
  tipo: 'bonificacion'
  fechaInicio: string
  fechaFin?: string | null
  limiteUsos?: number | null
  productoIds: string[]
  productoRegaloId?: string | null
  reglas: { clave: string; valor: number }[]
  prioridad?: number
  regaloMueveStock?: boolean
  modoExclusion?: 'acumulable' | 'excluyente'
  ajusteAutomatico?: boolean
  ajusteProductoId?: string | null
  unidadesPorBloque?: number | null
  stockPorBloque?: number | null
  descripcionRegalo?: string | null
}

// =============================================================================
// FETCH FUNCTIONS
// =============================================================================

/**
 * Fetch denormalizado que construye el PromoMap para resolución O(1).
 *
 * Por defecto evalúa vigencia al día de HOY. Si se pasa `fechaReferencia`
 * (ej. la fecha del pedido que se está editando) se usa esa fecha para
 * decidir si la promo estaba activa entonces. Imprescindible al re-resolver
 * promos en la edición de pedidos existentes.
 */
async function fetchPromoMap(fechaReferencia?: string): Promise<PromoMap> {
  const fecha = fechaReferencia || fechaLocalISO()

  const { data: promos, error: errorPromos } = await supabase
    .from('promociones')
    .select('*')
    .eq('activo', true)
    .lte('fecha_inicio', fecha)
    .or(`fecha_fin.is.null,fecha_fin.gte.${fecha}`)

  if (errorPromos) {
    if (errorPromos.message.includes('does not exist')) return new Map()
    throw errorPromos
  }
  if (!promos || promos.length === 0) return new Map()

  const promoIds = (promos as PromocionDB[]).map(p => p.id)

  const { data: productos, error: errorProductos } = await supabase
    .from('promocion_productos')
    .select('*')
    .in('promocion_id', promoIds)

  if (errorProductos && !errorProductos.message.includes('does not exist')) {
    throw errorProductos
  }

  const { data: reglas, error: errorReglas } = await supabase
    .from('promocion_reglas')
    .select('*')
    .in('promocion_id', promoIds)

  if (errorReglas && !errorReglas.message.includes('does not exist')) {
    throw errorReglas
  }

  const map: PromoMap = new Map()

  for (const promo of promos as PromocionDB[]) {
    const promoProductos = ((productos || []) as PromocionProductoDB[])
      .filter(p => String(p.promocion_id) === String(promo.id))
    const promoReglas = ((reglas || []) as PromocionReglaDB[])
      .filter(r => String(r.promocion_id) === String(promo.id))

    const productoIds = promoProductos.map(p => String(p.producto_id))
    if (productoIds.length === 0) continue

    const reglasMap: Record<string, number> = {}
    for (const r of promoReglas) {
      reglasMap[r.clave] = Number(r.valor)
    }

    const promoActiva: PromocionActiva = {
      id: String(promo.id),
      nombre: promo.nombre,
      tipo: promo.tipo,
      productoIds,
      reglas: reglasMap,
      productoRegaloId: promo.producto_regalo_id ? String(promo.producto_regalo_id) : undefined,
      prioridad: promo.prioridad ?? 0,
      regaloMueveStock: promo.regalo_mueve_stock ?? false,
      modoExclusion: promo.modo_exclusion ?? 'acumulable',
    }

    for (const productoId of productoIds) {
      const existing = map.get(productoId) || []
      existing.push(promoActiva)
      map.set(productoId, existing)
    }
  }

  return map
}

/**
 * Fetch todas las promociones con detalles (para admin panel)
 */
async function fetchPromocionesList(): Promise<PromocionConDetalles[]> {
  const { data: promos, error: errorPromos } = await supabase
    .from('promociones')
    .select('*')
    .order('created_at', { ascending: false })

  if (errorPromos) {
    if (errorPromos.message.includes('does not exist')) return []
    throw errorPromos
  }
  if (!promos || promos.length === 0) return []

  const promoIds = (promos as PromocionDB[]).map(p => p.id)

  const { data: productos } = await supabase
    .from('promocion_productos')
    .select('*')
    .in('promocion_id', promoIds)

  const { data: reglas } = await supabase
    .from('promocion_reglas')
    .select('*')
    .in('promocion_id', promoIds)

  return (promos as PromocionDB[]).map(promo => ({
    ...promo,
    usos_pendientes: (promo as PromocionDB & { usos_pendientes?: number }).usos_pendientes || 0,
    productos: ((productos || []) as PromocionProductoDB[])
      .filter(p => String(p.promocion_id) === String(promo.id)),
    reglas: ((reglas || []) as PromocionReglaDB[])
      .filter(r => String(r.promocion_id) === String(promo.id)),
  }))
}

// =============================================================================
// MUTATION FUNCTIONS
// =============================================================================

async function createPromocion(input: PromocionFormInput): Promise<PromocionConDetalles> {
  const { data: promo, error: errorPromo } = await supabase
    .from('promociones')
    .insert([{
      nombre: input.nombre,
      tipo: input.tipo,
      fecha_inicio: input.fechaInicio,
      fecha_fin: input.fechaFin || null,
      limite_usos: input.limiteUsos ?? null,
      producto_regalo_id: input.productoRegaloId ? parseInt(input.productoRegaloId) : null,
      prioridad: input.prioridad ?? 0,
      regalo_mueve_stock: input.regaloMueveStock ?? false,
      modo_exclusion: input.modoExclusion ?? 'acumulable',
      ajuste_automatico: input.ajusteAutomatico ?? false,
      ajuste_producto_id: input.ajusteProductoId ? parseInt(input.ajusteProductoId) : null,
      unidades_por_bloque: input.unidadesPorBloque ?? null,
      stock_por_bloque: input.stockPorBloque ?? null,
      descripcion_regalo: input.descripcionRegalo ?? null,
    }])
    .select()
    .single()

  if (errorPromo) throw errorPromo

  const promoId = (promo as PromocionDB).id

  if (input.productoIds.length > 0) {
    const { error } = await supabase
      .from('promocion_productos')
      .insert(input.productoIds.map(pid => ({
        promocion_id: parseInt(promoId),
        producto_id: parseInt(pid),
      })))
    if (error) throw error
  }

  if (input.reglas.length > 0) {
    const { error } = await supabase
      .from('promocion_reglas')
      .insert(input.reglas.map(r => ({
        promocion_id: parseInt(promoId),
        clave: r.clave,
        valor: r.valor,
      })))
    if (error) throw error
  }

  const { data: productos } = await supabase
    .from('promocion_productos')
    .select('*')
    .eq('promocion_id', promoId)

  const { data: reglas } = await supabase
    .from('promocion_reglas')
    .select('*')
    .eq('promocion_id', promoId)

  return {
    ...(promo as PromocionDB),
    usos_pendientes: 0,
    productos: (productos || []) as PromocionProductoDB[],
    reglas: (reglas || []) as PromocionReglaDB[],
  }
}

async function updatePromocion(
  { id, data: input }: { id: string; data: PromocionFormInput }
): Promise<PromocionConDetalles> {
  const { data: promo, error: errorPromo } = await supabase
    .from('promociones')
    .update({
      nombre: input.nombre,
      tipo: input.tipo,
      fecha_inicio: input.fechaInicio,
      fecha_fin: input.fechaFin || null,
      limite_usos: input.limiteUsos ?? null,
      producto_regalo_id: input.productoRegaloId ? parseInt(input.productoRegaloId) : null,
      prioridad: input.prioridad ?? 0,
      regalo_mueve_stock: input.regaloMueveStock ?? false,
      modo_exclusion: input.modoExclusion ?? 'acumulable',
      ajuste_automatico: input.ajusteAutomatico ?? false,
      ajuste_producto_id: input.ajusteProductoId ? parseInt(input.ajusteProductoId) : null,
      unidades_por_bloque: input.unidadesPorBloque ?? null,
      stock_por_bloque: input.stockPorBloque ?? null,
      descripcion_regalo: input.descripcionRegalo ?? null,
    })
    .eq('id', id)
    .select()
    .single()

  if (errorPromo) throw errorPromo

  // Reemplazar productos
  await supabase.from('promocion_productos').delete().eq('promocion_id', id)
  if (input.productoIds.length > 0) {
    const { error } = await supabase
      .from('promocion_productos')
      .insert(input.productoIds.map(pid => ({
        promocion_id: parseInt(id),
        producto_id: parseInt(pid),
      })))
    if (error) throw error
  }

  // Reemplazar reglas
  await supabase.from('promocion_reglas').delete().eq('promocion_id', id)
  if (input.reglas.length > 0) {
    const { error } = await supabase
      .from('promocion_reglas')
      .insert(input.reglas.map(r => ({
        promocion_id: parseInt(id),
        clave: r.clave,
        valor: r.valor,
      })))
    if (error) throw error
  }

  const { data: productos } = await supabase
    .from('promocion_productos')
    .select('*')
    .eq('promocion_id', id)

  const { data: reglas } = await supabase
    .from('promocion_reglas')
    .select('*')
    .eq('promocion_id', id)

  return {
    ...(promo as PromocionDB),
    usos_pendientes: (promo as PromocionDB & { usos_pendientes?: number }).usos_pendientes || 0,
    productos: (productos || []) as PromocionProductoDB[],
    reglas: (reglas || []) as PromocionReglaDB[],
  }
}

async function deletePromocion(id: string): Promise<void> {
  const { error } = await supabase
    .from('promociones')
    .delete()
    .eq('id', id)
  if (error) throw error
}

async function togglePromocionActiva(id: string, activo: boolean): Promise<PromocionDB> {
  const { data, error } = await supabase
    .from('promociones')
    .update({ activo })
    .eq('id', id)
    .select()
    .single()
  if (error) throw error
  return data as PromocionDB
}

interface AjustarStockInput {
  promocionId: string
  productoRegaloId: string
  cantidadStock: number
  usosAjustados: number
  usuarioId: string
  observaciones?: string
}

async function ajustarStockPromo(input: AjustarStockInput): Promise<void> {
  const { data, error } = await supabase.rpc('ajustar_stock_promocion_completo', {
    p_promocion_id: parseInt(input.promocionId),
    p_producto_id: parseInt(input.productoRegaloId),
    p_cantidad_stock: input.cantidadStock,
    p_usos_ajustados: input.usosAjustados,
    p_usuario_id: input.usuarioId,
    p_observaciones: input.observaciones || null,
  })
  if (error) throw error
  if (data && typeof data === 'object' && 'success' in data && !(data as { success: boolean }).success) {
    throw new Error((data as { error?: string }).error || 'Error al ajustar stock')
  }
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para obtener el PromoMap denormalizado (para resolución de promos)
 * Cache 5 minutos (más corto que mayorista por ser temporal).
 *
 * Si se pasa `fechaReferencia` (YYYY-MM-DD), se filtra por vigencia a esa fecha
 * en vez de hoy — necesario al editar pedidos antiguos.
 */
export function usePromoMapQuery(fechaReferencia?: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: promocionesKeys.promoMap(currentSucursalId, fechaReferencia),
    queryFn: () => fetchPromoMap(fechaReferencia),
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener todas las promociones con detalles (admin panel)
 */
export function usePromocionesListQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: promocionesKeys.lists(currentSucursalId),
    queryFn: fetchPromocionesList,
    staleTime: 2 * 60 * 1000,
  })
}

export function useCrearPromocionMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: createPromocion,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all(currentSucursalId) })
    },
  })
}

export function useActualizarPromocionMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: updatePromocion,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all(currentSucursalId) })
    },
  })
}

export function useEliminarPromocionMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: deletePromocion,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all(currentSucursalId) })
    },
  })
}

export function useTogglePromocionActivaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) => togglePromocionActiva(id, activo),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para obtener el total de unidades regaladas historicas por cada promo
 * (suma de pedido_items.cantidad con es_bonificacion=true).
 * Multi-tenant: scoped por sucursal activa via RLS.
 */
export function usePromoUnidadesEntregadasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...promocionesKeys.all(currentSucursalId), 'unidades_entregadas'] as const,
    queryFn: async (): Promise<Map<string, number>> => {
      const { data, error } = await supabase
        .from('pedido_items')
        .select('promocion_id, cantidad')
        .eq('es_bonificacion', true)
        .not('promocion_id', 'is', null)
      if (error) {
        if (error.message.includes('does not exist')) return new Map()
        throw error
      }
      const map = new Map<string, number>()
      for (const row of (data ?? []) as { promocion_id: string | number; cantidad: number }[]) {
        const key = String(row.promocion_id)
        map.set(key, (map.get(key) ?? 0) + Number(row.cantidad ?? 0))
      }
      return map
    },
    enabled: !!currentSucursalId,
    staleTime: 60 * 1000,
  })
}

export function useAjustarStockPromoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: ajustarStockPromo,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all(currentSucursalId) })
    },
  })
}
