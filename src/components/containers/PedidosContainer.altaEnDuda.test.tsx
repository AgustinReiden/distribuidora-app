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
import { describe, it, expect, vi, beforeEach, afterEach, type MockInstance } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
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
    onFormaPagoChange: (f: string) => void
    onTipoFacturaChange: (t: string) => void
    onGuardar: () => void
    onGuardarEnCola?: () => void
    onClose: () => void
  }) => (
    <>
      {/* D56: el modal real ofrece la cola cuando el container le pasa el callback. */}
      {p.onGuardarEnCola && <button type="button" onClick={() => p.onGuardarEnCola?.()}>Guardar en el teléfono</button>}
      <button type="button" onClick={() => p.onClose()}>Cerrar alta</button>
      <button type="button" onClick={() => { p.onClienteChange('9'); p.onAgregarItem('7', 10, 1000) }}>Armar</button>
      <button type="button" onClick={() => { p.onClienteChange('10'); p.onAgregarItem('7', 10, 1000) }}>Armar otro cliente</button>
      <button type="button" onClick={() => p.onNotasChange('dejar en la puerta')}>Cambiar nota</button>
      <button type="button" onClick={() => p.onNotasChange('')}>Nota igual</button>
      <button type="button" onClick={() => p.onEstadoPagoChange('pagado')}>Pagado</button>
      <button type="button" onClick={() => p.onFormaPagoChange('transferencia')}>Transferencia</button>
      <button type="button" onClick={() => p.onTipoFacturaChange('VB')}>Vale blanco</button>
      <button type="button" onClick={() => p.onGuardar()}>Confirmar</button>
    </>
  ),
}))

import PedidosContainer from './PedidosContainer'
import { fijarUsuarioRequestIds } from '../../utils/requestIdPersistente'
import { MARGEN_INTENTO_EN_VUELO_MS, MENSAJE_ALTA_EN_DUDA_ENCOLADA, PLAZO_ALTA_DIRECTA_MS } from '../../utils/idempotencia'

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

/**
 * M5 (#1603): un «no entró» dentro de `MARGEN_INTENTO_EN_VUELO_MS` del último
 * intento no se cree (el intento puede seguir corriendo en el servidor). Los tests
 * que prueban qué pasa con un «no entró» de verdad corren el reloj pasado el margen.
 */
let reloj: MockInstance<() => number> | null = null
function pasaElMargen(): void {
  const despues = Date.now() + MARGEN_INTENTO_EN_VUELO_MS
  reloj = vi.spyOn(Date, 'now').mockReturnValue(despues)
}

afterEach(() => {
  reloj?.mockRestore()
  reloj = null
})

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
  // Cambió de regla con D56 (1563-b7): un fallo de red con la clave en duda ya no
  // es un toast de error; el modal queda abierto y ofrece guardarlo en la cola.
  await screen.findByRole('button', { name: 'Guardar en el teléfono' })
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
    pasaElMargen()

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
    pasaElMargen()
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
    pasaElMargen()

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
    pasaElMargen()

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

/**
 * VTA-1 (#1543), el caso que quedaba: cerrar el alta con la X después del error.
 * `onClose` limpiaba el formulario y tiraba la clave en duda, así que el mismo
 * pedido cargado de nuevo desde cero viajaba con otra clave y se duplicaba.
 */
