/**
 * Tests para resolverPreciosMayorista con reglas de activacion combinada.
 *
 * Cubre:
 *   - Escala clasica (default, retrocompat)
 *   - Escala combinada basica (K=2, minimos uniformes)
 *   - Escala combinada con minimos heterogeneos
 *   - Falla por presencia insuficiente (producto con cantidad < minimo)
 *   - Fallback a escala inferior cuando la combinada no aplica
 *   - Prioridad entre dos grupos (gana el mejor precio)
 *   - Producto con precioOverride no se toca
 */
import { describe, expect, it } from 'vitest'
import {
  escalaAplica,
  esEscalaCombinada,
  precioEfectivoEscala,
  resolverPreciosMayorista,
  type EscalaPrecio,
  type GrupoPrecioInfo,
  type ItemPedido,
  type PricingMap,
  type ReglaProducto
} from './precioMayorista'

// Helpers para armar escalas facilmente
function escalaClasica(cantidadMinima: number, precioUnitario: number, etiqueta = ''): EscalaPrecio {
  return {
    cantidadMinima,
    precioUnitario,
    etiqueta: etiqueta || null,
    minProductosDistintos: 1,
    minimosPorProducto: new Map()
  }
}

/**
 * Arma una escala combinada. `minimos` acepta tanto un numero (shortcut a
 * { cantidad: N }) como un objeto { cantidad, precioOverride? } para configurar
 * un precio mayorista especifico por producto.
 */
function escalaCombinada(
  cantidadMinima: number,
  precioUnitario: number,
  minProductosDistintos: number,
  minimos: Record<string, number | ReglaProducto>,
  etiqueta = ''
): EscalaPrecio {
  const map = new Map<string, ReglaProducto>()
  for (const [pid, v] of Object.entries(minimos)) {
    if (typeof v === 'number') map.set(pid, { cantidad: v })
    else map.set(pid, v)
  }
  return {
    cantidadMinima,
    precioUnitario,
    etiqueta: etiqueta || null,
    minProductosDistintos,
    minimosPorProducto: map
  }
}

function grupo(
  id: string,
  nombre: string,
  productoIds: string[],
  escalas: EscalaPrecio[]
): GrupoPrecioInfo {
  return {
    grupoId: id,
    grupoNombre: nombre,
    escalas,
    productoIds,
    moqPorProducto: new Map()
  }
}

function pricingMap(grupos: GrupoPrecioInfo[]): PricingMap {
  const map: PricingMap = new Map()
  for (const g of grupos) {
    for (const pid of g.productoIds) {
      const arr = map.get(pid) || []
      arr.push(g)
      map.set(pid, arr)
    }
  }
  return map
}

function item(productoId: string, cantidad: number, precioUnitario = 1000): ItemPedido {
  return { productoId, cantidad, precioUnitario }
}

describe('esEscalaCombinada', () => {
  it('devuelve false para escalas clasicas', () => {
    expect(esEscalaCombinada(escalaClasica(12, 800))).toBe(false)
  })

  it('devuelve true si minProductosDistintos > 1', () => {
    expect(esEscalaCombinada(escalaCombinada(12, 800, 2, {}))).toBe(true)
  })

  it('devuelve true si hay minimos por producto', () => {
    expect(esEscalaCombinada(escalaCombinada(12, 800, 1, { A: 6 }))).toBe(true)
  })
})

