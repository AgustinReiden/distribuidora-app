/**
 * PanelPedidosNoEntregados
 *
 * Qué pedidos volvieron sin entregar y por qué. Va arriba de /pedidos porque el
 * pedido no entregado vuelve al estado 'pendiente' (mig 144): en la lista se ve
 * idéntico a uno recién cargado, así que sin esto el motivo se pierde apenas la
 * notificación de la campanita queda atrás.
 *
 * Es el lado del preventista de la misma historia que el panel de Recorridos le
 * muestra al admin. La RLS ya acota: cada uno ve los suyos.
 */
import { useState } from 'react'
import { PackageX, ChevronDown, ChevronUp } from 'lucide-react'
import { usePedidosRebotadosQuery } from '../../hooks/queries'
import { MOTIVO_EXPLICACION, LABEL_MOTIVO } from '../../constants/motivosNoEntrega'
import { formatPrecio } from '../../utils/formatters'

const VISIBLES_POR_DEFECTO = 3

export default function PanelPedidosNoEntregados() {
  const { data: pedidos = [], isLoading } = usePedidosRebotadosQuery()
  const [expandido, setExpandido] = useState(false)

  if (isLoading || pedidos.length === 0) return null

  const mostrados = expandido ? pedidos : pedidos.slice(0, VISIBLES_POR_DEFECTO)
  const ocultos = pedidos.length - mostrados.length

  return (
    <div className="rounded-xl border border-amber-300 dark:border-amber-800/60 bg-amber-50 dark:bg-amber-900/20 p-3">
      <div className="flex items-start gap-3">
        <PackageX className="w-5 h-5 shrink-0 mt-0.5 text-amber-600 dark:text-amber-400" aria-hidden="true" />
        <div className="min-w-0 flex-1">
          <p className="text-sm font-semibold text-amber-800 dark:text-amber-200">
            {pedidos.length === 1
              ? '1 pedido volvió sin entregar'
              : `${pedidos.length} pedidos volvieron sin entregar`}
          </p>
          <p className="text-xs text-amber-700 dark:text-amber-300 mt-0.5">
            Siguen vivos y volvieron al pool para re-repartir. Revisá el motivo antes de reprogramar.
          </p>

          <ul className="mt-2 space-y-1">
            {mostrados.map(p => (
              <li
                key={p.pedidoId}
                className="text-xs text-amber-900 dark:text-amber-100 flex flex-wrap items-baseline gap-x-2"
              >
                <span className="font-medium">#{p.pedidoId}</span>
                <span className="truncate max-w-[14rem]">{p.clienteNombre}</span>
                <span className="text-amber-700 dark:text-amber-300">
                  · {p.motivo === 'sin_motivo'
                      ? 'sin motivo cargado'
                      : (MOTIVO_EXPLICACION[p.motivo] ?? LABEL_MOTIVO[p.motivo] ?? p.motivo)}
                </span>
                {p.nota && <span className="italic text-amber-700 dark:text-amber-300">«{p.nota}»</span>}
                {p.fecha && <span className="text-amber-600 dark:text-amber-400">· {p.fecha}</span>}
                <span className="tabular-nums text-amber-700 dark:text-amber-300">{formatPrecio(p.total)}</span>
              </li>
            ))}
          </ul>

          {(ocultos > 0 || expandido) && (
            <button
              type="button"
              onClick={() => setExpandido(!expandido)}
              className="mt-1.5 inline-flex items-center gap-1 text-xs font-medium text-amber-800 dark:text-amber-200 hover:underline"
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
