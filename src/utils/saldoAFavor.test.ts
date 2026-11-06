import { describe, expect, it } from 'vitest'
import { mensajeSaldoAFavorAlta, montoCobroAlta, saldoAFavorAplicado, textoSaldoAFavorAplicado } from './saldoAFavor'

describe('saldoAFavorAplicado', () => {
  it('suma sólo los pagos marcados', () => {
    expect(saldoAFavorAplicado([
      { monto: 400, de_saldo_a_favor: true },
      { monto: '100.50', de_saldo_a_favor: true },
      { monto: 1000, de_saldo_a_favor: false },
      { monto: 50 },
    ])).toBe(500.5)
  })

  it('da 0 sin pagos o sin la columna (un bundle viejo contra una base vieja)', () => {
    expect(saldoAFavorAplicado(undefined)).toBe(0)
    expect(saldoAFavorAplicado([])).toBe(0)
    expect(saldoAFavorAplicado([{ monto: 100 }])).toBe(0)
  })
})

describe('textoSaldoAFavorAplicado', () => {
  it('arma el texto sólo si hay algo aplicado', () => {
    expect(textoSaldoAFavorAplicado(400)).toMatch(/^Saldo a favor aplicado: \$/)
    expect(textoSaldoAFavorAplicado(400)).toContain('400')
    expect(textoSaldoAFavorAplicado(0)).toBeNull()
  })
})

describe('mensajeSaldoAFavorAlta', () => {
  it('dice lo que cayó en la boleta nueva', () => {
    const m = mensajeSaldoAFavorAlta(12, 400, 0)
    expect(m).toContain('#12')
    expect(m).toContain('400')
    expect(m).not.toContain('anteriores')
  })

  it('dice lo que fue a boletas más viejas', () => {
    const m = mensajeSaldoAFavorAlta(12, 0, 30)
    expect(m).not.toContain('#12')
    expect(m).toContain('boletas anteriores')
    expect(m?.charAt(0)).toBe(m?.charAt(0).toUpperCase())
  })

  it('las dos cosas, o nada', () => {
    expect(mensajeSaldoAFavorAlta(12, 100, 50)).toMatch(/#12.*y .*anteriores/)
    expect(mensajeSaldoAFavorAlta(12, 0, 0)).toBeNull()
  })
})

describe('montoCobroAlta', () => {
  const base = { montoDeclarado: 0, totalConEnvio: 1000, totalGuardado: 1000, saldoAplicado: 0 }

  it('sin saldo aplicado, como antes', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado' })).toBe(1000)
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 300 })).toBe(300)
    expect(montoCobroAlta({ ...base, estadoPago: 'pendiente', montoDeclarado: 300 })).toBe(0)
  })

  it('pagado: descuenta lo que la boleta absorbió', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado', saldoAplicado: 400 })).toBe(600)
  })

  it('parcial: tope en lo que falta', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 900, saldoAplicado: 400 })).toBe(600)
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 200, saldoAplicado: 400 })).toBe(200)
  })

  it('una boleta saldada por el crédito no cobra nada', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado', saldoAplicado: 1000 })).toBe(0)
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 50, saldoAplicado: 1000 })).toBe(0)
  })
})
