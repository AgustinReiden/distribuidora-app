/**
 * La tarjeta de pedido en dos líneas con UNA acción visible (#768, WP-43),
 * montando la `PedidoCard` REAL con los pedidos de la galería.
 *
 * Qué fija:
 *  - por rol y estado, qué botón de acción aparece afuera del menú ⋮ (por su
 *    nombre accesible) o que no aparece ninguno;
 *  - que ese botón llama al MISMO handler que la opción del menú, con el pedido;
 *  - que el menú ⋮ sigue ofreciendo TODAS sus opciones, incluida la que además
 *    está afuera, y que hay un solo menú por tarjeta;
 *  - que el detalle (chevron con aria-expanded) tiene productos, notas y el
 *    cliente completo.
 *
 * Nada por clase: rol ARIA, nombre accesible, texto y handlers.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

// La cadena de imports pide supabaseUrl al cargarse (mismo patrón que
// PedidoCard.deuda.test.tsx).
vi.mock('../../../lib/supabase', () => ({
  supabase: {
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getUser: vi.fn(() => Promise.resolve({ data: { user: null } })),
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Test' }),
}))

vi.mock('../../../lib/pdfExport', () => ({
  generarReciboPedido: vi.fn(),
}))

import PedidoCard, { type PedidoCardProps } from '../PedidoCard'
import { AuthDataProvider } from '../../../contexts/AuthDataContext'
import { NotificationProvider } from '../../../contexts/NotificationContext'
import type { PedidoDB, RolUsuario } from '../../../types'
import { PEDIDOS_FIXTURE } from '../../../../dev/gallery/fixtures/pedidos'
import { authDataDeRol, ROLES_GALERIA } from '../../../../dev/gallery/fixtures/auth'
import { TRANSPORTISTAS_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo'

// Radix DropdownMenu en jsdom (mismos stubs que PedidoActions.test.tsx; el
// ResizeObserver ya viene de src/test/setup.js).
class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return [] }
}
globalThis.IntersectionObserver = ObservadorStub as unknown as typeof IntersectionObserver
if (!Element.prototype.hasPointerCapture) Element.prototype.hasPointerCapture = (): boolean => false
if (!Element.prototype.setPointerCapture) Element.prototype.setPointerCapture = (): void => undefined
if (!Element.prototype.releasePointerCapture) Element.prototype.releasePointerCapture = (): void => undefined
if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = (): void => undefined

// =============================================================================
// DATOS: los pedidos de la galería con fechas fijas
// =============================================================================

/** 14:00 ARG del 17/09/2026: antes del corte de 15:30 del preventista. */
const AHORA = new Date('2026-09-17T17:00:00Z')
/** 16:00 ARG del mismo día: pasado el corte. */
const DESPUES_DEL_CORTE = new Date('2026-09-17T19:00:00Z')

const PENDIENTE = '18420'
const EN_PREPARACION = '18421'
const ASIGNADO = '18398'
const ENTREGADO_FC = '18355'
const ENTREGADO_SALVEDAD = '18371'
const CANCELADO = '18312'
const GPS_DENEGADO = '18433'
const GPS_LEJOS = '18434'
const TEXTOS_LARGOS = '18440'

/** Las fechas de la galería son relativas al día real; acá van contra AHORA. */
const FECHAS_FIJAS: Record<string, Partial<PedidoDB>> = {
  [PENDIENTE]: { fecha: '2026-09-17', created_at: '2026-09-17T09:14:00-03:00' },
  [EN_PREPARACION]: { fecha: '2026-09-17', created_at: '2026-09-17T10:02:00-03:00', fecha_entrega_programada: '2026-09-18' },
  [ASIGNADO]: { fecha: '2026-09-15', created_at: '2026-09-15T08:47:00-03:00', fecha_entrega_programada: '2026-09-17' },
  [ENTREGADO_FC]: { fecha: '2026-09-12', created_at: '2026-09-12T07:58:00-03:00', fecha_entrega: '2026-09-13' },
  [ENTREGADO_SALVEDAD]: { fecha: '2026-09-14', created_at: '2026-09-14T11:31:00-03:00', fecha_entrega: '2026-09-15' },
  [CANCELADO]: { fecha: '2026-09-10', created_at: '2026-09-10T16:20:00-03:00' },
  [GPS_DENEGADO]: { fecha: '2026-09-17', created_at: '2026-09-17T12:44:00-03:00' },
  [GPS_LEJOS]: { fecha: '2026-09-17', created_at: '2026-09-17T13:05:00-03:00' },
  [TEXTOS_LARGOS]: { fecha: '2026-09-17', created_at: '2026-09-17T08:30:00-03:00', fecha_entrega_programada: '2026-09-19' },
}

