/**
 * handleSaveSalvedades normaliza el error de supabase que devuelve `registrar_salvedad` (#1062).
 *
 * EL HUECO
 * --------
 * Si la RPC volvía con `{ error }` y el error NO era transitorio para `isTransientNetworkError`,
 * el handler hacía `results.push({ success: false, error: error.message })` con el objeto
 * PLANO de supabase-js. Dos formas de "no hubo servidor" se escapan de esa heurística y salían
 * con el texto técnico: un timeout de `withTimeout` ("timed out after Nms", que no matchea
 * 'timeout') y `navigator.onLine === false`. Tiene que salir `errorDeSupabase(error, <sin
 * conexión>)`: la red se traduce, y el mensaje del servidor (el que trae `code`) pasa intacto.
 *
 * El andamiaje de mocks es copia, recortada, del de `PedidosContainer.erroresRed.test.tsx`.
 */
import React, { useState } from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { conAbortSignal } from '../../../test/conAbortSignal'
import { PLAZO_ESCRITURA_MS } from '../../../utils/escrituraIdempotente'

const { rpc, supabaseStub, falla } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  const fallaObj: { error: unknown } = { error: null }
  return {
    rpc: rpcFn,
    falla: fallaObj,
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
vi.mock('../../../contexts/NotificationContext', () => {
  const notify = { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }
  return { useNotification: () => notify }
})

vi.mock('../../../contexts/SucursalContext', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useSucursal: () => ({ currentSucursalId: 1, sucursales: [], loading: false }),
}))
vi.mock('../../../hooks/useOfflineSync', () => ({ useOfflineSync: () => ({ isOnline: true, pendingCount: 0 }) }))
vi.mock('../../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
vi.mock('../../../hooks/useOptimizarRuta', () => ({
  useOptimizarRuta: () => ({
    loading: false, rutaOptimizada: null, error: null,
    optimizarRuta: vi.fn(), optimizarRutaMulti: vi.fn(), setRutaOptimizada: vi.fn(), limpiarRuta: vi.fn(),
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

// La vista de la ruta del chofer llama a `onRegistrarSalvedad` (= handleRegistrarSalvedadSingle,
// que envuelve a handleSaveSalvedades) y muestra el `error` del resultado.
// El lote entra por el modal: dos salvedades en un solo `onSave`, resultado por salvedad.
vi.mock('../../modals/ModalEntregaConSalvedad', () => ({
  default: function ModalFalso({ onSave }: {
    onSave: (s: unknown[]) => Promise<Array<{ success: boolean; error?: string }>>
  }) {
    const [res, setRes] = useState<string[]>([])
    const salvedad = (n: number) => ({
      pedidoId: '42', pedidoItemId: String(n), cantidadAfectada: 1,
      motivo: 'danado', devolverStock: false, clientRequestId: `req-lote-${n}`,
    })
    return (
      <div>
        <button type="button" onClick={() => { void onSave([salvedad(1), salvedad(2)]).then(r => setRes(r.map(x => x.error ?? 'OK'))) }}>
          Guardar lote
        </button>
        <ul data-testid="resultado-lote">{res.map((m, i) => <li key={i}>{m}</li>)}</ul>
      </div>
    )
  },
}))

vi.mock('../../vistas/VistaPedidos', () => ({
  default: function VistaFalsa({ onRegistrarSalvedad, onMarcarEntregadoConSalvedad }: {
    onMarcarEntregadoConSalvedad?: (pedido: unknown) => void
    onRegistrarSalvedad?: (d: {
      pedidoId: string; pedidoItemId: string; cantidadAfectada: number
      motivo: 'danado'; devolverStock: boolean; clientRequestId: string
    }) => Promise<{ success: boolean; error?: string }>
  }) {
    const [msg, setMsg] = useState('')
    return (
      <div>
        <button
          type="button"
          onClick={() => {
            void onRegistrarSalvedad?.({
              pedidoId: '42', pedidoItemId: '7', cantidadAfectada: 1,
              motivo: 'danado', devolverStock: false, clientRequestId: 'req-1',
            }).then((r) => setMsg(r.error ?? 'OK'))
          }}
        >
          Registrar salvedad
        </button>
        <button type="button" onClick={() => onMarcarEntregadoConSalvedad?.({ id: 42 })}>
          Abrir lote
        </button>
        <p data-testid="resultado">{msg}</p>
      </div>
    )
  },
}))

import PedidosContainer from '../PedidosContainer'

// Las formas reales de supabase-js, sin `instanceof Error`.
const ERROR_DE_SERVIDOR = { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' }
// `withTimeout` dice "timed out after Nms": no hubo servidor, pero isTransientNetworkError no lo reconoce.
const ERROR_DE_TIMEOUT = { message: 'timed out after 8000ms', details: '', hint: '', code: '' }
const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

// El container llama a otras RPC al montar: sólo cuenta las de registrar_salvedad.
function llamadasASalvedad(): number {
  return rpc.mock.calls.filter(([nombre]) => nombre === 'registrar_salvedad').length
}

async function registrar(): Promise<string> {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Registrar salvedad' }))
  return waitFor(() => {
    const t = screen.getByTestId('resultado').textContent ?? ''
    expect(t).not.toBe('')
    return t
  }, { timeout: 5000 })
}

beforeEach(() => {
  vi.clearAllMocks()
  falla.error = null
  rpc.mockImplementation(() => conAbortSignal({ data: null, error: falla.error }))
})

afterEach(() => {
  vi.restoreAllMocks()
})

describe('PedidosContainer — errores de registrar_salvedad (#1062)', () => {
  it('un error del servidor conserva su mensaje y no se reintenta', async () => {
    falla.error = ERROR_DE_SERVIDOR
    expect(await registrar()).toBe('Acceso denegado: se requiere rol admin')
    expect(llamadasASalvedad()).toBe(1)
  })

  it('un timeout (no hubo servidor, pero no es "transitorio") se traduce a sin conexión', async () => {
    falla.error = ERROR_DE_TIMEOUT
    const msg = await registrar()
    expect(msg).toMatch(/^Sin conexi/)
    expect(msg).not.toMatch(/timed out/i)
    expect(llamadasASalvedad()).toBe(1)
  })

  it('con el navegador sin conexión, cualquier error sin code se traduce a sin conexión', async () => {
    vi.spyOn(navigator, 'onLine', 'get').mockReturnValue(false)
    falla.error = { message: 'Error raro', details: '', hint: '', code: '' }
    const msg = await registrar()
    expect(msg).toMatch(/^Sin conexi/)
    expect(msg).not.toMatch(/error raro/i)
  })

  // #1366: una RPC colgada (señal que no pasa datos) se corta con el plazo. Lo que
  // ya llegó al server no se cancela, así que el mensaje manda a revisar el pedido.
  describe('RPC colgada (plazo de red, #1366)', () => {
    beforeEach(() => { rpc.mockImplementation(() => conAbortSignal(new Promise(() => {}))) })

    it('se corta a los 20 s, sin reintentar, y pide revisar el pedido antes de volver a intentar', async () => {
      const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
      montar()
      const boton = await screen.findByRole('button', { name: 'Registrar salvedad' })
      vi.useFakeTimers({ shouldAdvanceTime: true })
      try {
        await user.click(boton)
        await act(async () => { await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS) })
      } finally {
        vi.useRealTimers()
      }
      const msg = (await screen.findByTestId('resultado')).textContent ?? ''
      expect(msg).toMatch(/puede haber quedado registrada/i)
      expect(msg).toMatch(/revisá el pedido antes de volver a intentar/i)
      expect(llamadasASalvedad()).toBe(1)
    })

    it('en un lote, tras el plazo no espera otro por cada salvedad que sigue', async () => {
      const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
      montar()
      const abrir = await screen.findByRole('button', { name: 'Abrir lote' })
      await user.click(abrir)
      const guardar = await screen.findByRole('button', { name: 'Guardar lote' })
      vi.useFakeTimers({ shouldAdvanceTime: true })
      try {
        await user.click(guardar)
        await act(async () => { await vi.advanceTimersByTimeAsync(PLAZO_ESCRITURA_MS) })
      } finally {
        vi.useRealTimers()
      }
      const items = await screen.findAllByRole('listitem')
      expect(items).toHaveLength(2)
      expect(items[0].textContent).toMatch(/puede haber quedado registrada/i)
      expect(items[1].textContent).toMatch(/no se llegó a enviar/i)
      expect(llamadasASalvedad()).toBe(1)
    })
  })

  it('un fallo de red transitorio se reintenta y sale traducido por el catch de abajo', async () => {
    falla.error = ERROR_DE_RED
    const msg = await registrar()
    expect(msg).toMatch(/^Sin conexion estable/)
    expect(msg).not.toMatch(/failed to fetch/i)
    expect(llamadasASalvedad()).toBe(3)
  }, 10000)
})
