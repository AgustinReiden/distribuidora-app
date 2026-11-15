/**
 * #1543 (VTA-1): nunca se acuña una clave de alta nueva mientras no se sepa qué
 * pasó con la anterior.
 *
 * El escenario que duplicaba: el preventista confirma, el server hace COMMIT
 * (stock descontado) y la respuesta se pierde; la pantalla muestra error, él
 * cambia algo y confirma de nuevo. La huella cambió → clave nueva → segundo
 * pedido. Y por la otra puerta: el segundo intento sale sin red, se encola con
 * otra clave y el replay crea el segundo pedido al sincronizar.
 *
 * El andamiaje de mocks es el de `PedidosContainer.altaClave.test.tsx`.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { RechazoDeNegocioError } from '../../utils/rechazoDeNegocio'

const {
  invalidateQueries, rpc, supabaseStub, registrarPago, notify, mutateAlta, verificarClave,
  guardarPedidoOffline, red, clientesMock,
} = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    verificarClave: vi.fn(),
    guardarPedidoOffline: vi.fn(),
    // `isOnline` del contexto: el segundo intento puede salir sin red.
    red: { online: true },
    clientesMock: { valor: [] as Array<Record<string, unknown>> },
    registrarPago: vi.fn(),
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    mutateAlta: vi.fn(),
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

const emptyQuery = { data: [], isLoading: false, isFetching: false, refetch: vi.fn() }
const emptyMutation = { mutateAsync: vi.fn().mockResolvedValue({}), mutate: vi.fn(), isPending: false }

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  usePedidosPaginatedQuery: () => ({ data: { pedidos: [], total: 0, totalPages: 1 }, isLoading: false, isFetching: false }),
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
  useClientesQuery: () => ({ ...emptyQuery, data: clientesMock.valor }),
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

// La pregunta al server por `pedidos.offline_id`.
vi.mock('../../hooks/queries/usePedidosQuery', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  verificarClaveDeAlta: verificarClave,
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
    isAdmin: true, isEncargado: false, isPreventista: false, isTransportista: false, isDeposito: false,
    isOnline: red.online, authReady: true,
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
vi.mock('../../hooks/useOfflineSync', () => ({
  useOfflineSync: () => ({ isOnline: true, pendingCount: 0, guardarPedidoOffline }),
}))
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
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    datosPrecio: { cargando: [], fallaron: [], sinSenal: [] }, entradasDatosPrecio: [], reintentarDatosPrecio: () => {},
    preciosResueltos: new Map(), faltantes: [], faltantesBonificacion: [],
    promoResolucion: { bonificaciones: [], productosConPromo: new Set() },
    itemsFinales: [{ productoId: '7', cantidad: 10, precioUnitario: 1000 }],
    totalFinal: 10000, totalOriginal: 10000, ahorro: 0, hayDescuento: false,
    itemsConDescuentoCliente: [], totalConDescuentoCliente: 10000,
    combos: [], combosAplicados: [],
    lineasConCombos: [{ productoId: '7', cantidad: 10, precioUnitario: 1000 }],
    totalConCombos: 10000, ahorroCombos: 0,
    isLoading: false, moqMap: new Map(), minimosProducto: new Map(), violacionesMOQ: [],
  }),
}))

vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onNuevoPedido }: { onNuevoPedido?: () => void }) => (
    <button type="button" onClick={() => onNuevoPedido?.()}>Nuevo pedido</button>
  ),
}))

vi.mock('../modals/ModalPedido', () => ({
  default: (p: {
    onClienteChange: (id: string) => void
    onAgregarItem: (id: string, cantidad?: number, precio?: number) => void
    onNotasChange: (notas: string) => void
    onEstadoPagoChange: (e: string) => void
    onTipoFacturaChange: (t: string) => void
    onGuardar: () => void
  }) => (
    <>
      <button type="button" onClick={() => { p.onClienteChange('9'); p.onAgregarItem('7', 10, 1000) }}>Armar</button>
      <button type="button" onClick={() => p.onNotasChange('dejar en la puerta')}>Cambiar nota</button>
      <button type="button" onClick={() => p.onNotasChange('')}>Nota igual</button>
      <button type="button" onClick={() => p.onEstadoPagoChange('pagado')}>Pagado</button>
      <button type="button" onClick={() => p.onTipoFacturaChange('VB')}>Vale blanco</button>
      <button type="button" onClick={() => p.onGuardar()}>Confirmar</button>
    </>
  ),
}))

import PedidosContainer from './PedidosContainer'
import { fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'

/** Lo que tira de verdad `crearPedido` cuando la respuesta se pierde. */
const respuestaPerdida = () =>
  errorDeSupabase({ message: 'TypeError: Failed to fetch', code: '' }, 'Sin conexión: no se pudo confirmar el alta del pedido.')

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><PedidosContainer /></MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  // La sesión de `u1`, como la fija `useAuth`: la clave en duda va al teléfono (INF-6).
  localStorage.clear()
  fijarUsuarioRequestIds('u1')
  red.online = true
  clientesMock.valor = []
  rpc.mockResolvedValue({ data: { success: true }, error: null })
  registrarPago.mockResolvedValue(undefined)
  mutateAlta.mockResolvedValue({ id: '600' })
  verificarClave.mockResolvedValue({ resultado: 'no_entro' })
  guardarPedidoOffline.mockResolvedValue({ success: true, pedido: { offlineId: 'op_1' } })
})