function fixture(id: string): PedidoDB {
  const ejemplo = PEDIDOS_FIXTURE.find(e => e.pedido.id === id)
  if (!ejemplo) throw new Error(`No hay fixture de pedido #${id}`)
  return { ...ejemplo.pedido, ...FECHAS_FIJAS[id] }
}

// Etiquetas exactas del menú (las mismas que PedidoActions.test.tsx).
const HISTORIAL = 'Ver Historial'
const IMPRIMIR = 'Imprimir Comanda'
const EDITAR = 'Editar'
const EDITAR_PEDIDO = 'Editar Pedido'
const EDITAR_OBS = 'Editar Observaciones'
const REGISTRAR_PAGO = 'Registrar Pago'
const VER_EDITAR_PAGOS = 'Ver/Editar Pagos'
const VER_ANULAR_PAGOS = 'Ver/Anular Pagos'
const PREPARAR = 'Marcar en Preparacion'
const VOLVER = 'Volver a Pendiente'
const ENTREGADO = 'Marcar Entregado'
const SALVEDAD = 'Entrega con Salvedad'
const REVERTIR = 'Revertir Entrega'
const CANCELAR = 'Cancelar Pedido'

const ETIQUETAS_ACCION = [
  HISTORIAL, IMPRIMIR, EDITAR, EDITAR_PEDIDO, EDITAR_OBS, REGISTRAR_PAGO, VER_EDITAR_PAGOS, VER_ANULAR_PAGOS,
  PREPARAR, VOLVER, ENTREGADO, SALVEDAD, REVERTIR, CANCELAR,
] as const

// =============================================================================
// HELPERS
// =============================================================================

function crearHandlers() {
  return {
    onVerHistorial: vi.fn(),
    onEditarPedido: vi.fn(),
    onEditarNotas: vi.fn(),
    onMarcarEnPreparacion: vi.fn(),
    onVolverAPendiente: vi.fn(),
    onMarcarEntregado: vi.fn(),
    onMarcarEntregadoConSalvedad: vi.fn(),
    onDesmarcarEntregado: vi.fn(),
    onCancelarPedido: vi.fn(),
    onRegistrarPago: vi.fn(),
  } satisfies Partial<PedidoCardProps>
}

type Handlers = ReturnType<typeof crearHandlers>

type FlagsDeRol = Pick<PedidoCardProps, 'isAdmin' | 'isPreventista' | 'isTransportista' | 'isEncargado'>

/**
 * Monta la card como VistaPedidos: flags de rol de la sesión, handlers por
 * props. `flags` pisa los del rol para los multi-rol (mig 155), que en la app
 * llegan así: el rol primario más las capacidades extra.
 */
function renderCard(
  pedido: PedidoDB,
  rol: RolUsuario,
  flags: Partial<FlagsDeRol> = {},
): { handlers: Handlers; pedido: PedidoDB } {
  const auth = { ...authDataDeRol(rol), ...flags }
  const handlers = crearHandlers()
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })

  function Wrapper({ children }: { children: ReactNode }): ReactElement {
    return (
      <QueryClientProvider client={qc}>
        <NotificationProvider>
          <AuthDataProvider value={auth}>{children}</AuthDataProvider>
        </NotificationProvider>
      </QueryClientProvider>
    )
  }

  render(
    <PedidoCard
      pedido={pedido}
      isAdmin={auth.isAdmin}
      isPreventista={auth.isPreventista}
      isTransportista={auth.isTransportista}
      isEncargado={auth.isEncargado}
      {...handlers}
    />,
    { wrapper: Wrapper },
  )
  return { handlers, pedido }
}

