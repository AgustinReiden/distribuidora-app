/**
 * Caracterización de WP-44 (issue #769): el panel único de filtros.
 *
 * `PedidoFilters.test.tsx` y `ModalFiltrosPedidos.test.tsx` fijan cada control
 * por separado, con `isAdmin` como único eje. Este archivo fija el INVENTARIO:
 * qué controles tiene cada ROL y qué parche de `onFiltrosChange` emite cada uno.
 * Se escribió ANTES del rediseño, contra los dos layouts de entonces, y se
 * ajustó con él: donde el rediseño cambió algo a propósito (los controles pasan
 * detrás de un solo trigger, las fechas de carga entran al panel, aparecen los
 * chips, #733 y #734) el caso se invirtió y lo dice; en el resto sólo cambió el
 * CAMINO para llegar al control (abrir el panel antes), nunca qué emite.
 *
 * Cómo se monta: igual que `VistaPedidos` + `PedidosContainer`. El `isAdmin` sale
 * de `authDataDeRol(rol)` (la misma cuenta que `App.tsx`, en `dev/gallery`), y
 * `usuarios` es `isAdmin ? todos : []` como en el container (línea `useMemo`
 * de `PedidosContainer`), mientras que `transportistas` le llega a todos los
 * roles. Ojo: `VistaPedidos` sólo le pasa `isAdmin` a `PedidoFilters`; encargado,
 * preventista, transportista y depósito son indistinguibles para la barra. Por
 * eso los casos se repiten por rol: no porque hoy difieran, sino porque un
 * rediseño puede empezar a distinguirlos y ahí hay que verlo.
 *
 * En jsdom `matchMedia` no matchea nada (src/test/setup.js), así que el panel
 * se abre como el bottom sheet del celular. El popover de escritorio envuelve
 * el mismo `PanelFiltrosPedidos` y se prueba en `PedidoFilters.test.tsx`. Se
 * asevera por rol ARIA, nombre accesible, texto y handlers; nunca por clase ni
 * por estructura de wrappers.
 *
 * Lo que queda AFUERA a propósito, porque sólo se puede fijar por estructura o
 * por CSS: qué envoltorio se ve en cada ancho (lo mide el orquestador en la
 * galería), el orden visual de los controles, el color de los chips y el ícono
 * de cada control.
 */
import '@testing-library/jest-dom/vitest'
import { useState } from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent, { type UserEvent } from '@testing-library/user-event'

import PedidoFilters, { type PedidoFiltersProps } from '../PedidoFilters'
import type { RolUsuario } from '../../../types'
import { authDataDeRol, ROLES_GALERIA } from '../../../../dev/gallery/fixtures/auth'
import { TRANSPORTISTAS_FIXTURE, USUARIOS_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo'

// =============================================================================
// FECHA FIJA
// =============================================================================

/**
 * 16/04/2026 02:00 UTC = 15/04/2026 23:00 en Argentina: la franja donde la fecha
 * UTC y la argentina no coinciden (mismo reloj que `PedidoFilters.test.tsx`), así
 * "Hoy" tiene que dar 2026-04-15 y "Mañana" 2026-04-16.
 */
const AHORA = new Date('2026-04-16T02:00:00Z')
const HOY = '2026-04-15'
const MANANA = '2026-04-16'

beforeEach(() => {
  // Sólo `Date`: si se falsearan los timers, userEvent se colgaría.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(AHORA)
})

afterEach(() => {
  vi.useRealTimers()
})

// =============================================================================
// FIXTURES Y MONTAJE POR ROL
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

const TRANSPORTISTA = TRANSPORTISTAS_FIXTURE[0]
const USUARIO = USUARIOS_FIXTURE[0]

/** Los siete filtros que cuenta el badge, todos puestos. */
const SIETE_FILTROS: Partial<Filtros> = {
  estado: 'pendiente',
  estadoPago: 'parcial',
  transportistaId: TRANSPORTISTA.id,
  usuarioId: USUARIO.id,
  conSalvedad: 'con_salvedad',
  fechaEntregaProgramada: HOY,
  verCancelados: true,
}

/** Los cinco que sólo un admin puede tocar desde la UI. */
const FILTROS_DE_ADMIN: Partial<Filtros> = {
  estadoPago: 'parcial',
  transportistaId: TRANSPORTISTA.id,
  usuarioId: USUARIO.id,
  conSalvedad: 'con_salvedad',
  fechaEntregaProgramada: HOY,
}

const ROLES: readonly RolUsuario[] = ROLES_GALERIA
const ROLES_NO_ADMIN: readonly RolUsuario[] = ROLES_GALERIA.filter(r => r !== 'admin')

interface OpcionesRender {
  filtros?: Partial<Filtros>
  busqueda?: string
}

/** Las props que `VistaPedidos` le arma a `PedidoFilters` según el rol. */
function propsDeRol(rol: RolUsuario, opciones: OpcionesRender = {}) {
  const { isAdmin } = authDataDeRol(rol)
  return {
    busqueda: opciones.busqueda ?? '',
    filtros: { ...FILTROS_BASE, ...opciones.filtros },
    transportistas: TRANSPORTISTAS_FIXTURE,
    usuarios: isAdmin ? USUARIOS_FIXTURE : [],
    isAdmin,
  }
}

function renderFilters(rol: RolUsuario, opciones: OpcionesRender = {}) {
  const onFiltrosChange = vi.fn()
  const onBusquedaChange = vi.fn()

  render(
    <PedidoFilters
      {...propsDeRol(rol, opciones)}
      onBusquedaChange={onBusquedaChange}
      onFiltrosChange={onFiltrosChange}
    />,
  )

  return { onFiltrosChange, onBusquedaChange }
}

/**
 * El único trigger del panel. Con el sheet abierto Radix esconde lo de atrás
 * con aria-hidden: para mirarlo en ese momento hay que pedirlo con `hidden`.
 */
function botonFiltros({ hidden = false }: { hidden?: boolean } = {}): HTMLElement {
  return screen.getByRole('button', { name: 'Abrir filtros avanzados', hidden })
}

/** Abre el panel (en jsdom, el bottom sheet) y devuelve el diálogo. */
async function abrirSheet(user: UserEvent): Promise<HTMLElement> {
  await user.click(botonFiltros())
  return screen.findByRole('dialog', { name: 'Filtros' })
}

/**
 * El `<select>` del panel que ofrece esa opción. Se los sigue identificando por
 * las opciones que ofrecen (así estaban escritos estos casos cuando los selects
 * del sheet no tenían nombre), siempre dentro del diálogo.
 */
function selectDelSheet(dialogo: HTMLElement, opcion: string): HTMLSelectElement {
  const select = within(dialogo)
    .getAllByRole('combobox')
    .find(s => within(s).queryByRole('option', { name: opcion }))
  if (!select) throw new Error(`Ningún combobox del sheet ofrece la opción "${opcion}"`)
  return select as HTMLSelectElement
}

/** Los `input[type=date]` dentro de un contenedor (no tienen rol ARIA). */
function inputsDeFecha(contenedor: HTMLElement): HTMLInputElement[] {
  return Array.from(contenedor.querySelectorAll<HTMLInputElement>('input[type="date"]'))
}

/**
 * Nombre accesible de cada elemento, para comparar inventarios enteros: el
 * `aria-label`, si no el `<label>` asociado (así se nombra la casilla) y si no
 * el texto (los botones).
 */
function nombres(elementos: HTMLElement[]): string[] {
  return elementos
    .map(el => el.getAttribute('aria-label') ?? (el as HTMLInputElement).labels?.[0]?.textContent ?? el.textContent ?? '')
    .sort()
}

/** Secciones del panel, por el texto de su encabezado. */
const SECCIONES_COMUNES = ['Estado del pedido', 'Fecha de carga', 'Otros']
const SECCIONES_ADMIN = ['Pago', 'Transportista', 'Cargado por', 'Entregas con salvedad', 'Entrega programada']

// =============================================================================
// (1) LA BARRA: BUSCADOR + UN SOLO TRIGGER; LOS CONTROLES, EN EL PANEL
// =============================================================================

describe.each(ROLES)('rol %s — la barra y los controles del panel', rol => {
  const esAdmin = rol === 'admin'

  // Invertido en WP-44: antes los selects de escritorio estaban todos inline,
  // sin trigger. Ahora la barra es el buscador, el control de entrega (sólo
  // admin, a un toque, como antes) y UN trigger; los selects aparecen al abrir
  // el panel, y no se pierde ninguno.
  it('con el panel cerrado la barra es buscador + trigger (+ entrega, admin); al abrirlo están los controles', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: /buscar pedidos por cliente, dirección o número de pedido/i })).toBeInTheDocument()
    expect(screen.queryByRole('combobox')).not.toBeInTheDocument()
    expect(screen.queryByRole('checkbox')).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: 'Abrir filtros avanzados' })).toHaveLength(1)
    // La entrega programada es de la fila, sólo para admin: se ve sin abrir nada.
    expect(screen.queryByRole('button', { name: 'Hoy' }) !== null).toBe(esAdmin)
    expect(screen.queryByRole('button', { name: 'Mañana' }) !== null).toBe(esAdmin)
    expect(screen.queryByLabelText('Fecha de entrega programada') !== null).toBe(esAdmin)

    await abrirSheet(user)
    expect(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })).toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: 'Incluir cancelados' })).toBeInTheDocument()
    expect(screen.getByLabelText('Desde')).toBeInTheDocument()
    expect(screen.getByLabelText('Hasta')).toBeInTheDocument()
  })

  it(`el inventario completo de la barra cerrada es el mismo para un ${esAdmin ? 'admin' : 'no-admin'}`, () => {
    renderFilters(rol)

    expect(screen.queryAllByRole('combobox')).toHaveLength(0)
    expect(screen.queryAllByRole('checkbox')).toHaveLength(0)
    expect(nombres(screen.getAllByRole('button'))).toEqual(
      esAdmin ? ['Abrir filtros avanzados', 'Hoy', 'Mañana'] : ['Abrir filtros avanzados'],
    )
    expect(screen.getAllByRole('textbox')).toHaveLength(1)
    // El admin tiene el input de fecha de la entrega programada; el resto ninguno.
    expect(inputsDeFecha(document.body)).toHaveLength(esAdmin ? 1 : 0)
  })

  it(`el inventario completo del panel abierto es el de un ${esAdmin ? 'admin' : 'no-admin'}`, async () => {
    const user = userEvent.setup()
    renderFilters(rol)
    const dialogo = await abrirSheet(user)

    expect(nombres(within(dialogo).getAllByRole('combobox'))).toEqual(
      esAdmin
        ? [
            'Filtrar por estado de pago',
            'Filtrar por estado del pedido',
            'Filtrar por salvedades en entrega',
            'Filtrar por transportista',
            'Filtrar por usuario que cargó el pedido',
          ]
        : ['Filtrar por estado del pedido'],
    )
    expect(nombres(within(dialogo).getAllByRole('checkbox'))).toEqual(['Incluir cancelados'])
    // Entrega programada (admin) + Desde y Hasta de la fecha de carga (todos).
    expect(inputsDeFecha(dialogo)).toHaveLength(esAdmin ? 3 : 2)
  })

  it('el buscador avisa cada tecla por onBusquedaChange y no toca los filtros', async () => {
    const user = userEvent.setup()
    const { onBusquedaChange, onFiltrosChange } = renderFilters(rol)

    await user.type(screen.getByRole('textbox', { name: /buscar pedidos/i }), 'K')

    expect(onBusquedaChange).toHaveBeenCalledTimes(1)
    expect(onBusquedaChange).toHaveBeenCalledWith('K')
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it.each([
    ['Pendientes', 'pendiente'],
    ['En preparación', 'en_preparacion'],
    ['En camino', 'asignado'],
    ['Entregados', 'entregado'],
    ['Cancelados', 'cancelado'],
  ])('elegir el estado "%s" emite sólo { estado: %s }', async (etiqueta, value) => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)
    await abrirSheet(user)

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i }), etiqueta)

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: value })
  })

  // La casilla es la del panel único, "Incluir cancelados"; "Ver cancelados" era
  // la copia de la fila de escritorio que el panel único eliminó.
  it('"Incluir cancelados" emite sólo { verCancelados: true } al marcarlo', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)
    await abrirSheet(user)

    await user.click(screen.getByRole('checkbox', { name: 'Incluir cancelados' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: true })
  })

  // Invertido en WP-44: antes "Fechas" (dos botones) sólo pedía abrir el modal
  // de rango. Ahora el único trigger abre el panel, y abrirlo no emite nada.
  it('abrir el panel no emite ningún filtro', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)

    await abrirSheet(user)

    expect(onFiltrosChange).not.toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Filtrar pedidos por rango de fechas', hidden: true })).not.toBeInTheDocument()
  })
})

