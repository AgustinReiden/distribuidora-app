import { useState, useEffect, useCallback, useRef } from 'react'
import {
  getSecureItem,
  setSecureItem,
  removeSecureItem,
  migrateToSecure
} from '../utils/secureStorage'
import type { MermaFormInput, ProductoDB } from '../types'

// ============================================================================
// TYPES
// ============================================================================

export interface PedidoOfflineItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
  nombre?: string;
}

export interface StockSnapshot {
  [productoId: string]: {
    stockAlMomento: number;
    reservadoOffline: number;
    disponible: number;
  };
}

export interface PedidoOffline {
  offlineId: string;
  clienteId: string | number;
  items: PedidoOfflineItem[];
  total: number;
  usuarioId?: string;
  notas?: string;
  formaPago?: string;
  estadoPago?: string;
  montoPagado?: number;
  creadoOffline: string;
  sincronizado: boolean;
  stockSnapshot?: StockSnapshot;
}

export interface MermaOffline extends MermaFormInput {
  offlineId: string;
  creadoOffline: string;
  sincronizado: boolean;
}

export interface GuardarPedidoOptions {
  productos?: ProductoDB[];
  validarStock?: boolean;
}

export interface ItemSinStock {
  productoId: string;
  nombre: string;
  solicitado: number;
  disponible: number;
}

export interface GuardarPedidoResult {
  success: boolean;
  pedido?: PedidoOffline;
  error?: string;
  itemsSinStock?: ItemSinStock[];
}

export interface SyncResult {
  success: boolean;
  sincronizados: number;
  errores: Array<{ pedido?: PedidoOffline; merma?: MermaOffline; error: string }>;
}

export interface CrearPedidoFunction {
  (
    clienteId: string | number,
    items: PedidoOfflineItem[],
    total: number,
    usuarioId?: string,
    descontarStockFn?: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>,
    notas?: string,
    formaPago?: string,
    estadoPago?: string
  ): Promise<unknown>;
}

export interface RegistrarMermaFunction {
  (merma: MermaFormInput, usuarioId?: string): Promise<unknown>;
}

export interface UseOfflineSyncReturn {
  isOnline: boolean;
  pedidosPendientes: PedidoOffline[];
  mermasPendientes: MermaOffline[];
  sincronizando: boolean;
  guardarPedidoOffline: (
    pedidoData: Omit<PedidoOffline, 'offlineId' | 'creadoOffline' | 'sincronizado'>,
    options?: GuardarPedidoOptions
  ) => GuardarPedidoResult;
  guardarMermaOffline: (mermaData: MermaFormInput) => MermaOffline;
  eliminarPedidoOffline: (offlineId: string) => void;
  eliminarMermaOffline: (offlineId: string) => void;
  sincronizarPedidos: (
    crearPedidoFn: CrearPedidoFunction,
    descontarStockFn: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>
  ) => Promise<SyncResult>;
  sincronizarMermas: (registrarMermaFn: RegistrarMermaFunction) => Promise<SyncResult>;
  limpiarPedidosOffline: () => void;
  cantidadPendientes: number;
}

// ============================================================================
// CONSTANTS
// ============================================================================

const OFFLINE_PEDIDOS_KEY = 'pedidos'
const OFFLINE_MERMAS_KEY = 'mermas'

// Claves legacy para migracion
const LEGACY_PEDIDOS_KEY = 'offline_pedidos'
const LEGACY_MERMAS_KEY = 'offline_mermas'

// ============================================================================
// HOOK
// ============================================================================

/**
 * Hook para manejar sincronización offline de pedidos y mermas
 */
