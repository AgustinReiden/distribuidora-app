/**
 * Handlers para operaciones con pedidos
 */
import { useCallback } from 'react'
import { calcularTotalPedido } from '../useAppState'
import { generarOrdenPreparacion, generarHojaRuta, generarHojaRutaOptimizada } from '../../lib/pdfExport'

export function usePedidoHandlers({
  productos,
  crearPedido,
  cambiarEstado,
  asignarTransportista,
  eliminarPedido,
  actualizarNotasPedido,
  actualizarEstadoPago,
  actualizarFormaPago,
  actualizarOrdenEntrega,
  actualizarItemsPedido,
  fetchHistorialPedido,
  validarStock,
  descontarStock,
  restaurarStock,
  registrarPago,
  crearRecorrido,
  limpiarRuta,
  agregarCliente,
  modales,
  setGuardando,
  setNuevoPedido,
  resetNuevoPedido,
  nuevoPedido,
  setPedidoAsignando,
  setPedidoHistorial,
  setHistorialCambios,
  setPedidoEditando,
  setCargandoHistorial,
  pedidoAsignando,
  pedidoEditando,
  refetchProductos,
  refetchPedidos,
  refetchMetricas,
  notify,
  user,
  isOnline,
  guardarPedidoOffline,
  rutaOptimizada
}) {
  // Item management
  const agregarItemPedido = useCallback((productoId) => {
    const existe = nuevoPedido.items.find(i => i.productoId === productoId)
    const producto = productos.find(p => p.id === productoId)
    if (existe) {
      setNuevoPedido(prev => ({
        ...prev,
        items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i)
      }))
    } else {
      setNuevoPedido(prev => ({
        ...prev,
        items: [...prev.items, { productoId, cantidad: 1, precioUnitario: producto?.precio || 0 }]
      }))
    }
  }, [productos, nuevoPedido.items, setNuevoPedido])

  const actualizarCantidadItem = useCallback((productoId, cantidad) => {
    if (cantidad <= 0) {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.filter(i => i.productoId !== productoId) }))
    } else {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad } : i) }))
    }
  }, [setNuevoPedido])

  // Form field handlers
  const handleClienteChange = useCallback((clienteId) => {
    setNuevoPedido(prev => ({ ...prev, clienteId }))
  }, [setNuevoPedido])

  const handleNotasChange = useCallback((notas) => {
    setNuevoPedido(prev => ({ ...prev, notas }))
  }, [setNuevoPedido])

  const handleFormaPagoChange = useCallback((formaPago) => {
    setNuevoPedido(prev => ({ ...prev, formaPago }))
  }, [setNuevoPedido])

  const handleEstadoPagoChange = useCallback((estadoPago) => {
    setNuevoPedido(prev => ({ ...prev, estadoPago, montoPagado: estadoPago === 'parcial' ? prev.montoPagado : 0 }))
  }, [setNuevoPedido])

  const handleMontoPagadoChange = useCallback((montoPagado) => {
    setNuevoPedido(prev => ({ ...prev, montoPagado }))
  }, [setNuevoPedido])

  const handleCrearClienteEnPedido = useCallback(async (nuevoCliente) => {
    const cliente = await agregarCliente(nuevoCliente)
    notify.success('Cliente creado correctamente')
    return cliente
  }, [agregarCliente, notify])

  // Main order creation
  const handleGuardarPedidoConOffline = useCallback(async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos')
      return
    }
    const validacion = validarStock(nuevoPedido.items)
    if (!validacion.valido) {
      notify.error(`Stock insuficiente:\n${validacion.errores.map(e => e.mensaje).join('\n')}`, 5000)
      return
    }

    if (!isOnline) {
      guardarPedidoOffline({
        clienteId: parseInt(nuevoPedido.clienteId),
        items: nuevoPedido.items,
        total: calcularTotalPedido(nuevoPedido.items),
        usuarioId: user.id,
        notas: nuevoPedido.notas,
        formaPago: nuevoPedido.formaPago,
        estadoPago: nuevoPedido.estadoPago,
        montoPagado: nuevoPedido.montoPagado
      })
      resetNuevoPedido()
      modales.pedido.setOpen(false)
      notify.warning('Sin conexión. Pedido guardado localmente y se sincronizará automáticamente.')
      return
    }

    if (nuevoPedido.estadoPago === 'parcial' && (!nuevoPedido.montoPagado || nuevoPedido.montoPagado <= 0)) {
      notify.warning('Ingresá el monto del pago parcial')
      return
    }

    setGuardando(true)
    try {
      const pedidoCreado = await crearPedido(
        parseInt(nuevoPedido.clienteId),
        nuevoPedido.items,
        calcularTotalPedido(nuevoPedido.items),
        user.id,
        descontarStock,
        nuevoPedido.notas,
        nuevoPedido.formaPago,
        nuevoPedido.estadoPago
      )

      if (nuevoPedido.estadoPago === 'parcial' && nuevoPedido.montoPagado > 0 && pedidoCreado?.id) {
        await registrarPago({
          clienteId: parseInt(nuevoPedido.clienteId),
          pedidoId: pedidoCreado.id,
          monto: nuevoPedido.montoPagado,
          formaPago: nuevoPedido.formaPago,
          notas: 'Pago parcial al crear pedido',
          usuarioId: user.id
        })
      }

      resetNuevoPedido()
      modales.pedido.setOpen(false)
      refetchProductos()
      refetchMetricas()
      notify.success('Pedido creado correctamente', { persist: true })
    } catch (e) {
      notify.error('Error al crear pedido: ' + e.message)
    }
    setGuardando(false)
  }, [nuevoPedido, validarStock, isOnline, guardarPedidoOffline, user, resetNuevoPedido, modales.pedido, crearPedido, descontarStock, registrarPago, refetchProductos, refetchMetricas, notify, setGuardando])

  // State change handlers
  const handleMarcarEntregado = useCallback((pedido) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Confirmar entrega',
      mensaje: `¿Confirmar entrega del pedido #${pedido.id}?`,
      tipo: 'success',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await cambiarEstado(pedido.id, 'entregado')
          refetchMetricas()
          notify.success(`Pedido #${pedido.id} marcado como entregado`, { persist: true })
        } catch (e) {
          notify.error(e.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando])

  const handleDesmarcarEntregado = useCallback((pedido) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Revertir entrega',
      mensaje: `¿Revertir entrega del pedido #${pedido.id}?`,
      tipo: 'warning',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await cambiarEstado(pedido.id, pedido.transportista_id ? 'asignado' : 'pendiente')
          refetchMetricas()
          notify.warning(`Pedido #${pedido.id} revertido`)
        } catch (e) {
          notify.error(e.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando])

  const handleMarcarEnPreparacion = useCallback((pedido) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Marcar en preparación',
      mensaje: `¿Marcar pedido #${pedido.id} como "En preparación"?`,
      tipo: 'success',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await cambiarEstado(pedido.id, 'en_preparacion')
          refetchMetricas()
          notify.success(`Pedido #${pedido.id} marcado como en preparación`)
        } catch (e) {
          notify.error(e.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando])

  const handleAsignarTransportista = useCallback(async (transportistaId, marcarListo = false) => {
    if (!pedidoAsignando) return
    setGuardando(true)
    try {
      await asignarTransportista(pedidoAsignando.id, transportistaId || null, marcarListo)
      modales.asignar.setOpen(false)
      setPedidoAsignando(null)
      if (transportistaId) {
        notify.success(marcarListo ? 'Transportista asignado y pedido listo para entregar' : 'Transportista asignado (el pedido mantiene su estado actual)')
      } else {
        notify.success('Transportista desasignado')
      }
    } catch (e) {
      notify.error('Error: ' + e.message)
    }
    setGuardando(false)
  }, [pedidoAsignando, asignarTransportista, modales.asignar, setPedidoAsignando, notify, setGuardando])

  const handleEliminarPedido = useCallback((id) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar pedido',
      mensaje: '¿Eliminar este pedido? El stock será restaurado y quedará registrado en el historial.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true)
        try {
          await eliminarPedido(id, restaurarStock, user?.id)
          refetchProductos()
          refetchMetricas()
          notify.success('Pedido eliminado y registrado en historial')
        } catch (e) {
          notify.error(e.message)
        } finally {
          setGuardando(false)
          modales.confirm.setConfig({ visible: false })
        }
      }
    })
  }, [eliminarPedido, restaurarStock, user, refetchProductos, refetchMetricas, notify, modales.confirm, setGuardando])

  // History and editing
  const handleVerHistorial = useCallback(async (pedido) => {
    setPedidoHistorial(pedido)
    modales.historial.setOpen(true)
    setCargandoHistorial(true)
    try {
      const historial = await fetchHistorialPedido(pedido.id)
      setHistorialCambios(historial)
    } catch (e) {
      notify.error('Error al cargar historial: ' + e.message)
      setHistorialCambios([])
    } finally {
      setCargandoHistorial(false)
    }
  }, [fetchHistorialPedido, setPedidoHistorial, modales.historial, setCargandoHistorial, setHistorialCambios, notify])

  const handleEditarPedido = useCallback((pedido) => {
    setPedidoEditando(pedido)
    modales.editarPedido.setOpen(true)
  }, [setPedidoEditando, modales.editarPedido])

  const handleGuardarEdicionPedido = useCallback(async ({ notas, formaPago, estadoPago, montoPagado }) => {
    if (!pedidoEditando) return
    setGuardando(true)
    try {
      await actualizarNotasPedido(pedidoEditando.id, notas)
      await actualizarFormaPago(pedidoEditando.id, formaPago)
      await actualizarEstadoPago(pedidoEditando.id, estadoPago, montoPagado)
      modales.editarPedido.setOpen(false)
      setPedidoEditando(null)
      notify.success('Pedido actualizado correctamente')
    } catch (e) {
      notify.error('Error al actualizar pedido: ' + e.message)
    }
    setGuardando(false)
  }, [pedidoEditando, actualizarNotasPedido, actualizarFormaPago, actualizarEstadoPago, modales.editarPedido, setPedidoEditando, notify, setGuardando])

  // Route optimization
  const handleAplicarOrdenOptimizado = useCallback(async (data) => {
    setGuardando(true)
    try {
      const ordenOptimizado = Array.isArray(data) ? data : data.ordenOptimizado
      const transportistaId = data.transportistaId || null
      const distancia = data.distancia || null
      const duracion = data.duracion || null

      await actualizarOrdenEntrega(ordenOptimizado)

      if (transportistaId && ordenOptimizado?.length > 0) {
        try {
          await crearRecorrido(transportistaId, ordenOptimizado, distancia, duracion)
          notify.success('Ruta optimizada y recorrido creado correctamente')
        } catch {
          notify.success('Orden de entrega actualizado (sin registro de recorrido)')
        }
      } else {
        notify.success('Orden de entrega actualizado correctamente')
      }

      modales.optimizarRuta.setOpen(false)
      limpiarRuta()
      refetchPedidos()
    } catch (e) {
      notify.error('Error al actualizar orden: ' + e.message)
    }
    setGuardando(false)
  }, [actualizarOrdenEntrega, crearRecorrido, limpiarRuta, refetchPedidos, modales.optimizarRuta, notify, setGuardando])

  const handleExportarHojaRutaOptimizada = useCallback((transportista, pedidosOrdenados) => {
    try {
      generarHojaRutaOptimizada(transportista, pedidosOrdenados, rutaOptimizada || {})
      notify.success('PDF generado correctamente')
    } catch (e) {
      notify.error('Error al generar PDF: ' + e.message)
    }
  }, [rutaOptimizada, notify])

  const handleCerrarModalOptimizar = useCallback(() => {
    modales.optimizarRuta.setOpen(false)
    limpiarRuta()
  }, [modales.optimizarRuta, limpiarRuta])

  return {
    // Item management
    agregarItemPedido,
    actualizarCantidadItem,
    handleClienteChange,
    handleNotasChange,
    handleFormaPagoChange,
    handleEstadoPagoChange,
    handleMontoPagadoChange,
    handleCrearClienteEnPedido,
    handleGuardarPedidoConOffline,
    // State changes
    handleMarcarEntregado,
    handleDesmarcarEntregado,
    handleMarcarEnPreparacion,
    handleAsignarTransportista,
    handleEliminarPedido,
    // History and editing
    handleVerHistorial,
    handleEditarPedido,
    handleGuardarEdicionPedido,
    // Route optimization
    handleAplicarOrdenOptimizado,
    handleExportarHojaRutaOptimizada,
    handleCerrarModalOptimizar,
    // PDF exports
    generarOrdenPreparacion,
    generarHojaRuta
  }
}
