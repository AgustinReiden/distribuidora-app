/**
 * Caracterización de `VistaRendiciones` (resumen auto-calculado + cierre +
 * resolución de disconformidad).
 *
 * Fija, por rol ARIA y por texto, lo que hace hoy la pantalla: qué RPC sale al
 * montar y con qué argumentos, el filtro de transportista, qué acción ofrece
 * cada tarjeta según su estado, y el detalle que se pide al expandir.
 *
 * Hasta #724 la vista no leía banderas de rol: sólo la abrían admin y
 * encargado. Desde #724 también entra el transportista, a ver sólo su fila y
 * sin acciones de control, así que `useAuthData` se mockea: por defecto como
 * admin (lo que la caracterización de abajo fija), y como transportista en su
 * bloque al final. Se mockean el cliente supabase, `useNotification`, las
 * consultas de transportistas/clientes y los tres modales lazy (se afirma qué
 * props reciben, no cómo se dibujan). `useRendiciones` es el hook real.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { rpcMock, notifyMock } = vi.hoisted(() => ({
  rpcMock: vi.fn(),
  notifyMock: { success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() },
}))

// El barrel de hooks/supabase arrastra SucursalContext, que importa lib/supabase
// y crea el cliente real (sin .env: "supabaseUrl is required").
vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: rpcMock },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

vi.mock('../../../hooks/supabase/base', () => ({
  supabase: { rpc: rpcMock },
  setErrorNotifier: vi.fn(),
  notifyError: vi.fn(),
  handleSupabaseError: vi.fn(),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => notifyMock,
}))

const roles = vi.hoisted(() => ({
  isAdmin: true,
  isEncargado: false,
  isPreventista: false,
  isTransportista: false,
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => roles,
}))

const TRANSPORTISTAS = [
  { id: 'tr-1', nombre: 'Tito Transportista' },
  { id: 'tr-2', nombre: 'Pedro Chofer' },
]

vi.mock('../../../hooks/queries', () => ({
  useTransportistasQuery: () => ({ data: TRANSPORTISTAS }),
  useClientesQuery: () => ({ data: [] }),
}))

// Stubs de los modales lazy: dejan ver las props y disparar el callback.
vi.mock('../../modals/ModalCerrarRendicion', () => ({
  default: (props: {
    fecha: string
    transportistaNombre: string
    totalCobrado: number
    totalEntregado: number
    observacionesPrevias?: string | null
    onConfirmar: (e: 'confirmada' | 'disconformidad', o: string | null, g: unknown[]) => void
    onClose: () => void
  }) => (
    <div role="dialog" aria-label="Cerrar rendición">
      <p>cerrar {props.fecha} {props.transportistaNombre}</p>
      <p>previas: {props.observacionesPrevias ?? '-'}</p>
      <button onClick={() => props.onConfirmar('confirmada', 'todo ok', [])}>stub-confirmar</button>
      <button onClick={() => props.onConfirmar('disconformidad', 'falta plata', [])}>stub-disconformidad</button>
      <button onClick={props.onClose}>stub-cerrar-modal</button>
    </div>
  ),
}))
vi.mock('../../modals/ModalResolverRendicion', () => ({
  default: (props: {
    fecha: string
    transportistaNombre: string
    observacionesPrevias?: string | null
    onResolver: (o: string) => void
    onClose: () => void
  }) => (
    <div role="dialog" aria-label="Resolver rendición">
      <p>resolver {props.fecha} {props.transportistaNombre}</p>
      <p>previas: {props.observacionesPrevias ?? '-'}</p>
      <button onClick={() => props.onResolver('se devolvió la diferencia')}>stub-resolver</button>
      <button onClick={props.onClose}>stub-cerrar-modal</button>
    </div>
  ),
}))
vi.mock('../../modals/ModalCtaCtePendiente', () => ({
  default: (props: { fechaDesde: string; fechaHasta: string; transportistaId: string; onClose: () => void }) => (
    <div role="dialog" aria-label="Cta cte pendiente">
      <p>ctacte {props.fechaDesde} {props.fechaHasta} [{props.transportistaId}]</p>
    </div>
  ),
}))
vi.mock('../../modals/ModalFichaCliente', () => ({
  default: () => <div role="dialog" aria-label="Ficha cliente" />,
}))

import VistaRendiciones from '../VistaRendiciones'
import { fechaLocalISO } from '../../../utils/formatters'

function fila(overrides: Record<string, unknown>) {
  return {
    fecha: '2026-10-05',
    transportista_id: 'tr-1',
    transportista_nombre: 'Tito Transportista',
    total_efectivo: 50000,
    total_transferencia: 20000,
    total_cheque: 0,
    total_cuenta_corriente: 0,
    total_tarjeta: 0,
    total_otros: 0,
    total_adelanto_sueldo: 0,
    total_general: 70000,
    total_entregas: 60000,
    total_ctascte: 10000,
    cantidad_pedidos: 3,
    total_entregado: 65000,
    total_gastos: 0,
    cantidad_gastos: 0,
    estado: 'pendiente',
    observaciones: null,
    controlada: false,
    controlada_at: null,
    controlada_por_nombre: null,
    resuelta_at: null,
    resuelta_por_nombre: null,
    ...overrides,
  }
}

const PENDIENTE = fila({})
const CONFIRMADA = fila({
  fecha: '2026-10-04',
  transportista_id: 'tr-2',
  transportista_nombre: 'Pedro Chofer',
  estado: 'confirmada',
  controlada: true,
  controlada_at: '2026-10-05T12:00:00Z',
  controlada_por_nombre: 'Ana Admin',
})
const DISCONFORME = fila({
  fecha: '2026-10-03',
  transportista_id: 'tr-1',
  estado: 'disconformidad',
  controlada: true,
  controlada_at: '2026-10-04T12:00:00Z',
  controlada_por_nombre: 'Ana Admin',
  observaciones: 'Faltan 5000',
})
const RESUELTA = fila({
  fecha: '2026-10-02',
  transportista_id: 'tr-2',
  transportista_nombre: 'Pedro Chofer',
  estado: 'resuelta',
  resuelta_at: '2026-10-03T12:00:00Z',
  resuelta_por_nombre: 'Ana Admin',
})

const DETALLE = [
  {
    cliente_id: 7,
    cliente_nombre: 'Kiosco El Sol',
    cobrado_por_id: 'tr-1',
    cobrado_por: 'Tito Transportista',
    total: 70000,
    total_entregas: 60000,
    total_ctascte: 10000,
    efectivo: 50000,
    transferencia: 20000,
    cheque: 0,
    tarjeta: 0,
    otros: 0,
    cantidad_pagos: 2,
  },
]

let resumenes: unknown[] = []

function llamadas(nombre: string) {
  return rpcMock.mock.calls.filter(([n]) => n === nombre)
}

/** Raíz de la tarjeta de un resumen: el contenedor con el borde de estado. */
function tarjeta(nombre: string, fecha: string): HTMLElement {
  const [y, m, d] = fecha.split('-')
  const fechaCorta = `${d}/${m}/${y}`
  const candidatas = screen
    .getAllByText(nombre, { selector: 'span' })
    .map(el => el.closest('.border-l-4') as HTMLElement | null)
    .filter((el): el is HTMLElement => el !== null)
  const t = candidatas.find(el => within(el).queryByText(fechaCorta))
  if (!t) throw new Error(`No hay tarjeta de ${nombre} del ${fechaCorta}`)
  return t
}

