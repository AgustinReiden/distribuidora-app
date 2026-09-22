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
 * (`effectiveRol`), no la union `rolesEfectivos`; desde #731 el menu filtra
 * igual para los items con gate (rol primario, y de los extras solo el
 * transportista), y por la union para las tres rutas sin gate.
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

/**
 * Etiquetas que no ve nadie: el item con `hidden: true` en la config del menu, y
 * el label viejo de /analytics, que desde #713 se ve como "Exportar a Power BI"
 * y no tiene que volver a aparecer con el nombre anterior.
 */
const ITEMS_OCULTOS = ['Recorrido Preventista', 'Centro de Analisis'] as const

/**
 * Lo que cada rol ve en la barra y en el panel desplegable. Usuarios,
 * Configuración y Bot Telegram no estan: desde #713 viven en el menu del
 * usuario (ADMINISTRACION_POR_ROL).
 */
const LABELS_POR_ROL = {
  admin: [
    'Dashboard', 'Pedidos', 'Mis entregas',
    'Clientes', 'Reportes', 'Reportes Gerenciales', 'Exportar a Power BI', 'Comisiones', 'Objetivos',
    'Productos', 'Compras', 'Vencimientos', 'Proveedores', 'Promociones', 'Mov. Sucursales',
    'Recorridos', 'Rendiciones', 'Salvedades', 'Geolocalización', 'Horarios a revisar',
  ],
  encargado: [
    'Pedidos', 'Mis entregas',
    'Clientes',
    'Productos', 'Compras', 'Vencimientos', 'Mov. Sucursales',
    'Recorridos', 'Rendiciones', 'Salvedades', 'Horarios a revisar',
  ],
  preventista: ['Dashboard', 'Pedidos', 'Mis entregas', 'Clientes', 'Productos'],
  transportista: ['Pedidos'],
  deposito: ['Pedidos', 'Productos', 'Vencimientos'],
} as const satisfies Record<RolUsuario, readonly string[]>

/** La seccion "Administración" del menu del usuario, por rol (#713). */
const ADMINISTRACION_POR_ROL = {
  admin: ['Usuarios', 'Configuración', 'Bot Telegram'],
  encargado: ['Configuración'],
  preventista: [],
  transportista: [],
  deposito: [],
} as const satisfies Record<RolUsuario, readonly string[]>

/**
 * Los items cuyas <Route> no tienen gate (App.tsx L295-297): los abre
 * cualquier rol, asi que el rol extra si los suma (#731).
 */
const ETIQUETAS_SIN_GATE: readonly string[] = ['Pedidos', 'Clientes', 'Productos']

