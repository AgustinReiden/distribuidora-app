/**
 * Foco del panel desplegable de `TopNavigation` (#789).
 *
 * El panel esta en el DOM DESPUES del <header>: abierto con el teclado, el Tab
 * pasaba por el boton de tema, la campana, la sucursal y el menu de usuario
 * antes de llegar al primer item. El arreglo:
 *  - abierto POR TECLADO (Enter o Espacio sobre la hamburguesa o sobre "Más"),
 *    el foco pasa al primer item;
 *  - abierto con mouse o toque, el foco no se mueve;
 *  - Escape lo cierra y devuelve el foco a quien lo abrio, venga de donde venga,
 *    salvo que haya otro desplegable del header abierto o que una capa de
 *    encima ya se haya quedado con la tecla.
 *
 * Se detecta "por teclado" con `event.detail === 0` del click. user-event lo
 * respeta (`user.keyboard` da 0, `user.click` da 1), asi que estos tests son
 * los mismos que haria un teclado de verdad.
 *
 * El andamiaje (mocks, MemoryRouter) es el de TopNavigation.test.tsx. jsdom no
 * aplica Tailwind: el panel cerrado se reconoce por la clase `invisible`.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, within, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import type { ReactElement } from 'react'

import type { PerfilDB, RolUsuario } from '../../../types'

// =============================================================================
// MOCKS (los mismos de TopNavigation.test.tsx)
// =============================================================================

let rolesEfectivosMock: RolUsuario[] = ['admin']
vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ rolesEfectivos: rolesEfectivosMock }),
}))

vi.mock('../../../contexts/ThemeContext', () => ({
  useTheme: () => ({ darkMode: false, toggleDarkMode: vi.fn() }),
}))

vi.mock('../DbNotificationBell', () => ({
  default: (): ReactElement => <div>Campanita</div>,
}))
vi.mock('../SucursalSelector', () => ({
  default: (): ReactElement => <div>Selector de sucursal</div>,
}))
vi.mock('../../perfil/VincularTelegramButton', () => ({
  default: (): ReactElement => <div>Vincular Telegram</div>,
}))
vi.mock('../../../hooks/useActualizacionDisponible', () => ({
  BUILD_ACTUAL: 'abc123def456',
}))

import TopNavigation from '../TopNavigation'

// =============================================================================
// HELPERS
// =============================================================================

const PERFIL = {
  id: 'u-1',
  nombre: 'Jorge Perez',
  email: 'jorge@distribuidora.test',
  rol: 'admin',
} as unknown as PerfilDB

function renderNav(roles: RolUsuario[]): void {
  rolesEfectivosMock = roles
  render(
    <MemoryRouter initialEntries={['/pedidos']}>
      <TopNavigation perfil={PERFIL} onLogout={vi.fn()} />
    </MemoryRouter>,
  )
}

const hamburguesa = (): HTMLElement => screen.getByRole('button', { name: /^(Abrir|Cerrar) menu$/ })
const botonMas = (): HTMLElement =>
  within(screen.getByRole('navigation', { name: 'Navegacion inferior' })).getByRole('button', { name: 'Más' })

/** El div del panel desplegable: el padre del nav que no es la barra de escritorio ni la inferior. */
const panel = (): HTMLElement => {
  const excluidos = [
    screen.getByRole('navigation', { name: 'Navegacion principal' }),
    screen.queryByRole('navigation', { name: 'Navegacion inferior' }),
  ]
  const nav = screen.getAllByRole('navigation').find(n => !excluidos.includes(n))
  if (!nav?.parentElement) throw new Error('No se encontro el panel desplegable')
  return nav.parentElement
}
const itemsDelPanel = (): HTMLElement[] => within(panel()).getAllByRole('button')
const textoDe = (el: Element | null): string => (el?.textContent ?? '').trim()

const estaAbierto = (): boolean => !panel().classList.contains('invisible')
const foco = (): string => textoDe(document.activeElement)

/** Los dos primeros items del panel de cada rol (la config del menu, en orden). */
const PRIMEROS_ITEMS = {
  admin: ['Dashboard', 'Pedidos'],
  encargado: ['Pedidos', 'Clientes'],
  preventista: ['Hoy', 'Dashboard'],
  deposito: ['Pedidos', 'Productos'],
} as const satisfies Partial<Record<RolUsuario, readonly [string, string]>>

