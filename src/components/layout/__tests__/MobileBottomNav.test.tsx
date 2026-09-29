/**
 * Barra inferior del celular (WP-41, #766).
 *
 * Se prueba montada desde `TopNavigation`, que es donde vive de verdad: de ahi
 * saca los destinos (el menu ya filtrado por rol) y el estado del panel que
 * abre "Mas". El andamiaje (mocks, MemoryRouter, "Ruta actual") es el de
 * TopNavigation.test.tsx.
 *
 * El invariante que no se puede romper: la barra no ofrece nada que el menu de
 * hoy no le ofrezca a ese rol. Lo que el menu ofrece lo fija
 * TopNavigation.test.tsx (y contra el router); aca se compara contra el panel
 * desplegable renderizado, no contra una tabla copiada.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, useLocation, useNavigate } from 'react-router-dom'
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
// TABLAS
// =============================================================================

/** Lo que muestra la barra de cada rol primario, en orden. "Más" va al final. */
const BARRA_POR_ROL = {
  admin: ['Dashboard', 'Pedidos', 'Clientes', 'Más'],
  encargado: ['Pedidos', 'Clientes', 'Recorridos', 'Más'],
  preventista: ['Dashboard', 'Pedidos', 'Mis entregas', 'Clientes', 'Productos'],
  deposito: ['Pedidos', 'Productos', 'Vencimientos'],
} as const

const RUTA_DE_LA_ETIQUETA: Record<string, string> = {
  'Dashboard': '/dashboard',
  'Pedidos': '/pedidos',
  'Mis entregas': '/mis-entregas',
  'Clientes': '/clientes',
  'Productos': '/productos',
  'Recorridos': '/recorridos',
  'Vencimientos': '/vencimientos',
}

const ROLES: RolUsuario[] = ['admin', 'encargado', 'preventista', 'transportista', 'deposito']
const MULTI_ROLES = ROLES.flatMap(primario =>
  ROLES.filter(extra => extra !== primario).map(extra => [primario, extra] as const),
)

// =============================================================================
// HELPERS
// =============================================================================

const PERFIL = {
  id: 'u-1',
  nombre: 'Jorge Perez',
  email: 'jorge@distribuidora.test',
  rol: 'admin',
} as unknown as PerfilDB

function RutaActual(): ReactElement {
  const { pathname, search } = useLocation()
  return <p>{`Ruta actual: ${pathname}${search}`}</p>
}

/** Botones para mover la URL desde afuera de la barra, como lo haria la app. */
function Saltos(): ReactElement {
  const navigate = useNavigate()
  return (
    <div>
      <button type="button" onClick={() => navigate('/pedidos?vista=ruta')}>Ir a la ruta</button>
      <button type="button" onClick={() => navigate('/pedidos')}>Ir a la lista</button>
    </div>
  )
}

function renderNav(roles: RolUsuario[], ruta = '/pedidos'): { unmount: () => void } {
  rolesEfectivosMock = roles
  return render(
    <MemoryRouter initialEntries={[ruta]}>
      <TopNavigation perfil={PERFIL} onLogout={vi.fn()} />
      <RutaActual />
      <Saltos />
    </MemoryRouter>,
  )
}

const barra = (): HTMLElement => screen.getByRole('navigation', { name: 'Navegacion inferior' })
const barraOpcional = (): HTMLElement | null =>
  screen.queryByRole('navigation', { name: 'Navegacion inferior' })

const textoDe = (el: Element): string => (el.textContent ?? '').trim()
const etiquetasDeLaBarra = (): string[] => within(barra()).getAllByRole('button').map(textoDe)

/** El panel desplegable: el nav que no es la barra de escritorio ni la inferior. */
const panel = (): HTMLElement => {
  const excluidos = [
    screen.getByRole('navigation', { name: 'Navegacion principal' }),
    barraOpcional(),
  ]
  const otro = screen.getAllByRole('navigation').find(nav => !excluidos.includes(nav))
  if (!otro) throw new Error('No se encontro el nav del panel movil')
  return otro
}
const etiquetasDelPanel = (): string[] => within(panel()).queryAllByRole('button').map(textoDe)

/** El overlay del panel abierto: el unico div aria-hidden (los iconos son svg). */
const overlayOpcional = (): HTMLElement | null => document.querySelector<HTMLElement>('div[aria-hidden="true"]')
const overlay = (): HTMLElement => {
  const el = overlayOpcional()
  if (!el) throw new Error('No hay overlay: el panel esta cerrado')
  return el
}

