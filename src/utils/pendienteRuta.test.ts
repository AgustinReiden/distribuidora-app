import { describe, it, expect } from 'vitest'
import { pendienteDeRuta } from './pendienteRuta'

describe('pendienteDeRuta (Rut-B11)', () => {
  it('una boleta de 1.000 pagada 700 en efectivo y 300 con saldo a favor no deja nada pendiente', () => {
    // monto_pagado = 1.000 (incluye el crédito aplicado); total_cobrado de la ruta sería 700.
    expect(pendienteDeRuta(1000, [{ estado_entrega: 'entregado', pedido: { estado: 'entregado', monto_pagado: 1000 } }])).toBe(0)
  })

  it('lo que falta pagar de una entregada y lo que falta entregar quedan pendientes', () => {
    expect(pendienteDeRuta(1500, [
      { estado_entrega: 'entregado', pedido: { estado: 'entregado', monto_pagado: '400.50' } },
      { estado_entrega: 'pendiente', pedido: { estado: 'asignado', monto_pagado: 100 } },
    ])).toBe(1099.5)
  })

  it('no cuenta paradas que no son de la ruta (no entregada acá, reasignada) ni vales blancos', () => {
    expect(pendienteDeRuta(1000, [
      { estado_entrega: 'reasignado', pedido: { estado: 'entregado', monto_pagado: 500 } },
      { estado_entrega: 'no_entregado', pedido: { estado: 'entregado', monto_pagado: 500 } },
      { estado_entrega: 'entregado', pedido: { estado: 'entregado', monto_pagado: 300, tipo_factura: 'VB' } },
    ])).toBe(1000)
  })

  it('sin paradas ni facturado, cero', () => {
    expect(pendienteDeRuta(null, [])).toBe(0)
  })
})
