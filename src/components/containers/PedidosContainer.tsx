/**
 * PedidosContainer
 *
 * Container que carga pedidos paginados server-side usando TanStack Query.
 * Maneja estado de paginación, filtros, búsqueda y modales.
 * Reemplaza el flujo legacy de App.tsx → VistaPedidos con prop drilling.
 */
import React, { lazy, Suspense, useState, useCallback, useMemo } from 'react'
import { calcularNetoVenta } from '../../utils/calculations'
import { fechaLocalISO, fechaHaceDias } from '../../utils/formatters'
import { preventistaPuedeEditar } from '../../utils/permisosPedido'
import { useQueryClient } from '@tanstack/react-query'
import { Loader2 } from 'lucide-react'
import {
  usePedidosPaginatedQuery,
  usePedidoStatsQuery,
  EMPTY_PEDIDO_STATS_SUMMARY,
  useCrearPedidoMutation,
  useCambiarEstadoMutation,
  useAsignarTransportistaMutation,
  useEntregasMasivasMutation,
  useCancelarPedidoMutation,
  usePagosMasivosMutation,
  useClientesQuery,
  useProductosQuery,
  useTransportistasQuery,
  useUsuariosQuery,
  useCrearClienteMutation,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useOptimizarRuta } from '../../hooks/useOptimizarRuta'
import { usePromocionPedido } from '../../hooks/usePromocionPedido'
import { useDebounce } from '../../hooks/useAsync'
import { useRegistrarGeolocalizacionPedido } from '../../hooks/useRegistrarGeolocalizacionPedido'
import { supabase } from '../../hooks/supabase/base'
import { usePagos } from '../../hooks/supabase/usePagos'
import type { PedidoDB, FiltrosPedidosState, PerfilDB, RegistrarSalvedadInput, RegistrarSalvedadResult, PagoDBWithUsuario } from '../../types'
import type { PedidoEditItem } from '../modals/ModalEditarPedido'

// Lazy load de componentes
const VistaPedidos = lazy(() => import('../vistas/VistaPedidos'))
const ModalPedido = lazy(() => import('../modals/ModalPedido'))
const ModalConfirmacion = lazy(() => import('../modals/ModalConfirmacion'))
const ModalAsignarTransportista = lazy(() => import('../modals/ModalAsignarTransportista'))
const ModalHistorialPedido = lazy(() => import('../modals/ModalHistorialPedido'))
const ModalEditarPedido = lazy(() => import('../modals/ModalEditarPedido'))
const ModalPagoPedido = lazy(() => import('../modals/ModalPagoPedido'))
const ModalEditarNotas = lazy(() => import('../modals/ModalEditarNotas'))
const ModalFiltroFecha = lazy(() => import('../modals/ModalFiltroFecha'))
const ModalExportarPDF = lazy(() => import('../modals/ModalExportarPDF'))
const ModalGestionRutas = lazy(() => import('../modals/ModalGestionRutas'))
const ModalEntregaConSalvedad = lazy(() => import('../modals/ModalEntregaConSalvedad'))
const ModalEntregasMasivas = lazy(() => import('../modals/ModalEntregasMasivas'))
const ModalCancelarPedido = lazy(() => import('../modals/ModalCancelarPedido'))
const ModalPagosMasivos = lazy(() => import('../modals/ModalPagosMasivos'))
const ModalAsignarTransportistaMasivo = lazy(() => import('../modals/ModalAsignarTransportistaMasivo'))
const ModalMarcarVisita = lazy(() => import('../modals/ModalMarcarVisita'))
const ModalVisitasHoy = lazy(() => import('../modals/ModalVisitasHoy'))

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
  onConfirm?: () => void
}