// Los <label> de los filtros no están asociados a su control (sin htmlFor), así
// que getByLabelText no los encuentra: se llega por las opciones que cada uno tiene.
const filtroTransportista = () => screen.getByRole('option', { name: 'Todos' }).closest('select') as HTMLSelectElement
const filtroEstado = () => screen.getByRole('option', { name: 'Todas' }).closest('select') as HTMLSelectElement

async function renderVista(titulo = 'Rendiciones Diarias') {
  render(<VistaRendiciones />)
  await screen.findByRole('heading', { name: titulo })
  await waitFor(() => expect(llamadas('obtener_resumen_rendiciones').length).toBeGreaterThan(0))
}

beforeEach(() => {
  vi.clearAllMocks()
  roles.isAdmin = true
  roles.isEncargado = false
  roles.isPreventista = false
  roles.isTransportista = false
  resumenes = [PENDIENTE, CONFIRMADA, DISCONFORME, RESUELTA]
  rpcMock.mockReset()
  rpcMock.mockImplementation((nombre: string) => {
    if (nombre === 'obtener_resumen_rendiciones') return Promise.resolve({ data: resumenes, error: null })
    if (nombre === 'obtener_detalle_rendicion') return Promise.resolve({ data: DETALLE, error: null })
    return Promise.resolve({ data: null, error: null })
  })
})

