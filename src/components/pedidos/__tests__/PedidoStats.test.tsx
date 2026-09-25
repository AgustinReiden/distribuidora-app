/**
 * Tests de CARACTERIZACIÓN de `PedidoStats` — las seis tarjetas KPI de /pedidos.
 *
 * No describen lo que las tarjetas DEBERÍAN hacer: describen lo que hacen hoy,
 * antes del rediseño de UI. Dos cosas del comportamiento actual van a cambiar y
 * queremos que el cambio se vea:
 *
 *  - Las tarjetas NO eran interactivas (eran `div`, no `button`). WP-24 (#715)
 *    las volvió clickeables, pero opt-in: sólo con `filtros` + `onFiltrosChange`,
 *    que VistaPedidos pasa SIEMPRE. Por eso el test de "todavía no hay botones"
 *    ya no es el tripwire de WP-24: cubre sólo el modo de sólo lectura (galería
 *    y cualquier consumidor sin esas props), y las caracterizaciones de acá
 *    abajo corren contra ese modo. El modo que ve producción lo cubre el
 *    describe de #715 al final, que las repite con los tiles como botones
 *    (orden, conteos, cero, miles, aproximado y montos por rol, depósito
 *    incluido).
 *  - Los montos se gateaban con UN booleano (`isEncargado`) y depósito caía en
 *    la rama 'admin': veía la facturación completa. WP-31 (#717) le sumó
 *    `isDeposito`, y ahora depósito ve los conteos y ningún monto.
 *
 * Nada acá asevera clases de Tailwind: el acoplamiento a clases es lo que el
 * rediseño viene a romper.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { useState } from 'react'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import PedidoStats from '../PedidoStats'
import { formatPrecio } from '../../../utils/formatters'
import type { PedidoStatsSummary } from '../../../hooks/queries'

// =============================================================================
// FIXTURES
// =============================================================================

/**
 * Montos y conteos deliberadamente distintos entre sí: así cada aserción de
 * texto identifica una sola tarjeta y no se cuelga de la posición en la grilla.
 */
function hacerSummary(overrides: Partial<PedidoStatsSummary> = {}): PedidoStatsSummary {
  return {
    pendientes: { count: 3, monto: 1000 },
    enPreparacion: { count: 4, monto: 2000 },
    enCamino: { count: 5, monto: 3000 },
    entregados: { count: 6, monto: 4000 },
    impagos: { count: 7, monto: 5000 },
    total: { count: 18, monto: 15000 },
    aproximado: false,
    ...overrides,
  }
}

const ETIQUETAS = [
  'Pendientes',
  'En preparación',
  'En camino',
  'Entregados',
  'Impagos',
  'Total filtrado',
] as const

/** El bloque de texto de una tarjeta: etiqueta + conteo + (quizá) monto. */
function tarjeta(etiqueta: string): HTMLElement {
  const label = screen.getByText(etiqueta)
  const contenedor = label.closest('div')
  if (!contenedor) throw new Error(`La etiqueta "${etiqueta}" no está dentro de una tarjeta`)
  return contenedor
}

/** Los montos se reconocen porque son lo único que empieza con "$". */
function montosVisibles(): HTMLElement[] {
  return screen.queryAllByText(/^\$/)
}

/**
 * El texto del monto tal como lo lee testing-library.
 *
 * `formatPrecio` separa el símbolo con un espacio duro (U+00A0) y el
 * normalizador por defecto de testing-library lo colapsa a un espacio común:
 * sin este ajuste la comparación falla por un carácter invisible.
 */
function montoTexto(monto: number): string {
  return formatPrecio(monto).replace(/\s+/g, ' ')
}

// =============================================================================
// TESTS
// =============================================================================

