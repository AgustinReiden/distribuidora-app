/**
 * #823: la condición «esta pantalla es la ruta activa del transportista».
 *
 * Tres partes:
 *  1. Casos legibles por rol sobre las funciones puras.
 *  2. Equivalencia exhaustiva contra las TRES expresiones que había antes
 *     (VistaPedidos, PedidosContainer y TopNavigation), copiadas acá tal cual.
 *     La de la vista se prueba además renderizando la VistaPedidos real, para
 *     que el test no dependa de una copia de lo que hoy hace el componente.
 *  3. Que las tres coincidan entre sí en cuándo se ve el mapa (la barra
 *     inferior del celular no puede aparecer sobre él ni faltar fuera de él).
 */
import { createElement, type ReactNode } from 'react'
import { render } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import {
  esTransportistaPuro,
  muestraRutaActiva,
  puedeAlternarRuta,
  rolesRutaActivaDesdeRolPrimario,
  type RolesRutaActiva,
} from './rutaActiva'
import VistaPedidos, { type VistaPedidosProps } from '../components/vistas/VistaPedidos'

// La vista real se renderiza con sus hijos pesados reemplazados por marcas que
// dicen qué pantalla se montó y con qué props condicionales.
vi.mock('../components/rutaActiva/RutaActivaTransportista', async () => {
  const { createElement: h } = await import('react')
  return {
    default: ({ onVolver }: { onVolver?: () => void }) =>
      h('div', { 'data-pantalla': 'mapa', 'data-con-volver': String(onVolver !== undefined) }),
  }
})
vi.mock('../components/pedidos', async () => {
  const { createElement: h } = await import('react')
  const nada = () => h('div')
  return { PedidoCard: nada, PedidoFilters: nada, PedidoStats: nada }
})
vi.mock('../components/pedidos/PedidosViewHeader', async () => {
  const { createElement: h } = await import('react')
  return {
    default: ({ actions }: { actions?: ReactNode }) =>
      h('div', { 'data-pantalla': 'lista' }, actions),
  }
})
vi.mock('../components/pedidos/PedidoToolbar', async () => {
  const { createElement: h } = await import('react')
  return {
    default: ({ onVerMiRuta }: { onVerMiRuta?: () => void }) =>
      h('span', { 'data-con-mi-ruta': String(onVerMiRuta !== undefined) }),
  }
})

const roles = (r: Partial<RolesRutaActiva>): RolesRutaActiva => ({
  isAdmin: false,
  isPreventista: false,
  isEncargado: false,
  isTransportista: false,
  ...r,
})

// =============================================================================
// 1. CASOS LEGIBLES POR ROL
// =============================================================================

