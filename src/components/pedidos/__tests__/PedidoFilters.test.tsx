/**
 * Tests de CARACTERIZACIÓN de `PedidoFilters` — la barra de filtros de /pedidos.
 *
 * Fijan el comportamiento ACTUAL antes del rediseño de UI. Dos cosas que
 * conviene tener presentes al leerlos:
 *
 *  1. El componente renderiza DOS layouts a la vez —el de mobile y el de
 *     desktop— y los esconde con Tailwind (`hidden sm:flex` / `sm:hidden`).
 *     En jsdom no hay CSS, así que los dos están en el árbol accesible y el
 *     botón "Fechas" aparece DOS veces. Eso no es un defecto del test: es lo
 *     que hoy ve un lector de pantalla.
 *  2. La segunda fila de filtros (pago, transportista, usuario, salvedad,
 *     entrega) es un render condicional por `isAdmin`, no un `hidden`: ahí sí
 *     la ausencia es real.
 *
 * La fecha del sistema se fija porque el segmented control de entrega calcula
 * "Hoy" y "Mañana" con `fechaLocalISO()` (TZ Argentina).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import PedidoFilters, { type PedidoFiltersProps } from '../PedidoFilters'
import type { RolUsuario, Usuario } from '../../../types'

// =============================================================================
// FECHA FIJA
// =============================================================================

/**
 * 16/04/2026 02:00 UTC = 15/04/2026 23:00 en Argentina (UTC-3).
 *
 * El reloj está puesto a propósito en la franja donde la fecha UTC y la
 * argentina NO coinciden: en UTC ya es 16, en Argentina todavía es 15. Así
 * "Hoy" tiene que dar 2026-04-15 y "Mañana" 2026-04-16, y una implementación
 * que calculara la fecha con `toISOString().slice(0, 10)` —la trampa que
 * CLAUDE.md marca como recurrente— devolvería 2026-04-16 y pondría los tests
 * en rojo. Con el reloj al mediodía las dos zonas dan lo mismo y el test no
 * probaría nada.
 */
const AHORA = new Date('2026-04-16T02:00:00Z')
const HOY = '2026-04-15'
const MANANA = '2026-04-16'

beforeEach(() => {
  // Sólo `Date`: si se falsearan también los timers, userEvent se colgaría
  // esperando sus propios setTimeout.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(AHORA)
})

afterEach(() => {
  vi.useRealTimers()
})

// =============================================================================
// FIXTURES
// =============================================================================

type Filtros = PedidoFiltersProps['filtros']

const FILTROS_BASE: Filtros = {
  estado: 'todos',
  estadoPago: 'todos',
  transportistaId: 'todos',
  usuarioId: 'todos',
  conSalvedad: 'todos',
  verCancelados: false,
  fechaDesde: null,
  fechaHasta: null,
  fechaEntregaProgramada: null,
}

function hacerUsuario(id: string, nombre: string, rol: RolUsuario): Usuario {
  return { id, nombre, rol, email: `${id}@test.com`, activo: true }
}

const TRANSPORTISTAS = [hacerUsuario('t1', 'Ramón Chofer', 'transportista')]
const USUARIOS = [hacerUsuario('u1', 'Vale Preventista', 'preventista')]

/** Los seis estados del selector: [etiqueta visible, value que viaja al filtro]. */
const ESTADOS: ReadonlyArray<readonly [string, string]> = [
  ['Todos los estados', 'todos'],
  ['Pendientes', 'pendiente'],
  ['En preparación', 'en_preparacion'],
  ['En camino', 'asignado'],
  ['Entregados', 'entregado'],
  ['Cancelados', 'cancelado'],
]

interface OpcionesRender {
  filtros?: Partial<Filtros>
  isAdmin?: boolean
  busqueda?: string
}

function renderFilters(opciones: OpcionesRender = {}) {
  const onFiltrosChange = vi.fn()
  const onBusquedaChange = vi.fn()
  const onModalFiltroFecha = vi.fn()

  render(
    <PedidoFilters
      busqueda={opciones.busqueda ?? ''}
      filtros={{ ...FILTROS_BASE, ...opciones.filtros }}
      transportistas={TRANSPORTISTAS}
      usuarios={USUARIOS}
      isAdmin={opciones.isAdmin ?? true}
      onBusquedaChange={onBusquedaChange}
      onFiltrosChange={onFiltrosChange}
      onModalFiltroFecha={onModalFiltroFecha}
    />,
  )

  return { onFiltrosChange, onBusquedaChange, onModalFiltroFecha }
}

