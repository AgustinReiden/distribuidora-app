import { describe, it, expect } from 'vitest'
import { separarPagosFicha } from './ventaCliente'

describe('separarPagosFicha: «Pagado» es sólo la plata cobrada (frv-B3)', () => {
  it('el ejemplo del dueño: 10.000 en efectivo y una nota de 5.000 aplicada → Pagado 10.000', () => {
    const r = separarPagosFicha([
      { monto: 10000, forma_pago: 'efectivo', pedido_id: 1 },
      { monto: 5000, forma_pago: 'nota_credito', de_saldo_a_favor: true, pedido_id: 1 },
    ])
    expect(r).toEqual({ cobrado: 10000, notaCreditoAplicada: 5000, saldoAFavorAplicado: 0 })
  })

  it('el saldo a favor aplicado va aparte y una nota nunca se cuenta como saldo a favor', () => {
    const r = separarPagosFicha([
      { monto: 300, forma_pago: 'efectivo', pedido_id: 2 },
      { monto: 200, forma_pago: 'efectivo', de_saldo_a_favor: true, pedido_id: 2 },
      { monto: 50, forma_pago: 'nota_credito', de_saldo_a_favor: true, pedido_id: 2 },
    ])
    expect(r).toEqual({ cobrado: 300, notaCreditoAplicada: 50, saldoAFavorAplicado: 200 })
  })

  it('un adelanto de sueldo no es plata cobrada ni se muestra en ningún lado', () => {
    expect(separarPagosFicha([
      { monto: 1000, forma_pago: 'adelanto_sueldo', pedido_id: 3 },
      { monto: 400, forma_pago: 'transferencia', pedido_id: 3 },
    ])).toEqual({ cobrado: 400, notaCreditoAplicada: 0, saldoAFavorAplicado: 0 })
  })

  it('el crédito de una nota que quedó suelto (sin boleta) no es cobro ni está aplicado', () => {
    expect(separarPagosFicha([{ monto: 700, forma_pago: 'nota_credito', pedido_id: null }]))
      .toEqual({ cobrado: 0, notaCreditoAplicada: 0, saldoAFavorAplicado: 0 })
  })

  it('un pago a cuenta suelto sí es plata cobrada; montos en texto o nulos no rompen', () => {
    expect(separarPagosFicha([
      { monto: '250.50', forma_pago: 'efectivo', pedido_id: null },
      { monto: null, forma_pago: 'efectivo' },
    ])).toEqual({ cobrado: 250.5, notaCreditoAplicada: 0, saldoAFavorAplicado: 0 })
  })
})
