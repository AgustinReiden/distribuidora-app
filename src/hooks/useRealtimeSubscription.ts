/**
 * Hook genérico para suscripciones Supabase Realtime
 *
 * Maneja el ciclo de vida de la suscripción:
 * - Subscribe al montar
 * - Unsubscribe al desmontar
 * - Reconexión automática (manejada por Supabase internamente)
 */
import { useEffect, useRef, useState, useCallback } from 'react'
import { supabase } from '../lib/supabase'
// RealtimeChannel type from Supabase used internally via any cast

export type RealtimeEvent = 'INSERT' | 'UPDATE' | 'DELETE' | '*'

export type RealtimeStatus = 'SUBSCRIBING' | 'SUBSCRIBED' | 'CLOSED' | 'CHANNEL_ERROR'

interface UseRealtimeSubscriptionOptions {
  /** Nombre de la tabla a escuchar */
  table: string
  /** Tipo de evento ('INSERT' | 'UPDATE' | 'DELETE' | '*') */
  event?: RealtimeEvent
  /** Schema de la tabla (default: 'public') */
  schema?: string
  /** Callback cuando se recibe un evento */
  onEvent: (payload: unknown) => void
  /** Si la suscripción está habilitada (default: true) */
  enabled?: boolean
}

export function useRealtimeSubscription({
  table,
  event = '*',
  schema = 'public',
  onEvent,
  enabled = true
}: UseRealtimeSubscriptionOptions) {
  const [status, setStatus] = useState<RealtimeStatus>('CLOSED')
  const channelRef = useRef<ReturnType<typeof supabase.channel> | null>(null)
  const onEventRef = useRef(onEvent)

  // Keep callback ref up to date without causing re-subscriptions
  useEffect(() => {
    onEventRef.current = onEvent
  }, [onEvent])

  const unsubscribe = useCallback(() => {
    if (channelRef.current) {
      supabase.removeChannel(channelRef.current)
      channelRef.current = null
      setStatus('CLOSED')
    }
  }, [])

  useEffect(() => {
    if (!enabled) {
      unsubscribe()
      return
    }

    const channelName = `realtime-${table}-${event}-${Date.now()}`

    const channel = (supabase
      .channel(channelName) as any)
      .on(
        'postgres_changes',
        { event, schema, table },
        (payload: unknown) => {
          onEventRef.current(payload)
        }
      )
      .subscribe((status: string) => {
        if (status === 'SUBSCRIBED') {
          setStatus('SUBSCRIBED')
        } else if (status === 'CLOSED') {
          setStatus('CLOSED')
        } else if (status === 'CHANNEL_ERROR') {
          setStatus('CHANNEL_ERROR')
        }
      })

    channelRef.current = channel
    setStatus('SUBSCRIBING')

    return () => {
      supabase.removeChannel(channel)
      channelRef.current = null
    }
  }, [table, event, schema, enabled, unsubscribe])

  return { status, unsubscribe }
}