/** El botón mobile que abre el bottom sheet, con su badge de conteo. */
function botonFiltros(): HTMLElement {
  return screen.getByRole('button', { name: 'Abrir filtros avanzados' })
}

/**
 * El `input[type="date"]` de "Entrega programada".
 *
 * No tiene `id`/`htmlFor` ni `aria-label`, así que no hay nombre accesible con
 * el que pedirlo —mismo hallazgo que en `ModalFiltroFecha`—. Se lo toma por su
 * tipo. Mientras el bottom sheet esté cerrado hay uno solo en el árbol: el
 * sheet vive en un portal de Radix que sólo se monta cuando está abierto.
 */
function inputFechaEntrega(): HTMLInputElement {
  const input = document.querySelector<HTMLInputElement>('input[type="date"]')
  if (!input) throw new Error('No hay input de fecha de entrega en el árbol')
  return input
}

// =============================================================================
// BÚSQUEDA, ESTADO, CANCELADOS, FECHAS
// =============================================================================

describe('PedidoFilters — primera fila', () => {
  it('escribir en el buscador avisa cada tecla', async () => {
    const user = userEvent.setup()
    const { onBusquedaChange } = renderFilters()

    await user.type(
      screen.getByRole('textbox', { name: /buscar pedidos por cliente, dirección o número de pedido/i }),
      'K',
    )

    expect(onBusquedaChange).toHaveBeenCalledTimes(1)
    expect(onBusquedaChange).toHaveBeenCalledWith('K')
  })

  it('cambiar el estado llama onFiltrosChange sólo con el estado', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.selectOptions(
      screen.getByRole('combobox', { name: /filtrar por estado del pedido/i }),
      'entregado',
    )

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'entregado' })
  })

  it('el selector de estado ofrece los seis estados, con su value contra la base', () => {
    renderFilters()
    const select = screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })

    // El `value` importa tanto como la etiqueta: es lo que viaja al filtro del
    // container y de ahí a `pedidos.estado`. "En camino" es el caso que más
    // engaña —su value es 'asignado'—, así que renombrarlo rompería el filtro
    // real sin cambiar una sola palabra de lo que se ve.
    for (const [etiqueta, value] of ESTADOS) {
      expect(within(select).getByRole('option', { name: etiqueta })).toHaveValue(value)
    }
  })

  it('marcar "Ver cancelados" lo prende', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.click(screen.getByRole('checkbox', { name: 'Ver cancelados' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: true })
  })

  it('desmarcar "Ver cancelados" lo apaga', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { verCancelados: true } })

    expect(screen.getByRole('checkbox', { name: 'Ver cancelados' })).toBeChecked()
    await user.click(screen.getByRole('checkbox', { name: 'Ver cancelados' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: false })
  })

  it('"Fechas" está DOS veces en el árbol accesible (layout mobile + desktop)', () => {
    renderFilters()

    // Los dos layouts se renderizan siempre; Tailwind esconde uno, pero para
    // un lector de pantalla hay dos botones con el mismo nombre.
    expect(screen.getAllByRole('button', { name: 'Filtrar pedidos por rango de fechas' })).toHaveLength(2)
  })

  it('"Fechas" dispara el callback que abre el modal de rango, en los DOS layouts', async () => {
    const user = userEvent.setup()
    const { onModalFiltroFecha } = renderFilters()

    // Los dos botones —el de desktop y el de mobile— tienen que estar
    // cableados. Clickear sólo el primero dejaba pasar un rediseño que le
    // sacara el handler al de mobile, que es el que usa casi todo el mundo.
    const botones = screen.getAllByRole('button', { name: 'Filtrar pedidos por rango de fechas' })
    expect(botones).toHaveLength(2)

    for (const boton of botones) {
      await user.click(boton)
    }

    expect(onModalFiltroFecha).toHaveBeenCalledTimes(2)
  })

  it('el botón "Fechas" de la fila mobile abre el modal por sí solo', async () => {
    const user = userEvent.setup()
    const { onModalFiltroFecha } = renderFilters()

    // En el DOM primero va el bloque `hidden sm:flex` (desktop) y después la
    // grilla `sm:hidden` (mobile): el índice 1 es el de mobile.
    const mobile = screen.getAllByRole('button', { name: 'Filtrar pedidos por rango de fechas' })[1]
    await user.click(mobile)

    expect(onModalFiltroFecha).toHaveBeenCalledTimes(1)
  })
})

