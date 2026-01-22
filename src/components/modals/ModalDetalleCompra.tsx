import React from 'react'
import { X, ShoppingCart, Package, Building2, Calendar, CreditCard, FileText, TrendingUp, Hash } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import type { Producto, Proveedor, Usuario } from '../../types'

type EstadoCompra = 'pendiente' | 'recibida' | 'parcial' | 'cancelada';
type FormaPagoCompra = 'efectivo' | 'transferencia' | 'cheque' | 'cuenta_corriente' | 'tarjeta';

interface EstadoConfig {
  label: string;
  color: string;
}

const ESTADOS_COMPRA: Record<EstadoCompra, EstadoConfig> = {
  pendiente: { label: 'Pendiente', color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-400' },
  recibida: { label: 'Recibida', color: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400' },
  parcial: { label: 'Parcial', color: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400' },
  cancelada: { label: 'Cancelada', color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400' }
}

const FORMAS_PAGO: Record<FormaPagoCompra, string> = {
  efectivo: 'Efectivo',
  transferencia: 'Transferencia',
  cheque: 'Cheque',
  cuenta_corriente: 'Cuenta Corriente',
  tarjeta: 'Tarjeta'
}

interface CompraItem {
  producto_id: string;
  producto?: Producto;
  cantidad: number;
  costo_unitario: number;
  subtotal?: number;
  stock_anterior?: number;
  stock_nuevo?: number;
}

interface CompraDetalle {
  id: string;
  proveedor?: Proveedor & { cuit?: string };
  proveedor_nombre?: string;
  estado: EstadoCompra;
  items?: CompraItem[];
  created_at: string;
  fecha_compra: string;
  numero_factura?: string;
  forma_pago: FormaPagoCompra;
  subtotal: number;
  iva: number;
  otros_impuestos?: number;
  total: number;
  notas?: string;
  usuario?: Usuario;
}

export interface ModalDetalleCompraProps {
  compra: CompraDetalle | null;
  onClose: () => void;
  onAnular?: (compraId: string) => void;
}

export default function ModalDetalleCompra({
  compra,
  onClose,
  onAnular
}: ModalDetalleCompraProps): React.ReactElement | null {
  if (!compra) return null

  const estado = ESTADOS_COMPRA[compra.estado] || ESTADOS_COMPRA.pendiente
  const totalUnidades = (compra.items || []).reduce((sum, i) => sum + i.cantidad, 0)

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <ShoppingCart className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                Detalle de Compra #{compra.id}
              </h2>
              <p className="text-sm text-gray-500">
                {new Date(compra.created_at).toLocaleDateString('es-AR', {
                  year: 'numeric',
                  month: 'long',
                  day: 'numeric',
                  hour: '2-digit',
                  minute: '2-digit'
                })}
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <span className={`px-3 py-1 rounded-full text-xs font-medium ${estado.color}`}>
              {estado.label}
            </span>
            <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
              <X className="w-5 h-5" />
            </button>
          </div>
        </div>

        {/* Contenido scrolleable */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Info del proveedor */}
          <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
            <div className="flex items-center gap-2 mb-3">
              <Building2 className="w-5 h-5 text-gray-500" />
              <h3 className="font-medium text-gray-800 dark:text-white">Proveedor</h3>
            </div>
            <p className="text-lg font-medium text-gray-800 dark:text-white">
              {compra.proveedor?.nombre || compra.proveedor_nombre || 'Sin proveedor especificado'}
            </p>
            {compra.proveedor?.cuit && (
              <p className="text-sm text-gray-500">CUIT: {compra.proveedor.cuit}</p>
            )}
          </div>

          {/* Datos de la compra */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3">
              <div className="flex items-center gap-2 text-gray-500 mb-1">
                <Calendar className="w-4 h-4" />
                <span className="text-xs">Fecha compra</span>
              </div>
              <p className="font-medium text-gray-800 dark:text-white">
                {new Date(compra.fecha_compra).toLocaleDateString('es-AR')}
              </p>
            </div>
            <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3">
              <div className="flex items-center gap-2 text-gray-500 mb-1">
                <Hash className="w-4 h-4" />
                <span className="text-xs">N Factura</span>
              </div>
              <p className="font-medium text-gray-800 dark:text-white">
                {compra.numero_factura || 'Sin especificar'}
              </p>
            </div>
            <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3">
              <div className="flex items-center gap-2 text-gray-500 mb-1">
                <CreditCard className="w-4 h-4" />
                <span className="text-xs">Forma de pago</span>
              </div>
              <p className="font-medium text-gray-800 dark:text-white">
                {FORMAS_PAGO[compra.forma_pago] || compra.forma_pago}
              </p>
            </div>
            <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3">
              <div className="flex items-center gap-2 text-gray-500 mb-1">
                <Package className="w-4 h-4" />
                <span className="text-xs">Total unidades</span>
              </div>
              <p className="font-medium text-gray-800 dark:text-white">{totalUnidades}</p>
            </div>
          </div>

          {/* Items de la compra */}
          <div>
            <div className="flex items-center gap-2 mb-3">
              <Package className="w-5 h-5 text-gray-500" />
              <h3 className="font-medium text-gray-800 dark:text-white">Productos ({compra.items?.length || 0})</h3>
            </div>
            <div className="bg-gray-50 dark:bg-gray-900 rounded-lg overflow-hidden">
              <table className="w-full text-sm">
                <thead className="bg-gray-100 dark:bg-gray-800">
                  <tr>
                    <th className="text-left px-4 py-2 text-gray-600 dark:text-gray-400">Producto</th>
                    <th className="text-center px-4 py-2 text-gray-600 dark:text-gray-400">Cantidad</th>
                    <th className="text-right px-4 py-2 text-gray-600 dark:text-gray-400">Costo Unit.</th>
                    <th className="text-right px-4 py-2 text-gray-600 dark:text-gray-400">Subtotal</th>
                  </tr>
                </thead>
                <tbody className="divide-y dark:divide-gray-700">
                  {(compra.items || []).map((item, index) => (
                    <tr key={index}>
                      <td className="px-4 py-3">
                        <p className="font-medium text-gray-800 dark:text-white">
                          {item.producto?.nombre || 'Producto'}
                        </p>
                        <p className="text-xs text-gray-500">
                          Stock: {item.stock_anterior} -&gt; {item.stock_nuevo}
                          <TrendingUp className="inline w-3 h-3 ml-1 text-green-500" />
                        </p>
                      </td>
                      <td className="px-4 py-3 text-center text-gray-800 dark:text-white">
                        {item.cantidad}
                      </td>
                      <td className="px-4 py-3 text-right text-gray-800 dark:text-white">
                        {formatPrecio(item.costo_unitario)}
                      </td>
                      <td className="px-4 py-3 text-right font-medium text-gray-800 dark:text-white">
                        {formatPrecio(item.subtotal || item.cantidad * item.costo_unitario)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {/* Totales */}
          <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4">
            <div className="space-y-2">
              <div className="flex justify-between text-sm">
                <span className="text-gray-600 dark:text-gray-400">Subtotal:</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(compra.subtotal)}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-gray-600 dark:text-gray-400">IVA:</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(compra.iva)}</span>
              </div>
              {compra.otros_impuestos && compra.otros_impuestos > 0 && (
                <div className="flex justify-between text-sm">
                  <span className="text-gray-600 dark:text-gray-400">Otros impuestos:</span>
                  <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(compra.otros_impuestos)}</span>
                </div>
              )}
              <div className="flex justify-between text-lg font-bold pt-2 border-t border-green-200 dark:border-green-800">
                <span className="text-gray-800 dark:text-white">Total:</span>
                <span className="text-green-600">{formatPrecio(compra.total)}</span>
              </div>
            </div>
          </div>

          {/* Notas */}
          {compra.notas && (
            <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4">
              <div className="flex items-center gap-2 mb-2">
                <FileText className="w-4 h-4 text-gray-500" />
                <span className="text-sm font-medium text-gray-600 dark:text-gray-400">Notas</span>
              </div>
              <p className="text-gray-800 dark:text-white">{compra.notas}</p>
            </div>
          )}

          {/* Usuario que registro */}
          {compra.usuario && (
            <div className="text-sm text-gray-500 text-center">
              Registrado por: {compra.usuario.nombre}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700">
          {compra.estado !== 'cancelada' && onAnular && (
            <button
              onClick={() => onAnular(compra.id)}
              className="px-4 py-2 text-red-600 border border-red-200 dark:border-red-800 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg transition-colors"
            >
              Anular Compra
            </button>
          )}
          <button
            onClick={onClose}
            className="flex-1 px-4 py-2 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg transition-colors"
          >
            Cerrar
          </button>
        </div>
      </div>
    </div>
  )
}
