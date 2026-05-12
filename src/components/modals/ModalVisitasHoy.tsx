/**
 * Modal "Visitas del día".
 *
 * Lista cronológica de las visitas que el preventista marcó hoy. Pensado
 * para que pueda ver de un vistazo a qué clientes ya pasó y cuáles le
 * faltan, sin tener que abrir el panel admin (que no ve).
 *
 * Datos vienen del RPC `listar_visitas_hoy` (scope al preventista logueado
 * + sucursal activa).
 */
import React from 'react'
import { Loader2, MapPin, Clock, AlertCircle } from 'lucide-react'
import ModalBase from './ModalBase'
import { useVisitasHoyQuery } from '../../hooks/queries'
import { formatHora } from '../../utils/formatters'
import { clasificarDistancia, formatDistancia, SEMAFORO_COLORS } from '../../utils/geo'

interface ModalVisitasHoyProps {
  userId: string | null
  onClose: () => void
}

export default function ModalVisitasHoy({ userId, onClose }: ModalVisitasHoyProps): React.ReactElement {
  const { data: visitas = [], isLoading, error } = useVisitasHoyQuery(userId, { enabled: !!userId })

  return (
    <ModalBase title="Visitas del día" onClose={onClose} maxWidth="max-w-lg">
      {isLoading ? (
        <div className="py-12 flex items-center justify-center text-gray-500">
          <Loader2 className="w-5 h-5 mr-2 animate-spin" />
          Cargando…
        </div>
      ) : error ? (
        <div className="rounded-lg border border-red-200 bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-300 px-4 py-3 text-sm">
          Error: {(error as Error).message}
        </div>
      ) : visitas.length === 0 ? (
        <div className="py-12 text-center text-sm text-gray-500 dark:text-gray-400">
          <MapPin className="w-6 h-6 mx-auto mb-2 opacity-40" />
          Todavía no marcaste ninguna visita hoy.
        </div>
      ) : (
        <>
          <p className="text-xs text-gray-500 dark:text-gray-400 mb-3">
            {visitas.length} visita{visitas.length === 1 ? '' : 's'} marcada{visitas.length === 1 ? '' : 's'} hoy. Ordenadas por hora.
          </p>
          <ol className="divide-y divide-gray-100 dark:divide-gray-700 rounded-lg border border-gray-200 dark:border-gray-700 max-h-[60vh] overflow-y-auto">
            {visitas.map((v, idx) => {
              const sinGps = v.gps_status !== 'ok'
              const clasif = clasificarDistancia(v.distancia_m)
              const cfg = SEMAFORO_COLORS[clasif]
              return (
                <li key={v.visita_id} className="px-3 py-2.5 flex items-start gap-3">
                  <span className="shrink-0 w-7 h-7 rounded-full bg-blue-100 dark:bg-blue-900/40 text-blue-700 dark:text-blue-300 flex items-center justify-center text-xs font-semibold">
                    {idx + 1}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <p className="text-sm font-medium text-gray-900 dark:text-white truncate">
                        {v.cliente_nombre || 'Cliente sin nombre'}
                      </p>
                      <span className="shrink-0 text-xs text-gray-500 dark:text-gray-400 inline-flex items-center gap-1">
                        <Clock className="w-3 h-3" />
                        {formatHora(v.created_at)}
                      </span>
                    </div>
                    {v.cliente_direccion && (
                      <p className="text-xs text-gray-500 dark:text-gray-400 truncate mt-0.5">
                        {v.cliente_direccion}
                      </p>
                    )}
                    <div className="mt-1">
                      {sinGps ? (
                        <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full ${SEMAFORO_COLORS.sin_dato.bg}`}>
                          <AlertCircle className="w-3 h-3" />
                          Sin GPS
                        </span>
                      ) : (
                        <span className={`inline-flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-full ${cfg.bg}`} title={cfg.label}>
                          <MapPin className="w-3 h-3" />
                          {formatDistancia(v.distancia_m)}
                        </span>
                      )}
                    </div>
                  </div>
                </li>
              )
            })}
          </ol>
        </>
      )}
    </ModalBase>
  )
}
