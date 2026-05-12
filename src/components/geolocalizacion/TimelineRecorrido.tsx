import React from 'react'
import { Clock, MapPin, AlertCircle } from 'lucide-react'
import { formatPrecio, formatHora } from '../../utils/formatters'
import { clasificarDistancia, formatDistancia, SEMAFORO_COLORS, colorPreventista } from '../../utils/geo'
import type { PedidoConGps } from '../../hooks/queries'

interface TimelineRecorridoProps {
  pedidos: PedidoConGps[]
  preventistaId: string | null
  preventistaNombre: string | null
  selectedPedidoId: number | null
  onSelectPedido: (pedidoId: number | null) => void
}

export default function TimelineRecorrido({
  pedidos,
  preventistaId,
  preventistaNombre,
  selectedPedidoId,
  onSelectPedido,
}: TimelineRecorridoProps): React.ReactElement {
  if (!preventistaId) {
    return (
      <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-6 text-center text-sm text-gray-500 dark:text-gray-400">
        Seleccioná un preventista en la lista o en el mapa para ver su recorrido del día.
      </div>
    )
  }

  // Ordenamos por created_at del pedido para que el timeline refleje el
  // orden real de creación, independiente de si hubo o no check-in GPS.
  // Fallback a gps_capturado_at para pedidos previos a la migración 041.
  const propios = pedidos
    .filter(p => p.preventista_id === preventistaId)
    .sort((a, b) => {
      const ta = Date.parse(a.pedido_created_at ?? a.gps_capturado_at ?? '') || 0
      const tb = Date.parse(b.pedido_created_at ?? b.gps_capturado_at ?? '') || 0
      return ta - tb
    })

  if (propios.length === 0) {
    return (
      <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-6 text-center text-sm text-gray-500 dark:text-gray-400">
        Este preventista no tiene pedidos en el rango seleccionado.
      </div>
    )
  }

  const color = colorPreventista(preventistaId)
  const conGps = propios.filter(p => p.gps_status === 'ok').length

  return (
    <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
      <div className="px-4 py-3 border-b border-gray-200 dark:border-gray-700 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="w-3 h-3 rounded-full" style={{ backgroundColor: color }} aria-hidden />
          <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200">
            Recorrido de {preventistaNombre ?? 'preventista'}
          </h3>
        </div>
        <span className="text-xs text-gray-500 dark:text-gray-400">
          {propios.length} pedido{propios.length === 1 ? '' : 's'} · {conGps} con GPS
        </span>
      </div>
      <ol className="divide-y divide-gray-100 dark:divide-gray-700 max-h-[40vh] overflow-y-auto">
        {propios.map((p, idx) => {
          const isSelected = selectedPedidoId === p.pedido_id
          const clasif = clasificarDistancia(p.distancia_m)
          const cfg = SEMAFORO_COLORS[clasif]
          const sinGps = p.gps_status !== 'ok'

          return (
            <li key={p.pedido_id}>
              <button
                type="button"
                onClick={() => onSelectPedido(isSelected ? null : p.pedido_id)}
                className={`w-full text-left px-4 py-3 flex items-start gap-3 transition-colors ${
                  isSelected
                    ? 'bg-blue-50 dark:bg-blue-900/20'
                    : 'hover:bg-gray-50 dark:hover:bg-gray-700/50'
                }`}
                aria-pressed={isSelected}
              >
                <span
                  className={`shrink-0 w-7 h-7 rounded-full flex items-center justify-center text-white text-xs font-semibold ${
                    sinGps ? 'bg-gray-300 dark:bg-gray-600' : ''
                  }`}
                  style={sinGps ? undefined : { backgroundColor: color }}
                  aria-hidden
                >
                  {idx + 1}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center justify-between gap-2">
                    <p className="text-sm font-medium text-gray-900 dark:text-white truncate">
                      {p.cliente_nombre || 'Cliente sin nombre'}
                    </p>
                    <span
                      className="shrink-0 text-xs text-gray-500 dark:text-gray-400 inline-flex items-center gap-1"
                      title="Hora de creación del pedido"
                    >
                      <Clock className="w-3 h-3" />
                      {formatHora(p.pedido_created_at ?? p.gps_capturado_at)}
                    </span>
                  </div>
                  <div className="mt-1 flex items-center justify-between gap-2 flex-wrap">
                    <span className="text-xs text-gray-500 dark:text-gray-400">
                      #{p.pedido_id} · {formatPrecio(Number(p.total) || 0)}
                    </span>
                    {sinGps ? (
                      <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full ${SEMAFORO_COLORS.sin_dato.bg}`}>
                        <AlertCircle className="w-3 h-3" />
                        Sin GPS
                      </span>
                    ) : (
                      <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full ${cfg.bg}`} title={cfg.label}>
                        <MapPin className="w-3 h-3" />
                        {formatDistancia(p.distancia_m)}
                      </span>
                    )}
                  </div>
                </div>
              </button>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