describe('VTA-1 — cerrar el alta con la clave en duda', () => {
  /** Cierra el alta y vuelve a cargar el pedido desde cero (con la nota cambiada si `editado`). */
  async function cerrarYCargarDeNuevo(user: ReturnType<typeof userEvent.setup>, editado: boolean) {
    await user.click(screen.getByRole('button', { name: 'Cerrar alta' }))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Confirmar' })).toBeNull())
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    if (editado) await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
  }

  it('al cerrar se pregunta por ella: si entró, se avisa con su número y no se crea otra', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValueOnce({ resultado: 'entro', pedidoId: '501' })

    await user.click(screen.getByRole('button', { name: 'Cerrar alta' }))

    await waitFor(() => expect(verificarClave).toHaveBeenCalledWith(claveAnterior))
    await waitFor(() => expect(avisos().some(a => a.includes('#501') && /no lo cargues de nuevo/.test(a))).toBe(true))
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['pedidos'] })
    expect(mutateAlta).toHaveBeenCalledTimes(1)
  })

  it('no contestó al cerrar: el pedido cargado de nuevo y editado pregunta antes de acuñar otra clave', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValueOnce({ resultado: 'sin_respuesta' })
    await cerrarYCargarDeNuevo(user, true)
    await waitFor(() => expect(verificarClave).toHaveBeenCalledTimes(1))

    // Ahora el server contesta que el anterior entró: no se crea el segundo.
    verificarClave.mockResolvedValueOnce({ resultado: 'entro', pedidoId: '501' })
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(avisos().some(a => a.includes('#501'))).toBe(true))
    expect(verificarClave).toHaveBeenCalledTimes(2)
    expect(verificarClave.mock.calls.every(c => c[0] === claveAnterior)).toBe(true)
    expect(mutateAlta).toHaveBeenCalledTimes(1)
  })

  it('no contestó al cerrar: el mismo pedido cargado de nuevo viaja con la MISMA clave', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValueOnce({ resultado: 'sin_respuesta' })
    await cerrarYCargarDeNuevo(user, false)

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).toBe(claveAnterior)
  })

  it('no entró: se olvida sin avisar, y el pedido nuevo va con otra clave', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    pasaElMargen()
    await cerrarYCargarDeNuevo(user, true)
    await waitFor(() => expect(verificarClave).toHaveBeenCalledWith(claveAnterior))

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).not.toBe(claveAnterior)
    expect(verificarClave).toHaveBeenCalledTimes(1)
    expect(avisos()).toEqual([])
  })

  it('cerrar sin un intento en duda no le pregunta nada al server', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    // Un rechazo de negocio prueba que no entró: no deja duda.
    mutateAlta.mockRejectedValueOnce(new RechazoDeNegocioError('Stock insuficiente para Coca 2.25'))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))

    await user.click(screen.getByRole('button', { name: 'Cerrar alta' }))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Confirmar' })).toBeNull())
    expect(verificarClave).not.toHaveBeenCalled()
  })
})

/**
 * L2 (#1603): la clave en duda va atada al cliente. Cerrar con la X un alta en duda,
 * sin señal, trababa TODA alta siguiente, también la de otro cliente y la que iría a
 * la cola offline («Esperá a tener señal»). Un alta de otro cliente no puede ser un
 * duplicado de la que quedó en duda: sigue su camino. Sólo la del mismo cliente espera.
 */
describe('L2 — la clave en duda es del cliente del pedido', () => {
  /** El alta del cliente 9 quedó en duda, se cerró con la X y el server no contestó; se corta la señal. */
  async function cerradaSinRespuestaYSinSenal() {
    const r = await primerIntentoPerdido()
    verificarClave.mockResolvedValue({ resultado: 'sin_respuesta' })
    await r.user.click(screen.getByRole('button', { name: 'Cerrar alta' }))
    await waitFor(() => expect(verificarClave).toHaveBeenCalledTimes(1))
    red.online = false
    return r
  }

  async function cargar(user: ReturnType<typeof userEvent.setup>, armar: 'Armar' | 'Armar otro cliente', editado = true) {
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: armar }))
    if (editado) await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
  }

  it('sin señal, el pedido de OTRO cliente se encola sin esperar ni preguntar, con otra clave', async () => {
    const { user, claveAnterior } = await cerradaSinRespuestaYSinSenal()

    await cargar(user, 'Armar otro cliente')

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][1].claveDeAlta).not.toBe(claveAnterior)
    expect(avisos().some(a => /Esperá a tener señal/.test(a))).toBe(false)
    expect(verificarClave).toHaveBeenCalledTimes(1)
  })

  it('con señal, el pedido de otro cliente se manda sin preguntar por la anterior', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValue({ resultado: 'sin_respuesta' })
    await user.click(screen.getByRole('button', { name: 'Cerrar alta' }))
    await waitFor(() => expect(verificarClave).toHaveBeenCalledTimes(1))

    await cargar(user, 'Armar otro cliente')

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).not.toBe(claveAnterior)
    expect(verificarClave).toHaveBeenCalledTimes(1)
  })

  it('sin señal, el pedido distinto del MISMO cliente sigue esperando', async () => {
    const { user, claveAnterior } = await cerradaSinRespuestaYSinSenal()

    await cargar(user, 'Armar')

    await waitFor(() => expect(avisos().some(a => /Esperá a tener señal/.test(a))).toBe(true))
    expect(verificarClave).toHaveBeenLastCalledWith(claveAnterior)
    expect(guardarPedidoOffline).not.toHaveBeenCalled()
  })

  it('sin señal, el MISMO pedido del mismo cliente se encola con la misma clave', async () => {
    const { user, claveAnterior } = await cerradaSinRespuestaYSinSenal()

    await cargar(user, 'Armar', false)

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][1]).toMatchObject({ claveDeAlta: claveAnterior })
  })

  it('la clave en duda no se pierde por cargar a otro cliente: vuelve la señal, se pregunta y se avisa con su número', async () => {
    const { user, claveAnterior } = await cerradaSinRespuestaYSinSenal()
    await cargar(user, 'Armar otro cliente')
    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(localStorage.getItem('distribuidora:alta-en-duda:u1')).toContain(claveAnterior)

    // Vuelve la señal (el container la lee al renderizar) y el anterior había entrado.
    verificarClave.mockResolvedValue({ resultado: 'entro', pedidoId: '501' })
    red.online = true
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))

    await waitFor(() => expect(avisos().some(a => a.includes('#501') && /no lo cargues de nuevo/.test(a))).toBe(true))
    expect(verificarClave).toHaveBeenLastCalledWith(claveAnterior)
    expect(localStorage.getItem('distribuidora:alta-en-duda:u1') ?? '').not.toContain(claveAnterior)
  })

  it('recargar con la clave en duda de un cliente no traba el pedido de otro', async () => {
    const { pantalla, claveAnterior } = await primerIntentoPerdido()
    verificarClave.mockResolvedValue({ resultado: 'sin_respuesta' })
    pantalla.unmount()
    red.online = false
    montar()
    const user = userEvent.setup()
    await waitFor(() => expect(verificarClave).toHaveBeenCalledWith(claveAnterior))

    await cargar(user, 'Armar otro cliente')

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][1].claveDeAlta).not.toBe(claveAnterior)
  })
})

