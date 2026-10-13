import { describe, it, expect } from 'vitest'
import { describirReglaEscala } from './describirReglaEscala'
import type { EscalaPrecio, ReglaProducto } from './precioMayorista'

/** El formato de moneda separa "$" del número con un espacio duro. */
const plano = (s: string) => s.replace(/\s+/g, ' ')

const escala = (
  cantidadMinima: number,
  precioUnitario: number,
  extra: { minProductosDistintos?: number; minimos?: Array<[string, ReglaProducto]> } = {},
): EscalaPrecio => ({
  cantidadMinima,
  precioUnitario,
  etiqueta: null,
  minProductosDistintos: extra.minProductosDistintos ?? 1,
  minimosPorProducto: new Map(extra.minimos ?? []),
})

describe('describirReglaEscala — precios con centavos (#1121)', () => {
  it('no redondea: una escala a $849,50 se describe a $849,50, como la cobra el pedido', () => {
    expect(plano(describirReglaEscala(escala(12, 849.5)))).toBe('Si el grupo suma 12+ unidades, $ 849,50 c/u.')
  })

  it('un precio entero sale con ",00", igual que el resto de la app', () => {
    expect(plano(describirReglaEscala(escala(12, 800)))).toBe('Si el grupo suma 12+ unidades, $ 800,00 c/u.')
  })

  it('en una combinada con precios por sabor, cada precio conserva sus centavos', () => {
    const texto = describirReglaEscala(
      escala(12, 800, {
        minProductosDistintos: 2,
        minimos: [['1', { cantidad: 6, precioOverride: 790.25 }], ['2', { cantidad: 6, precioOverride: null }]],
      }),
      { nombresProductos: new Map([['1', 'Fideo A'], ['2', 'Fideo B']]) },
    )
    expect(plano(texto)).toBe(
      'Si comprás 12+ unidades totales, al menos 2 productos distintos, con precios por producto (Fideo A 6+ a $ 790,25, Fideo B 6+ a $ 800,00).',
    )
  })

  it('en una combinada con precio único, el precio conserva sus centavos', () => {
    const texto = describirReglaEscala(
      escala(12, 799.99, { minimos: [['1', { cantidad: 6 }]] }),
      { nombresProductos: { '1': 'Fideo A' } },
    )
    expect(plano(texto)).toBe('Si comprás 12+ unidades totales, con mínimos (Fideo A 6+), $ 799,99 c/u.')
  })
})
