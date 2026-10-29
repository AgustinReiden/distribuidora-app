import { describe, it, expect } from 'vitest'
import {
  GRUPOS_GASTO,
  COMPROBANTES_GASTO,
  ALICUOTAS_IVA_GASTO,
  daCreditoFiscal,
  ivaSugerido,
  costoDeGasto,
  netoDeGasto,
  mesDe,
  sumarMeses,
  etiquetaMes,
  mesSugerido,
  cuotaDeGasto,
  cuotaDelMes,
  normalizarPatente,
  errorDeDesglose,
} from './gastos'
import type { ComprobanteGasto } from '../types/gastos'

describe('constantes', () => {
  it('los grupos van en el orden del spec', () => {
    expect(GRUPOS_GASTO.map(g => g.valor)).toEqual([
      'vehiculos', 'inmueble', 'impuestos', 'administracion', 'bienes_de_uso', 'otros',
    ])
    expect(GRUPOS_GASTO[0].etiqueta).toBe('Vehículos')
    expect(GRUPOS_GASTO[4].etiqueta).toBe('Bienes de uso')
  })

  it('son seis botones de comprobante, sin la letra M', () => {
    expect(COMPROBANTES_GASTO.map(c => c.etiqueta)).toEqual([
      'Factura A', 'Factura B', 'Factura C', 'Recibo', 'Ticket', 'Sin comprobante',
    ])
    expect(COMPROBANTES_GASTO.map(c => c.valor)).not.toContain('factura_m')
  })

  it('las alícuotas son 21, 10,5 y 27', () => {
    expect([...ALICUOTAS_IVA_GASTO]).toEqual([21, 10.5, 27])
  })
})

describe('daCreditoFiscal', () => {
  it('sólo la factura A y la M dan crédito', () => {
    const todos: ComprobanteGasto[] = ['factura_a', 'factura_m', 'factura_b', 'factura_c', 'recibo', 'ticket', 'ninguno']
    const con = todos.filter(daCreditoFiscal)
    expect(con).toEqual(['factura_a', 'factura_m'])
  })
})

describe('ivaSugerido, costo y neto', () => {
  it('21% sobre 50.000 da 8.677,69 y el costo es 41.322,31', () => {
    expect(ivaSugerido(50000, 21, 0, 0)).toBe(8677.69)
    expect(costoDeGasto({ monto_total: 50000, iva: 8677.69, percepcion_iva: 0, percepcion_iibb: 0 })).toBe(41322.31)
  })

  it('con percepciones y otros impuestos (combustible con ITC)', () => {
    expect(ivaSugerido(50000, 21, 1000, 2000)).toBe(8157.02)
    const g = { monto_total: 50000, iva: 8157.02, percepcion_iva: 1000, percepcion_iibb: 0, otros_impuestos: 2000 }
    expect(costoDeGasto(g)).toBe(40842.98)
    expect(netoDeGasto(g)).toBe(38842.98)
  })

  it('10,5% y 27%', () => {
    expect(ivaSugerido(1000, 10.5, 0, 0)).toBe(95.02)
    expect(ivaSugerido(1000, 27, 0, 0)).toBe(212.6)
  })
})

describe('meses', () => {
  it('mesDe devuelve el primer día del mes', () => {
    expect(mesDe('2026-10-28')).toBe('2026-10-01')
    expect(mesDe('2026-01-01')).toBe('2026-01-01')
  })

  it('sumarMeses cruza de año', () => {
    expect(sumarMeses('2026-11-01', 2)).toBe('2027-01-01')
    expect(sumarMeses('2026-10-01', 11)).toBe('2027-09-01')
    expect(sumarMeses('2026-10-01', -10)).toBe('2025-12-01')
    expect(sumarMeses('2026-10-01', 0)).toBe('2026-10-01')
  })

  it('etiquetaMes', () => {
    expect(etiquetaMes('2027-01-01')).toBe('enero 2027')
    expect(etiquetaMes('2026-10-01')).toBe('octubre 2026')
    expect(etiquetaMes('2026-09-01')).toBe('septiembre 2026')
  })

  it('mesSugerido', () => {
    expect(mesSugerido('2026-10-28', { sugiere_mes_anterior: true })).toBe('2026-09-01')
    expect(mesSugerido('2026-10-28', { sugiere_mes_anterior: false })).toBe('2026-10-01')
    expect(mesSugerido('2026-01-15', { sugiere_mes_anterior: true })).toBe('2025-12-01')
  })
})

