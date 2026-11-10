/**
 * La clave de idempotencia del alta (`pedidos.offline_id`, mig 071) sigue al
 * contenido del pedido (#1517, menor).
 *
 * `altaIdRef` se acuñaba en el primer intento y sobrevivía hasta limpiar el
 * formulario: si el primer intento fallaba y el usuario EDITABA el carrito antes
 * de reintentar, el reintento viajaba con la clave vieja. Si el primer intento sí
 * había entrado (respuesta perdida), el servidor devolvía el pedido de antes como
 * si fuera éste y la edición se perdía sin aviso. Un reintento SIN editar sigue
 * reusando la clave: es lo que impide crear el pedido dos veces.
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.cargoAlta.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, rpc, supabaseStub, registrarPago, notify, mutateAlta, politicasMock, clientesOperativosMock } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    // La lista que ve el modal del alta (#1509): de ahí sale el saldo a favor mostrado.
    clientesOperativosMock: { valor: [] as Array<{ id: string; saldo_cuenta: number }> },
    registrarPago: vi.fn(),
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    mutateAlta: vi.fn(),
    // Política de la sucursal: cobra 500 de envío bajo 20.000.
    politicasMock: {
      valor: { montoMinimoPedido: 20000, modoMinimoPedido: 'cargo', montoEnvioGratis: 0, cargoEnvioPedido: 500 },
    },
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
  useCrearPedidoMutation: () => ({ mutateAsync: mutateAlta, mutate: vi.fn(), isPending: false }),
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
  useClientesOperativosQuery: () => ({ ...emptyQuery, data: clientesOperativosMock.valor }),
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
  usePoliticasComercialesQuery: () => ({ politicas: politicasMock.valor }),
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
  usePagos: () => ({ registrarPago, anularPago: vi.fn(), obtenerPagosPedido: vi.fn() }),
}))
// El carrito: una línea de 12.000.
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [{ productoId: '7', cantidad: 1, precioUnitario: 12000 }],
    totalFinal: 12000, totalOriginal: 12000, ahorro: 0, hayDescuento: false,
    itemsConDescuentoCliente: [], totalConDescuentoCliente: 12000,
    combos: [], combosAplicados: [],
    lineasConCombos: [{ productoId: '7', cantidad: 1, precioUnitario: 12000 }],
    totalConCombos: 12000, ahorroCombos: 0,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

// La vista sólo tiene que poder abrir el alta.
vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onNuevoPedido }: { onNuevoPedido?: () => void }) => (
    <button type="button" onClick={() => onNuevoPedido?.()}>Nuevo pedido</button>
  ),
}))

// El modal real no es lo que se prueba: estos botones arman el pedido como lo
// hacen sus callbacks y lo confirman.
vi.mock('../modals/ModalPedido', () => ({
  default: (p: {
    onClienteChange: (id: string) => void
    onAgregarItem: (id: string, cantidad?: number, precio?: number) => void
    onEstadoPagoChange: (e: string) => void
    onMontoPagadoChange: (m: number) => void
    onFechaChange: (fecha: string) => void
    onGuardar: () => void
  }) => (
    <>
      <button type="button" onClick={() => { p.onClienteChange('9'); p.onAgregarItem('7', 1, 12000) }}>Armar</button>
      <button type="button" onClick={() => p.onAgregarItem('8', 2, 500)}>Editar carrito</button>
      <button type="button" onClick={() => p.onFechaChange('2026-01-15')}>Pedido de otro día</button>
      <button type="button" onClick={() => p.onEstadoPagoChange('pagado')}>Pagado</button>
      <button type="button" onClick={() => { p.onEstadoPagoChange('parcial'); p.onMontoPagadoChange(20000) }}>Parcial 20000</button>
      <button type="button" onClick={() => p.onGuardar()}>Confirmar</button>
    </>
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

beforeEach(() => {
  vi.clearAllMocks()
  clientesOperativosMock.valor = []
  rpc.mockResolvedValue({ data: { success: true }, error: null })
  registrarPago.mockResolvedValue(undefined)
  mutateAlta.mockResolvedValue({ id: '9' })
})

async function abrirYArmar() {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
  await user.click(await screen.findByRole('button', { name: 'Armar' }))
  return user
}

describe('PedidosContainer — la clave del alta sigue al contenido', () => {
  it('un reintento sin editar reusa la clave: el servidor lo reconoce', async () => {
    mutateAlta.mockRejectedValueOnce(new Error('Sin conexión')).mockResolvedValue({ id: '9' })
    const user = await abrirYArmar()

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))

    const [a, b] = mutateAlta.mock.calls.map(c => c[0].offlineId)
    expect(a).toBeTruthy()
    expect(b).toBe(a)
  })

  it('si el usuario edita el carrito entre un intento y el otro, la clave cambia', async () => {
    mutateAlta.mockRejectedValueOnce(new Error('Sin conexión')).mockResolvedValue({ id: '9' })
    const user = await abrirYArmar()

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    await user.click(screen.getByRole('button', { name: 'Editar carrito' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))

    const [a, b] = mutateAlta.mock.calls.map(c => c[0].offlineId)
    expect(a).toBeTruthy()
    expect(b).toBeTruthy()
    expect(b).not.toBe(a)
  })
})
