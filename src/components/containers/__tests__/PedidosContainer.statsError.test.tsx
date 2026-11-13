/**
 * FRT-3 (#1517): si la consulta de totales de Pedidos falla, los tiles mostraban
 * "0 · $0" como si fueran datos: el container se caía al resumen vacío de relleno
 * (`data = EMPTY_PEDIDO_STATS_SUMMARY`) sin avisarle a la vista que no había nada
 * real. Ahora la vista recibe `statsError` (con su reintento) y `statsCargando`.
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.clientesInvalida.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, supabaseStub, registrarPagosBatch, fetchPagosPedido, notifyMock, PEDIDO, statsQuery } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    statsQuery: { valor: {} as Record<string, unknown> },
    invalidateQueries: vi.fn(),
    registrarPagosBatch: vi.fn(),
    fetchPagosPedido: vi.fn(),
    notifyMock: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    PEDIDO: {
      id: 42, cliente_id: '9', estado: 'entregado', total: 1000, monto_pagado: 0, items: [],
      cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
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
  getSucursalHeader: vi.fn(() => 1),
}))

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

// Se parte del barrel real y se pisan sólo los hooks que el container usa: así
// un hook nuevo no rompe este test con "No export is defined on the mock".
vi.mock('../../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({
    data: { pedidos: [PEDIDO], total: 1, totalPages: 1 }, isLoading: false, isFetching: false,
  }),
  usePedidoStatsQuery: () => statsQuery.valor,
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
  usePagos: () => ({
    registrarPago: vi.fn(), registrarPagosBatch, anularPago: vi.fn(), obtenerPagosPedido: vi.fn(), fetchPagosPedido,
  }),
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

// La vista, reducida a lo que recibe de los tiles.
vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ statsSummary, statsCargando, statsError, onRetryStats }: {
    statsSummary: { total?: { count: number } }
    statsCargando?: boolean
    statsError?: boolean
    onRetryStats?: () => void
  }) => (
    <>
      <p data-testid="estado">{statsError ? 'error' : statsCargando ? 'cargando' : 'ok'}</p>
      <p data-testid="total">{String(statsSummary?.total?.count ?? 'sin-resumen')}</p>
      <button type="button" onClick={() => onRetryStats?.()}>Reintentar totales</button>
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

const RESUMEN = { total: { count: 18, monto: 15000 } }

beforeEach(() => {
  vi.clearAllMocks()
  fetchPagosPedido.mockResolvedValue([])
  supabaseStub.rpc.mockImplementation(() => Promise.resolve({ data: { success: true }, error: null }))
})

describe('PedidosContainer — los tiles sin datos reales (FRT-3)', () => {
  it('con la consulta fallida y sin nada en caché, la vista recibe el error', async () => {
    const refetch = vi.fn()
    statsQuery.valor = { data: undefined, isLoading: false, isError: true, isPlaceholderData: false, refetch }
    renderContainer()

    expect(await screen.findByTestId('estado')).toHaveTextContent('error')
  })

  it('"Reintentar" de los tiles vuelve a pedir los totales', async () => {
    const refetch = vi.fn()
    statsQuery.valor = { data: undefined, isLoading: false, isError: true, isPlaceholderData: false, refetch }
    renderContainer()

    fireEvent.click(await screen.findByRole('button', { name: 'Reintentar totales' }))

    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('mientras llega el primer resumen (relleno vacío) la vista sabe que está cargando', async () => {
    statsQuery.valor = { data: { total: { count: 0, monto: 0 } }, isLoading: false, isError: false, isPlaceholderData: true, refetch: vi.fn() }
    renderContainer()

    expect(await screen.findByTestId('estado')).toHaveTextContent('cargando')
  })

  it('con datos reales todo sigue igual: ni cargando ni error', async () => {
    statsQuery.valor = { data: RESUMEN, isLoading: false, isError: false, isPlaceholderData: false, refetch: vi.fn() }
    renderContainer()

    expect(await screen.findByTestId('estado')).toHaveTextContent('ok')
    expect(screen.getByTestId('total')).toHaveTextContent('18')
  })

  it('un refetch fallido con datos en caché conserva los números (no los pisa con un error)', async () => {
    statsQuery.valor = { data: RESUMEN, isLoading: false, isError: true, isPlaceholderData: false, refetch: vi.fn() }
    renderContainer()

    expect(await screen.findByTestId('estado')).toHaveTextContent('ok')
    expect(screen.getByTestId('total')).toHaveTextContent('18')
  })
})
