/**
 * ModalVehiculo — alta y edición de un vehículo (entrega 1 de gastos).
 *
 * La patente se normaliza mientras se escribe (mayúsculas, sin espacios ni
 * guiones): es la misma regla que aplica `guardar_vehiculo`, y la patente es
 * única en toda la red.
 */
import React, { useId, useState } from 'react'
import type { ChangeEvent, FormEvent } from 'react'
import { z } from 'zod'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { getErrorMessage } from '../../utils/errorHandling'
import { normalizarPatente } from '../../utils/gastos'
import type { GuardarVehiculoInput } from '../../hooks/queries/useVehiculosQuery'
import type { Vehiculo } from '../../types/gastos'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// eslint-disable-next-line react-refresh/only-export-components
export const modalVehiculoSchema = z.object({
  patente: z.string().regex(/^[A-Z0-9]{6,8}$/, { message: 'La patente tiene entre 6 y 8 letras o números' }),
  descripcion: z.string().trim().min(1, { message: 'Escribí el modelo o una descripción del vehículo' }),
})

export interface ModalVehiculoProps {
  /** Edición. */
  vehiculo?: Vehiculo | null
  onSave: (vehiculo: GuardarVehiculoInput) => Promise<void>
  onClose: () => void
}

export default function ModalVehiculo({ vehiculo, onSave, onClose }: ModalVehiculoProps): React.ReactElement {
  const idPatente = useId()
  const idDescripcion = useId()
  const [patente, setPatente] = useState(vehiculo?.patente ?? '')
  const [descripcion, setDescripcion] = useState(vehiculo?.descripcion ?? '')
  const [activo, setActivo] = useState(vehiculo?.activo ?? true)
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')
    const resultado = modalVehiculoSchema.safeParse({ patente, descripcion })
    if (!resultado.success) {
      setError(resultado.error.issues[0]?.message ?? 'Revisá los datos del vehículo')
      return
    }
    setGuardando(true)
    try {
      await onSave({
        ...(vehiculo ? { id: vehiculo.id } : {}),
        ...resultado.data,
        ...(vehiculo ? { activo } : {}),
      })
      onClose()
    } catch (err) {
      setError(getErrorMessage(err))
    } finally {
      setGuardando(false)
    }
  }

  return (
    <ModalBase title={vehiculo ? 'Editar vehículo' : 'Nuevo vehículo'} onClose={onClose} maxWidth="max-w-md">
      <form onSubmit={handleSubmit} className="p-4 space-y-4">
        <div>
          <label htmlFor={idPatente} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Patente <span className="text-red-500">*</span>
          </label>
          <input
            id={idPatente}
            type="text"
            autoComplete="off"
            value={patente}
            onChange={(e: ChangeEvent<HTMLInputElement>) => setPatente(normalizarPatente(e.target.value))}
            maxLength={8}
            placeholder="AC456EF"
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg font-mono uppercase focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white"
          />
        </div>
        <div>
          <label htmlFor={idDescripcion} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Modelo o descripción <span className="text-red-500">*</span>
          </label>
          <input
            id={idDescripcion}
            type="text"
            autoComplete="off"
            value={descripcion}
            onChange={e => setDescripcion(e.target.value)}
            placeholder="Partner, Hilux, camión del reparto…"
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white"
          />
        </div>
        {vehiculo && (
          <label className="inline-flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
            <input type="checkbox" className="w-4 h-4" checked={activo} onChange={e => setActivo(e.target.checked)} />
            Activo
          </label>
        )}
        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          </div>
        )}
        <div className="flex gap-3 pt-2">
          <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" variant="primary" size="md" loading={guardando} disabled={guardando} className="flex-1">
            Guardar vehículo
          </Button>
        </div>
      </form>
    </ModalBase>
  )
}
