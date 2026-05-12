import React, { useMemo } from 'react'
import { AlertTriangle, ZapOff, Search } from 'lucide-react'
import { formatPrecio, formatHora } from '../../utils/formatters'
import { clasificarDistancia, formatDistancia, SEMAFORO_COLORS } from '../../utils/geo'
import type { PedidoConGps, PreventistaResumen } from '../../hooks/queries'

interface TablaAnomaliasProps {
  pedidos: PedidoConGps[]
  preventistas: PreventistaResumen[]
  onSelectPedido: (pedidoId: number, preventistaId: string) => void
}

interface AnomaliaRow {
  pedido_id: number
  preventista_id: string
  preventista_nombre: string
  cliente_nombre: string
  hora: string
  motivo: 'sin_gps' | 'lejos'
  motivo_label: string
  distancia_m: number | null
  total: number
}

export default function TablaAnomalias({ pedidos, preventistas, onSelectPedido }: TablaAnomaliasProps): React.ReactElement {
  const nombresMap = useMemo(() => {
    const map: Record<string, string> = {}
    for (const p of preventistas) map[p.preventista_id] = p.preventista_nombre || 'Sin nombre'
    return map
  }, [preventistas])

  const rows = useMemo<AnomaliaRow[]>(() => {
    const result: AnomaliaRow[] = []
    for (const p of pedidos) {
      const sinGps = p.gps_status !== 'ok'
      const lejos = !sinGps && p.distancia_m != null && p.distancia_m >= 2000
      if (!sinGps && !lejos) continue
      result.push({
        pedido_id: p.pedido_id,
        preventista_id: p.preventista_id,
        preventista_nombre: nombresMap[p.preventista_id] ?? '—',
        cliente_nombre: p.cliente_nombre || 'Sin cliente',
        hora: formatHora(p.pedido_created_at ?? p.gps_capturado_at),
        motivo: sinGps ? 'sin_gps' : 'lejos',
        motivo_label: sinGps
          ? (p.gps_status === 'denied' ? 'GPS denegado'
            : p.gps_status === 'timeout' ? 'GPS sin respuesta'
            : p.gps_status === 'unavailable' ? 'GPS no disponible'
            : p.gps_status === 'error' ? 'GPS con error'
            : 'Sin check-in')
          : 'Lejos del cliente',
        distancia_m: p.distancia_m,
        total: Number(p.total) || 0,
      })
    }
    // Ordenar: lejos primero, luego sin GPS
    return result.sort((a, b) => {
      if (a.motivo !== b.motivo) return a.motivo === 'lejos' ? -1 : 1
      return (b.distancia_m ?? 0) - (a.distancia_m ?? 0)
    })
  }, [pedidos, nombresMap])

  if (rows.length === 0) {
    return (
      <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-6 text-center text-sm text-gray-500 dark:text-gray-400">
        <AlertTriangle className="w-6 h-6 mx-auto mb-2 text-green-500" />
        Sin anomalías en el rango seleccionado.
      </div>
    )
  }

  return (
    <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
      <div className="px-4 py-3 border-b border-gray-200 dark:border-gray-700 flex items-center justify-between">
        <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200">
          Anomalías <span className="text-gray-400 font-normal">({rows.length})</span>
        </h3>
      </div>
      <div className="overflow-x-auto">
        <table className="min-w-full text-sm">
          <thead className="bg-gray-50 dark:bg-gray-900/40 text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2 text-left font-medium">Preventista</th>
              <th className="px-4 py-2 text-left font-medium">Hora</th>
              <th className="px-4 py-2 text-left font-medium">Cliente</th>
              <th className="px-4 py-2 text-left font-medium">Motivo</th>
              <th className="px-4 py-2 text-right font-medium">Distancia</th>
              <th className="px-4 py-2 text-right font-medium">Total</th>
              <th className="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
            {rows.map(r => {
              const clasif = r.motivo === 'sin_gps' ? 'sin_dato' : clasificarDistancia(r.distancia_m)
              const cfg = SEMAFORO_COLORS[clasif]
              return (
                <tr key={r.pedido_id} className="hover:bg-gray-50 dark:hover:bg-gray-700/40">
                  <td className="px-4 py-2 text-gray-900 dark:text-white">{r.preventista_nombre}</td>
                  <td className="px-4 py-2 text-gray-700 dark:text-gray-300 tabular-nums">{r.hora}</td>
                  <td className="px-4 py-2 text-gray-900 dark:text-white">{r.cliente_nombre}</td>
                  <td className="px-4 py-2">
                    <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full ${cfg.bg}`}>
                      {r.motivo === 'sin_gps' ? <ZapOff className="w-3 h-3" /> : <AlertTriangle className="w-3 h-3" />}
                      {r.motivo_label}
                    </span>
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums text-gray-700 dark:text-gray-300">
                    {r.motivo === 'sin_gps' ? '—' : formatDistancia(r.distancia_m)}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums text-gray-700 dark:text-gray-300">
                    {formatPrecio(r.total)}
                  </td>
                  <td className="px-4 py-2 text-right">
                    <button
                      type="button"
                      onClick={() => onSelectPedido(r.pedido_id, r.preventista_id)}
                      className="inline-flex items-center gap-1 text-xs text-blue-600 dark:text-blue-400 hover:underline"
                      title="Ver en el mapa"
                    >
                      <Search className="w-3 h-3" />
                      Ver
                    </button>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}
