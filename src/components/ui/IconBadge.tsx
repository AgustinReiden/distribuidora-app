/**
 * IconBadge — el circulito de color con un icono adentro que hoy dibujan a mano
 * los KPIs de PedidoStats y ClienteStats.
 *
 * Accesibilidad: por defecto es decorativo (`aria-hidden`), porque al lado
 * siempre hay una etiqueta de texto que ya dice lo mismo. Si el badge va SOLO
 * (sin texto que lo acompañe), se le pasa `label` y pasa a ser `role="img"` con
 * nombre accesible.
 *
 * El icono hereda el color del contenedor (`currentColor`), asi que el tono
 * pinta las dos cosas con un solo par de clases.
 */
import type { LucideIcon } from 'lucide-react'
import type { ReactElement } from 'react'
import { cn } from '../../lib/utils'

export type IconBadgeTone = 'brand' | 'success' | 'warning' | 'danger' | 'neutral'
export type IconBadgeSize = 'sm' | 'md' | 'lg'

export interface IconBadgeProps {
  icon: LucideIcon
  tone: IconBadgeTone
  size: IconBadgeSize
  /** Si viene, el badge deja de ser decorativo: `role="img"` + `aria-label`. */
  label?: string
  className?: string
}

// Cada clase se escribe COMPLETA: Tailwind no genera clases interpoladas
// (`bg-${tono}-100` no existe en el CSS final).
const TONOS: Record<IconBadgeTone, string> = {
  brand: 'bg-brand-100 text-brand-700 dark:bg-brand-900/40 dark:text-brand-300',
  success: 'bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300',
  warning: 'bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300',
  danger: 'bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300',
  neutral: 'bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300',
}

// 28 / 34 / 44 px de caja, radio 8 / 10 / 12. El 34 y su radio no caen en
// ningun escalon de Tailwind, por eso van entre corchetes.
const TAMANOS: Record<IconBadgeSize, { caja: string; icono: string }> = {
  sm: { caja: 'w-7 h-7 rounded-lg', icono: 'w-3.5 h-3.5' },
  md: { caja: 'w-[34px] h-[34px] rounded-[10px]', icono: 'w-4 h-4' },
  lg: { caja: 'w-11 h-11 rounded-xl', icono: 'w-5 h-5' },
}

export function IconBadge({
  icon: Icon,
  tone,
  size,
  label,
  className,
}: IconBadgeProps): ReactElement {
  const tamano = TAMANOS[size]

  return (
    <span
      className={cn(
        'inline-flex items-center justify-center flex-shrink-0',
        tamano.caja,
        TONOS[tone],
        className
      )}
      role={label ? 'img' : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      <Icon className={tamano.icono} aria-hidden="true" />
    </span>
  )
}
