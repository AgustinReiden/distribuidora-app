import { useState, useEffect, useCallback, useRef } from 'react'
import {
  queueOperation,
  getPendingOperations,
  markAsCompleted,
  markAsFailed,
  cleanupOldOperations,
  deletePendingOperation,
  deletePendingOperations,
  type PendingOperation,
  type OperationType
} from '../lib/offlineDb'
import { logger } from '../utils/logger'
import type { ProductoDB } from '../types'
import type { OrigenPrecioItem } from '../utils/origenPrecio'
import { useSucursal } from '../contexts/SucursalContext'
import { motivoMontoMinimo } from '../utils/montoMinimo'
import { validarStockAntesDeEncolar } from '../utils/validarStockAntesDeEncolar'
import { leerMontoMinimoCacheado } from './queries/usePoliticasComercialesQuery'
import { setSucursalHeader, getSucursalHeader } from '../lib/supabase'
import { nuevoRequestId, idDeInstalacion } from '../utils/idempotencia'
import { retryWithBackoff, isTransientNetworkError } from '../utils/retryWithBackoff'
import { pareceSesionVencida, renovarSesion } from '../utils/sesionVencida'
import { getErrorMessage } from '../utils/errorHandling'

/**
 * La cola vive en IndexedDB, pero `pedidosPendientes` es estado de React por
 * instancia del hook. Quien encola (PedidosContainer) y quien muestra el badge
 * de pendientes (App.tsx) son instancias distintas, asi que sin este evento el
 * pedido entraba a la cola y el contador seguia en cero hasta recargar.
 */
export const OFFLINE_QUEUE_CHANGED = 'offline-queue-changed'

/** Identifica a la instancia que emitio el evento, para que no se reprocese. */
interface OfflineQueueChangedDetail { origen: string }

// ============================================================================
// TYPES
// ============================================================================

export interface PedidoOfflineItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
  nombre?: string;
  /**
   * Bonificacion de promo. Sin esto el replay mandaba el regalo como un item
   * comprado mas: se le cobraba al cliente y el stock se movia distinto.
   */
  esBonificacion?: boolean;
  promocionId?: string;
  /**
   * Desglose fiscal por unidad (mig 111-121). Lo calcula el front con el tipo
   * de factura y el IVA/II del producto; si no viaja, el pedido sincronizado
   * queda sin neto/IVA y descuadra la posicion fiscal.
   */
  neto_unitario?: number;
  iva_unitario?: number;
  impuestos_internos_unitario?: number;
  porcentaje_iva?: number;
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
  /**
   * Nombre a mostrar en el panel de pendientes (OfflineIndicator). Se acuña
   * ACÁ, al encolar, porque el panel muestra la cola sin señal: pedirle la
   * lista de clientes en ese momento no funciona, y comparar el `clienteId`
   * de la cola contra un `clientes` cargado aparte mezcla un id `string` con
   * un `id` que en runtime llega `number` (ver CLAUDE.md, "Los ids son
   * bigint").
   */
  clienteNombre?: string;
  items: PedidoOfflineItem[];
  total: number;
  usuarioId?: string;
  notas?: string;
  formaPago?: string;
  estadoPago?: string;
  /**
   * @deprecated Sin red NO se declara cobro: el replay no registra pagos, asi
   * que un pedido encolado como 'pagado' entraba impago y el chofer se lo
   * cobraba de nuevo al cliente. `ModalPedido` fuerza 'pendiente' offline.
   * Se conserva el campo para no romper operaciones ya encoladas en IndexedDB.
   */
  montoPagado?: number;
  creadoOffline: string;
  sincronizado: boolean;
  stockSnapshot?: StockSnapshot;
  // --- Lo que el alta online SI manda y la cola perdia en silencio ---
  /** Fecha del pedido. Sin esto el pedido se fecha el dia que sincroniza. */
  fecha?: string;
  fechaEntregaProgramada?: string;
  /** ZZ/FC. Sin esto el replay caia siempre en ZZ y cambiaba el desglose. */
  tipoFactura?: 'ZZ' | 'FC';
  /** A quien se le acredita la venta. Sin esto la cobraba quien sincroniza. */
  preventistaId?: string | null;
  totalNeto?: number;
  totalIva?: number;
  /** Por que se cobro cada precio (mig 148/149). Metadato analitico. */
  origenes?: OrigenPrecioItem[];
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

