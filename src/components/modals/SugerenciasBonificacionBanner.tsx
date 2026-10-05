/**
 * #908. Aviso en "Cargos y prorrateo" de la compra: una promo del proveedor
 * aplicaba y la factura no la descontó. Ofrece el cargo "Bonificación" con su
 * monto y su alcance, para aceptarlo o descartarlo. Nunca se aplica solo.
 */
import { AlertTriangle } from 'lucide-react'
import { Button } from '../ui/Button'
import { formatPrecio } from '../../utils/formatters'
import type { SugerenciaBonificacion } from '../../utils/sugerenciasBonificacion'

interface Props {
  sugerencias: SugerenciaBonificacion[]
  onAplicar: (s: SugerenciaBonificacion) => void
  onDescartar: (s: SugerenciaBonificacion) => void
}

export default function SugerenciasBonificacionBanner({ sugerencias, onAplicar, onDescartar }: Props) {
  if (sugerencias.length === 0) return null
  return (
    <div role="status" aria-label="Bonificaciones sugeridas" className="mt-3 space-y-2">
      {sugerencias.map(s => {
        const n = s.lineasAlcance.length
        return (
          <div
            key={s.promoId}
            className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm dark:border-amber-700 dark:bg-amber-900/20"
          >
            <div className="flex items-start gap-2">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-700 dark:text-amber-400" aria-hidden="true" />
              <div className="min-w-0 flex-1">
                <p className="font-medium text-gray-900 dark:text-amber-100">
                  {s.nombre}: el proveedor no descontó {formatPrecio(Math.abs(s.monto))} en {n} {n === 1 ? 'línea' : 'líneas'}
                </p>
                <p className="mt-0.5 text-xs text-gray-700 dark:text-amber-200/80">
                  {s.explicacion}. Se agrega como bonificación sólo sobre esas líneas.
                </p>
              </div>
            </div>
            <div className="mt-2 flex flex-wrap justify-end gap-2">
              <Button type="button" variant="ghost" size="sm" onClick={() => onDescartar(s)}>
                Descartar
              </Button>
              <Button type="button" variant="success" size="sm" onClick={() => onAplicar(s)}>
                Aplicar
              </Button>
            </div>
          </div>
        )
      })}
    </div>
  )
}
