import { describe, it, expect } from 'vitest'
import { detalleDeUso, mensajeAlNoBorrarPromocion, tienePromocionUso } from './promocionesEliminacion'

describe('tienePromocionUso', () => {
  it('sin pedidos, ajustes ni salvedades: no tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 0, ajustes: 0, salvedades: 0 })).toBe(false)
  })

  it('con pedidos facturados: tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 3, ajustes: 0, salvedades: 0 })).toBe(true)
  })

  it('con ajustes de stock aunque no tenga pedidos: tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 0, ajustes: 1, salvedades: 0 })).toBe(true)
  })

  it('con pedidos y ajustes: tiene uso', () => {
    expect(tienePromocionUso({ pedidos: 2, ajustes: 5, salvedades: 0 })).toBe(true)
  })

  it('con una salvedad que se llevó el regalo, aunque ya no haya líneas: tiene uso, como en el server (1556-b1)', () => {
    expect(tienePromocionUso({ pedidos: 0, ajustes: 0, salvedades: 1 })).toBe(true)
  })
})

describe('detalleDeUso', () => {
  it('nombra lo que hay, en singular o plural', () => {
    expect(detalleDeUso({ pedidos: 1, ajustes: 0, salvedades: 0 })).toBe('1 pedido facturado')
    expect(detalleDeUso({ pedidos: 3, ajustes: 1, salvedades: 0 })).toBe('3 pedidos facturados y 1 ajuste de stock')
    expect(detalleDeUso({ pedidos: 2, ajustes: 2, salvedades: 1 }))
      .toBe('2 pedidos facturados, 2 ajustes de stock y 1 salvedad')
    expect(detalleDeUso({ pedidos: 0, ajustes: 0, salvedades: 2 })).toBe('2 salvedades')
  })
})

describe('mensajeAlNoBorrarPromocion', () => {
  it('el rechazo de la guarda del server se muestra tal cual: ya está escrito para el usuario', () => {
    const rechazo = {
      code: 'P0001',
      message: 'No se puede eliminar la promoción «Promo 12+2»: la usan 1 pedido. Desactivala: deja de aplicarse a pedidos nuevos y el historial queda intacto.',
    }
    expect(mensajeAlNoBorrarPromocion(rechazo)).toBe(rechazo.message)
  })

  it('otro error del server no se muestra crudo', () => {
    expect(mensajeAlNoBorrarPromocion({ code: '23503', message: 'update or delete on table "promociones" violates foreign key constraint' }))
      .toBe('Error al eliminar promoción')
    expect(mensajeAlNoBorrarPromocion(new Error('Failed to fetch'))).toBe('Error al eliminar promoción')
    expect(mensajeAlNoBorrarPromocion(null)).toBe('Error al eliminar promoción')
  })
})