describe('PedidoStats — las seis tarjetas', () => {
  it('renderiza las seis etiquetas', () => {
    render(<PedidoStats summary={hacerSummary()} />)

    for (const etiqueta of ETIQUETAS) {
      expect(screen.getByText(etiqueta)).toBeInTheDocument()
    }
  })

  it('cada tarjeta muestra su propio conteo', () => {
    render(<PedidoStats summary={hacerSummary()} />)

    expect(within(tarjeta('Pendientes')).getByText('3')).toBeInTheDocument()
    expect(within(tarjeta('En preparación')).getByText('4')).toBeInTheDocument()
    expect(within(tarjeta('En camino')).getByText('5')).toBeInTheDocument()
    expect(within(tarjeta('Entregados')).getByText('6')).toBeInTheDocument()
    expect(within(tarjeta('Impagos')).getByText('7')).toBeInTheDocument()
    expect(within(tarjeta('Total filtrado')).getByText('18')).toBeInTheDocument()
  })

  // El orden es contenido, no decoración: las cuatro primeras tarjetas son el
  // ciclo de vida del pedido (Pendientes → En preparación → En camino →
  // Entregados) y recién después vienen las dos de plata (Impagos, Total). Un
  // reordenamiento del rediseño rompe esa lectura sin romper ninguna otra
  // aserción, porque todas las demás buscan por texto.
  it('las seis tarjetas salen siempre en el mismo orden', () => {
    render(<PedidoStats summary={hacerSummary()} />)

    const enPantalla = screen.getAllByText(
      /^(Pendientes|En preparación|En camino|Entregados|Impagos|Total filtrado)$/,
    )

    expect(enPantalla.map(el => el.textContent)).toEqual([...ETIQUETAS])
  })

  it('el conteo se escribe con separador de miles argentino', () => {
    render(<PedidoStats summary={hacerSummary({ total: { count: 1234, monto: 15000 } })} />)

    expect(within(tarjeta('Total filtrado')).getByText('1.234')).toBeInTheDocument()
  })

  it('un summary en cero muestra las seis tarjetas igual', () => {
    render(
      <PedidoStats
        summary={hacerSummary({
          pendientes: { count: 0, monto: 0 },
          enPreparacion: { count: 0, monto: 0 },
          enCamino: { count: 0, monto: 0 },
          entregados: { count: 0, monto: 0 },
          impagos: { count: 0, monto: 0 },
          total: { count: 0, monto: 0 },
        })}
      />,
    )

    for (const etiqueta of ETIQUETAS) {
      expect(within(tarjeta(etiqueta)).getByText('0')).toBeInTheDocument()
    }
  })
})

describe('PedidoStats — qué montos ve cada rol', () => {
  it('el admin ve el monto en las seis tarjetas', () => {
    render(<PedidoStats summary={hacerSummary()} isEncargado={false} />)

    expect(within(tarjeta('Pendientes')).getByText(montoTexto(1000))).toBeInTheDocument()
    expect(within(tarjeta('En preparación')).getByText(montoTexto(2000))).toBeInTheDocument()
    expect(within(tarjeta('En camino')).getByText(montoTexto(3000))).toBeInTheDocument()
    expect(within(tarjeta('Entregados')).getByText(montoTexto(4000))).toBeInTheDocument()
    expect(within(tarjeta('Impagos')).getByText(montoTexto(5000))).toBeInTheDocument()
    expect(within(tarjeta('Total filtrado')).getByText(montoTexto(15000))).toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(6)
  })

  it('sin la prop isEncargado se comporta como admin', () => {
    render(<PedidoStats summary={hacerSummary()} />)

    expect(montosVisibles()).toHaveLength(6)
  })

  it('el encargado ve el monto SOLO en "Impagos"', () => {
    render(<PedidoStats summary={hacerSummary()} isEncargado />)

    expect(within(tarjeta('Impagos')).getByText(montoTexto(5000))).toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(1)
  })

  it('el encargado igual ve los seis conteos', () => {
    render(<PedidoStats summary={hacerSummary()} isEncargado />)

    expect(within(tarjeta('Pendientes')).getByText('3')).toBeInTheDocument()
    expect(within(tarjeta('Total filtrado')).getByText('18')).toBeInTheDocument()
  })

  // #717 (WP-31): antes depósito llegaba con `isEncargado={false}`, caía en la
  // rama 'admin' y veía la facturación completa. Con `isDeposito` el componente
  // le pasa el rol real a `mostrarMontosEnStats`, que le niega los seis montos
  // —mismo criterio que `puedeVerDeudaCliente`—. Los conteos los sigue viendo:
  // son lo que necesita para preparar la mercadería.
  it('depósito ve los seis conteos y ningún monto (#717)', () => {
    render(<PedidoStats summary={hacerSummary()} isDeposito />)

    expect(within(tarjeta('Pendientes')).getByText('3')).toBeInTheDocument()
    expect(within(tarjeta('En preparación')).getByText('4')).toBeInTheDocument()
    expect(within(tarjeta('En camino')).getByText('5')).toBeInTheDocument()
    expect(within(tarjeta('Entregados')).getByText('6')).toBeInTheDocument()
    expect(within(tarjeta('Impagos')).getByText('7')).toBeInTheDocument()
    expect(within(tarjeta('Total filtrado')).getByText('18')).toBeInTheDocument()
    expect(within(tarjeta('Total filtrado')).queryByText(montoTexto(15000))).not.toBeInTheDocument()
    expect(within(tarjeta('Impagos')).queryByText(montoTexto(5000))).not.toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(0)
  })
})

