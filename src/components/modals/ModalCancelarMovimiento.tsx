/**
 * ModalCancelarMovimiento — el origen se retracta de un envío pendiente.
 *
 * Cancelar devuelve el stock a la sucursal origen (mig 139). Solo admin y solo
 * mientras el envío siga pendiente; el motivo viaja en la notificación al destino.
 */
import { memo, useState } from 'react'
import { AlertTriangle } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import type { MovimientoSucursalDB } from '../../hooks/queries'

export interface ModalCancelarMovimientoProps {
  movimiento: MovimientoSucursalDB
  guardando?: boolean
  onConfirmar: (motivo: string) => void | Promise<void>
  onClose: () => void
}

function ModalCancelarMovimiento({ movimiento, guardando, onConfirmar, onClose }: ModalCancelarMovimientoProps) {
  const [motivo, setMotivo] = useState('')

  return (
    <ModalBase
      title={`Cancelar envío #${movimiento.id}`}
      description="El stock vuelve a esta sucursal"
      onClose={onClose}
      maxWidth="max-w-md"
    >
      <div className="space-y-4">
        <div className="flex gap-2 p-3 rounded-lg bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800">
          <AlertTriangle className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
          <p className="text-sm text-amber-800 dark:text-amber-200">
            Se van a devolver <strong>{movimiento.total_unidades} unidades</strong> al stock de esta sucursal
            y se le va a avisar a {movimiento.destino?.nombre || 'la sucursal destino'}.
          </p>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">
            Motivo <span className="text-gray-400 font-normal">(opcional)</span>
          </label>
          <textarea
            value={motivo}
            onChange={e => setMotivo(e.target.value)}
            rows={3}
            placeholder="Ej: se cargó por error, la mercadería no salió…"
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
        </div>

        <div className="flex justify-end gap-2">
          <Button variant="secondary" size="md" onClick={onClose} disabled={guardando}>
            Volver
          </Button>
          <Button
            variant="danger"
            size="md"
            onClick={() => { void onConfirmar(motivo.trim()) }}
            disabled={guardando}
          >
            {guardando ? 'Cancelando…' : 'Cancelar envío'}
          </Button>
        </div>
      </div>
    </ModalBase>
  )
}

export default memo(ModalCancelarMovimiento)