/** Label del menu -> ruta a la que navega (el id del item). */
const RUTA_DE_LA_ETIQUETA: Record<string, string> = {
  'Dashboard': '/dashboard',
  'Pedidos': '/pedidos',
  'Mis entregas': '/mis-entregas',
  'Clientes': '/clientes',
  'Reportes': '/reportes',
  'Reportes Gerenciales': '/reportes-gerenciales',
  'Exportar a Power BI': '/analytics',
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

const seccionAdministracion = (): HTMLElement | null =>
  screen.queryByRole('group', { name: 'Administración' })

/**
 * Abre el menu del usuario, devuelve las etiquetas de su seccion
 * "Administración" (vacio si no la hay) y lo vuelve a cerrar.
 */
async function etiquetasDeAdministracion(): Promise<string[]> {
  const user = userEvent.setup()
  const boton = screen.getByRole('button', { name: 'Menu de usuario' })
  await user.click(boton)
  const seccion = seccionAdministracion()
  const etiquetas = seccion ? within(seccion).getAllByRole('button').map(textoDe) : []
  await user.click(boton)
  return etiquetas
}

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

  it.each(['admin', 'encargado', 'preventista', 'deposito'] as const)(
    'el %s con transportista como rol extra ve lo mismo que su rol solo, en escritorio y en movil',
    async rol => {
      renderNav([rol, 'transportista'])
      // El transportista solo aporta "Pedidos", que todos estos roles ya tienen:
      // el extra no suma ni quita nada.
      expect(ordenado(await etiquetasDelEscritorio())).toEqual(ordenado(LABELS_POR_ROL[rol]))
      expect(ordenado(etiquetasDelMovil())).toEqual(ordenado(LABELS_POR_ROL[rol]))
    },
  )

  it('un rol extra que no es transportista no suma items con gate: el encargado con preventista extra no ve "Dashboard"', async () => {
    renderNav(['encargado', 'preventista'])
    // /dashboard exige isAdmin || isPreventista, calculadas sobre el rol
    // primario (App.tsx): ofrecerlo seria un click que rebota a /pedidos.
    const visibles = await etiquetasDelEscritorio()
    expect(visibles).not.toContain('Dashboard')
    expect(ordenado(visibles)).toEqual(ordenado(LABELS_POR_ROL.encargado))
  })

  it('el deposito con preventista extra suma "Clientes" (sin gate) y no "Dashboard" ni "Mis entregas"', async () => {
    renderNav(['deposito', 'preventista'])
    // /clientes no tiene gate en App.tsx: la abre el deposito igual. /dashboard
    // y /mis-entregas si, sobre el rol primario: se las rebotaria.
    const esperado = ordenado([...LABELS_POR_ROL.deposito, 'Clientes'])
    expect(ordenado(await etiquetasDelEscritorio())).toEqual(esperado)
    expect(ordenado(etiquetasDelMovil())).toEqual(esperado)
  })

  it('sin roles efectivos el menu queda vacio, en escritorio y en movil', () => {
    renderNav([])
    expect(within(navEscritorio()).queryAllByRole('button')).toHaveLength(0)
    expect(within(navMovil()).queryAllByRole('button')).toHaveLength(0)
  })

  it('sin roles efectivos el menu del usuario no tiene seccion "Administración"', async () => {
    renderNav([])
    expect(await etiquetasDeAdministracion()).toEqual([])
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
// ADMINISTRACION EN EL MENU DEL USUARIO Y "EXPORTAR A POWER BI" (#713)
// =============================================================================

describe('TopNavigation — Administración en el menu del usuario y "Exportar a Power BI"', () => {
  async function itemsDelGrupo(nombre: RegExp): Promise<string[]> {
    const user = userEvent.setup()
    await user.click(within(navEscritorio()).getByRole('button', { name: nombre }))
    const desplegable = within(navEscritorio()).getByRole('menu')
    return within(desplegable).getAllByRole('menuitem').map(textoDe)
  }

  it('el admin ve "Exportar a Power BI" en Comercial, junto a los reportes', async () => {
    renderNav(['admin'])
    const comercial = await itemsDelGrupo(/Comercial/)
    expect(comercial).toContain('Exportar a Power BI')
    expect(comercial).toContain('Reportes')
    expect(comercial).toContain('Reportes Gerenciales')
  })

  it('"Exportar a Power BI" navega a /analytics', async () => {
    renderNav(['admin'])
    await irA('Exportar a Power BI')
    expect(screen.getByText('Ruta actual: /analytics')).toBeInTheDocument()
  })

  it('el encargado no ve "Exportar a Power BI"', async () => {
    renderNav(['encargado'])
    expect(await etiquetasDelEscritorio()).not.toContain('Exportar a Power BI')
    expect(etiquetasDelMovil()).not.toContain('Exportar a Power BI')
  })

  it('el menu del usuario cerrado no ofrece la seccion "Administración"', () => {
    renderNav(['admin'])
    expect(seccionAdministracion()).toBeNull()
    expect(screen.queryByText('Administración')).toBeNull()
  })

  it('el admin ve en el menu del usuario la seccion "Administración" con Usuarios, Configuración y Bot Telegram', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Menu de usuario' }))

    const seccion = screen.getByRole('group', { name: 'Administración' })
    expect(within(seccion).getByText('Administración')).toBeInTheDocument()
    expect(ordenado(within(seccion).getAllByRole('button').map(textoDe)))
      .toEqual(ordenado(['Usuarios', 'Configuración', 'Bot Telegram']))
    // "Cerrar sesion" sigue en el menu, fuera de la seccion.
    expect(within(seccion).queryByRole('button', { name: 'Cerrar sesion' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Cerrar sesion' })).toBeInTheDocument()
  })

  it('el encargado ve en la seccion "Administración" solo "Configuración"', async () => {
    renderNav(['encargado'])
    expect(await etiquetasDeAdministracion()).toEqual(['Configuración'])
  })

  it.each(['preventista', 'transportista', 'deposito'] as const)(
    'el %s no ve la seccion "Administración" en el menu del usuario',
    async rol => {
      renderNav([rol])
      const user = userEvent.setup()
      await user.click(screen.getByRole('button', { name: 'Menu de usuario' }))

      // El menu esta abierto: "Cerrar sesion" se ve y la seccion no.
      expect(screen.getByRole('button', { name: 'Cerrar sesion' })).toBeInTheDocument()
      expect(seccionAdministracion()).toBeNull()
      expect(screen.queryByText('Administración')).toBeNull()
      for (const item of ['Usuarios', 'Configuración', 'Bot Telegram']) {
        expect(screen.queryByRole('button', { name: item })).toBeNull()
      }
    },
  )

  it.each([
    ['admin', 'Usuarios'],
    ['admin', 'Configuración'],
    ['admin', 'Bot Telegram'],
    ['encargado', 'Configuración'],
  ] as const)(
    'el %s elige "%s" en el menu del usuario: navega a su ruta y cierra el menu',
    async (rol, etiqueta) => {
      renderNav([rol])
      const user = userEvent.setup()
      const boton = screen.getByRole('button', { name: 'Menu de usuario' })
      await user.click(boton)

      const seccion = screen.getByRole('group', { name: 'Administración' })
      await user.click(within(seccion).getByRole('button', { name: etiqueta }))

      expect(screen.getByText(`Ruta actual: ${RUTA_DE_LA_ETIQUETA[etiqueta]}`)).toBeInTheDocument()
      expect(boton).toHaveAttribute('aria-expanded', 'false')
      expect(seccionAdministracion()).toBeNull()
    },
  )

  it.each(['admin', 'encargado'] as const)(
    'para el %s, Usuarios, Configuración y Bot Telegram ya no estan en la barra ni en el panel',
    async rol => {
      renderNav([rol])
      const barra = await etiquetasDelEscritorio()
      const panel = etiquetasDelMovil()
      for (const movido of ['Usuarios', 'Configuración', 'Bot Telegram']) {
        expect(barra).not.toContain(movido)
        expect(panel).not.toContain(movido)
      }
      // Tampoco como grupo: ni boton en la barra ni titulo en el panel.
      expect(within(navEscritorio()).queryByRole('button', { name: /Administración/ })).toBeNull()
      expect(within(navMovil()).queryByText('Administración')).toBeNull()
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
      // La barra y, desde #713, la seccion "Administración" del menu del usuario.
      const administracion = await etiquetasDeAdministracion()
      expect(ordenado(administracion)).toEqual(ordenado(ADMINISTRACION_POR_ROL[rol]))
      const visibles = [...await etiquetasDelEscritorio(), ...administracion]
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

  it('el multi-rol transportista+preventista ya no ofrece rutas que el router le rebota: ve Pedidos, Clientes y Productos', async () => {
    // #731: las <Route> gatean por el rol PRIMARIO (`effectiveRol`, App.tsx
    // L225-234). Cuando el menu filtraba todo por la union `rolesEfectivos`, a
    // un transportista con 'preventista' como rol extra (mig 155) le ofrecia
    // "Dashboard" y "Mis entregas", y el click rebotaba a /pedidos sin ningun
    // mensaje. Ahora esas dos se filtran por el rol primario; "Clientes" y
    // "Productos" no tienen gate (App.tsx L295-297), y el extra si las suma.
    renderNav(['transportista', 'preventista'])
    const visibles = await etiquetasDelEscritorio()

    expect(visibles).not.toContain('Dashboard')
    expect(visibles).not.toContain('Mis entregas')
    expect(ordenado(visibles)).toEqual(ordenado(['Pedidos', 'Clientes', 'Productos']))
    expect(ordenado(etiquetasDelMovil())).toEqual(ordenado(['Pedidos', 'Clientes', 'Productos']))

    const fueraDelRouter = visibles
      .map(etiqueta => RUTA_DE_LA_ETIQUETA[etiqueta])
      .filter(ruta => !RUTAS_PERMITIDAS_POR_ROL.transportista.includes(ruta))
    expect(fueraDelRouter).toEqual([])
  })

  const ROLES = Object.keys(LABELS_POR_ROL) as RolUsuario[]
  const MULTI_ROLES = ROLES.flatMap(primario =>
    ROLES.filter(extra => extra !== primario).map(extra => [primario, extra] as const),
  )

  it.each(MULTI_ROLES)(
    'el multi-rol %s (primario) + %s (extra) no ofrece nada que el router del primario rebote',
    async (primario, extra) => {
      // Ninguna <Route> gatea por isTransportista (el unico flag que suma los
      // extras), asi que el router de este usuario es el de su rol primario,
      // mas las tres rutas sin gate, que abre cualquiera. Lo que ve es lo de su
      // primario mas lo sin gate que le toca al extra.
      renderNav([primario, extra])
      const barra = await etiquetasDelEscritorio()
      const administracion = await etiquetasDeAdministracion()

      for (const etiqueta of [...barra, ...administracion]) {
        expect(
          RUTAS_PERMITIDAS_POR_ROL[primario],
          `"${etiqueta}" rebota para ${primario} con ${extra} extra`,
        ).toContain(RUTA_DE_LA_ETIQUETA[etiqueta])
      }

      const sinGateDelExtra = LABELS_POR_ROL[extra].filter(e => ETIQUETAS_SIN_GATE.includes(e))
      expect(ordenado(barra))
        .toEqual(ordenado([...new Set([...LABELS_POR_ROL[primario], ...sinGateDelExtra])]))
      // Administración tiene gate en las tres rutas: la decide el primario.
      expect(ordenado(administracion)).toEqual(ordenado(ADMINISTRACION_POR_ROL[primario]))
    },
  )
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

  it('un segundo click en la hamburguesa lo cierra', async () => {
    // #730: el boton vive en el header, fuera de `menuRef`. El `mousedown` del
    // listener de "click afuera" cerraba el menu y el `onClick` del mismo toque
    // lo volvia a abrir. Ahora el listener ignora los toques sobre la
    // hamburguesa y el unico que la alterna es su onClick.
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(screen.getByRole('button', { name: 'Abrir menu' }))
    await user.click(screen.getByRole('button', { name: 'Cerrar menu' }))

    expect(screen.queryByRole('button', { name: 'Cerrar menu' })).toBeNull()
    expect(screen.getByRole('button', { name: 'Abrir menu' }))
      .toHaveAttribute('aria-expanded', 'false')
  })

  it('un click afuera del menu movil abierto lo sigue cerrando', async () => {
    renderNav(['admin'])
    const user = userEvent.setup()

    await user.click(screen.getByRole('button', { name: 'Abrir menu' }))
    await user.click(screen.getByText(/Ruta actual:/))

    expect(screen.getByRole('button', { name: 'Abrir menu' }))
      .toHaveAttribute('aria-expanded', 'false')
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
// DESTINO DEL SKIP LINK
// =============================================================================

describe('TopNavigation — destino del skip link "Ir a la navegación"', () => {
  // SkipLinks.tsx enfoca document.getElementById('main-navigation'). Desde #713
  // la barra solo se muestra desde 2xl, asi que el destino tiene que envolver
  // tambien a la hamburguesa, que es la navegacion en cualquier ancho menor.
  it('envuelve a la hamburguesa y a la barra de navegacion', () => {
    renderNav(['admin'])
    const destino = document.getElementById('main-navigation')
    if (!destino) throw new Error('No hay ningun elemento con id "main-navigation"')
    expect(within(destino).getByRole('button', { name: 'Abrir menu' })).toBeInTheDocument()
    expect(within(destino).getByRole('navigation', { name: 'Navegacion principal' })).toBeInTheDocument()
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