describe('PedidoStats — aviso de conteo aproximado', () => {
  it('avisa cuando el summary viene marcado como aproximado', () => {
    render(<PedidoStats summary={hacerSummary({ aproximado: true })} />)

    expect(screen.getByRole('status')).toHaveTextContent(
      'Totales aproximados: hay más pedidos filtrados de los que se pudieron sumar.',
    )
  })

  it('no avisa nada cuando los totales son exactos', () => {
    render(<PedidoStats summary={hacerSummary({ aproximado: false })} />)

    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.queryByText(/Totales aproximados/)).not.toBeInTheDocument()
  })
})

describe('PedidoStats — modo de sólo lectura (sin onFiltrosChange): las tarjetas no son interactivas', () => {
  // Vale sólo para el modo de SÓLO LECTURA (sin `filtros` + `onFiltrosChange`):
  // ahí cada tile sigue siendo un <div> sin rol, ni botón, ni link, ni foco. En
  // producción VistaPedidos pasa las dos props y los tiles son botones (WP-24,
  // #715): eso lo cubre el describe de #715 más abajo.
  it('no hay ningún botón ni link dentro de las tarjetas', () => {
    render(<PedidoStats summary={hacerSummary({ aproximado: true })} />)

    expect(screen.queryAllByRole('button')).toHaveLength(0)
    expect(screen.queryAllByRole('link')).toHaveLength(0)
  })
})

// =============================================================================
// WP-24 (#715): LOS TILES FILTRAN LA LISTA
// =============================================================================
//
// La interactividad es opt-in: sólo con `filtros` + `onFiltrosChange`. Sin
// ellas el componente sigue siendo de sólo lectura, y por eso el describe de
// arriba ("modo de sólo lectura") sigue valiendo tal cual para ese modo.

const SIN_FILTRO = { estado: 'todos', estadoPago: 'todos' }

/** Arnés con estado real: los clics cambian los filtros como en el container. */
function StatsConEstado({ inicial = SIN_FILTRO }: { inicial?: { estado: string; estadoPago: string } }) {
  const [filtros, setFiltros] = useState(inicial)
  return (
    <PedidoStats
      summary={hacerSummary()}
      filtros={filtros}
      onFiltrosChange={cambios => setFiltros(prev => ({ ...prev, ...cambios }))}
    />
  )
}

