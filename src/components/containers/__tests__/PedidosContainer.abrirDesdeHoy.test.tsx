/**
 * "Nuevo pedido" desde la pantalla Hoy abre el alta en /pedidos UNA vez (WP-48, #773).
 *
 * LO QUE SE PROTEGE
 * -----------------
 * `HoyContainer` navega a /pedidos con `state: { abrir: 'nuevoPedido' }` y
 * `PedidosContainer` lo consume: abre el alta y reemplaza la entrada del
 * historial por la misma URL sin state. Si no la limpiara, el alta se volvería
 * a abrir sola al recargar (el state vive en `history.state`) o al volver
 * atrás y adelante, con el preventista sin haber tocado nada.
 *
 * Se montan las DOS pantallas reales en un router en memoria, así el contrato
 * del state (la forma que escribe Hoy y la que lee Pedidos) se prueba de punta
 * a punta y no con un literal copiado a cada lado.
 *
 * El andamiaje de mocks es el de `PedidosContainer.statsFiltros.test.tsx`; la
 * vista de pedidos, el modal de alta y el de visita se reemplazan por dobles
 * mínimos. Como acá ya está montada la pantalla Hoy, el último describe fija
 * también su otra acción: "Marcar visita" abre el modal sin salir de /hoy.
 *
 * EL FOCO AL CERRAR (#864)
 * ------------------------
 * El Dialog devuelve el foco a quien abrió el alta (#800), pero el botón de Hoy
 * se desmontó con el cambio de ruta: sin otra cosa, al cerrar el foco cae en
 * <body>. Para que eso se pruebe de verdad, esos tests arman el alta con los
 * cascarones reales (ModalBase en escritorio, BottomSheet `comoDialogo` en el
 * celular; el `div` plano de los demás no atrapa ni devuelve el foco) y la
 * lista de pedidos monta la `PedidoToolbar` real: así el botón
 * "Nuevo pedido" al que tiene que volver el foco es el que ve el usuario, y si
 * alguien le cambia el texto a la toolbar este archivo se entera.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'
import { act, configure, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation, useNavigate, type Location } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useEffect, type ReactElement } from 'react'
import type { PedidoToolbarProps } from '../../pedidos/PedidoToolbar'

const { invalidateQueries, supabaseStub, hoyMocks } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    invalidateQueries: vi.fn(),
    // Lo que lee HoyContainer: configurable por test, para fijar cómo conecta
    // los datos de la pantalla (y no sólo que la pantalla se monta).
    hoyMocks: {
      useVisitasHoyQuery: vi.fn(),
      useAvanceMetasQuery: vi.fn(),
      useClientesQuery: vi.fn(),
      /** El callback que HoyContainer le pasa a useResetOnSucursalChange. */
      resetSucursal: { current: null as null | (() => void) },
      /**
       * Cómo se arma el doble del alta. 'plano' (el de siempre) es un `div` con
       * rol de diálogo y no tapa el resto de la página; 'modal' y 'sheet' son los
       * cascarones reales —escritorio y celular—, que sí: esconden lo que queda
       * afuera y le piden el foco a Radix. Sólo los tests del foco los necesitan.
       */
      altaComo: { current: 'plano' as 'plano' | 'modal' | 'sheet' },
      /** Id de un elemento de la lista al que el doble del alta le pasa el foco al desmontarse. */
      alCerrarEnfoca: { current: null as string | null },
      /** La lista se arma para un rol que no puede crear pedidos: la toolbar no trae "Nuevo pedido". */
      sinBotonNuevo: { current: false },
    },
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      },
    },
  }
})

vi.mock('@tanstack/react-query', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@tanstack/react-query')>()
  return { ...actual, useQueryClient: () => ({ invalidateQueries, setQueryData: vi.fn(), getQueryData: vi.fn() }) }
})

vi.mock('../../../lib/supabase', () => ({
  supabase: supabaseStub,
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../../hooks/supabase/base', () => ({
  supabase: supabaseStub,
  setErrorNotifier: vi.fn(),
  notifyError: vi.fn(),
  handleSupabaseError: vi.fn(),
}))

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

