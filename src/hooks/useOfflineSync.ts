import { useState, useEffect, useCallback, useRef } from 'react'
import {
  queueOperation,
  getPendingOperations,
  markAsCompleted,
  markAsFailed,
  cleanupOldOperations,
  type PendingOperation,
  type OperationType
} from '../lib/offlineDb'
import { logger } from '../utils/logger'
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
// HELPERS
// ============================================================================

/**
 * Convierte una PendingOperation de IndexedDB a PedidoOffline
 */
function operationToPedidoOffline(op: PendingOperation): PedidoOffline {
  const payload = op.payload as Record<string, unknown>
  return {
    offlineId: `op_${op.id}`,
    clienteId: payload.clienteId as string | number,
    items: payload.items as PedidoOfflineItem[],
    total: payload.total as number,
    usuarioId: payload.usuarioId as string | undefined,
    notas: payload.notas as string | undefined,
    formaPago: payload.formaPago as string | undefined,
    estadoPago: payload.estadoPago as string | undefined,
    montoPagado: payload.montoPagado as number | undefined,
    creadoOffline: op.createdAt.toISOString(),
    sincronizado: op.status === 'completed',
    stockSnapshot: payload.stockSnapshot as StockSnapshot | undefined
  }
}

/**
 * Convierte una PendingOperation de IndexedDB a MermaOffline
 */
function operationToMermaOffline(op: PendingOperation): MermaOffline {
  const payload = op.payload as MermaFormInput & { offlineId?: string }
  return {
    ...payload,
    offlineId: `op_${op.id}`,
    creadoOffline: op.createdAt.toISOString(),
    sincronizado: op.status === 'completed'
  }
}

// ============================================================================
// HOOK
// ============================================================================

/**
 * Hook para manejar sincronización offline de pedidos y mermas
 *
 * Ahora usa IndexedDB (via Dexie.js) para almacenamiento persistente
 * que soporta más de 5MB y sobrevive limpiezas de caché.
 */
