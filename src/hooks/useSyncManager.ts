/**
 * useSyncManager - Hook para manejar la sincronización automática y manual
 *
 * Extraído de App.tsx para reducir la complejidad del componente principal.
 * Maneja:
 * - Auto-sincronización cuando vuelve la conexión
 * - Sincronización manual
 * - Notificaciones de resultado
 */
import { useCallback, useEffect, useRef } from 'react'
import type { NotifyApi } from './useAppHandlers'
import type { ProductoDB } from '../types/hooks'
import type { StockConflict } from './useOfflineSync'

export interface SyncDependencies {
  // Estado de conexión y pendientes
  isOnline: boolean
  pedidosPendientes: Array<{ offlineId: string }>
  mermasPendientes: Array<{ offlineId: string }>
  sincronizando: boolean

  // Productos actuales para validación de stock
  productos?: ProductoDB[]

  // Funciones de sincronización
  sincronizarPedidos: (
    crearPedidoFn: (...args: unknown[]) => Promise<unknown>,
    descontarStockFn: (...args: unknown[]) => Promise<void>,
    productosActuales?: ProductoDB[]
  ) => Promise<{ sincronizados: number; errores: Array<{ error: string }>; conflictos?: StockConflict[] }>
  sincronizarMermas: (
    registrarMermaFn: (...args: unknown[]) => Promise<unknown>
  ) => Promise<{ sincronizados: number; errores: Array<{ error: string }> }>

  // Funciones de API
  crearPedido: (...args: unknown[]) => Promise<unknown>
  descontarStock: (...args: unknown[]) => Promise<void>
  registrarMerma: (...args: unknown[]) => Promise<unknown>

  // Funciones de refresh
  refetchPedidos: () => Promise<void>
  refetchProductos: () => Promise<void>
  refetchMermas: () => Promise<void>
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
  mermasPendientes,
  productos,
  sincronizarPedidos,
  sincronizarMermas,
  crearPedido,
  descontarStock,
  registrarMerma,
  refetchPedidos,
  refetchProductos,
  refetchMermas,
  refetchMetricas,
  notify
}: SyncDependencies): UseSyncManagerReturn {
  // Ref para evitar doble sincronización
  const isSyncingRef = useRef(false)

  /**
   * Ejecuta la sincronización de pedidos y mermas pendientes
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
          descontarStock as (...args: unknown[]) => Promise<void>,
          productos // Pasar productos actuales para validación
        )

        if (resultadoPedidos.sincronizados > 0) {
          notify.success(`${resultadoPedidos.sincronizados} pedido(s) sincronizado(s)`)
          await refetchPedidos()
          await refetchProductos()
          refetchMetricas()
        }

        // Notificar conflictos de stock (overselling prevenido)
        if (resultadoPedidos.conflictos && resultadoPedidos.conflictos.length > 0) {
          const totalConflictos = resultadoPedidos.conflictos.length
          notify.warning(
            `${totalConflictos} pedido(s) con stock insuficiente. Revise los pedidos fallidos.`,
            { persist: true }
          )
        }

        if (resultadoPedidos.errores.length > 0) {
          notify.error(`${resultadoPedidos.errores.length} pedido(s) no se pudieron sincronizar`)
        }
      }

      // Sincronizar mermas
      if (mermasPendientes.length > 0) {
        const resultadoMermas = await sincronizarMermas(
          registrarMerma as (...args: unknown[]) => Promise<unknown>
        )

        if (resultadoMermas.sincronizados > 0) {
          notify.success(`${resultadoMermas.sincronizados} merma(s) sincronizada(s)`)
          await refetchMermas()
        }

        if (resultadoMermas.errores.length > 0) {
          notify.error(`${resultadoMermas.errores.length} merma(s) no se pudieron sincronizar`)
        }
      }
    } catch (err: unknown) {
      const errorMessage = err instanceof Error ? err.message : 'Error desconocido'
      notify.error('Error durante la sincronizacion: ' + errorMessage)
    } finally {
      isSyncingRef.current = false
    }
  }, [
    pedidosPendientes.length,
    mermasPendientes.length,
    productos,
    sincronizarPedidos,
    sincronizarMermas,
    crearPedido,
    descontarStock,
    registrarMerma,
    refetchPedidos,
    refetchProductos,
    refetchMermas,
    refetchMetricas,
    notify
  ])

  // Auto-sincronizar cuando vuelve la conexión
  useEffect(() => {
    if (isOnline && (pedidosPendientes.length > 0 || mermasPendientes.length > 0)) {
      ejecutarSincronizacion()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOnline])

  // Handler para sincronización manual
  const handleSincronizar = useCallback(async (): Promise<void> => {
    await ejecutarSincronizacion()
  }, [ejecutarSincronizacion])

  return {
    handleSincronizar
  }
}

export default useSyncManager
