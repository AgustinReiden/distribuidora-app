/**
 * Cargo de envío en el cobro del alta.
 *
 * `crear_pedido_completo` guarda `total = productos + cargo` pero el carrito
 * manda sólo el total de productos. El cobro "pagado" del alta registraba ese
 * total pelado, y el pedido quedaba parcial debiendo el envío. El cobro tiene que
 * seguir al cargo que DEVUELVE el servidor, y avisar si difiere del mostrado.
 *
 * Se monta el container con la vista y el modal stubbeados: lo que se prueba es
 * el cableado del handler de guardado.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, rpc, supabaseStub, registrarPago, notify, mutateAlta, politicasMock } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
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
    onGuardar: () => void
  }) => (
    <>
      <button type="button" onClick={() => { p.onClienteChange('9'); p.onAgregarItem('7', 1, 12000) }}>Armar</button>
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

async function altaCon(acciones: string[]) {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
  await user.click(await screen.findByRole('button', { name: 'Armar' }))
  for (const a of acciones) await user.click(screen.getByRole('button', { name: a }))
  await user.click(screen.getByRole('button', { name: 'Confirmar' }))
}

beforeEach(() => {
  vi.clearAllMocks()
  rpc.mockResolvedValue({ data: { success: true }, error: null })
  registrarPago.mockResolvedValue(undefined)
  mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500 })
})

describe('PedidosContainer — cobro del alta con cargo de envío', () => {
  it('alta pagada registra el pago por productos + cargo devuelto por el server', async () => {
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ pedidoId: '9', monto: 12500 })
    // El carrito mostraba el mismo envío: nada que avisar.
    expect(notify.warning).not.toHaveBeenCalled()
  })

  it('una respuesta sin cargo (server anterior) cobra sólo los productos y no avisa', async () => {
    mutateAlta.mockResolvedValue({ id: '9' })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12000 })
    expect(notify.warning).not.toHaveBeenCalled()
  })

  it('el pago parcial no pasa del total que guardó el server', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500 })
    await altaCon(['Parcial 20000'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12500 })
  })

  it('si el cargo del server difiere del mostrado avisa', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 800 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.warning).toHaveBeenCalled())
    const texto = String(notify.warning.mock.calls[0][0])
    expect(texto).toMatch(/envío/i)
    expect(texto).toMatch(/800/)
    expect(texto).toMatch(/500/)
    // Y el cobro sigue al server, no al carrito.
    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12800 })
  })

  it('si el server no cobra envío y el carrito lo mostraba, avisa que no lleva', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 0 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.warning).toHaveBeenCalled())
    expect(String(notify.warning.mock.calls[0][0])).toContain('El pedido #9 no lleva envío')
    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12000 })
  })
})
