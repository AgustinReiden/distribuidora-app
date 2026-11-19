import { useCallback, useState, type ReactElement } from 'react'
import ConfirmarSalirSinGuardar, { type TextosSalirSinGuardar } from '../components/modals/ConfirmarSalirSinGuardar'

/**
 * Cerrar una ventana que puede tener datos sin guardar (decisión 4 del dueño, #1603).
 *
 * `pedirCierre` es EL camino de cierre de la ventana: la X, Escape y el «atrás» del teléfono llaman a esto y
 * se comportan igual. Sin cambios (`hayCambios` en false) cierra de una; con cambios muestra «Salir sin
 * guardar» (`confirmacion`, que la ventana renderiza ADENTRO) y recién con «Salir igual» llama a `onClose`.
 * Guardar, que cierra por su cuenta con `onClose`, no pasa por acá y no pregunta.
 *
 * «Hay cambios» es que el formulario cambió respecto de como abrió, no que tenga algo cargado: una edición
 * sin tocar no pregunta.
 */
export function useSalirSinGuardar({
  hayCambios,
  onClose,
  textos,
}: {
  hayCambios: boolean
  onClose: () => void
  textos?: TextosSalirSinGuardar
}): { pedirCierre: () => void; confirmacion: ReactElement } {
  const [preguntando, setPreguntando] = useState(false)

  const pedirCierre = useCallback(() => {
    if (hayCambios) setPreguntando(true)
    else onClose()
  }, [hayCambios, onClose])

  const confirmacion = (
    <ConfirmarSalirSinGuardar
      visible={preguntando}
      textos={textos}
      onSeguir={() => setPreguntando(false)}
      onSalir={() => {
        setPreguntando(false)
        onClose()
      }}
    />
  )

  return { pedirCierre, confirmacion }
}
