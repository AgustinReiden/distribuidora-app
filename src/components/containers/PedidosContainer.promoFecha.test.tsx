/**
 * #1152: el alta resuelve las promos con la fecha del pedido topada a hoy.
 *
 * El container es el que arma lo que se guarda y lo que se encola (no el
 * modal, que sólo muestra): si su `usePromocionPedido` siguiera pidiendo las
 * promos de hoy, un alta con fecha atrasada se guardaría con las de hoy aunque
 * el modal mostrara las de su fecha. Se monta el container con la vista y el
 * modal stubbeados y se mira con qué fecha llama al hook.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, rpc, supabaseStub, usePromocionPedidoMock } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    // #1152: el hook de precios del container, para ver con qué fecha lo llama.
    usePromocionPedidoMock: vi.fn((..._args: unknown[]) => ({
      preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
      promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
      itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
      itemsConDescuentoCliente: [], totalConDescuentoCliente: 0,
      // #1191: sin combos.
      combos: [], combosAplicados: [], lineasConCombos: [], totalConCombos: 0, ahorroCombos: 0,
      isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
    })),
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
  }
})

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
  estado: 'en_preparacion',
  total: 1000,
  items: [],
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
}

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

// Se parte del barrel real y se pisan sólo los hooks que el container usa: así
// un hook nuevo no rompe este test con "No export is defined on the mock".
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

vi.mock('../../hooks/queries/useRecorridoActivoQuery', () => ({
  useRecorridoActivoQuery: () => ({ data: null }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'admin' },
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
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
  usePagos: () => ({ registrarPago: vi.fn(), anularPago: vi.fn(), obtenerPagosPedido: vi.fn() }),
}))
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: (...args: unknown[]) => usePromocionPedidoMock(...args),
}))

// La vista sólo tiene que poder abrir el alta.
vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onNuevoPedido }: { onNuevoPedido?: () => void }) => (
    <button type="button" onClick={() => onNuevoPedido?.()}>Nuevo pedido</button>
  ),
}))

// El modal real no es lo que se prueba: alcanza con cambiar la fecha del alta
// como lo hace su input.
vi.mock('../modals/ModalPedido', () => ({
  default: ({ onFechaChange }: { onFechaChange?: (fecha: string) => void }) => (
    <>
      <button type="button" onClick={() => onFechaChange?.(fechaHaceDias(3))}>Fecha atrasada</button>
      <button type="button" onClick={() => onFechaChange?.(fechaLocalISO())}>Fecha de hoy</button>
    </>
  ),
}))

import PedidosContainer from './PedidosContainer'
import { fechaHaceDias, fechaLocalISO } from '../../utils/formatters'

const fechaDeLaUltimaLlamada = () => {
  const llamadas = usePromocionPedidoMock.mock.calls
  return llamadas[llamadas.length - 1]?.[1]
}

function montar() {
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

describe('PedidosContainer — fecha de las promos del alta (#1152)', () => {
  it('con la fecha de hoy pide las promos de hoy (undefined)', async () => {
    montar()
    await screen.findByRole('button', { name: 'Nuevo pedido' })
    expect(usePromocionPedidoMock).toHaveBeenCalled()
    expect(usePromocionPedidoMock.mock.calls.every(c => c[1] === undefined)).toBe(true)
  })

  it('con una fecha atrasada pide las promos de esa fecha, y al volver a hoy, las de hoy', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Fecha atrasada' }))
    expect(fechaDeLaUltimaLlamada()).toBe(fechaHaceDias(3))

    await user.click(screen.getByRole('button', { name: 'Fecha de hoy' }))
    expect(fechaDeLaUltimaLlamada()).toBeUndefined()
  })
})