async function primerIntentoPerdido() {
  const user = userEvent.setup()
  const pantalla = montar()
  await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
  await user.click(await screen.findByRole('button', { name: 'Armar' }))
  mutateAlta.mockRejectedValueOnce(respuestaPerdida())
  await user.click(screen.getByRole('button', { name: 'Confirmar' }))
  await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
  await waitFor(() => expect(notify.error).toHaveBeenCalled())
  return { user, pantalla, claveAnterior: mutateAlta.mock.calls[0][0].offlineId as string }
}

const avisos = () => notify.warning.mock.calls.map(c => String(c[0]))

describe('#1543 — el alta con la clave anterior en duda', () => {
  it('el anterior entró: NO se crea otro pedido, se avisa con su número y se cierra el alta', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValueOnce({ resultado: 'entro', pedidoId: '501' })

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(verificarClave).toHaveBeenCalledWith(claveAnterior))
    await waitFor(() => expect(avisos().some(a => a.includes('#501') && /NO está en ese pedido/.test(a))).toBe(true))
    // La RPC del alta no se llamó por segunda vez.
    expect(mutateAlta).toHaveBeenCalledTimes(1)
    expect(notify.success).not.toHaveBeenCalled()
    // El alta se cerró y la lista se refresca, como en un alta exitosa.
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Confirmar' })).toBeNull())
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['pedidos'] })
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['productos'] })
  })

  it('con cobro declarado, el aviso dice que el cobro no quedó registrado y no se cobra nada', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    await user.click(screen.getByRole('button', { name: 'Pagado' }))
    mutateAlta.mockRejectedValueOnce(respuestaPerdida())
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))

    verificarClave.mockResolvedValueOnce({ resultado: 'entro', pedidoId: '501' })
    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(avisos().some(a => a.includes('#501') && /cobro no quedó registrado/.test(a))).toBe(true))
    expect(mutateAlta).toHaveBeenCalledTimes(1)
    expect(registrarPago).not.toHaveBeenCalled()
  })

  it('el anterior no entró: se llama al alta con una clave nueva', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(verificarClave).toHaveBeenCalledWith(claveAnterior)
    const nueva = mutateAlta.mock.calls[1][0].offlineId
    expect(nueva).toBeTruthy()
    expect(nueva).not.toBe(claveAnterior)
    expect(mutateAlta.mock.calls[1][0].notas).toBe('dejar en la puerta')
  })

  it('no se pudo preguntar: no se crea nada, se pide esperar señal, y el formulario sigue en duda', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValueOnce({ resultado: 'sin_respuesta' })

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(avisos().some(a => /Esperá a tener señal/.test(a))).toBe(true))
    expect(mutateAlta).toHaveBeenCalledTimes(1)
    // El alta sigue abierta, y el próximo Confirmar vuelve a preguntar por la MISMA clave.
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(verificarClave).toHaveBeenCalledTimes(2)
    expect(verificarClave.mock.calls.every(c => c[0] === claveAnterior)).toBe(true)
  })

  it('mismo contenido: reusa la clave sin preguntar (el server contesta idempotente)', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(verificarClave).not.toHaveBeenCalled()
    expect(mutateAlta.mock.calls[1][0].offlineId).toBe(claveAnterior)
  })

  it('un rechazo de negocio no deja duda: una edición acuña clave nueva sin preguntar', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    mutateAlta.mockRejectedValueOnce(new RechazoDeNegocioError('Stock insuficiente para Coca 2.25'))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(verificarClave).not.toHaveBeenCalled()
    expect(mutateAlta.mock.calls[1][0].offlineId).not.toBe(mutateAlta.mock.calls[0][0].offlineId)
  })

  it('vale blanco: el anterior entró → no se crea otro', async () => {
    clientesMock.valor = [{ id: '9', nombre_fantasia: 'Kiosco Sur', tipo_factura_default: 'VB' }]
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    await user.click(screen.getByRole('button', { name: 'Vale blanco' }))
    mutateAlta.mockRejectedValueOnce(respuestaPerdida())
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    expect(mutateAlta.mock.calls[0][0].tipoFactura).toBe('VB')
    const claveAnterior = mutateAlta.mock.calls[0][0].offlineId

    verificarClave.mockResolvedValueOnce({ resultado: 'entro', pedidoId: '777' })
    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(avisos().some(a => a.includes('#777'))).toBe(true))
    expect(verificarClave).toHaveBeenCalledWith(claveAnterior)
    expect(mutateAlta).toHaveBeenCalledTimes(1)
  })
})