describe('rutaActiva — por rol', () => {
  it.each([
    {
      caso: 'transportista puro',
      r: roles({ isTransportista: true }),
      puro: true,
      alterna: false,
      sinVista: true,
      conVistaRuta: true,
    },
    {
      caso: 'preventista con transportista extra',
      r: roles({ isPreventista: true, isTransportista: true }),
      puro: false,
      alterna: true,
      sinVista: false,
      conVistaRuta: true,
    },
    {
      caso: 'encargado con transportista extra',
      r: roles({ isEncargado: true, isTransportista: true }),
      puro: false,
      alterna: true,
      sinVista: false,
      conVistaRuta: true,
    },
    {
      // El admin no alterna al mapa: ?vista=ruta no le cambia la pantalla.
      caso: 'admin con transportista extra',
      r: roles({ isAdmin: true, isTransportista: true }),
      puro: false,
      alterna: false,
      sinVista: false,
      conVistaRuta: false,
    },
    {
      // Depósito no tiene pantalla propia en /pedidos: con el extra, el mapa
      // es la única (todos los flags de pantalla en false).
      caso: 'depósito con transportista extra',
      r: roles({ isTransportista: true }),
      puro: true,
      alterna: false,
      sinVista: true,
      conVistaRuta: true,
    },
    {
      caso: 'preventista sin transportista',
      r: roles({ isPreventista: true }),
      puro: false,
      alterna: false,
      sinVista: false,
      conVistaRuta: false,
    },
    {
      caso: 'sin ningún rol',
      r: roles({}),
      puro: false,
      alterna: false,
      sinVista: false,
      conVistaRuta: false,
    },
  ])('$caso', ({ r, puro, alterna, sinVista, conVistaRuta }) => {
    expect(esTransportistaPuro(r)).toBe(puro)
    expect(puedeAlternarRuta(r)).toBe(alterna)
    expect(muestraRutaActiva(r, null)).toBe(sinVista)
    expect(muestraRutaActiva(r, 'lista')).toBe(sinVista)
    expect(muestraRutaActiva(r, 'ruta')).toBe(conVistaRuta)
  })

  it('el transportista puro y el que alterna son excluyentes', () => {
    for (const isAdmin of [false, true]) {
      for (const isPreventista of [false, true]) {
        for (const isEncargado of [false, true]) {
          for (const isTransportista of [false, true]) {
            const r = { isAdmin, isPreventista, isEncargado, isTransportista }
            expect(esTransportistaPuro(r) && puedeAlternarRuta(r)).toBe(false)
          }
        }
      }
    }
  })

  it('el valor del parámetro es exacto: distingue mayúsculas y vacío', () => {
    const r = roles({ isPreventista: true, isTransportista: true })
    expect(muestraRutaActiva(r, 'RUTA')).toBe(false)
    expect(muestraRutaActiva(r, '')).toBe(false)
    expect(muestraRutaActiva(r, 'ruta')).toBe(true)
  })
})

describe('rolesRutaActivaDesdeRolPrimario', () => {
  it.each([
    ['admin', true, { isAdmin: true, isPreventista: false, isEncargado: false, isTransportista: true }],
    ['preventista', false, { isAdmin: false, isPreventista: true, isEncargado: false, isTransportista: false }],
    ['encargado', true, { isAdmin: false, isPreventista: false, isEncargado: true, isTransportista: true }],
    ['transportista', true, { isAdmin: false, isPreventista: false, isEncargado: false, isTransportista: true }],
    ['deposito', true, { isAdmin: false, isPreventista: false, isEncargado: false, isTransportista: true }],
    [undefined, false, { isAdmin: false, isPreventista: false, isEncargado: false, isTransportista: false }],
  ] as const)('primario %s, transportista %s', (primario, tieneTransportista, esperado) => {
    expect(rolesRutaActivaDesdeRolPrimario(primario, tieneTransportista)).toEqual(esperado)
  })
})

// =============================================================================
// 2. EQUIVALENCIA EXHAUSTIVA CONTRA LAS EXPRESIONES ANTERIORES
// =============================================================================

const BOOLEANOS = [false, true] as const
// Props opcionales de la vista: `undefined` es un valor real (no se pasó).
const OPCIONAL = [undefined, false, true] as const
const VISTAS = [null, '', 'ruta', 'RUTA', 'lista'] as const
// Querystrings de TopNavigation: de ahí sale `vista` con URLSearchParams.
const BUSQUEDAS = ['', '?vista=ruta', '?vista=lista', '?vista=', '?vista=RUTA', '?otro=ruta'] as const
// Rol primario tal cual lo recibe TopNavigation. `otro` es un string que no es
// ningún rol; `undefined` es la lista de roles efectivos vacía.
const PRIMARIOS_TOPNAV = ['admin', 'preventista', 'encargado', 'transportista', 'deposito', 'otro', undefined] as const

