import React, { useState } from 'react'
import { Wifi, WifiOff, Cloud, CloudOff, RefreshCw, Check, AlertTriangle, X, ChevronDown, ChevronUp } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'

export default function OfflineIndicator({
  isOnline,
  pedidosPendientes = [],
  mermasPendientes = [],
  sincronizando,
  onSincronizar,
  clientes = []
}) {
  const [expandido, setExpandido] = useState(false)
  const cantidadTotal = pedidosPendientes.length + mermasPendientes.length

  // No mostrar nada si está online y no hay pendientes
  if (isOnline && cantidadTotal === 0) return null

  const getClienteNombre = (clienteId) => {
    const cliente = clientes.find(c => c.id === clienteId)
    return cliente?.nombre_fantasia || 'Cliente desconocido'
  }

  return (
    <div className={`fixed bottom-4 right-4 z-50 max-w-sm ${expandido ? 'w-80' : ''}`}>
      {/* Botón principal */}
      <button
        onClick={() => setExpandido(!expandido)}
        className={`flex items-center gap-2 px-4 py-2 rounded-lg shadow-lg transition-all ${
          isOnline
            ? cantidadTotal > 0
              ? 'bg-amber-500 hover:bg-amber-600 text-white'
              : 'bg-green-500 hover:bg-green-600 text-white'
            : 'bg-red-500 hover:bg-red-600 text-white'
        }`}
      >
        {isOnline ? (
          cantidadTotal > 0 ? (
            <>
              <Cloud className="w-5 h-5" />
              <span className="font-medium">{cantidadTotal} pendiente{cantidadTotal > 1 ? 's' : ''}</span>
            </>
          ) : (
            <>
              <Wifi className="w-5 h-5" />
              <span className="font-medium">Conectado</span>
            </>
          )
        ) : (
          <>
            <WifiOff className="w-5 h-5" />
            <span className="font-medium">Sin conexión</span>
            {cantidadTotal > 0 && (
              <span className="bg-white/20 px-2 py-0.5 rounded-full text-xs">
                {cantidadTotal}
              </span>
            )}
          </>
        )}
        {cantidadTotal > 0 && (
          expandido ? <ChevronDown className="w-4 h-4" /> : <ChevronUp className="w-4 h-4" />
        )}
      </button>

      {/* Panel expandido */}
      {expandido && cantidadTotal > 0 && (
        <div className="mt-2 bg-white dark:bg-gray-800 rounded-lg shadow-xl border dark:border-gray-700 overflow-hidden">
          {/* Header */}
          <div className="p-3 bg-gray-50 dark:bg-gray-900 border-b dark:border-gray-700 flex items-center justify-between">
            <div className="flex items-center gap-2">
              <CloudOff className="w-4 h-4 text-amber-500" />
              <span className="font-medium text-sm text-gray-700 dark:text-gray-300">
                Pendientes de sincronizar
              </span>
            </div>
            <button onClick={() => setExpandido(false)} className="text-gray-400 hover:text-gray-600">
              <X className="w-4 h-4" />
            </button>
          </div>

          {/* Lista de pedidos pendientes */}
          {pedidosPendientes.length > 0 && (
            <div className="p-3 border-b dark:border-gray-700">
              <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mb-2">
                PEDIDOS ({pedidosPendientes.length})
              </p>
              <div className="space-y-2 max-h-40 overflow-y-auto">
                {pedidosPendientes.map(pedido => (
                  <div
                    key={pedido.offlineId}
                    className="flex items-center justify-between p-2 bg-amber-50 dark:bg-amber-900/20 rounded text-sm"
                  >
                    <div>
                      <p className="font-medium text-gray-700 dark:text-gray-300">
                        {getClienteNombre(pedido.clienteId)}
                      </p>
                      <p className="text-xs text-gray-500">
                        {pedido.items?.length || 0} productos • {new Date(pedido.creadoOffline).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' })}
                      </p>
                    </div>
                    <span className="font-bold text-amber-600">
                      {formatPrecio(pedido.total)}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Lista de mermas pendientes */}
          {mermasPendientes.length > 0 && (
            <div className="p-3 border-b dark:border-gray-700">
              <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mb-2">
                MERMAS ({mermasPendientes.length})
              </p>
              <div className="space-y-2 max-h-40 overflow-y-auto">
                {mermasPendientes.map(merma => (
                  <div
                    key={merma.offlineId}
                    className="flex items-center justify-between p-2 bg-red-50 dark:bg-red-900/20 rounded text-sm"
                  >
                    <div>
                      <p className="font-medium text-gray-700 dark:text-gray-300">
                        {merma.productoNombre || 'Producto'}
                      </p>
                      <p className="text-xs text-gray-500">
                        -{merma.cantidad} • {merma.motivo}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Botón de sincronizar */}
          <div className="p-3">
            {isOnline ? (
              <button
                onClick={onSincronizar}
                disabled={sincronizando}
                className="w-full flex items-center justify-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg transition-colors"
              >
                {sincronizando ? (
                  <>
                    <RefreshCw className="w-4 h-4 animate-spin" />
                    <span>Sincronizando...</span>
                  </>
                ) : (
                  <>
                    <Cloud className="w-4 h-4" />
                    <span>Sincronizar ahora</span>
                  </>
                )}
              </button>
            ) : (
              <div className="flex items-center gap-2 p-2 bg-gray-100 dark:bg-gray-700 rounded text-sm text-gray-600 dark:text-gray-400">
                <AlertTriangle className="w-4 h-4" />
                <span>Se sincronizará cuando vuelva la conexión</span>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
