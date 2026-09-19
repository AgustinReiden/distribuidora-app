/**
 * Caracterizacion de la barra de navegacion (`TopNavigation`).
 *
 * NO prueba lo que el menu DEBERIA mostrar: fija lo que muestra HOY, antes del
 * rediseno que va a reagrupar los items. Lo que no puede cambiar sin que alguien
 * lo decida es QUE VE CADA ROL; el orden y los grupos si van a moverse, asi que
 * los conjuntos se comparan ordenados alfabeticamente y no por posicion.
 *
 * El invariante que mas duele romper esta en "menu <-> router": un item de menu
 * que lleva a una ruta que ese rol no puede abrir se ve como un click que
 * rebota a /pedidos sin explicacion. La tabla RUTAS_PERMITIDAS_POR_ROL de abajo
 * esta derivada leyendo los gates de <Route> de src/App.tsx.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, useLocation } from 'react-router-dom'
import type { ReactElement } from 'react'

import type { PerfilDB, RolUsuario } from '../../../types'

// =============================================================================
// MOCKS
// =============================================================================

let rolesEfectivosMock: RolUsuario[] = ['admin']
vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ rolesEfectivos: rolesEfectivosMock }),
}))

let darkModeMock = false
const toggleDarkMode = vi.fn()
vi.mock('../../../contexts/ThemeContext', () => ({
  useTheme: () => ({ darkMode: darkModeMock, toggleDarkMode }),
}))

// Los tres hijos pesados se aislan: traen supabase, queries y estado propio, y
// ninguno participa de lo que se esta caracterizando.
vi.mock('../DbNotificationBell', () => ({
  default: (): ReactElement => <div>Campanita</div>,
}))
vi.mock('../SucursalSelector', () => ({
  default: (): ReactElement => <div>Selector de sucursal</div>,
}))
vi.mock('../../perfil/VincularTelegramButton', () => ({
  default: (): ReactElement => <div>Vincular Telegram</div>,
}))

// El build id real lo inyecta vite; acá se fija para que el texto de version
// sea determinista.
vi.mock('../../../hooks/useActualizacionDisponible', () => ({
  BUILD_ACTUAL: 'abc123def456',
}))

import TopNavigation from '../TopNavigation'

// =============================================================================
// TABLAS DE REFERENCIA
// =============================================================================

/**
 * A que rutas puede ENTRAR cada rol, leido de los gates de <Route> en
 * src/App.tsx (lineas 283-411). Ojo: los gates miran el rol PRIMARIO
 * (`effectiveRol`), no la union `rolesEfectivos` que usa este menu.
 *
 *   L283-286  /dashboard             isAdmin || isPreventista
 *   L288-293  /mis-entregas          isPreventista || isAdminOrEncargado
 *   L295-297  /pedidos /clientes /productos   SIN gate: entran todos
 *   L299-302  /reportes              isAdmin
 *   L304-307  /usuarios              isAdmin
 *   L309-312  /configuracion         isAdminOrEncargado
 *   L314-317  /recorridos            isAdminOrEncargado
 *   L319-322  /recorrido-preventista isAdminOrEncargado
 *   L324-327  /compras               isAdminOrEncargado
 *   L329-332  /proveedores           isAdmin
 *   L338-343  /vencimientos          isAdminOrEncargado || effectiveRol === 'deposito'
 *   L357-360  /horarios-clientes     isAdminOrEncargado
 *   L362-365  /promociones           isAdmin
 *   L367-370  /transferencias        isAdminOrEncargado
 *   L372-375  /rendiciones           isAdminOrEncargado
 *   L377-380  /salvedades            isAdminOrEncargado
 *   L382-385  /analytics             isAdmin
 *   L387-390  /comisiones            isAdmin
 *   L392-395  /metas                 isAdmin
 *   L397-400  /reportes-gerenciales  isAdmin
 *   L402-405  /bot-telegram          isAdmin
 *   L407-410  /geolocalizacion       isAdmin
 */