// ---- Expresión anterior, copiada de src/components/vistas/VistaPedidos.tsx antes de #823 ----
// (`hayOnVerMiRuta` es `!!onVerMiRuta`; `isEncargado` y `modoRuta` son opcionales en las props.)
function vistaAntes({
  isAdmin,
  isPreventista,
  isTransportista,
  isEncargado,
  hayOnVerMiRuta,
  modoRuta,
}: {
  isAdmin: boolean
  isPreventista: boolean
  isTransportista: boolean
  isEncargado: boolean | undefined
  hayOnVerMiRuta: boolean
  modoRuta: boolean | undefined
}): { mapa: boolean; conVolver: boolean; conMiRuta: boolean } {
  const esTransportistaPuro = isTransportista && !isAdmin && !isPreventista && !isEncargado
  const puedeAlternarRuta = isTransportista && !esTransportistaPuro && hayOnVerMiRuta
  const mapa = !!(esTransportistaPuro || (puedeAlternarRuta && modoRuta))
  return {
    mapa,
    // `onVolver={esTransportistaPuro ? undefined : onSalirDeRuta}` (con onSalirDeRuta pasado)
    conVolver: !esTransportistaPuro,
    // `onVerMiRuta={puedeAlternarRuta ? onVerMiRuta : undefined}` (con onVerMiRuta pasado)
    conMiRuta: puedeAlternarRuta,
  }
}

// ---- Expresión anterior, copiada de src/components/containers/PedidosContainer.tsx antes de #823 ----
// (`vista` es `searchParams.get('vista')`.)
function containerAntes(
  { isAdmin, isPreventista, isTransportista, isEncargado }: RolesRutaActiva,
  vista: string | null,
): { puedeAlternarRuta: boolean; modoRuta: boolean } {
  const puedeAlternarRuta = isTransportista && !isAdmin && (isPreventista || isEncargado)
  const modoRuta = puedeAlternarRuta && vista === 'ruta'
  return { puedeAlternarRuta, modoRuta }
}

// ---- Expresión anterior, copiada de src/components/layout/TopNavigation.tsx antes de #823 ----
// (`rolPrimario`, `tieneTransportista`, `pathname` y `search` son los de ese componente.)
function topNavigationAntes(
  rolPrimario: string | undefined,
  tieneTransportista: boolean,
  pathname: string,
  search: string,
): boolean {
  const primarioSinPantallaDePedidos =
    rolPrimario !== 'admin' && rolPrimario !== 'preventista' && rolPrimario !== 'encargado'
  const enRutaActiva =
    pathname.replace(/\/+$/, '') === '/pedidos' &&
    tieneTransportista &&
    (primarioSinPantallaDePedidos ||
      (rolPrimario !== 'admin' && new URLSearchParams(search).get('vista') === 'ruta'))
  return enRutaActiva
}

// ---- Lo que hacen hoy el container y TopNavigation con las funciones nuevas ----
function containerAhora(r: RolesRutaActiva, vista: string | null): { puedeAlternarRuta: boolean; modoRuta: boolean } {
  const alterna = puedeAlternarRuta(r)
  return { puedeAlternarRuta: alterna, modoRuta: alterna && vista === 'ruta' }
}

function topNavigationAhora(
  rolPrimario: string | undefined,
  tieneTransportista: boolean,
  pathname: string,
  search: string,
): boolean {
  return (
    pathname.replace(/\/+$/, '') === '/pedidos' &&
    muestraRutaActiva(
      rolesRutaActivaDesdeRolPrimario(rolPrimario, tieneTransportista),
      new URLSearchParams(search).get('vista'),
    )
  )
}

// ---- La VistaPedidos real, con las marcas de los mocks de arriba ----
const noop = (): void => {}

function renderVista(
  extra: Partial<VistaPedidosProps>,
): { mapa: boolean; conVolver: boolean; conMiRuta: boolean } {
  const props: VistaPedidosProps = {
    pedidos: [],
    totalCount: 0,
    statsSummary: {} as VistaPedidosProps['statsSummary'],
    paginaActual: 1,
    totalPaginas: 1,
    busqueda: '',
    filtros: {} as VistaPedidosProps['filtros'],
    isAdmin: false,
    isPreventista: false,
    isTransportista: false,
    userId: 'u1',
    clientes: [],
    productos: [],
    loading: false,
    exportando: false,
    onBusquedaChange: noop,
    onFiltrosChange: noop,
    onPageChange: noop,
    onNuevoPedido: noop,
    onOptimizarRuta: noop,
    onExportarPDF: noop,
    onExportarExcel: noop,
    onVerHistorial: noop,
    onEditarPedido: noop,
    onMarcarEnPreparacion: noop,
    onVolverAPendiente: noop,
    onMarcarEntregado: noop,
    onDesmarcarEntregado: noop,
    onSalirDeRuta: noop,
    ...extra,
  }
  const { container, unmount } = render(createElement(VistaPedidos, props))
  try {
    const pantalla = container.querySelector('[data-pantalla]')
    const mapa = pantalla?.getAttribute('data-pantalla') === 'mapa'
    return {
      mapa,
      conVolver: container.querySelector('[data-con-volver="true"]') !== null,
      conMiRuta: container.querySelector('[data-con-mi-ruta="true"]') !== null,
    }
  } finally {
    unmount()
  }
}