describe('#1543 variante 4 — el primer intento online se perdió y el segundo sale sin red', () => {
  /** Se corta la señal: el container la lee de `useAuthData` al renderizar. */
  async function sinSenal(user: ReturnType<typeof userEvent.setup>) {
    red.online = false
    // Re-render sin tocar el contenido: la nota queda igual (vacía).
    await user.click(screen.getByRole('button', { name: 'Nota igual' }))
  }

  it('sin editar: se encola con la MISMA clave del intento perdido (el replay no duplica)', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    await sinSenal(user)

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][1]).toMatchObject({ claveDeAlta: claveAnterior })
    expect(verificarClave).not.toHaveBeenCalled()
    expect(mutateAlta).toHaveBeenCalledTimes(1)
  })

  it('editado y sin poder preguntar: no se encola nada y se pide esperar señal', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    await sinSenal(user)
    verificarClave.mockResolvedValueOnce({ resultado: 'sin_respuesta' })

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(avisos().some(a => /Esperá a tener señal/.test(a))).toBe(true))
    expect(verificarClave).toHaveBeenCalledWith(claveAnterior)
    expect(guardarPedidoOffline).not.toHaveBeenCalled()
    expect(mutateAlta).toHaveBeenCalledTimes(1)
  })

  it('editado y el server contesta que no entró: se encola con una clave nueva', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    await sinSenal(user)

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    const clave = guardarPedidoOffline.mock.calls[0][1].claveDeAlta
    expect(clave).toBeTruthy()
    expect(clave).not.toBe(claveAnterior)
  })

  it('editado y el server contesta que entró: no se encola nada', async () => {
    const { user } = await primerIntentoPerdido()
    await sinSenal(user)
    verificarClave.mockResolvedValueOnce({ resultado: 'entro', pedidoId: '501' })

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(avisos().some(a => a.includes('#501'))).toBe(true))
    expect(guardarPedidoOffline).not.toHaveBeenCalled()
  })
})

/**
 * INF-6 (#1563): la clave en duda sobrevive a recargar la app. Antes vivía sólo en
 * `altaIdRef`: recargar con un alta en duda la perdía y el mismo pedido, cargado de
 * nuevo, viajaba con otra clave y se duplicaba.
 */
describe('INF-6 — recargar la app con un alta en duda', () => {
  /** Cierra la pantalla y la vuelve a abrir: lo único que sobrevive es el teléfono. */
  async function recargar(pantalla: ReturnType<typeof montar>) {
    pantalla.unmount()
    montar()
    return userEvent.setup()
  }

  it('el mismo pedido cargado de nuevo viaja con la MISMA clave (el server contesta idempotente)', async () => {
    const { pantalla, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValueOnce({ resultado: 'sin_respuesta' })

    const user = await recargar(pantalla)
    await waitFor(() => expect(verificarClave).toHaveBeenCalledWith(claveAnterior))
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).toBe(claveAnterior)
  })

  it('al abrir se pregunta por ella: si entró, se avisa con su número y la próxima alta es otra', async () => {
    const { pantalla, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValueOnce({ resultado: 'entro', pedidoId: '501' })

    const user = await recargar(pantalla)

    await waitFor(() => expect(avisos().some(a => a.includes('#501') && /sí se guardó/.test(a))).toBe(true))
    expect(verificarClave).toHaveBeenCalledWith(claveAnterior)
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['pedidos'] })
    expect(mutateAlta).toHaveBeenCalledTimes(1)

    // La clave quedó olvidada: un pedido nuevo no vuelve a preguntar por ella.
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).not.toBe(claveAnterior)
    expect(verificarClave).toHaveBeenCalledTimes(1)
  })

  it('si no entró, se olvida sin avisar nada', async () => {
    const { pantalla, claveAnterior } = await primerIntentoPerdido()

    const user = await recargar(pantalla)
    await waitFor(() => expect(verificarClave).toHaveBeenCalledWith(claveAnterior))
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).not.toBe(claveAnterior)
    expect(avisos()).toEqual([])
  })

  it('un alta que salió bien no deja nada guardado', async () => {
    const user = userEvent.setup()
    const pantalla = montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Confirmar' })).toBeNull())

    await recargar(pantalla)
    await screen.findByRole('button', { name: 'Nuevo pedido' })
    expect(verificarClave).not.toHaveBeenCalled()
  })
})