describe('PedidoStats — con onFiltrosChange los tiles filtran (#715)', () => {
  it('los seis tiles son botones, dentro de un grupo con nombre', () => {
    render(<PedidoStats summary={hacerSummary()} filtros={SIN_FILTRO} onFiltrosChange={vi.fn()} />)

    const grupo = screen.getByRole('group', { name: 'Filtrar pedidos por estado o pago' })
    expect(within(grupo).getAllByRole('button')).toHaveLength(6)
    for (const etiqueta of ETIQUETAS) {
      expect(within(grupo).getByRole('button', { name: new RegExp(etiqueta) })).toBeInTheDocument()
    }
  })

  it('clic en "Pendientes" filtra por estado pendiente', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(<PedidoStats summary={hacerSummary()} filtros={SIN_FILTRO} onFiltrosChange={onFiltrosChange} />)

    await user.click(screen.getByRole('button', { name: /Pendientes/ }))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'pendiente' })
  })

  it('con estado pendiente ese tile está presionado y un segundo clic manda "todos"', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'pendiente', estadoPago: 'todos' }}
        onFiltrosChange={onFiltrosChange}
      />,
    )

    const pendientes = screen.getByRole('button', { name: /Pendientes/ })
    expect(pendientes).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: /Entregados/ })).toHaveAttribute('aria-pressed', 'false')

    await user.click(pendientes)

    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'todos' })
  })

  it('"En camino" filtra por estado asignado (lo que cuenta el summary)', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(<PedidoStats summary={hacerSummary()} filtros={SIN_FILTRO} onFiltrosChange={onFiltrosChange} />)

    await user.click(screen.getByRole('button', { name: /En camino/ }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'asignado' })
  })

  it('"En preparación" y "Entregados" filtran por su estado', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(<PedidoStats summary={hacerSummary()} filtros={SIN_FILTRO} onFiltrosChange={onFiltrosChange} />)

    await user.click(screen.getByRole('button', { name: /En preparación/ }))
    await user.click(screen.getByRole('button', { name: /Entregados/ }))

    expect(onFiltrosChange).toHaveBeenNthCalledWith(1, { estado: 'en_preparacion' })
    expect(onFiltrosChange).toHaveBeenNthCalledWith(2, { estado: 'entregado' })
  })

  it('"Impagos" filtra por el sentinela de pago impago, sin tocar el estado', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(<PedidoStats summary={hacerSummary()} filtros={SIN_FILTRO} onFiltrosChange={onFiltrosChange} />)

    await user.click(screen.getByRole('button', { name: /Impagos/ }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ estadoPago: 'impago' })
  })

  it('"Total filtrado" limpia estado y pago, y no es un toggle', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'asignado', estadoPago: 'impago' }}
        onFiltrosChange={onFiltrosChange}
      />,
    )

    const total = screen.getByRole('button', { name: /Total filtrado/ })
    expect(total).not.toHaveAttribute('aria-pressed')

    await user.click(total)

    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'todos', estadoPago: 'todos' })
  })

  it('un tile de estado e "Impagos" pueden estar presionados a la vez', () => {
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'asignado', estadoPago: 'impago' }}
        onFiltrosChange={vi.fn()}
      />,
    )

    expect(screen.getByRole('button', { name: /En camino/ })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: /Impagos/ })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: /Pendientes/ })).toHaveAttribute('aria-pressed', 'false')
  })

  it('con estado real: clic aplica, clic en el activo deselecciona', async () => {
    const user = userEvent.setup()
    render(<StatsConEstado />)

    const entregados = screen.getByRole('button', { name: /Entregados/ })
    expect(entregados).toHaveAttribute('aria-pressed', 'false')

    await user.click(entregados)
    expect(entregados).toHaveAttribute('aria-pressed', 'true')

    await user.click(entregados)
    expect(entregados).toHaveAttribute('aria-pressed', 'false')
  })

  it('con estado real: pasar de un tile de estado a otro mueve la selección y no toca "Impagos"', async () => {
    const user = userEvent.setup()
    render(<StatsConEstado inicial={{ estado: 'pendiente', estadoPago: 'impago' }} />)

    await user.click(screen.getByRole('button', { name: /En camino/ }))

    expect(screen.getByRole('button', { name: /En camino/ })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: /Pendientes/ })).toHaveAttribute('aria-pressed', 'false')
    expect(screen.getByRole('button', { name: /Impagos/ })).toHaveAttribute('aria-pressed', 'true')
  })

  it('un estado que ningún tile representa (cancelado) no presiona ninguno', () => {
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'cancelado', estadoPago: 'pagado' }}
        onFiltrosChange={vi.fn()}
      />,
    )

    for (const boton of screen.getAllByRole('button')) {
      expect(boton).not.toHaveAttribute('aria-pressed', 'true')
    }
  })

  it('sin onFiltrosChange no hay botones aunque lleguen los filtros', () => {
    render(<PedidoStats summary={hacerSummary()} filtros={{ estado: 'pendiente', estadoPago: 'todos' }} />)

    expect(screen.queryAllByRole('button')).toHaveLength(0)
    expect(screen.queryByRole('group')).not.toBeInTheDocument()
  })

  it('volverse botón no cambia los montos por rol: el encargado sigue viendo sólo "Impagos"', () => {
    render(
      <PedidoStats summary={hacerSummary()} isEncargado filtros={SIN_FILTRO} onFiltrosChange={vi.fn()} />,
    )

    expect(within(screen.getByRole('button', { name: /Impagos/ })).getByText(montoTexto(5000))).toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(1)
  })

  it('volverse botón no cambia los montos por rol: el admin ve los seis', () => {
    render(<PedidoStats summary={hacerSummary()} filtros={SIN_FILTRO} onFiltrosChange={vi.fn()} />)

    expect(within(screen.getByRole('button', { name: /Pendientes/ })).getByText('3')).toBeInTheDocument()
    expect(within(screen.getByRole('button', { name: /Total filtrado/ })).getByText(montoTexto(15000))).toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(6)
  })
})

