/**
 * BottomSheet: el default de siempre (tocar afuera cierra, sin extra en el
 * header, sin aria-modal, sin devolver el foco, sin mirar el teclado: así lo usa
 * ModalFiltrosPedidos) y lo que sumó WP-46 (#771) para el alta de pedido, todo
 * opcional: `headerExtra`, `cerrarAlTocarAfuera={false}`, `comoDialogo`
 * (aria-modal y devolución del foco al que abrió) y `ajustarTeclado` (el sheet
 * apoyado sobre el teclado virtual).
 */
import { useState } from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent, { PointerEventsCheckLevel } from '@testing-library/user-event'
import BottomSheet, { type BottomSheetProps } from './BottomSheet'

function renderSheet(props: Partial<BottomSheetProps> = {}) {
  const onClose = vi.fn()
  const utils = render(
    <BottomSheet open onClose={onClose} title="Filtros" {...props}>
      <p>Contenido</p>
    </BottomSheet>,
  )
  return { onClose, ...utils }
}

/** El overlay de Radix: sin rol ni nombre, es el hermano anterior del panel. */
function overlay(): HTMLElement {
  const nodo = screen.getByRole('dialog').previousElementSibling
  expect(nodo).toBeInstanceOf(HTMLElement)
  return nodo as HTMLElement
}

// delay: 0 a propósito: Radix registra el "pointerdown afuera" con un
// setTimeout(0) tras montar, y el clic tiene que llegar después (setup.js pone
// delay: null por default).
const userSinChequeoDePointerEvents = () =>
  userEvent.setup({ delay: 0, pointerEventsCheck: PointerEventsCheckLevel.Never })

