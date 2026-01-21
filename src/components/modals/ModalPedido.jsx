import React, { useState, useMemo, memo } from 'react';
import { X, Loader2, Search } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';

const ModalPedido = memo(function ModalPedido({
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
  onEstadoPagoChange,
  onMontoPagadoChange
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
    const busquedaLower = busquedaCliente.toLowerCase();
    return clientes.filter(c =>
      c.nombre_fantasia?.toLowerCase().includes(busquedaLower) ||
      c.razon_social?.toLowerCase().includes(busquedaLower) ||
      c.direccion?.toLowerCase().includes(busquedaLower) ||
      c.cuit?.includes(busquedaCliente.replace(/-/g, ''))
    ).slice(0, 8);
  }, [clientes, busquedaCliente]);

  const clienteSeleccionado = useMemo(() => {
    if (!nuevoPedido.clienteId) return null;
    const id = typeof nuevoPedido.clienteId === 'number'
      ? nuevoPedido.clienteId
      : parseInt(nuevoPedido.clienteId, 10);
    return Number.isNaN(id) ? null : clientes.find(c => c.id === id);
  }, [clientes, nuevoPedido.clienteId]);

  const handleCrearClienteRapido = async () => {
    const nombre = nuevoCliente.nombre?.trim();
    const nombreFantasia = nuevoCliente.nombreFantasia?.trim();
    const direccion = nuevoCliente.direccion?.trim();
    if (!nombre || !nombreFantasia || !direccion) return;
    setGuardandoCliente(true);
    try {
      const cliente = await onCrearCliente(nuevoCliente);
      onClienteChange(cliente.id.toString());
      setMostrarNuevoCliente(false);
      setNuevoCliente({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '' });
    } catch {
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
    if (stockDisponible < stockMinimo) return { tipo: 'warning', mensaje: `Stock bajo: quedaran ${stockDisponible}` };
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
          {/* Seccion Cliente */}
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
                <input type="text" value={nuevoCliente.nombreFantasia} onChange={e => setNuevoCliente({ ...nuevoCliente, nombreFantasia: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Nombre fantasia *" />
                <input type="text" value={nuevoCliente.nombre} onChange={e => setNuevoCliente({ ...nuevoCliente, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Nombre completo *" />
                <input type="text" value={nuevoCliente.direccion} onChange={e => setNuevoCliente({ ...nuevoCliente, direccion: e.target.value })} className="w-full px-3 py-2 border rounded-lg" placeholder="Direccion *" />
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
                  <input type="text" value={busquedaCliente} onChange={e => setBusquedaCliente(e.target.value)} className="w-full pl-10 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white" placeholder="Buscar por nombre, razón social o CUIT..." />
                </div>
                {clientesFiltrados.length > 0 && (
                  <div className="border dark:border-gray-600 rounded-lg max-h-40 overflow-y-auto mt-2">
                    {clientesFiltrados.map(c => (
                      <div key={c.id} className="p-3 hover:bg-blue-50 dark:hover:bg-blue-900/30 border-b dark:border-gray-600 cursor-pointer" onClick={() => { onClienteChange(c.id.toString()); setBusquedaCliente(''); }}>
                        <p className="font-medium dark:text-white">{c.nombre_fantasia}</p>
                        {c.razon_social && c.razon_social !== c.nombre_fantasia && (
                          <p className="text-xs text-gray-400">{c.razon_social}</p>
                        )}
                        <p className="text-sm text-gray-500 dark:text-gray-400">{c.direccion}</p>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Seccion Notas */}
          <div>
            <label className="block text-sm font-medium mb-1">Notas / Observaciones</label>
            <textarea
              value={nuevoPedido.notas || ''}
              onChange={e => onNotasChange && onNotasChange(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg"
              placeholder="Observaciones importantes para la preparacion del pedido..."
              rows={2}
            />
          </div>

          {/* Seccion Forma de Pago y Estado de Pago */}
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

          {/* Monto pagado si es pago parcial */}
          {nuevoPedido.estadoPago === 'parcial' && (
            <div className="p-3 bg-yellow-50 border border-yellow-200 rounded-lg">
              <label className="block text-sm font-medium mb-1 text-yellow-800">Monto del pago parcial *</label>
              <div className="flex items-center gap-2">
                <span className="text-lg font-semibold text-yellow-700">$</span>
                <input
                  type="number"
                  min="0"
                  step="0.01"
                  max={calcularTotal()}
                  value={nuevoPedido.montoPagado || ''}
                  onChange={e => onMontoPagadoChange && onMontoPagadoChange(parseFloat(e.target.value) || 0)}
                  className="flex-1 px-3 py-2 border border-yellow-300 rounded-lg focus:ring-2 focus:ring-yellow-500 bg-white"
                  placeholder="Ingrese el monto pagado"
                />
              </div>
              {nuevoPedido.montoPagado > 0 && (
                <p className="text-sm text-yellow-700 mt-2">
                  Resta por pagar: {formatPrecio(calcularTotal() - nuevoPedido.montoPagado)}
                </p>
              )}
            </div>
          )}

          {/* Seccion Productos con filtro por categoria */}
          <div>
            <label className="block text-sm font-medium mb-1">Agregar Productos</label>

            {/* Filtros de categoria */}
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

export default ModalPedido;
