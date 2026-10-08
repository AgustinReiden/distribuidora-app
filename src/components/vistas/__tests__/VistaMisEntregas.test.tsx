/**
 * Caracterización de `VistaMisEntregas` ("Mis entregas", mig 179).
 *
 * Fija, por rol ARIA y por texto, lo que ve hoy un preventista puro (consulta lo
 * suyo: `p_preventista_id: null`, sin selector) y un admin (puede elegir a quién
 * mirar). Sirve para probar que un cambio posterior no altera lo que ya hacía
 * la pantalla para esos roles.
 *
 * #723: el transportista ve lo que REPARTIÓ (`jornadas_transportista`, por
 * `pedidos.transportista_id`), y el preventista que también reparte elige entre
 * lo que vendió y lo que repartió.
 *
 * Se mockean el cliente supabase (`supabase.rpc`) y los contextos; los hooks de
 * TanStack Query (`useJornadasPreventistaQuery`, `useJornadaDetalleQuery`) y las
 * tarjetas son los reales, así que lo que se afirma es qué RPC sale y con qué.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { JornadasResultado, PedidoDelDia } from '../../../hooks/queries/useJornadasPreventistaQuery'

const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }))

vi.mock('../../../hooks/supabase/base', () => ({
  supabase: { rpc: rpcMock },
  setErrorNotifier: vi.fn(),
  notifyError: vi.fn(),
  handleSupabaseError: vi.fn(),
}))

const roles = vi.hoisted(() => ({
  isAdmin: false,
  isEncargado: false,
  isPreventista: true,
  isTransportista: false,
  rolesEfectivos: ['preventista'] as string[],
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => roles,
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

const preventistasMock = vi.hoisted(() => ({
  data: [] as Array<{ id: string; nombre: string }>,
  rol: undefined as string | undefined,
}))

vi.mock('../../../hooks/queries', () => ({
  useUsuariosByRolQuery: (rol: string) => {
    preventistasMock.rol = rol
    return { data: rol ? preventistasMock.data : undefined }
  },
}))

import VistaMisEntregas from '../VistaMisEntregas'

const DIA_RECIENTE = '2026-10-05'
const DIA_ANTERIOR = '2026-10-02'

const JORNADAS: JornadasResultado = {
  preventista_id: 'prev-1',
  nombre: 'Pablo Preventista',
  desde: '2026-09-24',
  hasta: '2026-10-07',
  dias: [
    {
      dia: DIA_RECIENTE,
      total: 4,
      entregados: 3,
      con_salvedad: 1,
      rechazados: 1,
      administrativos: 0,
      monto_entregado: 30000,
      monto_rechazado: 8000,
    },
    {
      dia: DIA_ANTERIOR,
      total: 2,
      entregados: 2,
      con_salvedad: 0,
      rechazados: 0,
      administrativos: 0,
      monto_entregado: 12000,
      monto_rechazado: 0,
    },
  ],
  totales: { entregados: 5, rechazados: 1, pct_rechazo: 17, monto_rechazado: 8000 },
  pendientes: { total: 0, monto: 0, mas_viejo: null },
}

const DETALLE_DIA: PedidoDelDia[] = [
  {
    pedido_id: 101,
    cliente: 'Kiosco El Sol',
    monto: 10000,
    desenlace: 'entregado',
    estado: 'entregado',
    fecha_pedido: '2026-10-04',
    motivo_tipo: null,
    motivo_nota: null,
    transportista: 'Tito Transportista',
    salvedades: [],
  },
  {
    pedido_id: 102,
    cliente: 'Almacén La Esquina',
    monto: 8000,
    desenlace: 'rechazado',
    estado: 'cancelado',
    fecha_pedido: '2026-10-04',
    motivo_tipo: null,
    motivo_nota: null,
    transportista: 'Tito Transportista',
    salvedades: [],
  },
]

function llamadas(nombre: string) {
  return rpcMock.mock.calls.filter(([n]) => n === nombre)
}

function renderVista() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } })
  return render(
    <QueryClientProvider client={client}>
      <VistaMisEntregas />
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  rpcMock.mockReset()
  rpcMock.mockImplementation((nombre: string) => {
    if (nombre === 'jornadas_preventista') return Promise.resolve({ data: JORNADAS, error: null })
    if (nombre === 'jornada_preventista_detalle') return Promise.resolve({ data: DETALLE_DIA, error: null })
    return Promise.resolve({ data: null, error: null })
  })
  roles.isAdmin = false
  roles.isEncargado = false
  roles.isPreventista = true
  roles.isTransportista = false
  roles.rolesEfectivos = ['preventista']
  preventistasMock.data = []
  preventistasMock.rol = undefined
})

describe('VistaMisEntregas — preventista puro', () => {
  it('pide las jornadas con p_preventista_id null (el usuario logueado)', async () => {
    renderVista()
    await screen.findByText('entregados')

    const jornadas = llamadas('jornadas_preventista')
    expect(jornadas).toHaveLength(1)
    const args = jornadas[0][1] as { p_desde: string; p_hasta: string; p_preventista_id: string | null }
    expect(args.p_preventista_id).toBeNull()
    expect(typeof args.p_desde).toBe('string')
    expect(typeof args.p_hasta).toBe('string')
    expect(args.p_desde <= args.p_hasta).toBe(true)
    expect(Object.keys(args).sort()).toEqual(['p_desde', 'p_hasta', 'p_preventista_id'])
  })

  it('muestra el título "Mis entregas" y el subtítulo', async () => {
    renderVista()
    await screen.findByText('entregados')

    expect(screen.getByRole('heading', { level: 1, name: 'Mis entregas' })).toBeInTheDocument()
    expect(screen.getByText('Qué pasó con los pedidos que tomaste, día por día.')).toBeInTheDocument()
  })

  it('no muestra el selector "Elegir preventista" ni pide la lista de preventistas', async () => {
    // Aunque el hook devolviera preventistas, el preventista no debe verlos.
    preventistasMock.data = [{ id: 'prev-2', nombre: 'Otro Preventista' }]
    renderVista()
    await screen.findByText('entregados')

    expect(screen.queryByRole('combobox', { name: 'Elegir preventista' })).toBeNull()
    expect(screen.queryByLabelText('Elegir preventista')).toBeNull()
    expect(preventistasMock.rol).toBe('')
  })

  it('muestra los totales: entregados, no entregados y % de rechazo', async () => {
    renderVista()
    await screen.findByText('entregados')

    const entregados = screen.getByText('entregados').parentElement as HTMLElement
    expect(within(entregados).getByText('5')).toBeInTheDocument()
    const noEntregados = screen.getByText('no entregados').parentElement as HTMLElement
    expect(within(noEntregados).getByText('1')).toBeInTheDocument()
    const rechazo = screen.getByText('de rechazo').parentElement as HTMLElement
    expect(within(rechazo).getByText('17%')).toBeInTheDocument()
    expect(screen.getByText(/que no llegaron a destino/)).toBeInTheDocument()
  })

  it('el primer día arranca expandido y pide su detalle con { p_dia, p_preventista_id: null }', async () => {
    renderVista()

    await waitFor(() => expect(llamadas('jornada_preventista_detalle')).toHaveLength(1))
    expect(llamadas('jornada_preventista_detalle')[0][1]).toEqual({
      p_dia: DIA_RECIENTE,
      p_preventista_id: null,
    })

    // El detalle se ve: clientes de la jornada.
    expect(await screen.findByText('Kiosco El Sol')).toBeInTheDocument()
    expect(screen.getByText('Almacén La Esquina')).toBeInTheDocument()

    // Solo el primer día está abierto; el segundo no pidió detalle.
    const botones = screen.getAllByRole('button', { expanded: true })
    expect(botones).toHaveLength(1)
  })

  it('expandir el segundo día pide su detalle recién entonces', async () => {
    const user = userEvent.setup()
    renderVista()
    await screen.findByText('Kiosco El Sol')
    expect(llamadas('jornada_preventista_detalle')).toHaveLength(1)

    const colapsado = screen.getAllByRole('button', { expanded: false })
      .find(b => /2 pedidos/.test(b.textContent ?? ''))
    expect(colapsado).toBeDefined()
    await user.click(colapsado!)

    await waitFor(() => expect(llamadas('jornada_preventista_detalle')).toHaveLength(2))
    expect(llamadas('jornada_preventista_detalle')[1][1]).toEqual({
      p_dia: DIA_ANTERIOR,
      p_preventista_id: null,
    })
  })

  it('no ve el selector entre lo que vendió y lo que repartió', async () => {
    renderVista()
    await screen.findByText('entregados')
    expect(screen.queryByRole('button', { name: 'Lo que vendí' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Lo que repartí' })).toBeNull()
    expect(llamadas('jornadas_transportista')).toHaveLength(0)
  })

  it('con jornadas vacías muestra "Sin movimientos"', async () => {
    rpcMock.mockImplementation((nombre: string) =>
      nombre === 'jornadas_preventista'
        ? Promise.resolve({
            data: { ...JORNADAS, dias: [], totales: { entregados: 0, rechazados: 0, pct_rechazo: 0, monto_rechazado: 0 } },
            error: null,
          })
        : Promise.resolve({ data: [], error: null }),
    )
    renderVista()

    expect(await screen.findByText('Sin movimientos')).toBeInTheDocument()
    expect(llamadas('jornada_preventista_detalle')).toHaveLength(0)
  })
})

describe('VistaMisEntregas — admin', () => {
  beforeEach(() => {
    roles.isAdmin = true
    // En el front isPreventista es el rol PRIMARIO (App.tsx), no es_preventista().
    roles.isPreventista = false
    roles.rolesEfectivos = ['admin']
    preventistasMock.data = [
      { id: 'prev-1', nombre: 'Pablo Preventista' },
      { id: 'prev-2', nombre: 'Paula Preventista' },
    ]
  })

  it('muestra el selector "Elegir preventista" con "Mis pedidos" y los preventistas', async () => {
    renderVista()
    await screen.findByText('entregados')

    const select = screen.getByRole('combobox', { name: 'Elegir preventista' })
    expect(preventistasMock.rol).toBe('preventista')
    const opciones = within(select).getAllByRole('option').map(o => o.textContent)
    expect(opciones).toEqual(['Mis pedidos', 'Pablo Preventista', 'Paula Preventista'])
    expect(select).toHaveValue('')
  })

  it('arranca con p_preventista_id null y el título pasa a "Entregas de <nombre>"', async () => {
    renderVista()
    await screen.findByText('entregados')

    expect(llamadas('jornadas_preventista')[0][1]).toMatchObject({ p_preventista_id: null })
    expect(screen.getByRole('heading', { level: 1, name: 'Entregas de Pablo Preventista' })).toBeInTheDocument()
  })

  it('elegir un preventista vuelve a pedir las jornadas con su id (y el detalle también)', async () => {
    const user = userEvent.setup()
    renderVista()
    await screen.findByText('entregados')
    expect(llamadas('jornadas_preventista')).toHaveLength(1)

    await user.selectOptions(screen.getByRole('combobox', { name: 'Elegir preventista' }), 'prev-2')

    await waitFor(() => expect(llamadas('jornadas_preventista')).toHaveLength(2))
    expect(llamadas('jornadas_preventista')[1][1]).toMatchObject({ p_preventista_id: 'prev-2' })

    await waitFor(() => {
      const detalles = llamadas('jornada_preventista_detalle')
      expect(detalles[detalles.length - 1][1]).toEqual({ p_dia: DIA_RECIENTE, p_preventista_id: 'prev-2' })
    })
  })

  it('volver a "Mis pedidos" restituye p_preventista_id null', async () => {
    const user = userEvent.setup()
    renderVista()
    await screen.findByText('entregados')
    const select = screen.getByRole('combobox', { name: 'Elegir preventista' })

    await user.selectOptions(select, 'prev-2')
    await waitFor(() => expect(llamadas('jornadas_preventista')).toHaveLength(2))

    await user.selectOptions(select, '')
    expect(select).toHaveValue('')
    // gcTime 0: la consulta "yo" ya no está en caché, así que vuelve a salir.
    await waitFor(() => expect(llamadas('jornadas_preventista')).toHaveLength(3))
    expect(llamadas('jornadas_preventista')[2][1]).toMatchObject({ p_preventista_id: null })
  })

  it('con rol extra de transportista sigue igual: sin selector vendí/repartí, sólo lo vendido', async () => {
    roles.isTransportista = true
    roles.rolesEfectivos = ['admin', 'transportista']
    renderVista()
    await screen.findByText('entregados')
    expect(screen.queryByRole('button', { name: 'Lo que repartí' })).toBeNull()
    expect(screen.getByRole('combobox', { name: 'Elegir preventista' })).toBeInTheDocument()
    expect(llamadas('jornadas_transportista')).toHaveLength(0)
  })

  it('el encargado también ve el selector', async () => {
    roles.isAdmin = false
    roles.isEncargado = true
    roles.rolesEfectivos = ['encargado']
    renderVista()
    await screen.findByText('entregados')

    expect(screen.getByRole('combobox', { name: 'Elegir preventista' })).toBeInTheDocument()
    expect(preventistasMock.rol).toBe('preventista')
  })
})

// =============================================================================
// #723 — TRANSPORTISTA
// =============================================================================

const JORNADAS_T: JornadasResultado = {
  ...JORNADAS,
  preventista_id: undefined,
  transportista_id: 'trans-1',
  nombre: 'Tito Transportista',
}

const DETALLE_T: PedidoDelDia[] = DETALLE_DIA.map(p => ({
  ...p,
  transportista: null,
  vendedor: 'Pablo Preventista',
}))

function conRpcsDeReparto() {
  rpcMock.mockImplementation((nombre: string) => {
    if (nombre === 'jornadas_preventista') return Promise.resolve({ data: JORNADAS, error: null })
    if (nombre === 'jornada_preventista_detalle') return Promise.resolve({ data: DETALLE_DIA, error: null })
    if (nombre === 'jornadas_transportista') return Promise.resolve({ data: JORNADAS_T, error: null })
    if (nombre === 'jornada_transportista_detalle') return Promise.resolve({ data: DETALLE_T, error: null })
    return Promise.resolve({ data: null, error: null })
  })
}

describe('VistaMisEntregas — transportista puro (#723)', () => {
  beforeEach(() => {
    roles.isPreventista = false
    roles.isTransportista = true
    roles.rolesEfectivos = ['transportista']
    conRpcsDeReparto()
  })

  it('pide lo que repartió (jornadas_transportista, null = él) y nunca lo vendido', async () => {
    renderVista()
    await screen.findByText('entregados')

    const jornadas = llamadas('jornadas_transportista')
    expect(jornadas).toHaveLength(1)
    const args = jornadas[0][1] as Record<string, unknown>
    expect(Object.keys(args).sort()).toEqual(['p_desde', 'p_hasta', 'p_transportista_id'])
    expect(args.p_transportista_id).toBeNull()
    expect(llamadas('jornadas_preventista')).toHaveLength(0)
    expect(llamadas('jornada_preventista_detalle')).toHaveLength(0)
  })

  it('el título es "Mis entregas" y el subtítulo habla de lo que llevó', async () => {
    renderVista()
    await screen.findByText('entregados')

    expect(screen.getByRole('heading', { level: 1, name: 'Mis entregas' })).toBeInTheDocument()
    expect(screen.getByText('Qué pasó con los pedidos que llevaste, día por día.')).toBeInTheDocument()
    expect(screen.queryByText('Qué pasó con los pedidos que tomaste, día por día.')).toBeNull()
  })

  it('no tiene selector de preventista ni de vendí/repartí, y no pide la lista de preventistas', async () => {
    preventistasMock.data = [{ id: 'prev-2', nombre: 'Otro Preventista' }]
    renderVista()
    await screen.findByText('entregados')

    expect(screen.queryByRole('combobox', { name: 'Elegir preventista' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Lo que vendí' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Lo que repartí' })).toBeNull()
    expect(preventistasMock.rol).toBe('')
  })

  it('muestra sus totales', async () => {
    renderVista()
    await screen.findByText('entregados')
    const entregados = screen.getByText('entregados').parentElement as HTMLElement
    expect(within(entregados).getByText('5')).toBeInTheDocument()
    const rechazo = screen.getByText('de rechazo').parentElement as HTMLElement
    expect(within(rechazo).getByText('17%')).toBeInTheDocument()
  })

  it('el detalle del día sale de jornada_transportista_detalle y dice quién vendió, no quién repartió', async () => {
    renderVista()

    await waitFor(() => expect(llamadas('jornada_transportista_detalle')).toHaveLength(1))
    expect(llamadas('jornada_transportista_detalle')[0][1]).toEqual({
      p_dia: DIA_RECIENTE,
      p_transportista_id: null,
    })
    expect(await screen.findByText('Kiosco El Sol')).toBeInTheDocument()
    expect(screen.getAllByText('Vendió Pablo Preventista')).toHaveLength(2)
    expect(screen.queryByText(/^Repartió/)).toBeNull()
  })

  it('sin movimientos lo dice en términos de reparto', async () => {
    rpcMock.mockImplementation((nombre: string) =>
      nombre === 'jornadas_transportista'
        ? Promise.resolve({
            data: { ...JORNADAS_T, dias: [], totales: { entregados: 0, rechazados: 0, pct_rechazo: 0, monto_rechazado: 0 } },
            error: null,
          })
        : Promise.resolve({ data: [], error: null }),
    )
    renderVista()
    expect(await screen.findByText('Sin movimientos')).toBeInTheDocument()
    expect(screen.getByText('No hay pedidos que hayas repartido con desenlace en los últimos 14 días.')).toBeInTheDocument()
  })
})

describe('VistaMisEntregas — preventista que también reparte (#723)', () => {
  beforeEach(() => {
    roles.isPreventista = true
    roles.isTransportista = true
    roles.rolesEfectivos = ['preventista', 'transportista']
    conRpcsDeReparto()
  })

  it('arranca en lo que vendió, como el preventista puro', async () => {
    renderVista()
    await screen.findByText('entregados')

    expect(screen.getByRole('button', { name: 'Lo que vendí' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: 'Lo que repartí' })).toHaveAttribute('aria-pressed', 'false')
    expect(llamadas('jornadas_preventista')).toHaveLength(1)
    expect(llamadas('jornadas_preventista')[0][1]).toMatchObject({ p_preventista_id: null })
    expect(llamadas('jornadas_transportista')).toHaveLength(0)
    expect(screen.getByText('Qué pasó con los pedidos que tomaste, día por día.')).toBeInTheDocument()
  })

  it('"Lo que repartí" pasa a las RPC de reparto, con el detalle incluido', async () => {
    const user = userEvent.setup()
    renderVista()
    await screen.findByText('Kiosco El Sol')

    await user.click(screen.getByRole('button', { name: 'Lo que repartí' }))

    await waitFor(() => expect(llamadas('jornadas_transportista')).toHaveLength(1))
    expect(llamadas('jornadas_transportista')[0][1]).toMatchObject({ p_transportista_id: null })
    await waitFor(() => expect(llamadas('jornada_transportista_detalle')).toHaveLength(1))
    expect(llamadas('jornada_transportista_detalle')[0][1]).toEqual({ p_dia: DIA_RECIENTE, p_transportista_id: null })
    expect(screen.getByRole('button', { name: 'Lo que repartí' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByText('Qué pasó con los pedidos que llevaste, día por día.')).toBeInTheDocument()
    expect((await screen.findAllByText('Vendió Pablo Preventista')).length).toBeGreaterThan(0)
  })
})
