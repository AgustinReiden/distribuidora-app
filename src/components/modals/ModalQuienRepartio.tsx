import { useState, memo } from 'react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import CampoQuienRepartio from './CampoQuienRepartio'
import { fechaLocalISO } from '../../utils/formatters'
import { errorDeFechaEntrega, rangoFechaEntrega } from '../../utils/fechaEntrega'
import type { PedidoDB, PerfilDB } from '../../types'
import type { EleccionChofer } from '../../utils/choferDeEntrega'

export interface ModalQuienRepartioProps {
  pedido: PedidoDB
  /** Choferes de verdad (fetchTransportistas: sin admin ni encargado). */
  transportistas: PerfilDB[]
  /** "Retiró en depósito" lo marcan sólo admin y encargado (#1204). */
  permitirRetiro: boolean
  /** Entrega elegida: quién la repartió y a qué día pertenece. */
  onConfirm: (eleccion: EleccionChofer, fechaEntrega: string) => void
  onClose: () => void
  /** Sólo el admin fecha una entrega hasta 60 días atrás; el resto, hasta `diasAtrasFechaEntrega`. */
  esAdmin?: boolean
  /** `politicas_comerciales.dias_atras_fecha_pedido` de la sucursal (7 por defecto). */
  diasAtrasFechaEntrega?: number | null
}

/**
 * #1204 · La confirmación de entrega de un pedido sin chofer que no pasa por el
 * cobro (ya pagado, o una parada de cambio): chofer y fecha en un solo paso.
 * El pedido con saldo elige el chofer adentro de ModalPagoPedido.
 */
const ModalQuienRepartio = memo(function ModalQuienRepartio({
  pedido,
  transportistas,
  permitirRetiro,
  onConfirm,
  onClose,
  esAdmin = false,
  diasAtrasFechaEntrega,
}: ModalQuienRepartioProps) {
  const [eleccion, setEleccion] = useState<EleccionChofer | null>(null)
  const [hoy] = useState<string>(fechaLocalISO)
  const [fecha, setFecha] = useState<string>(hoy)
  // La regla del server (`_fecha_entrega_fuera_de_rango`), no sólo un `max`.
  const regla = { esAdmin, diasAtras: diasAtrasFechaEntrega, hoy }
  const rango = rangoFechaEntrega(regla)
  const errorFecha = errorDeFechaEntrega(fecha, regla)
  const esCambio = pedido.canal === 'cambio'

  return (
    <ModalBase
      title={esCambio ? 'Confirmar cambio/devolución' : 'Confirmar entrega'}
      description={`Pedido #${pedido.id}`}
      onClose={onClose}
      maxWidth="max-w-md"
    >
      <div className="p-4 space-y-4">
        <p className="text-sm text-gray-600 dark:text-gray-400">
          {esCambio
            ? `¿Confirmar el cambio/devolución del pedido #${pedido.id}? Se ajustará el stock.`
            : `¿Confirmar entrega del pedido #${pedido.id}${pedido.cliente?.nombre_fantasia ? ` (${pedido.cliente.nombre_fantasia})` : ''}?`}
        </p>
        <CampoQuienRepartio
          transportistas={transportistas}
          permitirRetiro={permitirRetiro}
          value={eleccion}
          onChange={setEleccion}
        />
        <div>
          <label htmlFor="fecha-entrega-chofer" className="block text-sm font-medium mb-1 dark:text-gray-200">
            Fecha de entrega
          </label>
          <input
            id="fecha-entrega-chofer"
            type="date"
            value={fecha}
            min={rango.min}
            max={rango.max}
            onChange={e => setFecha(e.target.value)}
            aria-invalid={errorFecha ? true : undefined}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
          {errorFecha ? (
            <p role="alert" className="text-xs text-red-600 dark:text-red-400 mt-1">{errorFecha}</p>
          ) : (
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Si estás cargando la entrega de un día anterior, cambiala: define en qué día se contabiliza.
            </p>
          )}
        </div>
      </div>

      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <Button onClick={onClose} variant="ghost" size="md">
          Cancelar
        </Button>
        <Button
          onClick={() => { if (eleccion && fecha && !errorFecha) onConfirm(eleccion, fecha) }}
          disabled={!eleccion || !fecha || !!errorFecha}
          variant="primary"
          size="md"
        >
          Confirmar
        </Button>
      </div>
    </ModalBase>
  )
})

export default ModalQuienRepartio
