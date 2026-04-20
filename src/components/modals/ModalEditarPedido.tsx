import { useState, memo, useEffect, useMemo } from 'react';
import { Loader2, DollarSign, AlertCircle, Package, Plus, Minus, Trash2, Search, X, ShoppingCart, Pencil, Gift } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatPrecio } from '../../utils/formatters';
import { useZodValidation } from '../../hooks/useZodValidation';
import { modalEditarPedidoSchema } from '../../lib/schemas';
import { usePrecioMayorista } from '../../hooks/usePrecioMayorista';
import { useRendiciones } from '../../hooks/supabase/useRendiciones';
import { calcularNetoVenta } from '../../utils/calculations';
import type { PedidoDB, ProductoDB } from '../../types';

/** Item del pedido para edición */
export interface PedidoEditItem {
  productoId: string;
  nombre: string;
  cantidad: number;
  precioUnitario: number;
  cantidadOriginal: number;
  esNuevo?: boolean;
  precioOverride?: boolean;
  esBonificacion?: boolean;
  promocionId?: string;
}

/** Datos a guardar del pedido */
export interface PedidoSaveData {
  notas: string;
  formaPago: string;
  estadoPago: string;
  montoPagado: number;
  fecha?: string;
  fechaEntrega?: string;
  fechaEntregaProgramada?: string;
}

/** Props del componente ModalEditarPedido */
export interface ModalEditarPedidoProps {
  /** Pedido a editar */
  pedido: PedidoDB | null;
  /** Lista de productos disponibles */
  productos?: ProductoDB[];
  /** Si es admin (puede editar items) */
  isAdmin?: boolean;
  /** Callback al guardar datos */
  onSave: (data: PedidoSaveData) => void | Promise<void>;
  /** Callback al guardar items */
  onSaveItems?: (items: PedidoEditItem[]) => Promise<void>;
  /** Callback al cerrar */
  onClose: () => void;
  /** Indica si está guardando */
  guardando: boolean;
}

