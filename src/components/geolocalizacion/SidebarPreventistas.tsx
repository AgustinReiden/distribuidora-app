import React, { useMemo } from 'react'
import { MapPin, ShoppingCart, AlertTriangle } from 'lucide-react'
import { colorPreventista } from '../../utils/geo'
import { formatHora } from '../../utils/formatters'
import type { PreventistaResumen } from '../../hooks/queries'

interface SidebarPreventistasProps {
  preventistas: PreventistaResumen[]
  selectedId: string | null
  onSelect: (id: string | null) => void
}

export default function SidebarPreventistas({ preventistas, selectedId, onSelect }: SidebarPreventistasProps): React.ReactElement {
  const ordenadas = useMemo(() => {
    return [...preventistas].sort((a, b) => {
      const ta = a.ultima_ubicacion?.capturado_at ? Date.parse(a.ultima_ubicacion.capturado_at) : 0
      const tb = b.ultima_ubicacion?.capturado_at ? Date.parse(b.ultima_ubicacion.capturado_at) : 0
      return tb - ta
    })
  }, [preventistas])

  if (ordenadas.length === 0) {
    return (
      <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-6 text-center text-sm text-gray-500 dark:text-gray-400">
        Sin preventistas con pedidos en el rango seleccionado.
      </div>
    )
  }

  return (
    <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
      <div className="px-4 py-3 border-b border-gray-200 dark:border-gray-700 flex items-center justify-between">
        <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200">
          Preventistas <span className="text-gray-400 font-normal">({ordenadas.length})</span>
        </h3>
        {selectedId && (
          <button
            type="button"
            onClick={() => onSelect(null)}
            className="text-xs text-blue-600 dark:text-blue-400 hover:underline"
          >
            Ver todos
          </button>
        )}
      </div>
      <ul className="divide-y divide-gray-100 dark:divide-gray-700 max-h-[60vh] overflow-y-auto">
        {ordenadas.map(p => {
          const color = colorPreventista(p.preventista_id)
          const isSelected = selectedId === p.preventista_id
          const inicial = (p.preventista_nombre || '?').trim().charAt(0).toUpperCase()
          return (
            <li key={p.preventista_id}>
              <button
                type="button"
                onClick={() => onSelect(isSelected ? null : p.preventista_id)}
                className={`w-full text-left px-4 py-3 transition-colors flex items-center gap-3 ${
                  isSelected
                    ? 'bg-blue-50 dark:bg-blue-900/20'
                    : 'hover:bg-gray-50 dark:hover:bg-gray-700/50'
                }`}
                aria-pressed={isSelected}
              >
                <span
                  className="shrink-0 w-9 h-9 rounded-full flex items-center justify-center text-white font-semibold text-sm"
                  style={{ backgroundColor: color }}
                  aria-hidden
                >
                  {inicial}
                </span>
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-gray-900 dark:text-white truncate">
                    {p.preventista_nombre || 'Sin nombre'}
                  </p>
                  <div className="mt-0.5 flex items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
                    <span className="inline-flex items-center gap-1" title="Hora del último check-in">
                      <MapPin className="w-3 h-3" />
                      {formatHora(p.ultima_ubicacion?.capturado_at)}
                    </span>
                    <span className="inline-flex items-center gap-1" title="Pedidos del día">
                      <ShoppingCart className="w-3 h-3" />
                      {p.total_pedidos}
                    </span>
                    {p.pedidos_lejos > 0 && (
                      <span className="inline-flex items-center gap-1 text-red-600 dark:text-red-400" title="Pedidos lejos del cliente">
                        <AlertTriangle className="w-3 h-3" />
                        {p.pedidos_lejos}
                      </span>
                    )}
                  </div>
                </div>
              </button>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
