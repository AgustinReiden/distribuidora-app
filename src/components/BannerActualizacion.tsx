/**
 * Cartel de "hay una versión nueva". Ver `useActualizacionDisponible` para el
 * porqué: sin service worker la app no se entera sola de los deploys.
 *
 * A diferencia del viejo PWAPrompt (que quedó sin montar desde marzo y sólo se
 * renderizaba fuera del modo standalone), este aparece siempre, también con la
 * app instalada, que es justamente donde la pestaña vive abierta durante
 * semanas.
 *
 * D57 (decisión del dueño, 1563-b8 de #1563): la actualización es obligatoria.
 * El cartel avisa que se va a actualizar sola al cambiar de pantalla o al volver
 * a la app; no hay «Más tarde». La X sólo lo esconde.
 */
import { RefreshCw, X } from 'lucide-react'
import type { ReactElement } from 'react'
import { createPortal } from 'react-dom'
import { useActualizacionDisponible } from '../hooks/useActualizacionDisponible'
import { getNoticeRoot } from './ui/noticeRoot'

export interface BannerActualizacionProps {
  /** La pantalla actual: al cambiar, con una versión nueva esperando, se actualiza (D57). */
  ruta?: string
}

export function BannerActualizacion({ ruta }: BannerActualizacionProps = {}): ReactElement | null {
  const { disponible, actualizando, actualizar, ocultar } = useActualizacionDisponible(ruta)

  if (!disponible) return null

  // La posición la pone la pila de avisos (ver ui/noticeRoot), no este wrapper.
  const root = getNoticeRoot()
  const aviso = (
    <div
      role="status"
      className="pointer-events-auto w-full max-w-sm md:w-96 bg-blue-600 text-white p-4 rounded-lg shadow-lg"
    >
      <div className="flex items-start gap-3">
        <RefreshCw className="w-5 h-5 mt-0.5 flex-shrink-0" />
        <div className="flex-1">
          <p className="font-medium">Hay una versión nueva</p>
          <p className="text-sm text-blue-100 mt-1">
            La app se va a actualizar sola cuando cambies de pantalla o vuelvas a ella. Si estás
            cargando algo, terminalo primero: con un formulario abierto no se actualiza.
          </p>
          <div className="flex gap-2 mt-3">
            <button
              onClick={actualizar}
              disabled={actualizando}
              className="px-3 py-1.5 bg-white text-blue-600 rounded font-medium text-sm hover:bg-blue-50 transition-colors disabled:opacity-70 disabled:cursor-wait"
            >
              {actualizando ? 'Actualizando...' : 'Actualizar'}
            </button>
          </div>
        </div>
        <button
          onClick={ocultar}
          className="p-1 hover:bg-blue-500 rounded"
          aria-label="Cerrar aviso de actualización"
        >
          <X className="w-4 h-4" />
        </button>
      </div>
    </div>
  )

  return root ? createPortal(aviso, root) : aviso
}

export default BannerActualizacion
