/**
 * TanStack Query hooks para Promociones
 * Fetch de promos activas y construcción del PromoMap para resolución
 */
import { useQuery } from '@tanstack/react-query'
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
// FETCH FUNCTIONS
// =============================================================================

/**
 * Fetch denormalizado que construye el PromoMap para resolución O(1)
 * Solo trae promociones activas dentro de su rango de fechas.
 */
async function fetchPromoMap(): Promise<PromoMap> {
  const hoy = new Date().toISOString().split('T')[0]

  // 1. Fetch promos activas en rango de fecha
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

  // 2. Fetch productos de esas promos
  const { data: productos, error: errorProductos } = await supabase
    .from('promocion_productos')
    .select('*')
    .in('promocion_id', promoIds)

  if (errorProductos && !errorProductos.message.includes('does not exist')) {
    throw errorProductos
  }

  // 3. Fetch reglas de esas promos
  const { data: reglas, error: errorReglas } = await supabase
    .from('promocion_reglas')
    .select('*')
    .in('promocion_id', promoIds)

  if (errorReglas && !errorReglas.message.includes('does not exist')) {
    throw errorReglas
  }

  // 4. Build PromoMap
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
    }

    for (const productoId of productoIds) {
      const existing = map.get(productoId) || []
      existing.push(promoActiva)
      map.set(productoId, existing)
    }
  }

  return map
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
