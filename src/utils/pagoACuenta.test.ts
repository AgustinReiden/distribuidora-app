import { describe, it, expect } from 'vitest'
import { pagoACuentaPideConfirmacion, avisoPagoACuentaGrande } from './pagoACuenta'

describe('pago a cuenta de más del doble de la deuda (1559-b15, decisión D22)', () => {
  it('hasta el doble de la deuda no pide confirmar', () => {
    expect(pagoACuentaPideConfirmacion(10000, 10000)).toBe(false)
    expect(pagoACuentaPideConfirmacion(20000, 10000)).toBe(false)
    expect(pagoACuentaPideConfirmacion(20000.004, 10000)).toBe(false)
  })

  it('más del doble pide confirmar (un cero de más)', () => {
    expect(pagoACuentaPideConfirmacion(20000.01, 10000)).toBe(true)
    expect(pagoACuentaPideConfirmacion(100000, 10000)).toBe(true)
  })

  it('sin deuda o con saldo a favor, cualquier pago pide confirmar', () => {
    expect(pagoACuentaPideConfirmacion(1, 0)).toBe(true)
    expect(pagoACuentaPideConfirmacion(500, -300)).toBe(true)
  })

  it('un monto vacío o inválido no pide nada', () => {
    expect(pagoACuentaPideConfirmacion(0, 100)).toBe(false)
    expect(pagoACuentaPideConfirmacion(Number.NaN, 100)).toBe(false)
    expect(pagoACuentaPideConfirmacion(-5, 100)).toBe(false)
  })

  it('el aviso dice cuánto queda a favor', () => {
    const texto = avisoPagoACuentaGrande(100000, 10000)
    expect(texto).toMatch(/más del doble/)
    expect(texto).toMatch(/90\.000,00/)
    expect(avisoPagoACuentaGrande(500, -300)).toMatch(/no debe nada/)
  })
})
