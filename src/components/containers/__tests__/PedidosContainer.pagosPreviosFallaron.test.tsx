/**
 * Los pagos previos de una boleta no se arrastran a la siguiente (#1453).
 *
 * LO QUE SE PROTEGE
 * -----------------
 * `pagosPreviosFallaron` vive en el container, no en el modal. Si la carga de los
 * pagos falló en una boleta y no se lo reseteaba al abrir la siguiente ni al
 * cerrar, el aviso rojo "no se pudieron cargar los pagos" se veía durante toda la
 * carga de la boleta nueva, aunque nada hubiera fallado en ella.
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.confirmarEntrega.test.tsx`.
 * La vista se reemplaza por un botón por boleta que dispara `onMarcarEntregado`
 * (ambas con saldo y chofer: abren el modal de pago).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { PedidoDB } from '../../../types'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { supabaseStub, cambiarEstado, aplicarCambioParada, notifyMock, fetchPagosPedido, PEDIDO_A, PEDIDO_B, CHOFERES } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  const impago = (id: number) => ({
    id, cliente_id: '9', estado: 'asignado', estado_pago: 'pendiente', canal: 'app', total: 1000, items: [],
    transportista_id: 't-1',
    cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
  })
  return {
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      },
    },
    cambiarEstado: { mutateAsync: vi.fn(), mutate: vi.fn(), isPending: false },
    aplicarCambioParada: { mutateAsync: vi.fn(), mutate: vi.fn(), isPending: false },
    notifyMock: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    fetchPagosPedido: vi.fn(),
    PEDIDO_A: impago(42),
    PEDIDO_B: impago(43),
    CHOFERES: [{ id: 't-1', nombre: 'Chofer Uno', rol: 'transportista' }],
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
    data: { pedidos: [PEDIDO_A, PEDIDO_B], total: 2, totalPages: 1 }, isLoading: false, isFetching: false,
  }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => cambiarEstado,
  useAsignarTransportistaMutation: () => emptyMutation,
  useQuitarPedidoDeRecorridosMutation: () => emptyMutation,
  useVolverPedidoAPendienteMutation: () => emptyMutation,
  useEntregasMasivasMutation: () => emptyMutation,
  useCancelarPedidoMutation: () => emptyMutation,
  useCambiarClientePedidoMutation: () => emptyMutation,
  usePagosMasivosMutation: () => emptyMutation,
  useEntregaYPagoMasivosMutation: () => emptyMutation,
  usePedidosAsignadosQuery: () => emptyQuery,
  useClientesQuery: () => emptyQuery,
  useProductosQuery: () => emptyQuery,
  useTransportistasQuery: () => ({ ...emptyQuery, data: CHOFERES }),
  useUsuariosQuery: () => emptyQuery,
  useCrearClienteMutation: () => emptyMutation,
  useActualizarClienteMutation: () => emptyMutation,
  useDepositoCoords: () => ({ data: null }),
  useDestinoCoords: () => ({ data: null }),
  useCrearPedidoCambioEnRutaMutation: () => emptyMutation,
  useAplicarCambioParadaMutation: () => aplicarCambioParada,
  useZonasEstandarizadasQuery: () => emptyQuery,
}))

vi.mock('../../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
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
  usePagos: () => ({ registrarPago: vi.fn(), anularPago: vi.fn(), obtenerPagosPedido: vi.fn(), fetchPagosPedido }),
}))
vi.mock('../../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    datosPrecio: { cargando: [], fallaron: [], sinSenal: [] }, entradasDatosPrecio: [], reintentarDatosPrecio: () => {},
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

// La vista: un botón por boleta, como el ítem «Marcar Entregado» del ⋮.
vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ onMarcarEntregado }: { onMarcarEntregado: (p: PedidoDB) => void }) => (
    <>
      <button type="button" onClick={() => onMarcarEntregado(PEDIDO_A as unknown as PedidoDB)}>
        Entregar la A
      </button>
      <button type="button" onClick={() => onMarcarEntregado(PEDIDO_B as unknown as PedidoDB)}>
        Entregar la B
      </button>
    </>
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

// El modal de pago es lazy: el import en frío se come casi todo el segundo por
// defecto de `findBy*`.
const ESPERA_MODAL = { timeout: 5000 }
const AVISO = /No se pudieron cargar los pagos de esta boleta/

beforeEach(() => {
  vi.clearAllMocks()
  fetchPagosPedido.mockReset()
  supabaseStub.rpc.mockImplementation(() => Promise.resolve({ data: { success: true }, error: null }))
})

describe('PedidosContainer — el aviso de pagos sin cargar es de cada boleta (#1453)', () => {
  it('al abrir otra boleta, el aviso de la anterior no se ve durante la carga nueva', async () => {
    // La A falla; la B queda cargando.
    fetchPagosPedido.mockResolvedValueOnce(null).mockReturnValueOnce(new Promise(() => {}))
    renderContainer()

    fireEvent.click(await screen.findByRole('button', { name: 'Entregar la A' }))
    expect((await screen.findByRole('alert', {}, ESPERA_MODAL)).textContent).toMatch(AVISO)

    // fireEvent y hidden: con el modal abierto, Radix oculta la vista y su overlay
    // bloquea el puntero.
    fireEvent.click(screen.getByRole('button', { name: 'Entregar la B', hidden: true }))
    await waitFor(() => expect(fetchPagosPedido).toHaveBeenCalledTimes(2))
    expect(await screen.findByText('Cargando pagos previos...')).toBeInTheDocument()
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()
  })

  it('al cerrar el modal se resetea: el siguiente no abre con el aviso de antes', async () => {
    const user = userEvent.setup()
    fetchPagosPedido.mockResolvedValueOnce(null).mockReturnValueOnce(new Promise(() => {}))
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Entregar la A' }))
    await screen.findByText(AVISO, {}, ESPERA_MODAL)
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())

    await user.click(screen.getByRole('button', { name: 'Entregar la B' }))
    expect(await screen.findByText('Cargando pagos previos...', {}, ESPERA_MODAL)).toBeInTheDocument()
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()
  })
})
