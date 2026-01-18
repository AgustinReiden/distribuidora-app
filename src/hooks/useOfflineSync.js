import { useState, useEffect, useCallback } from 'react'
import {
  getSecureItem,
  setSecureItem,
  removeSecureItem,
  migrateToSecure
} from '../utils/secureStorage'

const OFFLINE_PEDIDOS_KEY = 'pedidos'
const OFFLINE_MERMAS_KEY = 'mermas'

// Claves legacy para migracion
const LEGACY_PEDIDOS_KEY = 'offline_pedidos'
const LEGACY_MERMAS_KEY = 'offline_mermas'

// Hook para manejar sincronización offline
export function useOfflineSync() {
  const [isOnline, setIsOnline] = useState(navigator.onLine)
  const [pedidosPendientes, setPedidosPendientes] = useState([])
  const [mermasPendientes, setMermasPendientes] = useState([])
  const [sincronizando, setSincronizando] = useState(false)

  // Cargar pedidos pendientes del secureStorage (con migracion de datos legacy)
  useEffect(() => {
    const loadOfflineData = async () => {
      // Migrar datos legacy si existen
      await migrateToSecure(LEGACY_PEDIDOS_KEY, OFFLINE_PEDIDOS_KEY)
      await migrateToSecure(LEGACY_MERMAS_KEY, OFFLINE_MERMAS_KEY)

      // Cargar pedidos desde almacenamiento seguro
      const storedPedidos = await getSecureItem(OFFLINE_PEDIDOS_KEY, [])
      if (Array.isArray(storedPedidos)) {
        setPedidosPendientes(storedPedidos)
      }

      // Cargar mermas desde almacenamiento seguro
      const storedMermas = await getSecureItem(OFFLINE_MERMAS_KEY, [])
      if (Array.isArray(storedMermas)) {
        setMermasPendientes(storedMermas)
      }
    }

    loadOfflineData()
  }, [])

  // Escuchar cambios de conexión
  useEffect(() => {
    const handleOnline = () => setIsOnline(true)
    const handleOffline = () => setIsOnline(false)

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)

    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [])

  // Guardar pedido offline
  const guardarPedidoOffline = useCallback((pedidoData) => {
    const nuevoPedido = {
      ...pedidoData,
      offlineId: `offline_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      creadoOffline: new Date().toISOString(),
      sincronizado: false
    }

    setPedidosPendientes(prev => {
      const updated = [...prev, nuevoPedido]
      // Guardar async sin bloquear
      setSecureItem(OFFLINE_PEDIDOS_KEY, updated).catch(() => {})
      return updated
    })

    return nuevoPedido
  }, [])

  // Guardar merma offline
  const guardarMermaOffline = useCallback((mermaData) => {
    const nuevaMerma = {
      ...mermaData,
      offlineId: `offline_merma_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      creadoOffline: new Date().toISOString(),
      sincronizado: false
    }

    setMermasPendientes(prev => {
      const updated = [...prev, nuevaMerma]
      // Guardar async sin bloquear
      setSecureItem(OFFLINE_MERMAS_KEY, updated).catch(() => {})
      return updated
    })

    return nuevaMerma
  }, [])

  // Eliminar pedido offline (despues de sincronizar)
  const eliminarPedidoOffline = useCallback((offlineId) => {
    setPedidosPendientes(prev => {
      const updated = prev.filter(p => p.offlineId !== offlineId)
      // Guardar async sin bloquear
      setSecureItem(OFFLINE_PEDIDOS_KEY, updated).catch(() => {})
      return updated
    })
  }, [])

  // Eliminar merma offline (despues de sincronizar)
  const eliminarMermaOffline = useCallback((offlineId) => {
    setMermasPendientes(prev => {
      const updated = prev.filter(m => m.offlineId !== offlineId)
      // Guardar async sin bloquear
      setSecureItem(OFFLINE_MERMAS_KEY, updated).catch(() => {})
      return updated
    })
  }, [])

  // Sincronizar pedidos pendientes
  const sincronizarPedidos = useCallback(async (crearPedidoFn, descontarStockFn) => {
    if (!isOnline || pedidosPendientes.length === 0) return { success: true, sincronizados: 0, errores: [] }

    setSincronizando(true)
    const errores = []
    let sincronizados = 0

    for (const pedido of pedidosPendientes) {
      try {
        await crearPedidoFn(
          pedido.clienteId,
          pedido.items,
          pedido.total,
          pedido.usuarioId,
          descontarStockFn,
          pedido.notas,
          pedido.formaPago,
          pedido.estadoPago
        )
        eliminarPedidoOffline(pedido.offlineId)
        sincronizados++
      } catch (error) {
        errores.push({ pedido, error: error.message })
      }
    }

    setSincronizando(false)
    return { success: errores.length === 0, sincronizados, errores }
  }, [isOnline, pedidosPendientes, eliminarPedidoOffline])

  // Sincronizar mermas pendientes
  const sincronizarMermas = useCallback(async (registrarMermaFn) => {
    if (!isOnline || mermasPendientes.length === 0) return { success: true, sincronizados: 0, errores: [] }

    setSincronizando(true)
    const errores = []
    let sincronizados = 0

    for (const merma of mermasPendientes) {
      try {
        await registrarMermaFn(merma)
        eliminarMermaOffline(merma.offlineId)
        sincronizados++
      } catch (error) {
        errores.push({ merma, error: error.message })
      }
    }

    setSincronizando(false)
    return { success: errores.length === 0, sincronizados, errores }
  }, [isOnline, mermasPendientes, eliminarMermaOffline])

  // Limpiar todos los pedidos offline
  const limpiarPedidosOffline = useCallback(() => {
    setPedidosPendientes([])
    removeSecureItem(OFFLINE_PEDIDOS_KEY)
  }, [])

  return {
    isOnline,
    pedidosPendientes,
    mermasPendientes,
    sincronizando,
    guardarPedidoOffline,
    guardarMermaOffline,
    eliminarPedidoOffline,
    eliminarMermaOffline,
    sincronizarPedidos,
    sincronizarMermas,
    limpiarPedidosOffline,
    cantidadPendientes: pedidosPendientes.length + mermasPendientes.length
  }
}
