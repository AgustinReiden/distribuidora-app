import React, { useState, useMemo, useCallback, useEffect } from 'react';
import { Loader2 } from 'lucide-react';
import { AuthProvider, useAuth, useClientes, useProductos, usePedidos, useUsuarios, useDashboard, useBackup, setErrorNotifier } from './hooks/useSupabase.jsx';
import { ToastProvider, useToast } from './components/Toast.jsx';
import { ThemeProvider } from './contexts/ThemeContext';
import { ModalConfirmacion, ModalFiltroFecha, ModalCliente, ModalProducto, ModalUsuario, ModalAsignarTransportista, ModalPedido, ModalHistorialPedido, ModalEditarPedido, ModalExportarPDF, ModalOptimizarRuta } from './components/Modals.jsx';
import { generarOrdenPreparacion, generarHojaRuta } from './lib/pdfExport.js';
import { useOptimizarRuta } from './hooks/useOptimizarRuta.js';
import { ITEMS_PER_PAGE } from './utils/formatters';

// Componentes
import LoginScreen from './components/auth/LoginScreen';
import Sidebar from './components/layout/Sidebar';
import TopBar from './components/layout/TopBar';
import { useNotifications } from './components/layout/NotificationCenter';
import VistaDashboard from './components/vistas/VistaDashboard';
import VistaPedidos from './components/vistas/VistaPedidos';
import VistaClientes from './components/vistas/VistaClientes';
import VistaProductos from './components/vistas/VistaProductos';
import VistaReportes from './components/vistas/VistaReportes';
import VistaUsuarios from './components/vistas/VistaUsuarios';

