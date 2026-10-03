/**
 * El primitivo `DialogContent`: a dónde vuelve el foco al cerrar y `aria-modal`
 * (#800).
 *
 * Radix 1.1.15 devuelve el foco al `Dialog.Trigger`, y en la app nadie usa
 * Trigger: los diálogos se abren con `open`. Sin el arreglo, el foco caía en
 * `<body>` al cerrar. Se cubre por los dos caminos que usan el primitivo:
 * `ModalBase` y un diálogo armado a mano con `Dialog` + `DialogContent`, que es
 * lo que hace `ModalConfirmacion`.
 *
 * FocusScope decide a dónde va el foco en un `setTimeout(0)` después del
 * desmontaje: por eso cada cierre deja correr ese timeout con `act` antes de
 * aseverar. Sin eso, "el foco no volvió" pasaría aunque volviera.
 */
import '@testing-library/jest-dom/vitest'
import { StrictMode, useState, type ReactNode } from 'react'
import { describe, it, expect, vi, beforeAll, afterAll, afterEach } from 'vitest'
import { act, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Dialog, DialogContent, DialogDescription, DialogTitle, type DialogContentProps } from './Dialog'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from './DropdownMenu'
import ModalBase from '../modals/ModalBase'
import ModalConfirmacion from '../modals/ModalConfirmacion'

type Usuario = ReturnType<typeof userEvent.setup>

const dejarCorrerFocusScope = () => act(() => new Promise<void>(resolve => setTimeout(resolve, 0)))

/** Un botón de la vista que abre un ModalBase, como en cualquier container. */
function HostModalBase({ conAutoFocus = false }: { conAutoFocus?: boolean }) {
  const [abierto, setAbierto] = useState(false)
  return (
    <>
      <button type="button" onClick={() => setAbierto(true)}>Abrir modal</button>
      {abierto && (
        <ModalBase title="Editar cliente" onClose={() => setAbierto(false)}>
          <input aria-label="Nombre" autoFocus={conAutoFocus} />
          <button type="button" onClick={() => setAbierto(false)}>Cancelar</button>
        </ModalBase>
      )}
    </>
  )
}

/** Un diálogo armado a mano con los primitivos, sin ModalBase (sin X). */
function DialogoAMano({
  onClose,
  children,
  ...contentProps
}: { onClose: () => void; children?: ReactNode } & Omit<DialogContentProps, 'children'>) {
  return (
    <Dialog open onOpenChange={(open) => { if (!open) onClose() }}>
      <DialogContent {...contentProps}>
        <DialogTitle>Confirmar baja</DialogTitle>
        <DialogDescription>Se da de baja el producto.</DialogDescription>
        {children}
        <button type="button" onClick={onClose}>Cancelar</button>
      </DialogContent>
    </Dialog>
  )
}

function HostAMano({ onCloseAutoFocus }: { onCloseAutoFocus?: DialogContentProps['onCloseAutoFocus'] }) {
  const [abierto, setAbierto] = useState(false)
  return (
    <>
      <button type="button" onClick={() => setAbierto(true)}>Abrir confirmación</button>
      <button type="button">Otro destino</button>
      {abierto && <DialogoAMano onClose={() => setAbierto(false)} onCloseAutoFocus={onCloseAutoFocus} />}
    </>
  )
}

