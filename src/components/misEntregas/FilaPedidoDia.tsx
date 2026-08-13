/**
 * Una fila del día: un cliente y qué pasó con su pedido.
 *
 * El motivo se muestra siempre que exista, incluido "Otro" y el caso sin
 * motivo cargado — esconderlos haría que el panel diga "no entregado" sin
 * decir por qué, que es justo el vacío que vino a llenar.
 */
import { memo } from 'react'
import { LABEL_MOTIVO, MOTIVO_EXPLICACION } from '../../constants/motivosNoEntrega'
import { MOTIVOS_SALVEDAD_LABELS } from '../../lib/schemas'
import { formatPrecio, formatFecha } from '../../utils/formatters'
import type { PedidoDelDia } from '../../hooks/queries/useJornadasPreventistaQuery'
import BadgeDesenlace from './BadgeDesenlace'

interface Props {
  pedido: PedidoDelDia
  /** En el bucket de pendientes la fecha de carga es el dato que importa
   *  (cuánto hace que está colgado); en un día cerrado es ruido. */
  mostrarFechaPedido?: boolean
}

function textoMotivo(pedido: PedidoDelDia): string | null {
  if (pedido.desenlace !== 'rechazado' && pedido.desenlace !== 'administrativo') return null
  if (!pedido.motivo_tipo) return 'Sin motivo cargado'
  return MOTIVO_EXPLICACION[pedido.motivo_tipo] ?? LABEL_MOTIVO[pedido.motivo_tipo] ?? pedido.motivo_tipo
}

function FilaPedidoDia({ pedido, mostrarFechaPedido = false }: Props) {
  const motivo = textoMotivo(pedido)

  return (
    <li className="py-2.5 border-b border-gray-100 dark:border-gray-700 last:border-0">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="text-sm font-medium text-gray-900 dark:text-gray-100 truncate">
            {pedido.cliente}
          </p>
          <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1">
            <BadgeDesenlace desenlace={pedido.desenlace} />
            <span className="text-xs text-gray-500 dark:text-gray-400">#{pedido.pedido_id}</span>
            {mostrarFechaPedido && (
              <span className="text-xs text-gray-500 dark:text-gray-400">
                cargado el {formatFecha(pedido.fecha_pedido)}
              </span>
            )}
          </div>

          {motivo && (
            <p className="mt-1 text-xs text-gray-600 dark:text-gray-300">
              {motivo}
              {pedido.motivo_nota && (
                <span className="italic text-gray-500 dark:text-gray-400"> — «{pedido.motivo_nota}»</span>
              )}
            </p>
          )}

          {pedido.salvedades.length > 0 && (
            <ul className="mt-1.5 space-y-0.5">
              {pedido.salvedades.map((s, i) => (
                <li key={i} className="text-xs text-amber-700 dark:text-amber-300">
                  {s.cantidad_afectada} de {s.cantidad_original} × {s.producto}
                  <span className="text-amber-600 dark:text-amber-400">
                    {' '}· {MOTIVOS_SALVEDAD_LABELS[s.motivo as keyof typeof MOTIVOS_SALVEDAD_LABELS] ?? s.motivo}
                  </span>
                  {s.descripcion && (
                    <span className="italic text-amber-600 dark:text-amber-400"> «{s.descripcion}»</span>
                  )}
                </li>
              ))}
            </ul>
          )}

          {pedido.transportista && (
            <p className="mt-1 text-xs text-gray-400 dark:text-gray-500">
              Repartió {pedido.transportista}
            </p>
          )}
        </div>

        <span className="shrink-0 text-sm tabular-nums font-medium text-gray-700 dark:text-gray-200">
          {formatPrecio(pedido.monto)}
        </span>
      </div>
    </li>
  )
}

export default memo(FilaPedidoDia)
