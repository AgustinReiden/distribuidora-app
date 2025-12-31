import React, { useState, useMemo, memo } from 'react';
import { X, Loader2, Trash2, AlertTriangle, Check, Search } from 'lucide-react';

const formatPrecio = (p) => new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0);

// Modal base reutilizable
const ModalBase = memo(function ModalBase({ children, onClose, title, maxWidth = 'max-w-md' }) {
  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className={`bg-white rounded-xl shadow-xl w-full ${maxWidth}`}>
        <div className="flex justify-between items-center p-4 border-b">
          <h2 className="text-xl font-semibold">{title}</h2>
          <button onClick={onClose}><X className="w-6 h-6 text-gray-500" /></button>
        </div>
        {children}
      </div>
    </div>
  );
});

// Modal de confirmación
export const ModalConfirmacion = memo(function ModalConfirmacion({ config, onClose }) {
  if (!config?.visible) return null;

  const iconConfig = {
    danger: { bg: 'bg-red-100', icon: <Trash2 className="w-6 h-6 text-red-600" />, btn: 'text-red-600 hover:bg-red-50' },
    warning: { bg: 'bg-yellow-100', icon: <AlertTriangle className="w-6 h-6 text-yellow-600" />, btn: 'text-yellow-600 hover:bg-yellow-50' },
    success: { bg: 'bg-green-100', icon: <Check className="w-6 h-6 text-green-600" />, btn: 'text-green-600 hover:bg-green-50' }
  };
  const { bg, icon, btn } = iconConfig[config.tipo] || iconConfig.success;

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-sm">
        <div className="p-6">
          <div className={`flex items-center justify-center w-12 h-12 mx-auto mb-4 rounded-full ${bg}`}>{icon}</div>
          <h3 className="text-lg font-semibold text-center mb-2">{config.titulo}</h3>
          <p className="text-center text-gray-600">{config.mensaje}</p>
        </div>
        <div className="flex border-t">
          <button onClick={onClose} className="flex-1 px-4 py-3 text-gray-700 hover:bg-gray-50 rounded-bl-xl">Cancelar</button>
          <button onClick={config.onConfirm} className={`flex-1 px-4 py-3 border-l rounded-br-xl ${btn}`}>Confirmar</button>
        </div>
      </div>
    </div>
  );
});

// Modal de filtro de fecha
export const ModalFiltroFecha = memo(function ModalFiltroFecha({ filtros, onApply, onClose }) {
  const [fechaDesde, setFechaDesde] = useState(filtros.fechaDesde || '');
  const [fechaHasta, setFechaHasta] = useState(filtros.fechaHasta || '');

  return (
    <ModalBase title="Filtrar por Fecha" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Desde</label><input type="date" value={fechaDesde} onChange={e => setFechaDesde(e.target.value)} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Hasta</label><input type="date" value={fechaHasta} onChange={e => setFechaHasta(e.target.value)} className="w-full px-3 py-2 border rounded-lg" /></div>
      </div>
      <div className="flex justify-between p-4 border-t bg-gray-50">
        <button onClick={() => { onApply({ fechaDesde: null, fechaHasta: null }); onClose(); }} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Limpiar</button>
        <button onClick={() => { onApply({ fechaDesde: fechaDesde || null, fechaHasta: fechaHasta || null }); onClose(); }} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700">Aplicar</button>
      </div>
    </ModalBase>
  );
});

