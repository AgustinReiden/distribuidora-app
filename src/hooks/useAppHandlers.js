/**
 * Hook consolidado para los handlers de la aplicación
 * Extrae todos los handlers de App.jsx para mejor organización
 */
import { useCallback } from 'react';
import { calcularTotalPedido } from './useAppState';
import { generarOrdenPreparacion, generarHojaRuta, generarHojaRutaOptimizada, generarReciboPago } from '../lib/pdfExport.js';

export function useAppHandlers({
  // Hooks de datos
  clientes,
  productos,
  pedidos,
  proveedores,

  // Funciones CRUD
  agregarCliente,
  actualizarCliente,
  eliminarCliente,
  agregarProducto,
  actualizarProducto,
  eliminarProducto,
  validarStock,
  descontarStock,
  restaurarStock,
  actualizarPreciosMasivo,
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
  actualizarUsuario,
  registrarPago,
  obtenerResumenCuenta,
  registrarMerma,
  registrarCompra,
  anularCompra,
  agregarProveedor,
  actualizarProveedor,
  crearRecorrido,
  limpiarRuta,

  // Funciones de refetch
  refetchProductos,
  refetchPedidos,
  refetchMetricas,
  refetchMermas,
  refetchCompras,
  refetchProveedores,

  // Estado de la app
  appState,

  // Notificaciones
  notify,

  // Usuario actual
  user,

  // Ruta optimizada
  rutaOptimizada,

  // Offline sync
  isOnline,
  guardarPedidoOffline,
  guardarMermaOffline
}) {
  const {
    setGuardando,
    setNuevoPedido,
    resetNuevoPedido,
    nuevoPedido,
    setBusqueda,
    setPaginaActual,

    // Modales
    modales,

    // Estados de edición
    setClienteEditando,
    setProductoEditando,
    setUsuarioEditando,
    setPedidoAsignando,
    setPedidoHistorial,
    setHistorialCambios,
    setPedidoEditando,
    setClienteFicha,
    setClientePago,
    setSaldoPendienteCliente,
    setProductoMerma,
    setCompraDetalle,
    setProveedorEditando,
    setCargandoHistorial,
    pedidoAsignando,
    pedidoEditando
  } = appState;

  // Handlers de búsqueda y filtros
  const handleBusquedaChange = useCallback((value) => {
    setBusqueda(value);
    setPaginaActual(1);
  }, [setBusqueda, setPaginaActual]);

  const handleFiltrosChange = useCallback((nuevosFiltros, filtros, setFiltros) => {
    setFiltros({ ...filtros, ...nuevosFiltros });
    setPaginaActual(1);
  }, [setPaginaActual]);

  // Handlers de Cliente
  const handleGuardarCliente = useCallback(async (cliente) => {
    setGuardando(true);
    try {
      if (cliente.id) await actualizarCliente(cliente.id, cliente);
      else await agregarCliente(cliente);
      modales.cliente.setOpen(false);
      setClienteEditando(null);
      notify.success(cliente.id ? 'Cliente actualizado correctamente' : 'Cliente creado correctamente');
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
    setGuardando(false);
  }, [agregarCliente, actualizarCliente, notify, modales.cliente, setClienteEditando, setGuardando]);

  const handleEliminarCliente = useCallback((id) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar cliente',
      mensaje: '¿Eliminar este cliente?',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await eliminarCliente(id);
          notify.success('Cliente eliminado', { persist: true });
        } catch (e) {
          notify.error(e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [eliminarCliente, notify, modales.confirm, setGuardando]);

  // Handlers de Producto
  const handleGuardarProducto = useCallback(async (producto) => {
    setGuardando(true);
    try {
      if (producto.id) await actualizarProducto(producto.id, producto);
      else await agregarProducto(producto);
      modales.producto.setOpen(false);
      setProductoEditando(null);
      notify.success(producto.id ? 'Producto actualizado correctamente' : 'Producto creado correctamente');
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
    setGuardando(false);
  }, [agregarProducto, actualizarProducto, notify, modales.producto, setProductoEditando, setGuardando]);

  const handleEliminarProducto = useCallback((id) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar producto',
      mensaje: '¿Eliminar este producto?',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await eliminarProducto(id);
          notify.success('Producto eliminado');
        } catch (e) {
          notify.error(e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [eliminarProducto, notify, modales.confirm, setGuardando]);

  // Handler de Usuario
  const handleGuardarUsuario = useCallback(async (usuario) => {
    setGuardando(true);
    try {
      await actualizarUsuario(usuario.id, usuario);
      modales.usuario.setOpen(false);
      setUsuarioEditando(null);
      notify.success('Usuario actualizado correctamente');
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
    setGuardando(false);
  }, [actualizarUsuario, notify, modales.usuario, setUsuarioEditando, setGuardando]);

  // Handlers de Pedido
  const agregarItemPedido = useCallback((productoId) => {
    const existe = nuevoPedido.items.find(i => i.productoId === productoId);
    const producto = productos.find(p => p.id === productoId);
    if (existe) {
      setNuevoPedido(prev => ({
        ...prev,
        items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i)
      }));
    } else {
      setNuevoPedido(prev => ({
        ...prev,
        items: [...prev.items, { productoId, cantidad: 1, precioUnitario: producto?.precio || 0 }]
      }));
    }
  }, [productos, nuevoPedido.items, setNuevoPedido]);

  const actualizarCantidadItem = useCallback((productoId, cantidad) => {
    if (cantidad <= 0) {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.filter(i => i.productoId !== productoId) }));
    } else {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad } : i) }));
    }
  }, [setNuevoPedido]);

  const handleClienteChange = useCallback((clienteId) => {
    setNuevoPedido(prev => ({ ...prev, clienteId }));
  }, [setNuevoPedido]);

  const handleNotasChange = useCallback((notas) => {
    setNuevoPedido(prev => ({ ...prev, notas }));
  }, [setNuevoPedido]);

  const handleFormaPagoChange = useCallback((formaPago) => {
    setNuevoPedido(prev => ({ ...prev, formaPago }));
  }, [setNuevoPedido]);

  const handleEstadoPagoChange = useCallback((estadoPago) => {
    setNuevoPedido(prev => ({ ...prev, estadoPago, montoPagado: estadoPago === 'parcial' ? prev.montoPagado : 0 }));
  }, [setNuevoPedido]);

  const handleMontoPagadoChange = useCallback((montoPagado) => {
    setNuevoPedido(prev => ({ ...prev, montoPagado }));
  }, [setNuevoPedido]);

  const handleCrearClienteEnPedido = useCallback(async (nuevoCliente) => {
    const cliente = await agregarCliente(nuevoCliente);
    notify.success('Cliente creado correctamente');
    return cliente;
  }, [agregarCliente, notify]);

  const handleGuardarPedidoConOffline = useCallback(async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos');
      return;
    }
    const validacion = validarStock(nuevoPedido.items);
    if (!validacion.valido) {
      notify.error(`Stock insuficiente:\n${validacion.errores.map(e => e.mensaje).join('\n')}`, 5000);
      return;
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
      });
      resetNuevoPedido();
      modales.pedido.setOpen(false);
      notify.warning('Sin conexión. Pedido guardado localmente y se sincronizará automáticamente.');
      return;
    }

    if (nuevoPedido.estadoPago === 'parcial' && (!nuevoPedido.montoPagado || nuevoPedido.montoPagado <= 0)) {
      notify.warning('Ingresá el monto del pago parcial');
      return;
    }

    setGuardando(true);
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
      );

      if (nuevoPedido.estadoPago === 'parcial' && nuevoPedido.montoPagado > 0 && pedidoCreado?.id) {
        await registrarPago({
          clienteId: parseInt(nuevoPedido.clienteId),
          pedidoId: pedidoCreado.id,
          monto: nuevoPedido.montoPagado,
          formaPago: nuevoPedido.formaPago,
          notas: 'Pago parcial al crear pedido',
          usuarioId: user.id
        });
      }

      resetNuevoPedido();
      modales.pedido.setOpen(false);
      refetchProductos();
      refetchMetricas();
      notify.success('Pedido creado correctamente', { persist: true });
    } catch (e) {
      notify.error('Error al crear pedido: ' + e.message);
    }
    setGuardando(false);
  }, [nuevoPedido, validarStock, isOnline, guardarPedidoOffline, user, resetNuevoPedido, modales.pedido, crearPedido, descontarStock, registrarPago, refetchProductos, refetchMetricas, notify, setGuardando]);

  const handleMarcarEntregado = useCallback((pedido) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Confirmar entrega',
      mensaje: `¿Confirmar entrega del pedido #${pedido.id}?`,
      tipo: 'success',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await cambiarEstado(pedido.id, 'entregado');
          refetchMetricas();
          notify.success(`Pedido #${pedido.id} marcado como entregado`, { persist: true });
        } catch (e) {
          notify.error(e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando]);

  const handleDesmarcarEntregado = useCallback((pedido) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Revertir entrega',
      mensaje: `¿Revertir entrega del pedido #${pedido.id}?`,
      tipo: 'warning',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await cambiarEstado(pedido.id, pedido.transportista_id ? 'asignado' : 'pendiente');
          refetchMetricas();
          notify.warning(`Pedido #${pedido.id} revertido`);
        } catch (e) {
          notify.error(e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando]);

  const handleMarcarEnPreparacion = useCallback((pedido) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Marcar en preparación',
      mensaje: `¿Marcar pedido #${pedido.id} como "En preparación"?`,
      tipo: 'success',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await cambiarEstado(pedido.id, 'en_preparacion');
          refetchMetricas();
          notify.success(`Pedido #${pedido.id} marcado como en preparación`);
        } catch (e) {
          notify.error(e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [cambiarEstado, refetchMetricas, notify, modales.confirm, setGuardando]);

  const handleAsignarTransportista = useCallback(async (transportistaId, marcarListo = false) => {
    if (!pedidoAsignando) return;
    setGuardando(true);
    try {
      await asignarTransportista(pedidoAsignando.id, transportistaId || null, marcarListo);
      modales.asignar.setOpen(false);
      setPedidoAsignando(null);
      if (transportistaId) {
        notify.success(marcarListo ? 'Transportista asignado y pedido listo para entregar' : 'Transportista asignado (el pedido mantiene su estado actual)');
      } else {
        notify.success('Transportista desasignado');
      }
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
    setGuardando(false);
  }, [pedidoAsignando, asignarTransportista, modales.asignar, setPedidoAsignando, notify, setGuardando]);

  const handleEliminarPedido = useCallback((id) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar pedido',
      mensaje: '¿Eliminar este pedido? El stock será restaurado y quedará registrado en el historial.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await eliminarPedido(id, restaurarStock, user?.id);
          refetchProductos();
          refetchMetricas();
          notify.success('Pedido eliminado y registrado en historial');
        } catch (e) {
          notify.error(e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [eliminarPedido, restaurarStock, user, refetchProductos, refetchMetricas, notify, modales.confirm, setGuardando]);

  const handleVerHistorial = useCallback(async (pedido) => {
    setPedidoHistorial(pedido);
    modales.historial.setOpen(true);
    setCargandoHistorial(true);
    try {
      const historial = await fetchHistorialPedido(pedido.id);
      setHistorialCambios(historial);
    } catch (e) {
      notify.error('Error al cargar historial: ' + e.message);
      setHistorialCambios([]);
    } finally {
      setCargandoHistorial(false);
    }
  }, [fetchHistorialPedido, setPedidoHistorial, modales.historial, setCargandoHistorial, setHistorialCambios, notify]);

  const handleEditarPedido = useCallback((pedido) => {
    setPedidoEditando(pedido);
    modales.editarPedido.setOpen(true);
  }, [setPedidoEditando, modales.editarPedido]);

  const handleGuardarEdicionPedido = useCallback(async ({ notas, formaPago, estadoPago, montoPagado }) => {
    if (!pedidoEditando) return;
    setGuardando(true);
    try {
      await actualizarNotasPedido(pedidoEditando.id, notas);
      await actualizarFormaPago(pedidoEditando.id, formaPago);
      await actualizarEstadoPago(pedidoEditando.id, estadoPago, montoPagado);
      modales.editarPedido.setOpen(false);
      setPedidoEditando(null);
      notify.success('Pedido actualizado correctamente');
    } catch (e) {
      notify.error('Error al actualizar pedido: ' + e.message);
    }
    setGuardando(false);
  }, [pedidoEditando, actualizarNotasPedido, actualizarFormaPago, actualizarEstadoPago, modales.editarPedido, setPedidoEditando, notify, setGuardando]);

  const handleAplicarOrdenOptimizado = useCallback(async (data) => {
    setGuardando(true);
    try {
      const ordenOptimizado = Array.isArray(data) ? data : data.ordenOptimizado;
      const transportistaId = data.transportistaId || null;
      const distancia = data.distancia || null;
      const duracion = data.duracion || null;

      await actualizarOrdenEntrega(ordenOptimizado);

      if (transportistaId && ordenOptimizado?.length > 0) {
        try {
          await crearRecorrido(transportistaId, ordenOptimizado, distancia, duracion);
          notify.success('Ruta optimizada y recorrido creado correctamente');
        } catch (recorridoError) {
          notify.success('Orden de entrega actualizado (sin registro de recorrido)');
        }
      } else {
        notify.success('Orden de entrega actualizado correctamente');
      }

      modales.optimizarRuta.setOpen(false);
      limpiarRuta();
      refetchPedidos();
    } catch (e) {
      notify.error('Error al actualizar orden: ' + e.message);
    }
    setGuardando(false);
  }, [actualizarOrdenEntrega, crearRecorrido, limpiarRuta, refetchPedidos, modales.optimizarRuta, notify, setGuardando]);

  const handleExportarHojaRutaOptimizada = useCallback((transportista, pedidosOrdenados) => {
    try {
      generarHojaRutaOptimizada(transportista, pedidosOrdenados, rutaOptimizada || {});
      notify.success('PDF generado correctamente');
    } catch (e) {
      notify.error('Error al generar PDF: ' + e.message);
    }
  }, [rutaOptimizada, notify]);

  const handleCerrarModalOptimizar = useCallback(() => {
    modales.optimizarRuta.setOpen(false);
    limpiarRuta();
  }, [modales.optimizarRuta, limpiarRuta]);

  // Handlers para ficha de cliente y pagos
  const handleVerFichaCliente = useCallback(async (cliente) => {
    setClienteFicha(cliente);
    modales.fichaCliente.setOpen(true);
    const resumen = await obtenerResumenCuenta(cliente.id);
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0);
    }
  }, [obtenerResumenCuenta, setClienteFicha, modales.fichaCliente, setSaldoPendienteCliente]);

  const handleAbrirRegistrarPago = useCallback(async (cliente) => {
    setClientePago(cliente);
    const resumen = await obtenerResumenCuenta(cliente.id);
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0);
    }
    modales.registrarPago.setOpen(true);
    modales.fichaCliente.setOpen(false);
  }, [obtenerResumenCuenta, setClientePago, setSaldoPendienteCliente, modales.registrarPago, modales.fichaCliente]);

  const handleRegistrarPago = useCallback(async (datosPago) => {
    try {
      const pago = await registrarPago({
        ...datosPago,
        usuarioId: user.id
      });
      notify.success('Pago registrado correctamente');
      return pago;
    } catch (e) {
      notify.error('Error al registrar pago: ' + e.message);
      throw e;
    }
  }, [registrarPago, user, notify]);

  const handleGenerarReciboPago = useCallback((pago, cliente) => {
    try {
      generarReciboPago(pago, cliente);
      notify.success('Recibo generado correctamente');
    } catch (e) {
      notify.error('Error al generar recibo: ' + e.message);
    }
  }, [notify]);

  // Handlers de Mermas
  const handleAbrirMerma = useCallback((producto) => {
    setProductoMerma(producto);
    modales.mermaStock.setOpen(true);
  }, [setProductoMerma, modales.mermaStock]);

  const handleRegistrarMerma = useCallback(async (mermaData) => {
    try {
      if (!isOnline) {
        guardarMermaOffline({
          ...mermaData,
          usuarioId: user?.id
        });
        await actualizarProducto(mermaData.productoId, { stock: mermaData.stockNuevo });
        notify.warning('Merma guardada localmente. Se sincronizará cuando vuelva la conexión.');
        refetchProductos();
        return;
      }

      await registrarMerma({
        ...mermaData,
        usuarioId: user?.id
      });
      notify.success('Merma registrada correctamente');
      refetchProductos();
      refetchMermas();
    } catch (e) {
      notify.error('Error al registrar merma: ' + e.message);
      throw e;
    }
  }, [isOnline, guardarMermaOffline, actualizarProducto, registrarMerma, user, refetchProductos, refetchMermas, notify]);

  const handleVerHistorialMermas = useCallback(() => {
    modales.historialMermas.setOpen(true);
  }, [modales.historialMermas]);

  // Handlers de Compras
  const handleNuevaCompra = useCallback(() => {
    modales.compra.setOpen(true);
  }, [modales.compra]);

  const handleRegistrarCompra = useCallback(async (compraData) => {
    try {
      await registrarCompra({
        ...compraData,
        usuarioId: user?.id
      });
      notify.success('Compra registrada correctamente. Stock actualizado.');
      refetchProductos();
      refetchCompras();
    } catch (e) {
      notify.error('Error al registrar compra: ' + e.message);
      throw e;
    }
  }, [registrarCompra, user, refetchProductos, refetchCompras, notify]);

  const handleVerDetalleCompra = useCallback((compra) => {
    setCompraDetalle(compra);
    modales.detalleCompra.setOpen(true);
  }, [setCompraDetalle, modales.detalleCompra]);

  const handleAnularCompra = useCallback((compraId) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Anular compra',
      mensaje: '¿Anular esta compra? El stock será revertido.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await anularCompra(compraId);
          notify.success('Compra anulada y stock revertido');
          refetchProductos();
          refetchCompras();
          modales.detalleCompra.setOpen(false);
          setCompraDetalle(null);
        } catch (e) {
          notify.error('Error al anular compra: ' + e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [anularCompra, refetchProductos, refetchCompras, modales.confirm, modales.detalleCompra, setCompraDetalle, notify, setGuardando]);

  // Handlers de Proveedores
  const handleNuevoProveedor = useCallback(() => {
    setProveedorEditando(null);
    modales.proveedor.setOpen(true);
  }, [setProveedorEditando, modales.proveedor]);

  const handleEditarProveedor = useCallback((proveedor) => {
    setProveedorEditando(proveedor);
    modales.proveedor.setOpen(true);
  }, [setProveedorEditando, modales.proveedor]);

  const handleGuardarProveedor = useCallback(async (proveedor) => {
    setGuardando(true);
    try {
      if (proveedor.id) {
        await actualizarProveedor(proveedor.id, proveedor);
        notify.success('Proveedor actualizado correctamente');
      } else {
        await agregarProveedor(proveedor);
        notify.success('Proveedor creado correctamente');
      }
      modales.proveedor.setOpen(false);
      setProveedorEditando(null);
      refetchProveedores();
    } catch (e) {
      notify.error('Error: ' + e.message);
    } finally {
      setGuardando(false);
    }
  }, [actualizarProveedor, agregarProveedor, modales.proveedor, setProveedorEditando, refetchProveedores, notify, setGuardando]);

  const handleToggleActivoProveedor = useCallback(async (proveedor) => {
    const nuevoEstado = proveedor.activo === false;
    try {
      await actualizarProveedor(proveedor.id, { ...proveedor, activo: nuevoEstado });
      notify.success(nuevoEstado ? 'Proveedor activado' : 'Proveedor desactivado');
      refetchProveedores();
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
  }, [actualizarProveedor, refetchProveedores, notify]);

  const handleEliminarProveedor = useCallback((id) => {
    modales.confirm.setConfig({
      visible: true,
      titulo: 'Eliminar proveedor',
      mensaje: '¿Eliminar este proveedor? Esta acción no se puede deshacer.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true);
        try {
          const proveedor = proveedores.find(p => p.id === id);
          if (proveedor) {
            await actualizarProveedor(id, { ...proveedor, activo: false });
            notify.success('Proveedor eliminado');
            refetchProveedores();
          }
        } catch (e) {
          notify.error('Error: ' + e.message);
        } finally {
          setGuardando(false);
          modales.confirm.setConfig({ visible: false });
        }
      }
    });
  }, [proveedores, actualizarProveedor, refetchProveedores, modales.confirm, notify, setGuardando]);

  return {
    // Búsqueda y filtros
    handleBusquedaChange,
    handleFiltrosChange,

    // Clientes
    handleGuardarCliente,
    handleEliminarCliente,
    handleVerFichaCliente,
    handleAbrirRegistrarPago,
    handleRegistrarPago,
    handleGenerarReciboPago,

    // Productos
    handleGuardarProducto,
    handleEliminarProducto,
    handleAbrirMerma,
    handleRegistrarMerma,
    handleVerHistorialMermas,

    // Usuarios
    handleGuardarUsuario,

    // Pedidos
    agregarItemPedido,
    actualizarCantidadItem,
    handleClienteChange,
    handleNotasChange,
    handleFormaPagoChange,
    handleEstadoPagoChange,
    handleMontoPagadoChange,
    handleCrearClienteEnPedido,
    handleGuardarPedidoConOffline,
    handleMarcarEntregado,
    handleDesmarcarEntregado,
    handleMarcarEnPreparacion,
    handleAsignarTransportista,
    handleEliminarPedido,
    handleVerHistorial,
    handleEditarPedido,
    handleGuardarEdicionPedido,

    // Rutas
    handleAplicarOrdenOptimizado,
    handleExportarHojaRutaOptimizada,
    handleCerrarModalOptimizar,

    // Compras
    handleNuevaCompra,
    handleRegistrarCompra,
    handleVerDetalleCompra,
    handleAnularCompra,

    // Proveedores
    handleNuevoProveedor,
    handleEditarProveedor,
    handleGuardarProveedor,
    handleToggleActivoProveedor,
    handleEliminarProveedor,

    // PDF Export helpers
    generarOrdenPreparacion,
    generarHojaRuta
  };
}
