/**
 * ModalAnularGasto — un gasto no se borra, se anula: queda con quién lo anuló y
 * el motivo, que es obligatorio. El permiso lo valida `anular_gasto`.
 */
import React, { useId, useState } from 'react'
import type { FormEvent } from 'react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { getErrorMessage } from '../../utils/errorHandling'
import { formatPrecio } from '../../utils/formatters'
import type { Gasto } from '../../types/gastos'

export interface ModalAnularGastoProps {
  gasto: Gasto
  onConfirm: (motivo: string) => Promise<void>
  onClose: () => void
}

export default function ModalAnularGasto({ gasto, onConfirm, onClose }: ModalAnularGastoProps): React.ReactElement {
  const idMotivo = useId()
  const [motivo, setMotivo] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')
    if (!motivo.trim()) {
      setError('Escribí por qué se anula')
      return
    }
    setGuardando(true)
    try {
      await onConfirm(motivo.trim())
      onClose()
    } catch (err) {
      setError(getErrorMessage(err))
    } finally {
      setGuardando(false)
    }
  }

  return (
    <ModalBase title="Anular gasto" onClose={onClose} maxWidth="max-w-md">
      <form onSubmit={handleSubmit} className="p-4 space-y-4">
        <p className="text-sm text-gray-700 dark:text-gray-300">
          {gasto.rubro?.nombre ?? 'Gasto'} · {formatPrecio(gasto.monto_total)}. Deja de contar en el resultado y en la
          posición fiscal; queda registrado quién lo anuló y por qué.
        </p>
        <div>
          <label htmlFor={idMotivo} className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Motivo <span className="text-red-500">*</span>
          </label>
          <textarea
            id={idMotivo}
            rows={3}
            value={motivo}
            onChange={e => setMotivo(e.target.value)}
            placeholder="Por qué se anula"
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white"
          />
        </div>
        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          </div>
        )}
        <div className="flex gap-3 pt-2">
          <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" variant="danger" size="md" loading={guardando} disabled={guardando} className="flex-1">
            Anular gasto
          </Button>
        </div>
      </form>
    </ModalBase>
  )
}
