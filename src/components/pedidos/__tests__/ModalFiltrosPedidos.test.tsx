/**
 * Tests de CARACTERIZACIÓN de `ModalFiltrosPedidos` — el bottom sheet de
 * filtros de /pedidos en mobile.
 *
 * Lo que fijan, porque es lo que el rediseño puede romper sin darse cuenta:
 *
 *  - Los cambios son EN VIVO. No hay "Aplicar": cada `onChange` llama a
 *    `onFiltrosChange` en el acto y "Listo" no hace más que cerrar. Si alguien
 *    agrega un botón Aplicar y deja de emitir en vivo, la pantalla de atrás
 *    deja de reaccionar y nadie se entera hasta producción.
 *  - "Limpiar todo" manda UN payload con los siete filtros del sheet, y no
 *    toca ni la búsqueda ni el rango fechaDesde/fechaHasta (la búsqueda vive
 *    afuera y el rango tiene su propio "Limpiar fechas de carga").
 *
 * Desde WP-44 (#769) el contenido del sheet es `PanelFiltrosPedidos`, el mismo
 * que el popover de escritorio, y los `<select>` tienen `aria-label`. Los casos
 * de antes los siguen buscando por una opción propia (`selectQueOfrece`), que
 * sigue siendo válido.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import ModalFiltrosPedidos, { type ModalFiltrosPedidosProps } from '../ModalFiltrosPedidos'
import type { RolUsuario, Usuario } from '../../../types'

// =============================================================================
// FECHA FIJA
// =============================================================================

/**
 * 16/04/2026 02:00 UTC = 15/04/2026 23:00 en Argentina (UTC-3).
 *
 * Mismo fixture que `PedidoFilters.test.tsx`, y por el mismo motivo: el reloj
 * está en la franja donde la fecha UTC (16) y la argentina (15) NO coinciden,
 * así que un cálculo hecho con `toISOString()` en vez de `fechaLocalISO()`
 * pone los tests de "Hoy" y "Mañana" en rojo en vez de pasar de casualidad.
 */
const AHORA = new Date('2026-04-16T02:00:00Z')
const HOY = '2026-04-15'
const MANANA = '2026-04-16'

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(AHORA)
})

afterEach(() => {
  vi.useRealTimers()
})

// =============================================================================
// FIXTURES
// =============================================================================

type Filtros = ModalFiltrosPedidosProps['filtros']

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
  activosCount?: number
  open?: boolean
}

function renderSheet(opciones: OpcionesRender = {}) {
  const onFiltrosChange = vi.fn()
  const onClose = vi.fn()

  render(
    <ModalFiltrosPedidos
      open={opciones.open ?? true}
      filtros={{ ...FILTROS_BASE, ...opciones.filtros }}
      transportistas={TRANSPORTISTAS}
      usuarios={USUARIOS}
      isAdmin={opciones.isAdmin ?? true}
      activosCount={opciones.activosCount ?? 0}
      onFiltrosChange={onFiltrosChange}
      onClose={onClose}
    />,
  )

  return { onFiltrosChange, onClose }
}

/**
 * El `<select>` que contiene esa opción. Los selects del sheet no tienen
 * nombre accesible, así que se los identifica por su contenido visible.
 */
function selectQueOfrece(opcion: string): HTMLSelectElement {
  const option = screen.getByRole('option', { name: opcion })
  const select = option.closest('select')
  if (!select) throw new Error(`La opción "${opcion}" no está dentro de un <select>`)
  return select
}

/**
 * El `input[type="date"]` de "Entrega programada". Tampoco tiene nombre
 * accesible, así que se lo toma por su tipo. El sheet vive en un portal de
 * Radix: hay que buscarlo desde `document`, no desde el container del render.
 */
function inputFechaEntrega(): HTMLInputElement {
  const input = document.querySelector<HTMLInputElement>('input[type="date"]')
  if (!input) throw new Error('No hay input de fecha de entrega en el sheet')
  return input
}

// =============================================================================
// APERTURA Y CIERRE
// =============================================================================

