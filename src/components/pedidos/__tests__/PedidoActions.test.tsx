/**
 * Caracterizacion del menu kebab de un pedido (`AccionesDropdown`).
 *
 * NO prueba lo que el menu DEBERIA hacer: fija lo que HACE hoy, antes del
 * rediseno de UI. De aca va a salir la accion inline de la tarjeta, asi que lo
 * que importa es la matriz ACCION x ROL x ESTADO: quien ve que opcion sobre que
 * pedido. Si el rediseno le corre una accion a un rol que no la tenia —o se la
 * saca a uno que si—, estos tests se ponen rojos.
 *
 * Todo se asevera por rol ARIA (`menuitem`) y texto visible en espanol. Nada de
 * clases: el acoplamiento a Tailwind es justo lo que viene a romper el rediseno.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import AccionesDropdown from '../PedidoActions'
import type { PedidoDB, PedidoItemDB } from '../../../types'

// =============================================================================
// POLYFILLS QUE RADIX NECESITA EN JSDOM
// =============================================================================
// Radix DropdownMenu usa la Pointer Capture API y `scrollIntoView` al mover el
// foco entre items. jsdom no las implementa: sin estos stubs el menu ni siquiera
// abre.
//
// El ResizeObserver de src/test/setup.js es un `vi.fn()` con implementacion
// flecha: se puede llamar, pero NO se puede construir con `new`, y el
// `autoUpdate` de @floating-ui (el posicionador de Radix) lo instancia. Sin
// pisarlo con una clase de verdad, abrir el menu tira "is not a constructor".
class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return [] }
}
globalThis.ResizeObserver = ObservadorStub as unknown as typeof ResizeObserver
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
// DATOS DE PRUEBA
// =============================================================================

/** El usuario logueado en todos los casos. */
const USUARIO = 'u-1'
/** Otro usuario cualquiera: dueno de la parada ajena. */
const OTRO = 'u-2'

/** 12:00 ARG del 17/09/2026 — antes del corte de 15:30 del preventista. */
const DENTRO_DE_VENTANA = new Date('2026-09-17T15:00:00Z')
/** 16:00 ARG del mismo dia — despues del corte. */
const FUERA_DE_VENTANA = new Date('2026-09-17T19:00:00Z')
/** 10:00 ARG del 17/09/2026: mismo dia argentino que las dos horas de arriba. */
const CREADO_HOY = '2026-09-17T13:00:00Z'

const ESTADOS = ['pendiente', 'en_preparacion', 'asignado', 'entregado', 'cancelado'] as const
type EstadoProbado = (typeof ESTADOS)[number]

// Etiquetas exactas que renderiza el componente.
const HISTORIAL = 'Ver Historial'
const IMPRIMIR = 'Imprimir Comanda'
const EDITAR = 'Editar'
const EDITAR_PEDIDO = 'Editar Pedido'
const EDITAR_OBS = 'Editar Observaciones'
const REGISTRAR_PAGO = 'Registrar Pago'
const PREPARAR = 'Marcar en Preparacion'
const VOLVER = 'Volver a Pendiente'
const ENTREGADO = 'Marcar Entregado'
const SALVEDAD = 'Entrega con Salvedad'
const REVERTIR = 'Revertir Entrega'
const CANCELAR = 'Cancelar Pedido'

interface PerfilProbado {
  isAdmin?: boolean
  isEncargado?: boolean
  isPreventista?: boolean
  isTransportista?: boolean
  /** Hora fijada con vi.setSystemTime: solo le cambia algo al preventista. */
  ahora: Date
  /** `transportista_id` del pedido: la parada es suya o de otro. */
  transportistaDelPedido: string
}

/**
 * Los seis perfiles que el componente distingue de verdad. "deposito" es el
 * caso "ninguno": ningun flag en true.
 */
