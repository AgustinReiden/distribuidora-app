import React, { useState } from 'react';
import { Package, Users, ShoppingCart, Truck, Plus, Edit2, Trash2, Check, Clock, Search, X, Menu, Loader2, LogOut, UserCog, AlertTriangle, User } from 'lucide-react';
import { AuthProvider, useAuth, useClientes, useProductos, usePedidos, useUsuarios } from './hooks/useSupabase.jsx';

// ==================== PANTALLA DE LOGIN ====================
function LoginScreen() {
  const { login } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      await login(email, password);
    } catch (err) {
      setError('Email o contraseña incorrectos');
    }
    setLoading(false);
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-blue-600 to-blue-800 flex items-center justify-center p-4">
      <div className="bg-white rounded-2xl shadow-2xl w-full max-w-md p-8">
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-blue-100 rounded-full mb-4">
            <Truck className="w-8 h-8 text-blue-600" />
          </div>
          <h1 className="text-2xl font-bold text-gray-800">Distribuidora</h1>
          <p className="text-gray-500 mt-1">Ingresá con tu cuenta</p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          {error && <div className="bg-red-50 text-red-600 px-4 py-3 rounded-lg text-sm">{error}</div>}
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Email</label>
            <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="w-full px-4 py-3 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500" placeholder="tu@email.com" required />
          </div>
          <div>
            <label className="block text-sm font-medium text-gray-700 mb-1">Contraseña</label>
            <input type="password" value={password} onChange={(e) => setPassword(e.target.value)} className="w-full px-4 py-3 border rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500" placeholder="••••••••" required />
          </div>
          <button type="submit" disabled={loading} className="w-full py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors font-medium flex items-center justify-center">
            {loading ? <Loader2 className="w-5 h-5 animate-spin" /> : 'Ingresar'}
          </button>
        </form>
      </div>
    </div>
  );
}