// =============================================================================
// (1b + 2) LOS FILTROS SECUNDARIOS: EN EL PANEL SÓLO PARA ADMIN, Y QUÉ EMITE CADA UNO
// =============================================================================

describe('los filtros secundarios (pago, transportista, usuario, salvedad, entrega)', () => {
  describe.each(ROLES_NO_ADMIN)('rol %s', rol => {
    it('no están en el panel: ni selects, ni segmented de entrega, ni input de entrega', async () => {
      const user = userEvent.setup()
      renderFilters(rol)
      await abrirSheet(user)

      for (const nombre of [
        /filtrar por estado de pago/i,
        /filtrar por transportista/i,
        /filtrar por usuario que cargó/i,
        /filtrar por salvedades en entrega/i,
      ]) {
        expect(screen.queryByRole('combobox', { name: nombre })).not.toBeInTheDocument()
      }
      expect(screen.queryByText('Entrega programada')).not.toBeInTheDocument()
      expect(screen.queryByRole('button', { name: 'Hoy' })).not.toBeInTheDocument()
      expect(screen.queryByRole('button', { name: 'Mañana' })).not.toBeInTheDocument()
      expect(screen.queryByLabelText('Fecha de entrega programada')).not.toBeInTheDocument()
    })

    it('ni siquiera tiene opciones de usuarios: el container no se las carga', async () => {
      const user = userEvent.setup()
      renderFilters(rol)
      await abrirSheet(user)

      expect(screen.queryByRole('option', { name: USUARIO.nombre })).not.toBeInTheDocument()
    })

    it('aunque el estado los traiga puestos, los controles siguen sin aparecer', async () => {
      const user = userEvent.setup()
      renderFilters(rol, { filtros: FILTROS_DE_ADMIN })
      await abrirSheet(user)

      expect(screen.getAllByRole('combobox')).toHaveLength(1)
      expect(screen.queryByText('Entrega programada')).not.toBeInTheDocument()
      // Con la entrega puesta, la X de "Limpiar filtro de entrega" es parte de esa sección.
      expect(screen.queryByRole('button', { name: 'Limpiar filtro de entrega' })).not.toBeInTheDocument()
    })
  })

  describe('rol admin', () => {
    it('están en el panel: los cuatro selects, el segmented Hoy/Mañana y el input de entrega', async () => {
      const user = userEvent.setup()
      renderFilters('admin')
      const dialogo = await abrirSheet(user)

      for (const nombre of [
        /filtrar por estado de pago/i,
        /filtrar por transportista/i,
        /filtrar por usuario que cargó/i,
        /filtrar por salvedades en entrega/i,
      ]) {
        expect(screen.getByRole('combobox', { name: nombre })).toBeInTheDocument()
      }
      // El sheet del celular trae también la sección de entrega; la fila de atrás
      // queda con aria-hidden mientras está abierto, así que se pide dentro del diálogo.
      expect(screen.getByText('Entrega programada')).toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Hoy' })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Mañana' })).toBeInTheDocument()
      expect(within(dialogo).getByLabelText('Fecha de entrega programada')).toBeInTheDocument()
    })

    it('pago ofrece cuatro valores más "Todos": pendiente, parcial, pagado e impago', async () => {
      const user = userEvent.setup()
      renderFilters('admin')
      await abrirSheet(user)
      const pago = screen.getByRole('combobox', { name: /filtrar por estado de pago/i })

      for (const [etiqueta, value] of [
        ['Todos los pagos', 'todos'],
        ['Pago pendiente', 'pendiente'],
        ['Pago parcial', 'parcial'],
        ['Pagado', 'pagado'],
        ['Impagos (sin pagar o parcial)', 'impago'],
      ]) {
        expect(within(pago).getByRole('option', { name: etiqueta })).toHaveValue(value)
      }
      expect(within(pago).getAllByRole('option')).toHaveLength(5)
    })

    it.each([
      ['Pago pendiente', 'pendiente'],
      ['Pago parcial', 'parcial'],
      ['Pagado', 'pagado'],
      ['Impagos (sin pagar o parcial)', 'impago'],
    ])('pago "%s" emite sólo { estadoPago: %s }', async (etiqueta, value) => {
      const user = userEvent.setup()
      const { onFiltrosChange } = renderFilters('admin')
      await abrirSheet(user)

      await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por estado de pago/i }), etiqueta)

      expect(onFiltrosChange).toHaveBeenCalledTimes(1)
      expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: value })
    })

    it('el transportista ofrece "Todos", "Sin asignar" y los transportistas recibidos', async () => {
      const user = userEvent.setup()
      renderFilters('admin')
      await abrirSheet(user)
      const select = screen.getByRole('combobox', { name: /filtrar por transportista/i })

      expect(within(select).getAllByRole('option').map(o => o.textContent)).toEqual([
        'Todos los transportistas',
        'Sin asignar',
        ...TRANSPORTISTAS_FIXTURE.map(t => t.nombre),
      ])
    })

    it('transportista emite sólo { transportistaId } con "sin_asignar" o el id', async () => {
      const user = userEvent.setup()
      const { onFiltrosChange } = renderFilters('admin')
      await abrirSheet(user)
      const select = screen.getByRole('combobox', { name: /filtrar por transportista/i })

      await user.selectOptions(select, 'Sin asignar')
      await user.selectOptions(select, TRANSPORTISTA.nombre)

      expect(onFiltrosChange).toHaveBeenNthCalledWith(1, { transportistaId: 'sin_asignar' })
      expect(onFiltrosChange).toHaveBeenNthCalledWith(2, { transportistaId: TRANSPORTISTA.id })
      expect(onFiltrosChange).toHaveBeenCalledTimes(2)
    })

    it('usuario emite sólo { usuarioId } con el id del que cargó', async () => {
      const user = userEvent.setup()
      const { onFiltrosChange } = renderFilters('admin')
      await abrirSheet(user)

      await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por usuario que cargó/i }), USUARIO.nombre)

      expect(onFiltrosChange).toHaveBeenCalledTimes(1)
      expect(onFiltrosChange).toHaveBeenCalledWith({ usuarioId: USUARIO.id })
    })

    it.each([
      ['Con salvedad', 'con_salvedad'],
      ['Sin salvedad', 'sin_salvedad'],
    ])('salvedad "%s" emite sólo { conSalvedad: %s }', async (etiqueta, value) => {
      const user = userEvent.setup()
      const { onFiltrosChange } = renderFilters('admin')
      await abrirSheet(user)

      await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por salvedades en entrega/i }), etiqueta)

      expect(onFiltrosChange).toHaveBeenCalledTimes(1)
      expect(onFiltrosChange).toHaveBeenCalledWith({ conSalvedad: value })
    })

    it('entrega: Hoy y Mañana emiten la fecha argentina; tocar el activo la apaga', async () => {
      const user = userEvent.setup()
      const { onFiltrosChange } = renderFilters('admin')
      await abrirSheet(user)

      await user.click(screen.getByRole('button', { name: 'Hoy' }))
      await user.click(screen.getByRole('button', { name: 'Mañana' }))

      expect(onFiltrosChange).toHaveBeenNthCalledWith(1, { fechaEntregaProgramada: HOY })
      expect(onFiltrosChange).toHaveBeenNthCalledWith(2, { fechaEntregaProgramada: MANANA })
    })

    it('entrega: con una fecha suelta el input la muestra y la X la limpia con null', async () => {
      const user = userEvent.setup()
      const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: '2026-05-20' } })
      const dialogo = await abrirSheet(user)

      expect(within(dialogo).getByLabelText('Fecha de entrega programada')).toHaveValue('2026-05-20')
      await user.click(screen.getByRole('button', { name: 'Limpiar filtro de entrega' }))

      expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
    })

    // La fila de la barra (sin abrir el panel) emite lo mismo que la sección del sheet.
    it('entrega, en la fila: Hoy, Mañana, fecha suelta y su X emiten lo mismo sin abrir el panel', async () => {
      const user = userEvent.setup()
      const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: '2026-05-20' } })

      await user.click(screen.getByRole('button', { name: 'Hoy' }))
      await user.click(screen.getByRole('button', { name: 'Mañana' }))
      fireEvent.change(screen.getByLabelText('Fecha de entrega programada'), { target: { value: '2026-06-01' } })
      await user.click(screen.getByRole('button', { name: 'Limpiar filtro de entrega' }))

      expect(onFiltrosChange.mock.calls).toEqual([
        [{ fechaEntregaProgramada: HOY }],
        [{ fechaEntregaProgramada: MANANA }],
        [{ fechaEntregaProgramada: '2026-06-01' }],
        [{ fechaEntregaProgramada: null }],
      ])
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })
  })
})