const hamburguesa = (): HTMLElement => screen.getByRole('button', { name: /^(Abrir|Cerrar) menu$/ })
const botonMas = (): HTMLElement => within(barra()).getByRole('button', { name: 'Más' })

const CLASE_EN_HTML = 'con-barra-inferior'

// =============================================================================
// QUE LLEVA LA BARRA DE CADA ROL
// =============================================================================

describe('MobileBottomNav — que lleva la barra de cada rol', () => {
  it.each(Object.keys(BARRA_POR_ROL) as Array<keyof typeof BARRA_POR_ROL>)(
    'el %s ve exactamente sus destinos, en orden',
    rol => {
      renderNav([rol])
      expect(etiquetasDeLaBarra()).toEqual(BARRA_POR_ROL[rol])
    },
  )

  it('el transportista puro no tiene barra, en /pedidos (su mapa) ni en otra ruta', () => {
    const { unmount } = renderNav(['transportista'])
    expect(barraOpcional()).toBeNull()
    unmount()

    renderNav(['transportista'], '/clientes')
    expect(barraOpcional()).toBeNull()
  })

  it('sin roles efectivos no hay barra', () => {
    renderNav([])
    expect(barraOpcional()).toBeNull()
  })

  const COMBINACIONES: RolUsuario[][] = [...ROLES.map(rol => [rol]), ...MULTI_ROLES.map(par => [...par])]

  it.each(COMBINACIONES.map(roles => [roles]))(
    'invariante barra ⊂ menu: con %j cada destino de la barra esta en el panel, y hay "Más" si y solo si al panel le sobra algo',
    roles => {
      // Fuera de /pedidos: ahi la barra no depende de la ruta activa.
      renderNav(roles, '/productos')
      const enElPanel = etiquetasDelPanel()
      const enLaBarra = barraOpcional() ? etiquetasDeLaBarra() : []
      const destinos = enLaBarra.filter(e => e !== 'Más')

      expect(enLaBarra.length).toBeLessThanOrEqual(5)
      for (const destino of destinos) expect(enElPanel).toContain(destino)
      if (enLaBarra.length > 0) {
        const sobra = enElPanel.some(e => !destinos.includes(e))
        expect(enLaBarra.includes('Más')).toBe(sobra)
      }
    },
  )

  it.each(['preventista', 'deposito'] as const)(
    'al %s no le queda nada del menu afuera: la barra no tiene "Más"',
    rol => {
      renderNav([rol])
      expect(within(barra()).queryByRole('button', { name: 'Más' })).toBeNull()
      expect([...etiquetasDelPanel()].sort()).toEqual([...etiquetasDeLaBarra()].sort())
    },
  )

  it('si el rol ve cinco destinos o menos van todos, en el orden del menu y sin "Más": el deposito con preventista extra ve sus cuatro', () => {
    renderNav(['deposito', 'preventista'])
    expect(etiquetasDeLaBarra()).toEqual(['Pedidos', 'Clientes', 'Productos', 'Vencimientos'])
    expect(within(barra()).queryByRole('button', { name: 'Más' })).toBeNull()
  })

  it('si el rol ve mas de cinco, va su lista corta y "Más" (nunca mas de cinco lugares)', () => {
    renderNav(['encargado'])
    expect(etiquetasDelPanel().length).toBeGreaterThan(5)
    expect(etiquetasDeLaBarra()).toHaveLength(4)
    expect(botonMas()).toBeInTheDocument()
  })

  it('un rol extra que no es transportista no suma destinos con gate: el encargado con preventista extra no ve "Dashboard"', () => {
    renderNav(['encargado', 'preventista'])
    expect(etiquetasDeLaBarra()).toEqual(BARRA_POR_ROL.encargado)
  })
})

// =============================================================================
// NAVEGAR
// =============================================================================