const PERFILES = {
  admin: { isAdmin: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
  encargado: { isEncargado: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
  'preventista dueno en ventana': {
    isPreventista: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO,
  },
  'preventista dueno fuera de ventana': {
    isPreventista: true, ahora: FUERA_DE_VENTANA, transportistaDelPedido: OTRO,
  },
  'transportista de la parada': {
    isTransportista: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: USUARIO,
  },
  'transportista ajeno': {
    isTransportista: true, ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO,
  },
  deposito: { ahora: DENTRO_DE_VENTANA, transportistaDelPedido: OTRO },
} as const satisfies Record<string, PerfilProbado>

type NombrePerfil = keyof typeof PERFILES

// =============================================================================
// HELPERS
// =============================================================================

function crearHandlers() {
  return {
    onHistorial: vi.fn(),
    onEditar: vi.fn(),
    onEditarNotas: vi.fn(),
    onPreparar: vi.fn(),
    onVolverAPendiente: vi.fn(),
    onEntregado: vi.fn(),
    onEntregadoConSalvedad: vi.fn(),
    onRevertir: vi.fn(),
    onCancelarPedido: vi.fn(),
    onRegistrarPago: vi.fn(),
    onImprimirComanda: vi.fn(),
  }
}

interface OpcionesPedido {
  estado: EstadoProbado
  transportistaDelPedido?: string
  montoPagado?: number
  estadoPago?: 'pendiente' | 'parcial' | 'pagado'
  /** false = pedido sin lineas (el caso que le saca "Entrega con Salvedad"). */
  conItems?: boolean
}

function crearPedido(opciones: OpcionesPedido): PedidoDB {
  const items = opciones.conItems === false
    ? []
    : ([{ id: '1', producto_id: '9', cantidad: 2, precio_unitario: 100 }] as unknown as PedidoItemDB[])

  return {
    id: '4625',
    cliente_id: '10',
    usuario_id: USUARIO,
    transportista_id: opciones.transportistaDelPedido ?? OTRO,
    estado: opciones.estado,
    estado_pago: opciones.estadoPago ?? 'pendiente',
    total: 21600,
    monto_pagado: opciones.montoPagado ?? 0,
    fecha: '2026-09-17',
    created_at: CREADO_HOY,
    items,
  } as unknown as PedidoDB
}

function renderAcciones(
  perfil: PerfilProbado,
  pedido: PedidoDB,
  handlers = crearHandlers(),
): { handlers: ReturnType<typeof crearHandlers>; pedido: PedidoDB } {
  vi.setSystemTime(perfil.ahora)
  render(
    <AccionesDropdown
      pedido={pedido}
      isAdmin={perfil.isAdmin}
      isEncargado={perfil.isEncargado}
      isPreventista={perfil.isPreventista}
      isTransportista={perfil.isTransportista}
      currentUserId={USUARIO}
      {...handlers}
    />,
  )
  return { handlers, pedido }
}

async function abrirMenu(): Promise<HTMLElement> {
  const user = userEvent.setup()
  await user.click(screen.getByRole('button', { name: 'Mas acciones' }))
  return screen.findByRole('menu')
}

/** Las etiquetas visibles del menu, ordenadas alfabeticamente (es un conjunto). */
async function opcionesVisibles(): Promise<string[]> {
  const menu = await abrirMenu()
  return within(menu)
    .getAllByRole('menuitem')
    .map(item => (item.textContent ?? '').trim())
    .sort()
}

const ordenado = (labels: readonly string[]): string[] => [...labels].sort()

// =============================================================================
// LA MATRIZ
// =============================================================================

interface CasoMatriz {
  perfil: NombrePerfil
  estado: EstadoProbado
  esperado: readonly string[]
}

const MATRIZ: readonly CasoMatriz[] = [
  // --- admin: lo ve todo, y es el unico que puede cancelar ---
  { perfil: 'admin', estado: 'pendiente', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO, CANCELAR] },
  { perfil: 'admin', estado: 'en_preparacion', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, CANCELAR] },
  { perfil: 'admin', estado: 'asignado', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, SALVEDAD, CANCELAR] },
  { perfil: 'admin', estado: 'entregado', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, REVERTIR] },
  // Cancelado sin pagos: ni editar (el stock ya volvio) ni cobrar.
  { perfil: 'admin', estado: 'cancelado', esperado: [HISTORIAL, IMPRIMIR] },

  // --- encargado: identico al admin salvo "Cancelar Pedido" ---
  { perfil: 'encargado', estado: 'pendiente', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, PREPARAR, ENTREGADO] },
  { perfil: 'encargado', estado: 'en_preparacion', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO] },
  { perfil: 'encargado', estado: 'asignado', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, VOLVER, ENTREGADO, SALVEDAD] },
  { perfil: 'encargado', estado: 'entregado', esperado: [HISTORIAL, IMPRIMIR, EDITAR, REGISTRAR_PAGO, REVERTIR] },
  { perfil: 'encargado', estado: 'cancelado', esperado: [HISTORIAL, IMPRIMIR] },

  // --- preventista dueno, antes de las 15:30 ARG: edicion completa ---
  { perfil: 'preventista dueno en ventana', estado: 'pendiente', esperado: [HISTORIAL, EDITAR_PEDIDO] },
  { perfil: 'preventista dueno en ventana', estado: 'en_preparacion', esperado: [HISTORIAL, EDITAR_PEDIDO] },
  // 'asignado' se permite a proposito: tener transportista no implica que la
  // ruta haya salido (ver el comentario de utils/permisosPedido.ts).
  { perfil: 'preventista dueno en ventana', estado: 'asignado', esperado: [HISTORIAL, EDITAR_PEDIDO] },
  { perfil: 'preventista dueno en ventana', estado: 'entregado', esperado: [HISTORIAL, EDITAR_OBS] },
  { perfil: 'preventista dueno en ventana', estado: 'cancelado', esperado: [HISTORIAL, EDITAR_OBS] },

  // --- preventista dueno, pasadas las 15:30 ARG: solo observaciones ---
  { perfil: 'preventista dueno fuera de ventana', estado: 'pendiente', esperado: [HISTORIAL, EDITAR_OBS] },
  { perfil: 'preventista dueno fuera de ventana', estado: 'en_preparacion', esperado: [HISTORIAL, EDITAR_OBS] },
  { perfil: 'preventista dueno fuera de ventana', estado: 'asignado', esperado: [HISTORIAL, EDITAR_OBS] },
  { perfil: 'preventista dueno fuera de ventana', estado: 'entregado', esperado: [HISTORIAL, EDITAR_OBS] },
  { perfil: 'preventista dueno fuera de ventana', estado: 'cancelado', esperado: [HISTORIAL, EDITAR_OBS] },

  // --- transportista con la parada asignada a el ---
  { perfil: 'transportista de la parada', estado: 'pendiente', esperado: [HISTORIAL] },
  { perfil: 'transportista de la parada', estado: 'en_preparacion', esperado: [HISTORIAL] },
  { perfil: 'transportista de la parada', estado: 'asignado', esperado: [HISTORIAL, ENTREGADO, SALVEDAD] },
  { perfil: 'transportista de la parada', estado: 'entregado', esperado: [HISTORIAL] },
  { perfil: 'transportista de la parada', estado: 'cancelado', esperado: [HISTORIAL] },

  // --- transportista sobre una parada de otro chofer: no toca nada ---
  { perfil: 'transportista ajeno', estado: 'pendiente', esperado: [HISTORIAL] },
  { perfil: 'transportista ajeno', estado: 'en_preparacion', esperado: [HISTORIAL] },
  { perfil: 'transportista ajeno', estado: 'asignado', esperado: [HISTORIAL] },
  { perfil: 'transportista ajeno', estado: 'entregado', esperado: [HISTORIAL] },
  { perfil: 'transportista ajeno', estado: 'cancelado', esperado: [HISTORIAL] },

  // --- deposito (ningun flag): solo mira ---
  { perfil: 'deposito', estado: 'pendiente', esperado: [HISTORIAL] },
  { perfil: 'deposito', estado: 'en_preparacion', esperado: [HISTORIAL] },
  { perfil: 'deposito', estado: 'asignado', esperado: [HISTORIAL] },
  { perfil: 'deposito', estado: 'entregado', esperado: [HISTORIAL] },
  { perfil: 'deposito', estado: 'cancelado', esperado: [HISTORIAL] },
]

