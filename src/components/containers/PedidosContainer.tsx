/**
 * PedidosContainer
 *
 * Container que carga pedidos paginados server-side usando TanStack Query.
 * Maneja estado de paginación, filtros, búsqueda y modales.
 * Reemplaza el flujo legacy de App.tsx → VistaPedidos con prop drilling.
 */
import React, { lazy, Suspense, useState, useCallback, useMemo } from 'react'
import { fechaLocalISO } from '../../utils/formatters'
import { useQueryClient } from '@tanstack/react-query'
import { Loader2 } from 'lucide-react'
import {
  usePedidosPaginatedQuery,
  useCrearPedidoMutation,
  useCambiarEstadoMutation,
  useAsignarTransportistaMutation,
  useEntregasMasivasMutation,
  useCancelarPedidoMutation,
  usePagosMasivosMutation,
  useClientesQuery,
  useProductosQuery,
  useTransportistasQuery,
  useCrearClienteMutation,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useOptimizarRuta } from '../../hooks/useOptimizarRuta'
import { usePromocionPedido } from '../../hooks/usePromocionPedido'
import { useDebounce } from '../../hooks/useAsync'
import { supabase } from '../../hooks/supabase/base'
import type { PedidoDB, FiltrosPedidosState, PerfilDB, RegistrarSalvedadInput, RegistrarSalvedadResult } from '../../types'
import type { PedidoEditItem } from '../modals/ModalEditarPedido'

// Lazy load de componentes
const VistaPedidos = lazy(() => import('../vistas/VistaPedidos'))
const ModalPedido = lazy(() => import('../modals/ModalPedido'))
const ModalConfirmacion = lazy(() => import('../modals/ModalConfirmacion'))
const ModalAsignarTransportista = lazy(() => import('../modals/ModalAsignarTransportista'))
const ModalHistorialPedido = lazy(() => import('../modals/ModalHistorialPedido'))
const ModalEditarPedido = lazy(() => import('../modals/ModalEditarPedido'))
const ModalEditarNotas = lazy(() => import('../modals/ModalEditarNotas'))
const ModalFiltroFecha = lazy(() => import('../modals/ModalFiltroFecha'))
const ModalExportarPDF = lazy(() => import('../modals/ModalExportarPDF'))
const ModalGestionRutas = lazy(() => import('../modals/ModalGestionRutas'))
const ModalEntregaConSalvedad = lazy(() => import('../modals/ModalEntregaConSalvedad'))
const ModalEntregasMasivas = lazy(() => import('../modals/ModalEntregasMasivas'))
const ModalCancelarPedido = lazy(() => import('../modals/ModalCancelarPedido'))
const ModalPagosMasivos = lazy(() => import('../modals/ModalPagosMasivos'))
const ModalAsignarTransportistaMasivo = lazy(() => import('../modals/ModalAsignarTransportistaMasivo'))

const ITEMS_PER_PAGE = 15

const DEFAULT_FILTROS: FiltrosPedidosState = {
  fechaDesde: null,
  fechaHasta: null,
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: 'todos',
  busqueda: '',
  conSalvedad: 'todos',
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
  const [filtros, setFiltros] = useState<FiltrosPedidosState>(DEFAULT_FILTROS)

  // Queries - use debounced search to avoid firing on every keystroke
  const { data: paginatedResult, isLoading: loadingPedidos } = usePedidosPaginatedQuery(
    paginaActual, ITEMS_PER_PAGE, filtros, debouncedBusqueda, authReady
  )
  const { data: clientes = [] } = useClientesQuery()
  const { data: productos = [] } = useProductosQuery()
  const { data: transportistas = [] } = useTransportistasQuery()

  // Mutations
  const crearPedido = useCrearPedidoMutation()
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
  })

  const resetNuevoPedido = useCallback(() => {
    setNuevoPedido({
      clienteId: '', items: [], notas: '',
      formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0,
      fecha: fechaLocalISO(),
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

  // Estado changes with confirmation dialog
  const handleMarcarEntregado = useCallback((pedido: PedidoDB) => {
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
  }, [cambiarEstado, notify])

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

  const handleEntregasMasivas = useCallback(async (transportistaId: string, pedidoIds: string[]) => {
    setGuardando(true)
    try {
      await entregasMasivas.mutateAsync({ pedidoIds, transportistaId })
      setModalEntregasMasivasOpen(false)
      notify.success(`${pedidoIds.length} pedido${pedidoIds.length !== 1 ? 's' : ''} marcado${pedidoIds.length !== 1 ? 's' : ''} como entregado${pedidoIds.length !== 1 ? 's' : ''}`)
    } catch (e) { notify.error('Error en entregas masivas: ' + (e as Error).message) }
    setGuardando(false)
  }, [entregasMasivas, notify])

  const handlePagosMasivos = useCallback(async (formaPago: string, pedidoIds: string[]) => {
    setGuardando(true)
    try {
      await pagosMasivos.mutateAsync({ pedidoIds, formaPago })
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

  // ModalEditarPedido: onSave({ notas, formaPago, estadoPago, montoPagado })
  const handleGuardarEdicion = useCallback(async (data: { notas: string; formaPago: string; estadoPago: string; montoPagado: number; fecha?: string }) => {
    if (!pedidoEditando) return
    setGuardando(true)
    try {
      const updateData: Record<string, unknown> = {
        notas: data.notas, forma_pago: data.formaPago,
        estado_pago: data.estadoPago, monto_pagado: data.montoPagado ?? 0,
      }
      if (data.fecha) updateData.fecha = data.fecha
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

  // ModalEditarPedido: onSaveItems - guardar cambios de items via RPC
  const handleGuardarItemsEdicion = useCallback(async (items: PedidoEditItem[]) => {
    if (!pedidoEditando) return
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId,
      cantidad: item.cantidad,
      precio_unitario: item.precioUnitario,
      ...(item.esBonificacion ? { es_bonificacion: true } : {}),
      ...(item.promocionId ? { promocion_id: item.promocionId } : {}),
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

  // ModalPedido handlers
  const handleGuardarPedido = useCallback(async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos')
      return
    }
    setGuardando(true)
    try {
      // Use promo+wholesale-resolved items and total (includes bonificaciones)
      const itemsParaCrear = itemsFinales.map(item => ({
        productoId: String(item.productoId),
        cantidad: item.cantidad,
        precioUnitario: item.precioUnitario,
        ...(item.esBonificacion ? { esBonificacion: true as const } : {}),
        ...(item.promoId ? { promocionId: item.promoId } : {}),
      }))
      await crearPedido.mutateAsync({
        clienteId: nuevoPedido.clienteId,
        items: itemsParaCrear,
        total: totalFinal,
        usuarioId: user?.id ?? null,
        notas: nuevoPedido.notas,
        formaPago: nuevoPedido.formaPago,
        estadoPago: nuevoPedido.estadoPago,
        montoPagado: nuevoPedido.montoPagado,
        fecha: nuevoPedido.fecha,
      })
      resetNuevoPedido()
      setModalPedidoOpen(false)
      notify.success('Pedido creado correctamente')
    } catch (e) {
      notify.error('Error al crear pedido: ' + (e as Error).message)
    }
    setGuardando(false)
  }, [nuevoPedido, itemsFinales, totalFinal, crearPedido, user, resetNuevoPedido, notify])

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
    return results
  }, [])

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
            isAdmin={isAdmin}
            onSave={handleGuardarEdicion}
            onSaveItems={handleGuardarItemsEdicion}
            onClose={() => { setModalEditarOpen(false); setPedidoEditando(null) }}
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
          />
        </Suspense>
      )}
    </>
  )
}
