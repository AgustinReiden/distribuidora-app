/**
 * «Dividir ruta»: lo que el optimizador deja afuera (#1549, FRT-05 y B9).
 *
 * EL HUECO (FRT-05)
 * -----------------
 * Todo pedido seleccionado que el optimizador no ruteaba se repartía de a uno por chofer
 * (a turnos, o por zona preferida) ignorando `max_paradas`, también los que volvían en
 * `skipped` por falta de cupo. El aviso decía «por falta de coordenadas» (falso: tienen) y
 * el resultado, «no se pudieron asignar (capacidad)» (falso: ya estaban asignados). Hoy
 * los sin coordenadas se siguen repartiendo; los `skipped` entran sólo hasta el cupo que
 * le queda a cada chofer y el resto queda sin asignar, con un aviso que lo dice.
 *
 * B9: si `aplicar_orden_ruta` fallaba en el 2.º chofer, las invalidaciones (después del
 * bucle, dentro del `try`) no corrían: la pantalla seguía con la lista de antes aunque el
 * 1.º ya estuviera armado.
 *
 * El optimizador de Google no se puede ejecutar acá: `optimizarRutaMulti` devuelve
 * respuestas simuladas con la forma de la edge function `optimizar-ruta`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { rpc, supabaseStub, invalidar, notify, optimizarRutaMulti, falla } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    rpc: rpcFn,
    invalidar: vi.fn(),
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    optimizarRutaMulti: vi.fn(),
    // Choferes cuyo aplicar_orden_ruta falla.
    falla: { choferes: new Set<string>() },
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

// El cliente tiene que ser estable: el container lo mete en las deps de sus handlers.
vi.mock('@tanstack/react-query', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@tanstack/react-query')>()
  const cliente = { invalidateQueries: invalidar, setQueryData: vi.fn(), getQueryData: vi.fn() }
  return { ...actual, useQueryClient: () => cliente }
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

vi.mock('../../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({ data: { pedidos: [PEDIDO], total: 1, totalPages: 1 }, isLoading: false, isFetching: false }),
  usePedidoStatsQuery: () => ({ data: undefined, isLoading: false }),
  EMPTY_PEDIDO_STATS_SUMMARY: {},
  useCrearPedidoMutation: () => emptyMutation,
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

vi.mock('../../../hooks/queries/useRecorridoActivoQuery', () => ({
  useRecorridoActivoQuery: () => ({ data: null }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'admin' },
  }),
}))

// El objeto tiene que ser estable: el container lo mete en las deps de sus handlers.
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
    optimizarRuta: vi.fn(), optimizarRutaMulti, setRutaOptimizada: vi.fn(), limpiarRuta: vi.fn(),
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
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [], totalFinal: 0, totalOriginal: 0, ahorro: 0, hayDescuento: false,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

vi.mock('../../vistas/VistaPedidos', () => ({
  default: ({ onOptimizarRuta }: { onOptimizarRuta?: () => void }) => (
    <button type="button" onClick={() => onOptimizarRuta?.()}>Armar ruta</button>
  ),
}))

// La selección y los choferes los pone el test (`escenario`): el modal real no se monta.
type Repartidor = { transportista_id: string; max_paradas?: number | null; zonas_preferidas?: number[] | null }
const escenario: { repartidores: Repartidor[]; pedidos: unknown[] } = { repartidores: [], pedidos: [] }

vi.mock('../../modals/ModalGestionRutas', () => ({
  default: ({ onArmarRutaMulti, rutaMulti }: {
    onArmarRutaMulti?: (...a: unknown[]) => Promise<void>
    rutaMulti?: { skipped: string[] } | null
  }) => (
    <div>
      <button
        type="button"
        onClick={() => void onArmarRutaMulti?.(escenario.repartidores, escenario.pedidos, '2026-11-13', '08:00', '18:00')}
      >
        Armar varios
      </button>
      <p data-testid="sin-asignar">{rutaMulti ? rutaMulti.skipped.join(',') : 'sin-resultado'}</p>
    </div>
  ),
}))

import PedidosContainer from '../PedidosContainer'

const pedidoConCoords = (id: string) => ({
  id, estado: 'en_preparacion', total: 100, items: [],
  cliente: { id: `c${id}`, nombre_fantasia: `Cliente ${id}`, latitud: -26.8, longitud: -65.2 },
})
const pedidoSinCoords = (id: string) => ({
  id, estado: 'en_preparacion', total: 100, items: [],
  cliente: { id: `c${id}`, nombre_fantasia: `Cliente ${id}` },
})

/** Respuesta simulada de la edge: los ids ruteados por chofer + los `skipped`. */
function respuestaDelOptimizador(rutas: Record<string, string[]>, skipped: string[]) {
  return {
    success: true,
    recorridos: Object.entries(rutas).map(([transportista_id, ids]) => ({
      transportista_id,
      total_pedidos: ids.length,
      orden_optimizado: ids.map((pedido_id, i) => ({ pedido_id, orden: i + 1 })),
      distancia_total: 1000, duracion_total: 600, polylines: null,
    })),
    pedidos_sin_coordenadas_ids: [],
    skipped,
  }
}

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

