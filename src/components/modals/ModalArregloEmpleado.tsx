/**
 * ModalArregloEmpleado — cambiar el arreglo de sueldo de un empleado (entrega 3 de gastos).
 *
 * Un arreglo nuevo vale desde una fecha: los períodos anteriores conservan el que tenían. Con la
 * misma fecha que el vigente, lo corrige. Los campos son los del primer arreglo del alta
 * (`ModalEmpleado`), precargados con los del vigente si existe. Las reglas las repite `errorDeArreglo` con los mismos mensajes que el server
 * (`guardar_arreglo_empleado`).
 */
import React, { useId, useState } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { z } from 'zod'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { cn } from '../../lib/utils'
import { getErrorMessage } from '../../utils/errorHandling'
import { errorDeArreglo, inicioDelPeriodo, parseMonto } from '../../utils/personal'
import type { ArregloEmpleado, Empleado, FrecuenciaSueldo, GuardarArregloPayload } from '../../types/personal'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// eslint-disable-next-line react-refresh/only-export-components
export const modalArregloSchema = z.object({
  vigente_desde: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, { message: 'Elegí desde cuándo vale el arreglo' }),
  sueldo: z.number({ error: 'El sueldo no puede ser negativo' }),
  frecuencia: z.enum(['semanal', 'mensual'], { error: 'El sueldo es semanal o mensual' }),
  comisiona: z.boolean(),
})

export interface ModalArregloEmpleadoProps {
  empleado: Pick<Empleado, 'id' | 'nombre'>
  /** El último arreglo del empleado, o `null` si todavía no tiene. */
  vigente: ArregloEmpleado | null
  hoy: string
  onSave: (a: GuardarArregloPayload) => Promise<void>
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

export default function ModalArregloEmpleado({
  empleado, vigente, hoy, onSave, onClose,
}: ModalArregloEmpleadoProps): React.ReactElement {
  const id = useId()
  // Parte del arreglo vigente: cambiar sólo la fecha no tiene que dejarlo en cero sin avisar.
  const [sueldoTxt, setSueldoTxt] = useState(vigente ? String(vigente.sueldo) : '')
  const [frecuencia, setFrecuencia] = useState<FrecuenciaSueldo>(vigente?.frecuencia ?? 'semanal')
  const [comisiona, setComisiona] = useState(vigente?.comisiona ?? false)
  // La fecha sigue a la frecuencia hasta que se la toca a mano.
  const [desdeManual, setDesdeManual] = useState<string | null>(null)
  const desde = desdeManual ?? inicioDelPeriodo(hoy, frecuencia)
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const corrigeElVigente = vigente !== null && desde === vigente.vigente_desde

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')

    const resultado = modalArregloSchema.safeParse({
      vigente_desde: desde,
      sueldo: parseMonto(sueldoTxt),
      frecuencia,
      comisiona,
    })
    if (!resultado.success) {
      setError(resultado.error.issues[0]?.message ?? 'Revisá los datos del arreglo')
      return
    }
    const errorArreglo = errorDeArreglo(resultado.data, vigente)
    if (errorArreglo) {
      setError(errorArreglo)
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

  return (
    <ModalBase title="Cambiar arreglo" description={empleado.nombre} onClose={onClose} maxWidth="max-w-md">
      <form onSubmit={handleSubmit} className="p-4 space-y-4">
        <div>
          <label htmlFor={`${id}-sueldo`} className={CLASE_ETIQUETA}>Sueldo fijo {requerido}</label>
          <div className="relative">
            <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
            <input
              id={`${id}-sueldo`}
              type="text"
              inputMode="decimal"
              autoComplete="off"
              value={sueldoTxt}
              onChange={ev => setSueldoTxt(ev.target.value)}
              placeholder="0,00"
              className={cn(CLASE_INPUT, 'pl-7 text-right')}
            />
          </div>
        </div>

        <div role="group" aria-label="Frecuencia del sueldo" className="grid grid-cols-2 gap-2">
          <Pastilla activa={frecuencia === 'semanal'} onClick={() => setFrecuencia('semanal')}>Semanal</Pastilla>
          <Pastilla activa={frecuencia === 'mensual'} onClick={() => setFrecuencia('mensual')}>Mensual</Pastilla>
        </div>

        <div>
          <label className="inline-flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
            <input
              type="checkbox"
              className="w-4 h-4"
              checked={comisiona}
              onChange={ev => setComisiona(ev.target.checked)}
            />
            Comisiona
          </label>
          <p className={CLASE_AYUDA}>El porcentaje no va acá: sale de las reglas de comisión.</p>
        </div>

        <div>
          <label htmlFor={`${id}-desde`} className={CLASE_ETIQUETA}>Vale desde {requerido}</label>
          <input
            id={`${id}-desde`}
            type="date"
            value={desde}
            onChange={ev => setDesdeManual(ev.target.value)}
            className={cn(CLASE_INPUT, 'text-sm')}
          />
          {corrigeElVigente && (
            <p className="mt-1 text-xs text-amber-700 dark:text-amber-300">Corrige el arreglo vigente.</p>
          )}
          <p className={CLASE_AYUDA}>Los períodos anteriores conservan el arreglo que tenían.</p>
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
            Guardar arreglo
          </Button>
        </div>
      </form>
    </ModalBase>
  )
}
