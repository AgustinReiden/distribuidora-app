/**
 * Cartel de "hay una version nueva". Ver `useActualizacionDisponible` para el
 * porque: sin service worker la app no se entera sola de los deploys.
 *
 * A diferencia del viejo PWAPrompt (que quedo sin montar desde marzo y solo se
 * renderizaba fuera del modo standalone), este aparece siempre, tambien con la
 * app instalada, que es justamente donde la pestania vive abierta durante
 * semanas.
 */
import { RefreshCw, X } from 'lucide-react'
import type { ReactElement } from 'react'
import { useActualizacionDisponible } from '../hooks/useActualizacionDisponible'

export function BannerActualizacion(): ReactElement | null {
  const { disponible, actualizar, posponer } = useActualizacionDisponible()

  if (!disponible) return null

  return (
    <div
      role="status"
      className="fixed bottom-4 left-4 right-4 md:left-auto md:right-4 md:w-96 bg-blue-600 text-white p-4 rounded-lg shadow-lg z-50"
    >
      <div className="flex items-start gap-3">
        <RefreshCw className="w-5 h-5 mt-0.5 flex-shrink-0" />
        <div className="flex-1">
          <p className="font-medium">Hay una version nueva</p>
          <p className="text-sm text-blue-100 mt-1">
            Actualiza para no seguir trabajando con pantallas viejas. Si estas
            cargando algo, termina primero.
          </p>
          <div className="flex gap-2 mt-3">
            <button
              onClick={actualizar}
              className="px-3 py-1.5 bg-white text-blue-600 rounded font-medium text-sm hover:bg-blue-50 transition-colors"
            >
              Actualizar
            </button>
            <button
              onClick={posponer}
              className="px-3 py-1.5 text-blue-100 hover:text-white text-sm"
            >
              Mas tarde
            </button>
          </div>
        </div>
        <button
          onClick={posponer}
          className="p-1 hover:bg-blue-500 rounded"
          aria-label="Cerrar aviso de actualizacion"
        >
          <X className="w-4 h-4" />
        </button>
      </div>
    </div>
  )
}

export default BannerActualizacion
