/**
 * Pestaña "Canjes" de la ficha del cliente (#1370).
 *
 * Lista los cambios de producto del cliente (`cambios_productos`: el canje en el momento
 * y el que se completó como parada de una ruta) con su diferencia de precio. La
 * diferencia es informativa (decisión del dueño): no está en la cuenta del cliente, a
 * favor ni en contra, y si hay que cobrarla o devolver algo se hace aparte. Sólo lectura.
 */
import { ArrowLeftRight, Info, Loader2 } from 'lucide-react'
import { formatPrecio, formatFecha } from '../../utils/formatters'
import { useCambiosProductosClienteQuery } from '../../hooks/queries/useCambiosProductosQuery'
import { leyendaDiferenciaCanje, motivoCanjeLabel, sentidoDiferenciaCanje } from '../../utils/diferenciaCanje'

export interface CanjesClienteProps {
  clienteId: string
}

const TONO_DIFERENCIA = {
  a_cobrar: 'text-orange-700 dark:text-orange-400',
  a_favor_cliente: 'text-emerald-700 dark:text-emerald-400',
  sin_diferencia: 'text-gray-700 dark:text-gray-300',
} as const

export default function CanjesCliente({ clienteId }: CanjesClienteProps) {
  const { data: canjes = [], isLoading, error } = useCambiosProductosClienteQuery(clienteId)

  if (isLoading) {
    return (
      <div className="flex justify-center py-12">
        <Loader2 className="h-6 w-6 animate-spin text-teal-600" />
      </div>
    )
  }
  if (error) {
    return <p className="py-8 text-center text-sm text-red-600">No se pudieron cargar los canjes.</p>
  }

  return (
    <div className="space-y-3">
      <h3 className="font-semibold text-gray-900 dark:text-white">Canjes</h3>
      <p className="flex items-center gap-2 rounded-lg bg-teal-50 p-2 text-xs text-teal-800 dark:bg-teal-900/20 dark:text-teal-300">
        <Info className="h-4 w-4 shrink-0" />
        La diferencia de precio de un canje es informativa: no está en la cuenta del cliente. Si hay que cobrarla o devolver algo, se hace aparte.
      </p>

      {canjes.length === 0 ? (
        <div className="py-12 text-center text-gray-500">
          <ArrowLeftRight className="mx-auto mb-3 h-12 w-12 opacity-50" />
          <p>No hay canjes</p>
        </div>
      ) : (
        canjes.map(c => {
          const sentido = sentidoDiferenciaCanje(c.diferencia_monto)
          return (
            <div key={c.id} className="rounded-xl bg-gray-50 p-4 dark:bg-gray-700/50">
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <p className="font-semibold text-gray-900 dark:text-white">Canje #{c.id}</p>
                  <p className="text-sm text-gray-500">
                    {formatFecha(c.created_at)} • {motivoCanjeLabel(c.motivo)}
                  </p>
                </div>
                <div className="text-right">
                  <p className="text-xs text-gray-500">Diferencia</p>
                  <p className={`font-semibold tabular-nums ${TONO_DIFERENCIA[sentido]}`}>
                    {formatPrecio(Number(c.diferencia_monto) || 0)}
                  </p>
                </div>
              </div>
              <ul className="mt-2 space-y-0.5 text-sm text-gray-600 dark:text-gray-300">
                <li className="flex justify-between gap-2">
                  <span>Devolvió: {c.cantidad_devuelta} × {c.producto_devuelto?.nombre ?? 'producto'}</span>
                  <span className="tabular-nums">{formatPrecio((Number(c.precio_devuelto) || 0) * c.cantidad_devuelta)}</span>
                </li>
                <li className="flex justify-between gap-2">
                  <span>Se llevó: {c.cantidad_entregada} × {c.producto_entregado?.nombre ?? 'producto'}</span>
                  <span className="tabular-nums">{formatPrecio((Number(c.precio_entregado) || 0) * c.cantidad_entregada)}</span>
                </li>
              </ul>
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{leyendaDiferenciaCanje(c.diferencia_monto)}</p>
              {c.observaciones && <p className="mt-1 text-sm text-gray-400">{c.observaciones}</p>}
            </div>
          )
        })
      )}
    </div>
  )
}