export interface StockConflict {
  pedido: PedidoOffline;
  items: Array<{
    productoId: string;
    nombre: string;
    solicitado: number;
    stockAlMomento: number;
    stockActual: number;
  }>;
}

export interface SyncResult {
  success: boolean;
  sincronizados: number;
  errores: Array<{ pedido?: PedidoOffline; error: string }>;
  conflictos?: StockConflict[];
}

/**
 * Alta de pedido usada por el replay. Toma un objeto y no 13 parametros
 * posicionales: la firma vieja ya obligaba a escribir `undefined, undefined,
 * undefined, undefined` en el medio para llegar al `offlineId`, y ahi fue
 * justamente donde se perdieron el tipo de factura, el desglose y el
 * preventista. Con nombres, olvidarse un campo se ve.
 */
export interface CrearPedidoFunction {
  (input: {
    clienteId: string | number;
    items: PedidoOfflineItem[];
    total: number;
    usuarioId?: string | null;
    notas?: string;
    formaPago?: string;
    estadoPago?: string;
    fecha?: string;
    fechaEntregaProgramada?: string;
    tipoFactura?: 'ZZ' | 'FC';
    totalNeto?: number;
    totalIva?: number;
    preventistaId?: string | null;
    origenes?: OrigenPrecioItem[];
    /** Idempotencia del alta (mig 071): el mismo valor en cada reintento. */
    offlineId?: string | null;
  }): Promise<unknown>;
}

export interface UseOfflineSyncReturn {
  isOnline: boolean;
  pedidosPendientes: PedidoOffline[];
  sincronizando: boolean;
  guardarPedidoOffline: (
    pedidoData: Omit<PedidoOffline, 'offlineId' | 'creadoOffline' | 'sincronizado'>,
    options?: GuardarPedidoOptions
  ) => Promise<GuardarPedidoResult>;
  eliminarPedidoOffline: (offlineId: string) => void;
  sincronizarPedidos: (
    crearPedidoFn: CrearPedidoFunction,
    productosActuales?: ProductoDB[]
  ) => Promise<SyncResult>;
  limpiarPedidosOffline: () => void;
  refreshPendingOperations: () => Promise<void>;
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
    clienteNombre: payload.clienteNombre as string | undefined,
    items: payload.items as PedidoOfflineItem[],
    total: payload.total as number,
    usuarioId: payload.usuarioId as string | undefined,
    notas: payload.notas as string | undefined,
    formaPago: payload.formaPago as string | undefined,
    estadoPago: payload.estadoPago as string | undefined,
    montoPagado: payload.montoPagado as number | undefined,
    creadoOffline: op.createdAt.toISOString(),
    sincronizado: op.status === 'completed',
    stockSnapshot: payload.stockSnapshot as StockSnapshot | undefined,
    fecha: payload.fecha as string | undefined,
    fechaEntregaProgramada: payload.fechaEntregaProgramada as string | undefined,
    tipoFactura: payload.tipoFactura as 'ZZ' | 'FC' | undefined,
    preventistaId: payload.preventistaId as string | null | undefined,
    totalNeto: payload.totalNeto as number | undefined,
    totalIva: payload.totalIva as number | undefined,
    origenes: payload.origenes as OrigenPrecioItem[] | undefined
  }
}

/**
 * Clave de idempotencia con la que el replay le habla a
 * `crear_pedido_idempotente` (mig 071).
 *
 * EL BUG QUE ARREGLA. Antes era `op_${op.id}`, y `op.id` es el autoincrement de
 * Dexie: arranca en 1 en cada instalación. La RPC busca `offline_id` en TODA la
 * tabla `pedidos` (índice único global, SECURITY DEFINER), así que el primer
 * pedido offline de cualquier teléfono era `op_1`. El segundo teléfono que
 * sincronizaba recibía el pedido AJENO con `idempotente: true`, lo daba por
 * sincronizado y su pedido no quedaba en ningún lado. Lo mismo al purgar
 * IndexedDB: el contador vuelve a 1 y choca con lo ya sincronizado.
 *
 * Ahora la cola acuña un UUID al encolar (`offlineUuid`). Para lo que ya estaba
 * encolado sin UUID se usa el dueño como prefijo: el usuario si la operación lo
 * registró, y si no la instalación, que también es única por dispositivo. Lo
 * que no se puede cambiar es que sea ESTABLE entre reintentos: si cambiara,
 * cada reintento crearía un pedido nuevo.
 */