describe('rutaActiva — equivalencia con las expresiones anteriores', () => {
  it('VistaPedidos: la vista real da lo mismo que su expresión anterior en las 144 combinaciones de props', () => {
    const diferencias: string[] = []
    let combinaciones = 0

    for (const isAdmin of BOOLEANOS) {
      for (const isPreventista of BOOLEANOS) {
        for (const isTransportista of BOOLEANOS) {
          for (const isEncargado of OPCIONAL) {
            for (const hayOnVerMiRuta of BOOLEANOS) {
              for (const modoRuta of OPCIONAL) {
                combinaciones++
                const esperado = vistaAntes({ isAdmin, isPreventista, isTransportista, isEncargado, hayOnVerMiRuta, modoRuta })
                const real = renderVista({
                  isAdmin,
                  isPreventista,
                  isTransportista,
                  isEncargado,
                  modoRuta,
                  onVerMiRuta: hayOnVerMiRuta ? noop : undefined,
                })
                // Fuera de la pantalla de mapa se ve la lista, con su toolbar;
                // `conVolver` sólo existe en el mapa y `conMiRuta` sólo en la lista.
                const obtenido = {
                  mapa: real.mapa,
                  conVolver: real.mapa ? real.conVolver : esperado.conVolver,
                  conMiRuta: real.mapa ? esperado.conMiRuta : real.conMiRuta,
                }
                if (JSON.stringify(obtenido) !== JSON.stringify(esperado)) {
                  diferencias.push(
                    `A=${isAdmin} P=${isPreventista} T=${isTransportista} E=${isEncargado} onVerMiRuta=${hayOnVerMiRuta} modoRuta=${modoRuta}: antes ${JSON.stringify(esperado)}, ahora ${JSON.stringify(obtenido)}`,
                  )
                }
              }
            }
          }
        }
      }
    }

    expect(combinaciones).toBe(144)
    expect(diferencias).toEqual([])
  })

  it('PedidosContainer: puedeAlternarRuta y modoRuta dan lo mismo que antes en las 80 combinaciones', () => {
    const diferencias: string[] = []
    let combinaciones = 0

    for (const isAdmin of BOOLEANOS) {
      for (const isPreventista of BOOLEANOS) {
        for (const isEncargado of BOOLEANOS) {
          for (const isTransportista of BOOLEANOS) {
            for (const vista of VISTAS) {
              combinaciones++
              const r = { isAdmin, isPreventista, isEncargado, isTransportista }
              const antes = containerAntes(r, vista)
              const ahora = containerAhora(r, vista)
              if (JSON.stringify(antes) !== JSON.stringify(ahora)) {
                diferencias.push(`${JSON.stringify(r)} vista=${vista}: antes ${JSON.stringify(antes)}, ahora ${JSON.stringify(ahora)}`)
              }
            }
          }
        }
      }
    }

    expect(combinaciones).toBe(80)
    expect(diferencias).toEqual([])
  })

  it('TopNavigation: enRutaActiva da lo mismo que antes para cada rol primario, con y sin transportista, en cada URL', () => {
    const diferencias: string[] = []
    let combinaciones = 0

    for (const pathname of ['/pedidos', '/pedidos/', '/clientes'] as const) {
      for (const rolPrimario of PRIMARIOS_TOPNAV) {
        for (const tieneTransportista of BOOLEANOS) {
          for (const search of BUSQUEDAS) {
            combinaciones++
            const antes = topNavigationAntes(rolPrimario, tieneTransportista, pathname, search)
            const ahora = topNavigationAhora(rolPrimario, tieneTransportista, pathname, search)
            if (antes !== ahora) {
              diferencias.push(`${rolPrimario} T=${tieneTransportista} ${pathname}${search}: antes ${antes}, ahora ${ahora}`)
            }
          }
        }
      }
    }

    // 3 rutas x 7 primarios x 2 x 6 querystrings.
    expect(combinaciones).toBe(252)
    expect(diferencias).toEqual([])
  })
})

