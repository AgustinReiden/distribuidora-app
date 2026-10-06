import { describe, it, expect } from 'vitest'
import { promosAfectadasPorDesactivar, avisoDesactivarProducto } from './promosAfectadasPorDesactivar'

const P = (o: Record<string, unknown>) => ({ nombre: 'X', activo: true, ...o }) as never

describe('promosAfectadasPorDesactivar', () => {
  it('encuentra promos activas por regalo y contenedor, comparando id como string', () => {
    const r = promosAfectadasPorDesactivar('5', [
      P({ nombre: 'A', producto_regalo_id: 5 }),
      P({ nombre: 'B', producto_regalo_id: '5' }),
      P({ nombre: 'C', ajuste_producto_id: 5 }),
      P({ nombre: 'D', producto_regalo_id: 6 }),
    ])
    expect(r).toEqual({ comoRegalo: ['A', 'B'], comoContenedor: ['C'] })
  })

  it('ignora promos inactivas o con fecha_fin vencida', () => {
    const r = promosAfectadasPorDesactivar('5', [
      P({ nombre: 'off', activo: false, producto_regalo_id: 5 }),
      P({ nombre: 'vencida', fecha_fin: '2026-01-01', producto_regalo_id: 5 }),
      P({ nombre: 'vigente', fecha_fin: '2026-12-31', producto_regalo_id: 5 }),
    ], '2026-10-06')
    expect(r.comoRegalo).toEqual(['vigente'])
  })

  it('sin promos afectadas el aviso es vacío', () => {
    expect(avisoDesactivarProducto({ comoRegalo: [], comoContenedor: [] })).toBe('')
  })

  it('redacta el aviso de regalo y el de contenedor en línea aparte', () => {
    expect(avisoDesactivarProducto({ comoRegalo: ['X', 'Y'], comoContenedor: ['Z'] })).toBe(
      'Es el regalo de la promo «X» y «Y». Mientras no cambies el regalo de esas promos, los pedidos que las activen van a fallar.\n' +
        'También es el contenedor de ajuste de la promo «Z».',
    )
    expect(avisoDesactivarProducto({ comoRegalo: ['X'], comoContenedor: [] })).toBe(
      'Es el regalo de la promo «X». Mientras no cambies el regalo de esa promo, los pedidos que la activen van a fallar.',
    )
  })
})
