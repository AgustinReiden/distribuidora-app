/**
 * #1700: el aviso al entregar con salvedades dice si quedaron resueltas por la oficina.
 *
 * La salvedad que carga un admin o un encargado nace resuelta (`resuelto_otro`) y la RPC
 * `registrar_salvedad` lo contesta en `estado_resolucion`. El container guarda lo que contestó el
 * último guardado del modal de entrega y, al marcar entregado, el aviso dice «resueltas por la
 * oficina» si todas quedaron así; si alguna quedó pendiente (la del chofer) o el server no lo dice,
 * el aviso de siempre.
 *
 * El andamiaje de mocks es copia, recortada, del de `PedidosContainer.salvedadesErrores.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { conAbortSignal } from '../../../test/conAbortSignal'

const { rpc, supabaseStub, notify } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    rpc: rpcFn,
    // El objeto tiene que ser estable: el container lo mete en las deps de sus handlers.
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
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
// Aparte, para poder hacer fallar una entrega.
const cambiarEstadoMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

vi.mock('../../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({ data: { pedidos: [PEDIDO], total: 1, totalPages: 1 }, isLoading: false, isFetching: false }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => cambiarEstadoMutation,
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

vi.mock('../../../contexts/NotificationContext', () => ({ useNotification: () => notify }))

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
    datosPrecio: { cargando: [], fallaron: [], sinSenal: [] }, entradasDatosPrecio: [], reintentarDatosPrecio: () => {},
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

// El modal de entrega: guarda dos salvedades en un solo `onSave` y, si entraron, marca entregado.
// «Entregar sin guardar» marca entregado sin guardar nada en este modal, y «Cerrar» lo cierra.
vi.mock('../../modals/ModalEntregaConSalvedad', () => ({
  default: function ModalFalso({ onSave, onMarcarEntregado, onClose }: {
    onSave: (s: unknown[]) => Promise<Array<{ success: boolean }>>
    onMarcarEntregado: () => Promise<void>
    onClose: () => void
  }) {
    const salvedad = (n: number) => ({
      pedidoId: '42', pedidoItemId: String(n), cantidadAfectada: 1,
      motivo: 'danado', devolverStock: false, clientRequestId: `req-lote-${n}`,
    })
    return (
      <div>
        <button
          type="button"
          onClick={() => {
            void onSave([salvedad(1), salvedad(2)]).then(r => (r.every(x => x.success) ? onMarcarEntregado() : undefined))
          }}
        >
          Guardar lote
        </button>
        <button type="button" onClick={() => { void onMarcarEntregado() }}>Entregar sin guardar</button>
        <button type="button" onClick={onClose}>Cerrar</button>
      </div>
    )
  },
}))

// La vista: abre el modal de entrega, o registra una salvedad suelta (el camino de la ruta del
// chofer, que usa el mismo guardado).
vi.mock('../../vistas/VistaPedidos', () => ({
  default: function VistaFalsa({ onMarcarEntregadoConSalvedad, onRegistrarSalvedad }: {
    onMarcarEntregadoConSalvedad?: (pedido: unknown) => void
    onRegistrarSalvedad?: (d: {
      pedidoId: string; pedidoItemId: string; cantidadAfectada: number
      motivo: 'danado'; devolverStock: boolean; clientRequestId: string
    }) => Promise<{ success: boolean }>
  }) {
    const [hecha, setHecha] = React.useState(false)
    return (
      <div>
        <button type="button" onClick={() => onMarcarEntregadoConSalvedad?.({ id: 42 })}>
          Abrir lote
        </button>
        <button
          type="button"
          onClick={() => {
            void onRegistrarSalvedad?.({
              pedidoId: '7', pedidoItemId: '70', cantidadAfectada: 1,
              motivo: 'danado', devolverStock: false, clientRequestId: 'req-suelta',
            }).then(() => setHecha(true))
          }}
        >
          Registrar una
        </button>
        {hecha && <p>Suelta registrada</p>}
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

// registrar_salvedad contesta con el estado que se le pida por salvedad (undefined = sin el dato).
function contestar(estados: Array<string | undefined>) {
  let n = 0
  rpc.mockImplementation((nombre: string) => {
    if (nombre !== 'registrar_salvedad') return conAbortSignal({ data: null, error: null })
    const estado = estados[n++]
    return conAbortSignal({
      data: { success: true, salvedad_id: 100 + n, ...(estado ? { estado_resolucion: estado } : {}) },
      error: null,
    })
  })
}

async function entregarConSalvedades(): Promise<string> {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Abrir lote' }))
  await user.click(await screen.findByRole('button', { name: 'Guardar lote' }))
  await waitFor(() => expect(notify.success).toHaveBeenCalled(), { timeout: 5000 })
  const llamadas = notify.success.mock.calls
  return String(llamadas[llamadas.length - 1]?.[0])
}

beforeEach(() => {
  vi.clearAllMocks()
})

afterEach(() => {
  vi.restoreAllMocks()
})

describe('PedidosContainer — aviso de la entrega con salvedades (#1700)', () => {
  it('si las dos nacieron resueltas (las cargó la oficina), el aviso dice que quedaron resueltas', async () => {
    contestar(['resuelto_otro', 'resuelto_otro'])
    expect(await entregarConSalvedades()).toBe('Pedido entregado con salvedades registradas y resueltas por la oficina')
  })

  it('si una quedó pendiente, el aviso de siempre', async () => {
    contestar(['resuelto_otro', 'pendiente'])
    expect(await entregarConSalvedades()).toBe('Pedido entregado con salvedades registradas')
  })

  it('un server anterior a #1700 (sin estado_resolucion): el aviso de siempre', async () => {
    contestar([undefined, undefined])
    expect(await entregarConSalvedades()).toBe('Pedido entregado con salvedades registradas')
  })

  // N7 de la revisión: lo que contestó otro guardado no vale para esta entrega.
  it('una salvedad suelta resuelta (la vista del chofer) no hace decir «resueltas» a la entrega de otro pedido', async () => {
    contestar(['resuelto_otro'])
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Registrar una' }))
    await screen.findByText('Suelta registrada')
    await user.click(screen.getByRole('button', { name: 'Abrir lote' }))
    await user.click(await screen.findByRole('button', { name: 'Entregar sin guardar' }))
    await waitFor(() => expect(notify.success).toHaveBeenCalled(), { timeout: 5000 })
    expect(notify.success).toHaveBeenLastCalledWith('Pedido entregado con salvedades registradas')
  })

  it('si la entrega falla y el modal se cierra, la próxima entrega no usa lo que contestó aquel guardado', async () => {
    contestar(['resuelto_otro', 'resuelto_otro'])
    cambiarEstadoMutation.mutateAsync.mockRejectedValueOnce(new Error('Sin conexión'))
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Abrir lote' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar lote' }))
    await waitFor(() => expect(notify.error).toHaveBeenCalledWith('Sin conexión'), { timeout: 5000 })
    expect(notify.success).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))
    await user.click(await screen.findByRole('button', { name: 'Abrir lote' }))
    await user.click(await screen.findByRole('button', { name: 'Entregar sin guardar' }))
    await waitFor(() => expect(notify.success).toHaveBeenCalled(), { timeout: 5000 })
    expect(notify.success).toHaveBeenLastCalledWith('Pedido entregado con salvedades registradas')
  })
})
