/**
 * Tests de CARACTERIZACIÓN de `PedidoStats` — las seis tarjetas KPI de /pedidos.
 *
 * No describen lo que las tarjetas DEBERÍAN hacer: describen lo que hacen hoy,
 * antes del rediseño de UI. Dos cosas del comportamiento actual van a cambiar y
 * queremos que el cambio se vea:
 *
 *  - Las tarjetas NO son interactivas (son `div`, no `button`). El plan es
 *    volverlas clickeables (WP-24): el test de "todavía no hay botones" se pone
 *    rojo el día que eso pase, que es justamente lo que se busca.
 *  - Los montos se gatean con UN booleano (`isEncargado`), no con el rol. Ver
 *    el BUG #717 más abajo.
 *
 * Nada acá asevera clases de Tailwind: el acoplamiento a clases es lo que el
 * rediseño viene a romper.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect } from 'vitest'
import { render, screen, within } from '@testing-library/react'

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

  // BUG #717: depósito ve todos los montos; se corrige en WP-31.
  //
  // `PedidoStats` no recibe el rol: recibe `isEncargado` y adentro resuelve
  // `const rol = isEncargado ? 'encargado' : 'admin'`. Cualquier rol que NO sea
  // encargado —depósito y transportista entran a /pedidos por TopNavigation—
  // llega con `isEncargado={false}` y cae en la rama 'admin', así que ve la
  // facturación completa. `mostrarMontosEnStats` sabe distinguir roles; el
  // componente le miente la entrada. Se asevera el comportamiento ACTUAL.
  it('BUG #717: depósito (isEncargado=false) ve los seis montos como si fuera admin', () => {
    render(<PedidoStats summary={hacerSummary()} isEncargado={false} />)

    expect(montosVisibles()).toHaveLength(6)
    expect(within(tarjeta('Total filtrado')).getByText(montoTexto(15000))).toBeInTheDocument()
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

describe('PedidoStats — las tarjetas todavía no son interactivas', () => {
  // Esto cambia en WP-24 (tiles clickeables que aplican el filtro). Hasta que
  // pase, cada tile es un <div> sin rol: ni botón, ni link, ni foco.
  it('no hay ningún botón ni link dentro de las tarjetas', () => {
    render(<PedidoStats summary={hacerSummary({ aproximado: true })} />)

    expect(screen.queryAllByRole('button')).toHaveLength(0)
    expect(screen.queryAllByRole('link')).toHaveLength(0)
  })
})