describe('VistaRendiciones — carga inicial', () => {
  it('al montar pide el resumen de la última semana, sin filtrar transportista', async () => {
    await renderVista()

    const resumen = llamadas('obtener_resumen_rendiciones')
    expect(resumen).toHaveLength(1)
    const args = resumen[0][1] as { p_fecha_desde: string; p_fecha_hasta: string; p_transportista_id: string | null }
    expect(Object.keys(args).sort()).toEqual(['p_fecha_desde', 'p_fecha_hasta', 'p_transportista_id'])
    expect(args.p_transportista_id).toBeNull()
    expect(args.p_fecha_hasta).toBe(fechaLocalISO())
    const dias = (Date.parse(args.p_fecha_hasta) - Date.parse(args.p_fecha_desde)) / 86_400_000
    expect(dias).toBe(7)
  })

  it('muestra título, descripción y los inputs de fecha con ese rango', async () => {
    await renderVista()
    await screen.findAllByText('Tito Transportista', { selector: 'span' })

    expect(screen.getByRole('heading', { level: 1, name: 'Rendiciones Diarias' })).toBeInTheDocument()
    expect(screen.getByText(/Resumen auto-calculado por transportista y día/)).toBeInTheDocument()
    const args = llamadas('obtener_resumen_rendiciones')[0][1] as { p_fecha_desde: string; p_fecha_hasta: string }
    const [desde, hasta] = Array.from(document.querySelectorAll('input[type="date"]'))
    expect(desde).toHaveValue(args.p_fecha_desde)
    expect(hasta).toHaveValue(args.p_fecha_hasta)
  })

  it('dibuja una tarjeta por resumen con su estado y los contadores', async () => {
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    expect(tarjeta('Tito Transportista', '2026-10-05')).toHaveTextContent('Pendiente')
    expect(tarjeta('Pedro Chofer', '2026-10-04')).toHaveTextContent('Confirmada')
    expect(tarjeta('Tito Transportista', '2026-10-03')).toHaveTextContent('Disconformidad')
    expect(tarjeta('Pedro Chofer', '2026-10-02')).toHaveTextContent('Resuelta')

    // "Disconformidad" también es el texto de una tarjeta: el contador es el <p> con número al lado.
    const stat = (label: string) => screen
      .getAllByText(label, { selector: 'p' })
      .find(el => el.nextElementSibling?.tagName === 'P' && el.parentElement?.className.includes('shadow-sm'))
      ?.parentElement as HTMLElement
    expect(within(stat('Total')).getByText('4')).toBeInTheDocument()
    expect(within(stat('Confirmadas')).getByText('1')).toBeInTheDocument()
    expect(within(stat('Pendientes')).getByText('1')).toBeInTheDocument()
    expect(within(stat('Disconformidad')).getByText('1')).toBeInTheDocument()
  })

  it('sin resultados muestra el vacío', async () => {
    resumenes = []
    await renderVista()
    expect(await screen.findByText('No hay rendiciones en el rango seleccionado')).toBeInTheDocument()
  })

  it('si la RPC falla no rompe: muestra el vacío', async () => {
    rpcMock.mockImplementation((nombre: string) =>
      nombre === 'obtener_resumen_rendiciones'
        ? Promise.resolve({ data: null, error: { message: 'boom', code: 'XX000' } })
        : Promise.resolve({ data: null, error: null }),
    )
    await renderVista()
    expect(await screen.findByText('No hay rendiciones en el rango seleccionado')).toBeInTheDocument()
  })
})

