/**
 * COB-F-5 (#1476): la clave de un cobro masivo se olvida cuando el cobro sale bien.
 *
 * Mismo lote + misma forma + misma fecha reusaban la clave para siempre: un
 * segundo cobro idéntico (p. ej. anular un pago y volver a marcar) se tomaba por
 * replay, y el toast decía "pagado" sin registrar nada. Con un error, en cambio, la
 * clave tiene que sobrevivir: es lo que hace seguro el reintento (mig 167).
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.confirmarEntrega.test.tsx`.
 * La vista y los dos modales masivos se reemplazan por botones que disparan los handlers.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { supabaseStub, pagosMasivos, entregaYPagoMasivos, notifyMock } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      },
    },
    pagosMasivos: { mutateAsync: vi.fn(), mutate: vi.fn(), isPending: false },
    entregaYPagoMasivos: { mutateAsync: vi.fn(), mutate: vi.fn(), isPending: false },
    notifyMock: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
  }
})

vi.mock('@tanstack/react-query', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@tanstack/react-query')>()
  return { ...actual, useQueryClient: () => ({ invalidateQueries: vi.fn(), setQueryData: vi.fn(), getQueryData: vi.fn() }) }
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
  getSucursalHeader: vi.fn(() => 1),
}))

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

// Se parte del barrel real y se pisan sólo los hooks que el container usa: así
// un hook nuevo no rompe este test con "No export is defined on the mock".
vi.mock('../../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({
    data: { pedidos: [], total: 0, totalPages: 1 }, isLoading: false, isFetching: false,
  }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => emptyMutation,
  useAsignarTransportistaMutation: () => emptyMutation,
  useQuitarPedidoDeRecorridosMutation: () => emptyMutation,
  useVolverPedidoAPendienteMutation: () => emptyMutation,
  useEntregasMasivasMutation: () => emptyMutation,
  useCancelarPedidoMutation: () => emptyMutation,
  useCambiarClientePedidoMutation: () => emptyMutation,
  usePagosMasivosMutation: () => pagosMasivos,
  useEntregaYPagoMasivosMutation: () => entregaYPagoMasivos,
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
  useNotification: () => notifyMock,
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
  usePagos: () => ({ registrarPago: vi.fn(), anularPago: vi.fn(), obtenerPagosPedido: vi.fn(), fetchPagosPedido: vi.fn().mockResolvedValue([]) }),
}))
vi.mock('../../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ onPagosMasivos, onEntregaYPagoMasivos }: {
    onPagosMasivos: () => void
    onEntregaYPagoMasivos: () => void
  }) => (
    <>
      <button type="button" onClick={onPagosMasivos}>Abrir pagos masivos</button>
      <button type="button" onClick={onEntregaYPagoMasivos}>Abrir entrega y pago</button>
    </>
  ),
}))
vi.mock('../../modals/ModalPagosMasivos', () => ({
  default: ({ onConfirm }: { onConfirm: (forma: string, ids: string[], fecha: string) => Promise<void> }) => (
    <button type="button" onClick={() => void onConfirm('efectivo', ['10', '11'], '2026-11-05')}>Confirmar pagos masivos</button>
  ),
}))
vi.mock('../../modals/ModalEntregaYPagoMasivos', () => ({
  default: ({ onConfirm }: { onConfirm: (t: string, forma: string, ids: { idsEntregar: string[]; idsCobrar: string[] }, fecha: string) => Promise<void> }) => (
    <button type="button" onClick={() => void onConfirm('t-1', 'efectivo', { idsEntregar: ['20'], idsCobrar: ['21'] }, '2026-11-05')}>
      Confirmar entrega y pago
    </button>
  ),
}))

import PedidosContainer from '../PedidosContainer'

function renderContainer() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

const ESPERA_MODAL = { timeout: 5000 }

beforeEach(() => {
  vi.clearAllMocks()
  supabaseStub.rpc.mockImplementation(() => Promise.resolve({ data: { success: true }, error: null }))
  pagosMasivos.mutateAsync.mockResolvedValue({})
  entregaYPagoMasivos.mutateAsync.mockResolvedValue({ entregados: 1, cobrados: 1, error: null })
})

async function confirmarPagosMasivos(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByRole('button', { name: 'Abrir pagos masivos' }))
  await user.click(await screen.findByRole('button', { name: 'Confirmar pagos masivos' }, ESPERA_MODAL))
}

async function confirmarEntregaYPago(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByRole('button', { name: 'Abrir entrega y pago' }))
  await user.click(await screen.findByRole('button', { name: 'Confirmar entrega y pago' }, ESPERA_MODAL))
}

describe('PedidosContainer — la clave del cobro masivo (COB-F-5)', () => {
  it('pagos masivos: tras un cobro exitoso, el mismo cobro lleva otra clave', async () => {
    const user = userEvent.setup()
    renderContainer()

    await confirmarPagosMasivos(user)
    await waitFor(() => expect(pagosMasivos.mutateAsync).toHaveBeenCalledTimes(1))
    await confirmarPagosMasivos(user)
    await waitFor(() => expect(pagosMasivos.mutateAsync).toHaveBeenCalledTimes(2))

    const [a, b] = pagosMasivos.mutateAsync.mock.calls.map(c => c[0].clientRequestId)
    expect(a).toBeTruthy()
    expect(b).not.toBe(a)
  })

  it('pagos masivos: si falla, el reintento lleva la misma clave', async () => {
    pagosMasivos.mutateAsync.mockRejectedValueOnce(new Error('Sin conexión'))
    const user = userEvent.setup()
    renderContainer()

    await confirmarPagosMasivos(user)
    await waitFor(() => expect(pagosMasivos.mutateAsync).toHaveBeenCalledTimes(1))
    await confirmarPagosMasivos(user)
    await waitFor(() => expect(pagosMasivos.mutateAsync).toHaveBeenCalledTimes(2))

    const [a, b] = pagosMasivos.mutateAsync.mock.calls.map(c => c[0].clientRequestId)
    expect(b).toBe(a)
  })

  it('entrega y pago masivos: tras un éxito completo, las dos claves se renuevan', async () => {
    const user = userEvent.setup()
    renderContainer()

    await confirmarEntregaYPago(user)
    await waitFor(() => expect(entregaYPagoMasivos.mutateAsync).toHaveBeenCalledTimes(1))
    await confirmarEntregaYPago(user)
    await waitFor(() => expect(entregaYPagoMasivos.mutateAsync).toHaveBeenCalledTimes(2))

    const [p, s] = entregaYPagoMasivos.mutateAsync.mock.calls.map(c => c[0])
    expect(s.clientRequestIdCobrar).not.toBe(p.clientRequestIdCobrar)
    expect(s.clientRequestIdEntregar).not.toBe(p.clientRequestIdEntregar)
  })

  it('entrega y pago masivos: si un paso falló, el reintento conserva las claves', async () => {
    entregaYPagoMasivos.mutateAsync.mockResolvedValueOnce({
      entregados: 0, cobrados: 1, error: { paso: 'entregar', mensaje: 'Sin conexión' },
    })
    const user = userEvent.setup()
    renderContainer()

    await confirmarEntregaYPago(user)
    await waitFor(() => expect(entregaYPagoMasivos.mutateAsync).toHaveBeenCalledTimes(1))
    await confirmarEntregaYPago(user)
    await waitFor(() => expect(entregaYPagoMasivos.mutateAsync).toHaveBeenCalledTimes(2))

    const [p, s] = entregaYPagoMasivos.mutateAsync.mock.calls.map(c => c[0])
    expect(s.clientRequestIdCobrar).toBe(p.clientRequestIdCobrar)
    expect(s.clientRequestIdEntregar).toBe(p.clientRequestIdEntregar)
  })
})
