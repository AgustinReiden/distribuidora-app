/**
 * El semáforo de un lote, en una etiqueta.
 *
 * Vive aparte porque lo usan dos pantallas que no se conocen entre sí: el
 * bloque de la ficha del producto y el panel de vencimientos. Si el color de
 * "crítico" cambia, tiene que cambiar en los dos lugares a la vez.
 *
 * El estado se calcula con `estadoVencimiento` (src/utils/vencimientos.ts), que
 * es donde vive la regla. Acá solo se elige cómo se pinta.
 */
import { AlertTriangle, Clock, XCircle } from 'lucide-react'
import { estadoVencimiento, textoVencimiento } from '../../utils/vencimientos'
import type { EstadoVencimiento } from '../../utils/vencimientos'

const ESTILOS: Record<EstadoVencimiento, { clase: string; Icono: typeof Clock | null }> = {
  vencido: {
    clase: 'bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-200',
    Icono: XCircle,
  },
  critico: {
    clase: 'bg-orange-100 text-orange-800 dark:bg-orange-900/40 dark:text-orange-200',
    Icono: AlertTriangle,
  },
  alerta: {
    clase: 'bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200',
    Icono: Clock,
  },
  ok: {
    clase: 'bg-stone-100 text-stone-600 dark:bg-gray-700 dark:text-gray-300',
    Icono: null,
  },
}

export interface BadgeVencimientoProps {
  /** 'YYYY-MM-DD', tal cual viene de la base. */
  fecha: string
  diasAlerta: number
  diasCritico: number
  /** Para tests: fija el "hoy" en vez de leer el reloj. */
  hoy?: string
}

export default function BadgeVencimiento({ fecha, diasAlerta, diasCritico, hoy }: BadgeVencimientoProps) {
  const estado = estadoVencimiento(fecha, diasAlerta, diasCritico, hoy)
  const { clase, Icono } = ESTILOS[estado]

  return (
    <span
      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium whitespace-nowrap ${clase}`}
    >
      {Icono && <Icono className="w-3 h-3" aria-hidden="true" />}
      {textoVencimiento(fecha, hoy)}
    </span>
  )
}
