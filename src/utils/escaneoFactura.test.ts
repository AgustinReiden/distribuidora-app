import { describe, it, expect } from 'vitest'
import {
  extensionArchivoFactura,
  formaPagoDesdeCondicion,
  mapearFacturaV2,
  nuevoUuid,
  rutaEscaneoFactura,
  type FacturaV2Escaneo,
} from './escaneoFactura'

function facturaV2(over: Partial<FacturaV2Escaneo> = {}): FacturaV2Escaneo {
  return {
    version: 2,
    tipoComprobante: 'A',
    tipoFactura: 'FC',
    puntoVenta: '0005',
    numero: '00455160',
    numeroCompleto: '0005-00455160',
    fechaEmision: '2026-09-30',
    proveedor: { nombre: 'Refres Now SA', cuit: '30-71234567-1' },
    condicionVenta: 'Cuenta corriente',
    items: [
      {
        codigo: 'MC3000', descripcion: 'MANAOS COLA 3000CC X6', cantidad: 10, unidad: 'bulto', unidadesPorBulto: 6,
        precioUnitarioNeto: 1000, bonificacionPct: 10, importeNeto: 9000, alicuotaIva: 21, impuestoInternoMonto: null, legible: true,
      },
      {
        codigo: null, descripcion: 'AGUA 2L', cantidad: null, unidad: null, unidadesPorBulto: null,
        precioUnitarioNeto: null, bonificacionPct: null, importeNeto: null, alicuotaIva: null, impuestoInternoMonto: null, legible: false,
      },
    ],
    pie: {
      netoGravado: 9500, noGravado: null, exento: null,
      iva: [{ alicuota: 21, monto: 1795.5 }, { alicuota: 10.5, monto: 99.75 }],
      impuestosInternos: [{ tasa: 8.6956, monto: 300 }],
      percepcionIva: 150, percepcionIibb: 200, otrosTributos: null,
      descuentosPie: [{ descripcion: 'Bonif. promo 3000cc', monto: 500 }],
      total: 12045.25,
    },
    confianza: 0.93,
    ...over,
  }
}

describe('mapearFacturaV2', () => {
  it('lleva la cabecera, el tipo y las advertencias', () => {
    const adv = [{ nivel: 'error' as const, codigo: 'TOTAL_NO_CUADRA', mensaje: 'no cierra' }]
    const m = mapearFacturaV2(facturaV2(), adv)
    expect(m.proveedorNombre).toBe('Refres Now SA')
    expect(m.proveedorCuit).toBe('30-71234567-1')
    expect(m.numeroFactura).toBe('0005-00455160')
    expect(m.fechaCompra).toBe('2026-09-30')
    expect(m.tipoFactura).toBe('FC')
    expect(m.formaPago).toBe('cuenta_corriente')
    expect(m.confianza).toBe(0.93)
    expect(m.advertencias).toBe(adv)
  })

  it('bonificacionPct → bonificacion (%), precioUnitarioNeto → costoUnitario, alícuota → iva', () => {
    const [l1] = mapearFacturaV2(facturaV2(), []).items
    expect(l1).toEqual({
      codigo: 'MC3000', descripcion: 'MANAOS COLA 3000CC X6', cantidad: 10, costoUnitario: 1000, bonificacion: 10, iva: 21,
      // Entrega C: lo que la revisión muestra (la conversión se OFRECE, no se aplica acá).
      unidad: 'bulto', unidadesPorBulto: 6, importeNeto: 9000, legible: true,
    })
  })

  it('Entrega C: lleva el pie que pre-llena campos de la compra (percepciones, II por tasa, descuentos)', () => {
    const m = mapearFacturaV2(facturaV2(), [])
    expect(m.pie).toEqual({
      percepcionIva: 150,
      percepcionIibb: 200,
      noGravado: null,
      impuestosInternos: [{ tasa: 8.6956, monto: 300 }],
      descuentosPie: [{ descripcion: 'Bonif. promo 3000cc', monto: 500 }],
    })
  })

  it('lo que no se leyó no se inventa: la alícuota queda null (sale del producto)', () => {
    const [, l2] = mapearFacturaV2(facturaV2(), []).items
    expect(l2.iva).toBeNull()
    expect(l2.bonificacion).toBe(0)
    expect(l2.costoUnitario).toBe(0)
  })

  it('arma el control contra factura con los totales impresos', () => {
    const m = mapearFacturaV2(facturaV2(), [])
    expect(m.control).toEqual({ gravado: 9500, iva: 1895.25, impuestosInternos: 300, percepciones: 350, total: 12045.25 })
    expect(m.subtotal).toBe(9500)
    expect(m.iva).toBe(1895.25)
    expect(m.total).toBe(12045.25)
  })

  it('un remito sin pie desglosado sólo prellena el total', () => {
    const f = facturaV2({ tipoComprobante: 'remito', tipoFactura: 'ZZ' })
    f.pie = { ...f.pie, netoGravado: null, iva: [], impuestosInternos: [], percepcionIva: null, percepcionIibb: null, total: 1500 }
    const m = mapearFacturaV2(f, [])
    expect(m.control).toEqual({ total: 1500 })
    expect(m.iva).toBeNull()
    expect(m.tipoFactura).toBe('ZZ')
    expect(m.letraComprobante).toBeNull()
  })

  it('mig 293: A, B, C y M se cargan como factura con su letra (B y C ya no son ZZ)', () => {
    for (const letra of ['A', 'B', 'C', 'M'] as const) {
      const m = mapearFacturaV2(facturaV2({ tipoComprobante: letra, tipoFactura: 'FC' }), [])
      expect([m.tipoFactura, m.letraComprobante]).toEqual(['FC', letra])
    }
  })

  it('mig 293: manda tipoComprobante aunque la edge function vieja diga ZZ para una B', () => {
    const m = mapearFacturaV2(facturaV2({ tipoComprobante: 'B', tipoFactura: 'ZZ' }), [])
    expect([m.tipoFactura, m.letraComprobante]).toEqual(['FC', 'B'])
  })

  it('un comprobante no reconocido no toca ni el tipo ni la letra', () => {
    const m = mapearFacturaV2(facturaV2({ tipoComprobante: 'otro', tipoFactura: null }), [])
    expect([m.tipoFactura, m.letraComprobante]).toEqual([null, null])
  })
})

