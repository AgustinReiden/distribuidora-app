/**
 * Caracterizacion de `PedidoCard` ANTES del rediseno WP-43 (#768: tarjeta en 2
 * lineas, riel de color por estado, una accion visible por estado).
 *
 * NO prueba lo que la tarjeta DEBERIA hacer: fija lo que HACE hoy, para que el
 * rediseno no pierda un dato ni una accion sin que se note. Si un test de aca se
 * pone rojo, la pregunta es "¿lo saque a proposito?"; si la respuesta es si, se
 * actualiza el test en el mismo PR y se dice en la descripcion.
 *
 * Reglas del archivo:
 *  - Se asevera por texto visible, rol ARIA, nombre accesible y handlers
 *    llamados. NUNCA por clase de Tailwind ni por la forma del arbol: el rediseno
 *    reestructura el markup entero.
 *  - Antes de WP-43 el stepper, los badges de pago/FC y el kebab se dibujaban
 *    DOS veces (desktop y mobile; jsdom no aplica CSS y ve las dos). Desde
 *    WP-43 hay una sola copia de cada uno, pero nada cuenta ocurrencias: `seVe`
 *    pide "al menos una", y los tests del menu recorren TODAS las copias del
 *    kebab y exigen que ofrezcan lo mismo.
 *  - Las acciones se aseveran como lo que el usuario puede ALCANZAR desde la
 *    card: botones visibles fuera del kebab + opciones del kebab
 *    (`accionesAlcanzables`), y se eligen por el mismo camino (`elegir`). Hoy
 *    no hay ningun boton de accion fuera del kebab; WP-43 saca UNA afuera. Si
 *    se asevera el contenido del kebab solo, ese movimiento pone rojo cada caso
 *    sin que se haya perdido ni agregado nada. Lo que SI lo pone rojo es una
 *    accion que desaparece o una que aparece donde hoy no esta (gate nuevo).
 *  - Lo que hoy solo esta en un tooltip (`title`) se busca por title O por
 *    aria-label (`etiquetados`): el dato importa, no el atributo que lo lleva.
 *  - Donde lo de hoy es un bug, se fija como esta con un comentario `// BUG`
 *    que dice que deberia pasar.
 *
 * Queda AFUERA porque solo se podria fijar por clase o por CSS:
 *  - que se ve en mobile y que en desktop (las copias `sm:hidden` /
 *    `hidden sm:flex`, las etiquetas del stepper solo en `sm:`);
 *  - el color de cada estado (getEstadoColor antes; desde WP-43 el badge y el
 *    riel con toneDeEstadoPedido), del badge de pago
 *    (toneDeEstadoPago), del semaforo GPS y de la antiguedad;
 *  - el truncado de la direccion y del motivo de cancelacion en la tarjeta.
 *
 * Los datos salen de la galeria (`dev/gallery/fixtures`), con las fechas fijadas
 * contra un "ahora" fijo: la galeria fecha relativo al dia real y aca eso haria
 * que la antiguedad y la ventana del preventista dependan de cuando corre el test.
 *
 * Ajustes de WP-43 (el rediseno a dos lineas, declarado en #768). Ninguna
 * asercion de "el dato sigue accesible" se borro; cambio el CAMINO:
 *  - fecha y hora de carga, antiguedad, GPS, forma de pago, "Pagado: X de Y",
 *    motivo de cancelacion y los productos salen de la tarjeta cerrada y viven
 *    en el detalle: esos tests expanden antes de mirar (`enDetalle`).
 *  - en el detalle la cantidad se escribe "x12" (`formatCantidadItem`), no el
 *    "×12" de los chips que se fueron; el "+6 más" pasa a ser la cantidad de
 *    items de la linea 2 ("9 ítems").
 *  - el stepper sale de la tarjeta: los dos BUG de "nada dice el estado" quedan
 *    arreglados por el badge de estado, y sus tests pasan a fijar el arreglo.
 *  - hay UN solo kebab (antes dos copias); los tests que recorren "todas las
 *    copias" siguen valiendo con una.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

// Mock de supabase antes de importar el componente: la cadena de imports pide
// supabaseUrl al cargarse (mismo patron que PedidoCard.deuda.test.tsx). `rpc` es
// la frontera del cambio FC/ZZ (useCambiarTipoFacturaMutation la llama).
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

// El recibo y la comanda se generan con jsPDF por import dinamico. Se reemplaza
// para ver con que se lo llama sin generar ningun PDF.
vi.mock('../../../lib/pdfExport', () => ({
  generarReciboPedido: vi.fn(),
}))

import PedidoCard, { type PedidoCardProps } from '../PedidoCard'
import { AuthDataProvider } from '../../../contexts/AuthDataContext'
import { NotificationProvider } from '../../../contexts/NotificationContext'
import { supabase } from '../../../lib/supabase'
import { generarReciboPedido } from '../../../lib/pdfExport'
import type { PedidoDB, RolUsuario } from '../../../types'
import { PEDIDOS_FIXTURE } from '../../../../dev/gallery/fixtures/pedidos'
import { authDataDeRol, ROLES_GALERIA } from '../../../../dev/gallery/fixtures/auth'
import { PRODUCTOS_FIXTURE, TRANSPORTISTAS_FIXTURE, USUARIOS_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo'

// =============================================================================
// POLYFILLS QUE RADIX NECESITA EN JSDOM (copiados de PedidoActions.test.tsx)
// =============================================================================
// Radix DropdownMenu usa Pointer Capture y `scrollIntoView`; el ResizeObserver
// que @floating-ui construye con `new` ya viene de src/test/setup.js. Sin esto
// el menu ni abre.
class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return [] }
}
globalThis.IntersectionObserver = ObservadorStub as unknown as typeof IntersectionObserver

if (!Element.prototype.hasPointerCapture) {
  Element.prototype.hasPointerCapture = (): boolean => false
}
if (!Element.prototype.setPointerCapture) {
  Element.prototype.setPointerCapture = (): void => undefined
}
if (!Element.prototype.releasePointerCapture) {
  Element.prototype.releasePointerCapture = (): void => undefined
}
if (!Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = (): void => undefined
}

// =============================================================================
// DATOS: los fixtures de la galeria, con fechas fijas
// =============================================================================

/** 14:00 ARG del 17/09/2026: antes del corte de 15:30 del preventista. */
const AHORA = new Date('2026-09-17T17:00:00Z')
/** 16:00 ARG del mismo dia: pasado el corte. */
const DESPUES_DEL_CORTE = new Date('2026-09-17T19:00:00Z')

const PENDIENTE = '18420'
const EN_PREPARACION = '18421'
const ASIGNADO = '18398'
const ENTREGADO_FC = '18355'
const ENTREGADO_SALVEDAD = '18371'
const CANCELADO = '18312'
const GPS_DENEGADO = '18433'
const GPS_LEJOS = '18434'

/**
 * Las mismas distancias en dias que usa la galeria (`hace(n)` / `enDias(n)`),
 * pero contra AHORA. Las horas llevan el offset de Argentina explicito para que
 * `formatHora` de lo mismo con cualquier TZ de maquina (CI corre en UTC).
 */
const FECHAS_FIJAS: Record<string, Partial<PedidoDB>> = {
  [PENDIENTE]: { fecha: '2026-09-17', created_at: '2026-09-17T09:14:00-03:00' },
  [EN_PREPARACION]: {
    fecha: '2026-09-17', created_at: '2026-09-17T10:02:00-03:00', fecha_entrega_programada: '2026-09-18',
  },
  [ASIGNADO]: {
    fecha: '2026-09-15', created_at: '2026-09-15T08:47:00-03:00', fecha_entrega_programada: '2026-09-17',
  },
  [ENTREGADO_FC]: { fecha: '2026-09-12', created_at: '2026-09-12T07:58:00-03:00', fecha_entrega: '2026-09-13' },
  [ENTREGADO_SALVEDAD]: { fecha: '2026-09-14', created_at: '2026-09-14T11:31:00-03:00', fecha_entrega: '2026-09-15' },
  [CANCELADO]: { fecha: '2026-09-10', created_at: '2026-09-10T16:20:00-03:00' },
  [GPS_DENEGADO]: { fecha: '2026-09-17', created_at: '2026-09-17T12:44:00-03:00' },
  [GPS_LEJOS]: { fecha: '2026-09-17', created_at: '2026-09-17T13:05:00-03:00' },
}

function fixture(id: string): PedidoDB {
  const ejemplo = PEDIDOS_FIXTURE.find(e => e.pedido.id === id)
  if (!ejemplo) throw new Error(`No hay fixture de pedido #${id} en dev/gallery/fixtures/pedidos.ts`)
  return { ...ejemplo.pedido, ...FECHAS_FIJAS[id] }
}