describe('MobileBottomNav — navegar', () => {
  const CASOS = (Object.keys(BARRA_POR_ROL) as Array<keyof typeof BARRA_POR_ROL>).flatMap(rol =>
    BARRA_POR_ROL[rol].filter(e => e !== 'Más').map(etiqueta => [rol, etiqueta] as const),
  )

  it.each(CASOS)('el %s toca "%s" y navega a su ruta', async (rol, etiqueta) => {
    renderNav([rol], '/pedidos')
    const user = userEvent.setup()
    await user.click(within(barra()).getByRole('button', { name: etiqueta }))
    expect(screen.getByText(`Ruta actual: ${RUTA_DE_LA_ETIQUETA[etiqueta]}`)).toBeInTheDocument()
  })

  it('el destino de la ruta actual lleva aria-current="page", y ningun otro', () => {
    renderNav(['admin'], '/clientes')
    expect(within(barra()).getByRole('button', { name: 'Clientes' })).toHaveAttribute('aria-current', 'page')
    for (const otro of ['Dashboard', 'Pedidos', 'Más']) {
      expect(within(barra()).getByRole('button', { name: otro })).not.toHaveAttribute('aria-current')
    }
  })

  it('al navegar, aria-current pasa al destino nuevo', async () => {
    renderNav(['preventista'], '/pedidos')
    const user = userEvent.setup()
    expect(within(barra()).getByRole('button', { name: 'Pedidos' })).toHaveAttribute('aria-current', 'page')

    await user.click(within(barra()).getByRole('button', { name: 'Mis entregas' }))
    expect(within(barra()).getByRole('button', { name: 'Mis entregas' })).toHaveAttribute('aria-current', 'page')
    expect(within(barra()).getByRole('button', { name: 'Pedidos' })).not.toHaveAttribute('aria-current')
  })

  it('en una ruta que no esta en la barra ningun destino lleva aria-current', () => {
    renderNav(['admin'], '/compras')
    for (const boton of within(barra()).getAllByRole('button')) {
      expect(boton).not.toHaveAttribute('aria-current')
    }
  })
})

// =============================================================================
// "MAS" ABRE EL MISMO PANEL QUE LA HAMBURGUESA
// =============================================================================

// En un celular, con el panel abierto el overlay (z-30, despues de la barra en
// el DOM) cubre la barra: un toque sobre ella NO llega a "Más" ni a sus destinos,
// llega al overlay y cierra el panel. jsdom no hace hit-testing, asi que un
// `user.click` sobre un boton de la barra con el panel abierto probaria un toque
// que en el navegador no ocurre. Por eso:
//  - lo que pasa con el toque real se prueba sobre el overlay (mas abajo);
//  - los casos de "Más" con el panel abierto activan el boton por teclado, que
//    si llega (el foco no depende de lo que tape el overlay);
//  - el unico `click` sobre "Más" abierto es el del bug #730 (mousedown + click).
describe('MobileBottomNav — "Más"', () => {
  it('arranca cerrado, y al tocarlo abre el mismo panel que la hamburguesa', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
    expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')

    await user.click(botonMas())

    expect(botonMas()).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByRole('button', { name: 'Cerrar menu' })).toHaveAttribute('aria-expanded', 'true')
  })

  it('un segundo toque en "Más" lo cierra (sin el bug #730 del click afuera)', async () => {
    renderNav(['encargado'])
    const user = userEvent.setup()

    await user.click(botonMas())
    await user.click(botonMas())

    expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
    expect(screen.getByRole('button', { name: 'Abrir menu' })).toHaveAttribute('aria-expanded', 'false')
  })

  it('por teclado: abierto con la hamburguesa, "Más" lo cierra; y abierto con "Más", la hamburguesa lo cierra', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(hamburguesa())
    expect(botonMas()).toHaveAttribute('aria-expanded', 'true')
    botonMas().focus()
    await user.keyboard('{Enter}')
    expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')

    botonMas().focus()
    await user.keyboard('{Enter}')
    expect(hamburguesa()).toHaveAttribute('aria-expanded', 'true')
    await user.click(hamburguesa())
    expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
  })

  it('un toque afuera del panel abierto con "Más" lo cierra', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(botonMas())
    await user.click(screen.getByText(/Ruta actual:/))

    expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
  })

  it('con el panel abierto, elegir un item del panel navega y lo cierra', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(botonMas())
    await user.click(within(panel()).getByRole('button', { name: 'Rendiciones' }))

    expect(screen.getByText('Ruta actual: /rendiciones')).toBeInTheDocument()
    expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
  })

  it('por teclado, con el panel abierto, activar un destino de la barra navega y cierra el panel', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(botonMas())
    within(barra()).getByRole('button', { name: 'Clientes' }).focus()
    await user.keyboard('{Enter}')

    expect(screen.getByText('Ruta actual: /clientes')).toBeInTheDocument()
    expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
    expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')
  })

  it.each(['admin', 'encargado'] as const)(
    'el toque real sobre la barra con el panel abierto (el %s) cae en el overlay: cierra el panel y no navega',
    async rol => {
      renderNav([rol], '/pedidos')
      const user = userEvent.setup()

      await user.click(botonMas())
      expect(botonMas()).toHaveAttribute('aria-expanded', 'true')
      await user.click(overlay())

      expect(botonMas()).toHaveAttribute('aria-expanded', 'false')
      expect(hamburguesa()).toHaveAttribute('aria-expanded', 'false')
      expect(overlayOpcional()).toBeNull()
      expect(screen.getByText('Ruta actual: /pedidos')).toBeInTheDocument()
    },
  )

  it('el overlay viene despues de la barra en el DOM (a igual z-index la cubre) y solo existe con el panel abierto', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    expect(overlayOpcional()).toBeNull()

    await user.click(botonMas())

    expect(barra().compareDocumentPosition(overlay()) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
})