// =============================================================================
// (1c) FILTROS ACTIVOS: EL CONTROL MUESTRA EL VALOR VIGENTE Y HAY UN CHIP POR FILTRO
// =============================================================================

describe('filtros activos: el control los muestra y cada uno tiene su chip', () => {
  it('cada control del admin muestra el valor vigente', async () => {
    const user = userEvent.setup()
    renderFilters('admin', { filtros: SIETE_FILTROS })
    const dialogo = await abrirSheet(user)

    expect(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })).toHaveValue('pendiente')
    expect(screen.getByRole('combobox', { name: /filtrar por estado de pago/i })).toHaveValue('parcial')
    expect(screen.getByRole('combobox', { name: /filtrar por transportista/i })).toHaveValue(TRANSPORTISTA.id)
    expect(screen.getByRole('combobox', { name: /filtrar por usuario que cargó/i })).toHaveValue(USUARIO.id)
    expect(screen.getByRole('combobox', { name: /filtrar por salvedades en entrega/i })).toHaveValue('con_salvedad')
    expect(screen.getByRole('checkbox', { name: 'Incluir cancelados' })).toBeChecked()
    expect(within(dialogo).getByLabelText('Fecha de entrega programada')).toHaveValue(HOY)
  })

  // Invertido en WP-44 (#769): antes no había chips; un filtro sólo se quitaba
  // volviendo a su select. Ahora cada filtro activo tiene su chip con su X.
  it('hay un chip removible para estado, pago, transportista, usuario, salvedad, entrega y cancelados', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: SIETE_FILTROS })

    const fila = screen.getByRole('status', { name: 'Filtros activos' })
    expect(nombres(within(fila).getAllByRole('button'))).toEqual([
      'Quitar filtro Cancelados',
      'Quitar filtro Cargado por',
      'Quitar filtro Entrega',
      'Quitar filtro Estado',
      'Quitar filtro Pago',
      'Quitar filtro Salvedad',
      'Quitar filtro Transportista',
    ])
    expect(fila).toHaveTextContent(`Transportista: ${TRANSPORTISTA.nombre}`)
    expect(fila).toHaveTextContent(`Cargado por: ${USUARIO.nombre}`)

    for (const boton of within(fila).getAllByRole('button')) {
      await user.click(boton)
    }
    // Cada X emite el mismo parche que su control al volver a "Todos".
    expect(onFiltrosChange.mock.calls.map(([p]) => p)).toEqual([
      { estado: 'todos' },
      { estadoPago: 'todos' },
      { transportistaId: 'todos' },
      { usuarioId: 'todos' },
      { conSalvedad: 'todos' },
      { fechaEntregaProgramada: null },
      { verCancelados: false },
    ])
  })
})

