/**
 * PedidosContainer
 *
 * Container que carga pedidos paginados server-side usando TanStack Query.
 * Maneja estado de paginación, filtros, búsqueda y modales.
 * Reemplaza el flujo legacy de App.tsx → VistaPedidos con prop drilling.
 */
import React, { lazy, Suspense, useState, useCallback, useMemo } from 'react'
import { Loader2 } from 'lucide-react'
import {
  usePedidosPaginatedQuery,
  useCrearPedidoMutation,
  useCambiarEstadoMutation,
  useAsignarTransportistaMutation,
  useEliminarPedidoMutation,
  useClientesQuery,
  useProductosQuery,
  useTransportistasQuery,
} from '../../hooks/queries'
import { useAuthData } from '../../contexts/AuthDataContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useOptimizarRuta } from '../../hooks/useOptimizarRuta'
import { usePrecioMayorista } from '../../hooks/usePrecioMayorista'
import { supabase } from '../../hooks/supabase/base'
import type { PedidoDB, FiltrosPedidosState, PerfilDB, RegistrarSalvedadInput, RegistrarSalvedadResult } from '../../types'

// Lazy load de componentes
const VistaPedidos = lazy(() => import('../vistas/VistaPedidos'))
const ModalPedido = lazy(() => import('../modals/ModalPedido'))
const ModalConfirmacion = lazy(() => import('../modals/ModalConfirmacion'))
const ModalAsignarTransportista = lazy(() => import('../modals/ModalAsignarTransportista'))
const ModalHistorialPedido = lazy(() => import('../modals/ModalHistorialPedido'))
const ModalEditarPedido = lazy(() => import('../modals/ModalEditarPedido'))
const ModalFiltroFecha = lazy(() => import('../modals/ModalFiltroFecha'))
const ModalExportarPDF = lazy(() => import('../modals/ModalExportarPDF'))
const ModalGestionRutas = lazy(() => import('../modals/ModalGestionRutas'))
const ModalPedidosEliminados = lazy(() => import('../modals/ModalPedidosEliminados'))
const ModalEntregaConSalvedad = lazy(() => import('../modals/ModalEntregaConSalvedad'))

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
  const { user, isAdmin, isPreventista, isTransportista, isOnline } = useAuthData()
  const notify = useNotification()

  // Pagination state
  const [paginaActual, setPaginaActual] = useState(1)
  const [busqueda, setBusqueda] = useState('')
  const [filtros, setFiltros] = useState<FiltrosPedidosState>(DEFAULT_FILTROS)

  // Queries
  const { data: paginatedResult, isLoading: loadingPedidos } = usePedidosPaginatedQuery(
    paginaActual, ITEMS_PER_PAGE, filtros, busqueda
  )
  const { data: clientes = [] } = useClientesQuery()
  const { data: productos = [] } = useProductosQuery()
  const { data: transportistas = [] } = useTransportistasQuery()

  // Mutations
  const crearPedido = useCrearPedidoMutation()
  const cambiarEstado = useCambiarEstadoMutation()
  const asignarTransportistaMut = useAsignarTransportistaMutation()
  const eliminarPedido = useEliminarPedidoMutation()

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
  const [modalPedidosEliminadosOpen, setModalPedidosEliminadosOpen] = useState(false)
  const [modalEntregaSalvedadOpen, setModalEntregaSalvedadOpen] = useState(false)
  const [confirmConfig, setConfirmConfig] = useState<ConfirmConfig>({ visible: false })

  // Pedido-specific state for modals
  const [pedidoAsignando, setPedidoAsignando] = useState<PedidoDB | null>(null)
  const [pedidoHistorial, setPedidoHistorial] = useState<PedidoDB | null>(null)
  const [historialCambios, setHistorialCambios] = useState<unknown[]>([])
  const [cargandoHistorial, setCargandoHistorial] = useState(false)
  const [pedidoEditando, setPedidoEditando] = useState<PedidoDB | null>(null)
  const [pedidoParaSalvedad, setPedidoParaSalvedad] = useState<PedidoDB | null>(null)
  const [guardando, setGuardando] = useState(false)

  // Nuevo pedido form state
  const [nuevoPedido, setNuevoPedido] = useState({
    clienteId: '',
    items: [] as Array<{ productoId: string; cantidad: number; precioUnitario: number }>,
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0,
  })

  const resetNuevoPedido = useCallback(() => {
    setNuevoPedido({
      clienteId: '', items: [], notas: '',
      formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0,
    })
  }, [])

  // Resolve wholesale prices for current pedido items
  const { itemsConPrecioMayorista, totalMayorista } = usePrecioMayorista(nuevoPedido.items)

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

  const handleEliminarPedido = useCallback((pedido: PedidoDB) => {
    setConfirmConfig({
      visible: true, titulo: 'Eliminar pedido',
      mensaje: '¿Eliminar este pedido? El stock será restaurado.', tipo: 'danger',
      onConfirm: async () => {
        try {
          await eliminarPedido.mutateAsync({ id: pedido.id, usuarioId: user?.id })
          notify.success('Pedido eliminado')
        } catch (e) { notify.error((e as Error).message) }
        setConfirmConfig({ visible: false })
      },
    })
  }, [eliminarPedido, user, notify])

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

  const handleMarcarEntregadoConSalvedad = useCallback((pedido: PedidoDB) => {
    setPedidoParaSalvedad(pedido)
    setModalEntregaSalvedadOpen(true)
  }, [])

  // Excel/CSV export
  const handleExportarExcel = useCallback(() => {
    setExportando(true)
    try {
      const rows = pedidos.map(p => [
        p.id,
        (p.cliente as { nombre_fantasia?: string })?.nombre_fantasia || '',
        p.estado, p.total, p.forma_pago, p.estado_pago, p.created_at,
      ].join(','))
      const csv = ['ID,Cliente,Estado,Total,FormaPago,EstadoPago,Fecha', ...rows].join('\n')
      const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `pedidos-${new Date().toISOString().split('T')[0]}.csv`
      a.click()
      URL.revokeObjectURL(url)
    } catch {
      notify.error('Error al exportar')
    }
    setExportando(false)
  }, [pedidos, notify])

  // Fetch pedidos eliminados
  const fetchPedidosEliminados = useCallback(async () => {
    const { data } = await supabase
      .from('pedidos_eliminados').select('*')
      .order('deleted_at', { ascending: false }).limit(50)
    return (data || []) as PedidoDB[]
  }, [])

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
  const handleGuardarEdicion = useCallback(async (data: { notas: string; formaPago: string; estadoPago: string; montoPagado: number }) => {
    if (!pedidoEditando) return
    setGuardando(true)
    try {
      await supabase.from('pedidos').update({
        notas: data.notas, forma_pago: data.formaPago,
        estado_pago: data.estadoPago, monto_pagado: data.montoPagado ?? 0,
      }).eq('id', pedidoEditando.id)
      setModalEditarOpen(false)
      setPedidoEditando(null)
      notify.success('Pedido actualizado')
    } catch (e) { notify.error((e as Error).message) }
    setGuardando(false)
  }, [pedidoEditando, notify])

  // ModalPedido handlers
  const handleGuardarPedido = useCallback(async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos')
      return
    }
    setGuardando(true)
    try {
      // Use wholesale-resolved items and total (falls back to original if no mayorista applies)
      await crearPedido.mutateAsync({
        clienteId: nuevoPedido.clienteId,
        items: itemsConPrecioMayorista,
        total: totalMayorista,
        usuarioId: user?.id ?? null,
        notas: nuevoPedido.notas,
        formaPago: nuevoPedido.formaPago,
        estadoPago: nuevoPedido.estadoPago,
        montoPagado: nuevoPedido.montoPagado,
      })
      resetNuevoPedido()
      setModalPedidoOpen(false)
      notify.success('Pedido creado correctamente')
    } catch (e) {
      notify.error('Error al crear pedido: ' + (e as Error).message)
    }
    setGuardando(false)
  }, [nuevoPedido, itemsConPrecioMayorista, totalMayorista, crearPedido, user, resetNuevoPedido, notify])

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
      const { generarHojaRuta } = await import('../../lib/pdfExport')
      generarHojaRuta(transportista, pedidosExport)
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
      const { error } = await supabase.from('salvedades').insert(salvedad)
      results.push({ success: !error, error: error?.message })
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
          onMarcarEnPreparacion={handleMarcarEnPreparacion}
          onVolverAPendiente={handleVolverAPendiente}
          onAsignarTransportista={handleAsignarTransportista}
          onMarcarEntregado={handleMarcarEntregado}
          onMarcarEntregadoConSalvedad={handleMarcarEntregadoConSalvedad}
          onDesmarcarEntregado={handleDesmarcarEntregado}
          onEliminarPedido={handleEliminarPedido}
          onVerPedidosEliminados={() => setModalPedidosEliminadosOpen(true)}
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
            onCrearCliente={async () => ({ id: '' as string | number })}
            onGuardar={handleGuardarPedido}
            guardando={guardando}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            onNotasChange={(notas: string) => setNuevoPedido(prev => ({ ...prev, notas }))}
            onFormaPagoChange={(fp: string) => setNuevoPedido(prev => ({ ...prev, formaPago: fp }))}
            onEstadoPagoChange={(ep: string) => setNuevoPedido(prev => ({ ...prev, estadoPago: ep }))}
            onMontoPagadoChange={(m: number) => setNuevoPedido(prev => ({ ...prev, montoPagado: m }))}
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
            onClose={() => { setModalEditarOpen(false); setPedidoEditando(null) }}
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

      {/* Modal Pedidos Eliminados */}
      {modalPedidosEliminadosOpen && (
        <Suspense fallback={null}>
          <ModalPedidosEliminados
            onFetch={fetchPedidosEliminados as unknown as Parameters<typeof ModalPedidosEliminados>[0]['onFetch']}
            onClose={() => setModalPedidosEliminadosOpen(false)}
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
    </>
  )
}
