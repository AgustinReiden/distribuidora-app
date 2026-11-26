import { Button } from '../ui/Button'
import { FORMAS_PAGO } from '../../constants/formasPago'
import type { FiltroMasivo } from '../../utils/filtroMasivas'

interface Props {
  filtro: FiltroMasivo
  onChange: (f: FiltroMasivo) => void
  /** Pagos masivos y entrega con pago: se puede filtrar por forma de pago. */
  conFormaPago?: boolean
}

// Las que un pedido puede traer como forma de pago prevista: las que se eligen, más cuenta corriente.
const OPCIONES_FORMA_PAGO = FORMAS_PAGO.filter(m => m.seleccionable || m.value === 'cuenta_corriente')

const campo = 'w-full px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white'
const etiqueta = 'block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1'

/** Filtro de fecha (entrega o pedido, como «Armar ruta») y, si corresponde, de forma de pago. */
export default function FiltrosMasivos({ filtro, onChange, conFormaPago = false }: Props) {
  const set = (parcial: Partial<FiltroMasivo>) => onChange({ ...filtro, ...parcial })
  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2 flex-wrap">
        <span className="text-xs font-medium text-gray-500 dark:text-gray-400">Filtrar por</span>
        <div role="group" aria-label="Fecha a filtrar" className="inline-flex rounded-lg border dark:border-gray-600 p-0.5">
          {(['entrega', 'pedido'] as const).map(t => (
            <Button
              key={t}
              type="button"
              size="sm"
              variant={filtro.tipoFecha === t ? 'primary' : 'ghost'}
              aria-pressed={filtro.tipoFecha === t}
              onClick={() => set({ tipoFecha: t })}
            >
              {t === 'entrega' ? 'Fecha de entrega' : 'Fecha del pedido'}
            </Button>
          ))}
        </div>
      </div>
      <div className={`grid gap-3 ${conFormaPago ? 'grid-cols-1 sm:grid-cols-3' : 'grid-cols-2'}`}>
        <div>
          <label htmlFor="filtro-masivo-desde" className={etiqueta}>Desde</label>
          <input id="filtro-masivo-desde" type="date" value={filtro.desde} onChange={e => set({ desde: e.target.value })} className={campo} />
        </div>
        <div>
          <label htmlFor="filtro-masivo-hasta" className={etiqueta}>Hasta</label>
          <input id="filtro-masivo-hasta" type="date" value={filtro.hasta} onChange={e => set({ hasta: e.target.value })} className={campo} />
        </div>
        {conFormaPago && (
          <div>
            <label htmlFor="filtro-masivo-forma-pago" className={etiqueta}>Forma de pago del pedido</label>
            <select id="filtro-masivo-forma-pago" value={filtro.formaPago} onChange={e => set({ formaPago: e.target.value })} className={campo}>
              <option value="">Todas</option>
              {OPCIONES_FORMA_PAGO.map(fp => (
                <option key={fp.value} value={fp.value}>{fp.label}</option>
              ))}
            </select>
          </div>
        )}
      </div>
    </div>
  )
}