// =============================================================================
// (1d) UN SOLO PANEL: NO HAY COPIAS DE LOS CONTROLES
// =============================================================================

describe.each(ROLES)('rol %s — el panel (bottom sheet en celular)', rol => {
  const esAdmin = rol === 'admin'

  // Invertido en WP-44: antes, con el sheet cerrado, los selects del admin
  // estaban UNA vez en el árbol (los de la fila de escritorio). Ahora cerrado
  // no hay ninguno, y abierto están una sola vez.
  it('cerrado no monta ningún control; abierto, cada select está UNA vez', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Listo' })).not.toBeInTheDocument()
    expect(screen.queryByRole('checkbox', { name: 'Incluir cancelados' })).not.toBeInTheDocument()
    expect(screen.queryAllByRole('combobox', { name: /filtrar por estado de pago/i })).toHaveLength(0)

    await abrirSheet(user)
    expect(screen.queryAllByRole('combobox', { name: /filtrar por estado de pago/i, hidden: true })).toHaveLength(esAdmin ? 1 : 0)
  })

  it('las secciones visibles: estado, fecha de carga y "Otros" para todos, las cinco de admin sólo para admin', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    const dialogo = await abrirSheet(user)

    for (const seccion of SECCIONES_COMUNES) {
      expect(within(dialogo).getByText(seccion)).toBeInTheDocument()
    }
    for (const seccion of SECCIONES_ADMIN) {
      if (esAdmin) expect(within(dialogo).getByText(seccion)).toBeInTheDocument()
      else expect(within(dialogo).queryByText(seccion)).not.toBeInTheDocument()
    }
  })

  it('el inventario del sheet: selects, botones, casilla e inputs de fecha', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    const dialogo = await abrirSheet(user)

    expect(within(dialogo).getAllByRole('combobox')).toHaveLength(esAdmin ? 5 : 1)
    expect(nombres(within(dialogo).getAllByRole('button'))).toEqual(
      esAdmin
        ? ['Cerrar', 'Hoy', 'Limpiar todo', 'Listo', 'Mañana']
        : ['Cerrar', 'Limpiar todo', 'Listo'],
    )
    expect(nombres(within(dialogo).getAllByRole('checkbox'))).toEqual(['Incluir cancelados'])
    expect(inputsDeFecha(dialogo)).toHaveLength(esAdmin ? 3 : 2)
  })

  // Invertido en WP-44: antes, con el sheet abierto, la fila de escritorio
  // seguía montada detrás y había DOS copias de cada control. Ahora hay una.
  it('con el sheet abierto no hay otra copia de los controles detrás', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    await abrirSheet(user)

    expect(screen.getAllByRole('combobox', { hidden: true })).toHaveLength(esAdmin ? 5 : 1)
    expect(screen.getAllByRole('checkbox', { hidden: true })).toHaveLength(1)
    expect(screen.queryByRole('checkbox', { name: 'Ver cancelados', hidden: true })).not.toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: 'Incluir cancelados' })).toBeInTheDocument()
  })

  it('el estado emite en vivo, sin Aplicar, sólo { estado }', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)
    const dialogo = await abrirSheet(user)

    await user.selectOptions(selectDelSheet(dialogo, 'Pendientes'), 'Pendientes')

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'pendiente' })
    expect(screen.queryByRole('button', { name: /aplicar/i })).not.toBeInTheDocument()
  })

  it('el estado del sheet ofrece los mismos seis values que el select de escritorio', async () => {
    const user = userEvent.setup()
    renderFilters(rol)
    const dialogo = await abrirSheet(user)

    const select = selectDelSheet(dialogo, 'En camino')
    expect(within(select).getAllByRole('option').map(o => [o.textContent, (o as HTMLOptionElement).value])).toEqual([
      ['Todos los estados', 'todos'],
      ['Pendientes', 'pendiente'],
      ['En preparación', 'en_preparacion'],
      ['En camino', 'asignado'],
      ['Entregados', 'entregado'],
      ['Cancelados', 'cancelado'],
    ])
  })

  it('"Incluir cancelados" emite sólo { verCancelados }', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('checkbox'))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: true })
  })

  it('"Listo" cierra sin emitir y devuelve el sheet a desmontado', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Listo' }))

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  // Invertido en WP-44: antes las fechas NO vivían en el sheet (eran un modal
  // aparte, con su botón "Fechas"). Ahora son la sección "Fecha de carga".
  it('las fechas de carga viven en el sheet: Desde y Hasta, sin un botón "Fechas" aparte', async () => {
    const user = userEvent.setup()
    renderFilters(rol)
    const dialogo = await abrirSheet(user)

    expect(within(dialogo).queryByRole('button', { name: /rango de fechas/i })).not.toBeInTheDocument()
    expect(within(dialogo).getByText('Desde')).toBeInTheDocument()
    expect(within(dialogo).getByText('Hasta')).toBeInTheDocument()
  })
})

describe('bottom sheet — controles de admin: qué emite cada uno', () => {
  it.each([
    ['Pago parcial', { estadoPago: 'parcial' }],
    ['Impagos (sin pagar o parcial)', { estadoPago: 'impago' }],
    ['Sin asignar', { transportistaId: 'sin_asignar' }],
    [TRANSPORTISTA.nombre, { transportistaId: TRANSPORTISTA.id }],
    [USUARIO.nombre, { usuarioId: USUARIO.id }],
    ['Con salvedad', { conSalvedad: 'con_salvedad' }],
    ['Sin salvedad', { conSalvedad: 'sin_salvedad' }],
  ])('elegir "%s" emite sólo %o', async (opcion, parche) => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin')
    const dialogo = await abrirSheet(user)

    await user.selectOptions(selectDelSheet(dialogo, opcion), opcion)

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith(parche)
  })

  it('entrega programada: Hoy, Mañana, fecha suelta y su X', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: '2026-05-20' } })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Hoy' }))
    await user.click(within(dialogo).getByRole('button', { name: 'Mañana' }))
    expect(inputsDeFecha(dialogo)[0]).toHaveValue('2026-05-20')
    await user.click(within(dialogo).getByRole('button', { name: 'Limpiar filtro de entrega' }))

    expect(onFiltrosChange.mock.calls).toEqual([
      [{ fechaEntregaProgramada: HOY }],
      [{ fechaEntregaProgramada: MANANA }],
      [{ fechaEntregaProgramada: null }],
    ])
  })

  it('"Limpiar todo" emite UN payload con los siete filtros y no toca las fechas ni la búsqueda', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onBusquedaChange } = renderFilters('admin', {
      filtros: { ...SIETE_FILTROS, fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' },
      busqueda: 'kiosco',
    })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Limpiar todo' }))

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
    expect(onBusquedaChange).not.toHaveBeenCalled()
  })
})

// =============================================================================
// (3) LAS FECHAS DE CARGA: UNA SECCIÓN DEL PANEL, NO UN DIÁLOGO APARTE
// =============================================================================

