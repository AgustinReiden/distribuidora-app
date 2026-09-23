/**
 * Los tiles de /pedidos son a la vez resumen y filtro (#715): el cableado.
 *
 * LO QUE SE PROTEGE
 * -----------------
 * `PedidosContainer` alimenta DOS queries con los filtros: la lista paginada
 * (`usePedidosPaginatedQuery`) con los filtros tal cual, y el summary de los
 * tiles (`usePedidoStatsQuery`) con `filtrosParaStats(filtros)`, que les saca
 * el estado y el pago. Si el container le pasara al summary los mismos filtros
 * que a la lista, al tocar "Pendientes" los otros cinco tiles caerían a 0 y ya
 * no se podría saltar de uno a otro. `filtrosParaStats` tiene sus tests
 * unitarios; lo que acá se fija es que el container LA USE, y para cuál query.
 *
 * Se asevera por comportamiento: con qué argumentos se llamó cada hook después
 * de tocar los tiles reales, no qué clases pinta nada.
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.itemsEdicion.test.tsx`
 * (con las rutas ajustadas a `__tests__/`): la vista se reemplaza por el
 * `PedidoStats` real cableado a los `filtros` y el `onFiltrosChange` que le da
 * el container, más un botón que hace de select de estado para 'cancelado'
 * (ningún tile lo aplica).
 *
 * El otro tramo del cableado, VistaPedidos → PedidoStats, lo cubre el último
 * describe montando la VistaPedidos REAL (vía `vi.importActual`, porque arriba
 * está mockeada): si la vista dejara de pasarle `filtros` y `onFiltrosChange`,
 * los tiles volverían a ser <div> en producción, el tripwire de sólo lectura de
 * PedidoStats seguiría verde, y nada más se enteraría.
 */
import React from 'react'
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { FiltrosPedidosState } from '../../../types'
import type { VistaPedidosProps } from '../../vistas/VistaPedidos'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, rpc, supabaseStub, usePedidoStatsQuery, usePedidosPaginatedQuery, SUMMARY } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  const PEDIDO_LISTA = { id: 42, cliente_id: '9', estado: 'pendiente', total: 1000, items: [], cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' } }
  return {
    invalidateQueries: vi.fn(),
    rpc: rpcFn,
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      },
    },
    usePedidoStatsQuery: vi.fn((..._args: unknown[]) => ({ data: undefined, isLoading: false })),
    usePedidosPaginatedQuery: vi.fn((..._args: unknown[]) => ({
      data: { pedidos: [PEDIDO_LISTA], total: 1, totalPages: 1 }, isLoading: false, isFetching: false,
    })),
    SUMMARY: {
      pendientes: { count: 3, monto: 1000 },
      enPreparacion: { count: 4, monto: 2000 },
      enCamino: { count: 5, monto: 3000 },
      entregados: { count: 6, monto: 4000 },
      impagos: { count: 7, monto: 5000 },
      total: { count: 18, monto: 15000 },
      aproximado: false,
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

// Se parte del barrel real y se pisan sólo los hooks que el container usa: así
// un hook nuevo no rompe este test con "No export is defined on the mock".
vi.mock('../../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery,
  usePedidoStatsQuery,
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
  useClientesQuery: () => emptyQuery,
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
}))

