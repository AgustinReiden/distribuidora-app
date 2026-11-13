/**
 * FRV-1 y FRV-4 (#1559), del lado del container.
 *
 * FRV-1: el que arma lo que se guarda y se encola es el `usePromocionPedido` del container, no
 * el del modal. Si la consulta de escalas (o de promos, mínimos o combos) cae entre el clic y
 * el guardado, el alta no se confirma a precio de lista: el server lo aceptaría (el techo es la
 * lista de hoy).
 *
 * FRV-4: el historial del pedido mostraba «No hay cambios registrados» cuando la consulta falló
 * (`handleVerHistorial` descartaba `error`). Ahora se ve el error, con «Reintentar».
 *
 * El andamiaje de mocks es copia del de `PedidosContainer.altaClave.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, rpc, supabaseStub, registrarPago, notify, mutateAlta, datosPrecioMock, historialMock } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  // FRV-1: lo que el hook REPORTA que falta cargar. FRV-4: lo que contesta la tabla del historial.
  const datosPrecioMock = { valor: { cargando: [] as string[], fallaron: [] as string[], sinSenal: [] as string[] } }
  const historialMock = {
    historial: { data: [] as unknown[] | null, error: null as unknown },
    perfiles: { data: [] as unknown[] | null, error: null as unknown },
    consultas: 0,
  }
  return {
    datosPrecioMock,
    historialMock,
    registrarPago: vi.fn(),
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    mutateAlta: vi.fn(),
    invalidateQueries: vi.fn(),
    rpc: rpcFn,
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn((tabla: string) => {
        if (tabla === 'pedido_historial') {
          return {
            select: () => ({
              eq: () => ({
                order: () => ({
                  order: () => { historialMock.consultas++; return Promise.resolve(historialMock.historial) },
                }),
              }),
            }),
          }
        }
        if (tabla === 'perfiles') {
          return { select: () => ({ in: () => Promise.resolve(historialMock.perfiles) }) }
        }
        return { select: vi.fn(() => ({ data: [], error: null })) }
      }),
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
// El carrito: una línea de 12.000. Lo que falta cargar lo fija cada test.
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    datosPrecio: datosPrecioMock.valor, entradasDatosPrecio: [], reintentarDatosPrecio: () => {},
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

// La vista abre el alta y el historial del pedido.
vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onNuevoPedido, onVerHistorial }: { onNuevoPedido?: () => void; onVerHistorial?: (p: unknown) => void }) => (
    <>
      <button type="button" onClick={() => onNuevoPedido?.()}>Nuevo pedido</button>
      <button type="button" onClick={() => onVerHistorial?.(PEDIDO)}>Ver historial</button>
    </>
  ),
}))

vi.mock('../modals/ModalPedido', () => ({
  default: (p: {
    onClienteChange: (id: string) => void
    onAgregarItem: (id: string, cantidad?: number, precio?: number) => void
    onGuardar: () => void
  }) => (
    <>
      <button type="button" onClick={() => { p.onClienteChange('9'); p.onAgregarItem('7', 1, 12000) }}>Armar</button>
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

const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const ERROR_DE_SERVIDOR = { message: 'permission denied for table pedido_historial', details: '', hint: '', code: '42501' }

beforeEach(() => {
  vi.clearAllMocks()
  datosPrecioMock.valor = { cargando: [], fallaron: [], sinSenal: [] }
  historialMock.historial = { data: [], error: null }
  historialMock.perfiles = { data: [], error: null }
  historialMock.consultas = 0
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

describe('PedidosContainer — el alta no se confirma sin lo que arma el precio (FRV-1, #1559)', () => {
  it('con la consulta de escalas caída no manda el alta y avisa por qué', async () => {
    datosPrecioMock.valor = { cargando: [], fallaron: ['las escalas mayoristas'], sinSenal: [] }
    const user = await abrirYArmar()

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(notify.error).toHaveBeenCalled())
    expect(notify.error.mock.calls[0][0]).toMatch(/No se pudieron cargar las escalas mayoristas/)
    expect(mutateAlta).not.toHaveBeenCalled()
  })

  it('con las promos todavía cargando tampoco manda el alta', async () => {
    datosPrecioMock.valor = { cargando: ['las promociones'], fallaron: [], sinSenal: [] }
    const user = await abrirYArmar()

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(notify.error).toHaveBeenCalled())
    expect(notify.error.mock.calls[0][0]).toMatch(/Todavía se están cargando las promociones/)
    expect(mutateAlta).not.toHaveBeenCalled()
  })

  it('con todo cargado el alta se manda', async () => {
    const user = await abrirYArmar()

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    expect(notify.error).not.toHaveBeenCalled()
  })
})

describe('PedidosContainer — el historial del pedido con la consulta caída (FRV-4, #1559)', () => {
  async function abrirHistorial() {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Ver historial' }))
    return user
  }

  it('con la consulta caída muestra el error, no «No hay cambios registrados»', async () => {
    historialMock.historial = { data: null, error: ERROR_DE_RED }
    await abrirHistorial()

    const aviso = await screen.findByRole('alert')
    expect(aviso).toHaveTextContent(/Sin conexión: no se pudo cargar el historial/)
    expect(screen.queryByText(/No hay cambios registrados/)).not.toBeInTheDocument()
  })

  it('un error del servidor conserva su mensaje', async () => {
    historialMock.historial = { data: null, error: ERROR_DE_SERVIDOR }
    await abrirHistorial()

    expect(await screen.findByRole('alert')).toHaveTextContent('permission denied for table pedido_historial')
    expect(screen.queryByText(/No hay cambios registrados/)).not.toBeInTheDocument()
  })

  it('«Reintentar» vuelve a pedir el historial y, si esta vez anda, lo muestra', async () => {
    historialMock.historial = { data: null, error: ERROR_DE_RED }
    const user = await abrirHistorial()
    await screen.findByRole('alert')
    expect(historialMock.consultas).toBe(1)

    historialMock.historial = {
      data: [{ id: 1, pedido_id: 42, campo_modificado: 'notas', valor_anterior: 'a', valor_nuevo: 'b', usuario_id: null }],
      error: null,
    }
    await user.click(screen.getByRole('button', { name: 'Reintentar' }))

    await waitFor(() => expect(historialMock.consultas).toBe(2))
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
    expect(screen.queryByText(/No hay cambios registrados/)).not.toBeInTheDocument()
  })

  it('si falla la consulta de los nombres también es un error: no todo «Sistema»', async () => {
    historialMock.historial = {
      data: [{ id: 1, pedido_id: 42, campo_modificado: 'notas', valor_anterior: 'a', valor_nuevo: 'b', usuario_id: 'u7' }],
      error: null,
    }
    historialMock.perfiles = { data: null, error: ERROR_DE_RED }
    await abrirHistorial()

    expect(await screen.findByRole('alert')).toHaveTextContent(/Sin conexión: no se pudo cargar el historial/)
  })

  it('un pedido que de verdad no tiene cambios sigue diciendo que no hay', async () => {
    await abrirHistorial()

    expect(await screen.findByText(/No hay cambios registrados/)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