async function dividir() {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Armar ruta' }))
  await user.click(await screen.findByRole('button', { name: 'Armar varios' }))
}

/** Pedidos que se mandaron a `aplicar_orden_ruta`, por chofer. */
function aplicadoPorChofer(): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const [nombre, args] of rpc.mock.calls) {
    if (nombre !== 'aplicar_orden_ruta') continue
    const a = args as { p_transportista_id: string; p_pedidos: Array<{ pedido_id: string }> }
    out[a.p_transportista_id] = a.p_pedidos.map(p => p.pedido_id)
  }
  return out
}
const avisos = (): string[] => notify.warning.mock.calls.map(([m]) => String(m))
const clavesInvalidadas = (): string[] => invalidar.mock.calls.map(([f]) => JSON.stringify((f as { queryKey: unknown }).queryKey))

beforeEach(() => {
  vi.clearAllMocks()
  invalidar.mockResolvedValue(undefined)
  falla.choferes = new Set()
  rpc.mockImplementation(async (nombre: string, args: { p_transportista_id?: string }) =>
    nombre === 'aplicar_orden_ruta' && falla.choferes.has(String(args?.p_transportista_id))
      ? { data: null, error: { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' } }
      : { data: { success: true }, error: null })
})

describe('PedidosContainer — dividir ruta con pedidos que el optimizador dejó afuera (#1549)', () => {
  it('los skipped por capacidad NO se reparten por encima del máximo: quedan sin asignar y el aviso lo dice', async () => {
    // 2 choferes de máximo 2 paradas, 6 pedidos con coordenadas: el optimizador pone 2 + 2 y deja 2 afuera.
    escenario.repartidores = [{ transportista_id: 't1', max_paradas: 2 }, { transportista_id: 't2', max_paradas: 2 }]
    escenario.pedidos = ['1', '2', '3', '4', '5', '6'].map(pedidoConCoords)
    optimizarRutaMulti.mockResolvedValue(respuestaDelOptimizador({ t1: ['1', '2'], t2: ['3', '4'] }, ['5', '6']))

    await dividir()

    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    // Cada chofer queda en su máximo (antes quedaban en 3 y 3).
    expect(aplicadoPorChofer()).toEqual({ t1: ['1', '2'], t2: ['3', '4'] })
    // Los dos avisos dicen lo mismo: 2 sin chofer, y ninguno habla de coordenadas.
    expect(avisos()).toHaveLength(1)
    expect(avisos()[0]).toMatch(/^2 pedidos quedaron sin chofer/)
    expect(avisos()[0]).not.toMatch(/coordenadas/i)
    expect(String(notify.success.mock.calls[0][0])).toBe('Ruta dividida en 2 recorrido(s) · 2 pedido(s) sin asignar')
    // Y el resultado que ve el modal trae justo esos dos.
    expect(screen.getByTestId('sin-asignar').textContent).toBe('5,6')
  })

  it('los sin coordenadas se siguen repartiendo (con su aviso) aunque el chofer esté en su máximo', async () => {
    escenario.repartidores = [{ transportista_id: 't1', max_paradas: 2 }, { transportista_id: 't2', max_paradas: 2 }]
    escenario.pedidos = [...['1', '2', '3', '4'].map(pedidoConCoords), pedidoSinCoords('7')]
    optimizarRutaMulti.mockResolvedValue(respuestaDelOptimizador({ t1: ['1', '2'], t2: ['3', '4'] }, []))

    await dividir()

    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(aplicadoPorChofer()).toEqual({ t1: ['1', '2', '7'], t2: ['3', '4'] })
    expect(avisos()).toHaveLength(1)
    expect(avisos()[0]).toMatch(/^1 pedido se repartió sin optimizar por falta de coordenadas/)
    expect(String(notify.success.mock.calls[0][0])).toBe('Ruta dividida en 2 recorrido(s)')
    expect(screen.getByTestId('sin-asignar').textContent).toBe('')
  })

  it('mezcla: sin coordenadas y skipped juntos, cada uno con su aviso y sin contarse dos veces', async () => {
    escenario.repartidores = [{ transportista_id: 't1', max_paradas: 3 }, { transportista_id: 't2', max_paradas: 3 }]
    escenario.pedidos = [...['1', '2', '3', '4', '5'].map(pedidoConCoords), pedidoSinCoords('7')]
    // t1 y t2 rutean 2 cada uno; '5' queda afuera por el optimizador; '7' no tiene coordenadas.
    optimizarRutaMulti.mockResolvedValue(respuestaDelOptimizador({ t1: ['1', '2'], t2: ['3', '4'] }, ['5']))

    await dividir()

    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    // '7' (sin coords) va a t1 y lo llena (3 de 3); '5' entra en el cupo de t2 (3 de 3).
    expect(aplicadoPorChofer()).toEqual({ t1: ['1', '2', '7'], t2: ['3', '4', '5'] })
    expect(avisos()).toHaveLength(2)
    expect(avisos()[0]).toMatch(/^1 pedido se repartió sin optimizar por falta de coordenadas/)
    expect(avisos()[1]).toMatch(/^1 pedido que el optimizador no pudo acomodar se sumó sin optimizar a un chofer con cupo/)
    expect(screen.getByTestId('sin-asignar').textContent).toBe('')
  })

  it('si hay cupo para todos los skipped, no queda ninguno sin asignar', async () => {
    escenario.repartidores = [{ transportista_id: 't1', max_paradas: 4 }, { transportista_id: 't2', max_paradas: 4 }]
    escenario.pedidos = ['1', '2', '3', '4', '5'].map(pedidoConCoords)
    optimizarRutaMulti.mockResolvedValue(respuestaDelOptimizador({ t1: ['1', '2'], t2: ['3', '4'] }, ['5']))

    await dividir()

    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(aplicadoPorChofer()).toEqual({ t1: ['1', '2', '5'], t2: ['3', '4'] })
    expect(String(notify.success.mock.calls[0][0])).toBe('Ruta dividida en 2 recorrido(s)')
    expect(avisos().some(m => /sin chofer/.test(m))).toBe(false)
  })
})

describe('PedidosContainer — dividir ruta cuando falla el 2.º chofer (B9, #1549)', () => {
  it('las invalidaciones corren igual: el 1.º ya quedó armado', async () => {
    escenario.repartidores = [{ transportista_id: 't1' }, { transportista_id: 't2' }]
    escenario.pedidos = ['1', '2', '3', '4'].map(pedidoConCoords)
    optimizarRutaMulti.mockResolvedValue(respuestaDelOptimizador({ t1: ['1', '2'], t2: ['3', '4'] }, []))
    falla.choferes = new Set(['t2'])

    await dividir()

    await waitFor(() => expect(notify.error).toHaveBeenCalled())
    expect(String(notify.error.mock.calls[0][0])).toMatch(/^Error al guardar las rutas: Acceso denegado/)
    expect(Object.keys(aplicadoPorChofer())).toEqual(['t1', 't2'])
    for (const clave of ['pedidos', 'recorridos', 'recorrido-activo', 'recorrido-existente', 'rutas-en-curso']) {
      expect(clavesInvalidadas()).toContain(JSON.stringify([clave]))
    }
  })

  it('y cuando sale bien también', async () => {
    escenario.repartidores = [{ transportista_id: 't1' }]
    escenario.pedidos = ['1'].map(pedidoConCoords)
    optimizarRutaMulti.mockResolvedValue(respuestaDelOptimizador({ t1: ['1'] }, []))

    await dividir()

    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(clavesInvalidadas()).toContain(JSON.stringify(['recorrido-activo']))
  })
})
