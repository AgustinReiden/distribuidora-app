import React from 'react'
import type { LucideIcon } from 'lucide-react'

interface KpiCardProps {
  label: string
  value: number | string
  icon: LucideIcon
  /** Tono del icono y barrita superior. Default: blue. */
  tone?: 'blue' | 'green' | 'amber' | 'red' | 'slate'
  hint?: string
}

const TONES: Record<NonNullable<KpiCardProps['tone']>, { bg: string; icon: string; bar: string }> = {
  blue:  { bg: 'bg-blue-50 dark:bg-blue-900/20',   icon: 'text-blue-600 dark:text-blue-400',   bar: 'bg-blue-500' },
  green: { bg: 'bg-green-50 dark:bg-green-900/20', icon: 'text-green-600 dark:text-green-400', bar: 'bg-green-500' },
  amber: { bg: 'bg-amber-50 dark:bg-amber-900/20', icon: 'text-amber-600 dark:text-amber-400', bar: 'bg-amber-500' },
  red:   { bg: 'bg-red-50 dark:bg-red-900/20',     icon: 'text-red-600 dark:text-red-400',     bar: 'bg-red-500' },
  slate: { bg: 'bg-slate-50 dark:bg-slate-800/40', icon: 'text-slate-600 dark:text-slate-300', bar: 'bg-slate-400' },
}

export default function KpiCard({ label, value, icon: Icon, tone = 'blue', hint }: KpiCardProps): React.ReactElement {
  const t = TONES[tone]
  return (
    <div className="relative overflow-hidden rounded-xl bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 shadow-sm hover:shadow-md transition-shadow p-4">
      <div className={`absolute top-0 left-0 right-0 h-0.5 ${t.bar}`} aria-hidden />
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-xs font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400 truncate">{label}</p>
          <p className="mt-1 text-2xl font-semibold text-gray-900 dark:text-white tabular-nums">{value}</p>
          {hint && <p className="mt-1 text-xs text-gray-400 dark:text-gray-500 truncate">{hint}</p>}
        </div>
        <div className={`shrink-0 rounded-lg p-2 ${t.bg}`}>
          <Icon className={`w-5 h-5 ${t.icon}`} aria-hidden />
        </div>
      </div>
    </div>
  )
}