describe('DialogContent · el foco vuelve al que abrió', () => {
  it.each([
    ['Escape', (user: Usuario) => user.keyboard('{Escape}')],
    ['la X', (user: Usuario) => user.click(screen.getByRole('button', { name: 'Cerrar' }))],
    ['Cancelar', (user: Usuario) => user.click(screen.getByRole('button', { name: 'Cancelar' }))],
  ])('ModalBase: al cerrar con %s el foco vuelve al botón que lo abrió', async (_, cerrar) => {
    const user = userEvent.setup()
    render(<HostModalBase />)
    const abrir = screen.getByRole('button', { name: 'Abrir modal' })

    await user.click(abrir)
    const dialogo = screen.getByRole('dialog', { name: 'Editar cliente' })
    expect(dialogo).toContainElement(document.activeElement as HTMLElement)

    await cerrar(user)
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(abrir).toHaveFocus()
  })

  it('ModalBase: vuelve al que abrió aunque un campo del cuerpo tenga autoFocus', async () => {
    const user = userEvent.setup()
    render(<HostModalBase conAutoFocus />)
    const abrir = screen.getByRole('button', { name: 'Abrir modal' })

    await user.click(abrir)
    expect(screen.getByRole('textbox', { name: 'Nombre' })).toHaveFocus()

    await user.keyboard('{Escape}')
    await dejarCorrerFocusScope()

    expect(abrir).toHaveFocus()
  })

  it.each([
    ['Escape', (user: Usuario) => user.keyboard('{Escape}')],
    ['Cancelar', (user: Usuario) => user.click(screen.getByRole('button', { name: 'Cancelar' }))],
  ])('armado a mano con Dialog + DialogContent: al cerrar con %s el foco vuelve al botón', async (_, cerrar) => {
    const user = userEvent.setup()
    render(<HostAMano />)
    const abrir = screen.getByRole('button', { name: 'Abrir confirmación' })

    await user.click(abrir)
    expect(screen.getByRole('dialog', { name: 'Confirmar baja' }))
      .toContainElement(document.activeElement as HTMLElement)

    await cerrar(user)
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(abrir).toHaveFocus()
  })

  it('con el Dialog siempre montado y `open` que alterna, vuelve cada vez al que abrió ESA vez', async () => {
    function HostPersistente() {
      const [abierto, setAbierto] = useState(false)
      return (
        <>
          <button type="button" onClick={() => setAbierto(true)}>Abrir desde arriba</button>
          <button type="button" onClick={() => setAbierto(true)}>Abrir desde abajo</button>
          <Dialog open={abierto} onOpenChange={setAbierto}>
            <DialogContent>
              <DialogTitle>Persistente</DialogTitle>
              <DialogDescription>Siempre montado.</DialogDescription>
              <button type="button" onClick={() => setAbierto(false)}>Cancelar</button>
            </DialogContent>
          </Dialog>
        </>
      )
    }
    const user = userEvent.setup()
    render(<HostPersistente />)
    const arriba = screen.getByRole('button', { name: 'Abrir desde arriba' })
    const abajo = screen.getByRole('button', { name: 'Abrir desde abajo' })

    await user.click(arriba)
    await user.keyboard('{Escape}')
    await dejarCorrerFocusScope()
    expect(arriba).toHaveFocus()

    await user.click(abajo)
    expect(screen.getByRole('dialog', { name: 'Persistente' })).toBeInTheDocument()
    await user.keyboard('{Escape}')
    await dejarCorrerFocusScope()
    expect(abajo).toHaveFocus()
  })
})

describe('DialogContent · en StrictMode (como corren la app y la galería en desarrollo)', () => {
  // StrictMode vuelve a correr los layout effects del montaje, y la segunda
  // corrida llega después del `autoFocus` del cuerpo: si "quién abrió" se
  // registrara ahí, sería el campo (que al cerrar ya no existe) y el foco
  // caería en <body>.
  it.each([
    ['sin autoFocus', false],
    ['con autoFocus en un campo del cuerpo', true],
  ])('ModalBase %s: al cerrar con Escape el foco vuelve al botón que lo abrió', async (_, conAutoFocus) => {
    const user = userEvent.setup()
    render(
      <StrictMode>
        <HostModalBase conAutoFocus={conAutoFocus} />
      </StrictMode>,
    )
    const abrir = screen.getByRole('button', { name: 'Abrir modal' })

    await user.click(abrir)
    expect(screen.getByRole('dialog', { name: 'Editar cliente' }))
      .toContainElement(document.activeElement as HTMLElement)

    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(abrir).toHaveFocus()
  })
})

describe('DialogContent · cadena: un diálogo cierra y otro abre en el mismo gesto', () => {
  // El que se cierra devuelve el foco en el setTimeout(0) de FocusScope, que
  // llega DESPUÉS de que el nuevo montó y tomó el foco. Si lo devolviera igual,
  // lo mandaría al botón de la vista, detrás del overlay del nuevo: con un
  // `autoFocus` el trap del nuevo todavía no lo registró y no lo puede rebotar.
  function HostCadena({ conAutoFocus }: { conAutoFocus: boolean }) {
    const [pasoA, setPasoA] = useState(false)
    const [pasoB, setPasoB] = useState(false)
    return (
      <>
        <button type="button" onClick={() => setPasoA(true)}>Abrir paso A</button>
        {pasoA && (
          <ModalBase title="Paso A" onClose={() => setPasoA(false)}>
            <button type="button" onClick={() => { setPasoA(false); setPasoB(true) }}>Seguir</button>
          </ModalBase>
        )}
        {pasoB && (
          <ModalBase title="Paso B" onClose={() => setPasoB(false)}>
            <textarea aria-label="Notas" autoFocus={conAutoFocus} />
            <button type="button" onClick={() => setPasoB(false)}>Listo</button>
          </ModalBase>
        )}
      </>
    )
  }

  it.each([
    ['con autoFocus en un campo', true],
    ['con el foco inicial por defecto', false],
  ])('el foco termina adentro del diálogo nuevo (%s), no en el botón que abrió el viejo', async (_, conAutoFocus) => {
    const user = userEvent.setup()
    render(<HostCadena conAutoFocus={conAutoFocus} />)
    const abrirA = screen.getByRole('button', { name: 'Abrir paso A' })

    await user.click(abrirA)
    await user.click(screen.getByRole('button', { name: 'Seguir' }))
    expect(screen.queryByRole('dialog', { name: 'Paso A' })).toBeNull()
    const pasoB = screen.getByRole('dialog', { name: 'Paso B' })
    await dejarCorrerFocusScope()

    expect(abrirA).not.toHaveFocus()
    expect(pasoB).toContainElement(document.activeElement as HTMLElement)
    if (conAutoFocus) expect(screen.getByRole('textbox', { name: 'Notas' })).toHaveFocus()
  })
})

