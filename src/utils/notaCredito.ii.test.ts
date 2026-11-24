import { describe, it, expect } from 'vitest'
import { calcularIINotaCredito, costoEfectivoCompra, restanteAcreditableCompra, totalesAjusteNotaCredito } from './notaCredito'

// mig 280 (#867). Datos sintéticos: los mismos que el ensayo de la migración,
// así el espejo TS y `ii_nota_credito_compra` se pueden comparar a ojo.
//   A: 10 u., neto 1000, tasa 10% -> II teórico 100
//   B:  5 u., neto 1000, sin II
//   cabecera: 105 (el motor liquidó un 5% más que el teórico)
const compra = {
  impuestos_internos: 105,
  items: [
    { producto_id: 'A', cantidad: 10, subtotal: 1000, impuestos_internos: 10 },
    { producto_id: 'B', cantidad: 5, subtotal: 1000, impuestos_internos: 0 },
  ],
}

describe('calcularIINotaCredito', () => {
  it('reparte la cabecera por el II teórico de lo devuelto (respeta el factor del motor)', () => {
    // 4/10 de A = 40 de 100 teórico -> 40% de 105
    expect(calcularIINotaCredito(compra, { A: 4 })).toBe(42)
  })

  it('devolver todo devuelve la cabecera exacta', () => {
    expect(calcularIINotaCredito(compra, { A: 10, B: 5 })).toBe(105)
  })

  it('un producto sin tasa no acredita II', () => {
    expect(calcularIINotaCredito(compra, { B: 5 })).toBe(0)
  })

  it('suma los renglones repetidos del mismo producto', () => {
    const dos = {
      impuestos_internos: 100,
      items: [
        { producto_id: 'A', cantidad: 5, subtotal: 500, impuestos_internos: 10 },
        { producto_id: 'A', cantidad: 5, subtotal: 500, impuestos_internos: 10 },
      ],
    }
    expect(calcularIINotaCredito(dos, { A: 5 })).toBe(50)
  })

  it('no acredita más de lo comprado', () => {
    expect(calcularIINotaCredito(compra, { A: 99 })).toBe(105)
  })

  it('compra vieja sin tasas por línea: reparte por neto', () => {
    const vieja = {
      impuestos_internos: 200,
      items: [
        { producto_id: 'A', cantidad: 10, subtotal: 1000, impuestos_internos: null },
        { producto_id: 'B', cantidad: 10, subtotal: 3000, impuestos_internos: 0 },
      ],
    }
    expect(calcularIINotaCredito(vieja, { A: 10 })).toBe(50)
  })

  it('sin II en la cabecera no hay nada que acreditar', () => {
    expect(calcularIINotaCredito({ ...compra, impuestos_internos: 0 }, { A: 10 })).toBe(0)
  })

  it('acepta los numéricos como string (PostgREST)', () => {
    const str = {
      impuestos_internos: '105.00',
      items: compra.items.map(i => ({ ...i, subtotal: String(i.subtotal), impuestos_internos: String(i.impuestos_internos) })),
    }
    expect(calcularIINotaCredito(str, { A: 4 })).toBe(42)
  })

  // CMP-b4 (tanda 6 de #1603): el espejo del tope de `ii_nota_credito_compra`. FC A de
  // 3 u. con II 200 en la cabecera: cada nota de 1 da 66,67, y la tercera no puede
  // pasar lo que le queda a la compra (200 − 133,34 = 66,66).
  describe('tope en lo que le queda del II a la compra', () => {
    const tres = { impuestos_internos: 200, items: [{ producto_id: 'A', cantidad: 3, subtotal: 300, impuestos_internos: 0 }] }
    const dev = (ii: number | string, extra: object = {}) => ({ tipo: 'devolucion', impuestos_internos: ii, anulada: false, ...extra })

    it('la tercera devolución de 1 acredita 66,66 y la suma da 200', () => {
      expect(calcularIINotaCredito(tres, { A: 1 }, [])).toBe(66.67)
      expect(calcularIINotaCredito(tres, { A: 1 }, [dev(66.67)])).toBe(66.67)
      expect(calcularIINotaCredito(tres, { A: 1 }, [dev(66.67), dev('66.67')])).toBe(66.66)
    })

    it('una nota anulada y un ajuste no cuentan', () => {
      const notas = [dev(66.67), dev(66.67, { anulada: true }), { tipo: 'ajuste', impuestos_internos: 100, anulada: false }]
      expect(calcularIINotaCredito(tres, { A: 1 }, notas)).toBe(66.67)
    })

    it('con todo el II ya acreditado no acredita nada (piso 0)', () => {
      expect(calcularIINotaCredito(tres, { A: 1 }, [dev(150), dev(60)])).toBe(0)
    })
  })
})

describe('costoEfectivoCompra', () => {
  it('resta sólo los ajustes, no las devoluciones', () => {
    expect(costoEfectivoCompra(2525, [
      { total: 526, tipo: 'devolucion' },
      { total: 65.5, tipo: 'ajuste' },
      { total: '100.25', tipo: 'ajuste' },
    ])).toBe(2359.25)
  })

  it('una nota sin tipo (respuesta vieja) no se toma como ajuste', () => {
    expect(costoEfectivoCompra(1000, [{ total: 100 }])).toBe(1000)
  })
})

describe('totalesAjusteNotaCredito', () => {
  it('FC: total = neto + IVA + II', () => {
    expect(totalesAjusteNotaCredito({ tipoFactura: 'FC', neto: 50, iva: 10.5, impuestosInternos: 5, totalZZ: 999 }))
      .toEqual({ subtotal: 50, iva: 10.5, impuestosInternos: 5, total: 65.5 })
  })

  it('ZZ: el ajuste es un total, sin IVA ni II', () => {
    expect(totalesAjusteNotaCredito({ tipoFactura: 'ZZ', neto: 1, iva: 21, impuestosInternos: 3, totalZZ: 300 }))
      .toEqual({ subtotal: 300, iva: 0, impuestosInternos: 0, total: 300 })
  })
})

describe('restanteAcreditableCompra (#1557, CMP-2)', () => {
  it('el total de la compra menos todas sus notas, de devolución y de ajuste', () => {
    expect(restanteAcreditableCompra(1210, [{ total: 1000 }])).toBe(210)
    expect(restanteAcreditableCompra('1000.00', [{ total: '300.00' }, { total: 700 }])).toBe(0)
  })
  it('sin notas es el total entero', () => {
    expect(restanteAcreditableCompra(1210, [])).toBe(1210)
  })
  it('sin el total de la compra no hay tope que calcular', () => {
    expect(restanteAcreditableCompra(undefined, [])).toBeNull()
    expect(restanteAcreditableCompra(null, [])).toBeNull()
    expect(restanteAcreditableCompra('NaN', [])).toBeNull()
  })
})
