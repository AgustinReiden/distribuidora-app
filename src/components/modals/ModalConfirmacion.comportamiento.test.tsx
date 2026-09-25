/**
 * Caracterización de ModalConfirmacion: COMPORTAMIENTO, no pintura.
 *
 * Ya existe `ModalConfirmacion.test.jsx`, que asevera clases de Tailwind
 * (`className` contiene `text-red-600`, el overlay por `.bg-black`). Eso es
 * justo lo que el rediseño de UI va a mover, así que este archivo fija lo que
 * NO tenía que cambiar cuando el modal pasó de un `<div className="fixed
 * inset-0">` hecho a mano a un Dialog de Radix (WP-28, con los primitivos de
 * `ui/Dialog`, no con ModalBase, que le agregaría una X):
 *
 *  - qué se ve (título, mensaje, ayuda) por TEXTO,
 *  - qué se puede hacer (confirmar / cancelar) por ROL ARIA,
 *  - con qué argumento vuelve `onConfirm` cuando hay `campoFecha`,
 *  - que el componente es `memo` SIN `key`: se reusa entre confirmaciones
 *    distintas y la fecha tiene que resetearse sola (hay un `useEffect` para
 *    eso, y es lo único que lo sostiene),
 *  - y el contrato de accesibilidad: `role="dialog"`, `aria-modal` (Radix 1.1
 *    no lo pone; el componente lo escribe explícito), nombre = título,
 *    descripción = mensaje.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalConfirmacion, {
  type ModalConfirmacionConfig,
  type ModalConfirmacionCampoFecha,
} from './ModalConfirmacion'
import ModalBase from './ModalBase'

function config(extra: Partial<ModalConfirmacionConfig> = {}): ModalConfirmacionConfig {
  return {
    visible: true,
    tipo: 'danger',
    titulo: 'Eliminar producto',
    mensaje: '¿Eliminar "Aceite 900ml"? Esta acción no se puede deshacer.',
    onConfirm: vi.fn(),
    ...extra,
  }
}

const CAMPO_FECHA: ModalConfirmacionCampoFecha = {
  label: 'Fecha de entrega',
  valorInicial: '2026-09-17',
  max: '2026-09-17',
  ayuda: 'Si estás cargando la entrega de un día anterior, cambiala.',
}

describe('ModalConfirmacion — cuándo aparece', () => {
  it('no monta ningún diálogo cuando la config es null', () => {
    render(<ModalConfirmacion config={null} onClose={vi.fn()} />)

    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('no monta ningún diálogo cuando visible es false', () => {
    render(<ModalConfirmacion config={config({ visible: false })} onClose={vi.fn()} />)

    expect(screen.queryByRole('dialog')).toBeNull()
    expect(screen.queryByText('Eliminar producto')).toBeNull()
  })

  it('muestra el título y el mensaje que le pasaron', () => {
    render(<ModalConfirmacion config={config()} onClose={vi.fn()} />)

    expect(screen.getByRole('heading', { name: 'Eliminar producto' })).toBeInTheDocument()
    expect(screen.getByText(/esta acción no se puede deshacer/i)).toBeVisible()
  })
})

describe('ModalConfirmacion — accesibilidad del diálogo', () => {
  it('es un dialog modal cuyo nombre accesible es el título', () => {
    render(<ModalConfirmacion config={config()} onClose={vi.fn()} />)

    const dialogo = screen.getByRole('dialog', { name: 'Eliminar producto' })
    expect(dialogo).toHaveAttribute('aria-modal', 'true')
  })

  it('describe el diálogo con el mensaje', () => {
    render(<ModalConfirmacion config={config()} onClose={vi.fn()} />)

    expect(screen.getByRole('dialog')).toHaveAccessibleDescription(
      '¿Eliminar "Aceite 900ml"? Esta acción no se puede deshacer.',
    )
  })

  it('ofrece exactamente los botones Cancelar y Confirmar, los dos habilitados', () => {
    render(<ModalConfirmacion config={config()} onClose={vi.fn()} />)

    const botones = screen.getAllByRole('button')
    expect(botones.map(b => b.textContent)).toEqual(['Cancelar', 'Confirmar'])
    botones.forEach(b => expect(b).toBeEnabled())
  })
})

describe('ModalConfirmacion — qué dispara cada botón', () => {
  it('Confirmar llama onConfirm y no cierra por su cuenta', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    const onClose = vi.fn()
    render(<ModalConfirmacion config={config({ onConfirm })} onClose={onClose} />)

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    expect(onConfirm).toHaveBeenCalledTimes(1)
    // Sin `campoFecha` el argumento es `undefined`, no un string vacío: quien
    // escucha distingue "no hay fecha" de "fecha vacía".
    expect(onConfirm).toHaveBeenCalledWith(undefined)
    expect(onClose).not.toHaveBeenCalled()
  })

  it('Cancelar llama onClose y no confirma nada', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    const onClose = vi.fn()
    render(<ModalConfirmacion config={config({ onConfirm })} onClose={onClose} />)

    await user.click(screen.getByRole('button', { name: 'Cancelar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onConfirm).not.toHaveBeenCalled()
  })

  // El modal hecho a mano no cerraba con Escape: la única salida era "Cancelar".
  // Desde que es un Dialog de Radix (WP-28, #721) Escape equivale a Cancelar.
  it('Escape equivale a Cancelar: llama onClose y no confirma nada', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    const onClose = vi.fn()
    render(<ModalConfirmacion config={config({ onConfirm })} onClose={onClose} />)

    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('un clic en el fondo, fuera de la caja, no cierra ni confirma', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    const onClose = vi.fn()
    render(<ModalConfirmacion config={config({ onConfirm })} onClose={onClose} />)

    // Radix engancha su listener de "clic afuera" un tick después de montar.
    await new Promise(resolve => setTimeout(resolve, 0))
    // El fondo oscuro es el hermano anterior de la caja del diálogo.
    const fondo = screen.getByRole('dialog').previousElementSibling as HTMLElement
    expect(fondo).toBeInTheDocument()
    expect(screen.getByRole('dialog')).not.toContainElement(fondo)
    await user.click(fondo)

    expect(onClose).not.toHaveBeenCalled()
    expect(onConfirm).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog', { name: 'Eliminar producto' })).toBeInTheDocument()
  })
})

describe('ModalConfirmacion — foco', () => {
  it('al abrir, el foco arranca en Cancelar', () => {
    render(<ModalConfirmacion config={config()} onClose={vi.fn()} />)

    expect(screen.getByRole('button', { name: 'Cancelar' })).toHaveFocus()
  })

  it('con campo de fecha el foco también arranca en Cancelar, no en el input', () => {
    render(<ModalConfirmacion config={config({ campoFecha: CAMPO_FECHA })} onClose={vi.fn()} />)

    expect(screen.getByRole('button', { name: 'Cancelar' })).toHaveFocus()
    expect(screen.getByLabelText('Fecha de entrega')).not.toHaveFocus()
  })

  it('Tab recorre sólo el diálogo y vuelve a empezar', async () => {
    const user = userEvent.setup()
    render(<ModalConfirmacion config={config({ campoFecha: CAMPO_FECHA })} onClose={vi.fn()} />)

    // Arranca en Cancelar. Después de Confirmar, el último, no se va al resto
    // de la página: vuelve al primero del diálogo, el input de fecha.
    await user.tab()
    expect(screen.getByRole('button', { name: 'Confirmar' })).toHaveFocus()
    await user.tab()
    expect(screen.getByLabelText('Fecha de entrega')).toHaveFocus()
    await user.tab()
    expect(screen.getByRole('button', { name: 'Cancelar' })).toHaveFocus()
  })
})

describe('ModalConfirmacion — anidada dentro de un ModalBase', () => {
  // 8 de los 15 usos renderizan la confirmación ADENTRO de un ModalBase. Las dos
  // son Dialogs de Radix y la confirmación queda como la capa de arriba.
  function renderAnidada() {
    const onCloseModal = vi.fn()
    const onCloseConfirmacion = vi.fn()
    const onConfirm = vi.fn()
    render(
      <ModalBase title="Editar pedido" onClose={onCloseModal}>
        <p>Contenido del modal de abajo</p>
        <ModalConfirmacion config={config({ onConfirm })} onClose={onCloseConfirmacion} />
      </ModalBase>,
    )
    return { onCloseModal, onCloseConfirmacion, onConfirm }
  }

  it('Escape cierra sólo la confirmación, no el modal de abajo', async () => {
    const user = userEvent.setup()
    const { onCloseModal, onCloseConfirmacion, onConfirm } = renderAnidada()

    await user.keyboard('{Escape}')

    expect(onCloseConfirmacion).toHaveBeenCalledTimes(1)
    expect(onCloseModal).not.toHaveBeenCalled()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('Confirmar queda por encima del modal de abajo y es clickeable', async () => {
    const user = userEvent.setup()
    const { onCloseModal, onCloseConfirmacion, onConfirm } = renderAnidada()

    // `userEvent` respeta pointer-events y aria-hidden: si la confirmación
    // quedara detrás del overlay del ModalBase, esto falla.
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    expect(onConfirm).toHaveBeenCalledTimes(1)
    expect(onCloseConfirmacion).not.toHaveBeenCalled()
    expect(onCloseModal).not.toHaveBeenCalled()
  })
})

describe('ModalConfirmacion — campo de fecha', () => {
  it('muestra el input con su etiqueta, el valor inicial, el máximo y la ayuda', () => {
    render(<ModalConfirmacion config={config({ campoFecha: CAMPO_FECHA })} onClose={vi.fn()} />)

    const input = screen.getByLabelText('Fecha de entrega')
    expect(input).toHaveValue('2026-09-17')
    expect(input).toHaveAttribute('max', '2026-09-17')
    expect(screen.getByText(/cargando la entrega de un día anterior/i)).toBeVisible()
  })

  it('onConfirm recibe la fecha elegida, no la inicial', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    render(
      <ModalConfirmacion config={config({ campoFecha: CAMPO_FECHA, onConfirm })} onClose={vi.fn()} />,
    )

    const input = screen.getByLabelText('Fecha de entrega')
    await user.clear(input)
    await user.type(input, '2026-09-15')
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    expect(onConfirm).toHaveBeenCalledWith('2026-09-15')
  })

  it('no deja confirmar con la fecha vacía', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    render(
      <ModalConfirmacion config={config({ campoFecha: CAMPO_FECHA, onConfirm })} onClose={vi.fn()} />,
    )

    await user.clear(screen.getByLabelText('Fecha de entrega'))

    expect(screen.getByRole('button', { name: 'Confirmar' })).toBeDisabled()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('reusado con OTRA config, la fecha arranca en el nuevo valor inicial', async () => {
    const user = userEvent.setup()
    const { rerender } = render(
      <ModalConfirmacion config={config({ campoFecha: CAMPO_FECHA })} onClose={vi.fn()} />,
    )

    await user.clear(screen.getByLabelText('Fecha de entrega'))
    await user.type(screen.getByLabelText('Fecha de entrega'), '2026-09-02')
    expect(screen.getByLabelText('Fecha de entrega')).toHaveValue('2026-09-02')

    // Otra confirmación, el MISMO componente montado: es `memo` sin `key`, así
    // que si el efecto de reseteo desaparece la fecha de la anterior queda pegada.
    rerender(
      <ModalConfirmacion
        config={config({
          titulo: 'Confirmar entrega',
          mensaje: '¿Confirmar entrega del pedido #42?',
          campoFecha: { ...CAMPO_FECHA, valorInicial: '2026-09-16' },
        })}
        onClose={vi.fn()}
      />,
    )

    expect(screen.getByLabelText('Fecha de entrega')).toHaveValue('2026-09-16')
    expect(screen.getByRole('heading', { name: 'Confirmar entrega' })).toBeInTheDocument()
  })

  it('cerrar y volver a abrir con el mismo valor inicial también resetea la fecha', async () => {
    const user = userEvent.setup()
    const props = { config: config({ campoFecha: CAMPO_FECHA }), onClose: vi.fn() }
    const { rerender } = render(<ModalConfirmacion {...props} />)

    await user.clear(screen.getByLabelText('Fecha de entrega'))
    await user.type(screen.getByLabelText('Fecha de entrega'), '2026-09-02')

    rerender(
      <ModalConfirmacion
        config={config({ visible: false, campoFecha: CAMPO_FECHA })}
        onClose={vi.fn()}
      />,
    )
    rerender(<ModalConfirmacion config={config({ campoFecha: CAMPO_FECHA })} onClose={vi.fn()} />)

    expect(screen.getByLabelText('Fecha de entrega')).toHaveValue('2026-09-17')
  })
})
