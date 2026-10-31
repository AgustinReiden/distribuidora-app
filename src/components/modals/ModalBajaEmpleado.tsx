/**
 * ModalBajaEmpleado — dar de baja a un empleado en una fecha (entrega 3 de gastos).
 *
 * La baja no borra nada: la cuenta y el historial quedan y se puede reactivar. Si tiene saldo,
 * el modal lo avisa (queda en su cuenta). Que la fecha sea válida para el empleado (por ejemplo,
 * que no sea anterior a su último arreglo) lo valida el server (`dar_de_baja_empleado`).
 */
import React, { useId, useState } from 'react'
import type { FormEvent } from 'react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { getErrorMessage } from '../../utils/errorHandling'
import { formatPrecio } from '../../utils/formatters'
import { estadoSaldo, fechaCompleta } from '../../utils/personal'
import type { Empleado } from '../../types/personal'

export interface ModalBajaEmpleadoProps {
  empleado: Empleado
  hoy: string
  onConfirmar: (fecha: string) => Promise<void>
  onClose: () => void
}

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white'
const CLASE_ETIQUETA = 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'

export default function ModalBajaEmpleado({
  empleado, hoy, onConfirmar, onClose,
}: ModalBajaEmpleadoProps): React.ReactElement {
  const id = useId()
  const [fecha, setFecha] = useState(hoy)
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const estado = estadoSaldo(empleado.saldo)
  // La baja no puede ser anterior al arranque; con un arranque a futuro sólo se puede dar de baja
  // desde hoy (no hay fecha futura que valga).
  const minimo = empleado.arranque ? (empleado.arranque < hoy ? empleado.arranque : hoy) : null

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) {
      setError('Elegí la fecha de baja')
      return
    }
    if (fecha > hoy) {
      setError('La fecha de baja no puede ser futura')
      return
    }
    if (minimo && fecha < minimo) {
      setError(`La baja no puede ser anterior al arranque (${fechaCompleta(minimo)})`)
      return
    }
    setGuardando(true)
    try {
      await onConfirmar(fecha)
      onClose()
    } catch (err) {
      // getErrorMessage, no `err instanceof Error`: el error de supabase-js es un objeto plano.
      setError(getErrorMessage(err))
    } finally {
      setGuardando(false)
    }
  }

  return (
    <ModalBase title={`Dar de baja a ${empleado.nombre}`} onClose={onClose} maxWidth="max-w-md">
      <form onSubmit={handleSubmit} className="p-4 space-y-4">
        <div>
          <label htmlFor={`${id}-fecha`} className={CLASE_ETIQUETA}>
            Fecha de baja <span className="text-red-500">*</span>
          </label>
          <input
            id={`${id}-fecha`}
            type="date"
            value={fecha}
            min={minimo ?? undefined}
            max={hoy}
            onChange={ev => setFecha(ev.target.value)}
            className={CLASE_INPUT}
          />
        </div>

        <p className="text-sm text-gray-600 dark:text-gray-300">Su cuenta y su historial quedan. Se puede reactivar.</p>

        {estado !== 'al_dia' && (
          <div className="p-3 rounded-lg border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-900/20">
            <p className="text-sm text-amber-800 dark:text-amber-300">
              {`Tiene un saldo de ${formatPrecio(Math.abs(empleado.saldo))} ${estado === 'a_favor' ? 'a su favor' : 'en contra'}: queda en su cuenta.`}
            </p>
          </div>
        )}

        {error && (
          <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          </div>
        )}

        <div className="flex gap-3 pt-2">
          <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" variant="danger" size="md" loading={guardando} disabled={guardando} className="flex-1">
            Dar de baja
          </Button>
        </div>
      </form>
    </ModalBase>
  )
}
