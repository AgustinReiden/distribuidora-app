import { useState, useEffect, useCallback, useRef } from 'react'
import {
  queueOperation,
  getPendingOperations,
  markAsCompleted,
  markAsFailed,
  anotarFalloDeRed,
  cleanupOldOperations,
  cleanupOldSyncEvents,
  deletePendingOperation,
  deletePendingOperations,
  type PendingOperation,
  type OperationType
} from '../lib/offlineDb'
import { logger } from '../utils/logger'
import type { ProductoDB, TipoComprobanteVenta } from '../types'
import type { OrigenPrecioItem } from '../utils/origenPrecio'
import { useSucursal } from '../contexts/SucursalContext'
import { motivoRechazoMinimo, REGLA_MINIMO_POR_DEFECTO } from '../utils/montoMinimo'
import { itemsConProductoDesactivado } from '../utils/productosOperativos'
import { rechazoEsTerminal, esRechazoDeRegalo, esRechazoDeCombo, esRechazoDeStock } from '../utils/rechazoDeNegocio'
import { quitarRegalosDelPayload } from '../utils/pedidoSinRegalos'
import { quitarCombosDelPayload } from '../utils/pedidoSinCombos'
import { validarStockAntesDeEncolar } from '../utils/validarStockAntesDeEncolar'
import { leerReglaMinimoCacheada } from './queries/usePoliticasComercialesQuery'
import { setSucursalHeader, getSucursalHeader } from '../lib/supabase'
import { nuevoRequestId, idDeInstalacion } from '../utils/idempotencia'
import { retryWithBackoff, isTransientNetworkError } from '../utils/retryWithBackoff'
import { pareceSesionVencida, renovarSesion } from '../utils/sesionVencida'
import { getErrorMessage } from '../utils/errorHandling'
import type { CamposCombo } from '../utils/combosPedido'

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

