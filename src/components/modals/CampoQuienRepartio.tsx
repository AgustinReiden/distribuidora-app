import type { PerfilDB } from '../../types'
import type { EleccionChofer } from '../../utils/choferDeEntrega'

const RETIRO = '__retiro__'

export interface CampoQuienRepartioProps {
  /** Choferes de verdad (fetchTransportistas: sin admin ni encargado). */
  transportistas: PerfilDB[]
  /** "Retiró en depósito" lo marcan sólo admin y encargado (#1204). */
  permitirRetiro: boolean
  value: EleccionChofer | null
  onChange: (eleccion: EleccionChofer | null) => void
}

const aValor = (e: EleccionChofer | null): string =>
  !e ? '' : e.tipo === 'retiro' ? RETIRO : e.transportistaId

/**
 * #1204 · "¿Quién lo repartió?" dentro de la pantalla de entrega, para un
 * pedido sin chofer. El server rechaza la entrega sin chofer ni retiro (mig
 * 385): esto es la pregunta, no la regla.
 */
export default function CampoQuienRepartio({ transportistas, permitirRetiro, value, onChange }: CampoQuienRepartioProps) {
  return (
    <div>
      <label htmlFor="quien-repartio" className="block text-sm font-medium mb-1 dark:text-gray-200">
        ¿Quién lo repartió?
      </label>
      <select
        id="quien-repartio"
        value={aValor(value)}
        onChange={e => {
          const v = e.target.value
          onChange(!v ? null : v === RETIRO ? { tipo: 'retiro' } : { tipo: 'chofer', transportistaId: v })
        }}
        className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
      >
        <option value="">Elegir chofer...</option>
        {transportistas.map(t => (
          <option key={t.id} value={t.id}>{t.nombre}</option>
        ))}
        {permitirRetiro && <option value={RETIRO}>Retiró en depósito (sin chofer)</option>}
      </select>
      <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
        El pedido no tiene chofer asignado: todo pedido entregado queda con quien lo llevó.
      </p>
    </div>
  )
}