const RUTAS_PERMITIDAS_POR_ROL: Record<RolUsuario, readonly string[]> = {
  admin: [
    '/dashboard', '/mis-entregas', '/pedidos', '/clientes', '/productos',
    '/reportes', '/usuarios', '/configuracion', '/recorridos', '/recorrido-preventista',
    '/compras', '/proveedores', '/vencimientos', '/horarios-clientes', '/promociones',
    '/transferencias', '/rendiciones', '/salvedades', '/analytics', '/comisiones',
    '/metas', '/reportes-gerenciales', '/bot-telegram', '/geolocalizacion',
  ],
  encargado: [
    '/mis-entregas', '/pedidos', '/clientes', '/productos', '/configuracion',
    '/recorridos', '/recorrido-preventista', '/compras', '/vencimientos',
    '/horarios-clientes', '/transferencias', '/rendiciones', '/salvedades',
  ],
  preventista: ['/dashboard', '/mis-entregas', '/pedidos', '/clientes', '/productos'],
  transportista: ['/pedidos', '/clientes', '/productos'],
  deposito: ['/pedidos', '/clientes', '/productos', '/vencimientos'],
}

/** Los dos items con `hidden: true` en la config del menu. No los ve nadie. */
const ITEMS_OCULTOS = ['Recorrido Preventista', 'Centro de Analisis'] as const

const LABELS_POR_ROL = {
  admin: [
    'Dashboard', 'Pedidos', 'Mis entregas',
    'Clientes', 'Reportes', 'Reportes Gerenciales', 'Comisiones', 'Objetivos',
    'Productos', 'Compras', 'Vencimientos', 'Proveedores', 'Promociones', 'Mov. Sucursales',
    'Recorridos', 'Rendiciones', 'Salvedades', 'Geolocalización', 'Horarios a revisar',
    'Usuarios', 'Bot Telegram', 'Configuración',
  ],
  encargado: [
    'Pedidos', 'Mis entregas',
    'Clientes',
    'Productos', 'Compras', 'Vencimientos', 'Mov. Sucursales',
    'Recorridos', 'Rendiciones', 'Salvedades', 'Horarios a revisar', 'Configuración',
  ],
  preventista: ['Dashboard', 'Pedidos', 'Mis entregas', 'Clientes', 'Productos'],
  transportista: ['Pedidos'],
  deposito: ['Pedidos', 'Productos', 'Vencimientos'],
} as const satisfies Record<RolUsuario, readonly string[]>

/** Label del menu -> ruta a la que navega (el id del item). */
const RUTA_DE_LA_ETIQUETA: Record<string, string> = {
  'Dashboard': '/dashboard',
  'Pedidos': '/pedidos',
  'Mis entregas': '/mis-entregas',
  'Clientes': '/clientes',
  'Reportes': '/reportes',
  'Reportes Gerenciales': '/reportes-gerenciales',
  'Comisiones': '/comisiones',
  'Objetivos': '/metas',
  'Productos': '/productos',
  'Compras': '/compras',
  'Vencimientos': '/vencimientos',
  'Proveedores': '/proveedores',
  'Promociones': '/promociones',
  'Mov. Sucursales': '/transferencias',
  'Recorridos': '/recorridos',
  'Rendiciones': '/rendiciones',
  'Salvedades': '/salvedades',
  'Geolocalización': '/geolocalizacion',
  'Horarios a revisar': '/horarios-clientes',
  'Usuarios': '/usuarios',
  'Bot Telegram': '/bot-telegram',
  'Configuración': '/configuracion',
}

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
  const { pathname } = useLocation()
  return <p>{`Ruta actual: ${pathname}`}</p>
}