beforeEach(() => {
  // Solo Date: setTimeout tiene que seguir siendo real o userEvent y Radix se
  // cuelgan. `preventistaPuedeEditar` lee la hora ARG de `new Date()`.
  vi.useFakeTimers({ toFake: ['Date'] })
})

afterEach(() => {
  vi.useRealTimers()
  // Radix en modo modal apaga los punteros del body; si queda puesto, el
  // userEvent del test siguiente no puede clickear nada.
  document.body.style.pointerEvents = ''
})

describe('AccionesDropdown — matriz accion x rol x estado', () => {
  it.each(MATRIZ)(
    '$perfil sobre un pedido $estado ve exactamente sus opciones',
    async ({ perfil, estado, esperado }) => {
      renderAcciones(PERFILES[perfil], crearPedido({
        estado,
        transportistaDelPedido: PERFILES[perfil].transportistaDelPedido,
      }))

      expect(await opcionesVisibles()).toEqual(ordenado(esperado))
    },
  )
})

describe('AccionesDropdown — cada opcion llama a su handler con el pedido', () => {
  async function elegir(opcion: string): Promise<void> {
    const user = userEvent.setup()
    const menu = await abrirMenu()
    await user.click(within(menu).getByRole('menuitem', { name: opcion }))
  }

  it('"Ver Historial" llama a onHistorial con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    await elegir(HISTORIAL)
    expect(handlers.onHistorial).toHaveBeenCalledWith(pedido)
  })

  it('"Imprimir Comanda" llama a onImprimirComanda con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    await elegir(IMPRIMIR)
    expect(handlers.onImprimirComanda).toHaveBeenCalledWith(pedido)
  })

  it('"Editar" llama a onEditar con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    await elegir(EDITAR)
    expect(handlers.onEditar).toHaveBeenCalledWith(pedido)
  })

  it('"Registrar Pago" llama a onRegistrarPago con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    await elegir(REGISTRAR_PAGO)
    expect(handlers.onRegistrarPago).toHaveBeenCalledWith(pedido)
  })

  it('"Marcar en Preparacion" llama a onPreparar con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    await elegir(PREPARAR)
    expect(handlers.onPreparar).toHaveBeenCalledWith(pedido)
  })

  it('"Volver a Pendiente" llama a onVolverAPendiente con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'en_preparacion' }))
    await elegir(VOLVER)
    expect(handlers.onVolverAPendiente).toHaveBeenCalledWith(pedido)
  })

  it('"Marcar Entregado" llama a onEntregado con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'asignado' }))
    await elegir(ENTREGADO)
    expect(handlers.onEntregado).toHaveBeenCalledWith(pedido)
  })

  it('"Entrega con Salvedad" llama a onEntregadoConSalvedad con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'asignado' }))
    await elegir(SALVEDAD)
    expect(handlers.onEntregadoConSalvedad).toHaveBeenCalledWith(pedido)
  })

  it('"Revertir Entrega" llama a onRevertir con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'entregado' }))
    await elegir(REVERTIR)
    expect(handlers.onRevertir).toHaveBeenCalledWith(pedido)
  })

  it('"Cancelar Pedido" llama a onCancelarPedido con el pedido', async () => {
    const { handlers, pedido } = renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    await elegir(CANCELAR)
    expect(handlers.onCancelarPedido).toHaveBeenCalledWith(pedido)
  })

  it('"Editar Pedido" del preventista llama a onEditar, no a onEditarNotas', async () => {
    const { handlers, pedido } = renderAcciones(
      PERFILES['preventista dueno en ventana'],
      crearPedido({ estado: 'pendiente' }),
    )
    await elegir(EDITAR_PEDIDO)
    expect(handlers.onEditar).toHaveBeenCalledWith(pedido)
    expect(handlers.onEditarNotas).not.toHaveBeenCalled()
  })

  it('"Editar Observaciones" llama a onEditarNotas, no a onEditar', async () => {
    const { handlers, pedido } = renderAcciones(
      PERFILES['preventista dueno fuera de ventana'],
      crearPedido({ estado: 'pendiente' }),
    )
    await elegir(EDITAR_OBS)
    expect(handlers.onEditarNotas).toHaveBeenCalledWith(pedido)
    expect(handlers.onEditar).not.toHaveBeenCalled()
  })
})