/** Otro chofer y otra preventista de la galeria, para los casos "ajeno". */
const OTRO_TRANSPORTISTA = TRANSPORTISTAS_FIXTURE[1]
const OTRA_PREVENTISTA = USUARIOS_FIXTURE[1]
/** La preventista duena de todos los fixtures (la sesion del rol 'preventista'). */
const PREVENTISTA_DUENA = USUARIOS_FIXTURE[0]

// Etiquetas exactas del kebab (las mismas que PedidoActions.test.tsx).
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

/** Todas las etiquetas que hoy puede tener una accion (PedidoActions.tsx). */
const ETIQUETAS_ACCION = [
  HISTORIAL, IMPRIMIR, EDITAR, EDITAR_PEDIDO, EDITAR_OBS, REGISTRAR_PAGO, VER_EDITAR_PAGOS, VER_ANULAR_PAGOS,
  PREPARAR, VOLVER, ENTREGADO, SALVEDAD, REVERTIR, CANCELAR,
] as const

/**
 * Lo que puede decir el badge de estado (WP-43). Reemplaza a los cuatro pasos
 * del stepper ('Pendiente', 'Preparando', 'En camino', 'Entregado'), que ya no
 * se dibuja en la tarjeta.
 */
const ETIQUETAS_ESTADO = ['Pendiente', 'En preparación', 'En camino', 'Entregado', 'Con Salvedad', 'Cancelado'] as const
const ETIQUETAS_PAGO = ['Pago Pendiente', 'Pago Parcial', 'Pagado'] as const

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
 * Monta la card como la montan VistaPedidos y la galeria: los flags de rol salen
 * de la sesion y todos los handlers llegan por props. `flags` pisa los flags
 * para simular un contenedor que no los pasa todos (VirtualizedPedidoList).
 */
function renderCard(
  pedido: PedidoDB,
  rol: RolUsuario,
  opciones: { flags?: FlagsDeRol } = {},
): { handlers: Handlers; pedido: PedidoDB; qc: QueryClient } {
  const auth = authDataDeRol(rol)
  const handlers = crearHandlers()
  const flags: FlagsDeRol = opciones.flags ?? {
    isAdmin: auth.isAdmin,
    isPreventista: auth.isPreventista,
    isTransportista: auth.isTransportista,
    isEncargado: auth.isEncargado,
  }
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

  render(<PedidoCard pedido={pedido} {...flags} {...handlers} />, { wrapper: Wrapper })
  return { handlers, pedido, qc }
}

/** Al menos una vez: antes de WP-43 varias cosas se dibujaban dos veces (desktop + mobile). */
function seVe(texto: string | RegExp): void {
  expect(screen.queryAllByText(texto).length, `deberia verse ${String(texto)}`).toBeGreaterThan(0)
}

function noSeVe(texto: string | RegExp): void {
  expect(screen.queryAllByText(texto), `no deberia verse ${String(texto)}`).toHaveLength(0)
}

function kebabs(): HTMLElement[] {
  return screen.queryAllByRole('button', { name: 'Mas acciones' })
}

async function abrirMenu(kebab: HTMLElement | undefined = kebabs()[0]): Promise<HTMLElement> {
  if (!kebab) throw new Error('La card no tiene kebab ("Mas acciones")')
  const user = userEvent.setup()
  await user.click(kebab)
  return screen.findByRole('menu')
}

async function opcionesDelMenu(kebab: HTMLElement | undefined = kebabs()[0]): Promise<string[]> {
  if (!kebab) return []
  const menu = await abrirMenu(kebab)
  return within(menu)
    .queryAllByRole('menuitem')
    .map(item => (item.textContent ?? '').trim())
    .sort()
}

/**
 * Acciones que la card ofrece como boton FUERA del kebab. Se mira con el menu
 * cerrado: abierto, Radix le pone aria-hidden al resto de la pagina.
 */
function accionesVisibles(): string[] {
  return ETIQUETAS_ACCION.filter(etiqueta => screen.queryAllByRole('button', { name: etiqueta }).length > 0)
}

/** Todo lo que el usuario puede hacer desde la card: botones visibles + kebab. */
async function accionesAlcanzables(kebab?: HTMLElement): Promise<string[]> {
  const fuera = accionesVisibles()
  const delMenu = await opcionesDelMenu(kebab)
  return [...new Set([...fuera, ...delMenu])].sort()
}

/** Elige una accion por donde este: boton visible o, si no, opcion del kebab. */
async function elegir(etiqueta: string): Promise<void> {
  const user = userEvent.setup()
  const visible = screen.queryAllByRole('button', { name: etiqueta })
  if (visible.length > 0) {
    await user.click(visible[0])
    return
  }
  const menu = await abrirMenu()
  await user.click(within(menu).getByRole('menuitem', { name: etiqueta }))
}

/** Elementos que llevan `etiqueta` como tooltip (title) o como aria-label. */
function etiquetados(etiqueta: string | RegExp): HTMLElement[] {
  return [...screen.queryAllByTitle(etiqueta), ...screen.queryAllByLabelText(etiqueta)]
}

/** Lo que un elemento le dice al usuario: su texto, su tooltip y su aria-label. */
function textoExpuesto(el: HTMLElement): string {
  return [el.textContent, el.getAttribute('title'), el.getAttribute('aria-label')].filter(Boolean).join(' ')
}

async function cerrarMenu(): Promise<void> {
  const user = userEvent.setup()
  await user.keyboard('{Escape}')
  await waitFor(() => expect(screen.queryByRole('menu')).not.toBeInTheDocument())
  document.body.style.pointerEvents = ''
}

async function expandir(): Promise<void> {
  const user = userEvent.setup()
  await user.click(screen.getByRole('button', { name: 'Ver detalle del pedido' }))
}

const ordenado = (labels: readonly string[]): string[] => [...labels].sort()

/**
 * La hora de carga tal como la escribe `formatHora`. Segun la version de ICU del
 * runtime, es-AR sale en 24 h ("16:20") o en 12 h ("04:20 p. m."): lo que se
 * fija es que la hora esta, no el formato del locale.
 */
function hora(hhmm: string): RegExp {
  const [h, m] = hhmm.split(':')
  const h12 = String(Number(h) % 12 === 0 ? 12 : Number(h) % 12).padStart(2, '0')
  return new RegExp(`^(${hhmm}|${h12}:${m} [ap]\\. m\\.)$`)
}

beforeEach(() => {
  // Solo Date: setTimeout tiene que seguir siendo real o userEvent y Radix se
  // cuelgan. La antiguedad y la ventana del preventista leen `new Date()`.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(AHORA)
  vi.mocked(supabase.rpc).mockReset()
  vi.mocked(generarReciboPedido).mockReset()
})

afterEach(() => {
  vi.useRealTimers()
  // Radix en modo modal apaga los punteros del body; si queda puesto, el
  // userEvent del test siguiente no puede clickear nada.
  document.body.style.pointerEvents = ''
})

// =============================================================================
// 1. TARJETA CERRADA: que datos se ven
// =============================================================================

interface TarjetaEsperada {
  id: string
  /** Texto exacto de algun elemento de la tarjeta cerrada. */
  textos: ReadonlyArray<string | RegExp>
  /** Ausentes de la tarjeta cerrada. */
  ausentes?: ReadonlyArray<string | RegExp>
  /**
   * Lo que antes estaba en la tarjeta cerrada y WP-43 paso al detalle: se
   * asevera despues de expandir.
   */
  enDetalle?: ReadonlyArray<string | RegExp>
}