vi.mock('../../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({ data: { pedidos: [], total: 0, totalPages: 1 }, isLoading: false, isFetching: false }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => emptyMutation,
  useAsignarTransportistaMutation: () => emptyMutation,
  useQuitarPedidoDeRecorridosMutation: () => emptyMutation,
  useEntregasMasivasMutation: () => emptyMutation,
  useCancelarPedidoMutation: () => emptyMutation,
  useCambiarClientePedidoMutation: () => emptyMutation,
  usePagosMasivosMutation: () => emptyMutation,
  useEntregaYPagoMasivosMutation: () => emptyMutation,
  usePedidosAsignadosQuery: () => emptyQuery,
  useClientesQuery: (...args: unknown[]) => hoyMocks.useClientesQuery(...args),
  useProductosQuery: () => emptyQuery,
  useTransportistasQuery: () => emptyQuery,
  useUsuariosQuery: () => emptyQuery,
  useCrearClienteMutation: () => emptyMutation,
  useActualizarClienteMutation: () => emptyMutation,
  useDepositoCoords: () => ({ data: null }),
  useDestinoCoords: () => ({ data: null }),
  useCrearPedidoCambioEnRutaMutation: () => emptyMutation,
  useAplicarCambioParadaMutation: () => emptyMutation,
  useZonasEstandarizadasQuery: () => emptyQuery,
  // Lo que pide HoyContainer.
  useVisitasHoyQuery: (...args: unknown[]) => hoyMocks.useVisitasHoyQuery(...args),
  useAvanceMetasQuery: (...args: unknown[]) => hoyMocks.useAvanceMetasQuery(...args),
}))