// =============================================================================
// MODO BOTÓN: LAS MISMAS CARACTERIZACIONES QUE EL MODO DE SÓLO LECTURA
// =============================================================================
//
// VistaPedidos siempre pasa `filtros` + `onFiltrosChange`, así que ÉSTE es el
// camino que ve producción. Los casos de arriba (orden, conteos, cero, miles,
// aproximado, montos por rol, depósito sin montos #717) corren contra la rama
// <div>; acá se repiten contra la rama <button> para que la red no quede más
// fina justo donde se usa. Cada tile se busca por su rol y su nombre accesible,
// no por posición.

/** PedidoStats en modo botón, como lo monta VistaPedidos. */
function renderInteractivo(
  summary: PedidoStatsSummary = hacerSummary(),
  props: { isEncargado?: boolean; isDeposito?: boolean } = {},
) {
  const onFiltrosChange = vi.fn()
  render(
    <PedidoStats
      summary={summary}
      isEncargado={props.isEncargado}
      isDeposito={props.isDeposito}
      filtros={SIN_FILTRO}
      onFiltrosChange={onFiltrosChange}
    />,
  )
  return { onFiltrosChange }
}

/** El botón de un tile. Nombre accesible = etiqueta + conteo + (quizá) monto. */
function tile(etiqueta: string): HTMLElement {
  return screen.getByRole('button', { name: new RegExp(`^${etiqueta}`) })
}