function renderNav(
  roles: RolUsuario[],
  opciones: { perfil?: PerfilDB | null; onLogout?: () => void; oscuro?: boolean } = {},
): { onLogout: () => void } {
  rolesEfectivosMock = roles
  darkModeMock = opciones.oscuro ?? false
  const onLogout = opciones.onLogout ?? vi.fn()

  render(
    <MemoryRouter initialEntries={['/pedidos']}>
      <TopNavigation
        perfil={opciones.perfil === undefined ? PERFIL : opciones.perfil}
        onLogout={onLogout}
      />
      <RutaActual />
    </MemoryRouter>,
  )
  return { onLogout }
}

const navEscritorio = (): HTMLElement =>
  screen.getByRole('navigation', { name: 'Navegacion principal' })

const navMovil = (): HTMLElement => {
  const escritorio = navEscritorio()
  const otra = screen.getAllByRole('navigation').find(nav => nav !== escritorio)
  if (!otra) throw new Error('No se encontro el nav del menu movil')
  return otra
}

const textoDe = (el: Element): string => (el.textContent ?? '').trim()
const ordenado = (labels: readonly string[]): string[] => [...labels].sort()

/**
 * Abre cada grupo desplegable del menu de escritorio y devuelve todas las
 * etiquetas visibles (items sueltos + items de cada grupo).
 */
async function etiquetasDelEscritorio(): Promise<string[]> {
  const user = userEvent.setup()
  const nav = navEscritorio()
  const primerNivel = within(nav).queryAllByRole('button')
  const etiquetas: string[] = []

  for (const boton of primerNivel) {
    if (boton.getAttribute('aria-haspopup') === 'true') {
      await user.click(boton)
      const desplegable = within(nav).getByRole('menu')
      etiquetas.push(...within(desplegable).getAllByRole('menuitem').map(textoDe))
      await user.click(boton) // cerrar antes de pasar al grupo siguiente
    } else {
      etiquetas.push(textoDe(boton))
    }
  }
  return etiquetas
}

const etiquetasDelMovil = (): string[] =>
  within(navMovil()).queryAllByRole('button').map(textoDe)

/** Clickea un item del menu de escritorio, este suelto o dentro de un grupo. */
async function irA(etiqueta: string): Promise<void> {
  const user = userEvent.setup()
  const nav = navEscritorio()

  const suelto = within(nav).queryByRole('button', { name: etiqueta })
  if (suelto) {
    await user.click(suelto)
    return
  }

  const grupos = within(nav)
    .queryAllByRole('button')
    .filter(b => b.getAttribute('aria-haspopup') === 'true')

  for (const grupo of grupos) {
    await user.click(grupo)
    const desplegable = within(nav).getByRole('menu')
    const item = within(desplegable).queryByRole('menuitem', { name: etiqueta })
    if (item) {
      await user.click(item)
      return
    }
    await user.click(grupo)
  }
  throw new Error(`No hay ningun item de menu con la etiqueta "${etiqueta}"`)
}

beforeEach(() => {
  toggleDarkMode.mockClear()
})

// =============================================================================
// A) MATRIZ ROL -> ITEMS
// =============================================================================

