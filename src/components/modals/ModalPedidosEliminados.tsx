import { useState, useEffect, type ReactElement } from 'react';
import { Trash2, Calendar, User, Package, DollarSign, Loader2, AlertCircle } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatPrecio, formatFecha } from '../../utils/formatters';
import type { EstadoPedido, FormaPago } from '../../types';

type EstadoPago = 'pendiente' | 'parcial' | 'pagado';

interface PedidoItem {
  producto_id: string;
  producto_nombre?: string;
  producto_codigo?: string;
  cantidad: number;
  precio_unitario: number;
  subtotal: number;
}

interface PedidoEliminado {
  id: string;
  pedido_id: string;
  cliente_nombre?: string;
  cliente_direccion?: string;
  total: number;
  estado: EstadoPedido;
  forma_pago?: FormaPago;
  fecha_pedido: string;
  eliminado_por_nombre?: string;
  eliminado_at: string;
  motivo_eliminacion?: string;
  usuario_creador_nombre?: string;
  items?: PedidoItem[];
  stock_restaurado?: boolean;
}

export interface ModalPedidosEliminadosProps {
  onFetch: () => Promise<PedidoEliminado[]>;
  onClose: () => void;
}

export default function ModalPedidosEliminados({
  onFetch,
  onClose
}: ModalPedidosEliminadosProps): ReactElement {
  const [pedidos, setPedidos] = useState<PedidoEliminado[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [pedidoExpandido, setPedidoExpandido] = useState<string | null>(null);

  useEffect(() => {
    const cargarPedidos = async (): Promise<void> => {
      try {
        setLoading(true);
        const data = await onFetch();
        setPedidos(data);
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Error al cargar pedidos';
        setError(errorMessage);
      } finally {
        setLoading(false);
      }
    };
    cargarPedidos();
  }, [onFetch]);

  const getEstadoColor = (estado: EstadoPedido): string => {
    const colores: Record<string, string> = {
      pendiente: 'bg-yellow-100 text-yellow-700 dark:bg-yellow-900/30 dark:text-yellow-400',
      en_preparacion: 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-400',
      asignado: 'bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-400',
      entregado: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
    };
    return colores[estado] || 'bg-gray-100 text-gray-700';
  };

  return (
    <ModalBase title="Historial de Pedidos Eliminados" onClose={onClose} maxWidth="max-w-4xl">
      <div className="p-4 max-h-[70vh] overflow-y-auto">
        {loading ? (
          <div className="flex items-center justify-center py-12">
            <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
          </div>
        ) : error ? (
          <div className="flex items-center justify-center py-12 text-red-500">
            <AlertCircle className="w-6 h-6 mr-2" />
            <span>{error}</span>
          </div>
        ) : pedidos.length === 0 ? (
          <div className="text-center py-12 text-gray-500">
            <Trash2 className="w-12 h-12 mx-auto mb-3 opacity-50" />
            <p>No hay pedidos eliminados registrados</p>
          </div>
        ) : (
          <div className="space-y-3">
            {pedidos.map(pedido => (
              <div
                key={pedido.id}
                className="border dark:border-gray-700 rounded-lg overflow-hidden"
              >
                {/* Header del pedido */}
                <div
                  className="bg-gray-50 dark:bg-gray-700/50 p-4 cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-700"
                  onClick={() => setPedidoExpandido(pedidoExpandido === pedido.id ? null : pedido.id)}
                >
                  <div className="flex items-center justify-between">
                    <div className="flex items-center gap-3">
                      <div className="p-2 bg-red-100 dark:bg-red-900/30 rounded-lg">
                        <Trash2 className="w-5 h-5 text-red-600" />
                      </div>
                      <div>
                        <p className="font-semibold dark:text-white">
                          Pedido #{pedido.pedido_id}
                        </p>
                        <p className="text-sm text-gray-500">
                          {pedido.cliente_nombre || 'Cliente desconocido'}
                        </p>
                      </div>
                    </div>
                    <div className="text-right">
                      <p className="font-semibold text-lg text-blue-600">
                        {formatPrecio(pedido.total)}
                      </p>
                      <span className={`text-xs px-2 py-0.5 rounded ${getEstadoColor(pedido.estado)}`}>
                        {pedido.estado}
                      </span>
                    </div>
                  </div>

                  {/* Info de eliminacion */}
                  <div className="mt-3 pt-3 border-t dark:border-gray-600 flex flex-wrap items-center gap-4 text-sm">
                    <div className="flex items-center gap-1 text-red-600 dark:text-red-400">
                      <User className="w-4 h-4" />
                      <span>Eliminado por: {pedido.eliminado_por_nombre || 'Desconocido'}</span>
                    </div>
                    <div className="flex items-center gap-1 text-gray-500">
                      <Calendar className="w-4 h-4" />
                      <span>{formatFecha(pedido.eliminado_at)}</span>
                    </div>
                    {pedido.motivo_eliminacion && (
                      <div className="text-gray-600 dark:text-gray-400 italic">
                        Motivo: &quot;{pedido.motivo_eliminacion}&quot;
                      </div>
                    )}
                  </div>
                </div>

                {/* Detalle expandido */}
                {pedidoExpandido === pedido.id && (
                  <div className="p-4 bg-white dark:bg-gray-800 border-t dark:border-gray-700">
                    {/* Info del pedido */}
                    <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-4">
                      <div>
                        <p className="text-xs text-gray-500">Cliente</p>
                        <p className="text-sm font-medium dark:text-white">{pedido.cliente_nombre}</p>
                        <p className="text-xs text-gray-500">{pedido.cliente_direccion}</p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500">Creado por</p>
                        <p className="text-sm font-medium dark:text-white">{pedido.usuario_creador_nombre || '-'}</p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500">Fecha pedido</p>
                        <p className="text-sm font-medium dark:text-white">{formatFecha(pedido.fecha_pedido)}</p>
                      </div>
                      <div>
                        <p className="text-xs text-gray-500">Forma de pago</p>
                        <p className="text-sm font-medium dark:text-white">{pedido.forma_pago || '-'}</p>
                      </div>
                    </div>

                    {/* Items del pedido */}
                    <div className="border dark:border-gray-700 rounded-lg overflow-hidden">
                      <div className="bg-gray-50 dark:bg-gray-700/50 px-3 py-2 flex items-center gap-2">
                        <Package className="w-4 h-4 text-blue-600" />
                        <span className="text-sm font-medium dark:text-white">Productos</span>
                      </div>
                      <div className="divide-y dark:divide-gray-700">
                        {pedido.items && pedido.items.length > 0 ? (
                          pedido.items.map((item, idx) => (
                            <div key={idx} className="px-3 py-2 flex justify-between items-center">
                              <div>
                                <p className="text-sm font-medium dark:text-white">
                                  {item.producto_nombre || `Producto ${item.producto_id}`}
                                </p>
                                <p className="text-xs text-gray-500">
                                  {item.producto_codigo} - {formatPrecio(item.precio_unitario)} x {item.cantidad}
                                </p>
                              </div>
                              <span className="font-medium text-blue-600">
                                {formatPrecio(item.subtotal)}
                              </span>
                            </div>
                          ))
                        ) : (
                          <div className="px-3 py-2 text-sm text-gray-500">
                            No hay informacion de productos
                          </div>
                        )}
                      </div>
                    </div>

                    {/* Stock restaurado */}
                    <div className="mt-3 text-xs text-gray-500 flex items-center gap-1">
                      <DollarSign className="w-3 h-3" />
                      Stock {pedido.stock_restaurado ? 'restaurado' : 'NO restaurado'} al eliminar
                    </div>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>

      <div className="flex justify-end p-4 border-t dark:border-gray-700">
        <button
          onClick={onClose}
          className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-300 dark:hover:bg-gray-600"
        >
          Cerrar
        </button>
      </div>
    </ModalBase>
  );
}