type RolConPanel = keyof typeof PRIMEROS_ITEMS
const ROLES_CON_PANEL = Object.keys(PRIMEROS_ITEMS) as RolConPanel[]

/** Los roles cuya barra inferior tiene "Más" (los otros ven todo en la barra). */
const ROLES_CON_MAS = ['admin', 'encargado', 'preventista'] as const

afterEach(() => {
  vi.restoreAllMocks()
})

// =============================================================================
// ABIERTO POR TECLADO: EL FOCO PASA AL PRIMER ITEM
// =============================================================================

describe('TopNavigation — panel abierto con la hamburguesa por teclado', () => {
  it.each(ROLES_CON_PANEL)(
    '%s: Enter abre el panel, el foco queda en su primer item y el Tab siguiente cae en el segundo (sin recorrer el header)',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()
      const [primero, segundo] = PRIMEROS_ITEMS[rol]
      expect(estaAbierto()).toBe(false)

      hamburguesa().focus()
      await user.keyboard('{Enter}')

      expect(hamburguesa()).toHaveAttribute('aria-expanded', 'true')
      expect(estaAbierto()).toBe(true)
      expect(panel()).toContainElement(document.activeElement as HTMLElement)
      expect(document.activeElement).toBe(itemsDelPanel()[0])
      expect(foco()).toBe(primero)

      await user.tab()
      expect(document.activeElement).toBe(itemsDelPanel()[1])
      expect(foco()).toBe(segundo)
    },
  )

  it.each(ROLES_CON_PANEL)(
    '%s: Espacio hace lo mismo que Enter',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()
      const [primero, segundo] = PRIMEROS_ITEMS[rol]

      hamburguesa().focus()
      await user.keyboard(' ')

      expect(estaAbierto()).toBe(true)
      expect(foco()).toBe(primero)
      await user.tab()
      expect(foco()).toBe(segundo)
    },
  )

  it('insiste cuadro a cuadro si el panel todavia no es enfocable (la transicion de `visibility` al abrir)', async () => {
    // En un navegador el panel cerrado esta `invisible` y su transition-all
    // anima tambien `visibility`: en el primer cuadro focus() no hace nada.
    renderNav(['admin'])
    const user = userEvent.setup()
    const focusOriginal = HTMLElement.prototype.focus
    let intentosSobreElPanel = 0
    vi.spyOn(HTMLElement.prototype, 'focus').mockImplementation(function (this: HTMLElement, opciones) {
      if (panel().contains(this) && ++intentosSobreElPanel <= 2) return // todavia invisible
      focusOriginal.call(this, opciones)
    })

    hamburguesa().focus()
    await user.keyboard('{Enter}')

    await waitFor(() => expect(foco()).toBe('Dashboard'))
    expect(intentosSobreElPanel).toBe(3)
  })
})

// =============================================================================
// ABIERTO CON MOUSE O TOQUE: NADA SE MUEVE
// =============================================================================

describe('TopNavigation — panel abierto con mouse o toque', () => {
  it.each(ROLES_CON_PANEL)(
    '%s: un click en la hamburguesa abre el panel y el foco NO pasa al panel',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()

      await user.click(hamburguesa())

      expect(estaAbierto()).toBe(true)
      expect(hamburguesa()).toHaveAttribute('aria-expanded', 'true')
      expect(hamburguesa()).toHaveFocus()
      expect(panel().contains(document.activeElement)).toBe(false)
    },
  )

  it.each(ROLES_CON_MAS)(
    '%s: un click en "Más" abre el panel y el foco NO pasa al panel',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()

      await user.click(botonMas())

      expect(estaAbierto()).toBe(true)
      expect(botonMas()).toHaveFocus()
      expect(panel().contains(document.activeElement)).toBe(false)
    },
  )

  it('la marca de "por teclado" no queda colgada: abrir con Enter, cerrar con Enter y abrir con mouse no mueve el foco', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    hamburguesa().focus()
    await user.keyboard('{Enter}')
    expect(foco()).toBe('Dashboard')

    hamburguesa().focus()
    await user.keyboard('{Enter}') // cierra
    expect(estaAbierto()).toBe(false)
    expect(hamburguesa()).toHaveFocus()

    await user.click(hamburguesa()) // abre con el mouse
    expect(estaAbierto()).toBe(true)
    expect(hamburguesa()).toHaveFocus()
  })
})