// Invertido en WP-44: hasta acá `ModalFiltroFecha` era un Dialog centrado aparte
// ("Filtrar por Fecha"), con su estado local y su "Aplicar", que el container
// montaba con `onModalFiltroFecha`. Ahora el rango es la sección "Fecha de
// carga" del mismo panel, emite en vivo por `onFiltrosChange` y el modal ya no
// existe. Los casos de comportamiento del modal se mudaron a
// `ModalFiltrosPedidos.test.tsx`.
describe.each(ROLES)('rol %s — las fechas de carga son parte del panel', rol => {
  it('abrir el panel no abre otro diálogo: hay uno solo, "Filtros"', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    await abrirSheet(user)

    expect(screen.queryByRole('dialog', { name: /filtrar por fecha/i })).not.toBeInTheDocument()
    expect(screen.getAllByRole('dialog')).toHaveLength(1)
    expect(screen.getByRole('dialog', { name: 'Filtros' })).toBeInTheDocument()
  })

  it('tiene Desde/Hasta y NO tiene "Aplicar": la fecha también es en vivo', async () => {
    const user = userEvent.setup()
    renderFilters(rol, { filtros: { fechaDesde: '2026-04-01' } })
    const dialogo = await abrirSheet(user)

    expect(within(dialogo).getByText('Desde')).toBeInTheDocument()
    expect(within(dialogo).getByText('Hasta')).toBeInTheDocument()
    expect(within(dialogo).getByRole('button', { name: 'Limpiar fechas de carga' })).toBeInTheDocument()
    expect(within(dialogo).queryByRole('button', { name: /aplicar/i })).not.toBeInTheDocument()
  })

  it('escribir el rango emite { fechaDesde, fechaHasta } por onFiltrosChange, sin cerrar', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)
    const dialogo = await abrirSheet(user)

    await user.type(within(dialogo).getByLabelText('Desde'), '2026-05-01')
    await user.type(within(dialogo).getByLabelText('Hasta'), '2026-05-31')

    expect(onFiltrosChange).toHaveBeenLastCalledWith({ fechaDesde: '2026-05-01', fechaHasta: '2026-05-31' })
    expect(screen.getByRole('dialog', { name: 'Filtros' })).toBeInTheDocument()
  })

  it('se abre precargado con el rango que la barra ya tiene', async () => {
    const user = userEvent.setup()
    renderFilters(rol, { filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })
    const dialogo = await abrirSheet(user)

    expect(within(dialogo).getByLabelText('Desde')).toHaveValue('2026-04-01')
    expect(within(dialogo).getByLabelText('Hasta')).toHaveValue('2026-04-15')
  })
})

// =============================================================================
// (4) CONTADOR DEL TRIGGER POR ROL
// =============================================================================

describe.each(ROLES)('rol %s — contador del botón "Filtros"', rol => {
  const esAdmin = rol === 'admin'

  it('sin filtros no muestra número y el sheet dice "Refiná tu búsqueda"', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
    const dialogo = await abrirSheet(user)
    expect(within(dialogo).getByText('Refiná tu búsqueda')).toBeInTheDocument()
    expect(within(dialogo).getByRole('button', { name: 'Limpiar todo' })).toBeDisabled()
  })

  // El tile "Impagos" de PedidoStats pone `estadoPago: 'impago'` para CUALQUIER
  // rol (#715). Un no-admin no tiene el select de pago: el badge, el chip y
  // "Limpiar todo" son, con el tile presionado, la forma de ver y quitar ese filtro.
  it('con estadoPago "impago" del tile cuenta 1 y "Limpiar todo" queda habilitado', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol, { filtros: { estadoPago: 'impago' } })

    expect(within(botonFiltros()).getByText('1')).toBeInTheDocument()
    const dialogo = await abrirSheet(user)
    expect(within(dialogo).getByText('1 filtro activo')).toBeInTheDocument()
    const limpiar = within(dialogo).getByRole('button', { name: 'Limpiar todo' })
    expect(limpiar).toBeEnabled()

    await user.click(limpiar)

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith(expect.objectContaining({ estadoPago: 'todos' }))
  })

  it('el estado y "cancelados", que todos los roles ven, suman 2', () => {
    renderFilters(rol, { filtros: { estado: 'entregado', verCancelados: true } })

    expect(within(botonFiltros()).getByText('2')).toBeInTheDocument()
  })

  it('las fechas y la búsqueda nunca cuentan', () => {
    renderFilters(rol, { busqueda: 'kiosco', filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
  })

  // Invertido en WP-44 (cierra #733): el contador cuenta sólo lo que el rol
  // puede ver y tocar. Antes un no-admin con estos cinco puestos veía 5 y el
  // sheet anunciaba "5 filtros activos" sin un solo control que los explicara.
  it(esAdmin
    ? 'los cinco filtros de admin suman 5 (los ve y los puede tocar)'
    : 'los cinco filtros de admin NO suman: el rol no tiene ni un control para ellos', async () => {
    const user = userEvent.setup()
    renderFilters(rol, { filtros: FILTROS_DE_ADMIN })

    if (esAdmin) {
      expect(within(botonFiltros()).getByText('5')).toBeInTheDocument()
    } else {
      expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
    }
    const dialogo = await abrirSheet(user)
    expect(within(dialogo).getByText(esAdmin ? '5 filtros activos' : 'Refiná tu búsqueda')).toBeInTheDocument()

    if (!esAdmin) {
      for (const seccion of SECCIONES_ADMIN) {
        expect(within(dialogo).queryByText(seccion)).not.toBeInTheDocument()
      }
      expect(within(dialogo).getAllByRole('combobox')).toHaveLength(1)
    }
  })

  it(esAdmin
    ? 'los siete filtros suman 7'
    : 'con los siete puestos suma 2: el estado y cancelados, los que ve', () => {
    renderFilters(rol, { filtros: SIETE_FILTROS })

    expect(within(botonFiltros()).getByText(esAdmin ? '7' : '2')).toBeInTheDocument()
  })

  it('"todos" en cada select y la entrega vacía no cuentan', () => {
    renderFilters(rol, { filtros: { estadoPago: 'todos', transportistaId: 'todos', usuarioId: 'todos', conSalvedad: 'todos', fechaEntregaProgramada: null } })

    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
  })
})

// =============================================================================
// (5) CHIP DE FECHAS
// =============================================================================