describe('VistaRendiciones — filtros', () => {
  it('tiene el filtro de transportista con "Todos" y los transportistas', async () => {
    await renderVista()

    const select = filtroTransportista()
    expect(select).toHaveValue('')
    expect(within(select).getAllByRole('option').map(o => o.textContent)).toEqual([
      'Todos',
      'Tito Transportista',
      'Pedro Chofer',
    ])
  })

  it('elegir un transportista vuelve a pedir el resumen con su id', async () => {
    const user = userEvent.setup()
    await renderVista()

    await user.selectOptions(filtroTransportista(), 'tr-2')

    await waitFor(() => expect(llamadas('obtener_resumen_rendiciones')).toHaveLength(2))
    expect(llamadas('obtener_resumen_rendiciones')[1][1]).toMatchObject({ p_transportista_id: 'tr-2' })
  })

  it('el filtro de estado es local: no vuelve a llamar a la RPC', async () => {
    const user = userEvent.setup()
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    await user.selectOptions(filtroEstado(), 'disconformidad')

    expect(screen.getAllByRole('button', { name: 'Resolver' })).toHaveLength(1)
    expect(screen.queryByRole('button', { name: 'Cerrar rendición' })).toBeNull()
    expect(llamadas('obtener_resumen_rendiciones')).toHaveLength(1)
  })
})

describe('VistaRendiciones — acciones por estado', () => {
  it('pendiente: "Cerrar rendición"; confirmada y resuelta: "Editar cierre"; disconformidad: "Resolver"', async () => {
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    expect(within(tarjeta('Tito Transportista', '2026-10-05')).getByRole('button', { name: 'Cerrar rendición' })).toBeInTheDocument()
    expect(within(tarjeta('Pedro Chofer', '2026-10-04')).getByRole('button', { name: 'Editar cierre' })).toBeInTheDocument()
    expect(within(tarjeta('Pedro Chofer', '2026-10-02')).getByRole('button', { name: 'Editar cierre' })).toBeInTheDocument()
    expect(within(tarjeta('Tito Transportista', '2026-10-03')).getByRole('button', { name: 'Resolver' })).toBeInTheDocument()
  })

  it('una disconformidad NO ofrece cerrar/editar cierre, y las demás NO ofrecen "Resolver"', async () => {
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    const disc = tarjeta('Tito Transportista', '2026-10-03')
    expect(within(disc).queryByRole('button', { name: 'Cerrar rendición' })).toBeNull()
    expect(within(disc).queryByRole('button', { name: 'Editar cierre' })).toBeNull()
    for (const [n, f] of [['Tito Transportista', '2026-10-05'], ['Pedro Chofer', '2026-10-04'], ['Pedro Chofer', '2026-10-02']]) {
      expect(within(tarjeta(n, f)).queryByRole('button', { name: 'Resolver' })).toBeNull()
    }
  })

  it('"Cerrar rendición" abre el modal de cierre de esa tarjeta; confirmar llama a confirmar_rendicion y refresca', async () => {
    const user = userEvent.setup()
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    await user.click(within(tarjeta('Tito Transportista', '2026-10-05')).getByRole('button', { name: 'Cerrar rendición' }))
    const modal = await screen.findByRole('dialog', { name: 'Cerrar rendición' })
    expect(modal).toHaveTextContent('cerrar 2026-10-05 Tito Transportista')

    await user.click(within(modal).getByRole('button', { name: 'stub-confirmar' }))

    await waitFor(() => expect(llamadas('confirmar_rendicion')).toHaveLength(1))
    expect(llamadas('confirmar_rendicion')[0][1]).toEqual({
      p_fecha: '2026-10-05',
      p_transportista_id: 'tr-1',
      p_estado: 'confirmada',
      p_observaciones: 'todo ok',
      p_gastos: [],
    })
    await waitFor(() => expect(notifyMock.success).toHaveBeenCalledWith('Rendición confirmada'))
    // Después de cerrar se vuelve a pedir el resumen y el modal se va.
    await waitFor(() => expect(llamadas('obtener_resumen_rendiciones')).toHaveLength(2))
    expect(screen.queryByRole('dialog', { name: 'Cerrar rendición' })).toBeNull()
  })

  it('cerrar con disconformidad notifica "Disconformidad registrada"', async () => {
    const user = userEvent.setup()
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    await user.click(within(tarjeta('Tito Transportista', '2026-10-05')).getByRole('button', { name: 'Cerrar rendición' }))
    await user.click(await screen.findByRole('button', { name: 'stub-disconformidad' }))

    await waitFor(() => expect(llamadas('confirmar_rendicion')).toHaveLength(1))
    expect(llamadas('confirmar_rendicion')[0][1]).toMatchObject({ p_estado: 'disconformidad', p_observaciones: 'falta plata' })
    await waitFor(() => expect(notifyMock.success).toHaveBeenCalledWith('Disconformidad registrada'))
  })

  it('"Editar cierre" abre el mismo modal de cierre con las observaciones previas', async () => {
    const user = userEvent.setup()
    resumenes = [{ ...CONFIRMADA, observaciones: 'ya estaba cerrada' }]
    await renderVista()
    await screen.findByText('Pedro Chofer', { selector: 'span' })

    await user.click(screen.getByRole('button', { name: 'Editar cierre' }))
    const modal = await screen.findByRole('dialog', { name: 'Cerrar rendición' })
    expect(modal).toHaveTextContent('cerrar 2026-10-04 Pedro Chofer')
    expect(modal).toHaveTextContent('previas: ya estaba cerrada')
  })

  it('"Resolver" abre el modal de resolución; resolver llama a resolver_rendicion y refresca', async () => {
    const user = userEvent.setup()
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    await user.click(within(tarjeta('Tito Transportista', '2026-10-03')).getByRole('button', { name: 'Resolver' }))
    const modal = await screen.findByRole('dialog', { name: 'Resolver rendición' })
    expect(modal).toHaveTextContent('resolver 2026-10-03 Tito Transportista')
    expect(modal).toHaveTextContent('previas: Faltan 5000')

    await user.click(within(modal).getByRole('button', { name: 'stub-resolver' }))

    await waitFor(() => expect(llamadas('resolver_rendicion')).toHaveLength(1))
    expect(llamadas('resolver_rendicion')[0][1]).toEqual({
      p_fecha: '2026-10-03',
      p_transportista_id: 'tr-1',
      p_observaciones: 'se devolvió la diferencia',
    })
    await waitFor(() => expect(notifyMock.success).toHaveBeenCalledWith('Disconformidad resuelta'))
    await waitFor(() => expect(llamadas('obtener_resumen_rendiciones')).toHaveLength(2))
  })
})

