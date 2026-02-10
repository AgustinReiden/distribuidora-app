/**
 * Hook que integra Supabase Realtime con TanStack Query
 *
 * Cuando otro usuario modifica pedidos o productos, este hook
 * invalida los queries correspondientes para que TanStack Query
 * los re-fetche automáticamente.
 *
 * Usa debounce de 300ms para agrupar cambios rápidos (ej: batch de stock).
 */
import { useRef, useCallback } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useRealtimeSubscription } from './useRealtimeSubscription'
import { pedidosKeys } from './queries/usePedidosQuery'
import { productosKeys } from './queries/useProductosQuery'

interface UseRealtimeInvalidationOptions {
  /** Si está habilitado (desactivar cuando offline) */
  enabled?: boolean
  /** Delay de debounce en ms (default: 300) */
  debounceMs?: number
}

export function useRealtimeInvalidation({
  enabled = true,
  debounceMs = 300
}: UseRealtimeInvalidationOptions = {}) {
  const queryClient = useQueryClient()
  const pedidosTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const productosTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const invalidatePedidos = useCallback(() => {
    if (pedidosTimerRef.current) {
      clearTimeout(pedidosTimerRef.current)
    }
    pedidosTimerRef.current = setTimeout(() => {
      queryClient.invalidateQueries({ queryKey: pedidosKeys.all })
    }, debounceMs)
  }, [queryClient, debounceMs])

  const invalidateProductos = useCallback(() => {
    if (productosTimerRef.current) {
      clearTimeout(productosTimerRef.current)
    }
    productosTimerRef.current = setTimeout(() => {
      queryClient.invalidateQueries({ queryKey: productosKeys.all })
    }, debounceMs)
  }, [queryClient, debounceMs])

  const { status: pedidosStatus } = useRealtimeSubscription({
    table: 'pedidos',
    event: '*',
    onEvent: invalidatePedidos,
    enabled
  })

  const { status: productosStatus } = useRealtimeSubscription({
    table: 'productos',
    event: 'UPDATE',
    onEvent: invalidateProductos,
    enabled
  })

  return {
    pedidosStatus,
    productosStatus,
    isConnected: pedidosStatus === 'SUBSCRIBED' && productosStatus === 'SUBSCRIBED'
  }
}
