import { useState, memo } from 'react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import type { PedidoDB, PerfilDB } from '../../types'
import type { EleccionChofer } from '../../utils/choferDeEntrega'

export interface ModalQuienRepartioProps {
  pedido: PedidoDB
  /** Choferes de verdad (fetchTransportistas: sin admin ni encargado). */
  transportistas: PerfilDB[]
  /** "Retiró en depósito" lo marcan sólo admin y encargado (#1204). */
  permitirRetiro: boolean
  onConfirm: (eleccion: EleccionChofer) => void
  onClose: () => void
}

const RETIRO = '__retiro__'

/**
 * #1204 · Antes de marcar entregado un pedido sin chofer, quién lo repartió.
 * El server rechaza la entrega sin chofer ni retiro (mig 384): esto es la
 * pregunta, no la regla.
 */
const ModalQuienRepartio = memo(function ModalQuienRepartio({
  pedido,
  transportistas,
  permitirRetiro,
  onConfirm,
  onClose,
}: ModalQuienRepartioProps) {
  const [eleccion, setEleccion] = useState('')

  const confirmar = (): void => {
    if (!eleccion) return
    onConfirm(eleccion === RETIRO ? { tipo: 'retiro' } : { tipo: 'chofer', transportistaId: eleccion })
  }

  return (
    <ModalBase
      title={`¿Quién repartió el pedido #${pedido.id}?`}
      description="El pedido no tiene chofer asignado"
      onClose={onClose}
      maxWidth="max-w-md"
    >
      <div className="p-4 space-y-4">
        <p className="text-sm text-gray-600 dark:text-gray-400">
          {pedido.cliente?.nombre_fantasia ? `${pedido.cliente.nombre_fantasia}. ` : ''}
          Todo pedido entregado queda con el chofer que lo llevó.
        </p>
        <div>
          <label htmlFor="quien-repartio" className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300">
            Chofer
          </label>
          <select
            id="quien-repartio"
            value={eleccion}
            onChange={e => setEleccion(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="">Elegir quién lo repartió...</option>
            {transportistas.map(t => (
              <option key={t.id} value={t.id}>{t.nombre}</option>
            ))}
            {permitirRetiro && <option value={RETIRO}>Retiró en depósito (sin chofer)</option>}
          </select>
        </div>
      </div>

      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <Button onClick={onClose} variant="ghost" size="md">
          Cancelar
        </Button>
        <Button onClick={confirmar} disabled={!eleccion} variant="primary" size="md">
          Continuar
        </Button>
      </div>
    </ModalBase>
  )
})

export default ModalQuienRepartio