describe('TopNavigation — que ve cada rol', () => {
  it.each(Object.keys(LABELS_POR_ROL) as RolUsuario[])(
    'el rol %s ve exactamente sus items en el menu de escritorio',
    async rol => {
      renderNav([rol])
      expect(ordenado(await etiquetasDelEscritorio())).toEqual(ordenado(LABELS_POR_ROL[rol]))
    },
  )

  it.each(Object.keys(LABELS_POR_ROL) as RolUsuario[])(
    'el rol %s ve los mismos items en el menu movil',
    rol => {
      renderNav([rol])
      expect(ordenado(etiquetasDelMovil())).toEqual(ordenado(LABELS_POR_ROL[rol]))
    },
  )

  it('el multi-rol preventista+transportista ve la union — que es lo mismo que el preventista solo', async () => {
    renderNav(['preventista', 'transportista'])
    // El unico item del transportista es "Pedidos", que el preventista ya tenia:
    // sumar el rol extra no le agrega ni una entrada al menu.
    expect(ordenado(await etiquetasDelEscritorio()))
      .toEqual(ordenado(LABELS_POR_ROL.preventista))
  })

  it('sin roles efectivos el menu queda vacio, en escritorio y en movil', () => {
    renderNav([])
    expect(within(navEscritorio()).queryAllByRole('button')).toHaveLength(0)
    expect(within(navMovil()).queryAllByRole('button')).toHaveLength(0)
  })

  it.each(Object.keys(LABELS_POR_ROL) as RolUsuario[])(
    'los items hidden no se le muestran al rol %s',
    async rol => {
      renderNav([rol])
      const visibles = await etiquetasDelEscritorio()
      for (const oculto of ITEMS_OCULTOS) {
        expect(visibles).not.toContain(oculto)
      }
      expect(etiquetasDelMovil()).not.toContain('Recorrido Preventista')
      expect(etiquetasDelMovil()).not.toContain('Centro de Analisis')
    },
  )

  it.each(['preventista', 'transportista', 'deposito'] as const)(
    'el grupo "Operaciones" no existe para %s',
    rol => {
      renderNav([rol])
      expect(within(navEscritorio()).queryByRole('button', { name: /Operaciones/ })).toBeNull()
    },
  )
})

// =============================================================================
// NAVEGACION
// =============================================================================

describe('TopNavigation — navegar', () => {
  it('un item suelto navega a "/<id>"', async () => {
    renderNav(['admin'])
    await irA('Dashboard')
    expect(screen.getByText('Ruta actual: /dashboard')).toBeInTheDocument()
  })

  it('un item dentro de un grupo navega a "/<id>"', async () => {
    renderNav(['admin'])
    await irA('Clientes')
    expect(screen.getByText('Ruta actual: /clientes')).toBeInTheDocument()
  })

  it('"Mov. Sucursales" navega a /transferencias, no a /mov-sucursales', async () => {
    renderNav(['admin'])
    await irA('Mov. Sucursales')
    expect(screen.getByText('Ruta actual: /transferencias')).toBeInTheDocument()
  })

  it('"Objetivos" navega a /metas', async () => {
    renderNav(['admin'])
    await irA('Objetivos')
    expect(screen.getByText('Ruta actual: /metas')).toBeInTheDocument()
  })

  it('al elegir un item el grupo se cierra', async () => {
    renderNav(['admin'])
    await irA('Clientes')
    expect(within(navEscritorio()).queryByRole('menu')).toBeNull()
  })

  it('abrir un grupo marca aria-expanded y cerrarlo lo devuelve a false', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    const grupo = within(navEscritorio()).getByRole('button', { name: /Comercial/ })

    expect(grupo).toHaveAttribute('aria-expanded', 'false')
    await user.click(grupo)
    expect(grupo).toHaveAttribute('aria-expanded', 'true')
    await user.click(grupo)
    expect(grupo).toHaveAttribute('aria-expanded', 'false')
  })
})

// =============================================================================
// INVARIANTE MENU <-> ROUTER
// =============================================================================