export function claveIdempotencia(op: PendingOperation): string {
  const uuid = (op.payload as { offlineUuid?: unknown }).offlineUuid
  if (typeof uuid === 'string' && uuid.length > 0) return uuid
  return `${op.userId || idDeInstalacion()}:op_${op.id}`
}

/**
 * Segunda defensa: una respuesta `idempotente: true` dice "ya tenía un pedido
 * con esa clave", pero no que ese pedido sea el nuestro. Antes de dar la
 * operación por sincronizada se compara contra lo encolado.
 *
 * Devuelve el motivo por el que NO hay que marcarla completada, o null si el
 * pedido del servidor es efectivamente este. `terminal` distingue el caso
 * probado —es de otro, reintentar no lo va a cambiar— del no verificable, que
 * puede ser una lectura que falló y sí merece otro intento.
 */
export function verificarRespuestaIdempotente(
  resultado: unknown,
  payload: Record<string, unknown>
): { motivo: string; terminal: boolean } | null {
  const r = resultado as {
    idempotente?: boolean
    clienteId?: string | number | null
    total?: number | null
  } | null

  if (!r || r.idempotente !== true) return null

  if (r.clienteId == null || typeof r.total !== 'number') {
    return {
      motivo: 'El servidor dice que este pedido ya existía, pero no se pudo leer para verificar que sea el mismo. No se marcó como sincronizado.',
      terminal: false
    }
  }

  const mismoCliente = String(r.clienteId) === String(payload.clienteId)
  const mismoTotal = Math.abs(r.total - (Number(payload.total) || 0)) < 0.01
  if (mismoCliente && mismoTotal) return null

  return {
    motivo: `La clave de sincronización de este pedido ya la tiene otro pedido en el servidor (cliente ${r.clienteId}, total ${r.total}). No se sincronizó para no pisarlo.`,
    terminal: true
  }
}

// ============================================================================
// HOOK
// ============================================================================

/**
 * Hook para manejar sincronización offline de pedidos
 *
 * Ahora usa IndexedDB (via Dexie.js) para almacenamiento persistente
 * que soporta más de 5MB y sobrevive limpiezas de caché.
 */