describe('VistaRendiciones — encabezado', () => {
  it('tiene los botones "Cta cte pendiente" y "Refrescar"', async () => {
    await renderVista()
    expect(screen.getByRole('button', { name: /Cta cte pendiente/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Refrescar/ })).toBeInTheDocument()
  })

  it('"Refrescar" vuelve a pedir el resumen con el mismo rango', async () => {
    const user = userEvent.setup()
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })
    const primero = llamadas('obtener_resumen_rendiciones')[0][1]

    await user.click(screen.getByRole('button', { name: /Refrescar/ }))

    await waitFor(() => expect(llamadas('obtener_resumen_rendiciones')).toHaveLength(2))
    expect(llamadas('obtener_resumen_rendiciones')[1][1]).toEqual(primero)
  })

  it('"Cta cte pendiente" abre el modal con el mismo rango y el transportista elegido', async () => {
    const user = userEvent.setup()
    await renderVista()
    await user.selectOptions(filtroTransportista(), 'tr-1')
    await waitFor(() => expect(llamadas('obtener_resumen_rendiciones')).toHaveLength(2))
    const { p_fecha_desde, p_fecha_hasta } = llamadas('obtener_resumen_rendiciones')[1][1] as {
      p_fecha_desde: string
      p_fecha_hasta: string
    }

    await user.click(screen.getByRole('button', { name: /Cta cte pendiente/ }))

    const modal = await screen.findByRole('dialog', { name: 'Cta cte pendiente' })
    expect(modal).toHaveTextContent(`ctacte ${p_fecha_desde} ${p_fecha_hasta} [tr-1]`)
  })
})