vi.mock('../../../hooks/queries/useRecorridoActivoQuery', () => ({
  useRecorridoActivoQuery: () => ({ data: null }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: false, isEncargado: false, isPreventista: true, isTransportista: false, isDeposito: false,
    authReady: true, user: { id: 'prev-1' }, perfil: { id: 'prev-1', rol: 'preventista' },
  }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))

vi.mock('../../../contexts/SucursalContext', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useSucursal: () => ({ currentSucursalId: 1, sucursales: [], loading: false }),
}))
vi.mock('../../../hooks/useOfflineSync', () => ({ useOfflineSync: () => ({ isOnline: true, pendingCount: 0 }) }))
vi.mock('../../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: (reset: () => void) => { hoyMocks.resetSucursal.current = reset },
}))
vi.mock('../../../hooks/useOptimizarRuta', () => ({
  useOptimizarRuta: () => ({ optimizar: vi.fn(), optimizando: false }),
  horarioParaRutear: () => null,
}))
vi.mock('../../../hooks/useRegistrarGeolocalizacionPedido', () => ({
  useRegistrarGeolocalizacionPedido: () => ({ registrar: vi.fn() }),
}))
vi.mock('../../../hooks/supabase/usePagos', () => ({
  usePagos: () => ({ registrarPago: vi.fn(), anularPago: vi.fn(), obtenerPagosPedido: vi.fn() }),
}))
vi.mock('../../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

// La lista de pedidos: un rótulo, un campo de búsqueda (otro lugar donde puede
// estar el foco) y la PedidoToolbar REAL, con sus dos botones "Nuevo pedido"
// (celular y escritorio; jsdom no aplica el `hidden` de Tailwind).
vi.mock('../../vistas/VistaPedidos', async () => {
  const { default: PedidoToolbar } = await import('../../pedidos/PedidoToolbar')
  return {
    default: (p: PedidoToolbarProps) => (
      <div>
        <p>Lista de pedidos</p>
        <input id="buscador-pedidos" aria-label="Buscar pedidos" />
        <PedidoToolbar
          isAdmin={p.isAdmin}
          isEncargado={p.isEncargado}
          isPreventista={p.isPreventista && !hoyMocks.sinBotonNuevo.current}
          exportando={p.exportando}
          totalCount={p.totalCount}
          onNuevoPedido={p.onNuevoPedido}
          onOptimizarRuta={p.onOptimizarRuta}
          onExportarPDF={p.onExportarPDF}
          onExportarExcel={p.onExportarExcel}
        />
      </div>
    ),
  }
})

// El alta: por defecto un diálogo plano con nombre y su cierre; para los tests
// del foco, el cascarón real de ModalPedido (ModalBase en escritorio, BottomSheet
// `comoDialogo` en el celular). Si `alCerrarEnfoca` está seteado, al desmontarse
// le pasa el foco a ese elemento de la lista.
vi.mock('../../modals/ModalPedido', async () => {
  const { useEffect } = await import('react')
  const { default: ModalBase } = await import('../../modals/ModalBase')
  const { BottomSheet } = await import('../../ui/BottomSheet')
  function AltaDePedido({ onClose }: { onClose: () => void }) {
    useEffect(() => () => {
      const id = hoyMocks.alCerrarEnfoca.current
      if (id) document.getElementById(id)?.focus()
    }, [])
    const cerrar = <button type="button" onClick={onClose}>Cerrar alta</button>
    switch (hoyMocks.altaComo.current) {
      case 'sheet':
        return <BottomSheet open onClose={onClose} title="Alta de pedido" comoDialogo>{cerrar}</BottomSheet>
      case 'modal':
        return <ModalBase title="Alta de pedido" onClose={onClose}>{cerrar}</ModalBase>
      default:
        return <div role="dialog" aria-label="Alta de pedido">{cerrar}</div>
    }
  }
  return { default: AltaDePedido }
})

// "Marcar visita" de Hoy: un doble que muestra las props que recibe.
vi.mock('../../modals/ModalMarcarVisita', () => ({
  default: ({ userId, isAdmin, isPreventista, clientes, onClose }: {
    userId: string | null; isAdmin: boolean; isPreventista: boolean; clientes: unknown[]; onClose: () => void
  }) => (
    <div role="dialog" aria-label="Marcar visita">
      <p>{`userId=${userId} isAdmin=${isAdmin} isPreventista=${isPreventista} clientes=${clientes.length}`}</p>
      <button type="button" onClick={onClose}>Cerrar visita</button>
    </div>
  ),
}))

import PedidosContainer from '../PedidosContainer'
import HoyContainer from '../HoyContainer'
import { periodoMensual } from '../../../hooks/queries'
import { AVANCE_METAS_HOY, VISITAS_HOY } from '../../../../dev/gallery/fixtures/hoy'

// Las dos vistas y el alta son lazy: con la suite entera en paralelo, el primer
// import en frío pasa el segundo por defecto de los `findBy`. Se precargan una
// vez acá, para que los `findBy` no dependan del tiempo de transform en frío; el
// timeout más largo queda de respaldo.
configure({ asyncUtilTimeout: 5000 })

beforeAll(async () => {
  await Promise.all([
    import('../../vistas/VistaHoy'),
    import('../../vistas/VistaPedidos'),
    import('../../modals/ModalPedido'),
    import('../../modals/ModalMarcarVisita'),
  ])
}, 30_000)

/** La última ubicación que vio el router, para "recargar" sobre ella. */
const sonda: { ultima: Location | null } = { ultima: null }

function Sonda(): ReactElement {
  const location = useLocation()
  const navigate = useNavigate()
  useEffect(() => {
    sonda.ultima = location
  }, [location])
  return (
    <div>
      <p>{`Ruta actual: ${location.pathname}${location.search}`}</p>
      <p>{`State: ${JSON.stringify(location.state ?? null)}`}</p>
      <button type="button" onClick={() => navigate(-1)}>Atrás</button>
      <button type="button" onClick={() => navigate(1)}>Adelante</button>
    </div>
  )
}

type Entrada = string | { pathname: string; search?: string; state?: unknown }

function renderApp(entradas: Entrada[], indice?: number) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={entradas} initialIndex={indice}>
        {/* El <main> de App.tsx: el destino de respaldo del foco (#864). */}
        <main id="main-content">
          <Routes>
            <Route path="/hoy" element={<HoyContainer />} />
            <Route path="/pedidos" element={<PedidosContainer />} />
          </Routes>
        </main>
        <Sonda />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

const alta = () => screen.queryByRole('dialog', { name: 'Alta de pedido' })

const visitasHoyVacias = { data: [], isLoading: false, error: null }

beforeEach(() => {
  sonda.ultima = null
  hoyMocks.resetSucursal.current = null
  hoyMocks.altaComo.current = 'plano'
  hoyMocks.alCerrarEnfoca.current = null
  hoyMocks.sinBotonNuevo.current = false
  hoyMocks.useVisitasHoyQuery.mockReset().mockReturnValue(visitasHoyVacias)
  hoyMocks.useAvanceMetasQuery.mockReset().mockReturnValue({ data: undefined })
  hoyMocks.useClientesQuery.mockReset().mockReturnValue(emptyQuery)
})

describe('PedidosContainer — abre el alta que pide Hoy, una sola vez (WP-48)', () => {
  it('"Nuevo pedido" en Hoy lleva a /pedidos con el alta abierta y el state ya limpio', async () => {
    const user = userEvent.setup()
    renderApp(['/hoy'])

    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))

    expect(await screen.findByRole('dialog', { name: 'Alta de pedido' })).toBeInTheDocument()
    expect(screen.getByText('Ruta actual: /pedidos')).toBeInTheDocument()
    expect(screen.getByText('State: null')).toBeInTheDocument()
  })

  it('la limpieza reemplaza la entrada, no apila otra: un "atrás" vuelve a Hoy', async () => {
    const user = userEvent.setup()
    renderApp(['/hoy'])

    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await screen.findByRole('dialog', { name: 'Alta de pedido' })
    await user.click(screen.getByRole('button', { name: 'Atrás' }))

    expect(screen.getByText('Ruta actual: /hoy')).toBeInTheDocument()
  })

  it('cerrar el alta, volver a Hoy y adelante otra vez a /pedidos no la reabre', async () => {
    const user = userEvent.setup()
    renderApp(['/hoy'])

    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Cerrar alta' }))
    expect(alta()).toBeNull()

    await user.click(screen.getByRole('button', { name: 'Atrás' }))
    expect(screen.getByText('Ruta actual: /hoy')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Adelante' }))

    expect(await screen.findByText('Lista de pedidos')).toBeInTheDocument()
    expect(screen.getByText('Ruta actual: /pedidos')).toBeInTheDocument()
    expect(alta()).toBeNull()
  })

  it('recargar /pedidos después de abrir el alta no la reabre', async () => {
    const user = userEvent.setup()
    const primera = renderApp(['/hoy'])

    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await screen.findByRole('dialog', { name: 'Alta de pedido' })

    // Una recarga arranca de la MISMA entrada del historial, con su state.
    const entradaActual = sonda.ultima
    if (!entradaActual) throw new Error('La sonda no vio ninguna ubicación')
    primera.unmount()
    renderApp([{ pathname: entradaActual.pathname, search: entradaActual.search, state: entradaActual.state }])

    expect(await screen.findByText('Lista de pedidos')).toBeInTheDocument()
    expect(alta()).toBeNull()
  })

  it('entrar a /pedidos con el state lo abre una vez y conserva la búsqueda de la URL', async () => {
    renderApp([{ pathname: '/pedidos', search: '?vista=lista', state: { abrir: 'nuevoPedido' } }])

    expect(await screen.findByRole('dialog', { name: 'Alta de pedido' })).toBeInTheDocument()
    expect(screen.getByText('Ruta actual: /pedidos?vista=lista')).toBeInTheDocument()
    expect(screen.getByText('State: null')).toBeInTheDocument()
  })

  it('sin state, /pedidos abre como siempre: sin alta', async () => {
    renderApp(['/pedidos'])
    expect(await screen.findByText('Lista de pedidos')).toBeInTheDocument()
    expect(alta()).toBeNull()
  })

  it('un state con otro pedido no abre nada ni se toca', async () => {
    renderApp([{ pathname: '/pedidos', state: { abrir: 'otraCosa' } }])
    expect(await screen.findByText('Lista de pedidos')).toBeInTheDocument()
    expect(alta()).toBeNull()
    expect(screen.getByText('State: {"abrir":"otraCosa"}')).toBeInTheDocument()
  })

  it('el botón de la toolbar sigue abriendo el alta como antes', async () => {
    const user = userEvent.setup()
    renderApp(['/pedidos'])
    // La toolbar real trae dos "Nuevo pedido" (celular y escritorio): cualquiera abre.
    await user.click((await screen.findAllByRole('button', { name: 'Nuevo pedido' }))[0])
    expect(await screen.findByRole('dialog', { name: 'Alta de pedido' })).toBeInTheDocument()
  })
})

