import { useMemo, useState, memo } from 'react';
import { Search, X, Loader2, ArrowRight, AlertCircle, Gift, RefreshCw } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatPrecio } from '../../utils/formatters';
import { calcularNetoVenta } from '../../utils/calculations';
import { usePromocionPedido } from '../../hooks/usePromocionPedido';
import { aplicarDescuentoClienteItems } from '../../utils/descuentoCliente';
import type { ItemPedido } from '../../utils/precioMayorista';
import type { PedidoDB, ProductoDB, ClienteDB } from '../../types';

/** Item recalculado que se envía a la RPC cambiar_cliente_pedido. */
export interface CambiarClienteItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
  esBonificacion?: boolean;
  promocionId?: string;
  neto_unitario?: number;
  iva_unitario?: number;
  impuestos_internos_unitario?: number;
  porcentaje_iva?: number;
}

/** Payload con todo lo que necesita el container para invocar la mutación. */
export interface CambiarClientePayload {
  nuevoClienteId: string;
  items: CambiarClienteItem[];
  total: number;
  totalNeto: number;
  totalIva: number;
  motivo?: string;
}

export interface ModalCambiarClienteProps {
  pedido: PedidoDB;
  productos: ProductoDB[];
  clientes: ClienteDB[];
  onConfirmar: (payload: CambiarClientePayload) => void | Promise<void>;
  onClose: () => void;
  guardando: boolean;
}

/**
 * Cambia el cliente de un pedido cargado al cliente equivocado. Recalcula
 * precios/promos/descuentos para el cliente nuevo (no copia los del viejo),
 * muestra una comparación total anterior vs nuevo, y al confirmar delega en el
 * container que cancela el pedido viejo y crea uno nuevo idéntico (RPC atómica).
 */