// Modal de cliente
export const ModalCliente = memo(function ModalCliente({ cliente, onSave, onClose, guardando }) {
  const [form, setForm] = useState(cliente ? {
    nombre: cliente.nombre,
    nombreFantasia: cliente.nombre_fantasia,
    direccion: cliente.direccion,
    telefono: cliente.telefono || '',
    zona: cliente.zona || ''
  } : { nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });

  const handleSubmit = () => {
    onSave({ ...form, id: cliente?.id });
  };

  return (
    <ModalBase title={cliente ? 'Editar Cliente' : 'Nuevo Cliente'} onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Nombre *</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Nombre Fantasía *</label><input type="text" value={form.nombreFantasia} onChange={e => setForm({ ...form, nombreFantasia: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Dirección *</label><input type="text" value={form.direccion} onChange={e => setForm({ ...form, direccion: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Teléfono</label><input type="text" value={form.telefono} onChange={e => setForm({ ...form, telefono: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Zona</label><input type="text" value={form.zona} onChange={e => setForm({ ...form, zona: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={handleSubmit} disabled={guardando || !form.nombre || !form.nombreFantasia || !form.direccion} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

// Modal de producto - con categorías como select
export const ModalProducto = memo(function ModalProducto({ producto, categorias, onSave, onClose, guardando }) {
  const [form, setForm] = useState(producto || { nombre: '', precio: '', stock: '', categoria: '' });
  const [nuevaCategoria, setNuevaCategoria] = useState('');
  const [mostrarNuevaCategoria, setMostrarNuevaCategoria] = useState(false);

  const handleSubmit = () => {
    const categoriaFinal = mostrarNuevaCategoria && nuevaCategoria.trim()
      ? nuevaCategoria.trim()
      : form.categoria;
    onSave({ ...form, categoria: categoriaFinal, id: producto?.id });
  };

  return (
    <ModalBase title={producto ? 'Editar Producto' : 'Nuevo Producto'} onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Nombre *</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div>
          <div className="flex justify-between items-center mb-1">
            <label className="block text-sm font-medium">Categoría</label>
            <button
              type="button"
              onClick={() => setMostrarNuevaCategoria(!mostrarNuevaCategoria)}
              className="text-sm text-blue-600 hover:text-blue-700"
            >
              {mostrarNuevaCategoria ? 'Elegir existente' : '+ Nueva categoría'}
            </button>
          </div>
          {mostrarNuevaCategoria ? (
            <input
              type="text"
              value={nuevaCategoria}
              onChange={e => setNuevaCategoria(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="Escribir nueva categoría..."
            />
          ) : (
            <select
              value={form.categoria || ''}
              onChange={e => setForm({ ...form, categoria: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="">Sin categoría</option>
              {categorias.map(cat => (
                <option key={cat} value={cat}>{cat}</option>
              ))}
            </select>
          )}
        </div>
        <div className="grid grid-cols-2 gap-4">
          <div><label className="block text-sm font-medium mb-1">Precio *</label><input type="number" value={form.precio} onChange={e => setForm({ ...form, precio: parseFloat(e.target.value) || '' })} className="w-full px-3 py-2 border rounded-lg" /></div>
          <div><label className="block text-sm font-medium mb-1">Stock *</label><input type="number" value={form.stock} onChange={e => setForm({ ...form, stock: parseInt(e.target.value) || '' })} className="w-full px-3 py-2 border rounded-lg" /></div>
        </div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={handleSubmit} disabled={guardando || !form.nombre || !form.precio} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

// Modal de usuario
export const ModalUsuario = memo(function ModalUsuario({ usuario, onSave, onClose, guardando }) {
  const [form, setForm] = useState(usuario || { nombre: '', rol: 'preventista', activo: true });

  return (
    <ModalBase title="Editar Usuario" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Email</label><input type="email" value={form.email || ''} disabled className="w-full px-3 py-2 border rounded-lg bg-gray-100" /></div>
        <div><label className="block text-sm font-medium mb-1">Nombre</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Rol</label><select value={form.rol} onChange={e => setForm({ ...form, rol: e.target.value })} className="w-full px-3 py-2 border rounded-lg"><option value="preventista">Preventista</option><option value="transportista">Transportista</option><option value="admin">Administrador</option></select></div>
        <div className="flex items-center space-x-2"><input type="checkbox" id="activo" checked={form.activo} onChange={e => setForm({ ...form, activo: e.target.checked })} className="w-4 h-4" /><label htmlFor="activo" className="text-sm">Usuario activo</label></div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={() => onSave({ ...form, id: usuario?.id })} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

// Modal asignar transportista
export const ModalAsignarTransportista = memo(function ModalAsignarTransportista({ pedido, transportistas, onSave, onClose, guardando }) {
  const [sel, setSel] = useState(pedido?.transportista_id || '');

  return (
    <ModalBase title="Asignar Transportista" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div className="bg-gray-50 rounded-lg p-3"><p className="text-sm text-gray-600">Pedido #{pedido?.id}</p><p className="font-medium">{pedido?.cliente?.nombre_fantasia}</p></div>
        <div><label className="block text-sm font-medium mb-1">Transportista</label><select value={sel} onChange={e => setSel(e.target.value)} className="w-full px-3 py-2 border rounded-lg"><option value="">Sin asignar</option>{transportistas.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}</select></div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={() => onSave(sel)} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

// Modal de pedido - con filtro por categorías
export const ModalPedido = memo(function ModalPedido({
  productos,
  clientes,
  categorias,
  nuevoPedido,
  onClose,
  onClienteChange,
  onAgregarItem,
  onActualizarCantidad,
  onCrearCliente,
  onGuardar,
  guardando,
  isAdmin,
  isPreventista
}) {
  const [busquedaProducto, setBusquedaProducto] = useState('');
  const [busquedaCliente, setBusquedaCliente] = useState('');
  const [categoriaSeleccionada, setCategoriaSeleccionada] = useState('');
  const [mostrarNuevoCliente, setMostrarNuevoCliente] = useState(false);
  const [nuevoCliente, setNuevoCliente] = useState({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });
  const [guardandoCliente, setGuardandoCliente] = useState(false);

  const productosFiltrados = useMemo(() => {
    return productos.filter(p => {
      const matchNombre = p.nombre.toLowerCase().includes(busquedaProducto.toLowerCase());
      const matchCategoria = !categoriaSeleccionada || p.categoria === categoriaSeleccionada;
      return matchNombre && matchCategoria;
    });
  }, [productos, busquedaProducto, categoriaSeleccionada]);

  const clientesFiltrados = useMemo(() => {
    if (busquedaCliente.length < 2) return [];
    return clientes.filter(c =>
      c.nombre_fantasia.toLowerCase().includes(busquedaCliente.toLowerCase()) ||
      c.direccion.toLowerCase().includes(busquedaCliente.toLowerCase())
    ).slice(0, 8);
  }, [clientes, busquedaCliente]);

  const clienteSeleccionado = clientes.find(c => c.id === parseInt(nuevoPedido.clienteId));

  const handleCrearClienteRapido = async () => {
    if (!nuevoCliente.nombre || !nuevoCliente.nombreFantasia || !nuevoCliente.direccion) return;
    setGuardandoCliente(true);
    try {
      const cliente = await onCrearCliente(nuevoCliente);
      onClienteChange(cliente.id.toString());
      setMostrarNuevoCliente(false);
      setNuevoCliente({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });
    } catch (e) {
      // Error handled by parent
    }
    setGuardandoCliente(false);
  };

  const getStockWarning = (productoId, cantidadEnPedido) => {
    const producto = productos.find(p => p.id === productoId);
    if (!producto) return null;
    const stockDisponible = producto.stock - cantidadEnPedido;
    if (stockDisponible < 0) return { tipo: 'error', mensaje: `Sin stock! Disponible: ${producto.stock}` };
    if (stockDisponible < 10) return { tipo: 'warning', mensaje: `Stock bajo: quedarán ${stockDisponible}` };
    return null;
  };

  const calcularTotal = () => nuevoPedido.items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-white rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-hidden flex flex-col">
        <div className="flex justify-between items-center p-4 border-b">
          <h2 className="text-xl font-semibold">Nuevo Pedido</h2>
          <button onClick={onClose}><X className="w-6 h-6 text-gray-500" /></button>
        </div>

        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Sección Cliente */}
          <div>
            <div className="flex justify-between items-center mb-1">
              <label className="block text-sm font-medium">Cliente *</label>
              {(isAdmin || isPreventista) && (
                <button onClick={() => setMostrarNuevoCliente(!mostrarNuevoCliente)} className="text-sm text-blue-600">
                  {mostrarNuevoCliente ? 'Cancelar' : '+ Nuevo'}
                </button>
              )}
            </div>

            {mostrarNuevoCliente ? (
              <div className="border rounded-lg p-3 space-y-3 bg-blue-50">
                <input type="text" value={nuevoCliente.nombreFantasia} onChange={e => setNuevoCliente({ ...nuevoCliente, nombreFantasia: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Nombre fantasía *" />
                <input type="text" value={nuevoCliente.nombre} onChange={e => setNuevoCliente({ ...nuevoCliente, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Nombre completo *" />
                <input type="text" value={nuevoCliente.direccion} onChange={e => setNuevoCliente({ ...nuevoCliente, direccion: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Dirección *" />
                <button onClick={handleCrearClienteRapido} disabled={guardandoCliente} className="w-full py-2 bg-blue-600 text-white rounded-lg">
                  {guardandoCliente ? <Loader2 className="w-4 h-4 animate-spin mx-auto" /> : 'Crear y seleccionar'}
                </button>
              </div>
            ) : clienteSeleccionado ? (
              <div className="p-3 bg-blue-50 border border-blue-200 rounded-lg flex justify-between items-center">
                <div><p className="font-medium">{clienteSeleccionado.nombre_fantasia}</p><p className="text-sm text-gray-600">{clienteSeleccionado.direccion}</p></div>
                <button onClick={() => onClienteChange('')} className="text-red-500 p-1"><X className="w-5 h-5" /></button>
              </div>
            ) : (
              <div>
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
                  <input type="text" value={busquedaCliente} onChange={e => setBusquedaCliente(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg" placeholder="Buscar cliente (mín. 2 letras)..." />
                </div>
                {clientesFiltrados.length > 0 && (
                  <div className="border rounded-lg max-h-40 overflow-y-auto mt-2">
                    {clientesFiltrados.map(c => (
                      <div key={c.id} className="p-3 hover:bg-blue-50 border-b cursor-pointer" onClick={() => { onClienteChange(c.id.toString()); setBusquedaCliente(''); }}>
                        <p className="font-medium">{c.nombre_fantasia}</p>
                        <p className="text-sm text-gray-500">{c.direccion}</p>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Sección Productos con filtro por categoría */}
          <div>
            <label className="block text-sm font-medium mb-1">Agregar Productos</label>

            {/* Filtros de categoría */}
            {categorias.length > 0 && (
              <div className="flex flex-wrap gap-2 mb-2">
                <button
                  onClick={() => setCategoriaSeleccionada('')}
                  className={`px-3 py-1 rounded-full text-sm font-medium transition-colors ${
                    categoriaSeleccionada === ''
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                  }`}
                >
                  Todos
                </button>
                {categorias.map(cat => (
                  <button
                    key={cat}
                    onClick={() => setCategoriaSeleccionada(cat)}
                    className={`px-3 py-1 rounded-full text-sm font-medium transition-colors ${
                      categoriaSeleccionada === cat
                        ? 'bg-blue-600 text-white'
                        : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                    }`}
                  >
                    {cat}
                  </button>
                ))}
              </div>
            )}

            <div className="relative">
              <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
              <input type="text" value={busquedaProducto} onChange={e => setBusquedaProducto(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg" placeholder="Buscar producto..." />
            </div>
          </div>

          <div className="border rounded-lg max-h-48 overflow-y-auto">
            {productosFiltrados.length === 0 ? (
              <p className="p-4 text-center text-gray-500">No se encontraron productos</p>
            ) : (
              productosFiltrados.map(p => (
                <div key={p.id} className="flex justify-between items-center p-3 hover:bg-gray-50 border-b cursor-pointer" onClick={() => onAgregarItem(p.id)}>
                  <div>
                    <p className="font-medium">{p.nombre}</p>
                    <p className="text-sm text-gray-500">
                      Stock: {p.stock}
                      {p.categoria && <span className="ml-2 px-2 py-0.5 bg-gray-100 rounded text-xs">{p.categoria}</span>}
                    </p>
                  </div>
                  <div className="text-right">
                    <p className="font-semibold text-blue-600">{formatPrecio(p.precio)}</p>
                    <span className="text-sm text-blue-500">+ Agregar</span>
                  </div>
                </div>
              ))
            )}
          </div>

          {/* Items del pedido */}
          {nuevoPedido.items.length > 0 && (
            <div>
              <h3 className="font-medium mb-2">Productos en el pedido</h3>
              <div className="border rounded-lg divide-y">
                {nuevoPedido.items.map(item => {
                  const prod = productos.find(p => p.id === item.productoId);
                  const warning = getStockWarning(item.productoId, item.cantidad);
                  return (
                    <div key={item.productoId} className="p-3">
                      <div className="flex justify-between items-center">
                        <div>
                          <p className="font-medium">{prod?.nombre}</p>
                          <p className="text-sm text-gray-500">{formatPrecio(item.precioUnitario)} c/u</p>
                        </div>
                        <div className="flex items-center space-x-3">
                          <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, item.cantidad - 1); }} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300">-</button>
                          <span className="w-8 text-center font-medium">{item.cantidad}</span>
                          <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, item.cantidad + 1); }} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300">+</button>
                          <p className="w-24 text-right font-semibold">{formatPrecio(item.precioUnitario * item.cantidad)}</p>
                        </div>
                      </div>
                      {warning && <p className={`text-sm mt-1 ${warning.tipo === 'error' ? 'text-red-600' : 'text-yellow-600'}`}>{warning.mensaje}</p>}
                    </div>
                  );
                })}
              </div>
            </div>
          )}
        </div>

        <div className="border-t bg-gray-50 p-4">
          <div className="flex justify-between items-center mb-4">
            <span className="text-lg font-medium">Total</span>
            <span className="text-2xl font-bold text-blue-600">{formatPrecio(calcularTotal())}</span>
          </div>
          <div className="flex justify-end space-x-3">
            <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
            <button onClick={onGuardar} disabled={guardando} className="px-6 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 flex items-center">
              {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Confirmar
            </button>
          </div>
        </div>
      </div>
    </div>
  );
});