export function useOfflineSync(): UseOfflineSyncReturn {
  const [isOnline, setIsOnline] = useState<boolean>(navigator.onLine)
  const [pedidosPendientes, setPedidosPendientes] = useState<PedidoOffline[]>([])
  const [mermasPendientes, setMermasPendientes] = useState<MermaOffline[]>([])
  const [sincronizando, setSincronizando] = useState<boolean>(false)

  // Ref para evitar race conditions en sincronización
  const sincronizandoRef = useRef<boolean>(false)

  /**
   * Carga las operaciones pendientes de IndexedDB
   */
  const loadPendingOperations = useCallback(async (): Promise<void> => {
    try {
      const operations = await getPendingOperations(100)

      const pedidos = operations
        .filter(op => op.type === 'CREATE_PEDIDO')
        .map(operationToPedidoOffline)

      const mermas = operations
        .filter(op => op.type === 'CREATE_MERMA')
        .map(operationToMermaOffline)

      setPedidosPendientes(pedidos)
      setMermasPendientes(mermas)
    } catch (err) {
      logger.error('[useOfflineSync] Error cargando operaciones pendientes:', err)
    }
  }, [])

  // Cargar operaciones pendientes al montar
  useEffect(() => {
    loadPendingOperations()

    // Limpieza periódica de operaciones antiguas (mayores a 7 días)
    cleanupOldOperations(7).catch(err => {
      logger.warn('[useOfflineSync] Error en limpieza periódica:', err)
    })
  }, [loadPendingOperations])

  // Escuchar cambios de conexión
  useEffect(() => {
    const handleOnline = (): void => {
      logger.info('[useOfflineSync] Conexión restaurada')
      setIsOnline(true)
    }
    const handleOffline = (): void => {
      logger.info('[useOfflineSync] Conexión perdida')
      setIsOnline(false)
    }

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)

    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
    }
  }, [])

  /**
   * Guarda un pedido en modo offline con validación de stock
   * Ahora usa IndexedDB via queueOperation
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

    // Generar offlineId temporal para el objeto de retorno
    const tempOfflineId = `offline_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`
    const nuevoPedido: PedidoOffline = {
      ...pedidoData,
      offlineId: tempOfflineId,
      creadoOffline: new Date().toISOString(),
      sincronizado: false
    }

    // Encolar en IndexedDB (async, no bloqueante)
    queueOperation('CREATE_PEDIDO' as OperationType, {
      ...pedidoData,
      tempOfflineId,
      timestamp: Date.now()
    }, pedidoData.usuarioId)
      .then((opId) => {
        if (opId !== null) {
          logger.info(`[useOfflineSync] Pedido encolado con ID: ${opId}`)
          // Actualizar lista local
          loadPendingOperations()
        } else {
          logger.warn('[useOfflineSync] Pedido duplicado detectado, no se encoló')
        }
      })
      .catch((err) => {
        logger.error('[useOfflineSync] Error crítico al encolar pedido:', err)
        window.dispatchEvent(new CustomEvent('offline-storage-error', {
          detail: { type: 'pedido', error: err.message }
        }))
      })

    // Actualizar estado local inmediatamente para UI responsive
    setPedidosPendientes(prev => [...prev, nuevoPedido])

    return { success: true, pedido: nuevoPedido }
  }, [pedidosPendientes, loadPendingOperations])

  /**
   * Guarda una merma en modo offline
   * Ahora usa IndexedDB via queueOperation
   */
  const guardarMermaOffline = useCallback((mermaData: MermaFormInput): MermaOffline => {
    const tempOfflineId = `offline_merma_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`
    const nuevaMerma: MermaOffline = {
      ...mermaData,
      offlineId: tempOfflineId,
      creadoOffline: new Date().toISOString(),
      sincronizado: false
    }

    // Encolar en IndexedDB (async, no bloqueante)
    queueOperation('CREATE_MERMA' as OperationType, {
      ...mermaData,
      tempOfflineId,
      timestamp: Date.now()
    })
      .then((opId) => {
        if (opId !== null) {
          logger.info(`[useOfflineSync] Merma encolada con ID: ${opId}`)
          loadPendingOperations()
        } else {
          logger.warn('[useOfflineSync] Merma duplicada detectada, no se encoló')
        }
      })
      .catch((err) => {
        logger.error('[useOfflineSync] Error crítico al encolar merma:', err)
        window.dispatchEvent(new CustomEvent('offline-storage-error', {
          detail: { type: 'merma', error: err.message }
        }))
      })

    // Actualizar estado local inmediatamente para UI responsive
    setMermasPendientes(prev => [...prev, nuevaMerma])

    return nuevaMerma
  }, [loadPendingOperations])

  /**
   * Elimina un pedido offline
   */
  const eliminarPedidoOffline = useCallback((offlineId: string): void => {
    // Extraer ID de operación del offlineId
    const opIdMatch = offlineId.match(/^op_(\d+)$/)
    if (opIdMatch) {
      const opId = parseInt(opIdMatch[1], 10)
      markAsFailed(opId, 'Eliminado manualmente').catch(err => {
        logger.error('[useOfflineSync] Error eliminando pedido:', err)
      })
    }

    setPedidosPendientes(prev => prev.filter(p => p.offlineId !== offlineId))
  }, [])

  /**
   * Elimina una merma offline
   */
  const eliminarMermaOffline = useCallback((offlineId: string): void => {
    // Extraer ID de operación del offlineId
    const opIdMatch = offlineId.match(/^op_(\d+)$/)
    if (opIdMatch) {
      const opId = parseInt(opIdMatch[1], 10)
      markAsFailed(opId, 'Eliminado manualmente').catch(err => {
        logger.error('[useOfflineSync] Error eliminando merma:', err)
      })
    }

    setMermasPendientes(prev => prev.filter(m => m.offlineId !== offlineId))
  }, [])

  /**
   * Sincroniza todos los pedidos pendientes con el servidor
   */
  const sincronizarPedidos = useCallback(async (
    crearPedidoFn: CrearPedidoFunction,
    descontarStockFn: (items: Array<{ productoId?: string; producto_id?: string; cantidad: number }>) => Promise<void>
  ): Promise<SyncResult> => {
    if (!isOnline) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sin conexión' }] }
    }

    // RACE CONDITION FIX: Verificar si ya está sincronizando usando ref BEFORE any async operations
    if (sincronizandoRef.current) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sincronización ya en progreso' }] }
    }

    sincronizandoRef.current = true
    setSincronizando(true)

    // Obtener operaciones pendientes desde IndexedDB
    const operations = await getPendingOperations(100)
    const pedidoOps = operations.filter(op => op.type === 'CREATE_PEDIDO')

    if (pedidoOps.length === 0) {
      sincronizandoRef.current = false
      setSincronizando(false)
      return { success: true, sincronizados: 0, errores: [] }
    }
    const errores: SyncResult['errores'] = []
    let sincronizados = 0

    try {
      for (const op of pedidoOps) {
        const payload = op.payload as Record<string, unknown>
        const pedido = operationToPedidoOffline(op)

        try {
          await crearPedidoFn(
            payload.clienteId as string | number,
            payload.items as PedidoOfflineItem[],
            payload.total as number,
            payload.usuarioId as string | undefined,
            descontarStockFn,
            payload.notas as string | undefined,
            payload.formaPago as string | undefined,
            payload.estadoPago as string | undefined
          )
          await markAsCompleted(op.id!)
          sincronizados++
        } catch (error) {
          const err = error as Error
          await markAsFailed(op.id!, err.message)
          errores.push({ pedido, error: err.message })
        }
      }
    } finally {
      sincronizandoRef.current = false
      setSincronizando(false)
      // Recargar lista de pendientes
      await loadPendingOperations()
    }

    return { success: errores.length === 0, sincronizados, errores }
  }, [isOnline, loadPendingOperations])

  /**
   * Sincroniza todas las mermas pendientes con el servidor
   */
  const sincronizarMermas = useCallback(async (
    registrarMermaFn: RegistrarMermaFunction
  ): Promise<SyncResult> => {
    if (!isOnline) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sin conexión' }] }
    }

    // RACE CONDITION FIX: Verificar si ya está sincronizando usando ref BEFORE any async operations
    if (sincronizandoRef.current) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sincronización ya en progreso' }] }
    }

    sincronizandoRef.current = true
    setSincronizando(true)

    // Obtener operaciones pendientes desde IndexedDB
    const operations = await getPendingOperations(100)
    const mermaOps = operations.filter(op => op.type === 'CREATE_MERMA')

    if (mermaOps.length === 0) {
      sincronizandoRef.current = false
      setSincronizando(false)
      return { success: true, sincronizados: 0, errores: [] }
    }
    const errores: SyncResult['errores'] = []
    let sincronizados = 0

    try {
      for (const op of mermaOps) {
        const merma = operationToMermaOffline(op)
        const payload = op.payload as MermaFormInput

        try {
          await registrarMermaFn(payload)
          await markAsCompleted(op.id!)
          sincronizados++
        } catch (error) {
          const err = error as Error
          await markAsFailed(op.id!, err.message)
          errores.push({ merma, error: err.message })
        }
      }
    } finally {
      sincronizandoRef.current = false
      setSincronizando(false)
      // Recargar lista de pendientes
      await loadPendingOperations()
    }

    return { success: errores.length === 0, sincronizados, errores }
  }, [isOnline, loadPendingOperations])

  /**
   * Limpia todos los pedidos offline
   */
  const limpiarPedidosOffline = useCallback((): void => {
    setPedidosPendientes([])
    setMermasPendientes([])
    // Limpiar operaciones de más de 0 días (todas)
    cleanupOldOperations(0).catch(err => {
      logger.error('[useOfflineSync] Error limpiando operaciones:', err)
    })
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