describe.each(ROLES)('rol %s — chip de fechas', rol => {
  it('sin rango no hay chip', () => {
    renderFilters(rol)

    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Limpiar filtro de fechas' })).not.toBeInTheDocument()
  })

  it('con rango aparece UNA vez, con las dos puntas', () => {
    renderFilters(rol, { filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    expect(screen.getAllByRole('status')).toHaveLength(1)
    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: 2026-04-01 – 2026-04-15')
  })

  it.each([
    ['sólo desde', { fechaDesde: '2026-04-01', fechaHasta: null }, 'Filtrado: 2026-04-01 – …'],
    ['sólo hasta', { fechaDesde: null, fechaHasta: '2026-04-15' }, 'Filtrado: … – 2026-04-15'],
  ])('con %s deja la otra punta en puntos suspensivos', (_nombre, filtros, texto) => {
    renderFilters(rol, { filtros })

    expect(screen.getByRole('status')).toHaveTextContent(texto)
  })

  it('su X limpia las dos puntas de una sola vez, sin tocar otros filtros', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol, {
      filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15', estado: 'pendiente' },
    })

    await user.click(screen.getByRole('button', { name: 'Limpiar filtro de fechas' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaDesde: null, fechaHasta: null })
  })

  // Ajustado en WP-44: el botón "Fechas" (dos, uno por layout) ya no existe; el
  // rango se cambia desde el único trigger, que sigue sin contarlo.
  it('con rango activo, el trigger sigue siendo uno y el rango no suma al contador', () => {
    renderFilters(rol, { filtros: { fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' } })

    expect(screen.getAllByRole('button', { name: 'Abrir filtros avanzados' })).toHaveLength(1)
    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
  })
})

// =============================================================================
// (6) DATOS VISIBLES Y VALORES VIGENTES, POR ROL
// =============================================================================

describe.each(ROLES)('rol %s — lo que la barra y el panel muestran y emiten además de lo anterior', rol => {
  it('el buscador muestra lo que trae `busqueda` y su ayuda visible', () => {
    renderFilters(rol, { busqueda: 'kiosco' })

    expect(screen.getByRole('textbox', { name: /buscar pedidos/i })).toHaveValue('kiosco')
    expect(screen.getByPlaceholderText('Buscar por cliente, dirección o ID…')).toBeInTheDocument()
  })

  it('el estado ofrece "Todos" y los cinco values, con sus etiquetas', async () => {
    const user = userEvent.setup()
    renderFilters(rol)
    await abrirSheet(user)
    const select = screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })

    expect(within(select).getAllByRole('option').map(o => [o.textContent, (o as HTMLOptionElement).value])).toEqual([
      ['Todos los estados', 'todos'],
      ['Pendientes', 'pendiente'],
      ['En preparación', 'en_preparacion'],
      ['En camino', 'asignado'],
      ['Entregados', 'entregado'],
      ['Cancelados', 'cancelado'],
    ])
  })

  it('con un estado puesto el select lo muestra elegido, por su etiqueta', async () => {
    const user = userEvent.setup()
    renderFilters(rol, { filtros: { estado: 'asignado' } })
    await abrirSheet(user)

    expect(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })).toHaveDisplayValue('En camino')
  })

  it('volver a "Todos los estados" emite { estado: "todos" }: así se quita el filtro de estado', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol, { filtros: { estado: 'pendiente' } })
    await abrirSheet(user)

    await user.selectOptions(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i }), 'Todos los estados')

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'todos' })
  })

  it('con cancelados puesto la casilla está marcada y desmarcarla emite { verCancelados: false }', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol, { filtros: { verCancelados: true } })
    await abrirSheet(user)
    const casilla = screen.getByRole('checkbox', { name: 'Incluir cancelados' })

    expect(casilla).toBeChecked()
    await user.click(casilla)

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: false })
  })

  // Invertido en WP-44: antes "Fechas" era el texto de dos botones (uno por
  // layout). Ahora es una sola sección del panel, "Fecha de carga".
  it('las fechas se llaman "Fecha de carga" y están UNA vez, dentro del panel', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    expect(screen.queryByText('Fechas')).not.toBeInTheDocument()
    await abrirSheet(user)
    expect(screen.getAllByText('Fecha de carga')).toHaveLength(1)
  })

  it('con los props opcionales ausentes (sólo `estado`) no rompe y no cuenta nada', async () => {
    const user = userEvent.setup()
    render(
      <PedidoFilters
        {...propsDeRol(rol)}
        filtros={{ estado: 'todos' }}
        onBusquedaChange={vi.fn()}
        onFiltrosChange={vi.fn()}
      />,
    )

    expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
    await abrirSheet(user)
    expect(screen.getByRole('combobox', { name: /filtrar por estado del pedido/i })).toHaveValue('todos')
    expect(screen.getByRole('checkbox', { name: 'Incluir cancelados' })).not.toBeChecked()
  })
})

describe('rol admin — los filtros secundarios: opciones, valores y salidas que faltaban', () => {
  it('el usuario ofrece "Todos los usuarios" y los usuarios recibidos, con su id como value', async () => {
    const user = userEvent.setup()
    renderFilters('admin')
    await abrirSheet(user)
    const select = screen.getByRole('combobox', { name: /filtrar por usuario que cargó/i })

    expect(within(select).getAllByRole('option').map(o => [o.textContent, (o as HTMLOptionElement).value])).toEqual([
      ['Todos los usuarios', 'todos'],
      ...USUARIOS_FIXTURE.map(u => [u.nombre, u.id]),
    ])
  })

  it('la salvedad ofrece "Todas las entregas", "Con salvedad" y "Sin salvedad"', async () => {
    const user = userEvent.setup()
    renderFilters('admin')
    await abrirSheet(user)
    const select = screen.getByRole('combobox', { name: /filtrar por salvedades en entrega/i })

    expect(within(select).getAllByRole('option').map(o => [o.textContent, (o as HTMLOptionElement).value])).toEqual([
      ['Todas las entregas', 'todos'],
      ['Con salvedad', 'con_salvedad'],
      ['Sin salvedad', 'sin_salvedad'],
    ])
  })

  it('sin transportistas ni usuarios recibidos, los selects sólo ofrecen lo fijo', async () => {
    const user = userEvent.setup()
    render(
      <PedidoFilters
        {...propsDeRol('admin')}
        transportistas={[]}
        usuarios={[]}
        onBusquedaChange={vi.fn()}
        onFiltrosChange={vi.fn()}
      />,
    )
    await abrirSheet(user)

    expect(
      within(screen.getByRole('combobox', { name: /filtrar por transportista/i })).getAllByRole('option').map(o => o.textContent),
    ).toEqual(['Todos los transportistas', 'Sin asignar'])
    expect(
      within(screen.getByRole('combobox', { name: /filtrar por usuario que cargó/i })).getAllByRole('option').map(o => o.textContent),
    ).toEqual(['Todos los usuarios'])
  })

  it.each([
    ['estado de pago', 'Todos los pagos', { estadoPago: 'todos' }],
    ['transportista', 'Todos los transportistas', { transportistaId: 'todos' }],
    ['usuario que cargó', 'Todos los usuarios', { usuarioId: 'todos' }],
    ['salvedades en entrega', 'Todas las entregas', { conSalvedad: 'todos' }],
  ])('volver a "Todos" en el select de %s (opción "%s") emite %o: así se quita', async (nombre, opcion, parche) => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: SIETE_FILTROS })
    await abrirSheet(user)

    await user.selectOptions(screen.getByRole('combobox', { name: new RegExp(`filtrar por ${nombre}`, 'i') }), opcion)

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith(parche)
  })

  it('entrega: estando en Hoy, tocar "Hoy" la apaga con null', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: HOY } })
    await abrirSheet(user)

    await user.click(screen.getByRole('button', { name: 'Hoy' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('entrega: estando en Hoy, "Mañana" cambia a la fecha de mañana (no la apaga)', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: HOY } })
    await abrirSheet(user)

    await user.click(screen.getByRole('button', { name: 'Mañana' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: MANANA })
  })

  it('entrega: estando en Mañana, tocar "Mañana" la apaga con null', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: MANANA } })
    await abrirSheet(user)

    await user.click(screen.getByRole('button', { name: 'Mañana' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('entrega: escribir una fecha suelta la emite tal cual', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin')
    const dialogo = await abrirSheet(user)

    await user.type(within(dialogo).getByLabelText('Fecha de entrega programada'), '2026-05-20')

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: '2026-05-20' })
  })

  it('entrega: borrar el input de una fecha puesta emite null, no cadena vacía', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: '2026-05-20' } })
    const dialogo = await abrirSheet(user)

    await user.clear(within(dialogo).getByLabelText('Fecha de entrega programada'))

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
    expect(onFiltrosChange).not.toHaveBeenCalledWith({ fechaEntregaProgramada: '' })
  })

  it('entrega: sin fecha puesta no hay X de "Limpiar filtro de entrega"', async () => {
    const user = userEvent.setup()
    renderFilters('admin')
    await abrirSheet(user)

    expect(screen.queryByRole('button', { name: 'Limpiar filtro de entrega' })).not.toBeInTheDocument()
  })
})

