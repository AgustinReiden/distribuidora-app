/**
 * «Entregar y registrar pago» cuando el cobro falla DESPUÉS de marcar la entrega (#1598-b11).
 *
 * LO QUE SE PROTEGE
 * -----------------
 * `handleEntregarConPago` hace dos cosas en orden: primero marca el pedido entregado (la más
 * crítica) y recién después registra el cobro. Si el cobro falla, el pedido YA quedó entregado
 * y la pantalla tiene que decirlo con un aviso que no se va solo y que nombre el pedido
 * (`avisoEntregaConPagoFallido`), cerrar el modal sin dejar el pedido «a medio cobrar» en el
 * estado, y NO anunciar «Pedido entregado y pago registrado». Si la que falla es la entrega,
 * el cobro ni se intenta (no se cobra un pedido que no salió).
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.pagosPreviosFallaron.test.tsx`: la
 * vista es un botón que dispara `onMarcarEntregado`; el modal de pago y el container son los reales.
 */
import React from 'react'
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { PedidoDB } from '../../../types'
import { avisoEntregaConPagoFallido } from '../../../utils/avisoEntregaConPagoFallido'
import { fechaLocalISO } from '../../../utils/formatters'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { supabaseStub, cambiarEstado, aplicarCambioParada, notifyMock, fetchPagosPedido, registrarPagosBatch, PEDIDO, CHOFERES } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      },
    },
    cambiarEstado: { mutateAsync: vi.fn(), mutate: vi.fn(), isPending: false },
    aplicarCambioParada: { mutateAsync: vi.fn(), mutate: vi.fn(), isPending: false },
    notifyMock: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    fetchPagosPedido: vi.fn(),
    registrarPagosBatch: vi.fn(),
    PEDIDO: {
      id: 42, cliente_id: '9', estado: 'asignado', estado_pago: 'pendiente', canal: 'app', total: 1000, items: [],
      transportista_id: 't-1',
      cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
    },
    CHOFERES: [{ id: 't-1', nombre: 'Chofer Uno', rol: 'transportista' }],
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
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => cambiarEstado,
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
  useTransportistasQuery: () => ({ ...emptyQuery, data: CHOFERES }),
  useUsuariosQuery: () => emptyQuery,
  useCrearClienteMutation: () => emptyMutation,
  useActualizarClienteMutation: () => emptyMutation,
  useDepositoCoords: () => ({ data: null }),
  useDestinoCoords: () => ({ data: null }),
  useCrearPedidoCambioEnRutaMutation: () => emptyMutation,
  useAplicarCambioParadaMutation: () => aplicarCambioParada,
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
    registrarPago: vi.fn(), anularPago: vi.fn(), obtenerPagosPedido: vi.fn(), fetchPagosPedido, registrarPagosBatch,
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

// La vista: un botón que dispara «Marcar Entregado» de la boleta.
vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ onMarcarEntregado }: { onMarcarEntregado: (p: PedidoDB) => void }) => (
    <button type="button" onClick={() => onMarcarEntregado(PEDIDO as unknown as PedidoDB)}>
      Entregar la boleta
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

// El modal de pago es lazy: el import en frío se come casi todo el segundo por defecto de `findBy*`.
const ESPERA_MODAL = { timeout: 5000 }

// El import en frío del modal, con la suite entera y la máquina cargada, pasa de los 5 s de arriba (#1587): se resuelve antes de
// todo, con margen propio, y los `findBy` sólo esperan el render.
beforeAll(async () => {
  await import('../../modals/ModalPagoPedido')
}, 120_000)

/** Abre el modal de la boleta y toca «Entregar y registrar pago» con el monto que el modal propone (el total). */
async function entregarYRegistrarPago() {
  fireEvent.click(await screen.findByRole('button', { name: 'Entregar la boleta' }))
  const boton = await screen.findByRole('button', { name: /^entregar y registrar pago$/i }, ESPERA_MODAL)
  // El modal propone el saldo entero como monto del cobro.
  await waitFor(() => expect((screen.getAllByPlaceholderText(/0[.,]00/i)[0] as HTMLInputElement).value).toBe('1.000'))
  fireEvent.click(boton)
}

beforeEach(() => {
  vi.clearAllMocks()
  fetchPagosPedido.mockReset()
  fetchPagosPedido.mockResolvedValue([])
  registrarPagosBatch.mockReset()
  cambiarEstado.mutateAsync.mockReset()
  cambiarEstado.mutateAsync.mockResolvedValue({})
  supabaseStub.rpc.mockImplementation(() => Promise.resolve({ data: { success: true }, error: null }))
})

describe('PedidosContainer — «Entregar y registrar pago» con el cobro caído (#1598-b11)', () => {
  it('la entrega ya está marcada: avisa con un cartel fijo que nombra el pedido, cierra el modal y no dice que se cobró', async () => {
    registrarPagosBatch.mockRejectedValue(new Error('Sin conexión'))
    renderContainer()

    await entregarYRegistrarPago()

    // Primero la entrega, con la fecha del cobro; después el intento de cobro.
    await waitFor(() => expect(cambiarEstado.mutateAsync).toHaveBeenCalledTimes(1))
    expect(cambiarEstado.mutateAsync).toHaveBeenCalledWith(
      expect.objectContaining({ pedidoId: 42, nuevoEstado: 'entregado', fechaEntrega: fechaLocalISO() }),
    )
    await waitFor(() => expect(registrarPagosBatch).toHaveBeenCalledTimes(1))
    expect(cambiarEstado.mutateAsync.mock.invocationCallOrder[0])
      .toBeLessThan(registrarPagosBatch.mock.invocationCallOrder[0])

    // El aviso es fijo (no se va solo) y dice que el pedido SÍ se entregó y que falta el cobro.
    await waitFor(() => expect(notifyMock.error).toHaveBeenCalledWith(
      avisoEntregaConPagoFallido(42, 'Sin conexión'),
      { persist: true },
    ))
    expect(notifyMock.error.mock.calls[0][0]).toMatch(/se entregó, pero falló el pago/)

    // El modal se cierra, y nadie dice «entregado y pago registrado».
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(notifyMock.success).not.toHaveBeenCalled()
  })

  it('si lo que falla es la entrega, el cobro ni se intenta y el modal sigue abierto', async () => {
    cambiarEstado.mutateAsync.mockRejectedValue(new Error('La caja del día está cerrada'))
    renderContainer()

    await entregarYRegistrarPago()

    await waitFor(() => expect(notifyMock.error).toHaveBeenCalledWith('La caja del día está cerrada'))
    expect(registrarPagosBatch).not.toHaveBeenCalled()
    expect(notifyMock.success).not.toHaveBeenCalled()
    // No es el caso «entregado sin cobro»: no se muestra el cartel fijo.
    expect(notifyMock.error).not.toHaveBeenCalledWith(expect.stringMatching(/se entregó, pero falló el pago/), expect.anything())
    expect(screen.getByRole('dialog')).toBeInTheDocument()
  })

  it('control: si el cobro entra, dice «Pedido entregado y pago registrado» y no hay cartel de falla', async () => {
    registrarPagosBatch.mockResolvedValue({ idempotentReplay: false })
    renderContainer()

    await entregarYRegistrarPago()

    await waitFor(() => expect(notifyMock.success).toHaveBeenCalledWith('Pedido entregado y pago registrado'))
    expect(notifyMock.error).not.toHaveBeenCalled()
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
  })
})
