/**
 * Tests de CARACTERIZACIÓN de `PedidoFilters` — la barra de filtros de /pedidos.
 *
 * Se escribieron antes del rediseño de UI y se ajustaron en WP-44 (#769), que
 * cambió DÓNDE están los controles, no qué emiten. Dos cosas que conviene tener
 * presentes al leerlos:
 *
 *  1. Desde WP-44 hay UN solo trigger ("Abrir filtros avanzados") y un solo
 *     panel (`PanelFiltrosPedidos`). Antes la barra renderizaba dos layouts a
 *     la vez —la fila inline de escritorio y el botón del sheet de mobile— y
 *     los selects estaban a la vista sin abrir nada; ahora viven en el panel,
 *     así que los casos de esos selects lo abren primero (`abrirPanel`). La
 *     entrega programada (Hoy / Mañana / fecha, sólo admin) NO se movió: sigue
 *     en la fila, a un toque, y sus casos no abren nada. En jsdom `matchMedia`
 *     no matchea nada (src/test/setup.js), así que el panel es el bottom sheet
 *     del celular; el popover de escritorio se prueba aparte, al final.
 *  2. Los filtros secundarios (pago, transportista, usuario, salvedad,
 *     entrega) son un render condicional por `isAdmin`, no un `hidden`: ahí sí
 *     la ausencia es real.
 *
 * La fecha del sistema se fija porque el segmented control de entrega calcula
 * "Hoy" y "Mañana" con `fechaLocalISO()` (TZ Argentina).
 */
import '@testing-library/jest-dom/vitest'
import { useState } from 'react'
import { describe, it, expect, vi, beforeEach, afterEach, beforeAll, afterAll } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent, { type UserEvent } from '@testing-library/user-event'

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

  render(
    <PedidoFilters
      busqueda={opciones.busqueda ?? ''}
      filtros={{ ...FILTROS_BASE, ...opciones.filtros }}
      transportistas={TRANSPORTISTAS}
      usuarios={USUARIOS}
      isAdmin={opciones.isAdmin ?? true}
      onBusquedaChange={onBusquedaChange}
      onFiltrosChange={onFiltrosChange}
    />,
  )

  return { onFiltrosChange, onBusquedaChange }
}

/** El único trigger del panel de filtros, con su badge de conteo. */
function botonFiltros({ hidden = false }: { hidden?: boolean } = {}): HTMLElement {
  // Con el sheet abierto Radix esconde lo de atrás con aria-hidden: para mirar
  // el trigger en ese momento hay que pedirlo con `hidden`.
  return screen.getByRole('button', { name: 'Abrir filtros avanzados', hidden })
}

/**
 * Abre el panel de filtros (en jsdom, el bottom sheet) y devuelve el diálogo.
 * Es el camino que agregó WP-44: los controles ya no están a la vista sin abrir.
 */
async function abrirPanel(user: UserEvent): Promise<HTMLElement> {
  await user.click(botonFiltros())
  return screen.findByRole('dialog', { name: 'Filtros' })
}