describe('TopNavigation — invariante menu <-> router', () => {
  it.each(Object.keys(LABELS_POR_ROL) as RolUsuario[])(
    'todo item visible para %s lleva a una ruta que ese rol puede abrir',
    async rol => {
      renderNav([rol])
      const visibles = await etiquetasDelEscritorio()
      expect(visibles.length).toBeGreaterThan(0)

      for (const etiqueta of visibles) {
        const ruta = RUTA_DE_LA_ETIQUETA[etiqueta]
        expect(ruta, `falta la ruta de "${etiqueta}" en la tabla del test`).toBeDefined()
        expect(
          RUTAS_PERMITIDAS_POR_ROL[rol],
          `"${etiqueta}" -> ${ruta} no esta habilitada para ${rol} en App.tsx`,
        ).toContain(ruta)
      }
    },
  )

  it.each(LABELS_POR_ROL.encargado)(
    'el item "%s" del encargado navega de verdad a la ruta que dice la tabla',
    async etiqueta => {
      renderNav(['encargado'])
      await irA(etiqueta)
      expect(screen.getByText(`Ruta actual: ${RUTA_DE_LA_ETIQUETA[etiqueta]}`)).toBeInTheDocument()
    },
  )

  it('el multi-rol preventista+transportista no ofrece nada fuera de su router', async () => {
    renderNav(['preventista', 'transportista'])
    // El rol PRIMARIO es el primero de rolesEfectivos (App.tsx L236-239), y es
    // contra ese que gatean las <Route>.
    for (const etiqueta of await etiquetasDelEscritorio()) {
      expect(RUTAS_PERMITIDAS_POR_ROL.preventista).toContain(RUTA_DE_LA_ETIQUETA[etiqueta])
    }
  })

  it('el multi-rol transportista+preventista SI ofrece rutas que el router le rebota', async () => {
    // BUG: el menu filtra por la UNION `rolesEfectivos` (TopNavigation L140) y
    // las <Route> gatean por el rol PRIMARIO (`effectiveRol`, App.tsx L225-234).
    // Para un transportista con 'preventista' como rol extra (mig 155) el menu
    // ofrece "Dashboard" y "Mis entregas", pero /dashboard exige
    // isAdmin||isPreventista y /mis-entregas isPreventista||isAdminOrEncargado,
    // las dos calculadas sobre el rol primario 'transportista': el click rebota
    // a /pedidos sin ningun mensaje. Se asevera el comportamiento ACTUAL.
    renderNav(['transportista', 'preventista'])
    const visibles = await etiquetasDelEscritorio()

    expect(ordenado(visibles))
      .toEqual(ordenado(['Dashboard', 'Pedidos', 'Mis entregas', 'Clientes', 'Productos']))

    const fueraDelRouter = visibles
      .map(etiqueta => RUTA_DE_LA_ETIQUETA[etiqueta])
      .filter(ruta => !RUTAS_PERMITIDAS_POR_ROL.transportista.includes(ruta))
    expect(fueraDelRouter).toEqual(['/dashboard', '/mis-entregas'])
  })
})

// =============================================================================
// MENU MOVIL
// =============================================================================

describe('TopNavigation — menu movil', () => {
  it('el boton arranca como "Abrir menu" con aria-expanded en false', () => {
    renderNav(['admin'])
    const boton = screen.getByRole('button', { name: 'Abrir menu' })
    expect(boton).toHaveAttribute('aria-expanded', 'false')
  })

  it('al abrirlo pasa a llamarse "Cerrar menu" y marca aria-expanded', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Abrir menu' }))

    const boton = screen.getByRole('button', { name: 'Cerrar menu' })
    expect(boton).toHaveAttribute('aria-expanded', 'true')
  })

  it('un segundo click en la hamburguesa NO lo cierra', async () => {
    // BUG: el `mousedown` del listener de "click afuera" (TopNavigation
    // L152-171) ya pone menuAbierto=false porque el boton vive en el header y
    // no dentro de `menuRef`; para cuando corre el `onClick` el estado ya es
    // false y `setMenuAbierto(!menuAbierto)` lo vuelve a abrir. El menu queda
    // abierto y aria-expanded en "true". Se cierra eligiendo un item o tocando
    // el overlay; por el boton, no. Se asevera el comportamiento ACTUAL.
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(screen.getByRole('button', { name: 'Abrir menu' }))
    await user.click(screen.getByRole('button', { name: 'Cerrar menu' }))

    expect(screen.getByRole('button', { name: 'Cerrar menu' }))
      .toHaveAttribute('aria-expanded', 'true')
  })

  it('elegir un item del menu movil navega y cierra el menu', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Abrir menu' }))

    await user.click(within(navMovil()).getByRole('button', { name: 'Clientes' }))

    expect(screen.getByText('Ruta actual: /clientes')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Abrir menu' }))
      .toHaveAttribute('aria-expanded', 'false')
  })

  it('muestra los titulos de los grupos que le tocan al rol', () => {
    renderNav(['admin'])
    const movil = navMovil()
    expect(within(movil).getByText('Comercial')).toBeInTheDocument()
    expect(within(movil).getByText('Inventario')).toBeInTheDocument()
    expect(within(movil).getByText('Operaciones')).toBeInTheDocument()
  })

  it('al deposito no le muestra los grupos que no puede ver', () => {
    renderNav(['deposito'])
    const movil = navMovil()
    expect(within(movil).getByText('Inventario')).toBeInTheDocument()
    expect(within(movil).queryByText('Comercial')).toBeNull()
    expect(within(movil).queryByText('Operaciones')).toBeNull()
  })
})