const ModalCambiarCliente = memo(function ModalCambiarCliente({
  pedido,
  productos,
  clientes,
  onConfirmar,
  onClose,
  guardando,
}: ModalCambiarClienteProps) {
  const [busquedaCliente, setBusquedaCliente] = useState<string>('');
  const [nuevoClienteId, setNuevoClienteId] = useState<string>('');

  const tipoFactura = pedido.tipo_factura ?? 'ZZ';

  // Cliente actual (para mostrarlo de referencia).
  const clienteActual = useMemo(
    () => clientes.find(c => String(c.id) === String(pedido.cliente_id)) ?? pedido.cliente ?? null,
    [clientes, pedido.cliente_id, pedido.cliente],
  );

  const clienteNuevo = useMemo(
    () => (nuevoClienteId ? clientes.find(c => String(c.id) === String(nuevoClienteId)) ?? null : null),
    [clientes, nuevoClienteId],
  );

  // Buscador de cliente (réplica del de ModalPedido), excluyendo el cliente actual.
  const clientesFiltrados = useMemo(() => {
    if (busquedaCliente.length < 2) return [];
    const busquedaNorm = busquedaCliente.replace(/\s+/g, ' ').trim().toLowerCase();
    if (!busquedaNorm) return [];
    const norm = (s: string | null | undefined) => s?.replace(/\s+/g, ' ').trim().toLowerCase() ?? '';
    return clientes
      .filter(c => String(c.id) !== String(pedido.cliente_id))
      .filter(c =>
        norm(c.nombre_fantasia).includes(busquedaNorm) ||
        norm(c.razon_social).includes(busquedaNorm) ||
        norm(c.direccion).includes(busquedaNorm) ||
        c.cuit?.includes(busquedaCliente.replace(/[-\s]/g, '')) ||
        (c.codigo != null && String(c.codigo).includes(busquedaCliente.trim())),
      )
      .slice(0, 8);
  }, [clientes, busquedaCliente, pedido.cliente_id]);

  // Items de venta del pedido viejo -> base para recalcular. Se descartan las
  // bonificaciones (se regeneran para el cliente nuevo) y se parte del precio
  // de LISTA del producto, no del precio_unitario viejo (que ya traía
  // mayorista/descuento del cliente equivocado embebido).
  const itemsVenta = useMemo<ItemPedido[]>(() => {
    return (pedido.items ?? [])
      .filter(i => !i.es_bonificacion)
      .map(i => {
        const prod = productos.find(p => String(p.id) === String(i.producto_id));
        return {
          productoId: String(i.producto_id),
          cantidad: i.cantidad,
          precioUnitario: prod?.precio ?? i.precio_unitario,
        };
      });
  }, [pedido.items, productos]);

  // Mayorista + promos para el cliente nuevo (vigencia a la fecha del pedido).
  const { itemsFinales, isLoading } = usePromocionPedido(itemsVenta, pedido.fecha);

  // Descuento del cliente nuevo (general + categoría) sobre los items resueltos.
  const descuento = useMemo(
    () => aplicarDescuentoClienteItems(itemsFinales, productos, clienteNuevo),
    [itemsFinales, productos, clienteNuevo],
  );

  const totalNuevo = descuento.total;
  const totalViejo = pedido.total ?? 0;
  const delta = totalNuevo - totalViejo;

  const tienePago = (pedido.monto_pagado ?? 0) > 0;

  const handleConfirmar = (): void => {
    if (!clienteNuevo || isLoading || guardando) return;

    let total = 0;
    let totalNeto = 0;
    let totalIva = 0;

    const items: CambiarClienteItem[] = descuento.items.map(item => {
      const productoId = String(item.productoId);
      if (item.esBonificacion) {
        return {
          productoId,
          cantidad: item.cantidad,
          precioUnitario: 0,
          esBonificacion: true,
          promocionId: item.promoId,
          neto_unitario: 0,
          iva_unitario: 0,
          impuestos_internos_unitario: 0,
          porcentaje_iva: 0,
        };
      }
      const prod = productos.find(p => String(p.id) === productoId);
      const pctIva = prod?.porcentaje_iva ?? 21;
      const pctImpInt = prod?.impuestos_internos ?? 0;
      const desglose = calcularNetoVenta(item.precioUnitario, pctIva, pctImpInt, tipoFactura);
      total += item.precioUnitario * item.cantidad;
      totalNeto += desglose.neto * item.cantidad;
      totalIva += desglose.iva * item.cantidad;
      return {
        productoId,
        cantidad: item.cantidad,
        precioUnitario: item.precioUnitario,
        neto_unitario: desglose.neto,
        iva_unitario: desglose.iva,
        impuestos_internos_unitario: desglose.impuestosInternos,
        porcentaje_iva: pctIva,
      };
    });

    void onConfirmar({
      nuevoClienteId: String(clienteNuevo.id),
      items,
      total,
      totalNeto,
      totalIva,
      motivo: 'Cambio de cliente',
    });
  };

  const nombreProducto = (productoId: string): string =>
    productos.find(p => String(p.id) === String(productoId))?.nombre ?? `Producto #${productoId}`;

  return (
    <ModalBase title="Cambiar cliente" onClose={onClose} maxWidth="max-w-lg">
      <div className="max-h-[70vh] overflow-y-auto overscroll-contain p-4 space-y-4">
        {/* Cliente actual */}
        <div>
          <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Cliente actual</p>
          <div className="p-3 bg-gray-50 dark:bg-gray-800 border dark:border-gray-700 rounded-lg">
            <p className="font-medium dark:text-white">{clienteActual?.nombre_fantasia ?? '—'}</p>
            {clienteActual?.direccion && (
              <p className="text-sm text-gray-500 dark:text-gray-400">{clienteActual.direccion}</p>
            )}
          </div>
        </div>

        {/* Nuevo cliente: buscador o seleccionado */}
        <div>
          <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Nuevo cliente</p>
          {clienteNuevo ? (
            <div className="p-3 bg-blue-50 dark:bg-blue-900/30 border border-blue-200 dark:border-blue-800 rounded-lg flex justify-between items-center">
              <div className="min-w-0">
                <p className="font-medium dark:text-white truncate">{clienteNuevo.nombre_fantasia}</p>
                {clienteNuevo.direccion && (
                  <p className="text-sm text-gray-500 dark:text-gray-400 truncate">{clienteNuevo.direccion}</p>
                )}
              </div>
              <button
                type="button"
                onClick={() => { setNuevoClienteId(''); setBusquedaCliente(''); }}
                className="text-red-500 p-1 flex-shrink-0"
                aria-label="Quitar cliente seleccionado"
              >
                <X className="w-5 h-5" />
              </button>
            </div>
          ) : (
            <div>
              <div className="relative w-full">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-5 h-5 pointer-events-none" />
                <input
                  type="text"
                  value={busquedaCliente}
                  onChange={e => setBusquedaCliente(e.target.value)}
                  autoComplete="off"
                  className="block w-full pl-10 pr-3 py-3 min-h-11 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none"
                  placeholder="Buscar por nombre, razón social o CUIT..."
                />
              </div>
              {clientesFiltrados.length > 0 && (
                <div role="listbox" aria-label="Resultados de clientes" className="border dark:border-gray-600 rounded-lg max-h-40 overflow-y-auto mt-2">
                  {clientesFiltrados.map(c => (
                    <button
                      type="button"
                      role="option"
                      aria-selected={false}
                      key={c.id}
                      className="w-full text-left p-3 hover:bg-blue-50 dark:hover:bg-blue-900/30 border-b dark:border-gray-600 focus:outline-none focus:bg-blue-100 dark:focus:bg-blue-900/50"
                      onClick={() => { setNuevoClienteId(c.id.toString()); setBusquedaCliente(''); }}
                    >
                      <p className="font-medium dark:text-white">{c.nombre_fantasia}</p>
                      {c.razon_social && c.razon_social !== c.nombre_fantasia && (
                        <p className="text-xs text-gray-400">{c.razon_social}</p>
                      )}
                      <p className="text-sm text-gray-500 dark:text-gray-400">{c.direccion}</p>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Comparación de precios (solo con cliente nuevo elegido) */}
        {clienteNuevo && (
          <div className="space-y-3">
            {isLoading ? (
              <div className="flex items-center justify-center gap-2 py-6 text-gray-500 dark:text-gray-400">
                <Loader2 className="w-5 h-5 animate-spin" />
                <span className="text-sm">Recalculando precios…</span>
              </div>
            ) : (
              <>
                {/* Detalle de items recalculados */}
                <div className="border dark:border-gray-700 rounded-lg divide-y dark:divide-gray-700">
                  {descuento.items.map((item, idx) => (
                    <div key={`${item.productoId}-${idx}`} className="flex items-center justify-between gap-2 p-2.5 text-sm">
                      <div className="min-w-0 flex items-center gap-1.5">
                        {item.esBonificacion && <Gift className="w-4 h-4 text-green-600 flex-shrink-0" />}
                        <span className="truncate dark:text-gray-200">{nombreProducto(String(item.productoId))}</span>
                      </div>
                      <div className="flex-shrink-0 text-right">
                        {item.esBonificacion ? (
                          <span className="text-green-600 font-medium">{item.cantidad} × Regalo</span>
                        ) : (
                          <span className="dark:text-gray-200">{item.cantidad} × {formatPrecio(item.precioUnitario)}</span>
                        )}
                      </div>
                    </div>
                  ))}
                </div>

                {/* Comparativo de totales */}
                <div className="p-3 bg-gray-50 dark:bg-gray-800 rounded-lg space-y-1.5">
                  <div className="flex items-center justify-between text-sm">
                    <span className="text-gray-500 dark:text-gray-400">Total anterior</span>
                    <span className="text-gray-500 dark:text-gray-400 line-through">{formatPrecio(totalViejo)}</span>
                  </div>
                  <div className="flex items-center justify-between">
                    <span className="font-medium dark:text-white flex items-center gap-1.5">
                      <ArrowRight className="w-4 h-4 text-blue-500" /> Total nuevo
                    </span>
                    <span className="text-lg font-bold dark:text-white">{formatPrecio(totalNuevo)}</span>
                  </div>
                  {Math.abs(delta) >= 0.01 && (
                    <div className={`text-xs text-right font-medium ${delta > 0 ? 'text-red-600' : 'text-green-600'}`}>
                      {delta > 0 ? '+' : ''}{formatPrecio(delta)} respecto al anterior
                    </div>
                  )}
                </div>
              </>
            )}
          </div>
        )}

        {/* Avisos */}
        <div className="flex items-start gap-2 p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg text-xs text-amber-800 dark:text-amber-200">
          <AlertCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
          <div className="space-y-0.5">
            <p>El pedido actual se <strong>cancelará</strong> y se creará uno nuevo para el cliente elegido. Si estaba asignado a una ruta, saldrá de la ruta.</p>
            {tienePago && <p>El pago registrado se <strong>transferirá</strong> al pedido nuevo.</p>}
          </div>
        </div>
      </div>

      {/* Acciones */}
      <div className="flex gap-2 p-4 border-t dark:border-gray-700">
        <button
          type="button"
          onClick={onClose}
          disabled={guardando}
          className="flex-1 py-2.5 border dark:border-gray-600 rounded-lg font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-50"
        >
          Cancelar
        </button>
        <button
          type="button"
          onClick={handleConfirmar}
          disabled={!clienteNuevo || isLoading || guardando}
          className="flex-1 py-2.5 bg-blue-600 text-white rounded-lg font-medium hover:bg-blue-700 disabled:bg-blue-400 disabled:cursor-not-allowed flex items-center justify-center gap-2"
        >
          {guardando ? (
            <><Loader2 className="w-4 h-4 animate-spin" /> Cambiando…</>
          ) : (
            <><RefreshCw className="w-4 h-4" /> Confirmar cambio</>
          )}
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalCambiarCliente;
