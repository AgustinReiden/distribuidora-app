/**
 * «Confirmar entrega» y «Confirmar cambio/devolución» llevan campo de fecha (#804).
 *
 * LO QUE SE PROTEGE
 * -----------------
 * `handleMarcarEntregado` arma la confirmación con `campoFecha` porque lo
 * habitual es marcar hoy las entregas de ayer: con la fecha fija en hoy, la
 * rendición del día del reparto quedaba vacía y la del día que se cargó,
 * inflada. Pero el objeto que el container le pasa a `ModalConfirmacion` se
 * arma copiando campo por campo, y durante un tiempo se comió `campoFecha`: el
 * input no aparecía y la entrega quedaba siempre con la fecha de hoy.
 * `ModalConfirmacion` tiene sus propios tests del campo; lo que acá se fija es
 * que el CONTAINER se lo pase y que la fecha elegida llegue a `cambiarEstado`.
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.statsFiltros.test.tsx`.
 * La vista se reemplaza por dos botones que disparan `onMarcarEntregado` con un
 * pedido pagado y con una parada de cambio; la confirmación es la real.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { PedidoDB } from '../../../types'
import { fechaLocalISO } from '../../../utils/formatters'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { supabaseStub, cambiarEstado, aplicarCambioParada, PEDIDO_PAGADO, PEDIDO_CAMBIO } = vi.hoisted(() => {
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
    PEDIDO_PAGADO: {
      id: 42, cliente_id: '9', estado: 'asignado', estado_pago: 'pagado', canal: 'app', total: 1000, items: [],
      cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
    },
    PEDIDO_CAMBIO: {
      id: 77, cliente_id: '9', estado: 'asignado', estado_pago: 'pagado', canal: 'cambio', total: 0, items: [],
      cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
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

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

// Se parte del barrel real y se pisan sólo los hooks que el container usa: así
// un hook nuevo no rompe este test con "No export is defined on the mock".
vi.mock('../../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({
    data: { pedidos: [PEDIDO_PAGADO, PEDIDO_CAMBIO], total: 2, totalPages: 1 }, isLoading: false, isFetching: false,
  }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => cambiarEstado,
  useAsignarTransportistaMutation: () => emptyMutation,
  useQuitarPedidoDeRecorridosMutation: () => emptyMutation,
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
  useAplicarCambioParadaMutation: () => aplicarCambioParada,
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

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
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

// La vista: botones que hacen lo que hacen los ítems «Marcar Entregado» y
// «Marcar en Preparacion» del ⋮.
vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ onMarcarEntregado, onMarcarEnPreparacion }: {
    onMarcarEntregado: (p: PedidoDB) => void
    onMarcarEnPreparacion: (p: PedidoDB) => void
  }) => (
    <>
      <button type="button" onClick={() => onMarcarEntregado(PEDIDO_PAGADO as unknown as PedidoDB)}>
        Entregar el pagado
      </button>
      <button type="button" onClick={() => onMarcarEntregado(PEDIDO_CAMBIO as unknown as PedidoDB)}>
        Entregar el cambio
      </button>
      <button type="button" onClick={() => onMarcarEnPreparacion(PEDIDO_PAGADO as unknown as PedidoDB)}>
        Preparar el pagado
      </button>
    </>
  ),
}))

import PedidosContainer from '../PedidosContainer'

function renderContainer() {
  // Provider real para los `useQuery` sueltos que quedan sin mockear;
  // `useQueryClient` sigue devolviendo el spy (ver el mock de arriba).
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

// Cualquier día anterior a hoy sirve: el input sólo tiene `max`.
const AYER_DEL_REPARTO = '2026-01-15'

// La confirmación es lazy: la primera vez que se abre en la corrida, el import
// en frío se come casi todo el segundo por defecto de `findBy*`.
const ESPERA_MODAL = { timeout: 5000 }

beforeEach(() => {
  vi.clearAllMocks()
  cambiarEstado.mutateAsync.mockResolvedValue({})
  aplicarCambioParada.mutateAsync.mockResolvedValue({})
  supabaseStub.rpc.mockResolvedValue({ data: { success: true }, error: null })
})

describe('PedidosContainer — «Confirmar entrega» de un pedido pagado (#804)', () => {
  it('la confirmación muestra el campo de fecha, arrancando en hoy', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Entregar el pagado' }))

    expect(await screen.findByRole('dialog', { name: 'Confirmar entrega' }, ESPERA_MODAL)).toBeInTheDocument()
    const fecha = screen.getByLabelText('Fecha de entrega')
    expect(fecha).toHaveValue(fechaLocalISO())
    expect(fecha).toHaveAttribute('max', fechaLocalISO())
  })

  it('sin tocar la fecha, a cambiarEstado le llega la de hoy', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Entregar el pagado' }))
    await screen.findByLabelText('Fecha de entrega', {}, ESPERA_MODAL)
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(cambiarEstado.mutateAsync).toHaveBeenCalledTimes(1))
    expect(cambiarEstado.mutateAsync).toHaveBeenCalledWith({
      pedidoId: 42, nuevoEstado: 'entregado', fechaEntrega: fechaLocalISO(),
    })
  })

  it('la fecha elegida llega a cambiarEstado', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Entregar el pagado' }))
    const fecha = await screen.findByLabelText('Fecha de entrega', {}, ESPERA_MODAL)
    await user.clear(fecha)
    await user.type(fecha, AYER_DEL_REPARTO)
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(cambiarEstado.mutateAsync).toHaveBeenCalledTimes(1))
    expect(cambiarEstado.mutateAsync).toHaveBeenCalledWith({
      pedidoId: 42, nuevoEstado: 'entregado', fechaEntrega: AYER_DEL_REPARTO,
    })
  })
})

describe('PedidosContainer — «Confirmar cambio/devolución» de una parada de cambio (#804)', () => {
  it('la confirmación muestra el campo de fecha y la fecha elegida llega a cambiarEstado', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Entregar el cambio' }))

    expect(await screen.findByRole('dialog', { name: 'Confirmar cambio/devolución' }, ESPERA_MODAL)).toBeInTheDocument()
    const fecha = screen.getByLabelText('Fecha de entrega')
    expect(fecha).toHaveValue(fechaLocalISO())
    await user.clear(fecha)
    await user.type(fecha, AYER_DEL_REPARTO)
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(cambiarEstado.mutateAsync).toHaveBeenCalledTimes(1))
    // El ajuste de stock y saldo va primero, y recién después se marca entregado.
    expect(aplicarCambioParada.mutateAsync).toHaveBeenCalledWith('77')
    expect(aplicarCambioParada.mutateAsync.mock.invocationCallOrder[0])
      .toBeLessThan(cambiarEstado.mutateAsync.mock.invocationCallOrder[0])
    expect(cambiarEstado.mutateAsync).toHaveBeenCalledWith({
      pedidoId: 77, nuevoEstado: 'entregado', fechaEntrega: AYER_DEL_REPARTO,
    })
  })
})

describe('PedidosContainer — las otras confirmaciones siguen sin fecha (#804)', () => {
  it('«Marcar en preparación», abierta después de cancelar una entrega, no hereda el campo', async () => {
    const user = userEvent.setup()
    renderContainer()

    await user.click(await screen.findByRole('button', { name: 'Entregar el pagado' }))
    await screen.findByLabelText('Fecha de entrega', {}, ESPERA_MODAL)
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())

    await user.click(screen.getByRole('button', { name: 'Preparar el pagado' }))
    expect(await screen.findByRole('dialog', { name: 'Marcar en preparación' }, ESPERA_MODAL)).toBeInTheDocument()
    expect(screen.queryByLabelText('Fecha de entrega')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(cambiarEstado.mutateAsync).toHaveBeenCalledTimes(1))
    expect(cambiarEstado.mutateAsync).toHaveBeenCalledWith({ pedidoId: 42, nuevoEstado: 'en_preparacion' })
  })
})
