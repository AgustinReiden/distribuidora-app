/**
 * "Mis entregas" — qué pasó, día por día, con los pedidos que tomó el
 * preventista (mig 179).
 *
 * El preventista cierra la venta y después no se entera de nada: si el cliente
 * rechazó, si el local estaba cerrado, si el chofer entregó de menos. Todo eso
 * pasa cuando él ya no está, y hasta acá no había ninguna pantalla que se lo
 * contara. Se enteraba en la visita siguiente, por el cliente.
 *
 * Los días se agrupan por fecha de REPARTO (cuándo se entregó o se cayó), no
 * por fecha de carga: la entrega es a D+1 sólo la mitad de las veces y se
 * estira hasta D+10, así que agrupar por carga mezclaría desenlaces de
 * semanas distintas en la misma tarjeta.
 *
 * Solo lectura. No hay un botón acá que cambie un pedido.
 */
import { useMemo, useState } from 'react'
import { CalendarDays, Clock, PackageX } from 'lucide-react'
import { useAuthData } from '../../contexts/AuthDataContext'
import {
  useJornadasPreventistaQuery,
  useJornadaDetalleQuery,
} from '../../hooks/queries/useJornadasPreventistaQuery'
import { useUsuariosByRolQuery } from '../../hooks/queries'
import { LABEL_FILTRO, type FiltroDesenlace } from '../../constants/desenlacePedido'
import { fechaLocalISO, fechaHaceDias, formatPrecio, formatFecha } from '../../utils/formatters'
import EmptyState from '../ui/EmptyState'
import TarjetaDia from '../misEntregas/TarjetaDia'
import FilaPedidoDia from '../misEntregas/FilaPedidoDia'

const PERIODOS = [
  { dias: 7, label: '7 días' },
  { dias: 14, label: '14 días' },
  { dias: 30, label: '30 días' },
] as const

const FILTROS: FiltroDesenlace[] = ['todos', 'entregados', 'rechazados', 'pendientes']

