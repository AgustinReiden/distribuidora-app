import React, { useState, useMemo, useCallback, useEffect } from 'react';
import { Package, Users, ShoppingCart, Truck, Plus, Edit2, Trash2, Check, Clock, Search, X, Menu, Loader2, LogOut, UserCog, AlertTriangle, User, BarChart3, Calendar, Download, TrendingUp, DollarSign, FileDown, RefreshCw, ChevronLeft, ChevronRight, History, FileText, CreditCard } from 'lucide-react';
import { AuthProvider, useAuth, useClientes, useProductos, usePedidos, useUsuarios, useDashboard, useBackup, setErrorNotifier } from './hooks/useSupabase.jsx';
import { ToastProvider, useToast } from './components/Toast.jsx';
import { ModalConfirmacion, ModalFiltroFecha, ModalCliente, ModalProducto, ModalUsuario, ModalAsignarTransportista, ModalPedido, ModalHistorialPedido, ModalEditarPedido } from './components/Modals.jsx';

const formatPrecio = (p) => new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0);
const formatFecha = (f) => f ? new Date(f).toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '';
const getEstadoColor = (e) => e === 'pendiente' ? 'bg-yellow-100 text-yellow-800' : e === 'asignado' ? 'bg-blue-100 text-blue-800' : 'bg-green-100 text-green-800';
const getEstadoLabel = (e) => e === 'pendiente' ? 'Pendiente' : e === 'asignado' ? 'En camino' : 'Entregado';
const getRolColor = (r) => r === 'admin' ? 'bg-purple-100 text-purple-700' : r === 'transportista' ? 'bg-orange-100 text-orange-700' : 'bg-blue-100 text-blue-700';
const getRolLabel = (r) => r === 'admin' ? 'Admin' : r === 'transportista' ? 'Transportista' : 'Preventista';
const LoadingSpinner = () => <div className="flex items-center justify-center py-12"><Loader2 className="w-8 h-8 animate-spin text-blue-600" /><span className="ml-2 text-gray-600">Cargando...</span></div>;

const ITEMS_PER_PAGE = 10;

function LoginScreen() {
  const { login } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault(); setError(''); setLoading(true);
    try { await login(email, password); } catch { setError('Email o contraseña incorrectos'); }
    setLoading(false);
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-blue-600 to-blue-800 flex items-center justify-center p-4">
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-md p-8">
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-blue-100 rounded-full mb-4"><Truck className="w-8 h-8 text-blue-600" /></div>
          <h1 className="text-2xl font-bold text-gray-800">Distribuidora</h1>
          <p className="text-gray-500 mt-1">Ingresá con tu cuenta</p>
        </div>
        <form onSubmit={handleSubmit} className="space-y-4">
          {error && <div className="bg-red-50 text-red-600 px-4 py-3 rounded-lg text-sm">{error}</div>}
          <div><label className="block text-sm font-medium text-gray-700 mb-1">Email</label><input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="w-full px-4 py-3 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="tu@email.com" required /></div>
          <div><label className="block text-sm font-medium text-gray-700 mb-1">Contraseña</label><input type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="w-full px-4 py-3 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="••••••••" required /></div>
          <button type="submit" disabled={loading} className="w-full py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 font-medium flex items-center justify-center">{loading ? <Loader2 className="w-5 h-5 animate-spin" /> : 'Ingresar'}</button>
        </form>
      </div>
    </div>
  );
}