/**
 * El `input[type="date"]` de "Entrega programada" de la fila. Mientras el panel
 * esté cerrado hay uno solo en el árbol: el panel (con las fechas de carga) vive
 * en un portal de Radix que sólo se monta cuando está abierto.
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
    await abrirPanel(user)

    await user.selectOptions(
      screen.getByRole('combobox', { name: /filtrar por estado del pedido/i }),
      'entregado',
    )

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'entregado' })
  })

  it('el selector de estado ofrece los seis estados, con su value contra la base', async () => {
    const user = userEvent.setup()
    renderFilters()
    await abrirPanel(user)
    const select = screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })

    // El `value` importa tanto como la etiqueta: es lo que viaja al filtro del
    // container y de ahí a `pedidos.estado`. "En camino" es el caso que más
    // engaña —su value es 'asignado'—, así que renombrarlo rompería el filtro
    // real sin cambiar una sola palabra de lo que se ve.
    for (const [etiqueta, value] of ESTADOS) {
      expect(within(select).getByRole('option', { name: etiqueta })).toHaveValue(value)
    }
  })

  // WP-44: la casilla es la del panel único, que se llama "Incluir cancelados"
  // (el nombre que ya tenía en el sheet). La de la fila de escritorio, "Ver
  // cancelados", era la copia que el panel único eliminó.
  it('marcar "Incluir cancelados" lo prende', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()
    await abrirPanel(user)

    await user.click(screen.getByRole('checkbox', { name: 'Incluir cancelados' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: true })
  })

  it('desmarcar "Incluir cancelados" lo apaga', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { verCancelados: true } })
    await abrirPanel(user)

    expect(screen.getByRole('checkbox', { name: 'Incluir cancelados' })).toBeChecked()
    await user.click(screen.getByRole('checkbox', { name: 'Incluir cancelados' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: false })
  })

  // Invertido en WP-44 (#769): antes había DOS layouts siempre montados y el
  // botón "Fechas" aparecía dos veces. Ahora hay un solo trigger, y las fechas
  // de carga viven adentro del panel: no hay botón "Fechas" aparte.
  it('hay UN solo trigger de filtros y ningún botón de fechas aparte', () => {
    renderFilters()

    expect(screen.getAllByRole('button', { name: 'Abrir filtros avanzados' })).toHaveLength(1)
    expect(screen.queryByRole('button', { name: 'Filtrar pedidos por rango de fechas' })).not.toBeInTheDocument()
    // Con el panel cerrado no hay ningún control del panel montado.
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
  })

  // Mudado de "Fechas dispara el callback que abre el modal de rango": el modal
  // aparte (`ModalFiltroFecha`) ya no existe; el rango se elige en la sección
  // "Fecha de carga" del mismo panel.
  it('el trigger abre el panel, que trae los campos Desde y Hasta de la fecha de carga', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    const panel = await abrirPanel(user)

    expect(within(panel).getByText('Fecha de carga')).toBeInTheDocument()
    expect(within(panel).getByLabelText('Desde')).toHaveAttribute('type', 'date')
    expect(within(panel).getByLabelText('Hasta')).toHaveAttribute('type', 'date')
    // Abrir no emite nada.
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('elegir un rango en el panel lo emite en vivo, con las dos puntas', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()
    const panel = await abrirPanel(user)

    await user.type(within(panel).getByLabelText('Desde'), '2026-05-01')
    await user.type(within(panel).getByLabelText('Hasta'), '2026-05-31')

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: '2026-05-01', fechaHasta: '2026-05-31' })
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
  it('el admin ve los cuatro selectores extra y el control de entrega', async () => {
    const user = userEvent.setup()
    renderFilters({ isAdmin: true })

    // La entrega está en la fila: se ve sin abrir el panel.
    expect(screen.getByText('Entrega:')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Hoy' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Mañana' })).toBeInTheDocument()

    // Los cuatro selectores están en el panel.
    await abrirPanel(user)
    for (const nombre of FILTROS_SOLO_ADMIN) {
      expect(screen.getByRole('combobox', { name: nombre })).toBeInTheDocument()
    }
  })

  // `isAdmin` es un booleano: encargado, preventista, transportista y depósito
  // llegan todos con `false` y no se distinguen entre sí acá.
  it('cualquier rol que no sea admin no ve ninguno de los cuatro', async () => {
    const user = userEvent.setup()
    renderFilters({ isAdmin: false })

    expect(screen.queryByText('Entrega:')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Hoy' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Mañana' })).not.toBeInTheDocument()

    await abrirPanel(user)
    for (const nombre of FILTROS_SOLO_ADMIN) {
      expect(screen.queryByRole('combobox', { name: nombre })).not.toBeInTheDocument()
    }
    // Ni siquiera la sección de entrega del sheet.
    expect(screen.queryByText('Entrega programada')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Hoy' })).not.toBeInTheDocument()
  })

  it('el no-admin conserva el estado, el buscador y las fechas', async () => {
    const user = userEvent.setup()
    renderFilters({ isAdmin: false })

    expect(screen.getByRole('textbox', { name: /buscar pedidos/i })).toBeInTheDocument()
    await abrirPanel(user)
    expect(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })).toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: 'Incluir cancelados' })).toBeInTheDocument()
    // Las fechas de carga, que antes eran el botón "Fechas" (dos veces, uno por
    // layout), ahora son la sección "Fecha de carga" del panel (#769).
    expect(screen.getByLabelText('Desde')).toBeInTheDocument()
    expect(screen.getByLabelText('Hasta')).toBeInTheDocument()
  })

  it('el selector de transportista lista "Sin asignar" y los transportistas recibidos', async () => {
    const user = userEvent.setup()
    renderFilters()
    await abrirPanel(user)
    const select = screen.getByRole('combobox', { name: /filtrar por transportista/i })

    expect(within(select).getByRole('option', { name: 'Todos los transportistas' })).toBeInTheDocument()
    expect(within(select).getByRole('option', { name: 'Sin asignar' })).toBeInTheDocument()
    expect(within(select).getByRole('option', { name: 'Ramón Chofer' })).toBeInTheDocument()
  })

  it('elegir un transportista avisa su id', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()
    await abrirPanel(user)

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por transportista/i }), 't1')

    expect(onFiltrosChange).toHaveBeenCalledWith({ transportistaId: 't1' })
  })

  it('elegir un usuario que cargó avisa su id', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()
    await abrirPanel(user)

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por usuario que cargó/i }), 'u1')

    expect(onFiltrosChange).toHaveBeenCalledWith({ usuarioId: 'u1' })
  })

  it('elegir estado de pago avisa el valor', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()
    await abrirPanel(user)

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por estado de pago/i }), 'parcial')

    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'parcial' })
  })

  it('elegir "Con salvedad" avisa el valor', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()
    await abrirPanel(user)

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
// LA FILA: BUSCADOR + ENTREGA (SÓLO ADMIN) + UN TRIGGER (WP-44, #769)
// =============================================================================

describe('PedidoFilters — la fila cerrada', () => {
  it('el admin tiene buscador, Hoy, Mañana, la fecha de entrega y el trigger, sin abrir nada', () => {
    renderFilters({ isAdmin: true })

    expect(screen.getByRole('textbox', { name: /buscar pedidos/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Hoy' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Mañana' })).toBeInTheDocument()
    expect(screen.getByLabelText('Fecha de entrega programada')).toHaveAttribute('type', 'date')
    expect(screen.getAllByRole('button', { name: 'Abrir filtros avanzados' })).toHaveLength(1)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('un no-admin sólo tiene el buscador y el trigger: nada de entrega', () => {
    renderFilters({ isAdmin: false })

    expect(screen.getByRole('textbox', { name: /buscar pedidos/i })).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Abrir filtros avanzados' })).toHaveLength(1)
    expect(screen.queryByRole('button', { name: 'Hoy' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Mañana' })).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Fecha de entrega programada')).not.toBeInTheDocument()
  })

  it('"Limpiar todo" sigue mandando la entrega en null dentro del payload de siete campos', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { fechaEntregaProgramada: HOY } })

    await abrirPanel(user)
    await user.click(screen.getByRole('button', { name: 'Limpiar todo' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({
      estado: 'todos',
      estadoPago: 'todos',
      transportistaId: 'todos',
      usuarioId: 'todos',
      conSalvedad: 'todos',
      fechaEntregaProgramada: null,
      verCancelados: false,
    })
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
// CONTADOR DEL TRIGGER "Filtros (N)"
// =============================================================================

/**
 * El badge del trigger es el consumidor visible de `contarFiltrosActivos`
 * (src/utils/filtrosPedidos.ts, con sus propios tests unitarios).
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

  // Invertido en WP-44 (cierra #733): el contador cuenta sólo lo que el rol
  // puede ver y tocar. Un no-admin no tiene controles de pago (salvo el tile de
  // impagos, ver más abajo), transportista, usuario, salvedad ni entrega: si el
  // estado los trae puestos, el badge no se los anuncia.
  it('no cuenta los filtros de admin que el rol no puede ver', async () => {
    const user = userEvent.setup()
    renderFilters({ isAdmin: false, filtros: { estadoPago: 'parcial', conSalvedad: 'con_salvedad' } })

    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
    await abrirPanel(user)
    expect(screen.queryByRole('combobox', { name: /filtrar por estado de pago/i })).not.toBeInTheDocument()
    expect(screen.getByText('Refiná tu búsqueda')).toBeInTheDocument()
  })

  it('el admin, que sí los ve y los puede tocar, los cuenta', () => {
    renderFilters({ isAdmin: true, filtros: { estadoPago: 'parcial', conSalvedad: 'con_salvedad' } })

    expect(within(botonFiltros()).getByText('2')).toBeInTheDocument()
  })

  it.each([
    ['el transportista', { transportistaId: 't1' }],
    ['el usuario que cargó', { usuarioId: 'u1' }],
    ['la salvedad', { conSalvedad: 'sin_salvedad' as const }],
    ['la entrega programada', { fechaEntregaProgramada: HOY }],
    ['un pago que no es impago', { estadoPago: 'pagado' }],
  ])('para un no-admin, %s puesto no suma', (_nombre, filtros) => {
    renderFilters({ isAdmin: false, filtros })

    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
  })

  it('para un no-admin, el estado y "cancelados" (que sí ve) suman igual que para el admin', () => {
    renderFilters({ isAdmin: false, filtros: { estado: 'pendiente', verCancelados: true, conSalvedad: 'con_salvedad' } })

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
  it('con estadoPago impago el select de pago lo muestra elegido', async () => {
    const user = userEvent.setup()
    renderFilters({ filtros: { estadoPago: 'impago' } })
    await abrirPanel(user)

    const pago = screen.getByRole('combobox', { name: /filtrar por estado de pago/i })
    expect(pago).toHaveValue('impago')
    expect(within(pago).getByRole('option', { name: 'Impagos (sin pagar o parcial)', selected: true })).toBeInTheDocument()
  })

  it('elegir "Todos los pagos" lo quita', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { estadoPago: 'impago' } })
    await abrirPanel(user)

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por estado de pago/i }), 'Todos los pagos')

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'todos' })
  })

  it('también se puede elegir desde el select, con el mismo valor que el tile', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()
    await abrirPanel(user)

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
// fijan que los dos lo cuenten. Desde WP-44 (#733) el contador respeta
// `isAdmin`, pero con esta excepción (comentario del dueño en #733): sin ella
// el no-admin con impagos vería el badge en 0 y "Limpiar todo" deshabilitado,
// y estos casos se ponen en rojo.
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

// =============================================================================
// CHIPS DE FILTROS ACTIVOS (WP-44, #769)
// =============================================================================

describe('PedidoFilters — un chip por filtro activo, con su X', () => {
  it('sin filtros no hay fila de chips', () => {
    renderFilters()

    expect(screen.queryByRole('status', { name: 'Filtros activos' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^quitar filtro/i })).not.toBeInTheDocument()
  })

  it.each([
    ['el estado', { estado: 'pendiente' }, 'Estado: Pendientes', 'Quitar filtro Estado', { estado: 'todos' }],
    ['"En camino" (value asignado)', { estado: 'asignado' }, 'Estado: En camino', 'Quitar filtro Estado', { estado: 'todos' }],
    ['el pago', { estadoPago: 'parcial' }, 'Pago: Parcial', 'Quitar filtro Pago', { estadoPago: 'todos' }],
    ['el pago impago del tile', { estadoPago: 'impago' }, 'Pago: Impagos', 'Quitar filtro Pago', { estadoPago: 'todos' }],
    ['el transportista, por nombre', { transportistaId: 't1' }, 'Transportista: Ramón Chofer', 'Quitar filtro Transportista', { transportistaId: 'todos' }],
    ['"sin asignar"', { transportistaId: 'sin_asignar' }, 'Transportista: Sin asignar', 'Quitar filtro Transportista', { transportistaId: 'todos' }],
    ['el usuario que cargó, por nombre', { usuarioId: 'u1' }, 'Cargado por: Vale Preventista', 'Quitar filtro Cargado por', { usuarioId: 'todos' }],
    ['la salvedad', { conSalvedad: 'con_salvedad' as const }, 'Salvedad: Con salvedad', 'Quitar filtro Salvedad', { conSalvedad: 'todos' }],
    ['la entrega de hoy', { fechaEntregaProgramada: HOY }, 'Entrega: Hoy', 'Quitar filtro Entrega', { fechaEntregaProgramada: null }],
    ['la entrega de mañana', { fechaEntregaProgramada: MANANA }, 'Entrega: Mañana', 'Quitar filtro Entrega', { fechaEntregaProgramada: null }],
    ['una entrega suelta', { fechaEntregaProgramada: '2026-05-20' }, 'Entrega: 20/05/2026', 'Quitar filtro Entrega', { fechaEntregaProgramada: null }],
    ['ver cancelados', { verCancelados: true }, 'Cancelados: Incluidos', 'Quitar filtro Cancelados', { verCancelados: false }],
  ])('%s tiene chip y su X lo quita sin abrir el panel', async (_nombre, filtros, texto, nombreQuitar, parche) => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros })

    const fila = screen.getByRole('status', { name: 'Filtros activos' })
    expect(fila).toHaveTextContent(texto)

    await user.click(within(fila).getByRole('button', { name: nombreQuitar }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith(parche)
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('con todos puestos hay un chip por filtro, y el de fechas es el de siempre', () => {
    renderFilters({
      filtros: {
        estado: 'pendiente',
        estadoPago: 'parcial',
        transportistaId: 't1',
        usuarioId: 'u1',
        conSalvedad: 'con_salvedad',
        fechaEntregaProgramada: HOY,
        verCancelados: true,
        fechaDesde: '2026-04-01',
        fechaHasta: '2026-04-15',
      },
    })

    const fila = screen.getByRole('status', { name: 'Filtros activos' })
    expect(within(fila).getAllByRole('button').map(b => b.getAttribute('aria-label'))).toEqual([
      'Quitar filtro Estado',
      'Quitar filtro Pago',
      'Quitar filtro Transportista',
      'Quitar filtro Cargado por',
      'Quitar filtro Salvedad',
      'Quitar filtro Entrega',
      'Quitar filtro Cancelados',
      'Limpiar filtro de fechas',
    ])
    expect(fila).toHaveTextContent('Filtrado: 2026-04-01 – 2026-04-15')
  })

  // #733: el chip, igual que el contador, sólo muestra lo que el rol puede ver.
  it('un no-admin sólo ve chips de lo que puede tocar: estado, cancelados y fechas', () => {
    renderFilters({
      isAdmin: false,
      filtros: {
        estado: 'pendiente',
        estadoPago: 'parcial',
        transportistaId: 't1',
        usuarioId: 'u1',
        conSalvedad: 'con_salvedad',
        fechaEntregaProgramada: HOY,
        verCancelados: true,
        fechaDesde: '2026-04-01',
      },
    })

    const fila = screen.getByRole('status', { name: 'Filtros activos' })
    expect(within(fila).getAllByRole('button').map(b => b.getAttribute('aria-label'))).toEqual([
      'Quitar filtro Estado',
      'Quitar filtro Cancelados',
      'Limpiar filtro de fechas',
    ])
  })

  // El tile "Impagos" filtra para cualquier rol (#715): el no-admin tiene que
  // ver ese filtro y poder quitarlo aunque no tenga el select de pago.
  it('un no-admin con el impago del tile lo ve como chip y lo puede quitar', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ isAdmin: false, filtros: { estadoPago: 'impago' } })

    await user.click(screen.getByRole('button', { name: 'Quitar filtro Pago' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'todos' })
  })

  it('con estado real: quitar un chip deja los demás y baja el contador', async () => {
    const user = userEvent.setup()
    function Contenedor() {
      const [filtros, setFiltros] = useState<Filtros>({ ...FILTROS_BASE, estado: 'entregado', verCancelados: true })
      return (
        <PedidoFilters
          busqueda=""
          filtros={filtros}
          transportistas={TRANSPORTISTAS}
          usuarios={USUARIOS}
          isAdmin
          onBusquedaChange={() => {}}
          onFiltrosChange={parche => setFiltros(prev => ({ ...prev, ...parche }))}
        />
      )
    }
    render(<Contenedor />)

    expect(within(botonFiltros()).getByText('2')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Quitar filtro Estado' }))

    expect(screen.queryByRole('button', { name: 'Quitar filtro Estado' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Quitar filtro Cancelados' })).toBeInTheDocument()
    expect(within(botonFiltros()).getByText('1')).toBeInTheDocument()
  })

  // Al quitar un chip su botón se desmonta: el foco tiene que ir a un vecino y,
  // si era el último, al trigger, no caer a <body>.
  describe('el foco no se pierde al quitar un chip', () => {
    function Contenedor({ inicial }: { inicial: Partial<Filtros> }) {
      const [filtros, setFiltros] = useState<Filtros>({ ...FILTROS_BASE, ...inicial })
      return (
        <PedidoFilters
          busqueda=""
          filtros={filtros}
          transportistas={TRANSPORTISTAS}
          usuarios={USUARIOS}
          isAdmin
          onBusquedaChange={() => {}}
          onFiltrosChange={parche => setFiltros(prev => ({ ...prev, ...parche }))}
        />
      )
    }

    it('quitar un chip pasa el foco al chip siguiente', async () => {
      const user = userEvent.setup()
      render(<Contenedor inicial={{ estado: 'entregado', estadoPago: 'pagado', verCancelados: true }} />)

      await user.click(screen.getByRole('button', { name: 'Quitar filtro Estado' }))

      expect(screen.queryByRole('button', { name: 'Quitar filtro Estado' })).not.toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Quitar filtro Pago' })).toHaveFocus()
    })

    it('quitar el último chip de la fila pasa el foco al anterior', async () => {
      const user = userEvent.setup()
      render(<Contenedor inicial={{ estado: 'entregado', estadoPago: 'pagado' }} />)

      await user.click(screen.getByRole('button', { name: 'Quitar filtro Pago' }))

      expect(screen.getByRole('button', { name: 'Quitar filtro Estado' })).toHaveFocus()
    })

    it('quitar el único chip pasa el foco al trigger de filtros', async () => {
      const user = userEvent.setup()
      render(<Contenedor inicial={{ estado: 'entregado' }} />)

      await user.click(screen.getByRole('button', { name: 'Quitar filtro Estado' }))

      expect(screen.queryByRole('status', { name: 'Filtros activos' })).not.toBeInTheDocument()
      expect(botonFiltros()).toHaveFocus()
    })
  })
})

// =============================================================================
// UN SOLO TRIGGER: SHEET EN CELULAR, POPOVER EN ESCRITORIO (WP-44, #769)
// =============================================================================

describe('PedidoFilters — en celular el trigger abre el bottom sheet', () => {
  it('el sheet es un diálogo con su X "Cerrar", y el panel adentro está UNA vez', async () => {
    const user = userEvent.setup()
    renderFilters()

    expect(botonFiltros()).toHaveAttribute('aria-expanded', 'false')
    const sheet = await abrirPanel(user)

    expect(botonFiltros({ hidden: true })).toHaveAttribute('aria-expanded', 'true')
    expect(within(sheet).getByRole('button', { name: 'Cerrar' })).toBeInTheDocument()
    // Sin la fila de escritorio detrás: cada control existe una sola vez, aun
    // contando lo que Radix esconde con aria-hidden.
    expect(screen.getAllByRole('combobox', { hidden: true })).toHaveLength(5)
    expect(screen.getAllByRole('checkbox', { hidden: true })).toHaveLength(1)
  })

  // El sheet de celular conserva su sección de entrega programada y la fila de la
  // barra también tiene la suya: en el DOM son dos. Pero el sheet es un modal y
  // Radix deja lo de atrás con aria-hidden, así que en el árbol accesible (y a la
  // vista, bajo el overlay) el admin tiene UN solo juego de Hoy / Mañana.
  it('con el sheet abierto el árbol accesible tiene un solo juego de Hoy / Mañana', async () => {
    const user = userEvent.setup()
    renderFilters({ filtros: { fechaEntregaProgramada: HOY } })
    const sheet = await abrirPanel(user)

    expect(screen.getAllByRole('button', { name: 'Hoy' })).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: 'Mañana' })).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: 'Limpiar filtro de entrega' })).toHaveLength(1)
    expect(within(sheet).getByRole('button', { name: 'Hoy' })).toBeInTheDocument()
  })
})

describe('PedidoFilters — en escritorio el MISMO trigger abre un popover', () => {
  // En escritorio `matchMedia('(min-width: 640px)')` matchea. El posicionador de
  // Radix (@floating-ui) construye un ResizeObserver con `new`, y el de
  // src/test/setup.js no se puede construir (#735): se pisa sólo para este bloque.
  class ObservadorStub {
    observe(): void { /* no-op */ }
    unobserve(): void { /* no-op */ }
    disconnect(): void { /* no-op */ }
  }
  const originales = { matchMedia: window.matchMedia, ResizeObserver: globalThis.ResizeObserver }

  beforeAll(() => {
    window.matchMedia = vi.fn().mockImplementation((query: string) => ({
      matches: query === '(min-width: 640px)',
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    }))
    globalThis.ResizeObserver = ObservadorStub as unknown as typeof ResizeObserver
  })
  afterAll(() => {
    window.matchMedia = originales.matchMedia
    globalThis.ResizeObserver = originales.ResizeObserver
  })

  it('el trigger es uno solo y abre un popover "Filtros", no el sheet', async () => {
    const user = userEvent.setup()
    renderFilters()

    expect(screen.getAllByRole('button', { name: 'Abrir filtros avanzados' })).toHaveLength(1)
    expect(botonFiltros()).toHaveAttribute('aria-haspopup', 'dialog')
    await user.click(botonFiltros())

    const popover = await screen.findByRole('dialog', { name: 'Filtros' })
    expect(botonFiltros()).toHaveAttribute('aria-expanded', 'true')
    expect(botonFiltros()).toHaveAttribute('aria-controls', popover.id)
    // El popover no tiene la X "Cerrar" del sheet: se cierra con Listo, Escape o click afuera.
    expect(within(popover).queryByRole('button', { name: 'Cerrar' })).not.toBeInTheDocument()
    expect(within(popover).getByText('Refiná tu búsqueda')).toBeInTheDocument()
  })

  it('adentro está el mismo panel: mismas secciones y cada control una vez', async () => {
    const user = userEvent.setup()
    renderFilters()
    await user.click(botonFiltros())
    const popover = await screen.findByRole('dialog', { name: 'Filtros' })

    for (const seccion of ['Estado del pedido', 'Pago', 'Transportista', 'Cargado por', 'Entregas con salvedad', 'Fecha de carga', 'Otros']) {
      expect(within(popover).getByText(seccion)).toBeInTheDocument()
    }
    expect(screen.getAllByRole('combobox')).toHaveLength(5)
    expect(screen.getAllByRole('checkbox', { name: 'Incluir cancelados' })).toHaveLength(1)
  })

  // La entrega programada está en la fila, que en escritorio se ve al lado del
  // popover: una segunda copia adentro sería el mismo control dos veces a la vista.
  it('la entrega programada está en la fila, UNA vez, y no se repite adentro del popover', async () => {
    const user = userEvent.setup()
    renderFilters()

    expect(screen.getAllByRole('button', { name: 'Hoy' })).toHaveLength(1)
    await user.click(botonFiltros())
    const popover = await screen.findByRole('dialog', { name: 'Filtros' })

    expect(within(popover).queryByText('Entrega programada')).not.toBeInTheDocument()
    expect(within(popover).queryByRole('button', { name: 'Hoy' })).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Hoy' })).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: 'Mañana' })).toHaveLength(1)
    expect(screen.getAllByLabelText('Fecha de entrega programada')).toHaveLength(1)
  })

  it('emite en vivo, sin Aplicar, y "Limpiar todo" manda el payload de siete campos', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters({ filtros: { estado: 'pendiente' } })
    await user.click(botonFiltros())
    const popover = await screen.findByRole('dialog', { name: 'Filtros' })

    await user.selectOptions(within(popover).getByRole('combobox', { name: /filtrar por transportista/i }), 't1')
    expect(onFiltrosChange).toHaveBeenLastCalledWith({ transportistaId: 't1' })
    expect(within(popover).queryByRole('button', { name: /aplicar/i })).not.toBeInTheDocument()

    await user.click(within(popover).getByRole('button', { name: 'Limpiar todo' }))
    expect(onFiltrosChange).toHaveBeenLastCalledWith({
      estado: 'todos',
      estadoPago: 'todos',
      transportistaId: 'todos',
      usuarioId: 'todos',
      conSalvedad: 'todos',
      fechaEntregaProgramada: null,
      verCancelados: false,
    })
    expect(onFiltrosChange).toHaveBeenCalledTimes(2)
  })

  it('"Listo" y Escape lo cierran sin emitir nada', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters()

    await user.click(botonFiltros())
    await user.click(within(await screen.findByRole('dialog', { name: 'Filtros' })).getByRole('button', { name: 'Listo' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    await user.click(botonFiltros())
    await screen.findByRole('dialog', { name: 'Filtros' })
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('un no-admin ve en el popover sólo estado, fecha de carga y cancelados', async () => {
    const user = userEvent.setup()
    renderFilters({ isAdmin: false })
    await user.click(botonFiltros())
    const popover = await screen.findByRole('dialog', { name: 'Filtros' })

    expect(within(popover).getAllByRole('combobox')).toHaveLength(1)
    expect(within(popover).getByRole('combobox', { name: /filtrar por estado del pedido/i })).toBeInTheDocument()
    expect(within(popover).getByLabelText('Desde')).toBeInTheDocument()
    expect(within(popover).getByRole('checkbox', { name: 'Incluir cancelados' })).toBeInTheDocument()
    expect(within(popover).queryByText('Entrega programada')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Hoy' })).not.toBeInTheDocument()
  })
})