/** Los botones de acción que la tarjeta muestra AFUERA del menú (menú cerrado). */
function accionesAfuera(): string[] {
  return ETIQUETAS_ACCION.filter(etiqueta => screen.queryAllByRole('button', { name: etiqueta }).length > 0)
}

async function opcionesDelMenu(): Promise<string[]> {
  const user = userEvent.setup()
  await user.click(screen.getByRole('button', { name: 'Mas acciones' }))
  const menu = await screen.findByRole('menu')
  return within(menu).getAllByRole('menuitem').map(item => (item.textContent ?? '').trim()).sort()
}

/** Que se haya llamado SOLO a `handler`, una vez y con el pedido. */
function soloLlamo(handlers: Handlers, handler: keyof Handlers, pedido: PedidoDB): void {
  expect(handlers[handler]).toHaveBeenCalledTimes(1)
  expect(handlers[handler]).toHaveBeenCalledWith(pedido)
  for (const [nombre, fn] of Object.entries(handlers)) {
    if (nombre !== handler) expect(fn, `${nombre} no debería llamarse`).not.toHaveBeenCalled()
  }
}

const ordenado = (labels: readonly string[]): string[] => [...labels].sort()

beforeEach(() => {
  // Sólo Date: setTimeout tiene que seguir siendo real o userEvent y Radix se
  // cuelgan. La ventana del preventista lee `new Date()`.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(AHORA)
})

afterEach(() => {
  vi.useRealTimers()
  document.body.style.pointerEvents = ''
})

// =============================================================================
// 1. LA ACCIÓN VISIBLE POR ROL Y ESTADO
// =============================================================================

interface CasoVisible {
  rol: RolUsuario
  id: string
  /** Etiqueta del botón de afuera, o null si no tiene que haber ninguno. */
  visible: string | null
  /** El handler que ese botón tiene que llamar. */
  handler?: keyof Handlers
  /** El menú completo, que no cambia por tener una acción afuera. */
  menu: readonly string[]
}

