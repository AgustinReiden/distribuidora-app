/**
 * Los handlers de escritura de PedidosContainer normalizan el error de supabase (#1011).
 *
 * EL HUECO
 * --------
 * Seis handlers hacían `if (error) throw error` con el objeto PLANO que devuelve
 * supabase-js. Un fallo de red llegaba entonces a la pantalla como
 * "TypeError: Failed to fetch" —sin decir que la escritura NO se confirmó— y
 * nada distinguía un blip de 4G de un rechazo del servidor. Tienen que lanzar
 * `errorDeSupabase(error, '<sin conexión>')`: la red se traduce, y el mensaje del
 * servidor (el que trae `code`) pasa intacto.
 *
 * Las dos formas del error NO son inventadas: son las que arma PostgrestBuilder
 * (ver errorDeSupabase.test.ts). El andamiaje de mocks es copia del de
 * `PedidosContainer.itemsEdicion.test.tsx`; los modales se reemplazan por botones
 * que disparan el handler y muestran lo que éste lanzó.
 */
import React, { useState } from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { rpc, supabaseStub, notifyError, falla, optimizarRuta, optimizarRutaMulti } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  // Qué RPC/tabla falla y con qué error: lo fija cada test.
  const fallaObj: { rpc: string | null; error: unknown } = { rpc: null, error: null }
  return {
    rpc: rpcFn,
    falla: fallaObj,
    notifyError: vi.fn(),
    optimizarRuta: vi.fn(),
    optimizarRutaMulti: vi.fn(),
    supabaseStub: {
      rpc: rpcFn,
      from: vi.fn(() => ({
        select: vi.fn(() => ({ data: [], error: null })),
        update: vi.fn(() => ({ eq: vi.fn(() => Promise.resolve({ error: fallaObj.rpc === 'update:pedidos' ? fallaObj.error : null })) })),
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
  const notify = { error: notifyError, success: vi.fn(), warning: vi.fn(), info: vi.fn() }
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
    optimizarRuta, optimizarRutaMulti, setRutaOptimizada: vi.fn(), limpiarRuta: vi.fn(),
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
  default: ({ onEditarPedido, onEditarNotas, onOptimizarRuta }: {
    onEditarPedido?: (p: unknown) => void
    onEditarNotas?: (p: unknown) => void
    onOptimizarRuta?: () => void
  }) => (
    <div>
      <button type="button" onClick={() => onEditarPedido?.(PEDIDO)}>Editar pedido</button>
      <button type="button" onClick={() => onEditarNotas?.(PEDIDO)}>Editar notas</button>
      <button type="button" onClick={() => onOptimizarRuta?.()}>Armar ruta</button>
    </div>
  ),
}))

// Lo que el handler LANZA (items, preventista) se ve en pantalla.
function Resultado({ children }: { children: (set: (m: string) => void) => React.ReactNode }) {
  const [msg, setMsg] = useState('')
  return (
    <div>
      {children(setMsg)}
      <p data-testid="lanzado">{msg}</p>
    </div>
  )
}

vi.mock('../../modals/ModalEditarPedido', () => ({
  default: ({ onSave, onSaveItems, onCambiarPreventista }: {
    onSave?: (d: { notas: string }) => Promise<void>
    onSaveItems?: (items: unknown[], origenes: unknown[]) => Promise<void>
    onCambiarPreventista?: (id: string) => Promise<void>
  }) => (
    <Resultado>
      {(set) => (
        <>
          <button type="button" onClick={() => void onSave?.({ notas: 'x' })}>Guardar edición</button>
          <button
            type="button"
            onClick={() => onSaveItems?.(
              [{ productoId: '1', nombre: 'P', cantidad: 5, precioUnitario: 200, cantidadOriginal: 12 }], [],
            ).catch((e: Error) => set(e.message))}
          >
            Guardar items
          </button>
          <button type="button" onClick={() => onCambiarPreventista?.('u2').catch((e: Error) => set(e.message))}>
            Cambiar preventista
          </button>
        </>
      )}
    </Resultado>
  ),
}))

vi.mock('../../modals/ModalEditarNotas', () => ({
  default: ({ onSave }: { onSave?: (n: string) => Promise<void> }) => (
    <button type="button" onClick={() => void onSave?.('nota')}>Guardar notas</button>
  ),
}))

vi.mock('../../modals/ModalGestionRutas', () => ({
  default: ({ onArmarRuta, onArmarRutaMulti }: {
    onArmarRuta?: (...a: unknown[]) => Promise<void>
    onArmarRutaMulti?: (...a: unknown[]) => Promise<void>
  }) => (
    <div>
      <button type="button" onClick={() => void onArmarRuta?.('t1', [PEDIDO], '2026-10-10', '08:00', '18:00')}>Armar un chofer</button>
      <button
        type="button"
        onClick={() => void onArmarRutaMulti?.([{ transportista_id: 't1' }, { transportista_id: 't2' }], [PEDIDO], '2026-10-10', '08:00', '18:00')}
      >
        Armar varios
      </button>
    </div>
  ),
}))

import PedidosContainer from '../PedidosContainer'

// Las dos formas reales de supabase-js, sin `instanceof Error` ni nada que las disfrace.
const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const ERROR_DE_SERVIDOR = { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' }

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

function mensajesNotificados(): string[] {
  return notifyError.mock.calls.map(([m]) => String(m))
}

beforeEach(() => {
  vi.clearAllMocks()
  falla.rpc = null
  falla.error = null
  rpc.mockImplementation(async (nombre: string) =>
    nombre === falla.rpc
      ? { data: null, error: falla.error }
      : { data: { success: true }, error: null })
  optimizarRuta.mockResolvedValue({
    orden_optimizado: [{ pedido_id: '42', orden: 1 }], distancia_total: 1, duracion_total: 1, polylines: null,
  })
  optimizarRutaMulti.mockResolvedValue({
    recorridos: [
      { transportista_id: 't1', orden_optimizado: [{ pedido_id: '42', orden: 1 }], distancia_total: 1, duracion_total: 1, polylines: null },
      { transportista_id: 't2', orden_optimizado: [], distancia_total: 0, duracion_total: 0, polylines: null },
    ],
    skipped: [],
  })
})

describe('PedidosContainer — errores de red y de servidor en las escrituras (#1011)', () => {
  describe('observaciones (handleGuardarNotas)', () => {
    it('un fallo de red avisa que no se confirmó, sin "Failed to fetch"', async () => {
      falla.rpc = 'update:pedidos'
      falla.error = ERROR_DE_RED
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar notas' }))
      await user.click(await screen.findByRole('button', { name: 'Guardar notas' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      const [msg] = mensajesNotificados()
      expect(msg).toMatch(/^Sin conexión: no se pudo confirmar/)
      expect(msg).not.toMatch(/failed to fetch/i)
    })

    it('un error del servidor conserva su mensaje', async () => {
      falla.rpc = 'update:pedidos'
      falla.error = ERROR_DE_SERVIDOR
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar notas' }))
      await user.click(await screen.findByRole('button', { name: 'Guardar notas' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      expect(mensajesNotificados()).toEqual(['Acceso denegado: se requiere rol admin'])
    })
  })

  describe('edición del pedido (handleGuardarEdicion)', () => {
    it('un fallo de red avisa que no se confirmó, sin "Failed to fetch"', async () => {
      falla.rpc = 'update:pedidos'
      falla.error = ERROR_DE_RED
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
      await user.click(await screen.findByRole('button', { name: 'Guardar edición' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      const [msg] = mensajesNotificados()
      expect(msg).toMatch(/^Sin conexión: no se pudo confirmar/)
      expect(msg).not.toMatch(/failed to fetch/i)
    })

    it('un error del servidor conserva su mensaje', async () => {
      falla.rpc = 'update:pedidos'
      falla.error = ERROR_DE_SERVIDOR
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
      await user.click(await screen.findByRole('button', { name: 'Guardar edición' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      expect(mensajesNotificados()).toEqual(['Acceso denegado: se requiere rol admin'])
    })
  })

  describe('items del pedido (handleGuardarItemsEdicion)', () => {
    it('un fallo de red lanza el mensaje de sin conexión, sin "Failed to fetch"', async () => {
      falla.rpc = 'actualizar_pedido_items'
      falla.error = ERROR_DE_RED
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
      await user.click(await screen.findByRole('button', { name: 'Guardar items' }))

      const lanzado = await waitFor(() => {
        const t = screen.getByTestId('lanzado').textContent ?? ''
        expect(t).not.toBe('')
        return t
      })
      expect(lanzado).toMatch(/^Sin conexión: no se pudo confirmar/)
      expect(lanzado).not.toMatch(/failed to fetch/i)
    })

    it('un error del servidor conserva su mensaje', async () => {
      falla.rpc = 'actualizar_pedido_items'
      falla.error = ERROR_DE_SERVIDOR
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
      await user.click(await screen.findByRole('button', { name: 'Guardar items' }))

      await waitFor(() => expect(screen.getByTestId('lanzado').textContent).toBe('Acceso denegado: se requiere rol admin'))
    })
  })

  describe('preventista del pedido (handleCambiarPreventistaPedido)', () => {
    it('un fallo de red avisa que no se confirmó, sin "Failed to fetch"', async () => {
      falla.rpc = 'actualizar_preventista_pedido'
      falla.error = ERROR_DE_RED
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
      await user.click(await screen.findByRole('button', { name: 'Cambiar preventista' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      const [msg] = mensajesNotificados()
      expect(msg).toMatch(/^Sin conexión: no se pudo confirmar/)
      expect(msg).not.toMatch(/failed to fetch/i)
      expect(screen.getByTestId('lanzado').textContent).toBe(msg)
    })

    it('un error del servidor conserva su mensaje', async () => {
      falla.rpc = 'actualizar_preventista_pedido'
      falla.error = ERROR_DE_SERVIDOR
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
      await user.click(await screen.findByRole('button', { name: 'Cambiar preventista' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      expect(mensajesNotificados()).toEqual(['Acceso denegado: se requiere rol admin'])
    })
  })

  describe('armar la ruta (aplicar_orden_ruta)', () => {
    it('un chofer: la red se traduce y conserva el prefijo "Error al guardar la ruta"', async () => {
      falla.rpc = 'aplicar_orden_ruta'
      falla.error = ERROR_DE_RED
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Armar ruta' }))
      await user.click(await screen.findByRole('button', { name: 'Armar un chofer' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      const [msg] = mensajesNotificados()
      expect(msg).toMatch(/^Error al guardar la ruta: Sin conexión: no se pudo confirmar/)
      expect(msg).not.toMatch(/failed to fetch/i)
    })

    it('un chofer: el error del servidor conserva su mensaje', async () => {
      falla.rpc = 'aplicar_orden_ruta'
      falla.error = ERROR_DE_SERVIDOR
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Armar ruta' }))
      await user.click(await screen.findByRole('button', { name: 'Armar un chofer' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      expect(mensajesNotificados()).toEqual(['Error al guardar la ruta: Acceso denegado: se requiere rol admin'])
    })

    it('varios choferes: la red se traduce y conserva el prefijo "Error al guardar las rutas"', async () => {
      falla.rpc = 'aplicar_orden_ruta'
      falla.error = ERROR_DE_RED
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Armar ruta' }))
      await user.click(await screen.findByRole('button', { name: 'Armar varios' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      const [msg] = mensajesNotificados()
      expect(msg).toMatch(/^Error al guardar las rutas: Sin conexión: no se pudo confirmar/)
      expect(msg).not.toMatch(/failed to fetch/i)
    })

    it('varios choferes: el error del servidor conserva su mensaje', async () => {
      falla.rpc = 'aplicar_orden_ruta'
      falla.error = ERROR_DE_SERVIDOR
      const user = userEvent.setup()
      montar()
      await user.click(await screen.findByRole('button', { name: 'Armar ruta' }))
      await user.click(await screen.findByRole('button', { name: 'Armar varios' }))

      await waitFor(() => expect(notifyError).toHaveBeenCalled())
      expect(mensajesNotificados()).toEqual(['Error al guardar las rutas: Acceso denegado: se requiere rol admin'])
    })
  })
})