/**
 * D56 (decisión del dueño, 1563-b7 de #1563): con señal que no pasa datos y
 * `navigator.onLine` en true, el alta que falla por la red queda en duda y la
 * pantalla ofrece guardarla en la cola; no se encola sola. Se encola con la MISMA
 * clave del intento: si ese intento sí había entrado, el replay recibe el mismo
 * pedido (rama idempotente) y no se duplica.
 */
describe('D56 — señal inservible con onLine en true: la cola se ofrece', () => {
  it('el fallo de red no encola solo ni se pierde: el alta queda abierta y ofrece la cola', async () => {
    await primerIntentoPerdido()

    expect(guardarPedidoOffline).not.toHaveBeenCalled()
    expect(notify.error).not.toHaveBeenCalled()
    // El alta sigue abierta con el pedido.
    expect(screen.getByRole('button', { name: 'Confirmar' })).toBeTruthy()
  })

  it('«Guardar en el teléfono» lo encola con la MISMA clave del intento, sin otro intento directo', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Guardar en el teléfono' }))

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][1]).toMatchObject({ claveDeAlta: claveAnterior })
    // El cobro no viaja en la cola (1598-b10).
    expect(guardarPedidoOffline.mock.calls[0][0]).toMatchObject({ estadoPago: 'pendiente' })
    expect(mutateAlta).toHaveBeenCalledTimes(1)
    expect(verificarClave).not.toHaveBeenCalled()
    await waitFor(() => expect(avisos()).toContain(MENSAJE_ALTA_EN_DUDA_ENCOLADA))
    // Encolada, la clave es de la cola: ya no queda en duda en el teléfono.
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Confirmar' })).toBeNull())
    expect(localStorage.getItem('distribuidora:alta-en-duda:u1') ?? '').not.toContain(claveAnterior)
  })

  it('tocar Confirmar de nuevo reintenta con la misma clave, y si vuelve a fallar se vuelve a ofrecer', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()
    mutateAlta.mockRejectedValueOnce(respuestaPerdida())

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).toBe(claveAnterior)
    await screen.findByRole('button', { name: 'Guardar en el teléfono' })
  })

  it('si cambia el pedido, la oferta deja de valer (sería otro pedido)', async () => {
    const { user } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))

    await waitFor(() => expect(screen.queryByRole('button', { name: 'Guardar en el teléfono' })).toBeNull())
  })

  // H4 (revisión de B12a): que no quede un estado en el que no se puede ni encolar ni mandar.
  it('si el encolado falla, la oferta sigue ahí con su error (no queda sólo Confirmar)', async () => {
    const { user } = await primerIntentoPerdido()
    guardarPedidoOffline.mockResolvedValueOnce({ success: false, error: 'Stock insuficiente para algunos productos' })

    await user.click(screen.getByRole('button', { name: 'Guardar en el teléfono' }))

    await waitFor(() => expect(notify.error).toHaveBeenCalled())
    expect(screen.getByRole('button', { name: 'Guardar en el teléfono' })).toBeTruthy()
  })

  it('tocar el estado de pago (que la cola descarta) no hace desaparecer la oferta, y encola con la MISMA clave', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Pagado' }))
    expect(screen.getByRole('button', { name: 'Guardar en el teléfono' })).toBeTruthy()
    await user.click(screen.getByRole('button', { name: 'Guardar en el teléfono' }))

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][1]).toMatchObject({ claveDeAlta: claveAnterior })
    expect(guardarPedidoOffline.mock.calls[0][0]).toMatchObject({ estadoPago: 'pendiente' })
    expect(verificarClave).not.toHaveBeenCalled()
  })

  it('N3: tocar la forma de pago no hace desaparecer la oferta: encola con la forma NUEVA y la MISMA clave', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Transferencia' }))
    expect(screen.getByRole('button', { name: 'Guardar en el teléfono' })).toBeTruthy()
    await user.click(screen.getByRole('button', { name: 'Guardar en el teléfono' }))

    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    expect(guardarPedidoOffline.mock.calls[0][1]).toMatchObject({ claveDeAlta: claveAnterior })
    expect(guardarPedidoOffline.mock.calls[0][0]).toMatchObject({ formaPago: 'transferencia' })
    expect(verificarClave).not.toHaveBeenCalled()
  })

  it('un rechazo del servidor no ofrece la cola: avisa el error', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    mutateAlta.mockRejectedValueOnce(new RechazoDeNegocioError('Stock insuficiente para Coca 2.25'))

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(notify.error).toHaveBeenCalled())
    expect(screen.queryByRole('button', { name: 'Guardar en el teléfono' })).toBeNull()
    expect(guardarPedidoOffline).not.toHaveBeenCalled()
  })
})