const ModalEditarPedido = memo(function ModalEditarPedido({
  pedido,
  productos = [],
  isAdmin = false,
  onSave,
  onSaveItems,
  onClose,
  guardando
}: ModalEditarPedidoProps) {
  const [notas, setNotas] = useState<string>(pedido?.notas || "");
  const [fecha, setFecha] = useState<string>(pedido?.fecha || "");
  const fechaEntregaOriginal = pedido?.fecha_entrega ? pedido.fecha_entrega.split('T')[0] : "";
  const [fechaEntrega, setFechaEntrega] = useState<string>(fechaEntregaOriginal);
  const fechaEntregaProgramadaOriginal = pedido?.fecha_entrega_programada || "";
  const [fechaEntregaProgramada, setFechaEntregaProgramada] = useState<string>(fechaEntregaProgramadaOriginal);
  const [formaPago, setFormaPago] = useState<string>(pedido?.forma_pago === 'combinado' ? 'combinado' : (pedido?.forma_pago || "efectivo"));
  const [estadoPago, setEstadoPago] = useState<string>(pedido?.estado_pago || "pendiente");
  const [montoPagado, setMontoPagado] = useState<number>(pedido?.monto_pagado || 0);
  const [errorValidacion, setErrorValidacion] = useState<string>('');

  // Pago combinado
  const [pagoCombinado, setPagoCombinado] = useState<boolean>(pedido?.forma_pago === 'combinado');
  const [pagosCombinados, setPagosCombinados] = useState<{ monto: string; formaPago: string }[]>(() => {
    if (pedido?.forma_pago === 'combinado' && pedido?.notas) {
      // Intentar parsear los pagos del notas (formato: "[Pago combinado: Efectivo $X + Transferencia $Y]")
      return [
        { monto: '', formaPago: 'efectivo' },
        { monto: '', formaPago: 'transferencia' },
      ];
    }
    return [
      { monto: '', formaPago: 'efectivo' },
      { monto: '', formaPago: 'transferencia' },
    ];
  });

  // Zod validation
  const { validate } = useZodValidation(modalEditarPedidoSchema);

  // Consulta de control de rendición (para warning al cambiar fecha_entrega)
  const { consultarControl } = useRendiciones();

  // Estado para edición de items (solo admin)
  const [items, setItems] = useState<PedidoEditItem[]>([]);
  const [itemsOriginales, setItemsOriginales] = useState<PedidoEditItem[]>([]);
  const [mostrarBuscador, setMostrarBuscador] = useState<boolean>(false);
  const [busquedaProducto, setBusquedaProducto] = useState<string>('');
  const [itemsModificados, setItemsModificados] = useState<boolean>(false);
  const [errorStock, setErrorStock] = useState<string | null>(null);
  const [editingPriceId, setEditingPriceId] = useState<string | null>(null);
  const [editingPriceValue, setEditingPriceValue] = useState<string>('');

  // Verificar si el pedido está entregado (no editable)
  const pedidoEntregado = pedido?.estado === 'entregado';

  // Inicializar items del pedido
  useEffect(() => {
    if (pedido?.items) {
      const itemsFormateados = pedido.items.map(item => ({
        productoId: item.producto_id,
        nombre: item.producto?.nombre || 'Producto desconocido',
        cantidad: item.cantidad,
        precioUnitario: item.precio_unitario,
        cantidadOriginal: item.cantidad,
        esBonificacion: item.es_bonificacion || false,
        promocionId: item.promocion_id || undefined,
      }));
      setItems(itemsFormateados);
      setItemsOriginales(JSON.parse(JSON.stringify(itemsFormateados)));
    }
  }, [pedido]);

  // Recalcular precios mayorista/minorista según cantidades actuales
  // Usamos el precio base (retail) de cada producto para que la resolución sea correcta
  const itemsConPrecioBase = useMemo(() => {
    return items.map(item => {
      // Si tiene override, usar el precio manual; si no, usar precio base del producto
      if (item.precioOverride) {
        return {
          productoId: item.productoId,
          cantidad: item.cantidad,
          precioUnitario: item.precioUnitario,
          precioOverride: true
        };
      }
      const producto = productos.find(p => p.id === item.productoId);
      return {
        productoId: item.productoId,
        cantidad: item.cantidad,
        precioUnitario: producto?.precio || item.precioUnitario
      };
    });
  }, [items, productos]);

  const { itemsConPrecioMayorista, totalMayorista: totalCalculado, moqMap } = usePrecioMayorista(itemsConPrecioBase);

  // Mapa de precios resueltos para mostrar en cada item
  const preciosResueltosMap = useMemo(() => {
    const map = new Map<string, number>();
    for (const item of itemsConPrecioMayorista) {
      // Si el item tiene override, usar su precio manual en vez del resuelto
      const originalItem = items.find(i => i.productoId === item.productoId);
      if (originalItem?.precioOverride) {
        map.set(item.productoId, originalItem.precioUnitario);
      } else {
        map.set(item.productoId, item.precioUnitario);
      }
    }
    return map;
  }, [itemsConPrecioMayorista, items]);

  const total = itemsModificados ? totalCalculado : (pedido?.total || 0);
  const saldoPendiente = total - montoPagado;

  // Detectar si hubo cambios en items
  useEffect(() => {
    if (itemsOriginales.length === 0) return;

    const cambios = items.length !== itemsOriginales.length ||
      items.some((item) => {
        const original = itemsOriginales.find(o => o.productoId === item.productoId);
        return !original || original.cantidad !== item.cantidad;
      }) ||
      itemsOriginales.some(o => !items.find(i => i.productoId === o.productoId));

    setItemsModificados(cambios);
  }, [items, itemsOriginales]);

  // Productos disponibles para agregar
  const productosDisponibles = useMemo(() => {
    if (!busquedaProducto.trim()) return [];
    const busquedaLower = busquedaProducto.toLowerCase();
    return productos
      .filter(p =>
        !items.find(i => i.productoId === p.id) &&
        (p.nombre?.toLowerCase().includes(busquedaLower) ||
          p.codigo?.toLowerCase().includes(busquedaLower))
      )
      .slice(0, 10);
  }, [productos, items, busquedaProducto]);

  // Cuando cambia el estado de pago, ajustar el monto
  // NOTE: Only react to estadoPago changes, NOT total changes.
  // If total is in deps, editing items while estadoPago='pagado' silently overwrites montoPagado.
  useEffect(() => {
    if (estadoPago === 'pagado') {
      setMontoPagado(total);
    } else if (estadoPago === 'pendiente') {
      setMontoPagado(0);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [estadoPago]);

  const handleMontoPagadoChange = (valor: string): void => {
    const monto = Math.min(parseFloat(valor) || 0, total);
    setMontoPagado(monto);
    if (monto >= total) {
      setEstadoPago('pagado');
    } else if (monto > 0) {
      setEstadoPago('parcial');
    } else {
      setEstadoPago('pendiente');
    }
  };

  const aplicarPorcentaje = (porcentaje: number): void => {
    const monto = (total * porcentaje) / 100;
    handleMontoPagadoChange(String(monto));
  };

  // Funciones para editar items
  const handleCantidadChange = (productoId: string, delta: number): void => {
    setErrorStock(null);
    setItems(prev => prev.map(item => {
      if (item.productoId === productoId) {
        const moq = moqMap.get(String(productoId));
        const minCantidad = moq && moq > 1 ? moq : 1;
        const nuevaCantidad = Math.max(minCantidad, item.cantidad + delta);
        // Verificar stock disponible
        const producto = productos.find(p => p.id === productoId);
        const cantidadOriginal = itemsOriginales.find(o => o.productoId === productoId)?.cantidad || 0;
        const stockDisponible = (producto?.stock || 0) + cantidadOriginal;

        if (nuevaCantidad > stockDisponible) {
          setErrorStock(`Stock insuficiente para "${item.nombre}". Disponible: ${stockDisponible}`);
          return item;
        }
        return { ...item, cantidad: nuevaCantidad };
      }
      return item;
    }));
  };

  const handleEliminarItem = (productoId: string): void => {
    setItems(prev => prev.filter(item => item.productoId !== productoId));
  };

  const handlePrecioChange = (productoId: string, nuevoPrecio: number): void => {
    if (nuevoPrecio <= 0) return;
    setItems(prev => prev.map(item =>
      item.productoId === productoId
        ? { ...item, precioUnitario: nuevoPrecio, precioOverride: true }
        : item
    ));
  };

  const handleAgregarProducto = (producto: ProductoDB): void => {
    const moq = moqMap.get(String(producto.id));
    const cantidadInicial = moq && moq > 1 ? moq : 1;
    setItems(prev => [...prev, {
      productoId: producto.id,
      nombre: producto.nombre,
      cantidad: cantidadInicial,
      precioUnitario: producto.precio,
      cantidadOriginal: 0,
      esNuevo: true
    }]);
    setBusquedaProducto('');
    setMostrarBuscador(false);
  };

  const handleGuardar = async (): Promise<void> => {
    setErrorValidacion('');
    setErrorStock(null);

    // Preparar datos de pago
    let formaPagoFinal = formaPago;
    let montoPagadoFinal = montoPagado || 0;
    let notasFinal = notas;

    if (pagoCombinado) {
      const pagosValidos = pagosCombinados.filter(p => parseFloat(p.monto) > 0);
      if (pagosValidos.length < 2) {
        setErrorValidacion('Ingresa al menos 2 formas de pago con monto mayor a 0');
        return;
      }
      formaPagoFinal = 'combinado';
      montoPagadoFinal = Math.min(pagosValidos.reduce((sum, p) => sum + parseFloat(p.monto), 0), total);
      if (pagosValidos.reduce((sum, p) => sum + parseFloat(p.monto), 0) > total) {
        setErrorValidacion(`El total combinado no puede superar el total del pedido (${formatPrecio(total)})`);
        return;
      }
      // Agregar detalle de pagos combinados a las notas
      const formasPagoLabels: Record<string, string> = {
        efectivo: 'Efectivo', transferencia: 'Transferencia', cheque: 'Cheque',
        tarjeta: 'Tarjeta', cuenta_corriente: 'Cuenta Corriente'
      };
      const detalle = pagosValidos.map(p =>
        `${formasPagoLabels[p.formaPago] || p.formaPago} $${parseFloat(p.monto).toLocaleString('es-AR')}`
      ).join(' + ');
      // Reemplazar detalle previo si existe, o agregar
      const notaSinDetalle = notas.replace(/\s*\[Pago combinado:.*?\]/g, '').trim();
      notasFinal = notaSinDetalle ? `${notaSinDetalle} [Pago combinado: ${detalle}]` : `[Pago combinado: ${detalle}]`;
    }

    // Validar con Zod
    const result = validate({ notas: notasFinal, formaPago: formaPagoFinal, estadoPago, montoPagado: montoPagadoFinal });
    if (!result.success) {
      const firstError = Object.values(result.errors || {})[0] || 'Error de validación';
      setErrorValidacion(firstError);
      return;
    }

    // Si cambió la fecha_entrega (solo admin + pedido entregado), consultar control de rendición
    const fechaEntregaCambio = isAdmin && pedidoEntregado && fechaEntrega && fechaEntrega !== fechaEntregaOriginal;
    if (fechaEntregaCambio && pedido?.transportista_id) {
      try {
        const [origen, destino] = await Promise.all([
          fechaEntregaOriginal ? consultarControl(pedido.transportista_id, fechaEntregaOriginal) : Promise.resolve({ controlada: false, controlada_at: null, controlada_por_nombre: null }),
          consultarControl(pedido.transportista_id, fechaEntrega)
        ]);
        const avisos: string[] = [];
        if (origen.controlada) {
          avisos.push(`La rendición del ${fechaEntregaOriginal} ya fue controlada por ${origen.controlada_por_nombre || 'un usuario'}.`);
        }
        if (destino.controlada) {
          avisos.push(`La rendición del ${fechaEntrega} ya fue controlada por ${destino.controlada_por_nombre || 'un usuario'}.`);
        }
        if (avisos.length > 0) {
          const mensaje = `${avisos.join('\n')}\n\nSi procedés, ese control se anulará y la rendición deberá volver a controlarse. ¿Continuar?`;
          if (!window.confirm(mensaje)) return;
        }
      } catch {
        // Si falla la consulta, continuamos (el trigger SQL anulará el control igual)
      }
    }

    try {
      // Si hay cambios en items y es admin, guardar items con precios mayoristas resueltos y desglose fiscal
      if (itemsModificados && isAdmin && onSaveItems) {
        const tipoFactura = pedido?.tipo_factura || 'ZZ';
        const itemsParaGuardar = items.map(item => {
          const precioFinal = preciosResueltosMap.get(item.productoId) ?? item.precioUnitario;
          const producto = productos.find(p => p.id === item.productoId);
          const pctIva = producto?.porcentaje_iva ?? 21;
          const pctImpInt = producto?.impuestos_internos ?? 0;
          const esBonif = item.esBonificacion || false;

          if (esBonif) {
            return { ...item, precioUnitario: 0, neto_unitario: 0, iva_unitario: 0, impuestos_internos_unitario: 0, porcentaje_iva: 0 };
          }

          const desglose = calcularNetoVenta(precioFinal, pctIva, pctImpInt, tipoFactura as 'ZZ' | 'FC');
          return {
            ...item,
            precioUnitario: precioFinal,
            neto_unitario: desglose.neto,
            iva_unitario: desglose.iva,
            impuestos_internos_unitario: desglose.impuestosInternos,
            porcentaje_iva: pctIva,
          };
        });
        await onSaveItems(itemsParaGuardar);
      }
      // Guardar el resto de los datos
      const fechaEntregaProgramadaCambio = isAdmin && !pedidoEntregado && fechaEntregaProgramada !== fechaEntregaProgramadaOriginal;
      await onSave({
        notas: notasFinal,
        formaPago: formaPagoFinal,
        estadoPago,
        montoPagado: montoPagadoFinal,
        ...(isAdmin && fecha ? { fecha } : {}),
        ...(fechaEntregaCambio ? { fechaEntrega } : {}),
        ...(fechaEntregaProgramadaCambio ? { fechaEntregaProgramada } : {})
      });
    } catch (err) {
      const error = err as Error;
      setErrorValidacion(error.message || 'Error al guardar los cambios');
    }
  };

  const getStockDisponible = (productoId: string): number => {
    const producto = productos.find(p => p.id === productoId);
    const cantidadOriginal = itemsOriginales.find(o => o.productoId === productoId)?.cantidad || 0;
    return (producto?.stock || 0) + cantidadOriginal;
  };

  return (
    <ModalBase
      title={`Editar Pedido #${pedido?.id}`}
      description="Editar notas, forma de pago, estado de pago y productos del pedido"
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Info del cliente */}
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-3 border dark:border-gray-600">
          <p className="text-sm text-gray-600 dark:text-gray-400">Cliente</p>
          <p className="font-medium dark:text-white">{pedido?.cliente?.nombre_fantasia}</p>
          <p className="text-sm text-gray-500 dark:text-gray-400">{pedido?.cliente?.direccion}</p>
        </div>

        {/* Alerta de pedido entregado */}
        {pedidoEntregado && (
          <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
            <div className="flex items-center gap-2">
              <AlertCircle className="w-5 h-5 text-yellow-600" />
              <p className="text-sm text-yellow-700 dark:text-yellow-400">
                Este pedido ya fue entregado. Los productos no se pueden modificar.
              </p>
            </div>
          </div>
        )}

        {/* Sección de productos - Vista de solo lectura para no-admin o pedido entregado */}
        {(!isAdmin || pedidoEntregado) && pedido && (pedido.items?.length ?? 0) > 0 && (
          <div className="border dark:border-gray-600 rounded-lg overflow-hidden">
            <div className="bg-gray-50 dark:bg-gray-700 px-4 py-3 flex items-center gap-2">
              <ShoppingCart className="w-5 h-5 text-blue-600" />
              <span className="font-medium dark:text-white">Productos del Pedido</span>
              <span className="text-xs text-gray-500">(solo lectura)</span>
            </div>
            <div className="divide-y dark:divide-gray-600">
              {pedido.items?.map(item => (
                <div key={item.producto_id} className="p-3 flex items-center justify-between">
                  <div className="flex-1">
                    <p className="font-medium text-sm dark:text-white">{item.producto?.nombre || 'Producto'}</p>
                    <p className="text-xs text-gray-500">{formatPrecio(item.precio_unitario)} c/u</p>
                  </div>
                  <div className="flex items-center gap-4">
                    <span className="text-sm dark:text-white">x{item.cantidad}</span>
                    <span className="font-semibold text-blue-600">{formatPrecio(item.cantidad * item.precio_unitario)}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Sección de productos editable (solo admin y pedido no entregado) */}
        {isAdmin && !pedidoEntregado && (
          <div className="border dark:border-gray-600 rounded-lg overflow-hidden">
            <div className="bg-gray-50 dark:bg-gray-700 px-4 py-3 flex items-center justify-between">
              <div className="flex items-center gap-2">
                <ShoppingCart className="w-5 h-5 text-blue-600" />
                <span className="font-medium dark:text-white">Productos del Pedido</span>
                {itemsModificados && (
                  <span className="text-xs bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400 px-2 py-0.5 rounded">
                    Modificado
                  </span>
                )}
              </div>
              <button
                onClick={() => setMostrarBuscador(!mostrarBuscador)}
                className="text-sm text-blue-600 hover:text-blue-700 flex items-center gap-1"
              >
                <Plus className="w-4 h-4" />
                Agregar
              </button>
            </div>

            {/* Buscador de productos */}
            {mostrarBuscador && (
              <div className="p-3 border-b dark:border-gray-600 bg-blue-50 dark:bg-blue-900/20">
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
                  <input
                    type="text"
                    value={busquedaProducto}
                    onChange={e => setBusquedaProducto(e.target.value)}
                    placeholder="Buscar producto por nombre o código..."
                    className="w-full pl-9 pr-8 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    autoFocus
                  />
                  {busquedaProducto && (
                    <button
                      onClick={() => { setBusquedaProducto(''); setMostrarBuscador(false); }}
                      className="absolute right-3 top-1/2 -translate-y-1/2"
                    >
                      <X className="w-4 h-4 text-gray-400" />
                    </button>
                  )}
                </div>
                {productosDisponibles.length > 0 && (
                  <div className="mt-2 max-h-40 overflow-y-auto bg-white dark:bg-gray-800 rounded border dark:border-gray-600">
                    {productosDisponibles.map(producto => (
                      <button
                        key={producto.id}
                        onClick={() => handleAgregarProducto(producto)}
                        className="w-full px-3 py-2 text-left hover:bg-gray-50 dark:hover:bg-gray-700 flex justify-between items-center border-b last:border-b-0 dark:border-gray-600"
                      >
                        <div>
                          <p className="text-sm font-medium dark:text-white">{producto.nombre}</p>
                          <p className="text-xs text-gray-500">{producto.codigo} - Stock: {producto.stock}</p>
                        </div>
                        <span className="text-sm font-semibold text-blue-600">{formatPrecio(producto.precio)}</span>
                      </button>
                    ))}
                  </div>
                )}
              </div>
            )}

            {/* Lista de items */}
            <div className="divide-y dark:divide-gray-600">
              {items.length === 0 ? (
                <div className="p-4 text-center text-gray-500">
                  <Package className="w-8 h-8 mx-auto mb-2 opacity-50" />
                  <p className="text-sm">No hay productos en el pedido</p>
                </div>
              ) : (
                items.map(item => {
                  const stockDisponible = getStockDisponible(item.productoId);
                  const cambio = item.cantidad - (item.cantidadOriginal || 0);
                  const precioResuelto = preciosResueltosMap.get(item.productoId) ?? item.precioUnitario;

                  // Bonificacion items: show as read-only
                  if (item.esBonificacion) {
                    return (
                      <div key={item.productoId} className="p-3 flex items-center justify-between bg-green-50 dark:bg-green-900/20">
                        <div className="flex items-center gap-2 flex-1">
                          <Gift className="w-4 h-4 text-green-600 flex-shrink-0" />
                          <div>
                            <p className="font-medium text-sm dark:text-white">{item.nombre}</p>
                            <p className="text-xs text-green-600 font-medium">REGALO x{item.cantidad}</p>
                          </div>
                        </div>
                        <span className="text-sm font-bold text-green-600">$0</span>
                      </div>
                    )
                  }

                  return (
                    <div
                      key={item.productoId}
                      className={`p-3 flex items-center justify-between ${
                        item.esNuevo ? 'bg-green-50 dark:bg-green-900/10' :
                          cambio !== 0 ? 'bg-yellow-50 dark:bg-yellow-900/10' : ''
                      }`}
                    >
                      <div className="flex-1">
                        <div className="flex items-center gap-1.5">
                          <p className="font-medium text-sm dark:text-white">{item.nombre}</p>
                          {item.precioOverride && (
                            <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-orange-100 text-orange-700 rounded-full font-medium shrink-0">
                              <Pencil className="w-3 h-3" />
                              Manual
                            </span>
                          )}
                        </div>
                        <div className="flex items-center gap-2 text-xs text-gray-500">
                          {editingPriceId === item.productoId ? (
                            <div className="flex items-center gap-1">
                              <span className="text-orange-600">$</span>
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
                                    if (newPrice > 0) handlePrecioChange(item.productoId, newPrice);
                                    setEditingPriceId(null);
                                  } else if (e.key === 'Escape') {
                                    setEditingPriceId(null);
                                  }
                                }}
                                onBlur={() => {
                                  const newPrice = parseFloat(editingPriceValue);
                                  if (newPrice > 0) handlePrecioChange(item.productoId, newPrice);
                                  setEditingPriceId(null);
                                }}
                                className="w-24 px-2 py-0.5 text-xs border border-orange-300 rounded bg-orange-50 dark:bg-orange-900/20 dark:border-orange-600 dark:text-white focus:ring-1 focus:ring-orange-500 focus:outline-none"
                                autoFocus
                              />
                              <span className="text-orange-600">c/u</span>
                            </div>
                          ) : (
                            <span
                              className={`${item.precioOverride ? 'text-orange-600 font-medium' : ''} ${isAdmin ? 'cursor-pointer hover:underline' : ''}`}
                              onClick={() => {
                                if (isAdmin) {
                                  setEditingPriceId(item.productoId);
                                  setEditingPriceValue(String(precioResuelto));
                                }
                              }}
                            >
                              {formatPrecio(precioResuelto)} c/u
                              {isAdmin && <Pencil className="w-3 h-3 inline ml-0.5 text-gray-400" />}
                            </span>
                          )}
                          <span>-</span>
                          <span>Stock disp: {stockDisponible}</span>
                          {item.esNuevo && (
                            <span className="text-green-600 font-medium">Nuevo</span>
                          )}
                          {!item.esNuevo && cambio !== 0 && (
                            <span className={cambio > 0 ? 'text-yellow-600' : 'text-orange-600'}>
                              ({cambio > 0 ? '+' : ''}{cambio})
                            </span>
                          )}
                        </div>
                      </div>

                      <div className="flex items-center gap-2">
                        {/* Controles de cantidad */}
                        <div className="flex items-center border dark:border-gray-600 rounded-lg">
                          <button
                            onClick={() => handleCantidadChange(item.productoId, -1)}
                            disabled={item.cantidad <= (moqMap.get(String(item.productoId)) || 1)}
                            className="p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 rounded-l-lg"
                          >
                            <Minus className="w-4 h-4" />
                          </button>
                          <span className="px-3 py-1 min-w-[40px] text-center font-medium dark:text-white">
                            {item.cantidad}
                          </span>
                          <button
                            onClick={() => handleCantidadChange(item.productoId, 1)}
                            disabled={item.cantidad >= stockDisponible}
                            className="p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 disabled:opacity-50 rounded-r-lg"
                          >
                            <Plus className="w-4 h-4" />
                          </button>
                        </div>

                        {/* Subtotal */}
                        <span className="font-semibold text-blue-600 min-w-[80px] text-right">
                          {formatPrecio(item.cantidad * precioResuelto)}
                        </span>

                        {/* Eliminar */}
                        <button
                          onClick={() => handleEliminarItem(item.productoId)}
                          className="p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    </div>
                  );
                })
              )}
            </div>
          </div>
        )}

        {/* Total del pedido */}
        <div className="bg-blue-50 dark:bg-blue-900/30 rounded-lg p-4 border border-blue-200 dark:border-blue-800">
          <div className="flex justify-between items-center">
            <span className="text-blue-700 dark:text-blue-300 font-medium">Total del Pedido</span>
            <div className="text-right">
              <span className="text-2xl font-bold text-blue-600 dark:text-blue-400">{formatPrecio(total)}</span>
              {itemsModificados && (
                <p className="text-xs text-blue-500">
                  Anterior: {formatPrecio(pedido?.total || 0)}
                </p>
              )}
            </div>
          </div>
        </div>

        {/* Fecha del pedido (solo admin) */}
        {isAdmin && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Fecha del Pedido</label>
            <input
              type="date"
              value={fecha}
              onChange={e => setFecha(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
          </div>
        )}

        {/* Fecha programada de entrega (solo admin + pedido NO entregado) */}
        {isAdmin && !pedidoEntregado && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              Fecha programada de entrega
            </label>
            <input
              type="date"
              value={fechaEntregaProgramada}
              onChange={e => setFechaEntregaProgramada(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
            {fechaEntregaProgramada !== fechaEntregaProgramadaOriginal && (
              <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                Se actualizará la fecha estimada de entrega del pedido.
              </p>
            )}
          </div>
        )}

        {/* Fecha de entrega (solo admin + pedido entregado) - determina el día de rendición */}
        {isAdmin && pedidoEntregado && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              Fecha de Entrega
              <span className="ml-2 text-xs text-gray-500 dark:text-gray-400">(determina el día de rendición)</span>
            </label>
            <input
              type="date"
              value={fechaEntrega}
              onChange={e => setFechaEntrega(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
            {fechaEntrega !== fechaEntregaOriginal && (
              <p className="mt-1 text-xs text-amber-600 dark:text-amber-400">
                Cambiar esta fecha moverá el pedido a la rendición del día elegido. Si alguno de los días estaba controlado, su control se anulará.
              </p>
            )}
          </div>
        )}

        {/* Notas */}
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Notas / Observaciones</label>
          <textarea
            value={notas}
            onChange={e => setNotas(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            placeholder="Observaciones importantes para la preparación del pedido..."
            rows={2}
          />
        </div>

        {/* Forma de Pago */}
        <div>
          <div className="flex items-center justify-between mb-1">
            <label className="block text-sm font-medium dark:text-gray-200">Forma de Pago</label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={pagoCombinado}
                onChange={e => {
                  setPagoCombinado(e.target.checked);
                  if (!e.target.checked) {
                    setFormaPago('efectivo');
                    setMontoPagado(pedido?.monto_pagado || 0);
                    setEstadoPago(pedido?.estado_pago || 'pendiente');
                  }
                }}
                className="w-4 h-4 rounded border-gray-300 text-blue-600"
              />
              <span className="text-xs text-gray-500 dark:text-gray-400">Pago combinado</span>
            </label>
          </div>

          {pagoCombinado ? (
            <div className="space-y-2">
              {pagosCombinados.map((pago, index) => (
                <div key={index} className="flex items-center gap-2">
                  <select
                    value={pago.formaPago}
                    onChange={e => setPagosCombinados(prev => prev.map((p, i) => i === index ? { ...p, formaPago: e.target.value } : p))}
                    className="flex-1 px-2 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  >
                    <option value="efectivo">Efectivo</option>
                    <option value="transferencia">Transferencia</option>
                    <option value="cheque">Cheque</option>
                    <option value="cuenta_corriente">Cuenta Corriente</option>
                    <option value="tarjeta">Tarjeta</option>
                  </select>
                  <div className="relative flex-1">
                    <span className="absolute left-2 top-1/2 -translate-y-1/2 text-gray-400 text-sm">$</span>
                    <input
                      type="number"
                      step="0.01"
                      min="0"
                      value={pago.monto}
                      onChange={e => {
                        const nuevos = pagosCombinados.map((p, i) => i === index ? { ...p, monto: e.target.value } : p);
                        setPagosCombinados(nuevos);
                        const totalComb = nuevos.reduce((sum, p) => sum + (parseFloat(p.monto) || 0), 0);
                        setMontoPagado(totalComb);
                        if (totalComb >= total) setEstadoPago('pagado');
                        else if (totalComb > 0) setEstadoPago('parcial');
                        else setEstadoPago('pendiente');
                      }}
                      placeholder="0.00"
                      className="w-full pl-6 pr-2 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white font-semibold"
                    />
                  </div>
                  {pagosCombinados.length > 2 && (
                    <button
                      type="button"
                      onClick={() => setPagosCombinados(prev => prev.filter((_, i) => i !== index))}
                      className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  )}
                </div>
              ))}
              <button
                type="button"
                onClick={() => setPagosCombinados(prev => [...prev, { monto: '', formaPago: 'efectivo' }])}
                className="w-full flex items-center justify-center gap-1 px-3 py-1.5 text-xs text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded-lg border border-dashed border-blue-300 dark:border-blue-700"
              >
                <Plus className="w-3 h-3" />
                Agregar forma de pago
              </button>
              {(() => {
                const totalComb = pagosCombinados.reduce((s, p) => s + (parseFloat(p.monto) || 0), 0);
                const excede = totalComb > total;
                return (
                  <div className={`text-right text-sm ${excede ? 'text-red-600 dark:text-red-400' : 'text-gray-500 dark:text-gray-400'}`}>
                    Total combinado: <span className={`font-bold ${excede ? 'text-red-600 dark:text-red-400' : 'text-gray-800 dark:text-white'}`}>{formatPrecio(totalComb)}</span>
                    {excede && <span className="block text-xs">Excede el total del pedido ({formatPrecio(total)})</span>}
                  </div>
                );
              })()}
            </div>
          ) : (
            <select
              value={formaPago}
              onChange={e => setFormaPago(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            >
              <option value="efectivo">Efectivo</option>
              <option value="transferencia">Transferencia</option>
              <option value="cheque">Cheque</option>
              <option value="cuenta_corriente">Cuenta Corriente</option>
              <option value="tarjeta">Tarjeta</option>
            </select>
          )}
        </div>

        {/* Sección de pago */}
        <div className="border dark:border-gray-600 rounded-lg p-4 space-y-4">
          <div className="flex items-center gap-2">
            <DollarSign className="w-5 h-5 text-green-600" />
            <span className="font-medium dark:text-gray-200">Estado de Pago</span>
          </div>

          {/* Estado de pago */}
          <div className="grid grid-cols-3 gap-2">
            <button
              type="button"
              onClick={() => setEstadoPago('pendiente')}
              className={`py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                estadoPago === 'pendiente'
                  ? 'bg-red-100 text-red-700 border-2 border-red-500 dark:bg-red-900/30 dark:text-red-400 dark:border-red-600'
                  : 'bg-gray-100 text-gray-600 border border-gray-300 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-400 dark:border-gray-600'
              }`}
            >
              Pendiente
            </button>
            <button
              type="button"
              onClick={() => setEstadoPago('parcial')}
              className={`py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                estadoPago === 'parcial'
                  ? 'bg-yellow-100 text-yellow-700 border-2 border-yellow-500 dark:bg-yellow-900/30 dark:text-yellow-400 dark:border-yellow-600'
                  : 'bg-gray-100 text-gray-600 border border-gray-300 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-400 dark:border-gray-600'
              }`}
            >
              Parcial
            </button>
            <button
              type="button"
              onClick={() => setEstadoPago('pagado')}
              className={`py-2 px-3 rounded-lg text-sm font-medium transition-colors ${
                estadoPago === 'pagado'
                  ? 'bg-green-100 text-green-700 border-2 border-green-500 dark:bg-green-900/30 dark:text-green-400 dark:border-green-600'
                  : 'bg-gray-100 text-gray-600 border border-gray-300 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-400 dark:border-gray-600'
              }`}
            >
              Pagado
            </button>
          </div>

          {/* Monto pagado */}
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              Monto Pagado
            </label>
            <div className="relative">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-500">$</span>
              <input
                type="number"
                min="0"
                max={total}
                step="0.01"
                value={montoPagado}
                onChange={e => handleMontoPagadoChange(e.target.value)}
                className="w-full pl-8 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder="0.00"
              />
            </div>

            {/* Botones de porcentaje rápido */}
            <div className="flex gap-2 mt-2">
              {[25, 50, 75, 100].map(pct => (
                <button
                  key={pct}
                  type="button"
                  onClick={() => aplicarPorcentaje(pct)}
                  className="flex-1 py-1 text-xs bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 dark:hover:bg-gray-600 rounded transition-colors dark:text-gray-300"
                >
                  {pct}%
                </button>
              ))}
            </div>
          </div>

          {/* Resumen de pagos */}
          {estadoPago === 'parcial' && saldoPendiente > 0 && (
            <div className="bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg p-3">
              <div className="flex items-start gap-2">
                <AlertCircle className="w-5 h-5 text-yellow-600 flex-shrink-0 mt-0.5" />
                <div className="text-sm">
                  <p className="font-medium text-yellow-800 dark:text-yellow-300">Pago Parcial</p>
                  <div className="mt-1 space-y-1 text-yellow-700 dark:text-yellow-400">
                    <p>Pagado: <span className="font-semibold">{formatPrecio(montoPagado)}</span></p>
                    <p>Pendiente: <span className="font-semibold text-red-600 dark:text-red-400">{formatPrecio(saldoPendiente)}</span></p>
                  </div>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Error de stock */}
      {errorStock && (
        <div className="mx-4 mb-2 p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
          <p className="text-sm text-yellow-600 dark:text-yellow-400">{errorStock}</p>
        </div>
      )}

      {/* Error de validación */}
      {errorValidacion && (
        <div className="mx-4 mb-2 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
          <p className="text-sm text-red-600 dark:text-red-400">{errorValidacion}</p>
        </div>
      )}

      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cancelar
        </button>
        <button
          onClick={handleGuardar}
          disabled={guardando || (isAdmin && !pedidoEntregado && items.length === 0)}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
        >
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          {itemsModificados ? 'Guardar Todo' : 'Guardar'}
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalEditarPedido;
