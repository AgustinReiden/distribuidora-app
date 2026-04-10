/**
 * ModalDetalleTransferencia
 *
 * Modal de solo lectura que muestra el detalle de un movimiento entre sucursales.
 */
import React from 'react'
import { X, ArrowUpRight, ArrowDownLeft, Package } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import type { TransferenciaDB } from '../../types'

interface ModalDetalleTransferenciaProps {
  transferencia: TransferenciaDB
  onClose: () => void
}

function formatFecha(fecha: string): string {
  try {
    return new Date(fecha).toLocaleDateString('es-AR', {
      day: '2-digit',
      month: '2-digit',
      year: 'numeric',
    })
  } catch {
    return fecha
  }
}

export default function ModalDetalleTransferencia({
  transferencia,
  onClose,
}: ModalDetalleTransferenciaProps): React.ReactElement {
  const esIngreso = transferencia.tipo === 'ingreso'
  const items = transferencia.items || []

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-2xl w-full max-w-2xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-3">
            <div className={`p-2 rounded-lg ${
              esIngreso
                ? 'bg-green-100 dark:bg-green-900/30'
                : 'bg-blue-100 dark:bg-blue-900/30'
            }`}>
              {esIngreso
                ? <ArrowDownLeft className="w-5 h-5 text-green-600" />
                : <ArrowUpRight className="w-5 h-5 text-blue-600" />
              }
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                {esIngreso ? 'Ingreso desde Sucursal' : 'Salida a Sucursal'}
              </h2>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                {formatFecha(transferencia.fecha)} - {transferencia.sucursal?.nombre || 'Sin sucursal'}
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          >
            <X className="w-5 h-5 text-gray-500 dark:text-gray-400" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          {/* Info */}
          {(transferencia.notas || transferencia.usuario) && (
            <div className="space-y-1 text-sm text-gray-600 dark:text-gray-400">
              {transferencia.usuario && (
                <p>Registrado por: <span className="font-medium text-gray-800 dark:text-white">{transferencia.usuario.nombre}</span></p>
              )}
              {transferencia.notas && (
                <p>Notas: <span className="text-gray-800 dark:text-white">{transferencia.notas}</span></p>
              )}
            </div>
          )}

          {/* Items table */}
          {items.length > 0 ? (
            <div className="border dark:border-gray-700 rounded-lg overflow-hidden">
              <div className="hidden sm:grid grid-cols-12 gap-2 px-4 py-2 bg-gray-50 dark:bg-gray-700/50 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">
                <div className="col-span-5">Producto</div>
                <div className="col-span-2 text-center">Cantidad</div>
                <div className="col-span-2 text-right">Costo Unit.</div>
                <div className="col-span-3 text-right">Subtotal</div>
              </div>
              {items.map(item => (
                <div
                  key={item.id}
                  className="grid grid-cols-12 gap-2 px-4 py-3 items-center border-t dark:border-gray-700 first:border-t-0"
                >
                  <div className="col-span-12 sm:col-span-5">
                    <p className="text-sm font-medium text-gray-800 dark:text-white">
                      {item.producto?.nombre || `Producto #${item.producto_id}`}
                    </p>
                    {item.producto?.codigo && (
                      <p className="text-xs text-gray-500">{item.producto.codigo}</p>
                    )}
                  </div>
                  <div className="col-span-4 sm:col-span-2 text-center text-sm text-gray-800 dark:text-white">
                    {item.cantidad}
                  </div>
                  <div className="col-span-4 sm:col-span-2 text-right text-sm text-gray-600 dark:text-gray-300">
                    {formatPrecio(item.costo_unitario)}
                  </div>
                  <div className="col-span-4 sm:col-span-3 text-right text-sm font-medium text-gray-800 dark:text-white">
                    {formatPrecio(item.subtotal)}
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <div className="flex flex-col items-center py-8 text-gray-400">
              <Package className="w-8 h-8 mb-2" />
              <p className="text-sm">Sin items</p>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t dark:border-gray-700 bg-gray-50 dark:bg-gray-800/50">
          <div className="text-lg font-semibold text-gray-800 dark:text-white">
            Total: {formatPrecio(transferencia.total_costo)}
          </div>
          <button
            onClick={onClose}
            className="px-4 py-2 border dark:border-gray-600 rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors font-medium"
          >
            Cerrar
          </button>
        </div>
      </div>
    </div>
  )
}
