/**
 * SelectorPlata — "Con qué plata se paga" un pago al personal (entrega 4 de gastos).
 *
 * La oficina, o el efectivo de una rendición (transportista y día). Lo usan `ModalLiquidar` y
 * `ModalMovimientoEmpleado` (el pago suelto). El día de la rendición reemplaza a la fecha del
 * pago: el server toma ese día. El encargado y el chofer ven de esa rendición sólo un total, sin
 * el nombre del empleado.
 */
import React, { useId } from 'react'
import { Building2, Truck } from 'lucide-react'
import { Combobox } from '../ui/Combobox'
import { cn } from '../../lib/utils'
import { PLATA_OFICINA } from '../../utils/personal'
import type { PlataDelPago } from '../../types/personal'

export interface SelectorPlataProps {
  valor: PlataDelPago
  onChange: (v: PlataDelPago) => void
  transportistas: Array<{ id: string; nombre: string }>
  hoy: string
}

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white'

function Pastilla({
  activa, onClick, icono, children,
}: { activa: boolean; onClick: () => void; icono: React.ReactNode; children: React.ReactNode }) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      onClick={onClick}
      className={cn(
        'flex items-center gap-2 p-2 border rounded-lg text-sm text-left transition-colors',
        activa
          ? 'border-brand-500 bg-brand-50 dark:bg-brand-900/20 text-brand-700 dark:text-brand-300 font-medium'
          : 'border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300',
      )}
    >
      {icono}
      {children}
    </button>
  )
}

export default function SelectorPlata({
  valor, onChange, transportistas, hoy,
}: SelectorPlataProps): React.ReactElement {
  const id = useId()
  const conRendicion = valor.origen_pago === 'rendicion'

  return (
    <div>
      <span id={`${id}-plata`} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
        Con qué plata se paga
      </span>
      <div role="group" aria-labelledby={`${id}-plata`} className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        <Pastilla
          activa={!conRendicion}
          onClick={() => onChange(PLATA_OFICINA)}
          icono={<Building2 className="w-4 h-4" aria-hidden="true" />}
        >
          La pagó la oficina
        </Pastilla>
        <Pastilla
          activa={conRendicion}
          onClick={() => {
            if (!conRendicion) {
              onChange({ origen_pago: 'rendicion', rendicion_transportista_id: null, rendicion_fecha: hoy })
            }
          }}
          icono={<Truck className="w-4 h-4" aria-hidden="true" />}
        >
          Con la plata de una rendición
        </Pastilla>
      </div>

      {conRendicion && (
        <>
          <div className="mt-2 grid grid-cols-1 sm:grid-cols-2 gap-2">
            <div>
              <Combobox
                aria-label="Transportista"
                opciones={transportistas}
                getKey={t => t.id}
                getLabel={t => t.nombre}
                valor={valor.rendicion_transportista_id}
                onSeleccionar={t => onChange({ ...valor, rendicion_transportista_id: t.id })}
                placeholder="Transportista"
                textoSinResultados="No hay transportistas"
              />
            </div>
            <div>
              <input
                type="date"
                aria-label="Día de la rendición"
                value={valor.rendicion_fecha ?? ''}
                max={hoy}
                onChange={ev => onChange({ ...valor, rendicion_fecha: ev.target.value || null })}
                className={CLASE_INPUT}
              />
            </div>
          </div>
          <p className="mt-1 text-xs text-gray-500">
            Se descuenta del efectivo a entregar de esa rendición. El encargado y el chofer ven sólo el total pagado al personal.
          </p>
        </>
      )}
    </div>
  )
}
