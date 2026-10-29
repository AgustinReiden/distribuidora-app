/**
 * Hook genérico para suscripciones Supabase Realtime
 *
 * Maneja el ciclo de vida de la suscripción:
 * - Subscribe al montar
 * - Unsubscribe al desmontar
 * - Reconexión automática (manejada por Supabase internamente)
 *
 * Supabase vuelve a unir el canal solo, pero los cambios que pasaron mientras
 * estuvo caído no se reenvían: al volver, la pantalla sigue con lo que tenía
 * (#1265). Por eso cada vuelta a SUBSCRIBED después de la primera llama a
 * `onReconnect`, para que el que escucha invalide lo que este canal cubría.
 * Cuenta también la vuelta tras `enabled` false → true (sin red): el canal es
 * otro, pero el hueco es el mismo.
 */
import { useEffect, useRef, useState, useCallback } from 'react'
import { supabase } from '../lib/supabase'
// RealtimeChannel type from Supabase used internally via any cast

export type RealtimeEvent = 'INSERT' | 'UPDATE' | 'DELETE' | '*'

export type RealtimeStatus = 'SUBSCRIBING' | 'SUBSCRIBED' | 'CLOSED' | 'CHANNEL_ERROR' | 'TIMED_OUT'

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
  /** Cuando el canal vuelve a SUBSCRIBED después de haber estado caído */
  onReconnect?: () => void
}

export function useRealtimeSubscription({
  table,
  event = '*',
  schema = 'public',
  onEvent,
  enabled = true,
  onReconnect
}: UseRealtimeSubscriptionOptions) {
  const [status, setStatus] = useState<RealtimeStatus>('CLOSED')
  const channelRef = useRef<ReturnType<typeof supabase.channel> | null>(null)
  const onEventRef = useRef(onEvent)
  const onReconnectRef = useRef(onReconnect)
  // Vive fuera del canal: un canal nuevo tras `enabled` false → true también es una vuelta.
  const yaSuscriptoRef = useRef(false)

  // Keep callback ref up to date without causing re-subscriptions
  useEffect(() => {
    onEventRef.current = onEvent
    onReconnectRef.current = onReconnect
  }, [onEvent, onReconnect])

  const unsubscribe = useCallback(() => {
    if (channelRef.current) {
      supabase.removeChannel(channelRef.current)
      channelRef.current = null
      setStatus('CLOSED')
    }
  }, [])

  // El cleanup correcto para Supabase Realtime es `supabase.removeChannel(channel)`,
  // que desuscribe el canal y limpia todos los listeners internos. react-doctor no
  // reconoce este patrón como remove de `.on(...)`, por eso suprimimos.
  // react-doctor-disable-next-line react-doctor/effect-needs-cleanup
  useEffect(() => {
    if (!enabled) {
      unsubscribe()
      return () => {}
    }

    const channelName = `realtime-${schema}-${table}-${event}`

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
          if (yaSuscriptoRef.current) onReconnectRef.current?.()
          yaSuscriptoRef.current = true
          setStatus('SUBSCRIBED')
        } else if (status === 'CLOSED') {
          setStatus('CLOSED')
        } else if (status === 'CHANNEL_ERROR') {
          setStatus('CHANNEL_ERROR')
        } else if (status === 'TIMED_OUT') {
          setStatus('TIMED_OUT')
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