describe('ModalFiltrosPedidos — apertura y cierre', () => {
  it('cerrado no monta nada', () => {
    renderSheet({ open: false })

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByText('Estado del pedido')).not.toBeInTheDocument()
  })

  it('abierto muestra el diálogo titulado "Filtros"', () => {
    renderSheet()

    expect(screen.getByRole('dialog', { name: 'Filtros' })).toBeInTheDocument()
  })

  it('sin filtros activos el subtítulo invita a refinar', () => {
    renderSheet({ activosCount: 0 })

    expect(screen.getByText('Refiná tu búsqueda')).toBeInTheDocument()
  })

  it('con un filtro activo el subtítulo va en singular', () => {
    renderSheet({ activosCount: 1 })

    expect(screen.getByText('1 filtro activo')).toBeInTheDocument()
  })

  it('con dos filtros activos el subtítulo va en plural', () => {
    renderSheet({ activosCount: 2 })

    expect(screen.getByText('2 filtros activos')).toBeInTheDocument()
  })

  it('la X del header cierra', async () => {
    const user = userEvent.setup()
    const { onClose, onFiltrosChange } = renderSheet()

    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('Escape cierra', async () => {
    const user = userEvent.setup()
    const { onClose } = renderSheet()

    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
  })

  // El tercer camino de dismissal que `BottomSheet.tsx` documenta ("tap fuera +
  // Escape cierran"): el overlay de Radix. No tiene rol ni nombre accesible, y
  // es el hermano anterior del panel dentro del portal.
  it('tocar el overlay cierra sin tocar los filtros', async () => {
    const user = userEvent.setup()
    const { onClose, onFiltrosChange } = renderSheet()

    const overlay = screen.getByRole('dialog').previousElementSibling
    expect(overlay).toBeInstanceOf(HTMLElement)
    await user.click(overlay as HTMLElement)

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })
})

// =============================================================================
// FOOTER: "LISTO" Y "LIMPIAR TODO"
// =============================================================================

describe('ModalFiltrosPedidos — footer', () => {
  it('NO existe un botón "Aplicar": los cambios ya se aplicaron solos', () => {
    renderSheet({ activosCount: 3 })

    expect(screen.queryByRole('button', { name: /aplicar/i })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Listo' })).toBeInTheDocument()
  })

  it('"Listo" sólo cierra: no emite ningún cambio de filtros', async () => {
    const user = userEvent.setup()
    const { onClose, onFiltrosChange } = renderSheet({ activosCount: 3, filtros: { estado: 'pendiente' } })

    await user.click(screen.getByRole('button', { name: 'Listo' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('"Limpiar todo" está deshabilitado cuando no hay filtros activos', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ activosCount: 0 })

    const limpiar = screen.getByRole('button', { name: 'Limpiar todo' })
    expect(limpiar).toBeDisabled()

    await user.click(limpiar)
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('"Limpiar todo" resetea los siete filtros del sheet en un solo payload', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onClose } = renderSheet({
      activosCount: 3,
      filtros: { estado: 'pendiente', estadoPago: 'parcial', verCancelados: true },
    })

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
    // Limpiar no cierra el sheet: el usuario sigue adentro para volver a filtrar.
    expect(onClose).not.toHaveBeenCalled()
  })

  it('"Limpiar todo" no toca la búsqueda ni el rango de fechas', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({
      activosCount: 1,
      filtros: { estado: 'pendiente', fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' },
    })

    await user.click(screen.getByRole('button', { name: 'Limpiar todo' }))

    const payload = onFiltrosChange.mock.calls[0][0]
    expect(payload).not.toHaveProperty('fechaDesde')
    expect(payload).not.toHaveProperty('fechaHasta')
  })
})

// =============================================================================
// CAMBIOS EN VIVO
// =============================================================================

describe('ModalFiltrosPedidos — cada cambio aplica en el acto', () => {
  it('cambiar el estado emite sólo el estado', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onClose } = renderSheet()

    await user.selectOptions(selectQueOfrece('Todos los estados'), 'en_preparacion')

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'en_preparacion' })
    expect(onClose).not.toHaveBeenCalled()
  })

  it('cambiar el pago emite sólo el pago', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.selectOptions(selectQueOfrece('Todos los pagos'), 'pagado')

    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'pagado' })
  })

  it('elegir transportista emite su id', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.selectOptions(selectQueOfrece('Todos los transportistas'), 't1')

    expect(onFiltrosChange).toHaveBeenCalledWith({ transportistaId: 't1' })
  })

  it('elegir "Sin asignar" también es un valor de transportista', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.selectOptions(selectQueOfrece('Todos los transportistas'), 'sin_asignar')

    expect(onFiltrosChange).toHaveBeenCalledWith({ transportistaId: 'sin_asignar' })
  })

  it('elegir el usuario que cargó emite su id', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.selectOptions(selectQueOfrece('Todos los usuarios'), 'u1')

    expect(onFiltrosChange).toHaveBeenCalledWith({ usuarioId: 'u1' })
  })

  it('elegir "Sin salvedad" emite el valor', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.selectOptions(selectQueOfrece('Todas las entregas'), 'sin_salvedad')

    expect(onFiltrosChange).toHaveBeenCalledWith({ conSalvedad: 'sin_salvedad' })
  })

  it('"Incluir cancelados" emite el booleano', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.click(screen.getByRole('checkbox', { name: 'Incluir cancelados' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: true })
  })

  it('destildar "Incluir cancelados" emite false', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ filtros: { verCancelados: true } })

    const check = screen.getByRole('checkbox', { name: 'Incluir cancelados' })
    expect(check).toBeChecked()
    await user.click(check)

    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: false })
  })
})