const TARJETAS_CERRADAS: readonly TarjetaEsperada[] = [
  {
    id: PENDIENTE,
    textos: [
      'Kiosco La Esquina', 'Av. Sarmiento 1240, San Miguel de Tucumán', '#18420',
      '$ 28.700,00', 'Nahuel Juárez',
    ],
    // Sin transportista: no hay chip de chofer.
    ausentes: ['Gustavo Paz', /^\+\d+ más$/],
    enDetalle: ['17/9', hora('09:14'), 'Manaos Cola 2,25 L', 'x12', 'Soda sifón 1,5 L', 'x8'],
  },
  {
    id: EN_PREPARACION,
    textos: [
      'Despensa El Trébol', 'Lavalle 780, Barrio Sur, San Miguel de Tucumán', '#18421',
      '$ 62.400,00', 'Nahuel Juárez',
    ],
    // Exactamente 3 productos: entran todos y no hay "+N más".
    ausentes: [/^\+\d+ más$/],
    enDetalle: [
      '17/9', hora('10:02'), 'Efectivo',
      'Yerba mate Cruz de Malta 1 kg', 'x6', 'Azúcar Concepción 1 kg', 'x12', 'Fideos tirabuzón 500 g', 'x18',
    ],
  },
  {
    id: ASIGNADO,
    textos: [
      'Almacén Don Ramón', 'Bolívar 3450, Villa Luján, San Miguel de Tucumán', '#18398',
      '$ 95.180,00', 'Nahuel Juárez', 'Gustavo Paz',
    ],
    enDetalle: [
      '15/9', hora('08:47'),
      'Aceite de girasol 900 ml', 'x12', 'Harina 000 x 1 kg', 'x20', 'Manaos Naranja 2,25 L', 'x10',
    ],
  },
  {
    id: ENTREGADO_FC,
    textos: [
      'Autoservicio Yerba Buena', 'Av. Aconquija 1890, Yerba Buena', '#18355',
      '$ 412.600,00', 'Nahuel Juárez', 'Gustavo Paz',
      // FC se ve para todos: boton para el admin, texto para el resto.
      'FC',
      // 9 items: la tarjeta dice cuantos son; todos estan en el detalle.
      '9 ítems',
    ],
    ausentes: ['Yerba mate Cruz de Malta 1 kg', 'Vinagre de alcohol 500 ml'],
    enDetalle: [
      '12/9', hora('07:58'), 'Combinado',
      'Manaos Cola 2,25 L', 'x40', 'Manaos Naranja 2,25 L', 'x32', 'Agua mineral sin gas 2 L', 'x24',
    ],
  },
  {
    id: ENTREGADO_SALVEDAD,
    textos: [
      'Almacén Don Ramón', '#18371', '$ 46.200,00', 'Nahuel Juárez', 'Gustavo Paz',
    ],
    enDetalle: [
      '14/9', hora('11:31'), 'Efectivo',
      'Soda sifón 1,5 L', 'x10', 'Agua mineral sin gas 2 L', 'x8',
    ],
  },
  {
    id: CANCELADO,
    textos: [
      'Despensa El Trébol', '#18312', '$ 0,00', 'Nahuel Juárez',
    ],
    enDetalle: [
      '10/9', hora('16:20'),
      // El motivo sale de la tarjeta cerrada: queda en el detalle (y como
      // tooltip del badge "Cancelado").
      'CERRADO — el local no abrió en las dos barridas del día.',
      'Fideos tirabuzón 500 g', 'x12',
    ],
  },
  {
    id: GPS_DENEGADO,
    textos: [
      'Kiosco La Esquina', 'Av. Sarmiento 1240, San Miguel de Tucumán', '#18433',
      '$ 14.500,00', 'Nahuel Juárez',
    ],
    enDetalle: ['17/9', hora('12:44'), 'Manaos Cola 2,25 L', 'x10'],
  },
  {
    id: GPS_LEJOS,
    textos: [
      'Autoservicio Yerba Buena', 'Av. Aconquija 1890, Yerba Buena', '#18434',
      '$ 88.300,00', 'Nahuel Juárez', 'FC',
    ],
    enDetalle: [
      '17/9', hora('13:05'),
      'Agua mineral sin gas 2 L', 'x30', 'Manaos Naranja 2,25 L', 'x24',
    ],
  },
]

describe('PedidoCard cerrada — los datos que se ven, iguales para los 5 roles', () => {
  const casos = ROLES_GALERIA.flatMap(rol => TARJETAS_CERRADAS.map(t => ({ rol, ...t })))

  it.each(casos)('$rol ve cliente, direccion, #id, total y personas en la tarjeta, y fecha, hora, pago y productos en el detalle de #$id', async ({ rol, id, textos, ausentes, enDetalle }) => {
    renderCard(fixture(id), rol)
    for (const t of textos) seVe(t)
    for (const t of ausentes ?? []) noSeVe(t)
    await expandir()
    for (const t of enDetalle ?? []) seVe(t)
  })

  it('un pedido sin cliente cargado dice "Sin cliente"', () => {
    renderCard({ ...fixture(PENDIENTE), cliente: undefined }, 'admin')
    seVe('Sin cliente')
  })

  it('la entrega programada se ve mientras el pedido esta activo', () => {
    renderCard(fixture(EN_PREPARACION), 'deposito')
    seVe('entrega 18/9')
  })

  it('la entrega programada de hoy tambien se ve (asignado)', () => {
    renderCard(fixture(ASIGNADO), 'transportista')
    seVe('entrega 17/9')
  })

  it.each([ENTREGADO_FC, CANCELADO])('la entrega programada NO se ve en #%s (entregado/cancelado), aunque tenga fecha', id => {
    renderCard({ ...fixture(id), fecha_entrega_programada: '2026-09-18' }, 'admin')
    noSeVe(/^entrega /)
  })

  // La antiguedad paso al detalle en WP-43: se expande antes de mirar.
  it('la antiguedad se marca a partir de los 2 dias en un pedido sin entregar', async () => {
    renderCard(fixture(ASIGNADO), 'deposito')
    await expandir()
    seVe('2d')
  })

  it('un pedido de hoy no marca antiguedad', async () => {
    renderCard(fixture(PENDIENTE), 'deposito')
    await expandir()
    noSeVe(/^\d+d$/)
  })

  it('un entregado no marca antiguedad', async () => {
    renderCard(fixture(ENTREGADO_FC), 'deposito')
    await expandir()
    noSeVe(/^\d+d$/)
  })

  it('un cancelado de hace 7 dias no marca antiguedad', async () => {
    // Antes (BUG): la antiguedad es una alarma de "esto lleva dias sin
    // entregarse" y BadgeAntiguedad solo se apagaba en 'entregado', asi que un
    // cancelado de hace 7 dias marcaba "7d" como si estuviera demorado. Ahora se
    // apaga tambien en 'cancelado' (#816).
    renderCard(fixture(CANCELADO), 'deposito')
    await expandir()
    noSeVe(/^\d+d$/)
  })

  it('un pendiente de hace 7 dias si marca "7d" de antiguedad', async () => {
    // La contraparte del caso anterior: lo que se apago es el cancelado, no la
    // alarma. Mismo pedido de hace 7 dias, pero todavia sin entregar.
    renderCard({ ...fixture(PENDIENTE), fecha: '2026-09-10' }, 'deposito')
    await expandir()
    seVe('7d')
  })

  it('el chip de cada persona dice quien es: quien cargo el pedido y quien lo lleva', () => {
    // Los dos son un nombre con un icono (aria-hidden). Lo unico que dice, en
    // texto, que Nahuel CARGO el pedido y Gustavo lo LLEVA es el tooltip. Con
    // "iconos por dato" (WP-43) es facil perderlo y dejar dos nombres sueltos.
    renderCard(fixture(ASIGNADO), 'deposito')
    expect(etiquetados(/cargado por/i).map(textoExpuesto).join(' | ')).toMatch(/Nahuel Juárez/)
    expect(etiquetados(/transportista/i).map(textoExpuesto).join(' | ')).toMatch(/Gustavo Paz/)
  })
})

// El GPS paso al detalle en WP-43: cada caso expande antes de mirar (tambien
// los "no se ve", para que no pasen por no haber abierto nada).
describe('PedidoCard — GPS del check-in: solo admin y el preventista dueno', () => {
  it.each([
    { rol: 'admin', ve: true },
    { rol: 'preventista', ve: true },
    { rol: 'encargado', ve: false },
    { rol: 'transportista', ve: false },
    { rol: 'deposito', ve: false },
  ] as const)('$rol ve "Sin GPS" en un check-in con GPS denegado: $ve', async ({ rol, ve }) => {
    renderCard(fixture(GPS_DENEGADO), rol)
    await expandir()
    if (ve) seVe('Sin GPS')
    else noSeVe('Sin GPS')
  })

  it('el preventista no ve el GPS de un pedido que cargo otra preventista', async () => {
    renderCard({ ...fixture(GPS_DENEGADO), usuario_id: OTRA_PREVENTISTA.id }, 'preventista')
    await expandir()
    noSeVe('Sin GPS')
  })

  it('con GPS ok muestra la distancia a la direccion del cliente', async () => {
    renderCard(fixture(GPS_LEJOS), 'admin')
    await expandir()
    seVe('2.4 km')
  })

  it('la distancia lleva por texto la clasificacion del semaforo, no solo el color', async () => {
    renderCard(fixture(GPS_LEJOS), 'admin')
    await expandir()
    expect(etiquetados(/Lejos del cliente/).length).toBeGreaterThan(0)
  })

  it.each([
    { gps_status: 'denied', motivo: 'GPS denegado' },
    { gps_status: 'timeout', motivo: 'GPS sin respuesta' },
    { gps_status: 'unavailable', motivo: 'GPS no disponible' },
    { gps_status: 'error', motivo: 'GPS con error' },
  ] as const)('un check-in con GPS $gps_status dice "Sin GPS" y el motivo "$motivo"', async ({ gps_status, motivo }) => {
    renderCard({ ...fixture(GPS_DENEGADO), gps_status }, 'admin')
    await expandir()
    seVe('Sin GPS')
    expect(etiquetados(motivo).length).toBeGreaterThan(0)
  })

  it('GPS ok contra un cliente sin coordenadas dice "s/ref" en vez de una distancia', async () => {
    const base = fixture(GPS_LEJOS)
    renderCard({ ...base, cliente: base.cliente && { ...base.cliente, latitud: null, longitud: null } }, 'admin')
    await expandir()
    seVe('s/ref')
    noSeVe(/^\d+(\.\d)? k?m$/)
  })

  it('un pedido sin check-in (sin gps_status) no muestra ningun chip de GPS', async () => {
    renderCard(fixture(PENDIENTE), 'admin')
    await expandir()
    noSeVe('Sin GPS')
    noSeVe('s/ref')
    noSeVe(/^\d+(\.\d)? k?m$/)
  })
})

