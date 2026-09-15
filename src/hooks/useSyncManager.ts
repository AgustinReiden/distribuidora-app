/**
 * useSyncManager - Hook para manejar la sincronización automática y manual
 *
 * Extraído de App.tsx para reducir la complejidad del componente principal.
 * Maneja:
 * - Auto-sincronización cuando vuelve la conexión
 * - Sincronización manual
 * - Notificaciones de resultado
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import type { NotifyApi } from '../types/ui'
import type { ProductoDB } from '../types/hooks'
import type { StockConflict } from './useOfflineSync'
import { useLatestRef } from './useLatestRef'

/**
 * Ventana mínima entre dos auto-sincronizaciones.
 *
 * EL BUG QUE ARREGLA. El efecto de auto-sync depende de
 * `ejecutarSincronizacion`, que dependía de `notify`, y el value de
 * NotificationContext se recreaba en cada render. Cada `notify.error` del
 * propio sync volvía a disparar el efecto, sin espera: los 5 reintentos de la
 * operación se consumían en segundos y el pedido quedaba en `failed`, fuera de
 * `getPendingOperations`. Pasaba justo al reconectar con el JWT vencido.
 *
 * `notify` ya no está en las dependencias, pero la ventana queda igual: el
 * efecto depende de cosas que la app puede recrear en cualquier render, y la
 * garantía que importa —un fallo no gasta más de un reintento por ventana— no
 * tiene que depender de que ninguna de ellas se desestabilice nunca más.
 */
export const VENTANA_AUTOSYNC_MS = 30_000

export interface SyncDependencies {
  // Estado de conexión y pendientes
  isOnline: boolean
  pedidosPendientes: Array<{ offlineId: string }>
  sincronizando: boolean

  // Productos actuales para validación de stock
  productos?: ProductoDB[]

  // Funciones de sincronización
  sincronizarPedidos: (
    crearPedidoFn: (...args: unknown[]) => Promise<unknown>,
    productosActuales?: ProductoDB[]
  ) => Promise<{ sincronizados: number; errores: Array<{ error: string }>; conflictos?: StockConflict[] }>

  // Funciones de API
  crearPedido: (...args: unknown[]) => Promise<unknown>

  // Funciones de refresh
  refetchPedidos: () => Promise<void>
  refetchProductos: () => Promise<void>
  refetchMetricas: () => Promise<void>

  // Notificaciones
  notify: NotifyApi
}

export interface UseSyncManagerReturn {
  handleSincronizar: () => Promise<void>
}

/**
 * Hook que encapsula toda la lógica de sincronización online/offline
 */
export function useSyncManager({
  isOnline,
  pedidosPendientes,
  productos,
  sincronizarPedidos,
  crearPedido,
  refetchPedidos,
  refetchProductos,
  refetchMetricas,
  notify
}: SyncDependencies): UseSyncManagerReturn {
  // Ref para evitar doble sincronización
  const isSyncingRef = useRef(false)

  // `notify` fuera de las dependencias: su identidad cambia en cada render del
  // provider y re-disparaba el efecto de auto-sync (ver VENTANA_AUTOSYNC_MS).
  const notifyRef = useLatestRef(notify)

  /**
   * Ejecuta la sincronización de pedidos pendientes
   * Valida stock actual antes de sincronizar para evitar overselling
   */
  const ejecutarSincronizacion = useCallback(async (): Promise<void> => {
    if (isSyncingRef.current) return
    isSyncingRef.current = true

    try {
      // Sincronizar pedidos (pasando productos para validación de stock)
      if (pedidosPendientes.length > 0) {
        const resultadoPedidos = await sincronizarPedidos(
          crearPedido as (...args: unknown[]) => Promise<unknown>,
          productos // Pasar productos actuales para validación
        )

        if (resultadoPedidos.sincronizados > 0) {
          notifyRef.current.success(`${resultadoPedidos.sincronizados} pedido(s) sincronizado(s)`)
          await refetchPedidos()
          await refetchProductos()
          refetchMetricas()
        }

        // Notificar conflictos de stock (overselling prevenido)
        if (resultadoPedidos.conflictos && resultadoPedidos.conflictos.length > 0) {
          const totalConflictos = resultadoPedidos.conflictos.length
          notifyRef.current.warning(
            `${totalConflictos} pedido(s) con stock insuficiente. Revise los pedidos fallidos.`,
            { persist: true }
          )
        }

        if (resultadoPedidos.errores.length > 0) {
          notifyRef.current.error(`${resultadoPedidos.errores.length} pedido(s) no se pudieron sincronizar`)
        }
      }
    } catch (err: unknown) {
      const errorMessage = err instanceof Error ? err.message : 'Error desconocido'
      notifyRef.current.error('Error durante la sincronizacion: ' + errorMessage)
    } finally {
      isSyncingRef.current = false
    }
  }, [
    pedidosPendientes.length,
    productos,
    sincronizarPedidos,
    crearPedido,
    refetchPedidos,
    refetchProductos,
    refetchMetricas,
    notifyRef
  ])

  // Auto-sincronizar cuando vuelve la conexión, como mucho una vez por ventana.
  // `reintento` es lo que despierta al efecto cuando la ventana se cumple: sin
  // él, un fallo dejaría la cola esperando al próximo render que pase por acá.
  const ultimoAutoSyncRef = useRef(0)
  const [reintento, setReintento] = useState(0)

  useEffect(() => {
    if (!isOnline) return
    if (pedidosPendientes.length === 0) return

    const restante = VENTANA_AUTOSYNC_MS - (Date.now() - ultimoAutoSyncRef.current)
    if (restante > 0) {
      const timer = setTimeout(() => setReintento(n => n + 1), restante)
      return () => clearTimeout(timer)
    }

    ultimoAutoSyncRef.current = Date.now()
    void ejecutarSincronizacion().finally(() => {
      // Reprograma la próxima ventana si algo quedó pendiente. Si la cola se
      // vació, el efecto sale por el guard de arriba y no vuelve a correr.
      setReintento(n => n + 1)
    })
  }, [isOnline, ejecutarSincronizacion, pedidosPendientes.length, reintento])

  // Handler para sincronización manual
  const handleSincronizar = useCallback(async (): Promise<void> => {
    // El botón no espera ninguna ventana: lo tocó una persona. Pero sí la
    // reinicia, para que el automático no dispare atrás del manual.
    ultimoAutoSyncRef.current = Date.now()
    await ejecutarSincronizacion()
  }, [ejecutarSincronizacion])

  return {
    handleSincronizar
  }
}

export default useSyncManager
