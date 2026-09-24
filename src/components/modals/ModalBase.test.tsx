import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ReactElement } from 'react'
import ModalBase from './ModalBase'

function Boom(): ReactElement {
  throw new Error('explosion en modal')
}

describe('ModalBase ErrorBoundary', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('muestra fallback en lugar de crashear cuando children tiran', () => {
    // Silenciamos los logs esperados de React al capturar el error en el boundary.
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    // Si no hay boundary, el error no capturado haría que render() lance
    // y el test falle con la excepción. Si lo hay, render() completa y
    // podemos inspeccionar el fallback.
    render(
      <ModalBase onClose={() => {}} title="Test">
        <Boom />
      </ModalBase>
    )

    // El fallback de CompactErrorBoundary para un error UNKNOWN muestra
    // el título "Error inesperado" proveniente de getRecoveryInfo. Este
    // texto SOLO aparece si el boundary atrapó el throw.
    expect(screen.getByText('Error inesperado')).toBeInTheDocument()

    // El mensaje genérico del fallback UNKNOWN también debe estar.
    expect(
      screen.getByText(/ha ocurrido un error inesperado/i)
    ).toBeInTheDocument()

    // El frame del modal (header con el título) sigue presente:
    // el boundary envuelve solo el body, no todo el modal — si el
    // boundary estuviera afuera, al capturar perderíamos el frame.
    expect(screen.getByText('Test')).toBeInTheDocument()

    errSpy.mockRestore()
  })

  it('con bodyBare, un hijo que tira sigue cayendo en el fallback y el header queda', () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    render(
      <ModalBase onClose={() => {}} title="Test bare" bodyBare>
        <Boom />
      </ModalBase>
    )

    const dialogo = screen.getByRole('dialog', { name: 'Test bare' })
    expect(within(dialogo).getByText('Error inesperado')).toBeInTheDocument()
    expect(
      within(dialogo).getByText(/ha ocurrido un error inesperado/i)
    ).toBeInTheDocument()
    // El header (título + X) queda afuera del boundary también con bodyBare.
    // Dos "Cerrar": la X del header y el botón del fallback.
    expect(within(dialogo).getByRole('heading', { name: 'Test bare' })).toBeInTheDocument()
    expect(within(dialogo).getAllByRole('button', { name: 'Cerrar' })).toHaveLength(2)

    errSpy.mockRestore()
  })
})

describe('ModalBase · maxWidth', () => {
  it('max-w-6xl llega al diálogo y reemplaza el ancho por defecto', () => {
    render(
      <ModalBase onClose={() => {}} title="Compra" maxWidth="max-w-6xl">
        <p>cuerpo</p>
      </ModalBase>
    )

    const dialogo = screen.getByRole('dialog', { name: 'Compra' })
    expect(dialogo).toHaveClass('max-w-6xl')
    // El `max-w-md` base de DialogContent no convive con el pedido: si
    // quedaran los dos, el ancho dependería del orden en el CSS.
    expect(dialogo).not.toHaveClass('max-w-md')
  })
})

