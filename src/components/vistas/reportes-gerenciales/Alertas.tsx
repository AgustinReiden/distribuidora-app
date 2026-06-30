import React from 'react'
import { AlertCircle, AlertTriangle, Info } from 'lucide-react'
import type { Alerta } from '../../../hooks/queries'

const STYLE: Record<Alerta['severidad'], { icon: React.ElementType; cls: string }> = {
  critical: { icon: AlertCircle, cls: 'border-red-200 dark:border-red-900 bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-300' },
  warning: { icon: AlertTriangle, cls: 'border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-900/20 text-amber-800 dark:text-amber-300' },
  info: { icon: Info, cls: 'border-blue-200 dark:border-blue-900 bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300' },
}

/** Panel "Qué requiere tu atención". Cada alerta es clickeable → drill a su sección. */
export default function Alertas({ items, onSelect }: { items: Alerta[]; onSelect?: (alerta: Alerta) => void }): React.ReactElement | null {
  if (!items?.length) return null
  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-xl shadow-sm p-4">
      <div className="text-[11px] font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400 mb-2">
        Qué requiere tu atención
      </div>
      <div className="grid sm:grid-cols-2 gap-2">
        {items.map((a) => {
          const s = STYLE[a.severidad] ?? STYLE.info
          const Icon = s.icon
          return (
            <button
              key={a.codigo}
              type="button"
              onClick={() => onSelect?.(a)}
              className={`flex items-start gap-2 text-left border rounded-lg px-3 py-2 transition hover:brightness-95 ${s.cls}`}
            >
              <Icon className="w-4 h-4 mt-0.5 shrink-0" />
              <span className="text-sm leading-snug"><b>{a.titulo}.</b> {a.detalle}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}
