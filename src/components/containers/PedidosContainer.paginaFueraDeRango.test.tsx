/**
 * FRV-4 (#1598): la lista de pedidos no se queda en una página que ya no existe.
 *
 * Con 31 pedidos hay 3 páginas de 15, y la tercera tiene uno. Si se cancela, la
 * consulta de la página 3 vuelve vacía con un total de 30 (dos páginas), pero
 * `paginaActual` seguía en 3: la vista decía «No hay pedidos» con el título
 * contando 30, y la paginación ni se ve en una página que pasa del final.
 *
 * El andamiaje de mocks es el de `PedidosContainer.altaEnDuda.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { supabaseStub, servidor } = vi.hoisted(() => ({
  // Lo que contesta el server para cada página.
  servidor: { total: 31, placeholder: false },
  supabaseStub: {
    rpc: vi.fn(() => Promise.resolve({ data: null, error: null })),
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
}))

vi.mock('@tanstack/react-query', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@tanstack/react-query')>()
  return { ...actual, useQueryClient: () => ({ invalidateQueries: vi.fn(), setQueryData: vi.fn(), getQueryData: vi.fn() }) }
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

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

/**
 * La página `pagina` de 15, con el total que tiene hoy el server. La misma
 * respuesta es el mismo objeto, como en react-query: uno nuevo en cada render
 * hace correr sin fin los efectos que miran la lista.
 */
const respuestas = new Map<string, unknown>()
function paginaDelServidor(pagina: number) {
  const clave = `${pagina}|${servidor.total}|${servidor.placeholder}`
  if (!respuestas.has(clave)) respuestas.set(clave, armarPagina(pagina))
  return respuestas.get(clave)
}
function armarPagina(pagina: number) {
  const desde = (pagina - 1) * 15
  const cuantos = Math.max(0, Math.min(15, servidor.total - desde))
  return {
    data: {
      data: Array.from({ length: cuantos }, (_, i) => ({ id: desde + i + 1, estado: 'pendiente', items: [] })),
      totalCount: servidor.total,
    },
    isLoading: false, isFetching: false, isError: false, refetch: vi.fn(),
    isSuccess: true, isPlaceholderData: servidor.placeholder,
  }
}

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: (pagina: number) => paginaDelServidor(pagina),
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
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false,
    isOnline: true, authReady: true,
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
vi.mock('../../hooks/useOfflineSync', () => ({
  useOfflineSync: () => ({ isOnline: true, pendingCount: 0, guardarPedidoOffline: vi.fn() }),
}))
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

vi.mock('../vistas/VistaPedidos', () => ({
  default: (p: { pedidos: unknown[]; paginaActual: number; totalPaginas: number; onPageChange: (n: number) => void }) => (
    <>
      <p>{`Página ${p.paginaActual} de ${p.totalPaginas}`}</p>
      <p>{p.pedidos.length === 0 ? 'No hay pedidos' : `${p.pedidos.length} pedidos`}</p>
      <button type="button" onClick={() => p.onPageChange(3)}>Ir a la 3</button>
    </>
  ),
}))

import PedidosContainer from './PedidosContainer'

const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
/** El mismo árbol: volver a dibujarlo es el re-render de un refetch, sin desmontar. */
function arbol() {
  return (
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>
  )
}

beforeEach(() => {
  servidor.total = 31
  servidor.placeholder = false
})

describe('FRV-4 — la página de la lista no pasa del final', () => {
  it('se cancela el único pedido de la última página: vuelve a la página 2, con pedidos', async () => {
    const user = userEvent.setup()
    const { rerender } = render(arbol())
    await user.click(await screen.findByRole('button', { name: 'Ir a la 3' }))
    expect(screen.getByText('Página 3 de 3')).toBeInTheDocument()
    expect(screen.getByText('1 pedidos')).toBeInTheDocument()

    // El refetch tras la cancelación: quedan 30, dos páginas.
    servidor.total = 30
    rerender(arbol())

    await waitFor(() => expect(screen.getByText('Página 2 de 2')).toBeInTheDocument())
    expect(screen.getByText('15 pedidos')).toBeInTheDocument()
    expect(screen.queryByText('No hay pedidos')).not.toBeInTheDocument()
  })

  it('con los datos de la página anterior (placeholder) no se mueve: su total es de otra consulta', async () => {
    const user = userEvent.setup()
    const { rerender } = render(arbol())
    await user.click(await screen.findByRole('button', { name: 'Ir a la 3' }))

    servidor.total = 30
    servidor.placeholder = true
    rerender(arbol())

    expect(screen.getByText('Página 3 de 2')).toBeInTheDocument()
  })

  it('sin ningún pedido queda en la página 1', async () => {
    const user = userEvent.setup()
    const { rerender } = render(arbol())
    await user.click(await screen.findByRole('button', { name: 'Ir a la 3' }))

    servidor.total = 0
    rerender(arbol())

    await waitFor(() => expect(screen.getByText('Página 1 de 0')).toBeInTheDocument())
  })
})