describe('cuotas del reparto', () => {
  it('1.320.000 en 12 cuotas son 110.000 cada una', () => {
    for (let k = 1; k <= 12; k++) expect(cuotaDeGasto(1320000, 12, k)).toBe(110000)
  })

  it('100 en 3 cuotas: la última absorbe el redondeo', () => {
    expect(cuotaDeGasto(100, 3, 1)).toBe(33.33)
    expect(cuotaDeGasto(100, 3, 2)).toBe(33.33)
    expect(cuotaDeGasto(100, 3, 3)).toBe(33.34)
  })

  it('las cuotas suman el costo', () => {
    const n = 7
    let s = 0
    for (let k = 1; k <= n; k++) s += cuotaDeGasto(1000, n, k)
    expect(Math.round(s * 100) / 100).toBe(1000)
  })

  it('cuotaDelMes cruza de año y devuelve null fuera del reparto', () => {
    const g = { costo: 100, mes_imputado: '2026-11-01', repartir_meses: 3 }
    expect(cuotaDelMes(g, '2027-01-01')).toEqual({ k: 3, n: 3, monto: 33.34 })
    expect(cuotaDelMes(g, '2026-11-01')).toEqual({ k: 1, n: 3, monto: 33.33 })
    expect(cuotaDelMes(g, '2027-02-01')).toBeNull()
    expect(cuotaDelMes(g, '2026-10-01')).toBeNull()
  })

  it('un gasto de un mes cae entero en su mes', () => {
    expect(cuotaDelMes({ costo: 8500, mes_imputado: '2026-10-01', repartir_meses: 1 }, '2026-10-01'))
      .toEqual({ k: 1, n: 1, monto: 8500 })
  })
})

describe('normalizarPatente', () => {
  it('mayúsculas y sin separadores', () => {
    expect(normalizarPatente(' ac 456-ef ')).toBe('AC456EF')
    expect(normalizarPatente('abc123')).toBe('ABC123')
  })
})

describe('errorDeDesglose', () => {
  const base = { comprobante: 'factura_a' as ComprobanteGasto, monto_total: 50000, iva: 8677.69, percepcion_iva: 0, percepcion_iibb: 0, otros_impuestos: 0 }

  it('importe negativo', () => {
    expect(errorDeDesglose({ ...base, iva: -1 })).toBe('Ningún importe puede ser negativo')
    expect(errorDeDesglose({ ...base, comprobante: 'ticket', iva: 0, otros_impuestos: -5 })).toBe('Ningún importe puede ser negativo')
  })

  it('factura A con neto no positivo', () => {
    expect(errorDeDesglose({ ...base, iva: 50000 })).toBe('Con factura A o M el neto tiene que ser mayor a cero')
    expect(errorDeDesglose({ ...base, comprobante: 'factura_m', iva: 40000, percepcion_iibb: 10000 }))
      .toBe('Con factura A o M el neto tiene que ser mayor a cero')
  })

  it('sin factura A o M no hay IVA ni percepciones', () => {
    expect(errorDeDesglose({ ...base, comprobante: 'factura_b' })).toBe('Sólo la factura A o M lleva IVA y percepciones')
    expect(errorDeDesglose({ ...base, comprobante: 'ticket', iva: 0, percepcion_iibb: 10 })).toBe('Sólo la factura A o M lleva IVA y percepciones')
    expect(errorDeDesglose({ ...base, comprobante: 'recibo', iva: 0, otros_impuestos: 10 })).toBe('Sólo la factura A o M lleva IVA y percepciones')
  })

  it('casos válidos', () => {
    expect(errorDeDesglose({ ...base })).toBeNull()
    expect(errorDeDesglose({ comprobante: 'ticket', monto_total: 8500, iva: 0, percepcion_iva: 0, percepcion_iibb: 0, otros_impuestos: 0 })).toBeNull()
  })
})