describe('AccionesDropdown — "Cancelar Pedido" es solo del admin', () => {
  it.each(['pendiente', 'en_preparacion', 'asignado'] as const)(
    'el admin la ve sobre un pedido %s',
    async estado => {
      renderAcciones(PERFILES.admin, crearPedido({ estado }))
      expect(await opcionesVisibles()).toContain(CANCELAR)
    },
  )

  it.each(['entregado', 'cancelado'] as const)(
    'ni el admin la ve sobre un pedido %s',
    async estado => {
      renderAcciones(PERFILES.admin, crearPedido({ estado }))
      expect(await opcionesVisibles()).not.toContain(CANCELAR)
    },
  )

  it('el encargado no la ve nunca, aunque vea todo lo demas', async () => {
    renderAcciones(PERFILES.encargado, crearPedido({ estado: 'pendiente' }))
    expect(await opcionesVisibles()).not.toContain(CANCELAR)
  })

  it('va separada del resto: el menu del admin trae un separador y el del encargado no', async () => {
    renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    const menuAdmin = await abrirMenu()
    expect(within(menuAdmin).getAllByRole('separator')).toHaveLength(1)
    expect(within(menuAdmin).getByRole('menuitem', { name: CANCELAR })).toBeInTheDocument()
  })

  it('sin "Cancelar Pedido" no hay separador', async () => {
    renderAcciones(PERFILES.encargado, crearPedido({ estado: 'pendiente' }))
    const menu = await abrirMenu()
    expect(within(menu).queryAllByRole('separator')).toHaveLength(0)
  })
})

