import { describe, it, expect } from 'vitest'
import { promoRigeEnPedido, regaloQueNoCrece } from './regaloPromoApagada'

const HOY = '2026-11-24'
const vigente = { activo: true, fecha_inicio: '2026-11-01', fecha_fin: null }
const apagada = { ...vigente, activo: false }

describe('promoRigeEnPedido (espejo del paso 2b de regalo_fuera_de_promo)', () => {
  it('apagada no rige', () => {
    expect(promoRigeEnPedido(apagada, '2026-11-20', HOY)).toBe(false)
  })
  it('activa y vigente en la fecha del pedido, rige', () => {
    expect(promoRigeEnPedido({ ...vigente, fecha_fin: '2026-11-21' }, '2026-11-20', HOY)).toBe(true)
  })
  it('activa, vencida para el pedido y para hoy, no rige', () => {
    expect(promoRigeEnPedido({ ...vigente, fecha_inicio: '2026-11-22', fecha_fin: '2026-11-23' }, '2026-11-20', HOY)).toBe(false)
  })
  it('una fecha futura mide en hoy', () => {
    expect(promoRigeEnPedido({ ...vigente, fecha_fin: '2026-11-24' }, '2026-12-01', HOY)).toBe(true)
  })
})

describe('regaloQueNoCrece (promos-B6, decisión del dueño del 24/11)', () => {
  it('la promo apagada conserva el regalo pero no lo sube: V×20 sigue con R×4', () => {
    expect(regaloQueNoCrece({ cantidad: 8, promo: apagada, fechaPedido: '2026-11-20', hoy: HOY, conservado: 4 })).toBe(4)
  })
  it('bajar la venta lo recorta como siempre', () => {
    expect(regaloQueNoCrece({ cantidad: 2, promo: apagada, fechaPedido: '2026-11-20', hoy: HOY, conservado: 4 })).toBe(2)
  })
  it('con la promo vigente crece', () => {
    expect(regaloQueNoCrece({ cantidad: 8, promo: vigente, fechaPedido: '2026-11-20', hoy: HOY, conservado: 4 })).toBe(8)
  })
  it('sin la promo decide el server', () => {
    expect(regaloQueNoCrece({ cantidad: 8, promo: null, fechaPedido: '2026-11-20', hoy: HOY, conservado: 4 })).toBe(8)
  })
})