function MainApp() {
  const { user, perfil, logout, isAdmin, isPreventista, isTransportista } = useAuth();
  const toast = useToast();
  const [vista, setVista] = useState(perfil?.rol === 'admin' ? 'dashboard' : 'pedidos');
  const [menuAbierto, setMenuAbierto] = useState(false);

  // Configurar el notificador de errores centralizado
  useEffect(() => {
    setErrorNotifier((message) => toast.error(message));
  }, [toast]);

  const { clientes, agregarCliente, actualizarCliente, eliminarCliente, loading: loadingClientes } = useClientes();
  const { productos, agregarProducto, actualizarProducto, eliminarProducto, validarStock, descontarStock, restaurarStock, loading: loadingProductos, refetch: refetchProductos } = useProductos();
  const { pedidos, pedidosFiltrados, crearPedido, cambiarEstado, asignarTransportista, eliminarPedido, actualizarNotasPedido, actualizarEstadoPago, actualizarFormaPago, fetchHistorialPedido, filtros, setFiltros, loading: loadingPedidos, refetch: refetchPedidos } = usePedidos();
  const { usuarios, transportistas, actualizarUsuario, loading: loadingUsuarios } = useUsuarios();
  const { metricas, reportePreventistas, calcularReportePreventistas, loading: loadingMetricas, loadingReporte, refetch: refetchMetricas } = useDashboard();
  const { exportando, descargarJSON, exportarPedidosCSV } = useBackup();

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

  const [clienteEditando, setClienteEditando] = useState(null);
  const [productoEditando, setProductoEditando] = useState(null);
  const [usuarioEditando, setUsuarioEditando] = useState(null);
  const [pedidoAsignando, setPedidoAsignando] = useState(null);
  const [pedidoHistorial, setPedidoHistorial] = useState(null);
  const [historialCambios, setHistorialCambios] = useState([]);
  const [pedidoEditando, setPedidoEditando] = useState(null);

  const [nuevoPedido, setNuevoPedido] = useState({ clienteId: '', items: [], notas: '', formaPago: 'efectivo', estadoPago: 'pendiente' });
  const [busqueda, setBusqueda] = useState('');
  const [guardando, setGuardando] = useState(false);
  const [cargandoHistorial, setCargandoHistorial] = useState(false);

  // Paginación
  const [paginaActual, setPaginaActual] = useState(1);

  // Extraer categorías únicas de productos
  const categorias = useMemo(() => {
    const cats = productos.map(p => p.categoria).filter(Boolean);
    return [...new Set(cats)].sort();
  }, [productos]);

  const handleLogout = async () => { try { await logout(); } catch (e) { console.error(e); } };
  const calcularTotalPedido = (items) => items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);

  const pedidosParaMostrar = useMemo(() => {
    return pedidosFiltrados().filter(p =>
      !busqueda ||
      p.cliente?.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase()) ||
      p.cliente?.direccion?.toLowerCase().includes(busqueda.toLowerCase()) ||
      p.id.toString().includes(busqueda)
    );
  }, [pedidosFiltrados, busqueda]);

  // Paginación de pedidos
  const totalPaginas = Math.ceil(pedidosParaMostrar.length / ITEMS_PER_PAGE);
  const pedidosPaginados = useMemo(() => {
    const inicio = (paginaActual - 1) * ITEMS_PER_PAGE;
    return pedidosParaMostrar.slice(inicio, inicio + ITEMS_PER_PAGE);
  }, [pedidosParaMostrar, paginaActual]);

  // Reset página cuando cambian filtros
  const handleBusquedaChange = (value) => {
    setBusqueda(value);
    setPaginaActual(1);
  };

  const handleFiltrosChange = (nuevosFiltros) => {
    setFiltros({ ...filtros, ...nuevosFiltros });
    setPaginaActual(1);
  };

  const productosStockBajo = productos.filter(p => p.stock < 10);

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
        } catch (e) {
          toast.error(e.message);
        } finally {
          setGuardando(false);
          setModalConfirm({ visible: false });
        }
      }
    });
  };

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
    }
    catch (e) {
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

  const handleAsignarTransportista = async (transportistaId) => {
    if (!pedidoAsignando) return;
    setGuardando(true);
    try {
      await asignarTransportista(pedidoAsignando.id, transportistaId || null);
      setModalAsignar(false);
      setPedidoAsignando(null);
      toast.success(transportistaId ? 'Transportista asignado correctamente' : 'Transportista desasignado');
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

  const menuItems = [
    { id: 'dashboard', icon: BarChart3, label: 'Dashboard', roles: ['admin'] },
    { id: 'pedidos', icon: ShoppingCart, label: 'Pedidos', roles: ['admin', 'preventista', 'transportista'] },
    { id: 'clientes', icon: Users, label: 'Clientes', roles: ['admin', 'preventista'] },
    { id: 'productos', icon: Package, label: 'Productos', roles: ['admin', 'preventista'] },
    { id: 'reportes', icon: TrendingUp, label: 'Reportes', roles: ['admin'] },
    { id: 'usuarios', icon: UserCog, label: 'Usuarios', roles: ['admin'] },
  ].filter(item => item.roles.includes(perfil?.rol));

  const Navegacion = () => (
    <nav className="bg-blue-600 text-white shadow-lg">
      <div className="max-w-7xl mx-auto px-4">
        <div className="flex justify-between items-center h-16">
          <div className="flex items-center space-x-2"><Truck className="w-8 h-8" /><span className="font-bold text-xl hidden sm:block">Distribuidora</span></div>
          <div className="hidden md:flex items-center space-x-1">
            {menuItems.map(item => (<button key={item.id} onClick={() => setVista(item.id)} className={`flex items-center space-x-2 px-4 py-2 rounded-lg ${vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'}`}><item.icon className="w-5 h-5" /><span>{item.label}</span></button>))}
            <div className="ml-4 pl-4 border-l border-blue-400 flex items-center space-x-3">
              <span className="text-sm">{perfil?.nombre}</span>
              <span className={`text-xs px-2 py-1 rounded ${getRolColor(perfil?.rol)}`}>{getRolLabel(perfil?.rol)}</span>
              <button onClick={handleLogout} className="p-2 hover:bg-blue-500 rounded-lg"><LogOut className="w-5 h-5" /></button>
            </div>
          </div>
          <button className="md:hidden p-2" onClick={() => setMenuAbierto(!menuAbierto)}><Menu className="w-6 h-6" /></button>
        </div>
        {menuAbierto && (<div className="md:hidden pb-4 space-y-2">{menuItems.map(item => (<button key={item.id} onClick={() => { setVista(item.id); setMenuAbierto(false); }} className={`flex items-center space-x-2 w-full px-4 py-2 rounded-lg ${vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'}`}><item.icon className="w-5 h-5" /><span>{item.label}</span></button>))}<div className="pt-2 mt-2 border-t border-blue-400"><button onClick={handleLogout} className="flex items-center space-x-2 w-full px-4 py-2 hover:bg-blue-500 rounded-lg"><LogOut className="w-5 h-5" /><span>Salir</span></button></div></div>)}
      </div>
    </nav>
  );

  // Componente de paginación
  const Paginacion = () => {
    if (totalPaginas <= 1) return null;

    const getPageNumbers = () => {
      const pages = [];
      const maxVisible = 5;
      let start = Math.max(1, paginaActual - Math.floor(maxVisible / 2));
      let end = Math.min(totalPaginas, start + maxVisible - 1);

      if (end - start + 1 < maxVisible) {
        start = Math.max(1, end - maxVisible + 1);
      }

      for (let i = start; i <= end; i++) {
        pages.push(i);
      }
      return pages;
    };

    return (
      <div className="flex items-center justify-center space-x-2 mt-4">
        <button
          onClick={() => setPaginaActual(p => Math.max(1, p - 1))}
          disabled={paginaActual === 1}
          className="p-2 rounded-lg border hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <ChevronLeft className="w-5 h-5" />
        </button>

        {getPageNumbers().map(num => (
          <button
            key={num}
            onClick={() => setPaginaActual(num)}
            className={`w-10 h-10 rounded-lg ${
              paginaActual === num
                ? 'bg-blue-600 text-white'
                : 'border hover:bg-gray-100'
            }`}
          >
            {num}
          </button>
        ))}

        <button
          onClick={() => setPaginaActual(p => Math.min(totalPaginas, p + 1))}
          disabled={paginaActual === totalPaginas}
          className="p-2 rounded-lg border hover:bg-gray-100 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <ChevronRight className="w-5 h-5" />
        </button>

        <span className="text-sm text-gray-500 ml-4">
          {pedidosParaMostrar.length} pedido{pedidosParaMostrar.length !== 1 ? 's' : ''}
        </span>
      </div>
    );
  };

  const VistaDashboard = () => (
    <div className="space-y-6">
      <div className="flex justify-between items-center">
        <h1 className="text-2xl font-bold">Dashboard</h1>
        <div className="flex space-x-2">
          <button onClick={() => refetchMetricas()} disabled={loadingMetricas} className="flex items-center space-x-2 px-4 py-2 bg-white border rounded-lg hover:bg-gray-50"><RefreshCw className={`w-5 h-5 ${loadingMetricas ? 'animate-spin' : ''}`} /><span>Actualizar</span></button>
          <button onClick={() => descargarJSON('completo')} disabled={exportando} className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700"><Download className="w-5 h-5" /><span>Backup</span></button>
        </div>
      </div>

      {loadingMetricas ? <LoadingSpinner /> : (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-white rounded-xl shadow p-4"><div className="flex items-center space-x-3"><div className="p-3 bg-green-100 rounded-lg"><DollarSign className="w-6 h-6 text-green-600" /></div><div><p className="text-sm text-gray-500">Ventas Hoy</p><p className="text-xl font-bold">{formatPrecio(metricas.ventasHoy)}</p></div></div></div>
            <div className="bg-white rounded-xl shadow p-4"><div className="flex items-center space-x-3"><div className="p-3 bg-blue-100 rounded-lg"><TrendingUp className="w-6 h-6 text-blue-600" /></div><div><p className="text-sm text-gray-500">Ventas Semana</p><p className="text-xl font-bold">{formatPrecio(metricas.ventasSemana)}</p></div></div></div>
            <div className="bg-white rounded-xl shadow p-4"><div className="flex items-center space-x-3"><div className="p-3 bg-purple-100 rounded-lg"><BarChart3 className="w-6 h-6 text-purple-600" /></div><div><p className="text-sm text-gray-500">Ventas Mes</p><p className="text-xl font-bold">{formatPrecio(metricas.ventasMes)}</p></div></div></div>
            <div className="bg-white rounded-xl shadow p-4"><div className="flex items-center space-x-3"><div className="p-3 bg-orange-100 rounded-lg"><ShoppingCart className="w-6 h-6 text-orange-600" /></div><div><p className="text-sm text-gray-500">Pedidos Mes</p><p className="text-xl font-bold">{metricas.pedidosMes}</p></div></div></div>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Clock className="w-5 h-5 text-yellow-600" /><span className="text-yellow-800 font-medium">Pendientes</span></div><p className="text-3xl font-bold text-yellow-600 mt-2">{metricas.pedidosPorEstado.pendiente}</p></div>
            <div className="bg-blue-50 border border-blue-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Truck className="w-5 h-5 text-blue-600" /><span className="text-blue-800 font-medium">En camino</span></div><p className="text-3xl font-bold text-blue-600 mt-2">{metricas.pedidosPorEstado.asignado}</p></div>
            <div className="bg-green-50 border border-green-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Check className="w-5 h-5 text-green-600" /><span className="text-green-800 font-medium">Entregados</span></div><p className="text-3xl font-bold text-green-600 mt-2">{metricas.pedidosPorEstado.entregado}</p></div>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div className="bg-white rounded-xl shadow p-4">
              <h3 className="font-semibold mb-4">Ventas últimos 7 días</h3>
              <div className="space-y-2">
                {metricas.ventasPorDia.map((d, i) => {
                  const maxVenta = Math.max(...metricas.ventasPorDia.map(x => x.ventas)) || 1;
                  const porcentaje = (d.ventas / maxVenta) * 100;
                  return (
                    <div key={i} className="flex items-center space-x-3">
                      <span className="w-12 text-sm text-gray-600">{d.dia}</span>
                      <div className="flex-1 bg-gray-200 rounded-full h-6"><div className="bg-blue-500 rounded-full h-6 flex items-center justify-end pr-2" style={{ width: `${Math.max(porcentaje, 10)}%` }}><span className="text-xs text-white font-medium">{formatPrecio(d.ventas)}</span></div></div>
                    </div>
                  );
                })}
              </div>
            </div>

            <div className="bg-white rounded-xl shadow p-4">
              <h3 className="font-semibold mb-4">Top 5 Productos</h3>
              <div className="space-y-3">
                {metricas.productosMasVendidos.map((p, i) => (
                  <div key={p.id} className="flex items-center justify-between">
                    <div className="flex items-center space-x-3"><span className={`w-6 h-6 rounded-full flex items-center justify-center text-sm font-bold ${i === 0 ? 'bg-yellow-400 text-yellow-900' : i === 1 ? 'bg-gray-300 text-gray-700' : i === 2 ? 'bg-orange-400 text-orange-900' : 'bg-gray-100 text-gray-600'}`}>{i + 1}</span><span className="font-medium">{p.nombre}</span></div>
                    <span className="text-sm text-gray-600">{p.cantidad} unid.</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );

  const VistaPedidos = () => (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <h1 className="text-2xl font-bold">Pedidos</h1>
        <div className="flex space-x-2">
          {isAdmin && <button onClick={() => exportarPedidosCSV(pedidosParaMostrar)} disabled={exportando} className="flex items-center space-x-2 px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700"><FileDown className="w-5 h-5" /><span>CSV</span></button>}
          {(isAdmin || isPreventista) && <button onClick={() => setModalPedido(true)} className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700"><Plus className="w-5 h-5" /><span>Nuevo</span></button>}
        </div>
      </div>

      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1"><Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" /><input type="text" value={busqueda} onChange={e => handleBusquedaChange(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg" placeholder="Buscar..." /></div>
        <select value={filtros.estado} onChange={e => handleFiltrosChange({ estado: e.target.value })} className="px-4 py-2 border rounded-lg"><option value="todos">Todos</option><option value="pendiente">Pendientes</option><option value="asignado">En camino</option><option value="entregado">Entregados</option></select>
        <button onClick={() => setModalFiltroFecha(true)} className={`flex items-center space-x-2 px-4 py-2 border rounded-lg ${filtros.fechaDesde || filtros.fechaHasta ? 'bg-blue-50 border-blue-300' : ''}`}><Calendar className="w-5 h-5" /><span>Fechas</span></button>
      </div>

      {(filtros.fechaDesde || filtros.fechaHasta) && <div className="flex items-center space-x-2 text-sm text-blue-600"><Calendar className="w-4 h-4" /><span>Filtrado: {filtros.fechaDesde || '...'} - {filtros.fechaHasta || '...'}</span><button onClick={() => handleFiltrosChange({ fechaDesde: null, fechaHasta: null })} className="text-red-500"><X className="w-4 h-4" /></button></div>}

      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3"><Clock className="w-5 h-5 text-yellow-600" /><p className="text-xl font-bold text-yellow-600">{pedidos.filter(p => p.estado === 'pendiente').length}</p><p className="text-sm text-yellow-800">Pendientes</p></div>
        <div className="bg-blue-50 border border-blue-200 rounded-lg p-3"><Truck className="w-5 h-5 text-blue-600" /><p className="text-xl font-bold text-blue-600">{pedidos.filter(p => p.estado === 'asignado').length}</p><p className="text-sm text-blue-800">En camino</p></div>
        <div className="bg-green-50 border border-green-200 rounded-lg p-3"><Check className="w-5 h-5 text-green-600" /><p className="text-xl font-bold text-green-600">{pedidos.filter(p => p.estado === 'entregado').length}</p><p className="text-sm text-green-800">Entregados</p></div>
        <div className="bg-purple-50 border border-purple-200 rounded-lg p-3"><ShoppingCart className="w-5 h-5 text-purple-600" /><p className="text-xl font-bold text-purple-600">{pedidosParaMostrar.length}</p><p className="text-sm text-purple-800">Mostrando</p></div>
      </div>

      {loadingPedidos ? <LoadingSpinner /> : pedidosParaMostrar.length === 0 ? (<div className="text-center py-12 text-gray-500"><ShoppingCart className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay pedidos</p></div>) : (
        <>
          <div className="space-y-3">
            {pedidosPaginados.map(pedido => (
              <div key={pedido.id} className="bg-white border rounded-lg shadow-sm p-4">
                <div className="flex justify-between items-start">
                  <div>
                    <h3 className="font-semibold text-lg">{pedido.cliente?.nombre_fantasia || 'Sin cliente'}</h3>
                    <p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p>
                    <p className="text-sm text-gray-400 mt-1">#{pedido.id} • {formatFecha(pedido.created_at)}</p>
                    {pedido.transportista && <p className="text-sm text-orange-600 mt-1">🚚 {pedido.transportista.nombre}</p>}
                  </div>
                  <div className="flex flex-col items-end gap-2">
                    <span className={`px-3 py-1 rounded-full text-sm font-medium ${getEstadoColor(pedido.estado)}`}>{getEstadoLabel(pedido.estado)}</span>
                    {pedido.estado_pago && (
                      <span className={`px-3 py-1 rounded-full text-xs font-medium ${pedido.estado_pago === 'pagado' ? 'bg-green-100 text-green-800' : pedido.estado_pago === 'parcial' ? 'bg-yellow-100 text-yellow-800' : 'bg-red-100 text-red-800'}`}>
                        {pedido.estado_pago === 'pagado' ? 'Pagado' : pedido.estado_pago === 'parcial' ? 'Pago Parcial' : 'Pago Pendiente'}
                      </span>
                    )}
                  </div>
                </div>
                <div className="mt-3 pt-3 border-t">
                  <p className="text-sm text-gray-600 mb-2">{pedido.items?.map(i => <span key={i.id} className="mr-2">{i.producto?.nombre} x{i.cantidad}</span>)}</p>
                  {pedido.notas && (
                    <div className="mb-2 p-2 bg-blue-50 border border-blue-200 rounded-lg">
                      <p className="text-xs text-blue-700 flex items-start">
                        <FileText className="w-3 h-3 mr-1 mt-0.5 flex-shrink-0" />
                        <span>{pedido.notas}</span>
                      </p>
                    </div>
                  )}
                  <div className="flex flex-wrap justify-between items-center gap-2">
                    <div className="flex flex-col">
                      <p className="text-lg font-bold text-blue-600">{formatPrecio(pedido.total)}</p>
                      {pedido.forma_pago && (
                        <p className="text-xs text-gray-500 flex items-center">
                          <CreditCard className="w-3 h-3 mr-1" />
                          {pedido.forma_pago === 'efectivo' ? 'Efectivo' : pedido.forma_pago === 'transferencia' ? 'Transferencia' : pedido.forma_pago === 'cheque' ? 'Cheque' : pedido.forma_pago === 'cuenta_corriente' ? 'Cta. Cte.' : pedido.forma_pago}
                        </p>
                      )}
                    </div>
                    <div className="flex flex-wrap gap-2">
                      <button onClick={() => handleVerHistorial(pedido)} className="flex items-center space-x-1 px-3 py-1.5 bg-gray-100 text-gray-700 rounded-lg text-sm hover:bg-gray-200">
                        <History className="w-4 h-4" /><span>Historial</span>
                      </button>
                      {(isAdmin || isPreventista) && <button onClick={() => handleEditarPedido(pedido)} className="flex items-center space-x-1 px-3 py-1.5 bg-blue-100 text-blue-700 rounded-lg text-sm hover:bg-blue-200">
                        <Edit2 className="w-4 h-4" /><span>Editar</span>
                      </button>}
                      {isAdmin && pedido.estado !== 'entregado' && <button onClick={() => { setPedidoAsignando(pedido); setModalAsignar(true); }} className="flex items-center space-x-1 px-3 py-1.5 bg-orange-500 text-white rounded-lg text-sm"><User className="w-4 h-4" /><span>{pedido.transportista ? 'Reasignar' : 'Asignar'}</span></button>}
                      {(isTransportista || isAdmin) && pedido.estado === 'asignado' && <button onClick={() => handleMarcarEntregado(pedido)} className="flex items-center space-x-1 px-3 py-1.5 bg-green-600 text-white rounded-lg text-sm"><Check className="w-4 h-4" /><span>Entregado</span></button>}
                      {isAdmin && pedido.estado === 'entregado' && <button onClick={() => handleDesmarcarEntregado(pedido)} className="flex items-center space-x-1 px-3 py-1.5 bg-yellow-500 text-white rounded-lg text-sm"><AlertTriangle className="w-4 h-4" /><span>Revertir</span></button>}
                      {isAdmin && <button onClick={() => handleEliminarPedido(pedido.id)} className="p-1.5 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-5 h-5" /></button>}
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>
          <Paginacion />
        </>
      )}
    </div>
  );

  const VistaClientes = () => (
    <div className="space-y-4">
      <div className="flex justify-between items-center"><h1 className="text-2xl font-bold">Clientes</h1>{(isAdmin || isPreventista) && <button onClick={() => setModalCliente(true)} className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"><Plus className="w-5 h-5" /><span>Nuevo</span></button>}</div>
      {loadingClientes ? <LoadingSpinner /> : clientes.length === 0 ? (<div className="text-center py-12 text-gray-500"><Users className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay clientes</p></div>) : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {clientes.map(c => (
            <div key={c.id} className="bg-white border rounded-lg shadow-sm p-4">
              <div className="flex justify-between items-start">
                <div><h3 className="font-semibold text-lg">{c.nombre_fantasia}</h3><p className="text-sm text-gray-600">{c.nombre}</p></div>
                {isAdmin && (<div className="flex space-x-1"><button onClick={() => { setClienteEditando(c); setModalCliente(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button><button onClick={() => handleEliminarCliente(c.id)} className="p-2 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-4 h-4" /></button></div>)}
              </div>
              <div className="mt-3 space-y-1 text-sm text-gray-500"><p>📍 {c.direccion}</p>{c.telefono && <p>📞 {c.telefono}</p>}{c.zona && <p>🗺️ {c.zona}</p>}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );

  const VistaProductos = () => (
    <div className="space-y-4">
      <div className="flex justify-between items-center"><h1 className="text-2xl font-bold">Productos</h1>{isAdmin && <button onClick={() => setModalProducto(true)} className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"><Plus className="w-5 h-5" /><span>Nuevo</span></button>}</div>
      {productosStockBajo.length > 0 && <div className="bg-red-50 border border-red-200 rounded-lg p-3"><p className="text-red-700 font-medium">⚠️ {productosStockBajo.length} producto(s) con stock bajo: {productosStockBajo.map(p => p.nombre).join(', ')}</p></div>}
      {loadingProductos ? <LoadingSpinner /> : productos.length === 0 ? (<div className="text-center py-12 text-gray-500"><Package className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay productos</p></div>) : (
        <div className="bg-white border rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50"><tr><th className="px-4 py-3 text-left text-sm font-medium">Producto</th><th className="px-4 py-3 text-left text-sm font-medium">Categoría</th><th className="px-4 py-3 text-right text-sm font-medium">Precio</th><th className="px-4 py-3 text-right text-sm font-medium">Stock</th>{isAdmin && <th className="px-4 py-3 text-right text-sm font-medium">Acciones</th>}</tr></thead>
            <tbody className="divide-y">
              {productos.map(p => (<tr key={p.id} className="hover:bg-gray-50"><td className="px-4 py-3 font-medium">{p.nombre}</td><td className="px-4 py-3"><span className={p.categoria ? 'px-2 py-1 bg-gray-100 rounded-full text-sm text-gray-700' : 'text-gray-400'}>{ p.categoria || 'Sin categoría'}</span></td><td className="px-4 py-3 text-right font-semibold text-blue-600">{formatPrecio(p.precio)}</td><td className="px-4 py-3 text-right"><span className={`px-2 py-1 rounded-full text-sm ${p.stock === 0 ? 'bg-red-100 text-red-700' : p.stock < 10 ? 'bg-yellow-100 text-yellow-700' : p.stock < 20 ? 'bg-orange-100 text-orange-700' : 'bg-green-100 text-green-700'}`}>{p.stock}</span></td>{isAdmin && <td className="px-4 py-3 text-right"><div className="flex justify-end space-x-1"><button onClick={() => { setProductoEditando(p); setModalProducto(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button><button onClick={() => handleEliminarProducto(p.id)} className="p-2 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-4 h-4" /></button></div></td>}</tr>))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );

  const VistaReportes = () => {
    const [fechaDesde, setFechaDesde] = useState('');
    const [fechaHasta, setFechaHasta] = useState('');
    const [cargandoReporte, setCargandoReporte] = useState(false);
    const [reporteGenerado, setReporteGenerado] = useState(false);

    // Cargar reporte automáticamente al montar el componente
    useEffect(() => {
      if (!reporteGenerado) {
        handleGenerarReporte();
      }
    }, []);

    const handleGenerarReporte = async () => {
      setCargandoReporte(true);
      await calcularReportePreventistas(fechaDesde || null, fechaHasta || null);
      setCargandoReporte(false);
      setReporteGenerado(true);
    };

    const handleLimpiarFiltros = async () => {
      setFechaDesde('');
      setFechaHasta('');
      setCargandoReporte(true);
      await calcularReportePreventistas(null, null);
      setCargandoReporte(false);
    };

    return (
      <div className="space-y-4">
        <h1 className="text-2xl font-bold">Reportes por Preventista</h1>

        {/* Filtros */}
        <div className="bg-white border rounded-lg shadow-sm p-4">
          <h2 className="font-semibold mb-3">Filtrar por Fecha</h2>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
            <div>
              <label className="block text-sm font-medium mb-1">Desde</label>
              <input
                type="date"
                value={fechaDesde}
                onChange={e => setFechaDesde(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Hasta</label>
              <input
                type="date"
                value={fechaHasta}
                onChange={e => setFechaHasta(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg"
              />
            </div>
            <div className="flex gap-2">
              <button
                onClick={handleGenerarReporte}
                disabled={cargandoReporte}
                className="flex items-center justify-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50"
              >
                {cargandoReporte ? <Loader2 className="w-5 h-5 animate-spin" /> : <BarChart3 className="w-5 h-5" />}
                <span>Generar Reporte</span>
              </button>
              {(fechaDesde || fechaHasta) && (
                <button
                  onClick={handleLimpiarFiltros}
                  disabled={cargandoReporte}
                  className="flex items-center justify-center space-x-2 px-4 py-2 bg-gray-500 text-white rounded-lg hover:bg-gray-600 disabled:opacity-50"
                >
                  <X className="w-5 h-5" />
                  <span>Limpiar</span>
                </button>
              )}
            </div>
          </div>
          {(fechaDesde || fechaHasta) && (
            <div className="mt-2 text-sm text-gray-600">
              Filtrando desde {fechaDesde || '(sin límite)'} hasta {fechaHasta || '(sin límite)'}
            </div>
          )}
        </div>

        {/* Tabla de reportes */}
        {cargandoReporte ? (
          <LoadingSpinner />
        ) : reportePreventistas.length === 0 ? (
          <div className="text-center py-12 text-gray-500 bg-white border rounded-lg shadow-sm">
            <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" />
            <p className="font-semibold">No hay datos para mostrar</p>
            <p className="text-sm mt-2">No se encontraron pedidos con preventistas asignados en el rango seleccionado</p>
            <p className="text-sm mt-1 text-blue-600">Verifica que los pedidos tengan un usuario (preventista) asignado</p>
          </div>
        ) : (
          <div className="bg-white border rounded-lg shadow-sm overflow-x-auto">
            <table className="w-full">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-4 py-3 text-left text-sm font-medium">Preventista</th>
                  <th className="px-4 py-3 text-right text-sm font-medium">Total Ventas</th>
                  <th className="px-4 py-3 text-right text-sm font-medium">Cant. Pedidos</th>
                  <th className="px-4 py-3 text-right text-sm font-medium">Pendientes</th>
                  <th className="px-4 py-3 text-right text-sm font-medium">En Camino</th>
                  <th className="px-4 py-3 text-right text-sm font-medium">Entregados</th>
                  <th className="px-4 py-3 text-right text-sm font-medium">Total Pagado</th>
                  <th className="px-4 py-3 text-right text-sm font-medium">Total Pendiente</th>
                </tr>
              </thead>
              <tbody className="divide-y">
                {reportePreventistas.map((preventista, index) => (
                  <tr key={preventista.id || index} className="hover:bg-gray-50">
                    <td className="px-4 py-3">
                      <div>
                        <p className="font-medium">{preventista.nombre}</p>
                        <p className="text-sm text-gray-500">{preventista.email}</p>
                      </div>
                    </td>
                    <td className="px-4 py-3 text-right font-bold text-blue-600">
                      {formatPrecio(preventista.totalVentas)}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <span className="px-2 py-1 bg-purple-100 text-purple-700 rounded-full text-sm">
                        {preventista.cantidadPedidos}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <span className="px-2 py-1 bg-yellow-100 text-yellow-700 rounded-full text-sm">
                        {preventista.pedidosPendientes}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <span className="px-2 py-1 bg-blue-100 text-blue-700 rounded-full text-sm">
                        {preventista.pedidosAsignados}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right">
                      <span className="px-2 py-1 bg-green-100 text-green-700 rounded-full text-sm">
                        {preventista.pedidosEntregados}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right font-semibold text-green-600">
                      {formatPrecio(preventista.totalPagado)}
                    </td>
                    <td className="px-4 py-3 text-right font-semibold text-red-600">
                      {formatPrecio(preventista.totalPendiente)}
                    </td>
                  </tr>
                ))}
              </tbody>
              <tfoot className="bg-gray-50 font-bold">
                <tr>
                  <td className="px-4 py-3">TOTAL</td>
                  <td className="px-4 py-3 text-right text-blue-600">
                    {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalVentas, 0))}
                  </td>
                  <td className="px-4 py-3 text-right">
                    {reportePreventistas.reduce((sum, p) => sum + p.cantidadPedidos, 0)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    {reportePreventistas.reduce((sum, p) => sum + p.pedidosPendientes, 0)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    {reportePreventistas.reduce((sum, p) => sum + p.pedidosAsignados, 0)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    {reportePreventistas.reduce((sum, p) => sum + p.pedidosEntregados, 0)}
                  </td>
                  <td className="px-4 py-3 text-right text-green-600">
                    {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalPagado, 0))}
                  </td>
                  <td className="px-4 py-3 text-right text-red-600">
                    {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalPendiente, 0))}
                  </td>
                </tr>
              </tfoot>
            </table>
          </div>
        )}
      </div>
    );
  };

  const VistaUsuarios = () => (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold">Usuarios</h1>
      <p className="text-gray-600">Para crear usuarios, hacelo desde Supabase → Authentication → Users</p>
      {loadingUsuarios ? <LoadingSpinner /> : usuarios.length === 0 ? (<div className="text-center py-12 text-gray-500"><UserCog className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay usuarios</p></div>) : (
        <div className="bg-white border rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50"><tr><th className="px-4 py-3 text-left text-sm font-medium">Nombre</th><th className="px-4 py-3 text-left text-sm font-medium">Email</th><th className="px-4 py-3 text-left text-sm font-medium">Rol</th><th className="px-4 py-3 text-left text-sm font-medium">Estado</th><th className="px-4 py-3 text-right text-sm font-medium">Acciones</th></tr></thead>
            <tbody className="divide-y">
              {usuarios.map(u => (<tr key={u.id} className="hover:bg-gray-50"><td className="px-4 py-3 font-medium">{u.nombre}</td><td className="px-4 py-3 text-gray-600">{u.email}</td><td className="px-4 py-3"><span className={`px-2 py-1 rounded-full text-sm ${getRolColor(u.rol)}`}>{getRolLabel(u.rol)}</span></td><td className="px-4 py-3"><span className={`px-2 py-1 rounded-full text-sm ${u.activo ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'}`}>{u.activo ? 'Activo' : 'Inactivo'}</span></td><td className="px-4 py-3 text-right"><button onClick={() => { setUsuarioEditando(u); setModalUsuario(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button></td></tr>))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );

  return (
    <div className="min-h-screen bg-gray-100">
      <Navegacion />
      <main className="max-w-7xl mx-auto px-4 py-6">
        {vista === 'dashboard' && isAdmin && <VistaDashboard />}
        {vista === 'pedidos' && <VistaPedidos />}
        {vista === 'clientes' && <VistaClientes />}
        {vista === 'productos' && <VistaProductos />}
        {vista === 'reportes' && isAdmin && <VistaReportes />}
        {vista === 'usuarios' && isAdmin && <VistaUsuarios />}
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
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <ToastProvider>
        <AppContent />
      </ToastProvider>
    </AuthProvider>
  );
}

function AppContent() {
  const { user, loading } = useAuth();
  if (loading) return <div className="min-h-screen bg-gray-100 flex items-center justify-center"><Loader2 className="w-8 h-8 animate-spin text-blue-600" /></div>;
  return user ? <MainApp /> : <LoginScreen />;
}