// =============================================================================
// 5. ESTADO DEL PEDIDO Y ESTADO DE PAGO, por texto
// =============================================================================

const POR_ESTADO = [
  { estado: 'pendiente', id: PENDIENTE, etiqueta: 'Pendiente', pago: 'Pago Pendiente', extra: [] },
  { estado: 'en_preparacion', id: EN_PREPARACION, etiqueta: 'En preparación', pago: 'Pago Parcial', extra: ['Pagado: $ 30.000,00 de $ 62.400,00'] },
  { estado: 'asignado', id: ASIGNADO, etiqueta: 'En camino', pago: 'Pago Pendiente', extra: [] },
  { estado: 'entregado', id: ENTREGADO_FC, etiqueta: 'Entregado', pago: 'Pagado', extra: [] },
  // El fixture llega sin `estado_pago` (asi vienen los cancelados viejos).
  { estado: 'cancelado', id: CANCELADO, etiqueta: 'Cancelado', pago: null, extra: [] },
] as const

describe('PedidoCard — estado del pedido y estado de pago, por texto', () => {
  it.each(POR_ESTADO)('$estado (#$id): el estado de pago dice $pago', async ({ id, pago, extra }) => {
    renderCard(fixture(id), 'deposito')
    for (const etiqueta of ETIQUETAS_PAGO) {
      if (etiqueta === pago) seVe(etiqueta)
      else noSeVe(etiqueta)
    }
    // "Pagado: X de Y" sigue a la vista con la tarjeta cerrada (línea 2).
    for (const t of extra) seVe(t)
    // "Pagado: X de Y" es solo del pago parcial.
    if (pago !== 'Pago Parcial') noSeVe(/^Pagado: /)
  })

  it('el pago parcial de un entregado con salvedad tambien dice cuanto se pago', async () => {
    renderCard(fixture(ENTREGADO_SALVEDAD), 'deposito')
    seVe('Pago Parcial')
    seVe('Pagado: $ 30.000,00 de $ 46.200,00')
  })

  it.each(POR_ESTADO)('$estado (#$id): la tarjeta dice por texto en que estado esta, y solo ese', ({ id, etiqueta }) => {
    // Antes (BUG): el stepper mostraba los mismos 4 pasos en los cinco estados
    // y el actual solo se distinguia por color; un lector de pantalla no podia
    // saber si estaba pendiente o en camino. WP-43 saca el stepper y pone el
    // badge de estado con su texto: esto fija el arreglo.
    renderCard(fixture(id), 'deposito')
    seVe(etiqueta)
    for (const otra of ETIQUETAS_ESTADO) {
      if (otra !== etiqueta) noSeVe(otra)
    }
  })

  it('un entregado con salvedad dice "Con Salvedad" en vez de "Entregado"', () => {
    renderCard(fixture(ENTREGADO_SALVEDAD), 'deposito')
    seVe('Con Salvedad')
    noSeVe('Entregado')
  })

  it('un cancelado sin motivo dice "Cancelado" por texto', () => {
    // Antes (BUG): para 'cancelado' el stepper no marcaba ningun paso y, sin
    // motivo, la tarjeta no tenia una sola palabra que dijera "cancelado"; solo
    // se notaba por el total en $0. El badge de estado de WP-43 lo arregla.
    renderCard({ ...fixture(CANCELADO), motivo_cancelacion: undefined }, 'admin')
    seVe('Cancelado')
  })

  it('un cancelado con motivo lo tiene a mano sin abrir el detalle: tooltip del badge "Cancelado"', () => {
    // La tarjeta cerrada dejó de mostrar el motivo (WP-43); entero sigue en el
    // detalle, y cerrada lo lleva el badge de estado.
    renderCard(fixture(CANCELADO), 'admin')
    expect(etiquetados(/^Cancelado: CERRADO/).length).toBeGreaterThan(0)
  })

  it('un anulado (#1060) dice "Anulado" con el mismo icono que un cancelado, no el reloj del fallback', () => {
    // 'anulado' esta en pedidos_estado_check y la lista lo trae con "Incluir
    // cancelados". Sin entrada en ESTADO_VISUAL caia en { icon: Clock }: un
    // reloj de pendiente sobre un pedido que no es venta.
    renderCard({ ...fixture(CANCELADO), estado: 'anulado', motivo_cancelacion: undefined }, 'admin')
    seVe('Anulado')
    noSeVe('Cancelado')
    const badge = screen.getAllByText('Anulado')[0]
    const svg = badge.parentElement?.querySelector('svg') ?? badge.querySelector('svg')
    expect(svg?.getAttribute('class') ?? '').not.toMatch(/lucide-clock/)
    expect(svg?.getAttribute('class') ?? '').toMatch(/lucide-(circle-x|x-circle)/)
  })
})

// =============================================================================
// 2. DETALLE EXPANDIDO
// =============================================================================

