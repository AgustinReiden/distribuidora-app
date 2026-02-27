import { useState, useMemo, memo } from 'react';
import { X, Loader2, Search, MapPin, Tag } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { usePrecioMayorista } from '../../hooks/usePrecioMayorista';
import type { ProductoDB, ClienteDB } from '../../types';

/** Item en el pedido */
export interface PedidoItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
}

/** Estado del nuevo pedido */
export interface NuevoPedidoState {
  clienteId: string;
  items: PedidoItem[];
  notas: string;
  formaPago?: string;
  estadoPago?: string;
  montoPagado?: number;
}

/** Datos del cliente a crear */
export interface NuevoClienteData {
  nombre: string;
  nombreFantasia: string;
  direccion: string;
  telefono: string;
  zona: string;
  razonSocial?: string; // Se usa "nombre" como razonSocial en creación rápida
  latitud?: number | null;
  longitud?: number | null;
}

/** Advertencia de stock */
export interface StockWarning {
  tipo: 'error' | 'warning';
  mensaje: string;
}

/** Categoria option type - can be string or object */
export type CategoriaOption = string | { id: string; nombre: string; descripcion?: string };

 
/** Props del componente ModalPedido */
export interface ModalPedidoProps {
  /** Lista de productos disponibles */
  productos: ProductoDB[];
  /** Lista de clientes */
  clientes: ClienteDB[];
  /** Categorías disponibles */
  categorias: string[] | CategoriaOption[];
  /** Estado del nuevo pedido */
  nuevoPedido: NuevoPedidoState;
  /** Callback al cerrar */
  onClose: () => void;
  /** Callback al cambiar cliente */
  onClienteChange: (clienteId: string) => void;
  /** Callback al agregar item */
  onAgregarItem: (productoId: string, cantidad?: number, precio?: number) => void;
  /** Callback al actualizar cantidad */
  onActualizarCantidad: (productoId: string, cantidad: number) => void;
  /** Callback al crear cliente */
  onCrearCliente: (cliente: Record<string, unknown>) => Promise<{ id: string | number }>;
  /** Callback al guardar pedido */
  onGuardar: () => void | Promise<void>;
  /** Indica si está guardando */
  guardando: boolean;
  /** Si es admin */
  isAdmin?: boolean;
  /** Si es preventista */
  isPreventista?: boolean;
  /** Callback al cambiar notas */
  onNotasChange?: (notas: string) => void;
  /** Callback al cambiar forma de pago */
  onFormaPagoChange?: (formaPago: string) => void;
  /** Callback al cambiar estado de pago */
  onEstadoPagoChange?: (estadoPago: string) => void;
  /** Callback al cambiar monto pagado */
  onMontoPagadoChange?: (monto: number) => void;
  /** Si está offline */
  isOffline?: boolean;
}
 

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
}: ModalPedidoProps) {
  const [busquedaProducto, setBusquedaProducto] = useState<string>('');
  const [busquedaCliente, setBusquedaCliente] = useState<string>('');
  const [categoriaSeleccionada, setCategoriaSeleccionada] = useState<string>('');
  const [mostrarNuevoCliente, setMostrarNuevoCliente] = useState<boolean>(false);
  const [nuevoCliente, setNuevoCliente] = useState<NuevoClienteData>({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '', latitud: null, longitud: null });
  const [guardandoCliente, setGuardandoCliente] = useState<boolean>(false);

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
    // clienteId is a string, compare directly with string id
    return clientes.find(c => String(c.id) === String(nuevoPedido.clienteId)) || null;
  }, [clientes, nuevoPedido.clienteId]);

  const handleCrearClienteRapido = async (): Promise<void> => {
    const nombre = nuevoCliente.nombre?.trim();
    const nombreFantasia = nuevoCliente.nombreFantasia?.trim();
    const direccion = nuevoCliente.direccion?.trim();
    if (!nombre || !nombreFantasia || !direccion) return;
    setGuardandoCliente(true);
    try {
      // Usar "nombre" como razonSocial (requerido por la DB)
      const clienteData = {
        ...nuevoCliente,
        razonSocial: nombre, // El "Nombre completo" es la razón social
      };
      const cliente = await onCrearCliente(clienteData);
      onClienteChange(cliente.id.toString());
      setMostrarNuevoCliente(false);
      setNuevoCliente({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '', latitud: null, longitud: null });
    } catch (err) {
      console.error('Error al crear cliente rápido:', err)
    }
    setGuardandoCliente(false);
  };

  const getStockWarning = (productoId: string, cantidadEnPedido: number): StockWarning | null => {
    const producto = productos.find(p => p.id === productoId);
    if (!producto) return null;
    const stockDisponible = producto.stock - cantidadEnPedido;
    const stockMinimo = producto.stock_minimo || 10;
    if (stockDisponible < 0) return { tipo: 'error', mensaje: `Sin stock! Disponible: ${producto.stock}` };
    if (stockDisponible < stockMinimo) return { tipo: 'warning', mensaje: `Stock bajo: quedaran ${stockDisponible}` };
    return null;
  };

  const calcularTotal = (): number => nuevoPedido.items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);

  // Precios mayoristas
  const { preciosResueltos, faltantes, totalMayorista, totalOriginal, ahorro, hayMayorista } = usePrecioMayorista(nuevoPedido.items);

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-hidden flex flex-col">
        <div className="flex justify-between items-center p-4 border-b dark:border-gray-700">
          <h2 className="text-xl font-semibold dark:text-white">Nuevo Pedido</h2>
          <button onClick={onClose}><X className="w-6 h-6 text-gray-500 dark:text-gray-400" /></button>
        </div>

        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Seccion Cliente */}
          <div>
            <div className="flex justify-between items-center mb-1">
              <label className="block text-sm font-medium dark:text-gray-200">Cliente *</label>
              {(isAdmin || isPreventista) && (
                <button onClick={() => setMostrarNuevoCliente(!mostrarNuevoCliente)} className="text-sm text-blue-600">
                  {mostrarNuevoCliente ? 'Cancelar' : '+ Nuevo'}
                </button>
              )}
            </div>

            {mostrarNuevoCliente ? (
              <div className="border rounded-lg p-3 space-y-3 bg-blue-50 dark:bg-gray-700 dark:border-gray-600">
                <input type="text" value={nuevoCliente.nombreFantasia} onChange={e => setNuevoCliente({ ...nuevoCliente, nombreFantasia: e.target.value })} className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-800 dark:border-gray-600 dark:text-white" placeholder="Nombre fantasia *" />
                <input type="text" value={nuevoCliente.nombre} onChange={e => setNuevoCliente({ ...nuevoCliente, nombre: e.target.value })} className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-800 dark:border-gray-600 dark:text-white" placeholder="Nombre completo *" />
                <AddressAutocomplete
                  value={nuevoCliente.direccion}
                  onChange={(val: string) => setNuevoCliente({ ...nuevoCliente, direccion: val })}
                  onSelect={(result) => {
                    setNuevoCliente({ ...nuevoCliente, direccion: result.direccion, latitud: result.latitud, longitud: result.longitud });
                  }}
                  placeholder="Buscar dirección..."
                />
                {nuevoCliente.latitud && nuevoCliente.longitud && (
                  <div className="flex items-center text-xs text-green-600 bg-green-50 dark:bg-green-900/20 px-3 py-2 rounded-lg">
                    <MapPin className="w-3 h-3 mr-1" />
                    <span>Ubicación guardada</span>
                  </div>
                )}
                <button onClick={handleCrearClienteRapido} disabled={guardandoCliente} className="w-full py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-blue-400">
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
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Notas / Observaciones</label>
            <textarea
              value={nuevoPedido.notas || ''}
              onChange={e => onNotasChange && onNotasChange(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              placeholder="Observaciones importantes para la preparacion del pedido..."
              rows={2}
            />
          </div>

          {/* Seccion Forma de Pago y Estado de Pago */}
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Forma de Pago</label>
              <select
                value={nuevoPedido.formaPago || 'efectivo'}
                onChange={e => onFormaPagoChange && onFormaPagoChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              >
                <option value="efectivo">Efectivo</option>
                <option value="transferencia">Transferencia</option>
                <option value="cheque">Cheque</option>
                <option value="cuenta_corriente">Cuenta Corriente</option>
                <option value="tarjeta">Tarjeta</option>
              </select>
            </div>
            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Estado de Pago</label>
              <select
                value={nuevoPedido.estadoPago || 'pendiente'}
                onChange={e => onEstadoPagoChange && onEstadoPagoChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white"
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
              {(nuevoPedido.montoPagado ?? 0) > 0 && (
                <p className="text-sm text-yellow-700 mt-2">
                  Resta por pagar: {formatPrecio(calcularTotal() - (nuevoPedido.montoPagado ?? 0))}
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
                {categorias.map((cat) => {
                  const catValue = typeof cat === 'string' ? cat : cat.nombre;
                  const catKey = typeof cat === 'string' ? cat : cat.id;
                  return (
                    <button
                      key={catKey}
                      onClick={() => setCategoriaSeleccionada(catValue)}
                      className={`px-3 py-1 rounded-full text-sm font-medium transition-colors ${
                        categoriaSeleccionada === catValue
                          ? 'bg-blue-600 text-white'
                          : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                      }`}
                    >
                      {catValue}
                    </button>
                  );
                })}
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
                  const precioInfo = preciosResueltos.get(String(item.productoId));
                  const esMayorista = precioInfo?.esMayorista || false;
                  const precioMostrar = esMayorista ? precioInfo!.precioResuelto : item.precioUnitario;
                  const subtotal = precioMostrar * item.cantidad;
                  return (
                    <div key={item.productoId} className="p-3">
                      <div className="flex justify-between items-center">
                        <div>
                          <div className="flex items-center gap-2">
                            <p className="font-medium">{prod?.nombre}</p>
                            {esMayorista && (
                              <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-green-100 text-green-700 rounded-full font-medium">
                                <Tag className="w-3 h-3" />
                                {precioInfo?.etiqueta || 'Mayorista'}
                              </span>
                            )}
                          </div>
                          {esMayorista ? (
                            <p className="text-sm">
                              <span className="text-gray-400 line-through">{formatPrecio(item.precioUnitario)}</span>
                              <span className="ml-1.5 text-green-600 font-medium">{formatPrecio(precioInfo!.precioResuelto)} c/u</span>
                            </p>
                          ) : (
                            <p className="text-sm text-gray-500">{formatPrecio(item.precioUnitario)} c/u</p>
                          )}
                        </div>
                        <div className="flex items-center space-x-3">
                          <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, item.cantidad - 1); }} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300">-</button>
                          <span className="w-8 text-center font-medium">{item.cantidad}</span>
                          <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, item.cantidad + 1); }} className="w-8 h-8 rounded-full bg-gray-200 hover:bg-gray-300">+</button>
                          <p className="w-24 text-right font-semibold">{formatPrecio(subtotal)}</p>
                        </div>
                      </div>
                      {warning && <p className={`text-sm mt-1 ${warning.tipo === 'error' ? 'text-red-600' : 'text-yellow-600'}`}>{warning.mensaje}</p>}
                    </div>
                  );
                })}
              </div>

              {/* Nudges para alcanzar siguiente tier */}
              {faltantes.length > 0 && (
                <div className="mt-2 space-y-1">
                  {faltantes.map((f, i) => (
                    <p key={i} className="text-sm text-blue-600 bg-blue-50 dark:bg-blue-900/20 px-3 py-1.5 rounded-lg">
                      Agrega {f.faltante} mas de <strong>{f.grupoNombre}</strong> para precio {f.etiqueta || 'mayorista'} ({formatPrecio(f.precioTier)} c/u)
                    </p>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        <div className="border-t bg-gray-50 p-4">
          <div className="flex justify-between items-center mb-4">
            <span className="text-lg font-medium">Total</span>
            <div className="text-right">
              {hayMayorista ? (
                <>
                  <span className="text-sm text-gray-400 line-through mr-2">{formatPrecio(totalOriginal)}</span>
                  <span className="text-2xl font-bold text-green-600">{formatPrecio(totalMayorista)}</span>
                  <p className="text-xs text-green-600 font-medium">Ahorro: {formatPrecio(ahorro)}</p>
                </>
              ) : (
                <span className="text-2xl font-bold text-blue-600">{formatPrecio(calcularTotal())}</span>
              )}
            </div>
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
