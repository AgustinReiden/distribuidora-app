/**
 * Panel de Movimientos entre Sucursales (con aprobación).
 *
 * Muestra movimientos entrantes (destino = sucursal activa) y salientes
 * (origen = activa). Los pendientes ENTRANTES se pueden Aceptar/Denegar
 * (admin/encargado). Los salientes son solo lectura (esperan aprobación).
 */
import { memo } from 'react'
import { Loader2, ArrowDownLeft, ArrowUpRight, Plus, Check, X, PackageX } from 'lucide-react'
import { formatPrecio, formatDateTime } from '../../utils/formatters'
import type { MovimientoSucursalDB, EstadoMovimiento } from '../../hooks/queries'

type TabEstado = EstadoMovimiento | 'todos'

export interface VistaMovimientosProps {
  movimientos: MovimientoSucursalDB[]
  loading: boolean
  currentSucursalId: number | null
  canResolver: boolean
  estado: TabEstado
  onEstadoChange: (e: TabEstado) => void
  onNuevaSalida: () => void
  onAceptar: (mov: MovimientoSucursalDB) => void
  onDenegar: (mov: MovimientoSucursalDB) => void
}

const TABS: Array<{ value: TabEstado; label: string }> = [
  { value: 'pendiente', label: 'Pendientes' },
  { value: 'aceptada', label: 'Aceptadas' },
  { value: 'denegada', label: 'Denegadas' },
  { value: 'todos', label: 'Todas' },
]

const ESTADO_BADGE: Record<EstadoMovimiento, string> = {
  pendiente: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
  aceptada: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  denegada: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
}

const VistaMovimientos = memo(function VistaMovimientos({
  movimientos, loading, currentSucursalId, canResolver, estado, onEstadoChange,
  onNuevaSalida, onAceptar, onDenegar,
}: VistaMovimientosProps) {
  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between flex-wrap gap-2">
        <h2 className="text-xl font-bold text-gray-900 dark:text-white">Movimientos entre sucursales</h2>
        <button
          onClick={onNuevaSalida}
          className="inline-flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium"
        >
          <Plus className="w-4 h-4" /> Nueva salida
        </button>
      </div>

      {/* Tabs */}
      <div className="flex gap-1 border-b dark:border-gray-700">
        {TABS.map(t => (
          <button
            key={t.value}
            onClick={() => onEstadoChange(t.value)}
            className={`px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors ${
              estado === t.value
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:hover:text-gray-300'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex items-center justify-center py-12 text-gray-500">
          <Loader2 className="w-6 h-6 animate-spin text-blue-600" /><span className="ml-2">Cargando...</span>
        </div>
      ) : movimientos.length === 0 ? (
        <div className="text-center py-12">
          <PackageX className="w-12 h-12 mx-auto text-gray-300 dark:text-gray-600 mb-3" />
          <p className="text-gray-500">No hay movimientos para mostrar</p>
        </div>
      ) : (
        <div className="space-y-3">
          {movimientos.map(mov => {
            const entrante = mov.sucursal_destino_id === currentSucursalId
            const contraparte = entrante ? mov.origen?.nombre : mov.destino?.nombre
            const puedeResolver = entrante && mov.estado === 'pendiente' && canResolver
            return (
              <div key={mov.id} className="bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700 p-4">
                <div className="flex items-start justify-between gap-3 flex-wrap">
                  <div className="flex items-start gap-3 min-w-0">
                    <div className={`w-9 h-9 rounded-full flex items-center justify-center flex-shrink-0 ${
                      entrante ? 'bg-green-100 dark:bg-green-900/30' : 'bg-blue-100 dark:bg-blue-900/30'
                    }`}>
                      {entrante
                        ? <ArrowDownLeft className="w-5 h-5 text-green-600 dark:text-green-400" />
                        : <ArrowUpRight className="w-5 h-5 text-blue-600 dark:text-blue-400" />}
                    </div>
                    <div className="min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="font-semibold text-gray-900 dark:text-white">
                          {entrante ? 'Entrante de' : 'Saliente a'} {contraparte || 'otra sucursal'}
                        </span>
                        <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${ESTADO_BADGE[mov.estado]}`}>
                          {mov.estado}
                        </span>
                        <span className="text-xs text-gray-400">#{mov.id}</span>
                      </div>
                      <p className="text-xs text-gray-500 mt-0.5">
                        {mov.created_at && formatDateTime(mov.created_at)}
                        {mov.creador?.nombre ? ` · ${mov.creador.nombre}` : ''}
                      </p>
                      {mov.notas && <p className="text-xs text-gray-500 italic mt-1">{mov.notas}</p>}
                      {mov.estado === 'denegada' && mov.motivo_rechazo && (
                        <p className="text-xs text-red-500 mt-1">Motivo: {mov.motivo_rechazo}</p>
                      )}
                    </div>
                  </div>
                  <div className="text-right flex-shrink-0">
                    <p className="font-bold text-gray-900 dark:text-white">{formatPrecio(mov.total_costo || 0)}</p>
                    <p className="text-xs text-gray-400">costo total</p>
                  </div>
                </div>

                {puedeResolver && (
                  <div className="flex justify-end gap-2 mt-3 pt-3 border-t dark:border-gray-700">
                    <button
                      onClick={() => onDenegar(mov)}
                      className="inline-flex items-center gap-1.5 px-3 py-2 text-sm rounded-lg bg-red-50 text-red-600 hover:bg-red-100 dark:bg-red-900/20 dark:text-red-400"
                    >
                      <X className="w-4 h-4" /> Denegar
                    </button>
                    <button
                      onClick={() => onAceptar(mov)}
                      className="inline-flex items-center gap-1.5 px-3 py-2 text-sm rounded-lg bg-green-600 text-white hover:bg-green-700"
                    >
                      <Check className="w-4 h-4" /> Aceptar
                    </button>
                  </div>
                )}
                {!entrante && mov.estado === 'pendiente' && (
                  <p className="text-xs text-amber-600 dark:text-amber-400 mt-2 pt-2 border-t dark:border-gray-700">
                    Esperando aprobación de {mov.destino?.nombre || 'la sucursal destino'}.
                  </p>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
})

export default VistaMovimientos