/**
 * H3 de la revisión de B12a (ya pasaba; dejaba a D56 a medias): el alta directa no
 * tenía plazo. Con señal que no pasa datos el `fetch` queda colgado sin fallar, y
 * la oferta de la cola no aparecía nunca.
 */
describe('H3 — el alta directa tiene plazo', () => {
  afterEach(() => { vi.useRealTimers() })

  it('plazo vencido → queda en duda y se ofrece la cola → se encola con la MISMA clave', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime })
    montar()
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    // Señal que no pasa datos: el alta no contesta nunca.
    mutateAlta.mockImplementationOnce(() => new Promise(() => {}))

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))
    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(1))
    const intento = mutateAlta.mock.calls[0][0] as { offlineId: string; signal?: AbortSignal }
    expect(screen.queryByRole('button', { name: 'Guardar en el teléfono' })).toBeNull()

    await act(async () => { await vi.advanceTimersByTimeAsync(PLAZO_ALTA_DIRECTA_MS) })

    // El request colgado se corta, y el corte es «sin respuesta»: oferta, sin error.
    expect(intento.signal?.aborted).toBe(true)
    await user.click(await screen.findByRole('button', { name: 'Guardar en el teléfono' }))
    expect(notify.error).not.toHaveBeenCalled()
    await waitFor(() => expect(guardarPedidoOffline).toHaveBeenCalledTimes(1))
    // Un alta cortada pudo haber entrado: la cola va con su clave, y el replay
    // recibe ese pedido de la rama idempotente (no se duplica).
    expect(guardarPedidoOffline.mock.calls[0][1]).toMatchObject({ claveDeAlta: intento.offlineId })
  })
})

/**
 * M5 (#1603): preguntar por la clave mientras el primer intento sigue corriendo en
 * el servidor puede dar «no entró» (la fila sin COMMIT no se ve). Creérselo
 * olvidaba la clave, y la próxima alta del cliente acuñaba otra: dos pedidos.
 */
describe('M5 — un «no entró» recién terminado el intento no se cree', () => {
  it('al cerrar enseguida, el «no entró» no la olvida: el mismo pedido viaja con la MISMA clave', async () => {
    const { user, claveAnterior } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Cerrar alta' }))
    await waitFor(() => expect(verificarClave).toHaveBeenCalledWith(claveAnterior))
    await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
    await user.click(await screen.findByRole('button', { name: 'Armar' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(mutateAlta).toHaveBeenCalledTimes(2))
    expect(mutateAlta.mock.calls[1][0].offlineId).toBe(claveAnterior)
  })

  it('editado enseguida: no acuña otra clave con un «no entró» que no vale; pide esperar', async () => {
    const { user } = await primerIntentoPerdido()

    await user.click(screen.getByRole('button', { name: 'Cambiar nota' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    await waitFor(() => expect(avisos().some(a => /Esperá a tener señal/.test(a))).toBe(true))
    expect(mutateAlta).toHaveBeenCalledTimes(1)
  })
})
