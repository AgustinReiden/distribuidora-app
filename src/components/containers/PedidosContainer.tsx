/**
 * PedidosContainer
 *
 * Container que carga pedidos bajo demanda usando TanStack Query.
 * Maneja filtros, paginación, búsqueda y operaciones sobre pedidos.
 */
import React, { lazy, Suspense, useState, useCallback, useMemo, useEffect } from 'react'
import { Loader2 } from 'lucide-react'
import { usePedidosQuery } from '../../hooks/queries/usePedidosQuery'
import { usePedidoActions } from '../../hooks/useHandlerActions'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useClientes } from '../../contexts/ClientesContext'
import { useProductos } from '../../contexts/ProductosContext'
import { useUsuariosContext } from '../../contexts/OperationsContext'
import { ITEMS_PER_PAGE } from '../../utils/formatters'
import type { PedidoDB, FiltrosPedidosState } from '../../types'

// Lazy load de la vista
const VistaPedidos = lazy(() => import('../vistas/VistaPedidos'))

// =============================================================================
// LOADING STATE
// =============================================================================

function LoadingState() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  )
}

// =============================================================================
// INITIAL FILTER STATE
// =============================================================================

const INITIAL_FILTROS: FiltrosPedidosState = {
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: '',
  busqueda: '',
  conSalvedad: 'todos',
  fechaDesde: null,
  fechaHasta: null,
}

// =============================================================================
// PROPS (para callbacks que aún viven en App.tsx)
// =============================================================================

export interface PedidosContainerProps {
  /** Abre el modal de crear nuevo pedido */
  onNuevoPedido?: () => void
  /** Abre el modal de optimizar ruta */
  onOptimizarRuta?: () => void
  /** Abre el modal de exportar PDF */
  onExportarPDF?: () => void
  /** Ejecuta export Excel directamente */
  onExportarExcel?: (pedidos: PedidoDB[], filtros: FiltrosPedidosState) => void
  /** Abre el modal de filtro por fecha */
  onModalFiltroFecha?: () => void
  /** Abre el modal de asignar transportista */
  onAsignarTransportista?: (pedido: PedidoDB) => void
  /** Abre el modal de entrega con salvedad */
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void
  /** Abre el modal de pedidos eliminados */
  onVerPedidosEliminados?: () => void
}

// =============================================================================
// CONTAINER
// =============================================================================