// =============================================================================
// SEGUNDA FILA: SÓLO ADMIN
// =============================================================================

const FILTROS_SOLO_ADMIN = [
  /filtrar por estado de pago/i,
  /filtrar por transportista/i,
  /filtrar por usuario que cargó el pedido/i,
  /filtrar por salvedades en entrega/i,
] as const

describe('PedidoFilters — la segunda fila es sólo para admin', () => {
  it('el admin ve los cuatro selectores extra y el control de entrega', () => {
    renderFilters({ isAdmin: true })

    for (const nombre of FILTROS_SOLO_ADMIN) {
      expect(screen.getByRole('combobox', { name: nombre })).toBeInTheDocument()
    }
    expect(screen.getByText('Entrega:')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Hoy' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Mañana' })).toBeInTheDocument()
  })

  // `isAdmin` es un booleano: encargado, preventista, transportista y depósito
  // llegan todos con `false` y no se distinguen entre sí acá.
  it('cualquier rol que no sea admin no ve ninguno de los cuatro', () => {
    renderFilters({ isAdmin: false })

    for (const nombre of FILTROS_SOLO_ADMIN) {
      expect(screen.queryByRole('combobox', { name: nombre })).not.toBeInTheDocument()
    }
    expect(screen.queryByText('Entrega:')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Hoy' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Mañana' })).not.toBeInTheDocument()
  })

  it('el no-admin conserva el estado, el buscador y las fechas', () => {
    renderFilters({ isAdmin: false })

    expect(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })).toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: 'Ver cancelados' })).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Filtrar pedidos por rango de fechas' })).toHaveLength(2)
  })

  it('el selector de transportista lista "Sin asignar" y los transportistas recibidos', () => {
    renderFilters()
    const select = screen.getByRole('combobox', { name: /filtrar por transportista/i })

    expect(within(select).getByRole('option', { name: 'Todos los transportistas' })).toBeInTheDocument()
    expect(within(select).getByRole('option', { name: 'Sin asignar' })).toBeInTheDocument()
    expect(within(select).getByRole('option', { name: 'Ramón Chofer' })).toBeInTheDocument()
  })

  it('elegir un transportista avisa su id', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por transportista/i }), 't1')

    expect(onFiltrosChange).toHaveBeenCalledWith({ transportistaId: 't1' })
  })

  it('elegir un usuario que cargó avisa su id', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por usuario que cargó/i }), 'u1')

    expect(onFiltrosChange).toHaveBeenCalledWith({ usuarioId: 'u1' })
  })

  it('elegir estado de pago avisa el valor', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por estado de pago/i }), 'parcial')

    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'parcial' })
  })

  it('elegir "Con salvedad" avisa el valor', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.selectOptions(
      screen.getByRole('combobox', { name: /filtrar por salvedades en entrega/i }),
      'con_salvedad',
    )

    expect(onFiltrosChange).toHaveBeenCalledWith({ conSalvedad: 'con_salvedad' })
  })
})

// =============================================================================
// ENTREGA PROGRAMADA (Hoy / Mañana / fecha suelta)
// =============================================================================

