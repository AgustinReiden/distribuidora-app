import { describe, it, expect } from 'vitest'
import { separarPagosFicha } from './ventaCliente'

describe('separarPagosFicha: «Pagado» es sólo la plata cobrada (frv-B3)', () => {
  it('el ejemplo del dueño: 10.000 en efectivo y una nota de 5.000 aplicada → Pagado 10.000, la nota aparte', () => {
    const r = separarPagosFicha([
      { monto: 10000, forma_pago: 'efectivo', pedido_id: 1 },
      { monto: 5000, forma_pago: 'nota_credito', de_saldo_a_favor: true, pedido_id: 1 },
    ])
    expect(r).toEqual({ cobrado: 10000, notaCreditoAplicada: 5000, adelantoSueldo: 0, saldoAFavorAplicado: 0 })
  })

  it('un pago a cuenta que después una boleta absorbe sigue en Pagado: 10.000 antes y después', () => {
    const aCuenta = { monto: 10000, forma_pago: 'efectivo', pedido_id: null, de_saldo_a_favor: false }
    const antes = separarPagosFicha([aCuenta])
    // Al día siguiente una boleta de 8.000 absorbe 8.000 de ese crédito: el pago se parte en dos.
    const despues = separarPagosFicha([
      { monto: 2000, forma_pago: 'efectivo', pedido_id: null, de_saldo_a_favor: false },
      { monto: 8000, forma_pago: 'efectivo', pedido_id: 7, de_saldo_a_favor: true },
    ])
    expect(antes.cobrado).toBe(10000)
    expect(despues.cobrado).toBe(10000)
    // De eso, 8.000 se aplicaron desde saldo a favor: informativo, no se resta.
    expect(despues.saldoAFavorAplicado).toBe(8000)
  })

  it('la boleta cobrada en efectivo que se cancela y cuyo crédito absorbe otra boleta: Pagado sigue en 5.000', () => {
    expect(separarPagosFicha([{ monto: 5000, forma_pago: 'efectivo', pedido_id: 3, de_saldo_a_favor: false }]).cobrado).toBe(5000)
    // Cancelada: el cobro queda suelto y paga otra boleta (ahora con la marca de saldo a favor).
    expect(separarPagosFicha([{ monto: 5000, forma_pago: 'efectivo', pedido_id: 9, de_saldo_a_favor: true }]).cobrado).toBe(5000)
  })

  it('una nota nunca se cuenta como saldo a favor aplicado, aunque lleve la marca', () => {
    const r = separarPagosFicha([
      { monto: 300, forma_pago: 'efectivo', pedido_id: 2 },
      { monto: 50, forma_pago: 'nota_credito', de_saldo_a_favor: true, pedido_id: 2 },
    ])
    expect(r).toEqual({ cobrado: 300, notaCreditoAplicada: 50, adelantoSueldo: 0, saldoAFavorAplicado: 0 })
  })

  it('un adelanto de sueldo no es plata cobrada: va aparte, con su monto', () => {
    expect(separarPagosFicha([
      { monto: 3000, forma_pago: 'adelanto_sueldo', pedido_id: 3 },
      { monto: 400, forma_pago: 'transferencia', pedido_id: 3 },
    ])).toEqual({ cobrado: 400, notaCreditoAplicada: 0, adelantoSueldo: 3000, saldoAFavorAplicado: 0 })
  })

  it('el crédito de una nota que quedó suelto (sin boleta) no es cobro ni está aplicado', () => {
    expect(separarPagosFicha([{ monto: 700, forma_pago: 'nota_credito', pedido_id: null }]))
      .toEqual({ cobrado: 0, notaCreditoAplicada: 0, adelantoSueldo: 0, saldoAFavorAplicado: 0 })
  })

  it('un pago a cuenta suelto sí es plata cobrada; montos en texto o nulos no rompen', () => {
    expect(separarPagosFicha([
      { monto: '250.50', forma_pago: 'efectivo', pedido_id: null },
      { monto: null, forma_pago: 'efectivo' },
    ])).toEqual({ cobrado: 250.5, notaCreditoAplicada: 0, adelantoSueldo: 0, saldoAFavorAplicado: 0 })
  })
})