describe('DialogContent · aria-modal', () => {
  it('ModalBase es un dialog con aria-modal="true"', () => {
    render(
      <ModalBase title="Con aria-modal" onClose={() => {}}>
        <p>cuerpo</p>
      </ModalBase>,
    )

    expect(screen.getByRole('dialog', { name: 'Con aria-modal' })).toHaveAttribute('aria-modal', 'true')
  })

  it('armado a mano, sin pasarlo, también lleva aria-modal="true"', () => {
    render(<DialogoAMano onClose={() => {}} />)

    expect(screen.getByRole('dialog', { name: 'Confirmar baja' })).toHaveAttribute('aria-modal', 'true')
  })
})

describe('DialogContent · onCloseAutoFocus del consumidor', () => {
  it('si hace preventDefault, manda él: el foco va a donde lo puso y NO vuelve al que abrió', async () => {
    const user = userEvent.setup()
    const onCloseAutoFocus = vi.fn((event: Event) => {
      event.preventDefault()
      screen.getByRole('button', { name: 'Otro destino' }).focus()
    })
    render(<HostAMano onCloseAutoFocus={onCloseAutoFocus} />)
    const abrir = screen.getByRole('button', { name: 'Abrir confirmación' })

    await user.click(abrir)
    await user.keyboard('{Escape}')
    await dejarCorrerFocusScope()

    expect(onCloseAutoFocus).toHaveBeenCalledTimes(1)
    expect(screen.getByRole('button', { name: 'Otro destino' })).toHaveFocus()
    expect(abrir).not.toHaveFocus()
  })

  it('si SÓLO hace preventDefault (el idiom de Radix para «no muevas el foco»), el foco no vuelve', async () => {
    // Sin mover el foco a otro lado: acá no hay ninguna otra guarda que tape
    // la falta del chequeo de `defaultPrevented`.
    const user = userEvent.setup()
    const onCloseAutoFocus = vi.fn((event: Event) => event.preventDefault())
    render(<HostAMano onCloseAutoFocus={onCloseAutoFocus} />)
    const abrir = screen.getByRole('button', { name: 'Abrir confirmación' })

    await user.click(abrir)
    await user.keyboard('{Escape}')
    await dejarCorrerFocusScope()

    expect(onCloseAutoFocus).toHaveBeenCalledTimes(1)
    expect(abrir).not.toHaveFocus()
    expect(document.body).toHaveFocus()
  })

  it('si no hace preventDefault, se lo llama igual (se compone, no se pisa) y el foco vuelve', async () => {
    const user = userEvent.setup()
    const onCloseAutoFocus = vi.fn()
    render(<HostAMano onCloseAutoFocus={onCloseAutoFocus} />)
    const abrir = screen.getByRole('button', { name: 'Abrir confirmación' })

    await user.click(abrir)
    await user.keyboard('{Escape}')
    await dejarCorrerFocusScope()

    expect(onCloseAutoFocus).toHaveBeenCalledTimes(1)
    expect(abrir).toHaveFocus()
  })
})

describe('DialogContent · el que abrió ya no está', () => {
  it('si el botón que abrió salió del DOM, cerrar no tira y el foco no queda en un nodo desconectado', async () => {
    function HostQueSeVa() {
      const [abierto, setAbierto] = useState(false)
      const [conBoton, setConBoton] = useState(true)
      return (
        <>
          {conBoton && <button type="button" onClick={() => setAbierto(true)}>Abrir y desaparecer</button>}
          {abierto && (
            <ModalBase title="Se va el de atrás" onClose={() => setAbierto(false)}>
              <button type="button" onClick={() => setConBoton(false)}>Quitar el de atrás</button>
            </ModalBase>
          )}
        </>
      )
    }
    const user = userEvent.setup()
    render(<HostQueSeVa />)
    const abrir = screen.getByRole('button', { name: 'Abrir y desaparecer' })

    await user.click(abrir)
    await user.click(screen.getByRole('button', { name: 'Quitar el de atrás' }))
    expect(abrir.isConnected).toBe(false)

    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(abrir).not.toHaveFocus()
    expect(document.activeElement).not.toBeNull()
    expect(document.activeElement?.isConnected).toBe(true)
  })
})