describe.each([
  { shell: 'modal', nombre: 'el modal de escritorio' },
  { shell: 'sheet', nombre: 'el bottom sheet del celular' },
] as const)('PedidosContainer — el foco al cerrar el alta que abrió Hoy (#864), en $nombre', ({ shell }) => {
  beforeEach(() => {
    hoyMocks.altaComo.current = shell
  })

  const botonesNuevoPedido = () => screen.getAllByRole('button', { name: 'Nuevo pedido' })

  /** Hoy → "Nuevo pedido" → /pedidos con el alta abierta. */
  async function abrirDesdeHoy(user: ReturnType<typeof userEvent.setup>) {
    renderApp(['/hoy'])
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await screen.findByRole('dialog', { name: 'Alta de pedido' })
  }

  it('cerrarla con Escape deja el foco en el "Nuevo pedido" de la toolbar de Pedidos, no en <body>', async () => {
    const user = userEvent.setup()
    await abrirDesdeHoy(user)

    await user.keyboard('{Escape}')

    await waitFor(() => expect(alta()).toBeNull())
    await waitFor(() => expect(botonesNuevoPedido()).toContain(document.activeElement))
  })

  it('cerrarla por un camino que no pasa por su onClose (al cambiar de sucursal) también', async () => {
    const user = userEvent.setup()
    await abrirDesdeHoy(user)

    const reset = hoyMocks.resetSucursal.current
    if (!reset) throw new Error('PedidosContainer no registró useResetOnSucursalChange')
    act(() => reset())

    await waitFor(() => expect(alta()).toBeNull())
    await waitFor(() => expect(botonesNuevoPedido()).toContain(document.activeElement))
  })

  it('si el foco ya quedó en otro lado al cerrarla, no se lo mueve', async () => {
    const user = userEvent.setup()
    hoyMocks.alCerrarEnfoca.current = 'buscador-pedidos'
    await abrirDesdeHoy(user)

    await user.keyboard('{Escape}')

    await waitFor(() => expect(alta()).toBeNull())
    // Pasada la ventana en la que el foco se repara solo.
    await act(() => new Promise(resolve => setTimeout(resolve, 50)))
    expect(document.activeElement).toBe(screen.getByRole('textbox', { name: 'Buscar pedidos' }))
  })

  it('sin "Nuevo pedido" en la toolbar, el foco va a <main>, y su tabindex se va con el foco', async () => {
    const user = userEvent.setup()
    hoyMocks.sinBotonNuevo.current = true
    await abrirDesdeHoy(user)

    await user.keyboard('{Escape}')

    const main = screen.getByRole('main')
    await waitFor(() => expect(document.activeElement).toBe(main))
    expect(main).toHaveAttribute('tabindex', '-1')

    act(() => main.blur())
    expect(main).not.toHaveAttribute('tabindex')
  })

  it('abierta desde la toolbar de Pedidos, el foco vuelve al botón que la abrió, como siempre', async () => {
    const user = userEvent.setup()
    renderApp(['/pedidos'])
    // El segundo (el de escritorio): si el foco se resolviera con el primero de
    // la toolbar en vez de devolverse a quien abrió, acá se notaría.
    const botonQueAbre = (await screen.findAllByRole('button', { name: 'Nuevo pedido' }))[1]
    await user.click(botonQueAbre)
    await screen.findByRole('dialog', { name: 'Alta de pedido' })

    await user.keyboard('{Escape}')

    await waitFor(() => expect(alta()).toBeNull())
    await waitFor(() => expect(document.activeElement).toBe(botonQueAbre))
  })
})