// =============================================================================
// ENTREGA PROGRAMADA
// =============================================================================

describe('ModalFiltrosPedidos — entrega programada', () => {
  it('"Hoy" emite la fecha de hoy en TZ Argentina', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.click(screen.getByRole('button', { name: 'Hoy' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: HOY })
  })

  it('"Mañana" emite el día siguiente', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.click(screen.getByRole('button', { name: 'Mañana' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: MANANA })
  })

  it('volver a tocar "Hoy" cuando ya está activo lo apaga', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ filtros: { fechaEntregaProgramada: HOY } })

    await user.click(screen.getByRole('button', { name: 'Hoy' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('el input de fecha precargado muestra la entrega vigente', () => {
    renderSheet({ filtros: { fechaEntregaProgramada: '2026-05-20' } })

    expect(inputFechaEntrega()).toHaveValue('2026-05-20')
  })

  it('escribir una fecha suelta en el input la emite tal cual', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.type(inputFechaEntrega(), '2026-05-20')

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: '2026-05-20' })
  })

  it('borrar el input emite null, no cadena vacía', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ filtros: { fechaEntregaProgramada: '2026-05-20' } })

    await user.clear(inputFechaEntrega())

    // Misma coerción `e.target.value || null` que en el layout de desktop: el
    // sheet tiene su propia copia del input y podría desincronizarse sola.
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
    expect(onFiltrosChange).not.toHaveBeenCalledWith({ fechaEntregaProgramada: '' })
  })

  it('con una fecha suelta aparece la X que la limpia', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ filtros: { fechaEntregaProgramada: '2026-05-20' } })

    await user.click(screen.getByRole('button', { name: 'Limpiar filtro de entrega' }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('sin fecha de entrega no hay X para limpiar', () => {
    renderSheet()

    expect(screen.queryByRole('button', { name: 'Limpiar filtro de entrega' })).not.toBeInTheDocument()
  })
})

// =============================================================================
// SECCIONES SEGÚN EL ROL
// =============================================================================

const SECCIONES_SOLO_ADMIN = [
  'Pago',
  'Transportista',
  'Cargado por',
  'Entregas con salvedad',
  'Entrega programada',
] as const