// =============================================================================
// (7) BOTTOM SHEET: VALORES VIGENTES, OPCIONES Y SALIDAS QUE FALTABAN
// =============================================================================

describe('bottom sheet — admin: valores vigentes y opciones', () => {
  it('cada control muestra el filtro vigente', async () => {
    const user = userEvent.setup()
    renderFilters('admin', { filtros: SIETE_FILTROS })
    const dialogo = await abrirSheet(user)

    expect(selectDelSheet(dialogo, 'En camino')).toHaveValue('pendiente')
    expect(selectDelSheet(dialogo, 'Pago parcial')).toHaveValue('parcial')
    expect(selectDelSheet(dialogo, 'Sin asignar')).toHaveValue(TRANSPORTISTA.id)
    expect(selectDelSheet(dialogo, USUARIO.nombre)).toHaveValue(USUARIO.id)
    expect(selectDelSheet(dialogo, 'Con salvedad')).toHaveValue('con_salvedad')
    expect(within(dialogo).getByRole('checkbox', { name: 'Incluir cancelados' })).toBeChecked()
    expect(inputsDeFecha(dialogo)[0]).toHaveValue(HOY)
  })

  it('las opciones de pago, transportista, usuario y salvedad son las de la barra', async () => {
    const user = userEvent.setup()
    renderFilters('admin')
    const dialogo = await abrirSheet(user)
    const opciones = (select: HTMLSelectElement) =>
      within(select).getAllByRole('option').map(o => [o.textContent, (o as HTMLOptionElement).value])

    expect(opciones(selectDelSheet(dialogo, 'Pago parcial'))).toEqual([
      ['Todos los pagos', 'todos'],
      ['Pago pendiente', 'pendiente'],
      ['Pago parcial', 'parcial'],
      ['Pagado', 'pagado'],
      ['Impagos (sin pagar o parcial)', 'impago'],
    ])
    expect(opciones(selectDelSheet(dialogo, 'Sin asignar'))).toEqual([
      ['Todos los transportistas', 'todos'],
      ['Sin asignar', 'sin_asignar'],
      ...TRANSPORTISTAS_FIXTURE.map(t => [t.nombre, t.id]),
    ])
    expect(opciones(selectDelSheet(dialogo, USUARIO.nombre))).toEqual([
      ['Todos los usuarios', 'todos'],
      ...USUARIOS_FIXTURE.map(u => [u.nombre, u.id]),
    ])
    expect(opciones(selectDelSheet(dialogo, 'Con salvedad'))).toEqual([
      ['Todas las entregas', 'todos'],
      ['Con salvedad', 'con_salvedad'],
      ['Sin salvedad', 'sin_salvedad'],
    ])
  })

  it.each([
    ['Todos los pagos', { estadoPago: 'todos' }],
    ['Todos los transportistas', { transportistaId: 'todos' }],
    ['Todos los usuarios', { usuarioId: 'todos' }],
    ['Todas las entregas', { conSalvedad: 'todos' }],
  ])('volver a "%s" emite %o: así se quita', async (opcion, parche) => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: SIETE_FILTROS })
    const dialogo = await abrirSheet(user)

    await user.selectOptions(selectDelSheet(dialogo, opcion), opcion)

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith(parche)
  })

  it('entrega: estando en Hoy, tocar "Hoy" la apaga con null', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: HOY } })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Hoy' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('entrega: estando en Mañana, tocar "Mañana" la apaga con null', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: MANANA } })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Mañana' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
  })

  it('entrega: estando en Hoy, "Mañana" cambia a la fecha de mañana (no la apaga)', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: HOY } })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Mañana' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: MANANA })
  })

  it('entrega: una fecha suelta se emite tal cual', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin')
    const dialogo = await abrirSheet(user)

    await user.type(inputsDeFecha(dialogo)[0], '2026-05-20')

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: '2026-05-20' })
  })

  it('entrega: borrar el input de una fecha puesta emite null, no cadena vacía', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters('admin', { filtros: { fechaEntregaProgramada: '2026-05-20' } })
    const dialogo = await abrirSheet(user)

    await user.clear(inputsDeFecha(dialogo)[0])

    expect(onFiltrosChange).toHaveBeenCalledWith({ fechaEntregaProgramada: null })
    expect(onFiltrosChange).not.toHaveBeenCalledWith({ fechaEntregaProgramada: '' })
  })

  it('entrega: sin fecha puesta no hay X de "Limpiar filtro de entrega"', async () => {
    const user = userEvent.setup()
    renderFilters('admin')
    const dialogo = await abrirSheet(user)

    expect(within(dialogo).queryByRole('button', { name: 'Limpiar filtro de entrega' })).not.toBeInTheDocument()
  })
})

