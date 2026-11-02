import { describe, it, expect } from 'vitest'
import { alicuotaIvaCompra } from './condicionIva'

describe('alicuotaIvaCompra (#1274: la condición manda, no se inventa el 21)', () => {
  it('exento y no gravado no llevan alícuota, traigan la que traigan', () => {
    expect(alicuotaIvaCompra('exento', null)).toBe(0)
    expect(alicuotaIvaCompra('exento', undefined)).toBe(0)
    expect(alicuotaIvaCompra('no_gravado', null)).toBe(0)
    // El escaneo lee 21 de la factura, pero la línea es exenta: el par tiene que
    // quedar coherente, que es lo que exige el CHECK de compra_items.
    expect(alicuotaIvaCompra('exento', 21)).toBe(0)
    expect(alicuotaIvaCompra('no_gravado', 10.5)).toBe(0)
  })

  it('gravado lleva la suya, sin redondearla a 21', () => {
    expect(alicuotaIvaCompra('gravado', 10.5)).toBe(10.5)
    expect(alicuotaIvaCompra('gravado', 21)).toBe(21)
    // `??` y no `||`: un 0 de la factura sigue siendo 0.
    expect(alicuotaIvaCompra('gravado', 0)).toBe(0)
  })

  it('gravado sin porcentaje es 21, el default de la columna y de las RPCs', () => {
    expect(alicuotaIvaCompra('gravado', null)).toBe(21)
    expect(alicuotaIvaCompra('gravado', undefined)).toBe(21)
  })

  it('sin condición se trata como gravado, igual que registrar_compra_completa', () => {
    expect(alicuotaIvaCompra(undefined, 10.5)).toBe(10.5)
    expect(alicuotaIvaCompra(null, null)).toBe(21)
  })
})