describe('PedidoCard — detalle expandido ("Ver detalle")', () => {
  it('"Ver detalle" arranca cerrado, abre la region que controla y la vuelve a cerrar', async () => {
    renderCard(fixture(ASIGNADO), 'admin')
    const boton = screen.getByRole('button', { name: 'Ver detalle del pedido' })
    expect(boton).toHaveAttribute('aria-expanded', 'false')
    const idRegion = boton.getAttribute('aria-controls')
    expect(idRegion).toBeTruthy()
    // Cerrado: la region no esta o esta oculta. Hoy no se monta; montarla con
    // `hidden` tambien es cerrado, y no deberia romper este test.
    const cerrada = (): void => {
      const region = document.getElementById(idRegion as string)
      if (region) expect(region).not.toBeVisible()
      for (const el of screen.queryAllByText('CUIT: 20-00000000-9')) expect(el).not.toBeVisible()
    }
    cerrada()

    const user = userEvent.setup()
    await user.click(boton)
    expect(boton).toHaveAttribute('aria-expanded', 'true')
    expect(boton).toHaveAccessibleName('Ocultar detalle del pedido')
    expect(document.getElementById(idRegion as string)).toBeVisible()
    seVe('CUIT: 20-00000000-9')

    await user.click(boton)
    expect(boton).toHaveAttribute('aria-expanded', 'false')
    cerrada()
  })

  it.each(ROLES_GALERIA)('%s ve el cliente completo: razon social, CUIT, direccion, telefono y contacto', async rol => {
    renderCard(fixture(ASIGNADO), rol)
    await expandir()
    seVe('Ramón Ernesto Ledesma')
    seVe('CUIT: 20-00000000-9')
    seVe('Bolívar 3450, Villa Luján, San Miguel de Tucumán')
    const telefono = screen.getByRole('link', { name: '381 466-9013' })
    expect(telefono).toHaveAttribute('href', 'tel:381 466-9013')
    seVe('(Ramón)')
  })

  it('un cliente sin razon social ni CUIT no muestra esas filas, pero si el telefono', async () => {
    renderCard(fixture(EN_PREPARACION), 'admin')
    await expandir()
    noSeVe(/^CUIT:/)
    expect(screen.getByRole('link', { name: '381 431-1155' })).toHaveAttribute('href', 'tel:381 431-1155')
  })

  it('lista TODOS los items (no solo los 3 de la tarjeta) con precio unitario, cantidad y subtotal', async () => {
    renderCard(fixture(ENTREGADO_FC), 'admin')
    await expandir()
    seVe('Productos (9)')
    for (const nombre of [
      'Manaos Cola 2,25 L', 'Manaos Naranja 2,25 L', 'Agua mineral sin gas 2 L', 'Yerba mate Cruz de Malta 1 kg',
      'Aceite de girasol 900 ml', 'Fideos tirabuzón 500 g', 'Azúcar Concepción 1 kg', 'Vinagre de alcohol 500 ml',
    ]) seVe(nombre)
    // Manaos Cola: 40 x $1.450 = $58.000.
    seVe('x40')
    seVe('$ 1.450,00 c/u')
    seVe('$ 58.000,00')
  })

  it('el regalo se lista con su descripcion, la marca REGALO y $0', async () => {
    renderCard(fixture(ENTREGADO_FC), 'admin')
    await expandir()
    seVe('Regalo por volumen · 1 bolsón cada 10')
    seVe('REGALO')
    seVe('x50')
    seVe('$0')
  })

  it('un regalo sustituido muestra el producto actual y la marca "Sustituido"', async () => {
    const base = fixture(ENTREGADO_FC)
    const pedido: PedidoDB = {
      ...base,
      items: base.items?.map(i => (i.es_bonificacion
        ? { ...i, descripcion_regalo: 'Regalo por volumen [Sustituido por: Harina 000 x 1 kg]' }
        : i)),
    }
    renderCard(pedido, 'admin')
    await expandir()
    seVe('Sustituido')
    seVe('REGALO')
    noSeVe('Regalo por volumen [Sustituido por: Harina 000 x 1 kg]')
  })

  it('un item con salvedad muestra motivo, cantidad pedida -> entregada y lo descontado', async () => {
    renderCard(fixture(ENTREGADO_SALVEDAD), 'admin')
    await expandir()
    seVe('Producto Dañado')
    seVe('Pedido: 12 → Entregado: 10 (2 no entregadas)')
    seVe('-$ 1.960,00')
  })

  it('la seccion de salvedades lista cada una con su estado de resolucion y el total afectado', async () => {
    renderCard(fixture(ENTREGADO_SALVEDAD), 'admin')
    await expandir()
    seVe('Salvedades (1)')
    seVe('Producto Dañado - 2 unidad(es)')
    seVe('Pendiente de resolver')
    seVe('Total afectado:')
  })

  it('con varias salvedades distingue las resueltas y suma el total afectado', async () => {
    const base = fixture(ENTREGADO_SALVEDAD)
    const pedido: PedidoDB = {
      ...base,
      salvedades: [
        ...(base.salvedades ?? []),
        {
          id: 'sv-2',
          motivo: 'faltante_stock',
          cantidad_afectada: 2,
          monto_afectado: 2_240,
          estado_resolucion: 'nota_credito',
          producto_id: PRODUCTOS_FIXTURE.aguaMineral.id,
        },
      ],
    }
    renderCard(pedido, 'admin')
    await expandir()
    seVe('Salvedades (2)')
    seVe('Faltante de Stock - 2 unidad(es)')
    // Cualquier estado distinto de 'pendiente' se muestra como "Resuelta".
    seVe('Resuelta')
    seVe('Pendiente de resolver')
    seVe('Pedido: 10 → Entregado: 8 (2 no entregadas)')
    // 1.960 + 2.240
    seVe('-$ 4.200,00')
  })

  it('con los ids como los manda PostgREST, la seccion de salvedades tambien nombra el producto', async () => {
    // Antes (BUG): `pedido_items(*)` llega de PostgREST con `producto_id`
    // numerico (bigint -> number), pero `enrichWithSalvedades`
    // (usePedidosQuery.ts) lo pasa a String. La fila del item compara con
    // String() de los dos lados y encuentra la salvedad; la seccion "Salvedades"
    // comparaba con `===` (PedidoCard.tsx, `productoItem`) y no la encontraba
    // nunca: en produccion cada salvedad decia "Producto" en vez del nombre.
    // Ahora normaliza igual que la fila del item (#816).
    const base = fixture(ENTREGADO_SALVEDAD)
    const pedido: PedidoDB = {
      ...base,
      items: base.items?.map(i => ({ ...i, producto_id: Number(i.producto_id) as unknown as string })),
    }
    renderCard(pedido, 'admin')
    await expandir()
    // La fila del item cruza la salvedad...
    seVe('Pedido: 12 → Entregado: 10 (2 no entregadas)')
    // ...y la seccion de salvedades tambien: sale el nombre del producto, no el
    // "Producto" de relleno. El nombre aparece al menos dos veces: en la fila del
    // item y en la salvedad.
    noSeVe('Producto')
    expect(screen.queryAllByText(PRODUCTOS_FIXTURE.sodaSifon.nombre).length).toBeGreaterThanOrEqual(2)
  })

  it('con los ids del mismo tipo, la seccion de salvedades nombra el producto', async () => {
    renderCard(fixture(ENTREGADO_SALVEDAD), 'admin')
    await expandir()
    noSeVe('Producto')
  })

  it('un regalo fraccionado dice que la cantidad es en botellas y cuantos fardos son', async () => {
    // Fue un bug real (#534, #552): "x392" a secas se leia como 392 fardos.
    const base = fixture(ENTREGADO_FC)
    const pedido: PedidoDB = {
      ...base,
      items: base.items?.map(i => (i.es_bonificacion ? { ...i, cantidad: 392, unidades_por_bloque_al_crear: 6 } : i)),
    }
    renderCard(pedido, 'admin')
    await expandir()
    seVe('x392 botellas')
    seVe('≈ 65,3 fardos')
  })

  it('un pago combinado se desglosa por forma de pago', async () => {
    renderCard(fixture(ENTREGADO_FC), 'admin')
    await expandir()
    seVe('Combinado')
    seVe('Transferencia')
    seVe('$ 300.000,00')
    seVe('Efectivo')
    seVe('$ 112.600,00')
  })

  it('un cancelado muestra el motivo de cancelacion en su propia seccion', async () => {
    renderCard(fixture(CANCELADO), 'admin')
    await expandir()
    seVe('Motivo de cancelacion')
    seVe('CERRADO — el local no abrió en las dos barridas del día.')
  })

  it('las notas del pedido estan en el detalle', async () => {
    renderCard(fixture(ENTREGADO_SALVEDAD), 'admin')
    await expandir()
    seVe('Notas')
    seVe('Dejar en el depósito del fondo. Preguntar por Ramón antes de descargar.')
  })

  it('el transportista se nombra en el detalle, o "Sin asignar"', async () => {
    renderCard(fixture(CANCELADO), 'admin')
    await expandir()
    seVe('Sin asignar')
  })
})

// =============================================================================
// 3. EL KEBAB (AccionesDropdown) MONTADO DENTRO DE LA CARD
// =============================================================================
// PedidoActions.test.tsx prueba el menu AISLADO con props armadas a mano. Esto
// prueba lo que la card le pasa de verdad: los flags de rol, el `currentUserId`
// de la sesion y cada handler. Si la card deja de pasar `isEncargado`, se caen
// las filas del encargado; si deja de pasar `currentUserId`, el transportista
// pierde "Marcar Entregado" sobre su parada y el preventista cae a
// "Editar Observaciones" sobre su pedido de hoy.
//
// Se asevera el conjunto de acciones ALCANZABLES (botones visibles + kebab),
// no el kebab solo: WP-43 saca una accion principal afuera y eso no es perder
// nada. La matriz cubre los 8 fixtures de la galeria x los 5 roles, que es la
// base del criterio de aceptacion de #768 ("la accion principal coincide con
// una opcion que HOY existe para ese rol x estado").

interface CasoMenu {
  rol: RolUsuario
  id: string
  esperado: readonly string[]
}

