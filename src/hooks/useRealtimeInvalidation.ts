/**
 * Hook que integra Supabase Realtime con TanStack Query
 *
 * Cuando otro usuario modifica pedidos o productos, este hook
 * invalida los queries correspondientes para que TanStack Query
 * los re-fetche automáticamente.
 *
 * - pedidos y pedido_items, cualquier evento → invalida `pedidosKeys.all()`
 * - productos UPDATE → invalida productos (coarse, es suficiente)
 *
 * Usa debounce de 300ms para agrupar cambios rápidos (ej: batch de stock).
 */
import { useRef, useCallback, useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useRealtimeSubscription } from './useRealtimeSubscription'
import { useSucursal } from '../contexts/SucursalContext'
import { pedidosKeys } from './queries/usePedidosQuery'
import { productosKeys } from './queries/useProductosQuery'

interface UseRealtimeInvalidationOptions {
  /** Si está habilitado (desactivar cuando offline) */
  enabled?: boolean
  /** Delay de debounce en ms (default: 300) */
  debounceMs?: number
}

/**
 * Extrae un id string de un payload de Supabase realtime.
 * Soporta new/old con id numérico o string.
 */
function extractId(row: unknown): string | null {
  if (!row || typeof row !== 'object') return null
  const id = (row as { id?: unknown }).id
  if (id == null) return null
  return String(id)
}

function extractPedidoIdFromItem(row: unknown): string | null {
  if (!row || typeof row !== 'object') return null
  const pedidoId = (row as { pedido_id?: unknown }).pedido_id
  if (pedidoId == null) return null
  return String(pedidoId)
}

type RealtimePayload = {
  eventType?: 'INSERT' | 'UPDATE' | 'DELETE'
  new?: unknown
  old?: unknown
}

export function useRealtimeInvalidation({
  enabled = true,
  debounceMs = 300
}: UseRealtimeInvalidationOptions = {}) {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  const pedidosListTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const productosTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Invalida pedidosKeys.all(): pedidosKeys.lists() y .detail() son keys que
  // ninguna query lee (la pantalla usa `paginated` y `stats`, ambas hijas de
  // `.all()`), así que invalidarlas no refrescaba nada — el realtime de
  // pedidos no actualizaba la pantalla ante cambios de otro usuario (#524).
  const invalidatePedidosList = useCallback(() => {
    if (!enabled) return
    if (pedidosListTimerRef.current) {
      clearTimeout(pedidosListTimerRef.current)
    }
    pedidosListTimerRef.current = setTimeout(() => {
      queryClient.invalidateQueries({
        queryKey: pedidosKeys.all(currentSucursalId)
      })
      pedidosListTimerRef.current = null
    }, debounceMs)
  }, [queryClient, debounceMs, enabled, currentSucursalId])

  // Comparte el timer de la lista a propósito: como todo termina invalidando
  // `.all()`, un timer por pedido no agrupaba nada. Armar un reparto cambia
  // decenas de pedidos en un segundo, y eran decenas de recargas de todos los
  // pedidos en cada pantalla abierta (~180 consultas en 5 s, la lista a 5 s).
  const invalidatePedido = useCallback((_pedidoId: string) => {
    invalidatePedidosList()
  }, [invalidatePedidosList])

  const invalidateProductos = useCallback(() => {
    if (!enabled) return
    if (productosTimerRef.current) {
      clearTimeout(productosTimerRef.current)
    }
    productosTimerRef.current = setTimeout(() => {
      queryClient.invalidateQueries({
        queryKey: productosKeys.all(currentSucursalId)
      })
      productosTimerRef.current = null
    }, debounceMs)
  }, [queryClient, debounceMs, enabled, currentSucursalId])

  // Handler para eventos de la tabla pedidos — enrutamiento granular
  const handlePedidosEvent = useCallback((payload: unknown) => {
    const p = (payload || {}) as RealtimePayload
    const eventType = p.eventType
    if (eventType === 'INSERT') {
      // Fila nueva: la lista cambia
      invalidatePedidosList()
      return
    }
    if (eventType === 'UPDATE') {
      const id = extractId(p.new)
      if (id) {
        invalidatePedido(id)
      } else {
        // Fallback si no hay id (no debería pasar)
        invalidatePedidosList()
      }
      return
    }
    if (eventType === 'DELETE') {
      const id = extractId(p.old)
      if (id) invalidatePedido(id)
      invalidatePedidosList()
      return
    }
    // Evento desconocido: ser conservador e invalidar la lista
    invalidatePedidosList()
  }, [invalidatePedido, invalidatePedidosList])

  // Handler para cambios en pedido_items — invalida detail del pedido padre
  const handlePedidoItemsEvent = useCallback((payload: unknown) => {
    const p = (payload || {}) as RealtimePayload
    const pedidoId =
      extractPedidoIdFromItem(p.new) || extractPedidoIdFromItem(p.old)
    if (pedidoId) {
      invalidatePedido(pedidoId)
    } else {
      // Fallback
      invalidatePedidosList()
    }
  }, [invalidatePedido, invalidatePedidosList])

  // Handler para productos — granularidad coarse es suficiente
  const handleProductosEvent = useCallback(() => {
    invalidateProductos()
  }, [invalidateProductos])

  // Limpiar timers de debounce al desmontar para prevenir memory leaks
  useEffect(() => {
    return () => {
      if (pedidosListTimerRef.current) {
        clearTimeout(pedidosListTimerRef.current)
      }
      if (productosTimerRef.current) {
        clearTimeout(productosTimerRef.current)
      }
    }
  }, [])

  // `onReconnect`: lo que cambió mientras el canal estuvo caído no llega como
  // evento (#1265). Con staleTime de 5 minutos, sin esto se seguía viendo el
  // stock y los pedidos de antes del corte.
  const { status: pedidosStatus } = useRealtimeSubscription({
    table: 'pedidos',
    event: '*',
    onEvent: handlePedidosEvent,
    onReconnect: invalidatePedidosList,
    enabled
  })

  const { status: pedidoItemsStatus } = useRealtimeSubscription({
    table: 'pedido_items',
    event: '*',
    onEvent: handlePedidoItemsEvent,
    onReconnect: invalidatePedidosList,
    enabled
  })

  const { status: productosStatus } = useRealtimeSubscription({
    table: 'productos',
    event: 'UPDATE',
    onEvent: handleProductosEvent,
    onReconnect: invalidateProductos,
    enabled
  })

  return {
    pedidosStatus,
    pedidoItemsStatus,
    productosStatus,
    isConnected:
      pedidosStatus === 'SUBSCRIBED' &&
      pedidoItemsStatus === 'SUBSCRIBED' &&
      productosStatus === 'SUBSCRIBED',
    // Invalidadores granulares expuestos para uso externo / testing
    invalidatePedido,
    invalidatePedidosList,
    invalidateProductos,
  }
}