// =============================================================================
// MENU DE USUARIO
// =============================================================================

describe('TopNavigation — menu de usuario', () => {
  it('muestra nombre, email, label del rol y la version del build', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Menu de usuario' }))

    expect(screen.getByText('Jorge Perez')).toBeInTheDocument()
    expect(screen.getByText('jorge@distribuidora.test')).toBeInTheDocument()
    expect(screen.getByText('Admin')).toBeInTheDocument()
    expect(screen.getByText('Version abc123def456')).toBeInTheDocument()
  })

  it('"Cerrar sesion" llama a onLogout', async () => {
    const { onLogout } = renderNav(['admin'])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Menu de usuario' }))
    await user.click(screen.getByRole('button', { name: 'Cerrar sesion' }))

    expect(onLogout).toHaveBeenCalledTimes(1)
  })

  it('el boton cerrado no ofrece "Cerrar sesion"', () => {
    renderNav(['admin'])
    expect(screen.queryByRole('button', { name: 'Cerrar sesion' })).toBeNull()
  })

  it('un segundo click en el boton de usuario cierra el menu', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    const boton = screen.getByRole('button', { name: 'Menu de usuario' })

    await user.click(boton)
    expect(boton).toHaveAttribute('aria-expanded', 'true')
    await user.click(boton)
    expect(boton).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('button', { name: 'Cerrar sesion' })).toBeNull()
  })

  it('el label del rol sale de perfil.rol, no de los roles efectivos', async () => {
    renderNav(['admin'], {
      perfil: { id: 'u-9', nombre: 'Ana Gomez', email: 'ana@t.test', rol: 'encargado' } as unknown as PerfilDB,
    })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Menu de usuario' }))

    expect(screen.getByText('Encargado')).toBeInTheDocument()
  })

  it('sin perfil muestra "Usuario" y el rol como "Sin rol"', async () => {
    renderNav(['admin'], { perfil: null })
    const user = userEvent.setup()

    expect(screen.getByRole('button', { name: 'Menu de usuario' })).toHaveTextContent('Usuario')
    await user.click(screen.getByRole('button', { name: 'Menu de usuario' }))
    expect(screen.getByText('Sin rol')).toBeInTheDocument()
  })
})

// =============================================================================
// TEMA
// =============================================================================

describe('TopNavigation — boton de tema', () => {
  it('en claro ofrece "Cambiar a modo oscuro" y llama a toggleDarkMode', async () => {
    renderNav(['admin'], { oscuro: false })
    const user = userEvent.setup()

    const boton = screen.getByRole('button', { name: 'Cambiar a modo oscuro' })
    expect(screen.queryByRole('button', { name: 'Cambiar a modo claro' })).toBeNull()

    await user.click(boton)
    expect(toggleDarkMode).toHaveBeenCalledTimes(1)
  })

  it('en oscuro ofrece "Cambiar a modo claro"', async () => {
    renderNav(['admin'], { oscuro: true })
    const user = userEvent.setup()

    const boton = screen.getByRole('button', { name: 'Cambiar a modo claro' })
    expect(screen.queryByRole('button', { name: 'Cambiar a modo oscuro' })).toBeNull()

    await user.click(boton)
    expect(toggleDarkMode).toHaveBeenCalledTimes(1)
  })
})
