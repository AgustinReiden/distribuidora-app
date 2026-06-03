/**
 * Campanita de notificaciones persistentes (DB), por polling.
 *
 * Reemplaza la campanita local (localStorage) en la barra superior: estas
 * notificaciones cruzan usuarios y dispositivos (ej: a la sucursal destino le
 * llega un movimiento pendiente). Los toasts transitorios siguen funcionando
 * aparte (NotificationProvider).
 */
import { memo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Bell, Check, Loader2, CheckCheck } from 'lucide-react'
import { formatDateTime } from '../../utils/formatters'
import {
  useNotificacionesQuery,
  useMarcarNotificacionLeidaMutation,
  useMarcarTodasNotificacionesLeidasMutation,
  type NotificacionDB,
} from '../../hooks/queries'

function rutaDeNotificacion(n: NotificacionDB): string | null {
  if (n.entidad_tipo === 'movimiento_sucursal') return '/transferencias'
  return null
}

const DbNotificationBell = memo(function DbNotificationBell() {
  const navigate = useNavigate()
  const [open, setOpen] = useState(false)
  const { data: notificaciones = [], isLoading } = useNotificacionesQuery()
  const marcarLeida = useMarcarNotificacionLeidaMutation()
  const marcarTodas = useMarcarTodasNotificacionesLeidasMutation()

  const noLeidas = notificaciones.filter(n => !n.leida).length

  const handleClick = (n: NotificacionDB) => {
    if (!n.leida) marcarLeida.mutate(n.id)
    const ruta = rutaDeNotificacion(n)
    setOpen(false)
    if (ruta) navigate(ruta)
  }

  return (
    <div className="relative">
      <button
        onClick={() => setOpen(o => !o)}
        className="relative p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 text-gray-600 dark:text-gray-300"
        aria-label="Notificaciones"
        title="Notificaciones"
      >
        <Bell className="w-5 h-5" />
        {noLeidas > 0 && (
          <span className="absolute -top-0.5 -right-0.5 min-w-[18px] h-[18px] px-1 rounded-full bg-red-500 text-white text-[11px] font-bold flex items-center justify-center">
            {noLeidas > 9 ? '9+' : noLeidas}
          </span>
        )}
      </button>

      {open && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setOpen(false)} aria-hidden />
          <div className="absolute right-0 mt-2 w-80 max-w-[90vw] bg-white dark:bg-gray-800 rounded-xl shadow-lg border dark:border-gray-700 z-50 overflow-hidden">
            <div className="flex items-center justify-between px-4 py-2 border-b dark:border-gray-700">
              <span className="font-semibold text-gray-900 dark:text-white">Notificaciones</span>
              {noLeidas > 0 && (
                <button
                  onClick={() => marcarTodas.mutate()}
                  className="text-xs text-blue-600 hover:underline flex items-center gap-1"
                >
                  <CheckCheck className="w-3.5 h-3.5" /> Marcar todas
                </button>
              )}
            </div>
            <div className="max-h-96 overflow-y-auto divide-y dark:divide-gray-700">
              {isLoading ? (
                <div className="flex items-center justify-center py-6 text-gray-500">
                  <Loader2 className="w-5 h-5 animate-spin" />
                </div>
              ) : notificaciones.length === 0 ? (
                <div className="text-center py-8 text-sm text-gray-500">Sin notificaciones</div>
              ) : (
                notificaciones.map(n => (
                  <button
                    key={n.id}
                    onClick={() => handleClick(n)}
                    className={`w-full text-left px-4 py-3 hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors ${
                      n.leida ? '' : 'bg-blue-50/50 dark:bg-blue-900/10'
                    }`}
                  >
                    <div className="flex items-start gap-2">
                      {!n.leida && <span className="w-2 h-2 rounded-full bg-blue-500 mt-1.5 flex-shrink-0" />}
                      <div className={`min-w-0 ${n.leida ? 'pl-4' : ''}`}>
                        <p className="text-sm font-medium text-gray-900 dark:text-white">{n.titulo}</p>
                        {n.mensaje && <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">{n.mensaje}</p>}
                        <p className="text-[11px] text-gray-400 mt-0.5">{n.created_at && formatDateTime(n.created_at)}</p>
                      </div>
                    </div>
                  </button>
                ))
              )}
            </div>
          </div>
        </>
      )}
    </div>
  )
})

export default DbNotificationBell