export default function VistaMisEntregas() {
  const { isAdmin, isEncargado } = useAuthData()
  const puedeElegirPreventista = isAdmin || isEncargado

  const [dias, setDias] = useState<number>(14)
  const [filtro, setFiltro] = useState<FiltroDesenlace>('todos')
  const [preventistaId, setPreventistaId] = useState<string | null>(null)

  const hasta = fechaLocalISO()
  const desde = fechaHaceDias(dias - 1)

  const { data, isLoading, error } = useJornadasPreventistaQuery(desde, hasta, preventistaId)
  const { data: preventistas = [] } = useUsuariosByRolQuery(
    puedeElegirPreventista ? 'preventista' : '',
  )

  // El bucket de colgados no pertenece a ningún día: se pide aparte y sólo
  // cuando el filtro lo pone en primer plano o no filtra nada.
  const mostrarPendientes = filtro === 'todos' || filtro === 'pendientes'
  const { data: pendientes = [], isLoading: cargandoPendientes } = useJornadaDetalleQuery(
    null,
    preventistaId,
    mostrarPendientes && Boolean(data?.pendientes.total),
  )

  const diasVisibles = useMemo(() => {
    if (!data) return []
    if (filtro === 'pendientes') return []
    if (filtro === 'entregados') return data.dias.filter(d => d.entregados > 0)
    if (filtro === 'rechazados') return data.dias.filter(d => d.rechazados > 0)
    // Un día que sólo tuvo cancelaciones administrativas no le dice nada al
    // preventista: no hubo ningún cliente esperando mercadería.
    return data.dias.filter(d => d.total - d.administrativos > 0)
  }, [data, filtro])

  if (error) {
    const msg = (error as { code?: string; message?: string })
    return (
      <div className="max-w-3xl mx-auto">
        <EmptyState
          icon={PackageX}
          title={msg.code === '42501' ? 'No tenés permiso para ver este panel' : 'No se pudo cargar'}
          description={msg.code === '42501' ? undefined : msg.message}
        />
      </div>
    )
  }

  return (
    <div className="max-w-3xl mx-auto space-y-4">
      <div>
        <h1 className="text-xl font-bold text-gray-900 dark:text-gray-100">
          {puedeElegirPreventista && data?.nombre ? `Entregas de ${data.nombre}` : 'Mis entregas'}
        </h1>
        <p className="text-sm text-gray-500 dark:text-gray-400 mt-0.5">
          Qué pasó con los pedidos que tomaste, día por día.
        </p>
      </div>

      {puedeElegirPreventista && preventistas.length > 0 && (
        <select
          value={preventistaId ?? ''}
          onChange={e => setPreventistaId(e.target.value || null)}
          className="w-full sm:w-auto h-9 px-3 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 text-sm text-gray-900 dark:text-gray-100"
          aria-label="Elegir preventista"
        >
          <option value="">Mis pedidos</option>
          {preventistas.map(p => (
            <option key={p.id} value={p.id}>{p.nombre}</option>
          ))}
        </select>
      )}

      <div className="flex flex-wrap gap-2">
        {PERIODOS.map(p => (
          <button
            key={p.dias}
            type="button"
            onClick={() => setDias(p.dias)}
            aria-pressed={dias === p.dias}
            className={`h-8 px-3 rounded-lg text-sm font-medium transition-colors ${
              dias === p.dias
                ? 'bg-blue-600 text-white'
                : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-600'
            }`}
          >
            {p.label}
          </button>
        ))}
      </div>

      {data && (
        <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-4">
          <div className="grid grid-cols-3 gap-3 text-center">
            <div>
              <p className="text-lg font-bold text-emerald-600 dark:text-emerald-400 tabular-nums">
                {data.totales.entregados}
              </p>
              <p className="text-xs text-gray-500 dark:text-gray-400">entregados</p>
            </div>
            <div>
              <p className="text-lg font-bold text-red-600 dark:text-red-400 tabular-nums">
                {data.totales.rechazados}
              </p>
              <p className="text-xs text-gray-500 dark:text-gray-400">no entregados</p>
            </div>
            <div>
              <p className="text-lg font-bold text-gray-700 dark:text-gray-200 tabular-nums">
                {data.totales.pct_rechazo}%
              </p>
              <p className="text-xs text-gray-500 dark:text-gray-400">de rechazo</p>
            </div>
          </div>
          {data.totales.monto_rechazado > 0 && (
            <p className="mt-2 text-center text-xs text-gray-500 dark:text-gray-400 tabular-nums">
              {formatPrecio(data.totales.monto_rechazado)} que no llegaron a destino
            </p>
          )}
        </div>
      )}

      <div className="flex flex-wrap gap-2">
        {FILTROS.map(f => (
          <button
            key={f}
            type="button"
            onClick={() => setFiltro(f)}
            aria-pressed={filtro === f}
            className={`h-8 px-3 rounded-lg text-sm font-medium transition-colors ${
              filtro === f
                ? 'bg-gray-900 dark:bg-gray-100 text-white dark:text-gray-900'
                : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-600'
            }`}
          >
            {LABEL_FILTRO[f]}
            {f === 'pendientes' && data?.pendientes.total ? ` (${data.pendientes.total})` : ''}
          </button>
        ))}
      </div>

      {/* Los colgados van arriba: son los que nadie está mirando. */}
      {mostrarPendientes && data && data.pendientes.total > 0 && (
        <div className="bg-sky-50 dark:bg-sky-900/20 border border-sky-200 dark:border-sky-800/60 rounded-xl p-4">
          <div className="flex items-start gap-2">
            <Clock className="w-4 h-4 shrink-0 mt-0.5 text-sky-600 dark:text-sky-400" aria-hidden="true" />
            <div className="min-w-0 flex-1">
              <p className="text-sm font-semibold text-sky-900 dark:text-sky-100">
                {data.pendientes.total} {data.pendientes.total === 1 ? 'pedido sigue' : 'pedidos siguen'} sin resolver
              </p>
              <p className="text-xs text-sky-700 dark:text-sky-300 mt-0.5 tabular-nums">
                {formatPrecio(data.pendientes.monto)}
                {data.pendientes.mas_viejo && ` · el más viejo es del ${formatFecha(data.pendientes.mas_viejo)}`}
              </p>
              {cargandoPendientes ? (
                <p className="mt-2 text-xs text-sky-700 dark:text-sky-300">Cargando…</p>
              ) : (
                <ul className="mt-2">
                  {pendientes.map(p => (
                    <FilaPedidoDia key={p.pedido_id} pedido={p} mostrarFechaPedido />
                  ))}
                </ul>
              )}
            </div>
          </div>
        </div>
      )}

      {isLoading && (
        <p className="text-sm text-gray-500 dark:text-gray-400">Cargando…</p>
      )}

      {!isLoading && diasVisibles.length === 0 && filtro !== 'pendientes' && (
        <EmptyState
          icon={CalendarDays}
          title="Sin movimientos"
          description={`No hay pedidos tuyos con desenlace en los últimos ${dias} días.`}
        />
      )}

      <div className="space-y-2">
        {diasVisibles.map((d, i) => (
          <TarjetaDia
            key={d.dia}
            resumen={d}
            preventistaId={preventistaId}
            filtro={filtro}
            defaultExpandido={i === 0}
          />
        ))}
      </div>
    </div>
  )
}
