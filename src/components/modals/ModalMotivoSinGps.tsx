/**
 * ModalMotivoSinGps
 *
 * Se abre cuando la captura de GPS termina con `timeout`, `unavailable` o
 * `error` (NO con `denied`, que es bloqueante). Pide al preventista una
 * justificación escrita obligatoria que queda persistida junto a la
 * visita/pedido para auditoría.
 *
 * Diseño: el caller usa este modal de forma imperativa via promesa —
 * `await abrir()` resuelve con el motivo escrito o `null` si canceló.
 */
import { useState } from 'react'
import { AlertTriangle, Loader2 } from 'lucide-react'
import ModalBase from './ModalBase'
import type { GpsStatus } from '../../hooks/useGeolocationCapture'

const MIN_LEN = 5

export interface ModalMotivoSinGpsProps {
  status: Exclude<GpsStatus, 'ok' | 'denied'>
  guardando?: boolean
  onConfirm: (motivo: string) => void
  onCancel: () => void
}

const STATUS_LABEL: Record<ModalMotivoSinGpsProps['status'], string> = {
  timeout: 'Se tardó demasiado en obtener la ubicación.',
  unavailable: 'GPS no disponible en este dispositivo o sin señal.',
  error: 'Error inesperado al obtener la ubicación.',
}

export default function ModalMotivoSinGps({
  status,
  guardando = false,
  onConfirm,
  onCancel,
}: ModalMotivoSinGpsProps) {
  const [motivo, setMotivo] = useState('')
  const valido = motivo.trim().length >= MIN_LEN

  return (
    <ModalBase title="Continuar sin GPS" onClose={onCancel} maxWidth="max-w-md">
      <div className="space-y-3">
        <div className="flex items-start gap-3 p-3 rounded-lg bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-700">
          <AlertTriangle className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
          <div className="text-sm text-amber-900 dark:text-amber-200">
            <p className="font-medium">{STATUS_LABEL[status]}</p>
            <p className="text-xs mt-1">
              Para continuar sin coordenadas necesitamos una explicación corta — queda
              registrada en el sistema.
            </p>
          </div>
        </div>

        <label className="block">
          <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
            Motivo *
          </span>
          <textarea
            autoFocus
            value={motivo}
            onChange={(e) => setMotivo(e.target.value)}
            rows={3}
            placeholder="Ej: estoy en sótano sin señal, GPS apagado, etc."
            className="mt-1 w-full px-3 py-2 text-sm rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-900 dark:text-white focus:outline-none focus:ring-2 focus:ring-blue-500"
            maxLength={500}
          />
          <span className="text-xs text-gray-400 mt-1 block">
            Mínimo {MIN_LEN} caracteres ({motivo.trim().length}/{MIN_LEN}).
          </span>
        </label>

        <div className="flex gap-2 pt-1">
          <button
            type="button"
            onClick={onCancel}
            disabled={guardando}
            className="flex-1 py-2 text-sm font-medium rounded-lg border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-60"
          >
            Cancelar
          </button>
          <button
            type="button"
            onClick={() => onConfirm(motivo.trim())}
            disabled={!valido || guardando}
            className="flex-1 py-2 text-sm font-semibold rounded-lg bg-amber-600 hover:bg-amber-700 disabled:bg-gray-300 dark:disabled:bg-gray-600 text-white flex items-center justify-center gap-1.5"
          >
            {guardando && <Loader2 className="w-4 h-4 animate-spin" />}
            Confirmar sin GPS
          </button>
        </div>
      </div>
    </ModalBase>
  )
}
