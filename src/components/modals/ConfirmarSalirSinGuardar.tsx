import { memo } from 'react'
import ModalConfirmacion from './ModalConfirmacion'

/** Los textos de la pregunta; cada modal puede decir su cosa («El pedido no se guardó»). */
export interface TextosSalirSinGuardar {
  titulo?: string
  mensaje?: string
  textoConfirmar?: string
  textoCancelar?: string
}

export interface ConfirmarSalirSinGuardarProps {
  visible: boolean
  /** «Salir igual»: se descarta lo cargado. */
  onSalir: () => void
  /** «Seguir editando», Escape o el «atrás» del teléfono: se vuelve al formulario. */
  onSeguir: () => void
  textos?: TextosSalirSinGuardar
}

/**
 * La pregunta «¿Salir sin guardar?», una sola para todas las ventanas con datos (decisión 4 del dueño,
 * #1603). Va DENTRO de la ventana (regla del proyecto: una confirmación disparada desde un modal Radix se
 * renderiza adentro, o queda detrás del overlay). Se usa por `useSalirSinGuardar`, que además la dispara
 * igual desde la X, Escape y el «atrás» del teléfono.
 */
export const ConfirmarSalirSinGuardar = memo(function ConfirmarSalirSinGuardar({
  visible,
  onSalir,
  onSeguir,
  textos,
}: ConfirmarSalirSinGuardarProps) {
  return (
    <ModalConfirmacion
      config={visible ? {
        visible: true,
        tipo: 'warning',
        titulo: textos?.titulo ?? 'Salir sin guardar',
        mensaje: textos?.mensaje ?? 'Lo que cargaste todavía no se guardó. ¿Salir igual?',
        textoConfirmar: textos?.textoConfirmar ?? 'Salir igual',
        textoCancelar: textos?.textoCancelar ?? 'Seguir editando',
        onConfirm: onSalir,
      } : null}
      onClose={onSeguir}
    />
  )
})

export default ConfirmarSalirSinGuardar
