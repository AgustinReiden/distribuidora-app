import { useState, useMemo, memo } from 'react';
import { X, Loader2, Search, MapPin, Tag, Calendar, Trash2, Pencil, Gift } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { usePromocionPedido } from '../../hooks/usePromocionPedido';
import type { ProductoDB, ClienteDB } from '../../types';

/** Item en el pedido */
export interface PedidoItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
  precioOverride?: boolean;
}

/** Estado del nuevo pedido */
export interface NuevoPedidoState {
  clienteId: string;
  items: PedidoItem[];
  notas: string;
  formaPago?: string;
  estadoPago?: string;
  montoPagado?: number;
  fecha?: string;
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
  /** Callback al cambiar fecha del pedido */
  onFechaChange?: (fecha: string) => void;
  /** Callback al actualizar precio (solo admin) */
  onActualizarPrecio?: (productoId: string, precio: number) => void;
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
  onMontoPagadoChange,
  onFechaChange,
  onActualizarPrecio
}: ModalPedidoProps) {
  const [busquedaProducto, setBusquedaProducto] = useState<string>('');
  const [busquedaCliente, setBusquedaCliente] = useState<string>('');
  const [editingPriceId, setEditingPriceId] = useState<string | null>(null);
  const [editingPriceValue, setEditingPriceValue] = useState<string>('');
  const [categoriaSeleccionada, setCategoriaSeleccionada] = useState<string>('');
  const [mostrarNuevoCliente, setMostrarNuevoCliente] = useState<boolean>(false);
  const [nuevoCliente, setNuevoCliente] = useState<NuevoClienteData>({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '', latitud: null, longitud: null });
  const [guardandoCliente, setGuardandoCliente] = useState<boolean>(false);
  const [errorCliente, setErrorCliente] = useState<string>('');

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
    // Normalizar: trim, colapsar espacios, reemplazar non-breaking spaces
    const busquedaNorm = busquedaCliente.replace(/[\s\u00A0]+/g, ' ').trim().toLowerCase();
    if (!busquedaNorm) return [];
    return clientes.filter(c => {
      const norm = (s: string | null | undefined) => s?.replace(/[\s\u00A0]+/g, ' ').trim().toLowerCase() ?? '';
      return norm(c.nombre_fantasia).includes(busquedaNorm) ||
        norm(c.razon_social).includes(busquedaNorm) ||
        norm(c.direccion).includes(busquedaNorm) ||
        c.cuit?.includes(busquedaCliente.replace(/[-\s]/g, '')) ||
        (c.codigo != null && String(c.codigo).includes(busquedaCliente.trim()));
    }).slice(0, 8);
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

    // Validación con feedback al usuario
    const camposFaltantes: string[] = [];
    if (!nombreFantasia) camposFaltantes.push('Nombre fantasía');
    if (!nombre) camposFaltantes.push('Nombre completo');
    if (!direccion) camposFaltantes.push('Dirección');
    if (camposFaltantes.length > 0) {
      setErrorCliente(`Completá: ${camposFaltantes.join(', ')}`);
      return;
    }
    setErrorCliente('');

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
      const errorMsg = err instanceof Error ? err.message : 'Error al crear cliente';
      setErrorCliente(errorMsg);
    }
    setGuardandoCliente(false);
  };

  const getStockWarning = (productoId: string, cantidadEnPedido: number): StockWarning | null => {
    const producto = productos.find(p => p.id === productoId);
    if (!producto) return null;
    // Bonificaciones NO descuentan stock — solo items comprados
    const stockDisponible = producto.stock - cantidadEnPedido;
    const stockMinimo = producto.stock_minimo || 10;
    if (stockDisponible < 0) return { tipo: 'error', mensaje: `Sin stock! Disponible: ${producto.stock}` };
    if (stockDisponible < stockMinimo) return { tipo: 'warning', mensaje: `Stock bajo: quedaran ${stockDisponible}` };
    return null;
  };

  const calcularTotal = (): number => nuevoPedido.items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);

  // Precios mayoristas, promociones y cantidades mínimas
  const { preciosResueltos, faltantes, faltantesBonificacion, promoResolucion, totalFinal, totalOriginal, ahorro, hayDescuento, moqMap, violacionesMOQ } = usePromocionPedido(nuevoPedido.items);

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
                <button onClick={() => { setMostrarNuevoCliente(!mostrarNuevoCliente); setErrorCliente(''); }} className="text-sm text-blue-600">
                  {mostrarNuevoCliente ? 'Cancelar' : '+ Nuevo'}
                </button>
              )}
            </div>

            {mostrarNuevoCliente ? (
              <div className="border rounded-lg p-3 space-y-3 bg-blue-50 dark:bg-gray-700 dark:border-gray-600">
                <input type="text" value={nuevoCliente.nombreFantasia} onChange={e => setNuevoCliente(prev => ({ ...prev, nombreFantasia: e.target.value }))} className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-800 dark:border-gray-600 dark:text-white" placeholder="Nombre fantasia *" />
                <input type="text" value={nuevoCliente.nombre} onChange={e => setNuevoCliente(prev => ({ ...prev, nombre: e.target.value }))} className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-800 dark:border-gray-600 dark:text-white" placeholder="Nombre completo *" />
                <AddressAutocomplete
                  value={nuevoCliente.direccion}
                  onChange={(val: string) => setNuevoCliente(prev => ({ ...prev, direccion: val }))}
                  onSelect={(result) => {
                    setNuevoCliente(prev => ({ ...prev, direccion: result.direccion, latitud: result.latitud, longitud: result.longitud }));
                  }}
                  placeholder="Buscar dirección..."
                />
                {nuevoCliente.latitud && nuevoCliente.longitud && (
                  <div className="flex items-center text-xs text-green-600 bg-green-50 dark:bg-green-900/20 px-3 py-2 rounded-lg">
                    <MapPin className="w-3 h-3 mr-1" />
                    <span>Ubicación guardada</span>
                  </div>
                )}
                {errorCliente && (
                  <p className="text-sm text-red-600 bg-red-50 dark:bg-red-900/20 dark:text-red-400 px-3 py-2 rounded-lg">{errorCliente}</p>
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

          {/* Fecha del pedido - compact inline */}
          <div className="flex items-center gap-3">
            <label className="text-sm font-medium dark:text-gray-200 whitespace-nowrap flex items-center gap-1">
              <Calendar className="w-4 h-4" />
              Fecha
            </label>
            <input
              type="date"
              value={nuevoPedido.fecha || new Date().toISOString().split('T')[0]}
              onChange={e => onFechaChange && onFechaChange(e.target.value)}
              max={new Date().toISOString().split('T')[0]}
              className="flex-1 px-3 py-1.5 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
            {nuevoPedido.fecha && nuevoPedido.fecha !== new Date().toISOString().split('T')[0] && (
              <p className="text-xs text-amber-600 whitespace-nowrap">Fecha distinta a hoy</p>
            )}
          </div>

          {/* Seccion Productos con filtro por categoria */}
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Agregar Productos</label>

            {/* Filtros de categoria */}
            {categorias.length > 0 && (
              <div className="flex flex-wrap gap-1.5 mb-2">
                <button
                  onClick={() => setCategoriaSeleccionada('')}
                  className={`px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${
                    categoriaSeleccionada === ''
                      ? 'bg-blue-600 text-white'
                      : 'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300'
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
                      className={`px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${
                        categoriaSeleccionada === catValue
                          ? 'bg-blue-600 text-white'
                          : 'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300'
                      }`}
                    >
                      {catValue}
                    </button>
                  );
                })}
              </div>
            )}

            <div className="relative">
              <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-4 h-4" />
              <input type="text" value={busquedaProducto} onChange={e => setBusquedaProducto(e.target.value)} className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white" placeholder="Buscar producto..." />
            </div>
          </div>

          {/* Lista de productos disponibles - altura adaptativa */}
          <div className="border dark:border-gray-600 rounded-lg max-h-[40vh] sm:max-h-64 overflow-y-auto">
            {productosFiltrados.length === 0 ? (
              <p className="p-4 text-center text-gray-500 dark:text-gray-400">No se encontraron productos</p>
            ) : (
              productosFiltrados.map(p => {
                const moq = moqMap.get(String(p.id))
                const yaAgregado = nuevoPedido.items.some(i => i.productoId === p.id);
                return (
                  <div
                    key={p.id}
                    className={`flex justify-between items-center px-3 py-2.5 border-b dark:border-gray-600 cursor-pointer transition-colors ${
                      yaAgregado
                        ? 'bg-blue-50 dark:bg-blue-900/20'
                        : 'hover:bg-gray-50 dark:hover:bg-gray-700'
                    }`}
                    onClick={() => onAgregarItem(p.id, moq || 1)}
                  >
                    <div className="min-w-0 flex-1">
                      <p className="font-medium text-sm dark:text-white truncate">{p.nombre}</p>
                      <p className="text-xs text-gray-500 dark:text-gray-400">
                        Stock: {p.stock}
                        {p.categoria && <span className="ml-1.5 px-1.5 py-0.5 bg-gray-100 dark:bg-gray-600 rounded text-xs">{p.categoria}</span>}
                        {moq && moq > 1 && <span className="ml-1.5 px-1.5 py-0.5 bg-amber-100 text-amber-700 rounded text-xs font-medium">Min: {moq}</span>}
                      </p>
                    </div>
                    <div className="text-right ml-3 shrink-0">
                      <p className="font-semibold text-sm text-blue-600 dark:text-blue-400">{formatPrecio(p.precio)}</p>
                      <span className="text-xs text-blue-500">{yaAgregado ? '+ Mas' : '+ Agregar'}</span>
                    </div>
                  </div>
                )
              })
            )}
          </div>

          {/* Items del pedido */}
          {nuevoPedido.items.length > 0 && (
            <div>
              <h3 className="font-medium mb-2 dark:text-white text-sm">Productos en el pedido ({nuevoPedido.items.length})</h3>
              <div className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-600">
                {nuevoPedido.items.map(item => {
                  const prod = productos.find(p => p.id === item.productoId);
                  const warning = getStockWarning(item.productoId, item.cantidad);
                  const precioInfo = preciosResueltos.get(String(item.productoId));
                  const esOverride = item.precioOverride || false;
                  const esMayorista = !esOverride && (precioInfo?.esMayorista || false);
                  const precioMostrar = esOverride ? item.precioUnitario : (esMayorista ? precioInfo!.precioResuelto : item.precioUnitario);
                  const subtotal = precioMostrar * item.cantidad;
                  const itemMoq = moqMap.get(String(item.productoId));
                  const minCantidad = itemMoq && itemMoq > 1 ? itemMoq : 1;
                  const isEditingPrice = editingPriceId === item.productoId;
                  return (
                    <div key={item.productoId} className="px-3 py-2.5">
                      <div className="flex justify-between items-center gap-2">
                        <div className="min-w-0 flex-1">
                          <div className="flex items-center gap-1.5">
                            <p className="font-medium text-sm dark:text-white truncate">{prod?.nombre}</p>
                            {esOverride && (
                              <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-orange-100 text-orange-700 rounded-full font-medium shrink-0">
                                <Pencil className="w-3 h-3" />
                                Manual
                              </span>
                            )}
                            {esMayorista && (
                              <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-green-100 text-green-700 rounded-full font-medium shrink-0">
                                <Tag className="w-3 h-3" />
                                {precioInfo?.etiqueta || 'Mayorista'}
                              </span>
                            )}
                          </div>
                          {isEditingPrice && isAdmin && onActualizarPrecio ? (
                            <div className="flex items-center gap-1 mt-0.5">
                              <span className="text-xs text-orange-600">$</span>
                              <input
                                type="number"
                                inputMode="decimal"
                                step="0.01"
                                min="0.01"
                                value={editingPriceValue}
                                onChange={e => setEditingPriceValue(e.target.value)}
                                onKeyDown={e => {
                                  if (e.key === 'Enter') {
                                    const newPrice = parseFloat(editingPriceValue);
                                    if (newPrice > 0) onActualizarPrecio(item.productoId, newPrice);
                                    setEditingPriceId(null);
                                  } else if (e.key === 'Escape') {
                                    setEditingPriceId(null);
                                  }
                                }}
                                onBlur={() => {
                                  const newPrice = parseFloat(editingPriceValue);
                                  if (newPrice > 0) onActualizarPrecio(item.productoId, newPrice);
                                  setEditingPriceId(null);
                                }}
                                className="w-24 px-2 py-0.5 text-xs border border-orange-300 rounded bg-orange-50 dark:bg-orange-900/20 dark:border-orange-600 dark:text-white focus:ring-1 focus:ring-orange-500 focus:outline-none"
                                autoFocus
                              />
                              <span className="text-xs text-orange-600">c/u</span>
                            </div>
                          ) : esOverride ? (
                            <p
                              className={`text-xs text-orange-600 font-medium ${isAdmin && onActualizarPrecio ? 'cursor-pointer hover:underline' : ''}`}
                              onClick={() => {
                                if (isAdmin && onActualizarPrecio) {
                                  setEditingPriceId(item.productoId);
                                  setEditingPriceValue(String(item.precioUnitario));
                                }
                              }}
                            >
                              {formatPrecio(item.precioUnitario)} c/u {isAdmin && onActualizarPrecio && <Pencil className="w-3 h-3 inline ml-0.5" />}
                            </p>
                          ) : esMayorista ? (
                            <p className={`text-xs ${isAdmin && onActualizarPrecio ? 'cursor-pointer hover:underline' : ''}`}
                              onClick={() => {
                                if (isAdmin && onActualizarPrecio) {
                                  setEditingPriceId(item.productoId);
                                  setEditingPriceValue(String(precioInfo!.precioResuelto));
                                }
                              }}
                            >
                              <span className="text-gray-400 line-through">{formatPrecio(item.precioUnitario)}</span>
                              <span className="ml-1 text-green-600 font-medium">{formatPrecio(precioInfo!.precioResuelto)} c/u</span>
                              {isAdmin && onActualizarPrecio && <Pencil className="w-3 h-3 inline ml-1 text-gray-400" />}
                            </p>
                          ) : (
                            <p
                              className={`text-xs text-gray-500 dark:text-gray-400 ${isAdmin && onActualizarPrecio ? 'cursor-pointer hover:underline' : ''}`}
                              onClick={() => {
                                if (isAdmin && onActualizarPrecio) {
                                  setEditingPriceId(item.productoId);
                                  setEditingPriceValue(String(item.precioUnitario));
                                }
                              }}
                            >
                              {formatPrecio(item.precioUnitario)} c/u {isAdmin && onActualizarPrecio && <Pencil className="w-3 h-3 inline ml-0.5 text-gray-400" />}
                            </p>
                          )}
                          {itemMoq && itemMoq > 1 && (
                            <p className="text-xs text-amber-600 mt-0.5">Min: {itemMoq} uds</p>
                          )}
                        </div>
                        <div className="flex items-center gap-2 shrink-0">
                          <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, 0); }} className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded" title="Eliminar producto"><Trash2 className="w-4 h-4" /></button>
                          <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, Math.max(item.cantidad - 1, minCantidad)); }} className={`w-7 h-7 rounded-full text-sm ${item.cantidad <= minCantidad ? 'bg-gray-100 text-gray-400 dark:bg-gray-700' : 'bg-gray-200 hover:bg-gray-300 dark:bg-gray-600 dark:hover:bg-gray-500'}`} disabled={item.cantidad <= minCantidad}>-</button>
                          <span className="w-6 text-center font-medium text-sm dark:text-white">{item.cantidad}</span>
                          <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, item.cantidad + 1); }} className="w-7 h-7 rounded-full text-sm bg-gray-200 hover:bg-gray-300 dark:bg-gray-600 dark:hover:bg-gray-500">+</button>
                          <p className="w-20 text-right font-semibold text-sm dark:text-white">{formatPrecio(subtotal)}</p>
                        </div>
                      </div>
                      {warning && <p className={`text-xs mt-1 ${warning.tipo === 'error' ? 'text-red-600' : 'text-yellow-600'}`}>{warning.mensaje}</p>}
                    </div>
                  );
                })}
                {/* Items de bonificación (gratis) */}
                {promoResolucion.bonificaciones.map(bonif => {
                  const prod = productos.find(p => p.id === bonif.productoId);
                  return (
                    <div key={`bonif-${bonif.productoId}`} className="px-3 py-2.5 bg-green-50 dark:bg-green-900/10">
                      <div className="flex justify-between items-center gap-2">
                        <div className="min-w-0 flex-1">
                          <div className="flex items-center gap-1.5">
                            <p className="font-medium text-sm text-green-700 dark:text-green-400 truncate">{prod?.nombre}</p>
                            <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-green-200 text-green-800 rounded-full font-medium shrink-0">
                              <Gift className="w-3 h-3" />
                              Bonificacion
                            </span>
                          </div>
                          <p className="text-xs text-green-600 dark:text-green-400">{bonif.promoNombre}</p>
                        </div>
                        <div className="flex items-center gap-2 shrink-0">
                          <span className="w-6 text-center font-medium text-sm text-green-700 dark:text-green-400">{bonif.cantidadBonificacion}</span>
                          <p className="w-20 text-right font-semibold text-sm text-green-600">GRATIS</p>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>

              {/* Nudges para alcanzar siguiente tier */}
              {faltantes.length > 0 && (
                <div className="mt-2 space-y-1">
                  {faltantes.map((f, i) => (
                    <p key={i} className="text-xs text-blue-600 bg-blue-50 dark:bg-blue-900/20 px-3 py-1.5 rounded-lg">
                      Agrega {f.faltante} mas de <strong>{f.grupoNombre}</strong> para precio {f.etiqueta || 'mayorista'} ({formatPrecio(f.precioTier)} c/u)
                    </p>
                  ))}
                </div>
              )}

              {/* Nudges para alcanzar bonificación */}
              {faltantesBonificacion.length > 0 && (
                <div className="mt-2 space-y-1">
                  {faltantesBonificacion.map((f, i) => {
                    const prod = productos.find(p => p.id === f.productoId);
                    return (
                      <p key={`bonif-nudge-${i}`} className="text-xs text-green-600 bg-green-50 dark:bg-green-900/20 px-3 py-1.5 rounded-lg">
                        Agrega {f.faltante} mas de <strong>{prod?.nombre || f.promoNombre}</strong> y te llevas {f.bonificacion} gratis!
                      </p>
                    );
                  })}
                </div>
              )}
            </div>
          )}

          {/* Seccion Forma de Pago y Observaciones - al fondo */}
          <div className="border-t dark:border-gray-600 pt-4 space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="block text-sm font-medium mb-1 dark:text-gray-200">Forma de Pago</label>
                <select
                  value={nuevoPedido.formaPago || 'efectivo'}
                  onChange={e => onFormaPagoChange && onFormaPagoChange(e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
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
                  className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                >
                  <option value="pendiente">Pendiente</option>
                  <option value="pagado">Pagado</option>
                  <option value="parcial">Parcial</option>
                </select>
              </div>
            </div>

            {/* Monto pagado si es pago parcial */}
            {nuevoPedido.estadoPago === 'parcial' && (
              <div className="p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-700 rounded-lg">
                <label className="block text-sm font-medium mb-1 text-yellow-800 dark:text-yellow-300">Monto del pago parcial *</label>
                <div className="flex items-center gap-2">
                  <span className="text-lg font-semibold text-yellow-700 dark:text-yellow-400">$</span>
                  <input
                    type="number"
                    min="0"
                    step="0.01"
                    max={calcularTotal()}
                    value={nuevoPedido.montoPagado || ''}
                    onChange={e => onMontoPagadoChange && onMontoPagadoChange(parseFloat(e.target.value) || 0)}
                    className="flex-1 px-3 py-2 border border-yellow-300 rounded-lg focus:ring-2 focus:ring-yellow-500 bg-white dark:bg-gray-800 dark:border-yellow-600 dark:text-white"
                    placeholder="Ingrese el monto pagado"
                  />
                </div>
                {(nuevoPedido.montoPagado ?? 0) > 0 && (
                  <p className="text-sm text-yellow-700 dark:text-yellow-300 mt-2">
                    Resta por pagar: {formatPrecio(calcularTotal() - (nuevoPedido.montoPagado ?? 0))}
                  </p>
                )}
              </div>
            )}

            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Observaciones</label>
              <textarea
                value={nuevoPedido.notas || ''}
                onChange={e => onNotasChange && onNotasChange(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                placeholder="Observaciones para la preparacion..."
                rows={2}
              />
            </div>
          </div>
        </div>

        <div className="border-t bg-gray-50 p-4">
          <div className="flex justify-between items-center mb-4">
            <span className="text-lg font-medium">Total</span>
            <div className="text-right">
              {hayDescuento ? (
                <>
                  <span className="text-sm text-gray-400 line-through mr-2">{formatPrecio(totalOriginal)}</span>
                  <span className="text-2xl font-bold text-green-600">{formatPrecio(totalFinal)}</span>
                  <p className="text-xs text-green-600 font-medium">Ahorro: {formatPrecio(ahorro)}</p>
                </>
              ) : (
                <span className="text-2xl font-bold text-blue-600">{formatPrecio(calcularTotal())}</span>
              )}
            </div>
          </div>
          <div className="flex justify-end space-x-3">
            <button onClick={onClose} className="px-4 py-2 text-gray-700 hover:bg-gray-200 rounded-lg">Cancelar</button>
            <button onClick={onGuardar} disabled={guardando || violacionesMOQ.length > 0} className="px-6 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:bg-gray-400 flex items-center">
              {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}Confirmar
            </button>
          </div>
        </div>
      </div>
    </div>
  );
});

export default ModalPedido;