describe('HoyContainer — "Marcar visita" abre el modal de siempre, sin salir de Hoy', () => {
  it('lo abre con las props que le pasa PedidosContainer, y se cierra', async () => {
    const user = userEvent.setup()
    renderApp(['/hoy'])

    await user.click(await screen.findByRole('button', { name: 'Marcar visita' }))

    const modal = await screen.findByRole('dialog', { name: 'Marcar visita' })
    expect(modal).toHaveTextContent('userId=prev-1 isAdmin=false isPreventista=true clientes=0')
    expect(screen.getByText('Ruta actual: /hoy')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Cerrar visita' }))
    expect(screen.queryByRole('dialog', { name: 'Marcar visita' })).toBeNull()
  })
})

describe('HoyContainer — conecta los datos de la pantalla', () => {
  it('pide las visitas del usuario logueado y los objetivos del mes corriente, con los argumentos del dashboard', async () => {
    renderApp(['/hoy'])
    await screen.findByRole('heading', { level: 1, name: 'Hoy' })

    expect(hoyMocks.useVisitasHoyQuery).toHaveBeenCalledWith('prev-1', { enabled: true })
    // Sin id (el RPC devuelve los del logueado), el período mensual y habilitada
    // para un preventista con la sesión lista.
    expect(hoyMocks.useAvanceMetasQuery).toHaveBeenCalledWith(undefined, periodoMensual(), true)
  })

  it('muestra en "Visitas de hoy" las visitas que devuelve useVisitasHoyQuery', async () => {
    hoyMocks.useVisitasHoyQuery.mockReturnValue({ data: VISITAS_HOY, isLoading: false, error: null })
    renderApp(['/hoy'])

    const seccion = await screen.findByRole('region', { name: 'Visitas de hoy' })
    expect(seccion).toHaveTextContent('Kiosco La Esquina')
    expect(seccion).toHaveTextContent('Almacén Lucía')
    expect(seccion).not.toHaveTextContent('Todavía no marcaste ninguna visita hoy.')
  })

  it('sin visitas, dice que todavía no marcó ninguna', async () => {
    renderApp(['/hoy'])
    expect(await screen.findByText('Todavía no marcaste ninguna visita hoy.')).toBeInTheDocument()
  })

  it('mientras carga las visitas, lo dice', async () => {
    hoyMocks.useVisitasHoyQuery.mockReturnValue({ data: undefined, isLoading: true, error: null })
    renderApp(['/hoy'])
    expect(await screen.findByText('Cargando…')).toBeInTheDocument()
  })

  it('si la query de visitas falla, muestra el error', async () => {
    hoyMocks.useVisitasHoyQuery.mockReturnValue({ data: undefined, isLoading: false, error: new Error('se cayó la red') })
    renderApp(['/hoy'])
    expect(await screen.findByText('Error: se cayó la red')).toBeInTheDocument()
  })

  it('con objetivos del mes, muestra el panel del dashboard', async () => {
    hoyMocks.useAvanceMetasQuery.mockReturnValue({ data: AVANCE_METAS_HOY })
    renderApp(['/hoy'])
    expect(await screen.findByRole('heading', { name: /Mis objetivos de/ })).toBeInTheDocument()
  })

  it('sin objetivos, no muestra el panel', async () => {
    renderApp(['/hoy'])
    await screen.findByRole('heading', { level: 1, name: 'Hoy' })
    expect(screen.queryByRole('heading', { name: /Mis objetivos de/ })).toBeNull()
  })

  it('"Marcar visita" le pasa al modal los clientes que devuelve useClientesQuery', async () => {
    const user = userEvent.setup()
    hoyMocks.useClientesQuery.mockReturnValue({ ...emptyQuery, data: [{ id: 1 }, { id: 2 }] })
    renderApp(['/hoy'])

    await user.click(await screen.findByRole('button', { name: 'Marcar visita' }))

    expect(await screen.findByRole('dialog', { name: 'Marcar visita' })).toHaveTextContent('clientes=2')
  })

  it('al cambiar de sucursal el modal de visita se cierra, no queda con los clientes de la anterior', async () => {
    const user = userEvent.setup()
    renderApp(['/hoy'])
    await user.click(await screen.findByRole('button', { name: 'Marcar visita' }))
    await screen.findByRole('dialog', { name: 'Marcar visita' })

    const reset = hoyMocks.resetSucursal.current
    if (!reset) throw new Error('HoyContainer no registró useResetOnSucursalChange')
    act(() => reset())

    expect(screen.queryByRole('dialog', { name: 'Marcar visita' })).toBeNull()
  })
})