export function useOfflineSync(): UseOfflineSyncReturn {
  const [isOnline, setIsOnline] = useState<boolean>(navigator.onLine)
  const [pedidosPendientes, setPedidosPendientes] = useState<PedidoOffline[]>([])
  const [mermasPendientes, setMermasPendientes] = useState<MermaOffline[]>([])
  const [sincronizando, setSincronizando] = useState<boolean>(false)

  // Ref para evitar race conditions en sincronización
  const sincronizandoRef = useRef<boolean>(false)

  // Cargar pedidos pendientes del secureStorage (con migracion de datos legacy)
  useEffect(() => {
    const loadOfflineData = async (): Promise<void> => {
      // Migrar datos legacy si existen
      await migrateToSecure(LEGACY_PEDIDOS_KEY, OFFLINE_PEDIDOS_KEY)
      await migrateToSecure(LEGACY_MERMAS_KEY, OFFLINE_MERMAS_KEY)

      // Cargar pedidos desde almacenamiento seguro
      const storedPedidos = await getSecureItem<PedidoOffline[]>(OFFLINE_PEDIDOS_KEY, [])
      if (Array.isArray(storedPedidos)) {
        setPedidosPendientes(storedPedidos)
      }

      // Cargar mermas desde almacenamiento seguro
      const storedMermas = await getSecureItem<MermaOffline[]>(OFFLINE_MERMAS_KEY, [])
      if (Array.isArray(storedMermas)) {
        setMermasPendientes(storedMermas)
      }
    }

    loadOfflineData()
  }, [])

  // Escuchar cambios de conexión
  useEffect(() => {
    const handleOnline = (): void => setIsOnline(true)
    const handleOffline = (): void => setIsOnline(false)

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)

    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [])

  /**
   * Guarda un pedido en modo offline con validación de stock
   * @param pedidoData - Datos del pedido
   * @param options - Opciones de validación
   * @returns Resultado con el pedido guardado o errores de validación
   */
  const guardarPedidoOffline = useCallback((
    pedidoData: Omit<PedidoOffline, 'offlineId' | 'creadoOffline' | 'sincronizado'>,
    options: GuardarPedidoOptions = {}
  ): GuardarPedidoResult => {
    const { productos = [], validarStock = true } = options

    // Validar stock si se proporciona lista de productos
    if (validarStock && productos.length > 0 && pedidoData.items?.length > 0) {
      const itemsSinStock: ItemSinStock[] = []
      const stockSnapshot: StockSnapshot = {}

      // Calcular stock considerando pedidos offline pendientes
      const stockReservado: Record<string, number> = {}
      pedidosPendientes.forEach(pedido => {
        pedido.items?.forEach(item => {
          stockReservado[item.productoId] = (stockReservado[item.productoId] || 0) + item.cantidad
        })
      })

      for (const item of pedidoData.items) {
        const producto = productos.find(p => p.id === item.productoId)
        if (producto) {
          const stockActual = producto.stock || 0
          const reservado = stockReservado[item.productoId] || 0
          const stockDisponible = stockActual - reservado

          stockSnapshot[item.productoId] = {
            stockAlMomento: stockActual,
            reservadoOffline: reservado,
            disponible: stockDisponible
          }

          if (item.cantidad > stockDisponible) {
            itemsSinStock.push({
              productoId: item.productoId,
              nombre: producto.nombre || item.nombre || 'Producto desconocido',
              solicitado: item.cantidad,
              disponible: Math.max(0, stockDisponible)
            })
          }
        }
      }

      if (itemsSinStock.length > 0) {
        return {
          success: false,
          error: 'Stock insuficiente para algunos productos',
          itemsSinStock
        }
      }

      // Agregar snapshot de stock al pedido para detección de conflictos
      pedidoData = { ...pedidoData, stockSnapshot }
    }

    const nuevoPedido: PedidoOffline = {
      ...pedidoData,
      offlineId: `offline_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      creadoOffline: new Date().toISOString(),
      sincronizado: false
    }

    setPedidosPendientes(prev => {
      const updated = [...prev, nuevoPedido]
      // Guardar async sin bloquear - con manejo de errores
      setSecureItem(OFFLINE_PEDIDOS_KEY, updated).catch((err) => {
        console.error('Error crítico: No se pudo guardar pedido offline:', err)
        // Intentar notificar al usuario via evento custom
        window.dispatchEvent(new CustomEvent('offline-storage-error', {
          detail: { type: 'pedido', error: err.message }
        }))
      })
      return updated
    })

    return { success: true, pedido: nuevoPedido }
  }, [pedidosPendientes])

  /**
   * Guarda una merma en modo offline
   * @param mermaData - Datos de la merma
   * @returns La merma guardada con metadatos offline
   */
  const guardarMermaOffline = useCallback((mermaData: MermaFormInput): MermaOffline => {
    const nuevaMerma: MermaOffline = {
      ...mermaData,
      offlineId: `offline_merma_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      creadoOffline: new Date().toISOString(),
      sincronizado: false
    }

    setMermasPendientes(prev => {
      const updated = [...prev, nuevaMerma]
      // Guardar async sin bloquear - con manejo de errores
      setSecureItem(OFFLINE_MERMAS_KEY, updated).catch((err) => {
        console.error('Error crítico: No se pudo guardar merma offline:', err)
        window.dispatchEvent(new CustomEvent('offline-storage-error', {
          detail: { type: 'merma', error: err.message }
        }))
      })
      return updated
    })

    return nuevaMerma
  }, [])

  /**
   * Elimina un pedido offline (después de sincronizar)
   * @param offlineId - ID del pedido offline a eliminar
   */
  const eliminarPedidoOffline = useCallback((offlineId: string): void => {
    setPedidosPendientes(prev => {
      const updated = prev.filter(p => p.offlineId !== offlineId)
      // Guardar async sin bloquear - con manejo de errores
      setSecureItem(OFFLINE_PEDIDOS_KEY, updated).catch((err) => {
        console.error('Error al actualizar pedidos offline:', err)
      })
      return updated
    })
  }, [])

  /**
   * Elimina una merma offline (después de sincronizar)
   * @param offlineId - ID de la merma offline a eliminar
   */
  const eliminarMermaOffline = useCallback((offlineId: string): void => {
    setMermasPendientes(prev => {
      const updated = prev.filter(m => m.offlineId !== offlineId)
      // Guardar async sin bloquear - con manejo de errores
      setSecureItem(OFFLINE_MERMAS_KEY, updated).catch((err) => {
        console.error('Error al actualizar mermas offline:', err)
      })
      return updated
    })
  }, [])

  /**
   * Sincroniza todos los pedidos pendientes con el servidor
   * @param crearPedidoFn - Función para crear pedidos en el servidor
   * @param descontarStockFn - Función para descontar stock
   * @returns Resultado de la sincronización
   */
  const sincronizarPedidos = useCallback(async (
    crearPedidoFn: CrearPedidoFunction,
    descontarStockFn: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>
  ): Promise<SyncResult> => {
    if (!isOnline || pedidosPendientes.length === 0) {
      return { success: true, sincronizados: 0, errores: [] }
    }

    // RACE CONDITION FIX: Verificar si ya está sincronizando usando ref
    if (sincronizandoRef.current) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sincronización ya en progreso' }] }
    }

    sincronizandoRef.current = true
    setSincronizando(true)
    const errores: SyncResult['errores'] = []
    let sincronizados = 0

    try {
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
          const err = error as Error
          errores.push({ pedido, error: err.message })
        }
      }
    } finally {
      sincronizandoRef.current = false
      setSincronizando(false)
    }

    return { success: errores.length === 0, sincronizados, errores }
  }, [isOnline, pedidosPendientes, eliminarPedidoOffline])

  /**
   * Sincroniza todas las mermas pendientes con el servidor
   * @param registrarMermaFn - Función para registrar mermas en el servidor
   * @returns Resultado de la sincronización
   */
  const sincronizarMermas = useCallback(async (
    registrarMermaFn: RegistrarMermaFunction
  ): Promise<SyncResult> => {
    if (!isOnline || mermasPendientes.length === 0) {
      return { success: true, sincronizados: 0, errores: [] }
    }

    // RACE CONDITION FIX: Verificar si ya está sincronizando usando ref
    if (sincronizandoRef.current) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sincronización ya en progreso' }] }
    }

    sincronizandoRef.current = true
    setSincronizando(true)
    const errores: SyncResult['errores'] = []
    let sincronizados = 0

    try {
      for (const merma of mermasPendientes) {
        try {
          await registrarMermaFn(merma)
          eliminarMermaOffline(merma.offlineId)
          sincronizados++
        } catch (error) {
          const err = error as Error
          errores.push({ merma, error: err.message })
        }
      }
    } finally {
      sincronizandoRef.current = false
      setSincronizando(false)
    }

    return { success: errores.length === 0, sincronizados, errores }
  }, [isOnline, mermasPendientes, eliminarMermaOffline])

  /**
   * Limpia todos los pedidos offline
   */
  const limpiarPedidosOffline = useCallback((): void => {
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