describe('AccionesDropdown — pagos', () => {
  it('un pedido cancelado SIN pagos no ofrece nada de plata', async () => {
    renderAcciones(PERFILES.admin, crearPedido({ estado: 'cancelado', montoPagado: 0 }))
    const opciones = await opcionesVisibles()
    expect(opciones).toEqual(ordenado([HISTORIAL, IMPRIMIR]))
  })

  it('un pedido cancelado CON pagos ofrece "Ver/Anular Pagos"', async () => {
    renderAcciones(PERFILES.admin, crearPedido({ estado: 'cancelado', montoPagado: 5000 }))
    const opciones = await opcionesVisibles()
    expect(opciones).toEqual(ordenado([HISTORIAL, IMPRIMIR, 'Ver/Anular Pagos']))
  })

  it('un pedido ya pagado dice "Ver/Editar Pagos"', async () => {
    renderAcciones(PERFILES.admin, crearPedido({
      estado: 'entregado', estadoPago: 'pagado', montoPagado: 21600,
    }))
    const opciones = await opcionesVisibles()
    expect(opciones).toContain('Ver/Editar Pagos')
    expect(opciones).not.toContain(REGISTRAR_PAGO)
  })

  it('un pago parcial sigue diciendo "Registrar Pago"', async () => {
    renderAcciones(PERFILES.admin, crearPedido({
      estado: 'asignado', estadoPago: 'parcial', montoPagado: 10000,
    }))
    expect(await opcionesVisibles()).toContain(REGISTRAR_PAGO)
  })

  it('el preventista no ve ninguna opcion de pago', async () => {
    renderAcciones(
      PERFILES['preventista dueno en ventana'],
      crearPedido({ estado: 'asignado', estadoPago: 'parcial', montoPagado: 10000 }),
    )
    const opciones = await opcionesVisibles()
    expect(opciones.filter(o => /pago/i.test(o))).toEqual([])
  })
})

