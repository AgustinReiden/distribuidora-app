/**
 * Hook que integra Supabase Realtime con TanStack Query
 *
 * Cuando otro usuario modifica pedidos o productos, este hook
 * invalida los queries correspondientes para que TanStack Query
 * los re-fetche automáticamente.
 *
 * Invalidación granular basada en el payload de Supabase:
 * - INSERT en pedidos → invalida la lista (aparece una fila nueva)
 * - UPDATE en pedidos → invalida solo el detail del pedido afectado
 * - DELETE en pedidos → invalida detail (se borra) + lista (se achica)
 * - pedido_items * → invalida el detail del pedido padre
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

  // Un timer por pedido-id para debounce granular por detail
  const pedidoDetailTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map())
  const pedidosListTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const productosTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const invalidatePedido = useCallback((pedidoId: string) => {
    if (!enabled) return
    const existing = pedidoDetailTimersRef.current.get(pedidoId)
    if (existing) clearTimeout(existing)
    const t = setTimeout(() => {
      queryClient.invalidateQueries({
        queryKey: pedidosKeys.detail(currentSucursalId, pedidoId)
      })
      pedidoDetailTimersRef.current.delete(pedidoId)
    }, debounceMs)
    pedidoDetailTimersRef.current.set(pedidoId, t)
  }, [queryClient, debounceMs, enabled, currentSucursalId])

  const invalidatePedidosList = useCallback(() => {
    if (!enabled) return
    if (pedidosListTimerRef.current) {
      clearTimeout(pedidosListTimerRef.current)
    }
    pedidosListTimerRef.current = setTimeout(() => {
      queryClient.invalidateQueries({
        queryKey: pedidosKeys.lists(currentSucursalId)
      })
      pedidosListTimerRef.current = null
    }, debounceMs)
  }, [queryClient, debounceMs, enabled, currentSucursalId])

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
    const detailTimers = pedidoDetailTimersRef.current
    return () => {
      for (const t of detailTimers.values()) {
        clearTimeout(t)
      }
      detailTimers.clear()
      if (pedidosListTimerRef.current) {
        clearTimeout(pedidosListTimerRef.current)
      }
      if (productosTimerRef.current) {
        clearTimeout(productosTimerRef.current)
      }
    }
  }, [])

  const { status: pedidosStatus } = useRealtimeSubscription({
    table: 'pedidos',
    event: '*',
    onEvent: handlePedidosEvent,
    enabled
  })

  const { status: pedidoItemsStatus } = useRealtimeSubscription({
    table: 'pedido_items',
    event: '*',
    onEvent: handlePedidoItemsEvent,
    enabled
  })

  const { status: productosStatus } = useRealtimeSubscription({
    table: 'productos',
    event: 'UPDATE',
    onEvent: handleProductosEvent,
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