export interface PedidoOfflineItem extends CamposCombo {
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
   * Si la promo del regalo mueve stock. Se sella al encolar porque la cola sólo
   * guardaba `promocionId` y ni al encolar ni antes del replay hay forma de
   * preguntarle a la promo: la validación de stock suma el regalo sólo si esto
   * es true (ver `cantidadesQueDescuentanStock`). No viaja al servidor.
   */
  regaloMueveStock?: boolean;
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
  /**
   * ZZ/FC/VB. Sin esto el replay caia siempre en ZZ y cambiaba el desglose. Un
   * vale blanco ('VB') viaja con total 0 y precio 0 por línea: lo precia el
   * servidor a costo al sincronizar (el front no ve costos).
   */
  tipoFactura?: TipoComprobanteVenta;
  /** A quien se le acredita la venta. Sin esto la cobraba quien sincroniza. */
  preventistaId?: string | null;
  totalNeto?: number;
  totalIva?: number;
  /** Por que se cobro cada precio (mig 148/149). Metadato analitico. */
  origenes?: OrigenPrecioItem[];
  /**
   * Motivo del último intento fallido (`lastError` de la cola). Un fallo sin
   * respuesta del servidor ya no gasta reintentos (#1264), así que el pedido
   * puede quedar pendiente un buen rato: el panel muestra por qué.
   */
  ultimoError?: string;
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
  /**
   * Pedidos que no llegaron al servidor (sin señal): siguen pendientes y no
   * gastaron reintentos (#1264). Van aparte de `errores` porque no son un
   * fallo del pedido, y para no avisar uno por sync cada 30 s.
   */
  sinRespuesta: number;
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
    tipoFactura?: TipoComprobanteVenta;
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
    tipoFactura: payload.tipoFactura as TipoComprobanteVenta | undefined,
    preventistaId: payload.preventistaId as string | null | undefined,
    totalNeto: payload.totalNeto as number | undefined,
    totalIva: payload.totalIva as number | undefined,
    origenes: payload.origenes as OrigenPrecioItem[] | undefined,
    ultimoError: op.lastError
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
    cargoEnvio?: number | null
  } | null

  if (!r || r.idempotente !== true) return null

  if (r.clienteId == null || typeof r.total !== 'number') {
    return {
      motivo: 'El servidor dice que este pedido ya existía, pero no se pudo leer para verificar que sea el mismo. No se marcó como sincronizado.',
      terminal: false
    }
  }

  const mismoCliente = String(r.clienteId) === String(payload.clienteId)
  // Un vale blanco se encola sin total (lo calcula el servidor a costo): no hay
  // total encolado con qué comparar, alcanza con el cliente.
  // El total encolado es el de productos; el servidor guarda productos + cargo
  // de envío, así que se compara `total - cargo`.
  const mismoTotal = payload.tipoFactura === 'VB'
    || Math.abs((r.total - (r.cargoEnvio ?? 0)) - (Number(payload.total) || 0)) < 0.01
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
    // Y del log de sincronización, que crecía sin límite (#1264).
    cleanupOldSyncEvents().catch(err => {
      logger.warn('[useOfflineSync] Error podando eventos de sincronización:', err)
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
    // Un vale blanco no tiene compra mínima (y se encola sin total: lo precia el
    // servidor), así que no pasa por este chequeo.
    // Con cargo de envío (mig 389, #1220) el pedido bajo el mínimo no se rechaza:
    // lo encola y el servidor suma el cargo al sincronizar.
    const regla = pedidoData.tipoFactura === 'VB'
      ? REGLA_MINIMO_POR_DEFECTO
      : await leerReglaMinimoCacheada(currentSucursalIdRef.current).catch(() => REGLA_MINIMO_POR_DEFECTO)
    const motivoMinimo = motivoRechazoMinimo(Number(pedidoData.total) || 0, regla)
    if (motivoMinimo) {
      return { success: false, error: motivoMinimo }
    }

    // Producto desactivado (regla única `esProductoOperativo`, también para las
    // líneas de regalo): se atajan acá y no en el replay, donde el servidor lo
    // rechazaría horas después. Corre aunque `validarStock` sea false: no es
    // una cuestión de stock.
    if (productos.length > 0 && pedidoData.items?.length > 0) {
      const desactivados = itemsConProductoDesactivado(pedidoData.items, productos)
      if (desactivados.length > 0) {
        const nombres = desactivados.map(d => d.nombre).join(', ')
        return {
          success: false,
          error: desactivados.length === 1
            ? `El producto ${nombres} está desactivado y no se puede vender ni regalar. Quitalo del pedido.`
            : `Estos productos están desactivados y no se pueden vender ni regalar: ${nombres}. Quitalos del pedido.`
        }
      }
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
   * Describe, con el stock local, el conflicto de un pedido que el servidor
   * rechazó por stock. Retorna null si el stock local no muestra faltante.
   */
  const validarStockParaSincronizacion = useCallback((
    pedido: PedidoOffline,
    payload: Record<string, unknown>,
    productosActuales: ProductoDB[]
  ): StockConflict | null => {
    const items = payload.items as PedidoOfflineItem[]
    const stockSnapshot = payload.stockSnapshot as StockSnapshot | undefined

    // Misma regla que al encolar (suma por producto, el regalo sólo si mueve
    // stock), sin reservas: acá el stock es el actual del servidor.
    const { itemsSinStock } = validarStockAntesDeEncolar(items, productosActuales)
    const itemsConConflicto: StockConflict['items'] = itemsSinStock.map(sinStock => ({
      productoId: sinStock.productoId,
      nombre: sinStock.nombre,
      solicitado: sinStock.solicitado,
      stockAlMomento: stockSnapshot?.[sinStock.productoId]?.stockAlMomento ?? sinStock.disponible,
      stockActual: sinStock.disponible
    }))

    if (itemsConConflicto.length > 0) {
      return { pedido, items: itemsConConflicto }
    }

    return null
  }, [])

  /**
   * Sincroniza todos los pedidos pendientes con el servidor.
   *
   * El stock lo decide el servidor (#1264). `productosActuales` sólo sirve para
   * describir el conflicto cuando el servidor rechaza por stock, no para
   * frenar el pedido antes de mandarlo: ver el comentario en el loop.
   */
  // `descontarStockFn` ya no es parametro: la RPC `crear_pedido_completo`
  // descuenta el stock dentro de la misma transaccion. El caller lo pasaba y
  // `usePedidos.crearPedido` lo recibia como `_descontarStockFn` sin usarlo.
  const sincronizarPedidos = useCallback(async (
    crearPedidoFn: CrearPedidoFunction,
    productosActuales?: ProductoDB[]
  ): Promise<SyncResult> => {
    if (!isOnline) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sin conexión' }], sinRespuesta: 0 }
    }

    // RACE CONDITION FIX: Verificar si ya está sincronizando usando ref BEFORE any async operations
    if (sincronizandoRef.current) {
      return { success: false, sincronizados: 0, errores: [{ error: 'Sincronización ya en progreso' }], sinRespuesta: 0 }
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
      return { success: true, sincronizados: 0, errores: [], sinRespuesta: 0 }
    }
    const errores: SyncResult['errores'] = []
    const conflictos: StockConflict[] = []
    let sincronizados = 0
    let sinRespuesta = 0

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

        // Sin revalidar el stock local antes de la RPC (#1264). Si el servidor
        // ya registró este pedido y la respuesta se perdió (o la pestaña murió
        // antes de markAsCompleted), el stock local ya lo tiene descontado:
        // "necesita 1, disponible 0" lo marcaba fallido sin llegar a
        // `crear_pedido_idempotente`, que habría devuelto la rama idempotente,
        // y recargarlo a mano lo duplicaba. La RPC busca la clave antes de
        // mirar el stock; si de verdad falta, rechaza, y recién ahí se
        // describe el conflicto (ver el catch).

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
          tipoFactura: payload.tipoFactura as TipoComprobanteVenta | undefined,
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
          // Sin respuesta del servidor (sin señal, "Failed to fetch", timeout
          // del fetch; ya pasó por el backoff de arriba): no gasta reintentos
          // de la cola (#1264, decisión del dueño). Sigue pendiente, con el
          // motivo, y se reintenta en la próxima ventana mientras haya
          // conexión: la RPC es idempotente, reintentar sin límite no duplica.
          if (isTransientNetworkError(error)) {
            await anotarFalloDeRed(op.id!, mensaje)
            sinRespuesta++
            continue
          }
          // Rechazo de negocio determinista del servidor (producto desactivado,
          // compra mínima, total que no coincide...): reintentar no lo cambia,
          // así que no se gastan los reintentos. Un 5xx y stock insuficiente
          // siguen la cola normal. Ver `rechazoEsTerminal`.
          // #1153: si el rechazo es por un regalo que dejó de ser legal y el
          // pedido tiene regalos, el banner ofrece mandarlo sin ellos.
          await markAsFailed(op.id!, mensaje, {
            terminal: rechazoEsTerminal(error),
            rechazoRegalo: esRechazoDeRegalo(error) && quitarRegalosDelPayload(payload) !== null,
            // #1191: idem si el rechazo es por un combo y el pedido tiene combos.
            rechazoCombo: esRechazoDeCombo(error) && quitarCombosDelPayload(payload) !== null,
          })
          if (esRechazoDeStock(error)) {
            // El servidor dijo que falta stock: el detalle por producto sale
            // del stock local, con la misma suma que al encolar. Si la lista
            // local no muestra el faltante (vieja), el conflicto va igual.
            const conflicto = productosActuales && productosActuales.length > 0
              ? validarStockParaSincronizacion(pedido, payload, productosActuales)
              : null
            conflictos.push(conflicto ?? { pedido, items: [] })
            logger.warn(`[useOfflineSync] Conflicto de stock en pedido ${pedido.offlineId}: ${mensaje}`)
          } else {
            errores.push({ pedido, error: mensaje })
          }
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
      success: errores.length === 0 && conflictos.length === 0 && sinRespuesta === 0,
      sincronizados,
      errores,
      conflictos: conflictos.length > 0 ? conflictos : undefined,
      sinRespuesta
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