describe('ModalFiltrosPedidos — qué secciones ve cada rol', () => {
  it('el admin ve las siete secciones', () => {
    renderSheet({ isAdmin: true })

    expect(screen.getByText('Estado del pedido')).toBeInTheDocument()
    for (const seccion of SECCIONES_SOLO_ADMIN) {
      expect(screen.getByText(seccion)).toBeInTheDocument()
    }
    expect(screen.getByText('Otros')).toBeInTheDocument()
  })

  it('el no-admin sólo ve "Estado del pedido" y "Otros"', () => {
    renderSheet({ isAdmin: false })

    expect(screen.getByText('Estado del pedido')).toBeInTheDocument()
    expect(screen.getByText('Otros')).toBeInTheDocument()
    for (const seccion of SECCIONES_SOLO_ADMIN) {
      expect(screen.queryByText(seccion)).not.toBeInTheDocument()
    }
  })

  it('el no-admin conserva el estado y el toggle de cancelados operativos', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ isAdmin: false })

    await user.selectOptions(selectQueOfrece('Todos los estados'), 'cancelado')
    await user.click(screen.getByRole('checkbox', { name: 'Incluir cancelados' }))

    expect(onFiltrosChange).toHaveBeenNthCalledWith(1, { estado: 'cancelado' })
    expect(onFiltrosChange).toHaveBeenNthCalledWith(2, { verCancelados: true })
  })

  it('el estado del sheet ofrece los mismos seis valores que el de desktop', () => {
    renderSheet()
    const select = selectQueOfrece('Todos los estados')

    // Etiqueta Y value: el sheet y el selector de desktop escriben el mismo
    // filtro, así que si uno de los dos renombra un value —'asignado' es el
    // que menos se parece a su etiqueta, "En camino"— quedan desalineados y el
    // filtrado contra la base cambia según desde dónde se lo toque.
    for (const [etiqueta, value] of ESTADOS) {
      expect(within(select).getByRole('option', { name: etiqueta })).toHaveValue(value)
    }
  })
})

// =============================================================================
// PAGO "IMPAGO": EL QUE APLICA EL TILE "Impagos" DE PedidoStats (#715)
// =============================================================================

describe('ModalFiltrosPedidos — el pago "impago" del tile (#715)', () => {
  it('con estadoPago impago el select de pago lo muestra elegido', () => {
    renderSheet({ filtros: { estadoPago: 'impago' }, activosCount: 1 })

    const pago = selectQueOfrece('Todos los pagos')
    expect(pago).toHaveValue('impago')
    expect(within(pago).getByRole('option', { name: 'Impagos (sin pagar o parcial)', selected: true })).toBeInTheDocument()
  })

  it('elegir "Todos los pagos" lo quita en el acto', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ filtros: { estadoPago: 'impago' }, activosCount: 1 })

    await user.selectOptions(selectQueOfrece('Todos los pagos'), 'Todos los pagos')

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'todos' })
  })

  it('también se puede elegir desde el sheet, con el mismo valor que el tile', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.selectOptions(selectQueOfrece('Todos los pagos'), 'Impagos (sin pagar o parcial)')

    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'impago' })
  })

  // El tile "Impagos" filtra para todos los roles. El no-admin no tiene la
  // sección de pago en el sheet, así que "Limpiar todo" es, además del tile,
  // la forma de quitarle ese filtro: tiene que estar habilitado y mandar el
  // pago a 'todos' aunque ese select no se vea.
  it('el no-admin sin sección de pago igual lo quita con "Limpiar todo"', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ isAdmin: false, filtros: { estadoPago: 'impago' }, activosCount: 1 })

    expect(screen.queryByRole('option', { name: 'Todos los pagos' })).not.toBeInTheDocument()
    const limpiar = screen.getByRole('button', { name: 'Limpiar todo' })
    expect(limpiar).toBeEnabled()

    await user.click(limpiar)

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
// FECHA DE CARGA (Desde / Hasta) — mudado de ModalFiltroFecha.test.tsx (#769)
// =============================================================================
//
// Hasta WP-44 el rango de fechas de carga era un modal aparte, `ModalFiltroFecha`
// (un Dialog centrado con estado local y "Aplicar"). Ahora es la sección "Fecha
// de carga" de este mismo panel y, como el resto, emite EN VIVO. Los casos de
// comportamiento se mudaron acá: qué valores llegan (rango completo, medias
// puntas, las dos puntas vacías como null/null, "Limpiar") son los mismos; lo
// que cambió es que llegan al cambiar cada campo, sin "Aplicar". El caso "BUG:
// acepta un rango invertido sin avisar nada" (#734) se invirtió.

/** Las dos fechas de carga, ahora con nombre accesible propio. */
function camposCarga(): [HTMLInputElement, HTMLInputElement] {
  return [screen.getByLabelText<HTMLInputElement>('Desde'), screen.getByLabelText<HTMLInputElement>('Hasta')]
}

