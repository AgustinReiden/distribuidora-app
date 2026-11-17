/**
 * 1600-b8 (decisión D58 del dueño, #1600): aviso de los pedidos sin sincronizar
 * que quedaron guardados en otra sucursal, con cuántos son y el botón para
 * cambiar a esa sucursal. Desde la activa no se mandan (no van cruzados), y antes
 * el contador marcaba 0 sin decir nada. El texto sale de `avisosColaOtraSucursal`.
 */
import { useState, type ReactElement } from 'react'
import { createPortal } from 'react-dom'
import { CloudOff } from 'lucide-react'
import { useSucursal } from '../../contexts/SucursalContext'
import type { PendientesDeOtraSucursal } from '../../lib/offlineDb'
import { avisosColaOtraSucursal } from '../../utils/colaOtraSucursal'
import { getNoticeRoot } from '../ui/noticeRoot'
import { Button } from '../ui/Button'

export interface AvisoColaOtraSucursalProps {
  pendientes: PendientesDeOtraSucursal[]
}

export default function AvisoColaOtraSucursal({ pendientes }: AvisoColaOtraSucursalProps): ReactElement | null {
  const { sucursales, switchSucursal } = useSucursal()
  const [cambiando, setCambiando] = useState(false)
  const avisos = avisosColaOtraSucursal(pendientes, sucursales)
  if (avisos.length === 0) return null

  const cambiar = async (sucursalId: number): Promise<void> => {
    setCambiando(true)
    try {
      // Si el cambio falla (sin señal, rechazo), lo avisa SucursalContext.
      await switchSucursal(sucursalId)
    } finally {
      setCambiando(false)
    }
  }

  const root = getNoticeRoot()
  const aviso = (
    <div
      role="status"
      className="pointer-events-auto w-full max-w-sm md:w-96 bg-amber-50 dark:bg-amber-900/40 border border-amber-300 dark:border-amber-700 text-amber-900 dark:text-amber-100 p-3 rounded-lg shadow-lg space-y-2"
    >
      {avisos.map(a => (
        <div key={a.sucursalId} className="flex items-start gap-2">
          <CloudOff className="w-4 h-4 mt-0.5 flex-shrink-0" aria-hidden="true" />
          <div className="flex-1 text-sm">
            <p>{a.texto}</p>
            {a.nombre && (
              <Button
                type="button"
                variant="primary"
                size="sm"
                onClick={() => { void cambiar(a.sucursalId) }}
                disabled={cambiando}
                className="mt-2"
              >
                {`Cambiar a ${a.nombre}`}
              </Button>
            )}
          </div>
        </div>
      ))}
    </div>
  )

  return root ? createPortal(aviso, root) : aviso
}
