/**
 * PanelPedidosNoEntregados
 *
 * Qué pedidos del preventista quedaron colgados: siguen vivos, sin entregar y
 * sin cancelar, así que en la lista de /pedidos se ven idénticos a uno recién
 * cargado y nadie los mira. Va arriba de /pedidos porque es el lugar donde el
 * preventista ya está parado.
 *
 * Antes esto salía de `recorrido_pedidos` y no devolvía nada para un
 * preventista: la RLS de esa tabla es admin-o-chofer, así que la query volvía
 * vacía sin error y el panel no se renderizaba nunca (ver el comentario de
 * useNoEntregadosQuery). Ahora sale del RPC de la mig 179.
 *
 * El detalle completo —con motivo, salvedades y el día de reparto— vive en
 * /mis-entregas; esto es el empujón para ir hasta ahí.
 */
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { PackageX, ChevronDown, ChevronUp } from 'lucide-react'
import { usePedidosSinResolverQuery } from '../../hooks/queries'
import { formatPrecio, formatFecha } from '../../utils/formatters'

const VISIBLES_POR_DEFECTO = 3

export default function PanelPedidosNoEntregados() {
  const { data: pedidos = [], isLoading } = usePedidosSinResolverQuery()
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
              ? '1 pedido tuyo sigue sin resolver'
              : `${pedidos.length} pedidos tuyos siguen sin resolver`}
          </p>
          <p className="text-xs text-amber-700 dark:text-amber-300 mt-0.5">
            No se entregaron ni se cancelaron. Revisalos antes de que envejezcan más.
          </p>

          <ul className="mt-2 space-y-1">
            {mostrados.map(p => (
              <li
                key={p.pedidoId}
                className="text-xs text-amber-900 dark:text-amber-100 flex flex-wrap items-baseline gap-x-2"
              >
                <span className="font-medium">#{p.pedidoId}</span>
                <span className="truncate max-w-[14rem]">{p.clienteNombre}</span>
                {p.fecha && (
                  <span className="text-amber-600 dark:text-amber-400">
                    · del {formatFecha(p.fecha)}
                  </span>
                )}
                <span className="tabular-nums text-amber-700 dark:text-amber-300">
                  {formatPrecio(p.total)}
                </span>
              </li>
            ))}
          </ul>

          <div className="mt-1.5 flex flex-wrap items-center gap-x-3">
            {(ocultos > 0 || expandido) && (
              <button
                type="button"
                onClick={() => setExpandido(!expandido)}
                className="inline-flex items-center gap-1 text-xs font-medium text-amber-800 dark:text-amber-200 hover:underline"
              >
                {expandido ? (
                  <>Ver menos <ChevronUp className="w-3 h-3" aria-hidden="true" /></>
                ) : (
                  <>Ver {ocultos} más <ChevronDown className="w-3 h-3" aria-hidden="true" /></>
                )}
              </button>
            )}
            <Link
              to="/mis-entregas"
              className="text-xs font-medium text-amber-800 dark:text-amber-200 hover:underline"
            >
              Ver mis entregas
            </Link>
          </div>
        </div>
      </div>
    </div>
  )
}