describe('ModalFiltrosPedidos — fecha de carga: render', () => {
  it.each([true, false])('la sección está para cualquier rol (isAdmin=%s), con Desde y Hasta', (isAdmin) => {
    renderSheet({ isAdmin })

    expect(screen.getByText('Fecha de carga')).toBeInTheDocument()
    const [desde, hasta] = camposCarga()
    expect(desde).toHaveAttribute('type', 'date')
    expect(hasta).toHaveAttribute('type', 'date')
  })

  it('precarga el rango que ya venía filtrado', () => {
    renderSheet({ filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    const [desde, hasta] = camposCarga()
    expect(desde).toHaveValue('2026-04-01')
    expect(hasta).toHaveValue('2026-04-15')
  })

  it('sin rango previo arranca con los dos campos vacíos y sin "Limpiar fechas de carga"', () => {
    renderSheet()

    const [desde, hasta] = camposCarga()
    expect(desde).toHaveValue('')
    expect(hasta).toHaveValue('')
    expect(screen.queryByRole('button', { name: 'Limpiar fechas de carga' })).not.toBeInTheDocument()
  })
})

describe('ModalFiltrosPedidos — fecha de carga: qué emite', () => {
  it('el rango completo llega con las dos puntas, sin "Aplicar" y sin cerrar', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onClose } = renderSheet()

    const [desde, hasta] = camposCarga()
    await user.type(desde, '2026-05-01')
    await user.type(hasta, '2026-05-31')

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: '2026-05-01', fechaHasta: '2026-05-31' })
    expect(screen.queryByRole('button', { name: /aplicar/i })).not.toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('media punta: sólo "Desde"', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.type(camposCarga()[0], '2026-05-01')

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: '2026-05-01', fechaHasta: null })
  })

  it('media punta: sólo "Hasta"', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.type(camposCarga()[1], '2026-05-31')

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: null, fechaHasta: '2026-05-31' })
  })

  it('con los dos campos vacíos el rango es nulo (no strings vacíos)', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({ filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    const [desde, hasta] = camposCarga()
    await user.clear(desde)
    await user.clear(hasta)

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: null, fechaHasta: null })
    for (const [parche] of onFiltrosChange.mock.calls) {
      expect(parche.fechaDesde).not.toBe('')
      expect(parche.fechaHasta).not.toBe('')
    }
  })

  // Invertido en WP-44 (cierra #734): antes el rango invertido se aplicaba tal
  // cual, el modal cerraba y la lista contestaba vacía sin explicación.
  it('un rango invertido NO se aplica y se avisa por qué', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onClose } = renderSheet()

    const [desde, hasta] = camposCarga()
    await user.type(desde, '2026-05-31')
    await user.type(hasta, '2026-05-01')

    expect(onFiltrosChange).not.toHaveBeenCalledWith({ fechaDesde: '2026-05-31', fechaHasta: '2026-05-01' })
    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: '2026-05-31', fechaHasta: null })
    expect(screen.getByRole('alert')).toHaveTextContent(/posterior/i)
    expect(desde).toHaveAttribute('aria-invalid', 'true')
    expect(hasta).toHaveAttribute('aria-invalid', 'true')
    // Lo tipeado queda a la vista para corregirlo, y el panel sigue abierto.
    expect(hasta).toHaveValue('2026-05-01')
    expect(onClose).not.toHaveBeenCalled()
  })

  it('al corregir el rango invertido se aplica el par entero y el aviso se va', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    const [desde, hasta] = camposCarga()
    await user.type(desde, '2026-05-31')
    await user.type(hasta, '2026-05-01')
    await user.clear(desde)
    await user.type(desde, '2026-04-01')

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: '2026-04-01', fechaHasta: '2026-05-01' })
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})

