import React, { useState, useMemo, memo, useEffect } from 'react';
import { X, Loader2, Trash2, AlertTriangle, Check, Search, History, FileText, FileDown, Package, Truck, MapPin, Route, Clock, Navigation, Settings, Save } from 'lucide-react';
import { AddressAutocomplete } from './AddressAutocomplete';
import { getDepositoCoords, setDepositoCoords } from '../hooks/useOptimizarRuta';

const formatPrecio = (p) => new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0);
const formatFecha = (fecha) => new Date(fecha).toLocaleString('es-AR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });

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
    latitud: cliente.latitud || null,
    longitud: cliente.longitud || null,
    telefono: cliente.telefono || '',
    zona: cliente.zona || ''
  } : { nombre: '', nombreFantasia: '', direccion: '', latitud: null, longitud: null, telefono: '', zona: '' });

  const handleAddressSelect = (result) => {
    setForm(prev => ({
      ...prev,
      direccion: result.direccion,
      latitud: result.latitud,
      longitud: result.longitud
    }));
  };

  const handleSubmit = () => {
    onSave({ ...form, id: cliente?.id });
  };

  return (
    <ModalBase title={cliente ? 'Editar Cliente' : 'Nuevo Cliente'} onClose={onClose}>
      <div className="p-4 space-y-4">
        <div><label className="block text-sm font-medium mb-1">Nombre *</label><input type="text" value={form.nombre} onChange={e => setForm({ ...form, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div><label className="block text-sm font-medium mb-1">Nombre Fantasía *</label><input type="text" value={form.nombreFantasia} onChange={e => setForm({ ...form, nombreFantasia: e.target.value })} className="w-full px-3 py-2 border rounded-lg" /></div>
        <div>
          <label className="block text-sm font-medium mb-1">Dirección *</label>
          <AddressAutocomplete
            value={form.direccion}
            onChange={(val) => setForm(prev => ({ ...prev, direccion: val }))}
            onSelect={handleAddressSelect}
            placeholder="Buscar dirección..."
          />
          {form.latitud && form.longitud && (
            <div className="mt-2 flex items-center text-xs text-green-600 bg-green-50 px-3 py-2 rounded-lg">
              <MapPin className="w-4 h-4 mr-2" />
              <span>Coordenadas: {form.latitud.toFixed(6)}, {form.longitud.toFixed(6)}</span>
            </div>
          )}
        </div>
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

// Modal de producto - con categorías y campos de costos/precios
export const ModalProducto = memo(function ModalProducto({ producto, categorias, onSave, onClose, guardando }) {
  const [form, setForm] = useState(producto || {
    nombre: '',
    codigo: '',
    categoria: '',
    stock: '',
    stock_minimo: 10,
    costo_sin_iva: '',
    costo_con_iva: '',
    impuestos_internos: '',
    precio_sin_iva: '',
    precio: '' // precio_con_iva (precio final al cliente)
  });
  const [nuevaCategoria, setNuevaCategoria] = useState('');
  const [mostrarNuevaCategoria, setMostrarNuevaCategoria] = useState(false);

  // Calcular automáticamente costo con IVA cuando cambia costo sin IVA
  const handleCostoSinIvaChange = (valor) => {
    const costoSinIva = parseFloat(valor) || 0;
    const costoConIva = costoSinIva * 1.21; // 21% IVA
    setForm({
      ...form,
      costo_sin_iva: valor,
      costo_con_iva: costoConIva ? costoConIva.toFixed(2) : ''
    });
  };

  // Calcular automáticamente precio con IVA cuando cambia precio sin IVA
  const handlePrecioSinIvaChange = (valor) => {
    const precioSinIva = parseFloat(valor) || 0;
    const precioConIva = precioSinIva * 1.21; // 21% IVA
    setForm({
      ...form,
      precio_sin_iva: valor,
      precio: precioConIva ? precioConIva.toFixed(2) : ''
    });
  };

  const handleSubmit = () => {
    const categoriaFinal = mostrarNuevaCategoria && nuevaCategoria.trim()
      ? nuevaCategoria.trim()
      : form.categoria;
    onSave({ ...form, categoria: categoriaFinal, id: producto?.id });
  };

  return (
    <ModalBase title={producto ? 'Editar Producto' : 'Nuevo Producto'} onClose={onClose} maxWidth="max-w-lg">
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Información básica */}
        <div className="grid grid-cols-2 gap-4">
          <div className="col-span-2 sm:col-span-1">
            <label className="block text-sm font-medium mb-1">Codigo</label>
            <input
              type="text"
              value={form.codigo || ''}
              onChange={e => setForm({ ...form, codigo: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="SKU o codigo interno"
            />
          </div>
          <div className="col-span-2 sm:col-span-1">
            <label className="block text-sm font-medium mb-1">Stock *</label>
            <input
              type="number"
              value={form.stock}
              onChange={e => setForm({ ...form, stock: parseInt(e.target.value) || '' })}
              className="w-full px-3 py-2 border rounded-lg"
            />
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Stock Mínimo de Seguridad</label>
          <input
            type="number"
            value={form.stock_minimo !== undefined ? form.stock_minimo : 10}
            onChange={e => setForm({ ...form, stock_minimo: parseInt(e.target.value) || 0 })}
            className="w-full px-3 py-2 border rounded-lg"
            placeholder="10"
          />
          <p className="text-xs text-gray-500 mt-1">
            Se mostrará una alerta cuando el stock esté por debajo de este valor
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Nombre *</label>
          <input
            type="text"
            value={form.nombre}
            onChange={e => setForm({ ...form, nombre: e.target.value })}
            className="w-full px-3 py-2 border rounded-lg"
          />
        </div>

        <div>
          <div className="flex justify-between items-center mb-1">
            <label className="block text-sm font-medium">Categoria</label>
            <button
              type="button"
              onClick={() => setMostrarNuevaCategoria(!mostrarNuevaCategoria)}
              className="text-sm text-blue-600 hover:text-blue-700"
            >
              {mostrarNuevaCategoria ? 'Elegir existente' : '+ Nueva categoria'}
            </button>
          </div>
          {mostrarNuevaCategoria ? (
            <input
              type="text"
              value={nuevaCategoria}
              onChange={e => setNuevaCategoria(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="Escribir nueva categoria..."
            />
          ) : (
            <select
              value={form.categoria || ''}
              onChange={e => setForm({ ...form, categoria: e.target.value })}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="">Sin categoria</option>
              {categorias.map(cat => (
                <option key={cat} value={cat}>{cat}</option>
              ))}
            </select>
          )}
        </div>

        {/* Sección de Costos */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Costos (compra)</h3>
          <div className="grid grid-cols-3 gap-3">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Costo sin IVA</label>
              <input
                type="number"
                step="0.01"
                value={form.costo_sin_iva || ''}
                onChange={e => handleCostoSinIvaChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg text-sm"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Costo con IVA</label>
              <input
                type="number"
                step="0.01"
                value={form.costo_con_iva || ''}
                onChange={e => setForm({ ...form, costo_con_iva: e.target.value })}
                className="w-full px-3 py-2 border rounded-lg text-sm bg-gray-50"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Imp. Internos</label>
              <input
                type="number"
                step="0.01"
                value={form.impuestos_internos || ''}
                onChange={e => setForm({ ...form, impuestos_internos: e.target.value })}
                className="w-full px-3 py-2 border rounded-lg text-sm"
                placeholder="0.00"
              />
            </div>
          </div>
        </div>

        {/* Sección de Precios de Venta */}
        <div className="border-t pt-4">
          <h3 className="text-sm font-semibold text-gray-700 mb-3">Precios de Venta</h3>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio sin IVA</label>
              <input
                type="number"
                step="0.01"
                value={form.precio_sin_iva || ''}
                onChange={e => handlePrecioSinIvaChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg"
                placeholder="0.00"
              />
            </div>
            <div>
              <label className="block text-xs font-medium mb-1 text-gray-600">Precio con IVA (Final) *</label>
              <input
                type="number"
                step="0.01"
                value={form.precio}
                onChange={e => setForm({ ...form, precio: parseFloat(e.target.value) || '' })}
                className="w-full px-3 py-2 border rounded-lg bg-green-50 border-green-300 font-semibold"
                placeholder="0.00"
              />
            </div>
          </div>
          <p className="text-xs text-gray-500 mt-2">* El precio con IVA es el que se muestra al cliente en los pedidos</p>
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
  const [marcarListo, setMarcarListo] = useState(false);

  // Verificar si el pedido ya está en estado 'asignado'
  const yaEstaAsignado = pedido?.estado === 'asignado';

  return (
    <ModalBase title="Asignar Transportista" onClose={onClose}>
      <div className="p-4 space-y-4">
        <div className="bg-gray-50 rounded-lg p-3">
          <p className="text-sm text-gray-600">Pedido #{pedido?.id}</p>
          <p className="font-medium">{pedido?.cliente?.nombre_fantasia}</p>
          <p className="text-sm text-gray-500">{pedido?.cliente?.direccion}</p>
          <div className="mt-2">
            <span className={`px-2 py-1 rounded-full text-xs font-medium ${
              pedido?.estado === 'pendiente' ? 'bg-yellow-100 text-yellow-800' :
              pedido?.estado === 'en_preparacion' ? 'bg-orange-100 text-orange-800' :
              pedido?.estado === 'asignado' ? 'bg-blue-100 text-blue-800' :
              'bg-green-100 text-green-800'
            }`}>
              {pedido?.estado === 'pendiente' ? 'Pendiente de preparar' :
               pedido?.estado === 'en_preparacion' ? 'En preparacion' :
               pedido?.estado === 'asignado' ? 'Listo para entregar' : 'Entregado'}
            </span>
          </div>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Transportista</label>
          <select value={sel} onChange={e => setSel(e.target.value)} className="w-full px-3 py-2 border rounded-lg">
            <option value="">Sin asignar</option>
            {transportistas.map(t => <option key={t.id} value={t.id}>{t.nombre}</option>)}
          </select>
        </div>

        {/* Opción para marcar como listo (solo si hay transportista y no está ya asignado) */}
        {sel && !yaEstaAsignado && (
          <div className="bg-blue-50 border border-blue-200 rounded-lg p-3">
            <label className="flex items-start space-x-3 cursor-pointer">
              <input
                type="checkbox"
                checked={marcarListo}
                onChange={e => setMarcarListo(e.target.checked)}
                className="w-5 h-5 mt-0.5 rounded border-blue-300"
              />
              <div>
                <span className="font-medium text-blue-800">Marcar como listo para entregar</span>
                <p className="text-sm text-blue-600 mt-1">
                  Si NO marcas esta opcion, el pedido mantendra su estado actual
                  {pedido?.estado === 'pendiente' && ' (pendiente de preparar)'}.
                  El transportista podra verlo pero sabra que aun no esta listo.
                </p>
              </div>
            </label>
          </div>
        )}

        {!sel && pedido?.transportista_id && (
          <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3">
            <p className="text-sm text-yellow-800">
              Al desasignar el transportista, el pedido mantendra su estado actual.
            </p>
          </div>
        )}
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
        <button onClick={() => onSave(sel, marcarListo)} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center">
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
  isPreventista,
  onNotasChange,
  onFormaPagoChange,
  onEstadoPagoChange
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
      const tieneStock = p.stock > 0;
      return matchNombre && matchCategoria && tieneStock;
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
    const stockMinimo = producto.stock_minimo || 10;
    if (stockDisponible < 0) return { tipo: 'error', mensaje: `Sin stock! Disponible: ${producto.stock}` };
    if (stockDisponible < stockMinimo) return { tipo: 'warning', mensaje: `Stock bajo: quedarán ${stockDisponible}` };
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

          {/* Sección Notas */}
          <div>
            <label className="block text-sm font-medium mb-1">Notas / Observaciones</label>
            <textarea
              value={nuevoPedido.notas || ''}
              onChange={e => onNotasChange && onNotasChange(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="Observaciones importantes para la preparación del pedido..."
              rows={2}
            />
          </div>

          {/* Sección Forma de Pago y Estado de Pago */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium mb-1">Forma de Pago</label>
              <select
                value={nuevoPedido.formaPago || 'efectivo'}
                onChange={e => onFormaPagoChange && onFormaPagoChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg"
              >
                <option value="efectivo">Efectivo</option>
                <option value="transferencia">Transferencia</option>
                <option value="cheque">Cheque</option>
                <option value="cuenta_corriente">Cuenta Corriente</option>
                <option value="tarjeta">Tarjeta</option>
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium mb-1">Estado de Pago</label>
              <select
                value={nuevoPedido.estadoPago || 'pendiente'}
                onChange={e => onEstadoPagoChange && onEstadoPagoChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg"
              >
                <option value="pendiente">Pendiente</option>
                <option value="pagado">Pagado</option>
                <option value="parcial">Parcial</option>
              </select>
            </div>
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

// Modal para ver historial de cambios de un pedido
export const ModalHistorialPedido = memo(function ModalHistorialPedido({ pedido, historial, onClose, loading }) {
  const formatearCampo = (campo) => {
    const mapeo = {
      estado: "Estado",
      transportista_id: "Transportista",
      notas: "Notas",
      forma_pago: "Forma de pago",
      estado_pago: "Estado de pago",
      total: "Total",
      creacion: "Creación"
    };
    return mapeo[campo] || campo;
  };

  const formatearValor = (campo, valor) => {
    if (campo === "total") return formatPrecio(parseFloat(valor));
    if (campo === "estado") {
      const estados = { pendiente: "Pendiente", en_preparacion: "En preparación", asignado: "En camino", entregado: "Entregado" };
      return estados[valor] || valor;
    }
    if (campo === "estado_pago") {
      const estados = { pendiente: "Pendiente", pagado: "Pagado", parcial: "Parcial" };
      return estados[valor] || valor;
    }
    if (campo === "forma_pago") {
      const formas = {
        efectivo: "Efectivo",
        transferencia: "Transferencia",
        cheque: "Cheque",
        cuenta_corriente: "Cuenta Corriente",
        tarjeta: "Tarjeta"
      };
      return formas[valor] || valor;
    }
    return valor;
  };

  return (
    <ModalBase title={`Historial de cambios - Pedido #${pedido?.id}`} onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4">
        {loading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
          </div>
        ) : historial.length === 0 ? (
          <div className="text-center py-8 text-gray-500">
            <History className="w-12 h-12 mx-auto mb-3 opacity-50" />
            <p>No hay cambios registrados para este pedido</p>
          </div>
        ) : (
          <div className="space-y-3 max-h-96 overflow-y-auto">
            {historial.map((cambio, index) => (
              <div key={cambio.id || index} className="border rounded-lg p-3 bg-gray-50">
                <div className="flex justify-between items-start mb-2">
                  <div>
                    <p className="font-medium text-gray-900">
                      {formatearCampo(cambio.campo_modificado)}
                    </p>
                    <p className="text-sm text-gray-600">
                      {cambio.usuario?.nombre || "Usuario desconocido"}
                    </p>
                  </div>
                  <p className="text-xs text-gray-500">{formatFecha(cambio.created_at)}</p>
                </div>
                {cambio.campo_modificado === "creacion" ? (
                  <p className="text-sm text-green-600 font-medium">{cambio.valor_nuevo}</p>
                ) : (
                  <div className="flex items-center space-x-2 text-sm">
                    <span className="px-2 py-1 bg-red-100 text-red-700 rounded">
                      {formatearValor(cambio.campo_modificado, cambio.valor_anterior)}
                    </span>
                    <span className="text-gray-400">→</span>
                    <span className="px-2 py-1 bg-green-100 text-green-700 rounded">
                      {formatearValor(cambio.campo_modificado, cambio.valor_nuevo)}
                    </span>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
      <div className="flex justify-end p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700">
          Cerrar
        </button>
      </div>
    </ModalBase>
  );
});

// Modal para editar detalles de un pedido existente
export const ModalEditarPedido = memo(function ModalEditarPedido({ pedido, onSave, onClose, guardando }) {
  const [notas, setNotas] = useState(pedido?.notas || "");
  const [formaPago, setFormaPago] = useState(pedido?.forma_pago || "efectivo");
  const [estadoPago, setEstadoPago] = useState(pedido?.estado_pago || "pendiente");

  const handleGuardar = () => {
    onSave({ notas, formaPago, estadoPago });
  };

  return (
    <ModalBase title={`Editar Pedido #${pedido?.id}`} onClose={onClose}>
      <div className="p-4 space-y-4">
        <div className="bg-gray-50 rounded-lg p-3 border">
          <p className="text-sm text-gray-600">Cliente</p>
          <p className="font-medium">{pedido?.cliente?.nombre_fantasia}</p>
          <p className="text-sm text-gray-500">{pedido?.cliente?.direccion}</p>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1">Notas / Observaciones</label>
          <textarea
            value={notas}
            onChange={e => setNotas(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg"
            placeholder="Observaciones importantes para la preparación del pedido..."
            rows={3}
          />
        </div>

        <div className="grid grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium mb-1">Forma de Pago</label>
            <select
              value={formaPago}
              onChange={e => setFormaPago(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="efectivo">Efectivo</option>
              <option value="transferencia">Transferencia</option>
              <option value="cheque">Cheque</option>
              <option value="cuenta_corriente">Cuenta Corriente</option>
              <option value="tarjeta">Tarjeta</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Estado de Pago</label>
            <select
              value={estadoPago}
              onChange={e => setEstadoPago(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="pendiente">Pendiente</option>
              <option value="pagado">Pagado</option>
              <option value="parcial">Parcial</option>
            </select>
          </div>
        </div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">
          Cancelar
        </button>
        <button onClick={handleGuardar} disabled={guardando} className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center">
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Guardar
        </button>
      </div>
    </ModalBase>
  );
});

// Modal para exportar pedidos a PDF
export const ModalExportarPDF = memo(function ModalExportarPDF({
  pedidos,
  transportistas,
  onExportarOrdenPreparacion,
  onExportarHojaRuta,
  onClose
}) {
  const [tipoExport, setTipoExport] = useState('preparacion'); // 'preparacion' o 'ruta'
  const [transportistaSeleccionado, setTransportistaSeleccionado] = useState('');
  const [pedidosSeleccionados, setPedidosSeleccionados] = useState([]);
  const [seleccionarTodos, setSeleccionarTodos] = useState(false);

  // Filtrar pedidos según el tipo de exportación
  const pedidosFiltrados = useMemo(() => {
    if (tipoExport === 'preparacion') {
      // Para orden de preparación: pedidos pendientes o en preparación (no entregados ni en camino)
      return pedidos.filter(p => p.estado === 'pendiente' || p.estado === 'en_preparacion');
    } else {
      // Para hoja de ruta: pedidos del transportista seleccionado que estén asignados
      if (!transportistaSeleccionado) return [];
      return pedidos.filter(p =>
        p.transportista_id === transportistaSeleccionado &&
        (p.estado === 'asignado' || p.estado === 'en_preparacion')
      );
    }
  }, [pedidos, tipoExport, transportistaSeleccionado]);

  // Manejar selección de todos
  const handleSeleccionarTodos = (checked) => {
    setSeleccionarTodos(checked);
    if (checked) {
      setPedidosSeleccionados(pedidosFiltrados.map(p => p.id));
    } else {
      setPedidosSeleccionados([]);
    }
  };

  // Manejar selección individual
  const handleTogglePedido = (pedidoId) => {
    setPedidosSeleccionados(prev => {
      if (prev.includes(pedidoId)) {
        const nuevo = prev.filter(id => id !== pedidoId);
        setSeleccionarTodos(false);
        return nuevo;
      } else {
        const nuevo = [...prev, pedidoId];
        if (nuevo.length === pedidosFiltrados.length) {
          setSeleccionarTodos(true);
        }
        return nuevo;
      }
    });
  };

  // Resetear selección cuando cambia el tipo o transportista
  const handleTipoChange = (tipo) => {
    setTipoExport(tipo);
    setPedidosSeleccionados([]);
    setSeleccionarTodos(false);
    if (tipo === 'preparacion') {
      setTransportistaSeleccionado('');
    }
  };

  const handleTransportistaChange = (id) => {
    setTransportistaSeleccionado(id);
    setPedidosSeleccionados([]);
    setSeleccionarTodos(false);
  };

  // Exportar
  const handleExportar = () => {
    const pedidosAExportar = pedidos.filter(p => pedidosSeleccionados.includes(p.id));
    if (pedidosAExportar.length === 0) return;

    if (tipoExport === 'preparacion') {
      onExportarOrdenPreparacion(pedidosAExportar);
    } else {
      const transportista = transportistas.find(t => t.id === transportistaSeleccionado);
      onExportarHojaRuta(transportista, pedidosAExportar);
    }
    onClose();
  };

  const getEstadoLabel = (e) => e === 'pendiente' ? 'Pendiente' : e === 'en_preparacion' ? 'En preparación' : e === 'asignado' ? 'En camino' : 'Entregado';
  const getEstadoColor = (e) => e === 'pendiente' ? 'bg-yellow-100 text-yellow-800' : e === 'en_preparacion' ? 'bg-orange-100 text-orange-800' : e === 'asignado' ? 'bg-blue-100 text-blue-800' : 'bg-green-100 text-green-800';

  return (
    <ModalBase title="Exportar Pedidos a PDF" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Selector de tipo de exportación */}
        <div>
          <label className="block text-sm font-medium mb-2">Tipo de documento</label>
          <div className="grid grid-cols-2 gap-3">
            <button
              onClick={() => handleTipoChange('preparacion')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'preparacion'
                  ? 'border-orange-500 bg-orange-50 text-orange-700'
                  : 'border-gray-200 hover:border-gray-300'
              }`}
            >
              <Package className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Orden de Preparacion</p>
                <p className="text-xs text-gray-500">Para el deposito</p>
              </div>
            </button>
            <button
              onClick={() => handleTipoChange('ruta')}
              className={`flex items-center justify-center space-x-2 p-4 rounded-lg border-2 transition-colors ${
                tipoExport === 'ruta'
                  ? 'border-blue-500 bg-blue-50 text-blue-700'
                  : 'border-gray-200 hover:border-gray-300'
              }`}
            >
              <Truck className="w-6 h-6" />
              <div className="text-left">
                <p className="font-medium">Hoja de Ruta</p>
                <p className="text-xs text-gray-500">Para el transportista</p>
              </div>
            </button>
          </div>
        </div>

        {/* Selector de transportista (solo para hoja de ruta) */}
        {tipoExport === 'ruta' && (
          <div>
            <label className="block text-sm font-medium mb-1">Transportista</label>
            <select
              value={transportistaSeleccionado}
              onChange={e => handleTransportistaChange(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
            >
              <option value="">Seleccionar transportista...</option>
              {transportistas.map(t => {
                const pedidosTransportista = pedidos.filter(p =>
                  p.transportista_id === t.id &&
                  (p.estado === 'asignado' || p.estado === 'en_preparacion')
                ).length;
                return (
                  <option key={t.id} value={t.id}>
                    {t.nombre} ({pedidosTransportista} pedidos)
                  </option>
                );
              })}
            </select>
          </div>
        )}

        {/* Lista de pedidos */}
        <div>
          <div className="flex justify-between items-center mb-2">
            <label className="block text-sm font-medium">
              Pedidos a exportar ({pedidosSeleccionados.length} de {pedidosFiltrados.length})
            </label>
            {pedidosFiltrados.length > 0 && (
              <label className="flex items-center space-x-2 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  checked={seleccionarTodos}
                  onChange={e => handleSeleccionarTodos(e.target.checked)}
                  className="w-4 h-4 rounded"
                />
                <span>Seleccionar todos</span>
              </label>
            )}
          </div>

          {pedidosFiltrados.length === 0 ? (
            <div className="text-center py-8 text-gray-500 bg-gray-50 rounded-lg">
              {tipoExport === 'ruta' && !transportistaSeleccionado ? (
                <>
                  <Truck className="w-10 h-10 mx-auto mb-2 opacity-50" />
                  <p>Selecciona un transportista para ver sus pedidos</p>
                </>
              ) : (
                <>
                  <Package className="w-10 h-10 mx-auto mb-2 opacity-50" />
                  <p>No hay pedidos disponibles para exportar</p>
                  <p className="text-xs mt-1">
                    {tipoExport === 'preparacion'
                      ? 'Solo se muestran pedidos pendientes o en preparacion'
                      : 'Solo se muestran pedidos asignados al transportista'
                    }
                  </p>
                </>
              )}
            </div>
          ) : (
            <div className="border rounded-lg max-h-64 overflow-y-auto">
              {pedidosFiltrados.map(pedido => (
                <div
                  key={pedido.id}
                  onClick={() => handleTogglePedido(pedido.id)}
                  className={`flex items-center p-3 border-b last:border-b-0 cursor-pointer transition-colors ${
                    pedidosSeleccionados.includes(pedido.id)
                      ? 'bg-blue-50'
                      : 'hover:bg-gray-50'
                  }`}
                >
                  <input
                    type="checkbox"
                    checked={pedidosSeleccionados.includes(pedido.id)}
                    onChange={() => {}}
                    className="w-4 h-4 mr-3"
                  />
                  <div className="flex-1">
                    <div className="flex items-center justify-between">
                      <p className="font-medium">#{pedido.id} - {pedido.cliente?.nombre_fantasia}</p>
                      <span className={`px-2 py-0.5 rounded-full text-xs ${getEstadoColor(pedido.estado)}`}>
                        {getEstadoLabel(pedido.estado)}
                      </span>
                    </div>
                    <p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p>
                    <p className="text-sm font-medium text-blue-600">{formatPrecio(pedido.total)}</p>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <div className="flex justify-between items-center p-4 border-t bg-gray-50">
        <p className="text-sm text-gray-600">
          {pedidosSeleccionados.length > 0 && (
            <>
              Total: {formatPrecio(
                pedidos
                  .filter(p => pedidosSeleccionados.includes(p.id))
                  .reduce((sum, p) => sum + (p.total || 0), 0)
              )}
            </>
          )}
        </p>
        <div className="flex space-x-3">
          <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">
            Cancelar
          </button>
          <button
            onClick={handleExportar}
            disabled={pedidosSeleccionados.length === 0}
            className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <FileDown className="w-4 h-4" />
            <span>Exportar PDF</span>
          </button>
        </div>
      </div>
    </ModalBase>
  );
});

// Modal para optimizar ruta de entregas
export const ModalOptimizarRuta = memo(function ModalOptimizarRuta({
  transportistas,
  pedidos,
  onOptimizar,
  onAplicarOrden,
  onClose,
  loading,
  rutaOptimizada,
  error
}) {
  const [transportistaSeleccionado, setTransportistaSeleccionado] = useState('');
  const [mostrarConfigDeposito, setMostrarConfigDeposito] = useState(false);
  const [depositoLat, setDepositoLat] = useState('');
  const [depositoLng, setDepositoLng] = useState('');
  const [depositoGuardado, setDepositoGuardado] = useState(false);

  // Cargar coordenadas del depósito al montar
  useEffect(() => {
    const coords = getDepositoCoords();
    setDepositoLat(coords.lat.toString());
    setDepositoLng(coords.lng.toString());
  }, []);

  // Obtener pedidos del transportista seleccionado
  const pedidosTransportista = useMemo(() => {
    if (!transportistaSeleccionado) return [];
    return pedidos
      .filter(p => p.transportista_id === transportistaSeleccionado && p.estado === 'asignado')
      .sort((a, b) => (a.orden_entrega || 999) - (b.orden_entrega || 999));
  }, [pedidos, transportistaSeleccionado]);

  // Verificar si hay pedidos sin coordenadas
  const pedidosSinCoordenadas = useMemo(() => {
    return pedidosTransportista.filter(p => !p.cliente?.latitud || !p.cliente?.longitud);
  }, [pedidosTransportista]);

  const handleOptimizar = () => {
    if (transportistaSeleccionado) {
      // Pasar los pedidos completos para que el hook extraiga las coordenadas
      onOptimizar(transportistaSeleccionado, pedidos);
    }
  };

  const handleGuardarDeposito = () => {
    const lat = parseFloat(depositoLat);
    const lng = parseFloat(depositoLng);
    if (!isNaN(lat) && !isNaN(lng)) {
      setDepositoCoords(lat, lng);
      setDepositoGuardado(true);
      setTimeout(() => setDepositoGuardado(false), 2000);
    }
  };

  const handleAplicar = () => {
    if (rutaOptimizada?.orden_optimizado) {
      onAplicarOrden(rutaOptimizada.orden_optimizado);
    }
  };

  const transportistaInfo = transportistas.find(t => t.id === transportistaSeleccionado);

  return (
    <ModalBase title="Optimizar Ruta de Entregas" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Configuración del depósito (colapsable) */}
        <div className="border rounded-lg">
          <button
            onClick={() => setMostrarConfigDeposito(!mostrarConfigDeposito)}
            className="w-full flex items-center justify-between p-3 hover:bg-gray-50 rounded-lg"
          >
            <div className="flex items-center space-x-2">
              <Settings className="w-5 h-5 text-gray-500" />
              <span className="font-medium">Configurar ubicacion del deposito/galpon</span>
            </div>
            <span className="text-gray-400">{mostrarConfigDeposito ? '▲' : '▼'}</span>
          </button>
          {mostrarConfigDeposito && (
            <div className="p-3 border-t bg-gray-50 space-y-3">
              <p className="text-sm text-gray-600">
                Ingresa las coordenadas de tu deposito o galpon. Este sera el punto de origen para calcular las rutas.
              </p>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-medium mb-1">Latitud</label>
                  <input
                    type="number"
                    step="0.000001"
                    value={depositoLat}
                    onChange={e => setDepositoLat(e.target.value)}
                    className="w-full px-3 py-2 border rounded-lg text-sm"
                    placeholder="-26.8241"
                  />
                </div>
                <div>
                  <label className="block text-xs font-medium mb-1">Longitud</label>
                  <input
                    type="number"
                    step="0.000001"
                    value={depositoLng}
                    onChange={e => setDepositoLng(e.target.value)}
                    className="w-full px-3 py-2 border rounded-lg text-sm"
                    placeholder="-65.2226"
                  />
                </div>
              </div>
              <div className="flex items-center justify-between">
                <p className="text-xs text-gray-500">
                  Tip: Busca tu direccion en Google Maps, click derecho y copia las coordenadas
                </p>
                <button
                  onClick={handleGuardarDeposito}
                  className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 text-sm"
                >
                  {depositoGuardado ? (
                    <>
                      <Check className="w-4 h-4" />
                      <span>Guardado!</span>
                    </>
                  ) : (
                    <>
                      <Save className="w-4 h-4" />
                      <span>Guardar</span>
                    </>
                  )}
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Selector de transportista */}
        <div>
          <label className="block text-sm font-medium mb-1">Seleccionar Transportista</label>
          <select
            value={transportistaSeleccionado}
            onChange={e => setTransportistaSeleccionado(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg"
            disabled={loading}
          >
            <option value="">Seleccionar...</option>
            {transportistas.map(t => {
              const cantPedidos = pedidos.filter(p =>
                p.transportista_id === t.id && p.estado === 'asignado'
              ).length;
              return (
                <option key={t.id} value={t.id}>
                  {t.nombre} ({cantPedidos} pedidos asignados)
                </option>
              );
            })}
          </select>
        </div>

        {/* Info del transportista y sus pedidos */}
        {transportistaSeleccionado && (
          <>
            <div className="bg-blue-50 border border-blue-200 rounded-lg p-3">
              <div className="flex items-center space-x-2 mb-2">
                <Truck className="w-5 h-5 text-blue-600" />
                <span className="font-medium">{transportistaInfo?.nombre}</span>
              </div>
              <p className="text-sm text-blue-700">
                {pedidosTransportista.length} pedido(s) asignado(s)
              </p>
            </div>

            {/* Advertencia de pedidos sin coordenadas */}
            {pedidosSinCoordenadas.length > 0 && (
              <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3">
                <div className="flex items-start space-x-2">
                  <AlertTriangle className="w-5 h-5 text-yellow-600 mt-0.5" />
                  <div>
                    <p className="font-medium text-yellow-800">Pedidos sin coordenadas</p>
                    <p className="text-sm text-yellow-700 mt-1">
                      Los siguientes clientes no tienen coordenadas registradas y no seran incluidos en la optimizacion:
                    </p>
                    <ul className="text-sm text-yellow-700 mt-2 space-y-1">
                      {pedidosSinCoordenadas.map(p => (
                        <li key={p.id}>• #{p.id} - {p.cliente?.nombre_fantasia}</li>
                      ))}
                    </ul>
                  </div>
                </div>
              </div>
            )}

            {/* Lista de pedidos actuales */}
            {pedidosTransportista.length > 0 && (
              <div>
                <h3 className="text-sm font-medium mb-2">Pedidos del transportista:</h3>
                <div className="border rounded-lg max-h-48 overflow-y-auto">
                  {pedidosTransportista.map((pedido, index) => (
                    <div key={pedido.id} className="flex items-center p-3 border-b last:border-b-0 hover:bg-gray-50">
                      <div className="flex items-center justify-center w-8 h-8 rounded-full bg-gray-100 mr-3">
                        {pedido.orden_entrega ? (
                          <span className="text-sm font-bold text-blue-600">{pedido.orden_entrega}</span>
                        ) : (
                          <span className="text-xs text-gray-400">-</span>
                        )}
                      </div>
                      <div className="flex-1">
                        <p className="font-medium">#{pedido.id} - {pedido.cliente?.nombre_fantasia}</p>
                        <p className="text-sm text-gray-500">{pedido.cliente?.direccion}</p>
                      </div>
                      {pedido.cliente?.latitud && pedido.cliente?.longitud ? (
                        <MapPin className="w-4 h-4 text-green-500" title="Con coordenadas" />
                      ) : (
                        <MapPin className="w-4 h-4 text-gray-300" title="Sin coordenadas" />
                      )}
                    </div>
                  ))}
                </div>
              </div>
            )}
          </>
        )}

        {/* Error */}
        {error && (
          <div className="bg-red-50 border border-red-200 rounded-lg p-3">
            <div className="flex items-center space-x-2">
              <AlertTriangle className="w-5 h-5 text-red-600" />
              <p className="text-red-700">{error}</p>
            </div>
          </div>
        )}

        {/* Resultado de la optimización */}
        {rutaOptimizada && rutaOptimizada.total_pedidos > 0 && (
          <div className="bg-green-50 border border-green-200 rounded-lg p-4">
            <div className="flex items-center space-x-2 mb-3">
              <Route className="w-5 h-5 text-green-600" />
              <span className="font-medium text-green-800">Ruta optimizada</span>
            </div>
            <div className="grid grid-cols-2 gap-4 mb-3">
              <div className="flex items-center space-x-2">
                <Clock className="w-4 h-4 text-gray-500" />
                <span className="text-sm">
                  Duracion: <strong>{rutaOptimizada.duracion_formato || 'N/A'}</strong>
                </span>
              </div>
              <div className="flex items-center space-x-2">
                <Navigation className="w-4 h-4 text-gray-500" />
                <span className="text-sm">
                  Distancia: <strong>{rutaOptimizada.distancia_formato || 'N/A'}</strong>
                </span>
              </div>
            </div>
            <p className="text-sm text-green-700 mb-3">
              Nuevo orden de entrega sugerido:
            </p>
            <div className="border border-green-300 rounded-lg bg-white max-h-40 overflow-y-auto">
              {rutaOptimizada.orden_optimizado?.map((item, index) => (
                <div key={item.pedido_id} className="flex items-center p-2 border-b last:border-b-0">
                  <div className="flex items-center justify-center w-6 h-6 rounded-full bg-green-600 text-white text-xs font-bold mr-3">
                    {item.orden}
                  </div>
                  <div className="flex-1">
                    <p className="text-sm font-medium">#{item.pedido_id} - {item.cliente}</p>
                    <p className="text-xs text-gray-500">{item.direccion}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {rutaOptimizada && rutaOptimizada.total_pedidos === 0 && (
          <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3 text-center">
            <p className="text-yellow-700">No hay pedidos con coordenadas para optimizar</p>
          </div>
        )}
      </div>

      <div className="flex justify-between items-center p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">
          Cerrar
        </button>
        <div className="flex space-x-3">
          <button
            onClick={handleOptimizar}
            disabled={!transportistaSeleccionado || loading || pedidosTransportista.length === 0}
            className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {loading ? (
              <Loader2 className="w-4 h-4 animate-spin" />
            ) : (
              <Route className="w-4 h-4" />
            )}
            <span>{loading ? 'Optimizando...' : 'Optimizar Ruta'}</span>
          </button>
          {rutaOptimizada?.orden_optimizado && (
            <button
              onClick={handleAplicar}
              disabled={loading}
              className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50"
            >
              <Check className="w-4 h-4" />
              <span>Aplicar Orden</span>
            </button>
          )}
        </div>
      </div>
    </ModalBase>
  );
});