describe('ModalBase · Escape', () => {
  it('sin onEscapeKeyDown, Escape cierra como siempre (llama onClose)', async () => {
    const user = userEvent.setup()
    const onClose = vi.fn()
    render(
      <ModalBase onClose={onClose} title="Escape por defecto">
        <p>cuerpo</p>
      </ModalBase>
    )

    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('onEscapeKeyDown recibe el Escape y, si no lo previene, el modal cierra igual', async () => {
    const user = userEvent.setup()
    const onClose = vi.fn()
    const onEscapeKeyDown = vi.fn()
    render(
      <ModalBase onClose={onClose} title="Escape observado" onEscapeKeyDown={onEscapeKeyDown}>
        <p>cuerpo</p>
      </ModalBase>
    )

    await user.keyboard('{Escape}')

    expect(onEscapeKeyDown).toHaveBeenCalledTimes(1)
    expect(onEscapeKeyDown.mock.calls[0][0]).toHaveProperty('key', 'Escape')
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('si onEscapeKeyDown hace preventDefault, onClose NO se llama', async () => {
    const user = userEvent.setup()
    const onClose = vi.fn()
    const onEscapeKeyDown = vi.fn((e: KeyboardEvent) => e.preventDefault())
    render(
      <ModalBase onClose={onClose} title="Escape abortado" onEscapeKeyDown={onEscapeKeyDown}>
        <p>cuerpo</p>
      </ModalBase>
    )

    await user.keyboard('{Escape}')

    expect(onEscapeKeyDown).toHaveBeenCalledTimes(1)
    expect(onClose).not.toHaveBeenCalled()
    // Abortar Escape no desarma el resto: la X sigue cerrando.
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

/**
 * Los contenedores con scroll que hay entre el diálogo y `nodo` (sin contar el
 * diálogo ni el propio `nodo`). jsdom no carga Tailwind —`getComputedStyle` no
 * ve ningún overflow—, así que el único rastro de quién scrollea es la utilidad
 * `overflow-*` del className.
 */
function contenedoresConScrollHasta(nodo: HTMLElement, dialogo: HTMLElement): HTMLElement[] {
  const encontrados: HTMLElement[] = []
  let actual = nodo.parentElement
  while (actual && actual !== dialogo) {
    if (/(^|\s)overflow(-y)?-(auto|scroll)(\s|$)/.test(actual.className)) encontrados.push(actual)
    actual = actual.parentElement
  }
  // Si no llegamos al diálogo, el hijo quedó afuera y el resto no significa nada.
  expect(actual).toBe(dialogo)
  return encontrados
}

// El uso previsto de bodyBare: el hijo trae su columna, su área con scroll y un
// footer fijo. Las clases son del hijo (el helper de arriba mira sólo lo que hay
// ENTRE el diálogo y el hijo), no una aserción.
function ContenidoConScrollPropio() {
  return (
    <section aria-label="Contenido propio" className="flex flex-1 min-h-0 flex-col">
      <div className="flex-1 overflow-y-auto">
        {Array.from({ length: 5 }).map((_, i) => (
          <p key={i}>Línea {i + 1}</p>
        ))}
      </div>
      <footer className="flex-shrink-0">
        <button type="button">Cancelar</button>
        <button type="button">Guardar</button>
      </footer>
    </section>
  )
}

describe('ModalBase · bodyBare', () => {
  it('sin bodyBare el cuerpo va dentro de UN contenedor con scroll (como hasta hoy)', () => {
    render(
      <ModalBase onClose={() => {}} title="Cuerpo normal">
        <ContenidoConScrollPropio />
      </ModalBase>
    )

    const dialogo = screen.getByRole('dialog', { name: 'Cuerpo normal' })
    const contenido = within(dialogo).getByRole('region', { name: 'Contenido propio' })
    expect(contenedoresConScrollHasta(contenido, dialogo)).toHaveLength(1)
  })

  it('con bodyBare no hay contenedor con scroll entre el diálogo y el hijo', () => {
    render(
      <ModalBase onClose={() => {}} title="Cuerpo pelado" bodyBare>
        <ContenidoConScrollPropio />
      </ModalBase>
    )

    const dialogo = screen.getByRole('dialog', { name: 'Cuerpo pelado' })
    const contenido = within(dialogo).getByRole('region', { name: 'Contenido propio' })
    expect(contenedoresConScrollHasta(contenido, dialogo)).toHaveLength(0)
    // El footer del hijo sigue adentro del diálogo, al alcance del foco.
    expect(within(contenido).getByRole('button', { name: 'Guardar' })).toBeInTheDocument()
    expect(within(contenido).getByRole('button', { name: 'Cancelar' })).toBeInTheDocument()
  })

  it('con bodyBare el header y el cierre siguen iguales', async () => {
    const user = userEvent.setup()
    const onClose = vi.fn()
    render(
      <ModalBase onClose={onClose} title="Cuerpo pelado" bodyBare>
        <ContenidoConScrollPropio />
      </ModalBase>
    )

    expect(screen.getByRole('heading', { name: 'Cuerpo pelado' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