describe('DialogContent · abierto desde un ítem de DropdownMenu', () => {
  // Es la entrada más común de la app («Más acciones» de cada pedido, las
  // toolbars de pedidos y productos). Radix cierra el menú al elegir el ítem,
  // así que al cerrar el diálogo el ítem que tenía el foco ya no existe: el foco
  // tiene que ir al trigger del menú, no caer en <body>.

  // Radix DropdownMenu necesita en jsdom la Pointer Capture API y `scrollIntoView`
  // (el ResizeObserver construible que usa @floating-ui ya viene de
  // src/test/setup.js). Se ponen sólo para este bloque y se restauran al salir.
  const originales = {
    hasPointerCapture: Element.prototype.hasPointerCapture,
    setPointerCapture: Element.prototype.setPointerCapture,
    releasePointerCapture: Element.prototype.releasePointerCapture,
    scrollIntoView: Element.prototype.scrollIntoView,
  }
  beforeAll(() => {
    Element.prototype.hasPointerCapture = () => false
    Element.prototype.setPointerCapture = () => undefined
    Element.prototype.releasePointerCapture = () => undefined
    Element.prototype.scrollIntoView = () => undefined
  })
  afterAll(() => {
    Element.prototype.hasPointerCapture = originales.hasPointerCapture
    Element.prototype.setPointerCapture = originales.setPointerCapture
    Element.prototype.releasePointerCapture = originales.releasePointerCapture
    Element.prototype.scrollIntoView = originales.scrollIntoView
  })
  afterEach(() => {
    // Radix en modo modal apaga los punteros del body; si queda puesto, el
    // userEvent del caso siguiente no puede clickear nada.
    document.body.style.pointerEvents = ''
  })

  /** Como `AccionesDropdown`: un trigger «Mas acciones» y un ítem que abre un ModalBase. */
  function HostMenu() {
    const [abierto, setAbierto] = useState(false)
    return (
      <>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <button type="button" aria-label="Mas acciones">⋮</button>
          </DropdownMenuTrigger>
          <DropdownMenuContent>
            <DropdownMenuItem onClick={() => setAbierto(true)}>Editar</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        {abierto && (
          <ModalBase title="Editar pedido" onClose={() => setAbierto(false)}>
            <button type="button" onClick={() => setAbierto(false)}>Cancelar</button>
          </ModalBase>
        )}
      </>
    )
  }

  it.each([
    ['Escape', (user: Usuario) => user.keyboard('{Escape}')],
    ['la X', (user: Usuario) => user.click(screen.getByRole('button', { name: 'Cerrar' }))],
  ])('elegido con el mouse: al cerrar con %s el foco vuelve al trigger del menú', async (_, cerrar) => {
    const user = userEvent.setup()
    render(<HostMenu />)
    const trigger = screen.getByRole('button', { name: 'Mas acciones' })

    await user.click(trigger)
    const menu = await screen.findByRole('menu')
    await user.click(within(menu).getByRole('menuitem', { name: 'Editar' }))
    const dialogo = screen.getByRole('dialog', { name: 'Editar pedido' })
    expect(screen.queryByRole('menu')).toBeNull()
    await dejarCorrerFocusScope()
    expect(dialogo).toContainElement(document.activeElement as HTMLElement)

    await cerrar(user)
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(trigger).toHaveFocus()
  })

  it('elegido con el teclado: al cerrar con Escape el foco vuelve al trigger del menú', async () => {
    const user = userEvent.setup()
    render(<HostMenu />)
    const trigger = screen.getByRole('button', { name: 'Mas acciones' })

    trigger.focus()
    await user.keyboard('{Enter}')
    const menu = await screen.findByRole('menu')
    expect(within(menu).getByRole('menuitem', { name: 'Editar' })).toHaveFocus()
    await user.keyboard('{Enter}')
    expect(screen.getByRole('dialog', { name: 'Editar pedido' })).toBeInTheDocument()
    await dejarCorrerFocusScope()

    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(trigger).toHaveFocus()
  })

  /**
   * Un menú propio que no se cierra al elegir: el ítem sigue montado cuando el
   * diálogo se cierra. `aria-labelledby` apunta a un botón ENFOCABLE, así que si
   * el orden de preferencia se invirtiera el foco iría ahí y no al ítem.
   * `deshabilitarAlElegir` deja el ítem montado pero sin poder tomar el foco.
   */
  function HostMenuPropio({ deshabilitarAlElegir = false }: { deshabilitarAlElegir?: boolean }) {
    const [abierto, setAbierto] = useState(false)
    const [deshabilitado, setDeshabilitado] = useState(false)
    return (
      <>
        <button type="button" id="trigger-acciones">Acciones</button>
        <div role="menu" aria-labelledby="trigger-acciones">
          <button
            type="button"
            role="menuitem"
            disabled={deshabilitado}
            onClick={() => { setAbierto(true); if (deshabilitarAlElegir) setDeshabilitado(true) }}
          >
            Editar
          </button>
        </div>
        {abierto && (
          <ModalBase title="Editar pedido" onClose={() => setAbierto(false)}>
            <p>cuerpo</p>
          </ModalBase>
        )}
      </>
    )
  }

  it('si el ítem sigue montado al cerrar, vuelve al ítem y no al trigger del menú', async () => {
    const user = userEvent.setup()
    render(<HostMenuPropio />)
    const item = screen.getByRole('menuitem', { name: 'Editar' })

    await user.click(item)
    expect(screen.getByRole('dialog', { name: 'Editar pedido' })).toBeInTheDocument()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(item).toHaveFocus()
    expect(screen.getByRole('button', { name: 'Acciones' })).not.toHaveFocus()
  })

  it('si el ítem sigue montado pero ya no toma el foco (deshabilitado), cede al trigger del menú', async () => {
    const user = userEvent.setup()
    render(<HostMenuPropio deshabilitarAlElegir />)
    const item = screen.getByRole('menuitem', { name: 'Editar' })

    await user.click(item)
    expect(item).toBeDisabled()
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()

    expect(screen.getByRole('button', { name: 'Acciones' })).toHaveFocus()
  })
})