describe('ModalFiltrosPedidos — fecha de carga: "Limpiar fechas de carga"', () => {
  it('borra el rango con null/null y no cierra el panel', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onClose } = renderSheet({ filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    await user.click(screen.getByRole('button', { name: 'Limpiar fechas de carga' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: null })
    expect(onClose).not.toHaveBeenCalled()
  })

  it('ignora lo que se haya escrito recién: limpia igual', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet()

    await user.type(camposCarga()[0], '2026-05-01')
    await user.click(screen.getByRole('button', { name: 'Limpiar fechas de carga' }))

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: null, fechaHasta: null })
  })

  it('vacía los campos en el acto: el panel sigue abierto, no hay desmontaje que lo haga', async () => {
    const user = userEvent.setup()
    renderSheet({ filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    await user.click(screen.getByRole('button', { name: 'Limpiar fechas de carga' }))

    const [desde, hasta] = camposCarga()
    expect(desde).toHaveValue('')
    expect(hasta).toHaveValue('')
  })

  it('"Limpiar todo" sigue sin tocar el rango aunque haya fechas puestas', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderSheet({
      activosCount: 1,
      filtros: { estado: 'pendiente', fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' },
    })

    await user.click(screen.getByRole('button', { name: 'Limpiar todo' }))

    expect(camposCarga()[0]).toHaveValue('2026-04-01')
    expect(onFiltrosChange.mock.calls[0][0]).not.toHaveProperty('fechaDesde')
  })
})

describe('ModalFiltrosPedidos — fecha de carga: cerrar', () => {
  it('Escape con un rango invertido a medio escribir cierra sin emitirlo', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onClose } = renderSheet({ filtros: { fechaDesde: '2026-05-31' } })

    await user.type(camposCarga()[1], '2026-05-01')
    await user.keyboard('{Escape}')

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })
})

// =============================================================================
// FECHA DE CARGA: EL AÑO A MEDIO TIPEAR NO SE EMITE
// =============================================================================
//
// Con día y mes ya puestos, tipear el año con el teclado hace que el navegador
// dispare `change` con '0002-…', '0020-…', '0202-…' y recién después '2026-…'.
// `user.type` en jsdom sólo manda la fecha entera, así que estos casos mandan los
// `change` intermedios a mano.

describe('ModalFiltrosPedidos — fecha de carga: el año a medio tipear es un borrador', () => {
  const ANIOS_PARCIALES = ['0002', '0020', '0202']

  it('sólo se emite la fecha completa, no los años intermedios', () => {
    const { onFiltrosChange } = renderSheet()
    const [desde] = camposCarga()

    for (const anio of ANIOS_PARCIALES) {
      fireEvent.change(desde, { target: { value: `${anio}-05-01` } })
      // Lo tipeado queda a la vista, pero no llega a la consulta.
      expect(desde).toHaveValue(`${anio}-05-01`)
    }
    expect(onFiltrosChange).not.toHaveBeenCalled()

    fireEvent.change(desde, { target: { value: '2026-05-01' } })

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaDesde: '2026-05-01', fechaHasta: null })
  })

  it('con "Desde" puesto, tipear el año de "Hasta" no hace parpadear el aviso de rango invertido', () => {
    const { onFiltrosChange } = renderSheet({ filtros: { fechaDesde: '2026-05-10' } })
    const [, hasta] = camposCarga()

    for (const anio of ANIOS_PARCIALES) {
      fireEvent.change(hasta, { target: { value: `${anio}-05-31` } })
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      expect(hasta).not.toHaveAttribute('aria-invalid')
    }
    expect(onFiltrosChange).not.toHaveBeenCalled()

    fireEvent.change(hasta, { target: { value: '2026-05-31' } })

    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaDesde: '2026-05-10', fechaHasta: '2026-05-31' })
  })

  it('una fecha anterior a 2000 ya tipeada entera sí se emite: el modal viejo la aplicaba', () => {
    const { onFiltrosChange } = renderSheet()

    fireEvent.change(camposCarga()[0], { target: { value: '1999-12-31' } })

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaDesde: '1999-12-31', fechaHasta: null })
  })

  it('un rango completo pero invertido sigue avisando', () => {
    const { onFiltrosChange } = renderSheet({ filtros: { fechaDesde: '2026-05-10' } })

    fireEvent.change(camposCarga()[1], { target: { value: '2026-05-01' } })

    expect(screen.getByRole('alert')).toHaveTextContent(/posterior/i)
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('borrar un campo a medio corregir sí se emite: la punta vacía es un rango abierto', () => {
    const { onFiltrosChange } = renderSheet({ filtros: { fechaDesde: '2026-05-01', fechaHasta: '2026-05-31' } })

    fireEvent.change(camposCarga()[0], { target: { value: '' } })

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: '2026-05-31' })
  })
})
