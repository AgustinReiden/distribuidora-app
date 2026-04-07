/**
 * TanStack Query hooks para Promociones
 * Fetch de promos activas + CRUD para admin panel + ajuste de stock
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type {
  PromocionDB,
  PromocionProductoDB,
  PromocionReglaDB,
} from '../../types'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

// Query keys
export const promocionesKeys = {
  all: ['promociones'] as const,
  lists: () => [...promocionesKeys.all, 'list'] as const,
  promoMap: () => [...promocionesKeys.all, 'promo_map'] as const,
}

// =============================================================================
// TIPOS PARA ADMIN PANEL
// =============================================================================

export interface PromocionConDetalles extends PromocionDB {
  productos: PromocionProductoDB[]
  reglas: PromocionReglaDB[]
  usos_pendientes: number
}

export interface PromocionFormInput {
  nombre: string
  tipo: 'bonificacion'
  fechaInicio: string
  fechaFin?: string | null
  productoIds: string[]
  productoRegaloId?: string | null
  reglas: { clave: string; valor: number }[]
}

// =============================================================================
// FETCH FUNCTIONS
// =============================================================================

/**
 * Fetch denormalizado que construye el PromoMap para resolución O(1)
 * Solo trae promociones activas dentro de su rango de fechas.
 */
async function fetchPromoMap(): Promise<PromoMap> {
  const hoy = new Date().toISOString().split('T')[0]

  const { data: promos, error: errorPromos } = await supabase
    .from('promociones')
    .select('*')
    .eq('activo', true)
    .lte('fecha_inicio', hoy)
    .or(`fecha_fin.is.null,fecha_fin.gte.${hoy}`)

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
      producto_regalo_id: input.productoRegaloId ? parseInt(input.productoRegaloId) : null,
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
      producto_regalo_id: input.productoRegaloId ? parseInt(input.productoRegaloId) : null,
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
  usosAjustados: number
  usuarioId: string
  observaciones?: string
}

async function ajustarStockPromo(input: AjustarStockInput): Promise<void> {
  // 1. Insertar registro en promo_ajustes
  const { error: errorAjuste } = await supabase
    .from('promo_ajustes')
    .insert([{
      promocion_id: parseInt(input.promocionId),
      usos_ajustados: input.usosAjustados,
      usuario_id: input.usuarioId,
      observaciones: input.observaciones || null,
    }])
  if (errorAjuste) throw errorAjuste

  // 2. Resetear usos_pendientes a 0
  const { error: errorReset } = await supabase
    .from('promociones')
    .update({ usos_pendientes: 0 })
    .eq('id', input.promocionId)
  if (errorReset) throw errorReset
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Hook para obtener el PromoMap denormalizado (para resolución de promos)
 * Cache 5 minutos (más corto que mayorista por ser temporal)
 */
export function usePromoMapQuery() {
  return useQuery({
    queryKey: promocionesKeys.promoMap(),
    queryFn: fetchPromoMap,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener todas las promociones con detalles (admin panel)
 */
export function usePromocionesListQuery() {
  return useQuery({
    queryKey: promocionesKeys.lists(),
    queryFn: fetchPromocionesList,
    staleTime: 2 * 60 * 1000,
  })
}

export function useCrearPromocionMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: createPromocion,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all })
    },
  })
}

export function useActualizarPromocionMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: updatePromocion,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all })
    },
  })
}

export function useEliminarPromocionMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: deletePromocion,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all })
    },
  })
}

export function useTogglePromocionActivaMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) => togglePromocionActiva(id, activo),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all })
    },
  })
}

export function useAjustarStockPromoMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ajustarStockPromo,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: promocionesKeys.all })
    },
  })
}