vi.mock('../../../hooks/queries/useRecorridoActivoQuery', () => ({
  useRecorridoActivoQuery: () => ({ data: null }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'admin' },
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
vi.mock('../../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
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

// La vista: los tiles REALES, con los filtros y el onFiltrosChange que el
// container le pasa a VistaPedidos, y un botón que hace de select de estado.
vi.mock('../../vistas/VistaPedidos', async () => {
  const { default: PedidoStats } = await vi.importActual<typeof import('../../pedidos/PedidoStats')>(
    '../../pedidos/PedidoStats',
  )
  return {
    default: ({ filtros, onFiltrosChange }: {
      filtros: FiltrosPedidosState
      onFiltrosChange: (cambios: Partial<FiltrosPedidosState>) => void
    }) => (
      <>
        <PedidoStats summary={SUMMARY} filtros={filtros} onFiltrosChange={onFiltrosChange} />
        <button type="button" onClick={() => onFiltrosChange({ estado: 'cancelado' })}>
          Elegir estado cancelado
        </button>
      </>
    ),
  }
})

// Sólo para el describe de la VistaPedidos real: el transportista puro ve el
// mapa de la ruta en vez de la lista, y el mapa real necesita mucho más
// andamiaje del que hace falta para ver que ahí no hay tiles.
vi.mock('../../rutaActiva/RutaActivaTransportista', () => ({
  default: () => <p>Mapa de la ruta activa</p>,
}))

import PedidosContainer from '../PedidosContainer'

/** Los filtros con los que se llamó por última vez a cada query. */
function ultimosFiltros() {
  const stats = usePedidoStatsQuery.mock.lastCall?.[0] as FiltrosPedidosState | undefined
  const lista = usePedidosPaginatedQuery.mock.lastCall?.[2] as FiltrosPedidosState | undefined
  if (!stats || !lista) throw new Error('El container no llamó a las dos queries')
  return { stats, lista }
}

function renderContainer() {
  // Provider real para los `useQuery` sueltos que quedan sin mockear;
  // `useQueryClient` sigue devolviendo el spy (ver el mock de arriba).
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  rpc.mockResolvedValue({ data: { success: true }, error: null })
})

describe('PedidosContainer — el summary de los tiles va sin estado ni pago (#715)', () => {
  it('con "Pendientes" + "Impagos" tocados, la lista filtra por los dos y el summary por ninguno', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: /^Pendientes/ }))
    await user.click(screen.getByRole('button', { name: /^Impagos/ }))

    await waitFor(() => {
      const { lista } = ultimosFiltros()
      expect(lista.estado).toBe('pendiente')
      expect(lista.estadoPago).toBe('impago')
    })

    const { stats, lista } = ultimosFiltros()
    expect(stats.estado).toBe('todos')
    expect(stats.estadoPago).toBe('todos')
    // Todo lo demás (fechas, transportista, usuario, salvedad…) es lo mismo que
    // mira la lista: el summary cuenta el mismo universo, sólo sin esas dos.
    expect(stats).toEqual({ ...lista, estado: 'todos', estadoPago: 'todos', verCancelados: lista.verCancelados })

    // Y los tiles quedaron presionados contra los filtros de la LISTA.
    expect(screen.getByRole('button', { name: /^Pendientes/ })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: /^Impagos/ })).toHaveAttribute('aria-pressed', 'true')
  })

  it('con estado cancelado el summary prende verCancelados, como hace la lista', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Elegir estado cancelado' }))

    await waitFor(() => expect(ultimosFiltros().lista.estado).toBe('cancelado'))

    const { stats, lista } = ultimosFiltros()
    expect(lista.verCancelados).not.toBe(true)
    expect(stats.estado).toBe('todos')
    expect(stats.verCancelados).toBe(true)
  })
})

// =============================================================================
// VistaPedidos REAL → PedidoStats
// =============================================================================

type Roles = Pick<VistaPedidosProps, 'isAdmin' | 'isPreventista' | 'isTransportista' | 'isEncargado'>

const FILTROS_VISTA: FiltrosPedidosState = {
  fechaDesde: null,
  fechaHasta: null,
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: 'todos',
  usuarioId: 'todos',
  busqueda: '',
  conSalvedad: 'todos',
}

/** Las props obligatorias de la vista, como en `VistaPedidos.error.test.tsx`. */
function propsVista(roles: Roles, overrides: Partial<VistaPedidosProps> = {}): VistaPedidosProps {
  return {
    pedidos: [],
    totalCount: 0,
    statsSummary: SUMMARY,
    paginaActual: 1,
    totalPaginas: 1,
    busqueda: '',
    filtros: FILTROS_VISTA,
    userId: 'u1',
    clientes: [],
    productos: [],
    loading: false,
    exportando: false,
    onBusquedaChange: vi.fn(),
    onFiltrosChange: vi.fn(),
    onPageChange: vi.fn(),
    onNuevoPedido: vi.fn(),
    onOptimizarRuta: vi.fn(),
    onExportarPDF: vi.fn(),
    onExportarExcel: vi.fn(),
    onModalFiltroFecha: vi.fn(),
    onVerHistorial: vi.fn(),
    onEditarPedido: vi.fn(),
    onMarcarEnPreparacion: vi.fn(),
    onVolverAPendiente: vi.fn(),
    onMarcarEntregado: vi.fn(),
    onDesmarcarEntregado: vi.fn(),
    ...roles,
    ...overrides,
  }
}

const NOMBRE_GRUPO = 'Filtrar pedidos por estado o pago'

// Todos los roles que ven la lista. "Impagos" filtra para todos, no sólo para
// el admin: el tile es el control del filtro de pago del que no tiene el select.
const ROLES_CON_LISTA: Array<[string, Roles]> = [
  ['admin', { isAdmin: true, isPreventista: false, isTransportista: false, isEncargado: false }],
  ['preventista', { isAdmin: false, isPreventista: true, isTransportista: false, isEncargado: false }],
  ['encargado', { isAdmin: false, isPreventista: false, isTransportista: false, isEncargado: true }],
  ['depósito (ningún flag)', { isAdmin: false, isPreventista: false, isTransportista: false, isEncargado: false }],
  ['preventista que también reparte, fuera del modo ruta', { isAdmin: false, isPreventista: true, isTransportista: true, isEncargado: false }],
]

describe('VistaPedidos real — le pasa a PedidoStats los filtros y el onFiltrosChange (#715)', () => {
  let VistaPedidosReal: (props: VistaPedidosProps) => React.ReactElement

  beforeAll(async () => {
    VistaPedidosReal = (await vi.importActual<typeof import('../../vistas/VistaPedidos')>('../../vistas/VistaPedidos')).default
  })

  it.each(ROLES_CON_LISTA)('%s: los seis tiles son botones y "Impagos" filtra', async (_rol, roles) => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(<VistaPedidosReal {...propsVista(roles, { onFiltrosChange })} />)

    const grupo = screen.getByRole('group', { name: NOMBRE_GRUPO })
    expect(within(grupo).getAllByRole('button')).toHaveLength(6)

    await user.click(within(grupo).getByRole('button', { name: /^Impagos/ }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'impago' })
  })

  it('los tiles se marcan contra los filtros que recibe la vista', () => {
    const roles: Roles = { isAdmin: false, isPreventista: true, isTransportista: false, isEncargado: false }
    render(
      <VistaPedidosReal {...propsVista(roles, { filtros: { ...FILTROS_VISTA, estado: 'asignado', estadoPago: 'impago' } })} />,
    )

    const grupo = screen.getByRole('group', { name: NOMBRE_GRUPO })
    expect(within(grupo).getByRole('button', { name: /^En camino/ })).toHaveAttribute('aria-pressed', 'true')
    expect(within(grupo).getByRole('button', { name: /^Impagos/ })).toHaveAttribute('aria-pressed', 'true')
    expect(within(grupo).getByRole('button', { name: /^Pendientes/ })).toHaveAttribute('aria-pressed', 'false')
  })

  it('el transportista puro ve el mapa de la ruta, sin tiles', () => {
    const roles: Roles = { isAdmin: false, isPreventista: false, isTransportista: true, isEncargado: false }
    render(<VistaPedidosReal {...propsVista(roles)} />)

    expect(screen.getByText('Mapa de la ruta activa')).toBeInTheDocument()
    expect(screen.queryByRole('group', { name: NOMBRE_GRUPO })).not.toBeInTheDocument()
  })
})