const MATRIZ_EN_CARD: readonly CasoMenu[] = [
  // --- admin ---
  { rol: 'admin', id: PENDIENTE, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO, CANCELAR] },
  { rol: 'admin', id: EN_PREPARACION, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, CANCELAR] },
  { rol: 'admin', id: ASIGNADO, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, SALVEDAD, CANCELAR] },
  { rol: 'admin', id: ENTREGADO_FC, esperado: [HISTORIAL, IMPRIMIR, EDITAR, VER_EDITAR_PAGOS, REVERTIR] },
  { rol: 'admin', id: ENTREGADO_SALVEDAD, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, REVERTIR] },
  { rol: 'admin', id: CANCELADO, esperado: [HISTORIAL, IMPRIMIR] },

  // --- encargado: lo mismo sin "Cancelar Pedido" ---
  { rol: 'encargado', id: PENDIENTE, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO] },
  { rol: 'encargado', id: EN_PREPARACION, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO] },
  { rol: 'encargado', id: ASIGNADO, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, SALVEDAD] },
  { rol: 'encargado', id: ENTREGADO_FC, esperado: [HISTORIAL, IMPRIMIR, EDITAR, VER_EDITAR_PAGOS, REVERTIR] },
  { rol: 'encargado', id: ENTREGADO_SALVEDAD, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, REVERTIR] },
  { rol: 'encargado', id: CANCELADO, esperado: [HISTORIAL, IMPRIMIR] },

  // --- preventista: dueno de todos los fixtures; 14:00 ARG ---
  { rol: 'preventista', id: PENDIENTE, esperado: [HISTORIAL, EDITAR_PEDIDO] },
  { rol: 'preventista', id: EN_PREPARACION, esperado: [HISTORIAL, EDITAR_PEDIDO] },
  // Cargado hace 2 dias: la ventana es del mismo dia, cae a observaciones.
  { rol: 'preventista', id: ASIGNADO, esperado: [HISTORIAL, EDITAR_OBS] },
  { rol: 'preventista', id: ENTREGADO_FC, esperado: [HISTORIAL, EDITAR_OBS] },
  { rol: 'preventista', id: ENTREGADO_SALVEDAD, esperado: [HISTORIAL, EDITAR_OBS] },
  { rol: 'preventista', id: CANCELADO, esperado: [HISTORIAL, EDITAR_OBS] },

  // --- transportista: la parada es suya en asignado y en los entregados ---
  { rol: 'transportista', id: PENDIENTE, esperado: [HISTORIAL] },
  { rol: 'transportista', id: EN_PREPARACION, esperado: [HISTORIAL] },
  { rol: 'transportista', id: ASIGNADO, esperado: [HISTORIAL, ENTREGADO, SALVEDAD] },
  { rol: 'transportista', id: ENTREGADO_FC, esperado: [HISTORIAL] },
  { rol: 'transportista', id: ENTREGADO_SALVEDAD, esperado: [HISTORIAL] },
  { rol: 'transportista', id: CANCELADO, esperado: [HISTORIAL] },

  // --- deposito: solo mira ---
  { rol: 'deposito', id: PENDIENTE, esperado: [HISTORIAL] },
  { rol: 'deposito', id: EN_PREPARACION, esperado: [HISTORIAL] },
  { rol: 'deposito', id: ASIGNADO, esperado: [HISTORIAL] },
  { rol: 'deposito', id: ENTREGADO_FC, esperado: [HISTORIAL] },
  { rol: 'deposito', id: ENTREGADO_SALVEDAD, esperado: [HISTORIAL] },
  { rol: 'deposito', id: CANCELADO, esperado: [HISTORIAL] },

  // --- los dos pendientes con GPS: mismo menu que cualquier pendiente de hoy ---
  { rol: 'admin', id: GPS_DENEGADO, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO, CANCELAR] },
  { rol: 'admin', id: GPS_LEJOS, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO, CANCELAR] },
  { rol: 'encargado', id: GPS_DENEGADO, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO] },
  { rol: 'encargado', id: GPS_LEJOS, esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO] },
  { rol: 'preventista', id: GPS_DENEGADO, esperado: [HISTORIAL, EDITAR_PEDIDO] },
  { rol: 'preventista', id: GPS_LEJOS, esperado: [HISTORIAL, EDITAR_PEDIDO] },
  { rol: 'transportista', id: GPS_DENEGADO, esperado: [HISTORIAL] },
  { rol: 'transportista', id: GPS_LEJOS, esperado: [HISTORIAL] },
  { rol: 'deposito', id: GPS_DENEGADO, esperado: [HISTORIAL] },
  { rol: 'deposito', id: GPS_LEJOS, esperado: [HISTORIAL] },
]

/** Un cancelado al que le quedo plata cargada (el fixture tiene monto_pagado 0). */
function canceladoConPagos(): PedidoDB {
  return { ...fixture(CANCELADO), monto_pagado: 15_000 }
}

/** El preventista que tambien reparte (rol extra, mig 155): los dos flags a la vez. */
const PREVENTISTA_QUE_REPARTE: FlagsDeRol = {
  isAdmin: false, isPreventista: true, isTransportista: true, isEncargado: false,
}

/** El asignado del fixture, con la preventista duena como chofer de la parada. */
function paradaDeLaPreventista(extra: Partial<PedidoDB> = {}): PedidoDB {
  return {
    ...fixture(ASIGNADO),
    transportista_id: PREVENTISTA_DUENA.id,
    transportista: PREVENTISTA_DUENA,
    ...extra,
  }
}

describe('PedidoCard — las acciones alcanzables desde la card', () => {
  it.each(MATRIZ_EN_CARD)('$rol sobre #$id alcanza exactamente sus acciones', async ({ rol, id, esperado }) => {
    renderCard(fixture(id), rol)
    expect(await accionesAlcanzables()).toEqual(ordenado(esperado))
  })

  it.each([
    { rol: 'admin', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, SALVEDAD, CANCELAR] },
    { rol: 'transportista', esperado: [HISTORIAL, ENTREGADO, SALVEDAD] },
  ] as const)('todas las copias del kebab (con lo visible) le ofrecen lo mismo al $rol', async ({ rol, esperado }) => {
    // Hoy hay dos (desktop y mobile) con las mismas props escritas dos veces. Si
    // el rediseno toca una sola, este test lo ve; si las unifica, sigue verde.
    renderCard(fixture(ASIGNADO), rol)
    const copias = kebabs()
    expect(copias.length).toBeGreaterThan(0)
    for (const kebab of copias) {
      expect(await accionesAlcanzables(kebab)).toEqual(ordenado(esperado))
      await cerrarMenu()
    }
  })

  it('el transportista sobre la parada de OTRO chofer solo ve el historial', async () => {
    renderCard({
      ...fixture(ASIGNADO),
      transportista_id: OTRO_TRANSPORTISTA.id,
      transportista: OTRO_TRANSPORTISTA,
    }, 'transportista')
    expect(await accionesAlcanzables()).toEqual([HISTORIAL])
  })

  it('el preventista, pasadas las 15:30 ARG, solo edita observaciones de su pedido de hoy', async () => {
    vi.setSystemTime(DESPUES_DEL_CORTE)
    renderCard(fixture(PENDIENTE), 'preventista')
    expect(await accionesAlcanzables()).toEqual(ordenado([HISTORIAL, EDITAR_OBS]))
  })

  it('el preventista sobre un pedido de otra preventista cae a observaciones aunque sea temprano', async () => {
    renderCard({ ...fixture(PENDIENTE), usuario_id: OTRA_PREVENTISTA.id }, 'preventista')
    expect(await accionesAlcanzables()).toEqual(ordenado([HISTORIAL, EDITAR_OBS]))
  })

  it.each([
    { rol: 'admin', esperado: [HISTORIAL, IMPRIMIR, VER_ANULAR_PAGOS] },
    { rol: 'encargado', esperado: [HISTORIAL, IMPRIMIR, VER_ANULAR_PAGOS] },
    { rol: 'preventista', esperado: [HISTORIAL, EDITAR_OBS] },
    { rol: 'transportista', esperado: [HISTORIAL] },
    { rol: 'deposito', esperado: [HISTORIAL] },
  ] as const)('un cancelado con plata cargada: lo que alcanza el $rol', async ({ rol, esperado }) => {
    // "Ver/Anular Pagos" es la unica accion de pago sobre un cancelado, solo
    // del staff y solo si `monto_pagado > 0`: antes anular esos pagos era SQL.
    renderCard(canceladoConPagos(), rol)
    expect(await accionesAlcanzables()).toEqual(ordenado(esperado))
  })

  it.each([
    // Cargado hace 2 dias: fuera de la ventana de edicion.
    { caso: 'de hace 2 dias', extra: {}, editar: EDITAR_OBS },
    // Cargado hoy a las 09:00, y son las 14:00: dentro de la ventana.
    { caso: 'de hoy', extra: { fecha: '2026-09-17', created_at: '2026-09-17T09:00:00-03:00' }, editar: EDITAR_PEDIDO },
  ])('el preventista que tambien reparte, sobre su propia parada $caso, edita Y entrega', async ({ extra, editar }) => {
    // Multi-rol (mig 155): los dos caminos del menu se suman. Es el caso donde
    // "la" accion principal compite entre editar y entregar.
    renderCard(paradaDeLaPreventista(extra), 'preventista', { flags: PREVENTISTA_QUE_REPARTE })
    expect(await accionesAlcanzables()).toEqual(ordenado([HISTORIAL, editar, ENTREGADO, SALVEDAD]))
  })

  it('el preventista que tambien reparte, sobre la parada de otro chofer, no entrega', async () => {
    renderCard(fixture(ASIGNADO), 'preventista', { flags: PREVENTISTA_QUE_REPARTE })
    expect(await accionesAlcanzables()).toEqual(ordenado([HISTORIAL, EDITAR_OBS]))
  })

  it('BUG latente: sin la prop isEncargado (como la monta VirtualizedPedidoList) el encargado queda como deposito', async () => {
    // BUG (en VirtualizedPedidoList, no en la card): esa lista no le pasa
    // `isEncargado` a la card. La card decide acciones y FC/ZZ por PROPS, pero el
    // aviso de deuda por `perfil.rol` de la sesion (ver el comentario de la
    // card). Resultado: el encargado ve la deuda, pero pierde todas las acciones
    // y el cambio FC/ZZ. Hoy VirtualizedPedidoList no tiene consumidores; si se
    // conecta, deberia pasar `isEncargado` como VistaPedidos.
    renderCard(fixture(ASIGNADO), 'encargado', {
      flags: { isAdmin: false, isPreventista: false, isTransportista: false },
    })
    seVe('Debe $ 184.300,00')
    expect(screen.queryByRole('button', { name: 'ZZ' })).not.toBeInTheDocument()
    expect(await accionesAlcanzables()).toEqual([HISTORIAL])
  })
})

