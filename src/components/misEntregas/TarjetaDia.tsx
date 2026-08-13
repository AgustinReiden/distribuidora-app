/**
 * Un día de reparto. Colapsada muestra el marcador; el detalle se pide recién
 * al expandir — mismo patrón que las tarjetas de VistaRendiciones.
 */
import { useState } from 'react'
import { ChevronDown, ChevronUp } from 'lucide-react'
import { useJornadaDetalleQuery } from '../../hooks/queries/useJornadasPreventistaQuery'
import type { ResumenDia } from '../../hooks/queries/useJornadasPreventistaQuery'
import {
  desenlacesDelFiltro,
  ESTILO_DESENLACE,
  type FiltroDesenlace,
} from '../../constants/desenlacePedido'
import { formatPrecio, parseDateSafe } from '../../utils/formatters'
import FilaPedidoDia from './FilaPedidoDia'

interface Props {
  resumen: ResumenDia
  preventistaId: string | null
  filtro: FiltroDesenlace
  /** El día más reciente arranca abierto: es el que se viene a mirar. */
  defaultExpandido?: boolean
}

function fechaLarga(dia: string): string {
  return parseDateSafe(dia).toLocaleDateString('es-AR', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
  })
}

export default function TarjetaDia({ resumen, preventistaId, filtro, defaultExpandido = false }: Props) {
  const [expandido, setExpandido] = useState(defaultExpandido)
  const [verAdministrativos, setVerAdministrativos] = useState(false)

  const { data: pedidos = [], isLoading } = useJornadaDetalleQuery(
    resumen.dia,
    preventistaId,
    expandido,
  )

  const operativos = resumen.total - resumen.administrativos
  const permitidos = desenlacesDelFiltro(filtro)
  const visibles = pedidos.filter(p => {
    if (p.desenlace === 'administrativo') return false
    return permitidos === null || permitidos.includes(p.desenlace)
  })
  const administrativos = pedidos.filter(p => p.desenlace === 'administrativo')

  return (
    <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
      <button
        type="button"
        onClick={() => setExpandido(!expandido)}
        aria-expanded={expandido}
        className="w-full text-left p-4 hover:bg-gray-50 dark:hover:bg-gray-750 transition-colors"
      >
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <p className="text-sm font-semibold text-gray-900 dark:text-gray-100 capitalize">
              {fechaLarga(resumen.dia)}
            </p>
            <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
              {/* Sin los administrativos, para que el marcador cierre con lo
                  que se lista abajo: si el día tuvo un error de carga, ese no
                  fue un cliente que existió. */}
              <span className="text-gray-500 dark:text-gray-400">
                {operativos} {operativos === 1 ? 'pedido' : 'pedidos'}
              </span>
              {resumen.entregados > 0 && (
                <span className={ESTILO_DESENLACE.entregado.punto}>
                  {resumen.entregados} entregados
                </span>
              )}
              {resumen.con_salvedad > 0 && (
                <span className={ESTILO_DESENLACE.entregado_con_salvedad.punto}>
                  {resumen.con_salvedad} con salvedad
                </span>
              )}
              {resumen.rechazados > 0 && (
                <span className={`font-medium ${ESTILO_DESENLACE.rechazado.punto}`}>
                  {resumen.rechazados} no {resumen.rechazados === 1 ? 'entregado' : 'entregados'}
                </span>
              )}
            </div>
            {resumen.monto_rechazado > 0 && (
              <p className="mt-1 text-xs text-red-600 dark:text-red-400 tabular-nums">
                {formatPrecio(resumen.monto_rechazado)} sin entregar
              </p>
            )}
          </div>
          {expandido
            ? <ChevronUp className="w-4 h-4 shrink-0 mt-1 text-gray-400" aria-hidden="true" />
            : <ChevronDown className="w-4 h-4 shrink-0 mt-1 text-gray-400" aria-hidden="true" />}
        </div>
      </button>

      {expandido && (
        <div className="px-4 pb-3 border-t border-gray-100 dark:border-gray-700">
          {isLoading ? (
            <p className="py-3 text-xs text-gray-500 dark:text-gray-400">Cargando…</p>
          ) : (
            <>
              <ul>
                {visibles.map(p => <FilaPedidoDia key={p.pedido_id} pedido={p} />)}
              </ul>

              {visibles.length === 0 && (
                <p className="py-3 text-xs text-gray-500 dark:text-gray-400">
                  Nada de este día entra en el filtro.
                </p>
              )}

              {/* Los administrativos existen pero no son rechazos: quedan a
                  mano sin ensuciar el marcador del día. */}
              {administrativos.length > 0 && (
                <div className="pt-2">
                  <button
                    type="button"
                    onClick={() => setVerAdministrativos(!verAdministrativos)}
                    className="text-xs text-gray-500 dark:text-gray-400 hover:underline"
                  >
                    {verAdministrativos ? 'Ocultar' : `Ver ${administrativos.length}`} corregidos en
                    oficina (errores de carga, pruebas, unificados)
                  </button>
                  {verAdministrativos && (
                    <ul className="mt-1">
                      {administrativos.map(p => <FilaPedidoDia key={p.pedido_id} pedido={p} />)}
                    </ul>
                  )}
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  )
}