const CASOS: readonly CasoVisible[] = [
  // --- admin ---
  { rol: 'admin', id: PENDIENTE, visible: PREPARAR, handler: 'onMarcarEnPreparacion', menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO, CANCELAR] },
  { rol: 'admin', id: EN_PREPARACION, visible: null, menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, CANCELAR] },
  { rol: 'admin', id: ASIGNADO, visible: ENTREGADO, handler: 'onMarcarEntregado', menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, SALVEDAD, CANCELAR] },
  // Pagado: "Ver/Editar Pagos" no va afuera.
  { rol: 'admin', id: ENTREGADO_FC, visible: null, menu: [HISTORIAL, IMPRIMIR, EDITAR, VER_EDITAR_PAGOS, REVERTIR] },
  // Pago parcial: falta cobrar.
  { rol: 'admin', id: ENTREGADO_SALVEDAD, visible: REGISTRAR_PAGO, handler: 'onRegistrarPago', menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, REVERTIR] },
  { rol: 'admin', id: CANCELADO, visible: null, menu: [HISTORIAL, IMPRIMIR] },

  // --- encargado: lo mismo que el admin, sin "Cancelar Pedido" ---
  { rol: 'encargado', id: PENDIENTE, visible: PREPARAR, handler: 'onMarcarEnPreparacion', menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO] },
  { rol: 'encargado', id: ASIGNADO, visible: ENTREGADO, handler: 'onMarcarEntregado', menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, SALVEDAD] },
  { rol: 'encargado', id: ENTREGADO_SALVEDAD, visible: REGISTRAR_PAGO, handler: 'onRegistrarPago', menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, REVERTIR] },
  { rol: 'encargado', id: CANCELADO, visible: null, menu: [HISTORIAL, IMPRIMIR] },

  // --- preventista: dueña de todos los fixtures, a las 14:00 ARG ---
  { rol: 'preventista', id: PENDIENTE, visible: EDITAR_PEDIDO, handler: 'onEditarPedido', menu: [HISTORIAL, EDITAR_PEDIDO] },
  // Tiene "Editar Pedido" en el menú, pero la regla sólo lo saca en pendiente.
  { rol: 'preventista', id: EN_PREPARACION, visible: null, menu: [HISTORIAL, EDITAR_PEDIDO] },
  { rol: 'preventista', id: ASIGNADO, visible: null, menu: [HISTORIAL, EDITAR_OBS] },
  { rol: 'preventista', id: ENTREGADO_FC, visible: null, menu: [HISTORIAL, EDITAR_OBS] },

  // --- transportista: la parada asignada es suya ---
  { rol: 'transportista', id: ASIGNADO, visible: ENTREGADO, handler: 'onMarcarEntregado', menu: [HISTORIAL, ENTREGADO, SALVEDAD] },
  { rol: 'transportista', id: PENDIENTE, visible: null, menu: [HISTORIAL] },
  { rol: 'transportista', id: ENTREGADO_FC, visible: null, menu: [HISTORIAL] },

  // --- depósito: sólo mira ---
  { rol: 'deposito', id: PENDIENTE, visible: null, menu: [HISTORIAL] },
  { rol: 'deposito', id: ASIGNADO, visible: null, menu: [HISTORIAL] },
  { rol: 'deposito', id: ENTREGADO_SALVEDAD, visible: null, menu: [HISTORIAL] },

  // --- el caso de textos largos de la galería: la acción visible no depende del ancho ---
  { rol: 'admin', id: TEXTOS_LARGOS, visible: PREPARAR, handler: 'onMarcarEnPreparacion', menu: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO, CANCELAR] },
  { rol: 'preventista', id: TEXTOS_LARGOS, visible: EDITAR_PEDIDO, handler: 'onEditarPedido', menu: [HISTORIAL, EDITAR_PEDIDO] },
]

describe('PedidoCard — la acción visible por rol y estado', () => {
  it.each(CASOS)('$rol sobre #$id: afuera "$visible"', ({ rol, id, visible }) => {
    renderCard(fixture(id), rol)
    expect(accionesAfuera()).toEqual(visible ? [visible] : [])
  })

  it.each(CASOS.filter(c => c.visible && c.handler))(
    '$rol sobre #$id: tocar "$visible" llama a $handler con el pedido y a nadie más',
    async ({ rol, id, visible, handler }) => {
      const { handlers, pedido } = renderCard(fixture(id), rol)
      const user = userEvent.setup()
      await user.click(screen.getByRole('button', { name: visible as string }))
      soloLlamo(handlers, handler as keyof Handlers, pedido)
    },
  )

  it.each(CASOS)('$rol sobre #$id: el menú ⋮ sigue ofreciendo todas sus opciones', async ({ rol, id, menu, visible }) => {
    renderCard(fixture(id), rol)
    const opciones = await opcionesDelMenu()
    expect(opciones).toEqual(ordenado(menu))
    expect(opciones).toHaveLength(menu.length)
    // La de afuera también sigue en el menú.
    if (visible) expect(opciones).toContain(visible)
  })

  it('el transportista sobre la parada de OTRO chofer no tiene acción visible', () => {
    renderCard({
      ...fixture(ASIGNADO),
      transportista_id: TRANSPORTISTAS_FIXTURE[1].id,
      transportista: TRANSPORTISTAS_FIXTURE[1],
    }, 'transportista')
    expect(accionesAfuera()).toEqual([])
  })

  it('el preventista, pasadas las 15:30 ARG, ya no tiene "Editar Pedido" afuera', () => {
    vi.setSystemTime(DESPUES_DEL_CORTE)
    renderCard(fixture(PENDIENTE), 'preventista')
    expect(accionesAfuera()).toEqual([])
  })

  it('un cancelado con plata cargada no saca "Ver/Anular Pagos" afuera', async () => {
    renderCard({ ...fixture(CANCELADO), monto_pagado: 15_000 }, 'admin')
    expect(accionesAfuera()).toEqual([])
    expect(await opcionesDelMenu()).toContain(VER_ANULAR_PAGOS)
  })
})

