/**
 * ModalDeudoresMora — lista de clientes en mora (cuenta corriente).
 *
 * La antigüedad se cuenta desde la FECHA DE ENTREGA (+ dias_credito del cliente),
 * vía la RPC `obtener_deudores_mora`. Solo cuenta pedidos entregados impagos.
 */
import { memo, useMemo, useState } from 'react'
import { Loader2, Search, AlertTriangle, User, ChevronRight } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio } from '../../utils/formatters'
import { useDeudoresMoraQuery } from '../../hooks/queries'

export interface ModalDeudoresMoraProps {
  onClose: () => void
  /** Abre la ficha del cliente (resuelto en el container desde la lista de clientes). */
  onVerFicha: (clienteId: number) => void
}

function badgeMora(dias: number): string {
  if (dias > 60) return 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400'
  if (dias > 30) return 'bg-orange-100 text-orange-700 dark:bg-orange-900/30 dark:text-orange-400'
  return 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400'
}

const ModalDeudoresMora = memo(function ModalDeudoresMora({ onClose, onVerFicha }: ModalDeudoresMoraProps) {
  const { data: deudores = [], isLoading, isError, error } = useDeudoresMoraQuery(1, true)
  const [busqueda, setBusqueda] = useState('')

  const filtrados = useMemo(() => {
    const term = busqueda.trim().toLowerCase()
    if (!term) return deudores
    return deudores.filter(d => d.nombre?.toLowerCase().includes(term))
  }, [deudores, busqueda])

  const totalVencido = useMemo(
    () => filtrados.reduce((s, d) => s + (d.saldo_vencido || 0), 0),
    [filtrados],
  )

  return (
    <ModalBase
      title="Deudores con mora"
      description="Clientes con pedidos entregados e impagos vencidos. La antigüedad se cuenta desde la fecha de entrega."
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="p-4 space-y-3">
        {/* Resumen */}
        <div className="grid grid-cols-2 gap-3">
          <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
            <p className="text-xs text-gray-500 dark:text-gray-400">Deudores en mora</p>
            <p className="text-xl font-bold text-gray-900 dark:text-white">{filtrados.length}</p>
          </div>
          <div className="bg-red-50 dark:bg-red-900/20 rounded-lg p-3">
            <p className="text-xs text-gray-500 dark:text-gray-400">Saldo vencido total</p>
            <p className="text-xl font-bold text-red-600 dark:text-red-400">{formatPrecio(totalVencido)}</p>
          </div>
        </div>

        {/* Búsqueda */}
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
          <input
            type="text"
            placeholder="Buscar cliente..."
            value={busqueda}
            onChange={e => setBusqueda(e.target.value)}
            className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
        </div>

        {/* Lista */}
        <div className="max-h-[55vh] overflow-y-auto border rounded-lg dark:border-gray-600">
          {isLoading ? (
            <div className="flex items-center justify-center py-10 text-gray-500">
              <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
              <span className="ml-2">Cargando deudores...</span>
            </div>
          ) : isError ? (
            <div className="flex items-start gap-2 p-4 text-sm text-red-600 dark:text-red-400">
              <AlertTriangle className="w-5 h-5 flex-shrink-0 mt-0.5" />
              <span>{(error as Error)?.message || 'Error al cargar deudores'}</span>
            </div>
          ) : filtrados.length === 0 ? (
            <div className="text-center py-10 text-gray-500">
              {busqueda ? 'Sin resultados para la búsqueda' : 'No hay clientes en mora 🎉'}
            </div>
          ) : (
            <ul className="divide-y dark:divide-gray-600">
              {filtrados.map(d => (
                <li key={d.cliente_id}>
                  <button
                    type="button"
                    onClick={() => onVerFicha(d.cliente_id)}
                    className="w-full flex items-center gap-3 px-3 py-2.5 text-left hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
                  >
                    <div className="w-8 h-8 rounded-full bg-gray-100 dark:bg-gray-700 flex items-center justify-center flex-shrink-0">
                      <User className="w-4 h-4 text-gray-500" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <p className="font-medium text-gray-900 dark:text-white truncate">{d.nombre || 'Sin nombre'}</p>
                      <div className="flex items-center gap-2 mt-0.5">
                        <span className={`px-1.5 py-0.5 rounded-full text-xs font-medium ${badgeMora(d.dias_mora_max)}`}>
                          {d.dias_mora_max} {d.dias_mora_max === 1 ? 'día' : 'días'} de mora
                        </span>
                      </div>
                    </div>
                    <div className="text-right flex-shrink-0">
                      <p className="font-bold text-red-600 dark:text-red-400">{formatPrecio(d.saldo_vencido)}</p>
                      <p className="text-xs text-gray-400">Saldo total: {formatPrecio(d.saldo)}</p>
                    </div>
                    <ChevronRight className="w-4 h-4 text-gray-400 flex-shrink-0" />
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      <div className="flex justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cerrar
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalDeudoresMora
