/**
 * Cambiarle la fecha a un pedido en camino lo devuelve a pendiente en una sola
 * RPC (#1372), y desde #1440 (punto 5) la fecha y las notas viajan en esa misma.
 *
 * EL HUECO
 * --------
 * `handleGuardarEdicion` hacía tres llamadas sueltas: chofer por REST, estado
 * por REST y `quitar_pedido_de_recorridos_activos`, que es sólo de admin y
 * encargado. El preventista dueño, que sí puede editar las fechas de su pedido,
 * lo dejaba pendiente, sin chofer y con la parada viva en la ruta. #1372 lo dejó
 * en dos: la vuelta a pendiente y después el PATCH de fecha y notas. Si fallaba
 * el PATCH, el pedido quedaba fuera de la ruta con la fecha vieja, y la versión
 * de #1323 en null: el próximo guardado de líneas iba sin concurrencia optimista.
 *
 * Se monta el container con la vista y el modal stubbeados: lo que se prueba es
 * el cableado del handler, no la pantalla.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { supabaseStub, updatePedido, cambiarEstado, avisos, pedidoActual, datosGuardado } = vi.hoisted(() => {
  const update = vi.fn(() => ({ eq: vi.fn(() => Promise.resolve({ error: null })) }))
  return {
    updatePedido: update,
    cambiarEstado: vi.fn().mockResolvedValue({}),
    avisos: { warning: vi.fn(), success: vi.fn(), error: vi.fn(), info: vi.fn() },
    pedidoActual: { valor: null as Record<string, unknown> | null },
    datosGuardado: { valor: {} as Record<string, unknown> },
    supabaseStub: {
      rpc: vi.fn(),
      from: vi.fn(() => ({ update, select: vi.fn(() => ({ data: [], error: null })) })),
      auth: {
        getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
        onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
      },
    },
  }
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
  usePedidosPaginatedQuery: () => ({
    data: { pedidos: [pedidoActual.valor], total: 1, totalPages: 1 }, isLoading: false, isFetching: false,
  }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
  useCambiarEstadoMutation: () => ({ ...emptyMutation, mutateAsync: cambiarEstado }),
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

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: false, isEncargado: false, isPreventista: true, isTransportista: false, isDeposito: false,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'preventista' },
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => avisos }))

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
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onEditarPedido }: { onEditarPedido?: (p: unknown) => void }) => (
    <button type="button" onClick={() => onEditarPedido?.(pedidoActual.valor)}>Editar pedido</button>
  ),
}))

vi.mock('../modals/ModalEditarPedido', () => ({
  default: ({ onSave, onSaveItems }: {
    onSave?: (data: Record<string, unknown>) => Promise<void>
    onSaveItems?: (items: unknown[]) => Promise<void>
  }) => (
    <>
      <button type="button" onClick={() => void onSave?.(datosGuardado.valor)}>Guardar edición</button>
      <button type="button" onClick={() => void onSaveItems?.([]).catch(() => {})}>Guardar líneas</button>
    </>
  ),
}))

import PedidosContainer from './PedidosContainer'

const V1 = '2026-11-04T13:00:00.123456+00:00'
const V2 = '2026-11-04T13:05:00.654321+00:00'

const PEDIDO_EN_CAMINO = {
  id: 42,
  cliente_id: '9',
  estado: 'asignado',
  transportista_id: 'chofer-1',
  fecha: '2026-11-02',
  fecha_entrega_programada: '2026-11-02',
  usuario_id: 'u1',
  total: 1000,
  items: [],
  updated_at: V1,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur' },
}

async function abrirEdicion() {
  const user = userEvent.setup()
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <PedidosContainer />
      </MemoryRouter>
    </QueryClientProvider>,
  )
  await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
  return user
}

async function guardarEdicion() {
  const user = await abrirEdicion()
  await user.click(await screen.findByRole('button', { name: 'Guardar edición' }))
  return user
}

const llamadas = (fn: string) => supabaseStub.rpc.mock.calls.filter(([f]) => f === fn)
const guardadoEnUnPaso = () => llamadas('actualizar_fechas_y_notas_pedido')

// La respuesta del server a la edición: si el pedido volvió a pendiente, con la
// versión de antes y la nueva.
const respuesta = (vuelto: boolean) => ({
  data: { success: true, vuelto_a_pendiente: vuelto, updated_at_anterior: V1, updated_at: vuelto ? V2 : V1 },
  error: null,
})

beforeEach(() => {
  vi.clearAllMocks()
  supabaseStub.rpc.mockImplementation((fn: string) => Promise.resolve(
    fn === 'actualizar_fechas_y_notas_pedido'
      ? respuesta(true)
      : { data: { success: true, updated_at: V2 }, error: null },
  ))
  pedidoActual.valor = PEDIDO_EN_CAMINO
  datosGuardado.valor = { notas: '', fechaEntregaProgramada: '2026-11-05' }
})

describe('PedidosContainer — cambiarle la fecha a un pedido en camino (#1372, #1440)', () => {
  it('fecha, notas y la vuelta a pendiente van en una sola RPC, sin PATCH aparte', async () => {
    await guardarEdicion()

    await waitFor(() => expect(guardadoEnUnPaso()).toHaveLength(1))
    expect(supabaseStub.rpc).toHaveBeenCalledWith('actualizar_fechas_y_notas_pedido', {
      p_pedido_id: 42,
      p_notas: '',
      p_fecha: null,
      p_fecha_entrega: null,
      p_fecha_entrega_programada: '2026-11-05',
    })
    expect(updatePedido).not.toHaveBeenCalled()
    expect(llamadas('volver_pedido_a_pendiente_por_edicion')).toHaveLength(0)
    expect(cambiarEstado).not.toHaveBeenCalled()
    expect(supabaseStub.rpc).not.toHaveBeenCalledWith('quitar_pedido_de_recorridos_activos', expect.anything())
    await waitFor(() => expect(avisos.warning).toHaveBeenCalledWith(expect.stringContaining('volvió a pendiente')))
  })

  it('la fecha de entrega viaja como mediodía UTC, igual que el PATCH de antes', async () => {
    datosGuardado.valor = { notas: 'x', fecha: '2026-11-03', fechaEntrega: '2026-11-04' }

    await guardarEdicion()

    await waitFor(() => expect(guardadoEnUnPaso()).toHaveLength(1))
    expect(guardadoEnUnPaso()[0][1]).toMatchObject({
      p_fecha: '2026-11-03', p_fecha_entrega: '2026-11-04T12:00:00Z', p_fecha_entrega_programada: null,
    })
  })

  it('si la RPC rechaza, avisa el error y no dice que quedó actualizado', async () => {
    supabaseStub.rpc.mockResolvedValue({
      data: null,
      error: { message: 'Como preventista sólo podés cambiar pedidos del día actual antes de las 15:30', code: '42501' },
    })

    await guardarEdicion()

    await waitFor(() => expect(avisos.error).toHaveBeenCalledWith(expect.stringContaining('antes de las 15:30')))
    expect(updatePedido).not.toHaveBeenCalled()
    expect(avisos.warning).not.toHaveBeenCalled()
    expect(avisos.success).not.toHaveBeenCalled()
  })

  it('si el server no lo devolvió a pendiente, avisa que quedó actualizado', async () => {
    supabaseStub.rpc.mockImplementation(() => Promise.resolve(respuesta(false)))
    datosGuardado.valor = { notas: 'tocar timbre', fechaEntregaProgramada: '2026-11-02' }

    await guardarEdicion()

    await waitFor(() => expect(avisos.success).toHaveBeenCalledWith('Pedido actualizado'))
    expect(avisos.warning).not.toHaveBeenCalled()
  })

  it('#1323: si la RPC falla, el próximo guardado de líneas del mismo modal sigue con la versión', async () => {
    supabaseStub.rpc.mockImplementation((fn: string) => Promise.resolve(
      fn === 'actualizar_fechas_y_notas_pedido'
        ? { data: null, error: { message: 'La rendición del 02/11/2026 de ese transportista ya fue controlada', code: '42501' } }
        : { data: { success: true, updated_at: V2 }, error: null },
    ))

    const user = await guardarEdicion()
    await waitFor(() => expect(avisos.error).toHaveBeenCalled())
    await user.click(screen.getByRole('button', { name: 'Guardar líneas' }))

    await waitFor(() => expect(llamadas('actualizar_pedido_items')).toHaveLength(1))
    expect(llamadas('actualizar_pedido_items')[0][1]).toMatchObject({ p_updated_at_esperado: V1 })
  })
})