describe('BottomSheet — default (lo que ya usaba ModalFiltrosPedidos)', () => {
  it('tocar el overlay cierra', async () => {
    const user = userSinChequeoDePointerEvents()
    const { onClose } = renderSheet()

    await user.click(overlay())

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('Escape y la X cierran', async () => {
    const user = userEvent.setup()
    const { onClose } = renderSheet()

    await user.keyboard('{Escape}')
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onClose).toHaveBeenCalledTimes(2)
  })

  it('sin headerExtra el header sólo tiene el título y la X', () => {
    renderSheet()

    const titulo = screen.getByRole('heading', { name: 'Filtros' })
    const header = titulo.parentElement!.parentElement!
    expect(header.children).toHaveLength(2)
    expect(within(header).getAllByRole('button')).toHaveLength(1)
  })

  it('es un diálogo con nombre y descripción, y sin aria-modal (como hasta hoy)', () => {
    renderSheet({ description: '3 filtros activos' })

    const dialogo = screen.getByRole('dialog', { name: 'Filtros' })
    expect(dialogo).not.toHaveAttribute('aria-modal')
    expect(dialogo).toHaveAccessibleDescription('3 filtros activos')
  })

  it('con comoDialogo es un diálogo modal', () => {
    renderSheet({ comoDialogo: true })

    expect(screen.getByRole('dialog', { name: 'Filtros' })).toHaveAttribute('aria-modal', 'true')
  })

  it('sin descripción no apunta a un aria-describedby que no existe', () => {
    renderSheet()

    expect(screen.getByRole('dialog')).not.toHaveAttribute('aria-describedby')
  })
})

describe('BottomSheet — headerExtra', () => {
  it('se renderiza en el header, entre el título y la X, y funciona', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    renderSheet({
      headerExtra: (
        <select aria-label="Tipo de factura" defaultValue="ZZ" onChange={e => onChange(e.target.value)}>
          <option value="ZZ">ZZ</option>
          <option value="FC">FC</option>
        </select>
      ),
    })

    const titulo = screen.getByRole('heading', { name: 'Filtros' })
    const header = titulo.parentElement!.parentElement!
    const extra = within(header).getByRole('combobox', { name: 'Tipo de factura' })
    const cerrar = within(header).getByRole('button', { name: 'Cerrar' })
    // Orden en el DOM: título → extra → X.
    expect(titulo.compareDocumentPosition(extra) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(extra.compareDocumentPosition(cerrar) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()

    await user.selectOptions(extra, 'FC')
    expect(onChange).toHaveBeenCalledWith('FC')
  })
})

describe('BottomSheet — cerrarAlTocarAfuera={false}', () => {
  it('tocar el overlay NO cierra', async () => {
    const user = userSinChequeoDePointerEvents()
    const { onClose } = renderSheet({ cerrarAlTocarAfuera: false })

    await user.click(overlay())

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog', { name: 'Filtros' })).toBeInTheDocument()
  })

  it('Escape y la X siguen cerrando', async () => {
    const user = userEvent.setup()
    const { onClose } = renderSheet({ cerrarAlTocarAfuera: false })

    await user.keyboard('{Escape}')
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onClose).toHaveBeenCalledTimes(2)
  })
})

describe('BottomSheet — el foco que sale del panel no cierra', () => {
  // El alta de pedido tiene cosas que se pintan FUERA del panel (el dropdown de
  // autocompletado de dirección, un aviso) y que pueden llevarse el foco. Para
  // Radix eso es "interacción afuera"; el Dialog MODAL (el que usa el sheet) ya
  // la cancela él solo (react-dialog 1.1.15, DialogContentModal.onFocusOutside),
  // así que el resultado es el mismo con `cerrarAlTocarAfuera` en true o en
  // false: no cierra. Este test no ejercita la prop sino el comportamiento: si
  // el sheet dejara de ser modal, o Radix cambiara eso, el alta con el carrito
  // armado se cerraría con el foco.
  it.each([true, false])('con cerrarAlTocarAfuera={%s}, que el foco salga del panel NO cierra', (valor) => {
    const onClose = vi.fn()
    render(
      <>
        <input aria-label="Afuera" data-testid="afuera" />
        <BottomSheet open onClose={onClose} title="Filtros" cerrarAlTocarAfuera={valor}>
          <input aria-label="Adentro" />
        </BottomSheet>
      </>,
    )

    act(() => screen.getByTestId('afuera').focus())

    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog', { name: 'Filtros' })).toBeInTheDocument()
  })
})

describe('BottomSheet — foco', () => {
  function ConDisparador({ comoDialogo }: { comoDialogo?: boolean }) {
    const [abierto, setAbierto] = useState(false)
    return (
      <>
        <button type="button" onClick={() => setAbierto(true)}>
          Abrir filtros
        </button>
        <BottomSheet
          open={abierto}
          onClose={() => setAbierto(false)}
          title="Filtros"
          comoDialogo={comoDialogo}
        >
          <input aria-label="Buscar" />
        </BottomSheet>
      </>
    )
  }

  it('por defecto no toca el foco al cerrar (como hasta hoy: Radix lo deja en <body>)', async () => {
    const user = userEvent.setup()
    render(<ConDisparador />)
    const disparador = screen.getByRole('button', { name: 'Abrir filtros' })

    await user.click(disparador)
    await user.keyboard('{Escape}')

    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(disparador).not.toHaveFocus()
  })

  it('con comoDialogo, al cerrar le devuelve el foco al que lo abrió', async () => {
    const user = userEvent.setup()
    render(<ConDisparador comoDialogo />)
    const disparador = screen.getByRole('button', { name: 'Abrir filtros' })

    await user.click(disparador)
    expect(screen.getByRole('dialog')).toContainElement(document.activeElement as HTMLElement)

    await user.keyboard('{Escape}')

    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    await waitFor(() => expect(disparador).toHaveFocus())
  })
})

describe('BottomSheet — teclado virtual', () => {
  const descriptor = Object.getOwnPropertyDescriptor(window, 'visualViewport')
  const innerHeightOriginal = window.innerHeight

  afterEach(() => {
    if (descriptor) Object.defineProperty(window, 'visualViewport', descriptor)
    else delete (window as { visualViewport?: unknown }).visualViewport
    Object.defineProperty(window, 'innerHeight', { configurable: true, value: innerHeightOriginal })
  })

  /** Un visualViewport de mentira: 800 px de alto, sin teclado. */
  function instalarViewport() {
    const vv = Object.assign(new EventTarget(), { height: 800, offsetTop: 0, scale: 1 })
    Object.defineProperty(window, 'innerHeight', { configurable: true, value: 800 })
    Object.defineProperty(window, 'visualViewport', { configurable: true, value: vv })
    return {
      abrirTeclado(alto: number) {
        act(() => {
          vv.height = 800 - alto
          vv.dispatchEvent(new Event('resize'))
        })
      },
      cerrarTeclado() {
        act(() => {
          vv.height = 800
          vv.dispatchEvent(new Event('resize'))
        })
      },
      zoom(escala: number) {
        act(() => {
          vv.scale = escala
          vv.height = 800 / escala
          vv.dispatchEvent(new Event('resize'))
        })
      },
    }
  }

  it('el zoom de dos dedos no se toma por teclado: el sheet no se mueve', () => {
    const viewport = instalarViewport()
    renderSheet({ maxHeight: '92dvh', bodyBare: true, ajustarTeclado: true })
    const panel = screen.getByRole('dialog')

    viewport.zoom(2)

    expect(panel.style.bottom).toBe('')
    expect(panel.style.maxHeight).toBe('92dvh')
  })

  it('sin teclado queda pegado al fondo con su maxHeight', () => {
    instalarViewport()
    renderSheet({ maxHeight: '92dvh', ajustarTeclado: true })

    const panel = screen.getByRole('dialog')
    expect(panel.style.maxHeight).toBe('92dvh')
    expect(panel.style.bottom).toBe('')
  })

  it('con el teclado abierto se apoya encima y no pasa del alto visible; al cerrarlo vuelve', () => {
    const viewport = instalarViewport()
    renderSheet({ maxHeight: '92dvh', bodyBare: true, ajustarTeclado: true })
    const panel = screen.getByRole('dialog')

    viewport.abrirTeclado(300)

    expect(panel.style.bottom).toBe('300px')
    // 800 − 300 visibles, menos 8 px de aire arriba.
    expect(panel.style.maxHeight).toBe('492px')
    expect(panel.style.height).toBe('492px')

    viewport.cerrarTeclado()

    expect(panel.style.bottom).toBe('')
    expect(panel.style.maxHeight).toBe('92dvh')
    expect(panel.style.height).toBe('92dvh')
  })

  it('por defecto ni mira el teclado: el sheet queda como hasta hoy (ModalFiltrosPedidos)', () => {
    const viewport = instalarViewport()
    renderSheet({ maxHeight: '92dvh', bodyBare: true })
    const panel = screen.getByRole('dialog')

    viewport.abrirTeclado(300)

    expect(panel.style.bottom).toBe('')
    expect(panel.style.maxHeight).toBe('92dvh')
  })

  describe('scrollIntoView del campo enfocado', () => {
    const scrollOriginal = Element.prototype.scrollIntoView
    afterEach(() => {
      Element.prototype.scrollIntoView = scrollOriginal
    })

    function montarConInput() {
      const scrollIntoView = vi.fn()
      Element.prototype.scrollIntoView = scrollIntoView
      const viewport = instalarViewport()
      const onClose = vi.fn()
      // Un elemento nuevo en cada llamada: con el mismo, React no re-renderiza.
      const sheet = () => (
        <BottomSheet open onClose={onClose} title="Filtros" ajustarTeclado>
          <input aria-label="Buscar" />
        </BottomSheet>
      )
      const utils = render(sheet())
      act(() => screen.getByRole('textbox', { name: 'Buscar' }).focus())
      return { viewport, scrollIntoView, sheet, ...utils }
    }

    it('corre al abrirse el teclado, y NO en cada re-render mientras sigue abierto', () => {
      const { viewport, scrollIntoView, rerender, sheet } = montarConInput()
      expect(scrollIntoView).not.toHaveBeenCalled()

      viewport.abrirTeclado(300)
      expect(scrollIntoView).toHaveBeenCalledTimes(1)

      // Un re-render del padre (una tecla en el buscador, un refetch): el
      // teclado es el mismo, no hay motivo para devolver el scroll al campo.
      rerender(sheet())
      rerender(sheet())
      expect(scrollIntoView).toHaveBeenCalledTimes(1)
    })

    it('vuelve a correr si el teclado cambia de alto', () => {
      const { viewport, scrollIntoView } = montarConInput()

      viewport.abrirTeclado(300)
      viewport.abrirTeclado(340)

      expect(scrollIntoView).toHaveBeenCalledTimes(2)
    })
  })
})