export function useOfflineSync(): UseOfflineSyncReturn {
  const [isOnline, setIsOnline] = useState<boolean>(navigator.onLine)
  const [pedidosPendientes, setPedidosPendientes] = useState<PedidoOffline[]>([])
  const [sincronizando, setSincronizando] = useState<boolean>(false)

  // Multi-tenant: track the active sucursal so we can tag queued operations
  // and reset the X-Sucursal-ID header after per-op replay.
  //
  // `userId` es el dueño de la cola. IndexedDB es del teléfono, no de la
  // sesión: en un teléfono compartido, sin esto el usuario B veía y replayaba
  // los pedidos de A (y el guard de la mig 219 se los rechazaba con 42501).
  const { currentSucursalId, userId } = useSucursal()
  const currentSucursalIdRef = useRef<number | null>(currentSucursalId)
  currentSucursalIdRef.current = currentSucursalId
  const userIdRef = useRef<string | null>(userId ?? null)
  userIdRef.current = userId ?? null

  // Ref para evitar race conditions en sincronización
  const sincronizandoRef = useRef<boolean>(false)

  // Ref para acceder a pedidosPendientes sin causar re-renders en callbacks
  const pedidosPendientesRef = useRef<PedidoOffline[]>(pedidosPendientes)

  // Ref para controlar si el componente está montado
  // Id de esta instancia del hook. Sirve para ignorar el propio evento: la
  // instancia que encola ya actualizo su estado optimista, y releer IndexedDB
  // ahi mismo se lo pisa con lo que haya alcanzado a commitear.
  const instanciaIdRef = useRef<string>(`ofs_${Math.random().toString(36).slice(2)}`)
  const isMountedRef = useRef<boolean>(true)

  // Mantener ref sincronizado con el estado
  pedidosPendientesRef.current = pedidosPendientes

  /**
   * Carga las operaciones pendientes de IndexedDB
   * Verifica si el componente está montado antes de actualizar estado
   */
  const loadPendingOperations = useCallback(async (): Promise<void> => {
    try {
      const operations = await getPendingOperations(100, userId ?? null, currentSucursalId)

      // Verificar si el componente sigue montado antes de actualizar estado
      if (!isMountedRef.current) return

      const pedidos = operations
        .filter(op => op.type === 'CREATE_PEDIDO')
        .map(operationToPedidoOffline)

      setPedidosPendientes(pedidos)
    } catch (err) {
      logger.error('[useOfflineSync] Error cargando operaciones pendientes:', err)
    }
  }, [userId, currentSucursalId])

  useEffect(() => {
    isMountedRef.current = true

    // Limpieza periódica de operaciones antiguas (mayores a 7 días)
    cleanupOldOperations(7).catch(err => {
      logger.warn('[useOfflineSync] Error en limpieza periódica:', err)
    })

    return () => {
      isMountedRef.current = false
    }
  }, [])

  // Releer la cola al montar y cada vez que cambia de dueño (login, logout,
  // cambio de sucursal): lo que se ve tiene que ser lo de la sesión de ahora.
  useEffect(() => {
    void loadPendingOperations()
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

    const handleQueueChanged = (e: Event): void => {
      const detalle = (e as CustomEvent<OfflineQueueChangedDetail>).detail
      // Solo las OTRAS instancias releen; la emisora ya se actualizo sola.
      if (detalle?.origen === instanciaIdRef.current) return
      void loadPendingOperations()
    }

    window.addEventListener('online', handleOnline)
    window.addEventListener('offline', handleOffline)
    window.addEventListener(OFFLINE_QUEUE_CHANGED, handleQueueChanged)

    return () => {
      window.removeEventListener('online', handleOnline)
      window.removeEventListener('offline', handleOffline)
      window.removeEventListener(OFFLINE_QUEUE_CHANGED, handleQueueChanged)
    }
  }, [loadPendingOperations])

  /**
   * Guarda un pedido en modo offline.
   *
   * Valida **compra mínima** (migs 204/205, contra el último valor cacheado en
   * Dexie) y stock ANTES de encolar: si alguna falla no encola nada y devuelve
   * `{ success: false, error }`. Ojo que la compra mínima corre siempre, incluso
   * con `validarStock: false`.
   *
   * Usa IndexedDB via queueOperation, y `pedidosPendientesRef` para evitar
   * re-renders innecesarios.
   */
  const guardarPedidoOffline = useCallback(async (
    pedidoData: Omit<PedidoOffline, 'offlineId' | 'creadoOffline' | 'sincronizado'>,
    options: GuardarPedidoOptions = {}
  ): Promise<GuardarPedidoResult> => {
    const { productos = [], validarStock = true } = options

    // Compra mínima (migs 204/205). ESTE es el chequeo que evita el peor final:
    // sin él, un pedido por debajo del mínimo se acepta en el teléfono sin
    // señal, el preventista se va del comercio, y el rechazo del servidor llega
    // horas después — como una operación fallida en IndexedDB que sólo se ve en
    // el panel de fallidas. El mínimo se lee del caché de Dexie, que es lo mejor
    // que se puede saber sin conexión (ver usePoliticasComercialesQuery).
    const minimo = await leerMontoMinimoCacheado(currentSucursalIdRef.current).catch(() => 0)
    const motivoMinimo = motivoMontoMinimo(Number(pedidoData.total) || 0, minimo)
    if (motivoMinimo) {
      return { success: false, error: motivoMinimo }
    }

    // Validar stock si se proporciona lista de productos
    // Usar ref para evitar dependencia en el array de callbacks
    if (validarStock && productos.length > 0 && pedidoData.items?.length > 0) {
      const { itemsSinStock, stockSnapshot } = validarStockAntesDeEncolar(
        pedidoData.items,
        productos,
        pedidosPendientesRef.current
      )

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

    // Clave de idempotencia del alta, acuñada ACÁ y no en el replay: tiene que
    // ser única en el mundo (la busca `crear_pedido_idempotente` en toda la
    // tabla `pedidos`) y estable entre reintentos. Ver `claveIdempotencia`.
    const offlineUuid = nuevoRequestId()

    // Generar offlineId temporal para el objeto de retorno
    const tempOfflineId = `offline_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`
    const nuevoPedido: PedidoOffline = {
      ...pedidoData,
      offlineId: tempOfflineId,
      creadoOffline: new Date().toISOString(),
      sincronizado: false
    }

    // Encolar en IndexedDB - await to ensure persistence before reporting success (BUG-11 fix)
    // Multi-tenant: persist the sucursal that originated the pedido so the replay
    // after reconnection can re-set X-Sucursal-ID to the same tenant (avoids C7).
    let pedidoFinal: PedidoOffline
    try {
      const opId = await queueOperation(
        'CREATE_PEDIDO' as OperationType,
        {
          ...pedidoData,
          offlineUuid,
          tempOfflineId,
          timestamp: Date.now()
        },
        pedidoData.usuarioId ?? userIdRef.current ?? undefined,
        undefined,
        currentSucursalIdRef.current ?? undefined
      )

      logger.info(`[useOfflineSync] Pedido encolado con ID: ${opId}`)
      // El id real de la cola, no el temporal (H57): quien borre este pedido
      // en la misma sesión llama a eliminarPedidoOffline con el offlineId que
      // ve en pantalla, y ese sólo borra de IndexedDB si matchea `op_<id>`. Sin
      // esto el id temporal sobrevivía hasta el próximo loadPendingOperations,
      // la emisora no se relee (ver OFFLINE_QUEUE_CHANGED), y borrar "ya" sacaba
      // el pedido de la UI dejándolo vivo en la cola para sincronizarse igual.
      pedidoFinal = { ...nuevoPedido, offlineId: `op_${opId}` }
    } catch (err) {
      logger.error('[useOfflineSync] Error crítico al encolar pedido:', err)
      window.dispatchEvent(new CustomEvent('offline-storage-error', {
        detail: { type: 'pedido', error: (err as Error).message }
      }))
      return { success: false, pedido: nuevoPedido }
    }

    // Actualizar estado local after confirmed IndexedDB write
    setPedidosPendientes(prev => [...prev, pedidoFinal])
    // Avisarle a las demas instancias del hook (el badge de pendientes vive en
    // App.tsx, no aca) para que relean IndexedDB.
    window.dispatchEvent(
      new CustomEvent<OfflineQueueChangedDetail>(OFFLINE_QUEUE_CHANGED, {
        detail: { origen: instanciaIdRef.current },
      }),
    )

    return { success: true, pedido: pedidoFinal }
  }, []) // pedidosPendientes removido, usamos ref

  /**
   * Elimina un pedido offline de verdad: lo saca de IndexedDB, no lo marca
   * `failed` (eso lo dejaba en la cola, visible en el panel de fallidas, sin
   * borrar nada).
   */
  const eliminarPedidoOffline = useCallback((offlineId: string): void => {
    setPedidosPendientes(prev => prev.filter(p => p.offlineId !== offlineId))

    const opIdMatch = offlineId.match(/^op_(\d+)$/)
    if (opIdMatch) {
      const opId = parseInt(opIdMatch[1], 10)
      deletePendingOperation(opId).catch(err => {
        logger.error('[useOfflineSync] Error eliminando pedido:', err)
      })
    }
  }, [])

  /**
   * Valida que el stock actual sea suficiente comparando con el snapshot
   * Retorna null si todo está bien, o un StockConflict si hay problemas
   */
  const validarStockParaSincronizacion = useCallback((
    pedido: PedidoOffline,
    payload: Record<string, unknown>,
    productosActuales: ProductoDB[]
  ): StockConflict | null => {
    const items = payload.items as PedidoOfflineItem[]
    const stockSnapshot = payload.stockSnapshot as StockSnapshot | undefined
    const itemsConConflicto: StockConflict['items'] = []

    for (const item of items) {
      const productoActual = productosActuales.find(p => p.id === item.productoId)
      if (!productoActual) continue

      const stockActual = productoActual.stock || 0
      const stockAlMomento = stockSnapshot?.[item.productoId]?.stockAlMomento ?? stockActual

      // Si el stock actual es menor que lo solicitado, hay conflicto
      if (item.cantidad > stockActual) {
        itemsConConflicto.push({
          productoId: item.productoId,
          nombre: productoActual.nombre || item.nombre || 'Producto desconocido',
          solicitado: item.cantidad,
          stockAlMomento,
          stockActual
        })
      }
    }

    if (itemsConConflicto.length > 0) {
      return { pedido, items: itemsConConflicto }
    }

    return null
  }, [])

  /**
   * Sincroniza todos los pedidos pendientes con el servidor
   * Valida stock actual antes de sincronizar para evitar overselling
   */
  // `descontarStockFn` ya no es parametro: la RPC `crear_pedido_completo`
  // descuenta el stock dentro de la misma transaccion. El caller lo pasaba y
  // `usePedidos.crearPedido` lo recibia como `_descontarStockFn` sin usarlo.
  const sincronizarPedidos = useCallback(async (
    crearPedidoFn: CrearPedidoFunction,
    productosActuales?: ProductoDB[]
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

    // Obtener operaciones pendientes desde IndexedDB (solo las de esta sesión:
    // usuario y sucursal activos)
    const operations = await getPendingOperations(100, userIdRef.current, currentSucursalIdRef.current)
    const pedidoOps = operations.filter(op => op.type === 'CREATE_PEDIDO')

    if (pedidoOps.length === 0) {
      sincronizandoRef.current = false
      setSincronizando(false)
      return { success: true, sincronizados: 0, errores: [] }
    }
    const errores: SyncResult['errores'] = []
    const conflictos: StockConflict[] = []
    let sincronizados = 0

    // Snapshot the header BEFORE the replay loop so we can restore it even if
    // the active sucursal changes mid-sync (e.g. user switches tabs). Each op
    // temporarily sets the header to its own sucursalId.
    const headerBeforeSync = getSucursalHeader()

    try {
      for (const op of pedidoOps) {
        const payload = op.payload as Record<string, unknown>
        const pedido = operationToPedidoOffline(op)

        // Multi-tenant (C7): refuse to replay ops queued without a sucursalId.
        // These are either pre-migration entries or corrupt writes — replaying
        // them would mint rows in whatever tenant happens to be active now.
        if (op.sucursalId == null) {
          await markAsFailed(op.id!, 'Operación pre-migración sin sucursal asignada; descartada para evitar corrupción cross-tenant')
          logger.warn(`[useOfflineSync] Pedido ${pedido.offlineId} sin sucursalId, marcado como failed`)
          errores.push({ pedido, error: 'Operación sin sucursal asignada' })
          continue
        }

        // Set the header to the sucursal that originated this op. RPCs rely on
        // current_sucursal_id() which (migration 061) reads X-Sucursal-ID.
        setSucursalHeader(op.sucursalId)

        // Validar stock si tenemos productos actuales
        if (productosActuales && productosActuales.length > 0) {
          const conflicto = validarStockParaSincronizacion(pedido, payload, productosActuales)
          if (conflicto) {
            // Marcar como fallido con mensaje descriptivo
            const itemsDesc = conflicto.items
              .map(i => `${i.nombre}: necesita ${i.solicitado}, disponible ${i.stockActual}`)
              .join('; ')
            await markAsFailed(op.id!, `Stock insuficiente: ${itemsDesc}`)
            conflictos.push(conflicto)
            logger.warn(`[useOfflineSync] Conflicto de stock en pedido ${pedido.offlineId}:`, conflicto.items)
            continue // No sincronizar este pedido
          }
        }

        const input = {
          clienteId: payload.clienteId as string | number,
          items: payload.items as PedidoOfflineItem[],
          total: payload.total as number,
          usuarioId: payload.usuarioId as string | undefined,
          notas: payload.notas as string | undefined,
          formaPago: payload.formaPago as string | undefined,
          // Un pedido encolado nunca declara cobro (ver PedidoOffline.montoPagado):
          // el replay no registra pagos, asi que 'pagado'/'parcial' entraria
          // impago igual. Se fuerza el unico estado que no miente.
          estadoPago: 'pendiente',
          // Estos cuatro iban en `undefined` y por eso el pedido sincronizado
          // se fechaba el dia del replay, caia siempre en ZZ, perdia el
          // desglose fiscal y se le acreditaba a quien sincronizara.
          fecha: payload.fecha as string | undefined,
          fechaEntregaProgramada: payload.fechaEntregaProgramada as string | undefined,
          tipoFactura: payload.tipoFactura as 'ZZ' | 'FC' | undefined,
          totalNeto: payload.totalNeto as number | undefined,
          totalIva: payload.totalIva as number | undefined,
          preventistaId: payload.preventistaId as string | null | undefined,
          origenes: payload.origenes as OrigenPrecioItem[] | undefined,
          // Clave de idempotencia estable y única por operación encolada.
          offlineId: claveIdempotencia(op),
        }

        try {
          // El primer pedido de la cola suele pegarle a un JWT vencido: al
          // reconectar, el token se renovó recién o no llegó a renovarse, y el
          // RPC contesta "No se pudo determinar la sucursal activa". Eso no es
          // un fallo del pedido —el RPC valida la sucursal antes de escribir
          // nada— así que se renueva la sesión y se reintenta sin gastar uno de
          // los reintentos de la cola.
          //
          // Los fallos de red sí se reintentan con backoff acá adentro, que es
          // donde corresponde: el alta es idempotente por `offlineId`, y un
          // blip de señal —lo normal en la calle— no tiene que consumir los 5
          // reintentos de la operación en un par de segundos.
          let yaRenovo = false
          const resultado = await retryWithBackoff(
            async () => {
              try {
                return await crearPedidoFn(input)
              } catch (error) {
                if (!yaRenovo && pareceSesionVencida(getErrorMessage(error))) {
                  yaRenovo = true
                  if (await renovarSesion()) {
                    return crearPedidoFn(input)
                  }
                }
                throw error
              }
            },
            { shouldRetry: isTransientNetworkError },
          )

          const sospecha = verificarRespuestaIdempotente(resultado, payload)
          if (sospecha) {
            await markAsFailed(op.id!, sospecha.motivo, { terminal: sospecha.terminal })
            logger.error(`[useOfflineSync] Pedido ${pedido.offlineId}: ${sospecha.motivo}`)
            errores.push({ pedido, error: sospecha.motivo })
            continue
          }

          await markAsCompleted(op.id!)
          sincronizados++
        } catch (error) {
          const mensaje = getErrorMessage(error)
          await markAsFailed(op.id!, mensaje)
          errores.push({ pedido, error: mensaje })
        }
      }
    } finally {
      // Always restore the header to whatever was active before replay. If the
      // user switched sucursal mid-sync, prefer the latest active value.
      const latestActive = currentSucursalIdRef.current
      setSucursalHeader(latestActive ?? headerBeforeSync)
      sincronizandoRef.current = false
      setSincronizando(false)
      // Recargar lista de pendientes
      await loadPendingOperations()
    }

    return {
      success: errores.length === 0 && conflictos.length === 0,
      sincronizados,
      errores,
      conflictos: conflictos.length > 0 ? conflictos : undefined
    }
  }, [isOnline, loadPendingOperations, validarStockParaSincronizacion])

  /**
   * Limpia todos los pedidos offline de la sesión activa (usuario + sucursal).
   * `cleanupOldOperations(0)` sólo borra `status: 'completed'`, así que lo
   * pendiente y lo fallido nunca se iba: esto lee lo mismo que ve el panel
   * (`getPendingOperations`, mismo alcance que `loadPendingOperations`) y lo
   * borra de IndexedDB de verdad.
   */
  const limpiarPedidosOffline = useCallback((): void => {
    setPedidosPendientes([])

    getPendingOperations(1000, userIdRef.current, currentSucursalIdRef.current)
      .then(operations => {
        const ids = operations
          .filter(op => op.type === 'CREATE_PEDIDO')
          .map(op => op.id)
          .filter((id): id is number => id != null)
        return deletePendingOperations(ids)
      })
      .catch(err => {
        logger.error('[useOfflineSync] Error limpiando operaciones:', err)
      })
  }, [])

  return {
    isOnline,
    pedidosPendientes,
    sincronizando,
    guardarPedidoOffline,
    eliminarPedidoOffline,
    sincronizarPedidos,
    limpiarPedidosOffline,
    refreshPendingOperations: loadPendingOperations,
    cantidadPendientes: pedidosPendientes.length
  }
}