describe('AccionesDropdown — "Entrega con Salvedad" exige items', () => {
  it('con items, el admin la ve sobre un pedido asignado', async () => {
    renderAcciones(PERFILES.admin, crearPedido({ estado: 'asignado', conItems: true }))
    expect(await opcionesVisibles()).toContain(SALVEDAD)
  })

  it('sin items, nadie la ve — ni el admin', async () => {
    renderAcciones(PERFILES.admin, crearPedido({ estado: 'asignado', conItems: false }))
    const opciones = await opcionesVisibles()
    expect(opciones).not.toContain(SALVEDAD)
    // Lo demas del pedido asignado sigue estando: lo unico que se cae es la salvedad.
    expect(opciones).toContain(ENTREGADO)
  })

  it('sin items, el transportista de la parada tampoco la ve', async () => {
    renderAcciones(
      PERFILES['transportista de la parada'],
      crearPedido({ estado: 'asignado', transportistaDelPedido: USUARIO, conItems: false }),
    )
    const opciones = await opcionesVisibles()
    expect(opciones).not.toContain(SALVEDAD)
    expect(opciones).toContain(ENTREGADO)
  })
})

describe('AccionesDropdown — la ventana horaria del preventista', () => {
  it('a las 12:00 ARG el dueno edita el pedido entero', async () => {
    renderAcciones(PERFILES['preventista dueno en ventana'], crearPedido({ estado: 'pendiente' }))
    const opciones = await opcionesVisibles()
    expect(opciones).toContain(EDITAR_PEDIDO)
    expect(opciones).not.toContain(EDITAR_OBS)
  })

  it('a las 16:00 ARG ya solo edita observaciones', async () => {
    renderAcciones(PERFILES['preventista dueno fuera de ventana'], crearPedido({ estado: 'pendiente' }))
    const opciones = await opcionesVisibles()
    expect(opciones).toContain(EDITAR_OBS)
    expect(opciones).not.toContain(EDITAR_PEDIDO)
  })

  it('un pedido de OTRO preventista cae a observaciones aunque sea temprano', async () => {
    const pedidoAjeno = {
      ...crearPedido({ estado: 'pendiente' }),
      usuario_id: OTRO,
    } as PedidoDB
    renderAcciones(PERFILES['preventista dueno en ventana'], pedidoAjeno)
    const opciones = await opcionesVisibles()
    expect(opciones).toContain(EDITAR_OBS)
    expect(opciones).not.toContain(EDITAR_PEDIDO)
  })

  it('un pedido de ayer cae a observaciones aunque sea temprano', async () => {
    const pedidoDeAyer = {
      ...crearPedido({ estado: 'pendiente' }),
      created_at: '2026-09-16T13:00:00Z',
    } as PedidoDB
    renderAcciones(PERFILES['preventista dueno en ventana'], pedidoDeAyer)
    const opciones = await opcionesVisibles()
    expect(opciones).toContain(EDITAR_OBS)
    expect(opciones).not.toContain(EDITAR_PEDIDO)
  })
})

describe('AccionesDropdown — el trigger', () => {
  it('el kebab se anuncia como "Mas acciones" y marca aria-expanded', async () => {
    renderAcciones(PERFILES.admin, crearPedido({ estado: 'pendiente' }))
    const trigger = screen.getByRole('button', { name: 'Mas acciones' })
    expect(trigger).toHaveAttribute('aria-expanded', 'false')

    const user = userEvent.setup()
    await user.click(trigger)
    await screen.findByRole('menu')
    expect(trigger).toHaveAttribute('aria-expanded', 'true')
  })

  it('sin ningun handler, el menu queda vacio pero el boton sigue estando', async () => {
    vi.setSystemTime(DENTRO_DE_VENTANA)
    render(<AccionesDropdown pedido={crearPedido({ estado: 'pendiente' })} isAdmin />)

    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Mas acciones' }))
    const menu = await screen.findByRole('menu')
    expect(within(menu).queryAllByRole('menuitem')).toHaveLength(0)
  })
})