describe('DialogContent · anidado (confirmación adentro de un ModalBase)', () => {
  // CLAUDE.md: una confirmación disparada desde un modal Radix se renderiza
  // DENTRO del modal. Al cerrarla, el foco vuelve al botón de ADENTRO del
  // ModalBase que la abrió, no al de la vista que abrió el ModalBase.
  function HostAnidado() {
    const [modalAbierto, setModalAbierto] = useState(false)
    const [confirmando, setConfirmando] = useState(false)
    return (
      <>
        <button type="button" onClick={() => setModalAbierto(true)}>Abrir pedido</button>
        {modalAbierto && (
          <ModalBase title="Editar pedido" onClose={() => setModalAbierto(false)}>
            <button type="button" onClick={() => setConfirmando(true)}>Eliminar ítem</button>
            <ModalConfirmacion
              config={{
                visible: confirmando,
                tipo: 'danger',
                titulo: 'Eliminar ítem',
                mensaje: '¿Eliminar el ítem del pedido?',
                onConfirm: () => {},
              }}
              onClose={() => setConfirmando(false)}
            />
          </ModalBase>
        )}
      </>
    )
  }

  it.each([
    ['Escape', (user: Usuario) => user.keyboard('{Escape}')],
    ['Cancelar', (user: Usuario) => user.click(screen.getByRole('button', { name: 'Cancelar' }))],
  ])('al cerrar la confirmación con %s el foco vuelve al botón del ModalBase que la abrió', async (_, cerrar) => {
    const user = userEvent.setup()
    render(<HostAnidado />)
    const abrirPedido = screen.getByRole('button', { name: 'Abrir pedido' })

    await user.click(abrirPedido)
    const eliminar = screen.getByRole('button', { name: 'Eliminar ítem' })
    await user.click(eliminar)
    const confirmacion = screen.getByRole('dialog', { name: 'Eliminar ítem' })
    expect(confirmacion).toContainElement(document.activeElement as HTMLElement)

    await cerrar(user)
    expect(screen.queryByRole('dialog', { name: 'Eliminar ítem' })).toBeNull()
    await dejarCorrerFocusScope()

    // El ModalBase sigue abierto y el foco está en SU botón.
    expect(screen.getByRole('dialog', { name: 'Editar pedido' })).toBeInTheDocument()
    expect(eliminar).toHaveFocus()

    // Y al cerrar el ModalBase, el foco sigue la cadena hasta la vista.
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    await dejarCorrerFocusScope()
    expect(abrirPedido).toHaveFocus()
  })
})
