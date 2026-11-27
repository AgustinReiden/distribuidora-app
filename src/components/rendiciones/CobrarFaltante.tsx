/**
 * T4 (#1710, D8) · «Lo pagó el cliente»: el chofer marcó $ 10.000 cobrados, rindió $ 5.000 y se le
 * cargó un faltante de $ 5.000; si después el cliente paga esos $ 5.000 en la oficina, ese pago
 * descuenta el faltante del chofer. No es otro cobro de la boleta (ya figura cobrada) ni entra en
 * la rendición del chofer: en efectivo, entra en la caja de quien lo recibió ese día. Sólo el admin
 * (maneja el personal).
 */
import React, { useState } from 'react'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { RegistroPropio } from '../ui/RegistroPropio'
import { FORMAS_PAGO_SELECCIONABLES } from '../../constants/formasPago'
import { formatPrecio } from '../../utils/formatters'
import { cobrarFaltanteRendicion } from '../../hooks/supabase/cobrosRendicion'
import CampoQuienCobro, { type PersonaQueCobra } from './CampoQuienCobro'

export interface CobrarFaltanteProps {
  faltanteId: number
  /** Lo que queda del faltante (`pendienteDelFaltante`). */
  pendiente: number
  personas: PersonaQueCobra[]
  yoId?: string | null
  onHecho: () => void
  onCancelar: () => void
}

function nuevaClave(): string {
  return typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random()}`
}

export default function CobrarFaltante({
  faltanteId, pendiente, personas, yoId, onHecho, onCancelar,
}: CobrarFaltanteProps): React.ReactElement {
  const [monto, setMonto] = useState<number | null>(pendiente)
  const [forma, setForma] = useState('efectivo')
  const [cobradoPor, setCobradoPor] = useState<string | null>(null)
  const [observacion, setObservacion] = useState('')
  const [error, setError] = useState('')
  const [guardando, setGuardando] = useState(false)
  // Una clave por intento: un reintento tras un corte no lo carga dos veces.
  const [clave] = useState(nuevaClave)

  const guardar = async (): Promise<void> => {
    if (monto == null || monto <= 0 || monto > pendiente || guardando) return
    setError('')
    setGuardando(true)
    try {
      await cobrarFaltanteRendicion({ faltanteId, monto, formaPago: forma, cobradoPor, observacion, clave })
      onHecho()
    } catch (e) {
      setError((e as Error).message || 'No se pudo cargar lo que pagó el cliente')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <RegistroPropio>
      {({ hay, aviso }) => (
        <div className="mt-1 p-2 rounded border border-gray-200 dark:border-gray-700 space-y-2">
          <p className="text-xs text-gray-600 dark:text-gray-300">
            Descuenta el faltante (quedan {formatPrecio(pendiente)}). En efectivo entra en la caja de quien lo recibió hoy.
          </p>
          <div>
            <label htmlFor={`monto-falt-${faltanteId}`} className="block text-xs font-medium mb-1 dark:text-gray-200">Monto</label>
            <NumberInput
              id={`monto-falt-${faltanteId}`}
              value={monto}
              onChange={setMonto}
              min={0.01}
              max={pendiente}
              motivoMax={`Quedan ${formatPrecio(pendiente)} del faltante`}
              motivoVacio="Poné cuánto pagó el cliente"
            />
          </div>
          <div>
            <label htmlFor={`forma-falt-${faltanteId}`} className="block text-xs font-medium mb-1 dark:text-gray-200">Forma de pago</label>
            <select
              id={`forma-falt-${faltanteId}`}
              value={forma}
              onChange={e => setForma(e.target.value)}
              className="w-full px-2 py-1 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            >
              {FORMAS_PAGO_SELECCIONABLES.map(f => (
                <option key={f.value} value={f.value}>{f.label}</option>
              ))}
            </select>
          </div>
          {forma === 'efectivo' && (
            <CampoQuienCobro
              id={`quien-falt-${faltanteId}`}
              personas={personas}
              value={cobradoPor}
              yoId={yoId}
              onChange={setCobradoPor}
              ayuda="El efectivo entra en la rendición de hoy de quien lo recibió."
            />
          )}
          <div>
            <label htmlFor={`obs-falt-${faltanteId}`} className="block text-xs font-medium mb-1 dark:text-gray-200">Observación</label>
            <input
              id={`obs-falt-${faltanteId}`}
              value={observacion}
              onChange={e => setObservacion(e.target.value)}
              className="w-full px-2 py-1 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
          </div>
          {error && <p role="alert" className="text-xs text-red-600">{error}</p>}
          {aviso}
          <div className="flex gap-2">
            <Button size="sm" variant="primary" disabled={hay || guardando || monto == null || monto <= 0}
                    onClick={() => { if (!hay) void guardar() }}>
              {guardando ? 'Guardando…' : 'Cargar lo que pagó'}
            </Button>
            <Button size="sm" variant="secondary" onClick={onCancelar}>Cancelar</Button>
          </div>
        </div>
      )}
    </RegistroPropio>
  )
}
