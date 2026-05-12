import React, { useMemo } from 'react'
import { Clock, MapPin, AlertCircle, ShoppingCart } from 'lucide-react'
import { formatPrecio, formatHora } from '../../utils/formatters'
import { clasificarDistancia, formatDistancia, SEMAFORO_COLORS, colorPreventista } from '../../utils/geo'
import type { PedidoConGps, VisitaConGps } from '../../hooks/queries'

interface TimelineRecorridoProps {
  pedidos: PedidoConGps[]
  visitas: VisitaConGps[]
  preventistaId: string | null
  preventistaNombre: string | null
  selectedPedidoId: number | null
  onSelectPedido: (pedidoId: number | null) => void
}

type EventoTimeline =
  | { tipo: 'pedido'; ts: number; pedido: PedidoConGps }
  | { tipo: 'visita'; ts: number; visita: VisitaConGps }

export default function TimelineRecorrido({
  pedidos,
  visitas,
  preventistaId,
  preventistaNombre,
  selectedPedidoId,
  onSelectPedido,
}: TimelineRecorridoProps): React.ReactElement {
  const eventos = useMemo<EventoTimeline[]>(() => {
    if (!preventistaId) return []
    const list: EventoTimeline[] = []
    for (const p of pedidos) {
      if (p.preventista_id !== preventistaId) continue
      const ts = Date.parse(p.pedido_created_at ?? p.gps_capturado_at ?? '') || 0
      list.push({ tipo: 'pedido', ts, pedido: p })
    }
    for (const v of visitas) {
      if (v.preventista_id !== preventistaId) continue
      const ts = Date.parse(v.visita_created_at ?? v.gps_capturado_at ?? '') || 0
      list.push({ tipo: 'visita', ts, visita: v })
    }
    return list.sort((a, b) => a.ts - b.ts)
  }, [pedidos, visitas, preventistaId])

  if (!preventistaId) {
    return (
      <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-6 text-center text-sm text-gray-500 dark:text-gray-400">
        Seleccioná un preventista en la lista o en el mapa para ver su recorrido del día.
      </div>
    )
  }

  if (eventos.length === 0) {
    return (
      <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-6 text-center text-sm text-gray-500 dark:text-gray-400">
        Este preventista no tiene pedidos ni visitas en el rango seleccionado.
      </div>
    )
  }

  const color = colorPreventista(preventistaId)
  const pedidosCount = eventos.filter(e => e.tipo === 'pedido').length
  const visitasCount = eventos.filter(e => e.tipo === 'visita').length

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
          {pedidosCount} pedido{pedidosCount === 1 ? '' : 's'}
          {visitasCount > 0 && ` · ${visitasCount} visita${visitasCount === 1 ? '' : 's'}`}
        </span>
      </div>
      <ol className="divide-y divide-gray-100 dark:divide-gray-700 max-h-[40vh] overflow-y-auto">
        {(() => {
          let pedidoIdx = 0
          return eventos.map(ev => {
            if (ev.tipo === 'pedido') {
              const p = ev.pedido
              pedidoIdx++
              const isSelected = selectedPedidoId === p.pedido_id
              const clasif = clasificarDistancia(p.distancia_m)
              const cfg = SEMAFORO_COLORS[clasif]
              const sinGps = p.gps_status !== 'ok'
              return (
                <li key={`p-${p.pedido_id}`}>
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
                      {pedidoIdx}
                    </span>
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center justify-between gap-2">
                        <p className="text-sm font-medium text-gray-900 dark:text-white truncate inline-flex items-center gap-1">
                          <ShoppingCart className="w-3.5 h-3.5 text-gray-400" aria-hidden />
                          {p.cliente_nombre || 'Cliente sin nombre'}
                        </p>
                        <span className="shrink-0 text-xs text-gray-500 dark:text-gray-400 inline-flex items-center gap-1" title="Hora de creación del pedido">
                          <Clock className="w-3 h-3" />
                          {formatHora(p.pedido_created_at ?? p.gps_capturado_at)}
                        </span>
                      </div>
                      <div className="mt-1 flex items-center justify-between gap-2 flex-wrap">
                        <span className="text-xs text-gray-500 dark:text-gray-400">
                          Pedido #{p.pedido_id} · {formatPrecio(Number(p.total) || 0)}
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
            }
            const v = ev.visita
            const clasif = clasificarDistancia(v.distancia_m)
            const cfg = SEMAFORO_COLORS[clasif]
            const sinGps = v.gps_status !== 'ok'
            return (
              <li key={`v-${v.visita_id}`} className="px-4 py-3 flex items-start gap-3">
                <span
                  className="shrink-0 w-5 h-5 mt-1 rounded-full ring-2 ring-white dark:ring-gray-800"
                  style={{ backgroundColor: color, opacity: sinGps ? 0.4 : 0.75 }}
                  aria-hidden
                />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center justify-between gap-2">
                    <p className="text-sm font-medium text-gray-700 dark:text-gray-200 truncate inline-flex items-center gap-1">
                      <MapPin className="w-3.5 h-3.5 text-gray-400" aria-hidden />
                      {v.cliente_nombre || 'Cliente sin nombre'}
                    </p>
                    <span className="shrink-0 text-xs text-gray-500 dark:text-gray-400 inline-flex items-center gap-1" title="Hora del ping de visita">
                      <Clock className="w-3 h-3" />
                      {formatHora(v.visita_created_at)}
                    </span>
                  </div>
                  <div className="mt-1 flex items-center justify-between gap-2 flex-wrap">
                    <span className="text-xs text-gray-500 dark:text-gray-400">Visita marcada</span>
                    {sinGps ? (
                      <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full ${SEMAFORO_COLORS.sin_dato.bg}`}>
                        <AlertCircle className="w-3 h-3" />
                        Sin GPS
                      </span>
                    ) : (
                      <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full ${cfg.bg}`} title={cfg.label}>
                        <MapPin className="w-3 h-3" />
                        {formatDistancia(v.distancia_m)}
                      </span>
                    )}
                  </div>
                </div>
              </li>
            )
          })
        })()}
      </ol>
    </div>
  )
}