describe('PedidoFilters — entrega programada', () => {
  it('"Hoy" setea la fecha de hoy en TZ Argentina', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.click(screen.getByRole('button', { name: 'Hoy' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: HOY })
  })

  it('"Mañana" setea el día siguiente', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.click(screen.getByRole('button', { name: 'Mañana' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: MANANA })
  })

  it('volver a tocar "Hoy" cuando ya está activo lo apaga', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { fechaEntregaProgramada: HOY } })

    await user.click(screen.getByRole('button', { name: 'Hoy' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('volver a tocar "Mañana" cuando ya está activo lo apaga', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { fechaEntregaProgramada: MANANA } })

    await user.click(screen.getByRole('button', { name: 'Mañana' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('el input de fecha precargado muestra la entrega vigente', () => {
    renderFilters({ filtros: { fechaEntregaProgramada: '2026-05-20' } })

    expect(inputFechaEntrega()).toHaveValue('2026-05-20')
  })

  it('escribir una fecha suelta en el input la emite tal cual', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.type(inputFechaEntrega(), '2026-05-20')

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: '2026-05-20' })
  })

  it('borrar el input emite null, no cadena vacía', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { fechaEntregaProgramada: '2026-05-20' } })

    await user.clear(inputFechaEntrega())

    // `e.target.value || null`: la cadena vacía se coerce a null antes de
    // salir. El container distingue null (sin filtro) de '' (filtro por una
    // fecha vacía, que no matchea nada), así que la coerción es parte del
    // contrato y no un detalle de implementación.
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
    expect(onFiltrosChange).not.toHaveBeenCalledWith({ fechaEntregaProgramada: '' })
  })

  it('con una fecha suelta aparece la X para limpiarla', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { fechaEntregaProgramada: '2026-05-20' } })

    await user.click(screen.getByRole('button', { name: 'Limpiar filtro de entrega' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('sin fecha de entrega no hay X para limpiar', () => {
    renderFilters()

    expect(screen.queryByRole('button', { name: 'Limpiar filtro de entrega' })).not.toBeInTheDocument()
  })
})

// =============================================================================
// CHIP DE RANGO DE FECHAS
// =============================================================================

describe('PedidoFilters — chip "Filtrado"', () => {
  it('no aparece cuando no hay rango de fechas', () => {
    renderFilters()

    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.queryByText(/Filtrado:/)).not.toBeInTheDocument()
  })

  it('muestra el rango completo cuando hay desde y hasta', () => {
    renderFilters({ filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: 2026-04-01 – 2026-04-15')
  })

  it('con una sola punta del rango deja la otra en puntos suspensivos', () => {
    renderFilters({ filtros: { fechaDesde: '2026-04-01', fechaHasta: null } })

    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: 2026-04-01 – …')
  })

  it('aparece también con sólo fechaHasta', () => {
    renderFilters({ filtros: { fechaDesde: null, fechaHasta: '2026-04-15' } })

    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: … – 2026-04-15')
  })

  it('su X limpia las dos puntas del rango de una', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({
      filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' },
    })

    await user.click(screen.getByRole('button', { name: 'Limpiar filtro de fechas' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: null })
  })
})

// =============================================================================
// CONTADOR DEL BOTÓN MOBILE "Filtros (N)"
// =============================================================================

/**
 * `contarFiltrosActivos` no está exportada, así que se la ejercita por el badge
 * del botón mobile, que es su único consumidor visible.
 */
describe('PedidoFilters — contador de filtros activos', () => {
  it('sin filtros el botón no muestra ningún número', () => {
    renderFilters()

    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
  })

  it.each([
    ['el estado', { estado: 'pendiente' }],
    ['el estado de pago', { estadoPago: 'parcial' }],
    ['el transportista', { transportistaId: 't1' }],
    ['el usuario que cargó', { usuarioId: 'u1' }],
    ['la salvedad', { conSalvedad: 'con_salvedad' as const }],
    ['la entrega programada', { fechaEntregaProgramada: HOY }],
    ['ver cancelados', { verCancelados: true }],
  ])('cuenta 1 cuando el filtro activo es %s', (_nombre, filtros) => {
    renderFilters({ filtros })

    expect(within(botonFiltros()).getByText('1')).toBeInTheDocument()
  })

  it('suma los siete filtros cuando están todos puestos', () => {
    renderFilters({
      filtros: {
        estado: 'pendiente',
        estadoPago: 'parcial',
        transportistaId: 't1',
        usuarioId: 'u1',
        conSalvedad: 'con_salvedad',
        fechaEntregaProgramada: HOY,
        verCancelados: true,
      },
    })

    expect(within(botonFiltros()).getByText('7')).toBeInTheDocument()
  })

  it('el rango de fechas y la búsqueda NO entran en el contador', () => {
    renderFilters({
      busqueda: 'kiosco',
      filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' },
    })

    // El buscador es un input controlado: muestra la prop `busqueda`. Si el
    // rediseño lo volviera no controlado, lo escrito dejaría de sobrevivir a
    // un re-render del padre y nadie se enteraría.
    expect(screen.getByRole('textbox', { name: /buscar pedidos/i })).toHaveValue('kiosco')
    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
  })

  // BUG: el contador no mira `isAdmin`. Un no-admin no ve ni puede tocar los
  // cuatro filtros de la segunda fila, pero si el estado los trae seteados el
  // badge se los cuenta igual y no tiene con qué explicarle de dónde salen.
  // Hoy no se dispara solo —la UI del no-admin nunca los pone en otra cosa que
  // 'todos'— pero el cálculo está desacoplado de quién los puede ver.
  it('BUG: cuenta filtros de admin aunque el rol no los pueda ver', () => {
    renderFilters({ isAdmin: false, filtros: { estadoPago: 'parcial', conSalvedad: 'con_salvedad' } })

    expect(screen.queryByRole('combobox', { name: /filtrar por estado de pago/i })).not.toBeInTheDocument()
    expect(within(botonFiltros()).getByText('2')).toBeInTheDocument()
  })
})

// =============================================================================
// BOTTOM SHEET
// =============================================================================

describe('PedidoFilters — bottom sheet de filtros', () => {
  it('arranca cerrado: no hay diálogo montado', () => {
    renderFilters()

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('el botón "Filtros" abre el bottom sheet', async () => {
    const user = userEvent.setup()
    renderFilters()

    await user.click(botonFiltros())

    expect(await screen.findByRole('dialog', { name: 'Filtros' })).toBeInTheDocument()
  })

  it('"Listo" cierra el bottom sheet sin tocar los filtros', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.click(botonFiltros())
    await user.click(await screen.findByRole('button', { name: 'Listo' }))

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })
})

// =============================================================================
// PAGO "IMPAGO": EL QUE APLICA EL TILE "Impagos" DE PedidoStats (#715)
// =============================================================================
//
// El tile manda `estadoPago: 'impago'`, un valor que antes no estaba entre las
// opciones del select: el select mostraba "Todos los pagos" (la primera) con
// un filtro puesto, y no había cómo sacarlo desde ahí.

describe('PedidoFilters — el pago "impago" del tile (#715)', () => {
  it('con estadoPago impago el select de pago lo muestra elegido', () => {
    renderFilters({ filtros: { estadoPago: 'impago' } })

    const pago = screen.getByRole('combobox', { name: /filtrar por estado de pago/i })
    expect(pago).toHaveValue('impago')
    expect(within(pago).getByRole('option', { name: 'Impagos (sin pagar o parcial)', selected: true })).toBeInTheDocument()
  })

  it('elegir "Todos los pagos" lo quita', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { estadoPago: 'impago' } })

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por estado de pago/i }), 'Todos los pagos')

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'todos' })
  })

  it('también se puede elegir desde el select, con el mismo valor que el tile', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.selectOptions(
      screen.getByRole('combobox', { name: /filtrar por estado de pago/i }),
      'Impagos (sin pagar o parcial)',
    )

    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'impago' })
  })
})