// =============================================================================
// LA RUTA ACTIVA DEL TRANSPORTISTA NO LLEVA BARRA
// =============================================================================

describe('MobileBottomNav — ruta activa', () => {
  it.each([
    [['preventista', 'transportista'], '/pedidos?vista=ruta', false],
    [['preventista', 'transportista'], '/pedidos', true],
    [['preventista', 'transportista'], '/clientes?vista=ruta', true],
    [['encargado', 'transportista'], '/pedidos?vista=ruta', false],
    [['encargado', 'transportista'], '/pedidos', true],
    // El admin no alterna a la ruta (PedidosContainer): ?vista=ruta no le cambia la pantalla.
    [['admin', 'transportista'], '/pedidos?vista=ruta', true],
    // Sin transportista no hay ruta activa, venga la URL que venga.
    [['preventista'], '/pedidos?vista=ruta', true],
    // Deposito con transportista extra: en /pedidos VistaPedidos le monta el
    // mapa (esTransportistaPuro), en el resto ve su pantalla y su barra.
    [['deposito', 'transportista'], '/pedidos', false],
    [['deposito', 'transportista'], '/productos', true],
  ] as const)('%j en %s: barra %s', (roles, ruta, hayBarra) => {
    renderNav([...roles], ruta)
    expect(barraOpcional() !== null).toBe(hayBarra)
  })

  it('el multi-rol que pasa a la ruta pierde la barra, y la recupera al volver a la lista', async () => {
    renderNav(['preventista', 'transportista'], '/pedidos')
    const user = userEvent.setup()
    expect(barraOpcional()).not.toBeNull()

    await user.click(screen.getByRole('button', { name: 'Ir a la ruta' }))
    expect(screen.getByText('Ruta actual: /pedidos?vista=ruta')).toBeInTheDocument()
    expect(barraOpcional()).toBeNull()
    expect(document.documentElement).not.toHaveClass(CLASE_EN_HTML)

    await user.click(screen.getByRole('button', { name: 'Ir a la lista' }))
    expect(barraOpcional()).not.toBeNull()
    expect(document.documentElement).toHaveClass(CLASE_EN_HTML)
  })
})

// =============================================================================
// LA CLASE EN <html> (el alto que reserva index.css)
// =============================================================================

describe('MobileBottomNav — reserva su lugar abajo', () => {
  it('pone la clase en <html> al montarse y la saca al desmontarse', () => {
    expect(document.documentElement).not.toHaveClass(CLASE_EN_HTML)

    const { unmount } = renderNav(['preventista'])
    expect(document.documentElement).toHaveClass(CLASE_EN_HTML)

    unmount()
    expect(document.documentElement).not.toHaveClass(CLASE_EN_HTML)
  })

  it('sin barra (transportista puro) no la pone', () => {
    renderNav(['transportista'])
    expect(document.documentElement).not.toHaveClass(CLASE_EN_HTML)
  })

  it('con dos barras montadas, desmontar una no le saca la clase a la otra', () => {
    const primera = renderNav(['admin'])
    const segunda = renderNav(['deposito'], '/productos')

    primera.unmount()
    expect(document.documentElement).toHaveClass(CLASE_EN_HTML)

    segunda.unmount()
    expect(document.documentElement).not.toHaveClass(CLASE_EN_HTML)
  })
})