describe('VistaRendiciones — detalle de una tarjeta', () => {
  it('no pide el detalle hasta que se expande', async () => {
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })
    expect(llamadas('obtener_detalle_rendicion')).toHaveLength(0)
  })

  it('expandir pide obtener_detalle_rendicion con { p_fecha, p_transportista_id } y lista los clientes', async () => {
    const user = userEvent.setup()
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    await user.click(within(tarjeta('Pedro Chofer', '2026-10-04')).getByRole('button', { name: /Detalle/ }))

    await waitFor(() => expect(llamadas('obtener_detalle_rendicion')).toHaveLength(1))
    expect(llamadas('obtener_detalle_rendicion')[0][1]).toEqual({
      p_fecha: '2026-10-04',
      p_transportista_id: 'tr-2',
    })
    expect(await screen.findByText('Kiosco El Sol')).toBeInTheDocument()
    expect(screen.getByText(/Detalle por cliente/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Exportar Excel/ })).toBeEnabled()
  })

  // El vale blanco dejó de ser forma de pago (pasó a comprobante VB, consumo interno):
  // ya no hay bucket "Vale Blanco" ni columna. La RPC puede seguir devolviendo
  // `total_vale_blanco` / `vale_blanco` un tiempo (hasta que se recree sin la columna) o no
  // devolverlos: la vista funciona con las dos y no muestra la columna.
  it('no muestra ningún bucket "Vale Blanco" (la RPC ya no trae la columna)', async () => {
    const user = userEvent.setup()
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })

    await user.click(within(tarjeta('Pedro Chofer', '2026-10-04')).getByRole('button', { name: /Detalle/ }))
    await screen.findByText('Kiosco El Sol')

    expect(screen.queryByText(/vale blanco/i)).not.toBeInTheDocument()
    expect(screen.getByText('Otros:')).toBeInTheDocument()
  })

  it('si la RPC todavía devuelve total_vale_blanco, no lo muestra y lo pliega a "Otros" para que el desglose cierre', async () => {
    const user = userEvent.setup()
    resumenes = [fila({ total_vale_blanco: 4000, total_otros: 1000, total_efectivo: 50000, total_transferencia: 15000, total_general: 70000 })]
    rpcMock.mockImplementation((nombre: string) => {
      if (nombre === 'obtener_resumen_rendiciones') return Promise.resolve({ data: resumenes, error: null })
      if (nombre === 'obtener_detalle_rendicion') {
        return Promise.resolve({ data: [{ ...DETALLE[0], otros: 1000, vale_blanco: 4000 }], error: null })
      }
      return Promise.resolve({ data: null, error: null })
    })
    await renderVista()
    await screen.findByText('Tito Transportista', { selector: 'span' })

    await user.click(screen.getByRole('button', { name: /Detalle/ }))
    await screen.findByText('Kiosco El Sol')

    expect(screen.queryByText(/vale blanco/i)).not.toBeInTheDocument()
    expect(screen.getByText('Otros:').parentElement).toHaveTextContent(/5\.000/)
  })

  it('si el detalle falla lo dice, no lo disfraza de "sin datos"', async () => {
    const user = userEvent.setup()
    rpcMock.mockImplementation((nombre: string) => {
      if (nombre === 'obtener_resumen_rendiciones') return Promise.resolve({ data: [PENDIENTE], error: null })
      if (nombre === 'obtener_detalle_rendicion') return Promise.resolve({ data: null, error: { message: 'tipo mal declarado' } })
      return Promise.resolve({ data: null, error: null })
    })
    await renderVista()
    await screen.findByText('Tito Transportista', { selector: 'span' })

    await user.click(screen.getByRole('button', { name: /Detalle/ }))

    expect(await screen.findByText(/No se pudo cargar el detalle: tipo mal declarado/)).toBeInTheDocument()
  })
})

// =============================================================================
// #724 — EL TRANSPORTISTA VE SUS COBROS
// =============================================================================