// ==================== APP PRINCIPAL ====================
function MainApp() {
  const { user, perfil, logout, isAdmin, isPreventista, isTransportista } = useAuth();
  const [vista, setVista] = useState('pedidos');
  const [menuAbierto, setMenuAbierto] = useState(false);
  
  const { clientes, loading: loadingClientes, agregarCliente, actualizarCliente, eliminarCliente, refetch: refetchClientes } = useClientes();
  const { productos, loading: loadingProductos, agregarProducto, actualizarProducto, eliminarProducto } = useProductos();
  const { pedidos, loading: loadingPedidos, crearPedido, cambiarEstado, asignarTransportista, eliminarPedido, refetch: refetchPedidos } = usePedidos();
  const { usuarios, transportistas, loading: loadingUsuarios, actualizarUsuario } = useUsuarios();
  
  const [modalCliente, setModalCliente] = useState(false);
  const [modalProducto, setModalProducto] = useState(false);
  const [modalPedido, setModalPedido] = useState(false);
  const [modalUsuario, setModalUsuario] = useState(false);
  const [modalAsignar, setModalAsignar] = useState(false);
  const [modalConfirm, setModalConfirm] = useState({ visible: false, mensaje: '', titulo: '', onConfirm: null, tipo: 'danger' });
  
  const [clienteEditando, setClienteEditando] = useState(null);
  const [productoEditando, setProductoEditando] = useState(null);
  const [usuarioEditando, setUsuarioEditando] = useState(null);
  const [pedidoAsignando, setPedidoAsignando] = useState(null);
  
  const [nuevoPedido, setNuevoPedido] = useState({ clienteId: '', items: [] });
  const [filtroEstado, setFiltroEstado] = useState('todos');
  const [busqueda, setBusqueda] = useState('');
  const [guardando, setGuardando] = useState(false);

  const handleLogout = async () => {
    try { await logout(); } catch (error) { console.error('Error al cerrar sesión:', error); }
  };

  // HANDLERS CLIENTES
  const handleGuardarCliente = async (cliente) => {
    setGuardando(true);
    try {
      if (cliente.id) { await actualizarCliente(cliente.id, cliente); } 
      else { await agregarCliente(cliente); }
      setModalCliente(false);
      setClienteEditando(null);
    } catch (error) { alert('Error al guardar cliente: ' + error.message); }
    setGuardando(false);
  };

  const handleEliminarCliente = (id) => {
    setModalConfirm({
      visible: true, titulo: 'Eliminar cliente',
      mensaje: '¿Estás seguro de eliminar este cliente? Esta acción no se puede deshacer.',
      tipo: 'danger',
      onConfirm: async () => {
        try { await eliminarCliente(id); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', titulo: '', onConfirm: null, tipo: 'danger' });
      }
    });
  };

  // HANDLERS PRODUCTOS
  const handleGuardarProducto = async (producto) => {
    setGuardando(true);
    try {
      if (producto.id) { await actualizarProducto(producto.id, producto); } 
      else { await agregarProducto(producto); }
      setModalProducto(false);
      setProductoEditando(null);
    } catch (error) { alert('Error al guardar producto: ' + error.message); }
    setGuardando(false);
  };

  const handleEliminarProducto = (id) => {
    setModalConfirm({
      visible: true, titulo: 'Eliminar producto',
      mensaje: '¿Estás seguro de eliminar este producto? Esta acción no se puede deshacer.',
      tipo: 'danger',
      onConfirm: async () => {
        try { await eliminarProducto(id); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', titulo: '', onConfirm: null, tipo: 'danger' });
      }
    });
  };

  // HANDLERS USUARIOS
  const handleGuardarUsuario = async (usuario) => {
    setGuardando(true);
    try {
      await actualizarUsuario(usuario.id, usuario);
      setModalUsuario(false);
      setUsuarioEditando(null);
    } catch (error) { alert('Error al guardar usuario: ' + error.message); }
    setGuardando(false);
  };

  // HANDLERS PEDIDOS
  const agregarItemPedido = (productoId) => {
    const existe = nuevoPedido.items.find(i => i.productoId === productoId);
    const producto = productos.find(p => p.id === productoId);
    if (existe) {
      setNuevoPedido({ ...nuevoPedido, items: nuevoPedido.items.map(i => i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i) });
    } else {
      setNuevoPedido({ ...nuevoPedido, items: [...nuevoPedido.items, { productoId, cantidad: 1, precioUnitario: producto?.precio || 0 }] });
    }
  };

  const actualizarCantidadItem = (productoId, cantidad) => {
    if (cantidad <= 0) {
      setNuevoPedido({ ...nuevoPedido, items: nuevoPedido.items.filter(i => i.productoId !== productoId) });
    } else {
      setNuevoPedido({ ...nuevoPedido, items: nuevoPedido.items.map(i => i.productoId === productoId ? { ...i, cantidad } : i) });
    }
  };

  const calcularTotalPedido = (items) => items.reduce((total, item) => total + (item.precioUnitario * item.cantidad), 0);

  const handleGuardarPedido = async () => {
    if (!nuevoPedido.clienteId || nuevoPedido.items.length === 0) {
      alert('Seleccioná un cliente y al menos un producto');
      return;
    }
    setGuardando(true);
    try {
      await crearPedido(parseInt(nuevoPedido.clienteId), nuevoPedido.items, calcularTotalPedido(nuevoPedido.items), user.id);
      setNuevoPedido({ clienteId: '', items: [] });
      setModalPedido(false);
    } catch (error) { alert('Error al crear pedido: ' + error.message); }
    setGuardando(false);
  };

  const handleMarcarEntregado = (pedido) => {
    setModalConfirm({
      visible: true, titulo: 'Confirmar entrega',
      mensaje: `¿Confirmás que el pedido #${pedido.id} para "${pedido.cliente?.nombre_fantasia}" fue entregado correctamente?`,
      tipo: 'success',
      onConfirm: async () => {
        try { await cambiarEstado(pedido.id, 'entregado'); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', titulo: '', onConfirm: null, tipo: 'danger' });
      }
    });
  };

  const handleDesmarcarEntregado = (pedido) => {
    setModalConfirm({
      visible: true, titulo: 'Revertir entrega',
      mensaje: `¿Estás seguro de marcar el pedido #${pedido.id} como NO entregado? Esto revertirá el estado del pedido.`,
      tipo: 'warning',
      onConfirm: async () => {
        try { await cambiarEstado(pedido.id, pedido.transportista_id ? 'asignado' : 'pendiente'); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', titulo: '', onConfirm: null, tipo: 'danger' });
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
    } catch (error) { alert('Error al asignar transportista: ' + error.message); }
    setGuardando(false);
  };

  const handleEliminarPedido = (id) => {
    setModalConfirm({
      visible: true, titulo: 'Eliminar pedido',
      mensaje: '¿Estás seguro de eliminar este pedido? Esta acción no se puede deshacer.',
      tipo: 'danger',
      onConfirm: async () => {
        try { await eliminarPedido(id); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', titulo: '', onConfirm: null, tipo: 'danger' });
      }
    });
  };

  // FILTROS
  const pedidosFiltrados = pedidos.filter(p => {
    const cliente = p.cliente;
    const coincideBusqueda = !busqueda || 
      cliente?.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase()) ||
      cliente?.direccion?.toLowerCase().includes(busqueda.toLowerCase());
    const coincideEstado = filtroEstado === 'todos' || p.estado === filtroEstado;
    return coincideBusqueda && coincideEstado;
  });

  // HELPERS
  const formatPrecio = (precio) => new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(precio || 0);
  const formatFecha = (fecha) => fecha ? new Date(fecha).toLocaleDateString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
  
  const getEstadoColor = (estado) => {
    switch (estado) {
      case 'pendiente': return 'bg-yellow-100 text-yellow-800';
      case 'asignado': return 'bg-blue-100 text-blue-800';
      case 'entregado': return 'bg-green-100 text-green-800';
      default: return 'bg-gray-100 text-gray-800';
    }
  };

  const getEstadoLabel = (estado) => {
    switch (estado) {
      case 'pendiente': return 'Pendiente';
      case 'asignado': return 'En camino';
      case 'entregado': return 'Entregado';
      default: return estado;
    }
  };

  const getRolColor = (rol) => {
    switch (rol) {
      case 'admin': return 'bg-purple-100 text-purple-700';
      case 'preventista': return 'bg-blue-100 text-blue-700';
      case 'transportista': return 'bg-orange-100 text-orange-700';
      default: return 'bg-gray-100 text-gray-700';
    }
  };

  const getRolLabel = (rol) => {
    switch (rol) {
      case 'admin': return 'Admin';
      case 'preventista': return 'Preventista';
      case 'transportista': return 'Transportista';
      default: return rol;
    }
  };

  const LoadingSpinner = () => (
    <div className="flex items-center justify-center py-12">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
      <span className="ml-2 text-gray-600">Cargando...</span>
    </div>
  );

  // MENÚ
  const menuItems = [
    { id: 'pedidos', icon: ShoppingCart, label: 'Pedidos', roles: ['admin', 'preventista', 'transportista'] },
    { id: 'clientes', icon: Users, label: 'Clientes', roles: ['admin', 'preventista'] },
    { id: 'productos', icon: Package, label: 'Productos', roles: ['admin', 'preventista'] },
    { id: 'usuarios', icon: UserCog, label: 'Usuarios', roles: ['admin'] },
  ].filter(item => item.roles.includes(perfil?.rol));

  // NAVEGACIÓN
  const Navegacion = () => (
    <nav className="bg-blue-600 text-white shadow-lg">
      <div className="max-w-7xl mx-auto px-4">
        <div className="flex justify-between items-center h-16">
          <div className="flex items-center space-x-2">
            <Truck className="w-8 h-8" />
            <span className="font-bold text-xl hidden sm:block">Distribuidora</span>
          </div>
          <div className="hidden md:flex items-center space-x-1">
            {menuItems.map(item => (
              <button key={item.id} onClick={() => setVista(item.id)} className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-colors ${vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'}`}>
                <item.icon className="w-5 h-5" /><span>{item.label}</span>
              </button>
            ))}
            <div className="ml-4 pl-4 border-l border-blue-400 flex items-center space-x-3">
              <span className="text-sm">{perfil?.nombre}</span>
              <span className={`text-xs px-2 py-1 rounded ${getRolColor(perfil?.rol)}`}>{getRolLabel(perfil?.rol)}</span>
              <button onClick={handleLogout} className="p-2 hover:bg-blue-500 rounded-lg" title="Cerrar sesión"><LogOut className="w-5 h-5" /></button>
            </div>
          </div>
          <button className="md:hidden p-2" onClick={() => setMenuAbierto(!menuAbierto)}><Menu className="w-6 h-6" /></button>
        </div>
        {menuAbierto && (
          <div className="md:hidden pb-4 space-y-2">
            {menuItems.map(item => (
              <button key={item.id} onClick={() => { setVista(item.id); setMenuAbierto(false); }} className={`flex items-center space-x-2 w-full px-4 py-2 rounded-lg ${vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'}`}>
                <item.icon className="w-5 h-5" /><span>{item.label}</span>
              </button>
            ))}
            <div className="pt-2 mt-2 border-t border-blue-400">
              <div className="px-4 py-2 text-sm flex items-center space-x-2">
                <span>{perfil?.nombre}</span>
                <span className={`text-xs px-2 py-1 rounded ${getRolColor(perfil?.rol)}`}>{getRolLabel(perfil?.rol)}</span>
              </div>
              <button onClick={handleLogout} className="flex items-center space-x-2 w-full px-4 py-2 hover:bg-blue-500 rounded-lg">
                <LogOut className="w-5 h-5" /><span>Cerrar sesión</span>
              </button>
            </div>
          </div>
        )}
      </div>
    </nav>
  );

  // MODAL CONFIRMACIÓN
  const ModalConfirmacion = () => modalConfirm.visible && (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-sm">
        <div className="p-6">
          <div className={`flex items-center justify-center w-12 h-12 mx-auto mb-4 rounded-full ${modalConfirm.tipo === 'danger' ? 'bg-red-100' : modalConfirm.tipo === 'warning' ? 'bg-yellow-100' : 'bg-green-100'}`}>
            {modalConfirm.tipo === 'danger' ? <Trash2 className="w-6 h-6 text-red-600" /> : modalConfirm.tipo === 'warning' ? <AlertTriangle className="w-6 h-6 text-yellow-600" /> : <Check className="w-6 h-6 text-green-600" />}
          </div>
          <h3 className="text-lg font-semibold text-center text-gray-900 mb-2">{modalConfirm.titulo}</h3>
          <p className="text-center text-gray-600">{modalConfirm.mensaje}</p>
        </div>
        <div className="flex border-t">
          <button onClick={() => setModalConfirm({ visible: false, mensaje: '', titulo: '', onConfirm: null, tipo: 'danger' })} className="flex-1 px-4 py-3 text-gray-700 font-medium hover:bg-gray-50 rounded-bl-xl">Cancelar</button>
          <button onClick={modalConfirm.onConfirm} className={`flex-1 px-4 py-3 font-medium border-l rounded-br-xl ${modalConfirm.tipo === 'danger' ? 'text-red-600 hover:bg-red-50' : modalConfirm.tipo === 'warning' ? 'text-yellow-600 hover:bg-yellow-50' : 'text-green-600 hover:bg-green-50'}`}>Confirmar</button>
        </div>
      </div>
    </div>
  );

  // MODAL CLIENTE
  const ModalCliente = () => {
    const [form, setForm] = useState(clienteEditando ? { nombre: clienteEditando.nombre, nombreFantasia: clienteEditando.nombre_fantasia, direccion: clienteEditando.direccion, telefono: clienteEditando.telefono || '', zona: clienteEditando.zona || '' } : { nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });
    return (
      <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
        <div className="bg-white rounded-xl shadow-xl w-full max-w-md max-h-[90vh] overflow-y-auto">
          <div className="flex justify-between items-center p-4 border-b sticky top-0 bg-white">
            <h2 className="text-xl font-semibold">{clienteEditando ? 'Editar Cliente' : 'Nuevo Cliente'}</h2>
            <button onClick={() => { setModalCliente(false); setClienteEditando(null); }}><X className="w-6 h-6 text-gray-500" /></button>
          </div>
          <div className="p-4 space-y-4">
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Nombre Completo *</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Juan Pérez" /></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Nombre de Fantasía *</label><input type="text" value={form.nombreFantasia} onChange={e => setForm({ ...form, nombreFantasia: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Kiosco Don Juan" /></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Dirección *</label><input type="text" value={form.direccion} onChange={e => setForm({ ...form, direccion: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Av. San Martín 1234" /></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Teléfono</label><input type="text" value={form.telefono} onChange={e => setForm({ ...form, telefono: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="11-5555-1234" /></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Zona</label><input type="text" value={form.zona} onChange={e => setForm({ ...form, zona: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Centro / Norte / Sur" /></div>
          </div>
          <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 rounded-b-xl">
            <button onClick={() => { setModalCliente(false); setClienteEditando(null); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg" disabled={guardando}>Cancelar</button>
            <button onClick={() => handleGuardarCliente({ ...form, id: clienteEditando?.id })} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center" disabled={guardando || !form.nombre || !form.nombreFantasia || !form.direccion}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar</button>
          </div>
        </div>
      </div>
    );
  };

  // MODAL PRODUCTO
  const ModalProducto = () => {
    const [form, setForm] = useState(productoEditando || { nombre: '', precio: '', stock: '', categoria: '' });
    return (
      <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
        <div className="bg-white rounded-xl shadow-xl w-full max-w-md">
          <div className="flex justify-between items-center p-4 border-b">
            <h2 className="text-xl font-semibold">{productoEditando ? 'Editar Producto' : 'Nuevo Producto'}</h2>
            <button onClick={() => { setModalProducto(false); setProductoEditando(null); }}><X className="w-6 h-6 text-gray-500" /></button>
          </div>
          <div className="p-4 space-y-4">
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Nombre del Producto *</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Coca-Cola 2.25L" /></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Categoría</label><input type="text" value={form.categoria} onChange={e => setForm({ ...form, categoria: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Gaseosas" /></div>
            <div className="grid grid-cols-2 gap-4">
              <div><label className="block text-sm font-medium text-gray-700 mb-1">Precio *</label><input type="number" value={form.precio} onChange={e => setForm({ ...form, precio: parseFloat(e.target.value) || '' })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="1500" /></div>
              <div><label className="block text-sm font-medium text-gray-700 mb-1">Stock *</label><input type="number" value={form.stock} onChange={e => setForm({ ...form, stock: parseInt(e.target.value) || '' })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="100" /></div>
            </div>
          </div>
          <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 rounded-b-xl">
            <button onClick={() => { setModalProducto(false); setProductoEditando(null); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg" disabled={guardando}>Cancelar</button>
            <button onClick={() => handleGuardarProducto({ ...form, id: productoEditando?.id })} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center" disabled={guardando || !form.nombre || !form.precio || form.stock === ''}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar</button>
          </div>
        </div>
      </div>
    );
  };

  // MODAL USUARIO
  const ModalUsuario = () => {
    const [form, setForm] = useState(usuarioEditando || { nombre: '', rol: 'preventista', activo: true });
    return (
      <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
        <div className="bg-white rounded-xl shadow-xl w-full max-w-md">
          <div className="flex justify-between items-center p-4 border-b">
            <h2 className="text-xl font-semibold">Editar Usuario</h2>
            <button onClick={() => { setModalUsuario(false); setUsuarioEditando(null); }}><X className="w-6 h-6 text-gray-500" /></button>
          </div>
          <div className="p-4 space-y-4">
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Email</label><input type="email" value={form.email} disabled className="w-full px-3 py-2 border rounded-lg bg-gray-100 text-gray-500" /></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Nombre</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" /></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Rol</label>
              <select value={form.rol} onChange={e => setForm({ ...form, rol: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500">
                <option value="preventista">Preventista</option>
                <option value="transportista">Transportista</option>
                <option value="admin">Administrador</option>
              </select>
            </div>
            <div className="flex items-center space-x-2">
              <input type="checkbox" id="activo" checked={form.activo} onChange={e => setForm({ ...form, activo: e.target.checked })} className="w-4 h-4 text-blue-600 rounded" />
              <label htmlFor="activo" className="text-sm text-gray-700">Usuario activo</label>
            </div>
          </div>
          <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 rounded-b-xl">
            <button onClick={() => { setModalUsuario(false); setUsuarioEditando(null); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg" disabled={guardando}>Cancelar</button>
            <button onClick={() => handleGuardarUsuario({ ...form, id: usuarioEditando?.id })} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center" disabled={guardando}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar</button>
          </div>
        </div>
      </div>
    );
  };

  // MODAL ASIGNAR TRANSPORTISTA
  const ModalAsignarTransportista = () => {
    const [transportistaSeleccionado, setTransportistaSeleccionado] = useState(pedidoAsignando?.transportista_id || '');
    return (
      <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
        <div className="bg-white rounded-xl shadow-xl w-full max-w-md">
          <div className="flex justify-between items-center p-4 border-b">
            <h2 className="text-xl font-semibold">Asignar Transportista</h2>
            <button onClick={() => { setModalAsignar(false); setPedidoAsignando(null); }}><X className="w-6 h-6 text-gray-500" /></button>
          </div>
          <div className="p-4 space-y-4">
            <div className="bg-gray-50 rounded-lg p-3">
              <p className="text-sm text-gray-600">Pedido #{pedidoAsignando?.id}</p>
              <p className="font-medium">{pedidoAsignando?.cliente?.nombre_fantasia}</p>
              <p className="text-sm text-gray-500">{pedidoAsignando?.cliente?.direccion}</p>
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Transportista</label>
              <select value={transportistaSeleccionado} onChange={e => setTransportistaSeleccionado(e.target.value)} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500">
                <option value="">Sin asignar</option>
                {transportistas.map(t => (<option key={t.id} value={t.id}>{t.nombre}</option>))}
              </select>
              {transportistas.length === 0 && <p className="text-sm text-yellow-600 mt-2">No hay transportistas activos. Creá uno desde la sección Usuarios.</p>}
            </div>
          </div>
          <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 rounded-b-xl">
            <button onClick={() => { setModalAsignar(false); setPedidoAsignando(null); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg" disabled={guardando}>Cancelar</button>
            <button onClick={() => handleAsignarTransportista(transportistaSeleccionado)} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center" disabled={guardando}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar</button>
          </div>
        </div>
      </div>
    );
  };

  // MODAL PEDIDO
  const ModalPedido = () => {
    const [busquedaProducto, setBusquedaProducto] = useState('');
    const [busquedaCliente, setBusquedaCliente] = useState('');
    const [mostrarNuevoCliente, setMostrarNuevoCliente] = useState(false);
    const [nuevoCliente, setNuevoCliente] = useState({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });
    
    const productosFiltradosModal = productos.filter(p => p.nombre.toLowerCase().includes(busquedaProducto.toLowerCase()) || (p.categoria && p.categoria.toLowerCase().includes(busquedaProducto.toLowerCase())));
    const clientesFiltradosModal = clientes.filter(c => c.nombre_fantasia.toLowerCase().includes(busquedaCliente.toLowerCase()) || c.direccion.toLowerCase().includes(busquedaCliente.toLowerCase()) || c.nombre.toLowerCase().includes(busquedaCliente.toLowerCase()) || (c.zona && c.zona.toLowerCase().includes(busquedaCliente.toLowerCase())));
    const clienteSeleccionado = clientes.find(c => c.id === parseInt(nuevoPedido.clienteId));

    const handleCrearClienteRapido = async () => {
      if (!nuevoCliente.nombre || !nuevoCliente.nombreFantasia || !nuevoCliente.direccion) { alert('Completá nombre, nombre de fantasía y dirección'); return; }
      setGuardando(true);
      try {
        const cliente = await agregarCliente(nuevoCliente);
        setNuevoPedido({ ...nuevoPedido, clienteId: cliente.id.toString() });
        setMostrarNuevoCliente(false);
        setNuevoCliente({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });
      } catch (error) { alert('Error al crear cliente: ' + error.message); }
      setGuardando(false);
    };

    return (
      <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
        <div className="bg-white rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-hidden flex flex-col">
          <div className="flex justify-between items-center p-4 border-b">
            <h2 className="text-xl font-semibold">Nuevo Pedido</h2>
            <button onClick={() => { setModalPedido(false); setNuevoPedido({ clienteId: '', items: [] }); }}><X className="w-6 h-6 text-gray-500" /></button>
          </div>
          
          <div className="flex-1 overflow-y-auto p-4 space-y-4">
            {/* Cliente */}
            <div>
              <div className="flex justify-between items-center mb-1">
                <label className="block text-sm font-medium text-gray-700">Cliente *</label>
                {(isAdmin || isPreventista) && <button onClick={() => setMostrarNuevoCliente(!mostrarNuevoCliente)} className="text-sm text-blue-600 hover:text-blue-800">{mostrarNuevoCliente ? 'Cancelar' : '+ Nuevo cliente'}</button>}
              </div>
              
              {mostrarNuevoCliente ? (
                <div className="border rounded-lg p-3 space-y-3 bg-blue-50">
                  <input type="text" value={nuevoCliente.nombreFantasia} onChange={e => setNuevoCliente({ ...nuevoCliente, nombreFantasia: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Nombre de fantasía *" />
                  <input type="text" value={nuevoCliente.nombre} onChange={e => setNuevoCliente({ ...nuevoCliente, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Nombre completo *" />
                  <input type="text" value={nuevoCliente.direccion} onChange={e => setNuevoCliente({ ...nuevoCliente, direccion: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Dirección *" />
                  <div className="grid grid-cols-2 gap-2">
                    <input type="text" value={nuevoCliente.telefono} onChange={e => setNuevoCliente({ ...nuevoCliente, telefono: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Teléfono" />
                    <input type="text" value={nuevoCliente.zona} onChange={e => setNuevoCliente({ ...nuevoCliente, zona: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Zona" />
                  </div>
                  <button onClick={handleCrearClienteRapido} className="w-full py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center justify-center" disabled={guardando}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Crear y seleccionar</button>
                </div>
              ) : (
                <>
                  <div className="relative">
                    <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
                    <input type="text" value={busquedaCliente} onChange={e => setBusquedaCliente(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Buscar cliente..." />
                  </div>
                  {clienteSeleccionado ? (
                    <div className="mt-2 p-3 bg-blue-50 border border-blue-200 rounded-lg flex justify-between items-center">
                      <div><p className="font-medium">{clienteSeleccionado.nombre_fantasia}</p><p className="text-sm text-gray-600">{clienteSeleccionado.direccion}</p></div>
                      <button onClick={() => setNuevoPedido({ ...nuevoPedido, clienteId: '' })} className="text-red-500 hover:bg-red-50 p-1 rounded"><X className="w-5 h-5" /></button>
                    </div>
                  ) : (
                    <div className="border rounded-lg max-h-40 overflow-y-auto mt-2">
                      {clientesFiltradosModal.length === 0 ? (<div className="p-3 text-center text-gray-500">No se encontraron clientes</div>) : (
                        clientesFiltradosModal.slice(0, 10).map(c => (
                          <div key={c.id} className="p-3 hover:bg-gray-50 border-b last:border-b-0 cursor-pointer" onClick={() => { setNuevoPedido({ ...nuevoPedido, clienteId: c.id.toString() }); setBusquedaCliente(''); }}>
                            <p className="font-medium">{c.nombre_fantasia}</p>
                            <p className="text-sm text-gray-500">{c.direccion} {c.zona && `• ${c.zona}`}</p>
                          </div>
                        ))
                      )}
                    </div>
                  )}
                </>
              )}
            </div>

            {/* Productos */}
            <div>
              <label className="block text-sm font-medium text-gray-700 mb-1">Agregar Productos</label>
              <div className="relative">
                <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
                <input type="text" value={busquedaProducto} onChange={e => setBusquedaProducto(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Buscar producto..." />
              </div>
            </div>
            
            <div className="border rounded-lg max-h-48 overflow-y-auto">
              {productosFiltradosModal.map(p => (
                <div key={p.id} className="flex justify-between items-center p-3 hover:bg-gray-50 border-b last:border-b-0 cursor-pointer" onClick={() => agregarItemPedido(p.id)}>
                  <div><p className="font-medium">{p.nombre}</p><p className="text-sm text-gray-500">{p.categoria} • Stock: {p.stock}</p></div>
                  <div className="text-right"><p className="font-semibold text-blue-600">{formatPrecio(p.precio)}</p><span className="text-sm text-blue-500">+ Agregar</span></div>
                </div>
              ))}
            </div>
            
            {nuevoPedido.items.length > 0 && (
              <div>
                <h3 className="font-medium text-gray-700 mb-2">Productos en el pedido</h3>
                <div className="border rounded-lg divide-y">
                  {nuevoPedido.items.map(item => { 
                    const producto = productos.find(p => p.id === item.productoId); 
                    return (
                      <div key={item.productoId} className="flex justify-between items-center p-3">
                        <div className="flex-1"><p className="font-medium">{producto?.nombre}</p><p className="text-sm text-gray-500">{formatPrecio(item.precioUnitario)} c/u</p></div>
                        <div className="flex items-center space-x-3">
                          <button onClick={() => actualizarCantidadItem(item.productoId, item.cantidad - 1)} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300 flex items-center justify-center">-</button>
                          <span className="w-8 text-center font-medium">{item.cantidad}</span>
                          <button onClick={() => actualizarCantidadItem(item.productoId, item.cantidad + 1)} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300 flex items-center justify-center">+</button>
                          <p className="w-24 text-right font-semibold">{formatPrecio(item.precioUnitario * item.cantidad)}</p>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
          
          <div className="border-t bg-gray-50 p-4">
            <div className="flex justify-between items-center mb-4"><span className="text-lg font-medium">Total del Pedido</span><span className="text-2xl font-bold text-blue-600">{formatPrecio(calcularTotalPedido(nuevoPedido.items))}</span></div>
            <div className="flex justify-end space-x-3">
              <button onClick={() => { setModalPedido(false); setNuevoPedido({ clienteId: '', items: [] }); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg" disabled={guardando}>Cancelar</button>
              <button onClick={handleGuardarPedido} className="px-6 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 flex items-center" disabled={guardando}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Confirmar Pedido</button>
            </div>
          </div>
        </div>
      </div>
    );
  };

  // VISTA PEDIDOS
  const VistaPedidos = () => (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <h1 className="text-2xl font-bold text-gray-800">Pedidos</h1>
        {(isAdmin || isPreventista) && <button onClick={() => setModalPedido(true)} className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700"><Plus className="w-5 h-5" /><span>Nuevo Pedido</span></button>}
      </div>
      
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1"><Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" /><input type="text" value={busqueda} onChange={e => setBusqueda(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Buscar por cliente..." /></div>
        <select value={filtroEstado} onChange={e => setFiltroEstado(e.target.value)} className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500">
          <option value="todos">Todos</option>
          <option value="pendiente">Pendientes</option>
          <option value="asignado">En camino</option>
          <option value="entregado">Entregados</option>
        </select>
      </div>
      
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Clock className="w-5 h-5 text-yellow-600" /><span className="text-yellow-800 font-medium">Pendientes</span></div><p className="text-2xl font-bold text-yellow-600 mt-1">{pedidos.filter(p => p.estado === 'pendiente').length}</p></div>
        <div className="bg-blue-50 border border-blue-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Truck className="w-5 h-5 text-blue-600" /><span className="text-blue-800 font-medium">En camino</span></div><p className="text-2xl font-bold text-blue-600 mt-1">{pedidos.filter(p => p.estado === 'asignado').length}</p></div>
        <div className="bg-green-50 border border-green-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Check className="w-5 h-5 text-green-600" /><span className="text-green-800 font-medium">Entregados</span></div><p className="text-2xl font-bold text-green-600 mt-1">{pedidos.filter(p => p.estado === 'entregado').length}</p></div>
        <div className="bg-purple-50 border border-purple-200 rounded-lg p-4"><div className="flex items-center space-x-2"><ShoppingCart className="w-5 h-5 text-purple-600" /><span className="text-purple-800 font-medium">Total</span></div><p className="text-2xl font-bold text-purple-600 mt-1">{pedidos.length}</p></div>
      </div>
      
      {loadingPedidos ? <LoadingSpinner /> : (
        <div className="space-y-3">
          {pedidosFiltrados.length === 0 ? (
            <div className="text-center py-12 text-gray-500"><ShoppingCart className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay pedidos</p></div>
          ) : pedidosFiltrados.map(pedido => (
            <div key={pedido.id} className="bg-white border rounded-lg shadow-sm p-4">
              <div className="flex justify-between items-start">
                <div>
                  <h3 className="font-semibold text-lg">{pedido.cliente?.nombre_fantasia || 'Sin cliente'}</h3>
                  <p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p>
                  <p className="text-sm text-gray-400 mt-1">
                    #{pedido.id} • {formatFecha(pedido.created_at)}
                    {pedido.usuario && <span className="text-blue-500"> • Creado por: {pedido.usuario.nombre}</span>}
                  </p>
                  {pedido.transportista && <p className="text-sm text-orange-600 mt-1">🚚 {pedido.transportista.nombre}</p>}
                  {pedido.fecha_entrega && <p className="text-sm text-green-600">✓ Entregado: {formatFecha(pedido.fecha_entrega)}</p>}
                </div>
                <span className={`px-3 py-1 rounded-full text-sm font-medium ${getEstadoColor(pedido.estado)}`}>{getEstadoLabel(pedido.estado)}</span>
              </div>
              
              <div className="mt-3 pt-3 border-t">
                <p className="text-sm text-gray-600 mb-2">{pedido.items?.map(item => <span key={item.id} className="mr-2">{item.producto?.nombre} x{item.cantidad}</span>)}</p>
                <div className="flex flex-wrap justify-between items-center gap-2">
                  <p className="text-lg font-bold text-blue-600">{formatPrecio(pedido.total)}</p>
                  <div className="flex flex-wrap gap-2">
                    {/* Admin: asignar transportista */}
                    {isAdmin && pedido.estado !== 'entregado' && (
                      <button onClick={() => { setPedidoAsignando(pedido); setModalAsignar(true); }} className="flex items-center space-x-1 px-3 py-1.5 bg-orange-500 text-white rounded-lg hover:bg-orange-600 text-sm">
                        <User className="w-4 h-4" /><span>{pedido.transportista ? 'Reasignar' : 'Asignar'}</span>
                      </button>
                    )}
                    
                    {/* Transportista: marcar entregado */}
                    {isTransportista && pedido.estado === 'asignado' && (
                      <button onClick={() => handleMarcarEntregado(pedido)} className="flex items-center space-x-1 px-3 py-1.5 bg-green-600 text-white rounded-lg hover:bg-green-700 text-sm">
                        <Check className="w-4 h-4" /><span>Marcar Entregado</span>
                      </button>
                    )}
                    
                    {/* Admin: marcar entregado o desmarcar */}
                    {isAdmin && pedido.estado === 'asignado' && (
                      <button onClick={() => handleMarcarEntregado(pedido)} className="flex items-center space-x-1 px-3 py-1.5 bg-green-600 text-white rounded-lg hover:bg-green-700 text-sm">
                        <Check className="w-4 h-4" /><span>Entregado</span>
                      </button>
                    )}
                    
                    {/* Solo Admin: desmarcar entregado */}
                    {isAdmin && pedido.estado === 'entregado' && (
                      <button onClick={() => handleDesmarcarEntregado(pedido)} className="flex items-center space-x-1 px-3 py-1.5 bg-yellow-500 text-white rounded-lg hover:bg-yellow-600 text-sm">
                        <AlertTriangle className="w-4 h-4" /><span>Revertir</span>
                      </button>
                    )}
                    
                    {/* Solo Admin: eliminar */}
                    {isAdmin && (
                      <button onClick={() => handleEliminarPedido(pedido.id)} className="p-1.5 text-red-500 hover:bg-red-50 rounded-lg">
                        <Trash2 className="w-5 h-5" />
                      </button>
                    )}
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );

  // VISTA CLIENTES
  const VistaClientes = () => (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-2xl font-bold text-gray-800">Clientes</h1>
        {(isAdmin || isPreventista) && <button onClick={() => setModalCliente(true)} className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"><Plus className="w-5 h-5" /><span>Nuevo Cliente</span></button>}
      </div>
      {loadingClientes ? <LoadingSpinner /> : clientes.length === 0 ? (
        <div className="text-center py-12 text-gray-500"><Users className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay clientes</p></div>
      ) : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {clientes.map(cliente => (
            <div key={cliente.id} className="bg-white border rounded-lg shadow-sm p-4">
              <div className="flex justify-between items-start">
                <div className="flex-1"><h3 className="font-semibold text-lg">{cliente.nombre_fantasia}</h3><p className="text-sm text-gray-600">{cliente.nombre}</p></div>
                {isAdmin && (
                  <div className="flex space-x-1">
                    <button onClick={() => { setClienteEditando(cliente); setModalCliente(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button>
                    <button onClick={() => handleEliminarCliente(cliente.id)} className="p-2 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-4 h-4" /></button>
                  </div>
                )}
              </div>
              <div className="mt-3 space-y-1 text-sm text-gray-500">
                <p>📍 {cliente.direccion}</p>
                {cliente.telefono && <p>📞 {cliente.telefono}</p>}
                {cliente.zona && <p>🗺️ {cliente.zona}</p>}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );

  // VISTA PRODUCTOS
  const VistaProductos = () => (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-2xl font-bold text-gray-800">Productos</h1>
        {isAdmin && <button onClick={() => setModalProducto(true)} className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"><Plus className="w-5 h-5" /><span>Nuevo Producto</span></button>}
      </div>
      {loadingProductos ? <LoadingSpinner /> : productos.length === 0 ? (
        <div className="text-center py-12 text-gray-500"><Package className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay productos</p></div>
      ) : (
        <div className="bg-white border rounded-lg shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead className="bg-gray-50"><tr><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Producto</th><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Categoría</th><th className="px-4 py-3 text-right text-sm font-medium text-gray-600">Precio</th><th className="px-4 py-3 text-right text-sm font-medium text-gray-600">Stock</th>{isAdmin && <th className="px-4 py-3 text-right text-sm font-medium text-gray-600">Acciones</th>}</tr></thead>
              <tbody className="divide-y">
                {productos.map(producto => (
                  <tr key={producto.id} className="hover:bg-gray-50">
                    <td className="px-4 py-3 font-medium">{producto.nombre}</td>
                    <td className="px-4 py-3 text-gray-600">{producto.categoria || '-'}</td>
                    <td className="px-4 py-3 text-right font-semibold text-blue-600">{formatPrecio(producto.precio)}</td>
                    <td className="px-4 py-3 text-right"><span className={`px-2 py-1 rounded-full text-sm ${producto.stock < 20 ? 'bg-red-100 text-red-700' : producto.stock < 50 ? 'bg-yellow-100 text-yellow-700' : 'bg-green-100 text-green-700'}`}>{producto.stock}</span></td>
                    {isAdmin && <td className="px-4 py-3 text-right"><div className="flex justify-end space-x-1"><button onClick={() => { setProductoEditando(producto); setModalProducto(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button><button onClick={() => handleEliminarProducto(producto.id)} className="p-2 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-4 h-4" /></button></div></td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );

  // VISTA USUARIOS
  const VistaUsuarios = () => (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-2xl font-bold text-gray-800">Usuarios</h1>
      </div>
      <p className="text-gray-600">Administrá los usuarios y sus permisos. Para crear nuevos usuarios, hacelo desde el panel de Supabase → Authentication → Users.</p>
      {loadingUsuarios ? <LoadingSpinner /> : usuarios.length === 0 ? (
        <div className="text-center py-12 text-gray-500"><UserCog className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay usuarios</p></div>
      ) : (
        <div className="bg-white border rounded-lg shadow-sm overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead className="bg-gray-50"><tr><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Nombre</th><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Email</th><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Rol</th><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Estado</th><th className="px-4 py-3 text-right text-sm font-medium text-gray-600">Acciones</th></tr></thead>
              <tbody className="divide-y">
                {usuarios.map(usuario => (
                  <tr key={usuario.id} className="hover:bg-gray-50">
                    <td className="px-4 py-3 font-medium">{usuario.nombre}</td>
                    <td className="px-4 py-3 text-gray-600">{usuario.email}</td>
                    <td className="px-4 py-3"><span className={`px-2 py-1 rounded-full text-sm ${getRolColor(usuario.rol)}`}>{getRolLabel(usuario.rol)}</span></td>
                    <td className="px-4 py-3"><span className={`px-2 py-1 rounded-full text-sm ${usuario.activo ? 'bg-green-100 text-green-700' : 'bg-red-100 text-red-700'}`}>{usuario.activo ? 'Activo' : 'Inactivo'}</span></td>
                    <td className="px-4 py-3 text-right"><button onClick={() => { setUsuarioEditando(usuario); setModalUsuario(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );

  return (
    <div className="min-h-screen bg-gray-100">
      <Navegacion />
      <main className="max-w-7xl mx-auto px-4 py-6">
        {vista === 'pedidos' && <VistaPedidos />}
        {vista === 'clientes' && <VistaClientes />}
        {vista === 'productos' && <VistaProductos />}
        {vista === 'usuarios' && isAdmin && <VistaUsuarios />}
      </main>
      {modalConfirm.visible && <ModalConfirmacion />}
      {modalCliente && <ModalCliente />}
      {modalProducto && <ModalProducto />}
      {modalPedido && <ModalPedido />}
      {modalUsuario && <ModalUsuario />}
      {modalAsignar && <ModalAsignarTransportista />}
    </div>
  );
}

// APP CON PROVIDER
export default function App() {
  return (
    <AuthProvider>
      <AppContent />
    </AuthProvider>
  );
}

function AppContent() {
  const { user, loading } = useAuth();
  if (loading) {
    return (
      <div className="min-h-screen bg-gray-100 flex items-center justify-center">
        <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
      </div>
    );
  }
  return user ? <MainApp /> : <LoginScreen />;
}

