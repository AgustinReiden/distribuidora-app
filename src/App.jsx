import React, { useState } from 'react';
import { Package, Users, ShoppingCart, Truck, Plus, Edit2, Trash2, Check, Clock, Search, X, Menu, Loader2 } from 'lucide-react';
import { useClientes, useProductos, usePedidos } from './hooks/useSupabase';

export default function App() {
  const [vista, setVista] = useState('pedidos');
  const [menuAbierto, setMenuAbierto] = useState(false);
  
  const { clientes, loading: loadingClientes, agregarCliente, actualizarCliente, eliminarCliente } = useClientes();
  const { productos, loading: loadingProductos, agregarProducto, actualizarProducto, eliminarProducto } = useProductos();
  const { pedidos, loading: loadingPedidos, crearPedido, cambiarEstado, eliminarPedido } = usePedidos();
  
  const [modalCliente, setModalCliente] = useState(false);
  const [modalProducto, setModalProducto] = useState(false);
  const [modalPedido, setModalPedido] = useState(false);
  const [modalConfirm, setModalConfirm] = useState({ visible: false, mensaje: '', onConfirm: null });
  
  const [clienteEditando, setClienteEditando] = useState(null);
  const [productoEditando, setProductoEditando] = useState(null);
  
  const [nuevoPedido, setNuevoPedido] = useState({ clienteId: '', items: [] });
  const [filtroEstado, setFiltroEstado] = useState('todos');
  const [busqueda, setBusqueda] = useState('');
  const [guardando, setGuardando] = useState(false);

  const handleGuardarCliente = async (cliente) => {
    setGuardando(true);
    try {
      if (cliente.id) {
        await actualizarCliente(cliente.id, cliente);
      } else {
        await agregarCliente(cliente);
      }
      setModalCliente(false);
      setClienteEditando(null);
    } catch (error) {
      alert('Error al guardar cliente: ' + error.message);
    }
    setGuardando(false);
  };

  const handleEliminarCliente = (id) => {
    setModalConfirm({
      visible: true,
      mensaje: '¿Estás seguro de eliminar este cliente?',
      onConfirm: async () => {
        try { await eliminarCliente(id); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', onConfirm: null });
      }
    });
  };

  const handleGuardarProducto = async (producto) => {
    setGuardando(true);
    try {
      if (producto.id) {
        await actualizarProducto(producto.id, producto);
      } else {
        await agregarProducto(producto);
      }
      setModalProducto(false);
      setProductoEditando(null);
    } catch (error) {
      alert('Error al guardar producto: ' + error.message);
    }
    setGuardando(false);
  };

  const handleEliminarProducto = (id) => {
    setModalConfirm({
      visible: true,
      mensaje: '¿Estás seguro de eliminar este producto?',
      onConfirm: async () => {
        try { await eliminarProducto(id); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', onConfirm: null });
      }
    });
  };

  const agregarItemPedido = (productoId) => {
    const existe = nuevoPedido.items.find(i => i.productoId === productoId);
    const producto = productos.find(p => p.id === productoId);
    if (existe) {
      setNuevoPedido({
        ...nuevoPedido,
        items: nuevoPedido.items.map(i => i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i)
      });
    } else {
      setNuevoPedido({
        ...nuevoPedido,
        items: [...nuevoPedido.items, { productoId, cantidad: 1, precioUnitario: producto?.precio || 0 }]
      });
    }
  };

  const actualizarCantidadItem = (productoId, cantidad) => {
    if (cantidad <= 0) {
      setNuevoPedido({ ...nuevoPedido, items: nuevoPedido.items.filter(i => i.productoId !== productoId) });
    } else {
      setNuevoPedido({
        ...nuevoPedido,
        items: nuevoPedido.items.map(i => i.productoId === productoId ? { ...i, cantidad } : i)
      });
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
      await crearPedido(parseInt(nuevoPedido.clienteId), nuevoPedido.items, calcularTotalPedido(nuevoPedido.items));
      setNuevoPedido({ clienteId: '', items: [] });
      setModalPedido(false);
    } catch (error) {
      alert('Error al crear pedido: ' + error.message);
    }
    setGuardando(false);
  };

  const handleCambiarEstado = async (id, nuevoEstado) => {
    try { await cambiarEstado(id, nuevoEstado); } catch (error) { alert('Error: ' + error.message); }
  };

  const handleEliminarPedido = (id) => {
    setModalConfirm({
      visible: true,
      mensaje: '¿Estás seguro de eliminar este pedido?',
      onConfirm: async () => {
        try { await eliminarPedido(id); } catch (error) { alert('Error: ' + error.message); }
        setModalConfirm({ visible: false, mensaje: '', onConfirm: null });
      }
    });
  };

  const pedidosFiltrados = pedidos.filter(p => {
    const cliente = p.cliente;
    const coincideBusqueda = !busqueda || cliente?.nombre_fantasia?.toLowerCase().includes(busqueda.toLowerCase());
    const coincideEstado = filtroEstado === 'todos' || p.estado === filtroEstado;
    return coincideBusqueda && coincideEstado;
  });

  const formatPrecio = (precio) => new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(precio || 0);

  const LoadingSpinner = () => (
    <div className="flex items-center justify-center py-12">
      <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
      <span className="ml-2 text-gray-600">Cargando...</span>
    </div>
  );

  const Navegacion = () => (
    <nav className="bg-blue-600 text-white shadow-lg">
      <div className="max-w-7xl mx-auto px-4">
        <div className="flex justify-between items-center h-16">
          <div className="flex items-center space-x-2">
            <Truck className="w-8 h-8" />
            <span className="font-bold text-xl">Distribuidora</span>
          </div>
          <div className="hidden md:flex space-x-1">
            {[{ id: 'pedidos', icon: ShoppingCart, label: 'Pedidos' }, { id: 'clientes', icon: Users, label: 'Clientes' }, { id: 'productos', icon: Package, label: 'Productos' }].map(item => (
              <button key={item.id} onClick={() => setVista(item.id)} className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-colors ${vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'}`}>
                <item.icon className="w-5 h-5" /><span>{item.label}</span>
              </button>
            ))}
          </div>
          <button className="md:hidden p-2" onClick={() => setMenuAbierto(!menuAbierto)}><Menu className="w-6 h-6" /></button>
        </div>
        {menuAbierto && (
          <div className="md:hidden pb-4 space-y-2">
            {[{ id: 'pedidos', icon: ShoppingCart, label: 'Pedidos' }, { id: 'clientes', icon: Users, label: 'Clientes' }, { id: 'productos', icon: Package, label: 'Productos' }].map(item => (
              <button key={item.id} onClick={() => { setVista(item.id); setMenuAbierto(false); }} className={`flex items-center space-x-2 w-full px-4 py-2 rounded-lg ${vista === item.id ? 'bg-blue-700' : 'hover:bg-blue-500'}`}>
                <item.icon className="w-5 h-5" /><span>{item.label}</span>
              </button>
            ))}
          </div>
        )}
      </div>
    </nav>
  );

  const ModalConfirmacion = () => modalConfirm.visible && (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-sm">
        <div className="p-6">
          <div className="flex items-center justify-center w-12 h-12 mx-auto mb-4 bg-red-100 rounded-full">
            <Trash2 className="w-6 h-6 text-red-600" />
          </div>
          <h3 className="text-lg font-semibold text-center text-gray-900 mb-2">Confirmar eliminación</h3>
          <p className="text-center text-gray-600">{modalConfirm.mensaje}</p>
        </div>
        <div className="flex border-t">
          <button onClick={() => setModalConfirm({ visible: false, mensaje: '', onConfirm: null })} className="flex-1 px-4 py-3 text-gray-700 font-medium hover:bg-gray-50 rounded-bl-xl">Cancelar</button>
          <button onClick={modalConfirm.onConfirm} className="flex-1 px-4 py-3 text-red-600 font-medium hover:bg-red-50 border-l rounded-br-xl">Eliminar</button>
        </div>
      </div>
    </div>
  );

  const ModalCliente = () => {
    const [form, setForm] = useState(clienteEditando ? { nombre: clienteEditando.nombre, nombreFantasia: clienteEditando.nombre_fantasia, direccion: clienteEditando.direccion, telefono: clienteEditando.telefono || '', zona: clienteEditando.zona || '' } : { nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });
    return (
      <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
        <div className="bg-white rounded-xl shadow-xl w-full max-w-md">
          <div className="flex justify-between items-center p-4 border-b">
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
            <button onClick={() => handleGuardarCliente({ ...form, id: clienteEditando?.id })} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center" disabled={guardando}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar</button>
          </div>
        </div>
      </div>
    );
  };

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
            <button onClick={() => handleGuardarProducto({ ...form, id: productoEditando?.id })} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center" disabled={guardando}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar</button>
          </div>
        </div>
      </div>
    );
  };

  const ModalPedido = () => {
    const [busquedaProducto, setBusquedaProducto] = useState('');
    const productosFiltradosModal = productos.filter(p => p.nombre.toLowerCase().includes(busquedaProducto.toLowerCase()) || (p.categoria && p.categoria.toLowerCase().includes(busquedaProducto.toLowerCase())));
    return (
      <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
        <div className="bg-white rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-hidden flex flex-col">
          <div className="flex justify-between items-center p-4 border-b">
            <h2 className="text-xl font-semibold">Nuevo Pedido</h2>
            <button onClick={() => { setModalPedido(false); setNuevoPedido({ clienteId: '', items: [] }); }}><X className="w-6 h-6 text-gray-500" /></button>
          </div>
          <div className="flex-1 overflow-y-auto p-4 space-y-4">
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Cliente *</label><select value={nuevoPedido.clienteId} onChange={e => setNuevoPedido({ ...nuevoPedido, clienteId: e.target.value })} className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"><option value="">Seleccionar cliente...</option>{clientes.map(c => <option key={c.id} value={c.id}>{c.nombre_fantasia} - {c.direccion}</option>)}</select></div>
            <div><label className="block text-sm font-medium text-gray-700 mb-1">Agregar Productos</label><div className="relative"><Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" /><input type="text" value={busquedaProducto} onChange={e => setBusquedaProducto(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Buscar producto..." /></div></div>
            <div className="border rounded-lg max-h-48 overflow-y-auto">{productosFiltradosModal.map(p => <div key={p.id} className="flex justify-between items-center p-3 hover:bg-gray-50 border-b last:border-b-0 cursor-pointer" onClick={() => agregarItemPedido(p.id)}><div><p className="font-medium">{p.nombre}</p><p className="text-sm text-gray-500">{p.categoria} • Stock: {p.stock}</p></div><div className="text-right"><p className="font-semibold text-blue-600">{formatPrecio(p.precio)}</p><span className="text-sm text-blue-500">+ Agregar</span></div></div>)}</div>
            {nuevoPedido.items.length > 0 && <div><h3 className="font-medium text-gray-700 mb-2">Productos en el pedido</h3><div className="border rounded-lg divide-y">{nuevoPedido.items.map(item => { const producto = productos.find(p => p.id === item.productoId); return <div key={item.productoId} className="flex justify-between items-center p-3"><div className="flex-1"><p className="font-medium">{producto?.nombre}</p><p className="text-sm text-gray-500">{formatPrecio(item.precioUnitario)} c/u</p></div><div className="flex items-center space-x-3"><button onClick={() => actualizarCantidadItem(item.productoId, item.cantidad - 1)} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300 flex items-center justify-center">-</button><span className="w-8 text-center font-medium">{item.cantidad}</span><button onClick={() => actualizarCantidadItem(item.productoId, item.cantidad + 1)} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300 flex items-center justify-center">+</button><p className="w-24 text-right font-semibold">{formatPrecio(item.precioUnitario * item.cantidad)}</p></div></div> })}</div></div>}
          </div>
          <div className="border-t bg-gray-50 p-4">
            <div className="flex justify-between items-center mb-4"><span className="text-lg font-medium">Total del Pedido</span><span className="text-2xl font-bold text-blue-600">{formatPrecio(calcularTotalPedido(nuevoPedido.items))}</span></div>
            <div className="flex justify-end space-x-3"><button onClick={() => { setModalPedido(false); setNuevoPedido({ clienteId: '', items: [] }); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg" disabled={guardando}>Cancelar</button><button onClick={handleGuardarPedido} className="px-6 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 flex items-center" disabled={guardando}>{guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Confirmar Pedido</button></div>
          </div>
        </div>
      </div>
    );
  };

  const VistaPedidos = () => (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <h1 className="text-2xl font-bold text-gray-800">Pedidos</h1>
        <button onClick={() => setModalPedido(true)} className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700"><Plus className="w-5 h-5" /><span>Nuevo Pedido</span></button>
      </div>
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1"><Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" /><input type="text" value={busqueda} onChange={e => setBusqueda(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500" placeholder="Buscar por cliente..." /></div>
        <select value={filtroEstado} onChange={e => setFiltroEstado(e.target.value)} className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"><option value="todos">Todos</option><option value="pendiente">Pendientes</option><option value="enviado">Enviados</option></select>
      </div>
      <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Clock className="w-5 h-5 text-yellow-600" /><span className="text-yellow-800 font-medium">Pendientes</span></div><p className="text-2xl font-bold text-yellow-600 mt-1">{pedidos.filter(p => p.estado === 'pendiente').length}</p></div>
        <div className="bg-green-50 border border-green-200 rounded-lg p-4"><div className="flex items-center space-x-2"><Check className="w-5 h-5 text-green-600" /><span className="text-green-800 font-medium">Enviados</span></div><p className="text-2xl font-bold text-green-600 mt-1">{pedidos.filter(p => p.estado === 'enviado').length}</p></div>
        <div className="bg-blue-50 border border-blue-200 rounded-lg p-4 col-span-2 sm:col-span-1"><div className="flex items-center space-x-2"><ShoppingCart className="w-5 h-5 text-blue-600" /><span className="text-blue-800 font-medium">Total Hoy</span></div><p className="text-2xl font-bold text-blue-600 mt-1">{formatPrecio(pedidos.filter(p => p.fecha === new Date().toISOString().split('T')[0]).reduce((sum, p) => sum + parseFloat(p.total || 0), 0))}</p></div>
      </div>
      {loadingPedidos ? <LoadingSpinner /> : (
        <div className="space-y-3">
          {pedidosFiltrados.length === 0 ? <div className="text-center py-12 text-gray-500"><ShoppingCart className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay pedidos</p></div> : pedidosFiltrados.map(pedido => (
            <div key={pedido.id} className="bg-white border rounded-lg shadow-sm p-4">
              <div className="flex justify-between items-start">
                <div><h3 className="font-semibold text-lg">{pedido.cliente?.nombre_fantasia || 'Sin cliente'}</h3><p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p><p className="text-sm text-gray-400 mt-1">#{pedido.id} • {pedido.fecha}</p></div>
                <span className={`px-3 py-1 rounded-full text-sm font-medium ${pedido.estado === 'pendiente' ? 'bg-yellow-100 text-yellow-800' : 'bg-green-100 text-green-800'}`}>{pedido.estado === 'pendiente' ? 'Pendiente' : 'Enviado'}</span>
              </div>
              <div className="mt-3 pt-3 border-t">
                <p className="text-sm text-gray-600 mb-2">{pedido.items?.map(item => <span key={item.id} className="mr-2">{item.producto?.nombre} x{item.cantidad}</span>)}</p>
                <div className="flex justify-between items-center">
                  <p className="text-lg font-bold text-blue-600">{formatPrecio(pedido.total)}</p>
                  <div className="flex space-x-2">
                    {pedido.estado === 'pendiente' ? <button onClick={() => handleCambiarEstado(pedido.id, 'enviado')} className="flex items-center space-x-1 px-3 py-1.5 bg-green-600 text-white rounded-lg hover:bg-green-700 text-sm"><Check className="w-4 h-4" /><span>Enviado</span></button> : <button onClick={() => handleCambiarEstado(pedido.id, 'pendiente')} className="flex items-center space-x-1 px-3 py-1.5 bg-yellow-500 text-white rounded-lg hover:bg-yellow-600 text-sm"><Clock className="w-4 h-4" /><span>Pendiente</span></button>}
                    <button onClick={() => handleEliminarPedido(pedido.id)} className="p-1.5 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-5 h-5" /></button>
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );

  const VistaClientes = () => (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-2xl font-bold text-gray-800">Clientes</h1>
        <button onClick={() => setModalCliente(true)} className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"><Plus className="w-5 h-5" /><span>Nuevo Cliente</span></button>
      </div>
      {loadingClientes ? <LoadingSpinner /> : clientes.length === 0 ? <div className="text-center py-12 text-gray-500"><Users className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay clientes</p></div> : (
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {clientes.map(cliente => (
            <div key={cliente.id} className="bg-white border rounded-lg shadow-sm p-4">
              <div className="flex justify-between items-start">
                <div className="flex-1"><h3 className="font-semibold text-lg">{cliente.nombre_fantasia}</h3><p className="text-sm text-gray-600">{cliente.nombre}</p></div>
                <div className="flex space-x-1">
                  <button onClick={() => { setClienteEditando(cliente); setModalCliente(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button>
                  <button onClick={() => handleEliminarCliente(cliente.id)} className="p-2 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-4 h-4" /></button>
                </div>
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

  const VistaProductos = () => (
    <div className="space-y-4">
      <div className="flex justify-between items-center">
        <h1 className="text-2xl font-bold text-gray-800">Productos</h1>
        <button onClick={() => setModalProducto(true)} className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700"><Plus className="w-5 h-5" /><span>Nuevo Producto</span></button>
      </div>
      {loadingProductos ? <LoadingSpinner /> : productos.length === 0 ? <div className="text-center py-12 text-gray-500"><Package className="w-12 h-12 mx-auto mb-3 opacity-50" /><p>No hay productos</p></div> : (
        <div className="bg-white border rounded-lg shadow-sm overflow-hidden">
          <table className="w-full">
            <thead className="bg-gray-50"><tr><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Producto</th><th className="px-4 py-3 text-left text-sm font-medium text-gray-600">Categoría</th><th className="px-4 py-3 text-right text-sm font-medium text-gray-600">Precio</th><th className="px-4 py-3 text-right text-sm font-medium text-gray-600">Stock</th><th className="px-4 py-3 text-right text-sm font-medium text-gray-600">Acciones</th></tr></thead>
            <tbody className="divide-y">
              {productos.map(producto => (
                <tr key={producto.id} className="hover:bg-gray-50">
                  <td className="px-4 py-3 font-medium">{producto.nombre}</td>
                  <td className="px-4 py-3 text-gray-600">{producto.categoria}</td>
                  <td className="px-4 py-3 text-right font-semibold text-blue-600">{formatPrecio(producto.precio)}</td>
                  <td className="px-4 py-3 text-right"><span className={`px-2 py-1 rounded-full text-sm ${producto.stock < 20 ? 'bg-red-100 text-red-700' : producto.stock < 50 ? 'bg-yellow-100 text-yellow-700' : 'bg-green-100 text-green-700'}`}>{producto.stock}</span></td>
                  <td className="px-4 py-3 text-right"><div className="flex justify-end space-x-1"><button onClick={() => { setProductoEditando(producto); setModalProducto(true); }} className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg"><Edit2 className="w-4 h-4" /></button><button onClick={() => handleEliminarProducto(producto.id)} className="p-2 text-red-500 hover:bg-red-50 rounded-lg"><Trash2 className="w-4 h-4" /></button></div></td>
                </tr>
              ))}
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
        {vista === 'pedidos' && <VistaPedidos />}
        {vista === 'clientes' && <VistaClientes />}
        {vista === 'productos' && <VistaProductos />}
      </main>
      {modalConfirm.visible && <ModalConfirmacion />}
      {modalCliente && <ModalCliente />}
      {modalProducto && <ModalProducto />}
      {modalPedido && <ModalPedido />}
    </div>
  );
}
