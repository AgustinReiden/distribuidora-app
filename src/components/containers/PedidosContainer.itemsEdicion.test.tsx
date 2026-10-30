/**
 * Editar los items de un pedido mueve stock y saldo: las dos cachés tienen que
 * caerse con él.
 *
 * EL HUECO
 * --------
 * `handleGuardarItemsEdicion` invalidaba `pedidos` y la familia `recorridos*`,
 * pero no `productos` ni `clientes`. `useProductosQuery` tiene `staleTime` de
 * 10 minutos, así que después de sacarle 20 unidades a un pedido el catálogo
 * seguía mostrando el stock de antes: el alta siguiente calculaba
 * `violacionesStock` contra ese número y bloqueaba de más —o, al revés, dejaba
 * pasar un pedido que no había stock para cubrir—. Lo mismo con el saldo del
 * cliente cuando el total cambia.
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

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, rpc, supabaseStub, guardado, propsModal } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    // La promesa del último onSaveItems, para ver con qué se rechaza.
    guardado: { promesa: null as Promise<void> | null },
    // Las props con que el container monta el modal.
    propsModal: { valor: null as Record<string, unknown> | null },
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

// Se parte del barrel real y se pisan sólo los hooks que el container usa: así
// un hook nuevo no rompe este test con "No export is defined on the mock".
vi.mock('../../hooks/queries', async (importOriginal) => ({
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

vi.mock('../../hooks/queries/useRecorridoActivoQuery', () => ({
  useRecorridoActivoQuery: () => ({ data: null }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false,
    user: { id: 'u1' }, perfil: { id: 'u1', rol: 'admin' },
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
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

// La vista sólo tiene que poder abrir la edición del pedido.
vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onEditarPedido }: { onEditarPedido?: (p: unknown) => void }) => (
    <button type="button" onClick={() => onEditarPedido?.(PEDIDO)}>Editar pedido</button>
  ),
}))

// El modal real no es lo que se prueba: alcanza con disparar el guardado de
// items como lo hace él, con su payload de items + orígenes.
vi.mock('../modals/ModalEditarPedido', () => ({
  default: (props: {
    onSaveItems?: (items: unknown[], origenes: unknown[], decision?: string) => Promise<void>
  }) => {
    propsModal.valor = props as Record<string, unknown>
    const items = [{ productoId: '1', nombre: 'Producto 1', cantidad: 5, precioUnitario: 200, cantidadOriginal: 12 }]
    const origenes = [{ producto_id: '1', es_bonificacion: false, origen_precio: 'mayorista', grupo_precio_escala_id: 'esc-1' }]
    const disparar = (decision?: string) => {
      guardado.promesa = (decision ? props.onSaveItems?.(items, origenes, decision) : props.onSaveItems?.(items, origenes)) ?? null
      guardado.promesa?.catch(() => undefined)
    }
    return (
      <>
        <button type="button" onClick={() => disparar()}>Guardar items</button>
        <button type="button" onClick={() => disparar('cobrar')}>Guardar items cobrando</button>
      </>
    )
  },
}))

import PedidosContainer from './PedidosContainer'
import { esRechazoDeEnvio, type RechazoDeNegocioError } from '../../utils/rechazoDeNegocio'

beforeEach(() => {
  vi.clearAllMocks()
  guardado.promesa = null
  propsModal.valor = null
  rpc.mockResolvedValue({ data: { success: true }, error: null })
})

describe('PedidosContainer — guardar items de la edición', () => {
  it('invalida productos y clientes además de pedidos y recorridos', async () => {
    const user = userEvent.setup()
    // Provider real para los `useQuery` sueltos que quedan sin mockear;
    // `useQueryClient` sigue devolviendo el spy (ver el mock de arriba).
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={qc}>
        <MemoryRouter><PedidosContainer /></MemoryRouter>
      </QueryClientProvider>,
    )

    await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar items' }))

    await waitFor(() => expect(rpc).toHaveBeenCalledWith('actualizar_pedido_items', expect.anything()))

    const invalidados = invalidateQueries.mock.calls.map(([arg]) => (arg as { queryKey: string[] }).queryKey[0])
    // Lo que ya estaba, para que el fix no se coma nada.
    expect(invalidados).toContain('pedidos')
    expect(invalidados).toContain('recorridos')
    // Lo que faltaba: sin esto el catálogo sirve stock de hasta 10 minutos
    // atrás y la cuenta corriente, el saldo anterior al cambio de total.
    expect(invalidados).toContain('productos')
    expect(invalidados).toContain('clientes')
  })
})

// cargo_2_edicion: la decisión del envío viaja como p_decision_envio, y sólo
// cuando hay una. Sin decisión la llamada es la de siempre, de tres argumentos:
// así el front nuevo funciona igual contra la base antes de la migración.
describe('PedidosContainer — decisión del envío al guardar items', () => {
  function montar() {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={qc}>
        <MemoryRouter><PedidosContainer /></MemoryRouter>
      </QueryClientProvider>,
    )
  }

  it('el modal sabe si quien edita decide el envío (admin: no es preventista)', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
    await screen.findByRole('button', { name: 'Guardar items' })
    expect(propsModal.valor?.esPreventista).toBe(false)
  })

  it('sin decisión no manda p_decision_envio', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar items' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('actualizar_pedido_items', expect.anything()))
    const args = rpc.mock.calls.find(([n]) => n === 'actualizar_pedido_items')![1] as Record<string, unknown>
    expect(Object.keys(args).sort()).toEqual(['p_items_nuevos', 'p_pedido_id', 'p_usuario_id'])
  })

  it('con decisión la manda como p_decision_envio', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar items cobrando' }))
    await waitFor(() => expect(rpc).toHaveBeenCalledWith('actualizar_pedido_items',
      expect.objectContaining({ p_pedido_id: 42, p_decision_envio: 'cobrar' })))
  })

  it('el rechazo requiere_decision_envio llega como RechazoDeNegocioError con su código y su detalle', async () => {
    rpc.mockResolvedValue({
      data: {
        success: false,
        errores: ['El pedido quedó en $14.000,00. ¿Agregar envío de $500,00?'],
        codigo: 'requiere_decision_envio',
        cargo: 500,
        franja: 'debajo',
        total_productos: 14000,
      },
      error: null,
    })
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Editar pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar items' }))
    await waitFor(() => expect(guardado.promesa).not.toBeNull())
    const error = await guardado.promesa!.then(() => null, (e: unknown) => e)
    expect(esRechazoDeEnvio(error)).toBe(true)
    const rechazo = error as RechazoDeNegocioError
    expect(rechazo.message).toBe('El pedido quedó en $14.000,00. ¿Agregar envío de $500,00?')
    expect(rechazo.detalle).toEqual({ cargo: 500, franja: 'debajo', total_productos: 14000 })
    // No se registró el origen del precio de una edición que no se guardó.
    expect(rpc).not.toHaveBeenCalledWith('registrar_origen_precio_items', expect.anything())
  })
})