// =============================================================================
// "MÁS" DE LA BARRA INFERIOR
// =============================================================================

describe('TopNavigation — panel abierto con "Más" por teclado', () => {
  it.each(ROLES_CON_MAS)(
    '%s: Enter sobre "Más" pasa el foco al primer item y el Tab siguiente cae en el segundo',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()
      const [primero, segundo] = PRIMEROS_ITEMS[rol]

      botonMas().focus()
      await user.keyboard('{Enter}')

      expect(botonMas()).toHaveAttribute('aria-expanded', 'true')
      expect(estaAbierto()).toBe(true)
      expect(foco()).toBe(primero)
      await user.tab()
      expect(foco()).toBe(segundo)
    },
  )

  it.each(ROLES_CON_MAS)('%s: Espacio sobre "Más" hace lo mismo', async rol => {
    renderNav([rol])
    const user = userEvent.setup()
    const [primero, segundo] = PRIMEROS_ITEMS[rol]

    botonMas().focus()
    await user.keyboard(' ')

    expect(estaAbierto()).toBe(true)
    expect(foco()).toBe(primero)
    await user.tab()
    expect(foco()).toBe(segundo)
  })
})

// =============================================================================
// ESCAPE
// =============================================================================

describe('TopNavigation — Escape cierra el panel y devuelve el foco', () => {
  it.each(ROLES_CON_PANEL)(
    '%s: abierto con Enter, Escape desde el primer item lo cierra y el foco vuelve a la hamburguesa',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()

      hamburguesa().focus()
      await user.keyboard('{Enter}')
      expect(panel().contains(document.activeElement)).toBe(true)

      await user.keyboard('{Escape}')

      expect(estaAbierto()).toBe(false)
      expect(panel()).toHaveClass('invisible')
      expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')
      expect(hamburguesa()).toHaveFocus()
    },
  )

  it.each(ROLES_CON_PANEL)(
    '%s: abierto con el mouse, Escape tambien lo cierra y el foco queda en la hamburguesa',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()

      await user.click(hamburguesa())
      await user.keyboard('{Escape}')

      expect(estaAbierto()).toBe(false)
      expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')
      expect(hamburguesa()).toHaveFocus()
    },
  )

  it('abierto con el mouse pero con el foco en otra parte (Safari no enfoca los botones al click), Escape igual cierra y devuelve el foco', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(hamburguesa())
    ;(document.activeElement as HTMLElement).blur()
    expect(document.body).toHaveFocus()

    await user.keyboard('{Escape}')

    expect(estaAbierto()).toBe(false)
    expect(hamburguesa()).toHaveFocus()
  })

  it.each(ROLES_CON_MAS)(
    '%s: abierto con "Más", Escape lo cierra y el foco vuelve a "Más" (no a la hamburguesa)',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()

      botonMas().focus()
      await user.keyboard('{Enter}')
      expect(panel().contains(document.activeElement)).toBe(true)
      await user.keyboard('{Escape}')

      expect(estaAbierto()).toBe(false)
      expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
      expect(botonMas()).toHaveFocus()
    },
  )

  it('abierto con "Más" y el mouse, Escape lo cierra y el foco queda en "Más"', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(botonMas())
    await user.keyboard('{Escape}')

    expect(estaAbierto()).toBe(false)
    expect(botonMas()).toHaveFocus()
  })

  it('el foco vuelve a quien lo abrio en esta vez: hamburguesa, cierre, "Más", Escape', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(hamburguesa())
    await user.keyboard('{Escape}')
    expect(hamburguesa()).toHaveFocus()

    botonMas().focus()
    await user.keyboard('{Enter}')
    await user.keyboard('{Escape}')
    expect(botonMas()).toHaveFocus()
    expect(estaAbierto()).toBe(false)
  })

  it('con el panel cerrado, Escape no hace nada: no mueve el foco ni abre nada', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    const tema = screen.getByRole('button', { name: 'Cambiar a modo oscuro' })

    tema.focus()
    await user.keyboard('{Escape}')

    expect(tema).toHaveFocus()
    expect(estaAbierto()).toBe(false)
    expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')
  })

  it('despues de cerrarlo con Escape, otro Escape no vuelve a mover el foco', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(hamburguesa())
    await user.keyboard('{Escape}')
    const tema = screen.getByRole('button', { name: 'Cambiar a modo oscuro' })
    tema.focus()
    await user.keyboard('{Escape}')

    expect(tema).toHaveFocus()
  })

  it('un item elegido con Enter navega y cierra el panel como siempre', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    hamburguesa().focus()
    await user.keyboard('{Enter}')
    await user.keyboard('{Enter}') // sobre "Dashboard", el primer item

    expect(estaAbierto()).toBe(false)
    expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')
  })
})

