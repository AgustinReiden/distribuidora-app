/**
 * FRT-2 (#1517): cobrar o registrar una salvedad desde Pedidos mueve el saldo del
 * cliente, pero los handlers sólo invalidaban `['pedidos']` (y `['productos']`).
 * El alta siguiente del mismo cliente avisaba una deuda que ya no existía, y ese
 * aviso es el que evita cobrar de más (#1503, #1509).
 *
 * El andamiaje de mocks es copia, recortada, del de
 * `PedidosContainer.pagosPreviosFallaron.test.tsx`. La vista y los dos modales se
 * reemplazan por botones que disparan los handlers del container.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, supabaseStub, registrarPagosBatch, fetchPagosPedido, eliminarPago, notifyMock, PEDIDO, PEDIDO_IMPAGO } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    invalidateQueries: vi.fn(),
    registrarPagosBatch: vi.fn(),
    fetchPagosPedido: vi.fn(),
    eliminarPago: vi.fn(),
    notifyMock: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    PEDIDO: {
      id: 42, cliente_id: '9', estado: 'entregado', total: 1000, monto_pagado: 0, items: [],
      cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
    },
    // Una entrega con saldo: abre el modal de pago en modo entrega.
    PEDIDO_IMPAGO: {
      id: 43, cliente_id: '9', estado: 'asignado', estado_pago: 'pendiente', canal: 'app', total: 1000, monto_pagado: 0, items: [],
      transportista_id: 't-1',
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
    isError: false, error: null,
  }),
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
  useFechasMinimasPorCobrador: () => new Map(),
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
    registrarPago: vi.fn(), registrarPagosBatch, anularPago: vi.fn(), obtenerPagosPedido: vi.fn(), fetchPagosPedido, eliminarPago,
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

// La vista abre cada modal; los modales confirman con un payload mínimo.
vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ onAbrirPagoPedido, onMarcarEntregadoConSalvedad, onMarcarEntregado }: {
    onAbrirPagoPedido: (p: unknown) => void
    onMarcarEntregadoConSalvedad: (p: unknown) => void
    onMarcarEntregado: (p: unknown) => void
  }) => (
    <>
      <button type="button" onClick={() => onAbrirPagoPedido(PEDIDO)}>Cobrar</button>
      <button type="button" onClick={() => onMarcarEntregado(PEDIDO_IMPAGO)}>Entregar impago</button>
      <button type="button" onClick={() => onMarcarEntregadoConSalvedad(PEDIDO)}>Salvedad</button>
    </>
  ),
}))
vi.mock('../../modals/ModalPagoPedido', () => ({
  default: ({ onConfirmar, onAnularPago }: { onConfirmar: (payload: unknown) => Promise<void>; onAnularPago?: (id: string) => Promise<void> }) => (
    <>
      <button
        type="button"
        onClick={() => void onConfirmar({
          pedidoId: '42', clienteId: '9', fechaPago: '2026-11-10', pagadoAntes: 0,
          pagos: [{ formaPago: 'efectivo', monto: 500 }], clientRequestIds: ['req-1'],
        })}
      >
        Confirmar cobro
      </button>
      <button type="button" onClick={() => void onAnularPago?.('5')}>Anular pago</button>
    </>
  ),
}))
vi.mock('../../modals/ModalEntregaConSalvedad', () => ({
  default: ({ onSave }: { onSave: (s: unknown[]) => Promise<unknown> }) => (
    <button
      type="button"
      onClick={() => void onSave([{
        pedidoId: '42', pedidoItemId: '1', cantidadAfectada: 1, motivo: 'rechazo', devolverStock: true,
        clientRequestId: 'sal-1',
      }])}
    >
      Guardar salvedad
    </button>
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

// Los modales son lazy: el import en frío se come casi todo el segundo de `findBy*`.
const ESPERA_MODAL = { timeout: 5000 }

function invalidoClientes() {
  return invalidateQueries.mock.calls.some(([arg]) => {
    const key = (arg as { queryKey?: unknown[] } | undefined)?.queryKey
    return Array.isArray(key) && key[0] === 'clientes'
  })
}

beforeEach(() => {
  vi.clearAllMocks()
  fetchPagosPedido.mockResolvedValue([])
  registrarPagosBatch.mockResolvedValue({ idempotentReplay: false })
  supabaseStub.rpc.mockImplementation(() => Promise.resolve({ data: { success: true }, error: null }))
})

describe('PedidosContainer — el saldo del cliente se entera (FRT-2)', () => {
  it('registrar un cobro invalida los clientes', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Cobrar' }))
    await user.click(await screen.findByRole('button', { name: 'Confirmar cobro' }, ESPERA_MODAL))

    await waitFor(() => expect(registrarPagosBatch).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(notifyMock.success).toHaveBeenCalledWith('Pago registrado'))
    expect(invalidoClientes()).toBe(true)
  })

  it('registrar una salvedad invalida los clientes', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Salvedad' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar salvedad' }, ESPERA_MODAL))

    await waitFor(() => expect(supabaseStub.rpc).toHaveBeenCalledWith('registrar_salvedad', expect.anything()))
    await waitFor(() => expect(invalidoClientes()).toBe(true))
  })

  // H5 (lente B10): «Entregar y registrar pago» no invalidaba los clientes ni el recorrido DESPUÉS
  // del cobro: el saldo del cliente quedaba viejo y el recorrido se refrescaba antes de que entrara el pago.
  it('entregar y registrar pago invalida clientes y la hoja de ruta después del cobro', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Entregar impago' }))
    await user.click(await screen.findByRole('button', { name: 'Confirmar cobro' }, ESPERA_MODAL))

    await waitFor(() => expect(registrarPagosBatch).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(notifyMock.success).toHaveBeenCalledWith('Pedido entregado y pago registrado'))
    const ordenCobro = registrarPagosBatch.mock.invocationCallOrder[0]
    const despuesDelCobro = (clave: string) => invalidateQueries.mock.calls.some(([arg], i) => {
      const key = (arg as { queryKey?: unknown[] } | undefined)?.queryKey
      return Array.isArray(key) && key[0] === clave && invalidateQueries.mock.invocationCallOrder[i] > ordenCobro
    })
    expect(despuesDelCobro('clientes')).toBe(true)
    // `['recorridos']` es una clave muerta (clavesMuertas.contract): la viva es la de la hoja de ruta.
    expect(despuesDelCobro('recorridos-hoja-ruta')).toBe(true)
    expect(despuesDelCobro('recorrido-activo')).toBe(true)
  })

  // H6 (lente B10): si el DELETE no borró ninguna fila (1559-b13) se avisa, pero la lista del modal
  // seguía mostrando el pago que ya no existe.
  it('si anular un pago falla, la lista de pagos del modal se vuelve a leer', async () => {
    eliminarPago.mockRejectedValue(new Error('No se anuló ningún pago: ya no existe o no tenés permiso para anularlo.'))
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Cobrar' }))
    await user.click(await screen.findByRole('button', { name: 'Anular pago' }, ESPERA_MODAL))
    await waitFor(() => expect(notifyMock.error).toHaveBeenCalledWith(expect.stringMatching(/No se anuló ningún pago/)))
    const lecturasAlAbrir = 1
    await waitFor(() => expect(fetchPagosPedido.mock.calls.length).toBeGreaterThan(lecturasAlAbrir))
  })

  // 1543-b4: una salvedad sobre un regalo libera su cupo de promo.
  it('registrar una salvedad invalida los cupos de promo', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Salvedad' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar salvedad' }, ESPERA_MODAL))

    await waitFor(() => expect(supabaseStub.rpc).toHaveBeenCalledWith('registrar_salvedad', expect.anything()))
    await waitFor(() => {
      const cupos = invalidateQueries.mock.calls
        .map(([arg]) => arg as { queryKey?: unknown[]; predicate?: (q: { queryKey: unknown[] }) => boolean })
        .filter(a => a.queryKey?.[0] === 'promociones')
      expect(cupos).toHaveLength(1)
      expect(cupos[0].predicate?.({ queryKey: ['promociones', 1, 'cupos', null] })).toBe(true)
    })
  })
})
