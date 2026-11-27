/**
 * Tanda 6 de #1603, tarjeta E: lo que cambia en `PedidosContainer`.
 *
 *  - frv-B1: «Nuevo pedido» abre con la fecha de hoy aunque la pantalla estuviera abierta de ayer.
 *  - FRV-2: el cliente del alta rápida queda asignado al preventista que lo crea.
 *  - FRV-3: el aviso de cancelar un pedido cobrado dice lo que pasa hoy con el cobro.
 *  - INF-1: abrir el alta o la edición relee el catálogo si su copia tiene más de un minuto.
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.altaClave.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { rpc, supabaseStub, notify, hoy, auth, crearCliente, productosQuery, refetchProductos } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    rpc: rpcFn,
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    hoy: { valor: '2026-11-23' },
    auth: {
      valor: {
        isAdmin: false, isEncargado: false, isPreventista: true, isTransportista: false, isDeposito: false,
        isOnline: true, authReady: true,
        user: { id: 'prev-1' }, perfil: { id: 'prev-1', rol: 'preventista' },
      } as Record<string, unknown>,
    },
    crearCliente: vi.fn(),
    refetchProductos: vi.fn(),
    productosQuery: { dataUpdatedAt: 0 },
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

vi.mock('../../utils/formatters', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  fechaLocalISO: () => hoy.valor,
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

const PEDIDO = {
  id: 42, cliente_id: '9', estado: 'pendiente', total: 1000, monto_pagado: 0, items: [],
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
}
const PEDIDO_COBRADO = { ...PEDIDO, id: 43, monto_pagado: 400 }

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({ data: { pedidos: [PEDIDO, PEDIDO_COBRADO], total: 2, totalPages: 1 }, isLoading: false, isFetching: false }),
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
  useProductosQuery: () => ({ ...emptyQuery, refetch: refetchProductos, dataUpdatedAt: productosQuery.dataUpdatedAt }),
  useTransportistasQuery: () => emptyQuery,
  useUsuariosQuery: () => emptyQuery,
  useCrearClienteMutation: () => ({ mutateAsync: crearCliente, mutate: vi.fn(), isPending: false }),
  useActualizarClienteMutation: () => emptyMutation,
  useDepositoCoords: () => ({ data: null }),
  useDestinoCoords: () => ({ data: null }),
  useCrearPedidoCambioEnRutaMutation: () => emptyMutation,
  useAplicarCambioParadaMutation: () => emptyMutation,
  useZonasEstandarizadasQuery: () => emptyQuery,
}))

vi.mock('../../hooks/queries/useRecorridoActivoQuery', () => ({ useRecorridoActivoQuery: () => ({ data: null }) }))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({
    politicas: { montoMinimoPedido: 0, modoMinimoPedido: 'cargo', montoEnvioGratis: 0, cargoEnvioPedido: 0 },
  }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => auth.valor }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => notify }))
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
  usePromocionPedido: () => ({
    datosPrecio: { cargando: [], fallaron: [], sinSenal: [] }, entradasDatosPrecio: [], reintentarDatosPrecio: () => {},
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
    itemsConDescuentoCliente: [], totalConDescuentoCliente: 0,
    combos: [], combosAplicados: [], lineasConCombos: [], totalConCombos: 0, ahorroCombos: 0,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

vi.mock('../vistas/VistaPedidos', () => ({
  default: (p: {
    onNuevoPedido?: () => void
    onEditarPedido?: (p: unknown) => void
    onCancelarPedido?: (p: unknown) => void
  }) => (
    <>
      <button type="button" onClick={() => p.onNuevoPedido?.()}>Nuevo pedido</button>
      <button type="button" onClick={() => p.onEditarPedido?.(PEDIDO)}>Editar pedido</button>
      <button type="button" onClick={() => p.onCancelarPedido?.(PEDIDO_COBRADO)}>Cancelar cobrado</button>
      <button type="button" onClick={() => p.onCancelarPedido?.(PEDIDO)}>Cancelar sin cobro</button>
    </>
  ),
}))
vi.mock('../modals/ModalPedido', () => ({
  default: (p: {
    nuevoPedido: { fecha: string }
    onCrearCliente: (d: Record<string, unknown>) => Promise<unknown>
  }) => (
    <>
      <div data-testid="fecha-alta">{p.nuevoPedido.fecha}</div>
      <button
        type="button"
        onClick={() => { void p.onCrearCliente({ nombreFantasia: 'Kiosco Nuevo', direccion: 'Calle 1' }).catch(() => undefined) }}
      >
        Alta rápida
      </button>
    </>
  ),
}))
vi.mock('../modals/ModalEditarPedido', () => ({ default: () => <div>Editando</div> }))
vi.mock('../modals/ModalConfirmacion', () => ({
  default: ({ config }: { config: { mensaje: string } }) => <div data-testid="confirmacion">{config.mensaje}</div>,
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
  hoy.valor = '2026-11-23'
  productosQuery.dataUpdatedAt = 0
  auth.valor = {
    isAdmin: false, isEncargado: false, isPreventista: true, isTransportista: false, isDeposito: false,
    isOnline: true, authReady: true, user: { id: 'prev-1' }, perfil: { id: 'prev-1', rol: 'preventista' },
  }
  rpc.mockResolvedValue({ data: { success: true }, error: null })
  crearCliente.mockResolvedValue({ id: '77', nombre_fantasia: 'Kiosco Nuevo' })
})

describe('frv-B1: el alta abre con la fecha de hoy', () => {
  it('con la pantalla abierta desde ayer, «Nuevo pedido» trae la fecha de hoy', async () => {
    const user = userEvent.setup()
    montar()
    // Pasó la medianoche con /pedidos abierta.
    hoy.valor = '2026-11-24'
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await waitFor(() => expect(screen.getByTestId('fecha-alta')).toHaveTextContent('2026-11-24'))
  })
})

describe('FRV-2: el cliente del alta rápida es del preventista que lo crea', () => {
  it('un preventista lo crea asignado a él', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Alta rápida' }))
    await waitFor(() => expect(crearCliente).toHaveBeenCalledTimes(1))
    expect(crearCliente.mock.calls[0][0]).toMatchObject({ nombre_fantasia: 'Kiosco Nuevo', preventista_ids: ['prev-1'] })
  })

  it('un admin no manda asignación: queda como hoy', async () => {
    auth.valor = { ...auth.valor, isAdmin: true, isPreventista: false, user: { id: 'adm-1' }, perfil: { id: 'adm-1', rol: 'admin' } }
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Alta rápida' }))
    await waitFor(() => expect(crearCliente).toHaveBeenCalledTimes(1))
    expect(crearCliente.mock.calls[0][0]).not.toHaveProperty('preventista_ids')
  })

  it('un encargado tampoco: no actúa como preventista', async () => {
    auth.valor = { ...auth.valor, isEncargado: true, isPreventista: false, user: { id: 'enc-1' }, perfil: { id: 'enc-1', rol: 'encargado' } }
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Alta rápida' }))
    await waitFor(() => expect(crearCliente).toHaveBeenCalledTimes(1))
    expect(crearCliente.mock.calls[0][0]).not.toHaveProperty('preventista_ids')
  })
})

describe('FRV-3: el aviso de cancelar un pedido cobrado dice lo que pasa con el cobro', () => {
  it('el cobro queda como saldo a favor y paga las otras boletas; ya no manda a «Ver/Anular Pagos»', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Cancelar cobrado' }))
    const aviso = await screen.findByTestId('confirmacion')
    expect(aviso).toHaveTextContent(/saldo a favor del cliente/)
    expect(aviso).toHaveTextContent(/otras boletas impagas/)
    expect(aviso.textContent).not.toMatch(/Ver\/Anular Pagos/)
    expect(aviso.textContent).not.toMatch(/anula los pagos/)
  })
})

describe('INF-1: abrir el alta o la edición relee un catálogo viejo', () => {
  it('«Nuevo pedido» con el catálogo de hace 5 minutos lo relee', async () => {
    productosQuery.dataUpdatedAt = Date.now() - 5 * 60 * 1000
    const user = userEvent.setup()
    montar()
    await screen.findByRole('button', { name: 'Nuevo pedido' })
    expect(refetchProductos).not.toHaveBeenCalled()
    await user.click(screen.getByRole('button', { name: 'Nuevo pedido' }))
    await waitFor(() => expect(refetchProductos).toHaveBeenCalledTimes(1))
  })

  it('editar un pedido con el catálogo viejo también lo relee', async () => {
    productosQuery.dataUpdatedAt = Date.now() - 5 * 60 * 1000
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
    await waitFor(() => expect(refetchProductos).toHaveBeenCalledTimes(1))
  })

  it('con el catálogo de hace segundos no lo relee', async () => {
    productosQuery.dataUpdatedAt = Date.now() - 5 * 1000
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await screen.findByTestId('fecha-alta')
    expect(refetchProductos).not.toHaveBeenCalled()
  })
})
