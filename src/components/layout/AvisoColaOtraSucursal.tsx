/**
 * 1600-b8 (decisión D58 del dueño, #1600): aviso de los pedidos sin sincronizar
 * que quedaron guardados en otra sucursal, con cuántos son y el botón para
 * cambiar a esa sucursal. Desde la activa no se mandan (no van cruzados), y antes
 * el contador marcaba 0 sin decir nada. El texto sale de `avisosColaOtraSucursal`.
 *
 * H5 de la revisión de B12a: se puede cerrar (vuelve si cambia la cuenta); a una
 * sucursal inactiva o que ya no es del usuario no se le ofrece el cambio; y
 * después de cambiar, la app se queda en esa sucursal y lo dice.
 */
import { useMemo, useState, type ReactElement } from 'react'
import { createPortal } from 'react-dom'
import { CloudOff, X } from 'lucide-react'
import { useSucursal } from '../../contexts/SucursalContext'
import { useNotification } from '../../contexts/NotificationContext'
import { useSucursalesActivasQuery } from '../../hooks/queries/useSucursalesActivasQuery'
import type { PendientesDeOtraSucursal } from '../../lib/offlineDb'
import { avisosColaOtraSucursal, firmaColaOtraSucursal, mensajeQuedasteEnSucursal } from '../../utils/colaOtraSucursal'
import { getSucursalHeader } from '../../lib/supabase'
import { getNoticeRoot } from '../ui/noticeRoot'
import { Button } from '../ui/Button'

export interface AvisoColaOtraSucursalProps {
  pendientes: PendientesDeOtraSucursal[]
}

export default function AvisoColaOtraSucursal({ pendientes = [] }: Partial<AvisoColaOtraSucursalProps>): ReactElement | null {
  // Sin nada que avisar no se monta el resto (ni la consulta de sucursales activas).
  if (!pendientes.some(p => p.pendientes + p.fallidos > 0)) return null
  return <AvisoConPendientes pendientes={pendientes} />
}

function AvisoConPendientes({ pendientes }: AvisoColaOtraSucursalProps): ReactElement | null {
  const { sucursales, switchSucursal } = useSucursal()
  const notify = useNotification()
  const { data: sucursalesActivas } = useSucursalesActivasQuery()
  const [cambiando, setCambiando] = useState(false)
  const [rechazadas, setRechazadas] = useState<ReadonlySet<number>>(() => new Set())
  // La X lo esconde mientras la cuenta sea la misma (H5).
  const [cerradoCon, setCerradoCon] = useState<string | null>(null)

  const activas = useMemo(
    () => (sucursalesActivas ? new Set(sucursalesActivas.map(s => s.id)) : null),
    [sucursalesActivas],
  )
  const avisos = avisosColaOtraSucursal(pendientes, sucursales, activas, rechazadas)
  const firma = firmaColaOtraSucursal(pendientes)
  if (avisos.length === 0 || cerradoCon === firma) return null

  const cambiar = async (sucursalId: number, nombre: string): Promise<void> => {
    setCambiando(true)
    try {
      // Si el cambio falla (sin señal, rechazo), lo avisa SucursalContext.
      await switchSucursal(sucursalId)
    } finally {
      setCambiando(false)
    }
    // Rechazado (sucursal inactiva, sin acceso): no se vuelve a ofrecer. El
    // header lo fija `switchSucursal` sólo cuando el servidor confirmó el cambio.
    if (getSucursalHeader() !== sucursalId) {
      setRechazadas(prev => new Set([...prev, sucursalId]))
      return
    }
    // La app se queda en esa sucursal (no vuelve sola) y lo dice.
    notify.info(mensajeQuedasteEnSucursal(nombre), { persist: true })
  }

  const root = getNoticeRoot()
  const aviso = (
    <div
      role="status"
      className="pointer-events-auto w-full max-w-sm md:w-96 bg-amber-50 dark:bg-amber-900/40 border border-amber-300 dark:border-amber-700 text-amber-900 dark:text-amber-100 p-3 rounded-lg shadow-lg"
    >
      <div className="flex items-start gap-2">
        <CloudOff className="w-4 h-4 mt-0.5 flex-shrink-0" aria-hidden="true" />
        <div className="flex-1 space-y-2 text-sm">
          {avisos.map(a => (
            <div key={a.sucursalId}>
              {a.lineas.map(linea => <p key={linea}>{linea}</p>)}
              {a.puedeCambiar && a.nombre && (
                <Button
                  type="button"
                  variant="primary"
                  size="sm"
                  onClick={() => { void cambiar(a.sucursalId, a.nombre as string) }}
                  disabled={cambiando}
                  className="mt-2"
                >
                  {`Cambiar a ${a.nombre}`}
                </Button>
              )}
            </div>
          ))}
        </div>
        <button
          type="button"
          onClick={() => setCerradoCon(firma)}
          className="p-1 rounded hover:bg-amber-100 dark:hover:bg-amber-800"
          aria-label="Cerrar aviso de pedidos en otra sucursal"
        >
          <X className="w-4 h-4" />
        </button>
      </div>
    </div>
  )

  return root ? createPortal(aviso, root) : aviso
}