function MainApp() {
  const { user, perfil, logout, isAdmin, isPreventista, isTransportista } = useAuth();
  const toast = useToast();
  const [vista, setVista] = useState(perfil?.rol === 'admin' ? 'dashboard' : 'pedidos');
  const [sidebarColapsado, setSidebarColapsado] = useState(false);

  // Sistema de notificaciones
  const {
    notifications,
    addNotification,
    markAsRead,
    markAllAsRead,
    removeNotification,
    clearAll: clearNotifications,
    unreadCount
  } = useNotifications();

  // Configurar el notificador de errores centralizado
  useEffect(() => {
    setErrorNotifier((message) => {
      toast.error(message);
      addNotification({ type: 'error', title: 'Error', message });
    });
  }, [toast, addNotification]);

  // Hooks de datos
  const { clientes, agregarCliente, actualizarCliente, eliminarCliente, loading: loadingClientes } = useClientes();
  const { productos, agregarProducto, actualizarProducto, eliminarProducto, validarStock, descontarStock, restaurarStock, loading: loadingProductos, refetch: refetchProductos } = useProductos();
  const { pedidos, pedidosFiltrados, crearPedido, cambiarEstado, asignarTransportista, eliminarPedido, actualizarNotasPedido, actualizarEstadoPago, actualizarFormaPago, actualizarOrdenEntrega, fetchHistorialPedido, filtros, setFiltros, loading: loadingPedidos, refetch: refetchPedidos } = usePedidos();
  const { usuarios, transportistas, actualizarUsuario, loading: loadingUsuarios } = useUsuarios();
  const { metricas, reportePreventistas, reporteInicializado, calcularReportePreventistas, loading: loadingMetricas, loadingReporte, refetch: refetchMetricas, filtroPeriodo, cambiarPeriodo } = useDashboard();
  const { exportando, descargarJSON, exportarPedidosCSV } = useBackup();
  const { loading: loadingOptimizacion, rutaOptimizada, error: errorOptimizacion, optimizarRuta, limpiarRuta } = useOptimizarRuta();

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

  // Estados de edición
  const [clienteEditando, setClienteEditando] = useState(null);
  const [productoEditando, setProductoEditando] = useState(null);
  const [usuarioEditando, setUsuarioEditando] = useState(null);
  const [pedidoAsignando, setPedidoAsignando] = useState(null);
  const [pedidoHistorial, setPedidoHistorial] = useState(null);
  const [historialCambios, setHistorialCambios] = useState([]);
  const [pedidoEditando, setPedidoEditando] = useState(null);

  // Estados del formulario de pedido
  const [nuevoPedido, setNuevoPedido] = useState({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente' });
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
    try { await logout(); } catch (e) { console.error(e); }
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
      toast.success(cliente.id ? 'Cliente actualizado correctamente' : 'Cliente creado correctamente');
    } catch (e) {
      toast.error('Error: ' + e.message);
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
          toast.success('Cliente eliminado');
          addNotification({ type: 'success', title: 'Cliente eliminado', message: 'El cliente fue eliminado correctamente' });
        } catch (e) {
          toast.error(e.message);
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
      toast.success(producto.id ? 'Producto actualizado correctamente' : 'Producto creado correctamente');
    } catch (e) {
      toast.error('Error: ' + e.message);
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
          toast.success('Producto eliminado');
        } catch (e) {
          toast.error(e.message);
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
      toast.success('Usuario actualizado correctamente');
    } catch (e) {
      toast.error('Error: ' + e.message);
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
    setNuevoPedido(prev => ({ ...prev, estadoPago }));
  }, []);

  const handleCrearClienteEnPedido = useCallback(async (nuevoCliente) => {
    const cliente = await agregarCliente(nuevoCliente);
    toast.success('Cliente creado correctamente');
    return cliente;
  }, [agregarCliente, toast]);

  const handleGuardarPedido = async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      toast.warning('Seleccioná cliente y productos');
      return;
    }
    const validacion = validarStock(nuevoPedido.items);
    if (!validacion.valido) {
      toast.error(`Stock insuficiente:\n${validacion.errores.map(e => e.mensaje).join('\n')}`, 5000);
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
      setNuevoPedido({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente' });
      setModalPedido(false);
      refetchProductos();
      refetchMetricas();
      toast.success('Pedido creado correctamente');
      addNotification({ type: 'success', title: 'Nuevo pedido', message: 'El pedido fue creado correctamente' });
    } catch (e) {
      toast.error('Error al crear pedido: ' + e.message);
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
          toast.success(`Pedido #${pedido.id} marcado como entregado`);
          addNotification({ type: 'success', title: 'Pedido entregado', message: `El pedido #${pedido.id} fue marcado como entregado` });
        } catch (e) {
          toast.error(e.message);
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
          toast.warning(`Pedido #${pedido.id} revertido`);
        } catch (e) {
          toast.error(e.message);
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
          toast.success(`Pedido #${pedido.id} marcado como en preparación`);
        } catch (e) {
          toast.error(e.message);
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
        toast.success(marcarListo ? 'Transportista asignado y pedido listo para entregar' : 'Transportista asignado (el pedido mantiene su estado actual)');
      } else {
        toast.success('Transportista desasignado');
      }
    } catch (e) {
      toast.error('Error: ' + e.message);
    }
    setGuardando(false);
  };

  const handleEliminarPedido = (id) => {
    setModalConfirm({
      visible: true,
      titulo: 'Eliminar pedido',
      mensaje: '¿Eliminar este pedido? El stock será restaurado.',
      tipo: 'danger',
      onConfirm: async () => {
        setGuardando(true);
        try {
          await eliminarPedido(id, restaurarStock);
          refetchProductos();
          refetchMetricas();
          toast.success('Pedido eliminado y stock restaurado');
        } catch (e) {
          toast.error(e.message);
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
      toast.error('Error al cargar historial: ' + e.message);
      setHistorialCambios([]);
    } finally {
      setCargandoHistorial(false);
    }
  };

  const handleEditarPedido = (pedido) => {
    setPedidoEditando(pedido);
    setModalEditarPedido(true);
  };

  const handleGuardarEdicionPedido = async ({ notas, formaPago, estadoPago }) => {
    if (!pedidoEditando) return;
    setGuardando(true);
    try {
      await actualizarNotasPedido(pedidoEditando.id, notas);
      await actualizarFormaPago(pedidoEditando.id, formaPago);
      await actualizarEstadoPago(pedidoEditando.id, estadoPago);
      setModalEditarPedido(false);
      setPedidoEditando(null);
      toast.success('Pedido actualizado correctamente');
    } catch (e) {
      toast.error('Error al actualizar pedido: ' + e.message);
    }
    setGuardando(false);
  };

  const handleAplicarOrdenOptimizado = async (ordenOptimizado) => {
    setGuardando(true);
    try {
      await actualizarOrdenEntrega(ordenOptimizado);
      toast.success('Orden de entrega actualizado correctamente');
      setModalOptimizarRuta(false);
      limpiarRuta();
      refetchPedidos();
    } catch (e) {
      toast.error('Error al actualizar orden: ' + e.message);
    }
    setGuardando(false);
  };

  const handleCerrarModalOptimizar = () => {
    setModalOptimizarRuta(false);
    limpiarRuta();
  };

  // Mapa de títulos para la TopBar
  const titulosVista = {
    dashboard: 'Dashboard',
    pedidos: 'Pedidos',
    clientes: 'Clientes',
    productos: 'Productos',
    reportes: 'Reportes',
    usuarios: 'Usuarios'
  };

  return (
    <div className="min-h-screen bg-gray-100 dark:bg-gray-900 transition-colors">
      <Sidebar
        vista={vista}
        setVista={setVista}
        perfil={perfil}
        onLogout={handleLogout}
        colapsado={sidebarColapsado}
        setColapsado={setSidebarColapsado}
      />

      <TopBar
        titulo={titulosVista[vista] || vista}
        onToggleSidebar={() => setSidebarColapsado(!sidebarColapsado)}
        sidebarColapsado={sidebarColapsado}
        notifications={notifications}
        onMarkAsRead={markAsRead}
        onMarkAllAsRead={markAllAsRead}
        onRemoveNotification={removeNotification}
        onClearNotifications={clearNotifications}
        unreadCount={unreadCount}
      />

      <main className={`pt-20 pb-6 px-4 transition-all duration-300 ${sidebarColapsado ? 'ml-20' : 'ml-64'}`}>
        <div className="max-w-7xl mx-auto">
        {vista === 'dashboard' && isAdmin && (
          <VistaDashboard
            metricas={metricas}
            loading={loadingMetricas}
            filtroPeriodo={filtroPeriodo}
            onCambiarPeriodo={cambiarPeriodo}
            onRefetch={refetchMetricas}
            onDescargarBackup={descargarJSON}
            exportando={exportando}
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
            loading={loadingPedidos}
            exportando={exportando}
            onBusquedaChange={handleBusquedaChange}
            onFiltrosChange={handleFiltrosChange}
            onPageChange={setPaginaActual}
            onNuevoPedido={() => setModalPedido(true)}
            onOptimizarRuta={() => setModalOptimizarRuta(true)}
            onExportarPDF={() => setModalExportarPDF(true)}
            onExportarCSV={() => exportarPedidosCSV(pedidosParaMostrar)}
            onModalFiltroFecha={() => setModalFiltroFecha(true)}
            onVerHistorial={handleVerHistorial}
            onEditarPedido={handleEditarPedido}
            onMarcarEnPreparacion={handleMarcarEnPreparacion}
            onAsignarTransportista={(pedido) => { setPedidoAsignando(pedido); setModalAsignar(true); }}
            onMarcarEntregado={handleMarcarEntregado}
            onDesmarcarEntregado={handleDesmarcarEntregado}
            onEliminarPedido={handleEliminarPedido}
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
          />
        )}

        {vista === 'reportes' && isAdmin && (
          <VistaReportes
            reportePreventistas={reportePreventistas}
            reporteInicializado={reporteInicializado}
            loading={loadingReporte}
            onCalcularReporte={calcularReportePreventistas}
          />
        )}

        {vista === 'usuarios' && isAdmin && (
          <VistaUsuarios
            usuarios={usuarios}
            loading={loadingUsuarios}
            onEditarUsuario={(usuario) => { setUsuarioEditando(usuario); setModalUsuario(true); }}
          />
        )}
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
          onClose={() => { setModalPedido(false); setNuevoPedido({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente' }); }}
          onClienteChange={handleClienteChange}
          onAgregarItem={agregarItemPedido}
          onActualizarCantidad={actualizarCantidadItem}
          onCrearCliente={handleCrearClienteEnPedido}
          onGuardar={handleGuardarPedido}
          onNotasChange={handleNotasChange}
          onFormaPagoChange={handleFormaPagoChange}
          onEstadoPagoChange={handleEstadoPagoChange}
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
          onSave={handleGuardarEdicionPedido}
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
        <ModalOptimizarRuta
          transportistas={transportistas}
          pedidos={pedidos}
          onOptimizar={(transportistaId, pedidosData) => optimizarRuta(transportistaId, pedidosData)}
          onAplicarOrden={handleAplicarOrdenOptimizado}
          onClose={handleCerrarModalOptimizar}
          loading={loadingOptimizacion}
          rutaOptimizada={rutaOptimizada}
          error={errorOptimizacion}
        />
      )}
    </div>
  );
}

export default function App() {
  return (
    <ThemeProvider>
      <AuthProvider>
        <ToastProvider>
          <AppContent />
        </ToastProvider>
      </AuthProvider>
    </ThemeProvider>
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
