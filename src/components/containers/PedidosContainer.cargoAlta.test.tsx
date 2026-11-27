/**
 * Cargo de envío en el cobro del alta.
 *
 * `crear_pedido_completo` guarda `total = productos + cargo` pero el carrito
 * manda sólo el total de productos. El cobro "pagado" del alta registraba ese
 * total pelado, y el pedido quedaba parcial debiendo el envío. El cobro tiene que
 * seguir al cargo que DEVUELVE el servidor, y avisar si difiere del mostrado.
 *
 * Se monta el container con la vista y el modal stubbeados: lo que se prueba es
 * el cableado del handler de guardado.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fechaLocalISO } from '../../utils/formatters'

// `vi.mock` se hoistea arriba de todo: las factories no pueden capturar consts
// de este módulo, así que los spies viven en `vi.hoisted`.
const { invalidateQueries, rpc, supabaseStub, registrarPago, notify, mutateAlta, politicasMock, clientesOperativosMock } = vi.hoisted(() => {
  const rpcFn = vi.fn()
  return {
    // La lista que ve el modal del alta (#1509): de ahí sale el saldo a favor mostrado.
    clientesOperativosMock: { valor: [] as Array<{ id: string; saldo_cuenta: number }> },
    registrarPago: vi.fn(),
    notify: { error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() },
    mutateAlta: vi.fn(),
    // Política de la sucursal: cobra 500 de envío bajo 20.000.
    politicasMock: {
      valor: { montoMinimoPedido: 20000, modoMinimoPedido: 'cargo', montoEnvioGratis: 0, cargoEnvioPedido: 500 },
    },
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
  useCrearPedidoMutation: () => ({ mutateAsync: mutateAlta, mutate: vi.fn(), isPending: false }),
  useCambiarEstadoMutation: () => emptyMutation,
  useAsignarTransportistaMutation: () => emptyMutation,
  useQuitarPedidoDeRecorridosMutation: () => emptyMutation,
  useVolverPedidoAPendienteMutation: () => emptyMutation,
  useEntregasMasivasMutation: () => emptyMutation,
  useCancelarPedidoMutation: () => emptyMutation,
  useRevertirCancelacionMutation: () => emptyMutation,
  useCambiarClientePedidoMutation: () => emptyMutation,
  usePagosMasivosMutation: () => emptyMutation,
  useEntregaYPagoMasivosMutation: () => emptyMutation,
  usePedidosAsignadosQuery: () => emptyQuery,
  useClientesQuery: () => emptyQuery,
  useClientesOperativosQuery: () => ({ ...emptyQuery, data: clientesOperativosMock.valor }),
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
  usePoliticasComercialesQuery: () => ({ politicas: politicasMock.valor }),
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
// El carrito: una línea de 12.000.
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: () => ({
    datosPrecio: { cargando: [], fallaron: [], sinSenal: [] }, entradasDatosPrecio: [], reintentarDatosPrecio: () => {},
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

// La vista sólo tiene que poder abrir el alta.
vi.mock('../vistas/VistaPedidos', () => ({
  default: ({ onNuevoPedido }: { onNuevoPedido?: () => void }) => (
    <button type="button" onClick={() => onNuevoPedido?.()}>Nuevo pedido</button>
  ),
}))

// El modal real no es lo que se prueba: estos botones arman el pedido como lo
// hacen sus callbacks y lo confirman.
vi.mock('../modals/ModalPedido', () => ({
  default: (p: {
    onClienteChange: (id: string) => void
    onAgregarItem: (id: string, cantidad?: number, precio?: number) => void
    onEstadoPagoChange: (e: string) => void
    onMontoPagadoChange: (m: number) => void
    onFechaChange: (fecha: string) => void
    onGuardar: () => void
  }) => (
    <>
      <button type="button" onClick={() => { p.onClienteChange('9'); p.onAgregarItem('7', 1, 12000) }}>Armar</button>
      <button type="button" onClick={() => p.onFechaChange('2026-01-15')}>Pedido de otro día</button>
      <button type="button" onClick={() => p.onEstadoPagoChange('pagado')}>Pagado</button>
      <button type="button" onClick={() => { p.onEstadoPagoChange('parcial'); p.onMontoPagadoChange(20000) }}>Parcial 20000</button>
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

async function altaCon(acciones: string[]) {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: 'Nuevo pedido' }))
  await user.click(await screen.findByRole('button', { name: 'Armar' }))
  for (const a of acciones) await user.click(screen.getByRole('button', { name: a }))
  await user.click(screen.getByRole('button', { name: 'Confirmar' }))
}

beforeEach(() => {
  vi.clearAllMocks()
  clientesOperativosMock.valor = []
  rpc.mockResolvedValue({ data: { success: true }, error: null })
  registrarPago.mockResolvedValue(undefined)
  mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500 })
})

describe('PedidosContainer — cobro del alta con cargo de envío', () => {
  it('alta pagada registra el pago por productos + cargo devuelto por el server', async () => {
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ pedidoId: '9', monto: 12500 })
    // El carrito mostraba el mismo envío: nada que avisar.
    expect(notify.warning).not.toHaveBeenCalled()
  })

  it('una respuesta sin cargo (server anterior) cobra sólo los productos y no avisa', async () => {
    mutateAlta.mockResolvedValue({ id: '9' })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12000 })
    expect(notify.warning).not.toHaveBeenCalled()
  })

  it('el pago parcial no pasa del total que guardó el server', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500 })
    await altaCon(['Parcial 20000'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12500 })
  })

  it('si el cargo del server difiere del mostrado avisa', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 800 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.warning).toHaveBeenCalled())
    const texto = String(notify.warning.mock.calls[0][0])
    expect(texto).toMatch(/envío/i)
    expect(texto).toMatch(/800/)
    expect(texto).toMatch(/500/)
    // Y el cobro sigue al server, no al carrito.
    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12800 })
  })

  it('si el server no cobra envío y el carrito lo mostraba, avisa que no lleva', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 0 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.warning).toHaveBeenCalled())
    expect(String(notify.warning.mock.calls[0][0])).toContain('El pedido #9 no lleva envío')
    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12000 })
  })
})

// #1293: la RPC sólo le acepta otra fecha que hoy al admin. Con la fecha del
// pedido, el cobro de un pedido de ayer fallaba después de crearlo.
describe('PedidosContainer — fecha del cobro del alta', () => {
  it('un pedido de otro día cobra con la fecha de hoy, que es cuando entra la plata', async () => {
    await altaCon(['Pedido de otro día', 'Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ pedidoId: '9', fecha: fechaLocalISO() })
    expect(mutateAlta.mock.calls[0][0]).toMatchObject({ fecha: '2026-01-15' })
  })
})

// #1469: la boleta nueva absorbe el saldo a favor del cliente al crearse. Lo
// absorbido ya está cobrado: el cobro del alta es lo que falta, y quien carga
// ve cuánto se aplicó.
describe('PedidosContainer — saldo a favor absorbido en el alta', () => {
  it('alta pagada cobra el total menos lo absorbido y lo avisa', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 400 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ pedidoId: '9', monto: 12100 })
    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    const texto = String(notify.success.mock.calls[0][0])
    expect(texto).toContain('#9')
    expect(texto).toMatch(/saldo a favor/)
    expect(texto).toMatch(/400/)
  })

  it('el parcial no pasa de lo que falta después del saldo a favor', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 400 })
    await altaCon(['Parcial 20000'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12100 })
  })

  // #1492: el replay idempotente (se perdió la respuesta y el alta se reintentó)
  // también descuenta lo absorbido, o el servidor rechaza el cobro.
  it('el replay idempotente de un alta pagada cobra el total menos lo absorbido', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '1', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 400 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ pedidoId: '9', monto: 12100 })
  })

  it('si el crédito saldó la boleta no registra ningún cobro', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 12500 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(registrarPago).not.toHaveBeenCalled()
  })

  it('el saldo que fue a boletas anteriores también se avisa, sin tocar el cobro', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorOtras: 30 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12500 })
    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(String(notify.success.mock.calls[0][0])).toMatch(/boletas anteriores/)
  })

  it('sin saldo a favor el aviso es el de siempre', async () => {
    await altaCon(['Pagado'])
    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(notify.success.mock.calls[0][0]).toBe('Pedido creado correctamente')
  })

  // #1503: si se registró menos de lo declarado, quien cobró lo tiene que saber:
  // la diferencia está en su mano y no en el sistema.
  it('alta pagada con saldo a favor avisa cuánto se registró y cuánto no', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 400 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.warning).toHaveBeenCalled())
    const texto = String(notify.warning.mock.calls[notify.warning.mock.calls.length - 1]?.[0])
    expect(texto).toMatch(/^En el pedido #9 se registró un cobro de \$\s12\.100,00/)
    expect(texto).toMatch(/Si cobraste \$\s12\.500,00, \$\s400,00 no quedaron registrados\./)
  })

  it('el parcial recortado por el saldo a favor avisa la diferencia', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 400 })
    await altaCon(['Parcial 20000'])

    await waitFor(() => expect(notify.warning).toHaveBeenCalled())
    expect(String(notify.warning.mock.calls[notify.warning.mock.calls.length - 1]?.[0]))
      .toMatch(/Si cobraste \$\s20\.000,00, \$\s7\.900,00 no quedaron registrados\./)
  })

  it('si el crédito saldó la boleta avisa que no se registró ningún cobro', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 12500 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.warning).toHaveBeenCalled())
    expect(String(notify.warning.mock.calls[notify.warning.mock.calls.length - 1]?.[0])).toMatch(/^En el pedido #9 no se registró ningún cobro/)
  })

  it('sin recorte no hay aviso de cobro', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(notify.warning.mock.calls.map(c => String(c[0])).filter(t => /se registró|no quedaron registrados/.test(t))).toEqual([])
  })
})

// #1509: el modal descuenta del cobro el saldo a favor que muestra (el cliente 9
// tiene $400 a favor en la lista que ve el modal). Con "Pagado", quien carga cobra
// eso, y es lo que se registra aunque el servidor absorba otra cosa.
describe('PedidosContainer — el cobro del alta sigue al saldo a favor mostrado', () => {
  const avisos = () => notify.warning.mock.calls.map(c => String(c[0]))

  beforeEach(() => {
    clientesOperativosMock.valor = [{ id: '9', saldo_cuenta: -400 }]
  })

  it('si el servidor absorbió lo mostrado, registra lo que se cobró y no avisa recorte', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 400 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12100 })
    await waitFor(() => expect(notify.success).toHaveBeenCalled())
    expect(avisos().filter(t => /no quedaron registrados|quedó debiendo/.test(t))).toEqual([])
  })

  it('si el servidor absorbió menos, registra lo cobrado (no el total) y avisa que la boleta quedó debiendo', async () => {
    // Otra alta del mismo cliente ya se llevó el crédito: el servidor no absorbió nada.
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 0 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12100 })
    await waitFor(() => expect(avisos().some(t => /quedó debiendo/.test(t))).toBe(true))
    expect(avisos().find(t => /quedó debiendo/.test(t)))
      .toMatch(/^El pedido #9 quedó debiendo \$\s400,00: el saldo a favor del cliente cubrió \$\s0,00 y no \$\s400,00/)
  })

  it('si el servidor absorbió más, registra lo que falta y avisa lo cobrado de más', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500, saldoAFavorAplicado: 500 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12000 })
    await waitFor(() => expect(avisos().some(t => /no quedaron registrados/.test(t))).toBe(true))
    expect(avisos().find(t => /no quedaron registrados/.test(t)))
      .toMatch(/Si cobraste \$\s12\.100,00, \$\s100,00 no quedaron registrados\./)
  })
})

// I2 de la revisión de B12a: el alta directa se reintenta con la MISMA clave (D56). Si el primer
// intento sí había entrado y alguien lo cambió (se editó, se canceló) antes del reintento, el server
// contesta el pedido que ya tenía y la pantalla decía «Pedido creado correctamente»: mentira, no se
// creó nada. Ahora dice qué pasó, con el mismo texto que el replay de la cola, y no lo da por creado.
describe('PedidosContainer — el alta directa devuelve un pedido propio que ya había entrado y cambió', () => {
  const avisos = () => notify.warning.mock.calls.map(c => String(c[0]))

  it('un pedido propio con otro total (se editó) no se anuncia como creado: avisa que ya estaba y cambió', async () => {
    // El carrito es de 12.000 y el pedido que contestó el server quedó en 8.000 + 500 de envío.
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 500, total: 8500 })
    await altaCon([])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    const texto = avisos().find(t => /ya estaba cargado/.test(t))!
    expect(texto).toContain('#9')
    expect(texto).toMatch(/ahora su total es \$\s8\.500,00/)
    expect(texto).toMatch(/No se cargó otro pedido y el cobro NO se registró/)
    expect(texto).toMatch(/Cobralo desde el pedido/)
    expect(notify.success).not.toHaveBeenCalled()
    // El aviso queda en pantalla hasta que se cierra (con el pedido ya cerrado, un toast de 5 s se pierde).
    expect(notify.warning.mock.calls.find(c => /ya estaba cargado/.test(String(c[0])))?.[1]).toEqual({ persist: true })
  })

  // Decisión 5 del dueño: con el pedido cambiado NO se registra ningún cobro, sea cual sea el estado de
  // pago que se tipeó, y no salen los avisos de recorte ni de envío (el único aviso es el de arriba).
  it.each([
    ['más chico (8.000 + 500)', { cargoEnvio: 500, total: 8500 }],
    ['cancelado (total 0)', { cargoEnvio: 0, total: 0 }],
    ['más grande (15.000 + 500)', { cargoEnvio: 500, total: 15500 }],
  ])('pedido %s con «Pagado»: no registra ningún cobro y avisa una sola cosa', async (_caso, resto) => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', ...resto })
    await altaCon(['Pagado'])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    expect(registrarPago).not.toHaveBeenCalled()
    expect(avisos()).toHaveLength(1)
    expect(notify.error).not.toHaveBeenCalled()
  })

  it('pedido cambiado con un parcial: tampoco registra ningún cobro', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 500, total: 8500 })
    await altaCon(['Parcial 20000'])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    expect(registrarPago).not.toHaveBeenCalled()
  })

  it('el mismo total (a un centavo) sí registra el cobro como siempre', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 500, total: 12500.01 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(avisos().filter(t => /ya estaba cargado/.test(t))).toEqual([])
  })

  // N2 de la revisión de C7: lo que se vio y se cobró es el total FINAL (12.000 + 500 de envío = 12.500).
  it('sólo subió el envío (12.000 + 800): es otro total final, no se registra ningún cobro y se avisa', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 800, total: 12800 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    expect(registrarPago).not.toHaveBeenCalled()
    expect(notify.success).not.toHaveBeenCalled()
    expect(avisos().find(t => /ya estaba cargado/.test(t))).toMatch(/ahora su total es \$\s12\.800,00/)
  })

  it('le sacaron el envío (12.000 + 0): tampoco se registra ningún cobro', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 0, total: 12000 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    expect(registrarPago).not.toHaveBeenCalled()
    expect(notify.success).not.toHaveBeenCalled()
  })

  it('mismo total final con otro reparto (11.700 + 800 = 12.500): es el mismo pedido, cobra y no avisa de cambio', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 800, total: 12500 })
    await altaCon(['Pagado'])

    await waitFor(() => expect(registrarPago).toHaveBeenCalledTimes(1))
    expect(registrarPago.mock.calls[0][0]).toMatchObject({ monto: 12500 })
    expect(avisos().filter(t => /ya estaba cargado/.test(t))).toEqual([])
  })

  it('un pedido propio cancelado (total 0) tampoco se anuncia como creado', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 0, total: 0 })
    await altaCon([])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    expect(notify.success).not.toHaveBeenCalled()
  })

  it('el replay de un pedido propio que no cambió (mismo cliente, mismo total) sigue diciendo que se creó', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 500, total: 12500 })
    await altaCon([])

    await waitFor(() => expect(notify.success).toHaveBeenCalledWith('Pedido creado correctamente'))
    expect(avisos().filter(t => /ya estaba cargado/.test(t))).toEqual([])
  })

  it('un alta nueva (no idempotente) con otro total que el del carrito sigue como siempre', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 8500 })
    await altaCon([])

    await waitFor(() => expect(notify.success).toHaveBeenCalledWith('Pedido creado correctamente'))
    expect(avisos().filter(t => /ya estaba cargado/.test(t))).toEqual([])
  })
})

// H4 de la revisión de C7: lo que el aviso del pedido que ya había entrado no cubría.
describe('PedidosContainer — el alta directa que devuelve un pedido ya cargado: los cabos sueltos (H4)', () => {
  const avisos = () => notify.warning.mock.calls.map(c => String(c[0]))

  // (a) El pedido no se pudo leer (lo más probable con la señal floja que provocó el reintento): llega
  // sin cliente, con el total de la RPC. La clave es por intención y la RPC sólo le contesta a quien lo
  // cargó (mig 519): es el propio. Con otro total, igual avisa.
  it('(a) si la fila no se pudo leer y el total de la RPC no es el del carrito, avisa igual', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: null, cargoEnvio: 500, total: 8500 })
    await altaCon([])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    expect(notify.success).not.toHaveBeenCalled()
  })

  it('(a) si la fila no se pudo leer y el total de la RPC es el del carrito, sigue diciendo que se creó', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: null, cargoEnvio: 500, total: 12500 })
    await altaCon([])

    await waitFor(() => expect(notify.success).toHaveBeenCalledWith('Pedido creado correctamente'))
    expect(avisos().filter(t => /ya estaba cargado/.test(t))).toEqual([])
  })

  // (b) El saldo a favor aplicado se sigue diciendo junto al aviso.
  it('(b) el saldo a favor aplicado no se pierde: va en el mismo aviso', async () => {
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 500, total: 8500, saldoAFavorAplicado: 400 })
    await altaCon([])

    await waitFor(() => expect(avisos().some(t => /ya estaba cargado/.test(t))).toBe(true))
    const texto = avisos().find(t => /ya estaba cargado/.test(t))!
    expect(texto).toMatch(/saldo a favor/)
    expect(texto).toMatch(/400/)
    expect(texto).toMatch(/el cobro NO se registró/)
    expect(notify.success).not.toHaveBeenCalled()
  })

  // (c) Si el server rechaza el cobro del reintento, el error no puede decir «se creó».
  it('(c) si el cobro del reintento falla, el error dice que el pedido ya existía, no que se creó', async () => {
    // Mismo total: el cobro se intenta como siempre, y si el server lo rechaza el error dice «ya existía».
    mutateAlta.mockResolvedValue({ id: '9', idempotente: true, clienteId: '9', cargoEnvio: 500, total: 12500 })
    registrarPago.mockRejectedValue(new Error('El pedido ya está pagado'))
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.error).toHaveBeenCalled())
    const texto = String(notify.error.mock.calls[0][0])
    expect(texto).toMatch(/^El pedido #9 ya existía, pero no se pudo registrar el cobro/)
    expect(texto).not.toMatch(/se creó/)
  })

  it('(c) un alta nueva con el cobro rechazado sigue diciendo que se creó', async () => {
    mutateAlta.mockResolvedValue({ id: '9', cargoEnvio: 500, total: 12500 })
    registrarPago.mockRejectedValue(new Error('El pedido ya está pagado'))
    await altaCon(['Pagado'])

    await waitFor(() => expect(notify.error).toHaveBeenCalled())
    expect(String(notify.error.mock.calls[0][0])).toMatch(/^El pedido #9 se creó, pero no se pudo registrar el cobro/)
  })
})