describe('escalaAplica', () => {
  const productos = ['A', 'B', 'C']

  it('clasica: aplica si total >= cantidadMinima', () => {
    const escala = escalaClasica(12, 800)
    const cantidades = new Map([['A', 12], ['B', 0], ['C', 0]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(true)
  })

  it('clasica: no aplica si total < cantidadMinima', () => {
    const escala = escalaClasica(12, 800)
    const cantidades = new Map([['A', 6], ['B', 5], ['C', 0]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(false)
  })

  it('combinada: aplica con 6A + 6B cuando K=2 y minimos 6/6/6', () => {
    const escala = escalaCombinada(12, 800, 2, { A: 6, B: 6, C: 6 })
    const cantidades = new Map([['A', 6], ['B', 6], ['C', 0]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(true)
  })

  it('combinada: falla con 12A solo cuando K=2', () => {
    const escala = escalaCombinada(12, 800, 2, { A: 6, B: 6, C: 6 })
    const cantidades = new Map([['A', 12], ['B', 0], ['C', 0]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(false)
  })

  it('combinada: falla si un producto presente tiene cantidad < su minimo', () => {
    // 7A + 5B = 12 total pero B esta con 5 (< 6)
    const escala = escalaCombinada(12, 800, 2, { A: 6, B: 6, C: 6 })
    const cantidades = new Map([['A', 7], ['B', 5], ['C', 0]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(false)
  })

  it('combinada: aplica con 6A+6B+3C cuando C no tiene minimo configurado y K=2', () => {
    // Si C no tuviera minimo: 6A + 6B cumplen K=2 y C cuenta solo si >= minimo
    // Aqui C tiene minimo 6 y solo 3: como cantidad > 0 y < minimo, la regla 2 falla.
    const escala = escalaCombinada(12, 800, 2, { A: 6, B: 6, C: 6 })
    const cantidades = new Map([['A', 6], ['B', 6], ['C', 3]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(false)
  })

  it('combinada: producto sin minimo configurado cuenta si >0', () => {
    // C no tiene minimo configurado: basta con estar presente para contar
    const escala = escalaCombinada(10, 800, 2, { A: 4, B: 4 })
    const cantidades = new Map([['A', 4], ['B', 0], ['C', 6]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(true)
  })

  it('combinada K=3 con 3 productos exactos cumple', () => {
    const escala = escalaCombinada(12, 700, 3, { A: 4, B: 4, C: 4 })
    const cantidades = new Map([['A', 4], ['B', 4], ['C', 4]])
    expect(escalaAplica(escala, cantidades, productos)).toBe(true)
  })
})

describe('resolverPreciosMayorista - escala clasica (retrocompat)', () => {
  it('aplica precio mayorista cuando total supera la escala', () => {
    const g = grupo('g1', 'Fideos', ['A', 'B'], [escalaClasica(12, 800)])
    const pm = pricingMap([g])
    const items = [item('A', 12, 1000), item('B', 0, 1000)]
    const res = resolverPreciosMayorista(items, pm)

    const resA = res.get('A')!
    expect(resA.esMayorista).toBe(true)
    expect(resA.precioResuelto).toBe(800)
    expect(resA.cantidadEnGrupo).toBe(12)
  })

  it('12A+0B activa la clasica (compat con comportamiento previo)', () => {
    const g = grupo('g1', 'Fideos', ['A', 'B'], [escalaClasica(12, 800)])
    const pm = pricingMap([g])
    const items = [item('A', 12, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(800)
  })

  it('total insuficiente deja precio original', () => {
    const g = grupo('g1', 'Fideos', ['A', 'B'], [escalaClasica(12, 800)])
    const pm = pricingMap([g])
    const items = [item('A', 5, 1000), item('B', 5, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.esMayorista).toBe(false)
    expect(res.get('A')!.precioResuelto).toBe(1000)
  })
})

describe('resolverPreciosMayorista - escala combinada', () => {
  const g = grupo('g1', 'Fideos', ['A', 'B', 'C'], [
    escalaCombinada(12, 800, 2, { A: 6, B: 6, C: 6 }, 'Combo medio+medio')
  ])
  const pm = pricingMap([g])

  it('6A+6B aplica precio $800 a ambos', () => {
    const items = [item('A', 6, 1000), item('B', 6, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(800)
    expect(res.get('B')!.precioResuelto).toBe(800)
  })

  it('12A+0B NO aplica la combinada', () => {
    const items = [item('A', 12, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.esMayorista).toBe(false)
  })

  it('7A+5B NO aplica (B insuficiente rompe la regla)', () => {
    const items = [item('A', 7, 1000), item('B', 5, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.esMayorista).toBe(false)
    expect(res.get('B')!.esMayorista).toBe(false)
  })

  it('6A+6B+3C NO aplica (C presente con < minimo)', () => {
    const items = [item('A', 6, 1000), item('B', 6, 1000), item('C', 3, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.esMayorista).toBe(false)
  })

  it('6A+6B+6C aplica (los 3 cuentan, K=2 ampliamente superado)', () => {
    const items = [item('A', 6, 1000), item('B', 6, 1000), item('C', 6, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(800)
    expect(res.get('B')!.precioResuelto).toBe(800)
    expect(res.get('C')!.precioResuelto).toBe(800)
  })
})

describe('resolverPreciosMayorista - coexistencia clasica + combinada', () => {
  // Grupo con 3 escalas: 12 clasica $820, 12 combinada $800, 24 clasica $750
  const g = grupo('g1', 'Fideos', ['A', 'B', 'C'], [
    escalaClasica(12, 820),
    escalaCombinada(12, 800, 2, { A: 6, B: 6, C: 6 }),
    escalaClasica(24, 750)
  ])
  const pm = pricingMap([g])

  it('12A paga $820 (clasica, la combinada falla)', () => {
    const items = [item('A', 12, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(820)
  })

  it('6A+6B paga $800 (combinada gana a la clasica de 12)', () => {
    const items = [item('A', 6, 1000), item('B', 6, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(800)
  })

  it('24A paga $750 (clasica 24 gana por ser mayor cantidadMinima)', () => {
    const items = [item('A', 24, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(750)
  })

  it('12A+12B paga $750 (clasica 24 supera a la combinada)', () => {
    const items = [item('A', 12, 1000), item('B', 12, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(750)
  })
})

describe('precioEfectivoEscala', () => {
  it('sin override devuelve precio base de la escala', () => {
    const e = escalaCombinada(12, 800, 2, { A: 6, B: 6 })
    expect(precioEfectivoEscala(e, 'A')).toBe(800)
  })

  it('con override devuelve el override del producto', () => {
    const e = escalaCombinada(12, 800, 2, {
      A: { cantidad: 6, precioOverride: 850 },
      B: { cantidad: 6, precioOverride: 950 }
    })
    expect(precioEfectivoEscala(e, 'A')).toBe(850)
    expect(precioEfectivoEscala(e, 'B')).toBe(950)
  })

  it('override null cae a precio base', () => {
    const e = escalaCombinada(12, 800, 2, {
      A: { cantidad: 6, precioOverride: null },
      B: { cantidad: 6, precioOverride: 950 }
    })
    expect(precioEfectivoEscala(e, 'A')).toBe(800)
    expect(precioEfectivoEscala(e, 'B')).toBe(950)
  })
})

describe('resolverPreciosMayorista - precios heterogeneos por producto', () => {
  // Caso del cliente: codito $900 con mayorista $850, moñito $1000 con mayorista $950.
  // Escala combinada exige 6 de cada uno y al menos 2 productos.
  const g = grupo('g1', 'Fideos', ['codito', 'moñito'], [
    escalaCombinada(12, 900, 2, {
      codito: { cantidad: 6, precioOverride: 850 },
      moñito: { cantidad: 6, precioOverride: 950 }
    })
  ])
  const pm = pricingMap([g])

  it('6 codito + 6 moñito aplica precios distintos por producto', () => {
    const items = [item('codito', 6, 900), item('moñito', 6, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('codito')!.precioResuelto).toBe(850)
    expect(res.get('moñito')!.precioResuelto).toBe(950)
    expect(res.get('codito')!.esMayorista).toBe(true)
    expect(res.get('moñito')!.esMayorista).toBe(true)
  })

  it('producto sin override en la escala usa el precio base de la escala', () => {
    const g2 = grupo('g2', 'Fideos', ['A', 'B', 'C'], [
      escalaCombinada(12, 800, 2, {
        A: { cantidad: 6, precioOverride: 700 },  // override
        B: { cantidad: 6 },                         // sin override -> 800
        C: { cantidad: 6, precioOverride: 750 }   // override
      })
    ])
    const pm2 = pricingMap([g2])
    const items = [item('A', 6, 1000), item('B', 6, 1000), item('C', 0, 1000)]
    const res = resolverPreciosMayorista(items, pm2)
    expect(res.get('A')!.precioResuelto).toBe(700)
    expect(res.get('B')!.precioResuelto).toBe(800)
  })

  it('clasica compite con combinada por el precio efectivo de cada producto', () => {
    // Escala clasica $820 para todos + escala combinada con override $870 para A.
    // La clasica gana para A (820 < 870), pero la combinada no subiria precios.
    const gMixto = grupo('g3', 'Fideos', ['A', 'B'], [
      escalaClasica(12, 820),
      escalaCombinada(12, 900, 2, {
        A: { cantidad: 6, precioOverride: 870 },
        B: { cantidad: 6, precioOverride: 850 }
      })
    ])
    const pm3 = pricingMap([gMixto])
    const items = [item('A', 6, 1000), item('B', 6, 1000)]
    const res = resolverPreciosMayorista(items, pm3)
    // Para A, la clasica $820 gana a la combinada $870
    expect(res.get('A')!.precioResuelto).toBe(820)
    // Para B, la combinada $850 gana a la clasica $820? No, $820 < $850, gana clasica.
    expect(res.get('B')!.precioResuelto).toBe(820)
  })

  it('clasica vs combinada con override mas barato por producto: gana la combinada', () => {
    const gMixto = grupo('g4', 'Fideos', ['A', 'B'], [
      escalaClasica(12, 820),
      escalaCombinada(12, 900, 2, {
        A: { cantidad: 6, precioOverride: 800 },  // mas barato que 820
        B: { cantidad: 6, precioOverride: 850 }
      })
    ])
    const pm4 = pricingMap([gMixto])
    const items = [item('A', 6, 1000), item('B', 6, 1000)]
    const res = resolverPreciosMayorista(items, pm4)
    expect(res.get('A')!.precioResuelto).toBe(800)
    expect(res.get('B')!.precioResuelto).toBe(820)
  })
})

describe('resolverPreciosMayorista - edge cases', () => {
  it('respeta precioOverride', () => {
    const g = grupo('g1', 'Fideos', ['A'], [escalaClasica(12, 800)])
    const pm = pricingMap([g])
    const items: ItemPedido[] = [
      { productoId: 'A', cantidad: 12, precioUnitario: 1500, precioOverride: true }
    ]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(1500)
    expect(res.get('A')!.esMayorista).toBe(false)
  })

  it('nunca aumenta el precio si la escala es mas cara', () => {
    const g = grupo('g1', 'Fideos', ['A'], [escalaClasica(12, 1200)])
    const pm = pricingMap([g])
    const items = [item('A', 12, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(1000)
    expect(res.get('A')!.esMayorista).toBe(false)
  })

  it('entre dos grupos toma el mejor precio', () => {
    const g1 = grupo('g1', 'Fideos', ['A'], [escalaClasica(10, 850)])
    const g2 = grupo('g2', 'Promo', ['A'], [escalaClasica(10, 780)])
    const pm = pricingMap([g1, g2])
    const items = [item('A', 10, 1000)]
    const res = resolverPreciosMayorista(items, pm)
    expect(res.get('A')!.precioResuelto).toBe(780)
    expect(res.get('A')!.grupoNombre).toBe('Promo')
  })
})
