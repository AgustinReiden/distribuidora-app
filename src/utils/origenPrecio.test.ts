import { describe, it, expect } from 'vitest'
import { resolverOrigenPrecio, construirOrigenPrecioItems, type ContextoOrigen } from './origenPrecio'

const mayorista = (escalaId: string | null = 'e1'): ContextoOrigen => ({
  preciosResueltos: new Map([['p1', { esMayorista: true, escalaId }]]),
})

describe('resolverOrigenPrecio', () => {
  it('sin nada aplicado es precio de lista', () => {
    expect(resolverOrigenPrecio({ productoId: 'p1', precioUnitario: 100 }))
      .toEqual({ origen: 'lista', escalaId: null })
  })

  it('la bonificación gana sobre todo lo demás', () => {
    const r = resolverOrigenPrecio(
      { productoId: 'p1', precioUnitario: 0, esBonificacion: true, precioOverride: true },
      { ...mayorista(), descuentoClientePct: new Map([['p1', 10]]) },
    )
    expect(r.origen).toBe('bonificacion')
  })

  it('el precio escrito a mano gana sobre el mayorista', () => {
    // Es la regla que evita pagar comisión reducida "por volumen" sobre una
    // decisión manual: con override, resolverPreciosMayorista ni siquiera aplica.
    const r = resolverOrigenPrecio(
      { productoId: 'p1', precioUnitario: 80, precioOverride: true },
      mayorista(),
    )
    expect(r).toEqual({ origen: 'manual', escalaId: null })
  })

  it('el mayorista gana sobre el descuento del cliente y arrastra la escala', () => {
    const r = resolverOrigenPrecio(
      { productoId: 'p1', precioUnitario: 80 },
      { ...mayorista('e7'), descuentoClientePct: new Map([['p1', 10]]) },
    )
    expect(r).toEqual({ origen: 'mayorista', escalaId: 'e7' })
  })

  it('mayorista sin id de escala no rompe: queda null', () => {
    expect(resolverOrigenPrecio({ productoId: 'p1', precioUnitario: 80 }, mayorista(null)))
      .toEqual({ origen: 'mayorista', escalaId: null })
  })

  it('distingue el descuento por categoría del general', () => {
    const ctx: ContextoOrigen = {
      descuentoClientePct: new Map([['p1', 10], ['p2', 5]]),
      descuentoPorCategoria: new Set(['p1']),
    }
    expect(resolverOrigenPrecio({ productoId: 'p1', precioUnitario: 90 }, ctx).origen)
      .toBe('desc_categoria')
    expect(resolverOrigenPrecio({ productoId: 'p2', precioUnitario: 95 }, ctx).origen)
      .toBe('desc_cliente')
  })

  it('un descuento de 0% es precio de lista, no descuento', () => {
    // Una regla por categoría en 0 existe para EXCLUIR del descuento general.
    const ctx: ContextoOrigen = {
      descuentoClientePct: new Map([['p1', 0]]),
      descuentoPorCategoria: new Set(['p1']),
    }
    expect(resolverOrigenPrecio({ productoId: 'p1', precioUnitario: 100 }, ctx).origen).toBe('lista')
  })

  it('un resuelto que no es mayorista no cuenta', () => {
    const ctx: ContextoOrigen = {
      preciosResueltos: new Map([['p1', { esMayorista: false, escalaId: 'e1' }]]),
    }
    expect(resolverOrigenPrecio({ productoId: 'p1', precioUnitario: 100 }, ctx))
      .toEqual({ origen: 'lista', escalaId: null })
  })
})

describe('construirOrigenPrecioItems', () => {
  it('arma el payload del RPC con ids en texto', () => {
    const payload = construirOrigenPrecioItems(
      [
        { productoId: 1, precioUnitario: 80 },
        { productoId: 2, precioUnitario: 0, esBonificacion: true },
      ],
      { preciosResueltos: new Map([['1', { esMayorista: true, escalaId: 'e3' }]]) },
    )
    expect(payload).toEqual([
      { producto_id: '1', es_bonificacion: false, origen_precio: 'mayorista', grupo_precio_escala_id: 'e3' },
      { producto_id: '2', es_bonificacion: true, origen_precio: 'bonificacion', grupo_precio_escala_id: null },
    ])
  })

  it('devuelve una fila por ítem, sin deduplicar', () => {
    const payload = construirOrigenPrecioItems([
      { productoId: 'p1', precioUnitario: 100 },
      { productoId: 'p1', precioUnitario: 100 },
    ])
    expect(payload).toHaveLength(2)
  })
})