export default function PedidosContainer(props: PedidosContainerProps): React.ReactElement {
  const { isAdmin, isPreventista, isTransportista, user } = useAuthData()
  const notify = useNotification()
  const handlers = usePedidoActions()

  // Data from TanStack Query
  const { data: pedidos = [], isLoading } = usePedidosQuery()

  // Data from contexts
  const { clientes } = useClientes()
  const { productos } = useProductos()
  const { transportistas } = useUsuariosContext()

  // ---------------------------------------------------------------------------
  // Local state
  // ---------------------------------------------------------------------------

  const [busqueda, setBusqueda] = useState('')
  const [paginaActual, setPaginaActual] = useState(1)
  const [filtros, setFiltros] = useState<FiltrosPedidosState>(INITIAL_FILTROS)
  const [exportando, setExportando] = useState(false)
  const [pedidoAsignando, setPedidoAsignando] = useState<PedidoDB | null>(null)

  // ---------------------------------------------------------------------------
  // Derived state: filtering
  // ---------------------------------------------------------------------------

  const pedidosFiltrados = useMemo((): PedidoDB[] => {
    return pedidos.filter(p => {
      // Filter by estado
      if (filtros.estado !== 'todos' && p.estado !== filtros.estado) return false

      // Filter by estadoPago
      if (filtros.estadoPago && filtros.estadoPago !== 'todos') {
        const estadoPagoActual = p.estado_pago || 'pendiente'
        if (estadoPagoActual !== filtros.estadoPago) return false
      }

      // Filter by transportistaId
      if (filtros.transportistaId && filtros.transportistaId !== 'todos') {
        if (filtros.transportistaId === 'sin_asignar') {
          if (p.transportista_id) return false
        } else {
          if (p.transportista_id !== filtros.transportistaId) return false
        }
      }

      // Filter by conSalvedad
      if (filtros.conSalvedad && filtros.conSalvedad !== 'todos') {
        const tieneSalvedad = p.salvedades && p.salvedades.length > 0
        if (filtros.conSalvedad === 'con_salvedad' && !tieneSalvedad) return false
        if (filtros.conSalvedad === 'sin_salvedad' && tieneSalvedad) return false
      }

      // Filter by date range
      const fechaPedido = p.created_at ? p.created_at.split('T')[0] : null
      if (filtros.fechaDesde && fechaPedido && fechaPedido < filtros.fechaDesde) return false
      if (filtros.fechaHasta && fechaPedido && fechaPedido > filtros.fechaHasta) return false

      return true
    })
  }, [pedidos, filtros])

  // ---------------------------------------------------------------------------
  // Derived state: search
  // ---------------------------------------------------------------------------

  const pedidosParaMostrar = useMemo((): PedidoDB[] => {
    if (!busqueda) return pedidosFiltrados

    const termino = busqueda.toLowerCase()
    return pedidosFiltrados.filter(p =>
      (p.cliente?.nombre_fantasia?.toLowerCase().includes(termino)) ||
      (p.cliente?.direccion?.toLowerCase().includes(termino)) ||
      p.id.toString().includes(busqueda)
    )
  }, [pedidosFiltrados, busqueda])

  // ---------------------------------------------------------------------------
  // Derived state: pagination
  // ---------------------------------------------------------------------------

  const totalPaginas = Math.ceil(pedidosParaMostrar.length / ITEMS_PER_PAGE)

  const pedidosPaginados = useMemo((): PedidoDB[] => {
    const inicio = (paginaActual - 1) * ITEMS_PER_PAGE
    return pedidosParaMostrar.slice(inicio, inicio + ITEMS_PER_PAGE)
  }, [pedidosParaMostrar, paginaActual])

  // ---------------------------------------------------------------------------
  // Reset pagination when filters or search change
  // ---------------------------------------------------------------------------

  useEffect(() => {
    setPaginaActual(1)
  }, [filtros, busqueda])

  // ---------------------------------------------------------------------------
  // Handlers
  // ---------------------------------------------------------------------------

  const handleBusquedaChange = useCallback((valor: string) => {
    setBusqueda(valor)
  }, [])

  const handleFiltrosChange = useCallback((parcial: Partial<FiltrosPedidosState>) => {
    setFiltros(prev => ({ ...prev, ...parcial }))
  }, [])

  const handlePageChange = useCallback((page: number) => {
    setPaginaActual(page)
  }, [])

  const handleNuevoPedido = useCallback(() => {
    // This will be wired to open a modal or navigate
    // For now delegates to the handler context if available
    notify.info('Crear nuevo pedido')
  }, [notify])

  const handleOptimizarRuta = useCallback(() => {
    notify.info('Optimizar ruta')
  }, [notify])

  const handleExportarPDF = useCallback(() => {
    // No-op placeholder - PDF export requires complex modal wiring
    setExportando(true)
    setTimeout(() => setExportando(false), 100)
  }, [])

  const handleExportarExcel = useCallback(() => {
    // No-op placeholder - Excel export will be wired separately
    setExportando(true)
    setTimeout(() => setExportando(false), 100)
  }, [])

  const handleModalFiltroFecha = useCallback(() => {
    // Placeholder for fecha filter modal
    notify.info('Filtro por fecha')
  }, [notify])

  const handleAsignarTransportista = useCallback((pedido: PedidoDB) => {
    setPedidoAsignando(pedido)
    // The actual assignment modal will be opened here
    // For now, store the pedido for when the modal is wired
  }, [])

  const handleMarcarEntregadoConSalvedad = useCallback((pedido: PedidoDB) => {
    // Placeholder for salvedad modal
    notify.info(`Marcar con salvedad: pedido ${pedido.id}`)
  }, [notify])

  const handleVerPedidosEliminados = useCallback(() => {
    // Placeholder for deleted pedidos modal
    notify.info('Ver pedidos eliminados')
  }, [notify])

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------

  const userId = user?.id || ''

  return (
    <Suspense fallback={<LoadingState />}>
      <VistaPedidos
        pedidos={pedidos}
        pedidosParaMostrar={pedidosParaMostrar}
        pedidosPaginados={pedidosPaginados}
        paginaActual={paginaActual}
        totalPaginas={totalPaginas}
        busqueda={busqueda}
        filtros={filtros}
        isAdmin={isAdmin}
        isPreventista={isPreventista}
        isTransportista={isTransportista}
        userId={userId}
        clientes={clientes}
        productos={productos}
        transportistas={transportistas}
        loading={isLoading}
        exportando={exportando}
        useVirtualScrolling="auto"
        onBusquedaChange={handleBusquedaChange}
        onFiltrosChange={handleFiltrosChange}
        onPageChange={handlePageChange}
        onNuevoPedido={props.onNuevoPedido || handleNuevoPedido}
        onOptimizarRuta={props.onOptimizarRuta || handleOptimizarRuta}
        onExportarPDF={props.onExportarPDF || handleExportarPDF}
        onExportarExcel={props.onExportarExcel
          ? () => { setExportando(true); props.onExportarExcel!(pedidosParaMostrar, { ...filtros, busqueda }); setTimeout(() => setExportando(false), 500) }
          : handleExportarExcel}
        onModalFiltroFecha={props.onModalFiltroFecha || handleModalFiltroFecha}
        onVerHistorial={handlers.handleVerHistorial}
        onEditarPedido={handlers.handleEditarPedido}
        onMarcarEnPreparacion={handlers.handleMarcarEnPreparacion}
        onVolverAPendiente={handlers.handleVolverAPendiente}
        onAsignarTransportista={props.onAsignarTransportista || handleAsignarTransportista}
        onMarcarEntregado={handlers.handleMarcarEntregado}
        onMarcarEntregadoConSalvedad={props.onMarcarEntregadoConSalvedad || handleMarcarEntregadoConSalvedad}
        onDesmarcarEntregado={handlers.handleDesmarcarEntregado}
        onEliminarPedido={(pedido: PedidoDB) => handlers.handleEliminarPedido(pedido.id)}
        onVerPedidosEliminados={props.onVerPedidosEliminados || handleVerPedidosEliminados}
      />
    </Suspense>
  )
}
