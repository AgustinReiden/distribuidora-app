/**
 * Modal para deshacer la resolución de una rendición (sólo admin).
 *
 * Deshace todo junto, nunca un pedazo: compensa las deudas cargadas a empleados, anula los gastos
 * de la resolución y devuelve la rendición a disconformidad. El motivo es obligatorio y se suma a
 * las observaciones con tu nombre y la fecha. Se llama a `deshacer_resolucion_rendicion` (RPC).
 */
import { useState, memo } from 'react'
import { Undo2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { formatPrecio } from '../../utils/formatters'
import { textoFaltante, totalImputado } from '../../utils/faltantesRendicion'
import type { FaltanteDeRendicion } from '../../types/gastos'

export interface ModalDeshacerResolucionProps {
  fecha: string
  transportistaNombre: string
  /** Las líneas vivas de la diferencia imputada: lo que se va a deshacer. */
  faltantes: FaltanteDeRendicion[]
  onDeshacer: (motivo: string) => Promise<void>
  onClose: () => void
  guardando: boolean
}

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

const ModalDeshacerResolucion = memo(function ModalDeshacerResolucion({
  fecha,
  transportistaNombre,
  faltantes,
  onDeshacer,
  onClose,
  guardando
}: ModalDeshacerResolucionProps) {
  const [motivo, setMotivo] = useState<string>('')

  // Confirmar es sólo con el botón: el campo es un textarea y Enter escribe una línea nueva.
  const handleSubmit = async (): Promise<void> => {
    if (!motivo.trim()) return
    await onDeshacer(motivo.trim())
  }

  return (
    <ModalBase title="Deshacer resolución" onClose={onClose} maxWidth="max-w-md">
      <div className="p-4 space-y-4">
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Rendición de <span className="font-semibold text-gray-800 dark:text-white">{transportistaNombre}</span>{' '}
            del <span className="font-semibold text-gray-800 dark:text-white">{formatFechaCorta(fecha)}</span>
          </p>
          <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">
            Se compensan las deudas, se anulan los gastos de la resolución y la rendición vuelve a disconformidad.
          </p>
        </div>

        {/* Qué se deshace: las mismas líneas que muestra la tarjeta. */}
        <div className="rounded-lg border border-gray-200 dark:border-gray-600 p-3">
          {faltantes.length === 0 ? (
            <p className="text-sm text-gray-600 dark:text-gray-400">
              Esta resolución no imputó ninguna diferencia: sólo vuelve a disconformidad.
            </p>
          ) : (
            <>
              <p className="text-xs font-medium text-gray-600 dark:text-gray-300">Diferencia imputada que se deshace</p>
              <ul className="mt-1 space-y-0.5 text-sm text-gray-800 dark:text-gray-200">
                {faltantes.map(f => (
                  <li key={f.id}>{textoFaltante(f)}</li>
                ))}
              </ul>
              <p className="mt-2 text-sm font-semibold text-gray-800 dark:text-white">
                {`Total: ${formatPrecio(totalImputado(faltantes))}`}
              </p>
            </>
          )}
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1" htmlFor="deshacer-motivo">
            ¿Por qué se deshace? <span className="text-red-500">*</span>
          </label>
          <textarea
            id="deshacer-motivo"
            value={motivo}
            onChange={e => setMotivo(e.target.value)}
            rows={3}
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
            El motivo se suma al historial con tu nombre y la fecha.
          </p>
        </div>
      </div>

      <div className="flex items-center justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <Button
          onClick={onClose}
          disabled={guardando}
          variant="ghost"
          size="md"
          className="text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
        >
          Cancelar
        </Button>
        <Button
          onClick={handleSubmit}
          disabled={guardando || !motivo.trim()}
          loading={guardando}
          variant="danger"
          size="md"
        >
          {!guardando && <Undo2 className="w-4 h-4" />}
          Deshacer resolución
        </Button>
      </div>
    </ModalBase>
  )
})

export default ModalDeshacerResolucion