// =============================================================================
// 3. LAS TRES COINCIDEN ENTRE SÍ
// =============================================================================

// Roles primarios mutuamente excluyentes, como los arma App.tsx: isAdmin,
// isPreventista, isEncargado e isDeposito salen del rol primario, e
// isTransportista suma además el rol extra (mig 155).
const PRIMARIOS_APP = ['admin', 'preventista', 'encargado', 'transportista', 'deposito', 'ninguno'] as const

describe('rutaActiva — container, vista y TopNavigation coinciden', () => {
  it('en las 72 combinaciones de rol primario, transportista extra y ?vista=, el mapa se ve exactamente donde TopNavigation quita la barra', () => {
    const diferencias: string[] = []
    let combinaciones = 0
    let conMapa = 0

    for (const primario of PRIMARIOS_APP) {
      for (const extraTransportista of BOOLEANOS) {
        for (const search of BUSQUEDAS) {
          combinaciones++

          // Lo que App.tsx le da al AuthDataContext.
          const flags: RolesRutaActiva = {
            isAdmin: primario === 'admin',
            isPreventista: primario === 'preventista',
            isEncargado: primario === 'encargado',
            isTransportista: primario === 'transportista' || extraTransportista,
          }
          const rolesEfectivos: string[] = [
            ...(primario === 'ninguno' ? [] : [primario]),
            ...(extraTransportista ? ['transportista'] : []),
          ]
          const vista = new URLSearchParams(search).get('vista')

          // Antes: container -> vista (la vista recibe modoRuta y, sólo si el
          // container puede alternar, onVerMiRuta) y TopNavigation por su lado.
          const cAntes = containerAntes(flags, vista)
          const vAntes = vistaAntes({
            ...flags,
            hayOnVerMiRuta: cAntes.puedeAlternarRuta,
            modoRuta: cAntes.modoRuta,
          })
          const tAntes = topNavigationAntes(rolesEfectivos[0], rolesEfectivos.includes('transportista'), '/pedidos', search)

          // Ahora: la vista real alimentada por el container nuevo, y TopNavigation nuevo.
          const cAhora = containerAhora(flags, vista)
          const vAhora = renderVista({
            ...flags,
            modoRuta: cAhora.modoRuta,
            onVerMiRuta: cAhora.puedeAlternarRuta ? noop : undefined,
          })
          const tAhora = topNavigationAhora(rolesEfectivos[0], rolesEfectivos.includes('transportista'), '/pedidos', search)

          const unica = muestraRutaActiva(flags, vista)

          const resultados = {
            vistaAntes: vAntes.mapa,
            vistaAhora: vAhora.mapa,
            topNavAntes: tAntes,
            topNavAhora: tAhora,
            funcion: unica,
          }
          if (new Set(Object.values(resultados)).size !== 1) {
            diferencias.push(`${primario} extraT=${extraTransportista} ${search}: ${JSON.stringify(resultados)}`)
          }
          if (unica) conMapa++
        }
      }
    }

    expect(combinaciones).toBe(72)
    expect(diferencias).toEqual([])
    // Que la tabla no sea trivial: hay combinaciones con y sin mapa.
    expect(conMapa).toBeGreaterThan(0)
    expect(conMapa).toBeLessThan(combinaciones)
  })
})
