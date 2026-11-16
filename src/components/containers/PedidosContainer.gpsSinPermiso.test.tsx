/**
 * #1602: el alta de un preventista con la ubicación bloqueada pide el motivo, y
 * el GPS del pedido cargado sin señal viaja con él a la cola.
 *
 * El andamiaje de mocks es el de `PedidosContainer.altaEnDuda.test.tsx`, con un
 * preventista en vez de un admin.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const {
  invalidateQueries, rpc, supabaseStub, registrarPago, notify, mutateAlta, verificarClave,
  guardarPedidoOffline, red, clientesMock, capturarGps, registrarGpsPedido,
} = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    verificarClave: vi.fn(),
    capturarGps: vi.fn(),
    registrarGpsPedido: vi.fn(),
    guardarPedidoOffline: vi.fn(),
    // `isOnline` del contexto: el segundo intento puede salir sin red.
    red: { online: true },
    clientesMock: { valor: [] as Array<Record<string, unknown>> },
    registrarPago: vi.fn(),
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    mutateAlta: vi.fn(),
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

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({ data: { pedidos: [], total: 0, totalPages: 1 }, isLoading: false, isFetching: false }),
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
  useClientesQuery: () => ({ ...emptyQuery, data: clientesMock.valor }),
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

// La pregunta al server por `pedidos.offline_id`.
vi.mock('../../hooks/queries/usePedidosQuery', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  verificarClaveDeAlta: verificarClave,
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
    isAdmin: false, isEncargado: false, isPreventista: true, isTransportista: false, isDeposito: false,
    isOnline: red.online, authReady: true,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'preventista' },
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => notify,
}))

vi.mock('../../contexts/SucursalContext', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useSucursal: () => ({ currentSucursalId: 1, sucursales: [], loading: false }),
}))
vi.mock('../../hooks/useOfflineSync', () => ({
  useOfflineSync: () => ({ isOnline: true, pendingCount: 0, guardarPedidoOffline }),
}))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
vi.mock('../../hooks/useOptimizarRuta', () => ({
  useOptimizarRuta: () => ({ optimizar: vi.fn(), optimizando: false }),
  horarioParaRutear: () => null,
}))
vi.mock('../../hooks/useRegistrarGeolocalizacionPedido', () => ({
  useRegistrarGeolocalizacionPedido: () => ({ capturarGps, registrarGpsPedido }),
}))
vi.mock('../../hooks/supabase/usePagos', () => ({
  usePagos: () => ({ registrarPago, anularPago: vi.fn(), obtenerPagosPedido: vi.fn() }),
}))
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    datosPrecio: { cargando: [], fallaron: [], sinSenal: [] }, entradasDatosPrecio: [], reintentarDatosPrecio: () => {},
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [{ productoId: '7', cantidad: 10, precioUnitario: 1000 }],
    totalFinal: 10000, totalOriginal: 10000, ahorro: 0, hayDescuento: false,
    itemsConDescuentoCliente: [], totalConDescuentoCliente: 10000,
    combos: [], combosAplicados: [],
    lineasConCombos: [{ productoId: '7', cantidad: 10, precioUnitario: 1000 }],
    totalConCombos: 10000, ahorroCombos: 0,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onNuevoPedido }: { onNuevoPedido?: () => void }) => (
    <button type="button" onClick={() => onNuevoPedido?.()}>Nuevo pedido</button>
  ),
}))

vi.mock('../modals/ModalPedido', () => ({
  default: (p: {
    onClienteChange: (id: string) => void
    onAgregarItem: (id: string, cantidad?: number, precio?: number) => void
    onNotasChange: (notas: string) => void
    onEstadoPagoChange: (e: string) => void
    onTipoFacturaChange: (t: string) => void
    onGuardar: () => void
  }) => (
    <>
      <button type="button" onClick={() => { p.onClienteChange('9'); p.onAgregarItem('7', 10, 1000) }}>Armar</button>
      <button type="button" onClick={() => p.onNotasChange('dejar en la puerta')}>Cambiar nota</button>
      <button type="button" onClick={() => p.onNotasChange('')}>Nota igual</button>
      <button type="button" onClick={() => p.onEstadoPagoChange('pagado')}>Pagado</button>
      <button type="button" onClick={() => p.onTipoFacturaChange('VB')}>Vale blanco</button>
      <button type="button" onClick={() => p.onGuardar()}>Confirmar</button>
    </>
  ),
}))

import PedidosContainer from './PedidosContainer'
import { fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

const diagnostico = { permiso: 'denied', error: 1, instalada: true, navegador: 'chrome 131', so: 'android 10' }

beforeEach(() => {
  vi.clearAllMocks()
  localStorage.clear()
  fijarUsuarioRequestIds('u1')
  red.online = true
  clientesMock.valor = []
  rpc.mockResolvedValue({ data: { success: true }, error: null })
  registrarPago.mockResolvedValue(undefined)
  mutateAlta.mockResolvedValue({ id: '600' })
  verificarClave.mockResolvedValue({ resultado: 'no_entro' })
  guardarPedidoOffline.mockResolvedValue({ success: true, pedido: { offlineId: 'op_1' } })
  registrarGpsPedido.mockResolvedValue(undefined)
})

async function confirmarCon(gps: Record<string, unknown>) {
  capturarGps.mockResolvedValue(gps)
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
  await user.click(await screen.findByRole('button', { name: 'Armar' }))
  await user.click(screen.getByRole('button', { name: 'Confirmar' }))
  await waitFor(() => expect(capturarGps).toHaveBeenCalledTimes(1))
  return user
}

describe('#1602 — el alta del preventista sin GPS', () => {
  it('con la ubicación bloqueada (denied) no crea el pedido hasta que escriba el motivo', async () => {
    const user = await confirmarCon({ status: 'denied', diagnostico })

    expect(await screen.findByText('La ubicación está bloqueada en este teléfono.')).toBeInTheDocument()
    expect(mutateAlta).not.toHaveBeenCalled()

    await user.type(screen.getByRole('textbox', { name: /Motivo/ }), 'no me deja activarla')
    await user.click(screen.getByRole('button', { name: 'Confirmar sin GPS' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(registrarGpsPedido).toHaveBeenCalledTimes(1))
    expect(registrarGpsPedido).toHaveBeenCalledWith('600', { status: 'denied', diagnostico }, 'no me deja activarla')
  })

  it('con un timeout, el motivo se puede confirmar (el alta en curso lo dejaba deshabilitado)', async () => {
    const user = await confirmarCon({ status: 'timeout', diagnostico: { ...diagnostico, permiso: 'granted', error: 3 } })
    await user.type(await screen.findByRole('textbox', { name: /Motivo/ }), 'estoy en un sótano')
    const confirmar = screen.getByRole('button', { name: 'Confirmar sin GPS' })
    expect(confirmar).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Cancelar' })).toBeEnabled()
    await user.click(confirmar)
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(registrarGpsPedido).toHaveBeenCalledWith('600', expect.objectContaining({ status: 'timeout' }), 'estoy en un sótano'))
  })

  it('cancelar el motivo no crea nada', async () => {
    const user = await confirmarCon({ status: 'denied', diagnostico })
    await screen.findByText('La ubicación está bloqueada en este teléfono.')
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))
    await waitFor(() => expect(screen.queryByText('La ubicación está bloqueada en este teléfono.')).toBeNull())
    expect(mutateAlta).not.toHaveBeenCalled()
    expect(registrarGpsPedido).not.toHaveBeenCalled()
  })

  it('con ok se crea directo y se registra el GPS', async () => {
    const gps = { status: 'ok', lat: -26.8, lng: -65.2, accuracy: 9, capturadoAt: '2026-11-15T12:00:00.000Z', diagnostico }
    await confirmarCon(gps)
    await waitFor(() => expect(registrarGpsPedido).toHaveBeenCalledWith('600', gps, undefined))
    expect(screen.queryByText('Continuar sin GPS')).toBeNull()
  })

  it('sin señal, el GPS capturado y su motivo viajan con el pedido encolado', async () => {
    red.online = false
    const user = await confirmarCon({ status: 'denied', diagnostico })
    await user.type(await screen.findByRole('textbox', { name: /Motivo/ }), 'sin permiso en el teléfono')
    await user.click(screen.getByRole('button', { name: 'Confirmar sin GPS' }))

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][0]).toMatchObject({
      gps: { status: 'denied', diagnostico },
      gpsMotivoOmision: 'sin permiso en el teléfono',
    })
    expect(mutateAlta).not.toHaveBeenCalled()
    // El registro lo hace el replay al sincronizar, no el alta.
    expect(registrarGpsPedido).not.toHaveBeenCalled()
  })

  it('sin señal y con ok, el GPS viaja sin motivo', async () => {
    red.online = false
    const gps = { status: 'ok', lat: -26.8, lng: -65.2, accuracy: 9, capturadoAt: '2026-11-15T12:00:00.000Z' }
    await confirmarCon(gps)
    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][0]).toMatchObject({ gps, gpsMotivoOmision: undefined })
  })
})