describe('formaPagoDesdeCondicion', () => {
  it.each([
    ['Contado', 'efectivo'],
    ['Cta. Cte.', 'cuenta_corriente'],
    ['Cuenta Corriente', 'cuenta_corriente'],
    ['30 días', 'cuenta_corriente'],
    ['Crédito', 'cuenta_corriente'],
    ['Transferencia bancaria', 'transferencia'],
    ['Cheque', 'cheque'],
    ['Tarjeta', 'tarjeta'],
    ['???', null],
    [null, null],
  ])('%s → %s', (cond, esperado) => {
    expect(formaPagoDesdeCondicion(cond)).toBe(esperado)
  })
})

describe('archivo y ruta', () => {
  it('extensión por MIME, y por nombre si el navegador no lo informa', () => {
    expect(extensionArchivoFactura({ type: 'image/jpeg', name: 'x.jpeg' })).toBe('jpg')
    expect(extensionArchivoFactura({ type: 'application/pdf', name: 'f.pdf' })).toBe('pdf')
    expect(extensionArchivoFactura({ type: 'image/heif', name: 'f.heif' })).toBe('heic')
    expect(extensionArchivoFactura({ type: '', name: 'IMG_1.HEIC' })).toBe('heic')
    expect(extensionArchivoFactura({ type: 'image/gif', name: 'f.gif' })).toBeNull()
    expect(extensionArchivoFactura({ type: '', name: 'factura.exe' })).toBeNull()
  })

  it('nuevoUuid da un v4 en minúsculas (también sin crypto.randomUUID)', () => {
    const v4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    expect(nuevoUuid()).toMatch(v4)
    const original = crypto.randomUUID
    try {
      Object.defineProperty(crypto, 'randomUUID', { value: undefined, configurable: true })
      expect(nuevoUuid()).toMatch(v4)
    } finally {
      Object.defineProperty(crypto, 'randomUUID', { value: original, configurable: true })
    }
  })

  it('la ruta va bajo la sucursal, con uuid en minúsculas', () => {
    expect(rutaEscaneoFactura(3, '0B7C1D2E-3F40-4A5B-8C6D-7E8F9A0B1C2D', 'pdf'))
      .toBe('3/0b7c1d2e-3f40-4a5b-8c6d-7e8f9a0b1c2d.pdf')
  })
})