export default function PedidosContainer(): React.ReactElement {
  const queryClient = useQueryClient()
  const { user, isAdmin, isPreventista, isTransportista, isEncargado, isOnline, authReady } = useAuthData()
  const notify = useNotification()

  // Pagination state
  const [paginaActual, setPaginaActual] = useState(1)
  const [busqueda, setBusqueda] = useState('')
  const debouncedBusqueda = useDebounce(busqueda, 350)
  const [filtros, setFiltros] = useState<FiltrosPedidosState>(buildDefaultFiltros)

  // Queries - use debounced search to avoid firing on every keystroke
  const { registrarPago, registrarPagosBatch, fetchPagosPedido, eliminarPago } = usePagos()

  const { data: paginatedResult, isLoading: loadingPedidos } = usePedidosPaginatedQuery(
    paginaActual, ITEMS_PER_PAGE, filtros, debouncedBusqueda, authReady
  )
  const { data: statsSummary = EMPTY_PEDIDO_STATS_SUMMARY } = usePedidoStatsQuery(
    filtros, debouncedBusqueda, authReady
  )
  const { data: clientes = [] } = useClientesQuery()
  const { data: productos = [] } = useProductosQuery()
  const { data: transportistas = [] } = useTransportistasQuery()
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
  const entregasMasivas = useEntregasMasivasMutation()
  const cancelarPedidoMut = useCancelarPedidoMutation()
  const pagosMasivos = usePagosMasivosMutation()
  const crearClienteMut = useCrearClienteMutation()

  // Route optimization
  const { loading: loadingOptimizacion, rutaOptimizada, error: errorOptimizacion, optimizarRuta, limpiarRuta } = useOptimizarRuta()

  // Export
  const [exportando, setExportando] = useState(false)

  // Derived data
  const pedidos = useMemo(() => paginatedResult?.data ?? [], [paginatedResult?.data])
  const totalCount = paginatedResult?.totalCount ?? 0
  const totalPaginas = Math.ceil(totalCount / ITEMS_PER_PAGE)

  // Modal state
  const [modalPedidoOpen, setModalPedidoOpen] = useState(false)
  const [modalAsignarOpen, setModalAsignarOpen] = useState(false)
  const [modalHistorialOpen, setModalHistorialOpen] = useState(false)
  const [modalEditarOpen, setModalEditarOpen] = useState(false)
  const [modalFiltroFechaOpen, setModalFiltroFechaOpen] = useState(false)
  const [modalExportarPDFOpen, setModalExportarPDFOpen] = useState(false)
  const [modalOptimizarRutaOpen, setModalOptimizarRutaOpen] = useState(false)
  const [modalEntregaSalvedadOpen, setModalEntregaSalvedadOpen] = useState(false)
  const [modalEntregasMasivasOpen, setModalEntregasMasivasOpen] = useState(false)
  const [modalCancelarOpen, setModalCancelarOpen] = useState(false)
  const [modalPagosMasivosOpen, setModalPagosMasivosOpen] = useState(false)
  const [modalAsignarMasivoOpen, setModalAsignarMasivoOpen] = useState(false)
  const [modalNotasOpen, setModalNotasOpen] = useState(false)
  const [modalPagoPedidoOpen, setModalPagoPedidoOpen] = useState(false)
  const [modalMarcarVisitaOpen, setModalMarcarVisitaOpen] = useState(false)
  const [modalVisitasHoyOpen, setModalVisitasHoyOpen] = useState(false)
  const [pedidoPago, setPedidoPago] = useState<PedidoDB | null>(null)
  const [pagosPreviosPedido, setPagosPreviosPedido] = useState<PagoDBWithUsuario[]>([])
  const [loadingPagosPrevios, setLoadingPagosPrevios] = useState(false)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Pedido-specific state for modals
  const [pedidoAsignando, setPedidoAsignando] = useState<PedidoDB | null>(null)
  const [pedidoHistorial, setPedidoHistorial] = useState<PedidoDB | null>(null)
  const [historialCambios, setHistorialCambios] = useState<unknown[]>([])
  const [cargandoHistorial, setCargandoHistorial] = useState(false)
  const [pedidoEditando, setPedidoEditando] = useState<PedidoDB | null>(null)
  const [pedidoParaSalvedad, setPedidoParaSalvedad] = useState<PedidoDB | null>(null)
  const [pedidoCancelando, setPedidoCancelando] = useState<PedidoDB | null>(null)
  const [pedidoNotasEditando, setPedidoNotasEditando] = useState<PedidoDB | null>(null)
  const [guardando, setGuardando] = useState(false)

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
  })

  const resetNuevoPedido = useCallback(() => {
    setNuevoPedido({
      clienteId: '', items: [], notas: '',
      formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0,
      fecha: fechaLocalISO(),
      tipoFactura: 'ZZ' as 'ZZ' | 'FC',
      fechaEntregaProgramada: undefined,
    })
  }, [])

  // Resolve wholesale prices for current pedido items
  const { itemsFinales, totalFinal } = usePromocionPedido(nuevoPedido.items)

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

  // Estado: marcar entregado.
  // Si el pedido ya esta pagado completamente → confirm simple.
  // Si queda saldo pendiente → abrir ModalPagoPedido en modoEntregaTransportista
  // para que el usuario pueda registrar el cobro o entregar sin pago en el mismo gesto.
  const [pedidoEntregaConPago, setPedidoEntregaConPago] = useState<PedidoDB | null>(null)

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
    if (pedido.estado_pago === 'pagado') {
      setConfirmConfig({
        visible: true, titulo: 'Confirmar entrega',
        mensaje: `¿Confirmar entrega del pedido #${pedido.id}?`, tipo: 'success',
        onConfirm: async () => {
          try {
            await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'entregado' })
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
  }, [cambiarEstado, notify, refreshPagosPedido])

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
      mensaje: `¿Volver el pedido #${pedido.id} a estado "Pendiente"?`, tipo: 'warning',
      onConfirm: async () => {
        try {
          if (pedido.transportista_id) {
            await asignarTransportistaMut.mutateAsync({ pedidoId: pedido.id, transportistaId: null })
          }
          await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'pendiente' })
          notify.warning('Pedido vuelto a pendiente')
        } catch (e) { notify.error((e as Error).message) }
        setConfirmConfig({ visible: false })
      },
    })
  }, [cambiarEstado, asignarTransportistaMut, notify])

  const handleAsignarTransportista = useCallback((pedido: PedidoDB) => {
    setPedidoAsignando(pedido)
    setModalAsignarOpen(true)
  }, [])

  const handleVerHistorial = useCallback(async (pedido: PedidoDB) => {
    setPedidoHistorial(pedido)
    setModalHistorialOpen(true)
    setCargandoHistorial(true)
    try {
      const { data } = await supabase
        .from('pedido_historial').select('*')
        .eq('pedido_id', pedido.id)
        .order('created_at', { ascending: false })
      setHistorialCambios(data || [])
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
    setPedidoCancelando(pedido)
    setModalCancelarOpen(true)
  }, [])

  const handleConfirmarCancelacion = useCallback(async (motivo: string) => {
    if (!pedidoCancelando) return
    setGuardando(true)
    try {
      await cancelarPedidoMut.mutateAsync({ pedidoId: pedidoCancelando.id, motivo, usuarioId: user?.id })
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
      await pagosMasivos.mutateAsync({ pedidoIds, formaPago, fecha: fechaPago })
      setModalPagosMasivosOpen(false)
      notify.success(`${pedidoIds.length} pedido${pedidoIds.length !== 1 ? 's' : ''} marcado${pedidoIds.length !== 1 ? 's' : ''} como pagado${pedidoIds.length !== 1 ? 's' : ''}`)
    } catch (e) { notify.error('Error en pagos masivos: ' + (e as Error).message) }
    setGuardando(false)
  }, [pagosMasivos, notify])

  const handleAsignarTransportistaMasivo = useCallback(async (transportistaId: string, pedidoIds: string[], marcarListo: boolean) => {
    setGuardando(true)
    try {
      for (const pedidoId of pedidoIds) {
        await asignarTransportistaMut.mutateAsync({ pedidoId, transportistaId })
        if (marcarListo) {
          await cambiarEstado.mutateAsync({ pedidoId, nuevoEstado: 'asignado' })
        }
      }
      setModalAsignarMasivoOpen(false)
      notify.success(`${pedidoIds.length} pedido${pedidoIds.length !== 1 ? 's' : ''} asignado${pedidoIds.length !== 1 ? 's' : ''} al transportista`)
    } catch (e) { notify.error('Error al asignar transportista: ' + (e as Error).message) }
    setGuardando(false)
  }, [asignarTransportistaMut, cambiarEstado, notify])

  // Fetch todos los pedidos con filtros actuales (sin paginación) para export
  const fetchAllFilteredPedidos = useCallback(async (): Promise<PedidoDB[]> => {
    const hasSearch = debouncedBusqueda && debouncedBusqueda.trim().length > 0
    const selectStr = hasSearch
      ? '*, cliente:clientes!inner(*), items:pedido_items(*, producto:productos(*))'
      : '*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))'

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
        'Forma Pago': p.forma_pago || '',
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

  // ModalAsignarTransportista: onSave(transportistaId, marcarListo)
  const handleConfirmarAsignar = useCallback(async (transportistaId: string, marcarListo: boolean) => {
    if (!pedidoAsignando) return
    setGuardando(true)
    try {
      await asignarTransportistaMut.mutateAsync({ pedidoId: pedidoAsignando.id, transportistaId: transportistaId || null })
      if (marcarListo && transportistaId) {
        await cambiarEstado.mutateAsync({ pedidoId: pedidoAsignando.id, nuevoEstado: 'asignado' })
      }
      setModalAsignarOpen(false)
      setPedidoAsignando(null)
      notify.success(transportistaId ? 'Transportista asignado' : 'Transportista desasignado')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoAsignando, asignarTransportistaMut, cambiarEstado, notify])

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
      // Invalidar cache para que los cambios se reflejen en la UI
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
      setModalEditarOpen(false)
      setPedidoEditando(null)
      notify.success('Pedido actualizado')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoEditando, notify, queryClient])

  // ModalEditarPedido: onSaveItems - guardar cambios de items via RPC.
  // Reenvía el desglose fiscal para que el RPC actualice correctamente
  // total_neto/total_iva (sin esto, los COALESCE(..., precio) del RPC dejaban
  // todo el monto como "neto" ignorando el IVA en facturas FC).
  const handleGuardarItemsEdicion = useCallback(async (items: PedidoEditItem[]) => {
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
    // Invalidar cache de pedidos para refrescar datos
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
  }, [pedidoEditando, user, queryClient])

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
  const handleConfirmarPago = useCallback(async (payload: { pedidoId: string; clienteId: string; fechaPago: string; observaciones?: string; pagos: Array<{ formaPago: string; monto: number }> }) => {
    setGuardando(true)
    try {
      await registrarPagosBatch({
        clienteId: payload.clienteId,
        pedidoId: payload.pedidoId,
        fecha: payload.fechaPago,
        observaciones: payload.observaciones || null,
        pagos: payload.pagos,
        usuarioId: user?.id ?? null,
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

  // Modo entrega transportista: "Entregar y registrar pago" → cambia estado y registra pagos.
  // Orden: primero entrega (mas critica), luego pagos. Si falla algun pago, queda
  // entregado y el usuario puede usar "Registrar Pago" desde el dropdown.
  const handleEntregarConPago = useCallback(async (payload: { pedidoId: string; clienteId: string; fechaPago: string; observaciones?: string; pagos: Array<{ formaPago: string; monto: number }> }) => {
    const pedido = pedidoEntregaConPago
    if (!pedido) {
      // Fallback: comportamiento normal de registrar pago sin entrega
      await handleConfirmarPago(payload)
      return
    }
    setGuardando(true)
    try {
      await cambiarEstado.mutateAsync({ pedidoId: pedido.id, nuevoEstado: 'entregado' })
      try {
        await registrarPagosBatch({
          clienteId: payload.clienteId,
          pedidoId: payload.pedidoId,
          fecha: payload.fechaPago,
          observaciones: payload.observaciones || null,
          pagos: payload.pagos,
          usuarioId: user?.id ?? null,
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

  // ModalPedido handlers
  const handleGuardarPedido = useCallback(async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos')
      return
    }
    setGuardando(true)
    // Disparamos la captura de GPS en paralelo a la creación del pedido para
    // no agregar latencia al flujo. Sólo si el usuario es preventista (target
    // del feature). El RPC vuelve a validar la autorización en el backend.
    const gpsPromise = isPreventista ? capturarGps() : null
    try {
      // Use promo+wholesale-resolved items and total (includes bonificaciones)
      const tipoFactura = nuevoPedido.tipoFactura || 'ZZ'
      let totalNeto = 0
      let totalIva = 0
      const itemsParaCrear = itemsFinales.map(item => {
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
      const pedidoCreado = await crearPedido.mutateAsync({
        clienteId: nuevoPedido.clienteId,
        items: itemsParaCrear,
        total: totalFinal,
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
      })
      // Check-in GPS: fire-and-forget. La promesa de captura ya está corriendo
      // en paralelo desde el inicio del handler; cuando resuelva, mandamos el
      // resultado al RPC. No bloquea el toast de éxito.
      if (gpsPromise && pedidoCreado?.id) {
        const pedidoId = pedidoCreado.id
        gpsPromise.then(gps => { void registrarGpsPedido(pedidoId, gps) })
      }
      resetNuevoPedido()
      setModalPedidoOpen(false)
      notify.success('Pedido creado correctamente')
    } catch (e) {
      notify.error('Error al crear pedido: ' + (e as Error).message)
    }
    setGuardando(false)
  }, [nuevoPedido, itemsFinales, totalFinal, crearPedido, user, resetNuevoPedido, notify, productos, isPreventista, capturarGps, registrarGpsPedido])

  // ModalFiltroFecha: onApply({ fechaDesde, fechaHasta })
  const handleFiltroFechaApply = useCallback((f: { fechaDesde: string | null; fechaHasta: string | null }) => {
    setFiltros(prev => ({ ...prev, fechaDesde: f.fechaDesde, fechaHasta: f.fechaHasta }))
    setPaginaActual(1)
    setModalFiltroFechaOpen(false)
  }, [])

  // ModalExportarPDF handlers (lazy PDF generation)
  const handleExportarOrdenPreparacion = useCallback(async (pedidosExport: PedidoDB[]) => {
    try {
      const { generarOrdenPreparacion } = await import('../../lib/pdfExport')
      generarOrdenPreparacion(pedidosExport)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  const handleExportarHojaRuta = useCallback(async (transportista: PerfilDB | undefined, pedidosExport: PedidoDB[]) => {
    if (!transportista) return
    try {
      const { generarHojaRutaOptimizada } = await import('../../lib/pdfExport')
      generarHojaRutaOptimizada(transportista, pedidosExport)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  const handleImprimirComandas = useCallback(async (pedidosExport: PedidoDB[]) => {
    try {
      const { generarComandasMultiples } = await import('../../lib/pdfExport')
      generarComandasMultiples(pedidosExport)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  // ModalGestionRutas handlers
  const handleAplicarOrden = useCallback(async (data: { ordenOptimizado: Array<{ pedido_id: string; orden: number }>; transportistaId: string; distancia: number | null; duracion: number | null }) => {
    setGuardando(true)
    try {
      if (data.ordenOptimizado) {
        await supabase.rpc('actualizar_orden_entrega', {
          p_pedidos: data.ordenOptimizado.map(p => ({ id: p.pedido_id, orden_entrega: p.orden }))
        })
      }
      setModalOptimizarRutaOpen(false)
      limpiarRuta()
      notify.success('Orden de entrega actualizado')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [limpiarRuta, notify])

  const handleExportarHojaRutaOptimizada = useCallback(async (transportista: PerfilDB | undefined, pedidosOrdenados: PedidoDB[]) => {
    try {
      const { generarHojaRutaOptimizada } = await import('../../lib/pdfExport')
      if (transportista) generarHojaRutaOptimizada(transportista, pedidosOrdenados)
    } catch (e) { notify.error((e as Error).message) }
  }, [notify])

  // ModalEntregaConSalvedad handlers
  const handleSaveSalvedades = useCallback(async (salvedades: RegistrarSalvedadInput[]): Promise<RegistrarSalvedadResult[]> => {
    const results: RegistrarSalvedadResult[] = []
    for (const salvedad of salvedades) {
      const { data, error } = await supabase.rpc('registrar_salvedad', {
        p_pedido_id: parseInt(String(salvedad.pedidoId), 10),
        p_pedido_item_id: parseInt(String(salvedad.pedidoItemId), 10),
        p_cantidad_afectada: salvedad.cantidadAfectada,
        p_motivo: salvedad.motivo,
        p_descripcion: salvedad.descripcion || null,
        p_foto_url: salvedad.fotoUrl || null,
        p_devolver_stock: salvedad.devolverStock !== false
      })
      if (error) {
        results.push({ success: false, error: error.message })
      } else {
        const result = data as Record<string, unknown> | null
        results.push({
          success: !!result?.success,
          error: result?.success ? undefined : String(result?.error || 'Error desconocido')
        })
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
  const handleRegistrarPagoTransportista = useCallback(async (data: {
    clienteId: string;
    pedidoId: string | null;
    monto: number;
    formaPago: string;
    referencia: string;
    notas: string;
    fecha: string;
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
    })
    queryClient.invalidateQueries({ queryKey: ['pedidos'] })
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
          onExportarPDF={() => setModalExportarPDFOpen(true)}
          onExportarExcel={handleExportarExcel}
          onModalFiltroFecha={() => setModalFiltroFechaOpen(true)}
          onVerHistorial={handleVerHistorial}
          onEditarPedido={handleEditarPedido}
          onEditarNotas={handleEditarNotas}
          onMarcarEnPreparacion={handleMarcarEnPreparacion}
          onVolverAPendiente={handleVolverAPendiente}
          onAsignarTransportista={handleAsignarTransportista}
          onMarcarEntregado={handleMarcarEntregado}
          onMarcarEntregadoConSalvedad={handleMarcarEntregadoConSalvedad}
          onDesmarcarEntregado={handleDesmarcarEntregado}
          onCancelarPedido={handleCancelarPedido}
          onEntregasMasivas={() => setModalEntregasMasivasOpen(true)}
          onPagosMasivos={() => setModalPagosMasivosOpen(true)}
          onAsignarTransportistaMasivo={() => setModalAsignarMasivoOpen(true)}
          onMarcarVisita={() => setModalMarcarVisitaOpen(true)}
          onVerVisitasHoy={() => setModalVisitasHoyOpen(true)}
          onRegistrarSalvedad={handleRegistrarSalvedadSingle}
          onRegistrarPago={handleRegistrarPagoTransportista}
          onAbrirPagoPedido={handleAbrirRegistrarPago}
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
            onClose={() => { setModalPedidoOpen(false); resetNuevoPedido() }}
            onClienteChange={(id: string) => setNuevoPedido(prev => ({ ...prev, clienteId: id }))}
            onAgregarItem={(productoId: string) => {
              setNuevoPedido(prev => {
                const existe = prev.items.find(i => i.productoId === productoId)
                const producto = productos.find(p => p.id === productoId)
                if (existe) {
                  return { ...prev, items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i) }
                }
                return { ...prev, items: [...prev.items, { productoId, cantidad: 1, precioUnitario: producto?.precio || 0 }] }
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
                }
                const newCliente = await crearClienteMut.mutateAsync(dbData)
                notify.success(`Cliente "${newCliente.nombre_fantasia}" creado`)
                return { id: newCliente.id }
              } catch (e) {
                notify.error((e as Error).message || 'Error al crear cliente')
                throw e
              }
            }}
            onGuardar={handleGuardarPedido}
            guardando={guardando}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            onNotasChange={(notas: string) => setNuevoPedido(prev => ({ ...prev, notas }))}
            onFormaPagoChange={(fp: string) => setNuevoPedido(prev => ({ ...prev, formaPago: fp }))}
            onEstadoPagoChange={(ep: string) => setNuevoPedido(prev => ({ ...prev, estadoPago: ep }))}
            onMontoPagadoChange={(m: number) => setNuevoPedido(prev => ({ ...prev, montoPagado: m }))}
            onFechaChange={(fecha: string) => setNuevoPedido(prev => ({ ...prev, fecha }))}
            onTipoFacturaChange={(tipo: 'ZZ' | 'FC') => setNuevoPedido(prev => ({ ...prev, tipoFactura: tipo }))}
            onFechaEntregaProgramadaChange={(fecha: string) => setNuevoPedido(prev => ({ ...prev, fechaEntregaProgramada: fecha }))}
            isOffline={!isOnline}
          />
        </Suspense>
      )}

      {/* Modal Asignar Transportista */}
      {modalAsignarOpen && pedidoAsignando && (
        <Suspense fallback={null}>
          <ModalAsignarTransportista
            pedido={pedidoAsignando}
            transportistas={transportistas}
            onSave={handleConfirmarAsignar}
            onClose={() => { setModalAsignarOpen(false); setPedidoAsignando(null) }}
            guardando={guardando}
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
            onSave={handleGuardarEdicion}
            onSaveItems={handleGuardarItemsEdicion}
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
            pedidos={pedidos}
            onOptimizar={optimizarRuta as Parameters<typeof ModalGestionRutas>[0]['onOptimizar']}
            onAplicarOrden={handleAplicarOrden as Parameters<typeof ModalGestionRutas>[0]['onAplicarOrden']}
            onExportarPDF={handleExportarHojaRutaOptimizada as Parameters<typeof ModalGestionRutas>[0]['onExportarPDF']}
            onClose={() => { setModalOptimizarRutaOpen(false); limpiarRuta() }}
            loading={loadingOptimizacion}
            guardando={guardando}
            rutaOptimizada={rutaOptimizada as Parameters<typeof ModalGestionRutas>[0]['rutaOptimizada']}
            error={errorOptimizacion}
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

      {/* Modal Asignar Transportista Masivo */}
      {modalAsignarMasivoOpen && (
        <Suspense fallback={null}>
          <ModalAsignarTransportistaMasivo
            transportistas={transportistas}
            onConfirm={handleAsignarTransportistaMasivo}
            onClose={() => setModalAsignarMasivoOpen(false)}
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

      {/* Modal Marcar Visita (preventista) */}
      {modalMarcarVisitaOpen && (
        <Suspense fallback={null}>
          <ModalMarcarVisita
            clientes={clientes}
            userId={user?.id ?? null}
            isAdmin={isAdmin}
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
    </>
  )
}
