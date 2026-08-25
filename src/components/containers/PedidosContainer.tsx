/**
 * PedidosContainer
 *
 * Container que carga pedidos paginados server-side usando TanStack Query.
 * Maneja estado de paginación, filtros, búsqueda y modales.
 * Reemplaza el flujo legacy de App.tsx → VistaPedidos con prop drilling.
 */
import React, { Suspense, useState, useCallback, useMemo, useRef } from 'react'
import { useSearchParams } from 'react-router-dom'
import { calcularNetoVenta } from '../../utils/calculations'
import {
  aplicarDescuentoClienteItems,
  esDescuentoDeCategoria,
  resolverDescuentoPctCliente,
} from '../../utils/descuentoCliente'
import { construirOrigenPrecioItems, type OrigenPrecioItem } from '../../utils/origenPrecio'
import PanelPedidosNoEntregados from '../pedidos/PanelPedidosNoEntregados'
import PanelPedidosTrabados from '../pedidos/PanelPedidosTrabados'
import { fechaLocalISO, fechaHaceDias, getFormaPagoDisplay, formatPrecio } from '../../utils/formatters'
import { explicarErrorDeSesion } from '../../utils/sesionVencida'
import { preventistaPuedeEditar } from '../../utils/permisosPedido'
import { useRequestIdEstable } from '../../hooks/useRequestIdEstable'
import { nuevoRequestId } from '../../utils/idempotencia'
import { useQueryClient } from '@tanstack/react-query'
import { Loader2 } from 'lucide-react'
import {
  usePedidosPaginatedQuery,
  usePedidoStatsQuery,
  EMPTY_PEDIDO_STATS_SUMMARY,
  useCrearPedidoMutation,
  useCambiarEstadoMutation,
  useAsignarTransportistaMutation,
  useQuitarPedidoDeRecorridosMutation,
  useEntregasMasivasMutation,
  useCancelarPedidoMutation,
  useCambiarClientePedidoMutation,
  usePagosMasivosMutation,
  useEntregaYPagoMasivosMutation,
  usePedidosAsignadosQuery,
  useClientesQuery,
  useProductosQuery,
  useTransportistasQuery,
  useUsuariosQuery,
  useCrearClienteMutation,
  useActualizarClienteMutation,
  useDepositoCoords,
  useDestinoCoords,
  useCrearPedidoCambioEnRutaMutation,
  useAplicarCambioParadaMutation,
  useZonasEstandarizadasQuery,
  type RegistrarCambioInput,
} from '../../hooks/queries'
import { useRecorridoActivoQuery } from '../../hooks/queries/useRecorridoActivoQuery'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useOfflineSync } from '../../hooks/useOfflineSync'
import { useNotification } from '../../contexts/NotificationContext'
import { useOptimizarRuta, horarioParaRutear, type RepartidorParam } from '../../hooks/useOptimizarRuta'
import { clasificarBarrida, intercalarSinCoordenadas, type Barrida } from '../../utils/barridas'
import { usePromocionPedido, type RegaloOverride } from '../../hooks/usePromocionPedido'
import { useDebounce } from '../../hooks/useAsync'
import { useResetOnSucursalChange } from '../../hooks/useResetOnSucursalChange'
import { useRegistrarGeolocalizacionPedido } from '../../hooks/useRegistrarGeolocalizacionPedido'
import type { GpsResult, GpsStatus } from '../../hooks/useGeolocationCapture'
import { supabase } from '../../hooks/supabase/base'
import { usePagos } from '../../hooks/supabase/usePagos'
import { retryWithBackoff, isTransientNetworkError } from '../../utils/retryWithBackoff'
import { importConRecarga, lazyWithReload } from '../../utils/lazyWithReload'
import type { PedidoDB, FiltrosPedidosState, PerfilDB, RegistrarSalvedadInput, RegistrarSalvedadResult, PagoDBWithUsuario } from '../../types'
import type { PedidoEditItem } from '../modals/ModalEditarPedido'
import type { CambiarClientePayload } from '../modals/ModalCambiarCliente'
import type { RutaMultiResultadoUI } from '../modals/ModalGestionRutas'

// Lazy load de componentes
const VistaPedidos = lazyWithReload(() => import('../vistas/VistaPedidos'))
const ModalPedido = lazyWithReload(() => import('../modals/ModalPedido'))
const ModalConfirmacion = lazyWithReload(() => import('../modals/ModalConfirmacion'))
const ModalHistorialPedido = lazyWithReload(() => import('../modals/ModalHistorialPedido'))
const ModalEditarPedido = lazyWithReload(() => import('../modals/ModalEditarPedido'))
const ModalPagoPedido = lazyWithReload(() => import('../modals/ModalPagoPedido'))
const ModalEditarNotas = lazyWithReload(() => import('../modals/ModalEditarNotas'))
const ModalFiltroFecha = lazyWithReload(() => import('../modals/ModalFiltroFecha'))
const ModalExportarPDF = lazyWithReload(() => import('../modals/ModalExportarPDF'))
const ModalGestionRutas = lazyWithReload(() => import('../modals/ModalGestionRutas'))
const ModalCambioProducto = lazyWithReload(() => import('../modals/ModalCambioProducto'))
const ModalEntregaConSalvedad = lazyWithReload(() => import('../modals/ModalEntregaConSalvedad'))
const ModalEntregasMasivas = lazyWithReload(() => import('../modals/ModalEntregasMasivas'))
const ModalCancelarPedido = lazyWithReload(() => import('../modals/ModalCancelarPedido'))
const ModalPagosMasivos = lazyWithReload(() => import('../modals/ModalPagosMasivos'))
const ModalEntregaYPagoMasivos = lazyWithReload(() => import('../modals/ModalEntregaYPagoMasivos'))
const ModalMarcarVisita = lazyWithReload(() => import('../modals/ModalMarcarVisita'))
const ModalVisitasHoy = lazyWithReload(() => import('../modals/ModalVisitasHoy'))
const ModalMotivoSinGps = lazyWithReload(() => import('../modals/ModalMotivoSinGps'))

const ITEMS_PER_PAGE = 15

// Ventana por defecto al abrir /pedidos: ultimos N dias.
// El usuario puede ampliar/limpiar el rango con el chip o el modal de filtro
// de fecha. La eleccion no persiste entre sesiones (cada visita arranca aca).
const VENTANA_DEFAULT_DIAS = 30

function buildDefaultFiltros(): FiltrosPedidosState {
  return {
    fechaDesde: fechaHaceDias(VENTANA_DEFAULT_DIAS),
    fechaHasta: null,
    estado: 'todos',
    estadoPago: 'todos',
    transportistaId: 'todos',
    usuarioId: 'todos',
    busqueda: '',
    conSalvedad: 'todos',
  }
}

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

// Confirm modal config matching ModalConfirmacion's expected interface
interface ConfirmConfig {
  visible: boolean
  tipo?: 'danger' | 'warning' | 'success'
  titulo?: string
  mensaje?: string
  /** Campo de fecha opcional; su valor llega como argumento de onConfirm. */
  campoFecha?: { label: string; valorInicial: string; max?: string; ayuda?: string }
  onConfirm?: (fecha?: string) => void
}

/**
 * Campo de fecha para el "marcar entregado" individual.
 *
 * Se arma en cada apertura y no como constante de módulo porque `fechaLocalISO()`
 * cambia a medianoche y esta app vive en pestañas abiertas por días.
 */
const campoFechaEntrega = (): NonNullable<ConfirmConfig['campoFecha']> => ({
  label: 'Fecha de entrega',
  valorInicial: fechaLocalISO(),
  max: fechaLocalISO(),
  ayuda: 'Si estás cargando la entrega de un día anterior, cambiala: define en qué día se contabiliza.',
})

