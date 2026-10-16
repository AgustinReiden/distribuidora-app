/**
 * La sugerencia de combos en el carrito (#1194): una línea por combo al que
 * le falta poco, con un toque que agrega lo que falta y otro que la descarta
 * para este pedido. La cuenta es `sugerirCombos` (src/utils/comboSugerencia.ts).
 */
import { Layers, Plus, X } from 'lucide-react'
import { Button } from '../ui/Button'
import { formatPrecio } from '../../utils/formatters'
import type { SugerenciaCombo } from '../../utils/comboSugerencia'

export interface SugerenciasComboProps {
  sugerencias: readonly SugerenciaCombo[] | undefined
  nombreDe: (productoId: string) => string
  onAgregar: (sugerencia: SugerenciaCombo) => void
  onDescartar: (comboId: string) => void
}

function textoAgregar(s: SugerenciaCombo, nombreDe: (productoId: string) => string): string {
  return s.agregar.map(a => `${a.cantidad} ${nombreDe(a.productoId)}`).join(' y ')
}

export default function SugerenciasCombo({ sugerencias, nombreDe, onAgregar, onDescartar }: SugerenciasComboProps) {
  if (!sugerencias || sugerencias.length === 0) return null
  return (
    <div className="mt-2 space-y-1" aria-live="polite">
      {sugerencias.map(s => (
        <div
          key={s.comboId}
          data-testid={`sugerencia-combo-${s.comboId}`}
          className="flex items-center gap-2 text-xs text-indigo-700 bg-indigo-50 dark:bg-indigo-900/20 dark:text-indigo-300 px-3 py-1.5 rounded-lg"
        >
          <Layers className="w-3 h-3 shrink-0" aria-hidden="true" />
          <span className="flex-1 min-w-0">
            Sumá {textoAgregar(s, nombreDe)} y armá el combo <strong>{s.nombre}</strong>: el cliente ahorra{' '}
            <strong>{formatPrecio(s.ahorro)}</strong>
          </span>
          <Button
            type="button"
            variant="primary"
            size="sm"
            onClick={() => onAgregar(s)}
            className="shrink-0 h-7 px-2 text-xs"
            aria-label={`Agregar ${textoAgregar(s, nombreDe)} para el combo ${s.nombre}`}
          >
            <Plus className="w-3 h-3" aria-hidden="true" />
            Agregar
          </Button>
          <Button
            type="button"
            variant="ghost"
            size="iconSm"
            onClick={() => onDescartar(s.comboId)}
            className="shrink-0 h-7 w-7"
            aria-label={`Descartar la sugerencia del combo ${s.nombre}`}
            title="No sugerir este combo en este pedido"
          >
            <X className="w-3 h-3" aria-hidden="true" />
          </Button>
        </div>
      ))}
    </div>
  )
}
