import { describe, it, expect } from 'vitest'
import { compararPrecios, mensajeCambiosDePrecio } from './preciosVigentes'

const visto = (id: string, precio: number | null, precio_sin_iva: number | null = null) =>
  ({ id, nombre: `Producto ${id}`, precio, precio_sin_iva })

describe('compararPrecios (FRG2-3)', () => {
  it('sin cambios, no hay nada que avisar', () => {
    const r = compararPrecios([visto('1', 1000, 900)], [{ id: '1', precio: 1000, precio_sin_iva: 900 }])
    expect(r).toEqual({ cambios: [], faltan: [] })
  })

  it('un precio final distinto es un cambio, con de y a', () => {
    const r = compararPrecios([visto('1', 1000, 900)], [{ id: '1', precio: 1200, precio_sin_iva: 1000 }])
    expect(r.cambios).toEqual([{ id: '1', nombre: 'Producto 1', campo: 'precio', de: 1000, a: 1200 }])
  })

  it('si sólo cambió el neto, también avisa', () => {
    const r = compararPrecios([visto('1', 1000, 900)], [{ id: '1', precio: 1000, precio_sin_iva: 905 }])
    expect(r.cambios).toEqual([{ id: '1', nombre: 'Producto 1', campo: 'precio_sin_iva', de: 900, a: 905 }])
  })

  it('compara al centavo y tolera el tipo (número o texto de la base)', () => {
    const r = compararPrecios(
      [visto('1', 1000.004, 900)],
      [{ id: '1', precio: '1000.00' as unknown as number, precio_sin_iva: 900 }],
    )
    expect(r.cambios).toEqual([])
  })

  it('un producto que la base no devuelve queda en faltan', () => {
    const r = compararPrecios([visto('1', 1000), visto('2', 500)], [{ id: '2', precio: 500, precio_sin_iva: null }])
    expect(r.faltan.map(f => f.id)).toEqual(['1'])
    expect(r.cambios).toEqual([])
  })
})

describe('mensajeCambiosDePrecio', () => {
  it('nombra los primeros, cuenta el resto y dice que no se aplicó nada', () => {
    const cambios = Array.from({ length: 7 }, (_, i) => ({
      id: String(i), nombre: `P${i}`, campo: 'precio' as const, de: 100, a: 110,
    }))
    const m = mensajeCambiosDePrecio({ cambios, faltan: [] }, 3)
    expect(m).toMatch(/Cambió el precio de 7 productos/)
    expect(m).toMatch(/P0: de .*100.* a .*110/)
    expect(m).toMatch(/y 4 más/)
    expect(m).not.toMatch(/P3/)
    expect(m).toMatch(/No se aplicó nada/)
  })
})