// =============================================================================
// ESCAPE Y OTROS DESPLEGABLES DEL HEADER
// =============================================================================

// Hoy ni el menu de usuario ni los grupos de la barra responden a Escape: lo
// que se fija es que el panel no se lo lleve cuando hay uno abierto.
describe('TopNavigation — Escape con otros desplegables del header', () => {
  const DESPLEGABLES = [
    ['el menu de usuario', 'Menu de usuario'],
    ['el grupo "Comercial" de la barra', 'Comercial'],
  ] as const

  it.each(DESPLEGABLES)(
    'con %s abierto y el panel cerrado, Escape no cambia nada: ni se abre el panel ni se mueve el foco',
    async (_nombre, etiqueta) => {
      renderNav(['admin'])
      const user = userEvent.setup()
      const desplegable = screen.getByRole('button', { name: etiqueta })

      await user.click(desplegable)
      expect(desplegable).toHaveAttribute('aria-expanded', 'true')
      await user.keyboard('{Escape}')

      expect(desplegable).toHaveAttribute('aria-expanded', 'true')
      expect(desplegable).toHaveFocus()
      expect(estaAbierto()).toBe(false)
    },
  )

  it.each(DESPLEGABLES)(
    'con %s abierto y el panel tambien (por teclado), Escape no cierra el panel ni mueve el foco; cerrado el desplegable, Escape vuelve a cerrar el panel',
    async (_nombre, etiqueta) => {
      renderNav(['admin'])
      const user = userEvent.setup()
      const desplegable = screen.getByRole('button', { name: etiqueta })

      // Por teclado no hay `mousedown` afuera del panel: los dos quedan abiertos.
      hamburguesa().focus()
      await user.keyboard('{Enter}')
      desplegable.focus()
      await user.keyboard('{Enter}')
      expect(desplegable).toHaveAttribute('aria-expanded', 'true')
      expect(estaAbierto()).toBe(true)

      await user.keyboard('{Escape}')

      expect(estaAbierto()).toBe(true)
      expect(hamburguesa()).toHaveAttribute('aria-expanded', 'true')
      expect(desplegable).toHaveAttribute('aria-expanded', 'true')
      expect(desplegable).toHaveFocus()

      await user.keyboard('{Enter}') // cierra el desplegable
      expect(desplegable).toHaveAttribute('aria-expanded', 'false')
      await user.keyboard('{Escape}')

      expect(estaAbierto()).toBe(false)
      expect(hamburguesa()).toHaveFocus()
    },
  )

  it('si una capa de encima ya se quedo con Escape (defaultPrevented, como un modal de Radix), el panel no lo cierra', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    const capaDeArriba = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') e.preventDefault()
    }
    // En captura, como el DismissableLayer de Radix: corre antes que el listener del panel.
    document.addEventListener('keydown', capaDeArriba, true)
    try {
      hamburguesa().focus()
      await user.keyboard('{Enter}')
      await user.keyboard('{Escape}')

      expect(estaAbierto()).toBe(true)
      expect(foco()).toBe('Dashboard')
    } finally {
      document.removeEventListener('keydown', capaDeArriba, true)
    }
  })
})

// =============================================================================
// ARIA-CONTROLS
// =============================================================================

describe('TopNavigation — aria-controls del panel', () => {
  it('la hamburguesa y "Más" apuntan al id del panel', () => {
    renderNav(['admin'])
    const id = panel().id
    expect(id).not.toBe('')
    expect(hamburguesa()).toHaveAttribute('aria-controls', id)
    expect(botonMas()).toHaveAttribute('aria-controls', id)
    expect(document.getElementById(id)).toBe(panel())
  })
})
