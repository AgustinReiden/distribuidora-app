/**
 * ModalMovimientoEmpleado — un movimiento manual en la cuenta del empleado (entrega 3 de gastos).
 *
 * Hay dos: el adelanto en efectivo (plata que sale de la oficina a cuenta del sueldo) y el
 * ajuste (a favor o en contra, siempre con su porqué). La mercadería, el reintegro y las
 * roturas entran solos desde su origen, no por acá. El adelanto viaja positivo (el server lo
 * guarda negativo); el ajuste, con su signo. Las reglas las repite `errorDeMovimiento` con los
 * mismos mensajes que el server.
 */
import React, { useId, useState } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { z } from 'zod'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { cn } from '../../lib/utils'
import { getErrorMessage } from '../../utils/errorHandling'
import { MENSAJE_MONTO_ILEGIBLE, errorDeMovimiento, parseMonto } from '../../utils/personal'
import type { Empleado, MovimientoManualPayload } from '../../types/personal'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// eslint-disable-next-line react-refresh/only-export-components
export const modalMovimientoSchema = z
  .object({
    tipo: z.enum(['adelanto', 'ajuste'], { error: 'Elegí el tipo de movimiento' }),
    monto: z.number({ error: 'El monto tiene que ser mayor a cero' }),
    fecha: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, { message: 'Elegí la fecha del movimiento' }),
    observacion: z.string().nullable(),
  })
  .superRefine((m, ctx) => {
    // Hoy no está en el schema: lo valida `onSubmit`, que lo conoce. Acá van las reglas de monto.
    const error = errorDeMovimiento(m, '9999-12-31')
    if (error) ctx.addIssue({ code: 'custom', message: error, path: ['monto'] })
  })

export interface ModalMovimientoEmpleadoProps {
  empleado: Pick<Empleado, 'id' | 'nombre'>
  hoy: string
  onSave: (m: MovimientoManualPayload) => Promise<void>
  onClose: () => void
}

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white'
const CLASE_ETIQUETA = 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'
const CLASE_AYUDA = 'mt-1 text-xs text-gray-500'

const requerido = <span className="text-red-500">*</span>

function Pastilla({
  activa, onClick, children,
}: { activa: boolean; onClick: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      aria-pressed={activa}
      onClick={onClick}
      className={cn(
        'p-2 border rounded-lg text-sm transition-colors',
        activa
          ? 'border-brand-500 bg-brand-50 dark:bg-brand-900/20 text-brand-700 dark:text-brand-300 font-medium'
          : 'border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300',
      )}
    >
      {children}
    </button>
  )
}

export default function ModalMovimientoEmpleado({
  empleado, hoy, onSave, onClose,
}: ModalMovimientoEmpleadoProps): React.ReactElement {
  const id = useId()
  const [tipo, setTipo] = useState<'adelanto' | 'ajuste'>('adelanto')
  const [signo, setSigno] = useState<'favor' | 'contra'>('favor')
  const [montoTxt, setMontoTxt] = useState('')
  const [fecha, setFecha] = useState(hoy)
  const [observacion, setObservacion] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')

    // En blanco queda en 0 y lo frena "tiene que ser mayor a cero"; lo que no se entiende se avisa.
    const tipeado = montoTxt.trim() ? parseMonto(montoTxt) : 0
    if (tipeado === null) {
      setError(MENSAJE_MONTO_ILEGIBLE)
      return
    }
    // El ajuste se tipea sin signo: lo da la pastilla. El adelanto viaja tal cual, y un negativo
    // lo frena `errorDeMovimiento`.
    const monto = tipo === 'ajuste'
      ? (signo === 'contra' ? -Math.abs(tipeado) : Math.abs(tipeado))
      : tipeado
    const payload: MovimientoManualPayload = {
      tipo,
      monto,
      fecha,
      observacion: observacion.trim() ? observacion.trim() : null,
    }

    const resultado = modalMovimientoSchema.safeParse(payload)
    if (!resultado.success) {
      setError(resultado.error.issues[0]?.message ?? 'Revisá los datos del movimiento')
      return
    }
    const errorFecha = errorDeMovimiento(resultado.data, hoy)
    if (errorFecha) {
      setError(errorFecha)
      return
    }

    setGuardando(true)
    try {
      await onSave(resultado.data)
      onClose()
    } catch (err) {
      // getErrorMessage, no `err instanceof Error`: el error de supabase-js es un objeto plano.
      setError(getErrorMessage(err))
    } finally {
      setGuardando(false)
    }
  }

  const esAjuste = tipo === 'ajuste'

  return (
    <ModalBase title="Nuevo movimiento" description={empleado.nombre} onClose={onClose} maxWidth="max-w-md">
      <form onSubmit={handleSubmit} className="p-4 space-y-4">
        <div>
          <span id={`${id}-tipo`} className={CLASE_ETIQUETA}>Tipo</span>
          <div role="group" aria-labelledby={`${id}-tipo`} className="grid grid-cols-2 gap-2">
            <Pastilla activa={tipo === 'adelanto'} onClick={() => setTipo('adelanto')}>Adelanto en efectivo</Pastilla>
            <Pastilla activa={esAjuste} onClick={() => setTipo('ajuste')}>Ajuste</Pastilla>
          </div>
          <p className={CLASE_AYUDA}>
            {esAjuste
              ? 'A su favor suma a lo que la empresa le debe; en contra, a lo que él le debe a la empresa.'
              : 'Plata que se le da a cuenta del sueldo. Sale de la oficina y se descuenta al liquidar.'}
          </p>
        </div>

        {esAjuste && (
          <div role="group" aria-label="Signo del ajuste" className="grid grid-cols-2 gap-2">
            <Pastilla activa={signo === 'favor'} onClick={() => setSigno('favor')}>A su favor</Pastilla>
            <Pastilla activa={signo === 'contra'} onClick={() => setSigno('contra')}>En contra</Pastilla>
          </div>
        )}

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div>
            <label htmlFor={`${id}-monto`} className={CLASE_ETIQUETA}>Monto {requerido}</label>
            <div className="relative">
              <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
              <input
                id={`${id}-monto`}
                type="text"
                inputMode="decimal"
                autoComplete="off"
                value={montoTxt}
                onChange={ev => setMontoTxt(ev.target.value)}
                placeholder="0,00"
                className={cn(CLASE_INPUT, 'pl-7 text-right')}
              />
            </div>
          </div>
          <div>
            <label htmlFor={`${id}-fecha`} className={CLASE_ETIQUETA}>Fecha {requerido}</label>
            <input
              id={`${id}-fecha`}
              type="date"
              value={fecha}
              max={hoy}
              onChange={ev => setFecha(ev.target.value)}
              className={CLASE_INPUT}
            />
          </div>
        </div>

        <div>
          <label htmlFor={`${id}-obs`} className={CLASE_ETIQUETA}>
            {esAjuste ? <>Por qué {requerido}</> : 'Observación'}
          </label>
          <input
            id={`${id}-obs`}
            type="text"
            autoComplete="off"
            value={observacion}
            onChange={ev => setObservacion(ev.target.value)}
            className={CLASE_INPUT}
          />
        </div>

        {error && (
          <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          </div>
        )}

        <div className="flex gap-3 pt-2">
          <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" variant="primary" size="md" loading={guardando} disabled={guardando} className="flex-1">
            Registrar movimiento
          </Button>
        </div>
      </form>
    </ModalBase>
  )
}
