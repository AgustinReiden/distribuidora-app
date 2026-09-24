import React, { useState } from 'react'
import { createPortal } from 'react-dom'
import { Wifi, WifiOff, Cloud, CloudOff, RefreshCw, AlertTriangle, X, ChevronDown, ChevronUp } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import { Button } from '../ui/Button'
import { getNoticeRoot } from '../ui/noticeRoot'

interface PedidoOffline {
  offlineId: string;
  clienteId: string;
  /** Se acuña al encolar (ver PedidoOffline en useOfflineSync); funciona sin
   *  señal, a diferencia de buscar el cliente por id en una lista aparte. */
  clienteNombre?: string;
  items?: Array<{ producto_id: string; cantidad: number }>;
  total: number;
  creadoOffline: string;
}

interface MermaOffline {
  offlineId: string;
  productoNombre?: string;
  cantidad: number;
  motivo: string;
}

export interface OfflineIndicatorProps {
  isOnline: boolean;
  pedidosPendientes?: PedidoOffline[];
  mermasPendientes?: MermaOffline[];
  sincronizando?: boolean;
  onSincronizar?: () => void;
}

export default function OfflineIndicator({
  isOnline,
  pedidosPendientes = [],
  mermasPendientes = [],
  sincronizando = false,
  onSincronizar
}: OfflineIndicatorProps): React.ReactElement | null {
  const [expandido, setExpandido] = useState<boolean>(false)
  const cantidadTotal = pedidosPendientes.length + mermasPendientes.length

  // No mostrar nada si esta online y no hay pendientes
  if (isOnline && cantidadTotal === 0) return null

  // La posición la pone la pila de avisos (ver ui/noticeRoot), no este wrapper.
  // Sin `w-full` a propósito: colapsado es una pastilla que se ajusta a su texto
  // y la pila la alinea a la derecha; a lo ancho, el botón quedaría a la izquierda.
  const root = getNoticeRoot()
  const aviso = (
    <div className={`pointer-events-auto max-w-sm ${expandido ? 'w-80' : ''}`}>
      {/* Boton principal */}
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
            <span className="font-medium">Sin conexion</span>
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
            <Button
              variant="ghost"
              size="iconSm"
              onClick={() => setExpandido(false)}
              className="text-gray-400 hover:text-gray-600"
              aria-label="Cerrar panel"
            >
              <X className="w-4 h-4" />
            </Button>
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
                        {pedido.clienteNombre || 'Cliente desconocido'}
                      </p>
                      <p className="text-xs text-gray-500">
                        {pedido.items?.length || 0} productos - {new Date(pedido.creadoOffline).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' })}
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
                        -{merma.cantidad} - {merma.motivo}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Boton de sincronizar */}
          <div className="p-3">
            {isOnline ? (
              <Button
                variant="primary"
                onClick={onSincronizar}
                disabled={sincronizando}
                className="w-full"
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
              </Button>
            ) : (
              <div className="flex items-center gap-2 p-2 bg-gray-100 dark:bg-gray-700 rounded text-sm text-gray-600 dark:text-gray-400">
                <AlertTriangle className="w-4 h-4" />
                <span>Se sincronizara cuando vuelva la conexion</span>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )

  return root ? createPortal(aviso, root) : aviso
}
