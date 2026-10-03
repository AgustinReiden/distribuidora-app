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
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'
import { act, configure, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation, useNavigate, type Location } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useEffect, type ReactElement } from 'react'

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

// La lista de pedidos: sólo un rótulo y el botón de alta de la toolbar.
vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ onNuevoPedido }: { onNuevoPedido: () => void }) => (
    <div>
      <p>Lista de pedidos</p>
      <button type="button" onClick={onNuevoPedido}>Nuevo pedido desde la toolbar</button>
    </div>
  ),
}))

// El alta: un diálogo con nombre y su cierre.
vi.mock('../../modals/ModalPedido', () => ({
  default: ({ onClose }: { onClose: () => void }) => (
    <div role="dialog" aria-label="Alta de pedido">
      <button type="button" onClick={onClose}>Cerrar alta</button>
    </div>
  ),
}))

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
        <Routes>
          <Route path="/hoy" element={<HoyContainer />} />
          <Route path="/pedidos" element={<PedidosContainer />} />
        </Routes>
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
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido desde la toolbar' }))
    expect(await screen.findByRole('dialog', { name: 'Alta de pedido' })).toBeInTheDocument()
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
