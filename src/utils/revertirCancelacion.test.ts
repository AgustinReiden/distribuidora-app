import { describe, it, expect } from 'vitest'
import {
  puedeRevertirCancelacion,
  mensajeConfirmarRevertirCancelacion,
  mensajeCancelacionRevertida,
} from './revertirCancelacion'
import { formatPrecio } from './formatters'

const cancelado = { estado: 'cancelado' as const, tipo_factura: 'ZZ' as const, canal: 'app', fecha_entrega: null }

describe('puedeRevertirCancelacion', () => {
  it('lo ofrece al admin sobre un pedido cancelado', () => {
    expect(puedeRevertirCancelacion(cancelado, true)).toBe(true)
    expect(puedeRevertirCancelacion({ ...cancelado, motivo_cancelacion_tipo: 'falta_stock' }, true)).toBe(true)
  })

  it('no lo ofrece a quien no es admin', () => {
    expect(puedeRevertirCancelacion(cancelado, false)).toBe(false)
    expect(puedeRevertirCancelacion(cancelado, undefined)).toBe(false)
  })

  it('no lo ofrece sobre un pedido que no está cancelado', () => {
    for (const estado of ['pendiente', 'en_preparacion', 'asignado', 'entregado'] as const) {
      expect(puedeRevertirCancelacion({ ...cancelado, estado }, true)).toBe(false)
    }
  })

  it('no lo ofrece en lo que el server rechaza siempre', () => {
    expect(puedeRevertirCancelacion({ ...cancelado, motivo_cancelacion_tipo: 'cambio_de_cliente' }, true)).toBe(false)
    expect(puedeRevertirCancelacion({ ...cancelado, canal: 'cambio' }, true)).toBe(false)
    expect(puedeRevertirCancelacion({ ...cancelado, tipo_factura: 'VB' }, true)).toBe(false)
    expect(puedeRevertirCancelacion({ ...cancelado, fecha_entrega: '2026-11-20T15:00:00Z' }, true)).toBe(false)
  })
})

describe('mensajeConfirmarRevertirCancelacion', () => {
  it('dice el estado, el stock y qué cobro vuelve', () => {
    const m = mensajeConfirmarRevertirCancelacion({ id: '42' })
    expect(m).toContain('#42')
    expect(m).toContain('"Pendiente"')
    expect(m).toContain('descontar su stock')
    expect(m).toContain('vuelve a la boleta')
    expect(m).toContain('otras boletas se queda ahí')
  })
})

describe('mensajeCancelacionRevertida', () => {
  it('sin cobro, ni regalos, ni mermas', () => {
    expect(mensajeCancelacionRevertida({ success: true })).toBe(
      'Cancelación revertida: el pedido volvió a pendiente y descontó su stock')
  })

  it('con el cobro que volvió', () => {
    expect(mensajeCancelacionRevertida({ success: true, cobro_vuelto: 60 }))
      .toContain(`volvió ${formatPrecio(60)} de lo cobrado`)
  })

  it('una cancelación sin foto avisa que no volvió ningún cobro', () => {
    expect(mensajeCancelacionRevertida({ success: true, cobro_vuelto: 0, sin_foto: true }))
      .toContain('no volvió ningún cobro')
  })

  it('con los regalos que no volvieron y las mermas anuladas', () => {
    const m = mensajeCancelacionRevertida({
      success: true,
      regalos_quitados: [{ promocion_id: 7, promocion: 'Promo verano', motivo: 'sin cupo' }, { promocion_id: 9 }],
      mermas_anuladas: 2,
    })
    expect(m).toContain('volvió sin el regalo de Promo verano, promo #9')
    expect(m).toContain('se anularon 2 mermas')
    expect(mensajeCancelacionRevertida({ success: true, mermas_anuladas: 1 })).toContain('se anuló 1 merma')
  })
})
