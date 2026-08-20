import { describe, it, expect } from 'vitest'
import { redondearSQL } from './calculations'

describe('redondearSQL (espejo de round(numeric, n) de Postgres)', () => {
  it('redondea medio ALEJANDOSE del cero, no hacia +infinito', () => {
    // Math.round(-0.5) === -0 → esto es lo que NO queremos
    expect(redondearSQL(-0.005, 2)).toBe(-0.01)
    expect(redondearSQL(0.005, 2)).toBe(0.01)
    expect(redondearSQL(-1.235, 2)).toBe(-1.24)
    expect(redondearSQL(1.235, 2)).toBe(1.24)
  })

  it('no devuelve -0 (rompe toBe con Object.is)', () => {
    expect(Object.is(redondearSQL(-0.001, 2), 0)).toBe(true)
  })

  it('casos triviales', () => {
    expect(redondearSQL(1900000 / 26, 2)).toBe(73076.92)
    expect(redondearSQL(0, 2)).toBe(0)
  })

  // Tabla de referencia: la columna esperada se calculo con round(v,2) EN POSTGRES
  // (proyecto hmuchlzmuqqxcldbzkgc), no en JavaScript. Es lo que hace que este
  // test sea un espejo y no una tautologia. Todos estos valores caen en el medio
  // centavo, que es donde double y numeric discrepan.
  const REFERENCIA_POSTGRES: Array<[number, number]> = [
    [1.005, 1.01], [1.015, 1.02], [1.025, 1.03], [1.035, 1.04], [1.045, 1.05],
    [0.145, 0.15], [0.565, 0.57], [0.005, 0.01], [2.675, 2.68], [8.045, 8.05],
    [-1.005, -1.01], [-1.025, -1.03], [-0.145, -0.15], [-0.565, -0.57],
    [-0.005, -0.01], [-2.675, -2.68], [1234.565, 1234.57], [73076.925, 73076.93],
    [36538.455, 36538.46], [292307.685, 292307.69], [1900000.005, 1900000.01],
    [1.115, 1.12], [1.215, 1.22], [4.985, 4.99],
  ]

  it.each(REFERENCIA_POSTGRES)('coincide con round(%s, 2) de Postgres', (valor, esperado) => {
    expect(redondearSQL(valor)).toBe(esperado)
  })

  it('decimales negativos: redondea a centenas como Postgres', () => {
    // round(1234, -2) = 1200 y round(1250, -2) = 1300 EN POSTGRES. Aca el
    // desplazamiento por string no sirve: `${1234}e--2` es NaN. Por eso los
    // decimales negativos salen por el branch de multiplicacion.
    expect(redondearSQL(1234, -2)).toBe(1200)
    expect(redondearSQL(1250, -2)).toBe(1300)
    expect(redondearSQL(-1250, -2)).toBe(-1300)
  })

  it('no explota con notacion exponencial', () => {
    expect(redondearSQL(1e-7)).toBe(0)
    expect(redondearSQL(-1e-7)).toBe(0)
    expect(Number.isNaN(redondearSQL(Infinity))).toBe(true)
    expect(Number.isNaN(redondearSQL(NaN))).toBe(true)
  })
})