describe('PedidoStats — modo botón: mismas caracterizaciones (#715)', () => {
  it('los seis botones salen en el orden del ciclo de vida y después la plata', () => {
    renderInteractivo()

    const grupo = screen.getByRole('group', { name: 'Filtrar pedidos por estado o pago' })
    const orden = within(grupo)
      .getAllByRole('button')
      .map(boton => ETIQUETAS.find(etiqueta => boton.textContent?.startsWith(etiqueta)))

    expect(orden).toEqual([...ETIQUETAS])
  })

  it('cada botón muestra su propio conteo', () => {
    renderInteractivo()

    expect(within(tile('Pendientes')).getByText('3')).toBeInTheDocument()
    expect(within(tile('En preparación')).getByText('4')).toBeInTheDocument()
    expect(within(tile('En camino')).getByText('5')).toBeInTheDocument()
    expect(within(tile('Entregados')).getByText('6')).toBeInTheDocument()
    expect(within(tile('Impagos')).getByText('7')).toBeInTheDocument()
    expect(within(tile('Total filtrado')).getByText('18')).toBeInTheDocument()
  })

  it('el conteo se escribe con separador de miles argentino', () => {
    renderInteractivo(hacerSummary({ total: { count: 1234, monto: 15000 } }))

    expect(within(tile('Total filtrado')).getByText('1.234')).toBeInTheDocument()
  })

  it('un summary en cero muestra los seis botones igual, y se pueden tocar', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderInteractivo(
      hacerSummary({
        pendientes: { count: 0, monto: 0 },
        enPreparacion: { count: 0, monto: 0 },
        enCamino: { count: 0, monto: 0 },
        entregados: { count: 0, monto: 0 },
        impagos: { count: 0, monto: 0 },
        total: { count: 0, monto: 0 },
      }),
    )

    for (const etiqueta of ETIQUETAS) {
      expect(within(tile(etiqueta)).getByText('0')).toBeInTheDocument()
    }

    await user.click(tile('Pendientes'))
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'pendiente' })
  })

  it('avisa cuando el summary es aproximado, fuera del grupo de botones', () => {
    renderInteractivo(hacerSummary({ aproximado: true }))

    const aviso = screen.getByRole('status')
    expect(aviso).toHaveTextContent(
      'Totales aproximados: hay más pedidos filtrados de los que se pudieron sumar.',
    )
    const grupo = screen.getByRole('group', { name: 'Filtrar pedidos por estado o pago' })
    expect(grupo).not.toContainElement(aviso)
    expect(within(grupo).getAllByRole('button')).toHaveLength(6)
  })

  it('no avisa nada cuando los totales son exactos', () => {
    renderInteractivo(hacerSummary({ aproximado: false }))

    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })

  it('el admin ve el monto en los seis botones', () => {
    renderInteractivo(hacerSummary(), { isEncargado: false })

    expect(within(tile('Pendientes')).getByText(montoTexto(1000))).toBeInTheDocument()
    expect(within(tile('En preparación')).getByText(montoTexto(2000))).toBeInTheDocument()
    expect(within(tile('En camino')).getByText(montoTexto(3000))).toBeInTheDocument()
    expect(within(tile('Entregados')).getByText(montoTexto(4000))).toBeInTheDocument()
    expect(within(tile('Impagos')).getByText(montoTexto(5000))).toBeInTheDocument()
    expect(within(tile('Total filtrado')).getByText(montoTexto(15000))).toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(6)
  })

  it('el encargado igual ve los seis conteos, y el monto sólo en "Impagos"', () => {
    renderInteractivo(hacerSummary(), { isEncargado: true })

    expect(within(tile('Pendientes')).getByText('3')).toBeInTheDocument()
    expect(within(tile('Total filtrado')).getByText('18')).toBeInTheDocument()
    expect(within(tile('Impagos')).getByText(montoTexto(5000))).toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(1)
  })

  // #717 (WP-31): el mismo caso de más arriba, en el modo que ve producción.
  // Las dos ramas comparten el contenido del tile, así que depósito tampoco ve
  // montos acá: ni en el texto ni en el nombre accesible del botón.
  it('depósito ve los seis conteos y ningún monto (#717)', () => {
    renderInteractivo(hacerSummary(), { isDeposito: true })

    expect(within(tile('Pendientes')).getByText('3')).toBeInTheDocument()
    expect(within(tile('En preparación')).getByText('4')).toBeInTheDocument()
    expect(within(tile('En camino')).getByText('5')).toBeInTheDocument()
    expect(within(tile('Entregados')).getByText('6')).toBeInTheDocument()
    expect(within(tile('Impagos')).getByText('7')).toBeInTheDocument()
    expect(within(tile('Total filtrado')).getByText('18')).toBeInTheDocument()
    expect(within(tile('Total filtrado')).queryByText(montoTexto(15000))).not.toBeInTheDocument()
    expect(montosVisibles()).toHaveLength(0)
    for (const etiqueta of ETIQUETAS) {
      expect(tile(etiqueta)).not.toHaveAccessibleName(/\$/)
    }
  })

  it('sin montos, los tiles de depósito siguen filtrando', async () => {
    const user = userEvent.setup()
    const { onFiltrosChange } = renderInteractivo(hacerSummary(), { isDeposito: true })

    await user.click(tile('Impagos'))
    await user.click(tile('Pendientes'))

    expect(onFiltrosChange).toHaveBeenNthCalledWith(1, { estadoPago: 'impago' })
    expect(onFiltrosChange).toHaveBeenNthCalledWith(2, { estado: 'pendiente' })
  })
})