describe.each(ROLES)('rol %s — bottom sheet: salidas y cierre', rol => {
  it('el select de estado muestra el estado vigente y "Incluir cancelados" su valor', async () => {
    const user = userEvent.setup()
    renderFilters(rol, { filtros: { estado: 'entregado', verCancelados: true } })
    const dialogo = await abrirSheet(user)

    expect(selectDelSheet(dialogo, 'En camino')).toHaveDisplayValue('Entregados')
    expect(within(dialogo).getByRole('checkbox', { name: 'Incluir cancelados' })).toBeChecked()
  })

  it('desmarcar "Incluir cancelados" emite { verCancelados: false }', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol, { filtros: { verCancelados: true } })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('checkbox', { name: 'Incluir cancelados' }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ verCancelados: false })
  })

  it('volver a "Todos los estados" emite { estado: "todos" }', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol, { filtros: { estado: 'cancelado' } })
    const dialogo = await abrirSheet(user)

    await user.selectOptions(selectDelSheet(dialogo, 'Todos los estados'), 'Todos los estados')

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'todos' })
  })

  it('"Limpiar todo" emite el mismo payload de siete campos para cualquier rol, sin fechas ni búsqueda', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange, onBusquedaChange } = renderFilters(rol, {
      filtros: { estado: 'pendiente', verCancelados: true, fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' },
      busqueda: 'kiosco',
    })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Limpiar todo' }))

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
    expect(onBusquedaChange).not.toHaveBeenCalled()
    // Antes: "no abre el modal de fechas" (`onModalFiltroFecha`). Ese modal ya no
    // existe; lo que importa es que el rango siga puesto en el panel.
    expect(within(dialogo).getByLabelText('Desde')).toHaveValue('2026-04-01')
  })

  it('"Limpiar todo" no cierra el sheet', async () => {
    const user = userEvent.setup()
    renderFilters(rol, { filtros: { estado: 'pendiente' } })
    const dialogo = await abrirSheet(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Limpiar todo' }))

    expect(screen.getByRole('dialog', { name: 'Filtros' })).toBeInTheDocument()
  })

  it('la X ("Cerrar") y Escape cierran el sheet sin emitir nada', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderFilters(rol)

    const dialogo = await abrirSheet(user)
    await user.click(within(dialogo).getByRole('button', { name: 'Cerrar' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    await abrirSheet(user)
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('se puede volver a abrir después de cerrarlo', async () => {
    const user = userEvent.setup()
    renderFilters(rol)

    await user.click(within(await abrirSheet(user)).getByRole('button', { name: 'Listo' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    expect(await abrirSheet(user)).toBeInTheDocument()
  })

  it('el subtítulo sigue al estado: dos filtros dicen "2 filtros activos"', async () => {
    const user = userEvent.setup()
    renderFilters(rol, { filtros: { estado: 'entregado', verCancelados: true } })
    const dialogo = await abrirSheet(user)

    expect(within(dialogo).getByText('2 filtros activos')).toBeInTheDocument()
  })

  it('con el sheet abierto un cambio de filtros desde afuera actualiza subtítulo y "Limpiar todo"', async () => {
    const user = userEvent.setup()
    const props = {
      onBusquedaChange: vi.fn(),
      onFiltrosChange: vi.fn(),
    }
    const { rerender } = render(<PedidoFilters {...propsDeRol(rol)} {...props} />)
    const dialogo = await abrirSheet(user)
    expect(within(dialogo).getByText('Refiná tu búsqueda')).toBeInTheDocument()
    expect(within(dialogo).getByRole('button', { name: 'Limpiar todo' })).toBeDisabled()

    rerender(<PedidoFilters {...propsDeRol(rol, { filtros: { estado: 'pendiente' } })} {...props} />)

    expect(within(dialogo).getByText('1 filtro activo')).toBeInTheDocument()
    expect(within(dialogo).getByRole('button', { name: 'Limpiar todo' })).toBeEnabled()
  })
})

// =============================================================================
// (8) CONTADOR: CADA FILTRO SUELTO SUMA 1 (SI EL ROL LO VE)
// =============================================================================

describe.each(ROLES)('rol %s — cada filtro suelto suma 1 al contador, si el rol lo ve', rol => {
  const esAdmin = rol === 'admin'
  const SOLOS: Array<[string, Partial<Filtros>, boolean]> = [
    ['el estado', { estado: 'pendiente' }, false],
    ['"ver cancelados"', { verCancelados: true }, false],
    ['el pago', { estadoPago: 'parcial' }, true],
    ['el transportista', { transportistaId: 'sin_asignar' }, true],
    ['el usuario', { usuarioId: USUARIO.id }, true],
    ['la salvedad', { conSalvedad: 'sin_salvedad' }, true],
    ['la entrega programada', { fechaEntregaProgramada: MANANA }, true],
  ]

  for (const [nombre, filtros, soloAdmin] of SOLOS) {
    // Invertido en WP-44 (cierra #733): para un no-admin, los filtros que no ve
    // ya no suman. El pago "impago" del tile, que sí ve, está cubierto en (4).
    const oculto = soloAdmin && !esAdmin
    it(`${nombre} ${oculto ? 'NO suma: el rol no lo ve' : 'suma 1'}`, () => {
      renderFilters(rol, { filtros })

      if (oculto) expect(botonFiltros()).toHaveTextContent(/^Filtros$/)
      else expect(within(botonFiltros()).getByText('1')).toBeInTheDocument()
    })
  }
})

// =============================================================================
// (9) FLUJO DE FECHAS CON ESTADO REAL: BARRA + PANEL COMO EN EL CONTAINER
// =============================================================================

/**
 * Igual que `PedidosContainer`: `onFiltrosChange` mergea el parche. Hay estado
 * de verdad, así que se ve lo que el usuario ve, no sólo lo que se emite. Antes
 * este contenedor montaba también `ModalFiltroFecha`; desde WP-44 el rango se
 * elige en el panel y no hace falta nada más.
 */
function ContenedorSimulado({ rol, inicial = {} }: { rol: RolUsuario; inicial?: Partial<Filtros> }) {
  const [filtros, setFiltros] = useState<Filtros>({ ...FILTROS_BASE, ...inicial })
  const props = propsDeRol(rol)
  return (
    <PedidoFilters
      {...props}
      filtros={filtros}
      onBusquedaChange={() => {}}
      onFiltrosChange={parche => setFiltros(prev => ({ ...prev, ...parche }))}
    />
  )
}

describe.each(ROLES)('rol %s — rango de fechas de punta a punta', rol => {
  /** Abre el panel y devuelve el diálogo (el camino que reemplazó al botón "Fechas"). */
  const abrirFechas = abrirSheet

  async function cerrar(user: UserEvent, dialogo: HTMLElement): Promise<void> {
    await user.click(within(dialogo).getByRole('button', { name: 'Listo' }))
  }

  it('elegir un rango y cerrar deja el chip con las dos puntas', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} />)
    const dialogo = await abrirFechas(user)

    await user.type(within(dialogo).getByLabelText('Desde'), '2026-05-01')
    await user.type(within(dialogo).getByLabelText('Hasta'), '2026-05-31')
    await cerrar(user, dialogo)

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: 2026-05-01 – 2026-05-31')
  })

  it('elegir sólo "Desde" deja el chip con la otra punta abierta', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} />)
    const dialogo = await abrirFechas(user)

    await user.type(within(dialogo).getByLabelText('Desde'), '2026-05-01')
    await cerrar(user, dialogo)

    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: 2026-05-01 – …')
  })

  it('el rango no toca los otros filtros ni el contador, y se reabre precargado', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} inicial={{ estado: 'pendiente' }} />)
    const dialogo = await abrirFechas(user)

    await user.type(within(dialogo).getByLabelText('Desde'), '2026-05-01')
    await user.type(within(dialogo).getByLabelText('Hasta'), '2026-05-31')

    expect(within(dialogo).getByRole('combobox', { name: /filtrar por estado del pedido/i })).toHaveValue('pendiente')
    await cerrar(user, dialogo)
    expect(within(botonFiltros()).getByText('1')).toBeInTheDocument()

    const reabierto = await abrirFechas(user)
    expect([within(reabierto).getByLabelText('Desde'), within(reabierto).getByLabelText('Hasta')].map(i => (i as HTMLInputElement).value))
      .toEqual(['2026-05-01', '2026-05-31'])
  })

  it('elegir un estado con un rango puesto no lo pisa: el chip sigue', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} inicial={{ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' }} />)
    const dialogo = await abrirFechas(user)

    await user.selectOptions(within(dialogo).getByRole('combobox', { name: /filtrar por estado del pedido/i }), 'Entregados')
    await cerrar(user, dialogo)

    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: 2026-04-01 – 2026-04-15')
  })

  it('la X del chip quita el rango sin abrir el panel', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} inicial={{ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' }} />)

    await user.click(screen.getByRole('button', { name: 'Limpiar filtro de fechas' }))

    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  // Ajustado en WP-44: "Limpiar" del modal quitaba el rango y cerraba el modal.
  // "Limpiar fechas de carga" del panel lo quita igual; el panel queda abierto,
  // como con el resto de sus controles.
  it('"Limpiar fechas de carga" quita el rango', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} inicial={{ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' }} />)
    const dialogo = await abrirFechas(user)

    await user.click(within(dialogo).getByRole('button', { name: 'Limpiar fechas de carga' }))
    await cerrar(user, dialogo)

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  // Ajustado en WP-44: con el modal, cerrar sin "Aplicar" descartaba lo tipeado.
  // El panel es en vivo, así que lo que se aplica es lo válido que se escribió;
  // lo que se sigue descartando al cerrar es un rango inválido.
  it('abrir y cerrar con la X o con Escape sin tocar nada no cambia el rango', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} inicial={{ fechaDesde: '2026-04-01', fechaHasta: '2026-04-15' }} />)

    const primero = await abrirFechas(user)
    await user.click(within(primero).getByRole('button', { name: 'Cerrar' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    await abrirFechas(user)
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()

    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: 2026-04-01 – 2026-04-15')
  })

  // Invertido en WP-44 (cierra #734): antes el rango invertido se aplicaba y se
  // mostraba como un chip normal, sin ningún aviso.
  it('un rango invertido NO se aplica: se avisa, y el chip sigue con el rango anterior', async () => {
    const user = userEvent.setup()
    render(<ContenedorSimulado rol={rol} inicial={{ fechaHasta: '2026-05-01' }} />)
    const dialogo = await abrirFechas(user)

    await user.type(within(dialogo).getByLabelText('Desde'), '2026-05-31')

    expect(within(dialogo).getByRole('alert')).toHaveTextContent(/posterior/i)
    await user.keyboard('{Escape}')

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Filtrado: … – 2026-05-01')
    expect(screen.getByRole('status')).not.toHaveTextContent('2026-05-31')
    expect(screen.queryByText(/posterior/i)).not.toBeInTheDocument()
  })
})
