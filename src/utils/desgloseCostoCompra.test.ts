import { describe, it, expect } from 'vitest'
import { compraQueFijaCosto, desgloseCostoDeCompra, lineaFijaCosto } from './desgloseCostoCompra'
import type { FilaCompraDelProducto } from './desgloseCostoCompra'
import { compraTestigoEdicion, COSTOS_GUARDADOS_304 } from '../test/fixtures/compraTestigoEdicion'
import type { CompraDBExtended } from '../types'

const suma = (d: NonNullable<ReturnType<typeof desgloseCostoDeCompra>>) =>
  d.netoUnitario + (d.iiUnitario ?? 0) + d.cargos.reduce((a, c) => a + c.unitario, 0) + d.otrosAjustes

describe('desgloseCostoDeCompra (compra testigo 304: flete 9.000, pallets 4.000, bonif −6.000)', () => {
  it('abre el costo final en neto + cada cargo con su nombre, y cierra contra lo guardado', () => {
    const d = desgloseCostoDeCompra(compraTestigoEdicion(), '501')
    expect(d).not.toBeNull()
    if (!d) return
    expect(d.netoUnitario).toBe(1000)
    expect(d.iiUnitario).toBe(0)
    // Flete 9.000 con pesos 4/1/1/0,5 → 5.538,46 a la línea de 240 u.
    // Pallets 4.000 con pesos 2/2/1/1 → 1.333,33. La bonificación pesa 0 acá.
    // El prorrateo reparte en centavos por línea: se compara al centavo.
    expect(d.cargos.map(c => c.concepto)).toEqual(['Flete', 'Pallets'])
    expect(d.cargos[0].unitario).toBeCloseTo(9000 * 4 / 6.5 / 240, 2)
    expect(d.cargos[1].unitario).toBeCloseTo(4000 * 2 / 6 / 240, 2)
    expect(d.otrosAjustes).toBe(0)
    expect(d.costoFinalUnitario).toBe(COSTOS_GUARDADOS_304['501'])
    expect(suma(d)).toBeCloseTo(d.costoFinalUnitario, 3)
  })

  it('con impuesto interno y una bonificación prorrateada que baja el costo', () => {
    const d = desgloseCostoDeCompra(compraTestigoEdicion(), '503')
    if (!d) throw new Error('sin desglose')
    expect(d.netoUnitario).toBe(2000)
    // II 10 % sobre (120.000 − 6.000 de la bonificación que afecta la base) / 60 u.
    expect(d.iiUnitario).toBeCloseTo(190, 4)
    const porConcepto = Object.fromEntries(d.cargos.map(c => [c.concepto, c.unitario]))
    expect(porConcepto['Bonificacion 3L']).toBeCloseTo(-100, 4)
    expect(porConcepto['Flete']).toBeCloseTo(9000 / 6.5 / 60, 2)
    expect(porConcepto['Pallets']).toBeCloseTo(4000 / 6 / 60, 2)
    expect(d.costoFinalUnitario).toBe(COSTOS_GUARDADOS_304['503'])
    expect(suma(d)).toBeCloseTo(d.costoFinalUnitario, 3)
  })

  it('dice de qué compra sale: comprobante, factura, fecha y proveedor', () => {
    const d = desgloseCostoDeCompra(compraTestigoEdicion(), '501')
    expect(d).toMatchObject({
      compraId: '304',
      comprobante: 'FC A',
      numeroFactura: 'A0005-00012345',
      fechaCompra: '2026-09-12',
      proveedor: 'Bebidas Testigo SA',
      costoEsLoPagado: false,
    })
  })

  it('una compra de antes del motor: lo guardado manda y la diferencia va aparte', () => {
    const compra = compraTestigoEdicion()
    const items = (compra.items ?? []).map(i => (String(i.producto_id) === '501' ? { ...i, costo_real_unitario: 1000 } : i))
    const d = desgloseCostoDeCompra({ ...compra, items } as CompraDBExtended, '501')
    if (!d) throw new Error('sin desglose')
    expect(d.costoFinalUnitario).toBe(1000)
    expect(d.otrosAjustes).toBeCloseTo(-28.63, 2)
    expect(suma(d)).toBeCloseTo(1000, 3)
  })

  it('un producto que no está, o que vino sólo de regalo, no tiene desglose', () => {
    expect(desgloseCostoDeCompra(compraTestigoEdicion(), '999')).toBeNull()
    const compra = compraTestigoEdicion()
    const items = (compra.items ?? []).map(i => (String(i.producto_id) === '501' ? { ...i, bonificacion: 100 } : i))
    expect(desgloseCostoDeCompra({ ...compra, items } as CompraDBExtended, '501')).toBeNull()
  })
})

describe('compraQueFijaCosto', () => {
  const fila = (compraId: number, over: Partial<FilaCompraDelProducto> = {}): FilaCompraDelProducto => ({
    compra_id: compraId, costo_unitario: 100, bonificacion: 0, compra: { id: compraId, estado: 'recibida' }, ...over,
  })

  it('es la más nueva que fija costo: saltea regalos y compras canceladas', () => {
    expect(compraQueFijaCosto([
      fila(30, { bonificacion: 100 }),
      fila(29, { compra: { id: 29, estado: 'cancelada' } }),
      fila(28, { costo_unitario: 0 }),
      fila(27),
      fila(26),
    ])).toBe('27')
  })

  it('sin candidatas no hay compra', () => {
    expect(compraQueFijaCosto([])).toBeNull()
    expect(compraQueFijaCosto([fila(1, { compra: null })])).toBeNull()
  })
})

describe('lineaFijaCosto', () => {
  it('replica v_actualiza_costo: bonificación < 100 y neto > 0', () => {
    expect(lineaFijaCosto({ costo_unitario: 100, bonificacion: 0 })).toBe(true)
    expect(lineaFijaCosto({ costo_unitario: '100', bonificacion: null })).toBe(true)
    expect(lineaFijaCosto({ costo_unitario: 100, bonificacion: 100 })).toBe(false)
    expect(lineaFijaCosto({ costo_unitario: 0, bonificacion: 0 })).toBe(false)
  })
})