describe('PedidoCard — el preventista que también reparte (multi-rol, mig 155)', () => {
  // Es el único perfil que en un mismo pedido podría tener dos acciones con
  // derecho a ir afuera (editar y entregar): afuera va UNA, la del estado.
  const REPARTE = { isPreventista: true, isTransportista: true } as const
  const yo = authDataDeRol('preventista').user?.id as string

  it('sobre su propia parada en camino: afuera va sólo "Marcar Entregado", y llama sólo a ese handler', async () => {
    const pedido = { ...fixture(ASIGNADO), usuario_id: yo, transportista_id: yo }
    const { handlers } = renderCard(pedido, 'preventista', REPARTE)
    expect(accionesAfuera()).toEqual([ENTREGADO])

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: ENTREGADO }))
    soloLlamo(handlers, 'onMarcarEntregado', pedido)
  })

  it('sobre un pendiente suyo de hoy: afuera va sólo "Editar Pedido"', async () => {
    const pedido = { ...fixture(PENDIENTE), usuario_id: yo }
    const { handlers } = renderCard(pedido, 'preventista', REPARTE)
    expect(accionesAfuera()).toEqual([EDITAR_PEDIDO])

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: EDITAR_PEDIDO }))
    soloLlamo(handlers, 'onEditarPedido', pedido)
  })
})

// =============================================================================
// 2. EL CRITERIO DE ACEPTACIÓN: en todos los pedidos de la galería x 5 roles,
//    lo de afuera es una opción que el menú ya le da a ese rol sobre ese pedido
// =============================================================================

describe('PedidoCard — lo de afuera siempre está también en el menú', () => {
  const casos = ROLES_GALERIA.flatMap(rol => PEDIDOS_FIXTURE.map(({ pedido }) => ({ rol, id: pedido.id })))

  it.each(casos)('$rol sobre #$id', async ({ rol, id }) => {
    renderCard(fixture(id), rol)
    const afuera = accionesAfuera()
    expect(afuera.length).toBeLessThanOrEqual(1)
    const menu = await opcionesDelMenu()
    for (const etiqueta of afuera) expect(menu).toContain(etiqueta)
  })
})

// =============================================================================
// 3. UN SOLO MENÚ, Y LA LÍNEA 2
// =============================================================================

describe('PedidoCard — estructura por rol ARIA y texto', () => {
  it.each(ROLES_GALERIA)('%s: hay un solo menú ⋮ por tarjeta (antes había dos copias)', rol => {
    renderCard(fixture(ASIGNADO), rol)
    expect(screen.getAllByRole('button', { name: 'Mas acciones' })).toHaveLength(1)
  })

  it.each([
    { id: ENTREGADO_FC, texto: '9 ítems' },
    { id: ASIGNADO, texto: '3 ítems' },
    { id: CANCELADO, texto: '1 ítem' },
  ])('la línea 2 dice cuántos ítems tiene #$id: "$texto"', ({ id, texto }) => {
    renderCard(fixture(id), 'deposito')
    expect(screen.getByText(texto)).toBeInTheDocument()
  })

  it('un entregado dice en la tarjeta cuándo se entregó', () => {
    renderCard(fixture(ENTREGADO_FC), 'deposito')
    expect(screen.getByText('entregado 13/9')).toBeInTheDocument()
  })

  it.each([
    // Como lo estampan usePedidosQuery y las RPC de entrega: mediodía AR.
    ['mediodía AR', '2026-09-13T12:00:00-03:00'],
    // Como lo reescribe la edición del pedido: mediodía UTC (09:00 AR).
    ['mediodía UTC', '2026-09-13T12:00:00+00:00'],
  ])('con fecha_entrega como la guarda la base (%s) dice sólo el día, sin una hora que no es la de la entrega', (_, fechaEntrega) => {
    renderCard({ ...fixture(ENTREGADO_FC), fecha_entrega: fechaEntrega }, 'deposito')
    expect(screen.getByTitle('Fecha de entrega')).toHaveTextContent(/^entregado 13\/9$/)
  })

  it('vendedor y transportista se leen como quién cargó y quién lleva', () => {
    renderCard(fixture(ASIGNADO), 'deposito')
    expect(screen.getByTitle('Pedido cargado por')).toHaveTextContent('Nahuel Juárez')
    expect(screen.getByTitle('Transportista asignado')).toHaveTextContent('Gustavo Paz')
  })
})

// =============================================================================
// 4. EL DETALLE
// =============================================================================

describe('PedidoCard — el detalle se abre con el chevron', () => {
  it('arranca cerrado y al abrirlo muestra todos los productos, las notas y el cliente completo', async () => {
    renderCard(fixture(ENTREGADO_SALVEDAD), 'admin')
    const chevron = screen.getByRole('button', { name: 'Ver detalle del pedido' })
    expect(chevron).toHaveAttribute('aria-expanded', 'false')
    // Cerrado: ni productos ni notas en la tarjeta.
    expect(screen.queryByText('Soda sifón 1,5 L')).not.toBeInTheDocument()
    expect(screen.queryByText(/Dejar en el depósito del fondo/)).not.toBeInTheDocument()

    const user = userEvent.setup()
    await user.click(chevron)

    expect(chevron).toHaveAttribute('aria-expanded', 'true')
    expect(chevron).toHaveAccessibleName('Ocultar detalle del pedido')
    const detalle = document.getElementById(chevron.getAttribute('aria-controls') as string)
    expect(detalle).toBeVisible()
    const region = within(detalle as HTMLElement)

    // Productos: todos. La soda aparece dos veces (su fila y la de su salvedad).
    expect(region.getByText('Productos (2)')).toBeInTheDocument()
    expect(region.getAllByText('Soda sifón 1,5 L').length).toBeGreaterThan(0)
    expect(region.getByText('Agua mineral sin gas 2 L')).toBeInTheDocument()
    // Notas.
    expect(region.getByText('Notas')).toBeInTheDocument()
    expect(region.getByText('Dejar en el depósito del fondo. Preguntar por Ramón antes de descargar.')).toBeInTheDocument()
    // Cliente completo.
    expect(region.getByText('Ramón Ernesto Ledesma')).toBeInTheDocument()
    expect(region.getByText('CUIT: 20-00000000-9')).toBeInTheDocument()
    expect(region.getByRole('link', { name: '381 466-9013' })).toHaveAttribute('href', 'tel:381 466-9013')
    // Lo que salió de las líneas: fecha de carga y forma de pago.
    expect(region.getByText('14/9')).toBeInTheDocument()
    expect(region.getByText('Efectivo')).toBeInTheDocument()

    await user.click(chevron)
    expect(chevron).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText('Soda sifón 1,5 L')).not.toBeInTheDocument()
  })

  it('un pedido con más de 3 ítems lista los 9 en el detalle, no sólo 3', async () => {
    renderCard(fixture(ENTREGADO_FC), 'deposito')
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Ver detalle del pedido' }))
    const region = within(document.getElementById('pedido-detalle-18355') as HTMLElement)
    expect(region.getByText('Productos (9)')).toBeInTheDocument()
    for (const nombre of [
      'Manaos Cola 2,25 L', 'Manaos Naranja 2,25 L', 'Agua mineral sin gas 2 L', 'Yerba mate Cruz de Malta 1 kg',
      'Aceite de girasol 900 ml', 'Fideos tirabuzón 500 g', 'Azúcar Concepción 1 kg', 'Vinagre de alcohol 500 ml',
      'Regalo por volumen · 1 bolsón cada 10',
    ]) expect(region.getByText(nombre)).toBeInTheDocument()
  })
})
