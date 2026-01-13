import React, { useState, useMemo, useCallback, useEffect, lazy, Suspense } from 'react';
import { Loader2 } from 'lucide-react';
import { AuthProvider, useAuth, useClientes, useProductos, usePedidos, useUsuarios, useDashboard, useBackup, usePagos, useMermas, useCompras, useRecorridos, setErrorNotifier } from './hooks/supabase';
import { ThemeProvider } from './contexts/ThemeContext';
import { NotificationProvider, useNotification } from './contexts/NotificationContext';
import { ModalConfirmacion, ModalFiltroFecha, ModalCliente, ModalProducto, ModalUsuario, ModalAsignarTransportista, ModalPedido, ModalHistorialPedido, ModalEditarPedido, ModalExportarPDF, ModalGestionRutas } from './components/Modals.jsx';
import ModalFichaCliente from './components/modals/ModalFichaCliente.jsx';
import ModalRegistrarPago from './components/modals/ModalRegistrarPago.jsx';
import ModalMermaStock from './components/modals/ModalMermaStock.jsx';
import ModalHistorialMermas from './components/modals/ModalHistorialMermas.jsx';
import ModalCompra from './components/modals/ModalCompra.jsx';
import ModalDetalleCompra from './components/modals/ModalDetalleCompra.jsx';
import ModalProveedor from './components/modals/ModalProveedor.jsx';
import ModalImportarPrecios from './components/modals/ModalImportarPrecios.jsx';
import ModalPedidosEliminados from './components/modals/ModalPedidosEliminados.jsx';
import OfflineIndicator from './components/layout/OfflineIndicator.jsx';
import { generarOrdenPreparacion, generarHojaRuta, generarHojaRutaOptimizada, generarReciboPago } from './lib/pdfExport.js';
import { useOptimizarRuta } from './hooks/useOptimizarRuta.js';
import { useOfflineSync } from './hooks/useOfflineSync.js';
import { ITEMS_PER_PAGE } from './utils/formatters';

// Componentes base
import LoginScreen from './components/auth/LoginScreen';
import ErrorBoundary from './components/ErrorBoundary';
import TopNavigation from './components/layout/TopNavigation';

// Vistas con lazy loading
const VistaDashboard = lazy(() => import('./components/vistas/VistaDashboard'));
const VistaPedidos = lazy(() => import('./components/vistas/VistaPedidos'));
const VistaClientes = lazy(() => import('./components/vistas/VistaClientes'));
const VistaProductos = lazy(() => import('./components/vistas/VistaProductos'));
const VistaReportes = lazy(() => import('./components/vistas/VistaReportes'));
const VistaUsuarios = lazy(() => import('./components/vistas/VistaUsuarios'));
const VistaRecorridos = lazy(() => import('./components/vistas/VistaRecorridos'));
const VistaCompras = lazy(() => import('./components/vistas/VistaCompras'));
const VistaProveedores = lazy(() => import('./components/vistas/VistaProveedores'));

// Componente de carga para Suspense
function LoadingVista() {
  return (
    <div className="flex items-center justify-center py-20">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
    </div>
  );
}