describe('PedidoStats — "Total filtrado" deja la lista que contaba (#715)', () => {
  // Con estado 'cancelado' el summary cuenta los cancelados (filtrosParaStats
  // les prende verCancelados). Si "Total" sólo limpiara el estado, la lista
  // volvería a excluirlos y tendría menos filas que el número del tile.
  it('con estado cancelado, además de limpiar prende "Ver cancelados"', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'cancelado', estadoPago: 'todos', verCancelados: false }}
        onFiltrosChange={onFiltrosChange}
      />,
    )

    await user.click(screen.getByRole('button', { name: /Total filtrado/ }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'todos', estadoPago: 'todos', verCancelados: true })
  })

  it('sin estado cancelado no toca "Ver cancelados"', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'entregado', estadoPago: 'impago', verCancelados: false }}
        onFiltrosChange={onFiltrosChange}
      />,
    )

    await user.click(screen.getByRole('button', { name: /Total filtrado/ }))

    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'todos', estadoPago: 'todos' })
  })
})

describe('PedidoStats — "Total filtrado" es el botón de limpiar (#715)', () => {
  // No tiene estado presionado que muestre lo que hace: su nombre accesible lo
  // dice. Y sin nada que limpiar no manda un cambio que sólo resetearía la página.
  it('su nombre accesible dice que quita los filtros de estado y pago; el de los otros cinco no', () => {
    renderInteractivo()

    expect(tile('Total filtrado')).toHaveAccessibleName(/quita los filtros de estado y pago/)
    for (const etiqueta of ETIQUETAS.filter(e => e !== 'Total filtrado')) {
      expect(tile(etiqueta)).not.toHaveAccessibleName(/quita los filtros/)
    }
  })

  it('en el modo de sólo lectura no aparece ese texto', () => {
    render(<PedidoStats summary={hacerSummary()} />)

    expect(screen.queryByText(/quita los filtros/)).not.toBeInTheDocument()
  })

  it('sin estado ni pago elegidos, tocarlo no llama a onFiltrosChange', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'todos', estadoPago: 'todos', verCancelados: true }}
        onFiltrosChange={onFiltrosChange}
      />,
    )

    await user.click(tile('Total filtrado'))

    expect(onFiltrosChange).not.toHaveBeenCalled()
  })

  it('con sólo un pago elegido sí limpia', async () => {
    const user = userEvent.setup()
    const onFiltrosChange = vi.fn()
    render(
      <PedidoStats
        summary={hacerSummary()}
        filtros={{ estado: 'todos', estadoPago: 'pagado' }}
        onFiltrosChange={onFiltrosChange}
      />,
    )

    await user.click(tile('Total filtrado'))

    expect(onFiltrosChange).toHaveBeenCalledTimes(1)
    expect(onFiltrosChange).toHaveBeenCalledWith({ estado: 'todos', estadoPago: 'todos' })
  })
})