export default function PedidosContainer(): React.ReactElement {
  const queryClient = useQueryClient()
  const { user, isAdmin, isPreventista, isTransportista, isEncargado, isOnline, authReady } = useAuthData()
  // Cola offline del alta. La cola real vive en IndexedDB, asi que esta
  // instancia del hook convive sin problema con la de App.tsx (se avisan por
  // el evento OFFLINE_QUEUE_CHANGED).
  const { guardarPedidoOffline } = useOfflineSync()
  const notify = useNotification()

  // Multi-rol (mig 155): quien vende Y reparte alterna entre la lista y el
  // mapa de la ruta. El estado va en la URL (?vista=ruta) y no en useState
  // porque esto es una PWA que se usa arriba del camión: sobrevive al reload y
  // el botón "atrás" de Android vuelve a la lista en vez de salir de la app.
  const [searchParams, setSearchParams] = useSearchParams()
  const puedeAlternarRuta = isTransportista && !isAdmin && (isPreventista || isEncargado)
  const modoRuta = puedeAlternarRuta && searchParams.get('vista') === 'ruta'

  const verMiRuta = useCallback(() => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.set('vista', 'ruta')
      return next
    })
  }, [setSearchParams])

  const salirDeRuta = useCallback(() => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev)
      next.delete('vista')
      return next
    })
  }, [setSearchParams])

  // Badge del botón "Mi ruta". Comparte cache con RutaActivaTransportista
  // (misma query key), así que no agrega un request.
  const { data: recorridoParaBadge } = useRecorridoActivoQuery(
    puedeAlternarRuta ? user?.id : null,
  )
  const paradasPendientes = useMemo(
    () => (recorridoParaBadge?.paradas ?? []).filter(p => p.estado !== 'entregado').length,
    [recorridoParaBadge],
  )

  // Pagination state
  const [paginaActual, setPaginaActual] = useState(1)
  const [busqueda, setBusqueda] = useState('')
  const debouncedBusqueda = useDebounce(busqueda, 350)
  const [filtros, setFiltros] = useState<FiltrosPedidosState>(buildDefaultFiltros)

  // Queries - use debounced search to avoid firing on every keystroke
  const { registrarPago, registrarPagosBatch, fetchPagosPedido, eliminarPago, actualizarFormaPagoDePago } = usePagos()

  const { data: paginatedResult, isLoading: loadingPedidos } = usePedidosPaginatedQuery(
    paginaActual, ITEMS_PER_PAGE, filtros, debouncedBusqueda, authReady
  )
  const { data: statsSummary = EMPTY_PEDIDO_STATS_SUMMARY } = usePedidoStatsQuery(
    filtros, debouncedBusqueda, authReady
  )
  const { data: clientes = [] } = useClientesQuery()
  const { data: productos = [] } = useProductosQuery()
  const { data: transportistas = [] } = useTransportistasQuery()
  // Zonas activas (para elegir zonas preferidas por chofer en el split)
  const { data: zonasRuta = [] } = useZonasEstandarizadasQuery()
  const { data: usuariosTodos = [] } = useUsuariosQuery()
  const usuarios = useMemo(
    () => (isAdmin ? usuariosTodos : []),
    [isAdmin, usuariosTodos],
  )

  // Mutations
  const crearPedido = useCrearPedidoMutation()
  // Geolocalización: solo se captura cuando el usuario es preventista. El
  // RPC backend valida igualmente la autorización; este flag solo evita
  // mostrar el prompt nativo de GPS a roles que no son target.
  const { capturarGps, registrarGpsPedido } = useRegistrarGeolocalizacionPedido()
  const cambiarEstado = useCambiarEstadoMutation()
  const asignarTransportistaMut = useAsignarTransportistaMutation()
  const quitarDeRecorridosMut = useQuitarPedidoDeRecorridosMutation()
  const entregasMasivas = useEntregasMasivasMutation()
  const cancelarPedidoMut = useCancelarPedidoMutation()
  const cambiarClientePedidoMut = useCambiarClientePedidoMutation()
  const pagosMasivos = usePagosMasivosMutation()
  const entregaYPagoMasivos = useEntregaYPagoMasivosMutation()
  // UUIDs de idempotencia de las acciones masivas de cobro (mig 167).
  const requestIdMasivo = useRequestIdEstable()
  // UUID de idempotencia del cobro que se declara al CREAR el pedido (mig 167).
  const requestIdAlta = useRequestIdEstable()
  /**
   * Clave de idempotencia del ALTA en sí (mig 071, `pedidos.offline_id`).
   *
   * No se deriva del contenido del pedido a propósito: un cliente puede repetir
   * el mismo pedido en el día, y una huella por contenido lo haría desaparecer
   * como si fuera un duplicado. La unidad correcta es la INTENCIÓN de alta: se
   * acuña al primer intento de guardar y se descarta cuando el formulario se
   * limpia (`resetNuevoPedido`), así que todo reintento del mismo pedido —el
   * automático de react-query incluido— reusa el mismo id y el servidor lo
   * reconoce, mientras que un pedido nuevo arranca con otro.
   */
  const altaIdRef = useRef<string | null>(null)
  const crearClienteMut = useCrearClienteMutation()
  const actualizarClienteMut = useActualizarClienteMutation()
  const crearCambioEnRutaMut = useCrearPedidoCambioEnRutaMutation()
  const aplicarCambioParadaMut = useAplicarCambioParadaMutation()

  // Route optimization
  const { loading: loadingOptimizacion, rutaOptimizada, error: errorOptimizacion, optimizarRuta, optimizarRutaMulti, setRutaOptimizada, limpiarRuta } = useOptimizarRuta()
  const deposito = useDepositoCoords()
  const destinoRuta = useDestinoCoords()
  // Inyecta el depósito (origen) y el punto de llegada opcional (destino) de la
  // sucursal en la optimización, así el lado que optimiza y el mapa usan la
  // MISMA ubicación. destino null = la ruta termina en el depósito.
  const optimizarRutaConDeposito = useCallback(
    (transportistaId: string, pedidosData?: PedidoDB[], fecha?: string, horaInicio?: string, horaFin?: string) =>
      optimizarRuta(transportistaId, pedidosData, deposito, destinoRuta, { fecha, horaInicio, horaFin }),
    [optimizarRuta, deposito, destinoRuta],
  )
  const optimizarRutaMultiConDeposito = useCallback(
    (repartidores: RepartidorParam[], pedidosData?: PedidoDB[], fecha?: string, horaInicio?: string, horaFin?: string) =>
      optimizarRutaMulti(repartidores, pedidosData, deposito, destinoRuta, { fecha, horaInicio, horaFin }),
    [optimizarRutaMulti, deposito, destinoRuta],
  )

  // Export
  const [exportando, setExportando] = useState(false)

  // Derived data
  const pedidos = useMemo(() => paginatedResult?.data ?? [], [paginatedResult?.data])
  const totalCount = paginatedResult?.totalCount ?? 0
  const totalPaginas = Math.ceil(totalCount / ITEMS_PER_PAGE)

  // Modal state
  const [modalPedidoOpen, setModalPedidoOpen] = useState(false)
  const [modalHistorialOpen, setModalHistorialOpen] = useState(false)
  const [modalEditarOpen, setModalEditarOpen] = useState(false)
  const [modalFiltroFechaOpen, setModalFiltroFechaOpen] = useState(false)
  const [modalExportarPDFOpen, setModalExportarPDFOpen] = useState(false)
  const [modalOptimizarRutaOpen, setModalOptimizarRutaOpen] = useState(false)
  const [modalEntregaSalvedadOpen, setModalEntregaSalvedadOpen] = useState(false)
  const [modalEntregasMasivasOpen, setModalEntregasMasivasOpen] = useState(false)
  const [modalCancelarOpen, setModalCancelarOpen] = useState(false)
  const [modalPagosMasivosOpen, setModalPagosMasivosOpen] = useState(false)
  const [modalEntregaYPagoMasivosOpen, setModalEntregaYPagoMasivosOpen] = useState(false)
  const [modalNotasOpen, setModalNotasOpen] = useState(false)
  const [modalPagoPedidoOpen, setModalPagoPedidoOpen] = useState(false)
  const [modalMarcarVisitaOpen, setModalMarcarVisitaOpen] = useState(false)
  const [modalVisitasHoyOpen, setModalVisitasHoyOpen] = useState(false)
  // Cambio/devolución como parada (desde la pantalla de Pedidos)
  const [cambioEnRutaOpen, setCambioEnRutaOpen] = useState(false)
  // Resultado del split multi-repartidor (vista de resultado del modal de rutas)
  const [rutaMultiResultado, setRutaMultiResultado] = useState<RutaMultiResultadoUI | null>(null)
  const [pedidoPago, setPedidoPago] = useState<PedidoDB | null>(null)
  const [pagosPreviosPedido, setPagosPreviosPedido] = useState<PagoDBWithUsuario[]>([])

  // Pool de pedidos para el modal de gestión de rutas: TODOS los pendiente /
  // en_preparacion de la sucursal, sin paginar (la lista paginada de 15 dejaba
  // pedidos afuera). El armado de ruta los asigna + marca "en camino".
  const { data: pedidosParaRuta = [], isLoading: loadingPedidosRuta } = usePedidosAsignadosQuery(modalOptimizarRutaOpen)
  const [loadingPagosPrevios, setLoadingPagosPrevios] = useState(false)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Pedido-specific state for modals
  const [pedidoHistorial, setPedidoHistorial] = useState<PedidoDB | null>(null)
  const [historialCambios, setHistorialCambios] = useState<unknown[]>([])
  const [cargandoHistorial, setCargandoHistorial] = useState(false)
  const [pedidoEditando, setPedidoEditando] = useState<PedidoDB | null>(null)
  const [pedidoParaSalvedad, setPedidoParaSalvedad] = useState<PedidoDB | null>(null)
  const [pedidoCancelando, setPedidoCancelando] = useState<PedidoDB | null>(null)
  const [pedidoNotasEditando, setPedidoNotasEditando] = useState<PedidoDB | null>(null)
  const [guardando, setGuardando] = useState(false)
  // Estado de "entrega con pago pendiente" (declarado aca para poder
  // resetearlo en useResetOnSucursalChange junto al resto de modales).
  const [pedidoEntregaConPago, setPedidoEntregaConPago] = useState<PedidoDB | null>(null)

  // Cerrar todos los modales al cambiar de sucursal: evita que queden con
  // datos de la sucursal anterior (hooks legacy con estado local que no se
  // invalidan con queryClient.invalidateQueries).
  useResetOnSucursalChange(() => {
    setModalPedidoOpen(false)
    setModalHistorialOpen(false)
    setModalEditarOpen(false)
    setModalFiltroFechaOpen(false)
    setModalExportarPDFOpen(false)
    setModalOptimizarRutaOpen(false)
    setCambioEnRutaOpen(false)
    setRutaMultiResultado(null)
    setModalEntregaSalvedadOpen(false)
    setModalEntregasMasivasOpen(false)
    setModalCancelarOpen(false)
    setModalPagosMasivosOpen(false)
    setModalEntregaYPagoMasivosOpen(false)
    setModalNotasOpen(false)
    setModalPagoPedidoOpen(false)
    setModalMarcarVisitaOpen(false)
    setModalVisitasHoyOpen(false)
    setPedidoPago(null)
    setPedidoHistorial(null)
    setPedidoEditando(null)
    setPedidoParaSalvedad(null)
    setPedidoCancelando(null)
    setPedidoNotasEditando(null)
    setPedidoEntregaConPago(null)
    setConfirmConfig({ visible: false })
  })

  // Nuevo pedido form state
  const [nuevoPedido, setNuevoPedido] = useState({
    clienteId: '',
    items: [] as Array<{ productoId: string; cantidad: number; precioUnitario: number }>,
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0,
    fecha: fechaLocalISO(),
    tipoFactura: 'ZZ' as 'ZZ' | 'FC',
    fechaEntregaProgramada: undefined as string | undefined,
    preventistaId: undefined as string | undefined,
  })

  // Override del producto del regalo al crear (solo admin). promoId -> producto elegido.
  const [regalosOverride, setRegalosOverride] = useState<Record<string, RegaloOverride>>({})

  // Promos quitadas a mano al crear el pedido (admin/preventista/encargado).
  // Guarda {id, nombre} para mostrar la fila "quitada" y restaurar sin re-resolver.
  const [promosEliminadas, setPromosEliminadas] = useState<Array<{ promoId: string; promoNombre: string }>>([])
  const promosEliminadasSet = useMemo(() => new Set(promosEliminadas.map(p => p.promoId)), [promosEliminadas])

  const resetNuevoPedido = useCallback(() => {
    setNuevoPedido({
      clienteId: '', items: [], notas: '',
      formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0,
      fecha: fechaLocalISO(),
      tipoFactura: 'ZZ' as 'ZZ' | 'FC',
      fechaEntregaProgramada: undefined,
      preventistaId: undefined,
    })
    setRegalosOverride({})
    setPromosEliminadas([])
    // Formulario limpio = próxima alta es otra intención. Ver `altaIdRef`.
    altaIdRef.current = null
  }, [])

  // Admin elige/cambia el producto del regalo de una promo al crear el pedido.
  // El producto elegido se persiste en la bonificación; el RPC ajusta el stock
  // (modo A descuenta el producto elegido; modo Fracción su contenedor por sabor).
  const handleCambiarRegaloCreacion = useCallback((promoId: string, productoId: string) => {
    const prod = productos.find(p => String(p.id) === String(productoId))
    setRegalosOverride(prev => ({
      ...prev,
      [String(promoId)]: { productoId: String(productoId), descripcionRegalo: prod?.nombre },
    }))
  }, [productos])

  // Quitar una promo del pedido en creación. La confirmación se muestra DENTRO
  // de ModalPedido (Radix Dialog modal); una confirmación disparada desde acá
  // quedaba detrás del overlay y era inalcanzable, así que la quita fallaba en
  // silencio. Este callback recibe la orden ya confirmada y solo la aplica.
  const handleEliminarPromoCreacion = useCallback((promoId: string, promoNombre: string) => {
    setPromosEliminadas(prev =>
      prev.some(p => p.promoId === promoId) ? prev : [...prev, { promoId, promoNombre }],
    )
  }, [])

  const handleRestaurarPromoCreacion = useCallback((promoId: string) => {
    setPromosEliminadas(prev => prev.filter(p => p.promoId !== promoId))
  }, [])

  // Resolve wholesale prices + promos (con override del regalo elegido por admin
  // y las promos que el usuario haya quitado a mano)
  // `preciosResueltos` se usa además para etiquetar el origen del precio de cada
  // ítem al guardar (mig 148/149): es lo único que sabe si el precio lo fijó una
  // escala mayorista y cuál.
  const { itemsFinales, preciosResueltos } = usePromocionPedido(nuevoPedido.items, undefined, regalosOverride, promosEliminadasSet)

  // =========================================================================
  // VistaPedidos handlers
  // =========================================================================

  const handleBusquedaChange = useCallback((value: string) => {
    setBusqueda(value)
    setPaginaActual(1)
  }, [])

  const handleFiltrosChange = useCallback((nuevosFiltros: Partial<FiltrosPedidosState>) => {
    setFiltros(prev => ({ ...prev, ...nuevosFiltros }))
    setPaginaActual(1)
  }, [])

  const handlePageChange = useCallback((page: number) => {
    setPaginaActual(page)
  }, [])

  // `pedidoEntregaConPago` se declara arriba (junto al resto de estado de
  // modales) para entrar en el reset de useResetOnSucursalChange.
  // Marca el flujo "marcar entregado":
  //   - Pedido ya pagado totalmente → confirm simple.
  //   - Saldo pendiente → abrir ModalPagoPedido en modoEntregaTransportista
  //     para cobrar o entregar sin pago en el mismo gesto.

  // Cargar pagos previos del pedido seleccionado para mostrar en el modal de pago.
  // Definido antes de handleMarcarEntregado porque este lo invoca al abrir el modal.
  const refreshPagosPedido = useCallback(async (pedidoId: string) => {
    setLoadingPagosPrevios(true)
    try {
      const previos = await fetchPagosPedido(pedidoId)
      setPagosPreviosPedido(previos)
    } finally {
      setLoadingPagosPrevios(false)
    }
  }, [fetchPagosPedido])

  const handleMarcarEntregado = useCallback(async (pedido: PedidoDB) => {
    // Parada de cambio/devolución (canal='cambio'): al completarla se ajusta
    // stock + saldo (aplicar_cambio_de_parada, idempotente) y recién después se
    // marca el pedido entregado. No hay cobro (total 0).
    if (pedido.canal === 'cambio') {
      setConfirmConfig({
        visible: true, titulo: 'Confirmar cambio/devolución',
        mensaje: `¿Confirmar el cambio/devolución del pedido #${pedido.id}? Se ajustará el stock y la cuenta del cliente.`,
        tipo: 'success',
        campoFecha: campoFechaEntrega(),
        onConfirm: async (fechaEntrega?: string) => {
          try {
            await aplicarCambioParadaMut.mutateAsync(String(pedido.id))
            await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'entregado', fechaEntrega })
            notify.success('Cambio/devolución completado')
          } catch (e) { notify.error((e as Error).message) }
          setConfirmConfig({ visible: false })
        },
      })
      return
    }
    if (pedido.estado_pago === 'pagado') {
      setConfirmConfig({
        visible: true, titulo: 'Confirmar entrega',
        mensaje: `¿Confirmar entrega del pedido #${pedido.id}?`, tipo: 'success',
        // La fecha es editable porque lo habitual es marcar hoy las entregas de
        // ayer: con la fecha fija en hoy, la rendición del día del reparto
        // quedaba vacía y la del día que se cargó, inflada.
        campoFecha: campoFechaEntrega(),
        onConfirm: async (fechaEntrega?: string) => {
          try {
            await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'entregado', fechaEntrega })
            notify.success('Pedido entregado')
          } catch (e) { notify.error((e as Error).message) }
          setConfirmConfig({ visible: false })
        },
      })
      return
    }
    // Saldo pendiente: abrir modal de pago en modo entrega
    setPedidoEntregaConPago(pedido)
    setPedidoPago(pedido)
    setPagosPreviosPedido([])
    setModalPagoPedidoOpen(true)
    await refreshPagosPedido(String(pedido.id))
  }, [cambiarEstado, notify, refreshPagosPedido, aplicarCambioParadaMut])

  const handleDesmarcarEntregado = useCallback((pedido: PedidoDB) => {
    setConfirmConfig({
      visible: true, titulo: 'Revertir entrega',
      mensaje: `¿Revertir entrega del pedido #${pedido.id}?`, tipo: 'warning',
      onConfirm: async () => {
        try {
          await cambiarEstado.mutateAsync({
            pedidoId: pedido.id,
            nuevoEstado: pedido.transportista_id ? 'asignado' : 'pendiente',
          })
          notify.warning('Pedido revertido')
        } catch (e) { notify.error((e as Error).message) }
        setConfirmConfig({ visible: false })
      },
    })
  }, [cambiarEstado, notify])

  const handleMarcarEnPreparacion = useCallback((pedido: PedidoDB) => {
    setConfirmConfig({
      visible: true, titulo: 'Marcar en preparación',
      mensaje: `¿Marcar pedido #${pedido.id} como "En preparación"?`, tipo: 'success',
      onConfirm: async () => {
        try {
          await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'en_preparacion' })
          notify.success('Pedido en preparación')
        } catch (e) { notify.error((e as Error).message) }
        setConfirmConfig({ visible: false })
      },
    })
  }, [cambiarEstado, notify])

  const handleVolverAPendiente = useCallback((pedido: PedidoDB) => {
    setConfirmConfig({
      visible: true, titulo: 'Volver a pendiente',
      mensaje: `¿Volver el pedido #${pedido.id} a estado "Pendiente"? Si está en una ruta activa, se quitará de ella.`, tipo: 'warning',
      onConfirm: async () => {
        try {
          if (pedido.transportista_id) {
            await asignarTransportistaMut.mutateAsync({ pedidoId: pedido.id, transportistaId: null })
          }
          await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'pendiente' })
          // Sacarlo de la(s) ruta(s) en curso para que no quede como parada
          // fantasma; así reaparece limpio en el pool de "Armar ruta".
          await quitarDeRecorridosMut.mutateAsync({ pedidoId: pedido.id })
          notify.warning('Pedido vuelto a pendiente')
        } catch (e) { notify.error((e as Error).message) }
        setConfirmConfig({ visible: false })
      },
    })
  }, [cambiarEstado, asignarTransportistaMut, quitarDeRecorridosMut, notify])

  const handleVerHistorial = useCallback(async (pedido: PedidoDB) => {
    setPedidoHistorial(pedido)
    setModalHistorialOpen(true)
    setCargandoHistorial(true)
    try {
      const { data } = await supabase
        .from('pedido_historial').select('*')
        .eq('pedido_id', pedido.id)
        .order('created_at', { ascending: false })
      const filas = (data || []) as Array<Record<string, unknown>>
      // Resolver usuario_id → nombre: la tabla guarda solo el id y el modal
      // muestra `cambio.usuario?.nombre` (si no, "Sistema"). Mismo patrón que
      // fetchAllFilteredPedidos. Sin esto, todo el historial salía como "Sistema".
      const usuarioIds = Array.from(
        new Set(filas.map(f => f.usuario_id).filter(Boolean)),
      ) as string[]
      let perfilesMap: Record<string, { nombre: string }> = {}
      if (usuarioIds.length > 0) {
        const { data: perfiles } = await supabase
          .from('perfiles').select('id, nombre').in('id', usuarioIds)
        if (perfiles) {
          perfilesMap = Object.fromEntries(
            (perfiles as Array<{ id: string; nombre: string }>).map(p => [p.id, { nombre: p.nombre }]),
          )
        }
      }
      setHistorialCambios(filas.map(f => ({
        ...f,
        usuario: f.usuario_id ? (perfilesMap[f.usuario_id as string] ?? null) : null,
      })))
    } catch (e) {
      notify.error('Error al cargar historial: ' + (e as Error).message)
      setHistorialCambios([])
    } finally { setCargandoHistorial(false) }
  }, [notify])

  const handleEditarPedido = useCallback((pedido: PedidoDB) => {
    setPedidoEditando(pedido)
    setModalEditarOpen(true)
  }, [])

  const handleEditarNotas = useCallback((pedido: PedidoDB) => {
    setPedidoNotasEditando(pedido)
    setModalNotasOpen(true)
  }, [])

  const handleGuardarNotas = useCallback(async (notas: string) => {
    if (!pedidoNotasEditando) return
    setGuardando(true)
    try {
      const { error } = await supabase.from('pedidos').update({ notas }).eq('id', pedidoNotasEditando.id)
      if (error) throw error
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      setModalNotasOpen(false)
      setPedidoNotasEditando(null)
      notify.success('Observaciones actualizadas')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoNotasEditando, notify, queryClient])

  const handleMarcarEntregadoConSalvedad = useCallback((pedido: PedidoDB) => {
    setPedidoParaSalvedad(pedido)
    setModalEntregaSalvedadOpen(true)
  }, [])

  const handleCancelarPedido = useCallback((pedido: PedidoDB) => {
    // Si el pedido ya tiene plata cobrada, avisar ANTES: cancelar no devuelve
    // nada solo, y hasta ahora el pedido cancelado no ofrecia ninguna accion de
    // pago, asi que ese cobro quedaba colgado sin camino desde la app.
    const cobrado = Number(pedido.monto_pagado ?? 0)
    if (cobrado > 0) {
      setConfirmConfig({
        visible: true, tipo: 'warning', titulo: 'El pedido tiene pagos registrados',
        mensaje:
          `Este pedido tiene ${formatPrecio(cobrado)} cobrados. Cancelarlo NO devuelve ` +
          'esa plata ni anula los pagos. Si el cobro no corresponde, anulalo desde ' +
          '"Ver/Anular Pagos" — la accion sigue disponible con el pedido cancelado. ' +
          'Al confirmar se continua con la cancelacion.',
        onConfirm: () => {
          setConfirmConfig({ visible: false })
          setPedidoCancelando(pedido)
          setModalCancelarOpen(true)
        },
      })
      return
    }
    setPedidoCancelando(pedido)
    setModalCancelarOpen(true)
  }, [])

  const handleConfirmarCancelacion = useCallback(async (motivo: string, tipo?: string) => {
    if (!pedidoCancelando) return
    setGuardando(true)
    try {
      await cancelarPedidoMut.mutateAsync({ pedidoId: pedidoCancelando.id, motivo, usuarioId: user?.id, tipo })
      setModalCancelarOpen(false)
      setPedidoCancelando(null)
      notify.success('Pedido cancelado y stock restaurado')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoCancelando, cancelarPedidoMut, user, notify])

  const handleEntregasMasivas = useCallback(async (transportistaId: string, pedidoIds: string[], fechaEntrega: string) => {
    setGuardando(true)
    try {
      await entregasMasivas.mutateAsync({ pedidoIds, transportistaId, fecha: fechaEntrega })
      setModalEntregasMasivasOpen(false)
      notify.success(`${pedidoIds.length} pedido${pedidoIds.length !== 1 ? 's' : ''} marcado${pedidoIds.length !== 1 ? 's' : ''} como entregado${pedidoIds.length !== 1 ? 's' : ''}`)
    } catch (e) { notify.error('Error en entregas masivas: ' + (e as Error).message) }
    setGuardando(false)
  }, [entregasMasivas, notify])

  const handlePagosMasivos = useCallback(async (formaPago: string, pedidoIds: string[], fechaPago: string) => {
    setGuardando(true)
    try {
      await pagosMasivos.mutateAsync({
        pedidoIds, formaPago, fecha: fechaPago,
        // Mismo lote + misma forma + misma fecha = el mismo cobro. Un reintento
        // tras un error de red no vuelve a cobrarlo (mig 167).
        clientRequestId: requestIdMasivo(`pagos|${fechaPago}|${formaPago}|${[...pedidoIds].sort().join(',')}`),
      })
      setModalPagosMasivosOpen(false)
      notify.success(`${pedidoIds.length} pedido${pedidoIds.length !== 1 ? 's' : ''} marcado${pedidoIds.length !== 1 ? 's' : ''} como pagado${pedidoIds.length !== 1 ? 's' : ''}`)
    } catch (e) { notify.error('Error en pagos masivos: ' + (e as Error).message) }
    setGuardando(false)
  }, [pagosMasivos, notify, requestIdMasivo])

  const handleEntregaYPagoMasivos = useCallback(async (
    transportistaId: string,
    formaPago: string,
    ids: { idsEntregar: string[]; idsCobrar: string[] },
    fecha: string,
  ) => {
    setGuardando(true)
    try {
      const huella = `${fecha}|${formaPago}|${transportistaId}`
      await entregaYPagoMasivos.mutateAsync({
        ...ids, transportistaId, formaPago, fecha,
        // Son dos RPCs distintas dentro de la misma mutation: un UUID cada una.
        clientRequestIdCobrar: requestIdMasivo(`cobrar|${huella}|${[...ids.idsCobrar].sort().join(',')}`),
        clientRequestIdEntregar: requestIdMasivo(`entregar|${huella}|${[...ids.idsEntregar].sort().join(',')}`),
      })
      setModalEntregaYPagoMasivosOpen(false)
      const total = ids.idsEntregar.length + ids.idsCobrar.length
      notify.success(`${total} pedido${total !== 1 ? 's' : ''} procesado${total !== 1 ? 's' : ''}`)
    } catch (e) { notify.error('Error en entrega y pago masivos: ' + (e as Error).message) }
    setGuardando(false)
  }, [entregaYPagoMasivos, notify, requestIdMasivo])

  // Fetch todos los pedidos con filtros actuales (sin paginación) para export
  const fetchAllFilteredPedidos = useCallback(async (): Promise<PedidoDB[]> => {
    const hasSearch = debouncedBusqueda && debouncedBusqueda.trim().length > 0
    const selectStr = hasSearch
      ? '*, cliente:clientes!inner(*), items:pedido_items(*, producto:productos(*)), pagos(forma_pago, monto)'
      : '*, cliente:clientes(*), items:pedido_items(*, producto:productos(*)), pagos(forma_pago, monto)'

    let query = supabase
      .from('pedidos')
      .select(selectStr)
      .order('created_at', { ascending: false })

    if (filtros.estado && filtros.estado !== 'todos') query = query.eq('estado', filtros.estado)
    if (filtros.estadoPago && filtros.estadoPago !== 'todos') query = query.eq('estado_pago', filtros.estadoPago)
    if (filtros.transportistaId && filtros.transportistaId !== 'todos') query = query.eq('transportista_id', filtros.transportistaId)
    if (filtros.fechaDesde) query = query.gte('fecha', filtros.fechaDesde)
    if (filtros.fechaHasta) query = query.lte('fecha', filtros.fechaHasta)
    if (!filtros.verCancelados && filtros.estado !== 'cancelado') query = query.neq('estado', 'cancelado')
    if (hasSearch) {
      const trimmed = debouncedBusqueda!.trim()
      query = query.or(
        `nombre_fantasia.ilike.%${trimmed}%,razon_social.ilike.%${trimmed}%,cuit.ilike.%${trimmed}%,direccion.ilike.%${trimmed}%`,
        { referencedTable: 'clientes' }
      )
    }

    const { data, error } = await query
    if (error) throw error

    // Enrich with perfiles
    const perfilIds = new Set<string>()
    for (const pedido of (data || [])) {
      if (pedido.usuario_id) perfilIds.add(pedido.usuario_id as string)
      if (pedido.transportista_id) perfilIds.add(pedido.transportista_id as string)
    }
    let perfilesMap: Record<string, PerfilDB> = {}
    if (perfilIds.size > 0) {
      const { data: perfiles } = await supabase
        .from('perfiles').select('id, nombre, email').in('id', Array.from(perfilIds))
      if (perfiles) {
        perfilesMap = Object.fromEntries((perfiles as PerfilDB[]).map(p => [p.id, p]))
      }
    }

    return (data || []).map(pedido => ({
      ...pedido,
      usuario: pedido.usuario_id ? perfilesMap[pedido.usuario_id] : null,
      transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id] : null,
    })) as PedidoDB[]
  }, [debouncedBusqueda, filtros])

  // Excel export (multi-sheet con ExcelJS)
  const handleExportarExcel = useCallback(async (modo: 'pagina' | 'filtro' = 'pagina') => {
    setExportando(true)
    try {
      const { createMultiSheetExcel } = await import('../../utils/excel')

      // Determinar qué datos exportar
      const pedidosExport = modo === 'filtro' ? await fetchAllFilteredPedidos() : pedidos

      // Hoja 1: Pedidos
      const pedidosData = pedidosExport.map(p => ({
        ID: p.id,
        Cliente: (p.cliente as { nombre_fantasia?: string })?.nombre_fantasia || '',
        Direccion: (p.cliente as { direccion?: string })?.direccion || '',
        Telefono: (p.cliente as { telefono?: string })?.telefono || '',
        Estado: p.estado,
        'Forma Pago': getFormaPagoDisplay(p as { forma_pago?: string | null; pagos?: Array<{ forma_pago: string }> }),
        'Estado Pago': p.estado_pago || '',
        Total: p.total,
        'Monto Pagado': p.monto_pagado || 0,
        Transportista: (p.transportista as { nombre?: string })?.nombre || '',
        Preventista: (p.usuario as { nombre?: string })?.nombre || '',
        Notas: p.notas || '',
        Fecha: p.fecha || p.created_at || '',
      }))

      // Hoja 2: Detalle Items
      const itemsData = pedidosExport.flatMap(p =>
        (p.items || []).map(item => ({
          'Pedido ID': p.id,
          Cliente: (p.cliente as { nombre_fantasia?: string })?.nombre_fantasia || '',
          Producto: (item.producto as { nombre?: string })?.nombre || '',
          Codigo: (item.producto as { codigo?: string })?.codigo || '',
          Cantidad: item.cantidad,
          'Precio Unit.': item.precio_unitario,
          Subtotal: item.cantidad * item.precio_unitario,
        }))
      )

      // Hoja 3: Resumen Estados
      const estadosCounts: Record<string, number> = {}
      pedidosExport.forEach(p => { estadosCounts[p.estado] = (estadosCounts[p.estado] || 0) + 1 })
      const estadosData = Object.entries(estadosCounts).map(([estado, cantidad]) => ({
        Estado: estado,
        Cantidad: cantidad,
        Porcentaje: `${((cantidad / pedidosExport.length) * 100).toFixed(1)}%`,
      }))

      // Hoja 4: Resumen Pagos
      const pagosCounts: Record<string, { cantidad: number; total: number }> = {}
      pedidosExport.forEach(p => {
        const ep = p.estado_pago || 'pendiente'
        if (!pagosCounts[ep]) pagosCounts[ep] = { cantidad: 0, total: 0 }
        pagosCounts[ep].cantidad++
        pagosCounts[ep].total += p.total
      })
      const pagosData = Object.entries(pagosCounts).map(([estado, info]) => ({
        'Estado Pago': estado,
        Cantidad: info.cantidad,
        'Total $': info.total,
      }))

      const suffix = modo === 'filtro' ? 'completo' : 'pagina'
      await createMultiSheetExcel([
        { name: 'Pedidos', data: pedidosData, columnWidths: [8, 25, 30, 15, 12, 15, 12, 12, 12, 20, 20, 30, 18] },
        { name: 'Detalle Items', data: itemsData, columnWidths: [10, 25, 35, 12, 10, 12, 12] },
        { name: 'Resumen Estados', data: estadosData, columnWidths: [20, 12, 12] },
        { name: 'Resumen Pagos', data: pagosData, columnWidths: [20, 12, 15] },
      ], `pedidos-${suffix}-${fechaLocalISO()}`)

      notify.success(`Excel exportado: ${pedidosExport.length} pedidos`)
    } catch {
      notify.error('Error al exportar Excel')
    }
    setExportando(false)
  }, [pedidos, notify, fetchAllFilteredPedidos])

  // =========================================================================
  // Modal-specific handlers
  // =========================================================================

  // ModalEditarPedido: onSave({ notas, fecha?, fechaEntrega?, fechaEntregaProgramada? })
  // Pago se gestiona desde ModalRegistrarPago (separate flow).
  const handleGuardarEdicion = useCallback(async (data: { notas: string; fecha?: string; fechaEntrega?: string; fechaEntregaProgramada?: string }) => {
    if (!pedidoEditando) return
    setGuardando(true)
    try {
      const updateData: Record<string, unknown> = { notas: data.notas }
      if (data.fecha) updateData.fecha = data.fecha
      if (data.fechaEntrega) {
        updateData.fecha_entrega = data.fechaEntrega.includes('T') ? data.fechaEntrega : `${data.fechaEntrega}T12:00:00Z`
      }
      if (data.fechaEntregaProgramada) updateData.fecha_entrega_programada = data.fechaEntregaProgramada
      const { error } = await supabase.from('pedidos').update(updateData).eq('id', pedidoEditando.id)
      if (error) throw error

      // Si el pedido estaba "en camino" (asignado a una ruta activa) y se le
      // cambió alguna fecha, vuelve a pendiente y sale de la ruta: al moverlo de
      // día ya no pertenece a esa ruta y debe poder re-rutearse. Mismo patrón que
      // "Volver a pendiente" (handleVolverAPendiente). data.fecha llega siempre que
      // el usuario puede editar fechas, así que se compara contra el valor original.
      const fechaCambio =
        (data.fecha !== undefined && data.fecha !== pedidoEditando.fecha) ||
        (data.fechaEntregaProgramada !== undefined &&
          data.fechaEntregaProgramada !== (pedidoEditando.fecha_entrega_programada || ''))
      const revertido = fechaCambio && pedidoEditando.estado === 'asignado'
      if (revertido) {
        if (pedidoEditando.transportista_id) {
          await asignarTransportistaMut.mutateAsync({ pedidoId: pedidoEditando.id, transportistaId: null })
        }
        await cambiarEstado.mutateAsync({ pedidoId: pedidoEditando.id, nuevoEstado: 'pendiente' })
        await quitarDeRecorridosMut.mutateAsync({ pedidoId: pedidoEditando.id })
      }

      // Invalidar cache para que los cambios se reflejen en la UI. Incluye la
      // familia recorridos* para que la hoja de ruta/comanda re-descargada desde
      // Exportaciones refleje cambios de fecha/notas (sino sirve datos cacheados).
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      queryClient.invalidateQueries({ queryKey: ['recorridos'] })
      queryClient.invalidateQueries({ queryKey: ['recorridos-hoja-ruta'] })
      queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
      queryClient.invalidateQueries({ queryKey: ['recorrido-existente'] })
      setModalEditarOpen(false)
      setPedidoEditando(null)
      if (revertido) {
        notify.warning('Pedido actualizado. Estaba en camino: volvió a pendiente y se quitó de la ruta activa.')
      } else {
        notify.success('Pedido actualizado')
      }
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoEditando, notify, queryClient, asignarTransportistaMut, cambiarEstado, quitarDeRecorridosMut])

  // ModalEditarPedido: onSaveItems - guardar cambios de items via RPC.
  // Reenvía el desglose fiscal para que el RPC actualice correctamente
  // total_neto/total_iva (sin esto, los COALESCE(..., precio) del RPC dejaban
  // todo el monto como "neto" ignorando el IVA en facturas FC).
  const handleGuardarItemsEdicion = useCallback(async (items: PedidoEditItem[], origenes?: OrigenPrecioItem[]) => {
    if (!pedidoEditando) return
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId,
      cantidad: item.cantidad,
      precio_unitario: item.precioUnitario,
      ...(item.esBonificacion ? { es_bonificacion: true } : {}),
      ...(item.promocionId ? { promocion_id: item.promocionId } : {}),
      ...(item.neto_unitario !== undefined ? { neto_unitario: item.neto_unitario } : {}),
      ...(item.iva_unitario !== undefined ? { iva_unitario: item.iva_unitario } : {}),
      ...(item.impuestos_internos_unitario !== undefined ? { impuestos_internos_unitario: item.impuestos_internos_unitario } : {}),
      ...(item.porcentaje_iva !== undefined ? { porcentaje_iva: item.porcentaje_iva } : {}),
    }))
    const { data, error } = await supabase.rpc('actualizar_pedido_items', {
      p_pedido_id: pedidoEditando.id,
      p_items_nuevos: itemsParaRPC,
      p_usuario_id: user?.id ?? null
    })
    if (error) throw error
    const response = data as { success: boolean; errores?: string[] }
    if (!response.success) {
      throw new Error(response.errores?.join(', ') || 'Error al actualizar items')
    }
    // El RPC borro y reinserto los items, asi que el origen del precio que se
    // habia registrado al crear el pedido ya no existe: hay que reponerlo o esta
    // venta pasa a comisionarse con la regla generica (mig 148/149).
    if (origenes && origenes.length > 0) {
      const { error: errorOrigen } = await supabase.rpc('registrar_origen_precio_items', {
        p_pedido_id: pedidoEditando.id,
        p_origenes: origenes,
      })
      // No se propaga: los items ya se guardaron bien y el total es correcto.
      if (errorOrigen) console.warn('No se pudo registrar el origen del precio:', errorOrigen)
    }
    // Invalidar cache de pedidos para refrescar datos. Tambien la familia
    // recorridos* para que la hoja de ruta y las comandas (que se descargan
    // desde la ruta armada via useRecorridosHojaRutaQuery) reflejen el precio
    // editado y no sirvan paradas cacheadas con el valor viejo.
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    queryClient.invalidateQueries({ queryKey: ['recorridos'] })
    queryClient.invalidateQueries({ queryKey: ['recorridos-hoja-ruta'] })
    queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
    queryClient.invalidateQueries({ queryKey: ['recorrido-existente'] })
  }, [pedidoEditando, user, queryClient])

  // Reasignar el preventista del pedido en edicion. Solo admin (la UI ya
  // pasa el flag canEditPreventista={isAdmin}). El RPC tambien valida.
  const handleCambiarPreventistaPedido = useCallback(async (nuevoPreventistaId: string) => {
    if (!pedidoEditando) return
    try {
      const { data, error } = await supabase.rpc('actualizar_preventista_pedido', {
        p_pedido_id: pedidoEditando.id,
        p_nuevo_preventista_id: nuevoPreventistaId,
      })
      if (error) throw error
      const response = data as { success: boolean; error?: string }
      if (!response?.success) {
        throw new Error(response?.error || 'Error al cambiar preventista')
      }
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      // Actualizar localmente el pedido en edicion para reflejar el cambio
      // sin esperar al refetch.
      setPedidoEditando(prev => prev ? { ...prev, usuario_id: nuevoPreventistaId } as PedidoDB : prev)
      notify.success('Preventista actualizado')
    } catch (e) {
      notify.error((e as Error).message || 'Error al cambiar preventista')
      throw e
    }
  }, [pedidoEditando, queryClient, notify])

  // Cambiar el cliente de un pedido cargado al cliente equivocado: cancela el
  // viejo y crea uno nuevo idéntico (precios recalculados en el modal) para el
  // cliente correcto, transfiriendo los pagos. Atómico (RPC). Solo admin.
  const handleCambiarClientePedido = useCallback(async (payload: CambiarClientePayload) => {
    if (!pedidoEditando) return
    try {
      const { nuevoPedidoId } = await cambiarClientePedidoMut.mutateAsync({
        pedidoId: String(pedidoEditando.id),
        nuevoClienteId: payload.nuevoClienteId,
        usuarioId: user?.id ?? null,
        items: payload.items,
        total: payload.total,
        totalNeto: payload.totalNeto,
        totalIva: payload.totalIva,
        motivo: payload.motivo,
      })
      setModalEditarOpen(false)
      setPedidoEditando(null)
      notify.success(`Cliente cambiado: se creó el pedido #${nuevoPedidoId} y se canceló el anterior`, { persist: true })
    } catch (e) {
      notify.error((e as Error).message || 'Error al cambiar el cliente del pedido')
      throw e
    }
  }, [pedidoEditando, cambiarClientePedidoMut, user, notify])

  // ===========================================================================
  // ModalPagoPedido handlers (registrar/anular pagos sobre un pedido)
  // ===========================================================================

  const handleAbrirRegistrarPago = useCallback(async (pedido: PedidoDB) => {
    setPedidoPago(pedido)
    setPagosPreviosPedido([])
    setModalPagoPedidoOpen(true)
    await refreshPagosPedido(String(pedido.id))
  }, [refreshPagosPedido])

  // El error ya fue notificado por usePagos.registrarPagosBatch via notifyError;
  // dejamos que se propague para que el modal lo muestre tambien.
  const handleConfirmarPago = useCallback(async (payload: { pedidoId: string; clienteId: string; fechaPago: string; observaciones?: string; pagos: Array<{ formaPago: string; monto: number }>; clientRequestIds?: string[] }) => {
    setGuardando(true)
    try {
      await registrarPagosBatch({
        clienteId: payload.clienteId,
        pedidoId: payload.pedidoId,
        fecha: payload.fechaPago,
        observaciones: payload.observaciones || null,
        pagos: payload.pagos,
        usuarioId: user?.id ?? null,
        clientRequestIds: payload.clientRequestIds,
      })
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      setModalPagoPedidoOpen(false)
      setPedidoPago(null)
      notify.success('Pago registrado')
    } finally {
      setGuardando(false)
    }
  }, [registrarPagosBatch, user, queryClient, notify])

  // Modo entrega transportista: "Entregar sin pago" → solo cambia estado.
  const handleEntregarSinPago = useCallback(async () => {
    const pedido = pedidoEntregaConPago
    if (!pedido) return
    setGuardando(true)
    try {
      await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'entregado' })
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      setModalPagoPedidoOpen(false)
      setPedidoPago(null)
      setPedidoEntregaConPago(null)
      notify.success('Pedido entregado sin pago registrado')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoEntregaConPago, cambiarEstado, queryClient, notify])

  // Flujo transportista: "Entregar a cuenta corriente (sin cobrar)" desde el
  // modal de cobranza. Marca entregado sin registrar pago (el saldo queda
  // pendiente = deuda del cliente). Repropaga el error para que el modal del
  // transportista quede abierto y permita reintentar (importante sin red).
  const handleEntregarSinCobrar = useCallback(async (pedido: PedidoDB) => {
    // El botón que dispara esto cierra las dos situaciones (ver ModalPagoPedido):
    // entregar fiado, o confirmar la entrega de un pedido que ya quedó cobrado.
    // Solo cambia el aviso: decirle "a cuenta corriente" sobre un pedido saldado
    // hace dudar al chofer de si cobró bien.
    const saldado = (pedido.monto_pagado || 0) >= (pedido.total || 0) - 0.01
    try {
      await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'entregado' })
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      notify.success(saldado ? 'Pedido entregado' : 'Entregado a cuenta corriente (sin cobrar)')
    } catch (e) {
      notify.error((e as Error).message)
      throw e
    }
  }, [cambiarEstado, queryClient, notify])

  // Modo entrega transportista: "Entregar y registrar pago" → cambia estado y registra pagos.
  // Orden: primero entrega (mas critica), luego pagos. Si falla algun pago, queda
  // entregado y el usuario puede usar "Registrar Pago" desde el dropdown.
  const handleEntregarConPago = useCallback(async (payload: { pedidoId: string; clienteId: string; fechaPago: string; observaciones?: string; pagos: Array<{ formaPago: string; monto: number }>; clientRequestIds?: string[] }) => {
    const pedido = pedidoEntregaConPago
    if (!pedido) {
      // Fallback: comportamiento normal de registrar pago sin entrega
      await handleConfirmarPago(payload)
      return
    }
    setGuardando(true)
    try {
      // La entrega pertenece al día que el usuario eligió para el cobro, no a hoy.
      await cambiarEstado.mutateAsync({
        pedidoId: pedido.id,
        nuevoEstado: 'entregado',
        fechaEntrega: payload.fechaPago,
      })
      try {
        await registrarPagosBatch({
          clienteId: payload.clienteId,
          pedidoId: payload.pedidoId,
          fecha: payload.fechaPago,
          observaciones: payload.observaciones || null,
          pagos: payload.pagos,
          usuarioId: user?.id ?? null,
          clientRequestIds: payload.clientRequestIds,
        })
      } catch (pagoErr) {
        notify.error('Pedido entregado pero falló el pago: ' + (pagoErr as Error).message + '. Registralo desde el menú de pago.')
        queryClient.invalidateQueries({ queryKey: ['pedidos'] })
        setModalPagoPedidoOpen(false)
        setPedidoPago(null)
        setPedidoEntregaConPago(null)
        return
      }
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      setModalPagoPedidoOpen(false)
      setPedidoPago(null)
      setPedidoEntregaConPago(null)
      notify.success('Pedido entregado y pago registrado')
    } catch (e) {
      notify.error((e as Error).message)
      throw e
    } finally {
      setGuardando(false)
    }
  }, [pedidoEntregaConPago, cambiarEstado, registrarPagosBatch, user, queryClient, notify, handleConfirmarPago])

  const handleAnularPagoPedido = useCallback(async (pagoId: string) => {
    if (!pedidoPago) return
    if (!isAdmin) return
    setGuardando(true)
    try {
      await eliminarPago(pagoId)
      await refreshPagosPedido(String(pedidoPago.id))
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      notify.success('Pago anulado')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoPago, isAdmin, eliminarPago, refreshPagosPedido, queryClient, notify])

  // Editar la forma de pago de un pago previo. Admin o encargado. El RPC
  // bloquea la edicion si la rendicion del dia del pago esta cerrada.
  const handleEditarFormaPagoPedido = useCallback(async (pagoId: string, nuevaForma: string) => {
    if (!pedidoPago) return
    if (!isAdmin && !isEncargado) return
    try {
      await actualizarFormaPagoDePago(pagoId, nuevaForma)
      await refreshPagosPedido(String(pedidoPago.id))
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      notify.success('Forma de pago actualizada')
    } catch (e) {
      notify.error((e as Error).message)
      throw e
    }
  }, [pedidoPago, isAdmin, isEncargado, actualizarFormaPagoDePago, refreshPagosPedido, queryClient, notify])

  // ModalPedido handlers
  // Estado para el modal de motivo cuando GPS != ok (timeout/unavailable/error).
  // Bloquea la creación del pedido hasta que el preventista escriba justificación
  // o cancele.
  const [motivoGpsPending, setMotivoGpsPending] = useState<{
    status: Exclude<GpsStatus, 'ok' | 'denied'>
  } | null>(null)
  // Guardamos el GpsResult capturado mientras esperamos que el preventista
  // escriba el motivo. Usamos ref para no re-renderizar cuando cambia.
  const gpsPendingRef = useRef<GpsResult | null>(null)

  // Helper: ejecuta la creación efectiva del pedido + check-in GPS.
  // Recibe el GPS ya capturado (admin: gps=null, preventista: GpsResult).
  const ejecutarCreacionPedido = useCallback(async (
    gps: GpsResult | null,
    motivoOmision?: string,
  ) => {
    try {
      // Use promo+wholesale-resolved items and total (includes bonificaciones)
      const tipoFactura = nuevoPedido.tipoFactura || 'ZZ'
      // Descuento del cliente: general + por categoría (la categoría prevalece).
      // Se aplica DESPUES de promociones/precio mayorista. Mismo helper que usa
      // ModalPedido, para que el total guardado == el total mostrado en vivo.
      // Items bonificacion / precioOverride / precio<=0 no se tocan.
      const clienteSel = clientes.find(c => String(c.id) === String(nuevoPedido.clienteId))
      const { items: itemsConDescuento, total: totalConDescuento } = aplicarDescuentoClienteItems(itemsFinales, productos, clienteSel)
      let totalNeto = 0
      let totalIva = 0
      const itemsParaCrear = itemsConDescuento.map(item => {
        const esBonif = !!item.esBonificacion
        if (esBonif) {
          return {
            productoId: String(item.productoId),
            cantidad: item.cantidad,
            precioUnitario: item.precioUnitario,
            esBonificacion: true as const,
            ...(item.promoId ? { promocionId: item.promoId } : {}),
            neto_unitario: 0, iva_unitario: 0, impuestos_internos_unitario: 0, porcentaje_iva: 0,
          }
        }
        const producto = productos.find(p => String(p.id) === String(item.productoId))
        const pctIva = producto?.porcentaje_iva ?? 21
        const pctImpInt = producto?.impuestos_internos ?? 0
        const desglose = calcularNetoVenta(item.precioUnitario, pctIva, pctImpInt, tipoFactura)
        totalNeto += desglose.neto * item.cantidad
        totalIva += desglose.iva * item.cantidad
        return {
          productoId: String(item.productoId),
          cantidad: item.cantidad,
          precioUnitario: item.precioUnitario,
          ...(item.promoId ? { promocionId: item.promoId } : {}),
          neto_unitario: desglose.neto,
          iva_unitario: desglose.iva,
          impuestos_internos_unitario: desglose.impuestosInternos,
          porcentaje_iva: pctIva,
        }
      })
      // Por qué se cobró cada precio (mig 148/149). Se arma ANTES de mandar,
      // con el mismo `itemsFinales` que produjo los precios: acá todavía se sabe
      // si el precio vino de una escala mayorista, de un descuento del cliente o
      // de un override manual. Después de guardar, ese contexto se pierde.
      const origenes = construirOrigenPrecioItems(
        itemsFinales.map(item => ({
          productoId: item.productoId,
          precioUnitario: item.precioUnitario,
          esBonificacion: item.esBonificacion,
          precioOverride: item.precioOverride,
        })),
        {
          preciosResueltos,
          descuentoClientePct: new Map(
            itemsFinales.map(item => {
              const prod = productos.find(p => String(p.id) === String(item.productoId))
              return [String(item.productoId), resolverDescuentoPctCliente(clienteSel, prod?.categoria)]
            }),
          ),
          descuentoPorCategoria: new Set(
            itemsFinales
              .filter(item => {
                const prod = productos.find(p => String(p.id) === String(item.productoId))
                return esDescuentoDeCategoria(clienteSel, prod?.categoria)
              })
              .map(item => String(item.productoId)),
          ),
        },
      )

      // Se acuña en el primer intento y sobrevive a los reintentos: es lo que
      // impide que un corte de señal después del COMMIT cree el pedido dos veces.
      altaIdRef.current ??= nuevoRequestId()

      // SIN RED: el pedido se encola en vez de perderse.
      //
      // Hasta acá la app tenía toda la maquinaria offline construida
      // —`offlineDb`, `useOfflineSync`, el panel "N pendientes" del
      // OfflineIndicator— y nada la alimentaba: el único `guardarPedidoOffline`
      // vivía en un handler que no se renderiza desde hace meses. El preventista
      // en una zona sin señal cargaba el pedido delante del cliente, tocaba
      // Confirmar y le salía "Error al crear pedido". El pedido se perdía entero.
      //
      // Se encola DESPUÉS de resolver precios, promos y desglose fiscal, para que
      // el pedido entre exactamente igual que uno online. La idempotencia del
      // replay NO usa `altaIdRef`: usa `op_<id de la operación en IndexedDB>`,
      // que es estable por entrada encolada, y pasa por
      // `crear_pedido_idempotente` (mig 071). Un reintento no duplica.
      if (!isOnline) {
        const resultado = await guardarPedidoOffline({
          clienteId: nuevoPedido.clienteId,
          items: itemsParaCrear.map(item => ({
            productoId: String(item.productoId),
            cantidad: item.cantidad,
            precioUnitario: item.precioUnitario,
            nombre: productos.find(p => String(p.id) === String(item.productoId))?.nombre,
            ...('esBonificacion' in item && item.esBonificacion ? { esBonificacion: true } : {}),
            ...(item.promocionId ? { promocionId: item.promocionId } : {}),
            neto_unitario: item.neto_unitario,
            iva_unitario: item.iva_unitario,
            impuestos_internos_unitario: item.impuestos_internos_unitario,
            porcentaje_iva: item.porcentaje_iva,
          })),
          total: totalConDescuento,
          usuarioId: user?.id ?? undefined,
          notas: nuevoPedido.notas,
          formaPago: nuevoPedido.formaPago,
          // Sin red NO se declara cobro. El replay no registra pagos, así que un
          // pedido encolado como 'pagado' entraría impago y el chofer se lo
          // cobraría de nuevo al cliente — el mismo bug que se arregló en el
          // camino online. `ModalPedido` ya fuerza 'pendiente' offline; esto es
          // la defensa en profundidad.
          estadoPago: 'pendiente',
          fecha: nuevoPedido.fecha,
          fechaEntregaProgramada: nuevoPedido.fechaEntregaProgramada,
          tipoFactura,
          totalNeto,
          totalIva,
          preventistaId: nuevoPedido.preventistaId ?? null,
          origenes,
        }, { productos, validarStock: true })

        if (!resultado.success) {
          // El motivo más común es stock: el hook reserva contra los pedidos
          // offline que ya están en la cola, así que dice exactamente qué falta.
          const detalle = resultado.itemsSinStock?.length
            ? resultado.itemsSinStock
                .map(i => `${i.nombre}: pediste ${i.solicitado}, quedan ${i.disponible}`)
                .join('\n')
            : resultado.error || 'No se pudo guardar el pedido sin conexión.'
          notify.error(`No se pudo guardar el pedido:\n${detalle}`)
          setGuardando(false)
          return
        }

        resetNuevoPedido()
        setModalPedidoOpen(false)
        notify.warning(
          'Sin conexión: el pedido quedó guardado en el teléfono y se va a sincronizar solo ' +
            'cuando vuelva la señal. El cobro se registra después.',
          { persist: true },
        )
        setGuardando(false)
        return
      }

      const pedidoCreado = await crearPedido.mutateAsync({
        offlineId: altaIdRef.current,
        clienteId: nuevoPedido.clienteId,
        items: itemsParaCrear,
        origenes,
        total: totalConDescuento,
        usuarioId: user?.id ?? null,
        notas: nuevoPedido.notas,
        formaPago: nuevoPedido.formaPago,
        estadoPago: nuevoPedido.estadoPago,
        montoPagado: nuevoPedido.montoPagado,
        fecha: nuevoPedido.fecha,
        tipoFactura,
        totalNeto,
        totalIva,
        fechaEntregaProgramada: nuevoPedido.fechaEntregaProgramada,
        preventistaId: nuevoPedido.preventistaId ?? null,
      })
      // Check-in GPS: ya tenemos el resultado capturado (sincrono para
      // preventistas, null para admin). Persistimos directo, sin esperar.
      if (gps && pedidoCreado?.id) {
        const pedidoId = pedidoCreado.id
        void registrarGpsPedido(pedidoId, gps, motivoOmision)
      }

      // El selector "Estado de Pago" del alta declaraba un cobro que NUNCA se
      // registraba: `montoPagado` llegaba hasta la capa de la query y ahí se
      // descartaba (`crear_pedido_completo` no tiene `p_monto_pagado`), así que
      // el trigger dejaba el pedido en 'pendiente' con monto_pagado 0. El
      // preventista cobraba $50.000 en el mostrador, veía "Pedido creado
      // correctamente", y al día siguiente el chofer llegaba con la boleta
      // marcada impaga y se lo cobraba de nuevo al cliente.
      //
      // El pago va DESPUÉS del alta a propósito: necesita el id del pedido, y su
      // fallo no puede invalidar un pedido que ya existe. Insertar en `pagos`
      // alcanza — `recalcular_monto_pagado_pedido` (mig 035) recalcula
      // monto_pagado y estado_pago en cascada.
      const montoDelAlta =
        nuevoPedido.estadoPago === 'pagado'
          ? totalConDescuento
          : nuevoPedido.estadoPago === 'parcial'
            ? Number(nuevoPedido.montoPagado) || 0
            : 0

      if (montoDelAlta > 0 && pedidoCreado?.id) {
        try {
          await registrarPago({
            clienteId: nuevoPedido.clienteId,
            pedidoId: String(pedidoCreado.id),
            monto: montoDelAlta,
            formaPago: nuevoPedido.formaPago,
            notas:
              nuevoPedido.estadoPago === 'parcial'
                ? 'Pago parcial al crear el pedido'
                : 'Pago al crear el pedido',
            fecha: nuevoPedido.fecha,
            usuarioId: user?.id ?? null,
            clientRequestId: requestIdAlta(
              `alta|${pedidoCreado.id}|${montoDelAlta}|${nuevoPedido.formaPago}`,
            ),
          })
        } catch (pagoErr) {
          // El pedido ya existe: el mensaje tiene que decir exactamente eso y
          // qué hacer, no un "error al crear pedido" que invita a recargarlo.
          notify.error(
            `El pedido #${pedidoCreado.id} se creó, pero no se pudo registrar el cobro de ` +
              `${formatPrecio(montoDelAlta)}: ${(pagoErr as Error).message}. ` +
              'Registralo desde la ficha del pedido.',
          )
        }
      }

      resetNuevoPedido()
      setModalPedidoOpen(false)
      notify.success('Pedido creado correctamente')
    } catch (e) {
      // "No se pudo determinar la sucursal activa" casi siempre es el token, no
      // la sucursal: se traduce y se renueva la sesión para que el reintento
      // funcione. Ver src/utils/sesionVencida.ts.
      const crudo = (e as Error).message
      const mensaje = await explicarErrorDeSesion(crudo)
      notify.error(mensaje === crudo ? 'Error al crear pedido: ' + crudo : mensaje)
    }
    setGuardando(false)
  }, [nuevoPedido, itemsFinales, preciosResueltos, crearPedido, user, resetNuevoPedido, notify, productos, clientes, registrarGpsPedido, registrarPago, requestIdAlta, isOnline, guardarPedidoOffline])

  // Handler que arranca el flujo: captura GPS si preventista, decide si bloquear,
  // pedir motivo, o crear directo.
  const handleGuardarPedido = useCallback(async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos')
      return
    }
    // Un "parcial" sin monto es un pedido que dice estar cobrado a medias y no
    // tiene ningún pago detrás. Se corta acá y no después de crearlo.
    if (nuevoPedido.estadoPago === 'parcial' && !(Number(nuevoPedido.montoPagado) > 0)) {
      notify.warning('Ingresá el monto del pago parcial')
      return
    }
    setGuardando(true)

    // Admin / encargado: sin GPS, flujo histórico.
    if (!isPreventista) {
      await ejecutarCreacionPedido(null)
      return
    }

    // Preventista: capturar GPS sincrónicamente antes de crear el pedido.
    // - 'ok' o 'denied' → crear pedido directo (denied queda registrado en
    //   gps_status para auditoría; el preventista llegó acá habiendo pasado
    //   el gate, no lo bloqueamos al confirmar).
    // - timeout/unavailable/error → ModalMotivoSinGps para justificar.
    const gps = await capturarGps()
    if (gps.status === 'ok' || gps.status === 'denied') {
      await ejecutarCreacionPedido(gps)
      return
    }
    // Guardamos el GpsResult y dejamos que el ModalMotivoSinGps maneje el
    // resto. El botón Confirmar del ModalPedido queda deshabilitado porque
    // guardando sigue en true hasta que se confirme o cancele el motivo.
    gpsPendingRef.current = gps
    setMotivoGpsPending({ status: gps.status })
  }, [nuevoPedido, isPreventista, capturarGps, ejecutarCreacionPedido, notify])

  const handleConfirmarMotivoGps = useCallback(async (motivo: string) => {
    const gps = gpsPendingRef.current
    setMotivoGpsPending(null)
    gpsPendingRef.current = null
    if (!gps) {
      setGuardando(false)
      return
    }
    await ejecutarCreacionPedido(gps, motivo)
  }, [ejecutarCreacionPedido])

  const handleCancelarMotivoGps = useCallback(() => {
    setMotivoGpsPending(null)
    gpsPendingRef.current = null
    setGuardando(false)
  }, [])

  // ModalFiltroFecha: onApply({ fechaDesde, fechaHasta })
  const handleFiltroFechaApply = useCallback((f: { fechaDesde: string | null; fechaHasta: string | null }) => {
    setFiltros(prev => ({ ...prev, fechaDesde: f.fechaDesde, fechaHasta: f.fechaHasta }))
    setPaginaActual(1)
    setModalFiltroFechaOpen(false)
  }, [])

  // ModalExportarPDF handlers (lazy PDF generation)
  const handleExportarOrdenPreparacion = useCallback(async (pedidosExport: PedidoDB[]) => {
    try {
      const { generarOrdenPreparacion } = await importConRecarga(() => import('../../lib/pdfExport'))
      generarOrdenPreparacion(pedidosExport)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  const handleExportarHojaRuta = useCallback(async (transportista: PerfilDB | undefined, pedidosExport: PedidoDB[]) => {
    if (!transportista) return
    try {
      const { generarHojaRutaOptimizada } = await importConRecarga(() => import('../../lib/pdfExport'))
      generarHojaRutaOptimizada(transportista, pedidosExport)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  const handleImprimirComandas = useCallback(async (pedidosExport: PedidoDB[]) => {
    try {
      const { generarComandasMultiples } = await importConRecarga(() => import('../../lib/pdfExport'))
      generarComandasMultiples(pedidosExport)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  // ModalGestionRutas handlers
  // Aplica el orden optimizado y persiste el recorrido del día (RPC
  // aplicar_orden_ruta, mig 081): actualiza pedidos.orden_entrega, cancela el
  // recorrido en_curso anterior del transportista y crea el nuevo con
  // distancia/duración. Un recorrido vigente por transportista por día.
  // Las polylines se pasan por argumento (no se leen de rutaOptimizada del
  // closure) para evitar usar un valor viejo cuando se encadena optimizar→aplicar.
  const aplicarOrden = useCallback(async (data: { ordenOptimizado: Array<{ pedido_id: string; orden: number }>; transportistaId: string; distancia: number | null; duracion: number | null; polylines: string[] | null; fecha: string }): Promise<boolean> => {
    setGuardando(true)
    let ok = false
    try {
      const { error } = await supabase.rpc('aplicar_orden_ruta', {
        p_transportista_id: data.transportistaId,
        p_pedidos: data.ordenOptimizado.map(p => ({ pedido_id: p.pedido_id, orden_entrega: p.orden })),
        p_distancia: data.distancia,
        p_duracion: data.duracion != null ? Math.round(data.duracion) : null,
        // Ruta real sobre las calles (encoded polylines de Google) para
        // dibujarla en el mapa del transportista y del admin.
        p_polylines: data.polylines ?? null,
        // Fecha de entrega elegida por el admin (default mañana en la UI).
        p_fecha: data.fecha
      })
      if (error) throw error

      // Refresca lista paginada + pool rutable (prefijo 'pedidos'), recorridos,
      // la ruta del transportista, la ruta existente (para re-editar) y el
      // resumen para re-descargar la hoja de ruta.
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      queryClient.invalidateQueries({ queryKey: ['recorridos'] })
      queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
      queryClient.invalidateQueries({ queryKey: ['recorrido-existente'] })
      queryClient.invalidateQueries({ queryKey: ['recorridos-hoja-ruta'] })
      // No cerramos el modal: queda en la vista de resultado (confirmación +
      // export PDF). El admin cierra con "Cerrar" (que limpia la ruta).
      notify.success('Ruta del día armada y guardada')
      ok = true
    } catch (e) { notify.error('Error al guardar la ruta: ' + (e as Error).message) }
    setGuardando(false)
    return ok
  }, [notify, queryClient])

  const handleAplicarOrden = useCallback(async (data: { ordenOptimizado: Array<{ pedido_id: string; orden: number }>; transportistaId: string; distancia: number | null; duracion: number | null; polylines: string[] | null; fecha: string }): Promise<boolean> => {
    if (!data.ordenOptimizado?.length || !data.transportistaId) return false
    // Sin confirm de reemplazo: si ya hay una ruta para ese transportista+fecha,
    // el modal la cargó pre-tildada y el RPC (mig 088) la edita in-place (no
    // duplica). Armar = guardar las modificaciones sobre esa misma ruta.
    return await aplicarOrden(data)
  }, [aplicarOrden])

  // Armar ruta del día: optimiza los pedidos seleccionados y los guarda en un
  // solo paso (sin botón "optimizar" separado). Las polylines del resultado se
  // pasan explícitamente a aplicar (no se leen del estado, que aún no se
  // actualizó en este tick).
  const handleArmarRutaDelDia = useCallback(async (transportistaId: string, pedidosSeleccionados: PedidoDB[], fecha: string, horaInicio: string, horaFin: string) => {
    if (!transportistaId || pedidosSeleccionados.length === 0) return
    const ruta = await optimizarRutaConDeposito(transportistaId, pedidosSeleccionados, fecha, horaInicio, horaFin)
    // ruta es null solo si la optimización falló de verdad (error de red/servicio):
    // optimizarRuta ya mostró el mensaje y no armamos nada.
    if (!ruta) return

    type ParadaPlan = { pedido_id: string; barrida?: Barrida; hora_estimada?: string }
    const optimizados = (ruta.orden_optimizado ?? []) as Array<ParadaPlan & { orden: number }>
    // Los pedidos sin coordenadas NO los devuelve el optimizador (Google necesita
    // el punto), pero igual son entregables y deben formar parte de la ruta. Van
    // al final de SU barrida, no al final de la ruta: sin coordenadas no se sabe
    // por dónde queda la parada, pero sí a qué hora abre y cierra el cliente.
    const idsOptimizados = new Set(optimizados.map(o => String(o.pedido_id)))
    const sinCoordenadas = pedidosSeleccionados
      .filter(p => !idsOptimizados.has(String(p.id)))
      .map((p): ParadaPlan & { barrida: Barrida } => ({
        pedido_id: p.id,
        barrida: clasificarBarrida(horarioParaRutear(p.cliente)).barrida,
        // Sin coordenadas el optimizador no las planifica: no hay hora estimada.
        hora_estimada: undefined,
      }))

    const ordenFinal = intercalarSinCoordenadas(optimizados, sinCoordenadas)
    if (ordenFinal.length === 0) return

    const armado = await handleAplicarOrden({
      ordenOptimizado: ordenFinal,
      transportistaId,
      distancia: ruta.distancia_total ?? null,
      duracion: ruta.duracion_total ?? null,
      polylines: ruta.polylines ?? null,
      fecha,
    })

    // Marcar la barrida de cada parada. Va aparte de aplicar_orden_ruta a
    // propósito (ver mig 142): es un dato informativo y de medición, así que si
    // falla no se rompe la ruta ya armada — solo se pierden las etiquetas.
    // Incluye las paradas sin coordenadas: la hoja de ruta separa por barrida y
    // sin este dato la despensa que cierra a las 14 salía sin etiqueta de bloque.
    const conBarrida = ordenFinal
      .filter(o => o.barrida != null)
      .map(o => ({ pedido_id: o.pedido_id, barrida: o.barrida }))
    if (conBarrida.length > 0) {
      const { error: errBarridas } = await supabase.rpc('actualizar_barridas_recorrido', {
        p_items: conBarrida,
      })
      if (errBarridas) console.error('[rutas] no se pudieron marcar las barridas:', errBarridas)
    }

    // Reflejar en el resultado la ruta REALMENTE armada (optimizadas + sin
    // coordenadas). El optimizador no devuelve las paradas sin coordenadas, así
    // que sin esto el modal no cambiaba a la vista de resultado (ni mostraba los
    // botones de hoja de ruta / comandas) cuando la ruta tenía pocas o ninguna
    // parada geolocalizada.
    if (armado) {
      setRutaOptimizada(prev => ({
        ...(prev ?? {}),
        success: true,
        total_pedidos: ordenFinal.length,
        orden_optimizado: ordenFinal.map(o => ({
          pedido_id: o.pedido_id,
          orden: o.orden,
          // El horario que planificó el optimizador: el modal lo contrasta contra
          // el del cliente para avisar qué paradas caen fuera de hora.
          hora_estimada: o.hora_estimada,
        })),
      }))
    }
  }, [optimizarRutaConDeposito, handleAplicarOrden, setRutaOptimizada])

  // Split multi-repartidor: optimiza dividiendo los pedidos entre N choferes y
  // persiste un recorrido por chofer (aplicar_orden_ruta una vez por cada uno).
  // Los pedidos sin coordenadas (que el optimizador no rutea) se reparten por
  // zona preferida o round-robin antes de persistir.
  const handleArmarRutaMulti = useCallback(async (repartidores: RepartidorParam[], pedidosSeleccionados: PedidoDB[], fecha: string, horaInicio: string, horaFin: string) => {
    if (!repartidores.length || pedidosSeleccionados.length === 0) return
    const resp = await optimizarRutaMultiConDeposito(repartidores, pedidosSeleccionados, fecha, horaInicio, horaFin)
    if (!resp) return // error ya notificado por el hook

    const byId = new Map(pedidosSeleccionados.map(p => [String(p.id), p]))

    // Orden por repartidor desde el resultado del optimizador (geocodificados).
    const ruteadasPorRep = new Map<string, Array<{ pedido_id: string; barrida?: Barrida }>>()
    for (const rep of repartidores) ruteadasPorRep.set(rep.transportista_id, [])
    for (const r of resp.recorridos) {
      ruteadasPorRep.set(
        r.transportista_id,
        (r.orden_optimizado ?? [])
          .slice()
          .sort((a, b) => a.orden - b.orden)
          .map(o => ({ pedido_id: String(o.pedido_id), barrida: o.barrida })),
      )
    }

    // Pedidos que el optimizador NO ruteó → repartir por zona preferida (si el
    // cliente tiene zona) o round-robin. Se intercalan en el bloque horario que
    // les toca, no al final del recorrido del chofer.
    //
    // Se derivan de lo que volvió, no del campo `pedidos_sin_coordenadas_ids`.
    // Con `resp.x ?? fallback` el fallback NUNCA disparaba: la edge devuelve un
    // array VACÍO, no null, y `??` sólo cae ante null/undefined. En Taco Pozo
    // —129 de 134 clientes sin coordenadas— eso significaba armar dos rutas de
    // una parada y perder las otras 38 sin ningún aviso.
    //
    // Además esto cubre cualquier otro motivo por el que el optimizador deje un
    // pedido afuera, no sólo la falta de coordenadas: la invariante es que todo
    // pedido seleccionado termine en la ruta de alguien.
    const ruteadosIds = new Set<string>()
    for (const lista of ruteadasPorRep.values()) {
      for (const o of lista) ruteadosIds.add(String(o.pedido_id))
    }
    const sinCoordsIds = pedidosSeleccionados
      .map(p => String(p.id))
      .filter(id => !ruteadosIds.has(id))
    const sinCoordsPorRep = new Map<string, Array<{ pedido_id: string; barrida: Barrida }>>()
    for (const rep of repartidores) sinCoordsPorRep.set(rep.transportista_id, [])
    let rr = 0
    for (const pid of sinCoordsIds) {
      const pedido = byId.get(String(pid))
      const zonaId = pedido?.cliente?.zona_id != null ? Number(pedido.cliente.zona_id) : null
      let target = zonaId != null
        ? repartidores.find(r => Array.isArray(r.zonas_preferidas) && r.zonas_preferidas.includes(zonaId))?.transportista_id
        : undefined
      if (!target) { target = repartidores[rr % repartidores.length].transportista_id; rr++ }
      sinCoordsPorRep.get(target)!.push({
        pedido_id: String(pid),
        barrida: clasificarBarrida(horarioParaRutear(pedido?.cliente)).barrida,
      })
    }

    const ordenPorRep = new Map<string, Array<{ pedido_id: string; orden: number; barrida: Barrida | null }>>()
    for (const rep of repartidores) {
      ordenPorRep.set(
        rep.transportista_id,
        intercalarSinCoordenadas(
          ruteadasPorRep.get(rep.transportista_id) ?? [],
          sinCoordsPorRep.get(rep.transportista_id) ?? [],
        ),
      )
    }

    // Métricas (distancia/duración/polylines) por chofer desde el optimizador.
    const metricsByRep = new Map(resp.recorridos.map(r => [r.transportista_id, r]))

    // Que no sea silencioso: el encargado tiene que saber que esas paradas
    // entraron sin orden geográfico y por qué, para poder acomodarlas a mano.
    if (sinCoordsIds.length > 0) {
      notify.warning(
        `${sinCoordsIds.length} ${sinCoordsIds.length === 1 ? 'pedido se repartió' : 'pedidos se repartieron'} ` +
          'sin optimizar por falta de coordenadas del cliente. Revisá su lugar en la ruta.',
      )
    }

    setGuardando(true)
    const recorridosUI: RutaMultiResultadoUI['recorridos'] = []
    try {
      for (const rep of repartidores) {
        const lista = ordenPorRep.get(rep.transportista_id) ?? []
        if (lista.length === 0) continue
        const m = metricsByRep.get(rep.transportista_id)
        const { error } = await supabase.rpc('aplicar_orden_ruta', {
          p_transportista_id: rep.transportista_id,
          p_pedidos: lista.map(o => ({ pedido_id: o.pedido_id, orden_entrega: o.orden })),
          p_distancia: m?.distancia_total ?? null,
          p_duracion: m?.duracion_total != null ? Math.round(m.duracion_total) : null,
          p_polylines: m?.polylines ?? null,
          p_fecha: fecha,
        })
        if (error) throw error
        recorridosUI.push({
          transportista_id: rep.transportista_id,
          transportista_nombre: transportistas.find(t => t.id === rep.transportista_id)?.nombre || 'Transportista',
          total_pedidos: lista.length,
          distancia_formato: m?.distancia_formato,
          duracion_formato: m?.duracion_formato,
          pedido_ids: lista.slice().sort((a, b) => a.orden - b.orden).map(o => o.pedido_id),
        })
      }

      // Barridas de todos los choferes en una sola llamada. Igual que en el modo
      // de un chofer: informativo, si falla no se rompe la ruta ya guardada.
      const conBarrida = [...ordenPorRep.values()]
        .flat()
        .filter(o => o.barrida != null)
        .map(o => ({ pedido_id: o.pedido_id, barrida: o.barrida }))
      if (conBarrida.length > 0) {
        const { error: errBarridas } = await supabase.rpc('actualizar_barridas_recorrido', {
          p_items: conBarrida,
        })
        if (errBarridas) console.error('[rutas] no se pudieron marcar las barridas:', errBarridas)
      }

      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      queryClient.invalidateQueries({ queryKey: ['recorridos'] })
      queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
      queryClient.invalidateQueries({ queryKey: ['recorrido-existente'] })
      queryClient.invalidateQueries({ queryKey: ['recorridos-hoja-ruta'] })

      setRutaMultiResultado({ recorridos: recorridosUI, skipped: resp.skipped ?? [] })
      const noAsignados = (resp.skipped ?? []).length
      notify.success(
        `Ruta dividida en ${recorridosUI.length} recorrido(s)` +
        (noAsignados > 0 ? ` · ${noAsignados} pedido(s) sin asignar (capacidad)` : ''),
      )
    } catch (e) {
      notify.error('Error al guardar las rutas: ' + (e as Error).message)
    }
    setGuardando(false)
  }, [optimizarRutaMultiConDeposito, transportistas, notify, queryClient])

  // Crea una parada de cambio/devolución (pedido especial canal='cambio'). La
  // usa tanto el modal de armar ruta (que además la suma a la selección con el
  // pedido_id que devuelve) como la pantalla de Pedidos. Devuelve el pedido_id.
  const handleCrearCambioEnRuta = useCallback(async (data: RegistrarCambioInput): Promise<string | null> => {
    try {
      const pedidoId = await crearCambioEnRutaMut.mutateAsync(data)
      notify.success('Cambio/devolución agregado como parada')
      return pedidoId != null ? String(pedidoId) : null
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo crear la parada de cambio')
      return null
    }
  }, [crearCambioEnRutaMut, notify])

  const handleExportarHojaRutaOptimizada = useCallback(async (transportista: PerfilDB | undefined, pedidosOrdenados: PedidoDB[]) => {
    try {
      const { generarHojaRutaOptimizada } = await importConRecarga(() => import('../../lib/pdfExport'))
      if (transportista) generarHojaRutaOptimizada(transportista, pedidosOrdenados)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  // ModalEntregaConSalvedad handlers
  // Idempotente via client_request_id (mig 049): el RPC hace short-circuit si ya
  // creo la salvedad con ese UUID.
  //
  // El UUID lo trae el caller (`salvedad.clientRequestId`), y eso es lo que hace
  // que sirva: antes se acuñaba uno nuevo ACA, dentro del loop, en cada
  // invocacion. Asi solo cubria el retry interno de retryWithBackoff —que
  // ademas nunca disparaba, ver retryWithBackoff.ts— y no el reintento del
  // usuario: si el lote fallaba a la mitad y volvia a tocar "Confirmar", las
  // salvedades que si habian entrado se aplicaban de nuevo, el total bajaba dos
  // veces y el stock volvia dos veces.
  const handleSaveSalvedades = useCallback(async (salvedades: RegistrarSalvedadInput[]): Promise<RegistrarSalvedadResult[]> => {
    const results: RegistrarSalvedadResult[] = []
    for (const salvedad of salvedades) {
      const clientRequestId = salvedad.clientRequestId || nuevoRequestId()
      try {
        const { data, error } = await retryWithBackoff(
          async () => {
            const response = await supabase.rpc('registrar_salvedad', {
              p_pedido_id: parseInt(String(salvedad.pedidoId), 10),
              p_pedido_item_id: parseInt(String(salvedad.pedidoItemId), 10),
              p_cantidad_afectada: salvedad.cantidadAfectada,
              p_motivo: salvedad.motivo,
              p_descripcion: salvedad.descripcion || null,
              p_foto_url: salvedad.fotoUrl || null,
              p_devolver_stock: salvedad.devolverStock !== false,
              p_client_request_id: clientRequestId,
            })
            // supabase-js puede devolver errores de red en `error` en lugar de
            // lanzarlos. Re-lanzamos como Error para que retryWithBackoff
            // pueda capturarlo y decidir reintentar.
            if (response.error && isTransientNetworkError(response.error)) {
              const e = new Error(response.error.message || 'Load failed')
              throw e
            }
            return response
          },
          { shouldRetry: isTransientNetworkError },
        )
        if (error) {
          results.push({ success: false, error: error.message })
        } else {
          const result = data as Record<string, unknown> | null
          results.push({
            success: !!result?.success,
            error: result?.success ? undefined : String(result?.error || 'Error desconocido'),
            codigo: result?.codigo ? String(result.codigo) : undefined,
          })
        }
      } catch (err) {
        const msg = err instanceof Error
          ? (isTransientNetworkError(err)
              ? 'Sin conexion estable. Volve a intentar cuando tengas senal.'
              : err.message)
          : 'Error desconocido'
        results.push({ success: false, error: msg })
      }
    }
    // Invalidar cache de productos y pedidos para reflejar cambios de stock y totales
    queryClient.invalidateQueries({ queryKey: ['productos'] })
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    return results
  }, [queryClient])

  // Handler single-salvedad para la vista transportista (wrapper sobre bulk)
  const handleRegistrarSalvedadSingle = useCallback(async (data: {
    pedidoId: string;
    pedidoItemId: string;
    cantidadAfectada: number;
    motivo: import('../../types').MotivoSalvedad;
    descripcion?: string;
    fotoUrl?: string;
    devolverStock: boolean;
  }): Promise<RegistrarSalvedadResult> => {
    const results = await handleSaveSalvedades([data])
    return results[0] ?? { success: false, error: 'Sin respuesta del servidor' }
  }, [handleSaveSalvedades])

  // Handler de registrar pago desde la vista transportista. Usa usePagos +
  // invalida cache de pedidos para refrescar monto_pagado / estado_pago.
  // OJO con `['recorrido-activo']`: la pantalla del chofer NO lee de
  // `['pedidos']`, lee de esa query (useRecorridoActivoQuery). Sin invalidarla,
  // el cobro entraba en la base pero la ruta seguía mostrando la parada como
  // impaga y el header con el total por cobrar viejo.
  const handleRegistrarPagoTransportista = useCallback(async (data: {
    clienteId: string;
    pedidoId: string | null;
    monto: number;
    formaPago: string;
    referencia: string;
    notas: string;
    fecha: string;
    clientRequestId?: string;
  }) => {
    const pago = await registrarPago({
      clienteId: data.clienteId,
      pedidoId: data.pedidoId,
      monto: data.monto,
      formaPago: data.formaPago,
      referencia: data.referencia,
      notas: data.notas,
      fecha: data.fecha,
      usuarioId: user?.id ?? null,
      clientRequestId: data.clientRequestId,
    })
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    // Se espera el refetch: al cerrarse el modal se marca entregado, y esa rama
    // depende de que la ruta ya esté al día.
    await queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
    return pago
  }, [registrarPago, queryClient, user?.id])

  const handleMarcarEntregadoConSalvedadConfirm = useCallback(async () => {
    if (!pedidoParaSalvedad) return
    try {
      await cambiarEstado.mutateAsync({ pedidoId: pedidoParaSalvedad.id, nuevoEstado: 'entregado' })
      setModalEntregaSalvedadOpen(false)
      setPedidoParaSalvedad(null)
      notify.success('Pedido entregado con salvedades registradas')
    } catch (e) { notify.error((e as Error).message) }
  }, [pedidoParaSalvedad, cambiarEstado, notify])

  // Confirm modal config object (matching ModalConfirmacion's config prop)
  const confirmModalConfig = confirmConfig.visible ? {
    visible: true,
    tipo: confirmConfig.tipo || ('warning' as const),
    titulo: confirmConfig.titulo || '',
    mensaje: confirmConfig.mensaje || '',
    onConfirm: confirmConfig.onConfirm || (() => {}),
  } : null

  return (
    <>
      {/* Los que volvieron sin entregar (mig 144). Van arriba de la lista
          porque vuelven a 'pendiente' y ahi se confunden con los nuevos. */}
      <div className="mb-3">
        <PanelPedidosNoEntregados />
      </div>

      {/* Los que quedaron trabados en 'asignado': no los ve el pool de "Armar
          ruta", asi que sin este panel no aparecen en ninguna pantalla. Dispara
          el MISMO handler que la fila del pedido — el boton ya existia, lo que
          faltaba era enterarse de que habia que usarlo. */}
      <div className="mb-3">
        <PanelPedidosTrabados
          enabled={isAdmin || isEncargado}
          onVolverAPendiente={p => handleVolverAPendiente(p as unknown as PedidoDB)}
        />
      </div>

      <Suspense fallback={<LoadingState />}>
        <VistaPedidos
          pedidos={pedidos}
          totalCount={totalCount}
          statsSummary={statsSummary}
          paginaActual={paginaActual}
          totalPaginas={totalPaginas}
          busqueda={busqueda}
          filtros={filtros}
          isAdmin={isAdmin}
          isPreventista={isPreventista}
          isTransportista={isTransportista}
          isEncargado={isEncargado}
          modoRuta={modoRuta}
          onVerMiRuta={puedeAlternarRuta ? verMiRuta : undefined}
          onSalirDeRuta={salirDeRuta}
          paradasPendientes={paradasPendientes}
          userId={user?.id ?? ''}
          clientes={clientes}
          productos={productos}
          transportistas={transportistas}
          usuarios={usuarios}
          loading={loadingPedidos}
          exportando={exportando}
          onBusquedaChange={handleBusquedaChange}
          onFiltrosChange={handleFiltrosChange}
          onPageChange={handlePageChange}
          onNuevoPedido={() => setModalPedidoOpen(true)}
          onOptimizarRuta={() => setModalOptimizarRutaOpen(true)}
          onCambioEnRuta={(isAdmin || isEncargado) ? () => setCambioEnRutaOpen(true) : undefined}
          onExportarPDF={() => setModalExportarPDFOpen(true)}
          onExportarExcel={handleExportarExcel}
          onModalFiltroFecha={() => setModalFiltroFechaOpen(true)}
          onVerHistorial={handleVerHistorial}
          onEditarPedido={handleEditarPedido}
          onEditarNotas={handleEditarNotas}
          onMarcarEnPreparacion={handleMarcarEnPreparacion}
          onVolverAPendiente={handleVolverAPendiente}
          onMarcarEntregado={handleMarcarEntregado}
          onMarcarEntregadoConSalvedad={handleMarcarEntregadoConSalvedad}
          onDesmarcarEntregado={handleDesmarcarEntregado}
          onCancelarPedido={handleCancelarPedido}
          onEntregasMasivas={() => setModalEntregasMasivasOpen(true)}
          onPagosMasivos={() => setModalPagosMasivosOpen(true)}
          onEntregaYPagoMasivos={() => setModalEntregaYPagoMasivosOpen(true)}
          onMarcarVisita={() => setModalMarcarVisitaOpen(true)}
          onVerVisitasHoy={() => setModalVisitasHoyOpen(true)}
          onRegistrarSalvedad={handleRegistrarSalvedadSingle}
          onRegistrarPago={handleRegistrarPagoTransportista}
          onAbrirPagoPedido={handleAbrirRegistrarPago}
          onEntregarSinCobrar={handleEntregarSinCobrar}
        />
      </Suspense>

      {/* Modal Confirmación */}
      {confirmConfig.visible && (
        <Suspense fallback={null}>
          <ModalConfirmacion
            config={confirmModalConfig}
            onClose={() => setConfirmConfig({ visible: false })}
          />
        </Suspense>
      )}

      {/* Modal Nuevo Pedido */}
      {modalPedidoOpen && (
        <Suspense fallback={null}>
          <ModalPedido
            productos={productos}
            clientes={clientes}
            categorias={[...new Set(productos.map(p => p.categoria).filter(Boolean))] as string[]}
            nuevoPedido={nuevoPedido}
            regalosOverride={regalosOverride}
            onCambiarRegaloCreacion={handleCambiarRegaloCreacion}
            promosEliminadas={promosEliminadas}
            onEliminarPromoCreacion={handleEliminarPromoCreacion}
            onRestaurarPromoCreacion={handleRestaurarPromoCreacion}
            onClose={() => { setModalPedidoOpen(false); resetNuevoPedido() }}
            onClienteChange={(id: string) => setNuevoPedido(prev => ({
              ...prev,
              clienteId: id,
              // Preseleccionar FC/ZZ según el default del cliente (mig 116); pisable por pedido.
              tipoFactura: ((clientes.find(c => String(c.id) === String(id)) as { tipo_factura_default?: 'ZZ' | 'FC' } | undefined)?.tipo_factura_default ?? 'ZZ'),
            }))}
            // `cantidad` la manda el modal con el mínimo de venta del producto
            // (mig 147). Antes este handler declaraba sólo `productoId` y
            // hardcodeaba 1 en las dos ramas: tocar un fardo de mínimo 3 lo
            // cargaba con 1, aparecía el cartel ámbar de violación de mínimo y
            // el confirmar quedaba en gris. El sistema conocía el mínimo y
            // obligaba a tipearlo a mano, con el cliente esperando.
            onAgregarItem={(productoId: string, cantidad = 1, precio?: number) => {
              setNuevoPedido(prev => {
                const existe = prev.items.find(i => i.productoId === productoId)
                const producto = productos.find(p => p.id === productoId)
                // El mínimo es un piso, no un múltiplo: sólo manda al agregar el
                // producto por primera vez. Si ya está en el carrito el piso ya
                // se cumplió y cada toque suma de a uno, como siempre.
                if (existe) {
                  return { ...prev, items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i) }
                }
                return { ...prev, items: [...prev.items, { productoId, cantidad, precioUnitario: precio ?? producto?.precio ?? 0 }] }
              })
            }}
            onActualizarCantidad={(productoId: string, cantidad: number) => {
              if (cantidad <= 0) {
                setNuevoPedido(prev => ({ ...prev, items: prev.items.filter(i => i.productoId !== productoId) }))
              } else {
                setNuevoPedido(prev => ({ ...prev, items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad } : i) }))
              }
            }}
            onActualizarPrecio={(productoId: string, precio: number) => {
              setNuevoPedido(prev => ({
                ...prev,
                items: prev.items.map(i =>
                  i.productoId === productoId
                    ? { ...i, precioUnitario: precio, precioOverride: true }
                    : i
                )
              }))
            }}
            onCrearCliente={async (clienteData: Record<string, unknown>) => {
              try {
                const dbData = {
                  razon_social: (clienteData.razonSocial as string) || (clienteData.nombreFantasia as string) || '',
                  nombre_fantasia: (clienteData.nombreFantasia as string) || (clienteData.nombre as string) || '',
                  direccion: (clienteData.direccion as string) || '',
                  telefono: (clienteData.telefono as string) || undefined,
                  zona: (clienteData.zona as string) || undefined,
                  latitud: (clienteData.latitud as number | null) ?? null,
                  longitud: (clienteData.longitud as number | null) ?? null,
                  horarios_atencion: (clienteData.horariosAtencion as string) || undefined,
                  dias_atencion: (clienteData.dias_atencion as string | null) ?? null,
                }
                const newCliente = await crearClienteMut.mutateAsync(dbData)
                notify.success(`Cliente "${newCliente.nombre_fantasia}" creado`)
                return { id: newCliente.id }
              } catch (e) {
                notify.error((e as Error).message || 'Error al crear cliente')
                throw e
              }
            }}
            onGuardarHorarioCliente={async (clienteId, patch) => {
              // Mutación aparte y previa a la creación del pedido: si falla, el
              // pedido armado no se pierde y el error se muestra en el bloque.
              try {
                await actualizarClienteMut.mutateAsync({ id: clienteId, data: patch })
              } catch (e) {
                const msg = (e as Error).message || 'No se pudo guardar el horario'
                notify.error(msg)
                throw e
              }
            }}
            onGuardar={handleGuardarPedido}
            guardando={guardando}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            isEncargado={isEncargado}
            onNotasChange={(notas: string) => setNuevoPedido(prev => ({ ...prev, notas }))}
            onFormaPagoChange={(fp: string) => setNuevoPedido(prev => ({ ...prev, formaPago: fp }))}
            onEstadoPagoChange={(ep: string) => setNuevoPedido(prev => ({
              ...prev,
              estadoPago: ep,
              // Al salir de "parcial" el monto tipeado deja de tener sentido:
              // si queda, se cobraría de más al confirmar.
              montoPagado: ep === 'parcial' ? prev.montoPagado : 0,
            }))}
            onMontoPagadoChange={(m: number) => setNuevoPedido(prev => ({ ...prev, montoPagado: m }))}
            onFechaChange={(fecha: string) => setNuevoPedido(prev => ({ ...prev, fecha }))}
            onTipoFacturaChange={(tipo: 'ZZ' | 'FC') => setNuevoPedido(prev => ({ ...prev, tipoFactura: tipo }))}
            onFechaEntregaProgramadaChange={(fecha: string) => setNuevoPedido(prev => ({ ...prev, fechaEntregaProgramada: fecha }))}
            onPreventistaChange={(preventistaId: string) => setNuevoPedido(prev => ({ ...prev, preventistaId }))}
            currentUserId={user?.id}
            isOffline={!isOnline}
          />
        </Suspense>
      )}


      {/* Modal Historial Pedido */}
      {modalHistorialOpen && pedidoHistorial && (
        <Suspense fallback={null}>
          <ModalHistorialPedido
            pedido={pedidoHistorial}
            historial={historialCambios as Parameters<typeof ModalHistorialPedido>[0]['historial']}
            loading={cargandoHistorial}
            transportistas={transportistas}
            onClose={() => { setModalHistorialOpen(false); setPedidoHistorial(null) }}
          />
        </Suspense>
      )}

      {/* Modal Editar Pedido */}
      {modalEditarOpen && pedidoEditando && (
        <Suspense fallback={null}>
          <ModalEditarPedido
            pedido={pedidoEditando}
            productos={productos}
            canEditItems={
              isAdmin || isEncargado ||
              (isPreventista && preventistaPuedeEditar(pedidoEditando, user?.id))
            }
            canEditPrices={isAdmin}
            canEditFechaEntrega={
              isAdmin || isEncargado ||
              (isPreventista && preventistaPuedeEditar(pedidoEditando, user?.id))
            }
            canSustituirRegalo={isAdmin || isEncargado}
            canEliminarPromo={isAdmin || isPreventista || isEncargado}
            canEditPreventista={isAdmin}
            canCambiarCliente={isAdmin}
            clientes={clientes}
            onSave={handleGuardarEdicion}
            onSaveItems={handleGuardarItemsEdicion}
            onCambiarPreventista={handleCambiarPreventistaPedido}
            onCambiarCliente={handleCambiarClientePedido}
            onClose={() => { setModalEditarOpen(false); setPedidoEditando(null) }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal Pago Pedido — registrar/anular pagos sobre un pedido.
          modoEntregaTransportista=true cuando el pedido fue abierto via Marcar Entregado
          (estado_pago != 'pagado'); habilita "Entregar sin pago" + "Entregar y registrar pago". */}
      {modalPagoPedidoOpen && pedidoPago && (
        <Suspense fallback={null}>
          <ModalPagoPedido
            pedido={pedidoPago}
            pagosPrevios={pagosPreviosPedido}
            loadingPagosPrevios={loadingPagosPrevios}
            onConfirmar={pedidoEntregaConPago ? handleEntregarConPago : handleConfirmarPago}
            onAnularPago={isAdmin && !pedidoEntregaConPago ? handleAnularPagoPedido : undefined}
            onEditarFormaPago={(isAdmin || isEncargado) && !pedidoEntregaConPago ? handleEditarFormaPagoPedido : undefined}
            soloAnulacion={pedidoPago.estado === 'cancelado'}
            modoEntregaTransportista={!!pedidoEntregaConPago}
            onEntregarSinPago={pedidoEntregaConPago ? handleEntregarSinPago : undefined}
            onClose={() => {
              setModalPagoPedidoOpen(false)
              setPedidoPago(null)
              setPedidoEntregaConPago(null)
              setPagosPreviosPedido([])
            }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal Editar Notas (preventista) */}
      {modalNotasOpen && pedidoNotasEditando && (
        <Suspense fallback={null}>
          <ModalEditarNotas
            pedido={pedidoNotasEditando}
            onSave={handleGuardarNotas}
            onClose={() => { setModalNotasOpen(false); setPedidoNotasEditando(null) }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal Filtro Fecha */}
      {modalFiltroFechaOpen && (
        <Suspense fallback={null}>
          <ModalFiltroFecha
            filtros={{ fechaDesde: filtros.fechaDesde, fechaHasta: filtros.fechaHasta }}
            onApply={handleFiltroFechaApply}
            onClose={() => setModalFiltroFechaOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Exportar PDF */}
      {modalExportarPDFOpen && (
        <Suspense fallback={null}>
          <ModalExportarPDF
            pedidos={pedidos}
            transportistas={transportistas}
            onExportarOrdenPreparacion={handleExportarOrdenPreparacion}
            onExportarHojaRuta={handleExportarHojaRuta}
            onImprimirComandas={handleImprimirComandas}
            fetchAllFilteredPedidos={fetchAllFilteredPedidos}
            onClose={() => setModalExportarPDFOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Optimizar Ruta */}
      {modalOptimizarRutaOpen && (
        <Suspense fallback={null}>
          <ModalGestionRutas
            transportistas={transportistas}
            pedidos={pedidosParaRuta}
            clientes={clientes}
            productos={productos}
            zonas={zonasRuta}
            onCrearCambio={handleCrearCambioEnRuta}
            onArmarRuta={handleArmarRutaDelDia as Parameters<typeof ModalGestionRutas>[0]['onArmarRuta']}
            onArmarRutaMulti={handleArmarRutaMulti as Parameters<typeof ModalGestionRutas>[0]['onArmarRutaMulti']}
            onExportarPDF={handleExportarHojaRutaOptimizada as Parameters<typeof ModalGestionRutas>[0]['onExportarPDF']}
            onImprimirComandas={handleImprimirComandas as Parameters<typeof ModalGestionRutas>[0]['onImprimirComandas']}
            onClose={() => { setModalOptimizarRutaOpen(false); limpiarRuta(); setRutaMultiResultado(null) }}
            loading={loadingOptimizacion || loadingPedidosRuta}
            guardando={guardando}
            rutaOptimizada={rutaOptimizada as Parameters<typeof ModalGestionRutas>[0]['rutaOptimizada']}
            rutaMulti={rutaMultiResultado}
            error={errorOptimizacion}
          />
        </Suspense>
      )}

      {/* Modal Cambio/Devolución como parada (desde la pantalla de Pedidos) */}
      {cambioEnRutaOpen && (
        <Suspense fallback={null}>
          <ModalCambioProducto
            clientes={clientes}
            productos={productos}
            modo="enRuta"
            onSave={async (data) => { await handleCrearCambioEnRuta(data as RegistrarCambioInput) }}
            onClose={() => setCambioEnRutaOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Entrega con Salvedad */}
      {modalEntregaSalvedadOpen && pedidoParaSalvedad && (
        <Suspense fallback={null}>
          <ModalEntregaConSalvedad
            pedido={pedidoParaSalvedad}
            onSave={handleSaveSalvedades as Parameters<typeof ModalEntregaConSalvedad>[0]['onSave']}
            onMarcarEntregado={handleMarcarEntregadoConSalvedadConfirm}
            onClose={() => { setModalEntregaSalvedadOpen(false); setPedidoParaSalvedad(null) }}
          />
        </Suspense>
      )}

      {/* Modal Entregas Masivas */}
      {modalEntregasMasivasOpen && (
        <Suspense fallback={null}>
          <ModalEntregasMasivas
            transportistas={transportistas}
            onConfirm={handleEntregasMasivas}
            onClose={() => setModalEntregasMasivasOpen(false)}
            guardando={guardando}
          />
        </Suspense>
      )}


      {/* Modal Cancelar Pedido */}
      {modalCancelarOpen && pedidoCancelando && (
        <Suspense fallback={null}>
          <ModalCancelarPedido
            pedido={pedidoCancelando}
            onConfirm={handleConfirmarCancelacion}
            onClose={() => { setModalCancelarOpen(false); setPedidoCancelando(null) }}
            guardando={guardando}
          />
        </Suspense>
      )}

      {/* Modal Pagos Masivos */}
      {modalPagosMasivosOpen && (
        <Suspense fallback={null}>
          <ModalPagosMasivos
            onConfirm={handlePagosMasivos}
            onClose={() => setModalPagosMasivosOpen(false)}
            guardando={guardando}
            isEncargado={isEncargado}
            isAdmin={isAdmin}
          />
        </Suspense>
      )}

      {/* Modal Entrega y Pago Masivos (combinado) */}
      {modalEntregaYPagoMasivosOpen && (
        <Suspense fallback={null}>
          <ModalEntregaYPagoMasivos
            transportistas={transportistas}
            onConfirm={handleEntregaYPagoMasivos}
            onClose={() => setModalEntregaYPagoMasivosOpen(false)}
            guardando={guardando}
            isEncargado={isEncargado}
            isAdmin={isAdmin}
          />
        </Suspense>
      )}

      {/* Modal Marcar Visita (preventista) */}
      {modalMarcarVisitaOpen && (
        <Suspense fallback={null}>
          <ModalMarcarVisita
            clientes={clientes}
            userId={user?.id ?? null}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            onClose={() => setModalMarcarVisitaOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal Visitas del día (preventista) */}
      {modalVisitasHoyOpen && (
        <Suspense fallback={null}>
          <ModalVisitasHoy
            userId={user?.id ?? null}
            onClose={() => setModalVisitasHoyOpen(false)}
          />
        </Suspense>
      )}

      {/* Modal de motivo cuando el GPS no es 'ok' al confirmar pedido (preventista) */}
      {motivoGpsPending && (
        <Suspense fallback={null}>
          <ModalMotivoSinGps
            status={motivoGpsPending.status}
            guardando={guardando}
            onConfirm={handleConfirmarMotivoGps}
            onCancel={handleCancelarMotivoGps}
          />
        </Suspense>
      )}
    </>
  )
}