// El tile "Impagos" filtra para TODOS los roles, no sólo para el admin: un
// no-admin puede tener `estadoPago: 'impago'` puesto sin haber visto nunca el
// select de pago. Para él, el badge "Filtros (N)" y "Limpiar todo" son, junto
// con el tile presionado, la forma de ver y quitar ese filtro. Estos casos
// fijan que los dos lo cuenten: el comentario del test "BUG: cuenta filtros de
// admin aunque el rol no los pueda ver" (más arriba) dice que la UI del no-admin
// nunca los pone en otra cosa que 'todos', y desde #715 eso ya no vale para el
// pago. Si alguien "arregla" ese BUG haciendo que el contador respete
// `isAdmin`, el no-admin con impagos vería el badge en 0 y "Limpiar todo"
// deshabilitado, y estos casos se ponen en rojo.
describe('PedidoFilters — el no-admin con el filtro de impagos del tile (#715)', () => {
  it('el badge lo cuenta aunque no tenga select de pago', () => {
    renderFilters({ isAdmin: false, filtros: { estadoPago: 'impago' } })

    expect(screen.queryByRole('combobox', { name: /filtrar por estado de pago/i })).not.toBeInTheDocument()
    expect(within(botonFiltros()).getByText('1')).toBeInTheDocument()
  })

  it('"Limpiar todo" del sheet está habilitado y lo quita', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ isAdmin: false, filtros: { estadoPago: 'impago' } })

    await user.click(botonFiltros())
    const limpiar = await screen.findByRole('button', { name: 'Limpiar todo' })
    expect(limpiar).toBeEnabled()

    await user.click(limpiar)

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith(expect.objectContaining({ estadoPago: 'todos' }))
  })
})
