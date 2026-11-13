/**
 * Registrar una salvedad refresca la ruta del chofer (#1549, FRT-01).
 *
 * EL HUECO
 * --------
 * La salvedad baja el total de la boleta (`nuevo_total_pedido`), pero
 * `handleSaveSalvedades` sólo invalidaba `productos`, `pedidos` y `clientes`. La
 * pantalla del chofer lee de `['recorrido-activo']` (staleTime 60 s), así que
 * seguía mostrando «A COBRAR $1.000» con la boleta ya en $700 y el cobro proponía
 * el monto viejo: el server lo rechaza, pero el cliente ya había puesto la plata
 * en la mano del chofer.
 *
 * El andamiaje de mocks es copia, recortada, del de
 * `PedidosContainer.salvedadesErrores.test.tsx`.
 */
import React, { useState } from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { conAbortSignal } from '../../../test/conAbortSignal'

const { rpc, supabaseStub, invalidar } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    rpc: rpcFn,
    invalidar: vi.fn(),
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn(() => ({
        select: vi.fn(() => ({ data: [], error: null })),
        update: vi.fn(() => ({ eq: vi.fn(() => Promise.resolve({ error: null })) })),
      })),
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      },
    },
  }
})

// El cliente tiene que ser estable: el container lo mete en las deps de sus handlers.
vi.mock('@tanstack/react-query', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@tanstack/react-query')>()
  const cliente = { invalidateQueries: invalidar, setQueryData: vi.fn(), getQueryData: vi.fn() }
  return { ...actual, useQueryClient: () => cliente }
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

vi.mock('../../../hooks/queries', async (importOriginal) => ({
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

vi.mock('../../../hooks/queries/useRecorridoActivoQuery', () => ({
  useRecorridoActivoQuery: () => ({ data: null }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'admin' },
  }),
}))

// El objeto tiene que ser estable: el container lo mete en las deps de sus handlers.
vi.mock('../../../contexts/NotificationContext', () => {
  const notify = { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }
  return { useNotification: () => notify }
})

vi.mock('../../../contexts/SucursalContext', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useSucursal: () => ({ currentSucursalId: 1, sucursales: [], loading: false }),
}))
vi.mock('../../../hooks/useOfflineSync', () => ({ useOfflineSync: () => ({ isOnline: true, pendingCount: 0 }) }))
vi.mock('../../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
vi.mock('../../../hooks/useOptimizarRuta', () => ({
  useOptimizarRuta: () => ({
    loading: false, rutaOptimizada: null, error: null,
    optimizarRuta: vi.fn(), optimizarRutaMulti: vi.fn(), setRutaOptimizada: vi.fn(), limpiarRuta: vi.fn(),
  }),
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

// La vista de la ruta del chofer llama a `onRegistrarSalvedad` (= handleRegistrarSalvedadSingle,
// que envuelve a handleSaveSalvedades) y muestra el resultado.
vi.mock('../../vistas/VistaPedidos', () => ({
  default: function VistaFalsa({ onRegistrarSalvedad }: {
    onRegistrarSalvedad?: (d: {
      pedidoId: string; pedidoItemId: string; cantidadAfectada: number
      motivo: 'cliente_rechaza'; devolverStock: boolean; clientRequestId: string
    }) => Promise<{ success: boolean; error?: string }>
  }) {
    const [msg, setMsg] = useState('')
    return (
      <div>
        <button
          type="button"
          onClick={() => {
            void onRegistrarSalvedad?.({
              pedidoId: '42', pedidoItemId: '7', cantidadAfectada: 3,
              motivo: 'cliente_rechaza', devolverStock: true, clientRequestId: 'req-1',
            }).then((r) => setMsg(r.error ?? 'OK'))
          }}
        >
          Registrar salvedad
        </button>
        <p data-testid="resultado">{msg}</p>
      </div>
    )
  },
}))

import PedidosContainer from '../PedidosContainer'

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

const claves = (): string[] => invalidar.mock.calls.map(([f]) => JSON.stringify((f as { queryKey: unknown }).queryKey))

async function registrar(): Promise<void> {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Registrar salvedad' }))
  await waitFor(() => expect(screen.getByTestId('resultado').textContent).not.toBe(''), { timeout: 5000 })
}

beforeEach(() => {
  vi.clearAllMocks()
  invalidar.mockResolvedValue(undefined)
})

describe('PedidosContainer — una salvedad refresca la ruta del chofer (#1549)', () => {
  it('con la salvedad registrada, invalida la ruta activa (de donde lee la pantalla del chofer) y los recorridos', async () => {
    rpc.mockImplementation(() => conAbortSignal({ data: { success: true, nuevo_total_pedido: 700 }, error: null }))
    await registrar()

    expect(screen.getByTestId('resultado').textContent).toBe('OK')
    expect(claves()).toContain(JSON.stringify(['recorrido-activo']))
    expect(claves()).toContain(JSON.stringify(['recorridos']))
    // Lo que ya refrescaba, sigue.
    expect(claves()).toContain(JSON.stringify(['pedidos']))
    expect(claves()).toContain(JSON.stringify(['clientes']))
  })

  it('espera el refetch de la ruta antes de devolver el resultado (el chofer sigue con el saldo nuevo)', async () => {
    rpc.mockImplementation(() => conAbortSignal({ data: { success: true }, error: null }))
    let termino!: () => void
    invalidar.mockImplementation(({ queryKey }: { queryKey: unknown[] }) =>
      queryKey[0] === 'recorrido-activo' ? new Promise<void>(r => { termino = r }) : Promise.resolve())

    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Registrar salvedad' }))
    await waitFor(() => expect(claves()).toContain(JSON.stringify(['recorrido-activo'])))
    // Con el refetch todavía en vuelo, la pantalla no tiene resultado.
    expect(screen.getByTestId('resultado').textContent).toBe('')

    termino()
    await waitFor(() => expect(screen.getByTestId('resultado').textContent).toBe('OK'))
  })

  it('una salvedad rechazada por el server también refresca (puede haber quedado a medias)', async () => {
    rpc.mockImplementation(() => conAbortSignal({ data: { success: false, error: 'No se puede' }, error: null }))
    await registrar()

    expect(screen.getByTestId('resultado').textContent).toBe('No se puede')
    expect(claves()).toContain(JSON.stringify(['recorrido-activo']))
  })
})