describe('VistaRendiciones — transportista (#724)', () => {
  const PAGOS = [
    {
      pago_id: 91, created_at: '2026-10-05T15:00:00Z', monto: 50000, forma_pago: 'efectivo',
      referencia: null, notas: null, pedido_id: 501, pedido_fecha: '2026-10-04',
      pedido_estado: 'entregado', pedido_total: 50000, cobrado_por: 'Tito Transportista',
      es_entrega_del_dia: true,
    },
  ]

  beforeEach(() => {
    roles.isAdmin = false
    roles.isTransportista = true
    // La RPC ya le devuelve sólo lo suyo (rama de #724): acá, dos días de tr-1.
    resumenes = [PENDIENTE, DISCONFORME]
    rpcMock.mockImplementation((nombre: string) => {
      if (nombre === 'obtener_resumen_rendiciones') return Promise.resolve({ data: resumenes, error: null })
      if (nombre === 'obtener_detalle_rendicion') return Promise.resolve({ data: DETALLE, error: null })
      if (nombre === 'obtener_pagos_rendicion_cliente') return Promise.resolve({ data: PAGOS, error: null })
      return Promise.resolve({ data: null, error: null })
    })
  })

  it('pide el resumen sin transportista (null = él: el servidor recorta a su fila)', async () => {
    await renderVista('Mis cobros')
    const args = llamadas('obtener_resumen_rendiciones')[0][1] as Record<string, unknown>
    expect(args.p_transportista_id).toBeNull()
  })

  it('el título es "Mis cobros" y no tiene filtro de transportista ni "Cta cte pendiente"', async () => {
    await renderVista('Mis cobros')
    await screen.findAllByText('Tito Transportista', { selector: 'span' })

    expect(screen.queryByRole('heading', { name: 'Rendiciones Diarias' })).toBeNull()
    expect(screen.queryByRole('option', { name: 'Todos' })).toBeNull()
    expect(screen.queryByRole('option', { name: 'Pedro Chofer' })).toBeNull()
    expect(screen.queryByRole('button', { name: /Cta cte pendiente/ })).toBeNull()
    // Lo que sí tiene: el rango, el filtro de estado y refrescar.
    expect(document.querySelectorAll('input[type="date"]')).toHaveLength(2)
    expect(filtroEstado()).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Refrescar/ })).toBeInTheDocument()
  })

  it('ve el estado de cada día pero ninguna acción de control', async () => {
    await renderVista('Mis cobros')
    await screen.findAllByText('Tito Transportista', { selector: 'span' })

    expect(tarjeta('Tito Transportista', '2026-10-05')).toHaveTextContent('Pendiente')
    expect(tarjeta('Tito Transportista', '2026-10-03')).toHaveTextContent('Disconformidad')
    expect(screen.queryByRole('button', { name: 'Cerrar rendición' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Editar cierre' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Resolver' })).toBeNull()
  })

  it('abre el detalle de su día con su id, y los pagos de un cliente, sin "Ver ficha del cliente"', async () => {
    const user = userEvent.setup()
    await renderVista('Mis cobros')
    await screen.findAllByText('Tito Transportista', { selector: 'span' })

    await user.click(within(tarjeta('Tito Transportista', '2026-10-05')).getByRole('button', { name: /Detalle/ }))
    await waitFor(() => expect(llamadas('obtener_detalle_rendicion')).toHaveLength(1))
    expect(llamadas('obtener_detalle_rendicion')[0][1]).toEqual({ p_fecha: '2026-10-05', p_transportista_id: 'tr-1' })

    await user.click(await screen.findByText('Kiosco El Sol'))
    await waitFor(() => expect(llamadas('obtener_pagos_rendicion_cliente')).toHaveLength(1))
    expect(llamadas('obtener_pagos_rendicion_cliente')[0][1]).toEqual({
      p_fecha: '2026-10-05', p_transportista_id: 'tr-1', p_cliente_id: 7,
    })
    expect(await screen.findByText(/Pedido #501/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Ver ficha del cliente/ })).toBeNull()
  })

  it('el preventista que también reparte ve lo mismo que el transportista', async () => {
    roles.isPreventista = true
    await renderVista('Mis cobros')
    await screen.findAllByText('Tito Transportista', { selector: 'span' })
    expect(screen.queryByRole('button', { name: 'Cerrar rendición' })).toBeNull()
    expect(screen.queryByRole('option', { name: 'Todos' })).toBeNull()
  })
})

describe('VistaRendiciones — el encargado sigue viendo la de oficina (#724)', () => {
  it('con título, filtro de transportista y acciones', async () => {
    roles.isAdmin = false
    roles.isEncargado = true
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })
    expect(filtroTransportista()).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Cerrar rendición' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Resolver' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Cta cte pendiente/ })).toBeInTheDocument()
  })

  it('el encargado que además tiene rol de transportista sigue en la de oficina', async () => {
    roles.isAdmin = false
    roles.isEncargado = true
    roles.isTransportista = true
    await renderVista()
    await screen.findAllByText('Pedro Chofer', { selector: 'span' })
    expect(filtroTransportista()).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Cerrar rendición' })).toBeInTheDocument()
  })
})