interface Eleccion {
  rol: RolUsuario
  id: string
  opcion: string
  handler: keyof Handlers
}

const ELECCIONES: readonly Eleccion[] = [
  { rol: 'admin', id: PENDIENTE, opcion: HISTORIAL, handler: 'onVerHistorial' },
  { rol: 'admin', id: PENDIENTE, opcion: EDITAR, handler: 'onEditarPedido' },
  { rol: 'admin', id: PENDIENTE, opcion: REGISTRAR_PAGO, handler: 'onRegistrarPago' },
  { rol: 'admin', id: PENDIENTE, opcion: PREPARAR, handler: 'onMarcarEnPreparacion' },
  { rol: 'admin', id: PENDIENTE, opcion: ENTREGADO, handler: 'onMarcarEntregado' },
  { rol: 'admin', id: PENDIENTE, opcion: CANCELAR, handler: 'onCancelarPedido' },
  { rol: 'admin', id: EN_PREPARACION, opcion: VOLVER, handler: 'onVolverAPendiente' },
  { rol: 'admin', id: ASIGNADO, opcion: SALVEDAD, handler: 'onMarcarEntregadoConSalvedad' },
  { rol: 'admin', id: ENTREGADO_FC, opcion: REVERTIR, handler: 'onDesmarcarEntregado' },
  { rol: 'admin', id: ENTREGADO_FC, opcion: VER_EDITAR_PAGOS, handler: 'onRegistrarPago' },
  { rol: 'encargado', id: ASIGNADO, opcion: EDITAR, handler: 'onEditarPedido' },
  { rol: 'encargado', id: ASIGNADO, opcion: ENTREGADO, handler: 'onMarcarEntregado' },
  { rol: 'encargado', id: ENTREGADO_SALVEDAD, opcion: REGISTRAR_PAGO, handler: 'onRegistrarPago' },
  { rol: 'encargado', id: ENTREGADO_SALVEDAD, opcion: REVERTIR, handler: 'onDesmarcarEntregado' },
  { rol: 'preventista', id: PENDIENTE, opcion: EDITAR_PEDIDO, handler: 'onEditarPedido' },
  { rol: 'preventista', id: ENTREGADO_FC, opcion: EDITAR_OBS, handler: 'onEditarNotas' },
  { rol: 'transportista', id: ASIGNADO, opcion: ENTREGADO, handler: 'onMarcarEntregado' },
  { rol: 'transportista', id: ASIGNADO, opcion: SALVEDAD, handler: 'onMarcarEntregadoConSalvedad' },
  { rol: 'deposito', id: ASIGNADO, opcion: HISTORIAL, handler: 'onVerHistorial' },
]

/** Que se haya llamado SOLO a `handler`, una vez y con el pedido. */
function soloLlamo(handlers: Handlers, handler: keyof Handlers, pedido: PedidoDB): void {
  expect(handlers[handler]).toHaveBeenCalledTimes(1)
  expect(handlers[handler]).toHaveBeenCalledWith(pedido)
  for (const [nombre, fn] of Object.entries(handlers)) {
    if (nombre !== handler) expect(fn, `${nombre} no deberia llamarse`).not.toHaveBeenCalled()
  }
}

describe('PedidoCard — cada accion llama al handler que recibio la card', () => {
  it.each(ELECCIONES)('$rol elige $opcion sobre #$id: llama a $handler con el pedido y a nadie mas', async ({ rol, id, opcion, handler }) => {
    const { handlers, pedido } = renderCard(fixture(id), rol)
    await elegir(opcion)
    soloLlamo(handlers, handler, pedido)
  })

  it('"Ver/Anular Pagos" de un cancelado abre el mismo handler de pago que "Registrar Pago"', async () => {
    const { handlers, pedido } = renderCard(canceladoConPagos(), 'admin')
    await elegir(VER_ANULAR_PAGOS)
    soloLlamo(handlers, 'onRegistrarPago', pedido)
  })

  it('el preventista que tambien reparte entrega su parada con el handler de entrega', async () => {
    const { handlers, pedido } = renderCard(paradaDeLaPreventista(), 'preventista', { flags: PREVENTISTA_QUE_REPARTE })
    await elegir(ENTREGADO)
    soloLlamo(handlers, 'onMarcarEntregado', pedido)
  })

  it('"Imprimir Comanda" no es un handler de afuera: la card genera la comanda con el pedido y su cliente', async () => {
    const { handlers, pedido } = renderCard(fixture(PENDIENTE), 'admin')
    await elegir(IMPRIMIR)

    await waitFor(() => {
      expect(generarReciboPedido).toHaveBeenCalledWith(pedido, pedido.cliente, { formato: 'comanda', rol: 'admin' })
    })
    for (const fn of Object.values(handlers)) expect(fn).not.toHaveBeenCalled()
  })

  it('"Imprimir Comanda" sin cliente cargado avisa en vez de imprimir', async () => {
    renderCard({ ...fixture(PENDIENTE), cliente: undefined }, 'admin')
    await elegir(IMPRIMIR)

    expect(await screen.findByText('No se puede imprimir: el pedido no tiene cliente cargado.')).toBeInTheDocument()
    expect(generarReciboPedido).not.toHaveBeenCalled()
  })
})

// =============================================================================
// Recibo PDF (pie de la tarjeta)
// =============================================================================

describe('PedidoCard — recibo de un pedido pagado', () => {
  it.each(ROLES_GALERIA)('%s tiene el boton de recibo en un pedido pagado (no depende del rol)', rol => {
    renderCard(fixture(ENTREGADO_FC), rol)
    expect(screen.getByRole('button', { name: /recibo/i })).toBeInTheDocument()
  })

  it.each([PENDIENTE, EN_PREPARACION, ENTREGADO_SALVEDAD])('#%s no esta pagado: no hay recibo', id => {
    renderCard(fixture(id), 'admin')
    expect(screen.queryByRole('button', { name: /recibo/i })).not.toBeInTheDocument()
  })

  it.each([
    { opcion: /^Hoja A4/, formato: 'a4' },
    { opcion: /^Comanda/, formato: 'comanda' },
  ] as const)('el recibo en formato $formato se genera con el pedido y su cliente', async ({ opcion, formato }) => {
    const { pedido } = renderCard(fixture(ENTREGADO_FC), 'admin')
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /recibo/i }))
    await user.click(screen.getByRole('button', { name: opcion }))
    await waitFor(() => {
      expect(generarReciboPedido).toHaveBeenCalledWith(pedido, pedido.cliente, { formato, rol: 'admin' })
    })
  })

  it('el recibo de un pedido sin cliente cargado avisa en vez de generarse', async () => {
    renderCard({ ...fixture(ENTREGADO_FC), cliente: undefined }, 'admin')
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /recibo/i }))
    await user.click(screen.getByRole('button', { name: /^Hoja A4/ }))

    expect(await screen.findByText('No se puede generar el recibo: el pedido no tiene cliente cargado.')).toBeInTheDocument()
    expect(generarReciboPedido).not.toHaveBeenCalled()
  })

  it('un cancelado (sin estado de pago) no tiene recibo', () => {
    renderCard(canceladoConPagos(), 'admin')
    expect(screen.queryByRole('button', { name: /recibo/i })).not.toBeInTheDocument()
  })
})

// =============================================================================
// 4. BadgeTipoFactura: quien cambia FC/ZZ y el doble clic
// =============================================================================

type ModoFactura = 'boton' | 'solo texto FC' | 'nada'

