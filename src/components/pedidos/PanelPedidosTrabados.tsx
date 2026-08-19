/**
 * PanelPedidosTrabados
 *
 * Pedidos que quedaron en `asignado` y envejecieron ahí: mercadería vendida que
 * no se entregó, no se canceló, y que el pool de "Armar ruta del día" no ve
 * porque filtra `pendiente`/`en_preparacion`. Sin este panel no aparecen en
 * ninguna pantalla — sólo salían con una consulta a mano.
 *
 * El botón para rescatarlos ("Volver a pendiente") existía y estaba cableado
 * desde hace rato. Lo que faltaba era enterarse de que había que usarlo, así que
 * esto va arriba de /pedidos, donde el admin ya está parado, y dispara la misma
 * acción que la fila del pedido.
 *
 * Hermano de PanelPedidosNoEntregados, que muestra lo del preventista; este es
 * la vista de admin/encargado.
 */
import { useState } from 'react'
import { AlertTriangle, ChevronDown, ChevronUp, Undo2 } from 'lucide-react'
import { usePedidosTrabadosQuery, type PedidoTrabado } from '../../hooks/queries/usePedidosTrabadosQuery'
import { formatPrecio, formatFecha } from '../../utils/formatters'

const VISIBLES_POR_DEFECTO = 3

export interface PanelPedidosTrabadosProps {
  /** Sólo admin/encargado: la acción de rescate es suya. */
  enabled: boolean
  /** Mismo handler que la fila del pedido; abre la confirmación. */
  onVolverAPendiente: (pedido: { id: string; transportista_id: string | null }) => void
}

export default function PanelPedidosTrabados({ enabled, onVolverAPendiente }: PanelPedidosTrabadosProps) {
  const { data: pedidos = [], isLoading } = usePedidosTrabadosQuery(enabled)
  const [expandido, setExpandido] = useState(false)

  if (!enabled || isLoading || pedidos.length === 0) return null

  const mostrados = expandido ? pedidos : pedidos.slice(0, VISIBLES_POR_DEFECTO)
  const ocultos = pedidos.length - mostrados.length
  const plata = pedidos.reduce((s, p) => s + p.total, 0)
  const masViejo = pedidos.reduce((max, p) => Math.max(max, p.diasTrabado), 0)

  return (
    <div className="rounded-xl border border-rose-300 dark:border-rose-800/60 bg-rose-50 dark:bg-rose-900/20 p-3">
      <div className="flex items-start gap-3">
        <AlertTriangle className="w-5 h-5 shrink-0 mt-0.5 text-rose-600 dark:text-rose-400" aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <p className="text-sm font-semibold text-rose-800 dark:text-rose-200">
            {pedidos.length === 1
              ? '1 pedido quedó trabado en "asignado"'
              : `${pedidos.length} pedidos quedaron trabados en "asignado"`}
            {' · '}
            <span className="tabular-nums">{formatPrecio(plata)}</span>
          </p>
          <p className="text-xs text-rose-700 dark:text-rose-300 mt-0.5">
            No se entregaron ni se cancelaron, y <strong>no aparecen al armar la ruta</strong>.
            {masViejo > 0 && ` El más viejo lleva ${masViejo} días.`} Volvelos a pendiente para
            poder rutearlos de nuevo.
          </p>

          <ul className="mt-2 space-y-1">
            {mostrados.map((p: PedidoTrabado) => (
              <li key={p.id} className="text-xs text-rose-900 dark:text-rose-100 flex flex-wrap items-baseline gap-x-2">
                <span className="font-medium">#{p.id}</span>
                <span className="truncate max-w-[14rem]">{p.clienteNombre}</span>
                {p.fecha && (
                  <span className="text-rose-600 dark:text-rose-400">
                    · del {formatFecha(p.fecha)} ({p.diasTrabado} d)
                  </span>
                )}
                <span className="tabular-nums text-rose-700 dark:text-rose-300">{formatPrecio(p.total)}</span>
                <button
                  type="button"
                  onClick={() => onVolverAPendiente({ id: p.id, transportista_id: p.transportistaId })}
                  className="inline-flex items-center gap-1 font-medium text-rose-800 dark:text-rose-200 hover:underline"
                >
                  <Undo2 className="w-3 h-3" aria-hidden="true" />
                  Volver a pendiente
                </button>
              </li>
            ))}
          </ul>

          {(ocultos > 0 || expandido) && (
            <button
              type="button"
              onClick={() => setExpandido(!expandido)}
              className="mt-1.5 inline-flex items-center gap-1 text-xs font-medium text-rose-800 dark:text-rose-200 hover:underline"
            >
              {expandido ? (
                <>Ver menos <ChevronUp className="w-3 h-3" aria-hidden="true" /></>
              ) : (
                <>Ver {ocultos} más <ChevronDown className="w-3 h-3" aria-hidden="true" /></>
              )}
            </button>
          )}
        </div>
      </div>
    </div>
  )
}