function MainApp() {
  const { user, perfil, logout, isAdmin, isPreventista, isTransportista } = useAuth();
  const notify = useNotification();
  const [vista, setVista] = useState(perfil?.rol === 'admin' ? 'dashboard' : 'pedidos');

  // Configurar el notificador de errores centralizado
  useEffect(() => {
    setErrorNotifier((message) => {
      notify.error(message);
    });
  }, [notify]);

  // Hooks de datos
  const { clientes, agregarCliente, actualizarCliente, eliminarCliente, loading: loadingClientes } = useClientes();
  const { productos, agregarProducto, actualizarProducto, eliminarProducto, validarStock, descontarStock, restaurarStock, actualizarPreciosMasivo, loading: loadingProductos, refetch: refetchProductos } = useProductos();
  const { pedidos, pedidosFiltrados, crearPedido, cambiarEstado, asignarTransportista, eliminarPedido, actualizarNotasPedido, actualizarEstadoPago, actualizarFormaPago, actualizarOrdenEntrega, actualizarItemsPedido, fetchHistorialPedido, fetchPedidosEliminados, filtros, setFiltros, loading: loadingPedidos, refetch: refetchPedidos } = usePedidos();
  const { usuarios, transportistas, actualizarUsuario, loading: loadingUsuarios } = useUsuarios();
  // Para preventistas, filtrar métricas por sus propios pedidos
  const dashboardUsuarioId = isPreventista && !isAdmin ? user?.id : null;
  const { metricas, reportePreventistas, reporteInicializado, calcularReportePreventistas, loading: loadingMetricas, loadingReporte, refetch: refetchMetricas, filtroPeriodo, cambiarPeriodo } = useDashboard(dashboardUsuarioId);
  const { exportando, descargarJSON, exportarPedidosExcel } = useBackup();
  const { loading: loadingOptimizacion, rutaOptimizada, error: errorOptimizacion, optimizarRuta, limpiarRuta } = useOptimizarRuta();
  const { registrarPago, obtenerResumenCuenta } = usePagos();
  const { mermas, registrarMerma, refetch: refetchMermas } = useMermas();
  const { compras, proveedores, registrarCompra, anularCompra, agregarProveedor, actualizarProveedor, loading: loadingCompras, refetch: refetchCompras, refetchProveedores } = useCompras();
  const { recorridos, loading: loadingRecorridos, fetchRecorridosHoy, fetchRecorridosPorFecha, crearRecorrido, getEstadisticasRecorridos } = useRecorridos();
  const { isOnline, pedidosPendientes, mermasPendientes, sincronizando, guardarPedidoOffline, guardarMermaOffline, sincronizarPedidos, sincronizarMermas } = useOfflineSync();

  // Estado para recorridos
  const [fechaRecorridos, setFechaRecorridos] = useState(() => new Date().toISOString().split('T')[0]);
  const [estadisticasRecorridos, setEstadisticasRecorridos] = useState(null);

  // Cargar recorridos cuando se cambia a la vista de recorridos
  useEffect(() => {
    if (vista === 'recorridos' && isAdmin) {
      const hoy = new Date().toISOString().split('T')[0];
      if (fechaRecorridos === hoy) {
        fetchRecorridosHoy();
      } else {
        fetchRecorridosPorFecha(fechaRecorridos);
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vista, fechaRecorridos]);

  // Estados de modales
  const [modalCliente, setModalCliente] = useState(false);
  const [modalProducto, setModalProducto] = useState(false);
  const [modalPedido, setModalPedido] = useState(false);
  const [modalUsuario, setModalUsuario] = useState(false);
  const [modalAsignar, setModalAsignar] = useState(false);
  const [modalConfirm, setModalConfirm] = useState({ visible: false });
  const [modalFiltroFecha, setModalFiltroFecha] = useState(false);
  const [modalHistorial, setModalHistorial] = useState(false);
  const [modalEditarPedido, setModalEditarPedido] = useState(false);
  const [modalExportarPDF, setModalExportarPDF] = useState(false);
  const [modalOptimizarRuta, setModalOptimizarRuta] = useState(false);
  const [modalFichaCliente, setModalFichaCliente] = useState(false);
  const [modalRegistrarPago, setModalRegistrarPago] = useState(false);
  const [modalMermaStock, setModalMermaStock] = useState(false);
  const [modalHistorialMermas, setModalHistorialMermas] = useState(false);
  const [productoMerma, setProductoMerma] = useState(null);
  const [modalCompra, setModalCompra] = useState(false);
  const [modalDetalleCompra, setModalDetalleCompra] = useState(false);
  const [compraDetalle, setCompraDetalle] = useState(null);
  const [modalProveedor, setModalProveedor] = useState(false);
  const [proveedorEditando, setProveedorEditando] = useState(null);
  const [modalImportarPrecios, setModalImportarPrecios] = useState(false);
  const [modalPedidosEliminados, setModalPedidosEliminados] = useState(false);

  // Estados de edición
  const [clienteEditando, setClienteEditando] = useState(null);
  const [productoEditando, setProductoEditando] = useState(null);
  const [usuarioEditando, setUsuarioEditando] = useState(null);
  const [pedidoAsignando, setPedidoAsignando] = useState(null);
  const [pedidoHistorial, setPedidoHistorial] = useState(null);
  const [historialCambios, setHistorialCambios] = useState([]);
  const [pedidoEditando, setPedidoEditando] = useState(null);
  const [clienteFicha, setClienteFicha] = useState(null);
  const [clientePago, setClientePago] = useState(null);
  const [saldoPendienteCliente, setSaldoPendienteCliente] = useState(0);

  // Estados del formulario de pedido
  const [nuevoPedido, setNuevoPedido] = useState({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0 });
  const [busqueda, setBusqueda] = useState('');
  const [guardando, setGuardando] = useState(false);
  const [cargandoHistorial, setCargandoHistorial] = useState(false);

  // Paginación
  const [paginaActual, setPaginaActual] = useState(1);

  // Categorías únicas
  const categorias = useMemo(() => {
    const cats = productos.map(p => p.categoria).filter(Boolean);
    return [...new Set(cats)].sort();
  }, [productos]);

  const handleLogout = async () => {
    try { await logout(); } catch (e) { /* error silenciado */ }
  };

  const calcularTotalPedido = (items) => items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);

  // Filtrado y paginación de pedidos
  const pedidosParaMostrar = useMemo(() => {
    return pedidosFiltrados().filter(p =>
      !busqueda ||
      p.cliente?.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase()) ||
      p.cliente?.direccion?.toLowerCase().includes(busqueda.toLowerCase()) ||
      p.id.toString().includes(busqueda)
    );
  }, [pedidosFiltrados, busqueda, filtros]);

  const totalPaginas = Math.ceil(pedidosParaMostrar.length / ITEMS_PER_PAGE);
  const pedidosPaginados = useMemo(() => {
    const inicio = (paginaActual - 1) * ITEMS_PER_PAGE;
    return pedidosParaMostrar.slice(inicio, inicio + ITEMS_PER_PAGE);
  }, [pedidosParaMostrar, paginaActual]);

  const handleBusquedaChange = (value) => {
    setBusqueda(value);
    setPaginaActual(1);
  };

  const handleFiltrosChange = (nuevosFiltros) => {
    setFiltros({ ...filtros, ...nuevosFiltros });
    setPaginaActual(1);
  };

  // Handlers de Cliente
  const handleGuardarCliente = async (cliente) => {
    setGuardando(true);
    try {
      if (cliente.id) await actualizarCliente(cliente.id, cliente);
      else await agregarCliente(cliente);
      setModalCliente(false);
      setClienteEditando(null);
      notify.success(cliente.id ? 'Cliente actualizado correctamente' : 'Cliente creado correctamente');
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
    setGuardando(false);
  };

  const handleEliminarCliente = (id) => {
    setModalConfirm({
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
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  // Handlers de Producto
  const handleGuardarProducto = async (producto) => {
    setGuardando(true);
    try {
      if (producto.id) await actualizarProducto(producto.id, producto);
      else await agregarProducto(producto);
      setModalProducto(false);
      setProductoEditando(null);
      notify.success(producto.id ? 'Producto actualizado correctamente' : 'Producto creado correctamente');
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
    setGuardando(false);
  };

  const handleEliminarProducto = (id) => {
    setModalConfirm({
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
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  // Handler de Usuario
  const handleGuardarUsuario = async (usuario) => {
    setGuardando(true);
    try {
      await actualizarUsuario(usuario.id, usuario);
      setModalUsuario(false);
      setUsuarioEditando(null);
      notify.success('Usuario actualizado correctamente');
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
    setGuardando(false);
  };

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
  }, [productos, nuevoPedido.items]);

  const actualizarCantidadItem = useCallback((productoId, cantidad) => {
    if (cantidad <= 0) {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.filter(i => i.productoId !== productoId) }));
    } else {
      setNuevoPedido(prev => ({ ...prev, items: prev.items.map(i => i.productoId === productoId ? { ...i, cantidad } : i) }));
    }
  }, []);

  const handleClienteChange = useCallback((clienteId) => {
    setNuevoPedido(prev => ({ ...prev, clienteId }));
  }, []);

  const handleNotasChange = useCallback((notas) => {
    setNuevoPedido(prev => ({ ...prev, notas }));
  }, []);

  const handleFormaPagoChange = useCallback((formaPago) => {
    setNuevoPedido(prev => ({ ...prev, formaPago }));
  }, []);

  const handleEstadoPagoChange = useCallback((estadoPago) => {
    setNuevoPedido(prev => ({ ...prev, estadoPago, montoPagado: estadoPago === 'parcial' ? prev.montoPagado : 0 }));
  }, []);

  const handleMontoPagadoChange = useCallback((montoPagado) => {
    setNuevoPedido(prev => ({ ...prev, montoPagado }));
  }, []);

  const handleCrearClienteEnPedido = useCallback(async (nuevoCliente) => {
    const cliente = await agregarCliente(nuevoCliente);
    notify.success('Cliente creado correctamente');
    return cliente;
  }, [agregarCliente, notify]);

  const handleGuardarPedido = async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      notify.warning('Seleccioná cliente y productos');
      return;
    }
    const validacion = validarStock(nuevoPedido.items);
    if (!validacion.valido) {
      notify.error(`Stock insuficiente:\n${validacion.errores.map(e => e.mensaje).join('\n')}`, 5000);
      return;
    }
    setGuardando(true);
    try {
      await crearPedido(
        parseInt(nuevoPedido.clienteId),
        nuevoPedido.items,
        calcularTotalPedido(nuevoPedido.items),
        user.id,
        descontarStock,
        nuevoPedido.notas,
        nuevoPedido.formaPago,
        nuevoPedido.estadoPago
      );
      setNuevoPedido({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0 });
      setModalPedido(false);
      refetchProductos();
      refetchMetricas();
      notify.success('Pedido creado correctamente', { persist: true });
    } catch (e) {
      notify.error('Error al crear pedido: ' + e.message);
    }
    setGuardando(false);
  };

  const handleMarcarEntregado = (pedido) => {
    setModalConfirm({
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
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  const handleDesmarcarEntregado = (pedido) => {
    setModalConfirm({
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
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  const handleMarcarEnPreparacion = (pedido) => {
    setModalConfirm({
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
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  const handleAsignarTransportista = async (transportistaId, marcarListo = false) => {
    if (!pedidoAsignando) return;
    setGuardando(true);
    try {
      await asignarTransportista(pedidoAsignando.id, transportistaId || null, marcarListo);
      setModalAsignar(false);
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
  };

  const handleEliminarPedido = (id) => {
    setModalConfirm({
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
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  const handleVerHistorial = async (pedido) => {
    setPedidoHistorial(pedido);
    setModalHistorial(true);
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
  };

  const handleEditarPedido = (pedido) => {
    setPedidoEditando(pedido);
    setModalEditarPedido(true);
  };

  const handleGuardarEdicionPedido = async ({ notas, formaPago, estadoPago, montoPagado }) => {
    if (!pedidoEditando) return;
    setGuardando(true);
    try {
      await actualizarNotasPedido(pedidoEditando.id, notas);
      await actualizarFormaPago(pedidoEditando.id, formaPago);
      await actualizarEstadoPago(pedidoEditando.id, estadoPago, montoPagado);
      setModalEditarPedido(false);
      setPedidoEditando(null);
      notify.success('Pedido actualizado correctamente');
    } catch (e) {
      notify.error('Error al actualizar pedido: ' + e.message);
    }
    setGuardando(false);
  };

  const handleAplicarOrdenOptimizado = async (data) => {
    setGuardando(true);
    try {
      // Soportar tanto el formato nuevo (objeto) como el antiguo (array)
      const ordenOptimizado = Array.isArray(data) ? data : data.ordenOptimizado;
      const transportistaId = data.transportistaId || null;
      const distancia = data.distancia || null;
      const duracion = data.duracion || null;

      await actualizarOrdenEntrega(ordenOptimizado);

      // Crear recorrido si tenemos transportista
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

      setModalOptimizarRuta(false);
      limpiarRuta();
      refetchPedidos();
    } catch (e) {
      notify.error('Error al actualizar orden: ' + e.message);
    }
    setGuardando(false);
  };

  const handleExportarHojaRutaOptimizada = (transportista, pedidosOrdenados) => {
    try {
      generarHojaRutaOptimizada(transportista, pedidosOrdenados, rutaOptimizada || {});
      notify.success('PDF generado correctamente');
    } catch (e) {
      notify.error('Error al generar PDF: ' + e.message);
    }
  };

  const handleCerrarModalOptimizar = () => {
    setModalOptimizarRuta(false);
    limpiarRuta();
  };

  // Handlers para ficha de cliente y pagos
  const handleVerFichaCliente = async (cliente) => {
    setClienteFicha(cliente);
    setModalFichaCliente(true);
    // Obtener saldo pendiente
    const resumen = await obtenerResumenCuenta(cliente.id);
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0);
    }
  };

  const handleAbrirRegistrarPago = async (cliente) => {
    setClientePago(cliente);
    // Obtener saldo pendiente
    const resumen = await obtenerResumenCuenta(cliente.id);
    if (resumen) {
      setSaldoPendienteCliente(resumen.saldo_actual || 0);
    }
    setModalRegistrarPago(true);
    setModalFichaCliente(false);
  };

  const handleRegistrarPago = async (datosPago) => {
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
  };

  const handleGenerarReciboPago = (pago, cliente) => {
    try {
      generarReciboPago(pago, cliente);
      notify.success('Recibo generado correctamente');
    } catch (e) {
      notify.error('Error al generar recibo: ' + e.message);
    }
  };

  // Handlers de Mermas
  const handleAbrirMerma = (producto) => {
    setProductoMerma(producto);
    setModalMermaStock(true);
  };

  const handleRegistrarMerma = async (mermaData) => {
    try {
      if (!isOnline) {
        // Guardar offline
        guardarMermaOffline({
          ...mermaData,
          usuarioId: user?.id
        });
        // Actualizar stock localmente
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
  };

  const handleVerHistorialMermas = () => {
    setModalHistorialMermas(true);
  };

  // Handlers de Compras
  const handleNuevaCompra = () => {
    setModalCompra(true);
  };

  const handleRegistrarCompra = async (compraData) => {
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
  };

  const handleVerDetalleCompra = (compra) => {
    setCompraDetalle(compra);
    setModalDetalleCompra(true);
  };

  const handleAnularCompra = (compraId) => {
    setModalConfirm({
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
          setModalDetalleCompra(false);
          setCompraDetalle(null);
        } catch (e) {
          notify.error('Error al anular compra: ' + e.message);
        } finally {
          setGuardando(false);
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  // Handlers de Proveedores
  const handleNuevoProveedor = () => {
    setProveedorEditando(null);
    setModalProveedor(true);
  };

  const handleEditarProveedor = (proveedor) => {
    setProveedorEditando(proveedor);
    setModalProveedor(true);
  };

  const handleGuardarProveedor = async (proveedor) => {
    setGuardando(true);
    try {
      if (proveedor.id) {
        await actualizarProveedor(proveedor.id, proveedor);
        notify.success('Proveedor actualizado correctamente');
      } else {
        await agregarProveedor(proveedor);
        notify.success('Proveedor creado correctamente');
      }
      setModalProveedor(false);
      setProveedorEditando(null);
      refetchProveedores();
    } catch (e) {
      notify.error('Error: ' + e.message);
    } finally {
      setGuardando(false);
    }
  };

  const handleToggleActivoProveedor = async (proveedor) => {
    const nuevoEstado = proveedor.activo === false;
    try {
      await actualizarProveedor(proveedor.id, { ...proveedor, activo: nuevoEstado });
      notify.success(nuevoEstado ? 'Proveedor activado' : 'Proveedor desactivado');
      refetchProveedores();
    } catch (e) {
      notify.error('Error: ' + e.message);
    }
  };

  const handleEliminarProveedor = (id) => {
    setModalConfirm({
      visible: true,
      titulo: 'Eliminar proveedor',
      mensaje: '¿Eliminar este proveedor? Esta acción no se puede deshacer.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true);
        try {
          // Por ahora solo desactivamos (soft delete)
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
          setModalConfirm({ visible: false });
        }
      }
    });
  };

  // Sincronización offline
  const handleSincronizar = async () => {
    try {
      // Sincronizar pedidos
      if (pedidosPendientes.length > 0) {
        const resultadoPedidos = await sincronizarPedidos(crearPedido, descontarStock);
        if (resultadoPedidos.sincronizados > 0) {
          notify.success(`${resultadoPedidos.sincronizados} pedido(s) sincronizado(s)`);
          refetchPedidos();
          refetchProductos();
        }
        if (resultadoPedidos.errores.length > 0) {
          notify.error(`${resultadoPedidos.errores.length} pedido(s) no se pudieron sincronizar`);
        }
      }

      // Sincronizar mermas
      if (mermasPendientes.length > 0) {
        const resultadoMermas = await sincronizarMermas(registrarMerma);
        if (resultadoMermas.sincronizados > 0) {
          notify.success(`${resultadoMermas.sincronizados} merma(s) sincronizada(s)`);
          refetchMermas();
        }
      }
    } catch (e) {
      notify.error('Error durante la sincronización: ' + e.message);
    }
  };

  // Auto-sincronizar cuando vuelve la conexión
  useEffect(() => {
    if (isOnline && (pedidosPendientes.length > 0 || mermasPendientes.length > 0)) {
      handleSincronizar();
    }
  }, [isOnline]);

  // Handler para crear pedido con soporte offline
  const handleGuardarPedidoConOffline = async () => {
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
      // Guardar pedido offline
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
      setNuevoPedido({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0 });
      setModalPedido(false);
      notify.warning('Sin conexión. Pedido guardado localmente y se sincronizará automáticamente.');
      return;
    }

    // Validar monto pagado si es pago parcial
    if (nuevoPedido.estadoPago === 'parcial' && (!nuevoPedido.montoPagado || nuevoPedido.montoPagado <= 0)) {
      notify.warning('Ingresá el monto del pago parcial');
      return;
    }

    // Crear pedido normal (online)
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

      // Registrar pago si es parcial
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

      setNuevoPedido({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0 });
      setModalPedido(false);
      refetchProductos();
      refetchMetricas();
      notify.success('Pedido creado correctamente', { persist: true });
    } catch (e) {
      notify.error('Error al crear pedido: ' + e.message);
    }
    setGuardando(false);
  };

  return (
    <div className="min-h-screen bg-gray-100 dark:bg-gray-900 transition-colors">
      <TopNavigation
        vista={vista}
        setVista={setVista}
        perfil={perfil}
        onLogout={handleLogout}
      />

      <main className="pt-20 pb-6 px-4">
        <div className="max-w-7xl mx-auto">
        <Suspense fallback={<LoadingVista />}>
        {vista === 'dashboard' && (isAdmin || isPreventista) && (
          <VistaDashboard
            metricas={metricas}
            loading={loadingMetricas}
            filtroPeriodo={filtroPeriodo}
            onCambiarPeriodo={cambiarPeriodo}
            onRefetch={refetchMetricas}
            onDescargarBackup={descargarJSON}
            exportando={exportando}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            totalClientes={clientes.length}
          />
        )}

        {vista === 'pedidos' && (
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
            userId={user?.id}
            clientes={clientes}
            productos={productos}
            transportistas={transportistas}
            loading={loadingPedidos}
            exportando={exportando}
            onBusquedaChange={handleBusquedaChange}
            onFiltrosChange={handleFiltrosChange}
            onPageChange={setPaginaActual}
            onNuevoPedido={() => setModalPedido(true)}
            onOptimizarRuta={() => setModalOptimizarRuta(true)}
            onExportarPDF={() => setModalExportarPDF(true)}
            onExportarExcel={() => exportarPedidosExcel(pedidosParaMostrar, { ...filtros, busqueda }, transportistas)}
            onModalFiltroFecha={() => setModalFiltroFecha(true)}
            onVerHistorial={handleVerHistorial}
            onEditarPedido={handleEditarPedido}
            onMarcarEnPreparacion={handleMarcarEnPreparacion}
            onAsignarTransportista={(pedido) => { setPedidoAsignando(pedido); setModalAsignar(true); }}
            onMarcarEntregado={handleMarcarEntregado}
            onDesmarcarEntregado={handleDesmarcarEntregado}
            onEliminarPedido={handleEliminarPedido}
            onVerPedidosEliminados={() => setModalPedidosEliminados(true)}
          />
        )}

        {vista === 'clientes' && (
          <VistaClientes
            clientes={clientes}
            loading={loadingClientes}
            isAdmin={isAdmin}
            isPreventista={isPreventista}
            onNuevoCliente={() => setModalCliente(true)}
            onEditarCliente={(cliente) => { setClienteEditando(cliente); setModalCliente(true); }}
            onEliminarCliente={handleEliminarCliente}
            onVerFichaCliente={handleVerFichaCliente}
          />
        )}

        {vista === 'productos' && (
          <VistaProductos
            productos={productos}
            loading={loadingProductos}
            isAdmin={isAdmin}
            onNuevoProducto={() => setModalProducto(true)}
            onEditarProducto={(producto) => { setProductoEditando(producto); setModalProducto(true); }}
            onEliminarProducto={handleEliminarProducto}
            onBajaStock={handleAbrirMerma}
            onVerHistorialMermas={handleVerHistorialMermas}
            onImportarPrecios={() => setModalImportarPrecios(true)}
          />
        )}

        {vista === 'reportes' && isAdmin && (
          <VistaReportes
            reportePreventistas={reportePreventistas}
            reporteInicializado={reporteInicializado}
            loading={loadingReporte}
            onCalcularReporte={calcularReportePreventistas}
            onVerFichaCliente={handleVerFichaCliente}
          />
        )}

        {vista === 'usuarios' && isAdmin && (
          <VistaUsuarios
            usuarios={usuarios}
            loading={loadingUsuarios}
            onEditarUsuario={(usuario) => { setUsuarioEditando(usuario); setModalUsuario(true); }}
          />
        )}

        {vista === 'recorridos' && isAdmin && (
          <VistaRecorridos
            recorridos={recorridos}
            loading={loadingRecorridos}
            fechaSeleccionada={fechaRecorridos}
            estadisticas={estadisticasRecorridos}
            onRefresh={async () => {
              const hoy = new Date().toISOString().split('T')[0];
              if (fechaRecorridos === hoy) {
                await fetchRecorridosHoy();
              } else {
                await fetchRecorridosPorFecha(fechaRecorridos);
              }
            }}
            onFechaChange={async (fecha) => {
              setFechaRecorridos(fecha);
              const hoy = new Date().toISOString().split('T')[0];
              if (fecha === hoy) {
                await fetchRecorridosHoy();
              } else {
                await fetchRecorridosPorFecha(fecha);
              }
            }}
          />
        )}

        {vista === 'compras' && isAdmin && (
          <VistaCompras
            compras={compras}
            proveedores={proveedores}
            loading={loadingCompras}
            isAdmin={isAdmin}
            onNuevaCompra={handleNuevaCompra}
            onVerDetalle={handleVerDetalleCompra}
            onAnularCompra={handleAnularCompra}
          />
        )}

        {vista === 'proveedores' && isAdmin && (
          <VistaProveedores
            proveedores={proveedores}
            compras={compras}
            loading={loadingCompras}
            isAdmin={isAdmin}
            onNuevoProveedor={handleNuevoProveedor}
            onEditarProveedor={handleEditarProveedor}
            onEliminarProveedor={handleEliminarProveedor}
            onToggleActivo={handleToggleActivoProveedor}
          />
        )}
        </Suspense>
        </div>
      </main>

      {/* Modales */}
      <ModalConfirmacion
        config={modalConfirm}
        onClose={() => setModalConfirm({ visible: false })}
      />

      {modalFiltroFecha && (
        <ModalFiltroFecha
          filtros={filtros}
          onApply={(nuevosFiltros) => handleFiltrosChange(nuevosFiltros)}
          onClose={() => setModalFiltroFecha(false)}
        />
      )}

      {modalCliente && (
        <ModalCliente
          cliente={clienteEditando}
          onSave={handleGuardarCliente}
          onClose={() => { setModalCliente(false); setClienteEditando(null); }}
          guardando={guardando}
          isAdmin={isAdmin}
          zonasExistentes={[...new Set(clientes.map(c => c.zona).filter(Boolean))]}
        />
      )}

      {modalProducto && (
        <ModalProducto
          producto={productoEditando}
          categorias={categorias}
          onSave={handleGuardarProducto}
          onClose={() => { setModalProducto(false); setProductoEditando(null); }}
          guardando={guardando}
        />
      )}

      {modalPedido && (
        <ModalPedido
          productos={productos}
          clientes={clientes}
          categorias={categorias}
          nuevoPedido={nuevoPedido}
          onClose={() => { setModalPedido(false); setNuevoPedido({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente', montoPagado: 0 }); }}
          onClienteChange={handleClienteChange}
          onAgregarItem={agregarItemPedido}
          onActualizarCantidad={actualizarCantidadItem}
          onCrearCliente={handleCrearClienteEnPedido}
          onGuardar={handleGuardarPedidoConOffline}
          isOffline={!isOnline}
          onNotasChange={handleNotasChange}
          onFormaPagoChange={handleFormaPagoChange}
          onEstadoPagoChange={handleEstadoPagoChange}
          onMontoPagadoChange={handleMontoPagadoChange}
          guardando={guardando}
          isAdmin={isAdmin}
          isPreventista={isPreventista}
        />
      )}

      {modalUsuario && (
        <ModalUsuario
          usuario={usuarioEditando}
          onSave={handleGuardarUsuario}
          onClose={() => { setModalUsuario(false); setUsuarioEditando(null); }}
          guardando={guardando}
        />
      )}

      {modalAsignar && (
        <ModalAsignarTransportista
          pedido={pedidoAsignando}
          transportistas={transportistas}
          onSave={handleAsignarTransportista}
          onClose={() => { setModalAsignar(false); setPedidoAsignando(null); }}
          guardando={guardando}
        />
      )}

      {modalHistorial && (
        <ModalHistorialPedido
          pedido={pedidoHistorial}
          historial={historialCambios}
          onClose={() => { setModalHistorial(false); setPedidoHistorial(null); setHistorialCambios([]); setCargandoHistorial(false); }}
          loading={cargandoHistorial}
        />
      )}

      {modalEditarPedido && (
        <ModalEditarPedido
          pedido={pedidoEditando}
          productos={productos}
          isAdmin={isAdmin}
          onSave={handleGuardarEdicionPedido}
          onSaveItems={async (items) => {
            await actualizarItemsPedido(pedidoEditando.id, items, user?.id);
            refetchProductos();
            notify.success('Productos del pedido actualizados');
          }}
          onClose={() => { setModalEditarPedido(false); setPedidoEditando(null); }}
          guardando={guardando}
        />
      )}

      {modalExportarPDF && (
        <ModalExportarPDF
          pedidos={pedidos}
          transportistas={transportistas}
          onExportarOrdenPreparacion={generarOrdenPreparacion}
          onExportarHojaRuta={generarHojaRuta}
          onClose={() => setModalExportarPDF(false)}
        />
      )}

      {modalOptimizarRuta && (
        <ModalGestionRutas
          transportistas={transportistas}
          pedidos={pedidos}
          onOptimizar={(transportistaId, pedidosData) => optimizarRuta(transportistaId, pedidosData)}
          onAplicarOrden={handleAplicarOrdenOptimizado}
          onExportarPDF={handleExportarHojaRutaOptimizada}
          onClose={handleCerrarModalOptimizar}
          loading={loadingOptimizacion}
          guardando={guardando}
          rutaOptimizada={rutaOptimizada}
          error={errorOptimizacion}
        />
      )}

      {modalFichaCliente && clienteFicha && (
        <ModalFichaCliente
          cliente={clienteFicha}
          onClose={() => { setModalFichaCliente(false); setClienteFicha(null); }}
          onRegistrarPago={handleAbrirRegistrarPago}
        />
      )}

      {modalRegistrarPago && clientePago && (
        <ModalRegistrarPago
          cliente={clientePago}
          saldoPendiente={saldoPendienteCliente}
          pedidos={pedidos}
          onClose={() => { setModalRegistrarPago(false); setClientePago(null); }}
          onConfirmar={handleRegistrarPago}
          onGenerarRecibo={handleGenerarReciboPago}
        />
      )}

      {modalMermaStock && productoMerma && (
        <ModalMermaStock
          producto={productoMerma}
          onSave={handleRegistrarMerma}
          onClose={() => { setModalMermaStock(false); setProductoMerma(null); }}
          isOffline={!isOnline}
        />
      )}

      {modalHistorialMermas && (
        <ModalHistorialMermas
          mermas={mermas}
          productos={productos}
          usuarios={usuarios}
          onClose={() => setModalHistorialMermas(false)}
        />
      )}

      {modalCompra && (
        <ModalCompra
          productos={productos}
          proveedores={proveedores}
          onSave={handleRegistrarCompra}
          onClose={() => setModalCompra(false)}
        />
      )}

      {modalDetalleCompra && compraDetalle && (
        <ModalDetalleCompra
          compra={compraDetalle}
          onClose={() => { setModalDetalleCompra(false); setCompraDetalle(null); }}
          onAnular={handleAnularCompra}
        />
      )}

      {modalProveedor && (
        <ModalProveedor
          proveedor={proveedorEditando}
          onSave={handleGuardarProveedor}
          onClose={() => { setModalProveedor(false); setProveedorEditando(null); }}
          guardando={guardando}
        />
      )}

      {modalImportarPrecios && (
        <ModalImportarPrecios
          productos={productos}
          onActualizarPrecios={actualizarPreciosMasivo}
          onClose={() => setModalImportarPrecios(false)}
        />
      )}

      {modalPedidosEliminados && (
        <ModalPedidosEliminados
          onFetch={fetchPedidosEliminados}
          onClose={() => setModalPedidosEliminados(false)}
        />
      )}

      {/* Indicador de estado offline */}
      <OfflineIndicator
        isOnline={isOnline}
        pedidosPendientes={pedidosPendientes}
        mermasPendientes={mermasPendientes}
        sincronizando={sincronizando}
        onSincronizar={handleSincronizar}
        clientes={clientes}
      />
    </div>
  );
}

export default function App() {
  return (
    <ErrorBoundary>
      <ThemeProvider>
        <AuthProvider>
          <NotificationProvider>
            <AppContent />
          </NotificationProvider>
        </AuthProvider>
      </ThemeProvider>
    </ErrorBoundary>
  );
}

function AppContent() {
  const { user, loading } = useAuth();
  if (loading) {
    return (
      <div className="min-h-screen bg-gray-100 dark:bg-gray-900 flex items-center justify-center transition-colors">
        <Loader2 className="w-8 h-8 animate-spin text-blue-600" aria-label="Cargando" />
      </div>
    );
  }
  return user ? <MainApp /> : <LoginScreen />;
}