const QUIEN_CAMBIA_FACTURA: ReadonlyArray<{ rol: RolUsuario; id: string; modo: ModoFactura; tipo: 'FC' | 'ZZ' }> = [
  { rol: 'admin', id: PENDIENTE, tipo: 'ZZ', modo: 'boton' },
  { rol: 'admin', id: ASIGNADO, tipo: 'ZZ', modo: 'boton' },
  // El admin lo cambia tambien despues de la entrega...
  { rol: 'admin', id: ENTREGADO_FC, tipo: 'FC', modo: 'boton' },
  // ...pero no en un cancelado (y un ZZ de solo lectura no se dibuja).
  { rol: 'admin', id: CANCELADO, tipo: 'ZZ', modo: 'nada' },
  { rol: 'encargado', id: PENDIENTE, tipo: 'ZZ', modo: 'boton' },
  { rol: 'encargado', id: GPS_LEJOS, tipo: 'FC', modo: 'boton' },
  // El encargado solo hasta la entrega.
  { rol: 'encargado', id: ENTREGADO_FC, tipo: 'FC', modo: 'solo texto FC' },
  { rol: 'encargado', id: ENTREGADO_SALVEDAD, tipo: 'ZZ', modo: 'nada' },
  { rol: 'preventista', id: GPS_LEJOS, tipo: 'FC', modo: 'solo texto FC' },
  { rol: 'preventista', id: PENDIENTE, tipo: 'ZZ', modo: 'nada' },
  { rol: 'transportista', id: ENTREGADO_FC, tipo: 'FC', modo: 'solo texto FC' },
  { rol: 'transportista', id: ASIGNADO, tipo: 'ZZ', modo: 'nada' },
  { rol: 'deposito', id: GPS_LEJOS, tipo: 'FC', modo: 'solo texto FC' },
  { rol: 'deposito', id: PENDIENTE, tipo: 'ZZ', modo: 'nada' },
]

describe('PedidoCard — FC/ZZ: quien lo puede cambiar', () => {
  it.each(QUIEN_CAMBIA_FACTURA)('$rol sobre #$id ($tipo): $modo', ({ rol, id, modo, tipo }) => {
    renderCard(fixture(id), rol)
    const botones = screen.queryAllByRole('button', { name: tipo })
    if (modo === 'boton') {
      expect(botones.length).toBeGreaterThan(0)
      return
    }
    expect(botones).toHaveLength(0)
    if (modo === 'solo texto FC') seVe('FC')
    else {
      noSeVe('FC')
      noSeVe('ZZ')
    }
  })
})

describe('PedidoCard — FC/ZZ: doble clic para confirmar', () => {
  it('el primer clic solo arma la confirmacion; el segundo llama a la RPC con el tipo destino', async () => {
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true }, error: null } as never)
    renderCard(fixture(PENDIENTE), 'admin')
    const user = userEvent.setup()

    await user.click(screen.getAllByRole('button', { name: 'ZZ' })[0])
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()
    expect(supabase.rpc).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: '→ FC?' }))
    await waitFor(() => {
      expect(supabase.rpc).toHaveBeenCalledWith(
        'cambiar_tipo_factura_pedido',
        expect.objectContaining({ p_pedido_id: '18420', p_tipo: 'FC' }),
      )
    })
    expect(supabase.rpc).toHaveBeenCalledTimes(1)
  })

  it('de FC se pasa a ZZ con el mismo doble clic', async () => {
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true }, error: null } as never)
    renderCard(fixture(ENTREGADO_FC), 'admin')
    const user = userEvent.setup()

    await user.click(screen.getAllByRole('button', { name: 'FC' })[0])
    await user.click(screen.getByRole('button', { name: '→ ZZ?' }))
    await waitFor(() => {
      expect(supabase.rpc).toHaveBeenCalledWith(
        'cambiar_tipo_factura_pedido',
        expect.objectContaining({ p_pedido_id: '18355', p_tipo: 'ZZ' }),
      )
    })
  })

  it('mientras la RPC esta en curso el boton queda deshabilitado', async () => {
    vi.mocked(supabase.rpc).mockReturnValue(new Promise(() => {}) as never)
    renderCard(fixture(PENDIENTE), 'encargado')
    const user = userEvent.setup()

    await user.click(screen.getAllByRole('button', { name: 'ZZ' })[0])
    await user.click(screen.getByRole('button', { name: '→ FC?' }))
    expect(await screen.findByRole('button', { name: '…' })).toBeDisabled()
  })

  it('si pasan 3 s sin el segundo clic se desarma, y el clic siguiente vuelve a armar en vez de confirmar', async () => {
    vi.useFakeTimers({ toFake: ['Date', 'setTimeout', 'clearTimeout'] })
    vi.setSystemTime(AHORA)
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true }, error: null } as never)
    renderCard(fixture(PENDIENTE), 'admin')

    fireEvent.click(screen.getAllByRole('button', { name: 'ZZ' })[0])
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()

    await act(() => vi.advanceTimersByTimeAsync(2999))
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()

    await act(() => vi.advanceTimersByTimeAsync(1))
    expect(screen.queryByRole('button', { name: '→ FC?' })).not.toBeInTheDocument()

    fireEvent.click(screen.getAllByRole('button', { name: 'ZZ' })[0])
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()
    expect(supabase.rpc).not.toHaveBeenCalled()
  })

  it('al confirmar se cancela el timer de 3 s: volver a armar dentro de esa ventana dura sus 3 s completos', async () => {
    // Antes (BUG): `setTimeout(() => setConfirmando(false), 3000)` no se guardaba
    // ni se limpiaba. Si se armaba (t=0), se confirmaba (t=1 s) y se volvia a
    // armar (t=1,5 s), el timer VIEJO disparaba a los 3 s y desarmaba la
    // confirmacion nueva a 1,5 s de armada, no a 3. Ahora el timer se guarda en
    // un ref y se limpia al confirmar y antes de armar uno nuevo (#816).
    vi.useFakeTimers({ toFake: ['Date', 'setTimeout', 'clearTimeout'] })
    vi.setSystemTime(AHORA)
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true }, error: null } as never)
    renderCard(fixture(PENDIENTE), 'admin')

    fireEvent.click(screen.getAllByRole('button', { name: 'ZZ' })[0]) // t=0: arma
    await act(() => vi.advanceTimersByTimeAsync(1000))
    fireEvent.click(screen.getByRole('button', { name: '→ FC?' })) // t=1000: confirma
    await act(() => vi.advanceTimersByTimeAsync(500))
    expect(supabase.rpc).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getAllByRole('button', { name: 'ZZ' })[0]) // t=1500: vuelve a armar
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()

    // t=3000: la hora a la que disparaba el timer de t=0. La confirmacion nueva
    // sigue armada...
    await act(() => vi.advanceTimersByTimeAsync(1500))
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()

    // ...hasta cumplir sus propios 3 s (t=4500).
    await act(() => vi.advanceTimersByTimeAsync(1499))
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()
    await act(() => vi.advanceTimersByTimeAsync(1))
    expect(screen.queryByRole('button', { name: '→ FC?' })).not.toBeInTheDocument()
  })

  it('si la RPC rechaza el cambio, la card avisa el motivo y el badge queda en el tipo de antes', async () => {
    // Antes (BUG): el catch de BadgeTipoFactura se tragaba el error ("toast
    // global si existe") y no existia: el queryClient solo avisa errores de
    // QUERIES, la mutation no tiene onError y no hay MutationCache global. El
    // admin veia que el badge seguia en ZZ sin saber por que. Ahora notifica con
    // `useNotification` (el provider real del renderCard dibuja el toast),
    // sumando el motivo que devuelve la RPC (#816).
    vi.mocked(supabase.rpc).mockResolvedValue({
      data: { success: false, error: 'La rendición del día está cerrada' },
      error: null,
    } as never)
    const { qc } = renderCard(fixture(PENDIENTE), 'admin')
    const user = userEvent.setup()

    await user.click(screen.getAllByRole('button', { name: 'ZZ' })[0])
    await user.click(screen.getByRole('button', { name: '→ FC?' }))
    await waitFor(() => {
      expect(qc.getMutationCache().getAll().map(m => m.state.status)).toEqual(['error'])
    })

    expect(
      await screen.findByText('No se pudo cambiar el tipo de factura: La rendición del día está cerrada'),
    ).toBeInTheDocument()
    // El badge no queda armado ni "en curso": vuelve a mostrar el tipo de antes.
    expect(screen.getAllByRole('button', { name: 'ZZ' }).length).toBeGreaterThan(0)
    expect(screen.queryByRole('button', { name: '→ FC?' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '…' })).not.toBeInTheDocument()
  })
})
