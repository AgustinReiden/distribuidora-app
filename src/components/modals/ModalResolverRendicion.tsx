/**
 * Modal para resolver una rendición que está en disconformidad.
 *
 * Flujo:
 *   1. El usuario describe cómo se resolvió el problema (texto obligatorio).
 *   2. Al submit se llama `resolver_rendicion` (RPC) que cambia el estado a
 *      'resuelta' y appendea la observación al historial preservando el texto
 *      anterior con sello de usuario y fecha.
 */
import { useState, memo } from 'react'
import { Loader2, FileText, CheckCircle } from 'lucide-react'
import ModalBase from './ModalBase'

export interface ModalResolverRendicionProps {
  fecha: string
  transportistaNombre: string
  observacionesPrevias: string | null
  onResolver: (observaciones: string) => Promise<void>
  onClose: () => void
  guardando: boolean
}

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

const ModalResolverRendicion = memo(function ModalResolverRendicion({
  fecha,
  transportistaNombre,
  observacionesPrevias,
  onResolver,
  onClose,
  guardando
}: ModalResolverRendicionProps) {
  const [observaciones, setObservaciones] = useState<string>('')

  const handleSubmit = async (): Promise<void> => {
    if (!observaciones.trim()) return
    await onResolver(observaciones.trim())
  }

  return (
    <ModalBase title="Resolver disconformidad" onClose={onClose} maxWidth="max-w-xl">
      <div className="p-4 space-y-4">
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Rendición de <span className="font-semibold text-gray-800 dark:text-white">{transportistaNombre}</span>{' '}
            del <span className="font-semibold text-gray-800 dark:text-white">{formatFechaCorta(fecha)}</span>
          </p>
        </div>

        {observacionesPrevias && (
          <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-3">
            <p className="text-xs font-medium text-red-700 dark:text-red-300 mb-1 flex items-center gap-1">
              <FileText className="w-3 h-3" />
              Observaciones previas
            </p>
            <p className="text-sm text-red-900 dark:text-red-200 whitespace-pre-wrap">
              {observacionesPrevias}
            </p>
          </div>
        )}

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            ¿Cómo se resolvió? <span className="text-red-500">*</span>
          </label>
          <textarea
            value={observaciones}
            onChange={e => setObservaciones(e.target.value)}
            rows={4}
            placeholder="Ej: Se cobró el faltante en efectivo al día siguiente / cheque reemplazado por transferencia / …"
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
            El texto se append-ea al historial con tu nombre y la fecha.
          </p>
        </div>
      </div>

      <div className="flex items-center justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button
          onClick={onClose}
          disabled={guardando}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg disabled:opacity-50"
        >
          Cancelar
        </button>
        <button
          onClick={handleSubmit}
          disabled={guardando || !observaciones.trim()}
          className="px-4 py-2 rounded-lg text-white flex items-center gap-2 disabled:opacity-50 bg-blue-600 hover:bg-blue-700"
        >
          {guardando ? <Loader2 className="w-4 h-4 animate-spin" /> : <CheckCircle className="w-4 h-4" />}
          Marcar como resuelta
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalResolverRendicion
