/**
 * 1544-b1 / 1544-b2 (#1544): «Quitar de la boleta» un pago que es saldo a favor aplicado (COB-2,
 * mig 479) lo deja suelto. Si ese pago era el crédito de una nota de crédito, la NC vuelve a
 * tener saldo por imputar: el container tiene que invalidar `['notas_credito_venta']` (antes sólo
 * `pedidos` y `clientes`) y, como cambia la deuda vencida, `['deudores-mora']`.
 *
 * El andamiaje de mocks es una versión recortada del de `PedidosContainer.datosCaidos.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { invalidateQueries, supabaseStub, notify, usePagosMock } = vi.hoisted(() => ({
  invalidateQueries: vi.fn(),
  notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
  usePagosMock: {
    registrarPago: vi.fn(),
    registrarPagosBatch: vi.fn(),
    fetchPagosPedido: vi.fn(),
    eliminarPago: vi.fn(),
    desimputarPago: vi.fn(),
    actualizarFormaPagoDePago: vi.fn(),
  },
  supabaseStub: {
    rpc: vi.fn(),
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
}))

vi.mock('@tanstack/react-query', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@tanstack/react-query')>()
  return { ...actual, useQueryClient: () => ({ invalidateQueries, setQueryData: vi.fn(), getQueryData: vi.fn() }) }
})

vi.mock('../../lib/supabase', () => ({
  supabase: supabaseStub,
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../hooks/supabase/base', () => ({
  supabase: supabaseStub,
  setErrorNotifier: vi.fn(),
  notifyError: vi.fn(),
  handleSupabaseError: vi.fn(),
}))

const PEDIDO = {
  id: 42,
  cliente_id: '9',
  estado: 'entregado',
  total: 1000,
  items: [],
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
}

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({ data: { pedidos: [PEDIDO], total: 1, totalPages: 1 }, isLoading: false, isFetching: false }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => emptyMutation,
  useAsignarTransportistaMutation: () => emptyMutation,
  useQuitarPedidoDeRecorridosMutation: () => emptyMutation,
  useVolverPedidoAPendienteMutation: () => emptyMutation,
  useEntregasMasivasMutation: () => emptyMutation,
  useCancelarPedidoMutation: () => emptyMutation,
  useRevertirCancelacionMutation: () => emptyMutation,
  useCambiarClientePedidoMutation: () => emptyMutation,
  usePagosMasivosMutation: () => emptyMutation,
  useEntregaYPagoMasivosMutation: () => emptyMutation,
  usePedidosAsignadosQuery: () => emptyQuery,
  useClientesQuery: () => emptyQuery,
  useClientesOperativosQuery: () => emptyQuery,
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

vi.mock('../../hooks/queries/useRecorridoActivoQuery', () => ({
  useRecorridoActivoQuery: () => ({ data: null }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({
    politicas: { montoMinimoPedido: 0, modoMinimoPedido: 'cargo', montoEnvioGratis: 0, cargoEnvioPedido: 0 },
  }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false, isOnline: true, authReady: true,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'admin' },
  }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => notify,
}))
vi.mock('../../contexts/SucursalContext', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useSucursal: () => ({ currentSucursalId: 1, sucursales: [], loading: false }),
}))
vi.mock('../../hooks/useOfflineSync', () => ({ useOfflineSync: () => ({ isOnline: true, pendingCount: 0 }) }))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
vi.mock('../../hooks/useOptimizarRuta', () => ({
  useOptimizarRuta: () => ({ optimizar: vi.fn(), optimizando: false }),
  horarioParaRutear: () => null,
}))
vi.mock('../../hooks/useRegistrarGeolocalizacionPedido', () => ({
  useRegistrarGeolocalizacionPedido: () => ({ registrar: vi.fn() }),
}))
vi.mock('../../hooks/supabase/usePagos', () => ({
  usePagos: () => usePagosMock,
}))

// La vista abre el cobro del pedido; el modal de cobro, el «Quitar de la boleta» del pago 77.
vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onAbrirPagoPedido }: { onAbrirPagoPedido?: (p: unknown) => void }) => (
    <button type="button" onClick={() => onAbrirPagoPedido?.(PEDIDO)}>Abrir cobro</button>
  ),
}))
vi.mock('../modals/ModalPagoPedido', () => ({
  default: ({ onQuitarDeBoleta }: { onQuitarDeBoleta?: (pagoId: string) => Promise<void> }) => (
    <button type="button" onClick={() => { void onQuitarDeBoleta?.('77') }}>Quitar de la boleta</button>
  ),
}))

import PedidosContainer from './PedidosContainer'

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

const clavesInvalidadas = (): string[] =>
  invalidateQueries.mock.calls.map(([arg]) => JSON.stringify((arg as { queryKey: unknown }).queryKey))

beforeEach(() => {
  vi.clearAllMocks()
  usePagosMock.fetchPagosPedido.mockResolvedValue([])
  usePagosMock.desimputarPago.mockResolvedValue({ yaEstabaSuelto: false, saldoAFavor: 500 })
})

describe('PedidosContainer — quitar de la boleta un pago que es saldo a favor aplicado (1544-b1/b2)', () => {
  it('invalida pedidos, clientes, las notas de crédito y los deudores en mora', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Abrir cobro' }))
    await user.click(await screen.findByRole('button', { name: 'Quitar de la boleta' }))

    await waitFor(() => expect(usePagosMock.desimputarPago).toHaveBeenCalledWith('77', '42'))
    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    const claves = clavesInvalidadas()
    expect(claves).toContain('["pedidos"]')
    expect(claves).toContain('["clientes"]')
    expect(claves).toContain('["notas_credito_venta"]')
    expect(claves).toContain('["deudores-mora"]')
  })
})
