import { describe, it, expect } from 'vitest'
import { motivoCostoCero, motivoLineaFueraDeRango, unAnioAntes, validarFechaCompra } from './rangosCompra'

// #1471 (STK-F-4): el alta no validaba rangos, y la base tampoco.
describe('motivoLineaFueraDeRango', () => {
  const ok = { cantidad: 10, costoUnitario: 100, bonificacion: 0 }

  it('una línea normal está bien, y también un regalo al 100 % a costo 0', () => {
    expect(motivoLineaFueraDeRango(ok)).toBeNull()
    expect(motivoLineaFueraDeRango({ cantidad: 2, costoUnitario: 0, bonificacion: 100 })).toBeNull()
    expect(motivoLineaFueraDeRango({ cantidad: 2, costoUnitario: 50 })).toBeNull()
  })

  it.each([
    [{ cantidad: 2.5 }, 'la cantidad tiene que ser entera'],
    [{ cantidad: 0 }, 'la cantidad tiene que ser mayor a 0'],
    [{ cantidad: -3 }, 'la cantidad tiene que ser mayor a 0'],
    [{ cantidad: Number.NaN }, 'la cantidad no es un número'],
    [{ costoUnitario: -1 }, 'el costo no puede ser negativo'],
    [{ bonificacion: 150 }, 'la bonificación es un porcentaje, de 0 a 100'],
    [{ bonificacion: -5 }, 'la bonificación es un porcentaje, de 0 a 100'],
  ])('%o → %s', (cambio, motivo) => {
    expect(motivoLineaFueraDeRango({ ...ok, ...cambio })).toBe(motivo)
  })
})

// CMP-5 (#1557): el regalo legal es la bonificación del 100 %. El modal precarga
// 0 si el producto no tiene costo, y un olvido bajaba el promedio sin aviso.
describe('motivoCostoCero', () => {
  const motivo = 'el costo es 0: si viene sin cargo, cargalo con bonificación del 100 %'

  it('un costo 0 (o que al centavo da 0) sin bonificación del 100 % no pasa', () => {
    expect(motivoCostoCero(0, 0)).toBe(motivo)
    expect(motivoCostoCero(0, 99.99)).toBe(motivo)
    expect(motivoCostoCero(0.004, null)).toBe(motivo)
    expect(motivoLineaFueraDeRango({ cantidad: 10, costoUnitario: 0, bonificacion: 0 })).toBe(motivo)
    expect(motivoLineaFueraDeRango({ cantidad: 10, costoUnitario: 0 })).toBe(motivo)
  })

  it('el regalo legal y un costo de un centavo pasan', () => {
    expect(motivoCostoCero(0, 100)).toBeNull()
    expect(motivoCostoCero(100, 100)).toBeNull()
    expect(motivoCostoCero(0.01, 0)).toBeNull()
    expect(motivoCostoCero(0.005, 0)).toBeNull()
  })
})

describe('validarFechaCompra', () => {
  const hoy = '2026-11-06'

  it('hoy y hasta un año atrás valen', () => {
    expect(validarFechaCompra(hoy, hoy)).toBeNull()
    expect(validarFechaCompra('2025-11-06', hoy)).toBeNull()
  })

  it('mañana no: es el año mal tipeado que deja la compra como la más nueva', () => {
    expect(validarFechaCompra('2026-11-07', hoy)).toBe('La fecha de la compra (07/11/2026) es posterior a hoy. Revisá el año.')
    expect(validarFechaCompra('2062-11-06', hoy)).toMatch(/posterior a hoy/)
  })

  it('más de un año atrás no', () => {
    expect(validarFechaCompra('2025-11-05', hoy)).toBe('La fecha de la compra (05/11/2025) tiene más de un año. Revisá el año.')
  })

  it('una fecha que no es YYYY-MM-DD no vale', () => {
    expect(validarFechaCompra('06/11/2026', hoy)).toBe('La fecha de la compra no es válida.')
  })
})

describe('unAnioAntes', () => {
  it('es el mismo día del año anterior', () => {
    expect(unAnioAntes('2026-11-06')).toBe('2025-11-06')
    expect(unAnioAntes('2026-01-01')).toBe('2025-01-01')
  })

  it('el 29 de febrero cae en el 28, como en Postgres', () => {
    expect(unAnioAntes('2028-02-29')).toBe('2027-02-28')
  })
})
